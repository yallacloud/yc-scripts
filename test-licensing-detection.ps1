# test-licensing-detection.ps1 - self-check for the Windows and Office licensing detection
# inside Test-MigrationReadiness.ps1 (the migration-check pre-flight).
#
# Run it on a Windows guest, from the repo root:  powershell -ExecutionPolicy Bypass -File .\test-licensing-detection.ps1
# It must end with '0 failed'. It changes nothing: every check it exercises is read-only.
# It slices the REAL code out of the real script and runs it against this machine's registry
# and WMI, so what is tested is what ships - not a copy that can drift.
$ErrorActionPreference = 'Continue'
$src = Join-Path $PSScriptRoot 'Test-MigrationReadiness.ps1'
$all = [IO.File]::ReadAllText($src)
$pass = 0; $fail = 0
function T { param([string]$Name,[bool]$Ok,[string]$Got='')
  if ($Ok) { $script:pass++; Write-Host ('  PASS  ' + $Name + $(if($Got){'  -> '+$Got}else{''})) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ('  FAIL  ' + $Name + $(if($Got){'  -> '+$Got}else{''})) -ForegroundColor Red } }

# --- stubs that stand in for the script's own reporting helpers -------------------------------
$script:Lines = New-Object System.Collections.Generic.List[string]
$script:Blockers = New-Object System.Collections.Generic.List[string]
$script:Risks    = New-Object System.Collections.Generic.List[string]
$script:Notes    = New-Object System.Collections.Generic.List[string]
function Say   { param([string]$Text,[string]$Level='INFO') $script:Lines.Add('['+$Level+'] '+$Text) | Out-Null; Write-Host ('      | ' + $Text) -ForegroundColor DarkGray }
function Block { param([string]$T) $script:Blockers.Add($T) | Out-Null }
function Risk  { param([string]$T) $script:Risks.Add($T)    | Out-Null }
function Note  { param([string]$T) $script:Notes.Add($T)    | Out-Null }
$script:Report = [ordered]@{}

function Slice {
  param([string]$From,[string]$To)
  $a = $all.IndexOf($From); if ($a -lt 0) { throw ('start marker not found: ' + $From) }
  $b = $all.IndexOf($To,$a); if ($b -lt 0) { throw ('end marker not found: ' + $To) }
  return $all.Substring($a, $b - $a)
}

Write-Host ''
Write-Host 'WINDOWS LICENSING BLOCK' -ForegroundColor Cyan
$m = [ordered]@{}
try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $m.os = [string]$os.Caption } catch { $m.os = '' }
$code = Slice '# WINDOWS LICENSING.' '$script:Report.machine = $m'
$err = $null
try { Invoke-Expression $code } catch { $err = $_.Exception.Message }
T 'windows block runs without throwing' ($null -eq $err) $err
T 'editionId was read'      ([bool]$m.windowsEditionId) ([string]$m.windowsEditionId)
T 'sku resolved'            ($m.windowsSku -ne 'UNKNOWN') ([string]$m.windowsSku)
T 'licence state resolved'  ($m.windowsLicense -ne 'unreadable') ([string]$m.windowsLicense)
T 'channel read'            ([bool]$m.windowsChannel) ([string]$m.windowsChannel)
T 'partial key is 5 chars or empty' (($m.windowsKeyLast5.Length -eq 5) -or ($m.windowsKeyLast5.Length -eq 0)) ([string]$m.windowsKeyLast5)
T 'no full key was captured' ($m.windowsKeyLast5.Length -le 5) ('len=' + [string]$m.windowsKeyLast5.Length)
T 'evaluation flag is boolean' ($m.windowsEvaluation -is [bool]) ([string]$m.windowsEvaluation)

Write-Host ''
Write-Host 'OFFICE / EXCEL BLOCK' -ForegroundColor Cyan
$code2 = Slice '# --- OFFICE / EXCEL:' '$script:Report.office = $office'
$err2 = $null
$t0 = Get-Date
try { Invoke-Expression $code2 } catch { $err2 = $_.Exception.Message }
$secs = [math]::Round(((Get-Date)-$t0).TotalSeconds,1)
T 'office block runs without throwing' ($null -eq $err2) $err2
T 'office block finishes under 60s' ($secs -lt 60) ([string]$secs + 's')
T 'installed flag is boolean' ($office.installed -is [bool]) ([string]$office.installed)
if ($office.installed) {
  T 'install type identified' ([bool]$office.installType) ([string]$office.installType)
  T 'at least one app or product found' ((@($office.apps).Count + @($office.products).Count) -gt 0) ('apps=' + [string]@($office.apps).Count + ' products=' + [string]@($office.products).Count)
  foreach ($l in @($office.licences)) {
    T ('licence key ending is 5 chars or empty: ' + $l.name) (([string]$l.keyLast5).Length -in @(0,5)) ([string]$l.keyLast5)
  }
  T 'verdict set' ($office.verdict -eq 'INSTALLED') ([string]$office.verdict)
} else {
  T 'verdict set when absent' ($office.verdict -eq 'NOT INSTALLED') ([string]$office.verdict)
}

Write-Host ''
Write-Host ('blockers raised: ' + [string]$script:Blockers.Count) -ForegroundColor Yellow
foreach ($b in $script:Blockers) { Write-Host ('   BLOCK ' + $b.Substring(0,[math]::Min(140,$b.Length))) -ForegroundColor Red }
Write-Host ('risks raised   : ' + [string]$script:Risks.Count) -ForegroundColor Yellow
foreach ($r in $script:Risks) { Write-Host ('   RISK  ' + $r.Substring(0,[math]::Min(140,$r.Length))) -ForegroundColor Yellow }
foreach ($n in $script:Notes) { Write-Host ('   note  ' + $n) -ForegroundColor DarkGray }
Write-Host ''
Write-Host ('RESULT: ' + [string]$pass + ' passed, ' + [string]$fail + ' failed') -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
