#!/usr/bin/env bash
# Prepare a Debian/Ubuntu host for LFS and run Chapter 2.2 version-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_CHECK="$ROOT/version-check.sh"

if [[ ! -f "$VERSION_CHECK" ]]; then
  echo "Missing $VERSION_CHECK" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "prepare-host: run as root (sudo $0)" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "prepare-host: apt-get not found (Debian/Ubuntu only)" >&2
  exit 1
fi

echo "=== Installing LFS host build dependencies (Debian/Ubuntu) ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  axel \
  bc \
  bison \
  build-essential \
  bzip2 \
  ca-certificates \
  file \
  flex \
  gawk \
  gperf \
  gzip \
  m4 \
  patch \
  perl \
  python3 \
  tar \
  texinfo \
  wget \
  xz-utils

echo ""
echo "=== Host symlinks required by the LFS book ==="

if [[ ! -e /bin/bash ]]; then
  echo "ERROR: /bin/bash is missing" >&2
  exit 1
fi

if [[ ! -L /bin/sh ]] || [[ "$(readlink -f /bin/sh)" != "$(readlink -f /bin/bash)" ]]; then
  ln -sf bash /bin/sh
  echo "Set /bin/sh -> bash"
else
  echo "/bin/sh already points to bash"
fi

if command -v gawk >/dev/null 2>&1; then
  ln -sf gawk /usr/bin/awk
  echo "Set /usr/bin/awk -> gawk"
fi

if command -v bison >/dev/null 2>&1; then
  if [[ -e /usr/bin/yacc ]] && [[ ! -L /usr/bin/yacc ]]; then
    echo "WARNING: /usr/bin/yacc exists and is not a symlink; leaving it unchanged"
  else
    ln -sf bison /usr/bin/yacc
    echo "Set /usr/bin/yacc -> bison"
  fi
fi

if ! command -v axel >/dev/null 2>&1; then
  echo "ERROR: axel is still not available after install" >&2
  exit 1
fi

echo ""
echo "=== Running version-check.sh (LFS Chapter 2.2) ==="
chmod +x "$VERSION_CHECK"
vc_log="$(mktemp)"
set +e
bash "$VERSION_CHECK" 2>&1 | tee "$vc_log"
check_status=${PIPESTATUS[0]}
set -e

if grep -q '^ERROR:' "$vc_log"; then
  check_status=1
fi
rm -f "$vc_log"

if [[ "$check_status" -ne 0 ]]; then
  echo ""
  echo "Host version check reported errors. Fix the issues above before building LFS." >&2
  exit 1
fi

echo ""
echo "Host is ready for LFS (packages installed, symlinks set, version check passed)."
echo "Next: ./lfs download   # fetch lfs-packages-13.0.tar into ~/sources (sync to \$LFS/sources when mounted)"
echo "Then:  ./lfs build      # run the build orchestrator (as root)"
