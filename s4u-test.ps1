<#
================================================================================================
  YALLACLOUD - S4U REGISTRATION TEST

  THE QUESTION THIS ANSWERS
    A migrated VM almost always needs a reboot during adopt, so the run continues through a
    scheduled task. That task needs a principal, and on a workgroup machine both obvious
    choices are broken:

      SYSTEM          fires reliably at startup, but a SYSTEM process was observed to get
                      "Access is denied" registering an S4U task for chadmin - so the resumed
                      half registers NO SQL and NO disk task.
      chadmin / S4U   can register those tasks, but an S4U task with an AtStartup trigger does
                      NOT fire until that account logs on - so the resume never happens
                      unattended.

    Both were observed on TS_BM_FD_DB01, 2026-10-22. This script measures the first one
    properly instead of reasoning about it: it runs ITSELF as SYSTEM and tries to register a
    chadmin task two different ways.

  WHAT IT CHANGES
    Nothing that survives. It creates up to three scheduled tasks with throwaway names and
    unregisters every one of them before it exits, and it writes one report file.

  RUN IT (elevated):
    [Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm https://raw.githubusercontent.com/yallacloud/yc-scripts/main/s4u-test.ps1)
================================================================================================
#>
$ErrorActionPreference = 'Continue'
$Dir   = 'C:\Scripts'
$Body  = Join-Path $env:TEMP 'yc-s4u-body.ps1'
$Out   = Join-Path $env:TEMP 'yc-s4u-result.txt'
$Task  = 'YC-S4U-Experiment'
$User  = $env:COMPUTERNAME + '\chadmin'

function Say { param([string]$m,[string]$c='Gray') Write-Host ('  ' + $m) -ForegroundColor $c }

Write-Host ''
Write-Host '  YALLACLOUD - S4U REGISTRATION TEST' -ForegroundColor Green
Write-Host ''

$admin = $false
try { $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
if (-not $admin) { Say 'Run this from an ELEVATED PowerShell.' 'Red'; exit 5 }

# ---- the body that will run AS SYSTEM ----------------------------------------------------------
# Written to a file rather than passed as a -Command string: a multi-line script in an argument
# is at the mercy of two layers of quoting, and that is how the first attempt at this silently
# ran nothing at all.
$body = @'
$ErrorActionPreference = 'Continue'
$o = New-Object System.Collections.Generic.List[string]
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$null = $o.Add('running as        : ' + $me.Name + '   isSystem=' + $me.IsSystem)
$u = $env:COMPUTERNAME + '\chadmin'
$null = $o.Add('target principal  : ' + $u)
$null = $o.Add('')

$act = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
$trg = New-ScheduledTaskTrigger -AtStartup

# --- method 1: the ScheduledTasks module, LogonType S4U (what the payload uses today) ---
try {
  $pri = New-ScheduledTaskPrincipal -UserId $u -LogonType S4U -RunLevel Highest
  Register-ScheduledTask -TaskName 'YC-S4UT-1' -Action $act -Trigger $trg -Principal $pri -Force -ErrorAction Stop | Out-Null
  $null = $o.Add('1 module  S4U     : REGISTERED')
} catch { $null = $o.Add('1 module  S4U     : FAILED - ' + $_.Exception.Message) }

# --- method 2: schtasks.exe /RU <user> /NP (a different API path to the same idea) ---
$r = & schtasks.exe /create /tn 'YC-S4UT-2' /tr 'cmd.exe /c exit 0' /sc onstart /ru $u /np /rl HIGHEST /f 2>&1
$null = $o.Add('2 schtasks /np    : exit ' + [string]$LASTEXITCODE + '   ' + ((@($r) | Where-Object { $_ }) -join ' | '))

# --- method 3: a GROUP principal, no per-user S4U at all ---
try {
  $pri3 = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Administrators' -RunLevel Highest
  Register-ScheduledTask -TaskName 'YC-S4UT-3' -Action $act -Trigger $trg -Principal $pri3 -Force -ErrorAction Stop | Out-Null
  $null = $o.Add('3 group Admins    : REGISTERED')
} catch { $null = $o.Add('3 group Admins    : FAILED - ' + $_.Exception.Message) }

$null = $o.Add('')
$null = $o.Add('read back, then removed:')
foreach ($t in @('YC-S4UT-1','YC-S4UT-2','YC-S4UT-3')) {
  $st = $null
  try { $st = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue } catch {}
  if ($st) {
    $who = ''
    try { $who = [string]$st.Principal.UserId + ' / ' + [string]$st.Principal.LogonType + ' / ' + [string]$st.Principal.RunLevel } catch {}
    $null = $o.Add(('  {0,-10} PRESENT  {1}' -f $t, $who))
    try { Unregister-ScheduledTask -TaskName $t -Confirm:$false } catch {}
  } else { $null = $o.Add(('  {0,-10} ABSENT' -f $t)) }
}
($o -join "`r`n") | Set-Content -LiteralPath (Join-Path $env:TEMP 'yc-s4u-result.txt') -Encoding ascii
'@
Set-Content -LiteralPath $Body -Value $body -Encoding ascii
Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue
Say ('probe body written: ' + $Body)

# ---- run it as SYSTEM --------------------------------------------------------------------------
try {
  $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $Body + '"')
  $p = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $t = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)
  Register-ScheduledTask -TaskName $Task -Action $a -Trigger $t -Principal $p -Force -ErrorAction Stop | Out-Null
  Start-ScheduledTask -TaskName $Task
  Say 'running the probe as SYSTEM...'
} catch { Say ('could not start the SYSTEM probe: ' + $_.Exception.Message) 'Red'; exit 6 }

$waited = 0
while ((-not (Test-Path -LiteralPath $Out)) -and $waited -lt 60) { Start-Sleep -Seconds 2; $waited += 2 }
try { Unregister-ScheduledTask -TaskName $Task -Confirm:$false } catch {}
Remove-Item -LiteralPath $Body -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '================================================================================' -ForegroundColor Cyan
Write-Host '  RESULT - can a SYSTEM process register a chadmin task?' -ForegroundColor Cyan
Write-Host '================================================================================' -ForegroundColor Cyan
if (Test-Path -LiteralPath $Out) {
  Get-Content -LiteralPath $Out | ForEach-Object { Write-Host ('  ' + $_) }
  if (Test-Path -LiteralPath $Dir) {
    Copy-Item -LiteralPath $Out -Destination (Join-Path $Dir 's4u-test-result.txt') -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Say ('also saved to ' + (Join-Path $Dir 's4u-test-result.txt')) 'Green'
  }
} else {
  Say ('the SYSTEM probe produced no output after ' + $waited + 's. It did not run.') 'Red'
}
Write-Host ''
Say 'Every task this created has been unregistered. Nothing is left behind.' 'Green'
Write-Host ''
