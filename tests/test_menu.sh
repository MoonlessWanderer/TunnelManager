#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

MENU_STATUS=0
MENU_SCREEN=""
MENU_OUT=""
MENU_ERR=""

menu_reset() {
  tm_test_reset
  TM_FW_BACKEND=iptables
  unset 'TM_BIN_OVERRIDE[nft]'
  unset SSH_CONNECTION
  export TM_SYSTEMD_DIR="${TM_TEST_ROOT}/etc/systemd/system"
  printf '%s\n' 'eth0 203.0.113.10/32' 'eth0 203.0.113.20/32' >"${TM_FAKE_ROOT}/ip.addrs"
  MENU_SCREEN="${TM_TEST_ROOT}/menu.screen"
  MENU_OUT="${TM_TEST_ROOT}/menu.out"
  MENU_ERR="${TM_TEST_ROOT}/menu.err"
}

# Runs the menu with scripted keyboard input, one answer per line.
menu_drive() {
  local feed="${TM_TEST_ROOT}/menu.in"
  local fd
  printf '%s' "$1" >"$feed"
  : >"$MENU_SCREEN"
  exec {fd}<"$feed"
  TM_TEST_TTY_FD="$fd"
  TM_TEST_TTY_OUT="$MENU_SCREEN"
  set +e
  (
    set -euo pipefail
    tm_menu
  ) >"$MENU_OUT" 2>"$MENU_ERR"
  MENU_STATUS=$?
  set -e
  exec {fd}<&-
  TM_TEST_TTY_FD=""
}

menu_reset

menu_drive $'9\n0\n'
if [[ "$MENU_STATUS" -eq 0 ]] && grep -q '! Enter a number from the list.' "$MENU_SCREEN" \
  && grep -q 'Goodbye.' "$MENU_ERR"; then
  tm_pass "an unknown choice is explained on the same screen"
else
  tm_fail "unknown choice handling was wrong (status ${MENU_STATUS})"
fi

menu_drive $'2\n0\n0\n'
if [[ "$MENU_STATUS" -eq 0 ]] && grep -q 'No tunnels are saved.' "$MENU_SCREEN"; then
  tm_pass "manage says when no tunnels are saved"
else
  tm_fail "manage did not explain the empty list (status ${MENU_STATUS})"
fi

menu_drive $'1\n2\nhello\nv2:gre:x:203.0.113.10:203.0.113.10:10.200.0.1:10.200.0.2:30:180879360\n\n0\n0\n'
prompts=$(grep -c 'Enter your choice' "$MENU_SCREEN" || true)
if [[ "$MENU_STATUS" -eq 0 && "$prompts" -eq 4 ]] \
  && grep -q 'That text does not contain a setup command.' "$MENU_ERR" \
  && grep -q 'The setup command is invalid.' "$MENU_ERR"; then
  tm_pass "a bad foreign paste asks again and keeps the menu open"
else
  tm_fail "bad foreign paste handling was wrong (status ${MENU_STATUS}, prompts ${prompts})"
fi

menu_drive $'1\n1\n203.0.113.10\n203.0.113.20\n1\n443\n\nn\n0\n0\n'
if [[ "$MENU_STATUS" -eq 0 ]] && grep -q 'Setup was not started.' "$MENU_SCREEN" \
  && [[ -z "$(tm_list_tunnels)" && -z "$(tm_list_forwards)" ]]; then
  tm_pass "a declined setup is reported on the next screen and saves nothing"
else
  tm_fail "declined setup handling was wrong (status ${MENU_STATUS})"
fi

menu_drive $'1\n1\n203.0.113.10\n203.0.113.20\n2\n10.200.0.1\n10.200.0.1\n\n\n10.200.0.2\n\n443\n\ny\n\n0\n2\n1\n1\n\n0\n0\n0\n'
unit_file="${TM_SYSTEMD_DIR}/tunnel-manager-apply.service"
if [[ "$MENU_STATUS" -eq 0 && -f "$(tm_tunnel_file edge)" && -f "$(tm_forward_file p443)" ]]; then
  tm_pass "iran menu setup saves the GRE tunnel and its port"
else
  tm_fail "iran menu setup did not finish (status ${MENU_STATUS}): $(tail -n 5 "$MENU_ERR")"
fi
if grep -q 'Use two different IPv4 hosts' "$MENU_ERR" \
  && grep -q 'TM_REMOTE_TUNNEL_IP=10.200.0.2' "$(tm_tunnel_file edge)"; then
  tm_pass "an invalid tunnel address pair is asked again"
else
  tm_fail "the tunnel address pair was not asked again"
fi
if [[ -f "${TM_FAKE_ROOT}/systemctl.enabled" && -f "$unit_file" ]] \
  && grep -q 'enable --quiet tunnel-manager-apply.service' "${TM_FAKE_ROOT}/systemctl.log" \
  && grep -q 'apply --yes' "$unit_file" && grep -q 'After reboot' "$MENU_SCREEN"; then
  tm_pass "setup turns on restore after reboot and says so before applying"
else
  tm_fail "setup did not enable restore after reboot"
fi
if grep -q 'sudo tunnel-manager quick v2:gre:edge:203.0.113.10:203.0.113.20:10.200.0.1:10.200.0.2:30:180879360' "$MENU_OUT"; then
  tm_pass "iran setup prints the foreign command"
else
  tm_fail "iran setup did not print the foreign command"
fi
if grep -q 'tcp 443 -> 443' "$MENU_SCREEN" && grep -q 'Interface' "$MENU_SCREEN"; then
  tm_pass "tunnel details list the saved port"
else
  tm_fail "tunnel details were incomplete"
fi

read -r next_local next_remote <<<"$(tm_setup_suggest_inner 203.0.113.10 203.0.113.30)"
next_key=$(tm_gre_key_for "$next_local" 30)
menu_drive $'1\n1\n203.0.113.10\n203.0.113.30\n2\n\n\n\n2053\n\ny\n\n0\n2\n0\n0\n'
if [[ "$MENU_STATUS" -eq 0 && -f "$(tm_tunnel_file edge2)" && -f "$(tm_forward_file p2053)" ]] \
  && grep -q "TM_LOCAL_TUNNEL_IP=${next_local}$" "$(tm_tunnel_file edge2)" \
  && ! tm_ip_subnets_overlap "$next_local" 30 10.200.0.1 30 \
  && grep -q "quick v2:gre:edge2:203.0.113.10:203.0.113.30:${next_local}:${next_remote}:30:${next_key}" "$MENU_OUT"; then
  tm_pass "a second GRE tunnel gets its own inner subnet by default"
else
  tm_fail "the second GRE tunnel did not get a free subnet (status ${MENU_STATUS}): $(tail -n 5 "$MENU_ERR")"
fi

menu_drive $'1\n1\n203.0.113.10\n203.0.113.20\n2\n\n\n\n2083\n\ny\n\n0\n2\n0\n0\n'
key_one=$(sed -n 's/^TM_GRE_KEY=//p' "$(tm_tunnel_file edge)")
key_three=$(sed -n 's/^TM_GRE_KEY=//p' "$(tm_tunnel_file edge3)" 2>/dev/null || true)
if [[ "$MENU_STATUS" -eq 0 && -f "$(tm_forward_file p2083)" ]] \
  && grep -q 'TM_REMOTE_PUBLIC_IP=203.0.113.20' "$(tm_tunnel_file edge3)" \
  && [[ -n "$key_three" && "$key_three" != "$key_one" ]] \
  && grep -q 'Already connected to 203.0.113.20 by edge.' "$MENU_SCREEN" \
  && grep -q "quick v2:gre:edge3:203.0.113.10:203.0.113.20:.*:30:${key_three}" "$MENU_OUT"; then
  tm_pass "a second tunnel to the same foreign server gets its own subnet and GRE key"
else
  tm_fail "a second tunnel to the same foreign server was not set up (status ${MENU_STATUS}): $(tail -n 5 "$MENU_ERR")"
fi
if grep -Eq 'edge +GRE -> 203\.0\.113\.20' "$MENU_SCREEN" \
  && grep -Eq 'edge2 +GRE -> 203\.0\.113\.30' "$MENU_SCREEN" \
  && grep -Eq 'edge3 +GRE -> 203\.0\.113\.20' "$MENU_SCREEN"; then
  tm_pass "manage shows the type and foreign server of each tunnel"
else
  tm_fail "manage did not label the tunnels"
fi

printf '%s\n' 'gre1 10.210.0.1/30' >>"${TM_FAKE_ROOT}/ip.addrs"
menu_drive $'1\n1\n203.0.113.10\n203.0.113.40\n2\n10.210.0.2\n10.210.0.1\n\n\n\n\n\ny\n\n0\n0\n'
if [[ "$MENU_STATUS" -eq 0 && -f "$(tm_tunnel_file edge4)" ]] \
  && ! grep -q 'TM_LOCAL_TUNNEL_IP=10.210.' "$(tm_tunnel_file edge4)" \
  && grep -q 'gre1 already uses 10.210.0.1/30. Press Enter for a free pair.' "$MENU_ERR"; then
  tm_pass "a subnet that another tool uses is explained and Enter takes a free pair"
else
  tm_fail "the interface clash in the menu was not handled (status ${MENU_STATUS}): $(tail -n 5 "$MENU_ERR")"
fi

menu_reset
menu_drive $'1\n2\nsudo tunnel-manager quick v2:gre:edge:203.0.113.10:203.0.113.20:10.200.0.1:10.200.0.2:30:180879360\ny\n\n0\n0\n'
if [[ "$MENU_STATUS" -eq 0 && -f "$(tm_tunnel_file edge)" && -f "${TM_FAKE_ROOT}/systemctl.enabled" ]] \
  && grep -q 'TM_LOCAL_TUNNEL_IP=10.200.0.2' "$(tm_tunnel_file edge)" \
  && grep -q 'TM_GRE_KEY=180879360' "$(tm_tunnel_file edge)" \
  && grep -Eq 'GRE key +180879360' "$MENU_SCREEN"; then
  tm_pass "foreign menu setup creates the GRE side and restores it after reboot"
else
  tm_fail "foreign menu setup did not finish (status ${MENU_STATUS}): $(tail -n 5 "$MENU_ERR")"
fi

menu_drive $'1\n2\nv2:gre:edge:203.0.113.10:203.0.113.20:10.200.0.1:10.200.0.2:30:180879360\n0\n0\n'
if [[ "$MENU_STATUS" -eq 0 && ! -f "$(tm_tunnel_file edge2)" ]] \
  && grep -q 'This GRE tunnel is already set up here as edge.' "$MENU_SCREEN"; then
  tm_pass "pasting the same setup command twice is explained"
else
  tm_fail "a repeated setup command was not explained (status ${MENU_STATUS})"
fi

menu_drive $'1\n2\nv1:gre:x:203.0.113.10:203.0.113.20:10.200.0.1:10.200.0.2:30\n\n0\n0\n'
if [[ "$MENU_STATUS" -eq 0 ]] && grep -q 'comes from a different Tunnel Manager version' "$MENU_ERR"; then
  tm_pass "a setup command from another version asks to update both servers"
else
  tm_fail "an old setup command was not explained (status ${MENU_STATUS})"
fi

menu_drive $'1\n2\nsudo tunnel-manager quick v2:gre:edge:203.0.113.11:203.0.113.20:10.200.7.1:10.200.7.2:30:180881152\ny\n\n0\n0\n'
if [[ "$MENU_STATUS" -eq 0 && -f "$(tm_tunnel_file edge2)" ]] \
  && grep -q 'TM_REMOTE_PUBLIC_IP=203.0.113.11' "$(tm_tunnel_file edge2)" \
  && grep -Eq 'Name.* edge2$' "$MENU_SCREEN"; then
  tm_pass "a second Iran server with the same name is shown and saved as edge2"
else
  tm_fail "the second Iran server was not set up (status ${MENU_STATUS}): $(tail -n 5 "$MENU_ERR")"
fi

menu_drive $'1\n2\nv2:gre:edge:203.0.113.12:203.0.113.20:10.200.0.5:10.200.0.6:24:180879360\n0\n0\n'
if [[ "$MENU_STATUS" -eq 0 && ! -f "$(tm_tunnel_file edge3)" ]] \
  && grep -q 'already used here by tunnel edge' "$MENU_SCREEN"; then
  tm_pass "an overlapping inner subnet is explained before anything is applied"
else
  tm_fail "the foreign overlap was not explained (status ${MENU_STATUS})"
fi

if (
  unset TM_SYSTEMD_DIR
  tm_systemd_dir_ok
); then
  tm_fail "test mode accepted the real systemd directory"
else
  tm_pass "test mode never writes units to the real systemd directory"
fi

tm_finish
