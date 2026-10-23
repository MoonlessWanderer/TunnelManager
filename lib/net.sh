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

tm_route_dev() {
  local line="$1"
  local -a parts=()
  local i token
  [[ -n "$line" ]] || return 1
  read -r -a parts <<<"$line"
  for ((i = 0; i < ${#parts[@]}; i++)); do
    if [[ "${parts[$i]}" != "dev" ]]; then
      continue
    fi
    token="${parts[$((i + 1))]:-}"
    token=${token%%@*}
    token=${token//\\/}
    tm_valid_iface "$token" || return 1
    printf '%s\n' "$token"
    return 0
  done
  return 1
}

tm_detect_default_iface() {
  local line dev
  while IFS= read -r line; do
    dev=$(tm_route_dev "$line" || true)
    if [[ -n "$dev" ]]; then
      printf '%s\n' "$dev"
      return 0
    fi
  done < <(tm_run_quiet ip -4 route show default 2>/dev/null || true)
  while IFS= read -r line; do
    [[ "$line" == default* ]] || continue
    dev=$(tm_route_dev "$line" || true)
    if [[ -n "$dev" ]]; then
      printf '%s\n' "$dev"
      return 0
    fi
  done < <(tm_run_quiet ip -4 route show 2>/dev/null || true)
  return 1
}

tm_addr_show_iface() {
  local line="$1"
  local rest iface
  [[ "$line" == *:* ]] || return 1
  rest=${line#*:}
  rest=${rest#"${rest%%[![:space:]]*}"}
  iface=${rest%%[[:space:]]*}
  iface=${iface%%@*}
  iface=${iface//\\/}
  tm_valid_iface "$iface" || return 1
  printf '%s\n' "$iface"
}

tm_detect_egress_iface() {
  local dest="$1"
  local family flag line dev
  family=$(tm_ip_family "$dest") || return 1
  case "$family" in
    4) flag=-4 ;;
    6) flag=-6 ;;
    *) return 1 ;;
  esac
  while IFS= read -r line; do
    dev=$(tm_route_dev "$line" || true)
    if [[ -n "$dev" ]]; then
      printf '%s\n' "$dev"
      return 0
    fi
  done < <(tm_run_quiet ip "$flag" route get "$dest" 2>/dev/null || true)
  return 1
}

tm_detect_iface_for_ip() {
  local want="$1"
  local line iface
  tm_ip_is_unicast_host "$want" || return 1
  if [[ "$(tm_ip_family "$want")" == "4" ]]; then
    while IFS= read -r line; do
      [[ "$line" == *" inet ${want}/"* || "$line" == *" inet ${want} "* ]] || continue
      iface=$(tm_addr_show_iface "$line" || true)
      if [[ -n "$iface" ]]; then
        printf '%s\n' "$iface"
        return 0
      fi
    done < <(tm_run_quiet ip -o -4 addr show 2>/dev/null || true)
  fi
  tm_detect_egress_iface "$want"
}

tm_detect_wan() {
  local hinted="${1:-}"
  local local_ip="${2:-}"
  local remote_ip="${3:-}"
  local found=""
  if tm_valid_iface "$hinted"; then
    printf '%s\n' "$hinted"
    return 0
  fi
  found=$(tm_detect_default_iface || true)
  if tm_valid_iface "$found"; then
    printf '%s\n' "$found"
    return 0
  fi
  if [[ -n "$local_ip" ]]; then
    found=$(tm_detect_iface_for_ip "$local_ip" || true)
    if tm_valid_iface "$found"; then
      printf '%s\n' "$found"
      return 0
    fi
  fi
  if [[ -n "$remote_ip" ]]; then
    found=$(tm_detect_egress_iface "$remote_ip" || true)
    if tm_valid_iface "$found"; then
      printf '%s\n' "$found"
      return 0
    fi
  fi
  return 1
}

tm_list_ifaces() {
  local path name line
  if [[ -d /sys/class/net ]]; then
    for path in /sys/class/net/*; do
      [[ -e "$path" ]] || continue
      name=$(basename -- "$path")
      [[ "$name" == "lo" ]] && continue
      tm_valid_iface "$name" || continue
      printf '%s\n' "$name"
    done
    return 0
  fi
  while IFS= read -r line; do
    name=$(tm_addr_show_iface "$line" || true)
    [[ -n "$name" && "$name" != "lo" ]] || continue
    printf '%s\n' "$name"
  done < <(tm_run_quiet ip -o link show 2>/dev/null || true)
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

tm_any_forward() {
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] && return 0
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
  tm_any_forward
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
