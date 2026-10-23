#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

rendered=$(tm_wg_render "$TM_TEST_PRIV" 10.200.0.1 30 51820 1420 "$TM_TEST_PUB" 10.200.0.2 203.0.113.20 51820 25)
if [[ "$rendered" == *"Table = off"* && "$rendered" == *"AllowedIPs = 10.200.0.2/32"* && "$rendered" != *"0.0.0.0/0"* && "$rendered" != *"::/0"* ]]; then
  tm_pass "wireguard config keeps a host route only"
else
  tm_fail "wireguard config was not constrained"
fi
tm_expect_fail "wireguard rejects a default allowed ip" tm_wg_render "$TM_TEST_PRIV" 10.200.0.1 30 51820 1420 "$TM_TEST_PUB" 0.0.0.0 203.0.113.20 51820 25
rendered6=$(tm_wg_render "$TM_TEST_PRIV" 2001:db8:1::1 64 51820 1400 "$TM_TEST_PUB" 2001:db8:1::2 2001:db8::20 51820 25)
if [[ "$rendered6" == *"AllowedIPs = 2001:db8:1::2/128"* && "$rendered6" == *"Endpoint = [2001:db8::20]:51820"* && "$rendered6" == *"Table = off"* && "$rendered6" != *"::/0"* ]]; then
  tm_pass "ipv6 wireguard config keeps a host route only"
else
  tm_fail "ipv6 wireguard config was not constrained"
fi
tm_expect_fail "wireguard rejects an ipv6 default route" tm_wg_render "$TM_TEST_PRIV" 2001:db8:1::1 64 51820 1400 "$TM_TEST_PUB" :: 2001:db8::20 51820 25

warning=$(tm_gre_warning_text)
if [[ "$warning" == *"no encryption"* && "$warning" == *"no authentication"* ]]; then
  tm_pass "GRE warning states there is no encryption"
else
  tm_fail "GRE warning is incomplete"
fi

mkdir -p -- "${TM_ETC}/forwards"
tm_kv_write "${TM_ETC}/forwards/web.conf" 0600 \
  TM_FORWARD_NAME web \
  TM_FORWARD_PROTO tcp \
  TM_LISTEN_IP 0.0.0.0 \
  TM_LISTEN_PORT 443 \
  TM_DEST_IP 10.200.0.2 \
  TM_DEST_PORT 443 \
  TM_SNAT never \
  TM_INGRESS_IFACE eth0 \
  TM_SOURCE_IP 10.200.0.1 \
  TM_TUNNEL_REF edge
proxy=$(tm_haproxy_render web)
if [[ "$proxy" == *"frontend tm_web_fe"* && "$proxy" == *"backend tm_web_be"* && "$proxy" == *"option tcp-check"* ]]; then
  tm_pass "haproxy render contains a tcp frontend and backend"
else
  tm_fail "haproxy render is incomplete"
fi
tm_kv_write "${TM_ETC}/forwards/ssh.conf" 0600 \
  TM_FORWARD_NAME ssh \
  TM_FORWARD_PROTO tcp \
  TM_LISTEN_IP 0.0.0.0 \
  TM_LISTEN_PORT 22 \
  TM_DEST_IP 10.200.0.2 \
  TM_DEST_PORT 22 \
  TM_SNAT never \
  TM_INGRESS_IFACE eth0 \
  TM_SOURCE_IP 10.200.0.1 \
  TM_TUNNEL_REF edge
if tm_haproxy_render ssh >/dev/null; then
  tm_fail "haproxy accepted SSH port 22"
else
  tm_pass "haproxy rejects listen port 22"
fi
tm_kv_write "${TM_ETC}/forwards/v6.conf" 0600 \
  TM_FORWARD_NAME v6 \
  TM_FORWARD_PROTO tcp \
  TM_LISTEN_IP :: \
  TM_LISTEN_PORT 443 \
  TM_DEST_IP 2001:db8:1::2 \
  TM_DEST_PORT 443 \
  TM_SNAT never \
  TM_INGRESS_IFACE eth0 \
  TM_SOURCE_IP 2001:db8:1::1 \
  TM_TUNNEL_REF edge6
proxy6=$(tm_haproxy_render v6)
if [[ "$proxy6" == *"bind [::]:443"* && "$proxy6" == *"server dest [2001:db8:1::2]:443 source [2001:db8:1::1]"* ]]; then
  tm_pass "haproxy brackets ipv6 addresses"
else
  tm_fail "haproxy ipv6 render was not bracketed"
fi

unit=$(tm_render_unit "${TM_REPO}/systemd/tunnel-manager-haproxy.service.in")
if [[ "$unit" == *"-c -f"* && "$unit" == *" -D "* ]]; then
  tm_pass "haproxy unit validates before start"
else
  tm_fail "haproxy unit is missing validation"
fi

tm_finish
