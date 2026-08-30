# Seal-Manual.ps1  -  preflight + cleanup ONLY. It does NOT run AppX and it does
#                     NOT run sysprep. You run those two by hand afterwards.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1
#
#   ... -WhatIf     run every check, change nothing (no cleanup either)
#
# WHY THE SPLIT
# ------------
# Every automated launch of sysprep from this script ended the same way: the
# process stays ALIVE with ~0 CPU forever, setupact.log frozen at
# "Sysprep_Generalize_Pnp_Drivers: Exit", setuperr.log 0 bytes, ImageState
# UNDEPLOYABLE. It is a HANG, not a crash and not a kill - sysprep.exe was still
# resident 9 minutes later at 0.015s CPU. Launching it detached under a SYSTEM
# scheduled task made no difference, so it is not session parentage either.
# The one clean 2025 seal came from typing the four AppX passes and the sysprep
# line by hand. That is the only sequence with evidence behind it, so this script
# stops short of it and hands you the exact commands.
#
# REQUIRED ORDER:
#   1. shutdown /s /t 0            (a real shutdown, not a reboot)
#   2. snapshot  PreSeal-<vm>-<version>
#   3. power on
#   4. run this               -> preflight + cleanup
#   5. paste the block it prints  -> AppX x4, then sysprep
param([switch]$WhatIf,[switch]$WatchSeal,[int]$WatchSealTimeoutMin=20,[switch]$Help)

if($Help){
@"
Seal-Manual.ps1  -  preflight + cleanup ONLY. Does NOT run AppX, does NOT run sysprep - it hands you
  the exact commands to paste and run by hand (see WHY THE SPLIT at the top of the .ps1).
USAGE:
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1 [-WhatIf]
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1 -WatchSeal [-WatchSealTimeoutMin <n>]
PARAMETERS:
  -WhatIf                Run every preflight check, change nothing (no cleanup either).
  -WatchSeal             Poll for seal success INSTEAD of running preflight/cleanup: watches the
                          registry ImageState for IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE, up to
                          -WatchSealTimeoutMin minutes. Success is ImageState=RESEAL_TO_OOBE followed
                          by the VM powering itself off (that power-off IS the confirmation - do not
                          judge a seal by setuperr.log being empty; EFI sysprep always logs benign
                          BCD/NVRAM lines there). Run this in a SECOND console/session while sysprep
                          runs in the first, so you get a SEAL OK / SEAL FAILED verdict (and an ntfy
                          push, if configured) without staring at the console.
  -WatchSealTimeoutMin   Minutes to wait for ImageState=RESEAL_TO_OOBE before declaring SEAL FAILED.
                          Default: 20 (matches the documented "still ON ~20 min after sealing = failed").
  -Help                  Show this help and exit.
EXAMPLES:
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1 -WhatIf
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1 -WatchSeal
"@ | Write-Host
  exit 0
}

# Windows PowerShell 5.1 only. Under pwsh 7 the Appx cmdlets proxy through a
# WinPSCompat session and Get-AppxPackage -AllUsers UNDER-REPORTS, so the appx
# risk line below reads clean while sysprep still dies 0x8007001f.
if($PSVersionTable.PSEdition -eq 'Core'){
  $a = @(); if($WhatIf){ $a += '-WhatIf' }; if($WatchSeal){ $a += '-WatchSeal'; $a += '-WatchSealTimeoutMin'; $a += $WatchSealTimeoutMin }
  & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @a
  exit $LASTEXITCODE
}

# Continue, NOT Stop. wevtutil writes to stderr on protected channels and under
# 'Stop' PowerShell turns that into a terminating NativeCommandError - which
# killed an earlier version at the event-log loop. Preconditions are checked
# explicitly instead.
$ErrorActionPreference = 'Continue'

$U   = 'C:\Scripts\Unattend-Seal.xml'
$Log = 'C:\Scripts\seal.log'
$fail = @()
function Say($m,$c='Gray'){ $s = "[{0}] {1}" -f (Get-Date -f 'HH:mm:ss'), $m
                            Write-Host $s -ForegroundColor $c
                            Add-Content $Log $s -Encoding ascii -EA SilentlyContinue
                            if($script:YcLibLoaded){
                              $lvl = switch($c){ 'Red'{'ERROR'} 'Yellow'{'WARN'} 'Green'{'OK'} default{'INFO'} }
                              Write-YcLog $m $lvl
                            } }

# ---------- YallaCloud shared logging (documented scheme: transcript tagged [YALLACLOUD][<cmd>] at
#            C:\Scripts\<cmd>.log via _yc-lib.ps1, mirrored to the Application event log under source
#            YallaCloud, EventIDs 1000/1001/1002/1003/1099). Additive - seal.log stays the authoritative
#            per-line record; best-effort so a missing lib never blocks the seal. ----------
$script:YcLibLoaded = $false
if(Test-Path 'C:\Scripts\_yc-lib.ps1'){ try{ . 'C:\Scripts\_yc-lib.ps1'; Start-YcLog 'Seal-Manual'; $script:YcLibLoaded = $true }catch{} }

# push a build/seal notification to the ntfy topic (best-effort HTTP; mirrors GoldenImage.ps1's own
# Send-Ntfy so the SEAL OK / SEAL FAILED push from -WatchSeal reaches the same channel).
$NtfyTopic = 'https://ntfy.sh/9890122212'
function Send-Ntfy($title,$body){ if(-not $NtfyTopic){ return }; try{
  # -bor, not '=': a bare assignment drops whatever the host already negotiated.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $full = ([string]$body) + "`n----`nhost: $env:COMPUTERNAME"
  Invoke-RestMethod -Uri $NtfyTopic -Method Post -Body $full -Headers @{ Title=[string]$title } -TimeoutSec 15 | Out-Null }catch{} }

# ---------- -WatchSeal: authoritative seal-success detection ----------------
# Never judge a seal by setuperr.log being empty - EFI sysprep always logs benign BCD/NVRAM/MRT lines
# there (BiUpdateEfiEntry, BiExportBcdObjects, MRTGeneralize, "Failed ConnectServer") that are NOT
# failures. The only authoritative signal is registry ImageState = IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE,
# plus the VM actually powering itself off (a successful sysprep shuts the VM down; that power-off IS
# the confirmation). Run this in a second window/session while the AppX+sysprep block runs in the first.
if($WatchSeal){
  $imgKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
  Say ('=========== WATCHING FOR SEAL (timeout ' + $WatchSealTimeoutMin + ' min) ===========') Cyan
  $deadline = (Get-Date).AddMinutes($WatchSealTimeoutMin)
  $sealed = $false
  while((Get-Date) -lt $deadline){
    $img = (Get-ItemProperty $imgKey -EA SilentlyContinue).ImageState
    if($img -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'){ $sealed = $true; break }
    Start-Sleep -Seconds 15
  }
  if($sealed){
    Say 'SEAL OK - ImageState=IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE. Waiting for the VM to power itself off (that is the final confirmation) - this session will simply stop responding when it does.' Green
    Send-Ntfy 'Seal-Manual: SEAL OK' ("ImageState=RESEAL_TO_OOBE on $env:COMPUTERNAME - awaiting self power-off, then capture the template.")
    if($script:YcLibLoaded){ Write-YcLog 'SEAL OK - ImageState=RESEAL_TO_OOBE' 'OK' }
  } else {
    $img = (Get-ItemProperty $imgKey -EA SilentlyContinue).ImageState
    Say ("SEAL FAILED / TIMEOUT - still ON after $WatchSealTimeoutMin min, ImageState=$img. Do NOT capture. setuperr.log lines are informational only (EFI sysprep always logs benign BCD/NVRAM lines) - check setupact.log / setuperr.log tails for the real cause.") Red
    Send-Ntfy 'Seal-Manual: SEAL FAILED' ("Still ON after $WatchSealTimeoutMin min on $env:COMPUTERNAME, ImageState=$img. Investigate before recapturing.")
    if($script:YcLibLoaded){ Write-YcLog "SEAL FAILED/TIMEOUT - ImageState=$img" 'ERROR' }
  }
  if($script:YcLibLoaded){ Stop-YcLog $(if($sealed){0}else{1}) }
  if($sealed){ exit 0 } else { exit 1 }
}

function Exit-Seal([int]$Code){ if($script:YcLibLoaded){ Stop-YcLog $Code }; exit $Code }

# Zero removable packages is UNREACHABLE: inbox apps (DesktopAppInstaller,
# SecHealthUI) refuse removal outright and frameworks (VCLibs, .NET Native,
# UI.Xaml) always return. What breaks sysprep is a package installed for a user
# but NOT provisioned - and only when it belongs to a profile other than the one
# sealing. This reports that number; AppX-Strip.ps1 is what reduces it.
function Get-AppxRisk {
  $prov  = @(Get-AppxProvisionedPackage -Online -EA SilentlyContinue | ForEach-Object PackageName)
  $block = @(Get-AppxPackage -AllUsers -EA SilentlyContinue |
             Where-Object { -not $_.NonRemovable -and $prov -notcontains $_.PackageFullName })
  $me = $env:USERNAME
  $other = @()
  foreach($b in $block){
    foreach($u in $b.PackageUserInformation){
      if($u.InstallState -eq 'Installed' -and $u.UserSecurityId.Username -and $u.UserSecurityId.Username -notmatch "\\$me$"){
        $other += ("{0} [{1}]" -f $b.Name, $u.UserSecurityId.Username)
      }
    }
  }
  [pscustomobject]@{ NotProvisioned=$block.Count; OtherProfile=@($other|Select-Object -Unique) }
}

Say '=========== SEAL PREFLIGHT ===========' Cyan

# ---- 1. licence: sysprep dies 0xc004fe00 if this is not Licensed ------------
$dlv = (& cscript //nologo C:\Windows\System32\slmgr.vbs /dlv 2>&1) -join "`n"
if($dlv -match 'License Status:\s*(\w+)'){ $ls = $matches[1] } else { $ls = 'unknown' }
if($ls -eq 'Licensed'){ Say 'licence      : Licensed' Green }
else { Say "licence      : $ls  -> run slmgr /ato and re-check" Red; $fail += 'licence' }

# ---- 2. unattend -----------------------------------------------------------
if(Test-Path $U){ Say "unattend     : $U" Green }
else { Say "unattend     : MISSING $U" Red; $fail += 'unattend' }

# ---- 3. pending reboot: generalize refuses with one queued -----------------
$pend = @()
if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'){ $pend += 'CBS' }
if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'){ $pend += 'WU' }
if((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -EA SilentlyContinue).PendingFileRenameOperations){ $pend += 'FileRename' }
if($pend.Count){ Say ('pending boot : ' + ($pend -join ', ') + '  -> reboot, re-snapshot, retry') Red; $fail += 'pendingreboot' }
else { Say 'pending boot : none' Green }

# ---- 4. rearm budget -------------------------------------------------------
$rearm = (Get-CimInstance SoftwareLicensingService -EA SilentlyContinue).RemainingWindowsReArmCount
Say "rearm left   : $rearm"
if($rearm -eq 0){ Say '               0 rearms - generalize will FAIL' Red; $fail += 'rearm' }

# ---- 5. TrustedInstaller: stopped/disabled => sysprep 0x80080005 -----------
$ti = Get-Service TrustedInstaller -EA SilentlyContinue
if($ti){ Say ("trustedinst  : {0}/{1}" -f $ti.Status, $ti.StartType) }
if($ti -and $ti.StartType -eq 'Disabled'){ Say '               disabled - sysprep cannot query CBS' Red; $fail += 'trustedinstaller' }

# ---- 6. already generalized / mid-generalize? sysprep is ONE-SHOT ----------
$img = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -EA SilentlyContinue).ImageState
$gen = (Get-ItemProperty 'HKLM:\SYSTEM\Setup\Status\SysprepStatus' -EA SilentlyContinue).GeneralizationState
Say "imagestate   : $img  (GeneralizationState=$gen)"
if($img -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'){
  Say '               ALREADY GENERALIZED - do not run sysprep again.' Red
  Say '               Power off with: shutdown /s /t 0 /f    then capture.' Red
  Exit-Seal 1
}
if($img -eq 'IMAGE_STATE_UNDEPLOYABLE' -or $gen -eq 3){
  Say '               UNDEPLOYABLE / mid-generalize - a previous sysprep did not finish.' Red
  Say '               Revert to the PreSeal snapshot. Re-running sysprep here cannot succeed.' Red
  $fail += 'undeployable'
}
if(Get-Process sysprep -EA SilentlyContinue){
  Say '               sysprep.exe is ALREADY RUNNING on this box - do not start another.' Red
  $fail += 'sysprepRunning'
}

# ---- 7. WinRE (warning only) ----------------------------------------------
$re = (& reagentc /info 2>&1) -join ' '
if($re -match 'Enabled'){ Say 'winre        : Enabled' Green }
else { Say 'winre        : not Enabled - clones ship without recovery (reagentc /enable)' Yellow }

# ---- 8. secrets that must never ship --------------------------------------
$secrets = @('C:\Scripts\guest.key','C:\Scripts\.gi-pw','C:\Scripts\gi-settings.ps1',
             'C:\Scripts\gi-pw.seed','C:\Scripts\bootstrap-access.log') +
           @(Get-ChildItem 'C:\Scripts' -Force -Include '*.key','*.pem','*.ppk','id_rsa*' -Recurse -EA SilentlyContinue |
             ForEach-Object FullName)
$secrets = @($secrets | Select-Object -Unique | Where-Object { Test-Path $_ })
if($secrets.Count){ Say ('secrets      : {0} file(s) will be DELETED' -f $secrets.Count) Yellow
                    foreach($x in $secrets){ Say "               $x" Yellow } }
else { Say 'secrets      : none present' Green }

# ---- 9. first-boot engine: BOTH lines, or clones self-heal only on 2nd boot -
$scf = 'C:\Windows\Setup\Scripts\SetupComplete.cmd'
if(Test-Path $scf){
  $sc = Get-Content $scf -Raw
  $hasCreate = $sc -match 'schtasks\s+/create\s+/tn\s+YCFIRSTBOOT'
  $hasRun    = $sc -match 'schtasks\s+/run\s+/tn\s+YCFIRSTBOOT'
  if($hasCreate -and $hasRun){ Say 'setupcomplete: create + run present' Green }
  else { Say "setupcomplete: create=$hasCreate run=$hasRun - /sc onstart alone fires only on the NEXT boot" Red; $fail += 'setupcomplete' }
} else { Say "setupcomplete: MISSING $scf" Red; $fail += 'setupcomplete' }

# ---- 10. self-heal scripts, or YC-Boot/YC-Health/YC-KeyGuard never register --
$miss = @()
# yc-net.ps1 AND yc-guard.ps1 are both retired: Install-YcTasks.ps1 (called from
# Fix-PreSeal.ps1) replaces them with yc-boot.ps1/yc-health.ps1/yc-keyguard.ps1
# and DELETES yc-guard.ps1/.cmd + yc-net.ps1 as part of that swap (see
# Install-YcTasks.ps1 "Remove-Item ... yc-guard.ps1 ..."), so checking for
# yc-guard.ps1 here always fails post-Fix-PreSeal - check the three files that
# actually back the three tasks instead. An EMPTY file is as bad as a missing
# one - X19B shipped a 0-byte yc-deploy.ps1, so YCDEPLOY ran and did nothing.
# yc-deploy.ps1 was dropped in the v265 audit - YCDEPLOY is retired by
# Install-YcTasks, so demanding the file here failed the gate on a correctly
# cleaned image. Five files, all of which still back a live task.
foreach($f in 'C:\Scripts\yc-firstboot.ps1','C:\Scripts\yc-activate.ps1','C:\Scripts\yc-boot.ps1','C:\Scripts\yc-health.ps1','C:\Scripts\yc-keyguard.ps1'){
  if(-not (Test-Path $f)){ $miss += (Split-Path $f -Leaf) + ' (missing)' }
  elseif((Get-Item $f).Length -eq 0){ $miss += (Split-Path $f -Leaf) + ' (EMPTY)' }
}
if($miss.Count){ Say ('firstboot set: ' + ($miss -join ', ')) Red; $fail += 'firstbootscripts' }
else { Say 'firstboot set: all 5 present and non-empty' Green }

# ---- 11. sshd - every clone inherits this config ---------------------------
$bin = 'C:\Program Files\OpenSSH\OpenSSH-Win64'
if(Test-Path "$bin\sshd.exe"){
  $t = & "$bin\sshd.exe" -T 2>&1
  $tj = ($t | Out-String)
  $okPort = $tj -match '(?m)^port 3222'
  $okSub  = $tj -match '(?m)^subsystem sftp sftp-server\.exe'
  if($okPort -and $okSub){ Say 'sshd -T      : port 3222, subsystem sftp sftp-server.exe' Green }
  else { Say ("sshd -T      : port3222=$okPort subsystem=$okSub  " + (($t|Select-Object -First 1) -join '')) Red; $fail += 'sshdconfig' }
} else { Say 'sshd -T      : OpenSSH not installed' Yellow }
$dsco = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -EA SilentlyContinue).DefaultShellCommandOption
if($dsco -eq '-c' -or -not $dsco){ Say "shell option : '$dsco' (ok)" Green }
else { Say "shell option : '$dsco' - MUST be a single token '-c' or ssh/scp break" Red; $fail += 'shelloption' }

# ---- 12. virtio storage driver MUST NOT be 0.1.285 (SQL corruption race) ---
foreach($drv in 'viostor','vioscsi'){
  $dp = "C:\Windows\System32\drivers\$drv.sys"
  if(Test-Path $dp){
    $fv = (Get-Item $dp).VersionInfo.FileVersion
    if($fv -match '^100\.100\.104\.271'){ Say "$drv      : $fv (0.1.271 - safe)" Green }
    elseif($fv -match '^100\.101\.104\.285'){ Say "$drv      : $fv - 0.1.285 vioscsi/viostor RACE, unsafe for SQL" Red; $fail += 'virtio285' }
    else { Say "$drv      : $fv (unrecognised - verify)" Yellow }
  } else { Say "$drv      : not bound (normal on ESXi)" }
}

# ---- 13. orphaned OEM INFs - the "Err = 0x2" in the PnP generalize phase ---
# sysprep enumerates every oemNN.inf registered in the DriverStore. If one is
# registered but its file is gone it logs
#   SYSPRP SPPNP: Unable to configure all driver packages. Err = 0x2
# immediately before the phase where the hang happens. Not proven causal, but
# it is the only anomaly in an otherwise clean log, so surface it.
$orphan = @()
foreach($o in (Get-ChildItem 'C:\Windows\INF' -Filter 'oem*.inf' -EA SilentlyContinue)){
  if((Get-Item $o.FullName).Length -eq 0){ $orphan += $o.Name }
}
$reg = @(& pnputil.exe /enum-drivers 2>&1 | Select-String -Pattern 'Published Name:\s*(oem\d+\.inf)' |
         ForEach-Object { $_.Matches[0].Groups[1].Value })
foreach($r in $reg){ if(-not (Test-Path "C:\Windows\INF\$r")){ $orphan += "$r (registered, file missing)" } }
if($orphan.Count){ Say ('oem inf      : ' + ($orphan -join ', ')) Yellow }
else { Say ("oem inf      : {0} registered, all present" -f $reg.Count) Green }

# ---- 14. MSMQ - registers a generalize provider and stalls sysprep ---------
# Arrived via 'Install-WindowsFeature NET-Framework-45-Features', whose
# NET-WCF-MSMQ-Activation45 sub-feature depends on MSMQ-Server. Symptom: sysprep
# stops dead right after "Sysprep_Generalize_Pnp_Drivers: Exit" with a 0-byte
# setuperr.log - sometimes hung at ~0 CPU, sometimes just gone. Removal needs a
# reboot, so this is a hard abort, not something to fix in place.
if((Get-Service MSMQ -EA SilentlyContinue) -or (Get-WindowsFeature MSMQ -EA SilentlyContinue).Installed){
  Say 'msmq         : INSTALLED - sysprep will stall. Uninstall-WindowsFeature MSMQ -Remove,' Red
  Say '               reboot, re-snapshot, then seal.' Red
  $fail += 'msmq'
} else { Say 'msmq         : absent' Green }

# ---- 14b. the LEGACY 9-task scheme must be gone ----------------------------
# GoldenImage.ps1 step 55 still bakes the old nine tasks. Install-YcTasks.ps1
# (called by Fix-PreSeal.ps1) retires them and installs the three. If any of the
# nine are still registered here, Fix-PreSeal was never run on this golden - and
# sealing now would ship YCGUARD5, which re-opens the firewall rules every five
# minutes forever and defeats the "open by default, never re-enforced" policy an
# administrator relies on. Abort rather than ship it.
$legacy = @('GIGrowDisk','GIDiskGuard','GINetwork','GIWatchdog','YCDEPLOY',
            'YCGUARD','YCGUARD5','YCNET','YCNET5' |
            Where-Object { Get-ScheduledTask -TaskName $_ -EA SilentlyContinue })
if($legacy.Count){
  Say ('legacy tasks : ' + ($legacy -join ', ')) Red
  Say '               Fix-PreSeal.ps1 was not run - it calls Install-YcTasks.ps1,' Red
  Say '               which retires these nine and installs YC-Boot/YC-Health/YC-KeyGuard.' Red
  $fail += 'legacytasks'
} else {
  $three = @('YC-Boot','YC-Health','YC-KeyGuard' |
             Where-Object { Get-ScheduledTask -TaskName $_ -EA SilentlyContinue })
  if($three.Count -eq 3){ Say 'tasks        : YC-Boot, YC-Health, YC-KeyGuard' Green }
  else { Say ('tasks        : expected 3, found ' + $three.Count + ' (' + ($three -join ', ') + ')') Red
         $fail += 'tasks' }
}

# ---- 15. C:\Scripts must not ship build/debug junk -------------------------
# v259 shipped 1,180 files / 2 GB here: 230 Linux .sh, 16 .py, GoldenImage.ps1,
# the seal tooling, _stage\, .done\ and a stale 305 MB copy of the Chocolatey
# lib tree. Run Clean-Scripts.ps1 -Apply before sealing.
$junk = @()
$nsh = @(Get-ChildItem 'C:\Scripts' -Filter '*.sh' -File -EA SilentlyContinue).Count
$npy = @(Get-ChildItem 'C:\Scripts' -Filter '*.py' -File -EA SilentlyContinue).Count
if($nsh){ $junk += "$nsh .sh" }
if($npy){ $junk += "$npy .py" }
foreach($d in '_stage','.done','lib-bad','helpers','redirects','KVM-Tooling'){
  if(Test-Path "C:\Scripts\$d"){ $junk += $d }
}
foreach($f in 'GoldenImage.ps1','GoldenImage-v239-yc.ps1','Prep-Seal.ps1'){
  if(Test-Path "C:\Scripts\$f"){ $junk += $f }
}
# setupdownloader_*.exe is NOT junk - Bitdefender-Register.ps1 finds it by glob
# and runs it with /bdparams /silent. Its absence is the fault, not its presence.
if(-not @(Get-ChildItem 'C:\Scripts' -Filter 'setupdownloader_*' -File -EA SilentlyContinue).Count){
  Say 'bitdefender  : setupdownloader_*.exe MISSING - bitdefender-register will fail' Yellow
}
if($junk.Count){
  Say ('scripts dir  : JUNK PRESENT - ' + ($junk -join ', ')) Red
  Say '               run Clean-Scripts.ps1 -Apply first' Red
  $fail += 'scriptsjunk'
} else {
  $sc = @(Get-ChildItem 'C:\Scripts' -Recurse -File -Force -EA SilentlyContinue)
  Say ("scripts dir  : clean ({0} files, {1:N0} MB)" -f $sc.Count, (($sc|Measure-Object Length -Sum).Sum/1MB)) Green
}

# ---- 16. build progress marker on the PUBLIC DESKTOP -----------------------
# Set-Progress drops "!<step>.txt" on C:\Users\Public\Desktop so you can see build
# state from the console. GoldenImage.ps1's own Clear-Progress call lives inside
# an unreachable function (dead code left over from the old auto-seal design), so
# it never actually runs on the real manual-seal path - every v259 clone shipped
# with "!Build complete - awaiting MANUAL AppX + seal.txt" sitting on the
# customer's desktop. THIS script is the last gate before sysprep, so it is the
# one that must actually remove it - report it here, then remove it for real in
# CLEANUP below (do not just abort and rely on a human to remember).
$progs = @(Get-ChildItem 'C:\Users\Public\Desktop' -Filter '!*' -Force -EA SilentlyContinue)
if($progs.Count){
  Say ('desktop      : ' + $progs.Count + ' build marker(s) on Public Desktop - will be removed in cleanup') Yellow
  foreach($p in $progs){ Say "               $($p.Name)" Yellow }
} else { Say 'desktop      : no build markers' Green }

# ---- 17. the app payload actually installed --------------------------------
# win2019bios shipped with 13 apps instead of 30 and only 3 choco packages,
# because step 16 logged [ OK ] without checking $LASTEXITCODE, wrote its .done
# marker, and every later run SKIPped it. setup-log.txt looked perfectly healthy.
$choco = 'C:\ProgramData\chocolatey\bin\choco.exe'
if(Test-Path $choco){
  $o = @(& $choco list --local-only --limit-output 2>$null)
  if(-not $o.Count){ $o = @(& $choco list --limit-output 2>$null) }
  $have = @($o | ForEach-Object { ($_ -split '\|')[0] } | Where-Object { $_ })
  $want = 'powershell-core','googlechrome','git','python','openssl','vcredist140',
          'vcredist2015','putty','winscp','sysinternals','winrar','everything','7zip'
  $miss = @($want | Where-Object { $have -notcontains $_ })
  if($miss.Count){
    Say ('choco pkgs   : MISSING ' + ($miss -join ', ')) Red
    Say '               step 16 did not complete - delete C:\Scripts\.done\16_Install_Choco_Packages.done and re-run GoldenImage.ps1' Red
    $fail += 'chocopkgs'
  } else { Say ("choco pkgs   : all {0} present" -f $want.Count) Green }
} else { Say 'choco pkgs   : chocolatey not installed' Red; $fail += 'chocopkgs' }

# ---- 18. customer-facing ---------------------------------------------------
$rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' -EA SilentlyContinue)
if($rel.ShutdownReasonOn -eq 0 -and $rel.ShutdownReasonUI -eq 0){ Say 'tracker      : disabled' Green }
else { Say "tracker      : ACTIVE (On=$($rel.ShutdownReasonOn) UI=$($rel.ShutdownReasonUI))" Red; $fail += 'tracker' }

$ul = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList' -EA SilentlyContinue)
if($ul.CloudinitAdmin -eq 0){ Say 'cloudinitadm : hidden' Green }
else { Say 'cloudinitadm : NOT hidden - it will show on the logon screen' Red; $fail += 'cloudinitadmin' }
if($ul.PSObject.Properties.Name -contains 'chadmin'){ Say 'chadmin      : HIDDEN - it is the fallback account, must stay visible' Red; $fail += 'chadmin' }
$ch = Get-LocalUser chadmin -EA SilentlyContinue
if($ch -and $ch.Enabled){ Say 'chadmin      : enabled (fallback intact)' Green }
else { Say 'chadmin      : missing or disabled' Red; $fail += 'chadmin' }

foreach($d in 'C:\Program Files\Nmap','C:\Program Files\AutoHotkey','C:\Program Files (x86)\Nmap','C:\Program Files (x86)\AutoHotkey'){
  if(Test-Path $d){ Say "suspect tool : $d still present (AV/EDR flags it)" Red; $fail += 'suspecttools' }
}

$r0 = Get-AppxRisk
Say ("appx         : notProvisioned={0} otherProfile={1}" -f $r0.NotProvisioned, $r0.OtherProfile.Count)
foreach($o in $r0.OtherProfile){ Say "               RISK $o" Yellow }

Say '======================================' Cyan
if($fail.Count){ Say ('ABORT: ' + ($fail -join ', ')) Red; Exit-Seal 1 }
if($WhatIf){ Say 'WhatIf - nothing changed, no cleanup performed.' Cyan; Exit-Seal 0 }

# ============================ CLEANUP ======================================
# Everything below is preparation only. AppX and sysprep are yours to run.
Say 'CLEANUP - secrets, build artefacts, host keys, event logs.' Cyan

foreach($x in $secrets){ Remove-Item $x -Force -EA SilentlyContinue }
$still = @($secrets | Where-Object { Test-Path $_ })
if($still.Count){ Say ('WARNING: could not delete ' + ($still -join ', ')) Red } else { Say 'secrets wiped' Green }

Get-ScheduledTask -TaskName 'GIBuild'   -EA SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -EA SilentlyContinue
Get-ScheduledTask -TaskName 'YCSYSPREP' -EA SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -EA SilentlyContinue
Remove-Item 'C:\Scripts\.phase','C:\Scripts\.reboot-pending','C:\Scripts\.prereboot-done' -Force -EA SilentlyContinue

# build progress marker(s) on the Public Desktop - must NEVER ship (see check 16 above). This is the
# second/real gate: GoldenImage.ps1's own Clear-Progress is unreachable, so remove it here for real.
$progsClean = @(Get-ChildItem 'C:\Users\Public\Desktop' -Filter '!*' -Force -EA SilentlyContinue)
if($progsClean.Count){
  foreach($p in $progsClean){ Add-Content 'C:\Scripts\clean-discarded.txt' ("{0} | {1} bytes | build progress marker, must not ship" -f $p.FullName, $p.Length) -Encoding ascii -EA SilentlyContinue }
  $progsClean | Remove-Item -Force -EA SilentlyContinue
  Say ('desktop marker(s) removed: ' + $progsClean.Count) Green
} else { Say 'desktop markers: none to remove' Green }
# per-clone host keys - sshd regenerates these on first boot
Remove-Item 'C:\ProgramData\ssh\ssh_host_*' -Force -EA SilentlyContinue
Get-ChildItem 'C:\Users\*\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt' -EA SilentlyContinue |
  Remove-Item -Force -EA SilentlyContinue
Say 'build artefacts + host keys removed'

# LiveId/Analytic and other protected channels can NEVER be cleared and report
# "Access is denied" on stderr. Swallow both streams - this is not a failure.
$n = 0
foreach($l in (& wevtutil el 2>$null)){ & wevtutil cl "$l" 2>&1 | Out-Null; $n++ }
Say "event logs cleared ($n channels attempted)"

# stale log from any previous attempt, so what you read next is this run only
Remove-Item 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Force -EA SilentlyContinue

Say ''
Say '=========== CLEANUP DONE - NOW RUN THESE BY HAND ===========' Cyan
Say 'Paste the block below into THIS session. Errors from AppX-Strip are' Yellow
Say 'expected and harmless - run all four passes regardless, then sysprep.' Yellow
Say ''
@'
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\AppX-Strip.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\AppX-Strip.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\AppX-Strip.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\AppX-Strip.ps1
#EVEN IF ERROR
& "$env:WINDIR\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /unattend:"C:\Scripts\Unattend-Seal.xml"
'@ | Write-Host -ForegroundColor White
Say ''
Say 'The VM powers itself off when sysprep finishes. Capture the template from' Cyan
Say 'the powered-off ROOT volume. DO NOT boot it again.' Cyan
Say 'Optional, in a SECOND window while the block above runs in this one:' Cyan
Say '  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1 -WatchSeal' Cyan
Say '  -> waits for ImageState=RESEAL_TO_OOBE (up to 20 min) and reports SEAL OK / SEAL FAILED.' Cyan
Say '  Do NOT judge success by setuperr.log being empty - EFI sysprep always logs benign lines there.' Cyan
Exit-Seal 0
