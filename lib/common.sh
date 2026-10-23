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

TM_VERSION="1.6.0"

tm_version() {
  printf '%s\n' "$TM_VERSION"
}

tm_redact() {
  local msg="$1"
  local redacted
  msg=${msg//$'\n'/ }
  msg=${msg//$'\r'/ }
  if ! redacted=$(printf '%s' "$msg" | sed -E 's/[A-Za-z0-9+/]{43}=/[REDACTED-KEY]/g'); then
    printf '%s\n' "$msg"
    return 0
  fi
  printf '%s\n' "$redacted"
}

tm_log() {
  local level="$1"
  shift
  local msg line
  msg=$(tm_redact "$*")
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${level} ${msg}"
  case "$level" in
    DEBUG)
      if [[ "${TM_LOG_LEVEL:-info}" == "debug" ]]; then
        printf '%s\n' "$line" >&2
      fi
      ;;
    *)
      # Logs stay on stderr so command stdout can be captured safely.
      printf '%s\n' "$line" >&2
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

tm_confirm() {
  local prompt="$1"
  local reply=""
  if [[ "${TM_YES:-0}" == "1" ]]; then
    return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    tm_error "Confirmation required but no terminal is available. Re-run with --yes to confirm."
    return 1
  fi
  read -r -p "$prompt [y/N] " reply </dev/tty || return 1
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

tm_confirm_phrase() {
  local expected="$1"
  local prompt="$2"
  local reply=""
  if [[ ! -r /dev/tty ]]; then
    tm_error "Type the confirmation phrase on a terminal, or pass the documented flag."
    return 1
  fi
  read -r -p "$prompt " reply </dev/tty || return 1
  [[ "$reply" == "$expected" ]]
}

tm_prompt() {
  local -n _tm_dest=$1
  local prompt="$2"
  local default="${3:-}"
  local reply=""
  if [[ ! -r /dev/tty ]]; then
    tm_die "A terminal is required for interactive input."
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply </dev/tty || return 1
    reply="${reply:-$default}"
  else
    read -r -p "$prompt: " reply </dev/tty || return 1
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
      iptables|ip6tables|nft|ip|sysctl|wg|wg-quick|systemctl|modprobe|haproxy|ping|ss)
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
