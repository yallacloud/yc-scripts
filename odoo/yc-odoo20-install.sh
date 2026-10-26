#!/bin/bash
# shellcheck disable=SC1090  # config files are written by this script
####################
# yc-odoo20-install.sh  v1.4.0  (2026-10-26 15:45 IST)  YallaCloud / OasisStack
# Odoo 20 Community + PostgreSQL 18 on Ubuntu 24.04 (CloudStack). Guide: STACK4-61.
#
# Normally started by yc-odoo20-userdata.sh (cloud-init), which writes the answers to
# /etc/yallacloud/odoo.conf.env. Manual: edit CONFIG, run as root. Re-run: yc-odoo-install
# ROLE=combined  DB + Odoo + nginx on one VM               (default)
# ROLE=db        PostgreSQL only. No domain, no public IP needed. Deploy FIRST.
# ROLE=app       Odoo + nginx only. Needs DB_HOST + DB_PASS from the db VM.
#
# ONE log for everything:  /var/log/yc-odoo-deploy.log  (userdata + installer + merged cloud-init)
# Result in one line:      /var/log/yc-odoo-deploy.status  (RUNNING / SUCCESS / FAILED step X)
# Credentials:             /root/odoo-info/handover.txt (chmod 600)
# Commands it leaves:      yallacloud (server card), odoo-domain, odoo-ssl, odoo-backup, yc-notify, yc-addons
# Below CONFIG there is nothing to edit.
####################
set -uo pipefail

# ==== CONFIG - defaults. cloud-init userdata overrides them (/etc/yallacloud/odoo.conf.env) ====
# -- 1. layout
ROLE="combined"              # combined | db | app
DOMAIN=""                    # blank = <public-ip>.sslip.io (or plain IP if private)
LE_EMAIL=""                  # Let's Encrypt contact (blank = register without email)
# -- 2. database
DB_HOST=""                   # app only: private IP of the db VM
DB_PASS=""                   # db/app: blank on db = generated; app = paste from db handover
APP_ALLOW=""                 # db only: CIDR allowed to 5432. blank = own private subnet
ODOO_DB="odoo"               # database created automatically (blank = skip)
PG_VERSION="18"              # PGDG major 16-19
# -- 3. network
PUBLIC_IP=""                 # NAT case: public IP forwarded to this VM (blank = auto)
GATEWAY=""                   # private VM behind a firewall: its LAN IP (blank = auto: .1/.254/.2)
SSH_PORT=""                  # blank = 3222 on a public IP, 22 on private
# -- 4. OS
TZ_SET="Asia/Dubai"
LOCALE_SET="en_US.UTF-8"
APT_MIRRORS="ae.archive.ubuntu.com archive.ubuntu.com"  # first that answers wins
# -- 5. backups (odoo-backup, cron)
BACKUP_DIR="/var/backups/odoo"   # local folder for the daily sets
BACKUP_KEEP_DAYS="15"            # sets older than this are deleted (1-365)
BACKUP_TIME="02:30"              # daily, HH:MM local time
# -- 6. reporting: ntfy (phone, never secrets) + YallaCloud ERP webhook (YCERP-01), each on/off
ENABLE_NTFY="yes"
NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="9890122212"
NTFY_TOKEN=""                    # only for a protected ntfy server
ENABLE_WEBHOOK="yes"
ERP_WEBHOOK_URL="https://api.yallacloud.net/api/v1/webhooks/cloudstack"
ERP_WEBHOOK_SECRET=""            # X-Webhook-Secret - REQUIRED by the ERP; paste at deploy time
ERP_WEBHOOK_TOKEN=""             # optional Authorization: Bearer <jwt>
WEBHOOK_SEND_SECRETS="yes"       # put the Odoo/DB passwords in the webhook fields (never in ntfy)
# -- 7. add-ons, run in the background after the deploy (never block or fail it)
ENABLE_SALT="yes"                # join the YallaCloud Salt master (zero-input, STACK4-54)
SALT_JOIN_URL="https://repo.oasisstack.io/salt/join.sh"
ENABLE_ACRONIS="yes"             # Acronis Cyber Protect agent - only runs when ACRONIS_TOKEN is set
ACRONIS_TOKEN=""                 # registration token from the Acronis console (secret)
ACRONIS_REGION="AE"              # AE = ae01-cloud.acronis.com | SG = sg-cloud.acronis.com
ACRONIS_SETUP_URL="https://repo.oasisstack.io/acronis/acronis-setup.sh"
# -- 8. advanced: sources and behaviour
PASS_URL="https://pass.oasisstack.io/?len=16"
DISABLE_CLOUD_INIT="yes"     # stops CloudStack re-running cloud-init every boot
ODOO_DEB_URL="https://github.com/yallacloud/yc-scripts/releases/download/odoo20-latest/odoo_20.0.latest_all.deb"
REPO_URL="https://repo.oasisstack.io/odoo"   # local mirror (ycwsus01, YC ranges): fallback when GitHub fails
# ================ nothing to edit below this line ================

VER=1.4.0
CFG=/etc/yallacloud/odoo.conf.env
LIB=/usr/local/lib/yc-odoo-common.sh
INFO=/root/odoo-info
NOTIFY_ENV=/etc/yallacloud/notify.env       # secrets of the reporting channels, root 600
LOG=/var/log/yc-odoo-deploy.log             # the ONE log: userdata + installer + cloud-init
STATUS=/var/log/yc-odoo-deploy.status
mkdir -p /etc/yallacloud "$INFO"; chmod 700 "$INFO"
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%F' '%T)] $*"; }
STEP=""; STEPS=""; WARNS=""; DIED=""
N(){ [ -x /usr/local/sbin/yc-notify ] && /usr/local/sbin/yc-notify "$@"; true; }
die(){
  echo "YC-FATAL: $*" | tee "$INFO/INSTALL-FAILED"; DIED=1
  echo "FAILED step ${STEP:-init}: $* ($(date '+%F %T %Z'))" > "$STATUS"
  N -t vm.deploy.failed -T "FAILED BUILD odoo ${ROLE:-?}" -p 5 -g rotating_light,odoo \
    --steps "${STEPS:+$STEPS }${STEP:-init}-" --failed-step "${STEP:-init}" --error "$*" \
    -l "result  FAILED at step ${STEP:-init}" -l "error   $*" -l "fix     read /var/log/yc-odoo-deploy.log, then: yc-odoo-install" \
    -f area=odoo -f role="${ROLE:-?}" -f status=failed -f summary="FAILED ${STEP:-init}: $*"
  exit 1; }
step(){ [ -n "$STEP" ] && STEPS="${STEPS:+$STEPS }$STEP+"; STEP=$1
        echo "RUNNING step $1 ($(date '+%F %T %Z'))" > "$STATUS"; say "== step $1"; }
skip(){ STEPS="${STEPS:+$STEPS }$1~"; }
# cloud-init's own logs go into the same file at the end (only when started by cloud-init)
merge_cloudinit(){
  [ -n "${YC_FROM_USERDATA:-}" ] || return 0
  echo "==== merged cloud-init logs ($(date '+%F %T %Z')) ===="
  cloud-init status --long 2>/dev/null | sed 's/^/cloud-init status | /'
  [ -f /var/log/cloud-init-output.log ] && awk '/userdata: /{exit} {print "cloud-init-output | " $0}' /var/log/cloud-init-output.log
  [ -f /var/log/cloud-init.log ] && sed 's/^/cloud-init.log | /' /var/log/cloud-init.log
  echo "==== end of merged cloud-init logs ===="
}
finish(){ local rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$DIED" ]; then DIED=1
    echo "FAILED step ${STEP:-?}: unexpected exit $rc ($(date '+%F %T %Z'))" > "$STATUS"
    N -t vm.deploy.failed -T "FAILED BUILD odoo ${ROLE:-?}" -p 5 -g rotating_light,odoo --steps "$STEPS ${STEP:-?}-" \
      --failed-step "${STEP:-?}" --error "unexpected exit $rc" -l "result  FAILED at step ${STEP:-?} (exit $rc)" -f area=odoo -f status=failed
  fi
  merge_cloudinit
  echo "RESULT: $(cat "$STATUS" 2>/dev/null)"
}
trap finish EXIT
[ "$(id -u)" = 0 ] || die "run as root"
echo "RUNNING step init ($(date '+%F %T %Z'))" > "$STATUS"
. /etc/os-release; [ "${ID}-${VERSION_ID}" = "ubuntu-24.04" ] || die "Ubuntu 24.04 only (found $PRETTY_NAME)"

# keep a copy so a re-run needs no userdata
[ -f "$CFG" ] && . "$CFG"          # earlier answers win on re-run
[ -f "$NOTIFY_ENV" ] && . "$NOTIFY_ENV"
SELF=$(readlink -f "$0"); [ "$SELF" != /usr/local/sbin/yc-odoo-install ] && install -m 700 "$SELF" /usr/local/sbin/yc-odoo-install
# == 0. check every input: required -> stop with the reason; optional -> warn + safe default
warn(){ say "WARN: $*"; WARNS="${WARNS:+$WARNS; }$*"; }
ip4(){ [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1; local n; for n in "${BASH_REMATCH[@]:1}"; do [ "$n" -le 255 ] || return 1; done; }
fqdn(){ [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }
ROLE=$(printf '%s' "$ROLE" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
case "$ROLE" in combined|db|app) ;; *) die "ROLE='$ROLE' - must be combined, db or app";; esac
DOMAIN=$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z' | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##')
if [ -n "$DOMAIN" ]; then
  if [ "$ROLE" = db ]; then warn "DOMAIN ignored on ROLE=db"; DOMAIN=""
  elif ! fqdn "$DOMAIN"; then warn "DOMAIN '$DOMAIN' is not a valid name - using sslip.io"; DOMAIN=""; fi
fi
[ -z "$LE_EMAIL" ] || [[ "$LE_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$ ]] || { warn "LE_EMAIL '$LE_EMAIL' invalid - no email"; LE_EMAIL=""; }
pw_safe(){ [[ "$1" =~ ^[A-Za-z0-9#]{8,64}$ ]]; }   # house rule: # is the only special character
if [ "$ROLE" = app ]; then
  [ -n "$DB_HOST" ] || die "ROLE=app needs DB_HOST (private IP of the db VM, from its handover.txt)"
  ip4 "$DB_HOST" || fqdn "$DB_HOST" || die "DB_HOST='$DB_HOST' is not an IPv4 address or host name"
  [ -n "$DB_PASS" ] || die "ROLE=app needs DB_PASS (from the db VM handover.txt)"
else
  [ -n "$DB_HOST" ] && { warn "DB_HOST ignored on ROLE=$ROLE (local PostgreSQL)"; DB_HOST=""; }
fi
[ -z "$DB_PASS" ] || pw_safe "$DB_PASS" || die "DB_PASS: 8-64 chars of A-Z a-z 0-9 and # only (# is the only special character allowed)"
if [ -n "$APP_ALLOW" ]; then
  ip4 "$APP_ALLOW" && APP_ALLOW="$APP_ALLOW/32"
  aa_ip=${APP_ALLOW%/*}; aa_m=${APP_ALLOW##*/}
  { [[ "$APP_ALLOW" == */* && "$aa_m" =~ ^[0-9]{1,2}$ ]] && [ "$aa_m" -le 32 ] && ip4 "$aa_ip"; } || { warn "APP_ALLOW '$APP_ALLOW' invalid - using own subnet"; APP_ALLOW=""; }
fi
[ -z "$ODOO_DB" ] || [[ "$ODOO_DB" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || { warn "ODOO_DB '$ODOO_DB' invalid - using odoo"; ODOO_DB=odoo; }
[[ "$PG_VERSION" =~ ^1[6-9]$ ]] || { warn "PG_VERSION '$PG_VERSION' invalid - using 18"; PG_VERSION=18; }
[ -f "/usr/share/zoneinfo/$TZ_SET" ] || { warn "TZ_SET '$TZ_SET' unknown - using Asia/Dubai"; TZ_SET=Asia/Dubai; }
[[ "$LOCALE_SET" =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]] || { warn "LOCALE_SET '$LOCALE_SET' invalid - using en_US.UTF-8"; LOCALE_SET=en_US.UTF-8; }
for m in $APT_MIRRORS; do fqdn "$m" || { warn "APT_MIRRORS '$APT_MIRRORS' invalid - default"; APT_MIRRORS="ae.archive.ubuntu.com archive.ubuntu.com"; break; }; done
[ -n "$APT_MIRRORS" ] || APT_MIRRORS="ae.archive.ubuntu.com archive.ubuntu.com"
if [ -n "$SSH_PORT" ]; then
  { [[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] && [[ ! " 80 443 5432 8069 8072 " == *" $SSH_PORT "* ]]; } || { warn "SSH_PORT '$SSH_PORT' invalid - auto"; SSH_PORT=""; }
fi
[[ "$PASS_URL" =~ ^https?:// ]] || PASS_URL="https://pass.oasisstack.io/?len=16"
case "$DISABLE_CLOUD_INIT" in yes|no) ;; *) DISABLE_CLOUD_INIT=yes;; esac
[ -z "$GATEWAY" ] || ip4 "$GATEWAY" || { warn "GATEWAY '$GATEWAY' invalid - auto"; GATEWAY=""; }
if [ -n "$PUBLIC_IP" ]; then
  ip4 "$PUBLIC_IP" || { warn "PUBLIC_IP '$PUBLIC_IP' invalid - auto"; PUBLIC_IP=""; }
fi
[[ "$REPO_URL" =~ ^https?:// ]] || REPO_URL="https://repo.oasisstack.io/odoo"
[[ "$ODOO_DEB_URL" =~ ^https?:// ]] || ODOO_DEB_URL="https://github.com/yallacloud/yc-scripts/releases/download/odoo20-latest/odoo_20.0.latest_all.deb"
yn(){ local v; v=$(printf '%s' "${!1}" | tr 'A-Z' 'a-z'); case "$v" in yes|y|true|1|on) printf -v "$1" yes;; no|n|false|0|off) printf -v "$1" no;; *) warn "$1='${!1}' must be yes|no - using $2"; printf -v "$1" '%s' "$2";; esac; }
yn ENABLE_NTFY yes; yn ENABLE_WEBHOOK yes; yn WEBHOOK_SEND_SECRETS yes
[[ "$BACKUP_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] && [ "$BACKUP_DIR" != / ] && [[ "$BACKUP_DIR" != *..* ]] || { warn "BACKUP_DIR '$BACKUP_DIR' invalid - using /var/backups/odoo"; BACKUP_DIR=/var/backups/odoo; }
BACKUP_DIR=${BACKUP_DIR%/}
{ [[ "$BACKUP_KEEP_DAYS" =~ ^[0-9]{1,3}$ ]] && [ "$BACKUP_KEEP_DAYS" -ge 1 ] && [ "$BACKUP_KEEP_DAYS" -le 365 ]; } || { warn "BACKUP_KEEP_DAYS '$BACKUP_KEEP_DAYS' invalid (1-365) - using 15"; BACKUP_KEEP_DAYS=15; }
[[ "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { warn "BACKUP_TIME '$BACKUP_TIME' invalid (HH:MM) - using 02:30"; BACKUP_TIME=02:30; }
[[ "$NTFY_SERVER" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || { warn "NTFY_SERVER '$NTFY_SERVER' invalid - using https://ntfy.sh"; NTFY_SERVER=https://ntfy.sh; }
NTFY_SERVER=${NTFY_SERVER%/}
[[ "$NTFY_TOPIC" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { [ "$ENABLE_NTFY" = yes ] && warn "NTFY_TOPIC '$NTFY_TOPIC' invalid - ntfy off"; ENABLE_NTFY=no; }
[ -z "$NTFY_TOKEN" ] || [[ "$NTFY_TOKEN" =~ ^[A-Za-z0-9_.-]{8,200}$ ]] || { warn "NTFY_TOKEN has bad characters - ignored"; NTFY_TOKEN=""; }
if [ "$ENABLE_WEBHOOK" = yes ]; then
  [[ "$ERP_WEBHOOK_URL" =~ ^https?://[^[:space:]]+$ ]] || { warn "ERP_WEBHOOK_URL '$ERP_WEBHOOK_URL' invalid - webhook off"; ENABLE_WEBHOOK=no; }
  [ -n "$ERP_WEBHOOK_SECRET$ERP_WEBHOOK_TOKEN" ] || warn "ERP_WEBHOOK_SECRET is blank - the ERP will refuse the events (set it and run: yc-notify --test)"
fi
yn ENABLE_SALT yes; yn ENABLE_ACRONIS yes
[[ "$SALT_JOIN_URL" =~ ^https://[^[:space:]]+$ ]] || { warn "SALT_JOIN_URL '$SALT_JOIN_URL' invalid - default"; SALT_JOIN_URL=https://repo.oasisstack.io/salt/join.sh; }
[[ "$ACRONIS_SETUP_URL" =~ ^https://[^[:space:]]+$ ]] || { warn "ACRONIS_SETUP_URL invalid - default"; ACRONIS_SETUP_URL=https://repo.oasisstack.io/acronis/acronis-setup.sh; }
ACRONIS_REGION=$(printf '%s' "$ACRONIS_REGION" | tr 'a-z' 'A-Z' | tr -d '[:space:]')
case "$ACRONIS_REGION" in AE|SG) ;; *) warn "ACRONIS_REGION '$ACRONIS_REGION' must be AE or SG - using AE"; ACRONIS_REGION=AE;; esac
ACRONIS_TOKEN=$(printf '%s' "$ACRONIS_TOKEN" | tr -d '[:space:]')
[ -z "$ACRONIS_TOKEN" ] || [[ "$ACRONIS_TOKEN" =~ ^[A-Za-z0-9-]{8,128}$ ]] || { warn "ACRONIS_TOKEN has bad characters - Acronis skipped"; ACRONIS_TOKEN=""; }
[ "$ENABLE_ACRONIS" = yes ] && [ -z "$ACRONIS_TOKEN" ] && say "acronis: ENABLE_ACRONIS=yes but no ACRONIS_TOKEN - Acronis will be skipped"
for v in ERP_WEBHOOK_SECRET ERP_WEBHOOK_TOKEN; do [[ "${!v}" =~ [[:space:]\"\'] ]] && { warn "$v contains spaces or quotes - ignored"; printf -v "$v" ''; }; done
say "config: ROLE=$ROLE DOMAIN=${DOMAIN:-<sslip>} DB_HOST=${DB_HOST:--} DB_PASS=$([ -n "$DB_PASS" ] && echo set || echo generate) APP_ALLOW=${APP_ALLOW:-auto} ODOO_DB=${ODOO_DB:-none} PG=$PG_VERSION TZ=$TZ_SET SSH=${SSH_PORT:-auto} PUBLIC_IP=${PUBLIC_IP:-auto} GATEWAY=${GATEWAY:-auto}"
say "config: BACKUP=$BACKUP_DIR keep ${BACKUP_KEEP_DAYS}d at $BACKUP_TIME  NTFY=$ENABLE_NTFY ($NTFY_SERVER/$NTFY_TOPIC)  WEBHOOK=$ENABLE_WEBHOOK ($ERP_WEBHOOK_URL, secret $([ -n "$ERP_WEBHOOK_SECRET" ] && echo set || echo NOT set), send secrets $WEBHOOK_SEND_SECRETS)  SALT=$ENABLE_SALT  ACRONIS=$ENABLE_ACRONIS (token $([ -n "$ACRONIS_TOKEN" ] && echo set || echo none), $ACRONIS_REGION)"

# == reporting tool (ntfy + ERP webhook) - installed first so a failure later is still reported
umask 077; printf '%s=%q\n' NTFY_TOKEN "$NTFY_TOKEN" ERP_WEBHOOK_SECRET "$ERP_WEBHOOK_SECRET" ERP_WEBHOOK_TOKEN "$ERP_WEBHOOK_TOKEN" ACRONIS_TOKEN "$ACRONIS_TOKEN" > "$NOTIFY_ENV"; umask 022
cat > /usr/local/sbin/yc-notify <<'NTFYEOF'
#!/usr/bin/env python3
# yc-notify v1.0.0 (2026-10-26) - YallaCloud Linux reporting: ntfy (phone) + YallaCloud ERP webhook
# (other team, yallacloud01, contract YCERP-01 - NOT ychook). Same event shape as the Windows
# C-Scripts payload so the ERP matches it by vmId = SMBIOS UUID.
#   yc-notify -t vm.deploy.completed -T "OK BUILD odoo combined" -p 3 -g white_check_mark,odoo \
#             -l "url  https://..." -f area=odoo -s odooAdminPassword=... [--steps "NET+ OS+"] \
#             [--failed-step PG --error "why"]
#   yc-notify --test      send a test event to both channels      yc-notify --show   settings (no secrets)
# -l lines go to ntfy AND the webhook; -f fields go to the webhook; -s fields are SECRETS:
# webhook only, and only when WEBHOOK_SEND_SECRETS=yes. ntfy never gets a secret.
# Settings: /etc/yallacloud/odoo.conf.env (switches) + notify.env (secrets, root 600). Failed webhook posts wait in
# /var/lib/yallacloud/notify-queue and go first on the next call (event.delivery.queued).
# Log: /var/log/yc-notify.log. Best effort: always exits 0 unless the arguments are wrong.
import argparse, datetime, glob, json, os, shlex, socket, ssl, subprocess, sys, time, urllib.request

CONF = '/etc/yallacloud/notify.env'          # secrets only: ERP_WEBHOOK_SECRET, ERP_WEBHOOK_TOKEN, NTFY_TOKEN
MAIN = '/etc/yallacloud/odoo.conf.env'       # switches + URLs (ENABLE_NTFY, NTFY_TOPIC, ...)
FACTS = '/etc/yallacloud/vm-facts.env'
QDIR = '/var/lib/yallacloud/notify-queue'
LOG = '/var/log/yc-notify.log'
CLOUD = 'CloudStack-{220e4496-d9e4-49a6-9fa0-3d1ca8b67382}'   # constant in YCERP-01


def envfile(path):
    d = {}
    try:
        for line in open(path, encoding='utf-8', errors='replace'):
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            try:
                tok = shlex.split(line, posix=True)
            except ValueError:
                continue
            if tok and '=' in tok[0]:
                k, v = tok[0].split('=', 1)
                d[k] = v
    except OSError:
        pass
    return d


def log(msg):
    line = time.strftime('%Y-%m-%d %H:%M:%S') + ' yc-notify: ' + msg
    print(line, flush=True)
    try:
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except OSError:
        pass


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ''


def facts():
    f = envfile(FACTS)
    try:
        uuid = open('/sys/class/dmi/id/product_uuid').read().strip().lower()
    except OSError:
        uuid = f.get('SMBIOS_UUID', '')
    osr = envfile('/etc/os-release')
    ip = sh("ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i==\"src\"){print $(i+1); exit}}'") or f.get('BIND_IP', '')
    st = os.statvfs('/')
    now = datetime.datetime.now().astimezone()
    tz = sh('timedatectl show -p Timezone --value') or ''
    return {
        'vmId': uuid, 'smbiosUuid': uuid, 'hostname': socket.gethostname(),
        'identitySource': 'smbios', 'cloud': CLOUD,
        'zone': f.get('MD_ZONE', ''), 'offering': f.get('MD_OFFERING', ''),
        'vmIdMismatch': bool(f.get('MD_VMID')) and f.get('MD_VMID', '').lower() != uuid,
        'routerVmId': f.get('MD_VMID', '') if f.get('MD_VMID', '').lower() != uuid else '',
        'vmName': f.get('MD_NAME', ''),
        'ip': ip, 'publicIp': f.get('PUBLIC', ''),
        'utc': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'lastUpdated': now.strftime('%Y-%m-%d %H:%M:%S %z') + (' ' + tz.split('/')[-1] if tz else ''),
        'os': osr.get('PRETTY_NAME', 'Linux'), 'osVersion': osr.get('VERSION_ID', '') + ' / ' + os.uname().release,
        'payload': f.get('INSTALLER_VERSION', ''), 'catalogue': f.get('INSTALLER_VERSION', ''),
        'freeGb': round(st.f_bavail * st.f_frsize / 1073741824, 1),
    }


def post(url, body, headers, timeout=20):
    req = urllib.request.Request(url, data=body, headers=headers, method='POST')
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return r.status, r.read(65536).decode('utf-8', 'replace')


def ascii_hdr(s):
    return s.encode('ascii', 'replace').decode('ascii')[:250]


def send_ntfy(c, a, fx):
    if c.get('ENABLE_NTFY', 'yes') != 'yes':
        return 'off'
    url = c.get('NTFY_SERVER', 'https://ntfy.sh').rstrip('/') + '/' + c.get('NTFY_TOPIC', '')
    if not c.get('NTFY_TOPIC'):
        return 'no topic'
    lines = list(a.line or [])
    if a.steps:
        lines.append('steps   ' + a.steps)
    if a.failed_step:
        lines.append('FAILED  step ' + a.failed_step + ': ' + (a.error or ''))
    lines += ['host    %s  %s%s' % (fx['hostname'], fx['ip'], ('  public ' + fx['publicIp']) if fx['publicIp'] else ''),
              'os      %s' % fx['os'],
              'time    %s  (%s)' % (fx['lastUpdated'], fx['utc']),
              'vm      %s%s' % (fx['vmName'] or '-', ('  zone ' + fx['zone']) if fx['zone'] else ''),
              'by      yc-notify / %s  log /var/log/yc-odoo-deploy.log' % (fx['payload'] or '-')]
    h = {'Title': ascii_hdr(a.title + ' - ' + fx['hostname']), 'Priority': str(a.priority),
         'Tags': ascii_hdr(a.tags or 'yallacloud'), 'Content-Type': 'text/plain; charset=utf-8'}
    if c.get('NTFY_TOKEN'):
        h['Authorization'] = 'Bearer ' + c['NTFY_TOKEN']
    try:
        s, _ = post(url, '\n'.join(lines).encode('utf-8'), h, 15)
        return 'ok %s' % s
    except Exception as e:  # never stop the caller
        return 'FAIL %s' % e


def send_webhook(c, a, fx):
    if c.get('ENABLE_WEBHOOK', 'yes') != 'yes':
        return 'off'
    url = c.get('ERP_WEBHOOK_URL', '')
    if not url:
        return 'no url'
    fields = {}
    for kv in (a.field or []):
        if '=' in kv:
            k, v = kv.split('=', 1)
            fields[k] = v
    if c.get('WEBHOOK_SEND_SECRETS', 'yes') == 'yes':
        for kv in (a.secret or []):
            if '=' in kv:
                k, v = kv.split('=', 1)
                fields[k] = v
    ev = dict(fx)
    ev.update({'type': a.type, 'steps': a.steps or '', 'extra': a.title, 'fields': fields,
               'saPassword': '', 'vmPassword': ''})
    if a.line:
        fields.setdefault('summary', ' | '.join(x.strip() for x in a.line[:6]))
    if a.failed_step:
        ev['failedStep'] = a.failed_step
        ev['error'] = a.error or ''
    h = {'Content-Type': 'application/json'}
    if c.get('ERP_WEBHOOK_SECRET'):
        h['X-Webhook-Secret'] = c['ERP_WEBHOOK_SECRET']
    if c.get('ERP_WEBHOOK_TOKEN'):
        h['Authorization'] = 'Bearer ' + c['ERP_WEBHOOK_TOKEN']
    os.makedirs(QDIR, mode=0o700, exist_ok=True)
    queued = sorted(glob.glob(QDIR + '/*.json'))
    for q in queued[:50]:                     # older events first, so history arrives in order
        try:
            post(url, open(q, 'rb').read(), h)
            os.remove(q)
        except Exception:
            break
    left = len(glob.glob(QDIR + '/*.json'))
    ev['delivery'] = {'queued': left}
    body = json.dumps(ev, separators=(',', ':')).encode('utf-8')
    try:
        s, txt = post(url, body, h)
        try:
            d = json.loads(txt).get('data', {})
        except ValueError:
            d = {}
        if d.get('applied') is True:            # YCERP-01: 200 + success is NOT success; applied is
            return 'ok %s applied %s' % (s, d.get('instanceNo', ''))
        return 'ok %s NOT applied (%s)' % (s, d.get('ignored', 'no reason given'))
    except Exception as e:
        qf = '%s/%s-%s.json' % (QDIR, time.strftime('%Y%m%d%H%M%S'), os.getpid())
        fd = os.open(qf, os.O_WRONLY | os.O_CREAT, 0o600)
        with os.fdopen(fd, 'wb') as f:
            f.write(body)
        for old in sorted(glob.glob(QDIR + '/*.json'))[:-200]:   # cap the queue
            os.remove(old)
        return 'FAIL %s (queued, %d waiting)' % (e, left + 1)


def main():
    p = argparse.ArgumentParser(prog='yc-notify')
    p.add_argument('-t', '--type', default='vm.event')
    p.add_argument('-T', '--title', default='YallaCloud event')
    p.add_argument('-p', '--priority', type=int, choices=range(1, 6), default=3)
    p.add_argument('-g', '--tags', default='')
    p.add_argument('-l', '--line', action='append')
    p.add_argument('-f', '--field', action='append')
    p.add_argument('-s', '--secret', action='append')
    p.add_argument('--steps', default='')
    p.add_argument('--failed-step', default='')
    p.add_argument('--error', default='')
    p.add_argument('--test', action='store_true')
    p.add_argument('--show', action='store_true')
    a = p.parse_args()
    c = envfile(MAIN)
    c.update(envfile(CONF))
    if a.show:
        for k in ('ENABLE_NTFY', 'NTFY_SERVER', 'NTFY_TOPIC', 'ENABLE_WEBHOOK', 'ERP_WEBHOOK_URL', 'WEBHOOK_SEND_SECRETS'):
            print('%-22s %s' % (k, c.get(k, '-')))
        print('%-22s %s' % ('ERP_WEBHOOK_SECRET', 'set' if c.get('ERP_WEBHOOK_SECRET') else 'NOT set'))
        print('%-22s %s' % ('ERP_WEBHOOK_TOKEN', 'set' if c.get('ERP_WEBHOOK_TOKEN') else 'not set'))
        print('%-22s %d' % ('queued webhook posts', len(glob.glob(QDIR + '/*.json'))))
        return 0
    if a.test:
        a.type, a.title, a.tags, a.line = 'vm.notify.test', 'TEST yc-notify', 'test_tube', ['test    reporting from this VM']
    fx = facts()
    log('%s "%s" ntfy=%s webhook=%s' % (a.type, a.title, send_ntfy(c, a, fx), send_webhook(c, a, fx)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
NTFYEOF
chmod 755 /usr/local/sbin/yc-notify

save_cfg(){   # effective answers, no secrets (those live in secrets.env / notify.env)
  local v; umask 077
  for v in ROLE DOMAIN LE_EMAIL DB_HOST APP_ALLOW ODOO_DB PG_VERSION PUBLIC_IP GATEWAY SSH_PORT TZ_SET LOCALE_SET APT_MIRRORS \
           BACKUP_DIR BACKUP_KEEP_DAYS BACKUP_TIME ENABLE_NTFY NTFY_SERVER NTFY_TOPIC ENABLE_WEBHOOK ERP_WEBHOOK_URL WEBHOOK_SEND_SECRETS \
           ENABLE_SALT SALT_JOIN_URL ENABLE_ACRONIS ACRONIS_REGION ACRONIS_SETUP_URL \
           PASS_URL DISABLE_CLOUD_INIT ODOO_DEB_URL REPO_URL; do printf '%s=%q\n' "$v" "${!v}"; done > "$CFG"
  umask 022; }
save_cfg

# == shared helper library
cat > "$LIB" <<'LIBEOF'
is_priv(){ [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|169\.254\.|127\.) ]]; }
# metadata: cloud-init cache, then the VR
md(){
  local k="$1" v="" s
  v=$(python3 -c "import json,sys;d=json.load(open('/run/cloud-init/instance-data.json'));print(d.get('ds',{}).get('meta_data',{}).get(sys.argv[1],'') or '')" "$k" 2>/dev/null)
  if [ -z "$v" ]; then
    for s in $(awk -F= '/^SERVER_ADDRESS=/{print $2}' /run/systemd/netif/leases/* 2>/dev/null) $(ip -4 route show default | awk '{print $3}'); do
      v=$(curl -fs --max-time 3 "http://$s/latest/meta-data/$k" 2>/dev/null) && [ -n "$v" ] && break
    done
  fi
  printf '%s' "$v" | tr -d '\r\n'
}
# BIND_IP: public NIC IP if the VM holds one (even with a private NIC too), else the private (SDN) IP.
# URL_IP : public NIC IP, else CloudStack static-NAT public IP from metadata, else BIND_IP.
detect_ips(){
  local ip; PUB_NIC=""; PRIV_NIC=""
  for ip in $(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1); do
    if is_priv "$ip"; then [ -z "$PRIV_NIC" ] && PRIV_NIC=$ip; else [ -z "$PUB_NIC" ] && PUB_NIC=$ip; fi
  done
  MD_PUB=$(md public-ipv4)
  BIND_IP=${PUB_NIC:-$PRIV_NIC}
  if [ -n "$PUB_NIC" ]; then URL_IP=$PUB_NIC
  elif [ -n "$MD_PUB" ] && ! is_priv "$MD_PUB"; then URL_IP=$MD_PUB
  else URL_IP=$BIND_IP; fi
  [ -n "${PUBLIC_IP:-}" ] && URL_IP=$PUBLIC_IP   # NAT/firewall public IP, set by hand
  PRIV_CIDR=$(ip -o -4 route show scope link | awk -v s="$PRIV_NIC" '$0 ~ "src "s {print $1; exit}')
}
# fetch URL OUT [nosha]: download, then check against URL.sha256 (unless nosha). 0 = file OK.
fetch(){
  rm -f "$2" "$2.sha256"
  curl -fsSL --retry 3 --connect-timeout 20 --speed-limit 10240 --speed-time 120 -o "$2" "$1" || { echo "fetch failed: $1" >&2; return 1; }
  [ "${3:-}" = nosha ] && return 0
  curl -fsSL --retry 3 --connect-timeout 20 -o "$2.sha256" "$1.sha256" || { echo "no sha256: $1" >&2; return 1; }
  [ "$(sha256sum "$2" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$2.sha256")" ] || { echo "sha256 mismatch: $1" >&2; return 1; }
}
# YallaCloud password rule (STACK4-52): 8-16 chars, first A-Z, last a-z, >=2 '#'
# (the ONLY special character), >=1 digit, both cases, no O 0 o I l 1. Local CSPRNG generator
# first (same code as the Nextcloud installer); pass.oasisstack.io is the fallback; both checked.
genpw_local(){
  local U="ABCDEFGHJKLMNPQRSTUVWXYZ" L="abcdefghijkmnpqrstuvwxyz" D="23456789" len=${1:-16}
  local A="${U}${L}${D}#" i j t n
  _p(){ local s="$1"; printf '%s' "${s:$(( $(od -An -N2 -tu2 /dev/urandom) % ${#s} )):1}"; }
  local -a m=('#' '#' "$(_p "$D")"); for i in $(seq 1 $((len-5))); do m+=("$(_p "$A")"); done
  n=${#m[@]}; for ((i=n-1;i>0;i--)); do j=$(( $(od -An -N2 -tu2 /dev/urandom) % (i+1) )); t=${m[i]}; m[i]=${m[j]}; m[j]=$t; done
  printf '%s%s%s\n' "$(_p "$U")" "$(IFS=; echo "${m[*]}")" "$(_p "$L")"
}
pw_ok(){ [[ "$1" =~ ^[A-Z][A-HJ-NP-Za-km-np-z2-9#]{6,14}[a-z]$ ]] && [[ "$1" == *#*#* ]] && [[ "$1" =~ [2-9] ]]; }
# gateway fix: a private VM behind a tenant firewall gets CloudStack's declared SDN gateway
# (often .254, nothing answers there) while the firewall is on .1. Public / VR networks: untouched.
gw_ok(){ ping -c 2 -W 2 -I "$2" "$1" >/dev/null 2>&1 || ip neigh show "$1" dev "$2" 2>/dev/null | grep -qE 'REACHABLE|STALE|DELAY|PERMANENT'; }
fix_gateway(){   # $1 = forced gateway (GATEWAY), blank = auto
  local dev ip gw c cands
  dev=$(ip -4 route show default | awk '{print $5; exit}'); [ -n "$dev" ] || dev=$(ip -o -4 addr show scope global | awk '{print $2; exit}')
  ip=$(ip -o -4 addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  gw=$(ip -4 route show default dev "$dev" 2>/dev/null | awk '{print $3; exit}')
  [ -n "$ip" ] || return 1
  if [ -n "${1:-}" ]; then cands=$1
  else
    [[ "$ip" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]] || { echo "gateway: public $ip via ${gw:-none} - nothing to fix"; return 0; }
    [ -n "$gw" ] && gw_ok "$gw" "$dev" && { echo "gateway: $gw answers (VR or firewall) - ok"; return 0; }
    cands="${ip%.*}.1 ${ip%.*}.254 ${ip%.*}.2"
  fi
  for c in $cands; do
    [ -z "${1:-}" ] && [ "$c" = "$gw" ] && continue
    gw_ok "$c" "$dev" || continue
    ip route replace default via "$c" dev "$dev" || continue
    mkdir -p /etc/netplan
    printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      routes:\n        - to: default\n          via: %s\n' "$dev" "$c" > /etc/netplan/99-yallacloud-gateway.yaml
    chmod 600 /etc/netplan/99-yallacloud-gateway.yaml
    echo "gateway: declared ${gw:-none} dead on $dev ($ip) - default route now via $c (persisted in netplan 99-yallacloud-gateway.yaml)"
    return 0
  done
  echo "gateway: nothing answers on ${cands// /, } for $dev ($ip)"; return 1
}
genpw(){
  local p; p=$(genpw_local 16)
  pw_ok "$p" || p=$(curl -fs --max-time 8 "${PASS_URL:-https://pass.oasisstack.io/?len=16}" 2>/dev/null | tr -d '\r\n')
  pw_ok "$p" || return 1
  printf '%s\n' "$p"
}
LIBEOF
. "$LIB"

# == 1. network + IPs
step NET
say "waiting for network"
for _ in $(seq 1 30); do ip -o -4 addr show scope global | grep -q . && break; sleep 2; done
say "$(fix_gateway "$GATEWAY")" || true
ip -4 route show default | grep -q . || die "no default route - set GATEWAY= to the firewall LAN IP"
detect_ips
[ -n "$BIND_IP" ] || die "no IPv4 address on any NIC"
[ -z "$SSH_PORT" ] && { [ -n "$PUB_NIC" ] && SSH_PORT=3222 || SSH_PORT=22; }
say "role=$ROLE bind=$BIND_IP url_ip=$URL_IP pub_nic=${PUB_NIC:-none} priv=${PRIV_NIC:-none} md_pub=${MD_PUB:-none} ssh=$SSH_PORT"
# facts for yc-notify (read once from the CloudStack router; SMBIOS stays the identity)
PUB_URL_IP=""; is_priv "$URL_IP" || PUB_URL_IP=$URL_IP
{ printf '%s=%q\n' SMBIOS_UUID "$(tr 'A-Z' 'a-z' < /sys/class/dmi/id/product_uuid 2>/dev/null)" BIND_IP "$BIND_IP" PUBLIC "$PUB_URL_IP" \
    MD_NAME "$(md local-hostname)" MD_VMID "$(md vm-id)" MD_INSTANCE "$(md instance-id)" MD_ZONE "$(md availability-zone)" \
    MD_OFFERING "$(md service-offering)" INSTALLER_VERSION "$VER"; } > /etc/yallacloud/vm-facts.env
N -t vm.deploy.started -T "START BUILD odoo $ROLE" -p 2 -g hourglass_flowing_sand,odoo \
  -l "role    $ROLE  ($([ "$ROLE" = combined ] && echo 'DB + Odoo' || { [ "$ROLE" = db ] && echo 'PostgreSQL only'; } || echo "Odoo, DB on $DB_HOST"))" \
  -l "ip      $BIND_IP  url ip $URL_IP" -l "domain  ${DOMAIN:-<sslip / ip>}" -l "pg      $PG_VERSION   tz $TZ_SET   ssh $SSH_PORT" \
  -f area=odoo -f role="$ROLE" -f status=started -f domain="$DOMAIN" -f installer="$VER"

# == 2. base OS: time, locale, apt
step OS
export DEBIAN_FRONTEND=noninteractive
timedatectl set-timezone "$TZ_SET" || true
locale-gen "$LOCALE_SET" >/dev/null && update-locale LANG="$LOCALE_SET" LC_ALL="$LOCALE_SET"
export LANG="$LOCALE_SET" LC_ALL="$LOCALE_SET"     # PG cluster is created with this -> UTF8

# Ubuntu repo fix: the template's mirror (Dubai/ae, cloudflare, eu ...) can stall.
# Probe each candidate, point every *.archive.ubuntu.com entry at the first that answers.
MIRROR=""
for m in $APT_MIRRORS; do
  curl -fsI --max-time 10 "http://$m/ubuntu/dists/noble/InRelease" >/dev/null 2>&1 && { MIRROR=$m; break; }
  say "mirror $m not answering"
done
[ -n "$MIRROR" ] || die "no apt mirror answered: $APT_MIRRORS"
for F in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
  [ -f "$F" ] && sed -i -E "s#https?://([a-z0-9.-]*\.)?archive\.ubuntu\.com/ubuntu#http://${MIRROR}/ubuntu#g" "$F"
done
# apt: retry, IPv4, wait for the first-boot unattended-upgrades lock instead of failing
printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::ForceIPv4 "true";\nDPkg::Lock::Timeout "900";\n' > /etc/apt/apt.conf.d/99yallacloud
mkdir -p /etc/needrestart/conf.d; echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/99-yallacloud.conf   # no prompts
say "apt mirror = $MIRROR"
apt-get update -q || die "apt update failed"
apt-get -y -q -o Dpkg::Options::=--force-confold upgrade
apt-get -y -q install curl ca-certificates gnupg ufw fail2ban chrony locales || die "base packages failed"
# time: estate NTP (ycwsus01, YC ranges) first, Ubuntu pool as fallback
printf 'server time.oasisstack.io iburst prefer\npool ntp.ubuntu.com iburst maxsources 4\n' > /etc/chrony/sources.d/yallacloud.sources
systemctl restart chrony; chronyc -a makestep >/dev/null 2>&1 || true

# PGDG repo: server on db/combined, client on app
install -d /usr/share/keyrings
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --yes -o /usr/share/keyrings/pgdg.gpg || die "PGDG key"
echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list

# swap: stops the OOM killer on report/import spikes
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
# kernel tuning - conservative values only, one drop-in file (delete it + sysctl --system to undo).
# Not touched on purpose: vm.overcommit_memory (Odoo forks workers), huge pages, I/O scheduler.
modprobe tcp_bbr 2>/dev/null && echo tcp_bbr > /etc/modules-load.d/yallacloud-bbr.conf
cat > /etc/sysctl.d/90-yallacloud-odoo.conf <<EOF
# YallaCloud Odoo - written by yc-odoo20-install $VER
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.vfs_cache_pressure = 50
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
# app <-> db through a firewall/NAT: keep idle connections alive (firewalls drop them silently)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.ip_nonlocal_bind = 1
EOF
lsmod | grep -q '^tcp_bbr' && printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >> /etc/sysctl.d/90-yallacloud-odoo.conf
sysctl -q --system || warn "some sysctl values were refused (see above)"
# transparent huge pages: madvise (PostgreSQL recommendation; Ubuntu default, enforced at boot)
printf 'w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise\nw /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise\n' > /etc/tmpfiles.d/yallacloud-thp.conf
systemd-tmpfiles --create /etc/tmpfiles.d/yallacloud-thp.conf 2>/dev/null || true
# open files: raised for the services that need it
for u in odoo nginx postgresql@; do mkdir -p "/etc/systemd/system/$u.service.d"; printf '[Service]\nLimitNOFILE=65536\n' > "/etc/systemd/system/$u.service.d/90-yallacloud-limits.conf"; done
systemctl daemon-reload

# == 3. SSH: root + password, no "login as ubuntu"
step SSH
cat > /etc/ssh/sshd_config.d/00-yallacloud.conf <<EOF
Port $SSH_PORT
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
# cloud-init prepends 'no-port-forwarding,...,command="echo Please login as the user ..."' - strip it.
[ -f /root/.ssh/authorized_keys ] && sed -i -E 's/^.*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9-]+@openssh\.com) /\1 /' /root/.ssh/authorized_keys
printf 'disable_root: false\nssh_pwauth: true\n' > /etc/cloud/cloud.cfg.d/99-yallacloud.cfg
install -d -m 755 /run/sshd   # missing when ssh.service is down; sshd -t needs it
sshd -t || die "sshd config invalid"
# 24.04 socket activation: the generator reads Port on daemon-reload; restart the socket, not the service.
systemctl daemon-reload
if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then systemctl stop ssh.service; systemctl restart ssh.socket; else systemctl restart ssh.service; fi
sleep 2; ss -ltn | grep -q ":$SSH_PORT " || die "sshd not listening on $SSH_PORT - check: journalctl -xeu ssh.service"
cat > /etc/fail2ban/jail.d/yallacloud.conf <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 6
bantime = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1; systemctl restart fail2ban

# == 4. secrets
step SECRETS
[ -f "$INFO/secrets.env" ] && . "$INFO/secrets.env"
: "${DB_PASS:=$(genpw)}"; : "${MASTER_PASS:=$(genpw)}"; : "${ADMIN_PASS:=$(genpw)}"
for v in DB_PASS MASTER_PASS ADMIN_PASS; do [ -n "${!v}" ] || die "password generation failed (local and pass.oasisstack.io)"; done
umask 077
printf "DB_PASS='%s'\nMASTER_PASS='%s'\nADMIN_PASS='%s'\n" "$DB_PASS" "$MASTER_PASS" "$ADMIN_PASS" > "$INFO/secrets.env"
umask 022

# == 5. PostgreSQL (db / combined)
RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo); CPUS=$(nproc)
pg_install(){
  apt-get update -q && apt-get -y -q install "postgresql-$PG_VERSION" "postgresql-client-$PG_VERSION" || die "postgresql-$PG_VERSION install failed"
  local pgram=$(( RAM_MB / 2 )); [ "$ROLE" = db ] && pgram=$RAM_MB    # combined: other half is Odoo's
  local sb=$(( pgram / 4 )) ecs=$(( pgram * 3 / 4 )) mwm=$(( pgram / 16 )) maxc=200 wm
  [ "$mwm" -gt 2048 ] && mwm=2048; [ "$mwm" -lt 64 ] && mwm=64
  wm=$(( (pgram - sb) / (maxc * 3) )); [ "$wm" -lt 4 ] && wm=4; [ "$wm" -gt 64 ] && wm=64
  local listen="localhost"; [ "$ROLE" = db ] && listen="localhost,${PRIV_NIC:-$BIND_IP}"
  cat > "/etc/postgresql/$PG_VERSION/main/conf.d/90-yallacloud-odoo.conf" <<EOF
# YallaCloud Odoo tuning - RAM ${RAM_MB}MB (PG budget ${pgram}MB), ${CPUS} vCPU, SSD
listen_addresses = '$listen'
max_connections = $maxc
shared_buffers = ${sb}MB
effective_cache_size = ${ecs}MB
maintenance_work_mem = ${mwm}MB
work_mem = ${wm}MB
wal_buffers = 16MB
min_wal_size = 1GB
max_wal_size = 4GB
checkpoint_completion_target = 0.9
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 100
max_parallel_workers = $CPUS
max_parallel_workers_per_gather = $(( CPUS > 2 ? 2 : 1 ))
# Odoo runs many short queries: JIT compile time costs more than it saves
jit = off
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
log_min_duration_statement = 2000
log_timezone = '$TZ_SET'
timezone = 'UTC'
# safe extras: smaller WAL, fewer forced checkpoints, faster vacuum on SSD, better diagnostics
wal_compression = on
checkpoint_timeout = 15min
max_worker_processes = $(( CPUS > 8 ? CPUS : 8 ))
max_parallel_maintenance_workers = $(( CPUS > 2 ? 2 : 1 ))
autovacuum_vacuum_cost_limit = 1000
huge_pages = try
track_io_timing = on
log_lock_waits = on
log_temp_files = 10MB
log_autovacuum_min_duration = 10s
log_checkpoints = on
# app VM behind a firewall: notice dead clients, keep NAT state alive
tcp_keepalives_idle = 300
tcp_keepalives_interval = 30
tcp_keepalives_count = 5
EOF
  if [ "$ROLE" = db ]; then
    [ -z "$APP_ALLOW" ] && APP_ALLOW=${PRIV_CIDR:-$BIND_IP/32}
    local hba="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
    grep -q "yallacloud-odoo" "$hba" || echo "host all odoo $APP_ALLOW scram-sha-256  # yallacloud-odoo" >> "$hba"
  fi
  systemctl restart "postgresql@$PG_VERSION-main" || die "postgresql failed to start - see /etc/postgresql/$PG_VERSION/main/conf.d/90-yallacloud-odoo.conf"
  # role odoo: CREATEDB, not superuser. pg_trgm/unaccent in template1 so new DBs have them.
  sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<SQL || die "role setup failed"
DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='odoo') THEN CREATE ROLE odoo LOGIN CREATEDB; END IF; END\$\$;
ALTER ROLE odoo WITH LOGIN CREATEDB NOSUPERUSER PASSWORD '$DB_PASS';
\c template1
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
SQL
  say "postgresql $PG_VERSION tuned: shared_buffers=${sb}MB cache=${ecs}MB work_mem=${wm}MB listen=$listen"
}
if [ "$ROLE" != app ]; then step PG; pg_install; else skip PG; fi

# == 6. firewall
step FW
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
ufw allow "$SSH_PORT/tcp" comment ssh >/dev/null
if [ "$ROLE" = db ]; then ufw allow from "$APP_ALLOW" to any port 5432 proto tcp comment odoo-app >/dev/null
else ufw allow 80/tcp comment http >/dev/null; ufw allow 443/tcp comment https >/dev/null; fi
ufw --force enable >/dev/null

# == 7. Odoo 20 CE (app / combined)
odoo_install(){
  # wkhtmltopdf: patched-Qt build (Ubuntu's own breaks PDF header/footer). Jammy build runs on noble.
  if ! wkhtmltopdf -V 2>/dev/null | grep -q 0.12.6; then
    fetch https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb /tmp/wkhtmltox.deb nosha \
      || fetch "${ODOO_DEB_URL%/*}/wkhtmltox_0.12.6.1-3.jammy_amd64.deb" /tmp/wkhtmltox.deb \
      || fetch "$REPO_URL/wkhtmltox_0.12.6.1-3.jammy_amd64.deb" /tmp/wkhtmltox.deb || die "wkhtmltox download failed (GitHub and $REPO_URL)"
    apt-get -y -q install /tmp/wkhtmltox.deb || die "wkhtmltox install failed"
  fi
  # Odoo .deb: GitHub release mirror first (nightly.odoo.com is unreliable), checked by .sha256;
  # fallback = nightly apt repo over http (key pinned by fingerprint, apt checks Release.gpg).
  local pkg=odoo
  if ! dpkg -s odoo >/dev/null 2>&1; then
    say "downloading Odoo deb (~330 MB): GitHub, then $REPO_URL"
    if fetch "$ODOO_DEB_URL" /tmp/odoo.deb || fetch "$REPO_URL/odoo_20.0.latest_all.deb" /tmp/odoo.deb; then
      chmod 644 /tmp/odoo.deb; pkg=/tmp/odoo.deb; say "odoo deb sha256 ok"
    else
      warn "GitHub and $REPO_URL odoo deb failed - last fallback nightly.odoo.com"
      curl -fsSL http://nightly.odoo.com/odoo.key | gpg --dearmor --yes -o /usr/share/keyrings/odoo.gpg || die "odoo key"
      gpg --show-keys --with-colons /usr/share/keyrings/odoo.gpg | grep -q '^fpr:::::::::5D134C924CB06330DCEFE2A1DEF2A2198183CBB5:' || die "odoo key fingerprint mismatch"
      echo "deb [signed-by=/usr/share/keyrings/odoo.gpg] http://nightly.odoo.com/20.0/nightly/deb/ ./" > /etc/apt/sources.list.d/odoo.list
    fi
  fi
  apt-get update -q || die "apt update (odoo/pgdg) failed"
  # no-install-recommends: keeps a local postgresql server off app VMs
  apt-get -y -q --no-install-recommends install "postgresql-client-$PG_VERSION" "$pkg" nginx certbot \
    fonts-dejavu-core fonts-noto-core fonts-liberation2 python3-phonenumbers python3-markdown2 || die "odoo install failed"
  systemctl stop odoo

  local workers cron soft hard appram
  [ "$ROLE" = combined ] && appram=$(( RAM_MB / 2 )) || appram=$(( RAM_MB - 512 ))
  workers=$(( CPUS * 2 + 1 ))
  local byram=$(( appram / 350 )); [ "$byram" -lt 2 ] && byram=2       # ~350MB per worker avg
  [ "$workers" -gt "$byram" ] && workers=$byram
  cron=1; [ "$CPUS" -ge 4 ] && cron=2
  soft=$(( appram * 2 / (workers + cron) )); [ "$soft" -gt 2048 ] && soft=2048; [ "$soft" -lt 640 ] && soft=640
  hard=$(( soft * 5 / 4 ))
  # every worker keeps its own pool: keep (workers + cron + 2) * db_maxconn under PG max_connections 200
  local maxconn=$(( 180 / (workers + cron + 2) )); [ "$maxconn" -gt 16 ] && maxconn=16; [ "$maxconn" -lt 4 ] && maxconn=4
  local dbh=False dbp=False dbport=False
  [ "$ROLE" = app ] && { dbh=$DB_HOST; dbp=$DB_PASS; dbport=5432; }
  # combined: unix socket + peer auth (system user odoo == role odoo), no password on the wire.
  install -d -o odoo -g odoo /var/lib/odoo /var/log/odoo
  cat > /etc/odoo/odoo.conf <<EOF
[options]
admin_passwd = $MASTER_PASS
db_host = $dbh
db_port = $dbport
db_user = odoo
db_password = $dbp
db_name = $ODOO_DB
dbfilter = ^${ODOO_DB}\$
list_db = False
db_maxconn = $maxconn
proxy_mode = True
http_interface = 127.0.0.1
http_port = 8069
gevent_port = 8072
data_dir = /var/lib/odoo
logfile = /var/log/odoo/odoo-server.log
log_level = warn
workers = $workers
max_cron_threads = $cron
limit_memory_soft = $(( soft * 1024 * 1024 ))
limit_memory_hard = $(( hard * 1024 * 1024 ))
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = 3600
limit_request = 65536
EOF
  [ -z "$ODOO_DB" ] && sed -i '/^db_name\|^dbfilter/d;s/^list_db = False/list_db = True/' /etc/odoo/odoo.conf
  chown odoo:odoo /etc/odoo/odoo.conf; chmod 640 /etc/odoo/odoo.conf
  printf '/var/log/odoo/*.log {\n  weekly\n  rotate 8\n  compress\n  missingok\n  copytruncate\n}\n' > /etc/logrotate.d/odoo-yallacloud
  say "odoo tuned: workers=$workers cron=$cron soft=${soft}MB hard=${hard}MB (app RAM ${appram}MB)"

  cd /var/lib/odoo || die "no /var/lib/odoo"   # odoo user cannot read /root
  if [ "$ROLE" = app ]; then           # db VM is deployed first; wait up to 15 min for it
    say "waiting for postgres at $DB_HOST:5432"
    for i in $(seq 1 90); do pg_isready -q -h "$DB_HOST" -p 5432 && break; [ "$i" = 90 ] && die "db $DB_HOST:5432 not reachable (ufw/pg_hba on db VM, APP_ALLOW?)"; sleep 10; done
  fi
  if [ -n "$ODOO_DB" ] && ! sudo -u odoo PGPASSWORD="$DB_PASS" psql -h "${DB_HOST:-/var/run/postgresql}" -U odoo -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$ODOO_DB'" | grep -q 1; then
    say "creating database $ODOO_DB (base, no demo) - a few minutes"
    sudo -u odoo odoo -c /etc/odoo/odoo.conf -d "$ODOO_DB" -i base --stop-after-init --no-http --logfile= --log-level=warn || die "database init failed - see $LOG"
    sudo -u odoo odoo shell -c /etc/odoo/odoo.conf -d "$ODOO_DB" --no-http --logfile= --log-level=warn <<PY || die "admin password set failed"
u = env.ref('base.user_admin'); u.password = """$ADMIN_PASS"""; u.tz = '$TZ_SET'
env.cr.commit()
PY
  fi
  systemctl enable --now odoo >/dev/null 2>&1 || die "odoo service failed"
}
if [ "$ROLE" != db ]; then step ODOO; odoo_install; else skip ODOO; fi

# == 8. odoo-domain command (nginx + cert + base url)
cat > /usr/local/sbin/odoo-domain <<'DOMEOF'
#!/bin/bash
# odoo-domain <fqdn> | --sslip | --ip | --show    (YallaCloud Odoo 20)
# A paid certificate installed with odoo-ssl (/etc/yallacloud/ssl/<fqdn>/) wins over Let's Encrypt.
set -uo pipefail
. /usr/local/lib/yc-odoo-common.sh; . /etc/yallacloud/odoo.conf.env
if [ "${1:-}" = --public ]; then PUBLIC_IP=$2; shift 2
  sed -i '/^PUBLIC_IP=/d' /etc/yallacloud/odoo.conf.env; echo "PUBLIC_IP=$PUBLIC_IP" >> /etc/yallacloud/odoo.conf.env; fi
INFO=/root/odoo-info; NG=/etc/nginx/sites-available/odoo
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
detect_ips
show(){ echo "URL      : $(cat $INFO/URL 2>/dev/null)"; echo "bind IP  : $BIND_IP  (url IP $URL_IP, public NIC ${PUB_NIC:-none})"
        systemctl is-active --quiet odoo && echo "odoo     : running" || echo "odoo     : DOWN"; echo "nginx    : $(systemctl is-active nginx) / $(systemctl is-enabled nginx)"; }
case "${1:---show}" in
  --show) show; exit 0;;
  --ip) HOST=""; MODE=ip;;
  --sslip) is_priv "$URL_IP" && { echo "private IP $URL_IP: sslip/LE impossible, using --ip"; HOST=""; MODE=ip; } || { HOST="${URL_IP//./-}.sslip.io"; MODE=fqdn; };;
  -*) echo "usage: odoo-domain [--public <ip>] <fqdn> | --sslip | --ip | --show"; exit 2;;
  *) HOST=$(printf '%s' "$1" | tr -d '[:space:]' | tr 'A-Z' 'a-z'); MODE=fqdn
     [[ "$HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] || { echo "bad domain: $HOST"; exit 2; };;
esac
mkdir -p "$INFO/backups"; [ -f "$NG" ] && cp -a "$NG" "$INFO/backups/odoo.nginx.$(date +%Y%m%d-%H%M%S)"
loc(){ cat <<EOF
    client_max_body_size 200m;
    proxy_read_timeout 720s; proxy_connect_timeout 720s; proxy_send_timeout 720s;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    location /websocket {
        proxy_pass http://odoochat;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location / { proxy_redirect off; proxy_pass http://odoo; }
    location ~* /web/static/ { proxy_cache_valid 200 90m; proxy_buffering on; expires 864000; proxy_pass http://odoo; }
    gzip on; gzip_comp_level 5; gzip_min_length 1024;
    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript image/svg+xml;
EOF
}
head_(){ cat <<EOF
upstream odoo { server 127.0.0.1:8069; keepalive 16; }
upstream odoochat { server 127.0.0.1:8072; }
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
EOF
}
write_http(){ { head_; echo "server {"; echo "    listen $BIND_IP:80 default_server;"; echo "    server_name ${HOST:-_};"
                echo "    location /.well-known/acme-challenge/ { root /var/www/html; }"; loc; echo "}"; } > "$NG"; }
CRT=""; KEY=""   # set before write_https: paid (/etc/yallacloud/ssl/<host>/) or Let's Encrypt
write_https(){ { head_
  echo "server { listen $BIND_IP:80 default_server; server_name _; location /.well-known/acme-challenge/ { root /var/www/html; } location / { return 301 https://$HOST\$request_uri; } }"
  echo "server {"; echo "    listen $BIND_IP:443 ssl http2;"; echo "    server_name $HOST;"
  echo "    ssl_certificate $CRT;"; echo "    ssl_certificate_key $KEY;"
  echo "    ssl_protocols TLSv1.2 TLSv1.3; ssl_session_cache shared:SSL:10m;"
  echo "    add_header Strict-Transport-Security \"max-age=31536000\" always;"; loc; echo "}"; } > "$NG"; }
reload(){ ln -sf "$NG" /etc/nginx/sites-enabled/odoo; rm -f /etc/nginx/sites-enabled/default
          nginx -t || { echo "nginx -t failed"; exit 3; }
          systemctl enable nginx >/dev/null 2>&1; systemctl restart nginx || { journalctl -u nginx -n 5 --no-pager; exit 3; }; }
write_http; reload
URL="http://${HOST:-$URL_IP}"
PAID=/etc/yallacloud/ssl/${HOST:-none}
if [ "$MODE" = fqdn ] && [ "$(cat "$PAID/TYPE" 2>/dev/null)" = paid ] && [ -s "$PAID/fullchain.pem" ] && [ -s "$PAID/privkey.pem" ]; then
  CRT=$PAID/fullchain.pem; KEY=$PAID/privkey.pem; write_https; reload; URL="https://$HOST"
  echo "TLS: paid certificate $PAID (renewal: odoo-ssl csr $HOST --reuse-key, then odoo-ssl install)"
elif [ "$MODE" = fqdn ]; then
  RES=$(getent ahostsv4 "$HOST" | awk '{print $1; exit}')
  CRT=/etc/letsencrypt/live/$HOST/fullchain.pem; KEY=/etc/letsencrypt/live/$HOST/privkey.pem
  if [ "$RES" != "$URL_IP" ]; then
    echo "DNS: $HOST -> ${RES:-nothing}, expected $URL_IP. Serving HTTP; re-run 'odoo-domain $HOST' once DNS is right."
  elif certbot certonly --webroot -w /var/www/html -n --agree-tos $([ -n "$LE_EMAIL" ] && echo "-m $LE_EMAIL" || echo --register-unsafely-without-email) -d "$HOST" --key-type ecdsa; then
    write_https; reload; URL="https://$HOST"
    install -d /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh; chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
    systemctl enable --now certbot.timer >/dev/null 2>&1
  else echo "certbot failed - serving HTTP (port 80 reachable from internet?)"; fi
fi
[ -n "$HOST" ] && hostnamectl set-hostname "$HOST"
echo "$URL" > "$INFO/URL"
# web.base.url so emails/links use the new host (Odoo also updates it on admin login).
if [ -n "${ODOO_DB:-}" ]; then
  sudo -u odoo odoo shell -c /etc/odoo/odoo.conf -d "$ODOO_DB" --no-http --logfile= --log-level=error >/dev/null 2>&1 <<PY
env['ir.config_parameter'].sudo().set_param('web.base.url', '$URL'); env.cr.commit()
PY
fi
show
DOMEOF
chmod 755 /usr/local/sbin/odoo-domain

# == 8b. odoo-ssl (free/paid certificates, full chain, PFX), odoo-backup, cron, logrotate
step TOOLS
cat > /usr/local/sbin/odoo-ssl <<'SSLEOF'
#!/bin/bash
# odoo-ssl - TLS certificates for this Odoo server (YallaCloud, STACK4-61). Free (Let's Encrypt) or paid.
#   odoo-ssl status                               every certificate: type, domain, issuer, expiry, days left
#   odoo-ssl free <fqdn>                          Let's Encrypt + automatic renewal (same as odoo-domain <fqdn>)
#   odoo-ssl csr <fqdn> [--org O] [--country CC] [--city C] [--reuse-key]
#                                                 paid cert APPLICATION: private key + CSR to give the CA
#   odoo-ssl install <fqdn> --cert FILE [--chain FILE] [--key FILE]
#                                                 paid cert from the CA (PEM/CRT/CER, DER or P7B bundle);
#                                                 builds + checks the full chain, installs, switches nginx
#   odoo-ssl install-pfx <fqdn> --pfx FILE [--pass PASSWORD]
#                                                 paid cert as PFX/P12 -> key + cert + chain -> install
#   odoo-ssl export-pfx <fqdn> [--pass PASSWORD] [--out FILE]
#                                                 current cert -> PFX (Windows/IIS, load balancers)
#   odoo-ssl check                                expiry warning (cron, daily): log + login banner < 30 days
set -uo pipefail
SSL=/etc/yallacloud/ssl; LE=/etc/letsencrypt/live; WARN=/var/lib/yallacloud/ssl-warn
N(){ local t=$1 ti=$2 p=$3 g=$4; shift 4; local a=(); for l in "$@"; do a+=(-l "$l"); done   # ntfy + ERP webhook, best effort
     [ -x /usr/local/sbin/yc-notify ] && /usr/local/sbin/yc-notify -t "$t" -T "$ti" -p "$p" -g "$g,odoo" -f area=odoo-ssl "${a[@]}" >/dev/null 2>&1; true; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
die(){ echo "odoo-ssl: $*" >&2; exit 1; }
fqdn_ok(){ [[ "$1" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }
days_left(){ local e; e=$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2) || return 1; echo $(( ($(date -d "$e" +%s) - $(date +%s)) / 86400 )); }
cert_line(){ printf '  %-6s %-36s %-30s expires %s (%s days)\n' "$1" "$2" "$(openssl x509 -noout -issuer -in "$3" | sed 's/.*O *= *//; s/,.*//' | cut -c1-30)" "$(openssl x509 -enddate -noout -in "$3" | cut -d= -f2)" "$(days_left "$3")"; }
# any certificate file (PEM, DER, PKCS7/P7B, several certs) -> PEM certificates on stdout
to_pem(){
  if grep -q 'BEGIN PKCS7' "$1" 2>/dev/null; then openssl pkcs7 -print_certs -in "$1" | sed -n '/BEGIN CERT/,/END CERT/p'
  elif grep -q 'BEGIN CERTIFICATE' "$1" 2>/dev/null; then sed -n '/BEGIN CERT/,/END CERT/p' "$1" | tr -d '\r'
  elif openssl x509 -inform DER -in "$1" >/dev/null 2>&1; then openssl x509 -inform DER -in "$1"
  elif openssl pkcs7 -inform DER -print_certs -in "$1" >/dev/null 2>&1; then openssl pkcs7 -inform DER -print_certs -in "$1" | sed -n '/BEGIN CERT/,/END CERT/p'
  else return 1; fi
}
pub(){ openssl "$1" -noout -pubkey -in "$2" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1; }
keypub(){ openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1; }

install_pem(){   # $1 fqdn, $2 leaf+maybe chain (PEM), $3 chain (PEM or empty), $4 key
  local d="$SSL/$1" t; t=$(mktemp -d); trap 'rm -rf "$t"' RETURN
  # split everything we were given into single certs, find the leaf = the one matching the key
  cat "$2" "$3" 2>/dev/null | awk -v d="$t" '/BEGIN CERT/{n++} n{print > (d "/c" n ".pem")} /END CERT/{close(d "/c" n ".pem")}'
  ls "$t"/c*.pem >/dev/null 2>&1 || die "no certificate found in the files given"
  openssl pkey -in "$4" -noout 2>/dev/null || die "private key unreadable (encrypted? run: openssl pkey -in KEY -out key.pem)"
  local kp leaf="" c; kp=$(keypub "$4")
  for c in "$t"/c*.pem; do [ "$(pub x509 "$c")" = "$kp" ] && { leaf=$c; break; }; done
  [ -n "$leaf" ] || die "private key does not match any certificate given (wrong key or wrong cert)"
  openssl x509 -noout -checkend 0 -in "$leaf" >/dev/null || die "certificate is EXPIRED: $(openssl x509 -enddate -noout -in "$leaf")"
  openssl x509 -noout -checkhost "$1" -in "$leaf" | grep -q 'does match' || die "certificate does not cover $1 (names: $(openssl x509 -noout -ext subjectAltName -in "$leaf" 2>/dev/null | tail -n +2 | tr -d ' '))"
  # full chain = leaf first, then intermediates (self-signed roots left out, duplicates dropped)
  : > "$t/chain.pem"
  for c in "$t"/c*.pem; do
    [ "$c" = "$leaf" ] && continue
    [ "$(openssl x509 -noout -subject -in "$c")" = "subject=$(openssl x509 -noout -issuer -in "$c" | sed 's/^issuer=//')" ] && continue
    grep -qF "$(sed -n 2p "$c")" "$t/chain.pem" || cat "$c" >> "$t/chain.pem"
  done
  cat "$leaf" "$t/chain.pem" > "$t/fullchain.pem"
  if openssl verify -untrusted "$t/chain.pem" "$leaf" >/dev/null 2>&1; then echo "chain   : complete (verifies against the system CA store)"
  else echo "chain   : WARNING - does not verify; ask the CA for the intermediate/bundle file and re-run with --chain"; fi
  [ -d "$d" ] && { mkdir -p "$d/old"; tar -czf "$d/old/$(date +%Y%m%d-%H%M%S).tgz" -C "$d" --exclude=old --exclude=request . 2>/dev/null; }
  install -d -m 700 "$d"
  install -m 644 "$leaf" "$d/cert.pem"; install -m 644 "$t/chain.pem" "$d/chain.pem"; install -m 644 "$t/fullchain.pem" "$d/fullchain.pem"
  install -m 600 "$4" "$d/privkey.pem"; echo paid > "$d/TYPE"
  N "vm.odoo.ssl.installed" "SSL PAID installed $1" 3 lock "cert    $1 paid, $(openssl x509 -noout -enddate -in "$d/cert.pem" | cut -d= -f2)" "issuer  $(openssl x509 -noout -issuer -in "$d/cert.pem" | sed 's/.*O *= *//; s/,.*//')"
  echo "install : $d (fullchain.pem, privkey.pem) - $(openssl x509 -noout -subject -enddate -in "$leaf" | tr '\n' ' ')"
  /usr/local/sbin/odoo-domain "$1"
}

cmd=${1:-status}; shift || true
case "$cmd" in
  status)
    echo "TLS certificates ($(hostname))"; n=0
    for c in "$SSL"/*/fullchain.pem; do [ -f "$c" ] && { cert_line paid "$(basename "$(dirname "$c")")" "$c"; n=1; }; done
    for c in "$LE"/*/fullchain.pem; do [ -f "$c" ] && { cert_line free "$(basename "$(dirname "$c")")" "$c"; n=1; }; done
    [ $n = 1 ] || echo "  none (site is plain HTTP)"
    echo "  in use : $(grep -m1 -o 'ssl_certificate [^;]*' /etc/nginx/sites-available/odoo 2>/dev/null | cut -d' ' -f2 || echo -)"
    echo "  free renewal: certbot.timer $(systemctl is-active certbot.timer 2>/dev/null) + cron /etc/cron.d/yallacloud-odoo (03:15, 15:15)";;
  free)
    h=${1:-}; fqdn_ok "$h" || die "usage: odoo-ssl free <fqdn>"
    [ -d "$SSL/$h" ] && { mv "$SSL/$h" "$SSL/$h.paid-$(date +%Y%m%d-%H%M%S)"; echo "paid cert for $h moved aside"; }
    /usr/local/sbin/odoo-domain "$h";;
  csr)
    h=${1:-}; shift || true; fqdn_ok "$h" || die "usage: odoo-ssl csr <fqdn> [--org O] [--country CC] [--city C] [--reuse-key]"
    org="" cc="AE" city="Dubai" reuse=no
    while [ $# -gt 0 ]; do case "$1" in --org) org=$2; shift 2;; --country) cc=$2; shift 2;; --city) city=$2; shift 2;; --reuse-key) reuse=yes; shift;; *) die "unknown option $1";; esac; done
    r="$SSL/$h/request"; install -d -m 700 "$r"
    if [ "$reuse" = yes ] && [ -f "$SSL/$h/privkey.pem" ]; then cp "$SSL/$h/privkey.pem" "$r/privkey.pem"
    else openssl genrsa -out "$r/privkey.pem" 2048 2>/dev/null; fi
    chmod 600 "$r/privkey.pem"
    subj="/C=$cc/L=$city/CN=$h"; [ -n "$org" ] && subj="/C=$cc/L=$city/O=$org/CN=$h"
    san="DNS:$h"; [[ "$h" == \*.* ]] || [[ "$h" == www.* ]] || san="$san,DNS:www.$h"
    openssl req -new -key "$r/privkey.pem" -out "$r/$h.csr" -subj "$subj" -addext "subjectAltName=$san" || die "CSR failed"
    echo "key  : $r/privkey.pem   (stays on this server - never send it)"
    echo "CSR  : $r/$h.csr   (paste this into the CA order form)"; echo; cat "$r/$h.csr"; echo
    echo "When the CA sends the certificate:  odoo-ssl install $h --cert <file.crt> --chain <ca-bundle>";;
  install)
    h=${1:-}; shift || true; fqdn_ok "$h" || die "usage: odoo-ssl install <fqdn> --cert FILE [--chain FILE] [--key FILE]"
    cert="" chain="" key="$SSL/$h/request/privkey.pem"
    while [ $# -gt 0 ]; do case "$1" in --cert) cert=$2; shift 2;; --chain) chain=$2; shift 2;; --key) key=$2; shift 2;; *) die "unknown option $1";; esac; done
    [ -f "$cert" ] || die "--cert file missing"; [ -f "$key" ] || die "--key file missing ($key) - give --key, or create the CSR with: odoo-ssl csr $h"
    t=$(mktemp -d); to_pem "$cert" > "$t/in.pem" || die "cannot read $cert as PEM, DER or P7B"
    : > "$t/ch.pem"; [ -z "$chain" ] || { [ -f "$chain" ] && to_pem "$chain" > "$t/ch.pem"; } || die "cannot read chain $chain"
    tr -d '\r' < "$key" > "$t/key.pem"
    install_pem "$h" "$t/in.pem" "$t/ch.pem" "$t/key.pem"; rm -rf "$t";;
  install-pfx)
    h=${1:-}; shift || true; fqdn_ok "$h" || die "usage: odoo-ssl install-pfx <fqdn> --pfx FILE [--pass PASSWORD]"
    pfx="" ; export PFXPASS=""
    while [ $# -gt 0 ]; do case "$1" in --pfx) pfx=$2; shift 2;; --pass) PFXPASS=$2; shift 2;; *) die "unknown option $1";; esac; done
    [ -f "$pfx" ] || die "--pfx file missing"
    t=$(mktemp -d); L=""
    openssl pkcs12 -in "$pfx" -passin env:PFXPASS -nokeys -noout 2>/dev/null || L=-legacy   # old RC2/3DES PFX need -legacy on OpenSSL 3
    openssl pkcs12 $L -in "$pfx" -passin env:PFXPASS -nocerts -nodes -out "$t/key.pem" 2>/dev/null || die "cannot open PFX (wrong --pass?)"
    openssl pkcs12 $L -in "$pfx" -passin env:PFXPASS -nokeys -out "$t/all.pem" 2>/dev/null || die "no certificates in PFX"
    sed -n '/BEGIN CERT/,/END CERT/p' "$t/all.pem" > "$t/in.pem"; openssl pkey -in "$t/key.pem" -out "$t/key2.pem" 2>/dev/null || die "no private key in PFX"
    install_pem "$h" "$t/in.pem" /dev/null "$t/key2.pem"; rm -rf "$t";;
  export-pfx)
    h=${1:-}; shift || true; fqdn_ok "$h" || die "usage: odoo-ssl export-pfx <fqdn> [--pass PASSWORD] [--out FILE]"
    export PFXPASS="" ; out="/root/odoo-info/$h.pfx"
    while [ $# -gt 0 ]; do case "$1" in --pass) PFXPASS=$2; shift 2;; --out) out=$2; shift 2;; *) die "unknown option $1";; esac; done
    d="$SSL/$h"; [ -f "$d/fullchain.pem" ] || d="$LE/$h"; [ -f "$d/fullchain.pem" ] || die "no certificate for $h (see odoo-ssl status)"
    [ -n "$PFXPASS" ] || { . /usr/local/lib/yc-odoo-common.sh; PFXPASS=$(genpw) || die "password generation failed"; echo "pfx password: $PFXPASS  (house rule; keep it with the file)"; }
    openssl pkcs12 -export -inkey "$d/privkey.pem" -in "$d/fullchain.pem" -name "$h" -passout env:PFXPASS -out "$out" || die "export failed"
    chmod 600 "$out"; echo "pfx : $out  (key + certificate + chain; import on Windows/IIS with the password)";;
  check)
    mkdir -p "$(dirname "$WARN")"; : > "$WARN"
    for c in "$SSL"/*/fullchain.pem "$LE"/*/fullchain.pem; do
      [ -f "$c" ] || continue; dl=$(days_left "$c"); h=$(basename "$(dirname "$c")"); ty=free; [[ "$c" == "$SSL"/* ]] && ty=paid
      echo "$(date '+%F %T') $ty $h $dl days left"
      if [ "$dl" -lt 30 ]; then
        [ $ty = paid ] && echo "  SSL: PAID certificate for $h expires in $dl days - renew: odoo-ssl csr $h --reuse-key, then odoo-ssl install" >> "$WARN"
        [ $ty = free ] && [ "$dl" -lt 20 ] && echo "  SSL: free certificate for $h expires in $dl days and did not renew - check: certbot renew --dry-run" >> "$WARN"
      fi
    done
    [ -s "$WARN" ] && N vm.odoo.ssl.expiring "SSL EXPIRING on $(hostname)" 4 warning "$(sed 's/^ *//' "$WARN" | head -3)"; true;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
SSLEOF
cat > /usr/local/sbin/odoo-backup <<'BAKEOF'
#!/bin/bash
# shellcheck disable=SC2024,SC2010,SC2045  # root writes the dump files on purpose; set names are fixed
# odoo-backup - database (+ filestore) backups, kept BACKUP_KEEP_DAYS days (YallaCloud, STACK4-61)
#   odoo-backup run                      back up now (what cron runs daily at BACKUP_TIME, default 02:30)
#   odoo-backup list                     backup sets, size, databases
#   odoo-backup restore <set> <db> --yes restore one database (+ its filestore) from a set - overwrites it
# Set = <BACKUP_DIR>/<YYYY-MM-DD_HHMM>/ with <db>.dump (pg_dump custom format), <db>.filestore.tgz
# (app/combined), globals.sql (db/combined: roles), MANIFEST. Status: /var/lib/yallacloud/backup.status
set -uo pipefail
. /etc/yallacloud/odoo.conf.env 2>/dev/null
DIR=${BACKUP_DIR:-/var/backups/odoo}; KEEP=${BACKUP_KEEP_DAYS:-15}; C=/etc/odoo/odoo.conf
ST=/var/lib/yallacloud/backup.status; FS=/var/lib/odoo/filestore
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
cd /tmp || exit 1   # sudo -u postgres cannot enter /root
oc(){ awk -F' *= *' -v k="$1" '$1==k{print $2; exit}' "$C" 2>/dev/null; }
# psql/pg_dump as the right user: db/combined = local postgres superuser, app = role odoo on DB_HOST
if [ "${ROLE:-combined}" = app ]; then
  PGHOST=$(oc db_host); PGPORT=$(oc db_port); PGUSER=odoo; PGPASSWORD=$(oc db_password); export PGHOST PGPORT PGUSER PGPASSWORD
  q(){ psql -d postgres -At -c "$1"; }; dump(){ pg_dump -Fc -Z 6 -d "$1" -f "$2"; }; rest(){ pg_restore --clean --if-exists --no-owner --role=odoo -d "$1" "$2"; }
else
  q(){ sudo -u postgres psql -d postgres -At -c "$1"; }; dump(){ sudo -u postgres pg_dump -Fc -Z 6 -d "$1" > "$2"; }; rest(){ sudo -u postgres pg_restore --clean --if-exists -d "$1" "$2"; }
fi
dbs(){ q "select datname from pg_database where not datistemplate and datname not in ('postgres')"; }

run(){
  exec 9>/run/odoo-backup.lock; flock -n 9 || { echo "another backup is running"; exit 1; }
  local set; set="$DIR/$(date +%Y-%m-%d_%H%M)"; install -d -m 700 "$DIR" "$set"; mkdir -p "$(dirname "$ST")"
  local last need free fail=0 n=0 d
  last=$(du -sb "$(ls -d "$DIR"/20* 2>/dev/null | grep -v "$set" | tail -1)" 2>/dev/null | cut -f1); need=$(( ${last:-0} * 2 ))
  free=$(df -B1 --output=avail "$DIR" | tail -1)
  if [ "$need" -gt "$free" ]; then echo "$(date '+%F %T') FAIL not enough space in $DIR (need ~$((need/1048576)) MB, free $((free/1048576)) MB)" | tee "$ST"; rmdir "$set"
    [ -x /usr/local/sbin/yc-notify ] && /usr/local/sbin/yc-notify -t vm.odoo.backup.failed -T "BACKUP FAIL disk full" -p 4 -g floppy_disk,warning,odoo -f area=odoo-backup -l "result  $(cat "$ST")" >/dev/null 2>&1; exit 1; fi
  local list; list=$(dbs) || { echo "$(date '+%F %T') FAIL cannot list databases" | tee "$ST"; rmdir "$set"; exit 1; }
  for d in $list; do
    n=$((n+1))
    if dump "$d" "$set/$d.dump"; then echo "dump  $d $(du -h "$set/$d.dump" | cut -f1)"; else echo "FAIL  dump $d"; fail=$((fail+1)); fi
    if [ "${ROLE:-combined}" != db ] && [ -d "$FS/$d" ]; then
      tar -czf "$set/$d.filestore.tgz" -C "$FS" "$d" && echo "files $d $(du -h "$set/$d.filestore.tgz" | cut -f1)" || { echo "FAIL  filestore $d"; fail=$((fail+1)); }
    fi
  done
  [ "${ROLE:-combined}" != app ] && { sudo -u postgres pg_dumpall --globals-only > "$set/globals.sql" 2>/dev/null || fail=$((fail+1)); }
  { echo "host $(hostname)  role ${ROLE:-?}  date $(date '+%F %T %Z')"; echo "odoo $(dpkg-query -W -f='${Version}' odoo 2>/dev/null || echo -)  postgres $(pg_dump -V | awk '{print $3}')"
    echo "databases: $list"; (cd "$set" && sha256sum ./*); } > "$set/MANIFEST"
  chmod -R go-rwx "$set"
  find "$DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"$((KEEP-1))" -print -exec rm -rf {} + | sed 's/^/expired /'
  local r=OK; [ $fail -gt 0 ] && r="FAIL ($fail errors)"; [ $n -eq 0 ] && r="WARN no databases"
  echo "$(date '+%F %T') $r set $set size $(du -sh "$set" | cut -f1) dbs $n keep ${KEEP}d sets $(ls -d "$DIR"/20* 2>/dev/null | wc -l)" | tee "$ST"
  if [ "$r" != OK ] && [ -x /usr/local/sbin/yc-notify ]; then
    /usr/local/sbin/yc-notify -t vm.odoo.backup.failed -T "BACKUP $r" -p 4 -g floppy_disk,warning,odoo -f area=odoo-backup -f status=failed -l "result  $(cat "$ST")" -l "log     /var/log/yc-odoo-backup.log" >/dev/null 2>&1
  fi
  [ $fail -eq 0 ]
}
case "${1:-}" in
  run) run;;
  list) echo "backups in $DIR (kept $KEEP days, daily ${BACKUP_TIME:-02:30}):"; for s in $(ls -d "$DIR"/20* 2>/dev/null); do printf '  %-18s %8s  %s\n' "$(basename "$s")" "$(du -sh "$s" | cut -f1)" "$(sed -n 3p "$s/MANIFEST" 2>/dev/null)"; done
        echo "last run: $(cat "$ST" 2>/dev/null || echo never)";;
  restore)
    s="$DIR/${2:-x}"; d=${3:-}; [ -f "$s/$d.dump" ] || { echo "usage: odoo-backup restore <set> <db> --yes   (see: odoo-backup list)"; exit 2; }
    [ "${4:-}" = --yes ] || { echo "this OVERWRITES database $d with $s - add --yes"; exit 2; }
    systemctl stop odoo 2>/dev/null
    [ -n "$(q "select 1 from pg_database where datname='$d'")" ] || q "create database \"$d\" owner odoo" >/dev/null
    rest "$d" "$s/$d.dump" && echo "database $d restored"
    [ -f "$s/$d.filestore.tgz" ] && { rm -rf "${FS:?}/$d"; tar -xzf "$s/$d.filestore.tgz" -C "$FS" && chown -R odoo:odoo "$FS/$d" && echo "filestore $d restored"; }
    systemctl start odoo 2>/dev/null; true;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
BAKEOF
cat > /usr/local/sbin/yc-addons <<'ADDEOF'
#!/bin/bash
# yc-addons salt|acronis|status - Salt join + Acronis agent for this VM (YallaCloud, STACK4-61)
# Started in the background at the end of the deploy (systemd-run), so they never hold up or fail
# the Odoo build. Safe to run again by hand. Each result goes to the deploy log, ntfy and the
# ERP webhook (vm.salt.* / vm.acronis.*). The Acronis token is never written to a log or ntfy.
#   salt    : zero-input join (STACK4-54 s17) -> id <cloudstack-domain>-<vm name>, retry cron by itself
#   acronis : acronis-setup.sh TOKEN AE|SG (repo.oasisstack.io/acronis). No token = skipped.
# Switches + values: ENABLE_SALT, SALT_JOIN_URL, ENABLE_ACRONIS, ACRONIS_REGION, ACRONIS_SETUP_URL
# in /etc/yallacloud/odoo.conf.env; ACRONIS_TOKEN in /etc/yallacloud/notify.env (root 600).
set -uo pipefail
. /etc/yallacloud/odoo.conf.env 2>/dev/null
. /etc/yallacloud/notify.env 2>/dev/null
LOG=/var/log/yc-odoo-deploy.log
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
cd /tmp || exit 1
say(){ echo "[$(date +%F' '%T)] addon $*" | tee -a "$LOG"; }
N(){ [ -x /usr/local/sbin/yc-notify ] && /usr/local/sbin/yc-notify "$@" >>"$LOG" 2>&1; true; }
fetch(){   # URL OUT : download, and check URL.sha256 when the server publishes one
  curl -fsSL --retry 3 --connect-timeout 20 -m 300 -o "$2" "$1" || return 1
  if curl -fsSL --connect-timeout 10 -m 30 -o "$2.sha256" "$1.sha256" 2>/dev/null; then
    [ "$(sha256sum "$2" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$2.sha256")" ] || { echo "sha256 mismatch: $1"; return 1; }
  fi; }

salt_join(){
  [ "${ENABLE_SALT:-yes}" = yes ] || { say "salt: off (ENABLE_SALT=no)"; return 0; }
  local f=/var/lib/yc-salt/join.sh r rc; mkdir -p /var/lib/yc-salt
  if ! fetch "${SALT_JOIN_URL:-https://repo.oasisstack.io/salt/join.sh}" "$f"; then
    r="FAILED: cannot download ${SALT_JOIN_URL:-}"; rc=6
  else
    r=$(sh "$f" 2>&1 </dev/null); rc=$?
    printf '%s\n' "$r" | sed 's/^/[salt] /' >> "$LOG"
    r=$(printf '%s\n' "$r" | grep -E '^(JOINED|CONFIGURED|WAITING:|FAILED:)' | tail -1); r=${r:-FAILED: no result line (rc $rc)}
  fi
  say "salt: $r"
  local t=vm.salt.failed p=4 g=x st=failed
  case "$r" in JOINED*) t=vm.salt.joined p=3 g=white_check_mark st=joined;; WAITING*) t=vm.salt.waiting p=4 g=hourglass st=waiting;; esac
  N -t "$t" -T "SALT ${st^^}" -p "$p" -g "$g,salt" -l "result  $r" \
    -l "retry   $([ -f /etc/cron.d/yc-salt-join ] && echo '/etc/cron.d/yc-salt-join every 15 min until JOINED' || echo none needed)" \
    -l "log     /var/lib/yc-salt/last.log" -f area=salt -f status="$st" -f summary="$r"
  return "$rc"
}

acronis(){
  [ "${ENABLE_ACRONIS:-yes}" = yes ] || { say "acronis: off (ENABLE_ACRONIS=no)"; return 0; }
  [ -n "${ACRONIS_TOKEN:-}" ] || { say "acronis: no ACRONIS_TOKEN - skipped (nothing installed)"; return 0; }
  local f=/var/lib/yc-acronis/acronis-setup.sh rc r st t p g; mkdir -p /var/lib/yc-acronis
  if ! fetch "${ACRONIS_SETUP_URL:-https://repo.oasisstack.io/acronis/acronis-setup.sh}" "$f"; then
    rc=3; r="download failed: ${ACRONIS_SETUP_URL:-}"
  else
    say "acronis: installing agent, region ${ACRONIS_REGION:-AE} (log /var/log/yc-acronis-setup.log)"
    bash "$f" "$ACRONIS_TOKEN" "${ACRONIS_REGION:-AE}" 2>&1 </dev/null | sed "s/${ACRONIS_TOKEN//\//\\/}/****/g; s/^/[acronis] /" >> "$LOG"
    rc=${PIPESTATUS[0]}
  fi
  case "$rc" in
    0)  st=registered t=vm.acronis.registered p=3 g=white_check_mark r="agent installed and registered (${ACRONIS_REGION:-AE})";;
    8)  st=failed t=vm.acronis.failed p=4 g=x r="agent installed, registration FAILED - see /var/log/yc-acronis-setup.log";;
    10) st=waiting t=vm.acronis.waiting p=4 g=hourglass r="agent installed, NOT registered - WAIT FOR HUMAN";;
    *)  st=failed t=vm.acronis.failed p=4 g=x r="${r:-acronis-setup exit $rc} - see /var/log/yc-acronis-setup.log";;
  esac
  say "acronis: $r (exit $rc)"
  N -t "$t" -T "ACRONIS ${st^^}" -p "$p" -g "$g,acronis" -l "result  $r" -l "region  ${ACRONIS_REGION:-AE}" \
    -l "log     /var/log/yc-acronis-setup.log" -f area=acronis -f status="$st" -f summary="$r"
  return "$rc"
}

case "${1:-}" in
  salt) salt_join;;
  acronis) acronis;;
  status)
    printf '  %-9s %s\n' salt "$([ "${ENABLE_SALT:-yes}" = yes ] && echo on || echo off), minion $(systemctl is-active salt-minion 2>/dev/null), id $(cat /etc/salt/minion_id 2>/dev/null || echo -), last: $(grep -E '^(JOINED|WAITING:|FAILED:)' /var/lib/yc-salt/last.log 2>/dev/null | tail -1)"
    printf '  %-9s %s\n' acronis "$([ "${ENABLE_ACRONIS:-yes}" = yes ] && echo on || echo off), token $([ -n "${ACRONIS_TOKEN:-}" ] && echo set || echo 'not set (skipped)'), region ${ACRONIS_REGION:-AE}, agent $(systemctl is-active acronis_mms 2>/dev/null || echo none)";;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
ADDEOF
chmod 755 /usr/local/sbin/odoo-ssl /usr/local/sbin/odoo-backup /usr/local/sbin/yc-addons
install -d -m 700 "$BACKUP_DIR"
BH=${BACKUP_TIME%:*}; BM=${BACKUP_TIME#*:}
{ echo "# YallaCloud Odoo (STACK4-61) - written by yc-odoo20-install $VER. Change times in $CFG, then re-run yc-odoo-install."
  echo "SHELL=/bin/bash"; echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  echo "$((10#$BM)) $((10#$BH)) * * * root odoo-backup run >> /var/log/yc-odoo-backup.log 2>&1"
  if [ "$ROLE" != db ]; then
    echo "15 3,15 * * * root certbot renew -q --deploy-hook 'systemctl reload nginx' >> /var/log/yc-odoo-ssl.log 2>&1"
    echo "0 8 * * * root odoo-ssl check >> /var/log/yc-odoo-ssl.log 2>&1"
  fi; } > /etc/cron.d/yallacloud-odoo
chmod 644 /etc/cron.d/yallacloud-odoo
printf '/var/log/yc-odoo-backup.log /var/log/yc-odoo-ssl.log /var/log/yc-notify.log {\n  monthly\n  rotate 12\n  compress\n  missingok\n  notifempty\n}\n' > /etc/logrotate.d/yc-odoo-tools
say "backups: $BACKUP_DIR daily $BACKUP_TIME, keep $BACKUP_KEEP_DAYS days; cert renew 03:15/15:15, cert check 08:00 (/etc/cron.d/yallacloud-odoo)"

# persist effective config (no secrets) for re-runs, odoo-domain, odoo-backup, yc-notify
save_cfg

if [ "$ROLE" != db ]; then
  step WEB
  if [ -n "$DOMAIN" ]; then odoo-domain "$DOMAIN"; else odoo-domain --sslip; fi
  for i in $(seq 1 30); do curl -fs -o /dev/null --max-time 5 "http://127.0.0.1:8069/web/login" && break; sleep 4; done
fi

# == 9. handover + motd
step HANDOVER
URL=$(cat "$INFO/URL" 2>/dev/null)
umask 077
{
echo "YallaCloud Odoo 20 - $(hostname) - $(date '+%F %T %Z')"
echo "role        : $ROLE"
echo "ssh         : root@${URL_IP} -p $SSH_PORT  (password = CloudStack root password)"
if [ "$ROLE" != db ]; then
echo "odoo url    : $URL"
echo "odoo login  : admin / $ADMIN_PASS        (database: ${ODOO_DB:-none})"
echo "master pass : $MASTER_PASS               (/etc/odoo/odoo.conf admin_passwd)"
echo "change url  : odoo-domain <fqdn> | --sslip | --ip | --show    server card: yallacloud"
echo "certificate : odoo-ssl status | free <fqdn> | csr <fqdn> | install ... | install-pfx ... | export-pfx <fqdn>"
fi
if [ "$ROLE" != app ]; then
[ "$ROLE" = db ] && PGAT="${PRIV_NIC:-$BIND_IP}:5432" || PGAT="localhost (unix socket, peer auth)"
echo "postgres    : $PG_VERSION on $PGAT  role odoo / $DB_PASS"
[ "$ROLE" = db ] && echo "allowed     : $APP_ALLOW  -> for the APP VM set  DB_HOST=${PRIV_NIC:-$BIND_IP}  DB_PASS='$DB_PASS'"
else
echo "postgres    : $DB_HOST:5432  role odoo / $DB_PASS"
fi
echo "backups     : odoo-backup list | run | restore <set> <db> --yes   ($BACKUP_DIR, daily $BACKUP_TIME, $BACKUP_KEEP_DAYS days)"
echo "add-ons     : salt $ENABLE_SALT, acronis $([ "$ENABLE_ACRONIS" = yes ] && [ -n "$ACRONIS_TOKEN" ] && echo "yes ($ACRONIS_REGION)" || echo "skipped")   (background; yc-addons status)"
echo "deploy log  : /var/log/yc-odoo-deploy.log   status: /var/log/yc-odoo-deploy.status"
} > "$INFO/handover.txt"
umask 022
cat > /etc/update-motd.d/99-yallacloud-odoo <<'EOF'
#!/bin/sh
echo; echo "  YallaCloud Odoo 20 - role $(. /etc/yallacloud/odoo.conf.env; echo $ROLE)"
[ -f /root/odoo-info/URL ] && echo "  URL: $(cat /root/odoo-info/URL)   (change: odoo-domain <fqdn>)"
echo "  Deploy: $(cat /var/log/yc-odoo-deploy.status 2>/dev/null)"
[ -s /var/lib/yallacloud/ssl-warn ] && cat /var/lib/yallacloud/ssl-warn
grep -q FAIL /var/lib/yallacloud/backup.status 2>/dev/null && echo "  BACKUP: $(cat /var/lib/yallacloud/backup.status)"
echo "  Credentials: /root/odoo-info/handover.txt   Full picture: yallacloud"; echo
EOF
chmod 755 /etc/update-motd.d/99-yallacloud-odoo
# == 9b. 'yallacloud' command: the whole picture of this server for a tech or the client
echo "yc-odoo20-install v$VER installed $(date '+%F %T %Z')" > /etc/yallacloud/odoo.version
cat > /usr/local/sbin/yallacloud <<'YCEOF'
#!/bin/bash
# yallacloud - what is installed here and how it is set up (STACK4-61). --secrets also prints passwords (root).
. /etc/yallacloud/odoo.conf.env 2>/dev/null
INFO=/root/odoo-info; C=/etc/odoo/odoo.conf
h(){ printf '\n== %s\n' "$1"; }; kv(){ printf '  %-18s %s\n' "$1" "$2"; }
st(){ printf '  %-22s %-9s %s\n' "$1" "$(systemctl is-active "$1" 2>/dev/null)" "$(systemctl is-enabled "$1" 2>/dev/null)"; }
oc(){ awk -F' *= *' -v k="$1" '$1==k{print $2; exit}' "$C" 2>/dev/null; }
pgsql(){ if [ "${ROLE:-}" = app ]; then PGPASSWORD="$(oc db_password)" psql -h "$(oc db_host)" -U odoo -d postgres -At -c "$1" 2>/dev/null
         else sudo -u postgres psql -At -c "$1" 2>/dev/null; fi; }
echo "YallaCloud server card - $(hostname) - $(date '+%F %T %Z')"
h "Setup"
kv role "${ROLE:-?}  ($([ "${ROLE:-}" = combined ] && echo 'PostgreSQL + Odoo on this VM' || { [ "${ROLE:-}" = db ] && echo 'PostgreSQL only'; } || echo "Odoo, database on ${DB_HOST:-?}"))"
kv installer "$(cat /etc/yallacloud/odoo.version 2>/dev/null)"
kv deploy "$(cat /var/log/yc-odoo-deploy.status 2>/dev/null || echo unknown)  (log /var/log/yc-odoo-deploy.log)"
kv os "$(. /etc/os-release; echo "$PRETTY_NAME") / kernel $(uname -r) / up $(uptime -p | sed 's/up //')"
kv url "$(cat $INFO/URL 2>/dev/null || echo '-')"
kv ips "$(hostname -I)  public=${PUBLIC_IP:-auto}"
kv ssh "port ${SSH_PORT:-22}, root + password login allowed, fail2ban on"
kv time "$(timedatectl show -p Timezone --value), NTP $(chronyc -n tracking 2>/dev/null | awk -F': ' '/Reference ID/{print $2}')"
kv locale "${LOCALE_SET:-?}"
kv cloud-init "$([ -f /etc/cloud/cloud-init.disabled ] && echo 'disabled after install (will not run again)' || echo enabled)"
h "Software"
kv odoo "$(dpkg-query -W -f='${Version}' odoo 2>/dev/null || echo -) Community"
kv postgresql "$(psql -V 2>/dev/null | awk '{print $3}') client$( [ "${ROLE:-}" != app ] && echo ", server $(pgsql 'show server_version')")"
kv nginx "$(nginx -v 2>&1 | cut -d/ -f2)"
kv wkhtmltopdf "$(wkhtmltopdf -V 2>/dev/null | awk '{print $2,$3,$4}')"
h "Services (state / boot)"
for u in odoo "postgresql@${PG_VERSION:-18}-main" nginx ssh.socket fail2ban chrony ufw; do
  systemctl cat "$u" >/dev/null 2>&1 && st "$u"; done
h "Listening ports"
ss -ltnH | awk '{print "  "$4}' | sort -u | tr '\n' ' '; echo
h "Firewall (ufw)"
ufw status | sed -n '5,$p' | sed 's/^/  /'
if [ -f "$C" ]; then h "Odoo settings ($C)"
  for k in db_host db_name dbfilter list_db proxy_mode workers max_cron_threads limit_memory_soft limit_memory_hard limit_time_real data_dir logfile; do kv "$k" "$(oc $k)"; done
  kv filestore "$(du -sh /var/lib/odoo 2>/dev/null | cut -f1) in /var/lib/odoo"
fi
F=$(ls /etc/postgresql/*/main/conf.d/90-yallacloud-odoo.conf 2>/dev/null | head -1)
if [ -n "$F" ]; then h "PostgreSQL tuning ($F)"
  grep -E '^(listen_addresses|max_connections|shared_buffers|effective_cache_size|work_mem|maintenance_work_mem|jit)' "$F" | sed 's/^/  /'
  grep yallacloud-odoo /etc/postgresql/*/main/pg_hba.conf 2>/dev/null | sed 's/^/  hba: /'
  kv data "$(du -sh /var/lib/postgresql 2>/dev/null | cut -f1) in /var/lib/postgresql"
fi
h "Databases"
pgsql "select datname||'  '||pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate and datname<>'postgres'" | sed 's/^/  /' || echo "  (not reachable)"
[ "${ROLE:-}" != db ] && [ -x /usr/local/sbin/odoo-ssl ] && { h "TLS"; odoo-ssl status | sed '1d'; [ -s /var/lib/yallacloud/ssl-warn ] && cat /var/lib/yallacloud/ssl-warn; }
h "Scheduled jobs"
systemctl list-timers --no-legend 2>/dev/null | awk '{print "  timer  "$(NF-1)}' | sort -u
crontab -l 2>/dev/null | grep -v '^#' | sed 's/^/  root cron  /'
ls /etc/cron.d 2>/dev/null | sed 's/^/  cron.d  /'
[ -f "$C" ] && echo "  odoo   $(pgsql "select count(*) from ir_cron where active" 2>/dev/null) active Odoo scheduled actions in DB $(oc db_name) (Settings > Technical > Scheduled Actions)"
h "Backups"
b=""
systemctl list-unit-files 2>/dev/null | grep -qiE 'acronis|aakore' && b="$b Acronis agent installed (policy + retention in the Acronis console);"
command -v proxmox-backup-client >/dev/null && b="$b PBS client present;"
grep -rlsE 'pg_dump|pg_basebackup' /etc/cron* /var/spool/cron 2>/dev/null | grep -q . && b="$b other pg_dump job in cron;"
[ -f /etc/cron.d/yallacloud-odoo ] && kv odoo-backup "daily ${BACKUP_TIME:-02:30} -> ${BACKUP_DIR:-/var/backups/odoo}, kept ${BACKUP_KEEP_DAYS:-15} days, $(ls -d "${BACKUP_DIR:-/var/backups/odoo}"/20* 2>/dev/null | wc -l) sets, $(du -sh "${BACKUP_DIR:-/var/backups/odoo}" 2>/dev/null | cut -f1)"
kv last-backup "$(cat /var/lib/yallacloud/backup.status 2>/dev/null || echo 'none yet')"
kv also "${b:-no Acronis / PBS client in this VM}"
kv note "snapshots / PBS of the VM are set in CloudStack, not visible from inside"
h "Add-ons (Salt, Acronis)"
/usr/local/sbin/yc-addons status 2>/dev/null
h "Reporting (ntfy + ERP webhook)"
/usr/local/sbin/yc-notify --show 2>/dev/null | sed 's/^/  /'
h "Logs and retention"
kv odoo "/var/log/odoo/odoo-server.log (weekly, 8 kept)"
kv nginx "/var/log/nginx/ (daily, 14 kept)"
kv deploy "/var/log/yc-odoo-deploy.log (userdata + installer + cloud-init), status /var/log/yc-odoo-deploy.status"
kv tools "/var/log/yc-odoo-backup.log, yc-odoo-ssl.log, yc-notify.log (monthly, 12 kept)"
kv journal "$(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]*[KMGT]')"
h "Resources"
kv cpu/ram "$(nproc) vCPU, $(free -h | awk '/Mem:/{print $2" RAM, "$3" used"}'), swap $(free -h | awk '/Swap:/{print $2}')"
kv disk "$(df -h / | awk 'NR==2{print $4" free of "$2" ("$5" used)"}')"
h "Commands"
kv "odoo-domain" "--show | <fqdn> | --sslip | --public <ip> --sslip | --ip"
kv "odoo-ssl" "status | free <fqdn> | csr <fqdn> | install <fqdn> --cert F [--chain F] [--key F] | install-pfx <fqdn> --pfx F --pass P | export-pfx <fqdn> | check"
kv "odoo-backup" "list | run | restore <set> <db> --yes"
kv "yc-addons" "status | salt | acronis   (re-run the Salt join / Acronis agent)"
kv "yc-notify" "--show | --test   (switches: ENABLE_NTFY / ENABLE_WEBHOOK in /etc/yallacloud/odoo.conf.env)"
kv "yc-odoo-install" "re-run the installer (answers: /etc/yallacloud/odoo.conf.env)"
kv "logs" "journalctl -u odoo -f ; tail -f /var/log/odoo/odoo-server.log"
kv "restart" "systemctl restart odoo nginx"
kv "credentials" "$INFO/handover.txt  (yallacloud --secrets)"
[ "${1:-}" = --secrets ] && { h "Credentials"; cat "$INFO/handover.txt"; }
YCEOF
chmod 755 /usr/local/sbin/yallacloud
rm -f "$INFO/INSTALL-FAILED"; touch "$INFO/INSTALLED"

# == 10. stop cloud-init re-running on CloudStack
# Side effect: CloudStack "reset password / reset SSH key" from the UI no longer reaches this VM.
[ "$DISABLE_CLOUD_INIT" = yes ] && touch /etc/cloud/cloud-init.disabled
STEPS="$STEPS $STEP+"; STEP=DONE
TLS=-; [ "$ROLE" != db ] && TLS=$(case "$URL" in https://*) [ -f "/etc/yallacloud/ssl/${URL#https://}/TYPE" ] && echo paid || echo "free (Let's Encrypt)";; *) echo "none - http only";; esac)
[ -n "$DOMAIN" ] && [ "${URL#https://}" = "$URL" ] && warn "DOMAIN $DOMAIN given but no certificate (DNS not pointing at $URL_IP yet?) - run: odoo-domain $DOMAIN"
SVC=""; for u in $([ "$ROLE" != db ] && echo odoo nginx) $([ "$ROLE" != app ] && echo "postgresql@$PG_VERSION-main"); do systemctl is-active --quiet "$u" || SVC="$SVC $u"; done
[ -n "$SVC" ] && warn "not running:$SVC"
RES=SUCCESS; PRI=3; TAG=white_check_mark; [ -n "$WARNS" ] && { RES="SUCCESS with warnings"; PRI=4; TAG=warning; }
echo "$RES $(date '+%F %T %Z') steps:$STEPS${WARNS:+ warnings: $WARNS}" > "$STATUS"
ADD_SALT=off; [ "$ENABLE_SALT" = yes ] && ADD_SALT="joining (own message follows)"
ADD_ACR=off; [ "$ENABLE_ACRONIS" = yes ] && { [ -n "$ACRONIS_TOKEN" ] && ADD_ACR="installing $ACRONIS_REGION (own message follows)" || ADD_ACR="skipped - no token"; }
SEC=(); [ "$ROLE" != db ] && SEC+=(-s odooAdminUser=admin -s odooAdminPassword="$ADMIN_PASS" -s odooMasterPassword="$MASTER_PASS")
SEC+=(-s dbUser=odoo -s dbPassword="$DB_PASS" -s dbHost="${DB_HOST:-${PRIV_NIC:-$BIND_IP}}")
N -t vm.deploy.completed -T "OK BUILD odoo $ROLE${WARNS:+ (warnings)}" -p "$PRI" -g "$TAG,odoo" --steps "$STEPS" \
  -l "result  $RES" -l "url     ${URL:-- (db only)}" -l "tls     $TLS" -l "ip      $BIND_IP  url ip $URL_IP  ssh $SSH_PORT" \
  -l "odoo    $(dpkg-query -W -f='${Version}' odoo 2>/dev/null || echo -)   pg $PG_VERSION   db ${ODOO_DB:-none}" \
  -l "backup  $BACKUP_DIR daily $BACKUP_TIME keep ${BACKUP_KEEP_DAYS}d" ${WARNS:+-l "warn    $WARNS"} \
  -l "addons  salt ${ADD_SALT}  acronis ${ADD_ACR}" -l "creds   /root/odoo-info/handover.txt (yallacloud --secrets)" \
  -f area=odoo -f role="$ROLE" -f status=completed -f url="$URL" -f domain="$DOMAIN" -f tls="$TLS" -f odooVersion="$(dpkg-query -W -f='${Version}' odoo 2>/dev/null)" \
  -f pgVersion="$PG_VERSION" -f sshPort="$SSH_PORT" -f backupDir="$BACKUP_DIR" -f backupKeepDays="$BACKUP_KEEP_DAYS" -f warnings="$WARNS" -f installer="$VER" -f salt="$ADD_SALT" -f acronis="$ADD_ACR" "${SEC[@]}"
# add-ons in the background: they report on their own (vm.salt.* / vm.acronis.*) into the same log
for a in salt acronis; do
  systemd-run --quiet --collect --unit "yc-addon-$a-$(date +%s)" /usr/local/sbin/yc-addons "$a" || warn "could not start add-on $a (run: yc-addons $a)"
done
say "DONE. $(grep -E '^(odoo url|postgres)' "$INFO/handover.txt" | tr '\n' ' ')"
cat "$INFO/handover.txt"
