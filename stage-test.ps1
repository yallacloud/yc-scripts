<#
================================================================================================
  YALLACLOUD - STAGED TEST RUN of migrated-vm, for a DISPOSABLE box.

  WHY THIS EXISTS
    Every SQL phase in migrated-vm has been written against proven shapes but has never met a
    live instance. This runs them on a box you are willing to throw away, in an order where the
    interesting phases are also the FAST ones, and bundles every log into one file to send back.

  THE OPTIONAL STAGES, AND WHAT THEY COST
    -IncludeTools      stage D. Chocolatey, git, .NET 4.8, PowerShell 7, dbatools, winget.
                       SSMS is NOT in it: it is the single longest download in the payload and
                       nothing in the corruption-prevention path needs it. Add -IncludeSsms to
                       pull it too, and expect to wait.
    -IncludeTasks      stage F. YC-AutoUpdate and YC-Inventory - the two recurring jobs. Fast.
                       Both are REMOVED again in step 3, so this proves registration and
                       readback without leaving anything running on this box.
    -IncludeDiskScan   stage E. Registers YC-DiskScan, which is a chkdsk /scan at 05:15. The
                       REGISTRATION is instant; the scan itself never runs here because step 3
                       removes the task. Nothing long happens during this stage.
    The deferred CHECKDB baseline task is REMOVED at the end if SQLMAINT ever registers it, so
    nothing fires at 02:15 on a box with failing storage.

  WHAT IT EXPECTS TO HAPPEN on the box this was written for
    SQLPREP    PASS   - chadmin exists and is already sysadmin; S4U gets proven
    BASELINE   PASS   - writes baseline_beforemigration.log naming the damaged database
    SQLHARDEN  NO-OP  - every database is already PAGE_VERIFY CHECKSUM; reports the SIMPLE ones
    SQLMAINT   REFUSE - suspect_pages is full, so it must not schedule a CHECKDB
    SQLBACKUP  REFUSE - Acronis is running AND the data will not fit the free space
    TOOLS      PASS   - installs what is missing; already-present tools are reported, not reinstalled
    TASKS      PASS   - registers YC-AutoUpdate and YC-Inventory, reads both back, then removes them
    DISKSCAN   PASS   - registers YC-DiskScan and reads it back, then removes it
    A refusal here is a PASS. Two of these phases are supposed to say no.

  RUN IT (elevated). The plain one-liner runs stages A-C only, because iex cannot pass arguments:
    [Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm https://raw.githubusercontent.com/yallacloud/yc-scripts/main/stage-test.ps1)

  TO GET THE OPTIONAL STAGES, save it first and then call it with switches:
    [Net.ServicePointManager]::SecurityProtocol='Tls12'
    irm https://raw.githubusercontent.com/yallacloud/yc-scripts/main/stage-test.ps1 -OutFile $env:TEMP\st.ps1
    & $env:TEMP\st.ps1 -IncludeTools -IncludeTasks -IncludeDiskScan
================================================================================================
#>
param([switch]$IncludeTools,[switch]$IncludeSsms,[switch]$IncludeTasks,[switch]$IncludeDiskScan)
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$Dir = 'C:\Scripts'
$Url    = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip'
$ShaUrl = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256'

function Say { param([string]$m,[string]$c='Gray') Write-Host ('  ' + $m) -ForegroundColor $c }

Write-Host ''
Write-Host '  YALLACLOUD - STAGED TEST RUN (disposable box)' -ForegroundColor Green
Write-Host ''

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$admin = $false
try { $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
if (-not $admin) { Say 'Run this from an ELEVATED PowerShell.' 'Red'; exit 5 }

# ---- 1. get the payload -----------------------------------------------------------------------
Say 'STEP 1  fetching and verifying the payload...'
if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
$tmp = Join-Path $env:TEMP ('yc-stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'p.zip'
try {
  Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
  $side = (Invoke-WebRequest -Uri $ShaUrl -UseBasicParsing).Content
} catch { Say ('download failed: ' + $_.Exception.Message) 'Red'; exit 6 }
$want = ([string]$side -split '\s+')[0].Trim().ToUpper()
$got  = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpper()
if ($want -ne $got) { Say 'SHA256 MISMATCH - nothing extracted.' 'Red'; exit 4 }
Say ('payload verified ' + $got.Substring(0,16) + '...') 'Green'
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $z = [IO.Compression.ZipFile]::OpenRead($zip)
  try { foreach ($e in $z.Entries) { if ($e.Name) {
          $d = Join-Path $Dir $e.FullName
          $pd = Split-Path $d -Parent
          if (-not (Test-Path $pd)) { New-Item -ItemType Directory -Path $pd -Force | Out-Null }
          [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $d, $true) } } }
  finally { $z.Dispose() }
} catch { Say ('extract failed: ' + $_.Exception.Message) 'Red'; exit 4 }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue }
Say ((@(Get-ChildItem $Dir -File).Count).ToString() + ' files in C:\Scripts') 'Green'

# ---- 2. the staged phases ---------------------------------------------------------------------
$adopt = Join-Path $Dir 'Adopt-MigratedVm.ps1'
$stages = @(
  @{ n='A  SQLPREP + BASELINE + SQLHARDEN'; a=@('-Run','-Only','SURVEY,SQLPREP,BASELINE,SQLHARDEN'); expect='PASS, with SQLHARDEN a no-op and the SIMPLE databases reported' },
  @{ n='B  SQLMAINT  (EXPECTED TO REFUSE)'; a=@('-Run','-Only','SURVEY,SQLMAINT');   expect='REFUSE - suspect_pages is not empty' },
  @{ n='C  SQLBACKUP (EXPECTED TO REFUSE)'; a=@('-Run','-Only','SURVEY,SQLBACKUP');  expect='REFUSE - another backup scheme, and/or the data will not fit' }
)
if ($IncludeTools) {
  # SSMS is opt-in inside an opt-in. It is a multi-hundred-megabyte installer and nothing in the
  # corruption-prevention path calls it, so it must not be what makes this stage look like a hang.
  $ta = @('-Run','-Only','SURVEY,TOOLS')
  if (-not $IncludeSsms) { $ta += '-SkipSsms' }
  $stages += @{ n=('D  TOOLS' + $(if ($IncludeSsms) {' + SSMS (very slow)'} else {' (no SSMS)'}))
                a=$ta
                expect=('Chocolatey, git, .NET, PowerShell 7, dbatools, winget' + $(if ($IncludeSsms) {', SSMS'} else {' - SSMS skipped'})) }
}
if ($IncludeDiskScan) { $stages += @{ n='E  DISKSCAN'; a=@('-Run','-Only','SURVEY,SQLPREP,DISKSCAN'); expect='registers YC-DiskScan - the registration is instant, the scan never runs here' } }
if ($IncludeTasks)    { $stages += @{ n='F  TASKS';    a=@('-Run','-Only','SURVEY,TASKS');            expect='registers YC-AutoUpdate and YC-Inventory, both proven by readback' } }

$results = @()
foreach ($s in $stages) {
  Write-Host ''
  Say ('STAGE ' + $s.n) 'Cyan'
  Say ('  expected: ' + $s.expect)
  $t0 = Get-Date
  $p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -NoNewWindow `
         -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$adopt) + $s.a)
  $secs = [int]((Get-Date) - $t0).TotalSeconds
  $results += [pscustomobject]@{ stage=$s.n; exit=$p.ExitCode; seconds=$secs; expected=$s.expect }
  Say ('  -> exit ' + $p.ExitCode + '   (' + $secs + 's)') $(if ($p.ExitCode -in @(0,2,3)) {'Green'} else {'Yellow'})
}

# ---- 3. READ BACK what was registered, THEN remove it ------------------------------------------
# The whole point of a schedule test is the readback. Removing a task without first recording what
# it was, when it fired and WHO it ran as proves nothing except that Unregister works.
$YcTasks = @('YC-IntegrityBaseline','YC-SqlIntegrityFast','YC-SqlIntegrity','YC-SqlRestoreVerify',
             'YC-DiskScan','YC-AutoUpdate','YC-Inventory','YC-AdoptResume','YC-S4U-Probe')
$taskDump = New-Object System.Collections.Generic.List[string]
Write-Host ''
Say 'STEP 3  reading back every task this run could have registered...'
foreach ($t in $YcTasks) {
  try {
    $st = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if (-not $st) { $null = $taskDump.Add(('  {0,-22} ABSENT' -f $t)); continue }
    $who = ''
    try { $who = $st.Principal.UserId + ' / ' + $st.Principal.LogonType + ' / ' + $st.Principal.RunLevel } catch {}
    $trg = ''
    try { $trg = (@($st.Triggers | ForEach-Object { $_.CimClass.CimClassName + '@' + [string]$_.StartBoundary }) -join ' ; ') } catch {}
    $act = ''
    try { $act = (@($st.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -join ' ; ') } catch {}
    $null = $taskDump.Add(('  {0,-22} PRESENT' -f $t))
    $null = $taskDump.Add( '     runs as : ' + $who)
    $null = $taskDump.Add( '     trigger : ' + $trg)
    $null = $taskDump.Add( '     action  : ' + $act)
    Say ('  ' + $t + '  ->  ' + $who) 'Green'
  } catch { $null = $taskDump.Add(('  {0,-22} could not be read: {1}' -f $t, $_.Exception.Message)) }
}

Say 'removing anything that would fire later on this box...'
foreach ($t in $YcTasks) {
  try { if (Get-ScheduledTask -TaskName $t -EA SilentlyContinue) {
          Unregister-ScheduledTask -TaskName $t -Confirm:$false
          Say ('  removed ' + $t) 'Yellow' } } catch {}
}
Say '  nothing from this test will run on a schedule.' 'Green'

# ---- 4. bundle everything ----------------------------------------------------------------------
$deskDir = Join-Path $env:USERPROFILE 'Desktop'
if (-not (Test-Path $deskDir)) { $deskDir = $env:TEMP }
$bundle = Join-Path $deskDir ('yc-stagetest-' + $env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$b = New-Object System.Collections.Generic.List[string]
$null = $b.Add('================================================================================')
$null = $b.Add('  YALLACLOUD STAGED TEST RUN')
$null = $b.Add('================================================================================')
$null = $b.Add('  host      : ' + $env:COMPUTERNAME)
$null = $b.Add('  ran       : ' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC')
$null = $b.Add('  payload   : ' + $(if (Test-Path (Join-Path $Dir 'yc-payload-version.txt')) { ((Get-Content (Join-Path $Dir 'yc-payload-version.txt') -TotalCount 1) -replace '^[^=]*=\s*','').Trim() } else { '?' }))
$null = $b.Add('')
$null = $b.Add('  A REFUSAL IS A PASS. Stages B and C are supposed to say no.')
$null = $b.Add('')
foreach ($r in $results) { $null = $b.Add(('  {0,-40} exit {1,-3} {2,4}s   expected: {3}' -f $r.stage, $r.exit, $r.seconds, $r.expected)) }
$null = $b.Add('')
$null = $b.Add('================================================================================')
$null = $b.Add('  SCHEDULED TASKS as they stood BEFORE step 3 removed them')
$null = $b.Add('================================================================================')
foreach ($line in $taskDump) { $null = $b.Add($line) }
$null = $b.Add('')
$null = $b.Add('================================================================================')
$null = $b.Add('  TOOLS - what is actually on this host now')
$null = $b.Add('================================================================================')
# This process started BEFORE the installs ran, so its PATH does not have them and
# "choco.exe is not recognized" was this probe's own blind spot, not a failed install - it said
# choco, git and winget were absent on a run whose own logs recorded all three installing
# successfully. Re-read the machine and user PATH, then probe by install path, never by name.
try {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
} catch {}
function Probe-Exe {
  param([string[]]$Paths,[string[]]$Args)
  foreach ($p in $Paths) {
    foreach ($hit in @(Get-ChildItem -Path $p -ErrorAction SilentlyContinue | Select-Object -First 1)) {
      try { return ((& $hit.FullName @Args 2>&1 | Where-Object { $_ } | Select-Object -First 1) | Out-String).Trim() }
      catch { return ('present at ' + $hit.FullName + ' but would not run: ' + $_.Exception.Message) }
    }
  }
  return ''
}
foreach ($probe in @(
    @{ n='choco';    c={ Probe-Exe -Paths @('C:\ProgramData\chocolatey\bin\choco.exe') -Args @('--version') } },
    @{ n='git';      c={ Probe-Exe -Paths @('C:\Program Files\Git\cmd\git.exe','C:\Program Files (x86)\Git\cmd\git.exe') -Args @('--version') } },
    @{ n='winget';   c={ Probe-Exe -Paths @((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'),'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller*\winget.exe') -Args @('--version') } },
    @{ n='pwsh 7';   c={ Probe-Exe -Paths @('C:\Program Files\PowerShell\7\pwsh.exe','C:\Program Files\PowerShell\7-preview\pwsh.exe') -Args @('-NoProfile','-Command','$PSVersionTable.PSVersion.ToString()') } },
    @{ n='dbatools'; c={ (@(Get-Module dbatools -ListAvailable -EA SilentlyContinue | ForEach-Object { [string]$_.Version }) -join ', ') } },
    @{ n='.NET rel'; c={ (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -EA SilentlyContinue).Release } },
    @{ n='ssms';     c={ (@(Get-ChildItem 'C:\Program Files (x86)\Microsoft SQL Server Management Studio*' -EA SilentlyContinue).Count) } })) {
  $val = ''
  try { $val = [string](& $probe.c) } catch { $val = 'probe failed: ' + $_.Exception.Message }
  if (-not $val) { $val = '(absent)' }
  $null = $b.Add(('  {0,-10} {1}' -f $probe.n, $val))
}
foreach ($f in @('adopt-migrated-vm.log','baseline_beforemigration.log','adopt-migrated-vm.state.json','pageverify.undo.json','yc-integrity.log','yc-autoupdate.log','report-inventory.log','dbatools-install.log','install-dotnet.log')) {
  $p2 = Join-Path $Dir $f
  $null = $b.Add(''); $null = $b.Add('================================================================================')
  $null = $b.Add('  ' + $f); $null = $b.Add('================================================================================')
  if (Test-Path $p2) { foreach ($line in (Get-Content $p2)) { $null = $b.Add($line) } }
  else { $null = $b.Add('  (not present)') }
}
$sv = @(Get-ChildItem (Join-Path $Dir 'survey') -Filter '*.json' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
if ($sv.Count) {
  $null = $b.Add(''); $null = $b.Add('================================================================================')
  $null = $b.Add('  ' + $sv[0].Name); $null = $b.Add('================================================================================')
  foreach ($line in (Get-Content $sv[0].FullName)) { $null = $b.Add($line) }
}
$b -join "`r`n" | Set-Content -LiteralPath $bundle -Encoding Ascii
Write-Host ''
Say ('BUNDLE: ' + $bundle) 'Green'
Say 'Send that one file back. It has every log from this run.' 'Green'
Write-Host ''
