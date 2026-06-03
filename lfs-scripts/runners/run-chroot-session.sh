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
ITERATOR="$RUNNER_DIR/iterate-session.sh"
CHROOT_SESSION=chroot
JOBS="${MAKEFLAGS:--j$(nproc 2>/dev/null || echo 1)}"
JOBS="${JOBS#-j}"

if [[ ! -d "$LFS/usr" ]]; then
  echo "Chroot target $LFS does not look like an LFS system tree." >&2
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
    /bin/bash --login "$ITERATOR" "$CHROOT_SESSION"
