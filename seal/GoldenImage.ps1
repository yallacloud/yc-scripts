<#  GoldenImage.ps1  -  ONE-FILE automated Windows Server golden-image builder.
    Version 2.30 |  2026-07-25  |  PowerShell 5.1+  |  Windows Server 2016 / 2019 / 2022 / 2025 (Std Eval)

    PLATFORM: NOT ASKED. This build is HYPERVISOR-NEUTRAL by design.
      DRIVERS  - virtio (pnputil) AND VMware PVSCSI/VMXNET3/SVGA (ADDLOCAL=Drivers)
                 are BOTH always injected, and both installer sets are kept forever
                 in C:\Scripts on BOTH platforms so a guest can migrate either way.
      AGENTS   - qemu-ga, virtio-win-guest-tools and VMware Tools are only STAGED.
                 PreSeal-Agents.ps1 installs the right pair AFTER the presealagent
                 snapshot, detecting the hypervisor it actually booted on.
      RESULT   - the ~4h Windows Update + app batch is run ONCE and forked to both
                 KVM and VMware, and a broken agent install costs 20 minutes on a
                 branch instead of a full rebuild.

    ONE RUN, NO MONITORING:
      1) Put THIS FILE in C:\Scripts and run it once in an elevated PowerShell.
      2) Answer the one-time menu (credentials, optional components, SSH keys).
         Answers are saved to an ANSWER FILE (C:\Scripts\gi-settings.ps1) and the password is
         stored DPAPI-ENCRYPTED (C:\Scripts\.gi-pw) so SYSTEM can resume after every reboot.
      3) Walk away. It patches (reboots), configures, does one pre-seal reboot, seals
         (sysprep /generalize /shutdown). VM powers OFF = golden image is ready to capture.

    RE-RUN OPTIONS:  -Reset   (wipe saved answers + build state and start clean).
                     -Resume  (alias -Retry): halt a STUCK/running instance + its worker jobs and continue
                              from the last completed task (uses .phase + .done; nothing done is redone).
    ANSWER-FILE MODE: if gi-settings.ps1 + .gi-pw already exist, they are used with NO prompt
      (drop a pre-made pair in C:\Scripts for fully zero-touch/ISO builds).

    Optional components are STAGED only (installer + a <name>-register command on PATH); they are
    NOT installed during the build. Register them per-deployment on each clone. Run <name>-register -Help.
#>
#Requires -RunAsAdministrator
param([switch]$Reset,[switch]$Resume,[switch]$Retry,[switch]$Status,[switch]$Help)

if($Help){
@"
GoldenImage.ps1  -  ONE-FILE automated Windows Server golden-image builder (KVM + VMware).
USAGE:
  powershell -File C:\Scripts\GoldenImage.ps1 [-Reset] [-Resume | -Retry] [-Status] [-Help]
PARAMETERS:
  -Reset    Wipe saved answers + build state (gi-settings.ps1, .gi-pw, .phase, .done) and start clean.
  -Resume   (alias -Retry) Halt a stuck/running instance + its worker jobs and continue from the last
            completed step (uses .phase + .done; nothing already done is redone).
  -Status   Read-only verdict: ImageState / GeneralizationState / build phase. Changes nothing, does
            not relaunch. Safe on a running VM; on a powered-off sealed template check the hypervisor
            instead of booting it (booting a template consumes its generalized state).
  -Help     Show this help and exit.
EXAMPLES:
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\GoldenImage.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\GoldenImage.ps1 -Status
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\GoldenImage.ps1 -Resume
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\GoldenImage.ps1 -Reset
"@ | Write-Host
  exit 0
}

# MUST run under Windows PowerShell 5.1, not pwsh 7. Under 7:
#   - BitsTransfer, Appx and DISM proxy through a WinPSCompat session and return
#     DESERIALIZED objects, so property/type checks in this script silently fail
#   - Get-AppxPackage -AllUsers under-reports, which is the direct cause of
#     sysprep failing 0x8007001f after a "clean" AppX strip
# Auto-relaunch rather than just complaining, so a wrong invocation cannot
# quietly produce a half-built image.
if($PSVersionTable.PSEdition -eq 'Core'){
  $ps51 = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  $sw = @(); foreach($k in $PSBoundParameters.Keys){ if($PSBoundParameters[$k] -eq $true){ $sw += "-$k" } }
  Write-Host "Running under PowerShell $($PSVersionTable.PSVersion) - relaunching in Windows PowerShell 5.1" -ForegroundColor Yellow
  & $ps51 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @sw
  exit $LASTEXITCODE
}

$ErrorActionPreference='Continue'
$S='C:\Scripts'; New-Item -ItemType Directory -Force $S | Out-Null
if($Retry){ $Resume=$true }                    # -Retry is an alias for -Resume

# ---- -Status: report whether THIS VM is sealed / stuck / still building, with a plain verdict. Reads the
#      definitive Windows registry state (does NOT change anything, does NOT relaunch). Run it on a VM you are
#      willing to have on; on a truly-sealed template that is powered OFF, check the HYPERVISOR (shut off = sealed)
#      instead of booting it (booting a template consumes its generalized state). ----
if($Status){
  # NOT named GV: 'gv' is the built-in ALIAS for Get-Variable, and aliases beat
  # functions in PowerShell's command resolution order, so the alias won and
  # -Status printed two ParameterBindingExceptions with empty ImageState.
  # Same class of bug the Yallacloud.ps1 header already warns about.
  function Get-RegVal($p,$n){ try{ (Get-ItemProperty $p -Name $n -EA Stop).$n }catch{ '(none)' } }
  $img=Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' 'ImageState'
  $gs =Get-RegVal 'HKLM:\SYSTEM\Setup\Status\SysprepStatus' 'GeneralizationState'
  $os=(Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).Caption
  $ph="$S\.phase"; $Done="$S\.done"
  $phase=if(Test-Path $ph){ (Get-Content $ph -Raw).Trim() }else{ '(none)' }
  $dc=@(Get-ChildItem $Done -Filter *.done -EA SilentlyContinue).Count
  $sp="$env:WINDIR\System32\Sysprep\Panther\setupact.log"; $er="$env:WINDIR\System32\Sysprep\Panther\setuperr.log"
  Write-Host ("==== GoldenImage STATUS  |  "+$env:COMPUTERNAME+"  |  "+$os+" ====") -ForegroundColor Cyan
  Write-Host ("  ImageState          : "+$img)
  Write-Host ("  GeneralizationState : "+$gs+"   (7=generalize complete, 3=stuck mid-generalize)")
  Write-Host ("  build phase (.phase): "+$phase+"   | config steps done: "+$dc)
  Write-Host ("  GoldenImage.ps1 here: "+([bool](Test-Path "$S\GoldenImage.ps1"))+"   GIBuild task: "+([bool](Get-ScheduledTask GIBuild -EA SilentlyContinue)))
  if("$img" -match 'GENERALIZE_RESEAL_TO_OOBE'){
    Write-Host '  VERDICT: SEALED - sysprep /generalize completed. This IS a finished template. Power off (if on) and CAPTURE it. Do NOT keep booting it.' -ForegroundColor Green
  } elseif("$gs" -eq '3'){
    Write-Host '  VERDICT: NOT sealed - STUCK mid-generalize (0x8007001f). Fix: start TrustedInstaller,msiserver,cryptsvc then re-run sysprep (see README "recovering a stuck seal").' -ForegroundColor Red
  } elseif($phase -eq 'seal'){
    Write-Host '  VERDICT: BUILD COMPLETE - waiting for the MANUAL seal. Nothing is stuck; the build script' -ForegroundColor Green
    Write-Host '           stops here by design. Run Seal-Manual.ps1 -WhatIf, then AppX-Strip x4 + sysprep at a console.' -ForegroundColor Green
  } elseif($phase -ne '(none)'){
    Write-Host ('  VERDICT: still BUILDING (phase='+$phase+'). Reboot or run  GoldenImage.ps1 -Resume  to continue to the seal.') -ForegroundColor Yellow
  } else {
    Write-Host '  VERDICT: normal running OS (not mid-build). Either never sealed, or a sealed template that has since been booted (which consumed its generalize).' -ForegroundColor Yellow
  }
  if(Test-Path $er){ $t=Get-Content $er -Tail 12 -EA SilentlyContinue; if($t){ Write-Host '  --- sysprep setuperr.log (tail) ---' -ForegroundColor DarkGray; $t | ForEach-Object { Write-Host ('    '+$_) -ForegroundColor DarkGray } } }
  exit 0
}
# ---- PORTABLE: run this script from ANYWHERE (Desktop / USB / share). If it is not already running from
#      C:\Scripts, copy itself + any answer files sitting beside it into C:\Scripts and relaunch from there,
#      so every C:\Scripts-relative path and the self-resume task stay consistent. ----
if($PSCommandPath -and ((Split-Path $PSCommandPath -Parent) -ne $S)){
  Copy-Item $PSCommandPath (Join-Path $S 'GoldenImage.ps1') -Force -EA SilentlyContinue
  foreach($f in 'gi-settings.ps1','.gi-pw','gi-pw.seed','Setup-Observability.ps1','Setup-HealthMonitors.ps1','_yc-lib.ps1'){ $src=Join-Path (Split-Path $PSCommandPath -Parent) $f; if(Test-Path $src){ Copy-Item $src (Join-Path $S $f) -Force -EA SilentlyContinue } }
  Write-Host "  [portable] copied to $S - relaunching from there..." -ForegroundColor Cyan
  $fwd=@(); if($Reset){ $fwd+='-Reset' }; if($Resume){ $fwd+='-Resume' }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $S 'GoldenImage.ps1') @fwd
  exit $LASTEXITCODE
}
# ---- RESUME / RETRY: a prior build may be STUCK (a hung update, a wedged download job, a frozen console) or
#      just stopped. -Resume (alias -Retry) forcibly halts any OTHER running GoldenImage instance + its worker
#      jobs, then this process falls straight through into the phase/step state machine and continues from the
#      exact task left in .phase + .done (nothing is redone). No prompts - safe to fire from a scheduled task. ----
if($Resume){
  Write-Host '  [resume] halting any running GoldenImage instance and continuing from the last task...' -ForegroundColor Yellow
  # end the self-resume task run GRACEFULLY first so its RestartCount does not respawn a competing instance
  try{ Stop-ScheduledTask -TaskName 'GIBuild' -EA SilentlyContinue }catch{}
  Start-Sleep 2
  # then force-kill any OTHER GoldenImage.ps1 process still alive (manual launch, wedged console) - never self
  try{ Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
         Where-Object { $_.CommandLine -like '*GoldenImage.ps1*' -and $_.ProcessId -ne $PID } |
         ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }catch{}
  # drop any orphaned worker jobs (stuck download / WU / dismount jobs) left behind by the halted instance
  try{ Get-Job -EA SilentlyContinue | Where-Object { $_.State -in 'Running','Suspended','NotStarted' } | ForEach-Object { Stop-Job $_ -EA SilentlyContinue; Remove-Job $_ -Force -EA SilentlyContinue } }catch{}
  # clear a stale reboot latch + stuck WU-cycle marker so the state machine is not blocked/looping
  Remove-Item "$S\.reboot-pending" -Force -EA SilentlyContinue
}
$Scripts=$S                                   # alias used by step bodies
$ph="$S\.phase"; $blog="$S\build.log"; $slog="$S\setup-log.txt"
$Done="$S\.done"; New-Item -ItemType Directory -Force $Done | Out-Null
$Lock="$S\.reboot-pending"; $setFile="$S\gi-settings.ps1"; $pwFile="$S\.gi-pw"
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12   # HTTPS on Server 2016

# ===== non-secret tunables (safe defaults) =====
$Force          = $false     # $true = ignore .done markers and re-run every step
$ForceRdpNlaOff = $false     # NLA auto-OFF on 2016 (CredSSP); $true = force off on any OS
$VirtioIsoUrl   = ''         # blank = auto-pick the pinned 0.1.271 ISO (ERROR 63)
# ACRONIS: this URL is BOTH version-pinned AND datacenter-specific, so it rots.
# Get the current one from the Acronis console: Devices > + Add > Windows agent,
# copy the download link. If this 404s the agent is silently NOT staged - which
# is exactly what happened on the v258 build.
$AcronisAgentUrl = 'https://ae01-cloud.acronis.com/download/u/baas/4.0/26.7.42773/CyberProtect_AgentForWindows_web.exe'
# RESOLVED, not pinned. The hard-coded build above goes stale within weeks - 26.7.42773
# 404'd on the 2026-08-10 build, exactly as the comment predicted. The payload side solved
# this with a `dirindex` resolver; this is the same thing in PowerShell. Only the version
# FOLDER changes - the exe name is constant. Falls back to the pinned URL above.
function Resolve-AcronisUrl {
  $index = 'https://ae01-cloud.acronis.com/download/u/baas/4.0/'
  try {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $html = (Invoke-WebRequest $index -UseBasicParsing -TimeoutSec 60).Content
    # href="26.7.42848/" - take the numerically highest, not the lexically highest
    $vers = [regex]::Matches($html,'href="(\d+(?:\.\d+)+)/"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    if(-not $vers){ return $null }
    $best = $vers | Sort-Object { ,@($_ -split '\.' | ForEach-Object {[int]$_}) } | Select-Object -Last 1
    return ($index + $best + '/CyberProtect_AgentForWindows_web.exe')
  } catch { return $null }
}
$resolved = Resolve-AcronisUrl
if($resolved){ $AcronisAgentUrl = $resolved }
$VMwareToolsUrl = 'https://packages-prod.broadcom.com/tools/releases/12.5.4/x64/VMware-tools-12.5.4-24964629-x64.exe'  # 12.5.4 = universal: PVSCSI/VMXNET3/SVGA drivers install on Server 2016/2019/2022/2025 (13.1 dropped 2016/2019 driver INFs)
$InstallVMwareTools = $true  # ALWAYS install VMware drivers-only (PVSCSI/VMXNET3/SVGA) regardless of platform, so ONE image boots on KVM AND VMware. Only the ACTIVE agent differs (qemu-ga on KVM, VMware Tools on VMware).
$InstallDotNet35= $true      # .NET 3.5 (local sources\sxs or auto-skip to avoid slow WU fetch)
$DotNet35Source = ''         # e.g. 'D:\sources\sxs'
# Optional-component installers (STAGED only). Verified-latest 2026-07; *-register finds the MSI by
# wildcard so bumping a version here never breaks registration. All support Server 2016-2025 x64.
$WazuhMsiUrl    = 'https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.7-1.msi'                        # Wazuh 4.14.7 (hermes binary audit rev 1.1, 2026-08-04)
$GlpiAgentMsiUrl= 'https://github.com/glpi-project/glpi-agent/releases/download/1.18/GLPI-Agent-1.18-x64.msi' # GLPI Agent 1.18
$OsqueryMsiUrl  = 'https://github.com/osquery/osquery/releases/download/5.23.1/osquery-5.23.1.msi'         # osquery 5.23.1
$Site24x7MsiUrl = 'https://staticdownloads.site24x7.com/server/Site24x7WindowsAgent.msi'                  # Site24x7 Windows agent
$ZabbixMsiUrl   = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.0/7.0.29/zabbix_agent2-7.0.29-windows-amd64-openssl.msi'  # Zabbix Agent 2 7.0.29 LTS (rev 1.1)
$NtfyTopic      = 'https://ntfy.sh/9890122212'   # build notifications (start + before sysprep). Blank to disable.
# ================================================

# ---------- YallaCloud shared logging (documented estate-wide scheme: transcript tagged
#            [YALLACLOUD][<cmd>] at C:\Scripts\<cmd>.log via _yc-lib.ps1's Start-YcLog/Write-YcLog,
#            mirrored to the Application event log under source YallaCloud, EventIDs
#            1000 start / 1001 info-ok / 1002 warn / 1003 error / 1099 end. Best-effort and additive:
#            this NEVER replaces build.log/setup-log.txt below (the per-step RUN/OK/FAIL/SKIP record
#            stays authoritative for the build state machine) and must never fail the build if the
#            shared lib is not yet staged (first-ever run, before the catalog is copied in) or Event
#            Log access is unavailable. ----------
$script:YcLibLoaded = $false
$YcLibPath = Join-Path $S '_yc-lib.ps1'
if(Test-Path $YcLibPath){ try{ . $YcLibPath; Start-YcLog 'GoldenImage'; $script:YcLibLoaded = $true }catch{} }

# ---------- logging + UI (PS 5.1 safe, ASCII only) ----------
function OL($m){ $s="$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $m"; Write-Host $s -f Gray; Add-Content $blog $s }
function Log($m){ $s="$(Get-Date -f HH:mm:ss)  $m"; Write-Host $s -f DarkCyan; Add-Content $slog $s
  if($script:YcLibLoaded -and $m -match '^\[FAIL\]'){ Write-YcLog $m 'ERROR' } }
$GIVER='v2.34'
function Banner {
  Write-Host ''
  Write-Host '  ============================================================' -f Cyan
  Write-Host ("   WINDOWS SERVER  GOLDEN IMAGE BUILDER            "+$GIVER) -f White
  Write-Host '   2016 / 2019 / 2022 / 2025  Std Eval   |   KVM + VMware' -f DarkGray
  Write-Host '  ============================================================' -f Cyan
}
function Section($t){ $d=44-$t.Length; if($d -lt 3){$d=3}; Write-Host ''; Write-Host ("  --- "+$t+" "+('-'*$d)) -f Yellow
  if($script:YcLibLoaded){ Write-YcLog ("phase: "+$t) } }
function Ok($m){   Write-Host "   [ OK ]  $m" -f Green }
function Info($m){ Write-Host "   [INFO]  $m" -f Gray }
function Warn($m){ Write-Host "   [WARN]  $m" -f Yellow }
function Err($m){  Write-Host "   [FAIL]  $m" -f Red }
# ---- consistent interactive prompts (clear default + input validation; used only in the one-time menu) ----
# Ask-YN: the CAPITAL letter in the hint is what pressing Enter selects; accepts y/yes/n/no in ANY case and
#   re-asks on anything else, so a stray key never silently mis-sets an option.
function Ask-YN([string]$q,[bool]$default){
  $hint = if($default){'[Y/n]'}else{'[y/N]'}
  while($true){
    $a=([string](Read-Host ("    $q $hint"))).Trim()
    if($a -eq ''){ return $default }
    if($a -match '^(y|yes)$'){ return $true }
    if($a -match '^(n|no)$'){ return $false }
    Write-Host '      -> type Y or N (or press Enter for the CAPITALISED default)' -f DarkYellow
  }
}
# Ask-Text: shows the default in [brackets]; Enter keeps it.
function Ask-Text([string]$q,[string]$default){
  if($default -ne ''){ $a=([string](Read-Host ("    $q [$default]"))).Trim(); if($a -eq ''){ return $default } else { return $a } }
  else { return ([string](Read-Host ("    $q"))).Trim() }
}
# desktop progress marker: a single file on the Public Desktop whose NAME shows current status;
# it is re-created (renamed) on each update and wiped just before sysprep so the template is clean.
$ProgDir='C:\Users\Public\Desktop'
# short prefix so the desktop file name is easy to read at a glance; only filename-legal chars are used
# (Windows forbids \ / : * ? " < > | - they are stripped below). Files look like:  !12-34 Install-Choco.txt
$ProgPfx='!'
function Set-Progress($label){ try{ Get-ChildItem $ProgDir -Filter ($ProgPfx+'*.txt') -Force -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue; $safe=(($label -replace '[\\/:*?"<>|]','-') -replace '\s+',' ').Trim(); if($safe.Length -gt 60){$safe=$safe.Substring(0,60)}; Set-Content (Join-Path $ProgDir ($ProgPfx+$safe+'.txt')) $label -Encoding ascii -EA SilentlyContinue }catch{} }
function Clear-Progress { try{ Get-ChildItem $ProgDir -Filter ($ProgPfx+'*.txt') -Force -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue }catch{} }
# public IP (cached once); tried across 3 providers so a single outage cannot blank the field
function Get-PubIP { if($script:GIpubip){ return $script:GIpubip }
  foreach($u in 'https://api.ipify.org','https://ifconfig.me/ip','https://icanhazip.com'){ try{ [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $ip=([string](Invoke-RestMethod $u -TimeoutSec 8)).Trim(); if($ip -match '\d{1,3}(\.\d{1,3}){3}'){ $script:GIpubip=$Matches[0]; return $script:GIpubip } }catch{} }
  return 'unknown' }
# push a build notification to the ntfy topic (best-effort HTTP; works on 2016-2025 with no CLI dependency).
# EVERY message auto-appends host + OS + public IP so multiple concurrent builds are always distinguishable.
function Send-Ntfy($title,$body){ if(-not $NtfyTopic){ return }; try{ [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $osTxt=if($OS){ [string]$OS }else{ [string](Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).Caption }
  $full=([string]$body)+"`n----`nhost: $env:COMPUTERNAME`nos: $osTxt`npublic-ip: $(Get-PubIP)"
  Invoke-RestMethod -Uri $NtfyTopic -Method Post -Body $full -Headers @{ Title=[string]$title } -TimeoutSec 15 | Out-Null }catch{} }

# ---------- network ----------
function Test-Net(){ foreach($u in 'https://www.microsoft.com/','https://community.chocolatey.org/','https://github.com/'){ try{ Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 12 | Out-Null; return $true }catch{} }; return $false }
function Wait-Net([int]$sec=300){ $t=0; while($t -lt $sec){ if(Test-Net){return $true}; Start-Sleep 10; $t+=10 }; return $false }
# ---------- POWER: Stop-Computer / Restart-Computer are NOT reliable here ----------
# Evidence from the 2026-08-11 win2019bios build: build.log printed
#   00:13:55 POST-UPDATE SNAPSHOT PAUSE ... Powering off
#   00:48:06 pre-seal reboot ... will AUTO-RESUME into SEAL
# and the VM did NEITHER - it sat there until a human noticed (7 min, then 11 h).
# Stop-Computer/Restart-Computer go through WMI Win32_Shutdown and fail SILENTLY
# when a service blocks shutdown or the caller's token lacks SeShutdownPrivilege
# in that session. shutdown.exe does not have that failure mode. Belt and braces:
# try the cmdlet, then shutdown.exe, then the Win32 API - and LOG which one ran,
# so build.log can never again claim a power event that did not happen.
function Invoke-Power([ValidateSet('off','restart')]$mode,[int]$delay=5){
  $what = if($mode -eq 'off'){'POWER OFF'}else{'RESTART'}
  OL ("$what requested - issuing now (watch for the confirmation line below)")
  try { if($mode -eq 'off'){ Stop-Computer -Force -EA Stop } else { Restart-Computer -Force -EA Stop }
        OL "  $what issued via cmdlet" }
  catch { OL "  cmdlet failed: $($_.Exception.Message)" }
  Start-Sleep 3
  # if we are still alive the cmdlet did not take - use shutdown.exe
  $flag = if($mode -eq 'off'){'/s'}else{'/r'}
  OL "  still running after cmdlet - falling back to shutdown.exe $flag /f /t $delay"
  & "$env:WINDIR\System32\shutdown.exe" $flag /f /t $delay /c "GoldenImage $what" 2>&1 | Out-Null
  Start-Sleep ($delay + 20)
  OL "  STILL RUNNING after shutdown.exe - the OS is refusing to power down."
  OL "  Do it by hand now:  shutdown $flag /f /t 0    (then continue per the runbook)"
  Send-Ntfy "GoldenImage: $what FAILED" "Both Stop/Restart-Computer and shutdown.exe were ignored on $env:COMPUTERNAME. Manual power action needed."
}

function Get-File($url,$out,$min=4096,$timeout=1200){
  # PRE-STAGED SHORT-CIRCUIT: if the file is already here at a plausible size, use it and do not
  # re-download. This is what makes an offline build possible - copy /yc-primary/goldenstuff into
  # C:\Scripts (FLATTENED, vendor filenames preserved) and every matching Get-File call is a no-op.
  # Same test the vc_redist call sites already used inline; now applied to every download.
  # Caveat: no version check. A stale pre-staged file is used forever. Stage from goldenstuff,
  # which is sha256-verified against MANIFEST.tsv, not from a hand-assembled folder.
  if((Test-Path $out) -and (Get-Item $out).Length -ge $min){
    Log ("  pre-staged, skipping download: " + (Split-Path $out -Leaf)); return $true }
  # each attempt runs in a timeout-bounded job so a stuck BITS/HTTP transfer can NEVER hang the build forever
  for($i=1;$i-le4;$i++){
    if((Test-Path $out) -and (Get-Item $out).Length -lt $min){ Remove-Item $out -Force -EA SilentlyContinue }   # drop incomplete before retry
    $j=Start-Job { param($u,$o)
      [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
      try{ Import-Module BitsTransfer -EA SilentlyContinue; Start-BitsTransfer -Source $u -Destination $o -EA Stop }catch{ try{ Invoke-WebRequest $u -OutFile $o -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 300 }catch{} }
    } -ArgumentList $url,$out
    if(-not (Wait-Job $j -Timeout $timeout)){ Stop-Job $j -EA SilentlyContinue; Log "  download stuck > ${timeout}s (killed) - retry $i/4: $url" }
    Remove-Job $j -Force -EA SilentlyContinue
    if((Test-Path $out) -and (Get-Item $out).Length -ge $min){ return $true }
    Start-Sleep 5
  }
  Log "  MISS (after 4 tries) $url"; return $false }

# ---------- encrypted credential store (DPAPI LocalMachine; only decrypts on THIS VM) ----------
Add-Type -AssemblyName System.Security -EA SilentlyContinue
function Protect-GIString([string]$plain){ $b=[Text.Encoding]::Unicode.GetBytes($plain); [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($b,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)) }
function Unprotect-GIString([string]$b64){ $p=[Convert]::FromBase64String($b64); [Text.Encoding]::Unicode.GetString([Security.Cryptography.ProtectedData]::Unprotect($p,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)) }
# true only if .gi-pw exists AND decrypts on THIS machine (DPAPI is machine-bound; a copied/cloned blob fails)
function Test-GIpw { if(-not (Test-Path $pwFile)){ return $false }; try{ [void](Unprotect-GIString ((Get-Content $pwFile -Raw).Trim())); return $true }catch{ return $false } }

$OS=(Get-CimInstance Win32_OperatingSystem).Caption
$Tag=switch -Regex ($OS){'2016'{'2k16'}'2019'{'2k19'}'2022'{'2k22'}'2025'{'2k25'}default{'2k22'}}

# ---------- config: ANSWER FILE if present, else one-time menu ----------
function Get-GIConfig {
  if($Reset){ Remove-Item $setFile,$pwFile -Force -EA SilentlyContinue; Remove-Item $ph,$Lock,"$S\.wu-done","$S\.wu-cycles","$S\.postwu-snap","$S\.prereboot-done" -Force -EA SilentlyContinue; Remove-Item $Done -Recurse -Force -EA SilentlyContinue; New-Item -ItemType Directory -Force $Done|Out-Null }
  # answer file present (gi-settings.ps1) but NO usable encrypted password on THIS machine:
  # .gi-pw missing, OR copied from another VM / stale after a clone-revert so DPAPI (machine-bound)
  # cannot decrypt it ("Key not valid for use in specified state"). Re-materialize it here.
  if((Test-Path $setFile) -and -not (Test-GIpw)){
    if(Test-Path $pwFile){ Warn 'Stored password cannot be decrypted on THIS machine (DPAPI is machine-bound; likely copied/cloned) - re-creating it.'; Remove-Item $pwFile -Force -EA SilentlyContinue }
    $seed="$S\gi-pw.seed"
    if(Test-Path $seed){
      $pt=((Get-Content $seed -Raw) -replace "`r","" -replace "`n","")
      Protect-GIString $pt | Set-Content $pwFile -Encoding ascii; Remove-Item $seed -Force -EA SilentlyContinue
      Info 'Consumed gi-pw.seed -> encrypted password store created for THIS VM (seed deleted).'
    } elseif([Environment]::UserInteractive){
      Info 'Enter the additional-admin password for THIS VM (other settings reused from the answer file):'
      do{ $s1=Read-Host '    Password' -AsSecureString; $s2=Read-Host '    Confirm password' -AsSecureString
          $p1=[Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1))
          $p2=[Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2))
          if(-not $p1 -or $p1 -ne $p2){ Warn 'passwords empty or do not match - try again' } } while(-not $p1 -or $p1 -ne $p2)
      Protect-GIString $p1 | Set-Content $pwFile -Encoding ascii
    } else { throw 'Answer file present but no decryptable .gi-pw and no gi-pw.seed (non-interactive). Drop C:\Scripts\gi-pw.seed containing the password, or run -Reset interactively.' }
  }
  if((Test-Path $setFile) -and (Test-GIpw)){
    Info "Answer file found -> using saved settings (no prompt).  ($setFile)"
  } else {
    if(-not [Environment]::UserInteractive){ throw 'No answer file (gi-settings.ps1/.gi-pw) and session is non-interactive. Run once interactively.' }
    $global:JustCreatedAnswerFile = $true
    Banner
    Section 'Platform / Hypervisor  (not asked any more - see below)'
    Write-Host '    This build is HYPERVISOR-NEUTRAL. You are no longer asked to pick one,' -f DarkGray
    Write-Host '    because the answer used to be needed 4 hours before it mattered.' -f DarkGray
    Write-Host ''
    Write-Host '      DRIVERS   - BOTH sets are always injected and always kept:' -f White
    Write-Host '                  virtio (viostor/vioscsi/NetKVM/...) via pnputil, and' -f DarkGray
    Write-Host '                  VMware PVSCSI + VMXNET3 + SVGA via ADDLOCAL=Drivers.' -f DarkGray
    Write-Host '      AGENTS    - qemu-ga, virtio-win-guest-tools and VMware Tools are' -f White
    Write-Host '                  STAGED here and INSTALLED later by PreSeal-Agents.ps1,' -f DarkGray
    Write-Host '                  which detects the hypervisor it is actually running on.' -f DarkGray
    Write-Host ''
    Write-Host '    One base image -> presealagent snapshot -> fork to KVM and to VMware.' -f Cyan
    Write-Host '    Nothing is ever deleted for belonging to "the other" hypervisor: the' -f DarkGray
    Write-Host '    installers and the virtio folder stay on BOTH, so a guest stays' -f DarkGray
    Write-Host '    migration-friendly in either direction.' -f DarkGray
    $hyp='both'
    Section 'Administrator account (your permanent access)'
    $u=Ask-Text 'Additional admin username' 'additionaladmin'
    do{
      $s1=Read-Host '    Password' -AsSecureString
      $s2=Read-Host '    Confirm password' -AsSecureString
      $p1=[Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1))
      $p2=[Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2))
      if(-not $p1 -or $p1 -ne $p2){ Warn 'passwords empty or do not match - try again' }
    } while(-not $p1 -or $p1 -ne $p2)
    Write-Host '    Examples:  Arabian Standard Time (Dubai/GST, UTC+4)   |   India Standard Time (IST, UTC+5:30)   |   UTC' -f DarkGray
    $tz=Ask-Text 'Timezone' 'Arabian Standard Time'
    Section 'Windows Update'
    $rwu=Ask-YN 'Run FULL Windows Update (reboots until fully patched)?' $true
    Section 'Snapshots (optional - the build powers OFF at that point so you can snapshot; boot the VM to auto-resume)'
    Write-Host '    Two independent checkpoints - pick either, both, or neither:' -f DarkGray
    $snapWU=Ask-YN '  1) After Windows Update, BEFORE app install  (clean fully-patched image)?' $false
    $snapPause=Ask-YN '  2) Just BEFORE sysprep  (final pre-seal image)?' $false
    Section 'Disk optimization (runs at seal time)'
    $optD=Ask-YN 'Standard disk optimization (DISM component cleanup + TRIM)?' $true
    $optZ=Ask-YN 'DEEP disk optimization (DISM /ResetBase + defrag + SDELETE zero-fill; slower)?' $false
    Section 'CloudStack deployment'
    Write-Host '    YES = if cloud-init runs, it injects + shares the Administrator password (CloudStack API/UI);' -f DarkGray
    Write-Host '          if cloud-init does NOT run, Administrator falls back to console set-up on first login (no OOBE).' -f DarkGray
    Write-Host '    Either way additionaladmin keeps its fixed password, so you can RDP in immediately.' -f DarkGray
    Write-Host '    (When YES, register the template in CloudStack with Password Enabled = Yes.)' -f DarkGray
    $stPw=Ask-YN 'Make this a PASSWORD-ENABLED template?' $false
    Section 'Optional components  (STAGED only - installed per-deployment, NOT in the image)'
    Write-Host '    Each staged component adds a <name>-register command to PATH.' -f DarkGray
    $stAcr=Ask-YN 'Acronis Cyber Protect  (acronis-register)?' $true
    $stBd =Ask-YN 'Bitdefender GravityZone EDR  (bitdefender-register)?' $true
    $stWz =Ask-YN 'Wazuh agent  (wazuh-register)?' $true
    $stGl =Ask-YN 'GLPI inventory agent  (glpi-register)?' $true
    $stOs =Ask-YN 'osquery / Fleet  (osquery-register)?' $true
    $stMd =Ask-YN 'Inventory + CloudStack-metadata reporter  (report-inventory)?' $true
    $stS7 =Ask-YN 'Site24x7 monitoring agent  (site24x7-register)?' $true
    $stZbx=Ask-YN 'Zabbix Agent 2  (zabbix-register, +remote control)?' $true
    $stDiag=Ask-YN 'Diagnostic tools staged as FILES  (iperf3/smartmontools/testdisk/logparser; NO nmap/pentest)?' $true
    Section 'Build notifications (ntfy.sh)'
    Write-Host '    Pushes start / update-done / DISM start+finish / pre-sysprep alerts to ntfy.sh.' -f DarkGray
    Write-Host '    Every message includes public IP + host + OS so you can tell VMs apart. Saved to config (changeable).' -f DarkGray
    Write-Host '    Enter a topic/channel, a full https://... URL, or type  off  to disable.' -f DarkGray
    $nt=Ask-Text 'ntfy.sh topic/channel (or "off" to disable)' '9890122212'
    if($nt -match '^(off|no|none|disable|disabled)$'){ $ntfyUrl='' }
    elseif($nt -match '^https?://'){ $ntfyUrl=$nt }
    else { $ntfyUrl='https://ntfy.sh/'+($nt.Trim()) }
    Section 'SSH public keys for the additional admin'
    Write-Host '    Paste one public key per line, then press Enter on a BLANK line to finish (or just Enter to add none).' -f DarkGray
    Write-Host '    Example:  ssh-ed25519 AAAAC3NzaC1lZDI1... you@laptop     (ssh-rsa AAAAB3... also fine)' -f DarkGray
    $keys=@(); while($true){ $k=Read-Host '    key (blank = done)'; if([string]::IsNullOrWhiteSpace($k)){break}; $keys+=$k.Trim() }
    $keysLine = ($keys | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ','
@"
# Hypervisor is always 'both' now - the base image is neutral and PreSeal-Agents.ps1
# decides at run time. Kept in the answer file only so older files still parse.
`$Hypervisor          = '$hyp'
`$AdditionalAdminUser = '$($u -replace "'","''")'
`$TimeZone            = '$($tz -replace "'","''")'
`$RunWindowsUpdate    = `$$rwu
`$SnapshotPostWU      = `$$snapWU
`$Unattended          = `$true
`$PauseOnFail         = `$false
`$VirtioDrive         = ''
`$OptimizeDisk        = `$$optD
`$DeepOptimize        = `$$optZ
`$SnapshotPause       = `$$snapPause
`$StageAcronis        = `$$stAcr
`$StageBitdefender    = `$$stBd
`$StageWazuh          = `$$stWz
`$StageGlpi           = `$$stGl
`$StageOsquery        = `$$stOs
`$StageMetadata       = `$$stMd
`$StageSite24x7       = `$$stS7
`$StageZabbix         = `$$stZbx
`$StageDiagTools      = `$$stDiag
`$CloudStackPwEnabled = `$$stPw
`$NtfyTopic           = '$($ntfyUrl -replace "'","''")'
`$SSHPubKeys          = @($keysLine)
"@ | Set-Content $setFile -Encoding ascii
    Protect-GIString $p1 | Set-Content $pwFile -Encoding ascii
    $global:GiPlainPw = $p1
    Ok "Settings saved to answer file; password encrypted. Reboots resume with NO prompt."
  }
  . $setFile
  # 'both' is the only value this build produces. Older answer files may still say
  # 'kvm' or 'vmware' - harmless, nothing branches on it now: the drivers are always
  # both, and the agents are chosen at run time by PreSeal-Agents.ps1.
  if(-not $Hypervisor){ $Hypervisor='both' }
  $global:Hypervisor              = $Hypervisor
  $global:AdditionalAdminUser     = $AdditionalAdminUser
  $global:AdditionalAdminPassword = (Unprotect-GIString ((Get-Content $pwFile -Raw).Trim()))
  $global:CloudinitAdminPassword  = $global:AdditionalAdminPassword
  $global:TimeZone                = $TimeZone
  $global:RunWindowsUpdate        = [bool]$RunWindowsUpdate
  $global:Unattended              = $true
  $global:PauseOnFail             = [bool]$PauseOnFail
  $global:SSHPubKeys              = @($SSHPubKeys)
  $global:VirtioDrive             = $VirtioDrive
  if($null -eq $OptimizeDisk){$OptimizeDisk=$true}
  $global:OptimizeDisk            = [bool]$OptimizeDisk
  $global:DeepOptimize            = [bool]$DeepOptimize
  $global:SnapshotPause           = [bool]$SnapshotPause
  $global:SnapshotPostWU          = [bool]$SnapshotPostWU
  if($null -eq $StageAcronis){$StageAcronis=$true}; if($null -eq $StageBitdefender){$StageBitdefender=$true}
  if($null -eq $StageWazuh){$StageWazuh=$true}; if($null -eq $StageGlpi){$StageGlpi=$true}
  if($null -eq $StageOsquery){$StageOsquery=$true}; if($null -eq $StageMetadata){$StageMetadata=$true}
  if($null -eq $CloudStackPwEnabled){$CloudStackPwEnabled=$false}
  if($null -eq $StageSite24x7){$StageSite24x7=$true}; if($null -eq $StageZabbix){$StageZabbix=$true}
  if($null -eq $StageDiagTools){$StageDiagTools=$true}
  $global:StageAcronis=[bool]$StageAcronis; $global:StageBitdefender=[bool]$StageBitdefender
  $global:StageWazuh=[bool]$StageWazuh; $global:StageGlpi=[bool]$StageGlpi
  $global:StageOsquery=[bool]$StageOsquery; $global:StageMetadata=[bool]$StageMetadata
  $global:StageSite24x7=[bool]$StageSite24x7; $global:StageZabbix=[bool]$StageZabbix
  $global:StageDiagTools=[bool]$StageDiagTools
  $global:CloudStackPwEnabled=[bool]$CloudStackPwEnabled
  # ntfy topic: prefer the answer-file value (may be '' = disabled); fall back to the built-in default for old files
  if($null -eq $NtfyTopic){ $NtfyTopic='https://ntfy.sh/9890122212' }
  $global:NtfyTopic = $NtfyTopic
}

# ---------- per-step checkpoint runner (survives reboots) ----------
function Step($n,$b){
  $mk=Join-Path $Done (($n -replace '[^\w]','_')+'.done')
  if((-not $Force) -and (Test-Path $mk)){ Log "[SKIP] $n (already done)"; return }
  $num=if($n -match '^(\d+)'){$matches[1]}else{'--'}
  Set-Progress ("$num-47 " + ($n -replace '^\d+\s*',''))
  Log "[RUN ] $n"
  try{ &$b; New-Item $mk -Force|Out-Null; Log "[ OK ] $n" }catch{ Log "[FAIL] $n : $($_.Exception.Message)" }
}

# =====================================================================================
#  LOAD CONFIG  (answer file or one-time menu)
# =====================================================================================
Get-GIConfig
$NtfyTopic = $global:NtfyTopic   # honor the ntfy topic chosen in the menu / answer file (overrides the built-in default)

# ---------- generate-only option: if the answer file was JUST created interactively, allow exit ----------
# (intent may be to only produce the answer file and reuse it on another VM / instance).
if($global:JustCreatedAnswerFile -and [Environment]::UserInteractive){
  Section 'Answer file created'
  Info "Saved:  gi-settings.ps1 (portable)   +   .gi-pw (encrypted, machine-bound to THIS VM)"
  Info "To reuse on OTHER VMs you need a PORTABLE credential - .gi-pw only works on this machine."
  if(Ask-YN 'Write a portable C:\Scripts\gi-pw.seed (PLAINTEXT password) for UNATTENDED reuse elsewhere?' $false){
    Set-Content "$S\gi-pw.seed" $global:GiPlainPw -Encoding ascii -NoNewline
    Warn 'Wrote C:\Scripts\gi-pw.seed (PLAINTEXT password).'
    Info 'Copy  gi-settings.ps1 + gi-pw.seed  to C:\Scripts on the other VMs. First run there self-encrypts'
    Info '  it into a local .gi-pw and DELETES the seed. (It is also auto-deleted here just before sysprep.)'
  }
  Info "Do NOT copy .gi-pw to other VMs (machine-bound - it will not decrypt there)."
  if(-not (Ask-YN 'Build THIS VM now?  (No = only generate the answer file and exit)' $true)){ Ok 'Answer file generated. Exiting WITHOUT building - reuse it on another VM/instance.'; exit 0 }
}

# ---------- self-resume: hardened SYSTEM startup task that re-runs THIS file every boot ----------
if(-not (Get-ScheduledTask -TaskName 'GIBuild' -EA SilentlyContinue)){
  $act=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\GoldenImage.ps1'
  $trg=New-ScheduledTaskTrigger -AtStartup; try{ $trg.Delay='PT30S' }catch{}
  $set=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -ExecutionTimeLimit ([TimeSpan]::Zero)
  $prn=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
  Register-ScheduledTask 'GIBuild' -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
  OL 'registered self-resume task GIBuild (SYSTEM, at startup, restart x3)'
}

# ---------- PREFLIGHT (first run only): admin/PS/OS/disk/RDP/internet ----------
if(-not (Test-Path $ph)){
  Section 'Preflight checks'
  Set-Progress 'Preflight checks'
  Send-Ntfy 'GoldenImage: BUILD START' ("$env:COMPUTERNAME | "+$OS)
  Ok "Elevated (Administrator)"                                   # guaranteed by #Requires
  if($PSVersionTable.PSVersion.Major -lt 5){ Err "PowerShell 5.1+ required (found $($PSVersionTable.PSVersion))"; throw 'PowerShell too old.' }
  Ok "PowerShell $($PSVersionTable.PSVersion)"
  if($OS -match '2016|2019|2022|2025'){ Ok "OS: $OS" } else { Warn "OS '$OS' not in 2016-2025 - continuing anyway" }
  $free=[math]::Round((Get-PSDrive C).Free/1GB,1); if($free -lt 15){ Warn "Low free space on C: ${free} GB (>=20 GB recommended)" } else { Ok "Free space on C: ${free} GB" }
  Info "Platform: HYPERVISOR-NEUTRAL  (virtio + VMware drivers both injected; guest agents staged, not installed - PreSeal-Agents.ps1 picks them after the presealagent snapshot)"
  # RDP on first (so you can watch if you want)
  Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 0 -EA SilentlyContinue
  Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -EA SilentlyContinue
  Start-Service TermService -EA SilentlyContinue
  $rdp = ((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -EA SilentlyContinue).fDenyTSConnections -eq 0)
  if($rdp){ Ok 'RDP enabled' } else { Warn 'RDP could not be enabled' }
  Info 'Checking internet (up to 2 min)...'
  $net = Wait-Net 120
  if(-not $rdp -or -not $net){
    Err "PREFLIGHT FAILED  (RDP: $rdp | Internet: $net). Aborting."
    Unregister-ScheduledTask 'GIBuild' -Confirm:$false -EA SilentlyContinue
    throw "Preflight failed: RDP=$rdp Internet=$net. Fix these, then re-run."
  }
  Ok 'Internet reachable'
  Set-Content $ph 'wu'
  Ok 'Preflight passed - starting build. You can walk away now.'
}
$phase=Get-Content $ph
$dc=@(Get-ChildItem $Done -Filter *.done -EA SilentlyContinue).Count
OL "==== phase = $phase   (platform=$Hypervisor, completed steps=$dc) ===="

# ---- ntfy: one push per PHASE ENTRY, once each (marker in .done). The six events
#      the operator actually waits on:
#        1 WU start          2 WU done -> power off for snapshot
#        3 config batch start (steps 1-57)      4 config done -> optimize starting
#        5 optimize done -> TAKE THE PRE-SEAL SNAPSHOT
#        6 nothing after that: phase=seal stops and waits for you over SSH.
$phMark = Join-Path $Done ("ntfy-$phase.done")
if(-not (Test-Path $phMark)){
  New-Item $phMark -Force | Out-Null
  switch($phase){
    'wu'     { Send-Ntfy 'GoldenImage 1/6: WINDOWS UPDATE STARTED' ("$env:COMPUTERNAME | $OS`nPatching now. Expect reboots. Next push when it is fully patched and powering off.") }
    'config' { Send-Ntfy 'GoldenImage 3/6: APP INSTALL STARTED (steps 1-57)' ("$env:COMPUTERNAME | $OS`nSnapshot resumed correctly. Chocolatey, drivers, agents, catalog. Next push when the steps finish.") }
    'reboot' { Send-Ntfy 'GoldenImage: PRE-SEAL REBOOT' ("$env:COMPUTERNAME`nOne reboot so pending updates finalize, then disk optimize.") }
  }
}

# =====================================================================================
#  PHASE: WU  -  patch, reboot, repeat until clean.  HANG-PROOF: every scan+install runs in a
#  timeout-bounded job (a wedged WU call is KILLED, not waited on forever), a persistent cycle
#  counter resets the datastore mid-way and finally gives up so a never-converging WU cannot loop
#  endlessly, and the build still completes (clones finish patching via the 'winupdate' command).
# =====================================================================================
function Reset-WUStore {
  # NOTE: never stop msiserver here (Windows Installer) - it is unrelated to the WU store and leaving it stopped
  # breaks a later sysprep. Only WU services + cryptsvc (to unlock catroot2) are touched, then all restarted.
  try{ Stop-Service wuauserv,bits,cryptsvc,usosvc -Force -EA SilentlyContinue
    Remove-Item 'C:\Windows\SoftwareDistribution','C:\Windows\System32\catroot2' -Recurse -Force -EA SilentlyContinue
    Start-Service wuauserv,bits,cryptsvc -EA SilentlyContinue }catch{} }
function Invoke-WUCycle([int]$timeout=5400){
  # returns 'reboot' | 'clean' | 'stuck'. The scan+install run inside a job bounded by $timeout so a
  # hung download/install is terminated instead of freezing the build; the caller reboots + retries.
  $j=Start-Job {
    try{ Import-Module PSWindowsUpdate -EA SilentlyContinue
      $l=@(Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -EA SilentlyContinue)
      if($l.Count -gt 0){ Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot -EA SilentlyContinue | Out-Null }
      $l.Count
    }catch{ -1 } }
  if(-not (Wait-Job $j -Timeout $timeout)){ Stop-Job $j -EA SilentlyContinue; Remove-Job $j -Force -EA SilentlyContinue; return 'stuck' }
  $out=@(Receive-Job $j -EA SilentlyContinue); Remove-Job $j -Force -EA SilentlyContinue
  $n=0; foreach($x in $out){ if("$x" -match '^\-?\d+$'){ $n=[int]$x } }
  OL ("  WU: processed " + [math]::Max($n,0) + " update(s) this cycle")
  if($n -lt 0){ return 'stuck' }                                       # scan/install error -> reboot + retry
  if( Get-WURebootStatus -Silent -EA SilentlyContinue ){ return 'reboot' }
  if($n -gt 0){ return 'reboot' }                                      # installed without a reboot flag -> scan again
  return 'clean' }
if($phase -eq 'wu'){
  if($RunWindowsUpdate){
    Section 'Windows Update (auto-reboots until fully patched)'
    Set-Progress 'Windows Update - patching'
    if(-not (Wait-Net 300)){ Warn 'network not reachable after 5 min; attempting anyway' }
    $cf="$S\.wu-cycles"; $cyc=0; if(Test-Path $cf){ $cyc=[int]((Get-Content $cf -Raw).Trim()) }; $cyc++; Set-Content $cf $cyc
    OL "WU: cycle $cyc (hang-proof, timeout-bounded)"
    try{ Import-Module PSWindowsUpdate -EA Stop }catch{ Install-PackageProvider NuGet -Force -EA SilentlyContinue|Out-Null; Set-PSRepository PSGallery -InstallationPolicy Trusted -EA SilentlyContinue; Install-Module PSWindowsUpdate -Force -Scope AllUsers -EA SilentlyContinue; Import-Module PSWindowsUpdate -EA SilentlyContinue }
    if($cyc -eq 8 -or $cyc -eq 16){ OL 'WU: datastore reset (wedged-store recovery)'; Reset-WUStore }
    if($cyc -gt 24){
      OL 'WU: giving up after 24 cycles (stuck) - continuing build; patch clones later with the winupdate command'
      Send-Ntfy 'GoldenImage: WINDOWS UPDATE GAVE UP' 'WU did not converge after 24 cycles; build continues. Patch later with: winupdate'
      Remove-Item $cf -Force -EA SilentlyContinue
      New-Item "$S\.wu-done" -Force | Out-Null; Set-Content $ph 'config'; $phase='config'
    } else {
      $r = Invoke-WUCycle 5400
      if($r -eq 'reboot'){ OL 'WU: reboot needed -> restarting (auto-resume)'; Invoke-Power restart; exit }
      elseif($r -eq 'stuck'){ OL 'WU: cycle stuck/failed (killed) -> rebooting to retry clean'; Invoke-Power restart; exit }
      else {
        OL 'WU: no more updates - fully patched'
        Send-Ntfy 'GoldenImage: WINDOWS UPDATE DONE' ('Fully patched after ' + $cyc + ' cycle(s). Build continuing.')
        Remove-Item $cf -Force -EA SilentlyContinue
        New-Item "$S\.wu-done" -Force | Out-Null; Set-Content $ph 'config'; $phase='config'
      }
    }
  } else {
    OL 'WU: skipped (chosen at prompt)'
    New-Item "$S\.wu-done" -Force | Out-Null; Set-Content $ph 'config'; $phase='config'
  }
  # OPTIONAL POST-UPDATE snapshot pause: Windows Update is finished and the phase is now 'config' (app install),
  # but nothing has been installed yet. If enabled, power off HERE so you can snapshot a CLEAN, fully-patched
  # image as a fast rebuild point. On next boot GIBuild resumes and, because the phase is already 'config', it
  # goes straight into the app-install/config steps automatically (the marker stops it pausing again).
  if($SnapshotPostWU -and -not (Test-Path "$S\.postwu-snap")){
    New-Item "$S\.postwu-snap" -Force | Out-Null
    OL 'POST-UPDATE SNAPSHOT PAUSE: fully patched, before app install. Powering off - take your CLEAN snapshot, then BOOT the VM to resume (app install starts automatically).'
    Set-Progress 'Post-update snapshot - power off, snapshot, then boot to resume'
    Send-Ntfy 'GoldenImage 2/6: WINDOWS UPDATE DONE - POWERING OFF FOR SNAPSHOT' ("$env:COMPUTERNAME | $OS`nFully patched. When it is OFF take:  snap01-winupdated-<vm>`nThen BOOT it - the app-install batch resumes by itself and pushes 3/6.")
    OL 'WU PHASE COMPLETE - fully patched. Next: snapshot  snap01-winupdated-<vm>  then BOOT to resume.'
    Invoke-Power off; exit
  }
}

# =====================================================================================
#  PHASE: CONFIG  -  all configuration steps (idempotent, checkpointed)
# =====================================================================================
if($phase -eq 'config'){
  Wait-Net 300 | Out-Null
  Section 'Configuration'
  Remove-Item $Lock -Force -EA SilentlyContinue
  $script:RebootNeeded=$false; $script:VDrive=''
  if($VirtioDrive){ $script:VDrive=($VirtioDrive.TrimEnd(':'))+':' }

Step '01 Enable-RDP' {
  Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 0
  $nla = if(($OS -match '2016') -or $ForceRdpNlaOff){0}else{1}
  Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' UserAuthentication $nla
  Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'; Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
  Start-Service TermService -EA SilentlyContinue; Log "  RDP enabled (NLA=$nla)"
}
Step '02 Create-AdditionalAdmin' {
  $s=ConvertTo-SecureString $AdditionalAdminPassword -AsPlainText -Force
  if(Get-LocalUser $AdditionalAdminUser -EA SilentlyContinue){Set-LocalUser $AdditionalAdminUser -Password $s}else{New-LocalUser $AdditionalAdminUser -Password $s -FullName $AdditionalAdminUser -PasswordNeverExpires}
  Add-LocalGroupMember Administrators $AdditionalAdminUser -EA SilentlyContinue
}
Step '03 Create-CloudInitAdmin' {
  $s=ConvertTo-SecureString $CloudinitAdminPassword -AsPlainText -Force
  if(Get-LocalUser CloudinitAdmin -EA SilentlyContinue){Set-LocalUser CloudinitAdmin -Password $s}else{New-LocalUser CloudinitAdmin -Password $s -FullName CloudinitAdmin -PasswordNeverExpires}
  Add-LocalGroupMember Administrators CloudinitAdmin -EA SilentlyContinue
}
Step '04 Write-AdminConsoleBootstrap' {
@'
@echo off
> "%TEMP%\sec.inf" echo [Version]
>> "%TEMP%\sec.inf" echo signature="$CHICAGO$"
>> "%TEMP%\sec.inf" echo [System Access]
>> "%TEMP%\sec.inf" echo MinimumPasswordLength = 0
>> "%TEMP%\sec.inf" echo PasswordComplexity = 0
secedit /configure /db "%TEMP%\sec.sdb" /cfg "%TEMP%\sec.inf" /areas SECURITYPOLICY >nul 2>&1
net user Administrator /active:yes >nul 2>&1
exit /b 0
'@ | Set-Content (Join-Path $Scripts 'set-admin-console.cmd') -Encoding ascii
}
Step '05 Disable-IE-ESC' {
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' IsInstalled 0 -EA SilentlyContinue
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-EA75-4B4E-88C5-0F26A9E9EA80}' IsInstalled 0 -EA SilentlyContinue
}
Step '06 Set-Timezone' { tzutil /s $TimeZone }
Step '07 Enable-NTP-Sync' { Set-Service w32time -StartupType Automatic; w32tm /config /manualpeerlist:"time.windows.com,0x9 pool.ntp.org,0x9" /syncfromflags:manual /reliable:yes /update|Out-Null; Start-Service w32time -EA SilentlyContinue; w32tm /resync /force 2>$null|Out-Null }
Step '08 Disable-Guest' { net user Guest /active:no|Out-Null }
Step '09 Enable-Firewall' { Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True }
Step '10 Add-Firewall-Ports' {
  $t=@('80','443','1443','1521','3222','3306','3478','4443','4444','5432','5985','5986','8080','51820','3389','5000-5500')
  New-NetFirewallRule -DisplayName 'App Ports TCP In'  -Direction Inbound  -Action Allow -Protocol TCP -LocalPort  $t -Profile Any -EA SilentlyContinue|Out-Null
  New-NetFirewallRule -DisplayName 'App Ports TCP Out' -Direction Outbound -Action Allow -Protocol TCP -RemotePort $t -Profile Any -EA SilentlyContinue|Out-Null
  New-NetFirewallRule -DisplayName 'App Ports UDP In'  -Direction Inbound  -Action Allow -Protocol UDP -LocalPort  3478,51820,'5000-5500' -Profile Any -EA SilentlyContinue|Out-Null
  New-NetFirewallRule -DisplayName 'App Ports UDP Out' -Direction Outbound -Action Allow -Protocol UDP -RemotePort 3478,51820,'5000-5500' -Profile Any -EA SilentlyContinue|Out-Null
}
Step '11 Enable-FilePrinter-Sharing' { Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -EA SilentlyContinue }
Step '12 Disable-IPv6' { Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' DisabledComponents 0xFF -Type DWord; New-NetFirewallRule -DisplayName 'ICMPv4 Echo In' -Direction Inbound -Action Allow -Protocol ICMPv4 -IcmpType 8 -Profile Any -EA SilentlyContinue|Out-Null }
Step '13 Reset-RDP-GracePeriod' {
  $a=New-ScheduledTaskAction -Execute reg.exe -Argument 'delete "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod" /va /f'
  $p=New-ScheduledTaskPrincipal -UserId SYSTEM -RunLevel Highest
  Register-ScheduledTask ResetRDPGrace -Action $a -Principal $p -Force|Out-Null; Start-ScheduledTask ResetRDPGrace; Start-Sleep 4; Unregister-ScheduledTask ResetRDPGrace -Confirm:$false
}
Step '14 Install-Telnet-DotNet' {
  Install-WindowsFeature Telnet-Client -EA SilentlyContinue|Out-Null
  # NET-Framework-45-Core ONLY. The umbrella 'NET-Framework-45-Features' pulls in
  # NET-WCF-MSMQ-Activation45, whose dependency is MSMQ-Server - so every golden
  # shipped a running Message Queuing server. MSMQ registers a sysprep generalize
  # provider and is what left sysprep hung/dead immediately after
  # Sysprep_Generalize_Pnp_Drivers: Exit with a 0-byte setuperr.log.
  Install-WindowsFeature NET-Framework-45-Core -EA SilentlyContinue|Out-Null
  # belt and braces: if an earlier build or a dependency dragged MSMQ in anyway,
  # take it back out before anything else installs on top of it.
  if((Get-WindowsFeature MSMQ -EA SilentlyContinue).Installed){
    Log '  MSMQ present - removing (breaks sysprep generalize)'
    Uninstall-WindowsFeature MSMQ -Remove -EA SilentlyContinue|Out-Null
  }
  # .NET 3.5. "Mount the ISO" was never a real answer for an automated build, so the
  # order is now: local sources\sxs if one happens to be mounted -> Windows Update
  # (DISM with NO /Source pulls NetFx3 straight from WU; this is the supported path
  # and needs no media) -> chocolatey. Only genuinely skip if all three fail, and say
  # which ones were tried. Set $InstallDotNet35=$false to opt out entirely.
  if($InstallDotNet35){
    $ok=$false
    $src=$DotNet35Source
    if(-not $src){ $src=(Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue | ForEach-Object { Join-Path ($_.Root) 'sources\sxs' } | Where-Object { Test-Path $_ } | Select-Object -First 1) }
    if($src){
      Install-WindowsFeature NET-Framework-Core -Source $src -EA SilentlyContinue | Out-Null
      $ok = (Get-WindowsFeature NET-Framework-Core -EA SilentlyContinue).Installed
      Log ("  .NET 3.5 from $src -> " + $(if($ok){'installed'}else{'FAILED, trying Windows Update'}))
    }
    if(-not $ok){
      Log '  .NET 3.5 via Windows Update (DISM, no media needed) - can take a few minutes'
      & dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /Quiet /NoRestart 2>&1 | Out-Null
      $ok = (Get-WindowsFeature NET-Framework-Core -EA SilentlyContinue).Installed
      Log ("  .NET 3.5 via WU -> " + $(if($ok){'installed'}else{'FAILED, trying chocolatey'}))
    }
    if(-not $ok -and (Get-Command choco -EA SilentlyContinue)){
      & choco install dotnet3.5 -y --no-progress 2>&1 | Out-Null
      $ok = (Get-WindowsFeature NET-Framework-Core -EA SilentlyContinue).Installed
      Log ("  .NET 3.5 via choco -> " + $(if($ok){'installed'}else{'FAILED'}))
    }
    if(-not $ok){ Log '  .NET 3.5 NOT INSTALLED - tried sources\sxs, Windows Update and choco. Set $DotNet35Source or $InstallDotNet35=$false.' }
  } else { Log '  .NET 3.5 skipped ($InstallDotNet35 = $false)' }
}
Step '15 Install-Chocolatey' {
  if(-not(Get-Command choco -EA SilentlyContinue)){ Set-ExecutionPolicy Bypass -Scope Process -Force; if($OS -match '2016|2019'){ $env:chocolateyVersion='1.4.0' }; iex((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) }
  $env:Path+=';C:\ProgramData\chocolatey\bin'
}
Step '16 Install-Choco-Packages' {
  $choco=(Get-Command choco -EA SilentlyContinue).Source; if(-not $choco){$choco='C:\ProgramData\chocolatey\bin\choco.exe'}
  if(-not(Test-Path $choco)){Log '  choco missing (reboot then re-run); pkgs skipped';return}
  # NEVER swallow the result. win2019bios sealed with ZERO of these installed: the
  # old loop piped choco to Out-Null, ignored $LASTEXITCODE and logged "choco <x>"
  # regardless, so Step() saw no exception and wrote .done\16_Install_Choco_Packages.
  # Every later run then logged "[SKIP] 16 (already done)" and the build could not
  # self-heal. Only visible symptom: the step took 5m01s instead of 11m51s.
  # Verify against choco's own inventory, retry once, and THROW if anything is
  # still missing so the marker is not written.
  $pkgs = 'powershell-core','googlechrome','git','python','openssl','vcredist140',
          'vcredist2015','putty','winscp','sysinternals','winrar','everything','7zip'
  function Get-ChocoInstalled($exe){
    # choco 1.x needs --local-only; choco 2.x removed it and lists local by default
    $o = @(& $exe list --local-only --limit-output 2>$null)
    if(-not $o.Count){ $o = @(& $exe list --limit-output 2>$null) }
    @($o | ForEach-Object { ($_ -split '\|')[0] } | Where-Object { $_ })
  }
  foreach($pass in 1,2){
    $have = Get-ChocoInstalled $choco
    $todo = @($pkgs | Where-Object { $have -notcontains $_ })
    if(-not $todo.Count){ break }
    if($pass -eq 2){ Log ("  retry pass for: " + ($todo -join ', ')) }
    foreach($x in $todo){
      & $choco install $x -y --no-progress --ignore-checksums | Out-Null
      $rc = $LASTEXITCODE
      # 1641/3010 = success, reboot required. 1605/1614 = already gone/absent.
      if($rc -eq 0 -or $rc -eq 1641 -or $rc -eq 3010){ Log "  choco $x (rc=$rc)" }
      else { Log "  choco $x FAILED rc=$rc" }
    }
  }
  $have = Get-ChocoInstalled $choco
  $miss = @($pkgs | Where-Object { $have -notcontains $_ })
  if($miss.Count){ throw ("choco packages STILL missing after 2 passes: " + ($miss -join ', ')) }
  Log ("  all " + $pkgs.Count + " choco packages verified present")
  & $choco install ansible --source python -y --no-progress 2>$null|Out-Null
}
Step '17 Install-PSWindowsUpdate' { Install-PackageProvider NuGet -Force -EA SilentlyContinue|Out-Null; Set-PSRepository PSGallery -InstallationPolicy Trusted -EA SilentlyContinue; Install-Module PSWindowsUpdate -Force -Scope AllUsers -EA SilentlyContinue }
Step '18 Refresh-Root-Certs' {
  $sst=Join-Path $Scripts 'roots.sst'; certutil -generateSSTFromWU $sst 2>$null|Out-Null
  if(Test-Path $sst){ try{ $col=New-Object Security.Cryptography.X509Certificates.X509Certificate2Collection; $col.Import($sst); $st=New-Object Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine'); $st.Open('ReadWrite'); $st.AddRange($col); $st.Close(); Log "  imported $($col.Count) root certs" }catch{ Log "  root cert import skipped: $($_.Exception.Message)" } }
}
Step '19 Install-Python-Modules' {
  # choco updates the MACHINE PATH but this process still has the old copy, so
  # python installed by step 16 is invisible here ("python not found").
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
  $py=(Get-Command python -EA SilentlyContinue).Source
  if(-not $py){ Log '  python not found; pip modules skipped'; return }
  & $py -m ensurepip --upgrade 2>$null | Out-Null
  & $py -m pip install --upgrade pip setuptools wheel 2>$null | Out-Null
  # SSL/cert + HTTP + crypto + Windows/WinRM/SSH + common must-haves (so nothing is "module not found" later)
  $mods='certifi','requests','urllib3','pyOpenSSL','cryptography','idna','charset-normalizer','pywin32','wmi','pywinrm','requests-ntlm','paramiko','pynacl','bcrypt','pyyaml','jinja2','six','psutil','packaging','python-dateutil','lxml','chardet'
  & $py -m pip install --upgrade $mods 2>$null | Out-Null
  try{ & $py -c "import certifi,requests,ssl,OpenSSL,cryptography,win32api,winrm; print('py-modules OK')" 2>$null | ForEach-Object { Log "  $_" } }catch{}
  Log ("  installed " + $mods.Count + " python modules (ssl/certifi/requests/cryptography/pywin32/winrm/paramiko/...)")
}

Step '20 Stage-Installers' {
  $d=@{ 'WinSCP-Setup.exe'='https://sourceforge.net/projects/winscp/files/latest/download'
        'CloudbaseInitSetup_x64.msi'='https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi'
        'putty-64bit.msi'='https://the.earth.li/~sgtatham/putty/latest/w64/putty-64bit-installer.msi'
        'SysinternalsSuite.zip'='https://download.sysinternals.com/files/SysinternalsSuite.zip'
        'IISCrypto.exe'='https://www.nartac.com/Downloads/IISCrypto/IISCrypto.exe'
        'IISCryptoCli.exe'='https://www.nartac.com/Downloads/IISCrypto/IISCryptoCli.exe' }
  foreach($k in $d.Keys){ if(Get-File $d[$k] (Join-Path $Scripts $k)){Log "  got $k"} }
  # IIS Crypto = free GUI/CLI to manage SSL/TLS protocols, ciphers, hashes + Windows crypto (Nartac).
  # Kept portable in C:\Scripts (on PATH): run  IISCrypto  (GUI)  or  IISCryptoCli  (command line).
  if(-not (Test-Path (Join-Path $Scripts 'IISCrypto.exe'))){ & (Get-Command choco -EA SilentlyContinue).Source install iiscrypto -y --no-progress 2>$null|Out-Null }
  Get-ChildItem 'C:\ProgramData\chocolatey\lib' -Recurse -Include *.exe,*.msi -EA SilentlyContinue | Where-Object { $_.Name -match 'everything|winrar|winscp|putty|7z|openssl' } | ForEach-Object { Copy-Item $_.FullName $Scripts -Force -EA SilentlyContinue }
  if(Test-Path (Join-Path $Scripts 'SysinternalsSuite.zip')){
    try{ Expand-Archive (Join-Path $Scripts 'SysinternalsSuite.zip') (Join-Path $Scripts 'Sysinternals') -Force; Log '  Sysinternals unpacked -> C:\Scripts\Sysinternals' }catch{ Log "  Sysinternals unpack failed: $($_.Exception.Message)" }
    reg add 'HKCU\Software\Sysinternals' /v EulaAccepted /t REG_DWORD /d 1 /f 2>$null | Out-Null
  }
  # add C:\Scripts AND every sub-folder of it to the SYSTEM PATH, so any tool/command staged there
  # (register scripts, Sysinternals, agents) runs by name from anywhere - including cloud-init (SYSTEM).
  $mp=[Environment]::GetEnvironmentVariable('Path','Machine'); $cur=@($mp -split ';')
  $add=@('C:\Scripts') + @(Get-ChildItem $Scripts -Directory -EA SilentlyContinue | ForEach-Object { $_.FullName })
  foreach($w in $add){ if($cur -notcontains $w){ $mp=$mp.TrimEnd(';')+';'+$w; $cur+=$w; $env:Path+=';'+$w; Log "  $w added to system PATH" } }
  [Environment]::SetEnvironmentVariable('Path',$mp,'Machine')

  # ===== Optional components: STAGE ONLY (never installed during build) - toggled at the prompt =====
  if($StageAcronis){
    $acrExe = Join-Path $Scripts 'CyberProtect_AgentForWindows_web.exe'
    Get-File $AcronisAgentUrl $acrExe (1MB) | Out-Null
    if((Test-Path $acrExe) -and ((Get-Item $acrExe).Length -ge 1MB)){
      Log ("  Acronis web installer staged, {0:N1} MB" -f ((Get-Item $acrExe).Length/1MB))
    } else {
      Remove-Item $acrExe -Force -EA SilentlyContinue
      Log '  WARNING: Acronis installer did NOT download - the pinned URL is stale.'
      Log '           Update $AcronisAgentUrl from the Acronis console, or pass'
      Log '           acronis-register -InstallerUrl <url> on the deployed VM.'
    }
@'
param([string]$Token,[string]$Url,[string]$InstallerUrl,[switch]$Help)
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12   # SYSTEM/cloud-init download
$Exe="C:\Scripts\CyberProtect_AgentForWindows_web.exe"; $Log="C:\Scripts\acronis-install.log"
if($Help -or -not $Token -or -not $Url){
@"
acronis-register  -  SILENT / unattended install + register of the Acronis Cyber Protect agent.
USAGE:
  acronis-register -Token <REGISTRATION_TOKEN> -Url <https://your-dc-cloud.acronis.com>
  acronis-register -Token <t> -Url <u> -InstallerUrl <download-link>   (agent not staged)
  acronis-register -Help
GET TOKEN : Acronis console > Devices > + Add > "Register via token".
GET URL   : your Acronis login data-center, e.g. https://ae01-cloud.acronis.com
EXAMPLE   : acronis-register -Token ABC12-DEF34 -Url https://ae01-cloud.acronis.com
NOTES     : run on the DEPLOYED VM (not the golden image). Alt auth: --login/--password.
"@ | Write-Host -ForegroundColor Cyan
  if($Help){ exit 0 } else { exit 1 }
}
# The baked-in installer URL is version-pinned and can 404 by the time this
# image is deployed. Fetch on demand rather than dead-ending.
if((-not (Test-Path $Exe)) -and $InstallerUrl){
  Write-Host "Downloading agent from $InstallerUrl ..." -ForegroundColor Cyan
  try{ Start-BitsTransfer -Source $InstallerUrl -Destination $Exe -EA Stop }
  catch{ try{ Invoke-WebRequest $InstallerUrl -OutFile $Exe -UseBasicParsing -EA Stop }catch{} }
}
if((-not (Test-Path $Exe)) -or ((Get-Item $Exe -EA SilentlyContinue).Length -lt 1MB)){
  Remove-Item $Exe -Force -EA SilentlyContinue
  Write-Host "Installer not present: $Exe" -ForegroundColor Red
  Write-Host "Get the link from the Acronis console (Devices > + Add > Windows), then:" -ForegroundColor Yellow
  Write-Host "  acronis-register -Token <t> -Url <dc-url> -InstallerUrl <download-link>" -ForegroundColor Yellow
  exit 1
}
$argl="--add-components=agentForWindows,commandLine,trayMonitor --reg-token=$Token --reg-address=$Url --quiet --log=`"$Log`""
Write-Host "Installing + registering Acronis agent (silent, unattended)..." -ForegroundColor Cyan
$p=Start-Process $Exe -ArgumentList $argl -Wait -PassThru
foreach($pt in 443,8443,44445,9877){ if(-not(Get-NetFirewallRule -DisplayName "Acronis out $pt" -EA SilentlyContinue)){ New-NetFirewallRule -DisplayName "Acronis out $pt" -Direction Outbound -Action Allow -Protocol TCP -RemotePort $pt -Profile Any -EA SilentlyContinue | Out-Null } }
Write-Host ("Acronis exit code: " + $p.ExitCode + "   (log: $Log; outbound 443/8443/44445 allowed)") -ForegroundColor Cyan
exit $p.ExitCode
'@ | Set-Content (Join-Path $Scripts 'Register-Acronis.ps1') -Encoding ascii
@'
@echo off
rem acronis-register [-Token <t>] [-Url <u>] [-InstallerUrl <url>] [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Register-Acronis.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'acronis-register.cmd') -Encoding ascii
    Log '  Acronis staged + acronis-register created (run: acronis-register -Token <t> -Url <u> | -Help)'
  } else { Log '  Acronis staging skipped (prompt=no)' }

  if($StageBitdefender){
    $bn='setupdownloader_[aHR0cHM6Ly9jbG91ZC1lY3MuZ3Jhdml0eXpvbmUuYml0ZGVmZW5kZXIuY29tL1BhY2thZ2VzL0JTVFdJTi8wL1liY0tVRi9pbnN0YWxsZXIueG1sP2xhbmc9ZW4tVVM=].exe'
    $bo=Join-Path $Scripts $bn; $bu='https://cloud.gravityzone.bitdefender.com/Packages/BSTWIN/0/'+$bn
    if((-not(Test-Path -LiteralPath $bo)) -or ((Get-Item -LiteralPath $bo -EA SilentlyContinue).Length -lt 100KB)){
      try{ Start-BitsTransfer -Source $bu -Destination $bo -EA Stop }catch{ try{ Invoke-WebRequest $bu -OutFile $bo -UseBasicParsing -EA Stop }catch{} }
    }
    if(Test-Path -LiteralPath $bo){ Log '  got Bitdefender installer (filename preserved)' } else { Log '  Bitdefender download failed - place setupdownloader_[...].exe in C:\Scripts manually' }
@'
param([switch]$Help,[string[]]$ExtraArgs)
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12   # SYSTEM/cloud-init download
$bd = Get-ChildItem 'C:\Scripts\setupdownloader_*.exe' -EA SilentlyContinue | Select-Object -First 1
if($Help){
@"
bitdefender-register  -  SILENT install of the Bitdefender GravityZone (EDR) agent.
The tenant/company is embedded in the installer FILENAME, so NO token is needed.
USAGE:  bitdefender-register                         (installs silently: /bdparams /silent)
        bitdefender-register -ExtraArgs '/bdparams','/silent'   (custom switches)
        bitdefender-register -Help
NOTES:  run on the DEPLOYED VM (not the golden image).
"@ | Write-Host -ForegroundColor Cyan; exit 0
}
if(-not $bd){ Write-Host 'Bitdefender installer (C:\Scripts\setupdownloader_*.exe) not found.' -ForegroundColor Red; exit 1 }
$al = if($ExtraArgs){ $ExtraArgs } else { @('/bdparams','/silent') }
Write-Host "Installing Bitdefender GravityZone (EDR) agent (silent)..." -ForegroundColor Cyan
$p=Start-Process -FilePath $bd.FullName -ArgumentList $al -Wait -PassThru
Write-Host ("Bitdefender exit code: " + $p.ExitCode) -ForegroundColor Cyan
exit $p.ExitCode
'@ | Set-Content (Join-Path $Scripts 'Bitdefender-Register.ps1') -Encoding ascii
@'
@echo off
rem bitdefender-register [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Bitdefender-Register.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'bitdefender-register.cmd') -Encoding ascii
    Log '  Bitdefender staged + bitdefender-register created (run: bitdefender-register | -Help)'
  } else { Log '  Bitdefender staging skipped (prompt=no)' }

  if($StageWazuh){
    Get-File $WazuhMsiUrl (Join-Path $Scripts (Split-Path $WazuhMsiUrl -Leaf)) (1MB) | Out-Null
@'
param([string]$Manager,[string]$RegPassword,[string]$Group,[string]$Name,[switch]$Help)
$msi = Get-ChildItem 'C:\Scripts\wazuh-agent-*.msi' -EA SilentlyContinue | Select-Object -First 1
if($Help -or -not $Manager){
@"
wazuh-register  -  SILENT install + enroll of the Wazuh agent (OUTBOUND ONLY to manager 1514/1515).
USAGE:
  wazuh-register -Manager <manager-ip-or-domain> [-RegPassword <pw>] [-Group <group>] [-Name <name>]
  wazuh-register -Help
NOTES: run on the DEPLOYED VM (not the golden image). Agent opens the connection outbound;
       no inbound ports. -Group maps the endpoint to a policy/customer for reporting.
"@ | Write-Host -ForegroundColor Cyan
  if($Help){ exit 0 } else { exit 1 }
}
if(-not $msi){ Write-Host 'Wazuh MSI (C:\Scripts\wazuh-agent-*.msi) not found.' -ForegroundColor Red; exit 1 }
$a=@('/i',('"'+$msi.FullName+'"'),'/q',"WAZUH_MANAGER=$Manager","WAZUH_REGISTRATION_SERVER=$Manager")
if($RegPassword){ $a+="WAZUH_REGISTRATION_PASSWORD=$RegPassword" }
if($Group){ $a+="WAZUH_AGENT_GROUP=$Group" }
if($Name){  $a+="WAZUH_AGENT_NAME=$Name" }
Write-Host 'Installing + enrolling Wazuh agent (silent)...' -ForegroundColor Cyan
$p=Start-Process msiexec.exe -ArgumentList $a -Wait -PassThru
Start-Sleep 3; & net start WazuhSvc 2>$null | Out-Null
foreach($pt in 1514,1515){ if(-not(Get-NetFirewallRule -DisplayName "Wazuh out $pt" -EA SilentlyContinue)){ New-NetFirewallRule -DisplayName "Wazuh out $pt" -Direction Outbound -Action Allow -Protocol TCP -RemotePort $pt -Profile Any -EA SilentlyContinue | Out-Null } }
Write-Host ("Wazuh msiexec exit: " + $p.ExitCode + "   (outbound 1514/1515 allowed)") -ForegroundColor Cyan
exit $p.ExitCode
'@ | Set-Content (Join-Path $Scripts 'Wazuh-Register.ps1') -Encoding ascii
@'
@echo off
rem wazuh-register -Manager <m> [-RegPassword <p>] [-Group <g>] [-Name <n>] [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Wazuh-Register.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'wazuh-register.cmd') -Encoding ascii
    Log '  Wazuh staged + wazuh-register created (run: wazuh-register -Manager <m> | -Help)'
  } else { Log '  Wazuh staging skipped (prompt=no)' }

  if($StageGlpi){
    Get-File $GlpiAgentMsiUrl (Join-Path $Scripts (Split-Path $GlpiAgentMsiUrl -Leaf)) (1MB) | Out-Null
@'
param([string]$Server,[string]$Tag,[switch]$Help)
$msi = Get-ChildItem 'C:\Scripts\GLPI-Agent-*.msi' -EA SilentlyContinue | Select-Object -First 1
if($Help -or -not $Server){
@"
glpi-register  -  SILENT install of the GLPI inventory agent (OUTBOUND ONLY to your GLPI 443).
USAGE:
  glpi-register -Server <https://glpi.example.com/front/inventory.php> [-Tag <customer-id>]
  glpi-register -Help
NOTES: run on the DEPLOYED VM. -Server = your GLPI native-inventory URL. -Tag maps the asset to a
       GLPI Entity/customer for per-tenant billing. Outbound 443 only; runs as service 'glpi-agent'.
"@ | Write-Host -ForegroundColor Cyan
  if($Help){ exit 0 } else { exit 1 }
}
if(-not $msi){ Write-Host 'GLPI Agent MSI (C:\Scripts\GLPI-Agent-*.msi) not found.' -ForegroundColor Red; exit 1 }
$a=@('/i',('"'+$msi.FullName+'"'),'/quiet','RUNNOW=1',('SERVER="'+$Server+'"'))
if($Tag){ $a+=('TAG="'+$Tag+'"') }
Write-Host 'Installing GLPI Agent (silent)...' -ForegroundColor Cyan
$p=Start-Process msiexec.exe -ArgumentList $a -Wait -PassThru
Write-Host ("GLPI Agent msiexec exit: " + $p.ExitCode) -ForegroundColor Cyan
exit $p.ExitCode
'@ | Set-Content (Join-Path $Scripts 'GLPI-Register.ps1') -Encoding ascii
@'
@echo off
rem glpi-register -Server <url> [-Tag <t>] [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\GLPI-Register.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'glpi-register.cmd') -Encoding ascii
    Log '  GLPI Agent staged + glpi-register created (run: glpi-register -Server <url> | -Help)'
  } else { Log '  GLPI Agent staging skipped (prompt=no)' }

  if($StageOsquery){
    Get-File $OsqueryMsiUrl (Join-Path $Scripts (Split-Path $OsqueryMsiUrl -Leaf)) (1MB) | Out-Null
@'
param([string]$FleetUrl,[string]$EnrollSecret,[switch]$Help)
$msi = Get-ChildItem 'C:\Scripts\osquery-*.msi' -EA SilentlyContinue | Select-Object -First 1
$dir = 'C:\Program Files\osquery'
if($Help -or -not $FleetUrl -or -not $EnrollSecret){
@"
osquery-register  -  SILENT install + Fleet enrollment of osquery (OUTBOUND ONLY, TLS 443 to Fleet).
USAGE:
  osquery-register -FleetUrl <fleet.example.com:443> -EnrollSecret <secret>
  osquery-register -Help
NOTES: run on the DEPLOYED VM. Get the enroll secret from Fleet (Settings > Agent options).
       Outbound 443 only; osqueryd runs as a service and polls Fleet. No inbound ports.
"@ | Write-Host -ForegroundColor Cyan
  if($Help){ exit 0 } else { exit 1 }
}
if(-not $msi){ Write-Host 'osquery MSI (C:\Scripts\osquery-*.msi) not found.' -ForegroundColor Red; exit 1 }
if(-not (Test-Path "$dir\osqueryd\osqueryd.exe")){
  Write-Host 'Installing osquery (silent)...' -ForegroundColor Cyan
  Start-Process msiexec.exe -ArgumentList @('/i',('"'+$msi.FullName+'"'),'/quiet') -Wait
}
$h = ($FleetUrl -replace '^https?://','') -replace '/.*$',''
$flags = @(
 "--tls_hostname=$h",
 "--tls_server_certs=$dir\certs\certs.pem",
 "--host_identifier=uuid",
 "--enroll_secret_path=$dir\enroll.secret",
 "--enroll_tls_endpoint=/api/osquery/enroll",
 "--config_plugin=tls",
 "--config_tls_endpoint=/api/osquery/config",
 "--config_refresh=60",
 "--disable_distributed=false",
 "--distributed_plugin=tls",
 "--distributed_interval=60",
 "--distributed_tls_max_attempts=3",
 "--distributed_tls_read_endpoint=/api/osquery/distributed/read",
 "--distributed_tls_write_endpoint=/api/osquery/distributed/write",
 "--logger_plugin=tls",
 "--logger_tls_endpoint=/api/osquery/log",
 "--logger_tls_period=60"
) -join "`r`n"
Set-Content "$dir\osquery.flags" $flags -Encoding ascii
Set-Content "$dir\enroll.secret" $EnrollSecret -NoNewline -Encoding ascii
Write-Host 'Enrolling osquery to Fleet (restarting osqueryd)...' -ForegroundColor Cyan
Restart-Service osqueryd -EA SilentlyContinue
Write-Host 'osquery enrolled (service osqueryd, outbound to Fleet).' -ForegroundColor Cyan
exit 0
'@ | Set-Content (Join-Path $Scripts 'Osquery-Register.ps1') -Encoding ascii
@'
@echo off
rem osquery-register -FleetUrl <host:443> -EnrollSecret <s> [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Osquery-Register.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'osquery-register.cmd') -Encoding ascii
    Log '  osquery staged + osquery-register created (run: osquery-register -FleetUrl <h> -EnrollSecret <s> | -Help)'
  } else { Log '  osquery staging skipped (prompt=no)' }

  if($StageMetadata){
@'
param([string]$PostUrl,[string]$Tag,[switch]$Install,[string]$Time='03:00',[switch]$Uninstall,[switch]$Help)
$ErrorActionPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($Help){
@"
report-inventory  -  collect CloudStack instance metadata + guest facts into JSON (OUTBOUND ONLY).
COLLECTS: instance metadata (instance-id, zone, offering, public/local IP) AND guest facts
          (SQL Server edition/version/eval, Windows activation/license, antivirus, backup agent,
          hardware, installed software).
USAGE:
  report-inventory                         (write JSON to C:\Scripts\inventory-report\)
  report-inventory -PostUrl <https://collector/api>  (also POST the JSON, outbound 443)
  report-inventory -Tag <customer-id>      (stamp the report with a customer/entity tag)
  report-inventory -Install [-PostUrl <u>] [-Tag <t>] [-Time 03:00]   (SYSTEM task: at startup + daily)
  report-inventory -Uninstall              (remove the scheduled task)
  report-inventory -Help
NOTES: run on the DEPLOYED VM. Reads BOTH metadata sources - the injected ConfigDrive/NoCloud CD
       (config-2 / cidata, primary) AND the CloudStack VR data-server (merged for public-ipv4/offering),
       cached locally so it survives CD detach. No inbound ports. -PostUrl lets your portal/ERP ingest it.
"@ | Write-Host -ForegroundColor Cyan; exit 0
}
if($Uninstall){ Unregister-ScheduledTask -TaskName 'YC-Inventory' -Confirm:$false; Write-Host 'Removed scheduled task YC-Inventory.' -ForegroundColor Yellow; exit 0 }
if($Install){
  $arg="-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  if($PostUrl){ $arg += " -PostUrl `"$PostUrl`"" }
  if($Tag){ $arg += " -Tag `"$Tag`"" }
  $act=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
  $t1=New-ScheduledTaskTrigger -AtStartup
  $t2=New-ScheduledTaskTrigger -Daily -At ([datetime]$Time)
  $prn=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
  $set=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask 'YC-Inventory' -Action $act -Trigger $t1,$t2 -Principal $prn -Settings $set -Force | Out-Null
  Write-Host 'Installed scheduled task YC-Inventory (SYSTEM: at startup + daily). Running once now...' -ForegroundColor Green
}
function Get-CSMeta {
  $m=[ordered]@{}
  $vols = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5 OR DriveType=2'
  $ordered = @($vols | Where-Object { $_.VolumeName -match 'config-2|cidata|config' }) + @($vols | Where-Object { $_.VolumeName -notmatch 'config-2|cidata|config' })
  foreach($v in $ordered){
    $d=$v.DeviceID; if(-not $d){ continue }
    $osjson = Join-Path $d 'openstack\latest\meta_data.json'
    $ncmeta = Join-Path $d 'meta-data'
    if(Test-Path $osjson){
      try{
        $j = Get-Content $osjson -Raw | ConvertFrom-Json
        $m['instance-id']=$j.uuid; $m['vm-id']=$j.uuid; $m['local-hostname']=$j.hostname; $m['name']=$j.name
        if($j.availability_zone){ $m['availability-zone']=$j.availability_zone }
        if($j.meta){ $m['meta']=$j.meta }
        $m['configdrive-source']=$osjson; break
      }catch{}
    }
    elseif(Test-Path $ncmeta){
      try{
        foreach($ln in (Get-Content $ncmeta)){
          if($ln -match '^\s*instance-id\s*:\s*(.+)$'){ $m['instance-id']=$matches[1].Trim() }
          if($ln -match '^\s*local-hostname\s*:\s*(.+)$'){ $m['local-hostname']=$matches[1].Trim() }
        }
        if($m.Count){ $m['configdrive-source']=$ncmeta; break }
      }catch{}
    }
  }
  $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.DHCPServer }
  $srv = @(); foreach($c in $cfg){ if($c.DHCPServer){ $srv += $c.DHCPServer } }; $srv += 'data-server'
  $keys = 'service-offering','availability-zone','local-ipv4','local-hostname','public-ipv4','public-hostname','instance-id','vm-id','cloud-identifier'
  foreach($h in ($srv | Select-Object -Unique)){
    if(-not $h){ continue }
    $base="http://$h/latest/meta-data"
    try{ Invoke-WebRequest "$base/instance-id" -UseBasicParsing -TimeoutSec 3 | Out-Null }catch{ continue }
    foreach($k in $keys){ try{ $v=(Invoke-WebRequest "$base/$k" -UseBasicParsing -TimeoutSec 5).Content; if($v){ $val=("$v").Trim(); if(-not $m[$k]){ $m[$k]=$val } } }catch{} }
    $m['vr-source']=$base; break
  }
  if($m.Count){
    $src=@(); if($m['configdrive-source']){ $src+='configdrive' }; if($m['vr-source']){ $src+='vr-http' }
    $m['metadata-source']=($src -join '+'); return $m
  }
  return [ordered]@{ 'metadata-source'='unavailable (no ConfigDrive/NoCloud CD and no VR data-server)' }
}
function Get-Activation {
  $st=@{0='Unlicensed';1='Licensed';2='OOB-Grace';3='OOT-Grace';4='NonGenuine-Grace';5='Notification';6='Extended-Grace'}
  Get-CimInstance SoftwareLicensingProduct | Where-Object { $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and $_.PartialProductKey } |
    ForEach-Object { [pscustomobject]@{ Name=$_.Name; PartialKey=$_.PartialProductKey; Status=$st[[int]$_.LicenseStatus]; StatusCode=[int]$_.LicenseStatus } }
}
function Get-SqlServers {
  $out=@()
  foreach($root in 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server'){
    $inst=Get-ItemProperty "$root\Instance Names\SQL" -EA SilentlyContinue
    if($inst){ foreach($p in ($inst.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })){
      $s=Get-ItemProperty "$root\$($p.Value)\Setup" -EA SilentlyContinue
      if($s){ $out += [pscustomobject]@{ Instance=$p.Name; Edition=$s.Edition; Version=$s.Version; PatchLevel=$s.PatchLevel; IsEvaluation=([string]$s.Edition -match 'Eval') } }
    } }
  }
  $out
}
function Get-AV {
  $out=@()
  Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -EA SilentlyContinue |
    ForEach-Object { $out += [pscustomobject]@{ Name=$_.displayName; ProductState=('0x{0:X}' -f $_.productState) } }
  try{ $d=Get-MpComputerStatus -EA SilentlyContinue; if($d){ $out += [pscustomobject]@{ Name='Windows Defender'; ProductState=("RTP="+$d.RealTimeProtectionEnabled+";AV="+$d.AntivirusEnabled+";Signatures="+$d.AntivirusSignatureVersion) } } }catch{}
  $svc = Get-CimInstance Win32_Service | Where-Object { $_.DisplayName -match 'bitdefender|kaspersky|sophos|mcafee|trend micro|eset|symantec|crowdstrike|sentinelone|carbon black|cylance|webroot' }
  foreach($v in $svc){ $out += [pscustomobject]@{ Name=$v.DisplayName; ProductState=('service:'+$v.State) } }
  $out
}
function Get-Backup {
  $pat='acronis|veeam|commvault|bacula|veritas|backup exec|cloudberry|msp360|arcserve|nakivo|datto|rubrik|duplicati|cobian'
  $out=@()
  Get-CimInstance Win32_Service | Where-Object { $_.DisplayName -match $pat } | ForEach-Object { $out += [pscustomobject]@{ Name=$_.DisplayName; State=$_.State; Kind='service' } }
  $out
}
function Get-Software {
  $keys='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  Get-ItemProperty $keys -EA SilentlyContinue | Where-Object { $_.DisplayName } |
    Select-Object @{n='Name';e={$_.DisplayName}},@{n='Version';e={$_.DisplayVersion}},@{n='Publisher';e={$_.Publisher}} | Sort-Object Name -Unique
}
$os=Get-CimInstance Win32_OperatingSystem; $cs=Get-CimInstance Win32_ComputerSystem; $bios=Get-CimInstance Win32_BIOS
$csmeta=Get-CSMeta; $cacheDir='C:\Scripts\inventory-report'; $cache=Join-Path $cacheDir 'instance-cache.json'
if(([string]$csmeta['metadata-source']) -like 'unavailable*'){ if(Test-Path $cache){ try{ $csmeta=(Get-Content $cache -Raw | ConvertFrom-Json) }catch{} } }
else { try{ New-Item -ItemType Directory -Force $cacheDir | Out-Null; ($csmeta | ConvertTo-Json -Depth 5) | Set-Content $cache -Encoding utf8 }catch{} }
$report=[ordered]@{
  tag              = $Tag
  collected_utc    = (Get-Date).ToUniversalTime().ToString('s')+'Z'
  hostname         = $env:COMPUTERNAME
  cloudstack       = $csmeta
  os = [ordered]@{ caption=$os.Caption; version=$os.Version; build=$os.BuildNumber; installdate=$os.InstallDate }
  activation       = @(Get-Activation)
  sql_servers      = @(Get-SqlServers)
  antivirus        = @(Get-AV)
  backup_agents    = @(Get-Backup)
  hardware = [ordered]@{ manufacturer=$cs.Manufacturer; model=$cs.Model; cpu=(@(Get-CimInstance Win32_Processor | ForEach-Object { $_.Name })); logical_cpus=$cs.NumberOfLogicalProcessors; ram_gb=[math]::Round($cs.TotalPhysicalMemory/1GB,1); bios_serial=$bios.SerialNumber }
  disks            = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [pscustomobject]@{ drive=$_.DeviceID; size_gb=[math]::Round($_.Size/1GB,1); free_gb=[math]::Round($_.FreeSpace/1GB,1) } })
  network          = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' | ForEach-Object { [pscustomobject]@{ ip=$_.IPAddress; mac=$_.MACAddress; gateway=$_.DefaultIPGateway; dhcp_server=$_.DHCPServer } })
  installed_software = @(Get-Software)
}
$dir='C:\Scripts\inventory-report'; New-Item -ItemType Directory -Force $dir | Out-Null
$json=$report | ConvertTo-Json -Depth 6
$file=Join-Path $dir ($env:COMPUTERNAME+'-'+(Get-Date -f yyyyMMdd-HHmmss)+'.json')
$json | Set-Content $file -Encoding utf8
Copy-Item $file (Join-Path $dir 'latest.json') -Force
Write-Host ("Inventory written: "+$file) -ForegroundColor Cyan
if($PostUrl){
  try{ Invoke-RestMethod -Uri $PostUrl -Method Post -Body $json -ContentType 'application/json' -TimeoutSec 30; Write-Host ("Posted inventory to "+$PostUrl) -ForegroundColor Green }
  catch{ Write-Host ("POST failed: "+$_.Exception.Message) -ForegroundColor Red }
}
exit 0
'@ | Set-Content (Join-Path $Scripts 'Report-Inventory.ps1') -Encoding ascii
@'
@echo off
rem report-inventory [-PostUrl <u>] [-Tag <t>] [-Install [-Time HH:mm]] [-Uninstall] [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Report-Inventory.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'report-inventory.cmd') -Encoding ascii
    Log '  report-inventory staged (run: report-inventory [-PostUrl <u>] [-Tag <t>] [-Install] | -Help)'
  } else { Log '  report-inventory staging skipped (prompt=no)' }

  # ----- Site24x7 monitoring agent (outbound HTTPS; register per-deployment with a device key) -----
  if($StageSite24x7){
    Get-File $Site24x7MsiUrl (Join-Path $Scripts 'Site24x7WindowsAgent.msi') (1MB) | Out-Null
@'
param([string]$DeviceKey,[string]$Name,[switch]$Help)
$msi = Get-ChildItem 'C:\Scripts\Site24x7WindowsAgent.msi' -EA SilentlyContinue | Select-Object -First 1
if($Help -or -not $DeviceKey){
@"
site24x7-register  -  SILENT install + register of the Site24x7 Windows monitoring agent (OUTBOUND 443 only).
USAGE:
  site24x7-register -DeviceKey <YOUR_DEVICE_KEY> [-Name <display-name>]
  site24x7-register -Help
GET KEY: Site24x7 console > Server > (+) add a Windows server monitor; copy the Device Key.
NOTES:   run on the DEPLOYED VM. Outbound HTTPS only; no inbound ports.
"@ | Write-Host -ForegroundColor Cyan
  if($Help){ exit 0 } else { exit 1 }
}
if(-not $msi){ Write-Host 'Site24x7 MSI (C:\Scripts\Site24x7WindowsAgent.msi) not found.' -ForegroundColor Red; exit 1 }
$a=@('/i',('"'+$msi.FullName+'"'),"EDITA1=$DeviceKey",'ENABLESILENT=YES','REBOOT=ReallySuppress','/qn')
if($Name){ $a+=('DN="'+$Name+'"') }
Write-Host 'Installing + registering Site24x7 agent (silent)...' -ForegroundColor Cyan
$p=Start-Process msiexec.exe -ArgumentList $a -Wait -PassThru
Write-Host ("Site24x7 msiexec exit: " + $p.ExitCode) -ForegroundColor Cyan
exit $p.ExitCode
'@ | Set-Content (Join-Path $Scripts 'Site24x7-Register.ps1') -Encoding ascii
@'
@echo off
rem site24x7-register -DeviceKey <k> [-Name <n>] [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Site24x7-Register.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'site24x7-register.cmd') -Encoding ascii
    Log '  Site24x7 staged + site24x7-register created (run: site24x7-register -DeviceKey <k> | -Help)'
  } else { Log '  Site24x7 staging skipped (prompt=no)' }

  # ----- Zabbix Agent 2 (monitoring + optional remote control via system.run) -----
  if($StageZabbix){
    Get-File $ZabbixMsiUrl (Join-Path $Scripts (Split-Path $ZabbixMsiUrl -Leaf)) (1MB) | Out-Null
@'
param([string]$Server,[string]$ServerActive,[string]$Hostname,[int]$ListenPort=10050,[switch]$RemoteCommands,[switch]$Help)
$msi = Get-ChildItem 'C:\Scripts\zabbix_agent2-*.msi' -EA SilentlyContinue | Select-Object -First 1
if($Help -or (-not $Server -and -not $ServerActive)){
@"
zabbix-register  -  SILENT install + configure the Zabbix Agent 2 (Windows) monitoring agent.
USAGE:
  zabbix-register -Server <zabbix-server-ip> [-ServerActive <ip>] [-Hostname <name>] [-ListenPort 10050] [-RemoteCommands]
  zabbix-register -Help
NOTES: run on the DEPLOYED VM. -Server = allowed passive-check source(s); -ServerActive = server for active checks.
       -Hostname defaults to the computer name. -RemoteCommands enables REMOTE CONTROL (AllowKey=system.run[*]) so
       the Zabbix server can run commands on this host - powerful, use only on trusted servers.
       Passive checks use inbound TCP 10050 (rule added); active checks are OUTBOUND to server:10051 (no inbound).
"@ | Write-Host -ForegroundColor Cyan
  if($Help){ exit 0 } else { exit 1 }
}
if(-not $msi){ Write-Host 'Zabbix MSI (C:\Scripts\zabbix_agent2-*.msi) not found.' -ForegroundColor Red; exit 1 }
if(-not $Hostname){ $Hostname=$env:COMPUTERNAME }
if(-not $ServerActive -and $Server){ $ServerActive=$Server }
$a=@('/i',('"'+$msi.FullName+'"'),'/qn','ENABLEPATH=1',"SERVER=$Server","SERVERACTIVE=$ServerActive","HOSTNAME=$Hostname","LISTENPORT=$ListenPort")
Write-Host 'Installing Zabbix Agent 2 (silent)...' -ForegroundColor Cyan
$p=Start-Process msiexec.exe -ArgumentList $a -Wait -PassThru
$conf='C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf'
if($RemoteCommands -and (Test-Path $conf)){
  Add-Content $conf "`r`nAllowKey=system.run[*]"
  Restart-Service 'Zabbix Agent 2' -EA SilentlyContinue
  Write-Host 'Remote control ENABLED (AllowKey=system.run[*]).' -ForegroundColor Yellow
}
if(-not(Get-NetFirewallRule -DisplayName ("Zabbix in "+$ListenPort) -EA SilentlyContinue)){ New-NetFirewallRule -DisplayName ("Zabbix in "+$ListenPort) -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ListenPort -Profile Any -EA SilentlyContinue | Out-Null }
if(-not(Get-NetFirewallRule -DisplayName 'Zabbix active out 10051' -EA SilentlyContinue)){ New-NetFirewallRule -DisplayName 'Zabbix active out 10051' -Direction Outbound -Action Allow -Protocol TCP -RemotePort 10051 -Profile Any -EA SilentlyContinue | Out-Null }
Write-Host ("Zabbix msiexec exit: " + $p.ExitCode + "   (inbound "+$ListenPort+" + outbound 10051 allowed)") -ForegroundColor Cyan
exit $p.ExitCode
'@ | Set-Content (Join-Path $Scripts 'Zabbix-Register.ps1') -Encoding ascii
@'
@echo off
rem zabbix-register -Server <ip> [-ServerActive <ip>] [-Hostname <n>] [-ListenPort 10050] [-RemoteCommands] [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Zabbix-Register.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'zabbix-register.cmd') -Encoding ascii
    Log '  Zabbix staged + zabbix-register created (run: zabbix-register -Server <ip> [-RemoteCommands] | -Help)'
  } else { Log '  Zabbix staging skipped (prompt=no)' }
}

  # ---------- DRIVERS IN, AGENTS OUT ------------------------------------------------
  # This block injects BOTH driver sets and stages BOTH agent sets. It installs no agent.
  #
  #   DRIVER (installed here, hypervisor-neutral, non-negotiable):
  #     step 22  virtio INFs   -> pnputil /add-driver /install   (viostor, vioscsi, NetKVM, ...)
  #     step 26  VMware INFs   -> ADDLOCAL=Drivers               (PVSCSI, VMXNET3, SVGA)
  #
  #   AGENT (staged here, installed later by PreSeal-Agents.ps1 on the branch):
  #     step 23  qemu-ga.msi
  #     step 24  virtio-win-guest-tools.exe
  #     step 26  VMware-Tools-x64.exe kept for its FULL (guest service) install
  #
  # Everything staged is kept on BOTH platforms permanently. A VMware guest keeps the
  # virtio folder and qemu-ga.msi; a KVM guest keeps VMware-Tools-x64.exe. One
  # infrastructure - a VM must stay migration-friendly in either direction, so nothing
  # is ever removed for belonging to "the other" hypervisor.
  if($true){
    Step '21 Prepare-Virtio-Media' {
      if($VirtioDrive){ $script:VDrive=($VirtioDrive.TrimEnd(':'))+':' ; Log "  using attached virtio CD $script:VDrive" }
      else {
        $iso=Join-Path $Scripts 'virtio-win.iso'
        if((-not(Test-Path $iso)) -or ((Get-Item $iso).Length -lt 50MB)){
          # ERROR 63: 0.1.285 carries the vioscsi/viostor race (commit 1bbc422) that
          # corrupts under sustained parallel I/O. SQL Server runs on most of these
          # images, so 0.1.271 is MANDATORY on every OS - not just 2025.
          $ver = '0.1.271-1'
          $cands=@()
          if($VirtioIsoUrl){ $cands+=$VirtioIsoUrl }
          $cands+="https://fedora-virt.repo.nfrance.com/virtio-win/direct-downloads/archive-virtio/virtio-win-$ver/virtio-win.iso"
          $cands+="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-$ver/virtio-win.iso"
          $cands+='https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'
          foreach($u in $cands){ Log "  trying $u"; if(Get-File $u $iso (50MB)){ break } }
        }
        # A Fedora mirror redirect can save an HTML page that passes a size check.
        # 0.1.271 is exactly 726501376 bytes / sha256 bbe6166a...6429 - verify BOTH.
        if(Test-Path $iso){
          $len=(Get-Item $iso).Length
          if($len -eq 726501376){
            $h=(Get-FileHash $iso -Algorithm SHA256).Hash.ToLower()
            if($h -eq 'bbe6166ad86a490caefad438fef8aa494926cb0a1b37fa1212925cfd81656429'){ Log '  virtio-win 0.1.271 ISO verified (size + sha256)' }
            else { Log "  ERROR: virtio ISO sha256 MISMATCH ($h) - DELETE C:\Scripts\virtio-win.iso and re-run"; Remove-Item $iso -Force -EA SilentlyContinue }
          } else { Log "  WARNING: virtio ISO is $len bytes, expected 726501376 (truncated or an HTML error page)" }
        }
        if((Test-Path $iso) -and ((Get-Item $iso).Length -ge 50MB)){
          $pre=@(Get-Volume | Where-Object DriveLetter | ForEach-Object DriveLetter)
          Mount-DiskImage -ImagePath $iso -EA SilentlyContinue | Out-Null; Start-Sleep 2
          $nl=@(Get-Volume | Where-Object DriveLetter | ForEach-Object DriveLetter) | Where-Object { $pre -notcontains $_ } | Select-Object -First 1
          if($nl){ $script:VDrive="$nl`:"; Log "  virtio ISO mounted at $script:VDrive" }
        } else { Log '  ISO download failed on all mirrors -> attach the ISO as a CD and set $VirtioDrive' }
      }
      if(-not $script:VDrive -and -not $Unattended){
        Write-Host "`n  >> VIRTIO MEDIA NOT FOUND. Attach/mount the virtio-win ISO now." -f Yellow
        $ans=Read-Host '  Then type its drive letter (e.g. E) and Enter, or just Enter to skip'
        if($ans){ $script:VDrive=($ans.TrimEnd(':'))+':' ; Log "  using $script:VDrive (manual)" }
      } elseif(-not $script:VDrive){ Log '  virtio media not found (unattended); guest-tools will still install drivers.' }
    }
    Step '22 Install-Virtio-Drivers' {
      $vdir=Join-Path $Scripts "virtio\$Tag"; New-Item -ItemType Directory -Force $vdir|Out-Null
      if($script:VDrive -and (Test-Path $script:VDrive)){
        $vDrivers='viostor','vioscsi','NetKVM','Balloon','vioserial','vioinput','viorng','viofs','viomem','pvpanic','qxldod','qxl','viogpudo','fwcfg','smbus'
        # Server 2025: the 0.1.271 '2k25' storage driver has reported INACCESSIBLE_BOOT_DEVICE (0x7B) BSODs when the
        # boot disk is switched to virtio; the 'w11' build (Server 2025 == Windows 11 24H2/Germanium kernel base) is
        # the community-confirmed working one. So on 2025 prefer w11, fall back to 2k25. Other OSes use their own tag.
        $folders = if($OS -match '2025'){ @('w11','2k25') } else { @($Tag) }
        foreach($drv in ($vDrivers|Select-Object -Unique)){
          $src=$null; foreach($fp in $folders){ $cand="$script:VDrive\$drv\$fp\amd64"; if(Test-Path $cand){ $src=$cand; break } }
          if($src){ New-Item -ItemType Directory -Force (Join-Path $vdir $drv)|Out-Null; Copy-Item "$src\*" (Join-Path $vdir $drv) -Recurse -Force -EA SilentlyContinue; Log ("  "+$drv+" <- "+(Split-Path (Split-Path $src -Parent) -Leaf)) }
        }
        Get-ChildItem $vdir -Recurse -Include *.cat,*.sys -EA SilentlyContinue | ForEach-Object {
          $sig=Get-AuthenticodeSignature $_.FullName -EA SilentlyContinue
          if($sig -and $sig.SignerCertificate){ foreach($st in 'TrustedPublisher','Root'){ try{ $x=New-Object Security.Cryptography.X509Certificates.X509Store($st,'LocalMachine'); $x.Open('ReadWrite'); $x.Add($sig.SignerCertificate); $x.Close() }catch{} } }
        }
        Get-ChildItem $vdir -Recurse -Filter *.inf | ForEach-Object { pnputil /add-driver "$($_.FullName)" /install 2>$null|Out-Null }
        Log "  injected $Tag virtio drivers (viostor + vioscsi + NetKVM + qxldod/viogpudo + misc); publisher pre-trusted"
      } else { Log '  no virtio media resolved' }
      foreach($svc in 'viostor','vioscsi'){ $k="HKLM:\SYSTEM\CurrentControlSet\Services\$svc"; if(Test-Path $k){Set-ItemProperty $k Start 0; Log "  $svc Start=0 (boot)"} }
    }
    # ---- STEPS 23 + 24: STAGE THE KVM AGENTS, DO NOT INSTALL THEM ---------------
    # These used to install when the menu answer was 'kvm'. That answer was given ~4
    # hours before it mattered and it welded the image to one hypervisor, so a VMware
    # variant meant repeating Windows Update and the whole app batch.
    # They are now STAGED only. PreSeal-Agents.ps1 installs them after the
    # presealagent snapshot, on whichever hypervisor the clone actually booted on.
    # The files themselves stay in C:\Scripts on BOTH platforms forever - a VMware
    # guest keeps the qemu-ga msi and the virtio folder so it can migrate to KVM.
    Step '23 Stage-QEMU-GuestAgent' {
      $qi=$null; if($script:VDrive){ $qi=Get-ChildItem "$script:VDrive\guest-agent\qemu-ga-x86_64.msi","$script:VDrive\guest-agent\*x64*.msi" -EA SilentlyContinue | Select-Object -First 1 }
      # canonical name: yc-firstboot.ps1 and PreSeal-Agents.ps1 both look for qemu-ga.msi.
      # The old copy kept the media name (qemu-ga-x86_64.msi), so first boot never found it.
      if($qi){ Copy-Item $qi.FullName (Join-Path $Scripts 'qemu-ga.msi') -Force -EA SilentlyContinue
               Log '  qemu-ga.msi staged (NOT installed - PreSeal-Agents.ps1 does that on a KVM clone)' }
      else   { Log '  qemu-ga msi not on media' }
    }
    Step '24 Stage-Virtio-GuestTools' {
      $c=Join-Path $Scripts 'virtio-win-guest-tools.exe'   # always kept in C:\Scripts, both platforms
      if($script:VDrive){ $src=(Get-ChildItem "$script:VDrive\virtio-win-guest-tools.exe" -EA SilentlyContinue | Select-Object -First 1).FullName; if($src){ Copy-Item $src $c -Force -EA SilentlyContinue } }
      if((-not(Test-Path $c)) -or ((Get-Item $c).Length -lt 1MB)){ $v='0.1.271-1'; Get-File "https://fedora-virt.repo.nfrance.com/virtio-win/direct-downloads/archive-virtio/virtio-win-$v/virtio-win-guest-tools.exe" $c (1MB)|Out-Null }
      if((Test-Path $c) -and ((Get-Item $c).Length -ge 1MB)){ Log '  virtio-win-guest-tools.exe staged (NOT installed - PreSeal-Agents.ps1 does that on a KVM clone)' }
      else { Log '  guest-tools unavailable' }
    }
    Step '25 Check-Virtio-BootReady' {
      $ready=$true
      foreach($svc in 'viostor','vioscsi'){ $k="HKLM:\SYSTEM\CurrentControlSet\Services\$svc"; $store=$false; try{ $store=[bool]((pnputil /enum-drivers 2>$null | Select-String -SimpleMatch "$svc.inf")) }catch{}; $start=if(Test-Path $k){(Get-ItemProperty $k).Start}else{'-'}; Log "  $svc : driverstore=$store Start=$start"; if(-not(Test-Path $k) -or $start -ne 0){$ready=$false} }
      if($ready){ Log '  VIRTIO BOOT READY - safe to switch disk to virtio.' } else { Log '  NOT virtio-boot-ready - mount the virtio ISO and re-run; do NOT switch to virtio yet.' }
    }
    # ---- STEP 26 STAYS IN THE BASE. THIS IS DRIVER INJECTION, NOT AN AGENT. -----
    # ADDLOCAL=Drivers installs PVSCSI + VMXNET3 + SVGA and nothing else - no VMTools
    # service, no tray app. It is the ONLY way to get those INFs into the DriverStore,
    # because VMware does not ship them separately. Do NOT move this to
    # PreSeal-Agents.ps1: if it is not in the base, the converted VMDK has no PVSCSI
    # and no VMXNET3, so the VMware fork is stuck on SATA + e1000 permanently instead
    # of using them only as a 0x7B fallback.
    # Because pvscsi is registered boot-start here, the VMDK will normally boot on
    # PVSCSI + VMXNET3 directly - try that first, drop to SATA + e1000 only on 0x7B.
    # The FULL VMware Tools guest service is what moves - PreSeal-Agents.ps1 installs
    # it from this same kept installer, on a VMware clone only.
    Step '26 Install-VMware-Drivers' {
      $e=Join-Path $Scripts 'VMware-Tools-x64.exe'
      # installer is ~146MB; require >=50MB (rejects truncated/contended downloads), retry up to 4x dropping partials
      # ---- VMware Tools 12.5.4 : ONE build for EVERY guest we ship --------------
      # 12.5.4 is the newest 12.x and the last branch that still carries the
      # PVSCSI / VMXNET3 / SVGA driver INFs for Server 2016 and 2019 while also
      # supporting 2022 and 2025. The 13.x line dropped 2016/2019, so 13.x is NOT
      # a valid universal choice for this template set.
      #   file   VMware-tools-12.5.4-24964629-x64.exe
      #   size   111965576 bytes   (exact)
      #   md5    a9e8d56c99dfb82c5fe8f94b501a9034
      #   sha256 6df1b26a1f15070f7612d623ff46c4c6409eefb8e272bf35f17b79a918d79ed7
      # Size alone is not proof - a CDN error page can be any length - so the
      # download is only accepted when size AND md5 AND sha256 all match.
      $tLen = 111965576
      $tMd5 = 'a9e8d56c99dfb82c5fe8f94b501a9034'
      $tSha = '6df1b26a1f15070f7612d623ff46c4c6409eefb8e272bf35f17b79a918d79ed7'
      function Test-ToolsFile([string]$f){
        if(-not (Test-Path $f)){ return $false }
        if((Get-Item $f).Length -ne $tLen){ Log ("  VMware Tools size " + (Get-Item $f).Length + " != $tLen"); return $false }
        $m=(Get-FileHash $f -Algorithm MD5).Hash.ToLower()
        $h=(Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
        if($m -ne $tMd5){ Log "  VMware Tools MD5 MISMATCH ($m)"; return $false }
        if($h -ne $tSha){ Log "  VMware Tools SHA256 MISMATCH ($h)"; return $false }
        Log "  VMware Tools 12.5.4 verified (size $tLen / md5 $tMd5 / sha256 ok)"
        return $true
      }
      $eok=Test-ToolsFile $e
      for($et=1; $VMwareToolsUrl -and (-not $eok) -and $et -le 4; $et++){
        if(Test-Path $e){ Remove-Item $e -Force -EA SilentlyContinue }
        Get-File $VMwareToolsUrl $e (50MB) 2400 | Out-Null
        $eok=Test-ToolsFile $e
        if(-not $eok){ Log "  VMware Tools download try $et failed verification - retrying"; Start-Sleep 15 }
      }
      if($eok){
        # PREREQ for VMware Tools 13.x on Server 2016/2019: VC++ 2015-2022 redist (x64+x86) - else driver install no-ops
        foreach($vc in @(@{u='https://aka.ms/vs/17/release/vc_redist.x64.exe';f='vc_redist.x64.exe'},@{u='https://aka.ms/vs/17/release/vc_redist.x86.exe';f='vc_redist.x86.exe'})){
          $vp=Join-Path $Scripts $vc.f
          if((-not (Test-Path $vp)) -or ((Get-Item $vp -EA SilentlyContinue).Length -lt 1MB)){ Get-File $vc.u $vp (1MB) 600 | Out-Null }
          if((Test-Path $vp) -and ((Get-Item $vp).Length -ge 1MB)){ try{ Start-Process $vp -ArgumentList '/install /quiet /norestart' -Wait; Log "  installed $($vc.f) (VMware Tools prereq)" }catch{} }
        }
        if($InstallVMwareTools){ try{ Start-Process $e -ArgumentList '/S /v "/qn ADDLOCAL=Drivers REBOOT=R"' -Wait; Log '  VMware DRIVERS-ONLY installed (PVSCSI + VMXNET3 + SVGA; no Tools service) for cross-platform/OVA boot' }catch{ Log "  VMware drivers install failed: $($_.Exception.Message)" } }
        else { Log '  VMware Tools staged only ($InstallVMwareTools=$false)' }
      } else { Log '  VMware Tools not staged (download failed)' }
      foreach($svc in 'pvscsi'){ $k="HKLM:\SYSTEM\CurrentControlSet\Services\$svc"; if(Test-Path $k){Set-ItemProperty $k Start 0; Log "  pvscsi Start=0 (boot)"} }
    }
    # ---- DISMOUNT HERE, NOT AT SEAL --------------------------------------------
    # Step 21 mounts C:\Scripts\virtio-win.iso and steps 22-24 read from it. Nothing
    # needs the media after step 26, but the dismount used to live in the SEAL phase
    # - hours later. Meanwhile step 54 installs the payload, and the payload CONTAINS
    # virtio-win.iso, so Copy-Item landed on the still-mounted file and threw
    #   "The process cannot access the file ... because it is being used by another process"
    # -> Install-YcPayload exit=1. On 2026-08-11 gates 1-3 all passed and the install
    # died on the very next copy, leaving the image with the 2 KB stub catalog.
    # Same safety rules as the seal-phase dismount: never call bare Get-DiskImage
    # (-ImagePath is mandatory, so it blocks forever under non-interactive SYSTEM),
    # and wrap it in a timeout job so a wedged storage stack cannot stall the build.
    Step '26b Dismount-Virtio-ISO' {
      $iso = Join-Path $Scripts 'virtio-win.iso'
      if(Test-Path $iso){
        $dj = Start-Job { param($p) Dismount-DiskImage -ImagePath $p -EA SilentlyContinue } -ArgumentList $iso
        if(-not (Wait-Job $dj -Timeout 60)){ Stop-Job $dj -EA SilentlyContinue; Log '  ISO dismount timed out (storage busy) - continuing' }
        Remove-Job $dj -Force -EA SilentlyContinue
        Start-Sleep 2
        Log '  virtio ISO dismounted - virtio-win.iso is now unlocked for the step 54 payload install'
      } else { Log '  no virtio-win.iso to dismount (attached CD-ROM or pre-staged drivers)' }
      $script:VDrive = ''
    }
    Log '  drivers: virtio + VMware BOTH injected, installers kept in C:\Scripts on both platforms.'
    Log '  agents : NONE installed. qemu-ga.msi / virtio-win-guest-tools.exe / VMware-Tools-x64.exe are staged;'
    Log '           PreSeal-Agents.ps1 installs the right pair after the presealagent snapshot.'
  }

Step '27 Install-CloudbaseInit' {
  $msi=Join-Path $Scripts 'CloudbaseInitSetup_x64.msi'
  if(Test-Path $msi){
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart RUN_SERVICE_AS_LOCAL_SYSTEM=1" -Wait
    $cd='C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
    if(Test-Path $cd){
      # STANDARD (default): fixed-password template - cloud-init NEVER resets the additional-admin password.
      $confStd=@'
[DEFAULT]
username=__CHUSER__
groups=Administrators
inject_user_password=false
config_drive_raw_hhd=true
config_drive_cdrom=true
config_drive_vfat=true
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.cloudstack.CloudStack,cloudbaseinit.metadata.services.httpservice.HttpService,cloudbaseinit.metadata.services.ec2service.EC2Service
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,cloudbaseinit.plugins.common.sshpublickeys.SetUserSSHPublicKeysPlugin,cloudbaseinit.plugins.common.userdata.UserDataPlugin,cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin
allow_reboot=true
stop_service_on_exit=false
check_latest_version=false
'@.Replace('__CHUSER__',$AdditionalAdminUser)
      # PASSWORD-ENABLED: CloudStack generates + sets the Administrator password each deploy (VR password
      # server or ConfigDrive). Requires the template registered with passwordenabled=true in CloudStack.
      $confPw=@'
[DEFAULT]
username=Administrator
groups=Administrators
inject_user_password=true
first_logon_behaviour=no
config_drive_raw_hhd=true
config_drive_cdrom=true
config_drive_vfat=true
config_drive_types=vfat,iso
config_drive_locations=hdd,partition,cdrom
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.cloudstack.CloudStack,cloudbaseinit.metadata.services.httpservice.HttpService,cloudbaseinit.metadata.services.ec2service.EC2Service
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin,cloudbaseinit.plugins.common.sshpublickeys.SetUserSSHPublicKeysPlugin,cloudbaseinit.plugins.common.userdata.UserDataPlugin,cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin
allow_reboot=true
stop_service_on_exit=false
check_latest_version=false
'@
      $conf = if($CloudStackPwEnabled){ $confPw } else { $confStd }
      Set-Content (Join-Path $cd 'cloudbase-init.conf') $conf -Encoding ascii
      Log ("  cloudbase-init.conf written (" + $(if($CloudStackPwEnabled){'PASSWORD-ENABLED: CloudStack manages Administrator'}else{'fixed-password: '+$AdditionalAdminUser}) + ")")
    }
  } else { Log '  cloudbase-init MSI not staged' }
}
Step '28 Install-OpenSSH-Server' {
  # ALWAYS use the LATEST Win32-OpenSSH from GitHub (the Windows 'capability' build is older/buggier) - ships ssh + scp + sftp.
  $z=Join-Path $Scripts 'OpenSSH-Win64.zip'; $bin='C:\Program Files\OpenSSH\OpenSSH-Win64'
  if(Get-Service sshd -EA SilentlyContinue){ Stop-Service sshd -Force -EA SilentlyContinue }
  if(Get-File 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip' $z (1MB)){
    Remove-Item $bin -Recurse -Force -EA SilentlyContinue
    Expand-Archive $z 'C:\Program Files\OpenSSH' -Force
    powershell -ExecutionPolicy Bypass -File "$bin\install-sshd.ps1" 2>$null
    # install-sshd.ps1 silently no-ops if the service already exists in a broken state.
    # Register it by hand if it is still missing, then make BOTH services survive a crash.
    if(-not (Get-Service sshd -EA SilentlyContinue)){
      & sc.exe create sshd binPath= "`"$bin\sshd.exe`"" start= auto DisplayName= "OpenSSH SSH Server" 2>$null | Out-Null
      & sc.exe create ssh-agent binPath= "`"$bin\ssh-agent.exe`"" start= auto DisplayName= "OpenSSH Authentication Agent" 2>$null | Out-Null
      Log '  sshd service was missing - registered manually via sc.exe'
    }
    & sc.exe failure sshd reset= 86400 actions= restart/5000/restart/10000/restart/30000 2>$null | Out-Null
    Set-Service ssh-agent -StartupType Automatic -EA SilentlyContinue
    Start-Service ssh-agent -EA SilentlyContinue
    $mp=[Environment]::GetEnvironmentVariable('Path','Machine'); if(($mp -split ';') -notcontains $bin){ [Environment]::SetEnvironmentVariable('Path',($mp.TrimEnd(';')+';'+$bin),'Machine'); $env:Path+=';'+$bin }
    Log "  OpenSSH (GitHub latest, incl. scp+sftp) installed -> $bin"
  } else { Log '  OpenSSH GitHub download FAILED - SSH not installed'; return }
  Set-Service sshd -StartupType Automatic; Start-Service sshd -EA SilentlyContinue
  if(-not (Test-Path 'C:\ProgramData\ssh\ssh_host_ed25519_key')){ & "$bin\ssh-keygen.exe" -A 2>$null }   # host keys if service did not make them
  $cfg='C:\ProgramData\ssh\sshd_config'
  if(Test-Path $cfg){ $c=Get-Content $cfg
    $c=$c -replace '^\s*#?\s*Port\s+.*','Port 3222'
    $c=$c -replace '^\s*#?\s*PasswordAuthentication\s+.*','PasswordAuthentication no'
    $c=$c -replace '^\s*#?\s*PubkeyAuthentication\s+.*','PubkeyAuthentication yes'
    $c=$c -replace '^\s*#?\s*Subsystem\s+sftp.*','Subsystem sftp sftp-server.exe'   # enables scp + sftp
    # DO NOT append. The stock sshd_config ends with "Match Group administrators"
    # and anything appended lands inside it: sshd then refuses to start with
    #   line NN: Directive 'Port' is not allowed within a Match block
    # (and $c is an ARRAY, so "$c -notmatch ..." returns the non-matching
    #  ELEMENTS, not a boolean - the guard was always true and always appended).
    # sshd takes the FIRST occurrence of a keyword, so prepend instead. Subsystem
    # must not be defined twice, so comment out any pre-existing one.
    $c = $c | Where-Object { $_ -notmatch '^\s*(Port|PasswordAuthentication|PubkeyAuthentication)\s' } |
              ForEach-Object { if($_ -match '^\s*Subsystem\s+sftp'){ '#' + $_ } else { $_ } }
    $c = @('Port 3222','PasswordAuthentication no','PubkeyAuthentication yes',
           'Subsystem sftp sftp-server.exe') + $c
    Set-Content $cfg $c -Encoding ascii }
  # ---- SSH shell + elevation + config validation -----------------------------
  # Without these a clone gets cmd.exe as its SSH shell and no elevated token.
  # The value of DefaultShellCommandOption MUST be a SINGLE token: sshd passes it
  # as one argv element, so '-NoLogo -NoProfile -Command' arrives as one literal
  # argument and pwsh rejects it, breaking every `ssh host 'cmd'` and scp.
  $pwshExe = 'C:\Program Files\PowerShell\7\pwsh.exe'
  if(Test-Path $pwshExe){
    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    New-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell              -Value $pwshExe -PropertyType String -Force | Out-Null
    New-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellCommandOption -Value '-c'     -PropertyType String -Force | Out-Null
    Log ("  SSH default shell = " + (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH').DefaultShell + "  option = " + (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH').DefaultShellCommandOption)
  } else { Log '  PowerShell 7 absent - SSH shell left as cmd.exe' }

  # A network logon hands an admin a UAC-FILTERED token, so the SSH session comes
  # up without admin rights and privileged commands fail quietly. Do NOT
  # New-Item -Force this key - it exists with a restrictive ACL and -Force tries
  # to recreate it ("unauthorized operation") even elevated.
  $polKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  if(-not (Test-Path $polKey)){ New-Item -Path $polKey -Force | Out-Null }
  & reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f 2>&1 | Out-Null
  Log ("  LocalAccountTokenFilterPolicy = " + (Get-ItemProperty $polKey -EA SilentlyContinue).LocalAccountTokenFilterPolicy + " (SSH gets a full admin token)")

  # Validate the config BEFORE the service is restarted, and BEFORE sealing -
  # every clone inherits whatever is written here.
  $sshdT = & "$bin\sshd.exe" -T 2>&1
  if($LASTEXITCODE -eq 0){
    Log ('  sshd -T OK: ' + (($sshdT | Select-String '^port |^passwordauthentication |^pubkeyauthentication |subsystem') -join ' | '))
  } else {
    Log ('  sshd -T REJECTED THE CONFIG: ' + (($sshdT | Select-Object -First 3) -join ' | '))
  }

  New-NetFirewallRule -DisplayName 'OpenSSH 3222' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3222 -Profile Any -EA SilentlyContinue|Out-Null
  $keys=@($SSHPubKeys | Where-Object { $_ -and $_.Trim() })
  # ERROR 57: sshd REFUSES administrators_authorized_keys unless the ACL is exactly
  # SYSTEM + BUILTIN\Administrators with inheritance BROKEN. Anything else (a stray
  # Users ACE inherited from C:\ProgramData) makes sshd ignore the file silently and
  # the keys "vanish" minutes after boot. Set it, then READ IT BACK and log the result.
  $ak='C:\ProgramData\ssh\administrators_authorized_keys'
  $keys=@($SSHPubKeys | Where-Object { $_ -and $_.Trim() })
  if($keys.Count){
    New-Item -ItemType Directory -Force 'C:\ProgramData\ssh' | Out-Null
    Set-Content $ak (($keys | ForEach-Object { $_.Trim() }) -join "`r`n") -Encoding ascii -Force
    & icacls $ak /inheritance:r                              2>$null | Out-Null
    & icacls $ak /grant '"NT AUTHORITY\SYSTEM:(F)"'          2>$null | Out-Null
    & icacls $ak /grant '"BUILTIN\Administrators:(F)"'       2>$null | Out-Null
    & icacls $ak /remove '"NT AUTHORITY\Authenticated Users"' '"BUILTIN\Users"' '"Everyone"' 2>$null | Out-Null
    $acl = (& icacls $ak 2>$null) -join ' '
    $clean = ($acl -notmatch 'Users:' -and $acl -notmatch 'Everyone:')
    Log ("  administrators_authorized_keys: $($keys.Count) key(s), ACL clean=$clean")
    if(-not $clean){ Log '  WARNING: extra ACEs still present - sshd may ignore the key file' }
    # C:\ProgramData\ssh itself must not be writable by Users either.
    & icacls 'C:\ProgramData\ssh' /inheritance:r /grant '"NT AUTHORITY\SYSTEM:(OI)(CI)F"' /grant '"BUILTIN\Administrators:(OI)(CI)F"' 2>$null | Out-Null
    # Host keys: private keys must be SYSTEM-only or sshd refuses to start.
    foreach($hk in (Get-ChildItem 'C:\ProgramData\ssh\ssh_host_*_key' -EA SilentlyContinue)){
      & icacls $hk.FullName /inheritance:r /grant '"NT AUTHORITY\SYSTEM:(F)"' /grant '"BUILTIN\Administrators:(F)"' 2>$null | Out-Null
    }
  } else { Log '  no SSH public keys configured - key auth will not work' }
  Set-Service sshd -StartupType Automatic -EA SilentlyContinue
  Restart-Service sshd -EA SilentlyContinue; Start-Sleep 2
  # verify it actually came up on 3222 (recorded in setup-log.txt so you can confirm without logging into the VM)
  $st=(Get-Service sshd -EA SilentlyContinue).Status
  $ls=@(Get-NetTCPConnection -LocalPort 3222 -State Listen -EA SilentlyContinue).Count -gt 0
  Log "  sshd status=$st  listening_on_3222=$ls  scp/sftp=on  auth=key-only  keys=$($keys.Count)  (per-clone host keys via GISSHInit firstboot)"
  if($st -ne 'Running' -or -not $ls){ Log '  WARNING: sshd not confirmed listening on 3222 on THIS build VM (clones still get GISSHInit firstboot regen).' }
}
Step '29 Expand-System-Drive' {
  $cp=Get-Partition -DriveLetter C
  $a=Get-Partition -DiskNumber $cp.DiskNumber|Where-Object{$_.Offset -gt $cp.Offset}|Sort-Object Offset|Select-Object -First 1
  if($a){Remove-Partition -DiskNumber $cp.DiskNumber -PartitionNumber $a.PartitionNumber -Confirm:$false}
  $max=(Get-PartitionSupportedSize -DriveLetter C).SizeMax
  if($max -gt $cp.Size){ Resize-Partition -DriveLetter C -Size $max -EA SilentlyContinue } else { Log '  C already full' }
}
Step '30 Generate-Seal-Unattend' {
  $xml=@'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="generalize">
    <!-- CRITICAL for VMs: skip the PnP driver-generalize step. Without this, sysprep's 'Sysprep Generalize
         Drivers' task loops on drivers like netvwifibus.inf (Err 0x2 'Unable to configure all driver packages')
         and NEVER reaches /shutdown - the VM generalizes OK but stays powered ON. Persisting device installs is
         correct for identical virtual hardware and lets sysprep shut down gracefully on 2016-2025. -->
    <component name="Microsoft-Windows-PnpSysprep" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PersistAllDeviceInstalls>true</PersistAllDeviceInstalls>
      <DoNotCleanUpNonPresentDevices>true</DoNotCleanUpNonPresentDevices>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>*</ComputerName><TimeZone>__TZ__</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous><RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
        <Order>1</Order><Path>cmd /c C:\Scripts\set-admin-console.cmd</Path></RunSynchronousCommand></RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><NetworkLocation>Work</NetworkLocation><ProtectYourPC>3</ProtectYourPC><SkipMachineOOBE>true</SkipMachineOOBE><SkipUserOOBE>true</SkipUserOOBE></OOBE>
      <!-- Blank built-in Administrator password: this ENABLES Administrator and SUPPRESSES the OOBE password screen
           on ALL versions incl. Server 2025 (that screen was blocking the console fallback on 2025). If cloud-init
           runs it overwrites this with the CloudStack password; if it does NOT run, FirstLogonCommands leaves the
           account blank + must-change-at-first-logon so the tech sets it from the console. -->
      <UserAccounts><AdministratorPassword><Value></Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd /c net user Administrator /active:yes</CommandLine><RequiresUserInput>false</RequiresUserInput></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>cmd /c C:\Scripts\set-admin-console.cmd</CommandLine><RequiresUserInput>false</RequiresUserInput></SynchronousCommand>
      </FirstLogonCommands>
      <TimeZone>__TZ__</TimeZone>
    </component>
  </settings>
</unattend>
'@.Replace('__TZ__',$TimeZone)
  Set-Content (Join-Path $Scripts 'Unattend-Seal.xml') $xml -Encoding utf8; Log '  Unattend-Seal.xml written'
}
Step '31 Generate-Userdata-Example' {
@'
#cloud-config
# Paste as instance User Data. Sets ONLY the Administrator password (edit it). Works on
# OpenStack + CloudStack (cloudbase-init). Change ADMIN_PASSWORD_HERE.
write_files:
  - path: C:\Windows\Temp\set-admin.ps1
    content: |
      $pw = ConvertTo-SecureString 'ADMIN_PASSWORD_HERE' -AsPlainText -Force
      net user Administrator /active:yes | Out-Null
      Set-LocalUser -Name Administrator -Password $pw
      Set-LocalUser -Name Administrator -PasswordNeverExpires $true
      net user Administrator /logonpasswordchg:no | Out-Null
      Remove-Item -Path $MyInvocation.MyCommand.Path -Force -EA SilentlyContinue
runcmd:
  - powershell.exe -ExecutionPolicy Bypass -File C:\Windows\Temp\set-admin.ps1
'@ | Set-Content (Join-Path $Scripts 'userdata-set-admin.yaml') -Encoding ascii
@'
#ps1_sysnative
# CloudStack/OpenStack DEPLOY-TIME userdata EXAMPLE. cloudbase-init runs this as SYSTEM on first boot.
# Uncomment + edit the lines you need. C:\Scripts is on the SYSTEM PATH; full paths shown for reliability.
$ErrorActionPreference='Continue'

# --- set Administrator password IF the template is NOT password-enabled (else CloudStack sets it) ---
# $pw = ConvertTo-SecureString 'ADMIN_PASSWORD_HERE' -AsPlainText -Force
# net user Administrator /active:yes | Out-Null; Set-LocalUser Administrator -Password $pw -PasswordNeverExpires $true

# --- register the STAGED agents you enabled (edit tokens/URLs; remove the ones you did not stage) ---
# & 'C:\Scripts\acronis-register.cmd'     -Token 'ACRONIS_TOKEN' -Url 'https://ae01-cloud.acronis.com'
# & 'C:\Scripts\bitdefender-register.cmd'
# & 'C:\Scripts\wazuh-register.cmd'       -Manager 'wazuh.example.com' -Group 'windows'
# & 'C:\Scripts\glpi-register.cmd'        -Server 'https://glpi.example.com/front/inventory.php' -Tag 'customerX'
# & 'C:\Scripts\osquery-register.cmd'     -FleetUrl 'fleet.example.com:443' -EnrollSecret 'SECRET'
# & 'C:\Scripts\site24x7-register.cmd'    -DeviceKey 'SITE24X7_DEVICE_KEY' -Name 'win-srv'
# & 'C:\Scripts\report-inventory.cmd'     -Install -PostUrl 'https://collector.example.com/api' -Tag 'customerX'

# --- grow C: to fill a (live-)resized disk / configure NIC (also automatic at boot) ---
# & 'C:\Scripts\grow-disk.cmd'
# & 'C:\Scripts\set-nic.cmd' -Name auto -DHCP
'@ | Set-Content (Join-Path $Scripts 'userdata-deploy-example.txt') -Encoding ascii
}
Step '32 Hide-Scripts-Folder' { (Get-Item $Scripts).Attributes = 'Directory,Hidden' }
Step '33 Cleanup-Temp' { Stop-Service wuauserv -EA SilentlyContinue; Remove-Item 'C:\Windows\SoftwareDistribution\Download\*','C:\Windows\Temp\*','C:\Users\*\AppData\Local\Temp\*' -Recurse -Force -EA SilentlyContinue }
Step '34 Clear-History-Logs' { Get-ChildItem 'C:\Users\*\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt' -EA SilentlyContinue|Remove-Item -Force -EA SilentlyContinue; Clear-History -EA SilentlyContinue }
Step '35 Desktop-Icons' {
  # show "This PC" (My Computer) on the desktop for the current user AND all future clone users (2016-2025)
  $GUID='{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
  foreach($base in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'){
    foreach($k in "$base\HideDesktopIcons\NewStartPanel","$base\HideDesktopIcons\ClassicStartMenu"){ New-Item -Path $k -Force|Out-Null; Set-ItemProperty $k $GUID 0 -Type DWord -Force -EA SilentlyContinue }
  }
  # apply to the DEFAULT user profile so every new profile on the clone also gets This PC
  reg load 'HKU\GIDEF' 'C:\Users\Default\NTUSER.DAT' 2>$null | Out-Null
  foreach($k in 'NewStartPanel','ClassicStartMenu'){ reg add "HKU\GIDEF\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\$k" /v $GUID /t REG_DWORD /d 0 /f 2>$null | Out-Null }
  reg unload 'HKU\GIDEF' 2>$null | Out-Null
  # remove the Everything + WinSCP desktop shortcuts (choco creates them) from every desktop
  $desks=@('C:\Users\Public\Desktop'); Get-ChildItem 'C:\Users' -Directory -EA SilentlyContinue | ForEach-Object { $desks += (Join-Path $_.FullName 'Desktop') }
  foreach($d in $desks){ Get-ChildItem $d -Filter '*.lnk' -EA SilentlyContinue | Where-Object { $_.Name -match 'everything|winscp' } | Remove-Item -Force -EA SilentlyContinue }
  Log '  This PC shown on desktop; Everything + WinSCP desktop shortcuts removed'
}
Step '36 Auto-Extend-Disk' {
@'
$ErrorActionPreference='SilentlyContinue'
try{ 'rescan' | diskpart | Out-Null }catch{}
try{ Update-HostStorageCache }catch{}
foreach($p in (Get-Partition -EA SilentlyContinue | Where-Object { $_.DriveLetter })){
  try{ $max=(Get-PartitionSupportedSize -DriveLetter $p.DriveLetter -EA Stop).SizeMax
       if($max -gt ($p.Size + 10MB)){ Resize-Partition -DriveLetter $p.DriveLetter -Size $max -EA Stop; Write-Host ("extended "+$p.DriveLetter+": -> "+[math]::Round($max/1GB,1)+" GB") } }catch{}
}
'@ | Set-Content (Join-Path $Scripts 'Grow-Disk.ps1') -Encoding ascii
@'
@echo off
rem grow-disk : rescan + extend all volumes to fill a (live-)resized disk - run anytime, no reboot needed
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Grow-Disk.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'grow-disk.cmd') -Encoding ascii
  Log '  grow-disk command written for LIVE CloudStack disk resize (auto-extend at boot now runs via YC-Boot)'
}
Step '37 Network-Helpers' {
@'
param([string]$Name,[switch]$DHCP,[string]$IP,[int]$Prefix=24,[string]$Gateway,[string[]]$DNS,[switch]$Rescan,[switch]$CleanGhosts,[switch]$List,[switch]$Help)
$ErrorActionPreference='SilentlyContinue'
if($Help -or (-not $DHCP -and -not $IP -and -not $Rescan -and -not $CleanGhosts -and -not $List)){
@"
set-nic  -  configure NICs on a CloudStack VM (DHCP or static IP/subnet/gateway/DNS), detect a live-added
            NIC, and clean ghost NICs left by MAC changes. Works 2016-2025.
USAGE:
  set-nic -List                                    show adapters (name, MAC, status, IP)
  set-nic -Rescan                                  detect a live hot-added NIC (no reboot)
  set-nic -Name <name|auto> -DHCP                  set the NIC to DHCP (IP + DNS)
  set-nic -Name <name|auto> -IP 10.0.0.5 -Prefix 24 -Gateway 10.0.0.1 -DNS 8.8.8.8,1.1.1.1   (static)
  set-nic -CleanGhosts                             remove hidden/ghost NICs left by MAC changes
NOTES: new NICs default to DHCP automatically (virtio NetKVM is injected). -Name auto = first connected NIC.
"@ | Write-Host -ForegroundColor Cyan; exit 0
}
if($Rescan){ try{ & "$env:WINDIR\System32\pnputil.exe" /scan-devices 2>$null | Out-Null }catch{}; Write-Host 'rescanned for new hardware.' -ForegroundColor Cyan }
if($List){ Get-NetAdapter | Sort-Object ifIndex | ForEach-Object { $ip=(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -EA SilentlyContinue | Select-Object -First 1).IPAddress; [pscustomobject]@{Name=$_.Name;MAC=$_.MacAddress;Status=$_.Status;IP=$ip} } | Format-Table -Auto }
if($CleanGhosts){ $c=0; try{ Get-PnpDevice -Class Net -EA SilentlyContinue | Where-Object { $_.Status -eq 'Unknown' } | ForEach-Object { try{ & "$env:WINDIR\System32\pnputil.exe" /remove-device $_.InstanceId 2>$null | Out-Null; $c++ }catch{} } }catch{}; Write-Host ("cleaned "+$c+" ghost NIC(s).") -ForegroundColor Cyan }
if($DHCP -or $IP){
  $ad = if($Name -and $Name -ne 'auto'){ Get-NetAdapter | Where-Object { $_.Name -eq $Name -or $_.MacAddress -eq $Name } | Select-Object -First 1 } else { Get-NetAdapter | Where-Object Status -eq 'Up' | Sort-Object ifIndex | Select-Object -First 1 }
  if(-not $ad){ Write-Host 'no matching NIC.' -ForegroundColor Red; exit 1 }
  $idx=$ad.ifIndex
  if($DHCP){
    Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -EA SilentlyContinue | Where-Object { $_.PrefixOrigin -eq 'Manual' } | Remove-NetIPAddress -Confirm:$false -EA SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $idx -Dhcp Enabled -EA SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -EA SilentlyContinue
    ipconfig /renew 2>$null | Out-Null
    Write-Host ("set "+$ad.Name+" to DHCP.") -ForegroundColor Green
  } else {
    Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -EA SilentlyContinue | Remove-NetIPAddress -Confirm:$false -EA SilentlyContinue
    Remove-NetRoute -InterfaceIndex $idx -Confirm:$false -EA SilentlyContinue
    New-NetIPAddress -InterfaceIndex $idx -IPAddress $IP -PrefixLength $Prefix -DefaultGateway $Gateway -EA SilentlyContinue | Out-Null
    if($DNS){ Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $DNS -EA SilentlyContinue }
    Write-Host ("set "+$ad.Name+" static "+$IP+"/"+$Prefix+" gw "+$Gateway) -ForegroundColor Green
  }
}
exit 0
'@ | Set-Content (Join-Path $Scripts 'Set-Nic.ps1') -Encoding ascii
@'
@echo off
rem set-nic : DHCP/static IP+subnet+gateway+DNS, rescan live NICs, clean ghost NICs after MAC changes
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Set-Nic.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'set-nic.cmd') -Encoding ascii
  Log '  set-nic command (DHCP/static/rescan/clean-ghosts) written; ghost-NIC cleanup at boot now runs via YC-Boot'
}
Step '38 Diag-Tools' {
  # Diagnostics are STAGED AS FILES, never INSTALLED into the golden image. Only SAFE, non-suspicious admin tools
  # are staged - NO network-scanning / pentest tooling (nmap and its Npcap driver were removed on purpose: AV/EDR
  # flag them and customers find them alarming on a delivered template). Portable tools (testdisk/photorec, iperf3
  # throughput test) are extracted ready-to-run and on PATH; installer-type tools (smartmontools SMART, Log Parser)
  # are dropped as files and installed ON THE DEPLOYED VM on demand via 'diagtools-install'. curl is already built
  # into Windows. Sysinternals is unpacked in C:\Scripts\Sysinternals. The diag/perflog report scripts below
  # (built-in tools + smartctl-if-present) are ALWAYS written. Toggle: $StageDiagTools.
  if($StageDiagTools){
    $dtf=Join-Path $Scripts 'DiagTools'; New-Item -ItemType Directory -Force $dtf|Out-Null
    # installer files - STAGED only (installed later by diagtools-install), so nothing is baked into the template
    # smartmontools: sourceforge 'latest/download' is a REDIRECT CHAIN that BITS and
    # Invoke-WebRequest both give up on - it MISSes even when the network is fine.
    # Pre-stage it (runbook 2c) and the guard in Get-File skips the download entirely.
    # THRESHOLD BUG, found 2026-08-11 by auditing a live clone: the staged file is
    # 130,427 B (the SourceForge web-installer stub, not a full setup). The old
    # min of 300KB meant Get-File judged the PRE-STAGED copy "incomplete", DELETED
    # it, re-downloaded through the sourceforge redirect chain, and logged MISS -
    # while the correct file had been sitting there all along. 100KB is right for
    # this artefact.
    if(-not (Test-Path (Join-Path $dtf 'smartmontools-setup.exe'))){
      Get-File 'https://sourceforge.net/projects/smartmontools/files/latest/download' (Join-Path $dtf 'smartmontools-setup.exe') (100KB) | Out-Null
      if(-not (Test-Path (Join-Path $dtf 'smartmontools-setup.exe'))){
        Log '  smartmontools NOT downloaded (sourceforge redirect). Pre-stage it from goldenstuff/tools/DiagTools/ - see runbook 1.2.' }
    } else { Log '  pre-staged, skipping download: smartmontools-setup.exe' }
    # LOG PARSER IS DEAD. Microsoft withdrew LogParser.msi - that URL 404s for everyone
    # and no supported replacement is published. Replaced with maintained OSS that does
    # the same job better, both single-binary GitHub releases:
    #   Hayabusa - evtx -> timeline/CSV + built-in detection rules (GPL-3)
    #   klogg    - fast GUI viewer/tailer for huge text logs (GPL-3)
    # Built-in Get-WinEvent / wevtutil already cover ad-hoc queries, so nothing is lost.
    # Asset names are VERSIONED (hayabusa-3.4.0-win-x64.zip), so /releases/latest/download/<name>
    # 404s - that is why both were MISS on every 2026-08-11 build. Resolve via the API instead.
    function Resolve-GhAsset([string]$repo,[string]$rx){
      try{
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing `
             -Headers @{ 'User-Agent'='YallaCloud-GoldenImage' } -TimeoutSec 60
        $a = $r.assets | Where-Object { $_.name -match $rx } | Select-Object -First 1
        if($a){ Log ("  resolved $repo -> " + $a.name); return $a.browser_download_url }
      }catch{ Log "  $repo API resolve failed: $($_.Exception.Message)" }
      return $null
    }
    $hay = Resolve-GhAsset 'Yamato-Security/hayabusa' 'win.*x64.*\.zip$'
    if($hay -and (Get-File $hay (Join-Path $dtf 'hayabusa.zip') (500KB))){
      try{ Expand-Archive (Join-Path $dtf 'hayabusa.zip') (Join-Path $dtf 'hayabusa') -Force
           Remove-Item (Join-Path $dtf 'hayabusa.zip') -Force -EA SilentlyContinue
           Log '  hayabusa extracted (evtx timeline + detection rules, replaces Log Parser)' }
      catch{ Log "  hayabusa unpack failed: $($_.Exception.Message)" }
    } else { Log '  hayabusa MISS - pre-stage or fetch later; Get-WinEvent still covers ad-hoc queries' }
    $klg = Resolve-GhAsset 'variar/klogg' '(portable|win).*(x86_64|x64).*\.zip$'
    if($klg -and (Get-File $klg (Join-Path $dtf 'klogg.zip') (500KB))){
      try{ Expand-Archive (Join-Path $dtf 'klogg.zip') (Join-Path $dtf 'klogg') -Force
           Remove-Item (Join-Path $dtf 'klogg.zip') -Force -EA SilentlyContinue
           Log '  klogg extracted (portable large-log viewer)' }
      catch{ Log "  klogg unpack failed: $($_.Exception.Message)" }
    } else { Log '  klogg MISS - optional viewer, not required' }

    # ---- evtx-hunt : hayabusa wrapper (the Log Parser replacement) --------------
@'
param([string]$OutFile,[string]$EvtxDir,[switch]$Live,[switch]$Help)
$hb = Get-ChildItem 'C:\Scripts\DiagTools\hayabusa' -Recurse -Filter 'hayabusa*.exe' -EA SilentlyContinue | Select-Object -First 1
if($Help -or -not $hb){ @"
evtx-hunt  -  Windows event-log timeline + detections (hayabusa). Replaces the withdrawn Log Parser.
USAGE:
  evtx-hunt [-Live] [-EvtxDir <path>] [-OutFile <csv>] [-Help]
PARAMETERS:
  -Live      scan THIS machine's live logs (C:\Windows\System32\winevt\Logs)   [default]
  -EvtxDir   scan a folder of .evtx files collected from elsewhere
  -OutFile   CSV to write (default C:\Scripts\evtx-hunt-<timestamp>.csv)
  -Help      this text
EXAMPLES:
  evtx-hunt
  evtx-hunt -EvtxDir D:\collected\evtx -OutFile C:\Scripts\case1.csv
NOTES:
  Built-in alternatives for one-off queries:  Get-WinEvent -FilterHashtable @{LogName='System';Level=2}
  and  wevtutil qe System /c:50 /rd:true /f:text
"@ | Write-Host -ForegroundColor Cyan
  if(-not $hb){ Write-Host 'hayabusa not staged - see diagtools-install' -ForegroundColor Yellow }
  exit 0 }
if(-not $OutFile){ $OutFile = 'C:\Scripts\evtx-hunt-' + (Get-Date -f 'yyyyMMdd-HHmmss') + '.csv' }
$dir = if($EvtxDir){ $EvtxDir } else { 'C:\Windows\System32\winevt\Logs' }
Write-Host ("hayabusa csv-timeline -d " + $dir + " -o " + $OutFile) -ForegroundColor Cyan
& $hb.FullName csv-timeline -d $dir -o $OutFile -w -q
Write-Host ("wrote " + $OutFile) -ForegroundColor Green
'@ | Set-Content (Join-Path $Scripts 'Evtx-Hunt.ps1') -Encoding ascii
    Set-Content (Join-Path $Scripts 'evtx-hunt.cmd') "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Evtx-Hunt.ps1`" %*`r`n" -Encoding ascii

    # ---- logview : klogg launcher ---------------------------------------------
@'
param([string]$Path,[switch]$Help)
$kl = Get-ChildItem 'C:\Scripts\DiagTools\klogg' -Recurse -Filter 'klogg.exe' -EA SilentlyContinue | Select-Object -First 1
if($Help -or -not $kl){ @"
logview  -  open a large log file in klogg (fast viewer/tailer, GPL-3).
USAGE:      logview [-Path <file>] [-Help]
PARAMETERS: -Path  log to open (default C:\Scripts\setup-log.txt)
EXAMPLES:   logview
            logview -Path C:\Scripts\yc-firstboot.log
NOTES:      headless box? use  Get-Content <file> -Tail 50 -Wait
"@ | Write-Host -ForegroundColor Cyan
  if(-not $kl){ Write-Host 'klogg not staged - see diagtools-install' -ForegroundColor Yellow }
  exit 0 }
if(-not $Path){ $Path = 'C:\Scripts\setup-log.txt' }
& $kl.FullName $Path
'@ | Set-Content (Join-Path $Scripts 'LogView.ps1') -Encoding ascii
    Set-Content (Join-Path $Scripts 'logview.cmd') "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0LogView.ps1`" %*`r`n" -Encoding ascii
    Log '  evtx-hunt (hayabusa) + logview (klogg) commands written'
    # portable tools - extracted ready-to-run (files only, no install)
    if(Get-File 'https://www.cgsecurity.org/testdisk-7.2.win64.zip' (Join-Path $dtf 'testdisk.zip') (500KB)){ try{ Expand-Archive (Join-Path $dtf 'testdisk.zip') $dtf -Force; Remove-Item (Join-Path $dtf 'testdisk.zip') -Force -EA SilentlyContinue; Log '  testdisk/photorec extracted (portable)' }catch{ Log "  testdisk unpack failed: $($_.Exception.Message)" } }
    if(Get-File 'https://iperf.fr/download/windows/iperf-3.1.3-win64.zip' (Join-Path $dtf 'iperf3.zip') (50KB)){ try{ Expand-Archive (Join-Path $dtf 'iperf3.zip') (Join-Path $dtf 'iperf3') -Force; Remove-Item (Join-Path $dtf 'iperf3.zip') -Force -EA SilentlyContinue; Log '  iperf3 extracted (portable)' }catch{ Log "  iperf3 unpack failed: $($_.Exception.Message)" } }
    # add DiagTools + its extracted tool subfolders to SYSTEM PATH so portable exes run by name from anywhere
    $mp=[Environment]::GetEnvironmentVariable('Path','Machine'); $cur=@($mp -split ';')
    $add=@($dtf)+@(Get-ChildItem $dtf -Directory -EA SilentlyContinue|ForEach-Object{$_.FullName})
    foreach($w in $add){ if($cur -notcontains $w){ $mp=$mp.TrimEnd(';')+';'+$w; $cur+=$w; $env:Path+=';'+$w } }
    [Environment]::SetEnvironmentVariable('Path',$mp,'Machine')
    # diagtools-install : install the STAGED installer-type tools on the DEPLOYED VM (run only when actually needed)
@'
param([switch]$Help)
$dt="C:\Scripts\DiagTools"
if($Help){ @"
diagtools-install  -  install the STAGED diagnostic tools on THIS (deployed) VM.
  Silent installs: smartmontools (/S), Log Parser 2.2 (LogParser.msi /qn).
  Portable tools (testdisk, photorec, iperf3) are ALREADY extracted under C:\Scripts\DiagTools and on PATH - no install needed.
  Run on the deployed clone only when you actually need SMART / Log Parser installed. (No nmap/pentest tooling is included.)
"@ | Write-Host -ForegroundColor Cyan; exit 0 }
if(-not (Test-Path $dt)){ Write-Host "No staged tools at $dt" -ForegroundColor Red; exit 1 }
$s=Join-Path $dt 'smartmontools-setup.exe'; if(Test-Path $s){ Write-Host 'Installing smartmontools (silent)...' -ForegroundColor Cyan; Start-Process $s -ArgumentList '/S' -Wait }
$l=Join-Path $dt 'LogParser.msi';           if(Test-Path $l){ Write-Host 'Installing Log Parser 2.2 (silent)...' -ForegroundColor Cyan; Start-Process msiexec.exe -ArgumentList "/i `"$l`" /qn" -Wait }
Write-Host 'diagtools-install done.' -ForegroundColor Green
'@ | Set-Content (Join-Path $Scripts 'DiagTools-Install.ps1') -Encoding ascii
@'
@echo off
rem diagtools-install [-Help]   install the STAGED smartmontools/logparser on THIS deployed VM
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\DiagTools-Install.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'diagtools-install.cmd') -Encoding ascii
    Log '  diag tools STAGED as files -> C:\Scripts\DiagTools (portable testdisk/photorec/iperf3 ready; smartmontools/logparser via diagtools-install; NO nmap/pentest tooling)'
  } else { Log '  diag tools staging skipped (prompt=no); diag + perflog report commands still created' }
@'
@echo off
rem perflog [seconds]  ->  C:\Scripts\perflog-<n>.csv   (CPU, memory, disk, network via typeperf)
set SECS=%1
if "%SECS%"=="" set SECS=60
set OUT=C:\Scripts\perflog-%RANDOM%.csv
echo Logging performance for %SECS%s to %OUT% ...
typeperf "\Processor(_Total)\%% Processor Time" "\Memory\Available MBytes" "\PhysicalDisk(_Total)\%% Disk Time" "\PhysicalDisk(_Total)\Avg. Disk Queue Length" "\Network Interface(*)\Bytes Total/sec" -si 1 -sc %SECS% -f CSV -o "%OUT%"
echo Done: %OUT%
'@ | Set-Content (Join-Path $Scripts 'perflog.cmd') -Encoding ascii
@'
$out="C:\Scripts\diag-$(Get-Date -f yyyyMMdd-HHmmss).txt"
function S($t){ "" | Out-File $out -Append -Encoding ascii; "===== $t =====" | Out-File $out -Append -Encoding ascii }
"System Diagnostic Report  $(Get-Date)  $env:COMPUTERNAME" | Out-File $out -Encoding ascii
S 'OS';          Get-CimInstance Win32_OperatingSystem | Format-List Caption,Version,BuildNumber,LastBootUpTime | Out-File $out -Append
S 'Boot config'; bcdedit /enum 2>&1 | Out-File $out -Append
S 'Disks + SMART';   Get-PhysicalDisk -EA SilentlyContinue | Format-Table FriendlyName,MediaType,HealthStatus,@{n="GB";e={[int]($_.Size/1GB)}} -Auto | Out-File $out -Append
Get-CimInstance -Namespace root\wmi -Class MSStorageDriver_FailurePredictStatus -EA SilentlyContinue | Format-Table InstanceName,PredictFailure -Auto | Out-File $out -Append
if(Get-Command smartctl -EA SilentlyContinue){ (smartctl --scan) 2>&1 | Out-File $out -Append }
S 'Volumes';     Get-Volume -EA SilentlyContinue | Format-Table DriveLetter,FileSystem,HealthStatus,@{n="FreeGB";e={[int]($_.SizeRemaining/1GB)}},@{n="GB";e={[int]($_.Size/1GB)}} -Auto | Out-File $out -Append
S 'chkdsk C: (read-only)'; cmd /c "chkdsk C:" 2>&1 | Out-File $out -Append
S 'SFC verifyonly';        cmd /c "sfc /verifyonly" 2>&1 | Out-File $out -Append
S 'DISM CheckHealth';      DISM /Online /Cleanup-Image /CheckHealth 2>&1 | Out-File $out -Append
S 'Last 30 System errors'; Get-WinEvent -FilterHashtable @{LogName="System";Level=1,2} -MaxEvents 30 -EA SilentlyContinue | Format-Table TimeCreated,Id,ProviderName -Auto | Out-File $out -Append
S 'Unexpected shutdown / bugcheck (41,6008,1001)'; Get-WinEvent -FilterHashtable @{LogName="System";Id=41,6008,1001} -MaxEvents 15 -EA SilentlyContinue | Format-Table TimeCreated,Id -Auto | Out-File $out -Append
S 'Last 20 Application errors'; Get-WinEvent -FilterHashtable @{LogName="Application";Level=1,2} -MaxEvents 20 -EA SilentlyContinue | Format-Table TimeCreated,Id,ProviderName -Auto | Out-File $out -Append
Write-Host "diagnostic report: $out" -ForegroundColor Green
'@ | Set-Content (Join-Path $Scripts 'Diag-System.ps1') -Encoding ascii
@'
@echo off
rem diag : forensic/health report (boot, disk+SMART, chkdsk/sfc/DISM, event errors, BSOD) -> C:\Scripts\diag-*.txt
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Diag-System.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'diag.cmd') -Encoding ascii
  Log '  diag + perflog report commands written (staged tools: see diagtools-install; report scripts use built-in tools + smartctl if installed)'
}
Step '39 Disk-Integrity' {
  fsutil repair set C: 1 2>$null | Out-Null           # NTFS self-healing ON
  chkntfs /d 2>$null | Out-Null                       # default autochk (auto-fix the dirty bit at next boot)
@'
$ErrorActionPreference='SilentlyContinue'
$log="C:\Scripts\disk-guard.log"; function L($m){ "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $m" | Out-File -Append $log -Encoding ascii }
foreach($d in (Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' } | ForEach-Object { $_.DriveLetter })){
  if((cmd /c "fsutil dirty query ${d}:") -match 'is Dirty'){ L "${d}: DIRTY -> chkdsk /spotfix"; cmd /c "echo Y| chkdsk ${d}: /spotfix" | Out-Null }
  else { L "${d}: online /scan"; cmd /c "chkdsk ${d}: /scan" | Out-Null }
}
'@ | Set-Content (Join-Path $Scripts 'Disk-Guard.ps1') -Encoding ascii
  Log '  NTFS self-healing on + Disk-Guard.ps1 written (dirty-check/scan now runs via YC-Health, daily 03:30)'
}
Step '40 Crash-Diagnostics' {
  # make BSODs leave evidence to root-cause: automatic memory dump + keep minidumps + log event + auto-reboot
  $cc='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
  Set-ItemProperty $cc CrashDumpEnabled 7 -Type DWord -Force -EA SilentlyContinue   # 7 = Automatic memory dump
  Set-ItemProperty $cc LogEvent 1 -Type DWord -Force -EA SilentlyContinue
  Set-ItemProperty $cc AutoReboot 1 -Type DWord -Force -EA SilentlyContinue
  Set-ItemProperty $cc Overwrite 1 -Type DWord -Force -EA SilentlyContinue
  try{ $csx=Get-CimInstance Win32_ComputerSystem; if(-not $csx.AutomaticManagedPagefile){ $csx | Set-CimInstance -Property @{AutomaticManagedPagefile=$true} -EA SilentlyContinue } }catch{}
@'
param([switch]$Latest)
$ErrorActionPreference='SilentlyContinue'
$out= if($Latest){'C:\Scripts\rootcause-latest.txt'} else {"C:\Scripts\rootcause-$(Get-Date -f yyyyMMdd-HHmmss).txt"}
'' | Out-File $out -Encoding ascii; function W($m){ $m | Out-File -Append $out -Encoding ascii }
$stop=@{'0x0000007a'='DISK/storage read fault (KERNEL_DATA_INPAGE)';'0x00000077'='DISK (KERNEL_STACK_INPAGE)';'0x0000007b'='DISK/controller/driver (INACCESSIBLE_BOOT_DEVICE)';'0x00000024'='NTFS corruption (NTFS_FILE_SYSTEM)';'0x000000f4'='OS/DISK (CRITICAL_OBJECT_TERMINATION)';'0x000000ef'='OS (CRITICAL_PROCESS_DIED)';'0x000000d1'='DRIVER (DRIVER_IRQL_NOT_LESS_OR_EQUAL)';'0x0000000a'='DRIVER (IRQL_NOT_LESS_OR_EQUAL)';'0x0000003b'='DRIVER/OS (SYSTEM_SERVICE_EXCEPTION)';'0x0000001e'='DRIVER (KMODE_EXCEPTION)';'0x00000050'='RAM/DRIVER (PAGE_FAULT_IN_NONPAGED_AREA)';'0x00000133'='DRIVER/storage (DPC_WATCHDOG)';'0x00000139'='DRIVER (KERNEL_SECURITY_CHECK)'}
W ("ROOT-CAUSE REPORT  "+(Get-Date)+"  "+$env:COMPUTERNAME)
W '== BSOD bugchecks (System event 1001) =='
Get-WinEvent -FilterHashtable @{LogName='System';Id=1001} -MaxEvents 8 -EA SilentlyContinue | ForEach-Object { $c=([regex]'0x[0-9a-fA-F]{8}').Match($_.Message).Value.ToLower(); W ("  "+$_.TimeCreated+"  "+$c+"  => "+$(if($stop[$c]){$stop[$c]}else{'look up this STOP code'})) }
W '== Disk / storage / NTFS errors (Ntfs, disk, vioscsi, viostor, storahci, stornvme) =='
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Ntfs','disk','volmgr','vioscsi','viostor','storahci','stornvme'} -MaxEvents 20 -EA SilentlyContinue | Format-Table TimeCreated,Id,ProviderName -Auto | Out-String | ForEach-Object { W $_ }
W '== SMART / physical disk health =='
Get-PhysicalDisk -EA SilentlyContinue | Format-Table FriendlyName,HealthStatus,OperationalStatus,@{n='GB';e={[int]($_.Size/1GB)}} -Auto | Out-String | ForEach-Object { W $_ }
W '== NTFS dirty bit =='
Get-Volume -EA SilentlyContinue | Where-Object DriveLetter | ForEach-Object { W ('  '+(cmd /c ("fsutil dirty query "+$_.DriveLetter+":"))) }
W '== Network adapter / TCP / DHCP errors =='
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='netkvm','NDIS','Tcpip','Tcpip6','Microsoft-Windows-Dhcp-Client'} -MaxEvents 15 -EA SilentlyContinue | Format-Table TimeCreated,Id,ProviderName -Auto | Out-String | ForEach-Object { W $_ }
W '== Recent System criticals/errors =='
Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2} -MaxEvents 25 -EA SilentlyContinue | Format-Table TimeCreated,Id,ProviderName -Auto | Out-String | ForEach-Object { W $_ }
W '== Latest minidumps =='
Get-ChildItem 'C:\Windows\Minidump\*.dmp' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name,LastWriteTime | Out-String | ForEach-Object { W $_ }
$cdb=(Get-ChildItem 'C:\Program Files*\Windows Kits\*\Debuggers\x64\cdb.exe' -EA SilentlyContinue | Select-Object -First 1).FullName
if($cdb){ $dmp=Get-ChildItem 'C:\Windows\Minidump\*.dmp' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if($dmp){ W '== cdb !analyze -v (culprit driver/module) =='; (& $cdb -z $dmp.FullName -c "!analyze -v; q") 2>&1 | Select-String 'BUGCHECK_CODE|MODULE_NAME|IMAGE_NAME|FAILURE_BUCKET_ID|Probably caused by' | Out-String | ForEach-Object { W $_ } } }
Write-Host ("root-cause report: "+$out) -ForegroundColor Green
'@ | Set-Content (Join-Path $Scripts 'Root-Cause.ps1') -Encoding ascii
@'
@echo off
rem rootcause : classify last crash/issue (disk / OS / driver / network) + BSOD STOP code -> C:\Scripts\rootcause-*.txt
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Root-Cause.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'rootcause.cmd') -Encoding ascii
  Log '  crash dumps configured (auto memory dump + minidumps) + rootcause command written (report now runs via YC-Health, daily 03:30)'
}
Step '41 Keep-WindowsUpdate-On' {
  # keep Windows Update ENABLED so deployed clones auto-download + install updates on their own
  Set-Service wuauserv -StartupType Manual -EA SilentlyContinue       # trigger-start default (NOT disabled)
  Set-Service usosvc  -StartupType Automatic -EA SilentlyContinue
  Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Recurse -Force -EA SilentlyContinue  # clear any WU-blocking policy
  $au='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
  New-Item $au -Force | Out-Null
  Set-ItemProperty $au NoAutoUpdate 0 -Type DWord -Force -EA SilentlyContinue
  Set-ItemProperty $au AUOptions 4 -Type DWord -Force -EA SilentlyContinue   # 4 = auto download + scheduled install
  Log '  Windows Update kept ON (auto download+install) for deployed clones'
}
Step '42 Install-Scoop-Ntfy' {
  # Scoop SYSTEM-WIDE alongside Chocolatey. Best-effort: if it can't install under the SYSTEM account, the
  # build never blocks - the 'notify' command + build notifications use HTTP and DO NOT depend on Scoop/ntfy CLI.
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  [Environment]::SetEnvironmentVariable('SCOOP','C:\Scoop','Machine'); $env:SCOOP='C:\Scoop'
  [Environment]::SetEnvironmentVariable('SCOOP_GLOBAL','C:\Scoop\global','Machine'); $env:SCOOP_GLOBAL='C:\Scoop\global'
  if(-not $env:USERPROFILE){ $env:USERPROFILE='C:\Users\Default' }   # some SYSTEM contexts have no profile var
  if(-not (Test-Path 'C:\Scoop\shims\scoop.cmd') -and -not (Get-Command scoop -EA SilentlyContinue)){
    try{ Invoke-Expression "& {$(Invoke-RestMethod -Uri https://get.scoop.sh -TimeoutSec 60)} -RunAsAdmin" }catch{ Log "  scoop install skipped (SYSTEM ctx?): $($_.Exception.Message)" }
  }
  $mp=[Environment]::GetEnvironmentVariable('Path','Machine'); if(($mp -split ';') -notcontains 'C:\Scoop\shims'){ $mp=$mp.TrimEnd(';')+';C:\Scoop\shims'; [Environment]::SetEnvironmentVariable('Path',$mp,'Machine'); $env:Path+=';C:\Scoop\shims' }
  $scoop=(Get-Command scoop -EA SilentlyContinue).Source; if(-not $scoop){ $scoop='C:\Scoop\shims\scoop.cmd' }
  if(Test-Path $scoop){ try{ & $scoop install -g ntfy 2>$null | Out-Null; Log '  scoop + ntfy CLI installed (global)' }catch{ Log "  scoop ntfy install skipped: $($_.Exception.Message)" } } else { Log '  scoop not available - notify command still works via HTTP' }
  # standalone fallback: if the ntfy CLI still is not on PATH, download it straight to C:\Scripts (latest release)
  if(-not (Get-Command ntfy -EA SilentlyContinue) -and -not (Test-Path 'C:\Scoop\shims\ntfy.exe') -and -not (Test-Path (Join-Path $Scripts 'ntfy.exe'))){
    try{
      $rel=Invoke-RestMethod 'https://api.github.com/repos/binwiederhier/ntfy/releases/latest' -Headers @{ 'User-Agent'='GoldenImage' } -TimeoutSec 30
      $url=($rel.assets | Where-Object { $_.name -match 'windows_amd64\.zip$' } | Select-Object -First 1).browser_download_url
      if($url){ $z=Join-Path $Scripts 'ntfy.zip'; if(Get-File $url $z (300KB)){ $td=Join-Path $Scripts '_ntfy'; Expand-Archive $z $td -Force; $exe=Get-ChildItem $td -Recurse -Filter ntfy.exe -EA SilentlyContinue | Select-Object -First 1; if($exe){ Copy-Item $exe.FullName (Join-Path $Scripts 'ntfy.exe') -Force }; Remove-Item $z,$td -Recurse -Force -EA SilentlyContinue; Log '  ntfy standalone downloaded to C:\Scripts (scoop fallback)' } }
    }catch{ Log "  ntfy standalone fallback skipped: $($_.Exception.Message)" }
  }
  # 'notify <message>' publishes to the build ntfy topic from cmd/PowerShell (HTTP - always works, no CLI needed)
@'
@echo off
rem notify <message>   publishes to the build ntfy topic
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $m='%*'; if(-not $m){$m='ping'}; try{ Invoke-RestMethod -Uri '__NTFY__' -Method Post -Body $m -TimeoutSec 15 | Out-Null; Write-Host sent }catch{ Write-Host 'ntfy failed' }"
'@.Replace('__NTFY__',$NtfyTopic) | Set-Content (Join-Path $Scripts 'notify.cmd') -Encoding ascii
  Log '  Scoop (system-wide) + ntfy + notify command; choco + scoop both in system env'
}
Step '43 Activation-Helpers' {
  # staged commands to convert Windows/SQL EVALUATION -> Volume License at DEPLOY (via cloud-init).
  # NOTHING is activated during the build - the image stays Evaluation until you run these on the clone.
@'
param([string]$ProductKey,[string]$Edition,[string]$KMS,[switch]$Help)
$ErrorActionPreference='Continue'
if($Help -or -not $ProductKey){
@"
activate-windows  -  convert Windows Server EVALUATION -> Volume License and activate (run at DEPLOY, as Admin).
SUPPORTS: Windows Server 2012 R2 / 2016 / 2019 / 2022 / 2025 - ALL editions (Standard / Datacenter).
USAGE:
  activate-windows -ProductKey <GVLK-or-MAK> [-Edition ServerStandard|ServerDatacenter] [-KMS <kms-host[:port]>]
  activate-windows -Help
NOTES: if the OS is EVALUATION this changes the edition (ONE-WAY, needs a REBOOT) then auto-activates on that
       reboot (RunOnce). Use the KMS client GVLK matching your exact OS version+edition (+ -KMS host) or a MAK.
       Eval stays eval until you run this. Provide it via cloud-init userdata to automate at deploy.
"@ | Write-Host -ForegroundColor Cyan; if($Help){ exit 0 } else { exit 1 }
}
$slmgr="cscript //nologo $env:WINDIR\System32\slmgr.vbs"
$km = if($ProductKey.Length -gt 5){ ('*' * ($ProductKey.Length-5)) + $ProductKey.Substring($ProductKey.Length-5) } else { '*****' }
$os = Get-CimInstance Win32_OperatingSystem
$cur = ((dism /online /Get-CurrentEdition) 2>$null | Select-String 'Current Edition' | ForEach-Object { ($_ -split ':')[-1].Trim() })
$lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -EA SilentlyContinue | Select-Object -First 1
$st=@{0='Unlicensed';1='Licensed';2='OOB-Grace';3='OOT-Grace';4='Non-Genuine';5='Notification';6='Extended-Grace'}
Write-Host "==== Windows activation ====" -ForegroundColor Cyan
Write-Host ("  OS        : "+$os.Caption+"  ("+$os.Version+")")
Write-Host ("  Edition   : "+$cur)
Write-Host ("  License   : "+$(if($lic){$st[[int]$lic.LicenseStatus]}else{'Unknown'}))
Write-Host ("  Using key : "+$km)   # key masked
if("$cur" -match 'Eval'){
  if(-not $Edition){ $Edition = ("$cur" -replace 'Eval$','') }
  Write-Host ("Converting evaluation -> "+$Edition+" (reboot required to finish)...") -ForegroundColor Yellow
  dism /online /Set-Edition:$Edition /ProductKey:$ProductKey /AcceptEula /NoRestart
  $ato = if($KMS){ "cmd /c $env:WINDIR\System32\cscript.exe //nologo $env:WINDIR\System32\slmgr.vbs /skms $KMS & cscript //nologo $env:WINDIR\System32\slmgr.vbs /ato" } else { "cmd /c cscript //nologo $env:WINDIR\System32\slmgr.vbs /ato" }
  reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v ActivateWindows /t REG_SZ /d $ato /f | Out-Null
  Write-Host 'Edition change staged. REBOOT now - activation runs automatically after the reboot.' -ForegroundColor Yellow
} else {
  iex "$slmgr /ipk $ProductKey"
  if($KMS){ iex "$slmgr /skms $KMS" }
  iex "$slmgr /ato"
  Write-Host 'Activation attempted. Verify: slmgr /dlv' -ForegroundColor Green
}
exit 0
'@ | Set-Content (Join-Path $Scripts 'Activate-Windows.ps1') -Encoding ascii
@'
@echo off
rem activate-windows -ProductKey <k> [-Edition ServerStandard|ServerDatacenter] [-KMS <host>] [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Activate-Windows.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'activate-windows.cmd') -Encoding ascii
@'
param([string]$ProductKey,[string]$InstanceName='MSSQLSERVER',[string]$SetupPath,[switch]$Help)
$ErrorActionPreference='Continue'
if($Help -or -not $ProductKey){
@"
activate-sql  -  upgrade SQL Server EVALUATION -> licensed edition (edition upgrade) at DEPLOY (run as Admin).
SUPPORTS: SQL Server 2012 / 2014 / 2016 / 2017 / 2019 / 2022 / 2025-2026 - ALL editions (Standard/Enterprise/Web/Developer/Express).
USAGE:
  activate-sql -ProductKey <SQL-product-key> [-InstanceName MSSQLSERVER] [-SetupPath <path\setup.exe>]
  activate-sql -Help
NOTES: uses SQL Server setup /ACTION=EditionUpgrade. Auto-finds the instance setup.exe (Setup Bootstrap);
       if not found pass -SetupPath to your SQL media setup.exe. The key must match the SQL VERSION + target
       edition. Eval stays eval until you run this. Provide it via cloud-init userdata to automate at deploy.
"@ | Write-Host -ForegroundColor Cyan; if($Help){ exit 0 } else { exit 1 }
}
$km = if($ProductKey.Length -gt 5){ ('*' * ($ProductKey.Length-5)) + $ProductKey.Substring($ProductKey.Length-5) } else { '*****' }
Write-Host "==== SQL Server activation ====" -ForegroundColor Cyan
foreach($root in 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server'){
  $inst=Get-ItemProperty "$root\Instance Names\SQL" -EA SilentlyContinue
  if($inst){ foreach($p in ($inst.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })){ $s=Get-ItemProperty "$root\$($p.Value)\Setup" -EA SilentlyContinue; if($s){ Write-Host ("  Instance "+$p.Name+" : "+$s.Edition+"  v"+$s.Version+"  ("+$s.PatchLevel+")") } } }
}
Write-Host ("  Using key : "+$km)   # key masked
$setup=$SetupPath
if(-not $setup){ $setup=(Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\*\setup.exe' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName }
if(-not $setup -or -not (Test-Path $setup)){ Write-Host 'SQL setup.exe not found - pass -SetupPath to your SQL media setup.exe.' -ForegroundColor Red; exit 1 }
Write-Host ("Edition-upgrading SQL instance "+$InstanceName+" via "+$setup+" ...") -ForegroundColor Cyan
& $setup /q /ACTION=editionupgrade /INSTANCENAME=$InstanceName /PID=$ProductKey /IACCEPTSQLSERVERLICENSETERMS
Write-Host ("SQL edition upgrade exit: "+$LASTEXITCODE) -ForegroundColor Green
foreach($root in 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server'){
  $inst=Get-ItemProperty "$root\Instance Names\SQL" -EA SilentlyContinue
  if($inst){ foreach($p in ($inst.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })){ $s=Get-ItemProperty "$root\$($p.Value)\Setup" -EA SilentlyContinue; if($s){ Write-Host ("  now: "+$p.Name+" -> "+$s.Edition) } } }
}
exit $LASTEXITCODE
'@ | Set-Content (Join-Path $Scripts 'Activate-Sql.ps1') -Encoding ascii
@'
@echo off
rem activate-sql -ProductKey <k> [-InstanceName MSSQLSERVER] [-SetupPath <setup.exe>] [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Activate-Sql.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'activate-sql.cmd') -Encoding ascii
  Log '  activate-windows + activate-sql staged (eval stays eval; convert to VL per-deploy via cloud-init)'
}
Step '44 SNMP-Helpers' {
@'
param([string]$Community='public',[string[]]$Managers,[string]$Trap,[string]$TrapCommunity,[string]$Location,[string]$Contact,[switch]$Help)
$ErrorActionPreference='Continue'
if($Help){
@"
snmp-register  -  enable + configure the built-in Windows SNMP Service (v1/v2c) for monitoring (run at DEPLOY, Admin).
USAGE:
  snmp-register -Community <read-community> [-Managers <ip,ip>] [-Trap <ip> -TrapCommunity <c>] [-Location <l>] [-Contact <c>]
  snmp-register -Help
DOES: installs the SNMP-Service feature (or capability on 2022/2025), sets a READ-ONLY community, permitted managers
      (blank = accept from any host), optional trap destination, sysLocation/sysContact, opens UDP 161 (+162 traps)
      and starts the service. Windows SNMP is v1/v2c; for SNMPv3 install Net-SNMP (snmpd) - not bundled here.
"@ | Write-Host -ForegroundColor Cyan; exit 0
}
if(-not (Get-Service SNMP -EA SilentlyContinue)){
  Import-Module ServerManager -EA SilentlyContinue
  try{ Install-WindowsFeature SNMP-Service -IncludeManagementTools -EA Stop | Out-Null }catch{
    Get-WindowsCapability -Online -Name 'SNMP.Client*' -EA SilentlyContinue | ForEach-Object { Add-WindowsCapability -Online -Name $_.Name -EA SilentlyContinue | Out-Null }
    dism /online /enable-feature /featurename:SNMP /all /quiet /norestart 2>$null | Out-Null
  }
}
$P='HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters'
New-Item "$P\ValidCommunities" -Force -EA SilentlyContinue | Out-Null
Set-ItemProperty "$P\ValidCommunities" $Community 4 -Type DWord -Force -EA SilentlyContinue
New-Item "$P\PermittedManagers" -Force -EA SilentlyContinue | Out-Null
if($Managers){ $i=1; foreach($m in $Managers){ Set-ItemProperty "$P\PermittedManagers" "$i" $m -Type String -Force -EA SilentlyContinue; $i++ } }
New-Item "$P\RFC1156Agent" -Force -EA SilentlyContinue | Out-Null
if($Location){ Set-ItemProperty "$P\RFC1156Agent" 'sysLocation' $Location -Force -EA SilentlyContinue }
if($Contact){ Set-ItemProperty "$P\RFC1156Agent" 'sysContact' $Contact -Force -EA SilentlyContinue }
if($Trap){ $tc=$(if($TrapCommunity){$TrapCommunity}else{$Community}); New-Item "$P\TrapConfiguration\$tc" -Force -EA SilentlyContinue | Out-Null; Set-ItemProperty "$P\TrapConfiguration\$tc" '1' $Trap -Type String -Force -EA SilentlyContinue }
New-NetFirewallRule -DisplayName 'SNMP 161 UDP' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 161 -Profile Any -EA SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName 'SNMP Trap 162 UDP' -Direction Outbound -Action Allow -Protocol UDP -RemotePort 162 -Profile Any -EA SilentlyContinue | Out-Null
Set-Service SNMP -StartupType Automatic -EA SilentlyContinue; Restart-Service SNMP -EA SilentlyContinue
Write-Host ("SNMP enabled: community '"+$Community+"' (read-only), managers="+$(if($Managers){$Managers -join ','}else{'any'})+$(if($Trap){", trap->"+$Trap}else{''})) -ForegroundColor Green
exit 0
'@ | Set-Content (Join-Path $Scripts 'Snmp-Register.ps1') -Encoding ascii
@'
@echo off
rem snmp-register -Community <c> [-Managers <ip,ip>] [-Trap <ip> -TrapCommunity <c>] [-Location <l>] [-Contact <c>] [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Snmp-Register.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'snmp-register.cmd') -Encoding ascii
  $cc=(Get-Command choco -EA SilentlyContinue).Source; if($cc){ & $cc install snmpb -y --no-progress 2>$null | Out-Null }
  Log '  snmp-register (Windows SNMP v1/v2c enable+configure) + snmpb browser'
}
Step '45 WindowsUpdate-CLI' {
  # 'winupdate' command: install/download Windows Updates from CLI, auto-fix WU issues, retry until complete (2016-2025)
@'
param([switch]$Download,[switch]$Install,[switch]$Reset,[switch]$Reboot,[int]$MaxRetries=5,[switch]$Help)
$ErrorActionPreference='Continue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($Help){
@"
winupdate  -  Windows Update from the command line, auto-diagnose + auto-fix, retry until done (2016-2025).
USAGE:
  winupdate               download + install all updates, retry until clean (default)
  winupdate -Download     download only
  winupdate -Install      download + install (default)
  winupdate -Reset        reset WU components first (SoftwareDistribution/catroot2 + re-register DLLs)
  winupdate -Reboot       auto-reboot when required (re-run after login to continue)
  winupdate -MaxRetries N retries per pass (default 5)
NOTES: uses the free PSWindowsUpdate module. On repeated failure it AUTO-runs a WU reset + SFC/DISM repair, then
       retries - autonomous. Log: C:\Scripts\winupdate.log.
"@ | Write-Host -ForegroundColor Cyan; exit 0
}
$log='C:\Scripts\winupdate.log'; function L($m){ $s="$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $m"; Write-Host $s; $s | Out-File -Append $log -Encoding ascii }
function Reset-WU {
  L 'auto-fix: resetting Windows Update components...'
  Stop-Service wuauserv,bits,cryptsvc -Force -EA SilentlyContinue
  Rename-Item 'C:\Windows\SoftwareDistribution' ("SoftwareDistribution.old-"+(Get-Date -f yyyyMMddHHmmss)) -EA SilentlyContinue
  Rename-Item 'C:\Windows\System32\catroot2' ("catroot2.old-"+(Get-Date -f yyyyMMddHHmmss)) -EA SilentlyContinue
  foreach($d in 'wuaueng.dll','wups.dll','wups2.dll','wuwebv.dll','wucltux.dll','atl.dll'){ regsvr32.exe /s $d 2>$null }
  Start-Service cryptsvc,bits,wuauserv -EA SilentlyContinue
}
function Repair-OS { L 'auto-fix: SFC + DISM /RestoreHealth...'; cmd /c "sfc /scannow" 2>&1 | Out-Null; DISM /online /Cleanup-Image /RestoreHealth 2>&1 | Out-Null }
if($Reset){ Reset-WU }
try{ Import-Module PSWindowsUpdate -EA Stop }catch{ Install-PackageProvider NuGet -Force -EA SilentlyContinue|Out-Null; Set-PSRepository PSGallery -InstallationPolicy Trusted -EA SilentlyContinue; Install-Module PSWindowsUpdate -Force -Scope AllUsers -EA SilentlyContinue; Import-Module PSWindowsUpdate -EA SilentlyContinue }
$dl = ($Download -and -not $Install); $pass=0
while($true){
  $pass++; if($pass -gt 20){ L 'max passes reached; stopping'; break }
  L ("pass $pass : scanning...")
  $list=@(Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -EA SilentlyContinue)
  L ("found "+$list.Count+" update(s)")
  if($list.Count -eq 0){ L 'no more updates -> COMPLETE'; break }
  $ok=$false
  for($try=1; $try -le $MaxRetries; $try++){
    try{
      if($dl){ Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Download -IgnoreReboot -EA Stop | ForEach-Object { L ("  downloaded: "+$_.Title) } }
      else   { Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install  -IgnoreReboot -EA Stop | ForEach-Object { L ("  installed: "+$_.Title+" ["+$_.Result+"]") } }
      $ok=$true; break
    }catch{ L ("  attempt $try failed: "+$_.Exception.Message); if($try -eq 2){ Reset-WU }; if($try -eq 3){ Repair-OS }; Start-Sleep 20 }
  }
  if(-not $ok){ L 'still failing after retries + auto-fix; stopping this run'; break }
  if($dl){ break }
  if(Get-WURebootStatus -Silent -EA SilentlyContinue){
    if($Reboot){ L 'reboot required -> restarting (re-run winupdate after login to continue)'; Restart-Computer -Force; break }
    else { L 'reboot required - run winupdate again after rebooting to continue'; break }
  }
}
exit 0
'@ | Set-Content (Join-Path $Scripts 'Win-Update.ps1') -Encoding ascii
@'
@echo off
rem winupdate [-Download] [-Install] [-Reset] [-Reboot] [-MaxRetries N] [-Help]
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Win-Update.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'winupdate.cmd') -Encoding ascii
  Log '  winupdate command (CLI Windows Update + auto WU reset/SFC/DISM + retry, 2016-2025)'
}
Step '46 Security-Exclusions' {
  # add C:\Scripts (recursive) to Microsoft Defender exclusions so staged tools are not quarantined (Defender kept ON).
  if(Get-Command Add-MpPreference -EA SilentlyContinue){ try{ Add-MpPreference -ExclusionPath 'C:\Scripts' -EA SilentlyContinue; Log '  Defender exclusion added: C:\Scripts' }catch{} } else { Log '  Defender cmdlets not present (skipped)' }
  # day-2 command: defender-exclude <path...>  (default C:\Scripts)
@'
param([string[]]$Path,[switch]$Help)
if($Help){ Write-Host "defender-exclude <path> [<path>...]   add folders/files to Microsoft Defender exclusions (default C:\Scripts)"; exit 0 }
if(-not $Path){ $Path=@('C:\Scripts') }
if(-not (Get-Command Add-MpPreference -EA SilentlyContinue)){ Write-Host 'Defender cmdlets not available on this host.' -ForegroundColor Red; exit 1 }
foreach($p in $Path){ Add-MpPreference -ExclusionPath $p -EA SilentlyContinue; Write-Host ("Defender exclusion added: "+$p) -ForegroundColor Green }
Write-Host 'Current Defender path exclusions:' -ForegroundColor Cyan
(Get-MpPreference).ExclusionPath | ForEach-Object { Write-Host ("  "+$_) }
exit 0
'@ | Set-Content (Join-Path $Scripts 'Defender-Exclude.ps1') -Encoding ascii
@'
@echo off
rem defender-exclude <path> [<path>...]   (default C:\Scripts)
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Defender-Exclude.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'defender-exclude.cmd') -Encoding ascii
  # day-2 command: bitdefender-exclude  (GravityZone cloud is policy-managed; writes the exclusion list + steps)
@'
param([string[]]$Path,[switch]$Help)
if($Help){
@"
bitdefender-exclude  -  prepare Bitdefender GravityZone folder exclusions (cloud policy managed).
Endpoint exclusions for GravityZone are set in the CONSOLE policy, not locally. This writes the folder list to
C:\Scripts\bitdefender-exclusions.txt and prints the exact steps to add them.
USAGE: bitdefender-exclude [<path> ...]     (default: C:\Scripts and C:\Scripts\*)
"@ | Write-Host -ForegroundColor Cyan; exit 0
}
if(-not $Path){ $Path=@('C:\Scripts','C:\Scripts\*') }
$out='C:\Scripts\bitdefender-exclusions.txt'
$Path | Set-Content $out -Encoding ascii
Write-Host 'Add these as FOLDER exclusions in GravityZone:' -ForegroundColor Cyan
Write-Host '  Policies > <your policy> > Antimalware > Settings > Exclusions > Custom > Add > Type=Folder' -ForegroundColor Cyan
$Path | ForEach-Object { Write-Host ("  "+$_) -ForegroundColor Green }
Write-Host ("(list also written to "+$out+")") -ForegroundColor DarkGray
exit 0
'@ | Set-Content (Join-Path $Scripts 'Bitdefender-Exclude.ps1') -Encoding ascii
@'
@echo off
rem bitdefender-exclude [<path> ...]   prepare GravityZone folder exclusions (default C:\Scripts)
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Bitdefender-Exclude.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'bitdefender-exclude.cmd') -Encoding ascii
  Log '  C:\Scripts added to Defender exclusions + defender-exclude / bitdefender-exclude day-2 commands'
}
Step '47 Yallacloud-Catalog' {
  # observability-register: wrapper for the staged Setup-Observability.ps1 (Grafana Alloy / OTel / Prometheus + SQL
  # maintenance -> OpenObserve). Only created if the script was staged into C:\Scripts (dropped beside GoldenImage.ps1).
  if(Test-Path (Join-Path $Scripts 'Setup-Observability.ps1')){
@'
@echo off
rem observability-register  ->  install Grafana Alloy / OpenTelemetry / Prometheus exporters + SQL maintenance (OpenObserve)
rem   example: observability-register -OOEndpoint https://oo.example.com -OOOrg default -OOUser you@x.com -OOPass *** -OOAuth "Basic BASE64"
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Setup-Observability.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'observability-register.cmd') -Encoding ascii
    Log '  observability-register created (wraps Setup-Observability.ps1: Alloy/OTel/Prometheus + SQL maintenance)'
  } else { Log '  Setup-Observability.ps1 not staged (drop it beside GoldenImage.ps1 to bake observability-register into the template)' }
  # rotate-password: rotate chadmin/additionaladmin OR reset the built-in Administrator. Automation-friendly - it
  # prints "NEWPASSWORD=<pw>" so any tool (cloud-init, Ansible, a cron/API job) can capture the new password. On PATH.
@'
param([string]$User,[string]$Password,[switch]$Administrator,[switch]$Random,[int]$Length=20,[switch]$Help)
$ErrorActionPreference='Stop'
if($Help -or (-not $User -and -not $Administrator)){
@"
rotate-password  -  set a local admin password YOU choose (automation-friendly; prints NEWPASSWORD=<pw>).
  You supply the password. Put it in DOUBLE QUOTES - special chars @ # ! $ are passed LITERALLY (the wrapper uses
  powershell -File, which does NOT expand `$`), so "P@ss#word!1$x" works as-is. Only avoid a literal % (cmd meta;
  write %% if you must). -Random is optional (mainly for a throwaway Administrator reset), not required.
USAGE:
  rotate-password -User chadmin -Password "P@ss#word!1$x"
  rotate-password -Administrator -Password "P@ss#word!1$x"   reset + enable the built-in Administrator
  rotate-password -Administrator -Random [-Length 24]        generate a random one (Administrator only)
"@ | Write-Host -ForegroundColor Cyan
  if($Help){ exit 0 } else { exit 1 } }
function New-StrongPw([int]$n){ $s="ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#%^*-_=+".ToCharArray(); -join (1..$n | ForEach-Object { $s[(Get-Random -Maximum $s.Length)] }) }
$target = if($Administrator){"Administrator"} else {$User}
if($Random){ $Password=New-StrongPw $Length }
if(-not $Password){ Write-Host 'Provide -Password "yourP@ss#1" (double-quoted), or -Random for Administrator.' -ForegroundColor Red; exit 1 }
if(-not (Get-LocalUser $target -EA SilentlyContinue)){ Write-Host "user not found: $target" -ForegroundColor Red; exit 2 }
Set-LocalUser -Name $target -Password (ConvertTo-SecureString $Password -AsPlainText -Force)
Set-LocalUser -Name $target -PasswordNeverExpires $true -EA SilentlyContinue
if($Administrator){ net user Administrator /active:yes | Out-Null; net user Administrator /logonpasswordchg:no | Out-Null }
Write-Host "OK: password rotated for $target" -ForegroundColor Green
Write-Host ("NEWPASSWORD=" + $Password)
'@ | Set-Content (Join-Path $Scripts 'Rotate-Password.ps1') -Encoding ascii
@'
@echo off
rem rotate-password  ->  rotate chadmin/additionaladmin or reset Administrator (prints NEWPASSWORD=)
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Rotate-Password.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'rotate-password.cmd') -Encoding ascii
  Log '  rotate-password command created (rotate chadmin / reset Administrator; automation-friendly)'
  # vmware-tools : install FULL VMware Tools (guest service + PVSCSI/VMXNET3/SVGA) unattended on a VMware clone.
  # The drivers-only set is already baked so the image boots on ESXi; this adds the full guest agent when wanted.
  # On PATH; safe from cloud-init / any automation tool. Prints nothing interactive.
@'
param([switch]$Drivers,[switch]$Help)
$ErrorActionPreference='Stop'
if($Help){ @"
vmware-tools  -  install VMware Tools unattended (silent, reboot suppressed). Run on a VMware/vCenter deployment.
  vmware-tools            full VMware Tools (guest service + PVSCSI + VMXNET3 + SVGA)
  vmware-tools -Drivers   drivers-only (PVSCSI + VMXNET3 + SVGA; no guest service) - already baked, use to repair
Idempotent-ish: skips if VMware Tools service is already installed (unless -Drivers).
"@ | Write-Host -ForegroundColor Cyan; exit 0 }
$e='C:\Scripts\VMware-Tools-x64.exe'
$url='https://packages-prod.broadcom.com/tools/releases/12.5.4/x64/VMware-tools-12.5.4-24964629-x64.exe'
if((-not $Drivers) -and (Get-Service VMTools -EA SilentlyContinue)){ Write-Host 'VMware Tools already installed (VMTools service present).' -ForegroundColor Green; exit 0 }
for($t=1; ((-not (Test-Path $e)) -or ((Get-Item $e).Length -lt 50MB)) -and $t -le 4; $t++){
  if(Test-Path $e){ Remove-Item $e -Force -EA SilentlyContinue }
  try{ [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    if(Get-Command Start-BitsTransfer -EA SilentlyContinue){ Start-BitsTransfer -Source $url -Destination $e -EA Stop } else { Invoke-WebRequest $url -OutFile $e -UseBasicParsing -TimeoutSec 1800 } }
  catch{ Start-Sleep 10 } }
if((-not (Test-Path $e)) -or ((Get-Item $e).Length -lt 50MB)){ Write-Host 'download failed (installer <50MB after 4 tries)' -ForegroundColor Red; exit 2 }
foreach($vc in 'x64','x86'){ $vp="C:\Scripts\vc_redist.$vc.exe"; if((-not (Test-Path $vp)) -or ((Get-Item $vp).Length -lt 1MB)){ try{ Invoke-WebRequest "https://aka.ms/vs/17/release/vc_redist.$vc.exe" -OutFile $vp -UseBasicParsing -TimeoutSec 300 }catch{} }; if(Test-Path $vp){ try{ Start-Process $vp -ArgumentList '/install /quiet /norestart' -Wait }catch{} } }
$al = if($Drivers){'/S /v "/qn ADDLOCAL=Drivers REBOOT=R"'} else {'/S /v "/qn REBOOT=R"'}
$p=Start-Process $e -ArgumentList $al -Wait -PassThru
Write-Host ("VMware Tools install exit=" + $p.ExitCode + $(if($Drivers){' (drivers-only)'}else{' (full)'})) -ForegroundColor Green
exit $p.ExitCode
'@ | Set-Content (Join-Path $Scripts 'Install-VMwareTools.ps1') -Encoding ascii
  ("@echo off`r`nrem vmware-tools [-Drivers]  ->  install VMware Tools unattended (full by default). Safe from cloud-init.`r`npowershell -NoProfile -ExecutionPolicy Bypass -File ""C:\Scripts\Install-VMwareTools.ps1"" %*") | Set-Content (Join-Path $Scripts 'vmware-tools.cmd') -Encoding ascii
  Log '  vmware-tools command created (full VMware Tools unattended; drivers already baked; on PATH for cloud-init)'
  # bake the daily health monitors (chkdsk / logon-logoff-shutdown / SQL-corruption) if the script is staged
  if(Test-Path (Join-Path $Scripts 'Setup-HealthMonitors.ps1')){ try{ powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Scripts 'Setup-HealthMonitors.ps1') -Install | Out-Null; Log '  health monitors installed (daily chkdsk/session-power/SQL-corruption -> C:\Scripts\Health + Application event log)' }catch{ Log "  health monitors error: $($_.Exception.Message)" } }
  # 'yallacloud' lists every command so the tech team does not have to navigate the folder
@'
Write-Host ''
Write-Host '  YALLACLOUD  -  command catalog (C:\Scripts is on PATH). Add -Help to any command.' -ForegroundColor White
Write-Host ''
Write-Host '  AGENTS (register per deployment):' -ForegroundColor Yellow
Write-Host '    acronis-register  bitdefender-register  wazuh-register  glpi-register  osquery-register'
Write-Host '    site24x7-register  zabbix-register  snmp-register  report-inventory'
Write-Host '  MONITORING (Grafana Alloy / OTel / Prometheus + SQL maintenance -> OpenObserve):' -ForegroundColor Yellow
Write-Host '    observability-register -OOEndpoint <url> -OOOrg <org> -OOUser <u> -OOPass <p>  [-Collector alloy|otel|prometheus|all]'
Write-Host '  HEALTH (daily SYSTEM tasks; logs in C:\Scripts\Health + Application event log source YallaCloudHealth):' -ForegroundColor Yellow
Write-Host '    YC-Health-Chkdsk (03:30)   YC-Health-Session (23:55)   YC-Health-SQL (04:00)   run now: Setup-HealthMonitors.ps1 -RunChkdsk'
Write-Host '  PASSWORD:' -ForegroundColor Yellow
Write-Host '    rotate-password -User chadmin -Password "P@ss#1$x"    (or -Administrator -Password ...)  quote it; @ # ! $ are literal'
Write-Host '  VMWARE (drivers PVSCSI/VMXNET3/SVGA already baked; run on a VMware/vCenter deploy for the full guest agent):' -ForegroundColor Yellow
Write-Host '    vmware-tools            (full VMware Tools, unattended - cloud-init safe)      vmware-tools -Drivers (drivers-only)'
Write-Host '  LICENSING:' -ForegroundColor Yellow
Write-Host '    activate-windows  (2012R2-2025)      activate-sql  (2012-2026)'
Write-Host '  DIAGNOSTICS / REPAIR:' -ForegroundColor Yellow
Write-Host '    diag    rootcause    perflog [sec]    winupdate    diagtools-install (installs staged smartmontools/logparser)'
Write-Host '  SYSTEM / DAY-2:' -ForegroundColor Yellow
Write-Host '    grow-disk    set-nic    defender-exclude    bitdefender-exclude    notify "<msg>"'
Write-Host '  TOOLS on PATH: IISCrypto(Cli) testdisk photorec iperf3 snmpb Sysinternals\* choco scoop ntfy   (smartctl/logparser STAGED -> diagtools-install; NO nmap)' -ForegroundColor DarkGray
Write-Host '  Files/logs in C:\Scripts (hidden): golden-image-build.log, winupdate.log, disk-guard.log, rootcause-latest.txt' -ForegroundColor DarkGray
Write-Host ''
'@ | Set-Content (Join-Path $Scripts 'Yallacloud.ps1') -Encoding ascii
@'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Yallacloud.ps1" %*
'@ | Set-Content (Join-Path $Scripts 'yallacloud.cmd') -Encoding ascii
  Log '  yallacloud command catalog created (run: yallacloud)'
}

  if($script:RebootNeeded){ New-Item $Lock -Force|Out-Null }
  Log '===== configuration steps complete ====='
  if(Test-Path $Lock){ OL 'CONFIG: reboot requested -> restarting (auto-resume)'; Invoke-Power restart; exit }
  Set-Content $ph 'sealcheck'; $phase='sealcheck'
}


# =============================================================================
#  STEPS 48-52  -  fixes proven on the v256/v257 rebuild (ERRORS 41-75).
#  Everything here is Windows PowerShell 5.1, ASCII only, no ternaries.
# =============================================================================

Step '48 FirstBoot-Engine-180Day' {
  # ---- ERROR 41: the 180-day evaluation ----------------------------------
  # Unattend keeps SkipRearm=1 so sysprep does NOT burn a rearm at seal time.
  # The consequence is that every clone INHERITS the golden's evaluation clock
  # (that is the 166-days-remaining report). The fix is to rearm on the CLONE,
  # exactly once, on its first boot, then reboot, then /ato until the licence
  # service actually reports "Licensed" - because immediately after a rearm the
  # state is "Initial grace period" (~9 days), NOT 180. Firing /ato once and
  # walking away is what shipped 166 days. It must RETRY until verified.
  #
  # ---- ERROR 72: this must NOT live in SetupComplete.cmd -----------------
  # SetupComplete runs while OOBE is still cycling; every CIM call dies with
  # "A system shutdown is in progress". So SetupComplete.cmd is ONE LINE that
  # registers a startup task, and all real work happens from that task.
  # ---- ERROR 71: never enumerate/delete drivers in there - it HANGS. -----

  $fb = Join-Path $Scripts 'yc-firstboot.ps1'
  $fbBody = @'
$ErrorActionPreference='Continue'
$log='C:\Scripts\yc-firstboot.log'
function Log($m){ $t=Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; Add-Content -Path $log -Value ("[$t] "+$m) -Encoding ascii }
Log '=== yc-firstboot start ==='
try { $null=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
catch { Log 'shutdown in progress - deferring to next boot'; exit 0 }

# 1. network profile Private (retry: the NIC is unclassified this early)
try {
  for($i=0;$i -lt 12;$i++){
    $p=Get-NetConnectionProfile -ErrorAction SilentlyContinue
    if($p -and ($p | Where-Object { $_.NetworkCategory -ne 'Private' })){
      $p | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue; Start-Sleep -Seconds 5
    } elseif($p){ break } else { Start-Sleep -Seconds 5 }
  }
  Log ('network profile = '+((Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1).NetworkCategory))
  & netsh advfirewall firewall add rule name="YC-SSH-3222" dir=in action=allow protocol=TCP localport=3222 2>&1 | Out-Null
} catch { Log ('firewall step error: '+$_.Exception.Message) }

# 2. sshd: service + key ACL (ERROR 57 - wrong ACL makes sshd ignore the keys)
try {
  $bin='C:\Program Files\OpenSSH\OpenSSH-Win64'
  if(-not (Get-Service sshd -ErrorAction SilentlyContinue) -and (Test-Path "$bin\install-sshd.ps1")){
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$bin\install-sshd.ps1" 2>&1 | Out-Null
  }
  if(-not (Test-Path 'C:\ProgramData\ssh\ssh_host_ed25519_key')){ & "$bin\ssh-keygen.exe" -A 2>&1 | Out-Null }
  foreach($hk in (Get-ChildItem 'C:\ProgramData\ssh\ssh_host_*_key' -ErrorAction SilentlyContinue)){
    & icacls $hk.FullName /inheritance:r /grant '"NT AUTHORITY\SYSTEM:(F)"' /grant '"BUILTIN\Administrators:(F)"' 2>&1 | Out-Null
  }
  $ak='C:\ProgramData\ssh\administrators_authorized_keys'
  if(Test-Path $ak){
    & icacls $ak /inheritance:r 2>&1 | Out-Null
    & icacls $ak /grant '"NT AUTHORITY\SYSTEM:(F)"' 2>&1 | Out-Null
    & icacls $ak /grant '"BUILTIN\Administrators:(F)"' 2>&1 | Out-Null
    & icacls $ak /remove '"BUILTIN\Users"' '"NT AUTHORITY\Authenticated Users"' '"Everyone"' 2>&1 | Out-Null
  }
  Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service sshd -ErrorAction SilentlyContinue
  Log ('sshd = '+(Get-Service sshd -ErrorAction SilentlyContinue).Status)
} catch { Log ('sshd step error: '+$_.Exception.Message) }

# 3. QEMU guest agent (KVM). Harmless no-op on ESXi - the msi is simply absent.
try {
  $qga=Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
  if(-not $qga -and (Test-Path 'C:\Scripts\qemu-ga.msi')){
    Start-Process msiexec.exe -ArgumentList '/i','C:\Scripts\qemu-ga.msi','/qn','/norestart' -Wait
    Log 'qemu-ga installed'
  }
  $qga=Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
  if($qga){ Set-Service -Name $qga.Name -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service $qga.Name -ErrorAction SilentlyContinue }
} catch { Log ('qga step error: '+$_.Exception.Message) }

# 4. Shutdown Event Tracker OFF - re-assert (customer-facing dialog)
try {
  $rk='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability'
  if(-not (Test-Path $rk)){ New-Item -Path $rk -Force | Out-Null }
  New-ItemProperty -Path $rk -Name 'ShutdownReasonOn' -PropertyType DWord -Value 0 -Force | Out-Null
  New-ItemProperty -Path $rk -Name 'ShutdownReasonUI' -PropertyType DWord -Value 0 -Force | Out-Null
  Log 'shutdown event tracker disabled'
} catch { Log ('tracker step error: '+$_.Exception.Message) }

# 5. hide CloudinitAdmin from the logon screen, focus Administrator (ERROR 48)
#    NEVER touch chadmin - it is the fallback account and must stay visible.
try {
  $ul='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
  if(-not (Test-Path $ul)){ New-Item -Path $ul -Force | Out-Null }
  New-ItemProperty -Path $ul -Name 'CloudinitAdmin' -PropertyType DWord -Value 0 -Force | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' -Name 'LastLoggedOnUser'        -Value '.\Administrator' -ErrorAction SilentlyContinue
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' -Name 'LastLoggedOnSAMUser'     -Value '.\Administrator' -ErrorAction SilentlyContinue
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' -Name 'LastLoggedOnDisplayName' -Value 'Administrator'   -ErrorAction SilentlyContinue
  Log 'CloudinitAdmin hidden, console focus = Administrator'
} catch { Log ('logonui step error: '+$_.Exception.Message) }

# 6. (retired) YCNET/YCNET5/YCDEPLOY first-boot task registration - superseded
#    by the build-time YC-Boot task (AtStartup), which already covers
#    grow-disk/set-nic/deploy-audit on every boot without a schtasks call here.

# 7. THE 180-DAY FIX. rearm once (guard file), reboot, then /ato until Licensed.
try {
  $slmgr='C:\Windows\System32\slmgr.vbs'
  $dlv=(& cscript //nologo $slmgr /dlv 2>&1) -join "`n"
  $licensed = $dlv -match 'License Status:\s*Licensed'
  if(-not (Test-Path 'C:\Scripts\.rearm-done')){
    $r=(& cscript //nologo $slmgr /rearm 2>&1) -join ' '
    Log ('rearm output: '+$r)
    Set-Content -Path 'C:\Scripts\.rearm-done' -Value 'done' -Encoding ascii
    & schtasks /create /tn YCActivate /tr 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\yc-activate.ps1' /sc onstart /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Null
    Log 'rearm applied - rebooting to arm the new 180-day period'
    & shutdown /r /t 30 /c 'YC: applying 180-day evaluation reset'
  } elseif(-not $licensed){
    Log 'rearm done but not Licensed yet - running activate now'
    & powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\Scripts\yc-activate.ps1'
  } else {
    $xpr=(& cscript //nologo $slmgr /xpr 2>&1) -join ' '
    Log ('already Licensed - '+$xpr)
  }
} catch { Log ('rearm step error: '+$_.Exception.Message) }

# 8. retire this task ONLY once licence + tasks + firewall are all green
try {
  $dlv2=(& cscript //nologo 'C:\Windows\System32\slmgr.vbs' /dlv 2>&1) -join "`n"
  $okLic  = $dlv2 -match 'License Status:\s*Licensed'
  $okTask = (Get-ScheduledTask -TaskName 'YC-Boot' -ErrorAction SilentlyContinue) -ne $null
  $okFw   = ((Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1).NetworkCategory) -eq 'Private'
  if($okLic -and $okTask -and $okFw){ & schtasks /delete /tn YCFIRSTBOOT /f 2>&1 | Out-Null; Log 'all green - YCFIRSTBOOT retired' }
  else { Log ("not green yet (lic=$okLic tasks=$okTask fw=$okFw) - will run again next boot") }
} catch { Log ('retire step error: '+$_.Exception.Message) }
Log '=== yc-firstboot end ==='
'@
  Set-Content $fb $fbBody -Encoding ascii
  Log '  yc-firstboot.ps1 written'

  # /ato retry loop - separate file so it can also be run by hand
  $act = @'
$log='C:\Scripts\yc-firstboot.log'
function Log($m){ Add-Content $log ("[activate] "+(Get-Date -Format 'HH:mm:ss')+" "+$m) -Encoding ascii }
$slmgr='C:\Windows\System32\slmgr.vbs'
for($i=1;$i -le 20;$i++){
  $dlv=(& cscript //nologo $slmgr /dlv 2>&1) -join "`n"
  if($dlv -match 'License Status:\s*Licensed'){
    Log ('Licensed after '+$i+' attempt(s) - '+(((& cscript //nologo $slmgr /xpr 2>&1) -join ' ')))
    & schtasks /delete /tn YCActivate /f 2>&1 | Out-Null
    break
  }
  & cscript //nologo $slmgr /ato 2>&1 | Out-Null
  Start-Sleep -Seconds 30
}
'@
  Set-Content (Join-Path $Scripts 'yc-activate.ps1') $act -Encoding ascii

  # yc-deploy.ps1 - deploy-audit script; its content is also inlined as step 5
  # of yc-boot.ps1, kept here as a standalone command. yc-net.ps1 is superseded
  # by yc-boot.ps1 and is no longer generated.
  $ycdep = @'
# yc-deploy.ps1 - runs once per boot; records what this clone actually is.
$ErrorActionPreference='SilentlyContinue'
$log='C:\Scripts\yc-deploy.log'
$os=(Get-CimInstance Win32_OperatingSystem).Caption
$ip=(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object -First 1).IPAddress
$xpr=(& cscript //nologo C:\Windows\System32\slmgr.vbs /xpr 2>&1) -join ' '
Add-Content $log ("[{0}] host={1} ip={2} os={3} lic={4}" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $ip, $os, $xpr) -Encoding ascii
'@
  Set-Content (Join-Path $Scripts 'yc-deploy.ps1') $ycdep -Encoding ascii
  Log '  yc-deploy.ps1 written'

  # SetupComplete.cmd: ONE LINE. It registers the task and gets out of the way.
  $sc = 'C:\Windows\Setup\Scripts'
  New-Item -ItemType Directory -Force $sc | Out-Null
  # /sc onstart alone fires on the NEXT boot, so on a fresh clone the firewall
  # stays Public and nothing self-heals until someone reboots it. Register the
  # task AND kick it off right away; the task itself is idempotent and retires
  # once everything is green.
  $l1 = 'schtasks /create /tn YCFIRSTBOOT /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\yc-firstboot.ps1" /sc onstart /ru SYSTEM /rl HIGHEST /f'
  $l2 = 'schtasks /run /tn YCFIRSTBOOT'
  Set-Content (Join-Path $sc 'SetupComplete.cmd') "@echo off`r`n$l1`r`n$l2`r`n" -Encoding ascii
  Log '  SetupComplete.cmd written (one-liner -> YCFIRSTBOOT task)'
}

Step '49 Shutdown-Event-Tracker-Off' {
  # Customer-facing: the "Why did the computer shut down unexpectedly?" dialog.
  # Set in the golden AND re-asserted at first boot (step 48/4) because some
  # 2022/2025 media reapply the default during OOBE.
  $rk='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability'
  New-Item -Path $rk -Force | Out-Null
  New-ItemProperty -Path $rk -Name 'ShutdownReasonOn' -PropertyType DWord -Value 0 -Force | Out-Null
  New-ItemProperty -Path $rk -Name 'ShutdownReasonUI' -PropertyType DWord -Value 0 -Force | Out-Null
  Log '  Shutdown Event Tracker disabled (ShutdownReasonOn/UI = 0)'
}

Step '50 Logon-Screen-Focus' {
  # ERROR 48: the account is called CloudinitAdmin. cloudbase-init legitimately
  # OWNS it, so it must be HIDDEN, not disabled. And chadmin must NEVER be
  # touched - it is the fallback account and has to stay enabled AND visible.
  $ul='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
  New-Item -Path $ul -Force | Out-Null
  New-ItemProperty -Path $ul -Name 'CloudinitAdmin' -PropertyType DWord -Value 0 -Force | Out-Null
  Remove-ItemProperty -Path $ul -Name 'chadmin' -EA SilentlyContinue      # undo any earlier mistake
  $lu='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
  Set-ItemProperty $lu -Name 'LastLoggedOnUser'        -Value '.\Administrator' -EA SilentlyContinue
  Set-ItemProperty $lu -Name 'LastLoggedOnSAMUser'     -Value '.\Administrator' -EA SilentlyContinue
  Set-ItemProperty $lu -Name 'LastLoggedOnDisplayName' -Value 'Administrator'   -EA SilentlyContinue
  Log '  CloudinitAdmin hidden; console focus = Administrator; chadmin untouched'
}

Step '51 VirtIO-Boot-Critical' {
  # Only meaningful on KVM. Makes viostor/vioscsi boot-start so a clone can be
  # switched from IDE/SATA to virtio without a 0x7B. Add-only: NEVER
  # pnputil /delete-driver here (ERROR 69 - no-op on in-use packages, and
  # ERROR 71 - the enum loop hangs the first-boot script).
  $vdir=Join-Path $Scripts "virtio\$Tag"
  if(-not (Test-Path $vdir)){ $vdir=Join-Path $Scripts 'virtio' }
  if(-not (Test-Path $vdir)){ Log '  virtio payload absent (step 21/22 did not run) - skipped'; return }
  foreach($sv in 'viostor','vioscsi'){
    $k="HKLM:\SYSTEM\CurrentControlSet\Services\$sv"
    if(Test-Path $k){ Set-ItemProperty $k -Name Start -Value 0 -Type DWord -EA SilentlyContinue }
  }
  # CriticalDeviceDatabase so the storage controller is bound before the disk is read
  $cdd='HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase'
  $map=@{ 'pci#ven_1af4&dev_1001'='viostor'; 'pci#ven_1af4&dev_1042'='viostor'
          'pci#ven_1af4&dev_1004'='vioscsi'; 'pci#ven_1af4&dev_1048'='vioscsi' }
  foreach($k in $map.Keys){
    $p="$cdd\$k"; New-Item -Path $p -Force | Out-Null
    New-ItemProperty -Path $p -Name 'Service'   -Value $map[$k]          -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $p -Name 'ClassGUID' -Value '{4D36E97B-E325-11CE-BFC1-08002BE10318}' -PropertyType String -Force | Out-Null
  }
  foreach($sv in 'viostor','vioscsi'){
    $p="C:\Windows\System32\drivers\$sv.sys"
    if(Test-Path $p){ Log ("  $sv.sys = "+(Get-Item $p).VersionInfo.FileVersion) } else { Log "  $sv.sys not bound yet (normal on ESXi)" }
  }
}

Step '52 Write-Manual-Seal-Scripts' {
  # The build script does NOT seal. Sealing is manual, in two separate scripts,
  # with a real shutdown in between so you can snapshot. See the banner at the
  # end of this run.
  #
  # INJECTED COPIES WIN. The versions written below are the ones baked into this
  # build script and they drift from the kit: on 2026-08-11 the inline Fix-PreSeal
  # went looking for Install-YcTasks.ps1, which the build never writes, and logged
  # "Install-YcTasks.ps1 MISSING - tasks NOT consolidated". If a newer copy was
  # injected into C:\Scripts (runbook 1.2) it must NOT be clobbered by the inline
  # one. Skip any file that is already there.
  $sealFiles = 'AppX-Strip.ps1','Seal-Manual.ps1','Fix-PreSeal.ps1','Install-YcTasks.ps1','Clean-Scripts.ps1'
  $present = @($sealFiles | Where-Object { Test-Path (Join-Path $Scripts $_) })
  if($present.Count){
    Log ("  injected seal tooling found, NOT overwriting: " + ($present -join ', '))
  }
  $skipInline = ($present -contains 'AppX-Strip.ps1') -and ($present -contains 'Seal-Manual.ps1')
  if($skipInline){
    Log '  both AppX-Strip.ps1 and Seal-Manual.ps1 already present - inline versions skipped'
    foreach($f in 'Fix-PreSeal.ps1','Install-YcTasks.ps1','Clean-Scripts.ps1'){
      if($present -notcontains $f){ Log "  NOTE: $f was NOT injected - push it from the kit before sealing" }
    }
    return
  }
  $appx = @'
# AppX-Strip.ps1  -  RUN THIS TWICE. Second pass must report Remaining: 0.
# Windows PowerShell 5.1 ONLY. Under pwsh 7 the Appx cmdlets proxy through a
# WinPSCompat session and Get-AppxPackage -AllUsers UNDER-REPORTS, so a pass can
# look clean while sysprep still dies 0x8007001f.
if($PSVersionTable.PSEdition -eq 'Core'){
  & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
  exit $LASTEXITCODE
}
# AppX is the #1 cause of sysprep 0x8007001f. Remove-AppxPackage throws
# TERMINATING errors that -ErrorAction does NOT suppress, so every single
# removal is wrapped in its own try/catch or one bad package kills the pass.
$ErrorActionPreference='Continue'
$log='C:\Scripts\appx-strip.log'
function L($m){ $s="[$(Get-Date -f 'HH:mm:ss')] $m"; Write-Host $s; Add-Content $log $s -Encoding ascii }
L '--- AppX strip pass start ---'
$prov=@(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
foreach($p in $prov){
  try{ Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null; L ("deprovisioned "+$p.DisplayName) }
  catch{ L ("skip prov "+$p.DisplayName+" : "+$_.Exception.Message) }
}
$pkgs=@(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { -not $_.NonRemovable })
foreach($p in $pkgs){
  try{ Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
  catch{ try{ Remove-AppxPackage -Package $p.PackageFullName -ErrorAction SilentlyContinue }catch{} }
}
# ZERO IS NOT REACHABLE and never was. Inbox packages (DesktopAppInstaller,
# SecHealthUI) refuse removal outright, and framework packages (VCLibs,
# .NET Native, UI.Xaml) report NonRemovable=false yet always come back.
# What actually breaks sysprep with 0x8007001f is narrower: a package
# INSTALLED FOR A USER but NOT PROVISIONED for all users. Test only that.
$prov  = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object PackageName)
$block = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
           Where-Object { -not $_.NonRemovable -and $prov -notcontains $_.PackageFullName })
$left  = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { -not $_.NonRemovable }).Count
L ("removable per-user: $left   provisioned: $($prov.Count)   NOT-provisioned (the ones that matter): $($block.Count)")
foreach($b in $block){
  $who = ($b.PackageUserInformation | ForEach-Object { "$($_.UserSecurityId.Username)=$($_.InstallState)" }) -join '; '
  L ("   blocker? " + $b.Name + "  [" + $who + "]")
}
if($block.Count -eq 0){ L 'CLEAN - safe to shut down and snapshot' }
else { L 'Review the list above. Only packages belonging to OTHER user profiles stop sysprep.' }
'@
  Set-Content (Join-Path $Scripts 'AppX-Strip.ps1') $appx -Encoding ascii

  $seal = @'
# Seal-Manual.ps1  -  preflight + AppX convergence + secret wipe + sysprep.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1
#
# FULLY UNATTENDED - no prompts, no typed confirmation. It runs preflight, and
# unless a hard precondition fails it strips AppX, cleans up and syspreps.
#
#   ... -WhatIf           run every check, change nothing, do not sysprep
#   ... -AppxPasses 6     max AppX passes per round (default 4)
#   ... -SkipAppx         preflight + sysprep only
#
# REQUIRED ORDER:
#   1. shutdown /s /t 0            (a real shutdown, not a reboot)
#   2. snapshot  PreSeal-<vm>-<version>
#   3. power on, run this
#
# This is the sequence that produced a clean 2025 seal, automated:
#   AppX strip x N  ->  build-artefact cleanup  ->  AppX strip x N again
#   ->  sysprep, fired even when setuperr.log has non-fatal noise.
# The second AppX round matters: the cleanup (event logs, task removal) can
# re-stage packages, and stripping only before it is what kept failing.
param([switch]$WhatIf,[int]$AppxPasses=4,[switch]$SkipAppx)

# Windows PowerShell 5.1 only. Under pwsh 7 the Appx cmdlets proxy through a
# WinPSCompat session and Get-AppxPackage -AllUsers UNDER-REPORTS, so a pass
# looks clean while sysprep still dies 0x8007001f.
if($PSVersionTable.PSEdition -eq 'Core'){
  $a = @(); if($WhatIf){ $a += '-WhatIf' }
  if($SkipAppx){ $a += '-SkipAppx' }; $a += @('-AppxPasses',$AppxPasses)
  & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @a
  exit $LASTEXITCODE
}

# Continue, NOT Stop. wevtutil and sysprep write to stderr on non-fatal
# conditions and under 'Stop' PowerShell turns that into a terminating
# NativeCommandError - which killed an earlier version at the event-log loop,
# before sysprep ever ran. Preconditions are checked explicitly instead.
$ErrorActionPreference = 'Continue'

$U   = 'C:\Scripts\Unattend-Seal.xml'
$Log = 'C:\Scripts\seal.log'
$fail = @()
function Say($m,$c='Gray'){ $s = "[{0}] {1}" -f (Get-Date -f 'HH:mm:ss'), $m
                            Write-Host $s -ForegroundColor $c
                            Add-Content $Log $s -Encoding ascii -EA SilentlyContinue }

# ---------------------------------------------------------------- AppX -------
# Zero removable packages is UNREACHABLE: inbox apps (DesktopAppInstaller,
# SecHealthUI) refuse removal outright and frameworks (VCLibs, .NET Native,
# UI.Xaml) always return. What breaks sysprep is a package installed for a user
# but NOT provisioned - and only when it belongs to a profile other than the one
# sealing. So: strip repeatedly until that number STOPS CHANGING, then move on.
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

function Invoke-AppxStrip {
  # EVERY removal in its own try/catch: Remove-Appx* throws TERMINATING errors
  # that -ErrorAction does not suppress, and one bad package would abort the
  # whole pass.
  foreach($p in @(Get-AppxProvisionedPackage -Online -EA SilentlyContinue)){
    try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -EA Stop | Out-Null } catch {}
  }
  foreach($p in @(Get-AppxPackage -AllUsers -EA SilentlyContinue | Where-Object { -not $_.NonRemovable })){
    try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -EA Stop }
    catch { try { Remove-AppxPackage -Package $p.PackageFullName -EA SilentlyContinue } catch {} }
  }
}

function Converge-Appx($label){
  # ALL passes run - no early exit. Four before the cleanup and four after is
  # the sequence that produced a clean 2025 seal. Packages that look gone after
  # pass 2 come back, and an "it settled" shortcut is exactly how the earlier
  # attempts got to sysprep with something still staged.
  Say "AppX round: $label  ($AppxPasses passes, all of them)" Cyan
  for($i=1; $i -le $AppxPasses; $i++){
    Invoke-AppxStrip
    $r = Get-AppxRisk
    Say ("  pass {0}/{1}: notProvisioned={2} otherProfile={3}" -f $i, $AppxPasses, $r.NotProvisioned, $r.OtherProfile.Count)
    foreach($o in $r.OtherProfile){ Say "     RISK $o" Yellow }
  }
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

# ---- 6. already generalized? sysprep is ONE-SHOT ---------------------------
$img = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -EA SilentlyContinue).ImageState
Say "imagestate   : $img"
if($img -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'){
  Say '               ALREADY GENERALIZED - do not run sysprep again.' Red
  Say '               Power off with: shutdown /s /t 0 /f    then capture.' Red
  exit 1
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

# ---- 10. first-boot self-heal scripts must be present ---------------------
$miss = @()
foreach($f in 'C:\Scripts\yc-firstboot.ps1','C:\Scripts\yc-activate.ps1','C:\Scripts\yc-deploy.ps1'){
  if(-not (Test-Path $f)){ $miss += (Split-Path $f -Leaf) }
}
if($miss.Count){ Say ('firstboot set: MISSING ' + ($miss -join ', ')) Red; $fail += 'firstbootscripts' }
else { Say 'firstboot set: all 3 present' Green }

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

# ---- 13. customer-facing ---------------------------------------------------
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

Say '======================================' Cyan
if($fail.Count){ Say ('ABORT: ' + ($fail -join ', ')) Red; exit 1 }
if($WhatIf){ Say 'WhatIf - nothing changed, not sealing.' Cyan; exit 0 }

# No confirmation prompt. Preflight above is the gate: licence, unattend,
# pending reboot, rearm budget, TrustedInstaller and already-generalized are all
# hard aborts, so reaching this line means it is safe to proceed.
Say 'PROCEEDING - AppX strip, cleanup, sysprep. VM will power off.' Cyan
Start-Sleep 5

# ---- ROUND 1: AppX ---------------------------------------------------------
if(-not $SkipAppx){ Converge-Appx 'before cleanup' }

# ---- secrets ---------------------------------------------------------------
foreach($x in $secrets){ Remove-Item $x -Force -EA SilentlyContinue }
$still = @($secrets | Where-Object { Test-Path $_ })
if($still.Count){ Say ('WARNING: could not delete ' + ($still -join ', ')) Red } else { Say 'secrets wiped' Green }

# ---- build artefacts -------------------------------------------------------
Get-ScheduledTask -TaskName 'GIBuild' -EA SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -EA SilentlyContinue
Remove-Item 'C:\Scripts\.phase','C:\Scripts\.reboot-pending','C:\Scripts\.prereboot-done' -Force -EA SilentlyContinue
# per-clone host keys - sshd regenerates these on first boot
Remove-Item 'C:\ProgramData\ssh\ssh_host_*' -Force -EA SilentlyContinue
Get-ChildItem 'C:\Users\*\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt' -EA SilentlyContinue |
  Remove-Item -Force -EA SilentlyContinue
Say 'build artefacts + host keys removed'

# ---- event logs ------------------------------------------------------------
# LiveId/Analytic and other protected channels can NEVER be cleared and report
# "Access is denied" on stderr. Swallow both streams - this is not a failure.
$n = 0
foreach($l in (& wevtutil el 2>$null)){ & wevtutil cl "$l" 2>&1 | Out-Null; $n++ }
Say "event logs cleared ($n channels attempted)"

# ---- ROUND 2: AppX again, AFTER the cleanup --------------------------------
# This second round is what made 2025 seal cleanly. Clearing logs and removing
# tasks can leave packages re-staged; stripping only beforehand is not enough.
if(-not $SkipAppx){ Converge-Appx 'after cleanup' }

# ---- sysprep ---------------------------------------------------------------
# Fire it even if the log has noise. Non-fatal entries that are ALWAYS present:
#   SYSPRP MRTGeneralize:98 Failed ConnectServer        (MSRT absent on Server)
#   CSI ... ERROR_ACCESS_DENIED from UnloadStore        (servicing stack)
#   SYSPRP BCD: BiUpdateEfiEntry failed c000000d        (no writable EFI NVRAM)
#   BCD recovery entry points to invalid location       (WinRE not configured)
# A REAL failure reads "Sysprep_Generalize_<plugin> ... hr = 0x8..." AND leaves
# the VM running.
Say 'launching sysprep /generalize /oobe /shutdown ...' Cyan
Remove-Item 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Force -EA SilentlyContinue

# DETACHED. Do NOT run sysprep as a child of this session.
# The Sysprep_Generalize_Pnp phase tears down and reconfigures the network
# adapters. Over SSH that drops the connection, sshd kills the session's whole
# process tree, and sysprep dies mid-generalize - leaving the image
# IMAGE_STATE_UNDEPLOYABLE with an EMPTY setuperr.log (it was terminated, not
# failed). The log always stops at exactly "Sysprep_Generalize_Pnp_Drivers: Exit".
# A SYSTEM scheduled task is owned by the service host, not the session, so it
# survives the network going away.
$tn = 'YCSYSPREP'
$cmdLine = ('"' + $env:WINDIR + '\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /unattend:"' + $U + '"')
& schtasks /create /tn $tn /tr $cmdLine /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Null
& schtasks /run /tn $tn 2>&1 | Out-Null
Say "sysprep launched detached via scheduled task $tn" Cyan

Start-Sleep 20
if(Get-Process sysprep -EA SilentlyContinue){
  Say 'sysprep is RUNNING (detached) - VM will power off when done' Green
  Say 'safe to close this SSH session; sysprep no longer depends on it' Green
  Say 'follow: Get-Content C:\Windows\System32\Sysprep\Panther\setupact.log -Tail 30 -Wait'
  Say 'when it powers off: capture the template. DO NOT boot it again.' Cyan
} else {
  Say 'sysprep exited immediately - reading setuperr.log' Red
  $e = 'C:\Windows\System32\Sysprep\Panther\setuperr.log'
  if(Test-Path $e){
    $hard = Select-String -Path $e -Pattern 'Sysprep_Generalize.*hr = 0x8|RunDlls|WinMain: Hit failure'
    if($hard){ Say 'FATAL:' Red; $hard | ForEach-Object { Say ("  " + $_.Line) Red } }
    else { Say 'no fatal plugin error found - check ImageState, it may have succeeded' Yellow }
    Get-Content $e -Tail 15 | ForEach-Object { Say "  $_" DarkGray }
  } else { Say '  no setuperr.log - check setupact.log' Red }
  Say ("imagestate now: " + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -EA SilentlyContinue).ImageState) Yellow
  exit 1
}
'@
  Set-Content (Join-Path $Scripts 'Seal-Manual.ps1') $seal -Encoding ascii
  Log '  AppX-Strip.ps1 and Seal-Manual.ps1 written (manual seal - build script does NOT sysprep)'
}


Step '53 Strip-Suspect-Tools' {
  # nmap/Npcap and AutoHotkey are NOT installed by this script, but an older
  # build or a manual run can leave them behind - and they are exactly what a
  # customer's AV/EDR flags, plus AutoHotkey ships a Start-menu shortcut called
  # "Window Spy" that looks like spyware in a screenshot.
  #
  # This used to live in Invoke-SealHygiene, which only ran from the automatic
  # seal. Sealing is manual now, so that code never executed - it has to be a
  # real build step. Everything is quiet and guarded; nothing here can fail the
  # build.
  $cc = (Get-Command choco -EA SilentlyContinue).Source
  if($cc){
    foreach($pk in 'nmap','npcap','autohotkey','autohotkey.install','autohotkey.portable'){
      try { & $cc uninstall $pk -y --remove-dependencies --skip-autouninstaller 2>&1 | Out-Null } catch {}
    }
  }
  # registered installers (Programs and Features), in case choco never tracked them
  try { Get-Package -Name '*nmap*','*npcap*','*autohotkey*' -EA SilentlyContinue |
          ForEach-Object { try{ Uninstall-Package $_.Name -Force -EA SilentlyContinue | Out-Null }catch{} } } catch {}

  Remove-Item 'C:\Program Files\Nmap','C:\Program Files\AutoHotkey',
              'C:\Program Files (x86)\Nmap','C:\Program Files (x86)\AutoHotkey' -Recurse -Force -EA SilentlyContinue
  Get-ChildItem 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs' -Recurse `
                -Include '*AutoHotkey*','*Nmap*','*Npcap*','*Window Spy*' -EA SilentlyContinue |
    Remove-Item -Recurse -Force -EA SilentlyContinue
  Remove-Item 'C:\ProgramData\chocolatey\lib\nmap','C:\ProgramData\chocolatey\lib\npcap',
              'C:\ProgramData\chocolatey\lib\autohotkey*' -Recurse -Force -EA SilentlyContinue
  # Npcap installs a kernel driver - remove the service too, not just the files.
  foreach($drv in 'npcap','npf'){ & sc.exe delete $drv 2>&1 | Out-Null }

  # report what, if anything, survived
  $left = @()
  foreach($d in 'C:\Program Files\Nmap','C:\Program Files\AutoHotkey','C:\Program Files (x86)\Nmap','C:\Program Files (x86)\AutoHotkey'){
    if(Test-Path $d){ $left += $d }
  }
  if($left.Count){ Log ('  WARNING: still present -> ' + ($left -join ', ')) }
  else { Log '  no nmap / Npcap / AutoHotkey present (clean)' }
}


Step '54 Stage-Real-Client-Scripts' {
  # The steps above GENERATE small inline versions of the client scripts and a
  # stub yallacloud catalog (~2 KB). The real ones live beside this script in a
  # "scripts" folder - Yallacloud.ps1 alone is ~8 KB and lists far more, and
  # there are ~22 register scripts (Alloy, Otelcol, Promtail, Telegraf, Salt,
  # SqlExporter, WinExporter, Mysqld/PostgresExporter, ...) that nothing here
  # generates at all.
  #
  # This runs LAST on purpose: the real files overwrite the generated stubs,
  # never the other way round. Drop the folder next to GoldenImage.ps1:
  #     GoldenImage.ps1
  #     scripts\        <- Yallacloud.ps1, *-Register.ps1, *-register.cmd, ...
  #     Day2\           <- Day2-Setup.ps1, Setup-HealthMonitors.ps1, ...
  $root = Split-Path $PSCommandPath -Parent
  $n = 0
  foreach($sub in 'scripts','Day2','Monitoring'){
    $src = Join-Path $root $sub
    if(-not (Test-Path $src)){ continue }
    foreach($f in (Get-ChildItem $src -File -Recurse -EA SilentlyContinue)){
      try { Copy-Item $f.FullName (Join-Path $Scripts $f.Name) -Force -EA Stop; $n++ } catch {}
    }
    Log "  staged $sub -> C:\Scripts"
  }
  # PAYLOAD FIRST. The scripts\ folder is the OLD delivery mechanism. If a
  # ycpayload zip is sitting in C:\Scripts, install it here - that is what carries
  # the real 84-file catalog, install-sql and sql-templates. Doing it inside the
  # build removes the "I injected the zip but forgot to run Install-YcPayload"
  # trap that left the 2026-08-11 build on the ~2 KB stub catalog until it was
  # spotted by hand hours later.
  $zip = Get-ChildItem $Scripts -Filter 'ycpayload-*.zip' -File -EA SilentlyContinue |
         Sort-Object Name -Descending | Select-Object -First 1
  $inst = Join-Path $Scripts 'Install-YcPayload.ps1'
  if($zip -and (Test-Path $inst) -and -not (Test-Path (Join-Path $Scripts 'yc-payload-version.txt'))){
    Log ("  payload found: " + $zip.Name + " - installing (four hash gates)")
    try {
      & powershell -NoProfile -ExecutionPolicy Bypass -File $inst -Zip $zip.FullName 2>&1 |
        ForEach-Object { Log ("    " + $_) }
      if($LASTEXITCODE -ne 0){ throw "Install-YcPayload exit=$LASTEXITCODE" }
      $n++
      Log '  payload installed - real catalog now in place'
    } catch { Log ("  PAYLOAD INSTALL FAILED: " + $_.Exception.Message + " - run it by hand before sealing") }
  } elseif(Test-Path (Join-Path $Scripts 'yc-payload-version.txt')) {
    $n++
    Log ('  payload already installed: ' + ((Get-Content (Join-Path $Scripts 'yc-payload-version.txt') -EA SilentlyContinue) -join ' | '))
  }

  if($n -eq 0){
    Log '  WARNING: no payload zip AND no scripts\ folder beside GoldenImage.ps1.'
    Log '           The image keeps the generated ~2 KB STUB catalog: no install-sql,'
    Log '           no sql-templates, only the inline register scripts.'
    Log '           FIX BEFORE SEALING - either:'
    Log '             a) put ycpayload-v263.zip + Install-YcPayload.ps1 in C:\Scripts and re-run -Resume, or'
    Log '             b) run  Install-YcPayload.ps1 -Zip C:\Scripts\ycpayload-v263.zip  by hand.'
  } else {
    Log "  $n real client script(s) staged (generated stubs overwritten)"
    $y = Join-Path $Scripts 'Yallacloud.ps1'
    if(Test-Path $y){ Log ("  Yallacloud.ps1 = " + (Get-Item $y).Length + " bytes") }
  }
  # rebuild the .cmd wrappers for anything staged that lacks one
  foreach($ps in (Get-ChildItem $Scripts -Filter '*-Register.ps1' -EA SilentlyContinue)){
    $name = ($ps.BaseName -replace '-Register$','').ToLower() + '-register'
    $cmd  = Join-Path $Scripts "$name.cmd"
    if(-not (Test-Path $cmd)){
      Set-Content $cmd ("@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$($ps.FullName)`" %*`r`n") -Encoding ascii
      Log "  wrapper created: $name"
    }
  }
}


Step '55 SSH-FirstBoot' {
  # yc-guard.ps1 / yc-guard.cmd and the YCGUARD/YCGUARD5 (boot + every 5 min)
  # tasks that used to be written here are RETIRED: superseded by the
  # build-time YC-Boot/YC-Health/YC-KeyGuard tasks (see the Install-YcTasks
  # step below), under the open-by-default / never-re-enforced access policy.
  # The old yc-guard also force-re-enabled chadmin and forced the network
  # profile to Private on every 5-minute tick - both dropped on purpose, since
  # an administrator who disables something must have it stay disabled.

  # SSH host keys are WIPED at seal for per-clone uniqueness. Windows sshd does
  # not reliably regenerate them, and RunOnce never fires on a headless clone
  # (no interactive logon). This SYSTEM AtStartup task recreates them on the
  # clone's first boot, starts sshd, then removes itself.
  $sshfb = Join-Path $Scripts 'SSH-FirstBoot.ps1'
@'
$ErrorActionPreference="SilentlyContinue"
$kg = @("C:\Windows\System32\OpenSSH\ssh-keygen.exe","C:\Program Files\OpenSSH\OpenSSH-Win64\ssh-keygen.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if(-not $kg){ $kg=(Get-ChildItem "C:\Program Files\OpenSSH" -Recurse -Filter ssh-keygen.exe -EA SilentlyContinue | Select-Object -First 1).FullName }
if($kg -and -not (Test-Path "C:\ProgramData\ssh\ssh_host_ed25519_key")){ & $kg -A | Out-Null }
Set-Service sshd -StartupType Automatic -EA SilentlyContinue
Start-Service sshd -EA SilentlyContinue
Unregister-ScheduledTask -TaskName "GISSHInit" -Confirm:$false -EA SilentlyContinue
'@ | Set-Content $sshfb -Encoding ascii
  $sAct=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\SSH-FirstBoot.ps1'
  $sTrg=New-ScheduledTaskTrigger -AtStartup
  $sPrn=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
  $sSet=New-ScheduledTaskSettingsSet -StartWhenAvailable
  Register-ScheduledTask 'GISSHInit' -Action $sAct -Trigger $sTrg -Principal $sPrn -Settings $sSet -Force | Out-Null
  Log '  GISSHInit registered (regenerates per-clone SSH host keys on first boot)'

  if(Get-ScheduledTask -TaskName 'GISSHInit' -EA SilentlyContinue){ Log '  task GISSHInit OK' } else { Log '  WARNING: task GISSHInit did NOT register' }
}

Step '56 Install-YcTasks' {
  # Replaces the nine legacy tasks (GIGrowDisk, GINetwork, GIDiskGuard, GIWatchdog,
  # YCNET, YCNET5, YCDEPLOY, YCGUARD, YCGUARD5) with three build-time tasks:
  # YC-Boot, YC-Health, YC-KeyGuard. Defensive: also retires any of the nine a
  # previous/partial build left registered, and deletes the yc-net.ps1 /
  # yc-guard.ps1 / yc-guard.cmd files those tasks used - both are superseded by
  # yc-boot.ps1 and are no longer generated.
  #
  # POLICY: access rules (RDP/WinRM/ICMP/SSH-3222) are created ONCE if absent
  # (-Profile Any) and never re-enabled once an admin disables them. The sshd
  # administrators_authorized_keys file + its ACL is the ONLY thing actively
  # enforced (YC-KeyGuard, hourly).

  Set-Content (Join-Path $Scripts 'yc-boot.ps1') @'
# yc-boot.ps1 - one boot task replacing GIGrowDisk + GINetwork + YCDEPLOY + YCGUARD.
# Creates access rules ONCE if absent. Never re-enables anything an admin turned off.
$ErrorActionPreference='SilentlyContinue'
$log='C:\Scripts\yc-boot.log'
function L($m){ Add-Content $log ("[{0}] {1}" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding ascii }
L '--- yc-boot start ---'

# 1. grow C: into unallocated space (portal disk resize lands live)
try { & powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Grow-Disk.ps1 | Out-Null; L 'grow-disk ran' } catch { L "grow-disk: $($_.Exception.Message)" }

# 2. remove ghost NICs left behind when CloudStack hands the clone a new MAC
try { & powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Set-Nic.ps1 -CleanGhosts | Out-Null; L 'set-nic -CleanGhosts ran' } catch { L "set-nic: $($_.Exception.Message)" }

# 3. access rules - CREATE ONLY IF ABSENT. -Profile Any so the Private/Public
#    classification never decides reachability. An admin who disables a rule
#    keeps it disabled; we only ever add a rule that does not exist at all.
$want = @(
  @{ n='YC-SSH-3222';  p='TCP';    port='3222' },
  @{ n='YC-RDP-3389';  p='TCP';    port='3389' },
  @{ n='YC-WinRM-5985';p='TCP';    port='5985' },
  @{ n='YC-WinRM-5986';p='TCP';    port='5986' }
)
foreach($r in $want){
  if(-not (Get-NetFirewallRule -DisplayName $r.n -EA SilentlyContinue)){
    New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Action Allow -Protocol $r.p -LocalPort $r.port -Profile Any | Out-Null
    L ("created firewall rule " + $r.n)
  }
}
if(-not (Get-NetFirewallRule -DisplayName 'YC-ICMPv4' -EA SilentlyContinue)){
  New-NetFirewallRule -DisplayName 'YC-ICMPv4' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow -Profile Any | Out-Null
  L 'created firewall rule YC-ICMPv4'
}

# 4. CloudinitAdmin: hidden always; DISABLED once first boot finished so it
#    cannot keep re-issuing the Administrator password on later boots.
#    chadmin is deliberately NOT touched - if an admin disabled it, it stays so.
$ul='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
if(-not (Test-Path $ul)){ New-Item -Path $ul -Force | Out-Null }
New-ItemProperty -Path $ul -Name 'CloudinitAdmin' -PropertyType DWord -Value 0 -Force | Out-Null
Remove-ItemProperty -Path $ul -Name 'chadmin' -EA 0
$fb='C:\Scripts\yc-firstboot.log'
if((Test-Path $fb) -and ((Get-Content $fb -Raw -EA 0) -match 'yc-firstboot end')){
  $c = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=true and Name='CloudinitAdmin'" -EA 0
  if($c -and -not $c.Disabled){ & net user CloudinitAdmin /active:no 2>&1 | Out-Null; L 'CloudinitAdmin disabled (first boot complete)' }
}

# 5. deploy audit line
$os=(Get-CimInstance Win32_OperatingSystem).Caption
$ip=(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object -First 1).IPAddress
$xpr=(& cscript //nologo C:\Windows\System32\slmgr.vbs /xpr 2>&1) -join ' '
L ("host=$env:COMPUTERNAME ip=$ip os=$os lic=$xpr")
L '--- yc-boot end ---'
'@ -Encoding ascii

  Set-Content (Join-Path $Scripts 'yc-health.ps1') @'
# yc-health.ps1 - daily health pass. Replaces GIDiskGuard + GIWatchdog.
# This is the YC-Health-Chkdsk task Yallacloud.ps1 already documented at 03:30.
$ErrorActionPreference='SilentlyContinue'
$log='C:\Scripts\yc-health.log'
function L($m){ Add-Content $log ("[{0}] {1}" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding ascii }
L '--- yc-health start ---'
foreach($d in (Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' } | ForEach-Object { $_.DriveLetter })){
  if((cmd /c "fsutil dirty query ${d}:") -match 'is Dirty'){ L "${d}: DIRTY -> chkdsk /spotfix"; cmd /c "echo Y| chkdsk ${d}: /spotfix" | Out-Null }
  else { L "${d}: online /scan"; cmd /c "chkdsk ${d}: /scan" | Out-Null }
}
try { & powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Root-Cause.ps1 -Latest | Out-Null; L 'rootcause snapshot written' } catch { L "rootcause: $($_.Exception.Message)" }
L '--- yc-health end ---'
'@ -Encoding ascii

  Set-Content (Join-Path $Scripts 'yc-keyguard.ps1') @'
# yc-keyguard.ps1 - THE ONLY ENFORCED THING ON THE IMAGE.
#
# Ports may be closed, services stopped, accounts disabled - all of that is the
# administrator's call and nothing here undoes it. But the sshd public key must
# survive, because it is the last way back in when everything else is shut.
#
# Guarantees: C:\ProgramData\ssh\administrators_authorized_keys
#   - exists and is NOT empty (restored from the baked backup if wiped)
#   - is ACL'd to Administrators + SYSTEM ONLY. OpenSSH refuses a key file that
#     other principals can write; v259 shipped it with Authenticated Users:(RX),
#     which sshd tolerated but is not the documented requirement.
$ErrorActionPreference='SilentlyContinue'
$log='C:\Scripts\yc-keyguard.log'
function L($m){ Add-Content $log ("[{0}] {1}" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding ascii }
$ak='C:\ProgramData\ssh\administrators_authorized_keys'
$bk='C:\Scripts\.authorized_keys.baked'

if((Test-Path $ak) -and (Get-Item $ak).Length -gt 0){
  # keep a pristine copy so a wipe is recoverable
  if(-not (Test-Path $bk)){ Copy-Item $ak $bk -Force; (Get-Item $bk).Attributes = 'Hidden'; L 'baked backup created' }
} elseif(Test-Path $bk){
  New-Item -ItemType Directory -Force 'C:\ProgramData\ssh' | Out-Null
  Copy-Item $bk $ak -Force
  L 'authorized_keys was MISSING/EMPTY - restored from baked backup'
} else {
  L 'authorized_keys missing and no baked backup - cannot self-heal'
  return
}

# ACL: Administrators + SYSTEM only, inheritance off
$acl = Get-Acl $ak
$need = $acl.Access | Where-Object { $_.IdentityReference -notmatch 'BUILTIN\\Administrators|NT AUTHORITY\\SYSTEM' }
if($need -or -not $acl.AreAccessRulesProtected){
  & icacls $ak /inheritance:r 2>&1 | Out-Null
  & icacls $ak /grant 'BUILTIN\Administrators:F' 'NT AUTHORITY\SYSTEM:F' 2>&1 | Out-Null
  foreach($p in 'NT AUTHORITY\Authenticated Users','BUILTIN\Users','Everyone'){ & icacls $ak /remove $p 2>&1 | Out-Null }
  L 'ACL tightened to Administrators + SYSTEM'
}
'@ -Encoding ascii
  Log '  yc-boot.ps1 + yc-health.ps1 + yc-keyguard.ps1 written'

  # retire any of the nine legacy tasks a previous/partial build left behind
  $old = 'GIGrowDisk','GIDiskGuard','GINetwork','GIWatchdog','YCDEPLOY','YCGUARD','YCGUARD5','YCNET','YCNET5'
  $removed = @()
  foreach($t in $old){
    if(Get-ScheduledTask -TaskName $t -EA SilentlyContinue){
      Unregister-ScheduledTask -TaskName $t -Confirm:$false -EA SilentlyContinue
      $removed += $t
    }
  }
  Log ('  legacy tasks retired: ' + $(if($removed.Count){ $removed -join ', ' } else { 'none present' }))
  Remove-Item (Join-Path $Scripts 'yc-net.ps1'),(Join-Path $Scripts 'yc-guard.ps1'),(Join-Path $Scripts 'yc-guard.cmd') -Force -EA SilentlyContinue

  $ycP   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
  $ycSet = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

  function Reg-YcTask($name,$script,$triggers){
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
         -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\$script")
    Register-ScheduledTask -TaskName $name -Action $a -Trigger $triggers -Principal $ycP -Settings $ycSet -Force | Out-Null
  }

  Reg-YcTask 'YC-Boot'   'yc-boot.ps1'   (New-ScheduledTaskTrigger -AtStartup)
  Reg-YcTask 'YC-Health' 'yc-health.ps1' @((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Daily -At 3:30am))

  # hourly, not every 5 minutes: the key file only changes if something went wrong
  $kt  = New-ScheduledTaskTrigger -AtStartup
  $kt2 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) `
          -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration ([TimeSpan]::FromDays(3650))
  Reg-YcTask 'YC-KeyGuard' 'yc-keyguard.ps1' @($kt,$kt2)

  foreach($t in 'YC-Boot','YC-Health','YC-KeyGuard'){
    if(-not (Get-ScheduledTask -TaskName $t -EA SilentlyContinue)){ throw "task $t did not register" }
  }
  Log '  YC-Boot (startup), YC-Health (startup + 03:30 daily), YC-KeyGuard (startup + hourly) registered'
}

# =====================================================================================
#  PHASE: SEALCHECK  -  report real failures; optionally pause before sealing
# =====================================================================================
if($phase -eq 'sealcheck'){
  Set-Progress 'Checking build results'
  $fails = Select-String $slog -Pattern '\[FAIL\]' -EA SilentlyContinue |
           Where-Object { $_.Line -notmatch 'already|requested size|Error:? *0?x?0*2\b|not supported|cannot find the file|0x80070002' }
  if($fails){ OL ("CONFIG had " + (@($fails).Count) + " failed step(s):"); $fails | ForEach-Object { OL ("   " + ($_.Line -replace '^.*?\d\d:\d\d:\d\d\s+','')) } }
  else { Ok 'All configuration steps OK' }
  if($fails -and $PauseOnFail){ Warn 'PauseOnFail=$true: NOT sealing. Fix the issues, then re-run (resumes into seal).'; exit }
  Set-Content $ph 'reboot'; $phase='reboot'
}

# =====================================================================================
#  PHASE: REBOOT  -  one clean pre-seal reboot so pending updates finalize
# =====================================================================================
if($phase -eq 'reboot'){
  if(-not (Test-Path "$S\.prereboot-done")){
    New-Item "$S\.prereboot-done" -Force | Out-Null
    Set-Progress 'Pre-seal reboot'
    OL 'pre-seal reboot (lets any pending update finalize); will AUTO-RESUME into SEAL'
    Invoke-Power restart; exit
  }
  OL 'resumed after pre-seal reboot'
  Set-Content $ph 'seal'; $phase='seal'
}

# =====================================================================================
#  PHASE: SEAL  -  optimize + sysprep /generalize /shutdown  (removes self last)
# =====================================================================================
function Invoke-Seal {
  $DeepOptimize = [bool]$DeepOptimize
  $OptimizeDisk = if($null -eq $OptimizeDisk){$true}else{[bool]$OptimizeDisk}
  Set-Progress 'Seal - optimize'
  Write-Host @"

============================================================
 SEAL: optimize + sysprep /generalize  (VM will SHUT DOWN)
============================================================
"@ -ForegroundColor Cyan

  # CloudinitAdmin self-disables on the deployed VM's first boot; cloudbase-init runs fresh
  New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name DisableCloudinitAdmin -PropertyType String -Force -Value 'cmd /c net user CloudinitAdmin /active:no' | Out-Null
  $svc=Get-Service cloudbase-init -EA SilentlyContinue; if($svc){ Set-Service cloudbase-init -StartupType Automatic; Stop-Service cloudbase-init -Force -EA SilentlyContinue }

  # SSH host keys are WIPED at seal (per-clone uniqueness). Windows sshd does NOT reliably regenerate them on its
  # own, and RunOnce would NOT fire on a headless cloud-init clone (no interactive logon) - so register a SYSTEM
  # AtStartup task that, on the CLONE's first boot, runs ssh-keygen -A to recreate the host keys, (re)starts sshd
  # on 3222, then removes itself. This guarantees SSH-3222 comes up on every deployed clone.
  $sshfb = Join-Path $S 'SSH-FirstBoot.ps1'
@'
$ErrorActionPreference="SilentlyContinue"
$kg = @("C:\Windows\System32\OpenSSH\ssh-keygen.exe","C:\Program Files\OpenSSH\OpenSSH-Win64\ssh-keygen.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if(-not $kg){ $kg=(Get-ChildItem "C:\Program Files\OpenSSH" -Recurse -Filter ssh-keygen.exe -EA SilentlyContinue | Select-Object -First 1).FullName }
if($kg -and -not (Test-Path "C:\ProgramData\ssh\ssh_host_ed25519_key")){ & $kg -A | Out-Null }
Set-Service sshd -StartupType Automatic -EA SilentlyContinue
Start-Service sshd -EA SilentlyContinue
Unregister-ScheduledTask -TaskName "GISSHInit" -Confirm:$false -EA SilentlyContinue
'@ | Set-Content $sshfb -Encoding ascii
  $sAct=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\SSH-FirstBoot.ps1'
  $sTrg=New-ScheduledTaskTrigger -AtStartup
  $sPrn=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
  $sSet=New-ScheduledTaskSettingsSet -StartWhenAvailable
  Register-ScheduledTask 'GISSHInit' -Action $sAct -Trigger $sTrg -Principal $sPrn -Settings $sSet -Force | Out-Null

  $Once=Join-Path $S '.done'; New-Item -ItemType Directory -Force $Once -EA SilentlyContinue|Out-Null
  function Once($name,$blk){ $mk=Join-Path $Once "seal-$name.done"; if(Test-Path $mk){ Write-Host "  skip $name (already done)" -f DarkGray; return }; & $blk; New-Item $mk -Force|Out-Null }
  # SAFETY NET: make sure NO customer-alarming / AV-flagged tool ever ships in the template. nmap is no longer
  # installed by this script, but an older build or a manual run could have left nmap + Npcap + AutoHotkey (its
  # "AutoHotkey Window Spy" shortcut looks like spyware). Best-effort remove the packages AND their Start-menu
  # shortcuts here so the sealed image is always clean. All quiet + guarded - never blocks the seal.
  Once 'strip-suspect-tools' {
    Write-Host '  stripping any nmap / Npcap / AutoHotkey (customer-alarming) before seal...' -f Cyan
    $cc=(Get-Command choco -EA SilentlyContinue).Source
    if($cc){ foreach($pk in 'nmap','npcap','autohotkey','autohotkey.install','autohotkey.portable'){ try{ Start-Job { param($c,$p) & $c uninstall $p -y --remove-dependencies --skip-autouninstaller 2>$null | Out-Null } -ArgumentList $cc,$pk | Wait-Job -Timeout 120 | Out-Null }catch{} } Get-Job | Remove-Job -Force -EA SilentlyContinue }
    # registered installers (Programs & Features), in case choco did not track them
    try{ Get-Package -Name '*nmap*','*npcap*','*autohotkey*' -EA SilentlyContinue | ForEach-Object { try{ Uninstall-Package $_.Name -Force -EA SilentlyContinue | Out-Null }catch{} } }catch{}
    # leftover files + Start-menu shortcuts (the alarming names) + choco lib folders
    Remove-Item 'C:\Program Files\Nmap','C:\Program Files\AutoHotkey','C:\Program Files (x86)\Nmap','C:\Program Files (x86)\AutoHotkey' -Recurse -Force -EA SilentlyContinue
    Get-ChildItem 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs' -Recurse -Include '*AutoHotkey*','*Nmap*','*Npcap*','*Window Spy*' -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
    Remove-Item 'C:\ProgramData\chocolatey\lib\nmap','C:\ProgramData\chocolatey\lib\npcap','C:\ProgramData\chocolatey\lib\autohotkey*' -Recurse -Force -EA SilentlyContinue
  }
  Stop-Service wuauserv,bits -EA SilentlyContinue
  Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -EA SilentlyContinue
  Get-ChildItem "$env:WINDIR\Temp","C:\Users\*\AppData\Local\Temp" -Directory -EA SilentlyContinue |
    ForEach-Object { Get-ChildItem $_.FullName -Force -EA SilentlyContinue | Where-Object { $_.FullName -ne $env:TEMP } | Remove-Item -Recurse -Force -EA SilentlyContinue }
  New-Item -ItemType Directory -Force $env:TEMP,$env:TMP,'C:\Windows\Temp' -EA SilentlyContinue | Out-Null
  powercfg -h off 2>$null
  $doOpt=($OptimizeDisk -or $DeepOptimize); $optMode=if($DeepOptimize){'DEEP (DISM /ResetBase + defrag + zero-fill)'}else{'Standard (DISM cleanup + TRIM)'}
  if($doOpt){ Send-Ntfy 'GoldenImage: DISK OPTIMIZE START' ('Mode: '+$optMode+' - heavy task, this can take a while.') }
  if($OptimizeDisk -or $DeepOptimize){    # DEEP implies the DISM cleanup (+ /ResetBase) even if Standard was declined
    Set-Progress 'Seal - DISM cleanup'
    Once 'dism' {
      Write-Host ("DISM StartComponentCleanup" + $(if($DeepOptimize){" /ResetBase"})) -f Cyan
      $dt='C:\Scripts\dismtmp'; New-Item -ItemType Directory -Force $dt -EA SilentlyContinue|Out-Null
      if($DeepOptimize){ Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /ScratchDir:$dt 2>&1|Out-Null }
      else             { Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ScratchDir:$dt 2>&1|Out-Null }
      Remove-Item $dt -Recurse -Force -EA SilentlyContinue
      Write-Host "  DISM done (a trailing 'Error: 2' after 100% is a benign Server 2016 quirk)." -f DarkGray
    }
    Once 'trim' { Write-Host "TRIM (reclaim free blocks)..." -f Cyan; Optimize-Volume -DriveLetter C -ReTrim -EA SilentlyContinue }
  } else { Write-Host "Standard disk optimization skipped (user choice)." -f DarkGray }
  if($DeepOptimize){
    Set-Progress 'Seal - deep optimize'
    Once 'defrag' { Write-Host "Defragmenting C: (deep)..." -f Cyan; Optimize-Volume -DriveLetter C -Defrag -EA SilentlyContinue }
    Once 'zero'   { Write-Host "Zeroing free space (sdelete, deep)..." -f Cyan
      $sd=Get-ChildItem $S -Recurse -Filter sdelete64.exe -EA SilentlyContinue | Select-Object -First 1
      if(-not $sd){ try{ Invoke-WebRequest 'https://download.sysinternals.com/files/SDelete.zip' -OutFile "$S\SDelete.zip" -UseBasicParsing; Expand-Archive "$S\SDelete.zip" $S -Force }catch{}; $sd=Get-ChildItem $S -Recurse -Filter sdelete64.exe -EA SilentlyContinue | Select-Object -First 1 }
      if($sd){ Push-Location C:\ ; & $sd.FullName -accepteula -z C: ; Pop-Location } }
  } else { Write-Host "Fast seal: on the HOST run  virt-sparsify --compress in.qcow2 out.qcow2" -f DarkGray }
  if($doOpt){ Send-Ntfy 'GoldenImage: DISK OPTIMIZE DONE' ('Mode: '+$(if($DeepOptimize){'DEEP'}else{'Standard'})+' complete. Proceeding to sysprep.') }

  # dismount the virtio ISO we mounted during config so its .iso file isn't locked, then delete it.
  # IMPORTANT: never call bare 'Get-DiskImage' - its -ImagePath is MANDATORY, so with no argument it
  # blocks forever waiting for input under the non-interactive SYSTEM seal (that was the hang). We
  # dismount ONLY the known ISO path, inside a 60s timeout job so a wedged storage stack can't stall us.
  # (Do NOT use Shell.Application Eject either - that COM call can also hang.) Attached/physical CD-ROMs
  # are detached at the hypervisor after capture, not from inside the guest.
  Set-Progress 'Seal - dismount ISO'
  Once 'dismount' {          # checkpointed: on a re-run/reboot this is SKIPPED (see .done\seal-dismount.done)
    $iso=Join-Path $S 'virtio-win.iso'
    if(Test-Path $iso){
      $dj=Start-Job { param($p) Dismount-DiskImage -ImagePath $p -EA SilentlyContinue } -ArgumentList $iso
      if(-not (Wait-Job $dj -Timeout 60)){ Stop-Job $dj -EA SilentlyContinue; Write-Host '  ISO dismount timed out (storage busy) - continuing.' -f DarkGray }
      Remove-Job $dj -Force -EA SilentlyContinue
      Remove-Item $iso -Force -EA SilentlyContinue
    }
  }

  # reset Windows Update datastore so clones can update cleanly (checkpointed)
  Set-Progress 'Seal - WU store reset'
  Once 'wureset' {
    Write-Host "Resetting Windows Update store..." -f Cyan
    # msiserver (Windows Installer) is NOT part of the WU store and must NOT be stopped - stopping it here was
    # the cause of the sysprep 0x8007001f half-generalize. Only WU services are stopped; cryptsvc is stopped just
    # long enough to delete catroot2, then RESTARTED so sysprep can still validate catalogs.
    Stop-Service wuauserv,bits,dosvc,usosvc,cryptsvc -Force -EA SilentlyContinue
    Remove-Item 'C:\Windows\SoftwareDistribution' -Recurse -Force -EA SilentlyContinue
    Remove-Item 'C:\Windows\System32\catroot2' -Recurse -Force -EA SilentlyContinue
    Remove-Item 'C:\Windows\Logs\WindowsUpdate\*','C:\Windows\WindowsUpdate.log' -Recurse -Force -EA SilentlyContinue
    reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate" /v SusClientId /f 2>$null | Out-Null
    reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate" /v SusClientIdValidation /f 2>$null | Out-Null
    Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -Recurse -Force -EA SilentlyContinue
    Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -Recurse -Force -EA SilentlyContinue
    Set-Service cryptsvc -StartupType Automatic -EA SilentlyContinue; Start-Service cryptsvc -EA SilentlyContinue   # back up before sysprep
  }

  # SECURITY: remove sensitive files (KEEP register scripts, drivers, tools). The RESUME machinery
  # (GIBuild task, .phase, .done markers, gi-settings, GoldenImage.ps1, logs) is kept until JUST before
  # sysprep, so an interrupted seal can be finished by simply REBOOTING or re-running the script - it
  # resumes at the seal phase and SKIPS the checkpointed steps (dism/trim/dismount/...).
  Set-Progress 'Seal - cleanup'
  Once 'cleanup' {
    Write-Host "Removing sensitive files..." -f Cyan
    Unregister-ScheduledTask 'GIWU' -Confirm:$false -EA SilentlyContinue
    Remove-Item (Join-Path $S 'wu-loop.log') -Force -EA SilentlyContinue
    Remove-Item (Join-Path $S 'SDelete.zip'),(Join-Path $S 'OpenSSH-Win64.zip'),(Join-Path $S 'roots.sst'),(Join-Path $S 'SysinternalsSuite.zip') -Force -EA SilentlyContinue
    Remove-Item 'C:\ProgramData\ssh\ssh_host_*' -Force -EA SilentlyContinue   # regenerate UNIQUE host keys per clone
    Get-ChildItem 'C:\Users\*\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
  }
  Set-Progress 'Seal - clear event logs'
  Once 'eventlogs' {
    wevtutil el | ForEach-Object { wevtutil cl "$_" 2>$null }
    Clear-History -EA SilentlyContinue
  }

  # SYSPREP generalize - fully headless (esp. Server 2025 AppX validation dialog)
  $u="$S\Unattend-Seal.xml"; $a='/generalize /oobe /shutdown'; if(Test-Path $u){ $a+=" /unattend:`"$u`"" }
  $sp="$env:WINDIR\System32\Sysprep\Panther\setupact.log"
  $er="$env:WINDIR\System32\Sysprep\Panther\setuperr.log"
  function RmAppx($pkg){ try{ Remove-AppxPackage -Package $pkg -AllUsers -EA Stop }catch{ try{ Remove-AppxPackage -Package $pkg -EA SilentlyContinue }catch{} } }
  # full strip of every removable AppX for ALL users + all provisioned packages (the reliable pre-sysprep step).
  # EACH removal is wrapped in its OWN try/catch: Remove-Appx* can throw a TERMINATING error ("Removal failed.
  # Please contact your software vendor") that -ErrorAction does NOT suppress; unhandled, it aborts the whole
  # ForEach pipeline and skips the rest of the seal. Per-item catch keeps every item + the seal flowing.
  function Deprovision-Appx {
    # ONLY de-provision packages that are ALSO removable per-user. De-provisioning an inbox NonRemovable app
    # (CloudExperienceHost, ShellExperienceHost, AAD.BrokerPlugin, immersivecontrolpanel, Cortana, ...) while its
    # per-user registration stays makes it 'installed for a user but NOT provisioned' -> sysprep generalize dies
    # with 0x80670006. So keep NonRemovable inbox apps provisioned; only strip genuinely removable Store apps.
    $keepProv = @(Get-AppxPackage -AllUsers -EA SilentlyContinue | Where-Object { $_.NonRemovable } | ForEach-Object { $_.Name }) | Sort-Object -Unique
    try{ Get-AppxProvisionedPackage -Online -EA SilentlyContinue | Where-Object { $keepProv -notcontains $_.DisplayName } | ForEach-Object { try{ Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -EA Stop | Out-Null }catch{} } }catch{}
    try{ Get-AppxPackage -AllUsers -EA SilentlyContinue | Where-Object { -not $_.NonRemovable } | ForEach-Object { RmAppx $_.PackageFullName } }catch{}
  }
  # PERMANENT seal log: written to C:\Scripts\seal-result.log which is KEPT on the sealed disk (not removed at
  # teardown). Tells you sysprep + AppX outcome (SUCCESS / FAILED + why) even after sealing - read it on the clone
  # or offline:  virt-cat <disk.qcow2> /Scripts/seal-result.log
  function SealLog($m){ try{ ("$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  "+$m) | Out-File -Append "$S\seal-result.log" -Encoding ascii }catch{}; OL $m }
  Set-Progress 'Seal - sysprep'
  Once 'deprovappx' {
    # Run the AppX de-provision TWICE: a package removed for the current user on pass 1 can still leave a
    # provisioned entry that only clears on a second pass - two passes reliably clears the '...was installed for
    # a user, but not provisioned for all users' sysprep blocker on 2016/2019/2022/2025. Then report what remains.
    Write-Host "De-provisioning removable AppX before sysprep - pass 1 (2016/2019/2022/2025 blocker)..." -f Cyan
    Deprovision-Appx
    Start-Sleep 3
    Write-Host "De-provisioning removable AppX - pass 2 (catch stragglers)..." -f Cyan
    Deprovision-Appx
    $leftPkg = @(Get-AppxPackage -AllUsers -EA SilentlyContinue | Where-Object { -not $_.NonRemovable }).Count
    $leftPrv = @(Get-AppxProvisionedPackage -Online -EA SilentlyContinue).Count
    SealLog "APPX de-provisioned (2 passes): removable-installed=$leftPkg provisioned=$leftPrv (0 removable = clean; any left are NonRemovable/inbox)"
  }
  # Parse BOTH sysprep logs for the package that blocked validation and remove it by name.
  # The exact line on 2016/2019/2022/2025 is:
  #   SYSPRP Package <PackageFullName> was installed for a user, but not provisioned for all users...
  # (The other failure - "Failed to remove apps for the current user: 0x80073CF2" - names NO package;
  #  that one is handled by the full Deprovision-Appx re-run performed on every retry below.)
  function Remove-SysprepBlockers {
    $names=@()
    foreach($f in $sp,$er){ if(Test-Path $f){
      $names += Select-String $f -Pattern 'Package (\S+) was installed for a user' -EA SilentlyContinue | ForEach-Object { $_.Matches.Groups[1].Value }
    } }
    $names = @($names | Where-Object { $_ } | Sort-Object -Unique)
    foreach($p in $names){ $n=($p -split '_')[0]; Write-Host "  removing sysprep blocker: $n" -f Yellow
      Get-AppxPackage -AllUsers $n -EA SilentlyContinue | ForEach-Object { RmAppx $_.PackageFullName }
      try{ Get-AppxProvisionedPackage -Online -EA SilentlyContinue | Where-Object { $_.PackageName -eq $p -or $_.DisplayName -eq $n } | ForEach-Object { try{ Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -EA Stop | Out-Null }catch{} } }catch{} }
    return @($names).Count
  }
  function Invoke-Sysprep {
    # CRITICAL: sysprep's generalize/cleanup phase writes its state via TrustedInstaller (CBS) + msiserver, and
    # validates catalogs via cryptsvc. If ANY of them is stopped, generalize fails with 0x8007001f and the VM is
    # left half-generalized (GeneralizationState=3) and never powers off. The WU-store reset above stops some of
    # these, so we FORCE them back to a startable state and start them right before EVERY sysprep attempt.
    foreach($svc in 'TrustedInstaller','msiserver'){ Set-Service $svc -StartupType Manual -EA SilentlyContinue }
    Set-Service cryptsvc -StartupType Automatic -EA SilentlyContinue
    Start-Service TrustedInstaller,msiserver,cryptsvc -EA SilentlyContinue
    if(Test-Path $sp){ Remove-Item $sp -Force -EA SilentlyContinue }
    if(Test-Path $er){ Remove-Item $er -Force -EA SilentlyContinue }
    # Run sysprep with /QUIT (not /shutdown): it RETURNS control to us after generalize, so we can read the real
    # seal state, write a definitive seal-result.log, and power off OURSELVES - only when ImageState confirms the
    # reseal. We NEVER kill sysprep. The benign 'SPPNP ... Error = 0x2' driver warning is ignored (skipped anyway
    # by PersistAllDeviceInstalls in the unattend). Real success = empty setuperr.log AND ImageState=RESEAL_TO_OOBE.
    $aq = $a -replace '/shutdown','/quit'
    Start-Process "$env:WINDIR\System32\Sysprep\sysprep.exe" -ArgumentList $aq
    for($i=0; $i -lt 360; $i++){
      Start-Sleep 5
      if(-not (Get-Process sysprep -EA SilentlyContinue)){
        Start-Sleep 5
        $errTxt = if(Test-Path $er){ ([string](Get-Content $er -Raw -EA SilentlyContinue)).Trim() } else { '' }
        $img = try{ [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState -EA Stop).ImageState }catch{ '(unknown)' }
        $gs  = try{ [string](Get-ItemProperty 'HKLM:\SYSTEM\Setup\Status\SysprepStatus' -Name GeneralizationState -EA Stop).GeneralizationState }catch{ '(unknown)' }
        # ImageState=RESEAL_TO_OOBE is the AUTHORITATIVE success signal - Windows only sets it when generalize
        # FULLY completes. Do NOT require an empty setuperr.log: on EFI VMs sysprep ALWAYS logs benign firmware
        # errors (BCD/EFI NVRAM write cannot work in a VM: 'BiUpdateEfiEntry/BiExport.../export alterations to
        # firmware ... c000000d') plus MRT 'Failed ConnectServer' - none of these prevent a valid seal (verified:
        # ImageState flips to RESEAL_TO_OOBE with them present). Treating a non-empty setuperr as failure caused
        # false retries that RE-generalize and burn a rearm each time. So judge by ImageState; use setuperr only
        # to explain a REAL non-reseal (after filtering the benign lines).
        $benign = 'BCD:|BiUpdateEfiEntry|BiExportBcdObjects|BiExportStoreAlterationsToEfi|export alterations to firmware|MRTGeneralize|Failed ConnectServer'
        if($img -match 'RESEAL_TO_OOBE'){
          SealLog "SEAL SUCCESS - sysprep generalized. ImageState=$img GeneralizationState=$gs (any BCD/EFI/MRT lines in setuperr are benign VM-firmware warnings). Powering off = SEALED template ready to capture."
          Stop-Computer -Force -EA SilentlyContinue; Start-Sleep 180; return $true
        } else {
          $fatal = @($errTxt -split "`n" | Where-Object { $_.Trim() -and ($_ -notmatch $benign) })
          $why = if($fatal.Count -gt 0){ 'setuperr.log: ' + (($fatal | Select-Object -Last 4) -join ' | ') } else { "generalize did NOT reseal (ImageState=$img, expected *RESEAL_TO_OOBE; GeneralizationState=$gs)" }
          SealLog "SEAL ATTEMPT FAILED - $why"
          return $false
        }
      }
    }
    SealLog 'SEAL ATTEMPT TIMEOUT - sysprep still running after 30 min (NOT killed).'
    return $false
  }
  function Invoke-SealHygiene {
    # Runs right before sysprep (new build OR resume-from-snapshot). Prevents the 0x0606ae
    # 'Required profile hive does not exist: E:\WINDOWS\...\NTUSER.DAT' generalize failure, and bakes the
    # tools that the config phase installs (so a snapshot taken before those tools existed still gets them).
    # 1) FIX stray drive-letter profile paths. A ProfileList entry pointing at a dead letter (e.g. E:\WINDOWS,
    #    left over from an install done with the ISO/other volume holding the early letters) makes sysprep abort.
    $pl='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $sr=$env:SystemRoot; $sd=$env:SystemDrive
    $canon=@{ 'S-1-5-18'="$sr\system32\config\systemprofile"; 'S-1-5-19'="$sr\ServiceProfiles\LocalService"; 'S-1-5-20'="$sr\ServiceProfiles\NetworkService" }
    foreach($sid in $canon.Keys){ $k="$pl\$sid"; if(Test-Path $k){ $cur=[string](Get-ItemProperty $k -Name ProfileImagePath -EA SilentlyContinue).ProfileImagePath
        if($cur -and -not (Test-Path $cur)){ try{ New-ItemProperty $k -Name ProfileImagePath -Value $canon[$sid] -PropertyType ExpandString -Force | Out-Null; SealLog "PROFILE FIX: $sid '$cur' -> '$($canon[$sid])'" }catch{} } } }
    foreach($k in Get-ChildItem $pl -EA SilentlyContinue){ $cur=[string](Get-ItemProperty $k.PSPath -Name ProfileImagePath -EA SilentlyContinue).ProfileImagePath
      if($cur -match '^[A-Za-z]:\\' -and -not (Test-Path $cur)){ $alt=$cur -replace '^[A-Za-z]:', $sd; if(Test-Path $alt){ try{ Set-ItemProperty $k.PSPath -Name ProfileImagePath -Value $alt -EA Stop; SealLog "PROFILE FIX: '$cur' -> '$alt'" }catch{} } } }
    foreach($v in 'ProfilesDirectory','Public','Default'){ $cur=[string](Get-ItemProperty $pl -Name $v -EA SilentlyContinue).$v
      if($cur -match '^[A-Za-z]:\\' -and -not (Test-Path $cur)){ $alt=$cur -replace '^[A-Za-z]:', $sd; if(Test-Path $alt){ try{ Set-ItemProperty $pl -Name $v -Value $alt -EA Stop; SealLog "PROFILE FIX: $v '$cur' -> '$alt'" }catch{} } } }
    # 2) REMOVABLE MEDIA: an attached ISO/CD shifts drive letters and is what bakes the bad E: path. Eject + warn.
    try{ $cd=@(Get-CimInstance Win32_CDROMDrive -EA SilentlyContinue | Where-Object { $_.MediaLoaded })
      if($cd.Count){ SealLog ("WARNING: optical media still loaded ("+(($cd|ForEach-Object{$_.Drive}) -join ',')+") - DETACH the install ISO in CloudStack before sealing"); foreach($d in $cd){ try{ (New-Object -ComObject Shell.Application).Namespace(17).ParseName($d.Drive).InvokeVerb('Eject') }catch{} } } }catch{}
    # 2b) APPX NOTE: inbox SystemApps (CloudExperienceHost, ShellExperienceHost, ...) are ALWAYS NonRemovable and
    #     unprovisioned - that is the normal baseline and sysprep seals fine with it. The 0x80670006 generalize
    #     failure only appears if something DE-PROVISIONED those inbox apps (leaving them installed-but-not-
    #     provisioned). We prevent that in Deprovision-Appx (it now skips NonRemovable). Re-provisioning them is
    #     NOT possible from a live manifest (Add-AppxProvisionedPackage returns 0x8051100f), so we do NOT attempt
    #     it; if an image was already broken by an old de-provision, revert to its pre-sysprep snapshot + reseal.
    # 2c) VMWARE drivers for the OVA/ESXi path. KEY FACT: the VMware Tools installer HARD-GATES on VMware hardware
    #     ("ERROR: Not inside a VM", exit 1602) - so on a KVM build it CANNOT install PVSCSI/VMXNET3. Windows Server
    #     2022/2025 ship those drivers IN-BOX (their OVA uses PVSCSI/VMXNET3); Server 2016/2019 do NOT, so their OVA
    #     uses in-box LSI-SAS+E1000e and the 'vmware-tools' command installs the full set at DEPLOY time on real ESXi.
    #     We still (a) install the VC++ redist - other apps (SQL etc.) need it, and it is KEPT, and (b) stage the
    #     installer so vmware-tools works at deploy.
    $onVmware = try{ ((Get-CimInstance Win32_ComputerSystem -EA Stop).Manufacturer) -match 'VMware' }catch{ $false }
    $hasVmw = (Test-Path "$env:WINDIR\System32\drivers\pvscsi.sys") -or (@(Get-ChildItem "$env:WINDIR\System32\DriverStore\FileRepository\pvscsi*" -Directory -EA SilentlyContinue).Count -gt 0)
    # VC++ 2015-2022 redist (x64+x86) - install if the runtime is missing (needed by VMware Tools AND SQL/other apps); KEPT.
    if(-not (Test-Path "$env:WINDIR\System32\msvcp140.dll")){
      foreach($vc in @(@{u='https://aka.ms/vs/17/release/vc_redist.x64.exe';f='vc_redist.x64.exe'},@{u='https://aka.ms/vs/17/release/vc_redist.x86.exe';f='vc_redist.x86.exe'})){
        $vp="$S\$($vc.f)"
        if((-not (Test-Path $vp)) -or ((Get-Item $vp -EA SilentlyContinue).Length -lt 1MB)){ try{ Get-File $vc.u $vp (1MB) 600 | Out-Null }catch{} }
        if((Test-Path $vp) -and ((Get-Item $vp).Length -ge 1MB)){ try{ Start-Process $vp -ArgumentList '/install /quiet /norestart' -Wait; SealLog "installed $($vc.f) (kept for VMware Tools + other apps)" }catch{ SealLog "VC++ $($vc.f): $($_.Exception.Message)" } }
      }
    }
    # stage the VMware Tools installer so the deploy-time 'vmware-tools' command works (download if missing, >=50MB, retry x4)
    $vt="$S\VMware-Tools-x64.exe"; $vurl='https://packages-prod.broadcom.com/tools/releases/12.5.4/x64/VMware-tools-12.5.4-24964629-x64.exe'
    $vok=(Test-Path $vt) -and ((Get-Item $vt -EA SilentlyContinue).Length -ge 50MB)
    for($vtry=1; (-not $vok) -and $vtry -le 4; $vtry++){ if(Test-Path $vt){ Remove-Item $vt -Force -EA SilentlyContinue }; try{ Get-File $vurl $vt (50MB) 2400 | Out-Null }catch{}; $vok=(Test-Path $vt) -and ((Get-Item $vt -EA SilentlyContinue).Length -ge 50MB); if(-not $vok){ Start-Sleep 15 } }
    if($vok){ SealLog 'VMware Tools 12.5.4 staged in C:\Scripts (run vmware-tools at deploy on the ESXi clone)' } else { SealLog 'VMware Tools installer NOT staged (download failed after 4 tries)' }
    if($hasVmw){ SealLog 'VMware PVSCSI/VMXNET3 present (in-box or installed) - OVA can use PVSCSI+VMXNET3 (PERF=1)' }
    elseif($onVmware -and $vok){ try{ Start-Process $vt -ArgumentList '/S /v "/qn ADDLOCAL=Drivers REBOOT=R"' -Wait; $k='HKLM:\SYSTEM\CurrentControlSet\Services\pvscsi'; if(Test-Path $k){ Set-ItemProperty $k Start 0 -EA SilentlyContinue }; SealLog 'VMware drivers-only installed at seal (running on VMware hardware)' }catch{ SealLog "VMware drivers install error: $($_.Exception.Message)" } }
    else { SealLog 'VMware drivers NOT baked: KVM build - the VMware Tools installer refuses off-VMware ("Not inside a VM"). 2022/2025 have them in-box; for 2016/2019 build the OVA with LSI-SAS+E1000e (make-ova PERF=auto) and run vmware-tools at deploy on ESXi.' }
    # 3) FORGOTTEN TOOLS - provision at seal (idempotent), because the config phase already ran in older snapshots.
    try{ if((Test-Path "$S\Setup-HealthMonitors.ps1") -and -not (Get-ScheduledTask -TaskName 'YC-Health-Chkdsk' -EA SilentlyContinue)){
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$S\Setup-HealthMonitors.ps1" -Install | Out-Null; SealLog 'health monitors installed at seal (YC-Health-Chkdsk/Session/SQL)' } }catch{ SealLog "health monitors seal-install error: $($_.Exception.Message)" }
    try{ if((Test-Path "$S\Setup-Observability.ps1") -and -not (Test-Path "$S\observability-register.cmd")){
        ("@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File ""C:\Scripts\Setup-Observability.ps1"" %*") | Set-Content "$S\observability-register.cmd" -Encoding ascii; SealLog 'observability-register staged at seal' } }catch{}
    if(-not (Test-Path "$S\rotate-password.cmd")){ try{
@'
param([string]$User,[string]$Password,[switch]$Administrator,[switch]$Random,[int]$Length=20,[switch]$Help)
$ErrorActionPreference='Stop'
if($Help -or (-not $User -and -not $Administrator)){ Write-Host 'rotate-password -User <name> -Password "P@ss#1$x"   (or -Administrator -Password ... / -Random). Double-quote; @ # ! $ are literal.'; if($Help){exit 0}else{exit 1} }
function New-StrongPw([int]$n){ $s="ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#%^*-_=+".ToCharArray(); -join (1..$n | ForEach-Object { $s[(Get-Random -Maximum $s.Length)] }) }
$target = if($Administrator){"Administrator"} else {$User}
if($Random){ $Password=New-StrongPw $Length }
if(-not $Password){ Write-Host 'Provide -Password "yourP@ss#1" (double-quoted), or -Random for Administrator.' -ForegroundColor Red; exit 1 }
if(-not (Get-LocalUser $target -EA SilentlyContinue)){ Write-Host "user not found: $target" -ForegroundColor Red; exit 2 }
Set-LocalUser -Name $target -Password (ConvertTo-SecureString $Password -AsPlainText -Force)
Set-LocalUser -Name $target -PasswordNeverExpires $true -EA SilentlyContinue
if($Administrator){ net user Administrator /active:yes | Out-Null }
Write-Host "OK: password rotated for $target" -ForegroundColor Green
Write-Host ("NEWPASSWORD=" + $Password)
'@ | Set-Content "$S\Rotate-Password.ps1" -Encoding ascii
      ("@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File ""C:\Scripts\Rotate-Password.ps1"" %*") | Set-Content "$S\rotate-password.cmd" -Encoding ascii
      SealLog 'rotate-password staged at seal' }catch{} }
  }
  Invoke-SealHygiene
  # OPTIONAL one-time SNAPSHOT pause: if C:\Scripts\.snapshot-pause exists, power off HERE (optimize + cleanup +
  # AppX-deprovision all done, but BEFORE teardown/sysprep). GIBuild task + .phase + GoldenImage.ps1 are still
  # intact, so this is a perfect pre-sysprep checkpoint: take your snapshot, then BOOT the VM and the seal resumes
  # straight into sysprep (the marker below stops it pausing again). Enable with:  ni C:\Scripts\.snapshot-pause
  if(($SnapshotPause -or (Test-Path "$S\.snapshot-pause")) -and -not (Test-Path "$S\.done\seal-snapshot.done")){
    New-Item "$S\.done\seal-snapshot.done" -Force | Out-Null
    OL 'SNAPSHOT PAUSE: powering off before sysprep. Take your snapshot, then BOOT the VM to resume -> sysprep.'
    Set-Progress 'Snapshot pause - power off, snapshot, then boot to resume'
    Send-Ntfy 'GoldenImage: SNAPSHOT PAUSE (powered off - take snapshot, then BOOT to resume -> sysprep)' ("$env:COMPUTERNAME | "+$OS)
    Stop-Computer -Force; exit
  }
  # FINAL teardown - EXACTLY before sysprep. Everything above was kept so an interrupted seal could be
  # resumed by a reboot/re-run; from here the resume machinery (task, phase, checkpoints, logs) AND the
  # secrets (answer file, encrypted password, seed) AND this script are removed, then sysprep runs.
  Clear-Progress
  Unregister-ScheduledTask 'GIBuild' -Confirm:$false -EA SilentlyContinue
  Remove-Item (Join-Path $S '.phase'),(Join-Path $S '.wu-done'),(Join-Path $S '.reboot-pending'),(Join-Path $S '.prereboot-done') -Force -EA SilentlyContinue
  Remove-Item (Join-Path $S '.done') -Recurse -Force -EA SilentlyContinue
  # KEEP the build logs for later review of golden-image issues (NO credentials/keys are ever logged):
  # copy to clearly-named files, then remove the working copies.
  try{ Write-VolumeCache -DriveLetter C -EA SilentlyContinue }catch{}   # flush NTFS cache so the template is CLEAN (no dirty bit)
  Copy-Item (Join-Path $S 'setup-log.txt') (Join-Path $S 'golden-image-build.log') -Force -EA SilentlyContinue
  Copy-Item (Join-Path $S 'build.log')     (Join-Path $S 'golden-image-phases.log') -Force -EA SilentlyContinue
  Remove-Item (Join-Path $S 'build.log'),(Join-Path $S 'setup-log.txt') -Force -EA SilentlyContinue
  Remove-Item (Join-Path $S 'gi-settings.ps1'),(Join-Path $S '.gi-pw'),(Join-Path $S 'gi-pw.seed'),(Join-Path $S 'gi-config.ps1'),(Join-Path $S 'GoldenImage.ps1') -Force -EA SilentlyContinue
  # if a prior attempt left the box PARTIALLY generalized (GeneralizationState>=3), a plain re-run of sysprep
  # just fails again ("machine is in an invalid state"). Clear that state so the next attempt starts clean.
  function Reset-GeneralizeState {
    $gs='HKLM:\SYSTEM\Setup\Status\SysprepStatus'
    try{ $cur=(Get-ItemProperty $gs -Name GeneralizationState -EA SilentlyContinue).GeneralizationState
      if($cur -ge 3){
        Set-ItemProperty $gs -Name GeneralizationState -Value 7 -EA SilentlyContinue
        Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState -Value 'IMAGE_STATE_COMPLETE' -EA SilentlyContinue
        Write-Host '  cleared partial-generalize state (GeneralizationState was '"$cur"') so sysprep can retry cleanly' -f Yellow
      } }catch{}
  }
  # this is the point of no return: SEALING notification fires HERE (only when actually about to sysprep, after any
  # snapshot pause). There is NO "sealed OK" message afterwards - a successful sysprep powers the VM OFF, and that
  # power-off IS your confirmation. If the VM is still ON ~20 min after this, the seal failed (see SEAL FAILED below).
  Send-Ntfy 'GoldenImage: SEALING (sysprep running; VM powers OFF when sealed. Still ON in ~20 min = seal FAILED)' ("$env:COMPUTERNAME | "+$OS)
  SealLog ("SEAL START - "+$OS+" - running sysprep /generalize /oobe (up to 4 tries).")
  $sealed=$false
  foreach($try in 1..4){
    SealLog "sysprep attempt $try ..."
    if(Invoke-Sysprep){ $sealed=$true; break }
    $removed = Remove-SysprepBlockers
    Deprovision-Appx    # aggressive re-strip each retry (covers RemoveAllApps 0x80073cf2 with no named package)
    Reset-GeneralizeState   # undo any partial generalize before the next attempt
    SealLog "attempt $try failed; removed $removed named AppX blocker(s) + re-stripped AppX + cleared partial-generalize; retrying..."
    if($try -eq 4){
      $tail = if(Test-Path $er){ (([string](Get-Content $er -Raw -EA SilentlyContinue)).Trim() -split "`n" | Select-Object -Last 8) -join ' | ' } else { '(setuperr.log empty)' }
      SealLog "SEAL FAILED after 4 tries. VM is still ON. Last setuperr: $tail"
      Send-Ntfy 'GoldenImage: SEAL FAILED - sysprep did not complete after 4 tries. VM is still ON and needs attention.' ("$env:COMPUTERNAME | "+$OS)
      if(Test-Path $sp){ '--- setupact.log ---'; Get-Content $sp -Tail 25 }
      if(Test-Path $er){ '--- setuperr.log ---'; Get-Content $er -Tail 15 }
    }
  }
  # VM powers off on success. Capture the disk as your CloudStack/OpenStack/PVE/VMware template.
}

if($phase -eq 'seal'){
  Section 'Seal'

  # ---- DISK OPTIMIZE: was DEAD CODE. -------------------------------------------------
  # The optimize block lived inside Invoke-Seal, which is only reachable from the
  # AUTOMATIC seal path. Sealing is manual, so Invoke-Seal is never called and a
  # build that answered YES to Standard or DEEP silently got neither - no DISM
  # cleanup, no /ResetBase, no defrag, no zero-fill. Same shape as the
  # Clear-Progress bug. It runs here now, before the manual hand-off, guarded by
  # its own .done marker so a resume does not redo it.
  if(-not (Test-Path "$Done\opt-disk.done")){
    $doOpt = ($OptimizeDisk -or $DeepOptimize)
    if($doOpt){
      $optMode = if($DeepOptimize){'DEEP (DISM /ResetBase + defrag + zero-fill)'}else{'Standard (DISM cleanup + TRIM)'}
      OL ("disk optimize: $optMode - heavy, this can take a while")
      Send-Ntfy 'GoldenImage 4/6: CONFIG DONE - DISK OPTIMIZE STARTED' ("$env:COMPUTERNAME`nMode: $optMode`nThis runs BEFORE the pre-seal snapshot on purpose, so sealing later is quick.")
      $dt='C:\Scripts\dismtmp'; New-Item -ItemType Directory -Force $dt -EA SilentlyContinue | Out-Null
      if($DeepOptimize){ Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /ScratchDir:$dt 2>&1 | Out-Null }
      else             { Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ScratchDir:$dt 2>&1 | Out-Null }
      Remove-Item $dt -Recurse -Force -EA SilentlyContinue
      OL "  DISM component cleanup done (a trailing 'Error: 2' after 100% is a benign 2016 quirk)"
      Optimize-Volume -DriveLetter C -ReTrim -EA SilentlyContinue
      OL '  TRIM done'
      if($DeepOptimize){
        Optimize-Volume -DriveLetter C -Defrag -EA SilentlyContinue
        OL '  defrag done'
        $sd = Get-ChildItem $S -Recurse -Filter sdelete64.exe -EA SilentlyContinue | Select-Object -First 1
        if(-not $sd){
          try{ Invoke-WebRequest 'https://download.sysinternals.com/files/SDelete.zip' -OutFile "$S\SDelete.zip" -UseBasicParsing
               Expand-Archive "$S\SDelete.zip" $S -Force }catch{}
          $sd = Get-ChildItem $S -Recurse -Filter sdelete64.exe -EA SilentlyContinue | Select-Object -First 1
        }
        if($sd){ Push-Location C:\ ; & $sd.FullName -accepteula -z C: | Out-Null ; Pop-Location; OL '  zero-fill done' }
        else   { OL '  zero-fill SKIPPED - sdelete64.exe not found and download failed' }
      }
      Send-Ntfy 'GoldenImage 5/6: OPTIMIZE DONE - TAKE THE PRESEALAGENT SNAPSHOT' ("$env:COMPUTERNAME`nMode: $optMode`nThis is the FORK POINT. No guest agent is installed yet, so this one snapshot serves BOTH stacks.`nPower off, take:  snap02-presealagent-<vm>`nThen per platform:  PreSeal-Agents.ps1 (auto-detects) -> C1 payload -> C2 clean -> C3 Fix-PreSeal -> C4 PATH -> C5 snap -> C6 preflight -> C7 seal")
    } else { OL 'disk optimize skipped (both options declined at the menu)' }
    New-Item "$Done\opt-disk.done" -Force | Out-Null
  } else { OL 'disk optimize already done (marker present)' }
  Send-Ntfy 'GoldenImage 6/6: BUILD COMPLETE - HYPERVISOR-NEUTRAL, WAITING FOR YOU' ("$env:COMPUTERNAME`nphase=seal (presealagent state: drivers in, agents NOT in). No further automation.`nConnect: ssh -i guest.key -p 3222 Administrator@<ip>`nFork this snapshot to KVM and to VMware - the 4h update+app batch is never repeated.")

  # GIBuild task + .phase are intentionally KEPT here (removed only just before sysprep inside Invoke-Seal)
  # so that if the seal is interrupted, a reboot or re-running GoldenImage.ps1 resumes and finishes it.
  # ---- SEAL IS MANUAL. The build script stops here on purpose. --------------
# Automating AppX + sysprep from inside this run is what produced the failed
# seals: sysprep fired while the AppX strip was still settling and while a
# reboot was pending. Both are now separate scripts you run by hand, with a
# real shutdown between them so you can snapshot.
Write-Host ''
# The zip name and member count were hard-coded to v262/172 and stayed wrong once v263
# shipped - the banner told you to install a file that is not on the box. Read reality.
$payZip = (Get-ChildItem (Join-Path $S 'ycpayload-v*.zip') -EA SilentlyContinue |
           Sort-Object Name | Select-Object -Last 1)
$payName = if($payZip){ $payZip.Name } else { 'ycpayload-<version>.zip  (NOT PRESENT)' }
$payCount = 'the count printed by gate3'
try { if(Test-Path (Join-Path $S 'MANIFEST.json')){
        $payCount = ((Get-Content (Join-Path $S 'MANIFEST.json') -Raw | ConvertFrom-Json).members).Count } } catch {}
$sealBlock = @'
=================== BUILD COMPLETE - SEAL IS MANUAL ===================
 Run these IN THIS ORDER. Each one checks the previous one's work.

  C0  ISO check     Dismount-DiskImage -ImagePath C:\Scripts\virtio-win.iso -EA SilentlyContinue
                   (if step 54 said "used by another process", the ISO was still mounted -
                    dismount, then run C1 by hand. Step 54 is marked done and will NOT retry.)

  C1  payload      powershell -File C:\Scripts\Install-YcPayload.ps1 -Zip C:\Scripts\__PAYZIP__
                   (skip if the build already did it - look for "gate4: OK" above)
                   MUST end: gate1..gate4 OK, __PAYCOUNT__ members, exit=0

  C2  clean        powershell -File C:\Scripts\Clean-Scripts.ps1            <- report only, review
                   powershell -File C:\Scripts\Clean-Scripts.ps1 -Apply
                   THEN RE-PUSH: Fix-PreSeal.ps1 Install-YcTasks.ps1 Seal-Manual.ps1
                                 AppX-Strip.ps1 Unattend-Seal.xml
                   (Clean-Scripts deletes the seal tooling on purpose - it must not ship)

  C3  fix          powershell -File C:\Scripts\Fix-PreSeal.ps1
                   MUST end: YC-Boot/YC-Health/YC-KeyGuard registered, MSMQ absent, exit=0

  C4  PATH prune   $mp=[Environment]::GetEnvironmentVariable('Path','Machine')
                   $keep=@($mp -split ';' | ? { $_ -and (Test-Path $_) })
                   [Environment]::SetEnvironmentVariable('Path',($keep -join ';'),'Machine')
                   (removes C:\Scripts\.done and friends - nothing else does this)

  C5  snapshot     shutdown /s /t 0          <- REAL shutdown, not reboot
                   snapshot:  PreSeal-<vm>-v262      then power on

  C6  preflight    powershell -File C:\Scripts\Seal-Manual.ps1 -WhatIf
                   ALL GREEN or fix the cause and re-run. Never seal past an ABORT.

  C7  seal         powershell -File C:\Scripts\Seal-Manual.ps1     <- prints the block
                   then BY HAND, at a console:
                     AppX-Strip.ps1  x4   (errors are expected)
                     sysprep.exe /generalize /oobe /shutdown /unattend:"C:\Scripts\Unattend-Seal.xml"
                   Success = the VM powers ITSELF off. Never judge by setuperr.log.

  C8  capture      from the powered-off ROOT volume. DO NOT boot it again.
======================================================================
'@
$sealBlock = $sealBlock -replace '__PAYZIP__', $payName -replace '__PAYCOUNT__', $payCount
Write-Host $sealBlock -ForegroundColor Green
foreach($ln in ($sealBlock -split "`n")){ Log ('  ' + $ln.TrimEnd()) }
Set-Progress 'Build complete - awaiting MANUAL AppX + seal'
if($script:YcLibLoaded){ Write-YcLog 'CONFIG phase complete - handed off to manual AppX-Strip + Seal-Manual.ps1'; Stop-YcLog 0 }

}
