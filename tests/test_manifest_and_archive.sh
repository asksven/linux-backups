#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals/stub functions read/invoked indirectly by sourced lib.sh/docker-backup.sh
# =============================================================================
# tests/test_manifest_and_archive.sh — schema-2 manifest validity and archive
# construction (docker-backup.sh): empty volumes, bind-only stacks, empty
# directory binds, file binds, duplicate-source dedup at the archive level,
# compose basename collisions, missing compose/bind sources, and paths
# containing spaces.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/harness.sh
source ./harness.sh
# shellcheck source=tests/stub_lib.sh
source ./stub_lib.sh

_setup_common() {
  local work="$1"
  load_docker_backup "$work"
  REPO_DIR="$REPO_ROOT"
  stub_bind_helpers
  stub_tar_as_gtar
  NODE_NAME="testnode"
  DOCKER_BACKUP_DIR="$work/backups"
  mkdir -p "$DOCKER_BACKUP_DIR"
  VOL_LINES=()
  COMPOSE_FILE_ENTRIES=()
  CAPTURE_BINDS=()
  EXCLUDED_BINDS=()
  stack_compose_files() { :; }
}

test_manifest_schema2_valid_json() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/data/bind1"
  _setup_common "$work"

  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/data/bind1" "/dst/bind1" "false"; }
  classify_stack_binds "mystack"
  build_compose_file_entries "mystack"

  local manifest
  manifest="$(write_manifest "mystack" "/some/wd" "docker-compose.yml")"
  echo "$manifest" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("schema", "node", "stack", "timestamp", "epoch", "compose", "volumes", "binds", "excluded_binds"):
    assert k in d, f"missing top-level key: {k}"
assert d["schema"] == 2
for k in ("working_dir", "config_files", "captured_files"):
    assert k in d["compose"], f"missing compose.{k}"
assert len(d["binds"]) == 1
assert d["binds"][0]["kind"] == "directory"
assert len(d["binds"][0]["mounts"]) == 1
'
  assert_status "$?" "0" "manifest is valid schema-2 JSON with expected shape"

  rm -rf "$work"
}

test_empty_volumes_and_bind_only_stack() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/data/bind1"
  _setup_common "$work"

  # No named volumes at all -- a bind-only stack.
  VOL_LINES=()
  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/data/bind1" "/dst/bind1" "false"; }
  classify_stack_binds "mystack"

  if validate_stack_inputs "mystack"; then :; else fail "validate_stack_inputs should succeed with zero volumes"; fi
  assert_eq "$BIND_COUNT" "1" "bind-only stack still classifies its bind"

  local manifest
  manifest="$(write_manifest "mystack" "/wd" "docker-compose.yml")"
  echo "$manifest" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["volumes"] == []
assert len(d["binds"]) == 1
'
  assert_status "$?" "0" "manifest volumes[] is empty, binds[] still populated"

  rm -rf "$work"
}

test_empty_directory_bind_archives() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/data/emptydir"
  _setup_common "$work"

  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/data/emptydir" "/dst/e" "false"; }
  classify_stack_binds "mystack"
  validate_stack_inputs "mystack" >/dev/null

  build_stack_archive "mystack" "/wd" ""
  assert_eq "$TAR_RC" "0" "archive build succeeds for an empty directory bind"

  local listing
  listing="$($TAR -tzf "$BACKUP_FILE" 2>/dev/null)"
  assert_contains "$listing" "binds/0" "archive contains an entry for the empty directory bind"

  rm -rf "$work"
}

test_file_bind_archives() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/data"
  echo "hello file bind" > "$work/data/config.txt"
  _setup_common "$work"

  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/data/config.txt" "/dst/config.txt" "true"; }
  classify_stack_binds "mystack"
  validate_stack_inputs "mystack" >/dev/null

  build_stack_archive "mystack" "/wd" ""
  assert_eq "$TAR_RC" "0" "archive build succeeds for a file bind"

  local listing
  listing="$($TAR -tzf "$BACKUP_FILE" 2>/dev/null)"
  assert_contains "$listing" "binds/0/config.txt" "archive contains the file bind at its exact filename"

  local extract; extract="$(mktemp -d)"
  $TAR -xzf "$BACKUP_FILE" -C "$extract" "binds/0/config.txt"
  assert_file_content "$extract/binds/0/config.txt" "hello file bind" "extracted file bind content matches"
  rm -rf "$extract"

  rm -rf "$work"
}

test_duplicate_source_archived_once() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/data/shared"
  echo "shared content" > "$work/data/shared/f"
  _setup_common "$work"

  # Two different destinations, same source -- classify_stack_binds already
  # dedupes this to a single CAPTURE_BINDS entry (step 25); confirm the
  # archive itself only contains ONE binds/<id>/ set of entries for it.
  stack_bind_mounts() {
    printf '%s\t%s\t%s\n' "$work/data/shared" "/dst/a" "false"
    printf '%s\t%s\t%s\n' "$work/data/shared" "/dst/b" "true"
  }
  classify_stack_binds "mystack"
  assert_eq "$BIND_COUNT" "1" "duplicate source collapses to one CAPTURE_BINDS entry"
  validate_stack_inputs "mystack" >/dev/null

  build_stack_archive "mystack" "/wd" ""
  local listing count
  listing="$($TAR -tzf "$BACKUP_FILE" 2>/dev/null)"
  count="$(grep -c '^binds/0/f$' <<< "$listing" || true)"
  assert_eq "$count" "1" "shared source content appears exactly once in the archive"
  assert_not_contains "$listing" "binds/1/" "no second binds/1/ entry for the duplicate source"

  rm -rf "$work"
}

test_compose_basename_collision() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/a" "$work/b"
  echo "a-version" > "$work/a/docker-compose.yml"
  echo "b-version" > "$work/b/docker-compose.yml"
  _setup_common "$work"

  stack_compose_files() {
    printf '%s\n' "$work/a/docker-compose.yml"
    printf '%s\n' "$work/b/docker-compose.yml"
  }
  stack_bind_mounts() { :; }
  classify_stack_binds "mystack"
  if build_compose_file_entries "mystack"; then :; else fail "build_compose_file_entries should succeed"; fi

  assert_eq "${#COMPOSE_FILE_ENTRIES[@]}" "2" "both colliding compose files are kept"
  local first="${COMPOSE_FILE_ENTRIES[0]}" second="${COMPOSE_FILE_ENTRIES[1]}"
  assert_eq "${first%%$'\t'*}" "compose/docker-compose.yml" "first compose file keeps its plain basename"
  assert_contains "${second%%$'\t'*}" "-docker-compose.yml" "second (colliding) compose file gets an index-prefixed name"
  assert_ne "${first%%$'\t'*}" "${second%%$'\t'*}" "collision-renamed paths are distinct"

  build_stack_archive "mystack" "$work" "$work/a/docker-compose.yml,$work/b/docker-compose.yml"
  assert_eq "$TAR_RC" "0" "archive build succeeds with colliding compose basenames"
  local listing; listing="$($TAR -tzf "$BACKUP_FILE" 2>/dev/null)"
  assert_contains "$listing" "compose/docker-compose.yml" "archive has the first compose file"
  assert_contains "$listing" "-docker-compose.yml" "archive has the renamed, colliding compose file"

  rm -rf "$work"
}

test_missing_compose_source_fails_validation() {
  local work; work="$(mktemp -d)"
  _setup_common "$work"

  stack_compose_files() { printf '%s\n' "$work/does/not/exist.yml"; }
  stack_bind_mounts() { :; }
  classify_stack_binds "mystack"

  if validate_stack_inputs "mystack"; then
    fail "validate_stack_inputs should fail when a compose file is missing"
  fi

  rm -rf "$work"
}

test_missing_bind_source_fails_validation() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/data/willvanish"
  _setup_common "$work"

  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/data/willvanish" "/dst/x" "false"; }
  classify_stack_binds "mystack"
  rm -rf "$work/data/willvanish"

  if validate_stack_inputs "mystack"; then
    fail "validate_stack_inputs should fail when a bind source has disappeared"
  fi

  rm -rf "$work"
}

test_paths_with_spaces() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/data/my bind dir"
  echo "spacey content" > "$work/data/my bind dir/f"
  mkdir -p "$work/compose dir"
  echo "compose-with-space" > "$work/compose dir/docker-compose.yml"
  _setup_common "$work"

  stack_compose_files() { printf '%s\n' "$work/compose dir/docker-compose.yml"; }
  stack_bind_mounts() { printf '%s\t%s\t%s\n' "$work/data/my bind dir" "/dst/x" "false"; }
  classify_stack_binds "mystack"
  if validate_stack_inputs "mystack"; then :; else fail "validate_stack_inputs should handle paths containing spaces"; fi

  build_stack_archive "mystack" "$work" "$work/compose dir/docker-compose.yml"
  assert_eq "$TAR_RC" "0" "archive build succeeds with space-containing paths"

  local extract; extract="$(mktemp -d)"
  $TAR -xzf "$BACKUP_FILE" -C "$extract" "binds/0/f" "compose/docker-compose.yml"
  assert_file_content "$extract/binds/0/f" "spacey content" "bind with a space in its path round-trips"
  assert_file_content "$extract/compose/docker-compose.yml" "compose-with-space" "compose file with a space in its dir round-trips"
  rm -rf "$extract"

  rm -rf "$work"
}

run_tests
