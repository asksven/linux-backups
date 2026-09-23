#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals/stub functions read/invoked indirectly by sourced lib.sh/docker-backup.sh
# =============================================================================
# tests/test_local_only.sh — LOCAL_ONLY mode (Phase 7A) in backup_stack()
# (docker-backup.sh): with LOCAL_ONLY=true, target delivery is skipped
# entirely (no ERROR, STACK_ALL_TARGETS_OK=1) and the archive stays in
# DOCKER_BACKUP_DIR; with LOCAL_ONLY=false (the default) and zero configured
# targets, the existing "no targets configured" ERROR is unchanged. Docker is
# stubbed as a bash function (no daemon).
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/harness.sh
source ./harness.sh
# shellcheck source=tests/stub_lib.sh
source ./stub_lib.sh

# Shared setup: a stack with one bind mount, no named volumes, a real compose
# file, zero configured targets (no $CONFIG_DIR/targets/*.conf, no DEST_URL),
# and a `docker` stub that always succeeds compose stop/start.
_setup() {
  local work="$1"
  mkdir -p "$work/data/bind1" "$work/compose" "$work/config"
  echo "services: {}" > "$work/compose/docker-compose.yml"

  load_docker_backup "$work"
  REPO_DIR="$REPO_ROOT"
  stub_bind_helpers
  stub_tar_as_gtar

  NODE_NAME="testnode"
  DOCKER_BACKUP_DIR="$work/backups"
  RETENTION_DAYS=7
  STOP_TIMEOUT=10
  CONFIG_DIR="$work/config"
  mkdir -p "$DOCKER_BACKUP_DIR"
  unset DEST_URL 2>/dev/null || true
  LOCAL_ONLY="false"

  VOL_LINES=(); CAPTURE_BINDS=(); EXCLUDED_BINDS=(); COMPOSE_FILE_ENTRIES=()
  BIND_IGNORE=(); BIND_INCLUDE_NETFS=(); NO_STOP_STACKS=()
  FAILED_STACKS=0
  STACK_TARGETS_TOTAL=0; STACK_TARGETS_OK=0; STACK_ALL_TARGETS_OK=0
  RESTART_GUARD_STACK=""; RESTART_GUARD_WD=""; RESTART_GUARD_CF=""

  stack_volumes() { :; }
  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/data/bind1" "/dst/bind1" "false"; }
  stack_compose_context() { printf '%s\t%s\n' "$work/compose" "$work/compose/docker-compose.yml"; }
  stack_compose_files() { printf '%s\n' "$work/compose/docker-compose.yml"; }

  # shellcheck disable=SC2317
  docker() {
    if [[ "$1" == "compose" ]]; then
      local action="${*: -3:1}"
      case "$action" in
        stop|start) return 0 ;;
      esac
    fi
    return 0
  }
}

test_local_only_skips_delivery_and_succeeds() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  LOCAL_ONLY="true"

  # shellcheck disable=SC2317
  send_stack_to_targets() { fail "send_stack_to_targets must not be called when LOCAL_ONLY=true"; }
  local logged=""
  # shellcheck disable=SC2317
  log() { logged+="$*"$'\n'; }

  backup_stack "mystack"

  assert_eq "$STACK_ALL_TARGETS_OK" "1" "local-only mode reports STACK_ALL_TARGETS_OK=1 (no phantom delivery failure)"
  assert_eq "$STACK_TARGETS_TOTAL" "0" "local-only mode records zero delivery attempts"
  assert_eq "$FAILED_STACKS" "0" "local-only mode is not counted as a failed stack"
  assert_not_contains "$logged" "ERROR" "local-only mode logs no ERROR"
  assert_file_exists "$BACKUP_FILE" "archive is retained locally"
  local kept; kept="$(find "$DOCKER_BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' | wc -l | tr -d ' ')"
  assert_eq "$kept" "1" "exactly one tarball is left in DOCKER_BACKUP_DIR"

  rm -rf "$work"
}

test_local_only_false_with_zero_targets_still_errors() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  LOCAL_ONLY="false"

  local logged=""
  # shellcheck disable=SC2317
  log() { logged+="$*"$'\n'; }

  backup_stack "mystack"

  assert_contains "$logged" "no targets configured" "zero targets without LOCAL_ONLY still reports the existing ERROR"
  assert_eq "$STACK_ALL_TARGETS_OK" "0" "zero targets without LOCAL_ONLY still reports delivery as failed"
  assert_file_exists "$BACKUP_FILE" "the archive is still built even though delivery is reported as failed"

  rm -rf "$work"
}

test_local_only_with_failed_archive_reports_no_valid_archive() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  LOCAL_ONLY="true"
  # shellcheck disable=SC2317
  tar() { return 2; }

  # shellcheck disable=SC2317
  send_stack_to_targets() { fail "send_stack_to_targets must not be called when LOCAL_ONLY=true"; }
  local logged=""
  # shellcheck disable=SC2317
  log() { logged+="$*"$'\n'; }

  backup_stack "mystack"

  assert_not_contains "$logged" "archive retained" "local-only mode must not claim retention when no valid archive exists"
  assert_contains "$logged" "no valid archive to retain" "local-only mode reports the failure explicitly instead of a phantom success"
  assert_eq "$STACK_ALL_TARGETS_OK" "0" "local-only mode with a failed archive is not reported as delivered"

  rm -rf "$work"
}

run_tests
