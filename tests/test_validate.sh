#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

tm_expect_ok "10.200.0.1 is unicast" tm_ipv4_is_unicast_host 10.200.0.1
tm_expect_fail "leading zero is rejected" tm_valid_ipv4 10.200.0.01
tm_expect_fail "loopback is not a tunnel address" tm_ipv4_is_unicast_host 127.0.0.1
tm_expect_fail "multicast is not a tunnel address" tm_ipv4_is_unicast_host 224.0.0.1
tm_expect_fail "broadcast is not a tunnel address" tm_ipv4_is_unicast_host 255.255.255.255
tm_expect_fail "unspecified address is not a host" tm_ipv4_is_unicast_host 0.0.0.0
tm_expect_ok "unspecified address may be a listen address" tm_valid_listen_ip 0.0.0.0
tm_expect_ok "/30 peers share a subnet" tm_ipv4_same_subnet 10.200.0.1 10.200.0.2 30
tm_expect_fail "/30 does not contain .5" tm_ipv4_same_subnet 10.200.0.1 10.200.0.5 30
tm_expect_fail "network address is not assignable on /30" tm_ipv4_is_assignable 10.200.0.0 30
tm_expect_fail "broadcast address is not assignable on /30" tm_ipv4_is_assignable 10.200.0.3 30
tm_expect_ok "both /31 hosts are assignable" tm_tunnel_pair_ok 10.200.0.0 10.200.0.1 31
tm_expect_fail "/16 is not a tunnel prefix" tm_valid_tunnel_prefix 16
tm_expect_ok "192.168.1.10/24 is assignable" tm_ipv4_is_assignable 192.168.1.10 24
tm_expect_ok "192.168.1.10 and .11 share /24" tm_ipv4_same_subnet 192.168.1.10 192.168.1.11 24
tm_expect_fail "port 0 is rejected" tm_valid_port 0
tm_expect_ok "port 22 is protected" tm_port_is_protected 22
tm_expect_fail "port 443 is not protected" tm_port_is_protected 443
tm_expect_ok "wireguard name edge" tm_valid_tunnel_name edge
tm_expect_fail "reserved name default" tm_valid_tunnel_name default
tm_expect_ok "default route cidr is recognized" tm_default_route_cidr 0.0.0.0/0
tm_expect_fail "/32 is not a default route" tm_default_route_cidr 10.200.0.2/32
tm_expect_ok "compressed ipv6 is valid" tm_valid_ipv6 2001:db8::1
tm_expect_ok "ipv6 host is unicast" tm_ipv6_is_unicast_host 2001:db8::1
tm_expect_fail "ipv6 loopback is not a tunnel address" tm_ipv6_is_unicast_host ::1
tm_expect_fail "ipv6 unspecified is not a host" tm_ipv6_is_unicast_host ::
tm_expect_ok "ipv6 unspecified may be a listen address" tm_valid_listen_ip ::
tm_expect_fail "ipv6 link-local is rejected" tm_ipv6_is_unicast_host fe80::1
tm_expect_fail "ipv6 multicast is rejected" tm_ipv6_is_unicast_host ff02::1
tm_expect_ok "ipv6 /64 peers share a subnet" tm_ipv6_same_subnet 2001:db8:1::1 2001:db8:1::2 64
tm_expect_fail "ipv6 /64 does not contain a different subnet id" tm_ipv6_same_subnet 2001:db8:1::1 2001:db8:2::1 64
tm_expect_fail "ipv6 subnet-router anycast is not assignable" tm_ipv6_is_assignable 2001:db8:1:: 64
tm_expect_ok "both ipv6 /127 hosts are assignable" tm_tunnel_pair_ok 2001:db8:1:: 2001:db8:1::1 127
tm_expect_fail "ipv6 /48 is too wide for a tunnel" tm_valid_ipv6_prefix 48
tm_expect_fail "mixed tunnel families are rejected" tm_tunnel_pair_ok 10.200.0.1 2001:db8:1::1 64
tm_expect_fail "mixed public families are rejected" tm_public_pair_ok 203.0.113.10 2001:db8::20
tm_expect_ok "ipv6 public pair is accepted" tm_public_pair_ok 2001:db8::10 2001:db8::20
tm_expect_ok "default ipv6 route is recognized" tm_default_route_cidr ::/0

if [[ ${#TM_TEST_PRIV} -eq 44 && ${#TM_TEST_PUB} -eq 44 ]]; then
  tm_pass "generated wireguard keys are 44 characters"
else
  tm_fail "generated wireguard keys have the wrong length"
fi
tm_expect_ok "private test key shape" tm_valid_wg_key "$TM_TEST_PRIV"
tm_expect_ok "public test key shape" tm_valid_wg_key "$TM_TEST_PUB"

redacted=$(tm_redact "secret ${TM_TEST_PRIV}")
if [[ "$redacted" == *"[REDACTED-KEY]"* && "$redacted" != *"$TM_TEST_PRIV"* ]]; then
  tm_pass "log redaction hides a wireguard key"
else
  tm_fail "log redaction left a wireguard key visible"
fi
extracted=$(tm_normalize_wg_key "copy this ${TM_TEST_PUB} now")
tm_expect_eq "pasted text keeps the wireguard key" "$extracted" "$TM_TEST_PUB"
tm_expect_fail "log placeholder is not a key" tm_normalize_wg_key "[REDACTED-KEY]"

tm_expect_eq "default route iface" "$(tm_detect_default_iface)" "eth0"
tm_expect_eq "nexthop route iface" "$(tm_route_dev 'nexthop via 192.0.2.1 dev ens3 weight 1')" "ens3"
tm_expect_fail "route line without a device" tm_route_dev "default via 192.0.2.1"
tm_expect_eq "address line iface" "$(tm_addr_show_iface '2: ens3    inet 31.184.244.31/24 brd 31.184.244.255 scope global ens3')" "ens3"
touch "${TM_FAKE_ROOT}/ip.no-default"
tm_expect_fail "missing main default route" tm_detect_default_iface
tm_expect_eq "wan follows the reachable address" "$(tm_detect_wan '' 31.184.244.31 87.107.112.226)" "eth0"
rm -f -- "${TM_FAKE_ROOT}/ip.no-default"
picked=$(printf '%s\n' \
  '1: lo    inet 127.0.0.1/8 scope host lo' \
  '2: enp3s0    inet 10.1.2.3/24 scope global enp3s0' \
  '2: enp3s0    inet 31.184.244.31/24 brd 31.184.244.255 scope global enp3s0' \
  | tm_pick_reachable_lines)
tm_expect_eq "public address is preferred" "$picked" "enp3s0 31.184.244.31"
picked=$(printf '%s\n' '2: enp3s0    inet 10.1.2.3/24 scope global enp3s0' | tm_pick_reachable_lines)
tm_expect_eq "private address is used when it is the only one" "$picked" "enp3s0 10.1.2.3"

tm_finish
