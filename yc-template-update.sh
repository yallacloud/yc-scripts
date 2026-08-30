#!/bin/bash
# yc-template-update.sh - bring ONE template VM up to the current payload, ready to seal.
#
#   ./yc-template-update.sh 100.64.20.3
#   ./yc-template-update.sh 100.64.20.3 -n     check only, change nothing
#
# Run it AFTER you have reverted the VM to the snapshot you want and it is booted
# and answering SSH on 3222. Safe to run more than once.
set -uo pipefail
IP="${1:-}"; DRY="${2:-}"
[ -n "$IP" ] || { echo "usage: yc-template-update.sh <ip> [-n]" >&2; exit 1; }
K=/root/.ssh/guest.key
G="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 -p 3222 -i $K Administrator@$IP"
P="scp -q -o StrictHostKeyChecking=no -o BatchMode=yes -P 3222 -i $K"
PS='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass'
ok(){ printf "  OK   %s\n" "$*"; }
no(){ printf "  FAIL %s\n" "$*"; FAILED=1; }
FAILED=0

echo "=== $IP"
$G 'cmd /c echo up' >/dev/null 2>&1 || { echo "  FAIL cannot ssh to $IP:3222 - is it booted?"; exit 2; }
ok "ssh"

WANT=$(curl -fsSL https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256 | grep -oE '[0-9A-Fa-f]{64}')
[ -n "$WANT" ] || { echo "  FAIL cannot read the sidecar from GitHub"; exit 2; }
echo "  github payload: ${WANT:0:16}..."

if [ "$DRY" = "-n" ]; then
  echo "  DRY RUN - nothing will be changed"
else
  # 1. bootstrap the updater (older snapshots do not have it), then pull the payload
  $P /root/scripts-v265/Update-YcScripts.ps1 Administrator@$IP:C:/Scripts/Update-YcScripts.ps1 2>/dev/null
  $G "cmd /c del /f /q C:\\Windows\\Temp\\yc-update.zip 2>nul" >/dev/null 2>&1
  $G "$PS -File C:\\Scripts\\Update-YcScripts.ps1" 2>&1 | grep -E 'SHA256 verified|Compliance gate|END exit' | sed 's/^/    /'

  # 2. the deployment-time fixes that belong in the IMAGE.
  #    gateway is deliberately NOT run here - it can move a route and this is a live SSH session.
  $G "$PS -File C:\\Scripts\\Fix-Deploy.ps1 -Only cbinit,lockout,console" 2>&1 | grep -E '\[OK\]|\[ERROR\]|Done\.' | sed 's/^/    /'

  # 3. put the SEAL TOOLING back.
  #    Update-YcScripts does a FULL overwrite from the payload, and the seal tooling is
  #    deliberately not in the payload - so the update above deletes Seal-Manual.ps1,
  #    AppX-Strip.ps1, doseal.cmd and the rest. Without this step the VM comes out of the
  #    update "READY TO SEAL" with nothing left to seal it with. Same source as the build
  #    tree: github seal/. doseal.cmd removes them again before sysprep, so none of this
  #    reaches a customer image.
  SEALRAW=https://raw.githubusercontent.com/yallacloud/yc-scripts/main/seal
  CACHE=/root/.sealcache; mkdir -p "$CACHE"; SN=0; SF=0
  for t in AppX-Strip.ps1 Clean-Scripts.ps1 Enable-VirtioBoot.ps1 Fix-DiagTools.ps1 \
           Fix-PreSeal.ps1 gi-settings.ps1 Install-YcPayload.ps1 \
           Install-YcTasks.ps1 PreSeal-Agents.ps1 Seal-Manual.ps1 yc-check.ps1 \
           yc-folders.ps1 yc-id.ps1 doseal.cmd; do
    curl -fsSL --max-time 90 -o "$CACHE/$t" "$SEALRAW/$t" 2>/dev/null || true
    if [ -s "$CACHE/$t" ] && $P "$CACHE/$t" Administrator@$IP:C:/Scripts/$t 2>/dev/null; then SN=$((SN+1)); else SF=$((SF+1)); fi
  done
  echo "    seal tooling restored: $SN file(s)$([ $SF -gt 0 ] && echo ", $SF FAILED")"

  # 3b. the Bitdefender tenant installer. Same casualty as the seal tooling: it is a
  #     vendor binary, not part of the payload, so the full overwrite removes it and
  #     Bitdefender-Register - which finds it by glob - then has nothing to run.
  BD=$(ls -1 /yc-primary/goldenstuff/agents/bitdefender/setupdownloader_*.exe 2>/dev/null | head -1)
  if [ -n "$BD" ]; then
    if $P "$BD" "Administrator@$IP:C:/Scripts/$(basename "$BD")" 2>/dev/null; then
      echo "    bitdefender installer restored"
    else
      echo "    bitdefender installer FAILED to copy"
    fi
  else
    echo "    bitdefender installer not in goldenstuff - skipped"
  fi

  # 4. the self-update task
  $G "$PS -File C:\\Scripts\\Yc-AutoUpdate.ps1 -Install" 2>&1 | grep -viE 'warning|^$' | tail -3 | sed 's/^/    /'
fi

# 4. verify
cat > /tmp/.tchk.ps1 <<'PS1'
$s=(((Get-Content C:\Scripts\.payload-sha256 -EA 0) -join '').Trim())
'SHA '+$s
'FILES '+(Get-ChildItem C:\Scripts -File -Force -EA 0).Count
$c='C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'
$p=((Get-Content $c -EA 0 | Where-Object {$_ -match '^plugins='}) -replace '^plugins=','' -split ',') | ForEach-Object { ($_ -split '\.')[-1] }
$i=[array]::IndexOf($p,'NetworkConfigPlugin'); $u=[array]::IndexOf($p,'UserDataPlugin')
'CBINIT '+$(if($i -ge 0 -and $i -lt $u){'ok'}else{'BAD'})
'TASK '+$(if(Get-ScheduledTask -TaskName 'YC-AutoUpdate' -EA 0){'ok'}else{'MISSING'})
$sm=@('Seal-Manual.ps1','AppX-Strip.ps1','doseal.cmd','Clean-Scripts.ps1','Unattend-Seal.xml') | Where-Object { -not (Test-Path (Join-Path 'C:\Scripts' $_)) }
'SEALKIT '+$(if($sm.Count -eq 0){'ok'}else{'MISSING:'+($sm -join ',')})
# Seal-Manual aborts on these by name. Anything here means the seal will refuse.
$jk=@('GoldenImage.ps1','GoldenImage-v239-yc.ps1','Prep-Seal.ps1') | Where-Object { Test-Path (Join-Path 'C:\Scripts' $_) }
$jk+=@(Get-ChildItem 'C:\Scripts' -Filter *.sh -File -EA 0 | ForEach-Object Name)
$jk+=@(Get-ChildItem 'C:\Scripts' -Filter *.py -File -EA 0 | ForEach-Object Name)
'JUNK '+$(if($jk.Count -eq 0){'none'}else{($jk -join ',')})
'BITDEF '+$(if(@(Get-ChildItem 'C:\Scripts' -Filter 'setupdownloader_*' -File -EA 0).Count){'ok'}else{'MISSING'})
'REARM '+(Get-CimInstance SoftwareLicensingService -EA 0).RemainingWindowsReArmCount
'LIC '+((& cscript //nologo C:\Windows\System32\slmgr.vbs /xpr 2>&1) -join ' ').Trim()
$e=0; foreach($f in Get-ChildItem C:\Scripts -Filter *.ps1 -File -EA 0){$er=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$er); if($er -and $er.Count){$e++}}
'PARSEERR '+$e
PS1
$P /tmp/.tchk.ps1 Administrator@$IP:C:/Windows/Temp/tchk.ps1 2>/dev/null
# tr -d '\r': the guest answers with CRLF, and every awk match below is anchored, so a
# trailing CR made all of them miss and turned a clean run into four false FAILs.
R=$($G "$PS -File C:\\Windows\\Temp\\tchk.ps1" 2>/dev/null | tr -d '\r')
GOT=$(echo "$R"   | awk '/^SHA /{print $2}')
[ "${GOT^^}" = "${WANT^^}" ] && ok "payload ${GOT:0:16}..." || no "payload is ${GOT:0:16}... want ${WANT:0:16}..."
[ "$(echo "$R" | awk '/^CBINIT /{print $2}')" = ok ] && ok "cloudbase-init NetworkConfigPlugin before UserData" || no "cloudbase-init plugin order"
[ "$(echo "$R" | awk '/^TASK /{print $2}')"   = ok ] && ok "YC-AutoUpdate registered" || no "YC-AutoUpdate task"
SK=$(echo "$R" | awk '/^SEALKIT /{print $2}')
if [ "$SK" = ok ]; then ok "seal tooling present"; else no "seal tooling $SK"; fi
JK=$(echo "$R" | awk '/^JUNK /{print $2}')
if [ "$JK" = none ]; then ok "no seal-blocking junk in C:\\Scripts"; else no "Seal-Manual will ABORT on: $JK"; fi
BD=$(echo "$R" | awk '/^BITDEF /{print $2}')
if [ "$BD" = ok ]; then ok "bitdefender installer present"; else no "bitdefender installer missing - bitdefender-register would fail"; fi
[ "$(echo "$R" | awk '/^PARSEERR /{print $2}')" = 0 ] && ok "every .ps1 parses under PowerShell 5.1" || no "$(echo "$R"|awk '/^PARSEERR /{print $2}') script(s) fail to parse"
RE=$(echo "$R" | awk '/^REARM /{print $2}')
case "$RE" in
  4294967295) no "rearm=0xFFFFFFFF - licensing store DESTROYED. Do not seal this VM." ;;
  0)          no "rearm=0 - no rearms left. Do not seal this VM." ;;
  *)          ok "rearm=$RE" ;;
esac
echo "  lic: $(echo "$R" | sed -n 's/^LIC //p')"
echo "  files: $(echo "$R" | awk '/^FILES /{print $2}')"
[ "$FAILED" = 0 ] && echo "  RESULT: READY TO SEAL" || echo "  RESULT: NOT READY - fix the FAIL lines above"
exit $FAILED
