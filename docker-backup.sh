#!/usr/bin/env bash
# =============================================================================
# docker-backup.sh — back up Docker Compose stack state (named volumes) as
# per-stack archives, using stop-cold-copy for consistency.
#
# Flow:
#   1. Self-update from git (default branch "main", override with --branch).
#   2. Load secrets + docker-backup.conf (and backup.conf for bind coverage).
#   3. Discover stacks that own named volumes (com.docker.compose.project label).
#   4. For each stack on the STACKS allowlist:
#        docker compose stop -> tar each volume into volumes/<vol>/ + manifest
#        -> docker compose start -> verify -> purge local -> azcopy copy.
#   5. Detect stateful stacks NOT on the allowlist (alert only, never auto-add)
#      and check every stack's bind mounts against the host-path backup.
#   6. Push per-stack + detector metrics to the Pushgateway.
#
# Usage:
#   docker-backup.sh [--branch <branch>] [--dry-run] [--check-targets]
#
# Environment overrides:
#   CONFIG_DIR       Config location (default: /etc/linux-backups)
#   BACKUP_BRANCH    Git branch for self-update (default: main)
#   DRY_RUN=1        Discovery + detection + bind analysis only; NO stop/tar/upload
#   NO_SELF_UPDATE=1 Skip the git self-update step
#
# --check-targets probes each target's credentials/reachability and exits 0 if
# all pass (non-zero otherwise); it performs no backup.
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-/etc/linux-backups}"

# Shared helpers + Docker discovery functions.
# shellcheck source=lib.sh
source "$REPO_DIR/lib.sh"

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
NODE_NAME=""
LOG_DIR=""
HAVE_COVERAGE=0
UNMANAGED_COUNT=0
declare -a VOL_LINES=()
declare -A BIND_IGNORE_HITS=()

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
# Configuration loading. docker-backup.conf is required; backup.conf is optional
# and only used to judge bind-mount coverage (INCLUDE_PATHS / EXCLUDE_PATHS).
# -----------------------------------------------------------------------------
load_config() {
  local secrets="$CONFIG_DIR/secrets.env"
  local host_conf="$CONFIG_DIR/backup.conf"
  local conf="$CONFIG_DIR/docker-backup.conf"

  load_secrets "$secrets"

  if [[ -r "$host_conf" ]]; then
    # shellcheck disable=SC1090
    source "$host_conf"
    if [[ -n "${INCLUDE_PATHS+x}" ]]; then
      HAVE_COVERAGE=1
    fi
  else
    log INFO "no backup.conf found; bind-mount coverage will be reported as unknown"
  fi

  if [[ ! -r "$conf" ]]; then
    log ERROR "config file not found or unreadable: $conf"
    log ERROR "create it from conf/docker-backup.example.conf (see README)"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$conf"

  NODE_NAME="${NODE_NAME:-$(hostname -s)}"
  BLOCK_SIZE_MB="${BLOCK_SIZE_MB:-100}"
  STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
  RETENTION_DAYS="${RETENTION_DAYS:-7}"
  DOCKER_BACKUP_DIR="${DOCKER_BACKUP_DIR:-${BACKUP_DIR:-/var/backups/linux-backups}/docker}"
  LOG_DIR="${DOCKER_LOG_DIR:-$DOCKER_BACKUP_DIR/logs}"

  # STACKS may legitimately be empty (detection-only run). Ensure it exists.
  if [[ -z "${STACKS+x}" ]]; then
    STACKS=()
  fi
  if [[ -z "${BIND_IGNORE+x}" ]]; then
    BIND_IGNORE=()
  fi
}

# -----------------------------------------------------------------------------
# Return 0 if <value> is an element of the STACKS allowlist.
# -----------------------------------------------------------------------------
is_managed() {
  local needle="$1" s
  for s in "${STACKS[@]:-}"; do
    [[ "$s" == "$needle" ]] && return 0
  done
  return 1
}

# -----------------------------------------------------------------------------
# BIND_IGNORE matching. An entry is either "<pattern>" or "<stack>:<pattern>".
# <pattern> is an exact path, a directory subtree (trailing "/"), or a glob.
# _bind_match is provided by lib.sh.
# -----------------------------------------------------------------------------
bind_ignored() {
  local stack="$1" src="$2" i entry pat scope
  for i in "${!BIND_IGNORE[@]}"; do
    entry="${BIND_IGNORE[$i]}"
    [[ -n "$entry" ]] || continue
    scope=""; pat="$entry"
    if [[ "$entry" != /* && "$entry" == *:* ]]; then
      scope="${entry%%:*}"; pat="${entry#*:}"
    fi
    [[ -n "$scope" && "$scope" != "$stack" ]] && continue
    if _bind_match "$src" "$pat"; then
      BIND_IGNORE_HITS[$i]=1
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# Analyze a stack's bind mounts. Sets UNCOVERED_BINDS and IGNORED_BINDS.
# -----------------------------------------------------------------------------
analyze_stack_binds() {
  local stack="$1" src dst
  UNCOVERED_BINDS=0
  IGNORED_BINDS=0
  while IFS=$'\t' read -r src dst; do
    [[ -n "$src" ]] || continue
    if bind_ignored "$stack" "$src"; then
      IGNORED_BINDS=$((IGNORED_BINDS + 1))
      log INFO "bind acknowledged (BIND_IGNORE): $src [$stack]"
      continue
    fi
    if [[ $HAVE_COVERAGE -eq 0 ]]; then
      log INFO "bind coverage unknown (no backup.conf): $src [$stack]"
      continue
    fi
    if path_is_covered "$src"; then
      log INFO "bind covered by host-path backup: $src [$stack]"
    else
      UNCOVERED_BINDS=$((UNCOVERED_BINDS + 1))
      log WARNING "UNCOVERED bind mount: $src -> $dst [$stack]"
    fi
  done < <(stack_bind_mounts "$stack")
}

# -----------------------------------------------------------------------------
# Compose stop / start. Uses the compose project context when available, else
# falls back to stopping/starting the stack's containers directly.
# -----------------------------------------------------------------------------
_compose_action() {
  local action="$1" stack="$2" wd="$3" cf="$4"
  if [[ -n "$wd" && -n "$cf" ]]; then
    local fargs=() f
    IFS=',' read -ra _cfs <<< "$cf"
    for f in "${_cfs[@]}"; do
      [[ -n "$f" ]] && fargs+=( -f "$f" )
    done
    docker compose --project-name "$stack" --project-directory "$wd" \
      "${fargs[@]}" "$action" -t "$STOP_TIMEOUT"
  else
    log WARNING "no compose context for '$stack'; using docker $action on containers"
    local cids
    mapfile -t cids < <(stack_containers "$stack")
    [[ ${#cids[@]} -gt 0 ]] && docker "$action" -t "$STOP_TIMEOUT" "${cids[@]}"
  fi
}

# -----------------------------------------------------------------------------
# Build manifest.json for the current stack (VOL_LINES already populated).
# -----------------------------------------------------------------------------
write_manifest() {
  local stack="$1" wd="$2" cf="$3"
  local epoch now line name mp
  epoch="$(date +%s)"
  now="$(date -u '+%FT%TZ')"

  local vjson="" first=1
  for line in "${VOL_LINES[@]}"; do
    name="${line%%$'\t'*}"; mp="${line#*$'\t'}"
    [[ $first -eq 1 ]] || vjson+=","
    first=0
    vjson+="$(printf '{"name":"%s","mountpoint":"%s","archive_path":"volumes/%s"}' \
      "$(json_escape "$name")" "$(json_escape "$mp")" "$(json_escape "$name")")"
  done

  local cfjson="" f
  first=1
  IFS=',' read -ra _cfs <<< "$cf"
  for f in "${_cfs[@]}"; do
    [[ -n "$f" ]] || continue
    [[ $first -eq 1 ]] || cfjson+=","
    first=0
    cfjson+="$(printf '"%s"' "$(json_escape "$f")")"
  done

  cat <<EOF
{
  "schema": 1,
  "node": "$(json_escape "$NODE_NAME")",
  "stack": "$(json_escape "$stack")",
  "timestamp": "$now",
  "epoch": $epoch,
  "compose": { "working_dir": "$(json_escape "$wd")", "config_files": [${cfjson}] },
  "volumes": [${vjson}]
}
EOF
}

# -----------------------------------------------------------------------------
# Create the per-stack tarball: manifest.json + volumes/<vol>/... . Uses an
# uncompressed intermediate .tar (so multiple volumes can be appended with
# per-volume path prefixes) then gzips it. Sets BACKUP_FILE and TAR_RC.
# GNU tar (--transform, --append) is required (Linux hosts).
# -----------------------------------------------------------------------------
build_stack_archive() {
  local stack="$1" wd="$2" cf="$3"
  local ts archive tarfile mdir line name mp
  ts="$(date '+%F-%H-%M')"
  archive="$DOCKER_BACKUP_DIR/${NODE_NAME}-${stack}-${ts}.tar.gz"
  tarfile="${archive%.gz}"
  BACKUP_FILE="$archive"
  TAR_RC=0

  mkdir -p "$DOCKER_BACKUP_DIR"
  rm -f "$tarfile"

  mdir="$(mktemp -d)"
  write_manifest "$stack" "$wd" "$cf" > "$mdir/manifest.json"

  set +e
  tar --create --file "$tarfile" -C "$mdir" manifest.json
  TAR_RC=$?
  for line in "${VOL_LINES[@]}"; do
    name="${line%%$'\t'*}"; mp="${line#*$'\t'}"
    if [[ ! -d "$mp" ]]; then
      log ERROR "volume '$name' mountpoint not accessible: $mp (backup incomplete)"
      TAR_RC=2
      continue
    fi
    tar --append --file "$tarfile" --numeric-owner \
      -C "$mp" --transform "s#^\.#volumes/${name}#" .
    local rc=$?
    [[ $rc -gt $TAR_RC ]] && TAR_RC=$rc
  done
  set -e

  rm -rf "$mdir"

  if [[ $TAR_RC -le 1 ]]; then
    if ! gzip -f "$tarfile"; then
      log ERROR "gzip failed for '$stack'"
      TAR_RC=2
      rm -f "$tarfile" "$tarfile.gz"
    fi
  else
    log ERROR "tar failed for '$stack' (rc=$TAR_RC); not compressing"
    rm -f "$tarfile"
  fi
}

# -----------------------------------------------------------------------------
# Send a stack's archive to every configured target under
# <node>/docker/<stack>, run each target's retention, and push per-target
# metrics. Sets STACK_ALL_TARGETS_OK.
# -----------------------------------------------------------------------------
send_stack_to_targets() {
  local stack="$1" name file
  local subpath="${NODE_NAME}/docker/${stack}"
  STACK_TARGETS_TOTAL=0
  STACK_TARGETS_OK=0
  while IFS=$'\t' read -r name file; do
    [[ -n "$name" ]] || continue
    STACK_TARGETS_TOTAL=$((STACK_TARGETS_TOTAL + 1))
    load_target "$name" "$file"
    target_send "$name" "$BACKUP_FILE" "$subpath"
    if [[ $TARGET_RC -eq 0 ]]; then
      target_prune "$name" "$subpath"
      STACK_TARGETS_OK=$((STACK_TARGETS_OK + 1))
      log INFO "stack '$stack' target '$name': delivered"
    else
      TARGET_PRUNED=0
      log ERROR "stack '$stack' target '$name': FAILED (rc=$TARGET_RC)"
    fi
    push_stack_target_metrics "$stack" "$name"
  done < <(list_targets)

  if [[ $STACK_TARGETS_TOTAL -eq 0 ]]; then
    log ERROR "no targets configured; stack '$stack' archive not delivered"
    STACK_ALL_TARGETS_OK=0
  elif [[ $STACK_TARGETS_OK -eq $STACK_TARGETS_TOTAL ]]; then
    STACK_ALL_TARGETS_OK=1
  else
    STACK_ALL_TARGETS_OK=0
  fi
}

# -----------------------------------------------------------------------------
# Push per-stack, per-target metrics.
# -----------------------------------------------------------------------------
push_stack_target_metrics() {
  local stack="$1" name="$2" now ok=0
  now="$(date +%s)"
  [[ ${TARGET_RC:-1} -eq 0 ]] && ok=1
  local body
  body="$(cat <<EOF
# TYPE docker_backup_target_success gauge
docker_backup_target_success ${ok}
# TYPE docker_backup_target_rc gauge
docker_backup_target_rc ${TARGET_RC:-1}
# TYPE docker_backup_target_duration_seconds gauge
docker_backup_target_duration_seconds ${TARGET_DURATION:-0}
# TYPE docker_backup_target_bytes gauge
docker_backup_target_bytes ${TARGET_BYTES:-0}
# TYPE docker_backup_target_pruned_files gauge
docker_backup_target_pruned_files ${TARGET_PRUNED:-0}
# TYPE docker_backup_target_last_run_timestamp_seconds gauge
docker_backup_target_last_run_timestamp_seconds ${now}
EOF
)"
  if [[ $ok -eq 1 ]]; then
    body+="
# TYPE docker_backup_target_last_success_timestamp_seconds gauge
docker_backup_target_last_success_timestamp_seconds ${now}"
  fi
  pushgateway_post "job/docker_backup/instance/${NODE_NAME}/stack/${stack}/target/${name}" "$body"
}

# -----------------------------------------------------------------------------
# Purge local stack tarballs older than RETENTION_DAYS.
# -----------------------------------------------------------------------------
purge_stack_local() {
  local stack="$1"
  find "$DOCKER_BACKUP_DIR" -maxdepth 1 -type f \
    -name "${NODE_NAME}-${stack}-*.tar.gz" -mtime "+${RETENTION_DAYS}" -delete
}

# -----------------------------------------------------------------------------
# Push per-stack metrics to job/docker_backup/instance/<node>/stack/<stack>.
# Args: stack managed did_backup archive_success all_targets size volcount down
#       dur uncovered ignored
# -----------------------------------------------------------------------------
push_stack_metrics() {
  local stack="$1" managed="$2" did_backup="$3" archive_success="$4" \
    all_targets="$5" size="$6" volcount="$7" down="$8" dur="$9" \
    uncovered="${10}" ignored="${11}"
  local now; now="$(date +%s)"
  local body
  body="$(cat <<EOF
# TYPE docker_backup_managed gauge
docker_backup_managed ${managed}
# TYPE docker_backup_uncovered_bind_mounts gauge
docker_backup_uncovered_bind_mounts ${uncovered}
# TYPE docker_backup_ignored_bind_mounts gauge
docker_backup_ignored_bind_mounts ${ignored}
# TYPE docker_backup_last_run_timestamp_seconds gauge
docker_backup_last_run_timestamp_seconds ${now}
EOF
)"
  if [[ "$managed" -eq 1 ]]; then
    body+="
# TYPE docker_backup_volume_count gauge
docker_backup_volume_count ${volcount}"
  fi
  if [[ "$did_backup" -eq 1 ]]; then
    body+="
# TYPE docker_backup_success gauge
docker_backup_success ${archive_success}
# TYPE docker_backup_all_targets_success gauge
docker_backup_all_targets_success ${all_targets}
# TYPE docker_backup_size_bytes gauge
docker_backup_size_bytes ${size}
# TYPE docker_backup_stop_seconds gauge
docker_backup_stop_seconds ${down}
# TYPE docker_backup_duration_seconds gauge
docker_backup_duration_seconds ${dur}"
    if [[ "$archive_success" -eq 1 && "$all_targets" -eq 1 ]]; then
      body+="
# TYPE docker_backup_last_success_timestamp_seconds gauge
docker_backup_last_success_timestamp_seconds ${now}"
    fi
  fi
  pushgateway_post "job/docker_backup/instance/${NODE_NAME}/stack/${stack}" "$body"
}

# -----------------------------------------------------------------------------
# Back up one managed stack end-to-end (stop-cold-copy).
# -----------------------------------------------------------------------------
backup_stack() {
  local stack="$1"
  local start_epoch downtime_start down=0 dur=0 size=0 volcount=0
  local tar_ok=0 integ=0
  start_epoch="$(date +%s)"

  mapfile -t VOL_LINES < <(stack_volumes "$stack")
  volcount=${#VOL_LINES[@]}

  analyze_stack_binds "$stack"

  if [[ $volcount -eq 0 ]]; then
    log WARNING "stack '$stack' has no named volumes; nothing to back up"
    push_stack_metrics "$stack" 1 1 1 1 0 0 0 0 "$UNCOVERED_BINDS" "$IGNORED_BINDS"
    return
  fi

  local ctx wd cf
  ctx="$(stack_compose_context "$stack")"
  wd="${ctx%%$'\t'*}"; cf="${ctx#*$'\t'}"

  log INFO "backing up stack '$stack' (${volcount} volume(s)); stopping it now"
  downtime_start="$(date +%s)"
  _compose_action stop "$stack" "$wd" "$cf" || log ERROR "failed to stop '$stack' cleanly"

  build_stack_archive "$stack" "$wd" "$cf"

  _compose_action start "$stack" "$wd" "$cf" || log ERROR "failed to restart '$stack'"
  down=$(( $(date +%s) - downtime_start ))
  log INFO "stack '$stack' restarted (downtime ${down}s)"

  [[ ${TAR_RC:-1} -le 1 ]] && tar_ok=1

  if [[ -s "$BACKUP_FILE" ]] && gzip -t "$BACKUP_FILE" 2>/dev/null; then
    integ=1
    size="$(wc -c < "$BACKUP_FILE" | tr -d '[:space:]')"
    log INFO "archive integrity OK for '$stack' (${size} bytes)"
  else
    log ERROR "archive integrity failed for '$stack'"
  fi

  purge_stack_local "$stack"

  local archive_ok=0
  [[ $tar_ok -eq 1 && $integ -eq 1 ]] && archive_ok=1

  send_stack_to_targets "$stack"

  dur=$(( $(date +%s) - start_epoch ))
  log INFO "stack '$stack' done: archive=${archive_ok} all_targets=${STACK_ALL_TARGETS_OK} (${STACK_TARGETS_OK}/${STACK_TARGETS_TOTAL}) size=${size}B downtime=${down}s"
  push_stack_metrics "$stack" 1 1 "$archive_ok" "$STACK_ALL_TARGETS_OK" "$size" "$volcount" "$down" "$dur" \
    "$UNCOVERED_BINDS" "$IGNORED_BINDS"
}

# -----------------------------------------------------------------------------
# Warn about BIND_IGNORE entries that matched nothing this run.
# -----------------------------------------------------------------------------
warn_stale_bind_ignore() {
  local i
  for i in "${!BIND_IGNORE[@]}"; do
    [[ -n "${BIND_IGNORE[$i]}" ]] || continue
    if [[ -z "${BIND_IGNORE_HITS[$i]:-}" ]]; then
      log WARNING "stale BIND_IGNORE entry (matched nothing): ${BIND_IGNORE[$i]}"
    fi
  done
}

# -----------------------------------------------------------------------------
# Push the node-level detector metric.
# -----------------------------------------------------------------------------
push_detector_metrics() {
  local now; now="$(date +%s)"
  local body
  body="$(cat <<EOF
# TYPE docker_backup_unmanaged_stacks gauge
docker_backup_unmanaged_stacks ${UNMANAGED_COUNT}
# TYPE docker_backup_last_run_timestamp_seconds gauge
docker_backup_last_run_timestamp_seconds ${now}
EOF
)"
  pushgateway_post "job/docker_backup/instance/${NODE_NAME}" "$body"
}

# -----------------------------------------------------------------------------
# EXIT trap: rotate logs.
# -----------------------------------------------------------------------------
finish() {
  local rc=$?
  rotate_logs "$LOG_DIR"
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

  if [[ -z "${_SELF_UPDATED:-}" && -z "${DRY_RUN:-}" && -z "${NO_SELF_UPDATE:-}" ]]; then
    if self_update; then
      export _SELF_UPDATED=1
      exec "$0" "$@"
    fi
  fi

  load_config
  setup_logging "$LOG_DIR"
  trap finish EXIT
  require_docker

  log INFO "starting docker-compose backup for node '${NODE_NAME}'"

  local projects=()
  mapfile -t projects < <(discover_compose_projects)
  log INFO "discovered ${#projects[@]} compose project(s): ${projects[*]:-<none>}"

  # Initialize BIND_IGNORE hit tracking.
  local i
  for i in "${!BIND_IGNORE[@]}"; do
    BIND_IGNORE_HITS[$i]=""
  done

  local s
  # Back up managed stacks (or, in dry-run, evaluate them without downtime).
  for s in "${STACKS[@]:-}"; do
    [[ -n "$s" ]] || continue
    if ! printf '%s\n' "${projects[@]:-}" | grep -qxF "$s"; then
      log WARNING "configured stack '$s' is not a running compose project (down or renamed?)"
    fi
    if [[ -n "${DRY_RUN:-}" ]]; then
      mapfile -t VOL_LINES < <(stack_volumes "$s")
      analyze_stack_binds "$s"
      log INFO "DRY_RUN: would back up '$s' (${#VOL_LINES[@]} volume(s))"
      push_stack_metrics "$s" 1 0 0 0 0 "${#VOL_LINES[@]}" 0 0 \
        "$UNCOVERED_BINDS" "$IGNORED_BINDS"
    else
      backup_stack "$s"
    fi
  done

  # Analyze binds for every non-managed project; only count as "unmanaged
  # stateful" those that own named volumes (i.e. something for stop-cold-copy).
  UNMANAGED_COUNT=0
  for s in "${projects[@]:-}"; do
    [[ -n "$s" ]] || continue
    is_managed "$s" && continue
    analyze_stack_binds "$s"
    if stack_has_named_volumes "$s"; then
      UNMANAGED_COUNT=$((UNMANAGED_COUNT + 1))
      log WARNING "UNMANAGED stateful stack (owns named volumes, not in STACKS): $s"
    else
      log INFO "compose project '$s' has no named volumes (state in bind mounts); bind coverage checked"
    fi
    push_stack_metrics "$s" 0 0 0 0 0 0 0 0 "$UNCOVERED_BINDS" "$IGNORED_BINDS"
  done

  warn_stale_bind_ignore
  push_detector_metrics
  log INFO "docker-compose backup finished: managed=${#STACKS[@]} unmanaged=${UNMANAGED_COUNT}"
}

main "$@"
