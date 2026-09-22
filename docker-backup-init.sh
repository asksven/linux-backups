#!/usr/bin/env bash
# =============================================================================
# docker-backup-init.sh — bootstrap or reconcile docker-backup.conf against the
# Docker Compose stacks actually running on this node.
#
# It is the "fix-it" companion to the runtime alert DockerBackupUnmanagedStack.
# Writing changes (bootstrap, --write/--yes, interactive) is manual-only (NOT
# from cron); --check is read-only and IS safe to run from cron/a systemd timer
# for drift detection (see README "Scheduling a drift check").
#
#   * No docker-backup.conf yet -> offer to create one from the template,
#     pre-populating STACKS with the discovered stateful stacks.
#   * Existing docker-backup.conf -> report stacks that are running-but-unmanaged,
#     configured-but-gone, and bind mounts with their fstype/verdict; offer to
#     append the missing stacks (additive, never rewriting your file).
#
# Usage:
#   docker-backup-init.sh [--print] [--write|--yes] [--check] [--config <dir>]
#                        [--apply-bind-ignore] [--apply-stop-policy]
#
#   --print          Report only; make no changes (default when non-interactive).
#   --write, --yes   Apply additive STACKS suggestions without prompting.
#   --check          Non-interactive drift check only: writes nothing, prints
#                     unmanaged/gone stacks, exits 1 on drift, 0 when in sync.
#   --config <dir>   Override CONFIG_DIR (default: /etc/linux-backups).
#   --apply-bind-ignore  Also apply BIND_IGNORE suggestions under --write/--yes.
#                     These are a heuristic (shared or likely-transient bind
#                     sources) and can exclude a source from every stack that
#                     mounts it -- review the printed candidates first.
#   --apply-stop-policy  Also apply NO_STOP_STACKS suggestions under
#                     --write/--yes. These only mean no known database
#                     signature was found by a shallow scan, not that hot
#                     backup is actually safe -- review the printed candidates
#                     first.
#
# Bind-mount and stop-policy suggestions are always PRINTED but never applied
# by default: STACKS drift is the only thing --write/--yes appends
# unconditionally. Applying BIND_IGNORE/NO_STOP_STACKS suggestions requires
# --apply-bind-ignore/--apply-stop-policy (non-interactive) or an explicit
# per-suggestion confirmation (interactive mode).
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$REPO_DIR/lib.sh"

CONFIG_DIR="${CONFIG_DIR:-/etc/linux-backups}"
TEMPLATE="$REPO_DIR/conf/docker-backup.example.conf"
MODE="interactive"   # interactive | print | write | check
# Explicit opt-in required to auto-apply BIND_IGNORE/NO_STOP_STACKS
# suggestions under --write/--yes: both are heuristics that can silently
# exclude data from every stack sharing a source, or weaken backup
# consistency, so STACKS drift alone is not a proxy for "review and accept
# these too".
APPLY_BIND_IGNORE=0
APPLY_STOP_POLICY=0

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print) MODE="print"; shift ;;
      --write|--yes) MODE="write"; shift ;;
      --check) MODE="check"; shift ;;
      --config) CONFIG_DIR="${2:?--config needs a value}"; shift 2 ;;
      --config=*) CONFIG_DIR="${1#*=}"; shift ;;
      --apply-bind-ignore) APPLY_BIND_IGNORE=1; shift ;;
      --apply-stop-policy) APPLY_STOP_POLICY=1; shift ;;
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

# Populate UNMANAGED and GONE from the caller's `projects` (discovered compose
# projects) and `STACKS` (configured allowlist) arrays. Shared by the
# interactive/--print/--write reconcile report and --check, so their verdicts
# can never drift apart.
UNMANAGED=()
GONE=()
compute_drift() {
  UNMANAGED=()
  GONE=()
  local name s found
  for name in "${projects[@]:-}"; do
    [[ -n "$name" ]] || continue
    found=0
    for s in "${STACKS[@]:-}"; do [[ "$s" == "$name" ]] && found=1 && break; done
    [[ $found -eq 1 ]] && continue
    if stack_is_stateful "$name"; then
      UNMANAGED+=( "$name" )
    fi
  done
  for s in "${STACKS[@]:-}"; do
    [[ -n "$s" ]] || continue
    found=0
    for name in "${projects[@]:-}"; do [[ "$s" == "$name" ]] && found=1 && break; done
    [[ $found -eq 0 ]] && GONE+=( "$s" )
  done
  # Explicit: without this, the function's own return status would be that of
  # the last comparison above -- often 1/false -- which would abort the caller
  # under `set -e` since compute_drift is invoked as a bare statement.
  return 0
}

# Scan all projects for capture-verdict binds (including force-included
# network-fs binds) that look transient or are shared across multiple stacks,
# and print BIND_IGNORE suggestions for each match. Uses the same precedence
# decision as runtime archiving (bind_capture_verdict, in lib.sh). Populates
# BIND_IGNORE_SUGGESTIONS so --write/--yes can append them (see main()); only
# ever printed otherwise.
BIND_IGNORE_SUGGESTIONS=()
suggest_bind_ignore() {
  BIND_IGNORE_SUGGESTIONS=()
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
    BIND_IGNORE_SUGGESTIONS+=( "$_s_src" )
  done
}

# Return 0 if any container of <stack> runs a well-known database image, or
# any of its bind/volume roots contain a SQLite/db/WAL-looking file, OR a root
# can't be conclusively scanned at all (missing/unreadable, or `find` hit an
# access error partway through). Used to keep NO_STOP_STACKS suggestions
# conservative -- never propose a hot backup for a stack that looks like it
# embeds a writable database, and never propose one just because a scan
# silently came back empty due to a permissions problem.
_stack_looks_stateful_db() {
  local stack="$1" cid image src dst ro name mp
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    image="$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null || true)"
    case "$image" in
      *postgres*|*mysql*|*mariadb*|*mongo*|*redis*|*influx*|*elastic*) return 0 ;;
    esac
  done < <(stack_containers "$stack")

  local _hits _find_rc
  while IFS=$'\t' read -r src dst ro; do
    [[ -n "$src" ]] || continue
    if [[ ! -d "$src" || ! -r "$src" ]]; then
      return 0
    fi
    _hits="$(find "$src" -maxdepth 3 \( -iname '*.sqlite*' -o -iname '*.db' -o -iname '*wal*' \) -print -quit 2>/dev/null)"
    _find_rc=$?
    if [[ -n "$_hits" || $_find_rc -ne 0 ]]; then
      return 0
    fi
  done < <(stack_bind_mounts "$stack")

  while IFS=$'\t' read -r name mp; do
    [[ -n "$mp" ]] || continue
    if [[ ! -d "$mp" || ! -r "$mp" ]]; then
      return 0
    fi
    _hits="$(find "$mp" -maxdepth 3 \( -iname '*.sqlite*' -o -iname '*.db' -o -iname '*wal*' \) -print -quit 2>/dev/null)"
    _find_rc=$?
    if [[ -n "$_hits" || $_find_rc -ne 0 ]]; then
      return 0
    fi
  done < <(stack_volumes "$stack")

  return 1
}

# Print each stateful stack's effective stop policy (via stack_stop_policy, in
# lib.sh). For stacks already following the default (stop-cold-copy) with no
# detected database signature, propose NO_STOP_STACKS. Populates
# NO_STOP_SUGGESTIONS so --write/--yes can append them (see main()); never
# appends by itself.
NO_STOP_SUGGESTIONS=()
suggest_stop_policy() {
  NO_STOP_SUGGESTIONS=()
  local -a _stateful=()
  local _stack _policy
  for _stack in "$@"; do
    [[ -n "$_stack" ]] || continue
    stack_is_stateful "$_stack" && _stateful+=( "$_stack" )
  done
  [[ ${#_stateful[@]} -eq 0 ]] && return 0

  echo
  echo "  Stop policy:"
  for _stack in "${_stateful[@]}"; do
    stack_stop_policy "$_stack"
    _policy="$STOP_POLICY"
    if [[ "$_policy" == "no-stop" ]]; then
      printf '    %-24s hot backup (NO_STOP_STACKS)\n' "$_stack"
    elif _stack_looks_stateful_db "$_stack"; then
      printf '    %-24s stop-cold-copy (database/db-file signature detected)\n' "$_stack"
    else
      printf '    %-24s stop-cold-copy -- candidate for NO_STOP_STACKS (no database signature found)\n' "$_stack"
      NO_STOP_SUGGESTIONS+=( "$_stack" )
    fi
  done
  # Explicit: guards against leaking a falsy internal test as this bare-called
  # function's own return status under `set -e` (see compute_drift).
  return 0
}

# Append <array-name>+=( <values...> ) lines to <conf>, one per value. No-op
# if there are no values. Empty-string values are skipped -- they only occur
# as the phantom element of "${arr[@]:-}" on a truly empty array, never a
# real stack name/path. The generalized single-array primitive shared by
# STACKS, BIND_IGNORE, and NO_STOP_STACKS appends.
append_entries() {
  local conf="$1" arr="$2"; shift 2
  [[ $# -gt 0 ]] || return 0
  local v
  for v in "$@"; do
    [[ -n "$v" ]] || continue
    printf '%s+=( %q )\n' "$arr" "$v"
  done >> "$conf"
}

# Split "-- "-separated groups from $@ into STACKS_GROUP / BIND_IGNORE_GROUP /
# NO_STOP_GROUP value arrays. Empty-string values are dropped (see
# append_entries) so an all-empty group never becomes a stray blank entry.
_split_entry_groups() {
  STACKS_GROUP=(); BIND_IGNORE_GROUP=(); NO_STOP_GROUP=()
  local group=1 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then
      group=$((group + 1))
      continue
    fi
    [[ -n "$a" ]] || continue
    case "$group" in
      1) STACKS_GROUP+=( "$a" ) ;;
      2) BIND_IGNORE_GROUP+=( "$a" ) ;;
      3) NO_STOP_GROUP+=( "$a" ) ;;
    esac
  done
}

# Append a single dated "added by docker-backup-init.sh" header, then STACKS /
# BIND_IGNORE / NO_STOP_STACKS entries under it via append_entries. Args:
#   <conf> <stacks...> -- <bind_ignore...> -- <no_stop...>
# Any group may be empty; a call where all three are empty is a no-op.
_append_suggestion_block() {
  local conf="$1"; shift
  _split_entry_groups "$@"
  if [[ ${#STACKS_GROUP[@]} -eq 0 && ${#BIND_IGNORE_GROUP[@]} -eq 0 && ${#NO_STOP_GROUP[@]} -eq 0 ]]; then
    return 0
  fi
  printf '\n# --- added by docker-backup-init.sh on %s ---\n' "$(date '+%F %T')" >> "$conf"
  append_entries "$conf" STACKS "${STACKS_GROUP[@]:-}"
  append_entries "$conf" BIND_IGNORE "${BIND_IGNORE_GROUP[@]:-}"
  append_entries "$conf" NO_STOP_STACKS "${NO_STOP_GROUP[@]:-}"
  log INFO "appended ${#STACKS_GROUP[@]} STACKS, ${#BIND_IGNORE_GROUP[@]} BIND_IGNORE, ${#NO_STOP_GROUP[@]} NO_STOP_STACKS entrie(s) to $conf"
}

# Create a fresh conf from the template, then append the chosen stacks and any
# other suggested entries under one shared dated header. Args:
#   create_conf <conf> <stacks...> -- <bind_ignore...> -- <no_stop...>
create_conf() {
  local conf="$1"; shift
  [[ -r "$TEMPLATE" ]] || { log ERROR "template not found: $TEMPLATE"; exit 1; }
  mkdir -p "$(dirname "$conf")"
  cp "$TEMPLATE" "$conf"
  chmod 600 "$conf"
  _append_suggestion_block "$conf" "$@"
  log INFO "created $conf (from template)"
  log INFO "review it, then set DEST_URL/SAS_TOKEN in $CONFIG_DIR/secrets.env"
}

# Backup <conf> to .bak-<ts>, then append suggested entries under one shared
# dated header. Args: <conf> <stacks...> -- <bind_ignore...> -- <no_stop...>
apply_append() {
  local conf="$1"; shift
  local bak; bak="${conf}.bak-$(date '+%F-%H-%M-%S')"
  cp "$conf" "$bak"
  log INFO "backed up existing config to $bak"
  _append_suggestion_block "$conf" "$@"
}

# Refuse to run as non-root: otherwise $CONFIG_DIR may not be readable, and a
# config that exists but can't be read is indistinguishable from no config at
# all -- silently producing wrong drift/suggestion output instead of failing
# loudly. A separate function (rather than inline in main) so tests can stub
# it the same way they already stub require_docker.
require_root() {
  if [[ $EUID -ne 0 ]]; then
    log ERROR "must be run as root (sudo)"
    exit 1
  fi
}

main() {
  parse_args "$@"
  require_root
  require_docker

  local conf="$CONFIG_DIR/docker-backup.conf"
  local projects=() name
  mapfile -t projects < <(discover_compose_projects)

  # ----- --check: non-interactive drift check, writes nothing -----
  if [[ "$MODE" == "check" ]]; then
    local STACKS=()
    local conf_missing=0
    if [[ -e "$conf" ]]; then
      # shellcheck disable=SC1090
      source "$conf"
      [[ -n "${STACKS+x}" ]] || STACKS=()
    else
      conf_missing=1
      log WARNING "no config at $conf; every discovered stateful stack counts as unmanaged"
    fi
    compute_drift
    echo "Drift check ($conf):"
    echo "  running but UNMANAGED (own volumes or bind-mount state): ${UNMANAGED[*]:-<none>}"
    echo "  configured but GONE (down/renamed?): ${GONE[*]:-<none>}"
    if [[ $conf_missing -eq 1 ]]; then
      log WARNING "drift detected: $conf does not exist; docker-backup.sh cannot run without it"
      return 1
    fi
    if [[ ${#UNMANAGED[@]} -gt 0 || ${#GONE[@]} -gt 0 ]]; then
      log WARNING "drift detected; re-run without --check (--write to fix non-interactively)"
      return 1
    fi
    log INFO "config is in sync with the running compose landscape"
    return 0
  fi

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
    declare -a NO_STOP_STACKS=()
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
    suggest_stop_policy "${projects[@]:-}"
    if [[ "$MODE" == "print" ]]; then
      echo
      log INFO "print mode: no file written. Re-run with --write or interactively to create $conf"
      return 0
    fi
    local extra_bind_ignore=() extra_no_stop=()
    case "$MODE" in
      write)
        [[ $APPLY_BIND_IGNORE -eq 1 ]] && extra_bind_ignore=( "${BIND_IGNORE_SUGGESTIONS[@]:-}" )
        [[ $APPLY_STOP_POLICY -eq 1 ]] && extra_no_stop=( "${NO_STOP_SUGGESTIONS[@]:-}" )
        ;;
      interactive)
        local _src _stk
        for _src in "${BIND_IGNORE_SUGGESTIONS[@]:-}"; do
          [[ -n "$_src" ]] || continue
          if confirm "Add BIND_IGNORE entry for '$_src'?"; then extra_bind_ignore+=( "$_src" ); fi
        done
        for _stk in "${NO_STOP_SUGGESTIONS[@]:-}"; do
          [[ -n "$_stk" ]] || continue
          if confirm "Back up '$_stk' hot (NO_STOP_STACKS, no downtime)?"; then extra_no_stop+=( "$_stk" ); fi
        done
        ;;
    esac
    create_conf "$conf" "${chosen[@]:-}" -- "${extra_bind_ignore[@]:-}" -- "${extra_no_stop[@]:-}"
    return 0
  fi

  # ----- Case 2: existing config -> reconcile -----
  # shellcheck disable=SC1090
  source "$conf"
  [[ -n "${STACKS+x}" ]] || STACKS=()
  [[ -n "${BIND_IGNORE+x}" ]] || BIND_IGNORE=()
  [[ -n "${BIND_INCLUDE_NETFS+x}" ]] || BIND_INCLUDE_NETFS=()
  [[ -n "${NO_STOP_STACKS+x}" ]] || NO_STOP_STACKS=()

  compute_drift

  echo "Reconciliation report:"
  echo "  managed stacks: ${STACKS[*]:-<none>}"
  echo "  hot backup stacks (NO_STOP_STACKS): ${NO_STOP_STACKS[*]:-<none>}"
  echo "  running but UNMANAGED (own volumes or bind-mount state): ${UNMANAGED[*]:-<none>}"
  echo "  configured but GONE (down/renamed?): ${GONE[*]:-<none>}"
  echo "  project details (volume & bind sizes):"
  for name in "${projects[@]:-}"; do
    [[ -n "$name" ]] || continue
    echo "    $name:"
    report_stack_volumes "$name"
    report_stack_binds "$name"
  done
  echo
  suggest_bind_ignore "${projects[@]:-}"
  suggest_stop_policy "${projects[@]:-}"

  if [[ ${#GONE[@]} -gt 0 ]]; then
    log WARNING "configured stacks with no live state: ${GONE[*]} (not removed automatically)"
  fi

  # BIND_IGNORE/NO_STOP_STACKS suggestions can exist even when every running
  # stack is already managed (UNMANAGED empty) -- do not let that alone short
  # -circuit the suggestion-only case below.
  local have_suggestions=0
  [[ ${#BIND_IGNORE_SUGGESTIONS[@]} -gt 0 || ${#NO_STOP_SUGGESTIONS[@]} -gt 0 ]] && have_suggestions=1

  if [[ ${#UNMANAGED[@]} -eq 0 && $have_suggestions -eq 0 ]]; then
    if [[ ${#GONE[@]} -gt 0 ]]; then
      log INFO "no additions to make; the stale entries listed above require manual removal from $conf"
    else
      log INFO "no unmanaged stacks that own named volumes; config is in sync"
    fi
    return 0
  fi

  case "$MODE" in
    print)
      [[ ${#UNMANAGED[@]} -gt 0 ]] && log INFO "print mode: no changes. Re-run with --write to append: ${UNMANAGED[*]}"
      [[ $have_suggestions -eq 1 ]] && log INFO "print mode: no changes. Re-run with --write --apply-bind-ignore/--apply-stop-policy (or interactively) to apply the suggestions above"
      ;;
    write)
      local pending_bind_ignore=() pending_no_stop=()
      [[ $APPLY_BIND_IGNORE -eq 1 ]] && pending_bind_ignore=( "${BIND_IGNORE_SUGGESTIONS[@]:-}" )
      [[ $APPLY_STOP_POLICY -eq 1 ]] && pending_no_stop=( "${NO_STOP_SUGGESTIONS[@]:-}" )
      if [[ ${#UNMANAGED[@]} -eq 0 && ${#pending_bind_ignore[@]} -eq 0 && ${#pending_no_stop[@]} -eq 0 ]]; then
        log INFO "no changes to apply (BIND_IGNORE/NO_STOP_STACKS suggestions require --apply-bind-ignore/--apply-stop-policy); config unchanged"
      else
        apply_append "$conf" "${UNMANAGED[@]:-}" -- "${pending_bind_ignore[@]:-}" -- "${pending_no_stop[@]:-}"
      fi
      ;;
    interactive)
      local add=() add_bind_ignore=() add_no_stop=() src
      for name in "${UNMANAGED[@]:-}"; do
        if confirm "Add unmanaged stack '$name' to STACKS?"; then add+=( "$name" ); fi
      done
      for src in "${BIND_IGNORE_SUGGESTIONS[@]:-}"; do
        [[ -n "$src" ]] || continue
        if confirm "Add BIND_IGNORE entry for '$src'?"; then add_bind_ignore+=( "$src" ); fi
      done
      for name in "${NO_STOP_SUGGESTIONS[@]:-}"; do
        [[ -n "$name" ]] || continue
        if confirm "Back up '$name' hot (NO_STOP_STACKS, no downtime)?"; then add_no_stop+=( "$name" ); fi
      done
      if [[ ${#add[@]} -gt 0 || ${#add_bind_ignore[@]} -gt 0 || ${#add_no_stop[@]} -gt 0 ]]; then
        apply_append "$conf" "${add[@]:-}" -- "${add_bind_ignore[@]:-}" -- "${add_no_stop[@]:-}"
      else
        log INFO "nothing selected; config unchanged"
      fi
      ;;
  esac
}

main "$@"
