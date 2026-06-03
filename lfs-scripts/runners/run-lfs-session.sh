#!/usr/bin/env bash
set -euo pipefail
# Run as root: su - lfs with book §4.4 env, then source every lfs script in one login shell.
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$RUNNER_DIR/../manifest.json" ]]; then
  SCRIPTS_DIR="$(cd "$RUNNER_DIR/.." && pwd)"
elif [[ -n "${LFS_SCRIPTS:-}" && -f "${LFS_SCRIPTS}/manifest.json" ]]; then
  SCRIPTS_DIR="$LFS_SCRIPTS"
else
  SCRIPTS_DIR="$(cd "$RUNNER_DIR/.." && pwd)"
fi

LFS="${LFS:-/mnt/lfs}"
LFS_USER="${LFS_USER:-lfs}"
ITERATOR="$RUNNER_DIR/iterate-session.sh"
LFS_ENV="$RUNNER_DIR/lfs-user-env.sh"
LFS_SESSION=lfs

if ! id -u "$LFS_USER" &>/dev/null; then
  echo "LFS user '$LFS_USER' does not exist. Complete Chapter 4 first." >&2
  exit 1
fi

export LFS
echo "Starting LFS user session (su - $LFS_USER) ..."
exec su - "$LFS_USER" -c "source $LFS_ENV && exec bash --login $ITERATOR $LFS_SESSION"
