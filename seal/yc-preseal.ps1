param(
  [switch]$Report,
  [switch]$SkipPayload,
  [switch]$SkipUpdates,
  [int]$MaxUpdatePasses = 3,
  [string]$ExpectCatalog = '2.17.0',
  [string]$Branch = 'main',
  [switch]$Help
)
# =====================================================================================
# yc-preseal.ps1 - bring a TEMPLATE VM up to date and prove it is ready to be sealed.
# PowerShell 5.1 only. ASCII only. Runs from C:\Windows\Temp, NOT from C:\Scripts.
#
# WHY IT LIVES IN TEMP
#   Step 1 replaces the whole of C:\Scripts with the published payload and deletes
#   anything that is not in it. A script that runs from there is deleting itself while
#   it still has work to do. Temp is outside the blast radius.
#
# WHY THE SEAL KIT IS RE-FETCHED
#   Seal-Manual.ps1, Fix-PreSeal.ps1, AppX-Strip.ps1, Clean-Scripts.ps1, doseal.cmd and
#   yc-check.ps1 are seal TOOLING. They are deliberately not in the customer payload, so
#   Update-YcScripts deletes them - which would leave a template that cannot be sealed.
#   They live in the repo under seal/ and are pulled back after the payload update.
#
# WHY IT IS NOT A STATE MACHINE
#   Every step reads the real machine - the .NET Release value, the MSMQ feature, the
#   Windows Update reboot flags - and does nothing if the machine is already there. So
#   it is safe to run it again after every reboot, and there is no state file to go
#   stale, be sealed into an image, or disagree with the box it describes.
#
# EXIT CODES
#   0  every step done - the VM is ready for the seal sequence
#   8  a reboot is required. Reboot, then run this again. NOT an error.
#   1  a step failed, or the final verification failed
#   5  not elevated
# Log: C:\Windows\Temp\yc-preseal.log
# =====================================================================================
$ErrorActionPreference = 'Continue'
$Log  = 'C:\Windows\Temp\yc-preseal.log'
$Pass = 'C:\Windows\Temp\yc-preseal-updpass.txt'
$S    = 'C:\Scripts'
$Raw  = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/' + $Branch

function L([string]$m, [string]$lvl = 'INFO') {
  $line = ((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') + '  [' + $lvl + '] ' + $m)
  Write-Output $line
  try { Add-Content -Path $Log -Value $line -Encoding ascii } catch { }
}

# -------------------------------------------------------------------------------------
# THE EXIT CODE IS NOT ENOUGH, so every ending also prints a sentinel line.
# The guests' OpenSSH DefaultShell is pwsh 7, and pwsh collapses ANY non-zero child exit
# code to 1 when it is the login shell: 'ssh host powershell -Command "exit 8"' comes back
# as 1. Measured, not assumed. A driver that reads only $? cannot tell "reboot and run me
# again" from "this failed", which is the one distinction the loop is built on.
# The sentinel is the last line of output and says which it is.
# -------------------------------------------------------------------------------------
# raw.githubusercontent returns intermittent 503s. Measured during the first real run:
# six of the eight seal-kit files failed in the same second, on three separate guests. One
# attempt per file is not a download, it is a coin toss - and the cost of losing is a
# template that gets all the way to the seal gate before anyone finds out the tooling is
# not there. Retries, a cache-buster so a CDN edge cannot serve yesterday's copy, and a
# hard stop the moment a file really cannot be fetched.
function Get-YcFile {
  param([string]$Url, [string]$Path, [int]$Tries = 5)
  for ($n = 1; $n -le $Tries; $n++) {
    try {
      $u = $Url + '?cb=' + [guid]::NewGuid().ToString('N')
      Invoke-WebRequest -Uri $u -OutFile $Path -UseBasicParsing -ErrorAction Stop
      if ((Get-Item $Path -ErrorAction SilentlyContinue).Length -gt 0) { return $true }
    } catch {
      if ($n -eq $Tries) { L ('   fetch failed after ' + $Tries + ' tries: ' + $Url + ' - ' + $_.Exception.Message) 'ERROR' }
      else { Start-Sleep -Seconds (3 * $n) }
    }
  }
  return $false
}

function End-YcPreseal([string]$verdict, [int]$code) {
  L ('YC-PRESEAL-RESULT: ' + $verdict)
  exit $code
}

if ($Help) {
@"
yc-preseal.ps1 - update a template VM and prove it is ready to seal.

  yc-preseal.ps1                  do the work. Exit 8 means reboot and run it again.
  yc-preseal.ps1 -Report          verify only. Changes NOTHING.
  yc-preseal.ps1 -SkipUpdates     everything except the Windows Update pass
  yc-preseal.ps1 -SkipPayload     leave C:\Scripts alone (it is already current)
  yc-preseal.ps1 -MaxUpdatePasses 5
  yc-preseal.ps1 -ExpectCatalog 2.17.0

WHAT IT DOES, in order
  1 payload   C:\Scripts <- the published payload, NO backup kept, then the seal kit
              is pulled back from the repo because the payload does not carry it.
  2 path      C:\Scripts is put on the MACHINE Path if it is missing, and dead entries
              are pruned. Nothing verified this before - yc-check only looked for dead
              entries, and 'yallacloud resolves' can pass off an inherited session Path.
  2b tls      Server 2016 only: machine-wide TLS 1.2 for .NET. Its default is Ssl3+Tls,
              which makes every HTTPS call to GitHub or chocolatey.org look like a dead
              network. Baked into the image here instead of forced per script forever.
  3 dotnet    install-dotnet -UpgradeChocolatey. 2016 and 2019 need it; 2022 and 2025
              are already above the bar and it is a no-op. This uses the choco netfx-4.8
              package, which touches NO Windows feature - so it cannot pull in MSMQ.
  4 msmq      MSMQ must not be on the box. Install-WindowsFeature NET-Framework-45-Features
              drags in NET-WCF-MSMQ-Activation45 -> MSMQ-Server, and Seal-Manual refuses
              to seal an image that has it. Removed here if present.
  5 updates   winupdate -All -Install, repeated across reboots until Windows stops asking
              for one, up to -MaxUpdatePasses.
  6 focus     LogonUI points at .\Administrator so the console lands on the right account.
  7 verify    catalogue version, .NET, Chocolatey, MSMQ, Path, every .cmd resolvable,
              the function-name/alias collision check, and yc-check.

AFTER exit 0: reboot once, then run the seal sequence by hand.
"@ | Write-Output
  exit 0
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  L 'not elevated' 'ERROR'; End-YcPreseal 'NOTADMIN' 5
}

$os    = (Get-CimInstance Win32_OperatingSystem).Caption
$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
L ('=== yc-preseal on ' + $env:COMPUTERNAME + ' - ' + $os + ' build ' + $build)

function Test-YcRebootPending {
  $a = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
  $b = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
  $c = $false
  try {
    $v = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
    if ($v.PendingFileRenameOperations) { $c = $true }
  } catch { }
  return ($a -or $b -or $c)
}
function Get-YcDotNetRelease {
  $r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction SilentlyContinue
  if ($r) { return [int]$r.Release } else { return 0 }
}
function Get-YcMsmq {
  $svc = Get-Service MSMQ -ErrorAction SilentlyContinue
  $f = $null
  try { $f = Get-WindowsFeature MSMQ -ErrorAction SilentlyContinue } catch { }
  return ([bool]$svc -or ($f -and $f.Installed))
}
function Get-YcCatalogVersion {
  $p = Join-Path $S 'Yallacloud.ps1'
  if (-not (Test-Path $p)) { return '' }
  $m = Select-String -Path $p -Pattern "^\`$YcCatalogVersion\s*=\s*'([^']+)'" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($m) { return $m.Matches[0].Groups[1].Value }
  return ''
}
function Get-YcChocoVersion {
  $c = Get-Command choco.exe -ErrorAction SilentlyContinue
  if (-not $c) { return '' }
  return (& $c.Source --version 2>&1 | Select-Object -First 1)
}

# -------------------------------------------------------------------------------------
# A reboot that is already pending poisons everything after it: the .NET install refuses,
# Windows Update stacks a second pending state on top of the first, and Seal-Manual
# aborts on 'pendingreboot' at the end anyway. Take it first, before doing any work.
# -------------------------------------------------------------------------------------
if (-not $Report -and (Test-YcRebootPending)) {
  L 'a restart is already pending. Reboot, then run this again.' 'WARN'
  End-YcPreseal 'REBOOT' 8
}

$fail = @()

# ---- 1 PAYLOAD ----------------------------------------------------------------------
if ($Report -or $SkipPayload) {
  L '1 payload  : skipped'
} else {
  $u = Join-Path $S 'Update-YcScripts.ps1'
  if (-not (Test-Path $u)) {
    L ('1 payload  : ' + $u + ' is missing - fetching it') 'WARN'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-YcFile ($Raw + '/Update-YcScripts.ps1') $u)) { L 'could not fetch Update-YcScripts.ps1' 'ERROR'; End-YcPreseal 'FAILED' 1 }
  }
  L '1 payload  : Update-YcScripts (sha256 verified, NO backup kept)'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $u *>> $Log
  $rc = $LASTEXITCODE
  L ('1 payload  : Update-YcScripts rc=' + $rc)
  if ($rc -ne 0) { L 'payload update failed' 'ERROR'; End-YcPreseal 'FAILED' 1 }

  # The seal kit is not in the payload, so the line above just deleted it.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $kit = 'Seal-Manual.ps1','Fix-PreSeal.ps1','AppX-Strip.ps1','Clean-Scripts.ps1',
         'Install-YcTasks.ps1','PreSeal-Agents.ps1','yc-check.ps1','doseal.cmd'
  $kitBad = @()
  foreach ($k in $kit) {
    if (Get-YcFile ($Raw + '/seal/' + $k) (Join-Path $S $k)) { L ('1 payload  : seal kit restored - ' + $k) }
    else { L ('1 payload  : COULD NOT restore ' + $k) 'ERROR'; $kitBad += $k }
  }
  # Stop HERE, not at the gate. A template with a missing seal kit will run every other
  # step, take its reboots, and only fail twenty minutes later on a row that does not say
  # what actually went wrong.
  if ($kitBad.Count) {
    L ('1 payload  : the seal kit is incomplete (' + ($kitBad -join ', ') + '). Re-run - these are 503s from raw.githubusercontent, not a real absence.') 'ERROR'
    End-YcPreseal 'FAILED' 1
  }
}

# ---- 2 PATH -------------------------------------------------------------------------
$mp    = [Environment]::GetEnvironmentVariable('Path','Machine')
$parts = @($mp -split ';' | Where-Object { $_ -and $_.Trim() })
$hasS  = @($parts | Where-Object { $_.TrimEnd('\') -ieq $S }).Count -gt 0
$dead  = @($parts | Where-Object { -not (Test-Path $_) })
if ($Report) {
  L ('2 path     : C:\Scripts on machine Path = ' + $hasS + ', dead entries = ' + $dead.Count)
  if (-not $hasS) { $fail += 'path:missing' }
  if ($dead.Count) { $fail += 'path:dead' }
} else {
  $keep = @($parts | Where-Object { Test-Path $_ })
  if (-not $hasS) { $keep = @($S) + $keep; L '2 path     : adding C:\Scripts to the machine Path' }
  if ($dead.Count) { L ('2 path     : pruning ' + $dead.Count + ' dead entries: ' + ($dead -join ' ; ')) }
  if ((-not $hasS) -or $dead.Count) {
    [Environment]::SetEnvironmentVariable('Path', ($keep -join ';'), 'Machine')
    $env:Path = ($keep -join ';') + ';' + $env:Path
    L '2 path     : machine Path rewritten'
  } else {
    L '2 path     : already correct'
  }
}

# ---- 2b TLS 1.2 (Server 2016 only) --------------------------------------------------
# Server 2016's .NET default SecurityProtocol is "Ssl3, Tls". GitHub and chocolatey.org
# both require TLS 1.2, so every .NET HTTPS call on a stock 2016 box fails with
#   The underlying connection was closed: An unexpected error occurred on a send.
# which reads exactly like a dead network. Measured on 100.64.20.11 and .12: gateway
# reachable, DNS fine, ping fine, and raw.githubusercontent returns 200 the moment
# TLS 1.2 is forced in-process.
#
# Individual scripts already force it per-process, and that is what has been carrying
# 2016 so far. It is the wrong place: choco 1.4.0, any installer, and anything a customer
# later runs on a clone of this template all get the 2010 default. Setting it MACHINE-WIDE
# here bakes the fix into the image instead of re-applying it per script forever.
# Both the 64-bit and 32-bit keys - a 32-bit process reads the WOW6432Node one.
if ($build -le 14393) {
  $tlsKeys = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
  $before = (Get-ItemProperty $tlsKeys[0] -Name SchUseStrongCrypto -ErrorAction SilentlyContinue).SchUseStrongCrypto
  if ($Report) {
    L ('2b tls     : Server 2016 - SchUseStrongCrypto = ' + $(if ($null -eq $before) { 'NOT SET' } else { $before }))
    if ($before -ne 1) { $fail += 'tls12' }
  } else {
    foreach ($k in $tlsKeys) {
      if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
      New-ItemProperty -Path $k -Name 'SchUseStrongCrypto'       -PropertyType DWord -Value 1 -Force | Out-Null
      New-ItemProperty -Path $k -Name 'SystemDefaultTlsVersions' -PropertyType DWord -Value 1 -Force | Out-Null
    }
    # The .NET half only tells managed code to ASK for TLS 1.2. SCHANNEL still has to be
    # willing to offer it, and on 2016 the TLS 1.2 Client key does not exist at all, which
    # leaves the protocol at whatever the OS default happens to be. Both halves or neither.
    $sch = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
    if (-not (Test-Path $sch)) { New-Item -Path $sch -Force | Out-Null }
    New-ItemProperty -Path $sch -Name 'Enabled'           -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $sch -Name 'DisabledByDefault' -PropertyType DWord -Value 0 -Force | Out-Null
    L ('2b tls     : machine-wide TLS 1.2 for .NET set (was ' + $(if ($null -eq $before) { 'not set' } else { $before }) + ')')
  }
} else {
  L '2b tls     : not 2016 - .NET already negotiates TLS 1.2'
}

# ---- 2c ADMINISTRATOR LOCKOUT ------------------------------------------------------
# net accounts /lockoutthreshold:0, in the IMAGE.
# A public IP takes roughly 3000 brute-force logons an hour and the stock threshold is 10,
# so the Administrator account locks within seconds of the VM becoming reachable and SSH,
# WinRM and RDP all refuse a password that is perfectly correct. It reads as a broken image
# every single time. Measured on the v264 clone vc2019test 2026-09-08: threshold 10,
# straight out of a freshly sealed template - nothing in the seal path had ever set it.
# yc-boot re-asserts it every boot; this is the baked value so a clone is correct from its
# very first second, before any task has run.
function Get-YcLockoutThreshold {
  $l = @(& net accounts) | Where-Object { $_ -match 'Lockout threshold' }
  if (-not $l) { return '?' }
  return (($l | Select-Object -First 1) -replace '[^0-9]','')
}
$lt = Get-YcLockoutThreshold
if ($Report) {
  L ('2c lockout  : threshold = ' + $lt)
  if ($lt -ne '0') { $fail += 'lockout' }
} elseif ($lt -eq '0') {
  L '2c lockout  : threshold already 0'
} else {
  & net accounts /lockoutthreshold:0 *>> $Log
  $now = Get-YcLockoutThreshold
  if ($now -eq '0') { L ('2c lockout  : threshold ' + $lt + ' -> 0') }
  else { L ('2c lockout  : FAILED - threshold still reads ' + $now) 'ERROR'; End-YcPreseal 'FAILED' 1 }
}

# ---- 3 DOTNET + CHOCOLATEY ----------------------------------------------------------
$rel = Get-YcDotNetRelease
if ($Report) {
  L ('3 dotnet   : Release ' + $rel + ', choco ' + (Get-YcChocoVersion))
} elseif ($rel -ge 528040) {
  L ('3 dotnet   : Release ' + $rel + ' is already 4.8 or better')
  # 2022/2025 ship 4.8+ but can still be on choco 1.x. Ask for the upgrade anyway; the
  # script no-ops when choco is already 2.x.
  & cmd /c 'C:\Scripts\install-dotnet.cmd -UpgradeChocolatey' *>> $Log
  L ('3 dotnet   : install-dotnet -UpgradeChocolatey rc=' + $LASTEXITCODE)
} else {
  L ('3 dotnet   : Release ' + $rel + ' is below 4.8 - installing (choco netfx-4.8, no Windows feature is touched)')
  & cmd /c 'C:\Scripts\install-dotnet.cmd -UpgradeChocolatey' *>> $Log
  $rc = $LASTEXITCODE
  L ('3 dotnet   : install-dotnet rc=' + $rc)
  if ($rc -eq 8) { L '3 dotnet   : .NET installed - REBOOT and run this again' 'WARN'; End-YcPreseal 'REBOOT' 8 }
  if ($rc -ne 0) { L ('install-dotnet failed rc=' + $rc) 'ERROR'; End-YcPreseal 'FAILED' 1 }
}

# ---- 4 MSMQ -------------------------------------------------------------------------
if (Get-YcMsmq) {
  if ($Report) { L '4 msmq     : PRESENT - Seal-Manual will refuse to seal this image' 'ERROR'; $fail += 'msmq' }
  else {
    L '4 msmq     : present - removing (Uninstall-WindowsFeature MSMQ -Remove)' 'WARN'
    try {
      $r = Uninstall-WindowsFeature MSMQ -Remove -ErrorAction Stop
      L ('4 msmq     : removed, restart needed = ' + $r.RestartNeeded)
      L '4 msmq     : REBOOT and run this again' 'WARN'
      End-YcPreseal 'REBOOT' 8
    } catch { L ('4 msmq     : removal failed - ' + $_.Exception.Message) 'ERROR'; End-YcPreseal 'FAILED' 1 }
  }
} else { L '4 msmq     : absent' }

# ---- 5 WINDOWS UPDATE ---------------------------------------------------------------
if ($Report -or $SkipUpdates) {
  L '5 updates  : skipped'
} else {
  $p = 0
  if (Test-Path $Pass) { $p = [int]((Get-Content $Pass -TotalCount 1) -replace '\D','') }
  if ($p -ge $MaxUpdatePasses) {
    L ('5 updates  : ' + $p + ' passes already done - moving on')
  } else {
    Set-Content -Path $Pass -Value ([string]($p + 1)) -Encoding ascii
    L ('5 updates  : winupdate -All -Install, pass ' + ($p + 1) + ' of ' + $MaxUpdatePasses)
    # No -Reboot. This script owns the reboot decision, and it asks WINDOWS whether one
    # is wanted rather than reading it out of an exit code that winupdate never sets.
    & cmd /c 'C:\Scripts\winupdate.cmd -All -Install' *>> $Log
    L ('5 updates  : winupdate rc=' + $LASTEXITCODE)
    if (Test-YcRebootPending) { L '5 updates  : restart pending - REBOOT and run this again' 'WARN'; End-YcPreseal 'REBOOT' 8 }
    L '5 updates  : no restart wanted'
  }
}

# ---- 6 LOGON FOCUS ------------------------------------------------------------------
$lu = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
$cur = (Get-ItemProperty $lu -Name LastLoggedOnSAMUser -ErrorAction SilentlyContinue).LastLoggedOnSAMUser
if ($Report) {
  L ('6 focus    : LastLoggedOnSAMUser = ' + $cur)
  if ($cur -ne '.\Administrator') { $fail += 'focus' }
} else {
  # Set every time, not once behind a sentinel. Fix-PreSeal guards this with
  # C:\Scripts\.ycfocus-done, and Update-YcScripts does not keep that file - so on a
  # refreshed template the sentinel is gone but the value may also have been changed by
  # a console logon since. Writing it is idempotent and costs nothing.
  Set-ItemProperty $lu LastLoggedOnUser        '.\Administrator' -ErrorAction SilentlyContinue
  Set-ItemProperty $lu LastLoggedOnSAMUser     '.\Administrator' -ErrorAction SilentlyContinue
  Set-ItemProperty $lu LastLoggedOnDisplayName 'Administrator'   -ErrorAction SilentlyContinue
  New-Item 'C:\Scripts\.ycfocus-done' -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
  L '6 focus    : console logon focused on .\Administrator'
}

# ---- 7 VERIFY -----------------------------------------------------------------------
L '7 verify   : ---------------------------------------------------------------'
function V([string]$n, [bool]$ok, [string]$v) {
  L ('7 verify   : {0,-22} {1,-4} {2}' -f $n, $(if ($ok) { 'PASS' } else { 'FAIL' }), $v)
  if (-not $ok) { $script:fail += $n }
}

$schK = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
# Fix 5 is not "Update-YcScripts exists", it is "the payload on this image is the published
# one". Compare the sha the updater recorded against the sha GitHub is serving right now.
$script:payloadCurrent = $false
$script:payloadNote = 'not checked'
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $pub = ((Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256' -UseBasicParsing -TimeoutSec 30).Content -split '\s+')[0].ToUpper()
  $loc = ''
  if (Test-Path (Join-Path $S '.payload-sha256')) { $loc = ((Get-Content (Join-Path $S '.payload-sha256') -TotalCount 1) -replace '\s','').ToUpper() }
  $script:payloadCurrent = ($loc -and $loc -eq $pub)
  $script:payloadNote = 'local ' + $(if ($loc) { $loc.Substring(0,12) } else { 'none' }) + ' vs published ' + $pub.Substring(0,12)
} catch { $script:payloadNote = 'could not reach GitHub: ' + $_.Exception.Message }

$cat = Get-YcCatalogVersion
V 'catalogue' ($cat -eq $ExpectCatalog) ($cat + ' (want ' + $ExpectCatalog + ')')
$rel = Get-YcDotNetRelease
V 'dotnet 4.8+' ($rel -ge 528040) ('Release ' + $rel)
$sc = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name SchUseStrongCrypto -ErrorAction SilentlyContinue).SchUseStrongCrypto
V 'tls 1.2 machine-wide' ($build -gt 14393 -or $sc -eq 1) $(if ($build -gt 14393) { 'n/a above 2016' } else { 'SchUseStrongCrypto=' + $sc })
$cv = Get-YcChocoVersion
V 'chocolatey 2.x' ($cv -match '^[2-9]\.') $cv
V 'msmq absent' (-not (Get-YcMsmq)) 'not installed'
$mp2   = [Environment]::GetEnvironmentVariable('Path','Machine')
$parts = @($mp2 -split ';' | Where-Object { $_ -and $_.Trim() })
V 'C:\Scripts on Path' (@($parts | Where-Object { $_.TrimEnd('\') -ieq $S }).Count -gt 0) 'machine Path'
V 'no dead Path entries' (@($parts | Where-Object { -not (Test-Path $_) }).Count -eq 0) ($parts.Count.ToString() + ' entries')
V 'reboot not pending' (-not (Test-YcRebootPending)) 'CBS / WU / FileRename'

# every .cmd wrapper must be reachable BY NAME - that is what 'the commands work' means,
# and it is the thing a missing C:\Scripts on the Path silently breaks.
$cmds = @(Get-ChildItem $S -Filter '*.cmd' -File -ErrorAction SilentlyContinue)
$unres = @($cmds | Where-Object { -not (Get-Command $_.BaseName -ErrorAction SilentlyContinue) })
V 'cmd wrappers resolve' ($cmds.Count -ge 30 -and $unres.Count -eq 0) ($cmds.Count.ToString() + ' wrappers, ' + $unres.Count + ' unresolvable' + $(if ($unres.Count) { ': ' + (($unres | Select-Object -First 5).BaseName -join ' ') } else { '' }))

# PowerShell resolves an ALIAS before a FUNCTION. A payload function called R ran
# Invoke-History on every call and returned nothing. Every function name the payload
# defines is checked against the built-in aliases here so that cannot ship again.
$fn = @()
foreach ($f in Get-ChildItem $S -Filter '*.ps1' -File -ErrorAction SilentlyContinue) {
  $fn += @(Select-String -Path $f.FullName -Pattern '^\s*function\s+([A-Za-z0-9_-]+)' -AllMatches -ErrorAction SilentlyContinue |
           ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value })
}
$fn = @($fn | Sort-Object -Unique)
$clash = @($fn | Where-Object { Get-Alias $_ -ErrorAction SilentlyContinue })
V 'no alias collisions' ($clash.Count -eq 0) ($fn.Count.ToString() + ' function names, ' + $clash.Count + ' clash' + $(if ($clash.Count) { ': ' + ($clash -join ' ') } else { '' }))

# ---- guest tooling: REPORTED, never a gate --------------------------------------
# A template can be perfectly sealable with none of this, and the two hypervisors want
# different halves of it, so nothing here is allowed to fail the run. It is here because
# "which VMware Tools / virtio build is baked into this image" is the question asked
# every time a clone misbehaves, and nobody could answer it from the machine.
function I([string]$n, [string]$v) { L ('7 verify   : {0,-22} {1,-4} {2}' -f $n, 'INFO', $v) }

$vmtVer = ''
foreach ($k in 'HKLM:\SOFTWARE\VMware, Inc.\VMware Tools','HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Tools') {
  if (-not $vmtVer) {
    $r = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if ($r -and $r.ProductVersion) { $vmtVer = [string]$r.ProductVersion }
  }
}
$vmtExe = 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe'
if (-not $vmtVer -and (Test-Path $vmtExe)) { $vmtVer = (Get-Item $vmtExe).VersionInfo.FileVersion }
$vmtSvc = Get-Service VMTools -ErrorAction SilentlyContinue
if ($vmtVer -or $vmtSvc) {
  I 'vmware tools' (('version ' + $(if ($vmtVer) { $vmtVer } else { 'unknown' })) +
                    ', service ' + $(if ($vmtSvc) { $vmtSvc.Status.ToString() + '/' + $vmtSvc.StartType } else { 'not present' }))
} else { I 'vmware tools' 'not installed' }

$gaSvc = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
if (-not $gaSvc) { $gaSvc = Get-Service -Name 'qemu-ga' -ErrorAction SilentlyContinue }
$gaVer = ''
foreach ($e in 'C:\Program Files\Qemu-ga\qemu-ga.exe','C:\Program Files (x86)\Qemu-ga\qemu-ga.exe') {
  if (-not $gaVer -and (Test-Path $e)) { $gaVer = (Get-Item $e).VersionInfo.FileVersion }
}
if ($gaSvc -or $gaVer) {
  I 'qemu guest agent' (('version ' + $(if ($gaVer) { $gaVer } else { 'unknown' })) +
                        ', service ' + $(if ($gaSvc) { $gaSvc.Status.ToString() + '/' + $gaSvc.StartType } else { 'not present' }))
} else { I 'qemu guest agent' 'not installed' }

# The driver FILES are the truth. A virtio package can be "installed" in Programs and
# Features while the driver bound to the disk is an older one, and it is the bound
# driver that decides whether this image boots on KVM.
$vio = @()
foreach ($d in 'viostor','vioscsi','netkvm','balloon','vioser','viorng','vioinput') {
  $f = Join-Path $env:SystemRoot ('System32\drivers\' + $d + '.sys')
  if (Test-Path $f) { $vio += ($d + ' ' + (Get-Item $f).VersionInfo.FileVersion) }
}
if ($vio.Count) { I 'virtio drivers' (($vio -join ' | ')) } else { I 'virtio drivers' 'none present (normal on ESXi)' }
$vt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -like '*Virtio-win*' -or $_.DisplayName -like '*virtio*guest*tools*' } |
      Select-Object -First 1
if ($vt) { I 'virtio guest tools' ($vt.DisplayName + ' ' + $vt.DisplayVersion) } else { I 'virtio guest tools' 'not installed' }

# ---- THE FIVE KNOWN DEPLOYMENT FIXES, GATED --------------------------------------
# These are the recurring issues every template generation has shipped with. They are
# checked HERE, at seal time, because "the user data will handle it" is what let four of
# the five survive into the v264 images: user data is per-deploy and per-cloud, so a VM
# built without exactly the right user data got none of them. An image that cannot pass
# these five does not get sealed.
V 'fix1 tls (2016 only)' ($build -gt 14393 -or ($sc -eq 1 -and (Get-ItemProperty $schK -Name Enabled -ErrorAction SilentlyContinue).Enabled -eq 1)) $(if ($build -gt 14393) { 'n/a above 2016' } else { 'NET+SCHANNEL both set' })
V 'fix2 lockout = 0' ((Get-YcLockoutThreshold) -eq '0') ('threshold ' + (Get-YcLockoutThreshold))
V 'fix2 enforced at boot' ((Select-String -Path (Join-Path $S 'yc-boot.ps1') -Pattern 'lockoutthreshold' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) 'yc-boot.ps1'
V 'fix3 fix-gateway shipped' (Test-Path (Join-Path $S 'fix-gateway.cmd')) 'fix-gateway.cmd'
V 'fix3 run at boot' ((Select-String -Path (Join-Path $S 'yc-boot.ps1') -Pattern 'fix-gateway' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) 'yc-boot.ps1'
V 'fix4 focus at firstboot' ((Select-String -Path (Join-Path $S 'yc-firstboot.ps1') -Pattern 'SelectedUserSID' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) 'yc-firstboot.ps1'
V 'fix5 Update-YcScripts' (Test-Path (Join-Path $S 'Update-YcScripts.ps1')) 'baked in, required by the sync step'
V 'fix5 payload is current' ($script:payloadCurrent) $script:payloadNote

$yc = Get-Command yallacloud -ErrorAction SilentlyContinue
V 'yallacloud runs' ([bool]$yc) $(if ($yc) { $yc.Source } else { 'not resolvable' })

# yc-check never exits non-zero - it prints '==== N checks, M FAIL ===='. Read the M.
$chk = Join-Path $S 'yc-check.ps1'
if (Test-Path $chk) {
  # -Template: hostname and qemu-ga are DEPLOYMENT checks and cannot pass on a golden image.
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $chk -Template 2>&1
  $out | ForEach-Object { Add-Content -Path $Log -Value ('    yc-check: ' + $_) -Encoding ascii }
  $sum = @($out | Where-Object { $_ -match '==== .* FAIL' }) | Select-Object -Last 1
  $n = 99
  if ($sum -match '(\d+)\s+FAIL') { $n = [int]$Matches[1] }
  V 'yc-check' ($n -eq 0) ([string]$sum)
} elseif ($Report) {
  L '7 verify   : yc-check               INFO absent - seal tooling, expected outside a template'
} else { V 'yc-check' $false 'yc-check.ps1 missing - the seal kit was not restored' }

L '7 verify   : ---------------------------------------------------------------'
if ($fail.Count) {
  L ('NOT READY TO SEAL - ' + $fail.Count + ' problem(s): ' + ($fail -join ', ')) 'ERROR'
  End-YcPreseal 'FAILED' 1
}
L 'READY TO SEAL. Reboot once, then run the seal sequence.' 'OK'
End-YcPreseal 'READY' 0
