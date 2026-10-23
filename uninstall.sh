#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remove Tunnel Manager. This script does not flush firewall rules.
set -euo pipefail

PREFIX="/usr/local"
ASSUME_YES=0
PURGE_STATE=0
SKIP_DOWN=0

ETC_DIR=/etc/tunnel-manager
VAR_DIR=/var/lib/tunnel-manager
LOG_DIR=/var/log/tunnel-manager
RUN_DIR=/run/tunnel-manager
SYSCTL_FWD=/etc/sysctl.d/99-tunnel-manager.conf
SYSCTL_BBR=/etc/sysctl.d/98-tunnel-manager-bbr.conf
MOD_BBR=/etc/modules-load.d/tunnel-manager-bbr.conf

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--prefix DIR] [--yes] [--purge-state] [--skip-down]

Stops Tunnel Manager, then removes the program. --purge-state also removes
saved tunnels, forwards, logs, Tunnel Manager sysctl files, and the BBR
module file. Missing
paths are ignored. Firewall rules owned by other tools are left in place.
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
  SYSCTL_FWD=${TM_SYSCTL_FILE:-$SYSCTL_FWD}
  SYSCTL_BBR=${TM_BBR_FILE:-$SYSCTL_BBR}
  MOD_BBR=${TM_BBR_MOD_FILE:-$MOD_BBR}
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
  printf '%s\n' "Refusing to remove saved tunnels without root." >&2
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
  rm -f -- /etc/systemd/system/tunnel-manager-apply.service
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
  for sysctl_file in "$SYSCTL_FWD" "$SYSCTL_BBR" "$MOD_BBR"; do
    case "$sysctl_file" in
      /etc/sysctl.d/99-tunnel-manager.conf|/etc/sysctl.d/98-tunnel-manager-bbr.conf|/etc/modules-load.d/tunnel-manager-bbr.conf)
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
  printf '%s\n' "Saved tunnels, forwards, and logs were removed."
fi

rm -f -- "${PREFIX}/bin/tunnel-manager" "${PREFIX}/bin/tm"
rm -rf -- "${PREFIX}/lib/tunnel-manager"
rm -rf -- "${PREFIX}/share/tunnel-manager"

printf '%s\n' "Tunnel Manager files were removed from ${PREFIX}."
printf '%s\n' "Firewall rules owned by other tools were not flushed."
