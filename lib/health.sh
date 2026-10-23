# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — read-only health checks.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "health.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_HEALTH_LOADED:-}" ]]; then
  return 0
fi
TM_HEALTH_LOADED=1

TM_DOCTOR_FAIL=0

tm_doctor_pass() { tm_info "[PASS] $*"; }
tm_doctor_warn() { tm_warn "[WARN] $*"; }
tm_doctor_fail() {
  tm_error "[FAIL] $*"
  TM_DOCTOR_FAIL=1
}

tm_doctor_ipv6_endpoint() {
  local name
  local -A row=()
  local need=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_tunnel_load "$name" row || continue
    if tm_valid_ipv6 "${row[TM_LOCAL_PUBLIC_IP]:-}"; then
      need=1
      break
    fi
  done < <(tm_list_tunnels)
  [[ "$need" -eq 1 ]] || return 0
  if tm_cmd_available ip6tables || tm_cmd_available nft; then
    tm_doctor_pass "IPv6 tunnel endpoints have ip6tables or nft available."
  else
    tm_doctor_warn "An IPv6 tunnel endpoint is saved, and neither ip6tables nor nft is available."
  fi
}

tm_action_doctor() {
  local value cmd
  TM_DOCTOR_FAIL=0
  tm_info "Tunnel Manager doctor ${TM_VERSION}"
  if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
    tm_doctor_pass "Bash ${BASH_VERSION}"
  else
    tm_doctor_fail "Bash 4.4 or newer is required."
  fi
  if tm_os_is_linux; then
    tm_doctor_pass "Kernel is Linux."
  else
    tm_doctor_fail "This host is not Linux ($(uname -s)). Tunnel changes require Linux."
  fi
  if tm_os_is_supported; then
    tm_doctor_pass "Distribution is Debian or Ubuntu."
  else
    tm_doctor_warn "Distribution is not Debian or Ubuntu. Packages and paths may differ."
  fi
  if tm_is_root; then
    tm_doctor_pass "Running as root."
  else
    tm_doctor_warn "Not running as root. Changes will be refused."
  fi
  for cmd in ip sysctl wg; do
    if tm_cmd_available "$cmd"; then
      tm_doctor_pass "Command ${cmd} is available."
    else
      tm_doctor_warn "Command ${cmd} is not available."
    fi
  done
  if tm_cmd_available iptables || tm_cmd_available nft; then
    tm_doctor_pass "A firewall command is available."
  else
    tm_doctor_fail "Neither iptables nor nft is available."
  fi
  if tm_use_systemd; then
    tm_doctor_pass "systemd is available."
  else
    tm_doctor_warn "systemd is not available. Boot persistence cannot be enabled here."
  fi
  if tm_cmd_available sysctl; then
    value=$(tm_exec sysctl -n net.ipv4.ip_forward 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$value" == "1" ]]; then
      tm_doctor_pass "net.ipv4.ip_forward is 1."
    else
      tm_doctor_warn "net.ipv4.ip_forward is ${value:-unset}. Port forwarding needs it."
    fi
  fi
  tm_doctor_ipv6_endpoint
  if tm_journal_exists; then
    tm_doctor_warn "A rollback journal exists. Run: tunnel-manager rollback"
  else
    tm_doctor_pass "No interrupted rollback journal."
  fi
  tm_doctor_pass "Port forwarding uses firewall NAT."
  local name
  local -A row=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if tm_tunnel_load "$name" row; then
      if [[ "${row[TM_TUNNEL_TYPE]:-}" == "forward" ]]; then
        tm_doctor_pass "Port forward ${name} has no tunnel interface."
      elif tm_iface_exists "$(tm_tunnel_iface "$name")"; then
        tm_doctor_pass "Tunnel ${name} interface is present."
      else
        tm_doctor_warn "Tunnel ${name} is saved but its interface is down."
      fi
    else
      tm_doctor_fail "Tunnel ${name} configuration cannot be read."
    fi
  done < <(tm_list_tunnels)
  if [[ "$TM_DOCTOR_FAIL" -eq 0 ]]; then
    tm_info "Doctor finished with no failures."
    return 0
  fi
  tm_error "Doctor found failures."
  return 1
}
