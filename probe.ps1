<#
================================================================================================
  YALLACLOUD - READ-ONLY PROBE.  Safe to run on a customer production server.

  WHAT IT IS FOR
    Collecting the evidence needed to finish and prove the migrated-vm SQL work, from a real
    SQL Server, without changing one thing on that server.

  WHAT IT WRITES
    ONE file, on the Desktop of whoever runs it (or %TEMP% if there is no Desktop):
        yc-probe-<HOST>-<timestamp>.txt
    Nothing else. No C:\Scripts, no installs, no registry writes, no scheduled tasks, no SQL
    writes, no DBCC, no backup, no service restart, no reboot.

  WHAT IT NEVER COLLECTS
    No passwords. No connection strings. No product keys - not even partial ones. No table data,
    no row counts from user tables, no schema. No file contents. No credentials of any kind.

  WHAT IT DOES COLLECT, so you can decide before you send it
    Hostname, OS version and build, firmware, domain membership, memory.
    Local volumes: letter, size, free space, filesystem, dirty-bit state.
    SQL instances: name, service state, EDITION, version, patch level, whether it is Evaluation.
    Per database: NAME, PAGE_VERIFY setting, recovery model, size, state.
    msdb.dbo.suspect_pages: the COUNT, and database_id/file_id/page_id of any rows.
    Backup history from msdb: database name, finish time, type, and who took it.
    Whether chadmin exists, whether it is a local admin, whether it is sysadmin on each instance.
    Presence and version of: sqlcmd, Chocolatey, git, PowerShell 7, dbatools, winget, virtio.
    Non-Microsoft scheduled task NAMES. Running backup/AV agent service names.

    DATABASE NAMES ARE IN THE FILE. If a database name is itself sensitive, say so and a
    redacted variant can be produced instead.

  EVERY SQL QUERY IS A METADATA READ against sys.databases, msdb and SERVERPROPERTY. They are
  trivially cheap and take no locks on user data. There is NO CHECKDB here - that is load, and
  load on a customer production server is not something a probe gets to decide.

  RUN IT
    Open an ELEVATED PowerShell on the server and paste:

      [Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm https://raw.githubusercontent.com/yallacloud/yc-scripts/main/probe.ps1)

    Not elevated still works - it collects less (no scheduled task list) and says so.
    You can read this whole script in a browser at that URL before you run it.
================================================================================================
#>
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$out = New-Object System.Collections.Generic.List[string]
function W { param([string]$s='') ; $null = $out.Add($s) }
# NOT 'H': that is the built-in alias for Get-History, and PowerShell resolves ALIAS before
# FUNCTION, so every call here silently ran Get-History instead. _yc-lib.ps1 prefixes its
# helpers YcHdr/YcCmd for exactly this reason.
function YcHdr { param([string]$s) ; W ''; W ('--- ' + $s + ' ' + ('-' * [Math]::Max(0, 74 - $s.Length))) }

function Get-HostNameSafe {
  foreach ($t in @({ [Environment]::MachineName }, { (Get-CimInstance Win32_ComputerSystem -EA Stop).Name }, { $env:COMPUTERNAME })) {
    try { $v = & $t; if ($v) { return [string]$v } } catch {}
  }
  return 'UNKNOWN-HOST'
}
$hostName = Get-HostNameSafe

$elevated = $false
try { $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}

W '================================================================================'
W '  YALLACLOUD READ-ONLY PROBE'
W '================================================================================'
W ('  host        : ' + $hostName)
W ('  collected   : ' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC')
W ('  run as      : ' + $env:USERNAME + '   elevated=' + $elevated)
W ('  powershell  : ' + $PSVersionTable.PSVersion.ToString())
W ''
W '  NOTHING ON THIS SERVER WAS CHANGED. This probe only reads.'
if (-not $elevated) { W '  NOT ELEVATED - the scheduled task list will be missing. Everything else is here.' }

# --- identity ---------------------------------------------------------------------------------
YcHdr 'IDENTITY'
try {
  $os = Get-CimInstance Win32_OperatingSystem -EA Stop
  $cs = Get-CimInstance Win32_ComputerSystem  -EA Stop
  W ('  os          : ' + $os.Caption + '   build ' + $os.BuildNumber)
  W ('  installed   : ' + $os.InstallDate)
  W ('  last boot   : ' + $os.LastBootUpTime)
  W ('  domain      : ' + $cs.Domain + '   joined=' + $cs.PartOfDomain)
  W ('  manufacturer: ' + $cs.Manufacturer + ' / ' + $cs.Model)
  W ('  memory      : ' + [string][math]::Round($cs.TotalPhysicalMemory/1GB,1) + ' GB   sockets=' + $cs.NumberOfProcessors + ' logical=' + $cs.NumberOfLogicalProcessors)
} catch { W ('  FAILED: ' + $_.Exception.Message) }
$fw = 'unknown'
try { if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { $fw = 'UEFI' }
      elseif ((bcdedit /enum '{current}' 2>$null) -match 'winload.efi') { $fw = 'UEFI' } else { $fw = 'BIOS' } } catch {}
W ('  firmware    : ' + $fw)

# --- pending reboot ---------------------------------------------------------------------------
YcHdr 'PENDING REBOOT'
$pr = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pr += 'Component Based Servicing' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pr += 'Windows Update' }
try { if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -EA Stop).PendingFileRenameOperations) { $pr += 'PendingFileRenameOperations' } } catch {}
W ('  ' + $(if ($pr.Count) { 'PENDING: ' + ($pr -join ', ') } else { 'none' }))

# --- volumes ----------------------------------------------------------------------------------
YcHdr 'VOLUMES (fixed)'
try {
  foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -EA Stop)) {
    $dirty = 'n/a (needs elevation)'
    if ($elevated) { try { $dirty = $(if (((cmd /c ('fsutil dirty query ' + $v.DeviceID) 2>&1) -join ' ') -match 'is Dirty') { 'YES - SET' } else { 'no' }) } catch { $dirty='unreadable' } }
    $pct = if ($v.Size -gt 0) { [math]::Round(($v.FreeSpace/$v.Size)*100,1) } else { 0 }
    W ('  {0,-4} {1,9} GB  free {2,9} GB ({3,5}%)  fs={4,-6} dirty={5}' -f $v.DeviceID,
       [math]::Round($v.Size/1GB,1), [math]::Round($v.FreeSpace/1GB,1), $pct, $v.FileSystem, $dirty)
  }
} catch { W ('  FAILED: ' + $_.Exception.Message) }

# --- tooling ----------------------------------------------------------------------------------
YcHdr 'TOOLING PRESENT'
function Probe-Cmd { param([string]$Name,[string]$Exe,[string]$VerArg='--version')
  $c = Get-Command $Exe -EA SilentlyContinue
  if (-not $c) { W ('  {0,-14} ABSENT' -f $Name); return }
  $v = ''
  try { $v = ((& $c.Source $VerArg 2>&1) | Select-Object -First 1) } catch {}
  W ('  {0,-14} {1}' -f $Name, ([string]$v).Trim())
}
Probe-Cmd 'chocolatey' 'choco.exe'
Probe-Cmd 'git'        'git.exe'
Probe-Cmd 'winget'     'winget.exe'
$ps7 = @(Get-ChildItem 'C:\Program Files\PowerShell\7\*.exe' -EA SilentlyContinue).Count
W ('  {0,-14} {1}' -f 'powershell 7', $(if ($ps7) { 'present' } else { 'ABSENT' }))
$sqlcmd = Get-Command sqlcmd.exe -EA SilentlyContinue
if (-not $sqlcmd) {
  foreach ($g in @('C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\*\Tools\Binn\sqlcmd.exe',
                   'C:\Program Files\Microsoft SQL Server\*\Tools\Binn\sqlcmd.exe')) {
    $f = @(Get-ChildItem -Path $g -EA SilentlyContinue | Sort-Object FullName -Descending)
    if ($f.Count) { $sqlcmd = [pscustomobject]@{ Source = $f[0].FullName }; break }
  }
}
W ('  {0,-14} {1}' -f 'sqlcmd', $(if ($sqlcmd) { $sqlcmd.Source } else { 'ABSENT - no SQL metadata can be read' }))
$dbat = @(Get-Module dbatools -ListAvailable -EA SilentlyContinue | Select-Object -First 1)
W ('  {0,-14} {1}' -f 'dbatools', $(if ($dbat.Count) { $dbat[0].Version.ToString() } else { 'ABSENT' }))
W '  virtio drivers:'
$anyV = $false
foreach ($drv in @('viostor','vioscsi','netkvm','balloon','vioser')) {
  $f = Join-Path $env:windir ('System32\drivers\' + $drv + '.sys')
  if (Test-Path $f) { $anyV = $true
    $ver = ''; try { $ver = (Get-Item $f).VersionInfo.FileVersion } catch {}
    W ('    {0,-10} {1}' -f $drv, $ver) }
}
if (-not $anyV) { W '    none - this guest is not on virtio drivers' }

# --- chadmin ----------------------------------------------------------------------------------
YcHdr 'CHADMIN ACCOUNT'
$chadminExists = $false
try { $u = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=TRUE AND Name='chadmin'" -EA Stop
      if ($u) { $chadminExists = $true; W ('  exists      : YES   disabled=' + $u.Disabled) } } catch {}
if (-not $chadminExists) { W '  exists      : NO' }
if ($chadminExists) {
  $isAdmin = $false
  try { $isAdmin = (((net localgroup Administrators) -join "`n") -match '(?im)^\s*chadmin\s*$') } catch {}
  W ('  local admin : ' + $isAdmin)
}

# --- SQL --------------------------------------------------------------------------------------
YcHdr 'SQL SERVER'
function Q { param([string]$Target,[string]$Sql)
  if (-not $sqlcmd) { return $null }
  try {
    $r = & $sqlcmd.Source -S $Target -E -b -h -1 -W -Q $Sql 2>&1
    if ($LASTEXITCODE -ne 0) { return ('QUERY FAILED: ' + (($r | Select-Object -First 3) -join ' ')) }
    return (($r | Where-Object { $_ -and ($_ -notmatch '^\s*$') }) -join "`n").Trim()
  } catch { return ('QUERY ERROR: ' + $_.Exception.Message) }
}
$instances = @()
$root = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
if (Test-Path $root) {
  try { $n = Get-ItemProperty $root -EA Stop
        foreach ($p in $n.PSObject.Properties) { if ($p.Name -notmatch '^PS') { $instances += $p.Name } } } catch {}
}
if ($instances.Count -eq 0) { W '  no SQL Server instance found in the registry.' }
foreach ($i in $instances) {
  $svcName = $(if ($i -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$' + $i })
  $svc = Get-Service -Name $svcName -EA SilentlyContinue
  $state = $(if ($svc) { $svc.Status.ToString() } else { 'service not found' })
  W ''
  W ('  INSTANCE: ' + $i + '   service=' + $svcName + '   state=' + $state)
  $acct = ''
  try { $acct = (Get-CimInstance Win32_Service -Filter ("Name='" + $svcName.Replace("\","\\").Replace("'","''") + "'") -EA Stop).StartName } catch {}
  if ($acct) { W ('    service account : ' + $acct) }
  if ($state -ne 'Running') { W '    (not running - nothing further could be read)'; continue }
  $t = $(if ($i -eq 'MSSQLSERVER') { '.' } else { '.\' + $i })

  W ('    edition       : ' + (Q $t "SET NOCOUNT ON; SELECT CONVERT(varchar(128),SERVERPROPERTY('Edition'));"))
  W ('    version       : ' + (Q $t "SET NOCOUNT ON; SELECT CONVERT(varchar(128),SERVERPROPERTY('ProductVersion')) + '  level=' + CONVERT(varchar(64),SERVERPROPERTY('ProductLevel')) + '  update=' + ISNULL(CONVERT(varchar(64),SERVERPROPERTY('ProductUpdateLevel')),'-');"))
  W ('    cores/sockets : ' + (Q $t "SET NOCOUNT ON; SELECT CONVERT(varchar(10),cpu_count) + ' logical cpus, ' + CONVERT(varchar(10),cpu_count/hyperthread_ratio) + ' sockets' FROM sys.dm_os_sys_info;"))
  W ('    chadmin sysadmin : ' + (Q $t ("SET NOCOUNT ON; SELECT ISNULL(CONVERT(varchar(3),IS_SRVROLEMEMBER('sysadmin', N'" + $hostName + "\chadmin')),'no such login');")))
  W ('    SYSTEM sysadmin  : ' + (Q $t "SET NOCOUNT ON; SELECT ISNULL(CONVERT(varchar(3),IS_SRVROLEMEMBER('sysadmin', N'NT AUTHORITY\SYSTEM')),'no such login');"))
  W ('    Ola procedures   : ' + (Q $t "SET NOCOUNT ON; IF DB_ID('DBA') IS NULL SELECT 'DBA database does not exist - Ola is not installed' ELSE EXEC('SELECT CONVERT(varchar(10),COUNT(*)) + '' of 4 in DBA'' FROM DBA.sys.procedures WHERE name IN (''DatabaseBackup'',''DatabaseIntegrityCheck'',''IndexOptimize'',''CommandExecute'')');"))
  W ('    SQL Agent        : ' + (Q $t "SET NOCOUNT ON; SELECT CASE WHEN CONVERT(varchar(128),SERVERPROPERTY('Edition')) LIKE 'Express%' THEN 'not available on Express' ELSE 'available' END;"))

  W '    databases (name | page_verify | recovery | state | size MB):'
  $dbs = Q $t ("SET NOCOUNT ON; SELECT CONVERT(varchar(10),database_id) + ' | ' + " +
               "CONVERT(varchar(128),name) COLLATE DATABASE_DEFAULT + ' | ' + " +
               "CONVERT(varchar(64),page_verify_option_desc) COLLATE DATABASE_DEFAULT + ' | ' + " +
               "CONVERT(varchar(64),recovery_model_desc) COLLATE DATABASE_DEFAULT + ' | ' + " +
               "CONVERT(varchar(64),state_desc) COLLATE DATABASE_DEFAULT + ' | ' + " +
               "CONVERT(varchar(20),CAST((SELECT SUM(size)*8.0/1024 FROM sys.master_files WHERE database_id = d.database_id) AS decimal(18,1))) " +
               "FROM sys.databases d ORDER BY database_id;")
  foreach ($line in @(([string]$dbs) -split "`n")) { if ($line.Trim()) { W ('      ' + $line.Trim()) } }

  W ('    suspect_pages    : ' + (Q $t "SET NOCOUNT ON; SELECT CONVERT(varchar(10),COUNT(*)) + ' row(s)' FROM msdb.dbo.suspect_pages;"))
  $sp = Q $t "SET NOCOUNT ON; SELECT TOP 20 'db_id=' + CONVERT(varchar(10),database_id) + ' file=' + CONVERT(varchar(10),file_id) + ' page=' + CONVERT(varchar(20),page_id) + ' event=' + CONVERT(varchar(10),event_type) + ' errors=' + CONVERT(varchar(10),error_count) + ' last=' + CONVERT(varchar(30),last_update_date,120) FROM msdb.dbo.suspect_pages;"
  foreach ($line in @(([string]$sp) -split "`n")) { if ($line.Trim()) { W ('      ' + $line.Trim()) } }

  W '    last 10 backups (db | finished | type | by):'
  $bh = Q $t "SET NOCOUNT ON; SELECT TOP 10 database_name + ' | ' + CONVERT(varchar(30),backup_finish_date,120) + ' | ' + type + ' | ' + ISNULL(user_name,'?') FROM msdb.dbo.backupset ORDER BY backup_finish_date DESC;"
  foreach ($line in @(([string]$bh) -split "`n")) { if ($line.Trim()) { W ('      ' + $line.Trim()) } }

  W '    DAMAGE DETAIL (suspect_pages is CAPPED at 1000 rows - a full table means ongoing, uncounted):'
  W ('      affected databases : ' + (Q $t "SET NOCOUNT ON; SELECT CONVERT(varchar(10),database_id) + '=' + ISNULL(CONVERT(varchar(128),DB_NAME(database_id)),'(dropped)') + ' rows=' + CONVERT(varchar(10),COUNT(*)) + ' maxerr=' + CONVERT(varchar(10),MAX(error_count)) + ' first=' + CONVERT(varchar(30),MIN(last_update_date),120) + ' last=' + CONVERT(varchar(30),MAX(last_update_date),120) FROM msdb.dbo.suspect_pages GROUP BY database_id;"))
  W ('      event types        : ' + (Q $t "SET NOCOUNT ON; SELECT CONVERT(varchar(10),event_type) + '=' + CASE event_type WHEN 1 THEN '823 OS-level CRC or non-checksum 824 (THE STORAGE FAILED THE READ)' WHEN 2 THEN 'bad checksum' WHEN 3 THEN 'torn page' WHEN 4 THEN 'restored' WHEN 5 THEN 'repaired' WHEN 7 THEN 'deallocated by CHECKDB' END + ' x' + CONVERT(varchar(10),COUNT(*)) FROM msdb.dbo.suspect_pages GROUP BY event_type;"))
  W ('      page span          : ' + (Q $t "SET NOCOUNT ON; SELECT 'db ' + CONVERT(varchar(10),database_id) + ' file ' + CONVERT(varchar(10),file_id) + ': pages ' + CONVERT(varchar(20),MIN(page_id)) + ' to ' + CONVERT(varchar(20),MAX(page_id)) + '  span=' + CONVERT(varchar(20),(MAX(page_id)-MIN(page_id))*8/1024) + ' MB  at ~' + CONVERT(varchar(20),MIN(page_id)*8/1024/1024) + ' GB into the file' FROM msdb.dbo.suspect_pages GROUP BY database_id, file_id;"))
  W '    RESTORE HISTORY (is there a known-good copy to go back to?):'
  $rh = Q $t "SET NOCOUNT ON; SELECT TOP 10 CONVERT(varchar(128),destination_database_name) COLLATE DATABASE_DEFAULT + ' | ' + CONVERT(varchar(30),restore_date,120) + ' | ' + CONVERT(varchar(10),restore_type) FROM msdb.dbo.restorehistory ORDER BY restore_date DESC;"
  foreach ($line in @(([string]$rh) -split "`n")) { if ($line.Trim()) { W ('      ' + $line.Trim()) } }
  W '    BACKUP TYPES SEEN (D=full I=diff L=log - no L means NO point-in-time recovery):'
  $bt = Q $t "SET NOCOUNT ON; SELECT CONVERT(varchar(128),database_name) COLLATE DATABASE_DEFAULT + ' | ' + type + ' x' + CONVERT(varchar(10),COUNT(*)) + ' | newest ' + CONVERT(varchar(30),MAX(backup_finish_date),120) FROM msdb.dbo.backupset GROUP BY database_name, type ORDER BY database_name, type;"
  foreach ($line in @(([string]$bt) -split "`n")) { if ($line.Trim()) { W ('      ' + $line.Trim()) } }
  W '    data/log file volumes:'
  $mf = Q $t "SET NOCOUNT ON; SELECT DISTINCT LEFT(physical_name,2) FROM sys.master_files;"
  foreach ($line in @(([string]$mf) -split "`n")) { if ($line.Trim()) { W ('      ' + $line.Trim()) } }
}

# --- inherited state --------------------------------------------------------------------------
YcHdr 'INHERITED STATE'
W '  backup / AV agent services that are RUNNING:'
$known = @{ 'AcronisAgent'='Acronis';'AcrSch2Svc'='Acronis Scheduler';'VeeamEndpointBackupSvc'='Veeam Agent'
            'VeeamBackupSvc'='Veeam B&R';'BackupExecAgentAccelerator'='Veritas BE';'BackupExecRPCService'='Veritas BE'
            'NetBackup Client Service'='NetBackup';'cvd'='Commvault';'sdrsvc'='Windows Server Backup'
            'SQLBackupAgent'='Redgate';'IDERAService'='Idera';'RvSrv'='Redstor';'bacula-fd'='Bacula' }
$foundAgent = $false
foreach ($k in $known.Keys) { $s = Get-Service -Name $k -EA SilentlyContinue
  if ($s -and $s.Status -eq 'Running') { $foundAgent = $true; W ('    ' + $known[$k] + '  (' + $s.Name + ')') } }
if (-not $foundAgent) { W '    none of the known agents are running' }
try { $av = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -EA Stop | ForEach-Object { $_.displayName })
      W ('  antivirus: ' + $(if ($av.Count) { $av -join ', ' } else { 'none reported' })) } catch { W '  antivirus: (not readable)' }
W '  non-Microsoft scheduled tasks:'
if ($elevated) {
  try { $tasks = @(Get-ScheduledTask -EA Stop | Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' })
        if ($tasks.Count) { foreach ($t in $tasks) { W ('    ' + $t.TaskPath + $t.TaskName + '   state=' + $t.State) } }
        else { W '    none' } } catch { W ('    FAILED: ' + $_.Exception.Message) }
} else { W '    (needs elevation)' }
$cbi = Get-Service -Name 'cloudbase-init' -EA SilentlyContinue
W ('  cloudbase-init: ' + $(if ($cbi) { $cbi.Status.ToString() } else { 'absent' }))
W ('  C:\Scripts    : ' + $(if (Test-Path 'C:\Scripts') { (@(Get-ChildItem 'C:\Scripts' -File -EA SilentlyContinue).Count).ToString() + ' files' } else { 'absent' }))

YcHdr 'STORAGE AND SQL ERRORS IN THE EVENT LOG (last 14 days)'
W '  These are the events that say whether the STORAGE stack is failing, which is a different'
W '  problem from SQL finding a logical inconsistency. 825 is the early warning that precedes 823.'
$since = (Get-Date).AddDays(-14)
foreach ($spec in @(
    @{ log='System';      ids=@(7,9,11,15,51,52,129,153); label='disk / storage driver' },
    @{ log='Application'; ids=@(823,824,825,3313,3314,3414,17053); label='SQL Server IO / recovery' })) {
  W ('  ' + $spec.label + ' (' + $spec.log + '):')
  try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName=$spec.log; Id=$spec.ids; StartTime=$since } -EA Stop |
            Group-Object Id | Sort-Object Count -Descending)
    if ($ev.Count -eq 0) { W '    none' }
    foreach ($g in $ev) {
      $newest = ($g.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1)
      W ('    event ' + $g.Name + ' x' + $g.Count + '   newest ' + $newest.TimeCreated.ToString('yyyy-MM-dd HH:mm'))
      W ('      ' + (($newest.Message -split "`n")[0]).Trim())
    }
  } catch { W ('    none found, or the log is not readable: ' + $_.Exception.Message) }
}

W ''
W '================================================================================'
W '  END OF PROBE. Nothing on this server was changed.'
W '================================================================================'

# --- write it out -------------------------------------------------------------------------------
$dir = Join-Path $env:USERPROFILE 'Desktop'
if (-not (Test-Path $dir)) { $dir = $env:TEMP }
$file = Join-Path $dir ('yc-probe-' + $hostName + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
try {
  $out -join "`r`n" | Set-Content -LiteralPath $file -Encoding Ascii
  Write-Host ''
  Write-Host '  Probe complete. NOTHING on this server was changed.' -ForegroundColor Green
  Write-Host ('  Report written to:  ' + $file) -ForegroundColor Green
  Write-Host '  Read it before you send it - it contains database names.' -ForegroundColor Yellow
  Write-Host ''
} catch {
  Write-Host ('  Could not write the report: ' + $_.Exception.Message) -ForegroundColor Red
  Write-Host '  Output follows so it can be copied:' -ForegroundColor Yellow
  $out | ForEach-Object { Write-Host $_ }
}
