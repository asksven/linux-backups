#!/usr/bin/env bash
# =============================================================================
# docker-backup-init.sh — bootstrap or reconcile docker-backup.conf against the
# Docker Compose stacks actually running on this node.
#
# It is the "fix-it" companion to the runtime alert DockerBackupUnmanagedStack.
# Run it manually (NOT from cron).
#
#   * No docker-backup.conf yet -> offer to create one from the template,
#     pre-populating STACKS with the discovered stateful stacks.
#   * Existing docker-backup.conf -> report stacks that are running-but-unmanaged,
#     configured-but-gone, and bind mounts with their fstype/verdict; offer to
#     append the missing stacks (additive, never rewriting your file).
#
# Usage:
#   docker-backup-init.sh [--print] [--write|--yes] [--config <dir>]
#
#   --print          Report only; make no changes (default when non-interactive).
#   --write, --yes   Apply additive suggestions without prompting.
#   --config <dir>   Override CONFIG_DIR (default: /etc/linux-backups).
#
# Bind-mount acknowledgments are only ever PRINTED as suggestions, never applied.
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$REPO_DIR/lib.sh"

CONFIG_DIR="${CONFIG_DIR:-/etc/linux-backups}"
TEMPLATE="$REPO_DIR/conf/docker-backup.example.conf"
MODE="interactive"   # interactive | print | write

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print) MODE="print"; shift ;;
      --write|--yes) MODE="write"; shift ;;
      --config) CONFIG_DIR="${2:?--config needs a value}"; shift 2 ;;
      --config=*) CONFIG_DIR="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log ERROR "unknown argument: $1"; usage; exit 2 ;;
    esac
  done
  # Fall back to report-only when interactive mode has no terminal.
  if [[ "$MODE" == "interactive" && ! -t 0 ]]; then
    MODE="print"
    log INFO "no terminal detected; running in --print mode"
  fi
}

# Ask a yes/no question on the terminal. Returns 0 for yes.
confirm() {
  local prompt="$1" ans
  read -r -p "$prompt [y/N] " ans < /dev/tty || return 1
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# Print a stack's named volumes with their on-disk sizes.
report_stack_volumes() {
  local stack="$1" name mp count=0
  while IFS=$'\t' read -r name mp; do
    [[ -n "$name" ]] || continue
    printf '      volume %s: %s\n' "$name" "$(dir_size_human "$mp")"
    count=$((count + 1))
  done < <(stack_volumes "$stack")
  [[ $count -eq 0 ]] && printf '      (no named volumes — state is in bind mounts)\n'
  return 0
}

# Return 0 if <src> looks like a transient / scratch / download directory
# that an admin would typically want to exclude from the backup archive.
_is_likely_transient() {
  local src="$1"
  case "$src" in
    */[Dd]ownload*|*/[Cc]ache*|*/.cache*|*/[Tt]mp/*|*/[Tt]emp/*) return 0 ;;
    */scratch*|*/transcode*|*/[Ii]ncomplete*|*blackhole*|*/watch*) return 0 ;;
  esac
  return 1
}

# Print each of a stack's bind mounts (writable and read-only) with its fstype,
# verdict (capture / network-forced / network-excluded / bind-ignore), and
# on-disk size. Uses the same precedence decision as runtime archiving
# (bind_capture_verdict, in lib.sh) so verdicts here can never drift from what
# docker-backup.sh actually does.
report_stack_binds() {
  local stack="$1" src dst ro any=0
  while IFS=$'\t' read -r src dst ro; do
    [[ -n "$src" ]] || continue
    any=1
    bind_capture_verdict "$stack" "$src"
    local ro_label=""
    [[ "$ro" == "true" ]] && ro_label=",ro"
    printf '      bind [%s%s] %s  fstype=%s  size=%s  -> %s\n' \
      "$BIND_VERDICT" "$ro_label" "$src" "$BIND_FSTYPE" "$(dir_size_human "$src")" "$dst"
  done < <(stack_bind_mounts "$stack")
  [[ $any -eq 0 ]] && printf '      (no bind mounts)\n'
  return 0
}

# Scan all projects for capture-verdict binds (including force-included
# network-fs binds) that look transient or are shared across multiple stacks,
# and print BIND_IGNORE suggestions for each match. Uses the same precedence
# decision as runtime archiving (bind_capture_verdict, in lib.sh).
suggest_bind_ignore() {
  local -A _src_stacks=()   # source_path -> space-separated stack names
  local _stack _src _dst _ro

  for _stack in "$@"; do
    [[ -n "$_stack" ]] || continue
    while IFS=$'\t' read -r _src _dst _ro; do
      [[ -n "$_src" ]] || continue
      bind_capture_verdict "$_stack" "$_src"
      case "$BIND_VERDICT" in
        network-excluded|bind-ignore) continue ;;
      esac
      local _existing="${_src_stacks[$_src]:-}"
      if [[ -z "$_existing" ]]; then
        _src_stacks[$_src]="$_stack"
      else
        _src_stacks[$_src]="$_existing $_stack"
      fi
    done < <(stack_bind_mounts "$_stack")
  done

  local _suggestions=() _entry _s_src _s_reason _wc
  for _src in "${!_src_stacks[@]}"; do
    local _stacks_using="${_src_stacks[$_src]}"
    local _reason=""
    _wc=$(printf '%s' "$_stacks_using" | wc -w)
    if [[ $_wc -gt 1 ]]; then
      _reason="shared by: ${_stacks_using}"
    fi
    if _is_likely_transient "$_src"; then
      _reason="${_reason:+${_reason}; }likely-transient path"
    fi
    [[ -n "$_reason" ]] && _suggestions+=( "${_src}|${_reason}" )
  done

  [[ ${#_suggestions[@]} -eq 0 ]] && return 0

  echo
  echo "  BIND_IGNORE candidates (add to docker-backup.conf to exclude from archive):"
  local _entry _s_src _s_reason
  for _entry in "${_suggestions[@]}"; do
    _s_src="${_entry%%|*}"; _s_reason="${_entry#*|}"
    printf '    BIND_IGNORE+=( %q )  # %s\n' "$_s_src" "$_s_reason"
  done
}

# Append STACKS entries under a dated, clearly-marked block.
append_stacks() {
  local conf="$1"; shift
  local ts; ts="$(date '+%F %T')"
  {
    printf '\n# --- added by docker-backup-init.sh on %s ---\n' "$ts"
    local s
    for s in "$@"; do
      printf 'STACKS+=( %q )\n' "$s"
    done
  } >> "$conf"
}

# Create a fresh conf from the template, then append the chosen stacks.
create_conf() {
  local conf="$1"; shift
  [[ -r "$TEMPLATE" ]] || { log ERROR "template not found: $TEMPLATE"; exit 1; }
  mkdir -p "$(dirname "$conf")"
  cp "$TEMPLATE" "$conf"
  chmod 600 "$conf"
  if [[ $# -gt 0 ]]; then
    append_stacks "$conf" "$@"
  fi
  log INFO "created $conf (from template)"
  log INFO "review it, then set DEST_URL/SAS_TOKEN in $CONFIG_DIR/secrets.env"
}

# Backup then append missing stacks to an existing conf.
apply_append() {
  local conf="$1"; shift
  local bak; bak="${conf}.bak-$(date '+%F-%H-%M-%S')"
  cp "$conf" "$bak"
  log INFO "backed up existing config to $bak"
  append_stacks "$conf" "$@"
  log INFO "appended ${#} stack(s) to $conf"
}

main() {
  parse_args "$@"
  require_docker

  local conf="$CONFIG_DIR/docker-backup.conf"
  local projects=() name
  mapfile -t projects < <(discover_compose_projects)

  echo "Node compose landscape:"
  echo "  compose projects: ${projects[*]:-<none>}"
  echo "  config: $conf ($([[ -e "$conf" ]] && echo present || echo missing))"
  echo

  # ----- Case 1: no config yet -> bootstrap -----
  if [[ ! -e "$conf" ]]; then
    if [[ ${#projects[@]} -eq 0 ]]; then
      log INFO "no compose projects found; nothing to bootstrap"
    fi
    declare -a BIND_IGNORE=()
    declare -a BIND_INCLUDE_NETFS=()
    local chosen=()
    for name in "${projects[@]:-}"; do
      [[ -n "$name" ]] || continue
      echo "  project: $name"
      report_stack_volumes "$name"
      report_stack_binds "$name"
      if ! stack_is_stateful "$name"; then
        # No named volumes and no non-ephemeral bind mounts; nothing to back up.
        continue
      fi
      case "$MODE" in
        write) chosen+=( "$name" ) ;;
        print) : ;;
        interactive)
          if confirm "Back up stack '$name'?"; then chosen+=( "$name" ); fi ;;
      esac
    done
    suggest_bind_ignore "${projects[@]:-}"
    if [[ "$MODE" == "print" ]]; then
      echo
      log INFO "print mode: no file written. Re-run with --write or interactively to create $conf"
      return 0
    fi
    create_conf "$conf" "${chosen[@]}"
    return 0
  fi

  # ----- Case 2: existing config -> reconcile -----
  # shellcheck disable=SC1090
  source "$conf"
  [[ -n "${STACKS+x}" ]] || STACKS=()
  [[ -n "${BIND_IGNORE+x}" ]] || BIND_IGNORE=()
  [[ -n "${BIND_INCLUDE_NETFS+x}" ]] || BIND_INCLUDE_NETFS=()

  local unmanaged=() gone=() s found
  for name in "${projects[@]:-}"; do
    [[ -n "$name" ]] || continue
    found=0
    for s in "${STACKS[@]:-}"; do [[ "$s" == "$name" ]] && found=1 && break; done
    [[ $found -eq 1 ]] && continue
    if stack_is_stateful "$name"; then
      unmanaged+=( "$name" )
    fi
  done
  for s in "${STACKS[@]:-}"; do
    [[ -n "$s" ]] || continue
    found=0
    for name in "${projects[@]:-}"; do [[ "$s" == "$name" ]] && found=1 && break; done
    [[ $found -eq 0 ]] && gone+=( "$s" )
  done

  echo "Reconciliation report:"
  echo "  managed stacks: ${STACKS[*]:-<none>}"
  echo "  running but UNMANAGED (own volumes or bind-mount state): ${unmanaged[*]:-<none>}"
  echo "  configured but GONE (down/renamed?): ${gone[*]:-<none>}"
  echo "  project details (volume & bind sizes):"
  for name in "${projects[@]:-}"; do
    [[ -n "$name" ]] || continue
    echo "    $name:"
    report_stack_volumes "$name"
    report_stack_binds "$name"
  done
  echo
  suggest_bind_ignore "${projects[@]:-}"

  if [[ ${#gone[@]} -gt 0 ]]; then
    log WARNING "configured stacks with no live state: ${gone[*]} (not removed automatically)"
  fi

  if [[ ${#unmanaged[@]} -eq 0 ]]; then
    log INFO "no unmanaged stacks that own named volumes; config is in sync"
    return 0
  fi

  case "$MODE" in
    print)
      log INFO "print mode: no changes. Re-run with --write to append: ${unmanaged[*]}" ;;
    write)
      apply_append "$conf" "${unmanaged[@]}" ;;
    interactive)
      local add=()
      for name in "${unmanaged[@]}"; do
        if confirm "Add unmanaged stack '$name' to STACKS?"; then add+=( "$name" ); fi
      done
      if [[ ${#add[@]} -gt 0 ]]; then
        apply_append "$conf" "${add[@]}"
      else
        log INFO "nothing selected; config unchanged"
      fi ;;
  esac
}

main "$@"
