#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals/stub functions read/invoked indirectly by sourced lib.sh/docker-backup-init.sh
# =============================================================================
# tests/test_init_writer.sh — docker-backup-init.sh config writer (Phase 7
# follow-up, must-fix 51/52/53): BIND_IGNORE and NO_STOP_STACKS suggestions
# are heuristics (shared/likely-transient bind sources; "no known database
# signature found") and must never be auto-appended by --write/--yes unless
# the caller explicitly opts in via --apply-bind-ignore/--apply-stop-policy.
# Also covers the reconcile early-return bug: a config with no unmanaged
# stacks but pending, opted-in suggestions must still be written to (and
# left alone when nothing is opted in) rather than reported as "in sync".
# Docker is stubbed as a bash function (no daemon).
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/harness.sh
source ./harness.sh
# shellcheck source=tests/stub_lib.sh
source ./stub_lib.sh

# Shared setup: one discovered stateful stack "sonarr" with a single bind
# mount at a likely-transient path (so suggest_bind_ignore proposes excluding
# it) and no detected database signature (so suggest_stop_policy proposes
# NO_STOP_STACKS for it). The real lib.sh bind_capture_verdict/
# stack_stop_policy run unstubbed -- only the docker-facing discovery
# primitives are stubbed.
_setup() {
  local work="$1"
  load_docker_backup_init "$work"
  mkdir -p "$work/conf"
  cp "$REPO_ROOT/conf/docker-backup.example.conf" "$work/conf/docker-backup.example.conf"
  # A real, readable, empty bind root so _stack_looks_stateful_db's scan is
  # conclusive (no signature found) rather than conservatively treating a
  # missing/unreadable root as "looks like a database" (see
  # test_stop_policy_suggestion_is_conservative_about_unreadable_bind_roots).
  mkdir -p "$work/data/cache"

  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"

  # shellcheck disable=SC2317
  require_docker() { :; }
  # shellcheck disable=SC2317
  require_root() { :; }
  # shellcheck disable=SC2317
  discover_compose_projects() { printf 'sonarr\n'; }
  # shellcheck disable=SC2317
  stack_is_stateful() { [[ "$1" == "sonarr" ]]; }
  # shellcheck disable=SC2317
  stack_volumes() { :; }
  # shellcheck disable=SC2317
  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/data/cache" "/config" "false"; }
  # shellcheck disable=SC2317
  stack_containers() { printf 'cid1\n'; }
  # shellcheck disable=SC2317
  docker() {
    if [[ "$1" == "inspect" ]]; then echo "example/sonarr:latest"; fi
  }
}

test_bootstrap_write_default_does_not_apply_suggestions() {
  local work; work="$(mktemp -d)"
  _setup "$work"

  main --write

  local conf="$CONFIG_DIR/docker-backup.conf"
  assert_file_exists "$conf" "--write creates the config from the template"
  local content; content="$(cat "$conf")"
  assert_contains "$content" 'STACKS+=( sonarr )' "the discovered stateful stack is still added by --write"
  assert_not_contains "$content" 'BIND_IGNORE+=' "BIND_IGNORE suggestions are not applied without --apply-bind-ignore"
  assert_not_contains "$content" 'NO_STOP_STACKS+=' "NO_STOP_STACKS suggestions are not applied without --apply-stop-policy"

  rm -rf "$work"
}

test_bootstrap_write_with_apply_flags_applies_suggestions() {
  local work; work="$(mktemp -d)"
  _setup "$work"

  main --write --apply-bind-ignore --apply-stop-policy

  local conf="$CONFIG_DIR/docker-backup.conf"
  local content; content="$(cat "$conf")"
  assert_contains "$content" 'STACKS+=( sonarr )' "the discovered stateful stack is added"
  assert_contains "$content" "BIND_IGNORE+=( $work/data/cache )" "--apply-bind-ignore applies the bind-ignore suggestion"
  assert_contains "$content" 'NO_STOP_STACKS+=( sonarr )' "--apply-stop-policy applies the stop-policy suggestion"

  rm -rf "$work"
}

test_reconcile_suggestion_only_requires_opt_in() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  local conf="$CONFIG_DIR/docker-backup.conf"
  cat > "$conf" <<'EOF'
STACKS=( "sonarr" )
EOF
  local before; before="$(cat "$conf")"

  main --write

  assert_eq "$(cat "$conf")" "$before" "no changes are written when suggestions exist but are not opted in"
  local baks; baks="$(find "$CONFIG_DIR" -maxdepth 1 -name '*.bak-*' | wc -l | tr -d ' ')"
  assert_eq "$baks" "0" "no backup file is created when nothing is actually written"

  rm -rf "$work"
}

test_reconcile_suggestion_only_applies_with_opt_in() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  local conf="$CONFIG_DIR/docker-backup.conf"
  cat > "$conf" <<'EOF'
STACKS=( "sonarr" )
EOF

  main --write --apply-bind-ignore --apply-stop-policy

  local content; content="$(cat "$conf")"
  assert_contains "$content" "BIND_IGNORE+=( $work/data/cache )" "opted-in bind-ignore suggestion is appended even with no unmanaged stacks"
  assert_contains "$content" 'NO_STOP_STACKS+=( sonarr )' "opted-in stop-policy suggestion is appended even with no unmanaged stacks"
  local hdr_count; hdr_count="$(grep -c '^# --- added by docker-backup-init.sh on ' "$conf")"
  assert_eq "$hdr_count" "1" "all suggestion-only additions land under a single dated block"
  local baks; baks="$(find "$CONFIG_DIR" -maxdepth 1 -name '*.bak-*' | wc -l | tr -d ' ')"
  assert_eq "$baks" "1" "a backup is created when a suggestion-only change is actually written"

  rm -rf "$work"
}

test_reconcile_does_not_duplicate_already_applied_suggestions() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  local conf="$CONFIG_DIR/docker-backup.conf"
  cat > "$conf" <<'EOF'
STACKS=( "sonarr" )
EOF

  main --write --apply-bind-ignore --apply-stop-policy
  main --write --apply-bind-ignore --apply-stop-policy

  local content; content="$(cat "$conf")"
  local bind_count; bind_count="$(grep -c 'BIND_IGNORE+=' "$conf")"
  local stop_count; stop_count="$(grep -c 'NO_STOP_STACKS+=' "$conf")"
  assert_eq "$bind_count" "1" "a suggestion already present in BIND_IGNORE is not re-suggested/re-appended"
  assert_eq "$stop_count" "1" "a stack already in NO_STOP_STACKS is not re-suggested/re-appended"

  rm -rf "$work"
}

test_reconcile_reports_no_additions_when_only_gone_entries_exist() {
  local work; work="$(mktemp -d)"
  load_docker_backup_init "$work"
  mkdir -p "$work/conf"
  cp "$REPO_ROOT/conf/docker-backup.example.conf" "$work/conf/docker-backup.example.conf"
  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"

  # shellcheck disable=SC2317
  require_docker() { :; }
  # shellcheck disable=SC2317
  require_root() { :; }
  # shellcheck disable=SC2317
  discover_compose_projects() { printf 'sonarr\n'; }
  # shellcheck disable=SC2317
  stack_is_stateful() { return 1; }
  # shellcheck disable=SC2317
  stack_volumes() { :; }
  # shellcheck disable=SC2317
  stack_bind_mounts() { :; }
  # shellcheck disable=SC2317
  stack_containers() { :; }

  local conf="$CONFIG_DIR/docker-backup.conf"
  cat > "$conf" <<'EOF'
STACKS=( "sonarr" "longgone" )
EOF
  local before; before="$(cat "$conf")"

  local logged=""
  # shellcheck disable=SC2317
  log() { logged+="$*"$'\n'; }

  main --write

  assert_contains "$logged" "no additions to make" "a config with only stale (GONE) entries and no suggestions is not reported as fully in sync"
  assert_not_contains "$logged" "config is in sync" "the misleading in-sync message is not printed when stale entries exist"
  assert_eq "$(cat "$conf")" "$before" "nothing is written when there is nothing to add"

  rm -rf "$work"
}

test_stop_policy_suggestion_is_conservative_about_unreadable_bind_roots() {
  local work; work="$(mktemp -d)"
  load_docker_backup_init "$work"
  mkdir -p "$work/conf"
  cp "$REPO_ROOT/conf/docker-backup.example.conf" "$work/conf/docker-backup.example.conf"
  CONFIG_DIR="$work/config"
  mkdir -p "$CONFIG_DIR"

  # shellcheck disable=SC2317
  require_docker() { :; }
  # shellcheck disable=SC2317
  require_root() { :; }
  # shellcheck disable=SC2317
  discover_compose_projects() { printf 'sonarr\n'; }
  # shellcheck disable=SC2317
  stack_is_stateful() { [[ "$1" == "sonarr" ]]; }
  # shellcheck disable=SC2317
  stack_volumes() { :; }
  # A bind root that does not exist on disk: the scan for a database
  # signature can't rule anything out, so this must NOT be suggested for
  # NO_STOP_STACKS (see must-fix 52 / should-fix in the Phase 7 follow-up).
  # shellcheck disable=SC2317
  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/does-not-exist" "/config" "false"; }
  # shellcheck disable=SC2317
  stack_containers() { :; }

  main --write --apply-stop-policy

  local conf="$CONFIG_DIR/docker-backup.conf"
  local content; content="$(cat "$conf")"
  assert_not_contains "$content" 'NO_STOP_STACKS+=' "a stack with an unscannable bind root is never proposed for hot backup"

  rm -rf "$work"
}

test_reconcile_report_echoes_loaded_no_stop_stacks() {
  local work; work="$(mktemp -d)"
  _setup "$work"
  local conf="$CONFIG_DIR/docker-backup.conf"
  cat > "$conf" <<'EOF'
STACKS=( "sonarr" )
NO_STOP_STACKS=( "sonarr" )
EOF

  local output; output="$(main --write 2>&1)"

  assert_contains "$output" "hot backup stacks (NO_STOP_STACKS): sonarr" "the reconcile report echoes the loaded NO_STOP_STACKS so a config that failed to load is immediately visible"

  rm -rf "$work"
}

run_tests
