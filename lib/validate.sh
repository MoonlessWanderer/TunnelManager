# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — input validation. Pure functions, no network changes.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "validate.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_VALIDATE_LOADED:-}" ]]; then
  return 0
fi
TM_VALIDATE_LOADED=1

tm_valid_octet() {
  local o="$1"
  [[ "$o" =~ ^[0-9]+$ ]] || return 1
  [[ "$o" =~ ^0[0-9]+$ ]] && return 1
  ((o >= 0 && o <= 255)) || return 1
  return 0
}

tm_valid_ipv4() {
  local ip="$1"
  local -a o=()
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  IFS='.' read -r -a o <<<"$ip"
  [[ "${#o[@]}" -eq 4 ]] || return 1
  local part
  for part in "${o[@]}"; do
    tm_valid_octet "$part" || return 1
  done
  return 0
}

tm_ipv4_is_unicast_host() {
  local ip="$1"
  local first
  tm_valid_ipv4 "$ip" || return 1
  first=${ip%%.*}
  ((first >= 1 && first <= 223)) || return 1
  ((first != 127)) || return 1
  return 0
}

tm_valid_listen_ip() {
  local ip="$1"
  if [[ "$ip" == "0.0.0.0" ]]; then
    return 0
  fi
  tm_ipv4_is_unicast_host "$ip"
}

tm_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [[ "$p" =~ ^0[0-9]+$ ]] && return 1
  ((p >= 1 && p <= 65535)) || return 1
  return 0
}

tm_valid_mtu() {
  local m="$1"
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  [[ "$m" =~ ^0[0-9]+$ ]] && return 1
  ((m >= 1280 && m <= 1500)) || return 1
  return 0
}

tm_valid_tunnel_prefix() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [[ "$p" =~ ^0[0-9]+$ ]] && return 1
  # A connected tunnel route wider than /24 could shadow real networks.
  ((p >= 24 && p <= 31)) || return 1
  return 0
}

tm_valid_keepalive() {
  local k="$1"
  [[ "$k" =~ ^[0-9]+$ ]] || return 1
  [[ "$k" =~ ^0[0-9]+$ ]] && return 1
  ((k >= 0 && k <= 120)) || return 1
  return 0
}

tm_valid_tunnel_name() {
  local name="$1"
  [[ "$name" =~ ^[a-z][a-z0-9-]{0,11}$ ]] || return 1
  [[ "$name" == *- || "$name" == *--* ]] && return 1
  case "$name" in
    tm|gre|wg|all|none|default|input|forward|output) return 1 ;;
  esac
  return 0
}

tm_valid_forward_name() {
  local name="$1"
  [[ "$name" =~ ^[a-z][a-z0-9-]{0,19}$ ]] || return 1
  [[ "$name" == *- || "$name" == *--* ]] && return 1
  return 0
}

tm_valid_iface() {
  local iface="$1"
  # IFNAMSIZ is 16 including the trailing NUL, so 15 visible characters.
  [[ "$iface" =~ ^[A-Za-z][A-Za-z0-9._-]{0,14}$ ]] || return 1
  [[ "$iface" == *..* ]] && return 1
  return 0
}

tm_valid_tunnel_iface() {
  local iface="$1"
  [[ "$iface" =~ ^tm-[a-z][a-z0-9-]{0,11}$ ]] || return 1
  return 0
}

tm_valid_role() {
  case "$1" in
    iran|foreign) return 0 ;;
    *) return 1 ;;
  esac
}

tm_valid_fw_backend() {
  case "$1" in
    auto|iptables|nft) return 0 ;;
    *) return 1 ;;
  esac
}

tm_valid_tunnel_type() {
  case "$1" in
    wireguard|gre) return 0 ;;
    *) return 1 ;;
  esac
}

tm_valid_l4_proto() {
  case "$1" in
    tcp|udp) return 0 ;;
    *) return 1 ;;
  esac
}

tm_valid_snat_mode() {
  case "$1" in
    auto|always|never) return 0 ;;
    *) return 1 ;;
  esac
}

tm_valid_wg_key() {
  [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

tm_valid_bool_word() {
  case "$1" in
    yes|no) return 0 ;;
    *) return 1 ;;
  esac
}

tm_ipv4_mask_octet() {
  local ip="$1"
  local prefix="$2"
  local mode="$3"
  local -a o=()
  local -a octets=()
  local i b global_bit bit_val out_bit result octet
  IFS='.' read -r -a o <<<"$ip"
  for i in 0 1 2 3; do
    octet=${o[$i]}
    result=0
    for b in 7 6 5 4 3 2 1 0; do
      global_bit=$((i * 8 + (7 - b)))
      bit_val=$(((octet >> b) & 1))
      out_bit=$bit_val
      if ((global_bit >= prefix)); then
        if [[ "$mode" == "network" ]]; then
          out_bit=0
        else
          out_bit=1
        fi
      fi
      result=$((result | (out_bit << b)))
    done
    octets+=("$result")
  done
  printf '%s.%s.%s.%s\n' "${octets[0]}" "${octets[1]}" "${octets[2]}" "${octets[3]}"
}

tm_ipv4_network() {
  tm_ipv4_mask_octet "$1" "$2" network
}

tm_ipv4_broadcast() {
  tm_ipv4_mask_octet "$1" "$2" broadcast
}

tm_ipv4_same_subnet() {
  local left="$1"
  local right="$2"
  local prefix="$3"
  local left_net right_net
  tm_valid_ipv4 "$left" || return 1
  tm_valid_ipv4 "$right" || return 1
  tm_valid_tunnel_prefix "$prefix" || return 1
  left_net=$(tm_ipv4_network "$left" "$prefix")
  right_net=$(tm_ipv4_network "$right" "$prefix")
  [[ "$left_net" == "$right_net" ]]
}

tm_ipv4_is_assignable() {
  local ip="$1"
  local prefix="$2"
  local network broadcast
  tm_ipv4_is_unicast_host "$ip" || return 1
  tm_valid_tunnel_prefix "$prefix" || return 1
  if ((prefix >= 31)); then
    return 0
  fi
  network=$(tm_ipv4_network "$ip" "$prefix")
  broadcast=$(tm_ipv4_broadcast "$ip" "$prefix")
  [[ "$ip" != "$network" && "$ip" != "$broadcast" ]]
}

tm_tunnel_pair_ok() {
  local local_ip="$1"
  local remote_ip="$2"
  local prefix="$3"
  [[ "$local_ip" != "$remote_ip" ]] || return 1
  tm_ipv4_is_assignable "$local_ip" "$prefix" || return 1
  tm_ipv4_is_assignable "$remote_ip" "$prefix" || return 1
  tm_ipv4_same_subnet "$local_ip" "$remote_ip" "$prefix" || return 1
  return 0
}

tm_port_is_protected() {
  local port="$1"
  local ssh_port="${TM_SSH_PORT:-22}"
  local -a fields=()
  [[ "$port" == "$ssh_port" ]] && return 0
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r -a fields <<<"${SSH_CONNECTION}"
    if [[ "${#fields[@]}" -ge 4 && "$port" == "${fields[3]}" ]]; then
      return 0
    fi
  fi
  return 1
}

tm_default_route_cidr() {
  case "$1" in
    0.0.0.0/0|::/0) return 0 ;;
    *) return 1 ;;
  esac
}
