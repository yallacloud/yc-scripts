# Self-check for the two pure-logic functions in Activate-Windows.ps1.
# Pulls them out of the real file by AST so the test can never drift from it.
$script:FakeBuild = 0
function Get-CimInstance{ param($ClassName,$Filter,$ErrorAction) [pscustomobject]@{ BuildNumber = $script:FakeBuild } }
$e=$null;$t=$null
$target = Join-Path $PSScriptRoot 'Activate-Windows.ps1'
if(-not (Test-Path -LiteralPath $target)){
  # ParseFile on a missing path reports "parse errors", which reads as a broken script
  # rather than a missing one. Say what is actually wrong.
  Write-Host ("[FAIL] Activate-Windows.ps1 was not found next to this test (" + $target + "). " +
              "This test must run from the payload directory, normally C:\Scripts.") -ForegroundColor Red
  exit 1
}
$ast=[System.Management.Automation.Language.Parser]::ParseFile($target,[ref]$t,[ref]$e)
if($e){ throw 'parse errors' }
foreach($n in @('Get-YcGvlk','Test-YcRearmError','Get-YcEditionFromDism','Format-YcReArm','Get-YcTargetEdition')){
  $f=$ast.Find({param($x) ($x -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $x.Name -eq $n},$true)
  if(-not $f){ throw "function $n not found" }
  Invoke-Expression $f.Extent.Text
}
$fail=0
function Check($what,$got,$want){ if("$got" -ne "$want"){ $script:fail++; Write-Host "FAIL $what : got '$got' want '$want'" } else { Write-Host "ok   $what" } }

$script:FakeBuild=9600 ; Check '2012R2 std' (Get-YcGvlk 'ServerStandard')   'D2N9P-3P6X9-2R39C-7RTCD-MDVJX'
$script:FakeBuild=9600 ; Check '2012R2 dc'  (Get-YcGvlk 'ServerDatacenter') 'W3GGN-FT8W3-Y4M27-J84CP-Q3VJ9'
$script:FakeBuild=14393; Check '2016 std'   (Get-YcGvlk 'ServerStandard')   'WC2BQ-8NRM3-FDDYY-2BFGV-KHKQY'
$script:FakeBuild=14393; Check '2016 dc'    (Get-YcGvlk 'ServerDatacenter') 'CB7KF-BWN84-R7R2Y-793K2-8XDDG'
$script:FakeBuild=17763; Check '2019 std'   (Get-YcGvlk 'ServerStandard')   'N69G4-B89J2-4G8F4-WWYCC-J464C'
$script:FakeBuild=17763; Check '2019 dc'    (Get-YcGvlk 'ServerDatacenter') 'WMDGN-G9PQG-XVVXX-R3X43-63DFG'
$script:FakeBuild=20348; Check '2022 std'   (Get-YcGvlk 'ServerStandard')   'VDYBN-27WPP-V4HQT-9VMD4-VMK7H'
$script:FakeBuild=20348; Check '2022 dc'    (Get-YcGvlk 'ServerDatacenter') 'WX4NM-KYWYW-QJJR4-XV3QB-6VM33'
$script:FakeBuild=26100; Check '2025 std'   (Get-YcGvlk 'ServerStandard')   'TVRH6-WHNXV-R9WG3-9XRFY-MY832'
$script:FakeBuild=26100; Check '2025 dc'    (Get-YcGvlk 'ServerDatacenter') 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'
$script:FakeBuild=7601 ; Check 'unknown os' (Get-YcGvlk 'ServerStandard')   ''
$script:FakeBuild=17763; Check 'unknown ed' (Get-YcGvlk 'ServerFoo')        ''
# every returned GVLK must satisfy the same regex the script enforces on -ProductKey
foreach($b in 9600,14393,17763,20348,26100){ $script:FakeBuild=$b
  foreach($ed in 'ServerStandard','ServerDatacenter'){
    Check ("shape $b $ed") ((Get-YcGvlk $ed) -match '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') 'True' } }

Check 'D302 detected'  (Test-YcRearmError 'Error: 0xC004D302 The Security Processor reported that the trusted data store was rearmed') 'True'
Check 'D302 lowercase' (Test-YcRearmError 'error 0xc004d302 blah') 'True'
Check 'not D302'       (Test-YcRearmError 'Error: 0x8a010101 The specified product key could not be validated.') 'False'
Check 'empty'          (Test-YcRearmError '') 'False'

# --- Get-YcEditionFromDism: the exact lines a real guest prints. Captured from
# --- C22E (93.177.125.216) on 2026-08-29, not invented. The 'Current edition is:'
# --- header is the line that broke v2.1 and earlier: Select-String matched it
# --- case-insensitively and $cur became a 2-element array.
$real = @(
  'Deployment Image Servicing and Management tool',
  'Version: 10.0.20348.5830',
  '',
  'Image Version: 10.0.20348.4171',
  '',
  'Current edition is:',
  '',
  'Current Edition : ServerStandardEval',
  '',
  'The operation completed successfully.'
)
Check 'dism eval'        (Get-YcEditionFromDism $real) 'ServerStandardEval'
Check 'dism scalar'      ((Get-YcEditionFromDism $real).GetType().Name) 'String'
Check 'dism derived'     ((Get-YcEditionFromDism $real) -replace 'Eval$','') 'ServerStandard'
Check 'dism derive ok'   (((Get-YcEditionFromDism $real) -replace 'Eval$','') -match '^[A-Za-z][A-Za-z0-9]{1,31}$') 'True'
$conv = @('Current edition is:','Current Edition : ServerDatacenter')
Check 'dism converted'   (Get-YcEditionFromDism $conv) 'ServerDatacenter'
Check 'dism header only' (Get-YcEditionFromDism @('Current edition is:')) ''
Check 'dism empty'       (Get-YcEditionFromDism @()) ''
Check 'dism no match'    (Get-YcEditionFromDism @('nothing useful here')) ''

# --- Format-YcReArm: 0xFFFFFFFF is a uint32 sentinel, not a count. C22E returns
# --- it; C19E returns 6. The old [int] cast threw on it and reported -1.
Check 'rearm healthy'    (Format-YcReArm 6) '6'
Check 'rearm zero'       (Format-YcReArm 0) '0'
Check 'rearm sentinel'   ((Format-YcReArm 4294967295) -like '4294967295 (0xFFFFFFFF*') 'True'
Check 'rearm unreadable' ((Format-YcReArm -1) -like 'unreadable*') 'True'

# --- Get-YcTargetEdition: ServerStandard by default (v2.3), except on a
# --- Datacenter evaluation image where that default would make dism fail.
Check 'ed default std'   (Get-YcTargetEdition '' ' ServerStandardEval')      'ServerStandard'
Check 'ed default blank' (Get-YcTargetEdition '' '')                         'ServerStandard'
Check 'ed dc image'      (Get-YcTargetEdition '' 'ServerDatacenterEval')     'ServerDatacenter'
Check 'ed dc converted'  (Get-YcTargetEdition '' 'ServerDatacenter')         'ServerDatacenter'
Check 'ed explicit wins' (Get-YcTargetEdition 'ServerDatacenter' 'ServerStandardEval') 'ServerDatacenter'
Check 'ed explicit std'  (Get-YcTargetEdition 'ServerStandard' 'ServerDatacenterEval') 'ServerStandard'
Check 'ed trims'         (Get-YcTargetEdition '  ServerStandard  ' '')       'ServerStandard'
# whatever it returns must survive the script's own -Edition regex
foreach($c in @('',' ServerStandardEval','ServerDatacenterEval','ServerStandard')){
  Check ("ed shape [$c]") ((Get-YcTargetEdition '' $c) -match '^[A-Za-z][A-Za-z0-9]{1,31}$') 'True' }
# and it must resolve to a real GVLK
$script:FakeBuild=17763
Check 'ed->gvlk std'     (Get-YcGvlk (Get-YcTargetEdition '' ' ServerStandardEval'))  'N69G4-B89J2-4G8F4-WWYCC-J464C'
Check 'ed->gvlk dc'      (Get-YcGvlk (Get-YcTargetEdition '' 'ServerDatacenterEval')) 'WMDGN-G9PQG-XVVXX-R3X43-63DFG'

# --- regression: the compliance gate's blocking SIDEEFFECT finding -------------
# Activate-Windows.ps1:534 used to register a startup retry task on a path that
# had ALREADY failed, with no success check. On a template whose licensing store
# reads 0xFFFFFFFF that leaves a VM which looks handled and can never succeed.
# Verified live on X19B, 2026-08-29.
$src = Join-Path $PSScriptRoot 'Activate-Windows.ps1'
$e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$e)
$fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Test-YcStoreRepairable' }, $true)
if (-not $fn) { throw 'Test-YcStoreRepairable is missing - the SIDEEFFECT guard has been removed' }
. ([scriptblock]::Create($fn.Extent.Text))
Check 'rearm 0xFFFFFFFF = store NOT repairable' (Test-YcStoreRepairable 4294967295) 'False'
Check 'rearm unreadable (-1) = NOT repairable'  (Test-YcStoreRepairable -1) 'False'
Check 'rearm 0 = repairable (a boot may still clear the flag)' (Test-YcStoreRepairable 0) 'True'
Check 'rearm 3 = repairable'                    (Test-YcStoreRepairable 3) 'True'
$body = Get-Content $src -Raw
Check 'the retry task is never registered unguarded' ($body -notmatch 'Set-YcPostRebootActivation \| Out-Null') 'True'
Check 'the damaged-store path removes any stale task' ($body -match 'Remove-YcPostRebootActivation[\s\S]{0,400}unreadable') 'True'

if($fail){ Write-Host "`n$fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nall checks passed"; exit 0 }
