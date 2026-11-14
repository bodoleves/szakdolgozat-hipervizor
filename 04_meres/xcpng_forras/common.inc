# ---- közös rész (XCP-ng dom0) ----
export LC_ALL=C
BASE=https://cloud.debian.org/images/cloud/bookworm/latest
IMGDIR=/var/tmp/bench; mkdir -p "$IMGDIR"
RAW=$IMGDIR/debian-12-genericcloud-amd64.raw
now(){ date +%s.%N; }
dt(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
command -v xe >/dev/null || { echo "Ez nem XCP-ng dom0 (nincs xe)."; exit 1; }

SR=$(xe pool-list params=default-SR --minimal)
[ -n "$SR" ] && [ "$SR" != "<not in database>" ] || SR=$(xe sr-list content-type=user --minimal | cut -d, -f1)
NET=$(xe pif-list management=true params=network-uuid --minimal | cut -d, -f1)
echo "SR: $(xe sr-param-get uuid=$SR param-name=name-label) ($(xe sr-param-get uuid=$SR param-name=type)), halozat: $(xe network-param-get uuid=$NET param-name=bridge)"

get_image() {
  [ -s "$RAW" ] && return 0
  echo "Debian 12 felhőkép letöltése…"
  if curl -fL --retry 3 -o "$RAW.part" "$BASE/debian-12-genericcloud-amd64.raw"; then mv "$RAW.part" "$RAW"; return 0; fi
  echo "Nincs .raw változat, qcow2 + konvertálás…"
  local Q=$IMGDIR/debian-12-genericcloud-amd64.qcow2 QI
  curl -fL --retry 3 -o "$Q" "$BASE/debian-12-genericcloud-amd64.qcow2" || { echo "Letöltés sikertelen"; exit 1; }
  QI=$(command -v qemu-img || ls /usr/lib64/xen/bin/qemu-img /usr/lib64/qemu-dp/bin/qemu-img 2>/dev/null | head -1)
  [ -n "$QI" ] || { echo "Nincs qemu-img a dom0-ban – szólj, és máshogy oldjuk meg."; exit 1; }
  "$QI" convert -O raw "$Q" "$RAW" && rm -f "$Q"
}

# $1 név  $2 seed-kép  -> kiírja a VM uuid-ját; a seed VDI uuid-ja a $1.seedvdi fájlba kerül
mkvm() {
  local name=$1 seed=$2 V T vbd vdi VDI SV
  T=$(xe template-list name-label="Debian Bookworm 12" --minimal | cut -d, -f1)
  [ -n "$T" ] || T=$(xe template-list name-label="Other install media" --minimal | cut -d, -f1)
  V=$(xe vm-install template-uuid=$T new-name-label="$name" sr-uuid=$SR)
  for vbd in $(xe vbd-list vm-uuid=$V type=Disk --minimal | tr , ' '); do   # a sablon üres lemezét eldobjuk
    vdi=$(xe vbd-param-get uuid=$vbd param-name=vdi-uuid); xe vbd-destroy uuid=$vbd >&2; xe vdi-destroy uuid=$vdi >&2
  done
  [ -n "$V" ] || return 1
  xe vm-param-set uuid=$V HVM-boot-params:firmware=bios HVM-boot-params:order=c
  xe vm-param-set uuid=$V VCPUs-max=4; xe vm-param-set uuid=$V VCPUs-at-startup=4
  xe vm-param-set uuid=$V platform:cores-per-socket=4
  xe vm-memory-limits-set uuid=$V static-min=8GiB dynamic-min=8GiB dynamic-max=8GiB static-max=8GiB
  VDI=$(xe vdi-create sr-uuid=$SR name-label="$name-root" virtual-size=32GiB type=user)
  xe vdi-import uuid=$VDI filename="$RAW" format=raw >&2 || return 1
  xe vbd-create vm-uuid=$V vdi-uuid=$VDI device=0 bootable=true type=Disk mode=RW >/dev/null
  SV=$(xe vdi-create sr-uuid=$SR name-label="$name-seed" virtual-size=16MiB type=user)
  xe vdi-import uuid=$SV filename="$seed" format=raw >&2 || return 1
  xe vbd-create vm-uuid=$V vdi-uuid=$SV device=1 type=Disk mode=RW >/dev/null
  [ -n "$(xe vif-list vm-uuid=$V --minimal)" ] || xe vif-create vm-uuid=$V network-uuid=$NET device=0 mac=random >/dev/null
  echo "$SV" > "/var/tmp/bench/$name.seedvdi"
  echo "$V"
}

# a szkript végére fűzött seed-kép kibontása: $1 cél
extract_seed() { sed '1,/^__SEED__$/d' "$0" | base64 -d | gunzip > "$1"; }
