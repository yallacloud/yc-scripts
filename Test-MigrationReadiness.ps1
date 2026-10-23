param(
  # Where to write the report. Default is the TEMP of whoever runs it, NOT C:\Scripts: this runs
  # on a customer's live production VM that is still in service on the source platform, and it is
  # not our machine yet.
  [string]$OutDir = $env:TEMP,
  [switch]$SkipChkdsk,          # skip the volume scans (they read the whole disk and take time)
  [switch]$SkipSql,             # do not touch SQL Server at all
  [int]$BackupMaxAgeDays = 7,   # a SQL backup older than this does not count as a fallback
  [int]$UptimeWarnDays   = 180, # a VM up this long has unproven boot behaviour
  [switch]$VerifyBackups,       # RESTORE VERIFYONLY every full backup, whatever its size
  [int]$VerifyMaxMB      = 51200, # above this, only read the backup header (50 GB)
  [switch]$Json,                # print the JSON object to stdout as well
  [switch]$Help
)
# ================================================================================================
# Test-MigrationReadiness.ps1 - YALLACLOUD: CAN THIS VM BE MIGRATED, AND WHAT WILL COME WITH IT?
#
# RUN THIS BEFORE THE MIGRATION WINDOW, ON THE SOURCE VM, WHILE IT IS STILL RUNNING.
# Windows PowerShell 5.1. ASCII only. Server 2012R2 to 2025.
#
# WHY IT EXISTS
#   A migration is booked, a downtime window is agreed, the customer stops work - and only then
#   does anybody find out the filesystem was dirty, the database had damaged pages, or the last
#   good backup is three weeks old. By then the window is burning and the decision is being made
#   under pressure. Every answer below can be had days earlier, while the VM is still serving
#   users, because every check here is READ-ONLY.
#
# IT CHANGES NOTHING. No install, no scheduled task, no registry write, no service touched, no
#   account created, no file written outside -OutDir. chkdsk is run as /scan, which is the ONLINE
#   READ-ONLY scan: it does not dismount the volume, does not repair, and needs no reboot. SQL is
#   only ever SELECTed from. If this script cannot answer something read-only, it says UNKNOWN
#   rather than doing something intrusive to find out.
#
# IT IS ALSO EVIDENCE. Anything it reports is dated, and those dates were written by Windows and
#   by SQL Server ON THE SOURCE PLATFORM, before the VM was moved. If damage is later blamed on
#   the migration, this file - produced before the migration, on the source - is the answer.
#
# THE ANSWER IT GIVES
#   GO             nothing found that should stop the move.
#   GO WITH RISK   it can move, but something will travel with it, or something is unproven.
#                  Every item is named. This is a decision, not a failure.
#   DO NOT MIGRATE something must be fixed first. Moving it now risks data you cannot get back.
#
# WHY "DO NOT MIGRATE" IS RESERVED
#   Damaged data on its own is NOT a blocker: the damage is already there, and migrating does not
#   make it worse - it copies it exactly. What IS a blocker is damaged data with nothing to
#   restore from, or a filesystem Windows has already flagged for repair. In those cases a failed
#   cutover has no way back, and that is the only situation worth refusing over.
# ================================================================================================

$ErrorActionPreference = 'Continue'

# HOW THIS SCRIPT ENDS, and why it is not just "exit".
#   Run from a FILE (the .cmd wrapper, or -File), the exit code IS the verdict and an orchestrator
#   or an L1 batch file reads it from %ERRORLEVEL%. It must be right: a run that never got past
#   the elevation gate exiting 0 would read as GO on a machine nothing was checked on.
#   Run through  iex (irm ...)  - which is how this gets onto a source VM that has no payload -
#   there is no file, and a bare `exit` kills the OPERATOR'S SESSION rather than this script.
#   Measured the hard way on the adopt on-ramp.
#   $PSCommandPath is set in the first case and empty in the second, which is the discriminator.
$script:FromFile = [bool]$PSCommandPath
function Finish {
  param([int]$Code)
  $global:LASTEXITCODE = $Code
  if ($script:FromFile) { exit $Code }
  Write-Host ('  exit code ' + [string]$Code + ' (also in $LASTEXITCODE)')
}

$script:Blockers = New-Object System.Collections.Generic.List[string]
$script:Risks    = New-Object System.Collections.Generic.List[string]
$script:Notes    = New-Object System.Collections.Generic.List[string]
$script:Report   = [ordered]@{
  schema='ycmig.readiness/1'; host=$env:COMPUTERNAME
  generatedUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
  tool='Test-MigrationReadiness.ps1'; version='1.0.0'
}
$script:Log = New-Object System.Collections.Generic.List[string]

function Say {
  param([string]$Text,[string]$Level='INFO')
  $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $script:Log.Add($stamp + '  [' + $Level + '] ' + $Text) | Out-Null
  $c = switch ($Level) { 'BLOCK' {'Red'} 'RISK' {'Yellow'} 'OK' {'Green'} 'HEAD' {'Cyan'} default {'Gray'} }
  if ($Level -eq 'HEAD') { Write-Host ''; Write-Host ('  ' + $Text) -ForegroundColor $c }
  else { Write-Host ('  ' + $Text) -ForegroundColor $c }
}
# Inline, an L1 gets ONE SHORT LINE per finding, numbered, so the run reads as a list rather than
# a wall of paragraphs. The full explanation - what it means, what to do, why - is printed ONCE in
# the summary at the end and written in full to the report file. Printing the whole paragraph
# twice, inline and again in the summary, is what made the first real run unreadable.
function Short {
  param([string]$T)
  $one = (($T -split '(?<=\.)\s') | Select-Object -First 1).Trim()
  if (-not $one) { $one = $T }
  if ($one.Length -gt 108) { $one = $one.Substring(0,105) + '...' }
  return $one
}
function Block {
  param([string]$T)
  $script:Blockers.Add($T) | Out-Null
  Say ('BLOCKER ' + [string]$script:Blockers.Count + ': ' + (Short $T)) 'BLOCK'
  $script:Log.Add('        full: ' + $T) | Out-Null
}
function Risk {
  param([string]$T)
  $script:Risks.Add($T) | Out-Null
  Say ('RISK ' + [string]$script:Risks.Count + ': ' + (Short $T)) 'RISK'
  $script:Log.Add('        full: ' + $T) | Out-Null
}
function Note  { param([string]$T) $script:Notes.Add($T)    | Out-Null }

if ($Help) {
@'
migration-check  -  can this VM be migrated, and what will come with it?

  RUN IT ON THE SOURCE VM, BEFORE THE MIGRATION WINDOW, WHILE IT IS STILL RUNNING.
  It changes NOTHING: no install, no task, no registry write, no repair. Read-only throughout,
  so it is safe on a live production machine serving users.

USAGE
  migration-check                 run every check and print the verdict
  migration-check -SkipChkdsk     skip the volume scans (they read the whole disk)
  migration-check -SkipSql        do not touch SQL Server at all
  migration-check -Json           also print the JSON to stdout
  migration-check -Help           this text

PARAMETERS
  -OutDir <path>            where to write the report. Default: your TEMP. NOT C:\Scripts -
                            this is still the customer's machine on the source platform.
  -SkipChkdsk               do not scan the volumes. They are read whole, so it takes minutes
                            per hundred GB - but skipping it leaves the filesystem UNPROVEN
                            and the report says so.
  -SkipSql                  do not connect to SQL Server at all.
  -BackupMaxAgeDays <n>     a full backup older than this does not count as a fallback.
                            Default 7.
  -UptimeWarnDays <n>       flag a VM that has been up longer than this, because nobody has
                            seen it boot. Default 180.
  -VerifyBackups            run RESTORE VERIFYONLY on EVERY full backup regardless of size.
                            It reads the whole file, so on a large backup this takes as long
                            as reading it does. Read-only - it writes nothing.
  -VerifyMaxMB <n>          backups larger than this are header-checked only, not verified.
                            Default 51200 (50 GB). Raise it, or use -VerifyBackups out of hours.
  -Json                     print the JSON object to stdout as well as writing it.

WHAT IT CHECKS
  every attached fixed volume   chkdsk /scan - ONLINE and READ-ONLY, no dismount, no repair,
                                no reboot - plus the NTFS dirty bit, free space, disk layout
                                and whether any disk is dynamic
  SQL Server, if installed      damaged pages WITH THE DATES SQL SERVER WROTE, databases that
                                have never passed a consistency check, recovery model,
                                PAGE_VERIFY, size, and when each database was last backed up
  the backup path (VSS)         writers, providers, the services they need, and recent VSS
                                errors - whether ANY backup of this machine can be
                                application-consistent
  the fallback                  which backup agent is installed and whether it is RUNNING, and
                                for every database the newest full backup: does the file still
                                exist, can SQL Server read its header, and does RESTORE
                                VERIFYONLY pass. Ticking "backup taken" is not the same as
                                knowing it restores, and the difference only shows up on the
                                day you need it.
  the record                    hostname, every NIC with its MAC, IP, mask, gateway and DNS,
                                listening ports, firewall state and rule count, automatic
                                services and the accounts they run as, scheduled tasks, and
                                every installed application with its version - the things the
                                migration checklist asks a person to transcribe by hand
  the machine                   boot mode, virtio/VMware drivers, uptime, pending reboot,
                                Windows licence channel, and IO errors already in the event log

THE ANSWER
  GO             nothing found that should stop the move
  GO WITH RISK   it can move, but something travels with it. Every item is named.
  DO NOT MIGRATE fix something first. Moving now risks data you cannot get back.

  Damaged data by itself is NOT a blocker - the damage is already there and a migration copies
  it exactly, it does not cause it and does not repair it. What BLOCKS is damaged data with
  NOTHING TO RESTORE FROM, or a filesystem Windows has already flagged for repair. Those are
  the cases where a failed cutover has no way back, and they are the only ones worth refusing.

IT IS ALSO EVIDENCE
  Every finding carries the date Windows or SQL Server recorded it, on the SOURCE platform,
  before the VM moved. If damage is later blamed on the migration, this file - produced before
  the migration, on the source - is the answer. Keep the .txt, the .json and the SHA256.

EXIT CODES
   0  GO
   1  GO WITH RISK - read the risks
   2  DO NOT MIGRATE - read the blockers
   5  not elevated. NOTHING WAS CHECKED - do not read it as a pass.

  Run it from a file and the exit code is the verdict, for an orchestrator or a batch file.
  Run it through  iex (irm ...)  and it is in $LASTEXITCODE instead - a bare exit inside iex
  would close the window you are standing in.

Log:
  This command deliberately does NOT write to C:\Scripts and does NOT use the house logging
  library. It is built to run on a source VM that has no YallaCloud payload on it at all, and
  depending on _yc-lib.ps1 would defeat that. The full run log is inside the report file it
  writes to -OutDir.

EXAMPLES
  migration-check
      the normal case: scan every drive, check SQL and VSS, print the verdict

  migration-check -SkipChkdsk
      when the window is tight and the volumes were scanned recently

  migration-check -OutDir \\fileserver\migration-evidence
      write the evidence somewhere central instead of the local TEMP

  migration-check -SkipSql -Json
      a file server with no database, machine-readable output for a collector

  migration-check -VerifyBackups
      out of hours: read EVERY full backup end to end and prove it would restore

  powershell -ExecutionPolicy Bypass -File .\Test-MigrationReadiness.ps1
      run it straight from a copied file on a VM with no payload installed
'@ | Write-Host
  Finish 0
  return
}

# --- elevation ---------------------------------------------------------------------------------
$elevated = $false
try { $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
if (-not $elevated) {
  Write-Host ''
  Write-Host '  This needs an elevated PowerShell: chkdsk and SQL both do.' -ForegroundColor Red
  Write-Host '  Right-click PowerShell, Run as administrator, and run it again.' -ForegroundColor Red
  Write-Host '  NOTHING WAS CHECKED. Do not read this as a pass.' -ForegroundColor Red
  Write-Host ''
  Finish 5
  return
}

Write-Host ''
Write-Host '================================================================================'
Write-Host '  CAN THIS VM BE MIGRATED?   -   ' -NoNewline
Write-Host $env:COMPUTERNAME -ForegroundColor White
Write-Host '  Read-only pre-flight. Nothing on this machine is changed.'
Write-Host '================================================================================'

# ================================================================================================
# 1. THE MACHINE
# ================================================================================================
Say 'THE MACHINE' 'HEAD'
$m = [ordered]@{}
try {
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $cs = Get-CimInstance Win32_ComputerSystem  -ErrorAction Stop
  $m.os           = [string]$os.Caption
  $m.build        = [string]$os.BuildNumber
  $m.memoryGB     = [math]::Round($cs.TotalPhysicalMemory/1GB,1)
  $m.cpus         = [int]$cs.NumberOfLogicalProcessors
  $m.manufacturer = [string]$cs.Manufacturer
  $m.model        = [string]$cs.Model
  $m.domain       = [string]$cs.Domain
  $m.partOfDomain = [bool]$cs.PartOfDomain
  $lastBoot       = $os.LastBootUpTime
  $m.lastBoot     = $lastBoot.ToString('yyyy-MM-dd HH:mm:ss')
  $m.uptimeDays   = [math]::Round(((Get-Date) - $lastBoot).TotalDays,1)
  $m.installed    = $os.InstallDate.ToString('yyyy-MM-dd')
} catch { Note ('could not read the machine identity: ' + $_.Exception.Message) }
try { $m.bios = [string](Get-CimInstance Win32_BIOS -ErrorAction Stop).Manufacturer } catch {}

# Source platform. OpenStack is KVM, so virtio is what the target needs too - but say what is
# actually there rather than assuming, because a VM that came to OpenStack from somewhere else
# may still be carrying the other platform's drivers.
$all = ($m.manufacturer + ' ' + $m.model + ' ' + $m.bios)
$m.platform = if     ($all -match 'VMware')                     { 'VMWARE' }
              elseif ($all -match 'QEMU|KVM|Bochs|SeaBIOS')     { 'KVM/OPENSTACK' }
              elseif ($all -match 'Microsoft.*Virtual|Hyper-V') { 'HYPERV' }
              elseif ($all -match 'Xen')                        { 'XEN' }
              else                                              { 'PHYSICAL-OR-UNKNOWN' }

# BOOT MODE must match what the target template is built for. Getting this wrong is a VM that
# does not boot after the move, found during the window.
$m.bootMode = 'UNKNOWN'
try {
  # $env:firmware_type is Server 2012R2+ and needs nothing; the SecureBoot cmdlet is 2012+ but
  # throws on BIOS machines, so the environment variable is tried first.
  if ($env:firmware_type) { $m.bootMode = $env:firmware_type.ToUpper() }
  elseif (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { $m.bootMode = 'UEFI' }
  else { $m.bootMode = 'BIOS' }
} catch {}
Say ('os            : ' + $m.os + '  build ' + $m.build)
Say ('platform      : ' + $m.platform + '   boot mode: ' + $m.bootMode)
Say ('size          : ' + [string]$m.cpus + ' vCPU, ' + [string]$m.memoryGB + ' GB RAM')
Say ('last boot     : ' + $m.lastBoot + '  (up ' + [string]$m.uptimeDays + ' days)')

if ($m.uptimeDays -gt $UptimeWarnDays) {
  Risk ('this VM has been up ' + [string]$m.uptimeDays + ' days. Nobody has seen it boot in that time, so whether it comes back up cleanly after the move is UNPROVEN. Reboot it in a maintenance window BEFORE the migration, not during it - a VM that fails to boot during a cutover is found with the window already burning.')
}

# Guest drivers. A VM landing on KVM with no virtio storage driver does not boot.
$virtio = @(); $vmw = @()
foreach ($d in @('viostor','vioscsi','netkvm','balloon','vioser')) {
  if (Test-Path -LiteralPath ($env:windir + '\System32\drivers\' + $d + '.sys')) { $virtio += $d }
}
foreach ($d in @('pvscsi','vmxnet3','vmci','vmmemctl')) {
  if (Get-Service -Name $d -ErrorAction SilentlyContinue) { $vmw += $d }
}
$m.virtioDrivers = @($virtio); $m.vmwareDrivers = @($vmw)
if (@($virtio).Count) { Say ('virtio        : ' + (@($virtio) -join ', ')) 'OK' }
else {
  Say 'virtio        : NONE PRESENT' 'RISK'
  Risk 'no virtio drivers are installed. If the target is KVM/CloudStack this VM will NOT BOOT after the move until they are injected offline. Inject them on the source first, or confirm the target uses the same controller this VM already has.'
}
if (@($vmw).Count) { Note ('VMware drivers present on the source: ' + (@($vmw) -join ', ') + ' - they will be inert on a KVM target.') }

# A pending reboot means something is half-applied. Copying a machine mid-update is how you get
# a VM that boots into a repair loop on the far side.
$pending = @()
if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'Component Based Servicing' }
if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update' }
try { if ((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations) { $pending += 'PendingFileRenameOperations' } } catch {}
$m.pendingReboot = @($pending)
if (@($pending).Count) {
  Block ('a reboot is PENDING on this machine (' + (@($pending) -join ', ') + '). Something is half-applied. Reboot it and re-run this check BEFORE migrating - copying a machine mid-update is how a VM arrives in a repair loop.')
} else { Say 'pending reboot: none' 'OK' }

# Activation drops when the MAC changes. Commercial, not technical, but it surfaces at cutover.
try {
  $lic = @(Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction Stop)
  if ($lic.Count) {
    $st = [int]$lic[0].LicenseStatus
    $m.windowsLicense = switch ($st) { 1 {'Licensed'} 2 {'OOB Grace'} 3 {'OOT Grace'} 4 {'Non-Genuine Grace'} 5 {'Notification'} 6 {'Extended Grace'} default {'Unknown(' + [string]$st + ')'} }
    $m.windowsChannel = [string]$lic[0].ProductKeyChannel
    Say ('windows       : ' + $m.windowsLicense + '  (' + $m.windowsChannel + ')')
    if ($m.windowsChannel -match 'OEM') {
      Risk ('Windows on this VM is an OEM licence (' + $m.windowsChannel + '). OEM licences are tied to the original hardware and do NOT transfer. Activation will drop after the move and re-licensing is a COMMERCIAL decision, not a technical one. Raise it before the window, not after.')
    } elseif ($st -ne 1) {
      Risk ('Windows is not fully licensed on the source already (' + $m.windowsLicense + '). The move will not fix that, and the MAC change may make it worse.')
    }
  }
} catch { Note 'could not read the Windows licence state' }
$script:Report.machine = $m

# ================================================================================================
# 2. EVERY ATTACHED VOLUME - chkdsk /scan, the dirty bit, space, and the layout
#
# chkdsk /scan is the ONLINE READ-ONLY scan. It does not dismount the volume, does not repair
# anything, and needs no reboot - which is exactly why it belongs HERE, days before the window,
# rather than during it. It reads the whole volume, so it takes minutes per hundred GB. That is
# time we have now and will not have later.
# ================================================================================================
Say 'EVERY ATTACHED DRIVE' 'HEAD'
$vols = @()
$diskRows = @()
try {
  foreach ($dk in @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Sort-Object Index)) {
    $diskRows += [ordered]@{ index=[int]$dk.Index; model=[string]$dk.Model
                             sizeGB=[math]::Round($dk.Size/1GB,1)
                             partitions=[int]$dk.Partitions; interface=[string]$dk.InterfaceType }
  }
  Say ([string]@($diskRows).Count + ' physical disk(s) attached:')
  foreach ($r in $diskRows) { Say ('   disk ' + [string]$r.index + '  ' + [string]$r.sizeGB + ' GB  ' + $r.partitions + ' partition(s)  ' + $r.model) }
} catch { Note ('could not enumerate the disks: ' + $_.Exception.Message) }
$script:Report.disks = @($diskRows)

# Dynamic disks do not survive most migration paths intact. Worth knowing before, never during.
try {
  $dyn = @(Get-CimInstance Win32_DiskPartition -ErrorAction Stop | Where-Object { $_.Type -match 'Logical Disk Manager|Dynamic' })
  if ($dyn.Count) {
    Block ([string]$dyn.Count + ' partition(s) are on DYNAMIC disks. Most migration tooling cannot move a dynamic disk cleanly, and the result does not always fail loudly. Convert to basic, or confirm with the migration platform that it handles dynamic disks, BEFORE booking the window.')
  }
} catch {}

foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
  $row = [ordered]@{ drive=[string]$v.DeviceID; fs=[string]$v.FileSystem
                     sizeGB=[math]::Round($v.Size/1GB,1); freeGB=[math]::Round($v.FreeSpace/1GB,1)
                     freePct=$(if ($v.Size -gt 0) { [math]::Round(($v.FreeSpace/$v.Size)*100,1) } else { 0 })
                     dirty='unknown'; chkdsk='not run'; chkdskClean=$null; chkdskDetail='' }
  Say ($row.drive + '  ' + [string]$row.sizeGB + ' GB total, ' + [string]$row.freeGB + ' GB free (' + [string]$row.freePct + '%)  fs=' + $row.fs)

  # The dirty bit first: if Windows has ALREADY decided this volume needs repair, no scan is
  # needed to know the answer, and running one does not change it.
  try {
    $dq = ((cmd /c ('fsutil dirty query ' + $row.drive) 2>&1) -join ' ')
    if     ($dq -match 'is Dirty')     { $row.dirty = 'YES' }
    elseif ($dq -match 'is NOT Dirty') { $row.dirty = 'no' }
    else                               { $row.dirty = 'unreadable' }
  } catch { $row.dirty = 'unreadable' }

  if ($row.dirty -eq 'YES') {
    Block ($row.drive + ' has the NTFS DIRTY BIT SET. Windows itself has already decided this filesystem needs repair and it has not been repaired. Migrating copies the damage exactly as it is. Run chkdsk /f on this volume in a maintenance window on the SOURCE, confirm it comes back clean, and re-run this check before booking the move.')
  } elseif ($row.dirty -eq 'unreadable') {
    Risk ($row.drive + ' the dirty bit could not be read, so a clean filesystem has not actually been established on this volume.')
  }

  if ($row.freePct -lt 10) {
    Risk ($row.drive + ' has only ' + [string]$row.freeGB + ' GB free (' + [string]$row.freePct + '%). A volume this full leaves no room for the snapshot a migration takes, and none for a rollback copy either.')
  }

  if ($SkipChkdsk) {
    $row.chkdsk = 'skipped (-SkipChkdsk)'
    Say ('   chkdsk     : SKIPPED') 'RISK'
    Risk ($row.drive + ' the volume scan was skipped, so the filesystem on it is UNPROVEN.')
  } elseif ($row.fs -ne 'NTFS') {
    $row.chkdsk = 'not applicable (' + $row.fs + ')'
    Say ('   chkdsk     : not applicable on ' + $row.fs)
  } else {
    Say ('   chkdsk /scan running - ONLINE and READ-ONLY, this volume stays in use. Please wait.')
    $txt = ''
    try { $txt = ((cmd /c ('chkdsk ' + $row.drive + ' /scan') 2>&1) -join "`n") } catch { $txt = 'chkdsk could not be started: ' + $_.Exception.Message }
    $code = $LASTEXITCODE
    $row.chkdsk = 'exit ' + [string]$code
    # ORDER MATTERS, AND THE FAILURE PHRASES GO FIRST.
    #   "Windows has made corrections to the file system." is followed by "No further action is
    #   required" - the SAME sentence a clean scan ends with. Checking the clean phrase first
    #   therefore reports a volume chkdsk has just REPAIRED as clean, which on a pre-migration
    #   go/no-go is a false GO on a damaged filesystem. Caught by the test, not by review.
    #   The reverse mistake is also live: "found NO problems" contains the word "problems", so
    #   the failure patterns must be specific enough not to match it. "found problems" does not
    #   appear inside "found no problems", and none of the others appear in a clean run.
    if ($txt -match '(?i)made corrections|found problems|Errors found|corruption was found|needs to be taken offline|Run chkdsk with the /f') {
      $row.chkdskClean = $false
      $row.chkdskDetail = [string]$Matches[0]
      Block ($row.drive + ' chkdsk /scan FOUND FILESYSTEM PROBLEMS ("' + $row.chkdskDetail + '"). This is on the SOURCE, before any migration. Repair it here with chkdsk /f in a maintenance window and confirm it comes back clean - migrating now copies a broken filesystem onto the new platform and the damage will be blamed on the move.')
    } elseif ($txt -match '(?i)found no problems|no further action is required') {
      $row.chkdskClean = $true
      $row.chkdskDetail = 'Windows reported no problems'
      Say ('   chkdsk     : CLEAN - Windows found no problems on ' + $row.drive) 'OK'
    } elseif ($code -eq 0) {
      $row.chkdskClean = $true
      $row.chkdskDetail = 'chkdsk exited 0'
      Say ('   chkdsk     : exit 0, no problems reported') 'OK'
    } else {
      # Neither phrase matched and the exit was non-zero. Say that, rather than guessing either way.
      $row.chkdskClean = $null
      $row.chkdskDetail = (($txt -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' ')
      if ($row.chkdskDetail.Length -gt 300) { $row.chkdskDetail = $row.chkdskDetail.Substring(0,300) + '...' }
      Risk ($row.drive + ' chkdsk /scan exited ' + [string]$code + ' and its output could not be read as either clean or failed. The filesystem on this volume is UNPROVEN. Last lines: ' + $row.chkdskDetail)
    }
  }
  $vols += $row
}
$script:Report.volumes = @($vols)

# ================================================================================================
# 3. IO ERRORS ALREADY IN THE EVENT LOG
#
# Scoped BY PROVIDER, never by event id alone: ids 7, 9, 11, 15 and friends are reused by
# unrelated components, and on a healthy machine a bare id filter returns hundreds of "disk
# errors" that are nothing of the kind. ProviderName in a FilterHashtable THROWS on a provider
# the machine does not have, so the list is resolved first.
# ================================================================================================
Say 'IO ERRORS ALREADY ON RECORD (last 365 days)' 'HEAD'
$corruptIds = @{
  'disk'=@(7,11,52,153); 'Ntfs'=@(55,98,130,131,137,140); 'Microsoft-Windows-Ntfs'=@(55,98,130,131,137,140)
  'volmgr'=@(46,49,161,162); 'partmgr'=@(58)
  'storahci'=@(129,153); 'stornvme'=@(129,153); 'vioscsi'=@(129,153); 'viostor'=@(129,153)
  'pvscsi'=@(129,153); 'vmscsi'=@(129,153); 'LSI_SAS'=@(129,153); 'iaStorA'=@(129,153); 'msdsm'=@(129,153)
}
$want = @('disk','Ntfs','Microsoft-Windows-Ntfs','volmgr','partmgr','volsnap','storahci','stornvme',
          'vioscsi','viostor','pvscsi','vmscsi','LSI_SAS','iaStorA','msdsm','mpio','Microsoft-Windows-StorPort')
$have = @(); foreach ($pr in $want) { if (Get-WinEvent -ListProvider $pr -ErrorAction SilentlyContinue) { $have += $pr } }
$ioRows = @()
if ($have.Count) {
  try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName=$have; Level=1,2,3
                                             StartTime=(Get-Date).AddDays(-365) } -MaxEvents 2000 -ErrorAction Stop)
    $bad = @($ev | Where-Object { $i = $corruptIds[[string]$_.ProviderName]; $i -and ($i -contains [int]$_.Id) })
    foreach ($g in @($bad | Group-Object ProviderName,Id)) {
      $times = @($g.Group | ForEach-Object { $_.TimeCreated } | Sort-Object)
      $ioRows += [ordered]@{ provider=[string]@($g.Group)[0].ProviderName; id=[int]@($g.Group)[0].Id
                             count=$g.Count; first=$times[0].ToString('yyyy-MM-dd HH:mm:ss')
                             last=$times[-1].ToString('yyyy-MM-dd HH:mm:ss') }
    }
  } catch {}
}
$script:Report.ioErrors = @($ioRows)
if (@($ioRows).Count) {
  foreach ($r in $ioRows) { Say ('   ' + $r.provider + ' event ' + [string]$r.id + '  x' + [string]$r.count + '   first ' + $r.first + '   last ' + $r.last) 'RISK' }
  $tot = 0; foreach ($r in $ioRows) { $tot += [int]$r.count }
  $first = @($ioRows | ForEach-Object { $_.first } | Sort-Object)[0]
  Risk ([string]$tot + ' filesystem/disk corruption event(s) are ALREADY on record on this source VM, the earliest on ' + $first + '. They were written by Windows on the source platform, before any migration. They travel with the VM, and this report is the proof of when they started.')
} else { Say 'none - no filesystem or disk corruption events from a storage provider' 'OK' }

# ================================================================================================
# 4. SQL SERVER, IF IT IS INSTALLED
#
# Everything here is a SELECT. Connected with .NET rather than sqlcmd on purpose: sqlcmd is not
# on every SQL box and this script must not install anything to be able to look.
# ================================================================================================
function Invoke-Sql {
  param([string]$Server,[string]$Query,[int]$TimeoutSec=120)
  $rows = @()
  $cn = New-Object System.Data.SqlClient.SqlConnection
  $cn.ConnectionString = 'Server=' + $Server + ';Database=master;Integrated Security=True;Connect Timeout=15;Application Name=yc-migration-check'
  try {
    $cn.Open()
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = $TimeoutSec
    $rd = $cmd.ExecuteReader()
    while ($rd.Read()) {
      $o = [ordered]@{}
      for ($i=0; $i -lt $rd.FieldCount; $i++) { $o[$rd.GetName($i)] = $(if ($rd.IsDBNull($i)) { $null } else { $rd.GetValue($i) }) }
      $rows += [pscustomobject]$o
    }
    $rd.Close()
  } finally { $cn.Close() }
  return @($rows)
}

$sqlOut = @()
if ($SkipSql) { Say 'SQL SERVER - SKIPPED (-SkipSql)' 'HEAD' }
else {
  Say 'SQL SERVER' 'HEAD'
  $instances = @()
  try {
    $k = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (Test-Path -LiteralPath $k) {
      foreach ($p in (Get-ItemProperty -LiteralPath $k).PSObject.Properties) {
        if ($p.Name -match '^PS') { continue }
        $instances += $p.Name
      }
    }
  } catch {}
  if (-not $instances.Count) { Say 'no SQL Server instance is installed on this VM' 'OK' }
  foreach ($inst in $instances) {
    $target = $(if ($inst -eq 'MSSQLSERVER') { '.' } else { '.\' + $inst })
    $si = [ordered]@{ instance=$inst; reachable=$false; edition=''; version=''; databases=@()
                      suspectPages=@(); neverCheckdb=@(); lastBackups=@(); totalSizeMB=0 }
    Say ('instance ' + $inst)
    try {
      $v = Invoke-Sql -Server $target -Query "SELECT CONVERT(varchar(128),SERVERPROPERTY('Edition')) AS ed, CONVERT(varchar(128),SERVERPROPERTY('ProductVersion')) AS ver"
      if (@($v).Count) { $si.reachable=$true; $si.edition=[string]$v[0].ed; $si.version=[string]$v[0].ver }
    } catch {
      Risk ('SQL instance ' + $inst + ' is installed but could not be queried (' + $_.Exception.Message.Split("`n")[0] + '). Its data CANNOT be assessed before the migration, so whatever state it is in will be discovered after the move.')
      $sqlOut += $si; continue
    }
    Say ('   edition    : ' + $si.edition + '   version ' + $si.version) 'OK'

    # databases, sizes and recovery model
    try {
      $dbs = Invoke-Sql -Server $target -Query @"
SELECT d.name AS dbname, d.recovery_model_desc AS recovery, d.page_verify_option_desc AS pageverify,
       d.state_desc AS state,
       CONVERT(decimal(18,1), SUM(CONVERT(bigint,mf.size))*8.0/1024) AS sizemb
FROM sys.databases d JOIN sys.master_files mf ON mf.database_id = d.database_id
WHERE d.database_id > 4
GROUP BY d.name, d.recovery_model_desc, d.page_verify_option_desc, d.state_desc
ORDER BY SUM(CONVERT(bigint,mf.size)) DESC
"@
      foreach ($d in $dbs) {
        $si.databases += [ordered]@{ database=[string]$d.dbname; recovery=[string]$d.recovery
                                     pageVerify=[string]$d.pageverify; state=[string]$d.state
                                     sizeMB=[string]$d.sizemb }
        $si.totalSizeMB += [double]$d.sizemb
        if ([string]$d.state -ne 'ONLINE') {
          Block ('SQL database ' + $d.dbname + ' on ' + $inst + ' is ' + $d.state + ', not ONLINE. A database in that state will migrate in that state. Find out why it is not online BEFORE the move, not after.')
        }
      }
      Say ('   databases  : ' + [string]@($si.databases).Count + ', ' + [string][math]::Round($si.totalSizeMB/1024,1) + ' GB total')
      foreach ($d in @($si.databases | Select-Object -First 10)) {
        Say ('      ' + ('{0,-32} {1,12} MB  {2,-8} page_verify={3}' -f $d.database, $d.sizeMB, $d.recovery, $d.pageVerify))
      }
      foreach ($d in @($si.databases | Where-Object { $_.pageVerify -ne 'CHECKSUM' })) {
        Risk ('SQL database ' + $d.database + ' has PAGE_VERIFY = ' + $d.pageVerify + ', not CHECKSUM. Torn and lost writes on this database are NOT DETECTABLE - it can be damaged right now with nothing recording it, and a fast consistency check after the move cannot prove otherwise.')
      }
    } catch { Note ('could not list databases on ' + $inst + ': ' + $_.Exception.Message) }

    # DAMAGED PAGES, WITH THE DATES SQL SERVER WROTE. This is the evidence.
    try {
      $sp = Invoke-Sql -Server $target -Query @"
SELECT ISNULL(DB_NAME(database_id),'(dropped)') AS dbname, COUNT(*) AS pages,
       CONVERT(varchar(30),MIN(last_update_date),120) AS firstseen,
       CONVERT(varchar(30),MAX(last_update_date),120) AS lastseen
FROM msdb.dbo.suspect_pages WHERE event_type IN (1,2,3)
GROUP BY database_id
"@
      foreach ($r in $sp) {
        $si.suspectPages += [ordered]@{ database=[string]$r.dbname; pages=[int]$r.pages
                                        firstSeen=[string]$r.firstseen; lastSeen=[string]$r.lastseen }
      }
    } catch { Note ('could not read suspect_pages on ' + $inst + ': ' + $_.Exception.Message) }

    # Has a CHECKDB ever completed cleanly? 1900-01-01 means never.
    try {
      foreach ($d in @($si.databases | Where-Object { $_.state -eq 'ONLINE' })) {
        $q = "DBCC DBINFO('" + ($d.database -replace "'","''") + "') WITH TABLERESULTS"
        $rows = Invoke-Sql -Server $target -Query $q -TimeoutSec 60
        $lkg = @($rows | Where-Object { [string]$_.Field -eq 'dbi_dbccLastKnownGood' }) | Select-Object -First 1
        if ($lkg -and ([string]$lkg.Value) -like '1900-01-01*') { $si.neverCheckdb += $d.database }
      }
    } catch { Note ('could not read the last-known-good date on ' + $inst + ': ' + $_.Exception.Message) }

    # When was each database last backed up, and can it be restored from?
    try {
      $bk = Invoke-Sql -Server $target -Query @"
SELECT d.name AS dbname,
       CONVERT(varchar(30),MAX(CASE WHEN b.type='D' THEN b.backup_finish_date END),120) AS lastfull,
       CONVERT(varchar(30),MAX(b.backup_finish_date),120) AS lastany
FROM sys.databases d LEFT JOIN msdb.dbo.backupset b ON b.database_name = d.name
WHERE d.database_id > 4 GROUP BY d.name
"@
      foreach ($r in $bk) {
        $full = [string]$r.lastfull
        $age  = $null
        if ($full) { try { $age = [math]::Round(((Get-Date) - [datetime]$full).TotalDays,1) } catch {} }
        $si.lastBackups += [ordered]@{ database=[string]$r.dbname; lastFull=$full
                                       lastAny=[string]$r.lastany; fullAgeDays=$age }
      }
    } catch { Note ('could not read backup history on ' + $inst + ': ' + $_.Exception.Message) }
    $sqlOut += $si
  }
}
$script:Report.sql = @($sqlOut)

# --- what the SQL findings MEAN for the migration ----------------------------------------------
foreach ($si in $sqlOut) {
  if (-not $si.reachable) { continue }
  $damaged = 0; $earliest = ''; $latest = ''
  foreach ($r in @($si.suspectPages)) {
    $damaged += [int]$r.pages
    if (-not $earliest -or $r.firstSeen -lt $earliest) { $earliest = $r.firstSeen }
    if ($r.lastSeen -gt $latest) { $latest = $r.lastSeen }
  }
  # Which databases have a usable fallback? This is what turns "damaged" into "blocked".
  $noBackup = @($si.lastBackups | Where-Object { -not $_.lastFull -or $_.fullAgeDays -eq $null -or $_.fullAgeDays -gt $BackupMaxAgeDays })
  $damagedNames = @($si.suspectPages | ForEach-Object { $_.database })

  if ($damaged -gt 0) {
    Say ('   DAMAGED PAGES: ' + [string]$damaged + ' on record, first seen ' + $earliest + ', latest ' + $latest) 'RISK'
    foreach ($r in @($si.suspectPages)) { Say ('      ' + $r.database + ': ' + [string]$r.pages + ' page(s), ' + $r.firstSeen + ' to ' + $r.lastSeen) 'RISK'}
    $ongoing = $(if ($latest -and $earliest -and $latest -ne $earliest) { ' The newest entry is NOT the oldest, so the damage is STILL BEING FOUND - this is ongoing, not a historical scar.' } else { '' })
    Risk ('SQL instance ' + $si.instance + ' has ' + [string]$damaged + ' DAMAGED PAGE(S) on record, first seen ' + $earliest + '. SQL Server wrote that date itself, on this source VM, before any migration. The damage will be copied to the target exactly as it is - a migration does not cause it and does not repair it.' + $ongoing)
    # The blocker is damage with no way back.
    $damagedNoBackup = @($noBackup | Where-Object { $damagedNames -contains $_.database })
    foreach ($d in $damagedNoBackup) {
      Block ('SQL database ' + $d.database + ' on ' + $si.instance + ' has DAMAGED PAGES and NO usable full backup (' + $(if ($d.lastFull) { 'last full ' + $d.lastFull + ', ' + [string]$d.fullAgeDays + ' days old' } else { 'no full backup on record at all' }) + '). If the cutover goes wrong there is nothing to restore. Take a verified full backup of this database and prove it restores, BEFORE the migration window.')
    }
  }
  if (@($si.neverCheckdb).Count) {
    Risk ('on ' + $si.instance + ', ' + [string]@($si.neverCheckdb).Count + ' database(s) have NEVER had a consistency check complete cleanly, on this platform: ' + ((@($si.neverCheckdb) | Select-Object -First 6) -join ', ') + '. Their true state is unknown TODAY, before the move. Corruption could have been accumulating undetected for the life of the database.')
  }
  foreach ($d in @($noBackup | Where-Object { $damagedNames -notcontains $_.database })) {
    Risk ('SQL database ' + $d.database + ' on ' + $si.instance + ' has no full backup newer than ' + [string]$BackupMaxAgeDays + ' days (' + $(if ($d.lastFull) { 'last full ' + $d.lastFull } else { 'none on record' }) + '). There is no fallback for it if the cutover goes wrong.')
  }
  $big = @($si.databases | Sort-Object { -[double]($_.sizeMB) } | Select-Object -First 1)
  if ($big.Count) { Note ('largest database on ' + $si.instance + ': ' + $big[0].database + ' at ' + $big[0].sizeMB + ' MB - size the copy window on this.') }
}


# ================================================================================================
# 7. THE RECORD - the things the migration checklist asks you to write down by hand
#
# Every item below is on the OasisCloud-to-YallaCloud pre-migration checklist and every one of
# them is normally transcribed by a person into a spreadsheet at 2am. Transcription is where the
# gateway digit gets dropped and the MAC gets mistyped, and nobody finds out until the VM is on
# the new platform with no route off it. Read it from the machine instead.
# ================================================================================================
Say 'THE RECORD (checklist items 1, 10, 13, 16, 17, 18)' 'HEAD'

# --- network identity: name, every NIC, MAC, IP, mask, gateway, DNS --------------------------
$net = @()
try {
  foreach ($c in @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop | Where-Object { $_.IPEnabled })) {
    $row = [ordered]@{
      adapter     = [string]$c.Description
      mac         = [string]$c.MACAddress
      dhcp        = [bool]$c.DHCPEnabled
      ipv4        = @(@($c.IPAddress) | Where-Object { $_ -and $_ -notmatch ':' })
      # IPSubnet carries an entry per IPAddress, so on a dual-stack NIC it mixes dotted-quad
      # masks with IPv6 prefix LENGTHS ("64", "128"). Printing those as a subnet mask next to an
      # IPv4 address is nonsense an L1 would reasonably query, so only dotted quads are kept.
      subnetMask  = @(@($c.IPSubnet)  | Where-Object { $_ -and $_ -match '^\d+\.\d+\.\d+\.\d+$' })
      gateway     = @(@($c.DefaultIPGateway))
      dns         = @(@($c.DNSServerSearchOrder))
      dnsDomain   = [string]$c.DNSDomain
      winsPrimary = [string]$c.WINSPrimaryServer
    }
    $net += $row
    Say ($row.adapter)
    Say ('   MAC        : ' + $row.mac)
    Say ('   IPv4       : ' + ((@($row.ipv4) -join ', ')) + '   mask ' + ((@($row.subnetMask) -join ', ')))
    Say ('   gateway    : ' + ((@($row.gateway) -join ', ')))
    Say ('   DNS        : ' + ((@($row.dns) -join ', ')))
    Say ('   addressing : ' + $(if ($row.dhcp) { 'DHCP' } else { 'STATIC' }))
    if ($row.dhcp) {
      Risk ('adapter "' + $row.adapter + '" is on DHCP (' + ((@($row.ipv4) -join ', ')) + '). After the move it will take whatever the new network hands it, which is NOT this address. If anything connects to this server by IP - an application, a firewall rule, a NAT entry - that breaks silently at cutover. Record the address now and decide whether it must be reserved on the target.')
    }
    if (-not @($row.gateway).Count) {
      Note ('adapter "' + $row.adapter + '" has no default gateway - normal for a second NIC on a storage or heartbeat network, but confirm the target gives it the same role.')
    }
  }
} catch { Note ('could not read the network configuration: ' + $_.Exception.Message) }
$script:Report.network = @($net)
try { $script:Report.machine.hostname = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DNSHostName } catch {}

# --- what is LISTENING. The post-migration checklist asks you to "test required ports" - this
#     is the list of what they actually were, taken before the move rather than guessed after.
$ports = @()
try {
  $conns = $null
  # Get-NetTCPConnection is 2012+; netstat is the fallback that works everywhere including 2008R2
  # remnants. OwningProcess gives the service name, which is what makes the list readable.
  try { $conns = @(Get-NetTCPConnection -State Listen -ErrorAction Stop) } catch {}
  if ($conns) {
    $byProc = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $byProc[[int]$p.Id] = $p.ProcessName }
    foreach ($g in @($conns | Group-Object LocalPort)) {
      $one = @($g.Group)[0]
      $ports += [ordered]@{ port=[int]$g.Name; process=[string]$byProc[[int]$one.OwningProcess]
                            addresses=@(@($g.Group | ForEach-Object { [string]$_.LocalAddress } | Select-Object -Unique)) }
    }
  } else {
    foreach ($line in @(cmd /c 'netstat -ano -p tcp' 2>&1)) {
      if ($line -match '^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)') {
        $ports += [ordered]@{ port=[int]$Matches[2]; process='pid ' + $Matches[3]; addresses=@($Matches[1]) }
      }
    }
    $ports = @($ports | Group-Object port | ForEach-Object { @($_.Group)[0] })
  }
} catch { Note ('could not read the listening ports: ' + $_.Exception.Message) }
$script:Report.listeningPorts = @($ports | Sort-Object { $_.port })
Say ('listening TCP ports: ' + [string]@($ports).Count + ' - ' + ((@($ports | Sort-Object { $_.port } | ForEach-Object { [string]$_.port }) | Select-Object -First 25) -join ', ') + $(if (@($ports).Count -gt 25) { ', ...' } else { '' }))
Say '   the full list with the owning process is in the JSON. After the move, the same list should come back.'

# --- Windows firewall: profile state and how many rules, so a silent reset is visible ---------
try {
  $fw = @()
  foreach ($pf in @('Domain','Private','Public')) {
    $o = ((cmd /c ('netsh advfirewall show ' + $pf.ToLower() + 'profile state') 2>&1) -join ' ')
    $fw += [ordered]@{ profile=$pf; state=$(if ($o -match '(?i)State\s+(ON|OFF)') { $Matches[1] } else { 'unknown' }) }
  }
  $rules = 0
  try { $rules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object { $_.Enabled -eq 'True' }).Count } catch {
    $txt = ((cmd /c 'netsh advfirewall firewall show rule name=all' 2>&1) -join "`n")
    $rules = @([regex]::Matches($txt,'(?m)^Rule Name:')).Count
  }
  $script:Report.firewall = [ordered]@{ profiles=@($fw); enabledRules=$rules }
  Say ('windows firewall : ' + ((@($fw | ForEach-Object { $_.profile + '=' + $_.state }) -join ', ')) + '   ' + [string]$rules + ' enabled rule(s)')
  Note ('Windows firewall rule count on the source: ' + [string]$rules + '. Compare it after the move - a rule set that silently did not come across is invisible until something cannot connect.')
} catch { Note ('could not read the Windows firewall state: ' + $_.Exception.Message) }

# --- services set to start automatically, and scheduled tasks: the "what must come back up" list
$svcAuto = @()
try {
  foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.StartMode -eq 'Auto' })) {
    $svcAuto += [ordered]@{ name=[string]$s.Name; display=[string]$s.DisplayName; state=[string]$s.State
                            account=[string]$s.StartName }
  }
} catch { Note ('could not enumerate services: ' + $_.Exception.Message) }
$script:Report.autoServices = @($svcAuto)
$notRunning = @($svcAuto | Where-Object { $_.state -ne 'Running' })
Say ('automatic services: ' + [string]@($svcAuto).Count + ', of which ' + [string]@($notRunning).Count + ' are NOT running right now')
if (@($notRunning).Count) {
  Note ('automatic services not running on the SOURCE, before the move (so do not chase them afterwards): ' + ((@($notRunning | ForEach-Object { $_.name }) | Select-Object -First 12) -join ', '))
}
# Services running under a named account will need that account to exist and that password to
# still work on the target. A domain service account on a workgroup target does not start.
$named = @($svcAuto | Where-Object { $_.account -and $_.account -notmatch '^(LocalSystem|NT AUTHORITY|NT SERVICE)' })
if (@($named).Count) {
  Risk ([string]@($named).Count + ' automatic service(s) run under a NAMED account rather than a built-in one: ' + ((@($named | ForEach-Object { $_.name + ' (' + $_.account + ')' }) | Select-Object -First 6) -join ', ') + '. Each one needs that account to exist on the target with the same password, or the service does not start after the move. Check them BEFORE the window.')
}
try {
  $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notmatch '^\\Microsoft\\' })
  $script:Report.scheduledTasks = @($tasks | ForEach-Object { [ordered]@{ name=[string]$_.TaskName; path=[string]$_.TaskPath; state=[string]$_.State } })
  Say ('non-Microsoft scheduled tasks: ' + [string]@($tasks).Count)
  if (@($tasks).Count) { Note ('scheduled tasks that must still be there after the move: ' + ((@($tasks | ForEach-Object { $_.TaskName }) | Select-Object -First 12) -join ', ')) }
} catch { Note 'could not enumerate scheduled tasks' }

# --- installed applications and their versions: checklist item 13 is "record Applite version",
#     and the same answer covers every other application on the box.
$apps = @()
try {
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    foreach ($p in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
      if (-not $p.DisplayName) { continue }
      if ($p.SystemComponent -eq 1) { continue }
      $apps += [ordered]@{ name=[string]$p.DisplayName; version=[string]$p.DisplayVersion
                           publisher=[string]$p.Publisher; installed=[string]$p.InstallDate }
    }
  }
  $apps = @($apps | Sort-Object { $_.name } -Unique)
} catch { Note ('could not read the installed applications: ' + $_.Exception.Message) }
$script:Report.installedApps = @($apps)
Say ('installed applications: ' + [string]@($apps).Count + ' recorded in the JSON (version and publisher for each)')

# ================================================================================================
# 8. THE FALLBACK - is there a backup, and can it actually be restored?
#
# Checklist items 6 to 9 ask for an Acronis backup, a separate MSSQL .bak, and "verify the SQL
# backup file and test its readability". Ticking "backup taken" is not the same as knowing it can
# be restored, and the difference only ever shows up on the day you need it.
#
# RESTORE HEADERONLY and RESTORE VERIFYONLY are READ-ONLY. Neither writes a byte to a database,
# neither touches the running instance's data, and neither needs the database offline. HEADERONLY
# reads the header: it proves the file is a real backup set and says what and when. VERIFYONLY
# reads the WHOLE file and checks the page checksums: it is the one that actually proves a
# restore would work, and it costs the time of a full read, which is why it is size-capped.
# ================================================================================================
Say 'THE FALLBACK - BACKUPS, AND WHETHER THEY RESTORE (checklist items 6-9)' 'HEAD'

# --- backup agents on the box -----------------------------------------------------------------
$agents = @()
$agentPatterns = @{
  'Acronis'   = 'acronis'
  'Veeam'     = 'veeam'
  'Commvault' = 'commvault|simpana'
  'Veritas'   = 'veritas|backup exec'
  'Rubrik'    = 'rubrik'
  'Cohesity'  = 'cohesity'
  'Azure/MARS'= 'microsoft azure recovery|obengine'
}
try {
  $all = @(Get-Service -ErrorAction Stop)
  foreach ($k in $agentPatterns.Keys) {
    $hit = @($all | Where-Object { $_.Name -match $agentPatterns[$k] -or $_.DisplayName -match $agentPatterns[$k] })
    if (-not $hit.Count) { continue }
    $running = @($hit | Where-Object { $_.Status -eq 'Running' })
    $agents += [ordered]@{ product=$k; services=[string]@($hit).Count; running=[string]@($running).Count
                           names=@(@($hit | ForEach-Object { $_.Name + '=' + $_.Status })) }
    Say ($k + ': ' + [string]@($hit).Count + ' service(s), ' + [string]@($running).Count + ' running') $(if (@($running).Count) {'OK'} else {'RISK'})
    if (-not @($running).Count) {
      Risk ($k + ' is installed on this VM but NONE of its services are running. Whatever protection it is supposed to be providing, it is not providing it right now - and this is the fallback the migration is relying on.')
    }
  }
} catch { Note ('could not enumerate the backup agents: ' + $_.Exception.Message) }
if (-not @($agents).Count) {
  Risk 'no backup agent (Acronis, Veeam, Commvault, Veritas, Rubrik, Cohesity, Azure) was found on this VM. If the migration fallback is a platform-level snapshot rather than an in-guest agent, confirm that snapshot exists and is restorable before the window.'
  Say 'no in-guest backup agent found' 'RISK'
}
$script:Report.backupAgents = @($agents)

# --- SQL backup FILES, and whether they can be read --------------------------------------------
$bakResults = @()
if (-not $SkipSql) {
  foreach ($si in @($script:Report.sql)) {
    if (-not $si.reachable) { continue }
    $target = $(if ($si.instance -eq 'MSSQLSERVER') { '.' } else { '.\' + $si.instance })
    # Ask SQL where it last wrote a backup, rather than guessing a folder. Only DISK devices:
    # a tape or a URL device is not a file we can read back.
    $files = @()
    try {
      $files = Invoke-Sql -Server $target -Query @"
SELECT TOP 40 bs.database_name AS dbname, bmf.physical_device_name AS path,
       CONVERT(varchar(30),bs.backup_finish_date,120) AS finished,
       CONVERT(decimal(18,1), bs.backup_size/1024.0/1024.0) AS sizemb, bs.type AS btype
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.type = 'D' AND bmf.device_type = 2
ORDER BY bs.backup_finish_date DESC
"@
    } catch { Note ('could not read the backup file list on ' + $si.instance + ': ' + $_.Exception.Message) }

    # One per database: the newest full. That is the one that would actually be restored.
    $seen = @{}
    foreach ($f in $files) {
      $db = [string]$f.dbname
      if ($seen[$db]) { continue }
      $seen[$db] = $true
      $row = [ordered]@{ instance=$si.instance; database=$db; path=[string]$f.path
                         finished=[string]$f.finished; sizeMB=[string]$f.sizemb
                         exists=$false; header='not checked'; verify='not checked' }
      if (-not (Test-Path -LiteralPath $row.path)) {
        $row.exists = $false
        Block ('the newest full backup of ' + $db + ' is recorded as ' + $row.path + ' (taken ' + $row.finished + ') but THAT FILE IS NOT THERE. msdb says a backup was taken; the file it points at has been moved or deleted. There is nothing to restore from at that path.')
        $bakResults += $row; continue
      }
      $row.exists = $true
      # HEADERONLY first - instant, and proves the file is a real backup set rather than a
      # zero-byte stub or a half-written file from an interrupted job.
      try {
        $h = Invoke-Sql -Server $target -Query ("RESTORE HEADERONLY FROM DISK = N'" + ($row.path -replace "'","''") + "'") -TimeoutSec 120
        if (@($h).Count) {
          $row.header = 'OK - readable backup set'
          Say ('   ' + $db + ': header OK  (' + $row.finished + ', ' + $row.sizeMB + ' MB)  ' + $row.path) 'OK'
        } else { $row.header = 'EMPTY - no backup set in the file' }
      } catch {
        $row.header = 'FAILED: ' + $_.Exception.Message.Split("`n")[0]
        Block ('the newest full backup of ' + $db + ' at ' + $row.path + ' CANNOT BE READ by SQL Server (' + $row.header + '). The file exists but it is not a usable backup. There is no fallback for this database.')
        $bakResults += $row; continue
      }
      # VERIFYONLY reads the whole file. Capped, because reading a 500 GB backup is not something
      # to start by surprise on a production box - the cap is raised with -VerifyBackups.
      $sz = 0.0; [void][double]::TryParse([string]$row.sizeMB, [ref]$sz)
      if ($VerifyBackups -or $sz -le $VerifyMaxMB) {
        Say ('   ' + $db + ': RESTORE VERIFYONLY running - reads the whole ' + $row.sizeMB + ' MB file, read-only. Please wait.')
        try {
          [void](Invoke-Sql -Server $target -Query ("RESTORE VERIFYONLY FROM DISK = N'" + ($row.path -replace "'","''") + "' WITH CHECKSUM") -TimeoutSec 7200)
          $row.verify = 'OK - verified, this backup would restore'
          Say ('   ' + $db + ': VERIFYONLY PASSED - this backup is restorable') 'OK'
        } catch {
          $row.verify = 'FAILED: ' + $_.Exception.Message.Split("`n")[0]
          Block ('RESTORE VERIFYONLY FAILED on the newest full backup of ' + $db + ' (' + $row.path + '): ' + $row.verify + '. The backup file is there and has a readable header, but its contents do not verify - restoring from it would fail. This is the fallback the migration depends on. Take a new verified backup before the window.')
        }
      } else {
        $row.verify = 'skipped - ' + $row.sizeMB + ' MB is over the ' + [string]$VerifyMaxMB + ' MB cap'
        Risk ('the newest full backup of ' + $db + ' is ' + $row.sizeMB + ' MB, over the ' + [string]$VerifyMaxMB + ' MB verify cap, so it was NOT verified - only its header was read. The header proves the file is a backup; it does not prove it restores. Run migration-check -VerifyBackups out of hours to verify it properly, or verify it by hand with RESTORE VERIFYONLY.')
      }
      $bakResults += $row
    }
    # A database with damaged pages and no backup FILE on disk at all
    foreach ($d in @($si.databases)) {
      if ($seen[$d.database]) { continue }
      Risk ('SQL database ' + $d.database + ' on ' + $si.instance + ' has NO full backup to a disk file on record at all. Whatever else protects it, there is no .bak to fall back to.')
    }
  }
}
$script:Report.backupFiles = @($bakResults)
if (@($bakResults).Count) {
  $okv = @($bakResults | Where-Object { $_.verify -like 'OK*' }).Count
  Say ('SQL backup files checked: ' + [string]@($bakResults).Count + ', fully verified: ' + [string]$okv)
}

# ================================================================================================
# 5. VSS - CAN ANY BACKUP OF THIS MACHINE ACTUALLY FREEZE IT?
#
# This decides whether the backup you are relying on as the migration fallback is worth anything.
# A snapshot taken while VSS is broken succeeds, reports success, and contains a database that was
# never quiesced. Finding that out during a failed cutover is the worst possible moment.
# vssadmin is read-only here: list writers, list providers. Nothing is created.
# ================================================================================================
Say 'THE BACKUP PATH (VSS)' 'HEAD'
$vss = [ordered]@{ writers=0; failedWriters=@(); providers=0; serviceStates=@{}
                   recentErrors=@(); verdict='UNKNOWN'; why='' }
$crit = @()
try {
  $w = ((cmd /c 'vssadmin list writers' 2>&1) -join "`n")
  $names = @([regex]::Matches($w, "Writer name:\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
  $vss.writers = @($names).Count
  foreach ($blk in ($w -split "Writer name:")) {
    if ($blk -notmatch "State:\s*\[(\d+)\]\s*(.+)") { continue }
    $state = $Matches[2].Trim()
    if ($state -notmatch '(?i)stable') {
      $nm = ''
      if ($blk -match "^\s*'([^']+)'") { $nm = $Matches[1] }
      $vss.failedWriters += ($nm + ' = ' + $state)
    }
  }
  if ($vss.writers -eq 0) { $crit += 'vssadmin returned NO WRITERS AT ALL. VSS is not answering, so no application-consistent backup of this machine can be taken by anything.' }
  elseif (@($vss.failedWriters).Count) { $crit += ([string]@($vss.failedWriters).Count + ' VSS writer(s) are not in a stable state: ' + ((@($vss.failedWriters) | Select-Object -First 4) -join '; ')) }
} catch { Note ('could not list VSS writers: ' + $_.Exception.Message) }
try {
  $p = ((cmd /c 'vssadmin list providers' 2>&1) -join "`n")
  $vss.providers = @([regex]::Matches($p, "Provider name:\s*'([^']+)'")).Count
  if ($vss.providers -eq 0) { $crit += 'NO VSS PROVIDER is registered. Snapshots cannot be created on this machine at all.' }
} catch { Note ('could not list VSS providers: ' + $_.Exception.Message) }
foreach ($svc in @('VSS','swprv','SQLWriter')) {
  try {
    $s = Get-Service -Name $svc -ErrorAction Stop
    $sm = ''
    try { $sm = [string](Get-CimInstance Win32_Service -Filter ("Name='" + $svc + "'") -ErrorAction Stop).StartMode } catch {}
    $vss.serviceStates[$svc] = $s.Status.ToString() + '/' + $sm
    if ($sm -eq 'Disabled') { $crit += ('the ' + $svc + ' service is DISABLED. VSS cannot function with it off.') }
  } catch { $vss.serviceStates[$svc] = 'absent' }
}
try {
  $ev = @(Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='VSS'; Level=1,2
                                           StartTime=(Get-Date).AddDays(-7) } -MaxEvents 50 -ErrorAction Stop)
  foreach ($g in @($ev | Group-Object Id)) {
    $t = @($g.Group | ForEach-Object { $_.TimeCreated } | Sort-Object)
    $vss.recentErrors += [ordered]@{ id=[int]$g.Name; count=$g.Count; last=$t[-1].ToString('yyyy-MM-dd HH:mm:ss') }
  }
} catch {}

Say ('writers       : ' + [string]$vss.writers + $(if (@($vss.failedWriters).Count) { '  (' + [string]@($vss.failedWriters).Count + ' NOT stable)' } else { '' })) $(if ($vss.writers -gt 0 -and -not @($vss.failedWriters).Count) {'OK'} else {'RISK'})
Say ('providers     : ' + [string]$vss.providers) $(if ($vss.providers -gt 0) {'OK'} else {'RISK'})
foreach ($k in $vss.serviceStates.Keys) { Say ('   ' + $k.PadRight(10) + ' ' + $vss.serviceStates[$k]) }
foreach ($e in @($vss.recentErrors)) { Say ('   VSS error ' + [string]$e.id + ' x' + [string]$e.count + ' in the last 7 days, latest ' + $e.last) 'RISK' }

if ($crit.Count) {
  $vss.verdict = 'BROKEN'
  $vss.why = ($crit -join ' ')
  Risk ('THE BACKUP PATH IS BROKEN ON THIS SOURCE VM: ' + $vss.why + ' Any snapshot or agent backup taken while this is true is CRASH-CONSISTENT, not application-consistent - it succeeds and reports success while the database inside it was never quiesced. Fix VSS before relying on a backup as the migration fallback.')
} elseif (@($vss.recentErrors).Count) {
  $vss.verdict = 'SUSPECT'; $vss.why = 'VSS errors in the last 7 days'
} else { $vss.verdict = 'OK'; $vss.why = 'writers and providers answered, services are not disabled'; Say 'VSS looks healthy' 'OK' }
$script:Report.vss = $vss

# THE COMBINATION THAT DECIDES IT. Damaged data is survivable if there is a good copy. A broken
# backup path is survivable if the data is sound. Both at once is the case with no way back, and
# it is the one situation this check exists to catch before a window is booked.
$anyDamaged = $false
foreach ($si in @($script:Report.sql)) { if (@($si.suspectPages).Count) { $anyDamaged = $true } }
if ($anyDamaged -and $vss.verdict -eq 'BROKEN') {
  Block 'THE DATA IS DAMAGED AND THE BACKUP PATH IS BROKEN AT THE SAME TIME. There may be no clean, restorable copy of this database anywhere. Do not migrate until there is one: fix VSS, take a full backup, and PROVE it restores somewhere else. If the cutover fails in this state there is nothing to go back to.'
}

# ================================================================================================
# 6. THE VERDICT
# ================================================================================================
$verdict = 'GO'; $code = 0
if ($script:Blockers.Count) { $verdict = 'DO NOT MIGRATE'; $code = 2 }
elseif ($script:Risks.Count) { $verdict = 'GO WITH RISK'; $code = 1 }
$script:Report.verdict  = $verdict
$script:Report.exitCode = $code
$script:Report.blockers = @($script:Blockers)
$script:Report.risks    = @($script:Risks)
$script:Report.notes    = @($script:Notes)

$banner = switch ($verdict) {
  'DO NOT MIGRATE' { 'Red' }
  'GO WITH RISK'   { 'Yellow' }
  default          { 'Green' }
}
Write-Host ''
Write-Host '================================================================================' -ForegroundColor $banner
Write-Host ('  ' + $verdict + '   -   ' + $env:COMPUTERNAME) -ForegroundColor $banner
Write-Host '================================================================================' -ForegroundColor $banner
if ($script:Blockers.Count) {
  Write-Host ''
  Write-Host ('  FIX THESE BEFORE BOOKING A WINDOW (' + [string]$script:Blockers.Count + '):') -ForegroundColor Red
  $i=0; foreach ($b in $script:Blockers) { $i++; Write-Host ('   ' + [string]$i + '. ' + $b) -ForegroundColor Red }
}
if ($script:Risks.Count) {
  Write-Host ''
  Write-Host ('  THESE TRAVEL WITH THE VM - DECIDE ON EACH (' + [string]$script:Risks.Count + '):') -ForegroundColor Yellow
  $i=0; foreach ($r in $script:Risks) { $i++; Write-Host ('   ' + [string]$i + '. ' + $r) -ForegroundColor Yellow }
}
if (-not $script:Blockers.Count -and -not $script:Risks.Count) {
  Write-Host ''
  Write-Host '  Nothing found that should stop this migration. Every drive scanned clean, the' -ForegroundColor Green
  Write-Host '  data has no damage on record, and the backup path works.' -ForegroundColor Green
}

# --- write the evidence file -------------------------------------------------------------------
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$base  = Join-Path $OutDir ('migration-check-' + $env:COMPUTERNAME + '-' + $stamp)
try {
  if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
  $txt = New-Object System.Collections.Generic.List[string]
  $txt.Add('================================================================================') | Out-Null
  $txt.Add('  MIGRATION READINESS - ' + $env:COMPUTERNAME) | Out-Null
  $txt.Add('  taken on the SOURCE platform, BEFORE any migration') | Out-Null
  $txt.Add('================================================================================') | Out-Null
  $txt.Add('  when     : ' + $script:Report.generatedUtc) | Out-Null
  $txt.Add('  verdict  : ' + $verdict) | Out-Null
  $txt.Add('') | Out-Null
  $txt.Add('  Every date in this file was written by Windows or by SQL Server ON THIS MACHINE,') | Out-Null
  $txt.Add('  on the source platform, before it was migrated. Anything dated before the') | Out-Null
  $txt.Add('  migration existed before the migration.') | Out-Null
  $txt.Add('') | Out-Null
  if ($script:Blockers.Count) {
    $txt.Add('--- FIX BEFORE MIGRATING -------------------------------------------------------') | Out-Null
    $i=0; foreach ($b in $script:Blockers) { $i++; $txt.Add('  ' + [string]$i + '. ' + $b) | Out-Null }
    $txt.Add('') | Out-Null
  }
  if ($script:Risks.Count) {
    $txt.Add('--- TRAVELS WITH THE VM --------------------------------------------------------') | Out-Null
    $i=0; foreach ($r in $script:Risks) { $i++; $txt.Add('  ' + [string]$i + '. ' + $r) | Out-Null }
    $txt.Add('') | Out-Null
  }
  if ($script:Notes.Count) {
    $txt.Add('--- NOTED ----------------------------------------------------------------------') | Out-Null
    foreach ($nn in $script:Notes) { $txt.Add('  - ' + $nn) | Out-Null }
    $txt.Add('') | Out-Null
  }
  $txt.Add('--- FULL LOG -------------------------------------------------------------------') | Out-Null
  foreach ($l in $script:Log) { $txt.Add($l) | Out-Null }
  Set-Content -LiteralPath ($base + '.txt') -Value $txt -Encoding Ascii
  $script:Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($base + '.json') -Encoding Ascii
  Write-Host ''
  Write-Host ('  REPORT : ' + $base + '.txt') -ForegroundColor White
  Write-Host ('  JSON   : ' + $base + '.json')
  # SHA256 through .NET, NOT Get-FileHash. Measured: on a machine whose PSModulePath had
  # PowerShell 7 ahead of 5.1, Get-FileHash did not resolve at all - and because it sat in the
  # same try block as the writes, its failure printed "could not write the report" over a report
  # that HAD been written. The hash is a nice-to-have; the path is not.
  $sha = ''
  try {
    $fs = [IO.File]::OpenRead($base + '.txt')
    try { $sha = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) }
    finally { $fs.Dispose() }
    Write-Host ('  SHA256 : ' + $sha.ToUpper())
  } catch { Write-Host '  SHA256 : could not be computed on this host (the report itself is fine)' }
  $script:Report.reportSha256 = $sha.ToUpper()
  Write-Host '  Keep both files. They are the record of what this VM was like BEFORE it moved.'
} catch { Write-Host ('  COULD NOT WRITE THE REPORT: ' + $_.Exception.Message) -ForegroundColor Red }

if ($Json) { Write-Host ''; $script:Report | ConvertTo-Json -Depth 8 }
Write-Host ''
Finish $code
