#!/usr/bin/env bash
# Book §8.86 cleanup — run from the host in a fresh chroot after stripping, before Ch 9.
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "$0: run as root (sudo $0)" >&2
    exit 1
  fi
}

require_root

if [[ ! -d "$LFS/usr" ]]; then
  echo "LFS system tree not found at $LFS" >&2
  exit 1
fi

if ! mountpoint -q "$LFS/proc" 2>/dev/null; then
  echo "Virtual kernel filesystems must be mounted on $LFS (run build or mount-kernfs.sh)" >&2
  exit 1
fi

echo "=== Cleaning up LFS tree under $LFS (book §8.86) ==="

chroot "$LFS" /usr/bin/env -i \
  HOME=/root \
  PATH=/usr/bin:/usr/sbin \
  /bin/bash --noprofile --norc <<'EOF'
set -e
rm -rf /tmp/{*,.*}
find /usr/lib /usr/libexec -name \*.la -delete
find /usr -depth -name $(uname -m)-lfs-linux-gnu\* | xargs rm -rf
userdel -r tester
EOF

echo "Cleanup complete."
