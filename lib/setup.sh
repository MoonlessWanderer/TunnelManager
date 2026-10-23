# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — one-step Iran and foreign setup.
# The setup command carries public addresses and GRE inner addresses only.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "setup.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_SETUP_LOADED:-}" ]]; then
  return 0
fi
TM_SETUP_LOADED=1

tm_setup_alloc_name() {
  local kind="$1"
  local base="fwd" candidate n=2
  if [[ "$kind" == "gre" ]]; then
    base="edge"
  fi
  candidate="$base"
  while [[ -f "$(tm_tunnel_file "$candidate")" ]]; do
    candidate="${base}${n}"
    n=$((n + 1))
    if (( n > 99 )); then
      tm_error "Could not choose a free tunnel name."
      return 1
    fi
  done
  tm_valid_tunnel_name "$candidate" || return 1
  printf '%s\n' "$candidate"
}

tm_setup_forward_name() {
  local listen="$1"
  local dest="$2"
  local base candidate n=2
  if [[ "$listen" == "$dest" ]]; then
    base="p${listen}"
  else
    base="p${listen}-${dest}"
  fi
  if (( ${#base} > 20 )); then
    base="p${listen}"
  fi
  candidate="$base"
  while [[ -f "$(tm_forward_file "$candidate")" ]]; do
    candidate="${base}-${n}"
    n=$((n + 1))
    if (( ${#candidate} > 20 || n > 99 )); then
      tm_error "Could not name the forward for port ${listen}."
      return 1
    fi
  done
  tm_valid_forward_name "$candidate" || return 1
  printf '%s\n' "$candidate"
}

tm_setup_spec_has_listen() {
  local spec="$1"
  local listen="$2"
  local item got
  local -a items=()
  [[ -n "$spec" ]] || return 1
  IFS=',' read -r -a items <<<"$spec"
  for item in "${items[@]}"; do
    if [[ "$item" == *=* ]]; then
      got="${item%%=*}"
    else
      got="$item"
    fi
    if [[ "$got" == "$listen" ]]; then
      return 0
    fi
  done
  return 1
}

tm_setup_split_ports() {
  local spec="$1"
  local -n _tm_listen=$2
  local -n _tm_dest=$3
  local -a items=()
  local item listen dest seen=""
  _tm_listen=()
  _tm_dest=()
  [[ -n "$spec" ]] || return 0
  IFS=',' read -r -a items <<<"$spec"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || return 1
    if [[ "$item" == *=* ]]; then
      listen="${item%%=*}"
      dest="${item#*=}"
    else
      listen="$item"
      dest="$item"
    fi
    tm_valid_port "$listen" || {
      tm_error "Invalid listen port ${listen}."
      return 1
    }
    tm_valid_port "$dest" || {
      tm_error "Invalid destination port ${dest}."
      return 1
    }
    if tm_port_is_protected "$listen"; then
      tm_error "Refusing to listen on protected port ${listen}."
      return 1
    fi
    if tm_setup_spec_has_listen "$seen" "$listen"; then
      tm_error "Listen port ${listen} is listed more than once."
      return 1
    fi
    if [[ -n "$seen" ]]; then
      seen="${seen},${listen}"
    else
      seen="$listen"
    fi
    _tm_listen+=("$listen")
    _tm_dest+=("$dest")
  done
}

tm_setup_token() {
  local type="$1"
  local name="$2"
  local iran_ip="$3"
  local foreign_ip="$4"
  local iran_tun="$5"
  local foreign_tun="$6"
  local cidr="$7"
  local key="${8:-0}"
  printf 'v2:%s:%s:%s:%s:%s:%s:%s:%s\n' \
    "$type" "$name" "$iran_ip" "$foreign_ip" "$iran_tun" "$foreign_tun" "$cidr" "$key"
}

tm_setup_extract_token() {
  local text="$1"
  local pattern='v2:(gre|forward):[a-z][a-z0-9-]{0,11}(:[0-9]{1,3}(\.[0-9]{1,3}){3}){4}:[0-9]{1,3}:[0-9]{1,10}'
  if [[ "$text" =~ $pattern ]]; then
    printf '%s\n' "${BASH_REMATCH[0]}"
    return 0
  fi
  return 1
}

tm_setup_no_token_message() {
  local text="$1"
  if [[ "$text" =~ v[0-9]+:(gre|forward): ]]; then
    printf '%s\n' "This setup command comes from a different Tunnel Manager version. Update both servers, then run setup on Iran again."
  else
    printf '%s\n' "That text does not contain a setup command."
  fi
}

tm_setup_parse_token() {
  local token="$1"
  local -n _tm_spec=$2
  local -a parts=()
  IFS=':' read -r -a parts <<<"$token"
  [[ "${#parts[@]}" -eq 9 ]] || return 1
  [[ "${parts[0]}" == "v2" ]] || return 1
  _tm_spec[type]="${parts[1]}"
  _tm_spec[name]="${parts[2]}"
  _tm_spec[iran_ip]="${parts[3]}"
  _tm_spec[foreign_ip]="${parts[4]}"
  _tm_spec[iran_tun]="${parts[5]}"
  _tm_spec[foreign_tun]="${parts[6]}"
  _tm_spec[cidr]="${parts[7]}"
  _tm_spec[key]="${parts[8]}"
  tm_valid_tunnel_type "${_tm_spec[type]}" || return 1
  tm_valid_tunnel_name "${_tm_spec[name]}" || return 1
  tm_valid_ipv4 "${_tm_spec[iran_ip]}" || return 1
  tm_valid_ipv4 "${_tm_spec[foreign_ip]}" || return 1
  tm_valid_ipv4 "${_tm_spec[iran_tun]}" || return 1
  tm_valid_ipv4 "${_tm_spec[foreign_tun]}" || return 1
  tm_public_pair_ok "${_tm_spec[iran_ip]}" "${_tm_spec[foreign_ip]}" || return 1
  if [[ "${_tm_spec[type]}" == "gre" ]]; then
    tm_tunnel_pair_ok "${_tm_spec[iran_tun]}" "${_tm_spec[foreign_tun]}" "${_tm_spec[cidr]}" || return 1
    tm_valid_gre_key "${_tm_spec[key]}" || return 1
  else
    [[ "${_tm_spec[cidr]}" == "32" ]] || return 1
    [[ "${_tm_spec[iran_tun]}" == "${_tm_spec[iran_ip]}" ]] || return 1
    [[ "${_tm_spec[foreign_tun]}" == "${_tm_spec[foreign_ip]}" ]] || return 1
    [[ "${_tm_spec[key]}" == "0" ]] || return 1
  fi
  return 0
}

tm_setup_address_present() {
  local want="$1"
  local line
  tm_valid_ipv4 "$want" || return 1
  while IFS= read -r line; do
    [[ "$line" == *" inet ${want}/"* || "$line" == *" inet ${want} "* ]] && return 0
  done < <(tm_run_quiet ip -o -4 addr show 2>/dev/null || true)
  return 1
}

# Prints "ADDR PREFIX MODE" for every network a new inner subnet must avoid:
# saved GRE tunnels clash on any overlap, host addresses follow
# tm_inner_clashes_with.
tm_setup_taken_networks() {
  local name iface addr prefix
  local -A row=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_tunnel_load "$name" row || continue
    [[ "${row[TM_TUNNEL_TYPE]:-}" == "gre" ]] || continue
    printf '%s %s overlap\n' "${row[TM_LOCAL_TUNNEL_IP]:-}" "${row[TM_TUNNEL_CIDR]:-}"
  done < <(tm_list_tunnels)
  while IFS=' ' read -r iface addr prefix; do
    [[ -n "$addr" ]] || continue
    printf '%s %s host\n' "$addr" "$prefix"
  done < <(tm_host_addresses)
}

tm_setup_inner_free() {
  local local_tun="$1"
  local cidr="$2"
  shift 2
  local entry addr prefix mode
  for entry in "$@"; do
    IFS=' ' read -r addr prefix mode <<<"$entry"
    if [[ "$mode" == "overlap" ]]; then
      tm_ip_subnets_overlap "$addr" "$prefix" "$local_tun" "$cidr" && return 1
    else
      tm_inner_clashes_with "$addr" "$prefix" "$local_tun" "$cidr" && return 1
    fi
  done
  return 0
}

# Prints "LOCAL REMOTE" for a free /30 in 10.200.0.0/16. The search starts at a
# hash of both public addresses, so Iran servers that share one foreign server
# rarely pick the same block.
tm_setup_suggest_inner() {
  local local_pub="$1"
  local remote_pub="$2"
  local seed i n base local_tun
  local -a taken=()
  seed=$(printf '%s %s' "$local_pub" "$remote_pub" | cksum)
  seed=${seed%% *}
  mapfile -t taken < <(tm_setup_taken_networks)
  for ((i = 0; i < 16384; i++)); do
    n=$(((seed + i) % 16384))
    base="10.200.$((n >> 6))"
    local_tun="${base}.$(((n & 63) * 4 + 1))"
    if tm_setup_inner_free "$local_tun" 30 "${taken[@]}"; then
      printf '%s %s\n' "$local_tun" "${base}.$(((n & 63) * 4 + 2))"
      return 0
    fi
  done
  return 1
}

# Prints why this GRE setup command cannot be used on this server.
tm_setup_foreign_conflict() {
  local -n _tm_tok=$1
  local other
  local redo="On the Iran server, delete tunnel ${_tm_tok[name]} and set it up again with other inner addresses."
  if other=$(tm_tunnel_pair_owner "${_tm_tok[foreign_ip]}" "${_tm_tok[iran_ip]}" "${_tm_tok[key]}"); then
    printf '%s\n' "This GRE tunnel is already set up here as ${other}."
    return 0
  fi
  if other=$(tm_tunnel_inner_owner "${_tm_tok[foreign_tun]}" "${_tm_tok[cidr]}"); then
    printf '%s\n' "Inner subnet ${_tm_tok[foreign_tun]}/${_tm_tok[cidr]} is already used here by tunnel ${other}. ${redo}"
    return 0
  fi
  if other=$(tm_tunnel_host_owner "${_tm_tok[foreign_tun]}" "${_tm_tok[cidr]}"); then
    printf '%s\n' "Inner subnet ${_tm_tok[foreign_tun]}/${_tm_tok[cidr]} clashes with ${other#* } on ${other%% *} here. ${redo}"
    return 0
  fi
  return 1
}

tm_setup_foreign_name() {
  local wanted="$1"
  if [[ ! -f "$(tm_tunnel_file "$wanted")" ]]; then
    printf '%s\n' "$wanted"
    return 0
  fi
  tm_setup_alloc_name gre
}

tm_setup_print_foreign() {
  local type="$1"
  local name="$2"
  local iran_ip="$3"
  local foreign_ip="$4"
  local iran_tun="$5"
  local foreign_tun="$6"
  local cidr="$7"
  local key="$8"
  local ports="$9"
  local token bold="" reset=""
  token=$(tm_setup_token "$type" "$name" "$iran_ip" "$foreign_ip" "$iran_tun" "$foreign_tun" "$cidr" "$key")
  if tm_styled 1; then
    bold=$'\033[1m'
    reset=$'\033[0m'
  fi
  if [[ "$type" == "gre" ]]; then
    printf '\n  %s\n\n' "On the foreign server, install Tunnel Manager if needed, then run:"
    printf '    %s%s%s\n\n' "$bold" "sudo tunnel-manager quick ${token}" "$reset"
    if [[ -n "$ports" ]]; then
      printf '  %s\n' "Forwarded TCP ports stay on this Iran server: $(tm_setup_ports_label "$ports")"
    else
      printf '  %s\n' "No TCP ports were forwarded. This GRE tunnel carries traffic only."
    fi
    return 0
  fi
  printf '\n  %s\n' "No tunnel command is required on the foreign server."
  printf '  %s\n' "Keep these TCP services listening there: $(tm_setup_ports_label "$ports")"
}

tm_setup_ports_label() {
  local spec="$1"
  local item out=""
  local -a items=()
  if [[ -z "$spec" ]]; then
    printf '%s\n' "none"
    return 0
  fi
  IFS=',' read -r -a items <<<"$spec"
  for item in "${items[@]}"; do
    if [[ "$item" == *=* ]]; then
      item="${item%%=*} -> ${item#*=}"
    fi
    out+="${out:+, }${item}"
  done
  printf '%s\n' "$out"
}

tm_setup_ensure_boot() {
  if ! tm_use_systemd || tm_service_boot_enabled; then
    return 0
  fi
  if ! (tm_action_service_enable); then
    tm_warn "Saved tunnels will not return after reboot until you run: sudo tunnel-manager service enable"
  fi
}

tm_setup_forwards_for() {
  local tunnel="$1"
  local name
  local -A row=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tm_forward_load "$name" row || continue
    if [[ "${row[TM_TUNNEL_REF]:-}" == "$tunnel" ]]; then
      printf '%s %s %s %s\n' "$name" "${row[TM_FORWARD_PROTO]:-tcp}" \
        "${row[TM_LISTEN_PORT]:-}" "${row[TM_DEST_PORT]:-}"
    fi
  done < <(tm_list_forwards)
}

tm_setup_abort_new_tunnel() {
  local name="$1"
  if [[ "${TM_DRY_RUN:-0}" == "1" || ! -f "$(tm_tunnel_file "$name")" ]]; then
    return 0
  fi
  tm_error "Setup failed. Removing unfinished tunnel ${name}."
  if ! (
    tm_action_tunnel_delete --name "$name" --yes
  ); then
    tm_error "Tunnel ${name} is still saved."
  fi
}

tm_setup_add_ports() {
  local name="$1"
  local ports="$2"
  local -a listen_ports=() dest_ports=()
  local i fname
  [[ -f "$(tm_tunnel_file "$name")" ]] || {
    tm_error "Tunnel ${name} was not found."
    return 1
  }
  tm_setup_reject_taken_ports "$ports" || return 1
  tm_setup_split_ports "$ports" listen_ports dest_ports || return 1
  if [[ "${#listen_ports[@]}" -eq 0 ]]; then
    tm_error "Enter at least one TCP port."
    return 1
  fi
  for i in "${!listen_ports[@]}"; do
    fname=$(tm_setup_forward_name "${listen_ports[$i]}" "${dest_ports[$i]}") || return 1
    tm_action_forward_add --name "$fname" --proto tcp \
      --listen-port "${listen_ports[$i]}" --dest-port "${dest_ports[$i]}" \
      --tunnel "$name" --snat auto --yes || return 1
  done
  tm_setup_ensure_boot
}

tm_setup_reject_taken_ports() {
  local ports="$1"
  local -a listen_ports=() dest_ports=()
  local i
  tm_setup_split_ports "$ports" listen_ports dest_ports || return 1
  for i in "${!listen_ports[@]}"; do
    if tm_forward_listen_conflict "_" "tcp" "0.0.0.0" "${listen_ports[$i]}"; then
      tm_error "A tcp forward already listens on 0.0.0.0:${listen_ports[$i]}."
      return 1
    fi
    tm_forward_reject_port_user tcp "${listen_ports[$i]}" || return 1
  done
}

tm_setup_apply_iran() {
  local name="$1"
  local type="$2"
  local local_pub="$3"
  local remote_pub="$4"
  local local_tun="$5"
  local remote_tun="$6"
  local cidr="$7"
  local wan="$8"
  local ssh_port="$9"
  local ports="${10}"
  local -a listen_ports=() dest_ports=()
  local -a create_args=()
  local i fname key=0
  tm_setup_reject_taken_ports "$ports" || return 1
  tm_setup_split_ports "$ports" listen_ports dest_ports || return 1
  if [[ "$type" == "forward" && "${#listen_ports[@]}" -eq 0 ]]; then
    tm_error "A plain port forward needs at least one TCP port."
    return 1
  fi
  if [[ ! -f "$(tm_host_file)" ]]; then
    tm_action_init --role iran --public-ip "$local_pub" --wan-iface "$wan" \
      --ssh-port "$ssh_port" --yes || return 1
  fi
  create_args=(
    --name "$name" --type "$type"
    --local-public-ip "$local_pub" --remote-public-ip "$remote_pub"
    --local-tunnel-ip "$local_tun" --remote-tunnel-ip "$remote_tun"
    --cidr "$cidr" --wan-iface "$wan" --yes
  )
  if [[ "$type" == "gre" ]] && key=$(tm_gre_key_for "$local_tun" "$cidr"); then
    create_args+=(--key "$key")
  fi
  tm_action_tunnel_create "${create_args[@]}" || return 1
  for i in "${!listen_ports[@]}"; do
    fname=$(tm_setup_forward_name "${listen_ports[$i]}" "${dest_ports[$i]}") || {
      tm_setup_abort_new_tunnel "$name"
      return 1
    }
    if ! (
      tm_action_forward_add --name "$fname" --proto tcp \
        --listen-port "${listen_ports[$i]}" --dest-port "${dest_ports[$i]}" \
        --tunnel "$name" --snat auto --yes
    ); then
      tm_setup_abort_new_tunnel "$name"
      return 1
    fi
  done
  tm_setup_ensure_boot
  if [[ "${TM_DRY_RUN:-0}" != "1" ]]; then
    tm_setup_print_foreign "$type" "$name" "$local_pub" "$remote_pub" \
      "$local_tun" "$remote_tun" "$cidr" "$key" "$ports"
  fi
}

tm_action_quick() {
  local token="" pasted="" wan ssh_port name conflict
  local -A spec=()
  local -a flags=() create_args=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --yes)
        TM_YES=1
        shift
        ;;
      --dry-run)
        TM_DRY_RUN=1
        shift
        ;;
      --token)
        [[ "$#" -ge 2 ]] || tm_die "Missing value for --token."
        token="$2"
        shift 2
        ;;
      --*)
        tm_die "Unknown option $1"
        ;;
      *)
        [[ -z "$token" ]] || tm_die "Unexpected argument: $1"
        token="$1"
        shift
        ;;
    esac
  done
  [[ -n "$token" ]] || tm_die "Paste the setup command from the Iran server."
  pasted="$token"
  token=$(tm_setup_extract_token "$pasted") || tm_die "$(tm_setup_no_token_message "$pasted")"
  tm_setup_parse_token "$token" spec || tm_die "The setup command is invalid."
  if [[ "${spec[type]}" == "forward" ]]; then
    tm_info "A plain port forward is configured on the Iran server."
    tm_info "No tunnel is created on this server. The destination service must already be listening."
    return 0
  fi
  local saved_dry="${TM_DRY_RUN:-0}"
  TM_DRY_RUN=0
  if ! tm_setup_address_present "${spec[foreign_ip]}"; then
    TM_DRY_RUN="$saved_dry"
    tm_die "This server does not have address ${spec[foreign_ip]}."
  fi
  wan=$(tm_detect_wan "" "${spec[foreign_ip]}" "${spec[iran_ip]}" || true)
  TM_DRY_RUN="$saved_dry"
  tm_valid_iface "$wan" || tm_die "A WAN interface could not be detected."
  if conflict=$(tm_setup_foreign_conflict spec); then
    tm_die "$conflict"
  fi
  name=$(tm_setup_foreign_name "${spec[name]}") || tm_die "Could not choose a free tunnel name."
  if [[ "$name" != "${spec[name]}" ]]; then
    tm_info "Tunnel name ${spec[name]} is already used here, so this tunnel is saved as ${name}."
  fi
  [[ "${TM_YES:-0}" == "1" ]] && flags+=(--yes)
  [[ "${TM_DRY_RUN:-0}" == "1" ]] && flags+=(--dry-run)
  ssh_port=$(tm_ssh_port)
  if [[ ! -f "$(tm_host_file)" ]]; then
    tm_action_init --role foreign --public-ip "${spec[foreign_ip]}" --wan-iface "$wan" \
      --ssh-port "$ssh_port" "${flags[@]}" || return 1
  fi
  create_args=(
    --name "$name" --type gre
    --local-public-ip "${spec[foreign_ip]}"
    --remote-public-ip "${spec[iran_ip]}"
    --local-tunnel-ip "${spec[foreign_tun]}"
    --remote-tunnel-ip "${spec[iran_tun]}"
    --cidr "${spec[cidr]}"
    --key "${spec[key]}"
    --wan-iface "$wan"
  )
  create_args+=("${flags[@]}")
  tm_action_tunnel_create "${create_args[@]}" || return $?
  tm_setup_ensure_boot
}
