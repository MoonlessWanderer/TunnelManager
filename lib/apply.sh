# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — reconcile saved state and tear runtime down.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "apply.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_APPLY_LOADED:-}" ]]; then
  return 0
fi
TM_APPLY_LOADED=1

tm_apply_build_plan() {
  local name
  tm_plan_reset
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_plan_add "Ensure tunnel ${name} matches its saved configuration" \
      "$(tm_shell_quote tm_tunnel_ensure_undo "$name")" \
      tm_tunnel_ensure_exec "$name"
  done < <(tm_list_tunnels)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_plan_add "Ensure forward ${name} is installed in the firewall" \
      "$(tm_shell_quote tm_forward_ensure_undo "$name")" \
      tm_forward_ensure_exec "$name"
  done < <(tm_list_forwards)
  tm_plan_add "Synchronize IPv4 forwarding with saved forwards" \
    "$(tm_shell_quote tm_sysctl_sync_exec)" \
    tm_sysctl_sync_exec
  tm_plan_add "Stop a leftover HAProxy forwarder" \
    "$(tm_shell_quote tm_noop)" \
    tm_haproxy_stop_exec
}

tm_action_apply() {
  local -A opt=()
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_plan_require_clear_journal
  tm_apply_build_plan
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_down_build_plan() {
  local name
  tm_plan_reset
  tm_plan_add "Stop a leftover HAProxy forwarder" \
    "$(tm_shell_quote tm_noop)" \
    tm_haproxy_stop_exec
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_plan_add "Remove runtime rules for forward ${name}" \
      "$(tm_shell_quote tm_forward_apply_saved "$name")" \
      tm_forward_down_exec "$name"
  done < <(tm_list_forwards)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_plan_add "Stop tunnel ${name} without deleting its configuration" \
      "$(tm_shell_quote tm_tunnel_start_exec "$name")" \
      tm_tunnel_stop_exec "$name"
  done < <(tm_list_tunnels)
  tm_plan_add "Leave saved sysctl drop-in in place when forwards remain configured" \
    "$(tm_shell_quote tm_noop)" \
    tm_noop
}

tm_forward_down_exec() {
  local name="$1"
  tm_fw_forward_delete_exec "$name"
}

tm_action_down_all() {
  local -A opt=()
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_plan_require_clear_journal
  tm_down_build_plan
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_action_rollback() {
  local -A opt=()
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  if ! tm_journal_exists; then
    tm_info "No rollback journal is present."
    return 0
  fi
  tm_warn "A rollback journal will undo the interrupted operation."
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    tm_info "Dry-run: rollback was not executed."
    return 0
  fi
  if ! tm_confirm "Run rollback now?"; then
    tm_info "Rollback was not executed."
    return 2
  fi
  tm_require_change_privileges
  tm_with_lock tm_journal_rollback
}

tm_action_init() {
  local -A opt=()
  local role public_ip wan ssh_port backend
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  role=$(tm_opt_get opt role)
  public_ip=$(tm_opt_get opt public_ip)
  wan=$(tm_opt_get opt wan_iface)
  ssh_port=$(tm_opt_get opt ssh_port "22")
  backend=$(tm_opt_get opt fw_backend "auto")
  tm_valid_role "$role" || tm_die "Role must be iran or foreign."
  tm_ip_is_unicast_host "$public_ip" || tm_die "A reachable public IPv4 or IPv6 address is required."
  tm_valid_iface "$wan" || tm_die "A WAN interface name is required."
  tm_valid_port "$ssh_port" || tm_die "Invalid SSH port."
  tm_valid_fw_backend "$backend" || tm_die "Firewall backend must be auto, iptables, or nft."
  if [[ -f "$(tm_host_file)" && "${TM_YES:-0}" != "1" && "${TM_DRY_RUN:-0}" != "1" ]]; then
    tm_die "Host configuration already exists. Re-run with --yes to replace it."
  fi
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Write host role ${role} (${public_ip} on ${wan}, ssh port ${ssh_port}, firewall ${backend})" \
    "$(tm_shell_quote tm_init_undo)" \
    tm_init_write_exec "$role" "$public_ip" "$wan" "$ssh_port" "$backend"
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_init_write_exec() {
  local role="$1"
  local public_ip="$2"
  local wan="$3"
  local ssh_port="$4"
  local backend="$5"
  tm_ensure_tree || return 1
  if [[ -f "$(tm_host_file)" ]]; then
    tm_snapshot_file "$(tm_host_file)" || return 1
  fi
  tm_kv_write "$(tm_host_file)" 0600 \
    TM_HOST_ROLE "$role" \
    TM_HOST_PUBLIC_IP "$public_ip" \
    TM_HOST_WAN_IFACE "$wan" \
    TM_SSH_PORT "$ssh_port" \
    TM_FW_BACKEND "$backend" || return 1
  TM_SSH_PORT="$ssh_port"
}

tm_init_undo() {
  if [[ -f "${TM_VAR}/snapshots/$(tm_path_id "$(tm_host_file)").kind" ]]; then
    tm_restore_snapshot "$(tm_host_file)" || return 1
    return 0
  fi
  if [[ -f "$(tm_host_file)" ]]; then
    tm_safe_rm "$(tm_host_file)" || return 1
  fi
}

tm_action_status() {
  local -A host=()
  local backend="unknown"
  printf 'Tunnel Manager %s\n' "$TM_VERSION"
  if [[ -f "$(tm_host_file)" ]] && tm_load_host host; then
    printf 'role=%s\n' "${host[TM_HOST_ROLE]:-unset}"
    printf 'public_ip=%s\n' "${host[TM_HOST_PUBLIC_IP]:-unset}"
    printf 'wan_iface=%s\n' "${host[TM_HOST_WAN_IFACE]:-unset}"
    printf 'ssh_port=%s\n' "${host[TM_SSH_PORT]:-22}"
    printf 'fw_backend_setting=%s\n' "${host[TM_FW_BACKEND]:-auto}"
  else
    printf '%s\n' "host=unconfigured"
  fi
  if backend=$(TM_FW_BACKEND="${host[TM_FW_BACKEND]:-auto}" tm_fw_active_backend 2>/dev/null); then
    printf 'fw_backend_active=%s\n' "$backend"
  else
    printf '%s\n' "fw_backend_active=unavailable"
  fi
  if tm_journal_exists; then
    printf '%s\n' "rollback_journal=present"
  else
    printf '%s\n' "rollback_journal=absent"
  fi
  printf '%s\n' "tunnels:"
  tm_action_tunnel_list || true
  printf '%s\n' "forwards:"
  tm_action_forward_list || true
}
