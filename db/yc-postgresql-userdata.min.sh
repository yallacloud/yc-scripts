#!/bin/bash
# yc-postgresql-userdata.min.sh  v1.0.5  (2026-10-31 12:00 IST)  YallaCloud / OasisStack
# CloudStack cloud-init userdata, SHORT version: PostgreSQL database server (DBaaS node).
# Same result as the full yc-postgresql-userdata.sh - only the usual settings are shown; everything else
# uses the installer defaults (PostgreSQL 18, port 5432, backups 15/4/12 at 01:30 + 7-day PITR, SSH 3222 on a public IP,
# Asia/Dubai, Salt + GLPI on, ntfy on n.oasisstack.io). Need another setting? Use the full file. Guide: STACK4-64.
# Paste in CloudStack: Add Instance > Advanced > Userdata. Edit ONLY the block below.
# Result: /root/yc-db/handover.txt (yallacloud secrets) | log /var/log/yc-db-deploy.log

# ===================== EDIT THESE =====================
# shellcheck disable=SC2034  # values are written out by name below
ENGINE="postgresql"        # fixed for this file
DB_VERSION="18"            # 15 | 16 | 17 | 18
DB_ALLOW=""                # CIDRs allowed to the DB port, e.g. "10.1.1.0/24,203.0.113.7" (blank = any IP on a public VM, own subnet on a private VM)
DB_NAME=""                 # optional first database, e.g. shop
DB_USER=""                 # optional owner of DB_NAME, e.g. shop (passwords are generated)
GATEWAY=""                 # private VM behind a firewall: firewall LAN IP (blank = auto)
ACRONIS_TOKEN=""           # blank = no Acronis
ACRONIS_REGION="AE"        # AE | SG
NTFY_TOPIC="9890122212"    # ntfy topic (status only, never secrets). off = no ntfy
NTFY_TOKEN=""              # ntfy publish token for n.oasisstack.io (private copy only; blank = ntfy.sh)
ERP_WEBHOOK_SECRET=""      # ERP webhook X-Webhook-Secret (private copy only; blank = ERP webhook off)
EXTRA_WEBHOOK_URL=""       # second webhook, one flat event per milestone (private copy only; blank = off)
EXTRA_WEBHOOK_SECRET=""    # its X-Webhook-Secret
INSTALLER_REF="main"       # advanced: git branch/tag of yallacloud/yc-scripts
NET_RETRY_INTERVAL="300"; NET_MAX_WAIT="0"   # runner: no internet -> retry every 5 min, forever
# ======================================================

LOG=/var/log/yc-db-deploy.log; touch "$LOG"; chmod 600 "$LOG"; exec 3>&1 4>&2; exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date '+%F %T %z')] userdata: $*"; }
fail(){ say "FATAL: $*"; NTFY_URL="https://ntfy.sh/${NTFY_TOPIC:-9890122212}"; [ "${NTFY_TOPIC:-}" = off ] && NTFY_URL=""; mkdir -p /root/yc-db; echo "$*" > /root/yc-db/INSTALL-FAILED; printf 'RESULT=FAILED\nTIME=%s\nSTEP=userdata\nREASON=%s\n' "$(date '+%F %T %Z')" "$*" > /var/log/yc-db-deploy.status
  [ -n "$NTFY_URL" ] && timeout 20 curl -fsS -o /dev/null -H "Title: FAILED $ENGINE $(hostname -s)" -H "Priority: 4" -H "Tags: x,db" --data-binary "userdata: $*" "$NTFY_URL"; exit 1; }
[ "$ENGINE" = postgresql ] || fail "ENGINE='$ENGINE' - this file is for postgresql only"

# gateway fix BEFORE the download: CloudStack SDN without a gateway declares .254 (dead), firewall is .1
[ -z "$GATEWAY" ] || [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { say "WARN: GATEWAY '$GATEWAY' invalid - auto"; GATEWAY=""; }
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
for v in ENGINE DB_VERSION DB_ALLOW DB_NAME DB_USER GATEWAY ACRONIS_TOKEN ACRONIS_REGION NTFY_TOPIC NTFY_TOKEN ERP_WEBHOOK_SECRET EXTRA_WEBHOOK_URL EXTRA_WEBHOOK_SECRET; do   # min: only these; the installer defaults the rest
  printf '%s=%q\n' "$v" "${!v}"
done > /etc/yallacloud/db.conf.env
umask 022

# cloud-init only drops the runner and starts yc-deploy.service: the internet wait, the download and the install
# survive reboots (Restart=on-failure, 5 min), up to 3 failed installer runs. Watch: journalctl -t YC-POSTGRESQL-DB
cat > /usr/local/sbin/yc-deploy-run <<EOF
#!/bin/bash
# yc-deploy-run - fetch yc-pg-install.sh (GitHub -> repo.oasisstack.io -> mirrors, sha256 checked), then run it. STACK4-64
REF=$(printf '%q' "$INSTALLER_REF"); RETRY=$(printf '%q' "${NET_RETRY_INTERVAL:-300}"); MAXW=$(printf '%q' "${NET_MAX_WAIT:-0}")
EOF
cat >> /usr/local/sbin/yc-deploy-run <<'EOF'
LOG=/var/log/yc-db-deploy.log; exec >> "$LOG" 2>&1
say(){ echo "$(date '+%FT%T%z') [YC-POSTGRESQL-DB] [runner] $*"; logger -t YC-POSTGRESQL-DB -- "[runner] $*"; }
[ -f /var/lib/yallacloud/deploy.done ] && { say "already deployed - nothing to do"; exit 0; }
mkdir -p /var/lib/yallacloud; n=$(( $(cat /var/lib/yallacloud/deploy.attempts 2>/dev/null || echo 0) + 1 )); echo $n > /var/lib/yallacloud/deploy.attempts
[ $n -gt 3 ] && { say "FAILED 3 times - giving up (fix, then: yallacloud deploy resume)"; systemctl disable yc-deploy.service; exit 0; }
[[ "$RETRY" =~ ^[0-9]+$ ]] && [ "$RETRY" -ge 30 ] || RETRY=300; [[ "$MAXW" =~ ^[0-9]+$ ]] || MAXW=0
R=yallacloud/yc-scripts; F=db/yc-pg-install.sh; OUT=/root/yc-pg-install.sh; waited=0
while :; do
  for u in "https://raw.githubusercontent.com/$R/$REF/$F" "https://repo.oasisstack.io/db/yc-pg-install.sh" \
           "https://cdn.jsdelivr.net/gh/$R@$REF/$F" "https://github.com/$R/raw/$REF/$F"; do
    if curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 -o "$OUT" "$u" \
       && curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 -o "$OUT.sha256" "$u.sha256" \
       && [ "$(sha256sum "$OUT" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$OUT.sha256")" ]; then
      say "installer ok from $u (attempt $n)"; chmod 700 "$OUT"; exec bash "$OUT"
    fi
    say "mirror failed or sha256 mismatch: $u"
  done
  printf '{"state":"WAITING_NETWORK","tag":"YC-POSTGRESQL-DB","step":"download","time":"%s"}\n' "$(date '+%FT%T%z')" > /var/lib/yallacloud/deploy.status
  [ "$MAXW" -gt 0 ] && [ "$waited" -ge "$MAXW" ] && { say "ERROR: no installer after ${waited}s - check DNS / outbound 443 / GATEWAY"; exit 1; }
  say "ERROR: no installer source reachable - next try in ${RETRY}s (waited ${waited}s)"; sleep "$RETRY"; waited=$((waited+RETRY))
done
EOF
chmod 700 /usr/local/sbin/yc-deploy-run
cat > /etc/systemd/system/yc-deploy.service <<'EOF'
[Unit]
Description=YallaCloud PostgreSQL deploy (STACK4-64) - internet wait, download, install; resumes after reboot
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/yallacloud/deploy.done
StartLimitIntervalSec=0
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/yc-deploy-run
Restart=on-failure
RestartSec=300
RestartPreventExitStatus=2
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable yc-deploy.service >/dev/null 2>&1
systemctl start --no-block yc-deploy.service || fail "yc-deploy.service did not start"
say "yc-deploy.service started - log $LOG, journalctl -t YC-POSTGRESQL-DB"
