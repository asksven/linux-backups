# shellcheck shell=bash
# =============================================================================
# lib.sh — shared helpers for linux-backups.
#
# This file is meant to be SOURCED, not executed. It provides:
#   * generic backup helpers (logging, self-update, secrets, logging setup,
#     log rotation, azcopy upload, Pushgateway push);
#   * Docker Compose discovery helpers used by docker-backup.sh and
#     docker-backup-init.sh.
#
# Callers are expected to define REPO_DIR before calling self_update, and to
# have PROM_GTW available (possibly empty) before calling pushgateway_post.
# =============================================================================

# -----------------------------------------------------------------------------
# Logging helper: log <LEVEL> <message...>
# -----------------------------------------------------------------------------
log() {
  local level="$1"; shift
  printf '[%s] %s: %s\n' "$(date '+%F %T')" "$level" "$*"
}

# -----------------------------------------------------------------------------
# Self-update: fetch + hard-reset to the requested branch. Fails SOFT: if git is
# unavailable or the remote is unreachable, log a warning and return non-zero so
# the caller continues with the current local version. Uses REPO_DIR and the
# optional BACKUP_BRANCH (defaults to "main").
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
# Source a secrets file (exports DEST_URL, SAS_TOKEN, PROM_GTW, ...). Errors and
# exits if the file is missing or unreadable.
# -----------------------------------------------------------------------------
load_secrets() {
  local secrets="$1"
  if [[ ! -r "$secrets" ]]; then
    log ERROR "secrets file not found or unreadable: $secrets"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$secrets"
}

# -----------------------------------------------------------------------------
# Logging setup: tee everything to a per-run logfile under <log_dir>.
# -----------------------------------------------------------------------------
setup_logging() {
  local log_dir="$1"
  mkdir -p "$log_dir"
  local logfile
  logfile="$log_dir/run-$(date '+%F-%H-%M-%S').log"
  exec > >(tee -a "$logfile") 2>&1
  log INFO "logging to $logfile"
}

# -----------------------------------------------------------------------------
# Keep only the N most recent run logs (default 5) in <log_dir>.
# -----------------------------------------------------------------------------
rotate_logs() {
  local log_dir="$1"
  local keep="${2:-5}"
  [[ -n "$log_dir" && -d "$log_dir" ]] || return 0
  local old
  # Filenames are controlled timestamps (run-<ts>.log), so ls -t is safe here.
  # shellcheck disable=SC2012
  old="$(ls -1t "$log_dir"/run-*.log 2>/dev/null | tail -n +"$((keep + 1))" || true)"
  [[ -z "$old" ]] && return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] && rm -f "$f"
  done <<< "$old"
}

# -----------------------------------------------------------------------------
# Upload a single file with `azcopy copy`. Sets globals:
#   AZCOPY_RC     — azcopy exit code
#   AZCOPY_FAILED — parsed "Number of Transfers Failed" (0 when clean)
# Args: <src_file> <dest_display> <dest_with_sas> <block_size_mb>
# -----------------------------------------------------------------------------
azcopy_copy() {
  local src="$1" dest_display="$2" dest="$3" block_size_mb="$4"
  local out
  log INFO "uploading to $dest_display (block-size=${block_size_mb}MiB)"
  set +e
  out="$(azcopy copy "$src" "$dest" --block-size-mb="$block_size_mb" 2>&1)"
  # AZCOPY_RC / AZCOPY_FAILED are read by callers.
  # shellcheck disable=SC2034
  AZCOPY_RC=$?
  set -e
  printf '%s\n' "$out"
  # shellcheck disable=SC2034
  AZCOPY_FAILED="$(grep -oE 'Number of Transfers Failed: [0-9]+' <<< "$out" \
    | grep -oE '[0-9]+$' || true)"
  AZCOPY_FAILED="${AZCOPY_FAILED:-0}"
}

# -----------------------------------------------------------------------------
# POST a Prometheus exposition body to the Pushgateway under <label_path>
# (e.g. "job/linux_backup/instance/node-1"). Skips gracefully when PROM_GTW is
# empty or curl is missing, and never fails the run on push errors.
# Args: <label_path> <body>
# -----------------------------------------------------------------------------
pushgateway_post() {
  local label_path="$1" body="$2"
  if [[ -z "${PROM_GTW:-}" ]]; then
    log INFO "Pushgateway URL not set; skipping metrics push ($label_path)"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log WARNING "curl not found; cannot push metrics"
    return 0
  fi
  local url="${PROM_GTW%/}/metrics/${label_path}"
  if printf '%s' "$body" | curl --fail --silent --show-error --data-binary @- "$url"; then
    log INFO "metrics pushed to $url"
  else
    log WARNING "failed to push metrics to $url"
  fi
}

# =============================================================================
# Backup targets
#
# A target is a destination for the built archive (e.g. azcopy->Azure, rsync->ssh).
# Each target is a file $CONFIG_DIR/targets/<name>.conf sourced as bash, defining
# TYPE (azure|rsync), transport params, and RETENTION_MODE (none|count[,KEEP]).
# The filename stem is the target's name (metric label + used only for logging).
#
# Callers: iterate `list_targets`, `load_target` each, `target_send`, then on
# success `target_prune`. Per-target result globals: TARGET_RC, TARGET_BYTES,
# TARGET_DURATION, TARGET_PRUNED.
# =============================================================================

# Print the lowercased ENABLED value of a target file (default "true"),
# evaluated in a subshell so it cannot pollute the caller's environment.
_target_enabled() {
  (
    ENABLED="true"
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1
    printf '%s' "${ENABLED,,}"
  )
}

# Print "<name>\t<file>" for each enabled target under $CONFIG_DIR/targets. When
# none exist but a legacy DEST_URL is set (secrets.env), emit the compat shim
# line "azure\t__compat__".
list_targets() {
  local dir="$CONFIG_DIR/targets" f name found=0
  if [[ -d "$dir" ]]; then
    for f in "$dir"/*.conf; do
      [[ -e "$f" ]] || continue
      if [[ "$(_target_enabled "$f")" == "false" ]]; then
        log INFO "target '$(basename "$f" .conf)' is disabled (ENABLED=false); skipping" >&2
        continue
      fi
      name="$(basename "$f" .conf)"
      printf '%s\t%s\n' "$name" "$f"
      found=1
    done
  fi
  if [[ $found -eq 0 && -n "${DEST_URL:-}" ]]; then
    printf 'azure\t__compat__\n'
  fi
}

# Load a target's variables into the current shell. Resets target-scoped vars
# first so values never leak between targets. The compat shim reuses the legacy
# DEST_URL/SAS_TOKEN/BLOCK_SIZE_MB from secrets.env.
load_target() {
  local file="$2"
  TYPE=""; RETENTION_MODE="none"; KEEP=""
  DEST=""; SSH_KEY=""; SSH_OPTS=""; BW_LIMIT=""
  if [[ "$file" == "__compat__" ]]; then
    TYPE="azure"
    RETENTION_MODE="none"
    BLOCK_SIZE_MB="${BLOCK_SIZE_MB:-100}"
    return 0
  fi
  DEST_URL=""; SAS_TOKEN=""; BLOCK_SIZE_MB="${BLOCK_SIZE_MB:-100}"
  # shellcheck disable=SC1090
  source "$file"
  RETENTION_MODE="${RETENTION_MODE:-none}"
  BLOCK_SIZE_MB="${BLOCK_SIZE_MB:-100}"
}

# Send <archive> to the currently-loaded target under remote <subpath>.
# Sets TARGET_RC (0=ok), TARGET_BYTES, TARGET_DURATION (read by callers).
# shellcheck disable=SC2034
target_send() {
  local name="$1" archive="$2" subpath="$3" start
  start="$(date +%s)"
  TARGET_RC=1
  TARGET_BYTES=0
  case "$TYPE" in
    azure) _send_azure "$archive" "$subpath" ;;
    rsync) _send_rsync "$archive" "$subpath" ;;
    *) log ERROR "target '$name': unknown TYPE '${TYPE:-<empty>}'"; TARGET_RC=2 ;;
  esac
  TARGET_DURATION=$(( $(date +%s) - start ))
  [[ -f "$archive" ]] && TARGET_BYTES="$(wc -c < "$archive" | tr -d '[:space:]')"
  return 0
}

_send_azure() {
  local archive="$1" subpath="$2" base dest_display dest
  base="$(basename "$archive")"
  dest_display="${DEST_URL%/}/${subpath}/${base}"
  dest="${DEST_URL%/}/${subpath}/${base}${SAS_TOKEN:-}"
  azcopy_copy "$archive" "$dest_display" "$dest" "${BLOCK_SIZE_MB:-100}"
  if [[ $AZCOPY_RC -eq 0 && "${AZCOPY_FAILED:-0}" -eq 0 ]]; then
    TARGET_RC=0
  else
    TARGET_RC="${AZCOPY_RC:-1}"
    [[ $TARGET_RC -eq 0 ]] && TARGET_RC=1
  fi
  return 0
}

# Build the ssh transport command from the loaded target's SSH_KEY/SSH_OPTS.
_target_rsh() {
  local rsh="ssh -o BatchMode=yes"
  [[ -n "$SSH_KEY" ]] && rsh+=" -i $SSH_KEY"
  [[ -n "$SSH_OPTS" ]] && rsh+=" $SSH_OPTS"
  printf '%s' "$rsh"
}

_send_rsync() {
  local archive="$1" subpath="$2" host path remote_dir rsh mkrc
  rsh="$(_target_rsh)"
  host="${DEST%%:*}"; path="${DEST#*:}"
  remote_dir="${path%/}/${subpath}"
  local bw=()
  [[ -n "$BW_LIMIT" ]] && bw=( "--bwlimit=$BW_LIMIT" )
  set +e
  # shellcheck disable=SC2086
  $rsh "$host" "mkdir -p '$remote_dir'"
  mkrc=$?
  rsync -a "${bw[@]}" -e "$rsh" "$archive" "${host}:${remote_dir}/"
  TARGET_RC=$?
  set -e
  [[ $mkrc -ne 0 && $TARGET_RC -eq 0 ]] && TARGET_RC=$mkrc
  return 0
}

# Enforce the loaded target's retention for remote <subpath>. Sets TARGET_PRUNED.
target_prune() {
  local name="$1" subpath="$2"
  TARGET_PRUNED=0
  case "$RETENTION_MODE" in
    none|"")
      log INFO "target '$name': remote retention managed externally (mode=none)" ;;
    count)
      if [[ -z "$KEEP" ]]; then
        log WARNING "target '$name': RETENTION_MODE=count but KEEP unset; skipping prune"
        return 0
      fi
      case "$TYPE" in
        rsync) _prune_rsync "$name" "$subpath" ;;
        azure) log INFO "target '$name': count retention unsupported for azure; use a lifecycle policy" ;;
        *) : ;;
      esac ;;
    *)
      log WARNING "target '$name': unknown RETENTION_MODE '$RETENTION_MODE'" ;;
  esac
}

_prune_rsync() {
  local name="$1" subpath="$2" host path dir rsh out removed=0 file
  rsh="$(_target_rsh)"
  host="${DEST%%:*}"; path="${DEST#*:}"
  dir="${path%/}/${subpath}"
  set +e
  # shellcheck disable=SC2086
  out="$($rsh "$host" "ls -1t '$dir'/*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1))" 2>/dev/null)"
  set -e
  if [[ -z "$out" ]]; then
    log INFO "target '$name': nothing to prune (<= $KEEP kept in $dir)"
    return 0
  fi
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    # shellcheck disable=SC2086
    if $rsh "$host" "rm -f -- '$file'" 2>/dev/null; then
      removed=$((removed + 1))
    fi
  done <<< "$out"
  # TARGET_PRUNED is read by callers.
  # shellcheck disable=SC2034
  TARGET_PRUNED=$removed
  log INFO "target '$name': pruned $removed old archive(s), kept newest $KEEP"
}

# -----------------------------------------------------------------------------
# Preflight credential/reachability probe for the currently-loaded target.
# Read-only where possible; the azure check uploads a tiny probe blob because a
# write-only SAS token cannot be validated by listing. Sets CHECK_RC / CHECK_MSG.
# -----------------------------------------------------------------------------
target_check() {
  local name="$1"
  CHECK_RC=1
  CHECK_MSG=""
  case "$TYPE" in
    azure) _check_azure "$name" ;;
    rsync) _check_rsync "$name" ;;
    *) CHECK_MSG="unknown TYPE '${TYPE:-<empty>}'"; CHECK_RC=2 ;;
  esac
  return 0
}

_check_azure() {
  local tmp probe dest out rc failed
  if [[ -z "${DEST_URL:-}" ]]; then CHECK_MSG="DEST_URL not set"; CHECK_RC=2; return 0; fi
  if ! command -v azcopy >/dev/null 2>&1; then CHECK_MSG="azcopy not installed"; CHECK_RC=2; return 0; fi
  tmp="$(mktemp)"
  printf 'linux-backups healthcheck %s\n' "$(date -u '+%FT%TZ')" > "$tmp"
  probe=".healthcheck-$(hostname -s 2>/dev/null || echo host)-$$"
  dest="${DEST_URL%/}/${NODE_NAME}/${probe}${SAS_TOKEN:-}"
  set +e
  out="$(azcopy copy "$tmp" "$dest" 2>&1)"; rc=$?
  set -e
  rm -f "$tmp"
  failed="$(grep -oE 'Number of Transfers Failed: [0-9]+' <<< "$out" | grep -oE '[0-9]+$' || true)"
  if [[ $rc -eq 0 && "${failed:-0}" -eq 0 ]]; then
    CHECK_RC=0
    CHECK_MSG="write OK"
    # Best-effort cleanup of the probe blob (needs Delete perm; ignore failures).
    azcopy rm "${DEST_URL%/}/${NODE_NAME}/${probe}${SAS_TOKEN:-}" >/dev/null 2>&1 || true
  else
    CHECK_RC=1
    CHECK_MSG="upload failed (rc=$rc); check the SAS token (needs Create/Write) and DEST_URL"
  fi
}

_check_rsync() {
  local host path rsh out rc
  if [[ -z "${DEST:-}" ]]; then CHECK_MSG="DEST not set"; CHECK_RC=2; return 0; fi
  if ! command -v ssh >/dev/null 2>&1; then CHECK_MSG="ssh not installed"; CHECK_RC=2; return 0; fi
  host="${DEST%%:*}"; path="${DEST#*:}"
  rsh="$(_target_rsh) -o ConnectTimeout=5"
  set +e
  # shellcheck disable=SC2086
  out="$($rsh "$host" "test -w '$path' && echo WRITABLE || echo NOWRITE" 2>&1)"; rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    CHECK_RC=1
    CHECK_MSG="ssh to $host failed: $(head -n1 <<< "$out")"
  elif grep -q WRITABLE <<< "$out"; then
    CHECK_RC=0
    CHECK_MSG="ssh OK, base path writable"
  else
    CHECK_RC=1
    CHECK_MSG="ssh OK but base path '$path' is not writable by the ssh user"
  fi
}

# -----------------------------------------------------------------------------
# Preflight: probe every enabled target and print a pass/fail line each. Returns
# non-zero if any target failed or none are configured. Uses the global NODE_NAME.
# -----------------------------------------------------------------------------
check_targets() {
  local name file total=0 ok=0
  echo "Checking backup targets (node=${NODE_NAME})..."
  while IFS=$'\t' read -r name file; do
    [[ -n "$name" ]] || continue
    total=$((total + 1))
    load_target "$name" "$file"
    target_check "$name"
    if [[ ${CHECK_RC:-1} -eq 0 ]]; then
      ok=$((ok + 1))
      printf '  [OK]   %-16s (%-5s) %s\n' "$name" "${TYPE:-?}" "$CHECK_MSG"
    else
      printf '  [FAIL] %-16s (%-5s) %s\n' "$name" "${TYPE:-?}" "$CHECK_MSG"
    fi
  done < <(list_targets)
  if [[ $total -eq 0 ]]; then
    log ERROR "no targets configured (see conf/targets/*.example.conf)"
    return 1
  fi
  echo "targets OK: ${ok}/${total}"
  [[ $ok -eq $total ]]
}

# =============================================================================
# Docker Compose discovery helpers
# =============================================================================

# Ensure the docker CLI is available; exit if not.
require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log ERROR "docker CLI not found; cannot back up compose stacks"
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    log ERROR "cannot talk to the Docker daemon (permission or daemon down?)"
    exit 1
  fi
}

# Print all compose project names present on the host — any container carrying
# the com.docker.compose.project label (running or stopped), one per line, sorted.
# This includes stacks that keep their state only in bind mounts (no named
# volumes), so their bind mounts still get coverage-checked.
discover_compose_projects() {
  docker ps -a --filter "label=com.docker.compose.project" \
    --format '{{ .Label "com.docker.compose.project" }}' 2>/dev/null \
    | awk 'NF' | sort -u
}

# Return 0 if <stack> has at least one named volume mounted by its containers
# (label-independent — catches external/unlabeled volumes too).
stack_has_named_volumes() {
  local first
  first="$(stack_volumes "$1" | head -n 1)"
  [[ -n "$first" ]]
}

# Print "<volume-name>\t<mountpoint>" for each named volume mounted by any
# container of <stack>. Derived from the containers' .Mounts (not from volume
# labels), so it also finds volumes declared `external:` / created out-of-band.
stack_volumes() {
  local stack="$1" cid type name src
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    while IFS=$'\t' read -r type name src; do
      [[ "$type" == "volume" ]] || continue
      [[ -n "$name" ]] || continue
      printf '%s\t%s\n' "$name" "$src"
    done < <(docker inspect "$cid" \
      --format '{{ range .Mounts }}{{ .Type }}{{ "\t" }}{{ .Name }}{{ "\t" }}{{ .Source }}{{ "\n" }}{{ end }}' \
      2>/dev/null)
  done < <(stack_containers "$stack") | sort -u
}

# Print the container IDs belonging to <stack> (running or stopped).
stack_containers() {
  local stack="$1"
  docker ps -a --filter "label=com.docker.compose.project=$stack" \
    --format '{{ .ID }}' 2>/dev/null
}

# Print "<working_dir>\t<config_files>" derived from the first container's
# compose labels. Either field may be empty when the labels are absent.
stack_compose_context() {
  local stack="$1" cid wd cf
  cid="$(stack_containers "$stack" | head -n 1)"
  [[ -n "$cid" ]] || { printf '\t\n'; return 0; }
  wd="$(docker inspect "$cid" \
    --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' \
    2>/dev/null || true)"
  cf="$(docker inspect "$cid" \
    --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' \
    2>/dev/null || true)"
  printf '%s\t%s\n' "$wd" "$cf"
}

# Print "<source>\t<destination>" for each read-write bind mount used by any
# container of <stack>. Ephemeral/system binds are filtered out here.
stack_bind_mounts() {
  local stack="$1" cid type src dst rw
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    while IFS=$'\t' read -r type src dst rw; do
      [[ "$type" == "bind" ]] || continue
      [[ "$rw" == "true" ]] || continue
      _is_ephemeral_bind "$src" && continue
      printf '%s\t%s\n' "$src" "$dst"
    done < <(docker inspect "$cid" \
      --format '{{ range .Mounts }}{{ .Type }}{{ "\t" }}{{ .Source }}{{ "\t" }}{{ .Destination }}{{ "\t" }}{{ .RW }}{{ "\n" }}{{ end }}' \
      2>/dev/null)
  done < <(stack_containers "$stack") | sort -u
}

# Return 0 if <source> is a well-known ephemeral/system bind that should never
# be treated as application state.
_is_ephemeral_bind() {
  local src="$1"
  case "$src" in
    /var/run/docker.sock|/run/docker.sock) return 0 ;;
    /etc/localtime|/etc/timezone|/etc/hosts|/etc/resolv.conf|/etc/hostname) return 0 ;;
    /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) return 0 ;;
  esac
  return 1
}

# Return 0 if <path> is under _path_ancestor <ancestor>.
_path_under() {
  local path="$1" anc="$2"
  [[ "$path" == "$anc" || "$path" == "$anc"/* ]]
}

# Return 0 if <path> is covered by the caller's INCLUDE_PATHS (and not excluded
# by EXCLUDE_PATHS). Both arrays are read from the caller's environment. When
# INCLUDE_PATHS is unset the path is treated as not covered.
path_is_covered() {
  local target inc exc
  target="$(realpath -m "$1" 2>/dev/null || printf '%s' "$1")"
  for exc in "${EXCLUDE_PATHS[@]:-}"; do
    [[ -n "$exc" ]] || continue
    _path_under "$target" "$(realpath -m "$exc" 2>/dev/null || printf '%s' "$exc")" \
      && return 1
  done
  for inc in "${INCLUDE_PATHS[@]:-}"; do
    [[ -n "$inc" ]] || continue
    _path_under "$target" "$(realpath -m "$inc" 2>/dev/null || printf '%s' "$inc")" \
      && return 0
  done
  return 1
}

# Minimal JSON string escaper (backslash and double-quote only — sufficient for
# filesystem paths and compose project names).
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Human-readable size of a file/directory via `du -sh`. Prints "?" when the path
# is missing or not readable (e.g. a volume mountpoint inside a Docker Desktop VM).
dir_size_human() {
  local p="$1" out
  [[ -e "$p" ]] || { printf '?'; return 0; }
  out="$(du -sh "$p" 2>/dev/null | awk '{print $1}')"
  printf '%s' "${out:-?}"
}

# Return 0 if bind source <src> matches BIND_IGNORE pattern <pat>. <pat> is an
# exact path, a directory subtree (trailing "/"), or a glob.
_bind_match() {
  local src="$1" pat="$2"
  [[ "$src" == "$pat" ]] && return 0
  if [[ "$pat" == */ ]]; then
    [[ "$src" == "${pat}"* || "$src" == "${pat%/}" ]] && return 0
  fi
  # shellcheck disable=SC2254
  case "$src" in
    $pat) return 0 ;;
  esac
  return 1
}
