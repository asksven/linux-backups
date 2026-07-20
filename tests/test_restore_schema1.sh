#!/usr/bin/env bash
# =============================================================================
# tests/test_restore_schema1.sh — restore of a schema-1 (volumes-only)
# archive, confirming ongoing schema-1 compatibility (restore.sh must
# continue to support it even though docker-backup.sh only ever writes
# schema 2 now). Uses tests/fixtures/schema1-manifest.json.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/harness.sh
source ./harness.sh

RESTORE_SH="$REPO_ROOT/restore.sh"
STUB_BIN_DIR="$TESTS_DIR/fixtures/bin"
FIXTURE_MANIFEST="$TESTS_DIR/fixtures/schema1-manifest.json"

# Build a schema-1 archive: fixture manifest.json + volumes/<name>/... data,
# matching the volume name the fixture manifest declares ("legacyapp_data").
_build_schema1_archive() {
  local work="$1"
  local staging="$work/staging"
  mkdir -p "$staging/volumes/legacyapp_data"
  echo "legacy volume content" > "$staging/volumes/legacyapp_data/legacy.txt"
  cp "$FIXTURE_MANIFEST" "$staging/manifest.json"

  local archive="$work/schema1.tar.gz"
  tar -czf "$archive" -C "$staging" manifest.json volumes
  printf '%s' "$archive"
}

test_restore_schema1_fixture_restores_volume() {
  local work; work="$(mktemp -d)"
  local archive; archive="$(_build_schema1_archive "$work")"

  local state="$work/docker_state" out="$work/out.log" err="$work/err.log" rc=0
  mkdir -p "$state"
  PATH="$STUB_BIN_DIR:$PATH" DOCKER_STUB_STATE="$state" \
    bash "$RESTORE_SH" "$archive" --force > "$out" 2> "$err" || rc=$?

  assert_status "$rc" "0" "schema-1 restore exits 0: $(cat "$err")"
  assert_file_content "$state/volumes/legacyapp_data/legacy.txt" "legacy volume content" \
    "schema-1 volume content round-trips"

  # No python3-only schema-2 sections should be attempted/required.
  assert_not_contains "$(cat "$err")" "python3 is required" "schema-1 restore never demands python3"

  rm -rf "$work"
}

run_tests
