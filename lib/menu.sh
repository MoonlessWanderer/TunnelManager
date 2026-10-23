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
    IFS=$' \t\n' read -r -a fields <<<"${SSH_CONNECTION}"
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

tm_menu_prompt_ipv4() {
  local -n _tm_v4=$1
  local label="$2"
  local other="${3:-}"
  local candidate=""
  candidate="${_tm_v4}"
  while true; do
    tm_menu_prompt_host_ip candidate "$label" "$other" || return 1
    if tm_valid_ipv4 "$candidate"; then
      _tm_v4="$candidate"
      return 0
    fi
    tm_warn "Enter an IPv4 address. The setup command supports IPv4."
    candidate=""
  done
}

tm_menu_saved_tcp_listen() {
  local listen="$1"
  local other
  local -A saved=()
  while IFS= read -r other; do
    [[ -n "$other" ]] || continue
    tm_forward_load "$other" saved || continue
    if [[ "${saved[TM_FORWARD_PROTO]:-}" == "tcp" && "${saved[TM_LISTEN_PORT]:-}" == "$listen" ]]; then
      return 0
    fi
  done < <(tm_list_forwards)
  return 1
}

tm_menu_collect_ports() {
  local -n _tm_spec=$1
  local required="$2"
  local line="" listen="" dest="" spec="" piece=""
  printf '\n%s\n' "TCP ports. One per line: 443 or 443=2053" >/dev/tty
  printf '%s\n' "Press Enter on an empty line to finish." >/dev/tty
  while true; do
    line=""
    tm_prompt line "TCP port" || return 1
    if [[ -z "$line" ]]; then
      if [[ "$required" == "yes" && -z "$spec" ]]; then
        tm_warn "A plain port forward needs at least one TCP port."
        continue
      fi
      _tm_spec="$spec"
      return 0
    fi
    if [[ "$line" == *=* ]]; then
      listen="${line%%=*}"
      dest="${line#*=}"
      piece="${listen}=${dest}"
    else
      listen="$line"
      dest="$line"
      piece="$listen"
    fi
    if ! tm_valid_port "$listen" || ! tm_valid_port "$dest"; then
      tm_warn "Use a port from 1 to 65535, or LISTEN=DEST."
      continue
    fi
    if tm_port_is_protected "$listen"; then
      tm_warn "Port ${listen} is reserved for SSH."
      continue
    fi
    if tm_setup_spec_has_listen "$spec" "$listen"; then
      tm_warn "Port ${listen} is already in this list."
      continue
    fi
    if tm_menu_saved_tcp_listen "$listen"; then
      tm_warn "Port ${listen} is already forwarded."
      continue
    fi
    if [[ -n "$spec" ]]; then
      spec="${spec},${piece}"
    else
      spec="$piece"
    fi
    tm_info "Added ${listen} -> ${dest}"
  done
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

tm_menu_setup_iran() {
  local local_pub="" remote_pub="" wan="" ssh_port="" kind=""
  local name="" local_tun="" remote_tun="" cidr="32" ports=""
  local saved_yes="" saved_gre=""
  ssh_port=$(tm_menu_ssh_port)
  tm_menu_prefill_uplink wan local_pub
  tm_menu_prompt_ipv4 local_pub "This server IPv4" || return 1
  tm_menu_prompt_ipv4 remote_pub "Foreign server IPv4" "$local_pub" || return 1
  kind=$(tm_menu_choose "Tunnel type" "Back" "Plain port forward" "GRE tunnel") || return 1
  case "$kind" in
    1) kind="forward" ;;
    2) kind="gre" ;;
    0) return 0 ;;
    *)
      tm_warn "Unknown choice."
      return 0
      ;;
  esac
  if [[ "$kind" == "gre" ]]; then
    local_tun="10.200.0.1"
    remote_tun="10.200.0.2"
    cidr="30"
    tm_prompt local_tun "Local tunnel IP" "$local_tun" || return 1
    tm_prompt remote_tun "Remote tunnel IP" "$remote_tun" || return 1
    tm_prompt cidr "Prefix length" "$cidr" || return 1
    if ! tm_tunnel_pair_ok "$local_tun" "$remote_tun" "$cidr"; then
      tm_warn "Those tunnel addresses are not two different hosts in one IPv4 prefix from 24 to 31."
      return 1
    fi
  else
    local_tun="$local_pub"
    remote_tun="$remote_pub"
  fi
  wan=$(tm_detect_wan "$wan" "$local_pub" "$remote_pub" || true)
  if ! tm_valid_iface "$wan" || ! tm_menu_iface_present "$wan"; then
    tm_menu_apply_iface wan || return 1
  fi
  if [[ "$kind" == "forward" ]]; then
    tm_menu_collect_ports ports yes || return 1
  else
    tm_menu_collect_ports ports no || return 1
  fi
  name=$(tm_setup_alloc_name "$kind") || return 1
  {
    printf '\n%s\n' "Iran ${local_pub} -> foreign ${remote_pub}"
    printf '%s\n' "Type ${kind}, name ${name}, WAN ${wan}"
    if [[ "$kind" == "gre" ]]; then
      printf '%s\n' "Inner ${local_tun} -> ${remote_tun}/${cidr}"
    fi
    if [[ -n "$ports" ]]; then
      printf '%s\n' "TCP ports ${ports}"
    else
      printf '%s\n' "No TCP ports. GRE tunnel only."
    fi
  } >/dev/tty
  if [[ "$kind" == "gre" ]]; then
    tm_gre_warning_text >/dev/tty
    if ! tm_confirm_phrase "GRE is not encrypted" "Type 'GRE is not encrypted' to continue:"; then
      tm_info "Setup was not started."
      return 0
    fi
  fi
  if ! tm_confirm "Apply this setup?"; then
    tm_info "Setup was not started."
    return 0
  fi
  saved_yes="${TM_YES:-0}"
  saved_gre="${TM_ALLOW_GRE:-0}"
  TM_YES=1
  if [[ "$kind" == "gre" ]]; then
    TM_ALLOW_GRE=1
  fi
  tm_menu_run tm_setup_apply_iran "$name" "$kind" "$local_pub" "$remote_pub" \
    "$local_tun" "$remote_tun" "$cidr" "$wan" "$ssh_port" "$ports"
  TM_YES="$saved_yes"
  TM_ALLOW_GRE="$saved_gre"
}

tm_menu_setup_foreign() {
  local pasted="" token="" saved_yes="" saved_gre=""
  local -A parsed=()
  tm_prompt pasted "Paste the setup command from the Iran server" || return 1
  if ! token=$(tm_setup_extract_token "$pasted"); then
    tm_warn "That text does not contain a setup command."
    return 1
  fi
  if ! tm_setup_parse_token "$token" parsed; then
    tm_warn "The setup command is invalid."
    return 1
  fi
  if [[ "${parsed[type]}" != "gre" ]]; then
    tm_menu_run tm_action_quick --token "$token"
    return 0
  fi
  tm_gre_warning_text >/dev/tty
  if ! tm_confirm_phrase "GRE is not encrypted" "Type 'GRE is not encrypted' to continue:"; then
    tm_info "Setup was not started."
    return 0
  fi
  if ! tm_confirm "Apply this GRE tunnel on the foreign server?"; then
    tm_info "Setup was not started."
    return 0
  fi
  saved_yes="${TM_YES:-0}"
  saved_gre="${TM_ALLOW_GRE:-0}"
  TM_YES=1
  TM_ALLOW_GRE=1
  tm_menu_run tm_action_quick --token "$token" --yes --i-understand-no-encryption
  TM_YES="$saved_yes"
  TM_ALLOW_GRE="$saved_gre"
}

tm_menu_show_tunnel() {
  local name="$1"
  local line
  local -A row=()
  tm_tunnel_load "$name" row || {
    tm_warn "Tunnel ${name} was not found."
    return 1
  }
  printf '\n%s\n' "name=${name}"
  printf '%s\n' "type=${row[TM_TUNNEL_TYPE]:-}"
  printf '%s\n' "state=${row[TM_TUNNEL_STATE]:-}"
  printf '%s\n' "public=${row[TM_LOCAL_PUBLIC_IP]:-} -> ${row[TM_REMOTE_PUBLIC_IP]:-}"
  if [[ "${row[TM_TUNNEL_TYPE]:-}" == "gre" ]]; then
    printf '%s\n' "inner=${row[TM_LOCAL_TUNNEL_IP]:-} -> ${row[TM_REMOTE_TUNNEL_IP]:-}/${row[TM_TUNNEL_CIDR]:-}"
    printf '%s\n' "interface=$(tm_tunnel_iface "$name")"
  fi
  printf '%s\n' "wan=${row[TM_WAN_IFACE]:-}"
  if tm_setup_forwards_for "$name" | grep -q .; then
    printf '%s\n' "ports:"
    while IFS= read -r line; do
      printf '  %s\n' "$line"
    done < <(tm_setup_forwards_for "$name")
  else
    printf '%s\n' "ports=none"
  fi
  tm_menu_pause
}

tm_menu_add_port() {
  local name="$1"
  local port_list="" saved_yes=""
  tm_menu_collect_ports port_list yes || return 1
  if ! tm_confirm "Add these TCP ports to ${name}?"; then
    tm_info "No ports were added."
    return 0
  fi
  saved_yes="${TM_YES:-0}"
  TM_YES=1
  tm_menu_run tm_setup_add_ports "$name" "$port_list"
  TM_YES="$saved_yes"
}

tm_menu_remove_port() {
  local tunnel="$1"
  local -a labels=() ids=()
  local line="" fname="" proto="" listen="" dest="" choice=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$' \t\n' read -r fname proto listen dest <<<"$line"
    ids+=("$fname")
    labels+=("${fname}  ${proto} ${listen} -> ${dest}")
  done < <(tm_setup_forwards_for "$tunnel")
  if [[ "${#ids[@]}" -eq 0 ]]; then
    tm_info "This tunnel has no port forwards."
    tm_menu_pause
    return 0
  fi
  choice=$(tm_menu_choose "Remove a TCP port" "Back" "${labels[@]}") || return 1
  if [[ "$choice" == "0" ]]; then
    return 0
  fi
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ids[@]} )); then
    tm_warn "Unknown choice."
    return 0
  fi
  tm_menu_run tm_action_forward_delete --name "${ids[$((choice - 1))]}"
}

tm_menu_tunnel() {
  local name="$1"
  local -A row=()
  local -a actions=()
  local choice="" label=""
  while true; do
    if ! tm_tunnel_load "$name" row; then
      tm_info "Tunnel ${name} is gone."
      return 0
    fi
    actions=("Show details" "Test" "Add a TCP port" "Remove a TCP port" "Delete")
    if [[ "${row[TM_TUNNEL_TYPE]:-}" == "gre" ]]; then
      actions=("Show details" "Test" "Add a TCP port" "Remove a TCP port" "Restart" "Delete")
    fi
    choice=$(tm_menu_choose "Tunnel ${name}" "Back" "${actions[@]}") || return 1
    if [[ "$choice" == "0" ]]; then
      return 0
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#actions[@]} )); then
      tm_warn "Unknown choice."
      continue
    fi
    label="${actions[$((choice - 1))]}"
    case "$label" in
      "Show details") tm_menu_show_tunnel "$name" ;;
      "Test") tm_menu_run tm_action_tunnel_test --name "$name" ;;
      "Add a TCP port") tm_menu_add_port "$name" ;;
      "Remove a TCP port") tm_menu_remove_port "$name" ;;
      "Restart") tm_menu_run tm_action_tunnel_restart --name "$name" ;;
      "Delete")
        tm_menu_run tm_action_tunnel_delete --name "$name"
        if [[ ! -f "$(tm_tunnel_file "$name")" ]]; then
          return 0
        fi
        ;;
      *) tm_warn "Unknown choice." ;;
    esac
  done
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
  printf '\n%s\n' "This deletes the program, saved tunnels, forwards, and logs."
  printf '%s\n' "A missing file is skipped. Other firewall rules stay in place."
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
    choice=$(tm_menu_choose "This server" "Back" "Iran" "Foreign") || return 1
    case "$choice" in
      1) tm_menu_setup_iran ;;
      2) tm_menu_setup_foreign ;;
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

tm_menu_leftover_ports() {
  local -a ids=() labels=()
  local line="" fname="" proto="" listen="" ref="" choice=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$' \t\n' read -r fname proto listen ref <<<"$line"
    ids+=("$fname")
    labels+=("${fname}  ${proto} ${listen}  tunnel ${ref} is gone")
  done < <(tm_forward_orphan_lines)
  if [[ "${#ids[@]}" -eq 0 ]]; then
    tm_info "No leftover ports are saved."
    tm_menu_pause
    return 0
  fi
  choice=$(tm_menu_choose "Leftover ports" "Back" "${labels[@]}") || return 1
  if [[ "$choice" == "0" ]]; then
    return 0
  fi
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ids[@]} )); then
    tm_warn "Unknown choice."
    return 0
  fi
  tm_menu_run tm_action_forward_delete --name "${ids[$((choice - 1))]}"
}

tm_menu_manage() {
  local -a names=() labels=() extras=()
  local name="" choice="" picked=""
  while true; do
    names=()
    labels=()
    extras=()
    if tm_forward_orphan_lines | grep -q .; then
      extras+=("Leftover ports")
    fi
    extras+=("Maintenance")
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      names+=("$name")
    done < <(tm_list_tunnels)
    if [[ "${#names[@]}" -eq 0 ]]; then
      tm_info "No tunnels are saved."
    fi
    labels=("${names[@]}" "${extras[@]}")
    choice=$(tm_menu_choose "Manage Tunnels" "Back" "${labels[@]}") || return 1
    if [[ "$choice" == "0" ]]; then
      return 0
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#labels[@]} )); then
      tm_warn "Unknown choice."
      continue
    fi
    if (( choice <= ${#names[@]} )); then
      tm_menu_tunnel "${names[$((choice - 1))]}"
      continue
    fi
    picked="${extras[$((choice - ${#names[@]} - 1))]}"
    case "$picked" in
      "Leftover ports") tm_menu_leftover_ports ;;
      "Maintenance") tm_menu_maintenance ;;
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
