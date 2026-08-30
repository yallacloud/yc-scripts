# yc-check.ps1 - read-only post-deploy verification of a YallaCloud clone.
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\yc-check.ps1
# Changes nothing.
#
# NOTE: every value is computed into a variable FIRST and only then emitted.
# The earlier version called  R 'os' $null (Get-CimInstance ...).Caption  and
# printed nothing: in ARGUMENT mode PowerShell does not bind that the way it
# looks, the call failed, and $ErrorActionPreference='SilentlyContinue' hid it.
$ErrorActionPreference = 'SilentlyContinue'
$rows = New-Object System.Collections.ArrayList
function Add-R([string]$name, $ok, $val) {
  $s = if ($ok -eq $null) { 'INFO' } elseif ($ok) { 'PASS' } else { 'FAIL' }
  [void]$rows.Add(('{0,-4}  {1,-22}  {2}' -f $s, $name, $val))
}

$os   = (Get-CimInstance Win32_OperatingSystem).Caption
$name = $env:COMPUTERNAME
Add-R 'os'       $null $os
Add-R 'hostname' ($name -notmatch '^(WIN2019|WIN2016|WIN2022|WIN2025)') $name

# ---- payload provenance ----
$pv = 'C:\Scripts\yc-payload-version.txt'
if (Test-Path $pv) { $v = (Get-Content $pv) -join ' | '; Add-R 'payload' $true $v }
else               { Add-R 'payload' $false 'yc-payload-version.txt MISSING - Install-YcPayload never ran' }
foreach ($f in 'MANIFEST.json','MANIFEST.sha256') {
  $e = Test-Path "C:\Scripts\$f"
  Add-R $f $e $(if ($e) { 'present' } else { 'MISSING' })
}

# ---- catalog ----
$y = Get-Item 'C:\Scripts\Yallacloud.ps1'
if ($y) { $len = $y.Length; Add-R 'catalog' ($len -gt 6000) ("Yallacloud.ps1 = $len bytes ({0})" -f $(if ($len -gt 6000) { 'real' } else { 'STUB' })) }
else    { Add-R 'catalog' $false 'Yallacloud.ps1 missing' }
$yc = Get-Command yallacloud -EA SilentlyContinue
Add-R 'yallacloud on PATH' ([bool]$yc) $(if ($yc) { $yc.Source } else { 'not resolvable' })
$isql = Test-Path 'C:\Scripts\Install-Sql.ps1'
Add-R 'install-sql' $isql $(if ($isql) { 'present' } else { 'absent (needs payload v262)' })
$tpl = @(Get-ChildItem 'C:\Scripts\sql-templates' -File -EA SilentlyContinue).Count
Add-R 'sql-templates' ($tpl -eq 5) "$tpl file(s)"
$ncmd = @(Get-ChildItem 'C:\Scripts' -Filter '*.cmd' -File).Count
Add-R 'catalog .cmd count' ($ncmd -ge 30) $ncmd

# ---- scheduled tasks ----
$want   = 'YC-Boot','YC-Health','YC-KeyGuard'
$have   = @($want   | Where-Object { Get-ScheduledTask -TaskName $_ -EA SilentlyContinue })
$legacy = @('GIGrowDisk','GIDiskGuard','GINetwork','GIWatchdog','YCDEPLOY','YCGUARD','YCGUARD5','YCNET','YCNET5' |
            Where-Object { Get-ScheduledTask -TaskName $_ -EA SilentlyContinue })
Add-R 'yc tasks'          ($have.Count -eq 3)   (($have -join ', ') + " [$($have.Count)/3]")
Add-R 'legacy tasks gone' ($legacy.Count -eq 0) $(if ($legacy) { $legacy -join ', ' } else { 'none present' })
foreach ($t in $have) {
  $ti = Get-ScheduledTaskInfo $t -EA SilentlyContinue
  $r  = $ti.LastTaskResult
  Add-R "  $t" ($r -eq 0 -or $r -eq 267011) "LastResult=$r Last=$($ti.LastRunTime)"
}

# ---- chocolatey ----
$choco = 'C:\ProgramData\chocolatey\bin\choco.exe'
if (Test-Path $choco) {
  $o = @(& $choco list --local-only --limit-output 2>$null)
  if (-not $o.Count) { $o = @(& $choco list --limit-output 2>$null) }
  $installed = @($o | ForEach-Object { ($_ -split '\|')[0] } | Where-Object { $_ })
  $want2 = 'powershell-core','googlechrome','git','python','openssl','vcredist140','vcredist2015','putty','winscp','sysinternals','winrar','everything','7zip'
  $miss  = @($want2 | Where-Object { $installed -notcontains $_ })
  Add-R 'choco 13' ($miss.Count -eq 0) $(if ($miss) { 'MISSING: ' + ($miss -join ', ') } else { 'all 13 present' })
} else { Add-R 'choco' $false 'chocolatey not installed' }

# ---- drivers / agents ----
foreach ($d in 'viostor','vioscsi') {
  $p = "C:\Windows\System32\drivers\$d.sys"
  if (Test-Path $p) {
    $fv = (Get-Item $p).VersionInfo.FileVersion
    $bad = $fv -match '^100\.101\.104\.285'
    Add-R $d ($fv -match '^100\.100\.104\.271') "$fv$(if ($bad) { '  <- 0.1.285 UNSAFE for SQL' })"
  } else { Add-R $d $null 'not bound' }
}
$qga = Get-Service QEMU-GA -EA SilentlyContinue
$cbi = Get-Service cloudbase-init -EA SilentlyContinue
Add-R 'qemu-ga'        ([bool]$qga) $(if ($qga) { $qga.Status } else { 'absent' })
Add-R 'cloudbase-init' ([bool]$cbi) $(if ($cbi) { "$($cbi.Status)/$($cbi.StartType)" } else { 'absent' })

# ---- sysprep / licensing ----
$img = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -EA SilentlyContinue).ImageState
$gs  = (Get-ItemProperty 'HKLM:\SYSTEM\Setup\Status\SysprepStatus' -EA SilentlyContinue).GeneralizationState
Add-R 'imagestate' ($img -eq 'IMAGE_STATE_COMPLETE') "$img (GeneralizationState=$gs)"
$sl = Get-CimInstance SoftwareLicensingService -EA SilentlyContinue
Add-R 'rearm left' ($sl.RemainingWindowsReArmCount -gt 0) $sl.RemainingWindowsReArmCount
$dlv = (& cscript //nologo C:\Windows\System32\slmgr.vbs /dlv 2>&1) -join "`n"
$ls  = if ($dlv -match 'License Status:\s*(\w+)') { $matches[1] } else { 'unknown' }
Add-R 'licence' ($ls -eq 'Licensed') $ls

# ---- access ----
$sshd = Get-Service sshd -EA SilentlyContinue
Add-R 'sshd' ($sshd.Status -eq 'Running') "$($sshd.Status)/$($sshd.StartType)"
$ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
$nk = @(Get-Content $ak -EA SilentlyContinue).Count
Add-R 'ssh keys' ($nk -gt 0) "$nk key(s)"
$l3222 = [bool](Get-NetTCPConnection -LocalPort 3222 -State Listen -EA SilentlyContinue)
Add-R 'port 3222' $l3222 'listening'
$ch = Get-LocalUser chadmin -EA SilentlyContinue
Add-R 'chadmin' ($ch -and $ch.Enabled) $(if ($ch) { "enabled=$($ch.Enabled)" } else { 'MISSING' })
$ul = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList' -EA SilentlyContinue
Add-R 'cloudinitadmin hidden' ($ul.CloudinitAdmin -eq 0) "UserList=$($ul.CloudinitAdmin)"
Add-R 'chadmin visible' (-not ($ul.PSObject.Properties.Name -contains 'chadmin')) 'must NOT be hidden'

# ---- disk / PATH / junk ----
$c = Get-Volume -DriveLetter C
Add-R 'C: volume' $null ('{0:N0} GB total, {1:N0} GB free' -f ($c.Size / 1GB), ($c.SizeRemaining / 1GB))
$mp   = [Environment]::GetEnvironmentVariable('Path','Machine')
$dead = @($mp -split ';' | Where-Object { $_ -and -not (Test-Path $_) })
Add-R 'PATH dead entries' ($dead.Count -eq 0) $(if ($dead) { "$($dead.Count): " + ($dead -join ' ; ') } else { 'none' })
$junk = @()
$nsh = @(Get-ChildItem 'C:\Scripts' -Filter '*.sh' -File).Count; if ($nsh) { $junk += "$nsh .sh" }
$npy = @(Get-ChildItem 'C:\Scripts' -Filter '*.py' -File).Count; if ($npy) { $junk += "$npy .py" }
foreach ($d in '_stage','.done') { if (Test-Path "C:\Scripts\$d") { $junk += $d } }
if (Test-Path 'C:\Scripts\GoldenImage.ps1') { $junk += 'GoldenImage.ps1' }
Add-R 'no build junk' ($junk.Count -eq 0) $(if ($junk) { $junk -join ', ' } else { 'clean' })
$mark = @(Get-ChildItem 'C:\Users\Public\Desktop' -Filter '!*' -Force -EA SilentlyContinue).Count
Add-R 'desktop marker' ($mark -eq 0) "$mark on Public Desktop"
$msmq = Get-Service MSMQ -EA SilentlyContinue
Add-R 'msmq absent' (-not $msmq) $(if ($msmq) { 'INSTALLED' } else { 'absent' })
$sc = @(Get-ChildItem 'C:\Scripts' -Recurse -File -Force -EA SilentlyContinue)
$mb = ($sc | Measure-Object Length -Sum).Sum / 1MB
Add-R 'C:\Scripts' $null ('{0} files, {1:N0} MB' -f $sc.Count, $mb)

# ---- C:\Scripts inventory: what is MISSING ----
# Report only gaps. Anything not listed here was found.
$S = 'C:\Scripts'
$gaps = New-Object System.Collections.ArrayList
function Need($label, $test, $fix) { if (-not $test) { [void]$gaps.Add(('{0,-30} {1}' -f $label, $fix)) } }

# catalog commands - the .cmd wrappers are what put them on PATH
$cmdWant = 'yallacloud','acronis-register','bitdefender-register','wazuh-register','glpi-register',
           'osquery-register','site24x7-register','zabbix-register','snmp-register','salt-register',
           'winexporter-register','telegraf-register','alloy-register','otelcol-register',
           'postgresexporter-register','mysqldexporter-register','sqlexporter-register',
           'dbatools-install','webjea-install','olivetin-install','pgbadger-install',
           'percona-toolkit-install','observability-register','report-inventory','install-sql',
           'activate-windows','activate-sql','defender-exclude','bitdefender-exclude','diag',
           'rootcause','perflog','boot-repair','winupdate','diagtools-install','grow-disk',
           'set-nic','set-firewall','rotate-password','notify'
$cmdMiss = @($cmdWant | Where-Object { -not (Test-Path (Join-Path $S "$_.cmd")) })
Need 'catalog commands' ($cmdMiss.Count -eq 0) ("MISSING {0}: {1}" -f $cmdMiss.Count, ($cmdMiss -join ' '))

# runtime scripts the scheduled tasks / first boot depend on
$rtWant = 'yc-boot.ps1','yc-health.ps1','yc-keyguard.ps1','yc-firstboot.ps1','yc-activate.ps1',
          'SSH-FirstBoot.ps1','Disk-Guard.ps1','Grow-Disk.ps1','Set-Nic.ps1','Root-Cause.ps1','_yc-lib.ps1'
$rtMiss = @($rtWant | Where-Object { -not (Test-Path (Join-Path $S $_)) })
$rtEmpty = @($rtWant | Where-Object { (Test-Path (Join-Path $S $_)) -and (Get-Item (Join-Path $S $_)).Length -eq 0 })
Need 'runtime scripts' ($rtMiss.Count -eq 0) ("MISSING: " + ($rtMiss -join ' '))
Need 'runtime 0-byte'   ($rtEmpty.Count -eq 0) ("EMPTY (as bad as missing): " + ($rtEmpty -join ' '))

# agent installers
$agents = @{
  'wazuh'      = 'wazuh-agent-*.msi'
  'glpi'       = 'GLPI-Agent-*.msi'
  'osquery'    = 'osquery-*.msi'
  'site24x7'   = 'Site24x7WindowsAgent.msi'
  'zabbix'     = 'zabbix_agent2-*.msi'
  'acronis'    = 'CyberProtect_AgentForWindows*.exe'
  'bitdefender'= 'setupdownloader_*.exe'
  'salt'       = 'Salt-Minion-*.exe'
}
$agMiss = @()
foreach ($k in $agents.Keys) { if (-not @(Get-ChildItem $S -Filter $agents[$k] -File -EA SilentlyContinue).Count) { $agMiss += $k } }
Need 'agent installers' ($agMiss.Count -eq 0) ("MISSING: " + ($agMiss -join ' '))

# base installers / media
$instWant = 'virtio-win.iso','virtio-win-guest-tools.exe','qemu-ga-x86_64.msi','OpenSSH-Win64.zip',
            'CloudbaseInitSetup_x64.msi','SysinternalsSuite.zip','putty-64bit.msi','WinSCP-Setup.exe',
            'IISCrypto.exe','vc_redist.x64.exe','PowerShell-win-x64.msi'
$instMiss = @($instWant | Where-Object { -not @(Get-ChildItem $S -Filter $_ -File -EA SilentlyContinue).Count })
Need 'installers/media' ($instMiss.Count -eq 0) ("MISSING: " + ($instMiss -join ' '))

# folders
foreach ($d in 'Day2','DiagTools','Sysinternals','virtio') {
  Need "folder $d" (Test-Path (Join-Path $S $d)) 'MISSING'
}
$dt = @(Get-ChildItem "$S\DiagTools" -Recurse -File -EA SilentlyContinue)
Need 'DiagTools content' ($dt.Count -ge 40) ("only $($dt.Count) files - expect ~45")
foreach ($t in 'testdisk_win.exe','iperf3.exe','smartmontools-setup.exe') {
  Need "  $t" (@(Get-ChildItem "$S\DiagTools" -Recurse -Filter $t -EA SilentlyContinue).Count -gt 0) 'MISSING from DiagTools'
}
$d2 = @(Get-ChildItem "$S\Day2" -File -EA SilentlyContinue).Name
foreach ($f in 'Day2-Setup.ps1','Setup-HealthMonitors.ps1','Setup-Observability.ps1') {
  Need "  Day2\$f" ($d2 -contains $f) 'MISSING from Day2'
}
$vt = @(Get-ChildItem "$S\virtio" -Recurse -Filter '*.sys' -EA SilentlyContinue).Count
Need 'virtio drivers' ($vt -ge 10) "only $vt .sys files"
$pdb = @(Get-ChildItem "$S\virtio" -Recurse -Filter '*.pdb' -EA SilentlyContinue).Count
Need 'virtio .pdb stripped' ($pdb -eq 0) "$pdb .pdb files still present (~53 MB of debug symbols)"

# sql
Need 'sql-templates x5' ($tpl -eq 5) "found $tpl, expect 5"

if ($gaps.Count) {
  [void]$rows.Add('')
  [void]$rows.Add('---- MISSING / MISCONFIGURED ----')
  $gaps | ForEach-Object { [void]$rows.Add($_) }
}

# ---- emit ----
$fail = @($rows | Where-Object { $_ -like 'FAIL*' }).Count
Write-Output ("==== yc-check  {0}  {1} ====" -f $name, (Get-Date -f 'yyyy-MM-dd HH:mm:ss'))
$rows | ForEach-Object { Write-Output $_ }
Write-Output ("==== {0} checks, {1} FAIL ====" -f $rows.Count, $fail)
