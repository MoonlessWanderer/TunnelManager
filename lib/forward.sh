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
  tm_l4_proto_ok "$proto" || return 1
  path=$(tm_forward_file "$name")
  if [[ -f "$path" ]]; then
    tm_safe_rm "$path" || return 1
  fi
  tm_fw_forward_delete_exec "$name" || return 1
  tm_sysctl_sync_exec || return 1
}

tm_forward_runtime_present() {
  local name="$1"
  local -A row=()
  local backend comment text
  tm_forward_load "$name" row || return 1
  comment=$(tm_fw_comment "${row[TM_FORWARD_PROTO]}:${name}:dnat")
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
  local_tun="${row[TM_SOURCE_IP]}"
  peer_tun="${row[TM_DEST_IP]}"
  decision=$(tm_fw_snat_decision "${row[TM_SNAT]}" "${row[TM_DEST_IP]}" "$local_tun" "$peer_tun") || return 1
  tm_fw_l4_apply_exec "${row[TM_FORWARD_PROTO]}" "$name" "${row[TM_INGRESS_IFACE]}" "${row[TM_LISTEN_PORT]}" \
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
  if [[ "$(tm_ip_family "$dest_ip")" == "6" || "$(tm_ip_family "$source_ip")" == "6" || "$(tm_ip_family "$listen_ip")" == "6" ]]; then
    tm_error "Port forwarding supports IPv4 only."
    return 1
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

# Succeeds when a firewall rule line matches PORT through --dport, --dports,
# or an nft dport value, list, or range.
tm_fw_line_has_dport() {
  local line="$1"
  local port="$2"
  local value item lo hi i j
  local -a words=() items=()
  IFS=$' \t\n' read -r -a words <<<"$line"
  for ((i = 0; i + 1 < ${#words[@]}; i++)); do
    case "${words[$i]}" in
      --dport|--dports|--destination-port|--destination-ports|dport) ;;
      *) continue ;;
    esac
    value="${words[$((i + 1))]}"
    if [[ "$value" == "{" ]]; then
      value=""
      for ((j = i + 2; j < ${#words[@]}; j++)); do
        [[ "${words[$j]}" != "}" ]] || break
        value+="${words[$j]}"
      done
    fi
    IFS=',' read -r -a items <<<"$value"
    for item in "${items[@]}"; do
      item="${item//-/:}"
      if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
        lo=${BASH_REMATCH[1]}
        hi=${BASH_REMATCH[2]}
        if ((10#$port >= 10#$lo && 10#$port <= 10#$hi)); then
          return 0
        fi
      elif [[ "$item" == "$port" ]]; then
        return 0
      fi
    done
  done
  return 1
}

# Succeeds when a DNAT or REDIRECT rule that Tunnel Manager did not make takes
# this port. Both iptables and nft are read, because either can hook the host.
tm_fw_foreign_redirect() {
  local proto="$1"
  local port="$2"
  local line table=""
  while IFS= read -r line; do
    [[ "$line" == "-A "* && "$line" == *"-p ${proto} "* ]] || continue
    [[ "$line" == *"-j DNAT"* || "$line" == *"-j REDIRECT"* ]] || continue
    [[ "$line" != *"--comment tm:"* && "$line" != *'--comment "tm:'* ]] || continue
    tm_fw_line_has_dport "$line" "$port" && return 0
  done < <(TM_DRY_RUN=0 tm_run_quiet iptables -t nat -S 2>/dev/null || true)
  while IFS= read -r line; do
    if [[ "$line" =~ ^table[[:space:]]+([a-z0-9]+)[[:space:]]+([A-Za-z0-9_-]+) ]]; then
      table="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
      continue
    fi
    [[ "$table" != "inet tunnel_manager" && "$line" != *'comment "tm:'* ]] || continue
    [[ "$line" == *" dnat "* || "$line" == *" redirect"* ]] || continue
    [[ "$line" == *"${proto} dport "* || "$line" == *"th dport "* ]] || continue
    tm_fw_line_has_dport "$line" "$port" && return 0
  done < <(TM_DRY_RUN=0 tm_run_quiet nft list ruleset 2>/dev/null || true)
  return 1
}

# Prints what already takes this port outside Tunnel Manager. A listener on
# loopback only is ignored, because traffic from the WAN cannot reach it.
tm_forward_port_user() {
  local proto="$1"
  local port="$2"
  local flag="-t" line local_addr
  local -a cols=()
  if [[ "$proto" == "udp" ]]; then
    flag="-u"
  fi
  while IFS= read -r line; do
    IFS=$' \t\n' read -r -a cols <<<"$line"
    [[ "${cols[0]:-}" != "State" && "${cols[0]:-}" != "Netid" ]] || continue
    local_addr="${cols[3]:-}"
    case "$local_addr" in
      ""|127.*|"[::1]"*|*%lo:*) continue ;;
    esac
    printf '%s\n' "a local ${proto} service on ${local_addr}"
    return 0
  done < <(TM_DRY_RUN=0 tm_run_quiet ss -H -l -n "$flag" sport = ":${port}" 2>/dev/null || true)
  if tm_fw_foreign_redirect "$proto" "$port"; then
    printf '%s\n' "a NAT rule from another tool"
    return 0
  fi
  return 1
}

tm_forward_reject_port_user() {
  local proto="$1"
  local port="$2"
  local user
  if user=$(tm_forward_port_user "$proto" "$port"); then
    tm_error "Port ${port}/${proto} is already used by ${user}. Choose another port, or stop that first."
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
    [[ -n "$ingress" ]] || ingress="${tun[TM_WAN_IFACE]:-}"
  fi
  [[ -n "$dest_ip" ]] || tm_die "Missing required option --dest-ip."
  [[ -n "$listen_port" ]] || tm_die "Missing required option --listen-port."
  [[ -n "$name" && -n "$proto" && -n "$ingress" && -n "$source_ip" ]] || tm_die "Missing forward options. Need --name, --proto, --listen-port, --dest-ip, --ingress-iface, and --source-ip or --tunnel."
  tm_forward_validate_common "$name" "$proto" "$listen_ip" "$listen_port" "$dest_ip" "$dest_port" "$snat" "$ingress" "$source_ip" || tm_die "Forward validation failed."
  if [[ -f "$(tm_forward_file "$name")" ]]; then
    tm_die "Forward ${name} already exists."
  fi
  tm_forward_reject_port_user "$proto" "$listen_port" || tm_die "Forward validation failed."
  decision=$(tm_fw_snat_decision "$snat" "$dest_ip" "$source_ip" "$dest_ip") || tm_die "Cannot decide SNAT."
  if [[ "$dest_ip" != "$source_ip" && "$dest_ip" != "${tun[TM_REMOTE_TUNNEL_IP]:-}" ]]; then
    tm_warn "No route will be added for ${dest_ip}. It must already be reachable, usually through the tunnel subnet."
  fi
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Write ${proto} forward '${name}' (${listen_ip}:${listen_port} -> ${dest_ip}:${dest_port}, snat ${snat})" \
    "$(tm_shell_quote tm_forward_file_undo "$name" "$proto")" \
    tm_forward_file_write_exec "$name" "$proto" "$listen_ip" "$listen_port" "$dest_ip" "$dest_port" "$snat" "$ingress" "$source_ip" "$tunnel_ref"
  tm_plan_add "Install ${proto} DNAT ${ingress}:${listen_port} -> ${dest_ip}:${dest_port} (snat ${decision}) using dedicated chains" \
    "$(tm_shell_quote tm_fw_l4_delete_exec "$proto" "$name")" \
    tm_fw_l4_apply_exec "$proto" "$name" "$ingress" "$listen_port" "$dest_ip" "$dest_port" "$source_ip" "$decision"
  tm_plan_add "Synchronize net.ipv4.ip_forward for saved forwards" \
    "$(tm_shell_quote tm_sysctl_sync_exec)" \
    tm_sysctl_sync_exec
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
  tm_l4_proto_ok "$proto" || return 1
  tm_restore_snapshot "$(tm_forward_file "$name")" || return 1
  tm_forward_apply_saved "$name" || return 1
  tm_sysctl_sync_exec || return 1
}

tm_forward_orphan_lines() {
  local name ref
  local -A row=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_forward_load "$name" row || continue
    ref="${row[TM_TUNNEL_REF]:-none}"
    if [[ -n "$ref" && "$ref" != "none" && ! -f "$(tm_tunnel_file "$ref")" ]]; then
      printf '%s %s %s %s\n' "$name" "${row[TM_FORWARD_PROTO]:-tcp}" \
        "${row[TM_LISTEN_PORT]:-}" "$ref"
    fi
  done < <(tm_list_forwards)
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
  if [[ "$proto" != "${row[TM_FORWARD_PROTO]}" || "$listen_port" != "${row[TM_LISTEN_PORT]}" ]]; then
    tm_forward_reject_port_user "$proto" "$listen_port" || tm_die "Forward validation failed."
  fi
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
  tm_fw_forward_delete_exec "$name" || return 1
  tm_restore_snapshot "$(tm_forward_file "$name")" || return 1
  if [[ -f "$(tm_forward_file "$name")" ]]; then
    tm_forward_apply_saved "$name" || return 1
  fi
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
  tm_l4_proto_ok "$old_proto" || return 1
  tm_snapshot_file "$(tm_forward_file "$name")" || return 1
  tm_forward_file_write_exec "$name" "$proto" "$listen_ip" "$listen_port" "$dest_ip" "$dest_port" "$snat" "$ingress" "$source_ip" "$tunnel_ref" || return 1
  tm_fw_forward_delete_exec "$name" || return 1
  tm_forward_apply_saved "$name" || return 1
  tm_sysctl_sync_exec || return 1
}

tm_action_forward_list() {
  local name proto
  local -A row=()
  if [[ -z "$(tm_list_forwards)" ]]; then
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
  if tm_forward_runtime_present "$name"; then
    tm_info "[PASS] Firewall DNAT rule is present."
  else
    tm_warn "[WARN] Firewall DNAT rule is not present. Run apply to install it."
  fi
  tm_info "Payload delivery cannot be confirmed without the application."
  tm_warn "[WARN] End-to-end success is not claimed by this test."
  return "$ok"
}
