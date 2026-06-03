#!/usr/bin/env bash
# Download LFS 13.0-systemd sources (single packages tarball) before the build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
LFS="${LFS:-/mnt/lfs}"
SOURCES="${LFS_SOURCES:-$LFS/sources}"
DOWNLOAD_DIR="${LFS_DOWNLOAD_DIR:-$SOURCES}"

usage() {
  cat <<EOF
Usage: $0 [options]

Download the LFS 13.0-systemd all-packages tarball and unpack into sources.

Environment:
  LFS              LFS mount point (default: /mnt/lfs)
  LFS_SOURCES      Sources directory (default: \$LFS/sources)
  LFS_DOWNLOAD_DIR Where to store the .tar while downloading (default: sources dir)
  LFS_PACKAGES_URL Override mirror URL for ${LFS_PACKAGES_NAME}
  AXEL_CONNECTIONS Parallel connections for axel (default: 100)
  LFS_BOOK_DIR     Book tree for md5sums (default: $ROOT/13.0)

Options:
  -h, --help       Show this help
  --skip-md5       Do not run md5sum -c after extract
EOF
}

SKIP_MD5=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --skip-md5) SKIP_MD5=1; shift ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if ! command -v axel >/dev/null 2>&1; then
  echo "axel not found. Run: sudo ./lfs prepare" >&2
  exit 1
fi

mkdir -p "$SOURCES" "$DOWNLOAD_DIR"
chmod -v a+wt "$SOURCES" 2>/dev/null || true

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

echo "Extracting into $SOURCES ..."
tar -xf "$archive" -C "$SOURCES"

# Flatten if the tarball has a single top-level directory (e.g. 13.0/)
top="$(find "$SOURCES" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [[ -n "$top" ]] && [[ "$(find "$SOURCES" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]]; then
  if [[ -z "$(find "$SOURCES" -mindepth 1 -maxdepth 1 -type f | head -1)" ]]; then
    echo "Flattening $top into $SOURCES"
    shopt -s dotglob
    mv "$top"/* "$SOURCES"/
    shopt -u dotglob
    rmdir "$top" 2>/dev/null || true
  fi
fi

md5_file="$BOOK_DIR/md5sums"
if [[ "$SKIP_MD5" -eq 0 && -f "$md5_file" ]]; then
  cp -f "$md5_file" "$SOURCES/md5sums"
  echo "Verifying checksums (md5sums from book) ..."
  (
    cd "$SOURCES"
    md5sum -c md5sums
  )
else
  echo "Skipped md5 verification (missing $md5_file or --skip-md5)"
fi

if [[ "$(id -u)" -eq 0 ]]; then
  chown root:root "$SOURCES"/* 2>/dev/null || true
fi

echo ""
echo "Sources ready in $SOURCES"
echo "Next: sudo ./lfs build"
