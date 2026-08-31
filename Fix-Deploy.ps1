# =============================================================
# Fix-Deploy.ps1  v1.0  (2026-08-29)
# YALLACLOUD - the five DEPLOYMENT-TIME defects that bite every VM built from a
# template, applied in one idempotent pass so cloud-init can call ONE thing.
#
# These are not theoretical. Each one cost real time on the 2026-08 fleet:
#
#   1. ACCOUNT LOCKOUT INHERITED FROM THE TEMPLATE.
#      The sealed image carries a lockout threshold, so a handful of failed
#      logons - a monitoring probe, a stale saved credential, an automation
#      retry, or an operator typing the wrong password twice - locks the local
#      Administrator out of a brand new VM. It also breaks SSH: sshd's key
#      exchange still resolves the account, and a locked account is refused
#      before the key is ever considered, so "Permission denied (publickey)" is
#      reported for what is actually a lockout. `net accounts
#      /lockoutthreshold:0` disables the threshold, which is the documented way
#      to turn lockout off.
#
#   2. WRONG DEFAULT GATEWAY ON AN ISOLATED NETWORK.
#      On a CloudStack ISOLATED network the virtual router is at x.x.x.1, but
#      the guest can come up with x.x.x.254 configured. The VM then has an IP,
#      a link and DNS, and no route off the subnet - which reads as "the network
#      is broken" rather than "one wrong octet". This script only intervenes
#      when it can PROVE the case: a private (RFC1918) address, the configured
#      gateway not answering, and x.x.x.1 answering. A working gateway is never
#      touched, and a public address like 93.177.125.x/25 - where .254 is
#      genuinely correct - is left completely alone.
#
#   3. TLS 1.2 NOT USED BY .NET ON WINDOWS SERVER 2016.
#      Measured across the fleet on 2026-08-29: DNS resolved, ICMP worked and
#      TCP 443 connected on all 16 VMs, but an HTTPS request failed on exactly
#      four - x16E, x16B, C16E, C16B - every Server 2016 host and only those.
#      One of them had no endpoint protection at all and still failed, and a
#      Server 2022 host WITH endpoint protection worked, so it is not the
#      security stack: .NET on 2016 defaults to TLS 1.0, and endpoints that now
#      require 1.2 close the connection. The symptom is
#          The underlying connection was closed: An unexpected error occurred on a send.
#      and it looks exactly like "no internet" to whoever reports it.
#      SchUseStrongCrypto and SystemDefaultTlsVersions fix it for every .NET
#      application on the machine, not just for scripts that remember to set
#      ServicePointManager themselves.
#
#   4. CONSOLE LOGON FOCUSED ON THE WRONG ACCOUNT (mostly vCenter guests).
#      The console presents the last-logged-on user, which on a template is
#      whatever account sealed it. Operators then type the Administrator
#      password into a different account's box, fail, and - with defect 1 still
#      in place - lock something out. Pointing LogonUI at .\Administrator makes
#      the console land on the account whose password the deployment actually
#      hands out.
#
# Every fix is idempotent and re-runnable, checks whether it applies before
# touching anything, and reports what it did. Nothing here needs the network.
#
# PowerShell 5.1 only. ASCII only. Windows Server 2012 R2 - 2025.
# =============================================================
param(
  [string]$Only,
  [switch]$Report,
  [switch]$RestartSql,
  [switch]$MergeOrphanBackups,
  [switch]$SelfCheck,
  [switch]$Help
)
. 'C:\Scripts\_yc-lib.ps1'
Start-YcLog 'fix-deploy'
$ErrorActionPreference = 'Continue'

$AllFixes = @('lockout','gateway','tls','console','cbinit','sqlrename')

if($Help){
@"
fix-deploy  -  apply the YallaCloud deployment-time fixes. Safe to run more than once.

USAGE:
  fix-deploy                          apply every fix that applies to this machine
  fix-deploy -Report                  report what WOULD be done, change nothing
  fix-deploy -Only lockout,gateway    apply just these
  fix-deploy -Only sqlrename -RestartSql          repair SQL after a rename AND restart it now
  fix-deploy -Only sqlrename -MergeOrphanBackups  also fold the stale backup folder back in
  fix-deploy -SelfCheck               run the built-in assertions, touch nothing
  fix-deploy -Help

THE FIXES:
  lockout   net accounts /lockoutthreshold:0 - stops a template's inherited lockout policy
            locking Administrator out of a new VM. Also fixes SSH being refused with
            "Permission denied (publickey)" when the real cause is a locked account.
            Applies to: every template.
  gateway   On a CloudStack ISOLATED network the router is x.x.x.1, but the guest can come up
            with x.x.x.254 and no route off the subnet. Only changed when the address is
            private, the configured gateway does NOT answer, and x.x.x.1 DOES. A working
            gateway is never touched and a public address is left alone.
  tls       SchUseStrongCrypto + SystemDefaultTlsVersions (both 32 and 64 bit) and the SCHANNEL
            TLS 1.2 client/server keys, so .NET stops defaulting to TLS 1.0.
            Applies to: Windows Server 2016 and older. Skipped on 2019+.
  console   LogonUI LastLoggedOnUser / LastLoggedOnSAMUser = .\Administrator, so the console
            lands on the account whose password the deployment hands out. Mostly a vCenter
            problem. Applies to: every template.
  cbinit    Adds the cloudbase-init NetworkConfigPlugin if the template shipped without it.
            Without that plugin cloudbase-init NEVER applies the IP, netmask, gateway, routes
            or DNS that CloudStack puts in the config drive. On a network with a virtual
            router DHCP hides the problem; on an ISOLATED network there is no DHCP, so the
            VM comes up with no usable network at all. This is the ROOT CAUSE that the
            'gateway' fix above only papers over. Inserted in the documented position - before
            UserDataPlugin and LocalScriptsPlugin, so user data runs with a working network.
            The conf change alone does not re-run cloudbase-init. It also writes a
            NETWORK-ONLY conf beside it and prints that command: re-running the MAIN conf
            would re-run SetUserPasswordPlugin and RESET the Administrator password, which
            is why cloudbase-init is stopped after the first deployment run. Never
            re-enable the service. Applies to: every template built before 2026-08-30.
  sqlrename Repairs SQL Server after the Windows computer name changed. A rename does NOT
            break logins - Windows logins are stored by SID - but it leaves three things
            wrong, silently:
              a) @@SERVERNAME keeps the OLD name for ever, because it is read once at
                 startup from a row this fix rewrites. Linked servers, replication and any
                 tool that reads @@SERVERNAME see a machine that no longer exists.
              b) sys.server_principals still shows OLDHOST\chadmin. Cosmetic - the SID is
                 what authenticates - but confusing, so the login is renamed too.
              c) Ola Hallengren writes to <BackupDir>\<hostname>\..., so backups fork to a
                 new folder and @CleanupTime never prunes the old one again. It grows for
                 ever. This fix REPORTS the orphan; -MergeOrphanBackups moves it back under
                 the current name so retention applies to it again.
            REFUSES to touch a clustered instance, an AlwaysOn instance, or one that is a
            replication publisher / subscriber / distributor - renaming those is not a
            supported operation and Microsoft says so.
            @@SERVERNAME only picks up the change when SQL Server restarts. This fix does
            NOT restart it by default, because fix-deploy must never take a production
            database down as a side effect. It writes the metadata, then either restarts on
            -RestartSql or prints the one command that finishes the job.
            Applies to: any host where the computer name no longer matches @@SERVERNAME.

CLOUD-INIT: call this FIRST, before anything that needs the network or SSH:
  C:\Scripts\fix-deploy.cmd

EXIT CODES:
  0  every applicable fix is in place
  1  bad arguments, or help
  2  one or more fixes could not be applied (see the log)
  5  not elevated
Log: C:\Scripts\fix-deploy.log
"@ | Write-Host -ForegroundColor Cyan
  Stop-YcLog 0; exit 0
}

# Escape a value for a T-SQL string literal. Pure.
function Get-YcSqlLiteral{
  param([string]$Value)
  return ("$Value" -replace "'","''")
}
# Escape a value for a T-SQL bracketed identifier. Pure.
function Get-YcSqlBracket{
  param([string]$Value)
  return ("$Value" -replace '\]',']]')
}
# What @@SERVERNAME SHOULD say on this machine for this instance. Pure.
function Get-YcExpectedSqlServerName{
  param([string]$MachineName,[string]$InstanceName)
  if([string]::IsNullOrEmpty($InstanceName) -or $InstanceName -eq 'MSSQLSERVER'){ return "$MachineName" }
  return ("$MachineName" + '\' + "$InstanceName")
}

# ---------------------------------------------------------------------------
# -SelfCheck. The only logic in this script that builds T-SQL from a machine name is
# the rename repair, so that is what is asserted: the escaping, and the name it expects.
# Needs no admin rights, touches nothing, exits non-zero on the first bad assertion.
# ---------------------------------------------------------------------------
if($SelfCheck){
  $n = 0; $bad = 0
  function T{
    param([string]$What,[bool]$Ok)
    $script:n++
    if($Ok){ Write-Host ('  ok   ' + $What) -ForegroundColor Green }
    else   { Write-Host ('  FAIL ' + $What) -ForegroundColor Red; $script:bad++ }
  }
  $script:n = 0; $script:bad = 0
  T 'a plain name survives the literal escape'      ((Get-YcSqlLiteral 'WIN-ABC123') -eq 'WIN-ABC123')
  T 'a single quote is doubled in a literal'        ((Get-YcSqlLiteral "O'Brien") -eq "O''Brien")
  T 'two single quotes both double'                 ((Get-YcSqlLiteral "a'b'c") -eq "a''b''c")
  T 'a plain name survives the bracket escape'      ((Get-YcSqlBracket 'HOST\chadmin') -eq 'HOST\chadmin')
  T 'a closing bracket is doubled'                  ((Get-YcSqlBracket 'HOST\ad]min') -eq 'HOST\ad]]min')
  T 'the default instance expects the bare name'    ((Get-YcExpectedSqlServerName -MachineName 'NEWHOST' -InstanceName '') -eq 'NEWHOST')
  T 'MSSQLSERVER also expects the bare name'        ((Get-YcExpectedSqlServerName -MachineName 'NEWHOST' -InstanceName 'MSSQLSERVER') -eq 'NEWHOST')
  T 'a named instance expects HOST\INSTANCE'        ((Get-YcExpectedSqlServerName -MachineName 'NEWHOST' -InstanceName 'SQLW') -eq 'NEWHOST\SQLW')
  T 'a matching name is detected as no-op'          ((Get-YcExpectedSqlServerName -MachineName 'H' -InstanceName 'I') -eq 'H\I')
  Write-Host ''
  if($script:bad -eq 0){ Write-Host ('SELF-CHECK PASSED: ' + $script:n + ' assertions') -ForegroundColor Green; Stop-YcLog 0; exit 0 }
  Write-Host ('SELF-CHECK FAILED: ' + $script:bad + ' of ' + $script:n + ' assertions') -ForegroundColor Red
  Stop-YcLog 1; exit 1
}

Assert-YcPrereqs -NeedAdmin

$run = $AllFixes
if($Only){
  $run = @()
  foreach($t in ($Only -split ',')){
    $t = $t.Trim().ToLowerInvariant()
    if(-not $t){ continue }
    if($AllFixes -notcontains $t){
      Write-YcLog ('Unknown -Only value "' + $t + '". Valid: ' + ($AllFixes -join ', ') + '.') 'ERROR'
      Stop-YcLog 1; exit 1
    }
    $run += $t
  }
  if($run.Count -eq 0){ Write-YcLog '-Only was supplied but named no fix.' 'ERROR'; Stop-YcLog 1; exit 1 }
}
Write-YcLog ('Fixes selected: ' + ($run -join ', ') + $(if($Report){'  (REPORT ONLY - nothing will be changed)'}else{''}))

$script:Failed  = 0
$script:Changed = 0
$script:Would   = 0
function Set-YcRegDword{
  param([string]$Path,[string]$Name,[int]$Value)
  try{
    if(-not (Test-Path -LiteralPath $Path)){ New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    $cur = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if($null -ne $cur -and [int]$cur -eq $Value){ Write-YcLog ('  already set: ' + $Path + ' ' + $Name + '=' + $Value); return $true }
    if($Report){ Write-YcLog ('  WOULD set: ' + $Path + ' ' + $Name + '=' + $Value + ' (currently ' + $(if($null -eq $cur){'absent'}else{$cur}) + ')') 'WARN'; $script:Would++; return $true }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType DWord -Value $Value -Force -ErrorAction Stop | Out-Null
    Write-YcLog ('  set: ' + $Path + ' ' + $Name + '=' + $Value) 'OK'
    $script:Changed++
    return $true
  }catch{
    Write-YcLog ('  FAILED to set ' + $Path + ' ' + $Name + ': ' + $_.Exception.Message) 'ERROR'
    $script:Failed++
    return $false
  }
}
function Set-YcRegString{
  param([string]$Path,[string]$Name,[string]$Value)
  try{
    if(-not (Test-Path -LiteralPath $Path)){ New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    $cur = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if("$cur" -eq $Value){ Write-YcLog ('  already set: ' + $Path + ' ' + $Name + '=' + $Value); return $true }
    if($Report){ Write-YcLog ('  WOULD set: ' + $Path + ' ' + $Name + '=' + $Value + ' (currently "' + "$cur" + '")') 'WARN'; $script:Would++; return $true }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType String -Value $Value -Force -ErrorAction Stop | Out-Null
    Write-YcLog ('  set: ' + $Path + ' ' + $Name + '=' + $Value) 'OK'
    $script:Changed++
    return $true
  }catch{
    Write-YcLog ('  FAILED to set ' + $Path + ' ' + $Name + ': ' + $_.Exception.Message) 'ERROR'
    $script:Failed++
    return $false
  }
}

# ---------------------------------------------------------------------------
# Is this address one of the private ranges an isolated CloudStack network uses?
# Pure, so it can be tested. 10/8, 172.16/12, 192.168/16 - RFC 1918, nothing else.
# ---------------------------------------------------------------------------
function Test-YcPrivateIPv4{
  param([string]$Address)
  if("$Address" -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$'){ return $false }
  $a=[int]$Matches[1]; $b=[int]$Matches[2]; $c=[int]$Matches[3]; $d=[int]$Matches[4]
  foreach($o in $a,$b,$c,$d){ if($o -lt 0 -or $o -gt 255){ return $false } }
  if($a -eq 10){ return $true }
  if($a -eq 172 -and $b -ge 16 -and $b -le 31){ return $true }
  if($a -eq 192 -and $b -eq 168){ return $true }
  return $false
}
# The .1 of the same /24-style prefix. Pure.
function Get-YcRouterCandidate{
  param([string]$Address)
  if("$Address" -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$'){ return '' }
  return ($Matches[1] + '.1')
}

# ===========================================================================
# FIX 1 - account lockout threshold
# ===========================================================================
if($run -contains 'lockout'){
  Write-YcLog '--- lockout: disabling the account lockout threshold inherited from the template ---'
  $before = (& net accounts 2>&1 | Out-String)
  $curThr = ''
  if($before -match '(?im)^Lockout threshold:\s*(.+)$'){ $curThr = $Matches[1].Trim() }
  Write-YcLog ('  current lockout threshold: ' + $(if($curThr){$curThr}else{'(could not read)'}))
  if($curThr -match '(?i)^never$'){
    Write-YcLog '  already disabled - nothing to do.' 'OK'
  } elseif($Report){
    Write-YcLog '  WOULD run: net accounts /lockoutthreshold:0' 'WARN'; $script:Would++
  } else {
    $out = (& net accounts /lockoutthreshold:0 2>&1 | Out-String).Trim()
    if($out){ Write-YcLog ('  net accounts: ' + ($out -replace '\s+',' ')) }
    # Verify by reading it back. The command can report success and change nothing
    # when a domain or local policy owns the setting.
    $after = (& net accounts 2>&1 | Out-String)
    $newThr = ''
    if($after -match '(?im)^Lockout threshold:\s*(.+)$'){ $newThr = $Matches[1].Trim() }
    if($newThr -match '(?i)^never$'){
      Write-YcLog '  VERIFIED: lockout threshold is now Never.' 'OK'
      $script:Changed++
    } else {
      Write-YcLog ('  VERIFICATION FAILED: lockout threshold still reads "' + $newThr + '". A policy (local security policy or a domain GPO) is overriding it - fix it there.') 'ERROR'
      $script:Failed++
    }
  }
  # The account itself may ALREADY be locked out from before the threshold changed.
  try{
    $adm = Get-LocalUser -Name 'Administrator' -ErrorAction Stop
    Write-YcLog ('  Administrator: Enabled=' + $adm.Enabled)
    $wmi = Get-CimInstance Win32_UserAccount -Filter "Name='Administrator' AND LocalAccount=True" -ErrorAction SilentlyContinue
    if($wmi -and $wmi.Lockout){
      if($Report){
        Write-YcLog '  Administrator is CURRENTLY LOCKED OUT. WOULD unlock it.' 'WARN'; $script:Would++
      } else {
        try{
          ([ADSI]("WinNT://" + $env:COMPUTERNAME + "/Administrator,user")).IsAccountLocked = $false
          Write-YcLog '  Administrator was LOCKED OUT and has been unlocked.' 'OK'
          $script:Changed++
        }catch{
          Write-YcLog ('  Administrator is locked out and could not be unlocked: ' + $_.Exception.Message) 'ERROR'
          $script:Failed++
        }
      }
    } elseif($wmi){
      Write-YcLog '  Administrator is not locked out.' 'OK'
    }
  }catch{
    Write-YcLog ('  Could not read the Administrator account: ' + $_.Exception.Message) 'WARN'
  }
}

# ===========================================================================
# FIX 2 - default gateway on an isolated network
# ===========================================================================
if($run -contains 'gateway'){
  Write-YcLog '--- gateway: checking for the isolated-network .254 / .1 mismatch ---'
  $acted = $false
  foreach($cfg in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)){
    $v4 = $cfg.IPv4Address | Select-Object -First 1
    if(-not $v4){ continue }
    $ip  = [string]$v4.IPAddress
    $gw  = [string]($cfg.IPv4DefaultGateway | Select-Object -First 1).NextHop
    $ifx = $cfg.InterfaceIndex
    if(-not (Test-YcPrivateIPv4 -Address $ip)){
      Write-YcLog ('  ' + $cfg.InterfaceAlias + ' ' + $ip + ' is a public address - not an isolated network, leaving its gateway (' + $gw + ') alone.')
      continue
    }
    $cand = Get-YcRouterCandidate -Address $ip
    if(-not $cand){ continue }
    if($gw -eq $cand){
      Write-YcLog ('  ' + $cfg.InterfaceAlias + ' ' + $ip + ' already uses ' + $cand + ' - correct.') 'OK'
      continue
    }
    # Only act on PROOF: the configured gateway is dead and the candidate answers.
    # ICMP alone is not proof of death. Plenty of gateways - and every firewall doing its
    # job - drop ping while routing perfectly, and replacing that route breaks a VM that was
    # working. Ask the neighbour table too: if the gateway answers ARP it is alive on the
    # wire, whatever it does with ping, and it is NOT ours to replace.
    $gwUp = $false
    if($gw){
      $gwUp = [bool](Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue)
      if(-not $gwUp){
        try{
          $nb = Get-NetNeighbor -IPAddress $gw -ErrorAction SilentlyContinue |
                Where-Object { $_.State -in 'Reachable','Stale','Permanent','Delay','Probe' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(00-00-00-00-00-00)$' }
          if($nb){
            $gwUp = $true
            Write-YcLog ('  ' + $cfg.InterfaceAlias + ' gateway ' + $gw + ' does not answer ICMP but IS in the neighbour table (' + ([string]($nb | Select-Object -First 1).State) + ') - it is alive and is NOT being changed.') 'OK'
          }
        }catch{}
      }
    }
    if($gwUp){
      Write-YcLog ('  ' + $cfg.InterfaceAlias + ' ' + $ip + ' gateway ' + $gw + ' answers - it is working, so it is NOT being changed.') 'OK'
      continue
    }
    $candUp = [bool](Test-Connection -ComputerName $cand -Count 2 -Quiet -ErrorAction SilentlyContinue)
    if(-not $candUp){
      Write-YcLog ('  ' + $cfg.InterfaceAlias + ' ' + $ip + ': configured gateway ' + $(if($gw){$gw}else{'(none)'}) + ' does not answer AND ' + $cand + ' does not answer either. This is a real network fault, not the CloudStack .254 quirk - not guessing.') 'WARN'
      continue
    }
    $acted = $true
    if($Report){
      Write-YcLog ('  WOULD replace the dead gateway ' + $(if($gw){$gw}else{'(none)'}) + ' with ' + $cand + ' on ' + $cfg.InterfaceAlias + '.') 'WARN'; $script:Would++
      continue
    }
    try{
      if($gw){ Remove-NetRoute -InterfaceIndex $ifx -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue }
      New-NetRoute -InterfaceIndex $ifx -DestinationPrefix '0.0.0.0/0' -NextHop $cand -ErrorAction Stop | Out-Null
      Write-YcLog ('  ' + $cfg.InterfaceAlias + ': default gateway changed from ' + $(if($gw){$gw}else{'(none)'}) + ' to ' + $cand + ' (CloudStack isolated networks route through .1, not .254).') 'OK'
      $script:Changed++
    }catch{
      Write-YcLog ('  FAILED to set the gateway to ' + $cand + ' on ' + $cfg.InterfaceAlias + ': ' + $_.Exception.Message) 'ERROR'
      $script:Failed++
    }
  }
  if(-not $acted){ Write-YcLog '  no interface needed a gateway change.' 'OK' }
}

# ===========================================================================
# FIX 3 - TLS 1.2 for .NET, Windows Server 2016 and older
# ===========================================================================
if($run -contains 'tls'){
  $build = 0
  try{ $build = [int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber }catch{ $build = [int][Environment]::OSVersion.Version.Build }
  if($build -ge 17763){
    Write-YcLog ('--- tls: build ' + $build + ' is Windows Server 2019 or later, where .NET already negotiates TLS 1.2 - skipped ---') 'OK'
  } else {
    Write-YcLog ('--- tls: build ' + $build + ' is Windows Server 2016 or older - forcing .NET onto TLS 1.2 ---')
    foreach($k in 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319','HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'){
      [void](Set-YcRegDword -Path $k -Name 'SchUseStrongCrypto' -Value 1)
      [void](Set-YcRegDword -Path $k -Name 'SystemDefaultTlsVersions' -Value 1)
    }
    $sch = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2'
    foreach($side in 'Client','Server'){
      [void](Set-YcRegDword -Path ($sch + '\' + $side) -Name 'Enabled' -Value 1)
      [void](Set-YcRegDword -Path ($sch + '\' + $side) -Name 'DisabledByDefault' -Value 0)
    }
    Write-YcLog '  NOTE: .NET reads these at process start, so anything already running keeps its old behaviour until it restarts. A reboot makes it uniform.' 'WARN'
  }
}

# ===========================================================================
# FIX 4 - console logon focused on Administrator
# ===========================================================================
if($run -contains 'console'){
  Write-YcLog '--- console: pointing the logon screen at .\Administrator ---'
  $lu = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
  [void](Set-YcRegString -Path $lu -Name 'LastLoggedOnUser'        -Value '.\Administrator')
  [void](Set-YcRegString -Path $lu -Name 'LastLoggedOnSAMUser'     -Value '.\Administrator')
  [void](Set-YcRegString -Path $lu -Name 'LastLoggedOnDisplayName' -Value 'Administrator')
}

# ===========================================================================
# FIX 5 - cloudbase-init NetworkConfigPlugin
# The template's plugins= line was written without it, so cloudbase-init read the
# config drive, saw the network details and applied NONE of them. Proven on 5 of 5
# registered Windows templates on 2026-08-30.
# ===========================================================================
if($run -contains 'cbinit'){
  Write-YcLog '--- cbinit: checking the cloudbase-init plugin list ---'
  $ncp  = 'cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin'
  $conf = Join-Path $env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'
  if(-not (Test-Path -LiteralPath $conf)){
    Write-YcLog '  cloudbase-init is not installed on this machine - nothing to do.' 'OK'
  } else {
    $lines = @(Get-Content -LiteralPath $conf -ErrorAction SilentlyContinue)
    $idx   = -1
    for($i=0; $i -lt $lines.Count; $i++){ if($lines[$i] -match '^\s*plugins\s*='){ $idx = $i; break } }
    if($idx -lt 0){
      Write-YcLog ('  no plugins= line in ' + $conf + ' - refusing to guess. Fix by hand.') 'WARN'
      $script:Failed++
    } elseif($lines[$idx] -like ('*' + $ncp + '*')){
      Write-YcLog '  NetworkConfigPlugin already present - nothing to do.' 'OK'
    } else {
      # Documented order: after CreateUserPlugin, before SetUserPassword / UserData /
      # LocalScripts. Appending it LAST would configure the network only after user data
      # had already tried to use it.
      $old = $lines[$idx]
      $new = ''
      foreach($a in 'cloudbaseinit.plugins.windows.createuser.CreateUserPlugin',
                    'cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin'){
        if($old -like ('*' + $a + '*')){ $new = $old -replace [regex]::Escape($a), ($a + ',' + $ncp); break }
      }
      if(-not $new){ $new = $old.TrimEnd() + ',' + $ncp }
      Write-YcLog ('  current: ' + $old)
      if($Report){
        Write-YcLog ('  WOULD write: ' + $new) 'WARN'; $script:Would++
      } else {
        try{
          $lines[$idx] = $new
          Set-Content -LiteralPath $conf -Value $lines -Encoding ascii -ErrorAction Stop
          Write-YcLog ('  written : ' + $new) 'OK'
          $script:Changed++

          # DO NOT tell anyone to re-run cloudbase-init against the MAIN conf. That conf
          # contains SetUserPasswordPlugin and CreateUserPlugin, so a re-run RESETS the
          # Administrator password - which is the exact reason cloudbase-init is stopped
          # after the first deployment run in the first place. Write a NETWORK-ONLY conf
          # beside it instead: same metadata sources, two harmless plugins, nothing that
          # can touch an account.
          $netOnly = Join-Path (Split-Path $conf -Parent) 'cloudbase-init-networkonly.conf'
          try{
            $nl = @()
            foreach($ln in $lines){
              if($ln -match '^\s*plugins\s*='){
                $nl += ('plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,' + $ncp)
              } elseif($ln -match '^\s*(inject_user_password|allow_reboot|stop_service_on_exit)\s*='){
                continue
              } else { $nl += $ln }
            }
            $nl += 'inject_user_password=false'
            $nl += 'allow_reboot=false'
            $nl += 'stop_service_on_exit=false'
            Set-Content -LiteralPath $netOnly -Value $nl -Encoding ascii -ErrorAction Stop
            Write-YcLog ('  wrote a network-only conf: ' + $netOnly) 'OK'
            Write-YcLog '  the main conf is fixed for the NEXT clone. To apply the network on THIS machine' 'WARN'
            Write-YcLog '  without resetting the Administrator password, run:' 'WARN'
            Write-YcLog ('    & "' + (Join-Path $env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init\Python\Scripts\cloudbase-init.exe') + '" --config-file "' + $netOnly + '"')
            Write-YcLog '  Do NOT run it against cloudbase-init.conf and do NOT re-enable the service.' 'WARN'
          }catch{
            Write-YcLog ('  could not write the network-only conf: ' + $_.Exception.Message) 'WARN'
          }
        }catch{
          Write-YcLog ('  FAILED to write ' + $conf + ': ' + $_.Exception.Message) 'ERROR'
          $script:Failed++
        }
      }
    }
  }
}

# ===========================================================================
# FIX 6 - SQL Server after a Windows computer rename
# Renaming a Windows box does NOT lock anyone out of SQL Server: Windows logins are
# stored by SID and a local account's SID does not change. Proved on 2026-08-31 by
# renaming a live 2025 Datacenter clone - chadmin still authenticated as sysadmin and
# all six YC-Sql* scheduled tasks still returned 0.
#
# What it DOES leave behind, silently, is three things:
#   a) @@SERVERNAME still reports the old name. It is read once at startup from a row
#      in sys.servers that a rename never touches. Microsoft's documented repair is
#      sp_dropserver / sp_addserver 'local', then a restart.
#   b) sys.server_principals still shows OLDHOST\chadmin. Cosmetic only.
#   c) Ola Hallengren writes to <BackupDir>\<hostname>\..., so backups fork into a new
#      folder and @CleanupTime = 168 only ever prunes the new one. The old folder is
#      orphaned and grows for ever. Observed live: 7 files stranded, 11 live.
#
# The guards matter more than the repair. Renaming is NOT supported on a clustered
# instance, on an AlwaysOn instance, or on a replication publisher / subscriber /
# distributor, so this refuses all three rather than "fixing" them into a broken state.
# ===========================================================================
$script:YcSqlErr = ''

function Invoke-YcSqlRows{
  param([string]$Target,[string]$Query,[int]$TimeoutSec = 20)
  $rows = @(); $cn = $null
  try{
    Add-Type -AssemblyName 'System.Data' -ErrorAction SilentlyContinue
    $cs = 'Server=' + $Target + ';Database=master;Integrated Security=SSPI;Connect Timeout=' +
          $TimeoutSec + ';Application Name=YallaCloud-fix-deploy'
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cn.Open()
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = $TimeoutSec
    $rd = $cmd.ExecuteReader()
    while($rd.Read()){
      $h = @{}
      for($i = 0; $i -lt $rd.FieldCount; $i++){ $h[$rd.GetName($i)] = $rd.GetValue($i) }
      $rows += ,$h
    }
    $rd.Close()
    $script:YcSqlErr = ''
  }catch{
    $script:YcSqlErr = $_.Exception.Message
    return $null
  }finally{
    if($null -ne $cn){ try{ $cn.Close() }catch{}; try{ $cn.Dispose() }catch{} }
  }
  return ,$rows
}
function Invoke-YcSqlExec{
  param([string]$Target,[string]$Query,[int]$TimeoutSec = 60)
  $cn = $null
  try{
    Add-Type -AssemblyName 'System.Data' -ErrorAction SilentlyContinue
    $cs = 'Server=' + $Target + ';Database=master;Integrated Security=SSPI;Connect Timeout=20' +
          ';Application Name=YallaCloud-fix-deploy'
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cn.Open()
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = $TimeoutSec
    [void]$cmd.ExecuteNonQuery()
    $script:YcSqlErr = ''
    return $true
  }catch{
    $script:YcSqlErr = $_.Exception.Message
    return $false
  }finally{
    if($null -ne $cn){ try{ $cn.Close() }catch{}; try{ $cn.Dispose() }catch{} }
  }
}

if($run -contains 'sqlrename'){
  Write-YcLog '--- sqlrename: SQL Server after a Windows computer rename ---'

  $instances = @()
  foreach($regRoot in 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server'){
    $p = Join-Path $regRoot 'Instance Names\SQL'
    if(-not (Test-Path -LiteralPath $p)){ continue }
    $props = Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue
    if($null -eq $props){ continue }
    foreach($pr in $props.PSObject.Properties){
      if($pr.Name -like 'PS*'){ continue }
      if($instances -notcontains $pr.Name){ $instances += $pr.Name }
    }
  }

  if($instances.Count -eq 0){
    Write-YcLog '  no SQL Server instance on this machine - nothing to repair.' 'OK'
  }

  foreach($instName in $instances){
    $isDefault = ($instName -eq 'MSSQLSERVER')
    $target    = if($isDefault){ '.' } else { '.\' + $instName }
    $svcName   = if($isDefault){ 'MSSQLSERVER' } else { 'MSSQL$' + $instName }
    $agtName   = if($isDefault){ 'SQLSERVERAGENT' } else { 'SQLAgent$' + $instName }

    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if($null -eq $svc){
      Write-YcLog ('  ' + $instName + ': the service ' + $svcName + ' does not exist - skipped.') 'WARN'
      continue
    }
    if($svc.Status -ne 'Running'){
      Write-YcLog ('  ' + $instName + ': ' + $svcName + ' is ' + $svc.Status + ', not Running. This fix reads and writes ' +
                   'sys.servers, so it needs the engine up. Start it and re-run.') 'WARN'
      continue
    }

    $q = "SET NOCOUNT ON; SELECT CONVERT(nvarchar(128),@@SERVERNAME) AS ServerName," +
         "CONVERT(nvarchar(128),SERVERPROPERTY('MachineName')) AS MachineName," +
         "CONVERT(nvarchar(128),ISNULL(SERVERPROPERTY('InstanceName'),'')) AS InstanceName," +
         "CONVERT(int,ISNULL(SERVERPROPERTY('IsClustered'),0)) AS IsClustered," +
         "CONVERT(int,ISNULL(SERVERPROPERTY('IsHadrEnabled'),0)) AS IsHadrEnabled"
    $rows = Invoke-YcSqlRows -Target $target -Query $q
    if($null -eq $rows -or $rows.Count -eq 0){
      Write-YcLog ('  ' + $instName + ': could not query the instance (' + $script:YcSqlErr + ') - skipped.') 'WARN'
      continue
    }
    $cur      = [string]$rows[0]['ServerName']
    $machine  = [string]$rows[0]['MachineName']
    $instProp = [string]$rows[0]['InstanceName']
    $expected = Get-YcExpectedSqlServerName -MachineName $machine -InstanceName $instProp

    if($cur -eq $expected){
      Write-YcLog ('  ' + $instName + ': @@SERVERNAME is "' + $cur + '", which matches the machine. Nothing to repair.') 'OK'
    } else {
      Write-YcLog ('  ' + $instName + ': @@SERVERNAME is "' + $cur + '" but this machine is "' + $expected +
                   '". A Windows rename happened and SQL Server was never told.') 'WARN'

      $blocked = ''
      if([int]$rows[0]['IsClustered'] -eq 1){ $blocked = 'this is a CLUSTERED instance' }
      elseif([int]$rows[0]['IsHadrEnabled'] -eq 1){ $blocked = 'AlwaysOn Availability Groups are enabled on this instance' }
      else{
        $rq = "SET NOCOUNT ON; SELECT CONVERT(int,(SELECT COUNT(*) FROM sys.servers WHERE is_publisher=1 OR is_subscriber=1 OR is_distributor=1)) AS ReplServers," +
              "CONVERT(int,(SELECT COUNT(*) FROM sys.databases WHERE is_published=1 OR is_subscribed=1 OR is_merge_published=1 OR is_distributor=1)) AS ReplDbs"
        $rr = Invoke-YcSqlRows -Target $target -Query $rq
        if($null -eq $rr){
          $blocked = 'the replication check could not be run (' + $script:YcSqlErr + '), so this refuses to guess'
        } elseif([int]$rr[0]['ReplServers'] -gt 0 -or [int]$rr[0]['ReplDbs'] -gt 0){
          $blocked = 'this instance takes part in REPLICATION (' + [int]$rr[0]['ReplServers'] + ' server role(s), ' +
                     [int]$rr[0]['ReplDbs'] + ' database(s))'
        }
      }

      if($blocked){
        Write-YcLog ('  ' + $instName + ': REFUSING to run sp_dropserver / sp_addserver, because ' + $blocked + '. ' +
                     'Microsoft does not support renaming a host in this configuration. Tear the configuration down, ' +
                     'rename, then rebuild it - by hand, deliberately.') 'ERROR'
        $script:Failed++
      } elseif($Report){
        Write-YcLog ('  WOULD run: EXEC sp_dropserver ''' + $cur + '''; EXEC sp_addserver ''' + $expected + ''', ''local'';') 'WARN'
        $script:Would++
      } else {
        $lo = Get-YcSqlLiteral $cur
        $ln = Get-YcSqlLiteral $expected
        $sql = "EXEC sp_dropserver '" + $lo + "'; EXEC sp_addserver '" + $ln + "', 'local';"
        if(Invoke-YcSqlExec -Target $target -Query $sql){
          Write-YcLog ('  ' + $instName + ': sp_dropserver / sp_addserver done - sys.servers now names "' + $expected + '".') 'OK'
          $script:Changed++
          # @@SERVERNAME is cached from startup. Until the engine restarts it still reports the
          # old name, and saying otherwise here would be a lie.
          if($RestartSql){
            $agtWasRunning = $false
            $agt = Get-Service -Name $agtName -ErrorAction SilentlyContinue
            if($null -ne $agt -and $agt.Status -eq 'Running'){ $agtWasRunning = $true }
            Write-YcLog ('  ' + $instName + ': -RestartSql was supplied - restarting ' + $svcName + ' now. Connections will drop.') 'WARN'
            try{
              Restart-Service -Name $svcName -Force -ErrorAction Stop
              Start-Sleep -Seconds 5
              if($agtWasRunning){ Start-Service -Name $agtName -ErrorAction SilentlyContinue }
              $after = Invoke-YcSqlRows -Target $target -Query "SET NOCOUNT ON; SELECT CONVERT(nvarchar(128),@@SERVERNAME) AS ServerName"
              if($null -ne $after -and $after.Count -gt 0 -and [string]$after[0]['ServerName'] -eq $expected){
                Write-YcLog ('  ' + $instName + ': VERIFIED - @@SERVERNAME now reads "' + $expected + '".') 'OK'
              } else {
                Write-YcLog ('  ' + $instName + ': restarted, but @@SERVERNAME still does not read "' + $expected +
                             '". Check the SQL Server error log.') 'ERROR'
                $script:Failed++
              }
            }catch{
              Write-YcLog ('  ' + $instName + ': the restart FAILED: ' + $_.Exception.Message +
                           '. The metadata change is already written and takes effect on the next restart.') 'ERROR'
              $script:Failed++
            }
          } else {
            Write-YcLog ('  ' + $instName + ': @@SERVERNAME is cached at startup, so it still reads "' + $cur +
                         '" until SQL Server restarts. This run did NOT restart it - fix-deploy does not take a ' +
                         'database down as a side effect. Finish it with either:') 'WARN'
            Write-YcLog ('      C:\Scripts\fix-deploy.cmd -Only sqlrename -RestartSql')
            Write-YcLog ('      Restart-Service -Name "' + $svcName + '" -Force')
          }
        } else {
          Write-YcLog ('  ' + $instName + ': sp_dropserver / sp_addserver FAILED: ' + $script:YcSqlErr) 'ERROR'
          $script:Failed++
        }
      }
    }

    # ---- stale login names. Cosmetic: the SID is what authenticates, so this can never
    # ---- lock anyone out. Skipped silently when there is nothing stale.
    $oldHost = ($cur -split '\\')[0]
    if($oldHost -and $oldHost -ne $machine){
      $lq = "SET NOCOUNT ON; SELECT name FROM sys.server_principals WHERE type IN ('U','G') AND name LIKE '" +
            (Get-YcSqlLiteral $oldHost) + "\%'"
      $lr = Invoke-YcSqlRows -Target $target -Query $lq
      if($null -ne $lr){
        foreach($lrow in $lr){
          $oldLogin = [string]$lrow['name']
          $suffix   = $oldLogin.Substring($oldHost.Length + 1)
          $newLogin = $machine + '\' + $suffix
          if($Report){
            Write-YcLog ('  WOULD rename login [' + $oldLogin + '] to [' + $newLogin + ']') 'WARN'
            $script:Would++
            continue
          }
          $al = "ALTER LOGIN [" + (Get-YcSqlBracket $oldLogin) + "] WITH NAME = [" + (Get-YcSqlBracket $newLogin) + "]"
          if(Invoke-YcSqlExec -Target $target -Query $al){
            Write-YcLog ('  ' + $instName + ': login [' + $oldLogin + '] renamed to [' + $newLogin + '] (same SID, same access).') 'OK'
            $script:Changed++
          } else {
            Write-YcLog ('  ' + $instName + ': could not rename login [' + $oldLogin + ']: ' + $script:YcSqlErr +
                         '. This is cosmetic - the login still works, because Windows logins authenticate by SID.') 'WARN'
          }
        }
      }
    }
  }

  # ---- orphaned Ola backup folders -------------------------------------------------
  # Ola's @Directory layout is <root>\<hostname>\<db>\<TYPE>. After a rename the new
  # hostname gets a new folder and @CleanupTime only ever prunes that one, so the old
  # folder is stranded and grows for ever. Read the roots out of the tasks that actually
  # run the backups rather than assuming the default.
  $backupRoots = @()
  foreach($bt in (Get-ScheduledTask -TaskName 'YC-SqlBackup*' -ErrorAction SilentlyContinue)){
    foreach($act in $bt.Actions){
      if("$($act.Arguments)" -match "@Directory\s*=\s*N'([^']+)'"){
        if($backupRoots -notcontains $Matches[1]){ $backupRoots += $Matches[1] }
      }
    }
  }
  if($backupRoots.Count -eq 0 -and (Test-Path -LiteralPath 'C:\dbbackupdaily')){ $backupRoots += 'C:\dbbackupdaily' }

  foreach($broot in $backupRoots){
    if(-not (Test-Path -LiteralPath $broot)){ continue }
    $live = Join-Path $broot $env:COMPUTERNAME
    foreach($od in (Get-ChildItem -LiteralPath $broot -Directory -ErrorAction SilentlyContinue)){
      if($od.Name -eq $env:COMPUTERNAME){ continue }
      $files = @(Get-ChildItem -LiteralPath $od.FullName -Recurse -File -ErrorAction SilentlyContinue)
      $mb    = if($files.Count -gt 0){ [math]::Round((($files | Measure-Object Length -Sum).Sum)/1MB,1) } else { 0 }
      Write-YcLog ('  ORPHANED backup folder: ' + $od.FullName + ' - ' + $files.Count + ' file(s), ' + $mb +
                   ' MB. This machine is now "' + $env:COMPUTERNAME + '", so Ola Hallengren writes to ' + $live +
                   ' and @CleanupTime will never prune the folder above. It grows for ever.') 'WARN'
      if(-not $MergeOrphanBackups){
        Write-YcLog ('  Not moving backup files without being asked. Re-run with -MergeOrphanBackups to fold them ' +
                     'under the current name so retention applies to them again, or delete the folder yourself.')
        continue
      }
      if($Report){
        Write-YcLog ('  WOULD move ' + $files.Count + ' file(s) from ' + $od.FullName + ' into ' + $live) 'WARN'
        $script:Would++
        continue
      }
      $moved = 0; $skipped = 0
      foreach($f in $files){
        $rel  = $f.FullName.Substring($od.FullName.Length).TrimStart('\')
        $dest = Join-Path $live $rel
        try{
          $dd = Split-Path -Parent $dest
          if(-not (Test-Path -LiteralPath $dd)){ New-Item -ItemType Directory -Path $dd -Force -ErrorAction Stop | Out-Null }
          if(Test-Path -LiteralPath $dest){
            Write-YcLog ('    already present at the destination, left where it is: ' + $f.FullName) 'WARN'
            $skipped++
            continue
          }
          Move-Item -LiteralPath $f.FullName -Destination $dest -ErrorAction Stop
          $moved++
        }catch{
          Write-YcLog ('    could not move ' + $f.FullName + ': ' + $_.Exception.Message) 'ERROR'
          $script:Failed++
        }
      }
      Write-YcLog ('  moved ' + $moved + ' file(s) into ' + $live + ($(if($skipped -gt 0){ ', ' + $skipped + ' left in place' }else{ '' }))) 'OK'
      if($moved -gt 0){ $script:Changed++ }
      # Only remove the old tree when it is genuinely empty. Never recursive-delete backups.
      if(@(Get-ChildItem -LiteralPath $od.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0){
        try{ Remove-Item -LiteralPath $od.FullName -Recurse -Force -ErrorAction Stop
             Write-YcLog ('  removed the now-empty ' + $od.FullName) 'OK' }
        catch{ Write-YcLog ('  could not remove the empty ' + $od.FullName + ': ' + $_.Exception.Message) 'WARN' }
      }
    }
  }
}

# Report mode changed nothing, so it must not claim anything is "in place" - that is the
# difference between a dry run and a lie.
if($Report){
  Write-YcLog ('REPORT ONLY - nothing was changed. ' + $script:Would + ' change(s) would be applied by a real run.') $(if($script:Would -gt 0){'WARN'}else{'OK'})
  Stop-YcLog 0; exit 0
}
Write-YcLog ('Done. ' + $script:Changed + ' change(s) applied, ' + $script:Failed + ' failure(s).')
if($script:Failed -gt 0){
  Write-YcLog 'One or more fixes could not be applied - this run is NOT a success.' 'ERROR'
  Stop-YcLog 2; exit 2
}
Write-YcLog 'All selected deployment fixes are in place.' 'OK'
Stop-YcLog 0
exit 0
