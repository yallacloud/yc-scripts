#!/bin/bash
# yc-odoo20-userdata.sh  v1.0.0  (2026-10-26 14:25 IST)  YallaCloud / OasisStack
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

# answers for the installer (it reads this file, and again on every re-run)
umask 077; mkdir -p /etc/yallacloud
for v in ROLE DOMAIN LE_EMAIL DB_HOST DB_PASS APP_ALLOW PUBLIC_IP ODOO_DB SSH_PORT TZ_SET LOCALE_SET PG_VERSION; do
  printf '%s=%q\n' "$v" "${!v}"
done > /etc/yallacloud/odoo.conf.env
umask 022

for _ in $(seq 1 60); do ip -4 route show default | grep -q . && break; sleep 2; done

# installer from GitHub (public yallacloud/yc-scripts), three mirrors, each checked by its .sha256
R=yallacloud/yc-scripts; F=odoo/yc-odoo20-install.sh; OUT=/root/yc-odoo20-install.sh; ok=""
for u in "https://raw.githubusercontent.com/$R/$INSTALLER_REF/$F" \
         "https://cdn.jsdelivr.net/gh/$R@$INSTALLER_REF/$F" \
         "https://github.com/$R/raw/$INSTALLER_REF/$F"; do
  if curl -fsSL --retry 3 --connect-timeout 15 -o "$OUT" "$u" \
     && curl -fsSL --retry 3 --connect-timeout 15 -o "$OUT.sha256" "$u.sha256" \
     && [ "$(sha256sum "$OUT" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$OUT.sha256")" ]; then
    ok=$u; break
  fi
  say "mirror failed or sha256 mismatch: $u"
done
[ -n "$ok" ] || fail "installer download failed from all GitHub mirrors (check DNS / outbound 443)"
say "installer ok from $ok"
chmod 700 "$OUT"
exec bash "$OUT"
