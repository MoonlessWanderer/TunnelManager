#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

TM_YES=1
TM_FW_BACKEND=iptables
unset 'TM_BIN_OVERRIDE[nft]'
unset 'TM_BIN_OVERRIDE[systemctl]'

tm_expect_fail "wireguard type is rejected" \
  tm_action_tunnel_create --name old --type wireguard \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.200.0.1 --remote-tunnel-ip 10.200.0.2 \
  --wan-iface eth0 --yes

tm_expect_ok "create gre tunnel" \
  tm_action_tunnel_create --name edge --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.200.0.1 --remote-tunnel-ip 10.200.0.2 \
  --wan-iface eth0 --i-understand-no-encryption --yes

if grep -q '^tm-edge$' "${TM_FAKE_ROOT}/ip.links"; then
  tm_pass "gre interface was created"
else
  tm_fail "gre interface was not created"
fi

tm_expect_fail "rp_filter is not written for a missing interface" tm_rp_filter_apply_exec tm-missing
if grep -q 'tm-missing' "${TM_FAKE_ROOT}/sysctl.log" 2>/dev/null; then
  tm_fail "sysctl ran for a missing interface"
else
  tm_pass "sysctl did not run for a missing interface"
fi
tm_expect_fail "duplicate tunnel is rejected" \
  tm_action_tunnel_create --name edge --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.200.0.1 --remote-tunnel-ip 10.200.0.2 \
  --wan-iface eth0 --i-understand-no-encryption --yes

tm_expect_fail "SSH listen port is rejected" \
  tm_action_forward_add --name bad --proto tcp --listen-port 22 \
  --dest-ip 10.200.0.2 --source-ip 10.200.0.1 --ingress-iface eth0 --yes

tm_expect_ok "add tcp forward" \
  tm_action_forward_add --name web --proto tcp --listen-port 443 \
  --dest-ip 10.200.0.2 --source-ip 10.200.0.1 --ingress-iface eth0 --snat never --yes
if grep -q -- '-p tcp --dport 443' "${TM_FAKE_ROOT}/iptables.log" \
  && grep -q -- 'tm:tcp:web:dnat' "${TM_FAKE_ROOT}/iptables.log" \
  && grep -q -- 'DNAT' "${TM_FAKE_ROOT}/iptables.log" \
  && [[ ! -f "$TM_HAPROXY_CFG" ]]; then
  tm_pass "tcp forward installed DNAT and did not start HAProxy"
else
  tm_fail "tcp forward did not use firewall NAT"
fi

tm_expect_ok "add udp forward" \
  tm_action_forward_add --name dns --proto udp --listen-port 5300 \
  --dest-ip 10.200.0.2 --source-ip 10.200.0.1 --ingress-iface eth0 --yes
if grep -q "DNAT" "${TM_FAKE_ROOT}/iptables.log" && grep -q "SNAT" "${TM_FAKE_ROOT}/iptables.log"; then
  tm_pass "udp forward installed DNAT and SNAT"
else
  tm_fail "udp forward did not install DNAT and SNAT"
fi
if [[ "$(tr -d '[:space:]' <"${TM_FAKE_ROOT}/sysctl.state" | sed -n 's/.*net.ipv4.ip_forward=//p')" == *1* ]] \
  || grep -q 'net.ipv4.ip_forward=1' "${TM_FAKE_ROOT}/sysctl.state"; then
  tm_pass "udp forward enables ip_forward"
else
  tm_fail "udp forward did not enable ip_forward"
fi

tm_expect_fail "duplicate listen port is rejected" \
  tm_action_forward_add --name dns2 --proto udp --listen-port 5300 \
  --dest-ip 10.200.0.2 --source-ip 10.200.0.1 --ingress-iface eth0 --yes

links_before=$(grep -c '^tm-edge$' "${TM_FAKE_ROOT}/ip.links" || true)
tm_plan_reset
tm_plan_add "ensure existing tunnel" "$(tm_shell_quote tm_tunnel_ensure_undo edge)" tm_tunnel_ensure_exec edge
tm_plan_add "fail after ensure" "$(tm_shell_quote tm_noop)" tm_step_fail_flow
tm_step_fail_flow() { return 1; }
status=0
tm_plan_apply || status=$?
tm_expect_eq "ensure rollback status" "$status" "4"
links_after=$(grep -c '^tm-edge$' "${TM_FAKE_ROOT}/ip.links" || true)
tm_expect_eq "existing tunnel stays up after rollback" "$links_before" "$links_after"

out="${TM_VAR}/peer-edge.conf"
tm_expect_ok "export peer bundle" tm_action_tunnel_export --name edge --output "$out" --yes
if grep -q "TM_PEER_PUBLIC_IP=203.0.113.10" "$out" && ! grep -q "$TM_TEST_PRIV" "$out"; then
  tm_pass "peer export contains the public address and no private key"
else
  tm_fail "peer export was incomplete"
fi

text=$(TM_DRY_RUN=1 tm_action_tunnel_create --name gre1 --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.200.0.5 --remote-tunnel-ip 10.200.0.6 \
  --wan-iface eth0 --dry-run 2>&1 || true)
if [[ "$text" == *"no encryption"* && "$text" == *"default route is not modified"* && "$text" == *"not flushed"* && "$text" == *"Dry-run"* ]]; then
  tm_pass "GRE dry-run shows the warning and the plan"
else
  tm_fail "GRE dry-run output was incomplete: ${text}"
fi
if [[ ! -f "${TM_ETC}/tunnels/gre1.conf" ]]; then
  tm_pass "GRE dry-run did not write state"
else
  tm_fail "GRE dry-run wrote state"
fi

tm_expect_fail "udp ipv6 forward is rejected" \
  tm_action_forward_add --name v6dns --proto udp --listen-port 5301 \
  --dest-ip 2001:db8:1::2 --source-ip 2001:db8:1::1 --ingress-iface eth0 --yes
tm_expect_fail "tcp ipv6 forward is rejected" \
  tm_action_forward_add --name v6web --proto tcp --listen-port 4430 \
  --dest-ip 2001:db8:1::2 --source-ip 2001:db8:1::1 --ingress-iface eth0 --yes
text6=$(TM_DRY_RUN=1 tm_action_tunnel_create --name gre6 --type gre \
  --local-public-ip 2001:db8::11 --remote-public-ip 2001:db8::21 \
  --local-tunnel-ip 2001:db8:3::1 --remote-tunnel-ip 2001:db8:3::2 \
  --wan-iface eth0 --dry-run 2>&1 || true)
if [[ "$text6" == *"ip6gre"* && "$text6" == *"no encryption"* && ! -f "${TM_ETC}/tunnels/gre6.conf" ]]; then
  tm_pass "ipv6 GRE dry-run names ip6gre and does not write state"
else
  tm_fail "ipv6 GRE dry-run was incomplete"
fi

tm_expect_fail "removed peer command is rejected" \
  tm_action_tunnel_set_peer --name edge --peer-public-key "$TM_TEST_PUB" --yes
tm_expect_ok "tcp forward takes addresses from the tunnel" \
  tm_action_forward_add --name auto --proto tcp --listen-port 9443 --tunnel edge --yes
if grep -q -- '-i eth0 -p tcp --dport 9443' "${TM_FAKE_ROOT}/iptables.log" \
  && grep -q -- '--to-destination 10.200.0.2:9443' "${TM_FAKE_ROOT}/iptables.log" \
  && grep -q -- '--to-source 10.200.0.1' "${TM_FAKE_ROOT}/iptables.log"; then
  tm_pass "tunnel forward filled destination, source, and ingress"
else
  tm_fail "tunnel forward did not use the saved tunnel"
fi

printf 'net.ipv4.ip_forward = 1\n' >"$TM_BBR_FILE"
tm_expect_fail "foreign bbr file is refused" tm_action_bbr_enable --yes
rm -f -- "$TM_BBR_FILE"
tm_expect_ok "enable bbr" tm_action_bbr_enable --yes
if grep -q 'net.core.default_qdisc = fq' "$TM_BBR_FILE" \
  && grep -q 'net.ipv4.tcp_congestion_control = bbr' "$TM_BBR_FILE" \
  && grep -q 'net.core.default_qdisc=fq' "${TM_FAKE_ROOT}/sysctl.state" \
  && grep -q 'net.ipv4.tcp_congestion_control=bbr' "${TM_FAKE_ROOT}/sysctl.state" \
  && grep -q 'tcp_bbr' "${TM_FAKE_ROOT}/modprobe.log"; then
  tm_pass "bbr enables fq and bbr only"
else
  tm_fail "bbr did not enable the expected settings"
fi
tm_expect_ok "bbr stays enabled" tm_action_bbr_enable --yes

printf '%s\n' 'eth0 203.0.113.31/32' >>"${TM_FAKE_ROOT}/ip.addrs"
set +e
quick_text=$(tm_action_quick --dry-run --i-understand-no-encryption --token \
  'v1:gre:link:203.0.113.10:203.0.113.31:10.200.0.1:10.200.0.2:30' 2>&1)
set -e
TM_DRY_RUN=0
TM_ALLOW_GRE=0
if [[ "$quick_text" == *"Dry-run"* && "$quick_text" == *"Start gre"* ]] \
  && [[ ! -f "${TM_ETC}/tunnels/link.conf" ]]; then
  tm_pass "foreign quick dry-run plans GRE and writes nothing"
else
  tm_fail "foreign quick dry-run was incomplete: ${quick_text}"
fi
set +e
forward_text=$(tm_action_quick --token \
  'v1:forward:fwd:203.0.113.10:203.0.113.31:203.0.113.10:203.0.113.31:32' 2>&1)
set -e
if [[ "$forward_text" == *"No tunnel is created"* ]]; then
  tm_pass "plain forward needs no foreign tunnel"
else
  tm_fail "plain forward quick did not explain itself: ${forward_text}"
fi
tm_expect_fail "bad setup command is rejected" tm_action_quick --token 'not-a-setup'

tm_finish
