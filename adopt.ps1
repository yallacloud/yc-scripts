# ================================================================================================
# YALLACLOUD - adopt a MIGRATED VM. The one-liner entry point.
#
# An L1 logging into a freshly migrated VM has NOTHING: no C:\Scripts, no yallacloud command, no
# migrated-vm command. So the first step cannot be a command - it has to be a line they paste.
#
# RUN IT IN AN ELEVATED POWERSHELL ON THE MIGRATED VM:
#
#   powershell.exe -nop -ep bypass -c "iex (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/yallacloud/yc-scripts/main/adopt.ps1')"
#
# That is the whole deployment. It fetches the payload, verifies it, and adopts the machine.
#
# WHY THIS FILE IS AT THE REPO ROOT AND NOT IN THE PAYLOAD
#   It is the thing you run BEFORE you have the payload. Keeping it beside the zip means one
#   public URL, no credential, and nothing to install first - the same design as the zip itself.
#
# WHAT THE OPERATOR SEES, AND WHY
#   The runner is L1, or an automation with nobody watching. Either way the SCREEN is the whole
#   interface: numbered steps with the marker in a fixed column, then one verdict block holding
#   everything they have to do next - and if it stops, WHICH step it stopped at and why. The log
#   file is for L2 and for evidence; it is never the only copy of the answer.
#
# WHY THE BODY IS A FUNCTION AND WHY THERE IS NO 'exit' IN IT
#   This file is designed to be run through  iex , which executes it IN THE OPERATOR'S OWN
#   SESSION. An 'exit' there does not end a script - it ends the WINDOW. This file used to end
#   with 'exit $code', so every single run closed the console the instant migrated-vm finished,
#   and the operator never got to read the verdict that had just been printed. Reported as
#   "why the script exits?". Everything below returns instead, and $LASTEXITCODE still carries
#   the result for anything that checks it.
#
# WHAT IT DOES, IN ORDER
#   1. reads and CHECKS the options you gave, before touching the network
#   2. refuses politely if not elevated, and prints the exact line to re-run
#   3. proves this Windows can speak TLS 1.2 at all - .NET 3.5 cannot, and GitHub needs it
#   4. downloads the payload zip + its .sha256 sidecar and VERIFIES THE HASH
#   5. unpacks the two files needed to continue: Adopt-MigratedVm.ps1 and Update-YcScripts.ps1
#   6. settles the one question that needs an answer - whether Acronis backup is being installed
#   7. hands over to  migrated-vm , which does the nineteen phases and pulls the full payload
#
# It is deliberately small. Everything it could do twice, it leaves to the script it hands over to.
# ================================================================================================

function Invoke-YcAdoptOnRamp {

$ErrorActionPreference = 'Stop'
$ZipUrl = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip'
$ShaUrl = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256'
$Line   = 'powershell.exe -nop -ep bypass -c "iex (New-Object Net.WebClient).DownloadString(''https://raw.githubusercontent.com/yallacloud/yc-scripts/main/adopt.ps1'')"'
$Dir    = 'C:\Scripts'
$Need   = 'Adopt-MigratedVm.ps1 Update-YcScripts.ps1'
$LogRef = 'C:\Scripts\adopt-migrated-vm.log'
$YcTotal = 7
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
function YcSkip { param([int]$n,[string]$label) YcStep $n $label 'SKIP' 'DarkGray' }
function YcRun  { param([int]$n,[string]$w) YcStep $n $w 'RUN'  'Cyan' }

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
  # One machine-readable line for an automation scraping the transcript.
  Write-Host ('  YC-RESULT script=adopt exit={0} verdict={1}' -f $code, ($title -replace '\s+','_')) -ForegroundColor DarkGray
  Write-Host ''
}

# --- operator input -------------------------------------------------------------------------
# Everything the operator can get wrong, caught and named BEFORE anything is downloaded. The
# option list is the subset of migrated-vm worth reaching from a pasted line; the rest are for
# someone who already has C:\Scripts and can type  migrated-vm -Help .
$Allowed = @('-Report','-Run','-Status','-AcronisToken','-AcronisRegion','-SkipAcronis',
             '-SkipSalt','-SaltMaster','-GrowDisk','-AllowReboot','-Force','-Skip','-Only',
             '-QemuGaMsi','-SkipGlpi','-SkipWsus','-Help')
$TakesValue = @('-AcronisToken','-AcronisRegion','-SaltMaster','-Skip','-Only','-QemuGaMsi')
$Secret     = @('-AcronisToken')

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
  if ($bestD -le 3) { return $best }
  return ''
}

# Returns @{ ok; args; problems; shown } - 'shown' is 'args' with any secret value replaced, and
# it is the ONLY one of the two that is ever allowed near the screen.
function YcParseArgs {
  param([string]$raw)
  $out = @{ ok = $true; args = @(); problems = @(); shown = @() }
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
      $out.problems += ("'" + $t + "' is not a switch. Every item has to start with a dash, like -Run.")
      $i++; continue
    }
    $name = '-' + $t.TrimStart('-','/')
    $hit  = @($Allowed | Where-Object { $_ -eq $name })   # -eq on strings is case-insensitive
    if (-not $hit) {
      $out.ok = $false
      $near = YcNearest $name $Allowed
      if ($near) { $out.problems += ("'" + $t + "' is not an option. Did you mean " + $near + " ?") }
      else       { $out.problems += ("'" + $t + "' is not an option for the adopt run. Options that only make sense once C:\Scripts exists are on  migrated-vm -Help .") }
      $i++; continue
    }
    $canon = $hit[0]
    if (-not ($TakesValue -contains $canon)) { $out.args += $canon; $out.shown += $canon; $i++; continue }

    if ($i + 1 -ge $toks.Count -or $toks[$i+1] -match '^[-/][A-Za-z]') {
      $out.ok = $false
      $out.problems += ($canon + ' needs a value after it.')
      $i++; continue
    }
    $val = $toks[$i+1]

    if ($canon -eq '-AcronisRegion') {
      $up = $val.ToUpperInvariant()
      if ($up -ne 'AE' -and $up -ne 'SG') {
        $out.ok = $false
        $out.problems += ("-AcronisRegion is AE (UAE) or SG (Singapore). '" + $val + "' is neither.")
      }
      $val = $up
    }
    if ($canon -eq '-AcronisToken') {
      # The commonest mistake with a worked example: pasting the example instead of the token.
      if ($val -match '^[<\[({].*[>\])}]$' -or $val -match '^(token|your-token|xxx+|TOKEN)$') {
        $out.ok = $false
        $out.problems += ("-AcronisToken still has the placeholder from the example in it. Put the real registration token there.")
      } elseif ($val.Length -lt 8) {
        $out.ok = $false
        $out.problems += ('-AcronisToken looks too short to be a registration token (' + $val.Length + ' characters). Check it was pasted whole.')
      }
    }
    $out.args  += $canon
    $out.args  += $val
    $out.shown += $canon
    if ($Secret -contains $canon) { $out.shown += ('<' + $val.Length + ' characters, not shown>') }
    else                          { $out.shown += $val }
    $i += 2
  }

  # Cross-checks. A token with no region installs nothing and says nothing, which reads on the
  # screen as "Acronis was skipped" and gets found weeks later by the customer.
  $hasTok = ($out.args -contains '-AcronisToken')
  $hasReg = ($out.args -contains '-AcronisRegion')
  if ($hasTok -and -not $hasReg) {
    $out.ok = $false
    $out.problems += 'you gave -AcronisToken but no -AcronisRegion. Add -AcronisRegion AE or -AcronisRegion SG, or Acronis is silently skipped.'
  }
  if ($hasReg -and -not $hasTok) {
    $out.ok = $false
    $out.problems += 'you gave -AcronisRegion but no -AcronisToken. Add the token, or drop the region.'
  }
  if (($out.args -contains '-SkipAcronis') -and $hasTok) {
    $out.ok = $false
    $out.problems += '-SkipAcronis and -AcronisToken contradict each other. Pick one.'
  }
  if (($out.args -contains '-Report') -and ($out.args -contains '-Run')) {
    $out.ok = $false
    $out.problems += '-Report and -Run contradict each other. -Report looks, -Run does. Pick one.'
  }
  return $out
}

# --- help -----------------------------------------------------------------------------------
function YcHelp {
  Write-Host ''
  YcRule
  Write-Host '  YALLACLOUD  ADOPT A MIGRATED VM            bring a VM that has just been' -ForegroundColor Green
  Write-Host '  adopt.ps1  (the on-ramp)                   moved up to the same day-2' -ForegroundColor Green
  Write-Host '                                             standard as one we deployed' -ForegroundColor Green
  YcRule
  Write-Host ''
  YcSay 'WHAT IT IS' 'White'
  YcSay '  Run ONCE on a VM migrated from vCenter or OpenStack. It surveys the machine,'
  YcSay '  checks the prerequisites, pulls C:\Scripts, puts it on the PATH so the'
  YcSay '  yallacloud command works, reports what SQL is there, takes a first full'
  YcSay '  backup and schedules the recurring ones, joins the Salt master, optionally'
  YcSay '  installs Acronis, and registers the tasks that keep the VM current.'
  Write-Host ''
  YcSay '  It NEVER installs SQL Server, never activates Windows, and never removes'
  YcSay '  anything it cannot positively identify. Those are decisions for a human,'
  YcSay '  and it says so on the screen rather than guessing.'
  Write-Host ''
  YcSay 'HOW TO RUN IT' 'White'
  YcSay '  In an ELEVATED PowerShell on the MIGRATED VM, paste this one line:'
  Write-Host ''
  Write-Host ('    ' + $Line) -ForegroundColor White
  Write-Host ''
  YcSay '  The same line works from PowerShell, from cmd.exe and from the Run box.'
  YcSay '  With no options it RUNS the adoption. There is no step two.'
  Write-Host ''
  YcSay 'WHAT YOU WILL SEE' 'White'
  YcSay '  Seven numbered steps, each ending OK, SKIP or FAIL in the same column, then'
  YcSay '  migrated-vm''s own output, then one block at the bottom holding the result'
  YcSay '  and what to do next. If it stops early, that block says WHICH step it'
  YcSay '  stopped at and why. The bottom of the screen is the whole answer.'
  Write-Host ''
  YcSay 'EXAMPLE SCENARIOS' 'White'
  Write-Host ''
  YcSay '  1) "The VM is migrated. Just adopt it."' 'Cyan'
  YcSay '     Paste the line, nothing else. Read the RESULT block at the bottom.'
  Write-Host ''
  YcSay '  2) "It is production. Show me what it would do first."' 'Cyan'
  YcSay '     -Report looks at everything and changes nothing at all:'
  YcSay '       YC_ARGS = -Report'
  Write-Host ''
  YcSay '  3) "This customer bought backup. Install Acronis too."' 'Cyan'
  YcSay '     Easiest: paste the plain line. If the console is interactive it ASKS you'
  YcSay '     about Acronis and checks the token and region as you type them, so there'
  YcSay '     is nothing to quote and nothing to mistype.'
  YcSay '     To pass them instead, BOTH are needed - a token with no region installs'
  YcSay '     nothing and the screen would only say Acronis was skipped:'
  YcSay '       YC_ARGS = -Run -AcronisToken <the-real-token> -AcronisRegion AE'
  YcSay '     Region is AE for UAE or SG for Singapore.'
  Write-Host ''
  YcSay '  4) "No backup for this one."' 'Cyan'
  YcSay '     Nothing to do. With no token Acronis is skipped, and that is a normal,'
  YcSay '     successful outcome - backup is sold per customer. -SkipAcronis makes it'
  YcSay '     explicit and stops the question being asked.'
  Write-Host ''
  YcSay '  5) "I am running this remotely, from a script, nobody is watching."' 'Cyan'
  YcSay '     It never waits for input when the console is not interactive: it takes'
  YcSay '     YC_ARGS and gets on with it, and Acronis is skipped unless a token was'
  YcSay '     passed. The last line of the transcript is written for a parser:'
  YcSay '       YC-RESULT script=adopt exit=0 verdict=ADOPTED'
  Write-Host ''
  YcSay '  6) "It said REBOOT REQUIRED."' 'Cyan'
  YcSay '     That is exit 1 and it is not a failure. A Windows update is half applied,'
  YcSay '     which makes the later phases unreliable, so it stopped on purpose.'
  YcSay '     Reboot the VM and paste the SAME line again.'
  Write-Host ''
  YcSay '  7) "It said BLOCKED AT STEP 3, this OS cannot do TLS 1.2."' 'Cyan'
  YcSay '     Server 2008 R2 with only .NET 3.5 cannot speak TLS 1.2, and GitHub'
  YcSay '     accepts nothing less. Install .NET Framework 4.8, or use the OFFLINE'
  YcSay '     ROUTE the screen prints. Nothing on the VM was changed.'
  Write-Host ''
  YcSay '  8) "What was actually done to this machine?"' 'Cyan'
  YcSay '     After the first run C:\Scripts exists, so use the real commands:'
  YcSay '       migrated-vm -Status    what a previous run did here'
  YcSay '       migrated-vm -Help      every option, not just these'
  YcSay '       yallacloud             the whole catalogue of commands on this box'
  Write-Host ''
  YcSay 'HOW TO PASS AN OPTION' 'White'
  YcSay '  Options go in YC_ARGS, set on the line BEFORE the paste line. Do NOT put'
  YcSay '  them inside the paste line: PowerShell parses the outer quotes first, so a'
  YcSay '  $ in there is expanded before the line runs and your option disappears'
  YcSay '  with no error at all.'
  Write-Host ''
  YcSay '    in PowerShell:   $env:YC_ARGS = ''-Report'''
  YcSay '    in cmd.exe:      set YC_ARGS=-Report'
  Write-Host ''
  YcSay '  Then paste the line. To go back to a plain adoption, clear it again:'
  Write-Host ''
  YcSay '    in PowerShell:   Remove-Item Env:\YC_ARGS'
  YcSay '    in cmd.exe:      set YC_ARGS='
  Write-Host ''
  YcSay 'OPTIONS' 'White'
  YcSay '  -Report                look at everything, change nothing'
  YcSay '  -Run                   do it. This is what you get with no options.'
  YcSay '  -Status                what a previous run did to this machine'
  YcSay '  -AcronisToken <tok>    Acronis registration token. NEEDS -AcronisRegion.'
  YcSay '  -AcronisRegion AE|SG   AE = UAE, SG = Singapore'
  YcSay '  -SkipAcronis           never touch Acronis, and do not ask'
  YcSay '  -SkipGlpi              never touch the GLPI agent, even with a password set'
  YcSay '  -SkipWsus              keep Windows Update on its current source'
  YcSay '  -SkipSalt              do not join the Salt master'
  YcSay '  -SaltMaster <host>     override the master. Default is derived from the IP.'
  YcSay '  -GrowDisk              actually extend partitions. Default: detect, report.'
  YcSay '  -AllowReboot           let it reboot at the END if something needs one'
  YcSay '  -Force                 proceed past a gate finding. It records what it did.'
  YcSay '  -Skip <phases>         skip these phases, comma separated'
  YcSay '  -Only <phases>         run only these phases'
  YcSay '  -QemuGaMsi <path|url>  the QEMU guest agent MSI. Not in the payload.'
  YcSay '  -Help                  this page'
  Write-Host ''
  YcSay 'EXIT CODES' 'White'
  YcSay '  0   ADOPTED         finished. Nothing left to do.'
  YcSay '  1   REBOOT NEEDED   not finished. Reboot, then paste the line again.'
  YcSay '  2   REFUSED         a gate said no, or your options were wrong'
  YcSay '  3   ITEMS FLAGGED   finished, but things are waiting on a human'
  YcSay '  4   BAD PAYLOAD     the zip failed its SHA256. Nothing installed.'
  YcSay '  5   NOT ELEVATED    nothing was changed at all'
  YcSay '  6   NO EGRESS       no HTTPS to raw.githubusercontent.com'
  YcSay '  7   OLD OS          this Windows cannot speak TLS 1.2'
  Write-Host ''
  YcSay 'WHERE THE EVIDENCE GOES' 'White'
  YcSay ('  ' + $LogRef)
  YcSay '  The screen is the answer, that log is the record for L2. Neither replaces'
  YcSay '  the other, so send the screen AND say where the log is.'
  Write-Host ''
  YcSay 'WHO IS TOLD, AND WHERE THE RESULTS ARE KEPT' 'White'
  YcSay '  Every step and the verdict go to the ERP webhook, the Tech Dept webhook'
  YcSay '  and ntfy (topic 9890122212 unless NTFY_TOPIC says otherwise). A webhook'
  YcSay '  is only used when its secret is set. Set them in PowerShell on the line'
  YcSay '  BEFORE the paste line - never as an option, so they stay out of the'
  YcSay '  history and the log. The values are in the vault, not in this help:'
  YcSay '    $env:ERP_WEBHOOK_SECRET   = ''<value>'''
  YcSay '    $env:EXTRA_WEBHOOK_URL    = ''<value>'''
  YcSay '    $env:EXTRA_WEBHOOK_SECRET = ''<value>'''
  YcSay '    $env:NTFY_TOKEN           = ''<value>''   (our ntfy n.oasisstack.io)'
  YcSay '    $env:NTFY_TOPIC           = ''off''     (optional: no phone push)'
  YcSay '    $env:GLPI_AGENT_PASSWORD  = ''<value>''   (optional: GLPI phase)'
  YcSay '  Every result line is tagged  [YALLACLOUD][YC-MILESTONE][YC-OK]  - or'
  YcSay '  YC-FAILED / YC-WAITING. Search for YC-FAILED to see what went wrong.'
  YcSay '  The adopt keeps them on the VM (SYSTEM and Administrators only), so every'
  YcSay '  later command reports too. Every result on the VM, from every command:'
  YcSay '    C:\ProgramData\YallaCloud\logs\yc-milestones.log'
  Write-Host ''
  YcSay 'BEFORE THE MIGRATION' 'White'
  YcSay '  The other half of this pair runs on the SOURCE VM, before the window, and'
  YcSay '  is read-only:'
  YcSay '    powershell.exe -nop -ep bypass -c "iex (New-Object Net.WebClient).DownloadString(''https://raw.githubusercontent.com/yallacloud/yc-scripts/main/check.ps1'')"'
  Write-Host ''
  YcRule
  Write-Host ''
}

# --- capability -----------------------------------------------------------------------------
function YcTlsAvailable {
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
# Two files, not the whole zip: Update-YcScripts.ps1 is the only thing allowed to write C:\Scripts
# wholesale, and it runs from inside the handover below. The .NET path needs 4.5; the Shell path
# is what Server 2008 R2 with .NET 3.5 actually has, and it is asynchronous, so it is waited for
# rather than trusted.
function YcExtractNamed {
  param([string]$Zip,[string]$Dest,[string[]]$Names)
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
      foreach ($n in $Names) {
        $e = $z.Entries | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        if (-not $e) { throw ($n + ' is not inside the payload zip') }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $Dest $n), $true)
      }
    } finally { $z.Dispose() }
    return 'dotnet'
  } catch [Exception] {
    if ($_.Exception.Message -like '*not inside the payload*') { throw }
  }
  $sh  = New-Object -ComObject Shell.Application
  $src = $sh.NameSpace($Zip)
  $dst = $sh.NameSpace($Dest)
  if (-not $src -or -not $dst) { throw 'Windows could not open the zip (Shell.Application returned nothing)' }
  foreach ($n in $Names) {
    $item = $src.Items() | Where-Object { $_.Name -eq $n } | Select-Object -First 1
    if (-not $item) { throw ($n + ' is not inside the payload zip') }
    $dst.CopyHere($item, 20)   # 4 = no progress window, 16 = yes to all
    $target = Join-Path $Dest $n
    for ($i = 0; $i -lt 120; $i++) {
      if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -gt 0) { break }
      Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path -LiteralPath $target)) { throw ('the copy of ' + $n + ' out of the zip did not finish in 60 seconds') }
  }
  return 'shell'
}

# Only ask a question when there is somebody there to answer it. An automation that blocks on a
# prompt looks exactly like a hang, and nobody is watching to break it out.
function YcInteractive {
  try {
    if (-not [Environment]::UserInteractive) { return $false }
    if (-not $Host.UI -or -not $Host.UI.RawUI) { return $false }
    return $true
  } catch { return $false }
}

# --- run ------------------------------------------------------------------------------------
$raw = $env:YC_ARGS
if (-not $raw) { $raw = $env:YC_ADOPT_ARGS }   # the older name, still honoured
$parsed = YcParseArgs $raw

if (@($parsed.args) -contains '-Help' -or $raw -match '(^|\s)[-/](\?|h|help)(\s|$)') { YcHelp; return 0 }

Write-Host ''
YcRule
Write-Host '  YALLACLOUD  ADOPT A MIGRATED VM            day-2 parity for a moved VM' -ForegroundColor Green
$hostName = $env:COMPUTERNAME
$stamp    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
Write-Host ('  host ' + $hostName.PadRight(21) + $stamp.PadRight(25) + 'run this ONCE per VM') -ForegroundColor DarkGray
YcRule
Write-Host ''

if (@($parsed.problems).Count) {
  foreach ($p in $parsed.problems) { YcSay ('INPUT: ' + $p) 'Yellow' }
  Write-Host ''
}
if (-not $parsed.ok) {
  YcFail 1 'read the options you gave'
  YcVerdict 'YOUR OPTIONS WERE NOT UNDERSTOOD' 2 'Red' @{
    'WHY' = 'the problems listed above are in $env:YC_ARGS. Nothing was downloaded and nothing on this machine was touched.'
    'FIX' = @('clear it and run the plain line, which adopts the VM with the defaults:',
              '  Remove-Item Env:\YC_ARGS -ErrorAction SilentlyContinue',
              'or see every option with a worked example for each:',
              '  set YC_ARGS=-Help   (cmd)   or   $env:YC_ARGS=''-Help''   (PowerShell)')
  } 1
  return 2
}
YcOk 1 'read the options you gave'
if (@($parsed.shown).Count) { YcNote ('passing through: ' + ($parsed.shown -join ' ')) }

$admin = $false
try {
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}
if (-not $admin) {
  YcFail 2 'running as Administrator'
  # Not a relaunch: this script arrived through a pipe, so it has no path on disk to re-run, and a
  # UAC relaunch of a pasted string is worse than telling somebody plainly what to do.
  YcVerdict 'NOT ELEVATED - NOTHING WAS CHANGED' 5 'Red' @{
    'WHY' = 'every phase of the adoption writes to places only an administrator can write to.'
    'FIX' = @('close this window. Right-click PowerShell -> Run as administrator, then paste:', '', '  ' + $Line)
  } 2
  return 5
}
YcOk 2 'running as Administrator'

$osCaption = 'unknown Windows'
try { $osCaption = (Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).Caption.Trim() } catch {}
$psv = $PSVersionTable.PSVersion.ToString()
$net = YcDotNetLabel

if (-not (YcTlsAvailable)) {
  YcFail 3 'this Windows can reach GitHub over TLS 1.2'
  YcNote ($osCaption + ' | PowerShell ' + $psv + ' | .NET ' + $net)
  YcVerdict 'THIS OS CANNOT DO TLS 1.2' 7 'Red' @{
    'WHY'           = @(($osCaption + ' with .NET ' + $net + '.'),
                        'GitHub requires TLS 1.2 and .NET 3.5 cannot speak it. This is the operating',
                        'system, not the network and not the link. Nothing was changed.')
    'FIX'           = 'install .NET Framework 4.8 on this VM, then paste the same line again.'
    'OFFLINE ROUTE' = @('on ANY machine with internet download',
                        '  ' + $ZipUrl,
                        'copy it onto this VM, unzip it to C:\Scripts, and run:',
                        '  powershell.exe -nop -ep bypass -File C:\Scripts\Adopt-MigratedVm.ps1 -Run')
  } 3
  return 7
}
YcEnableTls
YcOk 3 'this Windows can reach GitHub over TLS 1.2'
YcNote ($osCaption + ' | PowerShell ' + $psv + ' | .NET ' + $net)

if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

$ProgressPreference = 'SilentlyContinue'   # the progress bar costs ~0.8s per MB and shows nobody anything
$tmp = Join-Path $env:TEMP ('yc-adopt-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'payload.zip'
try {
  $wc = New-Object Net.WebClient
  $wc.DownloadFile($ZipUrl, $zip)
  $sidecar = $wc.DownloadString($ShaUrl)
  $kb = [int]((Get-Item -LiteralPath $zip).Length / 1024)
  YcOk 4 ('download the payload (' + $kb + ' KB)')
} catch {
  YcFail 4 'download the payload'
  $msg = $_.Exception.Message
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  YcVerdict 'NO HTTPS TO GITHUB FROM THIS VM' 6 'Red' @{
    'WHY'           = @($msg, 'This VM needs outbound HTTPS to raw.githubusercontent.com:443. Nothing was changed.')
    'FIX'           = @('check egress and any proxy, then paste the line again:', '  netsh winhttp show proxy')
    'OFFLINE ROUTE' = @('on any machine with internet download',
                        '  ' + $ZipUrl,
                        'copy it onto this VM, unzip it to C:\Scripts, and run:',
                        '  powershell.exe -nop -ep bypass -File C:\Scripts\Adopt-MigratedVm.ps1 -Run')
  } 4
  return 6
}

$want = ([string]$sidecar -split '\s+')[0].Trim().ToUpper()
$got  = YcSha256File $zip
if (-not $want -or $want -ne $got) {
  YcFail 5 'verify SHA256 and unpack'
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  YcVerdict 'PAYLOAD FAILED ITS SHA256 - NOTHING WAS INSTALLED' 4 'Red' @{
    'WHY' = @('the zip does not match its published hash, so it was not opened.',
              ('expected ' + $want), ('got      ' + $got))
    'FIX' = 'if a payload was pushed in the last 5 minutes this is the GitHub CDN cache. Wait five minutes and paste the line again. If it fails twice, stop and tell L2 - a persistent mismatch is not a retry problem.'
  } 5
  return 4
}
try {
  $how = YcExtractNamed $zip $Dir $Need
} catch {
  YcFail 5 'verify SHA256 and unpack'
  $msg = $_.Exception.Message
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  YcVerdict 'COULD NOT UNPACK THE PAYLOAD' 4 'Red' @{
    'WHY' = @($msg, 'The download was verified, so this is the unzip, not the file. Nothing was installed.')
    'FIX' = @('unzip it by hand into C:\Scripts and run:',
              '  ' + $ZipUrl,
              '  powershell.exe -nop -ep bypass -File C:\Scripts\Adopt-MigratedVm.ps1 -Run')
  } 5
  return 4
}
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
YcOk 5 'verify SHA256 and unpack'
YcNote ('sha256 ' + $got.Substring(0,32) + '...   unzipped with the ' + $how + ' path')

# --- step 6: the one decision that needs an answer ------------------------------------------
$passthru = @($parsed.args)
$acronisDecided = ($passthru -contains '-AcronisToken') -or ($passthru -contains '-SkipAcronis')
$looking = ($passthru -contains '-Report') -or ($passthru -contains '-Status')

if ($looking) {
  YcSkip 6 'confirm what will be installed'
  YcNote 'nothing will be changed on this run, so there is nothing to confirm'
} elseif ($acronisDecided) {
  YcOk 6 'confirm what will be installed'
  if ($passthru -contains '-SkipAcronis') { YcNote 'Acronis: skipped, you asked for that' }
  else { YcNote 'Acronis: will be installed and registered' }
} elseif (-not (YcInteractive)) {
  YcSkip 6 'confirm what will be installed'
  YcNote 'no interactive console, so nothing was asked. Acronis is skipped - pass'
  YcNote '-AcronisToken and -AcronisRegion in $env:YC_ARGS if this customer bought backup.'
} else {
  # Asked rather than typed into the line: a token pasted at a prompt cannot be mangled by a
  # shell, cannot land in the command history, and cannot be half-quoted.
  Write-Host ''
  YcSay 'Does this customer have Acronis backup?  [y/N]  ' 'Cyan'
  $ans = ''
  try { $ans = (Read-Host '          y or n').Trim().ToLowerInvariant() } catch { $ans = '' }
  if ($ans -eq 'y' -or $ans -eq 'yes') {
    for ($try = 1; $try -le 3; $try++) {
      $tok = ''
      try { $tok = (Read-Host '          paste the Acronis registration token').Trim() } catch {}
      $tok = YcAsciiFold $tok
      if ($tok.Length -lt 8) { YcSay 'that is too short to be a token. Try again, or press Enter to skip Acronis.' 'Yellow'
                               if (-not $tok) { break } else { continue } }
      $reg = ''
      try { $reg = (Read-Host '          region - type AE for UAE or SG for Singapore').Trim().ToUpperInvariant() } catch {}
      if ($reg -ne 'AE' -and $reg -ne 'SG') { YcSay 'region has to be AE or SG. Starting that question again.' 'Yellow'; continue }
      $passthru += @('-AcronisToken', $tok, '-AcronisRegion', $reg)
      YcOk 6 'confirm what will be installed'
      YcNote ('Acronis: will be installed, region ' + $reg + ', token <' + $tok.Length + ' characters, not shown>')
      break
    }
    if (-not ($passthru -contains '-AcronisToken')) {
      YcOk 6 'confirm what will be installed'
      YcNote 'Acronis: skipped - no usable token was given'
    }
  } else {
    YcOk 6 'confirm what will be installed'
    YcNote 'Acronis: skipped. That is a normal outcome - backup is sold per customer.'
  }
}

# --- step 7: hand over -----------------------------------------------------------------------
# Everything else - survey, prerequisites, the full payload sync, PATH, SQL, backups, Salt,
# Acronis, tasks, the marker and the verify - belongs to migrated-vm, which already knows how.
if (-not ($passthru | Where-Object { '-Report -Run -Status' -contains $_ })) { $passthru += '-Run' }

YcRun 7 'hand over to migrated-vm'
Write-Host ''
YcThin
Write-Host '  migrated-vm''s own output follows. Its verdict box is the real answer; this screen' -ForegroundColor DarkGray
Write-Host '  repeats the one thing to do next at the very bottom.' -ForegroundColor DarkGray
YcThin
Write-Host ''

$code = 0
try {
  # NOT  & $script @passthru  - splatting an array binds POSITIONALLY, so '-Report' landed in the
  # first positional parameter instead of being read as a switch. -File gets normal command-line
  # parsing, and it is how Adopt-MigratedVm.ps1 invokes the other payload commands too.
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Dir 'Adopt-MigratedVm.ps1')) + $passthru
  $proc = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                        -ArgumentList $argList -Wait -PassThru -NoNewWindow
  $code = $proc.ExitCode
} catch {
  YcVerdict 'MIGRATED-VM DID NOT START' 3 'Red' @{
    'WHY' = $_.Exception.Message
    'FIX' = 'the payload verified, so this is the adopt script and not the download. Send this screen to L2.'
  } 7
  return 3
}

$changed = (-not $looking)
switch ($code) {
  0 { if ($changed) {
        YcVerdict 'ADOPTED' 0 'Green' @{
          'WHAT IT MEANS' = 'this VM is now managed by the YallaCloud scripts, the same as one we deployed.'
          'NEXT STEP'     = @('nothing. Type  yallacloud  for everything this box can now do, or',
                              '  migrated-vm -Status   to see what this run did.')
          'EVIDENCE'      = $LogRef }
      } else {
        YcVerdict 'LOOKED ONLY - NOTHING WAS CHANGED' 0 'Green' @{
          'WHAT IT MEANS' = 'the survey above is what it WOULD do. No file, task or setting was touched.'
          'NEXT STEP'     = @('to adopt it for real, clear the option and paste the line again:',
                              '  Remove-Item Env:\YC_ARGS -ErrorAction SilentlyContinue')
          'EVIDENCE'      = $LogRef }
      } }
  1 { YcVerdict 'REBOOT REQUIRED - THE ADOPTION IS NOT FINISHED' 1 'Yellow' @{
        'WHAT IT MEANS' = 'a Windows update is half applied on this VM. The later phases are not reliable until it finishes, so the run stopped on purpose.'
        'NEXT STEP'     = @('reboot this VM, then paste the SAME line again. It carries on from here.',
                            '  Restart-Computer -Force')
        'EVIDENCE'      = $LogRef } }
  2 { YcVerdict 'REFUSED - A GATE SAID NO' 2 'Red' @{
        'WHAT IT MEANS' = 'something about this machine makes the adoption unsafe. The reason is named in the output above - it is not a generic failure.'
        'NEXT STEP'     = 'read the gate finding above. Fix it, or send this screen to L2. Only use -Force if L2 tells you to, and it records what it overrode.'
        'EVIDENCE'      = $LogRef } }
  3 { YcVerdict 'DONE, WITH ITEMS FOR A HUMAN' 3 'Yellow' @{
        'WHAT IT MEANS' = 'the adoption finished, but some things it will not decide by itself are flagged above - SQL, licensing and anything it could not identify.'
        'NEXT STEP'     = 'send this screen to L2 so the flagged items get owned.'
        'EVIDENCE'      = $LogRef } }
  5 { YcVerdict 'NOT ELEVATED' 5 'Red' @{
        'FIX'      = @('right-click PowerShell -> Run as administrator, then paste:', '  ' + $Line)
        'EVIDENCE' = $LogRef } }
  default { YcVerdict ('MIGRATED-VM EXITED ' + $code) $code 'Yellow' @{
        'WHAT IT MEANS' = 'this is not one of its documented outcomes.'
        'NEXT STEP'     = 'send this screen and the log below to L2.'
        'EVIDENCE'      = $LogRef } }
}
return $code

}  # end Invoke-YcAdoptOnRamp

$code = 0
try   { $code = Invoke-YcAdoptOnRamp }
catch { Write-Host ('  the on-ramp itself failed: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host '  Send this line to L2. Nothing was installed by the on-ramp itself.' -ForegroundColor Yellow
        $code = 9 }
# Carried for anything that checks it, WITHOUT ending the operator's session.
$global:LASTEXITCODE = $code
