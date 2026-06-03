#!/usr/bin/env bash
set -euo pipefail
# BLFS extra — efivar-39 (efibootmgr dependency)
# Source: blfs-extra/efivar-39 (static script, not from LFS book)
# Stage: stage-06-system-config (System configuration (Chapters 9–10))
# Session: chroot

# Executed inside the build session assigned by build_lfs.py

# --- LFS build tracking ---
_LFS_STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LFS_SCRIPTS_ROOT="$(cd "$_LFS_STAGE_DIR/.." && pwd)"
source "${LFS_SCRIPTS_DIR:-$_LFS_SCRIPTS_ROOT}/lfs-build-lib.sh"
lfs_script_begin \
  "stage-06-system-config/0122-02-efivar.sh" \
  "BLFS: efivar-39 (UEFI GRUB dependency)" \
  "blfs-extra/efivar-39" \
  "10" \
  "stage-06-system-config" \
  "chroot" \
  "efivar-39"

if [[ "${LFS_GRUB_MODE:-bios}" != efi ]]; then
  echo "Skip: LFS_GRUB_MODE is not efi (efibootmgr not needed)."
  lfs_script_finish success
  exit 0
fi

_patch="${LFS_SCRIPTS_DIR:-$_LFS_SCRIPTS_ROOT}/blfs-extra/patches/efivar-39-upstream_fixes-1.patch"
if [[ ! -f "$_patch" ]]; then
  echo "Missing patch: $_patch" >&2
  exit 1
fi

cd "${LFS_SOURCES:-$LFS/sources}"
pkg="efivar-39.tar.gz"
dir=$(lfs_tarball_topdir "$pkg")
rm -rf "$dir"
lfs_extract_archive "$pkg"
cd "$dir"

patch -Np1 -i "$_patch"
make ENABLE_DOCS=0
make install ENABLE_DOCS=0 LIBDIR=/usr/lib
install -vm644 docs/efivar.1 /usr/share/man/man1
install -vm644 docs/*.3 /usr/share/man/man3

cd "${LFS_SOURCES:-$LFS/sources}"
rm -rf "$dir"

lfs_script_finish success
