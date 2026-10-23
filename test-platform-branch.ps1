# Proves the platform branch. The trap it is built against: VMware Tools reports 4 version parts
# (13.1.0.24696) while the manifest pins 3 (13.1.0), so a naive compare reads every VMware guest
# as OLDER-THAN-PIN forever; and Tools 13.x dropped Server 2012R2, so a 2012R2 guest pinned to
# 13.x could never satisfy it.
param([string]$Script, [string]$PayloadDir = 'C:\Scripts')
$src = Get-Content -LiteralPath $Script -Raw
function Grab([string]$n){ $i=$src.IndexOf('function '+$n+' {'); if($i -lt 0){throw "not found: $n"}; $j=$src.IndexOf("`nfunction ",$i+10); if($j -lt 0){$j=$src.Length}; $src.Substring($i,$j-$i) }
$ScriptsDir = $PayloadDir
$script:VirtioPinFileVersion='100.100.104.27100'
$script:VirtioDrivers=@('viostor','vioscsi','netkvm','balloon','vioser')
$script:VMwareDrivers=@('pvscsi','vmxnet3','vmci','vmmemctl','vmmouse','vsock')
$script:Flags=@()
function L { param($m,$l='INFO') }
function Flag { param($p,$w) $script:Flags += $w }
foreach ($fn in @('Get-GuestPlatformKind','Get-VirtioPin','Get-VMwareToolsPin','Compare-VersionLoose',
                  'Get-ServiceStateSafe','Get-GuestAgentState','Get-VMwareToolsState','Get-VirtioState',
                  'Get-PlatformToolingState','Write-GuestPlatformLoud')) { Invoke-Expression (Grab $fn) }
$fail=0
function Check($what,$got,$want){ if("$got" -eq "$want"){Write-Host "  PASS  $what = $got" -ForegroundColor Green}else{Write-Host "  FAIL  $what = $got (expected $want)" -ForegroundColor Red; $script:fail++} }

Write-Host '=== 1. detection on THIS machine ===' -ForegroundColor Cyan
$p = Get-GuestPlatformKind
Write-Host ('  kind         : ' + $p.kind)
Write-Host ('  manufacturer : ' + $p.manufacturer)
Write-Host ('  model        : ' + $p.model)
Write-Host ('  bios         : ' + $p.bios)
Write-Host ('  why          : ' + $p.why)
if ($p.kind -eq 'UNKNOWN') { Write-Host '  FAIL  detection returned UNKNOWN on a real machine' -ForegroundColor Red; $fail++ }
else { Write-Host '  PASS  detection produced a kind' -ForegroundColor Green }

Write-Host ''
Write-Host '=== 2. version compare - the 4-part vs 3-part trap ===' -ForegroundColor Cyan
Check 'VMware 13.1.0.24696 vs pin 13.1.0'   (Compare-VersionLoose -Have '13.1.0.24696' -Want '13.1.0')  0
Check '12.5.4.9999 vs pin 13.1.0 is OLDER'  (Compare-VersionLoose -Have '12.5.4.9999'  -Want '13.1.0') -1
Check '13.5.0 vs pin 13.1.0 is NEWER'       (Compare-VersionLoose -Have '13.5.0'       -Want '13.1.0')  1
Check '12.5.4 vs pin 12.5.4 is SAME'        (Compare-VersionLoose -Have '12.5.4'       -Want '12.5.4')  0
Check 'garbage vs pin is not comparable'    (Compare-VersionLoose -Have 'abc'          -Want '13.1.0') 99
Check 'empty vs pin is not comparable'      (Compare-VersionLoose -Have ''             -Want '13.1.0') 99
Check '13.0.9 vs pin 13.1.0 is OLDER'       (Compare-VersionLoose -Have '13.0.9'       -Want '13.1.0') -1

Write-Host ''
Write-Host '=== 3. the VMware Tools pin follows the OS ===' -ForegroundColor Cyan
$pin = Get-VMwareToolsPin
Write-Host ('  this OS -> track ' + $pin.track + ', pin ' + $pin.package + ' (from ' + $pin.source + ')')
Write-Host ('  reason  : ' + $pin.reason)
if ($pin.source -eq 'MANIFEST.json') { Write-Host '  PASS  pin came from the manifest' -ForegroundColor Green }
else { Write-Host ('  NOTE  pin fell back to the constant (no manifest at ' + $ScriptsDir + ') - that path is allowed') -ForegroundColor Yellow }
if (-not $pin.package) { Write-Host '  FAIL  no pin at all' -ForegroundColor Red; $fail++ }

Write-Host ''
Write-Host '=== 4. KVM guest carrying leftover VMware Tools (the TS_BM_FD_DB01 shape) ===' -ForegroundColor Cyan
function Get-GuestPlatformKind { [ordered]@{kind='KVM';manufacturer='QEMU';model='Standard PC (i440FX + PIIX, 1996)';bios='SeaBIOS';why='test'} }
function Get-GuestAgentState  { [ordered]@{platform='KVM';agent='qemu-guest-agent';installed=$false;service='';status='absent';startType='';version='';running=$false;verdict='MISSING';why='no QEMU guest agent service on this machine'} }
function Get-VMwareToolsState { [ordered]@{platform='VMWARE';agent='VMware Tools';installed=$true;service='VMTools';status='Stopped';startType='Manual';version='12.5.4.1234';running=$false;pinPackage='13.1.0';pinTrack='current';pinSource='MANIFEST.json';pinReason='build 20348';versusPin='OLDER-THAN-PIN';drivers=@('vmci');verdict='STOPPED';why='installed but NOT RUNNING'} }
function Get-VirtioState      { [ordered]@{pinPackage='0.1.271-1';pinFileVersion='x';pinSource='MANIFEST.json';present=$true;verdict='OK';why='all 4 at pin';drivers=@([ordered]@{driver='viostor';fileVersion='x';state='MATCHES-PIN'})} }
$st = Get-PlatformToolingState
Check 'platform' $st.platform 'KVM'
Check 'expected agent' $st.expectedAgent 'qemu-guest-agent'
Check 'the agent reported is the KVM one' $st.agent.agent 'qemu-guest-agent'
Check 'virtio still judged on KVM' $st.virtio.verdict 'OK'
Check 'the stale VMware Tools is a leftover' @($st.leftovers).Count 1
if (@($st.leftovers)[0] -notmatch 'VMware Tools is installed on a KVM guest') { Write-Host '  FAIL  leftover text wrong' -ForegroundColor Red; $fail++ } else { Write-Host '  PASS  leftover names VMware Tools on KVM' -ForegroundColor Green }
Check 'overall needs attention' $st.verdict 'NEEDS-ATTENTION'

Write-Host ''
Write-Host '=== 5. a real VMware guest, Tools running but OLD ===' -ForegroundColor Cyan
function Get-GuestPlatformKind { [ordered]@{kind='VMWARE';manufacturer='VMware, Inc.';model='VMware20,1';bios='VMware, Inc.';why='test'} }
function Get-GuestAgentState  { [ordered]@{platform='KVM';agent='qemu-guest-agent';installed=$false;service='';status='absent';startType='';version='';running=$false;verdict='MISSING';why='none'} }
function Get-VMwareToolsState { [ordered]@{platform='VMWARE';agent='VMware Tools';installed=$true;service='VMTools';status='Running';startType='Auto';version='12.5.4.1234';running=$true;pinPackage='13.1.0';pinTrack='current';pinSource='MANIFEST.json';pinReason='build 20348';versusPin='OLDER-THAN-PIN';drivers=@('pvscsi','vmxnet3');verdict='OLD';why='running but older than pin'} }
function Get-VirtioState      { [ordered]@{pinPackage='0.1.271-1';pinFileVersion='x';pinSource='MANIFEST.json';present=$false;verdict='NOT-VIRTIO';why='none';drivers=@()} }
$st2 = Get-PlatformToolingState
Check 'platform' $st2.platform 'VMWARE'
Check 'expected agent' $st2.expectedAgent 'VMware Tools'
Check 'the agent reported is VMware Tools' $st2.agent.agent 'VMware Tools'
Check 'virtio is NOT judged on VMware' $st2.virtio.verdict 'NOT-APPLICABLE'
Check 'no leftovers when nothing stale' @($st2.leftovers).Count 0
Check 'OLD counts as needing attention' $st2.verdict 'NEEDS-ATTENTION'

Write-Host ''
Write-Host '=== 6. a healthy VMware guest must be QUIET ===' -ForegroundColor Cyan
function Get-VMwareToolsState { [ordered]@{platform='VMWARE';agent='VMware Tools';installed=$true;service='VMTools';status='Running';startType='Auto';version='13.1.0.24696';running=$true;pinPackage='13.1.0';pinTrack='current';pinSource='MANIFEST.json';pinReason='build 20348';versusPin='MATCHES-PIN';drivers=@('pvscsi','vmxnet3');verdict='OK';why='installed and running'} }
$script:Flags=@()
$st3 = Get-PlatformToolingState
Write-GuestPlatformLoud -State $st3
Check 'healthy VMware guest overall' $st3.verdict 'OK'
Check 'healthy VMware guest raises no flags' @($script:Flags).Count 0

Write-Host ''
Write-Host '=== 7. Hyper-V / physical: report, claim nothing ===' -ForegroundColor Cyan
function Get-GuestPlatformKind { [ordered]@{kind='HYPERV';manufacturer='Microsoft Corporation';model='Virtual Machine';bios='Microsoft Corporation';why='test'} }
function Get-VMwareToolsState { [ordered]@{platform='VMWARE';agent='VMware Tools';installed=$false;service='';status='absent';startType='';version='';running=$false;pinPackage='13.1.0';pinTrack='current';pinSource='x';pinReason='x';versusPin='unknown';drivers=@();verdict='MISSING';why='none'} }
$script:Flags=@()
$st4 = Get-PlatformToolingState
Check 'platform' $st4.platform 'HYPERV'
Check 'agent verdict is NOT-APPLICABLE' $st4.agent.verdict 'NOT-APPLICABLE'
Check 'virtio NOT-APPLICABLE' $st4.virtio.verdict 'NOT-APPLICABLE'
Check 'overall OK - nothing claimed' $st4.verdict 'OK'
Write-GuestPlatformLoud -State $st4
Check 'no flags raised on an unsupported platform' @($script:Flags).Count 0

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green; $global:LASTEXITCODE=0 }
else { Write-Host ([string]$fail + ' CHECK(S) FAILED') -ForegroundColor Red; $global:LASTEXITCODE=1 }
