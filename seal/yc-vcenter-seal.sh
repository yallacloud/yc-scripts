#!/bin/bash
# =====================================================================================
# yc-vcenter-seal.sh - the seal run. DESTRUCTIVE: each VM ends generalized and powered
#                      off, and there is no way back except the snapshot you took.
#
#   ./yc-vcenter-seal.sh 11 12 13 14 15 16 17 18
#   DRYRUN=1 ./yc-vcenter-seal.sh 11 ...    preflight only (Seal-Manual -WhatIf), seals nothing
#
# PRECONDITIONS - this script checks them and refuses if they are not met:
#   * yc-preseal.ps1 exits 0 on the host                    (run yc-vcenter-preseal.sh first)
#   * you have taken a vCenter snapshot named PreSeal-<vm>  (nothing here can verify that -
#     it is on you, and it is the only reason the last rollback was possible)
#
# THE SEQUENCE, and why it is in this order
#   1 Fix-PreSeal.ps1     registers YC-Boot / YC-Health / YC-KeyGuard, hides CloudinitAdmin,
#                         focuses the console on Administrator, and removes MSMQ if anything
#                         put it back. It can ask for a reboot; if it does, take it.
#   2 reboot              a pending restart makes Seal-Manual abort at check 3 anyway.
#   3 Seal-Manual -WhatIf 18 preflight gates, changes nothing. Anything red stops here.
#   4 Seal-Manual         the same gates, then the cleanup: secrets, build tasks, event
#                         logs, host keys, PSReadLine history.
#   5 AppX-Strip x4       four passes. One pass does not finish the job, and a leftover
#                         provisioned package is the classic sysprep failure.
#   6 doseal.cmd          deletes the seal tooling from C:\Scripts and launches
#                         sysprep /generalize /oobe /shutdown. The VM powering itself OFF
#                         is the success signal. Do not power it on again.
#
# Sysprep is launched by doseal.cmd, not by this script - every attempt to drive sysprep
# from an automation harness hung at Sysprep_Generalize_Pnp_Drivers with the image left
# UNDEPLOYABLE. doseal re-execs itself out of %TEMP% first so cmd is not reading a file
# that is being deleted underneath it.
# =====================================================================================
set -u
BASE="${BASE:-100.64.20}"
PORT="${PORT:-3222}"
KEY="${KEY:-/root/.ssh/guest.key}"
DRYRUN="${DRYRUN:-0}"
BOOTWAIT="${BOOTWAIT:-900}"
O="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=20"

[ $# -ge 1 ] || { echo "usage: $0 <last-octet> [last-octet ...]"; exit 2; }
say(){ echo "[$(date +%H:%M:%S)] $*"; }
up(){ timeout 5 bash -c "echo > /dev/tcp/$1/$PORT" 2>/dev/null; }
R(){ ssh $O -p "$PORT" "Administrator@$1" "$2"; }
wait_up(){ local t=0; while [ $t -lt "$BOOTWAIT" ]; do if up "$1" && R "$1" 'exit' >/dev/null 2>&1; then return 0; fi; sleep 10; t=$((t+10)); done; return 1; }
wait_down(){ local t=0; while [ $t -lt "$BOOTWAIT" ]; do up "$1" || return 0; sleep 10; t=$((t+10)); done; return 1; }

declare -A VERDICT
for oct in "$@"; do
  IP="$BASE.$oct"
  say "===================== $IP ====================="
  if ! up "$IP"; then say "$IP: not answering on $PORT"; VERDICT[$IP]="UNREACHABLE"; continue; fi

  say "$IP: gate - yc-preseal must exit 0"
  R "$IP" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\yc-preseal.ps1 -Report' | tail -40
  # pwsh 7 is the guests' OpenSSH DefaultShell and flattens every non-zero exit to 1, so
  # the verdict is read from yc-preseal's own last line rather than from $?.
  OUT=$(mktemp)
  R "$IP" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\yc-preseal.ps1 -SkipPayload -SkipUpdates' > "$OUT" 2>&1
  verd=$(grep -o 'YC-PRESEAL-RESULT: [A-Z]*' "$OUT" | tail -1 | awk '{print $2}')
  rm -f "$OUT"
  if [ "$verd" != "READY" ]; then say "$IP: NOT ready (verdict=${verd:-none}) - refusing to seal"; VERDICT[$IP]="NOT-READY"; continue; fi

  say "$IP: 1 Fix-PreSeal"
  R "$IP" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Fix-PreSeal.ps1' | tail -30

  say "$IP: 2 reboot"
  R "$IP" 'shutdown /r /t 5 /f' >/dev/null 2>&1
  sleep 30
  if ! wait_up "$IP"; then say "$IP: did not come back"; VERDICT[$IP]="NO-BOOT"; continue; fi
  sleep 30

  say "$IP: 3 Seal-Manual -WhatIf (preflight)"
  R "$IP" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1 -WhatIf'
  if [ $? -ne 0 ]; then say "$IP: PREFLIGHT ABORTED - nothing sealed"; VERDICT[$IP]="PREFLIGHT-ABORT"; continue; fi

  if [ "$DRYRUN" = "1" ]; then say "$IP: DRYRUN - stopping after preflight"; VERDICT[$IP]="PREFLIGHT-OK"; continue; fi

  say "$IP: 4 Seal-Manual (cleanup)"
  R "$IP" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1'
  if [ $? -ne 0 ]; then say "$IP: Seal-Manual aborted"; VERDICT[$IP]="SEAL-ABORT"; continue; fi

  say "$IP: 5 AppX-Strip x4"
  R "$IP" 'powershell -NoProfile -ExecutionPolicy Bypass -Command "& C:\Scripts\AppX-Strip.ps1; & C:\Scripts\AppX-Strip.ps1; & C:\Scripts\AppX-Strip.ps1; & C:\Scripts\AppX-Strip.ps1"' | tail -10

  say "$IP: 6 doseal - sysprep /generalize /oobe /shutdown"
  R "$IP" 'cmd /c C:\Scripts\doseal.cmd' | tail -10

  say "$IP: waiting for the VM to power itself off (that IS the success signal)"
  if wait_down "$IP"; then say "$IP: powered off - SEALED"; VERDICT[$IP]="SEALED"
  else say "$IP: still answering after ${BOOTWAIT}s - check sysprep on the console"; VERDICT[$IP]="SEAL-UNCONFIRMED"; fi
done

echo
echo "==================== SUMMARY ===================="
for ip in $(echo "${!VERDICT[@]}" | tr ' ' '\n' | sort -t. -k4 -n); do printf '  %-16s %s\n' "$ip" "${VERDICT[$ip]}"; done
echo
echo "  DO NOT power a SEALED VM on again. Convert it to a template from the powered-off state:"
echo "    PowerCLI  Get-VM <name> | Set-VM -ToTemplate -Confirm:\$false"
echo "    govc      govc vm.markastemplate <name>"
echo "    GUI       right-click the VM -> Template -> Convert to Template"
