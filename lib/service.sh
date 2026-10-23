# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — systemd unit installation.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "service.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_SERVICE_LOADED:-}" ]]; then
  return 0
fi
TM_SERVICE_LOADED=1

tm_template_dir() {
  local here root dir
  here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  root=$(cd -P "${here}/.." && pwd)
  # An installed lib lives in PREFIX/lib/tunnel-manager, so PREFIX/lib/systemd
  # is the system unit directory, not ours. Look for the template itself.
  for dir in "${root}/systemd" "${root}/../share/tunnel-manager/systemd" \
    /usr/local/share/tunnel-manager/systemd; do
    if [[ -f "${dir}/tunnel-manager-apply.service.in" ]]; then
      (cd -P "$dir" && pwd)
      return 0
    fi
  done
  return 1
}

tm_systemd_dir() {
  printf '%s\n' "${TM_SYSTEMD_DIR:-/etc/systemd/system}"
}

tm_systemd_dir_ok() {
  local dir parent norm
  dir=$(tm_systemd_dir)
  if [[ "${TM_TEST_MODE:-0}" != "1" ]]; then
    [[ "$dir" == "/etc/systemd/system" ]]
    return $?
  fi
  norm=$(tm_normalize_path "$dir") || return 1
  parent=$(dirname -- "$TM_ETC")
  parent=$(tm_normalize_path "$parent") || return 1
  tm_path_under "$norm" "$parent"
}

tm_render_unit() {
  local src="$1"
  local bin="${TM_BIN}"
  local lib="${TM_LIB_INSTALL}"
  sed \
    -e "s|@BIN@|${bin}|g" \
    -e "s|@LIB@|${lib}|g" \
    "$src"
}

tm_service_install_units_exec() {
  local dir src base rendered dest
  dir=$(tm_template_dir) || {
    tm_error "Systemd templates were not found."
    return 1
  }
  tm_systemd_dir_ok || {
    tm_error "Refusing to install units outside /etc/systemd/system."
    return 1
  }
  mkdir -p -- "$(tm_systemd_dir)" || return 1
  src="${dir}/tunnel-manager-apply.service.in"
  [[ -f "$src" ]] || {
    tm_error "Systemd templates were not found."
    return 1
  }
  base=$(basename -- "$src" .in)
  dest="$(tm_systemd_dir)/${base}"
  rendered=$(tm_render_unit "$src") || return 1
  printf '%s\n' "$rendered" >"$dest" || return 1
  chmod 0644 "$dest" || return 1
  tm_info "Installed ${dest}"
}

tm_action_service_enable() {
  local -A opt=()
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Restore saved tunnels and ports after reboot (tunnel-manager-apply.service)" \
    "$(tm_shell_quote tm_service_disable_exec)" \
    tm_service_enable_exec
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_service_enable_exec() {
  tm_service_install_units_exec || return 1
  if tm_use_systemd; then
    tm_must systemctl daemon-reload || return 1
    tm_must systemctl enable --quiet tunnel-manager-apply.service || return 1
  else
    tm_warn "systemd is not running. Unit files were written but not enabled."
  fi
}

tm_service_boot_enabled() {
  local saved="${TM_DRY_RUN:-0}" status=0
  tm_use_systemd || return 1
  TM_DRY_RUN=0
  tm_run_quiet systemctl is-enabled --quiet tunnel-manager-apply.service >/dev/null 2>&1 || status=$?
  TM_DRY_RUN="$saved"
  return "$status"
}

tm_service_disable_exec() {
  if tm_use_systemd; then
    tm_run systemctl disable tunnel-manager-apply.service >/dev/null 2>&1 || true
  fi
  return 0
}

tm_action_service_disable() {
  local -A opt=()
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Disable Tunnel Manager boot services" \
    "$(tm_shell_quote tm_service_enable_exec)" \
    tm_service_disable_exec
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}

tm_action_service_status() {
  if ! tm_use_systemd; then
    tm_warn "systemd is not available."
    return 0
  fi
  tm_run systemctl --no-pager status tunnel-manager-apply.service || true
}
