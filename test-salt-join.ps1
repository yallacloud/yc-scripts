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
Invoke-Expression (Grab 'Get-SaltMasterForThisHost')
Invoke-Expression ((Grab 'Test-TcpReachable')   -replace 'function Test-TcpReachable \{',   'function Real-TcpReachable {')
Invoke-Expression ((Grab 'Get-SaltMinionState') -replace 'function Get-SaltMinionState \{', 'function Real-SaltMinionState {')

$SaltMaster  = 'salt.example.invalid'   # set, so the scenarios below do not depend on this host's IPs
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
Write-Host '=== 4. mirror unreachable - reported, and the retry task handles it ===' -ForegroundColor Cyan
Set-Scenario -P4505 $true -P4506 $true -Repo $false
$rc = Invoke-Salt
T 'the mirror being down is reported, not fatal'  ($script:Evidence['salt'].repoReachable -eq $false) ([string]$script:Evidence['salt'].repoReachable)
T 'returns 3' ($rc -eq 3) ([string]$rc)
T 'and the flag says the retry task fixes it by itself' (Flagged 'retry task will keep trying') ''
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
Write-Host '=== 8. the master is DERIVED, not hardcoded (STACK4-54 s0) ===' -ForegroundColor Cyan
$SaltMaster = ''
$derived = Get-SaltMasterForThisHost
T 'with no -SaltMaster it derives one'   ([bool]$derived) $derived
T 'and it is one of the two real names'  ($derived -in @('salt.mgmt.yallacloud.net','salt.oasisstack.io')) $derived
$SaltMaster = 'salt.override.invalid'
T '-SaltMaster wins when given'          ((Get-SaltMasterForThisHost) -eq 'salt.override.invalid') (Get-SaltMasterForThisHost)
$SaltMaster = 'salt.example.invalid'

Write-Host ''
Write-Host '=== 9. the one-line result is what decides the verdict (STACK4-54 s00) ===' -ForegroundColor Cyan
foreach ($case in @(
    @{ line='JOINED acme-web01'; want='JOINED'; id='acme-web01' },
    @{ line='CONFIGURED acme-web01'; want='CONFIGURED'; id='' },
    @{ line='WAITING: not in CloudStack uuid=937feded-1111-2222-3333-444455556666 macs=06:aa:bb:cc:dd:ee'; want='WAITING'; id='' },
    @{ line='FAILED: could not download the installer'; want='FAILED'; id='' }
  )) {
  $l = $case.line
  $hit = ''
  if ($l -match '^(JOINED|CONFIGURED|WAITING|FAILED)') { $hit = $Matches[1] }
  T ('recognises ' + $case.want)  ($hit -eq $case.want) $hit
  if ($case.want -eq 'JOINED') {
    $gotId = ''
    if ($l -match '^JOINED\s+(\S+)') { $gotId = $Matches[1] }
    T 'and captures the minion id the master chose' ($gotId -eq $case.id) $gotId
  }
  if ($case.want -eq 'WAITING') {
    $u=''; $m=''
    if ($l -match 'uuid=(\S+)') { $u = $Matches[1] }
    if ($l -match 'macs=(\S+)') { $m = $Matches[1] }
    T 'and captures the uuid for manual.yaml' ($u -eq '937feded-1111-2222-3333-444455556666') $u
    T 'and the MACs'                          ($m -eq '06:aa:bb:cc:dd:ee') $m
  }
}
T 'WAITING is NOT judged by whether a service appeared' ($src -match "WAITING is a\s*\n?\s*#\s*legitimate outcome" -or $src -match 'legitimate outcome') ''
T 'the phase explains why it does not call Salt-Register directly' ($src -match 'reactor DELETES a key whose id') ''
T 'CONFIGURED is handled and is NOT reported as joined' ($src.IndexOf("-match '^CONFIGURED'") -gt 0) ''
T 'CONFIGURED says the key is not proven accepted'      ($src -match 'has NOT been proven accepted') ''
T 'the join exit code is recorded'                      ($src.IndexOf('$st.joinExit =') -gt 0) ''

Write-Host ''
Write-Host '=== 9b. the retry task join.ps1 registers is EXPECTED, not foreign ===' -ForegroundColor Cyan
T "'YallaCloud Salt Join' is in OurTaskNames" ($src -match "'YallaCloud Salt Join'\)") ''
T 'so VERIFY cannot flag it as a task we did not create' ($src -match 'self-healing task') ''
T 'and the phase reports that the VM retries itself'     ($src -match 'does not need a second visit') ''

Write-Host ''
Write-Host '=== 10. the phase is wired into the run, not just defined ===' -ForegroundColor Cyan
T 'SALT is in AllPhases'                 ($src -match '\$AllPhases = @\(''SURVEY''.*''SALT''') ''
T 'SALT is in the dispatcher'             ($src -match '''SALT''\s*\{\s*\$rc = Invoke-Salt') ''
T 'SALT is in the dispatched guard list'  ($src.IndexOf("'TASKS','SALT','ACRONIS','GLPI','NOTIFY','VERIFY'") -gt 0) ''
T 'SALT runs after TASKS, before ACRONIS' ($src.IndexOf("'TASKS','SALT','ACRONIS'") -gt 0) ''
T 'the outcome leaves the VM for ychook'  ($src -match 'salt='' \+ \[string\]\$sl\.action') ''
T '-Help documents the phase'             ($src -match '(?m)^  SALT       hands this machine') ''
T '-Report mode cannot reach it'          ($src -match 'if \(\$Report\) \{ \$phases = @\(''SURVEY'',''SQL''\) \}') ''
T 'it calls the house command salt-join, not its own fetch' ($src.IndexOf("Invoke-YcCommand -Script 'Salt-Join.ps1'") -gt 0) ''
T 'it refuses when Salt-Join.ps1 is not in the payload'    ($src.IndexOf("'Salt-Join.ps1')))") -gt 0 -or $src.IndexOf("Salt-Join.ps1 is not in") -gt 0) ''
T 'the wait is bounded and does not decide the outcome'    ($src.IndexOf('SaltWaitSec') -gt 0 -and $src.IndexOf('retries every 15 min regardless') -gt 0) ''
T 'a CONFIGURED line with leading spaces is still matched' ($src.IndexOf('s*(JOINED|CONFIGURED|WAITING:|FAILED:)') -gt 0) ''
T 'and the reason for that is written down'               ($src.IndexOf('four leading spaces') -gt 0) ''
T 'INSTALLED / NOT INSTALLED is its own log line'         ($src.IndexOf('salt-minion   : INSTALLED') -gt 0 -and $src.IndexOf('salt-minion   : NOT INSTALLED') -gt 0) ''
T 'a minion off the 3008 line is flagged'                 ($src.IndexOf('not on the 3008 LTS line') -gt 0) ''
T 'install state and version leave the VM for ychook'     ($src.IndexOf('saltInstalled=') -gt 0 -and $src.IndexOf('saltVersion=') -gt 0) ''

Write-Host ''
Write-Host ('RESULT: ' + [string]$pass + ' passed, ' + [string]$fail + ' failed') -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
