# shellcheck shell=bash
# =============================================================================
# tests/stub_lib.sh — shared helpers for tests that need to call
# docker-backup.sh / docker-backup-init.sh functions directly (unit-level),
# rather than running restore.sh as a subprocess (see test_restore_*.sh for
# that approach instead). Source this AFTER tests/harness.sh.
#
# `load_docker_backup`/`load_docker_backup_init` copy the target script (with
# its trailing `main "$@"` call stripped -- it must never run automatically
# just from sourcing) plus lib.sh into a scratch dir and source it, so the
# script's own `REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` line
# resolves there and finds our lib.sh copy rather than clobbering the
# caller's REPO_ROOT.
#
# The helper functions below are stub implementations of lib.sh functions,
# invoked indirectly by name once the real script is sourced (never called
# directly here) -- shellcheck cannot see that, hence the blanket SC2329.
# shellcheck disable=SC2329
# =============================================================================

load_docker_backup() {
  local work="$1"
  sed '$d' "$REPO_ROOT/docker-backup.sh" > "$work/docker-backup-stripped.sh"
  cp "$REPO_ROOT/lib.sh" "$work/lib.sh"
  # shellcheck source=/dev/null
  source "$work/docker-backup-stripped.sh"
}

load_docker_backup_init() {
  local work="$1"
  sed '$d' "$REPO_ROOT/docker-backup-init.sh" > "$work/init-stripped.sh"
  cp "$REPO_ROOT/lib.sh" "$work/lib.sh"
  # shellcheck source=/dev/null
  source "$work/init-stripped.sh"
}

# Stub `_bind_fstype`/`_bind_kind`/`du`/`log` for deterministic, daemon-free
# bind classification in unit tests. `_bind_kind` is left as the real
# lib.sh implementation (it only stats the path, no daemon/network involved)
# unless the caller redefines it after calling this.
stub_bind_helpers() {
  # shellcheck disable=SC2317  # invoked indirectly by name, not directly
  _bind_fstype() { echo "ext4"; }
  # shellcheck disable=SC2317
  log() { :; }
  # shellcheck disable=SC2317
  du() { echo "4096 x"; }
}

# docker-backup.sh/restore.sh call the literal `tar` command (correct on
# Linux, where the system tar is GNU tar). On macOS the system `tar` is
# bsdtar and lacks --transform/--append; shadow it with a bash function that
# forwards to $TAR (harness.sh resolves this to Homebrew's gtar there).
stub_tar_as_gtar() {
  if [[ "$TAR" != "tar" ]]; then
    # shellcheck disable=SC2317
    tar() { "$TAR" "$@"; }
  fi
}
