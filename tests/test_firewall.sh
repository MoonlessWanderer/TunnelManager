#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

tm_expect_eq "nf_tables selects iptables" "$(tm_fw_classify "iptables v1.8.9 (nf_tables)" 1)" "iptables"
tm_expect_eq "legacy plus nft is a conflict" "$(tm_fw_classify "iptables v1.8.7 (legacy)" 1)" "conflict-possible"
tm_expect_eq "nft only" "$(tm_fw_classify "" 1)" "nft"
tm_expect_fail "auto cannot mix two active backends" tm_fw_resolve_conflict yes yes auto
tm_expect_eq "pin selects iptables" "$(tm_fw_resolve_conflict yes yes iptables)" "iptables"
tm_expect_eq "auto snat for a peer" "$(tm_fw_snat_decision auto 10.200.0.2 10.200.0.1 10.200.0.2)" "yes"
tm_expect_eq "auto skips snat for the local tunnel address" "$(tm_fw_snat_decision auto 10.200.0.1 10.200.0.1 10.200.0.2)" "no"

printf '%s\n' "iptables v1.8.7 (legacy)" >"${TM_FAKE_ROOT}/iptables.version"
printf '%s\n' "-A INPUT -p tcp --dport 22 -j ACCEPT" >"${TM_FAKE_ROOT}/iptables.user-rules"
printf '%s\n' "table inet filter { chain input { type filter hook input priority 0; policy drop; } }" >"${TM_FAKE_ROOT}/nft.foreign"
if TM_FW_BACKEND=auto tm_fw_active_backend >/dev/null; then
  tm_fail "active backend mixed two rule sets"
else
  tm_pass "active backend refuses to mix legacy iptables and nft"
fi
tm_expect_eq "pinned backend is honored" "$(TM_FW_BACKEND=iptables tm_fw_active_backend)" "iptables"

rm -f -- "${TM_FAKE_ROOT}/iptables.version" "${TM_FAKE_ROOT}/iptables.user-rules" "${TM_FAKE_ROOT}/nft.foreign" \
  "${TM_FAKE_ROOT}/iptables.log" "${TM_FAKE_ROOT}/iptables.state" "${TM_FAKE_ROOT}/nft.log" "${TM_FAKE_ROOT}/nft.state"
unset 'TM_BIN_OVERRIDE[nft]'
TM_FW_BACKEND=iptables
tm_expect_ok "first udp apply" tm_iptables_udp_apply_exec edge eth0 5000 10.200.0.2 5000 10.200.0.1 yes
tm_expect_ok "second udp apply" tm_iptables_udp_apply_exec edge eth0 5000 10.200.0.2 5000 10.200.0.1 yes
appends=$(grep -c -- "-A TM_PREROUTING" "${TM_FAKE_ROOT}/iptables.log" || true)
tm_expect_eq "DNAT is not duplicated" "$appends" "1"
if grep -E '(^|[[:space:]])-F([[:space:]]|$)|--flush' "${TM_FAKE_ROOT}/iptables.log"; then
  tm_fail "iptables log contains a flush"
else
  tm_pass "iptables apply does not flush"
fi
if [[ -s "${TM_FAKE_ROOT}/nft.log" ]]; then
  tm_fail "iptables apply invoked nft"
else
  tm_pass "iptables apply does not invoke nft"
fi
tm_expect_ok "udp delete" tm_iptables_udp_delete_exec edge
tm_expect_ok "iptables tcp apply" tm_iptables_l4_apply_exec tcp web eth0 443 10.200.0.2 443 10.200.0.1 no
if grep -q -- '-p tcp --dport 443' "${TM_FAKE_ROOT}/iptables.log"; then
  tm_pass "iptables tcp DNAT is installed"
else
  tm_fail "iptables tcp DNAT was not installed"
fi
tm_expect_ok "tcp delete" tm_iptables_l4_delete_exec tcp web
if grep -q -- "-X TM_PREROUTING" "${TM_FAKE_ROOT}/iptables.log"; then
  tm_pass "empty chains are removed without a flush"
else
  tm_fail "empty chain was not deleted"
fi

TM_BIN_OVERRIDE[nft]="${TM_REPO}/tests/fakes/nft"
unset 'TM_BIN_OVERRIDE[iptables]'
rm -f -- "${TM_FAKE_ROOT}/nft.log" "${TM_FAKE_ROOT}/nft.state" "${TM_FAKE_ROOT}/nft.handle"
TM_FW_BACKEND=nft
tm_expect_ok "nft udp apply" tm_fw_udp_apply_exec edge eth0 5000 10.200.0.2 5000 10.200.0.1 yes
rules_first=$(grep -c "add rule" "${TM_FAKE_ROOT}/nft.log" || true)
tm_expect_ok "nft udp apply again" tm_fw_udp_apply_exec edge eth0 5000 10.200.0.2 5000 10.200.0.1 yes
rules_second=$(grep -c "add rule" "${TM_FAKE_ROOT}/nft.log" || true)
tm_expect_eq "nft rules are not duplicated" "$rules_first" "$rules_second"
tm_expect_ok "nft tcp apply" tm_fw_l4_apply_exec tcp web eth0 443 10.200.0.2 443 10.200.0.1 yes
if grep -q "tcp dport 443" "${TM_FAKE_ROOT}/nft.log"; then
  tm_pass "nft tcp DNAT uses the same table"
else
  tm_fail "nft tcp DNAT was not installed"
fi
printf '%s\n' "table inet filter {" >"${TM_FAKE_ROOT}/nft.foreign"
printf '%s\n' "  chain input { type filter hook input priority 0; policy drop; }" >>"${TM_FAKE_ROOT}/nft.foreign"
printf '%s\n' "}" >>"${TM_FAKE_ROOT}/nft.foreign"
: >"${TM_FAKE_ROOT}/nft.log"
tm_expect_ok "nft nat still applies beside a foreign filter hook" \
  tm_fw_udp_apply_exec other eth0 5001 10.200.0.2 5001 10.200.0.1 yes
if grep -q "hook forward" "${TM_FAKE_ROOT}/nft.log"; then
  tm_fail "nft added a filter forward hook beside a foreign filter"
else
  tm_pass "nft does not add a filter hook beside a foreign filter"
fi
if grep -q "add rule inet tunnel_manager prerouting" "${TM_FAKE_ROOT}/nft.log"; then
  tm_pass "nft DNAT is still installed"
else
  tm_fail "nft DNAT was skipped"
fi

tm_finish
