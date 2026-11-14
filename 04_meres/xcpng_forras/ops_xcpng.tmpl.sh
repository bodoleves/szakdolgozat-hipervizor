#!/usr/bin/env bash
# Üzemeltetési (U1-U3) és biztonsági áttekintő teszt – XCP-ng dom0-ban, rootként, csak xe CLI-vel.
# Ugyanazok a lépések, mint az ops_proxmox.sh-ban. A "használható" állapot jele: a vendég a cloud-init
# befejezése után a XenStore-ba írja a saját állapotát (vCPU, RAM, jelzőfájl) – ez felel meg a Proxmoxon
# a qemu-guest-agent válaszának.
# Futtatás:  nohup bash /root/ops_xcpng.sh > /root/ops.log 2>&1 &     (kb. 15-25 perc)
# Eredmény:  /root/ops_xcpng.tar.gz
set -uo pipefail
TOKEN=__TOKEN__
#@COMMON@
OUT=/root/ops_xcpng; mkdir -p "$OUT"; CSV="$OUT/idok.csv"
echo "feladat,lepes,ido_s,megjegyzes" > "$CSV"
log(){ echo "$1,$2,$3,$4" >> "$CSV"; echo "[$1] $2: $3 s  $4"; }
xs(){ local d; d=$(xe vm-param-get uuid=$1 param-name=dom-id); xenstore-read /local/domain/$d/data/bench/$2 2>/dev/null; }
wait_ready(){ for i in $(seq 1 120); do [ "$(xs $1 kesz)" = 1 ] && return 0; sleep 5; done; return 1; }
agent(){ local n; n=$(xe vm-param-get uuid=$1 param-name=networks 2>/dev/null); [ -n "$n" ] && [ "$n" != "<not in database>" ] && echo "agent IP: igen" || echo "agent IP: nem"; }
shut(){ xe vm-shutdown uuid=$1 2>/dev/null || xe vm-shutdown uuid=$1 force=true; }
setres(){ # $1 vm $2 vcpu $3 GiB
  if [ "$2" -lt "$(xe vm-param-get uuid=$1 param-name=VCPUs-max)" ]; then
    xe vm-param-set uuid=$1 VCPUs-at-startup=$2; xe vm-param-set uuid=$1 VCPUs-max=$2
  else xe vm-param-set uuid=$1 VCPUs-max=$2; xe vm-param-set uuid=$1 VCPUs-at-startup=$2; fi
  xe vm-param-set uuid=$1 platform:cores-per-socket=$2
  xe vm-memory-limits-set uuid=$1 static-min=$3GiB dynamic-min=$3GiB dynamic-max=$3GiB static-max=$3GiB
}

for n in ops-u1 ops-u3-restore; do [ -z "$(xe vm-list name-label=$n --minimal)" ] || { echo "A $n VM már létezik, leállok."; exit 1; }; done
echo "futo_vendegek: $(xe vm-list power-state=running is-control-domain=false --minimal | tr , '\n' | grep -c .)" > "$OUT/kornyezet.txt"
get_image
SEED=$IMGDIR/seed_ops.img; extract_seed "$SEED"

echo "== U1: VM létrehozása =="
t0=$(now)
V1=$(mkvm ops-u1 "$SEED") || { echo "VM-létrehozás sikertelen"; exit 1; }
t1=$(now); log U1 "letrehozas_es_lemezimport" "$(dt $t0 $t1)" "vm-install + vdi-import + seed-lemez"
xe vm-start uuid=$V1; wait_ready $V1 && ok=igen || ok=nem
t2=$(now); log U1 "inditas_hasznalhatoig" "$(dt $t1 $t2)" "vendeg jelzett: $ok; $(agent $V1) (cloud-init csomagtelepites is)"
log U1 "osszesen" "$(dt $t0 $t2)" ""
xe vm-param-list uuid=$V1 > "$OUT/u1_vm_config.txt"

echo "== U2: Erőforrás-módosítás és visszaállítás =="
t0=$(now)
shut $V1; setres $V1 2 4; xe vm-start uuid=$V1; wait_ready $V1
t1=$(now); log U2 "modositas_2vcpu_4GB" "$(dt $t0 $t1)" "vendegben: vcpu=$(xs $V1 vcpu) mem_mb=$(xs $V1 mem_mb)"
shut $V1; setres $V1 4 8; xe vm-start uuid=$V1; wait_ready $V1
t2=$(now); log U2 "visszaallitas_4vcpu_8GB" "$(dt $t1 $t2)" "vendegben: vcpu=$(xs $V1 vcpu) mem_mb=$(xs $V1 mem_mb)"

echo "== U3: Mentés (élő pillanatkép + export) és helyreállítás =="
BK=/var/tmp/bench/ops-u1-mentes.xva
t0=$(now)
SNAP=$(xe vm-snapshot uuid=$V1 new-name-label=ops-u1-mentes-snap)
xe template-param-set is-a-template=false ha-always-run=false uuid=$SNAP
ts=$(now)
xe vm-export vm=$SNAP filename=$BK compress=zstd > "$OUT/u3_export.log" 2>&1 || { tm=gzip; xe vm-export vm=$SNAP filename=$BK compress=true >> "$OUT/u3_export.log" 2>&1; }
te=$(now)
xe vm-uninstall uuid=$SNAP force=true >/dev/null
t1=$(now); SZ=$(du -h $BK | cut -f1)
log U3 "mentes_snapshot_mod" "$(dt $t0 $t1)" "pillanatkep $(dt $t0 $ts) s + export $(dt $ts $te) s + torles; meret: $SZ (${tm:-zstd}); VM futott kozben"
V2=$(xe vm-import filename=$BK sr-uuid=$SR 2> "$OUT/u3_import.log")
xe vm-param-set uuid=$V2 name-label=ops-u3-restore
t2=$(now); log U3 "visszaallitas_uj_vm" "$(dt $t1 $t2)" "vm-import -> ops-u3-restore"
xe vm-start uuid=$V2; wait_ready $V2 && ok=igen || ok=nem
got=$(xs $V2 jelzo); t3=$(now); [ "$got" = "$TOKEN" ] && egyez=igen || egyez=nem
log U3 "visszaallitott_vm_hasznalhato" "$(dt $t2 $t3)" "vendeg jelzett: $ok, jelzofajl egyezik: $egyez"

echo "== Biztonsági áttekintés (csak olvasás) =="
HOST=$(xe host-list --minimal | cut -d, -f1); S="$OUT/biztonsag.txt"
{
 echo "### Verzio"; grep PRETTY /etc/os-release; xe host-param-get uuid=$HOST param-name=software-version
 echo; echo "### Frissitesek (yum)"; echo "frissitheto csomagok: $(yum -q check-update 2>/dev/null | grep -cE '^[A-Za-z0-9]')"
 echo; echo "### Csomagforrasok (engedelyezett)"; grep -hE '^\[|^enabled|^baseurl' /etc/yum.repos.d/*.repo 2>/dev/null
 echo; echo "### Halozati interfeszek"; ip -br addr; xe pif-list params=device,IP,management,VLAN
 echo; echo "### Figyelo szolgaltatasok (TCP/UDP)"; ss -tulpn | awk 'NR==1||/LISTEN|UNCONN/{print $1,$5,$7}'
 echo; echo "### Tuzfal (iptables)"; iptables -S 2>&1 | head -40
 echo; echo "### Kulso hitelesites"; echo "external-auth-type: $(xe host-param-get uuid=$HOST param-name=external-auth-type)"
 echo; echo "### Felhasznalok / RBAC alanyok"; xe subject-list params=subject-identifier,other-config,roles 2>&1
 echo; echo "### Szerepkorok"; xe role-list params=name-label --minimal | tr , '\n' | grep -E '^(pool-admin|pool-operator|vm-power-admin|vm-admin|vm-operator|read-only)$'
 echo; echo "### Ketfaktoros azonositas"; echo "A XAPI nem tamogat beepitett 2FA-t (Xen Orchestra szintjen allithato)."
 echo; echo "### SSH beallitasok"; sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|port) '
 echo; echo "### XAPI TLS tanusitvany"; openssl x509 -in /etc/xensource/xapi-ssl.pem -noout -subject -issuer -enddate 2>&1
 xe certificate-list params=type,name,not-after 2>/dev/null
 echo; echo "### Naplozas"; echo "remote syslog: $(xe host-param-get uuid=$HOST param-name=logging)"; df -h /var/log | tail -1
 grep -rhE '@@?[0-9a-zA-Z]' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | head -3 || true
} > "$S" 2>&1

echo "== Takarítás =="
for v in $V2 $V1; do xe vm-shutdown uuid=$v force=true >/dev/null 2>&1; xe vm-uninstall uuid=$v force=true >/dev/null 2>&1; done
rm -f "$BK"
tar czf /root/ops_xcpng.tar.gz -C /root ops_xcpng
cat "$CSV"; echo "Mentve: /root/ops_xcpng.tar.gz"
exit 0
__SEED__
