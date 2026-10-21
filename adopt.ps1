# ================================================================================================
# YALLACLOUD - adopt a MIGRATED VM. The one-liner entry point.
#
# An L1 logging into a freshly migrated VM has NOTHING: no C:\Scripts, no yallacloud command, no
# migrated-vm command. So the first step cannot be a command - it has to be a line they paste.
# This is that line. Run it in an ELEVATED PowerShell on the migrated guest:
#
#   [Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm https://raw.githubusercontent.com/yallacloud/yc-scripts/main/adopt.ps1)
#
# That is the whole deployment. It fetches the payload, verifies it, and adopts the machine.
#
# Anything after the URL is passed through to migrated-vm, so the variations still work:
#   $env:YC_ADOPT_ARGS='-Skip SQLBACKUP'; iex (irm .../adopt.ps1)
#   $env:YC_ADOPT_ARGS='-Report'           look only, change nothing
#
# WHY THIS FILE IS AT THE REPO ROOT AND NOT IN THE PAYLOAD
#   It is the thing you run BEFORE you have the payload. Keeping it beside the zip means one
#   public URL, no credential, and nothing to install first - the same design as the zip itself.
#
# WHAT IT DOES, IN ORDER
#   1. TLS 1.2 (Server 2016 defaults to 1.0, so every HTTPS call fails while the network is fine)
#   2. refuses politely if not elevated, and prints the exact line to re-run
#   3. downloads the payload zip + its .sha256 sidecar
#   4. VERIFIES THE HASH before extracting anything
#   5. extracts the two files needed to continue: Adopt-MigratedVm.ps1 and Update-YcScripts.ps1
#   6. hands over to  migrated-vm -Run , which does the other nine phases and pulls the full payload
#
# It is deliberately small. Everything it could do twice, it leaves to the script it hands over to.
# ================================================================================================
$ErrorActionPreference = 'Stop'
$Url    = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip'
$ShaUrl = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256'
$Dir    = 'C:\Scripts'
$Line   = "[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm https://raw.githubusercontent.com/yallacloud/yc-scripts/main/adopt.ps1)"

function Say($m,$c='Gray'){ Write-Host ('  ' + $m) -ForegroundColor $c }

Write-Host ''
Write-Host '  YALLACLOUD  -  adopting this migrated VM' -ForegroundColor Green
Write-Host ''

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
# MEASURED: Invoke-WebRequest spends most of its time drawing a progress bar nobody sees -
# 0.9s with it, 0.1s without, for the same 844 KB.
$ProgressPreference = 'SilentlyContinue'

$admin = $false
try { $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
if (-not $admin) {
  # Not a relaunch: this script arrived through a pipe, so it has no path on disk to re-run, and a
  # UAC relaunch of a pasted string is worse than telling somebody plainly what to do.
  Say 'This has to run as Administrator.' 'Red'
  Say ''
  Say 'Close this window. Right-click PowerShell -> Run as administrator, then paste:' 'Yellow'
  Say ''
  Say $Line 'White'
  Say ''
  exit 5
}

if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

$tmp = Join-Path $env:TEMP ('yc-adopt-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'payload.zip'
try {
  Say 'downloading the payload...'
  Invoke-WebRequest -Uri $Url    -OutFile $zip -UseBasicParsing
  $sidecar = (Invoke-WebRequest -Uri $ShaUrl -UseBasicParsing).Content
} catch {
  Say ('download failed: ' + $_.Exception.Message) 'Red'
  Say 'This guest needs HTTPS to raw.githubusercontent.com:443. Nothing was changed.' 'Yellow'
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  exit 6
}

$want = ([string]$sidecar -split '\s+')[0].Trim().ToUpper()
$got  = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpper()
if (-not $want -or $want -ne $got) {
  Say 'SHA256 MISMATCH - the payload does not match its sidecar. NOTHING was extracted.' 'Red'
  Say ('  expected ' + $want) 'Red'
  Say ('  got      ' + $got)  'Red'
  Say 'If a payload was pushed in the last 5 minutes this is the CDN cache. Wait, then run it again.' 'Yellow'
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  exit 4
}
Say ('payload verified  sha256=' + $got.Substring(0,16) + '...') 'Green'

# Two files, not the whole zip: Update-YcScripts.ps1 is the only thing allowed to write C:\Scripts
# wholesale, and it runs from inside the handover below.
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $z = [IO.Compression.ZipFile]::OpenRead($zip)
  try {
    foreach ($name in @('Adopt-MigratedVm.ps1','Update-YcScripts.ps1')) {
      $e = $z.Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
      if (-not $e) { Say ($name + ' is not inside the payload zip.') 'Red'; exit 4 }
      [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $Dir $name), $true)
    }
  } finally { $z.Dispose() }
} catch {
  Say ('extract failed: ' + $_.Exception.Message) 'Red'
  exit 4
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# Hand over. Everything else - survey, prerequisites, the full payload sync, PATH, SQL, backups,
# tasks, the marker and the verify - belongs to migrated-vm, which already knows how to do it.
$passthru = @('-Run')
if ($env:YC_ADOPT_ARGS) { $passthru = @($env:YC_ADOPT_ARGS -split '\s+' | Where-Object { $_ }) }
Say ('handing over to:  migrated-vm ' + ($passthru -join ' '))
Write-Host ''
# NOT  & $script @passthru  - splatting an array binds POSITIONALLY, so '-Report' landed in the
# first positional parameter instead of being read as a switch. -File gets normal command-line
# parsing, and it is how Adopt-MigratedVm.ps1 invokes the other payload commands too.
$argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Dir 'Adopt-MigratedVm.ps1')) + $passthru
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru -NoNewWindow
$code = $proc.ExitCode
Write-Host ''
$changedThings = ($passthru -notcontains '-Report' -and $passthru -notcontains '-Status')
switch ($code) {
  0 { if ($changedThings) {
        Say 'DONE. This VM is now managed by the YallaCloud scripts. Type  yallacloud  for the catalog.' 'Green'
      } else {
        Say 'REPORT ONLY - nothing on this machine was changed. The survey path is above.' 'Green'
        Say 'To adopt it, run the same line without YC_ADOPT_ARGS set.' 'Gray'
      } }
  1 { Say 'A REBOOT IS PENDING. Restart this machine - the run continues by itself.' 'Yellow' }
  3 { Say 'DONE, but some items were flagged for a human. They are listed above and in the log.' 'Yellow' }
  default { Say ('migrated-vm exited ' + $code + '. See C:\Scripts\adopt-migrated-vm.log') 'Yellow' }
}
Write-Host ''
exit $code
