#!/usr/bin/env bash
# Download BLFS extra tarballs (UEFI GRUB dependencies) into host sources.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sources-lib.sh
source "$ROOT/sources-lib.sh"

META="$ROOT/blfs-extra/blfs-extra-packages.json"
HOST_SOURCES="$(host_sources_dir)"

if [[ ! -f "$META" ]]; then
  echo "Missing $META" >&2
  exit 1
fi

download_one() {
  local tarball="$1"
  shift
  local dest="$HOST_SOURCES/$tarball"

  if [[ -f "$dest" ]]; then
    echo "  have $tarball"
    return 0
  fi

  for url in "$@"; do
    echo "  fetching $tarball from $url"
    if curl -fsSL -o "$dest" "$url"; then
      return 0
    fi
    rm -f "$dest"
  done

  echo "  failed to download $tarball" >&2
  return 1
}

echo "BLFS extra packages -> $HOST_SOURCES"
mkdir -p "$HOST_SOURCES"

while IFS=$'\t' read -r tarball urls; do
  [[ -z "$tarball" ]] && continue
  # shellcheck disable=SC2206
  url_arr=($urls)
  download_one "$tarball" "${url_arr[@]}"
done < <(
  python3 - "$META" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for pkg in data.get("packages", []):
    urls = " ".join(pkg.get("urls", []))
    print(f"{pkg['tarball']}\t{urls}")
PY
)

echo "BLFS extra download complete."
