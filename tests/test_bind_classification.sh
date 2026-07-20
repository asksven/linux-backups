#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals/stub functions read/invoked indirectly by sourced lib.sh/docker-backup.sh
# =============================================================================
# tests/test_bind_classification.sh — the shared 5-rule bind-classification
# precedence (bind_capture_verdict, lib.sh) and its consumer
# classify_stack_binds() (docker-backup.sh): verdict precedence, per-source
# deduplication, and the unique-source counters/bytes (Phase 6 steps 24/25).
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/harness.sh
source ./harness.sh
# shellcheck source=tests/stub_lib.sh
source ./stub_lib.sh

test_verdict_precedence() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/normal" "$work/ignoreme" "$work/netfs" "$work/netfs-forced"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib.sh"
  _bind_fstype() {
    case "$1" in
      "$work/netfs"|"$work/netfs-forced") echo "nfs" ;;
      *) echo "ext4" ;;
    esac
  }

  BIND_IGNORE=( "$work/ignoreme" )
  BIND_INCLUDE_NETFS=( "$work/netfs-forced" )

  bind_capture_verdict "mystack" "$work/normal"
  assert_eq "$BIND_VERDICT" "capture" "normal local path"

  declare -A BIND_IGNORE_HITS=()
  bind_capture_verdict "mystack" "$work/ignoreme"
  assert_eq "$BIND_VERDICT" "bind-ignore" "BIND_IGNORE match"
  assert_eq "${BIND_IGNORE_HITS[0]:-}" "1" "BIND_IGNORE_HITS hit recorded"

  bind_capture_verdict "mystack" "$work/netfs"
  assert_eq "$BIND_VERDICT" "network-excluded" "network fs auto-excluded"

  bind_capture_verdict "mystack" "$work/netfs-forced"
  assert_eq "$BIND_VERDICT" "network-forced" "BIND_INCLUDE_NETFS overrides network exclusion"

  rm -rf "$work"
}

test_classify_stack_binds_dedup_and_metrics() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/data/normal" "$work/data/netfs-forced"

  load_docker_backup "$work"
  REPO_DIR="$REPO_ROOT"
  stub_bind_helpers
  _bind_fstype() {
    case "$1" in
      "$work/data/netfs-forced") echo "nfs" ;;
      *) echo "ext4" ;;
    esac
  }

  BIND_IGNORE=()
  BIND_INCLUDE_NETFS=( "$work/data/netfs-forced" )

  # The same two sources, each mounted by two different "containers"
  # (destinations), one of them read-only.
  stack_bind_mounts() {
    printf '%s\t%s\t%s\n' "$work/data/normal" "/dst/a" "false"
    printf '%s\t%s\t%s\n' "$work/data/normal" "/dst/b" "true"
    printf '%s\t%s\t%s\n' "$work/data/netfs-forced" "/dst/c" "false"
    printf '%s\t%s\t%s\n' "$work/data/netfs-forced" "/dst/d" "false"
  }

  classify_stack_binds "mystack"

  assert_eq "$BIND_COUNT" "2" "BIND_COUNT counts unique sources, not mount occurrences"
  assert_eq "$BIND_BYTES" "8192" "BIND_BYTES sums each unique source once, including force-captured netfs"

  local entry_normal="" e
  for e in "${CAPTURE_BINDS[@]}"; do
    [[ "$e" == "$work/data/normal"* ]] && entry_normal="$e"
  done
  local mounts="${entry_normal##*$'\t'}"
  assert_contains "$mounts" "/dst/a"$'\x1f'"false" "mounts[] preserves first destination/RO"
  assert_contains "$mounts" "/dst/b"$'\x1f'"true" "mounts[] preserves second destination/RO"

  rm -rf "$work"
}

test_classify_stack_binds_excluded_dedup() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/data/ignoreme" "$work/data/netfs"

  load_docker_backup "$work"
  REPO_DIR="$REPO_ROOT"
  stub_bind_helpers
  _bind_fstype() {
    case "$1" in
      "$work/data/netfs") echo "nfs" ;;
      *) echo "ext4" ;;
    esac
  }

  BIND_IGNORE=( "$work/data/ignoreme" )
  BIND_INCLUDE_NETFS=()

  stack_bind_mounts() {
    printf '%s\t%s\t%s\n' "$work/data/ignoreme" "/dst/a" "false"
    printf '%s\t%s\t%s\n' "$work/data/ignoreme" "/dst/b" "false"
    printf '%s\t%s\t%s\n' "$work/data/netfs" "/dst/c" "false"
    printf '%s\t%s\t%s\n' "$work/data/netfs" "/dst/d" "false"
  }

  classify_stack_binds "mystack"

  assert_eq "$EXCLUDED_BINDS_COUNT" "1" "excluded (BIND_IGNORE) counted once per unique source"
  assert_eq "$NETWORK_BINDS_COUNT" "1" "excluded (network-fs) counted once per unique source"
  assert_eq "$BIND_COUNT" "0" "nothing captured"

  rm -rf "$work"
}

run_tests
