# Fix-PreSeal.ps1  -  bring an ALREADY-BUILT golden up to v258 spec without a
#                     rebuild. Run on a golden reverted to its pre-seal snapshot,
#                     immediately before Seal-Manual.ps1.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Fix-PreSeal.ps1
#
# Fixes applied (all idempotent, safe to re-run):
#   1. real client scripts from C:\Scripts\_stage  (Yallacloud.ps1 8KB, 22 register scripts)
#   2. SetupComplete.cmd  -> add the missing "schtasks /run /tn YCFIRSTBOOT"
#   3. yc-net.ps1 + yc-deploy.ps1 so YCNET/YCNET5/YCDEPLOY can register
#   4. sshd DefaultShell/-c, elevated token, config validated with sshd -T
#
# It does NOT sysprep. Run Seal-Manual.ps1 after it.
param([string]$Stage = 'C:\Scripts\_stage',[switch]$Help)

if($Help){
@"
Fix-PreSeal.ps1  -  bring an ALREADY-BUILT golden up to spec without a rebuild.
  Run on a golden reverted to its pre-seal snapshot, immediately before Seal-Manual.ps1.
USAGE:
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Fix-PreSeal.ps1 [-Stage <path>] [-Help]
PARAMETERS:
  -Stage    Folder to pull the real client catalog scripts from (whitelist-copied into C:\Scripts).
            Default: C:\Scripts\_stage
  -Help     Show this help and exit.
EXAMPLES:
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Fix-PreSeal.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Fix-PreSeal.ps1 -Stage D:\stage
"@ | Write-Host
  exit 0
}

if($PSVersionTable.PSEdition -eq 'Core'){
  & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Stage $Stage
  exit $LASTEXITCODE
}
$ErrorActionPreference = 'Continue'
$S = 'C:\Scripts'

# ---------- YallaCloud shared logging (documented scheme: transcript tagged [YALLACLOUD][<cmd>] at
#            C:\Scripts\<cmd>.log via _yc-lib.ps1, mirrored to the Application event log under source
#            YallaCloud, EventIDs 1000/1001/1002/1003/1099). Additive - fix-preseal.log below stays the
#            authoritative per-line record; best-effort so a missing lib never blocks the fix pass. ----------
$script:YcLibLoaded = $false
if(Test-Path "$S\_yc-lib.ps1"){ try{ . "$S\_yc-lib.ps1"; Start-YcLog 'Fix-PreSeal'; $script:YcLibLoaded = $true }catch{} }

function Say($m,$c='Gray'){ $t = "[{0}] {1}" -f (Get-Date -f 'HH:mm:ss'), $m
                            Write-Host $t -ForegroundColor $c
                            Add-Content "$S\fix-preseal.log" $t -Encoding ascii -EA SilentlyContinue
                            if($script:YcLibLoaded){
                              $lvl = switch($c){ 'Red'{'ERROR'} 'Yellow'{'WARN'} 'Green'{'OK'} default{'INFO'} }
                              Write-YcLog $m $lvl
                            } }

Say '===== Fix-PreSeal =====' Cyan

# ---- 1. real client scripts ------------------------------------------------
# GoldenImage.ps1 generated a ~2 KB stub Yallacloud.ps1 and only ~8 register
# scripts inline. The real set is ~8 KB and 22 scripts. Staged copies win.
if(Test-Path $Stage){
  # WHITELIST. The original version copied EVERY file from _stage recursively and
  # flattened it into C:\Scripts. _stage is the jump-host scripts folder, so a
  # v259 clone shipped 230 .sh and 16 .py Linux debug scripts, GoldenImage.ps1
  # (205 KB), the seal tooling and 52 build markers - 1,180 files / 2 GB total.
  # Only the client catalog and the agent registration scripts belong here.
  $want = @('Yallacloud.ps1','yallacloud.cmd','_yc-lib.ps1')
  $pat  = @('*-Register.ps1','*-register.cmd')
  $n = 0
  foreach($f in (Get-ChildItem $Stage -File -Recurse -EA SilentlyContinue)){
    $ok = $want -contains $f.Name
    if(-not $ok){ foreach($p in $pat){ if($f.Name -like $p){ $ok = $true; break } } }
    if(-not $ok){ continue }
    try { Copy-Item $f.FullName (Join-Path $S $f.Name) -Force -EA Stop; $n++ } catch {}
  }
  Say "staged $n client script(s) from $Stage (whitelist)" Green
  $y = Join-Path $S 'Yallacloud.ps1'
  if(Test-Path $y){
    $len = (Get-Item $y).Length
    if($len -gt 6000){ Say "Yallacloud.ps1 = $len bytes (real catalog)" Green }
    else { Say "Yallacloud.ps1 = $len bytes - still the STUB, staging did not include it" Red }
  }
  # .cmd wrapper for any register script that lacks one
  foreach($ps in (Get-ChildItem $S -Filter '*-Register.ps1' -EA SilentlyContinue)){
    $name = ($ps.BaseName -replace '-Register$','').ToLower() + '-register'
    $cmd  = Join-Path $S "$name.cmd"
    if(-not (Test-Path $cmd)){
      Set-Content $cmd ("@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$($ps.FullName)`" %*`r`n") -Encoding ascii
      Say "  wrapper created: $name"
    }
  }
} else { Say "no stage folder at $Stage - client scripts NOT refreshed" Red }

# ---- 2. SetupComplete.cmd must also RUN the task ---------------------------
# /sc onstart alone fires on the NEXT boot, so a fresh clone does nothing:
# firewall stays Public, no rearm, no yc-firstboot.log.
$scDir = 'C:\Windows\Setup\Scripts'
$scf   = Join-Path $scDir 'SetupComplete.cmd'
New-Item -ItemType Directory -Force $scDir | Out-Null
$l1 = 'schtasks /create /tn YCFIRSTBOOT /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\yc-firstboot.ps1" /sc onstart /ru SYSTEM /rl HIGHEST /f'
$l2 = 'schtasks /run /tn YCFIRSTBOOT'
Set-Content $scf "@echo off`r`n$l1`r`n$l2`r`n" -Encoding ascii
$chk = Get-Content $scf -Raw
if(($chk -match '/create\s+/tn\s+YCFIRSTBOOT') -and ($chk -match '/run\s+/tn\s+YCFIRSTBOOT')){
  Say 'SetupComplete.cmd: create + run present' Green
} else { Say 'SetupComplete.cmd: write FAILED' Red }

# ---- 3. yc-net.ps1 / yc-deploy.ps1 ----------------------------------------
# yc-firstboot registers YCNET/YCNET5/YCDEPLOY only if these exist. They never
# did, so the tasks were silently skipped on every clone.
# yc-net.ps1 is RETIRED - its work now lives in yc-guard.ps1 (see section 5) and
# YCNET/YCNET5 are deleted. Kept here only so an older golden that still has the
# tasks registered does not end up pointing at a missing file mid-run.
if($false){
  Set-Content "$S\yc-net.ps1" @'
$ErrorActionPreference='SilentlyContinue'
$log='C:\Scripts\yc-net.log'
$p = Get-NetConnectionProfile
if($p | Where-Object { $_.NetworkCategory -ne 'Private' }){
  $p | Set-NetConnectionProfile -NetworkCategory Private
  Add-Content $log ("[{0}] set profile Private" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss')) -Encoding ascii
}
if(-not (Get-NetFirewallRule -DisplayName 'YC-SSH-3222' -ErrorAction SilentlyContinue)){
  New-NetFirewallRule -DisplayName 'YC-SSH-3222' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3222 -Profile Any | Out-Null
}
$s = Get-Service sshd -ErrorAction SilentlyContinue
if($s -and $s.Status -ne 'Running'){
  Start-Service sshd
  Add-Content $log ("[{0}] restarted sshd" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss')) -Encoding ascii
}
'@ -Encoding ascii
  Say 'yc-net.ps1 created' Green
} else { Say 'yc-net.ps1 already present' Green }

# yc-deploy.ps1 is NOT created any more (v265 audit). YCDEPLOY is retired by
# Install-YcTasks.ps1, so creating the file here only shipped an orphan script
# that nothing ran - and Seal-Manual then demanded it, which is why the two
# only agreed as long as both were wrong.

foreach($f in 'yc-firstboot.ps1','yc-activate.ps1'){
  if(-not (Test-Path "$S\$f")){ Say "MISSING $S\$f - copy it from the v258 kit before sealing" Red }
}

# ---- 4. sshd --------------------------------------------------------------
$bin = 'C:\Program Files\OpenSSH\OpenSSH-Win64'
if(Test-Path "$bin\sshd.exe"){
  $cfg = 'C:\ProgramData\ssh\sshd_config'
  if(Test-Path $cfg){
    # PREPEND. The stock config ends with "Match Group administrators" and
    # anything appended lands inside it -> sshd refuses to start. Subsystem must
    # be the BARE exe name; a quoted absolute path is not parsed as a subsystem.
    $old = Get-Content $cfg |
           Where-Object { $_ -notmatch '^\s*(Port|PasswordAuthentication|PubkeyAuthentication)\s' } |
           ForEach-Object { if($_ -match '^\s*Subsystem\s+sftp'){ '#' + $_ } else { $_ } }
    $head = @('# --- YallaCloud ---','Port 3222','PasswordAuthentication no',
              'PubkeyAuthentication yes','Subsystem sftp sftp-server.exe')
    $start = ($old | Select-String -SimpleMatch '# --- YallaCloud ---' | Select-Object -First 1)
    if($start){ $old = $old[($start.LineNumber + 4)..($old.Count - 1)] }
    Set-Content $cfg ($head + $old) -Encoding ascii
  }
  # single token, or every `ssh host 'cmd'` and scp breaks
  $pwshExe = 'C:\Program Files\PowerShell\7\pwsh.exe'
  if(Test-Path $pwshExe){
    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    New-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell              -Value $pwshExe -PropertyType String -Force | Out-Null
    New-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellCommandOption -Value '-c'     -PropertyType String -Force | Out-Null
  }
  $polKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  if(-not (Test-Path $polKey)){ New-Item -Path $polKey -Force | Out-Null }
  & reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f 2>&1 | Out-Null

  $t = (& "$bin\sshd.exe" -T 2>&1 | Out-String)
  if(($t -match '(?m)^port 3222') -and ($t -match '(?m)^subsystem sftp sftp-server\.exe')){
    Say 'sshd -T: port 3222, subsystem sftp sftp-server.exe' Green
  } else { Say ('sshd -T REJECTED: ' + (($t -split "`n")[0])) Red }
  Say ("shell option = '" + (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -EA SilentlyContinue).DefaultShellCommandOption + "'")
} else { Say 'OpenSSH not installed - skipped' Yellow }

# ---- 5. yc-guard + GISSHInit ----------------------------------------------
# Both of these lived inside Invoke-Seal in the hermes v2.42 line. v258 made
# sealing manual and dropped that function, so BOTH were silently lost.
#
# yc-guard is the durable network fix: a CloudStack stop/start gives the VM a
# NEW MAC, Windows treats it as an unknown network, files it Public and blocks
# SSH/RDP/WinRM/ICMP - the VM looks dead at the login screen. Forcing Private
# fixes it once; making the RULES profile-independent stops it recurring.
$ycg = @'
$ErrorActionPreference='SilentlyContinue'
"[{0}] yc-guard" -f (Get-Date -f s)
# CloudinitAdmin: hidden always; DISABLED once first boot has finished, so it
# cannot keep re-issuing the Administrator password on later boots.
# chadmin is the additional admin account - never disabled, never hidden.
$ul='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
if(-not (Test-Path $ul)){ New-Item -Path $ul -Force | Out-Null }
New-ItemProperty -Path $ul -Name 'CloudinitAdmin' -PropertyType DWord -Value 0 -Force | Out-Null
Remove-ItemProperty -Path $ul -Name 'chadmin' -EA 0
$fbLog = 'C:\Scripts\yc-firstboot.log'
$done  = (Test-Path $fbLog) -and ((Get-Content $fbLog -Raw -EA 0) -match 'yc-firstboot end')
if($done){
  $c = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=true and Name='CloudinitAdmin'" -EA 0
  if($c -and -not $c.Disabled){
    & net user CloudinitAdmin /active:no 2>&1 | Out-Null
    New-Item C:\Scripts\.ycadmin-disabled -ItemType File -Force -EA 0 | Out-Null
    'CloudinitAdmin disabled (first boot complete)'
  }
} else { 'CloudinitAdmin hidden; still enabled - first boot not finished yet' }
$ch = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=true and Name='chadmin'" -EA 0
if($ch -and $ch.Disabled){ & net user chadmin /active:yes 2>&1 | Out-Null; 'chadmin re-enabled' }
if(-not (Test-Path C:\Scripts\.ycfocus-done)){
  $lg='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
  Set-ItemProperty $lg LastLoggedOnUser '.\Administrator' -EA 0
  Set-ItemProperty $lg LastLoggedOnSAMUser '.\Administrator' -EA 0
  Set-ItemProperty $lg LastLoggedOnDisplayName 'Administrator' -EA 0
  New-Item C:\Scripts\.ycfocus-done -ItemType File -Force -EA 0 | Out-Null
}
for($i=0;$i -lt 18;$i++){ if(Get-NetConnectionProfile){break}; Start-Sleep 10 }
Get-NetConnectionProfile | ForEach-Object {
  if($_.NetworkCategory -ne 'DomainAuthenticated'){ Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private }
}
foreach($g in 'Remote Desktop','Windows Remote Management','File and Printer Sharing'){
  Get-NetFirewallRule -DisplayGroup $g -EA 0 | Set-NetFirewallRule -Profile Any -Enabled True
}
New-NetFirewallRule -DisplayName 'YC SSH 3222' -Direction Inbound -Protocol TCP -LocalPort 3222 -Action Allow -Profile Any -EA 0 | Out-Null
New-NetFirewallRule -DisplayName 'YC ICMPv4'  -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow -Profile Any -EA 0 | Out-Null
# sshd: folded in from yc-net.ps1 so YCNET/YCNET5 can be retired. They ran the
# same profile + firewall work as yc-guard every 5 minutes forever; the only
# thing they did that yc-guard did not was start the service.
$svc = Get-Service sshd -ErrorAction SilentlyContinue
if($svc -and $svc.Status -ne 'Running'){ Start-Service sshd; 'sshd started' }
'profiles: ' + ((Get-NetConnectionProfile | ForEach-Object { $_.InterfaceAlias + '=' + $_.NetworkCategory }) -join ', ')
'@
Set-Content "$S\yc-guard.ps1" $ycg -Encoding ascii
Set-Content "$S\yc-guard.cmd" "@echo off`r`npowershell -nop -ExecutionPolicy Bypass -File C:\Scripts\yc-guard.ps1 >> C:\Scripts\deploy.log 2>&1`r`n" -Encoding ascii
# YCGUARD/YCGUARD5 are SUPERSEDED. Install-YcTasks.ps1 replaces all NINE v259
# tasks (GIGrowDisk GIDiskGuard GINetwork GIWatchdog YCDEPLOY YCGUARD YCGUARD5
# YCNET YCNET5) with THREE - YC-Boot / YC-Health / YC-KeyGuard - and switches
# from enforced access to open-by-default. It removes yc-guard.* and yc-net.ps1
# itself, so nothing above needs undoing here.
if(Test-Path "$S\Install-YcTasks.ps1"){
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$S\Install-YcTasks.ps1" 2>&1 |
    ForEach-Object { Say ("  " + $_) }
} else {
  Say 'Install-YcTasks.ps1 MISSING - tasks NOT consolidated, old 9 still in place' Red
}

Set-Content "$S\SSH-FirstBoot.ps1" @'
$ErrorActionPreference="SilentlyContinue"
$kg = @("C:\Windows\System32\OpenSSH\ssh-keygen.exe","C:\Program Files\OpenSSH\OpenSSH-Win64\ssh-keygen.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if(-not $kg){ $kg=(Get-ChildItem "C:\Program Files\OpenSSH" -Recurse -Filter ssh-keygen.exe -EA SilentlyContinue | Select-Object -First 1).FullName }
if($kg -and -not (Test-Path "C:\ProgramData\ssh\ssh_host_ed25519_key")){ & $kg -A | Out-Null }
Set-Service sshd -StartupType Automatic -EA SilentlyContinue
Start-Service sshd -EA SilentlyContinue
Unregister-ScheduledTask -TaskName "GISSHInit" -Confirm:$false -EA SilentlyContinue
'@ -Encoding ascii
$sAct=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\SSH-FirstBoot.ps1'
$sTrg=New-ScheduledTaskTrigger -AtStartup
# -LogonType ServiceAccount is not optional - see Install-YcTasks.ps1.
$sPrn=New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$sSet=New-ScheduledTaskSettingsSet -StartWhenAvailable
Register-ScheduledTask 'GISSHInit' -Action $sAct -Trigger $sTrg -Principal $sPrn -Settings $sSet -Force | Out-Null

$want = 'YC-Boot','YC-Health','YC-KeyGuard','GISSHInit'
$ok = @($want | Where-Object { Get-ScheduledTask -TaskName $_ -EA SilentlyContinue })
if($ok.Count -eq $want.Count){ Say ("tasks registered: " + ($ok -join ', ')) Green }
else { Say ("tasks MISSING - only got: " + ($ok -join ', ')) Red }
$stale = @('GIGrowDisk','GIDiskGuard','GINetwork','GIWatchdog','YCDEPLOY','YCGUARD','YCGUARD5','YCNET','YCNET5' |
           Where-Object { Get-ScheduledTask -TaskName $_ -EA SilentlyContinue })
if($stale.Count){ Say ("STALE v259 tasks still present: " + ($stale -join ', ')) Red }

# ---- 6. MSMQ must go -------------------------------------------------------
# 'Install-WindowsFeature NET-Framework-45-Features' installs the whole umbrella,
# including NET-WCF-MSMQ-Activation45, which depends on MSMQ-Server. Every golden
# therefore shipped a running Message Queuing server. MSMQ registers a sysprep
# generalize provider; with it present sysprep dies right after
# "Sysprep_Generalize_Pnp_Drivers: Exit" leaving a 0-byte setuperr.log.
# Removal REQUIRES a reboot, so this must run before the pre-seal snapshot.
$needReboot = $false
if((Get-WindowsFeature MSMQ -EA SilentlyContinue).Installed){
  Say 'MSMQ installed - removing (this needs a reboot)' Yellow
  $r = Uninstall-WindowsFeature MSMQ -Remove -EA SilentlyContinue
  Say ("  result: {0}, restart needed: {1}" -f $r.Success, $r.RestartNeeded) Yellow
  $needReboot = $true
} else { Say 'MSMQ: absent' Green }

Say '=======================' Cyan
if($needReboot){
  Say 'REBOOT REQUIRED before sealing:' Red
  Say '  1. shutdown /r /t 0' Red
  Say '  2. confirm gone:  Get-WindowsFeature MSMQ' Red
  Say '  3. shutdown /s /t 0  -> snapshot PreSeal-<vm>-v259 -> power on' Red
}
Say 'Next: powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Seal-Manual.ps1 -WhatIf' Cyan
if($script:YcLibLoaded){ Stop-YcLog 0 }
