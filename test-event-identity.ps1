# ================================================================================================
# Runs Yc-Event.ps1's OWN -SelfCheck assertions on a machine that is not Windows.
#
# WHY
#   Yc-Event.ps1 dot-sources C:\Scripts\_yc-lib.ps1 and resolves C: paths at load time, so
#   "Yc-Event.ps1 -SelfCheck" cannot run here, and the assertions that prove the vmId fix would
#   only ever be exercised on a VM somebody remembered to run it on. That is not a gate.
#
#   So this lifts the pure functions AND THE SELFCHECK BLOCK ITSELF out of the shipping file with
#   the PowerShell parser and runs them with two small shims. Nothing is copied: the assertions
#   executed here are the ones that ship, so this test and that block cannot drift apart - which
#   is the whole point, because a copied assertion that has gone stale proves nothing.
#
#   Run:  pwsh -File test-event-identity.ps1 [-Script <path to Yc-Event.ps1>]
# ================================================================================================
param([string]$Script)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Script) {
  # default: the copy inside the published payload, extracted beside this script
  foreach ($c in @((Join-Path $here 'Yc-Event.ps1'), '/tmp/gchk/Yc-Event.ps1')) {
    if (Test-Path -LiteralPath $c) { $Script = $c; break }
  }
}
if (-not $Script -or -not (Test-Path -LiteralPath $Script)) {
  throw 'pass -Script <path to Yc-Event.ps1> (or extract the payload beside this test)'
}

$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$errs)
if ($errs -and $errs.Count) { throw ($Script + ' does not parse: ' + $errs[0].Message) }

# Every function the -SelfCheck block calls. Missing one is a hard failure, not a skip: a silently
# absent function would make its assertions throw and look like a product bug.
$need = @('ConvertTo-YcText','ConvertTo-YcAscii','Get-YcDubaiTime','Merge-YcFacts',
          'Get-YcAuthHeaders','Select-YcQueueKeep',
          'Resolve-YcIdentity','Get-YcSqlKeyForBody','Get-YcTrialDaysForBody')
$src = @(); $found = @()
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
  if ($need -contains $f.Name) { $src += $f.Extent.Text; $found += $f.Name }
}
$missing = @($need | Where-Object { $found -notcontains $_ })
if ($missing.Count) { throw ('Yc-Event.ps1 no longer defines: ' + ($missing -join ', ')) }

# The -SelfCheck block, verbatim. Identified by its condition rather than by a line number, so
# adding a check above it cannot silently make this test run nothing.
$block = $null
foreach ($i in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
  if ($i.Clauses[0].Item1.Extent.Text.Trim() -eq '$SelfCheck') {
    # Item2 is the statement BLOCK, and its extent includes the outer braces. Left on, the text
    # becomes a scriptblock LITERAL - one object returned, nothing executed, and a test that
    # passes having run nothing. Strip them.
    $block = $i.Clauses[0].Item2.Extent.Text.Trim()
    if ($block.StartsWith('{') -and $block.EndsWith('}')) { $block = $block.Substring(1, $block.Length - 2) }
    break
  }
}
if (-not $block) { throw 'could not find the "if ($SelfCheck)" block in Yc-Event.ps1' }

# Two shims. Exit-Yc would end this process; everything else the block touches is lifted above.
$harness = @'
$script:__exit = -1
$script:__msg  = ''
function Exit-Yc { param([int]$Code, [string]$Message, [string]$Level) $script:__exit = $Code; $script:__msg = $Message }
$script:YcRouterOnlyKeys = @('cloud', 'zone', 'offering', 'publicIp')
'@

# DOT-SOURCED, not called with &. The block opens with "$pass = 0" and its T function increments
# "$script:pass". At the top of the real script those are the same variable; invoked with & they
# are not - the block runs in a child scope, T increments a script-scope copy, and the tally line
# reads the untouched local one and reports "0 passed, 0 failed" while every assertion actually
# ran. That is the same case-of-scope trap that has bitten this repo twice, and it makes a test
# look green having measured nothing.
$lines = @()
$sb = [scriptblock]::Create($harness + "`n" + ($src -join "`n") + "`n" + $block + "`nWrite-Output ('__EXIT=' + `$script:__exit)")
foreach ($l in @(. $sb)) { $lines += [string]$l }

$out  = ($lines -join "`n")
$exit = -1
$m = [regex]::Match($out, '__EXIT=(-?\d+)')
if ($m.Success) { $exit = [int]$m.Groups[1].Value }
$tally = [regex]::Match($out, 'SelfCheck:\s+(\d+) passed,\s+(\d+) failed')

Write-Host ''
Write-Host ('Yc-Event.ps1 -SelfCheck, run against ' + $Script) -ForegroundColor Cyan
Write-Host ''
foreach ($l in $lines) {
  if ($l -match '^FAIL ')        { Write-Host ('  ' + $l) -ForegroundColor Red }
  elseif ($l -match '^ok ')      { Write-Host ('  ' + $l) -ForegroundColor DarkGray }
  elseif ($l -match '^SelfCheck:') { Write-Host ''; Write-Host ('  ' + $l) -ForegroundColor Green }
}
Write-Host ''

if (-not $tally.Success) { throw 'the SelfCheck block produced no tally - it did not run' }
$passed = [int]$tally.Groups[1].Value
$failed = [int]$tally.Groups[2].Value

# A tally alone is not enough: a block whose assertions were all deleted would report 0 passed,
# 0 failed and look green. These are the ones this test exists for, by name.
$mustHave = @('smbios wins the vmId','the mismatch is reported','no foreign offering leaks in',
              'poisoned offering is dropped','no router is not a mismatch',
              'no sql, no key','sql by version, key goes','licensed clears the count')
$absent = @($mustHave | Where-Object { $o = $_; -not (@($lines | Where-Object { $_ -match ('^(ok|FAIL)\s+' + [regex]::Escape($o) + '$') }).Count) })
if ($absent.Count) { throw ('these assertions are no longer in Yc-Event.ps1 -SelfCheck: ' + ($absent -join '; ')) }

if ($failed -gt 0) { throw ($failed.ToString() + ' SelfCheck assertion(s) failed') }
if ($exit -ne 0)   { throw ('SelfCheck called Exit-Yc ' + $exit) }
Write-Host ('  ' + $passed + ' assertions passed, 0 failed, and all ' + $mustHave.Count +
            ' named identity/licensing checks were present') -ForegroundColor Green
Write-Host ''
