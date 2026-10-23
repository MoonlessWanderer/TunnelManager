#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

order="${TM_VAR}/order"
mkdir -p -- "$TM_VAR"
tm_step_a() { printf 'A' >>"$order"; }
tm_undo_a() { printf 'a' >>"$order"; }
tm_step_b() { printf 'B' >>"$order"; return 1; }
tm_undo_b() { printf 'b' >>"$order"; }
tm_step_marker() { printf 'ran' >"${TM_VAR}/marker"; }

TM_DRY_RUN=1
TM_YES=0
tm_plan_reset
tm_plan_add "marker" "$(tm_shell_quote tm_noop)" tm_step_marker
tm_expect_ok "dry-run apply returns success" tm_plan_apply
if [[ ! -e "${TM_VAR}/marker" && ! -s "$(tm_journal_path)" ]]; then
  tm_pass "dry-run does not run steps or write a journal"
else
  tm_fail "dry-run executed a step or wrote a journal"
fi

TM_DRY_RUN=0
TM_YES=1
: >"$order"
tm_plan_reset
tm_plan_add "step A" "$(tm_shell_quote tm_undo_a)" tm_step_a
tm_plan_add "step B" "$(tm_shell_quote tm_undo_b)" tm_step_b
status=0
tm_plan_apply || status=$?
tm_expect_eq "failed plan returns rollback status" "$status" "4"
tm_expect_eq "rollback order is ABba" "$(cat "$order")" "ABba"
if tm_journal_exists; then
  tm_fail "successful rollback left a journal"
else
  tm_pass "successful rollback clears the journal"
fi

tm_finish
