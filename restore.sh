#!/usr/bin/env bash
# =============================================================================
# restore.sh — restore a Docker Compose stack from an archive produced by
# docker-backup.sh. Supports schema 1 (volumes only) and schema 2 (volumes,
# compose files, bind-mount data).
#
# Usage:
#   restore.sh <archive.tar.gz> [options]
#
#   --force              Restore even if a volume/bind target already exists.
#                        This is a REPLACE, not a merge: the existing volume
#                        or bind directory content is cleared before
#                        extraction, so files removed since the backup do not
#                        survive the restore.
#   --volume <name>      Restore only the named volume(s). May be repeated.
#                        Default: all volumes in the manifest.
#   --project-dir <dir>  Write compose files to <dir> instead of the original
#                        working_dir from the manifest (schema 2 only).
#   --bind-root <dir>    Remap all bind source paths under <dir>; e.g.
#                        --bind-root /restore maps /mnt/ssd/sonarr to
#                        /restore/mnt/ssd/sonarr (schema 2 only).
#   --no-binds           Skip bind-mount data restore (schema 2 only).
#   --no-compose         Skip compose-file restore (schema 2 only).
#
# Run as root (volume mountpoints and bind paths typically require root).
#
# Schema compatibility:
#   Schema 1 archives (volumes only) are fully supported.
#   Schema 2 archives add compose-file and bind-data restore; python3 is
#   required to parse the extended manifest.
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$REPO_DIR/lib.sh"

ARCHIVE=""
FORCE=0
declare -a ONLY_VOLUMES=()
PROJECT_DIR=""
BIND_ROOT=""
NO_BINDS=0
NO_COMPOSE=0

# Populated by restore_compose(): the restored compose file basenames (inside
# project_dir), in the original compose.config_files[] order, for the final
# "docker compose -f ... up -d" hint.
declare -a RESTORED_COMPOSE_FILES=()

# Incremented on every recoverable failure (non-empty target without --force,
# missing selected volume, extraction failure, ...) so processing can continue
# to later items while the process still exits non-zero overall.
RESTORE_FAILURES=0

usage() {
  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) FORCE=1; shift ;;
      --volume) ONLY_VOLUMES+=( "${2:?--volume needs a value}" ); shift 2 ;;
      --volume=*) ONLY_VOLUMES+=( "${1#*=}" ); shift ;;
      --project-dir) PROJECT_DIR="${2:?--project-dir needs a value}"; shift 2 ;;
      --project-dir=*) PROJECT_DIR="${1#*=}"; shift ;;
      --bind-root) BIND_ROOT="${2:?--bind-root needs a value}"; shift 2 ;;
      --bind-root=*) BIND_ROOT="${1#*=}"; shift ;;
      --no-binds) NO_BINDS=1; shift ;;
      --no-compose) NO_COMPOSE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) log ERROR "unknown option: $1"; usage; exit 2 ;;
      *)
        if [[ -z "$ARCHIVE" ]]; then ARCHIVE="$1"; else
          log ERROR "unexpected extra argument: $1"; exit 2
        fi
        shift ;;
    esac
  done
  [[ -n "$ARCHIVE" ]] || { log ERROR "no archive given"; usage; exit 2; }
  [[ -r "$ARCHIVE" ]] || { log ERROR "archive not readable: $ARCHIVE"; exit 1; }
}

# -----------------------------------------------------------------------------
# Manifest helpers
# -----------------------------------------------------------------------------

# Extract a scalar string field ("<key>":"<value>") from the manifest.
# A missing key (e.g. "working_dir" in a schema-1 manifest) is not an error --
# prints empty in that case, and must never trip `set -e` via a failed grep.
manifest_scalar() {
  local key="$1"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" <<< "$MANIFEST" \
    | head -n 1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\".*/\1/" || true
}

# Print the manifest schema version (integer, default 1).
manifest_schema() {
  local s
  s="$(grep -oE '"schema"[[:space:]]*:[[:space:]]*[0-9]+' <<< "$MANIFEST" \
    | grep -oE '[0-9]+' | head -n 1 || true)"
  echo "${s:-1}"
}

# Print all volume names from the manifest's volumes[] array.
manifest_volume_names() {
  grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' <<< "$MANIFEST" \
    | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/'
}

# Schema 2: print each compose.config_files[] entry (original path passed to
# docker compose -f), one per line, in the original captured order.
manifest_config_files() {
  printf '%s' "$MANIFEST" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for f in d.get("compose", {}).get("config_files", []):
    print(f)
'
}

# Schema 2: print "<archived_basename>\t<original_source>" for each
# compose.captured_files[] entry.
manifest_captured_files() {
  printf '%s' "$MANIFEST" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for c in d.get("compose", {}).get("captured_files", []):
    print(c.get("path", "") + "\t" + c.get("source", ""))
'
}

# Schema 2: print "<source>\t<archive_path>\t<kind>" for each binds[] entry.
# <kind> is "file", "directory", or empty for older manifests written before
# kind metadata existed (callers must infer it in that case).
manifest_binds() {
  printf '%s' "$MANIFEST" | python3 -c '
import json, sys
for b in json.load(sys.stdin).get("binds", []):
    print(b["source"] + "\t" + b["archive_path"] + "\t" + b.get("kind", ""))
'
}

# Schema 2: print "<source>\t<destination>\t<reason>" for each excluded_binds[] entry.
manifest_excluded_binds() {
  printf '%s' "$MANIFEST" | python3 -c '
import json, sys
for b in json.load(sys.stdin).get("excluded_binds", []):
    print(b["source"] + "\t" + b.get("destination","") + "\t" + b.get("reason","unknown"))
'
}

# -----------------------------------------------------------------------------
# Restore steps
# -----------------------------------------------------------------------------

# Reject unsafe archive member paths before any extraction: absolute paths or
# any ".." path-traversal segment. Every tar -x call in this script must pass
# an explicit member list (built from "tar -tzf") through this check first --
# never extract a caller/manifest-influenced pattern unchecked.
_validate_archive_members() {
  local m
  for m in "$@"; do
    if [[ "$m" == /* ]]; then
      log ERROR "refusing to extract archive member with absolute path: $m"
      return 1
    fi
    case "/$m/" in
      */../*)
        log ERROR "refusing to extract archive member with '..' path traversal: $m"
        return 1
        ;;
    esac
  done
  return 0
}

# Remove the direct contents of <dir> (not the directory itself), used to make
# --force a true replace rather than a merge. Refuses empty, relative, or
# root-like paths so a bad target can never cascade into deleting outside the
# exact validated restore path.
_clear_dir_contents() {
  local dir="$1"
  if [[ -z "$dir" || "$dir" != /* || "$dir" == "/" ]]; then
    log ERROR "refusing to clear unsafe path: '$dir'"
    return 1
  fi
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

# Return 0 if <name> should be restored given the --volume filter.
wanted_volume() {
  local name="$1" v
  [[ ${#ONLY_VOLUMES[@]} -eq 0 ]] && return 0
  for v in "${ONLY_VOLUMES[@]}"; do
    [[ "$v" == "$name" ]] && return 0
  done
  return 1
}

# Restore named volumes (all schemas). Without --force, a non-empty existing
# volume or a --volume selection missing from the manifest is a failure
# (RESTORE_FAILURES is incremented, restore continues with later volumes).
# With --force, an existing volume's content is cleared before extraction
# (replace, not merge).
restore_volumes() {
  local names=() name restored=0

  mapfile -t names < <(manifest_volume_names)
  if [[ ${#names[@]} -eq 0 ]]; then
    log WARNING "manifest lists no volumes; skipping volume restore"
    return 0
  fi

  # Fail on any --volume selection that the manifest doesn't actually have.
  if [[ ${#ONLY_VOLUMES[@]} -gt 0 ]]; then
    local ov found n
    for ov in "${ONLY_VOLUMES[@]}"; do
      found=0
      for n in "${names[@]}"; do
        [[ "$n" == "$ov" ]] && { found=1; break; }
      done
      if [[ $found -eq 0 ]]; then
        log ERROR "selected volume '$ov' not found in manifest"
        RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
      fi
    done
  fi

  for name in "${names[@]}"; do
    [[ -n "$name" ]] || continue
    if ! wanted_volume "$name"; then
      log INFO "skipping volume '$name' (not selected)"
      continue
    fi

    local mp
    if docker volume inspect "$name" >/dev/null 2>&1; then
      mp="$(docker volume inspect "$name" --format '{{ .Mountpoint }}')"
      if [[ -n "$(ls -A "$mp" 2>/dev/null || true)" ]]; then
        if [[ $FORCE -ne 1 ]]; then
          log ERROR "volume '$name' already exists and is non-empty; use --force to overwrite"
          RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
          continue
        fi
        log WARNING "volume '$name' exists and is non-empty; clearing before restore (--force)"
        if ! _clear_dir_contents "$mp"; then
          RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
          continue
        fi
      else
        log INFO "volume '$name' exists and is empty; restoring into it"
      fi
    else
      log INFO "creating volume '$name'"
      docker volume create "$name" >/dev/null
      mp="$(docker volume inspect "$name" --format '{{ .Mountpoint }}')"
    fi

    local -a vol_entries=()
    mapfile -t vol_entries < <(tar -tzf "$ARCHIVE" 2>/dev/null | grep "^volumes/${name}/")
    if [[ ${#vol_entries[@]} -eq 0 ]]; then
      log ERROR "no entries for volumes/$name in archive"
      RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
      continue
    fi
    if ! _validate_archive_members "${vol_entries[@]}"; then
      RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
      continue
    fi

    log INFO "extracting volumes/$name -> $mp"
    if ! tar -xzf "$ARCHIVE" -C "$mp" --strip-components=2 "${vol_entries[@]}"; then
      log ERROR "extraction failed for volume '$name'"
      RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
      continue
    fi
    restored=$((restored + 1))
  done

  log INFO "restored ${restored} volume(s)"
}

# Schema 2: restore compose files to <project_dir>, mapping every original
# compose.config_files[] path to its archived (possibly collision-prefixed)
# name via compose.captured_files[]. Sets RESTORED_COMPOSE_FILES to the
# restored basenames in the original config_files[] order, for the final
# "docker compose -f ... up -d" hint.
#
# Fails (returns 1) if a manifest-declared captured file is absent from the
# archive, or if a config_files[] entry has no matching captured_files
# record -- a partial extraction must never be reported as a full restore.
restore_compose() {
  local project_dir="$1"
  log INFO "restoring compose files to: $project_dir"
  mkdir -p "$project_dir"

  local -a captured=() config_files=()
  mapfile -t captured < <(manifest_captured_files)
  mapfile -t config_files < <(manifest_config_files)

  if [[ ${#captured[@]} -eq 0 ]]; then
    log WARNING "no compose.captured_files[] entries in manifest; skipping compose restore"
    return 0
  fi

  # Cross-check every captured file the manifest declares is actually present
  # in the archive.
  local -a archive_entries=()
  mapfile -t archive_entries < <(tar -tzf "$ARCHIVE" 2>/dev/null | grep '^compose/')
  local -A in_archive=()
  local e
  for e in "${archive_entries[@]}"; do
    in_archive["${e#compose/}"]=1
  done

  local -A source_to_archived=()
  local line apath src rc=0
  for line in "${captured[@]}"; do
    [[ -n "$line" ]] || continue
    apath="${line%%$'\t'*}"; src="${line#*$'\t'}"
    if [[ -z "${in_archive[$apath]:-}" ]]; then
      log ERROR "manifest declares captured compose file '$apath' (source: $src) but it is absent from the archive"
      rc=1
      continue
    fi
    source_to_archived["$src"]="$apath"
  done
  if [[ $rc -ne 0 ]]; then
    log ERROR "compose restore aborted: archive is missing manifest-declared file(s)"
    return 1
  fi

  # Extract every captured compose file (including .env, if present).
  # --strip-components=1 removes the leading "compose/" prefix so files land
  # directly in $project_dir under their archived (collision-safe) basename.
  if ! _validate_archive_members "${archive_entries[@]}"; then
    return 1
  fi
  if ! tar -xzf "$ARCHIVE" -C "$project_dir" --strip-components=1 "${archive_entries[@]}"; then
    log ERROR "extraction failed while restoring compose files to $project_dir"
    return 1
  fi
  log INFO "restored ${#archive_entries[@]} compose file(s)"

  # Build the -f argument list in the original compose.config_files[] order.
  RESTORED_COMPOSE_FILES=()
  local cfg
  for cfg in "${config_files[@]}"; do
    [[ -n "$cfg" ]] || continue
    apath="${source_to_archived[$cfg]:-}"
    if [[ -z "$apath" ]]; then
      log ERROR "manifest compose.config_files entry '$cfg' has no matching captured_files record"
      rc=1
      continue
    fi
    RESTORED_COMPOSE_FILES+=( "$apath" )
  done
  if [[ $rc -ne 0 ]]; then
    log ERROR "compose restore aborted: config_files[]/captured_files[] mismatch"
    return 1
  fi
}

# Infer whether an older (pre-kind) binds[] entry is a file or a directory by
# inspecting the archive members under <archive_path>. A directory bind has an
# explicit tar entry for the directory itself ("<archive_path>" or
# "<archive_path>/"); a file bind has exactly one member and no such entry.
# Prints "file", "directory", or "unknown" (ambiguous -- caller must fail).
_infer_bind_kind() {
  local archive_path="$1"
  local -a entries=()
  mapfile -t entries < <(tar -tzf "$ARCHIVE" 2>/dev/null | grep -E "^${archive_path}(/|$)")
  local e
  for e in "${entries[@]}"; do
    if [[ "$e" == "${archive_path}" || "$e" == "${archive_path}/" ]]; then
      echo "directory"
      return 0
    fi
  done
  if [[ ${#entries[@]} -eq 1 ]]; then
    echo "file"
    return 0
  fi
  echo "unknown"
}

# Restore a directory bind: extract every member under <archive_path>/ into
# <target> (created as a directory). Without --force, an existing non-empty
# target (or an existing path of an incompatible type) is a failure. With
# --force, existing content is cleared first -- --force is a replace, not a
# merge, so files removed from <target> since the backup do not survive.
restore_dir_bind() {
  local archive_path="$1" target="$2"

  if [[ -e "$target" && ! -d "$target" ]]; then
    if [[ $FORCE -ne 1 ]]; then
      log ERROR "bind target '$target' exists and is not a directory; use --force to replace"
      return 1
    fi
    log WARNING "removing incompatible existing path before directory-bind restore: $target"
    rm -rf "$target"
  fi

  if [[ -d "$target" && -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then
    if [[ $FORCE -ne 1 ]]; then
      log ERROR "bind target '$target' already exists and is non-empty; use --force to overwrite"
      return 1
    fi
    log WARNING "clearing existing bind target before restore (--force): $target"
    _clear_dir_contents "$target" || return 1
  fi

  mkdir -p "$target"

  local entries=()
  mapfile -t entries < <(tar -tzf "$ARCHIVE" 2>/dev/null | grep "^${archive_path}/")
  if [[ ${#entries[@]} -eq 0 ]]; then
    log WARNING "no entries for $archive_path in archive (skipping)"
    return 1
  fi
  _validate_archive_members "${entries[@]}" || return 1

  if ! tar -xzf "$ARCHIVE" -C "$target" --strip-components=2 \
    --numeric-owner "${entries[@]}"; then
    log ERROR "extraction failed for bind $target"
    return 1
  fi
  log INFO "restored bind (directory): $target"
}

# Restore a file bind to the exact source filename (not a directory named
# after it). Extracts to a temp location, then moves the file into place so
# the mode/numeric-owner tar already applied are preserved. Refuses to
# replace an existing path of an incompatible type (e.g. a directory sitting
# where the file belongs) unless --force is set.
restore_file_bind() {
  local archive_path="$1" target="$2"
  local entry base tmp

  entry="$(tar -tzf "$ARCHIVE" 2>/dev/null | grep -E "^${archive_path}/" | head -n 1 || true)"
  if [[ -z "$entry" ]]; then
    log WARNING "no entry for $archive_path in archive (skipping)"
    return 1
  fi
  _validate_archive_members "$entry" || return 1

  if [[ -e "$target" ]]; then
    if [[ $FORCE -ne 1 ]]; then
      log ERROR "bind target '$target' already exists; use --force to overwrite"
      return 1
    fi
    if [[ ! -f "$target" ]]; then
      log WARNING "removing incompatible existing path before file-bind restore: $target"
      rm -rf "$target"
    else
      log WARNING "replacing existing file bind target (--force): $target"
    fi
  fi

  tmp="$(mktemp -d)"
  if ! tar -xzf "$ARCHIVE" -C "$tmp" --strip-components=2 --numeric-owner "$entry"; then
    log ERROR "extraction failed for bind $target"
    rm -rf "$tmp"
    return 1
  fi
  base="$(basename "$entry")"
  mkdir -p "$(dirname "$target")"
  mv -f "$tmp/$base" "$target"
  rm -rf "$tmp"
  log INFO "restored bind (file): $target"
}

# Schema 2: restore bind-mount data from the archive, dispatching on each
# entry's kind (directory binds keep the binds/<id>/... layout; file binds
# restore to the exact source filename) into the original source path (or
# remapped under BIND_ROOT).
restore_binds() {
  local bind_root="$1"
  local src archive_path kind target restored=0

  while IFS=$'\t' read -r src archive_path kind; do
    [[ -n "$src" ]] || continue

    if [[ -n "$bind_root" ]]; then
      target="${bind_root%/}${src}"
    else
      target="$src"
    fi

    if [[ -z "$kind" ]]; then
      kind="$(_infer_bind_kind "$archive_path")"
      if [[ "$kind" == "unknown" ]]; then
        log ERROR "cannot determine whether $archive_path ($src) is a file or directory bind (manifest predates 'kind' and archive members are ambiguous); restore manually, e.g. 'tar -xzf $ARCHIVE $archive_path'"
        RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
        continue
      fi
      log INFO "manifest has no 'kind' for $archive_path; inferred: $kind"
    fi

    case "$kind" in
      directory)
        if restore_dir_bind "$archive_path" "$target"; then
          restored=$((restored + 1))
        else
          RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
        fi
        ;;
      file)
        if restore_file_bind "$archive_path" "$target"; then
          restored=$((restored + 1))
        else
          RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
        fi
        ;;
      *)
        log ERROR "unknown bind kind '$kind' for $archive_path ($src); skipping"
        RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
        ;;
    esac
  done < <(manifest_binds)

  log INFO "restored ${restored} bind(s)"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_docker
  command -v tar >/dev/null 2>&1 || { log ERROR "tar not found"; exit 1; }

  log INFO "reading manifest from $ARCHIVE"
  MANIFEST="$(tar -xzOf "$ARCHIVE" manifest.json 2>/dev/null || true)"
  if [[ -z "$MANIFEST" ]]; then
    log ERROR "no manifest.json found in $ARCHIVE (not a docker-backup archive?)"
    exit 1
  fi

  local schema stack node working_dir
  schema="$(manifest_schema)"
  stack="$(manifest_scalar stack)"
  node="$(manifest_scalar node)"
  working_dir="$(manifest_scalar working_dir)"
  log INFO "archive: node='${node}' stack='${stack}' schema=${schema}"

  # --- Volumes (all schemas) ---
  restore_volumes

  # --- Schema 2: compose files + bind-mount data ---
  if [[ "$schema" -ge 2 ]]; then
    command -v python3 >/dev/null 2>&1 || {
      log ERROR "python3 is required to restore schema-2 archives but was not found"
      exit 1
    }

    if [[ $NO_COMPOSE -eq 0 ]]; then
      local project_dir="${PROJECT_DIR:-$working_dir}"
      if [[ -z "$project_dir" ]]; then
        log WARNING "no working_dir in manifest and --project-dir not set; skipping compose restore"
        log WARNING "  re-run with --project-dir <dir> to restore compose files"
      else
        if ! restore_compose "$project_dir"; then
          RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
        fi
      fi
    else
      log INFO "skipping compose restore (--no-compose)"
    fi

    if [[ $NO_BINDS -eq 0 ]]; then
      restore_binds "$BIND_ROOT"
    else
      log INFO "skipping bind restore (--no-binds)"
    fi

    # Print a reminder about binds that were NOT captured in this archive.
    local excl_lines=()
    mapfile -t excl_lines < <(manifest_excluded_binds)
    if [[ ${#excl_lines[@]} -gt 0 ]]; then
      echo
      echo "NOTE: the following bind mounts were NOT captured in this archive"
      echo "      (network filesystem or BIND_IGNORE). Re-provision before 'up':"
      local line excl_src excl_dst excl_reason
      for line in "${excl_lines[@]}"; do
        IFS=$'\t' read -r excl_src excl_dst excl_reason <<< "$line"
        printf '  %-45s -> %-20s [%s]\n' "$excl_src" "$excl_dst" "$excl_reason"
      done
    fi
  fi

  # --- Next steps ---
  local project_dir_final
  if [[ "$schema" -ge 2 && -z "${PROJECT_DIR}" ]]; then
    project_dir_final="$working_dir"
  elif [[ -n "${PROJECT_DIR}" ]]; then
    project_dir_final="$PROJECT_DIR"
  else
    project_dir_final="$working_dir"
  fi

  echo
  echo "Bring the stack back up:"
  if [[ -n "$project_dir_final" ]]; then
    echo "  cd '${project_dir_final}'"
    if [[ ${#RESTORED_COMPOSE_FILES[@]} -gt 0 ]]; then
      local compose_cmd="docker compose" cf_file
      for cf_file in "${RESTORED_COMPOSE_FILES[@]}"; do
        compose_cmd+=" -f '${cf_file}'"
      done
      compose_cmd+=" up -d"
      echo "  ${compose_cmd}"
    else
      echo "  docker compose up -d"
    fi
  else
    echo "  cd <your compose project directory for '${stack}'>"
    echo "  docker compose up -d"
  fi

  if [[ $RESTORE_FAILURES -gt 0 ]]; then
    echo
    log ERROR "restore finished with ${RESTORE_FAILURES} failure(s); see errors above. Some items were NOT restored."
    exit 1
  fi
}

main "$@"
