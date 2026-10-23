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

tm_menu_add_forward() {
  local proto="$1"
  local name="" listen_port="" dest_ip="" dest_port="" source_ip="" ingress="" tunnel="" snat="auto"
  tm_prompt name "Forward name" || return 1
  tm_prompt listen_port "Listen port" || return 1
  tm_prompt dest_ip "Destination IP" || return 1
  tm_prompt dest_port "Destination port" "$listen_port" || return 1
  tm_prompt source_ip "Source tunnel IP" || return 1
  tm_prompt ingress "Ingress interface" || return 1
  tm_prompt tunnel "Existing tunnel name or '-' " "-" || return 1
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
  tm_prompt name "Tunnel name" || return 1
  tm_prompt type "Type: wireguard or gre" "wireguard" || return 1
  tm_prompt local_pub "Local reachable IPv4 or IPv6" || return 1
  tm_prompt remote_pub "Remote reachable IPv4 or IPv6" || return 1
  tm_prompt local_tun "Local tunnel IP" || return 1
  tm_prompt remote_tun "Remote tunnel IP" || return 1
  if [[ "$local_tun" == *:* ]]; then
    tm_prompt cidr "Prefix length" "64" || return 1
  else
    tm_prompt cidr "Prefix length" "30" || return 1
  fi
  tm_prompt wan "WAN interface" || return 1
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

tm_menu_named() {
  local action="$1"
  local name=""
  tm_prompt name "Tunnel name" || return 1
  tm_menu_run "$action" --name "$name"
}

tm_menu() {
  local choice=""
  tm_info "Tunnel Manager does not flush firewall rules or change the default route."
  while true; do
    printf '\n%s\n' "Tunnel Manager ${TM_VERSION}"
    printf '%s\n' "  1) Create tunnel"
    printf '%s\n' "  2) Delete tunnel"
    printf '%s\n' "  3) Restart tunnel"
    printf '%s\n' "  4) Test tunnel"
    printf '%s\n' "  5) Manage port forwards"
    printf '%s\n' "  6) Show status"
    printf '%s\n' "  7) Troubleshoot"
    printf '%s\n' "  8) Create backup"
    printf '%s\n' "  9) Restore backup"
    printf '%s\n' " 10) Apply saved state"
    printf '%s\n' " 11) Dry-run apply"
    printf '%s\n' " 12) Roll back an interrupted change"
    printf '%s\n' " 13) Update Tunnel Manager"
    printf '%s\n' "  0) Exit"
    tm_prompt choice "Choose" || return 1
    case "$choice" in
      1) tm_menu_create_tunnel ;;
      2) tm_menu_named tm_action_tunnel_delete ;;
      3) tm_menu_named tm_action_tunnel_restart ;;
      4) tm_menu_named tm_action_tunnel_test ;;
      5) tm_menu_forward ;;
      6) tm_action_status; tm_menu_pause ;;
      7) tm_menu_run tm_action_doctor ;;
      8)
        local output=""
        tm_prompt output "Backup output path" "${TM_VAR}/backups/manual.tar.gz" || continue
        tm_menu_run tm_action_backup_create --output "$output"
        ;;
      9)
        local file=""
        tm_prompt file "Backup file" || continue
        tm_menu_run tm_action_backup_restore --file "$file"
        ;;
      10) tm_menu_run tm_action_apply ;;
      11) tm_menu_run tm_action_apply --dry-run ;;
      12) tm_menu_run tm_action_rollback ;;
      13) tm_menu_run tm_action_update ;;
      0) tm_info "Goodbye."; return 0 ;;
      *) tm_warn "Unknown choice." ;;
    esac
  done
}
