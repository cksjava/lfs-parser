#!/usr/bin/env bash
# Enter an interactive LFS chroot with virtual kernel filesystems mounted (book §7.3).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$ROOT/lfs-build-config.json"
MOUNT_KERNFS="$ROOT/mount-kernfs.sh"

usage() {
  cat <<EOF
Usage: $0 [options] [-- command [args...]]

Mount dev/proc/sys/run (and optional /boot, /boot/efi from fstab or config), then
start an interactive shell inside \$LFS. Reads lfs-build-config.json when present.

Options:
  --mount          Mount \$LFS_PARTITION on \$LFS when the root filesystem is not mounted
  -h, --help       Show this help

Environment (override config file):
  LFS                  LFS mount point (default: /mnt/lfs)
  LFS_PARTITION        Root block device (e.g. /dev/sdb2)
  LFS_FILESYSTEM_TYPE  Root filesystem type (default: ext4)
  LFS_ESP_PARTITION    EFI System Partition for /boot/efi (UEFI)

Examples:
  sudo $0
  sudo $0 --mount
  sudo $0 -- grub-install --version

See also: mount-kernfs.sh, unmount-lfs.sh, ./lfs unmount
EOF
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "$0: run as root (sudo $0)" >&2
    exit 1
  fi
}

load_build_config() {
  local py_out
  py_out="$(python3 - "$CONFIG_FILE" <<'PY'
import json
import shlex
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
defaults = {
    "lfs_mount": "/mnt/lfs",
    "lfs_partition": "/dev/sdb2",
    "filesystem_type": "ext4",
    "esp_partition": "",
    "grub_install_device": "/dev/sdb",
    "hostname": "lfs",
    "release_codename": "",
    "timezone": "UTC",
    "locale": "en_US.UTF-8",
    "keymap": "us",
    "console_font": "LatArC-16",
    "groff_paper_size": "A4",
    "jobs": 0,
}

data = {}
if config_path.is_file():
    data = json.loads(config_path.read_text(encoding="utf-8"))

merged = {**defaults, **data}

def emit(name: str, value) -> None:
    if value is None:
        value = ""
    print(f"{name}={shlex.quote(str(value))}")

emit("LFS", merged["lfs_mount"])
emit("LFS_PARTITION", merged["lfs_partition"])
emit("LFS_FILESYSTEM_TYPE", merged["filesystem_type"])
emit("LFS_ESP_PARTITION", merged.get("esp_partition") or "")
emit("LFS_GRUB_INSTALL_DEVICE", merged["grub_install_device"])
emit("LFS_HOSTNAME", merged["hostname"])
emit("LFS_RELEASE_CODENAME", merged.get("release_codename") or merged["hostname"])
emit("LFS_TIMEZONE", merged["timezone"])
emit("LFS_LOCALE", merged["locale"])
emit("LFS_KEYMAP", merged["keymap"])
emit("LFS_CONSOLE_FONT", merged["console_font"])
emit("LFS_GROFF_PAPER_SIZE", merged["groff_paper_size"])
emit("LFS_BUILD_JOBS", merged.get("jobs") or 0)
PY
)" || true

  if [[ -n "$py_out" ]]; then
    eval "$py_out"
  fi

  LFS="${LFS:-/mnt/lfs}"
  LFS_PARTITION="${LFS_PARTITION:-/dev/sdb2}"
  LFS_FILESYSTEM_TYPE="${LFS_FILESYSTEM_TYPE:-ext4}"
  LFS_ESP_PARTITION="${LFS_ESP_PARTITION:-}"
  LFS_GRUB_INSTALL_DEVICE="${LFS_GRUB_INSTALL_DEVICE:-/dev/sdb}"
  LFS_HOSTNAME="${LFS_HOSTNAME:-lfs}"
  LFS_RELEASE_CODENAME="${LFS_RELEASE_CODENAME:-$LFS_HOSTNAME}"
  LFS_TIMEZONE="${LFS_TIMEZONE:-UTC}"
  LFS_LOCALE="${LFS_LOCALE:-en_US.UTF-8}"
  LFS_KEYMAP="${LFS_KEYMAP:-us}"
  LFS_CONSOLE_FONT="${LFS_CONSOLE_FONT:-LatArC-16}"
  LFS_GROFF_PAPER_SIZE="${LFS_GROFF_PAPER_SIZE:-A4}"
  LFS_BUILD_JOBS="${LFS_BUILD_JOBS:-0}"
}

grub_set_root_from_partition() {
  local partition="$1"
  if [[ "$partition" =~ ^/dev/sd([a-z])([0-9]+)$ ]]; then
    local drive=$(( $(printf '%d' "'${BASH_REMATCH[1]}'") - $(printf '%d' "'a'") ))
    echo "(hd${drive},${BASH_REMATCH[2]})"
    return
  fi
  if [[ "$partition" =~ ^/dev/vd([a-z])([0-9]+)$ ]]; then
    local drive=$(( $(printf '%d' "'${BASH_REMATCH[1]}'") - $(printf '%d' "'a'") ))
    echo "(hd${drive},${BASH_REMATCH[2]})"
    return
  fi
  if [[ "$partition" =~ ^/dev/nvme([0-9]+)n([0-9]+)p([0-9]+)$ ]]; then
    echo "(hd${BASH_REMATCH[1]},${BASH_REMATCH[3]})"
    return
  fi
  echo "(hd1,2)"
}

ensure_root_mounted() {
  if mountpoint -q "$LFS" 2>/dev/null; then
    return 0
  fi
  if [[ "$DO_MOUNT" -ne 1 ]]; then
    echo "$LFS is not mounted. Re-run with --mount or mount $LFS_PARTITION on $LFS first." >&2
    exit 1
  fi
  if [[ ! -b "$LFS_PARTITION" ]]; then
    echo "LFS partition is not a block device: $LFS_PARTITION" >&2
    exit 1
  fi
  mkdir -pv "$LFS"
  echo "Mounting $LFS_PARTITION on $LFS ..."
  mount -v -t "$LFS_FILESYSTEM_TYPE" "$LFS_PARTITION" "$LFS"
}

mount_fstab_extras() {
  local fstab="$LFS/etc/fstab"
  [[ -f "$fstab" ]] || return 0

  while read -r dev mp fstype opts _rest; do
    [[ -z "${dev:-}" || "$dev" =~ ^# ]] && continue
    [[ -z "${mp:-}" || -z "${fstype:-}" ]] && continue
    [[ "$dev" == "none" ]] && continue
    case "$mp" in
      /|/proc|/sys|/dev|/run|/dev/pts|/dev/shm) continue ;;
    esac
    mkdir -p "$LFS$mp"
    if mountpoint -q "$LFS$mp" 2>/dev/null; then
      continue
    fi
    case "$dev" in
      UUID=*|LABEL=*|/dev/*)
        mount -t "$fstype" -o "$opts" "$dev" "$LFS$mp"
        ;;
    esac
  done < <(grep -v '^[[:space:]]*#' "$fstab" || true)
}

mount_esp_if_needed() {
  if [[ -z "$LFS_ESP_PARTITION" ]]; then
    return 0
  fi
  mkdir -p "$LFS/boot/efi"
  if mountpoint -q "$LFS/boot/efi" 2>/dev/null; then
    return 0
  fi
  if [[ ! -b "$LFS_ESP_PARTITION" ]]; then
    echo "Warning: LFS_ESP_PARTITION is not a block device: $LFS_ESP_PARTITION" >&2
    return 0
  fi
  echo "Mounting ESP $LFS_ESP_PARTITION on $LFS/boot/efi ..."
  mount -t vfat "$LFS_ESP_PARTITION" "$LFS/boot/efi"
}

chroot_env() {
  local jobs="${LFS_BUILD_JOBS:-0}"
  if [[ "$jobs" -eq 0 ]]; then
    jobs="$(nproc 2>/dev/null || echo 1)"
  fi

  LFS_GRUB_SET_ROOT="${LFS_GRUB_SET_ROOT:-$(grub_set_root_from_partition "$LFS_PARTITION")}"
  LFS_GRUB_MODE="${LFS_GRUB_MODE:-$([ -n "$LFS_ESP_PARTITION" ] && echo efi || echo bios)}"
  LFS_GRUB_TARGET="${LFS_GRUB_TARGET:-$([ "$LFS_GRUB_MODE" = efi ] && echo x86_64-efi || echo i386-pc)}"
  LFS_RELEASE_VERSION="${LFS_RELEASE_VERSION:-13.0-systemd}"

  export LFS
  chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-linux}" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    MAKEFLAGS="-j$jobs" \
    TESTSUITEFLAGS="-j$jobs" \
    LFS="$LFS" \
    LFS_SOURCES=/sources \
    LFS_GROFF_PAPER_SIZE="$LFS_GROFF_PAPER_SIZE" \
    LFS_PARTITION="$LFS_PARTITION" \
    LFS_GRUB_INSTALL_DEVICE="$LFS_GRUB_INSTALL_DEVICE" \
    LFS_GRUB_SET_ROOT="$LFS_GRUB_SET_ROOT" \
    LFS_GRUB_MODE="$LFS_GRUB_MODE" \
    LFS_GRUB_TARGET="$LFS_GRUB_TARGET" \
    LFS_ESP_PARTITION="$LFS_ESP_PARTITION" \
    LFS_HOSTNAME="$LFS_HOSTNAME" \
    LFS_RELEASE_VERSION="$LFS_RELEASE_VERSION" \
    LFS_RELEASE_CODENAME="$LFS_RELEASE_CODENAME" \
    LFS_NETWORK_MODE="${LFS_NETWORK_MODE:-dhcp}" \
    LFS_NETWORK_MATCH="${LFS_NETWORK_MATCH:-Name=en* eth* wl*}" \
    LFS_NETWORK_ADDRESS="${LFS_NETWORK_ADDRESS:-}" \
    LFS_NETWORK_GATEWAY="${LFS_NETWORK_GATEWAY:-}" \
    LFS_NETWORK_DNS="${LFS_NETWORK_DNS:-8.8.8.8}" \
    LFS_NETWORK_DNS2="${LFS_NETWORK_DNS2:-}" \
    LFS_NETWORK_DOMAIN="${LFS_NETWORK_DOMAIN:-}" \
    LFS_TIMEZONE="$LFS_TIMEZONE" \
    LFS_LOCALE="$LFS_LOCALE" \
    LFS_KEYMAP="$LFS_KEYMAP" \
    LFS_CONSOLE_FONT="$LFS_CONSOLE_FONT" \
    LFS_HWCLOCK_LOCAL="${LFS_HWCLOCK_LOCAL:-0}" \
    "$@"
}

DO_MOUNT=0
CHROOT_CMD=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --mount) DO_MOUNT=1; shift ;;
    --)
      shift
      CHROOT_CMD=("$@")
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_root
load_build_config

if [[ ! -d "$LFS/usr" ]]; then
  echo "LFS system tree not found at $LFS (missing usr/)" >&2
  exit 1
fi

ensure_root_mounted

if [[ ! -x "$MOUNT_KERNFS" ]]; then
  echo "Missing mount helper: $MOUNT_KERNFS" >&2
  exit 1
fi

echo "=== Mounting virtual kernel filesystems under $LFS ==="
LFS="$LFS" bash "$MOUNT_KERNFS"

mount_fstab_extras
mount_esp_if_needed

if ((${#CHROOT_CMD[@]})); then
  echo "=== Running in LFS chroot: ${CHROOT_CMD[*]} ==="
  chroot_env "${CHROOT_CMD[@]}"
else
  echo "=== Entering interactive LFS chroot at $LFS ==="
  echo "Exit the shell to return to the host. Unmount with: sudo ./lfs unmount"
  chroot_env /bin/bash --login
fi
