# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — firewall backend selection and dedicated NAT/filter chains.
# Rules are added and deleted individually. The firewall is never flushed.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "firewall.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_FIREWALL_LOADED:-}" ]]; then
  return 0
fi
TM_FIREWALL_LOADED=1

tm_fw_classify() {
  local ipt_version="$1"
  local nft_present="$2"
  if [[ -z "$ipt_version" && "$nft_present" == "0" ]]; then
    printf 'none\n'
    return 1
  fi
  if [[ -n "$ipt_version" && "$ipt_version" != *nf_tables* && "$nft_present" == "1" ]]; then
    printf 'conflict-possible\n'
    return 0
  fi
  if [[ -n "$ipt_version" ]]; then
    printf 'iptables\n'
    return 0
  fi
  printf 'nft\n'
  return 0
}

tm_iptables_save_has_rules() {
  local text="$1"
  local line
  while IFS= read -r line; do
    [[ "$line" == -A\ * || "$line" == -I\ * ]] && return 0
  done <<<"$text"
  return 1
}

tm_nft_text_has_table() {
  local text="$1"
  [[ "$text" == *"table "* ]]
}

tm_fw_resolve_conflict() {
  local ipt_rules="$1"
  local nft_rules="$2"
  local pinned="${3:-auto}"
  case "$pinned" in
    iptables|nft)
      printf '%s\n' "$pinned"
      return 0
      ;;
    auto) ;;
    *) return 1 ;;
  esac
  if [[ "$ipt_rules" == "yes" && "$nft_rules" == "yes" ]]; then
    return 1
  fi
  if [[ "$nft_rules" == "yes" ]]; then
    printf 'nft\n'
    return 0
  fi
  printf 'iptables\n'
}

tm_fw_snat_decision() {
  local mode="$1"
  local dest="$2"
  local local_tun="$3"
  local peer_tun="$4"
  case "$mode" in
    always)
      printf 'yes\n'
      ;;
    never)
      printf 'no\n'
      ;;
    auto)
      if [[ "$dest" == "$local_tun" ]]; then
        printf 'no\n'
      elif [[ "$dest" == "$peer_tun" || "$dest" != "$local_tun" ]]; then
        printf 'yes\n'
      else
        return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

tm_fw_comment() {
  printf 'tm:%s\n' "$1"
}

tm_fw_probe_versions() {
  local ipt_version="" nft_present=0
  if tm_cmd_available iptables; then
    ipt_version=$(tm_exec iptables -V 2>/dev/null || true)
  fi
  if tm_cmd_available nft; then
    nft_present=1
  fi
  printf '%s\n' "$ipt_version"
  printf '%s\n' "$nft_present"
}

tm_fw_active_backend() {
  local pinned="${TM_FW_BACKEND:-}"
  local -A host=()
  local -a probe=()
  local ipt_version nft_present classified ipt_rules="no" nft_rules="no"
  local ipt_text="" nft_text=""
  if [[ -z "$pinned" && -f "$(tm_host_file)" ]]; then
    if tm_kv_read "$(tm_host_file)" host; then
      pinned="${host[TM_FW_BACKEND]:-auto}"
    fi
  fi
  [[ -n "$pinned" ]] || pinned="auto"
  tm_valid_fw_backend "$pinned" || {
    tm_error "Invalid firewall backend '${pinned}'."
    return 1
  }
  mapfile -t probe < <(tm_fw_probe_versions)
  ipt_version="${probe[0]:-}"
  nft_present="${probe[1]:-0}"
  classified=$(tm_fw_classify "$ipt_version" "$nft_present") || {
    tm_error "No iptables or nftables backend is available."
    return 1
  }
  if [[ "$classified" == "iptables" || "$classified" == "nft" ]]; then
    if [[ "$pinned" != "auto" && "$pinned" != "$classified" ]]; then
      if ! tm_cmd_available "$pinned"; then
        tm_error "Pinned firewall backend ${pinned} is not available."
        return 1
      fi
      tm_warn "Using pinned backend ${pinned}. Tunnel Manager will not mix it with ${classified}."
      printf '%s\n' "$pinned"
      return 0
    fi
    printf '%s\n' "$classified"
    return 0
  fi
  if tm_cmd_available iptables; then
    ipt_text=$(tm_exec iptables -S 2>/dev/null || true)
    if tm_iptables_save_has_rules "$ipt_text"; then
      ipt_rules="yes"
    fi
  fi
  if tm_cmd_available nft; then
    nft_text=$(tm_exec nft list ruleset 2>/dev/null || true)
    if tm_nft_text_has_table "$nft_text"; then
      nft_rules="yes"
    fi
  fi
  if ! classified=$(tm_fw_resolve_conflict "$ipt_rules" "$nft_rules" "$pinned"); then
    tm_error "Both legacy iptables and nftables already have rules."
    tm_error "Set TM_FW_BACKEND to iptables or nft. Tunnel Manager will not mix them."
    return 1
  fi
  printf '%s\n' "$classified"
}

tm_iptables_chain_exists() {
  local table="$1"
  local chain="$2"
  tm_run_quiet iptables -t "$table" -n -L "$chain" >/dev/null 2>&1
}

tm_iptables_chain_rules() {
  local table="$1"
  local chain="$2"
  if ! tm_iptables_chain_exists "$table" "$chain"; then
    return 0
  fi
  tm_run_quiet iptables -t "$table" -S "$chain"
}

tm_iptables_ensure_chain() {
  local table="$1"
  local chain="$2"
  if tm_iptables_chain_exists "$table" "$chain"; then
    return 0
  fi
  tm_must iptables -t "$table" -N "$chain"
}

tm_iptables_ensure_jump() {
  local table="$1"
  local from="$2"
  local to="$3"
  local comment="$4"
  if tm_run_quiet iptables -t "$table" -C "$from" -m comment --comment "$comment" -j "$to" >/dev/null 2>&1; then
    return 0
  fi
  tm_must iptables -t "$table" -I "$from" 1 -m comment --comment "$comment" -j "$to"
}

tm_iptables_ensure_base() {
  tm_iptables_ensure_chain nat TM_PREROUTING || return 1
  tm_iptables_ensure_chain nat TM_POSTROUTING || return 1
  tm_iptables_ensure_chain filter TM_FORWARD || return 1
  tm_iptables_ensure_chain filter TM_INPUT || return 1
  tm_iptables_ensure_jump nat PREROUTING TM_PREROUTING tm:jump:nat-prerouting || return 1
  tm_iptables_ensure_jump nat POSTROUTING TM_POSTROUTING tm:jump:nat-postrouting || return 1
  tm_iptables_ensure_jump filter FORWARD TM_FORWARD tm:jump:filter-forward || return 1
  tm_iptables_ensure_jump filter INPUT TM_INPUT tm:jump:filter-input || return 1
}

tm_iptables_add_if_missing() {
  local -a rule=("$@")
  local -a check=()
  local i
  check=("${rule[@]}")
  for i in "${!check[@]}"; do
    if [[ "${check[$i]}" == "-A" ]]; then
      check[i]="-C"
      break
    fi
  done
  if tm_run_quiet "${check[@]}" >/dev/null 2>&1; then
    return 0
  fi
  tm_must "${rule[@]}"
}

# iptables -S prints one rule per line. The comment is wrapped in quotes, and
# -p udp is repeated as -m udp. Split on spaces even when IFS has no space.
tm_iptables_split_spec() {
  local line="$1"
  local -n _tm_spec=$2
  local token rest
  _tm_spec=()
  rest="$line"
  while [[ "$rest" == [[:space:]]* ]]; do
    rest="${rest:1}"
  done
  while [[ -n "$rest" ]]; do
    if [[ "$rest" == \"* ]]; then
      rest="${rest:1}"
      token="${rest%%\"*}"
      if [[ "$rest" == *"\""* ]]; then
        rest="${rest#*\"}"
      else
        rest=""
      fi
    else
      token="${rest%%[[:space:]]*}"
      rest="${rest#"$token"}"
    fi
    [[ -n "$token" ]] && _tm_spec+=("$token")
    while [[ "$rest" == [[:space:]]* ]]; do
      rest="${rest:1}"
    done
  done
}

tm_iptables_delete_parsed() {
  local bin="$1"
  local table="$2"
  local chain="$3"
  local comment="$4"
  shift 4
  if [[ "$#" -eq 0 ]]; then
    tm_error "Could not parse the iptables rule for ${comment}."
    return 1
  fi
  if ! tm_argv_is_safe "$bin" -t "$table" -D "$chain" "$@"; then
    tm_error "The saved iptables rule for ${comment} cannot be deleted safely."
    return 1
  fi
  if tm_run "$bin" -t "$table" -D "$chain" "$@"; then
    return 0
  fi
  # iptables -S inserts -m udp or -m tcp. Some releases do not delete a rule
  # when that implicit match is repeated on the -D command.
  local -a plain=()
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "-m" || "$1" == "--match" ]]; then
      case "${2:-}" in
        udp|tcp)
          shift 2
          continue
          ;;
      esac
    fi
    plain+=("$1")
    shift
  done
  if [[ "${#plain[@]}" -gt 0 ]] && tm_argv_is_safe "$bin" -t "$table" -D "$chain" "${plain[@]}"; then
    if tm_run "$bin" -t "$table" -D "$chain" "${plain[@]}"; then
      return 0
    fi
  fi
  tm_warn "Firewall rule ${comment} was not removed. Cleanup will continue."
  return 0
}

tm_iptables_line_has_comment() {
  local line="$1"
  local comment="$2"
  [[ "$comment" =~ ^tm:[a-z0-9:_-]{1,80}$ ]] || return 1
  # The comment must end here, so tm:tcp:p1:fwd does not match tm:tcp:p1:fwdret.
  [[ "$line" =~ --comment[[:space:]]+\"?${comment}([^a-z0-9_:-]|$) ]]
}

tm_iptables_delete_comment() {
  local table="$1"
  local chain="$2"
  local comment="$3"
  local line prefix=""
  local -a spec=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    tm_iptables_line_has_comment "$line" "$comment" || continue
    [[ "$line" == "-A ${chain} "* ]] || continue
    prefix="-A ${chain} "
    tm_iptables_split_spec "${line#"${prefix}"}" spec
    tm_iptables_delete_parsed iptables "$table" "$chain" "$comment" "${spec[@]}" || return 1
  done < <(tm_iptables_chain_rules "$table" "$chain")
}

tm_iptables_chain_empty() {
  local table="$1"
  local chain="$2"
  local line
  while IFS= read -r line; do
    [[ "$line" == -A\ * ]] && return 1
  done < <(tm_iptables_chain_rules "$table" "$chain")
  return 0
}

tm_iptables_gc() {
  local table chain from comment row
  local -a rows=(
    "nat TM_PREROUTING PREROUTING tm:jump:nat-prerouting"
    "nat TM_POSTROUTING POSTROUTING tm:jump:nat-postrouting"
    "filter TM_FORWARD FORWARD tm:jump:filter-forward"
    "filter TM_INPUT INPUT tm:jump:filter-input"
  )
  for row in "${rows[@]}"; do
    IFS=$' \t\n' read -r table chain from comment <<<"$row"
    tm_iptables_chain_exists "$table" "$chain" || continue
    if tm_iptables_chain_empty "$table" "$chain"; then
      tm_run_quiet iptables -t "$table" -D "$from" -m comment --comment "$comment" -j "$chain" >/dev/null 2>&1 || true
      tm_must iptables -t "$table" -X "$chain" || return 1
    fi
  done
}

tm_l4_proto_ok() {
  case "$1" in
    tcp|udp) return 0 ;;
    *) return 1 ;;
  esac
}

tm_iptables_l4_apply_exec() {
  local proto="$1"
  local name="$2"
  local iface="$3"
  local lport="$4"
  local dest_ip="$5"
  local dest_port="$6"
  local source_ip="$7"
  local do_snat="$8"
  local c_dnat c_snat c_fwd c_ret
  tm_l4_proto_ok "$proto" || return 1
  c_dnat=$(tm_fw_comment "${proto}:${name}:dnat")
  c_snat=$(tm_fw_comment "${proto}:${name}:snat")
  c_fwd=$(tm_fw_comment "${proto}:${name}:fwd")
  c_ret=$(tm_fw_comment "${proto}:${name}:fwdret")
  tm_iptables_ensure_base || return 1
  tm_iptables_add_if_missing \
    iptables -t nat -A TM_PREROUTING -i "$iface" -p "$proto" --dport "$lport" \
    -m comment --comment "$c_dnat" -j DNAT --to-destination "${dest_ip}:${dest_port}" || return 1
  if [[ "$do_snat" == "yes" ]]; then
    tm_iptables_add_if_missing \
      iptables -t nat -A TM_POSTROUTING -p "$proto" -d "$dest_ip" --dport "$dest_port" \
      -m comment --comment "$c_snat" -j SNAT --to-source "$source_ip" || return 1
  fi
  tm_iptables_add_if_missing \
    iptables -t filter -A TM_FORWARD -p "$proto" -d "$dest_ip" --dport "$dest_port" \
    -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment "$c_fwd" -j ACCEPT || return 1
  tm_iptables_add_if_missing \
    iptables -t filter -A TM_FORWARD -p "$proto" -s "$dest_ip" --sport "$dest_port" \
    -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$c_ret" -j ACCEPT || return 1
}

tm_iptables_l4_delete_exec() {
  local proto="$1"
  local name="$2"
  tm_l4_proto_ok "$proto" || return 1
  tm_iptables_delete_comment nat TM_PREROUTING "$(tm_fw_comment "${proto}:${name}:dnat")" || return 1
  tm_iptables_delete_comment nat TM_POSTROUTING "$(tm_fw_comment "${proto}:${name}:snat")" || return 1
  tm_iptables_delete_comment filter TM_FORWARD "$(tm_fw_comment "${proto}:${name}:fwd")" || return 1
  tm_iptables_delete_comment filter TM_FORWARD "$(tm_fw_comment "${proto}:${name}:fwdret")" || return 1
  tm_iptables_gc || return 1
}

# A rule for this tunnel with another interface or peer is replaced, not kept
# next to the new one.
tm_iptables_input_apply_exec() {
  local name="$1"
  local iface="$2"
  local remote="$3"
  local comment
  local -a spec=()
  comment=$(tm_fw_comment "gre:${name}:input")
  spec=(-i "$iface" -s "$remote" -p gre -m comment --comment "$comment" -j ACCEPT)
  tm_iptables_ensure_base || return 1
  if ! tm_run_quiet iptables -t filter -C TM_INPUT "${spec[@]}" >/dev/null 2>&1; then
    tm_iptables_delete_comment filter TM_INPUT "$comment" || return 1
  fi
  tm_iptables_add_if_missing iptables -t filter -A TM_INPUT "${spec[@]}"
}

tm_iptables_input_delete_exec() {
  local name="$1"
  tm_iptables_delete_comment filter TM_INPUT "$(tm_fw_comment "gre:${name}:input")" || return 1
  tm_iptables_gc || return 1
}

tm_nft_handles_for_comment() {
  local text="$1"
  local comment="$2"
  local line
  while IFS= read -r line; do
    [[ "$line" == *"comment \"${comment}\""* || "$line" == *"comment ${comment}"* ]] || continue
    if [[ "$line" =~ handle[[:space:]]+([0-9]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done <<<"$text"
}

tm_nft_chain_text() {
  local chain="$1"
  tm_run_quiet nft -a list chain inet tunnel_manager "$chain" 2>/dev/null || true
}

tm_nft_comment_present() {
  local chain="$1"
  local comment="$2"
  local text
  text=$(tm_nft_chain_text "$chain")
  [[ "$text" == *"comment \"${comment}\""* || "$text" == *"comment ${comment}"* ]]
}

tm_nft_ensure_table() {
  if tm_run_quiet nft list table inet tunnel_manager >/dev/null 2>&1; then
    return 0
  fi
  tm_must nft add table inet tunnel_manager
}

tm_nft_ensure_chain() {
  local name="$1"
  local def="$2"
  if tm_run_quiet nft list chain inet tunnel_manager "$name" >/dev/null 2>&1; then
    return 0
  fi
  tm_must nft add chain inet tunnel_manager "$name" "$def"
}

tm_nft_ensure_base() {
  TM_NFT_FILTER_OK=0
  tm_nft_ensure_table || return 1
  tm_nft_ensure_chain prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' || return 1
  tm_nft_ensure_chain postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' || return 1
  if tm_nft_filter_hook_allowed; then
    tm_nft_ensure_chain forward '{ type filter hook forward priority 0; policy accept; }' || return 1
    tm_nft_ensure_chain input '{ type filter hook input priority 0; policy accept; }' || return 1
    TM_NFT_FILTER_OK=1
  else
    tm_warn "Another firewall owns a filter hook. Tunnel Manager will add NAT rules only."
  fi
}

tm_nft_add_rule() {
  local chain="$1"
  local comment="$2"
  shift 2
  if tm_nft_comment_present "$chain" "$comment"; then
    return 0
  fi
  tm_must nft add rule inet tunnel_manager "$chain" "$@" comment "$comment"
}

tm_nft_delete_comment() {
  local chain="$1"
  local comment="$2"
  local text handle
  text=$(tm_nft_chain_text "$chain")
  while IFS= read -r handle; do
    [[ -n "$handle" ]] || continue
    tm_must nft delete rule inet tunnel_manager "$chain" handle "$handle" || return 1
  done < <(tm_nft_handles_for_comment "$text" "$comment")
}

tm_nft_l4_apply_exec() {
  local proto="$1"
  local name="$2"
  local iface="$3"
  local lport="$4"
  local dest_ip="$5"
  local dest_port="$6"
  local source_ip="$7"
  local do_snat="$8"
  local c_dnat c_snat c_fwd c_ret
  tm_l4_proto_ok "$proto" || return 1
  c_dnat=$(tm_fw_comment "${proto}:${name}:dnat")
  c_snat=$(tm_fw_comment "${proto}:${name}:snat")
  c_fwd=$(tm_fw_comment "${proto}:${name}:fwd")
  c_ret=$(tm_fw_comment "${proto}:${name}:fwdret")
  tm_nft_ensure_base || return 1
  tm_nft_add_rule prerouting "$c_dnat" iifname "$iface" "$proto" dport "$lport" dnat to "${dest_ip}:${dest_port}" || return 1
  if [[ "$do_snat" == "yes" ]]; then
    tm_nft_add_rule postrouting "$c_snat" ip daddr "$dest_ip" "$proto" dport "$dest_port" snat to "$source_ip" || return 1
  fi
  if [[ "${TM_NFT_FILTER_OK:-0}" == "1" ]]; then
    tm_nft_add_rule forward "$c_fwd" "$proto" dport "$dest_port" ip daddr "$dest_ip" accept || return 1
    tm_nft_add_rule forward "$c_ret" "$proto" sport "$dest_port" ip saddr "$dest_ip" accept || return 1
  fi
}

tm_nft_l4_delete_exec() {
  local proto="$1"
  local name="$2"
  tm_l4_proto_ok "$proto" || return 1
  tm_nft_delete_comment prerouting "$(tm_fw_comment "${proto}:${name}:dnat")" || return 1
  tm_nft_delete_comment postrouting "$(tm_fw_comment "${proto}:${name}:snat")" || return 1
  tm_nft_delete_comment forward "$(tm_fw_comment "${proto}:${name}:fwd")" || return 1
  tm_nft_delete_comment forward "$(tm_fw_comment "${proto}:${name}:fwdret")" || return 1
}

tm_nft_input_apply_exec() {
  local name="$1"
  local iface="$2"
  local remote="$3"
  local match=ip comment line stale=0 want have
  tm_nft_ensure_base || return 1
  if [[ "${TM_NFT_FILTER_OK:-0}" != "1" ]]; then
    tm_warn "Skipped the GRE input allow because a filter hook is owned by another firewall."
    return 0
  fi
  if tm_valid_ipv6 "$remote"; then
    match=ip6
  fi
  comment=$(tm_fw_comment "gre:${name}:input")
  want=$(tm_ip_canonical "$remote") || return 1
  while IFS= read -r line; do
    [[ "$line" == *"comment \"${comment}\""* || "$line" == *"comment ${comment} "* || "$line" == *"comment ${comment}" ]] || continue
    have=""
    if [[ "$line" =~ saddr[[:space:]]+([0-9A-Fa-f:.]+) ]]; then
      have=$(tm_ip_canonical "${BASH_REMATCH[1]}" || true)
    fi
    if [[ "$have" == "$want" \
      && ("$line" == *"iifname \"${iface}\" "* || "$line" == *"iifname ${iface} "*) ]]; then
      continue
    fi
    stale=1
  done < <(tm_nft_chain_text input)
  if [[ "$stale" == "1" ]]; then
    tm_nft_delete_comment input "$comment" || return 1
  fi
  tm_nft_add_rule input "$comment" \
    iifname "$iface" "$match" saddr "$remote" meta l4proto gre accept
}

tm_nft_input_delete_exec() {
  local name="$1"
  tm_nft_delete_comment input "$(tm_fw_comment "gre:${name}:input")"
}

tm_fw_l4_apply_exec() {
  local proto="$1"
  shift
  local backend
  tm_l4_proto_ok "$proto" || return 1
  backend=$(tm_fw_active_backend) || return 1
  case "$backend" in
    iptables) tm_iptables_l4_apply_exec "$proto" "$@" ;;
    nft) tm_nft_l4_apply_exec "$proto" "$@" ;;
    *)
      tm_error "Unsupported firewall backend: ${backend}"
      return 1
      ;;
  esac
}

tm_fw_l4_delete_exec() {
  local proto="$1"
  local name="$2"
  local backend
  tm_l4_proto_ok "$proto" || return 1
  backend=$(tm_fw_active_backend) || return 1
  case "$backend" in
    iptables) tm_iptables_l4_delete_exec "$proto" "$name" ;;
    nft) tm_nft_l4_delete_exec "$proto" "$name" ;;
    *) return 1 ;;
  esac
}

tm_fw_forward_delete_exec() {
  local name="$1"
  tm_fw_l4_delete_exec tcp "$name" || return 1
  tm_fw_l4_delete_exec udp "$name" || return 1
}

tm_ip6tables_input_ensure() {
  if ! tm_run_quiet ip6tables -t filter -n -L TM_INPUT >/dev/null 2>&1; then
    tm_must ip6tables -t filter -N TM_INPUT || return 1
  fi
  if tm_run_quiet ip6tables -t filter -C INPUT -m comment --comment tm:jump:filter-input -j TM_INPUT >/dev/null 2>&1; then
    return 0
  fi
  tm_must ip6tables -t filter -I INPUT 1 -m comment --comment tm:jump:filter-input -j TM_INPUT
}

tm_ip6tables_chain_rules() {
  if ! tm_run_quiet ip6tables -t filter -n -L TM_INPUT >/dev/null 2>&1; then
    return 0
  fi
  tm_run_quiet ip6tables -t filter -S TM_INPUT
}

tm_ip6tables_input_delete_comment() {
  local comment="$1"
  local line prefix=""
  local -a spec=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    tm_iptables_line_has_comment "$line" "$comment" || continue
    [[ "$line" == "-A TM_INPUT "* ]] || continue
    prefix="-A TM_INPUT "
    tm_iptables_split_spec "${line#"${prefix}"}" spec
    tm_iptables_delete_parsed ip6tables filter TM_INPUT "$comment" "${spec[@]}" || return 1
  done < <(tm_ip6tables_chain_rules)
}

tm_ip6tables_input_gc() {
  local line
  tm_run_quiet ip6tables -t filter -n -L TM_INPUT >/dev/null 2>&1 || return 0
  while IFS= read -r line; do
    [[ "$line" == -A\ * ]] && return 0
  done < <(tm_ip6tables_chain_rules)
  tm_run_quiet ip6tables -t filter -D INPUT -m comment --comment tm:jump:filter-input -j TM_INPUT >/dev/null 2>&1 || true
  tm_must ip6tables -t filter -X TM_INPUT
}

tm_ip6tables_input_apply_exec() {
  local name="$1"
  local iface="$2"
  local remote="$3"
  local comment
  local -a spec=()
  comment=$(tm_fw_comment "gre:${name}:input")
  spec=(-i "$iface" -s "$remote" -p gre -m comment --comment "$comment" -j ACCEPT)
  tm_ip6tables_input_ensure || return 1
  if ! tm_run_quiet ip6tables -t filter -C TM_INPUT "${spec[@]}" >/dev/null 2>&1; then
    tm_ip6tables_input_delete_comment "$comment" || return 1
  fi
  tm_iptables_add_if_missing ip6tables -t filter -A TM_INPUT "${spec[@]}"
}

tm_ip6tables_input_delete_exec() {
  local name="$1"
  tm_ip6tables_input_delete_comment "$(tm_fw_comment "gre:${name}:input")" || return 1
  tm_ip6tables_input_gc || return 1
}

# Accepts GRE from the peer only, so GRE for other tools on this host keeps
# whatever policy they set.
tm_fw_input_apply_exec() {
  local name="$1"
  local iface="$2"
  local remote="$3"
  local family="${4:-4}"
  local backend
  tm_ip_is_unicast_host "$remote" || return 1
  backend=$(tm_fw_active_backend) || return 1
  if [[ "$family" == "6" && "$backend" == "iptables" ]]; then
    tm_ip6tables_input_apply_exec "$name" "$iface" "$remote"
    return $?
  fi
  case "$backend" in
    iptables) tm_iptables_input_apply_exec "$name" "$iface" "$remote" ;;
    nft) tm_nft_input_apply_exec "$name" "$iface" "$remote" ;;
    *) return 1 ;;
  esac
}

tm_fw_input_delete_exec() {
  local name="$1"
  local family="${2:-4}"
  local backend
  backend=$(tm_fw_active_backend) || return 1
  if [[ "$family" == "6" && "$backend" == "iptables" ]]; then
    tm_ip6tables_input_delete_exec "$name"
    return $?
  fi
  case "$backend" in
    iptables) tm_iptables_input_delete_exec "$name" ;;
    nft) tm_nft_input_delete_exec "$name" ;;
    *) return 1 ;;
  esac
}
