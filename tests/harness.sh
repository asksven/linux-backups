# shellcheck shell=bash
# =============================================================================
# tests/harness.sh — minimal assertion/test-runner helpers shared by every
# tests/test_*.sh file in this suite. Source this; do not execute it.
#
# There is no external test framework dependency (Bats et al.) here, matching
# the rest of this repo (plain bash, nothing to install). Conventions:
#
#   - Each tests/test_*.sh file defines one or more `test_<name>` functions
#     and ends with `run_tests`, which discovers and runs every test_*
#     function defined in that file (order is whatever `declare -F` reports,
#     not necessarily definition order -- each test must be independent),
#     each in its own subshell so state (globals, cwd, traps, sourced
#     scripts) never leaks between tests.
#   - Use the assert_* helpers below inside a test function. A failed
#     assertion is recorded and printed immediately but does NOT abort the
#     test function -- later assertions in the same test still run, so one
#     test prints every mismatch it finds, not just the first.
#   - TAR is the GNU tar binary to use for building test fixtures: "tar" on
#     Linux, or Homebrew's "gtar" on macOS (whose default `tar` is bsdtar and
#     lacks --transform/--append, which the scripts under test require).
# =============================================================================
set -uo pipefail

TAR="${TAR:-tar}"
if ! "$TAR" --version 2>/dev/null | grep -q GNU; then
  if command -v gtar >/dev/null 2>&1; then
    TAR=gtar
  fi
fi
export TAR

# Absolute path to the repo root (tests/ is directly under it). Read by every
# tests/test_*.sh / tests/stub_lib.sh file, not by this file itself.
# shellcheck disable=SC2034
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# Set by fail(); read by run_tests()'s per-test subshell to decide pass/fail.
_CURRENT_TEST_FAILED=0

fail() {
  echo "    FAIL: $*"
  _CURRENT_TEST_FAILED=1
}

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  [[ "$got" == "$want" ]] || fail "${msg:+$msg: }expected [$want], got [$got]"
}

assert_ne() {
  local got="$1" not_want="$2" msg="${3:-}"
  [[ "$got" != "$not_want" ]] || fail "${msg:+$msg: }did not expect [$not_want]"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  [[ "$haystack" == *"$needle"* ]] || fail "${msg:+$msg: }expected to contain [$needle], got [$haystack]"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  [[ "$haystack" != *"$needle"* ]] || fail "${msg:+$msg: }expected NOT to contain [$needle], got [$haystack]"
}

assert_file_exists() {
  local f="$1" msg="${2:-}"
  [[ -f "$f" ]] || fail "${msg:+$msg: }expected file to exist: $f"
}

assert_dir_exists() {
  local d="$1" msg="${2:-}"
  [[ -d "$d" ]] || fail "${msg:+$msg: }expected directory to exist: $d"
}

assert_not_exists() {
  local p="$1" msg="${2:-}"
  [[ ! -e "$p" ]] || fail "${msg:+$msg: }expected path to NOT exist: $p"
}

assert_file_content() {
  local f="$1" want="$2" msg="${3:-}"
  local got=""
  [[ -f "$f" ]] && got="$(cat "$f")"
  [[ "$got" == "$want" ]] || fail "${msg:+$msg: }file $f: expected content [$want], got [$got]"
}

# assert_mode <path> <octal-mode e.g. 644 or 755> [msg]
assert_mode() {
  local p="$1" want="$2" msg="${3:-}" got
  got="$(stat -f '%Lp' "$p" 2>/dev/null || stat -c '%a' "$p" 2>/dev/null)"
  [[ "$got" == "$want" ]] || fail "${msg:+$msg: }mode of $p: expected [$want], got [$got]"
}

assert_status() {
  local got="$1" want="$2" msg="${3:-}"
  [[ "$got" -eq "$want" ]] || fail "${msg:+$msg: }expected exit status $want, got $got"
}

# run_tests -- discover every function named test_* defined so far in the
# calling file and run each in its own subshell (order is whatever
# `declare -F` reports; tests must not depend on each other). Prints a
# per-test PASS/FAIL line and a per-file summary; exits non-zero if any test
# in this file failed (the exit status run_all.sh checks per file).
run_tests() {
  local fn rc file_pass=0 file_fail=0
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    echo "--- $fn ---"
    ( _CURRENT_TEST_FAILED=0; "$fn"; exit "$_CURRENT_TEST_FAILED" )
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "PASS: $fn"
      file_pass=$((file_pass + 1))
    else
      echo "FAIL: $fn"
      file_fail=$((file_fail + 1))
    fi
  done
  echo
  echo "$(basename "$0"): ${file_pass} passed, ${file_fail} failed"
  [[ $file_fail -eq 0 ]]
}
