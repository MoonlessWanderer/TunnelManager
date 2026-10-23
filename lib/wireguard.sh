# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — WireGuard configuration and lifecycle.
# Generated configs set Table = off and never allow a default route.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "wireguard.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_WIREGUARD_LOADED:-}" ]]; then
  return 0
fi
TM_WIREGUARD_LOADED=1

tm_tunnel_iface() {
  printf 'tm-%s\n' "$1"
}

tm_wg_render() {
  local private_key="$1"
  local local_ip="$2"
  local cidr="$3"
  local listen_port="$4"
  local mtu="$5"
  local peer_key="$6"
  local peer_tun="$7"
  local endpoint_host="$8"
  local endpoint_port="$9"
  local keepalive="${10}"
  local family peer_family hostbits endpoint=""
  tm_valid_wg_key "$private_key" || return 1
  tm_valid_wg_key "$peer_key" || return 1
  family=$(tm_ip_family "$local_ip") || return 1
  peer_family=$(tm_ip_family "$peer_tun") || return 1
  [[ "$family" == "$peer_family" ]] || return 1
  tm_ip_is_assignable "$local_ip" "$cidr" || return 1
  tm_ip_is_assignable "$peer_tun" "$cidr" || return 1
  tm_valid_port "$listen_port" || return 1
  tm_valid_mtu "$mtu" || return 1
  tm_valid_keepalive "$keepalive" || return 1
  if [[ "$family" == "4" ]]; then
    hostbits=32
  else
    hostbits=128
  fi
  if [[ -n "$endpoint_host" ]]; then
    tm_ip_is_unicast_host "$endpoint_host" || return 1
    tm_valid_port "$endpoint_port" || return 1
    if [[ "$(tm_ip_family "$endpoint_host")" == "6" ]]; then
      endpoint="[${endpoint_host}]:${endpoint_port}"
    else
      endpoint="${endpoint_host}:${endpoint_port}"
    fi
  fi
  if tm_default_route_cidr "${peer_tun}/${hostbits}"; then
    return 1
  fi
  printf '%s\n' "[Interface]"
  printf 'Address = %s/%s\n' "$local_ip" "$cidr"
  printf 'ListenPort = %s\n' "$listen_port"
  printf 'PrivateKey = %s\n' "$private_key"
  printf 'MTU = %s\n' "$mtu"
  printf '%s\n' "Table = off"
  printf '\n'
  printf '%s\n' "[Peer]"
  printf 'PublicKey = %s\n' "$peer_key"
  printf 'AllowedIPs = %s/%s\n' "$peer_tun" "$hostbits"
  if [[ -n "$endpoint" ]]; then
    printf 'Endpoint = %s\n' "$endpoint"
  fi
  if [[ "$keepalive" != "0" ]]; then
    printf 'PersistentKeepalive = %s\n' "$keepalive"
  fi
}

tm_wg_assert_conf_safe() {
  local file="$1"
  local text
  [[ -f "$file" && ! -L "$file" ]] || return 1
  text=$(cat -- "$file")
  [[ "$text" == *"Table = off"* ]] || return 1
  [[ "$text" != *"0.0.0.0/0"* ]] || return 1
  [[ "$text" != *"::/0"* ]] || return 1
  grep -Eq '^AllowedIPs = .*/(32|128)$' <<<"$text" || return 1
  return 0
}

tm_wg_keygen_exec() {
  local name="$1"
  local keyfile pubfile priv pub
  tm_valid_tunnel_name "$name" || return 1
  tm_ensure_tree || return 1
  keyfile=$(tm_key_file "$name")
  pubfile=$(tm_pub_file "$name")
  if [[ -f "$keyfile" ]]; then
    return 0
  fi
  priv=$(tm_run_quiet wg genkey) || return 1
  priv=${priv//$'\r'/}
  priv=${priv//$'\n'/}
  tm_valid_wg_key "$priv" || {
    unset priv
    tm_error "wg genkey did not return a usable key."
    return 1
  }
  pub=$(printf '%s\n' "$priv" | tm_run_quiet wg pubkey) || {
    unset priv
    return 1
  }
  pub=${pub//$'\r'/}
  pub=${pub//$'\n'/}
  tm_valid_wg_key "$pub" || {
    unset priv pub
    tm_error "wg pubkey did not return a usable key."
    return 1
  }
  printf '%s\n' "$priv" | tm_write_file "$keyfile" 0600 || {
    unset priv pub
    return 1
  }
  unset priv
  printf '%s\n' "$pub" | tm_write_file "$pubfile" 0644 || return 1
  unset pub
}

# Print to the terminal, not the log. The log redacts every key-shaped value,
# including the public key the other server needs.
tm_print_public_key() {
  local name="$1"
  local pub="${2:-}"
  local pubfile
  if [[ -z "$pub" ]]; then
    pubfile=$(tm_pub_file "$name")
    [[ -f "$pubfile" ]] || return 1
    pub=$(tr -d '[:space:]' <"$pubfile")
  fi
  tm_valid_wg_key "$pub" || return 1
  printf '\n%s\n' "PUBLIC KEY for ${name}. Copy this single line to the other server:"
  printf '%s\n\n' "$pub"
}

tm_wg_key_undo() {
  local name="$1"
  local keyfile pubfile
  keyfile=$(tm_key_file "$name")
  pubfile=$(tm_pub_file "$name")
  [[ -f "$keyfile" ]] && tm_safe_rm "$keyfile"
  [[ -f "$pubfile" ]] && tm_safe_rm "$pubfile"
  return 0
}

tm_wg_conf_write_exec() {
  local name="$1"
  local local_ip="$2"
  local cidr="$3"
  local listen_port="$4"
  local mtu="$5"
  local peer_key="$6"
  local peer_tun="$7"
  local endpoint_host="$8"
  local endpoint_port="$9"
  local keepalive="${10}"
  local keyfile conf priv rendered
  keyfile=$(tm_key_file "$name")
  conf=$(tm_wg_conf_file "$name")
  [[ -f "$keyfile" ]] || {
    tm_error "Private key file is missing for ${name}."
    return 1
  }
  priv=$(tr -d '[:space:]' <"$keyfile") || return 1
  rendered=$(tm_wg_render "$priv" "$local_ip" "$cidr" "$listen_port" "$mtu" \
    "$peer_key" "$peer_tun" "$endpoint_host" "$endpoint_port" "$keepalive") || {
    unset priv rendered
    tm_error "Refusing to write an unsafe WireGuard configuration."
    return 1
  }
  unset priv
  printf '%s\n' "$rendered" | tm_write_file "$conf" 0600 || {
    unset rendered
    return 1
  }
  unset rendered
  tm_wg_assert_conf_safe "$conf" || {
    tm_safe_rm "$conf" || true
    tm_error "Generated WireGuard configuration failed the safety check."
    return 1
  }
}

tm_wg_conf_undo() {
  local conf
  conf=$(tm_wg_conf_file "$1")
  if [[ -f "$conf" ]]; then
    tm_safe_rm "$conf" || return 1
  fi
}

tm_wg_up_exec() {
  local name="$1"
  local iface conf
  iface=$(tm_tunnel_iface "$name")
  conf=$(tm_wg_conf_file "$name")
  if ! tm_wg_assert_conf_safe "$conf"; then
    tm_error "Refusing to start ${iface} without Table = off and a /32 or /128 AllowedIPs entry."
    return 1
  fi
  if tm_use_systemd; then
    tm_must systemctl enable --now "wg-quick@${iface}" || return 1
  else
    tm_must wg-quick up "$iface" || return 1
  fi
  if tm_iface_exists "$iface"; then
    return 0
  fi
  if tm_use_systemd; then
    tm_warn "WireGuard interface ${iface} is missing after startup. Restarting wg-quick@${iface}."
    tm_must systemctl restart "wg-quick@${iface}" || true
    if tm_iface_exists "$iface"; then
      return 0
    fi
    tm_error "WireGuard interface ${iface} did not come up."
    tm_run systemctl --no-pager status "wg-quick@${iface}" || true
    return 1
  fi
  tm_error "WireGuard interface ${iface} did not come up."
  return 1
}

tm_wg_down_exec() {
  local name="$1"
  local iface
  iface=$(tm_tunnel_iface "$name")
  if tm_use_systemd; then
    tm_run systemctl disable --now "wg-quick@${iface}" >/dev/null 2>&1 || true
    return 0
  fi
  if tm_cmd_available wg-quick; then
    tm_run wg-quick down "$iface" >/dev/null 2>&1 || true
  fi
  return 0
}
