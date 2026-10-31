#!/bin/bash
# yc-odoo20-userdata.sh v1.3.14 MIN (same code as the FULL twin, comments removed) - edit only the values; guide STACK4-61
ROLE="combined"
DOMAIN=""
LE_EMAIL="bilalinamdar@gmail.com"
DB_HOST=""
DB_PASS=""
APP_ALLOW=""
ODOO_DB="odoo"
PG_VERSION="18"
PUBLIC_IP=""
GATEWAY=""
SSH_PORT=""
ROOT_PW_FROM_CLOUDSTACK="yes"
VM_PW_USERS="root"
SSH_PUBKEYS="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDSMLjQxi/2e/MTTyuzD34SA+94GP1+Eyv3PjAXqSMhQy3MdWwZCrnrP+W7FON6ilIDhdI42usXmMhTr0eJQYsTwVdwMZE9OtF4SniauuN7YvJkG9O3W6YclGr0U8xqo4QH48ZQYntB37nP5PUIOgFKkVyH3T7MR2Dp8VZo0n6oa7hgMjIJOVcmC8zhEm0+4/JJSL60gaGA2/251jSELOlAVTalKyuOipZYjnNOY4TqU9owCRPJNGd9e3rP4QOO0p5xjtsFSNDMqacpCSYiIc26y2GNjOqthvWGa4/O84QmMqbtG053VrmNQZGSgmGw+4b9ajC/9Bh8dU0XSEN9ijqc1U86zNXL10GhhAV+H2R3V5wLPbFK3/NAPOi4sqZ1eXq6denlr6Ap2/cAvUT089v5L1CkoXaZY2QCLQleHH3jPRKzvzB+7g7R7VIDXVX977qleExzi48XinzV+W5+dZyHbAK+9iOf5orJGOMWWxj1LKYltPUQeY19B+H4fRDfhDmw7+94oqFxnDPjMaSdcTAosoQ4EdKwqBmtdWhDAaxsIHa1ynkmUo0IwbosDJayjl/GqHeiyAwWWG/7CKwJXTef4ZYETwIWdXobZElzh9/kGrKgoalzT5K5f6sBM/IBciPfhSz8PaOiWc0RwLEkqX8JtzzllgBZItuIKWpSWl4TUw== guest"
TZ_SET="Asia/Dubai"
LOCALE_SET="en_US.UTF-8"
BACKUP_DIR="/var/backups/odoo"
BACKUP_KEEP_DAYS="15"
BACKUP_TIME="02:30"
ENABLE_NTFY="yes"
NTFY_SERVER="https://n.oasisstack.io"
NTFY_TOPIC="9890122212"
NTFY_TOKEN=""
NTFY_FALLBACK="https://ntfy.sh"
ENABLE_WEBHOOK="yes"
ERP_WEBHOOK_URL="https://api.yallacloud.net/api/v1/webhooks/cloudstack"
ERP_WEBHOOK_SECRET=""
WEBHOOK_SEND_SECRETS="yes"
EXTRA_WEBHOOK_URL=""
EXTRA_WEBHOOK_SECRET=""
CLOUDSTACK_URL="https://dxb01.oasisstack.io/client"
CS_TENANT=""
ENABLE_SALT="yes"
ENABLE_ACRONIS="yes"
ACRONIS_TOKEN=""
ACRONIS_REGION="AE"
ENABLE_GLPI="yes"
GLPI_AGENT_PASSWORD=""
GLPI_TAG=""
ENABLE_MONITOR="yes"
INSTALLER_REF="main"
LOG=/var/log/yc-odoo-deploy.log; STATUS=/var/log/yc-odoo-deploy.status
exec > >(tee -a "$LOG") 2>&1
ycl(){ local l=$1; shift; mkdir -p -m 750 /var/log/yallacloud; local x; x=$(printf '%s | %-5s | %-9s | %-8s | %s' "$(date '+%F %T %z')" "$l" userdata - "$*")
  ( umask 027; echo "$x" >> /var/log/yallacloud/odoo.log; case "$l" in WARN|ERROR) echo "$x" >> /var/log/yallacloud/errors.log;; esac )
  logger -t yallacloud-odoo -p user.info -- "$l userdata -: $*" 2>/dev/null; }
say(){ echo "[$(date +%F' '%T)] userdata: $*"; case "$*" in WARN:*) ycl WARN "${*#WARN: }";; *) ycl INFO "$*";; esac; }
echo "RUNNING step userdata ($(date '+%F %T %Z'))" > "$STATUS"
fail(){
  echo "[$(date +%F' '%T)] userdata: FATAL: $*"; ycl ERROR "userdata FAILED: $*"; mkdir -p /root/odoo-info; echo "$*" > /root/odoo-info/INSTALL-FAILED
  echo "FAILED step userdata: $* ($(date '+%F %T %Z'))" > "$STATUS"
  local h e u; h=$(hostname); e=${1//\\/\\\\}; e=${e//\"/\\\"}; u=$(tr 'A-Z' 'a-z' < /sys/class/dmi/id/product_uuid 2>/dev/null)
  local nm; nm=$(printf 'result  FAILED in userdata\nerror   %s\nhost    %s  %s\nlog     %s' "$1" "$h" "$(hostname -I)" "$LOG")
  [ "$ENABLE_NTFY" = yes ] && { curl -fsS -m 15 ${NTFY_TOKEN:+-H "Authorization: Bearer $NTFY_TOKEN"} -H "Title: FAILED BUILD odoo $ROLE - $h" -H "Priority: 5" -H "Tags: rotating_light,odoo" \
    -d "$nm" "${NTFY_SERVER%/}/$NTFY_TOPIC" >/dev/null 2>&1 || { [ -n "$NTFY_FALLBACK" ] && curl -fsS -m 15 -H "Title: FAILED BUILD odoo $ROLE - $h" -H "Priority: 5" \
    -H "Tags: rotating_light,odoo" -d "$nm" "${NTFY_FALLBACK%/}/$NTFY_TOPIC" >/dev/null 2>&1; }; }
  local ev; ev="{\"type\":\"vm.deploy.failed\",\"vmId\":\"$u\",\"smbiosUuid\":\"$u\",\"identitySource\":\"smbios\",\"hostname\":\"$h\",\"ip\":\"$(hostname -I | awk '{print $1}')\",\"utc\":\"$(date -u +%FT%TZ)\",\"lastUpdated\":\"$(date '+%F %T %z')\",\"failedStep\":\"userdata\",\"error\":\"$e\",\"steps\":\"USERDATA-\",\"extra\":\"FAILED BUILD odoo $ROLE\",\"fields\":{\"area\":\"odoo\",\"status\":\"failed\"}}"
  [ -n "$EXTRA_WEBHOOK_URL" ] && curl -fsS -m 15 -H 'Content-Type: application/json' -H "X-Webhook-Secret: $EXTRA_WEBHOOK_SECRET" \
    -d "{\"type\":\"vm.deploy.failed\",\"vmId\":\"$u\",\"hostname\":\"$h\",\"ip\":\"$(hostname -I | awk '{print $1}')\",\"os\":\"$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")\",\"error\":\"$(printf '%s' "$1" | tr -d '"\\' | head -c 300)\",\"lastUpdated\":\"$(date '+%F %T %z')\",\"extra\":\"yc-odoo20-userdata 1.3.14\"}" \
    "$EXTRA_WEBHOOK_URL" >/dev/null 2>&1
  [ "$ENABLE_WEBHOOK" = yes ] && [ -n "$ERP_WEBHOOK_URL" ] && curl -fsS -m 20 -H 'Content-Type: application/json' \
    ${ERP_WEBHOOK_SECRET:+-H "X-Webhook-Secret: $ERP_WEBHOOK_SECRET"} -d "$ev" "$ERP_WEBHOOK_URL" >/dev/null
  exit 1; }
[ -n "$NTFY_TOPIC" ] || NTFY_TOPIC=9890122212
case "$ROLE" in combined|db|app) ;; *) fail "ROLE='$ROLE' - must be combined, db or app";; esac
if [ "$ROLE" = app ]; then
  [ -n "$DB_HOST" ] || fail "ROLE=app needs DB_HOST"
  [ -n "$DB_PASS" ] || fail "ROLE=app needs DB_PASS"
fi
[ -z "$GATEWAY" ] || [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { say "WARN: GATEWAY '$GATEWAY' invalid - auto"; GATEWAY=""; }
[[ "$INSTALLER_REF" =~ ^[A-Za-z0-9._/-]{1,64}$ ]] || { say "WARN: INSTALLER_REF invalid - main"; INSTALLER_REF=main; }
umask 077; mkdir -p /etc/yallacloud
for v in ROLE DOMAIN LE_EMAIL DB_HOST DB_PASS APP_ALLOW ODOO_DB PG_VERSION PUBLIC_IP GATEWAY SSH_PORT ROOT_PW_FROM_CLOUDSTACK VM_PW_USERS SSH_PUBKEYS TZ_SET LOCALE_SET \
         BACKUP_DIR BACKUP_KEEP_DAYS BACKUP_TIME ENABLE_NTFY NTFY_SERVER NTFY_TOPIC NTFY_TOKEN NTFY_FALLBACK ENABLE_WEBHOOK ERP_WEBHOOK_URL \
         ERP_WEBHOOK_SECRET EXTRA_WEBHOOK_URL EXTRA_WEBHOOK_SECRET WEBHOOK_SEND_SECRETS CLOUDSTACK_URL CS_TENANT ENABLE_SALT ENABLE_ACRONIS ACRONIS_TOKEN ACRONIS_REGION \
         ENABLE_GLPI GLPI_AGENT_PASSWORD GLPI_TAG ENABLE_MONITOR; do
  printf '%s=%q\n' "$v" "${!v}"
done > /etc/yallacloud/odoo.conf.env
umask 022
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
R=yallacloud/yc-scripts; F=odoo/yc-odoo20-install.sh; OUT=/root/yc-odoo20-install.sh; ok=""
MIN_VER="1.6.1"
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
