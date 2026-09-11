#!/bin/bash
###############################################################################
#  yc-nextcloud-manual.sh  1.2.0                                              #
#  Run this AS ROOT on a fresh Ubuntu 24.04 LTS VM.                          #
#  VM to install a production Nextcloud with a Let's Encrypt certificate.     #
#                                                                            #
#  Self-contained: it fetches ONLY the distro's own apt repos,               #
#  download.nextcloud.com (the server tarball) and Let's Encrypt.            #
#                                                                            #
#  1. Edit the CONFIG block below.                                           #
#  2. chmod +x yc-nextcloud-manual.sh                                        #
#  3. sudo ./yc-nextcloud-manual.sh                                          #
#                                                                            #
#  Progress: /var/log/yc-nextcloud-install.log                              #
#  Result:   /root/yc-handover.json   (all passwords, chmod 600)            #
###############################################################################
set -uo pipefail

# ============================ CONFIG - EDIT THESE ============================
FQDN="cloud.example.com"        # the domain users will type. MUST already have
                                # a DNS A record pointing at the PUBLIC IP that
                                # reaches this VM (see the firewall note below).

ADMIN_USER="admin"              # Nextcloud admin login
DATA_PATH="/nc_data"            # where user files live
TIER="standard"                 # basic | standard | hardened (hardened forces 2FA)
TZ_SET="Asia/Dubai"
PHONE_REGION="AE"
SUDO_USER_NAME="chadmin"        # extra sudo user created on the VM
HTTPS_PORT=""                   # blank = 443 (standard). Set e.g. 8443 for a
                                # custom HTTPS port. Port 80 is still used for the
                                # Let's Encrypt check, so LE works either way.
SET_HOSTNAME="yes"             # yes = run hostnamectl set-hostname $FQDN + /etc/hosts
TARBALL=""                     # blank = download Nextcloud from download.nextcloud.com.
                                # Set to a LOCAL pre-downloaded archive to skip the
                                # download entirely, e.g. TARBALL="/root/latest.tar.bz2"
                                # (a sibling .sha256/.sha512 is used to verify it).
APT_MIRROR="ae.archive.ubuntu.com"  # apt archive mirror (UAE). Change per region if needed.
TARBALL_URL=""                 # optional INTERNAL mirror (e.g. pbs01) serving
                                # latest.tar.bz2 + latest.tar.bz2.sha256. When set and
                                # TARBALL is not already a local file, both are pulled
                                # to /root over the LAN (fast, no nextcloud.com, no
                                # FortiGate throttle), e.g. "http://10.x.x.x/nextcloud".

# --- overrides (leave blank to auto-detect) ---------------------------------
SSH_PORT_OVERRIDE=""            # blank = 3222 if the VM has a public IP, else 22.
                                # behind a firewall (private IP) leave blank -> 22.
GATEWAY_OVERRIDE=""             # blank = auto (tries .1, then .254, then .2).
                                # set to your firewall's LAN IP, e.g. 172.30.30.1,
                                # if auto-detect picks the wrong one.
# ============================================================================
#
#  >>> FIREWALL / NAT CASE (private IP like 172.30.30.3) <<<
#  For Let's Encrypt to succeed, the firewall must forward, from the PUBLIC IP
#  the A record points at, to THIS VM:
#        TCP 80  -> <this VM>:80     (required for the certificate)
#        TCP 443 -> <this VM>:443    (required for clients to reach it)
#  If port 80 is not forwarded, the install still completes and the site comes
#  up on a temporary self-signed cert; re-run  certbot --nginx -d <FQDN>  once
#  the forward is in place.
#
###############################################################################

CFG=/etc/yallacloud/nextcloud.conf
LOG=/var/log/yc-nextcloud-install.log
OUT=/root/yc-handover.json
exec > >(tee -a "$LOG") 2>&1

say()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "YC-FATAL: $*" | tee /root/yc-INSTALL-FAILED; exit 1; }
# YallaCloud password rule (stated 2026-09-08): length 16, first char A-Z,
# last char a-z, at least two '#' (the ONLY symbol allowed), at least one digit,
# both cases present; confusables O 0 o I l 1 excluded. CSPRNG via /dev/urandom.
genpw() {
    local U="ABCDEFGHJKLMNPQRSTUVWXYZ" L="abcdefghijkmnpqrstuvwxyz" D="23456789"
    local A="${U}${L}${D}#" len=16
    _p() { local s="$1"; printf '%s' "${s:$(( $(od -An -N2 -tu2 /dev/urandom) % ${#s} )):1}"; }
    # required middle content: two '#' and one digit, then fill to length-2
    local -a m=('#' '#' "$(_p "$D")"); local i
    for i in $(seq 1 $((len-2-3))); do m+=("$(_p "$A")"); done
    # Fisher-Yates shuffle of the middle
    local n=${#m[@]} j t
    for ((i=n-1;i>0;i--)); do
        j=$(( $(od -An -N2 -tu2 /dev/urandom) % (i+1) )); t=${m[i]}; m[i]=${m[j]}; m[j]=$t
    done
    printf '%s%s%s\n' "$(_p "$U")" "$(IFS=; echo "${m[*]}")" "$(_p "$L")"
}
rnd()  { genpw; }   # every generated secret now follows the YallaCloud rule

[ "$(id -u)" = "0" ] || die "run this as root (sudo ./yc-nextcloud-manual.sh)"
# userdata / re-run: an existing conf (written by cloud-init) OVERRIDES the
# CONFIG block above, so one embedded installer serves many VMs.
[ -f "$CFG" ] && . "$CFG"
case "$FQDN" in cloud.example.com|"") die "edit FQDN in the CONFIG block first";; esac
: "${HTTPS_PORT:=443}"           # blank -> standard 443 (nginx listen needs a port)

# persist the choices so a re-run and the handover agree
mkdir -p /etc/yallacloud
cat > "$CFG" <<EOF
FQDN=$FQDN
ADMIN_USER=$ADMIN_USER
DATA_PATH=$DATA_PATH
TIER=$TIER
TZ_SET=$TZ_SET
PHONE_REGION=$PHONE_REGION
SUDO_USER_NAME=$SUDO_USER_NAME
HTTPS_PORT=$HTTPS_PORT
SET_HOSTNAME=$SET_HOSTNAME
TARBALL=$TARBALL
TARBALL_URL=$TARBALL_URL
APT_MIRROR=$APT_MIRROR
EOF
chmod 600 "$CFG"

# ------------------------------------------- 1. network: classify, stabilise
# NETWORK IS CHECKED FIRST. Nothing else runs until the VM has an address,
# a default route, and a gateway that actually answers.
# Runs before anything that needs the network. Uses only local facts:
# the routing table and ARP/ICMP to the gateway. No DNS, no internet.
#
# Three shapes are supported:
#   direct-public   VM holds a public IP on a shared network        (VR present)
#   vr-private      VM holds a private IP, CloudStack VR is the gw  (VR present)
#   isolated-fw     VM holds a private IP behind a tenant firewall  (no VR gw)
#
# The isolated case is the one that breaks: CloudStack hands out the network's
# declared gateway (x.x.x.254), nothing answers there, and the real gateway is
# the firewall on x.x.x.1. That is corrected here and made persistent.

NET_REPORT=/root/yc-network-report.json

gw_alive() {                      # does this gateway actually answer?
    local gw="$1" dev="$2"
    ping -c 2 -W 2 -I "$dev" "$gw" >/dev/null 2>&1 && return 0
    command -v arping >/dev/null 2>&1 && arping -c 2 -w 3 -I "$dev" "$gw" >/dev/null 2>&1 && return 0
    ip neigh show "$gw" dev "$dev" 2>/dev/null | grep -qE 'REACHABLE|STALE|DELAY' && return 0
    return 1
}

persist_gateway() {               # survive a reboot, without fighting cloud-init
    local dev="$1" gw="$2"
    mkdir -p /etc/netplan
    cat > /etc/netplan/99-yallacloud-gateway.yaml <<EOF
# Written by yc-nextcloud: the CloudStack-declared gateway does not answer on
# this isolated network; the tenant firewall does. Do not remove.
network:
  version: 2
  ethernets:
    ${dev}:
      routes:
        - to: default
          via: ${gw}
EOF
    chmod 600 /etc/netplan/99-yallacloud-gateway.yaml
    netplan apply >/dev/null 2>&1 || true
}

stabilise_network() {
    local dev ip gw base cand shape="unknown" fixed="no" tries
    # wait for an address at all - the NIC may still be coming up
    for tries in $(seq 1 30); do
        dev=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
        [ -z "$dev" ] && dev=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2; exit}')
        ip=$(ip -o -4 addr show dev "${dev:-lo}" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$ip" ] && break
        sleep 2
    done
    [ -n "$ip" ] || die "no IPv4 address after 60s - the NIC never came up"
    gw=$(ip -4 route show default dev "$dev" 2>/dev/null | awk '{print $3; exit}')
    say "interface $dev  address $ip  declared gateway ${gw:-none}"

    case "$ip" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) IS_PUBLIC=0 ;;
        *) IS_PUBLIC=1 ;;
    esac

    if [ -n "$GATEWAY_OVERRIDE" ]; then
        say "gateway override set: $GATEWAY_OVERRIDE"
        ip route replace default via "$GATEWAY_OVERRIDE" dev "$dev" 2>/dev/null || true
        persist_gateway "$dev" "$GATEWAY_OVERRIDE"
        gw="$GATEWAY_OVERRIDE"; shape="manual-gateway"; fixed="yes"
    elif [ "$IS_PUBLIC" = "1" ]; then
        shape="direct-public"
        say "public address - shared network, gateway is the estate router"
    else
        # private: is the declared gateway real?
        if [ -n "$gw" ] && gw_alive "$gw" "$dev"; then
            shape="vr-private"
            say "private address, declared gateway $gw answers - CloudStack VR, nothing to fix"
        else
            say "declared gateway ${gw:-none} does not answer - isolated network behind a firewall"
            base="${ip%.*}"
            # the estate's convention: declared .254, real firewall on .1
            for cand in "${base}.1" "${base}.254" "${base}.2"; do
                [ "$cand" = "$gw" ] && continue
                say "  trying $cand"
                if gw_alive "$cand" "$dev"; then
                    say "  $cand answers - making it the default route"
                    ip route replace default via "$cand" dev "$dev" 2>/dev/null \
                        || die "could not set default route via $cand"
                    persist_gateway "$dev" "$cand"
                    gw="$cand"; shape="isolated-fw"; fixed="yes"
                    break
                fi
            done
            [ "$fixed" = "yes" ] || die "no usable gateway on ${base}.0/24 (tried .1 .254 .2).
      The VM has an address but nothing routes. Check the tenant firewall is up
      and on this network before re-running."
        fi
    fi

    # final local gate: a default route exists and the gateway answers.
    ip -4 route show default | grep -q . || die "no default route after stabilisation"
    gw_alive "$gw" "$dev" || die "gateway $gw stopped answering"

    NET_DEV="$dev"; NET_IP="$ip"; NET_GW="$gw"; NET_SHAPE="$shape"; NET_FIXED="$fixed"
    cat > "$NET_REPORT" <<EOF
{"interface":"${dev}","ip":"${ip}","gateway":"${gw}","shape":"${shape}",
 "gateway_corrected":"${fixed}","is_public":${IS_PUBLIC},"at":"$(date -Is)"}
EOF
    say "network ready: shape=${shape} gw=${gw} corrected=${fixed}"
}

stabilise_network
PRIV_IP="$NET_IP"

if [ "$SET_HOSTNAME" = "yes" ]; then
    say "setting hostname to $FQDN"
    hostnamectl set-hostname "$FQDN" 2>/dev/null || true
    grep -q "[[:space:]]$FQDN\([[:space:]]\|$\)" /etc/hosts 2>/dev/null \
        || echo "127.0.1.1 $FQDN ${FQDN%%.*}" >> /etc/hosts
fi

# Only now is it reasonable to expect the internet to work.
say "waiting for outbound connectivity"
for tries in $(seq 1 30); do
    getent hosts download.nextcloud.com >/dev/null 2>&1 && break
    [ "$tries" = "30" ] && die "no DNS resolution after 60s - check the firewall's DNS and outbound rules"
    sleep 2
done

# SSH port: override wins; else 3222 on a public address, 22 behind NAT.
if [ -n "$SSH_PORT_OVERRIDE" ]; then SSH_PORT="$SSH_PORT_OVERRIDE"
elif [ "$IS_PUBLIC" = "1" ]; then SSH_PORT=3222; else SSH_PORT=22; fi
say "ssh port will be ${SSH_PORT} ($([ "$IS_PUBLIC" = 1 ] && echo 'direct public' || echo 'private/NATted'))"

# --------------------------------------------------------------- 2. OS gate
. /etc/os-release
say "detected: $PRETTY_NAME"
# This build targets Ubuntu 24.04 LTS only.
case "${ID}-${VERSION_ID}" in
  ubuntu-24.04) PHPV=8.3 ;;
  *) die "this script is for Ubuntu 24.04 LTS only (found: ${PRETTY_NAME})." ;;
esac

# name the host after its domain (cosmetic - tidier logs/mail)
hostnamectl set-hostname "$FQDN" 2>/dev/null || true
grep -q "$FQDN" /etc/hosts || echo "127.0.1.1 $FQDN ${FQDN%%.*}" >> /etc/hosts
say "using distro PHP $PHPV - no third-party APT repositories are added"

# ------------------------------------------------------------ 3. secrets
DB_PASS=$(rnd 24); DB_ROOT_PASS=$(rnd 24)
ADMIN_PASS=$(rnd 18); SUDO_PASS=$(rnd 18); REDIS_PASS=$(rnd 24)
DB_NAME=nextcloud; DB_USER=nc_user01

# ------------------------------------------------------------- 4. packages
export DEBIAN_FRONTEND=noninteractive
timedatectl set-timezone "$TZ_SET" 2>/dev/null || true
# Ubuntu 24.04 repo fix: the default archive.ubuntu.com / cloudflare / eu.archive
# mirrors can be slow or unreachable on some networks. Repoint the archive host
# at APT_MIRROR (default the UAE mirror ae.archive.ubuntu.com). security.ubuntu.com
# is left as-is. Handles the deb822 ubuntu.sources and the legacy sources.list.
say "pointing apt archive mirror at ${APT_MIRROR}"
for F in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
  [ -f "$F" ] || continue
  sed -i -E "s#https?://([a-z0-9.-]*\\.)?archive\\.ubuntu\\.com/ubuntu#http://${APT_MIRROR}/ubuntu#g" "$F"
done
say "apt update"
apt-get update -qq || die "apt update failed"
apt-get upgrade -y -qq

say "installing nginx, mariadb, redis, php $PHPV"
apt-get install -y -qq \
  nginx mariadb-server redis-server certbot python3-certbot-nginx \
  php${PHPV}-fpm php${PHPV}-gd php${PHPV}-mysql php${PHPV}-curl php${PHPV}-mbstring \
  php${PHPV}-intl php${PHPV}-gmp php${PHPV}-bcmath php${PHPV}-xml php${PHPV}-imagick \
  php${PHPV}-zip php${PHPV}-redis php${PHPV}-apcu \
  ufw fail2ban unzip bzip2 ghostscript libfontconfig1 curl \
  || die "package installation failed"

# ------------------------------------------------------------- 5. database
say "configuring mariadb"

# --- MariaDB performance tuning (the c-rieger nextcloud-zero optimisation) ---
# innodb buffer pool ~= half of RAM, floored at 256M. Query cache is deliberately
# omitted: deprecated in MariaDB 10.11 and not needed by Nextcloud.
RAM_MB=$(awk "/MemTotal/{print int(\$2/1024)}" /proc/meminfo)
BP_MB=$(( RAM_MB / 2 )); [ "$BP_MB" -lt 256 ] && BP_MB=256
cat > /etc/mysql/mariadb.conf.d/90-yallacloud-nextcloud.cnf <<EOF
[mysqld]
# YallaCloud / Nextcloud tuning
skip-name-resolve
character-set-server        = utf8mb4
collation-server           = utf8mb4_general_ci
transaction_isolation      = READ-COMMITTED
binlog_format              = ROW
innodb_file_per_table      = 1
innodb_buffer_pool_size    = ${BP_MB}M
innodb_buffer_pool_instances = 1
innodb_log_buffer_size     = 32M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method        = O_DIRECT
innodb_read_only_compressed = OFF
tmp_table_size             = 64M
max_heap_table_size        = 64M
max_connections            = 200
EOF
say "  mariadb tuned (innodb_buffer_pool=${BP_MB}M of ${RAM_MB}M RAM)"
systemctl restart mariadb || die "mariadb failed to start after tuning - check /etc/mysql/mariadb.conf.d/90-yallacloud-nextcloud.cnf"

# Connect as OS root over the unix socket. --no-defaults ignores any stray
# /root/.my.cnf from a prior run (a password there would be REJECTED by the
# unix_socket plugin: "Access denied ... using password: YES"). Root stays on
# unix_socket - that IS the passwordless 'mysql' autologin, no password needed.
# Idempotent: IF NOT EXISTS + ALTER so a re-run refreshes the app user's pass.
if mysql --no-defaults -u root -e 'SELECT 1' >/dev/null 2>&1; then
    MROOT=(mysql --no-defaults -u root)
elif [ -f /root/.my.cnf ] && mysql -e 'SELECT 1' >/dev/null 2>&1; then
    MROOT=(mysql)
else
    die "cannot authenticate to MariaDB as root - a prior partial run left it in an unknown state. Purge and re-run: 'systemctl stop mariadb; apt-get purge -y mariadb-server; rm -rf /var/lib/mysql; apt-get install -y mariadb-server' then run this script again."
fi
"${MROOT[@]}" <<SQL || die "mariadb setup failed"
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# --- autologin: on MariaDB, OS root already logs in via unix_socket. Remove any
# password-bearing .my.cnf a prior run left, which would BREAK 'mysql'. ---
rm -f /root/.my.cnf
say "  root 'mysql' logs in automatically via unix_socket (no password needed)"

# ---------------------------------------------------------------- 6. redis
say "configuring redis"
sed -i "s/^# *requirepass .*/requirepass ${REDIS_PASS}/" /etc/redis/redis.conf
grep -q "^requirepass" /etc/redis/redis.conf || echo "requirepass ${REDIS_PASS}" >> /etc/redis/redis.conf
systemctl restart redis-server

# ------------------------------------------------------------------ 7. php
PHPINI=/etc/php/${PHPV}/fpm/php.ini
sed -i 's/^memory_limit = .*/memory_limit = 1024M/;
        s/^upload_max_filesize = .*/upload_max_filesize = 16G/;
        s/^post_max_size = .*/post_max_size = 16G/;
        s/^max_execution_time = .*/max_execution_time = 3600/;
        s/^max_input_time = .*/max_input_time = 3600/;
        s/^;date.timezone.*/date.timezone = '"${TZ_SET//\//\\/}"'/' "$PHPINI"
cat >> "$PHPINI" <<EOF

; yallacloud
opcache.enable=1
opcache.interned_strings_buffer=64
opcache.max_accelerated_files=10000
opcache.memory_consumption=256
opcache.revalidate_freq=1
EOF
systemctl restart php${PHPV}-fpm

# ---------------------------------------------------------- 8. the tarball
# Everything below stays on download.nextcloud.com. The fallbacks are
# alternate paths and formats on that same host, not third-party mirrors.

DL_RECORD=/root/yc-download-report.json
DL_DIR=/var/cache/yallacloud
mkdir -p "$DL_DIR"

# One attempt. Resumes a partial file, never silently accepts a short read.
try_fetch() {
    local url="$1" out="$2" code
    local rc
    # No -C -: a resume onto a file from a different URL produces a corrupt
    # archive that still looks plausible. Start clean, every time.
    rm -f "$out"
    code=$(curl -sSL --retry 3 --retry-delay 5 --retry-connrefused \
                --connect-timeout 20 --max-time 1800 \
                --speed-limit 10240 --speed-time 120 \
                -o "$out" -w '%{http_code}' "$url" 2>/dev/null)
    rc=$?
    # curl's exit code is the authority: --speed-time aborts mid-transfer while
    # the status line still says 200, which is exactly how a truncated file
    # reaches verification looking healthy.
    [ "$rc" -eq 0 ] || { say "  curl exit $rc (transfer aborted)"; return 1; }
    [ "$code" = "200" ] || [ "$code" = "206" ] || return 1
    [ -s "$out" ] || return 1
    return 0
}

# Is this actually the archive, and is it intact and complete?
verify_archive() {
    local f="$1" want="$2" magic got
    [ -s "$f" ] || { echo "empty file"; return 1; }
    magic=$(head -c 3 "$f")
    case "$f" in
        *.bz2) [ "$magic" = "BZh" ] || { echo "not bzip2 (got '${magic}') - connection is being intercepted"; return 1; } ;;
        *.zip) [ "${magic:0:2}" = "PK" ] || { echo "not a zip (got '${magic}') - connection is being intercepted"; return 1; } ;;
    esac
    if [ -n "$want" ]; then
        got=$(sha256sum "$f" | awk '{print $1}')
        [ "$got" = "$want" ] || { echo "sha256 mismatch: got $got want $want"; return 1; }
    fi
    case "$f" in
        *.bz2) tar -tjf "$f" >/dev/null 2>&1 || { echo "archive will not list - truncated"; return 1; } ;;
        *.zip) unzip -tq "$f" >/dev/null 2>&1 || { echo "archive will not list - truncated"; return 1; } ;;
    esac
    # the archive must actually be Nextcloud, not some other tarball
    local first
    case "$f" in
        *.bz2) first=$(tar -tjf "$f" 2>/dev/null | head -1) ;;
        *.zip) first=$(unzip -Z1 "$f" 2>/dev/null | head -1) ;;
    esac
    case "$first" in
        nextcloud/*) : ;;
        *) echo "archive does not start with nextcloud/ (got '${first}')"; return 1 ;;
    esac
    return 0
}

fetch_nextcloud() {
    local base=https://download.nextcloud.com/server/releases
    local -a CANDIDATES=(
        "$base/latest.tar.bz2"
        "$base/latest.zip"
    )
    # If we can learn the exact current version, prefer the pinned URL - a
    # versioned file cannot change under us between the checksum and the body.
    local ver
    ver=$(curl -sS --max-time 20 "$base/latest.tar.bz2.sha256" 2>/dev/null \
          | awk '{print $2}' | sed -n 's/^\*\?nextcloud-\(.*\)\.tar\.bz2$/\1/p' | head -1)
    if [ -n "$ver" ]; then
        say "current release is $ver"
        CANDIDATES=("$base/nextcloud-${ver}.tar.bz2" "${CANDIDATES[@]}")
    fi

    local attempts=0 max=3 url out sum err
    local -a JLOG=()
    for pass in $(seq 1 $max); do
        for url in "${CANDIDATES[@]}"; do
            attempts=$((attempts+1))
            out="$DL_DIR/$(basename "$url")"
            say "download attempt $attempts: $url"

            # the .sha256 file lists several artefacts - take the line for THIS file
            sum=$(curl -sS --max-time 20 "${url}.sha256" 2>/dev/null \
                  | awk -v f="$(basename "$url")" '$2==f || $2=="*"f {print $1; exit}')
            [ ${#sum} -eq 64 ] || sum=""
            [ -n "$sum" ] && say "  published sha256: ${sum:0:16}..." || say "  no published sha256 - falling back to magic bytes and archive test"

            # two goes at this URL before falling back to another format:
            # a 250 MB transfer over a saturated link deserves a second chance
            local inner
            err="not attempted"
            for inner in 1 2; do
                if ! try_fetch "$url" "$out"; then
                    err="transfer failed or was truncated"
                elif ! err=$(verify_archive "$out" "$sum"); then
                    :
                else
                    err=""; break
                fi
                [ "$inner" = "1" ] && say "  retrying same URL after: $err"
            done

            if [ -z "$err" ]; then
                say "  verified OK ($(du -h "$out" | cut -f1))"
                JLOG+=("{\"attempt\":$attempts,\"url\":\"$url\",\"result\":\"ok\"}")
                NC_TARBALL="$out"
                NC_SHA="${sum:-unverified}"
                NC_ATTEMPTS=$attempts
                printf '{"attempts":%d,"chosen":"%s","sha256":"%s","log":[%s],"at":"%s"}\n' \
                    "$attempts" "$url" "${sum:-unverified}" \
                    "$(IFS=,; echo "${JLOG[*]}")" "$(date -Is)" > "$DL_RECORD"
                chmod 600 "$DL_RECORD"
                return 0
            fi

            say "  FAILED: $err"
            JLOG+=("{\"attempt\":$attempts,\"url\":\"$url\",\"result\":\"$err\"}")
            rm -f "$out"
        done
        [ "$pass" -lt "$max" ] && { say "pass $pass exhausted, waiting $((pass*20))s"; sleep $((pass*20)); }
    done

    printf '{"attempts":%d,"chosen":null,"log":[%s],"at":"%s"}\n' \
        "$attempts" "$(IFS=,; echo "${JLOG[*]}")" "$(date -Is)" > "$DL_RECORD"
    chmod 600 "$DL_RECORD"
    return 1
}

# optional: pull the archive from an internal mirror (pbs01) before the
# local-file check below. LAN transfer - no nextcloud.com, no FortiGate throttle.
if [ -n "$TARBALL_URL" ] && { [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; }; then
    TARBALL="/root/latest.tar.bz2"
    say "fetching Nextcloud from internal mirror $TARBALL_URL"
    curl -fSL --retry 3 --retry-delay 5 -o "$TARBALL"        "$TARBALL_URL/latest.tar.bz2"        || die "mirror fetch failed: $TARBALL_URL/latest.tar.bz2"
    curl -fSL --retry 3 --retry-delay 5 -o "${TARBALL}.sha256" "$TARBALL_URL/latest.tar.bz2.sha256" || say "  no .sha256 at mirror - will check archive integrity only"
    say "  mirror fetch done ($(du -h "$TARBALL" | cut -f1))"
fi
if [ -n "$TARBALL" ] && [ -f "$TARBALL" ]; then
    say "using local Nextcloud archive $TARBALL (no download)"
    # pull a 64-hex sha256 out of the sibling file whatever its format
    # (GNU "hash  file", BSD "SHA256 (file) = hash", or a bare hash)
    lsum=""
    [ -f "${TARBALL}.sha256" ] && lsum=$(grep -oiE "[0-9a-f]{64}" "${TARBALL}.sha256" | head -1)
    [ ${#lsum} -eq 64 ] || lsum=""
    [ -n "$lsum" ] && say "  verifying against ${TARBALL}.sha256" \
                   || say "  no sibling .sha256 - checking magic bytes + archive integrity only"
    if lerr=$(verify_archive "$TARBALL" "$lsum"); then
        NC_TARBALL="$TARBALL"; NC_SHA="${lsum:-local-unverified}"; NC_ATTEMPTS=0
        say "  local archive verified OK ($(du -h "$TARBALL" | cut -f1))"
    else
        die "local archive $TARBALL failed verification: $lerr"
    fi
elif [ -n "$TARBALL" ]; then
    die "TARBALL set to '$TARBALL' but that file does not exist"
else
    say "fetching Nextcloud from download.nextcloud.com"
    fetch_nextcloud || die "could not obtain a verified Nextcloud archive after $NC_ATTEMPTS attempts.
      Report: $DL_RECORD
      Either fix egress to download.nextcloud.com, or pre-download latest.tar.bz2
      and set TARBALL=/path/to/latest.tar.bz2 in the CONFIG block."
fi

say "extracting $(basename "$NC_TARBALL")"
case "$NC_TARBALL" in
    *.bz2) tar -xjf "$NC_TARBALL" -C /var/www || die "extract failed" ;;
    *.zip) unzip -q "$NC_TARBALL" -d /var/www || die "extract failed" ;;
esac
[ -f /var/www/nextcloud/occ ] || die "extract produced no /var/www/nextcloud/occ"
mkdir -p "$DATA_PATH"
chown -R www-data:www-data /var/www/nextcloud "$DATA_PATH"

# ---------------------------------------------------------------- 9. nginx
say "configuring nginx for $FQDN"
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/nextcloud <<EOF
upstream php-handler { server unix:/run/php/php${PHPV}-fpm.sock; }
server {
    listen 80; listen [::]:80;
    server_name ${FQDN};
    root /var/www/nextcloud;
    location ^~ /.well-known/acme-challenge { default_type "text/plain"; root /var/www/nextcloud; }
    location / { return 301 https://\$host:${HTTPS_PORT}\$request_uri; }
}
server {
    listen ${HTTPS_PORT} ssl http2; listen [::]:${HTTPS_PORT} ssl http2;
    ssl_certificate /etc/ssl/yc/tmp.crt;
    ssl_certificate_key /etc/ssl/yc/tmp.key;
    server_name ${FQDN};
    root /var/www/nextcloud;
    client_max_body_size 16G;
    client_body_timeout 3600s;
    fastcgi_buffers 64 4K;

    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=15768000; includeSubDomains" always;

    index index.php index.html /index.php\$request_uri;
    location = / { if ( \$http_user_agent ~ ^DavClnt ) { return 302 /remote.php/webdav/\$is_args\$args; } }
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }
        location /.well-known/acme-challenge { try_files \$uri \$uri/ =404; }
        return 301 /index.php\$request_uri;
    }
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:\$|/) { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)          { return 404; }
    location ~ \\.php(?:\$|/) {
        rewrite ^/(?!index|remote|public|cron|core\\/ajax\\/update|status|ocs\\/v[12]|updater\\/.+|ocs-provider\\/.+|.+\\/richdocumentscode\\/proxy) /index.php\$request_uri;
        fastcgi_split_path_info ^(.+?\\.php)(/.*)\$;
        set \$path_info \$fastcgi_path_info;
        try_files \$fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass php-handler;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        fastcgi_read_timeout 3600;
    }
    location ~ \\.(?:css|js|mjs|svg|gif|png|jpg|ico|wasm|tflite|map|ogg|flac)\$ {
        try_files \$uri /index.php\$request_uri;
        expires 6M; access_log off;
    }
    location ~ \\.woff2?\$ { try_files \$uri /index.php\$request_uri; expires 7d; access_log off; }
    location /remote { return 301 /remote.php\$request_uri; }
    location / { try_files \$uri \$uri/ /index.php\$request_uri; }
}
EOF
ln -sf /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud

# a temporary self-signed pair so nginx starts before certbot runs
mkdir -p /etc/ssl/yc
openssl req -x509 -nodes -days 3 -newkey rsa:2048 \
  -keyout /etc/ssl/yc/tmp.key -out /etc/ssl/yc/tmp.crt -subj "/CN=${FQDN}" 2>/dev/null
nginx -t || die "nginx config test failed"
systemctl restart nginx

# ----------------------------------------------------------- 10. nextcloud
say "installing Nextcloud"
sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
  --database mysql --database-name "$DB_NAME" \
  --database-user "$DB_USER" --database-pass "$DB_PASS" \
  --admin-user "$ADMIN_USER" --admin-pass "$ADMIN_PASS" \
  --data-dir "$DATA_PATH" || die "occ maintenance:install failed"

O="sudo -u www-data php /var/www/nextcloud/occ"
$O config:system:set trusted_domains 0 --value="$FQDN"
$O config:system:set trusted_domains 1 --value="$PRIV_IP"
PORTSFX=""; [ "$HTTPS_PORT" != "443" ] && PORTSFX=":$HTTPS_PORT"
$O config:system:set trusted_domains 2 --value="${FQDN}${PORTSFX}"
$O config:system:set overwrite.cli.url --value="https://${FQDN}${PORTSFX}"
$O config:system:set overwriteprotocol --value="https"
$O config:system:set default_phone_region --value="$PHONE_REGION"
$O config:system:set default_locale --value="en_GB"
$O config:system:set maintenance_window_start --type=integer --value=1
$O config:system:set memcache.local --value='\OC\Memcache\APCu'
$O config:system:set memcache.distributed --value='\OC\Memcache\Redis'
$O config:system:set memcache.locking --value='\OC\Memcache\Redis'
$O config:system:set redis host --value=localhost
$O config:system:set redis port --type=integer --value=6379
$O config:system:set redis password --value="$REDIS_PASS"
$O background:cron
$O db:add-missing-indices
$O maintenance:repair --include-expensive
echo '*/5 * * * * php -f /var/www/nextcloud/cron.php' | crontab -u www-data -

# ----------------------------------------------------------------- 11. ssl
say "requesting a Let's Encrypt certificate for $FQDN (HTTP-01 on port 80)"
mkdir -p /var/www/nextcloud
if certbot certonly --webroot -w /var/www/nextcloud -n --agree-tos \
     --register-unsafely-without-email -d "$FQDN" >/dev/null 2>&1; then
  # point nginx at the real cert (replaces the temporary self-signed pair)
  sed -i "s#ssl_certificate .*#ssl_certificate /etc/letsencrypt/live/${FQDN}/fullchain.pem;#;
          s#ssl_certificate_key .*#ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;#" \
    /etc/nginx/sites-available/nextcloud
  nginx -t && systemctl reload nginx
  say "certificate issued and installed"
  SSL_OK=yes
else
  say "WARNING: Let's Encrypt failed - the site is up on the temporary self-signed cert."
  say "         Port 80 must be reachable from the internet (NAT 80 -> this VM:80)."
  say "         Once forwarded, run: certbot certonly --webroot -w /var/www/nextcloud -d $FQDN"
  say "         then reload nginx."
  SSL_OK=no
fi

# ------------------------------------------------------- 12. accounts, ssh
say "creating sudo user ${SUDO_USER_NAME} and setting ssh port ${SSH_PORT}"
if ! id "$SUDO_USER_NAME" >/dev/null 2>&1; then
  adduser --gecos "" --disabled-password "$SUDO_USER_NAME" >/dev/null
  usermod -aG sudo "$SUDO_USER_NAME"
fi
chpasswd <<<"${SUDO_USER_NAME}:${SUDO_PASS}"
if [ "$SSH_PORT" != "22" ]; then
  sed -i '/^#\?Port /d' /etc/ssh/sshd_config
  echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
  # Ubuntu 24.04 uses socket activation (ssh.socket) which listens on 22 and
  # OVERRIDES the Port in sshd_config. Point the socket at the new port too.
  if systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/port.conf <<EOS
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
EOS
    systemctl daemon-reload
    systemctl restart ssh.socket 2>/dev/null || true
  fi
fi

# ------------------------------------------------------ 13. firewall, tier
say "hardening (tier: $TIER)"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
ufw allow ${SSH_PORT}/tcp comment 'SSH' >/dev/null
ufw allow 80/tcp  comment 'LetsEncrypt(http)' >/dev/null
ufw allow ${HTTPS_PORT}/tcp comment 'TLS(https)' >/dev/null
ufw --force enable >/dev/null

cat > /etc/fail2ban/filter.d/nextcloud.conf <<'EOF'
[Definition]
_groupsre = (?:(?:,?\s*"\w+":(?:"[^"]+"|\w+))*)
failregex = ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Login failed:
            ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Trusted domain error.
datepattern = ,?\s*"time"\s*:\s*"%%Y-%%m-%%d[T ]%%H:%%M:%%S(%%z)?"
EOF
cat > /etc/fail2ban/jail.d/nextcloud.local <<EOF
[nextcloud]
backend  = auto
enabled  = true
port     = 80,443
protocol = tcp
filter   = nextcloud
maxretry = 3
bantime  = 3600
findtime = 600
logpath  = ${DATA_PATH}/nextcloud.log
[sshd]
enabled = true
port    = ${SSH_PORT}
maxretry = 3
bantime  = 3600
EOF

if [ "$TIER" != "basic" ]; then
  $O config:system:set auth.bruteforce.protection.enabled --type=boolean --value=true
  $O config:system:set trashbin_retention_obligation --value="auto, 30"
  $O config:system:set versions_retention_obligation --value="auto, 90"
fi
if [ "$TIER" = "hardened" ]; then
  $O app:install twofactor_totp >/dev/null 2>&1
  $O app:enable  twofactor_totp >/dev/null 2>&1
  $O config:app:set twofactor_totp enforced --value=1 >/dev/null 2>&1
fi

systemctl restart fail2ban ssh nginx php${PHPV}-fpm
systemctl enable --now nginx mariadb redis-server fail2ban php${PHPV}-fpm >/dev/null 2>&1

# ------------------------------------------------------------ 14. handover
NC_VER=$($O status 2>/dev/null | awk '/versionstring/{print $3}')
ISSUER=$(echo | timeout 10 openssl s_client -connect "${FQDN}:443" -servername "$FQDN" 2>/dev/null \
         | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
APPSTORE=$(curl -sS -o /dev/null -m 15 -w '%{http_code}' https://apps.nextcloud.com/ 2>/dev/null)

cat > "$OUT" <<EOF
{
  "fqdn": "${FQDN}",
  "url": "https://${FQDN}${PORTSFX}",
  "nextcloud_version": "${NC_VER}",
  "os": "${PRETTY_NAME}",
  "php": "${PHPV}",
  "admin_user": "${ADMIN_USER}",
  "admin_password": "${ADMIN_PASS}",
  "sudo_user": "${SUDO_USER_NAME}",
  "sudo_password": "${SUDO_PASS}",
  "ssh_port": ${SSH_PORT},
  "is_public": ${IS_PUBLIC},
  "network_shape": "${NET_SHAPE}",
  "gateway": "${NET_GW}",
  "gateway_corrected": "${NET_FIXED}",
  "ip": "${PRIV_IP}",
  "data_path": "${DATA_PATH}",
  "db_name": "${DB_NAME}",
  "db_user": "${DB_USER}",
  "db_password": "${DB_PASS}",
  "db_root_password": "unix_socket (run 'mysql' as root - no password)",
  "redis_password": "${REDIS_PASS}",
  "security_tier": "${TIER}",
  "ssl": "${SSL_OK}",
  "certificate_issuer": "${ISSUER}",
  "app_store": "${APPSTORE}",
  "download_attempts": ${NC_ATTEMPTS:-0},
  "download_sha256": "${NC_SHA:-unknown}",
  "download_report": "/root/yc-download-report.json",
  "installed_at": "$(date -Is)"
}
EOF
chmod 600 "$OUT"
touch /root/yc-INSTALL-OK
say "DONE - handover written to $OUT"
say "URL https://${FQDN}  admin ${ADMIN_USER} / ${ADMIN_PASS}  ssh port ${SSH_PORT}"
