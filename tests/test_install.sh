#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
tm_test_reset

prefix="${TM_TEST_ROOT}/prefix"
bash "${TM_REPO}/install.sh" --prefix "$prefix" --skip-packages --skip-systemd
if [[ -f "${prefix}/bin/tunnel-manager" && -f "${prefix}/bin/tm" && -f "${prefix}/lib/tunnel-manager/load.sh" && -f "${prefix}/lib/tunnel-manager/haproxy-reload.sh" ]]; then
  tm_pass "install lays out the executable and libraries"
else
  tm_fail "install layout is incomplete"
fi
if grep -q 'tunnel-manager" menu' "${prefix}/bin/tm"; then
  tm_pass "tm opens the menu"
else
  tm_fail "tm does not open the menu"
fi
installed_version=$(bash "${prefix}/bin/tunnel-manager" version)
tm_expect_eq "installed version" "$installed_version" "1.3.0"
bash "${TM_REPO}/uninstall.sh" --prefix "$prefix" --yes --skip-down
if [[ ! -e "${prefix}/bin/tunnel-manager" && ! -e "${prefix}/bin/tm" && ! -e "${prefix}/lib/tunnel-manager" ]]; then
  tm_pass "uninstall removes installed files"
else
  tm_fail "uninstall left installed files behind"
fi
if grep -E 'apt(-get)?[[:space:]]+remove|iptables[[:space:]]+-F|nft[[:space:]]+flush' "${TM_REPO}/uninstall.sh"; then
  tm_fail "uninstall removes packages or flushes the firewall"
else
  tm_pass "uninstall leaves packages and foreign firewall rules alone"
fi

archive="${TM_TEST_ROOT}/src.tar.gz"
tar -C "$TM_REPO" -czf "$archive" --exclude .git .
got="${TM_TEST_ROOT}/got"
TM_UPDATE_ARCHIVE="$archive" bash "${TM_REPO}/get.sh" --prefix "$got" --skip-packages --skip-systemd
if [[ -x "${got}/bin/tm" && -f "${got}/lib/tunnel-manager/update.sh" ]]; then
  tm_pass "one-command installer lays out tm"
else
  tm_fail "one-command installer layout is incomplete"
fi
export TM_UPDATE_ARCHIVE="$archive"
export TM_PREFIX="${TM_TEST_ROOT}/updated"
tm_expect_ok "update installs from a local archive" tm_action_update --yes
if [[ -f "${TM_PREFIX}/bin/tm" && -f "${TM_PREFIX}/lib/tunnel-manager/load.sh" ]]; then
  tm_pass "update reinstalls the program"
else
  tm_fail "update did not reinstall the program"
fi
unset TM_UPDATE_ARCHIVE TM_PREFIX
if grep -q 'Configure a New Tunnel' "${TM_REPO}/lib/menu.sh" \
  && grep -q 'Enable BBR' "${TM_REPO}/lib/menu.sh" \
  && grep -q 'Enter your choice' "${TM_REPO}/lib/menu.sh"; then
  tm_pass "menu contains the short main screen"
else
  tm_fail "menu is missing the short main screen"
fi

tm_finish
