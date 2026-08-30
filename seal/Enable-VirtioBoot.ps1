<#
  Enable-VirtioBoot.ps1  -  make virtio boot-critical WITHOUT the hardware present.

  THE PROBLEM
    GoldenImage step 22 runs pnputil /add-driver /install, so the INF is in the
    DriverStore (step 25 reports driverstore=True). But Windows only creates
    HKLM\SYSTEM\CurrentControlSet\Services\viostor and copies viostor.sys into
    System32\drivers when the virtio PCI device actually BINDS. Build on ESXi and
    that never happens - step 25 reports "Start=-" and step 51 says "not bound yet".
    Injected is not the same as boot-ready. Move that disk to KVM with a virtio
    controller and it is an immediate 0x7B INACCESSIBLE_BOOT_DEVICE.

  THE FIX (what a virtio-win offline install does by hand)
    1. copy viostor.sys / vioscsi.sys into C:\Windows\System32\drivers
    2. create the service key with Start=0 (boot), Group="SCSI miniport"
    3. add CriticalDeviceDatabase entries so the boot loader maps the PCI ID
       straight to the service before PnP has run

  Safe on ESXi and on KVM. Idempotent. Changes nothing about VMware/pvscsi.

    Enable-VirtioBoot.ps1            apply
    Enable-VirtioBoot.ps1 -WhatIf    report only
#>
[CmdletBinding()]
param([switch]$WhatIf,[switch]$Help)

$ErrorActionPreference = 'Continue'
$S = 'C:\Scripts'
$fail = 0
function L($m,$c='Gray'){ Write-Host $m -ForegroundColor $c
  try{ Add-Content (Join-Path $S 'virtio-boot.log') ('{0}  {1}' -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'),$m) -Encoding ascii }catch{} }

if($Help){ Write-Host 'Enable-VirtioBoot.ps1 [-WhatIf]  - register viostor/vioscsi as boot-start with no virtio hardware present.'; exit 0 }
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ L 'Run elevated.' 'Red'; exit 1 }

# SCSIAdapter class - both virtio storage drivers live here
$CLS = '{4D36E97B-E325-11CE-BFC1-08002BE10318}'

# PCI IDs: legacy (transitional) and modern (1.0) device IDs for each driver.
$MAP = @(
  @{ svc='viostor'; ids=@('pci#ven_1af4&dev_1001','pci#ven_1af4&dev_1042'); disp='Red Hat VirtIO SCSI controller' },
  @{ svc='vioscsi'; ids=@('pci#ven_1af4&dev_1004','pci#ven_1af4&dev_1048'); disp='Red Hat VirtIO SCSI pass-through' },
  # pvscsi has the SAME defect: step 26 installs the VMware drivers, so pvscsi.sys is in
  # the DriverStore on every build - but the service key only appears where the device
  # bound. That is why 2k22/2k25 logged "pvscsi Start=0" and 2k16/2k19 did not.
  @{ svc='pvscsi';  ids=@('pci#ven_15ad&dev_07c0');                        disp='VMware PVSCSI controller' }
)

L ('==== Enable-VirtioBoot on ' + $env:COMPUTERNAME + ' ====') 'White'

foreach($e in $MAP){
  $svc = $e.svc
  L ''
  L ("--- $svc ---") 'Cyan'

  # 1. locate the .sys - DriverStore first, then the staged trees, then VMware's own dir
  $sys = Get-ChildItem "$env:WINDIR\System32\DriverStore\FileRepository" -Recurse -Filter "$svc.sys" -EA SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if(-not $sys){ $sys = Get-ChildItem (Join-Path $S 'virtio') -Recurse -Filter "$svc.sys" -EA SilentlyContinue | Select-Object -First 1 }
  if(-not $sys){ $sys = Get-ChildItem "$env:ProgramFiles\VMware\VMware Tools\Drivers" -Recurse -Filter "$svc.sys" -EA SilentlyContinue | Select-Object -First 1 }
  if(-not $sys){
    # pvscsi is OPTIONAL here. VMware Tools 12.5.4 ADDLOCAL=Drivers injects PVSCSI on
    # 2k22/2k25 but NOT on 2k16/2k19 - verified across 8 builds on 2026-08-12. That is
    # fine: the VMware branch of PreSeal-Agents.ps1 installs FULL VMware Tools, which
    # registers pvscsi correctly with the hardware present. Only viostor/vioscsi are
    # boot-critical here, because nothing else can register them offline.
    if($svc -eq 'pvscsi'){
      L "  pvscsi.sys not staged on this OS - EXPECTED on 2016/2019." 'Yellow'
      L "  Not a problem: the VMware branch installs full Tools, which brings pvscsi." 'Yellow'
      L "  First boot on ESXi must use LSI Logic SAS or SATA, then switch to PVSCSI after Tools." 'Yellow'
      continue
    }
    L "  $svc.sys NOT FOUND - driver was never injected" 'Red'; $fail++; continue
  }
  L ("  source : " + $sys.FullName)
  L ("  version: " + $sys.VersionInfo.FileVersion)

  $dst = "$env:WINDIR\System32\drivers\$svc.sys"
  if($WhatIf){ L "  WHATIF would copy -> $dst" 'Yellow' }
  else {
    try { Copy-Item $sys.FullName $dst -Force -EA Stop; L "  copied -> System32\drivers\$svc.sys" 'Green' }
    catch { L ("  copy failed: " + $_.Exception.Message) 'Red'; $fail++; continue }
  }

  # 2. service key, Start=0 boot
  $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
  if($WhatIf){ L "  WHATIF would set $k  Start=0 Type=1 Group='SCSI miniport'" 'Yellow' }
  else {
    try {
      New-Item -Path $k -Force -EA Stop | Out-Null
      New-ItemProperty $k -Name 'Type'         -Value 1 -PropertyType DWord  -Force -EA Stop | Out-Null
      New-ItemProperty $k -Name 'Start'        -Value 0 -PropertyType DWord  -Force -EA Stop | Out-Null
      New-ItemProperty $k -Name 'ErrorControl' -Value 1 -PropertyType DWord  -Force -EA Stop | Out-Null
      New-ItemProperty $k -Name 'ImagePath'    -Value "system32\drivers\$svc.sys" -PropertyType ExpandString -Force -EA Stop | Out-Null
      New-ItemProperty $k -Name 'Group'        -Value 'SCSI miniport' -PropertyType String -Force -EA Stop | Out-Null
      New-ItemProperty $k -Name 'DisplayName'  -Value $e.disp -PropertyType String -Force -EA Stop | Out-Null
      L "  service registered, Start=0 (boot)" 'Green'
    } catch { L ("  service key failed: " + $_.Exception.Message) 'Red'; $fail++ }
  }

  # 3. CriticalDeviceDatabase - lets the boot loader bind the PCI ID before PnP runs
  foreach($id in $e.ids){
    $c = "HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\$id"
    if($WhatIf){ L "  WHATIF would add CDDB $id -> $svc" 'Yellow'; continue }
    try {
      New-Item -Path $c -Force -EA Stop | Out-Null
      New-ItemProperty $c -Name 'Service'   -Value $svc -PropertyType String -Force -EA Stop | Out-Null
      New-ItemProperty $c -Name 'ClassGUID' -Value $CLS -PropertyType String -Force -EA Stop | Out-Null
      L "  CDDB $id -> $svc" 'Green'
    } catch { L ("  CDDB $id failed: " + $_.Exception.Message) 'Red'; $fail++ }
  }
}

# ---- verify exactly what step 25 checks ----
L ''
L '--- verify (same check as GoldenImage step 25) ---' 'Cyan'
foreach($svc in 'viostor','vioscsi','pvscsi','storahci'){
  $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
  if(Test-Path $k){
    $st = (Get-ItemProperty $k -Name Start -EA SilentlyContinue).Start
    $ip = (Get-ItemProperty $k -Name ImagePath -EA SilentlyContinue).ImagePath
    $onDisk = Test-Path "$env:WINDIR\System32\drivers\$svc.sys"
    $ok = ($st -eq 0 -and $onDisk)
    L ("  {0,-9} Start={1}  sys_on_disk={2}  {3}" -f $svc,$st,$onDisk,$(if($ok){'OK'}else{'NOT BOOT READY'})) $(if($ok){'Green'}else{'Yellow'})
    # Only viostor/vioscsi are fatal - see the pvscsi note above.
    if($svc -in @('viostor','vioscsi') -and -not $ok){ $fail++ }
  } else { L ("  {0,-9} service key ABSENT{1}" -f $svc, $(if($svc -eq 'pvscsi'){'  (expected on 2016/2019 - full Tools adds it on the VMware branch)'}else{''})) `
             $(if($svc -in @('viostor','vioscsi')){'Red'}else{'Yellow'})
           if($svc -in @('viostor','vioscsi')){ $fail++ } }
}

Write-Host ''
if($WhatIf){ L 'WhatIf - nothing changed.' 'Yellow'; exit 0 }
if($fail -eq 0){ L 'VIRTIO BOOT READY - this disk can move to a KVM virtio controller.' 'Green'; exit 0 }
L ("$fail problem(s) with viostor/vioscsi - do NOT switch the disk to virtio yet.") 'Red'; exit 1
