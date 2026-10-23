# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — command allowlist.
# Network changes must pass this gate. It rejects firewall flushes,
# policy changes, default-route edits, and commands outside the tool's scope.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "preflight.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_PREFLIGHT_LOADED:-}" ]]; then
  return 0
fi
TM_PREFLIGHT_LOADED=1

tm_command_is_read_only() {
  local cmd="$1"
  shift || true
  case "$cmd" in
    tm_*)
      return 1
      ;;
    iptables)
      case "${1:-}" in
        -V|--version|-S|--list-rules|-L|--list|-C|--check) return 0 ;;
      esac
      local arg
      for arg in "$@"; do
        case "$arg" in
          -S|--list-rules|-L|--list|-C|--check|-V|--version) return 0 ;;
        esac
      done
      return 1
      ;;
    nft)
      [[ "${1:-}" == "list" || "${2:-}" == "list" ]]
      ;;
    ip)
      local token
      for token in "$@"; do
        case "$token" in
          show|get|list) return 0 ;;
          add|del|delete|replace|change|set) return 1 ;;
        esac
      done
      return 1
      ;;
    sysctl)
      [[ "${1:-}" == "-n" ]]
      ;;
    systemctl)
      case "${1:-}" in
        is-active|is-enabled|is-failed|status|show|cat) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    wg)
      [[ "${1:-}" == "show" ]]
      ;;
    ss|ping)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tm_chain_is_ours() {
  [[ "$1" =~ ^TM_[A-Z0-9_]+$ ]]
}

tm_chain_is_builtin() {
  case "$1" in
    INPUT|OUTPUT|FORWARD|PREROUTING|POSTROUTING) return 0 ;;
    *) return 1 ;;
  esac
}

tm_iptables_target_ok() {
  case "$1" in
    ACCEPT|DNAT|SNAT) return 0 ;;
    TM_*)
      tm_chain_is_ours "$1"
      ;;
    *) return 1 ;;
  esac
}

tm_iptables_rule_is_safe() {
  local chain="$1"
  shift
  local -a args=("$@")
  local i=0
  local n=${#args[@]}
  local target="" comment="" proto="" in_iface="" daddr="" saddr=""
  local dport="" sport="" to_dest="" to_src="" ctstate="" module=""
  local token

  while [[ "$i" -lt "$n" ]]; do
    token="${args[$i]}"
    case "$token" in
      -m|--match)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        module="${args[$i]}"
        case "$module" in
          # iptables -S adds -m udp or -m tcp for the protocol already named by -p.
          comment|conntrack|tcp|udp) ;;
          *) return 1 ;;
        esac
        ;;
      --comment)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        comment="${args[$i]}"
        comment="${comment#\"}"
        comment="${comment%\"}"
        ;;
      --ctstate)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        ctstate="${args[$i]}"
        ;;
      -p|--protocol)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        proto="${args[$i]}"
        ;;
      -i|--in-interface)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        in_iface="${args[$i]}"
        tm_valid_iface "$in_iface" || return 1
        ;;
      -d|--destination)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        daddr="${args[$i]}"
        # iptables-nft prints a single host as address/32.
        [[ "$daddr" == */32 ]] && daddr="${daddr%/32}"
        tm_valid_ipv4 "$daddr" || return 1
        ;;
      -s|--source)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        saddr="${args[$i]}"
        [[ "$saddr" == */32 ]] && saddr="${saddr%/32}"
        tm_valid_ipv4 "$saddr" || return 1
        ;;
      --dport)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        dport="${args[$i]}"
        tm_valid_port "$dport" || return 1
        ;;
      --sport)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        sport="${args[$i]}"
        tm_valid_port "$sport" || return 1
        ;;
      -j|--jump)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        target="${args[$i]}"
        tm_iptables_target_ok "$target" || return 1
        ;;
      --to-destination)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        to_dest="${args[$i]}"
        ;;
      --to-source)
        i=$((i + 1))
        [[ "$i" -lt "$n" ]] || return 1
        to_src="${args[$i]}"
        [[ "$to_src" == */32 ]] && to_src="${to_src%/32}"
        ;;
      *)
        return 1
        ;;
    esac
    i=$((i + 1))
  done

  [[ "$comment" =~ ^tm:[a-z0-9:_-]{1,80}$ ]] || return 1
  [[ -n "$target" ]] || return 1

  if tm_chain_is_builtin "$chain"; then
    tm_chain_is_ours "$target" || return 1
    [[ -z "$proto" && -z "$dport" && -z "$sport" && -z "$daddr" && -z "$saddr" ]] || return 1
    [[ -z "$in_iface" && -z "$ctstate" && -z "$to_dest" && -z "$to_src" ]] || return 1
    [[ "$comment" == tm:jump:* ]] || return 1
    return 0
  fi

  tm_chain_is_ours "$chain" || return 1

  case "$target" in
    DNAT)
      [[ "$chain" == "TM_PREROUTING" ]] || return 1
      [[ "$proto" == "udp" || "$proto" == "tcp" ]] || return 1
      [[ -n "$in_iface" && -n "$dport" && -n "$to_dest" ]] || return 1
      [[ "$to_dest" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] || return 1
      tm_ipv4_is_unicast_host "${to_dest%%:*}" || return 1
      tm_valid_port "${to_dest##*:}" || return 1
      tm_port_is_protected "$dport" && return 1
      ;;
    SNAT)
      [[ "$chain" == "TM_POSTROUTING" ]] || return 1
      [[ "$proto" == "udp" || "$proto" == "tcp" ]] || return 1
      [[ -n "$daddr" && -n "$dport" && -n "$to_src" ]] || return 1
      tm_ipv4_is_unicast_host "$to_src" || return 1
      ;;
    ACCEPT)
      [[ "$chain" == "TM_FORWARD" || "$chain" == "TM_INPUT" ]] || return 1
      case "$proto" in
        udp|tcp)
          [[ -n "$dport" || -n "$sport" ]] || return 1
          case "$ctstate" in
            NEW,ESTABLISHED|ESTABLISHED,RELATED) ;;
            *) return 1 ;;
          esac
          ;;
        gre|47)
          [[ "$chain" == "TM_INPUT" ]] || return 1
          [[ -n "$in_iface" ]] || return 1
          [[ -z "$dport" && -z "$sport" ]] || return 1
          ;;
        *)
          return 1
          ;;
      esac
      if [[ "$chain" == "TM_INPUT" ]]; then
        [[ -n "$in_iface" ]] || return 1
        if [[ -n "$dport" ]] && tm_port_is_protected "$dport"; then
          return 1
        fi
      fi
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

tm_iptables_has_forbidden_arg() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -F|--flush|-P|--policy|DROP|REJECT|MASQUERADE|TPROXY|REDIRECT|MARK|LOG|ULOG|NFLOG)
        return 0
        ;;
    esac
  done
  return 1
}

tm_iptables_argv_is_safe() {
  local -a args=("$@")
  local n=${#args[@]}
  local idx=1
  local table="filter"
  local action="" chain="" position="" token

  case "${args[0]}" in
    iptables|ip6tables) ;;
    *) return 1 ;;
  esac
  tm_iptables_has_forbidden_arg "$@" && return 1

  while [[ "$idx" -lt "$n" ]]; do
    token="${args[$idx]}"
    case "$token" in
      -t|--table)
        idx=$((idx + 1))
        [[ "$idx" -lt "$n" ]] || return 1
        table="${args[$idx]}"
        case "$table" in
          nat|filter) ;;
          *) return 1 ;;
        esac
        ;;
      -n|--numeric|-v|--verbose|-x|--exact|--line-numbers)
        ;;
      -V|--version)
        return 0
        ;;
      -S|--list-rules|-L|--list)
        return 0
        ;;
      -N|--new-chain)
        idx=$((idx + 1))
        [[ "$idx" -lt "$n" ]] || return 1
        tm_chain_is_ours "${args[$idx]}" || return 1
        return 0
        ;;
      -X|--delete-chain)
        idx=$((idx + 1))
        [[ "$idx" -lt "$n" ]] || return 1
        tm_chain_is_ours "${args[$idx]}" || return 1
        return 0
        ;;
      -A|--append|-I|--insert|-D|--delete|-C|--check)
        action="$token"
        idx=$((idx + 1))
        [[ "$idx" -lt "$n" ]] || return 1
        chain="${args[$idx]}"
        if [[ "$action" == "-I" || "$action" == "--insert" ]]; then
          if [[ "${args[$((idx + 1))]:-}" =~ ^[0-9]+$ ]]; then
            idx=$((idx + 1))
            position="${args[$idx]}"
            [[ "$position" == "1" ]] || return 1
          else
            position="1"
          fi
          tm_chain_is_builtin "$chain" || return 1
        fi
        if [[ "$action" == "-A" || "$action" == "--append" ]]; then
          tm_chain_is_ours "$chain" || return 1
        fi
        idx=$((idx + 1))
        tm_iptables_rule_is_safe "$chain" "${args[@]:$idx}" || return 1
        return 0
        ;;
      *)
        return 1
        ;;
    esac
    idx=$((idx + 1))
  done
  return 1
}

tm_nft_comment_ok() {
  [[ "$1" =~ ^tm:[a-z0-9:_-]{1,80}$ ]]
}

tm_nft_chain_name_ok() {
  case "$1" in
    prerouting|postrouting|forward|input) return 0 ;;
    *) return 1 ;;
  esac
}

tm_nft_chain_def_ok() {
  case "$1" in
    "{ type nat hook prerouting priority dstnat; policy accept; }"|\
      "{ type nat hook postrouting priority srcnat; policy accept; }")
      return 0
      ;;
    "{ type filter hook forward priority 0; policy accept; }"|\
      "{ type filter hook input priority 0; policy accept; }")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tm_nft_def_is_filter_hook() {
  case "$1" in
    "{ type filter hook forward priority 0; policy accept; }"|\
      "{ type filter hook input priority 0; policy accept; }")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tm_nft_ruleset_has_foreign_forward_hook() {
  local ruleset="$1"
  local line table=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^table[[:space:]]+([a-z0-9]+)[[:space:]]+([A-Za-z0-9_-]+) ]]; then
      table="${BASH_REMATCH[2]}"
    fi
    if [[ "$line" == *"hook forward"* || "$line" == *"hook input"* ]]; then
      [[ "$table" == "tunnel_manager" ]] || return 0
    fi
  done <<<"$ruleset"
  return 1
}

tm_nft_filter_hook_allowed() {
  local ruleset=""
  if ! ruleset=$(tm_exec nft list ruleset 2>/dev/null); then
    return 1
  fi
  if tm_nft_ruleset_has_foreign_forward_hook "$ruleset"; then
    return 1
  fi
  return 0
}

tm_nft_rule_tail_is_safe() {
  local chain="$1"
  shift
  local comment="" proto_seen=0 gre_seen=0 iif_seen=0 dport="" to_value="" jump=""
  local -a args=("$@")
  local i=0 token
  while [[ "$i" -lt "${#args[@]}" ]]; do
    token="${args[$i]}"
    case "$token" in
      iifname)
        i=$((i + 1))
        tm_valid_iface "${args[$i]:-}" || return 1
        iif_seen=1
        ;;
      udp|tcp)
        proto_seen=1
        ;;
      gre)
        gre_seen=1
        ;;
      ip)
        ;;
      daddr|saddr)
        i=$((i + 1))
        tm_valid_ipv4 "${args[$i]:-}" || return 1
        ;;
      dport|sport)
        i=$((i + 1))
        dport="${args[$i]:-}"
        tm_valid_port "$dport" || return 1
        ;;
      dnat|snat)
        jump="$token"
        i=$((i + 1))
        [[ "${args[$i]:-}" == "to" ]] || return 1
        i=$((i + 1))
        to_value="${args[$i]:-}"
        ;;
      accept)
        jump="accept"
        ;;
      comment)
        i=$((i + 1))
        comment="${args[$i]:-}"
        ;;
      counter)
        ;;
      *)
        return 1
        ;;
    esac
    i=$((i + 1))
  done
  tm_nft_comment_ok "$comment" || return 1
  case "$chain:$jump" in
    prerouting:dnat)
      [[ "$proto_seen" -eq 1 && "$iif_seen" -eq 1 && -n "$dport" && -n "$to_value" ]] || return 1
      tm_port_is_protected "$dport" && return 1
      [[ "$to_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] || return 1
      tm_ipv4_is_unicast_host "${to_value%%:*}" || return 1
      tm_valid_port "${to_value##*:}" || return 1
      ;;
    postrouting:snat)
      [[ "$proto_seen" -eq 1 && -n "$dport" && -n "$to_value" ]] || return 1
      tm_ipv4_is_unicast_host "$to_value" || return 1
      ;;
    forward:accept)
      [[ "$proto_seen" -eq 1 && -n "$dport" ]] || return 1
      ;;
    input:accept)
      [[ "$iif_seen" -eq 1 ]] || return 1
      if [[ "$gre_seen" -eq 1 ]]; then
        [[ -z "$dport" ]] || return 1
      else
        [[ "$proto_seen" -eq 1 && -n "$dport" ]] || return 1
        tm_port_is_protected "$dport" && return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

tm_nft_argv_is_safe() {
  local -a args=("$@")
  [[ "${args[0]}" == "nft" ]] || return 1
  local arg
  for arg in "${args[@]}"; do
    case "$arg" in
      flush|Flush|FLUSH) return 1 ;;
    esac
  done
  if [[ "${args[1]:-}" == "-a" ]]; then
    [[ "${args[2]:-}" == "list" && "${args[3]:-}" == "chain" ]] || return 1
    [[ "${args[4]:-}" == "inet" && "${args[5]:-}" == "tunnel_manager" ]] || return 1
    tm_nft_chain_name_ok "${args[6]:-}" || return 1
    [[ "$#" -eq 7 ]] || return 1
    return 0
  fi
  case "${args[1]:-}" in
    list)
      case "${args[2]:-}" in
        ruleset|tables)
          [[ "$#" -eq 3 ]] || return 1
          return 0
          ;;
        table)
          [[ "${args[3]:-}" == "inet" && "${args[4]:-}" == "tunnel_manager" && "$#" -eq 5 ]] || return 1
          return 0
          ;;
        chain)
          [[ "${args[3]:-}" == "inet" && "${args[4]:-}" == "tunnel_manager" ]] || return 1
          tm_nft_chain_name_ok "${args[5]:-}" || return 1
          [[ "$#" -eq 6 ]] || return 1
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    add)
      case "${args[2]:-}" in
        table)
          [[ "${args[3]:-}" == "inet" && "${args[4]:-}" == "tunnel_manager" && "$#" -eq 5 ]] || return 1
          return 0
          ;;
        chain)
          [[ "${args[3]:-}" == "inet" && "${args[4]:-}" == "tunnel_manager" ]] || return 1
          tm_nft_chain_name_ok "${args[5]:-}" || return 1
          [[ "$#" -eq 7 ]] || return 1
          tm_nft_chain_def_ok "${args[6]}" || return 1
          if tm_nft_def_is_filter_hook "${args[6]}"; then
            tm_nft_filter_hook_allowed || return 1
          fi
          return 0
          ;;
        rule)
          [[ "${args[3]:-}" == "inet" && "${args[4]:-}" == "tunnel_manager" ]] || return 1
          tm_nft_chain_name_ok "${args[5]:-}" || return 1
          tm_nft_rule_tail_is_safe "${args[5]}" "${args[@]:6}" || return 1
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    delete)
      case "${args[2]:-}" in
        table)
          [[ "${args[3]:-}" == "inet" && "${args[4]:-}" == "tunnel_manager" && "$#" -eq 5 ]] || return 1
          return 0
          ;;
        chain)
          [[ "${args[3]:-}" == "inet" && "${args[4]:-}" == "tunnel_manager" ]] || return 1
          tm_nft_chain_name_ok "${args[5]:-}" || return 1
          [[ "$#" -eq 6 ]] || return 1
          return 0
          ;;
        rule)
          [[ "${args[3]:-}" == "inet" && "${args[4]:-}" == "tunnel_manager" ]] || return 1
          tm_nft_chain_name_ok "${args[5]:-}" || return 1
          [[ "${args[6]:-}" == "handle" && "${args[7]:-}" =~ ^[0-9]+$ && "$#" -eq 8 ]] || return 1
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

tm_ip_prefix_ok() {
  local cidr="$1"
  local ip prefix family
  [[ "$cidr" == */* ]] || return 1
  ip=${cidr%/*}
  prefix=${cidr#*/}
  [[ "$ip" != */* && "$prefix" != */* ]] || return 1
  family=$(tm_ip_family "$ip") || return 1
  tm_ip_is_assignable "$ip" "$prefix" || return 1
  tm_valid_prefix_for_family "$family" "$prefix" || return 1
  return 0
}

tm_ip_link_add_is_safe() {
  local -a args=("$@")
  local family
  # name IFACE type gre|ip6gre local IP remote IP ttl N
  [[ "${#args[@]}" -eq 10 ]] || return 1
  [[ "${args[0]}" == "name" && "${args[2]}" == "type" ]] || return 1
  tm_valid_tunnel_iface "${args[1]}" || return 1
  [[ "${args[4]}" == "local" && "${args[6]}" == "remote" && "${args[8]}" == "ttl" ]] || return 1
  case "${args[3]}" in
    gre) family=4 ;;
    ip6gre) family=6 ;;
    *) return 1 ;;
  esac
  [[ "$(tm_ip_family "${args[5]}")" == "$family" ]] || return 1
  [[ "$(tm_ip_family "${args[7]}")" == "$family" ]] || return 1
  tm_ip_is_unicast_host "${args[5]}" || return 1
  tm_ip_is_unicast_host "${args[7]}" || return 1
  [[ "$(tm_ip_canonical "${args[5]}")" != "$(tm_ip_canonical "${args[7]}")" ]] || return 1
  [[ "${args[9]}" =~ ^[0-9]+$ ]] || return 1
  (("${args[9]}" >= 1 && "${args[9]}" <= 255)) || return 1
  return 0
}

tm_ip_argv_is_safe() {
  local -a args=("$@")
  local i=1
  local n=${#args[@]}
  local sub=""
  [[ "${args[0]}" == "ip" ]] || return 1
  while [[ "$i" -lt "$n" ]]; do
    case "${args[$i]}" in
      -4|-6|-d|-o|-br) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [[ "$i" -lt "$n" ]] || return 1
  sub="${args[$i]}"
  i=$((i + 1))
  case "$sub" in
    route)
      [[ "$i" -lt "$n" ]] || return 1
      case "${args[$i]}" in
        show|list|get) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    link)
      [[ "$i" -lt "$n" ]] || return 1
      case "${args[$i]}" in
        show)
          return 0
          ;;
        add)
          tm_ip_link_add_is_safe "${args[@]:$((i + 1))}"
          ;;
        set)
          # set dev IFACE mtu N | up | down
          [[ "${args[$((i + 1))]:-}" == "dev" ]] || return 1
          tm_valid_tunnel_iface "${args[$((i + 2))]:-}" || return 1
          case "${args[$((i + 3))]:-}" in
            up|down)
              [[ $((i + 4)) -eq "$n" ]] || return 1
              return 0
              ;;
            mtu)
              [[ "${args[$((i + 4))]:-}" =~ ^[0-9]+$ ]] || return 1
              tm_valid_mtu "${args[$((i + 4))]}" || return 1
              [[ $((i + 5)) -eq "$n" ]] || return 1
              return 0
              ;;
            *)
              return 1
              ;;
          esac
          ;;
        del|delete)
          [[ "${args[$((i + 1))]:-}" == "dev" ]] || return 1
          tm_valid_tunnel_iface "${args[$((i + 2))]:-}" || return 1
          [[ $((i + 3)) -eq "$n" ]] || return 1
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    addr|address)
      [[ "$i" -lt "$n" ]] || return 1
      case "${args[$i]}" in
        show)
          return 0
          ;;
        add|del|delete)
          tm_ip_prefix_ok "${args[$((i + 1))]:-}" || return 1
          [[ "${args[$((i + 2))]:-}" == "dev" ]] || return 1
          tm_valid_tunnel_iface "${args[$((i + 3))]:-}" || return 1
          [[ $((i + 4)) -eq "$n" ]] || return 1
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

tm_sysctl_key_is_safe() {
  local spec="$1"
  local key="${spec%%=*}"
  local value=""
  local iface
  if [[ "$spec" == *"="* ]]; then
    value="${spec#*=}"
  fi
  case "$key" in
    net.ipv4.ip_forward)
      if [[ -n "$value" ]]; then
        [[ "$value" == "0" || "$value" == "1" ]] || return 1
      fi
      return 0
      ;;
    net.ipv4.conf.*.rp_filter)
      iface=${key#net.ipv4.conf.}
      iface=${iface%.rp_filter}
      tm_valid_tunnel_iface "$iface" || return 1
      if [[ -n "$value" ]]; then
        [[ "$value" == "0" || "$value" == "1" || "$value" == "2" ]] || return 1
      fi
      return 0
      ;;
    net.core.default_qdisc|net.ipv4.tcp_congestion_control)
      if [[ -n "$value" ]]; then
        [[ "$value" =~ ^[a-z0-9_]{1,32}$ ]] || return 1
      fi
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tm_sysctl_argv_is_safe() {
  local -a args=("$@")
  [[ "${args[0]}" == "sysctl" ]] || return 1
  case "${args[1]:-}" in
    -n)
      [[ "$#" -eq 3 ]] || return 1
      tm_sysctl_key_is_safe "${args[2]}"
      ;;
    -w)
      [[ "$#" -eq 3 ]] || return 1
      [[ "${args[2]}" == *"="* ]] || return 1
      tm_sysctl_key_is_safe "${args[2]}"
      ;;
    *)
      return 1
      ;;
  esac
}

tm_systemctl_unit_ok() {
  local unit="$1"
  unit=${unit%.service}
  case "$unit" in
    tunnel-manager-apply)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tm_systemctl_argv_is_safe() {
  local -a args=("$@")
  local i=1
  local verb unit
  [[ "${args[0]}" == "systemctl" ]] || return 1
  while [[ "$i" -lt "$#" ]]; do
    case "${args[$i]}" in
      --now|--quiet|--no-block|--no-pager) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  verb="${args[$i]:-}"
  i=$((i + 1))
  case "$verb" in
    daemon-reload)
      [[ "$i" -eq $# ]] || return 1
      return 0
      ;;
    enable|disable|start|stop|restart|reload|try-reload-or-restart|is-active|is-enabled|is-failed|status|show|cat)
      while [[ "$i" -lt $# ]]; do
        case "${args[$i]}" in
          --now|--quiet|--no-block|--no-pager) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      unit="${args[$i]:-}"
      [[ -n "$unit" ]] || return 1
      tm_systemctl_unit_ok "$unit" || return 1
      [[ $((i + 1)) -eq $# ]] || return 1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tm_modprobe_argv_is_safe() {
  [[ "$1" == "modprobe" ]] || return 1
  [[ "$#" -eq 2 ]] || return 1
  case "$2" in
    ip_gre|ip6_gre|tcp_bbr) return 0 ;;
    *) return 1 ;;
  esac
}

tm_ping_argv_is_safe() {
  local -a args=("$@")
  local i=1 dest="" count="" iface=""
  [[ "${args[0]}" == "ping" ]] || return 1
  while [[ "$i" -lt "$#" ]]; do
    case "${args[$i]}" in
      -c)
        i=$((i + 1))
        count="${args[$i]:-}"
        [[ "$count" =~ ^[1-4]$ ]] || return 1
        ;;
      -W|-w)
        i=$((i + 1))
        [[ "${args[$i]:-}" =~ ^[1-5]$ ]] || return 1
        ;;
      -I)
        i=$((i + 1))
        iface="${args[$i]:-}"
        tm_valid_iface "$iface" || return 1
        ;;
      -4|-6|-n|-q)
        ;;
      *)
        [[ -z "$dest" ]] || return 1
        dest="${args[$i]}"
        tm_ip_is_unicast_host "$dest" || return 1
        ;;
    esac
    i=$((i + 1))
  done
  [[ -n "$dest" && -n "$count" ]]
}

tm_ss_argv_is_safe() {
  [[ "$1" == "ss" ]] || return 1
  local arg
  for arg in "$@"; do
    case "$arg" in
      ss|-H|-l|-n|-t|-u|-p|-4) ;;
      sport|sport=*) ;;
      "=") ;;
      :*)
        [[ "$arg" =~ ^:[0-9]+$ ]] || return 1
        ;;
      *)
        return 1
        ;;
    esac
  done
  return 0
}

tm_timeout_argv_is_safe() {
  local -a args=("$@")
  local i=1
  [[ "${args[0]}" == "timeout" ]] || return 1
  while [[ "$i" -lt "$#" ]]; do
    case "${args[$i]}" in
      -k|--kill-after)
        i=$((i + 1))
        [[ "${args[$i]:-}" =~ ^[0-9]+$ ]] || return 1
        ;;
      --)
        i=$((i + 1))
        break
        ;;
      -*)
        return 1
        ;;
      *)
        if [[ "${args[$i]}" =~ ^[0-9]+$ ]]; then
          i=$((i + 1))
          break
        fi
        return 1
        ;;
    esac
    i=$((i + 1))
  done
  [[ "$i" -lt "$#" ]] || return 1
  tm_argv_is_safe "${args[@]:$i}"
}

tm_managed_update_path() {
  local path
  path=$(tm_normalize_path "$1") || return 1
  tm_path_under "$path" "${TM_VAR}/update" || return 1
  return 0
}

tm_curl_argv_is_safe() {
  local dest url
  [[ "$#" -eq 8 ]] || return 1
  dest="$7"
  url="$8"
  [[ "$1" == "curl" && "$2" == "-fsSL" && "$3" == "--proto" && "$4" == "=https" ]] || return 1
  [[ "$5" == "--tlsv1.2" && "$6" == "-o" ]] || return 1
  tm_managed_update_path "$dest" || return 1
  [[ "$url" == "https://github.com/MoonlessWanderer/TunnelManager/archive/refs/heads/main.tar.gz" ]] || return 1
  return 0
}

tm_tar_argv_is_safe() {
  if [[ "$1" == "tar" && "$2" == "-tzf" && "$#" -eq 3 ]]; then
    tm_managed_update_path "$3"
    return $?
  fi
  [[ "$1" == "tar" && "$2" == "-xzf" && "$4" == "-C" && "$#" -eq 5 ]] || return 1
  tm_managed_update_path "$3" || return 1
  tm_managed_update_path "$5" || return 1
  return 0
}

tm_argv_is_safe() {
  if [[ "$#" -eq 0 ]]; then
    return 1
  fi
  case "$1" in
    tm_*)
      [[ "$1" =~ ^tm_[A-Za-z0-9_]+$ ]]
      ;;
    iptables|ip6tables)
      tm_iptables_argv_is_safe "$@"
      ;;
    curl)
      tm_curl_argv_is_safe "$@"
      ;;
    tar)
      tm_tar_argv_is_safe "$@"
      ;;
    nft)
      tm_nft_argv_is_safe "$@"
      ;;
    ip)
      tm_ip_argv_is_safe "$@"
      ;;
    sysctl)
      tm_sysctl_argv_is_safe "$@"
      ;;
    systemctl)
      tm_systemctl_argv_is_safe "$@"
      ;;
    modprobe)
      tm_modprobe_argv_is_safe "$@"
      ;;
    ping)
      tm_ping_argv_is_safe "$@"
      ;;
    ss)
      tm_ss_argv_is_safe "$@"
      ;;
    timeout)
      tm_timeout_argv_is_safe "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

tm_eval_argv() {
  local encoded="$1"
  local -n _tm_argv=$2
  # encoded is produced by printf %q. The eval only rebuilds the argument array.
  # shellcheck disable=SC2294
  eval "_tm_argv=( $encoded )"
}
