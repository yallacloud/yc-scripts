<#
================================================================================================
  YALLACLOUD - STAGED TEST RUN of migrated-vm, for a DISPOSABLE box.

  WHY THIS EXISTS
    Every SQL phase in migrated-vm has been written against proven shapes but has never met a
    live instance. This runs them on a box you are willing to throw away, in an order where the
    interesting phases are also the FAST ones, and bundles every log into one file to send back.

  WHAT IT DELIBERATELY DOES NOT RUN
    TOOLS      installs Chocolatey, git, PowerShell 7, dbatools, SSMS. Minutes, and the least
               interesting thing to prove. Pass -IncludeTools if you want it.
    DISKSCAN   chkdsk /scan on a 1 TB volume. Long. Pass -IncludeDiskScan if you want it.
    The deferred CHECKDB baseline task is REMOVED at the end if SQLMAINT ever registers it, so
    nothing fires at 02:15 on a box with failing storage.

  WHAT IT EXPECTS TO HAPPEN on the box this was written for
    SQLPREP    PASS   - chadmin exists and is already sysadmin; S4U gets proven
    BASELINE   PASS   - writes baseline_beforemigration.log naming the damaged database
    SQLHARDEN  NO-OP  - every database is already PAGE_VERIFY CHECKSUM; reports the SIMPLE ones
    SQLMAINT   REFUSE - suspect_pages is full, so it must not schedule a CHECKDB
    SQLBACKUP  REFUSE - Acronis is running AND the data will not fit the free space
    A refusal here is a PASS. Two of these five phases are supposed to say no.

  RUN IT (elevated):
    [Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm https://raw.githubusercontent.com/yallacloud/yc-scripts/main/stage-test.ps1)
================================================================================================
#>
param([switch]$IncludeTools,[switch]$IncludeDiskScan)
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
if ($IncludeTools)    { $stages += @{ n='D  TOOLS (slow)';    a=@('-Run','-Only','SURVEY,TOOLS');    expect='installs Chocolatey, git, PS7, dbatools, SSMS' } }
if ($IncludeDiskScan) { $stages += @{ n='E  DISKSCAN (slow)'; a=@('-Run','-Only','SURVEY,DISKSCAN'); expect='registers YC-DiskScan' } }

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

# ---- 3. make sure nothing is left scheduled on a box with failing storage ----------------------
Write-Host ''
Say 'STEP 3  removing anything that would fire later on this box...'
foreach ($t in @('YC-IntegrityBaseline','YC-SqlIntegrityFast','YC-SqlIntegrity','YC-SqlRestoreVerify','YC-DiskScan','YC-AdoptResume','YC-S4U-Probe')) {
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
foreach ($f in @('adopt-migrated-vm.log','baseline_beforemigration.log','adopt-migrated-vm.state.json','pageverify.undo.json','yc-integrity.log')) {
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
