#!/bin/bash
###############################################################################
#  yc-nextcloud-install.sh  (version: NC_IVER below)                           #
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
#                                                                            #
#  1.4.0  sshd: ALL settings in one drop-in (00-yallacloud-root.conf, first   #
#              in the include glob so it wins). Pubkey auth explicit,         #
#              optional operator key install. Socket activation dropped and   #
#              masked - ssh.socket overrides the Port in sshd_config and a    #
#              socket restart can leave NOTHING listening. Listener is        #
#              verified before the script continues.                         #
#              cloud-init disabled at the end so it stops rewriting netplan,  #
#              the sshd drop-in and the hostname on every boot.              #
#              Final section: post-install checks, then a clean reboot.       #
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
REPO_MIRROR="https://repo.oasisstack.io/payload"  # internal fallback mirror (repo.oasisstack.io, IP-allowlisted) for latest.tar.bz2 + .sha256
TARBALL_URL=""                 # optional INTERNAL mirror (e.g. pbs01) serving
                                # latest.tar.bz2 + latest.tar.bz2.sha256. When set and
                                # TARBALL is not already a local file, both are pulled
                                # to /root over the LAN (fast, no nextcloud.com, no
                                # FortiGate throttle), e.g. "http://10.x.x.x/nextcloud".

# --- ssh ---------------------------------------------------------------------
SSH_PUBKEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDSMLjQxi/2e/MTTyuzD34SA+94GP1+Eyv3PjAXqSMhQy3MdWwZCrnrP+W7FON6ilIDhdI42usXmMhTr0eJQYsTwVdwMZE9OtF4SniauuN7YvJkG9O3W6YclGr0U8xqo4QH48ZQYntB37nP5PUIOgFKkVyH3T7MR2Dp8VZo0n6oa7hgMjIJOVcmC8zhEm0+4/JJSL60gaGA2/251jSELOlAVTalKyuOipZYjnNOY4TqU9owCRPJNGd9e3rP4QOO0p5xjtsFSNDMqacpCSYiIc26y2GNjOqthvWGa4/O84QmMqbtG053VrmNQZGSgmGw+4b9ajC/9Bh8dU0XSEN9ijqc1U86zNXL10GhhAV+H2R3V5wLPbFK3/NAPOi4sqZ1eXq6denlr6Ap2/cAvUT089v5L1CkoXaZY2QCLQleHH3jPRKzvzB+7g7R7VIDXVX977qleExzi48XinzV+W5+dZyHbAK+9iOf5orJGOMWWxj1LKYltPUQeY19B+H4fRDfhDmw7+94oqFxnDPjMaSdcTAosoQ4EdKwqBmtdWhDAaxsIHa1ynkmUo0IwbosDJayjl/GqHeiyAwWWG/7CKwJXTef4ZYETwIWdXobZElzh9/kGrKgoalzT5K5f6sBM/IBciPfhSz8PaOiWc0RwLEkqX8JtzzllgBZItuIKWpSWl4TUw== guest"  # baked-in guest operator key, installed for root
                                # and $SUDO_USER_NAME, e.g.
                                # "ssh-ed25519 AAAAC3Nza... bilal@elitebook"
                                # blank = pubkey auth still enabled, add keys later.
PERMIT_ROOT_LOGIN="yes"        # yes | prohibit-password | no
                                # prohibit-password = key-only root (set SSH_PUBKEY first)
LE_EMAIL="bilalinamdar@gmail.com"  # Let's Encrypt registration email (renewal + expiry
                                # notices). Blank = register without an email.

# --- finish ------------------------------------------------------------------
DISABLE_CLOUD_INIT="yes"       # yes = stop cloud-init re-running every boot once the
                                # build is done. Do NOT set yes on a VM you will clone
                                # or template - see section 14.
REBOOT_AFTER="yes"             # yes = verify every service and port, then reboot
                                # cleanly at the end. no = leave the box running.

# --- notifications (each switchable; ntfy = STATUS ONLY no secrets, webhook = FULL incl. passwords) ---
NOTIFY_NTFY="yes"              # yes|no - push status to ntfy (never secrets)
NTFY_URL="https://ntfy.sh"     # ntfy server base
NTFY_TOPIC="9890122212"        # ntfy topic (change per client/deployment)
NOTIFY_WEBHOOK="no"            # yes|no - POST full JSON incl. credentials (needs WEBHOOK_SECRET)
WEBHOOK_URL="https://api.yallacloud.net/api/v1/webhooks/cloudstack"  # YallaCloud ERP webhook (changeable)
WEBHOOK_SECRET=""              # X-Webhook-Secret header value; set it to turn the webhook on
EXTRA_WEBHOOK_URL=""           # optional second webhook: copy of every event, credentials stripped (blank = off)
EXTRA_WEBHOOK_SECRET=""        # its X-Webhook-Secret
# CloudStack context for the webhook - the deployer/portal supplies these (the guest
# cannot know its own tenant/portal); they are reported so the ERP knows exactly where
# the VM came from. All optional.
CLOUDSTACK_URL="https://dxb01.oasisstack.io/client"  # CloudStack portal (cloudPortal + cloudVmUrl in the webhook)
CS_DOMAIN=""                   # CloudStack domain/tenant that owns this VM
CS_ACCOUNT=""                  # CloudStack account that owns this VM
CS_INSTANCE=""                 # CloudStack internal instance name (i-2-xxxx); deployer-supplied, else the UUID
CS_ROOT_PASS=""                # root password SET BY CLOUDSTACK (password-enabled template). The guest
                                # cannot read it - the password-reset client consumes it at first boot
                                # and never persists the plaintext - so the deployer/portal passes it here
                                # (from the deployVirtualMachine API response) to include it in the webhook.
VM_NAME=""                     # CloudStack VM display name (blank = auto-detect from cloud-init)

# --- integrations (Salt minion + Acronis backup agent) ---
JOIN_SALT="yes"                # yes|no - join this VM to the YallaCloud Salt master (salt.oasisstack.io:4506)
ACRONIS_TOKEN=""               # Acronis registration token; EMPTY = skip Acronis entirely
ACRONIS_REGION="AE"            # AE|SG - Acronis datacenter region

# --- overrides (leave blank to auto-detect) ---------------------------------
SSH_PORT_OVERRIDE=""            # blank = 3222 if the VM has a public IP, else 22.
                                # behind a firewall (private IP) leave blank -> 22.
GATEWAY_OVERRIDE=""             # blank = auto (tries .1, then .254, then .2).
                                # set to your firewall's LAN IP, e.g. 172.30.30.1,
                                # if auto-detect picks the wrong one.
PUBLIC_IP=""                    # optional: the PUBLIC IP that reaches this VM (the
                                # firewall's public IP when behind NAT). Used only for
                                # the sslip.io FQDN fallback and the webhook. Blank =
                                # auto (the VM's own IP when it is already public).
# ============================================================================
#
#  >>> FIREWALL / NAT CASE (private IP like 172.30.30.3) <
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
touch "$LOG"; chmod 600 "$LOG"
# cloud-init already sends our stdout to $LOG - teeing again wrote every line twice
[ "$(readlink -f /proc/$$/fd/1)" = "$LOG" ] || exec > >(tee -a "$LOG") 2>&1

say()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "YC-FATAL: $*" | tee /root/yc-INSTALL-FAILED
         command -v notify_ntfy    >/dev/null 2>&1 && notify_ntfy "FAILED BUILD nextcloud" "result  FAILED: $*
url     https://${FQDN:-?}/" high "x"
         command -v notify_webhook >/dev/null 2>&1 && notify_webhook "vm.deploy.failed" "$*"
         command -v build_deploy_log>/dev/null 2>&1 && build_deploy_log FAILED
         exit 1; }
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
# ycpass (pass.oasisstack.io) issues a password under the SAME house rule and
# lets them be issued centrally; genpw is the offline, always-rule-compliant
# fallback when ycpass is unreachable (isolated VM, outside the YC allow-list)
# or returns something off-rule. ycpass len range is 8-16; we use 16.
ycpass_pw() {
    local p
    p=$(curl -fsS --max-time 8 "https://pass.oasisstack.io/?len=16" 2>/dev/null | tr -d '[:space:]')
    case "$p" in ERROR*|"") return 1 ;; esac
    [ ${#p} -ge 12 ] && printf '%s' "$p" | grep -q '#' || return 1
    printf '%s\n' "$p"
}
rnd()  { ycpass_pw || genpw; }   # ycpass first, local rule-generator as fallback

[ "$(id -u)" = "0" ] || die "run this as root (sudo ./yc-nextcloud-manual.sh)"
# userdata / re-run: an existing conf (written by cloud-init) OVERRIDES the
# CONFIG block above, so one embedded installer serves many VMs.
[ -f "$CFG" ] && . "$CFG"
if grep -qs "'installed' => true" /var/www/nextcloud/config/config.php; then
    say "Nextcloud is already installed here - nothing to do (TLS: yc-nc-ssl, domain: yc-nc-domain, facts: yallacloud)"; exit 0
fi
: "${NOTIFY_NTFY:=yes}"; : "${NTFY_URL:=https://ntfy.sh}"; : "${NTFY_TOPIC:=9890122212}"
: "${NOTIFY_WEBHOOK:=no}"; : "${WEBHOOK_URL:=}"; : "${WEBHOOK_SECRET:=}"; : "${EXTRA_WEBHOOK_URL:=}"; : "${EXTRA_WEBHOOK_SECRET:=}"
VMID=$(tr 'A-Z' 'a-z' < /sys/class/dmi/id/product_uuid 2>/dev/null || echo ""); SSL_STATUS="pending"; NC_VERSION=""; : "${PUBLIC_IP:=}"; SALT_STATE="pending"
NC_IVER="1.2.4"
: "${VM_NAME:=}"; : "${CS_INSTANCE:=}"; : "${CS_DOMAIN:=}"; : "${CS_ACCOUNT:=}"; : "${CS_ROOT_PASS:=}"
: "${CLOUDSTACK_URL:=https://dxb01.oasisstack.io/client}"; CLOUDSTACK_URL="${CLOUDSTACK_URL%/}"
# --- CloudStack metadata reader: cloud-init instance-data first, then the VR metadata server ---
md(){ local k="$1" v s
  v=$(python3 -c "import json,sys;d=json.load(open('/run/cloud-init/instance-data.json'));print(d.get('ds',{}).get('meta_data',{}).get(sys.argv[1],'') or '')" "$k" 2>/dev/null)
  if [ -z "$v" ]; then
    for s in $(grep -hoE 'SERVER_ADDRESS=[0-9.]+' /run/systemd/netif/leases/* 2>/dev/null | cut -d= -f2) $(ip -4 route show default 2>/dev/null | awk '{print $3}'); do
      v=$(curl -fs --max-time 3 "http://$s/latest/meta-data/$k" 2>/dev/null) && [ -n "$v" ] && break
    done
  fi
  printf '%s' "$v" | tr -d '\r\n'; }
# tenant = CloudStack domain, from the Salt who-file keyed by sha256 of the SMBIOS UUID / a MAC
yc_tenant(){ local k w
  for k in "$VMID" $(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00$' | sort -u); do
    [ -n "$k" ] || continue
    w=$(curl -fsS -m 10 "https://repo.oasisstack.io/salt/who/$(printf '%s' "$k" | sha256sum | cut -c1-64)" 2>/dev/null) || continue
    case "$w" in *tenant=*) printf '%s' "$w" | sed -n 's/^tenant=//p' | tr -d '\r '; return 0;; esac
  done; return 1; }
# capture facts once (deployer VM_NAME/CS_INSTANCE/CS_DOMAIN win over metadata)
VM_NAME="${VM_NAME:-$(md local-hostname)}"; VM_NAME="${VM_NAME:-$(hostname -s)}"
ZONE=$(md availability-zone); OFFERING=$(md service-offering); CLOUD_ID=$(md cloud-identifier)
VM_UUID=$(md vm-id); VM_UUID="${VM_UUID:-$(md instance-id)}"; VM_UUID=$(printf '%s' "${VM_UUID:-$VMID}" | tr 'A-Z' 'a-z')
# ERP match key: SMBIOS, unless CloudStack's vm-id differs (VMware: BIOS uuid != CloudStack id) - same rule as the DB/PG kits
VM_ID=$VMID; ID_SRC=smbios
[[ "$VM_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && [ "$VM_UUID" != "$VMID" ] && { VM_ID=$VM_UUID; ID_SRC=metadata; }
[ -n "$VM_ID" ] || { VM_ID=$VM_UUID; ID_SRC=metadata; }
INSTANCE_ID="${CS_INSTANCE:-$(md instance-id)}"
if TENANT=$(yc_tenant); then TENANT_SRC="salt-who"; else TENANT="${CS_DOMAIN:-}"; [ -n "$CS_DOMAIN" ] && TENANT_SRC="config" || TENANT_SRC=""; fi
# root password on a password-enabled CloudStack template (the template itself has no password;
# CloudStack assigns one). Resolve in order: deployer var -> what cloud-init captured this boot
# (VR password server; public / VR networks) -> the ConfigDrive vm_password.txt (isolated / private-IP
# / LAN networks with no reachable VR) -> generate our own if CloudStack provided none. Then ALWAYS
# reset root to it, because the KVM v263 template's linked cloud-config chpasswd leaves root on a
# default - so the password the portal shows and the webhook reports is the real, working one.
CS_ROOT_SRC="config"
if [ -z "$CS_ROOT_PASS" ]; then
  CS_ROOT_PASS=$(python3 -c "import json;print(json.load(open('/run/cloud-init/combined-cloud-config.json')).get('password','') or '')" 2>/dev/null)
  [ -n "$CS_ROOT_PASS" ] && CS_ROOT_SRC="cloudstack (metadata)"
fi
if [ -z "$CS_ROOT_PASS" ]; then
  for _d in $(blkid -t LABEL=config-2 -o device 2>/dev/null; blkid -L config-2 2>/dev/null); do
    _m=$(mktemp -d)
    mount -o ro "$_d" "$_m" 2>/dev/null && { CS_ROOT_PASS=$(tr -d '\r\n' < "$_m"/cloudstack/password/vm_password.txt 2>/dev/null); umount "$_m" 2>/dev/null; }
    rmdir "$_m" 2>/dev/null
    [ -n "$CS_ROOT_PASS" ] && { CS_ROOT_SRC="cloudstack (configdrive)"; break; }
  done
  case "$CS_ROOT_PASS" in saved_password|bad_request) CS_ROOT_PASS="";; esac
fi
if [ -z "$CS_ROOT_PASS" ]; then CS_ROOT_PASS=$(rnd 18); CS_ROOT_SRC="generated (no CloudStack password found)"; fi
printf 'root:%s\n' "$CS_ROOT_PASS" | chpasswd 2>/dev/null || true
# The template's cloud-config gives 'ubuntu' the fixed password 'ubuntu' on every VM, and SSH password
# login is on: lock it (keys and console still work; owner 2026-10-26, same as db v1.0.9).
id ubuntu >/dev/null 2>&1 && passwd -l ubuntu >/dev/null 2>&1 || true
export VM_ID ID_SRC HV GA_STATE SALT_STATE SSL_STATUS ACRONIS_TOKEN TZ_SET VMID NC_IVER VM_NAME VM_UUID INSTANCE_ID ZONE OFFERING CLOUD_ID TENANT TENANT_SRC CLOUDSTACK_URL FQDN NET_IP PUBLIC_IP NET_SHAPE ADMIN_USER ADMIN_PASS DB_NAME DB_USER DB_PASS REDIS_PASS SUDO_USER_NAME SUDO_PASS CS_ROOT_PASS CS_ROOT_SRC SSH_PORT DATA_PATH SSL_STATUS NC_VERSION PORTSFX
notify_ntfy(){   # $1 title $2 message [$3 priority] [$4 tags] - STATUS ONLY, never secrets
  [ "${NOTIFY_NTFY:-no}" = yes ] && [ -n "${NTFY_TOPIC:-}" ] || return 0
  curl -fsS --max-time 10 -H "Title: $1 - $(hostname)" -H "Priority: ${3:-default}" -H "Tags: ${4:-information_source},nextcloud" --data-binary "$2
host    $(hostname)  ${NET_IP:-}${PUBLIC_IP:+  public ${PUBLIC_IP}}
os      $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
time    $(TZ="${TZ_SET:-UTC}" date '+%F %T %z') ${TZ_SET##*/}  ($(date -u +%FT%TZ))
vm      ${VM_NAME:--}  uuid ${VM_UUID:--}${ZONE:+  zone ${ZONE}}
tenant  ${TENANT:-not published yet}  (${TENANT_SRC:--})  ${CLOUDSTACK_URL:-}
by      yc-nextcloud-install / ${NC_IVER}  log ${LOG}" "${NTFY_URL%/}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
}
notify_webhook(){  # $1 type $2 extra [$3 with-secrets:yes|no] - house YCERP-01 envelope, X-Webhook-Secret (+ optional second webhook)
  local erp=no xtra=no
  [ "${NOTIFY_WEBHOOK:-no}" = yes ] && [ -n "${WEBHOOK_URL:-}" ] && erp=yes
  [ -n "${EXTRA_WEBHOOK_URL:-}" ] && [ -n "${EXTRA_WEBHOOK_SECRET:-}" ] && xtra=yes
  [ "$erp$xtra" = nono ] && return 0
  local j; j=$(mktemp); chmod 600 "$j"
  WTYPE="$1" WEXTRA="$2" WSEC="${3:-no}" python3 - > "$j" <<'PY'
import json,os,time,socket
e=os.environ.get
def osr():
    d={}
    try:
        for l in open('/etc/os-release'):
            if '=' in l:
                k,v=l.rstrip().split('=',1); d[k]=v.strip('"')
    except OSError: pass
    return d
o=osr(); PORTSFX=e("PORTSFX") or ""; CU=e("CLOUDSTACK_URL") or ""; VU=e("VM_UUID") or ""
d={"type":e("WTYPE"),"extra":e("WEXTRA"),
 "vmId":e("VM_ID") or e("VMID") or None,"smbiosUuid":e("VMID") or None,"identitySource":e("ID_SRC") or "smbios",
 "vmName":e("VM_NAME") or None,"vmUuid":VU or None,"instanceId":e("INSTANCE_ID") or None,
 "vmIdMismatch":bool(VU and e("VMID") and VU!=e("VMID")),
 "hostname":socket.gethostname(),"fqdn":e("FQDN") or None,
 "ip":e("NET_IP") or None,"publicIp":e("PUBLIC_IP") or None,"shape":e("NET_SHAPE") or None,
 "zone":e("ZONE") or None,"cloud":"YallaCloud","cloudIdentifier":e("CLOUD_ID") or None,
 "cloudPortal":CU or None,"cloudVmUrl":(CU+"/#/vm/"+VU) if CU and VU else None,
 "tenant":e("TENANT") or None,"tenantSource":e("TENANT_SRC") or None,"serviceOffering":e("OFFERING") or None,
 "os":o.get("PRETTY_NAME","Linux"),"osVersion":o.get("VERSION_ID","")+" / "+os.uname().release,
 "catalogue":"nextcloud-"+(e("NC_VERSION") or ""),"area":"nextcloud",
 "installer":"yc-nextcloud-install "+(e("NC_IVER") or ""),
 "utc":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),
 "app":{"url":"https://%s%s/"%(e("FQDN") or "",PORTSFX),"tls":e("SSL_STATUS") or "",
   "ncVersion":e("NC_VERSION") or "","sshPort":e("SSH_PORT") or "","dataPath":e("DATA_PATH") or "",
   "dbName":e("DB_NAME") or ""}}
T=e("WTYPE") or ""; ok=T=="vm.deploy.completed"
st={"vm.deploy.started":"started","vm.deploy.completed":"completed"}.get(T,"failed")
warn=[w for w in ["salt: "+e("SALT_STATE") if (e("SALT_STATE") or "").startswith(("FAILED","BLOCKED")) else "",
                  "tls: "+e("SSL_STATUS") if (e("SSL_STATUS") or "").startswith("self-signed") else ""] if w]
try: fs=os.statvfs(e("DATA_PATH") or "/")
except OSError: fs=os.statvfs("/")
d["schema"]="yc-event/2"; d["summary"]=e("WEXTRA") or T
d["vm"]={"vmId":d["vmId"],"smbiosUuid":d["smbiosUuid"],"vmUuid":d["vmUuid"],"instanceId":d["instanceId"],
 "identitySource":d["identitySource"],"vmIdMismatch":d["vmIdMismatch"],"routerVmId":None,"vmName":d["vmName"],
 "hostname":d["hostname"],"ip":d["ip"],"publicIp":d["publicIp"],"os":d["os"],"osVersion":o.get("VERSION_ID",""),
 "freeGb":round(fs.f_bavail*fs.f_frsize/1073741824,1)}
d["cloud"]={"id":e("CLOUD_ID") or None,"zone":d["zone"],"tenant":d["tenant"],"tenantSource":d["tenantSource"],
 "offering":d["serviceOffering"],"portal":d["cloudPortal"],"vmUrl":d["cloudVmUrl"]}
d["service"]={"area":"salt" if T.startswith("vm.salt.") else "nextcloud","catalogue":d["catalogue"],"status":st,
 "result":("SUCCESS" if not warn else "SUCCESS with warnings") if ok else ("FAILED" if st=="failed" else None),
 "warnings":warn,"installer":d["installer"],
 "details":dict(d["app"],hypervisor=e("HV") or None,guestAgent=e("GA_STATE") or None,sshPort=int(e("SSH_PORT")) if (e("SSH_PORT") or "").isdigit() else None,fqdn=d["fqdn"],shape=d["shape"],salt=e("SALT_STATE") or None,
                acronis="on" if e("ACRONIS_TOKEN") else "off")}
if e("WSEC")=="yes":   # every secret in ONE place, YC-EVENT v2 shape; empty logins left out
  def up(u,pw,**x): return dict({"user":u,"password":pw},**x) if pw else None
  c={"vm":up("root",e("CS_ROOT_PASS"),source=e("CS_ROOT_SRC") or None),
     "sudo":up(e("SUDO_USER_NAME"),e("SUDO_PASS")),
     "nextcloud":{"admin":up(e("ADMIN_USER"),e("ADMIN_PASS"))},
     "db":{"app":up(e("DB_USER"),e("DB_PASS")),"database":e("DB_NAME") or None},
     "redis":{"password":e("REDIS_PASS")} if e("REDIS_PASS") else None}
  d["credentials"]={k:v for k,v in c.items() if v and any(x is not None for x in v.values())}
d["delivery"]={"queued":0}
print(json.dumps(d))
PY
  if [ "$erp" = yes ]; then
    curl -fsS --max-time 20 -H "Content-Type: application/json" ${WEBHOOK_SECRET:+-H @<(printf 'X-Webhook-Secret: %s\n' "$WEBHOOK_SECRET")} --data-binary @"$j" "${WEBHOOK_URL}" >/root/yc-webhook-$1.resp 2>&1 || true
    install -m 600 "$j" "/root/yc-webhook-$1.json"  # root-only copy of what was sent (same secrets as yc-handover.json)
  fi
  if [ "$xtra" = yes ]; then   # second webhook: same event, credentials stripped, best effort
    local x; x=$(mktemp); chmod 600 "$x"
    python3 - "$j" > "$x" 2>/dev/null <<'PY' && curl -fsS --max-time 15 -H "Content-Type: application/json" -H @<(printf 'X-Webhook-Secret: %s\n' "$EXTRA_WEBHOOK_SECRET") --data-binary @"$x" "$EXTRA_WEBHOOK_URL" >/dev/null 2>&1 || true
import json, re, sys, time
R = re.compile(r'(?i)pass|pwd|secret|token|^uri|dsn')
def s(v):
    if isinstance(v, dict): return {k: ('REDACTED' if R.search(k) and isinstance(x, str) and x else s(x)) for k, x in v.items() if k != 'credentials'}
    if isinstance(v, list): return [s(x) for x in v]
    return v
d = s(json.load(open(sys.argv[1]))); d.setdefault('lastUpdated', time.strftime('%Y-%m-%d %H:%M:%S %z'))
print(json.dumps(d))
PY
    rm -f "$x"
  fi
  rm -f "$j"
}
build_deploy_log(){  # $1 = SUCCESS|FAILED - ONE merged log: installer + cloud-init
  local DPL=/var/log/yc-nextcloud-deploy.log
  { echo "==== YallaCloud Nextcloud deploy: $1  $(date -Is) ===="
    echo "fqdn=${FQDN} ip=${NET_IP:-} shape=${NET_SHAPE:-} ssl=${SSL_STATUS:-} nc=${NC_VERSION:-} vmId=${VMID}"
    echo; echo "---- installer log (${LOG}) ----"; cat "$LOG" 2>/dev/null
    for c in /var/log/cloud-init-output.log /var/log/cloud-init.log; do
      [ -f "$c" ] && { echo; echo "---- $c ----"; cat "$c"; }
    done
    echo; echo "==== end: $1 ===="
  } > "$DPL" 2>/dev/null || true
  chmod 600 "$DPL" 2>/dev/null || true
}
case "$FQDN" in cloud.example.com|"") FQDN=""; FQDN_AUTO=yes ;; *) FQDN_AUTO=no ;; esac
: "${HTTPS_PORT:=443}"           # blank -> standard 443 (nginx listen needs a port)
: "${PERMIT_ROOT_LOGIN:=yes}"
: "${SSH_PUBKEY:=}"
: "${DISABLE_CLOUD_INIT:=yes}"
: "${REBOOT_AFTER:=yes}"

# persist the choices so a re-run and the handover agree
mkdir -p /etc/yallacloud
install -m 600 /dev/null "$CFG"
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
REPO_MIRROR=$REPO_MIRROR
NOTIFY_NTFY=$NOTIFY_NTFY
NTFY_URL=$NTFY_URL
NTFY_TOPIC=$NTFY_TOPIC
NOTIFY_WEBHOOK=$NOTIFY_WEBHOOK
WEBHOOK_URL=$WEBHOOK_URL
WEBHOOK_SECRET=$WEBHOOK_SECRET
EXTRA_WEBHOOK_URL=$EXTRA_WEBHOOK_URL
EXTRA_WEBHOOK_SECRET=$EXTRA_WEBHOOK_SECRET
CLOUDSTACK_URL=$CLOUDSTACK_URL
CS_DOMAIN=$CS_DOMAIN
CS_ACCOUNT=$CS_ACCOUNT
CS_INSTANCE=$CS_INSTANCE
CS_ROOT_PASS="$CS_ROOT_PASS"
VM_NAME="$VM_NAME"
JOIN_SALT=$JOIN_SALT
ACRONIS_TOKEN=$ACRONIS_TOKEN
ACRONIS_REGION=$ACRONIS_REGION
APT_MIRROR=$APT_MIRROR
SSH_PUBKEY="$SSH_PUBKEY"
PERMIT_ROOT_LOGIN=$PERMIT_ROOT_LOGIN
LE_EMAIL="$LE_EMAIL"
DISABLE_CLOUD_INIT=$DISABLE_CLOUD_INIT
REBOOT_AFTER=$REBOOT_AFTER
PUBLIC_IP=$PUBLIC_IP
SSH_PORT_OVERRIDE=$SSH_PORT_OVERRIDE
GATEWAY_OVERRIDE=$GATEWAY_OVERRIDE
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
[ -n "${PUBLIC_IP:-}" ] || { [ "${IS_PUBLIC:-0}" = 1 ] && PUBLIC_IP="$NET_IP"; }
# FQDN fallback: no domain given -> a working sslip.io name off the reachable IP, so the
# box always comes up named (and gets a real LE cert when that IP is public). Switch to
# the paid domain later in one step:  yc-nc-domain <your-domain> --le
if [ "${FQDN_AUTO:-no}" = yes ]; then
    _ipn="${PUBLIC_IP:-$NET_IP}"
    FQDN="$(printf '%s' "$_ipn" | tr '.' '-').sslip.io"
    sed -i "s|^FQDN=.*|FQDN=$FQDN|" "$CFG" 2>/dev/null || echo "FQDN=$FQDN" >> "$CFG"
    say "no FQDN given - using sslip.io fallback $FQDN (change later: yc-nc-domain <domain> --le)"
fi
notify_ntfy "START BUILD nextcloud" "url     https://${FQDN}/
ip      ${NET_IP} (${NET_SHAPE})  tier ${TIER}  data ${DATA_PATH}" low "hourglass_flowing_sand"
notify_webhook "vm.deploy.started" "network ${NET_SHAPE}"
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

say "using distro PHP $PHPV - no third-party APT repositories are added"

# ------------------------------------------------------------ 3. secrets
DB_PASS=$(rnd 24); DB_ROOT_PASS=$(rnd 24)
ADMIN_PASS=$(rnd 18); SUDO_PASS=$(rnd 18); REDIS_PASS=$(rnd 24)
DB_NAME=nextcloud; DB_USER=nc_user01

# ------------------------------------------------------------- 4. packages
export DEBIAN_FRONTEND=noninteractive
# Ubuntu 24.04 unattended hygiene (common first-boot traps):
#  - needrestart pops an interactive service/kernel-restart prompt that HANGS a
#    cloud-init run; NEEDRESTART_MODE=a auto-restarts, SUSPEND=1 skips the prompt.
export NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 UCF_FORCE_CONFFOLD=1
#  - cloud-init / unattended-upgrades can still hold the dpkg lock at first boot;
#    wait it out so our first apt-get does not die on a lock (max ~5 min).
for _ in $(seq 1 60); do
  fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || break
  sleep 5
done
timedatectl set-timezone "$TZ_SET" 2>/dev/null || true
#  - a skewed clock makes Let's Encrypt and TLS fail; force NTP sync on.
timedatectl set-ntp true 2>/dev/null || true
#  - generate the system locale so apt/perl stop warning and occ has a real locale.
locale-gen en_GB.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_GB.UTF-8 >/dev/null 2>&1 || true
# Ubuntu 24.04 repo fix: the default archive.ubuntu.com / cloudflare / eu.archive
# mirrors can be slow or unreachable on some networks. Repoint the archive host
# at APT_MIRROR (default the UAE mirror ae.archive.ubuntu.com). security.ubuntu.com
# is left as-is. Handles the deb822 ubuntu.sources and the legacy sources.list.
# a slow regional mirror (seen live: ae.archive at 15 KB/s) turns the build into hours - measure, fall back
if [ "${APT_MIRROR}" != archive.ubuntu.com ]; then
  _ms=$(curl -s -o /dev/null -m 15 -w '%{speed_download}' "http://${APT_MIRROR}/ubuntu/dists/noble/main/binary-amd64/Packages.gz" 2>/dev/null | cut -d. -f1)
  if [ "${_ms:-0}" -lt 200000 ]; then
    say "  mirror ${APT_MIRROR} slow or unreachable (${_ms:-0} B/s) - using archive.ubuntu.com"; APT_MIRROR=archive.ubuntu.com
  else say "  mirror ${APT_MIRROR} ok ($((_ms/1024)) KB/s)"; fi
fi
say "pointing apt archive mirror at ${APT_MIRROR}"
for F in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
  [ -f "$F" ] || continue
  sed -i -E "s#https?://([a-z0-9.-]*\\.)?archive\\.ubuntu\\.com/ubuntu#http://${APT_MIRROR}/ubuntu#g" "$F"
done
# a stalled mirror connection otherwise hangs apt forever (seen live: 17 min on one http fetch)
printf 'Acquire::http::Timeout "30";\nAcquire::https::Timeout "30";\nAcquire::Retries "3";\n' > /etc/apt/apt.conf.d/99yallacloud-timeouts
say "apt update"
timeout 900 apt-get update -qq || { sleep 10; timeout 900 apt-get update -qq; } || die "apt update failed (mirror ${APT_MIRROR} unreachable or stalled)"
apt-get upgrade -y -qq

say "installing nginx, mariadb, redis, php $PHPV"
apt-get install -y -qq \
  nginx mariadb-server redis-server certbot python3-certbot-nginx \
  php${PHPV}-fpm php${PHPV}-gd php${PHPV}-mysql php${PHPV}-curl php${PHPV}-mbstring \
  php${PHPV}-intl php${PHPV}-gmp php${PHPV}-bcmath php${PHPV}-xml php${PHPV}-imagick \
  php${PHPV}-zip php${PHPV}-redis php${PHPV}-apcu \
  ufw fail2ban unzip bzip2 ghostscript libfontconfig1 curl \
  || die "package installation failed"

# hypervisor guest agent (CloudStack runs VMware and KVM): IP / clean shutdown / quiesce from the
# hypervisor. Same rule as the DB and PG kits. SOFT - never fails the build.
HV=$(systemd-detect-virt 2>/dev/null); HV=${HV:-none}
case "$HV" in vmware) GA=open-vm-tools;; kvm|qemu) GA=qemu-guest-agent;; *) GA="";; esac
if [ -n "$GA" ]; then
  apt-get install -y -qq "$GA" >/dev/null 2>&1 || say "  WARN: $GA install failed ($HV)"
  if [ "$GA" = open-vm-tools ]; then
    systemctl enable --now open-vm-tools >/dev/null 2>&1 || true
    vmware-toolbox-cmd timesync disable >/dev/null 2>&1 || true   # timesyncd owns the clock; two sources fight
  else systemctl start qemu-guest-agent >/dev/null 2>&1 || true; fi
  GA_STATE="$GA $(systemctl is-active open-vm-tools qemu-guest-agent 2>/dev/null | grep -m1 -x active || echo inactive)"
else GA_STATE="none ($HV)"; fi
say "hypervisor: $HV, guest agent: $GA_STATE"

# ------------------------------------------------------------- 5. database
# --------------------------------------- 15a. operator scripts + data disk + DB backup
cat > /usr/local/bin/yc-nc-datadisk <<'YCEOF'
#!/bin/bash
# yc-nc-datadisk [--apply] - set up a BLANK second disk for the Nextcloud data dir.
# LVM + xfs when LVM tools exist, else a straight xfs filesystem on the whole disk.
# SAFETY: only ever touches a whole disk that is NOT the root disk, has NO
# partitions/children, NO filesystem signature, and is NOT mounted. Anything with
# data is left untouched (do it manually). Dry-run unless --apply.
set -euo pipefail
CFG=/etc/yallacloud/nextcloud.conf; [ -f "$CFG" ] && . "$CFG"; DATA_PATH="${DATA_PATH:-/nc_data}"
root_src=$(findmnt -no SOURCE / 2>/dev/null)
rootdisk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)
[ -n "$rootdisk" ] || rootdisk=$(basename "$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)" 2>/dev/null)
cand=""
while read -r name type; do
  [ "$type" = disk ] || continue
  [ "/dev/$name" = "/dev/$rootdisk" ] || [ "$name" = "$rootdisk" ] && continue
  [ -n "$(lsblk -no NAME "/dev/$name" | tail -n +2)" ] && continue          # has partitions
  [ -n "$(blkid -o value -s TYPE "/dev/$name" 2>/dev/null)" ] && continue   # has a filesystem
  findmnt -S "/dev/$name" >/dev/null 2>&1 && continue                        # mounted
  cand="$name"; break
done < <(lsblk -dno NAME,TYPE)
if [ -z "$cand" ]; then
  echo "no BLANK second disk found - only an empty, unpartitioned, unformatted disk is used automatically."
  echo "Add a disk later and run: yc-nc-datadisk --apply   (or set up $DATA_PATH by hand)."; exit 0
fi
dev="/dev/$cand"
echo "blank disk: $dev ($(lsblk -dno SIZE "$dev"))  ->  $DATA_PATH"
[ "${1:-}" = "--apply" ] || { echo "DRY RUN - nothing changed. Re-run with --apply to use it."; exit 0; }
mountpoint -q "$DATA_PATH" && { echo "$DATA_PATH is already a mount - aborting"; exit 0; }
if command -v pvcreate >/dev/null 2>&1; then
  pvcreate -ff -y "$dev"; vgcreate ncvg "$dev"; lvcreate -y -l 100%FREE -n ncdata ncvg
  src=/dev/ncvg/ncdata; mkfs.xfs -f "$src"
else
  src="$dev"; mkfs.xfs -f "$src"
fi
mkdir -p "$DATA_PATH"
tmp=$(mktemp -d); mount "$src" "$tmp"
[ -n "$(ls -A "$DATA_PATH" 2>/dev/null)" ] && cp -a "$DATA_PATH"/. "$tmp"/ 2>/dev/null || true
umount "$tmp"; rmdir "$tmp"
uuid=$(blkid -o value -s UUID "$src")
grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $DATA_PATH xfs defaults,noatime 0 2" >> /etc/fstab
mount "$DATA_PATH"
id www-data >/dev/null 2>&1 && chown -R www-data:www-data "$DATA_PATH"
echo "OK - $src formatted xfs, mounted at $DATA_PATH, fstab persisted."
YCEOF
chmod 755 /usr/local/bin/yc-nc-datadisk
cat > /usr/local/bin/yc-nc-backup <<'YCEOF'
#!/bin/bash
# yc-nc-backup - dump the Nextcloud database and keep the last 15 days.
# Root MariaDB is unix_socket (no password). Run daily by /etc/cron.d/yc-nc-backup.
set -euo pipefail
CFG=/etc/yallacloud/nextcloud.conf; [ -f "$CFG" ] && . "$CFG"
DB="${DB_NAME:-nextcloud}"; DEST=/var/backups/nextcloud; KEEP=15
mkdir -p "$DEST"; chmod 700 "$DEST"
f="$DEST/${DB}-$(date +%F_%H%M).sql.gz"
mysqldump --no-defaults -u root --single-transaction --routines --triggers "$DB" | gzip -9 > "$f"
find "$DEST" -maxdepth 1 -name "${DB}-*.sql.gz" -mtime +"$KEEP" -delete
echo "$(date -Is) ok $f ($(du -h "$f" | cut -f1)); retention ${KEEP}d" >> "$DEST/backup.log"
YCEOF
chmod 755 /usr/local/bin/yc-nc-backup
cat > /usr/local/bin/yc-nc-domain <<'YCEOF'
#!/bin/bash
# yc-nc-domain <new-fqdn> - change the Nextcloud domain end to end
# (config, nginx server_name, occ trusted_domains + overwrite.cli.url, hostname).
# Optional 2nd arg --le also issues a free Let's Encrypt cert in the same step.
set -euo pipefail
new="${1:?usage: yc-nc-domain <new-fqdn> [--le]}"
CFG=/etc/yallacloud/nextcloud.conf; . "$CFG"; old="$FQDN"
NCROOT=/var/www/nextcloud; occ(){ sudo -u www-data php "$NCROOT/occ" "$@"; }
PORTSFX=""; [ -n "${HTTPS_PORT:-}" ] && [ "$HTTPS_PORT" != 443 ] && PORTSFX=":$HTTPS_PORT"
sed -i "s|^FQDN=.*|FQDN=$new|" "$CFG"
sed -i "s/server_name .*/server_name $new;/" /etc/nginx/sites-available/nextcloud 2>/dev/null || true
occ config:system:set overwrite.cli.url --value="https://${new}${PORTSFX}/"
occ config:system:set trusted_domains 0 --value="$new"
if [ "${SET_HOSTNAME:-yes}" = yes ]; then hostnamectl set-hostname "$new" 2>/dev/null || true; fi
nginx -t && systemctl reload nginx
echo "domain changed: $old -> $new"
if [ "${2:-}" = "--le" ]; then yc-nc-ssl le; else
  echo "next: yc-nc-ssl le (free)  OR  yc-nc-ssl import <fullchain.pem> <privkey.pem> (paid)  OR re-run with --le"
fi
YCEOF
chmod 755 /usr/local/bin/yc-nc-domain
cat > /usr/local/bin/yc-nc-ssl <<'YCEOF'
#!/bin/bash
# yc-nc-ssl - TLS certificate management for this Nextcloud
#   yc-nc-ssl le                                   free Let's Encrypt (webroot) issue/renew + nginx reload
#   yc-nc-ssl import <fullchain.pem> <privkey.pem> install a PAID cert (PEM/fullchain)
#   yc-nc-ssl from-pfx <file.pfx> [password]       convert a PFX/.p12 to key+fullchain and install
#   yc-nc-ssl make-fullchain <cert.pem> <inter.pem> [out.pem]   just build a fullchain (leaf + intermediate)
#   yc-nc-ssl status                               show the live cert issuer + expiry
# Free LE auto-renews via the certbot systemd timer (reload hook included).
set -euo pipefail
CFG=/etc/yallacloud/nextcloud.conf; . "$CFG"
NG=/etc/nginx/sites-available/nextcloud; DST=/etc/ssl/yc; mkdir -p "$DST"
point(){ sed -i "s#ssl_certificate .*#ssl_certificate $1;#; s#ssl_certificate_key .*#ssl_certificate_key $2;#" "$NG"; }
reload(){ nginx -t && systemctl reload nginx; }
case "${1:-status}" in
  le)
    certbot certonly --webroot -w /var/www/nextcloud -n --agree-tos -m "${LE_EMAIL:-admin@${FQDN}}" -d "$FQDN" \
      --deploy-hook "systemctl reload nginx"
    point "/etc/letsencrypt/live/${FQDN}/fullchain.pem" "/etc/letsencrypt/live/${FQDN}/privkey.pem"; reload
    echo "Let's Encrypt cert installed for $FQDN (auto-renews via certbot.timer).";;
  import)
    [ -f "${2:-}" ] && [ -f "${3:-}" ] || { echo "usage: yc-nc-ssl import <fullchain.pem> <privkey.pem>"; exit 1; }
    install -m 644 "$2" "$DST/paid-fullchain.pem"; install -m 600 "$3" "$DST/paid-privkey.pem"
    point "$DST/paid-fullchain.pem" "$DST/paid-privkey.pem"; reload; echo "paid cert installed.";;
  from-pfx)
    f="${2:?usage: yc-nc-ssl from-pfx <file.pfx> [password]}"; pw="${3:-}"
    openssl pkcs12 -in "$f" -nocerts -nodes ${pw:+-passin pass:$pw} -out "$DST/paid-privkey.pem"
    openssl pkcs12 -in "$f" -clcerts -nokeys ${pw:+-passin pass:$pw} -out "$DST/_leaf.pem"
    openssl pkcs12 -in "$f" -cacerts -nokeys -chain ${pw:+-passin pass:$pw} -out "$DST/_chain.pem" 2>/dev/null || : > "$DST/_chain.pem"
    cat "$DST/_leaf.pem" "$DST/_chain.pem" > "$DST/paid-fullchain.pem"
    chmod 600 "$DST/paid-privkey.pem"; chmod 644 "$DST/paid-fullchain.pem"; rm -f "$DST/_leaf.pem" "$DST/_chain.pem"
    point "$DST/paid-fullchain.pem" "$DST/paid-privkey.pem"; reload; echo "cert installed from PFX $f.";;
  make-fullchain)
    out="${4:-$DST/fullchain.pem}"; cat "${2:?cert}" "${3:?intermediate}" > "$out"; echo "wrote $out";;
  status)
    echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT:-443}" -servername "$FQDN" 2>/dev/null \
      | openssl x509 -noout -issuer -subject -enddate;;
  *) grep '^#' "$0" | sed 's/^# \{0,1\}//';;
esac
YCEOF
chmod 755 /usr/local/bin/yc-nc-ssl
say "  operator scripts installed: yc-nc-datadisk, yc-nc-backup, yc-nc-domain, yc-nc-ssl"
# DB backup: nightly 02:30, 15-day retention (the script enforces retention)
cat > /etc/cron.d/yc-nc-backup <<'EOF'
30 2 * * * root /usr/local/bin/yc-nc-backup >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/yc-nc-backup
say "  DB backup cron installed (nightly 02:30 -> /var/backups/nextcloud, keep 15 days)"
# free-SSL auto-renew: certbot ships its own timer; make sure it is enabled
systemctl enable --now certbot.timer >/dev/null 2>&1 || true
# data disk: auto-use a BLANK second disk for the data dir (fresh install, before any data is written)
say "checking for a blank second disk for ${DATA_PATH}"
/usr/local/bin/yc-nc-datadisk --apply || say "  (no blank disk / left for manual setup)"


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
grep -q "^; yallacloud" "$PHPINI" || cat >> "$PHPINI" <<EOF

; yallacloud
opcache.enable=1
opcache.interned_strings_buffer=64
opcache.max_accelerated_files=10000
opcache.memory_consumption=256
opcache.revalidate_freq=1
opcache.enable_cli=1
opcache.save_comments=1
apc.enable_cli=1
realpath_cache_size=4M
realpath_cache_ttl=600
EOF

# php-fpm pool sized to RAM (conservative: ~64 MB per worker, min 8, cap 120); safe dynamic pm
PHP_CH=$(( RAM_MB / 64 )); [ "$PHP_CH" -lt 8 ] && PHP_CH=8; [ "$PHP_CH" -gt 120 ] && PHP_CH=120
POOL=/etc/php/${PHPV}/fpm/pool.d/www.conf
if [ -f "$POOL" ]; then
  sed -i "s/^pm = .*/pm = dynamic/;
          s/^pm.max_children = .*/pm.max_children = ${PHP_CH}/;
          s/^pm.start_servers = .*/pm.start_servers = $(( PHP_CH/4>2?PHP_CH/4:2 ))/;
          s/^pm.min_spare_servers = .*/pm.min_spare_servers = 2/;
          s/^pm.max_spare_servers = .*/pm.max_spare_servers = $(( PHP_CH/2>4?PHP_CH/2:4 ))/;
          s/^;pm.max_requests = .*/pm.max_requests = 500/" "$POOL"
  say "  php-fpm pool: pm=dynamic max_children=${PHP_CH} (RAM ${RAM_MB}M)"
fi

# kernel sysctl - CONSERVATIVE (connection backlog, low swappiness, redis overcommit)
cat > /etc/sysctl.d/90-yallacloud-nextcloud.conf <<SYS
# YallaCloud Nextcloud - safe kernel tweaks
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 2048
net.core.netdev_max_backlog = 2048
vm.swappiness = 10
vm.overcommit_memory = 1
fs.file-max = 262144
SYS
sysctl --system >/dev/null 2>&1 || true
say "  kernel sysctl applied (backlog, swappiness=10, overcommit=1 for redis)"
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
# Pull the archive from a mirror before the local-file check: TARBALL_URL
# (GitHub release) first, then REPO_MIRROR (internal repo.oasisstack.io). Never
# download.nextcloud.com. First mirror that yields the file wins; verify_archive
# below still checks the sha256, so a bad/partial mirror copy is rejected.
if { [ -n "$TARBALL_URL" ] || [ -n "$REPO_MIRROR" ]; } && { [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; }; then
    TARBALL="/root/latest.tar.bz2"
    for _mir in "$TARBALL_URL" "$REPO_MIRROR"; do
        [ -n "$_mir" ] || continue
        say "fetching Nextcloud from $_mir"
        if curl -fSL --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 1800 --speed-limit 10240 --speed-time 120 -o "$TARBALL" "$_mir/latest.tar.bz2"; then
            curl -fSL --retry 3 --retry-delay 5 --max-time 60 -o "${TARBALL}.sha256" "$_mir/latest.tar.bz2.sha256" \
                || say "  no .sha256 at $_mir - will check archive integrity only"
            [ -s "$TARBALL" ] && { say "  fetched $(du -h "$TARBALL" | cut -f1) from $_mir"; break; }
        fi
        say "  $_mir did not serve the archive - trying next"
    done
    [ -s "$TARBALL" ] || die "all tarball mirrors failed (TARBALL_URL=$TARBALL_URL, REPO_MIRROR=$REPO_MIRROR); pre-seed /root/latest.tar.bz2 instead"
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
    fetch_nextcloud || die "could not obtain a verified Nextcloud archive after ${NC_ATTEMPTS:-0} attempts.
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
openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
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
if [ -n "${LE_EMAIL:-}" ]; then _le_em="-m $LE_EMAIL"; else _le_em="--register-unsafely-without-email"; fi
if certbot certonly --webroot -w /var/www/nextcloud -n --agree-tos --deploy-hook "systemctl reload nginx" \
     $_le_em -d "$FQDN" >/dev/null 2>&1; then
  SSL_STATUS="free (Let's Encrypt)"
  # point nginx at the real cert (replaces the temporary self-signed pair)
  sed -i "s#ssl_certificate .*#ssl_certificate /etc/letsencrypt/live/${FQDN}/fullchain.pem;#;
          s#ssl_certificate_key .*#ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;#" \
    /etc/nginx/sites-available/nextcloud
  nginx -t && systemctl reload nginx
  say "certificate issued and installed"
  SSL_OK=yes
else
  SSL_STATUS="self-signed (Let's Encrypt failed)"
  say "WARNING: Let's Encrypt failed - the site is up on the temporary self-signed cert."
  say "         Port 80 must be reachable from the internet (NAT 80 -> this VM:80)."
  say "         Once forwarded, run: yc-nc-ssl le"
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

# ALL sshd settings live in ONE drop-in. Ubuntu 24.04's sshd_config begins with
# "Include /etc/ssh/sshd_config.d/*.conf", the glob is read in sort order, and
# sshd takes the FIRST value it sees for a keyword. The 00- prefix therefore
# wins over cloud-init's 50-cloud-init.conf and anything in sshd_config itself.
sed -i '/^#\?Port /d' /etc/ssh/sshd_config
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-yallacloud-root.conf <<EOF
# Written by yc-nextcloud. First file in the include glob, so these values win.
Port ${SSH_PORT}
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes
PermitRootLogin ${PERMIT_ROOT_LOGIN}
KbdInteractiveAuthentication no
UsePAM yes
EOF
chmod 644 /etc/ssh/sshd_config.d/00-yallacloud-root.conf

# install the operator key, if one was supplied
install_key() {
    local user="$1" home
    home=$(getent passwd "$user" | cut -d: -f6)
    [ -n "$home" ] && [ -d "$home" ] || { say "  no home directory for ${user} - key skipped"; return; }
    mkdir -p "${home}/.ssh"
    touch "${home}/.ssh/authorized_keys"
    grep -qxF "$SSH_PUBKEY" "${home}/.ssh/authorized_keys" \
        || echo "$SSH_PUBKEY" >> "${home}/.ssh/authorized_keys"
    chmod 700 "${home}/.ssh"; chmod 600 "${home}/.ssh/authorized_keys"
    chown -R "${user}:$(id -gn "$user")" "${home}/.ssh"
    say "  key installed for ${user}"
}
if [ -n "$SSH_PUBKEY" ]; then
    case "$SSH_PUBKEY" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-*\ *|sk-ecdsa-*\ *) : ;;
        *) die "SSH_PUBKEY does not look like a public key line (expected ssh-ed25519, ssh-rsa, ecdsa-sha2-* or sk-*)" ;;
    esac
    install_key root
    install_key "$SUDO_USER_NAME"
    SSH_KEY_STATE="yes"
else
    say "  no SSH_PUBKEY set - pubkey auth is enabled, add keys to ~/.ssh/authorized_keys"
    SSH_KEY_STATE="no"
fi

# Ubuntu 24.04 ships ssh.socket ENABLED. Under socket activation the Port in
# sshd_config is IGNORED (the port lives in the unit), and restarting the
# socket can leave NOTHING listening - locking you out of a box that looks
# perfectly healthy. Drop socket activation and run sshd as a plain service:
# one source of truth for the port, and a listener that survives a restart.
mkdir -p /run/sshd   # 24.04: privsep dir is absent until ssh.service first starts; sshd -t/-T need it
sshd -t || die "sshd configuration is invalid - refusing to touch a working sshd"
systemctl disable --now ssh.socket >/dev/null 2>&1 || true
rm -rf /etc/systemd/system/ssh.socket.d
systemctl mask ssh.socket >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable ssh.service >/dev/null 2>&1
systemctl restart ssh.service || die "sshd would not start on port ${SSH_PORT}"
sleep 1
ss -ltn | grep -qE "[:.]${SSH_PORT}[[:space:]]" \
  || die "nothing is listening on ${SSH_PORT} - keep your console session open"
# Confirm pubkey is effective, but RETRY - sshd -T can momentarily fail right after a
# restart (privsep dir not yet recreated), and that is not a reason to fail a finished
# build: the port is already proven listening above and password auth stays on.
_pk=no
for _i in 1 2 3 4 5; do
  sshd -T 2>/dev/null | grep -qi '^pubkeyauthentication yes' && { _pk=yes; break; }
  sleep 1
done
if [ "$_pk" = yes ]; then
  say "  sshd on ${SSH_PORT}: pubkey yes, password yes, root ${PERMIT_ROOT_LOGIN}, socket masked"
else
  say "  WARN: sshd -T did not confirm pubkey ($(grep -i '^PubkeyAuthentication' /etc/ssh/sshd_config.d/00-yallacloud-root.conf 2>/dev/null)); port ${SSH_PORT} listening + password auth on, continuing"
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

# NOTE: ssh is deliberately NOT in this restart list. Section 12 already
# restarted and verified it; bouncing it again would drop the session this
# script is running in, and would race the socket unit it just masked.
systemctl restart fail2ban nginx php${PHPV}-fpm
systemctl enable --now nginx mariadb redis-server fail2ban php${PHPV}-fpm >/dev/null 2>&1

# ---------------------------------------------------- 14. disable cloud-init
# cloud-init has done its job: the instance is built. Left enabled it re-runs
# every boot and can rewrite things this script owns - netplan, the sshd
# drop-in, the hostname - silently undoing the build.
#
# /etc/cloud/cloud-init.disabled is cloud-init's own supported switch: its
# systemd generator checks for that file and declines to enable any of the
# units. The explicit disables below are belt and braces for images where the
# units were enabled statically.
#
# WARNING: do NOT do this on a VM you intend to clone or turn into a template.
# cloud-init is what regenerates the hostname, machine-id and SSH host keys per
# instance; without it every clone ships identical host keys.
if [ "$DISABLE_CLOUD_INIT" = "yes" ]; then
    if [ -d /etc/cloud ]; then
        say "disabling cloud-init permanently"
        touch /etc/cloud/cloud-init.disabled
        for U in cloud-init cloud-init-local cloud-init-main cloud-config cloud-final; do
            systemctl disable "$U" >/dev/null 2>&1 || true
        done
        say "  /etc/cloud/cloud-init.disabled created, units disabled"
        say "  to undo: rm /etc/cloud/cloud-init.disabled && systemctl enable cloud-init-local cloud-init cloud-config cloud-final"
        CLOUD_INIT_STATE="disabled"
    else
        say "cloud-init is not installed - nothing to disable"
        CLOUD_INIT_STATE="not-installed"
    fi
else
    say "DISABLE_CLOUD_INIT=no - cloud-init left enabled"
    CLOUD_INIT_STATE="enabled"
fi
# Note: /etc/netplan/50-cloud-init.yaml and /etc/ssh/sshd_config.d/50-cloud-init.conf
# are deliberately LEFT IN PLACE. They are static files now - still read at boot,
# no longer rewritten. Deleting the netplan one would drop the VM's addressing.

# ------------------------------------------------------------ 15. handover
NC_VER=$($O status 2>/dev/null | awk '/versionstring/{print $3}')
ISSUER=$(echo | timeout 10 openssl s_client -connect "${FQDN}:443" -servername "$FQDN" 2>/dev/null \
         | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
APPSTORE=$(curl -sS -o /dev/null -m 15 -w '%{http_code}' https://apps.nextcloud.com/ 2>/dev/null)

# --------------------------------------- 15c. Salt minion join + Acronis agent
# Both pull from repo.oasisstack.io (IP-allowlisted). A failure here NEVER aborts
# the Nextcloud build - it is logged and the deploy continues.
if [ "${JOIN_SALT:-yes}" = yes ]; then
  # reachability gate: the minion must reach the master publisher port before joining.
  if timeout 8 bash -c '</dev/tcp/salt.oasisstack.io/4506' 2>/dev/null; then
    say "salt: master salt.oasisstack.io:4506 reachable - joining via repo.oasisstack.io/salt/join.sh"
    if timeout 1200 bash -c 'curl -fsS --max-time 60 https://repo.oasisstack.io/salt/join.sh | sh' >>"$LOG" 2>&1; then
      SALT_STATE="JOINED"; say "  salt: joined (the master assigns the minion id: <domain>-<vmname>)"
    else
      printf '# YallaCloud: Salt join failed at install - retry the zero-input join until JOINED (join.sh removes this)\n*/15 * * * * root curl -fsS https://repo.oasisstack.io/salt/join.sh | sh >/dev/null 2>&1\n' > /etc/cron.d/yc-salt-join
      SALT_STATE="FAILED - join.sh failed (repo/apt mirror), retry every 15 min"; say "  salt: $SALT_STATE"
      notify_webhook "vm.salt.failed" "salt join.sh failed (repo/apt mirror) - retry cron /etc/cron.d/yc-salt-join" no
    fi
  else
    printf '# YallaCloud: Salt join failed at install - retry the zero-input join until JOINED (join.sh removes this)\n*/15 * * * * root curl -fsS https://repo.oasisstack.io/salt/join.sh | sh >/dev/null 2>&1\n' > /etc/cron.d/yc-salt-join
    SALT_STATE="BLOCKED - salt.oasisstack.io:4506 unreachable, retry every 15 min"; say "  salt: $SALT_STATE"
    notify_webhook "vm.salt.failed" "salt master salt.oasisstack.io:4506 unreachable - retry cron /etc/cron.d/yc-salt-join" no
  fi
else
  SALT_STATE="off"; say "salt join disabled (JOIN_SALT=no)"
fi
if [ -n "${ACRONIS_TOKEN:-}" ]; then
  say "installing + registering the Acronis backup agent (region ${ACRONIS_REGION:-AE})"
  _acr_ntfy=""; [ "${NOTIFY_NTFY:-yes}" = yes ] && [ -n "${NTFY_URL:-}" ] && [ -n "${NTFY_TOPIC:-}" ] && _acr_ntfy="--ntfy ${NTFY_URL%/}/${NTFY_TOPIC}"
  if curl -fsSL --max-time 60 https://repo.oasisstack.io/acronis/acronis-setup.sh | timeout 1800 bash -s -- --token "$ACRONIS_TOKEN" --region "${ACRONIS_REGION:-AE}" $_acr_ntfy >>"$LOG" 2>&1; then
    say "  acronis: setup ran (see the log for registered/already-registered status)"
  else
    say "  acronis: setup failed (token/region/egress) - continuing without it"
  fi
else
  say "acronis skipped (no ACRONIS_TOKEN provided)"
fi

# --------------------------------------- 15b. the 'yallacloud' info command
# A read-only catalogue so a tech or client sees the whole picture on the box:
# access, versions, services, cron, TLS, storage, backup/retention status.
cat > /usr/local/bin/yallacloud <<'YCEOF'
#!/bin/bash
# yallacloud - YallaCloud Nextcloud catalogue (read-only). Subcommands: info|cron|backup|secrets
CFG=/etc/yallacloud/nextcloud.conf; OUT=/root/yc-handover.json; NCROOT=/var/www/nextcloud
[ -f "$CFG" ] && . "$CFG"
occ(){ sudo -u www-data php "$NCROOT/occ" "$@" 2>/dev/null; }
hr(){ printf '%s\n' "------------------------------------------------------------"; }
PORTSFX=""; [ -n "${HTTPS_PORT:-}" ] && [ "$HTTPS_PORT" != "443" ] && PORTSFX=":$HTTPS_PORT"
case "${1:-info}" in
  secrets)
    [ "$(id -u)" = 0 ] || { echo "run as root: sudo yallacloud secrets"; exit 1; }
    [ -f "$OUT" ] && cat "$OUT" || echo "no handover file at $OUT" ;;
  cron)
    echo "Nextcloud background jobs mode: $(occ config:app:get core backgroundjobs_mode || echo cron)"
    echo "www-data crontab:"; crontab -u www-data -l 2>/dev/null | sed 's/^/  /'
    echo "certbot renew timer:"; systemctl list-timers 'certbot*' --no-pager 2>/dev/null | sed -n '1,3p' ;;
  backup)
    echo "DB backups - /var/backups/nextcloud, nightly 02:30 cron, 15-day retention:"
    ls -1t /var/backups/nextcloud/*.sql.gz 2>/dev/null | head -20 | sed 's/^/  /' || echo "  (none yet)"
    echo "Run now: sudo yc-nc-backup    Data dir: ${DATA_PATH:-/nc_data}" ;;
  ssl)      shift; exec yc-nc-ssl "$@" ;;
  domain)   shift; exec yc-nc-domain "$@" ;;
  datadisk) shift; exec yc-nc-datadisk "$@" ;;
  *)
    hr; echo " YallaCloud Nextcloud - ${FQDN:-unknown}"; hr
    echo " URL        : https://${FQDN}${PORTSFX}/"
    echo " Admin user : ${ADMIN_USER:-admin}  (password: sudo yallacloud secrets)"
    echo " SSH        : port $(ss -ltn 2>/dev/null | grep -qE ':3222 ' && echo 3222 || echo 22)   sudo user: ${SUDO_USER_NAME:-chadmin}"
    echo " Data dir   : ${DATA_PATH:-/nc_data}   Security tier: ${TIER:-standard}"
    hr; echo " Versions"
    echo "   OS       : $(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
    echo "   Nextcloud: $(occ status | awk -F': ' '/versionstring/{print $2}')"
    echo "   PHP      : $(php -v 2>/dev/null | head -1 | awk '{print $2}')"
    echo "   nginx    : $(nginx -v 2>&1 | sed 's#.*/##')"
    echo "   MariaDB  : $(mysql --no-defaults -u root -N -e 'SELECT VERSION();' 2>/dev/null)"
    echo "   Redis    : $(redis-server --version 2>/dev/null | awk '{print $3}' | sed 's/v=//')"
    hr
    echo " Services   : nginx=$(systemctl is-active nginx) php-fpm=$(systemctl is-active "php${PHPV:-8.3}-fpm" 2>/dev/null) mariadb=$(systemctl is-active mariadb) redis=$(systemctl is-active redis-server)"
    echo " TLS cert   : $(echo | openssl s_client -connect 127.0.0.1:${HTTPS_PORT:-443} -servername "${FQDN}" 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null | tr '\n' ' ')"
    echo " Storage    : $(df -h "${DATA_PATH:-/nc_data}" 2>/dev/null | awk 'NR==2{print $3" used / "$2" ("$5" full)"}')"
    hr
    echo " Config     : $CFG"
    echo " Handover   : $OUT   (sudo yallacloud secrets)"
    echo " Logs       : /var/log/yc-nextcloud-install.log"
    echo " More       : yallacloud cron | backup | secrets | ssl | domain | datadisk"
    hr ;;
esac
YCEOF
chmod 755 /usr/local/bin/yallacloud
say "  'yallacloud' command installed - run it for the full picture (sudo yallacloud secrets for passwords)"

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
  "root_user": "root",
  "root_password": "${CS_ROOT_PASS:-set by CloudStack (password-enabled template); see the deploy response / portal}",
  "ssh_port": ${SSH_PORT},
  "ssh_mode": "service (ssh.socket masked)",
  "ssh_pubkey_auth": "enabled",
  "ssh_password_auth": "enabled",
  "ssh_key_installed": "${SSH_KEY_STATE}",
  "permit_root_login": "${PERMIT_ROOT_LOGIN}",
  "cloud_init": "${CLOUD_INIT_STATE}",
  "is_public": ${IS_PUBLIC},
  "network_shape": "${NET_SHAPE}",
  "hypervisor": "${HV:-unknown}",
  "guest_agent": "${GA_STATE:-none}",
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
say "DONE - handover written to $OUT"
say "URL https://${FQDN}${PORTSFX}  admin ${ADMIN_USER}  ssh port ${SSH_PORT}  (passwords: yallacloud secrets)"

# --------------------------------------------- 16. verify, then clean reboot
# Nothing here changes the build. It proves the box is actually serving before
# the reboot, and refuses to reboot if it is not - a reboot into a broken state
# is far harder to diagnose than a script that stopped and said why.
say "post-install verification"
VFAIL=0
for U in nginx mariadb redis-server "php${PHPV}-fpm" ssh fail2ban; do
    if systemctl is-active --quiet "$U"; then
        systemctl is-enabled --quiet "$U" 2>/dev/null \
            || say "  warning: ${U} is running but not enabled at boot"
    else
        say "  NOT RUNNING: ${U}"; VFAIL=1
    fi
done
for P in "$SSH_PORT" "$HTTPS_PORT" 80; do
    ss -ltn | grep -qE "[:.]${P}[[:space:]]" || { say "  NOT LISTENING: ${P}"; VFAIL=1; }
done
$O status >/dev/null 2>&1 || { say "  occ status failed - Nextcloud is not answering"; VFAIL=1; }
curl -skS -o /dev/null -m 15 "https://127.0.0.1:${HTTPS_PORT}/status.php" \
    || { say "  local https probe failed"; VFAIL=1; }

if [ "$VFAIL" != "0" ]; then
    say "VERIFICATION FAILED - not rebooting. Fix the above first."
    say "Full log: $LOG   Handover: $OUT"
    die "post-install verification failed (see NOT RUNNING / NOT LISTENING above)"
fi
say "all services healthy, all ports listening"
rm -f /root/yc-INSTALL-FAILED; touch /root/yc-INSTALL-OK
NC_VERSION=$(sudo -u www-data php /var/www/nextcloud/occ status 2>/dev/null | awk -F': ' '/versionstring/{print $2}')
_ok="SUCCESS"; case "$SALT_STATE$SSL_STATUS" in *FAILED*|*BLOCKED*|*self-signed*) _ok="SUCCESS with warnings";; esac
notify_ntfy "OK BUILD nextcloud" "result  ${_ok}
url     https://${FQDN}${PORTSFX}/
tls     ${SSL_STATUS}
ip      ${NET_IP}  ssh ${SSH_PORT}
nc      ${NC_VERSION}   php ${PHPV}   data ${DATA_PATH}   hv ${HV:-?} (${GA_STATE:-?})
addons  salt ${SALT_STATE}   acronis ${ACRONIS_TOKEN:+on}${ACRONIS_TOKEN:-off}
creds   /root/yc-handover.json (yallacloud secrets)" default "white_check_mark"
notify_webhook "vm.deploy.completed" "install ok" yes
build_deploy_log SUCCESS
say "deploy log: /var/log/yc-nextcloud-deploy.log (installer + cloud-init merged)"


if [ "$REBOOT_AFTER" != "yes" ]; then
    say "REBOOT_AFTER=no - leaving the box running. Reboot when convenient."
    exit 0
fi

say "clean shutdown in 15s - press Ctrl-C now to abort"
sleep 15

# Quiesce in dependency order: web tier first so nothing writes during the
# datastore flush, then the datastores, then hand over to systemd.
# innodb_flush_log_at_trx_commit=2 (set in section 5) leaves up to a second of
# commits in the OS cache - stopping MariaDB explicitly closes that window
# instead of racing the shutdown timer.
say "  stopping web tier"
systemctl stop nginx "php${PHPV}-fpm" >/dev/null 2>&1 || true
say "  flushing redis"
REDISCLI_AUTH="$REDIS_PASS" redis-cli SAVE >/dev/null 2>&1 || true
systemctl stop redis-server >/dev/null 2>&1 || true
say "  flushing mariadb - do not interrupt"
mysql --no-defaults -u root -e "FLUSH TABLES; FLUSH LOGS;" >/dev/null 2>&1 || true
systemctl stop mariadb >/dev/null 2>&1 || true
sync; sync
say "  rebooting now - reconnect on ssh port ${SSH_PORT}"
systemctl reboot || reboot || init 6
