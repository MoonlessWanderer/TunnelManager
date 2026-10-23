#!/usr/bin/env bash
# Shared helpers for Tunnel Manager unit tests.
set -euo pipefail

TM_REPO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/load.sh
source "${TM_REPO}/lib/load.sh"

TM_PASS=0
TM_FAIL=0
# Used by the test files that source this helper.
# shellcheck disable=SC2034
TM_TEST_PRIV="$(printf '%43s' '' | tr ' ' 'A')="
# shellcheck disable=SC2034
TM_TEST_PUB="$(printf '%43s' '' | tr ' ' 'B')="

tm_pass() {
  TM_PASS=$((TM_PASS + 1))
  printf 'PASS %s\n' "$1"
}

tm_fail() {
  TM_FAIL=$((TM_FAIL + 1))
  printf 'FAIL %s\n' "$*" >&2
}

tm_expect_ok() {
  local desc="$1"
  shift
  set +e
  "$@"
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    tm_pass "$desc"
  else
    tm_fail "${desc} (status ${status})"
  fi
}

tm_expect_fail() {
  local desc="$1"
  shift
  set +e
  ( "$@" )
  local status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    tm_pass "$desc"
  else
    tm_fail "${desc} (unexpected success)"
  fi
}

tm_expect_eq() {
  local desc="$1"
  local got="$2"
  local want="$3"
  if [[ "$got" == "$want" ]]; then
    tm_pass "$desc"
  else
    tm_fail "${desc}: got '${got}' want '${want}'"
  fi
}

tm_capture() {
  local __out=$1
  shift
  local text="" status=0
  set +e
  text=$( "$@" 2>&1 )
  status=$?
  set -e
  printf -v "$__out" '%s' "$text"
  return "$status"
}

tm_test_cleanup() {
  if [[ -n "${TM_TEST_ROOT:-}" && "$TM_TEST_ROOT" == *tm-test.* && -d "$TM_TEST_ROOT" ]]; then
    rm -rf -- "$TM_TEST_ROOT"
  fi
}

tm_test_reset() {
  tm_test_cleanup
  TM_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tm-test.XXXXXX")
  export TM_TEST_MODE=1
  export TM_ALLOW_NON_ROOT=1
  export TM_ALLOW_NON_LINUX=1
  export TM_YES=0
  export TM_DRY_RUN=0
  export TM_ALLOW_GRE=0
  export TM_LOG_LEVEL=info
  export TM_SSH_PORT=22
  export TM_FW_BACKEND=auto
  export TM_ETC="${TM_TEST_ROOT}/etc/tunnel-manager"
  export TM_VAR="${TM_TEST_ROOT}/var"
  export TM_LOG_DIR="${TM_TEST_ROOT}/log"
  export TM_RUN="${TM_TEST_ROOT}/run"
  export TM_SYSCTL_FILE="${TM_TEST_ROOT}/99-tunnel-manager.conf"
  export TM_BBR_FILE="${TM_TEST_ROOT}/98-tunnel-manager-bbr.conf"
  export TM_BBR_MOD_FILE="${TM_TEST_ROOT}/tunnel-manager-bbr.conf"
  export TM_FAKE_ROOT="${TM_TEST_ROOT}/fake"
  export TM_LOG_FILE="${TM_LOG_DIR}/tunnel-manager.log"
  mkdir -p -- "$TM_FAKE_ROOT" "$TM_LOG_DIR"
  TM_BIN_OVERRIDE[iptables]="${TM_REPO}/tests/fakes/iptables"
  TM_BIN_OVERRIDE[ip6tables]="${TM_REPO}/tests/fakes/ip6tables"
  TM_BIN_OVERRIDE[nft]="${TM_REPO}/tests/fakes/nft"
  TM_BIN_OVERRIDE[ip]="${TM_REPO}/tests/fakes/ip"
  TM_BIN_OVERRIDE[sysctl]="${TM_REPO}/tests/fakes/sysctl"
  TM_BIN_OVERRIDE[wg]="${TM_REPO}/tests/fakes/wg"
  TM_BIN_OVERRIDE[wg-quick]="${TM_REPO}/tests/fakes/wg-quick"
  TM_BIN_OVERRIDE[haproxy]="${TM_REPO}/tests/fakes/haproxy"
  TM_BIN_OVERRIDE[systemctl]="${TM_REPO}/tests/fakes/systemctl"
  TM_BIN_OVERRIDE[modprobe]="${TM_REPO}/tests/fakes/modprobe"
  TM_BIN_OVERRIDE[ping]="${TM_REPO}/tests/fakes/ping"
  TM_BIN_OVERRIDE[ss]="${TM_REPO}/tests/fakes/ss"
  tm_init_runtime
  tm_plan_reset
  unset TM_FW_BACKEND
}

tm_finish() {
  printf 'passed=%s failed=%s\n' "$TM_PASS" "$TM_FAIL"
  [[ "$TM_FAIL" -eq 0 ]]
}

trap tm_test_cleanup EXIT
