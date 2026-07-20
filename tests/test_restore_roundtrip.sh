#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals/stub functions read/invoked indirectly by sourced lib.sh/docker-backup.sh
# =============================================================================
# tests/test_restore_roundtrip.sh — build a real synthetic schema-2 archive
# with docker-backup.sh's own archive-building functions, then restore it
# with restore.sh run as a REAL subprocess (docker stubbed via an executable
# under tests/fixtures/bin/, no daemon). Asserts exact file/directory shape,
# contents, modes, config-file order, --bind-root, --project-dir, --no-binds,
# --no-compose, and replacement semantics with/without --force.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/harness.sh
source ./harness.sh
# shellcheck source=tests/stub_lib.sh
source ./stub_lib.sh

RESTORE_SH="$REPO_ROOT/restore.sh"
STUB_BIN_DIR="$TESTS_DIR/fixtures/bin"

# Build a schema-2 archive under $1/backups/*.tar.gz containing: one named
# volume (a file with a specific mode), two compose files (one basename
# collision), one directory bind, one file bind. Prints the archive path on
# stdout; returns non-zero if fixture construction itself failed.
_build_archive() {
  local work="$1"
  mkdir -p "$work/src/volume/vol1_data" \
    "$work/src/compose/proj/override" \
    "$work/src/binds/dirbind/subdir"

  echo "vol content" > "$work/src/volume/vol1_data/data.txt"
  chmod 640 "$work/src/volume/vol1_data/data.txt"

  cat > "$work/src/compose/proj/docker-compose.yml" <<'EOF'
services:
  app: {}
EOF
  cat > "$work/src/compose/proj/override/docker-compose.yml" <<'EOF'
services:
  app:
    environment: [OVERRIDE=1]
EOF

  echo "dir bind content" > "$work/src/binds/dirbind/subdir/f.txt"
  echo "file bind content" > "$work/src/binds/filebind.conf"

  load_docker_backup "$work"
  REPO_DIR="$REPO_ROOT"
  stub_bind_helpers
  stub_tar_as_gtar

  NODE_NAME="testnode"
  DOCKER_BACKUP_DIR="$work/backups"
  mkdir -p "$DOCKER_BACKUP_DIR"
  VOL_LINES=( "$(printf 'vol1\t%s' "$work/src/volume/vol1_data")" )
  COMPOSE_FILE_ENTRIES=(); CAPTURE_BINDS=(); EXCLUDED_BINDS=()

  stack_compose_files() {
    printf '%s\n' "$work/src/compose/proj/docker-compose.yml"
    printf '%s\n' "$work/src/compose/proj/override/docker-compose.yml"
  }
  stack_bind_mounts() {
    printf '%s\t%s\t%s\n' "$work/src/binds/dirbind" "/dst/dirbind" "false"
    printf '%s\t%s\t%s\n' "$work/src/binds/filebind.conf" "/dst/filebind.conf" "true"
  }

  classify_stack_binds "mystack"
  validate_stack_inputs "mystack" >/dev/null || return 1

  build_stack_archive "mystack" "$work/src/compose/proj" \
    "$work/src/compose/proj/docker-compose.yml,$work/src/compose/proj/override/docker-compose.yml"
  [[ "$TAR_RC" -le 1 ]] || return 1

  printf '%s' "$BACKUP_FILE"
}

# Run restore.sh as a real subprocess with the docker stub on PATH.
# _run_restore <state-dir> <stdout-file> <stderr-file> <archive> [restore.sh args...]
_run_restore() {
  local state="$1" out="$2" err="$3" archive="$4"; shift 4
  mkdir -p "$state"
  PATH="$STUB_BIN_DIR:$PATH" DOCKER_STUB_STATE="$state" \
    bash "$RESTORE_SH" "$archive" "$@" > "$out" 2> "$err"
}

test_restore_roundtrip_shape_content_modes_and_order() {
  local work; work="$(mktemp -d)"
  local archive; archive="$(_build_archive "$work")"
  if [[ -z "$archive" ]]; then fail "fixture archive build failed"; rm -rf "$work"; return; fi

  local state="$work/docker_state" proj="$work/restore/proj" bindroot="$work/restore/bindroot"
  local out="$work/out.log" err="$work/err.log" rc=0
  _run_restore "$state" "$out" "$err" "$archive" \
    --force --project-dir "$proj" --bind-root "$bindroot" || rc=$?
  assert_status "$rc" "0" "restore exits 0 on a clean round-trip: $(cat "$err")"

  # Volume: content + mode preserved.
  assert_file_content "$state/volumes/vol1/data.txt" "vol content" "restored volume file content"
  assert_mode "$state/volumes/vol1/data.txt" "640" "restored volume file mode preserved"

  # Compose files: both present, in original config_files[] order in the hint.
  assert_file_exists "$proj/docker-compose.yml" "first compose file restored under its plain name"
  assert_file_content "$proj/docker-compose.yml" "$(cat <<'EOF'
services:
  app: {}
EOF
)" "first compose file content"
  local collided; collided="$(find "$proj" -maxdepth 1 -name '*-docker-compose.yml' | head -n1)"
  assert_ne "$collided" "" "collision-renamed second compose file exists"
  assert_file_content "$collided" "$(cat <<'EOF'
services:
  app:
    environment: [OVERRIDE=1]
EOF
)" "second (collision) compose file content"

  local hint; hint="$(cat "$out")"
  assert_contains "$hint" "-f 'docker-compose.yml'" "final hint references the first compose file"
  assert_contains "$hint" "-f '$(basename "$collided")'" "final hint references the renamed second compose file"
  # The plain "docker-compose.yml" -f flag must appear before the collision one.
  local idx1 idx2
  idx1="$(awk -v s="-f 'docker-compose.yml'" 'index($0,s){print index($0,s); exit}' <<< "$hint")"
  idx2="$(awk -v s="-f '$(basename "$collided")'" 'index($0,s){print index($0,s); exit}' <<< "$hint")"
  [[ -n "$idx1" && -n "$idx2" && "$idx1" -lt "$idx2" ]] || fail "compose -f flags are not in original config_files[] order"

  # Directory bind, remapped under --bind-root at its original absolute path.
  assert_file_content "${bindroot}${work}/src/binds/dirbind/subdir/f.txt" "dir bind content" "directory bind round-trips under --bind-root"

  # File bind, remapped under --bind-root, exact original filename.
  assert_file_content "${bindroot}${work}/src/binds/filebind.conf" "file bind content" "file bind round-trips under --bind-root"

  rm -rf "$work"
}

test_restore_no_binds_and_no_compose_skip_those_sections() {
  local work; work="$(mktemp -d)"
  local archive; archive="$(_build_archive "$work")"
  if [[ -z "$archive" ]]; then fail "fixture archive build failed"; rm -rf "$work"; return; fi

  local state="$work/docker_state" proj="$work/restore/proj" bindroot="$work/restore/bindroot"
  local out="$work/out.log" err="$work/err.log" rc=0
  _run_restore "$state" "$out" "$err" "$archive" \
    --force --project-dir "$proj" --bind-root "$bindroot" --no-binds --no-compose || rc=$?
  assert_status "$rc" "0" "restore with --no-binds --no-compose still exits 0: $(cat "$err")"

  assert_file_content "$state/volumes/vol1/data.txt" "vol content" "volumes still restore under --no-binds/--no-compose"
  assert_not_exists "$proj/docker-compose.yml" "--no-compose skips compose restore"
  assert_not_exists "${bindroot}${work}/src/binds/dirbind" "--no-binds skips directory bind restore"
  assert_not_exists "${bindroot}${work}/src/binds/filebind.conf" "--no-binds skips file bind restore"

  rm -rf "$work"
}

test_restore_no_force_rejects_conflicting_targets_without_modifying_them() {
  local work; work="$(mktemp -d)"
  local archive; archive="$(_build_archive "$work")"
  if [[ -z "$archive" ]]; then fail "fixture archive build failed"; rm -rf "$work"; return; fi

  local state="$work/docker_state" proj="$work/restore/proj" bindroot="$work/restore/bindroot"

  # Pre-seed conflicting content: an existing non-empty "volume" (docker
  # stub state dir), a non-empty existing directory-bind target, and an
  # existing file-bind target with different content.
  mkdir -p "$state/volumes/vol1"
  echo "PRE-EXISTING VOLUME DATA" > "$state/volumes/vol1/stray.txt"
  mkdir -p "${bindroot}${work}/src/binds/dirbind"
  echo "PRE-EXISTING DIR BIND DATA" > "${bindroot}${work}/src/binds/dirbind/stray.txt"
  mkdir -p "$(dirname "${bindroot}${work}/src/binds/filebind.conf")"
  echo "PRE-EXISTING FILE BIND DATA" > "${bindroot}${work}/src/binds/filebind.conf"

  local out="$work/out.log" err="$work/err.log" rc=0
  _run_restore "$state" "$out" "$err" "$archive" \
    --project-dir "$proj" --bind-root "$bindroot" || rc=$?
  assert_ne "$rc" "0" "restore without --force exits non-zero on conflicting targets"

  assert_file_exists "$state/volumes/vol1/stray.txt" "non-forced restore does not clear the pre-existing volume"
  assert_not_exists "$state/volumes/vol1/data.txt" "non-forced restore does not extract into the conflicting volume"
  assert_file_content "${bindroot}${work}/src/binds/dirbind/stray.txt" "PRE-EXISTING DIR BIND DATA" "non-forced restore does not clear the conflicting directory bind target"
  assert_file_content "${bindroot}${work}/src/binds/filebind.conf" "PRE-EXISTING FILE BIND DATA" "non-forced restore does not overwrite the conflicting file bind target"

  # Now retry with --force: everything should be replaced.
  rc=0
  _run_restore "$state" "$out" "$err" "$archive" \
    --force --project-dir "$proj" --bind-root "$bindroot" || rc=$?
  assert_status "$rc" "0" "forced retry succeeds: $(cat "$err")"
  assert_file_content "$state/volumes/vol1/data.txt" "vol content" "forced restore replaces the volume content"
  assert_not_exists "$state/volumes/vol1/stray.txt" "forced restore clears prior stray volume content"
  assert_file_content "${bindroot}${work}/src/binds/dirbind/subdir/f.txt" "dir bind content" "forced restore replaces the directory bind content"
  assert_not_exists "${bindroot}${work}/src/binds/dirbind/stray.txt" "forced restore clears prior stray directory-bind content"
  assert_file_content "${bindroot}${work}/src/binds/filebind.conf" "file bind content" "forced restore replaces the file bind content"

  rm -rf "$work"
}

run_tests
