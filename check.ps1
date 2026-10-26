# ================================================================================================
# YALLACLOUD - PRE-MIGRATION CHECK. The one-liner entry point.
#
# An L1 on a customer's SOURCE VM has NOTHING: no C:\Scripts, no migration-check command, and no
# right to install anything on a machine that is still serving that customer's users. So the first
# step cannot be a command - it has to be a line they paste. This is that line.
#
# RUN IT IN AN ELEVATED POWERSHELL ON THE SOURCE VM:
#
#   powershell.exe -nop -ep bypass -c "iex (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/yallacloud/yc-scripts/main/check.ps1')"
#
# It changes NOTHING on the machine: no install, no scheduled task, no registry write, no repair.
# It writes two files - the report and its JSON - and only into TEMP.
#
# WHY THIS FILE EXISTS AND IS NOT JUST  iex (irm Test-MigrationReadiness.ps1)
#   That older line worked, but it had three faults an L1 pays for:
#     - irm is PowerShell 3.0. On Server 2008 R2 (PowerShell 2.0) the line dies with
#       "The term 'irm' is not recognized", which reads like a broken link, not an old OS.
#     - 'Tls12' as a string throws on .NET 3.5, so the SAME line fails differently on an old box.
#     - iex of a 116 KB script means nothing is verified before it runs, and a half-downloaded
#       body fails somewhere in the middle with a parse error nobody can act on.
#   This on-ramp checks the machine CAN do the job, downloads, VERIFIES THE SHA256, and only then
#   runs the check - from a real file, so the screen says which step it got to.
#
# WHAT THE OPERATOR SEES, AND WHY
#   The runner is L1, or an automation with nobody watching. Either way the SCREEN is the whole
#   interface: numbered steps, one verdict block, and - if it stops - which step it stopped at and
#   what to do about it. The log file is for L2 and for evidence; it is never the only copy of the
#   answer.
#
# WHY THE BODY IS A FUNCTION AND WHY THERE IS NO 'exit' IN IT
#   This runs through  iex , which executes it IN THE OPERATOR'S OWN SESSION. An 'exit' there does
#   not end a script - it ends the WINDOW, taking the verdict with it. Everything below returns.
#   $LASTEXITCODE still carries the result for anything that checks it.
# ================================================================================================

function Invoke-YcCheckOnRamp {

$ErrorActionPreference = 'Stop'
$ZipUrl = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip'
$ShaUrl = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256'
$Line   = 'powershell.exe -nop -ep bypass -c "iex (New-Object Net.WebClient).DownloadString(''https://raw.githubusercontent.com/yallacloud/yc-scripts/main/check.ps1'')"'
$Script = 'Test-MigrationReadiness.ps1'
$YcTotal = 5
$YcWidth = 80

# --- screen ---------------------------------------------------------------------------------
# 80 columns because that is the default console width. Wider wraps, and a wrapped verdict is
# not a verdict any more.
function YcRule { Write-Host ('=' * $YcWidth) -ForegroundColor DarkGray }
function YcThin { Write-Host ('-' * $YcWidth) -ForegroundColor DarkGray }
function YcSay  { param([string]$m,[string]$c='Gray') Write-Host ('  ' + $m) -ForegroundColor $c }
function YcNote {
  param([string]$m)
  foreach ($ln in (YcWrapTo $m 12)) { Write-Host ('            ' + $ln) -ForegroundColor DarkGray }
}
# Wrap to the console width at a word boundary. Hand-wrapping the verdict text is what put
# 95-character lines on an 80-column console: a wrapped verdict is not a verdict any more,
# because the operator reads half a sentence and scrolls.
#
# TWO DELIBERATE EXCEPTIONS, both so the operator can still copy what they see:
#   - a line that STARTS WITH TWO SPACES is verbatim. That is the convention for a command or a
#     path, and breaking one across lines makes it un-pasteable.
#   - a single word longer than the room left (a URL, a long path) goes on its own line and is
#     allowed to overflow, for the same reason.
function YcWrapTo {
  param([string]$text,[int]$indent)
  $max = $YcWidth - $indent
  if ($text -match '^  \S' -or $text.Length -le $max) { return @($text) }
  $out = @(); $cur = ''
  foreach ($word in @($text -split ' ')) {
    if ($cur -eq '')                                   { $cur = $word; continue }
    if (($cur.Length + 1 + $word.Length) -le $max)     { $cur = $cur + ' ' + $word }
    else                                               { $out += $cur; $cur = $word }
  }
  if ($cur -ne '') { $out += $cur }
  return $out
}


# One line per step, the marker always in the same column, so a glance down the right-hand edge
# is the whole story.
# Returns @(left, box) rather than printing, so the screen and the self-check measure the exact
# same string. Printed in two colours, which is the only reason it is two pieces.
function YcStepParts {
  param([int]$n,[string]$label,[string]$mark)
  $box  = '[' + $mark.PadLeft(([int](6 + $mark.Length) / 2)).PadRight(6) + ']'
  $room = $YcWidth - $box.Length - 1          # left = head + dots, then one space, then the box
  $head = ('  STEP {0}/{1}  {2} ' -f $n, $YcTotal, $label)
  # A label long enough to push the marker out of its column costs more than the words it saves:
  # the whole point of this layout is that the right-hand edge can be read without reading left.
  if ($head.Length -gt ($room - 1)) { $head = $head.Substring(0, $room - 5) + '... ' }
  $pad = $room - $head.Length
  if ($pad -lt 1) { $pad = 1 }
  return @(($head + ('.' * $pad) + ' '), $box)
}
function YcStep {
  # The marker always lands in the same column, so running an eye down the right-hand edge is the
  # whole story without reading a word.
  param([int]$n,[string]$label,[string]$mark,[string]$colour)
  $parts = YcStepParts $n $label $mark
  Write-Host $parts[0] -NoNewline -ForegroundColor Gray
  Write-Host $parts[1] -ForegroundColor $colour
}
function YcOk   { param([int]$n,[string]$w) YcStep $n $w 'OK'   'Green' }
function YcFail { param([int]$n,[string]$label) YcStep $n $label 'FAIL' 'Red' }
function YcWarn { param([int]$n,[string]$label) YcStep $n $label 'WARN' 'Yellow' }
function YcRun  { param([int]$n,[string]$w) YcStep $n $w 'RUN'  'Cyan' }

# The last thing on screen. Everything an operator has to do next is inside this block, so there
# is never a reason to scroll up to find out what happened.
function YcVerdict {
  param([string]$title,[int]$code,[string]$colour,[hashtable]$rows,[int]$blockedAt = 0)
  Write-Host ''
  YcRule
  # Build the left-hand text first and pad the WHOLE line, rather than guessing the prefix
  # length: the BLOCKED prefix is 16 characters longer than the RESULT one, so a single padding
  # sum pushed the exit code past column 80 on exactly the screens that matter most.
  if ($blockedAt -gt 0) { $left = ('  BLOCKED AT STEP {0} OF {1}   {2}' -f $blockedAt, $YcTotal, $title) }
  else                  { $left = ('  RESULT   ' + $title) }
  $tail = ('exit code ' + $code)
  $gap  = $YcWidth - $left.Length - $tail.Length - 2
  if ($gap -lt 2) { $gap = 2 }
  Write-Host $left -ForegroundColor $colour -NoNewline
  Write-Host ((' ' * $gap) + $tail) -ForegroundColor DarkGray
  YcThin
  foreach ($k in @('WHY','WHAT IT MEANS','NEXT STEP','FIX','OFFLINE ROUTE','EVIDENCE')) {
    if (-not $rows.ContainsKey($k)) { continue }
    $first = $true
    foreach ($entry in @($rows[$k])) {
      foreach ($ln in (YcWrapTo ([string]$entry) 18)) {
        if ($first) { Write-Host ('  ' + $k.PadRight(16) + $ln) -ForegroundColor Gray; $first = $false }
        else        { Write-Host ('  ' + (' ' * 16) + $ln) -ForegroundColor Gray }
      }
    }
  }
  YcRule
  # One machine-readable line for an automation scraping the transcript. Humans ignore it; a
  # remote runner does not have to parse the box above to know what happened.
  Write-Host ('  YC-RESULT script=check exit={0} verdict={1}' -f $code, ($title -replace '\s+','_')) -ForegroundColor DarkGray
  Write-Host ''
}

# --- operator input -------------------------------------------------------------------------
# Everything the operator can get wrong, caught here and named, BEFORE anything is downloaded.
# $env:YC_ARGS is the only input this on-ramp takes, and it is optional.
$Allowed = @('-OutDir','-SkipChkdsk','-SkipSql','-BackupMaxAgeDays','-UptimeWarnDays',
             '-VerifyBackups','-VerifyMaxMB','-Json','-Help')
$TakesValue = @('-OutDir','-BackupMaxAgeDays','-UptimeWarnDays','-VerifyMaxMB')

# A line copied out of WhatsApp, Word or Outlook comes back with typographic dashes and curly
# quotes. They look identical on screen and PowerShell does not accept them, so the operator
# gets a parse error about a character they cannot see. Fold them back to ASCII first.
function YcAsciiFold {
  param([string]$s)
  if (-not $s) { return '' }
  $map = @{
    [char]0x2010='-'; [char]0x2011='-'; [char]0x2012='-'; [char]0x2013='-'; [char]0x2014='-'
    [char]0x2015='-'; [char]0x2212='-'; [char]0x00AD=''
    [char]0x2018="'"; [char]0x2019="'"; [char]0x201A="'"; [char]0x201B="'"
    [char]0x201C='"'; [char]0x201D='"'; [char]0x201E='"'; [char]0x00A0=' '
  }
  $sb = New-Object Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    if ($map.ContainsKey($ch)) { [void]$sb.Append($map[$ch]) } else { [void]$sb.Append($ch) }
  }
  return $sb.ToString()
}

# Levenshtein, because "did you mean" is the difference between a fix and a ticket. Small inputs
# only - switch names - so the full matrix is cheaper than being clever.
function YcEditDistance {
  param([string]$a,[string]$b)
  $a = $a.ToLowerInvariant(); $b = $b.ToLowerInvariant()
  if (-not $a) { return $b.Length }
  if (-not $b) { return $a.Length }
  $prev = New-Object 'int[]' ($b.Length + 1)
  $cur  = New-Object 'int[]' ($b.Length + 1)
  for ($j = 0; $j -le $b.Length; $j++) { $prev[$j] = $j }
  for ($i = 1; $i -le $a.Length; $i++) {
    $cur[0] = $i
    for ($j = 1; $j -le $b.Length; $j++) {
      $cost = 1; if ($a[$i-1] -eq $b[$j-1]) { $cost = 0 }
      $d = $prev[$j] + 1
      if ($cur[$j-1] + 1 -lt $d) { $d = $cur[$j-1] + 1 }
      if ($prev[$j-1] + $cost -lt $d) { $d = $prev[$j-1] + $cost }
      $cur[$j] = $d
    }
    for ($j = 0; $j -le $b.Length; $j++) { $prev[$j] = $cur[$j] }
  }
  return $prev[$b.Length]
}

function YcNearest {
  param([string]$word,[string[]]$pool)
  $best = ''; $bestD = 99
  foreach ($p in $pool) {
    $d = YcEditDistance $word $p
    if ($d -lt $bestD) { $bestD = $d; $best = $p }
  }
  # 3 is the ceiling that still catches -Skipchkdsc and -OutDirr without inventing a match for
  # a switch that simply does not exist.
  if ($bestD -le 3) { return $best }
  return ''
}

# Returns @{ ok = $bool; args = @(); problems = @() }
function YcParseArgs {
  param([string]$raw)
  $out = @{ ok = $true; args = @(); problems = @() }
  $folded = YcAsciiFold $raw
  if ($folded -ne $raw) {
    $out.problems += 'your input contained typographic dashes or curly quotes (pasted from a chat or a document) - they were folded back to ASCII'
  }
  $folded = $folded.Trim()
  if (-not $folded) { return $out }
  $toks = @($folded -split '\s+' | Where-Object { $_ })
  $i = 0
  while ($i -lt $toks.Count) {
    $t = $toks[$i]
    if ($t -notmatch '^[-/]') {
      $out.ok = $false
      $out.problems += ("'" + $t + "' is not a switch. Every item has to start with a dash, like -SkipChkdsk.")
      $i++; continue
    }
    $name = '-' + $t.TrimStart('-','/')
    $hit  = @($Allowed | Where-Object { $_ -eq $name })   # -eq on strings is case-insensitive
    if (-not $hit) {
      $out.ok = $false
      $near = YcNearest $name $Allowed
      if ($near) { $out.problems += ("'" + $t + "' is not an option. Did you mean " + $near + " ?") }
      else       { $out.problems += ("'" + $t + "' is not an option for this check.") }
      $i++; continue
    }
    $canon = $hit[0]
    $out.args += $canon
    if ($TakesValue -contains $canon) {
      if ($i + 1 -ge $toks.Count -or $toks[$i+1] -match '^[-/][A-Za-z]') {
        $out.ok = $false
        $out.problems += ($canon + ' needs a value after it.')
        $i++; continue
      }
      $val = $toks[$i+1]
      if ($canon -ne '-OutDir' -and $val -notmatch '^\d+$') {
        $out.ok = $false
        $out.problems += ($canon + ' takes a whole number, not ' + "'" + $val + "'.")
      }
      if ($canon -eq '-OutDir' -and $val -match '[<>|?*"]') {
        $out.ok = $false
        $out.problems += ('-OutDir is not a valid path: ' + "'" + $val + "'.")
      }
      $out.args += $val
      $i += 2; continue
    }
    $i++
  }
  return $out
}

# --- help -----------------------------------------------------------------------------------
function YcHelp {
  Write-Host ''
  YcRule
  Write-Host '  YALLACLOUD  PRE-MIGRATION CHECK            can this VM be migrated, and' -ForegroundColor Green
  Write-Host '  check.ps1  (the on-ramp)                   what comes with it if we move it?' -ForegroundColor Green
  YcRule
  Write-Host ''
  YcSay 'WHAT IT IS' 'White'
  YcSay '  A read-only survey of a SOURCE VM, run BEFORE the migration window while'
  YcSay '  the VM is still serving its users. It installs nothing, schedules nothing'
  YcSay '  and repairs nothing. It writes two files, into TEMP: a report and its JSON.'
  Write-Host ''
  YcSay 'HOW TO RUN IT' 'White'
  YcSay '  In an ELEVATED PowerShell on the SOURCE VM, paste this one line:'
  Write-Host ''
  Write-Host ('    ' + $Line) -ForegroundColor White
  Write-Host ''
  YcSay '  The same line works from PowerShell, from cmd.exe and from the Run box.'
  YcSay '  There is no step two.'
  Write-Host ''
  YcSay 'WHAT YOU WILL SEE' 'White'
  YcSay '  Five numbered steps, each ending OK or FAIL in the same column. Then one'
  YcSay '  block at the bottom holding the answer and what to do next. If it stops'
  YcSay '  early, that block says WHICH step it stopped at, why, and how to fix it.'
  YcSay '  You never have to scroll up: the bottom of the screen is the whole answer.'
  Write-Host ''
  YcSay 'EXAMPLE SCENARIOS' 'White'
  Write-Host ''
  YcSay '  1) "The client wants MYSQLVM01 moved on Friday. Can we?"' 'Cyan'
  YcSay '     Paste the line and read the RESULT block:'
  YcSay '       GO              nothing found that should stop the move'
  YcSay '       GO WITH RISK    it can move, but something travels with it, and'
  YcSay '                       every such thing is named'
  YcSay '       DO NOT MIGRATE  fix something first. Moving now risks data that'
  YcSay '                       cannot be got back afterwards.'
  YcSay '     Send BOTH files listed under EVIDENCE to L2 before a window is agreed.'
  Write-Host ''
  YcSay '  2) "The data drive is 4 TB and the disk scan is taking forever."' 'Cyan'
  YcSay '     The volume scans read the whole disk. You may skip them - but say so in'
  YcSay '     your handover, because a dirty volume is exactly the thing that makes a'
  YcSay '     migration lose data.'
  YcSay '       YC_ARGS = -SkipChkdsk'
  Write-Host ''
  YcSay '  3) "It is production SQL and I may not touch SQL at all."' 'Cyan'
  YcSay '     The check never writes to SQL - it reads damaged-page history and backup'
  YcSay '     dates - but if the customer forbids even a connection:'
  YcSay '       YC_ARGS = -SkipSql'
  Write-Host ''
  YcSay '  4) "I need the report on a share, not in my TEMP."' 'Cyan'
  YcSay '       YC_ARGS = -OutDir D:\migration'
  Write-Host ''
  YcSay '  5) "I am running this remotely, from a script, nobody is watching."' 'Cyan'
  YcSay '     Nothing to change. It never asks a question and never waits for input.'
  YcSay '     The last line of the transcript is written for a parser:'
  YcSay '       YC-RESULT script=check exit=1 verdict=GO_WITH_RISK'
  Write-Host ''
  YcSay '  6) "It said BLOCKED AT STEP 3, this OS cannot do TLS 1.2."' 'Cyan'
  YcSay '     Server 2008 R2 with only .NET 3.5 cannot speak TLS 1.2, and GitHub'
  YcSay '     accepts nothing less. Install .NET Framework 4.8 on that VM, or use the'
  YcSay '     OFFLINE ROUTE the screen prints - download the zip somewhere with'
  YcSay '     internet and copy it over. Nothing on the VM was changed.'
  Write-Host ''
  YcSay '  7) "It said BLOCKED AT STEP 1, my options were not understood."' 'Cyan'
  YcSay '     It read YC_ARGS, did not recognise something, and stopped before'
  YcSay '     downloading anything. The screen names the item and, if it is close to a'
  YcSay '     real option, suggests the one you meant.'
  Write-Host ''
  YcSay 'HOW TO PASS AN OPTION' 'White'
  YcSay '  Options go in YC_ARGS, set on the line BEFORE the paste line. Do NOT put'
  YcSay '  them inside the paste line: PowerShell parses the outer quotes first, so a'
  YcSay '  $ in there is expanded before the line runs and your option disappears'
  YcSay '  with no error at all.'
  Write-Host ''
  YcSay '    in PowerShell:   $env:YC_ARGS = ''-SkipChkdsk'''
  YcSay '    in cmd.exe:      set YC_ARGS=-SkipChkdsk'
  Write-Host ''
  YcSay '  Then paste the line. To go back to the defaults, clear it again:'
  Write-Host ''
  YcSay '    in PowerShell:   Remove-Item Env:\YC_ARGS'
  YcSay '    in cmd.exe:      set YC_ARGS='
  Write-Host ''
  YcSay 'OPTIONS' 'White'
  YcSay '  -SkipChkdsk            skip the volume scans. They read the whole disk.'
  YcSay '  -SkipSql               do not connect to SQL Server at all'
  YcSay '  -OutDir <path>         where the report goes. Default: your TEMP'
  YcSay '  -VerifyBackups         RESTORE VERIFYONLY every full backup, any size'
  YcSay '  -VerifyMaxMB <n>       above this size read only the header (default 51200)'
  YcSay '  -BackupMaxAgeDays <n>  a backup older than this is no fallback (default 7)'
  YcSay '  -UptimeWarnDays <n>    flag a VM up longer than this (default 180)'
  YcSay '  -Json                  print the JSON to the screen as well'
  YcSay '  -Help                  this page'
  Write-Host ''
  YcSay 'EXIT CODES' 'White'
  YcSay '  0   GO              nothing found that should stop the move'
  YcSay '  1   GO WITH RISK    it can move, but something travels with it'
  YcSay '  2   DO NOT MIGRATE  fix something first, or your options were wrong'
  YcSay '  4   BAD PAYLOAD     the zip failed its SHA256. Nothing was run.'
  YcSay '  5   NOT ELEVATED    nothing was checked at all'
  YcSay '  6   NO EGRESS       no HTTPS to raw.githubusercontent.com'
  YcSay '  7   OLD OS          this Windows cannot speak TLS 1.2'
  Write-Host ''
  YcSay 'WHERE THE EVIDENCE GOES' 'White'
  YcSay '  migration-check-<HOST>-<date>.txt and .json, in -OutDir (TEMP by default).'
  YcSay '  The screen is the answer; those two files are the record of what this VM'
  YcSay '  was like BEFORE it moved. Keep both - they are dated evidence.'
  Write-Host ''
  YcSay 'AFTER THE MIGRATION' 'White'
  YcSay '  The other half of this pair runs on the MIGRATED VM, once, and adopts it:'
  YcSay '    powershell.exe -nop -ep bypass -c "iex (New-Object Net.WebClient).DownloadString(''https://raw.githubusercontent.com/yallacloud/yc-scripts/main/adopt.ps1'')"'
  Write-Host ''
  YcRule
  Write-Host ''
}

# --- capability preflight -------------------------------------------------------------------
function YcTlsAvailable {
  # The honest test, and it needs no network: if the .NET on this box does not know the name
  # Tls12, no amount of registry work in the world makes this process speak it.
  try { return ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls12') } catch { return $false }
}
function YcEnableTls {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}
}
function YcSha256File {
  param([string]$Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $fs = [IO.File]::OpenRead($Path)
    try { $bytes = $sha.ComputeHash($fs) } finally { $fs.Close() }
  } finally { try { $sha.Clear() } catch {} }
  $sb = New-Object Text.StringBuilder
  foreach ($b in $bytes) { [void]$sb.Append($b.ToString('X2')) }
  return $sb.ToString()
}
function YcDotNetLabel {
  try {
    $r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
    if ($r.Release -ge 528040) { return '4.8 or later' }
    if ($r.Release -ge 461808) { return '4.7.2' }
    if ($r.Release -ge 394802) { return '4.6.2' }
    if ($r.Release -ge 378389) { return '4.5 or later' }
    return ('4.x release ' + $r.Release)
  } catch { return '3.5 or earlier (no v4 Full key)' }
}
# Pull ONE named file out of the zip. The .NET path needs 4.5; the Shell path is what Server
# 2008 R2 with .NET 3.5 actually has, and it is asynchronous, so it is waited for rather than
# trusted.
function YcExtractOne {
  param([string]$Zip,[string]$Dest,[string]$Name)
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
      $e = $z.Entries | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
      if (-not $e) { throw ($Name + ' is not inside the payload zip') }
      [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $Dest $Name), $true)
    } finally { $z.Dispose() }
    return 'dotnet'
  } catch [Exception] {
    if ($_.Exception.Message -like '*not inside the payload*') { throw }
  }
  $sh = New-Object -ComObject Shell.Application
  $src = $sh.NameSpace($Zip)
  $dst = $sh.NameSpace($Dest)
  if (-not $src -or -not $dst) { throw 'Windows could not open the zip (Shell.Application returned nothing)' }
  $item = $src.Items() | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
  if (-not $item) { throw ($Name + ' is not inside the payload zip') }
  $dst.CopyHere($item, 20)   # 4 = no progress window, 16 = yes to all
  $target = Join-Path $Dest $Name
  for ($i = 0; $i -lt 120; $i++) {
    if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -gt 0) { break }
    Start-Sleep -Milliseconds 500
  }
  if (-not (Test-Path -LiteralPath $target)) { throw 'the copy out of the zip did not finish in 60 seconds' }
  return 'shell'
}

# --- run ------------------------------------------------------------------------------------
$raw = $env:YC_ARGS
if (-not $raw) { $raw = $env:YC_CHECK_ARGS }    # accepted, for anything that already sets it
$parsed = YcParseArgs $raw

if (@($parsed.args) -contains '-Help' -or $raw -match '(^|\s)[-/](\?|h|help)(\s|$)') { YcHelp; return 0 }

Write-Host ''
YcRule
Write-Host '  YALLACLOUD  PRE-MIGRATION CHECK            source VM go / no-go' -ForegroundColor Green
$host_ = $env:COMPUTERNAME
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
Write-Host ('  host ' + $host_.PadRight(21) + $stamp.PadRight(25) + 'read-only, changes nothing') -ForegroundColor DarkGray
YcRule
Write-Host ''

if (@($parsed.problems).Count) {
  foreach ($p in $parsed.problems) { YcSay ('INPUT: ' + $p) 'Yellow' }
  Write-Host ''
}
if (-not $parsed.ok) {
  YcFail 1 'read the options you gave'
  YcVerdict 'YOUR OPTIONS WERE NOT UNDERSTOOD' 2 'Red' @{
    'WHY'       = 'the problems listed above are in $env:YC_ARGS. Nothing was downloaded and nothing on this machine was touched.'
    'FIX'       = @('clear it and run the plain line:', '  Remove-Item Env:\YC_ARGS -ErrorAction SilentlyContinue', 'or see every option and a worked example for each:', '  set YC_ARGS=-Help   (cmd)   or   $env:YC_ARGS=''-Help''   (PowerShell)')
  } 1
  return 2
}
YcOk 1 'read the options you gave'
if (@($parsed.args).Count) { YcNote ('passing through: ' + ($parsed.args -join ' ')) }

# Elevation. Checked before anything else that could half-happen.
$admin = $false
try {
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}
if (-not $admin) {
  YcFail 2 'running as Administrator'
  YcVerdict 'NOT ELEVATED - NOTHING WAS CHECKED' 5 'Red' @{
    'WHY'       = 'chkdsk, VSS and the licensing store are all readable only by an administrator. A run without it would report a clean machine it never actually looked at.'
    'FIX'       = @('close this window. Right-click PowerShell -> Run as administrator, then paste:', '', '  ' + $Line)
  } 2
  return 5
}
YcOk 2 'running as Administrator'

# Capability. The one thing that can make this machine simply unable to do the job.
$osCaption = 'unknown Windows'
try { $osCaption = (Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).Caption.Trim() } catch {}
$psv = $PSVersionTable.PSVersion.ToString()
$net = YcDotNetLabel
$wow = ($env:PROCESSOR_ARCHITEW6432 -ne $null -and $env:PROCESSOR_ARCHITEW6432 -ne '')

if (-not (YcTlsAvailable)) {
  YcFail 3 'this Windows can reach GitHub over TLS 1.2'
  YcNote ($osCaption + ' | PowerShell ' + $psv + ' | .NET ' + $net)
  YcVerdict 'THIS OS CANNOT DO TLS 1.2' 7 'Red' @{
    'WHY'           = @(($osCaption + ' with .NET ' + $net + '.'), 'GitHub requires TLS 1.2 and .NET 3.5 cannot speak it. This is the operating', 'system, not the network and not the link. Nothing was changed.')
    'FIX'           = 'install .NET Framework 4.8 on this VM, then paste the same line again.'
    'OFFLINE ROUTE' = @('if installing .NET here is not allowed, on ANY machine with internet download', '  ' + $ZipUrl, '  ' + $ShaUrl, 'copy both onto this VM, unzip the first, and run from the unzipped folder:', '  powershell.exe -nop -ep bypass -File .\' + $Script)
  } 3
  return 7
}
YcEnableTls
YcOk 3 'this Windows can reach GitHub over TLS 1.2'
YcNote ($osCaption + ' | PowerShell ' + $psv + ' | .NET ' + $net)
if ($wow) { YcSay 'NOTE: this is the 32-bit PowerShell on a 64-bit Windows. Some hardware and' 'Yellow'
            YcSay '      licensing detail is invisible from here. Prefer the 64-bit console.' 'Yellow' }

# Download. Nothing is written outside TEMP, and the folder goes away on every exit path.
$ProgressPreference = 'SilentlyContinue'   # the progress bar costs ~0.8s per MB and shows nobody anything
$tmp = Join-Path $env:TEMP ('yc-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'payload.zip'
try {
  $wc = New-Object Net.WebClient
  $wc.DownloadFile($ZipUrl, $zip)
  $sidecar = $wc.DownloadString($ShaUrl)
  $kb = [int]((Get-Item -LiteralPath $zip).Length / 1024)
  YcOk 4 ('download and verify the payload (' + $kb + ' KB)')
} catch {
  YcFail 4 'download and verify the payload'
  $msg = $_.Exception.Message
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  YcVerdict 'NO HTTPS TO GITHUB FROM THIS VM' 6 'Red' @{
    'WHY'           = @($msg, 'This VM needs outbound HTTPS to raw.githubusercontent.com:443. Nothing was changed.')
    'FIX'           = @('check egress and any proxy. If this VM goes out through a proxy, set it first:', '  netsh winhttp show proxy', 'then paste the line again.')
    'OFFLINE ROUTE' = @('on any machine with internet download', '  ' + $ZipUrl, 'copy it onto this VM, unzip it, and run from the unzipped folder:', '  powershell.exe -nop -ep bypass -File .\' + $Script)
  } 4
  return 6
}

$want = ([string]$sidecar -split '\s+')[0].Trim().ToUpper()
$got  = YcSha256File $zip
if (-not $want -or $want -ne $got) {
  YcFail 5 'SHA256 matches the published sidecar'
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  YcVerdict 'PAYLOAD FAILED ITS SHA256 - NOTHING WAS RUN' 4 'Red' @{
    'WHY'       = @('the zip does not match its published hash, so it was not opened.', ('expected ' + $want), ('got      ' + $got))
    'FIX'       = 'if a payload was pushed in the last 5 minutes this is the GitHub CDN cache. Wait five minutes and paste the line again. If it fails twice, stop and tell L2 - a persistent mismatch is not a retry problem.'
  } 5
  return 4
}
YcNote ('sha256 ' + $got.Substring(0,32) + '...')

try {
  $how = YcExtractOne $zip $tmp $Script
  YcNote ('unpacked with the ' + $how + ' unzip path')
} catch {
  YcFail 5 'unpack the check out of the payload'
  $msg = $_.Exception.Message
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  YcVerdict 'COULD NOT UNPACK THE PAYLOAD' 4 'Red' @{
    'WHY' = @($msg, 'The download was verified, so this is the unzip, not the file. Nothing was changed.')
    'FIX' = @('unzip it by hand and run the check from the unzipped folder:', '  ' + $ZipUrl, '  powershell.exe -nop -ep bypass -File .\' + $Script)
  } 5
  return 4
}
YcRun 5 'run the check'
Write-Host ''
YcThin
Write-Host '  the check''s own output follows. Its verdict, and where your report was written,' -ForegroundColor DarkGray
Write-Host '  are repeated at the very bottom of this screen.' -ForegroundColor DarkGray
YcThin
Write-Host ''

$code = 0
try {
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $tmp $Script)) + @($parsed.args)
  # -File, never splatting: an array splatted into a script binds POSITIONALLY, which is how
  # '-Report' once landed in the first positional parameter instead of being read as a switch.
  $proc = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                        -ArgumentList $argList -Wait -PassThru -NoNewWindow
  $code = $proc.ExitCode
} catch {
  YcVerdict 'THE CHECK ITSELF DID NOT START' 3 'Red' @{
    'WHY' = $_.Exception.Message
    'FIX' = 'tell L2 and attach this screen. The payload verified, so this is the check script, not the download.'
  } 5
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  return 3
}

# The report lives in -OutDir (TEMP by default) and the temp folder below is only the unzip, so
# cleaning it never removes the evidence.
$outDir = $env:TEMP
for ($i = 0; $i -lt @($parsed.args).Count; $i++) {
  if ($parsed.args[$i] -eq '-OutDir' -and ($i + 1) -lt @($parsed.args).Count) { $outDir = $parsed.args[$i+1] }
}
$files = @()
try {
  $files = @(Get-ChildItem -Path $outDir -Filter ('migration-check-' + $host_ + '-*') -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 2 | ForEach-Object { $_.FullName })
} catch {}
if (-not $files.Count) { $files = @(('no report file was found in ' + $outDir + ' - say so to L2, the verdict above is then the only record')) }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

switch ($code) {
  0 { YcVerdict 'GO' 0 'Green' @{
        'WHAT IT MEANS' = 'nothing was found that should stop this VM being migrated.'
        'NEXT STEP'     = 'send both files below to L2, then the migration window can be agreed.'
        'EVIDENCE'      = $files } }
  1 { YcVerdict 'GO WITH RISK' 1 'Yellow' @{
        'WHAT IT MEANS' = 'it can move, but something travels with it. Every item is named above and in the report - none of them was invented by this screen.'
        'NEXT STEP'     = 'send both files below to L2 BEFORE anyone agrees a downtime.'
        'EVIDENCE'      = $files } }
  2 { YcVerdict 'DO NOT MIGRATE' 2 'Red' @{
        'WHAT IT MEANS' = 'something has to be fixed first. Moving this VM now risks data that cannot be got back afterwards.'
        'NEXT STEP'     = 'stop. Send both files below to L2 and do not book a window yet.'
        'EVIDENCE'      = $files } }
  5 { YcVerdict 'NOT ELEVATED - NOTHING WAS CHECKED' 5 'Red' @{
        'FIX'      = @('right-click PowerShell -> Run as administrator, then paste:', '  ' + $Line)
        'EVIDENCE' = $files } }
  default { YcVerdict ('THE CHECK EXITED ' + $code) $code 'Yellow' @{
        'WHAT IT MEANS' = 'this is not one of the four answers it is supposed to give.'
        'NEXT STEP'     = 'send this screen and the files below to L2.'
        'EVIDENCE'      = $files } }
}
return $code

}  # end Invoke-YcCheckOnRamp

$code = 0
try   { $code = Invoke-YcCheckOnRamp }
catch { Write-Host ('  the on-ramp itself failed: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host '  Nothing on this machine was changed. Send this line to L2.' -ForegroundColor Yellow
        $code = 9 }
# Carried for anything that checks it, WITHOUT ending the operator's session.
$global:LASTEXITCODE = $code
