# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — logging, errors, locking, and command execution.
# This file is sourced. It does not change network state.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "common.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_COMMON_LOADED:-}" ]]; then
  return 0
fi
TM_COMMON_LOADED=1

TM_VERSION="2.0.2"

tm_version() {
  printf '%s\n' "$TM_VERSION"
}

tm_styled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" && -t "$1" ]]
}

# Quiet one-line form used while the menu runs.
# The log file always keeps the timestamped line.
tm_face_print() {
  local level="$1"
  local msg="$2"
  local open="" close="" mark=""
  if [[ "$level" == "WARN" || "$level" == "ERROR" ]] && [[ "$msg" != "["* ]]; then
    mark="! "
  fi
  if tm_styled 2; then
    if [[ "$level" == "WARN" || "$level" == "ERROR" ]]; then
      open=$'\033[1m'
    elif [[ "$msg" == "RUN: "* ]]; then
      open=$'\033[2m'
    fi
    if [[ -n "$open" ]]; then
      close=$'\033[0m'
    fi
  fi
  printf '  %s%s%s%s\n' "$open" "$mark" "$msg" "$close" >&2
}

tm_log() {
  local level="$1"
  shift
  local msg="$*" line
  msg=${msg//$'\n'/ }
  msg=${msg//$'\r'/ }
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${level} ${msg}"
  case "$level" in
    DEBUG)
      if [[ "${TM_LOG_LEVEL:-info}" == "debug" ]]; then
        printf '%s\n' "$line" >&2
      fi
      ;;
    *)
      # Logs stay on stderr so command stdout can be captured safely.
      if [[ "${TM_MENU_FACE:-0}" == "1" ]]; then
        tm_face_print "$level" "$msg"
      else
        printf '%s\n' "$line" >&2
      fi
      ;;
  esac
  if [[ -n "${TM_LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" >>"$TM_LOG_FILE" 2>/dev/null || true
  fi
}

tm_info() { tm_log INFO "$@"; }
tm_warn() { tm_log WARN "$@"; }
tm_error() { tm_log ERROR "$@"; }
tm_debug() { tm_log DEBUG "$@"; }

tm_die() {
  tm_error "$*"
  if [[ ! -t 2 ]] && [[ -w /dev/tty ]]; then
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR $*" >/dev/tty || true
  fi
  exit 1
}

tm_have() {
  command -v "$1" >/dev/null 2>&1
}

tm_is_root() {
  [[ "$(id -u)" -eq 0 ]]
}

tm_require_root() {
  if tm_is_root; then
    return 0
  fi
  if [[ "${TM_TEST_MODE:-0}" == "1" && "${TM_ALLOW_NON_ROOT:-0}" == "1" ]]; then
    return 0
  fi
  tm_die "This operation requires root."
}

tm_require_bash() {
  if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    printf '%s\n' "Tunnel Manager requires Bash 4.4 or newer." >&2
    exit 1
  fi
}

tm_shell_quote() {
  printf '%q ' "$@"
}

# Prompts read the controlling terminal. In test mode a script can stand in
# for it: TM_TEST_TTY_FD is an open input descriptor, TM_TEST_TTY_OUT a file.
tm_tty_scripted() {
  [[ "${TM_TEST_MODE:-0}" == "1" && -n "${TM_TEST_TTY_FD:-}" ]]
}

tm_tty_ready() {
  tm_tty_scripted || [[ -r /dev/tty ]]
}

tm_tty_printf() {
  local out=/dev/tty
  if tm_tty_scripted; then
    out="${TM_TEST_TTY_OUT:-/dev/null}"
  fi
  # shellcheck disable=SC2059
  printf "$@" >>"$out"
}

tm_tty_read() {
  local -n _tm_tty_line=$1
  if tm_tty_scripted; then
    read -r -u "$TM_TEST_TTY_FD" _tm_tty_line
  else
    read -r _tm_tty_line </dev/tty
  fi
}

tm_confirm() {
  local prompt="$1"
  local reply="" lead=""
  if [[ "${TM_YES:-0}" == "1" ]]; then
    return 0
  fi
  if ! tm_tty_ready; then
    tm_error "Confirmation required but no terminal is available. Re-run with --yes to confirm."
    return 1
  fi
  if [[ "${TM_MENU_FACE:-0}" == "1" ]]; then
    lead="  "
  fi
  tm_tty_printf '%s%s [y/N] ' "$lead" "$prompt"
  tm_tty_read reply || return 1
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

tm_prompt() {
  local -n _tm_dest=$1
  local prompt="$2"
  local default="${3:-}"
  local reply="" lead=""
  if ! tm_tty_ready; then
    tm_die "A terminal is required for interactive input."
  fi
  if [[ "${TM_MENU_FACE:-0}" == "1" ]]; then
    lead="  "
  fi
  if [[ -n "$default" ]]; then
    tm_tty_printf '%s%s [%s]: ' "$lead" "$prompt" "$default"
  else
    tm_tty_printf '%s%s: ' "$lead" "$prompt"
  fi
  tm_tty_read reply || return 1
  if [[ -n "$default" ]]; then
    reply="${reply:-$default}"
  fi
  _tm_dest="$reply"
}

tm_try_enable_file_log() {
  local dir="${TM_LOG_DIR:-/var/log/tunnel-manager}"
  if mkdir -p -- "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    TM_LOG_FILE="${dir}/tunnel-manager.log"
  fi
}

tm_lock_acquire() {
  local lockdir="${TM_VAR:?}/run.lock"
  local attempt pid
  mkdir -p -- "$TM_VAR" || return 1
  if [[ -d "$lockdir" && -f "$lockdir/pid" ]]; then
    pid=$(cat "$lockdir/pid" 2>/dev/null || true)
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f -- "$lockdir/pid"
      rmdir -- "$lockdir" 2>/dev/null || true
    fi
  fi
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir -- "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" >"$lockdir/pid" || true
      return 0
    fi
    sleep 0.1
  done
  tm_error "Another Tunnel Manager operation holds the lock at ${lockdir}."
  return 1
}

tm_lock_release() {
  local lockdir="${TM_VAR:?}/run.lock"
  local pid=""
  if [[ ! -d "$lockdir" ]]; then
    return 0
  fi
  if [[ -f "$lockdir/pid" ]]; then
    pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fi
  if [[ -z "$pid" || "$pid" == "$$" ]]; then
    rm -f -- "$lockdir/pid"
    rmdir -- "$lockdir" 2>/dev/null || true
  fi
}

# Execute a logical command. Tests may point TM_BIN_OVERRIDE[name] at a fake.
declare -gA TM_BIN_OVERRIDE=()

tm_exec() {
  local name="$1"
  shift
  local bin=""
  if [[ "${TM_TEST_MODE:-0}" == "1" ]]; then
    case "$name" in
      iptables|ip6tables|nft|ip|sysctl|systemctl|modprobe|ping|ss)
        if [[ -z "${TM_BIN_OVERRIDE[$name]:-}" ]]; then
          tm_error "Test mode refuses to run the real ${name} command."
          return 127
        fi
        ;;
    esac
  fi
  if [[ -n "${TM_BIN_OVERRIDE[$name]:-}" ]]; then
    bash "${TM_BIN_OVERRIDE[$name]}" "$@"
    return $?
  fi
  if bin=$(command -v "$name" 2>/dev/null); then
    "$bin" "$@"
    return $?
  fi
  local dir
  for dir in /usr/local/sbin /usr/sbin /sbin /usr/local/bin /usr/bin /bin; do
    if [[ -x "${dir}/${name}" ]]; then
      "${dir}/${name}" "$@"
      return $?
    fi
  done
  tm_error "Required command not found: ${name}"
  return 127
}

tm_cmd_available() {
  local name="$1"
  local dir
  if [[ -n "${TM_BIN_OVERRIDE[$name]:-}" ]]; then
    return 0
  fi
  if [[ "${TM_TEST_MODE:-0}" == "1" ]]; then
    return 1
  fi
  if tm_have "$name"; then
    return 0
  fi
  for dir in /usr/local/sbin /usr/sbin /sbin /usr/local/bin /usr/bin /bin; do
    if [[ -x "${dir}/${name}" ]]; then
      return 0
    fi
  done
  return 1
}

tm_must() {
  tm_run "$@"
}

tm_noop() {
  return 0
}

tm_with_lock() {
  local status=0
  if [[ "${TM_DRY_RUN:-0}" != "1" ]]; then
    tm_lock_acquire || return 1
  fi
  set +e
  "$@"
  status=$?
  set -e
  if [[ "${TM_DRY_RUN:-0}" != "1" ]]; then
    tm_lock_release || true
  fi
  return "$status"
}

tm_run_quiet() {
  if [[ "$#" -eq 0 ]]; then
    return 1
  fi
  if ! tm_argv_is_safe "$@"; then
    tm_die "Refusing unsafe command: $(tm_shell_quote "$@")"
  fi
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  local name="$1"
  shift
  tm_exec "$name" "$@"
}

tm_run() {
  if [[ "$#" -eq 0 ]]; then
    tm_die "Refusing to run an empty command."
  fi
  if ! tm_argv_is_safe "$@"; then
    tm_die "Refusing unsafe command: $(tm_shell_quote "$@")"
  fi
  if tm_command_is_read_only "$@"; then
    tm_debug "RUN: $(tm_shell_quote "$@")"
  else
    tm_info "RUN: $(tm_shell_quote "$@")"
  fi
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  local name="$1"
  shift
  tm_exec "$name" "$@"
}
