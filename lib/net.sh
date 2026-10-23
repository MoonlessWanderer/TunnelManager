# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — addressing, sysctl, and interface helpers.
# This module never changes the default route.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "net.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_NET_LOADED:-}" ]]; then
  return 0
fi
TM_NET_LOADED=1

tm_sysctl_dropin_text() {
  cat <<'EOF'
# Managed by Tunnel Manager.
# This file only enables IPv4 forwarding for saved UDP forwards.
# It does not change the default route or flush firewall rules.
net.ipv4.ip_forward = 1
EOF
}

tm_normalize_managed_text() {
  printf '%s\n' "$1" | tr -d '\r' | sed -e 's/[[:space:]]*$//'
}

tm_sysctl_dropin_status() {
  local content="$1"
  local expected norm_content norm_expected trimmed
  trimmed=$(printf '%s' "$content" | tr -d '[:space:]')
  if [[ -z "$trimmed" ]]; then
    printf 'missing\n'
    return 0
  fi
  expected=$(tm_sysctl_dropin_text)
  norm_content=$(tm_normalize_managed_text "$content")
  norm_expected=$(tm_normalize_managed_text "$expected")
  if [[ "$norm_content" == "$norm_expected" ]]; then
    printf 'managed\n'
  else
    printf 'foreign\n'
  fi
}

tm_iface_exists() {
  local iface="$1"
  tm_valid_iface "$iface" || return 1
  if [[ "${TM_TEST_MODE:-0}" == "1" ]]; then
    tm_run_quiet ip link show dev "$iface" >/dev/null 2>&1
    return $?
  fi
  [[ -e "/sys/class/net/${iface}" ]]
}

tm_detect_default_iface() {
  local line
  local -a parts=()
  local i
  line=$(tm_run_quiet ip -4 route show default 2>/dev/null | head -n 1 || true)
  [[ -n "$line" ]] || return 1
  read -r -a parts <<<"$line"
  for ((i = 0; i < ${#parts[@]}; i++)); do
    if [[ "${parts[$i]}" == "dev" && -n "${parts[$((i + 1))]:-}" ]]; then
      printf '%s\n' "${parts[$((i + 1))]}"
      return 0
    fi
  done
  return 1
}

tm_detect_iface_ipv4() {
  local iface="$1"
  local line ip
  line=$(tm_run_quiet ip -4 -o addr show dev "$iface" 2>/dev/null | head -n 1 || true)
  [[ -n "$line" ]] || return 1
  ip=${line#* inet }
  ip=${ip%%/*}
  tm_ipv4_is_unicast_host "$ip" || return 1
  printf '%s\n' "$ip"
}

tm_any_udp_forward() {
  local name proto
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    proto=$(tm_forward_proto "$name" || true)
    [[ "$proto" == "udp" ]] && return 0
  done < <(tm_list_forwards)
  return 1
}

tm_forward_proto() {
  local name="$1"
  local -A row=()
  tm_kv_read "$(tm_forward_file "$name")" row || return 1
  printf '%s\n' "${row[TM_FORWARD_PROTO]}"
}

tm_sysctl_forward_needed() {
  tm_any_udp_forward
}

tm_sysctl_sync_exec() {
  local current="" status="missing" prev="" need=0
  local prev_file="${TM_VAR}/ip_forward.prev"
  if tm_sysctl_forward_needed; then
    need=1
  fi
  if [[ -f "$TM_SYSCTL_FILE" ]]; then
    status=$(tm_sysctl_dropin_status "$(cat -- "$TM_SYSCTL_FILE")")
  fi
  if [[ "$need" -eq 1 && "$status" == "foreign" ]]; then
    tm_error "Refusing to overwrite ${TM_SYSCTL_FILE}; it is not managed by Tunnel Manager."
    return 1
  fi
  current=$(tm_run_quiet sysctl -n net.ipv4.ip_forward 2>/dev/null | tr -d '[:space:]' || true)
  [[ -n "$current" ]] || current="0"
  if [[ "$need" -eq 1 ]]; then
    if [[ ! -f "$prev_file" ]]; then
      if [[ "$current" == "1" ]]; then
        printf 'unchanged\n' >"$prev_file"
      else
        printf '%s\n' "$current" >"$prev_file"
      fi
      chmod 0600 "$prev_file" || true
    fi
    if [[ "$status" == "missing" ]]; then
      tm_sysctl_dropin_text | tm_write_file "$TM_SYSCTL_FILE" 0644 || return 1
    fi
    if [[ "$current" != "1" ]]; then
      tm_must sysctl -w net.ipv4.ip_forward=1 || return 1
    fi
    return 0
  fi
  if [[ "$status" == "managed" && -f "$TM_SYSCTL_FILE" ]]; then
    tm_safe_rm "$TM_SYSCTL_FILE" || return 1
  fi
  if [[ -f "$prev_file" ]]; then
    prev=$(tr -d '[:space:]' <"$prev_file")
    if [[ "$prev" == "0" ]]; then
      tm_must sysctl -w net.ipv4.ip_forward=0 || return 1
    fi
    tm_safe_rm "$prev_file" || return 1
  fi
  return 0
}

tm_rp_filter_key() {
  printf 'net.ipv4.conf.%s.rp_filter\n' "$1"
}

tm_rp_filter_apply_exec() {
  local iface="$1"
  local key prev_file current
  tm_valid_tunnel_iface "$iface" || return 1
  key=$(tm_rp_filter_key "$iface")
  prev_file="${TM_VAR}/rp_${iface}.prev"
  current=$(tm_run_quiet sysctl -n "$key" 2>/dev/null | tr -d '[:space:]' || true)
  [[ -n "$current" ]] || current="1"
  if [[ ! -f "$prev_file" ]]; then
    printf '%s\n' "$current" >"$prev_file"
    chmod 0600 "$prev_file" || true
  fi
  if [[ "$current" != "2" ]]; then
    tm_must sysctl -w "${key}=2" || return 1
  fi
}

tm_rp_filter_restore_exec() {
  local iface="$1"
  local key prev_file prev
  tm_valid_tunnel_iface "$iface" || return 1
  key=$(tm_rp_filter_key "$iface")
  prev_file="${TM_VAR}/rp_${iface}.prev"
  [[ -f "$prev_file" ]] || return 0
  prev=$(tr -d '[:space:]' <"$prev_file")
  case "$prev" in
    0|1|2) tm_must sysctl -w "${key}=${prev}" || return 1 ;;
  esac
  tm_safe_rm "$prev_file" || return 1
}
