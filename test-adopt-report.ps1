# Proves the disk verdict can reach every state it claims. Before this fix it could only ever
# say GOOD or SUSPECT: Write-AdoptReport read $Survey (not in its scope) for a 'dirty' property
# the survey never collected, so the BAD branch was unreachable on a volume Windows had flagged.
param(
  # The script under test. Defaults to the installed copy, so on any adopted box this is just:
  #   powershell -ExecutionPolicy Bypass -File .\test-adopt-report.ps1
  [string]$Script = 'C:\Scripts\Adopt-MigratedVm.ps1'
)
# No bare exit: this file is meant to be runnable through  iex (irm ...)  as well as by path, and
# an exit under iex kills the OPERATOR'S session, not the script. Measured the hard way.
if (-not (Test-Path -LiteralPath $Script)) {
  Write-Host ('cannot find the script under test: ' + $Script) -ForegroundColor Red
  Write-Host 'pass -Script <path> to point at an extracted payload copy.'
  return
}
Write-Host ('testing: ' + $Script)
$src = Get-Content -LiteralPath $Script -Raw
function Grab([string]$n) {
  $i = $src.IndexOf('function ' + $n + ' {')
  if ($i -lt 0) { throw ('function not found: ' + $n) }
  $j = $src.IndexOf("`nfunction ", $i + 10)
  if ($j -lt 0) { $j = $src.Length }
  return $src.Substring($i, $j - $i)
}
function Get-HostNameSafe { 'TS_BM_FD_DB01' }
function Get-PayloadVersion { '2.30.2' }
function L { param($m,$l='INFO') }
function Flag { param($p,$w) }
Invoke-Expression (Grab 'Group-StorageEvidence')
Invoke-Expression (Grab 'Write-AdoptReport')

$ScriptsDir = Join-Path $env:TEMP 'yc-voltest'
$script:OurTaskNames = @('YC-DiskScan')
$script:Done = 1..17
$script:Flags = @()
$script:BackupOwned = $true

$corrupt = @([ordered]@{ provider='Ntfs'; id=55; level='Error'; count=16
                         first='2026-09-27 21:26:23'; last='2026-10-14 04:51:59' })

function Run($label, $vols, $corruptRows) {
  New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null
  $script:Evidence = [ordered]@{
    sql = @(); lastKnownGood = @(); volumes = $vols
    events = [ordered]@{ sql=@(); storage=$corruptRows; corruption=$corruptRows; windowDays=365; capped=$false }
    baselineSha256 = 'DEADBEEF'
  }
  Write-AdoptReport
  $j = Get-Content (Join-Path $ScriptsDir 'adopt-report.json') -Raw | ConvertFrom-Json
  $txt = Get-Content (Join-Path $ScriptsDir 'adopt-report.txt') -Raw
  Remove-Item $ScriptsDir -Recurse -Force
  return [pscustomobject]@{ label=$label; verdict=$j.volumes.verdict; reason=$j.volumes.reason
                            dirty=@($j.volumes.dirtyVolumes) -join ','
                            unreadable=@($j.volumes.dirtyBitUnreadableOn) -join ','
                            backupLine=($txt -split "`r?`n" | Where-Object { $_ -match 'owns SQL backups' }) }
}

$clean = @([ordered]@{ drive='C:'; fs='NTFS'; dirty='no' })
$dirtyV = @([ordered]@{ drive='C:'; fs='NTFS'; dirty='no' },
            [ordered]@{ drive='E:'; fs='NTFS'; dirty='YES - Windows has already decided this volume needs repair' })
$unread = @([ordered]@{ drive='C:'; fs='NTFS'; dirty='(unreadable)' })

$r = @()
$r += Run 'clean volumes, no events'        $clean  @()
$r += Run 'clean volumes, corruption events' $clean  $corrupt
$r += Run 'DIRTY BIT SET'                    $dirtyV @()
$r += Run 'dirty bit SET + events'           $dirtyV $corrupt
$r += Run 'dirty bit UNREADABLE, no events'  $unread @()

foreach ($x in $r) {
  Write-Host ('{0,-32} -> {1}' -f $x.label, $x.verdict) -ForegroundColor Cyan
  Write-Host ('    reason     : ' + $x.reason)
  Write-Host ('    dirty      : [' + $x.dirty + ']   unreadable: [' + $x.unreadable + ']')
}
Write-Host ''
Write-Host ('backup line now reads: ' + ($r[0].backupLine).Trim())
Write-Host ''
$want = @('GOOD','SUSPECT','BAD','BAD','UNPROVEN')
$fail = 0
for ($i=0; $i -lt $want.Count; $i++) {
  if ($r[$i].verdict -ne $want[$i]) { $fail++; Write-Host ('FAIL: ' + $r[$i].label + ' expected ' + $want[$i] + ' got ' + $r[$i].verdict) -ForegroundColor Red }
}
if ($r[2].dirty -ne 'E:') { $fail++; Write-Host ('FAIL: dirtyVolumes should name E:, got [' + $r[2].dirty + ']') -ForegroundColor Red }
if ($r[4].unreadable -ne 'C:') { $fail++; Write-Host ('FAIL: dirtyBitUnreadableOn should name C:, got [' + $r[4].unreadable + ']') -ForegroundColor Red }
if (($r[0].backupLine) -notmatch 'YES') { $fail++; Write-Host 'FAIL: BackupOwned=true did not reach the report' -ForegroundColor Red }
if ($fail -eq 0) {
  Write-Host 'ALL 8 CHECKS PASSED' -ForegroundColor Green
  $global:LASTEXITCODE = 0
} else {
  Write-Host ([string]$fail + ' CHECK(S) FAILED') -ForegroundColor Red
  $global:LASTEXITCODE = 1
}
