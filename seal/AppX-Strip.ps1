# AppX-Strip.ps1  -  RUN THIS TWICE. Second pass must report Remaining: 0.
# Windows PowerShell 5.1 ONLY. Under pwsh 7 the Appx cmdlets proxy through a
# WinPSCompat session and Get-AppxPackage -AllUsers UNDER-REPORTS, so a pass can
# look clean while sysprep still dies 0x8007001f.
if($PSVersionTable.PSEdition -eq 'Core'){
  & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
  exit $LASTEXITCODE
}
# AppX is the #1 cause of sysprep 0x8007001f. Remove-AppxPackage throws
# TERMINATING errors that -ErrorAction does NOT suppress, so every single
# removal is wrapped in its own try/catch or one bad package kills the pass.
$ErrorActionPreference='Continue'
$log='C:\Scripts\appx-strip.log'
function L($m){ $s="[$(Get-Date -f 'HH:mm:ss')] $m"; Write-Host $s; Add-Content $log $s -Encoding ascii }
L '--- AppX strip pass start ---'
$prov=@(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
foreach($p in $prov){
  try{ Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null; L ("deprovisioned "+$p.DisplayName) }
  catch{ L ("skip prov "+$p.DisplayName+" : "+$_.Exception.Message) }
}
$pkgs=@(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { -not $_.NonRemovable })
foreach($p in $pkgs){
  try{ Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
  catch{ try{ Remove-AppxPackage -Package $p.PackageFullName -ErrorAction SilentlyContinue }catch{} }
}
# ZERO IS NOT REACHABLE and never was. Inbox packages (DesktopAppInstaller,
# SecHealthUI) refuse removal outright, and framework packages (VCLibs,
# .NET Native, UI.Xaml) report NonRemovable=false yet always come back.
# What actually breaks sysprep with 0x8007001f is narrower: a package
# INSTALLED FOR A USER but NOT PROVISIONED for all users. Test only that.
$prov  = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object PackageName)
$block = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
           Where-Object { -not $_.NonRemovable -and $prov -notcontains $_.PackageFullName })
$left  = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { -not $_.NonRemovable }).Count
L ("removable per-user: $left   provisioned: $($prov.Count)   NOT-provisioned (the ones that matter): $($block.Count)")
foreach($b in $block){
  $who = ($b.PackageUserInformation | ForEach-Object { "$($_.UserSecurityId.Username)=$($_.InstallState)" }) -join '; '
  L ("   blocker? " + $b.Name + "  [" + $who + "]")
}
if($block.Count -eq 0){ L 'CLEAN - safe to shut down and snapshot' }
else { L 'Review the list above. Only packages belonging to OTHER user profiles stop sysprep.' }
