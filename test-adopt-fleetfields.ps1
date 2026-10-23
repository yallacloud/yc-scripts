# Proves the fleet event carries the facts the dispute turns on, and that it reads the two
# verdicts BACK from the report rather than recomputing them - computing them twice is how the
# event and the file drift apart.
param([string]$Script = 'C:\Scripts\Adopt-MigratedVm.ps1')
if (-not (Test-Path -LiteralPath $Script)) { Write-Host ('no script at ' + $Script) -ForegroundColor Red; return }
$src = Get-Content -LiteralPath $Script -Raw

# Pull just the field-building block out of Send-AdoptNotification.
$i = $src.IndexOf('  $f = @()')
$j = $src.IndexOf('foreach ($kv in $f) { $args += ', $i)
if ($i -lt 0 -or $j -lt 0) { Write-Host 'could not find the field block' -ForegroundColor Red; return }
$block = $src.Substring($i, $j - $i)

$ScriptsDir = Join-Path $env:TEMP 'yc-fieldtest'
New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null
function L { param($m,$l='INFO') Write-Host ('    [' + $l + '] ' + $m) }
$AllPhases = 1..17
$script:Done = 1..15
$fl = 2
$script:Evidence = [ordered]@{ baselineSha256='ABC123DEF456'
  guestAgent = [ordered]@{ verdict='MISSING'; service=''; status='absent'; version='' } }
$ga = [ordered]@{ verdict='OK'; service='QEMU-GA'; status='Running'; version='110.0.2' }
$vi = [ordered]@{ verdict='DIFFERS'; pinPackage='0.1.271-1'
  drivers=@([ordered]@{ driver='viostor'; fileVersion='100.100.100.20800'; state='DIFFERS-FROM-PIN' },
            [ordered]@{ driver='balloon'; fileVersion='100.100.104.27100'; state='MATCHES-PIN' }) }

# the report the event must read back from
@{ databases = @{ verdict='BAD'; damagedPages=33; firstSeen='2026-10-19 14:08:18' }
   volumes   = @{ verdict='SUSPECT'; corruptionCount=36; corruptionFirstSeen='2026-09-27 21:26:23' }
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ScriptsDir 'adopt-report.json') -Encoding Ascii

Invoke-Expression $block
Write-Host ''
Write-Host '=== fields the fleet event would carry ===' -ForegroundColor Cyan
foreach ($kv in $f) { Write-Host ('  ' + $kv) }
Write-Host ''
$fail = 0
function Want($pair) {
  if ($f -contains $pair) { Write-Host ('  PASS  ' + $pair) -ForegroundColor Green }
  else { Write-Host ('  FAIL  missing: ' + $pair) -ForegroundColor Red; $script:fail++ }
}
Want 'dbVerdict=BAD'
Want 'dbDamagedPages=33'
Want 'dbDamageFirstSeen=2026-10-19 14:08:18'
Want 'diskVerdict=SUSPECT'
Want 'diskCorruptionEvents=36'
Want 'diskCorruptionFirstSeen=2026-09-27 21:26:23'
Want 'guestAgent=OK'
Want 'guestAgentService=QEMU-GA:Running'
Want 'guestAgentOnArrival=MISSING'
Want 'virtio=DIFFERS'
Want 'virtioPin=0.1.271-1'
Want 'virtioOld=viostor:100.100.100.20800'
Want 'baselineSha256=ABC123DEF456'
Want 'findings=2'
# the driver AT the pin must NOT be reported as old
if (@($f | Where-Object { $_ -like 'virtioOld=balloon*' }).Count -eq 0) { Write-Host '  PASS  a driver at the pin is not reported as old' -ForegroundColor Green }
else { Write-Host '  FAIL  a matching driver was reported as old' -ForegroundColor Red; $fail++ }
# the arrival state must be kept distinct from the now state
if (($f -contains 'guestAgent=OK') -and ($f -contains 'guestAgentOnArrival=MISSING')) {
  Write-Host '  PASS  arrival and current agent state are both carried, and differ' -ForegroundColor Green
} else { Write-Host '  FAIL  arrival/current agent state collapsed' -ForegroundColor Red; $fail++ }

Remove-Item $ScriptsDir -Recurse -Force
Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green; $global:LASTEXITCODE = 0 }
else { Write-Host ([string]$fail + ' CHECK(S) FAILED') -ForegroundColor Red; $global:LASTEXITCODE = 1 }
