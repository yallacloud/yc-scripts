# =============================================================================
# Sync-OdooMirror.ps1 - keep the Odoo 20 deploy kit on repo.oasisstack.io/odoo (local fallback for GitHub)
# Runs on ycwsus01 as task YC-OdooMirror (SYSTEM, daily 03:45 + at startup). Lives in D:\repo-sync
# (NOT C:\Scripts - Update-YcScripts wipes C:\Scripts). Guide: STACK4-61.
# YallaCloud / OasisStack - v1.0.0 - 2026-10-26. Windows PowerShell 5.1. ASCII only.
#
# Source of truth = GitHub (public yallacloud/yc-scripts). Served copy (IIS, YC ranges only):
#   <Root>\odoo\yc-odoo20-install.sh   + .sha256     raw main odoo/
#   <Root>\odoo\yc-odoo20-userdata.sh  + .sha256     raw main odoo/
#   <Root>\odoo\odoo_20.0.latest_all.deb + .sha256 + odoo-VERSION.txt   release odoo20-latest
#   <Root>\odoo\wkhtmltox_0.12.6.1-3.jammy_amd64.deb + .sha256          wkhtmltopdf/packaging release
#   <Root>\odoo\VERSION.txt   what is served, sizes, sha256, last check
# Rule: the .sha256 decides. A file is fetched only when its published sha256 changed, into
# D:\repo-sync\tmp (outside the web root), checked against that sha256, then swapped in.
# Log: D:\repo-sync\odoo-mirror.log. Exit code = number of failed files.
# =============================================================================
param([string]$Root = 'D:\repo', [string]$Work = 'D:\repo-sync')
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Log = Join-Path $Work 'odoo-mirror.log'; $Tmp = Join-Path $Work 'tmp'; $Dir = Join-Path $Root 'odoo'
New-Item -ItemType Directory -Force -Path $Tmp, $Dir | Out-Null
function Log([string]$m){ $l = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $m; Add-Content -Path $Log -Value $l -Encoding ascii; Write-Output $l }
function Get-Text([string]$u){ $p = Join-Path $Tmp 'txt.part'; & curl.exe -fsSL --retry 3 -o $p $u; if ($LASTEXITCODE -ne 0) { throw "curl $LASTEXITCODE $u" }; (Get-Content $p -Raw).Trim() }

$raw = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/odoo'
$rel = 'https://github.com/yallacloud/yc-scripts/releases/download/odoo20-latest'
$wk  = 'https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb'
# Sha = URL of a published "<sha256>  <name>" file; $null = no upstream sha (computed here once).
$items = @(
  @{ Name = 'yc-odoo20-install.sh';  Url = "$raw/yc-odoo20-install.sh";  Sha = "$raw/yc-odoo20-install.sh.sha256";  Min = 1KB },
  @{ Name = 'yc-odoo20-userdata.sh'; Url = "$raw/yc-odoo20-userdata.sh"; Sha = "$raw/yc-odoo20-userdata.sh.sha256"; Min = 1KB },
  @{ Name = 'odoo_20.0.latest_all.deb'; Url = "$rel/odoo_20.0.latest_all.deb"; Sha = "$rel/odoo_20.0.latest_all.deb.sha256"; Min = 100MB },
  @{ Name = 'wkhtmltox_0.12.6.1-3.jammy_amd64.deb'; Url = $wk; Sha = $null; Min = 10MB }
)
$fail = 0; $rows = @()
foreach ($it in $items) {
  $dst = Join-Path $Dir $it.Name; $shaFile = "$dst.sha256"
  try {
    $want = if ($it.Sha) { ((Get-Text $it.Sha) -split '\s+')[0].ToLower() } else { $null }
    $have = if (Test-Path $shaFile) { ((Get-Content $shaFile -Raw).Trim() -split '\s+')[0].ToLower() } else { '' }
    if ((Test-Path $dst) -and $have -and ((-not $want) -or $want -eq $have)) {
      Log "OK   $($it.Name) up to date ($have)"
    } else {
      Log "GET  $($it.Name) (want $want, have $(if($have){$have}else{'nothing'}))"
      $part = Join-Path $Tmp ($it.Name + '.part'); Remove-Item $part -Force -ErrorAction SilentlyContinue
      & curl.exe -fsSL --retry 3 --retry-delay 10 -o $part $it.Url
      if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE" }
      $len = (Get-Item $part).Length
      if ($len -lt $it.Min) { throw "download too small ($len bytes) - error page?" }
      $hash = (Get-FileHash $part -Algorithm SHA256).Hash.ToLower()
      if ($want -and $hash -ne $want) { throw "sha256 mismatch: got $hash, published $want" }
      Move-Item -Force $part $dst
      Set-Content -Path $shaFile -Value "$hash  $($it.Name)" -Encoding ascii
      Log "NEW  $($it.Name) size $len sha256 $hash"
    }
  } catch { $fail++; Log "FAIL $($it.Name): $($_.Exception.Message)" }
  if (Test-Path $dst) { $f = Get-Item $dst; $rows += ("{0,-40} {1,12} bytes  {2:yyyy-MM-dd HH:mm}  sha256 {3}" -f $it.Name, $f.Length, $f.LastWriteTime, ((Get-Content $shaFile -Raw).Trim() -split '\s+')[0]) }
}
try { Set-Content -Path (Join-Path $Dir 'odoo-VERSION.txt') -Value (Get-Text "$rel/VERSION.txt") -Encoding ascii } catch { $fail++; Log "FAIL odoo-VERSION.txt: $($_.Exception.Message)" }

$txt = @(
  'Odoo 20 deploy kit - repo.oasisstack.io/odoo/  (local fallback for GitHub yallacloud/yc-scripts)',
  ('Odoo build            : ' + ((Get-Content (Join-Path $Dir 'odoo-VERSION.txt') -ErrorAction SilentlyContinue | Select-Object -First 1))),
  ('Last check            : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' (+04, ycwsus01)'),
  ('Result                : ' + $(if ($fail) { "$fail FAILED - see D:\repo-sync\odoo-mirror.log" } else { 'OK' })),
  '', 'Files served:') + $rows + @('',
  'Cloud-init : paste yc-odoo20-userdata.sh (edit the block at the top) - guide STACK4-61',
  'Manual     : curl -fsSLO https://repo.oasisstack.io/odoo/yc-odoo20-install.sh && bash yc-odoo20-install.sh')
Set-Content -Path (Join-Path $Dir 'VERSION.txt') -Value $txt -Encoding ascii
exit $fail
