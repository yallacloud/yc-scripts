# =============================================================
# Activate-Windows.ps1  v2.3  (2026-08-29)
# YALLACLOUD - show licence state -> activate Windows Server (Eval->Volume or
# MAK/KMS) -> show licence state again (+ optional GLPI inventory push).
#
# WHAT CHANGED IN v2.1 (and WHY) - three real defects found on the x/C fleet:
#   A. DISM /Set-Edition WAS GIVEN THE WRONG KIND OF KEY (this is the big one).
#      v2.0 passed -ProductKey straight into
#          dism /online /Set-Edition:<ed> /ProductKey:<-ProductKey>
#      but /Set-Edition only accepts the PUBLIC GVLK (KMS client setup key) for
#      the target edition. Hand it a MAK or a retail key and it fails with
#          Error: 0x8a010101
#          The specified product key could not be validated.
#      which reads like "your key is bad" and is not - DISM is refusing a
#      non-GVLK. Observed on x19B (Server 2019 Standard Evaluation): the edition
#      change never happened, the script exited 2, and the VM stayed Evaluation.
#      FIX: the published GVLK for the detected build + target edition is used
#      for the edition change, and the operator's real key is installed after
#      the reboot with slmgr /ipk - which is Microsoft's documented order. If
#      DISM still returns 0x8a010101 the log now names the expected GVLK instead
#      of blaming the key.
#   B. THE POST-REBOOT ACTIVATION NEVER RAN ON HEADLESS VMs.
#      v2.0 staged it in HKLM\...\RunOnce. RunOnce only fires at the next
#      INTERACTIVE LOGON. These servers are deployed headless from userdata, so
#      nobody ever logged in and the staged /ato simply never happened - the VM
#      sat in Evaluation looking like the script had failed silently.
#      FIX: a startup SCHEDULED TASK running as SYSTEM (fires on boot, no logon
#      needed, 3 minute delay so the network and sppsvc are up). The task
#      re-runs THIS script, so the post-reboot attempt gets the same key
#      handling, the same store repair and the same verification as a manual
#      run - and the script deletes the task itself once the licence verifies.
#      Any leftover v2.0 RunOnce value is removed on the way past.
#   C. 0xC004D302 WAS REPORTED AS "check the key and the network".
#      0xC004D302 = "the Security processor reported that the trusted data store
#      was rearmed". It is the Software Protection Platform token store that is
#      refusing, not the key, not the edition and not connectivity - so the old
#      advice sent the operator to look in three places that were all fine.
#      FIX: the error is detected in the slmgr output, the token store is
#      rebuilt (sppsvc stopped, tokens.dat/cache.dat MOVED to a timestamped
#      .bak - never deleted - sppsvc started, slmgr /rilc), and the activation
#      is retried once. If it still fails the script stages the retry, logs the
#      remaining Windows rearm count, exits with the new code 4, and says
#      plainly that a template shipping a rearmed store cannot be fixed from
#      inside the guest.
#   D. THE EDITION COULD NEVER BE AUTO-DERIVED (found by the fleet log sweep on
#      x16E, x16B, C25B and C22B, all of which logged
#          Could not derive a valid target edition from " ServerStandardEval"
#      and forced the operator to pass -Edition by hand every time).
#      dism /online /Get-CurrentEdition prints TWO lines containing the words
#      "current edition":
#          Current edition is:
#          Current Edition : ServerStandardEval
#      Select-String 'Current Edition' is case-insensitive, so it matched both,
#      and $cur became a two-element ARRAY whose first element is the empty
#      string. "$cur" then joins it with a space - which is where the phantom
#      leading space came from. It was never a whitespace bug, so the .Trim()
#      that was already there could not have helped. The leading space failed
#      ^[A-Za-z][A-Za-z0-9]{1,31}$ and the run died at exit 1.
#      FIX: Get-YcEditionFromDism, a pure function that takes the dism lines and
#      returns the FIRST value that actually follows "Current Edition :", so the
#      header line cannot match and the result is always a single trimmed string.
#   E. THE REARM COUNT READ AS -1 ON EXACTLY THE VMs THAT NEEDED IT.
#      RemainingWindowsReArmCount is a uint32. A healthy image returns a small
#      number (C19E/C19B return 6). A damaged licensing store returns
#      0xFFFFFFFF = 4294967295, and casting that to [int] THROWS - so the catch
#      swallowed it and reported -1 on every broken VM, hiding the one number
#      that says whether the image is salvageable. Read as [int64] and the
#      sentinel is now shown for what it is.
#
# DEFAULTS CHANGED IN v2.3 (operator request - both were friction, not safety):
#   -Edition now defaults to ServerStandard. The whole fleet is Standard and
#   nobody should have to type it. The one exception: on a DATACENTER evaluation
#   image, forcing Standard would fail at dism with a misleading "not a valid
#   target edition", so the image's own edition wins and the log says so.
#   GLPI is now OFF by default. It used to prompt interactively and skip when
#   unattended; the prompt could block a first-boot run. Pass -GlpiUpdate to
#   push an inventory. -NoGlpi is still accepted so existing userdata and .cmd
#   calls keep working, it is simply the default now.
#   So this is enough:
#       activate-windows -ProductKey XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
#
# CARRIED OVER FROM v2.0
#   P0-3 command injection is still closed: no Invoke-Expression anywhere,
#   slmgr.vbs is invoked with the call operator and an argument ARRAY, and
#   -ProductKey / -KMS / -Edition are validated against strict regexes before
#   any of them is used.
#
# NOTE ON THE PRODUCT KEY - CHANGED IN v2.1, READ THIS.
#   v2.0 promised the key was never persisted. v2.1 breaks that promise on
#   purpose: the staged startup task carries -ProductKey so that an unattended
#   first-boot deployment can actually finish activating without a human. The
#   key therefore sits in C:\Windows\System32\Tasks\YcActivateWindows until the
#   task is removed, readable by SYSTEM and Administrators - the same principals
#   that can already read the userdata and C:\Scripts. The task is deleted as
#   soon as the licence verifies. Injection is still impossible: -ProductKey has
#   passed ^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$ before it is used, so it cannot carry
#   a shell metacharacter. The key is still never written to the log or the
#   event log - only the masked last 5 characters are.
#
# PowerShell 5.1 only. ASCII only. Windows Server 2012 R2 - 2025. Idempotent.
# =============================================================
param([string]$ProductKey,[string]$Edition,[string]$KMS,[switch]$GlpiUpdate,[switch]$NoGlpi,[switch]$Help)
. 'C:\Scripts\_yc-lib.ps1'
Start-YcLog 'activate-windows'
$ErrorActionPreference='Continue'
if($Help -or -not $ProductKey){
@"
activate-windows  -  show state -> activate Windows Server (Eval->Volume or MAK/KMS) -> show state (+optional GLPI).
SUPPORTS: Windows Server 2012 R2 / 2016 / 2019 / 2022 / 2025 - Standard / Datacenter.
USAGE:
  activate-windows -ProductKey <GVLK-or-MAK> [-Edition ServerStandard|ServerDatacenter] [-KMS <host[:port]>]
                   [-GlpiUpdate]
  activate-windows -Help
FLOW: prints FULL current state (OS, edition, Evaluation vs full, activated/not, channel: Volume/KMS/MAK/Retail/OEM),
      then activates, then prints the FULL state again AND VERIFIES the licence actually took. If a GLPI agent is
      installed+configured, -GlpiUpdate pushes a fresh inventory. GLPI is SKIPPED by default - it is never
      prompted for, so an unattended first-boot run can never block on it.
PARAMETERS:
  -ProductKey  KMS client GVLK or MAK (required). Must be 5 groups of 5 A-Z/0-9 separated by hyphens.
  -Edition     target edition. DEFAULTS TO ServerStandard (ServerDatacenter on a Datacenter
               evaluation image). Letters and digits only.
  -KMS         optional KMS host[:port]  (hostname or IPv4, optional :port 1-65535).
  -GlpiUpdate  push a GLPI inventory. GLPI is OFF by default.
  -NoGlpi      accepted for compatibility; GLPI is already off by default.
  -Help        show this help and exit.
EVALUATION IMAGES: the edition change is done with the PUBLISHED GVLK for this build (dism /Set-Edition refuses a
      MAK or retail key with 0x8a010101), it is ONE WAY, and it needs a REBOOT. A startup scheduled task running as
      SYSTEM re-runs this script after that reboot and installs -ProductKey for real; this run exits 3 to say so.
      HKLM RunOnce is NOT used - it only fires at an interactive logon, which never happens on a headless VM.
0xC004D302: the trusted licensing store was rearmed. The script rebuilds the store (tokens.dat and cache.dat are
      MOVED to a .bak, never deleted) and retries once. If it still fails the store came that way in the template.
SECURITY: -ProductKey / -KMS / -Edition are strictly validated. Values containing shell metacharacters are
      REJECTED, not executed. Only the last 5 characters of the key are ever logged. The staged startup task does
      carry -ProductKey so unattended deployments can finish; it is deleted as soon as the licence verifies.
EXIT CODES:
  0  Windows is Licensed (SoftwareLicensingProduct LicenseStatus = 1)
  1  bad or missing -ProductKey / -KMS / -Edition, or help
  2  activation was attempted but the licence status is still not Licensed
  3  Evaluation edition change staged - REBOOT required, activation runs then
  4  0xC004D302: the trusted licensing store is rearmed and survived a rebuild
  5  not elevated (see _yc-lib.ps1 preflight)
Log: C:\Scripts\activate-windows.log
"@ | Write-Host -ForegroundColor Cyan; if($Help){ Stop-YcLog 0; exit 0 } else { Stop-YcLog 1; exit 1 }
}
Assert-YcPrereqs -NeedAdmin

# =============================================================
# INPUT VALIDATION (P0-3). Nothing below this block may contain a shell
# metacharacter, so nothing tenant-supplied can alter a command line.
# =============================================================
$ProductKey = $ProductKey.Trim().ToUpperInvariant()
if($ProductKey -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$'){
  Write-YcLog 'Invalid -ProductKey. Expected 5 groups of 5 characters (A-Z, 0-9) separated by hyphens, e.g. XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.' 'ERROR'
  Stop-YcLog 1; exit 1
}

if($KMS){
  $KMS = $KMS.Trim()
  $kmsHostRe = '^[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*(:[0-9]{1,5})?$'
  $kmsPortRe = '^:[0-9]{1,5}$'
  if(($KMS -notmatch $kmsHostRe) -and ($KMS -notmatch $kmsPortRe)){
    Write-YcLog ('Invalid -KMS value. Expected host[:port] (hostname or IPv4, optional port), got: ' + $KMS) 'ERROR'
    Stop-YcLog 1; exit 1
  }
  if($KMS -match ':([0-9]{1,5})$'){
    $kmsPort = [int]$Matches[1]
    if($kmsPort -lt 1 -or $kmsPort -gt 65535){
      Write-YcLog ('Invalid -KMS port (must be 1-65535): ' + $KMS) 'ERROR'
      Stop-YcLog 1; exit 1
    }
  }
}

if($Edition){
  $Edition = $Edition.Trim()
  if($Edition -notmatch '^[A-Za-z][A-Za-z0-9]{1,31}$'){
    Write-YcLog ('Invalid -Edition. Letters and digits only, e.g. ServerStandard or ServerDatacenter. Got: ' + $Edition) 'ERROR'
    Stop-YcLog 1; exit 1
  }
}

$SlmgrPath = Join-Path $env:WINDIR 'System32\slmgr.vbs'
if(-not (Test-Path $SlmgrPath)){
  Write-YcLog ('slmgr.vbs not found at ' + $SlmgrPath) 'ERROR'
  Stop-YcLog 1; exit 1
}
# ApplicationID of the Windows operating system SKUs in SoftwareLicensingProduct.
$WinAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
$YcTaskName = 'YcActivateWindows'

# Published KMS client setup keys (GVLKs). These are PUBLIC values from
# Microsoft's own documentation, not secrets:
#   https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys
# They are here for exactly one reason: dism /online /Set-Edition accepts ONLY
# the GVLK for the target edition. Keyed on build number because the caption
# string is localised and the marketing name is not in the registry.
function Get-YcGvlk{
  param([string]$TargetEdition)
  $b = 0
  try{ $b = [int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber }catch{ $b = [int][Environment]::OSVersion.Version.Build }
  $std = ''; $dc = ''
  if($b -ge 26100){      $std='TVRH6-WHNXV-R9WG3-9XRFY-MY832'; $dc='D764K-2NDRG-47T6Q-P8T8W-YP6DF' } # Server 2025
  elseif($b -ge 20348){  $std='VDYBN-27WPP-V4HQT-9VMD4-VMK7H'; $dc='WX4NM-KYWYW-QJJR4-XV3QB-6VM33' } # Server 2022
  elseif($b -ge 17763){  $std='N69G4-B89J2-4G8F4-WWYCC-J464C'; $dc='WMDGN-G9PQG-XVVXX-R3X43-63DFG' } # Server 2019
  elseif($b -ge 14393){  $std='WC2BQ-8NRM3-FDDYY-2BFGV-KHKQY'; $dc='CB7KF-BWN84-R7R2Y-793K2-8XDDG' } # Server 2016
  elseif($b -ge 9600){   $std='D2N9P-3P6X9-2R39C-7RTCD-MDVJX'; $dc='W3GGN-FT8W3-Y4M27-J84CP-Q3VJ9' } # Server 2012 R2
  else { return '' }
  if("$TargetEdition" -match 'Datacenter'){ return $dc }
  if("$TargetEdition" -match 'Standard'){ return $std }
  return ''
}

# Invoke slmgr.vbs with the CALL OPERATOR and an argument ARRAY - no shell, no
# string concatenation, nothing to inject into. Replaces the removed iex calls.
# Returns the COMBINED OUTPUT TEXT, not the exit code: slmgr.vbs does not set a
# meaningful exit code, so reading what it printed is the only way to see WHICH
# error happened (see Test-YcRearmError).
function Invoke-YcSlmgr{
  param([string[]]$SlmgrArgs,[string]$What)
  $global:LASTEXITCODE = 0
  $out = & cscript //nologo $SlmgrPath @SlmgrArgs 2>&1
  $txt = (($out | Out-String).Trim())
  if($txt){ Write-YcLog ($What + ': ' + ($txt -replace '\s+',' ')) }
  return $txt
}

# 0xC004D302 - "the Security processor reported that the trusted data store was
# rearmed". The token store is refusing; the key, the edition and the network
# are all irrelevant to this one.
function Test-YcRearmError{
  param([string]$Text)
  return ("$Text" -match 'C004D302')
}

# Rebuild the Software Protection Platform token store so sppsvc recreates it.
# Files are MOVED to a timestamped .bak, NEVER deleted, so a bad outcome can be
# put back by hand. Returns $true only if something was actually moved.
function Repair-YcSppStore{
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $files = @()
  $files += Get-ChildItem -Path (Join-Path $env:WINDIR 'System32\spp') -Recurse -Force -Include 'tokens.dat','cache.dat' -ErrorAction SilentlyContinue
  $files += Get-ChildItem -Path (Join-Path $env:WINDIR 'ServiceProfiles\NetworkService\AppData\Roaming\Microsoft\SoftwareProtectionPlatform') -Recurse -Force -Include 'tokens.dat','cache.dat' -ErrorAction SilentlyContinue
  if(-not $files -or $files.Count -eq 0){
    Write-YcLog 'Store repair: no tokens.dat / cache.dat found - nothing to rebuild.' 'WARN'
    return $false
  }
  Write-YcLog 'Store repair: stopping sppsvc...' 'INFO'
  try{ Stop-Service -Name 'sppsvc' -Force -ErrorAction Stop }catch{ Write-YcLog ('Store repair: could not stop sppsvc - ' + $_.Exception.Message) 'WARN' }
  Start-Sleep 3
  $moved = 0
  foreach($f in $files){
    $bak = $f.FullName + '.bak-' + $stamp
    try{
      Move-Item -LiteralPath $f.FullName -Destination $bak -Force -ErrorAction Stop
      Write-YcLog ('Store repair: moved ' + $f.FullName + ' -> ' + $bak) 'INFO'
      $moved++
    }catch{
      Write-YcLog ('Store repair: could NOT move ' + $f.FullName + ' - ' + $_.Exception.Message) 'WARN'
    }
  }
  try{ Start-Service -Name 'sppsvc' -ErrorAction Stop }catch{ Write-YcLog ('Store repair: could not start sppsvc - ' + $_.Exception.Message) 'ERROR' }
  Start-Sleep 5
  if($moved -lt 1){
    Write-YcLog 'Store repair: nothing could be moved (files locked?) - store NOT rebuilt.' 'ERROR'
    return $false
  }
  Invoke-YcSlmgr -SlmgrArgs @('/rilc') -What 'slmgr /rilc' | Out-Null
  Start-Sleep 5
  Write-YcLog ('Store repair: token store rebuilt (' + $moved + ' file(s) moved aside).') 'OK'
  return $true
}

# Stage the post-reboot attempt. v2.0 used HKLM RunOnce, which only fires at an
# interactive logon - on a headless VM that is never. A startup scheduled task
# running as SYSTEM fires on boot with no logon. It re-runs THIS script so the
# retry gets the same key handling, store repair and verification as a manual
# run. See the NOTE ON THE PRODUCT KEY in the header: the key is in the task
# definition until the task is removed.
function Set-YcPostRebootActivation{
  # -Proven is mandatory and is the whole point: a retry task is an artefact that
  # makes a machine LOOK handled. Staging one on a path that has not established
  # the retry can succeed leaves a VM nobody looks at again. Every caller must
  # state, at the call site, that it checked. Verified on X19B 2026-08-29, where
  # the task was staged one second before a hard failure.
  param([Parameter(Mandatory=$true)][bool]$Proven)

  if(-not $Proven){
    Write-YcLog 'Refusing to stage the post-reboot retry: the caller did not establish that a retry can succeed.' 'ERROR'
    return $false
  }

  $self = $PSCommandPath
  if(-not $self){ $self = 'C:\Scripts\Activate-Windows.ps1' }
  # Every value appended below has already passed a strict regex, so none of
  # them can carry a shell metacharacter.
  $a = '-NoProfile -ExecutionPolicy Bypass -File "' + $self + '" -ProductKey ' + $ProductKey + ' -NoGlpi'
  if($Edition){ $a = $a + ' -Edition ' + $Edition }
  if($KMS){ $a = $a + ' -KMS ' + $KMS }

  # Is one already staged? Re-running activate-windows by hand is normal, and a
  # -Force re-register silently resets the trigger. Knowing the prior state also
  # means the log says "replaced" rather than implying a first-time staging.
  $prior = $null
  try{ $prior = Get-ScheduledTask -TaskName $YcTaskName -ErrorAction SilentlyContinue }catch{}
  if($prior){ Write-YcLog ('A task named "' + $YcTaskName + '" is already staged; it will be replaced.') 'INFO' }

  try{
    $ps  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $act = New-ScheduledTaskAction -Execute $ps -Argument $a
    $trg = New-ScheduledTaskTrigger -AtStartup
    try{ $trg.Delay = 'PT3M' }catch{}   # let the network and sppsvc settle first
    $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $YcTaskName -Action $act -Trigger $trg -Principal $pri -Force -ErrorAction Stop | Out-Null
  }catch{
    Write-YcLog ('Could not register the post-reboot activation task: ' + $_.Exception.Message) 'ERROR'
    return $false
  }

  # Prove the side effect actually landed. Register-ScheduledTask can return
  # without throwing and still leave nothing usable behind on a locked-down image;
  # reporting "staged" in that case is the same lie this guard exists to prevent.
  $check = $null
  try{ $check = Get-ScheduledTask -TaskName $YcTaskName -ErrorAction SilentlyContinue }catch{}
  if(-not $check){
    Write-YcLog ('Register-ScheduledTask reported success but no task named "' + $YcTaskName + '" exists. Nothing was staged.') 'ERROR'
    return $false
  }
  Write-YcLog ('Post-reboot activation staged as scheduled task "' + $YcTaskName + '" (at startup, as SYSTEM, 3 min delay), existence confirmed.') 'OK'
  return $true
}
function Remove-YcPostRebootActivation{
  try{ Unregister-ScheduledTask -TaskName $YcTaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }catch{}
  # Clear the v2.0 RunOnce value too, so a VM updated from v2.0 does not fire twice.
  try{ Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ActivateWindows' -Force -ErrorAction SilentlyContinue }catch{}
}

# Pull the current edition out of dism /online /Get-CurrentEdition output.
# Pure (takes the lines, touches nothing) so it can be unit tested, and it must
# stay that way: the bug it replaces was invisible until someone looked at the
# actual bytes on a guest. Only a line with a NON-EMPTY value after
# "Current Edition :" counts, which excludes the "Current edition is:" header
# that the old Select-String pattern also matched.
function Get-YcEditionFromDism{
  param([string[]]$Lines)
  foreach($l in @($Lines)){
    if("$l" -match 'Current\s+Edition\s*:\s*(\S.*)$'){ return $Matches[1].Trim() }
  }
  return ''
}

# Which edition to convert TO. Pure so it can be unit tested.
# Default is ServerStandard: the fleet is Standard and typing -Edition every
# time was pure friction. A Datacenter evaluation image is the one case where
# that default is wrong - dism would reject ServerStandard as "not a valid
# target edition" - so the image's own edition wins there.
function Get-YcTargetEdition{
  param([string]$Supplied,[string]$CurrentEdition)
  if($Supplied){ return $Supplied.Trim() }
  if("$CurrentEdition" -match 'Datacenter'){ return 'ServerDatacenter' }
  return 'ServerStandard'
}

function Get-YcLicenseProduct{
  return (Get-CimInstance SoftwareLicensingProduct -Filter ("ApplicationID='" + $WinAppId + "' AND PartialProductKey IS NOT NULL") -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# uint32. Healthy images return a small count; a damaged licensing store returns
# 0xFFFFFFFF (4294967295), which does NOT fit in [int] - the old [int] cast threw
# and the catch reported -1, hiding the sentinel on exactly the broken VMs.
function Get-YcReArmLeft{
  try{ return [int64](Get-CimInstance SoftwareLicensingService -ErrorAction Stop).RemainingWindowsReArmCount }catch{ return -1 }
}
# 0xFFFFFFFF is the all-bits-set sentinel on a uint32 property: the store is not
# readable, i.e. the image shipped damaged. It is NOT a count, and no reboot
# changes it - which is the whole reason Test-YcStoreRepairable exists.
function Test-YcStoreRepairable{
  param([int64]$N)
  return ($N -ne 4294967295 -and $N -ge 0)
}
function Format-YcReArm{
  param([int64]$N)
  if($N -eq 4294967295){ return '4294967295 (0xFFFFFFFF - licensing store is NOT readable, this image is damaged)' }
  if($N -lt 0){ return 'unreadable (SoftwareLicensingService did not answer)' }
  return "$N"
}

# LicenseStatus values (SoftwareLicensingProduct):
#   0 Unlicensed  1 Licensed  2 OOBGrace  3 OOTGrace  4 NonGenuineGrace
#   5 Notification  6 ExtendedGrace
# Only 1 means "activated". Poll briefly: /ato returns before the licence
# state has settled.
function Test-YcActivated{
  param([int]$TimeoutSec = 40)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  do{
    $lic = Get-YcLicenseProduct
    if($lic -and ([int]$lic.LicenseStatus -eq 1)){ return $true }
    Start-Sleep -Seconds 3
  } while((Get-Date) -lt $deadline)
  return $false
}

function Get-WinState {
  $os = Get-CimInstance Win32_OperatingSystem
  $cur = Get-YcEditionFromDism (((dism /online /Get-CurrentEdition) 2>$null) | Out-String -Stream)
  $lic = Get-YcLicenseProduct
  $st=@{0='Unlicensed';1='Licensed (activated)';2='OOB-Grace';3='OOT-Grace';4='Non-Genuine-Grace';5='Notification (not activated)';6='Extended-Grace'}
  $desc = if($lic){ "$($lic.Description)" } else { '' }
  $chan = 'Unknown'
  if($desc -match 'VOLUME_KMSCLIENT'){ $chan='Volume (KMS client)' }
  elseif($desc -match 'VOLUME_MAK'){ $chan='Volume (MAK)' }
  elseif($desc -match 'TIMEBASED|EVAL'){ $chan='Evaluation (time-based)' }
  elseif($desc -match 'RETAIL'){ $chan='Retail' }
  elseif($desc -match 'OEM'){ $chan='OEM' }
  $isEval = ("$cur" -match 'Eval') -or ($os.Caption -match 'Evaluation') -or ($desc -match 'EVAL|TIMEBASED')
  [pscustomobject]@{
    OS=$os.Caption; Version=$os.Version; Build=$os.BuildNumber; Edition=$cur; Evaluation=$isEval;
    LicenseStatus=$(if($lic){$st[[int]$lic.LicenseStatus]}else{'Unknown'});
    Channel=$chan; PartialKey=$(if($lic){$lic.PartialProductKey}else{'(none)'});
    GraceDays=$(if($lic){[int]($lic.GracePeriodRemaining/1440)}else{0});
    ReArmLeft=(Get-YcReArmLeft)
  }
}
function Show-WinState([string]$when){
  $s=Get-WinState
  Write-Host ("==== Windows license state ("+$when+") ====") -ForegroundColor Cyan
  Write-Host ("  OS           : "+$s.OS+"  ("+$s.Version+" build "+$s.Build+")")
  Write-Host ("  Edition      : "+$s.Edition+"   Evaluation: "+$s.Evaluation)
  Write-Host ("  License      : "+$s.LicenseStatus)
  Write-Host ("  Channel      : "+$s.Channel)
  Write-Host ("  PartialKey   : "+$s.PartialKey+"   GraceDays: "+$s.GraceDays)
  Write-Host ("  ReArmLeft    : "+(Format-YcReArm $s.ReArmLeft))
  Write-YcLog ("state("+$when+"): build="+$s.Build+" edition="+$s.Edition+" eval="+$s.Evaluation+" license="+$s.LicenseStatus+" channel="+$s.Channel+" rearmleft="+(Format-YcReArm $s.ReArmLeft))
}
function Invoke-GlpiInventory {
  $dir='C:\Program Files\GLPI-Agent'
  $svc=Get-Service -Name 'glpi-agent','GLPI-Agent' -EA SilentlyContinue | Select-Object -First 1
  if(-not $svc -and -not (Test-Path $dir)){ Write-YcLog 'GLPI agent not installed - inventory skipped.' 'INFO'; return }
  $configured=$false
  $reg=Get-ItemProperty 'HKLM:\SOFTWARE\GLPI-Agent\Agent' -EA SilentlyContinue
  if($reg -and $reg.server){ $configured=$true }
  if(-not $configured){ if(Get-ChildItem "$dir\etc" -Recurse -File -EA SilentlyContinue | Select-String -Pattern 'server' -EA SilentlyContinue){ $configured=$true } }
  if(-not $configured){ Write-YcLog 'GLPI agent installed but no server configured - inventory skipped.' 'INFO'; return }
  Write-YcLog 'Triggering GLPI inventory (--force)...' 'INFO'
  $exe=Get-ChildItem $dir -Recurse -Filter 'glpi-agent.exe' -EA SilentlyContinue | Select-Object -First 1
  if($exe){ & $exe.FullName --force 2>&1 | Out-Null } else { try{ Restart-Service $svc.Name -EA SilentlyContinue }catch{} }
  Write-YcLog 'GLPI inventory triggered.' 'OK'
}
# GLPI is OFF unless asked for. It used to prompt when interactive, which could
# block a first-boot run forever; -NoGlpi still works but is now redundant.
function Maybe-Glpi {
  if($GlpiUpdate -and (-not $NoGlpi)){ Invoke-GlpiInventory; return }
  Write-YcLog 'GLPI: skipped (off by default). Pass -GlpiUpdate to push an inventory.' 'INFO'
}

$km = if($ProductKey.Length -gt 5){ ('*'*($ProductKey.Length-5))+$ProductKey.Substring($ProductKey.Length-5) } else { '*****' }
Show-WinState 'BEFORE'
Write-Host ("  Using key    : "+$km) -ForegroundColor DarkGray
Write-YcLog ('Using product key ' + $km)

# Already Licensed and no edition change pending: nothing to do (idempotent).
$before = Get-WinState
if((-not $before.Evaluation) -and (Get-YcLicenseProduct) -and ([int](Get-YcLicenseProduct).LicenseStatus -eq 1) -and (-not $KMS)){
  Write-YcLog 'Windows is already Licensed - nothing to do (idempotent).' 'OK'
  Remove-YcPostRebootActivation
  Show-WinState 'AFTER'
  Maybe-Glpi
  Stop-YcLog 0
  exit 0
}

$cur = $before.Edition
if("$cur" -match 'Eval'){
  # ---------- Evaluation -> full edition (ONE WAY, needs a reboot) ----------
  $picked = Get-YcTargetEdition $Edition $cur
  if(-not $Edition){ Write-YcLog ('No -Edition given - defaulting to ' + $picked + ' (current edition: ' + $cur + ').') 'INFO' }
  $Edition = $picked
  if($Edition -notmatch '^[A-Za-z][A-Za-z0-9]{1,31}$'){
    Write-YcLog ('Could not derive a valid target edition from "' + $cur + '". Pass -Edition explicitly.') 'ERROR'
    Stop-YcLog 1; exit 1
  }
  Write-YcLog ('Evaluation detected - converting to ' + $Edition + ' (reboot required to finish)...') 'WARN'

  # DEFECT A. dism /Set-Edition takes the PUBLISHED GVLK for the target edition
  # and nothing else. v2.0 handed it -ProductKey, so any deployment using a MAK
  # died here with 0x8a010101. Use the GVLK for the conversion; the operator's
  # real key goes in afterwards with /ipk, which is Microsoft's documented order.
  $gvlk   = Get-YcGvlk $Edition
  $setKey = $ProductKey
  if($gvlk){
    $setKey = $gvlk
    if($gvlk -ne $ProductKey){
      Write-YcLog ('Edition change will use the published GVLK for ' + $Edition + '; -ProductKey ' + $km + ' is installed with /ipk after the reboot.') 'INFO'
    }
  } else {
    Write-YcLog ('No published GVLK is known for build ' + $before.Build + ' - falling back to -ProductKey for the edition change. If this fails with 0x8a010101 the key is not a GVLK.') 'WARN'
  }

  # Apply the KMS host NOW. It persists in HKLM SoftwareProtectionPlatform
  # across the reboot.
  if($KMS){ Invoke-YcSlmgr -SlmgrArgs @('/skms',$KMS) -What 'slmgr /skms' | Out-Null }

  $dismOut = (dism /online /Set-Edition:$Edition /ProductKey:$setKey /AcceptEula /NoRestart 2>&1 | Out-String)
  $dismRc  = $LASTEXITCODE
  Write-Host $dismOut
  if(($dismRc -ne 0) -and ($dismRc -ne 3010)){
    if($dismOut -match '0x8a010101'){
      $expect = if($gvlk){ $gvlk } else { '(no published GVLK known for build ' + $before.Build + ')' }
      Write-YcLog ('dism /Set-Edition returned 0x8a010101. That error means DISM refused the KEY TYPE, not that the key is dead: /Set-Edition only accepts the published GVLK for the target edition. Expected GVLK for ' + $Edition + ': ' + $expect + '. Also confirm ' + $Edition + ' is a valid target for this OS (dism /online /Get-TargetEditions).') 'ERROR'
    } else {
      Write-YcLog ('dism /Set-Edition failed with exit code ' + $dismRc + ' - edition NOT changed.') 'ERROR'
    }
    Show-WinState 'AFTER'
    Maybe-Glpi
    Stop-YcLog 2; exit 2
  }

  # DEFECT B. Staged as a startup task, not RunOnce - see the header.
  if(-not (Set-YcPostRebootActivation -Proven $true)){
    Show-WinState 'AFTER'
    Maybe-Glpi
    Stop-YcLog 2; exit 2
  }
  Write-YcLog 'Edition change staged - REBOOT to finish; activation runs automatically after the reboot.' 'WARN'

  Start-Sleep 3
  Show-WinState 'AFTER'
  Maybe-Glpi
  Write-YcLog 'Not activated yet by design - reboot required. Exiting 3.' 'WARN'
  Stop-YcLog 3; exit 3
}

# ---------- Normal path: install key, optionally point at KMS, activate ----------
# One helper so /ipk, /skms and /ato are always issued in the same order and the
# whole sequence can be replayed after a store rebuild without duplicating it.
function Invoke-YcActivateOnce{
  param([string]$Tag)
  $t = Invoke-YcSlmgr -SlmgrArgs @('/ipk',$ProductKey) -What ('slmgr /ipk' + $Tag)
  if($KMS){ $t = $t + "`n" + (Invoke-YcSlmgr -SlmgrArgs @('/skms',$KMS) -What ('slmgr /skms' + $Tag)) }
  $t = $t + "`n" + (Invoke-YcSlmgr -SlmgrArgs @('/ato') -What ('slmgr /ato' + $Tag))
  return $t
}

$res = Invoke-YcActivateOnce ''

# DEFECT C. 0xC004D302 is the token store, not the key and not the network.
# Rebuild it and replay the sequence exactly once - a second rebuild would only
# move the same files again.
if(Test-YcRearmError $res){
  Write-YcLog 'slmgr returned 0xC004D302 - the trusted licensing store is in a REARMED state. The key, the edition and network reachability are NOT the problem here. Rebuilding the store...' 'WARN'
  if(Repair-YcSppStore){
    $res = Invoke-YcActivateOnce ' (after store rebuild)'
  }
}

Start-Sleep 3
$activated = Test-YcActivated -TimeoutSec 40
Show-WinState 'AFTER'
Maybe-Glpi

if($activated){
  Remove-YcPostRebootActivation
  Write-YcLog 'Activation VERIFIED: SoftwareLicensingProduct LicenseStatus = 1 (Licensed).' 'OK'
  Stop-YcLog 0
  exit 0
}

if(Test-YcRearmError $res){
  # The rearm flag is only cleared by a boot, so stage the retry and be honest
  # that a template which ships a rearmed store cannot be repaired from inside.
  # Stage the retry ONLY when it can plausibly work. A boot normally clears the
  # rearm flag, so a startup task is worth leaving behind - but if the rearm
  # count reads 0xFFFFFFFF the store itself is unreadable and no number of
  # reboots will change that. Planting a retry task there leaves a machine that
  # LOOKS handled and never is, and a spot check would call it fixed. Verified
  # on X19B 2026-08-29: "Post-reboot activation staged ... OK" logged one second
  # before the hard failure.
  $rearmLeft = Get-YcReArmLeft
  if(Test-YcStoreRepairable $rearmLeft){
    if(Set-YcPostRebootActivation -Proven $true){
      Write-YcLog ('Retry staged as a startup task: the licensing store still reports ' + (Format-YcReArm $rearmLeft) + ', so a boot may clear the rearm flag.') 'WARN'
    }else{
      Write-YcLog 'Could not stage the post-reboot retry - run activate-windows by hand after the next boot.' 'ERROR'
    }
  }else{
    # Leave nothing behind that implies this is in hand.
    Remove-YcPostRebootActivation
    Write-YcLog 'NOT staging a retry task: the licensing store is unreadable, so rebooting cannot fix it. Any previously staged task has been removed so this VM is not left looking handled.' 'ERROR'
  }
  Write-YcLog ('STILL 0xC004D302 after rebuilding the token store. The rearm flag is only cleared by a BOOT: reboot this VM and the staged task will retry automatically (or run activate-windows again by hand with the same key). Remaining Windows rearm count: ' + (Format-YcReArm (Get-YcReArmLeft)) + '. If every VM built from the same template shows 0xC004D302, the TEMPLATE shipped a rearmed licensing store - no in-guest repair fixes that, the image has to be resealed (sysprep /generalize with SkipRearm handled correctly).') 'ERROR'
  Stop-YcLog 4
  exit 4
}

$lic = Get-YcLicenseProduct
$statusNum = 'no matching SoftwareLicensingProduct'
if($lic){ $statusNum = ('LicenseStatus=' + [int]$lic.LicenseStatus + ' LicenseStatusReason=' + $lic.LicenseStatusReason) }
Write-YcLog ('Activation DID NOT take (' + $statusNum + '). Check the key, the edition and KMS/internet reachability.') 'ERROR'
Stop-YcLog 2
exit 2
