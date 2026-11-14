#!/usr/bin/env bash
# backup_proxmox.sh – teljes mentés a Proxmox hostról az XCP-ng telepítése előtt
#
# Használat (a Proxmox hoston, rootként):
#   bash backup_proxmox.sh --becsles            # csak felmérés, semmit nem ment
#   bash backup_proxmox.sh /mnt/kulso           # teljes mentés a megadott (felcsatolt) helyre
#
# Mit csinál:
#   1. leltár: vendégek, tárolók, lemezek, LVM, hálózat, verziók -> leltar/
#   2. host-konfiguráció archiválása (/etc/pve, hálózat, ssh, apt, /root, snippets…) -> host-config.tar.gz
#   3. minden VM és konténer mentése vzdump-pal (stop mód, zstd), a 9001-es tesztgép kivételével -> dump/
#   4. ellenőrzés: zstd -t minden archívumra, sha256 ellenőrzőösszegek -> MANIFEST.sha256
set -uo pipefail

KIHAGY="${KIHAGY:-9001}"          # vesszővel elválasztott VMID-k, amiket nem kell menteni
MOD="${MOD:-stop}"                # stop = legkonzisztensebb; snapshot = nincs leállás

hiba() { echo "HIBA: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || hiba "rootként futtasd"
command -v vzdump >/dev/null || hiba "ez nem Proxmox host (nincs vzdump)"

# ---------- felmérés ----------
becsles() {
  echo "== Vendégek =="
  qm list 2>/dev/null; echo; pct list 2>/dev/null; echo
  echo "== Tárolók =="
  pvesm status; echo
  echo "== Lemezek =="
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL; echo
  echo "== LVM kötetek (thin esetén a Data% a ténylegesen foglalt rész) =="
  lvs --units g -o lv_name,vg_name,lv_size,data_percent,pool_lv 2>/dev/null; echo
  echo "== Vendéglemezek összesített mérete (kiosztott, a 9001 nélkül) =="
  local ossz=0 id m
  for id in $(qm list 2>/dev/null | awk 'NR>1{print $1}') $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
    [[ ",$KIHAGY," == *",$id,"* ]] && continue
    if qm config "$id" >/dev/null 2>&1; then
      m=$(qm config "$id" | grep -E '^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]+:' | grep -v media=cdrom \
          | grep -oE 'size=[0-9.]+[KMGT]' | sed 's/size=//' | numfmt --from=iec 2>/dev/null | awk '{s+=$1} END{printf "%d", s}')
    else
      m=$(pct config "$id" | grep -E '^(rootfs|mp[0-9]+):' | grep -oE 'size=[0-9.]+[KMGT]' | sed 's/size=//' \
          | numfmt --from=iec 2>/dev/null | awk '{s+=$1} END{printf "%d", s}')
    fi
    m=${m:-0}; ossz=$((ossz + m))
    printf '  %-6s %10s\n' "$id" "$(numfmt --to=iec "$m")"
  done
  echo "  ÖSSZESEN (kiosztva): $(numfmt --to=iec $ossz)"
  echo "  A zstd-vel tömörített mentés jellemzően ennek a töredéke (az üres terület szinte nem foglal),"
  echo "  de a vastag (nem thin) LVM-en lévő, sok adatot tartalmazó lemezeknél a valós adat mérete számít."
}

if [ "${1:-}" = "--becsles" ] || [ -z "${1:-}" ]; then
  becsles
  [ -z "${1:-}" ] && echo && echo "Mentéshez: bash $0 /mnt/kulso"
  exit 0
fi

CEL="$1"
[ -d "$CEL" ] || hiba "$CEL nem létezik"
mountpoint -q "$CEL" || hiba "$CEL nincs felcsatolva (mountpoint) – nem mentek a host saját lemezére"
GYOKER_DEV=$(findmnt -no SOURCE /); CEL_DEV=$(findmnt -no SOURCE --target "$CEL")
[ "$GYOKER_DEV" != "$CEL_DEV" ] || hiba "a cél ugyanazon a lemezen van, mint a rendszer"

DIR="$CEL/proxmox_mentes_$(hostname)_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$DIR/leltar" "$DIR/dump" || hiba "nem írható: $CEL"
exec > >(tee -a "$DIR/mentes.log") 2>&1
echo "Mentés indul: $(date)  ->  $DIR"
echo "Szabad hely a célon: $(df -h --output=avail "$CEL" | tail -1)"

# ---------- 1. leltár ----------
L="$DIR/leltar"
becsles                         > "$L/becsles.txt" 2>&1
pveversion -v                   > "$L/pveversion.txt"
qm list                         > "$L/qm_list.txt"
pct list                        > "$L/pct_list.txt"
pvesm status                    > "$L/pvesm_status.txt"
cat /etc/pve/storage.cfg        > "$L/storage.cfg"
lsblk -f                        > "$L/lsblk.txt"
{ pvs; vgs; lvs -a; }           > "$L/lvm.txt" 2>&1
{ ip -br addr; ip route; }      > "$L/halozat.txt" 2>&1
cat /etc/network/interfaces     > "$L/interfaces"
for id in $(qm list | awk 'NR>1{print $1}');  do qm config  "$id" > "$L/vm_${id}.conf";  done
for id in $(pct list | awk 'NR>1{print $1}'); do pct config "$id" > "$L/ct_${id}.conf"; done
crontab -l                      > "$L/root_crontab.txt" 2>/dev/null
dpkg --get-selections           > "$L/csomagok.txt"
echo "[1/4] leltár kész"

# ---------- 2. host-konfiguráció ----------
tar czf "$DIR/host-config.tar.gz" --ignore-failed-read \
  /etc/pve /etc/network /etc/hosts /etc/hostname /etc/resolv.conf /etc/fstab \
  /etc/ssh /etc/apt /etc/lvm/lvm.conf /etc/vzdump.conf /etc/cron* \
  /root /var/lib/vz/snippets /var/lib/pve-cluster/config.db 2>/dev/null
echo "[2/4] host-config.tar.gz kész ($(du -h "$DIR/host-config.tar.gz" | cut -f1))"

# ---------- 3. vendégek ----------
echo "[3/4] vzdump indul (mód: $MOD, kihagyva: $KIHAGY) – ez órákig is tarthat"
vzdump --all 1 --exclude "$KIHAGY" --mode "$MOD" --compress zstd --zstd 0 \
       --dumpdir "$DIR/dump" --notes-template '{{guestname}}'
VZ=$?
[ $VZ -eq 0 ] && echo "vzdump: sikeres" || echo "FIGYELEM: vzdump kilépési kód $VZ – nézd meg a fenti naplót"

# ---------- 4. ellenőrzés ----------
echo "[4/4] ellenőrzés"
ROSSZ=0
for f in "$DIR"/dump/*.zst; do
  [ -e "$f" ] || continue
  if zstd -tq "$f"; then echo "  OK    $(basename "$f")"; else echo "  HIBÁS $(basename "$f")"; ROSSZ=1; fi
done
gzip -t "$DIR/host-config.tar.gz" && echo "  OK    host-config.tar.gz" || ROSSZ=1
( cd "$DIR" && find . -type f ! -name MANIFEST.sha256 ! -name mentes.log -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )

echo
echo "Mentett vendégek:"; ls -1 "$DIR"/dump/*.zst 2>/dev/null | sed 's#.*/vzdump-#  #'
echo "Várt (a $KIHAGY nélkül): $(( $(qm list | awk 'NR>1' | wc -l) + $(pct list | awk 'NR>1' | wc -l) - $(echo "$KIHAGY" | tr ',' '\n' | wc -l) ))"
echo "Teljes méret: $(du -sh "$DIR" | cut -f1)"
sync
if [ $VZ -eq 0 ] && [ $ROSSZ -eq 0 ]; then echo "KÉSZ – minden archívum ép. ($(date))"; else echo "KÉSZ, DE HIBÁVAL – ne töröld a Proxmoxot, amíg nincs rendben!"; fi
