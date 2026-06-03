#!/usr/bin/env bash
# Unmount LFS virtual kernel filesystems, then $LFS (book §7.13.2 / §11.3).
# Idempotent: skips mount points that are not active. Run as root before restarting a failed build.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$ROOT/lfs-build-config.json"

usage() {
  cat <<EOF
Usage: $0 [options]

Unmount virtual filesystems under \$LFS, then \$LFS itself, then optional swap.

Order (LFS 13.0-systemd):
  \$LFS/dev/pts, \$LFS/dev/shm (if mounted), \$LFS/dev, \$LFS/run,
  \$LFS/proc, \$LFS/sys, \$LFS/home (if mounted), \$LFS

Environment:
  LFS              LFS mount point (default: /mnt/lfs, or lfs-build-config.json)
  LFS_SWAP_PARTITION  Swap device to swapoff (optional)

Options:
  -h, --help       Show this help
  --lazy           Use umount -l if a normal umount fails (busy mount)
EOF
}

load_config_mount() {
  if [[ -n "${LFS:-}" ]]; then
    return 0
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    LFS="/mnt/lfs"
    return 0
  fi
  LFS="$(python3 -c "
import json
from pathlib import Path
p = Path('$CONFIG_FILE')
if p.exists():
    d = json.loads(p.read_text())
    print(d.get('lfs_mount', '/mnt/lfs'))
else:
    print('/mnt/lfs')
" 2>/dev/null || echo "/mnt/lfs")"
}

load_config_swap() {
  if [[ -n "${LFS_SWAP_PARTITION:-}" ]]; then
    return 0
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    return 0
  fi
  LFS_SWAP_PARTITION="$(python3 -c "
import json
from pathlib import Path
p = Path('$CONFIG_FILE')
if p.exists():
    d = json.loads(p.read_text())
    print(d.get('swap_partition', '') or '')
" 2>/dev/null || true)"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "$0: run as root (sudo $0)" >&2
    exit 1
  fi
}

USE_LAZY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --lazy) USE_LAZY=1; shift ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

require_root
load_config_mount
load_config_swap

LFS="${LFS:-/mnt/lfs}"

umount_if_mounted() {
  local target="$1"
  if ! mountpoint -q "$target" 2>/dev/null; then
    return 0
  fi
  echo "Unmounting $target ..."
  if umount -v "$target"; then
    return 0
  fi
  if [[ "$USE_LAZY" -eq 1 ]]; then
    echo "Retrying lazy unmount: $target" >&2
    umount -lv "$target" || return 1
    return 0
  fi
  echo "Failed to unmount $target (device busy?). Try: $0 --lazy" >&2
  return 1
}

echo "=== Unmounting LFS filesystems at $LFS ==="

failed=0
for target in \
  "$LFS/boot/efi" \
  "$LFS/boot" \
  "$LFS/dev/pts" \
  "$LFS/dev/shm" \
  "$LFS/dev" \
  "$LFS/run" \
  "$LFS/proc" \
  "$LFS/sys/firmware/efi/efivars" \
  "$LFS/sys" \
  "$LFS/home" \
  "$LFS"
do
  umount_if_mounted "$target" || failed=1
done

if [[ -n "${LFS_SWAP_PARTITION:-}" ]]; then
  if swapon --show 2>/dev/null | grep -qF "$LFS_SWAP_PARTITION"; then
    echo "Disabling swap on $LFS_SWAP_PARTITION ..."
    swapoff "$LFS_SWAP_PARTITION" || failed=1
  fi
fi

if [[ "$failed" -ne 0 ]]; then
  echo ""
  echo "Some unmounts failed. Stop processes using \$LFS (including chroot shells), then retry." >&2
  exit 1
fi

echo ""
echo "LFS filesystems unmounted."
