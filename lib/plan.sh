# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034
# Tunnel Manager — dry-run plans and rollback journals.
# Undos are recorded before each step so a crash can be recovered.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '%s\n' "plan.sh is a library and must be sourced." >&2
  exit 1
fi

if [[ -n "${TM_PLAN_LOADED:-}" ]]; then
  return 0
fi
TM_PLAN_LOADED=1

TM_PLAN_DESC=()
TM_PLAN_CMD=()
TM_PLAN_UNDO=()
TM_PLAN_GRE=0

tm_plan_reset() {
  TM_PLAN_DESC=()
  TM_PLAN_CMD=()
  TM_PLAN_UNDO=()
  TM_PLAN_GRE=0
}

tm_plan_note_gre() {
  TM_PLAN_GRE=1
}

tm_journal_path() {
  printf '%s\n' "${TM_VAR}/rollback.journal"
}

tm_journal_exists() {
  local path
  path=$(tm_journal_path)
  [[ -s "$path" ]]
}

tm_journal_clear() {
  local path
  path=$(tm_journal_path)
  if [[ -f "$path" ]]; then
    tm_safe_rm "$path"
  fi
}

tm_journal_append() {
  local line="$1"
  local path dir
  path=$(tm_journal_path)
  dir=$(dirname -- "$path")
  tm_mkdir_mode "$dir" 0700
  tm_path_is_mutable "$path" || tm_die "Refusing to write the rollback journal outside managed state."
  printf '%s\n' "$line" >>"$path"
  chmod 0600 "$path" || true
}

tm_plan_eval_checked() {
  local encoded="$1"
  local -a argv=()
  tm_eval_argv "$encoded" argv
  if [[ "${#argv[@]}" -eq 0 ]]; then
    return 1
  fi
  tm_argv_is_safe "${argv[@]}" || {
    tm_error "Rollback or plan command failed the safety check: $(tm_shell_quote "${argv[@]}")"
    return 1
  }
  "${argv[@]}"
}

tm_journal_write_lines() {
  local path tmp
  local -a kept=()
  local line
  path=$(tm_journal_path)
  for line in "$@"; do
    [[ -n "$line" ]] || continue
    kept+=("$line")
  done
  if [[ "${#kept[@]}" -eq 0 ]]; then
    tm_journal_clear
    return 0
  fi
  tmp=$(mktemp "$(dirname -- "$path")/.tm.XXXXXX") || return 1
  printf '%s\n' "${kept[@]}" >"$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  chmod 0600 "$tmp" || true
  mv -f -- "$tmp" "$path"
}

tm_journal_rollback() {
  local path
  local -a lines=()
  local i cmd
  path=$(tm_journal_path)
  if [[ ! -f "$path" ]]; then
    tm_info "No rollback journal is present."
    return 0
  fi
  mapfile -t lines <"$path"
  if [[ "${#lines[@]}" -eq 0 ]]; then
    tm_journal_clear
    tm_info "Rollback journal was empty."
    return 0
  fi
  tm_warn "Rolling back ${#lines[@]} recorded step(s)."
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    cmd="${lines[$i]}"
    [[ -n "$cmd" ]] || continue
    tm_warn "Undo command $(printf '%s' $((i + 1)))."
    if ! tm_plan_eval_checked "$cmd"; then
      tm_error "A rollback command failed. The journal was kept at ${path}."
      return 1
    fi
    lines[i]=""
    tm_journal_write_lines "${lines[@]}" || {
      tm_error "Could not update the rollback journal."
      return 1
    }
  done
  tm_journal_clear
  tm_info "Rollback completed."
  return 0
}

tm_plan_add() {
  local desc="$1"
  local undo_q="$2"
  shift 2
  local cmd_q
  cmd_q=$(tm_shell_quote "$@")
  TM_PLAN_DESC+=("$desc")
  TM_PLAN_CMD+=("$cmd_q")
  TM_PLAN_UNDO+=("$undo_q")
}

tm_plan_show() {
  local i
  if [[ "${TM_PLAN_GRE:-0}" == "1" ]]; then
    tm_warn "GRE tunnels have no encryption and no authentication. Traffic can be read or modified in transit."
  fi
  if [[ "${#TM_PLAN_DESC[@]}" -eq 0 ]]; then
    tm_info "No changes planned."
    return 0
  fi
  tm_info "Planned changes (${#TM_PLAN_DESC[@]} steps):"
  for i in "${!TM_PLAN_DESC[@]}"; do
    tm_info "  $((i + 1)). ${TM_PLAN_DESC[$i]}"
  done
  tm_info "The default route is not modified."
  tm_info "Existing firewall rules are not flushed."
}

tm_plan_apply() {
  local i
  tm_plan_show
  if [[ "${#TM_PLAN_DESC[@]}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${TM_DRY_RUN:-0}" == "1" ]]; then
    if tm_journal_exists; then
      tm_warn "A rollback journal exists. Apply will refuse to run until rollback completes."
    fi
    tm_info "Dry-run only. No changes were made."
    return 0
  fi
  if tm_journal_exists; then
    tm_die "A rollback journal already exists. Run: tunnel-manager rollback"
  fi
  if [[ "${TM_PLAN_GRE:-0}" == "1" && "${TM_ALLOW_GRE:-0}" != "1" ]]; then
    tm_gre_warning_text >&2
    if ! tm_confirm_phrase "GRE is not encrypted" "Type 'GRE is not encrypted' to continue:"; then
      tm_error "GRE was not applied. The confirmation phrase did not match."
      return 2
    fi
  fi
  if ! tm_confirm "Apply these changes?"; then
    tm_info "Aborted. No changes were made."
    return 2
  fi
  for i in "${!TM_PLAN_DESC[@]}"; do
    tm_info "Applying: ${TM_PLAN_DESC[$i]}"
    tm_journal_append "${TM_PLAN_UNDO[$i]}"
    if ! tm_plan_eval_checked "${TM_PLAN_CMD[$i]}"; then
      tm_error "Step failed: ${TM_PLAN_DESC[$i]}"
      if ! tm_journal_rollback; then
        tm_error "Rollback did not finish cleanly."
        return 4
      fi
      return 4
    fi
  done
  tm_journal_clear
  tm_info "Changes applied."
  return 0
}

tm_plan_require_clear_journal() {
  if tm_journal_exists; then
    tm_die "A rollback journal exists from an interrupted operation. Run: tunnel-manager rollback"
  fi
}
