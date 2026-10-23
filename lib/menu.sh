# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — interactive menu.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "menu.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_MENU_LOADED:-}" ]]; then
  return 0
fi
TM_MENU_LOADED=1

tm_menu_pause() {
  local _unused=""
  if [[ -r /dev/tty ]]; then
    read -r -p "Press Enter to continue. " _unused </dev/tty || true
  fi
}

tm_menu_run() {
  local status=0
  set +e
  (
    set -euo pipefail
    "$@"
  )
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    tm_warn "The command exited with status ${status}."
  fi
  tm_menu_pause
}

tm_menu_choose() {
  local title="$1"
  local exit_label="$2"
  shift 2
  local -a items=("$@")
  local choice=""
  local i
  printf '\n%s\n' "═══════════════════════════════════════════" >/dev/tty
  printf '\n' >/dev/tty
  if [[ -n "$title" ]]; then
    printf '  %s\n\n' "$title" >/dev/tty
  fi
  for i in "${!items[@]}"; do
    printf '  %s. %s\n' "$((i + 1))" "${items[$i]}" >/dev/tty
  done
  printf '  %s. %s\n' "0" "$exit_label" >/dev/tty
  printf '\n%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >/dev/tty
  if [[ ! -r /dev/tty ]]; then
    tm_die "A terminal is required for interactive input."
  fi
  read -r -p "Enter your choice [0–${#items[@]}]: " choice </dev/tty || return 1
  printf '%s\n' "$choice"
}

tm_menu_forward() {
  local choice=""
  while true; do
    choice=$(tm_menu_choose "Port forwards" "Back" \
      "Add forward" \
      "Edit a forward" \
      "Delete a forward" \
      "List forwards" \
      "Test a forward") || return 1
    case "$choice" in
      1) tm_menu_add_forward_prompt ;;
      2) tm_menu_edit_forward ;;
      3) tm_menu_delete_forward ;;
      4) tm_action_forward_list; tm_menu_pause ;;
      5) tm_menu_test_forward ;;
      0) return 0 ;;
      *) tm_warn "Unknown choice." ;;
    esac
  done
}

tm_menu_default_tunnel() {
  local -a names=()
  local line
  if [[ -f "$(tm_tunnel_file edge)" ]]; then
    printf '%s\n' "edge"
    return 0
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && names+=("$line")
  done < <(tm_list_tunnels)
  if [[ "${#names[@]}" -ge 1 ]]; then
    printf '%s\n' "${names[0]}"
    return 0
  fi
  printf '%s\n' "edge"
}

tm_menu_ssh_port() {
  local -a fields=()
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r -a fields <<<"${SSH_CONNECTION}"
    if [[ "${#fields[@]}" -ge 4 ]] && tm_valid_port "${fields[3]}"; then
      printf '%s\n' "${fields[3]}"
      return 0
    fi
  fi
  printf '%s\n' "22"
}

tm_menu_add_forward_prompt() {
  local proto=""
  tm_prompt proto "Protocol tcp or udp" "tcp" || return 1
  tm_menu_add_forward "$proto"
}

tm_menu_add_forward() {
  local proto="$1"
  local name="" listen_port="" dest_ip="" dest_port="" source_ip="" ingress="" tunnel="" snat="auto"
  local -A tun=()
  tm_prompt name "Forward name" || return 1
  tm_prompt listen_port "Listen port" || return 1
  tm_prompt tunnel "Existing tunnel name or '-' " "$(tm_menu_default_tunnel)" || return 1
  if [[ "$tunnel" != "-" && -f "$(tm_tunnel_file "$tunnel")" ]] && tm_tunnel_load "$tunnel" tun; then
    dest_ip="${tun[TM_REMOTE_TUNNEL_IP]}"
    source_ip="${tun[TM_LOCAL_TUNNEL_IP]}"
    ingress="${tun[TM_WAN_IFACE]}"
  fi
  tm_prompt dest_ip "Destination IP" "$dest_ip" || return 1
  tm_prompt dest_port "Destination port" "$listen_port" || return 1
  tm_prompt source_ip "Source tunnel IP" "$source_ip" || return 1
  tm_prompt ingress "Ingress interface" "$ingress" || return 1
  tm_prompt snat "SNAT auto, always, or never" "auto" || return 1
  if [[ "$tunnel" == "-" ]]; then
    tm_menu_run tm_action_forward_add --name "$name" --proto "$proto" \
      --listen-port "$listen_port" --dest-ip "$dest_ip" --dest-port "$dest_port" \
      --source-ip "$source_ip" --ingress-iface "$ingress" --snat "$snat"
  else
    tm_menu_run tm_action_forward_add --name "$name" --proto "$proto" \
      --listen-port "$listen_port" --dest-ip "$dest_ip" --dest-port "$dest_port" \
      --source-ip "$source_ip" --ingress-iface "$ingress" --snat "$snat" --tunnel "$tunnel"
  fi
}

tm_menu_edit_forward() {
  local name="" listen_port=""
  tm_prompt name "Forward name" || return 1
  tm_prompt listen_port "New listen port, or '-' to keep" "-" || return 1
  if [[ "$listen_port" == "-" ]]; then
    tm_menu_run tm_action_forward_edit --name "$name"
  else
    tm_menu_run tm_action_forward_edit --name "$name" --listen-port "$listen_port"
  fi
}

tm_menu_delete_forward() {
  local name=""
  tm_prompt name "Forward name" || return 1
  tm_menu_run tm_action_forward_delete --name "$name"
}

tm_menu_test_forward() {
  local name=""
  tm_prompt name "Forward name" || return 1
  tm_menu_run tm_action_forward_test --name "$name"
}

tm_menu_prefill_uplink() {
  local -n _tm_wan=$1
  local -n _tm_ip=$2
  local picked="" iface="" ip=""
  if ! tm_valid_iface "${_tm_wan}"; then
    _tm_wan=$(tm_detect_default_iface || true)
  fi
  if ! tm_valid_iface "${_tm_wan}"; then
    _tm_wan=$(tm_detect_sole_iface || true)
  fi
  picked=$(tm_detect_reachable_addr || true)
  if [[ "$picked" == *" "* ]]; then
    iface=${picked%% *}
    ip=${picked#* }
    if ! tm_valid_iface "${_tm_wan}"; then
      _tm_wan="$iface"
    fi
    if ! tm_ip_is_unicast_host "${_tm_ip}" && { [[ -z "${_tm_wan}" ]] || [[ "${_tm_wan}" == "$iface" ]]; }; then
      _tm_ip="$ip"
    fi
  fi
  if tm_valid_iface "${_tm_wan}" && ! tm_ip_is_unicast_host "${_tm_ip}"; then
    _tm_ip=$(tm_detect_iface_ipv4 "${_tm_wan}" || true)
  fi
}

tm_menu_prompt_host_ip() {
  local -n _tm_ip=$1
  local label="$2"
  local other="${3:-}"
  local choice=""
  choice="${_tm_ip}"
  while true; do
    tm_prompt choice "$label" "$choice" || return 1
    if tm_ip_is_unicast_host "$choice" && [[ "$choice" != "$other" ]]; then
      _tm_ip="$choice"
      return 0
    fi
    if [[ -n "$other" && "$choice" == "$other" ]]; then
      tm_warn "The two servers need different reachable addresses."
    else
      tm_warn "A reachable public IPv4 or IPv6 address is required."
    fi
    choice=""
  done
}

tm_menu_create_tunnel() {
  local name="" type="" local_pub="" remote_pub="" local_tun="" remote_tun="" wan="" peer="" cidr="30"
  tm_menu_prefill_uplink wan local_pub
  tm_prompt name "Tunnel name" "edge" || return 1
  tm_prompt type "Type: wireguard or gre" "wireguard" || return 1
  tm_menu_prompt_host_ip local_pub "Local reachable IPv4 or IPv6" || return 1
  tm_menu_prompt_host_ip remote_pub "Remote reachable IPv4 or IPv6" "$local_pub" || return 1
  tm_prompt local_tun "Local tunnel IP" || return 1
  tm_prompt remote_tun "Remote tunnel IP" || return 1
  if [[ "$local_tun" == *:* ]]; then
    tm_prompt cidr "Prefix length" "64" || return 1
  else
    tm_prompt cidr "Prefix length" "30" || return 1
  fi
  wan=$(tm_detect_wan "$wan" "$local_pub" "$remote_pub" || true)
  tm_menu_apply_iface wan || return 1
  if [[ "$type" == "wireguard" ]]; then
    tm_prompt peer "Peer public key, or '-' to generate a pending tunnel" "-" || return 1
    if [[ "$peer" == "-" ]]; then
      tm_menu_run tm_action_tunnel_create --name "$name" --type wireguard \
        --local-public-ip "$local_pub" --remote-public-ip "$remote_pub" \
        --local-tunnel-ip "$local_tun" --remote-tunnel-ip "$remote_tun" \
        --cidr "$cidr" --wan-iface "$wan"
    else
      tm_menu_run tm_action_tunnel_create --name "$name" --type wireguard \
        --local-public-ip "$local_pub" --remote-public-ip "$remote_pub" \
        --local-tunnel-ip "$local_tun" --remote-tunnel-ip "$remote_tun" \
        --cidr "$cidr" --wan-iface "$wan" --peer-public-key "$peer"
    fi
  else
    tm_menu_run tm_action_tunnel_create --name "$name" --type gre \
      --local-public-ip "$local_pub" --remote-public-ip "$remote_pub" \
      --local-tunnel-ip "$local_tun" --remote-tunnel-ip "$remote_tun" \
      --cidr "$cidr" --wan-iface "$wan"
  fi
}

tm_menu_show_key() {
  local name=""
  tm_prompt name "Tunnel name" "$(tm_menu_default_tunnel)" || return 1
  tm_print_public_key "$name" || tm_die "No public key is stored for ${name}."
}

tm_menu_paste_peer() {
  local name="" peer=""
  tm_prompt name "Tunnel name" "$(tm_menu_default_tunnel)" || return 1
  tm_prompt peer "Paste the other server public key" || return 1
  peer=$(tm_normalize_wg_key "$peer") || return 1
  tm_action_tunnel_set_peer --name "$name" --peer-public-key "$peer"
}

tm_menu_quick_forward() {
  local port="" proto="" tunnel="" name=""
  tm_prompt port "Port on this server" "443" || return 1
  tm_prompt proto "tcp or udp" "tcp" || return 1
  tm_prompt tunnel "Tunnel name" "$(tm_menu_default_tunnel)" || return 1
  if [[ "$proto" == "tcp" && "$port" == "443" ]]; then
    name="web"
  else
    name="${proto}${port}"
  fi
  tm_action_forward_add --name "$name" --proto "$proto" --listen-port "$port" --tunnel "$tunnel"
}

tm_menu_apply_iface() {
  local -n _tm_iface=$1
  local choice="" iface_list=""
  choice="${_tm_iface}"
  while true; do
    tm_prompt choice "WAN interface" "$choice" || return 1
    if tm_valid_iface "$choice" && tm_menu_iface_present "$choice"; then
      _tm_iface="$choice"
      return 0
    fi
    if tm_valid_iface "$choice"; then
      tm_warn "Interface ${choice} is not present on this server."
    else
      tm_warn "A WAN interface name is required."
    fi
    iface_list=$(tm_list_ifaces | tr '\n' ' ' || true)
    iface_list=${iface_list%" "}
    if [[ -n "$iface_list" ]]; then
      tm_info "Interfaces: ${iface_list}"
    fi
    choice=""
  done
}

tm_menu_iface_present() {
  local iface="$1"
  if [[ "${TM_TEST_MODE:-0}" == "1" ]]; then
    return 0
  fi
  if [[ -d /sys/class/net ]]; then
    [[ -e "/sys/class/net/${iface}" ]]
    return $?
  fi
  return 0
}

tm_menu_quick_setup() {
  local role="" local_pub="" remote_pub="" wan="" peer="" ssh_port=""
  local local_tun="" remote_tun=""
  tm_menu_prefill_uplink wan local_pub
  ssh_port=$(tm_menu_ssh_port)
  if [[ -f "$(tm_tunnel_file edge)" ]]; then
    tm_info "Tunnel edge already exists. Its public key is printed below."
    tm_print_public_key edge || tm_die "Tunnel edge has no public key."
    tm_info "On the other server, open Manage Tunnels and paste this public key."
    return 0
  fi
  tm_prompt role "This server: iran or foreign" "iran" || return 1
  case "$role" in
    iran)
      local_tun="10.200.0.1"
      remote_tun="10.200.0.2"
      ;;
    foreign)
      local_tun="10.200.0.2"
      remote_tun="10.200.0.1"
      ;;
    *)
      tm_die "Role must be iran or foreign."
      ;;
  esac
  tm_menu_prompt_host_ip local_pub "This server reachable IP" || return 1
  tm_menu_prompt_host_ip remote_pub "Other server reachable IP" "$local_pub" || return 1
  wan=$(tm_detect_wan "$wan" "$local_pub" "$remote_pub" || true)
  tm_menu_apply_iface wan || return 1
  tm_prompt peer "Other server public key, or Enter if you do not have it yet" "-" || return 1
  printf '\n%s\n' "WireGuard edge will use ${local_tun} on this server and ${remote_tun} on the other."
  printf '%s\n' "Listen port 51820 and prefix 30 are filled in automatically. WAN interface is ${wan}."
  if [[ ! -f "$(tm_host_file)" ]]; then
    tm_action_init --role "$role" --public-ip "$local_pub" --wan-iface "$wan" --ssh-port "$ssh_port"
  fi
  if [[ "$peer" == "-" ]]; then
    tm_action_tunnel_create --name edge --type wireguard \
      --local-public-ip "$local_pub" --remote-public-ip "$remote_pub" \
      --local-tunnel-ip "$local_tun" --remote-tunnel-ip "$remote_tun" \
      --wan-iface "$wan"
  else
    peer=$(tm_normalize_wg_key "$peer") || return 1
    tm_action_tunnel_create --name edge --type wireguard \
      --local-public-ip "$local_pub" --remote-public-ip "$remote_pub" \
      --local-tunnel-ip "$local_tun" --remote-tunnel-ip "$remote_tun" \
      --wan-iface "$wan" --peer-public-key "$peer"
  fi
}

tm_menu_named() {
  local action="$1"
  local name=""
  tm_prompt name "Tunnel name" "$(tm_menu_default_tunnel)" || return 1
  tm_menu_run "$action" --name "$name"
}

tm_menu_uninstall_script() {
  local dir="${TM_LIB_DIR:-}"
  local parent=""
  if [[ -n "$dir" && -f "${dir}/uninstall.sh" ]]; then
    printf '%s\n' "${dir}/uninstall.sh"
    return 0
  fi
  if [[ -n "$dir" ]]; then
    parent=$(cd -P "${dir}/.." && pwd) || return 1
    if [[ -f "${parent}/uninstall.sh" ]]; then
      printf '%s\n' "${parent}/uninstall.sh"
      return 0
    fi
  fi
  return 1
}

tm_menu_uninstall() {
  local script="" prefix=""
  script=$(tm_menu_uninstall_script) || tm_die "uninstall.sh was not found. Reinstall Tunnel Manager."
  prefix="${TM_PREFIX:-/usr/local}"
  printf '\n%s\n' "This deletes the program, saved tunnels, keys, logs, and Tunnel Manager WireGuard configs."
  printf '%s\n' "A missing file is skipped. Other firewall rules and the wireguard and haproxy packages stay."
  if ! tm_confirm "Uninstall Tunnel Manager?"; then
    tm_info "Uninstall was not started."
    return 0
  fi
  bash "$script" --prefix "$prefix" --yes --purge-state
  exit 0
}

tm_menu_configure() {
  local choice=""
  while true; do
    choice=$(tm_menu_choose "Configure a New Tunnel" "Back" \
      "Quick WireGuard setup" \
      "Advanced tunnel") || return 1
    case "$choice" in
      1) tm_menu_run tm_menu_quick_setup ;;
      2) tm_menu_create_tunnel ;;
      0) return 0 ;;
      *) tm_warn "Unknown choice." ;;
    esac
  done
}

tm_menu_maintenance() {
  local choice="" output="" file=""
  while true; do
    choice=$(tm_menu_choose "Maintenance" "Back" \
      "Status" \
      "Troubleshoot" \
      "Backup" \
      "Restore" \
      "Apply saved state" \
      "Dry-run apply" \
      "Roll back") || return 1
    case "$choice" in
      1) tm_action_status; tm_menu_pause ;;
      2) tm_menu_run tm_action_doctor ;;
      3)
        tm_prompt output "Backup output path" "${TM_VAR}/backups/manual.tar.gz" || continue
        tm_menu_run tm_action_backup_create --output "$output"
        ;;
      4)
        tm_prompt file "Backup file" || continue
        tm_menu_run tm_action_backup_restore --file "$file"
        ;;
      5) tm_menu_run tm_action_apply ;;
      6) tm_menu_run tm_action_apply --dry-run ;;
      7) tm_menu_run tm_action_rollback ;;
      0) return 0 ;;
      *) tm_warn "Unknown choice." ;;
    esac
  done
}

tm_menu_manage() {
  local choice=""
  while true; do
    choice=$(tm_menu_choose "Manage Tunnels" "Back" \
      "Show public key" \
      "Paste the other server key" \
      "Forward a port" \
      "Test tunnel" \
      "Restart tunnel" \
      "Delete tunnel" \
      "Port forwards" \
      "Maintenance") || return 1
    case "$choice" in
      1) tm_menu_show_key; tm_menu_pause ;;
      2) tm_menu_run tm_menu_paste_peer ;;
      3) tm_menu_run tm_menu_quick_forward ;;
      4) tm_menu_named tm_action_tunnel_test ;;
      5) tm_menu_named tm_action_tunnel_restart ;;
      6) tm_menu_named tm_action_tunnel_delete ;;
      7) tm_menu_forward ;;
      8) tm_menu_maintenance ;;
      0) return 0 ;;
      *) tm_warn "Unknown choice." ;;
    esac
  done
}

tm_menu() {
  local choice=""
  while true; do
    choice=$(tm_menu_choose "" "Exit" \
      "Configure a New Tunnel" \
      "Manage Tunnels" \
      "Update" \
      "Uninstall" \
      "Enable BBR") || return 1
    case "$choice" in
      1) tm_menu_configure ;;
      2) tm_menu_manage ;;
      3) tm_menu_run tm_action_update ;;
      4) tm_menu_uninstall ;;
      5) tm_menu_run tm_action_bbr_enable ;;
      0) tm_info "Goodbye."; return 0 ;;
      *) tm_warn "Unknown choice." ;;
    esac
  done
}
