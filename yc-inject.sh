#!/bin/bash
# yc-inject.sh - put C:\Scripts into a Windows disk image. ONE command.
#
#   ./yc-inject.sh /path/to/disk.qcow2
#   ./yc-inject.sh -n /path/to/disk.qcow2     dry run, show what it would do
#
# It attaches the disk, finds the Windows partition itself, replaces C:\Scripts
# from the prebuilt tree, and detaches. The detach happens in a trap, so it runs
# even if something fails halfway - which is what used to leave nbd devices
# attached and a disk you must not boot.
set -euo pipefail

TREE=/root/yc-scripts-tree.tar
DRY=0
[ "${1:-}" = "-n" ] && { DRY=1; shift; }
DISK="${1:-}"

say(){ printf "  %s\n" "$*"; }
die(){ printf "ERROR: %s\n" "$*" >&2; exit 1; }

[ -n "$DISK" ]   || die "usage: yc-inject.sh [-n] <disk.qcow2>"
[ -f "$DISK" ]   || die "no such disk: $DISK"
[ -f "$TREE" ]   || die "no tree at $TREE - run ./yc-build-tree.sh first"
[ "$(id -u)" = 0 ] || die "must be root"

NBD=""; MNT=""
cleanup(){
  set +e
  [ -n "$MNT" ] && { sync; umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null; }
  if [ -n "$NBD" ]; then
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
    sleep 2
    if [ "$(cat /sys/block/$(basename "$NBD")/size 2>/dev/null || echo 0)" != "0" ]; then
      printf "WARNING: %s may still be attached. Check with: lsblk | grep nbd\n" "$NBD" >&2
    else
      say "detached $NBD"
    fi
  fi
}
trap cleanup EXIT

modprobe nbd max_part=16 2>/dev/null || true

# Pick a free nbd device instead of making the operator track a number.
for i in $(seq 0 15); do
  d="/dev/nbd$i"
  [ -e "$d" ] || continue
  if [ "$(cat /sys/block/nbd$i/size 2>/dev/null || echo 0)" = "0" ]; then NBD="$d"; break; fi
done
[ -n "$NBD" ] || die "no free /dev/nbdN - something is still attached. lsblk | grep nbd"
say "using $NBD"

qemu-nbd --connect="$NBD" "$DISK" || die "qemu-nbd could not attach $DISK"
sleep 3
partprobe "$NBD" 2>/dev/null || true

# The Windows volume is the largest NTFS partition. Finding it beats asking the
# operator to guess p1/p2/p3, which changes between BIOS and EFI images.
PART=$(lsblk -rno NAME,FSTYPE,SIZE "$NBD" 2>/dev/null \
       | awk '$2=="ntfs"{print $3, $1}' | sort -hr | head -1 | awk '{print "/dev/"$2}')
[ -n "$PART" ] || die "no NTFS partition found on $DISK - is this a Windows disk?"
say "windows partition: $PART"

MNT=$(mktemp -d /mnt/ycinj.XXXXXX)
# A dry run must not be able to dirty the volume, so mount it read-only.
MOPT=(); [ "$DRY" = 1 ] && MOPT=(-o ro)
mount "${MOPT[@]}" "$PART" "$MNT" || die "could not mount $PART (dirty volume? try: ntfsfix $PART)"
[ -d "$MNT/Windows" ] || die "$PART has no \\Windows - wrong partition"

BEFORE=$(find "$MNT/Scripts" -type f 2>/dev/null | wc -l)
say "C:\\Scripts before: $BEFORE file(s)"

if [ "$DRY" = 1 ]; then
  echo; echo "DRY RUN - nothing changed."
  echo "  would wipe : $MNT/Scripts ($BEFORE files)"
  echo "  would write: $(tar -tf "$TREE" | grep -c . ) entries from $TREE"
  exit 0
fi

NEED=$(( $(stat -c %s "$TREE") / 1024 ))
HAVE=$(( $(df -Pk "$MNT" | awk 'NR==2{print $4}') + $(du -sk "$MNT/Scripts" 2>/dev/null | cut -f1 || echo 0) ))
say "space: need ~$((NEED/1024)) MiB, have $((HAVE/1024)) MiB"
[ "$HAVE" -gt "$((NEED + 262144))" ] \
  || die "not enough free space on $PART (need ~$((NEED/1024)) MiB + 256 MiB headroom, have $((HAVE/1024)) MiB). Nothing was changed."

rm -rf "$MNT/Scripts"
mkdir -p "$MNT/Scripts"
tar -xf "$TREE" -C "$MNT/Scripts" \
  || die "extract failed after C:\\Scripts was already wiped - DO NOT BOOT THIS DISK. Free space and re-run."

AFTER=$(find "$MNT/Scripts" -type f | wc -l)
[ "$AFTER" -gt 20 ] || die "only $AFTER files landed - extract failed, DO NOT BOOT THIS DISK"

# The one file that decides whether the VM can ever update itself.
[ -f "$MNT/Scripts/Update-YcScripts.ps1" ] \
  && say "Update-YcScripts.ps1 present - this image can self-update" \
  || printf "WARNING: Update-YcScripts.ps1 is NOT in the tree. Every VM from this image keeps a frozen payload.\n" >&2

echo
echo "INJECTED  $DISK"
echo "  C:\\Scripts : $BEFORE -> $AFTER files"
