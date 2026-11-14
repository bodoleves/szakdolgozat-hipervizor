#!/usr/bin/env bash
# Üzemeltetési (U1-U3) és biztonsági áttekintő teszt – Proxmox VE hoszton, rootként.
# Futtatás:  nohup bash /root/ops_proxmox.sh > /root/ops.log 2>&1 &     (kb. 15-25 perc)
# Eredmény:  /root/ops_proxmox.tar.gz
set -uo pipefail
export LC_ALL=C
OUT=/root/ops_proxmox; mkdir -p "$OUT"; CSV="$OUT/idok.csv"
echo "feladat,lepes,ido_s,megjegyzes" > "$CSV"
IMG=/var/lib/vz/template/debian-12-genericcloud-amd64.qcow2
IMG_URL=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
STORAGE=$(pvesm status --content images | awk 'NR==2{print $1}')
V1=9002; V2=9003
now(){ date +%s.%N; }
dt(){ python3 -c "print(round($2-$1,1))"; }
log(){ echo "$1,$2,$3,$4" >> "$CSV"; echo "[$1] $2: $3 s  $4"; }
wait_agent(){ local id=$1 t0; t0=$(now); for i in $(seq 1 120); do qm agent $id ping >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
gexec(){ qm guest exec "$1" -- bash -c "$2" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())'; }

for id in $V1 $V2; do qm status $id >/dev/null 2>&1 && { echo "A $id VM már létezik, leállok."; exit 1; }; done
echo "futo_vendegek: $(qm list | awk 'NR>1&&$3=="running"' | wc -l) VM, $(pct list 2>/dev/null | awk 'NR>1&&$2=="running"' | wc -l) CT" > "$OUT/kornyezet.txt"
[ -f "$IMG" ] || wget -q -O "$IMG" "$IMG_URL"
mkdir -p /var/lib/vz/snippets
cat > /var/lib/vz/snippets/ops-user.yaml <<'YAML'
#cloud-config
package_update: true
packages: [qemu-guest-agent]
runcmd:
  - systemctl enable --now qemu-guest-agent
YAML

echo "== U1: VM létrehozása =="
t0=$(now)
qm create $V1 --name ops-u1 --ostype l26 --cores 4 --cpu host --memory 8192 --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single --agent enabled=1 --serial0 socket --vga serial0 >/dev/null
qm set $V1 --scsi0 ${STORAGE}:0,import-from=$IMG,iothread=1 >/dev/null
qm resize $V1 scsi0 32G
qm set $V1 --ide2 ${STORAGE}:cloudinit --boot order=scsi0 --ipconfig0 ip=dhcp --cicustom user=local:snippets/ops-user.yaml >/dev/null
t1=$(now); log U1 "letrehozas_es_lemezimport" "$(dt $t0 $t1)" "qm create + import + resize + cloud-init"
qm start $V1; wait_agent $V1 && ok=igen || ok=nem
t2=$(now); log U1 "inditas_hasznalhatoig" "$(dt $t1 $t2)" "guest agent valaszol: $ok (cloud-init csomagtelepites is)"
log U1 "osszesen" "$(dt $t0 $t2)" ""
qm config $V1 > "$OUT/u1_vm_config.txt"

echo "== U2: Erőforrás-módosítás és visszaállítás =="
t0=$(now)
qm shutdown $V1 --timeout 120; qm set $V1 --cores 2 --memory 4096 >/dev/null; qm start $V1; wait_agent $V1
v=$(gexec $V1 'echo "vcpu=$(nproc) mem_mb=$(free -m | awk "/Mem:/{print \$2}")"')
t1=$(now); log U2 "modositas_2vcpu_4GB" "$(dt $t0 $t1)" "vendegben: $v"
qm shutdown $V1 --timeout 120; qm set $V1 --cores 4 --memory 8192 >/dev/null; qm start $V1; wait_agent $V1
v=$(gexec $V1 'echo "vcpu=$(nproc) mem_mb=$(free -m | awk "/Mem:/{print \$2}")"')
t2=$(now); log U2 "visszaallitas_4vcpu_8GB" "$(dt $t1 $t2)" "vendegben: $v"

echo "== U3: Mentés és helyreállítás =="
TOKEN=$(head -c 12 /dev/urandom | base64 | tr -dc A-Za-z0-9)
gexec $V1 "echo $TOKEN > /root/jelzo.txt; sync" >/dev/null
t0=$(now)
vzdump $V1 --mode snapshot --compress zstd --dumpdir /var/lib/vz/dump > "$OUT/u3_vzdump.log" 2>&1
t1=$(now)
BK=$(ls -t /var/lib/vz/dump/vzdump-qemu-$V1-*.vma.zst | head -1); SZ=$(du -h "$BK" | cut -f1)
log U3 "mentes_snapshot_mod" "$(dt $t0 $t1)" "fajl: $(basename $BK), meret: $SZ, VM futott kozben"
qmrestore "$BK" $V2 --unique 1 > "$OUT/u3_qmrestore.log" 2>&1
t2=$(now); log U3 "visszaallitas_uj_vmid" "$(dt $t1 $t2)" "qmrestore -> $V2"
qm start $V2; wait_agent $V2 && ok=igen || ok=nem
got=$(gexec $V2 'cat /root/jelzo.txt')
t3=$(now); [ "$got" = "$TOKEN" ] && egyez=igen || egyez=nem
log U3 "visszaallitott_vm_hasznalhato" "$(dt $t2 $t3)" "agent: $ok, jelzofajl egyezik: $egyez"

echo "== Biztonsági áttekintés (csak olvasás) =="
S="$OUT/biztonsag.txt"
{
 echo "### Verzio"; pveversion -v | head -3
 echo; echo "### Frissitesek (apt)"; apt-get update -qq >/dev/null 2>&1; apt list --upgradable 2>/dev/null | tail -n +2 | wc -l | sed 's/^/frissitheto csomagok: /'
 echo; echo "### Csomagforrasok"; grep -rh -E '^(deb|Types|URIs|Suites|Components)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
 echo; echo "### Halozati interfeszek"; ip -br addr
 echo; echo "### Figyelo szolgaltatasok (TCP/UDP)"; ss -tulpn | awk 'NR==1||/LISTEN|UNCONN/{print $1,$5,$7}'
 echo; echo "### Tuzfal"; pve-firewall status 2>&1
 echo; echo "### Hitelesitesi tartomanyok"; pvesh get /access/domains --output-format text 2>&1
 echo; echo "### Felhasznalok"; pvesh get /access/users --output-format text 2>&1
 echo; echo "### Ketfaktoros azonositas (tipusok, titkok nelkul)"; pvesh get /access/tfa --output-format json 2>/dev/null | python3 -c 'import json,sys; [print(u["userid"], [e.get("type") for e in u.get("entries",[])]) for u in json.load(sys.stdin)]' 2>&1
 echo; echo "### Jogosultsagok (ACL)"; pvesh get /access/acl --output-format text 2>&1
 echo; echo "### API tokenek (root@pam)"; pvesh get /access/users/root@pam/token --output-format text 2>&1
 echo; echo "### SSH beallitasok"; sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|port) '
 echo; echo "### Webes felulet tanusitvanya"; pvenode cert info --output-format text 2>&1 | grep -E -i 'filename|subject|issuer|notafter' 
 echo; echo "### Naplozas"; journalctl --disk-usage 2>&1; ls /etc/rsyslog.d 2>/dev/null; grep -rh -E '@@?[0-9a-zA-Z]' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | head -3 || true
} > "$S" 2>&1

echo "== Takarítás =="
qm stop $V2 >/dev/null 2>&1; qm destroy $V2 --purge >/dev/null 2>&1
qm stop $V1 >/dev/null 2>&1; qm destroy $V1 --purge >/dev/null 2>&1
rm -f "$BK" "${BK%.vma.zst}.log" 2>/dev/null
tar czf /root/ops_proxmox.tar.gz -C /root ops_proxmox
cat "$CSV"; echo "Mentve: /root/ops_proxmox.tar.gz"
