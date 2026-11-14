#!/usr/bin/env bash
# Proxmox VE hoszton futtatandó (root shell). Létrehoz egy Debian 12 teszt-VM-et,
# telepíti benne a mérőprogramokat, lefuttatja a meres.sh-t, és összegyűjti az eredményt.
# Futtatás:  nohup bash /root/bench_proxmox.sh > /root/bench.log 2>&1 &   majd: tail -f /root/bench.log
set -euo pipefail
VMID=9001; NAME=bench-debian12; CORES=4; MEM=8192; DISK=32G; REPS=5
IMG_URL=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
IMG=/var/lib/vz/template/debian-12-genericcloud-amd64.qcow2

echo "== 1. Hoszt adatai =="
{ date -Is; pveversion -v | head -5; lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Socket'; free -h; lsblk -o NAME,SIZE,TYPE,MODEL,ROTA; pvesm status; } | tee /root/bench_host_info.txt

qm status $VMID >/dev/null 2>&1 && { echo "A $VMID VM már létezik, leállok."; exit 1; }
RUNNING=$( (qm list | awk 'NR>1 && $3=="running"{print "VM "$1" "$2}'; pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print "CT "$1" "$NF}') || true)
if [ -n "$RUNNING" ]; then echo "Futó vendégek vannak, ezek torzítanák a mérést. Állítsd le őket, majd indítsd újra a szkriptet:"; echo "$RUNNING"; exit 1; fi
STORAGE=$(pvesm status --content images | awk 'NR==2{print $1}')
echo "VM-lemez tárolója: $STORAGE"

echo "== 2. Debian 12 felhőkép letöltése =="
mkdir -p /var/lib/vz/template; [ -f "$IMG" ] || wget -q --show-progress -O "$IMG" "$IMG_URL"

echo "== 3. cloud-init beállítás (snippet) =="
if ! awk '/^dir: local$/{f=1;next} /^[a-z]+: /{f=0} f' /etc/pve/storage.cfg | grep -q snippets; then
  CUR=$(awk '/^dir: local$/{f=1;next} /^[a-z]+: /{f=0} f&&/content/{print $2}' /etc/pve/storage.cfg)
  pvesm set local --content "${CUR},snippets"
fi
mkdir -p /var/lib/vz/snippets
cat > /var/lib/vz/snippets/bench-user.yaml <<YAML
#cloud-config
package_update: true
packages: [qemu-guest-agent, sysbench, fio, python3]
write_files:
  - path: /root/meres.sh
    permissions: '0755'
    encoding: b64
    content: MERES_B64
runcmd:
  - systemctl enable --now qemu-guest-agent
  - [bash, -c, "cd /root && ./meres.sh proxmox REPS_N > /root/meres.log 2>&1; touch /root/KESZ"]
YAML
sed -i "s|MERES_B64|IyEvdXNyL2Jpbi9lbnYgYmFzaAojIEhpcGVydml6b3Itw7Zzc3plaGFzb25sw610w7MgbcOpcsOpcyDigJMgYSBWRU5Ew4lHIHZpcnR1w6FsaXMgZ8OpcGJlbiBmdXR0YXRhbmTDsyAoRGViaWFuIDEyKS4KIyBIYXN6bsOhbGF0OiAgc3VkbyAuL21lcmVzLnNoIDxwbGF0Zm9ybT4gW2lzbcOpdGzDqXNzesOhbV0KIyAgIHBsLiAgICAgICBzdWRvIC4vbWVyZXMuc2ggcHJveG1veCA1CiMgRWzFkWZlbHTDqXRlbDogYXB0IGluc3RhbGwgLXkgc3lzYmVuY2ggZmlvIHB5dGhvbjMKIyBLaW1lbmV0OiAgIC4vZXJlZG1lbnllay88cGxhdGZvcm0+XzxpZMWRYsOpbHllZz4vICAoZXJlZG1lbnllay5jc3YsIG1ldGEudHh0LCBueWVycy8pCnNldCAtZXVvIHBpcGVmYWlsCgpQTEFURk9STT0iJHsxOj9BZGQgbWVnIGEgcGxhdGZvcm0gbmV2w6l0OiBwcm94bW94IHwgeGNwbmcgfCBlc3hpfSIKUkVQUz0iJHsyOi01fSIKQ1BVX1RJTUU9MzAgICAgICAgICAgIyBzIC8gQ1BVLSDDqXMgbWVtw7NyaWF0ZXN6dApGSU9fUlVOVElNRT02MCAgICAgICAjIHMgLyBsZW1lenRlc3p0IChtw6lydCBzemFrYXN6KQpGSU9fUkFNUD0xMCAgICAgICAgICAjIHMgYmVtZWxlZ8OtdMOpcyBhIGZpby1uIGJlbMO8bCAobmVtIGtlcsO8bCBheiBlcmVkbcOpbnliZSkKRklPX1NJWkU9NEcgICAgICAgICAgIyB0ZXN6dGbDoWpsIG3DqXJldGUKRklPX0RJUj0vdmFyL3RtcC9maW90ZXN0ICAgIyBGw4FKTFJBIG3DqXLDvG5rLCBzb2hhIG5lbSBueWVycyBlc3prw7Z6cmUKClsgIiQoaWQgLXUpIiAtZXEgMCBdIHx8IHsgZWNobyAiUm9vdCBqb2cga2VsbCAoc3VkbykuIjsgZXhpdCAxOyB9CmZvciBiIGluIHN5c2JlbmNoIGZpbyBweXRob24zOyBkbyBjb21tYW5kIC12ICRiID4vZGV2L251bGwgfHwgeyBlY2hvICJIacOhbnl6aWs6ICRiIjsgZXhpdCAxOyB9OyBkb25lCgpUUz0kKGRhdGUgKyVZJW0lZF8lSCVNJVMpCk9VVD0iLi9lcmVkbWVueWVrLyR7UExBVEZPUk19XyR7VFN9IjsgbWtkaXIgLXAgIiRPVVQvbnllcnMiICIkRklPX0RJUiIKQ1NWPSIkT1VUL2VyZWRtZW55ZWsuY3N2IgplY2hvICJwbGF0Zm9ybSxpc21ldGxlcyxzb3JyZW5kLHRlc3p0LGVydGVrLG1lcnRla2VneXNlZyxpb3BzLGF0bGFnX2tlc2xlbHRldGVzX3VzLGlkb3BvbnQiID4gIiRDU1YiCgojIC0tLSBLw7ZybnllemV0IHLDtmd6w610w6lzZSAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQp7CiAgZWNobyAicGxhdGZvcm06ICRQTEFURk9STSI7IGVjaG8gImluZGl0YXM6ICQoZGF0ZSAtSXMpIjsgZWNobyAiaXNtZXRsZXNlazogJFJFUFMiCiAgZWNobyAia2VybmVsOiAkKHVuYW1lIC1yKSI7IGVjaG8gIm9zOiAkKC4gL2V0Yy9vcy1yZWxlYXNlOyBlY2hvICIkUFJFVFRZX05BTUUiKSIKICBlY2hvICJzeXNiZW5jaDogJChzeXNiZW5jaCAtLXZlcnNpb24pIjsgZWNobyAiZmlvOiAkKGZpbyAtLXZlcnNpb24pIgogIGVjaG8gImNwdTogJChncmVwIC1tMSAnbW9kZWwgbmFtZScgL3Byb2MvY3B1aW5mbyB8IGN1dCAtZDogLWYyLSkiOyBlY2hvICJ2Y3B1OiAkKG5wcm9jKSIKICBlY2hvICJyYW06ICQoZnJlZSAtaCB8IGF3ayAnL01lbTove3ByaW50ICQyfScpIgogIGVjaG8gImxlbWV6ZWs6IjsgbHNibGsgLW8gTkFNRSxTSVpFLFRZUEUsTU9ERUwsUk9UQQogIGVjaG8gInZpcnR1YWxpemFjaW86ICQoc3lzdGVtZC1kZXRlY3QtdmlydCB8fCB0cnVlKSIKICBlY2hvICJwYXJhbWV0ZXJlazogQ1BVX1RJTUU9JENQVV9USU1FIEZJT19SVU5USU1FPSRGSU9fUlVOVElNRSBGSU9fUkFNUD0kRklPX1JBTVAgRklPX1NJWkU9JEZJT19TSVpFIgp9ID4gIiRPVVQvbWV0YS50eHQiCgojIC0tLSBUZXN6dGVrIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KcnVuX3Rlc3QoKSB7ICAjICQxIHRlc3p0ICAkMiBpc23DqXRsw6lzICgwID0gYmVtZWxlZ8OtdMWRLCBuZW0ga2Vyw7xsIGEgQ1NWLWJlKSAgJDMgc29ycmVuZAogIGxvY2FsIHQ9JDEgcmVwPSQyIG9yZD0kMyByYXc9IiRPVVQvbnllcnMvJHt0fV9yJHtyZXB9LnR4dCIgdmFsIHVuaXQgaW9wcyBsYXQKICBjYXNlICR0IGluCiAgICBjcHUxfGNwdTQpCiAgICAgIHN5c2JlbmNoIGNwdSAtLWNwdS1tYXgtcHJpbWU9MjAwMDAgLS10aHJlYWRzPSR7dCNjcHV9IC0tdGltZT0kQ1BVX1RJTUUgcnVuID4gIiRyYXciCiAgICAgIHZhbD0kKGF3ayAnL2V2ZW50cyBwZXIgc2Vjb25kL3twcmludCAkNH0nICIkcmF3Iik7IHVuaXQ9ImVzZW1lbnkvcyI7IGlvcHM9IiI7IGxhdD0iIiA7OwogICAgbWVtX3JlYWR8bWVtX3dyaXRlKQogICAgICBzeXNiZW5jaCBtZW1vcnkgLS1tZW1vcnktYmxvY2stc2l6ZT0xTSAtLW1lbW9yeS10b3RhbC1zaXplPTEwMDBHIFwKICAgICAgICAtLW1lbW9yeS1vcGVyPSR7dCNtZW1ffSAtLXRocmVhZHM9MSAtLXRpbWU9JENQVV9USU1FIHJ1biA+ICIkcmF3IgogICAgICB2YWw9JChncmVwIC1vUCAnXChcS1swLTkuXSsoPz0gTWlCL3NlY1wpKScgIiRyYXciKTsgdW5pdD0iTWlCL3MiOyBpb3BzPSIiOyBsYXQ9IiIgOzsKICAgIHNlcV9yZWFkfHNlcV93cml0ZXxyYW5kX3JlYWR8cmFuZF93cml0ZSkKICAgICAgbG9jYWwgcncgYnMKICAgICAgY2FzZSAkdCBpbiBzZXFfcmVhZCkgcnc9cmVhZDsgYnM9MU07OyBzZXFfd3JpdGUpIHJ3PXdyaXRlOyBicz0xTTs7CiAgICAgICAgICAgICAgICAgcmFuZF9yZWFkKSBydz1yYW5kcmVhZDsgYnM9NGs7OyByYW5kX3dyaXRlKSBydz1yYW5kd3JpdGU7IGJzPTRrOzsgZXNhYwogICAgICBmaW8gLS1uYW1lPSR0IC0tZGlyZWN0b3J5PSIkRklPX0RJUiIgLS1maWxlbmFtZT1maW90ZXN0LmJpbiAtLXNpemU9JEZJT19TSVpFIFwKICAgICAgICAgIC0tcnc9JHJ3IC0tYnM9JGJzIC0taW9kZXB0aD0zMiAtLW51bWpvYnM9MSAtLWlvZW5naW5lPWxpYmFpbyAtLWRpcmVjdD0xIFwKICAgICAgICAgIC0tdGltZV9iYXNlZCAtLXJ1bnRpbWU9JEZJT19SVU5USU1FIC0tcmFtcF90aW1lPSRGSU9fUkFNUCBcCiAgICAgICAgICAtLWdyb3VwX3JlcG9ydGluZyAtLW91dHB1dC1mb3JtYXQ9anNvbiA+ICIkcmF3IgogICAgICByZWFkIC1yIHZhbCBpb3BzIGxhdCA8IDwocHl0aG9uMyAtICIkcmF3IiAiJHJ3IiA8PCdQWScKaW1wb3J0IGpzb24sc3lzCmo9anNvbi5sb2FkKG9wZW4oc3lzLmFyZ3ZbMV0pKTsgZD1qWyJqb2JzIl1bMF1bInJlYWQiIGlmICJyZWFkIiBpbiBzeXMuYXJndlsyXSBlbHNlICJ3cml0ZSJdCnByaW50KHJvdW5kKGRbImJ3Il0vMTAyNCwyKSwgcm91bmQoZFsiaW9wcyJdLDEpLCByb3VuZChkWyJjbGF0X25zIl1bIm1lYW4iXS8xMDAwLDEpKQpQWQopCiAgICAgIHVuaXQ9Ik1pQi9zIiA7OwogIGVzYWMKICBbICIkcmVwIiAtZ3QgMCBdICYmIGVjaG8gIiRQTEFURk9STSwkcmVwLCRvcmQsJHQsJHZhbCwkdW5pdCwkaW9wcywkbGF0LCQoZGF0ZSAtSXMpIiA+PiAiJENTViIKICBlY2hvICIgIFskcmVwXSAkdDogJHZhbCAkdW5pdCIKfQoKVEVTVFM9ImNwdTEgY3B1NCBtZW1fcmVhZCBtZW1fd3JpdGUgc2VxX3JlYWQgc2VxX3dyaXRlIHJhbmRfcmVhZCByYW5kX3dyaXRlIgoKZWNobyAiPT0gQmVtZWxlZ8OtdMOpcyAobmVtIGtlcsO8bCBheiBlcmVkbcOpbnllayBrw7Z6w6kpID09Igpmb3IgdCBpbiAkVEVTVFM7IGRvIHJ1bl90ZXN0ICR0IDAgMDsgZG9uZQoKZm9yIHJlcCBpbiAkKHNlcSAxICIkUkVQUyIpOyBkbwogIGVjaG8gIj09IElzbcOpdGzDqXMgJHJlcC8kUkVQUyAodsOpbGV0bGVuIHNvcnJlbmQpID09IgogIG9yZD0wCiAgZm9yIHQgaW4gJChlY2hvICRURVNUUyB8IHRyICcgJyAnXG4nIHwgc2h1Zik7IGRvIG9yZD0kKChvcmQrMSkpOyBydW5fdGVzdCAkdCAkcmVwICRvcmQ7IGRvbmUKZG9uZQoKcm0gLWYgIiRGSU9fRElSL2Zpb3Rlc3QuYmluIgplY2hvICJiZWZlamV6ZXM6ICQoZGF0ZSAtSXMpIiA+PiAiJE9VVC9tZXRhLnR4dCIKZWNobyAiS8Opc3o6ICRDU1YiCg==|; s|REPS_N|$REPS|" /var/lib/vz/snippets/bench-user.yaml

echo "== 4. VM létrehozása =="
qm create $VMID --name $NAME --ostype l26 --cores $CORES --cpu host --memory $MEM \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single --agent enabled=1 \
  --serial0 socket --vga serial0
qm set $VMID --scsi0 ${STORAGE}:0,import-from=$IMG,iothread=1
qm resize $VMID scsi0 $DISK
qm set $VMID --ide2 ${STORAGE}:cloudinit --boot order=scsi0 --ipconfig0 ip=dhcp \
  --cicustom user=local:snippets/bench-user.yaml
qm config $VMID | tee /root/bench_vm_config.txt
qm start $VMID

echo "== 5. Várakozás a mérés végére (kb. 45-50 perc) =="
for i in $(seq 1 120); do
  sleep 60
  if qm guest exec $VMID -- test -f /root/KESZ 2>/dev/null | grep -q '"exitcode" : 0'; then echo "Kész."; break; fi
  echo "  $(date +%H:%M) még fut..."
done

echo "== 6. Eredmények összegyűjtése =="
qm guest exec $VMID --timeout 60 -- bash -c 'cd /root && tar czf - eredmenyek meres.log | base64 -w0' \
  | python3 -c 'import json,sys,base64; open("/root/bench_results_proxmox.tar.gz","wb").write(base64.b64decode(json.load(sys.stdin)["out-data"]))'
tar xzf /root/bench_results_proxmox.tar.gz -C /root
cat /root/eredmenyek/proxmox_*/eredmenyek.csv
echo "Mentve: /root/bench_results_proxmox.tar.gz, /root/bench_host_info.txt, /root/bench_vm_config.txt"
