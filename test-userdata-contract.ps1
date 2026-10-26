# ================================================================================================
# The contract between the YC-BUILDER userdata and the payload, asserted.
#
# WHY
#   The userdata (v2.18.10) is pasted into CloudStack and is frozen on every sealed template. It
#   calls payload scripts BY NAME with EXACT parameters, and it cannot be fixed after the fact -
#   a VM that is already sealed will keep calling whatever it was built to call. So a payload edit
#   that renames a parameter or drops a .cmd does not fail here, it fails on somebody's VM at
#   first boot, silently, with the build half done.
#
#   Everything below is from the "DO NOT BREAK" list in the 2026-10-26 handoff. It is cheap to
#   assert and expensive to discover.
#
#   Run:  pwsh -File test-userdata-contract.ps1 [-PayloadDir <extracted payload>]
# ================================================================================================
param([string]$PayloadDir)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $PayloadDir) {
  foreach ($c in @('/tmp/gchk', (Join-Path $here 'payload'), $here)) {
    if (Test-Path (Join-Path $c 'Yc-VmBuild.ps1')) { $PayloadDir = $c; break }
  }
}
if (-not $PayloadDir -or -not (Test-Path (Join-Path $PayloadDir 'Yc-VmBuild.ps1'))) {
  throw 'pass -PayloadDir <folder holding the extracted payload>'
}
$pass = 0; $fail = 0
function Ok { param([string]$what,[bool]$cond,[string]$detail='')
  if ($cond) { $script:pass++; Write-Host ('  PASS  ' + $what) -ForegroundColor Green }
  else       { $script:fail++; Write-Host ('  FAIL  ' + $what + ' ' + $detail) -ForegroundColor Red } }

function Get-ScriptParams {
  # The declared parameter NAMES, read with the parser. A regex over the param block got this
  # wrong on a default value that itself contained a comma.
  param([string]$Path)
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) { throw ($Path + ' does not parse: ' + $errs[0].Message) }
  if (-not $ast.ParamBlock) { return @() }
  return @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

Write-Host ''
Write-Host 'USERDATA <-> PAYLOAD CONTRACT (YC-BUILDER v2.18.10)' -ForegroundColor Cyan
Write-Host ''

# --- the files the bootstrap refuses to continue without -------------------------------------
# Yc-Bootstrap.ps1 checks exactly this list and writes SYNC- and exits 1 if any is missing.
foreach ($f in @('install-dotnet.cmd','install-sql.cmd','install-ssms.cmd','Yc-VmBuild.ps1','yc-event.cmd')) {
  Ok ($f + ' is in the payload') (Test-Path (Join-Path $PayloadDir $f))
}
foreach ($f in @('Yc-Event.ps1','Set-LocalWsus.ps1','Yallacloud.ps1')) {
  Ok ($f + ' is in the payload') (Test-Path (Join-Path $PayloadDir $f))
}

# --- Yc-Event.ps1: the parameters yc-notify.ps1 splats ----------------------------------------
# The userdata builds a hashtable and splats it. A renamed parameter is a terminating error
# inside the notifier, so the VM goes silent rather than reporting a failure.
$ep = Get-ScriptParams (Join-Path $PayloadDir 'Yc-Event.ps1')
foreach ($p in @('Type','Step','Extra','NtfyTitle','NtfyPriority','NtfyTags','NtfyLine','Field',
                 'SetUrl','SetSecret','SetToken','SetNtfy','SetNtfyEnabled','SqlKeyLast5',
                 'FailedStep','ErrorText','SelfCheck')) {
  Ok ('Yc-Event.ps1 still takes -' + $p) ($ep -contains $p)
}
# NtfyPriority is passed as the STRING '2'..'5' by the userdata, through a ValidateSet.
$evText = [IO.File]::ReadAllText((Join-Path $PayloadDir 'Yc-Event.ps1'))
Ok 'Yc-Event.ps1 accepts NtfyPriority 1-5 as strings' `
   ($evText -match "ValidateSet\('','1','2','3','4','5'\)\]\[string\]\`$NtfyPriority")
Ok 'Yc-Event.ps1 accepts -SetNtfyEnabled on|off' ($evText -match "ValidateSet\('','on','off'\)")
Ok 'NtfyLine and Field are arrays' (($evText -match '\[string\[\]\]\$NtfyLine') -and ($evText -match '\[string\[\]\]\$Field'))

# --- yc-event.cmd: the userdata calls the WRAPPER for the -Set options ------------------------
$cmdText = [IO.File]::ReadAllText((Join-Path $PayloadDir 'yc-event.cmd'))
Ok 'yc-event.cmd forwards every argument to Yc-Event.ps1' `
   (($cmdText -match 'Yc-Event\.ps1') -and ($cmdText -match '%\*'))

# --- Set-LocalWsus.ps1: called with -Install -Server -Port, exit codes are read ---------------
$wp = Get-ScriptParams (Join-Path $PayloadDir 'Set-LocalWsus.ps1')
foreach ($p in @('Install','Server','Port','Uninstall','Status','Test')) {
  Ok ('Set-LocalWsus.ps1 still takes -' + $p) ($wp -contains $p)
}
# The userdata maps exit 0/2/3/5 to words for the operator. If the script stops returning one of
# them the operator is told "unknown exit", which is the one thing that message cannot explain.
$wsText = [IO.File]::ReadAllText((Join-Path $PayloadDir 'Set-LocalWsus.ps1'))
foreach ($rc in @('0','2','3','5')) {
  Ok ('Set-LocalWsus.ps1 can still exit ' + $rc) ($wsText -match ('(?m)Exit-Yc\s+' + $rc + '\b|exit\s+' + $rc + '\b'))
}

# --- the names baked into every sealed template ------------------------------------------------
$vbText = [IO.File]::ReadAllText((Join-Path $PayloadDir 'Yc-VmBuild.ps1'))
Ok 'Yc-VmBuild.ps1 still works out of the sqltemplate folder' `
   ($vbText -match 'ProgramData\\YallaCloud\\sqltemplate')
Ok 'Yc-VmBuild.ps1 still reads yc-build.json' ($vbText -match 'yc-build\.json')
# Keys the userdata writes. Yc-VmBuild may ignore some, but it must not CRASH on them, and the
# ones it acts on must still be read by these exact names.
foreach ($k in @('Profile','SqlVersion','SqlEdition','InstanceName','InstallSql','LicenseSql',
                 'InstallSsms','LicenseWindows','ConfigureSqlBackup','WinKey','SqlKey')) {
  Ok ('yc-build.json key ' + $k + ' is still read') ($vbText -match ('Cfg\.' + $k + '\b'))
}

# --- the two fixes of 2026-10-26 ---------------------------------------------------------------
# FIX 2: LIC must not be recorded as done on a machine that is not licensed.
Ok 'the LIC step decides its marker from slmgr /xpr' `
   (($vbText -match 'Test-YcWinPermanent') -and ($vbText -match "Set-State 'UPDPOST'") -and ($vbText -match 'WinLicOk'))
Ok 'Get-WinLic reads /xpr, not only /dlv'  ($vbText -match '/xpr')
Ok 'the activation reason code is captured' ($vbText -match 'Notification Reason')
# FIX 3: the final build event carries the rich format.
Ok 'the completed event sets a title, priority and tags' `
   (($vbText -match 'NtfyTitle') -and ($vbText -match 'NtfyPriority') -and ($vbText -match 'NtfyTags'))
Ok 'the completed event sends aligned lines'  ($vbText -match 'NtfyLine     = \$lines')
Ok 'the completed event sends area/status/summary fields' `
   (($vbText -match "'area=deploy'") -and ($vbText -match "'status=completed'") -and ($vbText -match "summary="))
Ok 'the failed event is priority 5'           ($vbText -match "NtfyPriority = '5'")
Ok 'the failed event sends status=failed'     ($vbText -match "'status=failed'")
Ok 'the completed event still carries SqlKeyLast5' ($vbText -match "SqlKeyLast5'\] = ")
Ok 'the -Extra single-line summary is still built' ($vbText -match "profile=' \+ ")

# --- and the scripts' own assertions, which run natively here ----------------------------------
$ps = $(if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' })
$vbOut = (& $ps -NoProfile -File (Join-Path $PayloadDir 'Yc-VmBuild.ps1') -SelfCheck 2>&1 | Out-String)
$m = [regex]::Match($vbOut, 'SelfCheck:\s+(\d+) passed,\s+(\d+) failed')
Ok 'Yc-VmBuild.ps1 -SelfCheck produced a tally' $m.Success
if ($m.Success) {
  Ok ('Yc-VmBuild.ps1 -SelfCheck: ' + $m.Groups[1].Value + ' passed, ' + $m.Groups[2].Value + ' failed') `
     ([int]$m.Groups[2].Value -eq 0)
}

Write-Host ''
Write-Host ('  ' + $pass + ' passed, ' + $fail + ' failed') -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
Write-Host ''
if ($fail) { throw ($fail.ToString() + ' contract check(s) failed') }
