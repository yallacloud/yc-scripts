# yc-id.ps1 - identity proof. Two clones from one template MUST differ here.
$cs   = Get-CimInstance Win32_ComputerSystemProduct
$os   = Get-CimInstance Win32_OperatingSystem
$adm  = Get-LocalUser -Name Administrator -EA SilentlyContinue
$msid = if ($adm) { ($adm.SID.Value -replace '-500$','') } else { 'n/a' }
$nic  = Get-NetAdapter -Physical -EA SilentlyContinue | Select-Object -First 1
$ip   = (Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
         Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | Select-Object -First 1).IPAddress
'hostname     : ' + $env:COMPUTERNAME
'smbios uuid  : ' + $cs.UUID
'machine sid  : ' + $msid
'install date : ' + $os.InstallDate
'last boot    : ' + $os.LastBootUpTime
'mac          : ' + $nic.MacAddress
'ipv4         : ' + $ip
'imagestate   : ' + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -EA SilentlyContinue).ImageState
'cbi log      : ' + $(if (Test-Path 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log') {
                        (Get-Item 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log').Length.ToString() + ' bytes' }
                      else { 'no log' })
