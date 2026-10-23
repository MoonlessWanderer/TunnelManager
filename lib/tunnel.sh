# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — create, start, stop, and export tunnels.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "tunnel.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_TUNNEL_LOADED:-}" ]]; then
  return 0
fi
TM_TUNNEL_LOADED=1

tm_tunnel_load() {
  local name="$1"
  local -n _tm_tun=$2
  local key
  for key in "${!_tm_tun[@]}"; do
    unset "_tm_tun[$key]"
  done
  tm_kv_read "$(tm_tunnel_file "$name")" _tm_tun
}

tm_export_dest_ok() {
  local path home parent
  path=$(tm_normalize_path "$1") || return 1
  if tm_path_has_symlink_component "$path"; then
    return 1
  fi
  home="${HOME:-}"
  if tm_path_under "$path" "$TM_VAR" || tm_path_under "$path" "/tmp"; then
    return 0
  fi
  if [[ -n "$home" ]] && tm_path_under "$path" "$home"; then
    return 0
  fi
  if [[ "${TM_TEST_MODE:-0}" == "1" ]]; then
    parent=$(dirname -- "$TM_ETC")
    tm_path_under "$path" "$parent" && return 0
  fi
  return 1
}

tm_tunnel_fill_defaults() {
  local -n _tm_fill=$1
  local outer=4 inner=4
  if tm_valid_ipv6 "${_tm_fill[local_public_ip]:-}"; then
    outer=6
  fi
  if tm_valid_ipv6 "${_tm_fill[local_tunnel_ip]:-}"; then
    inner=6
  fi
  if [[ "${_tm_fill[type]}" == "wireguard" ]]; then
    [[ -n "${_tm_fill[listen_port]:-}" ]] || _tm_fill[listen_port]=51820
    [[ -n "${_tm_fill[endpoint_port]:-}" ]] || _tm_fill[endpoint_port]="${_tm_fill[listen_port]}"
    if [[ -z "${_tm_fill[mtu]:-}" ]]; then
      if [[ "$outer" == "6" ]]; then
        _tm_fill[mtu]=1400
      else
        _tm_fill[mtu]=1420
      fi
    fi
    [[ -n "${_tm_fill[keepalive]:-}" ]] || _tm_fill[keepalive]=25
    if [[ -z "${_tm_fill[cidr]:-}" ]]; then
      if [[ "$inner" == "6" ]]; then
        _tm_fill[cidr]=64
      else
        _tm_fill[cidr]=30
      fi
    fi
  else
    if [[ -z "${_tm_fill[mtu]:-}" ]]; then
      if [[ "$outer" == "6" ]]; then
        _tm_fill[mtu]=1456
      else
        _tm_fill[mtu]=1476
      fi
    fi
    if [[ -z "${_tm_fill[cidr]:-}" ]]; then
      if [[ "$inner" == "6" ]]; then
        _tm_fill[cidr]=64
      else
        _tm_fill[cidr]=30
      fi
    fi
    _tm_fill[listen_port]="${_tm_fill[listen_port]:-1}"
    _tm_fill[endpoint_port]="${_tm_fill[endpoint_port]:-1}"
    _tm_fill[keepalive]="${_tm_fill[keepalive]:-0}"
  fi
}

tm_tunnel_validate_request() {
  local -n _tm_req=$1
  tm_valid_tunnel_name "${_tm_req[name]}" || {
    tm_error "Invalid tunnel name. Use 1-12 lowercase letters, digits, or hyphens."
    return 1
  }
  tm_valid_tunnel_type "${_tm_req[type]}" || {
    tm_error "Tunnel type must be wireguard or gre."
    return 1
  }
  tm_public_pair_ok "${_tm_req[local_public_ip]}" "${_tm_req[remote_public_ip]}" || {
    tm_error "Local and remote public addresses must be different IPv4 or IPv6 hosts of the same family."
    return 1
  }
  tm_valid_iface "${_tm_req[wan_iface]}" || {
    tm_error "Invalid WAN interface."
    return 1
  }
  tm_tunnel_fill_defaults _tm_req
  tm_tunnel_pair_ok "${_tm_req[local_tunnel_ip]}" "${_tm_req[remote_tunnel_ip]}" "${_tm_req[cidr]}" || {
    tm_error "Tunnel addresses must be different hosts in the same prefix. IPv4 uses 24-31. IPv6 uses 64-127."
    return 1
  }
  tm_valid_mtu "${_tm_req[mtu]}" || {
    tm_error "MTU must be between 1280 and 1500."
    return 1
  }
  if [[ "${_tm_req[type]}" == "wireguard" ]]; then
    tm_valid_port "${_tm_req[listen_port]}" || return 1
    tm_valid_port "${_tm_req[endpoint_port]}" || return 1
    tm_valid_keepalive "${_tm_req[keepalive]}" || return 1
    if [[ -n "${_tm_req[peer_public_key]:-}" ]] && ! tm_valid_wg_key "${_tm_req[peer_public_key]}"; then
      tm_error "The peer public key is not a WireGuard key."
      return 1
    fi
    local mtu_limit=1420
    if [[ "$(tm_ip_family "${_tm_req[local_public_ip]}")" == "6" ]]; then
      mtu_limit=1400
    fi
    if (( _tm_req[mtu] > mtu_limit )); then
      tm_warn "WireGuard MTU ${_tm_req[mtu]} is above ${mtu_limit} and may fragment on this path."
    fi
  fi
  return 0
}

tm_tunnel_state_write_exec() {
  local name="$1"
  local type="$2"
  local state="$3"
  local local_pub="$4"
  local remote_pub="$5"
  local local_tun="$6"
  local remote_tun="$7"
  local cidr="$8"
  local listen_port="$9"
  local endpoint_port="${10}"
  local mtu="${11}"
  local keepalive="${12}"
  local wan="${13}"
  local peer="${14}"
  local gre_ack="${15}"
  local -a pairs=()
  tm_ensure_tree || return 1
  pairs+=(
    TM_TUNNEL_NAME "$name"
    TM_TUNNEL_TYPE "$type"
    TM_TUNNEL_STATE "$state"
    TM_LOCAL_PUBLIC_IP "$local_pub"
    TM_REMOTE_PUBLIC_IP "$remote_pub"
    TM_LOCAL_TUNNEL_IP "$local_tun"
    TM_REMOTE_TUNNEL_IP "$remote_tun"
    TM_TUNNEL_CIDR "$cidr"
    TM_MTU "$mtu"
    TM_WAN_IFACE "$wan"
    TM_GRE_ACK "$gre_ack"
  )
  if [[ "$type" == "wireguard" ]]; then
    pairs+=(
      TM_PRIVATE_KEY_FILE "$(tm_key_file "$name")"
      TM_LISTEN_PORT "$listen_port"
      TM_ENDPOINT_PORT "$endpoint_port"
      TM_KEEPALIVE "$keepalive"
    )
    if [[ -n "$peer" ]]; then
      pairs+=(TM_PEER_PUBLIC_KEY "$peer")
    fi
  fi
  tm_kv_write "$(tm_tunnel_file "$name")" 0600 "${pairs[@]}"
}

tm_tunnel_state_undo() {
  local path
  path=$(tm_tunnel_file "$1")
  if [[ -f "$path" ]]; then
    tm_safe_rm "$path" || return 1
  fi
}

tm_tunnel_start_exec() {
  local name="$1"
  local -A row=()
  local iface family
  tm_tunnel_load "$name" row || return 1
  iface=$(tm_tunnel_iface "$name")
  family=$(tm_ip_family "${row[TM_LOCAL_PUBLIC_IP]}") || return 1
  if [[ "${row[TM_TUNNEL_STATE]}" == "pending-peer" ]]; then
    tm_info "Tunnel ${name} is waiting for a peer public key, so it will not start."
    return 0
  fi
  if [[ "${row[TM_TUNNEL_TYPE]}" == "wireguard" ]]; then
    tm_wg_conf_write_exec "$name" \
      "${row[TM_LOCAL_TUNNEL_IP]}" "${row[TM_TUNNEL_CIDR]}" "${row[TM_LISTEN_PORT]}" \
      "${row[TM_MTU]}" "${row[TM_PEER_PUBLIC_KEY]}" "${row[TM_REMOTE_TUNNEL_IP]}" \
      "${row[TM_REMOTE_PUBLIC_IP]}" "${row[TM_ENDPOINT_PORT]}" "${row[TM_KEEPALIVE]}" || return 1
    if tm_iface_exists "$iface"; then
      tm_info "WireGuard interface ${iface} is already up."
    else
      tm_wg_up_exec "$name" || return 1
    fi
    tm_rp_filter_apply_exec "$iface" || return 1
    tm_fw_input_apply_exec wg "$name" "${row[TM_WAN_IFACE]}" "${row[TM_LISTEN_PORT]}" "$family" || return 1
    return 0
  fi
  if [[ "${row[TM_GRE_ACK]}" != "yes" ]]; then
    tm_error "Refusing to start GRE tunnel ${name} without a stored encryption acknowledgement."
    return 1
  fi
  tm_gre_up_exec "$name" "${row[TM_LOCAL_PUBLIC_IP]}" "${row[TM_REMOTE_PUBLIC_IP]}" \
    "${row[TM_LOCAL_TUNNEL_IP]}" "${row[TM_TUNNEL_CIDR]}" "${row[TM_MTU]}" || return 1
  tm_rp_filter_apply_exec "$iface" || return 1
  tm_fw_input_apply_exec gre "$name" "${row[TM_WAN_IFACE]}" "" "$family" || return 1
}

tm_tunnel_stop_exec() {
  local name="$1"
  local -A row=()
  local iface family
  tm_tunnel_load "$name" row || return 1
  iface=$(tm_tunnel_iface "$name")
  family=$(tm_ip_family "${row[TM_LOCAL_PUBLIC_IP]}") || return 1
  if tm_iface_exists "$iface"; then
    tm_rp_filter_restore_exec "$iface" || return 1
  fi
  if [[ "${row[TM_TUNNEL_TYPE]}" == "wireguard" ]]; then
    tm_fw_input_delete_exec wg "$name" "$family" || return 1
    tm_wg_down_exec "$name" || return 1
    return 0
  fi
  tm_fw_input_delete_exec gre "$name" "$family" || return 1
  tm_gre_down_exec "$name" || return 1
}

tm_tunnel_require_gre_ack() {
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${TM_ALLOW_GRE:-0}" == "1" ]]; then
    return 0
  fi
  tm_gre_warning_text >&2
  if tm_confirm_phrase "GRE is not encrypted" "Type 'GRE is not encrypted' to continue:"; then
    return 0
  fi
  tm_error "GRE was not created. The confirmation phrase did not match."
  return 1
}

tm_action_tunnel_create() {
  local -A opt=()
  local -A req=()
  local state="active" gre_ack="no" peer=""
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  req[name]=$(tm_opt_get opt name)
  req[type]=$(tm_opt_get opt type)
  req[local_public_ip]=$(tm_opt_get opt local_public_ip)
  req[remote_public_ip]=$(tm_opt_get opt remote_public_ip)
  req[local_tunnel_ip]=$(tm_opt_get opt local_tunnel_ip)
  req[remote_tunnel_ip]=$(tm_opt_get opt remote_tunnel_ip)
  req[cidr]=$(tm_opt_get opt cidr)
  req[listen_port]=$(tm_opt_get opt listen_port)
  req[endpoint_port]=$(tm_opt_get opt endpoint_port)
  req[mtu]=$(tm_opt_get opt mtu)
  req[keepalive]=$(tm_opt_get opt keepalive)
  req[wan_iface]=$(tm_opt_get opt wan_iface)
  req[peer_public_key]=$(tm_opt_get opt peer_public_key)
  if [[ -f "$(tm_peer_import_candidate "${opt[peer_file]:-}")" ]]; then
    tm_tunnel_apply_peer_file req "${opt[peer_file]}"
  fi
  if [[ -n "${req[peer_public_key]:-}" ]]; then
    req[peer_public_key]=$(tm_normalize_wg_key "${req[peer_public_key]}") || return 1
  fi
  tm_tunnel_validate_request req || tm_die "Tunnel validation failed."
  if [[ -f "$(tm_tunnel_file "${req[name]}")" ]]; then
    tm_die "Tunnel ${req[name]} already exists."
  fi
  peer="${req[peer_public_key]:-}"
  if [[ "${req[type]}" == "wireguard" && -z "$peer" ]]; then
    state="pending-peer"
  fi
  if [[ "${req[type]}" == "gre" ]]; then
    gre_ack="yes"
  fi
  tm_plan_require_clear_journal
  tm_plan_reset
  if [[ "${req[type]}" == "gre" ]]; then
    tm_plan_note_gre
  fi
  tm_plan_add "Prepare Tunnel Manager directories" \
    "$(tm_shell_quote tm_noop)" \
    tm_ensure_tree
  if [[ "${req[type]}" == "wireguard" && ! -f "$(tm_key_file "${req[name]}")" ]]; then
    tm_plan_add "Generate a WireGuard key pair for ${req[name]} (private key mode 0600)" \
      "$(tm_shell_quote tm_wg_key_undo "${req[name]}")" \
      tm_wg_keygen_exec "${req[name]}"
  fi
  tm_plan_add "Write tunnel state ${req[name]} (${state}). Connected tunnel routes only; the default route is not changed." \
    "$(tm_shell_quote tm_tunnel_state_undo "${req[name]}")" \
    tm_tunnel_state_write_exec "${req[name]}" "${req[type]}" "$state" \
      "${req[local_public_ip]}" "${req[remote_public_ip]}" \
      "${req[local_tunnel_ip]}" "${req[remote_tunnel_ip]}" "${req[cidr]}" \
      "${req[listen_port]}" "${req[endpoint_port]}" "${req[mtu]}" "${req[keepalive]}" \
      "${req[wan_iface]}" "$peer" "$gre_ack"
  if [[ "$state" == "active" ]]; then
    local link_kind="${req[type]}"
    if [[ "$link_kind" == "gre" && "$(tm_ip_family "${req[local_public_ip]}")" == "6" ]]; then
      link_kind="ip6gre"
    fi
    tm_plan_add "Start ${link_kind} tunnel ${req[name]} on $(tm_tunnel_iface "${req[name]}")" \
      "$(tm_shell_quote tm_tunnel_stop_exec "${req[name]}")" \
      tm_tunnel_start_exec "${req[name]}"
  else
    tm_plan_add "Leave ${req[name]} down until a peer public key is installed" \
      "$(tm_shell_quote tm_noop)" \
      tm_noop
  fi
  tm_require_change_privileges
  local status=0
  tm_with_lock tm_plan_apply || status=$?
  if [[ "$status" -eq 0 && "${req[type]}" == "wireguard" && "${TM_DRY_RUN:-0}" != "1" ]]; then
    tm_print_public_key "${req[name]}" || true
  fi
  return "$status"
}

tm_peer_import_candidate() {
  local path="${1:-}"
  if [[ -n "$path" && -f "$path" ]]; then
    printf '%s\n' "$path"
  fi
}

tm_tunnel_apply_peer_file() {
  local -n _tm_req=$1
  local path="$2"
  local -A peer=()
  [[ -n "$path" && -f "$path" ]] || return 0
  tm_kv_read "$path" peer || tm_die "Peer file is invalid: ${path}"
  [[ -n "${peer[TM_PEER_PUBLIC_IP]:-}" ]] && _tm_req[remote_public_ip]="${peer[TM_PEER_PUBLIC_IP]}"
  [[ -n "${peer[TM_PEER_TUNNEL_IP]:-}" ]] && _tm_req[remote_tunnel_ip]="${peer[TM_PEER_TUNNEL_IP]}"
  [[ -n "${peer[TM_PEER_LISTEN_PORT]:-}" ]] && _tm_req[endpoint_port]="${peer[TM_PEER_LISTEN_PORT]}"
  [[ -n "${peer[TM_PEER_PUBLIC_KEY]:-}" ]] && _tm_req[peer_public_key]="${peer[TM_PEER_PUBLIC_KEY]}"
  [[ -n "${peer[TM_PEER_CIDR]:-}" ]] && _tm_req[cidr]="${peer[TM_PEER_CIDR]}"
}

tm_action_tunnel_set_peer() {
  local -A opt=()
  local -A row=()
  local name peer
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt name name
  name="${opt[name]}"
  peer=$(tm_opt_get opt peer_public_key)
  if [[ -n "${opt[peer_file]:-}" ]]; then
    local -A peerfile=()
    tm_kv_read "${opt[peer_file]}" peerfile || tm_die "Peer file is invalid."
    peer="${peerfile[TM_PEER_PUBLIC_KEY]:-}"
  fi
  peer=$(tm_normalize_wg_key "$peer") || return 1
  tm_tunnel_load "$name" row || tm_die "Tunnel ${name} was not found."
  [[ "${row[TM_TUNNEL_TYPE]}" == "wireguard" ]] || tm_die "set-peer applies to WireGuard tunnels."
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Store the peer public key and start ${name}" \
    "$(tm_shell_quote tm_tunnel_set_peer_undo "$name")" \
    tm_tunnel_set_peer_exec "$name" "$peer"
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_tunnel_set_peer_exec() {
  local name="$1"
  local peer="$2"
  local -A row=()
  local iface mark
  tm_tunnel_load "$name" row || return 1
  tm_valid_wg_key "$peer" || return 1
  tm_snapshot_file "$(tm_tunnel_file "$name")" || return 1
  iface=$(tm_tunnel_iface "$name")
  mark="${TM_VAR}/peer-${name}.mark"
  mkdir -p -- "$TM_VAR" || return 1
  if tm_iface_exists "$iface"; then
    printf 'kept\n' >"$mark"
  else
    printf 'started\n' >"$mark"
  fi
  chmod 0600 "$mark" || true
  tm_tunnel_state_write_exec "$name" wireguard active \
    "${row[TM_LOCAL_PUBLIC_IP]}" "${row[TM_REMOTE_PUBLIC_IP]}" \
    "${row[TM_LOCAL_TUNNEL_IP]}" "${row[TM_REMOTE_TUNNEL_IP]}" "${row[TM_TUNNEL_CIDR]}" \
    "${row[TM_LISTEN_PORT]}" "${row[TM_ENDPOINT_PORT]}" "${row[TM_MTU]}" "${row[TM_KEEPALIVE]}" \
    "${row[TM_WAN_IFACE]}" "$peer" no || return 1
  tm_tunnel_start_exec "$name"
}

tm_tunnel_set_peer_undo() {
  local name="$1"
  local mark="${TM_VAR}/peer-${name}.mark"
  local mode="started"
  if [[ -f "$mark" ]]; then
    mode=$(tr -d '[:space:]' <"$mark")
  fi
  tm_tunnel_stop_exec "$name" || return 1
  tm_restore_snapshot "$(tm_tunnel_file "$name")" || return 1
  if [[ "$mode" == "kept" ]]; then
    tm_tunnel_start_exec "$name" || return 1
  fi
  if [[ -f "$mark" ]]; then
    tm_safe_rm "$mark" || return 1
  fi
}

tm_tunnel_ensure_exec() {
  local name="$1"
  local iface mark
  iface=$(tm_tunnel_iface "$name")
  mark="${TM_VAR}/ensure-${name}.mark"
  mkdir -p -- "$TM_VAR" || return 1
  if tm_iface_exists "$iface"; then
    printf 'kept\n' >"$mark"
  else
    printf 'started\n' >"$mark"
  fi
  chmod 0600 "$mark" || true
  tm_tunnel_start_exec "$name"
}

tm_tunnel_ensure_undo() {
  local name="$1"
  local mark="${TM_VAR}/ensure-${name}.mark"
  local mode="started"
  if [[ -f "$mark" ]]; then
    mode=$(tr -d '[:space:]' <"$mark")
  fi
  if [[ "$mode" == "started" ]]; then
    tm_tunnel_stop_exec "$name" || return 1
  fi
  if [[ -f "$mark" ]]; then
    tm_safe_rm "$mark" || return 1
  fi
}

tm_tunnel_remove_files_exec() {
  local name="$1"
  local -A row=()
  local conf
  tm_tunnel_load "$name" row || return 1
  tm_snapshot_file "$(tm_tunnel_file "$name")" || return 1
  if [[ -f "$(tm_key_file "$name")" ]]; then
    tm_snapshot_file "$(tm_key_file "$name")" || return 1
  fi
  if [[ -f "$(tm_pub_file "$name")" ]]; then
    tm_snapshot_file "$(tm_pub_file "$name")" || return 1
  fi
  conf=$(tm_wg_conf_file "$name")
  if [[ -f "$conf" ]]; then
    tm_snapshot_file "$conf" || return 1
  fi
  tm_tunnel_stop_exec "$name" || return 1
  tm_wg_conf_undo "$name" || return 1
  tm_wg_key_undo "$name" || return 1
  tm_tunnel_state_undo "$name" || return 1
}

tm_tunnel_remove_undo() {
  local name="$1"
  tm_restore_snapshot "$(tm_tunnel_file "$name")" || return 1
  tm_restore_snapshot "$(tm_key_file "$name")" || return 1
  tm_restore_snapshot "$(tm_pub_file "$name")" || return 1
  tm_restore_snapshot "$(tm_wg_conf_file "$name")" || return 1
  if [[ -f "$(tm_tunnel_file "$name")" ]]; then
    tm_tunnel_start_exec "$name" || return 1
  fi
}

tm_action_tunnel_delete() {
  local -A opt=()
  local name
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt name name
  name="${opt[name]}"
  [[ -f "$(tm_tunnel_file "$name")" ]] || tm_die "Tunnel ${name} was not found."
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Stop ${name}, remove its runtime, configuration, and private key" \
    "$(tm_shell_quote tm_tunnel_remove_undo "$name")" \
    tm_tunnel_remove_files_exec "$name"
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_action_tunnel_up() {
  local -A opt=()
  local name
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt name name
  name="${opt[name]}"
  [[ -f "$(tm_tunnel_file "$name")" ]] || tm_die "Tunnel ${name} was not found."
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Start tunnel ${name}" \
    "$(tm_shell_quote tm_tunnel_stop_exec "$name")" \
    tm_tunnel_start_exec "$name"
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_action_tunnel_down() {
  local -A opt=()
  local name
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt name name
  name="${opt[name]}"
  [[ -f "$(tm_tunnel_file "$name")" ]] || tm_die "Tunnel ${name} was not found."
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Stop tunnel ${name} and keep its saved configuration" \
    "$(tm_shell_quote tm_tunnel_start_exec "$name")" \
    tm_tunnel_stop_exec "$name"
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_action_tunnel_restart() {
  local -A opt=()
  local name
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt name name
  name="${opt[name]}"
  [[ -f "$(tm_tunnel_file "$name")" ]] || tm_die "Tunnel ${name} was not found."
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Stop tunnel ${name}" \
    "$(tm_shell_quote tm_tunnel_start_exec "$name")" \
    tm_tunnel_stop_exec "$name"
  tm_plan_add "Start tunnel ${name}" \
    "$(tm_shell_quote tm_tunnel_stop_exec "$name")" \
    tm_tunnel_start_exec "$name"
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_action_tunnel_list() {
  local name
  local -A row=()
  if ! tm_list_tunnels | grep -q .; then
    tm_info "No tunnels are saved."
    return 0
  fi
  printf '%-14s %-10s %-16s %-16s %-12s\n' "NAME" "TYPE" "LOCAL" "REMOTE" "STATE"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_tunnel_load "$name" row || continue
    printf '%-14s %-10s %-16s %-16s %-12s\n' \
      "$name" "${row[TM_TUNNEL_TYPE]}" "${row[TM_LOCAL_TUNNEL_IP]}" \
      "${row[TM_REMOTE_TUNNEL_IP]}" "${row[TM_TUNNEL_STATE]}"
  done < <(tm_list_tunnels)
}

tm_action_tunnel_show() {
  local -A opt=()
  local -A row=()
  local name key
  tm_opts_parse opt "$@"
  tm_opt_require opt name name
  name="${opt[name]}"
  tm_tunnel_load "$name" row || tm_die "Tunnel ${name} was not found."
  printf 'name=%s\n' "$name"
  for key in "${!row[@]}"; do
    if [[ "$key" == "TM_PRIVATE_KEY_FILE" ]]; then
      printf '%s=%s\n' "$key" "${row[$key]}"
      continue
    fi
    printf '%s=%s\n' "$key" "${row[$key]}"
  done
  if [[ -f "$(tm_pub_file "$name")" ]]; then
    printf 'public_key=%s\n' "$(tr -d '[:space:]' <"$(tm_pub_file "$name")")"
  fi
}

tm_action_tunnel_export() {
  local -A opt=()
  local -A row=()
  local name dest pub role
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt name name
  name="${opt[name]}"
  tm_tunnel_load "$name" row || tm_die "Tunnel ${name} was not found."
  dest=$(tm_opt_get opt output "${TM_VAR}/exports/${name}.peer")
  tm_export_dest_ok "$dest" || tm_die "Refusing to write the peer bundle to ${dest}."
  if [[ -e "$dest" && "${TM_YES:-0}" != "1" && "${TM_DRY_RUN:-0}" != "1" ]]; then
    tm_die "Output already exists. Re-run with --yes to replace ${dest}."
  fi
  pub=""
  if [[ -f "$(tm_pub_file "$name")" ]]; then
    pub=$(tr -d '[:space:]' <"$(tm_pub_file "$name")")
  fi
  role="unknown"
  if [[ -f "$(tm_host_file)" ]]; then
    local -A host=()
    tm_load_host host || true
    role="${host[TM_HOST_ROLE]:-unknown}"
  fi
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    tm_info "Dry-run: would write public peer bundle ${dest}"
    return 0
  fi
  mkdir -p -- "$(dirname -- "$dest")" || tm_die "Cannot create the output directory."
  {
    printf '%s\n' "# Tunnel Manager public peer bundle. It contains no private key."
    printf 'TM_PEER_NAME=%s\n' "$name"
    printf 'TM_PEER_ROLE=%s\n' "$role"
    printf 'TM_PEER_PUBLIC_IP=%s\n' "${row[TM_LOCAL_PUBLIC_IP]}"
    printf 'TM_PEER_TUNNEL_IP=%s\n' "${row[TM_LOCAL_TUNNEL_IP]}"
    printf 'TM_PEER_TUNNEL_TYPE=%s\n' "${row[TM_TUNNEL_TYPE]}"
    printf 'TM_PEER_CIDR=%s\n' "${row[TM_TUNNEL_CIDR]}"
    if [[ -n "${row[TM_LISTEN_PORT]:-}" && "${row[TM_TUNNEL_TYPE]}" == "wireguard" ]]; then
      printf 'TM_PEER_LISTEN_PORT=%s\n' "${row[TM_LISTEN_PORT]}"
    fi
    if [[ -n "$pub" ]]; then
      printf 'TM_PEER_PUBLIC_KEY=%s\n' "$pub"
    fi
  } >"$dest"
  chmod 0644 "$dest" || true
  tm_info "Wrote public peer bundle ${dest}"
}

tm_action_tunnel_test() {
  local -A opt=()
  local -A row=()
  local name iface ok=0
  tm_opts_parse opt "$@"
  tm_opt_require opt name name
  name="${opt[name]}"
  tm_tunnel_load "$name" row || tm_die "Tunnel ${name} was not found."
  iface=$(tm_tunnel_iface "$name")
  if tm_iface_exists "$iface"; then
    tm_info "[PASS] Interface ${iface} exists."
  else
    tm_error "[FAIL] Interface ${iface} is not present."
    ok=1
  fi
  if [[ "${row[TM_TUNNEL_TYPE]}" == "wireguard" && -f "$(tm_wg_conf_file "$name")" ]]; then
    if tm_wg_assert_conf_safe "$(tm_wg_conf_file "$name")"; then
      tm_info "[PASS] WireGuard config keeps Table = off and does not use a default route."
    else
      tm_error "[FAIL] WireGuard config failed the safety check."
      ok=1
    fi
  fi
  if tm_cmd_available ping; then
    local -a ping_args=(ping -c 3 -W 2)
    if [[ "$(tm_ip_family "${row[TM_REMOTE_TUNNEL_IP]}")" == "6" ]]; then
      ping_args=(ping -6 -c 3 -W 2)
    fi
    if tm_run "${ping_args[@]}" "${row[TM_REMOTE_TUNNEL_IP]}" >/dev/null 2>&1; then
      tm_info "[PASS] ${row[TM_REMOTE_TUNNEL_IP]} answered ping."
    else
      tm_error "[FAIL] ${row[TM_REMOTE_TUNNEL_IP]} did not answer ping."
      ok=1
    fi
  else
    tm_warn "[WARN] ping is not available, so reachability was not tested."
    ok=1
  fi
  return "$ok"
}

tm_action_tunnel_keygen() {
  local -A opt=()
  local name
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt name name
  name="${opt[name]}"
  tm_valid_tunnel_name "$name" || tm_die "Invalid tunnel name."
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Generate WireGuard keys for ${name}" \
    "$(tm_shell_quote tm_wg_key_undo "$name")" \
    tm_wg_keygen_exec "$name"
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}
