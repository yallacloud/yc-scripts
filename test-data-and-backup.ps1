# Proves the three data answers and the one banner that carries them. The trap this is built
# against: on the first real end-to-end run, "33 damaged pages", "8 databases never CHECKDB'd"
# and "VSS has 4 CRITICAL findings" all went past as ordinary WARN lines while the guest platform
# got a red banner. These three ARE the data and the backup path.
param([string]$Script, [string]$PayloadDir = 'C:\Scripts')
$src = Get-Content -LiteralPath $Script -Raw
function Grab([string]$n){ $i=$src.IndexOf('function '+$n+' {'); if($i -lt 0){throw "not found: $n"}; $j=$src.IndexOf("`nfunction ",$i+10); if($j -lt 0){$j=$src.Length}; $src.Substring($i,$j-$i) }
$ScriptsDir = $PayloadDir
$script:Flags = @()
function L { param($m,$l='INFO') }
function Flag { param($p,$w) $script:Flags += $w }
foreach ($fn in @('Write-LoudBanner','Get-VssState','Get-ChkdskState','Get-SqlIntegrityState','Invoke-DataAndBackupCheck')) { Invoke-Expression (Grab $fn) }
$fail=0
function Check($what,$got,$want){ if("$got" -eq "$want"){Write-Host "  PASS  $what = $got" -ForegroundColor Green}else{Write-Host "  FAIL  $what = $got (expected $want)" -ForegroundColor Red; $script:fail++} }

Write-Host '=== 1. Get-VssState against the REAL vss-check on this machine ===' -ForegroundColor Cyan
$script:Evidence = [ordered]@{ vss=$null }
$v = Get-VssState
Write-Host ('  ran      : ' + $v.ran + '   exit: ' + $v.exit)
Write-Host ('  critical : ' + $v.critical + '   warn: ' + $v.warn + '   findings parsed: ' + @($v.findings).Count)
Write-Host ('  verdict  : ' + $v.verdict)
Write-Host ('  why      : ' + $v.why)
foreach ($f in @($v.findings | Select-Object -First 4)) { Write-Host ('    [' + $f.severity + '] ' + $f.area + ' - ' + $f.subject) }
# exit 5 is "not elevated" - it must say it could not CHECK, never that VSS is fine.
if ($v.exit -eq 5) {
  Check 'an unelevated vss-check reads NOT-CHECKED' $v.verdict 'NOT-CHECKED'
  if ($v.why -match 'not checked, not found healthy') { Write-Host '  PASS  it says checked-vs-healthy in words' -ForegroundColor Green }
  else { Write-Host '  FAIL  an unelevated run does not distinguish not-checked from healthy' -ForegroundColor Red; $fail++ }
} elseif ($v.ran -and @($v.findings).Count -eq 0 -and $v.exit -notin @(0,5)) {
  Write-Host '  FAIL  vss-check reported a non-zero exit but NO findings were parsed - the JSON parse is broken' -ForegroundColor Red; $fail++
} else { Write-Host '  PASS  findings parsed consistently with the exit code' -ForegroundColor Green }
# the cache must stop a second run
$script:Evidence['vss'] = $v
$t0 = Get-Date; $v2 = Get-VssState; $ms = ((Get-Date)-$t0).TotalMilliseconds
Check 'the cached call returns the same verdict' $v2.verdict $v.verdict
if ($ms -gt 500) { Write-Host ("  FAIL  cached call took ${ms}ms - it re-ran vss-check") -ForegroundColor Red; $fail++ }
else { Write-Host ("  PASS  cached call was instant (${ms}ms) - vss-check did not run twice") -ForegroundColor Green }

Write-Host ''
Write-Host '=== 2. chkdsk: dirty bit, unreadable, and no-record-ever ===' -ForegroundColor Cyan
$script:Evidence = [ordered]@{ volumes=@([ordered]@{drive='C:';fs='NTFS';dirty='YES - Windows has already decided this volume needs repair'}) }
$c1 = Get-ChkdskState
Check 'dirty bit set reads BAD' $c1.verdict 'BAD'
Check 'it names the volume' (@($c1.dirtyVolumes) -join ',') 'C:'
$script:Evidence = [ordered]@{ volumes=@([ordered]@{drive='C:';fs='NTFS';dirty='(unreadable)'}) }
$c2 = Get-ChkdskState
# A real chkdsk failure outranks an unreadable bit, so only assert UNPROVEN when the last scan
# was NOT a failure. Either way it must never be OK.
if ($c2.verdict -eq 'BAD') { Write-Host ('  PASS  a recorded chkdsk failure outranks the unreadable bit (' + $c2.why + ')') -ForegroundColor Green }
else { Check 'unreadable dirty bit reads UNPROVEN' $c2.verdict 'UNPROVEN' }
if ($c2.verdict -eq 'OK') { Write-Host '  FAIL  an unreadable dirty bit must never read OK' -ForegroundColor Red; $fail++ }

$script:Evidence = [ordered]@{ volumes=@([ordered]@{drive='C:';fs='NTFS';dirty='no'}) }
$c3 = Get-ChkdskState
Write-Host ('  clean volume on THIS machine -> ' + $c3.verdict)
Write-Host ('    last run   : ' + $c3.lastRun)
Write-Host ('    clean flag : ' + $c3.clean)
Write-Host ('    matched    : ' + (@($c3.found) -join '; '))
# THE BUG THIS CATCHES: "Windows has scanned the file system and found no problems" contains the
# word "problems". A loose match reads a clean scan as a failure, and this laptop proved it.
if ($c3.clean -and $c3.verdict -eq 'BAD') {
  Write-Host '  FAIL  a CLEAN chkdsk result was read as BAD' -ForegroundColor Red; $fail++
} else { Write-Host '  PASS  a clean chkdsk result is not read as a failure' -ForegroundColor Green }
if ($c3.verdict -notin @('OK','UNPROVEN','BAD')) { Write-Host '  FAIL  unexpected verdict' -ForegroundColor Red; $fail++ }
else { Write-Host '  PASS  a clean volume produces a real verdict, not a blank' -ForegroundColor Green }

Write-Host ''
Write-Host '=== 3. SQL integrity, the TS_BM_FD_DB01 shape ===' -ForegroundColor Cyan
$script:Evidence = [ordered]@{
  sql=@([ordered]@{ instance='MSSQLSERVER'; suspectPages=[ordered]@{ totalPages=33; earliest='2026-10-19 14:08:18'; latest='2026-10-23 08:41:12' } })
  lastKnownGood=@(
    [ordered]@{database='NEWDAT';neverChecked=$true},[ordered]@{database='PORTAL';neverChecked=$true},
    [ordered]@{database='NEWSYS';neverChecked=$true},[ordered]@{database='TSTDAT';neverChecked=$true}) }
$q = Get-SqlIntegrityState
Check 'damaged pages reads BAD' $q.verdict 'BAD'
Check 'page count carried' $q.damagedPages 33
Check 'first seen carried' $q.firstSeen '2026-10-19 14:08:18'
if ($q.why -notmatch 'STILL BEING FOUND') { Write-Host '  FAIL  ongoing damage not called out' -ForegroundColor Red; $fail++ }
else { Write-Host '  PASS  says the damage is STILL BEING FOUND (newest != oldest)' -ForegroundColor Green }
# no damage, but never checked
$script:Evidence = [ordered]@{ sql=@(); lastKnownGood=@([ordered]@{database='X';neverChecked=$true}) }
Check 'clean list but never CHECKDB reads UNPROVEN' (Get-SqlIntegrityState).verdict 'UNPROVEN'
$script:Evidence = [ordered]@{ sql=@(); lastKnownGood=@([ordered]@{database='X';neverChecked=$false}) }
Check 'clean and checked reads OK' (Get-SqlIntegrityState).verdict 'OK'

Write-Host ''
Write-Host '=== 4. all three bad: ONE banner, and the sentence that matters ===' -ForegroundColor Cyan
$script:Flags=@()
$script:Evidence = [ordered]@{
  volumes=@([ordered]@{drive='C:';fs='NTFS';dirty='YES - Windows has already decided this volume needs repair'})
  sql=@([ordered]@{ instance='MSSQLSERVER'; suspectPages=[ordered]@{ totalPages=33; earliest='2026-10-19 14:08:18'; latest='2026-10-23 08:41:12' } })
  lastKnownGood=@([ordered]@{database='NEWDAT';neverChecked=$true})
  vss=[ordered]@{ ran=$true; exit=2; critical=4; warn=3; verdict='BROKEN'
                  why='4 CRITICAL VSS finding(s). Snapshot backups are NOT application-consistent.'
                  findings=@([ordered]@{severity='CRITICAL';area='writers';subject='vssadmin list writers';detail='No writers were returned at all.';remedy='Check the VSS service.'}) } }
$rc = Invoke-DataAndBackupCheck
Check 'returns 3 (findings), not 0' $rc 3
Check 'three flags raised, one per answer' @($script:Flags).Count 3
$joined = ($script:Flags -join ' | ')
foreach ($must in @('SQL integrity','chkdsk/filesystem','VSS')) {
  if ($joined -match [regex]::Escape($must)) { Write-Host "  PASS  flag for $must" -ForegroundColor Green }
  else { Write-Host "  FAIL  no flag for $must" -ForegroundColor Red; $fail++ }
}
Check 'all three verdicts stored for the report' ("$($script:Evidence['sqlIntegrity'].verdict)/$($script:Evidence['chkdsk'].verdict)/$($script:Evidence['vss'].verdict)") 'BAD/BAD/BROKEN'

Write-Host ''
Write-Host '=== 5. healthy machine: no banner, no flags ===' -ForegroundColor Cyan
$script:Flags=@()
$script:Evidence = [ordered]@{
  volumes=@([ordered]@{drive='C:';fs='NTFS';dirty='no'})
  sql=@(); lastKnownGood=@([ordered]@{database='X';neverChecked=$false})
  vss=[ordered]@{ ran=$true; exit=0; critical=0; warn=0; verdict='OK'; why='VSS answered and reported no critical finding'; findings=@() } }
$rc2 = Invoke-DataAndBackupCheck
Write-Host ('  chkdsk on this machine came back: ' + $script:Evidence['chkdsk'].verdict)
if ($script:Evidence['chkdsk'].verdict -eq 'OK') {
  Check 'healthy returns 0' $rc2 0
  Check 'healthy raises no flags' @($script:Flags).Count 0
} else {
  Write-Host '  NOTE  this machine has no chkdsk record, so UNPROVEN is correct and one flag is expected' -ForegroundColor Yellow
  Check 'only the chkdsk answer flagged' @($script:Flags).Count 1
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green; $global:LASTEXITCODE=0 }
else { Write-Host ([string]$fail + ' CHECK(S) FAILED') -ForegroundColor Red; $global:LASTEXITCODE=1 }
