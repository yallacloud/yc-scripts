#!/bin/bash
# yc-odoo20-userdata.sh  v1.3.7  (2026-10-26 21:20 IST)  YallaCloud / OasisStack
# CloudStack cloud-init userdata: Ubuntu 24.04 -> Odoo 20 Community (+ PostgreSQL 18).
# Guide: STACK4-61. Paste in CloudStack: Add Instance > Advanced > Userdata.
# Two-server layout: deploy ROLE=db FIRST, read /root/odoo-info/handover.txt on it,
# then deploy ROLE=app with DB_HOST + DB_PASS from that file.
# Edit ONLY the block below. Every value is checked on the VM: a wrong REQUIRED value
# stops the install with the reason; a wrong optional value falls back to the default.
# One log for everything: /var/log/yc-odoo-deploy.log   Result: /var/log/yc-odoo-deploy.status

# ============================ EDIT THESE ============================
# shellcheck disable=SC2034  # values are written out by name below
# -- 1. layout
ROLE="combined"        # REQUIRED  combined (DB+app on one VM) | db | app
DOMAIN=""              # optional  erp.example.com  - blank = <public-ip>.sslip.io (app/combined only)
LE_EMAIL="bilalinamdar@gmail.com"   # optional  Let's Encrypt expiry mails (blank = none)
# -- 2. database
DB_HOST=""             # app: REQUIRED  private IP of the db VM, e.g. 172.30.30.3
DB_PASS=""             # app: REQUIRED  from the db handover | db: blank = generated | combined: blank
APP_ALLOW=""           # db: optional  CIDR allowed to 5432, e.g. 172.30.30.0/24 (blank = own subnet)
ODOO_DB="odoo"         # optional  database created at install (blank = none, DB manager stays on)
PG_VERSION="18"        # optional  16-19 (PGDG)
# -- 3. network
PUBLIC_IP=""           # app/combined behind NAT: public IP forwarded to this VM (blank = auto)
GATEWAY=""             # private VM behind a firewall: firewall LAN IP, e.g. 172.30.30.1 (blank = auto)
SSH_PORT=""            # optional  blank = 3222 on a public IP, 22 on a private IP
ROOT_PW_FROM_CLOUDSTACK="yes"   # VM login password = the one CloudStack shows (VR or ConfigDrive), sent in the webhook
VM_PW_USERS="root"            # accounts that get it (chadmin gets its own generated password)
SSH_PUBKEYS="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDSMLjQxi/2e/MTTyuzD34SA+94GP1+Eyv3PjAXqSMhQy3MdWwZCrnrP+W7FON6ilIDhdI42usXmMhTr0eJQYsTwVdwMZE9OtF4SniauuN7YvJkG9O3W6YclGr0U8xqo4QH48ZQYntB37nP5PUIOgFKkVyH3T7MR2Dp8VZo0n6oa7hgMjIJOVcmC8zhEm0+4/JJSL60gaGA2/251jSELOlAVTalKyuOipZYjnNOY4TqU9owCRPJNGd9e3rP4QOO0p5xjtsFSNDMqacpCSYiIc26y2GNjOqthvWGa4/O84QmMqbtG053VrmNQZGSgmGw+4b9ajC/9Bh8dU0XSEN9ijqc1U86zNXL10GhhAV+H2R3V5wLPbFK3/NAPOi4sqZ1eXq6denlr6Ap2/cAvUT089v5L1CkoXaZY2QCLQleHH3jPRKzvzB+7g7R7VIDXVX977qleExzi48XinzV+W5+dZyHbAK+9iOf5orJGOMWWxj1LKYltPUQeY19B+H4fRDfhDmw7+94oqFxnDPjMaSdcTAosoQ4EdKwqBmtdWhDAaxsIHa1ynkmUo0IwbosDJayjl/GqHeiyAwWWG/7CKwJXTef4ZYETwIWdXobZElzh9/kGrKgoalzT5K5f6sBM/IBciPfhSz8PaOiWc0RwLEkqX8JtzzllgBZItuIKWpSWl4TUw== guest"   # root keys, one per line
# -- 4. OS
TZ_SET="Asia/Dubai"    # optional  any /usr/share/zoneinfo name
LOCALE_SET="en_US.UTF-8"
# -- 5. backups (daily, local)
BACKUP_DIR="/var/backups/odoo"
BACKUP_KEEP_DAYS="15"  # 1-365
BACKUP_TIME="02:30"    # HH:MM
# -- 6. reporting: ntfy = phone (never passwords) | webhook = YallaCloud ERP (YCERP-01)
ENABLE_NTFY="yes"
NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="9890122212"
ENABLE_WEBHOOK="yes"
ERP_WEBHOOK_URL="https://api.yallacloud.net/api/v1/webhooks/cloudstack"
ERP_WEBHOOK_SECRET=""  # REQUIRED for the webhook: X-Webhook-Secret from the estate secret store
WEBHOOK_SEND_SECRETS="yes"   # Odoo/DB passwords in the webhook fields (ntfy never gets them)
CLOUDSTACK_URL="https://dxb01.oasisstack.io/client"   # portal this VM comes from (sent in the webhook)
CS_TENANT=""           # CloudStack domain; blank = auto (Salt inventory, ROOT = admin)
# -- 7. add-ons (background, never block the deploy)
ENABLE_SALT="yes"      # join the YallaCloud Salt master (zero-input)
ENABLE_ACRONIS="yes"   # Acronis agent - runs ONLY when ACRONIS_TOKEN is set
ACRONIS_TOKEN=""       # registration token (secret)
ACRONIS_REGION="AE"    # AE | SG
# -- 8. advanced
INSTALLER_REF="main"   # git branch or tag of yallacloud/yc-scripts to install from
# ===================================================================

LOG=/var/log/yc-odoo-deploy.log; STATUS=/var/log/yc-odoo-deploy.status
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%F' '%T)] userdata: $*"; }
echo "RUNNING step userdata ($(date '+%F %T %Z'))" > "$STATUS"
# before the installer exists only curl is there: ntfy without secrets, minimal ERP event
fail(){
  say "FATAL: $*"; mkdir -p /root/odoo-info; echo "$*" > /root/odoo-info/INSTALL-FAILED
  echo "FAILED step userdata: $* ($(date '+%F %T %Z'))" > "$STATUS"
  local h e u; h=$(hostname); e=${1//\\/\\\\}; e=${e//\"/\\\"}; u=$(tr 'A-Z' 'a-z' < /sys/class/dmi/id/product_uuid 2>/dev/null)
  [ "$ENABLE_NTFY" = yes ] && curl -fsS -m 15 -H "Title: FAILED BUILD odoo $ROLE - $h" -H "Priority: 5" -H "Tags: rotating_light,odoo" \
    -d "$(printf 'result  FAILED in userdata\nerror   %s\nhost    %s  %s\nlog     %s' "$1" "$h" "$(hostname -I)" "$LOG")" "${NTFY_SERVER%/}/$NTFY_TOPIC" >/dev/null
  [ "$ENABLE_WEBHOOK" = yes ] && [ -n "$ERP_WEBHOOK_URL" ] && curl -fsS -m 20 -H 'Content-Type: application/json' \
    ${ERP_WEBHOOK_SECRET:+-H "X-Webhook-Secret: $ERP_WEBHOOK_SECRET"} \
    -d "{\"type\":\"vm.deploy.failed\",\"vmId\":\"$u\",\"smbiosUuid\":\"$u\",\"identitySource\":\"smbios\",\"hostname\":\"$h\",\"ip\":\"$(hostname -I | awk '{print $1}')\",\"utc\":\"$(date -u +%FT%TZ)\",\"failedStep\":\"userdata\",\"error\":\"$e\",\"steps\":\"USERDATA-\",\"extra\":\"FAILED BUILD odoo $ROLE\",\"fields\":{\"area\":\"odoo\",\"status\":\"failed\"}}" \
    "$ERP_WEBHOOK_URL" >/dev/null
  exit 1; }

# fast checks before anything is downloaded (the installer re-checks everything)
case "$ROLE" in combined|db|app) ;; *) fail "ROLE='$ROLE' - must be combined, db or app";; esac
if [ "$ROLE" = app ]; then
  [ -n "$DB_HOST" ] || fail "ROLE=app needs DB_HOST"
  [ -n "$DB_PASS" ] || fail "ROLE=app needs DB_PASS"
fi
[ -z "$GATEWAY" ] || [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { say "WARN: GATEWAY '$GATEWAY' invalid - auto"; GATEWAY=""; }
[[ "$INSTALLER_REF" =~ ^[A-Za-z0-9._/-]{1,64}$ ]] || { say "WARN: INSTALLER_REF invalid - main"; INSTALLER_REF=main; }

# answers for the installer (it validates each one, moves the secrets to notify.env)
umask 077; mkdir -p /etc/yallacloud
for v in ROLE DOMAIN LE_EMAIL DB_HOST DB_PASS APP_ALLOW ODOO_DB PG_VERSION PUBLIC_IP GATEWAY SSH_PORT ROOT_PW_FROM_CLOUDSTACK VM_PW_USERS SSH_PUBKEYS TZ_SET LOCALE_SET \
         BACKUP_DIR BACKUP_KEEP_DAYS BACKUP_TIME ENABLE_NTFY NTFY_SERVER NTFY_TOPIC ENABLE_WEBHOOK ERP_WEBHOOK_URL \
         ERP_WEBHOOK_SECRET WEBHOOK_SEND_SECRETS CLOUDSTACK_URL CS_TENANT ENABLE_SALT ENABLE_ACRONIS ACRONIS_TOKEN ACRONIS_REGION; do
  printf '%s=%q\n' "$v" "${!v}"
done > /etc/yallacloud/odoo.conf.env
umask 022

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
for _ in $(seq 1 30); do ip -o -4 addr show scope global | grep -q . && break; sleep 2; done
say "$(fix_gateway "$GATEWAY")"   # BEFORE the download: a dead .254 gateway means no internet

# installer: GitHub (public yallacloud/yc-scripts), then the local mirror repo.oasisstack.io/odoo
# (ycwsus01, YC ranges), then two more GitHub mirrors - each checked by its .sha256
R=yallacloud/yc-scripts; F=odoo/yc-odoo20-install.sh; OUT=/root/yc-odoo20-install.sh; ok=""
MIN_VER="1.4.11"   # oldest installer this userdata works with: a CDN can serve a stale copy for minutes
for u in "https://raw.githubusercontent.com/$R/$INSTALLER_REF/$F" \
         "https://raw.githubusercontent.com/$R/$INSTALLER_REF/$F?nocache=$(date +%s)" \
         "https://repo.oasisstack.io/odoo/yc-odoo20-install.sh" \
         "https://cdn.jsdelivr.net/gh/$R@$INSTALLER_REF/$F" \
         "https://github.com/$R/raw/$INSTALLER_REF/$F"; do
  if curl -fsSL --retry 3 --connect-timeout 15 -o "$OUT" "$u" \
     && b=${u%%\?*} && curl -fsSL --retry 3 --connect-timeout 15 -o "$OUT.sha256" "$b.sha256${u#"$b"}" \
     && [ "$(sha256sum "$OUT" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$OUT.sha256")" ]; then
    v=$(sed -n 's/^VER=//p' "$OUT" | head -1)
    [ "$(printf '%s\n' "$MIN_VER" "$v" | sort -V | head -1)" = "$MIN_VER" ] && { ok=$u; break; }
    say "stale installer v${v:-?} (need >= $MIN_VER): $u"; continue
  fi
  say "mirror failed or sha256 mismatch: $u"
done
[ -n "$ok" ] || fail "installer download failed from GitHub and repo.oasisstack.io (check DNS / outbound 443 / gateway)"
say "installer ok from $ok"
chmod 700 "$OUT"
export YC_FROM_USERDATA=1   # the installer merges the cloud-init logs into $LOG at the end
exec bash "$OUT"
