#!/usr/bin/env bash
# Download LFS 13.0-systemd sources (single packages tarball) before the build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sources-lib.sh
source "$ROOT/sources-lib.sh"

BOOK_DIR="${LFS_BOOK_DIR:-$ROOT/13.0}"

# Stable book: all packages in one tarball (Chapter 3.1, mirrors.html#files)
LFS_PACKAGES_NAME="${LFS_PACKAGES_NAME:-lfs-packages-13.0.tar}"
LFS_PACKAGES_URLS=(
  "${LFS_PACKAGES_URL:-}"
  "https://ftp.ludd.ltu.se/mirrors/lfs/lfs-packages/${LFS_PACKAGES_NAME}"
  "https://mirror.koddos.net/lfs/lfs-packages/${LFS_PACKAGES_NAME}"
  "https://ftp.wrz.de/pub/LFS/lfs-packages/${LFS_PACKAGES_NAME}"
  "https://mirror.download.it/lfs/pub/lfs-packages/${LFS_PACKAGES_NAME}"
)

AXEL_CONNECTIONS="${AXEL_CONNECTIONS:-100}"
HOST_SOURCES="$(host_sources_dir)"
DOWNLOAD_DIR="${LFS_DOWNLOAD_DIR:-$HOST_SOURCES}"

usage() {
  cat <<EOF
Usage: $0 [options]

Download the LFS 13.0-systemd all-packages tarball, extract into the host
staging directory, verify md5sums, and optionally sync to \$LFS/sources when
the LFS partition is mounted.

Host staging (download + extract):
  ${HOST_SOURCES}
  (override with LFS_HOST_SOURCES)

LFS target (copy only when \$LFS is a mount point):
  $(lfs_target_sources_dir)
  (override with LFS and LFS_SOURCES)

Environment:
  LFS_HOST_SOURCES Host staging dir (default: ~/sources)
  LFS              LFS mount point (default: /mnt/lfs)
  LFS_SOURCES      Target on LFS disk (default: \$LFS/sources)
  LFS_DOWNLOAD_DIR Where to store the .tar while downloading (default: host staging)
  LFS_PACKAGES_URL Override mirror URL for ${LFS_PACKAGES_NAME}
  AXEL_CONNECTIONS Parallel connections for axel (default: 100)
  LFS_BOOK_DIR     Book tree for md5sums (default: $ROOT/13.0)
  LFS_BOOK_VERSION Top-level dir name inside tarball to flatten (default: 13.0)

Options:
  -h, --help       Show this help
  --skip-md5       Do not run md5sum -c after extract
  --sync-only      Only sync host staging -> \$LFS/sources (requires mount)
  --no-sync        Do not attempt sync after download/extract
EOF
}

SKIP_MD5=0
SYNC_ONLY=0
NO_SYNC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --skip-md5) SKIP_MD5=1; shift ;;
    --sync-only) SYNC_ONLY=1; shift ;;
    --no-sync) NO_SYNC=1; shift ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "$SYNC_ONLY" -eq 1 ]]; then
  sync_host_sources_to_lfs "$HOST_SOURCES" "$(lfs_mount_default)" "$(lfs_target_sources_dir)"
  exit $?
fi

if ! command -v axel >/dev/null 2>&1; then
  echo "axel not found. Run: sudo ./lfs prepare" >&2
  exit 1
fi

mkdir -p "$HOST_SOURCES" "$DOWNLOAD_DIR"
chmod -v a+wt "$HOST_SOURCES" 2>/dev/null || true

if [[ -x "$ROOT/download-blfs-extra.sh" ]]; then
  echo ""
  echo "Downloading BLFS extra packages (UEFI GRUB dependencies) ..."
  bash "$ROOT/download-blfs-extra.sh"
fi

archive="$DOWNLOAD_DIR/$LFS_PACKAGES_NAME"

if [[ -f "$archive" ]]; then
  echo "Using existing archive: $archive"
else
  picked_url=""
  for url in "${LFS_PACKAGES_URLS[@]}"; do
    [[ -z "$url" ]] && continue
    echo "Trying: $url"
    if axel -n "$AXEL_CONNECTIONS" -a -o "$archive" "$url"; then
      picked_url="$url"
      break
    fi
    rm -f "$archive" "${archive}.st"
  done
  if [[ -z "$picked_url" ]]; then
    echo "Failed to download ${LFS_PACKAGES_NAME} from configured mirrors." >&2
    echo "See https://www.linuxfromscratch.org/mirrors.html#files" >&2
    exit 1
  fi
  echo "Downloaded from: $picked_url"
fi

echo "Extracting into $HOST_SOURCES ..."
tar -xf "$archive" -C "$HOST_SOURCES"
flatten_sources_dir "$HOST_SOURCES"

md5_file="$BOOK_DIR/md5sums"
if [[ "$SKIP_MD5" -eq 0 && -f "$md5_file" ]]; then
  cp -f "$md5_file" "$HOST_SOURCES/md5sums"
  echo "Verifying checksums (md5sums from book) ..."
  (
    cd "$HOST_SOURCES"
    md5sum -c md5sums
  )
else
  echo "Skipped md5 verification (missing $md5_file or --skip-md5)"
fi

echo ""
echo "Sources ready on host: $HOST_SOURCES"

if [[ "$NO_SYNC" -eq 0 ]]; then
  if mountpoint -q "$(lfs_mount_default)" 2>/dev/null; then
    sync_host_sources_to_lfs "$HOST_SOURCES" "$(lfs_mount_default)" "$(lfs_target_sources_dir)" || true
  else
    echo ""
    echo "LFS is not mounted at $(lfs_mount_default)."
    echo "After you mount the LFS partition there, run:"
    echo "  ./lfs download --sync-only"
    echo "  (or ./lfs build will sync before phases that need \$LFS/sources)"
  fi
fi

echo ""
echo "Next: mount \$LFS if needed, sync sources, then sudo ./lfs build"
