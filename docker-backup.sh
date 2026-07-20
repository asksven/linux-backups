#!/usr/bin/env bash
# =============================================================================
# docker-backup.sh — back up Docker Compose stack state (named volumes, compose
# files, and bind-mounted data) as per-stack archives, using stop-cold-copy for
# consistency.
#
# Flow:
#   1. Self-update from git (default branch "main", override with --branch).
#   2. Load secrets + docker-backup.conf.
#   3. Discover stacks that own named volumes or non-ephemeral bind mounts
#      (com.docker.compose.project label).
#   4. For each stack on the STACKS allowlist:
#        docker compose stop -> tar each volume into volumes/<vol>/, capture
#        compose files into compose/, capture bind mounts into binds/, write
#        manifest -> docker compose start -> verify -> purge local -> azcopy copy.
#   5. Detect stateful stacks NOT on the allowlist (alert only, never auto-add).
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
UNMANAGED_COUNT=0
FAILED_STACKS=0
declare -a VOL_LINES=()
declare -A BIND_IGNORE_HITS=()
declare -a CAPTURE_BINDS=()
declare -a EXCLUDED_BINDS=()
declare -a COMPOSE_FILE_ENTRIES=()

# Per-stack restart guard: while non-empty, a stack has been stopped for
# backup and has not yet had a start attempt run. See restart_guard_run().
RESTART_GUARD_STACK=""
RESTART_GUARD_WD=""
RESTART_GUARD_CF=""

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
# Configuration loading. docker-backup.conf is required; no longer reads
# backup.conf or INCLUDE_PATHS — the docker backup is self-contained.
# -----------------------------------------------------------------------------
load_config() {
  local secrets="$CONFIG_DIR/secrets.env"
  local conf="$CONFIG_DIR/docker-backup.conf"

  load_secrets "$secrets"

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
  DOCKER_BACKUP_DIR="${DOCKER_BACKUP_DIR:-/var/backups/linux-backups/docker}"
  LOG_DIR="${DOCKER_LOG_DIR:-$DOCKER_BACKUP_DIR/logs}"

  # STACKS may legitimately be empty (detection-only run). Ensure it exists.
  if [[ -z "${STACKS+x}" ]]; then
    STACKS=()
  fi
  if [[ -z "${BIND_IGNORE+x}" ]]; then
    BIND_IGNORE=()
  fi
  if [[ -z "${BIND_INCLUDE_NETFS+x}" ]]; then
    BIND_INCLUDE_NETFS=()
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
# Classify a stack's bind mounts using the shared 5-rule precedence decision
# (bind_capture_verdict, in lib.sh). Populates: CAPTURE_BINDS, EXCLUDED_BINDS
# (tab-separated fields per entry), deduplicated by source path: identical
# source data mounted by several containers/destinations is captured/excluded
# once, with all its destination/RO relationships preserved.
# Sets:      BIND_COUNT, EXCLUDED_BINDS_COUNT, NETWORK_BINDS_COUNT (all counts
#            of UNIQUE source paths, not container-mount occurrences).
#
# CAPTURE_BINDS entries:  <src>\t<fstype>\t<kind>\t<mounts>
#   <mounts> is one or more "<dst>\x1f<ro>" records joined by \x1e.
# EXCLUDED_BINDS entries: <src>\t<dst>\t<fstype>\t<reason>  (first destination
#   seen for that source; reason/fstype are the same for every mount of a
#   given source, since the verdict only depends on stack+source).
# Archive path for entry i is: binds/<i>  (index into CAPTURE_BINDS). <kind>
# ("file"|"directory"|"unknown") is determined here, before the stack is
# stopped, so the manifest and the archive both agree on it. BIND_BYTES
# includes force-captured network binds, since they are archived too.
# -----------------------------------------------------------------------------
classify_stack_binds() {
  local stack="$1" src dst ro kind entry
  local -A _cap_idx=() _excl_idx=()
  CAPTURE_BINDS=()
  EXCLUDED_BINDS=()
  BIND_COUNT=0
  BIND_BYTES=0
  EXCLUDED_BINDS_COUNT=0
  NETWORK_BINDS_COUNT=0

  while IFS=$'\t' read -r src dst ro; do
    [[ -n "$src" ]] || continue

    bind_capture_verdict "$stack" "$src"

    case "$BIND_VERDICT" in
      network-forced|capture)
        if [[ -n "${_cap_idx[$src]+x}" ]]; then
          CAPTURE_BINDS[${_cap_idx[$src]}]+=$'\x1e'"${dst}"$'\x1f'"${ro}"
        else
          [[ "$BIND_VERDICT" == "network-forced" ]] \
            && log INFO "bind force-captured via BIND_INCLUDE_NETFS: $src (fstype=$BIND_FSTYPE) [$stack]"
          kind="$(_bind_kind "$src")"
          _cap_idx[$src]=${#CAPTURE_BINDS[@]}
          CAPTURE_BINDS+=( "${src}"$'\t'"${BIND_FSTYPE}"$'\t'"${kind}"$'\t'"${dst}"$'\x1f'"${ro}" )
        fi
        ;;
      network-excluded)
        if [[ -z "${_excl_idx[$src]+x}" ]]; then
          _excl_idx[$src]=1
          log INFO "bind auto-excluded (network-fs, fstype=$BIND_FSTYPE): $src [$stack]"
          EXCLUDED_BINDS+=( "${src}"$'\t'"${dst}"$'\t'"${BIND_FSTYPE}"$'\t'"network-fs" )
          NETWORK_BINDS_COUNT=$((NETWORK_BINDS_COUNT + 1))
        fi
        ;;
      bind-ignore)
        if [[ -z "${_excl_idx[$src]+x}" ]]; then
          _excl_idx[$src]=1
          log INFO "bind excluded (BIND_IGNORE): $src [$stack]"
          EXCLUDED_BINDS+=( "${src}"$'\t'"${dst}"$'\t'"${BIND_FSTYPE}"$'\t'"bind-ignore" )
          EXCLUDED_BINDS_COUNT=$((EXCLUDED_BINDS_COUNT + 1))
        fi
        ;;
    esac
  done < <(stack_bind_mounts "$stack")

  BIND_COUNT=${#CAPTURE_BINDS[@]}

  for entry in "${CAPTURE_BINDS[@]}"; do
    src="${entry%%$'\t'*}"
    local _sz
    _sz="$(du -sb "$src" 2>/dev/null | awk '{print $1}')" || true
    BIND_BYTES=$(( BIND_BYTES + ${_sz:-0} ))
  done
}

# -----------------------------------------------------------------------------
# Resolve the archive-path mapping for a stack's labelled compose config
# files, detecting basename collisions. Sets COMPOSE_FILE_ENTRIES (entries:
# <archive_path>\t<source_path>). A labelled file that is missing/unreadable
# is a hard failure (returns 1) -- it must never be silently dropped.
# -----------------------------------------------------------------------------
build_compose_file_entries() {
  local stack="$1"
  local _cf_files=() _cf_seen _cf_idx _f _bn _aname rc=0
  COMPOSE_FILE_ENTRIES=()
  mapfile -t _cf_files < <(stack_compose_files "$stack")
  declare -A _cf_seen=()
  _cf_idx=0
  for _f in "${_cf_files[@]}"; do
    [[ -n "$_f" ]] || continue
    if [[ ! -f "$_f" || ! -r "$_f" ]]; then
      log ERROR "compose config file missing/unreadable: $_f [$stack]"
      rc=1
      continue
    fi
    _bn="$(basename "$_f")"
    if [[ -n "${_cf_seen[$_bn]+x}" ]]; then
      _aname="${_cf_idx}-${_bn}"
    else
      _aname="$_bn"
      _cf_seen[$_bn]=1
    fi
    COMPOSE_FILE_ENTRIES+=( "compose/${_aname}"$'\t'"${_f}" )
    _cf_idx=$((_cf_idx + 1))
  done
  return $rc
}

# -----------------------------------------------------------------------------
# Validate that everything backup_stack is about to archive actually exists
# and is readable *before* the stack is stopped, so a doomed backup never
# incurs downtime. Reads: VOL_LINES, CAPTURE_BINDS (already populated by the
# caller via stack_volumes/classify_stack_binds). Populates
# COMPOSE_FILE_ENTRIES as a side effect. Returns 1 if anything is invalid.
# -----------------------------------------------------------------------------
validate_stack_inputs() {
  local stack="$1" rc=0
  local line name mp entry src kind

  for line in "${VOL_LINES[@]}"; do
    name="${line%%$'\t'*}"; mp="${line#*$'\t'}"
    if [[ ! -d "$mp" || ! -r "$mp" ]]; then
      log ERROR "volume '$name' mountpoint not accessible: $mp [$stack]"
      rc=1
    fi
  done

  build_compose_file_entries "$stack" || rc=1

  for entry in "${CAPTURE_BINDS[@]}"; do
    IFS=$'\t' read -r src _ kind _ <<< "$entry"
    case "$kind" in
      directory) [[ -d "$src" && -r "$src" ]] || { log ERROR "bind source not accessible: $src [$stack]"; rc=1; } ;;
      file)      [[ -f "$src" && -r "$src" ]] || { log ERROR "bind source not accessible: $src [$stack]"; rc=1; } ;;
      *)         log ERROR "bind source of unresolved kind: $src [$stack]"; rc=1 ;;
    esac
  done

  return $rc
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
# Build manifest.json (schema 2) for the current stack.
# Reads: VOL_LINES, COMPOSE_FILE_ENTRIES, CAPTURE_BINDS, EXCLUDED_BINDS.
# -----------------------------------------------------------------------------
write_manifest() {
  local stack="$1" wd="$2" cf="$3"
  local epoch now line name mp entry first
  epoch="$(date +%s)"
  now="$(date -u '+%FT%TZ')"

  # volumes[]
  local vjson="" ; first=1
  for line in "${VOL_LINES[@]}"; do
    name="${line%%$'\t'*}"; mp="${line#*$'\t'}"
    [[ $first -eq 1 ]] || vjson+=","
    first=0
    vjson+="$(printf '{"name":"%s","mountpoint":"%s","archive_path":"volumes/%s"}' \
      "$(json_escape "$name")" "$(json_escape "$mp")" "$(json_escape "$name")")"
  done

  # compose.config_files[]
  local cfjson="" f ; first=1
  local _cfs=()
  IFS=',' read -ra _cfs <<< "$cf"
  for f in "${_cfs[@]}"; do
    [[ -n "$f" ]] || continue
    [[ $first -eq 1 ]] || cfjson+=","
    first=0
    cfjson+="$(printf '"%s"' "$(json_escape "$f")")"
  done

  # compose.captured_files[]
  local capjson="" apath fpath ; first=1
  for entry in "${COMPOSE_FILE_ENTRIES[@]}"; do
    apath="${entry%%$'\t'*}"; fpath="${entry#*$'\t'}"
    [[ $first -eq 1 ]] || capjson+=","
    first=0
    capjson+="$(printf '{"path":"%s","source":"%s"}' \
      "$(json_escape "$(basename "$apath")")" "$(json_escape "$fpath")")"
  done

  # binds[]. Each unique captured source becomes one record with a mounts[]
  # list preserving every destination/RO relationship it had (see
  # classify_stack_binds -- entries are already deduplicated by source).
  local bindsjson="" bi=0 src fstype kind mounts_field rec dst ro ro_bool ; first=1
  local mjson mfirst _mrecs
  for entry in "${CAPTURE_BINDS[@]}"; do
    IFS=$'\t' read -r src fstype kind mounts_field <<< "$entry"
    [[ $first -eq 1 ]] || bindsjson+=","
    first=0

    mjson="" ; mfirst=1
    IFS=$'\x1e' read -ra _mrecs <<< "$mounts_field"
    for rec in "${_mrecs[@]}"; do
      dst="${rec%%$'\x1f'*}"; ro="${rec#*$'\x1f'}"
      [[ "$ro" == "true" ]] && ro_bool="true" || ro_bool="false"
      [[ $mfirst -eq 1 ]] || mjson+=","
      mfirst=0
      mjson+="$(printf '{"destination":"%s","ro":%s}' "$(json_escape "$dst")" "$ro_bool")"
    done

    bindsjson+="$(printf '{"source":"%s","fstype":"%s","kind":"%s","archive_path":"binds/%d","mounts":[%s]}' \
      "$(json_escape "$src")" "$(json_escape "$fstype")" "$(json_escape "$kind")" "$bi" "$mjson")"
    bi=$((bi + 1))
  done

  # excluded_binds[]
  local excljson="" reason ; first=1
  for entry in "${EXCLUDED_BINDS[@]}"; do
    IFS=$'\t' read -r src dst fstype reason <<< "$entry"
    [[ $first -eq 1 ]] || excljson+=","
    first=0
    excljson+="$(printf '{"source":"%s","destination":"%s","fstype":"%s","reason":"%s"}' \
      "$(json_escape "$src")" "$(json_escape "$dst")" "$(json_escape "$fstype")" "$(json_escape "$reason")")"
  done

  cat <<EOF
{
  "schema": 2,
  "node": "$(json_escape "$NODE_NAME")",
  "stack": "$(json_escape "$stack")",
  "timestamp": "$now",
  "epoch": $epoch,
  "compose": {
    "working_dir": "$(json_escape "$wd")",
    "config_files": [${cfjson}],
    "captured_files": [${capjson}]
  },
  "volumes": [${vjson}],
  "binds": [${bindsjson}],
  "excluded_binds": [${excljson}]
}
EOF
}

# -----------------------------------------------------------------------------
# Create the per-stack tarball: manifest.json + volumes/<vol>/... +
# compose/<file> + binds/<id>/... . Uses an uncompressed intermediate .tar
# (so entries can be appended with path prefixes) then gzips it.
# Sets BACKUP_FILE and TAR_RC. Reads COMPOSE_FILE_ENTRIES, which must already
# be populated by validate_stack_inputs (called before the stack was stopped).
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

  # Append named volumes.
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

  # Append compose files.
  local _entry _apath _fpath _fbname _rc
  for _entry in "${COMPOSE_FILE_ENTRIES[@]}"; do
    _apath="${_entry%%$'\t'*}"; _fpath="${_entry#*$'\t'}"
    _fbname="$(basename "$_fpath")"
    tar --append --file "$tarfile" --numeric-owner \
      -C "$(dirname "$_fpath")" --transform "s#^${_fbname}#${_apath}#" "$_fbname"
    _rc=$?
    [[ $_rc -gt $TAR_RC ]] && TAR_RC=$_rc
  done

  # Append bind-mount data. <kind> was determined by classify_stack_binds
  # (before the stack was stopped) and drives both the manifest and this
  # archive layout, so the two always agree. Re-check existence/kind here too
  # (not just at classify time): a bind that disappeared, changed kind, or
  # became unreadable between classification and now is a hard archive
  # failure -- its manifest entry must never be left pointing at missing data.
  local _bi=0 _src _kind _bentry _sfname
  for _bentry in "${CAPTURE_BINDS[@]}"; do
    IFS=$'\t' read -r _src _ _kind _ <<< "$_bentry"
    _rc=0
    if [[ "$_kind" == "directory" && -d "$_src" && -r "$_src" ]]; then
      tar --append --file "$tarfile" --numeric-owner \
        -C "$_src" --transform "s#^\.#binds/${_bi}#" .
      _rc=$?
    elif [[ "$_kind" == "file" && -f "$_src" && -r "$_src" ]]; then
      _sfname="$(basename "$_src")"
      tar --append --file "$tarfile" --numeric-owner \
        -C "$(dirname "$_src")" \
        --transform "s#^${_sfname}#binds/${_bi}/${_sfname}#" "$_sfname"
      _rc=$?
    else
      log ERROR "bind source missing/unreadable or no longer a $_kind: $_src [$stack] (archive failed)"
      _rc=2
    fi
    [[ $_rc -gt $TAR_RC ]] && TAR_RC=$_rc
    _bi=$((_bi + 1))
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
    bind_count="${10}" bind_bytes="${11}" excluded_binds="${12}" network_binds="${13}"
  local now; now="$(date +%s)"
  local body
  body="$(cat <<EOF
# TYPE docker_backup_managed gauge
docker_backup_managed ${managed}
# TYPE docker_backup_bind_count gauge
docker_backup_bind_count ${bind_count}
# TYPE docker_backup_bind_bytes gauge
docker_backup_bind_bytes ${bind_bytes}
# TYPE docker_backup_excluded_binds gauge
docker_backup_excluded_binds ${excluded_binds}
# TYPE docker_backup_network_binds gauge
docker_backup_network_binds ${network_binds}
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
  local stop_ok=0 archive_ok=0 restart_ok=0
  start_epoch="$(date +%s)"

  mapfile -t VOL_LINES < <(stack_volumes "$stack")
  volcount=${#VOL_LINES[@]}

  classify_stack_binds "$stack"

  if [[ $volcount -eq 0 ]]; then
    log INFO "stack '$stack' has no named volumes; backing up compose files and bind data only"
  fi

  if ! validate_stack_inputs "$stack"; then
    dur=$(( $(date +%s) - start_epoch ))
    log ERROR "stack '$stack': input validation failed; aborting backup (stack was not stopped)"
    push_stack_metrics "$stack" 1 1 0 0 0 "$volcount" 0 "$dur" \
      "$BIND_COUNT" "$BIND_BYTES" "$EXCLUDED_BINDS_COUNT" "$NETWORK_BINDS_COUNT"
    return
  fi

  local ctx wd cf
  ctx="$(stack_compose_context "$stack")"
  wd="${ctx%%$'\t'*}"; cf="${ctx#*$'\t'}"

  log INFO "backing up stack '$stack' (${volcount} volume(s), ${BIND_COUNT} bind(s)); stopping it now"
  downtime_start="$(date +%s)"
  if _compose_action stop "$stack" "$wd" "$cf"; then
    stop_ok=1
    log INFO "stack '$stack': stop OK"
  else
    log ERROR "stack '$stack': failed to stop cleanly"
  fi

  if [[ $stop_ok -eq 1 ]]; then
    # Arm the restart guard: from here until a start attempt has run below,
    # any unexpected exit (shell error, signal) triggers a best-effort
    # restart via restart_guard_run() in the EXIT trap.
    RESTART_GUARD_STACK="$stack"; RESTART_GUARD_WD="$wd"; RESTART_GUARD_CF="$cf"

    build_stack_archive "$stack" "$wd" "$cf"
    [[ ${TAR_RC:-1} -le 1 ]] && tar_ok=1

    if [[ -s "$BACKUP_FILE" ]] && gzip -t "$BACKUP_FILE" 2>/dev/null; then
      integ=1
      size="$(wc -c < "$BACKUP_FILE" | tr -d '[:space:]')"
      log INFO "stack '$stack': archive integrity OK (${size} bytes)"
    else
      log ERROR "stack '$stack': archive integrity failed"
    fi
    [[ $tar_ok -eq 1 && $integ -eq 1 ]] && archive_ok=1
    log INFO "stack '$stack': archive=${archive_ok}"
  else
    log ERROR "stack '$stack': stop failed; skipping archive"
  fi

  # Best-effort restart regardless of stop/archive outcome, then clear the
  # guard -- a start attempt has now run, whether or not it succeeded.
  if _compose_action start "$stack" "$wd" "$cf"; then
    restart_ok=1
    log INFO "stack '$stack': restart OK"
  else
    log ERROR "stack '$stack': failed to restart"
  fi
  RESTART_GUARD_STACK=""
  down=$(( $(date +%s) - downtime_start ))

  purge_stack_local "$stack"

  # Delivery only depends on having a valid archive (stop_ok && archive_ok):
  # a restart failure doesn't invalidate an already-built archive, and target
  # metrics describe delivery independently of overall stack success.
  if [[ $stop_ok -eq 1 && $archive_ok -eq 1 ]]; then
    send_stack_to_targets "$stack"
  else
    log ERROR "stack '$stack': skipping target delivery (stop_ok=${stop_ok} archive_ok=${archive_ok})"
    STACK_TARGETS_TOTAL=0
    STACK_TARGETS_OK=0
    STACK_ALL_TARGETS_OK=0
  fi

  local overall_ok=0
  [[ $stop_ok -eq 1 && $archive_ok -eq 1 && $restart_ok -eq 1 ]] && overall_ok=1
  if [[ $overall_ok -ne 1 ]]; then
    FAILED_STACKS=$((FAILED_STACKS + 1))
  fi

  dur=$(( $(date +%s) - start_epoch ))
  log INFO "stack '$stack' done: stop=${stop_ok} archive=${archive_ok} restart=${restart_ok} success=${overall_ok} all_targets=${STACK_ALL_TARGETS_OK} (${STACK_TARGETS_OK}/${STACK_TARGETS_TOTAL}) size=${size}B downtime=${down}s"
  push_stack_metrics "$stack" 1 1 "$overall_ok" "$STACK_ALL_TARGETS_OK" "$size" "$volcount" "$down" "$dur" \
    "$BIND_COUNT" "$BIND_BYTES" "$EXCLUDED_BINDS_COUNT" "$NETWORK_BINDS_COUNT"
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
# Safety net for RESTART_GUARD_STACK: if a stack was stopped for backup and
# the script exits (shell error, signal, ...) before a start attempt could
# run, best-effort restart it here so a crash never leaves a stack down.
# Cleared by backup_stack() itself once a normal start attempt has run.
# -----------------------------------------------------------------------------
restart_guard_run() {
  if [[ -n "$RESTART_GUARD_STACK" ]]; then
    log ERROR "restart guard: unexpected exit while '$RESTART_GUARD_STACK' was stopped; attempting best-effort restart"
    _compose_action start "$RESTART_GUARD_STACK" "$RESTART_GUARD_WD" "$RESTART_GUARD_CF" \
      || log ERROR "restart guard: failed to restart '$RESTART_GUARD_STACK'"
    RESTART_GUARD_STACK=""
  fi
}

# -----------------------------------------------------------------------------
# EXIT trap: run the restart guard safety net, then rotate logs.
# -----------------------------------------------------------------------------
finish() {
  local rc=$?
  restart_guard_run
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
  # Convert INT/TERM into a normal exit so the EXIT trap (and its restart
  # guard) always gets a chance to run exactly once.
  trap 'exit 130' INT
  trap 'exit 143' TERM
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
      classify_stack_binds "$s"
      log INFO "DRY_RUN: would back up '$s' (${#VOL_LINES[@]} volume(s))"
      push_stack_metrics "$s" 1 0 0 0 0 "${#VOL_LINES[@]}" 0 0 \
        "$BIND_COUNT" "$BIND_BYTES" "$EXCLUDED_BINDS_COUNT" "$NETWORK_BINDS_COUNT"
    else
      backup_stack "$s"
    fi
  done

  # Analyze binds for every non-managed project; count as "unmanaged stateful"
  # those that own named volumes OR at least one non-ephemeral bind mount
  # (bind-only projects are stateful too — see stack_is_stateful in lib.sh).
  UNMANAGED_COUNT=0
  for s in "${projects[@]:-}"; do
    [[ -n "$s" ]] || continue
    is_managed "$s" && continue
    classify_stack_binds "$s"
    if stack_is_stateful "$s"; then
      UNMANAGED_COUNT=$((UNMANAGED_COUNT + 1))
      log WARNING "UNMANAGED stateful stack (owns named volumes or bind-mount state, not in STACKS): $s"
    fi
    push_stack_metrics "$s" 0 0 0 0 0 0 0 0 \
      "$BIND_COUNT" 0 "$EXCLUDED_BINDS_COUNT" "$NETWORK_BINDS_COUNT"
  done

  warn_stale_bind_ignore
  push_detector_metrics
  log INFO "docker-compose backup finished: managed=${#STACKS[@]} unmanaged=${UNMANAGED_COUNT} failed=${FAILED_STACKS}"

  if [[ $FAILED_STACKS -gt 0 ]]; then
    return 1
  fi
}

main "$@"
