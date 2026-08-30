<#
  Fix-DiagTools.ps1  -  install hayabusa + klogg on a machine where the build MISSed them.

  WHY THEY MISSED
    GoldenImage step 38 used:
      https://github.com/Yamato-Security/hayabusa/releases/latest/download/hayabusa-win-x64.zip
      https://github.com/variar/klogg/releases/latest/download/klogg-portable-x64.zip
    /releases/latest/download/<name> only works when the asset filename is CONSTANT
    across releases. Both projects version their asset names
    (hayabusa-3.4.0-win-x64.zip, klogg-24.10.0.1738-x86_64-portable.zip), so both URLs
    404 - four retries each, then MISS. Nothing to do with the network.

  THE FIX
    Ask the GitHub releases API for the latest release, pick the asset by REGEX, and
    download the real URL. Same logic now lives in GoldenImage step 38.

    Fix-DiagTools.ps1              install both
    Fix-DiagTools.ps1 -WhatIf      resolve + print URLs, download nothing
#>
[CmdletBinding()]
param([switch]$WhatIf,[switch]$Help)

$ErrorActionPreference = 'Continue'
$S   = 'C:\Scripts'
$dtf = Join-Path $S 'DiagTools'
$fail = 0
function L($m,$c='Gray'){ Write-Host $m -ForegroundColor $c
  try{ Add-Content (Join-Path $S 'fix-diagtools.log') ('{0}  {1}' -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'),$m) -Encoding ascii }catch{} }

if($Help){ Write-Host 'Fix-DiagTools.ps1 [-WhatIf]  - install hayabusa + klogg via the GitHub API (the build MISSed them).'; exit 0 }
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ L 'Run elevated.' 'Red'; exit 1 }

# -bor, not '=': a bare assignment drops whatever the host already negotiated.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force $dtf | Out-Null

function Resolve-GhAsset([string]$repo,[string]$rx){
  try{
    $r = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing `
         -Headers @{ 'User-Agent'='YallaCloud-GoldenImage' } -TimeoutSec 60
    $a = $r.assets | Where-Object { $_.name -match $rx } | Select-Object -First 1
    if(-not $a){
      L ("  no asset matched /$rx/ in $repo $($r.tag_name). Available:") 'Yellow'
      $r.assets | ForEach-Object { L ("      " + $_.name) }
      return $null
    }
    L ("  $repo $($r.tag_name) -> " + $a.name) 'Green'
    return $a.browser_download_url
  } catch { L ("  $repo API failed: " + $_.Exception.Message) 'Red'; return $null }
}

function Get-Tool([string]$name,[string]$repo,[string]$rx,[int]$minKB){
  L ''
  L "--- $name ---" 'Cyan'
  $dest = Join-Path $dtf $name
  if((Test-Path $dest) -and @(Get-ChildItem $dest -Recurse -File -EA SilentlyContinue).Count){
    L "  already present at $dest - skipping" 'Green'; return $true
  }
  $url = Resolve-GhAsset $repo $rx
  if(-not $url){ $script:fail++; return $false }
  if($WhatIf){ L "  WHATIF would download $url" 'Yellow'; return $true }

  $zip = Join-Path $dtf "$name.zip"
  for($i=1; $i -le 3; $i++){
    try{
      Invoke-WebRequest $url -OutFile $zip -UseBasicParsing -TimeoutSec 900 `
        -Headers @{ 'User-Agent'='YallaCloud-GoldenImage' } -EA Stop
      if((Get-Item $zip).Length -ge ($minKB*1KB)){ break }
      L "  try $i too small ($((Get-Item $zip).Length) B) - retrying" 'Yellow'
    } catch { L ("  try $i failed: " + $_.Exception.Message) 'Yellow'; Start-Sleep 5 }
  }
  if((-not (Test-Path $zip)) -or (Get-Item $zip).Length -lt ($minKB*1KB)){
    L "  DOWNLOAD FAILED" 'Red'; $script:fail++; return $false }

  try{
    Expand-Archive $zip $dest -Force
    Remove-Item $zip -Force -EA SilentlyContinue
    $n = @(Get-ChildItem $dest -Recurse -File).Count
    L "  extracted -> $dest  ($n files)" 'Green'
    return $true
  } catch { L ("  unpack failed: " + $_.Exception.Message) 'Red'; $script:fail++; return $false }
}

L ('==== Fix-DiagTools on ' + $env:COMPUTERNAME + ' ====') 'White'
Get-Tool 'hayabusa' 'Yamato-Security/hayabusa' 'win.*x64.*\.zip$'              2000 | Out-Null
Get-Tool 'klogg'    'variar/klogg'             '(portable|win).*(x86_64|x64).*\.zip$' 2000 | Out-Null

# ---- verify the two PATH wrappers the build already wrote can now find their exe ----
L ''
L '--- verify ---' 'Cyan'
$hb = Get-ChildItem $dtf -Recurse -Filter 'hayabusa*.exe' -EA SilentlyContinue | Select-Object -First 1
$kl = Get-ChildItem $dtf -Recurse -Filter 'klogg*.exe'    -EA SilentlyContinue | Select-Object -First 1
if($hb){ L ("  evtx-hunt -> " + $hb.FullName) 'Green' } else { L '  hayabusa.exe MISSING - evtx-hunt will not work' 'Red'; $fail++ }
if($kl){ L ("  logview   -> " + $kl.FullName) 'Green' } else { L '  klogg.exe MISSING - logview will not work' 'Yellow' }

Write-Host ''
if($WhatIf){ L 'WhatIf - nothing downloaded.' 'Yellow'; exit 0 }
if($fail -eq 0){ L 'DIAGTOOLS OK - evtx-hunt and logview are usable.' 'Green'; exit 0 }
L ("$fail problem(s). hayabusa is the important one (Log Parser replacement); klogg is optional.") 'Yellow'
exit 1
