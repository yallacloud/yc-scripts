#!/bin/bash
# yc-odoo20-userdata.sh  v1.2.0  (2026-10-26 15:30 IST)  YallaCloud / OasisStack
# CloudStack cloud-init userdata: Ubuntu 24.04 -> Odoo 20 Community (+ PostgreSQL 18).
# Guide: STACK4-61. Paste in CloudStack: Add Instance > Advanced > Userdata.
# Two-server layout: deploy ROLE=db FIRST, read /root/odoo-info/handover.txt on it,
# then deploy ROLE=app with DB_HOST + DB_PASS from that file.
# Edit ONLY the block below. Every value is checked on the VM: a wrong REQUIRED value
# stops the install with the reason; a wrong optional value falls back to the default.

# ===================== EDIT THESE =====================
# shellcheck disable=SC2034  # values are written out by name below
ROLE="combined"        # REQUIRED  combined (DB+app on one VM) | db | app
DOMAIN=""              # optional  erp.example.com  - blank = <public-ip>.sslip.io (app/combined only)
LE_EMAIL=""            # optional  admin@example.com - Let's Encrypt expiry mails (blank = none)
DB_HOST=""             # app: REQUIRED  private IP of the db VM, e.g. 172.30.30.3
DB_PASS=""             # app: REQUIRED  from the db handover | db: blank = generated | combined: blank
APP_ALLOW=""           # db: optional  CIDR allowed to 5432, e.g. 172.30.30.0/24 (blank = own subnet)
PUBLIC_IP=""           # app/combined behind NAT: public IP forwarded to this VM (blank = auto)
GATEWAY=""             # private VM behind a firewall: firewall LAN IP, e.g. 172.30.30.1 (blank = auto)
ODOO_DB="odoo"         # optional  database created at install (blank = none, DB manager stays on)
SSH_PORT=""            # optional  blank = 3222 on a public IP, 22 on a private IP
TZ_SET="Asia/Dubai"    # optional  any /usr/share/zoneinfo name
LOCALE_SET="en_US.UTF-8"
PG_VERSION="18"        # optional  16-19 (PGDG)
INSTALLER_REF="main"   # advanced  git branch or tag of yallacloud/yc-scripts to install from
# ======================================================

LOG=/var/log/yc-odoo-userdata.log; exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%F' '%T)] userdata: $*"; }
fail(){ say "FATAL: $*"; mkdir -p /root/odoo-info; echo "$*" > /root/odoo-info/INSTALL-FAILED; exit 1; }

# fast checks before anything is downloaded (the installer re-checks everything)
case "$ROLE" in combined|db|app) ;; *) fail "ROLE='$ROLE' - must be combined, db or app";; esac
if [ "$ROLE" = app ]; then
  [ -n "$DB_HOST" ] || fail "ROLE=app needs DB_HOST"
  [ -n "$DB_PASS" ] || fail "ROLE=app needs DB_PASS"
fi

[ -z "$GATEWAY" ] || [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { say "WARN: GATEWAY '$GATEWAY' invalid - auto"; GATEWAY=""; }

# answers for the installer (it reads this file, and again on every re-run)
umask 077; mkdir -p /etc/yallacloud
for v in ROLE DOMAIN LE_EMAIL DB_HOST DB_PASS APP_ALLOW PUBLIC_IP GATEWAY ODOO_DB SSH_PORT TZ_SET LOCALE_SET PG_VERSION; do
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
for u in "https://raw.githubusercontent.com/$R/$INSTALLER_REF/$F" \
         "https://repo.oasisstack.io/odoo/yc-odoo20-install.sh" \
         "https://cdn.jsdelivr.net/gh/$R@$INSTALLER_REF/$F" \
         "https://github.com/$R/raw/$INSTALLER_REF/$F"; do
  if curl -fsSL --retry 3 --connect-timeout 15 -o "$OUT" "$u" \
     && curl -fsSL --retry 3 --connect-timeout 15 -o "$OUT.sha256" "$u.sha256" \
     && [ "$(sha256sum "$OUT" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$OUT.sha256")" ]; then
    ok=$u; break
  fi
  say "mirror failed or sha256 mismatch: $u"
done
[ -n "$ok" ] || fail "installer download failed from GitHub and repo.oasisstack.io (check DNS / outbound 443 / gateway)"
say "installer ok from $ok"
chmod 700 "$OUT"
exec bash "$OUT"
