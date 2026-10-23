# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — TCP BBR. This does not change the default route.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "bbr.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_BBR_LOADED:-}" ]]; then
  return 0
fi
TM_BBR_LOADED=1

tm_bbr_dropin_text() {
  cat <<'EOF'
# Managed by Tunnel Manager.
# TCP BBR and a fair queue. This file does not change the default route.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
}

tm_bbr_dropin_status() {
  local content="$1"
  local expected norm_content norm_expected trimmed
  trimmed=$(printf '%s' "$content" | tr -d '[:space:]')
  if [[ -z "$trimmed" ]]; then
    printf 'missing\n'
    return 0
  fi
  expected=$(tm_bbr_dropin_text)
  norm_content=$(tm_normalize_managed_text "$content")
  norm_expected=$(tm_normalize_managed_text "$expected")
  if [[ "$norm_content" == "$norm_expected" ]]; then
    printf 'managed\n'
  else
    printf 'foreign\n'
  fi
}

tm_bbr_read() {
  local key="$1"
  local value=""
  value=$(tm_run_quiet sysctl -n "$key" 2>/dev/null || true)
  value=${value//$'\r'/}
  value=${value//$'\n'/}
  [[ "$value" =~ ^[a-z0-9_]{1,32}$ ]] || return 1
  printf '%s\n' "$value"
}

tm_bbr_save_prev() {
  local path="$1"
  local value="$2"
  if [[ -f "$path" ]]; then
    return 0
  fi
  printf '%s\n' "$value" | tm_write_file "$path" 0600
}

tm_bbr_restore_prev() {
  local key="$1"
  local path="$2"
  local value=""
  [[ -f "$path" ]] || return 0
  value=$(tr -d '[:space:]' <"$path")
  if [[ "$value" =~ ^[a-z0-9_]{1,32}$ ]]; then
    tm_must sysctl -w "${key}=${value}" || return 1
  fi
  tm_safe_rm "$path"
}

tm_bbr_apply_exec() {
  local qdisc="" cc="" status=""
  tm_must modprobe tcp_bbr || return 1
  qdisc=$(tm_bbr_read net.core.default_qdisc) || return 1
  cc=$(tm_bbr_read net.ipv4.tcp_congestion_control) || return 1
  mkdir -p -- "$TM_VAR" || return 1
  tm_bbr_save_prev "${TM_VAR}/bbr.qdisc.prev" "$qdisc" || return 1
  tm_bbr_save_prev "${TM_VAR}/bbr.cc.prev" "$cc" || return 1
  if [[ -f "$TM_BBR_FILE" ]]; then
    status=$(tm_bbr_dropin_status "$(cat -- "$TM_BBR_FILE")")
    if [[ "$status" == "foreign" ]]; then
      tm_error "Refusing to overwrite ${TM_BBR_FILE}; it is not managed by Tunnel Manager."
      return 1
    fi
  fi
  if [[ "$status" != "managed" ]]; then
    tm_bbr_dropin_text | tm_write_file "$TM_BBR_FILE" 0644 || return 1
  fi
  if [[ "$qdisc" != "fq" ]]; then
    tm_must sysctl -w net.core.default_qdisc=fq || return 1
  fi
  if [[ "$cc" != "bbr" ]]; then
    tm_must sysctl -w net.ipv4.tcp_congestion_control=bbr || return 1
  fi
  return 0
}

tm_bbr_undo() {
  local status="missing"
  tm_bbr_restore_prev net.core.default_qdisc "${TM_VAR}/bbr.qdisc.prev" || return 1
  tm_bbr_restore_prev net.ipv4.tcp_congestion_control "${TM_VAR}/bbr.cc.prev" || return 1
  if [[ -f "$TM_BBR_FILE" ]]; then
    status=$(tm_bbr_dropin_status "$(cat -- "$TM_BBR_FILE")")
    if [[ "$status" == "managed" ]]; then
      tm_safe_rm "$TM_BBR_FILE" || return 1
    fi
  fi
  return 0
}

tm_bbr_already() {
  local qdisc="" cc="" status=""
  [[ -f "$TM_BBR_FILE" ]] || return 1
  status=$(tm_bbr_dropin_status "$(cat -- "$TM_BBR_FILE")")
  [[ "$status" == "managed" ]] || return 1
  qdisc=$(tm_bbr_read net.core.default_qdisc) || return 1
  cc=$(tm_bbr_read net.ipv4.tcp_congestion_control) || return 1
  [[ "$qdisc" == "fq" && "$cc" == "bbr" ]]
}

tm_action_bbr_enable() {
  local -A opt=()
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  if [[ "${TM_DRY_RUN:-0}" != "1" ]] && tm_bbr_already; then
    tm_info "BBR is already enabled."
    return 0
  fi
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Enable TCP BBR with fq. The default route is not changed and firewall rules are not flushed." \
    "$(tm_shell_quote tm_bbr_undo)" \
    tm_bbr_apply_exec
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}
