# yc-folders.ps1 - READ ONLY. Audit every sub-folder of C:\Scripts: what is there,
# what should be there, what should NOT be there. Reports gaps only at the end.
$ErrorActionPreference = 'SilentlyContinue'
$S = 'C:\Scripts'
$gaps = New-Object System.Collections.ArrayList
function Gap($t) { [void]$gaps.Add($t) }

"==== C:\Scripts sub-folders  $env:COMPUTERNAME  $(Get-Date -f 'yyyy-MM-dd HH:mm') ===="
$dirs = Get-ChildItem $S -Directory -Force | Sort-Object Name
foreach ($d in $dirs) {
  $f = @(Get-ChildItem $d.FullName -Recurse -File -Force)
  $mb = ($f | Measure-Object Length -Sum).Sum / 1MB
  '{0,-18} {1,5} files  {2,9:N1} MB   {3}' -f $d.Name, $f.Count, $mb, $(if ($d.Attributes -band [IO.FileAttributes]::Hidden) { '(hidden)' })
}
$root = @(Get-ChildItem $S -File -Force)
'{0,-18} {1,5} files  {2,9:N1} MB   (root)' -f '<root>', $root.Count, (($root | Measure-Object Length -Sum).Sum / 1MB)

# ---- folders that MUST be gone ------------------------------------------------
foreach ($d in '_stage','.done','.chocolatey','lib','lib-bad','helpers','redirects',
                'extensions','tools','config','logs','bin','KVM-Tooling','Host-Recovery','Monitoring') {
  if (Test-Path (Join-Path $S $d)) { Gap "REMOVE  $d\  - should have been deleted by Clean-Scripts" }
}

# ---- Day2 ---------------------------------------------------------------------
''
'--- Day2 ---'
Get-ChildItem "$S\Day2" -Force | ForEach-Object { '  {0,-34} {1,8} B' -f $_.Name, $_.Length }
foreach ($f in 'README.txt','SQL-Observability-Guide.md') {
  if (-not (Test-Path "$S\Day2\$f")) { Gap "MISSING Day2\$f" }
}
# the executables live at ROOT, not in Day2 - that is correct
foreach ($f in 'Day2-Setup.ps1','Setup-Observability.ps1') {
  if (-not (Test-Path "$S\$f")) { Gap "MISSING $f (root) - Day2 entry point" }
}
foreach ($f in 'Setup-HealthMonitors.ps1','A-Z-Deploy.ps1','Setup-YallaCloudExtras.ps1') {
  if (-not (Test-Path "$S\$f")) { Gap "MISSING $f (root) - not in final_scripts, see runbook 6.2" }
}

# ---- DiagTools ----------------------------------------------------------------
''
'--- DiagTools ---'
Get-ChildItem "$S\DiagTools" -Force | ForEach-Object {
  $n = if ($_.PSIsContainer) { @(Get-ChildItem $_.FullName -Recurse -File).Count } else { '' }
  '  {0,-30} {1}' -f $_.Name, $(if ($_.PSIsContainer) { "$n files" } else { '{0:N0} B' -f $_.Length })
}
foreach ($p in @{ 'testdisk_win.exe'='testdisk'; 'photorec_win.exe'='photorec';
                  'iperf3.exe'='iperf3'; 'smartmontools-setup.exe'='smartmontools' }.GetEnumerator()) {
  if (-not @(Get-ChildItem "$S\DiagTools" -Recurse -Filter $p.Key).Count) { Gap "MISSING DiagTools\$($p.Key)" }
}
foreach ($t in 'hayabusa','klogg') {
  if (-not (Test-Path "$S\DiagTools\$t")) { Gap "MISSING DiagTools\$t\ - Log Parser replacement (payload v263+)" }
}

# ---- Sysinternals -------------------------------------------------------------
''
'--- Sysinternals ---'
$si = @(Get-ChildItem "$S\Sysinternals" -File)
'  {0} files' -f $si.Count
if ($si.Count -lt 100) { Gap "Sysinternals only $($si.Count) files - expect ~164" }
foreach ($e in 'PsExec.exe','procexp.exe','Autoruns.exe','handle.exe','Sysmon64.exe') {
  if (-not (Test-Path "$S\Sysinternals\$e")) { Gap "MISSING Sysinternals\$e" }
}

# ---- virtio -------------------------------------------------------------------
''
'--- virtio ---'
$sys = @(Get-ChildItem "$S\virtio" -Recurse -Filter '*.sys'); $inf = @(Get-ChildItem "$S\virtio" -Recurse -Filter '*.inf')
$pdb = @(Get-ChildItem "$S\virtio" -Recurse -Filter '*.pdb')
'  {0} .sys   {1} .inf   {2} .pdb' -f $sys.Count, $inf.Count, $pdb.Count
if ($sys.Count -lt 10) { Gap "virtio only $($sys.Count) .sys files" }
if ($pdb.Count -gt 0)  { Gap "virtio has $($pdb.Count) .pdb debug symbols (~53 MB) - Clean-Scripts should strip these" }
$vs = Get-ChildItem "$S\virtio" -Recurse -Filter 'viostor.sys' | Select-Object -First 1
if ($vs) { $v = $vs.VersionInfo.FileVersion; "  viostor.sys $v"
           if ($v -notmatch '^100\.100\.104\.271') { Gap "virtio is $v - must be 100.100.104.271xx (0.1.271)" } }

# ---- sql-templates ------------------------------------------------------------
''
'--- sql-templates ---'
$tp = @(Get-ChildItem "$S\sql-templates" -File)
$tp | ForEach-Object { '  {0}' -f $_.Name }
if ($tp.Count -ne 5) { Gap "sql-templates has $($tp.Count) files, expect 5" }
foreach ($y in 2016,2017,2019,2022,2025) {
  if (-not (Test-Path "$S\sql-templates\ConfigurationFile-$y.ini.tmpl")) { Gap "MISSING sql-templates\ConfigurationFile-$y.ini.tmpl" }
}

# ---- anything unexpected ------------------------------------------------------
$known = 'Day2','DiagTools','Sysinternals','virtio','sql-templates','Health','Observability','Sysmon'
foreach ($d in $dirs) { if ($known -notcontains $d.Name) { Gap "UNEXPECTED folder $($d.Name)\ - not in the keep list" } }

''
if ($gaps.Count) { '---- GAPS ({0}) ----' -f $gaps.Count; $gaps | ForEach-Object { '  ' + $_ } }
else { '---- no gaps ----' }
