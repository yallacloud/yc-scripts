#!/bin/bash
####################
# yc-odoo20-install.sh  v1.1.0  (2026-10-26 14:25 IST)  YallaCloud / OasisStack
# Odoo 20 Community + PostgreSQL 18 on Ubuntu 24.04 (CloudStack). Guide: STACK4-61.
#
# Normally started by yc-odoo20-userdata.sh (cloud-init), which writes the answers to
# /etc/yallacloud/odoo.conf.env. Manual: edit CONFIG, run as root. Re-run: yc-odoo-install
# ROLE=combined  DB + Odoo + nginx on one VM               (default)
# ROLE=db        PostgreSQL only. No domain, no public IP needed. Deploy FIRST.
# ROLE=app       Odoo + nginx only. Needs DB_HOST + DB_PASS from the db VM.
#
# Log:      /var/log/yc-odoo-install.log
# Result:   /root/odoo-info/handover.txt  (all passwords, chmod 600)
# Domain:   odoo-domain <fqdn> | odoo-domain --sslip | --ip | --show
####################
set -uo pipefail

# ==== CONFIG ====
ROLE="combined"              # combined | db | app
DOMAIN=""                    # blank = <public-ip>.sslip.io (or plain IP if private)
LE_EMAIL=""                  # Let's Encrypt contact (blank = register without email)
DB_HOST=""                   # app only: private IP of the db VM
DB_PASS=""                   # db/app: blank on db = generated; app = paste from db handover
APP_ALLOW=""                 # db only: CIDR allowed to 5432. blank = own private subnet
ODOO_DB="odoo"               # database created automatically (blank = skip)
PG_VERSION="18"              # PGDG major. 19 is not GA yet (2026-10-13)
TZ_SET="Asia/Dubai"
LOCALE_SET="en_US.UTF-8"
APT_MIRRORS="ae.archive.ubuntu.com archive.ubuntu.com"  # first that answers wins
SSH_PORT=""                  # blank = 3222 on a public IP, 22 on private
PASS_URL="https://pass.oasisstack.io/?len=16"
DISABLE_CLOUD_INIT="yes"     # stops CloudStack re-running cloud-init every boot
PUBLIC_IP=""                 # NAT case: public IP forwarded to this VM (blank = auto)
ODOO_DEB_URL="https://github.com/yallacloud/yc-scripts/releases/download/odoo20-latest/odoo_20.0.latest_all.deb"
# ================

CFG=/etc/yallacloud/odoo.conf.env
LIB=/usr/local/lib/yc-odoo-common.sh
INFO=/root/odoo-info
LOG=/var/log/yc-odoo-install.log
mkdir -p /etc/yallacloud "$INFO"; chmod 700 "$INFO"
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%F' '%T)] $*"; }
die(){ echo "YC-FATAL: $*" | tee "$INFO/INSTALL-FAILED"; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
. /etc/os-release; [ "${ID}-${VERSION_ID}" = "ubuntu-24.04" ] || die "Ubuntu 24.04 only (found $PRETTY_NAME)"

# keep a copy so a re-run needs no userdata
[ -f "$CFG" ] && . "$CFG"          # earlier answers win on re-run
SELF=$(readlink -f "$0"); [ "$SELF" != /usr/local/sbin/yc-odoo-install ] && install -m 700 "$SELF" /usr/local/sbin/yc-odoo-install
# == 0. check every input: required -> stop with the reason; optional -> warn + safe default
warn(){ say "WARN: $*"; }
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
pw_safe(){ [[ "$1" =~ ^[A-Za-z0-9#@%+=._,:-]{8,64}$ ]]; }   # no quotes, spaces, \ $ ` (SQL + config safe)
if [ "$ROLE" = app ]; then
  [ -n "$DB_HOST" ] || die "ROLE=app needs DB_HOST (private IP of the db VM, from its handover.txt)"
  ip4 "$DB_HOST" || fqdn "$DB_HOST" || die "DB_HOST='$DB_HOST' is not an IPv4 address or host name"
  [ -n "$DB_PASS" ] || die "ROLE=app needs DB_PASS (from the db VM handover.txt)"
else
  [ -n "$DB_HOST" ] && { warn "DB_HOST ignored on ROLE=$ROLE (local PostgreSQL)"; DB_HOST=""; }
fi
[ -z "$DB_PASS" ] || pw_safe "$DB_PASS" || die "DB_PASS: 8-64 chars of A-Z a-z 0-9 # @ % + = . _ , : - only"
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
if [ -n "$PUBLIC_IP" ]; then
  ip4 "$PUBLIC_IP" || { warn "PUBLIC_IP '$PUBLIC_IP' invalid - auto"; PUBLIC_IP=""; }
fi
[[ "$ODOO_DEB_URL" =~ ^https?:// ]] || ODOO_DEB_URL="https://github.com/yallacloud/yc-scripts/releases/download/odoo20-latest/odoo_20.0.latest_all.deb"
say "config: ROLE=$ROLE DOMAIN=${DOMAIN:-<sslip>} DB_HOST=${DB_HOST:--} DB_PASS=$([ -n "$DB_PASS" ] && echo set || echo generate) APP_ALLOW=${APP_ALLOW:-auto} ODOO_DB=${ODOO_DB:-none} PG=$PG_VERSION TZ=$TZ_SET SSH=${SSH_PORT:-auto} PUBLIC_IP=${PUBLIC_IP:-auto}"

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
# YallaCloud password rule (STACK4-52): 8-16 chars, first A-Z, last a-z, >=2 '#'
# (only symbol), >=1 digit, no O 0 o I l 1. pass.oasisstack.io first, local fallback.
genpw_local(){
  local U="ABCDEFGHJKLMNPQRSTUVWXYZ" L="abcdefghijkmnpqrstuvwxyz" D="23456789" len=${1:-16}
  local A="${U}${L}${D}#" i j t n
  _p(){ local s="$1"; printf '%s' "${s:$(( $(od -An -N2 -tu2 /dev/urandom) % ${#s} )):1}"; }
  local -a m=('#' '#' "$(_p "$D")"); for i in $(seq 1 $((len-5))); do m+=("$(_p "$A")"); done
  n=${#m[@]}; for ((i=n-1;i>0;i--)); do j=$(( $(od -An -N2 -tu2 /dev/urandom) % (i+1) )); t=${m[i]}; m[i]=${m[j]}; m[j]=$t; done
  printf '%s%s%s\n' "$(_p "$U")" "$(IFS=; echo "${m[*]}")" "$(_p "$L")"
}
pw_ok(){ [[ "$1" =~ ^[A-Z][A-HJ-NP-Za-km-np-z2-9#]{6,14}[a-z]$ ]] && [[ "$1" == *#*#* ]] && [[ "$1" =~ [2-9] ]]; }
genpw(){
  local p; p=$(curl -fs --max-time 8 "${PASS_URL:-https://pass.oasisstack.io/?len=16}" 2>/dev/null | tr -d '\r\n')
  pw_ok "$p" || p=$(genpw_local 16)
  printf '%s\n' "$p"
}
LIBEOF
. "$LIB"

# == 1. network + IPs
say "waiting for network"
for i in $(seq 1 60); do ip -4 route show default | grep -q . && break; sleep 2; done
detect_ips
[ -n "$BIND_IP" ] || die "no IPv4 address on any NIC"
[ -z "$SSH_PORT" ] && { [ -n "$PUB_NIC" ] && SSH_PORT=3222 || SSH_PORT=22; }
say "role=$ROLE bind=$BIND_IP url_ip=$URL_IP pub_nic=${PUB_NIC:-none} priv=${PRIV_NIC:-none} md_pub=${MD_PUB:-none} ssh=$SSH_PORT"

# == 2. base OS: time, locale, apt
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
cat > /etc/sysctl.d/90-yallacloud-odoo.conf <<EOF
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
fs.file-max = 1048576
net.ipv4.ip_nonlocal_bind = 1
EOF
sysctl -q --system

# == 3. SSH: root + password, no "login as ubuntu"
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
[ -f "$INFO/secrets.env" ] && . "$INFO/secrets.env"
: "${DB_PASS:=$(genpw)}"; : "${MASTER_PASS:=$(genpw)}"; : "${ADMIN_PASS:=$(genpw)}"
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
[ "$ROLE" != app ] && pg_install

# == 6. firewall
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
    curl -fsSL --retry 3 -o /tmp/wkhtmltox.deb https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb || die "wkhtmltox download failed"
    apt-get -y -q install /tmp/wkhtmltox.deb || die "wkhtmltox install failed"
  fi
  # Odoo .deb: GitHub release mirror first (nightly.odoo.com is unreliable), checked by .sha256;
  # fallback = nightly apt repo over http (key pinned by fingerprint, apt checks Release.gpg).
  local pkg=odoo
  if ! dpkg -s odoo >/dev/null 2>&1; then
    say "downloading Odoo deb (~330 MB) from $ODOO_DEB_URL"
    if curl -fsSL --retry 3 --connect-timeout 20 --speed-limit 10240 --speed-time 120 -o /tmp/odoo.deb "$ODOO_DEB_URL" \
       && curl -fsSL --retry 3 -o /tmp/odoo.deb.sha256 "$ODOO_DEB_URL.sha256" \
       && [ "$(sha256sum /tmp/odoo.deb | cut -d' ' -f1)" = "$(cut -d' ' -f1 /tmp/odoo.deb.sha256)" ]; then
      chmod 644 /tmp/odoo.deb; pkg=/tmp/odoo.deb; say "odoo deb sha256 ok"
    else
      warn "GitHub odoo deb failed or sha256 mismatch - fallback nightly.odoo.com"
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
db_maxconn = 16
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
[ "$ROLE" != db ] && odoo_install

# == 8. odoo-domain command (nginx + cert + base url)
cat > /usr/local/sbin/odoo-domain <<'DOMEOF'
#!/bin/bash
# odoo-domain <fqdn> | --sslip | --ip | --show    (YallaCloud Odoo 20)
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
write_https(){ { head_
  echo "server { listen $BIND_IP:80 default_server; server_name _; location /.well-known/acme-challenge/ { root /var/www/html; } location / { return 301 https://$HOST\$request_uri; } }"
  echo "server {"; echo "    listen $BIND_IP:443 ssl http2;"; echo "    server_name $HOST;"
  echo "    ssl_certificate /etc/letsencrypt/live/$HOST/fullchain.pem;"; echo "    ssl_certificate_key /etc/letsencrypt/live/$HOST/privkey.pem;"
  echo "    ssl_protocols TLSv1.2 TLSv1.3; ssl_session_cache shared:SSL:10m;"
  echo "    add_header Strict-Transport-Security \"max-age=31536000\" always;"; loc; echo "}"; } > "$NG"; }
reload(){ ln -sf "$NG" /etc/nginx/sites-enabled/odoo; rm -f /etc/nginx/sites-enabled/default
          nginx -t || { echo "nginx -t failed"; exit 3; }
          systemctl enable nginx >/dev/null 2>&1; systemctl restart nginx || { journalctl -u nginx -n 5 --no-pager; exit 3; }; }
write_http; reload
URL="http://${HOST:-$URL_IP}"
if [ "$MODE" = fqdn ]; then
  RES=$(getent ahostsv4 "$HOST" | awk '{print $1; exit}')
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

# persist effective config (no secrets) for re-runs and odoo-domain
cat > "$CFG" <<EOF
ROLE=$ROLE
DOMAIN=$DOMAIN
LE_EMAIL=$LE_EMAIL
DB_HOST=$DB_HOST
APP_ALLOW=$APP_ALLOW
ODOO_DB=$ODOO_DB
PG_VERSION=$PG_VERSION
TZ_SET=$TZ_SET
LOCALE_SET=$LOCALE_SET
APT_MIRRORS="$APT_MIRRORS"
SSH_PORT=$SSH_PORT
PASS_URL="$PASS_URL"
DISABLE_CLOUD_INIT=$DISABLE_CLOUD_INIT
PUBLIC_IP=$PUBLIC_IP
ODOO_DEB_URL=$ODOO_DEB_URL
EOF
chmod 600 "$CFG"

if [ "$ROLE" != db ]; then
  if [ -n "$DOMAIN" ]; then odoo-domain "$DOMAIN"; else odoo-domain --sslip; fi
  for i in $(seq 1 30); do curl -fs -o /dev/null --max-time 5 "http://127.0.0.1:8069/web/login" && break; sleep 4; done
fi

# == 9. handover + motd
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
fi
if [ "$ROLE" != app ]; then
[ "$ROLE" = db ] && PGAT="${PRIV_NIC:-$BIND_IP}:5432" || PGAT="localhost (unix socket, peer auth)"
echo "postgres    : $PG_VERSION on $PGAT  role odoo / $DB_PASS"
[ "$ROLE" = db ] && echo "allowed     : $APP_ALLOW  -> for the APP VM set  DB_HOST=${PRIV_NIC:-$BIND_IP}  DB_PASS='$DB_PASS'"
else
echo "postgres    : $DB_HOST:5432  role odoo / $DB_PASS"
fi
} > "$INFO/handover.txt"
umask 022
cat > /etc/update-motd.d/99-yallacloud-odoo <<'EOF'
#!/bin/sh
echo; echo "  YallaCloud Odoo 20 - role $(. /etc/yallacloud/odoo.conf.env; echo $ROLE)"
[ -f /root/odoo-info/URL ] && echo "  URL: $(cat /root/odoo-info/URL)   (change: odoo-domain <fqdn>)"
echo "  Credentials: /root/odoo-info/handover.txt   Full picture: yallacloud"; echo
EOF
chmod 755 /etc/update-motd.d/99-yallacloud-odoo
# == 9b. 'yallacloud' command: the whole picture of this server for a tech or the client
echo "yc-odoo20-install v1.1.0 installed $(date '+%F %T %Z')" > /etc/yallacloud/odoo.version
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
if ls /etc/letsencrypt/live/*/cert.pem >/dev/null 2>&1; then h "TLS certificates (auto-renew: certbot.timer)"
  for c in /etc/letsencrypt/live/*/cert.pem; do kv "$(basename "$(dirname "$c")")" "expires $(openssl x509 -enddate -noout -in "$c" | cut -d= -f2)"; done; fi
h "Scheduled jobs"
systemctl list-timers --no-legend 2>/dev/null | awk '{print "  timer  "$(NF-1)}' | sort -u
crontab -l 2>/dev/null | grep -v '^#' | sed 's/^/  root cron  /'
ls /etc/cron.d 2>/dev/null | sed 's/^/  cron.d  /'
[ -f "$C" ] && echo "  odoo   $(pgsql "select count(*) from ir_cron where active" 2>/dev/null) active Odoo scheduled actions in DB $(oc db_name) (Settings > Technical > Scheduled Actions)"
h "Backups"
b=""
systemctl list-unit-files 2>/dev/null | grep -qiE 'acronis|aakore' && b="$b Acronis agent installed (policy + retention in the Acronis console);"
command -v proxmox-backup-client >/dev/null && b="$b PBS client present;"
grep -rlsE 'pg_dump|pg_basebackup' /etc/cron* /var/spool/cron 2>/dev/null | grep -q . && b="$b pg_dump job in cron;"
kv in-guest "${b:-NONE configured on this VM}"
kv note "snapshots / PBS of the VM are set in CloudStack, not visible from inside"
h "Logs and retention"
kv odoo "/var/log/odoo/odoo-server.log (weekly, 8 kept)"
kv nginx "/var/log/nginx/ (daily, 14 kept)"
kv install "/var/log/yc-odoo-install.log, /var/log/yc-odoo-userdata.log"
kv journal "$(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]*[KMGT]')"
h "Resources"
kv cpu/ram "$(nproc) vCPU, $(free -h | awk '/Mem:/{print $2" RAM, "$3" used"}'), swap $(free -h | awk '/Swap:/{print $2}')"
kv disk "$(df -h / | awk 'NR==2{print $4" free of "$2" ("$5" used)"}')"
h "Commands"
kv "odoo-domain" "--show | <fqdn> | --sslip | --public <ip> --sslip | --ip"
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
say "DONE. $(grep -E '^(odoo url|postgres)' "$INFO/handover.txt" | tr '\n' ' ')"
cat "$INFO/handover.txt"
