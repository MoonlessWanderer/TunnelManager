#!/usr/bin/env bash
# Run every unit test file. A skipped check is not counted as a pass.
set -euo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
ran=0

for test_file in "$ROOT"/tests/test_*.sh; do
  [[ -f "$test_file" ]] || continue
  ran=$((ran + 1))
  printf '\n== %s\n' "$(basename "$test_file")"
  if bash "$test_file"; then
    printf 'FILE PASS %s\n' "$(basename "$test_file")"
  else
    printf 'FILE FAIL %s\n' "$(basename "$test_file")" >&2
    fail=1
  fi
done

if [[ "$ran" -eq 0 ]]; then
  printf '%s\n' "No test files were found." >&2
  exit 1
fi

if [[ "$fail" -ne 0 ]]; then
  printf '%s\n' "One or more test files failed." >&2
  exit 1
fi
printf '%s\n' "All ${ran} test files passed."
