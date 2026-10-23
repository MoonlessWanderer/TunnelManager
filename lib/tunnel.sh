# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — create, start, and stop tunnels.

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

tm_tunnel_fill_defaults() {
  local -n _tm_fill=$1
  local outer=4 inner=4
  if tm_valid_ipv6 "${_tm_fill[local_public_ip]:-}"; then
    outer=6
  fi
  if tm_valid_ipv6 "${_tm_fill[local_tunnel_ip]:-}"; then
    inner=6
  fi
  if [[ "${_tm_fill[type]}" == "forward" ]]; then
    [[ -n "${_tm_fill[local_tunnel_ip]:-}" ]] || _tm_fill[local_tunnel_ip]="${_tm_fill[local_public_ip]}"
    [[ -n "${_tm_fill[remote_tunnel_ip]:-}" ]] || _tm_fill[remote_tunnel_ip]="${_tm_fill[remote_public_ip]}"
    [[ -n "${_tm_fill[mtu]:-}" ]] || _tm_fill[mtu]=1500
    [[ -n "${_tm_fill[cidr]:-}" ]] || _tm_fill[cidr]=32
  else
    if [[ -z "${_tm_fill[cidr]:-}" ]]; then
      if [[ "$inner" == "6" ]]; then
        _tm_fill[cidr]=64
      else
        _tm_fill[cidr]=30
      fi
    fi
    if [[ -z "${_tm_fill[key]:-}" ]] && tm_ip_family "${_tm_fill[local_tunnel_ip]:-}" >/dev/null; then
      _tm_fill[key]=$(tm_gre_key_for "${_tm_fill[local_tunnel_ip]}" "${_tm_fill[cidr]}" || true)
    fi
    # Outer IP header plus an 8-byte GRE header with a key.
    if [[ -z "${_tm_fill[mtu]:-}" ]]; then
      if [[ "$outer" == "6" ]]; then
        _tm_fill[mtu]=1452
      else
        _tm_fill[mtu]=1472
      fi
    fi
  fi
}

tm_tunnel_validate_request() {
  local -n _tm_req=$1
  tm_valid_tunnel_name "${_tm_req[name]}" || {
    tm_error "Invalid tunnel name. Use 1-12 lowercase letters, digits, or hyphens."
    return 1
  }
  tm_valid_tunnel_type "${_tm_req[type]}" || {
    tm_error "Tunnel type must be forward or gre."
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
  if [[ "${_tm_req[type]}" == "forward" ]]; then
    tm_ip_is_unicast_host "${_tm_req[local_tunnel_ip]}" || {
      tm_error "The forward source address is invalid."
      return 1
    }
    tm_ip_is_unicast_host "${_tm_req[remote_tunnel_ip]}" || {
      tm_error "The forward destination address is invalid."
      return 1
    }
    if [[ "$(tm_ip_family "${_tm_req[local_tunnel_ip]}")" != "$(tm_ip_family "${_tm_req[remote_tunnel_ip]}")" ]]; then
      tm_error "Forward source and destination must use the same IP family."
      return 1
    fi
    [[ -z "${_tm_req[key]:-}" ]] || {
      tm_error "A plain port forward has no GRE key."
      return 1
    }
  else
    tm_tunnel_pair_ok "${_tm_req[local_tunnel_ip]}" "${_tm_req[remote_tunnel_ip]}" "${_tm_req[cidr]}" || {
      tm_error "Tunnel addresses must be different hosts in the same prefix. IPv4 uses 24-31. IPv6 uses 64-127."
      return 1
    }
    tm_valid_gre_key "${_tm_req[key]:-}" || {
      tm_error "GRE key must be a number from 1 to 4294967295."
      return 1
    }
  fi
  tm_valid_mtu "${_tm_req[mtu]}" || {
    tm_error "MTU must be between 1280 and 1500."
    return 1
  }
  return 0
}

# The kernel keeps one GRE link per local address, remote address, and key.
tm_tunnel_pair_owner() {
  local local_pub="$1"
  local remote_pub="$2"
  local key="${3:-}"
  local name want_local want_remote
  local -A row=()
  want_local=$(tm_ip_canonical "$local_pub") || return 1
  want_remote=$(tm_ip_canonical "$remote_pub") || return 1
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_tunnel_load "$name" row || continue
    [[ "${row[TM_TUNNEL_TYPE]:-}" == "gre" && "${row[TM_GRE_KEY]:-}" == "$key" ]] || continue
    if [[ "$(tm_ip_canonical "${row[TM_LOCAL_PUBLIC_IP]:-}" || true)" == "$want_local" \
      && "$(tm_ip_canonical "${row[TM_REMOTE_PUBLIC_IP]:-}" || true)" == "$want_remote" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(tm_list_tunnels)
  return 1
}

tm_tunnel_inner_owner() {
  local local_tun="$1"
  local cidr="$2"
  local name
  local -A row=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_tunnel_load "$name" row || continue
    [[ "${row[TM_TUNNEL_TYPE]:-}" == "gre" ]] || continue
    if tm_ip_subnets_overlap "${row[TM_LOCAL_TUNNEL_IP]:-}" "${row[TM_TUNNEL_CIDR]:-}" "$local_tun" "$cidr"; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(tm_list_tunnels)
  return 1
}

# Prints "IFACE ADDR PREFIX" for each address on this host, including the peer
# side of point-to-point links. Read-only, so it also runs during dry-run.
tm_host_addresses() {
  local line i iface addr prefix word
  local -a words=()
  while IFS= read -r line; do
    IFS=$' \t\n' read -r -a words <<<"$line"
    iface="${words[1]:-}"
    iface="${iface%:}"
    iface="${iface%%@*}"
    [[ -n "$iface" ]] || continue
    for ((i = 2; i + 1 < ${#words[@]}; i++)); do
      word="${words[$i]}"
      [[ "$word" == "inet" || "$word" == "inet6" || "$word" == "peer" ]] || continue
      addr="${words[$((i + 1))]}"
      prefix=""
      if [[ "$addr" == */* ]]; then
        prefix="${addr#*/}"
        addr="${addr%%/*}"
      fi
      if tm_valid_ipv4 "$addr"; then
        [[ -n "$prefix" ]] || prefix=32
      elif tm_valid_ipv6 "$addr"; then
        [[ -n "$prefix" ]] || prefix=128
      else
        continue
      fi
      printf '%s %s %s\n' "$iface" "$addr" "$prefix"
    done
  done < <(TM_DRY_RUN=0 tm_run_quiet ip -o addr show 2>/dev/null || true)
}

tm_tunnel_host_owner() {
  local local_tun="$1"
  local cidr="$2"
  local skip="${3:-}"
  local iface addr prefix
  while IFS=' ' read -r iface addr prefix; do
    [[ -n "$addr" && "$iface" != "$skip" ]] || continue
    if tm_inner_clashes_with "$addr" "$prefix" "$local_tun" "$cidr"; then
      printf '%s %s/%s\n' "$iface" "$addr" "$prefix"
      return 0
    fi
  done < <(tm_host_addresses)
  return 1
}

tm_tunnel_reject_conflicts() {
  local -n _tm_new=$1
  local other
  [[ "${_tm_new[type]}" == "gre" ]] || return 0
  if other=$(tm_tunnel_pair_owner "${_tm_new[local_public_ip]}" "${_tm_new[remote_public_ip]}" "${_tm_new[key]:-}"); then
    tm_error "GRE tunnel ${other} already connects ${_tm_new[local_public_ip]} and ${_tm_new[remote_public_ip]} with the same key. Add ports to ${other} instead."
    return 1
  fi
  if other=$(tm_tunnel_inner_owner "${_tm_new[local_tunnel_ip]}" "${_tm_new[cidr]}"); then
    tm_error "Inner subnet ${_tm_new[local_tunnel_ip]}/${_tm_new[cidr]} overlaps tunnel ${other}. Choose other inner addresses."
    return 1
  fi
  if other=$(tm_tunnel_host_owner "${_tm_new[local_tunnel_ip]}" "${_tm_new[cidr]}" "$(tm_tunnel_iface "${_tm_new[name]}")"); then
    tm_error "Inner subnet ${_tm_new[local_tunnel_ip]}/${_tm_new[cidr]} clashes with ${other#* } on ${other%% *}, which another tool manages. Choose other inner addresses."
    return 1
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
  local mtu="$9"
  local wan="${10}"
  local key="${11:-}"
  local -a pairs=(
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
  )
  if [[ -n "$key" ]]; then
    pairs+=(TM_GRE_KEY "$key")
  fi
  tm_ensure_tree || return 1
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
  if [[ "${row[TM_TUNNEL_TYPE]}" == "forward" ]]; then
    return 0
  fi
  if [[ "${row[TM_TUNNEL_TYPE]}" != "gre" ]]; then
    tm_error "Tunnel ${name} has unsupported type ${row[TM_TUNNEL_TYPE]}."
    return 1
  fi
  tm_gre_up_exec "$name" "${row[TM_LOCAL_PUBLIC_IP]}" "${row[TM_REMOTE_PUBLIC_IP]}" \
    "${row[TM_LOCAL_TUNNEL_IP]}" "${row[TM_TUNNEL_CIDR]}" "${row[TM_MTU]}" "${row[TM_GRE_KEY]:-}" || return 1
  tm_rp_filter_apply_exec "$iface" || return 1
  tm_fw_input_apply_exec "$name" "${row[TM_WAN_IFACE]}" "${row[TM_REMOTE_PUBLIC_IP]}" "$family" || return 1
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
  if [[ "${row[TM_TUNNEL_TYPE]}" == "forward" ]]; then
    return 0
  fi
  if [[ "${row[TM_TUNNEL_TYPE]}" != "gre" ]]; then
    tm_error "Tunnel ${name} has unsupported type ${row[TM_TUNNEL_TYPE]}."
    return 1
  fi
  tm_fw_input_delete_exec "$name" "$family" || return 1
  tm_gre_down_exec "$name" || return 1
}

tm_action_tunnel_create() {
  local -A opt=()
  local -A req=()
  local link_kind status=0
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  req[name]=$(tm_opt_get opt name)
  req[type]=$(tm_opt_get opt type)
  req[local_public_ip]=$(tm_opt_get opt local_public_ip)
  req[remote_public_ip]=$(tm_opt_get opt remote_public_ip)
  req[local_tunnel_ip]=$(tm_opt_get opt local_tunnel_ip)
  req[remote_tunnel_ip]=$(tm_opt_get opt remote_tunnel_ip)
  req[cidr]=$(tm_opt_get opt cidr)
  req[mtu]=$(tm_opt_get opt mtu)
  req[wan_iface]=$(tm_opt_get opt wan_iface)
  req[key]=$(tm_opt_get opt key)
  tm_tunnel_validate_request req || tm_die "Tunnel validation failed."
  if [[ -f "$(tm_tunnel_file "${req[name]}")" ]]; then
    tm_die "Tunnel ${req[name]} already exists."
  fi
  tm_tunnel_reject_conflicts req || tm_die "Tunnel validation failed."
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Prepare Tunnel Manager directories" \
    "$(tm_shell_quote tm_noop)" \
    tm_ensure_tree
  tm_plan_add "Write tunnel state ${req[name]} (active). The default route is not changed." \
    "$(tm_shell_quote tm_tunnel_state_undo "${req[name]}")" \
    tm_tunnel_state_write_exec "${req[name]}" "${req[type]}" active \
      "${req[local_public_ip]}" "${req[remote_public_ip]}" \
      "${req[local_tunnel_ip]}" "${req[remote_tunnel_ip]}" "${req[cidr]}" \
      "${req[mtu]}" "${req[wan_iface]}" "${req[key]:-}"
  if [[ "${req[type]}" == "forward" ]]; then
    tm_plan_add "Save port-forward ${req[name]}. No tunnel interface is created." \
      "$(tm_shell_quote tm_tunnel_stop_exec "${req[name]}")" \
      tm_tunnel_start_exec "${req[name]}"
  else
    link_kind="${req[type]}"
    if [[ "$link_kind" == "gre" && "$(tm_ip_family "${req[local_public_ip]}")" == "6" ]]; then
      link_kind="ip6gre"
    fi
    tm_plan_add "Start ${link_kind} tunnel ${req[name]} on $(tm_tunnel_iface "${req[name]}") with GRE key ${req[key]}" \
      "$(tm_shell_quote tm_tunnel_stop_exec "${req[name]}")" \
      tm_tunnel_start_exec "${req[name]}"
  fi
  tm_require_change_privileges
  tm_with_lock tm_plan_apply || status=$?
  return "$status"
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
  tm_tunnel_load "$name" row || return 1
  [[ -n "${row[TM_TUNNEL_NAME]}" ]] || return 1
  tm_snapshot_file "$(tm_tunnel_file "$name")" || return 1
  tm_tunnel_stop_exec "$name" || return 1
  tm_tunnel_state_undo "$name" || return 1
}

tm_tunnel_remove_undo() {
  local name="$1"
  tm_restore_snapshot "$(tm_tunnel_file "$name")" || return 1
  if [[ -f "$(tm_tunnel_file "$name")" ]]; then
    tm_tunnel_start_exec "$name" || return 1
  fi
}

tm_action_tunnel_delete() {
  local -A opt=()
  local name line="" fname="" proto=""
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt name name
  name="${opt[name]}"
  [[ -f "$(tm_tunnel_file "$name")" ]] || tm_die "Tunnel ${name} was not found."
  tm_plan_require_clear_journal
  tm_plan_reset
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$' \t\n' read -r fname proto _rest <<<"$line"
    [[ -n "$fname" && -n "$proto" ]] || continue
    tm_plan_add "Remove ${proto} forward '${fname}' for tunnel ${name}" \
      "$(tm_shell_quote tm_forward_delete_undo "$fname" "$proto")" \
      tm_forward_delete_exec "$fname" "$proto"
  done < <(tm_setup_forwards_for "$name")
  tm_plan_add "Stop ${name} and remove its runtime and configuration" \
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
  if [[ -z "$(tm_list_tunnels)" ]]; then
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
    printf '%s=%s\n' "$key" "${row[$key]}"
  done
}

tm_action_tunnel_test() {
  local -A opt=()
  local -A row=()
  local name iface ok=0
  tm_opts_parse opt "$@"
  tm_opt_require opt name name
  name="${opt[name]}"
  tm_tunnel_load "$name" row || tm_die "Tunnel ${name} was not found."
  if [[ "${row[TM_TUNNEL_TYPE]}" == "forward" ]]; then
    tm_info "[PASS] Port forward ${name} has no tunnel interface."
    tm_info "Saved forwards use ${row[TM_LOCAL_TUNNEL_IP]} -> ${row[TM_REMOTE_TUNNEL_IP]}."
    return 0
  fi
  iface=$(tm_tunnel_iface "$name")
  if tm_iface_exists "$iface"; then
    tm_info "[PASS] Interface ${iface} exists."
  else
    tm_error "[FAIL] Interface ${iface} is not present."
    ok=1
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

