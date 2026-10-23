# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — configuration backups.
# Private keys are excluded unless the operator passes --include-keys.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "backup.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_BACKUP_LOADED:-}" ]]; then
  return 0
fi
TM_BACKUP_LOADED=1

tm_backup_member_ok() {
  local member="$1"
  local include_keys="$2"
  local base
  [[ "$member" != /* ]] || return 1
  [[ "$member" != *..* ]] || return 1
  [[ "$member" != *$'\n'* ]] || return 1
  case "$member" in
    MANIFEST|host.conf|haproxy.cfg) return 0 ;;
    tunnels/*.conf)
      base=${member#tunnels/}
      [[ "$base" != */* && "$base" == *.conf ]] || return 1
      [[ "$base" =~ ^[a-z][a-z0-9-]{0,11}\.conf$ ]] || return 1
      return 0
      ;;
    forwards/*.conf)
      base=${member#forwards/}
      [[ "$base" != */* && "$base" == *.conf ]] || return 1
      [[ "$base" =~ ^[a-z][a-z0-9-]{0,19}\.conf$ ]] || return 1
      return 0
      ;;
    keys/*.key|keys/*.pub)
      [[ "$include_keys" == "1" ]] || return 1
      base=${member#keys/}
      [[ "$base" != */* ]] || return 1
      [[ "$base" =~ ^[a-z][a-z0-9-]{0,11}\.(key|pub)$ ]] || return 1
      return 0
      ;;
    wireguard/tm-*.conf)
      [[ "$include_keys" == "1" ]] || return 1
      base=${member#wireguard/}
      [[ "$base" =~ ^tm-[a-z][a-z0-9-]{0,11}\.conf$ ]] || return 1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tm_backup_normalize_member() {
  local member="$1"
  member=${member%$'\r'}
  member=${member#./}
  printf '%s\n' "$member"
}

tm_kv_file_ok() {
  local file="$1"
  local -A row=()
  tm_kv_read "$file" row
}

tm_backup_validate_members() {
  local archive="$1"
  local include_keys="$2"
  local member normalized
  local saw=0
  while IFS= read -r member; do
    normalized=$(tm_backup_normalize_member "$member")
    [[ -n "$normalized" ]] || continue
    [[ "$normalized" == */ ]] && continue
    saw=1
    tm_backup_member_ok "$normalized" "$include_keys" || return 1
  done < <(tar -tzf "$archive")
  [[ "$saw" -eq 1 ]]
}

tm_backup_create_exec() {
  local output="$1"
  local include_keys="$2"
  local stage manifest name
  tm_export_dest_ok "$output" || {
    tm_error "Refusing backup output path ${output}."
    return 1
  }
  if [[ -L "$output" ]]; then
    tm_error "Refusing to write a backup through a symlink."
    return 1
  fi
  stage=$(mktemp -d "${TMPDIR:-/tmp}/tm-backup.XXXXXX") || return 1
  mkdir -p -- "$stage/tunnels" "$stage/forwards"
  if [[ -f "$(tm_host_file)" ]]; then
    cp -- "$(tm_host_file)" "$stage/host.conf" || return 1
  fi
  if [[ -f "$TM_HAPROXY_CFG" ]]; then
    cp -- "$TM_HAPROXY_CFG" "$stage/haproxy.cfg" || return 1
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    cp -- "$(tm_tunnel_file "$name")" "$stage/tunnels/${name}.conf" || return 1
    if [[ "$include_keys" == "1" ]]; then
      if [[ -f "$(tm_key_file "$name")" || -f "$(tm_pub_file "$name")" ]]; then
        mkdir -p -- "$stage/keys"
      fi
      if [[ -f "$(tm_key_file "$name")" ]]; then
        cp -- "$(tm_key_file "$name")" "$stage/keys/${name}.key" || return 1
      fi
      if [[ -f "$(tm_pub_file "$name")" ]]; then
        cp -- "$(tm_pub_file "$name")" "$stage/keys/${name}.pub" || return 1
      fi
    fi
  done < <(tm_list_tunnels)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    cp -- "$(tm_forward_file "$name")" "$stage/forwards/${name}.conf" || return 1
  done < <(tm_list_forwards)
  manifest="$stage/MANIFEST"
  {
    printf '%s\n' "tunnel-manager-backup"
    printf 'version=%s\n' "$TM_VERSION"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'includes_keys=%s\n' "$include_keys"
  } >"$manifest"
  mkdir -p -- "$(dirname -- "$output")"
  local -a files=(MANIFEST)
  local path rel
  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    rel=${path#"${stage}/"}
    [[ "$rel" == "MANIFEST" ]] && continue
    files+=("$rel")
  done < <(find "$stage" -type f | sort)
  tar -C "$stage" -czf "$output" "${files[@]}" || {
    rm -rf -- "$stage"
    return 1
  }
  rm -rf -- "$stage"
  tm_info "Wrote backup ${output}"
}

tm_backup_install_tree() {
  local stage="$1"
  local include_keys="$2"
  local f base
  tm_ensure_tree || return 1
  if [[ -f "$stage/host.conf" ]]; then
    tm_kv_file_ok "$stage/host.conf" || {
      tm_error "Backup host.conf failed validation."
      return 1
    }
  fi
  for f in "$stage/tunnels"/*.conf; do
    [[ -f "$f" ]] || continue
    tm_kv_file_ok "$f" || {
      tm_error "Backup tunnel file failed validation: $(basename "$f")"
      return 1
    }
  done
  for f in "$stage/forwards"/*.conf; do
    [[ -f "$f" ]] || continue
    tm_kv_file_ok "$f" || return 1
  done
  if [[ -f "$stage/host.conf" ]]; then
    cp -- "$stage/host.conf" "$(tm_host_file)" || return 1
    chmod 0600 "$(tm_host_file)" || return 1
  fi
  if [[ -f "$stage/haproxy.cfg" ]]; then
    cp -- "$stage/haproxy.cfg" "$TM_HAPROXY_CFG" || return 1
    chmod 0644 "$TM_HAPROXY_CFG" || return 1
  fi
  for f in "$stage/tunnels"/*.conf; do
    [[ -f "$f" ]] || continue
    base=$(basename -- "$f")
    cp -- "$f" "${TM_ETC}/tunnels/${base}" || return 1
    chmod 0600 "${TM_ETC}/tunnels/${base}" || return 1
  done
  for f in "$stage/forwards"/*.conf; do
    [[ -f "$f" ]] || continue
    base=$(basename -- "$f")
    cp -- "$f" "${TM_ETC}/forwards/${base}" || return 1
    chmod 0600 "${TM_ETC}/forwards/${base}" || return 1
  done
  if [[ "$include_keys" == "1" ]]; then
    for f in "$stage/keys"/*; do
      [[ -f "$f" ]] || continue
      base=$(basename -- "$f")
      cp -- "$f" "${TM_ETC}/keys/${base}" || return 1
      chmod 0600 "${TM_ETC}/keys/${base}" || return 1
    done
    for f in "$stage/wireguard"/*.conf; do
      [[ -f "$f" ]] || continue
      base=$(basename -- "$f")
      cp -- "$f" "${TM_WG_DIR}/${base}" || return 1
      chmod 0600 "${TM_WG_DIR}/${base}" || return 1
    done
  fi
}

tm_action_backup_create() {
  local -A opt=()
  local output include="0"
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt output output
  output="${opt[output]}"
  if [[ "${opt[include_keys]:-0}" == "1" ]]; then
    include="1"
    tm_warn "This backup will contain private keys. Store it somewhere restricted."
  fi
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    tm_info "Dry-run: backup would be written to ${output}. include_keys=${include}."
    return 0
  fi
  tm_backup_create_exec "$output" "$include"
}

tm_action_backup_restore() {
  local -A opt=()
  local archive include="0" stage member
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  tm_opt_require opt file file
  archive="${opt[file]}"
  [[ -f "$archive" && ! -L "$archive" ]] || tm_die "Backup file was not found."
  if [[ "${opt[include_keys]:-0}" == "1" ]]; then
    include="1"
  fi
  tm_backup_validate_members "$archive" "$include" || tm_die "Backup contains an unexpected or unsafe path."
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    tm_info "Dry-run backup members:"
    while IFS= read -r member; do
      printf '%s\n' "$member"
    done < <(tar -tzf "$archive")
    tm_info "Dry-run only. No files were restored."
    return 0
  fi
  if ! tm_confirm "Restore this backup over the current Tunnel Manager state?"; then
    tm_info "Restore aborted."
    return 2
  fi
  stage=$(mktemp -d "${TMPDIR:-/tmp}/tm-restore.XXXXXX") || tm_die "Cannot create a restore directory."
  tar -C "$stage" -xzf "$archive" || {
    rm -rf -- "$stage"
    tm_die "Cannot extract the backup."
  }
  tm_backup_install_tree "$stage" "$include" || {
    rm -rf -- "$stage"
    tm_die "Restore validation failed. Live state was left in place if copy had not started; check the files before applying."
  }
  rm -rf -- "$stage"
  tm_info "Backup files were restored. Review them, then run: tunnel-manager apply"
}

tm_action_backup_list() {
  local f
  local dir="${TM_VAR}/backups"
  if [[ ! -d "$dir" ]]; then
    tm_info "No backups are stored in ${dir}."
    return 0
  fi
  local found=0
  for f in "$dir"/*.tar.gz; do
    [[ -f "$f" ]] || continue
    found=1
    printf '%s\n' "$f"
  done
  if [[ "$found" -eq 0 ]]; then
    tm_info "No backups are stored in ${dir}."
  fi
}
