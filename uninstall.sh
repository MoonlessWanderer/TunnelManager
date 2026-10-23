#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remove Tunnel Manager files. This script does not flush firewall rules.
set -euo pipefail

PREFIX="/usr/local"
ASSUME_YES=0
PURGE_STATE=0
SKIP_DOWN=0

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--prefix DIR] [--yes] [--purge-state] [--skip-down]

Stops Tunnel Manager runtime through its own down command, removes installed
files, and leaves foreign firewall rules in place. --purge-state also removes
/etc/tunnel-manager and /var/lib/tunnel-manager.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --purge-state) PURGE_STATE=1; shift ;;
    --skip-down) SKIP_DOWN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PREFIX" || "$PREFIX" == "/" || "$PREFIX" == "/etc" || "$PREFIX" == "/usr" ]]; then
  printf '%s\n' "Refusing prefix ${PREFIX:-empty}." >&2
  exit 1
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  if [[ ! -r /dev/tty ]]; then
    printf '%s\n' "Re-run with --yes to uninstall." >&2
    exit 1
  fi
  read -r -p "Uninstall Tunnel Manager from ${PREFIX}? [y/N] " reply </dev/tty
  case "$reply" in
    y|Y|yes|YES) ;;
    *) printf '%s\n' "Aborted."; exit 2 ;;
  esac
fi

bin="${PREFIX}/bin/tunnel-manager"
if [[ "$SKIP_DOWN" -eq 0 && -x "$bin" ]]; then
  "$bin" down --yes || printf '%s\n' "Runtime shutdown returned an error. Installed files were not removed yet." >&2
fi

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  systemctl disable --now tunnel-manager-apply.service >/dev/null 2>&1 || true
  systemctl disable --now tunnel-manager-haproxy.service >/dev/null 2>&1 || true
  rm -f -- /etc/systemd/system/tunnel-manager-apply.service /etc/systemd/system/tunnel-manager-haproxy.service
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

restore_sysctl() {
  local key="$1"
  local file="$2"
  local value=""
  [[ -f "$file" ]] || return 0
  value=$(tr -d '[:space:]' <"$file")
  if [[ "$value" =~ ^[a-z0-9_]{1,32}$ ]] && command -v sysctl >/dev/null 2>&1; then
    sysctl -w "${key}=${value}" >/dev/null 2>&1 || printf '%s\n' "Could not restore ${key}." >&2
  fi
}
if [[ "$(id -u)" -eq 0 ]]; then
  restore_sysctl net.core.default_qdisc /var/lib/tunnel-manager/bbr.qdisc.prev
  restore_sysctl net.ipv4.tcp_congestion_control /var/lib/tunnel-manager/bbr.cc.prev
  rm -f -- /etc/sysctl.d/98-tunnel-manager-bbr.conf
fi

rm -f -- "${PREFIX}/bin/tunnel-manager" "${PREFIX}/bin/tm"
rm -rf -- "${PREFIX}/lib/tunnel-manager"
rm -rf -- "${PREFIX}/share/tunnel-manager"

if [[ "$PURGE_STATE" -eq 1 ]]; then
  if [[ "$(id -u)" -ne 0 ]]; then
    printf '%s\n' "Refusing to purge state without root." >&2
    exit 1
  fi
  rm -rf -- /etc/tunnel-manager /var/lib/tunnel-manager /var/log/tunnel-manager
  rm -f -- /etc/sysctl.d/99-tunnel-manager.conf
  printf '%s\n' "State directories were removed. WireGuard configs under /etc/wireguard were not deleted automatically."
fi

printf '%s\n' "Tunnel Manager files were removed from ${PREFIX}."
printf '%s\n' "Firewall rules owned by other tools were not flushed."
