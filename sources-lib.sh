#!/usr/bin/env bash
# Shared helpers: host staging dir, flatten tarball layout, sync to $LFS/sources.
set -euo pipefail

# Where packages are downloaded and extracted on the build host (not on the LFS disk).
host_sources_dir() {
  echo "${LFS_HOST_SOURCES:-$HOME/sources}"
}

lfs_mount_default() {
  echo "${LFS:-/mnt/lfs}"
}

lfs_target_sources_dir() {
  local lfs
  lfs="$(lfs_mount_default)"
  echo "${LFS_SOURCES:-$lfs/sources}"
}

# Move a single top-level directory (e.g. 13.0/) up into the sources root.
flatten_sources_dir() {
  local dest="$1"
  local book_ver="${LFS_BOOK_VERSION:-13.0}"
  local nested="$dest/$book_ver"

  if [[ -d "$nested" ]]; then
    echo "Flattening $nested into $dest"
    shopt -s dotglob
    mv "$nested"/* "$dest"/
    shopt -u dotglob
    rmdir "$nested" 2>/dev/null || true
    return 0
  fi

  local top count files
  top="$(find "$dest" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  count="$(find "$dest" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  files="$(find "$dest" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | head -1)"
  if [[ -n "$top" && "$count" == "1" && -z "$files" ]]; then
    echo "Flattening $top into $dest"
    shopt -s dotglob
    mv "$top"/* "$dest"/
    shopt -u dotglob
    rmdir "$top" 2>/dev/null || true
  fi
}

# Copy host staging sources into $LFS/sources when the LFS root is mounted.
sync_host_sources_to_lfs() {
  local host_src="${1:-$(host_sources_dir)}"
  local lfs="${2:-$(lfs_mount_default)}"
  local target="${3:-$(lfs_target_sources_dir)}"

  if ! mountpoint -q "$lfs" 2>/dev/null; then
    echo "LFS partition is not mounted at $lfs; sources remain in $host_src"
    echo "Mount the LFS partition, then run: ./lfs download --sync-only"
    return 1
  fi

  if [[ ! -d "$host_src" ]] || [[ -z "$(ls -A "$host_src" 2>/dev/null)" ]]; then
    echo "No sources in $host_src to sync." >&2
    return 1
  fi

  mkdir -p "$target"
  chmod -v a+wt "$target" 2>/dev/null || true

  echo "Syncing sources from $host_src to $target ..."
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$host_src"/ "$target"/
  else
    cp -a "$host_src"/. "$target"/
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    chown root:root "$target"/* 2>/dev/null || true
  fi

  echo "Sources synced to $target"
  return 0
}
