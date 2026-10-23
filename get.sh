#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Download and install Tunnel Manager with one command.
# This script does not enable services, flush firewalls, or change routes.
set -euo pipefail

RELEASE_URL="https://github.com/MoonlessWanderer/TunnelManager/archive/refs/heads/main.tar.gz"

usage() {
  cat <<'EOF'
Usage:
  curl -fsSL https://raw.githubusercontent.com/MoonlessWanderer/TunnelManager/main/get.sh | sudo bash

Downloads the main branch and runs install.sh. Services stay disabled.
Firewall rules and the default route are not changed.
Arguments after the script are passed to install.sh.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_root=1
skip_packages=0
skip_systemd=0
have_prefix=0
for arg in "$@"; do
  case "$arg" in
    --skip-packages) skip_packages=1 ;;
    --skip-systemd) skip_systemd=1 ;;
    --prefix) have_prefix=1 ;;
  esac
done
if [[ "$skip_packages" -eq 1 && "$skip_systemd" -eq 1 && "$have_prefix" -eq 1 ]]; then
  need_root=0
fi
if [[ "$need_root" -eq 1 && "$(id -u)" -ne 0 ]]; then
  printf '%s\n' "Root is required. Run: curl -fsSL https://raw.githubusercontent.com/MoonlessWanderer/TunnelManager/main/get.sh | sudo bash" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/tunnel-manager-get.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

if [[ -n "${TM_UPDATE_ARCHIVE:-}" ]]; then
  [[ -f "$TM_UPDATE_ARCHIVE" && ! -L "$TM_UPDATE_ARCHIVE" ]] || {
    printf '%s\n' "TM_UPDATE_ARCHIVE is not a regular file." >&2
    exit 1
  }
  cp -f -- "$TM_UPDATE_ARCHIVE" "$work/src.tar.gz"
else
  if ! command -v curl >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl
  fi
  curl -fsSL --proto '=https' --tlsv1.2 -o "$work/src.tar.gz" "$RELEASE_URL"
fi

while IFS= read -r member; do
  [[ -n "$member" ]] || continue
  case "$member" in
    /*|*..*)
      printf 'Refusing archive member: %s\n' "$member" >&2
      exit 1
      ;;
  esac
done < <(tar -tzf "$work/src.tar.gz")

mkdir -p -- "$work/src"
tar -xzf "$work/src.tar.gz" -C "$work/src"
src=""
if [[ -f "$work/src/install.sh" && -f "$work/src/bin/tunnel-manager" ]]; then
  src=$work/src
else
  for dir in "$work/src"/*; do
    [[ -d "$dir" && -f "$dir/install.sh" && -f "$dir/bin/tunnel-manager" && -f "$dir/lib/load.sh" ]] || continue
    src=$dir
    break
  done
fi
[[ -n "$src" ]] || {
  printf '%s\n' "The archive does not contain Tunnel Manager." >&2
  exit 1
}
bash "$src/install.sh" "$@"
printf '%s\n' "Open the menu with: sudo tm"
