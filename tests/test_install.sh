#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

prefix="${TM_TEST_ROOT}/prefix"
bash "${TM_REPO}/install.sh" --prefix "$prefix" --skip-packages --skip-systemd
if [[ -f "${prefix}/bin/tunnel-manager" && -f "${prefix}/lib/tunnel-manager/load.sh" && -f "${prefix}/lib/tunnel-manager/haproxy-reload.sh" ]]; then
  tm_pass "install lays out the executable and libraries"
else
  tm_fail "install layout is incomplete"
fi
installed_version=$(bash "${prefix}/bin/tunnel-manager" version)
tm_expect_eq "installed version" "$installed_version" "1.0.0"
bash "${TM_REPO}/uninstall.sh" --prefix "$prefix" --yes --skip-down
if [[ ! -e "${prefix}/bin/tunnel-manager" && ! -e "${prefix}/lib/tunnel-manager" ]]; then
  tm_pass "uninstall removes installed files"
else
  tm_fail "uninstall left installed files behind"
fi
if grep -E 'apt(-get)?[[:space:]]+remove|iptables[[:space:]]+-F|nft[[:space:]]+flush' "${TM_REPO}/uninstall.sh"; then
  tm_fail "uninstall removes packages or flushes the firewall"
else
  tm_pass "uninstall leaves packages and foreign firewall rules alone"
fi

tm_finish
