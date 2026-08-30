<#
  PreSeal-Agents.ps1  -  the "presealagent" step.

  RUN THIS FIRST on a clone booted from the snap02-presealagent snapshot, before
  C1 payload / C2 clean / C3 Fix-PreSeal / C7 seal.

  WHY IT EXISTS
  -------------
  The base golden image is deliberately HYPERVISOR-NEUTRAL: Windows Update, the
  whole app batch, BOTH driver sets and the DEEP disk optimize are all done, but
  NO guest agent is installed. That single snapshot therefore forks to KVM and to
  VMware without repeating the ~4h update+app batch, and without ever having to
  uninstall one vendor's agent to install the other's.

  WHAT IS A DRIVER AND WHAT IS AN AGENT
  -------------------------------------
    DRIVER (already in the base, never touched here):
      virtio INFs (viostor, vioscsi, NetKVM, ...) staged by pnputil
      VMware PVSCSI + VMXNET3 + SVGA, installed by ADDLOCAL=Drivers
    AGENT (installed here, by detected platform):
      KVM    -> qemu-ga.msi  +  virtio-win-guest-tools.exe
      VMware -> VMware-Tools-x64.exe, FULL (guest service), from the same installer

  NOTHING IS EVER DELETED FOR BELONGING TO THE OTHER HYPERVISOR.
  The virtio folder, qemu-ga.msi, virtio-win-guest-tools.exe and
  VMware-Tools-x64.exe stay in C:\Scripts on BOTH platforms. They are one
  infrastructure and a guest must stay migration-friendly in either direction.
  All three boot-critical storage services are left Start=0 on both platforms for
  the same reason.

  USAGE
    PreSeal-Agents.ps1                 detect, install, clean ghosts, zero free space
    PreSeal-Agents.ps1 -WhatIf         detect and report only, change nothing
    PreSeal-Agents.ps1 -Platform kvm   override detection (kvm | vmware)
    PreSeal-Agents.ps1 -SkipZero       skip the free-space zero pass
    PreSeal-Agents.ps1 -Help

  Exit 0 = agents present and verified. Exit 1 = something needs attention.
#>
[CmdletBinding()]
param(
  [ValidateSet('kvm','vmware','auto')][string]$Platform = 'auto',
  [switch]$WhatIf,
  [switch]$SkipZero,
  [switch]$Help
)

$ErrorActionPreference = 'Continue'
$S    = 'C:\Scripts'
$LogF = Join-Path $S 'preseal-agents.log'
$fail = 0

function L($m,$c='Gray'){
  $line = ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
  Write-Host $line -ForegroundColor $c
  try { Add-Content -Path $LogF -Value $line -Encoding ascii } catch {}
}
function Head($t){ Write-Host ''; Write-Host ('== ' + $t + ' ' + ('=' * [Math]::Max(0,60-$t.Length))) -ForegroundColor Cyan; try{ Add-Content $LogF "`r`n== $t ==" -Encoding ascii }catch{} }

if($Help){
  Write-Host @'
PreSeal-Agents.ps1 - install the guest agents for the hypervisor this clone booted on.

  -Platform kvm|vmware|auto   force a platform instead of detecting (default auto)
  -WhatIf                     detect and report only, install nothing
  -SkipZero                   skip the free-space zero pass
  -Help                       this text

Order on a fresh clone:
  PreSeal-Agents.ps1  ->  C1 Install-YcPayload  ->  C2 Clean-Scripts -Apply
  ->  C3 Fix-PreSeal  ->  C4 PATH prune  ->  C5 snapshot  ->  C6 preflight  ->  C7 seal
'@
  exit 0
}

if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  Write-Host 'Run this elevated.' -ForegroundColor Red; exit 1
}

L ('==== PreSeal-Agents on ' + $env:COMPUTERNAME + ' ====') 'White'

# ---------------------------------------------------------------------------
# 1. DETECT THE HYPERVISOR
#    Three independent signals. SMBIOS strings are the primary; PCI vendor IDs
#    are the tie-breaker because they cannot be spoofed by a BIOS rebrand:
#      VEN_15AD = VMware      VEN_1AF4 = Red Hat / virtio
# ---------------------------------------------------------------------------
Head 'Detect'
$detected = $null
try {
  $cs  = Get-CimInstance Win32_ComputerSystem -EA Stop
  $bi  = Get-CimInstance Win32_BIOS           -EA SilentlyContinue
  $mfr = "$($cs.Manufacturer)"; $mdl = "$($cs.Model)"
  $bmf = "$($bi.Manufacturer)"; $bsn = "$($bi.SerialNumber)"
  L ("  Win32_ComputerSystem : Manufacturer='$mfr'  Model='$mdl'")
  L ("  Win32_BIOS           : Manufacturer='$bmf'  SerialNumber='$bsn'")

  if    ($mfr -match 'VMware' -or $mdl -match 'VMware' -or $bsn -match '^VMware') { $detected = 'vmware' }
  elseif($mfr -match 'QEMU|Red\s*Hat' -or $mdl -match 'QEMU|KVM|Standard PC')     { $detected = 'kvm' }
} catch { L ("  SMBIOS query failed: " + $_.Exception.Message) 'Yellow' }

$pciVmw = @(Get-CimInstance Win32_PnPEntity -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -match 'VEN_15AD' }).Count
$pciVio = @(Get-CimInstance Win32_PnPEntity -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -match 'VEN_1AF4' }).Count
L ("  PCI devices          : VMware(VEN_15AD)=$pciVmw   virtio(VEN_1AF4)=$pciVio")
if(-not $detected){
  if($pciVmw -gt 0 -and $pciVio -eq 0){ $detected = 'vmware' }
  elseif($pciVio -gt 0 -and $pciVmw -eq 0){ $detected = 'kvm' }
}

if($Platform -ne 'auto'){
  L ("  DETECTED=$detected  but -Platform $Platform was given - using the override") 'Yellow'
  $plat = $Platform
} elseif($detected){
  $plat = $detected
  L ("  PLATFORM = $plat") 'Green'
} else {
  L '  CANNOT DETECT the hypervisor. Re-run with -Platform kvm  or  -Platform vmware.' 'Red'
  exit 1
}

if($WhatIf){ L ''; L ("-WhatIf: would install the $plat agents. Nothing changed.") 'Yellow'; exit 0 }

# ---------------------------------------------------------------------------
# 2. INSTALL THE AGENTS FOR THIS PLATFORM
# ---------------------------------------------------------------------------
Head ('Install agents  (' + $plat + ')')

if($plat -eq 'kvm'){

  $qi = Join-Path $S 'qemu-ga.msi'
  if(Get-Service 'QEMU-GA','qemu-ga' -EA SilentlyContinue){ L '  qemu-ga already installed - skipping' 'Green' }
  elseif(Test-Path $qi){
    L '  installing qemu-ga...'
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$qi`" /qn /norestart" -Wait -PassThru
    if($p.ExitCode -in 0,3010){ L ("  qemu-ga installed (exit " + $p.ExitCode + ")") 'Green' }
    else { L ("  qemu-ga FAILED exit " + $p.ExitCode) 'Red'; $fail++ }
  } else { L "  MISSING $qi" 'Red'; $fail++ }

  $gt = Join-Path $S 'virtio-win-guest-tools.exe'
  if(Get-Service 'BalloonService' -EA SilentlyContinue){ L '  virtio guest-tools already installed - skipping' 'Green' }
  elseif((Test-Path $gt) -and ((Get-Item $gt).Length -ge 1MB)){
    L '  installing virtio-win-guest-tools...'
    $p = Start-Process $gt -ArgumentList '/install /quiet /norestart' -Wait -PassThru
    if($p.ExitCode -in 0,3010){ L ("  virtio guest-tools installed (exit " + $p.ExitCode + ")") 'Green' }
    else { L ("  virtio guest-tools exit " + $p.ExitCode + " - check manually") 'Yellow' }
  } else { L "  MISSING $gt" 'Red'; $fail++ }

} else {

  # FULL VMware Tools = the guest service. The PVSCSI/VMXNET3/SVGA drivers are
  # already in the base from ADDLOCAL=Drivers, so this only adds the service layer.
  $vt = Join-Path $S 'VMware-Tools-x64.exe'
  if(Get-Service 'VMTools' -EA SilentlyContinue){ L '  VMware Tools already installed - skipping' 'Green' }
  elseif((Test-Path $vt) -and ((Get-Item $vt).Length -ge 50MB)){
    L '  installing FULL VMware Tools (guest service)...'
    $p = Start-Process $vt -ArgumentList '/S /v "/qn REBOOT=R"' -Wait -PassThru
    if($p.ExitCode -in 0,3010){ L ("  VMware Tools installed (exit " + $p.ExitCode + ")") 'Green' }
    else { L ("  VMware Tools FAILED exit " + $p.ExitCode) 'Red'; $fail++ }
  } else { L "  MISSING or truncated $vt" 'Red'; $fail++ }
}

# ---------------------------------------------------------------------------
# 3. KEEP EVERY BOOT-CRITICAL STORAGE DRIVER Start=0 ON BOTH PLATFORMS
#    This is what makes the image migration-friendly. A driver whose hardware is
#    absent costs nothing at boot; a driver that is NOT boot-start is a 0x7B the
#    day the disk moves to the other stack.
# ---------------------------------------------------------------------------
Head 'Boot-critical storage services (both stacks, deliberately)'

# pnputil /add-driver /install only STAGES the INF. Windows creates the service key and
# copies the .sys to System32\drivers when the device BINDS - which never happens for
# virtio on an ESXi build, or for pvscsi on a KVM build. Injected is not boot-ready, and
# the Start=0 loop below can only fix keys that already exist. Enable-VirtioBoot.ps1
# registers viostor/vioscsi offline so the disk can move to a virtio controller without
# a 0x7B. Runs on BOTH branches - a VMware clone must stay migration-friendly too.
$evb = Join-Path $S 'Enable-VirtioBoot.ps1'
if(Test-Path $evb){
  L '  running Enable-VirtioBoot.ps1 (offline virtio boot registration)...'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $evb | ForEach-Object { L ("    " + $_) }
  if($LASTEXITCODE -ne 0){ L '  Enable-VirtioBoot reported problems - see above' 'Yellow'; $fail++ }
} else { L '  Enable-VirtioBoot.ps1 NOT PRESENT - virtio will not be boot-ready on this image' 'Yellow' }

foreach($svc in 'viostor','vioscsi','pvscsi','storahci'){
  $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
  if(Test-Path $k){
    try { Set-ItemProperty $k -Name Start -Value 0 -EA Stop; L ("  $svc Start=0") 'Green' }
    catch { L ("  $svc could not be set: " + $_.Exception.Message) 'Yellow' }
  } else { L ("  $svc service key absent (driver not installed on this OS)") 'Yellow' }
}

# ---------------------------------------------------------------------------
# 4. GHOST DEVICES
#    A clone that booted on the other hypervisor leaves phantom NICs and storage
#    nodes behind. sysprep /generalize clears most of it; this makes it tidy and
#    keeps Device Manager honest.
# ---------------------------------------------------------------------------
Head 'Ghost devices'
$g = 0
try {
  Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.Status -eq 'Unknown' } | ForEach-Object {
    try { & "$env:WINDIR\System32\pnputil.exe" /remove-device $_.InstanceId 2>$null | Out-Null; $g++ } catch {}
  }
} catch {}
L ("  removed $g ghost device(s)")

# ---------------------------------------------------------------------------
# 5. LIGHT ZERO PASS
#    The heavy work (DISM /StartComponentCleanup /ResetBase + defrag) already ran
#    in the base BEFORE the snapshot and is NOT repeated - that is the whole point.
#    The agent install above dirtied a few hundred MB, so a zero-only pass restores
#    compression. ~3 minutes, versus ~40 for the full optimize.
# ---------------------------------------------------------------------------
Head 'Zero free space (light)'
if($SkipZero){ L '  skipped (-SkipZero)' 'Yellow' }
else {
  $sd = Get-ChildItem $S -Recurse -Filter 'sdelete64.exe' -EA SilentlyContinue | Select-Object -First 1
  if($sd){
    L '  zeroing free space...'
    Push-Location C:\ ; & $sd.FullName -accepteula -z C: | Out-Null ; Pop-Location
    L '  zero-fill done' 'Green'
  } else { L '  sdelete64.exe not found under C:\Scripts - skipped' 'Yellow' }
}

# ---------------------------------------------------------------------------
# 6. VERIFY
# ---------------------------------------------------------------------------
Head 'Verify'
$expect = if($plat -eq 'kvm'){ @('QEMU-GA') } else { @('VMTools') }
foreach($n in $expect){
  if(Get-Service $n -EA SilentlyContinue){ L ("  service $n present") 'Green' }
  else { L ("  service $n MISSING") 'Red'; $fail++ }
}
foreach($f in 'qemu-ga.msi','virtio-win-guest-tools.exe','VMware-Tools-x64.exe'){
  if(Test-Path (Join-Path $S $f)){ L ("  kept for migration: $f") 'Green' }
  else { L ("  NOT KEPT: $f  - the guest is no longer migration-friendly") 'Yellow' }
}
if(Test-Path (Join-Path $S 'virtio')){ L '  kept for migration: virtio\' 'Green' }
else { L '  NOT KEPT: virtio\' 'Yellow' }

Write-Host ''
if($fail -eq 0){
  L 'PRESEALAGENT STEP OK. Next: Install-YcPayload -> Clean-Scripts -Apply -> Fix-PreSeal -> PATH prune -> snapshot -> preflight -> seal.' 'Green'
  exit 0
} else {
  L ("PRESEALAGENT STEP: $fail problem(s) above. Fix before sealing.") 'Red'
  exit 1
}
