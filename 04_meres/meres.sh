#!/usr/bin/env bash
# Hipervizor-összehasonlító mérés – a VENDÉG virtuális gépben futtatandó (Debian 12).
# Használat:  sudo ./meres.sh <platform> [ismétlésszám]
#   pl.       sudo ./meres.sh proxmox 5
# Előfeltétel: apt install -y sysbench fio python3
# Kimenet:   ./eredmenyek/<platform>_<időbélyeg>/  (eredmenyek.csv, meta.txt, nyers/)
set -euo pipefail

PLATFORM="${1:?Add meg a platform nevét: proxmox | xcpng | esxi}"
REPS="${2:-5}"
CPU_TIME=30          # s / CPU- és memóriateszt
FIO_RUNTIME=60       # s / lemezteszt (mért szakasz)
FIO_RAMP=10          # s bemelegítés a fio-n belül (nem kerül az eredménybe)
FIO_SIZE=4G          # tesztfájl mérete
FIO_DIR=/var/tmp/fiotest   # FÁJLRA mérünk, soha nem nyers eszközre

[ "$(id -u)" -eq 0 ] || { echo "Root jog kell (sudo)."; exit 1; }
for b in sysbench fio python3; do command -v $b >/dev/null || { echo "Hiányzik: $b"; exit 1; }; done

TS=$(date +%Y%m%d_%H%M%S)
OUT="./eredmenyek/${PLATFORM}_${TS}"; mkdir -p "$OUT/nyers" "$FIO_DIR"
CSV="$OUT/eredmenyek.csv"
echo "platform,ismetles,sorrend,teszt,ertek,mertekegyseg,iops,atlag_kesleltetes_us,idopont" > "$CSV"

# --- Környezet rögzítése --------------------------------------------------
{
  echo "platform: $PLATFORM"; echo "inditas: $(date -Is)"; echo "ismetlesek: $REPS"
  echo "kernel: $(uname -r)"; echo "os: $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "sysbench: $(sysbench --version)"; echo "fio: $(fio --version)"
  echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)"; echo "vcpu: $(nproc)"
  echo "ram: $(free -h | awk '/Mem:/{print $2}')"
  echo "lemezek:"; lsblk -o NAME,SIZE,TYPE,MODEL,ROTA
  echo "virtualizacio: $(systemd-detect-virt || true)"
  echo "parameterek: CPU_TIME=$CPU_TIME FIO_RUNTIME=$FIO_RUNTIME FIO_RAMP=$FIO_RAMP FIO_SIZE=$FIO_SIZE"
} > "$OUT/meta.txt"

# --- Tesztek ----------------------------------------------------------------
run_test() {  # $1 teszt  $2 ismétlés (0 = bemelegítő, nem kerül a CSV-be)  $3 sorrend
  local t=$1 rep=$2 ord=$3
  local raw="$OUT/nyers/${t}_r${rep}.txt" val="" unit="" iops="" lat=""
  case $t in
    cpu1|cpu4)
      sysbench cpu --cpu-max-prime=20000 --threads=${t#cpu} --time=$CPU_TIME run > "$raw"
      val=$(awk '/events per second/{print $4}' "$raw"); unit="esemeny/s"; iops=""; lat="" ;;
    mem_read|mem_write)
      sysbench memory --memory-block-size=1M --memory-total-size=1000G \
        --memory-oper=${t#mem_} --threads=1 --time=$CPU_TIME run > "$raw"
      val=$(grep -oP '\(\K[0-9.]+(?= MiB/sec\))' "$raw"); unit="MiB/s"; iops=""; lat="" ;;
    seq_read|seq_write|rand_read|rand_write)
      local rw bs
      case $t in seq_read) rw=read; bs=1M;; seq_write) rw=write; bs=1M;;
                 rand_read) rw=randread; bs=4k;; rand_write) rw=randwrite; bs=4k;; esac
      fio --name=$t --directory="$FIO_DIR" --filename=fiotest.bin --size=$FIO_SIZE \
          --rw=$rw --bs=$bs --iodepth=32 --numjobs=1 --ioengine=libaio --direct=1 \
          --time_based --runtime=$FIO_RUNTIME --ramp_time=$FIO_RAMP \
          --group_reporting --output-format=json > "$raw"
      read -r val iops lat < <(python3 - "$raw" "$rw" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); d=j["jobs"][0]["read" if "read" in sys.argv[2] else "write"]
print(round(d["bw"]/1024,2), round(d["iops"],1), round(d["clat_ns"]["mean"]/1000,1))
PY
)
      unit="MiB/s" ;;
  esac
  [ "$rep" -gt 0 ] && echo "$PLATFORM,$rep,$ord,$t,$val,$unit,$iops,$lat,$(date -Is)" >> "$CSV"
  echo "  [$rep] $t: $val $unit"
}

TESTS="cpu1 cpu4 mem_read mem_write seq_read seq_write rand_read rand_write"

echo "== Bemelegítés (nem kerül az eredmények közé) =="
for t in $TESTS; do run_test $t 0 0; done

for rep in $(seq 1 "$REPS"); do
  echo "== Ismétlés $rep/$REPS (véletlen sorrend) =="
  ord=0
  for t in $(echo $TESTS | tr ' ' '\n' | shuf); do ord=$((ord+1)); run_test $t $rep $ord; done
done

rm -f "$FIO_DIR/fiotest.bin"
echo "befejezes: $(date -Is)" >> "$OUT/meta.txt"
echo "Kész: $CSV"
