# Architecture

Reference documentation for the **implemented** `linux-backups` system. This
describes how things work today. Pending/forward-looking work is tracked
separately in [PLAN.md](PLAN.md).

## Overview

The repo provides host-level and Docker-Compose-level backups for a fleet of
Linux boxes, sharing one bash codebase. It is **open-source-safe**: only the
scripts and templates are committed; every per-server config and secret lives
outside the repo checkout and is never committed.

Two subsystems, one shared library:

- **Host filesystem backup** — `backup.sh`: tars declared paths (`INCLUDE_PATHS`)
  plus the node's own config, then fans the archive out to one or more targets.
- **Docker stack backup** — `docker-backup.sh`: per-Compose-stack archives built
  via stop-cold-copy, fanned out to the same targets.
- **Shared library** — `lib.sh`: config/secret loading, self-update, logging,
  the target layer, Docker discovery helpers, and the Pushgateway push.

The host FS backup and the Docker backup are run independently (typically both
from cron).

## Repository layout (committed — no secrets, no server configs)

```
linux-backups/
  backup.sh                       # host FS backup orchestrator (sources lib.sh)
  docker-backup.sh                # Docker Compose stack backup orchestrator
  docker-backup-init.sh           # interactive config bootstrap & reconcile helper
  restore.sh                      # per-stack restore helper
  lib.sh                          # shared helpers (config, self-update, targets, discovery)
  prometheus.bash                 # vendored Pushgateway push helper (homelab convention)
  conf/example.conf               # TEMPLATE for CONFIG_DIR/backup.conf
  conf/docker-backup.example.conf # TEMPLATE for CONFIG_DIR/docker-backup.conf
  conf/targets/azure.example.conf # TEMPLATE for a target
  conf/targets/rsync.example.conf # TEMPLATE for a target
  secrets.env.example             # TEMPLATE for CONFIG_DIR/secrets.env
  lifecycle-policy.example.json   # Azure Blob lifecycle policy example
  dashboards/linux-backups.json   # importable Grafana dashboard
  alerts/linux-backups-rules.yaml # Prometheus alert rules
  .gitignore
  README.md
  ARCHITECTURE.md
  PLAN.md
```

## Configuration model

Per-server config lives in `CONFIG_DIR` (default `/etc/linux-backups`),
**outside** the repo checkout so self-update (`git reset --hard`) cannot clobber
it. The host FS backup auto-appends `$CONFIG_DIR` to its own tarball, so a node's
config and secrets are themselves restorable.

- `$CONFIG_DIR/backup.conf` — host backup: `NODE_NAME` (default `hostname -s`),
  `BACKUP_DIR`, `RETENTION_DAYS` (local), `REMOTE_RETENTION_DAYS`, `BLOCK_SIZE_MB`,
  optional `LOG_DIR`, `INCLUDE_PATHS=(...)`, `EXCLUDE_PATHS=(...)`.
- `$CONFIG_DIR/docker-backup.conf` — Docker backup: `STACKS=(...)` allowlist,
  `DOCKER_BACKUP_DIR`, retention/block-size, `STOP_TIMEOUT`, `BIND_IGNORE=(...)`,
  `BIND_INCLUDE_NETFS=(...)`.
- `$CONFIG_DIR/secrets.env` — `PROM_GTW` and (legacy) `DEST_URL`/`SAS_TOKEN`.
- `$CONFIG_DIR/targets/*.conf` — one file per backup destination (see
  [Backup targets](#backup-targets)); sensitive, `chmod 600`, never committed.

The server *is* the node, so there is one config set per server — no
hostname-based selection.

## Self-update

Both orchestrators self-update from git before running:

- `BRANCH` defaults to `main`; override via `--branch <b>` or `BACKUP_BRANCH`.
- `git fetch` → `checkout $BRANCH` → `reset --hard origin/$BRANCH`, then re-exec
  the updated code via a `_SELF_UPDATED=1` guard to avoid a loop.
- **Soft-fail**: if git is unreachable, log a WARNING and continue with the local
  version. A backup is never blocked on repo reachability.

## Host filesystem backup (`backup.sh`)

1. Self-update, then `set -euo pipefail`.
2. Source `secrets.env` + `backup.conf` from `CONFIG_DIR`; error clearly if missing.
3. Logging to `LOG_DIR` (default `$BACKUP_DIR/logs`), `run-<ts>.log`, keep newest 5.
4. Metric vars initialized to failure defaults so an early death still reports failure.
5. Build the tar: `EXCLUDE_PATHS` → `--exclude=`, `INCLUDE_PATHS` positional, plus
   auto-appended `$CONFIG_DIR`. `tar` rc is captured: `0`=ok, `1`=warning (files
   changed while reading; still usable), `>=2`=fatal.
6. Integrity: `gzip -t` + non-zero size check.
7. Local purge: delete `*.tar.gz` older than `RETENTION_DAYS` in `BACKUP_DIR`.
8. Deliver the archive to every enabled target (see below).
9. Metrics pushed via a `trap EXIT` handler so they always fire, even on early failure.

## Backup targets

The single upload was generalized into an abstract **target** set in `lib.sh`, so
one locally built archive is fanned out to N destinations. Used by both
`backup.sh` and `docker-backup.sh`.

- **Config**: one file per target, `$CONFIG_DIR/targets/<name>.conf`, sourced as
  bash. The filename stem `<name>` is the metric label and remote sub-prefix.
  `ENABLED` (default true) toggles a target without deleting it.
- **Types**:
  - `azure` — `azcopy copy` to `${DEST_URL}/<subpath>/${SAS_TOKEN}` with
    `--block-size-mb`. `RETENTION_MODE=none` (retention via Azure lifecycle policy).
  - `rsync` — ssh only (`user@host:/path`), optional `SSH_KEY`/`SSH_OPTS`/`BW_LIMIT`.
    `RETENTION_MODE=count`, `KEEP=N` prunes to the newest N over ssh.
- **Interface**: `target_send <name> <archive> <subpath>` dispatches on `TYPE` and
  captures rc/duration/bytes; `target_prune <name> <subpath>` applies the retention
  mode (`none` = no-op; `count` = keep newest N).
- **Layout**: each target stores archives under `<root>/<node>/...` and
  `<root>/<node>/docker/<stack>/...` for stack backups.
- **Failure isolation**: targets are attempted independently and sequentially; one
  failing never aborts the others, and the local archive is always retained.
- **Compat shim**: if `targets/` is absent but a legacy `DEST_URL` is set in
  `secrets.env`, a single `azure` target is synthesized and a migration hint logged.

## Docker stack backup (`docker-backup.sh`)

Creates **self-contained, disaster-recoverable** archives for each Compose stack —
one archive contains named volumes, bind-mount data, and the labelled Compose
config files plus top-level `.env` needed to rebuild the stack on a wiped host
(`env_file:` directives and config files outside `working_dir` are not
discovered).

- **DB consistency via stop-cold-copy**: `docker compose stop` → tar the state →
  `docker compose start`. Stopping flushes state to disk, so a raw tar is
  consistent without `pg_dump`/`mysqldump`. Trade-off: brief per-stack downtime.
- **Selection**: an explicit `STACKS` allowlist of Compose project names.
- **Discovery**: live Docker, via `com.docker.compose.project` labels on volumes
  and containers — independent of how a stack was started. A stack "has state" if
  it owns named volumes.
- **Archive layout v2** (schema 2): `manifest.json` + `compose/` (project files)
  + `volumes/<name>/` (named volume data) + `binds/<id>/` (local bind data).
- **Per stack** (sequential, to minimize downtime): classify bind mounts →
  stop → tar volumes + compose files + local bind data + write `manifest.json` →
  start → verify (`gzip -t` + non-empty) → purge old local tarballs → deliver via
  targets → push metrics.
- **Unmanaged detection**: stateful stacks not on `STACKS` raise
  `docker_backup_unmanaged_stacks` + an alert — never auto-added.
- **Bind-mount classification** (5-rule precedence per bind source):
  1. Ephemeral/system paths (`docker.sock`, `/etc/localtime`, `/proc`, …) — silently skipped.
  2. Network/remote fstype (`cifs`, `smb2/3`, `nfs/nfs4`, `fuse.sshfs`, `fuse.rclone`,
     `glusterfs`, `ceph`, `tmpfs`) — auto-excluded; counted as `docker_backup_network_binds`.
  3. `BIND_INCLUDE_NETFS` allowlist — override: force-capture even if network-fs.
  4. `BIND_IGNORE` match — excluded from archive; counted as `docker_backup_excluded_binds`.
  5. All remaining local sources — captured into `binds/<id>/`; counted as
     `docker_backup_bind_count`, sized as `docker_backup_bind_bytes`.
  - Classification, and all four counters above, are keyed by **unique source
    path per stack**, not by container-mount occurrence: identical host data
    bind-mounted by several containers or at several destinations is archived
    once (as one `binds/<id>/`) and counted once. Its full set of
    destination/RO relationships is preserved in the manifest as a `mounts[]`
    list on that one `binds[]` record, so no relationship is lost even though
    the data itself is stored/counted once. `docker_backup_bind_bytes`
    includes force-captured network binds (rule 3), since those are archived
    too.
- **Subsystem independence**: `docker-backup.sh` reads only `docker-backup.conf`.
  No dependency on `backup.conf` or the host FS backup.

## Restore (`restore.sh`)

`restore.sh <archive>` reads `manifest.json` (schema 1 or 2), recreates named
volumes via a throwaway `alpine` container, restores compose project files, and
rehydrates local bind-mount data. After restore it prints any bind sources that
were not captured (network mounts, BIND_IGNORE entries) as a re-provisioning
reminder, then prints the `docker compose up -d` next steps.

Flags: `--project-dir <path>` (compose file destination), `--bind-root <path>`
(remap bind destinations), `--no-compose`, `--no-binds`, `--force`, `--volume <v>`.

## Config bootstrap & reconcile (`docker-backup-init.sh`)

An interactive admin helper (run manually, not from cron) that inspects the live
Docker Compose landscape and helps create or reconcile `docker-backup.conf`. It is
the "fix-it" companion to the `DockerBackupUnmanagedStack` alert. It reuses the
`lib.sh` discovery helpers, lists each stack's volumes and bind mounts with
on-disk sizes and classification verdicts (`capture`, `netfs-excluded`,
`bind-ignore`), and appends additive `STACKS+=( ... )` lines under a dated
comment block (backing up the conf first, never rewriting existing entries).
Paste-ready `BIND_IGNORE+=( ... )` suggestions are printed for likely-transient
or multi-stack bind sources.

## Metrics & Pushgateway semantics

Metrics are pushed with `io::prometheus::PushAdd` (an HTTP **POST**) via
`prometheus.bash`. POST **replaces only same-named metrics in the group and keeps
the rest**. This is load-bearing:

- `*_last_success_timestamp_seconds` is pushed **only on success**, so a failed
  run (which omits it) leaves the previous success timestamp intact → robust
  staleness alerting.
- If `PROM_GTW` is unset/empty: log INFO and skip the push; the run still
  succeeds. All metric collection still happens; only the final push is skipped.

**Metric groups:**

- Host node group (`.../instance/<node>`): `backup_success` (archive built +
  integrity OK), `backup_all_targets_success`, `backup_last_success_timestamp_seconds`,
  `backup_tar_rc`, `backup_size_bytes`, `backup_duration_seconds`,
  `backup_last_run_timestamp_seconds`, `backup_retention_days`.
- Per-target group (`.../instance/<node>/target/<t>`): `backup_target_success`,
  `backup_target_rc`, `backup_target_duration_seconds`, `backup_target_bytes`,
  `backup_target_last_success_timestamp_seconds`, `backup_target_pruned_files`.
- Docker per-stack group (`.../instance/<node>/stack/<stack>`): `docker_backup_success`,
  `docker_backup_duration_seconds`, `docker_backup_size_bytes`,
  `docker_backup_volume_count`, `docker_backup_stop_seconds`,
  `docker_backup_bind_count`, `docker_backup_bind_bytes`,
  `docker_backup_excluded_binds`, `docker_backup_network_binds`,
  `docker_backup_last_run_timestamp_seconds`, `docker_backup_last_success_timestamp_seconds`.
  Docker archives also push per-target metrics under `.../stack/<stack>/target/<t>`.
- Detector group (`.../instance/<node>`): `docker_backup_unmanaged_stacks`.

## Alerts (`alerts/linux-backups-rules.yaml`)

Plain Prometheus rules, labelled `severity` (critical/warning) + `type`:

- `LinuxBackupFailed` — `backup_success == 0`.
- `LinuxBackupTargetFailed` — a target failed to deliver.
- `LinuxBackupStale` / `LinuxBackupTargetStale` — no success within the window
  (also catches "cron didn't run at all").
- `DockerBackupFailed`, `DockerBackupStale`, `DockerBackupUnmanagedStack`,
  `DockerBackupTargetFailed`, `DockerBackupTargetStale`.

## Dashboard

`dashboards/linux-backups.json` is imported via the Grafana UI (dashboards are
DB-provisioned, so no JSON lives in the running Grafana). It shows per-node and
per-target success/staleness/duration/size, plus per-stack panels.

## Remote retention (Azure lifecycle policy)

Azure retention is enforced **server-side, free, with zero client API calls** by an
account-level Blob lifecycle management policy (per-node `prefixMatch` rules merged
into one JSON), using `REMOTE_RETENTION_DAYS`. `azcopy copy` (not `sync`) is used so
no per-run destination enumeration is needed. Client-managed targets (rsync) instead
prune themselves via `RETENTION_MODE=count`.
