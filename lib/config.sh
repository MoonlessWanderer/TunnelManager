# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — paths, atomic writes, and strict KEY=VALUE state files.
# State files are parsed. They are never sourced.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "config.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_CONFIG_LOADED:-}" ]]; then
  return 0
fi
TM_CONFIG_LOADED=1

tm_paths_init() {
  TM_ETC="${TM_ETC:-/etc/tunnel-manager}"
  TM_VAR="${TM_VAR:-/var/lib/tunnel-manager}"
  TM_LOG_DIR="${TM_LOG_DIR:-/var/log/tunnel-manager}"
  TM_RUN="${TM_RUN:-/run/tunnel-manager}"
  TM_SYSCTL_FILE="${TM_SYSCTL_FILE:-/etc/sysctl.d/99-tunnel-manager.conf}"
  TM_BBR_FILE="${TM_BBR_FILE:-/etc/sysctl.d/98-tunnel-manager-bbr.conf}"
  TM_BBR_MOD_FILE="${TM_BBR_MOD_FILE:-/etc/modules-load.d/tunnel-manager-bbr.conf}"
  TM_BIN="${TM_BIN:-${TM_PREFIX:-/usr/local}/bin/tunnel-manager}"
  TM_LIB_INSTALL="${TM_LIB_INSTALL:-${TM_PREFIX:-/usr/local}/lib/tunnel-manager}"
}

tm_init_runtime() {
  tm_require_bash
  tm_paths_init
  : "${TM_YES:=0}"
  : "${TM_DRY_RUN:=0}"
  : "${TM_LOG_LEVEL:=info}"
  : "${TM_SSH_PORT:=22}"
  tm_assert_storage_roots
}

tm_normalize_path() {
  local input="$1"
  local -a raw_parts=()
  local -a kept_parts=()
  local part out="" idx
  input=${input//\\//}
  [[ "$input" == /* ]] || return 1
  IFS='/' read -r -a raw_parts <<<"$input"
  for part in "${raw_parts[@]}"; do
    case "$part" in
      ""|.) continue ;;
      ..) return 1 ;;
      *) kept_parts+=("$part") ;;
    esac
  done
  if [[ "${#kept_parts[@]}" -eq 0 ]]; then
    printf '%s\n' "/"
    return 0
  fi
  for idx in "${!kept_parts[@]}"; do
    out+="/${kept_parts[$idx]}"
  done
  printf '%s\n' "$out"
}

tm_path_under() {
  local path="$1"
  local root="$2"
  [[ "$path" == "$root" || "$path" == "$root"/* ]]
}

tm_path_has_symlink_component() {
  local path="$1"
  local acc=""
  local part
  local -a parts=()
  IFS='/' read -r -a parts <<<"${path#/}"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    acc+="/${part}"
    if [[ -L "$acc" ]]; then
      return 0
    fi
  done
  return 1
}

tm_assert_storage_roots() {
  local path norm base
  local -a roots=()
  roots=("$TM_ETC" "$TM_VAR" "$TM_LOG_DIR" "$TM_RUN")
  for path in "${roots[@]}"; do
    norm=$(tm_normalize_path "$path") || tm_die "Invalid storage path: ${path}"
    case "$norm" in
      /|/etc|/usr|/usr/bin|/bin|/sbin|/boot|/var|/run|/home|/etc/sysctl.d)
        tm_die "Refusing broad storage path: ${norm}"
        ;;
    esac
  done
  if [[ "${TM_TEST_MODE:-0}" == "1" ]]; then
    return 0
  fi
  base=$(basename "$TM_ETC")
  [[ "$base" == "tunnel-manager" ]] || tm_die "TM_ETC must end with tunnel-manager."
  [[ "$TM_ETC" == /etc/tunnel-manager || "$TM_ETC" == */tunnel-manager ]] || tm_die "Refusing TM_ETC=${TM_ETC}"
  [[ "$TM_VAR" == /var/lib/tunnel-manager ]] || tm_die "Refusing TM_VAR=${TM_VAR}"
  [[ "$TM_LOG_DIR" == /var/log/tunnel-manager ]] || tm_die "Refusing TM_LOG_DIR=${TM_LOG_DIR}"
  [[ "$TM_RUN" == /run/tunnel-manager ]] || tm_die "Refusing TM_RUN=${TM_RUN}"
  [[ "$TM_SYSCTL_FILE" == /etc/sysctl.d/99-tunnel-manager.conf ]] || tm_die "Refusing TM_SYSCTL_FILE=${TM_SYSCTL_FILE}"
  [[ "$TM_BBR_FILE" == /etc/sysctl.d/98-tunnel-manager-bbr.conf ]] || tm_die "Refusing TM_BBR_FILE=${TM_BBR_FILE}"
  [[ "$TM_BBR_MOD_FILE" == /etc/modules-load.d/tunnel-manager-bbr.conf ]] || tm_die "Refusing TM_BBR_MOD_FILE=${TM_BBR_MOD_FILE}"
}

tm_path_is_mutable() {
  local raw="$1"
  local path etc var log run sysctl bbr="" bbr_mod=""
  path=$(tm_normalize_path "$raw") || return 1
  etc=$(tm_normalize_path "$TM_ETC") || return 1
  var=$(tm_normalize_path "$TM_VAR") || return 1
  log=$(tm_normalize_path "$TM_LOG_DIR") || return 1
  run=$(tm_normalize_path "$TM_RUN") || return 1
  sysctl=$(tm_normalize_path "$TM_SYSCTL_FILE") || return 1
  bbr=$(tm_normalize_path "$TM_BBR_FILE") || return 1
  bbr_mod=$(tm_normalize_path "$TM_BBR_MOD_FILE") || return 1
  if tm_path_under "$path" "$etc" \
    || tm_path_under "$path" "$var" \
    || tm_path_under "$path" "$log" \
    || tm_path_under "$path" "$run" \
    || [[ "$path" == "$sysctl" || "$path" == "$bbr" || "$path" == "$bbr_mod" ]]; then
    :
  else
    return 1
  fi
  if tm_path_has_symlink_component "$path"; then
    return 1
  fi
  return 0
}

tm_mkdir_mode() {
  local dir="$1"
  local mode="$2"
  local chmod_existing="${3:-yes}"
  tm_path_is_mutable "$dir" || tm_die "Refusing to create directory outside Tunnel Manager state: ${dir}"
  if [[ -d "$dir" ]]; then
    if [[ "$chmod_existing" == "yes" ]]; then
      chmod "$mode" "$dir" || tm_die "Cannot set mode ${mode} on ${dir}"
    fi
    return 0
  fi
  mkdir -p -- "$dir" || tm_die "Cannot create directory ${dir}"
  chmod "$mode" "$dir" || tm_die "Cannot set mode ${mode} on ${dir}"
}

tm_ensure_tree() {
  tm_paths_init
  tm_mkdir_mode "$TM_ETC" 0755
  tm_mkdir_mode "$TM_ETC/tunnels" 0700
  tm_mkdir_mode "$TM_ETC/forwards" 0700
  tm_mkdir_mode "$TM_ETC/keys" 0700
  tm_mkdir_mode "$TM_VAR" 0700
  tm_mkdir_mode "$TM_VAR/backups" 0700
  tm_mkdir_mode "$TM_VAR/snapshots" 0700
  tm_mkdir_mode "$TM_LOG_DIR" 0750
  tm_mkdir_mode "$TM_RUN" 0750
}

tm_write_file() {
  local dest="$1"
  local mode="$2"
  local tmp
  case "$mode" in
    0600|0640|0644|0700|0750|0755) ;;
    *) tm_die "Refusing unusual file mode ${mode}." ;;
  esac
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    cat >/dev/null || true
    tm_info "DRY-RUN: write ${dest} mode ${mode}"
    return 0
  fi
  tm_path_is_mutable "$dest" || tm_die "Refusing to write outside Tunnel Manager state: ${dest}"
  if [[ -e "$dest" && ! -f "$dest" ]]; then
    tm_die "Refusing to replace a non-regular file: ${dest}"
  fi
  if [[ -L "$dest" ]]; then
    tm_die "Refusing to write through a symlink: ${dest}"
  fi
  tmp=$(mktemp "$(dirname -- "$dest")/.tm.XXXXXX") || tm_die "Cannot create a temporary file beside ${dest}"
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    tm_die "Cannot write temporary file for ${dest}"
  fi
  chmod "$mode" "$tmp" || {
    rm -f -- "$tmp"
    tm_die "Cannot set mode ${mode} on ${dest}"
  }
  mv -f -- "$tmp" "$dest" || {
    rm -f -- "$tmp"
    tm_die "Cannot move temporary file into ${dest}"
  }
}

tm_safe_rm() {
  local path="$1"
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    tm_info "DRY-RUN: remove ${path}"
    return 0
  fi
  tm_path_is_mutable "$path" || tm_die "Refusing to delete outside Tunnel Manager state: ${path}"
  if [[ -L "$path" ]]; then
    tm_die "Refusing to delete a symlink: ${path}"
  fi
  if [[ -d "$path" ]]; then
    tm_die "Refusing to delete a directory with rm: ${path}"
  fi
  rm -f -- "$path"
}

tm_path_id() {
  printf '%s' "$1" | cksum | awk '{print $1}'
}

tm_snapshot_file() {
  local dest="$1"
  local id snap
  tm_path_is_mutable "$dest" || return 1
  tm_mkdir_mode "$TM_VAR/snapshots" 0700
  id=$(tm_path_id "$dest")
  snap="${TM_VAR}/snapshots/${id}"
  if [[ -f "$dest" ]]; then
    cp -- "$dest" "$snap" || return 1
    printf '%s\n' "file" >"${snap}.kind"
  else
    : >"$snap"
    printf '%s\n' "missing" >"${snap}.kind"
  fi
  printf '%s\n' "$dest" >"${snap}.path"
}

tm_restore_snapshot() {
  local dest="$1"
  local id snap kind
  id=$(tm_path_id "$dest")
  snap="${TM_VAR}/snapshots/${id}"
  [[ -f "${snap}.kind" ]] || return 0
  kind=$(cat "${snap}.kind")
  case "$kind" in
    missing)
      if [[ -f "$dest" ]]; then
        tm_safe_rm "$dest"
      fi
      ;;
    file)
      tm_path_is_mutable "$dest" || return 1
      cp -- "$snap" "$dest" || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

tm_kv_key_ok() {
  case "$1" in
    TM_HOST_ROLE|TM_HOST_PUBLIC_IP|TM_HOST_WAN_IFACE|TM_SSH_PORT|TM_FW_BACKEND|\
      TM_TUNNEL_NAME|TM_TUNNEL_TYPE|TM_TUNNEL_STATE|TM_LOCAL_PUBLIC_IP|TM_REMOTE_PUBLIC_IP|\
      TM_LOCAL_TUNNEL_IP|TM_REMOTE_TUNNEL_IP|TM_TUNNEL_CIDR|TM_LISTEN_PORT|TM_ENDPOINT_PORT|\
      TM_MTU|TM_KEEPALIVE|TM_WAN_IFACE|TM_PEER_PUBLIC_KEY|TM_PRIVATE_KEY_FILE|TM_GRE_ACK|\
      TM_FORWARD_NAME|TM_FORWARD_PROTO|TM_LISTEN_IP|TM_DEST_IP|TM_DEST_PORT|TM_SNAT|\
      TM_INGRESS_IFACE|TM_SOURCE_IP|TM_TUNNEL_REF|\
      TM_PEER_NAME|TM_PEER_ROLE|TM_PEER_PUBLIC_IP|TM_PEER_TUNNEL_IP|TM_PEER_LISTEN_PORT|\
      TM_PEER_TUNNEL_TYPE|TM_PEER_CIDR|TM_PEER_MTU|TM_PEER_WAN_HINT)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tm_kv_value_ok() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  ((${#value} <= 220)) || return 1
  # Slash is allowed so a private-key path can be stored. ".." is not.
  [[ "$value" != *..* ]] || return 1
  # Colon is allowed for IPv6 addresses. ".." is still rejected above.
  [[ "$value" =~ ^[A-Za-z0-9._+/=:@,:/-]+$ ]] || return 1
  return 0
}

tm_kv_validate_pair() {
  tm_kv_key_ok "$1" || return 1
  tm_kv_value_ok "$2" || return 1
  return 0
}

tm_kv_read() {
  local file="$1"
  local -n _tm_dst=$2
  local line key value
  [[ -f "$file" ]] || return 1
  [[ ! -L "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *"="* ]] && return 1
    # Values may contain '='.
    [[ "$line" =~ ^[A-Z0-9_]+=.+$ ]] || return 1
    key=${line%%=*}
    value=${line#*=}
    tm_kv_validate_pair "$key" "$value" || return 1
    _tm_dst["$key"]=$value
  done <"$file"
}

tm_kv_write() {
  local dest="$1"
  local mode="$2"
  shift 2
  local -a pairs=("$@")
  local i tmp
  case "$mode" in
    0600|0640|0644) ;;
    *) tm_die "Refusing unusual state-file mode ${mode}." ;;
  esac
  if ((${#pairs[@]} == 0 || ${#pairs[@]} % 2 != 0)); then
    tm_die "Internal error: configuration pairs are incomplete."
  fi
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    tm_kv_validate_pair "${pairs[$i]}" "${pairs[$((i + 1))]}" \
      || tm_die "Refusing to store invalid configuration value for ${pairs[$i]}."
  done
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    tm_info "DRY-RUN: write state ${dest}"
    return 0
  fi
  tm_path_is_mutable "$dest" || tm_die "Refusing to write outside Tunnel Manager state: ${dest}"
  tmp=$(mktemp "$(dirname -- "$dest")/.tm.XXXXXX") || tm_die "Cannot create a temporary state file."
  {
    printf '%s\n' "# Tunnel Manager state. Edit through the CLI."
    for ((i = 0; i < ${#pairs[@]}; i += 2)); do
      printf '%s=%s\n' "${pairs[$i]}" "${pairs[$((i + 1))]}"
    done
  } >"$tmp" || {
    rm -f -- "$tmp"
    tm_die "Cannot write ${dest}."
  }
  chmod "$mode" "$tmp" || {
    rm -f -- "$tmp"
    tm_die "Cannot set permissions on ${dest}."
  }
  mv -f -- "$tmp" "$dest" || {
    rm -f -- "$tmp"
    tm_die "Cannot install ${dest}."
  }
}

tm_host_file() {
  printf '%s\n' "${TM_ETC}/host.conf"
}

tm_tunnel_file() {
  printf '%s\n' "${TM_ETC}/tunnels/${1}.conf"
}

tm_tunnel_iface() {
  printf 'tm-%s\n' "$1"
}

tm_forward_file() {
  printf '%s\n' "${TM_ETC}/forwards/${1}.conf"
}

tm_key_file() {
  printf '%s\n' "${TM_ETC}/keys/${1}.key"
}

tm_pub_file() {
  printf '%s\n' "${TM_ETC}/keys/${1}.pub"
}

tm_list_files() {
  local dir="$1"
  local suffix="$2"
  local f base
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*"$suffix"; do
    [[ -f "$f" ]] || continue
    base=$(basename -- "$f")
    printf '%s\n' "${base%"$suffix"}"
  done
}

tm_list_tunnels() {
  tm_list_files "${TM_ETC}/tunnels" ".conf"
}

tm_list_forwards() {
  tm_list_files "${TM_ETC}/forwards" ".conf"
}

tm_load_host() {
  local -n _tm_host=$1
  local file
  file=$(tm_host_file)
  [[ -f "$file" ]] || return 1
  tm_kv_read "$file" _tm_host
}

tm_ssh_port() {
  local -A host=()
  TM_SSH_PORT="${TM_SSH_PORT:-22}"
  if [[ -f "$(tm_host_file)" ]] && tm_load_host host; then
    if [[ -n "${host[TM_SSH_PORT]:-}" ]]; then
      TM_SSH_PORT="${host[TM_SSH_PORT]}"
    fi
  fi
  printf '%s\n' "$TM_SSH_PORT"
}
