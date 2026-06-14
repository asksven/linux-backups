#!/usr/bin/env bash
# =============================================================================
# linux-backups — unified, self-updating backup with Prometheus metrics
#
# Flow:
#   1. Self-update from git (default branch "main", override with --branch).
#   2. Load per-server config + secrets from CONFIG_DIR (default /etc/linux-backups).
#   3. tar -czf the declared paths (plus CONFIG_DIR itself) with excludes.
#   4. Verify archive integrity, purge old LOCAL tarballs.
#   5. Upload ONLY today's tarball with `azcopy copy` (no sync, no delete-destination).
#   6. Always push success/failure metrics to the Pushgateway (skipped if unset).
#   7. Keep the last 5 run logs locally.
#
# Remote retention is NOT handled here — it is enforced server-side by an Azure
# Blob lifecycle policy (see README).
#
# Usage:
#   backup.sh [--branch <branch>] [--dry-run]
#
# Environment overrides:
#   CONFIG_DIR       Config location (default: /etc/linux-backups)
#   BACKUP_BRANCH    Git branch for self-update (default: main)
#   DRY_RUN=1        Run tar + metrics, skip azcopy and self-update
#   NO_SELF_UPDATE=1 Skip the git self-update step
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults — set to FAILURE so an early crash still reports a failed backup.
# -----------------------------------------------------------------------------
START_TS="$(date +%s)"
TAR_RC=1
AZCOPY_RC=1
SIZE_BYTES=0
DURATION=0
TAR_SUCCESS=0
INTEGRITY_OK=0
AZCOPY_SUCCESS=0
OVERALL_SUCCESS=0
LOG_DIR=""
NODE_NAME=""
BACKUP_FILE=""

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-/etc/linux-backups}"

# -----------------------------------------------------------------------------
# Logging helper: log <LEVEL> <message...>
# -----------------------------------------------------------------------------
log() {
  local level="$1"; shift
  printf '[%s] %s: %s\n' "$(date '+%F %T')" "$level" "$*"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) BACKUP_BRANCH="${2:?--branch needs a value}"; shift 2 ;;
      --branch=*) BACKUP_BRANCH="${1#*=}"; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help)
        grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
      *) log WARNING "ignoring unknown argument: $1"; shift ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Self-update: fetch + hard-reset to the requested branch, then re-exec.
# Fails SOFT: if git is unavailable or the remote is unreachable, log a warning
# and continue with the current local version instead of aborting the backup.
# -----------------------------------------------------------------------------
self_update() {
  local branch="${BACKUP_BRANCH:-main}"

  if ! command -v git >/dev/null 2>&1; then
    log WARNING "git not found; skipping self-update"
    return 1
  fi
  if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log WARNING "$REPO_DIR is not a git checkout; skipping self-update"
    return 1
  fi
  if ! git -C "$REPO_DIR" fetch --quiet origin "$branch" 2>/dev/null; then
    log WARNING "git fetch failed (offline?); continuing with current version"
    return 1
  fi
  if ! git -C "$REPO_DIR" checkout --quiet "$branch" 2>/dev/null; then
    log WARNING "git checkout '$branch' failed; continuing with current version"
    return 1
  fi
  if ! git -C "$REPO_DIR" reset --hard --quiet "origin/$branch" 2>/dev/null; then
    log WARNING "git reset failed; continuing with current version"
    return 1
  fi
  log INFO "self-updated to origin/$branch ($(git -C "$REPO_DIR" rev-parse --short HEAD))"
  return 0
}

# -----------------------------------------------------------------------------
# Configuration loading
# -----------------------------------------------------------------------------
load_config() {
  local secrets="$CONFIG_DIR/secrets.env"
  local conf="$CONFIG_DIR/backup.conf"

  if [[ ! -r "$secrets" ]]; then
    log ERROR "secrets file not found or unreadable: $secrets"
    exit 1
  fi
  if [[ ! -r "$conf" ]]; then
    log ERROR "config file not found or unreadable: $conf"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$secrets"
  # shellcheck disable=SC1090
  source "$conf"

  NODE_NAME="${NODE_NAME:-$(hostname -s)}"
  BLOCK_SIZE_MB="${BLOCK_SIZE_MB:-100}"
  LOG_DIR="${LOG_DIR:-$BACKUP_DIR/logs}"

  local missing=0
  [[ -n "${BACKUP_DIR:-}" ]]     || { log ERROR "BACKUP_DIR not set in $conf"; missing=1; }
  [[ -n "${RETENTION_DAYS:-}" ]] || { log ERROR "RETENTION_DAYS not set in $conf"; missing=1; }
  [[ -n "${DEST_URL:-}" ]]       || { log ERROR "DEST_URL not set in $secrets"; missing=1; }
  if [[ "${#INCLUDE_PATHS[@]}" -eq 0 ]]; then
    log ERROR "INCLUDE_PATHS is empty in $conf"; missing=1
  fi
  [[ $missing -eq 0 ]] || exit 1
}

# -----------------------------------------------------------------------------
# Logging setup: tee everything to a per-run logfile.
# -----------------------------------------------------------------------------
setup_logging() {
  mkdir -p "$LOG_DIR"
  local logfile
  logfile="$LOG_DIR/run-$(date '+%F-%H-%M-%S').log"
  exec > >(tee -a "$logfile") 2>&1
  log INFO "logging to $logfile"
}

# -----------------------------------------------------------------------------
# Keep only the 5 most recent run logs.
# -----------------------------------------------------------------------------
rotate_logs() {
  [[ -n "$LOG_DIR" && -d "$LOG_DIR" ]] || return 0
  local old
  # Filenames are controlled timestamps (run-<ts>.log), so ls -t is safe here.
  # shellcheck disable=SC2012
  old="$(ls -1t "$LOG_DIR"/run-*.log 2>/dev/null | tail -n +6 || true)"
  [[ -z "$old" ]] && return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] && rm -f "$f"
  done <<< "$old"
}

# -----------------------------------------------------------------------------
# Create the tarball. Includes the declared paths AND the CONFIG_DIR so the node
# is fully restorable. tar exit codes: 0=ok, 1=warning (files changed while
# reading, archive still usable), >=2=fatal.
# -----------------------------------------------------------------------------
create_archive() {
  mkdir -p "$BACKUP_DIR"
  local today
  today="$(date '+%F-%H-%M')"
  BACKUP_FILE="$BACKUP_DIR/${NODE_NAME}-${today}.tar.gz"

  local tar_args=()
  local ex
  for ex in "${EXCLUDE_PATHS[@]:-}"; do
    [[ -n "$ex" ]] && tar_args+=( "--exclude=$ex" )
  done
  tar_args+=( --create --gzip --verbose --file "$BACKUP_FILE" )
  tar_args+=( "${INCLUDE_PATHS[@]}" )
  tar_args+=( "$CONFIG_DIR" )

  log INFO "creating archive $BACKUP_FILE"
  set +e
  tar "${tar_args[@]}"
  TAR_RC=$?
  set -e

  if [[ $TAR_RC -eq 0 ]]; then
    TAR_SUCCESS=1
  elif [[ $TAR_RC -eq 1 ]]; then
    TAR_SUCCESS=1
    log WARNING "tar reported files changed while reading (rc=1); archive kept"
  else
    TAR_SUCCESS=0
    log ERROR "tar failed (rc=$TAR_RC)"
  fi
}

# -----------------------------------------------------------------------------
# Verify the archive is non-empty and gzip-intact.
# -----------------------------------------------------------------------------
verify_archive() {
  if [[ ! -s "$BACKUP_FILE" ]]; then
    log ERROR "archive missing or empty: $BACKUP_FILE"
    INTEGRITY_OK=0
    return
  fi
  SIZE_BYTES="$(wc -c < "$BACKUP_FILE" | tr -d '[:space:]')"
  if gzip -t "$BACKUP_FILE" 2>/dev/null; then
    INTEGRITY_OK=1
    log INFO "archive integrity OK ($SIZE_BYTES bytes)"
  else
    INTEGRITY_OK=0
    log ERROR "archive failed gzip integrity check"
  fi
}

# -----------------------------------------------------------------------------
# Delete LOCAL tarballs older than RETENTION_DAYS.
# -----------------------------------------------------------------------------
purge_local() {
  log INFO "purging local tarballs older than ${RETENTION_DAYS} days in $BACKUP_DIR"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -mtime "+${RETENTION_DAYS}" -delete
}

# -----------------------------------------------------------------------------
# Upload today's tarball with `azcopy copy` to the node's prefix. No sync, no
# delete-destination — this avoids the expensive per-run destination indexing.
# -----------------------------------------------------------------------------
upload_archive() {
  local basename dest_display dest azcopy_out failed
  basename="$(basename "$BACKUP_FILE")"
  dest_display="${DEST_URL%/}/${NODE_NAME}/${basename}"
  dest="${DEST_URL%/}/${NODE_NAME}/${basename}${SAS_TOKEN:-}"

  log INFO "uploading to $dest_display (block-size=${BLOCK_SIZE_MB}MiB)"
  set +e
  azcopy_out="$(azcopy copy "$BACKUP_FILE" "$dest" --block-size-mb="$BLOCK_SIZE_MB" 2>&1)"
  AZCOPY_RC=$?
  set -e
  printf '%s\n' "$azcopy_out"

  failed="$(grep -oE 'Number of Transfers Failed: [0-9]+' <<< "$azcopy_out" | grep -oE '[0-9]+$' || true)"
  if [[ $AZCOPY_RC -eq 0 && "${failed:-0}" -eq 0 ]]; then
    AZCOPY_SUCCESS=1
    log INFO "upload succeeded"
  else
    AZCOPY_SUCCESS=0
    log ERROR "upload failed (rc=$AZCOPY_RC, transfers failed=${failed:-unknown})"
  fi
}

# -----------------------------------------------------------------------------
# Build the Prometheus exposition body. backup_last_success_timestamp_seconds is
# only emitted on success; because we POST to the Pushgateway, an omitted metric
# keeps its previous value — so the last successful time survives failed runs.
# -----------------------------------------------------------------------------
build_metrics() {
  local now; now="$(date +%s)"
  cat <<EOF
# TYPE backup_success gauge
backup_success ${OVERALL_SUCCESS}
# TYPE backup_tar_rc gauge
backup_tar_rc ${TAR_RC}
# TYPE backup_azcopy_rc gauge
backup_azcopy_rc ${AZCOPY_RC}
# TYPE backup_duration_seconds gauge
backup_duration_seconds ${DURATION}
# TYPE backup_size_bytes gauge
backup_size_bytes ${SIZE_BYTES}
# TYPE backup_last_run_timestamp_seconds gauge
backup_last_run_timestamp_seconds ${now}
# TYPE backup_retention_days gauge
backup_retention_days ${RETENTION_DAYS:-0}
EOF
  if [[ $OVERALL_SUCCESS -eq 1 ]]; then
    cat <<EOF
# TYPE backup_last_success_timestamp_seconds gauge
backup_last_success_timestamp_seconds ${now}
EOF
  fi
}

# -----------------------------------------------------------------------------
# Push metrics to the Pushgateway (POST). Skips gracefully (INFO) when the
# gateway URL is empty, and never fails the run on push errors.
# -----------------------------------------------------------------------------
push_metrics() {
  if [[ -z "$NODE_NAME" ]]; then
    log INFO "node name unknown; skipping metrics push"
    return 0
  fi
  if [[ -z "${PROM_GTW:-}" ]]; then
    log INFO "Pushgateway URL not set; skipping metrics push"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log WARNING "curl not found; cannot push metrics"
    return 0
  fi

  local url="${PROM_GTW%/}/metrics/job/linux_backup/instance/${NODE_NAME}"
  if build_metrics | curl --fail --silent --show-error --data-binary @- "$url"; then
    log INFO "metrics pushed to $url (success=${OVERALL_SUCCESS})"
  else
    log WARNING "failed to push metrics to $url"
  fi
}

# -----------------------------------------------------------------------------
# EXIT trap: always compute the final result, rotate logs and push metrics.
# -----------------------------------------------------------------------------
finish() {
  local rc=$?
  DURATION=$(( $(date +%s) - START_TS ))
  if [[ $TAR_SUCCESS -eq 1 && $INTEGRITY_OK -eq 1 && $AZCOPY_SUCCESS -eq 1 ]]; then
    OVERALL_SUCCESS=1
  else
    OVERALL_SUCCESS=0
  fi
  log INFO "backup finished: success=${OVERALL_SUCCESS} duration=${DURATION}s size=${SIZE_BYTES}B"
  rotate_logs
  push_metrics
  exit "$rc"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  parse_args "$@"

  # Self-update, then re-exec the updated script. Skipped in dry-run, when
  # already updated, or when explicitly disabled.
  if [[ -z "${_SELF_UPDATED:-}" && -z "${DRY_RUN:-}" && -z "${NO_SELF_UPDATE:-}" ]]; then
    if self_update; then
      export _SELF_UPDATED=1
      exec "$0" "$@"
    fi
  fi

  load_config
  setup_logging
  trap finish EXIT

  log INFO "starting backup for node '${NODE_NAME}'"
  create_archive
  verify_archive
  purge_local

  if [[ -n "${DRY_RUN:-}" ]]; then
    log INFO "DRY_RUN set; skipping upload. Marking azcopy step as successful."
    AZCOPY_SUCCESS=1
    AZCOPY_RC=0
  else
    upload_archive
  fi
}

main "$@"
