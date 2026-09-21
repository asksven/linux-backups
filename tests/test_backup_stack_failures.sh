#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals/stub functions read/invoked indirectly by sourced lib.sh/docker-backup.sh
# =============================================================================
# tests/test_backup_stack_failures.sh — backup_stack() failure modes
# (docker-backup.sh): compose stop failure, archive/tar failure after a
# successful stop, restart failure with an otherwise-valid delivery, and the
# restart guard safety net. Docker is stubbed as a bash function (no daemon).
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/harness.sh
source ./harness.sh
# shellcheck source=tests/stub_lib.sh
source ./stub_lib.sh

# Shared setup: a stack with one bind mount, no named volumes, a real compose
# file, and a `docker` stub controlled by STUB_STOP_RC/STUB_START_RC.
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
  BIND_IGNORE=(); BIND_INCLUDE_NETFS=()
  FAILED_STACKS=0
  STACK_TARGETS_TOTAL=0; STACK_TARGETS_OK=0; STACK_ALL_TARGETS_OK=0

  stack_volumes() { :; }
  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/data/bind1" "/dst/bind1" "false"; }
  stack_compose_context() { printf '%s\t%s\n' "$work/compose" "$work/compose/docker-compose.yml"; }
  stack_compose_files() { printf '%s\n' "$work/compose/docker-compose.yml"; }

  STUB_STOP_RC=0
  STUB_START_RC=0
  # `docker compose --project-name S --project-directory WD -f F <action> -t N`
  # -- the action is always 3rd-from-last positional arg in that call shape.
  docker() {
    if [[ "$1" == "compose" ]]; then
      local action="${*: -3:1}"
      case "$action" in
        stop) return "$STUB_STOP_RC" ;;
        start) return "$STUB_START_RC" ;;
      esac
    fi
    return 0
  }
}

test_stop_failure_skips_archive_and_delivery() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  STUB_STOP_RC=1
  # shellcheck disable=SC2317
  send_stack_to_targets() { fail "send_stack_to_targets must not be called on stop failure"; }

  backup_stack "mystack"

  assert_eq "$FAILED_STACKS" "1" "stop failure counts the stack as failed"
  assert_not_exists "$DOCKER_BACKUP_DIR"/*.tar.gz "no archive is produced when stop fails"

  rm -rf "$work"
}

test_stop_failure_does_not_emit_misleading_stack_stopped_metric() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  STUB_STOP_RC=1
  local captured_body=""
  # shellcheck disable=SC2317
  pushgateway_post() { captured_body="$2"; }

  backup_stack "mystack"

  assert_not_contains "$captured_body" "docker_backup_stack_stopped" "no archive exists after a failed stop; the consistency metric must not be pushed"

  rm -rf "$work"
}

test_validation_failure_does_not_emit_misleading_stack_stopped_metric() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  # A bind source that does not exist on disk makes validate_stack_inputs fail
  # (unresolved kind) before any stop is attempted.
  # shellcheck disable=SC2317
  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/does-not-exist" "/dst/bind1" "false"; }
  local captured_body=""
  # shellcheck disable=SC2317
  pushgateway_post() { captured_body="$2"; }

  backup_stack "mystack"

  assert_not_contains "$captured_body" "docker_backup_stack_stopped" "no archive exists after failed validation; the consistency metric must not be pushed"

  rm -rf "$work"
}

test_successful_cold_backup_emits_stack_stopped_metric() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  stub_tar_as_gtar
  local captured_body=""
  # shellcheck disable=SC2317
  pushgateway_post() { captured_body="$2"; }
  DEST_URL="https://fake.blob.core.windows.net/container"
  # shellcheck disable=SC2317
  azcopy() { echo "Number of Transfers Failed: 0"; return 0; }

  backup_stack "mystack"

  assert_contains "$captured_body" "docker_backup_stack_stopped 1" "a successful cold archive still reports its achieved consistency"

  rm -rf "$work"
}

test_stop_failure_still_attempts_restart() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  STUB_STOP_RC=1
  local start_called=0
  # shellcheck disable=SC2317
  docker() {
    if [[ "$1" == "compose" ]]; then
      local action="${*: -3:1}"
      case "$action" in
        stop) return "$STUB_STOP_RC" ;;
        start) start_called=1; return "$STUB_START_RC" ;;
      esac
    fi
    return 0
  }
  # shellcheck disable=SC2317
  send_stack_to_targets() { fail "send_stack_to_targets must not be called on stop failure"; }

  backup_stack "mystack"

  assert_eq "$start_called" "1" "a best-effort restart is still attempted after a failed stop"
  assert_eq "$RESTART_GUARD_STACK" "" "restart guard is cleared again after the attempted restart"
  assert_eq "$FAILED_STACKS" "1" "stop failure still counts the stack as failed overall"

  rm -rf "$work"
}

test_restart_guard_armed_before_stop_is_attempted() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  stub_tar_as_gtar

  # The guard must already be armed with THIS stack's identity by the time
  # `docker compose stop` runs -- not only after stop returns success -- so
  # an interruption during the stop call itself is still covered.
  local guard_during_stop=""
  # shellcheck disable=SC2317
  docker() {
    if [[ "$1" == "compose" ]]; then
      local action="${*: -3:1}"
      [[ "$action" == "stop" ]] && guard_during_stop="$RESTART_GUARD_STACK"
      case "$action" in
        stop) return "$STUB_STOP_RC" ;;
        start) return "$STUB_START_RC" ;;
      esac
    fi
    return 0
  }

  DEST_URL="https://fake.blob.core.windows.net/container"
  # shellcheck disable=SC2317
  azcopy() { echo "Number of Transfers Failed: 0"; return 0; }

  backup_stack "mystack"

  assert_eq "$guard_during_stop" "mystack" "restart guard is armed before docker compose stop is invoked"
  assert_eq "$RESTART_GUARD_STACK" "" "restart guard is cleared again once the run completes"

  rm -rf "$work"
}

test_tar_failure_after_successful_stop_skips_delivery() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  # shellcheck disable=SC2317
  tar() { return 2; }
  # shellcheck disable=SC2317
  send_stack_to_targets() { fail "send_stack_to_targets must not be called when the archive failed"; }

  backup_stack "mystack"

  assert_eq "$FAILED_STACKS" "1" "tar failure after a successful stop still counts the stack as failed"
  assert_not_exists "$DOCKER_BACKUP_DIR"/*.tar.gz "no surviving archive when tar fails"

  rm -rf "$work"
}

test_restart_failure_still_delivers_valid_archive() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  stub_tar_as_gtar
  STUB_START_RC=1

  # A trivially-"succeeding" azure compat target so delivery can be proven
  # independent of restart outcome, without a real network/daemon.
  DEST_URL="https://fake.blob.core.windows.net/container"
  # shellcheck disable=SC2317
  azcopy() { echo "Number of Transfers Failed: 0"; return 0; }

  backup_stack "mystack"

  assert_eq "$STACK_ALL_TARGETS_OK" "1" "archive is still delivered despite the restart failure"
  assert_eq "$FAILED_STACKS" "1" "restart failure still marks the overall stack run as failed"

  rm -rf "$work"
}

test_restart_guard_restarts_and_clears_itself() {
  local work; work="$(mktemp -d)"
  _setup "$work"

  local guard_start_called=0
  # shellcheck disable=SC2317
  docker() {
    if [[ "$1" == "compose" ]]; then
      local action="${*: -3:1}"
      [[ "$action" == "start" ]] && guard_start_called=1
    fi
    return 0
  }

  RESTART_GUARD_STACK="mystack"
  RESTART_GUARD_WD="$work/compose"
  RESTART_GUARD_CF="$work/compose/docker-compose.yml"

  restart_guard_run

  assert_eq "$guard_start_called" "1" "restart_guard_run invokes a start via _compose_action"
  assert_eq "$RESTART_GUARD_STACK" "" "restart_guard_run clears RESTART_GUARD_STACK after running"

  rm -rf "$work"
}

test_restart_guard_noop_when_unarmed() {
  local work; work="$(mktemp -d)"
  _setup "$work"

  # shellcheck disable=SC2317
  docker() { fail "docker should not be invoked when the restart guard is unarmed"; }

  RESTART_GUARD_STACK=""
  restart_guard_run

  rm -rf "$work"
}

run_tests
