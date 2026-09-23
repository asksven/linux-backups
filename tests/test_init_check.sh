#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals/stub functions read/invoked indirectly by sourced lib.sh/docker-backup-init.sh
# =============================================================================
# tests/test_init_check.sh — docker-backup-init.sh --check (Phase 7C): a
# non-interactive, read-only drift check. Exits 0 when STACKS matches the
# discovered stateful compose projects, 1 when a running project is
# unmanaged or a configured stack is gone, and never writes to the config
# file either way. Docker is stubbed as bash functions (no daemon).
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/harness.sh
source ./harness.sh
# shellcheck source=tests/stub_lib.sh
source ./stub_lib.sh

test_check_exits_0_when_in_sync() {
  local work; work="$(mktemp -d)"
  load_docker_backup_init "$work"
  # shellcheck disable=SC2317
  discover_compose_projects() { printf 'sonarr\n'; }
  # shellcheck disable=SC2317
  stack_is_stateful() { [[ "$1" == "sonarr" ]]; }
  # shellcheck disable=SC2317
  require_docker() { :; }
  # shellcheck disable=SC2317
  require_root() { :; }

  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
STACKS=( "sonarr" )
EOF
  local before; before="$(cat "$CONFIG_DIR/docker-backup.conf")"

  local rc=0
  main --check || rc=$?
  assert_status "$rc" "0" "config matching the discovered stateful stacks exits 0"
  assert_eq "$(cat "$CONFIG_DIR/docker-backup.conf")" "$before" "--check never modifies the config file"

  rm -rf "$work"
}

test_check_exits_1_on_unmanaged_stack() {
  local work; work="$(mktemp -d)"
  load_docker_backup_init "$work"
  # shellcheck disable=SC2317
  discover_compose_projects() { printf 'sonarr\nhomepage\n'; }
  # shellcheck disable=SC2317
  stack_is_stateful() { [[ "$1" == "sonarr" || "$1" == "homepage" ]]; }
  # shellcheck disable=SC2317
  require_docker() { :; }
  # shellcheck disable=SC2317
  require_root() { :; }

  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
STACKS=( "sonarr" )
EOF
  local before; before="$(cat "$CONFIG_DIR/docker-backup.conf")"

  local rc=0
  main --check || rc=$?
  assert_status "$rc" "1" "a running-but-unmanaged stateful stack causes --check to exit 1"
  assert_eq "$(cat "$CONFIG_DIR/docker-backup.conf")" "$before" "--check never modifies the config file even on drift"

  rm -rf "$work"
}

test_check_exits_1_on_gone_stack() {
  local work; work="$(mktemp -d)"
  load_docker_backup_init "$work"
  # shellcheck disable=SC2317
  discover_compose_projects() { printf 'sonarr\n'; }
  # shellcheck disable=SC2317
  stack_is_stateful() { [[ "$1" == "sonarr" ]]; }
  # shellcheck disable=SC2317
  require_docker() { :; }
  # shellcheck disable=SC2317
  require_root() { :; }

  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
STACKS=( "sonarr" "longgone" )
EOF

  local rc=0
  main --check || rc=$?
  assert_status "$rc" "1" "a configured stack with no live project causes --check to exit 1"

  rm -rf "$work"
}

test_check_treats_missing_config_as_drift_even_with_no_live_projects() {
  local work; work="$(mktemp -d)"
  load_docker_backup_init "$work"
  # shellcheck disable=SC2317
  discover_compose_projects() { :; }
  # shellcheck disable=SC2317
  stack_is_stateful() { return 1; }
  # shellcheck disable=SC2317
  require_docker() { :; }
  # shellcheck disable=SC2317
  require_root() { :; }

  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"
  # No docker-backup.conf and nothing currently running either.

  local rc=0
  main --check || rc=$?
  assert_status "$rc" "1" "a missing config is drift even when nothing is currently running (docker-backup.sh cannot run without it)"

  rm -rf "$work"
}

test_check_treats_missing_config_as_fully_unmanaged() {
  local work; work="$(mktemp -d)"
  load_docker_backup_init "$work"
  # shellcheck disable=SC2317
  discover_compose_projects() { printf 'sonarr\n'; }
  # shellcheck disable=SC2317
  stack_is_stateful() { [[ "$1" == "sonarr" ]]; }
  # shellcheck disable=SC2317
  require_docker() { :; }
  # shellcheck disable=SC2317
  require_root() { :; }

  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"
  # No docker-backup.conf at all.

  local rc=0
  main --check || rc=$?
  assert_status "$rc" "1" "a missing config with a live stateful project exits 1"
  assert_not_exists "$CONFIG_DIR/docker-backup.conf" "--check never creates a config file"

  rm -rf "$work"
}

test_main_refuses_to_run_as_non_root() {
  local work; work="$(mktemp -d)"
  load_docker_backup_init "$work"
  # shellcheck disable=SC2317
  discover_compose_projects() { printf 'sonarr\n'; }
  # shellcheck disable=SC2317
  stack_is_stateful() { [[ "$1" == "sonarr" ]]; }
  # shellcheck disable=SC2317
  require_docker() { :; }

  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"

  # A root test process would trivially pass EUID -eq 0 -- skip rather than
  # false-pass, matching the chmod-000 guard used elsewhere in this suite.
  if [[ "$(id -u)" -ne 0 ]]; then
    local rc=0
    # main's exit 1 (via require_root) would otherwise terminate this test's
    # own subshell before assert_status runs -- wrap it like load_config's
    # tests do so only the inner subshell exits.
    ( main --check ) >/dev/null 2>&1 || rc=$?
    assert_status "$rc" "1" "main refuses to run without root instead of silently misreading CONFIG_DIR"
  fi

  rm -rf "$work"
}

test_check_fails_hard_on_world_readable_secrets_env() {
  local work; work="$(mktemp -d)"
  load_docker_backup_init "$work"
  # shellcheck disable=SC2317
  discover_compose_projects() { printf 'sonarr\n'; }
  # shellcheck disable=SC2317
  stack_is_stateful() { [[ "$1" == "sonarr" ]]; }
  # shellcheck disable=SC2317
  require_docker() { :; }
  # shellcheck disable=SC2317
  require_root() { :; }

  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
STACKS=( "sonarr" )
EOF
  : > "$CONFIG_DIR/secrets.env"
  chmod 644 "$CONFIG_DIR/secrets.env"

  # main's exit 1 would otherwise terminate this test's own subshell before
  # assert_status runs -- wrap it like the non-root test above.
  local output rc=0
  output="$( ( main --check ) 2>&1 )" || rc=$?

  assert_status "$rc" "1" "docker-backup-init.sh also refuses to run against a world-readable secrets.env, even though it never sources it"
  assert_contains "$output" "readable by group/other" "the error explains why it refused"
  assert_contains "$output" "chmod 600" "the error tells the operator exactly how to fix it"

  rm -rf "$work"
}

run_tests
