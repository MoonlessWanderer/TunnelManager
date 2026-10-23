#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

bad="${TM_TEST_ROOT}/bad.conf"
# The payload must stay quoted so the shell does not expand it.
# shellcheck disable=SC2016
printf 'TM_HOST_ROLE=$(reboot)\n' >"$bad"
tm_expect_fail "command substitution is rejected" tm_kv_read "$bad" _ignored
printf 'TM_HOST_ROLE=iran;touch\n' >"$bad"
local_status=0
(
  declare -A row=()
  tm_kv_read "$bad" row
) || local_status=1
if [[ "$local_status" -eq 1 ]]; then
  tm_pass "semicolon injection is rejected"
else
  tm_fail "semicolon injection was accepted"
fi
printf 'TM_HOST_ROLE=../etc/passwd\n' >"$bad"
if (
  declare -A row=()
  tm_kv_read "$bad" row
); then
  tm_fail "dotdot value was accepted"
else
  tm_pass "dotdot value is rejected"
fi
for value in /etc/x a=b a+b a@b a,b; do
  printf 'TM_HOST_ROLE=%s\n' "$value" >"$bad"
  if (
    declare -A row=()
    tm_kv_read "$bad" row
  ); then
    tm_fail "state value ${value} was accepted"
  else
    tm_pass "state value ${value} is rejected"
  fi
done
printf 'TM_UNKNOWN_KEY=1\n' >"$bad"
tm_expect_fail "unknown state key is rejected" tm_kv_read "$bad" _ignored

good="${TM_ETC}/host.conf"
mkdir -p -- "$TM_ETC"
tm_kv_write "$good" 0600 \
  TM_HOST_ROLE iran \
  TM_HOST_PUBLIC_IP 203.0.113.10 \
  TM_HOST_WAN_IFACE eth0 \
  TM_SSH_PORT 22 \
  TM_FW_BACKEND auto
declare -A host=()
tm_expect_ok "host file can be read" tm_kv_read "$good" host
tm_expect_eq "host role" "${host[TM_HOST_ROLE]}" "iran"

# shellcheck disable=SC2016
encoded=$(tm_shell_quote tm_noop '$(touch pwned)')
declare -a argv=()
tm_eval_argv "$encoded" argv
# shellcheck disable=SC2016
tm_expect_eq "quoted payload stays literal" "${argv[1]}" '$(touch pwned)'

tm_expect_fail "/etc/passwd is not mutable" tm_path_is_mutable /etc/passwd
tm_expect_fail "a tm- file outside the state tree is not mutable" tm_path_is_mutable "${TM_TEST_ROOT}/other/tm-edge.conf"
tm_expect_fail "another program's config is not mutable" tm_path_is_mutable "${TM_TEST_ROOT}/other/app.conf"

mkdir -p -- "$TM_ETC/real"
rm -rf -- "$TM_ETC/alias"
MSYS=winsymlinks:nativestrict ln -s real "$TM_ETC/alias" 2>/dev/null || true
if [[ ! -L "$TM_ETC/alias" ]]; then
  rm -rf -- "$TM_ETC/alias"
  powershell.exe -NoProfile -Command "New-Item -ItemType SymbolicLink -Path '$TM_ETC/alias' -Target '$TM_ETC/real'" >/dev/null 2>&1 || true
fi
if [[ -L "$TM_ETC/alias" ]]; then
  if (
    printf 'nope\n' | tm_write_file "${TM_ETC}/alias/file.conf" 0600
  ); then
    tm_fail "symlink path was writable"
  else
    tm_pass "symlink path is rejected"
  fi
else
  printf '%s\n' "SKIP symlink rejection was not executed; this host did not create a symlink."
fi

TM_DRY_RUN=1
printf 'dry\n' | tm_write_file "${TM_ETC}/dry.conf" 0600
if [[ ! -e "${TM_ETC}/dry.conf" ]]; then
  tm_pass "dry-run write creates no file"
else
  tm_fail "dry-run write created a file"
fi
TM_DRY_RUN=0

for sample in "${TM_REPO}"/examples/*.conf.example; do
  # sample_row is filled through a nameref.
  # shellcheck disable=SC2034
  declare -A sample_row=()
  if tm_kv_read "$sample" sample_row; then
    tm_pass "example parses: $(basename "$sample")"
  else
    tm_fail "example failed to parse: $(basename "$sample")"
  fi
done

tm_finish
