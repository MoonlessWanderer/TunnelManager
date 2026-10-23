# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — command dispatch.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "dispatch.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_DISPATCH_LOADED:-}" ]]; then
  return 0
fi
TM_DISPATCH_LOADED=1

tm_take_global_flags() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --yes)
        TM_YES=1
        shift
        ;;
      --dry-run)
        TM_DRY_RUN=1
        shift
        ;;
      --verbose)
        TM_LOG_LEVEL=debug
        shift
        ;;
      *)
        break
        ;;
    esac
  done
  TM_REMAINING=("$@")
}

tm_dispatch_tunnel() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    keygen) tm_action_tunnel_keygen "$@" ;;
    create) tm_action_tunnel_create "$@" ;;
    delete) tm_action_tunnel_delete "$@" ;;
    up) tm_action_tunnel_up "$@" ;;
    down) tm_action_tunnel_down "$@" ;;
    restart) tm_action_tunnel_restart "$@" ;;
    test) tm_action_tunnel_test "$@" ;;
    list) tm_action_tunnel_list "$@" ;;
    show) tm_action_tunnel_show "$@" ;;
    set-peer) tm_action_tunnel_set_peer "$@" ;;
    export-peer) tm_action_tunnel_export "$@" ;;
    *)
      tm_die "Unknown tunnel command. See: tunnel-manager help"
      ;;
  esac
}

tm_dispatch_forward() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    add) tm_action_forward_add "$@" ;;
    edit) tm_action_forward_edit "$@" ;;
    delete) tm_action_forward_delete "$@" ;;
    list) tm_action_forward_list "$@" ;;
    test) tm_action_forward_test "$@" ;;
    *)
      tm_die "Unknown forward command. See: tunnel-manager help"
      ;;
  esac
}

tm_dispatch_backup() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    create) tm_action_backup_create "$@" ;;
    restore) tm_action_backup_restore "$@" ;;
    list) tm_action_backup_list "$@" ;;
    *)
      tm_die "Unknown backup command. See: tunnel-manager help"
      ;;
  esac
}

tm_dispatch_service() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    enable) tm_action_service_enable "$@" ;;
    disable) tm_action_service_disable "$@" ;;
    status) tm_action_service_status "$@" ;;
    *)
      tm_die "Unknown service command. See: tunnel-manager help"
      ;;
  esac
}

tm_main() {
  tm_init_runtime
  tm_try_enable_file_log
  local -a TM_REMAINING=()
  if [[ "$#" -eq 0 ]]; then
    if [[ -t 0 && -t 1 ]]; then
      tm_menu
      return $?
    fi
    tm_usage
    return 1
  fi
  tm_take_global_flags "$@"
  set -- "${TM_REMAINING[@]}"
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    help|-h|--help)
      tm_usage
      ;;
    version|--version)
      tm_version
      ;;
    menu)
      tm_menu
      ;;
    init)
      tm_action_init "$@"
      ;;
    status)
      tm_action_status "$@"
      ;;
    doctor)
      tm_action_doctor "$@"
      ;;
    firewall)
      [[ "${1:-}" == "detect" ]] || tm_die "Usage: tunnel-manager firewall detect"
      tm_fw_active_backend
      ;;
    apply)
      tm_action_apply "$@"
      ;;
    down)
      tm_action_down_all "$@"
      ;;
    rollback)
      tm_action_rollback "$@"
      ;;
    tunnel)
      tm_dispatch_tunnel "$@"
      ;;
    forward)
      tm_dispatch_forward "$@"
      ;;
    backup)
      tm_dispatch_backup "$@"
      ;;
    service)
      tm_dispatch_service "$@"
      ;;
    update)
      tm_action_update "$@"
      ;;
    bbr)
      tm_action_bbr_enable "$@"
      ;;
    *)
      tm_die "Unknown command '${cmd}'. See: tunnel-manager help"
      ;;
  esac
}
