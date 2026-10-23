BASH ?= bash

.PHONY: syntax test shellcheck check

syntax:
	$(BASH) -n bin/tunnel-manager install.sh uninstall.sh lib/haproxy-reload.sh
	$(BASH) -n lib/*.sh tests/helpers.sh tests/run-tests.sh tests/test_*.sh tests/fakes/*

test: syntax
	$(BASH) tests/run-tests.sh

shellcheck:
	shellcheck -x bin/tunnel-manager lib/*.sh lib/haproxy-reload.sh install.sh uninstall.sh tests/helpers.sh tests/run-tests.sh tests/test_*.sh

check: test shellcheck
