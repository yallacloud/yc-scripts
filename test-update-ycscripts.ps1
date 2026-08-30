#Requires -Version 5.1
# test-update-ycscripts.ps1 - self-check for the pieces of Update-YcScripts.ps1
# that can be exercised without touching C:\Scripts. Run it before publishing.
#   powershell -ExecutionPolicy Bypass -File .\test-update-ycscripts.ps1
# Exit 0 = PASS, 1 = FAIL.

$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$what,$got,$want){
  if("$got" -eq "$want"){ Write-Host ("[OK]   " + $what) -ForegroundColor Green }
  else{ Write-Host ("[FAIL] " + $what + "`n       got:  " + $got + "`n       want: " + $want) -ForegroundColor Red; $script:fail++ }
}

# The regex Update-YcScripts uses to derive a git remote from a raw URL. Keep in sync.
$RawRx = '^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$'

$live = 'https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip'
$m = [regex]::Match($live, $RawRx)
Check 'live payload URL parses'      $m.Success              'True'
Check '  owner'                      $m.Groups[1].Value      'yallacloud'
Check '  repo'                       $m.Groups[2].Value      'yc-scripts'
Check '  branch'                     $m.Groups[3].Value      'main'
Check '  path'                       $m.Groups[4].Value      'YallaCloud-CScripts-latest.zip'
Check '  derived remote'             ('https://github.com/' + $m.Groups[1].Value + '/' + $m.Groups[2].Value + '.git') `
                                     'https://github.com/yallacloud/yc-scripts.git'

$sc = [regex]::Match('https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256', $RawRx)
Check 'sidecar URL parses'           $sc.Success             'True'
Check '  sidecar path'               $sc.Groups[4].Value     'YallaCloud-CScripts-latest.sha256'

# A nested path must keep its slashes, and they must become backslashes on disk.
$nested = [regex]::Match('https://raw.githubusercontent.com/o/r/main/a/b/c.zip', $RawRx)
Check 'nested path kept whole'       $nested.Groups[4].Value 'a/b/c.zip'
Check '  as a windows relative path' ($nested.Groups[4].Value -replace '/','\') 'a\b\c.zip'

# Anything that is not a raw.githubusercontent.com URL must NOT produce a remote -
# the fallback has to decline, not guess.
foreach($u in @('https://github.com/yallacloud/yc-scripts/raw/main/x.zip',
                'https://dist.example.com/yc/YallaCloud-CScripts-latest.zip',
                'http://raw.githubusercontent.com/o/r/main/x.zip',
                'https://raw.githubusercontent.com/o/r/main')){
  Check ('declines: ' + $u) ([regex]::Match($u, $RawRx).Success) 'False'
}

# The sidecar parser must find a hash anywhere in "<sha>  <filename>".
$sha = '22B8F00B53AF207B9AAE36C472D2C9C9391BC0159FF1B028FC8CBD242764F3A7'
Check 'sha found in sidecar text' ([regex]::Match(($sha + '  YallaCloud-CScripts-latest.zip'), '([0-9a-fA-F]{64})').Groups[1].Value) $sha
Check 'no sha in a 404 page'      ([regex]::Match('404: Not Found', '([0-9a-fA-F]{64})').Success) 'False'

if($fail -gt 0){ Write-Host ("RESULT: FAIL - " + $fail + " check(s) failed.") -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: PASS' -ForegroundColor Green
exit 0
