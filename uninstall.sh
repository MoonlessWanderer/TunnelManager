#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remove Tunnel Manager. This script does not flush firewall rules
# and does not remove wireguard or haproxy.
set -euo pipefail

PREFIX="/usr/local"
ASSUME_YES=0
PURGE_STATE=0
SKIP_DOWN=0

ETC_DIR=/etc/tunnel-manager
VAR_DIR=/var/lib/tunnel-manager
LOG_DIR=/var/log/tunnel-manager
RUN_DIR=/run/tunnel-manager
WG_DIR=/etc/wireguard
SYSCTL_FWD=/etc/sysctl.d/99-tunnel-manager.conf
SYSCTL_BBR=/etc/sysctl.d/98-tunnel-manager-bbr.conf

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--prefix DIR] [--yes] [--purge-state] [--skip-down]

Stops Tunnel Manager, then removes the program. --purge-state also removes
saved tunnels, keys, logs, Tunnel Manager sysctl files, and
/etc/wireguard/tm-*.conf. Missing paths are ignored. Foreign firewall rules
and other WireGuard configs are left in place.
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

if [[ "${TM_TEST_MODE:-0}" == "1" ]]; then
  ETC_DIR=${TM_ETC:-$ETC_DIR}
  VAR_DIR=${TM_VAR:-$VAR_DIR}
  LOG_DIR=${TM_LOG_DIR:-$LOG_DIR}
  RUN_DIR=${TM_RUN:-$RUN_DIR}
  WG_DIR=${TM_WG_DIR:-$WG_DIR}
  SYSCTL_FWD=${TM_SYSCTL_FILE:-$SYSCTL_FWD}
  SYSCTL_BBR=${TM_BBR_FILE:-$SYSCTL_BBR}
fi

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

if [[ "$PURGE_STATE" -eq 1 && "$(id -u)" -ne 0 && "${TM_TEST_MODE:-0}" != "1" ]]; then
  printf '%s\n' "Refusing to remove saved tunnels and keys without root." >&2
  exit 1
fi

owned_dir() {
  local path="$1"
  local base
  base=$(basename -- "$path")
  [[ "$base" == "tunnel-manager" ]] || return 1
  [[ "$path" != "/" && "$path" != "/etc" && "$path" != "/var" && "$path" != "/run" ]]
}

bin="${PREFIX}/bin/tunnel-manager"
if [[ "$SKIP_DOWN" -eq 0 && -x "$bin" ]]; then
  if ! "$bin" down --yes; then
    printf '%s\n' "Runtime shutdown failed. Removal will continue." >&2
  fi
fi

if [[ "${TM_TEST_MODE:-0}" != "1" ]] && command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  systemctl disable --now tunnel-manager-apply.service >/dev/null 2>&1 || true
  systemctl disable --now tunnel-manager-haproxy.service >/dev/null 2>&1 || true
  rm -f -- /etc/systemd/system/tunnel-manager-apply.service /etc/systemd/system/tunnel-manager-haproxy.service
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

if [[ "$PURGE_STATE" -eq 1 ]]; then
  if [[ "${TM_TEST_MODE:-0}" != "1" && "$(id -u)" -eq 0 ]] && command -v sysctl >/dev/null 2>&1; then
    if [[ -f "${VAR_DIR}/bbr.qdisc.prev" ]]; then
      value=$(tr -d '[:space:]' <"${VAR_DIR}/bbr.qdisc.prev")
      if [[ "$value" =~ ^[a-z0-9_]{1,32}$ ]]; then
        sysctl -w "net.core.default_qdisc=${value}" >/dev/null 2>&1 || true
      fi
    fi
    if [[ -f "${VAR_DIR}/bbr.cc.prev" ]]; then
      value=$(tr -d '[:space:]' <"${VAR_DIR}/bbr.cc.prev")
      if [[ "$value" =~ ^[a-z0-9_]{1,32}$ ]]; then
        sysctl -w "net.ipv4.tcp_congestion_control=${value}" >/dev/null 2>&1 || true
      fi
    fi
    if [[ -f "${VAR_DIR}/ip_forward.prev" ]]; then
      value=$(tr -d '[:space:]' <"${VAR_DIR}/ip_forward.prev")
      if [[ "$value" == "0" ]]; then
        sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
      fi
    fi
  fi

  if [[ "$WG_DIR" == /etc/wireguard || ( "${TM_TEST_MODE:-0}" == "1" && -n "${TM_TEST_ROOT:-}" && "$WG_DIR" == "${TM_TEST_ROOT}"/* ) ]]; then
    if [[ -d "$WG_DIR" ]]; then
      shopt -s nullglob
      for conf in "$WG_DIR"/tm-*.conf; do
        name=$(basename -- "$conf" .conf)
        if [[ "${TM_TEST_MODE:-0}" != "1" ]] && command -v wg-quick >/dev/null 2>&1; then
          wg-quick down "$name" >/dev/null 2>&1 || true
        fi
        rm -f -- "$conf"
      done
      shopt -u nullglob
    fi
  else
    printf '%s\n' "Refusing to remove WireGuard configs in ${WG_DIR}." >&2
    exit 1
  fi

  for dir in "$ETC_DIR" "$VAR_DIR" "$LOG_DIR" "$RUN_DIR"; do
    if owned_dir "$dir"; then
      rm -rf -- "$dir"
    elif [[ "${TM_TEST_MODE:-0}" == "1" && "$dir" == "${TM_TEST_ROOT:-/tmp/tm-test.invalid}"/* ]]; then
      rm -rf -- "$dir"
    else
      printf '%s\n' "Refusing to remove ${dir}." >&2
      exit 1
    fi
  done
  for sysctl_file in "$SYSCTL_FWD" "$SYSCTL_BBR"; do
    case "$sysctl_file" in
      /etc/sysctl.d/99-tunnel-manager.conf|/etc/sysctl.d/98-tunnel-manager-bbr.conf)
        rm -f -- "$sysctl_file"
        ;;
      *)
        if [[ "${TM_TEST_MODE:-0}" == "1" && -n "${TM_TEST_ROOT:-}" && "$sysctl_file" == "${TM_TEST_ROOT}"/* ]]; then
          rm -f -- "$sysctl_file"
        else
          printf '%s\n' "Refusing to remove ${sysctl_file}." >&2
          exit 1
        fi
        ;;
    esac
  done
  printf '%s\n' "Saved tunnels, keys, logs, and Tunnel Manager WireGuard configs were removed."
fi

rm -f -- "${PREFIX}/bin/tunnel-manager" "${PREFIX}/bin/tm"
rm -rf -- "${PREFIX}/lib/tunnel-manager"
rm -rf -- "${PREFIX}/share/tunnel-manager"

printf '%s\n' "Tunnel Manager files were removed from ${PREFIX}."
printf '%s\n' "Firewall rules owned by other tools were not flushed."
