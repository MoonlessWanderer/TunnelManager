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

tm_menu_forward() {
  local choice=""
  while true; do
    printf '\n%s\n' "Port forwards"
    printf '%s\n' "  1) Add TCP forward (HAProxy)"
    printf '%s\n' "  2) Add UDP forward (NAT)"
    printf '%s\n' "  3) Edit a forward"
    printf '%s\n' "  4) Delete a forward"
    printf '%s\n' "  5) List forwards"
    printf '%s\n' "  6) Test a forward"
    printf '%s\n' "  0) Back"
    tm_prompt choice "Choose" || return 1
    case "$choice" in
      1) tm_menu_add_forward tcp ;;
      2) tm_menu_add_forward udp ;;
      3) tm_menu_edit_forward ;;
      4) tm_menu_delete_forward ;;
      5) tm_action_forward_list; tm_menu_pause ;;
      6) tm_menu_test_forward ;;
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

tm_menu_create_tunnel() {
  local name="" type="" local_pub="" remote_pub="" local_tun="" remote_tun="" wan="" peer="" cidr="30"
  wan=$(tm_detect_default_iface || true)
  if [[ -n "$wan" ]]; then
    local_pub=$(tm_detect_iface_ipv4 "$wan" || true)
  fi
  tm_prompt name "Tunnel name" "edge" || return 1
  tm_prompt type "Type: wireguard or gre" "wireguard" || return 1
  tm_prompt local_pub "Local reachable IPv4 or IPv6" "$local_pub" || return 1
  tm_prompt remote_pub "Remote reachable IPv4 or IPv6" || return 1
  tm_prompt local_tun "Local tunnel IP" || return 1
  tm_prompt remote_tun "Remote tunnel IP" || return 1
  if [[ "$local_tun" == *:* ]]; then
    tm_prompt cidr "Prefix length" "64" || return 1
  else
    tm_prompt cidr "Prefix length" "30" || return 1
  fi
  tm_prompt wan "WAN interface" "$wan" || return 1
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

tm_menu_quick_setup() {
  local role="" local_pub="" remote_pub="" wan="" peer="" ssh_port=""
  local local_tun="" remote_tun=""
  wan=$(tm_detect_default_iface || true)
  if [[ -n "$wan" ]]; then
    local_pub=$(tm_detect_iface_ipv4 "$wan" || true)
  fi
  ssh_port=$(tm_menu_ssh_port)
  if [[ -f "$(tm_tunnel_file edge)" ]]; then
    tm_info "Tunnel edge already exists. Its public key is printed below."
    tm_print_public_key edge || tm_die "Tunnel edge has no public key."
    tm_info "On the other server, choose Paste the other server public key."
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
  tm_prompt local_pub "This server reachable IP" "$local_pub" || return 1
  tm_prompt remote_pub "Other server reachable IP" || return 1
  tm_prompt wan "WAN interface" "$wan" || return 1
  tm_prompt peer "Other server public key, or Enter if you do not have it yet" "-" || return 1
  printf '\n%s\n' "WireGuard edge will use ${local_tun} on this server and ${remote_tun} on the other."
  printf '%s\n' "Listen port 51820, prefix 30, and the WAN interface are filled in automatically."
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

tm_menu() {
  local choice=""
  tm_info "Tunnel Manager does not flush firewall rules or change the default route."
  while true; do
    printf '\n%s\n' "Tunnel Manager ${TM_VERSION}"
    printf '%s\n' "  1) Quick WireGuard setup"
    printf '%s\n' "  2) Paste the other server public key"
    printf '%s\n' "  3) Show my public key"
    printf '%s\n' "  4) Forward a port"
    printf '%s\n' "  5) Test tunnel"
    printf '%s\n' "  6) Create tunnel (advanced)"
    printf '%s\n' "  7) Delete tunnel"
    printf '%s\n' "  8) Restart tunnel"
    printf '%s\n' "  9) Manage port forwards"
    printf '%s\n' " 10) Show status"
    printf '%s\n' " 11) Troubleshoot"
    printf '%s\n' " 12) Create backup"
    printf '%s\n' " 13) Restore backup"
    printf '%s\n' " 14) Apply saved state"
    printf '%s\n' " 15) Dry-run apply"
    printf '%s\n' " 16) Roll back an interrupted change"
    printf '%s\n' " 17) Update Tunnel Manager"
    printf '%s\n' "  0) Exit"
    tm_prompt choice "Choose" || return 1
    case "$choice" in
      1) tm_menu_run tm_menu_quick_setup ;;
      2) tm_menu_run tm_menu_paste_peer ;;
      3) tm_menu_show_key; tm_menu_pause ;;
      4) tm_menu_run tm_menu_quick_forward ;;
      5) tm_menu_named tm_action_tunnel_test ;;
      6) tm_menu_create_tunnel ;;
      7) tm_menu_named tm_action_tunnel_delete ;;
      8) tm_menu_named tm_action_tunnel_restart ;;
      9) tm_menu_forward ;;
      10) tm_action_status; tm_menu_pause ;;
      11) tm_menu_run tm_action_doctor ;;
      12)
        local output=""
        tm_prompt output "Backup output path" "${TM_VAR}/backups/manual.tar.gz" || continue
        tm_menu_run tm_action_backup_create --output "$output"
        ;;
      13)
        local file=""
        tm_prompt file "Backup file" || continue
        tm_menu_run tm_action_backup_restore --file "$file"
        ;;
      14) tm_menu_run tm_action_apply ;;
      15) tm_menu_run tm_action_apply --dry-run ;;
      16) tm_menu_run tm_action_rollback ;;
      17) tm_menu_run tm_action_update ;;
      0) tm_info "Goodbye."; return 0 ;;
      *) tm_warn "Unknown choice." ;;
    esac
  done
}
