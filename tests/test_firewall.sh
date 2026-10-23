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
tm_expect_ok "first udp apply" tm_iptables_l4_apply_exec udp edge eth0 5000 10.200.0.2 5000 10.200.0.1 yes
tm_expect_ok "second udp apply" tm_iptables_l4_apply_exec udp edge eth0 5000 10.200.0.2 5000 10.200.0.1 yes
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
IFS=$'\n\t' tm_expect_ok "udp delete" tm_iptables_l4_delete_exec udp edge
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

{
  printf '%s\n' "CHAIN filter TM_FORWARD"
  printf 'RULE\tfilter\tTM_FORWARD\t%s\n' \
    '-d 10.200.0.2/32 -p udp -m udp --dport 5000 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment "tm:udp:edge:fwd" -j ACCEPT'
} >>"${TM_FAKE_ROOT}/iptables.state"
tm_expect_ok "iptables -S rule with -m udp can be deleted" \
  tm_iptables_delete_comment filter TM_FORWARD tm:udp:edge:fwd
if grep -q 'tm:udp:edge:fwd' "${TM_FAKE_ROOT}/iptables.state"; then
  tm_fail "quoted forward rule was not removed"
else
  tm_pass "quoted forward rule was removed"
fi

tm_split_saved_rule() {
  local -a spec=()
  local joined
  IFS=$'\n' tm_iptables_split_spec '-d 10.200.0.2/32 -p udp -m udp --dport 5000 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment "tm:udp:edge:fwd" -j ACCEPT' spec
  joined=$(printf '%s ' "${spec[@]}")
  [[ "$joined" == '-d 10.200.0.2/32 -p udp -m udp --dport 5000 -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment tm:udp:edge:fwd -j ACCEPT ' ]] || return 1
  tm_iptables_argv_is_safe iptables -t filter -D TM_FORWARD "${spec[@]}"
}
tm_expect_ok "saved rule splits when IFS has no space" tm_split_saved_rule

{
  printf '%s\n' "CHAIN nat TM_POSTROUTING"
  printf 'RULE\tnat\tTM_POSTROUTING\t%s\n' \
    '-d 203.0.113.31/32 -p tcp -m tcp --dport 443 -m comment --comment "tm:tcp:p443:snat" -j SNAT --to-source 203.0.113.10'
  printf 'RULE\tfilter\tTM_FORWARD\t%s\n' \
    '-s 203.0.113.31/32 -p tcp -m tcp --sport 443 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "tm:tcp:p443:fwdret" -j ACCEPT'
  printf '%s\n' "CHAIN filter TM_FORWARD"
} >>"${TM_FAKE_ROOT}/iptables.state"
tm_expect_ok "saved snat with /32 can be deleted" \
  tm_iptables_delete_comment nat TM_POSTROUTING tm:tcp:p443:snat
tm_expect_ok "saved forward return with /32 can be deleted" \
  tm_iptables_delete_comment filter TM_FORWARD tm:tcp:p443:fwdret
reply='-A TM_FORWARD -s 203.0.113.31/32 -p tcp -m tcp --sport 4444 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "tm:tcp:p4444:fwdret" -j ACCEPT'
if tm_iptables_line_has_comment "$reply" "tm:tcp:p4444:fwd"; then
  tm_fail "comment fwd matched fwdret"
else
  tm_pass "comment fwd does not match fwdret"
fi
if tm_iptables_line_has_comment "$reply" "tm:tcp:p4444:fwdret"; then
  tm_pass "comment fwdret matches exactly"
else
  tm_fail "comment fwdret was not recognized"
fi
printf 'RULE\tfilter\tTM_FORWARD\t%s\n' \
  '-s 203.0.113.31/32 -p tcp -m tcp --sport 4444 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "tm:tcp:p4444:fwdret" -j ACCEPT' \
  >>"${TM_FAKE_ROOT}/iptables.state"
tm_expect_ok "saved return rule with RELATED,ESTABLISHED can be deleted" \
  tm_iptables_delete_comment filter TM_FORWARD tm:tcp:p4444:fwdret
if grep -q '203.0.113.31/32' "${TM_FAKE_ROOT}/iptables.state"; then
  tm_fail "host /32 rules were not removed"
else
  tm_pass "host /32 rules were removed"
fi

TM_BIN_OVERRIDE[nft]="${TM_REPO}/tests/fakes/nft"
unset 'TM_BIN_OVERRIDE[iptables]'
rm -f -- "${TM_FAKE_ROOT}/nft.log" "${TM_FAKE_ROOT}/nft.state" "${TM_FAKE_ROOT}/nft.handle"
TM_FW_BACKEND=nft
tm_expect_ok "nft udp apply" tm_fw_l4_apply_exec udp edge eth0 5000 10.200.0.2 5000 10.200.0.1 yes
rules_first=$(grep -c "add rule" "${TM_FAKE_ROOT}/nft.log" || true)
tm_expect_ok "nft udp apply again" tm_fw_l4_apply_exec udp edge eth0 5000 10.200.0.2 5000 10.200.0.1 yes
rules_second=$(grep -c "add rule" "${TM_FAKE_ROOT}/nft.log" || true)
tm_expect_eq "nft rules are not duplicated" "$rules_first" "$rules_second"
tm_expect_ok "nft tcp apply" tm_fw_l4_apply_exec tcp web eth0 443 10.200.0.2 443 10.200.0.1 yes
if grep -q "tcp dport 443" "${TM_FAKE_ROOT}/nft.log"; then
  tm_pass "nft tcp DNAT uses the same table"
else
  tm_fail "nft tcp DNAT was not installed"
fi
tm_expect_ok "nft gre input allow" tm_fw_input_apply_exec edge eth0 203.0.113.20 4
if grep -q "add rule inet tunnel_manager input iifname eth0 ip saddr 203.0.113.20 meta l4proto gre accept comment tm:gre:edge:input" "${TM_FAKE_ROOT}/nft.log"; then
  tm_pass "nft gre input allow accepts the peer only"
else
  tm_fail "nft gre input allow was not installed"
fi
tm_expect_ok "nft gre input delete" tm_fw_input_delete_exec edge 4
if grep -q "tm:gre:edge:input" "${TM_FAKE_ROOT}/nft.state"; then
  tm_fail "nft gre input allow was left behind"
else
  tm_pass "nft gre input allow was removed"
fi
printf '%s\n' "table inet filter {" >"${TM_FAKE_ROOT}/nft.foreign"
printf '%s\n' "  chain input { type filter hook input priority 0; policy drop; }" >>"${TM_FAKE_ROOT}/nft.foreign"
printf '%s\n' "}" >>"${TM_FAKE_ROOT}/nft.foreign"
: >"${TM_FAKE_ROOT}/nft.log"
tm_expect_ok "nft nat still applies beside a foreign filter hook" \
  tm_fw_l4_apply_exec udp other eth0 5001 10.200.0.2 5001 10.200.0.1 yes
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
