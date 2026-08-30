#!/bin/bash
# yc-build-tree.sh - assemble the C:\Scripts tree ONCE into a single tar.
#
# LAYERING, and it matters:
#   1. RUNTIME SCRIPTS come from GitHub, always. yallacloud/yc-scripts is the single
#      source of truth. Local script folders are NOT read - four copies of the same
#      script in four places is what produced every defect we spent this week fixing.
#   2. BIG BINARIES come from /yc-primary/goldenstuff, because installers and drivers
#      are too large for git and never change on their own.
#   3. SEAL TOOLING comes from /root/goldenscript/v262 and is only needed on the BUILD
#      VM. doseal.cmd deletes it at seal time so it never reaches a customer.
#
#   ./yc-build-tree.sh             build /root/yc-scripts-tree.tar
#   ./yc-build-tree.sh -o FILE     build somewhere else
#   ./yc-build-tree.sh --no-seal   runtime + binaries only (for re-injecting a live image)
set -euo pipefail

OUT=/root/yc-scripts-tree.tar
WANT_SEAL=1
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    --no-seal) WANT_SEAL=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

ZIPURL=https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip
SHAURL=https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256
SEAL=/root/goldenscript/v262
GOLD=/yc-primary/goldenstuff
PAY=/root/ycpayload/out

STAGE=$(mktemp -d /root/.yctree.XXXXXX)
cleanup(){ rm -rf "$STAGE"; }
trap cleanup EXIT

say(){ printf "  %s\n" "$*"; }
die(){ printf "ERROR: %s\n" "$*" >&2; exit 1; }

# ---- 1. runtime scripts: GitHub, hash-verified. Non-negotiable. -----------------
say "runtime scripts <- github.com/yallacloud/yc-scripts"
curl -fsSL -o "$STAGE/.p.zip" "$ZIPURL" || die "could not fetch the payload from GitHub"
WANT=$(curl -fsSL "$SHAURL" | grep -oE "[0-9a-fA-F]{64}" | head -1) || die "could not fetch the sidecar"
GOT=$(sha256sum "$STAGE/.p.zip" | cut -d" " -f1)
[ "${WANT,,}" = "${GOT,,}" ] || die "payload SHA mismatch. want=$WANT got=$GOT"
say "  sha256 verified ${GOT:0:12}..."
unzip -q -o "$STAGE/.p.zip" -d "$STAGE" || die "could not unzip the payload"
rm -f "$STAGE/.p.zip"
RUNTIME=$(find "$STAGE" -type f | wc -l)
say "  $RUNTIME runtime file(s)"
[ -f "$STAGE/Update-YcScripts.ps1" ] || die "the payload has no Update-YcScripts.ps1 - refusing to build a tree that can never self-update"

# ---- 2. big binaries: local, because they cannot live in git --------------------
[ -d "$GOLD" ] || die "missing $GOLD"
say "big binaries    <- $GOLD"
mkdir -p "$STAGE/DiagTools"
find "$GOLD/agents" "$GOLD/runtime" \
     "$GOLD/tools/iiscrypto" "$GOLD/tools/putty" "$GOLD/tools/winscp" \
     "$GOLD/tools/sysinternals" "$GOLD/drivers/qemu-ga" \
     -type f -exec cp -n {} "$STAGE"/ \; 2>/dev/null || true
cp -n "$GOLD"/drivers/virtio/iso/*        "$STAGE"/ 2>/dev/null || true
cp -n "$GOLD"/drivers/vmware/installers/* "$STAGE"/ 2>/dev/null || true
cp -rn "$GOLD"/tools/DiagTools/*          "$STAGE/DiagTools/" 2>/dev/null || true

ZIP=$(ls -1t "$PAY"/ycpayload-v*.zip 2>/dev/null | head -1) || true
if [ -n "${ZIP:-}" ]; then
  say "  + $(basename "$ZIP")"
  cp -n "$ZIP" "$STAGE"/ 2>/dev/null || true
  cp -n "$ZIP.sha256" "$STAGE"/ 2>/dev/null || true
fi

# ---- 3. seal tooling: build VM only, deleted by doseal.cmd ----------------------
if [ "$WANT_SEAL" = 1 ]; then
  [ -d "$SEAL" ] || die "missing $SEAL"
  say "seal tooling    <- $SEAL  (doseal.cmd removes this at seal time)"
  # An ALLOW-LIST, not *.ps1. A glob copied A-Z-Deploy.ps1, Setup-HealthMonitors.ps1 and
  # Setup-YallaCloudExtras.ps1 straight back into C:\Scripts - three of the files the v265
  # audit deleted from the payload. The glob silently undid the deletion on every build.
  # -n so the GitHub copies still win over a stale local file of the same name.
  # GitHub first, the local kit only as a fallback. Three local copies of these files
  # drifted apart and produced most of the 2026-08-30 defects, so the repo owns them now.
  # Unattend-Seal.xml is NOT in this list: it ships in the payload, and the payload copy
  # is canonical. -n so the payload always wins over anything fetched here.
  SEALRAW=https://raw.githubusercontent.com/yallacloud/yc-scripts/main/seal
  GOTGH=0; USEDLOCAL=0
  for t in AppX-Strip.ps1 Clean-Scripts.ps1 Enable-VirtioBoot.ps1 Fix-DiagTools.ps1 \
           Fix-PreSeal.ps1 gi-settings.ps1 GoldenImage.ps1 Install-YcPayload.ps1 \
           Install-YcTasks.ps1 PreSeal-Agents.ps1 Seal-Manual.ps1 yc-check.ps1 \
           yc-folders.ps1 yc-id.ps1 doseal.cmd; do
    if curl -fsSL --max-time 60 -o "$STAGE/.seal.tmp" "$SEALRAW/$t" && [ -s "$STAGE/.seal.tmp" ]; then
      [ -e "$STAGE/$t" ] || mv "$STAGE/.seal.tmp" "$STAGE/$t"
      rm -f "$STAGE/.seal.tmp"
      GOTGH=$((GOTGH+1))
    elif [ -f "$SEAL/$t" ]; then
      rm -f "$STAGE/.seal.tmp"
      cp -n "$SEAL/$t" "$STAGE"/ 2>/dev/null || true
      USEDLOCAL=$((USEDLOCAL+1))
    else
      die "seal tooling $t is in neither GitHub nor $SEAL"
    fi
  done
  say "  $GOTGH from github, $USEDLOCAL from the local kit"
  [ "$USEDLOCAL" = 0 ] || say "  WARNING: $USEDLOCAL file(s) came from the local kit - GitHub was unreachable for those."
  G=$(grep -c "SkipRearm>0<" "$STAGE/Unattend-Seal.xml" 2>/dev/null || echo 0)
  [ "$G" = "1" ] || die "Unattend-Seal.xml does not have SkipRearm=0 - refusing to build. Fix $SEAL/Unattend-Seal.xml"
  say "  SkipRearm=0 confirmed"
else
  say "seal tooling    <- SKIPPED (--no-seal)"
fi

# MANIFEST.json is a real check now, not decoration. It sat stale for a whole payload
# generation with 130 of 175 entries pointing at paths that no longer existed, and nothing
# ever read it. Every entry marked shipped must be in the tree we just staged.
if [ -f "$STAGE/MANIFEST.json" ]; then
  MISSING=$(python3 - "$STAGE" <<'PYEOF'
import json,os,sys
stage=sys.argv[1]
try: mem=json.load(open(os.path.join(stage,'MANIFEST.json')))['members']
except Exception as e: print('MANIFEST-UNREADABLE:'+str(e)); raise SystemExit
# The tree is flat apart from DiagTools\, and install_to carries Windows paths, so
# normalise the separator and look the basename up anywhere under the stage.
have=set()
for dp,_,fns in os.walk(stage):
    for fn in fns: have.add(fn.lower())
def landed(e):
    t=(e.get('install_to') or e.get('target') or '').replace('\\','/')
    b=os.path.basename(t)
    return bool(b) and b.lower() in have
bad=[e['name'] for e in mem if e.get('shipped',True) and not landed(e)]
print(' '.join(sorted(set(bad))))
PYEOF
)
  if [ -n "$MISSING" ]; then
    say "  MANIFEST: not in the tree -> $MISSING"
  else
    say "  MANIFEST: every shipped entry is present"
  fi
fi

N=$(find "$STAGE" -type f | wc -l)
SZ=$(du -sh "$STAGE" | cut -f1)
[ "$N" -gt 100 ] || die "only $N files staged - a source is empty, refusing to build a broken tree"

# Stamp what we actually baked in. Yc-AutoUpdate reads this on first boot and stays
# quiet when it already matches GitHub, instead of re-downloading what we just injected.
printf "%s\n" "${GOT^^}" > "$STAGE/.payload-sha256"

tar -cf "$OUT" -C "$STAGE" .
printf "%s  %s\n" "$(sha256sum "$OUT" | cut -d" " -f1)" "$(basename "$OUT")" > "$OUT.sha256"

echo
echo "BUILT $OUT"
echo "  runtime (github): $RUNTIME"
echo "  total files     : $N"
echo "  size            : $SZ"
echo "  payload sha     : ${GOT:0:16}..."
echo
echo "Now:  ./yc-inject.sh <disk.qcow2>"
