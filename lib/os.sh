# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — operating-system checks.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "os.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_OS_LOADED:-}" ]]; then
  return 0
fi
TM_OS_LOADED=1

tm_os_is_linux() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name=$(uname -s)
  fi
  [[ "$name" == "Linux" ]]
}

tm_os_release_value() {
  local key="$1"
  local line value
  [[ -r /etc/os-release ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == "${key}="* ]] || continue
    value=${line#*=}
    value=${value#\"}
    value=${value%\"}
    printf '%s\n' "$value"
    return 0
  done </etc/os-release
  return 1
}

tm_os_is_supported() {
  local id like
  id=$(tm_os_release_value ID || true)
  like=$(tm_os_release_value ID_LIKE || true)
  case "$id" in
    ubuntu|debian) return 0 ;;
  esac
  case " ${like} " in
    *" debian "*) return 0 ;;
  esac
  return 1
}

tm_require_linux_for_apply() {
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${TM_TEST_MODE:-0}" == "1" && "${TM_ALLOW_NON_LINUX:-0}" == "1" ]]; then
    return 0
  fi
  tm_os_is_linux || tm_die "This operation requires Linux."
}

tm_require_change_privileges() {
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  tm_require_linux_for_apply
  tm_require_root
}

tm_use_systemd() {
  if [[ "${TM_TEST_MODE:-0}" == "1" && -z "${TM_BIN_OVERRIDE[systemctl]:-}" ]]; then
    return 1
  fi
  tm_cmd_available systemctl || return 1
  if [[ "${TM_TEST_MODE:-0}" == "1" ]]; then
    return 0
  fi
  [[ -d /run/systemd/system ]]
}
