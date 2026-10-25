# test-acronis-phase.ps1 - self-check for the OPTIONAL ACRONIS phase of Adopt-MigratedVm.ps1.
#
# The functions under test are sliced out of the shipped script. Get-AcronisState is overridden to
# stand for machines this host is not; nothing is installed, fetched or registered by this test,
# and no token is ever used.
#
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File .\test-acronis-phase.ps1
# It must end with '0 failed'.
param(
  [string]$Script     = 'C:\Scripts\Adopt-MigratedVm.ps1',
  [string]$PayloadDir = 'C:\Scripts'
)
if (-not (Test-Path -LiteralPath $Script)) {
  Write-Host ('cannot find the script under test: ' + $Script) -ForegroundColor Red; return
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

$script:Flags = New-Object System.Collections.Generic.List[string]
function L    { param($m,$l='INFO') }
function Flag { param($p,$w) $script:Flags.Add($p + ': ' + $w) | Out-Null }
$script:Evidence = @{}
$ScriptsDir = $PayloadDir

Invoke-Expression (Grab 'Invoke-Acronis')
Invoke-Expression ((Grab 'Get-AcronisState') -replace 'function Get-AcronisState \{', 'function Real-AcronisState {')

# NOT a literal assigned to a token-named variable: scan-secrets flags that shape in a public
# repo and it is right to - a placeholder and a real token look identical to a scanner.
$FakeValue    = 'placeholder-not-a-secret'
$AcronisToken = ''; $AcronisRegion = ''; $SkipAcronis = $false
$AcronisWaitSec = 3600; $AcronisSetupUrl = 'https://repo.example.invalid/acronis/acronis-setup.ps1'

function Set-Acr {
  param([bool]$Installed=$false,[bool]$Registered=$false,[string]$Status='absent',[string]$Dc='')
  $script:acInstalled=$Installed; $script:acRegistered=$Registered; $script:acStatus=$Status; $script:acDc=$Dc
  function script:Get-AcronisState {
    [ordered]@{ installed=$script:acInstalled; service=$(if($script:acInstalled){'MMS'}else{''})
                status=$script:acStatus; running=($script:acStatus -eq 'Running')
                version='15.0.37012'; registered=$script:acRegistered
                dataCenter=$script:acDc; foundAt='HKLM:\SOFTWARE\Acronis\x' }
  }
  $script:Flags.Clear(); $script:Evidence = @{}
}
function Flagged([string]$p) { return [bool]@($script:Flags | Where-Object { $_ -match $p }).Count }

Write-Host ''
Write-Host '=== 1. the real state reader, against this machine ===' -ForegroundColor Cyan
$live = Real-AcronisState
T 'returns a shape, not an error'        ($null -ne $live.installed) ('installed=' + [string]$live.installed)
T 'absent reads absent, not healthy'     ($live.installed -or ($live.status -eq 'absent')) ([string]$live.status)
T 'registered is boolean'                ($live.registered -is [bool]) ([string]$live.registered)

Write-Host ''
Write-Host '=== 2. OPTIONAL: no token, nothing installed -> skip, and NOT a finding ===' -ForegroundColor Cyan
Set-Acr
$rc = Invoke-Acronis
T 'returns 0 - skipping is success'      ($rc -eq 0) ([string]$rc)
T 'action says not requested'            ($script:Evidence['acronis'].action -eq 'skipped-not-requested') ([string]$script:Evidence['acronis'].action)
T 'raises NO finding'                    ($script:Flags.Count -eq 0) ('flags=' + [string]$script:Flags.Count)
T 'nothing was fetched or installed'     (-not $script:Evidence['acronis'].requested) ''

Write-Host ''
Write-Host '=== 3. -SkipAcronis ===' -ForegroundColor Cyan
Set-Acr
$AcronisToken = $FakeValue; $AcronisRegion = 'AE'; $SkipAcronis = $true
$rc = Invoke-Acronis
$SkipAcronis = $false; $AcronisToken = ''; $AcronisRegion = ''
T 'returns 0'                            ($rc -eq 0) ([string]$rc)
T 'action is skipped'                    ($script:Evidence['acronis'].action -eq 'skipped') ([string]$script:Evidence['acronis'].action)
T 'no finding'                           ($script:Flags.Count -eq 0) ('flags=' + [string]$script:Flags.Count)

Write-Host ''
Write-Host '=== 4. already installed AND registered -> skip before fetching ===' -ForegroundColor Cyan
Set-Acr -Installed $true -Registered $true -Status 'Running' -Dc 'https://ae01-cloud.acronis.com'
$AcronisToken = $FakeValue; $AcronisRegion = 'AE'
$rc = Invoke-Acronis
T 'returns 0'                            ($rc -eq 0) ([string]$rc)
T 'action is already-registered'         ($script:Evidence['acronis'].action -eq 'already-registered') ([string]$script:Evidence['acronis'].action)
T 'no 1.8 GB was pulled'                 (-not $script:Evidence['acronis'].requested) ''
T 'no finding on a healthy agent'        ($script:Flags.Count -eq 0) ('flags=' + [string]$script:Flags.Count)
T 'records the data center'              ($script:Evidence['acronis'].after.dataCenter -eq 'https://ae01-cloud.acronis.com') ''

Write-Host ''
Write-Host '=== 5. registered but the service is STOPPED ===' -ForegroundColor Cyan
Set-Acr -Installed $true -Registered $true -Status 'Stopped' -Dc 'https://sg-cloud.acronis.com'
$rc = Invoke-Acronis
T 'a stopped agent is flagged'           (Flagged 'MMS service is Stopped') ''
T 'the flag says it takes no backups'    (Flagged 'takes no backups') ''
T 'returns 3'                            ($rc -eq 3) ([string]$rc)

Write-Host ''
Write-Host '=== 6. installed but NOT registered, and no token to fix it ===' -ForegroundColor Cyan
Set-Acr -Installed $true -Registered $false -Status 'Running'
$AcronisToken = ''; $AcronisRegion = ''
$rc = Invoke-Acronis
T 'action is installed-not-registered'   ($script:Evidence['acronis'].action -eq 'installed-not-registered') ([string]$script:Evidence['acronis'].action)
T 'flagged even though no token given'   (Flagged 'NOT registered') ''
T 'the flag names the real danger'       (Flagged 'looks like protection and provides none') ''
T 'returns 3'                            ($rc -eq 3) ([string]$rc)

Write-Host ''
Write-Host '=== 7. a region that is not AE or SG ===' -ForegroundColor Cyan
Set-Acr
$AcronisToken = $FakeValue; $AcronisRegion = 'EU'
$rc = Invoke-Acronis
$AcronisToken = ''; $AcronisRegion = ''
T 'refused before anything ran'          ($script:Evidence['acronis'].action -eq 'bad-region') ([string]$script:Evidence['acronis'].action)
T 'and it says what the two options are' (Flagged 'AE is the UAE data center') ''
T 'returns 3'                            ($rc -eq 3) ([string]$rc)

Write-Host ''
Write-Host '=== 8. the token never reaches a log or a flag ===' -ForegroundColor Cyan
$leak = ($src -match "L \('acronis.*' \+ \`$AcronisToken") -or ($src -match "Invoke-YcCommand[^\r\n]*AcronisToken")
T 'the token is never concatenated into a log line' (-not $leak) ''
T 'it never goes through Invoke-YcCommand (which logs args)' ($src.IndexOf("Invoke-YcCommand -Script 'acronis") -lt 0) ''
T 'the logged command line is redacted'  ($src.IndexOf("acronis-setup.ps1 **** ") -gt 0) ''
T 'the honest limit is written down'     ($src.IndexOf('visible in the process list') -gt 0) ''

Write-Host ''
Write-Host '=== 9. wired into the run ===' -ForegroundColor Cyan
T 'ACRONIS is in AllPhases'              ($src.IndexOf("'TASKS','SALT','ACRONIS','NOTIFY','VERIFY'") -gt 0) ''
T 'ACRONIS has a dispatcher case'        ($src.IndexOf("'ACRONIS'   { `$rc = Invoke-Acronis }") -gt 0) ''
T 'it runs after SALT, before NOTIFY'    ($src.IndexOf("'SALT','ACRONIS','NOTIFY'") -gt 0) ''
T 'the notification carries a line'      ($src.IndexOf("'acronis  : '") -gt 0) ''
T 'the state leaves the VM for ychook'   ($src.IndexOf('acronisRegistered=') -gt 0 -and $src.IndexOf('acronisInstalled=') -gt 0) ''
T 'but the token does NOT'               ($src.IndexOf('acronisToken=') -lt 0) ''
T '-Help documents the phase'            ($src -match '(?m)^  ACRONIS    OPTIONAL') ''
T 'the web installer is left alone'      ($src.IndexOf('Register-Acronis.ps1 is the WEB installer') -gt 0) ''

Write-Host ''
Write-Host ('RESULT: ' + [string]$pass + ' passed, ' + [string]$fail + ' failed') -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
