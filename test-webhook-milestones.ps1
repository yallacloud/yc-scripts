# test-webhook-milestones.ps1 - proves the WEBHOOK MILESTONES block (payload 2.45.0) without a VM.
#   pwsh -File test-webhook-milestones.ps1 -PayloadDir <extracted payload>
# Checks: the adopt script and the pre-migration check carry a VERBATIM copy of the library block;
# settings precedence, defaults and URL checks; the body is exactly the agreed flat schema with no
# secret in it; areas, states, keywords, ntfy text; the adopt and pre-migration mappings; the
# library hooks (Start-YcLog / Stop-YcLog / Exit-Yc / Write-YcLog); and a real POST to a local
# listener (headers and body as the receiver sees them). Must end with '0 failed'.
param([string]$PayloadDir = 'C:\Scripts')
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function T([string]$Name, [bool]$Ok, [string]$Got = '') {
  if ($Ok) { $script:pass++; Write-Host ('  ok   ' + $Name) }
  else { $script:fail++; Write-Host ('  FAIL ' + $Name + $(if ($Got) { '   got: ' + $Got } else { '' })) -ForegroundColor Red }
}

$lib   = [IO.File]::ReadAllText((Join-Path $PayloadDir '_yc-lib.ps1')) -replace "`r`n", "`n"
$adopt = [IO.File]::ReadAllText((Join-Path $PayloadDir 'Adopt-MigratedVm.ps1')) -replace "`r`n", "`n"
$prem  = [IO.File]::ReadAllText((Join-Path $PayloadDir 'Test-MigrationReadiness.ps1')) -replace "`r`n", "`n"
$mark  = "# ------------------------------------------------------------------------------------`n# WEBHOOK MILESTONES"
$i = $lib.IndexOf($mark)
T 'library has the WEBHOOK MILESTONES block' ($i -ge 0)
$block = $lib.Substring($i).TrimEnd("`n")
foreach ($pair in @(@('Adopt-MigratedVm.ps1', $adopt), @('Test-MigrationReadiness.ps1', $prem))) {
  $t = $pair[1]; $a = $t.IndexOf($mark); $z = $t.IndexOf('# --- end of the copied block')
  $copy = $(if ($a -ge 0 -and $z -gt $a) { $t.Substring($a, $z - $a).TrimEnd("`n") } else { '' })
  T ($pair[0] + ' carries a verbatim copy of the library block') ($copy -eq $block) $(if ($copy) { 'differs' } else { 'missing' })
}
. ([scriptblock]::Create($block))

# --- settings ---------------------------------------------------------------------------------
$none = @{}
$c = Resolve-YcMsConfig -Vars $none -Env $none -Json $null
T 'no settings: ERP url is the public default'      ($c.erpUrl -eq 'https://api.yallacloud.net/api/v1/webhooks/cloudstack')
T 'no settings: no ERP secret, no extra webhook'    (-not $c.erpSecret -and -not $c.extraUrl -and -not $c.extraSecret)
T 'no settings, no token: ntfy is public ntfy.sh, topic 9890122212' ($c.ntfyUrl -eq 'https://ntfy.sh/9890122212')
$c = Resolve-YcMsConfig -Vars $none -Env @{ NTFY_TOKEN = 'tkA' } -Json $null
T 'a token moves ntfy to our own server n.oasisstack.io' ($c.ntfyUrl -eq 'https://n.oasisstack.io/9890122212' -and $c.ntfyToken -eq 'tkA') $c.ntfyUrl
$c = Resolve-YcMsConfig -Vars @{ NtfyToken = 'tkB' } -Env @{ NTFY_SERVER = 'https://ntfy.example'; NTFY_TOPIC = 'yc-x' } -Json $null
T 'NTFY_SERVER still wins over the token default'       ($c.ntfyUrl -eq 'https://ntfy.example/yc-x' -and $c.ntfyToken -eq 'tkB')
$c = Resolve-YcMsConfig -Vars $none -Env $none -Json ([pscustomobject]@{ ntfyToken = 'tkJ' })
T 'yc-event.json ntfyToken is used'                     ($c.ntfyToken -eq 'tkJ' -and $c.ntfyUrl -eq 'https://n.oasisstack.io/9890122212')
$j = [pscustomobject]@{ url = 'https://json.example/erp'; secret = 'JSEC1'; extraUrl = 'https://json.example/x'; extraSecret = 'JSONX1'; ntfy = 'https://ntfy.example/t1' }
$c = Resolve-YcMsConfig -Vars $none -Env $none -Json $j
T 'yc-event.json is used when nothing else is set'  ($c.erpUrl -eq 'https://json.example/erp' -and $c.erpSecret -eq 'JSEC1' -and $c.extraUrl -eq 'https://json.example/x' -and $c.ntfyUrl -eq 'https://ntfy.example/t1')
$c = Resolve-YcMsConfig -Vars $none -Env @{ ERP_WEBHOOK_SECRET = 'ENVSEC'; EXTRA_WEBHOOK_URL = 'https://env.example/x'; NTFY_TOPIC = 'abc_1' } -Json $j
T 'environment beats yc-event.json'                 ($c.erpSecret -eq 'ENVSEC' -and $c.extraUrl -eq 'https://env.example/x' -and $c.extraSecret -eq 'JSONX1')
T 'NTFY_TOPIC beats the json ntfy url'               ($c.ntfyUrl -eq 'https://ntfy.sh/abc_1')
$c = Resolve-YcMsConfig -Vars @{ ErpWebhookSecret = 'VARSEC'; NtfyTopic = 'off' } -Env @{ ERP_WEBHOOK_SECRET = 'ENVSEC' } -Json $j
T 'script variables beat the environment'            ($c.erpSecret -eq 'VARSEC')
T 'NTFY_TOPIC=off turns ntfy off'                     (-not $c.ntfyUrl)
$c = Resolve-YcMsConfig -Vars $none -Env @{ EXTRA_WEBHOOK_URL = 'http://plain.example/x'; NTFY_TOPIC = 'bad topic!' } -Json $null
T 'a non-https webhook url is refused'               (-not $c.extraUrl)
T 'an invalid ntfy topic turns ntfy off'             (-not $c.ntfyUrl)

# --- error text -------------------------------------------------------------------------------
$e = ConvertTo-YcMsError -Text "line1`nline2   password=Hunter2 token: abc secret='x y' TOPSECRETVAL" -Secrets @('TOPSECRETVAL')
T 'error: one line'                                  ($e -notmatch "`n")
T 'error: key=value secrets redacted'                 ($e -match 'password=REDACTED' -and $e -match 'token: REDACTED' -and $e -notmatch 'Hunter2' -and $e -notmatch 'abc ')
T 'error: a known secret value redacted anywhere'     ($e -notmatch 'TOPSECRETVAL')
T 'error: at most 300 characters'                     ((ConvertTo-YcMsError -Text ('x' * 900) -Secrets @()).Length -le 300)

# --- body -------------------------------------------------------------------------------------
$id = @{ vmId = '11111111-2222-3333-4444-555555555555'; hostname = 'WEB01'; ip = '93.177.125.10'; os = 'Windows Server 2022 Standard' }
$b = New-YcMsBody -Area 'Acronis' -State 'FAILED' -Err 'exit 4' -Tag 'acronis-register payload 2.45.0' -Id $id -UtcNow ([datetime]::SpecifyKind([datetime]'2026-10-28T06:15:02', 'Utc'))
T 'body: the event head, then the agreed 8 keys, in order' ((@($b.Keys) -join ',') -eq 'deploymentId,event,stage,status,seq,time,vm,kit,kitVersion,detail,progress,type,vmId,hostname,ip,os,error,lastUpdated,extra') (@($b.Keys) -join ',')
T 'body: head - no portal = deploymentId -, status failed, stage acronis' ($b.deploymentId -eq '-' -and $b.status -eq 'failed' -and $b.stage -eq 'acronis' -and $b.event -eq 'vm.acronis.failed')
$bd = New-YcMsBody -Area 'salt' -State 'joined' -Err '' -Tag 't' -Id $id -DeployId 'YCD-20261104-000042' -Seq 5 -Detail 'JOINED x' -KitVersion '2.47.7'
T 'body: head carries id, seq, detail, payload version' ($bd.deploymentId -eq 'YCD-20261104-000042' -and $bd.seq -eq 5 -and $bd.detail -eq 'JOINED x' -and $bd.kit -eq 'payload' -and $bd.kitVersion -eq '2.47.7' -and $bd.status -eq 'ok')
T 'body: vm name / uuid / ip'                           ($bd.vm.name -eq 'web01' -and $bd.vm.uuid -eq $id.vmId -and $bd.vm.ip -eq $id.ip)
T 'body: type is vm.<area>.<state>, lower case'       ($b.type -eq 'vm.acronis.failed')
T 'body: lastUpdated is Dubai time, +04'              ($b.lastUpdated -eq '2026-10-28 10:15:02 +04') $b.lastUpdated
T 'body: the eight old values are strings'           (@('type','vmId','hostname','ip','os','error','lastUpdated','extra' | Where-Object { $b[$_] -isnot [string] }).Count -eq 0)
T 'body: area/state cannot inject dots or spaces'     ((New-YcMsBody -Area 'a.b c' -State 'x.y' -Err '' -Tag '' -Id $id).type -eq 'vm.abc.xy')

# --- areas, states, keywords --------------------------------------------------------------------
T 'area: acronis-register -> acronis'                 ((Get-YcMsArea 'acronis-register') -eq 'acronis')
T 'area: set-local-wsus -> wsus'                      ((Get-YcMsArea 'set-local-wsus') -eq 'wsus')
T 'area: activate-windows -> license'                 ((Get-YcMsArea 'activate-windows') -eq 'license')
T 'area: unknown tag -> the tag itself'               ((Get-YcMsArea 'grow-disk') -eq 'grow-disk')
T 'area: never vm.deploy.* (that is the ERP build signal)' ((@('fix-deploy','deploy') | ForEach-Object { Get-YcMsArea $_ }) -notcontains 'deploy')
foreach ($t in 'yc-event','yc-compliance','report-inventory','adopt-migrated-vm','salt-join','diag') { T ('area: ' + $t + ' does not report') ((Get-YcMsArea $t) -eq '') }
T 'state: 0 ok, 3010 ok, 1 failed'                    ((Get-YcMsState -Area 'sql' -Code 0) -eq 'ok' -and (Get-YcMsState -Area 'sql' -Code 3010) -eq 'ok' -and (Get-YcMsState -Area 'sql' -Code 1) -eq 'failed')
T 'area: glpi-join -> glpi'                            ((Get-YcMsArea 'glpi-join') -eq 'glpi')
T 'state: glpi 0 registered, 8 waiting, 3 failed'      ((Get-YcMsState -Area 'glpi' -Code 0) -eq 'registered' -and (Get-YcMsState -Area 'glpi' -Code 8) -eq 'waiting' -and (Get-YcMsState -Area 'glpi' -Code 3) -eq 'failed')
T 'state: acronis 0 registered, 3 waitforhuman, 7 failed' ((Get-YcMsState -Area 'acronis' -Code 0) -eq 'registered' -and (Get-YcMsState -Area 'acronis' -Code 3) -eq 'waitforhuman' -and (Get-YcMsState -Area 'acronis' -Code 7) -eq 'failed')
T 'read-only: -Report / -Help / -SelfCheck are not reported' ((Test-YcMsReadOnly @('Report')) -and (Test-YcMsReadOnly @('Help')) -and (Test-YcMsReadOnly @('Force','SelfCheck')))
T 'read-only: an action run is reported'              (-not (Test-YcMsReadOnly @('Token','Region')))
T 'keyword: failed / waiting / ok'                    ((Get-YcMsKeyword 'failed') -eq 'YC-FAILED' -and (Get-YcMsKeyword 'waitforhuman') -eq 'YC-WAITING' -and (Get-YcMsKeyword 'joined') -eq 'YC-OK')
$ln = Format-YcMsLine -Body $b -Sent 'extra:202,erp:200,ntfy:200'
T 'journal line: fixed tags first'                    ($ln -like '2026-10-28 10:15:02 +04 `[YALLACLOUD`]`[YC-MILESTONE`]`[YC-FAILED`] type=vm.acronis.failed *') $ln
T 'journal line: key=value fields'                    ($ln -match ' area=acronis state=failed host=WEB01 vmId=11111111-' -and $ln -match ' by="acronis-register payload 2.45.0" error="exit 4" sent=extra:202,erp:200,ntfy:200$') $ln
T 'journal line: carries the deployment id and seq'   ($ln -match ' deployment=- seq=0 by=') $ln
T 'ntfy: only what a human must act on, unless always' ((Test-YcMsNtfy 'failed') -and (Test-YcMsNtfy 'waiting') -and -not (Test-YcMsNtfy 'ok') -and (Test-YcMsNtfy 'completed' 'always') -and -not (Test-YcMsNtfy 'failed' 'never'))
$n = New-YcMsNtfy -Body $b -Log 'C:\Scripts\acronis-register.log'
T 'ntfy: title says result, what, where and the deployment' ($n.title -eq 'FAILED: Acronis backup agent - WEB01 | -') $n.title
T 'ntfy: failed is priority 5'                        ($n.priority -eq '5')
T 'ntfy: deployment first, then labelled lines'       ($n.text -match '^deployment : -\nRESULT   FAILED - action needed' -and $n.text -match "`nWHAT     Acronis backup agent" -and $n.text -match "`nWHY      exit 4" -and $n.text -match "`nLOG      C:\\Scripts\\acronis-register.log")
T 'ntfy: ok is priority 3'                            ((New-YcMsNtfy -Body (New-YcMsBody -Area 'adopt' -State 'completed' -Err '' -Tag '' -Id $id)).priority -eq '3')

# --- 2.47.7: agents send one final status, only when it changed -----------------------------------
T 'agent areas: salt glpi acronis wsus'                ((Test-YcAgentArea 'salt') -and (Test-YcAgentArea 'glpi') -and (Test-YcAgentArea 'acronis') -and (Test-YcAgentArea 'wsus') -and -not (Test-YcAgentArea 'sql'))
T 'send: agents go to ntfy on a final result, in the agent format' ($block -match "if\(\`$agent -and \`$Ntfy -eq 'auto'\)\{ \`$mode = \`$\(if\(\`$final\)\{ 'always' \} else \{ 'never' \}\) \}" -and $block -match 'New-YcAgentNtfy -Area \$Area')
T 'send: an unchanged agent result is journalled, not sent' ($block -match "Test-YcAgentChanged -Area \`$Area -State \`$State\)\)\{\s+Write-YcMsJournal -Body \`$b -Sent 'unchanged'\s+return")
T 'send: a copy to the portal stage table'             ($block -match 'Send-YcMsReport -Json \$json')

# --- adopt and pre-migration mappings -------------------------------------------------------------
foreach ($pair in @(@($adopt, 'Get-AdoptPhaseHook'), @($prem, 'Get-PremigSlug'), @($prem, 'Get-PremigSectionState'))) {
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($pair[0], [ref]$null, [ref]$null)
  $fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $pair[1] }, $true)
  T ($pair[1] + ' exists') ([bool]$fn)
  if ($fn) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
$h = Get-AdoptPhaseHook -Phase 'SALT' -Rc 0 -Action 'joined';        T 'adopt SALT joined -> vm.salt.joined'      ($h.area -eq 'salt' -and $h.state -eq 'joined')
$h = Get-AdoptPhaseHook -Phase 'SALT' -Rc 3 -Action 'waiting';       T 'adopt SALT waiting -> vm.salt.waiting'    ($h.state -eq 'waiting')
$h = Get-AdoptPhaseHook -Phase 'SALT' -Rc 0 -Action 'skipped';       T 'adopt SALT skipped -> nothing'            ($null -eq $h)
$h = Get-AdoptPhaseHook -Phase 'ACRONIS' -Rc 0 -Action 'skipped-not-requested'; T 'adopt ACRONIS not requested -> nothing' ($null -eq $h)
$h = Get-AdoptPhaseHook -Phase 'ACRONIS' -Rc 3 -Action 'timeout';    T 'adopt ACRONIS timeout -> failed'          ($h.area -eq 'acronis' -and $h.state -eq 'failed')
$h = Get-AdoptPhaseHook -Phase 'ACRONIS' -Rc 0 -Action 'installed-registered'; T 'adopt ACRONIS -> registered' ($h.state -eq 'registered')
$h = Get-AdoptPhaseHook -Phase 'GLPI' -Rc 0 -Action 'registered';     T 'adopt GLPI ran -> nothing (glpi-join reports itself)' ($null -eq $h)
$h = Get-AdoptPhaseHook -Phase 'GLPI' -Rc 0 -Action 'skipped-not-requested'; T 'adopt GLPI not requested -> nothing' ($null -eq $h)
$h = Get-AdoptPhaseHook -Phase 'GLPI' -Rc 3 -Action 'no-command';     T 'adopt GLPI command missing -> vm.glpi.failed' ($h.area -eq 'glpi' -and $h.state -eq 'failed')
T 'adopt has the GLPI phase between ACRONIS and NOTIFY' ($adopt -match "'SALT','ACRONIS','GLPI','WSUS','NOTIFY','VERIFY'" -and $adopt -match "'GLPI'      \{ \`$rc = Invoke-Glpi \}")
T 'adopt GLPI password only from the environment'      ($adopt -notmatch '\[string\]\`$Glpi\w*Password' -and $adopt -match 'GLPI_AGENT_PASSWORD')
$h = Get-AdoptPhaseHook -Phase 'SQLBACKUP' -Rc 3;                    T 'adopt flagged phase -> waitforhuman'      ($h.area -eq 'adopt-sqlbackup' -and $h.state -eq 'waitforhuman')
$h = Get-AdoptPhaseHook -Phase 'PREREQ' -Rc 1;                       T 'adopt reboot-wait -> waiting'             ($h.state -eq 'waiting')
$h = Get-AdoptPhaseHook -Phase 'SYNC' -Rc 4;                         T 'adopt terminal -> failed'                 ($h.state -eq 'failed')
T 'premig slugs'                                       ((Get-PremigSlug 'THE MACHINE') -eq 'machine' -and (Get-PremigSlug 'THE FALLBACK - BACKUPS, AND WHETHER THEY RESTORE (checklist items 6-9)') -eq 'backups' -and (Get-PremigSlug 'SQL SERVER - SKIPPED (-SkipSql)') -eq '')
T 'premig section: blocker red, risk human, clean ok'  ((Get-PremigSectionState 1 0) -eq 'failed' -and (Get-PremigSectionState 0 2) -eq 'waitforhuman' -and (Get-PremigSectionState 0 0) -eq 'ok')
T 'premig writes no journal file (changes nothing)'    ($prem -match "(?m)^\`$script:YcJournalFile\s+= ''")
T 'premig reports every section and the verdict'       ($prem -match 'Close-PremigSection; Open-PremigSection' -and $prem -match "Send-YcMilestone -Area 'premig' -State \`$fin")
T 'adopt reports each phase, saves settings after SYNC, sends a final word' ($adopt -match 'Send-AdoptPhaseHook -Phase \$p -Rc \$rc' -and $adopt -match 'Save-YcMsConfig' -and $adopt -match "Send-YcMilestone -Area 'adopt' -State \`$fin")

# --- glpi-join ------------------------------------------------------------------------------------
$gj = [IO.File]::ReadAllText((Join-Path $PayloadDir 'Glpi-Join.ps1')) -replace "`r`n", "`n"
$ast = [System.Management.Automation.Language.Parser]::ParseInput($gj, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Test-GlpiKit' }, $true)
T 'Glpi-Join has Test-GlpiKit' ([bool]$fn)
if ($fn) { . ([scriptblock]::Create($fn.Extent.Text)) }
T 'kit check: the real header and valid PowerShell pass' (Test-GlpiKit "<#`n glpi-agent-setup.ps1 1.1.0 - YallaCloud`n#>`nparam([string]`$Password)`n'x'")
T 'kit check: a 403 HTML page fails'                   (-not (Test-GlpiKit '<html><body>403 Forbidden</body></html>'))
T 'kit check: a truncated kit fails'                   (-not (Test-GlpiKit "<#`n glpi-agent-setup.ps1 1.1.0`n#>`nfunction X {"))
T 'glpi-join: no password parameter'                    (@($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -match 'Pass' }).Count -eq 0)
T 'glpi-join: tenant passed to the kit by NAME (password stays in the environment)' ($gj -match "\`$a \+= '-Tenant'; \`$a \+= \`$Tenant")
T 'glpi-join: the kit''s own ntfy/webhook are off for the child' ($gj -match "\`$env:NTFY_TOPIC = 'off'; \`$env:EXTRA_WEBHOOK_URL = ''")
T 'glpi-join is in the catalogue and has a .cmd'        ((Test-Path (Join-Path $PayloadDir 'glpi-join.cmd')) -and ([IO.File]::ReadAllText((Join-Path $PayloadDir 'Yallacloud.ps1')) -match 'glpi-join'))

# --- library hooks ------------------------------------------------------------------------------
T 'Stop-YcLog sends the run milestone, not on the unclean path' ($lib -match 'if\(-not \$Unclean\)\{ try\{ \[void\]\(Send-YcRunMilestone -Code \$Code\) \}catch\{\} \}')
T 'Start-YcLog records the caller''s SWITCHES (2.5.1)'  ($lib -match '\$script:YcBoundNames = @\(\$bp\.Keys \| Where-Object \{ \$bp\[\$_\] -is \[System\.Management\.Automation\.SwitchParameter\]')
T 'Exit-Yc keeps its message as the reason'             ($lib -match 'if\(\$Code -ne 0 -and \$Message\)\{ \$script:YcLastMessage = \$Message \}')
T 'library version is 2.5.1'                            ($lib -match "\`$script:YcLibVersion\s+= '2\.5\.1'")
# --- 2.5.0 (payload 2.47.9): reasons, waiting, last result, safe journal, deployment link ------------
T 'Write-YcLog keeps the FIRST error of the run (P1)'   ($lib -match 'if\(-not \$script:YcFirstError\)\{ \$script:YcFirstError = \$safe \}')
T 'Start-YcLog resets the first error'                  ($lib -match "\`$script:YcFirstError  = ''")
T 'Stop-YcLog writes last-<tag>.json, not on the unclean path' ($lib -match 'if\(-not \$Unclean\)\{ try\{ Write-YcLastResult -Code \$Code \}catch\{\} \}')
T 'activate-windows exit 3 is WAITING (P8)'             ((Get-YcMsState -Area 'license' -Code 3) -eq 'waiting' -and (Get-YcMsState -Area 'license' -Code 1) -eq 'failed' -and (Get-YcMsState -Area 'license' -Code 0) -eq 'ok')
$script:YcFirstError = 'first error'; $script:YcLastMessage = 'last message'
T 'reason: the first error wins'                        ((Get-YcRunReason 'failed') -eq 'first error')
T 'reason: a WAITING run says its own message'          ((Get-YcRunReason 'waiting') -eq 'last message')
$script:YcFirstError = ''
T 'reason: no error = the last message'                 ((Get-YcRunReason 'failed') -eq 'last message')
$lt = Join-Path ([IO.Path]::GetTempPath()) ('yclr-' + [guid]::NewGuid().ToString('N'))
try {
  $script:YcLastResultDir = $lt; $script:YcTag = 'install-sql'; $script:YcBoundNames = @(); $script:YcFirstError = '-SaPasswordFile is empty: C:\x\.sa-password'
  $script:Summary = @('Build                 : 15.0.2000.5')
  Write-YcLastResult -Code 2
  $lr = Get-Content -LiteralPath (Join-Path $lt 'last-install-sql.json') -Raw | ConvertFrom-Json
  T 'last result: tag, code, state, reason (P1)'        ($lr.tag -eq 'install-sql' -and $lr.code -eq 2 -and $lr.state -eq 'failed' -and $lr.reason -eq '-SaPasswordFile is empty: C:\x\.sa-password') ($lr | ConvertTo-Json -Compress)
  T 'last result: the script summary rides along'       (@($lr.summary)[0] -match '^Build\s+: 15\.0\.2000\.5$')
  $script:YcTag = 'activate-windows'; $script:YcFirstError = ''; $script:YcLastMessage = 'edition changed to ServerStandard, reboot then activation'; $script:Summary = $null
  Write-YcLastResult -Code 3
  $lw = Get-Content -LiteralPath (Join-Path $lt 'last-activate-windows.json') -Raw | ConvertFrom-Json
  T 'last result: activate-windows 3 = waiting + reason' ($lw.state -eq 'waiting' -and $lw.reason -like 'edition changed to ServerStandard*')
  $script:YcBoundNames = @('Report'); $script:YcTag = 'install-ssms'
  Write-YcLastResult -Code 0
  T 'last result: a read-only run writes nothing'       (-not (Test-Path -LiteralPath (Join-Path $lt 'last-install-ssms.json')))
  $script:YcBoundNames = @()
  $jf = Join-Path $lt 'yc-milestones.log'
  T 'journal line: written by the safe writer (P9)'     ((Add-YcLineSafe -Path $jf -Line 'L1') -and ((Get-Content -LiteralPath $jf) -eq 'L1'))
} finally { Remove-Item -LiteralPath $lt -Recurse -Force -ErrorAction SilentlyContinue; $script:YcTag = 'yallacloud' }
T 'journal: Add-Content -EA Stop is gone (P9)'          ($block -notmatch 'Add-Content -LiteralPath \$script:YcJournalFile -Value \$line -Encoding ascii -ErrorAction Stop')
$bl7 = New-YcMsBody -Area 'sql' -State 'failed' -Err 'exit 2: x' -Tag 't' -Id $id -DeployId 'YCD-20261105-000008' -Seq 3
$n7 = New-YcMsNtfy -Body $bl7
T 'ntfy: first line links the deployment (P7)'           (($n7.text -split "`n")[0] -eq 'deployment : YCD-20261105-000008  https://cloudinit.mgmt.yallacloud.net/deployments?id=YCD-20261105-000008') (($n7.text -split "`n")[0])
T 'ntfy: Send-YcMsNtfy sends the Actions header'         ($block -match "if\(\`$act\)\{ \`$h\['Actions'\] = \`$act \}")
T 'agent ntfy: no "during the build" line (P6)'         ((New-YcAgentNtfy -Area 'glpi' -State 'registered' -DeployId 'YCD-20261105-000008' -Host_ 'H' -When 'during the build (also in OK BUILD)').text -notmatch 'when')
T 'os name: Evaluation dropped after the change (P11)'  ((ConvertTo-YcOsName -Caption 'Microsoft Windows Server 2022 Standard Evaluation' -EditionId 'ServerStandard') -eq 'Microsoft Windows Server 2022 Standard')
$isq = [IO.File]::ReadAllText((Join-Path $PayloadDir 'Install-Sql.ps1')) -replace "`r`n", "`n"
T 'install-sql: its exit no longer sets the library stop flag (no END, no vm.sql.* before 2.47.9)' ($isq -notmatch '\$script:YcStopped = \$true' -and $isq -match 'if \(\$script:YcSqlExiting\) \{ exit \$Code \}')
T 'install-sql: TLS certificate per instance (P12)'     ($isq -match 'function Set-YcSqlTlsCert' -and $isq -match "Microsoft RSA SChannel Cryptographic Provider" -and $isq -match "Add-YcSummary 'SQL TLS'" -and $isq -notmatch 'ForceEncryption\s*-Value\s*1')
$aw = [IO.File]::ReadAllText((Join-Path $PayloadDir 'Activate-Windows.ps1')) -replace "`r`n", "`n"
T 'activate-windows: eval read from the DISM edition (P10)' ($aw -match 'if \("\$cur"\) \{ \("\$cur" -match ''Eval''\)')
T 'activate-windows: exit 3 carries its reason (P8)'    ($aw -match "\`$script:YcLastMessage = \('edition changed to ' \+ \`$Edition")
# The call-stack capture, run for real: a script given -Report must be seen as read-only.
$m = [regex]::Match($lib, '(?s)    \$script:YcBoundNames = @\(\)\r?\n    try\{.*?\n    \}catch\{\}')
T 'capture code found' $m.Success
if ($m.Success) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ycwh-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  Set-Content -LiteralPath (Join-Path $tmp '_yc-lib.ps1') -Value ("function Cap{`n" + $m.Value + "`n return ,`$script:YcBoundNames }")
  Set-Content -LiteralPath (Join-Path $tmp 'cmd.ps1') -Value "param([switch]`$Report,[string]`$Region,[string]`$Version)`n. (Join-Path `$PSScriptRoot '_yc-lib.ps1')`n(Cap) -join ','"
  $got = & (Join-Path $tmp 'cmd.ps1') -Report -Region AE
  T 'capture sees the calling script''s switches'     ([string]$got -eq 'Report') ([string]$got)
  $got = & (Join-Path $tmp 'cmd.ps1') -Version 2019
  T 'a -Version VALUE is not a read-only run (install-sql -Version 2019)' ([string]$got -eq '') ([string]$got)
  Remove-Item -LiteralPath $tmp -Recurse -Force
}

# --- a real POST, as the receiver sees it ---------------------------------------------------------
$port = Get-Random -Minimum 20000 -Maximum 40000
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add('http://127.0.0.1:' + $port + '/')
try {
  $l.Start()
  $ar = $l.BeginGetContext($null, $null)
  $json = ([pscustomobject]$b) | ConvertTo-Json -Compress
  $job = [powershell]::Create().AddScript({ param($u, $j, $blk) . ([scriptblock]::Create($blk)); Send-YcMsPost -Url $u -Headers @{ 'X-Webhook-Secret' = 'S3cr3tVal' } -Json $j }).AddArgument('http://127.0.0.1:' + $port + '/in/event').AddArgument($json).AddArgument($block)
  $h2 = $job.BeginInvoke()
  if ($ar.AsyncWaitHandle.WaitOne(20000)) {
    $ctx = $l.EndGetContext($ar)
    $rd = New-Object IO.StreamReader($ctx.Request.InputStream); $got = $rd.ReadToEnd(); $rd.Close()
    T 'POST: X-Webhook-Secret header carried'          ($ctx.Request.Headers['X-Webhook-Secret'] -eq 'S3cr3tVal')
    T 'POST: Content-Type application/json'            ($ctx.Request.ContentType -like 'application/json*')
    T 'POST: body is the flat JSON'                    ($got -eq $json) $got
    T 'POST: secret is not in the body'                ($got -notmatch 'S3cr3tVal')
    $ctx.Response.StatusCode = 202; $ctx.Response.Close()
    $res = $job.EndInvoke($h2)
    T 'POST: the status code comes back'               ([string]$res[0] -eq '202') ([string]$res)
  } else { T 'POST: listener received the request' $false 'timeout' }
} catch { T 'POST: local listener test' $false $_.Exception.Message }
finally { try { $l.Stop() } catch {} }

Write-Host ''
Write-Host ('RESULT: ' + $script:pass + ' passed, ' + $script:fail + ' failed') -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
