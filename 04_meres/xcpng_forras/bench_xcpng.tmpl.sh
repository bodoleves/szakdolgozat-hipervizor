#!/usr/bin/env bash
# XCP-ng dom0-ban futtatandó (root). Ugyanazt a Debian 12 teszt-VM-et hozza létre, mint a Proxmoxon
# (4 vCPU, 8 GB RAM, 32 GB lemez, BIOS), lefuttatja benne a meres.sh-t, és összegyűjti az eredményt.
# A vendég a végén a saját seed-lemezére írja az eredményt és leáll, így nincs szükség hálózati hozzáférésre.
# Futtatás:  nohup bash /root/bench_xcpng.sh > /root/bench.log 2>&1 &    majd: tail -f /root/bench.log
set -uo pipefail
NAME=bench-debian12
#@COMMON@

echo "== 1. Hoszt adatai =="
HOST=$(xe host-list --minimal | cut -d, -f1)
{ date -Is; grep PRETTY /etc/os-release; echo "xapi software-version: $(xe host-param-get uuid=$HOST param-name=software-version)"
  xl info | grep -E '^(xen_version|xen_commandline|nr_cpus|cores_per_socket|threads_per_core|total_memory|free_memory|virt_caps)'
  grep -m1 'model name' /proc/cpuinfo; echo "dom0 vCPU: $(nproc), dom0 RAM: $(free -h | awk '/Mem:/{print $2}')"
  lsblk -o NAME,SIZE,TYPE,MODEL,ROTA
  xe sr-list params=name-label,type,physical-size,physical-utilisation
} | tee /root/bench_host_info.txt

[ -z "$(xe vm-list name-label=$NAME --minimal)" ] || { echo "A $NAME VM már létezik, leállok."; exit 1; }
RUN=$(xe vm-list power-state=running is-control-domain=false params=name-label --minimal)
[ -z "$RUN" ] || { echo "Futó vendégek vannak, ezek torzítanák a mérést: $RUN"; exit 1; }

echo "== 2. Felhőkép =="
get_image
SEED=$IMGDIR/seed_bench.img; extract_seed "$SEED"

echo "== 3. VM létrehozása =="
V=$(mkvm $NAME "$SEED") || { echo "VM-létrehozás sikertelen"; exit 1; }
SV=$(cat $IMGDIR/$NAME.seedvdi)
xe vm-param-list uuid=$V > /root/bench_vm_config.txt
xe vm-start uuid=$V && echo "elindult: $V"

echo "== 4. Várakozás a mérés végére (kb. 45-60 perc; a vendég a végén leáll) =="
for i in $(seq 1 180); do
  sleep 60
  st=$(xe vm-param-get uuid=$V param-name=power-state)
  [ "$st" = halted ] && { echo "Kész ($(date +%H:%M))."; break; }
  echo "  $(date +%H:%M) még fut…"
done

echo "== 5. Eredmények összegyűjtése =="
OUT=/root/xcpng_bench; mkdir -p $OUT
xe vdi-export uuid=$SV filename=$OUT/eredmeny_lemez.img format=raw
mkdir -p /mnt/eredm && if mount -o loop,ro $OUT/eredmeny_lemez.img /mnt/eredm; then
  cp /mnt/eredm/eredmeny.tgz $OUT/ && umount /mnt/eredm && tar xzf $OUT/eredmeny.tgz -C $OUT && cat $OUT/eredmenyek/xcpng_*/eredmenyek.csv
  echo "Sorok száma a CSV-ben: $(cat $OUT/eredmenyek/xcpng_*/eredmenyek.csv | wc -l) (várt: 41)"
else echo "A lemezkép nem csatolható fel itt – a nyers képet a gépeden bontjuk ki."; fi
cp /root/bench_host_info.txt /root/bench_vm_config.txt $OUT/
tar czf /root/bench_results_xcpng.tar.gz -C /root xcpng_bench
echo "Mentve: /root/bench_results_xcpng.tar.gz   (a $NAME VM leállítva megmarad)"
exit 0
__SEED__
