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

# A note set here is shown once, on the next menu screen.
TM_MENU_NOTE=""
TM_MENU_STATUS=0

tm_menu_color_on() {
  case "${TM_MENU_COLOR:-auto}" in
    0|no|off) return 1 ;;
    1|yes|on) return 0 ;;
  esac
  tm_styled 2
}

tm_menu_sgr() {
  if ! tm_menu_color_on; then
    return 0
  fi
  case "$1" in
    dim) printf '\033[2m' ;;
    bold) printf '\033[1m' ;;
    accent) printf '\033[36m' ;;
    reset) printf '\033[0m' ;;
  esac
}

tm_menu_home() {
  if tm_tty_scripted || [[ "${TERM:-dumb}" == "dumb" || ! -t 2 || ! -w /dev/tty ]]; then
    return 0
  fi
  printf '\033[H\033[2J' >/dev/tty
}

tm_menu_header() {
  printf '\n  %sTunnel Manager%s\n' "$(tm_menu_sgr bold)" "$(tm_menu_sgr reset)"
  printf '  %s%s%s\n' "$(tm_menu_sgr dim)" "$1" "$(tm_menu_sgr reset)"
}

tm_menu_text() {
  tm_tty_printf '  %s\n' "$1"
}

tm_menu_hint() {
  tm_tty_printf '  %s%s%s\n' "$(tm_menu_sgr dim)" "$1" "$(tm_menu_sgr reset)"
}

tm_menu_row() {
  tm_tty_printf '  %s%-12s%s  %s\n' "$(tm_menu_sgr dim)" "$1" "$(tm_menu_sgr reset)" "$2"
}

tm_menu_pause() {
  local _unused=""
  if tm_tty_ready; then
    tm_tty_printf '\n  %sPress Enter to continue.%s ' "$(tm_menu_sgr dim)" "$(tm_menu_sgr reset)"
    tm_tty_read _unused || true
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
  TM_MENU_STATUS="$status"
  # Status 2 means the user declined, and the action already said so.
  if [[ "$status" -ne 0 && "$status" -ne 2 ]]; then
    tm_warn "The command exited with status ${status}."
  fi
  tm_menu_pause
}

tm_menu_render() {
  local title="$1"
  local exit_label="$2"
  shift 2
  local -a items=("$@")
  local i width accent="" reset=""
  accent=$(tm_menu_sgr accent)
  reset=$(tm_menu_sgr reset)
  width="${#items[@]}"
  width="${#width}"
  tm_menu_header "${title:-$TM_VERSION}"
  printf '\n'
  if [[ -n "${TM_MENU_NOTE:-}" ]]; then
    printf '  %s\n\n' "$TM_MENU_NOTE"
  fi
  if [[ -n "${TM_MENU_ALERT:-}" ]]; then
    printf '  %s! %s%s\n\n' "$(tm_menu_sgr bold)" "$TM_MENU_ALERT" "$reset"
  fi
  for i in "${!items[@]}"; do
    printf '  %s%*d%s  %s\n' "$accent" "$width" "$((i + 1))" "$reset" "${items[$i]}"
  done
  printf '\n  %s%*d%s  %s\n' "$accent" "$width" 0 "$reset" "$exit_label"
}

tm_menu_choice_index() {
  local raw="$1"
  local count="$2"
  local choice="$raw"
  choice="${choice#"${choice%%[![:space:]]*}"}"
  choice="${choice%"${choice##*[![:space:]]}"}"
  if [[ "$choice" =~ ^[0-9]+$ && ${#choice} -le 4 ]]; then
    if (( 10#$choice >= 0 && 10#$choice <= count )); then
      printf '%s\n' "$((10#$choice))"
      return 0
    fi
  fi
  return 1
}

tm_menu_choose() {
  local title="$1"
  local exit_label="$2"
  shift 2
  local -a items=("$@")
  local choice="" picked="" TM_MENU_ALERT=""
  if ! tm_tty_ready; then
    tm_die "A terminal is required for interactive input."
  fi
  while true; do
    tm_menu_home
    tm_tty_printf '%s\n\n' "$(tm_menu_render "$title" "$exit_label" "${items[@]}")"
    tm_tty_printf '  Enter your choice [0-%s]: ' "${#items[@]}"
    if ! tm_tty_read choice; then
      tm_tty_printf '\n'
      return 1
    fi
    if picked=$(tm_menu_choice_index "$choice" "${#items[@]}"); then
      tm_tty_printf '\n'
      printf '%s\n' "$picked"
      return 0
    fi
    TM_MENU_ALERT="Enter a number from the list."
  done
}

tm_menu_pick() {
  local -n _tm_picked=$1
  shift
  local _tm_pick_status=0
  _tm_picked=$(tm_menu_choose "$@") || _tm_pick_status=$?
  TM_MENU_NOTE=""
  return "$_tm_pick_status"
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
  local line="" listen="" dest="" spec="" piece="" user=""
  tm_tty_printf '\n'
  tm_menu_hint "TCP ports. One per line: 443 or 443=2053"
  tm_menu_hint "Press Enter on an empty line to finish."
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
    if user=$(tm_forward_port_user tcp "$listen"); then
      tm_warn "Port ${listen} is already used by ${user}."
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

tm_menu_boot_row() {
  if tm_use_systemd; then
    tm_menu_row "After reboot" "restored automatically"
  fi
}

tm_menu_gre_to() {
  local local_pub="$1"
  local remote_pub="$2"
  local name names=""
  local -A row=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_tunnel_load "$name" row || continue
    [[ "${row[TM_TUNNEL_TYPE]:-}" == "gre" ]] || continue
    [[ "${row[TM_LOCAL_PUBLIC_IP]:-}" == "$local_pub" && "${row[TM_REMOTE_PUBLIC_IP]:-}" == "$remote_pub" ]] || continue
    names+="${names:+, }${name}"
  done < <(tm_list_tunnels)
  printf '%s\n' "$names"
}

tm_menu_setup_iran() {
  local local_pub="" remote_pub="" wan="" ssh_port="" kind=""
  local name="" local_tun="" remote_tun="" cidr="32" ports="" saved_yes=""
  local other="" suggested=""
  ssh_port=$(tm_menu_ssh_port)
  tm_menu_prefill_uplink wan local_pub
  tm_menu_prompt_ipv4 local_pub "This server IPv4" || return 1
  tm_menu_prompt_ipv4 remote_pub "Foreign server IPv4" "$local_pub" || return 1
  tm_menu_pick kind "Tunnel type" "Back" "Plain port forward" "GRE tunnel" || return 1
  case "$kind" in
    1) kind="forward" ;;
    2) kind="gre" ;;
    *) return 0 ;;
  esac
  if [[ "$kind" == "gre" ]]; then
    other=$(tm_menu_gre_to "$local_pub" "$remote_pub")
    if [[ -n "$other" ]]; then
      tm_menu_hint "Already connected to ${remote_pub} by ${other}. Manage Tunnels adds ports to it."
      tm_menu_hint "Continue for one more tunnel with its own subnet and GRE key."
    fi
    local_tun="10.200.0.1"
    remote_tun="10.200.0.2"
    if suggested=$(tm_setup_suggest_inner "$local_pub" "$remote_pub"); then
      IFS=$' \t\n' read -r local_tun remote_tun <<<"$suggested"
    fi
    cidr="30"
    while true; do
      tm_prompt local_tun "Local tunnel IP" "$local_tun" || return 1
      tm_prompt remote_tun "Remote tunnel IP" "$remote_tun" || return 1
      tm_prompt cidr "Prefix length" "$cidr" || return 1
      if ! tm_tunnel_pair_ok "$local_tun" "$remote_tun" "$cidr"; then
        tm_warn "Use two different IPv4 hosts in one prefix from 24 to 31."
        continue
      fi
      if other=$(tm_tunnel_inner_owner "$local_tun" "$cidr"); then
        tm_warn "Tunnel ${other} already uses this subnet. Choose other inner addresses."
        continue
      fi
      if other=$(tm_tunnel_host_owner "$local_tun" "$cidr"); then
        tm_warn "${other%% *} already uses ${other#* }. Choose other inner addresses."
        continue
      fi
      break
    done
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
  if ! name=$(tm_setup_alloc_name "$kind"); then
    TM_MENU_NOTE="Setup was not started. No free tunnel name is left."
    return 0
  fi
  tm_tty_printf '\n'
  tm_menu_row "This server" "$local_pub"
  tm_menu_row "Foreign" "$remote_pub"
  if [[ "$kind" == "gre" ]]; then
    tm_menu_row "Type" "GRE"
    tm_menu_row "Inner" "${local_tun} -> ${remote_tun}/${cidr}"
    tm_menu_row "GRE key" "$(tm_gre_key_for "$local_tun" "$cidr" || true)"
  else
    tm_menu_row "Type" "Port forward"
  fi
  tm_menu_row "Name" "$name"
  tm_menu_row "WAN" "$wan"
  tm_menu_row "Ports" "$(tm_setup_ports_label "$ports")"
  tm_menu_boot_row
  tm_tty_printf '\n'
  if ! tm_confirm "Apply this setup?"; then
    TM_MENU_NOTE="Setup was not started."
    return 0
  fi
  saved_yes="${TM_YES:-0}"
  TM_YES=1
  tm_menu_run tm_setup_apply_iran "$name" "$kind" "$local_pub" "$remote_pub" \
    "$local_tun" "$remote_tun" "$cidr" "$wan" "$ssh_port" "$ports"
  TM_YES="$saved_yes"
}

tm_menu_setup_foreign() {
  local pasted="" token="" saved_yes="" conflict="" name=""
  local -A parsed=()
  tm_menu_hint "Press Enter on an empty line to go back."
  while true; do
    pasted=""
    tm_prompt pasted "Paste the setup command from the Iran server" || return 1
    if [[ -z "$pasted" ]]; then
      return 0
    fi
    if ! token=$(tm_setup_extract_token "$pasted"); then
      tm_warn "$(tm_setup_no_token_message "$pasted")"
      continue
    fi
    parsed=()
    if tm_setup_parse_token "$token" parsed; then
      break
    fi
    tm_warn "The setup command is invalid."
  done
  if [[ "${parsed[type]}" != "gre" ]]; then
    tm_menu_run tm_action_quick --token "$token"
    return 0
  fi
  if conflict=$(tm_setup_foreign_conflict parsed); then
    TM_MENU_NOTE="$conflict"
    return 0
  fi
  if ! name=$(tm_setup_foreign_name "${parsed[name]}"); then
    TM_MENU_NOTE="Setup was not started. No free tunnel name is left."
    return 0
  fi
  tm_tty_printf '\n'
  tm_menu_row "This server" "${parsed[foreign_ip]}"
  tm_menu_row "Iran" "${parsed[iran_ip]}"
  tm_menu_row "Type" "GRE"
  tm_menu_row "Inner" "${parsed[foreign_tun]} -> ${parsed[iran_tun]}/${parsed[cidr]}"
  tm_menu_row "GRE key" "${parsed[key]}"
  tm_menu_row "Name" "$name"
  tm_menu_boot_row
  tm_tty_printf '\n'
  if ! tm_confirm "Apply this GRE tunnel on the foreign server?"; then
    TM_MENU_NOTE="Setup was not started."
    return 0
  fi
  saved_yes="${TM_YES:-0}"
  TM_YES=1
  tm_menu_run tm_action_quick --token "$token" --yes
  TM_YES="$saved_yes"
}

tm_menu_show_tunnel() {
  local name="$1"
  local line="" kind="" fname="" proto="" listen="" dest="" label="Ports"
  local -A row=()
  if ! tm_tunnel_load "$name" row; then
    TM_MENU_NOTE="Tunnel ${name} was not found."
    return 0
  fi
  kind="${row[TM_TUNNEL_TYPE]:-}"
  tm_menu_home
  tm_tty_printf '%s\n\n' "$(tm_menu_header "Tunnel ${name}")"
  case "$kind" in
    gre) tm_menu_row "Type" "GRE" ;;
    forward) tm_menu_row "Type" "Port forward" ;;
    *) tm_menu_row "Type" "$kind" ;;
  esac
  tm_menu_row "State" "${row[TM_TUNNEL_STATE]:-}"
  tm_menu_row "Public" "${row[TM_LOCAL_PUBLIC_IP]:-} -> ${row[TM_REMOTE_PUBLIC_IP]:-}"
  if [[ "$kind" == "gre" ]]; then
    tm_menu_row "Inner" "${row[TM_LOCAL_TUNNEL_IP]:-} -> ${row[TM_REMOTE_TUNNEL_IP]:-}/${row[TM_TUNNEL_CIDR]:-}"
    tm_menu_row "GRE key" "${row[TM_GRE_KEY]:-none}"
    tm_menu_row "Interface" "$(tm_tunnel_iface "$name")"
  fi
  tm_menu_row "WAN" "${row[TM_WAN_IFACE]:-}"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$' \t\n' read -r fname proto listen dest <<<"$line"
    tm_menu_row "$label" "${proto} ${listen} -> ${dest}"
    label=""
  done < <(tm_setup_forwards_for "$name")
  if [[ -n "$label" ]]; then
    tm_menu_row "Ports" "none"
  fi
  tm_menu_pause
}

tm_menu_add_port() {
  local name="$1"
  local port_list="" saved_yes=""
  tm_menu_collect_ports port_list yes || return 1
  tm_tty_printf '\n'
  tm_menu_row "Ports" "$(tm_setup_ports_label "$port_list")"
  tm_menu_boot_row
  tm_tty_printf '\n'
  if ! tm_confirm "Add these TCP ports to ${name}?"; then
    TM_MENU_NOTE="No ports were added."
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
    TM_MENU_NOTE="This tunnel has no TCP ports."
    return 0
  fi
  tm_menu_pick choice "Remove a TCP port" "Back" "${labels[@]}" || return 1
  if [[ "$choice" == "0" ]]; then
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
      TM_MENU_NOTE="Tunnel ${name} is gone."
      return 0
    fi
    actions=("Show details" "Test" "Add a TCP port" "Remove a TCP port")
    if [[ "${row[TM_TUNNEL_TYPE]:-}" == "gre" ]]; then
      actions+=("Restart")
    fi
    actions+=("Delete")
    tm_menu_pick choice "Tunnel ${name}" "Back" "${actions[@]}" || return 1
    if [[ "$choice" == "0" ]]; then
      return 0
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
  if ! script=$(tm_menu_uninstall_script); then
    TM_MENU_NOTE="uninstall.sh was not found. Reinstall Tunnel Manager."
    return 0
  fi
  prefix="${TM_PREFIX:-/usr/local}"
  tm_menu_text "This deletes the program, saved tunnels, forwards, and logs."
  tm_menu_text "A missing file is skipped. Other firewall rules stay in place."
  tm_tty_printf '\n'
  if ! tm_confirm "Uninstall Tunnel Manager?"; then
    TM_MENU_NOTE="Uninstall was not started."
    return 0
  fi
  bash "$script" --prefix "$prefix" --yes --purge-state
  exit 0
}

tm_menu_configure() {
  local choice=""
  while true; do
    tm_menu_pick choice "This server" "Back" "Iran" "Foreign" || return 1
    case "$choice" in
      1) tm_menu_setup_iran ;;
      2) tm_menu_setup_foreign ;;
      *) return 0 ;;
    esac
  done
}

tm_menu_status() {
  tm_action_status | sed 's/^/  /'
}

tm_menu_maintenance() {
  local choice="" output="" file=""
  while true; do
    tm_menu_pick choice "Maintenance" "Back" \
      "Status" \
      "Troubleshoot" \
      "Backup" \
      "Restore" \
      "Apply saved state" \
      "Dry-run apply" \
      "Roll back" || return 1
    case "$choice" in
      1) tm_menu_run tm_menu_status ;;
      2) tm_menu_run tm_action_doctor ;;
      3)
        tm_prompt output "Backup output path" "${TM_VAR}/backups/manual.tar.gz" || continue
        tm_menu_run tm_action_backup_create --output "$output"
        ;;
      4)
        file=""
        tm_prompt file "Backup file" || continue
        [[ -n "$file" ]] || continue
        tm_menu_run tm_action_backup_restore --file "$file"
        ;;
      5) tm_menu_run tm_action_apply ;;
      6) tm_menu_run tm_action_apply --dry-run ;;
      7) tm_menu_run tm_action_rollback ;;
      *) return 0 ;;
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
    TM_MENU_NOTE="No leftover ports are saved."
    return 0
  fi
  tm_menu_pick choice "Leftover ports" "Back" "${labels[@]}" || return 1
  if [[ "$choice" == "0" ]]; then
    return 0
  fi
  tm_menu_run tm_action_forward_delete --name "${ids[$((choice - 1))]}"
}

tm_menu_tunnel_label() {
  local name="$1"
  local kind=""
  local -A row=()
  if ! tm_tunnel_load "$name" row; then
    printf '%s\n' "$name"
    return 0
  fi
  case "${row[TM_TUNNEL_TYPE]:-}" in
    gre) kind="GRE" ;;
    forward) kind="Port forward" ;;
    *) kind="${row[TM_TUNNEL_TYPE]:-}" ;;
  esac
  printf '%-12s  %s -> %s\n' "$name" "$kind" "${row[TM_REMOTE_PUBLIC_IP]:-}"
}

tm_menu_manage() {
  local -a names=() labels=() extras=()
  local name="" choice="" picked="" orphans=""
  while true; do
    names=()
    extras=()
    orphans=$(tm_forward_orphan_lines || true)
    if [[ -n "$orphans" ]]; then
      extras+=("Leftover ports")
    fi
    extras+=("Maintenance")
    labels=()
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      names+=("$name")
      labels+=("$(tm_menu_tunnel_label "$name")")
    done < <(tm_list_tunnels)
    if [[ "${#names[@]}" -eq 0 && -z "$TM_MENU_NOTE" ]]; then
      TM_MENU_NOTE="No tunnels are saved."
    fi
    labels+=("${extras[@]}")
    tm_menu_pick choice "Manage Tunnels" "Back" "${labels[@]}" || return 1
    if [[ "$choice" == "0" ]]; then
      return 0
    fi
    if (( choice <= ${#names[@]} )); then
      tm_menu_tunnel "${names[$((choice - 1))]}"
      continue
    fi
    picked="${extras[$((choice - ${#names[@]} - 1))]}"
    case "$picked" in
      "Leftover ports") tm_menu_leftover_ports ;;
      "Maintenance") tm_menu_maintenance ;;
    esac
  done
}

tm_menu_bbr_label() {
  if tm_bbr_persistent; then
    printf '%s\n' "Disable BBR"
  else
    printf '%s\n' "Enable BBR"
  fi
}

tm_menu_update() {
  local prefix=""
  tm_menu_run tm_action_update
  if [[ "$TM_MENU_STATUS" -ne 0 || "${TM_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  prefix=$(tm_install_prefix) || return 0
  if [[ -x "${prefix}/bin/tunnel-manager" ]]; then
    unset TM_LIB_DIR TM_PREFIX
    exec "${prefix}/bin/tunnel-manager" menu
  fi
}

tm_menu() {
  local choice="" bbr_label=""
  TM_MENU_FACE=1
  while true; do
    bbr_label=$(tm_menu_bbr_label)
    tm_menu_pick choice "" "Exit" \
      "Configure a New Tunnel" \
      "Manage Tunnels" \
      "Update" \
      "Uninstall" \
      "$bbr_label" || return 1
    case "$choice" in
      1) tm_menu_configure ;;
      2) tm_menu_manage ;;
      3) tm_menu_update ;;
      4) tm_menu_uninstall ;;
      5)
        if [[ "$bbr_label" == "Disable BBR" ]]; then
          tm_menu_run tm_action_bbr_disable
        else
          tm_menu_run tm_action_bbr_enable
        fi
        ;;
      *)
        tm_info "Goodbye."
        return 0
        ;;
    esac
  done
}
