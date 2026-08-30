# Install-YcPayload.ps1 - verify and install the YallaCloud payload artifact.
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Install-YcPayload.ps1 -Zip C:\Temp\ycpayload-v261.zip
#
# Four hash gates, each one throws on failure - a partial or unverified
# install must never be reported as success:
#   gate 1  zip            vs its detached <zip>.sha256
#   gate 2  MANIFEST.json  vs its detached MANIFEST.sha256   <- authenticates the
#                                                                manifest BEFORE any
#                                                                member hash inside
#                                                                it is trusted
#   gate 3  every member,  as extracted,       vs MANIFEST.json
#   gate 4  every member,  as installed on disk, vs MANIFEST.json
#
# Gate 2 is the one that matters: hashing members against an unauthenticated
# manifest proves nothing, because a bad build rewrites the manifest and the
# members together. Get the ordering (1, then 2, then 3/4) wrong and the
# other gates are decoration.
#
# MANIFEST.json member schema (as emitted by build.py): name, target,
# install_to, bytes, sha256, source_url, version, channel, pinned, source,
# fetched_at.
#   target     = path INSIDE the artifact      (e.g. commands\Yallacloud.ps1)
#   install_to = absolute Windows destination   (e.g. C:\Scripts\Yallacloud.ps1)
# install_to is authoritative for where a member lands - it is never derived
# from target or name.
#
# This script does NOT register scheduled tasks; Install-YcTasks.ps1 owns that.
[CmdletBinding()]
param(
  [string]$Zip,
  [switch]$DotSourceOnly,
  [switch]$Help
)

function Get-YcFileHash{
  param([string]$Path)
  # Get-FileHash streams the file; it never loads a whole member into memory,
  # which matters here since some members reach ~693 MB.
  # -LiteralPath, not -Path: several artifact members (e.g. the Bitdefender
  # setupdownloader_[...].exe) have literal [ ] in their filename, which -Path
  # treats as wildcard glob syntax and silently matches zero files.
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Assert-YcHash{
  param([string]$Path,[string]$Expected,[string]$What)
  if(-not (Test-Path -LiteralPath $Path)){ throw ("${What}: file not found: $Path") }
  $actual = Get-YcFileHash -Path $Path
  if($actual -ne $Expected.ToLower()){
    throw ("$What hash mismatch for {0}: expected {1} got {2}" -f $Path, $Expected.ToLower(), $actual)
  }
}

if($DotSourceOnly){ return }

if($Help){
@'
USAGE:
  Install-YcPayload.ps1 [-Zip <path to ycpayload-<ver>.zip>]

PARAMETERS:
  -Zip            Path to the ycpayload-<ver>.zip artifact to install. A
                  sibling <name>.sha256 detached hash file must exist next
                  to it (e.g. ycpayload-v263.zip.sha256).
                  OPTIONAL: if omitted, the newest C:\Scripts\ycpayload-v*.zip
                  is used, which is the one the image shipped with.
  -DotSourceOnly  Load the Get-YcFileHash / Assert-YcHash functions only, for
                  dot-sourcing from a test script. Installs nothing.
  -Help           Show this help and exit.

EXAMPLES:
  Install-YcPayload.ps1
        install the newest ycpayload-v*.zip already in C:\Scripts.
  Install-YcPayload.ps1 -Zip C:\Temp\ycpayload-v263.zip
        install a specific artifact.
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Install-YcPayload.ps1
'@ | Write-Host
  exit 0
}

$ErrorActionPreference = 'Stop'
$S = 'C:\Scripts'

# Best-effort logging via the shared lib. A missing or broken lib must never
# block an install, so this is wrapped and silently degrades to Write-Host.
$haveLib = $false
try{
  if(Test-Path -LiteralPath "$S\_yc-lib.ps1"){
    . "$S\_yc-lib.ps1"
    Start-YcLog 'install-ycpayload'
    $haveLib = $true
  }
}catch{ $haveLib = $false }
function LogInfo([string]$m){ if($haveLib){ Write-YcLog $m } else { Write-Host $m } }
function LogErr([string]$m){ if($haveLib){ Write-YcLog $m 'ERROR' } else { Write-Host $m -ForegroundColor Red } }

# v265 audit: -Zip was mandatory and the help named a version (v261) that is not the
# one the image ships (v263). L1 had to know the version number to run this at all.
# Default to the newest artifact sitting in C:\Scripts.
if(-not $Zip){
  $cand = @(Get-ChildItem -LiteralPath $S -Filter 'ycpayload-v*.zip' -File -EA SilentlyContinue |
            Sort-Object Name -Descending)
  if($cand.Count){ $Zip = $cand[0].FullName; LogInfo ('no -Zip given, using ' + $Zip) }
}
if(-not $Zip){ throw 'Install-YcPayload.ps1: no -Zip given and no ycpayload-v*.zip found in C:\Scripts (run with -Help for usage).' }

$stage = $null
$ok = $false
try{
  # gate 1 - the artifact is exactly what the builder produced
  $side = "${Zip}.sha256"
  if(-not (Test-Path -LiteralPath $side)){ throw "missing detached hash: $side" }
  $zipExpected = (Get-Content -LiteralPath $side -Raw).Trim().Split()[0]
  LogInfo ("gate1: verifying " + $Zip + " against " + $side)
  Assert-YcHash -Path $Zip -Expected $zipExpected -What 'gate1 (zip)'
  LogInfo 'gate1: OK'

  $stage = Join-Path $env:TEMP ("ycpayload-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $stage)

  # gate 2 - authenticate MANIFEST.json BEFORE trusting any hash inside it
  $manPath = Join-Path $stage 'MANIFEST.json'
  $manSide = Join-Path $stage 'MANIFEST.sha256'
  if(-not (Test-Path -LiteralPath $manPath)){ throw 'gate2: MANIFEST.json missing from artifact' }
  if(-not (Test-Path -LiteralPath $manSide)){ throw 'gate2: MANIFEST.sha256 missing from artifact' }
  $manExpected = (Get-Content -LiteralPath $manSide -Raw).Trim().Split()[0]
  LogInfo 'gate2: verifying MANIFEST.json against MANIFEST.sha256'
  Assert-YcHash -Path $manPath -Expected $manExpected -What 'gate2 (manifest)'
  LogInfo 'gate2: OK'

  $man = Get-Content -LiteralPath $manPath -Raw | ConvertFrom-Json

  # gate 3 - every member, as extracted, against the now-trusted manifest
  LogInfo ("gate3: verifying " + $man.members.Count + " extracted members")
  foreach($m in $man.members){
    $p = Join-Path $stage $m.target
    if(-not (Test-Path -LiteralPath $p)){ throw ("gate3: member missing from artifact: " + $m.target) }
    Assert-YcHash -Path $p -Expected $m.sha256 -What ('gate3 (' + $m.name + ')')
  }
  LogInfo 'gate3: OK'

  # lay it out - install_to is authoritative, never derived from target/name
  #
  # A destination can be LOCKED. virtio-win.iso is the known case: GoldenImage step 21
  # mounts it, and on 2026-08-11 the dismount still lived in the seal phase, so this
  # copy threw "used by another process" AFTER gates 1-3 had all passed - and the whole
  # install exited 1, leaving the image with the 2 KB stub catalog. One locked file
  # must not cost the entire payload. Try to release a mounted image, retry, and if it
  # is still locked, record it and keep going - gate 4 below is what decides pass/fail,
  # and it re-hashes every installed member, so nothing is waved through silently.
  New-Item -ItemType Directory -Force -Path $S | Out-Null
  $locked = @()
  foreach($m in $man.members){
    $dst = $m.install_to
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    $src = Join-Path $stage $m.target
    $done = $false
    for($try = 1; $try -le 3 -and -not $done; $try++){
      try { Copy-Item -LiteralPath $src -Destination $dst -Force -EA Stop; $done = $true }
      catch {
        if($try -eq 1 -and $dst -match '\.iso$'){
          LogInfo ("  locked, attempting dismount: " + $dst)
          $dj = Start-Job { param($p) Dismount-DiskImage -ImagePath $p -EA SilentlyContinue } -ArgumentList $dst
          if(-not (Wait-Job $dj -Timeout 60)){ Stop-Job $dj -EA SilentlyContinue }
          Remove-Job $dj -Force -EA SilentlyContinue
        }
        Start-Sleep 3
      }
    }
    if(-not $done){ $locked += $dst; LogInfo ("  STILL LOCKED after 3 tries: " + $dst) }
  }
  if($locked.Count){
    LogInfo ("WARNING: " + $locked.Count + " member(s) could not be written; gate4 will fail them:")
    foreach($x in $locked){ LogInfo ("    " + $x) }
  }
  Copy-Item -LiteralPath $manPath -Destination "$S\MANIFEST.json" -Force
  Copy-Item -LiteralPath $manSide -Destination "$S\MANIFEST.sha256" -Force

  # gate 4 - what actually landed on disk
  LogInfo ("gate4: verifying " + $man.members.Count + " installed members on disk")
  foreach($m in $man.members){
    Assert-YcHash -Path $m.install_to -Expected $m.sha256 -What ('gate4 (' + $m.name + ')')
  }
  LogInfo 'gate4: OK'

  Set-Content -Path "$S\yc-payload-version.txt" -Encoding ascii -Value (
    "payload_version = {0}`r`nmanifest_sha256 = {1}`r`ninstalled_at    = {2}`r`nhost            = {3}`r`n" -f `
    $man.payload_version, (Get-YcFileHash -Path "$S\MANIFEST.json"), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME
  )

  $msg = ("payload {0}: {1} members verified and installed" -f $man.payload_version, $man.members.Count)
  Write-Host $msg
  LogInfo $msg
  $ok = $true
}
catch{
  LogErr $_.Exception.Message
  throw
}
finally{
  if($stage -and (Test-Path -LiteralPath $stage)){ Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
  if($haveLib){ try{ Stop-YcLog $(if($ok){0}else{1}) }catch{} }
}
