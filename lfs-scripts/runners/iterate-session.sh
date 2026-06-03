#!/usr/bin/env bash
# Generic session iterator: run every *.sh in sessions/<name>/ in sorted order.
# Usage: iterate-session.sh <lfs|chroot>
set -euo pipefail

SESSION="${1:?usage: iterate-session.sh <lfs|chroot>}"
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$RUNNER_DIR/../manifest.json" ]]; then
  SCRIPTS_DIR="$(cd "$RUNNER_DIR/.." && pwd)"
elif [[ -n "${LFS_SCRIPTS:-}" && -f "${LFS_SCRIPTS}/manifest.json" ]]; then
  SCRIPTS_DIR="$LFS_SCRIPTS"
else
  SCRIPTS_DIR="$(cd "$RUNNER_DIR/.." && pwd)"
fi

SESSION_DIR="$SCRIPTS_DIR/sessions/$SESSION"
LOG="${LFS_BUILD_LOG:-$SCRIPTS_DIR/logs/build-${SESSION}.log}"
mkdir -p "$(dirname "$LOG")"

if [[ ! -d "$SESSION_DIR" ]]; then
  echo "Session directory not found: $SESSION_DIR" >&2
  echo "Run: npm run extract" >&2
  exit 1
fi

shopt -s nullglob
mapfile -t scripts < <(find "$SESSION_DIR" -maxdepth 1 -name '*.sh' -print | sort)

if (("${#scripts[@]}" == 0)); then
  echo "No scripts in $SESSION_DIR" >&2
  exit 1
fi

echo "Session: $SESSION (${#scripts[@]} script(s))"
echo "Log: $LOG"

for script in "${scripts[@]}"; do
  real="${script}"
  if command -v readlink &>/dev/null; then
    real="$(readlink -f "$script" 2>/dev/null || echo "$script")"
  fi
  {
    echo ""
    echo "======== $(date -Iseconds 2>/dev/null || date) ========"
    echo "Running: $(basename "$script")"
    grep '^# ' "$real" 2>/dev/null | head -8 || true
  } | tee -a "$LOG"
  # shellcheck source=/dev/null
  source "$real"
done

echo "" | tee -a "$LOG"
echo "Session $SESSION finished successfully." | tee -a "$LOG"
