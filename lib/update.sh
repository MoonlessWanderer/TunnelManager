# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — download and reinstall without touching tunnels or firewall rules.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "update.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_UPDATE_LOADED:-}" ]]; then
  return 0
fi
TM_UPDATE_LOADED=1

TM_RELEASE_URL="https://github.com/MoonlessWanderer/TunnelManager/archive/refs/heads/main.tar.gz"

tm_install_prefix() {
  local prefix=""
  if [[ -n "${TM_PREFIX:-}" ]]; then
    prefix=$TM_PREFIX
  elif [[ "${TM_LIB_DIR:-}" == */lib/tunnel-manager ]]; then
    prefix=$(cd -P "${TM_LIB_DIR}/../.." && pwd)
  else
    prefix=/usr/local
  fi
  [[ -n "$prefix" && "$prefix" != "/" && "$prefix" != "/etc" ]] || return 1
  printf '%s\n' "$prefix"
}

tm_update_download_exec() {
  local dest="${TM_VAR}/update/tunnel-manager.tar.gz"
  mkdir -p -- "${TM_VAR}/update" || return 1
  chmod 0700 "${TM_VAR}/update" || true
  if [[ -n "${TM_UPDATE_ARCHIVE:-}" ]]; then
    [[ -f "$TM_UPDATE_ARCHIVE" && ! -L "$TM_UPDATE_ARCHIVE" ]] || return 1
    cp -f -- "$TM_UPDATE_ARCHIVE" "$dest" || return 1
    return 0
  fi
  tm_must curl -fsSL --proto '=https' --tlsv1.2 -o "$dest" "$TM_RELEASE_URL"
}

tm_update_download_undo() {
  local dest="${TM_VAR}/update/tunnel-manager.tar.gz"
  if [[ -f "$dest" ]]; then
    tm_safe_rm "$dest" || return 1
  fi
}

tm_update_members_ok() {
  local archive="$1"
  local member listing="" status=0
  set +e
  listing=$(tm_run tar -tzf "$archive")
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || return 1
  while IFS= read -r member || [[ -n "$member" ]]; do
    [[ -n "$member" ]] || continue
    case "$member" in
      /*|*..*) return 1 ;;
    esac
  done <<<"$listing"
}

tm_update_extract_exec() {
  local archive="${TM_VAR}/update/tunnel-manager.tar.gz"
  local dest="${TM_VAR}/update/src"
  local dir found=""
  rm -rf -- "$dest"
  mkdir -p -- "$dest" || return 1
  tm_update_members_ok "$archive" || {
    tm_error "The archive contains an unsafe path."
    return 1
  }
  tm_must tar -xzf "$archive" -C "$dest" || return 1
  if [[ -f "$dest/install.sh" && -f "$dest/bin/tunnel-manager" && -f "$dest/lib/load.sh" ]]; then
    found=$dest
  else
    for dir in "$dest"/*; do
      [[ -d "$dir" ]] || continue
      if [[ -f "$dir/install.sh" && -f "$dir/bin/tunnel-manager" && -f "$dir/lib/load.sh" ]]; then
        found=$dir
        break
      fi
    done
  fi
  [[ -n "$found" && ! -L "$found/install.sh" ]] || {
    tm_error "The archive does not contain Tunnel Manager."
    return 1
  }
  printf '%s\n' "$found" >"${TM_VAR}/update/root.path"
  chmod 0600 "${TM_VAR}/update/root.path" || true
}

tm_update_extract_undo() {
  rm -rf -- "${TM_VAR}/update/src"
  if [[ -f "${TM_VAR}/update/root.path" ]]; then
    tm_safe_rm "${TM_VAR}/update/root.path" || return 1
  fi
}

tm_update_copy_if_present() {
  local src="$1"
  local dest="$2"
  if [[ -e "$src" && ! -L "$src" ]]; then
    mkdir -p -- "$(dirname -- "$dest")"
    cp -a -- "$src" "$dest" || return 1
  fi
}

tm_update_snapshot_exec() {
  local prefix snap present="no"
  prefix=$(tm_install_prefix) || return 1
  snap="${TM_VAR}/update/previous"
  rm -rf -- "$snap"
  mkdir -p -- "$snap/bin" "$snap/lib" "$snap/share" "$snap/units" || return 1
  if [[ -f "$prefix/bin/tunnel-manager" ]]; then
    present="yes"
    tm_update_copy_if_present "$prefix/bin/tunnel-manager" "$snap/bin/tunnel-manager" || return 1
  fi
  tm_update_copy_if_present "$prefix/bin/tm" "$snap/bin/tm" || return 1
  if [[ -d "$prefix/lib/tunnel-manager" && ! -L "$prefix/lib/tunnel-manager" ]]; then
    cp -a -- "$prefix/lib/tunnel-manager" "$snap/lib/" || return 1
    present="yes"
  fi
  if [[ -d "$prefix/share/tunnel-manager" && ! -L "$prefix/share/tunnel-manager" ]]; then
    cp -a -- "$prefix/share/tunnel-manager" "$snap/share/" || return 1
  fi
  tm_update_copy_if_present /etc/systemd/system/tunnel-manager-apply.service "$snap/units/tunnel-manager-apply.service" || return 1
  tm_update_copy_if_present /etc/systemd/system/tunnel-manager-haproxy.service "$snap/units/tunnel-manager-haproxy.service" || return 1
  printf '%s\n' "$present" >"$snap/present"
  printf '%s\n' "$prefix" >"$snap/prefix"
  chmod 0600 "$snap/present" "$snap/prefix" || true
}

tm_update_snapshot_undo() {
  rm -rf -- "${TM_VAR}/update/previous"
}

tm_update_restore_exec() {
  local snap="${TM_VAR}/update/previous"
  local prefix present
  [[ -f "$snap/prefix" && -f "$snap/present" ]] || return 1
  prefix=$(<"$snap/prefix")
  present=$(<"$snap/present")
  prefix=${prefix//$'\r'/}
  prefix=${prefix%$'\n'}
  present=${present//$'\r'/}
  present=${present%$'\n'}
  [[ "$prefix" != "/" && "$prefix" != "/etc" && -n "$prefix" ]] || return 1
  if [[ "$present" == "yes" ]]; then
    mkdir -p -- "$prefix/bin" "$prefix/lib" "$prefix/share" || return 1
    [[ -f "$snap/bin/tunnel-manager" ]] && cp -a -- "$snap/bin/tunnel-manager" "$prefix/bin/tunnel-manager"
    [[ -f "$snap/bin/tm" ]] && cp -a -- "$snap/bin/tm" "$prefix/bin/tm"
    if [[ -d "$snap/lib/tunnel-manager" ]]; then
      rm -rf -- "$prefix/lib/tunnel-manager"
      cp -a -- "$snap/lib/tunnel-manager" "$prefix/lib/" || return 1
    fi
    if [[ -d "$snap/share/tunnel-manager" ]]; then
      rm -rf -- "$prefix/share/tunnel-manager"
      cp -a -- "$snap/share/tunnel-manager" "$prefix/share/" || return 1
    fi
  else
    rm -f -- "$prefix/bin/tunnel-manager" "$prefix/bin/tm"
    rm -rf -- "$prefix/lib/tunnel-manager" "$prefix/share/tunnel-manager"
  fi
  if [[ -f "$snap/units/tunnel-manager-apply.service" ]]; then
    cp -a -- "$snap/units/tunnel-manager-apply.service" /etc/systemd/system/tunnel-manager-apply.service || return 1
  fi
  if [[ -f "$snap/units/tunnel-manager-haproxy.service" ]]; then
    cp -a -- "$snap/units/tunnel-manager-haproxy.service" /etc/systemd/system/tunnel-manager-haproxy.service || return 1
  fi
}

tm_update_install_exec() {
  local root prefix
  local -a args=()
  root=$(<"${TM_VAR}/update/root.path")
  root=${root//$'\r'/}
  root=${root%$'\n'}
  prefix=$(tm_install_prefix) || return 1
  [[ -n "$root" && -f "$root/install.sh" && ! -L "$root/install.sh" ]] || return 1
  tm_path_under "$root" "${TM_VAR}/update/src" || return 1
  args=(--prefix "$prefix" --yes)
  if [[ "${TM_TEST_MODE:-0}" == "1" ]]; then
    args+=(--skip-packages --skip-systemd)
  fi
  bash "$root/install.sh" "${args[@]}"
}

tm_update_install_undo() {
  tm_update_restore_exec
}

tm_action_update() {
  local -A opt=()
  local prefix
  tm_opts_parse opt "$@"
  tm_opts_bind_flags opt
  prefix=$(tm_install_prefix) || tm_die "Refusing to update an unsafe install prefix."
  tm_plan_require_clear_journal
  tm_plan_reset
  tm_plan_add "Download Tunnel Manager. Existing firewall rules and the default route stay unchanged." \
    "$(tm_shell_quote tm_update_download_undo)" \
    tm_update_download_exec
  tm_plan_add "Verify the archive and extract it under managed state" \
    "$(tm_shell_quote tm_update_extract_undo)" \
    tm_update_extract_exec
  tm_plan_add "Snapshot the current installation in ${prefix}" \
    "$(tm_shell_quote tm_update_snapshot_undo)" \
    tm_update_snapshot_exec
  tm_plan_add "Reinstall Tunnel Manager into ${prefix} without enabling services" \
    "$(tm_shell_quote tm_update_install_undo)" \
    tm_update_install_exec
  tm_require_change_privileges
  tm_with_lock tm_plan_apply
}
