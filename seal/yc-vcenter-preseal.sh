#!/bin/bash
# =====================================================================================
# yc-vcenter-preseal.sh - bring vCenter template VMs up to date, across reboots,
#                         and stop when every one of them says READY TO SEAL.
#
#   ./yc-vcenter-preseal.sh 11 12 13 14 15 16 17 18
#   ./yc-vcenter-preseal.sh 11                       (one VM)
#   BASE=100.64.20 ./yc-vcenter-preseal.sh 11 12     (different subnet)
#
# It changes NOTHING on the hypervisor. It runs yc-preseal.ps1 inside each guest, and
# yc-preseal.ps1 decides what still needs doing by reading the machine, not a state
# file - so this loop is just "run it, reboot if it asks, run it again".
#
# WHY A LOOP AND NOT A SCRIPT THAT DOES IT ALL IN ONE PASS
#   .NET 4.8 always wants a restart, MSMQ removal wants a restart, and Windows Update
#   wants one after nearly every wave. Chaining work across a reboot inside the guest
#   means trusting a resume; re-running an idempotent script from outside does not.
#
# EXIT: 0 if every host reached READY TO SEAL, 1 otherwise. The per-host verdict is
#       printed at the end and each host keeps its own log at C:\Windows\Temp\yc-preseal.log
# =====================================================================================
set -u
BASE="${BASE:-100.64.20}"
PORT="${PORT:-3222}"
KEY="${KEY:-/root/.ssh/guest.key}"
RAW="${RAW:-https://raw.githubusercontent.com/yallacloud/yc-scripts/main}"
MAXROUNDS="${MAXROUNDS:-12}"
BOOTWAIT="${BOOTWAIT:-900}"     # seconds to wait for a guest to come back

O="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=20"

[ $# -ge 1 ] || { echo "usage: $0 <last-octet> [last-octet ...]   e.g. $0 11 12 13 14 15 16 17 18"; exit 2; }

say(){ echo "[$(date +%H:%M:%S)] $*"; }

up(){ timeout 5 bash -c "echo > /dev/tcp/$1/$PORT" 2>/dev/null; }

wait_up(){   # $1 = ip
  local t=0
  while [ $t -lt "$BOOTWAIT" ]; do
    if up "$1" && ssh $O -p "$PORT" "Administrator@$1" 'exit' >/dev/null 2>&1; then return 0; fi
    sleep 10; t=$((t+10))
  done
  return 1
}

# Wait for the guest to STOP answering. Going straight from "shutdown /r" to wait_up hits the
# sshd that is still alive during the shutdown, so the next command is cut off mid-flight and
# the caller reads an empty result from a host that is perfectly healthy.
wait_down(){ local t=0; while [ $t -lt 300 ]; do up "$1" || return 0; sleep 5; t=$((t+5)); done; return 1; }

# STAGING: ycnode01 fetches yc-preseal.ps1 ONCE and scp's it to every guest.
#
# It used to be the guest that downloaded it, and that was wrong twice over.
# raw.githubusercontent is behind a CDN, and for several minutes after a push an edge
# still serves the previous file: the guest reported a successful download and ran the
# OLD script. Checking the downloaded file for a feature string does not catch that
# either, once the feature has been there a while. And raw returns intermittent 503s -
# six of eight seal-kit files failed in one second on the first real run.
# Fetching once, here, with retries, and pushing the same bytes to every host removes
# the CDN from the per-guest path entirely and guarantees all eight run the same script.
LOCAL="/root/.yc-preseal.ps1"

fetch_local(){
  # NOFETCH=1 uses the copy already at $LOCAL. For when the node has been handed the
  # exact bytes out of band and the CDN must not get a vote.
  if [ "${NOFETCH:-0}" = "1" ] && [ -s "$LOCAL" ]; then
    say "using $LOCAL as-is  $(wc -c < "$LOCAL") bytes  sha $(sha256sum "$LOCAL" | cut -c1-16)"
    return 0
  fi
  local url="$RAW/seal/yc-preseal.ps1"
  local n
  for n in 1 2 3 4 5 6; do
    if curl -fsSL --max-time 60 "$url?cb=$(date +%s)$RANDOM$n" -o "$LOCAL.new" && [ -s "$LOCAL.new" ] \
       && grep -q 'YC-PRESEAL-RESULT' "$LOCAL.new"; then
      mv -f "$LOCAL.new" "$LOCAL"
      say "fetched yc-preseal.ps1  $(wc -c < "$LOCAL") bytes  sha $(sha256sum "$LOCAL" | cut -c1-16)"
      return 0
    fi
    sleep $((3*n))
  done
  rm -f "$LOCAL.new"
  return 1
}

stage(){     # $1 = ip
  scp $O -P "$PORT" -q "$LOCAL" "Administrator@$1:C:/Windows/Temp/yc-preseal.ps1" >/dev/null 2>&1
}

fetch_local || { echo "could not fetch yc-preseal.ps1 from $RAW - nothing staged, nothing run"; exit 1; }

declare -A VERDICT
for oct in "$@"; do
  IP="$BASE.$oct"
  say "===================== $IP ====================="
  if ! up "$IP"; then say "$IP: port $PORT is not answering - skipped"; VERDICT[$IP]="UNREACHABLE"; continue; fi

  round=0; verdict="INCOMPLETE"
  while [ $round -lt "$MAXROUNDS" ]; do
    round=$((round+1))
    if ! stage "$IP"; then say "$IP: could not stage yc-preseal.ps1"; verdict="STAGE-FAILED"; break; fi
    say "$IP: round $round"
    # THE SENTINEL, NOT $?, IS THE ANSWER.
    # The guests' OpenSSH DefaultShell is pwsh 7, and pwsh collapses every non-zero child
    # exit code to 1 when it is the login shell - 'ssh host powershell -Command "exit 8"'
    # comes back as 1. Measured on these very templates. So the loop could never tell
    # "reboot and run me again" from "this failed", which is the one distinction it is
    # built on. yc-preseal.ps1 prints YC-PRESEAL-RESULT: <verdict> as its last line.
    OUT=$(mktemp)
    ssh $O -p "$PORT" "Administrator@$IP" \
      'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\yc-preseal.ps1' 2>&1 | tee "$OUT"
    rc=${PIPESTATUS[0]}
    verd=$(grep -o 'YC-PRESEAL-RESULT: [A-Z]*' "$OUT" | tail -1 | awk '{print $2}')
    rm -f "$OUT"
    [ -n "$verd" ] || { say "$IP: no result line from yc-preseal (ssh rc=$rc) - stopping this host"; verdict="NO-RESULT"; break; }
    case "$verd" in
      READY) say "$IP: READY TO SEAL"; verdict="READY"; break ;;
      REBOOT) say "$IP: reboot requested - restarting"
         ssh $O -p "$PORT" "Administrator@$IP" 'shutdown /r /t 5 /f' >/dev/null 2>&1
         wait_down "$IP" || say "$IP: never stopped answering - carrying on"
         if wait_up "$IP"; then sleep 45; say "$IP: back up"; else say "$IP: did NOT come back within ${BOOTWAIT}s"; verdict="NO-BOOT"; break; fi ;;
      *) say "$IP: yc-preseal says $verd (ssh rc=$rc) - stopping this host"; verdict="$verd"; break ;;
    esac
  done
  [ "$verdict" = "INCOMPLETE" ] && say "$IP: hit MAXROUNDS=$MAXROUNDS without finishing"
  VERDICT[$IP]="$verdict"
done

echo
echo "==================== SUMMARY ===================="
bad=0
for ip in $(echo "${!VERDICT[@]}" | tr ' ' '\n' | sort -t. -k4 -n); do
  printf '  %-16s %s\n' "$ip" "${VERDICT[$ip]}"
  [ "${VERDICT[$ip]}" = "READY" ] || bad=1
done
echo
if [ $bad -eq 0 ]; then
  echo "  All hosts are ready. NEXT, and do this deliberately:"
  echo "    1. shut each VM down cleanly   ssh \$O -p $PORT Administrator@$BASE.<n> 'shutdown /s /t 5 /f'"
  echo "    2. take a vCenter snapshot     PreSeal-<vm>-2.17.0     <- this is the way back"
  echo "    3. power the VMs back on"
  echo "    4. ./yc-vcenter-seal.sh <last-octets>"
else
  echo "  Fix the hosts above before sealing anything. Their log: C:\\Windows\\Temp\\yc-preseal.log"
fi
exit $bad
