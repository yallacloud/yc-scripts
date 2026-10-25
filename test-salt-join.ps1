# test-salt-join.ps1 - self-check for the SALT phase of Adopt-MigratedVm.ps1.
#
# The functions under test are SLICED OUT OF THE SHIPPED SCRIPT, so what is tested is what ships
# rather than a copy that can drift. It needs no Salt minion and no Salt master: the two helpers
# (Test-TcpReachable, Get-SaltMinionState) are overridden to stand for machines and networks this
# host is not, which is the only way the interesting branches are reachable at all.
#
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File .\test-salt-join.ps1
# It must end with '0 failed'. It changes nothing: no service is installed, started or stopped,
# and no join script is ever fetched.
param(
  [string]$Script     = 'C:\Scripts\Adopt-MigratedVm.ps1',
  [string]$PayloadDir = 'C:\Scripts'
)
if (-not (Test-Path -LiteralPath $Script)) {
  Write-Host ('cannot find the script under test: ' + $Script) -ForegroundColor Red
  Write-Host 'pass -Script <path to Adopt-MigratedVm.ps1>.'
  return
}
$ErrorActionPreference = 'Continue'
$src = Get-Content -LiteralPath $Script -Raw
function Grab([string]$n) {
  $i = $src.IndexOf('function ' + $n + ' {')
  if ($i -lt 0) { throw ('not found: ' + $n) }
  $j = $src.IndexOf("`nfunction ", $i + 10)
  if ($j -lt 0) { $j = $src.Length }
  return $src.Substring($i, $j - $i)
}

$pass = 0; $fail = 0
function T { param([string]$Name,[bool]$Ok,[string]$Got='')
  if ($Ok) { $script:pass++; Write-Host ('  PASS  ' + $Name + $(if($Got){'  -> '+$Got}else{''})) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ('  FAIL  ' + $Name + $(if($Got){'  -> '+$Got}else{''})) -ForegroundColor Red } }

# --- the stubs the phase leans on -------------------------------------------------------------
$script:Logged = New-Object System.Collections.Generic.List[string]
$script:Flags  = New-Object System.Collections.Generic.List[string]
function L    { param($m,$l='INFO') $script:Logged.Add('[' + $l + '] ' + [string]$m) | Out-Null }
function Flag { param($p,$w) $script:Flags.Add($p + ': ' + $w) | Out-Null }
$script:Evidence = @{}

# Invoke-Salt goes in as-is. The two helpers it calls go in TWICE: once under their own names,
# which the scenario stubs below then overwrite, and once renamed, so section 1 can still
# exercise the real code. A function defined in this script scope shadows a global one, so
# defining the stubs with "global:" does NOT work - that was the first version of this test, and
# it passed six checks that had never run the code they named.
Invoke-Expression (Grab 'Invoke-Salt')
Invoke-Expression ((Grab 'Test-TcpReachable')   -replace 'function Test-TcpReachable \{',   'function Real-TcpReachable {')
Invoke-Expression ((Grab 'Get-SaltMinionState') -replace 'function Get-SaltMinionState \{', 'function Real-SaltMinionState {')

$SaltMaster  = 'salt.example.invalid'
$SaltJoinUrl = 'https://repo.example.invalid/salt/join.ps1'
$SkipSalt    = $false

# A machine with no minion, and a network where nothing answers. These are the defaults every
# test below starts from; each test overrides only what it is about.
function Set-Scenario {
  param([bool]$Installed=$false,[string]$Status='absent',[string]$Master='',[string]$Svc='salt-minion',
        [bool]$P4505=$false,[bool]$P4506=$false,[bool]$Repo=$false)
  $script:scInstalled=$Installed; $script:scStatus=$Status; $script:scMaster=$Master; $script:scSvc=$Svc
  $script:scP4505=$P4505; $script:scP4506=$P4506; $script:scRepo=$Repo
  function script:Get-SaltMinionState {
    [ordered]@{ installed=$script:scInstalled; service=$(if($script:scInstalled){$script:scSvc}else{''})
                status=$script:scStatus; startType='Auto'
                running=($script:scStatus -eq 'Running'); version='3007.1'; minionId='testbox'
                configuredMaster=$script:scMaster }
  }
  function script:Test-TcpReachable {
    param([string]$HostName,[int]$Port,[int]$TimeoutMs=6000)
    if ($Port -eq 4505) { return $script:scP4505 }
    if ($Port -eq 4506) { return $script:scP4506 }
    if ($Port -eq 443)  { return $script:scRepo }
    return $false
  }
  $script:Flags.Clear(); $script:Logged.Clear(); $script:Evidence = @{}
}
function Flagged([string]$Pattern) { return [bool]@($script:Flags | Where-Object { $_ -match $Pattern }).Count }

Write-Host ''
Write-Host '=== 1. the real helpers, against this machine ===' -ForegroundColor Cyan
$live = Real-SaltMinionState
T 'Get-SaltMinionState returns a shape, not an error' ($null -ne $live.installed) ('installed=' + [string]$live.installed)
T 'absent reads absent, not healthy' ($live.installed -or ($live.status -eq 'absent')) ([string]$live.status)
$t0 = Get-Date
$unreachable = Real-TcpReachable -HostName '203.0.113.1' -Port 4505 -TimeoutMs 3000
$secs = [math]::Round(((Get-Date)-$t0).TotalSeconds,1)
T 'a blackholed host returns false' (-not $unreachable) ([string]$unreachable)
T 'and it HONOURS the 3s ceiling it was given' ($secs -lt 8) ([string]$secs + 's')
T 'an empty hostname is false, not an exception' (-not (Real-TcpReachable -HostName '' -Port 4505)) ''

Write-Host ''
Write-Host '=== 2. -SkipSalt ===' -ForegroundColor Cyan
Set-Scenario
$SkipSalt = $true
$rc = Invoke-Salt
$SkipSalt = $false
T 'returns 3, not 0 - unmanaged is not success' ($rc -eq 3) ([string]$rc)
T 'never terminal (1,4,5,6 would abandon the adopt)' ($rc -notin @(1,4,5,6)) ([string]$rc)
T 'action recorded as skipped' ($script:Evidence['salt'].action -eq 'skipped') ([string]$script:Evidence['salt'].action)
T 'it is flagged for a human' (Flagged 'SkipSalt') ''

Write-Host ''
Write-Host '=== 3. only 4506 open - the false-healthy minion ===' -ForegroundColor Cyan
Set-Scenario -P4505 $false -P4506 $true -Repo $false
$rc = Invoke-Salt
T 'flags the asymmetry explicitly' (Flagged '4506 but NOT on 4505') ''
T 'the flag says no state will run' (Flagged 'NO STATE EVER RUNS') ''
T 'returns 3' ($rc -eq 3) ([string]$rc)

Write-Host ''
Write-Host '=== 4. repo unreachable - the join must NOT be attempted ===' -ForegroundColor Cyan
Set-Scenario -P4505 $true -P4506 $true -Repo $false
$rc = Invoke-Salt
T 'action is blocked' ($script:Evidence['salt'].action -eq 'blocked') ([string]$script:Evidence['salt'].action)
T 'returns 3' ($rc -eq 3) ([string]$rc)
T 'prints the manual one-liner so it can be done by hand' (Flagged 'irm https://repo\.example\.invalid') ''
T 'nothing claims the minion is running' (-not $script:Evidence['salt'].after.running) ''

Write-Host ''
Write-Host '=== 5. already a minion, on OUR master, running ===' -ForegroundColor Cyan
Set-Scenario -Installed $true -Status 'Running' -Master 'salt.example.invalid' -P4505 $true -P4506 $true -Repo $true
$rc = Invoke-Salt
T 'returns 0 - nothing to do is success' ($rc -eq 0) ([string]$rc)
T 'action is already-installed' ($script:Evidence['salt'].action -eq 'already-installed') ([string]$script:Evidence['salt'].action)
T 'no flag raised on a healthy minion' ($script:Flags.Count -eq 0) ('flags=' + [string]$script:Flags.Count)

Write-Host ''
Write-Host '=== 6. already a minion, but pointed at the SOURCE estate master ===' -ForegroundColor Cyan
Set-Scenario -Installed $true -Status 'Running' -Master 'salt.oldestate.invalid' -P4505 $true -P4506 $true -Repo $true
$rc = Invoke-Salt
T 'the foreign master is flagged' (Flagged 'NOT salt\.example\.invalid') ''
T 'the flag names the risk of the old estate pushing state' (Flagged 'migrating OFF') ''
T 'returns 3' ($rc -eq 3) ([string]$rc)

Write-Host ''
Write-Host '=== 7. installed but stopped, and it cannot be started ===' -ForegroundColor Cyan
Set-Scenario -Installed $true -Status 'Stopped' -Master 'salt.example.invalid' -Svc 'yc-no-such-service-9f3a' -P4505 $true -P4506 $true -Repo $true
$rc = Invoke-Salt
T 'a failed start is flagged, not swallowed' (Flagged 'could not be started') ''
T 'returns 3' ($rc -eq 3) ([string]$rc)
T 'still never terminal' ($rc -notin @(1,4,5,6)) ([string]$rc)

Write-Host ''
Write-Host '=== 8. the phase is wired into the run, not just defined ===' -ForegroundColor Cyan
T 'SALT is in AllPhases'                 ($src -match '\$AllPhases = @\(''SURVEY''.*''SALT''') ''
T 'SALT is in the dispatcher'             ($src -match '''SALT''\s*\{\s*\$rc = Invoke-Salt') ''
T 'SALT is in the dispatched guard list'  ($src -match '''TASKS'',''SALT'',''NOTIFY'',''VERIFY''') ''
T 'SALT runs between TASKS and NOTIFY'    ($src.IndexOf("'TASKS','SALT','NOTIFY'") -gt 0) ''
T 'the outcome leaves the VM for ychook'  ($src -match 'salt='' \+ \[string\]\$sl\.action') ''
T '-Help documents the phase'             ($src -match '(?m)^  SALT       hands this machine') ''
T '-Report mode cannot reach it'          ($src -match 'if \(\$Report\) \{ \$phases = @\(''SURVEY'',''SQL''\) \}') ''
T 'the join never runs in-process (an exit in it would kill the adopt)' ($src -match '-NoProfile'',''-ExecutionPolicy'',''Bypass'',''-File'',\s*\$tmp' -or $src -match '-ExecutionPolicy Bypass -File \$tmp') ''

Write-Host ''
Write-Host ('RESULT: ' + [string]$pass + ' passed, ' + [string]$fail + ' failed') -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
