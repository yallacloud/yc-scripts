# Install-YcTasks.ps1  -  replace the nine v259 scheduled tasks with three, and
#                         switch from ENFORCED access to OPEN-BY-DEFAULT access.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Install-YcTasks.ps1
#
# Run on a golden reverted to its PreSeal snapshot, before Seal-Manual.ps1.
#
# WHAT WAS WRONG
# --------------
# v259 shipped nine tasks: GIGrowDisk, GIDiskGuard, GINetwork, GIWatchdog,
# YCDEPLOY, YCGUARD, YCGUARD5, YCNET, YCNET5. Four separate boot tasks each
# spawning PowerShell, plus TWO tasks looping every five minutes forever doing
# overlapping work - yc-net.ps1 was a strict subset of yc-guard.ps1 apart from
# Start-Service sshd.
#
# Worse, that five-minute loop RE-ASSERTED the network profile, the firewall
# rules and the chadmin account. An administrator could not close a port or
# disable an account and have it stay that way.
#
# THE NEW POLICY - open by default, never re-enforced
# ---------------------------------------------------
#   RDP / WinRM / ICMP / SSH 3222 : rules CREATED ONCE (-Profile Any), enabled.
#                                   Disable or delete one and it STAYS gone.
#   network location Private/Public: NOT forced any more. Every rule is
#                                   -Profile Any, so classification is irrelevant.
#   chadmin                        : created at build, NEVER re-enabled/unhidden.
#   CloudinitAdmin                 : still hidden + disabled after first boot -
#                                   deliberate, it re-issues the Administrator
#                                   password on every boot otherwise.
#   sshd public key                : THE ONE ENFORCED THING. See yc-keyguard.
$ErrorActionPreference = 'Continue'
if($PSVersionTable.PSEdition -eq 'Core'){
  & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
  exit $LASTEXITCODE
}
$S = 'C:\Scripts'
function Say($m,$c='Gray'){ $t = "[{0}] {1}" -f (Get-Date -f 'HH:mm:ss'), $m
                            Write-Host $t -ForegroundColor $c
                            Add-Content "$S\install-yctasks.log" $t -Encoding ascii -EA SilentlyContinue }

Say '===== Install-YcTasks =====' Cyan

# =============================================================== yc-boot.ps1 ==
Set-Content "$S\yc-boot.ps1" @'
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
Say 'yc-boot.ps1 written' Green

# ============================================================= yc-health.ps1 ==
Set-Content "$S\yc-health.ps1" @'
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
Say 'yc-health.ps1 written' Green

# =========================================================== yc-keyguard.ps1 ==
Set-Content "$S\yc-keyguard.ps1" @'
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
Say 'yc-keyguard.ps1 written' Green

# ================================================================== tasks =====
# Retire the nine. Deleting a task that is not there is harmless.
$old = 'GIGrowDisk','GIDiskGuard','GINetwork','GIWatchdog','YCDEPLOY','YCGUARD','YCGUARD5','YCNET','YCNET5'
$removed = @()
foreach($t in $old){
  if(Get-ScheduledTask -TaskName $t -EA SilentlyContinue){
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -EA SilentlyContinue
    $removed += $t
  }
}
Say ("retired: " + $(if($removed.Count){ $removed -join ', ' } else { 'none present' })) Yellow
# yc-deploy.ps1 joined this list in the v265 audit: YCDEPLOY is retired above, so the
# file was surviving as an orphan that nothing ever ran.
Remove-Item "$S\yc-net.ps1","$S\yc-guard.ps1","$S\yc-guard.cmd","$S\yc-deploy.ps1" -Force -EA SilentlyContinue

# -LogonType ServiceAccount is not optional: without it 'SYSTEM' can register as an
# interactive-token principal that never fires at boot, which is silent until it isn't.
$P = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$Set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

function Reg-YcTask($name,$script,$triggers){
  $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
       -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\$script")
  Register-ScheduledTask -TaskName $name -Action $a -Trigger $triggers -Principal $P -Settings $Set -Force | Out-Null
  if(Get-ScheduledTask -TaskName $name -EA SilentlyContinue){ Say "  registered $name -> $script" Green }
  else { Say "  FAILED to register $name" Red }
}

Reg-YcTask 'YC-Boot'     'yc-boot.ps1'     (New-ScheduledTaskTrigger -AtStartup)
Reg-YcTask 'YC-Health'   'yc-health.ps1'   (New-ScheduledTaskTrigger -Daily -At 3:30am)

# hourly, not every 5 minutes: the key file only changes if something went wrong
$kt = New-ScheduledTaskTrigger -AtStartup
$kt2 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) `
        -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration ([TimeSpan]::FromDays(3650))
Reg-YcTask 'YC-KeyGuard' 'yc-keyguard.ps1' @($kt,$kt2)

Say '---------------------------' Cyan
Get-ScheduledTask | Where-Object { $_.TaskName -match '^(YC-|YCFIRSTBOOT|GISSHInit)' } |
  Sort-Object TaskName | ForEach-Object { Say ("  {0,-14} {1}" -f $_.TaskName, $_.State) }
Say 'access is now OPEN BY DEFAULT and NOT re-enforced; only the sshd key is guarded.' Cyan
