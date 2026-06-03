#!/usr/bin/env bash
# Chapters 2–4 host bootstrap: host check, download, disk, mount, sources, layout, lfs user.
# Called by build_lfs.py (root). Idempotent where safe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sources-lib.sh
source "$ROOT/sources-lib.sh"

LFS="${LFS:-/mnt/lfs}"
LFS_PARTITION="${LFS_PARTITION:?LFS_PARTITION must be set (e.g. /dev/sdb2)}"
LFS_FILESYSTEM_TYPE="${LFS_FILESYSTEM_TYPE:-ext4}"
LFS_SWAP_PARTITION="${LFS_SWAP_PARTITION:-}"
LFS_USER="${LFS_USER:-lfs}"
LFS_GROUP="${LFS_GROUP:-lfs}"
LFS_USER_PASSWORD="${LFS_USER_PASSWORD:-lfs}"
LFS_BOOTSTRAP_MKFS="${LFS_BOOTSTRAP_MKFS:-1}"

VERSION_CHECK="$ROOT/version-check.sh"
PREPARE_HOST="$ROOT/prepare-host.sh"
DOWNLOAD_SOURCES="$ROOT/download-sources.sh"

log_step() {
  echo ""
  echo "=== Bootstrap: $1 ==="
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "bootstrap-lfs.sh must run as root." >&2
    exit 1
  fi
}

ensure_host_ready() {
  log_step "host version check"
  if [[ ! -x "$VERSION_CHECK" ]]; then
    echo "Missing $VERSION_CHECK" >&2
    exit 1
  fi
  local vc_log
  vc_log="$(mktemp)"
  set +e
  bash "$VERSION_CHECK" 2>&1 | tee "$vc_log"
  local check_status=${PIPESTATUS[0]}
  set -e
  if grep -q '^ERROR:' "$vc_log"; then
    check_status=1
  fi
  rm -f "$vc_log"

  if [[ "$check_status" -ne 0 ]]; then
    echo "Version check failed; running prepare-host.sh ..."
    bash "$PREPARE_HOST"
    bash "$VERSION_CHECK" || {
      echo "Host still not suitable after prepare-host.sh." >&2
      exit 1
    }
  fi
}

ensure_sources_downloaded() {
  log_step "download sources"
  if [[ ! -x "$DOWNLOAD_SOURCES" ]]; then
    echo "Missing $DOWNLOAD_SOURCES" >&2
    exit 1
  fi
  bash "$DOWNLOAD_SOURCES" --no-sync
}

ensure_filesystem() {
  if [[ "$LFS_BOOTSTRAP_MKFS" != "1" ]]; then
    echo "Skipping mkfs (LFS_BOOTSTRAP_MKFS=$LFS_BOOTSTRAP_MKFS)"
    return 0
  fi
  log_step "format and mount"
  if [[ ! -b "$LFS_PARTITION" ]]; then
    echo "LFS partition is not a block device: $LFS_PARTITION" >&2
    exit 1
  fi
  echo "Creating $LFS_FILESYSTEM_TYPE filesystem on $LFS_PARTITION ..."
  mkfs -v -t "$LFS_FILESYSTEM_TYPE" "$LFS_PARTITION"

  if [[ -n "$LFS_SWAP_PARTITION" ]]; then
    if [[ ! -b "$LFS_SWAP_PARTITION" ]]; then
      echo "Swap partition is not a block device: $LFS_SWAP_PARTITION" >&2
      exit 1
    fi
    echo "Initializing swap on $LFS_SWAP_PARTITION ..."
    mkswap "$LFS_SWAP_PARTITION"
  fi
}

ensure_mounted() {
  if mountpoint -q "$LFS" 2>/dev/null; then
    echo "$LFS is already mounted"
  else
    mkdir -pv "$LFS"
    echo "Mounting $LFS_PARTITION on $LFS ..."
    mount -v -t "$LFS_FILESYSTEM_TYPE" "$LFS_PARTITION" "$LFS"
  fi

  chown root:root "$LFS"
  chmod 755 "$LFS"

  if [[ -n "$LFS_SWAP_PARTITION" ]]; then
    if swapon --show | grep -qF "$LFS_SWAP_PARTITION"; then
      echo "Swap $LFS_SWAP_PARTITION already enabled"
    else
      /sbin/swapon -v "$LFS_SWAP_PARTITION"
    fi
  fi
}

ensure_lfs_sources_dir() {
  log_step "LFS sources directory"
  mkdir -pv "$LFS/sources"
  chmod -v a+wt "$LFS/sources"
}

ensure_sources_synced() {
  log_step "sync sources"
  local host
  host="$(host_sources_dir)"
  sync_host_sources_to_lfs "$host" "$LFS" "$(lfs_target_sources_dir)"
}

ensure_directory_layout() {
  log_step "directory layout"
  mkdir -pv "$LFS"/{etc,var} "$LFS"/usr/{bin,lib,sbin}

  for i in bin lib sbin; do
    if [[ ! -e "$LFS/$i" ]]; then
      ln -sv "usr/$i" "$LFS/$i"
    fi
  done

  case "$(uname -m)" in
    x86_64)
      mkdir -pv "$LFS/lib64"
      ;;
  esac

  mkdir -pv "$LFS/tools"
}

ensure_lfs_user() {
  log_step "LFS user"
  if ! getent group "$LFS_GROUP" >/dev/null; then
    groupadd "$LFS_GROUP"
  else
    echo "Group $LFS_GROUP already exists"
  fi

  if ! id -u "$LFS_USER" >/dev/null 2>&1; then
    useradd -s /bin/bash -g "$LFS_GROUP" -m -k /dev/null "$LFS_USER"
  else
    echo "User $LFS_USER already exists"
  fi

  echo "${LFS_USER}:${LFS_USER_PASSWORD}" | chpasswd

  chown -v "$LFS_USER" "$LFS"/{usr{,/*},var,etc,tools}
  case "$(uname -m)" in
    x86_64) chown -v "$LFS_USER" "$LFS/lib64" ;;
  esac
}

ensure_host_bashrc_moved() {
  log_step "host bash.bashrc (book §4.4)"
  if [[ -e /etc/bash.bashrc && ! -e /etc/bash.bashrc.NOUSE ]]; then
    mv -v /etc/bash.bashrc /etc/bash.bashrc.NOUSE
  else
    echo "/etc/bash.bashrc already moved or absent"
  fi
}

main() {
  require_root
  export LFS
  export LFS_SOURCES="${LFS_SOURCES:-$LFS/sources}"

  ensure_host_ready
  ensure_sources_downloaded
  ensure_filesystem
  ensure_mounted
  ensure_lfs_sources_dir
  ensure_sources_synced
  ensure_directory_layout
  ensure_lfs_user
  ensure_host_bashrc_moved

  echo ""
  echo "=== Bootstrap complete ==="
}

main "$@"
