#!/usr/bin/env bash
set -euo pipefail
# BLFS extra — Popt-1.19 (efibootmgr dependency)
# Source: blfs-extra/popt-1.19 (static script, not from LFS book)
# Stage: stage-06-system-config (System configuration (Chapters 9–10))
# Session: chroot

# Executed inside the build session assigned by build_lfs.py

# --- LFS build tracking ---
_LFS_STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LFS_SCRIPTS_ROOT="$(cd "$_LFS_STAGE_DIR/.." && pwd)"
source "${LFS_SCRIPTS_DIR:-$_LFS_SCRIPTS_ROOT}/lfs-build-lib.sh"
lfs_script_begin \
  "stage-06-system-config/0122-01-popt.sh" \
  "BLFS: Popt-1.19 (UEFI GRUB dependency)" \
  "blfs-extra/popt-1.19" \
  "10" \
  "stage-06-system-config" \
  "chroot" \
  "popt-1.19"

if [[ "${LFS_GRUB_MODE:-bios}" != efi ]]; then
  echo "Skip: LFS_GRUB_MODE is not efi (efibootmgr not needed)."
  lfs_script_finish success
  exit 0
fi

cd "${LFS_SOURCES:-$LFS/sources}"
pkg="popt-1.19.tar.gz"
dir=$(lfs_tarball_topdir "$pkg")
rm -rf "$dir"
lfs_extract_archive "$pkg"
cd "$dir"

./configure --prefix=/usr --disable-static
make
make install

cd "${LFS_SOURCES:-$LFS/sources}"
rm -rf "$dir"

lfs_script_finish success
