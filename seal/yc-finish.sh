#!/bin/bash
# yc-finish.sh <last-octet> - everything after yc-preseal says READY, for ONE host:
#   clean shutdown -> STAGE04 snapshot -> power on -> seal -> STAGE05 snapshot -> OVA export
# The snapshots are taken on a POWERED-OFF VM so they carry no memory state, and STAGE04 is
# taken BEFORE the seal so a bad image can be re-sealed without rebuilding - which also
# restores the rearm count, and on the 2025 pair that is the only rearm left.
set -u
VER=2.18.2
O="-i /root/.ssh/guest.key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=20"
vmof(){ case "$1" in 11) echo V16B;; 12) echo V16E;; 13) echo V19B;; 14) echo V19E;; 15) echo V22B;; 16) echo V22E;; 17) echo V25B;; 18) echo V25E;; esac; }
shortof(){ case "$1" in 11) echo WS16B;; 12) echo WS16E;; 13) echo WS19B;; 14) echo WS19E;; 15) echo WS22B;; 16) echo WS22E;; 17) echo WS25B;; 18) echo WS25E;; esac; }
say(){ echo "[$(date +%H:%M:%S)] $*"; }
set -a; . /root/govc-yc.env; set +a
pstate(){ timeout 40 govc vm.info "$1" 2>/dev/null | awk -F': *' '/Power state/{print $2}'; }

for oct in "$@"; do
  IP=100.64.20.$oct; VM=$(vmof $oct); SH=$(shortof $oct)
  say "=============== $IP / $VM"
  say "$VM: clean shutdown"
  ssh $O -p 3222 Administrator@$IP 'shutdown /s /t 5 /f' >/dev/null 2>&1
  t=0; while [ $t -lt 900 ]; do [ "$(pstate $VM)" = "poweredOff" ] && break; sleep 15; t=$((t+15)); done
  if [ "$(pstate $VM)" != "poweredOff" ]; then say "$VM: did not power off - SKIPPING"; continue; fi
  say "$VM: STAGE04-PreSeal-VMWARE-$SH-$VER"
  timeout 300 govc snapshot.create -vm "$VM" -d "STAGE04 pre-seal. payload $VER, 9 fix gates + YC tasks clean." "STAGE04-PreSeal-VMWARE-$SH-$VER" 2>&1 | head -2
  # POWER ON, AND BE READY FOR THE POST-SNAPSHOT NETWORK FAULT.
  # Observed three times on 2026-09-08 (V22E, V16E, V25B - two EFI and one BIOS, so it is
  # not firmware-specific): after snapshot.create the VM powers on, boots all the way to the
  # lock screen, VMware Tools reports guestState=running with the correct IP, the vNIC shows
  # Connected on the right port group - and the guest answers neither ICMP nor 3222. The disk
  # state is fine: reverting to the very snapshot just taken and powering on again fixes it
  # every time, which points at the power-on-after-snapshot transition rather than the image.
  # So: wait a reasonable time, and if it is still deaf, revert and try once more.
  boot_wait(){ local n=0; while [ $n -lt $1 ]; do timeout 3 bash -c "echo > /dev/tcp/$IP/3222" 2>/dev/null && return 0; sleep 15; n=$((n+15)); done; return 1; }
  timeout 60 govc vm.power -on "$VM" >/dev/null 2>&1
  if ! boot_wait 480; then
    say "$VM: booted but unreachable after 480s - the post-snapshot network fault. Reverting to the snapshot just taken and retrying."
    timeout 60 govc vm.power -off "$VM" >/dev/null 2>&1; sleep 8
    timeout 180 govc snapshot.revert -vm "$VM" "STAGE04-PreSeal-VMWARE-$SH-$VER" >/dev/null 2>&1; sleep 8
    timeout 60 govc vm.power -on "$VM" >/dev/null 2>&1
    if ! boot_wait 600; then say "$VM: STILL unreachable after the revert - SKIPPING, needs a look"; continue; fi
    say "$VM: back after the revert"
  fi
  sleep 20
  say "$VM: sealing"
  /root/yc-vcenter-seal.sh $oct 2>&1 | grep -E "100.64.20.$oct: |tasks  |ABORT|SEALED"
  # POLL, do not sample once. yc-vcenter-seal.sh declares success as soon as port 3222 stops
  # answering, and vCenter takes a few more seconds to mark the VM poweredOff - so a single
  # check here called a perfectly good seal "NOT sealed". Measured on V16B 2026-09-08.
  t=0; while [ $t -lt 300 ]; do [ "$(pstate $VM)" = "poweredOff" ] && break; sleep 10; t=$((t+10)); done
  if [ "$(pstate $VM)" != "poweredOff" ]; then say "$VM: NOT sealed (still powered on after ${t}s) - stopping here"; continue; fi
  say "$VM: STAGE05-Sealed-VMWARE-$SH-$VER"
  timeout 300 govc snapshot.create -vm "$VM" -d "STAGE05 sealed. sysprep complete, payload $VER." "STAGE05-Sealed-VMWARE-$SH-$VER" 2>&1 | head -2
  say "$VM: exporting OVA"
  /root/yc-ova-export.sh "$VM" 2>&1 | grep -E "  OK|FAILED|^===="
done
say "yc-finish done"
