#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

tm_ensure_tree
tm_kv_write "$(tm_tunnel_file edge)" 0600 \
  TM_TUNNEL_NAME edge \
  TM_TUNNEL_TYPE gre \
  TM_TUNNEL_STATE active \
  TM_LOCAL_PUBLIC_IP 203.0.113.10 \
  TM_REMOTE_PUBLIC_IP 203.0.113.20 \
  TM_LOCAL_TUNNEL_IP 10.200.0.1 \
  TM_REMOTE_TUNNEL_IP 10.200.0.2 \
  TM_TUNNEL_CIDR 30 \
  TM_MTU 1476 \
  TM_WAN_IFACE eth0
tm_kv_write "$(tm_host_file)" 0600 \
  TM_HOST_ROLE iran \
  TM_HOST_PUBLIC_IP 203.0.113.10 \
  TM_HOST_WAN_IFACE eth0 \
  TM_SSH_PORT 22 \
  TM_FW_BACKEND iptables

archive="${TM_VAR}/backups/plain.tar.gz"
tm_expect_ok "create backup" tm_action_backup_create --output "$archive"
members=$(tar -tzf "$archive")
if [[ "$members" == *"MANIFEST"* && "$members" == *"host.conf"* && "$members" == *"tunnels/edge.conf"* ]]; then
  tm_pass "backup holds the manifest, host, and tunnel files"
else
  tm_fail "backup members were unexpected: ${members}"
fi

rm -f -- "$(tm_host_file)" "$(tm_tunnel_file edge)"
tm_expect_ok "restore backup" tm_action_backup_restore --file "$archive" --yes
if [[ -f "$(tm_host_file)" && -f "$(tm_tunnel_file edge)" ]]; then
  tm_pass "restore wrote host.conf and the tunnel"
else
  tm_fail "restore did not write host.conf and the tunnel"
fi

bad="${TM_TEST_ROOT}/bad.tar.gz"
mkdir -p -- "${TM_TEST_ROOT}/stage/bad"
printf 'pwn\n' >"${TM_TEST_ROOT}/stage/bad/x"
tar -C "${TM_TEST_ROOT}/stage" -czf "$bad" bad/x
if (
  tm_action_backup_restore --file "$bad" --yes
); then
  tm_fail "unsafe backup member was restored"
else
  tm_pass "unsafe backup member is rejected"
fi

tm_finish
