#!/usr/bin/env bash
# =============================================================================
# tests/run_all.sh — run every tests/test_*.sh file in this directory and
# print an aggregate pass/fail summary. Exits non-zero if any file failed.
#
# Usage: tests/run_all.sh
#
# This suite has no external dependencies (no Bats, no daemon): Docker is
# stubbed either as bash functions overriding lib.sh's docker-wrapper
# functions (unit-level tests), or as a minimal `docker` executable stub
# under tests/fixtures/bin/ prepended to PATH (subprocess-level restore.sh
# tests, which run restore.sh as a real script rather than sourcing it).
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

total_pass=0
total_fail=0
failed_files=()

for f in test_*.sh; do
  [[ -e "$f" ]] || continue
  echo "=== $f ==="
  if bash "$f"; then
    total_pass=$((total_pass + 1))
  else
    total_fail=$((total_fail + 1))
    failed_files+=( "$f" )
  fi
  echo
done

echo "==================================="
echo "Suite result: ${total_pass} file(s) passed, ${total_fail} file(s) failed"
if [[ ${#failed_files[@]} -gt 0 ]]; then
  echo "Failed files: ${failed_files[*]}"
fi
[[ $total_fail -eq 0 ]]
