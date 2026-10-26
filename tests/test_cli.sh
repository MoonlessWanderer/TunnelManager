#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

bin="${TM_REPO}/bin/tunnel-manager"
version=$(bash "$bin" version)
tm_expect_eq "version" "$version" "2.0.2"
bash "$bin" help >/dev/null
tm_pass "help exits successfully"

child_env=(
  "TM_TEST_MODE=1"
  "TM_ALLOW_NON_ROOT=1"
  "TM_ALLOW_NON_LINUX=1"
  "TM_ETC=${TM_ETC}"
  "TM_VAR=${TM_VAR}"
  "TM_LOG_DIR=${TM_LOG_DIR}"
  "TM_RUN=${TM_RUN}"
  "TM_SYSCTL_FILE=${TM_SYSCTL_FILE}"
  "TM_FAKE_ROOT=${TM_FAKE_ROOT}"
)
env "${child_env[@]}" bash "$bin" --dry-run init --role iran --public-ip 203.0.113.10 --wan-iface eth0
if [[ ! -f "${TM_ETC}/host.conf" ]]; then
  tm_pass "init dry-run does not write host.conf"
else
  tm_fail "init dry-run wrote host.conf"
fi

text=$(env "${child_env[@]}" bash "$bin" --dry-run tunnel create --name edge --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.200.0.1 --remote-tunnel-ip 10.200.0.2 \
  --wan-iface eth0 2>&1 || true)
if [[ "$text" == *"Dry-run"* && "$text" == *"default route is not modified"* && ! -f "${TM_ETC}/tunnels/edge.conf" ]]; then
  tm_pass "cli dry-run create prints a plan and writes nothing"
else
  tm_fail "cli dry-run create was incomplete"
fi

set +e
doctor_text=$(bash "$bin" doctor 2>&1)
doctor_status=$?
set -e
if [[ "$doctor_text" == *"[FAIL]"* && "$doctor_status" -ne 0 ]]; then
  tm_pass "doctor returns failure when it reports a failed check"
elif [[ "$doctor_text" == *"[PASS]"* && "$doctor_text" != *"[FAIL]"* && "$doctor_status" -eq 0 ]]; then
  tm_pass "doctor returns success when every check passed"
else
  tm_fail "doctor result did not match its report (status ${doctor_status})"
fi

forbidden=0
while IFS= read -r file; do
  if grep -E -n 'iptables[[:space:]]+-F|iptables[[:space:]]+--flush|nft[[:space:]]+flush|ip[[:space:]]+route[[:space:]]+(add|replace|del|delete)' "$file"; then
    forbidden=1
  fi
done < <(find "${TM_REPO}/lib" "${TM_REPO}/bin" "${TM_REPO}/install.sh" "${TM_REPO}/uninstall.sh" -type f)
if [[ "$forbidden" -eq 0 ]]; then
  tm_pass "source does not flush firewalls or edit routes"
else
  tm_fail "source contains a forbidden firewall or route command"
fi

TM_MENU_COLOR=0
TM_MENU_NOTE="No tunnels are saved."
menu_text=$(tm_menu_render "Manage Tunnels" "Back" "edge" "Maintenance")
TM_MENU_NOTE=""
if [[ "$menu_text" == *"Tunnel Manager"* && "$menu_text" == *"Manage Tunnels"* \
  && "$menu_text" == *"No tunnels are saved."* && "$menu_text" == *"1  edge"* \
  && "$menu_text" == *"2  Maintenance"* && "$menu_text" == *"0  Back"* \
  && "$menu_text" != *$'\033'* && "$menu_text" != *"2.0.2"* ]]; then
  tm_pass "menu screen is plain text when color is off"
else
  tm_fail "menu screen was not the plain layout"
fi

TM_MENU_COLOR=1
menu_color=$(tm_menu_render "" "Exit" "Configure a New Tunnel" "Enable BBR")
TM_MENU_COLOR=0
if [[ "$menu_color" == *$'\033[36m'* && "$menu_color" == *"Tunnel Manager"* \
  && "$menu_color" == *"2.0.2"* && "$menu_color" == *"Configure a New Tunnel"* \
  && "$menu_color" == *"Enable BBR"* && "$menu_color" == *"Exit"* \
  && "$menu_color" != *$'\033[31m'* && "$menu_color" != *"════"* ]]; then
  tm_pass "menu screen uses a quiet accent and the version on the main page"
else
  tm_fail "menu screen accent or main page was wrong"
fi

idx=$(tm_menu_choice_index " 1 " 5)
idx8=$(tm_menu_choice_index "08" 10)
if [[ "$idx" == "1" && "$idx8" == "8" ]] && ! tm_menu_choice_index "99" 5 && ! tm_menu_choice_index "x" 5; then
  tm_pass "menu accepts only a listed choice"
else
  tm_fail "menu choice check was wrong"
fi

face_line=$(tm_face_print INFO "Changes applied." 2>&1)
warn_line=$(tm_face_print WARN "Port 443 is already forwarded." 2>&1)
check_line=$(tm_face_print WARN "[WARN] ip_forward is off" 2>&1)
face_info=$(TM_MENU_FACE=1 tm_info "kept in the log" 2>&1)
plain_info=$(tm_info "stamped outside the menu" 2>&1)
if [[ "$face_line" == "  Changes applied." && "$warn_line" == "  ! Port 443 is already forwarded." \
  && "$check_line" == "  [WARN] ip_forward is off" && "$face_line" != *$'\033'* \
  && "$face_info" == "  kept in the log" && "$plain_info" == *"INFO stamped outside the menu"* ]] \
  && grep -q 'INFO kept in the log' "$TM_LOG_FILE"; then
  tm_pass "menu messages stay one line and the log keeps timestamps"
else
  tm_fail "menu message layout was wrong"
fi

ports_label=$(tm_setup_ports_label "443,8443=2053")
tm_expect_eq "port list reads as a sentence" "$ports_label" "443, 8443 -> 2053"

tm_plan_reset
tm_plan_add "Only step" "$(tm_shell_quote tm_noop)" tm_noop
plan_text=$(tm_plan_show 2>&1)
tm_plan_reset
if [[ "$plan_text" == *"Planned changes (1 step):"* ]]; then
  tm_pass "a one-step plan says step"
else
  tm_fail "a one-step plan was worded wrong: ${plan_text}"
fi

tm_finish
