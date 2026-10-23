# The chkdsk decision is what turns into a BLOCKER on a customer's production VM, so the phrase
# matching gets tested against the real strings chkdsk prints - including the one that already
# caused a false BAD once: "found NO problems" contains the word "problems".
$samples = @(
  @{ name='clean /scan';            clean=$true;  txt="The type of the file system is NTFS.`nStage 1: Examining basic file system structure ...`nWindows has scanned the file system and found no problems.`nNo further action is required.`n`n  1048575 MB total disk space." },
  @{ name='clean, short form';      clean=$true;  txt="Windows has scanned the file system and found no problems." },
  @{ name='clean, offline wording'; clean=$true;  txt="Windows has checked the file system and found no problems.`nNo further action is required." },
  @{ name='problems found';         clean=$false; txt="Stage 1: Examining basic file system structure ...`nWindows has scanned the file system and found problems.`nRun chkdsk with the /f (fix) option to correct these." },
  @{ name='corrections made';       clean=$false; txt="Windows has made corrections to the file system.`nNo further action is required." },
  @{ name='errors found';           clean=$false; txt="Errors found. CHKDSK cannot continue in read-only mode." },
  @{ name='needs offline';          clean=$false; txt="The volume needs to be taken offline to perform a Full Chkdsk." },
  @{ name='unrecognised';           clean=$null;  txt="Access Denied as you do not have sufficient privileges." }
)
$fail = 0
foreach ($s in $samples) {
  $txt = $s.txt
  $got = $null; $why = ''
  # EXACTLY the logic in Test-MigrationReadiness.ps1
  if ($txt -match '(?i)made corrections|found problems|Errors found|corruption was found|needs to be taken offline|Run chkdsk with the /f') { $got = $false; $why = [string]$Matches[0] }
  elseif ($txt -match '(?i)found no problems|no further action is required') { $got = $true;  $why = 'Windows reported no problems' }
  else { $got = $null; $why = 'unrecognised' }
  $ok = ("$got" -eq "$($s.clean)")
  if ($ok) { Write-Host ("  PASS  {0,-22} -> clean={1,-5}  ({2})" -f $s.name, "$got", $why) -ForegroundColor Green }
  else { Write-Host ("  FAIL  {0,-22} -> clean={1} expected {2}  ({3})" -f $s.name, "$got", "$($s.clean)", $why) -ForegroundColor Red; $fail++ }
}
Write-Host ''
# The verdict ladder: blockers outrank risks, and no findings is GO.
foreach ($c in @(@{b=0;r=0;want='GO';code=0}, @{b=0;r=3;want='GO WITH RISK';code=1},
                 @{b=1;r=0;want='DO NOT MIGRATE';code=2}, @{b=2;r=5;want='DO NOT MIGRATE';code=2})) {
  $v='GO'; $x=0
  if ($c.b) { $v='DO NOT MIGRATE'; $x=2 } elseif ($c.r) { $v='GO WITH RISK'; $x=1 }
  if ($v -eq $c.want -and $x -eq $c.code) { Write-Host ("  PASS  {0} blocker(s), {1} risk(s) -> {2} (exit {3})" -f $c.b,$c.r,$v,$x) -ForegroundColor Green }
  else { Write-Host ("  FAIL  {0}/{1} -> {2}" -f $c.b,$c.r,$v) -ForegroundColor Red; $fail++ }
}
Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green } else { Write-Host ([string]$fail + ' FAILED') -ForegroundColor Red }
