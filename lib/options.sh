# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — shared command-line option parser.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "options.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_OPTIONS_LOADED:-}" ]]; then
  return 0
fi
TM_OPTIONS_LOADED=1

tm_opts_parse() {
  local -n _tm_parsed=$1
  shift
  local raw key
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --yes)
        _tm_parsed['yes']=1
        shift
        ;;
      --dry-run)
        _tm_parsed['dry_run']=1
        shift
        ;;
      --verbose)
        _tm_parsed['verbose']=1
        shift
        ;;
      --i-understand-no-encryption)
        # Accepted for setup commands printed by older versions.
        shift
        ;;
      --include-keys)
        _tm_parsed['include_keys']=1
        shift
        ;;
      --help|-h)
        _tm_parsed['help']=1
        shift
        ;;
      --)
        shift
        if [[ "$#" -gt 0 ]]; then
          tm_die "Unexpected argument: $1"
        fi
        ;;
      --*=*)
        tm_die "Use separate option and value arguments, not: $1"
        ;;
      --*)
        raw="${1#--}"
        key="${raw//-/_}"
        [[ "$key" =~ ^[a-z][a-z0-9_]*$ ]] || tm_die "Invalid option: $1"
        if [[ "$#" -lt 2 || "$2" == --* ]]; then
          tm_die "Missing value for $1"
        fi
        _tm_parsed["$key"]="$2"
        shift 2
        ;;
      *)
        tm_die "Unexpected argument: $1"
        ;;
    esac
  done
}

tm_opts_bind_flags() {
  local -n _tm_bound=$1
  if [[ "${_tm_bound['yes']:-0}" == "1" || "${TM_YES:-0}" == "1" ]]; then
    TM_YES=1
  else
    TM_YES=0
  fi
  if [[ "${_tm_bound['dry_run']:-0}" == "1" || "${TM_DRY_RUN:-0}" == "1" ]]; then
    TM_DRY_RUN=1
  else
    TM_DRY_RUN=0
  fi
  if [[ "${_tm_bound['verbose']:-0}" == "1" ]]; then
    TM_LOG_LEVEL=debug
  fi
}

tm_opt_get() {
  local -n _tm_chosen=$1
  local key="$2"
  local default="${3:-}"
  if [[ -n "${_tm_chosen[$key]:-}" ]]; then
    printf '%s\n' "${_tm_chosen[$key]}"
  else
    printf '%s\n' "$default"
  fi
}

tm_opt_require() {
  local -n _tm_needed=$1
  local key="$2"
  local label="$3"
  [[ -n "${_tm_needed[$key]:-}" ]] || tm_die "Missing required option --${label}."
}
