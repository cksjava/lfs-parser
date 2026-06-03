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
    /bin/bash --login "$ITERATOR" "$CHROOT_SESSION"
