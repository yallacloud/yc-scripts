#!/bin/bash
####################
# yc-db-install.sh  v1.0.7  (2026-10-26 20:30 IST)  YallaCloud / OasisStack
# Database server (DBaaS node): MariaDB or Oracle MySQL Community, nothing else.
# OS: Ubuntu 24.04 | RHEL / Rocky / AlmaLinux / Oracle Linux 9 and 10.   Guide: STACK4-62.
#
# Cloud-init: yc-mariadb-userdata.sh / yc-mysql-userdata.sh write the answers to
# /etc/yallacloud/db.conf.env and start this script. Manual: run as root, values as arguments:
#   bash yc-db-install.sh ENGINE=mysql DB_VERSION=8.4 DB_NAME=shop DB_USER=shop
# Re-run any time (same answers, passwords kept): yc-db-install
#
# Result : /root/yc-db/handover.txt (credentials + connection strings, chmod 600) | yallacloud
# Log    : /var/log/yc-db-deploy.log (this run + cloud-init log merged)  Status: /var/log/yc-db-deploy.status
####################
set -uo pipefail
umask 022
export HOME=/root LC_ALL=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==== DEFAULTS (cloud-init answers in /etc/yallacloud/db.conf.env win, arguments win over both) ====
ENGINE="mariadb"            # mariadb | mysql
DB_VERSION=""               # mariadb 10.11|11.4|11.8|12.3 (blank 11.8) | mysql 8.4|9.7 (blank 8.4)
DB_PORT="3306"
DB_ALLOW=""                 # CIDR list (comma/space) allowed to DB_PORT. blank = any on a public VM, own subnet on a private VM
DB_ADMIN_USER="dbadmin"     # remote admin: ALL PRIVILEGES WITH GRANT OPTION, host %
DB_NAME=""                  # optional first database
DB_USER=""                  # optional user owning DB_NAME (blank = none)
DB_ROOT_PASS=""             # blank = generated (house rule: A-Z a-z 2-9 and '#' only)
DB_ADMIN_PASS=""
DB_USER_PASS=""
DATA_DISK="auto"            # auto = first empty extra disk -> XFS /data | none | /dev/vdb
BACKUP_KEEP_DAYS="15"       # daily dumps kept
BACKUP_KEEP_WEEKS="4"       # Sunday copies kept (0 = off)
BACKUP_KEEP_MONTHS="12"     # 1st-of-month copies kept (0 = off)
BACKUP_TIME="01:30"         # HH:MM local time
BINLOG="yes"                # binary log (point-in-time recovery / replicas)
BINLOG_DAYS="7"
PUBLIC_IP=""                # NAT / port-forward: the public IP clients use (blank = auto)
GATEWAY=""                  # private VM behind a firewall: firewall LAN IP (blank = auto .1/.254/.2)
SSH_PORT=""                 # blank = 3222 on a public IP, 22 on a private IP
SSH_PUBKEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDSMLjQxi/2e/MTTyuzD34SA+94GP1+Eyv3PjAXqSMhQy3MdWwZCrnrP+W7FON6ilIDhdI42usXmMhTr0eJQYsTwVdwMZE9OtF4SniauuN7YvJkG9O3W6YclGr0U8xqo4QH48ZQYntB37nP5PUIOgFKkVyH3T7MR2Dp8VZo0n6oa7hgMjIJOVcmC8zhEm0+4/JJSL60gaGA2/251jSELOlAVTalKyuOipZYjnNOY4TqU9owCRPJNGd9e3rP4QOO0p5xjtsFSNDMqacpCSYiIc26y2GNjOqthvWGa4/O84QmMqbtG053VrmNQZGSgmGw+4b9ajC/9Bh8dU0XSEN9ijqc1U86zNXL10GhhAV+H2R3V5wLPbFK3/NAPOi4sqZ1eXq6denlr6Ap2/cAvUT089v5L1CkoXaZY2QCLQleHH3jPRKzvzB+7g7R7VIDXVX977qleExzi48XinzV+W5+dZyHbAK+9iOf5orJGOMWWxj1LKYltPUQeY19B+H4fRDfhDmw7+94oqFxnDPjMaSdcTAosoQ4EdKwqBmtdWhDAaxsIHa1ynkmUo0IwbosDJayjl/GqHeiyAwWWG/7CKwJXTef4ZYETwIWdXobZElzh9/kGrKgoalzT5K5f6sBM/IBciPfhSz8PaOiWc0RwLEkqX8JtzzllgBZItuIKWpSWl4TUw== guest"   # root authorized_keys (one OpenSSH line, blank = none)
TZ_SET="Asia/Dubai"
LOCALE_SET="en_US.UTF-8"
SALT_JOIN="yes"             # join salt.oasisstack.io (zero-input join.sh)
ACRONIS_TOKEN=""            # blank = Acronis skipped
ACRONIS_REGION="AE"         # AE | SG
NTFY_URL="https://ntfy.sh/9890122212"   # no secrets are ever sent here
ERP_WEBHOOK_URL="https://api.yallacloud.net/api/v1/webhooks/cloudstack"
ERP_WEBHOOK_SECRET=""       # blank = ERP webhook skipped (carries the credentials)
CLOUDSTACK_URL="https://dxb01.oasisstack.io/client"   # portal this VM came from (cloudPortal / cloudVmUrl in the webhook)
# advanced
APT_MIRRORS="ae.archive.ubuntu.com archive.ubuntu.com"
PASS_URL="https://pass.oasisstack.io/?len=16"
REPO_URL="https://repo.oasisstack.io/db"       # local mirror (ycwsus01, YC ranges only)
DISABLE_CLOUD_INIT="yes"
# ================

VER=1.0.7
KEYS="ENGINE DB_VERSION DB_PORT DB_ALLOW DB_ADMIN_USER DB_NAME DB_USER DB_ROOT_PASS DB_ADMIN_PASS DB_USER_PASS DATA_DISK BACKUP_KEEP_DAYS BACKUP_KEEP_WEEKS BACKUP_KEEP_MONTHS BACKUP_TIME BINLOG BINLOG_DAYS PUBLIC_IP GATEWAY SSH_PORT SSH_PUBKEY TZ_SET LOCALE_SET SALT_JOIN ACRONIS_TOKEN ACRONIS_REGION NTFY_URL ERP_WEBHOOK_URL ERP_WEBHOOK_SECRET CLOUDSTACK_URL APT_MIRRORS PASS_URL REPO_URL DISABLE_CLOUD_INIT"
CFG=/etc/yallacloud/db.conf.env
LIB=/usr/local/lib/yc-db-common.sh
INFO=/root/yc-db
LOG=/var/log/yc-db-deploy.log
STATUS=/var/log/yc-db-deploy.status
mkdir -p /etc/yallacloud "$INFO" /var/lib/yallacloud; chmod 700 /etc/yallacloud "$INFO"
touch "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date '+%F %T')] $*"; }
WARNS=0; WARN_TXT=""
warn(){ say "WARN: $*"; WARNS=$((WARNS+1)); WARN_TXT="${WARN_TXT:+$WARN_TXT; }$*"; }
STEP=init; FAIL_REASON=""
step(){ STEP=$1; say "== $1"; }
die(){ FAIL_REASON="$*"; say "YC-FATAL [$STEP]: $*"; echo "$*" > "$INFO/INSTALL-FAILED"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
say "yc-db-install v$VER start (pid $$)"

# answers: defaults < cfg file < arguments (KEY=value)
[ -f "$CFG" ] && . "$CFG"
[ -f "$INFO/secrets.env" ] && . "$INFO/secrets.env"     # passwords of an earlier run are kept
for a in "$@"; do
  k=${a%%=*}
  [[ "$a" == *=* && " $KEYS " == *" $k "* ]] || die "unknown argument '$a' (use KEY=value, keys: $KEYS)"
  printf -v "$k" '%s' "${a#*=}"
done
SELF=$(readlink -f "$0" 2>/dev/null || true)
[ -f "$SELF" ] && [ "$SELF" != /usr/local/sbin/yc-db-install ] && install -m 700 "$SELF" /usr/local/sbin/yc-db-install

# ================= shared library (also used by yallacloud, yc-db-backup) =================
cat > "$LIB" <<'LIBEOF'
# yc-db-common.sh - YallaCloud DB helpers (STACK4-62). Sourced, never run.
is_priv(){ [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|169\.254\.|127\.) ]]; }
ip4(){ [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1; local n; for n in "${BASH_REMATCH[@]:1}"; do [ "$n" -le 255 ] || return 1; done; }
cidr_ok(){ local m=${1##*/}; [[ "$1" == */* ]] && ip4 "${1%/*}" && [[ "$m" =~ ^[0-9]{1,2}$ ]] && [ "$m" -le 32 ]; }
# CloudStack metadata: cloud-init cache first, then the virtual router
md(){
  local k="$1" v="" s
  v=$(python3 -c "import json,sys;d=json.load(open('/run/cloud-init/instance-data.json'));print(d.get('ds',{}).get('meta_data',{}).get(sys.argv[1],'') or '')" "$k" 2>/dev/null)
  if [ -z "$v" ]; then
    # the VR answers metadata on the DHCP server address (shared networks: NOT the gateway)
    for s in $(grep -hoE 'SERVER_ADDRESS=[0-9.]+' /run/systemd/netif/leases/* 2>/dev/null | cut -d= -f2) \
             $(nmcli -g DHCP4.OPTION device show 2>/dev/null | grep -oE 'dhcp_server_identifier = [0-9.]+' | awk '{print $3}') \
             $(ip -4 route show default | awk '{print $3}'); do
      v=$(curl -fs --max-time 3 "http://$s/latest/meta-data/$k" 2>/dev/null) && [ -n "$v" ] && break
    done
  fi
  printf '%s' "$v" | tr -d '\r\n'
}
# PUB_NIC/PRIV_NIC = first public/private NIC IP. HOST_PUB = what clients outside use (NIC, PUBLIC_IP, static NAT).
detect_ips(){
  local ip; PUB_NIC=""; PRIV_NIC=""
  for ip in $(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1); do
    if is_priv "$ip"; then [ -z "$PRIV_NIC" ] && PRIV_NIC=$ip; else [ -z "$PUB_NIC" ] && PUB_NIC=$ip; fi
  done
  MD_PUB=$(md public-ipv4); is_priv "$MD_PUB" && MD_PUB=""
  HOST_PUB=${PUBLIC_IP:-${PUB_NIC:-$MD_PUB}}
  HOST_PRIV=$PRIV_NIC
  PRIV_CIDR=""
  [ -n "$PRIV_NIC" ] && PRIV_CIDR=$(ip -o -4 route show scope link | awk -v s="$PRIV_NIC" '$0 ~ "src "s"( |$)" {print $1; exit}')
}
# YallaCloud password rule (STACK4-52): 8-16 chars, first A-Z, last a-z, >=2 '#' (the ONLY
# special character), >=1 digit, no O 0 o I l 1. Local CSPRNG first, pass.oasisstack.io fallback.
genpw_local(){
  local U="ABCDEFGHJKLMNPQRSTUVWXYZ" L="abcdefghijkmnpqrstuvwxyz" D="23456789" len=${1:-16}
  local A="${U}${L}${D}" i j t n
  _p(){ local s="$1"; printf '%s' "${s:$(( $(od -An -N2 -tu2 /dev/urandom) % ${#s} )):1}"; }
  local -a m=('#' '#' "$(_p "$D")"); for i in $(seq 1 $((len-5))); do m+=("$(_p "$A")"); done
  n=${#m[@]}; for ((i=n-1;i>0;i--)); do j=$(( $(od -An -N2 -tu2 /dev/urandom) % (i+1) )); t=${m[i]}; m[i]=${m[j]}; m[j]=$t; done
  printf '%s%s%s\n' "$(_p "$U")" "$(IFS=; echo "${m[*]}")" "$(_p "$L")"
}
pw_ok(){ [[ "$1" =~ ^[A-Z][A-HJ-NP-Za-km-np-z2-9#]{6,14}[a-z]$ ]] && [[ "$1" == *#*#* ]] && [[ "$1" =~ [2-9] ]]; }
genpw(){
  local p; p=$(genpw_local 16)
  pw_ok "$p" || p=$(curl -fs --max-time 8 "${PASS_URL:-https://pass.oasisstack.io/?len=16}" 2>/dev/null | tr -d '\r\n')
  pw_ok "$p" || return 1
  printf '%s\n' "$p"
}
urlpw(){ printf '%s' "${1//#/%23}"; }   # '#' must be %23 inside a URI
# gateway fix: CloudStack SDN without a gateway declares .254 (dead) while the tenant firewall is .1
gw_ok(){ ping -c 2 -W 2 -I "$2" "$1" >/dev/null 2>&1 || ip neigh show "$1" dev "$2" 2>/dev/null | grep -qE 'REACHABLE|STALE|DELAY|PERMANENT'; }
gw_persist(){   # $1 dev  $2 gateway
  if command -v netplan >/dev/null; then
    printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      routes:\n        - to: default\n          via: %s\n' "$1" "$2" > /etc/netplan/99-yallacloud-gateway.yaml
    chmod 600 /etc/netplan/99-yallacloud-gateway.yaml
  else   # NetworkManager (EL): metric 0 route beats the DHCP one and survives lease renewals
    printf '[Unit]\nDescription=YallaCloud default gateway fix (STACK4-62)\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/sbin/ip route replace default via %s dev %s metric 0\n[Install]\nWantedBy=multi-user.target\n' "$2" "$1" > /etc/systemd/system/yc-gateway.service
    systemctl daemon-reload; systemctl enable yc-gateway.service >/dev/null 2>&1
  fi
}
fix_gateway(){   # $1 = forced gateway, blank = auto
  local dev ip gw c cands
  dev=$(ip -4 route show default | awk '{print $5; exit}'); [ -n "$dev" ] || dev=$(ip -o -4 addr show scope global | awk '{print $2; exit}')
  ip=$(ip -o -4 addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  gw=$(ip -4 route show default dev "$dev" 2>/dev/null | awk '{print $3; exit}')
  [ -n "$ip" ] || return 1
  if [ -n "${1:-}" ]; then cands=$1
  else
    is_priv "$ip" || { echo "gateway: public $ip via ${gw:-none} - nothing to fix"; return 0; }
    [ -n "$gw" ] && gw_ok "$gw" "$dev" && { echo "gateway: $gw answers - ok"; return 0; }
    cands="${ip%.*}.1 ${ip%.*}.254 ${ip%.*}.2"
  fi
  for c in $cands; do
    [ -z "${1:-}" ] && [ "$c" = "$gw" ] && continue
    gw_ok "$c" "$dev" || continue
    ip route replace default via "$c" dev "$dev" metric 0 || continue
    gw_persist "$dev" "$c"
    echo "gateway: declared ${gw:-none} dead on $dev ($ip) - default route now via $c (persisted)"
    return 0
  done
  echo "gateway: nothing answers on ${cands// /, } for $dev ($ip)"; return 1
}
# CloudStack tenant (domain; ROOT = admin) from the Salt inventory "who" file, keyed by sha256 of SMBIOS UUID or a MAC
yc_tenant(){
  local k w
  for k in $(tr 'A-Z' 'a-z' < /sys/class/dmi/id/product_uuid 2>/dev/null) $(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00$' | sort -u); do
    w=$(curl -fsS -m 10 "https://repo.oasisstack.io/salt/who/$(printf '%s' "$k" | sha256sum | cut -c1-64)" 2>/dev/null) || continue
    case "$w" in *tenant=*) printf '%s\n' "$w" | sed -n 's/^tenant=//p' | tr -d '\r '; return 0;; esac
  done
  return 1
}
# Salt master reachability with default tools only (getent, timeout, bash /dev/tcp). Prints the reason, rc 0 = both ports open
SALT_MASTER=salt.oasisstack.io
salt_ports(){
  local ip p bad=""
  ip=$(getent hosts "$SALT_MASTER" | awk '{print $1; exit}')
  [ -n "$ip" ] || { echo "DNS: $SALT_MASTER does not resolve"; return 1; }
  for p in 4505 4506; do timeout 5 bash -c "</dev/tcp/$ip/$p" 2>/dev/null || bad="$bad $p"; done
  [ -z "$bad" ] && { echo "$SALT_MASTER ($ip) 4505/4506 open"; return 0; }
  echo "$SALT_MASTER ($ip) port(s)${bad} blocked from $(ip -4 route get "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src")s=$(i+1);if($i=="via")g=$(i+1)}} END{print s" via "(g?g:"direct")}')"
  return 1
}
# database client as root (/root/.my.cnf)
db_cli(){ command -v mariadb || command -v mysql; }
sqlr(){ "$(db_cli)" --defaults-file=/root/.my.cnf -NB -e "$1"; }
db_svc(){ local s; for s in mariadb mysqld mysql; do systemctl cat "$s.service" >/dev/null 2>&1 && { echo "$s"; return; }; done; }
cnf_dir(){ local d; for d in /etc/mysql/mariadb.conf.d /etc/mysql/mysql.conf.d /etc/my.cnf.d; do [ -d "$d" ] && { echo "$d"; return; }; done; }
# memory/CPU based tuning -> 90-yallacloud-tuning.cnf (installer + 'yallacloud retune')
db_tune(){
  local ram cpu bp redo maxc tmp f
  ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo); cpu=$(nproc)
  if   [ "$ram" -lt 2048 ]; then bp=$((ram*40/100)); maxc=100
  elif [ "$ram" -lt 8192 ]; then bp=$((ram*60/100)); maxc=200
  else bp=$((ram*70/100)); maxc=500; fi
  bp=$(( bp/128*128 )); [ "$bp" -lt 128 ] && bp=128
  redo=$(( bp/4 )); [ "$redo" -lt 256 ] && redo=256; [ "$redo" -gt 4096 ] && redo=4096
  tmp=$(( ram/64 )); [ "$tmp" -lt 32 ] && tmp=32; [ "$tmp" -gt 256 ] && tmp=256
  f="$(cnf_dir)/90-yallacloud-tuning.cnf"
  {
    echo "# YallaCloud DB tuning (STACK4-62) - RAM ${ram}MB, ${cpu} vCPU, written $(date '+%F %T'). Re-calc: yallacloud retune"
    echo "[mysqld]"
    echo "innodb_buffer_pool_size = ${bp}M"
    if [ "$ENGINE" = mysql ]; then echo "innodb_redo_log_capacity = ${redo}M"; else echo "innodb_log_file_size = ${redo}M"; fi
    echo "innodb_io_capacity = 1000"
    echo "innodb_io_capacity_max = 2000"
    echo "innodb_flush_log_at_trx_commit = 1"
    echo "max_connections = $maxc"
    echo "tmp_table_size = ${tmp}M"
    echo "max_heap_table_size = ${tmp}M"
    echo "table_open_cache = 4000"
    echo "table_definition_cache = 2000"
    echo "open_files_limit = 65535"
  } > "$f"
  chmod 644 "$f"
  echo "tuning: buffer_pool=${bp}M redo=${redo}M max_connections=$maxc tmp_table=${tmp}M (RAM ${ram}MB, ${cpu} vCPU)"
}
# firewall: one DB rule per CIDR (0.0.0.0/0 = any)
fw_db(){   # add|del CIDR
  local op=$1 c=$2
  if command -v ufw >/dev/null; then
    local d=""; [ "$op" = del ] && d=delete
    if [ "$c" = 0.0.0.0/0 ]; then ufw $d allow "$DB_PORT/tcp" >/dev/null; else ufw $d allow from "$c" to any port "$DB_PORT" proto tcp >/dev/null; fi
  else
    local o=--add; [ "$op" = del ] && o=--remove
    if [ "$c" = 0.0.0.0/0 ]; then firewall-cmd -q --permanent $o-port="$DB_PORT/tcp"
    else firewall-cmd -q --permanent $o-rich-rule="rule family=\"ipv4\" source address=\"$c\" port port=\"$DB_PORT\" protocol=\"tcp\" accept"; fi
    firewall-cmd -q --reload
  fi
}
# notifications: separate, best effort, never block or fail the work
yc_ntfy(){   # title priority tags message - NO secrets here
  [ -n "${NTFY_URL:-}" ] || return 0
  timeout 20 curl -fsS -o /dev/null -H "Title: $1" -H "Priority: $2" -H "Tags: $3" --data-binary "$4" "$NTFY_URL" 2>/dev/null || echo "ntfy: post failed (ignored)"
}
yc_erp(){    # json-file - ERP webhook (credentials allowed), secret via header file, never argv
  [ -n "${ERP_WEBHOOK_URL:-}" ] && [ -n "${ERP_WEBHOOK_SECRET:-}" ] || { echo "erp webhook: ERP_WEBHOOK_SECRET blank - skipped"; return 0; }
  local h; h=$(mktemp); chmod 600 "$h"; printf 'X-Webhook-Secret: %s\nContent-Type: application/json\n' "$ERP_WEBHOOK_SECRET" > "$h"
  echo "erp webhook: HTTP $(timeout 30 curl -sS -o /dev/null -w '%{http_code}' -H @"$h" --data-binary @"$1" "$ERP_WEBHOOK_URL" 2>/dev/null || echo fail)"
  rm -f "$h"
}
LIBEOF
chmod 644 "$LIB"
. "$LIB"

# ================= 0. check every input: required -> stop with the reason; optional -> warn + default
step "0 inputs"
low(){ printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '[:space:]'; }
ENGINE=$(low "$ENGINE")
case "$ENGINE" in mariadb|mysql) ;; *) die "ENGINE='$ENGINE' - must be mariadb or mysql";; esac
DB_VERSION=$(low "$DB_VERSION")
if [ "$ENGINE" = mariadb ]; then
  case "$DB_VERSION" in 10.11|11.4|11.8|12.3) ;; "") DB_VERSION=11.8;; *) warn "DB_VERSION '$DB_VERSION' not a MariaDB LTS (10.11 11.4 11.8 12.3) - using 11.8"; DB_VERSION=11.8;; esac
else
  case "$DB_VERSION" in 8.4|9.7) ;; "") DB_VERSION=8.4;; *) warn "DB_VERSION '$DB_VERSION' not a MySQL LTS (8.4 9.7) - using 8.4"; DB_VERSION=8.4;; esac
fi
{ [[ "$DB_PORT" =~ ^[0-9]{2,5}$ ]] && [ "$DB_PORT" -ge 1024 ] && [ "$DB_PORT" -le 65535 ] && [ "$DB_PORT" != 33060 ]; } || { warn "DB_PORT '$DB_PORT' invalid - using 3306"; DB_PORT=3306; }
ALLOW=""
for c in $(printf '%s' "$DB_ALLOW" | tr ',;' '  '); do
  [ "$c" = any ] && c=0.0.0.0/0
  ip4 "$c" && c="$c/32"
  cidr_ok "$c" && ALLOW="$ALLOW $c" || warn "DB_ALLOW entry '$c' is not an IP or CIDR - ignored"
done
DB_ALLOW=$(echo $ALLOW)
uname_ok(){ [[ "$1" =~ ^[a-z_][a-z0-9_]{0,31}$ ]] && [[ ! " root mysql mariadb.sys mysql.sys mysql.session mysql.infoschema yc_backup " == *" $1 "* ]]; }
DB_ADMIN_USER=$(low "$DB_ADMIN_USER"); uname_ok "$DB_ADMIN_USER" || { warn "DB_ADMIN_USER '$DB_ADMIN_USER' invalid or reserved - using dbadmin"; DB_ADMIN_USER=dbadmin; }
DB_NAME=$(low "$DB_NAME"); DB_USER=$(low "$DB_USER")
[ -z "$DB_NAME" ] || { [[ "$DB_NAME" =~ ^[a-z0-9_]{1,64}$ ]] && [[ ! " mysql sys information_schema performance_schema test " == *" $DB_NAME "* ]]; } || { warn "DB_NAME '$DB_NAME' invalid or reserved - no database created"; DB_NAME=""; }
if [ -n "$DB_USER" ]; then
  [ -n "$DB_NAME" ] || { warn "DB_USER '$DB_USER' given without DB_NAME - no user created"; DB_USER=""; }
  [ -z "$DB_USER" ] || uname_ok "$DB_USER" || { warn "DB_USER '$DB_USER' invalid - using $DB_NAME"; DB_USER=${DB_NAME:0:32}; }
  [ "$DB_USER" = "$DB_ADMIN_USER" ] && { warn "DB_USER equals DB_ADMIN_USER - no extra user"; DB_USER=""; }
fi
pw_safe(){ [[ "$1" =~ ^[A-Za-z0-9#]{8,64}$ ]]; }   # house rule: '#' is the only special character
for v in DB_ROOT_PASS DB_ADMIN_PASS DB_USER_PASS; do
  [ -z "${!v}" ] || pw_safe "${!v}" || die "$v: 8-64 chars of A-Z a-z 0-9 and # only (# is the only special character allowed)"
done
DATA_DISK=$(low "$DATA_DISK"); case "$DATA_DISK" in auto|none|/dev/*) ;; "") DATA_DISK=auto;; *) warn "DATA_DISK '$DATA_DISK' invalid - auto"; DATA_DISK=auto;; esac
num_in(){ [[ "$1" =~ ^[0-9]{1,3}$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
num_in "$BACKUP_KEEP_DAYS" 1 365 || { warn "BACKUP_KEEP_DAYS '$BACKUP_KEEP_DAYS' invalid - 15"; BACKUP_KEEP_DAYS=15; }
num_in "$BACKUP_KEEP_WEEKS" 0 104 || { warn "BACKUP_KEEP_WEEKS '$BACKUP_KEEP_WEEKS' invalid - 4"; BACKUP_KEEP_WEEKS=4; }
num_in "$BACKUP_KEEP_MONTHS" 0 120 || { warn "BACKUP_KEEP_MONTHS '$BACKUP_KEEP_MONTHS' invalid - 12"; BACKUP_KEEP_MONTHS=12; }
[[ "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { warn "BACKUP_TIME '$BACKUP_TIME' invalid - 01:30"; BACKUP_TIME=01:30; }
BINLOG=$(low "$BINLOG"); case "$BINLOG" in yes|no) ;; *) warn "BINLOG '$BINLOG' invalid - yes"; BINLOG=yes;; esac
num_in "$BINLOG_DAYS" 1 90 || { warn "BINLOG_DAYS '$BINLOG_DAYS' invalid - 7"; BINLOG_DAYS=7; }
[ -z "$PUBLIC_IP" ] || { ip4 "$PUBLIC_IP" && ! is_priv "$PUBLIC_IP"; } || { warn "PUBLIC_IP '$PUBLIC_IP' invalid - auto"; PUBLIC_IP=""; }
[ -z "$GATEWAY" ] || ip4 "$GATEWAY" || { warn "GATEWAY '$GATEWAY' invalid - auto"; GATEWAY=""; }
if [ -n "$SSH_PORT" ]; then
  { [[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] && [ "$SSH_PORT" != "$DB_PORT" ]; } || { warn "SSH_PORT '$SSH_PORT' invalid - auto"; SSH_PORT=""; }
fi
[ -f "/usr/share/zoneinfo/$TZ_SET" ] || { warn "TZ_SET '$TZ_SET' unknown - Asia/Dubai"; TZ_SET=Asia/Dubai; }
[[ "$LOCALE_SET" =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]] || { warn "LOCALE_SET '$LOCALE_SET' invalid - en_US.UTF-8"; LOCALE_SET=en_US.UTF-8; }
SALT_JOIN=$(low "$SALT_JOIN"); case "$SALT_JOIN" in yes|no) ;; *) warn "SALT_JOIN '$SALT_JOIN' invalid - yes"; SALT_JOIN=yes;; esac
ACRONIS_TOKEN=$(printf '%s' "$ACRONIS_TOKEN" | tr -d '[:space:]')
ACRONIS_REGION=$(printf '%s' "$ACRONIS_REGION" | tr 'a-z' 'A-Z' | tr -d '[:space:]'); case "$ACRONIS_REGION" in AE|SG) ;; *) warn "ACRONIS_REGION '$ACRONIS_REGION' invalid - AE"; ACRONIS_REGION=AE;; esac
CLOUDSTACK_URL=${CLOUDSTACK_URL%/}
for v in NTFY_URL ERP_WEBHOOK_URL CLOUDSTACK_URL; do [ -z "${!v}" ] || [[ "${!v}" =~ ^https?://[^[:space:]]+$ ]] || { warn "$v invalid - disabled"; printf -v "$v" '%s' ""; }; done
[[ "$PASS_URL" =~ ^https?:// ]] || PASS_URL="https://pass.oasisstack.io/?len=16"
[[ "$REPO_URL" =~ ^https?:// ]] || REPO_URL="https://repo.oasisstack.io/db"
[ -n "$APT_MIRRORS" ] || APT_MIRRORS="ae.archive.ubuntu.com archive.ubuntu.com"
case "$DISABLE_CLOUD_INIT" in yes|no) ;; *) DISABLE_CLOUD_INIT=yes;; esac

. /etc/os-release
OSV=${VERSION_ID%%.*}
case "$ID" in
  ubuntu) [ "$VERSION_ID" = 24.04 ] || die "Ubuntu 24.04 only (found $PRETTY_NAME)"; OSF=ubuntu ;;
  rhel|rocky|almalinux|ol|centos) [[ "$OSV" =~ ^(9|10)$ ]] || die "EL 9 or 10 only (found $PRETTY_NAME)"; OSF=el ;;
  *) die "unsupported OS $PRETTY_NAME (Ubuntu 24.04, RHEL/Rocky/Alma/Oracle 9-10)" ;;
esac
say "config: ENGINE=$ENGINE $DB_VERSION PORT=$DB_PORT ALLOW=${DB_ALLOW:-auto} ADMIN=$DB_ADMIN_USER DB=${DB_NAME:--}/${DB_USER:--} DATA_DISK=$DATA_DISK BACKUP=${BACKUP_KEEP_DAYS}d/${BACKUP_KEEP_WEEKS}w/${BACKUP_KEEP_MONTHS}m@$BACKUP_TIME BINLOG=$BINLOG/${BINLOG_DAYS}d SALT=$SALT_JOIN ACRONIS=$([ -n "$ACRONIS_TOKEN" ] && echo "on/$ACRONIS_REGION" || echo off) ERP=$([ -n "$ERP_WEBHOOK_SECRET" ] && echo on || echo off) OS=$PRETTY_NAME"

# facts for notifications
VM_NAME=$(md local-hostname); VM_NAME=${VM_NAME:-$(hostname -s)}
SMBIOS=$(tr 'A-Z' 'a-z' < /sys/class/dmi/id/product_uuid 2>/dev/null)
ZONE=$(md availability-zone)
VM_UUID=$(md vm-id); VM_UUID=${VM_UUID:-$(md instance-id)}; VM_UUID=$(printf '%s' "${VM_UUID:-$SMBIOS}" | tr 'A-Z' 'a-z')
OFFERING=$(md service-offering)
INSTANCE_ID=$(md instance-id)
CLOUD_ID=$(md cloud-identifier)
TENANT=""; TENANT_SRC=""
PREV_RESULT=$(awk -F= '/^RESULT=/{print $2}' "$STATUS" 2>/dev/null)
facts_json(){   # $1 type  $2 summary  $3 with-secrets(yes|no) -> stdout
  T="$1" S="$2" W="$3" python3 - <<'PY'
import json, os, time
e = os.environ.get
d = {"type": e("T"), "extra": e("S"), "vmId": e("SMBIOS") or None, "smbiosUuid": e("SMBIOS") or None,
     "vmName": e("VM_NAME"), "vmUuid": e("VM_UUID") or None,
     "vmIdMismatch": bool(e("VM_UUID") and e("SMBIOS") and e("VM_UUID") != e("SMBIOS")),
     "tenant": e("TENANT") or None, "tenantSource": e("TENANT_SRC") or None, "serviceOffering": e("OFFERING") or None,
     "hostname": e("VM_NAME"), "ip": e("HOST_PRIV") or e("PUB_NIC") or None, "publicIp": e("HOST_PUB") or None,
     "zone": e("ZONE") or None, "cloud": e("CLOUD_ID") or "YallaCloud", "cloudIdentifier": e("CLOUD_ID") or None,
     "cloudPortal": e("CLOUDSTACK_URL") or None,
     "cloudVmUrl": (e("CLOUDSTACK_URL") + "/#/vm/" + e("VM_UUID")) if e("CLOUDSTACK_URL") and e("VM_UUID") else None, "os": e("PRETTY_NAME"), "osVersion": e("VERSION_ID"),
     "catalogue": e("ENGINE") + "-" + e("DB_VERSION"), "area": "db", "status": e("RESULT"), "steps": e("STEP"),
     "warnings": int(e("WARNS") or 0), "installer": "yc-db-install " + e("VER"),
     "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
if e("W") == "yes":
    d["db"] = {k: (e(v) or None) for k, v in {
        "engine": "ENGINE", "version": "DB_REAL_VERSION", "port": "DB_PORT", "hostPrivate": "HOST_PRIV",
        "hostPublic": "HOST_PUB", "allow": "DB_ALLOW", "rootUser": "ROOTU", "rootPassword": "DB_ROOT_PASS",
        "adminUser": "DB_ADMIN_USER", "adminPassword": "DB_ADMIN_PASS", "database": "DB_NAME",
        "user": "DB_USER", "userPassword": "DB_USER_PASS", "uriAdmin": "URI_ADMIN", "uriUser": "URI_USER",
        "dataDir": "DATADIR", "backupDir": "BACKUP_DIR", "backupRetention": "RETENTION",
        "sshPort": "SSH_PORT"}.items()}
# same keys as the Odoo kit / payload events (one ERP contract) - additive only
d.update({"offering": e("OFFERING") or None, "identitySource": "smbios" if e("SMBIOS") else "metadata",
          "instanceId": e("INSTANCE_ID") or None, "routerVmId": "", "cloudstackUrl": e("CLOUDSTACK_URL") or None,
          "lastUpdated": time.strftime("%Y-%m-%d %H:%M:%S %z ") + (e("TZ_SET") or "UTC").split("/")[-1], "payload": e("VER"), "freeGb": float(e("FREE_GB") or 0),
          "delivery": {"queued": 0}})
st = {"vm.deploy.started": "started", "vm.deploy.completed": "completed"}.get(e("T"), "failed")
f = {"area": "db", "status": st, "summary": e("S"), "engine": e("ENGINE"), "dbVersion": e("DB_REAL_VERSION") or e("DB_VERSION"),
     "dbHost": e("HOST_PUB") or e("HOST_PRIV") or None, "dbPort": e("DB_PORT"), "sshPort": e("SSH_PORT") or None,
     "warnings": e("WARN_TXT") or "", "installer": e("VER"), "salt": e("SALT_STATE") or None, "acronis": e("ACRONIS_STATE") or None}
if e("W") == "yes":
    f.update({"dbRootUser": "root", "dbRootPassword": e("DB_ROOT_PASS") or None, "dbAdminUser": e("DB_ADMIN_USER"),
              "dbAdminPassword": e("DB_ADMIN_PASS") or None, "dbName": e("DB_NAME") or None,
              "dbUser": e("DB_USER") or e("DB_ADMIN_USER"), "dbPassword": (e("DB_USER_PASS") if e("DB_USER") else e("DB_ADMIN_PASS")) or None,
              "backupDir": e("BACKUP_DIR") or None, "backupRetention": e("RETENTION") or None})
d["fields"] = f
print(json.dumps(d))
PY
}
export ENGINE DB_VERSION DB_PORT DB_ALLOW DB_ADMIN_USER DB_NAME DB_USER TZ_SET VM_NAME VM_UUID INSTANCE_ID OFFERING TENANT TENANT_SRC CLOUD_ID CLOUDSTACK_URL SMBIOS ZONE PRETTY_NAME VERSION_ID VER STEP WARNS
RESULT=RUNNING
finish(){
  local rc=$? title prio tags msg typ j
  trap - EXIT INT TERM
  [ -n "${CANCELLED:-}" ] && rc=130
  if [ "$rc" = 0 ]; then RESULT=SUCCESS; elif [ "$rc" = 130 ]; then RESULT=CANCELLED; else RESULT=FAILED; fi
  FREE_GB=$(df -BM --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc 0-9 | awk '{printf "%.1f", $1/1024}')
  export RESULT STEP WARNS WARN_TXT SALT_STATE ACRONIS_STATE FREE_GB HOST_PRIV HOST_PUB PUB_NIC DB_REAL_VERSION ROOTU DB_ROOT_PASS DB_ADMIN_PASS DB_USER_PASS URI_ADMIN URI_USER DATADIR BACKUP_DIR RETENTION SSH_PORT
  {
    echo "RESULT=$RESULT"; echo "TIME=$(date '+%F %T %Z')"; echo "INSTALLER=yc-db-install $VER"
    echo "ENGINE=$ENGINE ${DB_REAL_VERSION:-$DB_VERSION}"; echo "STEP=$STEP"; echo "WARNINGS=$WARNS${WARN_TXT:+ ($WARN_TXT)}"
    [ "$RESULT" = SUCCESS ] || echo "REASON=${FAIL_REASON:-exit $rc in step $STEP}"
  } > "$STATUS"
  say "RESULT $RESULT (step $STEP, warnings $WARNS) - status $STATUS"
  # one log for everything: append cloud-init's own logs
  { echo; echo "========== merged: cloud-init status =========="; cloud-init status --long 2>/dev/null
    for f in /var/log/cloud-init.log /var/log/cloud-init-output.log; do
      [ -f "$f" ] && { echo "========== merged: $f (last 400 lines) =========="; tail -n 400 "$f"; }; done
  } >> "$LOG" 2>/dev/null
  msg="vm      : $VM_NAME  tenant ${TENANT:--}  uuid ${VM_UUID:--}
ip      : ${HOST_PRIV:--} / public ${HOST_PUB:--}
engine  : $ENGINE ${DB_REAL_VERSION:-$DB_VERSION} port $DB_PORT
allow   : ${DB_ALLOW:-?}
step    : $STEP   warnings: $WARNS
detail  : ${FAIL_REASON:-${WARN_TXT:-none}}
salt    : ${SALT_STATE:-not run}   acronis: ${ACRONIS_STATE:-not run}
log     : $LOG"
  case "$RESULT" in
    SUCCESS)
      typ=vm.deploy.completed
      if [ "$PREV_RESULT" = FAILED ]; then title="BACK TO GREEN $ENGINE $VM_NAME"; prio=3; tags="green_circle,db"
      elif [ "${WAIT_HUMAN:-}" ]; then title="WAIT FOR HUMAN $ENGINE $VM_NAME"; prio=4; tags="raising_hand,db"; msg="$msg
human   : $WAIT_HUMAN"
      elif [ "$WARNS" -gt 0 ]; then title="OK WITH WARNINGS $ENGINE $VM_NAME"; prio=3; tags="warning,db"
      else title="READY $ENGINE $VM_NAME"; prio=3; tags="white_check_mark,db"; fi ;;
    CANCELLED) typ=vm.deploy.failed; title="CANCELLED $ENGINE $VM_NAME"; prio=4; tags="stop_sign,db" ;;
    *) typ=vm.deploy.failed; title="FAILED $ENGINE $VM_NAME"; prio=4; tags="x,db" ;;
  esac
  yc_ntfy "$title" "$prio" "$tags" "$msg"
  j=$(mktemp); chmod 600 "$j"
  facts_json "$typ" "$title | step $STEP | warnings $WARNS${FAIL_REASON:+ | $FAIL_REASON}" "$([ "$RESULT" = SUCCESS ] && echo yes || echo no)" > "$j" && yc_erp "$j"
  [ "$RESULT" = SUCCESS ] && install -m 600 "$j" "$INFO/handover.json"   # = the exact body the ERP received
  rm -f "$j"
  exit "$rc"
}
trap finish EXIT
trap 'CANCELLED=1; exit 130' INT TERM

# ================= 1. network
step "1 network"
for _ in $(seq 1 30); do ip -o -4 addr show scope global | grep -q . && break; sleep 2; done
say "$(fix_gateway "$GATEWAY")" || warn "gateway check found no answering gateway"
ip -4 route show default | grep -q . || die "no default route - set GATEWAY= to the firewall LAN IP"
detect_ips
[ -n "$PRIV_NIC$PUB_NIC" ] || die "no IPv4 address on any NIC"
[ -z "$SSH_PORT" ] && { [ -n "$PUB_NIC" ] && SSH_PORT=3222 || SSH_PORT=22; }
if [ -z "$DB_ALLOW" ]; then
  if [ -n "$PUB_NIC$PUBLIC_IP" ] || [ -z "$PRIV_CIDR" ]; then DB_ALLOW=0.0.0.0/0; warn "DB_ALLOW blank on a public VM - port $DB_PORT open to any IP (restrict: yallacloud deny 0.0.0.0/0; yallacloud allow <cidr>)"
  else DB_ALLOW=$PRIV_CIDR; fi
fi
export HOST_PRIV HOST_PUB PUB_NIC
TENANT=$(yc_tenant) && TENANT_SRC="salt-inventory (CloudStack domain)" || { TENANT=""; say "tenant: not published yet (Salt inventory syncs every 5 min) - webhook sends null"; }
say "vm: $VM_NAME uuid ${VM_UUID:-?} smbios ${SMBIOS:-?} tenant ${TENANT:-?} offering ${OFFERING:-?}"
say "ips: private=${HOST_PRIV:-none} public=${HOST_PUB:-none} (nic ${PUB_NIC:-none}, static-nat ${MD_PUB:-none}) subnet=${PRIV_CIDR:-none} allow=$DB_ALLOW ssh=$SSH_PORT"
yc_ntfy "RUN $ENGINE $VM_NAME" 2 "hourglass,db" "vm      : $VM_NAME  tenant ${TENANT:--}  uuid ${VM_UUID:--}
ip      : ${HOST_PRIV:--} / public ${HOST_PUB:--}
engine  : $ENGINE $DB_VERSION port $DB_PORT
os      : $PRETTY_NAME
installer: yc-db-install $VER"
j=$(mktemp); chmod 600 "$j"; facts_json vm.deploy.started "deploy started $ENGINE $DB_VERSION" no > "$j" && yc_erp "$j"; rm -f "$j"

# ================= 2. base OS: time, locale, repos, updates, kernel
step "2 os"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
timedatectl set-timezone "$TZ_SET" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TZ_SET" /etc/localtime
if [ "$OSF" = ubuntu ]; then
  MIRROR=""
  for m in $APT_MIRRORS; do
    curl -fsI --max-time 10 "http://$m/ubuntu/dists/noble/InRelease" >/dev/null 2>&1 && { MIRROR=$m; break; }
    say "apt mirror $m not answering"
  done
  [ -n "$MIRROR" ] || die "no apt mirror answered: $APT_MIRRORS"
  for F in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
    [ -f "$F" ] && sed -i -E "s#https?://([a-z0-9.-]*\.)?archive\.ubuntu\.com/ubuntu#http://${MIRROR}/ubuntu#g" "$F"
  done
  printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::ForceIPv4 "true";\nDPkg::Lock::Timeout "900";\n' > /etc/apt/apt.conf.d/99yallacloud
  mkdir -p /etc/needrestart/conf.d; echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/99-yallacloud.conf
  say "apt mirror = $MIRROR"
  apt-get update -q || die "apt update failed"
  apt-get -y -q -o Dpkg::Options::=--force-confold upgrade || warn "apt upgrade had errors"
  apt-get -y -q install curl ca-certificates gnupg ufw chrony locales xfsprogs cron gzip fail2ban openssh-server || die "base packages failed"
  locale-gen "$LOCALE_SET" >/dev/null && update-locale LANG="$LOCALE_SET"
  printf 'server time.oasisstack.io iburst prefer\npool ntp.ubuntu.com iburst maxsources 4\n' > /etc/chrony/sources.d/yallacloud.sources
  CHRONY=chrony
else
  if [ "$ID" = rhel ] && ! dnf -q repolist 2>/dev/null | grep -q .; then die "RHEL has no enabled repos - register it (subscription-manager) and re-run yc-db-install"; fi
  grep -q '^fastestmirror' /etc/dnf/dnf.conf || printf 'fastestmirror=True\nmax_parallel_downloads=10\nretries=5\ntimeout=60\n' >> /etc/dnf/dnf.conf
  dnf -y -q upgrade || warn "dnf upgrade had errors"
  dnf -y -q install ca-certificates chrony cronie xfsprogs gzip tar iputils openssh-server policycoreutils-python-utils firewalld "glibc-langpack-${LOCALE_SET%%_*}" python3 || die "base packages failed"
  dnf -y -q install epel-release 2>/dev/null || dnf -y -q install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$OSV.noarch.rpm" 2>/dev/null || true
  dnf -y -q install fail2ban 2>/dev/null || warn "fail2ban not available (EPEL) - skipped"
  localectl set-locale LANG="$LOCALE_SET" 2>/dev/null || echo "LANG=$LOCALE_SET" > /etc/locale.conf
  grep -q 'time.oasisstack.io' /etc/chrony.conf || sed -i '1i server time.oasisstack.io iburst prefer' /etc/chrony.conf
  systemctl enable --now crond >/dev/null 2>&1
  CHRONY=chronyd
fi
systemctl enable "$CHRONY" >/dev/null 2>&1; systemctl restart "$CHRONY"; timedatectl set-ntp true 2>/dev/null; chronyc -a makestep >/dev/null 2>&1 || true
# swap: guards mysqld against the OOM killer on a spike (swappiness 1 keeps it out of normal use)
if ! swapon --show | grep -q .; then
  { fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; } && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab || warn "swap file not created"
fi
cat > /etc/sysctl.d/90-yallacloud-db.conf <<'EOF'
# YallaCloud DB kernel settings (STACK4-62)
vm.swappiness = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
fs.file-max = 2097152
fs.aio-max-nr = 1048576
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF
sysctl -q --system 2>/dev/null || warn "some sysctl keys not applied"
cat > /etc/systemd/system/yc-thp-off.service <<'EOF'
[Unit]
Description=YallaCloud: transparent huge pages off (database latency)
Before=mariadb.service mysql.service mysqld.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for f in enabled defrag; do [ -w /sys/kernel/mm/transparent_hugepage/$f ] && echo never > /sys/kernel/mm/transparent_hugepage/$f; done; true'
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable --now yc-thp-off.service >/dev/null 2>&1

# ================= 3. SSH: root + password, no "login as ubuntu"
step "3 ssh"
SSHD=/etc/ssh/sshd_config.d/00-yallacloud.conf
printf 'Port %s\nPermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\nUsePAM yes\n' "$SSH_PORT" > "$SSHD"
rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
[ -f /root/.ssh/authorized_keys ] && sed -i -E 's/^.*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9-]+@openssh\.com) /\1 /' /root/.ssh/authorized_keys
SSH_PUBKEY=$(printf '%s' "$SSH_PUBKEY" | tr -d '\r\n')
if [ -n "$SSH_PUBKEY" ]; then
  kf=$(mktemp); printf '%s\n' "$SSH_PUBKEY" > "$kf"
  SSH_KEY_FP=$(ssh-keygen -lf "$kf" 2>/dev/null | awk '{print $2" "$NF}'); rm -f "$kf"
  [ -n "$SSH_KEY_FP" ] || { warn "SSH_PUBKEY is not a valid OpenSSH public key line - not installed"; SSH_PUBKEY=""; }
fi
if [ -n "$SSH_PUBKEY" ]; then
  install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
  grep -qF "$(echo "$SSH_PUBKEY" | awk '{print $2}')" /root/.ssh/authorized_keys || echo "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
  restorecon -R /root/.ssh 2>/dev/null; say "ssh key installed for root: $SSH_KEY_FP"
fi
printf 'disable_root: false\nssh_pwauth: true\n' > /etc/cloud/cloud.cfg.d/99-yallacloud.cfg 2>/dev/null || true
[ "$OSF" = el ] && [ "$SSH_PORT" != 22 ] && { semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || true; }
install -d -m 755 /run/sshd
ssh-keygen -A >/dev/null 2>&1   # fresh image without host keys
sshd -t || die "sshd config invalid"
systemctl daemon-reload
if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then systemctl stop ssh.service; systemctl restart ssh.socket
else systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service; fi
sleep 2; ss -ltn | grep -q ":$SSH_PORT " || warn "sshd not listening on $SSH_PORT"

# ================= 4. secrets (kept across re-runs)
step "4 secrets"
: "${DB_ROOT_PASS:=$(genpw)}"; : "${DB_ADMIN_PASS:=$(genpw)}"
[ -n "$DB_USER" ] && : "${DB_USER_PASS:=$(genpw)}"
for v in DB_ROOT_PASS DB_ADMIN_PASS; do [ -n "${!v}" ] || die "password generation failed (local and $PASS_URL)"; done
( umask 077; printf "DB_ROOT_PASS='%s'\nDB_ADMIN_PASS='%s'\nDB_USER_PASS='%s'\n" "$DB_ROOT_PASS" "$DB_ADMIN_PASS" "${DB_USER_PASS:-}" > "$INFO/secrets.env" )
( umask 077; printf '[client]\nuser=root\npassword="%s"\n' "$DB_ROOT_PASS" > /root/.my.cnf.yc-new )

# answers file without passwords (re-run, retune, yallacloud, backup read it)
( umask 077; for v in $KEYS; do case $v in *_PASS) continue;; esac; printf '%s=%q\n' "$v" "${!v}"; done > "$CFG" )
echo "SSH_PORT=$SSH_PORT" >> "$CFG"

# ================= 5. data disk: empty extra disk -> XFS /data, /data/mysql bind-mounted on /var/lib/mysql
step "5 storage"
root_disk=$(lsblk -nsro NAME,TYPE "$(findmnt -no SOURCE /)" 2>/dev/null | awk '$2=="disk"{print "/dev/"$1; exit}')
disk_empty(){ [ "$(lsblk -nro NAME "$1" | wc -l)" = 1 ] && [ -z "$(blkid -p -o value -s TYPE "$1" 2>/dev/null)$(blkid -p -o value -s PTTYPE "$1" 2>/dev/null)" ]; }
DEV=""
if findmnt -n /data >/dev/null; then say "storage: /data already mounted ($(findmnt -no SOURCE /data))"
elif [ "$DATA_DISK" = auto ]; then
  ycd=$(blkid -L ycdata 2>/dev/null)
  if [ -n "$ycd" ]; then DEV=$ycd
  else
    DEV=$(lsblk -dbnpro NAME,TYPE,RO,SIZE | awk -v r="$root_disk" '$2=="disk" && $3==0 && $1!=r && $4>=5368709120 {print $4, $1}' | sort -rn | while read -r _ d; do
            disk_empty "$d" && ! swapon --show=NAME --noheadings | grep -qx "$d" && { echo "$d"; break; }; done)
  fi
  [ -n "$DEV" ] || say "storage: no empty extra disk (>=5 GB) - data stays on the root disk"
elif [[ "$DATA_DISK" == /dev/* ]]; then
  [ -b "$DATA_DISK" ] || die "DATA_DISK $DATA_DISK is not a block device"
  [ "$DATA_DISK" = "$root_disk" ] && die "DATA_DISK $DATA_DISK is the root disk"
  DEV=$DATA_DISK
fi
if [ -n "$DEV" ]; then
  if [ "$(blkid -o value -s LABEL "$DEV" 2>/dev/null)" = ycdata ]; then say "storage: $DEV is a YallaCloud data disk - mounting, not formatting"
  elif disk_empty "$DEV"; then mkfs.xfs -q -L ycdata "$DEV" || die "mkfs.xfs $DEV failed"; say "storage: formatted $DEV as XFS (label ycdata)"
  else die "DATA_DISK $DEV has partitions or a filesystem - refusing to format (wipe it yourself or use DATA_DISK=none)"; fi
  mkdir -p /data
  uuid=$(blkid -o value -s UUID "$DEV")
  grep -q "$uuid" /etc/fstab || echo "UUID=$uuid /data xfs defaults,noatime,nofail 0 2" >> /etc/fstab
  systemctl daemon-reload; mount /data || die "mount /data failed"
fi
if findmnt -n /data >/dev/null; then
  mkdir -p /data/mysql /data/backup /var/lib/mysql
  if findmnt -n /var/lib/mysql >/dev/null; then :
  elif [ -n "$(ls -A /var/lib/mysql 2>/dev/null)" ]; then warn "/var/lib/mysql is not empty - left on the root disk (data not moved)"
  else
    grep -q ' /var/lib/mysql ' /etc/fstab || echo "/data/mysql /var/lib/mysql none bind,nofail,x-systemd.requires-mounts-for=/data 0 0" >> /etc/fstab
    systemctl daemon-reload; mount /var/lib/mysql || die "bind mount /data/mysql -> /var/lib/mysql failed"
  fi
  BACKUP_DIR=/data/backup
  [ "$OSF" = el ] && { semanage fcontext -a -e /var/lib/mysql /data/mysql 2>/dev/null; restorecon -R /data/mysql 2>/dev/null; }
else
  BACKUP_DIR=/var/backups/yc-db
fi
DATADIR=/var/lib/mysql
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
echo "BACKUP_DIR=$BACKUP_DIR" >> "$CFG"
say "storage: datadir $DATADIR on $(findmnt -no SOURCE --target /var/lib/mysql 2>/dev/null || findmnt -no SOURCE --target /var/lib) ($(df -h --output=avail /var/lib | tail -1 | tr -d ' ') free), backups $BACKUP_DIR"

# ================= 6. engine: vendor repo -> repo.oasisstack.io copy -> OS packages (fallback)
step "6 install $ENGINE $DB_VERSION"
get(){ curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"; }   # url out
FALLBACK=""
if [ "$ENGINE" = mariadb ]; then
  rs=/root/mariadb_repo_setup
  if get https://r.mariadb.com/downloads/mariadb_repo_setup $rs || get "$REPO_URL/mariadb_repo_setup" $rs; then
    bash $rs --mariadb-server-version="mariadb-$DB_VERSION" --skip-maxscale --skip-tools --skip-check-installed || { warn "mariadb_repo_setup failed"; FALLBACK=1; }
  else warn "mariadb_repo_setup download failed (r.mariadb.com and $REPO_URL)"; FALLBACK=1; fi
  if [ "$OSF" = ubuntu ]; then
    [ -z "$FALLBACK" ] && { apt-get update -q && apt-get -y -q install mariadb-server mariadb-client mariadb-backup; } || {
      warn "MariaDB $DB_VERSION repo install failed - using Ubuntu's MariaDB"; rm -f /etc/apt/sources.list.d/mariadb.*; apt-get update -q
      apt-get -y -q install mariadb-server mariadb-client mariadb-backup || die "MariaDB install failed"; FALLBACK=1; }
  else
    [ -z "$FALLBACK" ] && dnf -y -q install MariaDB-server MariaDB-client MariaDB-backup || {
      warn "MariaDB $DB_VERSION repo install failed - using the OS MariaDB"; rm -f /etc/yum.repos.d/mariadb.repo
      dnf -y -q install mariadb-server mariadb || die "MariaDB install failed"; FALLBACK=1; }
  fi
else
  key=/root/mysql-key.asc
  get https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 $key || get "$REPO_URL/RPM-GPG-KEY-mysql-2025" $key || { warn "MySQL GPG key download failed"; FALLBACK=1; }
  comp=mysql-$DB_VERSION-lts; [ "$DB_VERSION" = 8.4 ] && comp=mysql-8.4-lts
  if [ "$OSF" = ubuntu ]; then
    if [ -z "$FALLBACK" ]; then
      gpg --dearmor --yes -o /usr/share/keyrings/mysql.gpg $key
      echo "deb [signed-by=/usr/share/keyrings/mysql.gpg] http://repo.mysql.com/apt/ubuntu noble $comp mysql-tools" > /etc/apt/sources.list.d/mysql.list
      printf 'mysql-community-server mysql-community-server/root-pass password %s\nmysql-community-server mysql-community-server/re-root-pass password %s\n' "$DB_ROOT_PASS" "$DB_ROOT_PASS" | debconf-set-selections
    fi
    [ -z "$FALLBACK" ] && { apt-get update -q && apt-get -y -q install mysql-community-server mysql-community-client; } || {
      warn "MySQL $DB_VERSION repo install failed - using Ubuntu's MySQL"; rm -f /etc/apt/sources.list.d/mysql.list; apt-get update -q
      apt-get -y -q install mysql-server mysql-client || die "MySQL install failed"; FALLBACK=1; }
  else
    if [ -z "$FALLBACK" ]; then
      rpm --import $key
      printf '[mysql-community]\nname=MySQL %s Community Server\nbaseurl=https://repo.mysql.com/yum/mysql-%s-community/el/%s/$basearch/\nenabled=1\ngpgcheck=1\ngpgkey=file://%s\nmodule_hotfixes=1\n' "$DB_VERSION" "$DB_VERSION" "$OSV" "$key" > /etc/yum.repos.d/mysql-community.repo
      [ "$OSV" = 9 ] && dnf -y -q module disable mysql mariadb >/dev/null 2>&1
    fi
    [ -z "$FALLBACK" ] && dnf -y -q install mysql-community-server mysql-community-client || {
      warn "MySQL $DB_VERSION repo install failed - using the OS MySQL"; rm -f /etc/yum.repos.d/mysql-community.repo
      dnf -y -q install mysql-server mysql || die "MySQL install failed"; FALLBACK=1; }
  fi
fi
[ -n "$FALLBACK" ] && WAIT_HUMAN="vendor repo failed - OS package installed, check version"
SVC=$(db_svc); [ -n "$SVC" ] || die "no mariadb/mysql systemd unit after install"
CLI=$(db_cli)
say "installed: $($CLI --version) service=$SVC"

# ================= 7. configuration + tuning
step "7 configure"
CD=$(cnf_dir); [ -n "$CD" ] || { CD=/etc/my.cnf.d; mkdir -p $CD; }
if [ "$CD" = /etc/my.cnf.d ] && ! grep -qs '^!includedir /etc/my.cnf.d' /etc/my.cnf; then echo '!includedir /etc/my.cnf.d' >> /etc/my.cnf; fi
case "$OSF/$ENGINE" in
  ubuntu/*) LOG_ERR=/var/log/mysql/error.log; install -d -o mysql -g adm -m 2750 /var/log/mysql ;;
  el/mysql) LOG_ERR=/var/log/mysqld.log ;;
  el/mariadb) LOG_ERR=/var/log/mariadb/mariadb.log; install -d -o mysql -g mysql -m 750 /var/log/mariadb; restorecon -R /var/log/mariadb 2>/dev/null ;;
esac
touch "$LOG_ERR"; chown mysql: "$LOG_ERR"; [ "$OSF" = el ] && restorecon "$LOG_ERR" 2>/dev/null
o3=$(echo "${HOST_PRIV:-${PUB_NIC:-0.0.0.1}}" | cut -d. -f3); o4=$(echo "${HOST_PRIV:-${PUB_NIC:-0.0.0.1}}" | cut -d. -f4)
SERVER_ID=$(( o3*256 + o4 + 1 ))
{
  echo "# YallaCloud DB server settings (STACK4-62) - yc-db-install $VER. Tuning: 90-yallacloud-tuning.cnf"
  echo "[mysqld]"
  echo "port = $DB_PORT"
  echo "bind_address = 0.0.0.0"
  echo "skip_name_resolve = ON"
  echo "character_set_server = utf8mb4"
  echo "max_allowed_packet = 64M"
  echo "log_error = $LOG_ERR"
  echo "slow_query_log = ON"
  echo "long_query_time = 2"
  echo "server_id = $SERVER_ID"
  echo "sync_binlog = 1"
  if [ "$ENGINE" = mysql ]; then
    echo "log_error_verbosity = 3"
    echo "mysqlx_bind_address = 127.0.0.1"
    if [ "$BINLOG" = yes ]; then echo "binlog_expire_logs_seconds = $((BINLOG_DAYS*86400))"; else echo "disable_log_bin"; fi
  else
    echo "log_warnings = 2"
    [ "$BINLOG" = yes ] && { echo "log_bin = mysql-bin"; echo "binlog_format = ROW"; echo "binlog_expire_logs_seconds = $((BINLOG_DAYS*86400))"; }
  fi
} > "$CD/80-yallacloud.cnf"
say "$(db_tune)"
chmod 644 "$CD"/80-yallacloud.cnf "$CD"/90-yallacloud-tuning.cnf
mkdir -p "/etc/systemd/system/$SVC.service.d"
printf '[Unit]\nRequiresMountsFor=/var/lib/mysql\nAfter=yc-thp-off.service\n[Service]\nLimitNOFILE=65535\n' > "/etc/systemd/system/$SVC.service.d/yallacloud.conf"
if [ "$OSF" = el ]; then
  [ "$DB_PORT" != 3306 ] && { semanage port -a -t mysqld_port_t -p tcp "$DB_PORT" 2>/dev/null || semanage port -m -t mysqld_port_t -p tcp "$DB_PORT" 2>/dev/null || true; }
  restorecon -R /var/lib/mysql 2>/dev/null
fi
chown mysql:mysql /var/lib/mysql; chmod 750 /var/lib/mysql
systemctl daemon-reload; systemctl enable "$SVC" >/dev/null 2>&1
systemctl restart "$SVC" || { tail -n 30 "$LOG_ERR"; die "$SVC failed to start with the YallaCloud config - see $LOG_ERR"; }
for _ in $(seq 1 30); do "$CLI" --version >/dev/null && ss -ltn | grep -q ":$DB_PORT " && break; sleep 2; done
ss -ltn | grep -q ":$DB_PORT " || die "$SVC not listening on $DB_PORT"

# ================= 8. root password, clean-up, admin + app users
step "8 users"
ROOTU=root
if "$CLI" -uroot -NBe 'select 1' >/dev/null 2>&1; then rc_auth="socket"
elif "$CLI" --defaults-file=/root/.my.cnf.yc-new -NBe 'select 1' >/dev/null 2>&1; then rc_auth="password"
elif [ -f /root/.my.cnf ] && "$CLI" --defaults-file=/root/.my.cnf -NBe 'select 1' >/dev/null 2>&1; then rc_auth="old-cnf"
else
  tmp=$(grep -h 'temporary password' "$LOG_ERR" /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}')
  [ -n "$tmp" ] || die "cannot log in as root (no socket auth, no password, no temporary password in $LOG_ERR)"
  "$CLI" -uroot -p"$tmp" --connect-expired-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS'" || die "root temporary password change failed"
  rc_auth="temporary"
fi
case $rc_auth in socket) RC=(-uroot) ;; password) RC=(--defaults-file=/root/.my.cnf.yc-new) ;; old-cnf) RC=(--defaults-file=/root/.my.cnf) ;; temporary) RC=(--defaults-file=/root/.my.cnf.yc-new) ;; esac
q(){ "$CLI" "${RC[@]}" -NB -e "$1"; }
if [ "$ENGINE" = mariadb ]; then
  q "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$DB_ROOT_PASS')" || die "root password set failed"
else
  q "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '$DB_ROOT_PASS'" || die "root password set failed"
fi
mv -f /root/.my.cnf.yc-new /root/.my.cnf; chmod 600 /root/.my.cnf
sqlr 'select 1' >/dev/null || die "root login with /root/.my.cnf failed"
# like mysql_secure_installation: no anonymous users, no remote root, no test database
for u in $(sqlr "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user WHERE user='' OR (user='root' AND host NOT IN ('localhost','127.0.0.1','::1'))"); do sqlr "DROP USER $u" && say "dropped user $u"; done
sqlr "DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'; FLUSH PRIVILEGES" || warn "test database clean-up failed"
sqlr "CREATE USER IF NOT EXISTS '$DB_ADMIN_USER'@'%' IDENTIFIED BY '$DB_ADMIN_PASS'; ALTER USER '$DB_ADMIN_USER'@'%' IDENTIFIED BY '$DB_ADMIN_PASS'; GRANT ALL PRIVILEGES ON *.* TO '$DB_ADMIN_USER'@'%' WITH GRANT OPTION" || die "admin user $DB_ADMIN_USER failed"
if [ -n "$DB_NAME" ]; then
  sqlr "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4" || die "database $DB_NAME failed"
  [ -n "$DB_USER" ] && { sqlr "CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_USER_PASS'; ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$DB_USER_PASS'; GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%'" || die "user $DB_USER failed"; }
fi
DB_REAL_VERSION=$(sqlr 'SELECT VERSION()')
say "users ok: root (local), $DB_ADMIN_USER@% (admin)${DB_USER:+, $DB_USER@% on $DB_NAME} - server $DB_REAL_VERSION"

# ================= 9. firewall + fail2ban
step "9 firewall"
if [ "$OSF" = ubuntu ]; then
  ufw --force reset >/dev/null; ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  ufw allow "$SSH_PORT/tcp" >/dev/null
  for c in $DB_ALLOW; do fw_db add "$c"; done
  ufw --force enable >/dev/null || die "ufw enable failed"
else
  systemctl enable --now firewalld >/dev/null 2>&1 || die "firewalld failed to start"
  for s in cockpit dhcpv6-client ssh; do firewall-cmd -q --permanent --remove-service=$s 2>/dev/null; done
  firewall-cmd -q --permanent --add-port="$SSH_PORT/tcp"
  for c in $DB_ALLOW; do fw_db add "$c"; done
  firewall-cmd -q --reload
fi
if command -v fail2ban-client >/dev/null; then
  bk=""; [ "$OSF" = el ] && bk="backend = systemd"
  cat > /etc/fail2ban/jail.d/yallacloud.conf <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 6
bantime = 1h
$bk

[mysqld-auth]
enabled = true
port = $DB_PORT
logpath = $LOG_ERR
backend = auto
maxretry = 8
bantime = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban || warn "fail2ban failed to start"
fi
say "firewall: ssh $SSH_PORT any, $ENGINE $DB_PORT from: $DB_ALLOW"

# ================= 10. backups: daily dump per database, grants, retention, cron
step "10 backup"
cat > /usr/local/sbin/yc-db-backup <<'EOF'
#!/bin/bash
# yc-db-backup - logical backup of every database + users/grants (STACK4-62). Cron: /etc/cron.d/yc-db-backup
# Layout: $BACKUP_DIR/daily/YYYY-MM-DD/<db>.sql.gz + users.sql.gz, Sunday copy -> weekly/, 1st -> monthly/
set -uo pipefail; umask 077; export HOME=/root
. /etc/yallacloud/db.conf.env; . /usr/local/lib/yc-db-common.sh
ST=/var/lib/yallacloud/db-backup.status; prev=$(awk -F= '/^RESULT=/{print $2}' $ST 2>/dev/null)
day=$(date +%F); out="$BACKUP_DIR/daily/$day"; err=""
log(){ echo "[$(date '+%F %T')] $*"; }
mkdir -p "$out" "$BACKUP_DIR/weekly" "$BACKUP_DIR/monthly"; chmod 700 "$BACKUP_DIR"
DUMP=$(command -v mariadb-dump || command -v mysqldump)
size=$(sqlr "SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')")
free=$(( $(df -Pk "$BACKUP_DIR" | awk 'NR==2{print $4}') * 1024 ))
[ "${size:-0}" -lt "$free" ] || err="not enough space: databases ${size} bytes, free ${free} bytes in $BACKUP_DIR"
if [ -z "$err" ]; then
  for db in $(sqlr "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys')"); do
    if "$DUMP" --defaults-file=/root/.my.cnf --single-transaction --quick --routines --events --triggers --hex-blob --databases "$db" | gzip -c > "$out/$db.sql.gz.part" && gzip -t "$out/$db.sql.gz.part"; then
      mv -f "$out/$db.sql.gz.part" "$out/$db.sql.gz"; log "ok   $db $(du -h "$out/$db.sql.gz" | cut -f1)"
    else rm -f "$out/$db.sql.gz.part"; err="$err dump $db failed;"; log "FAIL $db"; fi
  done
  # users + grants (restore: gunzip -c users.sql.gz | mysql)
  { if [ "$ENGINE" = mariadb ]; then "$DUMP" --defaults-file=/root/.my.cnf --system=users
    else for u in $(sqlr "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user WHERE user NOT IN ('root','mysql.sys','mysql.session','mysql.infoschema')"); do
      echo "$(sqlr "SET SESSION print_identified_with_as_hex=ON; SHOW CREATE USER $u");"; sqlr "SHOW GRANTS FOR $u" | sed 's/$/;/'; done; fi; } | gzip -c > "$out/users.sql.gz" || err="$err users dump failed;"
fi
[ "$(date +%u)" = 7 ] && [ "${BACKUP_KEEP_WEEKS:-0}" -gt 0 ] && cp -al "$out" "$BACKUP_DIR/weekly/$day" 2>/dev/null
[ "$(date +%d)" = 01 ] && [ "${BACKUP_KEEP_MONTHS:-0}" -gt 0 ] && cp -al "$out" "$BACKUP_DIR/monthly/$day" 2>/dev/null
find "$BACKUP_DIR/daily"   -mindepth 1 -maxdepth 1 -type d -mtime +$(( BACKUP_KEEP_DAYS - 1 )) -exec rm -rf {} +
find "$BACKUP_DIR/weekly"  -mindepth 1 -maxdepth 1 -type d -mtime +$(( BACKUP_KEEP_WEEKS * 7 ))  -exec rm -rf {} +
find "$BACKUP_DIR/monthly" -mindepth 1 -maxdepth 1 -type d -mtime +$(( BACKUP_KEEP_MONTHS * 31 )) -exec rm -rf {} +
res=OK; [ -n "$err" ] && res=FAILED
printf 'RESULT=%s\nTIME=%s\nDIR=%s\nSIZE=%s\nDETAIL=%s\n' "$res" "$(date '+%F %T')" "$out" "$(du -sh "$out" | cut -f1)" "${err:-none}" > $ST
log "backup $res -> $out ${err}"
h=$(hostname -s)
[ "$res" = FAILED ] && yc_ntfy "BACKUP FAILED $ENGINE $h" 4 "x,db,floppy_disk" "$err"
[ "$res" = OK ] && [ "$prev" = FAILED ] && yc_ntfy "BACKUP BACK TO GREEN $ENGINE $h" 3 "green_circle,db" "backup ok again -> $out"
[ "$res" = OK ]
EOF
chmod 700 /usr/local/sbin/yc-db-backup
echo "${BACKUP_TIME#*:} $((10#${BACKUP_TIME%%:*})) * * * root /usr/local/sbin/yc-db-backup >> /var/log/yc-db-backup.log 2>&1" > /etc/cron.d/yc-db-backup
chmod 644 /etc/cron.d/yc-db-backup
printf '/var/log/yc-db-backup.log /var/log/yc-db-deploy.log {\n  monthly\n  rotate 6\n  compress\n  missingok\n  notifempty\n}\n' > /etc/logrotate.d/yallacloud-db
RETENTION="daily ${BACKUP_KEEP_DAYS}d, weekly ${BACKUP_KEEP_WEEKS}, monthly ${BACKUP_KEEP_MONTHS} at $BACKUP_TIME -> $BACKUP_DIR"
/usr/local/sbin/yc-db-backup >> /var/log/yc-db-backup.log 2>&1 && say "first backup ok ($RETENTION)" || warn "first backup failed - see /var/log/yc-db-backup.log"

# ================= 11. handover + yallacloud command
step "11 handover"
HOST_C=${HOST_PRIV:-$HOST_PUB}
URI_ADMIN="mysql://$DB_ADMIN_USER:$(urlpw "$DB_ADMIN_PASS")@${HOST_PUB:-$HOST_C}:$DB_PORT/"
URI_USER=""; [ -n "$DB_USER" ] && URI_USER="mysql://$DB_USER:$(urlpw "$DB_USER_PASS")@${HOST_PUB:-$HOST_C}:$DB_PORT/$DB_NAME"
jproto=mysql; [ "$ENGINE" = mariadb ] && jproto=mariadb
jx=""; [ "$ENGINE" = mysql ] && jx="?allowPublicKeyRetrieval=true"
export DB_REAL_VERSION ROOTU DB_ROOT_PASS DB_ADMIN_PASS DB_USER_PASS DATADIR BACKUP_DIR RETENTION SSH_PORT URI_ADMIN URI_USER
umask 077
{
cat <<EOF
==================== YallaCloud database server - handover ====================
created     : $(date '+%F %T %Z')   installer yc-db-install $VER
vm          : $VM_NAME   ($PRETTY_NAME)
tenant      : ${TENANT:--} (CloudStack domain)   vm uuid ${VM_UUID:--}   offering ${OFFERING:--}
portal      : ${CLOUDSTACK_URL:--}${CLOUDSTACK_URL:+/#/vm/$VM_UUID}
engine      : $ENGINE $DB_REAL_VERSION$([ -n "$FALLBACK" ] && echo "   (OS package fallback - vendor repo failed)")
host        : private ${HOST_PRIV:--}   public ${HOST_PUB:--}
port        : $DB_PORT   (allowed from: $DB_ALLOW)
ssl         : not configured (plain TCP inside the allowed networks)

-- accounts --------------------------------------------------------------------
root        : root / $DB_ROOT_PASS        (localhost only; on the server just type: $(basename "$CLI"))
admin       : $DB_ADMIN_USER / $DB_ADMIN_PASS        (remote, ALL PRIVILEGES WITH GRANT OPTION)
EOF
[ -n "$DB_NAME" ] && echo "database    : $DB_NAME"
[ -n "$DB_USER" ] && echo "app user    : $DB_USER / $DB_USER_PASS        (remote, ALL on $DB_NAME.*)"
cat <<EOF

-- connect ---------------------------------------------------------------------
cli         : mysql -h ${HOST_PUB:-$HOST_C} -P $DB_PORT -u $DB_ADMIN_USER -p'$DB_ADMIN_PASS'
uri admin   : $URI_ADMIN
EOF
[ -n "$URI_USER" ] && cat <<EOF
uri app     : $URI_USER
jdbc        : jdbc:$jproto://${HOST_PUB:-$HOST_C}:$DB_PORT/$DB_NAME$jx   user $DB_USER
php pdo     : new PDO('mysql:host=${HOST_PUB:-$HOST_C};port=$DB_PORT;dbname=$DB_NAME;charset=utf8mb4', '$DB_USER', '$DB_USER_PASS');
python      : pymysql.connect(host='${HOST_PUB:-$HOST_C}', port=$DB_PORT, user='$DB_USER', password='$DB_USER_PASS', database='$DB_NAME')
EOF
[ -n "$HOST_PRIV" ] && [ -n "$HOST_PUB" ] && echo "same network: use host $HOST_PRIV instead of $HOST_PUB"
cat <<EOF
note        : '#' in a password is written %23 inside a URI.$([ "$ENGINE" = mysql ] && echo " Old clients without TLS need allowPublicKeyRetrieval=true (caching_sha2_password).")

-- server ----------------------------------------------------------------------
ssh         : port $SSH_PORT, root + password (CloudStack password)${SSH_KEY_FP:+ + key $SSH_KEY_FP}
datadir     : $DATADIR on $(findmnt -no SOURCE --target $DATADIR)
backups     : $RETENTION   (yallacloud backup)
binlog      : $BINLOG $([ "$BINLOG" = yes ] && echo "(${BINLOG_DAYS} days)")
config      : $CD/80-yallacloud.cnf + 90-yallacloud-tuning.cnf
full picture: yallacloud      secrets: yallacloud secrets      log: $LOG
================================================================================
EOF
} > "$INFO/handover.txt"
facts_json vm.deploy.completed handover yes > "$INFO/handover.json" 2>/dev/null
umask 022
chmod 600 "$INFO/handover.txt" "$INFO/handover.json"
echo "yc-db-install $VER $(date '+%F %T %Z')" > /etc/yallacloud/db.version

cat > /usr/local/sbin/yallacloud <<'YCEOF'
#!/bin/bash
# yallacloud - the whole picture of this database server (STACK4-62)
#   yallacloud [info]       setup, tuning, databases, users, backups, cron, firewall, agents
#   yallacloud secrets      credentials + connection strings (root)
#   yallacloud backup       run a backup now          yallacloud backups   list backups
#   yallacloud restore FILE restore a <db>.sql.gz / users.sql.gz
#   yallacloud allow CIDR | deny CIDR    open/close the DB port for a network (0.0.0.0/0 = any)
#   yallacloud newdb NAME [USER]         database + user with a generated password
#   yallacloud retune       re-calculate memory tuning after a resize, restart the DB
#   yallacloud log          deployment log
. /etc/yallacloud/db.conf.env 2>/dev/null; . /usr/local/lib/yc-db-common.sh
export HOME=/root
kv(){ printf '  %-22s %s\n' "$1" "$2"; }
st(){ systemctl cat "$1" >/dev/null 2>&1 && systemctl is-active "$1" || echo "not installed"; }
hum(){ [[ "$1" =~ ^[0-9]{7,}$ ]] && echo "$(( $1 / 1048576 ))M" || echo "$1"; }
hd(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
need_root(){ [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }; }
svc=$(db_svc); cd_=$(cnf_dir)
case "${1:-info}" in
info)
  need_root; detect_ips
  hd "YallaCloud database server - $(hostname -s)"
  kv engine "$ENGINE $(sqlr 'SELECT VERSION()' 2>/dev/null || echo '(not answering)')"
  kv service "$svc $(systemctl is-active "$svc") since $(systemctl show -p ActiveEnterTimestamp --value "$svc")"
  kv installer "$(cat /etc/yallacloud/db.version 2>/dev/null)   result: $(awk -F= '/^RESULT=/{print $2}' /var/log/yc-db-deploy.status 2>/dev/null)"
  kv os "$(. /etc/os-release; echo "$PRETTY_NAME") kernel $(uname -r)$({ [ -f /var/run/reboot-required ] || { command -v needs-restarting >/dev/null && ! needs-restarting -r >/dev/null 2>&1; }; } && echo '  REBOOT PENDING')"
  kv cpu/ram "$(nproc) vCPU / $(free -h | awk '/Mem:/{print $2}') RAM, swap $(free -h | awk '/Swap:/{print $2}')"
  kv cloud-init "$([ -f /etc/cloud/cloud-init.disabled ] && echo 'disabled after install' || echo enabled)"
  hd "Network"
  kv private "${HOST_PRIV:--}"; kv public "${HOST_PUB:--}"; kv port "$DB_PORT"; kv ssh "port $SSH_PORT"
  kv allowed "$DB_ALLOW"
  kv firewall "$(command -v ufw >/dev/null && ufw status | head -1 || echo "firewalld $(firewall-cmd --state 2>/dev/null)")"
  command -v fail2ban-client >/dev/null && kv fail2ban "$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}')"
  hd "Storage"
  kv datadir "/var/lib/mysql on $(findmnt -no SOURCE --target /var/lib/mysql) - $(df -h --output=used,size,pcent /var/lib/mysql | tail -1)"
  kv backups "$BACKUP_DIR - $(df -h --output=avail "$BACKUP_DIR" | tail -1 | tr -d ' ') free"
  hd "Settings (live)"
  for v in innodb_buffer_pool_size max_connections innodb_redo_log_capacity innodb_log_file_size innodb_io_capacity tmp_table_size table_open_cache log_bin binlog_expire_logs_seconds slow_query_log long_query_time character_set_server skip_name_resolve log_error; do
    x=$(sqlr "SHOW GLOBAL VARIABLES LIKE '$v'" 2>/dev/null | cut -f2); [ -n "$x" ] && kv "$v" "$(hum "$x")"; done
  kv files "$cd_/80-yallacloud.cnf, $cd_/90-yallacloud-tuning.cnf"
  kv connections "$(sqlr "SHOW GLOBAL STATUS LIKE 'Threads_connected'" | cut -f2) now, max used $(sqlr "SHOW GLOBAL STATUS LIKE 'Max_used_connections'" | cut -f2)"
  kv slow-queries "$(sqlr "SHOW GLOBAL STATUS LIKE 'Slow_queries'" | cut -f2) since start ($(sqlr 'SELECT @@slow_query_log_file'))"
  hd "Databases"
  sqlr "SELECT s.schema_name, CONCAT(ROUND(COALESCE(SUM(t.data_length+t.index_length),0)/1048576,1),' MB') FROM information_schema.schemata s LEFT JOIN information_schema.tables t ON t.table_schema=s.schema_name WHERE s.schema_name NOT IN ('mysql','information_schema','performance_schema','sys') GROUP BY s.schema_name" | while read -r a b; do kv "$a" "$b"; done
  hd "Users"
  sqlr "SELECT user, host FROM mysql.user WHERE user NOT IN ('mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','') ORDER BY user" | while read -r a b; do kv "$a" "@$b"; done
  hd "Backups"
  kv schedule "$(grep -v '^#' /etc/cron.d/yc-db-backup | awk '{printf "%02d:%02d daily", $2, $1}') (/etc/cron.d/yc-db-backup)"
  kv retention "daily ${BACKUP_KEEP_DAYS}d, weekly ${BACKUP_KEEP_WEEKS}, monthly ${BACKUP_KEEP_MONTHS}"
  kv last "$(tr '\n' ' ' < /var/lib/yallacloud/db-backup.status 2>/dev/null || echo none)"
  kv kept "$(ls "$BACKUP_DIR/daily" 2>/dev/null | wc -l) daily, $(ls "$BACKUP_DIR/weekly" 2>/dev/null | wc -l) weekly, $(ls "$BACKUP_DIR/monthly" 2>/dev/null | wc -l) monthly"
  systemctl list-unit-files 2>/dev/null | grep -qiE 'acronis|aakore' && kv acronis "agent installed (policy + retention in the Acronis console)"
  hd "Cron"
  grep -hv '^#' /etc/cron.d/yc-* 2>/dev/null | sed 's/^/  /'; crontab -l 2>/dev/null | grep -v '^#' | sed 's/^/  root: /'
  hd "Agents"
  kv salt "$(st salt-minion) $(grep -hs '^id:' /etc/salt/minion.d/*.conf | head -1) - $(salt_ports)$([ -f /etc/cron.d/yc-salt-join ] && echo ', join retry pending')"
  kv acronis "$(st acronis_mms)"
  hd "Commands"
  kv "yallacloud secrets" "credentials + connection strings"
  kv "yallacloud backup" "backup now (yallacloud backups = list, restore FILE)"
  kv "yallacloud allow|deny" "CIDR on port $DB_PORT"
  kv "yallacloud newdb" "NAME [USER] - database + user"
  kv "yallacloud retune" "after a CPU/RAM change"
  kv logs "/var/log/yc-db-deploy.log  /var/log/yc-db-backup.log  $(sqlr 'SELECT @@log_error')"
  kv re-install "yc-db-install (answers: /etc/yallacloud/db.conf.env)"
  echo ;;
secrets) need_root; cat /root/yc-db/handover.txt ;;
backup)  need_root; /usr/local/sbin/yc-db-backup | tee -a /var/log/yc-db-backup.log ;;
backups) need_root; for k in daily weekly monthly; do echo "== $k"; ls -1 "$BACKUP_DIR/$k" 2>/dev/null | while read -r d; do echo "  $d  $(du -sh "$BACKUP_DIR/$k/$d" | cut -f1)  $(ls "$BACKUP_DIR/$k/$d" | tr '\n' ' ')"; done; done ;;
restore)
  need_root; f=${2:-}; [ -f "$f" ] || { echo "usage: yallacloud restore $BACKUP_DIR/daily/<date>/<db>.sql.gz"; exit 1; }
  read -r -p "restore $f into the running server (overwrites that database)? type YES: " a; [ "$a" = YES ] || exit 1
  gunzip -c "$f" | "$(db_cli)" --defaults-file=/root/.my.cnf && echo "restored $f" ;;
allow|deny)
  need_root; c=${2:-}; ip4 "$c" && c="$c/32"; cidr_ok "$c" || { echo "usage: yallacloud $1 <ip|cidr>  (0.0.0.0/0 = any)"; exit 1; }
  if [ "$1" = allow ]; then fw_db add "$c"; n=$(echo "$DB_ALLOW $c" | tr ' ' '\n' | sort -u | tr '\n' ' ')
  else fw_db del "$c"; n=$(echo "$DB_ALLOW" | tr ' ' '\n' | grep -vxF "$c" | tr '\n' ' '); fi
  n=$(echo $n); sed -i "s#^DB_ALLOW=.*#DB_ALLOW='$n'#" /etc/yallacloud/db.conf.env
  echo "port $DB_PORT now allowed from: ${n:-nobody}" ;;
newdb)
  need_root; n=${2:-}; u=${3:-$2}
  [[ "$n" =~ ^[a-z0-9_]{1,64}$ && "$u" =~ ^[a-z_][a-z0-9_]{0,31}$ ]] || { echo "usage: yallacloud newdb NAME [USER]  (a-z 0-9 _)"; exit 1; }
  p=$(genpw) || { echo "password generation failed"; exit 1; }
  sqlr "CREATE DATABASE IF NOT EXISTS \`$n\` CHARACTER SET utf8mb4; CREATE USER '$u'@'%' IDENTIFIED BY '$p'; GRANT ALL PRIVILEGES ON \`$n\`.* TO '$u'@'%'" || exit 1
  detect_ips; h=${HOST_PUB:-$HOST_PRIV}
  t="database    : $n   user $u / $p   (added $(date '+%F %T'))
uri         : mysql://$u:$(urlpw "$p")@$h:$DB_PORT/$n"
  echo "$t" | tee -a /root/yc-db/handover.txt ;;
retune) need_root; db_tune && systemctl restart "$svc" && echo "restarted $svc" ;;
log) less +G /var/log/yc-db-deploy.log ;;
*) sed -n '2,11p' "$0" | sed 's/^# //' ;;
esac
YCEOF
chmod 755 /usr/local/sbin/yallacloud
cat > /etc/profile.d/yallacloud-db.sh <<'EOF'
[ "$(id -u)" = 0 ] && [ -n "$PS1" ] && echo "  YallaCloud $(. /etc/yallacloud/db.conf.env; echo $ENGINE) server - full picture: yallacloud   credentials: yallacloud secrets"
EOF

# ================= 12. verify over TCP the way a client connects
step "12 verify"
for h in ${HOST_PRIV:-} ${PUB_NIC:-} 127.0.0.1; do
  [ -n "$h" ] || continue
  printf '[client]\nuser=%s\npassword="%s"\n' "$DB_ADMIN_USER" "$DB_ADMIN_PASS" > /root/.yc-verify.cnf; chmod 600 /root/.yc-verify.cnf
  r=$("$CLI" --defaults-file=/root/.yc-verify.cnf --protocol=TCP -h "$h" -P "$DB_PORT" -NBe 'SELECT VERSION()' 2>&1) || { rm -f /root/.yc-verify.cnf; die "TCP login $DB_ADMIN_USER@$h:$DB_PORT failed: $r"; }
  say "verify: $DB_ADMIN_USER@$h:$DB_PORT -> $r"
done
rm -f /root/.yc-verify.cnf

# ================= 13. agents: Salt, Acronis (never fail the DB build)
step "13 agents"
if [ "$SALT_JOIN" = yes ] && ! sp=$(salt_ports); then
  # join.sh would fail the same way: record why, keep the 15-min retry (removed by join.sh after JOINED)
  printf '# YallaCloud: Salt master was unreachable at install (%s) - retry the zero-input join until JOINED (STACK4-54 s17)\n*/15 * * * * root curl -fsS https://repo.oasisstack.io/salt/join.sh | sh >/dev/null 2>&1\n' "$sp" > /etc/cron.d/yc-salt-join
  SALT_STATE="BLOCKED - $sp (retry every 15 min)"; warn "salt: $sp - join skipped, retry cron /etc/cron.d/yc-salt-join"
  WAIT_HUMAN="${WAIT_HUMAN:+$WAIT_HUMAN; }open $SALT_MASTER 4505/4506 for this VM"
elif [ "$SALT_JOIN" = yes ]; then
  say "salt: $sp"
  SALT_STATE=$(timeout 1200 bash -c 'curl -fsS --retry 3 https://repo.oasisstack.io/salt/join.sh | sh' 2>&1 | tail -n 3 | tr '\n' ' ')
  say "salt: $SALT_STATE"; [[ "$SALT_STATE" == *JOINED* ]] || { warn "salt join not confirmed: $SALT_STATE"; SALT_STATE="not joined"; }
  [[ "$SALT_STATE" == *JOINED* ]] && SALT_STATE=JOINED
else SALT_STATE="off (SALT_JOIN=no)"; fi
if [ -n "$ACRONIS_TOKEN" ]; then
  timeout 3600 bash -c "curl -fsSL --retry 3 https://repo.oasisstack.io/acronis/acronis-setup.sh | bash -s '$ACRONIS_TOKEN' '$ACRONIS_REGION'"; arc=$?
  case $arc in 0) ACRONIS_STATE="registered ($ACRONIS_REGION)";; 10) ACRONIS_STATE="installed, NOT registered"; WAIT_HUMAN="${WAIT_HUMAN:+$WAIT_HUMAN; }acronis needs a human (exit 10)";; *) ACRONIS_STATE="failed (exit $arc)"; warn "acronis-setup exit $arc - see /var/log/yc-acronis-setup.log";; esac
  say "acronis: $ACRONIS_STATE"
else ACRONIS_STATE="off (ACRONIS_TOKEN blank)"; fi

# tenant for the final webhook: a VM deployed minutes ago may not be in the Salt inventory yet (5-min sync)
if [ -z "$TENANT" ]; then
  for _ in $(seq 1 30); do TENANT=$(yc_tenant) && { TENANT_SRC="salt-inventory (CloudStack domain)"; break; }; TENANT=""; sleep 10; done
  say "tenant: ${TENANT:-still not published after 5 min - webhook sends null}"
  [ -n "$TENANT" ] && sed -i "s/^tenant      : - (/tenant      : $TENANT (/" "$INFO/handover.txt"
fi
# ================= 14. done: cloud-init off (CloudStack would re-run it on every boot)
step "14 done"
[ "$DISABLE_CLOUD_INIT" = yes ] && touch /etc/cloud/cloud-init.disabled 2>/dev/null
rm -f "$INFO/INSTALL-FAILED"
grep -vE '^(root|admin|app user|cli|uri|jdbc|php|python) ' "$INFO/handover.txt"   # no passwords on the console
say "done in ${SECONDS}s - credentials: /root/yc-db/handover.txt (yallacloud secrets)"
