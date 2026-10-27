#!/bin/bash
####################
# yc-pg-install.sh  v1.0.4  (2026-10-27 21:30 IST)  YallaCloud / OasisStack
# Database server (DBaaS node): PostgreSQL (PGDG packages), nothing else.
# OS: Ubuntu 24.04 | RHEL / Rocky / AlmaLinux / Oracle Linux 9 and 10.   Guide: STACK4-64.
# Sibling of yc-db-install.sh (MariaDB / MySQL, STACK4-62): same layout, files, yallacloud command, ERP contract.
#
# Cloud-init: yc-postgresql-userdata.sh writes the answers to /etc/yallacloud/db.conf.env and
# starts this script. Manual: run as root, values as arguments:
#   bash yc-pg-install.sh DB_VERSION=18 DB_NAME=shop DB_USER=shop
# Re-run any time (same answers, passwords kept): yc-db-install
#
# Result : /root/yc-db/handover.txt (credentials + connection strings, chmod 600) | yallacloud
# Log    : /var/log/yc-db-deploy.log (this run + cloud-init log merged)  Status: /var/log/yc-db-deploy.status
####################
set -uo pipefail
umask 022
export HOME=/root LC_ALL=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==== DEFAULTS (cloud-init answers in /etc/yallacloud/db.conf.env win, arguments win over both) ====
ENGINE="postgresql"         # fixed (MariaDB / MySQL: yc-db-install.sh)
DB_VERSION=""               # 15 | 16 | 17 | 18  (community-supported majors, blank = 18)
DB_PORT="5432"
DB_ALLOW=""                 # CIDR list (comma/space) allowed to DB_PORT. blank = any on a public VM, own subnet on a private VM
DB_ADMIN_USER="dbadmin"     # remote admin: SUPERUSER (same power as the MySQL kit's admin)
DB_NAME=""                  # optional first database
DB_USER=""                  # optional owner of DB_NAME (blank = none)
DB_ROOT_PASS=""             # password of the 'postgres' superuser (local only). blank = generated (A-Z a-z 2-9 and '#')
DB_ADMIN_PASS=""
DB_USER_PASS=""
DATA_DISK="auto"            # auto = first empty extra disk -> XFS /data | none | /dev/vdb
BACKUP_KEEP_DAYS="15"       # daily dumps kept
BACKUP_KEEP_WEEKS="4"       # Sunday copies kept (0 = off)
BACKUP_KEEP_MONTHS="12"     # 1st-of-month copies kept (0 = off)
BACKUP_TIME="01:30"         # HH:MM local time
WAL_ARCHIVE="yes"           # yes = WAL archive + daily base backup -> point-in-time recovery (PITR)
WAL_DAYS="7"                # PITR window: base backups + WAL kept this many days
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
EXTRA_WEBHOOK_URL=""        # optional second webhook: gets a copy of every ERP event, credentials stripped (blank = off)
EXTRA_WEBHOOK_SECRET=""     # its X-Webhook-Secret (blank = off)
CLOUDSTACK_URL="https://dxb01.oasisstack.io/client"   # portal this VM came from (cloudPortal / cloudVmUrl in the webhook)
# advanced
APT_MIRRORS="ae.archive.ubuntu.com archive.ubuntu.com"
PASS_URL="https://pass.oasisstack.io/?len=16"
REPO_URL="https://repo.oasisstack.io/db"       # local mirror (ycwsus01, YC ranges only)
DISABLE_CLOUD_INIT="yes"
NET_RETRY_INTERVAL="300"   # internet gate: seconds between checks (master prompt 1A)
NET_MAX_WAIT="0"           # internet gate: give up after N seconds (0 = wait forever)
# ================

VER=1.0.4
KEYS="ENGINE DB_VERSION DB_PORT DB_ALLOW DB_ADMIN_USER DB_NAME DB_USER DB_ROOT_PASS DB_ADMIN_PASS DB_USER_PASS DATA_DISK BACKUP_KEEP_DAYS BACKUP_KEEP_WEEKS BACKUP_KEEP_MONTHS BACKUP_TIME WAL_ARCHIVE WAL_DAYS PUBLIC_IP GATEWAY SSH_PORT SSH_PUBKEY TZ_SET LOCALE_SET SALT_JOIN ACRONIS_TOKEN ACRONIS_REGION NTFY_URL ERP_WEBHOOK_URL ERP_WEBHOOK_SECRET EXTRA_WEBHOOK_URL EXTRA_WEBHOOK_SECRET CLOUDSTACK_URL APT_MIRRORS PASS_URL REPO_URL DISABLE_CLOUD_INIT NET_RETRY_INTERVAL NET_MAX_WAIT"
CFG=/etc/yallacloud/db.conf.env
PGENV=/etc/yallacloud/pg.env
LIB=/usr/local/lib/yc-db-common.sh
INFO=/root/yc-db
LOG=/var/log/yc-db-deploy.log
STATUS=/var/log/yc-db-deploy.status
mkdir -p /etc/yallacloud "$INFO" /var/lib/yallacloud; chmod 700 /etc/yallacloud "$INFO"
touch "$LOG"; chmod 600 "$LOG"
[ "$(readlink -f /proc/self/fd/1)" = "$LOG" ] || exec > >(tee -a "$LOG") 2>&1   # yc-deploy-run already writes stdout to $LOG: tee again = every line twice
DEPLOY_TAG="YC-POSTGRESQL-DB"; RUN_ID="$(hostname -s)-$(date +%Y%m%dT%H%M%S)"; TSYNC=0; T0=$SECONDS
say(){ local p="" l; [ "$TSYNC" = 1 ] || p=" [PRESYNC up=$(cut -d. -f1 /proc/uptime)s]"; l="$(date '+%FT%T%z') [$DEPLOY_TAG] [$RUN_ID] [${STEP:-init}]$p $*"; echo "$l"; logger -t "$DEPLOY_TAG" -- "[$RUN_ID] [${STEP:-init}] $*" 2>/dev/null || true; }
ST_JSON=/var/lib/yallacloud/deploy.status
status_json(){ printf '{"state":"%s","result":"%s","tag":"%s","run_id":"%s","step":"%s","time":"%s","warnings":%s,"log":"%s"}\n' "$1" "${2:-}" "$DEPLOY_TAG" "$RUN_ID" "${STEP:-init}" "$(date '+%FT%T%z')" "${WARNS:-0}" "$LOG" > "$ST_JSON" 2>/dev/null || true; }
WARNS=0; WARN_TXT=""; WARN_LIST=""
warn(){ say "WARN: $*"; WARNS=$((WARNS+1)); WARN_TXT="${WARN_TXT:+$WARN_TXT; }$*"; WARN_LIST="${WARN_LIST:+$WARN_LIST$'\n'}$*"; }   # WARN_LIST: one per line (a message may contain ';')
STEP=init; FAIL_REASON=""
step(){ [ "$STEP" = init ] || echo "$(date '+%FT%T%z') $RUN_ID OK $STEP" >> /var/lib/yallacloud/steps.done; STEP=$1; say "== $1"; status_json RUNNING; }
# apt has no low-speed abort: one degraded HTTPS connection crawled at ~11 KB/s for 10+ min (ycpg-vmw01, fresh curl = 1.8 MB/s).
# Download only, max 300 s per try, new connection each try (apt resumes partial files); then install without a timeout (never kill dpkg).
aptdl(){ local n; for n in 1 2 3 4; do timeout 300 apt-get -y -q -d "$@" && return 0; say "apt download slow or stalled (try $n/4, 300 s) - retrying on a new connection"; done; return 1; }
die(){ FAIL_REASON="$*"; say "YC-FATAL [$STEP]: $*"; echo "$*" > "$INFO/INSTALL-FAILED"; [ "$STEP" = "0 inputs" ] && exit 2; exit 1; }   # 2 = bad input, no automatic retry
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
exec 9>/var/lock/yc-deploy.lock; flock -n 9 || { echo "another yc-deploy run is active (lock /var/lock/yc-deploy.lock)"; exit 1; }
say "yc-pg-install v$VER start (pid $$)"; status_json RUNNING

# answers: defaults < cfg file < arguments (KEY=value)
[ -f "$CFG" ] && . "$CFG"
ENGINE=postgresql   # a leftover MariaDB/MySQL answers file must not change the engine
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
# yc-db-common.sh - YallaCloud DB helpers, PostgreSQL edition (STACK4-64). Sourced, never run.
is_priv(){ [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|169\.254\.|127\.) ]]; }
ip4(){ [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1; local n; for n in "${BASH_REMATCH[@]:1}"; do [ "$n" -le 255 ] || return 1; done; }
cidr_ok(){ local m=${1##*/}; [[ "$1" == */* ]] && ip4 "${1%/*}" && [[ "$m" =~ ^[0-9]{1,2}$ ]] && [ "$m" -le 32 ]; }
# CloudStack VR = the DHCP server (shared networks: NOT the gateway); gateway last
vr_list(){
  grep -hoE 'SERVER_ADDRESS=[0-9.]+' /run/systemd/netif/leases/* 2>/dev/null | cut -d= -f2
  nmcli -g DHCP4.OPTION device show 2>/dev/null | tr '|' '\n' | sed -n 's/.*dhcp_server_identifier = //p'
  grep -h dhcp-server-identifier /var/lib/NetworkManager/*.lease /var/lib/dhclient/*.lease 2>/dev/null | awk '{print $NF}' | tr -d ';'
  ip -4 route show default | awk '{print $3}'
}
# ConfigDrive (isolated networks without a VR): CD labelled config-2, mounted read-only once
cfgdrive(){
  local m=/run/yc-cfgdrive d
  [ -d "$m/cloudstack" ] && { echo "$m"; return 0; }
  d=$(blkid -L config-2 2>/dev/null) || return 1
  mkdir -p "$m" && mount -o ro "$d" "$m" 2>/dev/null && [ -d "$m/cloudstack" ] && echo "$m"
}
# CloudStack metadata: cloud-init cache, then the VR, then the ConfigDrive
md(){
  local k="$1" v="" s
  v=$(python3 -c "import json,sys;d=json.load(open('/run/cloud-init/instance-data.json'));print(d.get('ds',{}).get('meta_data',{}).get(sys.argv[1],'') or '')" "$k" 2>/dev/null)
  if [ -z "$v" ]; then
    for s in $(vr_list | awk '!s[$0]++'); do
      v=$(curl -fs --max-time 3 "http://$s/latest/meta-data/$k" 2>/dev/null) && [ -n "$v" ] && break
    done
  fi
  if [ -z "$v" ]; then local c; c=$(cfgdrive) && v=$(cat "$c/cloudstack/metadata/$k.txt" 2>/dev/null); fi
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
    printf '[Unit]\nDescription=YallaCloud default gateway fix (STACK4-64)\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/sbin/ip route replace default via %s dev %s metric 0\n[Install]\nWantedBy=multi-user.target\n' "$2" "$1" > /etc/systemd/system/yc-gateway.service
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
  for k in $(tr 'A-Z' 'a-z' 2>/dev/null < /sys/class/dmi/id/product_uuid) $(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00$' | sort -u); do
    w=$(curl -fsS -m 5 "https://repo.oasisstack.io/salt/who/$(printf '%s' "$k" | sha256sum | cut -c1-64)" 2>/dev/null) || continue
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
# ---- PostgreSQL: paths written by the installer (PG_MAJOR PGBIN PGDATA CONF_DIR CONF_D HBA SVC PGROOT LOG_DIR WAL_DIR)
[ -f /etc/yallacloud/pg.env ] && . /etc/yallacloud/pg.env
pgrun(){ ( cd / && runuser -u postgres -- "$@" ); }   # as the postgres OS user (peer auth on the socket: no password anywhere)
sqlr(){ pgrun "${PGBIN:-/usr/bin}/psql" -X -qAt -v ON_ERROR_STOP=1 -p "${DB_PORT:-5432}" -d "${2:-postgres}" <<<"$1"; }   # SQL on stdin: never in ps
# pg_hba.conf from DB_ALLOW - fully managed, change with: yallacloud allow|deny <cidr>
hba_write(){
  local c
  {
    echo "# YallaCloud managed (STACK4-64) - written $(date '+%F %T'). Change with: yallacloud allow|deny <cidr>"
    echo "# TYPE  DATABASE     USER      ADDRESS            METHOD"
    echo "local   all          postgres                     peer"
    echo "local   replication  postgres                     peer"
    echo "local   all          all                          scram-sha-256"
    echo "host    all          all       127.0.0.1/32       scram-sha-256"
    echo "host    all          all       ::1/128            scram-sha-256"
    echo "host    all          postgres  0.0.0.0/0          reject"
    echo "host    all          postgres  ::/0               reject"
    for c in $DB_ALLOW; do
      printf 'host    all          all       %-18s scram-sha-256\n' "$c"
      printf 'host    replication  all       %-18s scram-sha-256\n' "$c"
    done
  } > "$HBA.yc-new"
  chown postgres: "$HBA.yc-new"; chmod 640 "$HBA.yc-new"; mv -f "$HBA.yc-new" "$HBA"
  command -v restorecon >/dev/null && restorecon "$HBA" 2>/dev/null; true
}
# memory/CPU based tuning -> conf.d/90-yallacloud-tuning.conf (installer + 'yallacloud retune'). OLTP / mixed web profile.
pg_tune(){
  local ram cpu sb ecs mwm maxc wm pw mw hp f
  ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo); cpu=$(nproc)
  sb=$(( ram/4 )); [ "$sb" -lt 128 ] && sb=128
  ecs=$(( ram*3/4 ))
  mwm=$(( ram/16 )); [ "$mwm" -lt 64 ] && mwm=64; [ "$mwm" -gt 2048 ] && mwm=2048
  if [ "$ram" -lt 2048 ]; then maxc=100; elif [ "$ram" -lt 8192 ]; then maxc=200; else maxc=300; fi
  wm=$(( (ram - sb) / (maxc * 3) )); [ "$wm" -lt 4 ] && wm=4; [ "$wm" -gt 64 ] && wm=64
  pw=$(( cpu/2 )); [ "$pw" -lt 1 ] && pw=1; [ "$pw" -gt 4 ] && pw=4
  mw=$(( cpu > 8 ? cpu : 8 ))
  f="$CONF_D/90-yallacloud-tuning.conf"
  {
    echo "# YallaCloud PostgreSQL tuning (STACK4-64) - RAM ${ram}MB, ${cpu} vCPU, written $(date '+%F %T'). Re-calc: yallacloud retune"
    echo "shared_buffers = ${sb}MB"
    echo "effective_cache_size = ${ecs}MB"
    echo "maintenance_work_mem = ${mwm}MB"
    echo "work_mem = ${wm}MB"
    echo "max_connections = $maxc"
    echo "wal_buffers = 16MB"
    echo "min_wal_size = 1GB"
    echo "max_wal_size = 4GB"
    echo "checkpoint_completion_target = 0.9"
    echo "random_page_cost = 1.1"
    echo "effective_io_concurrency = 200"
    echo "maintenance_io_concurrency = 100"
    echo "max_worker_processes = $mw"
    echo "max_parallel_workers = $cpu"
    echo "max_parallel_workers_per_gather = $pw"
    echo "max_parallel_maintenance_workers = $pw"
    echo "autovacuum_vacuum_cost_limit = 2000"
    echo "jit = off"
    echo "huge_pages = try"
  } > "$f"
  chown postgres: "$f"; chmod 644 "$f"
  # explicit huge pages only where they pay off (shared_buffers >= 4 GB); smaller VMs keep 4k pages
  if [ "$ram" -ge 16384 ]; then
    hp=$(( sb*105/100/2 + 64 )); echo "vm.nr_hugepages = $hp" > /etc/sysctl.d/91-yallacloud-hugepages.conf; sysctl -q -p /etc/sysctl.d/91-yallacloud-hugepages.conf
  else rm -f /etc/sysctl.d/91-yallacloud-hugepages.conf; hp=0; fi
  echo "tuning: shared_buffers=${sb}MB effective_cache_size=${ecs}MB work_mem=${wm}MB maintenance_work_mem=${mwm}MB max_connections=$maxc parallel=$pw/$cpu hugepages=$hp (RAM ${ram}MB, ${cpu} vCPU)"
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
  timeout 20 curl -fsS -o /dev/null -H "Title: $1" -H "Priority: $2" -H "Tags: $3" --data-binary "$4
time    : $(date '+%F %T %z')  ($(date -u +%FT%TZ))
by      : $([ -n "${VER:-}" ] && echo "yc-pg-install $VER" || cut -d" " -f1-2 /etc/yallacloud/db.version 2>/dev/null) on $(hostname -s)" "$NTFY_URL" 2>/dev/null || echo "ntfy: post failed (ignored)"
}
yc_extra(){   # json-file - optional second webhook: copy of the ERP event, credentials stripped, best effort
  [ -n "${EXTRA_WEBHOOK_URL:-}" ] && [ -n "${EXTRA_WEBHOOK_SECRET:-}" ] || return 0
  local h b; h=$(mktemp); b=$(mktemp); chmod 600 "$h" "$b"; printf 'X-Webhook-Secret: %s\nContent-Type: application/json\n' "$EXTRA_WEBHOOK_SECRET" > "$h"
  if python3 - "$1" > "$b" 2>/dev/null <<'PY'
import json, re, sys, time
R = re.compile(r'(?i)pass|pwd|secret|token|^uri|dsn')   # passwords + connection URIs never go to the second target
def s(v):
    if isinstance(v, dict): return {k: ('REDACTED' if R.search(k) and isinstance(x, str) and x else s(x)) for k, x in v.items()}
    if isinstance(v, list): return [s(x) for x in v]
    return v
d = s(json.load(open(sys.argv[1]))); d.setdefault('lastUpdated', time.strftime('%Y-%m-%d %H:%M:%S %z'))
print(json.dumps(d))
PY
  then echo "extra webhook: HTTP $(timeout 15 curl -sS -o /dev/null -w '%{http_code}' -H @"$h" --data-binary @"$b" "$EXTRA_WEBHOOK_URL" 2>/dev/null || echo fail)"
  else echo "extra webhook: payload sanitise failed - nothing sent"; fi
  rm -f "$h" "$b"
}
yc_erp(){    # json-file - ERP webhook (credentials allowed), secret via header file, never argv
  yc_extra "$1"
  [ -n "${ERP_WEBHOOK_URL:-}" ] && [ -n "${ERP_WEBHOOK_SECRET:-}" ] || { echo "erp webhook: ERP_WEBHOOK_SECRET blank - skipped"; return 0; }
  local h c w; h=$(mktemp); chmod 600 "$h"
  printf '%s' "$ERP_WEBHOOK_SECRET" | python3 -c '
import hashlib, hmac, json, sys
k = sys.stdin.read().encode(); b = open(sys.argv[1], "rb").read(); d = json.loads(b)
print("X-Webhook-Secret: " + k.decode()); print("Content-Type: application/json")
print("X-YC-Signature: sha256=" + hmac.new(k, b, hashlib.sha256).hexdigest())
for n, f in (("X-YC-Tag", "tag"), ("X-YC-Run-Id", "run_id"), ("X-YC-Event", "event"), ("X-YC-Timestamp", "timestamp")):
    print(n + ": " + str(d.get(f) or ""))' "$1" > "$h" || { echo "erp webhook: header build failed - nothing sent"; rm -f "$h"; return 0; }
  for w in 10 30 60 120 300 0; do
    c=$(timeout 30 curl -sS -o /dev/null -w '%{http_code}' -H @"$h" --data-binary @"$1" "$ERP_WEBHOOK_URL" 2>/dev/null); c=${c:-000}
    case "$c" in 2??|4??) break;; esac   # 4xx = the ERP said no - retrying will not change it
    [ "$w" = 0 ] || { echo "erp webhook: HTTP $c - retry in ${w}s"; sleep "$w"; }
  done
  echo "erp webhook: HTTP $c"
  rm -f "$h"
}
LIBEOF
chmod 644 "$LIB"
. "$LIB"

TENANT=""; TENANT_SRC=""; HOST_PRIV=""; HOST_PUB=""; PUB_NIC=""; ROOTU=postgres; PGROOT=${PGROOT:-/var/lib/postgresql}
# facts for notifications
VM_NAME=$(md local-hostname); VM_NAME=${VM_NAME:-$(hostname -s)}
SMBIOS=$(tr 'A-Z' 'a-z' 2>/dev/null < /sys/class/dmi/id/product_uuid)
ZONE=$(md availability-zone)
INSTANCE_ID=$(md instance-id)
VM_UUID=$(md vm-id); VM_UUID=${VM_UUID:-$INSTANCE_ID}; VM_UUID=$(printf '%s' "${VM_UUID:-$SMBIOS}" | tr 'A-Z' 'a-z')
OFFERING=$(md service-offering)
CLOUD_ID=$(md cloud-identifier)
HV=$(systemd-detect-virt 2>/dev/null); HV=${HV:-none}   # kvm | vmware | ... (CloudStack runs both)
# ERP match key: KVM SMBIOS = CloudStack VM uuid; VMware SMBIOS = the vCenter BIOS uuid (unrelated) -> metadata vm-id wins
VM_ID=$SMBIOS; ID_SRC=smbios
[[ "$VM_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && [ "$VM_UUID" != "$SMBIOS" ] && { VM_ID=$VM_UUID; ID_SRC=metadata; }
[ -n "$VM_ID" ] || { VM_ID=$VM_UUID; ID_SRC=metadata; }
PREV_RESULT=$(awk -F= '/^RESULT=/{print $2}' "$STATUS" 2>/dev/null)
facts_json(){   # $1 type  $2 summary  $3 with-secrets(yes|no) -> stdout   (same contract as yc-db-install / STACK4-63)
  T="$1" S="$2" W="$3" python3 - <<'PY'
import json, os, time
e = os.environ.get
d = {"type": e("T"), "extra": e("S"), "vmId": e("VM_ID") or None, "smbiosUuid": e("SMBIOS") or None,
     "vmName": e("VM_NAME"), "vmUuid": e("VM_UUID") or None,
     "vmIdMismatch": bool(e("VM_UUID") and e("SMBIOS") and e("VM_UUID") != e("SMBIOS")),
     "tenant": e("TENANT") or None, "tenantSource": e("TENANT_SRC") or None, "serviceOffering": e("OFFERING") or None,
     "hostname": e("VM_NAME"), "ip": e("HOST_PRIV") or e("PUB_NIC") or None, "publicIp": e("HOST_PUB") or None,
     "zone": e("ZONE") or None, "cloud": e("CLOUD_ID") or "YallaCloud", "cloudIdentifier": e("CLOUD_ID") or None,
     "cloudPortal": e("CLOUDSTACK_URL") or None,
     "cloudVmUrl": (e("CLOUDSTACK_URL") + "/#/vm/" + e("VM_UUID")) if e("CLOUDSTACK_URL") and e("VM_UUID") else None, "os": e("PRETTY_NAME"), "osVersion": e("VERSION_ID"),
     "hypervisor": e("HV") or None,
     "catalogue": e("ENGINE") + "-" + e("DB_VERSION"), "area": "db", "status": e("RESULT"), "steps": e("STEP"),
     "warnings": int(e("WARNS") or 0), "installer": "yc-pg-install " + e("VER"),
     "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
if e("W") == "yes":
    d["db"] = {k: (e(v) or None) for k, v in {
        "engine": "ENGINE", "version": "DB_REAL_VERSION", "port": "DB_PORT", "hostPrivate": "HOST_PRIV",
        "hostPublic": "HOST_PUB", "allow": "DB_ALLOW", "rootUser": "ROOTU", "rootPassword": "DB_ROOT_PASS",
        "adminUser": "DB_ADMIN_USER", "adminPassword": "DB_ADMIN_PASS", "database": "DB_NAME",
        "user": "DB_USER", "userPassword": "DB_USER_PASS", "uriAdmin": "URI_ADMIN", "uriUser": "URI_USER",
        "dataDir": "PGDATA", "backupDir": "BACKUP_DIR", "backupRetention": "RETENTION",
        "sshPort": "SSH_PORT"}.items()}
    d["vmUser"] = "root"; d["vmPassword"] = e("VM_PASS") or None
    if e("CHADMIN_PASS"): d["sudoUser"] = "chadmin"; d["sudoPassword"] = e("CHADMIN_PASS")
# same keys as the Odoo kit / payload events (one ERP contract) - additive only
d.update({"offering": e("OFFERING") or None, "identitySource": e("ID_SRC") or "metadata",
          "instanceId": e("INSTANCE_ID") or None, "routerVmId": None, "cloudstackUrl": e("CLOUDSTACK_URL") or None,
          "lastUpdated": time.strftime("%Y-%m-%d %H:%M:%S %z ") + (e("TZ_SET") or "UTC").split("/")[-1], "payload": e("VER"), "freeGb": float(e("FREE_GB")) if e("FREE_GB") else None,
          "delivery": {"queued": 0}})
st = {"vm.deploy.started": "started", "vm.deploy.completed": "completed"}.get(e("T"), "failed")
f = {"area": "db", "status": st, "summary": e("S"), "engine": e("ENGINE"), "dbVersion": e("DB_REAL_VERSION") or e("DB_VERSION"),
     "dbHost": e("HOST_PUB") or e("HOST_PRIV") or None, "dbPort": e("DB_PORT"), "sshPort": e("SSH_PORT") or None,
     "warnings": e("WARN_TXT") or "", "installer": e("VER"), "salt": e("SALT_STATE") or None, "acronis": e("ACRONIS_STATE") or None}
if e("W") == "yes":
    f.update({"dbRootUser": e("ROOTU"), "dbRootPassword": e("DB_ROOT_PASS") or None, "dbAdminUser": e("DB_ADMIN_USER"),
              "dbAdminPassword": e("DB_ADMIN_PASS") or None, "dbName": e("DB_NAME") or None,
              "dbUser": e("DB_USER") or e("DB_ADMIN_USER"), "dbPassword": (e("DB_USER_PASS") if e("DB_USER") else e("DB_ADMIN_PASS")) or None,
              "backupDir": e("BACKUP_DIR") or None, "backupRetention": e("RETENTION") or None,
              "vmUser": "root", "vmPassword": e("VM_PASS") or None})
    if e("CHADMIN_PASS"): f.update({"sudoUser": "chadmin", "sudoPassword": e("CHADMIN_PASS")})
d["fields"] = f
# YC-EVENT v2 sections (STACK4-63), additive - flat v1 keys above stay for the ERP
d["schema"] = "yc-event/2"; d["summary"] = e("S") or e("T")
d["vm"] = {k: d.get(k) for k in ("vmId", "smbiosUuid", "vmUuid", "instanceId", "identitySource", "vmIdMismatch",
                                 "routerVmId", "vmName", "hostname", "ip", "publicIp", "os", "freeGb")}
d["vm"]["osVersion"] = e("VERSION_ID") or ""
d["cloud"] = {"id": e("CLOUD_ID") or None, "zone": d["zone"], "tenant": d["tenant"], "tenantSource": d["tenantSource"],
              "offering": d["serviceOffering"], "portal": d["cloudPortal"], "vmUrl": d["cloudVmUrl"]}
num = lambda x: int(x) if (x or "").isdigit() else None
d["service"] = {"area": "db", "catalogue": d["catalogue"], "status": st,
                "result": e("RESULT") if e("RESULT") not in (None, "", "RUNNING") else None, "steps": e("STEP"),
                "warnings": [w for w in (e("WARN_LIST") or "").split("\n") if w], "installer": d["installer"],
                "details": {"engine": e("ENGINE"), "version": e("DB_REAL_VERSION") or e("DB_VERSION"),
                            "host": e("HOST_PUB") or e("HOST_PRIV") or None, "hostPrivate": e("HOST_PRIV") or None,
                            "port": num(e("DB_PORT")), "allow": e("DB_ALLOW") or None, "tls": "off (plain TCP, sslmode=disable)", "hypervisor": e("HV") or None, "guestAgent": e("GA_STATE") or None,
                            "sshPort": num(e("SSH_PORT")), "dataDir": e("PGDATA") or None, "backupDir": e("BACKUP_DIR") or None,
                            "backupRetention": e("RETENTION") or None, "pitr": e("PITR_TXT") or None,
                            "salt": e("SALT_STATE") or None, "acronis": e("ACRONIS_STATE") or None}}
if e("W") == "yes":   # every secret in ONE place; empty logins left out
    up = lambda u, p, **x: dict({"user": u, "password": p}, **x) if p else None
    db = {"root": up(e("ROOTU"), e("DB_ROOT_PASS")), "admin": up(e("DB_ADMIN_USER"), e("DB_ADMIN_PASS")),
          "app": up(e("DB_USER"), e("DB_USER_PASS")) if e("DB_USER") else None, "database": e("DB_NAME") or None,
          "uriAdmin": e("URI_ADMIN") or None, "uriApp": e("URI_USER") or None}
    c = {"vm": up("root", e("VM_PASS"), source=e("VM_PASS_SRC") or None), "sudo": up("chadmin", e("CHADMIN_PASS")),
         "db": {k: v for k, v in db.items() if v}}
    d["credentials"] = {k: v for k, v in c.items() if v}
# master prompt v1.9.3 section 7.3 / 3B / 5A keys - additive, the ERP keys above stay
ev = {"vm.deploy.started": "deploy.started", "vm.deploy.completed": "deploy.succeeded", "vm.deploy.waiting_network": "deploy.waiting_network"}.get(e("T"), "deploy.failed")
d.update({"event": ev, "tag": e("DEPLOY_TAG"), "run_id": e("RUN_ID"), "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
          "software": "postgresql", "version": e("DB_REAL_VERSION") or e("DB_VERSION"), "role": "db", "topology": "single",
          "result": d["service"]["result"], "duration_s": int(e("DURATION") or 0), "log": "/var/log/yc-db-deploy.log",
          "instanceName": "unknown"})
d["vm"]["instanceName"] = "unknown"; d["vm"]["hypervisor"] = e("HV") or None
d["ssh"] = {"port": num(e("SSH_PORT")), "users": ["root"] + (["chadmin"] if e("CHADMIN_PASS") else []),
            "key_fingerprints": [x for x in (e("SSH_KEY_FP") or "").split() if x.startswith("SHA256:")], "password_auth": True}
d["salt"] = {"joined": e("SALT_STATE") == "JOINED", "minion_id": e("SALT_ID") or None, "state": e("SALT_STATE") or None}
d["acronis"] = {"installed": (e("ACRONIS_STATE") or "").startswith(("registered", "installed")), "reason": e("ACRONIS_STATE") or None}
if e("W") == "yes":
    d["db"].update({"host": e("HOST_PRIV") or e("HOST_PUB") or None, "public_host": e("HOST_PUB") or None, "bind": "0.0.0.0",
                    "allowed_sources": (e("DB_ALLOW") or "").split(), "name": e("DB_NAME") or None,
                    "user": e("DB_USER") or e("DB_ADMIN_USER"),
                    "password": (e("DB_USER_PASS") if e("DB_USER") else e("DB_ADMIN_PASS")) or None})
    srcmap = {"cloudstack": "cloudstack-cloudinit", "cloudstack-password-server": "cloudstack-vr", "generated": "script-generated"}
    osu = [{"user": "root", "password": e("VM_PASS"), "source": srcmap.get(e("VM_PASS_SRC") or "", e("VM_PASS_SRC") or None)}]
    if e("CHADMIN_PASS"): osu.append({"user": "chadmin", "password": e("CHADMIN_PASS"), "source": "script-generated"})
    d.setdefault("credentials", {})["os_users"] = osu
print(json.dumps(d))
PY
}
export DEPLOY_TAG RUN_ID VM_ID ID_SRC HV ENGINE DB_VERSION DB_PORT DB_ALLOW DB_ADMIN_USER DB_NAME DB_USER TZ_SET VM_NAME VM_UUID INSTANCE_ID OFFERING TENANT TENANT_SRC CLOUD_ID CLOUDSTACK_URL SMBIOS ZONE PRETTY_NAME VERSION_ID VER STEP WARNS RESULT ROOTU
RESULT=RUNNING
finish(){
  local rc=$? title prio tags msg typ j
  trap - EXIT INT TERM
  [ -n "${CANCELLED:-}" ] && rc=130
  if [ "$rc" = 0 ]; then RESULT=SUCCESS; elif [ "$rc" = 130 ]; then RESULT=CANCELLED; else RESULT=FAILED; fi
  FREE_GB=$({ df -BM --output=avail "$PGROOT" || df -BM --output=avail /var/lib; } 2>/dev/null | tail -1 | tr -dc 0-9 | awk '{printf "%.1f", $1/1024}')
  DURATION=$((SECONDS-T0)); SALT_ID=$(cat /etc/salt/minion_id 2>/dev/null); status_json "$RESULT" "$RESULT"
  [ "$RESULT" = SUCCESS ] && { touch /var/lib/yallacloud/deploy.done; systemctl disable yc-deploy.service >/dev/null 2>&1; }
  export DURATION SALT_ID SSH_KEY_FP RESULT STEP WARNS WARN_TXT WARN_LIST SALT_STATE ACRONIS_STATE FREE_GB VM_PASS VM_PASS_SRC CHADMIN_PASS HOST_PRIV HOST_PUB PUB_NIC DB_REAL_VERSION DB_ROOT_PASS DB_ADMIN_PASS DB_USER_PASS URI_ADMIN URI_USER PGDATA BACKUP_DIR RETENTION SSH_PORT PITR_TXT
  {
    echo "RESULT=$RESULT"; echo "TIME=$(date '+%F %T %Z')"; echo "INSTALLER=yc-pg-install $VER"
    echo "ENGINE=$ENGINE ${DB_REAL_VERSION:-$DB_VERSION}"; echo "STEP=$STEP"; echo "WARNINGS=$WARNS${WARN_TXT:+ ($WARN_TXT)}"
    [ "$RESULT" = SUCCESS ] || echo "REASON=${FAIL_REASON:-exit $rc in step $STEP}"
  } > "$STATUS"
  say "DEPLOY_RESULT=$RESULT step=$STEP warnings=$WARNS duration=${DURATION}s - status $STATUS + $ST_JSON"
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
      if [ "$PREV_RESULT" = FAILED ]; then title="BACK TO GREEN $ENGINE - $VM_NAME"; prio=3; tags="green_circle,db"
      elif [ "${WAIT_HUMAN:-}" ]; then title="WAIT FOR HUMAN $ENGINE - $VM_NAME"; prio=4; tags="raising_hand,db"; msg="$msg
human   : $WAIT_HUMAN"
      elif [ "$WARNS" -gt 0 ]; then title="OK BUILD WITH WARNINGS $ENGINE - $VM_NAME"; prio=3; tags="warning,db"
      else title="OK BUILD $ENGINE - $VM_NAME"; prio=3; tags="white_check_mark,db"; fi ;;
    CANCELLED) typ=vm.deploy.failed; title="CANCELLED BUILD $ENGINE - $VM_NAME"; prio=4; tags="stop_sign,db" ;;
    *) typ=vm.deploy.failed; title="FAILED BUILD $ENGINE - $VM_NAME"; prio=4; tags="x,db" ;;
  esac
  yc_ntfy "$title" "$prio" "$tags" "$msg"
  j=$(mktemp); chmod 600 "$j"
  facts_json "$typ" "$title | step $STEP | warnings $WARNS${FAIL_REASON:+ | $FAIL_REASON}" "$([ "$RESULT" = SUCCESS ] && echo yes || echo no)" > "$j" && yc_erp "$j" || say "erp webhook: payload build failed - nothing sent"
  [ "$RESULT" = SUCCESS ] && install -m 600 "$j" "$INFO/handover.json"   # = the exact body the ERP received
  rm -f "$j"
  exit "$rc"
}
trap finish EXIT
trap 'CANCELLED=1; exit 130' INT TERM

# ================= 0. check every input: required -> stop with the reason; optional -> warn + default
step "0 inputs"
low(){ printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '[:space:]'; }
DB_VERSION=$(low "$DB_VERSION"); DB_VERSION=${DB_VERSION%%.*}
case "$DB_VERSION" in 15|16|17|18) ;; "") DB_VERSION=18;; *) warn "DB_VERSION '$DB_VERSION' not a supported PostgreSQL major (15 16 17 18; 19 is not GA, 14 ends 2026-11-12) - using 18"; DB_VERSION=18;; esac
{ [[ "$DB_PORT" =~ ^[0-9]{2,5}$ ]] && [ "$DB_PORT" -ge 1024 ] && [ "$DB_PORT" -le 65535 ]; } || { warn "DB_PORT '$DB_PORT' invalid - using 5432"; DB_PORT=5432; }
ALLOW=""
for c in $(printf '%s' "$DB_ALLOW" | tr ',;' '  '); do
  [ "$c" = any ] && c=0.0.0.0/0
  ip4 "$c" && c="$c/32"
  cidr_ok "$c" && ALLOW="$ALLOW $c" || warn "DB_ALLOW entry '$c' is not an IP or CIDR - ignored"
done
DB_ALLOW=$(echo $ALLOW)
uname_ok(){ [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] && [[ "$1" != pg_* ]] && [[ ! " postgres public yc_backup " == *" $1 "* ]]; }
DB_ADMIN_USER=$(low "$DB_ADMIN_USER"); uname_ok "$DB_ADMIN_USER" || { warn "DB_ADMIN_USER '$DB_ADMIN_USER' invalid or reserved - using dbadmin"; DB_ADMIN_USER=dbadmin; }
DB_NAME=$(low "$DB_NAME"); DB_USER=$(low "$DB_USER")
[ -z "$DB_NAME" ] || { [[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] && [[ ! " postgres template0 template1 " == *" $DB_NAME "* ]]; } || { warn "DB_NAME '$DB_NAME' invalid or reserved - no database created"; DB_NAME=""; }
if [ -n "$DB_USER" ]; then
  [ -n "$DB_NAME" ] || { warn "DB_USER '$DB_USER' given without DB_NAME - no user created"; DB_USER=""; }
  [ -z "$DB_USER" ] || uname_ok "$DB_USER" || { warn "DB_USER '$DB_USER' invalid - using $DB_NAME"; DB_USER=$DB_NAME; }
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
WAL_ARCHIVE=$(low "$WAL_ARCHIVE"); case "$WAL_ARCHIVE" in yes|no) ;; *) warn "WAL_ARCHIVE '$WAL_ARCHIVE' invalid - yes"; WAL_ARCHIVE=yes;; esac
num_in "$WAL_DAYS" 1 90 || { warn "WAL_DAYS '$WAL_DAYS' invalid - 7"; WAL_DAYS=7; }
[ -z "$PUBLIC_IP" ] || { ip4 "$PUBLIC_IP" && ! is_priv "$PUBLIC_IP"; } || { warn "PUBLIC_IP '$PUBLIC_IP' invalid - auto"; PUBLIC_IP=""; }
[ -z "$GATEWAY" ] || ip4 "$GATEWAY" || { warn "GATEWAY '$GATEWAY' invalid - auto"; GATEWAY=""; }
if [ -n "$SSH_PORT" ]; then
  { [[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] && [ "$SSH_PORT" != "$DB_PORT" ]; } || { warn "SSH_PORT '$SSH_PORT' invalid - auto"; SSH_PORT=""; }
fi
[ -f "/usr/share/zoneinfo/$TZ_SET" ] || { warn "TZ_SET '$TZ_SET' unknown - Asia/Dubai"; TZ_SET=Asia/Dubai; }
export TZ=$TZ_SET
[[ "$LOCALE_SET" =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]] || { warn "LOCALE_SET '$LOCALE_SET' invalid - en_US.UTF-8"; LOCALE_SET=en_US.UTF-8; }
SALT_JOIN=$(low "$SALT_JOIN"); case "$SALT_JOIN" in yes|no) ;; *) warn "SALT_JOIN '$SALT_JOIN' invalid - yes"; SALT_JOIN=yes;; esac
ACRONIS_TOKEN=$(printf '%s' "$ACRONIS_TOKEN" | tr -d '[:space:]')
ACRONIS_REGION=$(printf '%s' "$ACRONIS_REGION" | tr 'a-z' 'A-Z' | tr -d '[:space:]'); case "$ACRONIS_REGION" in AE|SG) ;; *) warn "ACRONIS_REGION '$ACRONIS_REGION' invalid - AE"; ACRONIS_REGION=AE;; esac
CLOUDSTACK_URL=${CLOUDSTACK_URL%/}
for v in NTFY_URL ERP_WEBHOOK_URL EXTRA_WEBHOOK_URL CLOUDSTACK_URL; do [ -z "${!v}" ] || [[ "${!v}" =~ ^https?://[^[:space:]]+$ ]] || { warn "$v invalid - disabled"; printf -v "$v" '%s' ""; }; done
[[ "$PASS_URL" =~ ^https?:// ]] || PASS_URL="https://pass.oasisstack.io/?len=16"
[[ "$REPO_URL" =~ ^https?:// ]] || REPO_URL="https://repo.oasisstack.io/db"
[ -n "$APT_MIRRORS" ] || APT_MIRRORS="ae.archive.ubuntu.com archive.ubuntu.com"
case "$DISABLE_CLOUD_INIT" in yes|no) ;; *) DISABLE_CLOUD_INIT=yes;; esac

. /etc/os-release
OSV=${VERSION_ID%%.*}
case "$ID" in
  ubuntu) [ "$VERSION_ID" = 24.04 ] || die "Ubuntu 24.04 only (found $PRETTY_NAME)"; OSF=ubuntu; PGROOT=/var/lib/postgresql ;;
  rhel|rocky|almalinux|ol|centos) [[ "$OSV" =~ ^(9|10)$ ]] || die "EL 9 or 10 only (found $PRETTY_NAME)"; OSF=el; PGROOT=/var/lib/pgsql ;;
  *) die "unsupported OS $PRETTY_NAME (Ubuntu 24.04, RHEL/Rocky/Alma/Oracle 9-10)" ;;
esac
say "config: ENGINE=postgresql $DB_VERSION PORT=$DB_PORT ALLOW=${DB_ALLOW:-auto} ADMIN=$DB_ADMIN_USER DB=${DB_NAME:--}/${DB_USER:--} DATA_DISK=$DATA_DISK BACKUP=${BACKUP_KEEP_DAYS}d/${BACKUP_KEEP_WEEKS}w/${BACKUP_KEEP_MONTHS}m@$BACKUP_TIME PITR=$WAL_ARCHIVE/${WAL_DAYS}d SALT=$SALT_JOIN ACRONIS=$([ -n "$ACRONIS_TOKEN" ] && echo "on/$ACRONIS_REGION" || echo off) ERP=$([ -n "$ERP_WEBHOOK_SECRET" ] && echo on || echo off) EXTRA=$([ -n "$EXTRA_WEBHOOK_SECRET" ] && [ -n "$EXTRA_WEBHOOK_URL" ] && echo on || echo off) OS=$PRETTY_NAME"


# ================= 1. network
step "1 network"
for _ in $(seq 1 30); do ip -o -4 addr show scope global | grep -q . && break; sleep 2; done
gwo=$(fix_gateway "$GATEWAY") && say "$gwo" || warn "$gwo"
ip -4 route show default | grep -q . || die "no default route - set GATEWAY= to the firewall LAN IP"
detect_ips
[ -n "$PRIV_NIC$PUB_NIC" ] || die "no IPv4 address on any NIC"
[ -z "$SSH_PORT" ] && { [ -n "$PUB_NIC" ] && SSH_PORT=3222 || SSH_PORT=22; }
if [ -z "$DB_ALLOW" ]; then
  if [ -n "$PUB_NIC$PUBLIC_IP" ] || [ -z "$PRIV_CIDR" ]; then DB_ALLOW=0.0.0.0/0; warn "DB_ALLOW blank on a public VM - port $DB_PORT open to any IP (restrict: yallacloud deny 0.0.0.0/0; yallacloud allow <cidr>)"
  else DB_ALLOW=$PRIV_CIDR; fi
fi
export HOST_PRIV HOST_PUB PUB_NIC
net_ok(){
  NETFAIL=""
  ip -4 route show default | grep -q . || { NETFAIL=route; return 1; }
  { getent hosts github.com || getent hosts repo.oasisstack.io; } >/dev/null || { NETFAIL=dns; return 1; }
  curl -fsS -o /dev/null --max-time 10 https://github.com 2>/dev/null || curl -fsS -o /dev/null --max-time 10 "$REPO_URL/VERSION.txt" 2>/dev/null || { NETFAIL=https; return 1; }
}
waited=0
until net_ok; do
  say "ERROR: internet gate failed at check '$NETFAIL' - waiting ${NET_RETRY_INTERVAL}s (waited ${waited}s, max ${NET_MAX_WAIT}s, 0 = forever)"; status_json WAITING_NETWORK
  [ "$NETFAIL" = dns ] && command -v resolvectl >/dev/null && resolvectl dns "$(ip -4 route show default | awk '{print $5; exit}')" 1.1.1.1 8.8.8.8 2>/dev/null
  fix_gateway "$GATEWAY" >/dev/null 2>&1
  [ "$NET_MAX_WAIT" -gt 0 ] && [ "$waited" -ge "$NET_MAX_WAIT" ] && die "no internet after ${waited}s (failed check: $NETFAIL)"
  sleep "$NET_RETRY_INTERVAL"; waited=$((waited+NET_RETRY_INTERVAL))
done
[ "$waited" -gt 0 ] && say "internet back after ${waited}s"
status_json RUNNING
# time first (7.2): NTP sync before anything TLS-heavy, max 2 min, then ISO 8601 stamps without [PRESYNC]
timedatectl set-timezone "$TZ_SET" 2>/dev/null; timedatectl set-ntp true 2>/dev/null
for _ in $(seq 1 24); do [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && break; sleep 5; done
TSYNC=1
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then
  say "TIME_SYNCED source=$(timedatectl show-timesync -p ServerName --value 2>/dev/null || chronyc -n sources 2>/dev/null | awk '/^\^\*/{print $2}') tz=$TZ_SET time=$(date '+%FT%T%z')"
else warn "time not synchronised after 2 min - continuing on RTC time ($(date '+%FT%T%z'))"; fi
TENANT=$(yc_tenant) && TENANT_SRC="salt-inventory (CloudStack domain)" || { TENANT=""; say "tenant: not published yet (Salt inventory syncs every 5 min) - webhook sends null"; }
say "vm: $VM_NAME uuid ${VM_UUID:-?} smbios ${SMBIOS:-?} tenant ${TENANT:-?} offering ${OFFERING:-?}"
say "ips: private=${HOST_PRIV:-none} public=${HOST_PUB:-none} (nic ${PUB_NIC:-none}, static-nat ${MD_PUB:-none}) subnet=${PRIV_CIDR:-none} allow=$DB_ALLOW ssh=$SSH_PORT"
yc_ntfy "START BUILD $ENGINE - $VM_NAME" 2 "hourglass,db" "vm      : $VM_NAME  tenant ${TENANT:--}  uuid ${VM_UUID:--}
ip      : ${HOST_PRIV:--} / public ${HOST_PUB:--}
engine  : $ENGINE $DB_VERSION port $DB_PORT
os      : $PRETTY_NAME
installer: yc-pg-install $VER"
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
  aptdl upgrade; apt-get -y -q -o Dpkg::Options::=--force-confold upgrade || warn "apt upgrade had errors"
  BASE_PKGS="curl ca-certificates gnupg ufw chrony locales xfsprogs cron gzip fail2ban openssh-server"
  aptdl install $BASE_PKGS; apt-get -y -q install $BASE_PKGS || die "base packages failed"
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
# hypervisor guest agent (CloudStack on VMware and KVM): shutdown/IP/quiesce from the hypervisor. SOFT - never fails the build
case "$HV" in vmware) GA=open-vm-tools;; kvm|qemu) GA=qemu-guest-agent;; *) GA="";; esac
if [ -n "$GA" ]; then
  if [ "$OSF" = ubuntu ]; then apt-get -y -q install "$GA" >/dev/null; else dnf -y -q install "$GA" >/dev/null; fi || warn "$GA install failed ($HV)"
  if [ "$GA" = open-vm-tools ]; then
    systemctl enable --now open-vm-tools >/dev/null 2>&1 || systemctl enable --now vmtoolsd >/dev/null 2>&1
    vmware-toolbox-cmd timesync disable >/dev/null 2>&1   # chrony owns the clock; two time sources fight
  else systemctl start qemu-guest-agent >/dev/null 2>&1; fi
  GA_STATE="$GA $(systemctl is-active open-vm-tools vmtoolsd qemu-guest-agent 2>/dev/null | grep -m1 -x active || echo inactive)"
else GA_STATE="none ($HV)"; fi
say "hypervisor: $HV, guest agent: $GA_STATE"; export GA_STATE
systemctl enable "$CHRONY" >/dev/null 2>&1; systemctl restart "$CHRONY"; timedatectl set-ntp true 2>/dev/null; chronyc -a makestep >/dev/null 2>&1 || true
# swap: guards the postmaster against the OOM killer on a spike (swappiness 1 keeps it out of normal use)
if ! swapon --show | grep -q .; then
  { fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; } && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab || warn "swap file not created"
fi
cat > /etc/sysctl.d/90-yallacloud-db.conf <<'EOF'
# YallaCloud PostgreSQL kernel settings (STACK4-64)
vm.swappiness = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.overcommit_memory = 0
kernel.sched_autogroup_enabled = 0
fs.file-max = 2097152
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
Before=postgresql.service
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
[ -f /root/.ssh/authorized_keys ] && sed -i -E '/Please login as/ s/^.*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9-]+@openssh\.com) /\1 /' /root/.ssh/authorized_keys
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
# OS logins: the KVM v263 template's linked cloud-config sets WELL-KNOWN passwords (root/Root@123, ubuntu/ubuntu,
# chadmin/Reset@123) after CloudStack's - with SSH password login on a public IP that is an open door. Replace them:
# root = the CloudStack-issued password (cloud-init cache, this boot only) or a generated one; chadmin = generated; ubuntu = locked.
if [ -z "${VM_PASS:-}" ]; then
  # CloudStack password (password-enabled template): cloud-init cache -> ConfigDrive -> VR password server -> generated
  VM_PASS=$(python3 -c "import json;print(json.load(open('/run/cloud-init/combined-cloud-config.json')).get('password',''))" 2>/dev/null); VM_PASS_SRC=cloudstack
  if [ ${#VM_PASS} -lt 8 ]; then c=$(cfgdrive) && VM_PASS=$(tr -d '\r\n' < "$c/cloudstack/password/vm_password.txt" 2>/dev/null); VM_PASS_SRC=cloudstack-configdrive; fi
  if [ ${#VM_PASS} -lt 8 ]; then
    for s in $(vr_list | awk '!s[$0]++'); do
      VM_PASS=$(curl -fs --max-time 5 -H "DomU_Request: send_my_password" "http://$s:8080" 2>/dev/null | tr -d '\r\n')
      case "$VM_PASS" in ""|saved_password|bad_request) VM_PASS="";; *) curl -fs --max-time 5 -H "DomU_Request: saved_password" "http://$s:8080" >/dev/null 2>&1; VM_PASS_SRC=cloudstack-password-server; break;; esac
    done
  fi
  if [ ${#VM_PASS} -lt 8 ]; then VM_PASS=$(genpw); VM_PASS_SRC=generated; fi
fi
VM_PASS_SRC=${VM_PASS_SRC:-kept}
[ "$VM_PASS_SRC" = kept ] || { printf 'root:%s\n' "$VM_PASS" | chpasswd || die "setting the root password failed"; }
CHADMIN_PASS=${CHADMIN_PASS:-}
if ! id chadmin >/dev/null 2>&1; then CHADMIN_PASS=""
elif [ -z "$CHADMIN_PASS" ]; then CHADMIN_PASS=$(genpw) && printf 'chadmin:%s\n' "$CHADMIN_PASS" | chpasswd || warn "chadmin password not set"; fi
id ubuntu >/dev/null 2>&1 && passwd -l ubuntu >/dev/null 2>&1
say "os logins: root password = $VM_PASS_SRC, chadmin $([ -n "$CHADMIN_PASS" ] && echo 'password generated' || echo 'not present'), ubuntu locked (template defaults removed)"
( umask 077; printf "DB_ROOT_PASS=%q\nDB_ADMIN_PASS=%q\nDB_USER_PASS=%q\nVM_PASS=%q\nVM_PASS_SRC=%q\nCHADMIN_PASS=%q\n" "$DB_ROOT_PASS" "$DB_ADMIN_PASS" "${DB_USER_PASS:-}" "$VM_PASS" "$VM_PASS_SRC" "$CHADMIN_PASS" > "$INFO/secrets.env" )

# answers file without passwords (re-run, retune, yallacloud, backup read it)
( umask 077; for v in $KEYS; do case $v in *_PASS) continue;; esac; printf '%s=%q\n' "$v" "${!v}"; done > "$CFG" )

# ================= 5. data disk: empty extra disk -> XFS /data, /data/postgresql bind-mounted on the PG home
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
  mkdir -p /data/postgresql /data/backup "$PGROOT"
  if findmnt -n "$PGROOT" >/dev/null; then :
  elif [ -n "$(ls -A "$PGROOT" 2>/dev/null)" ]; then warn "$PGROOT is not empty - left on the root disk (data not moved)"
  else
    grep -q " $PGROOT " /etc/fstab || echo "/data/postgresql $PGROOT none bind,nofail,x-systemd.requires-mounts-for=/data 0 0" >> /etc/fstab
    systemctl daemon-reload; mount "$PGROOT" || die "bind mount /data/postgresql -> $PGROOT failed"
  fi
  BACKUP_DIR=/data/backup
  [ "$OSF" = el ] && { semanage fcontext -a -e /var/lib/pgsql /data/postgresql 2>/dev/null; restorecon -R /data/postgresql 2>/dev/null; }
else
  BACKUP_DIR=/var/backups/yc-db
fi
WAL_DIR=$BACKUP_DIR/wal
mkdir -p "$BACKUP_DIR"; chmod 711 "$BACKUP_DIR"   # 711: the postgres user reaches wal/ and base/, never lists dumps
echo "BACKUP_DIR=$BACKUP_DIR" >> "$CFG"
say "storage: PostgreSQL home $PGROOT on $(findmnt -no SOURCE --target "$PGROOT" 2>/dev/null || findmnt -no SOURCE --target /var/lib) ($(df -h --output=avail /var/lib | tail -1 | tr -d ' ') free), backups $BACKUP_DIR"

# ================= 6. engine: PGDG repo (key/repo rpm also on repo.oasisstack.io) -> OS packages (fallback)
step "6 install postgresql $DB_VERSION"
get(){ curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 -o "$2" "$1"; }   # url out
FALLBACK=""; PG_MAJOR=$DB_VERSION
if [ "$OSF" = ubuntu ]; then
  # the installer creates the cluster itself (port, data checksums, C.UTF-8) - no auto 'main' on 5432
  mkdir -p /etc/postgresql-common/createcluster.d
  printf '# YallaCloud (STACK4-64): yc-pg-install creates the cluster itself\ncreate_main_cluster = false\n' > /etc/postgresql-common/createcluster.d/50-yallacloud.conf
  key=/root/pgdg-ACCC4CF8.asc
  if get https://www.postgresql.org/media/keys/ACCC4CF8.asc $key || get "$REPO_URL/ACCC4CF8.asc" $key; then
    gpg --dearmor --yes -o /usr/share/keyrings/pgdg.gpg $key
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  else warn "PGDG signing key download failed (postgresql.org and $REPO_URL)"; FALLBACK=1; fi
  [ -z "$FALLBACK" ] && { apt-get update -q && aptdl install "postgresql-$PG_MAJOR" "postgresql-client-$PG_MAJOR" && apt-get -y -q install "postgresql-$PG_MAJOR" "postgresql-client-$PG_MAJOR"; } || {
    warn "PostgreSQL $PG_MAJOR (PGDG) install failed - using Ubuntu's PostgreSQL 16"; rm -f /etc/apt/sources.list.d/pgdg.list; apt-get update -q
    aptdl install postgresql-16 postgresql-client-16; apt-get -y -q install postgresql-16 postgresql-client-16 || die "PostgreSQL install failed"; FALLBACK=1; PG_MAJOR=16; }
  PGBIN=/usr/lib/postgresql/$PG_MAJOR/bin; CONF_DIR=/etc/postgresql/$PG_MAJOR/main; PGDATA=$PGROOT/$PG_MAJOR/main
  SVC=postgresql@$PG_MAJOR-main; DROPIN=postgresql@.service.d; LOG_DIR=/var/log/postgresql
  chown postgres:postgres "$PGROOT"
  if [ ! -f "$PGDATA/PG_VERSION" ]; then
    [ -d "$CONF_DIR" ] && pg_dropcluster --stop "$PG_MAJOR" main 2>/dev/null   # an empty auto-created cluster (older postgresql-common)
    pg_createcluster -p "$DB_PORT" --locale=C.UTF-8 -e UTF8 --start-conf=auto "$PG_MAJOR" main -- --data-checksums || die "pg_createcluster $PG_MAJOR main failed"
  fi
else
  arch=$(uname -m)
  rpm -q pgdg-redhat-repo >/dev/null 2>&1 || dnf -y -q install "https://download.postgresql.org/pub/repos/yum/reporpms/EL-$OSV-$arch/pgdg-redhat-repo-latest.noarch.rpm" \
    || dnf -y -q install "$REPO_URL/pgdg-redhat-repo-latest-el$OSV.noarch.rpm" || { warn "PGDG repo package download failed"; FALLBACK=1; }
  [ -z "$FALLBACK" ] && { dnf -qy module disable postgresql >/dev/null 2>&1; dnf -y -q install "postgresql$PG_MAJOR-server" "postgresql$PG_MAJOR-contrib"; } || {
    warn "PostgreSQL $PG_MAJOR (PGDG) install failed - using the OS PostgreSQL"
    dnf -y -q install postgresql-server postgresql-contrib || die "PostgreSQL install failed"; FALLBACK=1
    PG_MAJOR=$(/usr/bin/postgres --version | awk '{print int($3)}'); }
  if [ -z "$FALLBACK" ]; then PGBIN=/usr/pgsql-$PG_MAJOR/bin; PGDATA=$PGROOT/$PG_MAJOR/data; SVC=postgresql-$PG_MAJOR; SETUP="$PGBIN/postgresql-$PG_MAJOR-setup initdb"
  else PGBIN=/usr/bin; PGDATA=$PGROOT/data; SVC=postgresql; SETUP="postgresql-setup --initdb"; fi
  CONF_DIR=$PGDATA; DROPIN=$SVC.service.d; LOG_DIR=$PGDATA/log
  chown postgres:postgres "$PGROOT"
  [ -f "$PGDATA/PG_VERSION" ] || PGSETUP_INITDB_OPTIONS="--data-checksums --locale=C.UTF-8 --encoding=UTF8" $SETUP || die "initdb failed"
fi
[ -n "$FALLBACK" ] && { WAIT_HUMAN="PGDG repo failed - OS PostgreSQL $PG_MAJOR installed, check version"; DB_VERSION=$PG_MAJOR; sed -i "s/^DB_VERSION=.*/DB_VERSION=$PG_MAJOR/" "$CFG"; }
CONF_D=$CONF_DIR/conf.d; HBA=$CONF_DIR/pg_hba.conf
cat > "$PGENV" <<EOF
# YallaCloud PostgreSQL paths (STACK4-64) - written by yc-pg-install $VER
PG_MAJOR=$PG_MAJOR
PGBIN=$PGBIN
PGDATA=$PGDATA
PGROOT=$PGROOT
CONF_DIR=$CONF_DIR
CONF_D=$CONF_D
HBA=$HBA
SVC=$SVC
LOG_DIR=$LOG_DIR
WAL_DIR=$WAL_DIR
EOF
chmod 644 "$PGENV"
say "installed: $("$PGBIN/postgres" --version) service=$SVC data=$PGDATA conf=$CONF_DIR$([ -n "$FALLBACK" ] && echo ' (OS package fallback)')"

# ================= 7. configuration + tuning + pg_hba
step "7 configure"
install -d -o postgres -g postgres -m 755 "$CONF_D"
if [ "$OSF" = el ]; then grep -q "^include_dir = 'conf.d'" "$CONF_DIR/postgresql.conf" || echo "include_dir = 'conf.d'   # YallaCloud STACK4-64" >> "$CONF_DIR/postgresql.conf"
else sed -i -E "s/^#?port = [0-9]+/port = $DB_PORT/" "$CONF_DIR/postgresql.conf"; fi   # pg_lsclusters / pg_wrapper read the port here
install -d -o postgres -g postgres -m 700 "$WAL_DIR"
[ "$OSF" = el ] && { semanage fcontext -a -t postgresql_db_t "$WAL_DIR(/.*)?" 2>/dev/null; restorecon -R "$WAL_DIR" 2>/dev/null; }
{
  echo "# YallaCloud PostgreSQL server settings (STACK4-64) - yc-pg-install $VER. Tuning: 90-yallacloud-tuning.conf"
  echo "listen_addresses = '*'"
  echo "port = $DB_PORT"
  echo "password_encryption = scram-sha-256"
  echo "timezone = '$TZ_SET'"
  echo "log_timezone = '$TZ_SET'"
  echo "shared_preload_libraries = 'pg_stat_statements'"
  echo "pg_stat_statements.max = 5000"
  echo "track_io_timing = on"
  echo "logging_collector = on"
  echo "log_directory = '$LOG_DIR'"
  echo "log_filename = 'postgresql-%a.log'"
  echo "log_truncate_on_rotation = on"
  echo "log_rotation_age = 1d"
  echo "log_rotation_size = 0"
  echo "log_line_prefix = '%m [%p] %q%u@%d %h '"
  echo "log_min_duration_statement = 2000"
  echo "log_checkpoints = on"
  echo "log_lock_waits = on"
  echo "log_temp_files = 10240"
  echo "log_autovacuum_min_duration = 10s"
  echo "wal_level = replica"
  if [ "$WAL_ARCHIVE" = yes ]; then
    echo "archive_mode = on"
    echo "archive_command = '[ -f $WAL_DIR/%f.gz ] || (gzip -c %p > $WAL_DIR/%f.gz.part && mv $WAL_DIR/%f.gz.part $WAL_DIR/%f.gz)'"
    echo "archive_timeout = 900"
  else
    echo "archive_mode = off"
  fi
} > "$CONF_D/80-yallacloud.conf"
chown postgres: "$CONF_D/80-yallacloud.conf"; chmod 644 "$CONF_D/80-yallacloud.conf"
say "$(pg_tune)"
echo "wal_compression = lz4" >> "$CONF_D/90-yallacloud-tuning.conf"   # in the tuning file: rejected together -> defaults
hba_write
PITR_TXT=$([ "$WAL_ARCHIVE" = yes ] && echo "on: WAL archive $WAL_DIR + daily base backup, ${WAL_DAYS} days window" || echo off)
# postmaster out of the OOM killer's reach, backends normal (PostgreSQL docs, Linux memory overcommit)
mkdir -p "/etc/systemd/system/$DROPIN"
printf '[Unit]\nRequiresMountsFor=%s\nAfter=yc-thp-off.service\n[Service]\nLimitNOFILE=65535\nOOMScoreAdjust=-900\nEnvironment=PG_OOM_ADJUST_FILE=/proc/self/oom_score_adj PG_OOM_ADJUST_VALUE=0\n' "$PGROOT" > "/etc/systemd/system/$DROPIN/yallacloud.conf"
[ "$OSF" = ubuntu ] && ! grep -q PG_OOM_ADJUST_FILE "$CONF_DIR/environment" 2>/dev/null && printf "PG_OOM_ADJUST_FILE = '/proc/self/oom_score_adj'\nPG_OOM_ADJUST_VALUE = '0'\n" >> "$CONF_DIR/environment"
[ "$OSF" = el ] && [ "$DB_PORT" != 5432 ] && { semanage port -a -t postgresql_port_t -p tcp "$DB_PORT" 2>/dev/null || semanage port -m -t postgresql_port_t -p tcp "$DB_PORT" 2>/dev/null || true; }
systemctl daemon-reload; systemctl enable "$SVC" >/dev/null 2>&1; [ "$OSF" = ubuntu ] && systemctl enable postgresql >/dev/null 2>&1
if ! systemctl restart "$SVC"; then
  journalctl -u "$SVC" -n 15 --no-pager; tail -n 20 "$LOG_DIR"/postgresql-*.log 2>/dev/null
  mv -f "$CONF_D/90-yallacloud-tuning.conf" "$CONF_D/90-yallacloud-tuning.conf.rejected"
  warn "PostgreSQL refused the tuning - started with defaults (see $CONF_D/90-yallacloud-tuning.conf.rejected)"
  systemctl restart "$SVC" || die "$SVC failed to start with the YallaCloud config - see journalctl -u $SVC and $LOG_DIR"
fi
for _ in $(seq 1 30); do "$PGBIN/pg_isready" -q -p "$DB_PORT" && break; sleep 2; done
"$PGBIN/pg_isready" -q -p "$DB_PORT" || die "$SVC not accepting connections on $DB_PORT"

# ================= 8. passwords + admin + app users (SQL on stdin, statement logging off for these sessions)
step "8 users"
Q="SET log_statement='none'; SET log_min_duration_statement=-1; SET log_min_error_statement=panic;"
role_up(){   # name password attributes
  sqlr "$Q DO \$\$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$1') THEN CREATE ROLE \"$1\"; END IF; END\$\$; ALTER ROLE \"$1\" WITH LOGIN $3 PASSWORD '$2'"
}
sqlr "$Q ALTER ROLE postgres PASSWORD '$DB_ROOT_PASS'" || die "postgres password set failed"
role_up "$DB_ADMIN_USER" "$DB_ADMIN_PASS" SUPERUSER || die "admin role $DB_ADMIN_USER failed"
if [ -n "$DB_NAME" ]; then
  [ -n "$DB_USER" ] && { role_up "$DB_USER" "$DB_USER_PASS" "NOSUPERUSER NOCREATEDB NOCREATEROLE" || die "user $DB_USER failed"; }
  own=${DB_USER:-$DB_ADMIN_USER}
  [ "$(sqlr "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")" = 1 ] || sqlr "CREATE DATABASE \"$DB_NAME\" OWNER \"$own\" ENCODING 'UTF8' TEMPLATE template0" || die "database $DB_NAME failed"
  sqlr "REVOKE CONNECT, TEMPORARY ON DATABASE \"$DB_NAME\" FROM PUBLIC; GRANT CONNECT, TEMPORARY ON DATABASE \"$DB_NAME\" TO \"$own\"" || warn "database $DB_NAME: connect privilege change failed"
fi
sqlr "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" >/dev/null || warn "pg_stat_statements extension not created"
DB_REAL_VERSION=$(sqlr "SHOW server_version" | awk '{print $1}')
# root on the server: plain 'psql' (TCP 127.0.0.1 as postgres, password from ~/.pgpass)
( umask 077; printf 'localhost:%s:*:postgres:%s\n127.0.0.1:%s:*:postgres:%s\n' "$DB_PORT" "$DB_ROOT_PASS" "$DB_PORT" "$DB_ROOT_PASS" > /root/.pgpass )
say "users ok: postgres (local only), $DB_ADMIN_USER (remote superuser)${DB_USER:+, $DB_USER (owner of $DB_NAME)} - server $DB_REAL_VERSION, checksums $(sqlr 'SHOW data_checksums')"

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
  cat > /etc/fail2ban/filter.d/yc-postgresql.conf <<'EOF'
# YallaCloud (STACK4-64): log_line_prefix = '%m [%p] %q%u@%d %h '
[Definition]
failregex = ^.*\[\d+\] \S*@\S* <HOST> FATAL:  (?:password authentication failed for user|no pg_hba\.conf entry for host|pg_hba\.conf rejects connection for host)
ignoreregex =
EOF
  cat > /etc/fail2ban/jail.d/yallacloud.conf <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 6
bantime = 1h
$bk

[yc-postgresql]
enabled = true
filter = yc-postgresql
port = $DB_PORT
logpath = $LOG_DIR/postgresql-*.log
backend = auto
maxretry = 8
bantime = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban || warn "fail2ban failed to start"
fi
say "firewall: ssh $SSH_PORT any, postgresql $DB_PORT from: $DB_ALLOW (pg_hba: scram-sha-256, remote postgres rejected)"

# ================= 10. backups: daily pg_dump per database + roles, base backup for PITR, retention, cron
step "10 backup"
cat > /usr/local/sbin/yc-db-backup <<'EOF'
#!/bin/bash
# yc-db-backup - PostgreSQL backup (STACK4-64). Cron: /etc/cron.d/yc-db-backup
# Layout: $BACKUP_DIR/daily/YYYY-MM-DD/<db>.dump (pg_dump -Fc) + globals.sql.gz (roles), Sunday copy -> weekly/, 1st -> monthly/
#         WAL_ARCHIVE=yes: $BACKUP_DIR/base/YYYY-MM-DD/ (pg_basebackup tar) + $BACKUP_DIR/wal/*.gz, kept WAL_DAYS -> PITR
set -uo pipefail; umask 077; export HOME=/root
. /etc/yallacloud/db.conf.env; . /usr/local/lib/yc-db-common.sh
ST=/var/lib/yallacloud/db-backup.status; prev=$(awk -F= '/^RESULT=/{print $2}' $ST 2>/dev/null)
day=$(date +%F); out="$BACKUP_DIR/daily/$day"; err=""
log(){ echo "[$(date '+%F %T')] $*"; }
sqlr 'SELECT 1' >/dev/null 2>&1 || err="database not answering"
mkdir -p "$out" "$BACKUP_DIR/weekly" "$BACKUP_DIR/monthly"; chmod 700 "$out" "$BACKUP_DIR/daily" "$BACKUP_DIR/weekly" "$BACKUP_DIR/monthly"
size=$(sqlr "SELECT COALESCE(SUM(pg_database_size(datname)),0) FROM pg_database WHERE datallowconn" 2>/dev/null)
free=$(( $(df -Pk "$BACKUP_DIR" | awk 'NR==2{print $4}') * 1024 ))
[ -n "$err" ] || [ "${size:-0}" -lt "$free" ] || err="not enough space: databases ${size} bytes, free ${free} bytes in $BACKUP_DIR"
if [ -z "$err" ]; then
  for db in $(sqlr "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1"); do
    if pgrun "$PGBIN/pg_dump" -p "$DB_PORT" -Fc -d "$db" > "$out/$db.dump.part" && "$PGBIN/pg_restore" -l "$out/$db.dump.part" >/dev/null; then
      mv -f "$out/$db.dump.part" "$out/$db.dump"; log "ok   $db $(du -h "$out/$db.dump" | cut -f1)"
    else rm -f "$out/$db.dump.part"; err="$err dump $db failed;"; log "FAIL $db"; fi
  done
  # roles + passwords (restore first: gunzip -c globals.sql.gz | psql)
  pgrun "$PGBIN/pg_dumpall" -p "$DB_PORT" --globals-only | gzip -c > "$out/globals.sql.gz" && gzip -t "$out/globals.sql.gz" || err="$err globals dump failed;"
fi
[ "$(date +%u)" = 7 ] && [ "${BACKUP_KEEP_WEEKS:-0}" -gt 0 ] && [ ! -e "$BACKUP_DIR/weekly/$day" ] && cp -al "$out" "$BACKUP_DIR/weekly/$day" 2>/dev/null
[ "$(date +%d)" = 01 ] && [ "${BACKUP_KEEP_MONTHS:-0}" -gt 0 ] && [ ! -e "$BACKUP_DIR/monthly/$day" ] && cp -al "$out" "$BACKUP_DIR/monthly/$day" 2>/dev/null
find "$BACKUP_DIR/daily"   -mindepth 1 -maxdepth 1 -type d -mtime +$(( BACKUP_KEEP_DAYS - 1 )) -exec rm -rf {} +
find "$BACKUP_DIR/weekly"  -mindepth 1 -maxdepth 1 -type d -mtime +$(( BACKUP_KEEP_WEEKS * 7 ))  -exec rm -rf {} +
find "$BACKUP_DIR/monthly" -mindepth 1 -maxdepth 1 -type d -mtime +$(( BACKUP_KEEP_MONTHS * 31 )) -exec rm -rf {} +
# PITR: one base backup a day, WAL_DAYS kept; WAL older than the oldest kept base backup's start is not needed
if [ "${WAL_ARCHIVE:-no}" = yes ] && [ -z "$err" ]; then
  b="$BACKUP_DIR/base/$day"; install -d -o postgres -g postgres -m 700 "$BACKUP_DIR/base"
  if [ ! -f "$b/base.tar.gz" ]; then
    rm -rf "$b"; touch "$b.started"
    if pgrun "$PGBIN/pg_basebackup" -p "$DB_PORT" -D "$b" -Ft -z -X stream -c fast; then log "ok   base backup $b $(du -sh "$b" | cut -f1)"
    else rm -rf "$b" "$b.started"; err="$err base backup failed;"; log "FAIL base backup"; fi
  fi
  find "$BACKUP_DIR/base" -mindepth 1 -maxdepth 1 -mtime +$(( WAL_DAYS - 1 )) -exec rm -rf {} +
  oldest=$(ls -1 "$BACKUP_DIR"/base/*.started 2>/dev/null | head -1)
  [ -n "$oldest" ] && [ -d "${oldest%.started}" ] && find "$WAL_DIR" -maxdepth 1 -type f -name '0*' ! -newer "$oldest" -delete
  a=$(sqlr "SELECT failed_count||' failed, last '||COALESCE(last_archived_wal,'-')||' '||COALESCE(to_char(last_archived_time,'YYYY-MM-DD HH24:MI'),'') FROM pg_stat_archiver")
  log "wal archive: $a ($(ls "$WAL_DIR" | wc -l) files, $(du -sh "$WAL_DIR" | cut -f1))"
fi
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
/usr/local/sbin/yc-db-backup >> /var/log/yc-db-backup.log 2>&1 && say "first backup ok ($RETENTION; PITR $PITR_TXT)" || warn "first backup failed - see /var/log/yc-db-backup.log"

# ================= 11. handover + yallacloud command
step "11 handover"
HOST_C=${HOST_PRIV:-$HOST_PUB}; H=${HOST_PUB:-$HOST_C}
URI_ADMIN="postgresql://$DB_ADMIN_USER:$(urlpw "$DB_ADMIN_PASS")@$H:$DB_PORT/postgres?sslmode=disable"
URI_USER=""; [ -n "$DB_USER" ] && URI_USER="postgresql://$DB_USER:$(urlpw "$DB_USER_PASS")@$H:$DB_PORT/$DB_NAME?sslmode=disable"
AU=${DB_USER:-$DB_ADMIN_USER}; AP=$([ -n "$DB_USER" ] && echo "$DB_USER_PASS" || echo "$DB_ADMIN_PASS"); AD=${DB_NAME:-postgres}
umask 077
{
cat <<EOF
==================== YallaCloud database server - handover ====================
created     : $(date '+%F %T %Z')   installer yc-pg-install $VER
vm          : $VM_NAME   ($PRETTY_NAME, $HV, guest agent $GA_STATE)
tenant      : ${TENANT:--} (CloudStack domain)   vm uuid ${VM_UUID:--}   offering ${OFFERING:--}
portal      : ${CLOUDSTACK_URL:--}${CLOUDSTACK_URL:+/#/vm/$VM_UUID}
engine      : PostgreSQL $DB_REAL_VERSION$([ -n "$FALLBACK" ] && echo "   (OS package fallback - PGDG repo failed)")
host        : private ${HOST_PRIV:--}   public ${HOST_PUB:--}
port        : $DB_PORT   (allowed from: $DB_ALLOW)
ssl         : not configured (plain TCP inside the allowed networks; clients: sslmode=disable or prefer)

-- accounts --------------------------------------------------------------------
root        : postgres / $DB_ROOT_PASS        (superuser, on the server only; as root just type: psql)
admin       : $DB_ADMIN_USER / $DB_ADMIN_PASS        (remote, SUPERUSER)
EOF
[ -n "$DB_NAME" ] && echo "database    : $DB_NAME   (owner ${DB_USER:-$DB_ADMIN_USER}, UTF8, C.UTF-8)"
[ -n "$DB_USER" ] && echo "app user    : $DB_USER / $DB_USER_PASS        (remote, owner of $DB_NAME)"
cat <<EOF

-- connect ---------------------------------------------------------------------
cli         : PGPASSWORD='$DB_ADMIN_PASS' psql -h $H -p $DB_PORT -U $DB_ADMIN_USER -d postgres
uri admin   : $URI_ADMIN
EOF
[ -n "$URI_USER" ] && echo "uri app     : $URI_USER"
cat <<EOF
jdbc        : jdbc:postgresql://$H:$DB_PORT/$AD?sslmode=disable   user $AU
php pdo     : new PDO('pgsql:host=$H;port=$DB_PORT;dbname=$AD', '$AU', '$AP');
python      : psycopg.connect(host='$H', port=$DB_PORT, dbname='$AD', user='$AU', password='$AP')
node        : new pg.Pool({ host: '$H', port: $DB_PORT, database: '$AD', user: '$AU', password: '$AP' })
EOF
[ -n "$HOST_PRIV" ] && [ -n "$HOST_PUB" ] && echo "same network: use host $HOST_PRIV instead of $HOST_PUB"
cat <<EOF
note        : '#' in a password is written %23 inside a URI. Many apps: put PgBouncer in front above ~200 connections.

-- server ----------------------------------------------------------------------
ssh         : port $SSH_PORT, root / $VM_PASS   (${VM_PASS_SRC:-kept})${SSH_KEY_FP:+ + key $SSH_KEY_FP}
EOF
[ -n "$CHADMIN_PASS" ] && echo "sudo user   : chadmin / $CHADMIN_PASS"
cat <<EOF
note        : template default passwords (Root@123, ubuntu, Reset@123) were replaced; ubuntu is locked
datadir     : $PGDATA on $(findmnt -no SOURCE --target "$PGDATA")   (data checksums $(sqlr 'SHOW data_checksums'))
backups     : $RETENTION   (yallacloud backup)
pitr        : $PITR_TXT
config      : $CONF_D/80-yallacloud.conf + 90-yallacloud-tuning.conf, $HBA
logs        : $LOG_DIR/postgresql-<Day>.log (7-day rotation), slow queries > 2 s logged
full picture: yallacloud      secrets: yallacloud secrets      log: $LOG
================================================================================
EOF
} > "$INFO/handover.txt"
[ -f "$INFO/extra.txt" ] && cat "$INFO/extra.txt" >> "$INFO/handover.txt"   # yallacloud newdb entries survive a re-run
umask 022
chmod 600 "$INFO/handover.txt"
echo "yc-pg-install $VER $(date '+%F %T %Z')" > /etc/yallacloud/db.version

cat > /usr/local/sbin/yallacloud <<'YCEOF'
#!/bin/bash
# yallacloud - the whole picture of this PostgreSQL server (STACK4-64)
#   yallacloud [info]       setup, tuning, databases, roles, backups, PITR, cron, firewall, agents
#   yallacloud secrets      credentials + connection strings (root)
#   yallacloud backup       run a backup now          yallacloud backups   list backups
#   yallacloud restore FILE restore a <db>.dump (replaces that database) / globals.sql.gz
#   yallacloud allow CIDR | deny CIDR    open/close the DB port for a network (pg_hba + firewall, 0.0.0.0/0 = any)
#   yallacloud newdb NAME [USER]         database + owner with a generated password
#   yallacloud top          top 10 statements by total time (pg_stat_statements)
#   yallacloud retune       re-calculate memory tuning after a resize, restart PostgreSQL
#   yallacloud log          deployment log      yallacloud deploy status|resume|log
. /etc/yallacloud/db.conf.env 2>/dev/null; . /usr/local/lib/yc-db-common.sh
export HOME=/root
kv(){ printf '  %-22s %s\n' "$1" "$2"; }
st(){ systemctl cat "$1" >/dev/null 2>&1 && systemctl is-active "$1" || echo "not installed"; }
hd(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
need_root(){ [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }; }
case "${1:-info}" in
info)
  need_root; detect_ips
  hd "YallaCloud PostgreSQL server - $(hostname -s)"
  kv engine "$(sqlr 'SELECT version()' 2>/dev/null | cut -d, -f1 || echo '(not answering)')"
  kv service "$SVC $(systemctl is-active "$SVC") since $(systemctl show -p ActiveEnterTimestamp --value "$SVC")"
  kv installer "$(cat /etc/yallacloud/db.version 2>/dev/null)   result: $(awk -F= '/^RESULT=/{print $2}' /var/log/yc-db-deploy.status 2>/dev/null)"
  kv os "$(. /etc/os-release; echo "$PRETTY_NAME") kernel $(uname -r)$({ [ -f /var/run/reboot-required ] || { command -v needs-restarting >/dev/null && ! needs-restarting -r >/dev/null 2>&1; }; } && echo '  REBOOT PENDING')"
  kv cpu/ram "$(nproc) vCPU / $(free -h | awk '/Mem:/{print $2}') RAM, swap $(free -h | awk '/Swap:/{print $2}')"
  kv cloud-init "$([ -f /etc/cloud/cloud-init.disabled ] && echo 'disabled after install' || echo enabled)"
  hd "Network"
  kv private "${HOST_PRIV:--}"; kv public "${HOST_PUB:--}"; kv port "$DB_PORT  listening on $(ss -ltnH "sport = :$DB_PORT" | awk '{print $4}' | tr '\n' ' ')"; kv ssh "port $SSH_PORT"
  kv allowed "$DB_ALLOW  (pg_hba $HBA)"
  kv firewall "$(command -v ufw >/dev/null && ufw status | head -1 || echo "firewalld $(firewall-cmd --state 2>/dev/null)")"
  command -v fail2ban-client >/dev/null && kv fail2ban "$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}')"
  hd "Storage"
  kv datadir "$PGDATA on $(findmnt -no SOURCE --target "$PGDATA") - $(df -h --output=used,size,pcent "$PGDATA" | tail -1)"
  kv backups "$BACKUP_DIR - $(df -h --output=avail "$BACKUP_DIR" | tail -1 | tr -d ' ') free"
  hd "Settings (live)"
  for v in shared_buffers effective_cache_size work_mem maintenance_work_mem max_connections max_wal_size wal_compression random_page_cost effective_io_concurrency max_parallel_workers_per_gather jit huge_pages archive_mode data_checksums password_encryption log_min_duration_statement log_directory; do
    kv "$v" "$(sqlr "SHOW $v" 2>/dev/null)"; done
  kv files "$CONF_D/80-yallacloud.conf, $CONF_D/90-yallacloud-tuning.conf"
  kv connections "$(sqlr "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend'") now / max $(sqlr 'SHOW max_connections')"
  kv cache-hit "$(sqlr "SELECT COALESCE(round(100.0*sum(blks_hit)/NULLIF(sum(blks_hit+blks_read),0),2)::text,'-')||' %' FROM pg_stat_database")"
  kv slow-queries "logged when > $(sqlr 'SHOW log_min_duration_statement') in $LOG_DIR (yallacloud top)"
  hd "Databases"
  sqlr "SELECT datname, pg_size_pretty(pg_database_size(datname))||'  owner '||pg_get_userbyid(datdba)||'  '||datcollate FROM pg_database WHERE NOT datistemplate ORDER BY 1" | while IFS='|' read -r a b; do kv "$a" "$b"; done
  hd "Roles"
  sqlr "SELECT rolname, CASE WHEN rolsuper THEN 'superuser' ELSE 'user' END||CASE WHEN rolcanlogin THEN ', login' ELSE '' END FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY 1" | while IFS='|' read -r a b; do kv "$a" "$b"; done
  hd "Backups"
  kv schedule "$(grep -v '^#' /etc/cron.d/yc-db-backup | awk '{printf "%02d:%02d daily", $2, $1}') (/etc/cron.d/yc-db-backup)"
  kv retention "daily ${BACKUP_KEEP_DAYS}d, weekly ${BACKUP_KEEP_WEEKS}, monthly ${BACKUP_KEEP_MONTHS}"
  kv last "$(tr '\n' ' ' < /var/lib/yallacloud/db-backup.status 2>/dev/null || echo none)"
  kv kept "$(ls "$BACKUP_DIR/daily" 2>/dev/null | wc -l) daily, $(ls "$BACKUP_DIR/weekly" 2>/dev/null | wc -l) weekly, $(ls "$BACKUP_DIR/monthly" 2>/dev/null | wc -l) monthly"
  if [ "${WAL_ARCHIVE:-no}" = yes ]; then
    kv pitr "base backups: $(ls -d "$BACKUP_DIR"/base/*/ 2>/dev/null | wc -l) (${WAL_DAYS}d), WAL files: $(ls "$WAL_DIR" 2>/dev/null | wc -l) ($(du -sh "$WAL_DIR" 2>/dev/null | cut -f1))"
    kv archiver "$(sqlr "SELECT archived_count||' archived, '||failed_count||' failed, last '||COALESCE(last_archived_wal,'-')||' at '||COALESCE(to_char(last_archived_time,'YYYY-MM-DD HH24:MI'),'-') FROM pg_stat_archiver")"
  else kv pitr "off (WAL_ARCHIVE=no)"; fi
  systemctl list-unit-files 2>/dev/null | grep -qiE 'acronis|aakore' && kv acronis "agent installed (policy + retention in the Acronis console)"
  hd "Cron"
  grep -hv '^#' /etc/cron.d/yc-* 2>/dev/null | sed 's/^/  /'; crontab -l 2>/dev/null | grep -v '^#' | sed 's/^/  root: /'
  hd "Agents"
  kv salt "$(st salt-minion) $(grep -hs '^id:' /etc/salt/minion.d/*.conf | head -1) - $(salt_ports)$([ -f /etc/cron.d/yc-salt-join ] && echo ', join retry pending')"
  kv acronis "$(st acronis_mms)"
  hd "Commands"
  kv "yallacloud secrets" "credentials + connection strings"
  kv "yallacloud backup" "backup now (yallacloud backups = list, restore FILE)"
  kv "yallacloud allow|deny" "CIDR on port $DB_PORT (pg_hba + firewall)"
  kv "yallacloud newdb" "NAME [USER] - database + owner"
  kv "yallacloud top" "slowest statements"
  kv "yallacloud retune" "after a CPU/RAM change"
  kv psql "as root: psql (postgres superuser via ~/.pgpass)"
  kv logs "/var/log/yc-db-deploy.log  /var/log/yc-db-backup.log  $LOG_DIR/"
  kv re-install "yc-db-install (answers: /etc/yallacloud/db.conf.env)"
  echo ;;
secrets) need_root; cat /root/yc-db/handover.txt ;;
backup)  need_root; /usr/local/sbin/yc-db-backup | tee -a /var/log/yc-db-backup.log ;;
backups) need_root; for k in daily weekly monthly base; do echo "== $k"; ls -1 "$BACKUP_DIR/$k" 2>/dev/null | grep -v '\.started$' | while read -r d; do echo "  $d  $(du -sh "$BACKUP_DIR/$k/$d" | cut -f1)  $(ls "$BACKUP_DIR/$k/$d" | tr '\n' ' ')"; done; done
         [ "${WAL_ARCHIVE:-no}" = yes ] && echo "== wal: $(ls "$WAL_DIR" | wc -l) files, oldest $(ls "$WAL_DIR" | head -1), newest $(ls "$WAL_DIR" | tail -1)" ;;
restore)
  need_root; f=${2:-}; [ -f "$f" ] || { echo "usage: yallacloud restore $BACKUP_DIR/daily/<date>/<db>.dump | globals.sql.gz"; exit 1; }
  read -r -p "restore $f into the running server (drops and re-creates that database)? type YES: " a; [ "$a" = YES ] || exit 1
  case "$f" in
    *.dump) db=$(basename "$f" .dump)
            sqlr "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$db' AND pid<>pg_backend_pid()" >/dev/null
            pgrun "$PGBIN/pg_restore" -p "$DB_PORT" --clean --if-exists --create -d postgres < "$f" && echo "restored $db from $f" ;;
    *.sql.gz) gunzip -c "$f" | pgrun "$PGBIN/psql" -X -q -p "$DB_PORT" -d postgres && echo "restored $f" ;;
    *) echo "unknown file type (want .dump or .sql.gz)"; exit 1 ;;
  esac ;;
allow|deny)
  need_root; c=${2:-}; ip4 "$c" && c="$c/32"; cidr_ok "$c" || { echo "usage: yallacloud $1 <ip|cidr>  (0.0.0.0/0 = any)"; exit 1; }
  if [ "$1" = allow ]; then fw_db add "$c"; n=$(echo "$DB_ALLOW $c" | tr ' ' '\n' | sort -u | tr '\n' ' ')
  else fw_db del "$c"; n=$(echo "$DB_ALLOW" | tr ' ' '\n' | grep -vxF "$c" | tr '\n' ' '); fi
  DB_ALLOW=$(echo $n); sed -i "s#^DB_ALLOW=.*#DB_ALLOW='$DB_ALLOW'#" /etc/yallacloud/db.conf.env
  hba_write && sqlr 'SELECT pg_reload_conf()' >/dev/null
  echo "port $DB_PORT now allowed from: ${DB_ALLOW:-nobody (localhost only)}" ;;
newdb)
  need_root; n=${2:-}; u=${3:-$2}
  [[ "$n" =~ ^[a-z_][a-z0-9_]{0,62}$ && "$u" =~ ^[a-z_][a-z0-9_]{0,62}$ && "$u" != pg_* && "$u" != postgres ]] || { echo "usage: yallacloud newdb NAME [USER]  (a-z 0-9 _)"; exit 1; }
  p=$(genpw) || { echo "password generation failed"; exit 1; }
  sqlr "SET log_statement='none'; SET log_min_error_statement=panic; CREATE ROLE \"$u\" LOGIN PASSWORD '$p'" || exit 1
  sqlr "CREATE DATABASE \"$n\" OWNER \"$u\" ENCODING 'UTF8' TEMPLATE template0" || exit 1
  sqlr "REVOKE CONNECT, TEMPORARY ON DATABASE \"$n\" FROM PUBLIC; GRANT CONNECT, TEMPORARY ON DATABASE \"$n\" TO \"$u\"" >/dev/null
  detect_ips; h=${HOST_PUB:-$HOST_PRIV}
  t="database    : $n   user $u / $p   (added $(date '+%F %T'))
uri         : postgresql://$u:$(urlpw "$p")@$h:$DB_PORT/$n?sslmode=disable"
  ( umask 077; echo "$t" >> /root/yc-db/extra.txt ); echo "$t" | tee -a /root/yc-db/handover.txt ;;
top) need_root; pgrun "$PGBIN/psql" -X -p "$DB_PORT" -d postgres -c "SELECT round(total_exec_time::numeric,0) AS total_ms, calls, round(mean_exec_time::numeric,1) AS mean_ms, left(regexp_replace(query,'\s+',' ','g'),90) AS query FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10" ;;
retune) need_root; pg_tune && echo "wal_compression = lz4" >> "$CONF_D/90-yallacloud-tuning.conf" && systemctl restart "$SVC" && echo "restarted $SVC" ;;
log) less +G /var/log/yc-db-deploy.log ;;
deploy)
  case "${2:-status}" in
    status) cat /var/lib/yallacloud/deploy.status 2>/dev/null; echo; cat /var/log/yc-db-deploy.status 2>/dev/null; tail -n 3 /var/lib/yallacloud/steps.done 2>/dev/null ;;
    resume|rerun) need_root; rm -f /var/lib/yallacloud/deploy.done /var/lib/yallacloud/deploy.attempts; systemctl start --no-block yc-deploy.service 2>/dev/null && echo "yc-deploy.service started - follow: yallacloud deploy log" || /usr/local/sbin/yc-db-install ;;
    log) journalctl -t YC-POSTGRESQL-DB -n 200 --no-pager ;;
    *) echo "usage: yallacloud deploy status|resume|log" ;;
  esac ;;
*) sed -n '2,13p' "$0" | sed 's/^# //' ;;
esac
YCEOF
chmod 755 /usr/local/sbin/yallacloud
cat > /etc/profile.d/yallacloud-db.sh <<EOF
if [ "\$(id -u)" = 0 ]; then
  export PGHOST=127.0.0.1 PGPORT=$DB_PORT PGUSER=postgres PGDATABASE=postgres PATH="$PGBIN:\$PATH"
  [ -n "\$PS1" ] && echo "  YallaCloud PostgreSQL $PG_MAJOR server - full picture: yallacloud   credentials: yallacloud secrets   sql: psql"
fi
EOF

# ================= 12. verify the way a client connects: bind 0.0.0.0 + TCP login on every address
step "12 verify"
ss -ltnH "sport = :$DB_PORT" | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):' || die "PostgreSQL is not listening on 0.0.0.0:$DB_PORT ($(ss -ltnH "sport = :$DB_PORT" | awk '{print $4}' | tr '\n' ' '))"
pf=$(mktemp); chmod 600 "$pf"
for h in ${HOST_PRIV:-} ${PUB_NIC:-} 127.0.0.1; do
  [ -n "$h" ] || continue
  printf '%s:%s:*:%s:%s\n' "$h" "$DB_PORT" "$DB_ADMIN_USER" "$DB_ADMIN_PASS" > "$pf"
  r=$(PGPASSFILE=$pf "$PGBIN/psql" -X -qAt -h "$h" -p "$DB_PORT" -U "$DB_ADMIN_USER" -d postgres -c 'SHOW server_version' 2>&1) || { rm -f "$pf"; die "TCP login $DB_ADMIN_USER@$h:$DB_PORT failed: $r"; }
  say "verify: $DB_ADMIN_USER@$h:$DB_PORT -> $r"
done
if [ -n "$DB_USER" ]; then
  printf '127.0.0.1:%s:*:%s:%s\n' "$DB_PORT" "$DB_USER" "$DB_USER_PASS" > "$pf"
  r=$(PGPASSFILE=$pf "$PGBIN/psql" -X -qAt -h 127.0.0.1 -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c 'CREATE TABLE yc_verify(i int); DROP TABLE yc_verify; SELECT current_user' 2>&1) || { rm -f "$pf"; die "app user $DB_USER cannot create tables in $DB_NAME: $r"; }
  say "verify: $DB_USER owns $DB_NAME (create/drop table ok)"
fi
rm -f "$pf"
[ "$WAL_ARCHIVE" = yes ] && { sqlr "SELECT pg_switch_wal()" >/dev/null; sleep 3; say "verify: wal archive $(sqlr "SELECT archived_count||' archived, '||failed_count||' failed' FROM pg_stat_archiver")"; }

# ================= 13. agents: Salt, Acronis (never fail the DB build)
step "13 agents"
if [ "$SALT_JOIN" = yes ] && ! sp=$(salt_ports); then
  # join.sh would fail the same way: record why, keep the 15-min retry (removed by join.sh after JOINED)
  printf '# YallaCloud: Salt master was unreachable at install (%s) - retry the zero-input join until JOINED (STACK4-54 s17)\n*/15 * * * * root flock -n /run/yc-salt-join.lock timeout 900 sh -c 'curl -fsS --max-time 60 https://repo.oasisstack.io/salt/join.sh | sh' >/dev/null 2>&1\n' "$sp" > /etc/cron.d/yc-salt-join
  SALT_STATE="BLOCKED - $sp (retry every 15 min)"; warn "salt: $sp - join skipped, retry cron /etc/cron.d/yc-salt-join"
  WAIT_HUMAN="${WAIT_HUMAN:+$WAIT_HUMAN; }open $SALT_MASTER 4505/4506 for this VM"
elif [ "$SALT_JOIN" = yes ]; then
  say "salt: $sp"
  SALT_STATE=$(timeout 1200 bash -c 'curl -fsS --retry 3 --max-time 60 https://repo.oasisstack.io/salt/join.sh | sh' 2>&1 | tail -n 3 | tr '\n' ' ')
  say "salt: $SALT_STATE"; [[ "$SALT_STATE" == *JOINED* ]] || { warn "salt join not confirmed: $SALT_STATE"; SALT_STATE="not joined"; }
  [[ "$SALT_STATE" == *JOINED* ]] && SALT_STATE=JOINED
else SALT_STATE="off (SALT_JOIN=no)"; fi
if [ -n "$ACRONIS_TOKEN" ]; then
  YC_AT="$ACRONIS_TOKEN" YC_AR="$ACRONIS_REGION" timeout 3600 bash -c 'curl -fsSL --retry 3 --max-time 120 https://repo.oasisstack.io/acronis/acronis-setup.sh | bash -s "$YC_AT" "$YC_AR"'; arc=$?   # shortcut: token is argv of the inner bash -s (acronis-setup.sh takes no env token yet)
  case $arc in 0) ACRONIS_STATE="registered ($ACRONIS_REGION)";; 8|10) ACRONIS_STATE="installed, NOT registered (exit $arc)"; WAIT_HUMAN="${WAIT_HUMAN:+$WAIT_HUMAN; }acronis needs a human (exit $arc)";; *) ACRONIS_STATE="failed (exit $arc)"; warn "acronis-setup exit $arc - see /var/log/yc-acronis-setup.log";; esac
  say "acronis: $ACRONIS_STATE"
else ACRONIS_STATE="off (ACRONIS_TOKEN blank)"; fi

# tenant for the final webhook: a VM deployed minutes ago may not be in the Salt inventory yet (5-min sync)
if [ -z "$TENANT" ]; then
  t_end=$((SECONDS+300)); while [ $SECONDS -lt $t_end ]; do TENANT=$(yc_tenant) && { TENANT_SRC="salt-inventory (CloudStack domain)"; break; }; TENANT=""; sleep 10; done
  say "tenant: ${TENANT:-still not published after 5 min - webhook sends null}"
  [ -n "$TENANT" ] && sed -i "s/^tenant      : - (/tenant      : $TENANT (/" "$INFO/handover.txt"
fi
# ================= 14. done: cloud-init off (CloudStack would re-run it on every boot)
step "14 done"
[ "$DISABLE_CLOUD_INIT" = yes ] && touch /etc/cloud/cloud-init.disabled 2>/dev/null
rm -f "$INFO/INSTALL-FAILED"
grep -vE '^(root|admin|app user|cli|uri|jdbc|php|python|node|ssh|sudo user|database) ' "$INFO/handover.txt"   # no passwords on the console
say "done in ${SECONDS}s - credentials: /root/yc-db/handover.txt (yallacloud secrets)"
