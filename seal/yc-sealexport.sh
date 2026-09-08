#!/bin/bash
# For a host that ALREADY has its STAGE04 snapshot and is sitting on it: seal, STAGE05, export.
set -u
VER=2.18.2
vmof(){ case "$1" in 11) echo V16B;; 12) echo V16E;; 13) echo V19B;; 14) echo V19E;; 15) echo V22B;; 16) echo V22E;; 17) echo V25B;; 18) echo V25E;; esac; }
shortof(){ case "$1" in 11) echo WS16B;; 12) echo WS16E;; 13) echo WS19B;; 14) echo WS19E;; 15) echo WS22B;; 16) echo WS22E;; 17) echo WS25B;; 18) echo WS25E;; esac; }
say(){ echo "[$(date +%H:%M:%S)] $*"; }
set -a; . /root/govc-yc.env; set +a
pstate(){ timeout 40 govc vm.info "$1" 2>/dev/null | awk -F': *' '/Power state/{print $2}'; }
for oct in "$@"; do
  VM=$(vmof $oct); SH=$(shortof $oct)
  say "=============== 100.64.20.$oct / $VM  (STAGE04 already exists)"
  /root/yc-vcenter-seal.sh $oct 2>&1 | grep -E "100.64.20.$oct: |tasks  |ABORT|SEALED"
  t=0; while [ $t -lt 300 ]; do [ "$(pstate $VM)" = "poweredOff" ] && break; sleep 10; t=$((t+10)); done
  if [ "$(pstate $VM)" != "poweredOff" ]; then say "$VM: NOT sealed after ${t}s - stopping"; continue; fi
  say "$VM: STAGE05-Sealed-VMWARE-$SH-$VER"
  timeout 300 govc snapshot.create -vm "$VM" -d "STAGE05 sealed. sysprep complete, payload $VER." "STAGE05-Sealed-VMWARE-$SH-$VER" 2>&1 | head -2
  say "$VM: exporting"
  /root/yc-ova-export.sh "$VM" 2>&1 | grep -E "  OK|FAILED|^===="
done
say done
