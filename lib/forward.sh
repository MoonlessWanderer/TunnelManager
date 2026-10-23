# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — TCP and UDP port-forward records and runtime sync.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "forward.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_FORWARD_LOADED:-}" ]]; then
  return 0
fi
TM_FORWARD_LOADED=1

tm_forward_clear_row() {
  local -n _tm_clear=$1
  local key
  for key in "${!_tm_clear[@]}"; do
    unset "_tm_clear[$key]"
  done
}

tm_forward_load() {
  local name="$1"
  local -n _tm_row=$2
  tm_forward_clear_row _tm_row
  tm_kv_read "$(tm_forward_file "$name")" _tm_row
}

tm_forward_listen_conflict() {
  local name="$1"
  local proto="$2"
  local listen_ip="$3"
  local listen_port="$4"
  local other
  local -A row=()
  while IFS= read -r other; do
    [[ -n "$other" && "$other" != "$name" ]] || continue
    tm_forward_load "$other" row || continue
    if [[ "${row[TM_FORWARD_PROTO]:-}" == "$proto" \
      && "${row[TM_LISTEN_IP]:-}" == "$listen_ip" \
      && "${row[TM_LISTEN_PORT]:-}" == "$listen_port" ]]; then
      return 0
    fi
  done < <(tm_list_forwards)
  return 1
}

tm_forward_file_write_exec() {
  local name="$1"
  local proto="$2"
  local listen_ip="$3"
  local listen_port="$4"
  local dest_ip="$5"
  local dest_port="$6"
  local snat="$7"
  local ingress="$8"
  local source_ip="$9"
  local tunnel_ref="${10:-none}"
  tm_ensure_tree || return 1
  if [[ -z "$tunnel_ref" ]]; then
    tunnel_ref="none"
  fi
  tm_kv_write "$(tm_forward_file "$name")" 0600 \
    TM_FORWARD_NAME "$name" \
    TM_FORWARD_PROTO "$proto" \
    TM_LISTEN_IP "$listen_ip" \
    TM_LISTEN_PORT "$listen_port" \
    TM_DEST_IP "$dest_ip" \
    TM_DEST_PORT "$dest_port" \
    TM_SNAT "$snat" \
    TM_INGRESS_IFACE "$ingress" \
    TM_SOURCE_IP "$source_ip" \
    TM_TUNNEL_REF "$tunnel_ref"
}

tm_forward_file_undo() {
  local name="$1"
  local proto="$2"
  local path
  path=$(tm_forward_file "$name")
  if [[ -f "$path" ]]; then
    tm_safe_rm "$path" || return 1
  fi
  if [[ "$proto" == "udp" ]]; then
    tm_fw_udp_delete_exec "$name" || return 1
  else
    tm_haproxy_sync_exec || return 1
  fi
  tm_sysctl_sync_exec || return 1
}

tm_forward_runtime_present() {
  local name="$1"
  local -A row=()
  local backend comment text
  tm_forward_load "$name" row || return 1
  if [[ "${row[TM_FORWARD_PROTO]}" == "tcp" ]]; then
    [[ -f "$TM_HAPROXY_CFG" ]] || return 1
    grep -q "frontend $(tm_haproxy_ident "$name")_fe" "$TM_HAPROXY_CFG"
    return
  fi
  comment=$(tm_fw_comment "udp:${name}:dnat")
  backend=$(tm_fw_active_backend) || return 1
  if [[ "$backend" == "iptables" ]]; then
    text=$(tm_iptables_chain_rules nat TM_PREROUTING || true)
    [[ "$text" == *"$comment"* ]]
    return
  fi
  tm_nft_comment_present prerouting "$comment"
}

tm_forward_ensure_exec() {
  local name="$1"
  local mark="${TM_VAR}/fwd-${name}.mark"
  mkdir -p -- "$TM_VAR" || return 1
  if tm_forward_runtime_present "$name"; then
    printf 'kept\n' >"$mark"
  else
    printf 'started\n' >"$mark"
  fi
  chmod 0600 "$mark" || true
  tm_forward_apply_saved "$name"
}

tm_forward_ensure_undo() {
  local name="$1"
  local mark="${TM_VAR}/fwd-${name}.mark"
  local mode="started"
  if [[ -f "$mark" ]]; then
    mode=$(tr -d '[:space:]' <"$mark")
  fi
  if [[ "$mode" == "started" ]]; then
    tm_forward_down_exec "$name" || return 1
  fi
  if [[ -f "$mark" ]]; then
    tm_safe_rm "$mark" || return 1
  fi
}

tm_forward_apply_saved() {
  local name="$1"
  local -A row=()
  local decision="no" local_tun="" peer_tun=""
  tm_forward_load "$name" row || return 1
  if [[ "${row[TM_FORWARD_PROTO]}" == "tcp" ]]; then
    tm_haproxy_sync_exec || return 1
    return 0
  fi
  local_tun="${row[TM_SOURCE_IP]}"
  peer_tun="${row[TM_DEST_IP]}"
  decision=$(tm_fw_snat_decision "${row[TM_SNAT]}" "${row[TM_DEST_IP]}" "$local_tun" "$peer_tun") || return 1
  tm_fw_udp_apply_exec "$name" "${row[TM_INGRESS_IFACE]}" "${row[TM_LISTEN_PORT]}" \
    "${row[TM_DEST_IP]}" "${row[TM_DEST_PORT]}" "${row[TM_SOURCE_IP]}" "$decision" || return 1
}

tm_forward_validate_common() {
  local name="$1"
  local proto="$2"
  local listen_ip="$3"
  local listen_port="$4"
  local dest_ip="$5"
  local dest_port="$6"
  local snat="$7"
  local ingress="$8"
  local source_ip="$9"
  tm_valid_forward_name "$name" || {
    tm_error "Invalid forward name."
    return 1
  }
  tm_valid_l4_proto "$proto" || {
    tm_error "Protocol must be tcp or udp."
    return 1
  }
  tm_valid_listen_ip "$listen_ip" || {
    tm_error "Invalid listen IP."
    return 1
  }
  tm_valid_port "$listen_port" || {
    tm_error "Invalid listen port."
    return 1
  }
  tm_valid_port "$dest_port" || {
    tm_error "Invalid destination port."
    return 1
  }
  tm_ip_is_unicast_host "$dest_ip" || {
    tm_error "Invalid destination IP."
    return 1
  }
  tm_valid_snat_mode "$snat" || {
    tm_error "SNAT mode must be auto, always, or never."
    return 1
  }
  tm_valid_iface "$ingress" || {
    tm_error "Invalid ingress interface."
    return 1
  }
  tm_ip_is_unicast_host "$source_ip" || {
    tm_error "Invalid source IP. Pass --source-ip or --tunnel."
    return 1
  }
  if [[ "$(tm_ip_family "$dest_ip")" != "$(tm_ip_family "$source_ip")" ]]; then
    tm_error "Source and destination addresses must use the same IP family."
    return 1
  fi
  if [[ "$proto" == "udp" ]]; then
    if [[ "$(tm_ip_family "$dest_ip")" == "6" || "$(tm_ip_family "$listen_ip")" == "6" ]]; then
      tm_error "UDP forwarding supports IPv4 only. TCP forwarding can use IPv6."
      return 1
    fi
  fi
  tm_ssh_port >/dev/null
  if tm_port_is_protected "$listen_port"; then
    tm_error "Refusing to listen on protected port ${listen_port}. That would risk cutting off SSH."
    return 1
  fi
  if tm_forward_listen_conflict "$name" "$proto" "$listen_ip" "$listen_port"; then
    tm_error "A ${proto} forward already listens on ${listen_ip}:${listen_port}."
    return 1
  fi
  return 0
}

tm_action_forward_add() {
  local -A opt=()
  local name proto listen_ip listen_port dest_ip dest_port snat ingress source_ip tunnel_ref decision
  local -A tun=()
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  name=$(tm_opt_get opt name)
  proto=$(tm_opt_get opt proto)
  listen_ip=$(tm_opt_get opt listen_ip "0.0.0.0")
  listen_port=$(tm_opt_get opt listen_port)
  dest_port=$(tm_opt_get opt dest_port "$listen_port")
  snat=$(tm_opt_get opt snat "auto")
  ingress=$(tm_opt_get opt ingress_iface)
  source_ip=$(tm_opt_get opt source_ip)
  dest_ip=$(tm_opt_get opt dest_ip)
  tunnel_ref=$(tm_opt_get opt tunnel "none")
  if [[ -z "$ingress" && -f "$(tm_host_file)" ]]; then
    local -A host=()
    if tm_load_host host; then
      ingress="${host[TM_HOST_WAN_IFACE]:-}"
    fi
  fi
  if [[ "$tunnel_ref" != "none" && -n "$tunnel_ref" ]]; then
    tm_valid_tunnel_name "$tunnel_ref" || tm_die "Invalid tunnel name."
    tm_kv_read "$(tm_tunnel_file "$tunnel_ref")" tun || tm_die "Tunnel ${tunnel_ref} was not found."
    [[ -n "$source_ip" ]] || source_ip="${tun[TM_LOCAL_TUNNEL_IP]}"
    [[ -n "$dest_ip" ]] || dest_ip="${tun[TM_REMOTE_TUNNEL_IP]}"
  fi
  [[ -n "$dest_ip" ]] || tm_die "Missing required option --dest-ip."
  [[ -n "$listen_port" ]] || tm_die "Missing required option --listen-port."
  [[ -n "$name" && -n "$proto" && -n "$ingress" && -n "$source_ip" ]] || tm_die "Missing forward options. Need --name, --proto, --listen-port, --dest-ip, --ingress-iface, and --source-ip or --tunnel."
  tm_forward_validate_common "$name" "$proto" "$listen_ip" "$listen_port" "$dest_ip" "$dest_port" "$snat" "$ingress" "$source_ip" || tm_die "Forward validation failed."
  if [[ -f "$(tm_forward_file "$name")" ]]; then
    tm_die "Forward ${name} already exists."
  fi
  decision=$(tm_fw_snat_decision "$snat" "$dest_ip" "$source_ip" "$dest_ip") || tm_die "Cannot decide SNAT."
  if [[ "$dest_ip" != "$source_ip" ]]; then
    tm_warn "No route will be added for ${dest_ip}. It must already be reachable, usually through the tunnel subnet."
  fi
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Write ${proto} forward '${name}' (${listen_ip}:${listen_port} -> ${dest_ip}:${dest_port}, snat ${snat})" \
    "$(tm_shell_quote tm_forward_file_undo "$name" "$proto")" \
    tm_forward_file_write_exec "$name" "$proto" "$listen_ip" "$listen_port" "$dest_ip" "$dest_port" "$snat" "$ingress" "$source_ip" "$tunnel_ref"
  if [[ "$proto" == "udp" ]]; then
    tm_plan_add "Install UDP DNAT ${ingress}:${listen_port} -> ${dest_ip}:${dest_port} (snat ${decision}) using dedicated chains" \
      "$(tm_shell_quote tm_fw_udp_delete_exec "$name")" \
      tm_fw_udp_apply_exec "$name" "$ingress" "$listen_port" "$dest_ip" "$dest_port" "$source_ip" "$decision"
    tm_plan_add "Synchronize net.ipv4.ip_forward for saved UDP forwards" \
      "$(tm_shell_quote tm_sysctl_sync_exec)" \
      tm_sysctl_sync_exec
  else
    tm_plan_add "Validate HAProxy configuration and reload the dedicated Tunnel Manager instance" \
      "$(tm_shell_quote tm_haproxy_sync_undo)" \
      tm_haproxy_sync_exec
  fi
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_forward_delete_exec() {
  local name="$1"
  local proto="$2"
  tm_snapshot_file "$(tm_forward_file "$name")" || return 1
  tm_forward_file_undo "$name" "$proto"
}

tm_forward_delete_undo() {
  local name="$1"
  local proto="$2"
  tm_restore_snapshot "$(tm_forward_file "$name")" || return 1
  if [[ "$proto" == "udp" ]]; then
    tm_forward_apply_saved "$name" || return 1
    tm_sysctl_sync_exec || return 1
  else
    tm_haproxy_sync_exec || return 1
  fi
}

tm_action_forward_delete() {
  local -A opt=()
  local name proto
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt name name
  name="${opt[name]}"
  [[ -f "$(tm_forward_file "$name")" ]] || tm_die "Forward ${name} was not found."
  proto=$(tm_forward_proto "$name") || tm_die "Forward ${name} cannot be read."
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Remove ${proto} forward '${name}' and its runtime rules" \
    "$(tm_shell_quote tm_forward_delete_undo "$name" "$proto")" \
    tm_forward_delete_exec "$name" "$proto"
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_action_forward_edit() {
  local -A opt=()
  local -A row=()
  local name proto listen_ip listen_port dest_ip dest_port snat ingress source_ip tunnel_ref decision
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt name name
  name="${opt[name]}"
  tm_forward_load "$name" row || tm_die "Forward ${name} was not found."
  proto=$(tm_opt_get opt proto "${row[TM_FORWARD_PROTO]}")
  listen_ip=$(tm_opt_get opt listen_ip "${row[TM_LISTEN_IP]}")
  listen_port=$(tm_opt_get opt listen_port "${row[TM_LISTEN_PORT]}")
  dest_ip=$(tm_opt_get opt dest_ip "${row[TM_DEST_IP]}")
  dest_port=$(tm_opt_get opt dest_port "${row[TM_DEST_PORT]}")
  snat=$(tm_opt_get opt snat "${row[TM_SNAT]}")
  ingress=$(tm_opt_get opt ingress_iface "${row[TM_INGRESS_IFACE]}")
  source_ip=$(tm_opt_get opt source_ip "${row[TM_SOURCE_IP]}")
  tunnel_ref=$(tm_opt_get opt tunnel "${row[TM_TUNNEL_REF]:-none}")
  tm_forward_validate_common "$name" "$proto" "$listen_ip" "$listen_port" "$dest_ip" "$dest_port" "$snat" "$ingress" "$source_ip" || tm_die "Forward validation failed."
  decision=$(tm_fw_snat_decision "$snat" "$dest_ip" "$source_ip" "$dest_ip") || tm_die "Cannot decide SNAT."
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Update ${proto} forward '${name}' (${listen_ip}:${listen_port} -> ${dest_ip}:${dest_port}, snat ${snat}/${decision})" \
    "$(tm_shell_quote tm_forward_edit_undo "$name")" \
    tm_forward_edit_exec "$name" "$proto" "$listen_ip" "$listen_port" "$dest_ip" "$dest_port" "$snat" "$ingress" "$source_ip" "$tunnel_ref" "${row[TM_FORWARD_PROTO]}"
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_forward_edit_undo() {
  local name="$1"
  local proto
  tm_fw_udp_delete_exec "$name" || return 1
  tm_restore_snapshot "$(tm_forward_file "$name")" || return 1
  if [[ -f "$(tm_forward_file "$name")" ]]; then
    proto=$(tm_forward_proto "$name") || return 1
    if [[ "$proto" == "udp" ]]; then
      tm_forward_apply_saved "$name" || return 1
    fi
  fi
  tm_haproxy_sync_exec || return 1
  tm_sysctl_sync_exec || return 1
}

tm_forward_edit_exec() {
  local name="$1"
  local proto="$2"
  local listen_ip="$3"
  local listen_port="$4"
  local dest_ip="$5"
  local dest_port="$6"
  local snat="$7"
  local ingress="$8"
  local source_ip="$9"
  local tunnel_ref="${10}"
  local old_proto="${11}"
  tm_snapshot_file "$(tm_forward_file "$name")" || return 1
  tm_forward_file_write_exec "$name" "$proto" "$listen_ip" "$listen_port" "$dest_ip" "$dest_port" "$snat" "$ingress" "$source_ip" "$tunnel_ref" || return 1
  if [[ "$old_proto" == "udp" && "$proto" != "udp" ]]; then
    tm_fw_udp_delete_exec "$name" || return 1
  fi
  if [[ "$proto" == "udp" ]]; then
    tm_forward_apply_saved "$name" || return 1
    tm_sysctl_sync_exec || return 1
  else
    tm_haproxy_sync_exec || return 1
    tm_sysctl_sync_exec || return 1
  fi
}

tm_action_forward_list() {
  local name proto
  local -A row=()
  if ! tm_list_forwards | grep -q .; then
    tm_info "No forwards are saved."
    return 0
  fi
  printf '%-16s %-5s %-22s %-22s %-8s\n' "NAME" "PROTO" "LISTEN" "DESTINATION" "SNAT"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_forward_load "$name" row || continue
    proto=${row[TM_FORWARD_PROTO]}
    printf '%-16s %-5s %-22s %-22s %-8s\n' \
      "$name" "$proto" \
      "${row[TM_LISTEN_IP]}:${row[TM_LISTEN_PORT]}" \
      "${row[TM_DEST_IP]}:${row[TM_DEST_PORT]}" \
      "${row[TM_SNAT]}"
  done < <(tm_list_forwards)
}

tm_action_forward_test() {
  local -A opt=()
  local name
  local -A row=()
  local ok=0
  tm_opts_parse opt "$@"
  tm_opt_require opt name name
  name="${opt[name]}"
  tm_forward_load "$name" row || tm_die "Forward ${name} was not found."
  tm_info "Forward ${name}: ${row[TM_FORWARD_PROTO]} ${row[TM_LISTEN_IP]}:${row[TM_LISTEN_PORT]} -> ${row[TM_DEST_IP]}:${row[TM_DEST_PORT]}"
  if [[ "${row[TM_FORWARD_PROTO]}" == "tcp" ]]; then
    if tm_cmd_available haproxy; then
      if [[ -f "$TM_HAPROXY_CFG" ]] && tm_run haproxy -c -f "$TM_HAPROXY_CFG" >/dev/null 2>&1; then
        tm_info "[PASS] HAProxy configuration is valid."
      else
        tm_error "[FAIL] HAProxy configuration is missing or invalid."
        ok=1
      fi
    else
      tm_warn "[WARN] haproxy is not available; configuration syntax was not checked."
    fi
    tm_info "TCP destination reachability is checked by HAProxy health checks after the service is running."
  else
    tm_info "UDP payload delivery cannot be confirmed without the application. Rule presence is checked by the firewall backend."
    tm_warn "[WARN] End-to-end UDP success is not claimed by this test."
  fi
  return "$ok"
}
