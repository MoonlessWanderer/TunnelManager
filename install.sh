#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Install Tunnel Manager. This script does not change firewall rules,
# tunnels, or the default route.
set -euo pipefail

PREFIX="/usr/local"
SKIP_PACKAGES=0
SKIP_SYSTEMD=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: install.sh [--prefix DIR] [--skip-packages] [--skip-systemd] [--yes]

Installs Tunnel Manager into PREFIX. Package installation is attempted only
on Debian and Ubuntu when running as root. Services are not enabled.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="${2:-}"
      shift 2
      ;;
    --skip-packages)
      SKIP_PACKAGES=1
      shift
      ;;
    --skip-systemd)
      SKIP_SYSTEMD=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PREFIX" || "$PREFIX" == "/" ]]; then
  printf '%s\n' "Refusing an empty or root prefix." >&2
  exit 1
fi

install() {
  if [[ "${1:-}" == "-d" ]]; then
    shift
    local mode="0755"
    if [[ "${1:-}" == "-m" ]]; then
      mode="${2:-0755}"
      shift 2
    fi
    local dir
    for dir in "$@"; do
      mkdir -p -- "$dir"
      chmod "$mode" "$dir"
    done
    return 0
  fi
  local mode="0644"
  if [[ "${1:-}" == "-m" ]]; then
    mode="${2:-0644}"
    shift 2
  fi
  local src="${1:-}" dest="${2:-}"
  mkdir -p -- "$(dirname -- "$dest")"
  cp -f -- "$src" "$dest"
  chmod "$mode" "$dest"
}

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DEST="${PREFIX}/lib/tunnel-manager"
BIN_DEST="${PREFIX}/bin"
SHARE_DEST="${PREFIX}/share/tunnel-manager"
UNIT_SRC="${ROOT}/systemd"

need_root=0
if [[ "$SKIP_PACKAGES" -eq 0 || "$SKIP_SYSTEMD" -eq 0 ]]; then
  if [[ "$PREFIX" == "/usr" || "$PREFIX" == "/usr/local" ]]; then
    need_root=1
  fi
fi
if [[ "$need_root" -eq 1 && "$(id -u)" -ne 0 ]]; then
  printf '%s\n' "Root is required to install packages or systemd units under ${PREFIX}." >&2
  exit 1
fi

if [[ "$SKIP_PACKAGES" -eq 0 ]]; then
  if [[ ! -r /etc/os-release ]]; then
    printf '%s\n' "Refusing package installation without /etc/os-release. Re-run with --skip-packages." >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *)
      case " ${ID_LIKE:-} " in
        *" debian "*) ;;
        *)
          printf '%s\n' "Refusing package installation on ${ID:-unknown}. Re-run with --skip-packages or --force is not offered." >&2
          exit 1
          ;;
      esac
      ;;
  esac
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    wireguard \
    iproute2 \
    iptables \
    nftables \
    haproxy \
    iputils-ping \
    procps \
    ca-certificates
fi

install -d -m 0755 "${BIN_DEST}" "${LIB_DEST}" "${SHARE_DEST}/examples" "${SHARE_DEST}/docs" "${SHARE_DEST}/systemd"
install -m 0755 "${ROOT}/bin/tunnel-manager" "${BIN_DEST}/tunnel-manager"
install -m 0755 "${ROOT}/bin/tm" "${BIN_DEST}/tm"
local_sh=""
for local_sh in "${ROOT}/lib/"*.sh; do
  install -m 0644 "$local_sh" "${LIB_DEST}/$(basename "$local_sh")"
done
install -m 0755 "${ROOT}/lib/haproxy-reload.sh" "${LIB_DEST}/haproxy-reload.sh"
install -m 0755 "${ROOT}/uninstall.sh" "${LIB_DEST}/uninstall.sh"
if [[ -d "${ROOT}/examples" ]]; then
  for local_sh in "${ROOT}/examples/"*; do
    [[ -f "$local_sh" ]] || continue
    install -m 0644 "$local_sh" "${SHARE_DEST}/examples/$(basename "$local_sh")"
  done
fi
if [[ -d "${ROOT}/docs" ]]; then
  for local_sh in "${ROOT}/docs/"*; do
    [[ -f "$local_sh" ]] || continue
    install -m 0644 "$local_sh" "${SHARE_DEST}/docs/$(basename "$local_sh")"
  done
fi
for local_sh in "${UNIT_SRC}/"*.in; do
  [[ -f "$local_sh" ]] || continue
  install -m 0644 "$local_sh" "${SHARE_DEST}/systemd/$(basename "$local_sh")"
done

if [[ "$SKIP_SYSTEMD" -eq 0 && -d /etc/systemd/system ]]; then
  haproxy_bin=$(command -v haproxy || true)
  [[ -n "$haproxy_bin" ]] || haproxy_bin="/usr/sbin/haproxy"
  for local_sh in "${UNIT_SRC}/"*.in; do
    [[ -f "$local_sh" ]] || continue
    dest="/etc/systemd/system/$(basename "${local_sh%.in}")"
    sed \
      -e "s|@BIN@|${BIN_DEST}/tunnel-manager|g" \
      -e "s|@LIB@|${LIB_DEST}|g" \
      -e "s|@HAPROXY@|${haproxy_bin}|g" \
      -e "s|@CFG@|/etc/tunnel-manager/haproxy.cfg|g" \
      -e "s|@PID@|/run/tunnel-manager/haproxy.pid|g" \
      "$local_sh" >"$dest"
    chmod 0644 "$dest"
  done
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
  fi
  printf '%s\n' "Systemd units were installed but not enabled."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  install -d -m 0755 /etc/tunnel-manager
  install -d -m 0700 /etc/tunnel-manager/keys /etc/tunnel-manager/tunnels /etc/tunnel-manager/forwards
  install -d -m 0700 /var/lib/tunnel-manager /var/lib/tunnel-manager/backups
  install -d -m 0750 /var/log/tunnel-manager
fi

printf '%s\n' "Installed Tunnel Manager into ${PREFIX}."
printf '%s\n' "Open the menu with: sudo ${BIN_DEST}/tm"
printf '%s\n' "Next: sudo ${BIN_DEST}/tunnel-manager init --role iran|foreign ..."
printf '%s\n' "Services stay disabled until: sudo ${BIN_DEST}/tunnel-manager service enable"
if [[ "$ASSUME_YES" -eq 0 ]]; then
  printf '%s\n' "No firewall rules, tunnels, or routes were changed."
fi
