# ================================================================================================
# Self-check for the two on-ramps, check.ps1 and adopt.ps1 - the files an L1 pastes into an
# elevated PowerShell on a machine that has nothing on it yet.
#
# WHY THIS EXISTS
#   The on-ramps cannot be tried out the way a payload script can. They run once, on a machine
#   that has no C:\Scripts, in front of somebody who cannot debug them, and the first thing they
#   touch is operator input pasted out of a chat window. So the parts that have no Windows in
#   them - folding typographic dashes back to ASCII, recognising a mistyped switch, refusing a
#   value that is not a number - are pulled out of the real source with the parser and exercised
#   here. Nothing is copied: a drift between this test and the file it tests would defeat it, so
#   the function bodies under test ARE the ones that ship.
#
#   Run:  pwsh -File test-onramp.ps1    (or powershell.exe -File, on Windows)
# ================================================================================================
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pass = 0; $fail = 0

function Ok {
  param([string]$what,[bool]$cond,[string]$detail = '')
  if ($cond) { $script:pass++; Write-Host ('  PASS  ' + $what) -ForegroundColor Green }
  else       { $script:fail++; Write-Host ('  FAIL  ' + $what + ' ' + $detail) -ForegroundColor Red }
}

# Lift the named functions out of a real on-ramp and define them here, so what is tested is what
# ships. ParseFile, not a regex: a function that happens to contain the word 'function' in a
# comment broke the regex version of this.
# Return the source text of the named functions, for the CALLER to dot-source. Defining them in
# here would put them in this helper's own scope, where they vanish the moment it returns - which
# is exactly what the first version of this test did, and it reported "not recognized as a name".
# ParseFile, not a regex: a function whose comment contains the word 'function' broke that version.
function Get-OnRampFunctionSource {
  param([string]$Path,[string[]]$Names)
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) { throw ($Path + ' does not parse: ' + $errs[0].Message) }
  $parts = @(); $found = @()
  foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($Names -contains $f.Name) { $parts += $f.Extent.Text; $found += $f.Name }
  }
  foreach ($n in $Names) { if ($found -notcontains $n) { throw ($n + ' not found in ' + $Path) } }
  return ($parts -join "`n")
}

# Read a literal array assignment ($Allowed = @('-a','-b')) out of the source, so the test uses
# the shipping option list rather than its own idea of it.
function Get-SourceArray {
  param([string]$Path,[string]$VarName)
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
  foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    if ($a.Left.Extent.Text -eq ('$' + $VarName)) {
      return @([scriptblock]::Create($a.Right.Extent.Text).Invoke())
    }
  }
  throw ($VarName + ' not found in ' + $Path)
}

Write-Host ''
Write-Host 'ON-RAMP SELF-CHECK' -ForegroundColor Cyan
Write-Host ''

foreach ($file in @('check.ps1','adopt.ps1')) {
  $p = Join-Path $here $file
  Ok ($file + ' exists') (Test-Path -LiteralPath $p)
  if (-not (Test-Path -LiteralPath $p)) { continue }

  $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)
  Ok ($file + ' parses') (-not ($errs -and $errs.Count)) ($(if ($errs -and $errs.Count) { $errs[0].Message } else { '' }))

  $text = [IO.File]::ReadAllText($p)

  # It runs through iex in the operator's own session. An 'exit' there closes the window and the
  # verdict goes with it - which is exactly the bug that got reported as "why does it exit?".
  $bareExit = @([regex]::Matches($text, '(?m)^\s*exit\b'))
  Ok ($file + ' has no bare exit (it would close the operator''s window)') ($bareExit.Count -eq 0) (('found ' + $bareExit.Count))

  # ASCII only. A byte above 0x7F in a file that gets pasted around comes back as a mojibake
  # character in a console using a different code page.
  $nonAscii = @([regex]::Matches($text, '[^\x00-\x7F]'))
  Ok ($file + ' is pure ASCII') ($nonAscii.Count -eq 0) (('found ' + $nonAscii.Count + ' byte(s) over 0x7F'))

  # irm/iwr are PowerShell 3.0. Server 2008 R2 ships 2.0, where the line dies with "the term
  # 'irm' is not recognized" - which reads like a broken URL, not an old OS.
  Ok ($file + ' never calls irm/iwr/Invoke-WebRequest (PS 3.0+ only)') `
     (-not ($text -match '(?m)^\s*[^#]*\b(irm|iwr|Invoke-WebRequest|Invoke-RestMethod)\b'))

  # Get-FileHash is PowerShell 4.0; Expand-Archive is 5.0. Both are absent on the old boxes a
  # source VM can be.
  Ok ($file + ' never calls Get-FileHash (PS 4.0+ only)') (-not ($text -match '(?m)^\s*[^#]*\bGet-FileHash\b'))
  Ok ($file + ' never calls Expand-Archive (PS 5.0+ only)') (-not ($text -match '(?m)^\s*[^#]*\bExpand-Archive\b'))

  # 'Tls12' by NAME throws on .NET 3.5, where the enum member does not exist. The numeric form
  # is the same value and degrades to a caught exception instead of a red wall.
  Ok ($file + ' never names the Tls12 enum member (absent on .NET 3.5, so naming it throws)') `
     (-not ($text -match '(?m)^\s*[^#]*(::Tls12|SecurityProtocolType\]::Tls|=\s*.?Tls1)'))

  # The verdict block is the only thing an L1 is asked to read.
  Ok ($file + ' prints a machine-readable YC-RESULT line for unattended runs') ($text -match 'YC-RESULT')
  Ok ($file + ' has a -Help page with worked examples') ($text -match 'EXAMPLE SCENARIOS')
}



# ---- the pasted line must survive BOTH shells ------------------------------------------------
# WHAT THIS CATCHES
#   The instruction tells an L1 to open an elevated PowerShell. So the line they paste is parsed
#   by POWERSHELL, not cmd - and PowerShell expands a $ inside the outer double quotes before the
#   child process ever starts. Every worked example used to read
#     powershell.exe -nop -ep bypass -c "$env:YC_ARGS='-SkipChkdsk'; iex ..."
#   which is correct in cmd.exe and silently drops the option in PowerShell: the variable expands
#   to nothing and the child receives  ='-SkipChkdsk'; iex ... . No error, just the default run.
#   Options therefore go on their OWN line, in the operator's own shell, and the paste line itself
#   must contain no $ whatsoever.
foreach ($file in @('check.ps1','adopt.ps1')) {
  $p = Join-Path $here $file
  $text = [IO.File]::ReadAllText($p)
  $pasteLines = @([regex]::Matches($text, 'powershell(\.exe)? -nop[^\r\n]*')) | ForEach-Object { $_.Value }
  Ok ($file + ' documents at least one paste line') (@($pasteLines).Count -ge 1)

  $withDollar = @($pasteLines | Where-Object { $_ -match '-c "[^"]*\$' })
  Ok ($file + ' no paste line puts a $ inside the -c quotes (PowerShell would expand it first)') `
     ($withDollar.Count -eq 0) ($(if ($withDollar.Count) { $withDollar[0] } else { '' }))

  # cmd.exe treats these as metacharacters. Inside double quotes they are safe, so what matters is
  # that the quoting is balanced and that no %VAR% can be eaten on the way through.
  $unbalanced = @($pasteLines | Where-Object { (([regex]::Matches($_, '"')).Count % 2) -ne 0 })
  Ok ($file + ' every paste line has balanced double quotes (cmd.exe needs them)') ($unbalanced.Count -eq 0)
  $percent = @($pasteLines | Where-Object { $_ -match '%[A-Za-z_][A-Za-z0-9_]*%' })
  Ok ($file + ' no paste line contains %VAR% (cmd.exe would expand it)') ($percent.Count -eq 0)

  # The option mechanism has to be spelled out for both shells, because it differs between them.
  Ok ($file + ' says how to set an option in PowerShell AND in cmd.exe') `
     (($text -match 'in PowerShell:\s+\$env:YC_ARGS') -and ($text -match 'in cmd.exe:\s+set YC_ARGS'))
}


# ---- the -Help page must also fit the console -------------------------------------------------
# The help text is hand-set to the width. It was once reflowed by a script, twice, which left
# ragged half-sentences all down the page - so the width is asserted rather than remembered.
foreach ($pair in @(@('check.ps1', 5), @('adopt.ps1', 7))) {
  $f = $pair[0]; $steps = $pair[1]
  $src = Get-OnRampFunctionSource (Join-Path $here $f) @('YcRule','YcThin','YcSay','YcNote','YcWrapTo','YcHelp')
  $tf = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.txt')
  $sb = [scriptblock]::Create(@"
`$YcWidth = 80
`$YcTotal = $steps
`$Line    = 'powershell.exe -nop -ep bypass -c "iex (New-Object Net.WebClient).DownloadString(''https://raw.githubusercontent.com/yallacloud/yc-scripts/main/$f'')"'
`$LogRef  = 'C:\Scripts\adopt-migrated-vm.log'
$src
YcHelp
"@)
  Start-Transcript -Path $tf -Force | Out-Null
  & $sb
  Stop-Transcript | Out-Null
  $body = @(Get-Content -LiteralPath $tf | Where-Object { $_ -notmatch '^\*\*\*' })
  # a URL and the paste line cannot be broken without making them un-copyable
  $over = @($body | Where-Object { $_.Length -gt 80 -and $_ -notmatch 'https?://' })
  Ok ($f + ' -Help prints no line wider than the console') ($over.Count -eq 0) `
     ($(if ($over.Count) { $over[0].Length.ToString() + ' chars: ' + $over[0].Trim() } else { '' }))
  Ok ($f + ' -Help names every exit code the script can return') `
     ((@(0,1,2,4,5,6,7) | Where-Object { $m = ('^\s+' + $_ + '\s+[A-Z]'); -not (@($body | Where-Object { $_ -match $m }).Count) }).Count -eq 0) `
     ('a code listed in the script is missing from its EXIT CODES block')
  Ok ($f + ' -Help tells the operator what they will see on screen') `
     (@($body | Where-Object { $_ -match 'WHAT YOU WILL SEE' }).Count -eq 1)
  Ok ($f + ' -Help says where the evidence for L2 goes') `
     (@($body | Where-Object { $_ -match 'WHERE THE EVIDENCE GOES' }).Count -eq 1)
  Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
}

$chk = Join-Path $here 'check.ps1'

# ---- the screen itself: nothing may exceed the console width ----------------------------------
# WHY THIS IS CHECKED AND NOT EYEBALLED
#   The verdict block is the only thing an L1 is asked to read. A line of 95 characters on an
#   80-column console wraps, and a wrapped verdict is read as half a sentence and a scroll. The
#   first version of these files hand-wrapped the text and got six lines wrong, so the wrapping
#   is now computed - and computed wrapping needs a test, which is this.
#
#   Two overflows are deliberate and are asserted as such: a line starting with two spaces is a
#   command or a path, printed verbatim so it can be copied, and a single word with no spaces in
#   it (a URL) cannot be broken at all.
. ([scriptblock]::Create((Get-OnRampFunctionSource $chk @('YcWrapTo'))))
$YcWidth = 80

# The step line, measured directly rather than through a transcript. YcStepParts returns the
# string instead of printing it for exactly this reason: -NoNewline splits a transcript line in
# two, so the first version of this check looked for a '[' that was never on the same line and
# passed having measured nothing at all.
foreach ($pair in @(@('check.ps1', 5), @('adopt.ps1', 7))) {
  $f = $pair[0]; $steps = $pair[1]
  $sb = [scriptblock]::Create(@"
`$YcWidth = 80
`$YcTotal = $steps
$(Get-OnRampFunctionSource (Join-Path $here $f) @('YcStepParts'))
foreach (`$case in @(
    @(1,'ok'),
    @(2,'running as Administrator'),
    @($steps,'this Windows can reach GitHub over TLS 1.2'),
    @(3,'a label deliberately far longer than any real step label could ever sensibly be')
  )) {
  foreach (`$mk in @('OK','FAIL','SKIP','RUN','WARN')) {
    `$p = YcStepParts `$case[0] `$case[1] `$mk
    (`$p[0].Length + `$p[1].Length).ToString() + ' ' + `$p[0].Length
  }
}
"@)
  $widths = @(& $sb)
  Ok ($f + ' every step line is exactly 80 characters wide') `
     (@($widths | Where-Object { $_.Split(' ')[0] -ne '80' }).Count -eq 0) `
     (('saw: ' + (($widths | ForEach-Object { $_.Split(' ')[0] } | Sort-Object -Unique) -join ',')))
  Ok ($f + ' every step marker starts in the same column, however long the label') `
     ((@($widths | ForEach-Object { $_.Split(' ')[1] } | Sort-Object -Unique)).Count -eq 1) `
     (('columns: ' + (($widths | ForEach-Object { $_.Split(' ')[1] } | Sort-Object -Unique) -join ',')))
}

$long = 'it can move, but something travels with it and every single item is named above as well as in the report, so none of them was invented by this screen at all'
$lines = @(YcWrapTo $long 18)
Ok 'long prose is wrapped'                     (@($lines).Count -gt 1)
Ok 'every wrapped line fits the console at the verdict indent' `
   (@($lines | Where-Object { ($_.Length + 18) -gt $YcWidth }).Count -eq 0) `
   (('widest was ' + (($lines | Measure-Object -Property Length -Maximum).Maximum + 18)))
Ok 'wrapping never loses or adds a word' `
   ((($lines -join ' ') -replace '\s+',' ') -eq ($long -replace '\s+',' '))

$cmd = '  powershell.exe -nop -ep bypass -c "iex (New-Object Net.WebClient).DownloadString(''x'')"'
Ok 'a command line (two leading spaces) is left verbatim so it can be copied' `
   ((@(YcWrapTo $cmd 18)).Count -eq 1)

$url = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip'
Ok 'an unbreakable URL survives whole'           ((@(YcWrapTo $url 18) -join '') -eq $url)
Ok 'a short line is returned untouched'          ((@(YcWrapTo 'short' 18)) -join '' -eq 'short')
Ok 'an empty string does not crash the wrapper'  ((@(YcWrapTo '' 18)).Count -ge 1)

# The whole screen, captured, for both files. Start-Transcript is the only way to see Write-Host.
foreach ($pair in @(@('check.ps1', 5), @('adopt.ps1', 7))) {
  $f = $pair[0]; $steps = $pair[1]
  $src = Get-OnRampFunctionSource (Join-Path $here $f) `
           @('YcRule','YcThin','YcSay','YcNote','YcWrapTo','YcStepParts','YcStep','YcOk','YcFail','YcRun','YcVerdict')
  $tf = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.txt')
  $sb = [scriptblock]::Create(@"
`$YcWidth = 80
`$YcTotal = $steps
$src
YcRule
YcOk 1 'read the options you gave'
YcFail $steps 'this Windows can reach GitHub over TLS 1.2, which is a deliberately long label'
YcNote 'Microsoft Windows Server 2008 R2 Standard | PowerShell 2.0.-1.-1 | .NET 3.5 or earlier (no v4 Full key)'
YcVerdict 'THIS OS CANNOT DO TLS 1.2' 7 'Red' @{
  'WHY' = '$long'
  'FIX' = 'install .NET Framework 4.8 on this VM, then paste exactly the same line again and it will carry on'
  'EVIDENCE' = 'C:\Windows\Temp\migration-check-AVERYLONGHOSTNAME01-20261026-140211.json'
} $steps
"@)
  Start-Transcript -Path $tf -Force | Out-Null
  & $sb
  Stop-Transcript | Out-Null
  # Transcript headers are the host's, not ours; only our own lines are judged.
  $body = @(Get-Content -LiteralPath $tf | Where-Object { $_ -notmatch '^\*\*\*' -and $_ -notmatch '^(Transcript|Windows PowerShell|PowerShell|Host Application|Process ID|PSVersion|PSEdition|PSCompatibleVersions|BuildVersion|CLRVersion|WSManStackVersion|SerializationVersion|Machine|Username|RunAs User|Configuration Name|Clixml)' })
  $over = @($body | Where-Object { $_.Length -gt 80 -and $_ -notmatch '^\s\s\S' -and $_ -notmatch 'https?://' })
  Ok ($f + ' prints no line wider than the 80-column console') ($over.Count -eq 0) `
     ($(if ($over.Count) { 'widest: ' + $over[0].Length + ' chars - ' + $over[0].Trim() } else { '' }))
  Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
}

# ---- the input-handling logic, lifted from check.ps1 -------------------------------------------
$chk = Join-Path $here 'check.ps1'
. ([scriptblock]::Create((Get-OnRampFunctionSource $chk @('YcAsciiFold','YcEditDistance','YcNearest','YcParseArgs'))))
$Allowed    = Get-SourceArray $chk 'Allowed'
$TakesValue = Get-SourceArray $chk 'TakesValue'
$Secret     = @()
Ok 'option list was read from check.ps1 itself' ($Allowed -contains '-SkipChkdsk' -and $Allowed -contains '-Help')
Ok 'every option that takes a value is also in the option list' `
   (@($TakesValue | Where-Object { $Allowed -notcontains $_ }).Count -eq 0)

# Typographic punctuation. This is the single most common way a pasted line fails: the dash in
# -SkipChkdsk arrives as U+2013 from WhatsApp or Word and PowerShell cannot see it.
Ok 'en dash folds to a hyphen'        ((YcAsciiFold ([string][char]0x2013 + 'SkipSql')) -eq '-SkipSql')
Ok 'em dash folds to a hyphen'        ((YcAsciiFold ([string][char]0x2014 + 'SkipSql')) -eq '-SkipSql')
Ok 'minus sign folds to a hyphen'     ((YcAsciiFold ([string][char]0x2212 + 'SkipSql')) -eq '-SkipSql')
Ok 'curly single quotes fold'         ((YcAsciiFold ([string][char]0x2018 + 'x' + [char]0x2019)) -eq "'x'")
Ok 'curly double quotes fold'         ((YcAsciiFold ([string][char]0x201C + 'x' + [char]0x201D)) -eq '"x"')
Ok 'non-breaking space folds'         ((YcAsciiFold ('-SkipSql' + [char]0x00A0 + '-Json')) -eq '-SkipSql -Json')
Ok 'soft hyphen is removed'           ((YcAsciiFold ('-Skip' + [char]0x00AD + 'Sql')) -eq '-SkipSql')
Ok 'plain ASCII is left alone'        ((YcAsciiFold '-OutDir D:\x') -eq '-OutDir D:\x')
Ok 'empty input is safe'              ((YcAsciiFold '') -eq '')

Ok 'edit distance of identical strings is 0' ((YcEditDistance 'abc' 'abc') -eq 0)
Ok 'edit distance counts one substitution'   ((YcEditDistance 'abc' 'abd') -eq 1)
Ok 'edit distance counts one deletion'       ((YcEditDistance 'abc' 'ac')  -eq 1)
Ok 'nearest match finds a one-letter typo'   ((YcNearest '-SkipSq'  $Allowed) -eq '-SkipSql')
Ok 'nearest match finds a transposition'     ((YcNearest '-SkipChkdks' $Allowed) -eq '-SkipChkdsk')
Ok 'nearest match gives up on nonsense'      ((YcNearest '-Bananas' $Allowed) -eq '')

$r = YcParseArgs ''
Ok 'no input is accepted and passes nothing through' ($r.ok -and @($r.args).Count -eq 0)

$r = YcParseArgs '-SkipChkdsk -SkipSql'
Ok 'two valid switches pass through' ($r.ok -and @($r.args).Count -eq 2)

$r = YcParseArgs '-skipchkdsk'
Ok 'a switch typed in lower case is accepted and canonicalised' ($r.ok -and $r.args[0] -eq '-SkipChkdsk')

$r = YcParseArgs '/SkipSql'
Ok 'a forward-slash switch is accepted (cmd habit)' ($r.ok -and $r.args[0] -eq '-SkipSql')

$r = YcParseArgs '-SkipChkdks'
Ok 'a typo is refused, not silently dropped' (-not $r.ok)
Ok 'a typo is answered with "did you mean"'  ((@($r.problems) -join ' ') -match 'Did you mean -SkipChkdsk')

$r = YcParseArgs ([string][char]0x2013 + 'SkipSql')
Ok 'an en-dash switch is repaired and accepted' ($r.ok -and $r.args[0] -eq '-SkipSql')
Ok 'and the operator is told their input was repaired' ((@($r.problems) -join ' ') -match 'typographic')

$r = YcParseArgs '-OutDir'
Ok 'an option missing its value is refused' (-not $r.ok)
Ok 'and says so plainly' ((@($r.problems) -join ' ') -match 'needs a value')

$r = YcParseArgs '-OutDir D:\migration'
Ok 'an option with its value passes through as two tokens' ($r.ok -and $r.args.Count -eq 2 -and $r.args[1] -eq 'D:\migration')

$r = YcParseArgs '-VerifyMaxMB lots'
Ok 'a number option given a word is refused' (-not $r.ok)
Ok 'and names the option'  ((@($r.problems) -join ' ') -match 'VerifyMaxMB')

$r = YcParseArgs '-VerifyMaxMB 2048'
Ok 'a number option given a number is accepted' ($r.ok)

$r = YcParseArgs 'SkipSql'
Ok 'a bare word with no dash is refused' (-not $r.ok)

$r = YcParseArgs '-OutDir "D:\a|b"'
Ok 'an illegal path character is refused' (-not $r.ok)

$r = YcParseArgs '-Help'
Ok '-Help is a valid option' ($r.ok -and $r.args -contains '-Help')

# ---- the same logic in adopt.ps1, which carries a secret ---------------------------------------
$adp = Join-Path $here 'adopt.ps1'
if (Test-Path -LiteralPath $adp) {
  $atext = [IO.File]::ReadAllText($adp)
  # A token in an argument list is the one thing on this screen that must never be echoed, and
  # the adopt on-ramp is where it is typed.
  Ok 'adopt.ps1 never prints the Acronis token back to the screen' `
     (-not ($atext -match '(?m)^\s*[^#]*(Write-Host|YcSay|YcNote)[^#\r\n]*\$(token|AcronisToken)\b'))
  . ([scriptblock]::Create((Get-OnRampFunctionSource $adp @('YcAsciiFold','YcEditDistance','YcNearest','YcParseArgs'))))
  $Allowed    = Get-SourceArray $adp 'Allowed'
  $TakesValue = Get-SourceArray $adp 'TakesValue'
  $Secret     = Get-SourceArray $adp 'Secret'
  $aAllowed   = $Allowed
  Ok 'adopt.ps1 knows its own options'      ($aAllowed -contains '-Run' -and $aAllowed -contains '-AcronisToken')
  $r = YcParseArgs '-Run -AcronisRegion ZZ'
  Ok 'a bad Acronis region is refused'      (-not $r.ok)
  Ok 'and the message names AE and SG'      ((@($r.problems) -join ' ') -match 'AE' )
  # A region needs its token: the pair is checked together, so the token is supplied here.
  $r = YcParseArgs '-Run -AcronisToken ABCDEFGH12345 -AcronisRegion ae'
  Ok 'a lower-case region is accepted and upper-cased' ($r.ok -and ($r.args -contains 'AE'))
  Ok 'the token value is NOT in what gets shown on screen' (-not (@($r.shown) -contains 'ABCDEFGH12345'))
  Ok 'but the token value IS in what gets passed through'  (@($r.args)  -contains 'ABCDEFGH12345')
  $r = YcParseArgs '-Run -AcronisRegion AE'
  Ok 'a region with no token is refused (Acronis would silently skip)' (-not $r.ok)
  $r = YcParseArgs '-Run -AcronisToken ABCDEFGH12345'
  Ok 'a token with no region is refused (same silent skip)' (-not $r.ok)
  $r = YcParseArgs '-Run -SkipAcronis -AcronisToken ABCDEFGH12345'
  Ok 'skip-acronis and a token together are refused as contradictory' (-not $r.ok)
  $r = YcParseArgs '-Report -Run'
  Ok 'report and run together are refused as contradictory' (-not $r.ok)
  $r = YcParseArgs ''
  Ok 'no options at all is valid for adopt (it defaults to a real run)' ($r.ok)
  $r = YcParseArgs '-Run -AcronisToken <token>'
  Ok 'the placeholder <token> is refused'   (-not $r.ok)
  $r = YcParseArgs '-Reprot'
  Ok 'a typo''d -Report is caught'          (-not $r.ok)
  Ok 'and suggests -Report'                 ((@($r.problems) -join ' ') -match 'Did you mean -Report')
}

Write-Host ''
Write-Host ('  ' + $pass + ' passed, ' + $fail + ' failed') -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
Write-Host ''
if ($fail) { throw ($fail.ToString() + ' on-ramp check(s) failed') }
