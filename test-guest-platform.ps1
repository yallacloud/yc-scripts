# Proves the guest-platform checks: the pin is read from the payload's own manifest (and says so
# when it cannot be), a stopped agent reads STOPPED rather than present, and the loud banner fires
# ONLY when something is wrong - a banner that fires on a healthy machine trains people to skip it.
param(
  [string]$Script     = 'C:\Scripts\Adopt-MigratedVm.ps1',
  [string]$PayloadDir = 'C:\Scripts'
)
if (-not (Test-Path -LiteralPath $Script)) {
  Write-Host ('cannot find the script under test: ' + $Script) -ForegroundColor Red
  Write-Host 'pass -Script <path> and -PayloadDir <dir with MANIFEST.json>.'
  return
}
$src = Get-Content -LiteralPath $Script -Raw
function Grab([string]$n) {
  $i = $src.IndexOf('function ' + $n + ' {')
  if ($i -lt 0) { throw ('not found: ' + $n) }
  $j = $src.IndexOf("`nfunction ", $i + 10)
  if ($j -lt 0) { $j = $src.Length }
  return $src.Substring($i, $j - $i)
}
$script:VirtioPinFileVersion = '100.100.104.27100'
$script:VirtioDrivers = @('viostor','vioscsi','netkvm','balloon','vioser')
$ScriptsDir = $PayloadDir
$QemuGaMsi = ''
$SkipGuestAgent = $true
$script:Flags = @()
function L { param($m,$l='INFO') Write-Host ('    [' + $l + '] ' + $m) }
function Flag { param($p,$w) $script:Flags += ($p + ': ' + $w) }
foreach ($fn in @('Write-LoudBanner','Get-VirtioPin','Get-GuestAgentState','Get-VirtioState','Write-GuestPlatformLoud')) {
  Invoke-Expression (Grab $fn)
}
$fail = 0
function Check($what,$got,$want) {
  if ($got -eq $want) { Write-Host ('  PASS  ' + $what + ' = ' + $got) -ForegroundColor Green }
  else { Write-Host ('  FAIL  ' + $what + ' = ' + $got + '  (expected ' + $want + ')') -ForegroundColor Red; $script:fail++ }
}

Write-Host '=== 1. the pin, read from the payload MANIFEST.json ===' -ForegroundColor Cyan
$pin = Get-VirtioPin
Write-Host ('  package     : ' + $pin.package)
Write-Host ('  fileVersion : ' + $pin.fileVersion)
Write-Host ('  source      : ' + $pin.source)
Check 'pin came from the manifest' $pin.source 'MANIFEST.json'
Check 'pinned package' $pin.package '0.1.271-1'

Write-Host ''
Write-Host '=== 2. the pin with NO manifest - must fall back and SAY SO ===' -ForegroundColor Cyan
$ScriptsDir = (Join-Path $env:TEMP 'no-such-dir-xyz')
$pin2 = Get-VirtioPin
Write-Host ('  package     : ' + $pin2.package)
Write-Host ('  source      : ' + $pin2.source)
Check 'fallback names itself' $pin2.source 'built-in constant'
Check 'fallback package says manifest unreadable' $pin2.package '0.1.271-1 (manifest unreadable)'
$ScriptsDir = $PayloadDir

Write-Host ''
Write-Host '=== 3. this machine, measured for real ===' -ForegroundColor Cyan
$g = Get-GuestAgentState
Write-Host ('  agent installed : ' + $g.installed + '   service: [' + $g.service + ']   status: ' + $g.status)
Write-Host ('  agent verdict   : ' + $g.verdict + ' - ' + $g.why)
$v = Get-VirtioState
Write-Host ('  virtio present  : ' + $v.present + '   drivers found: ' + @($v.drivers).Count)
foreach ($r in @($v.drivers)) { Write-Host ('      ' + $r.driver + '  ' + $r.fileVersion + '  ' + $r.state) }
Write-Host ('  virtio verdict  : ' + $v.verdict + ' - ' + $v.why)
if ($g.installed -and $g.status -ne 'Running') { Check 'a present-but-stopped agent reads STOPPED' $g.verdict 'STOPPED' }
if (-not $g.installed) { Check 'no agent reads MISSING' $g.verdict 'MISSING' }
if (-not $v.present) { Check 'no virtio reads NOT-VIRTIO' $v.verdict 'NOT-VIRTIO' }

Write-Host ''
Write-Host '=== 4. a healthy pair must stay QUIET (no banner, no flags) ===' -ForegroundColor Cyan
$script:Flags = @()
$okG = [ordered]@{ agent='qemu-guest-agent'; verdict='OK'; why='installed and running (QEMU-GA, start type Auto)'; service='QEMU-GA'; status='Running'; installed=$true; running=$true; startType='Auto'; version='110.0.2' }
$okV = [ordered]@{ verdict='OK'; why='all 5 virtio driver(s) are at the pinned version 0.1.271-1'; present=$true; pinPackage='0.1.271-1'; pinFileVersion='100.100.104.27100'; drivers=@() }
Write-GuestPlatformLoud -State ([ordered]@{ platform='KVM'; platformWhy='test'; manufacturer='QEMU'; model='Standard PC'; expectedAgent='qemu-guest-agent'; agent=$okG; virtio=$okV; leftovers=@() })
Check 'healthy pair raises no flags' @($script:Flags).Count 0

Write-Host ''
Write-Host '=== 5. a STOPPED agent and an OLD virtio must go LOUD and flag ===' -ForegroundColor Cyan
$script:Flags = @()
$badG = [ordered]@{ agent='qemu-guest-agent'; verdict='STOPPED'; why='installed but NOT RUNNING (QEMU-GA is Stopped).'; service='QEMU-GA'; status='Stopped'; installed=$true; running=$false; startType='Disabled'; version='110.0.2' }
$badV = [ordered]@{ verdict='DIFFERS'; why='2 of 5 virtio driver(s) are NOT at the pinned version 0.1.271-1.'
                    present=$true; pinPackage='0.1.271-1'; pinFileVersion='100.100.104.27100'
                    drivers=@([ordered]@{ driver='viostor'; fileVersion='100.100.100.20800'; state='DIFFERS-FROM-PIN' },
                              [ordered]@{ driver='netkvm';  fileVersion='100.100.100.20800'; state='DIFFERS-FROM-PIN' },
                              [ordered]@{ driver='balloon'; fileVersion='100.100.104.27100'; state='MATCHES-PIN' }) }
Write-GuestPlatformLoud -State ([ordered]@{ platform='KVM'; platformWhy='test'; manufacturer='QEMU'; model='Standard PC'; expectedAgent='qemu-guest-agent'; agent=$badG; virtio=$badV; leftovers=@() })
Check 'bad pair raises 2 flags' @($script:Flags).Count 2
$hasAgent  = [bool](@($script:Flags) | Where-Object { $_ -match 'QEMU-GUEST-AGENT|GUEST AGENT' })
$hasVirtio = [bool](@($script:Flags) | Where-Object { $_ -match 'VIRTIO' })
Check 'the agent flag is there'  $hasAgent  $true
Check 'the virtio flag is there' $hasVirtio $true

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green; $global:LASTEXITCODE = 0 }
else { Write-Host ([string]$fail + ' CHECK(S) FAILED') -ForegroundColor Red; $global:LASTEXITCODE = 1 }
