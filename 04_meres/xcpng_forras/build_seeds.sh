#!/usr/bin/env bash
# Builds the two NoCloud seed images (vfat, label CIDATA) and embeds them into the dom0 scripts.
set -euo pipefail
cd "$(dirname "$0")"
MERES_B64=$(base64 -w0 meres.sh)
TOKEN=$(head -c 12 /dev/urandom | base64 | tr -dc A-Za-z0-9)
rm -rf seed_b seed_o; mkdir -p seed_b seed_o

# ---------- bench seed ----------
cat > seed_b/meta-data <<EOF
instance-id: bench-xcpng-001
local-hostname: bench-debian12
EOF
cat > seed_b/user-data <<EOF
#cloud-config
package_update: true
packages: [sysbench, fio, python3]
write_files:
  - path: /root/meres.sh
    permissions: '0755'
    encoding: b64
    content: $MERES_B64
runcmd:
  - [bash, -c, "apt-get install -y xe-guest-utilities > /root/agent.log 2>&1 || echo 'nincs xe-guest-utilities' >> /root/agent.log"]
  - [bash, -c, "cd /root && ./meres.sh xcpng 5 > /root/meres.log 2>&1; mkdir -p /mnt/ki && mount LABEL=CIDATA /mnt/ki && tar czf /mnt/ki/eredmeny.tgz -C /root eredmenyek meres.log agent.log && sync && umount /mnt/ki; poweroff"]
EOF

# ---------- ops seed ----------
cat > seed_o/meta-data <<EOF
instance-id: ops-xcpng-001
local-hostname: ops-u1
EOF
cat > seed_o/user-data <<EOF
#cloud-config
package_update: true
write_files:
  - path: /root/jelzo.txt
    content: "$TOKEN"
  - path: /usr/local/sbin/xs-jelentes.sh
    permissions: '0755'
    content: |
      #!/bin/sh
      # a vendég saját állapotát a XenStore data/ ágába írja (ezt a dom0 olvassa)
      xenstore-write data/bench/vcpu "\$(nproc)" data/bench/mem_mb "\$(free -m | awk '/Mem:/{print \$2}')" \\
        data/bench/jelzo "\$(cat /root/jelzo.txt 2>/dev/null)" data/bench/kesz 1
  - path: /etc/systemd/system/xs-jelentes.service
    content: |
      [Unit]
      Description=Allapot jelentese a XenStore-ba (uzemeltetesi meres)
      After=network-online.target
      Wants=network-online.target
      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/xs-jelentes.sh
      [Install]
      WantedBy=multi-user.target
runcmd:
  - [bash, -c, "apt-get install -y xenstore-utils > /root/agent.log 2>&1; apt-get install -y xe-guest-utilities >> /root/agent.log 2>&1 || true"]
  - [systemctl, daemon-reload]
  - [systemctl, enable, xs-jelentes.service]
  - [systemctl, start, --no-block, xs-jelentes.service]
EOF

mk() { # $1 dir  $2 img
  rm -f "$2"; truncate -s 16M "$2"; mkfs.vfat -n CIDATA "$2" >/dev/null
  mcopy -i "$2" "$1/user-data" "$1/meta-data" ::
}
mk seed_b seed_bench.img; mk seed_o seed_ops.img
for s in bench ops; do
  gzip -9c seed_$s.img | base64 -w76 > seed_$s.b64
  python3 - "$s" "$TOKEN" <<'PY'
import sys
s,tok=sys.argv[1],sys.argv[2]
t=open(f"{s}_xcpng.tmpl.sh").read().replace("#@COMMON@\n",open("common.inc").read()).replace("__TOKEN__",tok)
open(f"{s}_xcpng.sh","w").write(t)
PY
  cat seed_$s.b64 >> ${s}_xcpng.sh
  bash -n ${s}_xcpng.sh
  echo "$s: $(wc -c < ${s}_xcpng.sh) bytes"
done
echo "TOKEN=$TOKEN"
