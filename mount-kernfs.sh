#!/usr/bin/env bash
# Mount virtual kernel filesystems on $LFS (book §7.3). Used by build_lfs.py before chroot sessions.
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"

if mountpoint -q "$LFS/proc" 2>/dev/null; then
  echo "Virtual kernel filesystems already mounted under $LFS"
  exit 0
fi

mkdir -pv "$LFS"/{dev,proc,sys,run}

mount -v --bind /dev "$LFS/dev"

mount -vt devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
mount -vt proc proc "$LFS/proc"
mount -vt sysfs sysfs "$LFS/sys"
mount -vt tmpfs tmpfs "$LFS/run"

if [[ -h "$LFS/dev/shm" ]]; then
  install -v -d -m 1777 "$LFS$(realpath /dev/shm)"
else
  mount -vt tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
fi

echo "Virtual kernel filesystems mounted under $LFS"
