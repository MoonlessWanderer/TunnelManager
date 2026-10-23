#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

warning=$(tm_gre_warning_text)
if [[ "$warning" == *"no encryption"* && "$warning" == *"no authentication"* ]]; then
  tm_pass "GRE warning states there is no encryption"
else
  tm_fail "GRE warning is incomplete"
fi

unit=$(tm_render_unit "${TM_REPO}/systemd/tunnel-manager-apply.service.in")
if [[ "$unit" == *"apply --yes"* && "$unit" == *"down --yes"* ]]; then
  tm_pass "apply unit starts saved state and stops on shutdown"
else
  tm_fail "apply unit is incomplete"
fi

tm_finish
