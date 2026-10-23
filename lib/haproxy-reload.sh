#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Reload the dedicated Tunnel Manager HAProxy process after validation.
set -euo pipefail

CFG="${TM_HAPROXY_CFG:-/etc/tunnel-manager/haproxy.cfg}"
PID_FILE="${TM_HAPROXY_PID:-/run/tunnel-manager/haproxy.pid}"
HAPROXY="${TM_HAPROXY_BIN:-/usr/sbin/haproxy}"

if [[ ! -x "$HAPROXY" ]]; then
  printf '%s\n' "HAProxy binary was not found at ${HAPROXY}." >&2
  exit 1
fi

"$HAPROXY" -c -f "$CFG"

if [[ ! -s "$PID_FILE" ]]; then
  printf '%s\n' "HAProxy is not running; start tunnel-manager-haproxy instead of reloading." >&2
  exit 1
fi

pid=$(tr -d '[:space:]' <"$PID_FILE")
if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "HAProxy pid file is invalid." >&2
  exit 1
fi

"$HAPROXY" -D -f "$CFG" -p "$PID_FILE" -sf "$pid"
