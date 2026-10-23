# test-sql-licensing.ps1 - self-check for the SQL Server product, edition and licensing
# classification inside Test-MigrationReadiness.ps1 (the migration-check pre-flight).
#
# Run it on a Windows guest, from the repo root:  powershell -ExecutionPolicy Bypass -File .\test-sql-licensing.ps1
# It needs NO SQL Server: the real code is driven with synthetic SERVERPROPERTY values, so the
# version mapping, the edition classification and the evaluation-expiry arithmetic are tested on
# any machine. It must end with '0 failed'.
# The real code is sliced out of the real script and driven with synthetic SERVERPROPERTY values,
# so the mapping and the wording are tested on a machine that has no SQL Server on it.
$ErrorActionPreference = 'Continue'
$src = Join-Path $PSScriptRoot 'Test-MigrationReadiness.ps1'
$all = [IO.File]::ReadAllText($src)
$a = $all.IndexOf('# WHICH SQL SERVER IS THIS')
$b = $all.IndexOf('# --- WHO CAN ADMINISTER', $a)
if ($a -lt 0 -or $b -lt 0) { throw 'markers not found' }
$code = $all.Substring($a, $b - $a)

$pass = 0; $fail = 0
function T { param([string]$Name,[bool]$Ok,[string]$Got='')
  if ($Ok) { $script:pass++; Write-Host ('  PASS  ' + $Name + $(if($Got){'  -> '+$Got}else{''})) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ('  FAIL  ' + $Name + $(if($Got){'  -> '+$Got}else{''})) -ForegroundColor Red } }

$script:Blockers = New-Object System.Collections.Generic.List[string]
$script:Risks    = New-Object System.Collections.Generic.List[string]
function Say   { param([string]$Text,[string]$Level='INFO') Write-Host ('      | ' + $Text) -ForegroundColor DarkGray }
function Block { param([string]$T) $script:Blockers.Add($T) | Out-Null }
function Risk  { param([string]$T) $script:Risks.Add($T)    | Out-Null }
function Note  { param([string]$T) }

function Run {
  param([string]$Edition,[string]$Version,[string]$Level,[string]$Cu,[string]$Installed)
  $script:Blockers.Clear(); $script:Risks.Clear()
  $script:si = [ordered]@{ instance='TEST'; reachable=$true; edition=$Edition; version=$Version
                           versionName=''; productLevel=$Level; updateLevel=$Cu; licensing=''
                           authMode='Windows only'; installDate=$Installed; evalExpiry=''
                           evalDaysLeft=$null; databases=@(); totalSizeMB=0 }
  $script:inst = 'TEST'
  $si = $script:si; $inst = $script:inst
  Invoke-Expression $code
  return $si
}

Write-Host ''
Write-Host 'SQL PRODUCT / EDITION / LICENSING CLASSIFICATION' -ForegroundColor Cyan

$r = Run 'Enterprise Edition: Core-based Licensing (64-bit)' '15.0.4365.2' 'RTM' 'CU22' '2021-03-04 11:02:11'
T 'SQL 2019 recognised from major 15'  ($r.versionName -eq 'SQL Server 2019') $r.versionName
T 'paid edition classified'            ($r.licensing -match 'paid edition') $r.licensing
T 'paid edition raises nothing'        (($script:Blockers.Count + $script:Risks.Count) -eq 0) ('b=' + $script:Blockers.Count + ' r=' + $script:Risks.Count)

$r = Run 'Enterprise Evaluation Edition (64-bit)' '16.0.1000.6' 'RTM' '' '2026-08-01 09:00:00'
T 'SQL 2022 recognised from major 16'  ($r.versionName -eq 'SQL Server 2022') $r.versionName
T 'evaluation classified'              ($r.licensing -match 'EVALUATION') $r.licensing
T 'evaluation BLOCKS'                  ($script:Blockers.Count -eq 1) ('blockers=' + $script:Blockers.Count)
T 'evaluation expiry computed'         ($r.evalExpiry -eq '2027-01-28') ([string]$r.evalExpiry)
T 'evaluation days left is a number'   ($null -ne $r.evalDaysLeft) ([string]$r.evalDaysLeft)
T 'blocker names the expiry date'      ($script:Blockers[0] -match '2027-01-28') ''

$r = Run 'Express Edition (64-bit)' '14.0.3465.1' 'RTM' 'CU31' '2019-06-02 08:00:00'
T 'SQL 2017 recognised from major 14'  ($r.versionName -eq 'SQL Server 2017') $r.versionName
T 'express classified with the 10 GB cap named' ($r.licensing -match '10 GB per database') $r.licensing
T 'express alone raises nothing'       (($script:Blockers.Count + $script:Risks.Count) -eq 0) ('b=' + $script:Blockers.Count + ' r=' + $script:Risks.Count)

$r = Run 'Developer Edition (64-bit)' '13.0.6300.2' 'SP3' '' '2018-01-01 08:00:00'
T 'SQL 2016 recognised from major 13'  ($r.versionName -eq 'SQL Server 2016') $r.versionName
T 'developer classified'               ($r.licensing -match 'NOT licensed for production') $r.licensing
T 'developer RISKS, does not block'    (($script:Risks.Count -eq 1) -and ($script:Blockers.Count -eq 0)) ('b=' + $script:Blockers.Count + ' r=' + $script:Risks.Count)

$r = Run 'Standard Edition (64-bit)' '11.0.7001.0' 'SP4' '' '2015-05-05 08:00:00'
T 'SQL 2012 recognised from major 11'  ($r.versionName -eq 'SQL Server 2012') $r.versionName

$r = Run 'Standard Edition (64-bit)' '17.0.100.0' 'RTM' '' '2026-02-02 08:00:00'
T 'SQL 2025 recognised from major 17'  ($r.versionName -eq 'SQL Server 2025') $r.versionName

$r = Run 'Enterprise Evaluation Edition (64-bit)' '16.0.1000.6' 'RTM' ''
T 'evaluation with no install date still blocks' ($script:Blockers.Count -eq 1) ('blockers=' + $script:Blockers.Count)
T 'no expiry claimed when the date is unknown'   (-not $r.evalExpiry) ('"' + [string]$r.evalExpiry + '"')

$r = Run 'Some Future Edition' '99.0.0.0' '' '' ''
T 'unknown major does not throw'       ($r.versionName -match 'unrecognised') $r.versionName
T 'unclassifiable edition says so'     ($r.licensing -match 'could not classify') $r.licensing

Write-Host ''
Write-Host ('RESULT: ' + [string]$pass + ' passed, ' + [string]$fail + ' failed') -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
