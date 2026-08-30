#!/bin/bash
# yc-stage-version.sh - stage the current GitHub payload into a versioned folder,
# in both /root and /yc-primary, and repoint scripts-latest at it.
#
#   ./yc-stage-version.sh v266
#
# Runtime scripts only, straight from GitHub, hash-verified, subfolders intact.
# Big binaries stay in /yc-primary/goldenstuff; yc-build-tree.sh joins them up.
set -euo pipefail
VER="${1:-}"
[ -n "$VER" ] || { echo "usage: yc-stage-version.sh vNNN" >&2; exit 1; }
Z=https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip
H=https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256

T=$(mktemp -d /root/.ycver.XXXX); trap 'rm -rf "$T"' EXIT
curl -fsSL -o "$T/p.zip" "$Z"
WANT=$(curl -fsSL "$H" | grep -oE '[0-9a-fA-F]{64}' | head -1)
GOT=$(sha256sum "$T/p.zip" | cut -d' ' -f1)
[ "${WANT,,}" = "${GOT,,}" ] || { echo "SHA MISMATCH want=$WANT got=$GOT" >&2; exit 1; }
echo "payload sha verified ${GOT:0:16}..."

unzip -q -o "$T/p.zip" -d "$T/tree"
printf '%s\n' "${GOT^^}" > "$T/tree/.payload-sha256"
NF=$(find "$T/tree" -type f | wc -l); ND=$(find "$T/tree" -mindepth 1 -type d | wc -l)
cat > "$T/tree/VERSION.txt" <<TXT
YallaCloud C:\\Scripts runtime payload
version        : $VER
source         : https://github.com/yallacloud/yc-scripts (main)
payload sha256 : ${GOT^^}
files          : $NF
subfolders     : $ND
staged         : $(date '+%Y-%m-%d %H:%M:%S %Z')
staged by      : yc-stage-version.sh on $(hostname)

Runtime script set ONLY, hash-verified against GitHub. No big binaries
(/yc-primary/goldenstuff) and no seal tooling. yc-build-tree.sh combines
all three into /root/yc-scripts-tree.tar for injection.
TXT

for D in "/root/scripts-$VER" "/yc-primary/scripts-$VER"; do
  rm -rf "$D"; mkdir -p "$D"
  cp -a "$T/tree/." "$D/"
  cp -a "$T/p.zip" "$D/YallaCloud-CScripts-$VER.zip"
  printf '%s  %s\n' "${GOT^^}" "YallaCloud-CScripts-$VER.zip" > "$D/YallaCloud-CScripts-$VER.zip.sha256"
  ln -sfn "$D" "$(dirname "$D")/scripts-latest"
  echo "  staged $D ($(find "$D" -type f|wc -l) files, $(find "$D" -mindepth 1 -type d|wc -l) dirs)"
done
diff -r "/root/scripts-$VER" "/yc-primary/scripts-$VER" >/dev/null && echo "  both copies identical"
