# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — dedicated HAProxy process for TCP forwards.
# The system HAProxy configuration is not modified.
# Configuration is validated with haproxy -c before a reload.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "haproxy.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_HAPROXY_LOADED:-}" ]]; then
  return 0
fi
TM_HAPROXY_LOADED=1

tm_haproxy_ident() {
  local name="$1"
  name=${name//-/_}
  printf 'tm_%s\n' "$name"
}

tm_haproxy_addr() {
  local ip="$1"
  if tm_valid_ipv6 "$ip"; then
    printf '[%s]' "$ip"
    return 0
  fi
  printf '%s' "$ip"
}

tm_haproxy_render() {
  local -a names=("$@")
  local name ident listen_ip listen_port dest_ip dest_port source_ip
  local -A row=()
  local key
  if [[ "${#names[@]}" -eq 0 ]]; then
    return 1
  fi
  printf '%s\n' "global"
  printf '%s\n' "    maxconn 4096"
  printf '%s\n' "    log /dev/log local0"
  if id haproxy >/dev/null 2>&1; then
    printf '%s\n' "    user haproxy"
    printf '%s\n' "    group haproxy"
  fi
  printf '%s\n' "defaults"
  printf '%s\n' "    mode tcp"
  printf '%s\n' "    timeout connect 5s"
  printf '%s\n' "    timeout client 1m"
  printf '%s\n' "    timeout server 1m"
  printf '%s\n' "    log global"
  printf '%s\n' "    option tcplog"
  printf '%s\n' "    option clitcpka"
  printf '%s\n' "    option srvtcpka"
  for name in "${names[@]}"; do
    for key in "${!row[@]}"; do
      unset "row[$key]"
    done
    tm_kv_read "$(tm_forward_file "$name")" row || return 1
    [[ "${row[TM_FORWARD_PROTO]}" == "tcp" ]] || return 1
    listen_ip=${row[TM_LISTEN_IP]}
    listen_port=${row[TM_LISTEN_PORT]}
    dest_ip=${row[TM_DEST_IP]}
    dest_port=${row[TM_DEST_PORT]}
    source_ip=${row[TM_SOURCE_IP]:-}
    tm_port_is_protected "$listen_port" && return 1
    ident=$(tm_haproxy_ident "$name")
    printf '\n'
    printf 'frontend %s_fe\n' "$ident"
    printf '    bind %s:%s\n' "$(tm_haproxy_addr "$listen_ip")" "$listen_port"
    printf '%s\n' "    mode tcp"
    printf '    default_backend %s_be\n' "$ident"
    printf '\n'
    printf 'backend %s_be\n' "$ident"
    printf '%s\n' "    mode tcp"
    printf '%s\n' "    option tcp-check"
    if [[ -n "$source_ip" ]]; then
      printf '    server dest %s:%s source %s check inter 5s fall 3 rise 2\n' \
        "$(tm_haproxy_addr "$dest_ip")" "$dest_port" "$(tm_haproxy_addr "$source_ip")"
    else
      printf '    server dest %s:%s check inter 5s fall 3 rise 2\n' \
        "$(tm_haproxy_addr "$dest_ip")" "$dest_port"
    fi
  done
}

tm_haproxy_tcp_names() {
  local name proto
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    proto=$(tm_forward_proto "$name" || true)
    if [[ "$proto" == "tcp" ]]; then
      printf '%s\n' "$name"
    fi
  done < <(tm_list_forwards)
}

tm_haproxy_stop_exec() {
  if tm_use_systemd; then
    tm_run systemctl disable --now tunnel-manager-haproxy.service >/dev/null 2>&1 || true
    return 0
  fi
  if [[ -s "$TM_HAPROXY_PID" ]]; then
    local pid
    pid=$(tr -d '[:space:]' <"$TM_HAPROXY_PID")
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    tm_safe_rm "$TM_HAPROXY_PID" || true
  fi
  return 0
}

tm_haproxy_unit_installed() {
  local dir="${TM_SYSTEMD_DIR:-/etc/systemd/system}"
  [[ -f "${dir}/tunnel-manager-haproxy.service" \
    || -f /etc/systemd/system/tunnel-manager-haproxy.service \
    || -f /lib/systemd/system/tunnel-manager-haproxy.service \
    || -f /usr/lib/systemd/system/tunnel-manager-haproxy.service ]]
}

tm_haproxy_reload_or_start() {
  local pid=""
  if [[ -s "$TM_HAPROXY_PID" ]]; then
    pid=$(tr -d '[:space:]' <"$TM_HAPROXY_PID")
  fi
  tm_must haproxy -c -f "$TM_HAPROXY_CFG" || return 1
  if tm_use_systemd && tm_haproxy_unit_installed; then
    tm_must systemctl enable --now tunnel-manager-haproxy.service || return 1
    tm_must systemctl reload tunnel-manager-haproxy.service || return 1
    return 0
  fi
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    tm_must haproxy -D -f "$TM_HAPROXY_CFG" -p "$TM_HAPROXY_PID" -sf "$pid" || return 1
  else
    tm_must haproxy -D -f "$TM_HAPROXY_CFG" -p "$TM_HAPROXY_PID" || return 1
  fi
}

tm_haproxy_sync_exec() {
  local -a names=()
  local rendered
  mapfile -t names < <(tm_haproxy_tcp_names)
  if [[ "${#names[@]}" -eq 0 ]]; then
    tm_haproxy_stop_exec || return 1
    if [[ -f "$TM_HAPROXY_CFG" ]]; then
      tm_safe_rm "$TM_HAPROXY_CFG" || return 1
    fi
    return 0
  fi
  rendered=$(tm_haproxy_render "${names[@]}") || {
    tm_error "HAProxy configuration could not be rendered."
    return 1
  }
  tm_snapshot_file "$TM_HAPROXY_CFG" || return 1
  printf '%s\n' "$rendered" | tm_write_file "$TM_HAPROXY_CFG" 0644 || return 1
  if ! tm_must haproxy -c -f "$TM_HAPROXY_CFG"; then
    tm_error "HAProxy rejected the configuration. Restoring the previous file."
    tm_restore_snapshot "$TM_HAPROXY_CFG" || true
    return 1
  fi
  if ! tm_haproxy_reload_or_start; then
    tm_error "HAProxy reload failed. Restoring the previous configuration."
    tm_restore_snapshot "$TM_HAPROXY_CFG" || true
    if [[ -f "$TM_HAPROXY_CFG" ]]; then
      tm_haproxy_reload_or_start || true
    else
      tm_haproxy_stop_exec || true
    fi
    return 1
  fi
}

tm_haproxy_sync_undo() {
  local kind_file
  kind_file="${TM_VAR}/snapshots/$(tm_path_id "$TM_HAPROXY_CFG").kind"
  # A missing snapshot means this step never replaced the file. Leave it alone.
  if [[ -f "$kind_file" ]]; then
    tm_restore_snapshot "$TM_HAPROXY_CFG" || return 1
  fi
  if [[ -f "$TM_HAPROXY_CFG" ]]; then
    tm_haproxy_reload_or_start || return 1
  else
    tm_haproxy_stop_exec || return 1
  fi
}
