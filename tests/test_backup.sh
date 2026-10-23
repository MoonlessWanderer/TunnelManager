#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

tm_ensure_tree
printf '%s\n' "$TM_TEST_PRIV" | tm_write_file "$(tm_key_file edge)" 0600
tm_kv_write "$(tm_tunnel_file edge)" 0600 \
  TM_TUNNEL_NAME edge \
  TM_TUNNEL_TYPE wireguard \
  TM_TUNNEL_STATE active \
  TM_LOCAL_PUBLIC_IP 203.0.113.10 \
  TM_REMOTE_PUBLIC_IP 203.0.113.20 \
  TM_LOCAL_TUNNEL_IP 10.200.0.1 \
  TM_REMOTE_TUNNEL_IP 10.200.0.2 \
  TM_TUNNEL_CIDR 30 \
  TM_MTU 1420 \
  TM_WAN_IFACE eth0 \
  TM_GRE_ACK no \
  TM_PRIVATE_KEY_FILE "$(tm_key_file edge)" \
  TM_LISTEN_PORT 51820 \
  TM_ENDPOINT_PORT 51820 \
  TM_KEEPALIVE 25 \
  TM_PEER_PUBLIC_KEY "$TM_TEST_PUB"
tm_kv_write "$(tm_host_file)" 0600 \
  TM_HOST_ROLE iran \
  TM_HOST_PUBLIC_IP 203.0.113.10 \
  TM_HOST_WAN_IFACE eth0 \
  TM_SSH_PORT 22 \
  TM_FW_BACKEND iptables

archive="${TM_VAR}/backups/plain.tar.gz"
tm_expect_ok "backup without keys" tm_action_backup_create --output "$archive"
members=$(tar -tzf "$archive")
if [[ "$members" == *"host.conf"* && "$members" == *"tunnels/edge.conf"* && "$members" != *"keys/"* && "$members" != *".key"* ]]; then
  tm_pass "default backup excludes private keys"
else
  tm_fail "default backup members were unexpected: ${members}"
fi

keyed="${TM_VAR}/backups/keyed.tar.gz"
tm_expect_ok "backup with keys" tm_action_backup_create --output "$keyed" --include-keys
members=$(tar -tzf "$keyed")
if [[ "$members" == *"keys/edge.key"* && "$members" == *"$TM_TEST_PRIV"* ]]; then
  tm_fail "key material leaked into the member names"
else
  if [[ "$members" == *"keys/edge.key"* ]]; then
    tm_pass "explicit backup can include the key file"
  else
    tm_fail "include-keys backup omitted the key file: ${members}"
  fi
fi
if grep -q "private keys" "$TM_LOG_FILE"; then
  tm_pass "include-keys backup warns about private keys"
else
  tm_fail "include-keys backup did not warn"
fi

rm -f -- "$(tm_host_file)"
tm_expect_ok "restore backup" tm_action_backup_restore --file "$archive" --yes
if [[ -f "$(tm_host_file)" ]]; then
  tm_pass "restore wrote host.conf"
else
  tm_fail "restore did not write host.conf"
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
