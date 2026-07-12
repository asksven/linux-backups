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
#   backup.sh [--branch <branch>] [--dry-run] [--check-targets]
#
# Environment overrides:
#   CONFIG_DIR       Config location (default: /etc/linux-backups)
#   BACKUP_BRANCH    Git branch for self-update (default: main)
#   DRY_RUN=1        Run tar + metrics, skip azcopy and self-update
#   NO_SELF_UPDATE=1 Skip the git self-update step
#
# --check-targets probes each target's credentials/reachability and exits 0 if
# all pass (non-zero otherwise); it performs no backup.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults — set to FAILURE so an early crash still reports a failed backup.
# -----------------------------------------------------------------------------
START_TS="$(date +%s)"
TAR_RC=1
SIZE_BYTES=0
DURATION=0
TAR_SUCCESS=0
INTEGRITY_OK=0
ARCHIVE_SUCCESS=0
ALL_TARGETS_SUCCESS=0
TARGETS_TOTAL=0
TARGETS_OK=0
LOG_DIR=""
NODE_NAME=""
BACKUP_FILE=""

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-/etc/linux-backups}"

# Shared helpers: log, self_update, load_secrets, setup_logging, rotate_logs,
# azcopy_copy, pushgateway_post (and Docker discovery helpers, unused here).
# shellcheck source=lib.sh
source "$REPO_DIR/lib.sh"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) BACKUP_BRANCH="${2:?--branch needs a value}"; shift 2 ;;
      --branch=*) BACKUP_BRANCH="${1#*=}"; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --check-targets) CHECK_TARGETS=1; shift ;;
      -h|--help)
        grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
      *) log WARNING "ignoring unknown argument: $1"; shift ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Self-update is provided by lib.sh (self_update); it uses REPO_DIR and the
# optional BACKUP_BRANCH env/flag.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Configuration loading
# -----------------------------------------------------------------------------
load_config() {
  local secrets="$CONFIG_DIR/secrets.env"
  local conf="$CONFIG_DIR/backup.conf"

  if [[ ! -r "$conf" ]]; then
    log ERROR "config file not found or unreadable: $conf"
    exit 1
  fi

  load_secrets "$secrets"
  # shellcheck disable=SC1090
  source "$conf"

  NODE_NAME="${NODE_NAME:-$(hostname -s)}"
  BLOCK_SIZE_MB="${BLOCK_SIZE_MB:-100}"
  LOG_DIR="${LOG_DIR:-$BACKUP_DIR/logs}"

  local missing=0
  [[ -n "${BACKUP_DIR:-}" ]]     || { log ERROR "BACKUP_DIR not set in $conf"; missing=1; }
  [[ -n "${RETENTION_DAYS:-}" ]] || { log ERROR "RETENTION_DAYS not set in $conf"; missing=1; }
  if [[ "${#INCLUDE_PATHS[@]}" -eq 0 ]]; then
    log ERROR "INCLUDE_PATHS is empty in $conf"; missing=1
  fi
  [[ $missing -eq 0 ]] || exit 1
}

# -----------------------------------------------------------------------------
# Logging setup and log rotation are provided by lib.sh (setup_logging,
# rotate_logs); they take the log directory as an argument.
# -----------------------------------------------------------------------------

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
# Send today's tarball to every configured target under the node's prefix, then
# run each target's retention. Sets ALL_TARGETS_SUCCESS. Per-target metrics are
# pushed immediately so a mid-run failure still reports each target's state.
# -----------------------------------------------------------------------------
send_to_targets() {
  local name file
  TARGETS_TOTAL=0
  TARGETS_OK=0
  while IFS=$'\t' read -r name file; do
    [[ -n "$name" ]] || continue
    TARGETS_TOTAL=$((TARGETS_TOTAL + 1))
    load_target "$name" "$file"
    if [[ -n "${DRY_RUN:-}" ]]; then
      log INFO "DRY_RUN: skipping send to target '$name'"
      TARGET_RC=0; TARGET_BYTES=$SIZE_BYTES; TARGET_DURATION=0; TARGET_PRUNED=0
    else
      target_send "$name" "$BACKUP_FILE" "$NODE_NAME"
      if [[ $TARGET_RC -eq 0 ]]; then
        target_prune "$name" "$NODE_NAME"
      else
        TARGET_PRUNED=0
      fi
    fi
    if [[ $TARGET_RC -eq 0 ]]; then
      TARGETS_OK=$((TARGETS_OK + 1))
      log INFO "target '$name': delivered"
    else
      log ERROR "target '$name': FAILED (rc=$TARGET_RC)"
    fi
    push_target_metrics "$name"
  done < <(list_targets)

  if [[ $TARGETS_TOTAL -eq 0 ]]; then
    log ERROR "no backup targets configured (see conf/targets/*.example.conf); archive not delivered"
    ALL_TARGETS_SUCCESS=0
  elif [[ $TARGETS_OK -eq $TARGETS_TOTAL ]]; then
    ALL_TARGETS_SUCCESS=1
  else
    ALL_TARGETS_SUCCESS=0
  fi
}

# -----------------------------------------------------------------------------
# Push per-target metrics to job/linux_backup/instance/<node>/target/<name>.
# -----------------------------------------------------------------------------
push_target_metrics() {
  local name="$1" now ok=0
  now="$(date +%s)"
  [[ ${TARGET_RC:-1} -eq 0 ]] && ok=1
  local body
  body="$(cat <<EOF
# TYPE backup_target_success gauge
backup_target_success ${ok}
# TYPE backup_target_rc gauge
backup_target_rc ${TARGET_RC:-1}
# TYPE backup_target_duration_seconds gauge
backup_target_duration_seconds ${TARGET_DURATION:-0}
# TYPE backup_target_bytes gauge
backup_target_bytes ${TARGET_BYTES:-0}
# TYPE backup_target_pruned_files gauge
backup_target_pruned_files ${TARGET_PRUNED:-0}
# TYPE backup_target_last_run_timestamp_seconds gauge
backup_target_last_run_timestamp_seconds ${now}
EOF
)"
  if [[ $ok -eq 1 ]]; then
    body+="
# TYPE backup_target_last_success_timestamp_seconds gauge
backup_target_last_success_timestamp_seconds ${now}"
  fi
  pushgateway_post "job/linux_backup/instance/${NODE_NAME}/target/${name}" "$body"
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
backup_success ${ARCHIVE_SUCCESS}
# TYPE backup_all_targets_success gauge
backup_all_targets_success ${ALL_TARGETS_SUCCESS}
# TYPE backup_tar_rc gauge
backup_tar_rc ${TAR_RC}
# TYPE backup_duration_seconds gauge
backup_duration_seconds ${DURATION}
# TYPE backup_size_bytes gauge
backup_size_bytes ${SIZE_BYTES}
# TYPE backup_last_run_timestamp_seconds gauge
backup_last_run_timestamp_seconds ${now}
# TYPE backup_retention_days gauge
backup_retention_days ${RETENTION_DAYS:-0}
EOF
  if [[ $ARCHIVE_SUCCESS -eq 1 && $ALL_TARGETS_SUCCESS -eq 1 ]]; then
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
  pushgateway_post "job/linux_backup/instance/${NODE_NAME}" "$(build_metrics)"
}

# -----------------------------------------------------------------------------
# EXIT trap: always compute the final result, rotate logs and push metrics.
# -----------------------------------------------------------------------------
finish() {
  local rc=$?
  DURATION=$(( $(date +%s) - START_TS ))
  if [[ $TAR_SUCCESS -eq 1 && $INTEGRITY_OK -eq 1 ]]; then
    ARCHIVE_SUCCESS=1
  else
    ARCHIVE_SUCCESS=0
  fi
  log INFO "backup finished: archive=${ARCHIVE_SUCCESS} all_targets=${ALL_TARGETS_SUCCESS} (${TARGETS_OK}/${TARGETS_TOTAL}) duration=${DURATION}s size=${SIZE_BYTES}B"
  rotate_logs "$LOG_DIR"
  push_metrics
  exit "$rc"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  parse_args "$@"

  # Preflight: probe target credentials/reachability and exit (no backup).
  if [[ -n "${CHECK_TARGETS:-}" ]]; then
    load_config
    if check_targets; then exit 0; else exit 1; fi
  fi

  # Self-update, then re-exec the updated script. Skipped in dry-run, when
  # already updated, or when explicitly disabled.
  if [[ -z "${_SELF_UPDATED:-}" && -z "${DRY_RUN:-}" && -z "${NO_SELF_UPDATE:-}" ]]; then
    if self_update; then
      export _SELF_UPDATED=1
      exec "$0" "$@"
    fi
  fi

  load_config
  setup_logging "$LOG_DIR"
  trap finish EXIT

  log INFO "starting backup for node '${NODE_NAME}'"
  create_archive
  verify_archive
  purge_local
  send_to_targets
}

main "$@"
