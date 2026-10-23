BASH ?= bash

.PHONY: syntax test shellcheck check

syntax:
	$(BASH) -n bin/tunnel-manager bin/tm install.sh uninstall.sh get.sh
	$(BASH) -n lib/*.sh tests/helpers.sh tests/run-tests.sh tests/test_*.sh tests/fakes/*

test: syntax
	$(BASH) tests/run-tests.sh

shellcheck:
	shellcheck -x bin/tunnel-manager bin/tm lib/*.sh install.sh uninstall.sh get.sh tests/helpers.sh tests/run-tests.sh tests/test_*.sh

check: test shellcheck
