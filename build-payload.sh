#!/bin/bash
# Rebuild the payload zip + sha256 sidecar from a Scripts/ directory.
#   ./build-payload.sh /path/to/Scripts
# Keeps the filename fixed on purpose - the URL baked into every sealed template
# depends on it never changing.
set -euo pipefail
SRC="${1:?usage: build-payload.sh /path/to/Scripts}"
[ -d "$SRC" ] || { echo "not a directory: $SRC" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
ZIP="$HERE/YallaCloud-CScripts-latest.zip"
python3 - "$SRC" "$ZIP" <<'PY'
import sys, os, zipfile, hashlib
src, out = sys.argv[1], sys.argv[2]
if os.path.exists(out): os.remove(out)
z = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, allowZip64=False)
for dp, _, fns in os.walk(src):
    for fn in sorted(fns):
        p = os.path.join(dp, fn)
        # FLAT on purpose: Update-YcScripts.ps1 copies the extract ROOT into
        # C:\Scripts, so nesting under Scripts/ lands everything one level too deep.
        arc = os.path.relpath(p, src).replace(os.sep, '/')
        zi = zipfile.ZipInfo.from_file(p, arc)
        zi.create_system = 0            # mark as MS-DOS so Windows tools are happy
        zi.external_attr = 0x20         # FILE_ATTRIBUTE_ARCHIVE, no unix perms
        zi.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(zi, open(p, 'rb').read())
z.close()
print(out, os.path.getsize(out), 'bytes')
PY
sha256sum "$ZIP" | awk '{print toupper($1)"  YallaCloud-CScripts-latest.zip"}' > "$HERE/YallaCloud-CScripts-latest.sha256"
cat "$HERE/YallaCloud-CScripts-latest.sha256"
echo "Now: git commit -am 'payload $(date +%F)' && git push"
