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
  # The gate is allowed to spend ONE reboot. The -Report pass above installs chocolatey
  # servicing and .NET hotfixes, and those routinely leave a reboot pending that was NOT
  # pending when the pass started - so yc-preseal reports REBOOT on a host where all 24 other
  # gates PASS. Refusing outright there means a human has to restart the guest and run the
  # whole seal again, which is exactly what happened on 100.64.20.17 and .18 on 2026-09-09.
  # Anything other than REBOOT still refuses: a real defect must not be rebooted away.
  verd=''
  for attempt in 1 2; do
    OUT=$(mktemp)
    R "$IP" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\yc-preseal.ps1 -SkipPayload -SkipUpdates' > "$OUT" 2>&1
    verd=$(grep -o 'YC-PRESEAL-RESULT: [A-Z]*' "$OUT" | tail -1 | awk '{print $2}')
    rm -f "$OUT"
    [ "$verd" = "READY" ] && break
    # An EMPTY verdict is retryable for the same reason REBOOT is: it means the ssh session
    # died before yc-preseal printed its sentinel, which is what happens when the guest is
    # still finishing a restart. A real defect always prints FAILED.
    { [ "$verd" = "REBOOT" ] || [ -z "$verd" ]; } && [ $attempt -eq 1 ] || break
    say "$IP: gate wants a reboot - restarting once, then re-checking"
    R "$IP" 'shutdown /r /t 5 /f' >/dev/null 2>&1
    # Wait for the guest to actually GO DOWN before waiting for it to come up. Without this,
    # wait_up connects to the sshd that is still running during the shutdown, the command is
    # cut off mid-flight, and the gate reads an empty verdict on a perfectly healthy host.
    wait_down "$IP" || say "$IP: never stopped answering - carrying on"
    if ! wait_up "$IP"; then say "$IP: did not come back from the gate reboot"; verd='NO-BOOT'; break; fi
    sleep 45
  done
  if [ "$verd" != "READY" ]; then say "$IP: NOT ready (verdict=${verd:-none}) - refusing to seal"; VERDICT[$IP]="NOT-READY"; continue; fi

  say "$IP: 1 Fix-PreSeal"
  R "$IP" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Fix-PreSeal.ps1' | tail -30

  say "$IP: 2 reboot"
  R "$IP" 'shutdown /r /t 5 /f' >/dev/null 2>&1
  wait_down "$IP" || say "$IP: never stopped answering - carrying on"
  if ! wait_up "$IP"; then say "$IP: did not come back"; VERDICT[$IP]="NO-BOOT"; continue; fi
  sleep 45

  say "$IP: 3 Seal-Manual -WhatIf (preflight)"
  R "$IP" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1 -WhatIf'
  if [ $? -ne 0 ]; then say "$IP: PREFLIGHT ABORTED - nothing sealed"; VERDICT[$IP]="PREFLIGHT-ABORT"; continue; fi

  if [ "$DRYRUN" = "1" ]; then say "$IP: DRYRUN - stopping after preflight"; VERDICT[$IP]="PREFLIGHT-OK"; continue; fi

  say "$IP: 4 Seal-Manual (cleanup)"
  # Judge this by what Seal-Manual LOGGED, not by $?. The guests' OpenSSH DefaultShell is
  # pwsh 7, which does not report a child's exit status faithfully: on 100.64.20.18
  # 2026-09-09 Seal-Manual finished its cleanup and logged [END] exit=0, and $? still came
  # back non-zero, so the driver declared SEAL-ABORT on a run that had actually succeeded.
  # Seal-Manual's own last line is the authority.
  SOUT=$(mktemp)
  R "$IP" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1' > "$SOUT" 2>&1
  tail -3 "$SOUT" | grep -v RISK
  if grep -q 'ABORT:' "$SOUT" || ! grep -q '\[END\] exit=0' "$SOUT"; then
    say "$IP: Seal-Manual did not finish cleanly"; grep -E 'ABORT:' "$SOUT" | tail -2
    rm -f "$SOUT"; VERDICT[$IP]="SEAL-ABORT"; continue
  fi
  rm -f "$SOUT"

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
