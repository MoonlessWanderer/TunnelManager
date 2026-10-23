#!/usr/bin/env bash
# Several tunnels on one server: distinct inner subnets, conflict checks, and
# apply, down, and delete that leave the other tunnels alone.
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

multi_reset() {
  tm_test_reset
  TM_YES=1
  TM_FW_BACKEND=iptables
  unset 'TM_BIN_OVERRIDE[nft]'
  unset 'TM_BIN_OVERRIDE[systemctl]'
  printf '%s\n' "eth0 $1/32" >"${TM_FAKE_ROOT}/ip.addrs"
}

saved() {
  sed -n "s/^$2=//p" "$(tm_tunnel_file "$1")"
}

has_link() {
  grep -qx -- "$1" "${TM_FAKE_ROOT}/ip.links" 2>/dev/null
}

has_rule() {
  grep -qF -- "$1" "${TM_FAKE_ROOT}/iptables.state" 2>/dev/null
}

ip_forward() {
  sed -n 's/^net.ipv4.ip_forward=//p' "${TM_FAKE_ROOT}/sysctl.state" | tail -n 1
}

multi_reset 203.0.113.10

tm_expect_ok "the same /30 overlaps" tm_ip_subnets_overlap 10.200.0.1 30 10.200.0.2 30
tm_expect_fail "the next /30 does not overlap" tm_ip_subnets_overlap 10.200.0.1 30 10.200.0.5 30
tm_expect_ok "a /24 overlaps a /30 inside it" tm_ip_subnets_overlap 10.200.0.9 24 10.200.0.1 30
tm_expect_fail "IPv4 and IPv6 never overlap" tm_ip_subnets_overlap 10.200.0.1 30 2001:db8::1 64
tm_expect_ok "IPv6 subnets overlap" tm_ip_subnets_overlap 2001:db8:3::1 64 2001:db8:3::5 64

first_c=$(tm_setup_suggest_inner 203.0.113.10 203.0.113.30)
tm_expect_eq "the suggestion is stable" "$(tm_setup_suggest_inner 203.0.113.10 203.0.113.30)" "$first_c"
read -r c0_local c0_remote <<<"$first_c"
if [[ "$c0_local" =~ ^10\.200\.[0-9]+\.[0-9]+$ && "$c0_local" != "$c0_remote" ]] \
  && tm_tunnel_pair_ok "$c0_local" "$c0_remote" 30; then
  tm_pass "the suggestion is a /30 pair inside 10.200.0.0/16"
else
  tm_fail "unexpected suggestion: ${first_c}"
fi
tm_expect_eq "the GRE key is the inner network as a number" "$(tm_gre_key_for 10.200.0.1 30)" "180879360"
tm_expect_eq "the GRE key is the same on both ends" "$(tm_gre_key_for 10.200.0.2 30)" "180879360"
tm_expect_fail "GRE key 0 is not allowed" tm_valid_gre_key 0
tm_expect_fail "a GRE key above 32 bits is not allowed" tm_valid_gre_key 4294967296
tm_expect_ok "a narrow host network clashes on any overlap" tm_inner_clashes_with 10.200.3.1 30 10.200.3.2 30
tm_expect_ok "a wide host network clashes when its address is inside our subnet" \
  tm_inner_clashes_with 10.200.3.2 8 10.200.3.1 30
tm_expect_fail "a wide host network elsewhere does not block a /30 inside it" \
  tm_inner_clashes_with 10.0.0.5 8 10.200.3.1 30

printf 'eth1 %s/24\n' "$c0_local" >>"${TM_FAKE_ROOT}/ip.addrs"
read -r host_local _ <<<"$(tm_setup_suggest_inner 203.0.113.10 203.0.113.30)"
tm_expect_fail "the suggestion avoids networks already on this server" \
  tm_ip_subnets_overlap "$host_local" 30 "$c0_local" 24
printf '%s\n' "eth0 203.0.113.10/32" >"${TM_FAKE_ROOT}/ip.addrs"

tm_expect_ok "first GRE tunnel takes the subnet another pair would get" \
  tm_setup_apply_iran edge gre 203.0.113.10 203.0.113.20 "$c0_local" "$c0_remote" 30 eth0 22 443
read -r c_local c_remote <<<"$(tm_setup_suggest_inner 203.0.113.10 203.0.113.30)"
if [[ "$c_local" != "$c0_local" ]] && ! tm_ip_subnets_overlap "$c_local" 30 "$c0_local" 30; then
  tm_pass "the suggestion skips a subnet that a saved tunnel uses"
else
  tm_fail "the suggestion reused ${c0_local}/30"
fi
tm_expect_ok "second GRE tunnel to another foreign server" \
  tm_setup_apply_iran edge2 gre 203.0.113.10 203.0.113.30 "$c_local" "$c_remote" 30 eth0 22 2053

if has_link tm-edge && has_link tm-edge2 \
  && has_rule 'tm:gre:edge:input' && has_rule 'tm:gre:edge2:input' \
  && has_rule "--to-destination ${c0_remote}:443" && has_rule "--to-destination ${c_remote}:2053"; then
  tm_pass "each tunnel has its own interface, GRE allow, and port forward"
else
  tm_fail "two tunnels did not get separate runtime state"
fi

tm_expect_ok "a second GRE tunnel to the same foreign server" \
  tm_setup_apply_iran edge3 gre 203.0.113.10 203.0.113.20 10.201.0.1 10.201.0.2 30 eth0 22 8443
key_one=$(saved edge TM_GRE_KEY)
key_three=$(saved edge3 TM_GRE_KEY)
if has_link tm-edge3 && [[ -n "$key_three" && "$key_three" != "$key_one" ]] \
  && grep -q "type gre local 203.0.113.10 remote 203.0.113.20 ttl 255 key ${key_three}$" "${TM_FAKE_ROOT}/ip.log" \
  && has_rule 'tm:tcp:p8443:dnat'; then
  tm_pass "two tunnels between the same servers get different GRE keys"
else
  tm_fail "the second tunnel between the same servers was not separate"
fi
tm_expect_eq "a pair lookup with a key finds that tunnel" \
  "$(tm_tunnel_pair_owner 203.0.113.10 203.0.113.20 "$key_three" || true)" "edge3"
tm_expect_fail "a pair lookup without a key ignores keyed tunnels" \
  tm_tunnel_pair_owner 203.0.113.10 203.0.113.20
dup_text=""
if tm_capture dup_text tm_action_tunnel_create --name edge4 --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.20 \
  --local-tunnel-ip 10.202.0.1 --remote-tunnel-ip 10.202.0.2 --key "$key_one" --wan-iface eth0 --yes; then
  tm_fail "a GRE tunnel with the same servers and key was created"
elif [[ "$dup_text" == *"already connects 203.0.113.10 and 203.0.113.20 with the same key"* \
  && ! -f "$(tm_tunnel_file edge4)" ]]; then
  tm_pass "the same servers with the same GRE key are refused"
else
  tm_fail "the duplicate key was not explained: ${dup_text}"
fi
if has_rule '-i eth0 -s 203.0.113.20 -p gre -m comment --comment tm:gre:edge:input' \
  && has_rule '-i eth0 -s 203.0.113.30 -p gre -m comment --comment tm:gre:edge2:input'; then
  tm_pass "each GRE allow accepts its own foreign server only"
else
  tm_fail "a GRE allow is not limited to its peer"
fi

e_local=$(saved edge TM_LOCAL_TUNNEL_IP)
e_remote=$(saved edge TM_REMOTE_TUNNEL_IP)
overlap_text=""
if tm_capture overlap_text tm_action_tunnel_create --name edge4 --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.40 \
  --local-tunnel-ip "$e_remote" --remote-tunnel-ip "$e_local" --wan-iface eth0 --yes; then
  tm_fail "a tunnel with an overlapping inner subnet was created"
elif [[ "$overlap_text" == *"overlaps tunnel edge"* && ! -f "$(tm_tunnel_file edge4)" ]]; then
  tm_pass "an inner subnet that overlaps another tunnel is refused"
else
  tm_fail "the overlap was not explained: ${overlap_text}"
fi
octet=${e_local#10.200.}
octet=${octet%%.*}
tm_expect_fail "a wider prefix around another tunnel is refused" \
  tm_action_tunnel_create --name edge4 --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.40 \
  --local-tunnel-ip "10.200.${octet}.9" --remote-tunnel-ip "10.200.${octet}.10" \
  --cidr 24 --wan-iface eth0 --yes

printf '%s\n' "gre1 10.210.0.1/30" >>"${TM_FAKE_ROOT}/ip.addrs"
host_text=""
if tm_capture host_text tm_action_tunnel_create --name edge4 --type gre \
  --local-public-ip 203.0.113.10 --remote-public-ip 203.0.113.40 \
  --local-tunnel-ip 10.210.0.2 --remote-tunnel-ip 10.210.0.1 --wan-iface eth0 --yes; then
  tm_fail "a subnet that another tool's interface uses was accepted"
elif [[ "$host_text" == *"clashes with 10.210.0.1/30 on gre1"* && ! -f "$(tm_tunnel_file edge4)" ]]; then
  tm_pass "a subnet that another tool's interface uses is refused"
else
  tm_fail "the interface clash was not explained: ${host_text}"
fi

printf '%s\n' "tcp 0.0.0.0:8080" "tcp 127.0.0.1:8081" >"${TM_FAKE_ROOT}/ss.listen"
port_text=""
if tm_capture port_text tm_action_forward_add --name busy --proto tcp --listen-port 8080 --tunnel edge --yes; then
  tm_fail "a port that a local service listens on was forwarded"
elif [[ "$port_text" == *"Port 8080/tcp is already used by a local tcp service on 0.0.0.0:8080"* \
  && ! -f "$(tm_forward_file busy)" ]]; then
  tm_pass "a port that a local service listens on is refused"
else
  tm_fail "the busy port was not explained: ${port_text}"
fi
tm_expect_ok "a port that only listens on loopback can be forwarded" \
  tm_action_forward_add --name local8081 --proto tcp --listen-port 8081 --tunnel edge --yes
printf '%s\n' "-A PREROUTING -p tcp -m tcp --dport 9000:9100 -j DNAT --to-destination 192.0.2.5" \
  >"${TM_FAKE_ROOT}/iptables.user-rules"
nat_text=""
if tm_capture nat_text tm_setup_apply_iran edge4 gre 203.0.113.10 203.0.113.40 10.203.0.1 10.203.0.2 30 eth0 22 9050; then
  tm_fail "a port that another tool forwards was taken"
elif [[ "$nat_text" == *"already used by a NAT rule from another tool"* \
  && ! -f "$(tm_tunnel_file edge4)" ]] && ! has_link tm-edge4; then
  tm_pass "a port that another tool forwards is refused before anything changes"
else
  tm_fail "the other tool's port was not explained: ${nat_text}"
fi
rm -f -- "${TM_FAKE_ROOT}/iptables.user-rules" "${TM_FAKE_ROOT}/ss.listen"
tm_expect_ok "remove the loopback test forward" tm_action_forward_delete --name local8081 --yes
tm_expect_ok "remove the second tunnel to the same server" tm_action_tunnel_delete --name edge3 --yes
if has_link tm-edge && ! has_link tm-edge3 && has_rule 'tm:gre:edge:input' \
  && ! has_rule 'tm:gre:edge3:input' && has_rule 'tm:tcp:p443:dnat' && ! has_rule 'tm:tcp:p8443:dnat'; then
  tm_pass "deleting one of two tunnels to the same server keeps the other"
else
  tm_fail "deleting edge3 changed edge"
fi

tm_expect_ok "down stops every tunnel" tm_action_down_all --yes
if ! has_link tm-edge && ! has_link tm-edge2 \
  && ! has_rule 'tm:gre:edge' && ! has_rule 'tm:tcp:p443:dnat' && ! has_rule 'tm:tcp:p2053:dnat' \
  && [[ -f "$(tm_tunnel_file edge)" && -f "$(tm_tunnel_file edge2)" ]]; then
  tm_pass "down removed the runtime state of both tunnels and kept their files"
else
  tm_fail "down left runtime state behind"
fi
tm_expect_ok "apply restores every tunnel" tm_action_apply --yes
if has_link tm-edge && has_link tm-edge2 && has_rule 'tm:tcp:p443:dnat' && has_rule 'tm:tcp:p2053:dnat'; then
  tm_pass "apply brought both tunnels and their ports back"
else
  tm_fail "apply did not restore both tunnels"
fi

tm_expect_ok "down before the failure test" tm_action_down_all --yes
printf '%s\n' tm-edge2 >"${TM_FAKE_ROOT}/ip.fail-add"
apply_text=""
apply_status=0
tm_capture apply_text tm_action_apply --yes || apply_status=$?
tm_expect_eq "apply reports the tunnel that could not start" "$apply_status" "4"
if has_link tm-edge && ! has_link tm-edge2 \
  && has_rule 'tm:gre:edge:input' && ! has_rule 'tm:gre:edge2:input' \
  && has_rule 'tm:tcp:p443:dnat' && ! has_rule 'tm:tcp:p2053:dnat'; then
  tm_pass "a tunnel that cannot start does not undo the other tunnel"
else
  tm_fail "one broken tunnel changed the other tunnel"
fi
if [[ "$apply_text" == *"Failed or skipped: tunnel edge2, forward p2053."* \
  && "$apply_text" == *"Skipping forward p2053"* ]] && ! tm_journal_exists; then
  tm_pass "the failure names the tunnel and its skipped port and leaves no journal"
else
  tm_fail "the partial apply was not reported: ${apply_text}"
fi
tm_expect_eq "IPv4 forwarding stays on after a partial apply" "$(ip_forward)" "1"
rm -f -- "${TM_FAKE_ROOT}/ip.fail-add"
tm_expect_ok "apply after the fix starts the missing tunnel" tm_action_apply --yes
if has_link tm-edge2 && has_rule 'tm:tcp:p2053:dnat'; then
  tm_pass "the fixed tunnel and its port came back"
else
  tm_fail "the fixed tunnel did not come back"
fi

tm_expect_ok "delete the first tunnel" tm_action_tunnel_delete --name edge --yes
if [[ ! -f "$(tm_tunnel_file edge)" && ! -f "$(tm_forward_file p443)" ]] \
  && [[ -f "$(tm_tunnel_file edge2)" && -f "$(tm_forward_file p2053)" ]] \
  && ! has_link tm-edge && has_link tm-edge2 \
  && ! has_rule 'tm:gre:edge:input' && has_rule 'tm:gre:edge2:input' \
  && ! has_rule 'tm:tcp:p443:dnat' && has_rule 'tm:tcp:p2053:dnat' \
  && has_rule 'tm:jump:filter-input'; then
  tm_pass "deleting one tunnel keeps the other tunnel and its port"
else
  tm_fail "deleting edge changed edge2"
fi
tm_expect_eq "IPv4 forwarding stays on for the remaining port" "$(ip_forward)" "1"
mkdir -p -- "$TM_SYSCTL_SCAN"
printf '%s\n' "# another tool" "net.ipv4.ip_forward = 1" >"${TM_SYSCTL_SCAN}/60-other.conf"
sysctl_text=""
tm_capture sysctl_text tm_action_tunnel_delete --name edge2 --yes || true
if [[ "$(ip_forward)" == "1" && "$sysctl_text" == *"IPv4 forwarding stays on because ${TM_SYSCTL_SCAN}/60-other.conf turns it on."* ]]; then
  tm_pass "IPv4 forwarding stays on when another sysctl file turns it on"
else
  tm_fail "IPv4 forwarding was changed under another tool: ${sysctl_text}"
fi

multi_reset 203.0.113.10
tm_expect_ok "a tunnel that turns IPv4 forwarding on" \
  tm_setup_apply_iran edge gre 203.0.113.10 203.0.113.20 10.200.0.1 10.200.0.2 30 eth0 22 443
tm_expect_ok "delete that tunnel" tm_action_tunnel_delete --name edge --yes
tm_expect_eq "IPv4 forwarding goes back off when nothing else needs it" "$(ip_forward)" "0"

multi_reset 203.0.113.20
first_token='v2:gre:edge:203.0.113.10:203.0.113.20:10.200.1.1:10.200.1.2:30:180879616'
tm_expect_ok "the foreign server accepts the first Iran server" \
  tm_action_quick --yes --token "$first_token"
second_text=""
if tm_capture second_text tm_action_quick --yes \
  --token 'v2:gre:edge:203.0.113.11:203.0.113.20:10.200.2.1:10.200.2.2:30:180879872' \
  && [[ "$second_text" == *"saved as edge2"* ]] \
  && [[ "$(saved edge2 TM_REMOTE_PUBLIC_IP)" == "203.0.113.11" ]] \
  && [[ "$(saved edge2 TM_LOCAL_TUNNEL_IP)" == "10.200.2.2" ]]; then
  tm_pass "a second Iran server with the same tunnel name is saved as edge2"
else
  tm_fail "the second Iran server was not set up: ${second_text}"
fi
again_text=""
if tm_capture again_text tm_action_quick --yes --token "$first_token"; then
  tm_fail "pasting the same setup command twice created another tunnel"
elif [[ "$again_text" == *"already set up here as edge."* && ! -f "$(tm_tunnel_file edge3)" ]]; then
  tm_pass "pasting the same setup command twice is refused"
else
  tm_fail "the repeated setup command was not explained: ${again_text}"
fi
clash_text=""
if tm_capture clash_text tm_action_quick --yes \
  --token 'v2:gre:edge:203.0.113.12:203.0.113.20:10.200.1.5:10.200.1.6:24:180879616'; then
  tm_fail "an overlapping inner subnet was accepted on the foreign server"
elif [[ "$clash_text" == *"already used here by tunnel edge"* && ! -f "$(tm_tunnel_file edge3)" ]]; then
  tm_pass "an overlapping inner subnet is refused on the foreign server"
else
  tm_fail "the foreign overlap was not explained: ${clash_text}"
fi
printf '%s\n' "gre9 10.200.3.1/30" >>"${TM_FAKE_ROOT}/ip.addrs"
host_text=""
if tm_capture host_text tm_action_quick --yes \
  --token 'v2:gre:edge:203.0.113.12:203.0.113.20:10.200.3.1:10.200.3.2:30:180880128'; then
  tm_fail "a subnet that another tool's interface uses was accepted on the foreign server"
elif [[ "$host_text" == *"clashes with 10.200.3.1/30 on gre9 here"* && ! -f "$(tm_tunnel_file edge3)" ]]; then
  tm_pass "a subnet that another tool's interface uses is refused on the foreign server"
else
  tm_fail "the foreign interface clash was not explained: ${host_text}"
fi
tm_expect_ok "a third Iran server with free inner addresses" \
  tm_action_quick --yes --token 'v2:gre:edge:203.0.113.12:203.0.113.20:10.200.4.1:10.200.4.2:30:180880384'
old_text=""
if tm_capture old_text tm_action_quick --yes \
  --token 'v1:gre:edge:203.0.113.13:203.0.113.20:10.200.5.1:10.200.5.2:30'; then
  tm_fail "a setup command from another version was accepted"
elif [[ "$old_text" == *"comes from a different Tunnel Manager version"* ]]; then
  tm_pass "a setup command from another version asks to update both servers"
else
  tm_fail "the old setup command was not explained: ${old_text}"
fi
if has_link tm-edge && has_link tm-edge2 && has_link tm-edge3 \
  && has_rule '-s 203.0.113.10 -p gre -m comment --comment tm:gre:edge:input' \
  && has_rule '-s 203.0.113.11 -p gre -m comment --comment tm:gre:edge2:input' \
  && has_rule '-s 203.0.113.12 -p gre -m comment --comment tm:gre:edge3:input'; then
  tm_pass "the foreign server runs one GRE tunnel per Iran server"
else
  tm_fail "the foreign server did not keep every tunnel"
fi

tm_finish
