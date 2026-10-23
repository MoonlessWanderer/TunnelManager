#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

bin="${TM_REPO}/bin/tunnel-manager"
version=$(bash "$bin" version)
tm_expect_eq "version" "$version" "1.3.1"
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
  "TM_WG_DIR=${TM_WG_DIR}"
  "TM_SYSCTL_FILE=${TM_SYSCTL_FILE}"
  "TM_FAKE_ROOT=${TM_FAKE_ROOT}"
)
env "${child_env[@]}" bash "$bin" --dry-run init --role iran --public-ip 203.0.113.10 --wan-iface eth0
if [[ ! -f "${TM_ETC}/host.conf" ]]; then
  tm_pass "init dry-run does not write host.conf"
else
  tm_fail "init dry-run wrote host.conf"
fi

text=$(env "${child_env[@]}" bash "$bin" --dry-run tunnel create --name edge --type wireguard \
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

tm_finish
