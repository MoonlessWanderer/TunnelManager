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

tm_finish
