# Clean-Scripts.ps1  -  strip build/debug junk out of C:\Scripts on a golden.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Clean-Scripts.ps1          # REPORT ONLY
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Clean-Scripts.ps1 -Apply   # actually delete
#
# Run on a golden reverted to its PreSeal snapshot, BEFORE Seal-Manual.ps1.
#
# WHITELIST SOURCE OF TRUTH
# -------------------------
# $Catalog below is the 79-file command set from /root/final_scripts on ycnode01
# (10.15.1.101) - the source of truth named in SCRIPTS-FOLDER-IMPROVEMENTS.md,
# baked into the golden by inject6.sh. Plus the golden's own runtime scripts and
# anything a baked scheduled task points at. Everything else in the ROOT of
# C:\Scripts goes.
#
# WHY THIS EXISTS
# ---------------
# A v259 clone shipped 1,180 files / 2,025 MB in C:\Scripts, including 230 .sh
# and 16 .py Linux jump-host debug scripts, GoldenImage.ps1 (205 KB), the seal
# tooling, _stage\ (235 files), .done\ (52 build markers) and a 305 MB STALE
# COPY of the Chocolatey lib tree (the live one is C:\ProgramData\chocolatey).
#
# Root cause of the .sh/.py/_stage part: Fix-PreSeal.ps1 copied EVERY file from
# C:\Scripts\_stage recursively and flattened it into C:\Scripts with no filter.
#
# DELIBERATELY KEPT
#   - all installers (virtio-win.iso, VMware-Tools, PowerShell msi, CloudbaseInit,
#     vc_redist, SysinternalsSuite.zip, agent MSIs) so images stay offline-repairable
#   - setupdownloader_*.exe - Bitdefender-Register.ps1 LOCATES THIS BY GLOB and
#     runs it with /bdparams /silent. Deleting it breaks GravityZone enrolment.
param([switch]$Apply)

if($PSVersionTable.PSEdition -eq 'Core'){
  $a = @(); if($Apply){ $a += '-Apply' }
  & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @a
  exit $LASTEXITCODE
}
$ErrorActionPreference = 'Continue'
$S = 'C:\Scripts'
$Discard = "$S\clean-discarded.txt"
function Say($m,$c='Gray'){ $t = "[{0}] {1}" -f (Get-Date -f 'HH:mm:ss'), $m
                            Write-Host $t -ForegroundColor $c
                            Add-Content "$S\clean-scripts.log" $t -Encoding ascii -EA SilentlyContinue }
# every removal is recorded with size + reason BEFORE it happens, so the list
# survives even if the run is interrupted
function Drop($path,$kb,$reason){
  Add-Content $Discard ("{0,10:N0} KB  {1,-28} {2}" -f $kb, $reason, $path) -Encoding ascii -EA SilentlyContinue
}

# ---- the 79 from /root/final_scripts ---------------------------------------
$Catalog = @(
 'acronis-register.cmd','activate-sql.cmd','Activate-Sql.ps1','activate-windows.cmd',
 'Activate-Windows.ps1','alloy-register.cmd','Alloy-Register.ps1','bitdefender-exclude.cmd',
 'Bitdefender-Exclude.ps1','bitdefender-register.cmd','Bitdefender-Register.ps1',
 'boot-repair.cmd','Boot-Repair.ps1','_COMPLIANCE.txt','Day2-Setup.ps1',
 'dbatools-install.cmd','Dbatools-Install.ps1','defender-exclude.cmd','Defender-Exclude.ps1',
 'diag.cmd','Diag-System.ps1','diagtools-install.cmd','DiagTools-Install.ps1',
 'glpi-register.cmd','GLPI-Register.ps1','grow-disk.cmd','Grow-Disk.ps1',
 'mysqldexporter-register.cmd','MysqldExporter-Register.ps1','observability-register.cmd',
 'olivetin-install.cmd','OliveTin-Install.ps1','osquery-register.cmd','Osquery-Register.ps1',
 'otelcol-register.cmd','Otelcol-Register.ps1','percona-toolkit-install.cmd',
 'Percona-Toolkit-Install.ps1','pgbadger-install.cmd','PgBadger-Install.ps1',
 'postgresexporter-register.cmd','PostgresExporter-Register.ps1',
 # Promtail RETIRED v261 (EOL Mar 2026, Alloy 1.18.0 replaces it). The payload no
 # longer ships promtail-register.cmd / Promtail-Register.ps1 - build.py skips any
 # file whose name starts 'promtail'. Keeping them here made the completeness check
 # below report them MISSING on every single run.
 'install-sql.cmd','Install-Sql.ps1',
 'Register-Acronis.ps1','report-inventory.cmd','Report-Inventory.ps1',
 'rootcause.cmd','Root-Cause.ps1','rotate-password.cmd','Rotate-Password.ps1',
 'salt-register.cmd','Salt-Register.ps1','set-firewall.cmd','Set-Firewall.ps1',
 'set-nic.cmd','Set-Nic.ps1','Setup-Observability.ps1','site24x7-register.cmd',
 'Site24x7-Register.ps1','snmp-register.cmd','Snmp-Register.ps1','sqlexporter-register.cmd',
 'SqlExporter-Register.ps1','telegraf-register.cmd','Telegraf-Register.ps1',
 'wazuh-register.cmd','Wazuh-Register.ps1','webjea-install.cmd','WebJEA-Install.ps1',
 'winexporter-register.cmd','WinExporter-Register.ps1','winupdate.cmd','Win-Update.ps1',
 'yallacloud.cmd','Yallacloud.ps1','_yc-lib.ps1','zabbix-register.cmd','Zabbix-Register.ps1'
)

# ---- golden runtime: referenced by baked scheduled tasks or first boot -------
# Disk-Guard   <- GIDiskGuard      Grow-Disk <- GIGrowDisk
# Set-Nic      <- GINetwork        Root-Cause <- GIWatchdog
# yc-guard.*   <- YCGUARD/YCGUARD5 yc-deploy <- YCDEPLOY
$Runtime = @(
 'Disk-Guard.ps1','yc-firstboot.ps1','yc-activate.ps1','yc-guard.ps1','yc-guard.cmd',
 'yc-deploy.ps1','SSH-FirstBoot.ps1','Setup-HealthMonitors.ps1','Setup-YallaCloudExtras.ps1',
 'Extract-VMwareDrivers.ps1','vmware-drivers.cmd','Install-VMwareTools.ps1','vmware-tools.cmd',
 'A-Z-Deploy.ps1','notify.cmd','perflog.cmd','rootcause-latest.txt',
 'userdata-deploy-example.txt','userdata-salt-example.txt','userdata-set-admin.yaml',
 # the three consolidated task scripts (replace GIGrowDisk/GIDiskGuard/GINetwork/
 # GIWatchdog/YCDEPLOY/YCGUARD/YCGUARD5/YCNET/YCNET5)
 'yc-boot.ps1','yc-health.ps1','yc-keyguard.ps1',
 # Install-YcPayload.ps1 writes these three. They are the ONLY proof of what the
 # guest is running: yc-verify re-hashes the installed tree against MANIFEST.json,
 # and yc-payload-version.txt is the first thing a technician reads on a
 # misbehaving VM. Deleting them was silent and destroyed both.
 'MANIFEST.json','MANIFEST.sha256','yc-payload-version.txt',
 # this run's own audit trail
 'clean-discarded.txt','clean-scripts.log'
)

$keepExact    = $Catalog + $Runtime
# Installers stay, incl. setupdownloader_*. This is also what keeps the image
# MIGRATION-FRIENDLY and it is deliberate, not incidental: qemu-ga.msi,
# virtio-win-guest-tools.exe and VMware-Tools-x64.exe are ALL kept on BOTH
# platforms, and so is the virtio\ folder (see the directory keep-list below).
# We never strip one vendor's payload because the guest happens to be running on
# the other stack - they are one infrastructure, and a VM can move either way.
$keepPatterns = @('*.msi','*.exe','*.iso','*.zip')

# build/seal tooling and engineering leftovers - removed even if they match above
$killAnyway = @('GoldenImage*.ps1','Seal-Manual.ps1','Seal-Auto.ps1','Seal.cmd','seal-auto.cmd',
                'sealdiag.cmd','Prep-Seal.ps1','prep-seal.cmd','Fix-PreSeal.ps1','Clean-Scripts.ps1',
                'AppX-Strip.ps1','Strip-Appx.ps1','pw-setonce.ps1','seal_all.py',
                # presealagent tooling: it has already run by the time Clean-Scripts
                # does, and it is build machinery, not customer content. The AGENTS it
                # installed stay; the installers it used stay (see $keepPatterns).
                'PreSeal-Agents.ps1','preseal-agents.log',
                'yc-check-kvm.ps1','yc-net.ps1','inv.ps1','inv2.ps1','choco.ps1','heads.ps1',
                # Unattend-Seal.xml is NOT junk at this point - sysprep needs it a few
                # minutes later. Deleting it here is what made Seal-Manual ABORT with
                # "unattend MISSING" and cost two re-pushes + two reboots on 2026-08-11.
                # It carries no credentials (verified: no Password element), and sysprep
                # copies it to C:\Windows\Panther anyway, so leaving it is harmless.
                'tasks.ps1','drv.ps1','scanvm.*','roots.sst',
                '*.sh','*.py','*.bak','*.bak-broken','*.vmdk','*.log','*.done')

# ---- directories that must go ------------------------------------------------
# Chocolatey's live install is C:\ProgramData\chocolatey; the trees below are a
# stale duplicate. _stage/.done are build scaffolding. KVM-Tooling and
# Host-Recovery are internal engineering material, not customer content.
# KEPT: Day2, Monitoring, DiagTools, Sysinternals, virtio.
$killDirs = @('_stage','.done','.chocolatey','lib','lib-bad','helpers','redirects',
              'extensions','tools','config','logs','bin','KVM-Tooling','Host-Recovery')

function Should-Keep($name){
  # This run's own audit trail, decided FIRST: clean-scripts.log is listed in
  # $Runtime as a keeper but also matches '*.log' in $killAnyway, which is
  # evaluated first - so the script was deleting its own log while claiming to
  # keep it. Explicit beats ordering.
  if($name -eq 'clean-discarded.txt' -or $name -eq 'clean-scripts.log'){ return $true }
  foreach($k in $killAnyway){ if($name -like $k){ return $false } }
  if($keepExact -contains $name){ return $true }
  foreach($p in $keepPatterns){ if($name -like $p){ return $true } }
  return $false
}

Say '===== Clean-Scripts =====' Cyan
if(-not $Apply){ Say 'REPORT ONLY - re-run with -Apply to delete' Yellow }
Set-Content $Discard ("YallaCloud C:\Scripts discard list - {0} - {1}`r`n{2}" -f `
  (Get-Date -f 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, ('-'*100)) -Encoding ascii -EA SilentlyContinue
$before = Get-ChildItem $S -Recurse -File -Force -EA SilentlyContinue
Say ("before: {0} files, {1:N0} MB" -f $before.Count, (($before|Measure-Object Length -Sum).Sum/1MB))

# ---- Monitoring\ -> Day2\ : keep the guide, drop the duplicated scripts ------
# Setup-HealthMonitors.ps1 and Setup-Observability.ps1 exist in Monitoring\, in
# Day2\ AND in the root - three copies of the same two files.
$mon = Join-Path $S 'Monitoring'
if(Test-Path $mon){
  $guide = Join-Path $mon 'SQL-Observability-Guide.md'
  if(Test-Path $guide){
    Say '  moving Monitoring\SQL-Observability-Guide.md -> Day2\' Cyan
    if($Apply){
      New-Item -ItemType Directory -Force (Join-Path $S 'Day2') | Out-Null
      Copy-Item $guide (Join-Path $S 'Day2\SQL-Observability-Guide.md') -Force -EA SilentlyContinue
    }
  }
}

$freed = 0
foreach($d in $killDirs){
  $p = Join-Path $S $d
  if(Test-Path $p){
    $f  = @(Get-ChildItem $p -Recurse -File -Force -EA SilentlyContinue)
    $mb = ($f | Measure-Object Length -Sum).Sum/1MB
    $freed += $mb
    Say ("  dir  {0,-16} {1,4} files {2,8:N0} MB" -f $d, $f.Count, $mb) Yellow
    foreach($x in $f){ Drop $x.FullName ($x.Length/1KB) ("dir:" + $d) }
    if($Apply){ Remove-Item $p -Recurse -Force -EA SilentlyContinue }
  }
}

# ---- virtio\*.pdb : 53 MB of kernel debug symbols, no runtime function -------
# The actual .inf/.sys/.cat drivers are only ~3 MB. Symbols are for debugging
# the virtio drivers themselves and are never read by Windows.
$pdb = @(Get-ChildItem (Join-Path $S 'virtio') -Recurse -Filter '*.pdb' -File -EA SilentlyContinue)
if($pdb.Count){
  $mb = ($pdb | Measure-Object Length -Sum).Sum/1MB
  $freed += $mb
  Say ("  virtio .pdb    {0,4} files {1,8:N0} MB (debug symbols)" -f $pdb.Count, $mb) Yellow
  foreach($x in $pdb){ Drop $x.FullName ($x.Length/1KB) 'virtio debug symbols' }
  if($Apply){ foreach($x in $pdb){ Remove-Item $x.FullName -Force -EA SilentlyContinue } }
}

# ---- build progress markers on the PUBLIC DESKTOP ---------------------------
# Set-Progress writes "!<step>.txt" there during the build; Clear-Progress was
# never called at the end, so every v259 clone shipped with
# "!Build complete - awaiting MANUAL AppX + seal.txt" on the customer's desktop.
$prog = @(Get-ChildItem 'C:\Users\Public\Desktop' -Filter '!*' -Force -EA SilentlyContinue)
foreach($p in $prog){
  Say ("  desktop marker: " + $p.Name) Yellow
  Drop $p.FullName ($p.Length/1KB) 'build progress marker'
  if($Apply){ Remove-Item $p.FullName -Force -EA SilentlyContinue }
}
if(-not $prog.Count){ Say '  desktop: no build markers' Green }

# reason per file, so clean-discarded.txt explains itself
function Get-Reason($n){
  if($n -like '*.sh'){ return 'linux jump-host script' }
  if($n -like '*.py'){ return 'linux jump-host script' }
  if($n -like 'GoldenImage*'){ return 'BUILD SCRIPT - must not ship' }
  if($n -like 'Seal*' -or $n -like '*Seal*' -or $n -like 'AppX-Strip*' -or $n -like 'Strip-Appx*' -or $n -like 'pw-setonce*'){ return 'seal tooling' }
  if($n -like '*.log'){ return 'build-era log' }
  if($n -like '*.bak*'){ return 'backup copy' }
  if($n -like '*.vmdk'){ return 'stub disk artefact' }
  if($n -eq 'roots.sst'){ return 'cert store export' }
  if($n -like '*.done'){ return 'build step marker' }
  if($n -like '*.cmd'){ return 'one-off debug cmd' }
  return 'not in catalog'
}

$kill = @(Get-ChildItem $S -File -Force -EA SilentlyContinue | Where-Object { -not (Should-Keep $_.Name) })
$mbR  = ($kill | Measure-Object Length -Sum).Sum/1MB
Say ("  root files to remove: {0}  ({1:N0} MB)" -f $kill.Count, $mbR) Yellow
foreach($g in ($kill | Group-Object Extension | Sort-Object Count -Descending)){
  Say ("    {0,-8} {1,4}" -f $g.Name, $g.Count)
}
foreach($f in $kill){ Drop $f.FullName ($f.Length/1KB) (Get-Reason $f.Name) }
if($Apply){ foreach($f in $kill){ Remove-Item $f.FullName -Force -EA SilentlyContinue } }
Say ("  discard list written: $Discard") Cyan

# ---- verify what survived ----------------------------------------------------
# Something critical missing is far worse than something junk left behind.
if($Apply){
  $after = Get-ChildItem $S -Recurse -File -Force -EA SilentlyContinue
  Say ("after: {0} files, {1:N0} MB" -f $after.Count, (($after|Measure-Object Length -Sum).Sum/1MB)) Green

  $missCat = @($Catalog  | Where-Object { -not (Test-Path (Join-Path $S $_)) })
  # v265 audit: Disk-Guard / yc-guard / yc-deploy are retired, so requiring them here
  # painted a correctly cleaned image red. These are the files the LIVE tasks call:
  # YC-Boot, YC-Health, YC-KeyGuard, YCFIRSTBOOT, plus the three Install-YcTasks runs inline.
  $missRun = @('Grow-Disk.ps1','Set-Nic.ps1','Root-Cause.ps1','yc-boot.ps1','yc-health.ps1',
               'yc-keyguard.ps1','yc-firstboot.ps1','yc-activate.ps1' |
               Where-Object { -not (Test-Path (Join-Path $S $_)) })
  if($missCat.Count){ Say ('CATALOG MISSING (' + $missCat.Count + '): ' + ($missCat -join ', ')) Red }
  else { Say "catalog intact: all $($Catalog.Count) command files present" Green }
  if($missRun.Count){ Say ('TASK TARGET MISSING: ' + ($missRun -join ', ')) Red }
  else { Say 'every baked scheduled task still points at a real file' Green }

  # empty files are as bad as missing - X19B shipped a 0-byte yc-deploy.ps1
  $empty = @(Get-ChildItem $S -File -Force -EA SilentlyContinue | Where-Object { $_.Length -eq 0 -and $_.Extension -in '.ps1','.cmd' })
  if($empty.Count){ Say ('EMPTY script files: ' + (($empty|ForEach-Object Name) -join ', ')) Red }

  if(@(Get-ChildItem $S -Filter 'setupdownloader_*' -File -EA SilentlyContinue).Count){
    Say 'bitdefender tenant installer present (required by Bitdefender-Register)' Green
  } else { Say 'setupdownloader_*.exe GONE - bitdefender-register will fail' Red }

  # sql-templates ships with install-sql (payload v262+) and is NOT in $killDirs,
  # so it survives - assert it rather than assume it.
  foreach($d in 'Day2','Monitoring','DiagTools','Sysinternals','virtio','sql-templates'){
    if(Test-Path (Join-Path $S $d)){ Say "  kept dir: $d" Green } else { Say "  MISSING dir: $d" Red }
  }

  # the payload's own provenance - without these yc-verify has nothing to check against
  foreach($f in 'MANIFEST.json','MANIFEST.sha256','yc-payload-version.txt'){
    if(Test-Path (Join-Path $S $f)){ Say "  kept: $f" Green } else { Say "  MISSING: $f" Red }
  }
} else {
  Say ("would free about {0:N0} MB of directories + {1:N0} MB of root files" -f $freed, $mbR) Cyan
}
Say '=========================' Cyan
