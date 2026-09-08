#!/bin/bash
# Export the eight SEALED vCenter VMs to OVA for CloudStack registration.
# Mirrors section 9 of "Actual Template Making Guide kvm-vcenter v263".
# The vCenter password is read from /root/govc-yc.env and URL-encoded in-process;
# it is never echoed and never appears in a log line.
set -u
OUT=/yc-primary/FINAL_OVA_V265
VER=v265
set -a; . /root/govc-yc.env; set +a
VCHOST=$(printf '%s' "$GOVC_URL" | sed -E 's#^https?://##; s#/sdk$##')
PW=$(python3 -c "import os,urllib.parse;print(urllib.parse.quote(os.environ['GOVC_PASSWORD'],safe=''))")
USER=$(python3 -c "import os,urllib.parse;print(urllib.parse.quote(os.environ['GOVC_USERNAME'],safe=''))")

# VM name -> template name
map(){ case "$1" in
  V16B) echo VC-WS2016-BIOS-$VER;; V16E) echo VC-WS2016-EFI-$VER;;
  V19B) echo VC-WS2019-BIOS-$VER;; V19E) echo VC-WS2019-EFI-$VER;;
  V22B) echo VC-WS2022-BIOS-$VER;; V22E) echo VC-WS2022-EFI-$VER;;
  V25B) echo VC-WS2025-BIOS-$VER;; V25E) echo VC-WS2025-EFI-$VER;;
esac; }

for vm in "$@"; do
  T=$(map "$vm")
  [ -n "$T" ] || { echo "unknown vm $vm"; continue; }
  echo "=================== $vm -> $T.ova   $(date +%H:%M:%S)"
  rm -f "$OUT/$T.ova"
  ovftool --acceptAllEulas --noSSLVerify --powerOffSource=false \
    "vi://$USER:$PW@$VCHOST/DXBYALLACLOUD/vm/$vm" \
    "$OUT/$T.ova" 2>&1 | sed -E "s#vi://[^@]*@#vi://***@#g" | tail -6
  if [ -s "$OUT/$T.ova" ]; then
    echo "  OK  $(ls -lh "$OUT/$T.ova" | awk '{print $5}')  $(date +%H:%M:%S)"
  else
    echo "  FAILED - no output file"
  fi
done
echo "=================== done $(date +%H:%M:%S)"
ls -lh "$OUT"
