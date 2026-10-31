Content-Type: multipart/mixed; boundary="YCDB-PART"
MIME-Version: 1.0

--YCDB-PART
Content-Type: text/cloud-config; charset="us-ascii"

#cloud-config
# YallaCloud OS fix: the v263 templates order cloud-set-guest-password AFTER cloud-final while multi-user.target
# wants it - an ordering cycle; systemd then drops the cloud-final job at random and the script below never runs.
# bootcmd runs before cloud-final: when its job is missing, run the final stage from a transient unit instead.
bootcmd:
  - [bash, -c, "systemctl list-jobs --no-legend 2>/dev/null | grep -q ' cloud-final.service ' || systemctl is-active -q cloud-final.service || { echo 'yc: cloud-final job missing (template ordering cycle) - final stage via yc-cloud-final'; systemd-run --unit=yc-cloud-final --on-active=30 /usr/bin/cloud-init modules --mode=final; }"]

--YCDB-PART
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
# yc-mysql-userdata.min.sh  v1.0.12  (2026-10-31 12:00 IST)  YallaCloud / OasisStack
# CloudStack cloud-init userdata: Oracle MySQL Community database server (DBaaS node), nothing else.
# OS: Ubuntu 24.04 | RHEL / Rocky / AlmaLinux / Oracle Linux 9-10.  Guide: STACK4-62.
# Hypervisor: CloudStack KVM or VMware, same file. VMware: use a 'VC Standard' offering (gp.* fails with 533);
#   VC templates that run cloud-init today: LNX-AlmaLinux-9-VC-v263 (and Oracle Linux 9 VC, intermittent).
# MIN version: common settings only, everything else = installer defaults. All settings: yc-mysql-userdata.sh (FULL).
# Paste in CloudStack: Add Instance > Advanced > Userdata. Edit ONLY the block below.
# Every value is checked on the VM: a wrong REQUIRED value stops with the reason,
# a wrong optional value falls back to the default (logged as WARN).
# Result: /root/yc-db/handover.txt (yallacloud secrets) | log /var/log/yc-db-deploy.log

# ===================== EDIT THESE (MIN) =====================
# Only the settings people change per VM. Everything else = the installer default:
# port 3306, admin user dbadmin, generated passwords, data disk auto, backups 15d/4w/12m at 01:30,
# binlog on 7d, SSH 3222 (public IP) with the owner key, Asia/Dubai, Salt join + GLPI agent on,
# ntfy n.oasisstack.io, ERP webhook URL, CloudStack portal dxb01. Need one of those? use the FULL file.
# shellcheck disable=SC2034  # values are written out by name below
ENGINE="mysql"          # fixed for this file
DB_VERSION="8.4"           # 8.4 | 9.7   (LTS lines)
DB_ALLOW=""                # CIDRs allowed to the DB port, e.g. "10.1.1.0/24,203.0.113.7"; blank = any IP (public VM)
DB_NAME=""                 # optional first database, e.g. shop
DB_USER=""                 # optional owner of DB_NAME, e.g. shop
ACRONIS_TOKEN=""           # Acronis registration token (blank = no Acronis)
NTFY_TOPIC="9890122212"    # ntfy topic for the status messages
NTFY_TOKEN=""              # ntfy publish token for n.oasisstack.io (blank = messages go to ntfy.sh) - private copy only
ERP_WEBHOOK_SECRET=""      # ERP webhook X-Webhook-Secret (blank = ERP webhook off) - private copy only
EXTRA_WEBHOOK_URL=""       # second webhook (Tech Dept) URL, milestone events, no passwords (blank = off) - private copy only
EXTRA_WEBHOOK_SECRET=""    # its X-Webhook-Secret - private copy only
# ============================================================
# defaults for the settings this file does not set (same as the installer; the installer applies the rest)
: "${NTFY_URL=https://n.oasisstack.io}" "${ERP_WEBHOOK_URL=https://api.yallacloud.net/api/v1/webhooks/cloudstack}" "${TZ_SET=Asia/Dubai}" "${GATEWAY=}" "${INSTALLER_REF=main}"

LOG=/var/log/yc-db-deploy.log; touch "$LOG"; chmod 600 "$LOG"; exec 3>&1 4>&2; exec > >(tee -a "$LOG") 2>&1
[ -f "/usr/share/zoneinfo/$TZ_SET" ] && export TZ=$TZ_SET   # log times in local time from the first line
RUN="deploy-$(date +%Y%m%d-%H%M%S)"; mkdir -p /var/log/yallacloud; chmod 750 /var/log/yallacloud
say(){   # same tagged line as the installer: time | LEVEL | area | run | message  -> raw log, central log, journald (yc-db)
  local lv=INFO; case "${1:-}" in ERROR|WARN) lv=$1; shift;; esac
  local l; l=$(printf '%s | %-5s | %-8s | %-24s | %s' "$(date '+%F %T %z')" "$lv" userdata "$RUN" "$*")
  echo "$l"; echo "$l" >> /var/log/yallacloud/yc-db.log; [ "$lv" != INFO ] && echo "$l" >> /var/log/yallacloud/yc-db-errors.log
  logger -t yc-db -p "user.$(case $lv in ERROR) echo err;; WARN) echo warning;; *) echo info;; esac)" -- "[$lv] [userdata] [$RUN] $*" 2>/dev/null; }
fail(){   # early failure (before the installer runs): status file + the three outputs (extra webhook, ntfy, ERP) - no secrets
  say ERROR "FATAL: $*"; mkdir -p /root/yc-db; echo "$*" > /root/yc-db/INSTALL-FAILED
  printf 'RESULT=FAILED\nTIME=%s\nSTEP=userdata\nREASON=%s\n' "$(date '+%F %T %Z')" "$*" > /var/log/yc-db-deploy.status
  local id ip os why h b u; id=$(tr 'A-Z' 'a-z' 2>/dev/null < /sys/class/dmi/id/product_uuid); id=${id:-$(hostname)}
  ip=$(hostname -I 2>/dev/null | awk '{print $1}'); os=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME"); why=$(printf '%s' "$*" | tr -d '"\\' | head -c 300)
  h=$(mktemp); b=$(printf '{"type":"vm.deploy.failed","vmId":"%s","hostname":"%s","ip":"%s","os":"%s","error":"%s","lastUpdated":"%s","extra":"yc-%s-userdata"}' "$id" "$(hostname)" "$ip" "$os" "$why" "$(date '+%F %T %z')" "$ENGINE")
  if [ -n "$EXTRA_WEBHOOK_URL" ]; then printf 'X-Webhook-Secret: %s\nContent-Type: application/json\n' "$EXTRA_WEBHOOK_SECRET" > "$h"; curl -fsS -m 15 -o /dev/null -H @"$h" -d "$b" "$EXTRA_WEBHOOK_URL"; fi
  if [ -n "$ERP_WEBHOOK_SECRET" ]; then printf 'X-Webhook-Secret: %s\nContent-Type: application/json\n' "$ERP_WEBHOOK_SECRET" > "$h"
    curl -fsS -m 30 -o /dev/null -H @"$h" -d "${b%\}},\"area\":\"db\",\"status\":\"FAILED\",\"steps\":\"userdata\",\"installer\":\"yc-$ENGINE-userdata\"}" "$ERP_WEBHOOK_URL"; fi
  : > "$h"; u=${NTFY_URL%/}; [ -z "$NTFY_TOKEN" ] && [ "$u" = https://n.oasisstack.io ] && u=https://ntfy.sh   # own server is deny-all
  [ -n "$NTFY_TOKEN" ] && [ "$u" != https://ntfy.sh ] && printf 'Authorization: Bearer %s\n' "$NTFY_TOKEN" > "$h"
  [ -n "$NTFY_URL" ] && timeout 20 curl -fsS -o /dev/null -H @"$h" -H "Title: FAILED BUILD $ENGINE - $(hostname -s)" -H "Priority: 5" -H "Tags: x,db" --data-binary "NOT READY - the build stopped before the installer could start: $*
next     : check DNS / outbound 443 / GATEWAY, then redeploy (or run the userdata again as root)

[ server ]
vm       : $(hostname -s)  ($os)  ip ${ip:--}

[ trace ]
run      : $RUN   stage userdata (yc-$ENGINE-userdata)
logs     : /var/log/yallacloud/yc-db.log  errors /var/log/yallacloud/yc-db-errors.log  (journalctl -t yc-db)" "$u/${NTFY_TOPIC:-9890122212}"
  rm -f "$h"; exit 1; }
case "$ENGINE" in mariadb|mysql) ;; *) fail "ENGINE='$ENGINE' - must be mariadb or mysql";; esac

# gateway fix BEFORE the download: CloudStack SDN without a gateway declares .254 (dead), firewall is .1
[ -z "$GATEWAY" ] || [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { say WARN "GATEWAY '$GATEWAY' invalid - auto"; GATEWAY=""; }
priv(){ [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; }
gw_ok(){ ping -c 2 -W 2 -I "$2" "$1" >/dev/null 2>&1 || ip neigh show "$1" dev "$2" 2>/dev/null | grep -qE 'REACHABLE|STALE|DELAY|PERMANENT'; }
for _ in $(seq 1 30); do ip -o -4 addr show scope global | grep -q . && break; sleep 2; done
dev=$(ip -4 route show default | awk '{print $5; exit}'); [ -n "$dev" ] || dev=$(ip -o -4 addr show scope global | awk '{print $2; exit}')
ip=$(ip -o -4 addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
gw=$(ip -4 route show default dev "$dev" 2>/dev/null | awk '{print $3; exit}')
if [ -n "$GATEWAY" ] || { priv "$ip" && ! { [ -n "$gw" ] && gw_ok "$gw" "$dev"; }; }; then
  for c in ${GATEWAY:-${ip%.*}.1 ${ip%.*}.254 ${ip%.*}.2}; do
    gw_ok "$c" "$dev" && ip route replace default via "$c" dev "$dev" metric 0 && { say "gateway: ${gw:-none} dead - default via $c (installer persists it)"; GATEWAY=$c; break; }
  done
fi

# answers for the installer (it validates everything again; re-run: yc-db-install)
umask 077; mkdir -p /etc/yallacloud
for v in ENGINE DB_VERSION DB_PORT DB_ALLOW DB_ADMIN_USER DB_NAME DB_USER DB_ROOT_PASS DB_ADMIN_PASS DB_USER_PASS DATA_DISK BACKUP_KEEP_DAYS BACKUP_KEEP_WEEKS BACKUP_KEEP_MONTHS BACKUP_TIME BINLOG BINLOG_DAYS PUBLIC_IP GATEWAY SSH_PORT SSH_PUBKEY TZ_SET LOCALE_SET SALT_JOIN ACRONIS_TOKEN ACRONIS_REGION GLPI_AGENT NTFY_URL NTFY_TOPIC NTFY_TOKEN ERP_WEBHOOK_URL ERP_WEBHOOK_SECRET EXTRA_WEBHOOK_URL EXTRA_WEBHOOK_SECRET CLOUDSTACK_URL; do
  [ -n "${!v+x}" ] && printf '%s=%q\n' "$v" "${!v}"   # only settings this file sets; the rest = installer defaults
done > /etc/yallacloud/db.conf.env
umask 022

# installer: GitHub (public yallacloud/yc-scripts) -> repo.oasisstack.io/db (YC ranges) -> GitHub mirrors, sha256 checked
R=yallacloud/yc-scripts; F=db/yc-db-install.sh; OUT=/root/yc-db-install.sh; ok=""
for u in "https://raw.githubusercontent.com/$R/$INSTALLER_REF/$F" \
         "https://repo.oasisstack.io/db/yc-db-install.sh" \
         "https://cdn.jsdelivr.net/gh/$R@$INSTALLER_REF/$F" \
         "https://github.com/$R/raw/$INSTALLER_REF/$F"; do
  if curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 -o "$OUT" "$u" \
     && curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 -o "$OUT.sha256" "$u.sha256" \
     && [ "$(sha256sum "$OUT" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$OUT.sha256")" ]; then ok=$u; break; fi
  say WARN "mirror failed or sha256 mismatch: $u"
done
[ -n "$ok" ] || fail "installer download failed from GitHub and repo.oasisstack.io (check DNS / outbound 443 / GATEWAY)"
say "installer ok from $ok"
chmod 700 "$OUT"
export YC_RUN=$RUN; exec bash "$OUT" 1>&3 2>&4   # installer logs to the same file itself

--YCDB-PART--
