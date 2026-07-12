#!/usr/bin/env bash
# =============================================================================
# restore.sh — restore a Docker Compose stack's named volumes from an archive
# produced by docker-backup.sh.
#
# The archive contains `manifest.json` plus `volumes/<name>/...` for each named
# volume. This script recreates each volume and extracts its contents into the
# volume's mountpoint (host-side, so it must run as root on the Docker host).
#
# Usage:
#   restore.sh <archive.tar.gz> [--force] [--volume <name>]...
#
#   --force            Restore even if a target volume already exists / is
#                      non-empty (its contents are overwritten/merged).
#   --volume <name>    Restore only the named volume(s). May be repeated.
#                      Default: all volumes listed in the manifest.
#
# After extraction it prints the compose context so you can bring the stack up.
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$REPO_DIR/lib.sh"

ARCHIVE=""
FORCE=0
declare -a ONLY_VOLUMES=()

usage() {
  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) FORCE=1; shift ;;
      --volume) ONLY_VOLUMES+=( "${2:?--volume needs a value}" ); shift 2 ;;
      --volume=*) ONLY_VOLUMES+=( "${1#*=}" ); shift ;;
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

# Return 0 if <name> should be restored given the --volume filter.
wanted_volume() {
  local name="$1" v
  [[ ${#ONLY_VOLUMES[@]} -eq 0 ]] && return 0
  for v in "${ONLY_VOLUMES[@]}"; do
    [[ "$v" == "$name" ]] && return 0
  done
  return 1
}

# Extract a scalar string field ("<key>":"<value>") from the manifest.
manifest_scalar() {
  local key="$1"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" <<< "$MANIFEST" \
    | head -n 1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

# Print all volume names from the manifest's volumes[] array.
manifest_volume_names() {
  grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' <<< "$MANIFEST" \
    | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/'
}

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

  local stack node working_dir
  stack="$(manifest_scalar stack)"
  node="$(manifest_scalar node)"
  working_dir="$(manifest_scalar working_dir)"
  log INFO "archive: node='${node}' stack='${stack}'"

  local names=() name
  mapfile -t names < <(manifest_volume_names)
  if [[ ${#names[@]} -eq 0 ]]; then
    log WARNING "manifest lists no volumes; nothing to restore"
    exit 0
  fi

  local restored=0
  for name in "${names[@]}"; do
    [[ -n "$name" ]] || continue
    if ! wanted_volume "$name"; then
      log INFO "skipping volume '$name' (not selected)"
      continue
    fi

    if docker volume inspect "$name" >/dev/null 2>&1; then
      local mp
      mp="$(docker volume inspect "$name" --format '{{ .Mountpoint }}')"
      if [[ -n "$(ls -A "$mp" 2>/dev/null || true)" && $FORCE -ne 1 ]]; then
        log ERROR "volume '$name' already exists and is non-empty; use --force to overwrite"
        continue
      fi
      log INFO "volume '$name' exists; restoring into it (force)"
    else
      log INFO "creating volume '$name'"
      docker volume create "$name" >/dev/null
    fi

    local mp
    mp="$(docker volume inspect "$name" --format '{{ .Mountpoint }}')"
    log INFO "extracting volumes/$name -> $mp"
    tar -xzf "$ARCHIVE" -C "$mp" --strip-components=2 "volumes/$name"
    restored=$((restored + 1))
  done

  log INFO "restored ${restored} volume(s) for stack '${stack}'"
  echo
  echo "Next steps to bring the stack back up:"
  if [[ -n "$working_dir" ]]; then
    echo "  cd '$working_dir'"
    echo "  docker compose up -d"
  else
    echo "  cd <your compose project directory for '${stack}'>"
    echo "  docker compose up -d"
  fi
}

main "$@"
