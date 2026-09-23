#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals/stub functions read/invoked indirectly by sourced lib.sh/docker-backup.sh
# =============================================================================
# tests/test_config_validation.sh — docker-backup.sh load_config() (Phase 7
# follow-up, should-fix 58): LOCAL_ONLY must be exactly "true"/"false" and
# NO_STOP_STACKS must be an indexed array; a bad value in docker-backup.conf
# fails load_config() with a clear error instead of being silently
# misinterpreted (e.g. a typo like LOCAL_ONLY=TRUE, or a scalar
# NO_STOP_STACKS="mystack").
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/harness.sh
source ./harness.sh
# shellcheck source=tests/stub_lib.sh
source ./stub_lib.sh

_setup() {
  local work="$1"
  load_docker_backup "$work"
  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"
  : > "$CONFIG_DIR/secrets.env"
  # The umask-default mode load_config now rejects; permission-specific tests
  # chmod it explicitly to whatever they want to assert on.
  chmod 600 "$CONFIG_DIR/secrets.env"
}

test_load_config_rejects_invalid_local_only_value() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
LOCAL_ONLY=TRUE
EOF

  local rc=0
  ( load_config ) >/dev/null 2>&1 || rc=$?
  assert_status "$rc" "1" "an invalid LOCAL_ONLY value is rejected instead of silently accepted"

  rm -rf "$work"
}

test_load_config_accepts_valid_local_only_values() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
LOCAL_ONLY=true
EOF

  local rc=0
  ( load_config ) >/dev/null 2>&1 || rc=$?
  assert_status "$rc" "0" "a valid LOCAL_ONLY value loads without error"

  rm -rf "$work"
}

test_load_config_rejects_non_array_no_stop_stacks() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
NO_STOP_STACKS="mystack"
EOF

  local rc=0
  ( load_config ) >/dev/null 2>&1 || rc=$?
  assert_status "$rc" "1" "a scalar NO_STOP_STACKS is rejected instead of silently misbehaving"

  rm -rf "$work"
}

test_load_config_accepts_indexed_array_no_stop_stacks() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
NO_STOP_STACKS=( "mystack" )
EOF

  local rc=0
  ( load_config ) >/dev/null 2>&1 || rc=$?
  assert_status "$rc" "0" "a valid NO_STOP_STACKS array loads without error"

  rm -rf "$work"
}

test_load_config_local_only_true_without_secrets_loads() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  rm -f "$CONFIG_DIR/secrets.env"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
LOCAL_ONLY=true
EOF

  local rc=0
  ( load_config ) >/dev/null 2>&1 || rc=$?
  assert_status "$rc" "0" "LOCAL_ONLY=true loads with no secrets.env present"

  rm -rf "$work"
}

test_load_config_non_local_only_without_secrets_exits() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  rm -f "$CONFIG_DIR/secrets.env"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
LOCAL_ONLY=false
EOF

  local rc=0
  ( load_config ) >/dev/null 2>&1 || rc=$?
  assert_status "$rc" "1" "a missing secrets.env is still fatal without LOCAL_ONLY=true"

  rm -rf "$work"
}

test_load_config_unreadable_secrets_is_always_fatal() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  echo 'PROM_GTW="x"' > "$CONFIG_DIR/secrets.env"
  chmod 000 "$CONFIG_DIR/secrets.env"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
LOCAL_ONLY=true
EOF

  # chmod 000 has no effect for root; skip rather than false-fail under root.
  if [[ "$(id -u)" -ne 0 ]]; then
    local rc=0
    ( load_config ) >/dev/null 2>&1 || rc=$?
    assert_status "$rc" "1" "an existing but unreadable secrets.env is fatal even under LOCAL_ONLY=true"
  fi
  chmod 600 "$CONFIG_DIR/secrets.env"

  rm -rf "$work"
}

test_load_config_docker_backup_conf_overrides_secrets_env() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  echo 'PROM_GTW="from-secrets"' > "$CONFIG_DIR/secrets.env"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
PROM_GTW="from-conf"
EOF

  load_config
  assert_eq "$PROM_GTW" "from-conf" "docker-backup.conf still overrides a value also set in secrets.env"

  rm -rf "$work"
}

test_load_config_fails_hard_on_world_readable_secrets_env() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  chmod 644 "$CONFIG_DIR/secrets.env"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
LOCAL_ONLY=true
EOF

  # load_config -> load_secrets calls exit directly on an insecure mode; run
  # it inside a command substitution so only that inner shell exits, not this
  # test function's own subshell (same gotcha as the missing-secrets tests).
  local output rc=0
  output="$( ( load_config ) 2>&1 )" || rc=$?

  assert_status "$rc" "1" "a group/other-readable secrets.env (holds live credentials) refuses to run rather than just warning"
  assert_contains "$output" "readable by group/other" "the error explains why it refused"
  assert_contains "$output" "chmod 600" "the error tells the operator exactly how to fix it"

  rm -rf "$work"
}

test_load_config_no_error_for_strict_secrets_env_permissions() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  chmod 600 "$CONFIG_DIR/secrets.env"
  cat > "$CONFIG_DIR/docker-backup.conf" <<'EOF'
LOCAL_ONLY=true
EOF

  local logged=""
  # shellcheck disable=SC2317
  log() { logged+="$*"$'\n'; }

  load_config

  assert_not_contains "$logged" "readable by group/other" "a strictly-permissioned (600) secrets.env is not flagged"

  rm -rf "$work"
}

run_tests

