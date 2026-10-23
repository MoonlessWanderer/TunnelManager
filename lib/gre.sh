# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — kernel GRE tunnels.
# GRE has no encryption. Callers must show that warning before apply.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "gre.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_GRE_LOADED:-}" ]]; then
  return 0
fi
TM_GRE_LOADED=1

tm_gre_warning_text() {
  cat <<'EOF'
WARNING: GRE tunnels have no encryption and no authentication.
Traffic can be read and modified in transit.
WireGuard is the recommended tunnel type.
The default route will not be changed.
EOF
}

tm_gre_up_exec() {
  local name="$1"
  local local_pub="$2"
  local remote_pub="$3"
  local local_tun="$4"
  local prefix="$5"
  local mtu="$6"
  local iface
  iface=$(tm_tunnel_iface "$name")
  tm_must modprobe ip_gre || return 1
  if tm_iface_exists "$iface"; then
    tm_info "GRE interface ${iface} already exists."
    return 0
  fi
  tm_must ip link add name "$iface" type gre local "$local_pub" remote "$remote_pub" ttl 255 || return 1
  tm_must ip link set dev "$iface" mtu "$mtu" || return 1
  tm_must ip addr add "${local_tun}/${prefix}" dev "$iface" || return 1
  tm_must ip link set dev "$iface" up || return 1
}

tm_gre_down_exec() {
  local name="$1"
  local iface
  iface=$(tm_tunnel_iface "$name")
  if tm_iface_exists "$iface"; then
    tm_must ip link del dev "$iface" || return 1
  fi
}
