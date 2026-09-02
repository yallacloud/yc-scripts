param(
  [string]$Zip = 'C:/Windows/Temp/yc-update.zip',
  # These DEFAULT to the canonical payload. They used to default to empty, and the
  # consequences were both real and silent: run with no arguments the script either
  # exited 3 because it had no idea where the payload lives, or - worse - found a stale
  # yc-update.zip left in Temp by an earlier run and installed it with NO hash check at
  # all. Two template VMs were put back onto a v264 payload that way on 2026-08-30.
  # The one script whose whole job is "make C:\Scripts current" now knows where current is.
  [string]$Url    = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip',
  [string]$Sha = '',
  [string]$ShaUrl = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256',
  # Install a zip that nothing has verified. Offline use only, and it has to be asked for.
  [switch]$AllowUnverified,
  # Directories under C:\Scripts that a FULL OVERWRITE must not touch. These hold
  # vendor binaries and drivers - roughly 1.7 GB - that the payload deliberately
  # does not ship, so deleting them is not recoverable from the zip. Pass -Keep @()
  # to wipe C:\Scripts completely and leave ONLY the payload.
  [string[]]$Keep = @('virtio','Sysinternals','DiagTools'),
  # Once-per-clone STATE FILES a full overwrite must not delete. .authorized_keys.baked is
  # yc-keyguard's only copy of the tenant SSH key - the last way back in - and the rest are
  # markers that gate destructive first-boot steps. None ship in the zip, so without this
  # list every sync destroyed them.
  [string[]]$KeepFile = @('.rearm-done','.sshhostkeys','.provisioned','.goldenimage','.authorized_keys.baked','.firstboot-runs','.payload-sha256'),
  [switch]$NoCompliance,
  [switch]$Help
)
# Update-YcScripts.ps1 - replace C:\Scripts from a verified payload zip.
# Windows PowerShell 5.1, ASCII only, SELF-CONTAINED on purpose:
# it must not dot-source _yc-lib.ps1, because it is replacing _yc-lib.ps1.
#
# Exit codes: 0 ok | 2 bad args | 3 zip missing | 4 SHA mismatch
#             5 not admin | 6 extract failed | 7 compliance failed (rolled back)

if($Help){
@"
update-yc-scripts  -  verify + install a repaired C:\Scripts payload.

USAGE:
  Update-YcScripts.ps1 -Zip C:/Windows/Temp/yc-update.zip -Sha <SHA256>
  Update-YcScripts.ps1 -Url <zip url> -ShaUrl <sha256 url>     (hash from a sidecar;
                                                                the caller never changes)
  Update-YcScripts.ps1 -Help

PARAMETERS:
  -Zip           path to the payload zip           (default C:/Windows/Temp/yc-update.zip)
  -Url           HTTPS URL to fetch the payload from when -Zip is absent or does not match -Sha.
                 This is what cloud-init uses: the guest pulls the current payload itself instead
                 of waiting for somebody to scp it. TLS 1.2 is forced before the download, because
                 on Windows Server 2016 .NET otherwise offers TLS 1.0 and the transfer fails with
                 "the underlying connection was closed" - which reads as "no internet".
  -Sha           expected SHA256 of the zip. Omitted, the hash comes from -ShaUrl instead;
                 if neither yields a hash the script REFUSES to install rather than
                 overwrite C:\Scripts from something unverified.
  -AllowUnverified  install anyway with no hash. Offline use only.
  -ShaUrl        HTTPS URL of the .sha256 sidecar next to the zip. Use this instead of -Sha so the
                 caller never has to change when a new payload is published: the guest fetches the
                 current hash itself. This is what the cloud-init user data uses.

                 If either HTTPS fetch fails and the URL is on raw.githubusercontent.com, it falls
                 back to a shallow git clone of the same repo - every YallaCloud server has git.
                 The remote, branch and path are DERIVED from the URL, so nothing new is passed and
                 the user data stays frozen. github.com and raw.githubusercontent.com are separate
                 hosts that can fail independently, and git does its own TLS through schannel rather
                 than .NET, so the fallback is unaffected by the Server 2016 TLS 1.0 default. The
                 clone is temporary and deleted on every exit path.
  -Keep          directories under C:\Scripts a full overwrite must NOT delete.
                 Default: virtio, Sysinternals, DiagTools - roughly 1.7 GB of vendor binaries and
                 drivers the payload deliberately does not ship, so deleting them is not
                 recoverable from the zip. Pass -Keep @() to wipe C:\Scripts completely and leave
                 ONLY the payload.
  -NoCompliance  do not run yc-compliance after the swap
  -Help          show this help and exit

WHAT IT DOES - FULL OVERWRITE, NO BACKUP KEPT:
  1 verify the zip hash          4 copy the payload over C:\Scripts
  2 extract the payload          5 DELETE every file in C:\Scripts that is not in the
  3 stage a rollback copy in       payload, except the -Keep directories
    %windir%\Temp for the       6 run C:\Scripts\Yc-Compliance.ps1
    duration of this run only    7 roll back if the gate fails, then delete the copy

  Nothing named C:\Scripts.bak-* is ever created, and the rollback copy is deleted at the
  end of every run, pass or fail. A script dropped from the payload therefore disappears
  from the VM instead of lingering as a stale command on the PATH.

EXAMPLES:
  Update-YcScripts.ps1 -Sha 36320738570079C0E78EA4933B6C8A361BF9AB5BEF4BECF96DA6D19C4E8B3713
  Update-YcScripts.ps1 -Url https://dist.example.com/yc/YallaCloud-CScripts.zip -Sha 0A36...
  Update-YcScripts.ps1 -Zip D:/yc.zip -Sha 9f2c... -NoCompliance

Log: C:\Windows\Temp\update-yc-scripts.log
"@ | Write-Host -ForegroundColor Cyan
  exit 0
}

$ErrorActionPreference = 'Stop'
$S    = 'C:\Scripts'
$Stamp= (Get-Date).ToString('yyyyMMdd-HHmmss')
# Rollback copy lives in TEMP and is deleted at the end of every run, pass or
# fail. Nothing named C:\Scripts.bak-* is ever created - those accumulated on
# every VM and were never cleaned up.
$Bak  = Join-Path $env:windir ('Temp\yc-rollback-' + $Stamp)
$script:GitClone = $null   # set by the git fallback below; declared here so the cleanup can always read it
$Log  = 'C:\Windows\Temp\update-yc-scripts.log'

function Say([string]$m,[string]$lvl='INFO'){
  $line = ('{0}  [YC-UPDATE] [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),$lvl,$m)
  switch($lvl){
    'ERROR'{ Write-Host $line -ForegroundColor Red }
    'WARN' { Write-Host $line -ForegroundColor Yellow }
    'OK'   { Write-Host $line -ForegroundColor Green }
    default{ Write-Host $line }
  }
  try{ Add-Content -LiteralPath $Log -Value $line -Encoding ASCII -EA SilentlyContinue }catch{}
}
# Every exit path clears the temporary rollback copy. Nothing this script stages
# may outlive the run: a leftover directory on a customer's VM is exactly what the
# no-backup rule exists to prevent.
function Remove-YcRollback{
  if($Bak -and (Test-Path -LiteralPath $Bak)){
    Remove-Item -LiteralPath $Bak -Recurse -Force -EA SilentlyContinue
    if(Test-Path -LiteralPath $Bak){ Say ('Could not remove the temporary rollback copy at ' + $Bak + ' - delete it by hand.') 'WARN' }
  }
  # The git fallback clone is temporary too. Same rule: nothing this script stages
  # may outlive the run.
  if($script:GitClone -and (Test-Path -LiteralPath $script:GitClone)){
    Remove-Item -LiteralPath $script:GitClone -Recurse -Force -EA SilentlyContinue
    if(Test-Path -LiteralPath $script:GitClone){ Say ('Could not remove the temporary git clone at ' + $script:GitClone + ' - delete it by hand.') 'WARN' }
  }
}
function Die([int]$code,[string]$m){ Say $m 'ERROR'; Remove-YcRollback; Say ('END exit=' + $code); exit $code }
trap { Say ('Unhandled: ' + $_.Exception.Message) 'ERROR'; Remove-YcRollback; Say 'END exit=1'; exit 1 }

Say ('START host=' + $env:COMPUTERNAME + ' ps=' + $PSVersionTable.PSVersion)

# --- 0 elevation -------------------------------------------------------------
$isAdmin = $false
try{
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}catch{}
if(-not $isAdmin){ Die 5 'Must run as Administrator.' }

# --- git fallback -------------------------------------------------------------
# Every YallaCloud server has git installed, so when the direct HTTPS fetch fails
# there is a second way to the same bytes. It is a FALLBACK, not the primary path:
# a raw download is 744 KB and a shallow clone is a couple of MB, so the plain
# download stays first.
#
# Two reasons it is worth having. github.com and raw.githubusercontent.com are
# different hosts and can be filtered or fail independently. And git does its own
# TLS through schannel rather than .NET, so it is unaffected by the Server 2016
# TLS 1.0 default that breaks Invoke-WebRequest on exactly the machines that need
# this script most.
#
# The repo, branch and path are DERIVED from the raw URL, so cloud-init user data
# passes nothing new and stays frozen.
$RawRx = '^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$'

function Get-YcGitClone{
  param([string]$RawUrl)
  if($script:GitClone -and (Test-Path -LiteralPath $script:GitClone)){ return $script:GitClone }
  $m = [regex]::Match($RawUrl, $RawRx)
  if(-not $m.Success){ Say ('Not a raw.githubusercontent.com URL, no git fallback: ' + $RawUrl) 'WARN'; return $null }
  $git = Get-Command git.exe -EA SilentlyContinue
  if(-not $git){ Say 'git is not on PATH - no fallback available.' 'WARN'; return $null }
  $remote = 'https://github.com/' + $m.Groups[1].Value + '/' + $m.Groups[2].Value + '.git'
  $branch = $m.Groups[3].Value
  $dest   = Join-Path $env:windir ('Temp\yc-gitfetch-' + $Stamp)
  if(Test-Path -LiteralPath $dest){ Remove-Item -LiteralPath $dest -Recurse -Force -EA SilentlyContinue }
  Say ('Falling back to git: clone --depth 1 --branch ' + $branch + ' ' + $remote)
  try{
    & git.exe clone --depth 1 --branch $branch --quiet $remote $dest 2>&1 | Out-Null
  }catch{
    Say ('git clone threw: ' + $_.Exception.Message) 'WARN'; return $null
  }
  if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dest)){
    Say ('git clone failed (exit ' + $LASTEXITCODE + ').') 'WARN'
    if(Test-Path -LiteralPath $dest){ Remove-Item -LiteralPath $dest -Recurse -Force -EA SilentlyContinue }
    return $null
  }
  $script:GitClone = $dest
  Say ('git clone OK -> ' + $dest + ' (temporary, removed at the end)') 'OK'
  return $dest
}

# Returns $true and writes $OutFile, or $false. Never throws - the caller decides
# whether a miss is fatal.
function Get-YcFileViaGit{
  param([string]$RawUrl,[string]$OutFile)
  $m = [regex]::Match($RawUrl, $RawRx)
  if(-not $m.Success){ return $false }
  $root = Get-YcGitClone -RawUrl $RawUrl
  if(-not $root){ return $false }
  $src = Join-Path $root ($m.Groups[4].Value -replace '/','\')
  if(-not (Test-Path -LiteralPath $src)){ Say ('Not in the clone: ' + $m.Groups[4].Value) 'WARN'; return $false }
  $dir = Split-Path -Parent $OutFile
  if($dir -and -not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  try{ Copy-Item -LiteralPath $src -Destination $OutFile -Force -EA Stop }catch{ return $false }
  return $true
}

# --- 1 fetch (cloud-init path) -----------------------------------------------
# Download only when we do not already hold the right bytes. Re-fetching a payload
# that already matches -Sha is pure waste, and on a slow link it is the difference
# between a first boot that finishes and one that looks hung.
if($Url){
  # TLS 1.2 FIRST. Both the sidecar fetch and the payload download need it, and
  # Server 2016 defaults .NET to TLS 1.0.
  try{
    $want = [Net.SecurityProtocolType]::Tls12
    if([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13'){ try{ $want = $want -bor ([Net.SecurityProtocolType]'Tls13') }catch{} }
    [Net.ServicePointManager]::SecurityProtocol = $want
  }catch{}

  # -ShaUrl fetches the expected hash from a sidecar file published next to the
  # payload. That is the whole point: the caller - cloud-init user data baked into
  # a sealed template - then NEVER has to change when the payload changes. Push a
  # new zip and a new .sha256, and every future VM picks both up.
  #
  # Be clear about what this is: a CORRUPTION check, not tamper protection. The
  # sidecar comes from the same place as the zip, so anyone who can rewrite one can
  # rewrite the other. What actually protects the payload is who has write access
  # to that repository.
  if($ShaUrl -and -not $Sha){
    try{
      $raw = (Invoke-WebRequest -Uri $ShaUrl -UseBasicParsing -TimeoutSec 120).Content
      $txt = if($raw -is [byte[]]){ [Text.Encoding]::ASCII.GetString($raw) } else { [string]$raw }
      if($txt -match '([0-9a-fA-F]{64})'){
        $Sha = $Matches[1].ToUpper()
        Say ('Expected SHA256 from sidecar: ' + $Sha) 'OK'
      } else {
        Say ('Sidecar ' + $ShaUrl + ' held no SHA256 - continuing without a hash check.') 'WARN'
      }
    }catch{
      Say ('Sidecar fetch failed: ' + $_.Exception.Message + ' - trying git.') 'WARN'
      $tmpSha = Join-Path $env:windir ('Temp\yc-sha-' + $Stamp + '.txt')
      if(Get-YcFileViaGit -RawUrl $ShaUrl -OutFile $tmpSha){
        $txt = Get-Content -LiteralPath $tmpSha -Raw
        Remove-Item -LiteralPath $tmpSha -Force -EA SilentlyContinue
        $m2 = [regex]::Match($txt, '([0-9a-fA-F]{64})')
        if($m2.Success){ $Sha = $m2.Groups[1].Value.ToUpper(); Say ('Expected SHA256 from sidecar (via git): ' + $Sha) 'OK' }
        else{ Say 'Sidecar from git held no SHA256 - continuing without a hash check.' 'WARN' }
      } else {
        # 2026-08-30: this used to continue and install an UNVERIFIED payload over all of
        # C:\Scripts. A transient network fault must not silently turn integrity off.
        Die 4 'Could not obtain the expected SHA256 from the sidecar over HTTPS or git. Refusing to install an unverified payload.'
      }
    }
  }

  $need = $true
  if(Test-Path -LiteralPath $Zip){
    if($Sha){
      $h = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToUpper()
      if($h -eq $Sha.Trim().ToUpper()){ $need = $false; Say ('Payload already present and matches -Sha - not downloading.') 'OK' }
      else{ Say ('Payload present but hash ' + $h + ' does not match -Sha - downloading again.') 'WARN' }
    } else {
      Say 'Payload present and no -Sha to check it against - downloading again to be sure.' 'WARN'
    }
  }
  if($need){
    # Server 2016 defaults .NET to TLS 1.0. Without this the download fails on exactly
    # the machines that need this script most.
    try{
      $want = [Net.SecurityProtocolType]::Tls12
      if([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13'){ try{ $want = $want -bor ([Net.SecurityProtocolType]'Tls13') }catch{} }
      [Net.ServicePointManager]::SecurityProtocol = $want
    }catch{}
    Say ('Downloading payload: ' + $Url)
    $dir = Split-Path -Parent $Zip
    if($dir -and -not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try{
      Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing -TimeoutSec 900
      Say ('Downloaded ' + (Get-Item -LiteralPath $Zip).Length + ' bytes.') 'OK'
    }catch{
      Say ('Download failed: ' + $_.Exception.Message + ' - trying git.') 'WARN'
      if(Get-YcFileViaGit -RawUrl $Url -OutFile $Zip){
        Say ('Fetched ' + (Get-Item -LiteralPath $Zip).Length + ' bytes via git.') 'OK'
      } else {
        Die 3 ('Download failed and the git fallback did not produce the payload either: ' + $_.Exception.Message)
      }
    }
  }
}

# --- 2 verify ----------------------------------------------------------------
if(-not (Test-Path -LiteralPath $Zip)){ Die 3 ('Payload not found: ' + $Zip + $(if($Url){''}else{' - and no -Url was given to fetch it'})) }
$got = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToUpper()
if($Sha){
  $want = $Sha.Trim().ToUpper()
  if($got -ne $want){ Die 4 ('SHA256 mismatch. want=' + $want + ' got=' + $got) }
  Say ('SHA256 verified ' + $got) 'OK'
}elseif($AllowUnverified){
  Say ('No expected hash and -AllowUnverified was given; installing UNVERIFIED zip ' + $got) 'WARN'
}else{
  Die 4 ('No expected SHA256 could be established for ' + $Zip + ' (hash ' + $got + '). ' +
         'Refusing to overwrite C:\Scripts from a payload nothing has verified. ' +
         'Pass -Sha / -ShaUrl, or -AllowUnverified if you really mean it.')
}

# --- 3 extract ---------------------------------------------------------------
if(-not (Test-Path -LiteralPath $S)){
  New-Item -ItemType Directory -Path $S -Force | Out-Null
  Say 'C:\Scripts did not exist; created it.' 'WARN'
}
$tmp = Join-Path $env:TEMP ('yc-upd-' + $Stamp)
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try{
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path -LiteralPath $Zip).Path, $tmp)
}catch{
  Say ('Extract failed: ' + $_.Exception.Message) 'ERROR'
  Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue
  Die 6 'Nothing was changed; C:\Scripts is untouched.'
}
# Relative names come from the ZIP CENTRAL DIRECTORY, not from substring-ing
# FileInfo.FullName against a Resolve-Path root: those two can disagree (8.3
# short path vs long path) and the slice then silently yields a garbage
# relative name, so nothing matches and nothing gets backed up.
$rels = @()
try{
  $za = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Zip).Path)
  try{
    foreach($e in $za.Entries){ if($e.Name){ $rels += $e.FullName.Replace('/','\') } }
  } finally { $za.Dispose() }
}catch{
  Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue
  Die 6 ('Could not read the zip index: ' + $_.Exception.Message)
}
Say ('Extracted ' + $rels.Count + ' files')

# --- 3 stage a rollback copy, then FULL OVERWRITE -----------------------------
# "Full overwrite" means C:\Scripts ends up holding the payload and nothing else:
# a script deleted from the payload must disappear from the VM, not linger as a
# stale command on the PATH. So every file that is not in this payload is removed,
# except under the -Keep directories (vendor binaries and drivers the payload does
# not carry, ~1.7 GB, unrecoverable from a 736 KB zip).
#
# The rollback copy covers everything about to be removed OR replaced, lives in
# TEMP, and is deleted at the end either way. No .bak directory is left behind.
# Copy a tree file by file, never all-or-nothing.
#
# This used to be two bare 'Copy-Item -Path <dir>\* -Destination C:\Scripts -Recurse -Force'
# calls under $ErrorActionPreference='Stop'. A single locked file aborts the whole call
# part-way through, and on the ROLLBACK path that is unrecoverable: the payload's files have
# already been deleted, so C:\Scripts is left gutted and the script dies unhandled.
#
# MEASURED 2026-09-01 on 100.64.20.8: install-sql was running, so C:\Scripts\install-sql.log
# was open. The gate failed, rollback deleted the new payload, and the restore threw
# "The process cannot access the file ... because it is being used by another process" on
# that one log. Exit 1, no rollback, 53 of ~150 files left in C:\Scripts, and every command
# on the box gone. A rollback that can leave the machine worse than either state is not a
# rollback.
#
# So: per file, count what fails, and let the caller report it. A log we cannot overwrite is
# a nuisance; a C:\Scripts we cannot restore is an outage.
function Copy-YcTree{
  param([string]$From,[string]$To)
  $ok = 0; $bad = @()
  foreach($f in (Get-ChildItem -LiteralPath $From -Recurse -File -Force -EA SilentlyContinue)){
    $rel = $f.FullName.Substring($From.Length).TrimStart('\')
    $dst = Join-Path $To $rel
    $dir = Split-Path -Parent $dst
    try{
      if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -EA Stop
      $ok++
    }catch{ $bad += $rel }
  }
  [pscustomobject]@{ Copied = $ok; Failed = $bad }
}

$relSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($r in $rels){ [void]$relSet.Add($r) }

$doomed = @()
foreach($f in (Get-ChildItem -LiteralPath $S -Recurse -File -Force -EA SilentlyContinue)){
  $rel = $f.FullName.Substring($S.Length).TrimStart('\')
  $top = ($rel -split '\\')[0]
  if($Keep -contains $top){ continue }          # vendor payload, not ours to delete
  if($KeepFile -contains $f.Name){ continue }   # once-per-clone state, never in the zip
  $doomed += [pscustomobject]@{ Full = $f.FullName; Rel = $rel }
}

$saved = 0
foreach($d in $doomed){
  $dst = Join-Path $Bak $d.Rel
  $dir = Split-Path -Parent $dst
  if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  try{ Copy-Item -LiteralPath $d.Full -Destination $dst -Force -EA Stop; $saved++ }catch{}
}
Say ('Rollback copy staged: ' + $saved + ' file(s) -> ' + $Bak + ' (temporary, removed at the end)')

$removed = 0
foreach($d in $doomed){
  if(-not $relSet.Contains($d.Rel)){
    try{ Remove-Item -LiteralPath $d.Full -Force -EA Stop; $removed++ }catch{
      Say ('Could not remove stale file ' + $d.Rel + ': ' + $_.Exception.Message) 'WARN'
    }
  }
}
Say ('Full overwrite: removed ' + $removed + ' file(s) not in this payload. Kept: ' + ($(if($Keep.Count){ $Keep -join ', ' }else{ '(nothing - full wipe)' })))

# --- 4 copy over --------------------------------------------------------------
Say ('Copying payload over ' + $S)
$cp = Copy-YcTree -From $tmp -To $S
if($cp.Failed.Count){ Say ('Could not write ' + $cp.Failed.Count + ' payload file(s) (locked): ' + ($cp.Failed -join ', ')) 'WARN' }
Say ('Copied ' + $cp.Copied + ' file(s) into ' + $S)
Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue

# --- 5 gate ------------------------------------------------------------------
$gate = Join-Path $S 'Yc-Compliance.ps1'
if($NoCompliance){
  Say 'Compliance gate skipped (-NoCompliance).' 'WARN'
}elseif(-not (Test-Path -LiteralPath $gate)){
  Say 'Yc-Compliance.ps1 not in payload; gate skipped.' 'WARN'
}else{
  Say 'Running compliance gate...'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gate | Out-Host
  $rc = $LASTEXITCODE
  if($rc -ne 0){
    Say ('Gate FAILED (exit ' + $rc + ') - rolling back from ' + $Bak) 'ERROR'
    if(Test-Path -LiteralPath $Bak){
      # Clear what the payload just wrote, then restore. A plain copy-back would
      # leave the payload's NEW files behind - files that did not exist before -
      # so the "rollback" would not actually restore the previous state.
      foreach($f in (Get-ChildItem -LiteralPath $S -Recurse -File -Force -EA SilentlyContinue)){
        $rel = $f.FullName.Substring($S.Length).TrimStart('\')
        $top = ($rel -split '\\')[0]
        if($Keep -contains $top){ continue }
        try{ Remove-Item -LiteralPath $f.FullName -Force -EA Stop }catch{}
      }
      $rb = Copy-YcTree -From $Bak -To $S
      if($rb.Failed.Count){
        # Say it out loud and KEEP the copy. A half restore that deletes its own evidence
        # leaves nobody a way back.
        Say ('Rollback restored ' + $rb.Copied + ' file(s) but could NOT restore ' + $rb.Failed.Count + ': ' + ($rb.Failed -join ', ')) 'ERROR'
        Die 7 ('C:\Scripts is INCOMPLETE. The rollback copy has been KEPT at ' + $Bak + ' - copy it back by hand once nothing is holding those files.')
      }
      Remove-Item -LiteralPath $Bak -Recurse -Force -EA SilentlyContinue
      Die 7 'Rolled back. C:\Scripts is as it was before this run.'
    }
    Die 7 'Nothing to roll back to (C:\Scripts had none of these files before this run).'
  }
  Say 'Compliance gate PASS (exit 0)' 'OK'
}

# --- 6 report ----------------------------------------------------------------
try{ & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $S 'Yallacloud.ps1') -Version | Out-Host }catch{}
# The rollback copy has done its job. Delete it: nothing is left on the VM, which
# is the point - C:\Scripts.bak-* directories used to pile up on every host and
# were never cleaned up by anything.
Remove-YcRollback
# Record the hash we actually installed. yc-payload-version.txt is a BUILD artefact and
# carries the hash of whatever the golden image was assembled from - it is not updated by a
# payload sync, so it drifts immediately and cannot be used to answer 'am I current?'.
# yc-autoupdate reads this file instead. Written last, after the gate, so a rolled-back run
# never claims a payload it did not keep.
try{ Set-Content -LiteralPath (Join-Path $S '.payload-sha256') -Value $got -Encoding ASCII -EA Stop }catch{}
Say ('Updated. C:\Scripts now holds this payload and nothing else' + $(if($Keep.Count){ ' (except ' + ($Keep -join ', ') + ')' }else{ '' }) + '. No backup was kept.') 'OK'
Say 'END exit=0'
exit 0
