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
  if [[ "$ip" == "0.0.0.0" || "$ip" == "::" ]]; then
    return 0
  fi
  tm_ip_is_unicast_host "$ip"
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

# Pull a WireGuard key out of pasted text. Logs hide keys as [REDACTED-KEY],
# so that placeholder is rejected instead of being stored.
tm_normalize_wg_key() {
  local key="$1"
  key=${key//$'\r'/}
  key=${key//$'\n'/}
  if [[ "$key" == *"[REDACTED-KEY]"* || "$key" == *REDACTED-KEY* ]]; then
    tm_error "That text is a log placeholder, not the key. On the other server run sudo tm, open Manage Tunnels, and choose Show public key. Copy the line that ends with =."
    return 1
  fi
  if [[ "$key" =~ ([A-Za-z0-9+/]{43}=) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  tm_error "A WireGuard public key is 44 characters and ends with =."
  return 1
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

tm_ipv6_append_groups() {
  local -n _tm_v6=$1
  shift
  local group padded
  for group in "$@"; do
    [[ "$group" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    printf -v padded '%04x' "$((16#$group))"
    _tm_v6+=("$padded")
  done
}

tm_ipv6_expand() {
  local ip="${1,,}"
  local left="" right="" missing=0 i
  local -a left_groups=() right_groups=() words=()
  [[ -n "$ip" ]] || return 1
  [[ "$ip" =~ ^[0-9a-f:]+$ ]] || return 1
  [[ "$ip" != *:::* ]] || return 1
  [[ "$ip" != *::*::* ]] || return 1
  if [[ "$ip" == *::* ]]; then
    left=${ip%%::*}
    right=${ip#*::}
    if [[ -n "$left" ]]; then
      [[ "$left" != *: && "$left" != :* ]] || return 1
      IFS=':' read -r -a left_groups <<<"$left"
    fi
    if [[ -n "$right" ]]; then
      [[ "$right" != *: && "$right" != :* ]] || return 1
      IFS=':' read -r -a right_groups <<<"$right"
    fi
    missing=$((8 - ${#left_groups[@]} - ${#right_groups[@]}))
    ((missing >= 1)) || return 1
  else
    [[ "$ip" != *: && "$ip" != :* ]] || return 1
    IFS=':' read -r -a left_groups <<<"$ip"
    [[ "${#left_groups[@]}" -eq 8 ]] || return 1
  fi
  if ((${#left_groups[@]} > 0)); then
    tm_ipv6_append_groups words "${left_groups[@]}" || return 1
  fi
  for ((i = 0; i < missing; i++)); do
    words+=(0000)
  done
  if ((${#right_groups[@]} > 0)); then
    tm_ipv6_append_groups words "${right_groups[@]}" || return 1
  fi
  [[ "${#words[@]}" -eq 8 ]] || return 1
  printf '%s\n' "${words[*]}"
}

tm_valid_ipv6() {
  tm_ipv6_expand "$1" >/dev/null
}

tm_ip_family() {
  if tm_valid_ipv4 "$1"; then
    printf '4\n'
    return 0
  fi
  if tm_valid_ipv6 "$1"; then
    printf '6\n'
    return 0
  fi
  return 1
}

tm_ip_canonical() {
  local family
  family=$(tm_ip_family "$1") || return 1
  if [[ "$family" == "4" ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  tm_ipv6_expand "$1" | tr ' ' ':'
}

tm_ipv6_is_unicast_host() {
  local expanded first num
  expanded=$(tm_ipv6_expand "$1") || return 1
  [[ "$expanded" != "0000 0000 0000 0000 0000 0000 0000 0000" ]] || return 1
  [[ "$expanded" != "0000 0000 0000 0000 0000 0000 0000 0001" ]] || return 1
  [[ "$expanded" != "0000 0000 0000 0000 0000 ffff "* ]] || return 1
  first=${expanded%% *}
  num=$((16#$first))
  if ((num >= 0xfe80 && num <= 0xfeff)); then
    return 1
  fi
  if ((num >= 0xff00)); then
    return 1
  fi
  return 0
}

tm_ip_is_unicast_host() {
  tm_ipv4_is_unicast_host "$1" && return 0
  tm_ipv6_is_unicast_host "$1"
}

tm_valid_ipv6_prefix() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [[ "$p" =~ ^0[0-9]+$ ]] && return 1
  # Wider than /64 would install a connected route that can shadow real networks.
  ((p >= 64 && p <= 127)) || return 1
  return 0
}

tm_valid_prefix_for_family() {
  case "$1" in
    4) tm_valid_tunnel_prefix "$2" ;;
    6) tm_valid_ipv6_prefix "$2" ;;
    *) return 1 ;;
  esac
}

tm_ipv6_network() {
  local ip="$1"
  local prefix="$2"
  local expanded i hextet result b global_bit bit_val out_bit padded
  local -a src=() masked=()
  expanded=$(tm_ipv6_expand "$ip") || return 1
  IFS=$' \t\n' read -r -a src <<<"$expanded"
  for i in 0 1 2 3 4 5 6 7; do
    hextet=$((16#${src[i]}))
    result=0
    for b in 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0; do
      global_bit=$((i * 16 + (15 - b)))
      bit_val=$(((hextet >> b) & 1))
      if ((global_bit >= prefix)); then
        out_bit=0
      else
        out_bit=$bit_val
      fi
      result=$((result | (out_bit << b)))
    done
    printf -v padded '%04x' "$result"
    masked+=("$padded")
  done
  printf '%s\n' "${masked[*]}"
}

tm_ipv6_same_subnet() {
  local left="$1"
  local right="$2"
  local prefix="$3"
  local left_net right_net
  tm_valid_ipv6 "$left" || return 1
  tm_valid_ipv6 "$right" || return 1
  tm_valid_ipv6_prefix "$prefix" || return 1
  left_net=$(tm_ipv6_network "$left" "$prefix")
  right_net=$(tm_ipv6_network "$right" "$prefix")
  [[ "$left_net" == "$right_net" ]]
}

tm_ipv6_is_assignable() {
  local ip="$1"
  local prefix="$2"
  local expanded network
  tm_ipv6_is_unicast_host "$ip" || return 1
  tm_valid_ipv6_prefix "$prefix" || return 1
  if ((prefix >= 127)); then
    return 0
  fi
  expanded=$(tm_ipv6_expand "$ip") || return 1
  network=$(tm_ipv6_network "$ip" "$prefix") || return 1
  [[ "$expanded" != "$network" ]]
}

tm_ip_is_assignable() {
  local family
  family=$(tm_ip_family "$1") || return 1
  if [[ "$family" == "4" ]]; then
    tm_ipv4_is_assignable "$1" "$2"
  else
    tm_ipv6_is_assignable "$1" "$2"
  fi
}

tm_ip_same_subnet() {
  local family
  family=$(tm_ip_family "$1") || return 1
  if [[ "$family" == "4" ]]; then
    tm_ipv4_same_subnet "$1" "$2" "$3"
  else
    tm_ipv6_same_subnet "$1" "$2" "$3"
  fi
}

tm_public_pair_ok() {
  local left_family right_family
  left_family=$(tm_ip_family "$1") || return 1
  right_family=$(tm_ip_family "$2") || return 1
  [[ "$left_family" == "$right_family" ]] || return 1
  tm_ip_is_unicast_host "$1" || return 1
  tm_ip_is_unicast_host "$2" || return 1
  [[ "$(tm_ip_canonical "$1")" != "$(tm_ip_canonical "$2")" ]] || return 1
  return 0
}

tm_tunnel_pair_ok() {
  local local_ip="$1"
  local remote_ip="$2"
  local prefix="$3"
  local left_family right_family
  left_family=$(tm_ip_family "$local_ip") || return 1
  right_family=$(tm_ip_family "$remote_ip") || return 1
  [[ "$left_family" == "$right_family" ]] || return 1
  [[ "$(tm_ip_canonical "$local_ip")" != "$(tm_ip_canonical "$remote_ip")" ]] || return 1
  tm_ip_is_assignable "$local_ip" "$prefix" || return 1
  tm_ip_is_assignable "$remote_ip" "$prefix" || return 1
  tm_ip_same_subnet "$local_ip" "$remote_ip" "$prefix" || return 1
  return 0
}

tm_port_is_protected() {
  local port="$1"
  local ssh_port="${TM_SSH_PORT:-22}"
  local -a fields=()
  [[ "$port" == "$ssh_port" ]] && return 0
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    IFS=$' \t\n' read -r -a fields <<<"${SSH_CONNECTION}"
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
