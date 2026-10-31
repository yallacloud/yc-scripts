# test-local-wsus.ps1 - proves the local-WSUS rollout logic (payload 2.47.0) without a VM.
#   pwsh -File test-local-wsus.ps1 -PayloadDir <extracted payload>
# Covers: a customer's own update server is never replaced; the guard's revert decision (down
# twice / no updates for 8 days / just booted / just configured); the exit codes and what each
# reports; the day-0 fix in fix-deploy (on by default, opt-out file, never a deployment failure);
# the adopt WSUS phase (on by default, -SkipWsus, foreign = finding, unreachable = not a finding).
# Must end with '0 failed'.
param([string]$PayloadDir = 'C:\Scripts')
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function T([string]$Name, [bool]$Ok, [string]$Got = '') {
  if ($Ok) { $script:pass++; Write-Host ('  ok   ' + $Name) }
  else { $script:fail++; Write-Host ('  FAIL ' + $Name + $(if ($Got) { '   got: ' + $Got } else { '' })) -ForegroundColor Red }
}
function Read-Src([string]$f) { [IO.File]::ReadAllText((Join-Path $PayloadDir $f)) -replace "`r`n", "`n" }
function Lift([string]$Text, [string[]]$Names) {
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
  foreach ($n in $Names) {
    $fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true)
    T ($n + ' exists') ([bool]$fn)
    if ($fn) { . ([scriptblock]::Create($fn.Extent.Text)); Set-Item -Path ('function:global:' + $n) -Value $fn.Body.GetScriptBlock() }
  }
}

$sw  = Read-Src 'Set-LocalWsus.ps1'
$fd  = Read-Src 'Fix-Deploy.ps1'
$ad  = Read-Src 'Adopt-MigratedVm.ps1'
$lib = Read-Src '_yc-lib.ps1'

Write-Host '=== 1. a customer''s own update server is never replaced ===' -ForegroundColor Cyan
Lift $sw @('Test-YcForeignWsus','Get-YcGuardVerdict')
T 'not configured -> not foreign'                    (-not (Test-YcForeignWsus -Current '' -OurHost '93.177.125.166'))
T 'ours -> not foreign'                              (-not (Test-YcForeignWsus -Current 'http://93.177.125.166:8530' -OurHost '93.177.125.166'))
T 'a company WSUS -> foreign'                        (Test-YcForeignWsus -Current 'http://wsus.acme.local:8530' -OurHost '93.177.125.166')
T 'install refuses a foreign server with exit 6 unless -Force' ($sw.Contains('(Test-YcForeignWsus -Current ([string]$cur.WUServer) -OurHost $Server) -and -not $Force') -and $sw.Contains('Exit-Yc 6 '))
T 'the foreign check runs BEFORE anything is written' ($sw.IndexOf('Exit-Yc 6 ') -lt $sw.IndexOf("New-ItemProperty `$WU -Name 'WUServer'"))
T 'unreachable server: exit 7, nothing changed, stays on Microsoft' ($sw -match 'Exit-Yc 7 \(''NOT CHANGED' -and $sw.IndexOf('Exit-Yc 7 ') -lt $sw.IndexOf("New-ItemProperty `$WU -Name 'WUServer'"))

Write-Host '=== 2. the guard decides when to go back to Microsoft ===' -ForegroundColor Cyan
$now = [datetime]::SpecifyKind([datetime]'2026-11-10T06:20:00', 'Utc')
T 'server down -> down'                              ((Get-YcGuardVerdict -Answers $false -LastScanUtc $now -ConfiguredUtc $now.AddDays(-10) -NowUtc $now) -eq 'down')
T 'answers, checked yesterday -> ok'                 ((Get-YcGuardVerdict -Answers $true -LastScanUtc $now.AddDays(-1) -ConfiguredUtc $now.AddDays(-10) -NowUtc $now) -eq 'ok')
T 'answers, no update check for 7 days -> ok (limit is 8)' ((Get-YcGuardVerdict -Answers $true -LastScanUtc $now.AddDays(-7) -ConfiguredUtc $now.AddDays(-20) -NowUtc $now) -eq 'ok')
T 'answers, no update check for 9 days -> stale'     ((Get-YcGuardVerdict -Answers $true -LastScanUtc $now.AddDays(-9) -ConfiguredUtc $now.AddDays(-20) -NowUtc $now) -eq 'stale')
T 'answers, never checked, configured 9 days ago -> stale' ((Get-YcGuardVerdict -Answers $true -LastScanUtc $null -ConfiguredUtc $now.AddDays(-9) -NowUtc $now) -eq 'stale')
T 'configured 7 days ago -> ok (give it 8 days)'    ((Get-YcGuardVerdict -Answers $true -LastScanUtc $null -ConfiguredUtc $now.AddDays(-7) -NowUtc $now) -eq 'ok')
T 'booted 2 hours ago -> ok (switched off is not stale)' ((Get-YcGuardVerdict -Answers $true -LastScanUtc $now.AddDays(-12) -ConfiguredUtc $now.AddDays(-20) -NowUtc $now -UptimeHours 2) -eq 'ok')
T 'down still counts right after a boot'             ((Get-YcGuardVerdict -Answers $false -LastScanUtc $now -ConfiguredUtc $now -NowUtc $now -UptimeHours 1) -eq 'down')
T 'guard tests the server it is ACTUALLY pointed at' ($sw -match '\$u = \[uri\]\$s\.WUServer; \$gHost = \$u\.Host')
T 'stale reverts at once; down needs 2 in a row'     ($sw.Contains('if($v -eq ''stale''){') -and $sw.Contains('$n = $GuardLimit') -and $sw.Contains('$GuardLimit = 2'))
T 'a healthy daily check sends nothing'              ($sw -match '(?s)if\(\$v -eq ''ok''\)\{[^}]*\$script:YcMsSent = \$true')
T 'the revert reuses -Uninstall (one revert path)'   ($sw.Contains('''-File'',$me,''-Uninstall'''))

Write-Host '=== 3. what each result reports ===' -ForegroundColor Cyan
$m = [regex]::Match($lib, "(?s)# ------------------------------------------------------------------------------------\n# WEBHOOK MILESTONES.*")
. ([scriptblock]::Create($m.Value))
T 'set-local-wsus reports as area wsus'              ((Get-YcMsArea 'set-local-wsus') -eq 'wsus')
T '0 -> vm.wsus.ok'                                  ((Get-YcMsState -Area 'wsus' -Code 0) -eq 'ok')
T '6 foreign -> waitforhuman'                        ((Get-YcMsState -Area 'wsus' -Code 6) -eq 'waitforhuman')
T '7 unreachable -> waiting'                         ((Get-YcMsState -Area 'wsus' -Code 7) -eq 'waiting')
T '1 guard reverted / not answering -> failed'       ((Get-YcMsState -Area 'wsus' -Code 1) -eq 'failed')
T '-Status and -Test are read-only, not reported'    ((Test-YcMsReadOnly @('Status')) -and (Test-YcMsReadOnly @('Test')))

Write-Host '=== 4. day-0: fix-deploy ===' -ForegroundColor Cyan
T 'wsus is in the default fix list (on by default)'  ($fd -match "\`$AllFixes = @\('lockout','gateway','tls','console','cbinit','sqlrename','salt','wsus'\)")
T 'opt-out file skips it'                            ($fd -match "\`$optOut = 'C:\\ProgramData\\YallaCloud\\wsus\\no-local'" -and $fd -match 'elseif\(Test-Path -LiteralPath \$optOut\)')
T 'runs set-local-wsus -Install'                     ($fd -match '-File \$sw -Install')
$wa = $fd.IndexOf('if($run -contains ''wsus'')'); $wz = $fd.IndexOf('Step-YcFix ''''', $wa)
T 'never a deployment failure (no Failed++ in the wsus fix)' ($wa -gt 0 -and $wz -gt $wa -and $fd.Substring($wa, $wz - $wa) -notmatch '\$script:Failed\+\+')
T '-Report only reports'                             ($fd -match '-File \$sw -Status')

Write-Host '=== 5. day-2: the adopt WSUS phase ===' -ForegroundColor Cyan
T 'WSUS phase between GLPI and NOTIFY'               ($ad -match "'ACRONIS','GLPI','WSUS','NOTIFY','VERIFY'")
T 'dispatched'                                       ($ad -match "'WSUS'      \{ \`$rc = Invoke-Wsus \}")
T '-SkipWsus exists'                                 ($ad -match '\[switch\]\$SkipWsus')
T 'runs set-local-wsus -Install, 0/6/7 are expected' ($ad -match "Invoke-YcCommand -Script 'Set-LocalWsus.ps1' -Arguments @\('-Install'\) -Phase 'WSUS' -OkCodes @\(0,6,7\)")
T 'foreign is a finding'                             ($ad -match "6 \{ \`$st\.action = 'foreign'[^}]*Flag 'WSUS'")
T 'unreachable is not a finding'                     ($ad -match "7 \{ \`$st\.action = 'unreachable'[^}]*return 0 \}")
T 'the guard task is one of ours (VERIFY does not flag it)' ($ad -match "\`$script:OurTaskNames = @\('YC-AdoptResume','YC-WsusGuard',")
Lift $ad @('Get-AdoptPhaseHook')
T 'adopt WSUS ran -> nothing (set-local-wsus reports itself)' ($null -eq (Get-AdoptPhaseHook -Phase 'WSUS' -Rc 0 -Action 'local'))
$h = Get-AdoptPhaseHook -Phase 'WSUS' -Rc 3 -Action 'no-command'
T 'adopt WSUS command missing -> vm.wsus.failed'     ($h.area -eq 'wsus' -and $h.state -eq 'failed')

Write-Host ''
Write-Host ('RESULT: ' + $script:pass + ' passed, ' + $script:fail + ' failed') -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
