#!/bin/bash
# yc-sync-node.sh - make every local copy on this node match yallacloud/yc-scripts.
# Stale copies on the build node are how a fixed script keeps shipping broken. Run before sealing.
set -uo pipefail
RAW=https://raw.githubusercontent.com/yallacloud/yc-scripts/main
N=0; F=0
get(){ # get <repo-path> <local-path> [mode]
  local url="$RAW/$1" dst="$2" mode="${3:-644}" tmp
  tmp=$(mktemp)
  if curl -fsSL --max-time 120 -o "$tmp" "$url"; then
    if [ -s "$tmp" ]; then
      if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then printf "  same    %s\n" "$dst"
      else install -m "$mode" "$tmp" "$dst"; printf "  UPDATED %s\n" "$dst"; fi
      N=$((N+1)); rm -f "$tmp"; return 0
    fi
  fi
  printf "  FAILED  %s\n" "$dst"; F=$((F+1)); rm -f "$tmp"; return 1
}

echo "=== node scripts"
for f in yc-seal-loop.sh yc-template-update.sh build-payload.sh yc-build-tree.sh yc-inject.sh yc-stage-version.sh; do
  get "$f" "/root/$f" 755
done

echo "=== payload + sidecar (reference copy, nothing serves it - the guests fetch from GitHub)"
mkdir -p /root/payload-ref
get YallaCloud-CScripts-latest.zip    /root/payload-ref/YallaCloud-CScripts-latest.zip
get YallaCloud-CScripts-latest.sha256 /root/payload-ref/YallaCloud-CScripts-latest.sha256

echo "=== Update-YcScripts bootstrap (yc-template-update.sh scp-s this one)"
mkdir -p /root/scripts-v265
get Update-YcScripts.ps1 /root/scripts-v265/Update-YcScripts.ps1

echo "=== seal tooling cache"
mkdir -p /root/.sealcache
for t in AppX-Strip.ps1 Clean-Scripts.ps1 Enable-VirtioBoot.ps1 Fix-DiagTools.ps1 \
         Fix-PreSeal.ps1 gi-settings.ps1 Install-YcPayload.ps1 Install-YcTasks.ps1 \
         PreSeal-Agents.ps1 Seal-Manual.ps1 yc-check.ps1 yc-folders.ps1 yc-id.ps1 doseal.cmd; do
  get "seal/$t" "/root/.sealcache/$t"
done

echo
echo "  synced: $N   failed: $F"
[ -d /root/kit-v262 ] && echo "  NOTE: /root/kit-v262 is the RETIRED kit - yc-template-update.sh pulls seal/ from GitHub now."
exit $F
