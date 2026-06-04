#!/usr/bin/env bash
set -euo pipefail
# Run as root: chroot with book env, then source every chroot script in one login shell.
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$RUNNER_DIR/../manifest.json" ]]; then
  SCRIPTS_DIR="$(cd "$RUNNER_DIR/.." && pwd)"
elif [[ -n "${LFS_SCRIPTS:-}" && -f "${LFS_SCRIPTS}/manifest.json" ]]; then
  SCRIPTS_DIR="$LFS_SCRIPTS"
else
  SCRIPTS_DIR="$(cd "$RUNNER_DIR/.." && pwd)"
fi

LFS="${LFS:-/mnt/lfs}"
CHROOT_SCRIPTS="/tmp/lfs-scripts"
ITERATOR="$CHROOT_SCRIPTS/runners/iterate-session.sh"
CHROOT_SESSION=chroot
JOBS="${MAKEFLAGS:--j$(nproc 2>/dev/null || echo 1)}"
JOBS="${JOBS#-j}"

if [[ ! -d "$LFS/usr" ]]; then
  echo "Chroot target $LFS does not look like an LFS system tree." >&2
  exit 1
fi

if [[ ! -x "$LFS/tmp/lfs-scripts/runners/iterate-session.sh" ]]; then
  echo "Synced scripts tree missing under $LFS/tmp/lfs-scripts" >&2
  exit 1
fi

export LFS
echo "Starting chroot session at $LFS ..."
chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-linux}" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    MAKEFLAGS="-j$JOBS" \
    TESTSUITEFLAGS="-j$JOBS" \
    LFS_SOURCES=/sources \
    LFS_SCRIPTS="$CHROOT_SCRIPTS" \
    LFS_GROFF_PAPER_SIZE="${LFS_GROFF_PAPER_SIZE:-A4}" \
    LFS_PARTITION="${LFS_PARTITION:-/dev/sdb2}" \
    LFS_GRUB_INSTALL_DEVICE="${LFS_GRUB_INSTALL_DEVICE:-/dev/sdb}" \
    LFS_GRUB_SET_ROOT="${LFS_GRUB_SET_ROOT:-(hd1,2)}" \
    LFS_GRUB_MODE="${LFS_GRUB_MODE:-bios}" \
    LFS_GRUB_TARGET="${LFS_GRUB_TARGET:-i386-pc}" \
    LFS_ESP_PARTITION="${LFS_ESP_PARTITION:-}" \
    LFS_HOSTNAME="${LFS_HOSTNAME:-lfs}" \
    LFS_RELEASE_VERSION="${LFS_RELEASE_VERSION:-13.0-systemd}" \
    LFS_RELEASE_CODENAME="${LFS_RELEASE_CODENAME:-lfs}" \
    LFS_NETWORK_MODE="${LFS_NETWORK_MODE:-dhcp}" \
    LFS_NETWORK_MATCH="${LFS_NETWORK_MATCH:-Name=en* eth* wl*}" \
    LFS_NETWORK_ADDRESS="${LFS_NETWORK_ADDRESS:-}" \
    LFS_NETWORK_GATEWAY="${LFS_NETWORK_GATEWAY:-}" \
    LFS_NETWORK_DNS="${LFS_NETWORK_DNS:-8.8.8.8}" \
    LFS_NETWORK_DNS2="${LFS_NETWORK_DNS2:-}" \
    LFS_NETWORK_DOMAIN="${LFS_NETWORK_DOMAIN:-}" \
    LFS_TIMEZONE="${LFS_TIMEZONE:-UTC}" \
    LFS_LOCALE="${LFS_LOCALE:-en_US.UTF-8}" \
    LFS_KEYMAP="${LFS_KEYMAP:-us}" \
    LFS_CONSOLE_FONT="${LFS_CONSOLE_FONT:-Lat2-Terminus16}" \
    LFS_HWCLOCK_LOCAL="${LFS_HWCLOCK_LOCAL:-0}" \
    /bin/bash --login "$ITERATOR" "$CHROOT_SESSION"
