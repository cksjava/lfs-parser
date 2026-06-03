#!/usr/bin/env bash
set -euo pipefail
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$RUNNER_DIR/../manifest.json" ]]; then
  SCRIPTS_DIR="$(cd "$RUNNER_DIR/.." && pwd)"
elif [[ -n "${LFS_SCRIPTS:-}" && -f "${LFS_SCRIPTS}/manifest.json" ]]; then
  SCRIPTS_DIR="$LFS_SCRIPTS"
else
  SCRIPTS_DIR="$(cd "$RUNNER_DIR/.." && pwd)"
fi
exec "$RUNNER_DIR/iterate-session.sh" lfs
