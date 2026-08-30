param(
  [string]$Zip = 'C:/Windows/Temp/yc-update.zip',
  [string]$Url = '',
  [string]$Sha = '',
  [string]$ShaUrl = '',
  # Directories under C:\Scripts that a FULL OVERWRITE must not touch. These hold
  # vendor binaries and drivers - roughly 1.7 GB - that the payload deliberately
  # does not ship, so deleting them is not recoverable from the zip. Pass -Keep @()
  # to wipe C:\Scripts completely and leave ONLY the payload.
  [string[]]$Keep = @('virtio','Sysinternals','DiagTools'),
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
  -Sha           expected SHA256 of the zip        (skip the check if omitted - not advised)
  -NoCompliance  do not run yc-compliance after the swap
  -Help          show this help and exit

WHAT IT DOES:
  1 verify the zip hash          4 copy the payload over C:\Scripts
  2 extract the payload          5 run C:\Scripts\Yc-Compliance.ps1
  3 back up ONLY the files       6 roll the backup back if the gate fails
    the payload will replace

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
function Die([int]$code,[string]$m){ Say $m 'ERROR'; Say ('END exit=' + $code); exit $code }

Say ('START host=' + $env:COMPUTERNAME + ' ps=' + $PSVersionTable.PSVersion)

# --- 0 elevation -------------------------------------------------------------
$isAdmin = $false
try{
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}catch{}
if(-not $isAdmin){ Die 5 'Must run as Administrator.' }

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
      Say ('Sidecar fetch failed: ' + $_.Exception.Message + ' - continuing without a hash check.') 'WARN'
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
      Die 3 ('Download failed: ' + $_.Exception.Message)
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
}else{
  Say ('No -Sha given; zip hash is ' + $got) 'WARN'
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
$relSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($r in $rels){ [void]$relSet.Add($r) }

$doomed = @()
foreach($f in (Get-ChildItem -LiteralPath $S -Recurse -File -Force -EA SilentlyContinue)){
  $rel = $f.FullName.Substring($S.Length).TrimStart('\')
  $top = ($rel -split '\\')[0]
  if($Keep -contains $top){ continue }          # vendor payload, not ours to delete
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
Copy-Item -Path (Join-Path $tmp '*') -Destination $S -Recurse -Force
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
      Copy-Item -Path (Join-Path $Bak '*') -Destination $S -Recurse -Force
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
Remove-Item -LiteralPath $Bak -Recurse -Force -EA SilentlyContinue
if(Test-Path -LiteralPath $Bak){ Say ('Could not remove the temporary rollback copy at ' + $Bak + ' - delete it by hand.') 'WARN' }
Say ('Updated. C:\Scripts now holds this payload and nothing else' + $(if($Keep.Count){ ' (except ' + ($Keep -join ', ') + ')' }else{ '' }) + '. No backup was kept.') 'OK'
Say 'END exit=0'
exit 0
