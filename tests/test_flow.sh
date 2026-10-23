#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

TM_YES=1
TM_FW_BACKEND=iptables
unset 'TM_BIN_OVERRIDE[nft]'
unset 'TM_BIN_OVERRIDE[systemctl]'

tm_expect_ok "create wireguard tunnel" \
  tm_action_tunnel_create --name edge --type wireguard \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.200.0.1 --remote-tunnel-ip 10.200.0.2 \
  --wan-iface eth0 --peer-public-key "$TM_TEST_PUB" --yes

if grep -q '^tm-edge$' "${TM_FAKE_ROOT}/ip.links"; then
  tm_pass "wireguard interface was created"
else
  tm_fail "wireguard interface was not created"
fi
conf="${TM_WG_DIR}/tm-edge.conf"
tm_expect_ok "generated wireguard config is safe" tm_wg_assert_conf_safe "$conf"
if grep -q "$TM_TEST_PRIV" "$TM_LOG_FILE"; then
  tm_fail "private key was written to the log"
else
  tm_pass "private key is absent from the log"
fi
mode=$(stat -c '%a' "$(tm_key_file edge)" 2>/dev/null || stat -f '%OLp' "$(tm_key_file edge)")
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    printf 'SKIP private key mode 0600 is not observable on %s (stat reported %s).\n' "$(uname -s)" "$mode"
    ;;
  *)
    tm_expect_eq "private key mode is 0600" "$mode" "600"
    ;;
esac

tm_expect_fail "duplicate tunnel is rejected" \
  tm_action_tunnel_create --name edge --type wireguard \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.200.0.1 --remote-tunnel-ip 10.200.0.2 \
  --wan-iface eth0 --peer-public-key "$TM_TEST_PUB" --yes

tm_expect_fail "SSH listen port is rejected" \
  tm_action_forward_add --name bad --proto tcp --listen-port 22 \
  --dest-ip 10.200.0.2 --source-ip 10.200.0.1 --ingress-iface eth0 --yes

tm_expect_ok "add tcp forward" \
  tm_action_forward_add --name web --proto tcp --listen-port 443 \
  --dest-ip 10.200.0.2 --source-ip 10.200.0.1 --ingress-iface eth0 --snat never --yes
if grep -q "frontend tm_web_fe" "$TM_HAPROXY_CFG"; then
  tm_pass "tcp forward rendered a haproxy frontend"
else
  tm_fail "tcp forward did not render haproxy"
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
if grep -q "TM_PEER_PUBLIC_KEY=${TM_TEST_PUB}" "$out" && ! grep -q "$TM_TEST_PRIV" "$out"; then
  tm_pass "peer export contains only the public key"
else
  tm_fail "peer export leaked or omitted a key"
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

tm_expect_ok "create ipv6 wireguard tunnel" \
  tm_action_tunnel_create --name edge6 --type wireguard \
  --local-public-ip 2001:db8::10 --remote-public-ip 2001:db8::20 \
  --local-tunnel-ip 2001:db8:1::1 --remote-tunnel-ip 2001:db8:1::2 \
  --wan-iface eth0 --peer-public-key "$TM_TEST_PUB" --yes
conf6="${TM_WG_DIR}/tm-edge6.conf"
if grep -q 'AllowedIPs = 2001:db8:1::2/128' "$conf6" \
  && grep -q 'Endpoint = \[2001:db8::20\]:51820' "$conf6" \
  && grep -q 'Table = off' "$conf6" \
  && ! grep -q '::/0' "$conf6"; then
  tm_pass "ipv6 wireguard config is a host route"
else
  tm_fail "ipv6 wireguard config was not constrained"
fi
if [[ -f "${TM_FAKE_ROOT}/ip6tables.log" ]] && grep -q -- '--dport 51820' "${TM_FAKE_ROOT}/ip6tables.log" \
  && ! grep -q -- '-F' "${TM_FAKE_ROOT}/ip6tables.log"; then
  tm_pass "ipv6 endpoint is allowed through ip6tables"
else
  tm_fail "ipv6 endpoint did not install an ip6tables input rule"
fi
tm_expect_fail "udp ipv6 forward is rejected" \
  tm_action_forward_add --name v6dns --proto udp --listen-port 5301 \
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

printf '%s\n' "frontend tm_boom_fe" >"${TM_FAKE_ROOT}/haproxy.reject-if"
status=0
tm_action_forward_add --name boom --proto tcp --listen-port 8443 \
  --dest-ip 10.200.0.2 --source-ip 10.200.0.1 --ingress-iface eth0 --snat never --yes || status=$?
rm -f -- "${TM_FAKE_ROOT}/haproxy.reject-if"
tm_expect_eq "rejected haproxy forward rolls back" "$status" "4"
if [[ ! -f "${TM_ETC}/forwards/boom.conf" && ! -f "$(tm_journal_path)" ]] \
  && grep -q "frontend tm_web_fe" "$TM_HAPROXY_CFG" \
  && ! grep -q "frontend tm_boom_fe" "$TM_HAPROXY_CFG"; then
  tm_pass "failed tcp forward left the previous HAProxy config in place"
else
  tm_fail "failed tcp forward did not restore HAProxy state"
fi

tm_finish
