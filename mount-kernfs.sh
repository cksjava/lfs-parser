#!/usr/bin/env bash
# Mount virtual kernel filesystems on $LFS (book §7.3). Used by build_lfs.py before chroot sessions.
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"

mount_efivars_in_chroot() {
  if [[ ! -d /sys/firmware/efi/efivars ]] || ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
    return 0
  fi
  mkdir -p "$LFS/sys/firmware/efi/efivars"
  if ! mountpoint -q "$LFS/sys/firmware/efi/efivars" 2>/dev/null; then
    mount --bind /sys/firmware/efi/efivars "$LFS/sys/firmware/efi/efivars"
  fi
}

if mountpoint -q "$LFS/proc" 2>/dev/null; then
  mount_efivars_in_chroot
  echo "Virtual kernel filesystems already mounted under $LFS"
  exit 0
fi

mkdir -pv "$LFS"/{dev,proc,sys,run}

mount -v --bind /dev "$LFS/dev"

mount -vt devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
mount -vt proc proc "$LFS/proc"
mount -vt sysfs sysfs "$LFS/sys"
mount -vt tmpfs tmpfs "$LFS/run"

mount_efivars_in_chroot

if [[ -h "$LFS/dev/shm" ]]; then
  install -v -d -m 1777 "$LFS$(realpath /dev/shm)"
else
  mount -vt tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
fi

echo "Virtual kernel filesystems mounted under $LFS"
