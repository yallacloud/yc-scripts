#!/bin/bash
# yc-seal-loop.sh - update + seal one or more template VMs, and PROVE each seal.
#
#   ./yc-seal-loop.sh 1 2 3 4 5 6            # last octet of 100.64.20.x
#   ./yc-seal-loop.sh 11 12 13 14 15 16 17 18  # the vCenter stack's octets
#   ./yc-seal-loop.sh 100.64.30.7            # or a full address, for a different subnet
#   ./yc-seal-loop.sh 2                      # just the one that got missed
#
# An argument containing a dot is used as-is; a bare number is an octet of 100.64.20.x. The
# hardcoded /24 was fine while both stacks lived on it and would have quietly built the WRONG
# VM the day one of them moved.
#
# Why this exists: the old inline for-loop assumed the seal worked. On 2026-08-31
# .2 was skipped entirely (its ssh timed out during the reboot) and nobody noticed
# until the images were being captured. This version waits properly and then proves
# the VM powered itself off, which is the only real success signal.
set -uo pipefail
K=/root/.ssh/guest.key
O="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
PS='powershell -NoProfile -ExecutionPolicy Bypass'
SEAL="$PS -Command \"& C:\\Scripts\\Seal-Manual.ps1; & C:\\Scripts\\AppX-Strip.ps1; & C:\\Scripts\\AppX-Strip.ps1; & C:\\Scripts\\AppX-Strip.ps1; & C:\\Scripts\\AppX-Strip.ps1; cmd /c C:\\Scripts\\doseal.cmd\""

up(){ timeout 4 bash -c "echo > /dev/tcp/$1/3222" 2>/dev/null; }
sshq(){ ssh $O -o ConnectTimeout=8 -o BatchMode=yes -p 3222 "Administrator@$1" "$2" </dev/null 2>/dev/null; }

RESULT=()
for n in "$@"; do
  case "$n" in
    *.*) IP="$n" ;;
    *)   IP="100.64.20.$n" ;;
  esac
  echo; echo "################ $IP ################"

  # 1. already sealed and off? leave it alone - booting it would spend the seal.
  if ! up "$IP"; then
    echo "  SKIP - $IP is powered off. If it was sealed, capture it; do NOT boot it."
    RESULT+=("$IP SKIPPED(off)"); continue
  fi

  # 2. payload + preflight. Its exit code is the gate - do not seal past a FAIL.
  if ! ./yc-template-update.sh "$IP"; then
    echo "  ABORT - not READY TO SEAL"; RESULT+=("$IP ABORT(update)"); continue
  fi

  # 3. reboot. Sleep FIRST: for ~30s after 'shutdown /r' the box still answers ssh,
  #    and the old loop's `until ssh` matched that pre-shutdown window, raced ahead
  #    and fired the seal into a dying box. That is exactly how .2 was skipped.
  echo "  -- rebooting"
  sshq "$IP" 'shutdown /r /t 5 /f'
  sleep 60
  for _ in $(seq 60); do up "$IP" && break; sleep 10; done

  # 4. require the box to be steadily up, not merely reachable once.
  ok=0
  for _ in $(seq 30); do
    if sshq "$IP" 'cmd /c echo up' >/dev/null; then ok=$((ok+1)); else ok=0; fi
    [ $ok -ge 3 ] && break
    sleep 10
  done
  if [ $ok -lt 3 ]; then
    echo "  ABORT - $IP never came back steadily after the reboot"
    RESULT+=("$IP ABORT(reboot)"); continue
  fi
  sleep 30   # let sshd, sppsvc and the Task Scheduler settle

  # 4b. WinRE. Seal-Manual WARNs "not Enabled" on the 2022 pair, which means those
  #     clones ship with no recovery environment. One line, harmless where it is
  #     already on, so just always try it rather than special-casing an OS.
  sshq "$IP" 'reagentc /enable' >/dev/null
  echo "  -- winre: $(sshq "$IP" 'reagentc /info' | tr -d '\r' | grep -i "Status" | head -1)"

  # 5. seal. ServerAlive keeps the session alive through the long event-log clear.
  echo "  -- sealing"
  ssh $O -o ServerAliveInterval=60 -o ServerAliveCountMax=15 -p 3222 "Administrator@$IP" "$SEAL" </dev/null

  # 6. PROVE it. sysprep /shutdown powers the VM off; a FAILED sysprep leaves it up.
  #    'The batch file cannot be found.' is cosmetic - cmd re-reading the deleted
  #    doseal.cmd after sysprep already started. Ignore it, watch the power state.
  echo "  -- waiting for power-off (up to 20 min)"
  sealed=no
  for _ in $(seq 80); do
    if ! up "$IP"; then sleep 20; up "$IP" || { sealed=yes; break; }; fi
    sleep 15
  done
  if [ "$sealed" = yes ]; then
    echo "  SEALED - $IP is off. Capture from the powered-off ROOT volume. DO NOT BOOT IT."
    RESULT+=("$IP SEALED")
  else
    echo "  NOT SEALED - $IP is still up after 20 min. Do not capture. Check C:\\Windows\\System32\\Sysprep\\Panther\\setupact.log"
    RESULT+=("$IP NOT-SEALED")
  fi
done

echo; echo "================ SUMMARY ================"
printf '  %s\n' "${RESULT[@]}"
