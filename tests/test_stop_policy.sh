#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals/stub functions read/invoked indirectly by sourced lib.sh/docker-backup.sh
# =============================================================================
# tests/test_stop_policy.sh — per-stack NO_STOP_STACKS stop policy (Phase 7B):
# stack_stop_policy() precedence/hit-tracking (lib.sh) and its effect on
# backup_stack() (docker-backup.sh): a hot (NO_STOP_STACKS) stack never calls
# docker compose stop/start or arms the restart guard, reports zero downtime
# and docker_backup_stack_stopped=0, and writes consistency.stopped=false —
# while still building and delivering a valid archive. The cold (default)
# path is unchanged. Docker is stubbed as a bash function (no daemon).
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/harness.sh
source ./harness.sh
# shellcheck source=tests/stub_lib.sh
source ./stub_lib.sh

# Shared setup: a stack with one bind mount, no named volumes, a real compose
# file, a `docker` stub that FAILS the test if compose stop/start is ever
# invoked (individual tests override this when they expect the cold path),
# and push_stack_metrics()/CAPTURED_METRICS capturing every arg for
# inspection instead of actually pushing anything.
_setup() {
  local work="$1"
  mkdir -p "$work/data/bind1" "$work/compose"
  echo "services: {}" > "$work/compose/docker-compose.yml"

  load_docker_backup "$work"
  REPO_DIR="$REPO_ROOT"
  stub_bind_helpers

  NODE_NAME="testnode"
  DOCKER_BACKUP_DIR="$work/backups"
  RETENTION_DAYS=7
  STOP_TIMEOUT=10
  CONFIG_DIR="$work/config"
  mkdir -p "$DOCKER_BACKUP_DIR" "$CONFIG_DIR"
  unset DEST_URL 2>/dev/null || true

  VOL_LINES=(); CAPTURE_BINDS=(); EXCLUDED_BINDS=(); COMPOSE_FILE_ENTRIES=()
  BIND_IGNORE=(); BIND_INCLUDE_NETFS=(); NO_STOP_STACKS=()
  declare -gA NO_STOP_STACKS_HITS=()
  FAILED_STACKS=0
  STACK_TARGETS_TOTAL=0; STACK_TARGETS_OK=0; STACK_ALL_TARGETS_OK=0
  RESTART_GUARD_STACK=""; RESTART_GUARD_WD=""; RESTART_GUARD_CF=""

  stack_volumes() { :; }
  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/data/bind1" "/dst/bind1" "false"; }
  stack_compose_context() { printf '%s\t%s\n' "$work/compose" "$work/compose/docker-compose.yml"; }
  stack_compose_files() { printf '%s\n' "$work/compose/docker-compose.yml"; }

  CAPTURED_METRICS=()
  push_stack_metrics() { CAPTURED_METRICS=( "$@" ); }

  # shellcheck disable=SC2317
  docker() {
    if [[ "$1" == "compose" ]]; then
      local action="${*: -3:1}"
      case "$action" in
        stop|start) fail "docker compose $action must not be called for a hot (NO_STOP_STACKS) backup" ;;
      esac
    fi
    return 0
  }
}

# A trivially-"succeeding" azure compat target so delivery can be asserted
# without a real network/daemon (same trick as test_backup_stack_failures.sh).
_stub_delivery() {
  DEST_URL="https://fake.blob.core.windows.net/container"
  # shellcheck disable=SC2317
  azcopy() { echo "Number of Transfers Failed: 0"; return 0; }
}

test_no_stop_stacks_skips_stop_and_start() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  stub_tar_as_gtar
  _stub_delivery
  NO_STOP_STACKS=( "mystack" )

  backup_stack "mystack"

  assert_eq "$FAILED_STACKS" "0" "hot backup is not counted as failed"
  assert_eq "$STACK_ALL_TARGETS_OK" "1" "hot backup still delivers its archive"
  assert_eq "$RESTART_GUARD_STACK" "" "restart guard is never armed for a hot backup"
  assert_file_exists "$BACKUP_FILE" "hot backup still produces an archive file"

  assert_eq "${CAPTURED_METRICS[7]:-}" "0" "downtime is 0 for a hot backup"
  assert_eq "${CAPTURED_METRICS[9]:-}" "0" "docker_backup_stack_stopped=0 for a hot backup"

  local manifest
  manifest="$($TAR -xzOf "$BACKUP_FILE" manifest.json 2>/dev/null)"
  echo "$manifest" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["consistency"] == {"stopped": False}
'
  assert_status "$?" "0" "manifest records consistency.stopped=false for a hot backup"

  rm -rf "$work"
}

test_stack_not_in_no_stop_stacks_uses_cold_path() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  stub_tar_as_gtar
  _stub_delivery
  NO_STOP_STACKS=()

  local stop_called=0 start_called=0
  # shellcheck disable=SC2317
  docker() {
    if [[ "$1" == "compose" ]]; then
      local action="${*: -3:1}"
      case "$action" in
        stop) stop_called=1 ;;
        start) start_called=1 ;;
      esac
    fi
    return 0
  }

  backup_stack "mystack"

  assert_eq "$stop_called" "1" "cold (default) path still calls docker compose stop"
  assert_eq "$start_called" "1" "cold (default) path still calls docker compose start"
  assert_eq "$RESTART_GUARD_STACK" "" "restart guard is cleared again after a normal cold run"
  assert_eq "$FAILED_STACKS" "0" "cold backup is not counted as failed"
  assert_eq "${CAPTURED_METRICS[9]:-}" "1" "docker_backup_stack_stopped=1 for the cold (default) path"

  local manifest
  manifest="$($TAR -xzOf "$BACKUP_FILE" manifest.json 2>/dev/null)"
  echo "$manifest" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["consistency"] == {"stopped": True}
'
  assert_status "$?" "0" "manifest records consistency.stopped=true for the cold (default) path"

  rm -rf "$work"
}

test_stack_stop_policy_glob_match_and_hit_tracking() {
  # Unit-level: the shared lib.sh precedence decision itself, independent of
  # backup_stack() -- mirrors test_bind_classification.sh's style for
  # bind_capture_verdict.
  local work; work="$(mktemp -d)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib.sh"

  NO_STOP_STACKS=( "prod-*" "unused-stack" )
  declare -A NO_STOP_STACKS_HITS=()

  stack_stop_policy "prod-web"
  assert_eq "$STOP_POLICY" "no-stop" "glob entry matches"
  assert_eq "${NO_STOP_STACKS_HITS[0]:-}" "1" "hit recorded for the matching glob entry"
  assert_eq "${NO_STOP_STACKS_HITS[1]:-}" "" "the unrelated entry is not hit by this match"

  stack_stop_policy "otherstack"
  assert_eq "$STOP_POLICY" "stop" "no match falls back to stop (default)"

  rm -rf "$work"
}

test_stale_no_stop_stacks_entry_warns() {
  local work; work="$(mktemp -d)"
  _setup "$work"

  NO_STOP_STACKS=( "neverused" )
  declare -gA NO_STOP_STACKS_HITS=()
  NO_STOP_STACKS_HITS[0]=""

  local logged=""
  # shellcheck disable=SC2317
  log() { logged+="$*"$'\n'; }

  # A run where "neverused" never matches any stack being backed up.
  stack_stop_policy "mystack" >/dev/null

  warn_stale_no_stop_stacks

  assert_contains "$logged" "stale NO_STOP_STACKS entry" "a NO_STOP_STACKS entry that matched nothing is reported"
  assert_contains "$logged" "neverused" "the stale-entry warning names the actual entry"

  rm -rf "$work"
}

run_tests
