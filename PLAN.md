# Plan: Unified, self-updating Linux backup with Prometheus metrics

## Goal

Standardize backups across Linux boxes (e.g. `infra-1`, `lab-3`, `srv-1`) into a single,
**open-source-safe** git repo containing only the shared script + templates. Each server
keeps its own config locally (never committed). The script self-updates from git before
every run, backs up the declared paths **plus its own config**, uploads with `azcopy copy`
(cost-optimized), enforces remote retention via an Azure lifecycle policy, pushes
success/failure metrics to the existing Pushgateway, and keeps the last 5 run logs locally.

## Context (current state)

- All three current scripts share one shape:
  `source ./env` → `tar -czf` server-specific paths (with excludes) →
  `find ... -mtime +$RETENTION -delete` → `azcopy sync . $SAS_URL --delete-destination=true`.
- `env` holds `DEST`, `RETENTION`, `SAS_URL` (SAS token is a **secret** — must never be committed).
- No error handling anywhere (no `set -e`, no exit-code checks on `tar`/`azcopy`).
- Legacy/unused: `purge.sh` (sftp-based, superseded; confirmed unused on srv-1),
  `srv-1/exclude_file.txt` (unreferenced).
- **Reuse existing homelab convention**: `homelab-setup/infrastructure/backup/`
  - `backup.sh` uses a vendored `prometheus.bash` lib: `io::prometheus::NewGauge`,
    `<metric> set <val>`, `io::prometheus::PushAdd job=<j> instance=<i> gateway=$PROM_GTW`.
  - `setenv`: `export PROM_GTW=https://prometheus-pushgateway.internal.asksven.io:443`.
  - `PushAdd` = HTTP POST = replaces only same-named metrics in the group, keeps others.
- Alert convention: plain Prometheus `rules.yml` (groups/rules), labels `severity`
  (critical/warning) + `type`. Example:
  `homelab-setup/.../rook-ceph-cluster/prometheus/localrules.yaml`.
- Grafana: dashboards live in `grafana.db` (DB-provisioned), no JSON in repo →
  deliver an importable dashboard JSON, imported via the UI.
- Pushgateway already exists, internal URL, no auth.

## Decisions (final)

- Repo is open-source-safe: only the script + templates are committed.
- Per-server `backup.conf` + `secrets.env` live in `CONFIG_DIR` **outside** the repo
  checkout and are **included in the backup** (so a node is fully restorable).
- Script self-updates from git (`main` by default, any branch for testing), failing
  **soft** if the repo is unreachable.
- No per-server config migration in-repo — README documents **manual migration**.
- Upload via `azcopy copy` (not `sync`); **no** `--delete-destination`.
- Local retention (`RETENTION_DAYS`) and remote retention (`REMOTE_RETENTION_DAYS`)
  are independent values.
- Remote retention enforced **only** by an Azure Blob lifecycle management policy.
- Empty `PROM_GTW` → INFO log, skip push, run still succeeds.
- Bash only; reuse `prometheus.bash` (no Python, no permanent process).
- Deployment (cron) is documented only, not automated.

## Repository structure (committed — no secrets, no server configs)

```
linux-backups/
  backup.sh                    # self-update + orchestrator
  prometheus.bash              # vendored push helper (homelab convention)
  conf/example.conf            # TEMPLATE only
  secrets.env.example          # TEMPLATE only (DEST_URL/SAS, PROM_GTW)
  lifecycle-policy.example.json
  dashboards/linux-backups.json
  alerts/linux-backups-rules.yaml
  .gitignore
  README.md
  PLAN.md
```

No committed per-server configs. Legacy `infra-1/`, `lab-3/`, `srv-1/` dirs,
`purge.sh`, and `exclude_file.txt` are removed.

## Local, per-server files (never committed)

Stored in `CONFIG_DIR` (default `/etc/linux-backups`), **outside** the repo checkout so
self-update (`git reset --hard`) cannot clobber them:

- `$CONFIG_DIR/backup.conf` — `NODE_NAME` (default `hostname -s`), `BACKUP_DIR`,
  `RETENTION_DAYS` (local), `REMOTE_RETENTION_DAYS`, `BLOCK_SIZE_MB`, optional `LOG_DIR`,
  `INCLUDE_PATHS=(...)`, `EXCLUDE_PATHS=(...)`.
- `$CONFIG_DIR/secrets.env` — `DEST_URL` (container base + SAS), `PROM_GTW`.

Single config per server (the server *is* the node) → no hostname-based selection needed.

## `backup.sh` design

1. **Self-update first** (before the backup):
   - `BRANCH` defaults to `main`; override via `--branch <b>` arg or `BACKUP_BRANCH` env.
   - `git -C <repo> fetch` → `checkout $BRANCH` → `reset --hard origin/$BRANCH`.
   - Re-exec the updated code via a guard: `_SELF_UPDATED=1 exec "$0" "$@"` (avoids loop).
   - **Resilience**: if git fails (offline/unreachable), log **WARNING** and continue
     with the current local version — never block a backup on repo reachability.
2. `set -euo pipefail`.
3. `CONFIG_DIR=${CONFIG_DIR:-/etc/linux-backups}`; source `secrets.env` + `backup.conf`;
   error clearly if missing.
4. **Logging**: `LOG_DIR` default `$BACKUP_DIR/logs`; `LOGFILE=run-<ts>.log`;
   `exec > >(tee -a "$LOGFILE") 2>&1`. Rotate: keep newest 5.
5. Initialize all metric vars to **failure defaults** so an early death still reports failure.
6. **Build tar**: `EXCLUDE_PATHS` → `--exclude=`; `INCLUDE_PATHS` positional; **auto-append
   `$CONFIG_DIR`** so config + secrets are captured in the tarball. Capture `tar` rc:
   `0`=ok, `1`=warning (files changed while reading; still usable), `>=2`=fatal failure.
7. **Integrity**: `gzip -t "$BACKUP_FILE"` + non-zero size check.
8. **Local purge**: `find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz'
   -mtime +$RETENTION_DAYS -delete`.
9. **Upload (cost-optimized)**:
   `azcopy copy "$BACKUP_FILE" "$DEST_URL/<NODE_NAME>/" --block-size-mb=$BLOCK_SIZE_MB`
   — only today's tarball, **no** `--delete-destination`. Capture `azcopy` rc and parse
   "Number of Transfers Failed" from output for extra safety.
10. `overall_success = tar_ok && integrity_ok && azcopy_ok`.
11. **Metrics push** via `trap EXIT` so it always runs (even on early failure).

### Error handling

- `trap` on `ERR`/`EXIT`; capture `tar`/`azcopy` rc explicitly (guarded against `set -e`).
- `EXIT` handler computes the final success flag, pushes metrics, exits with proper code.

## Metrics

Pushed with `io::prometheus::PushAdd` (POST) — `job=linux_backup`, `instance=$NODE_NAME`,
`gateway=$PROM_GTW`:

- `backup_success` (1/0, overall)
- `backup_tar_rc`
- `backup_azcopy_rc`
- `backup_duration_seconds`
- `backup_size_bytes`
- `backup_last_run_timestamp_seconds` (always = now)
- `backup_last_success_timestamp_seconds` (**only on success** → persists across failed
  runs because POST keeps metrics not present in the body)
- `backup_retention_days`

**Rationale**: only pushing `last_success` on success + POST semantics means the previous
success timestamp survives failed runs → enables robust staleness alerting.

### Empty `PROM_GTW` handling

If `PROM_GTW` is unset/empty: log **INFO** "Pushgateway URL not set; skipping metrics push"
(INFO, **not** error), skip the push, and **do not** fail the run. All metric collection
still happens; only the final `PushAdd` is conditionally skipped.

## Remote retention (decoupled, Azure lifecycle policy only)

- Each node uploads to its own prefix: `$DEST_URL/<NODE_NAME>/server-<ts>.tar.gz`.
- Retention enforced **server-side, free, with zero client API calls** by an Azure Blob
  lifecycle management policy:
  - `filters.blobTypes = [blockBlob]`
  - `filters.prefixMatch = ["<container>/<node>/"]`
  - `actions.baseBlob.delete.daysAfterModificationGreaterThan = REMOTE_RETENTION_DAYS`
- The management policy is **account-level** (one policy holds all node rules) → per-node
  rules are merged into one JSON.
- Provide `lifecycle-policy.example.json` + a README `az` snippet to create/update the rule
  using `REMOTE_RETENTION_DAYS`:

  ```bash
  az storage account management-policy create \
    --account-name <acct> -g <rg> --policy @lifecycle-policy.json
  ```

## Cost rationale (why `sync` was expensive)

- `azcopy sync --delete-destination=true` **indexes/enumerates both source and destination
  on every run** (List Blobs / iterative-read operations) plus runs delete reconciliation —
  this is the Azure **transaction-cost** driver. Microsoft docs recommend `copy` over `sync`
  when not deleting because copy "doesn't have to index the source or destination."
- Switching to `azcopy copy` of only today's tarball removes per-run destination enumeration.
- Lifecycle policy removes all client-side listing/delete operations (deletes are free anyway).
- `--block-size-mb` reduces the number of Put Block write operations on large tarballs
  (data-write per GB is free; only per-operation is charged).

## Alerts (`alerts/linux-backups-rules.yaml`, plain `rules.yml`)

```yaml
groups:
  - name: linux-backups
    rules:
      - alert: LinuxBackupFailed
        expr: backup_success{job="linux_backup"} == 0
        for: 5m
        labels: { severity: critical, type: backup }
      - alert: LinuxBackupStale
        expr: time() - backup_last_success_timestamp_seconds{job="linux_backup"} > 90000  # >25h
        labels: { severity: critical, type: backup }
```

`LinuxBackupStale` also catches "cron didn't run at all".

## Dashboard (`dashboards/linux-backups.json`, importable)

- Table/stat: `backup_success` by node (green/red).
- Stat: time since last success per node (`time() - backup_last_success_timestamp_seconds`).
- Time series: `backup_duration_seconds` by node.
- Time series: `backup_size_bytes` by node.
- Table: `backup_tar_rc` / `backup_azcopy_rc` by node.

## README contents

- Bootstrap: clone repo (e.g. to `/opt/linux-backups`), create `CONFIG_DIR` with
  `backup.conf` + `secrets.env`, add a cron entry calling `backup.sh` (optional `--branch`).
- **Manual migration paragraph**: how to convert an existing per-server `backup.sh` + `env`
  into `$CONFIG_DIR/backup.conf` (`INCLUDE_PATHS`/`EXCLUDE_PATHS` from old `tar` args,
  `RETENTION_DAYS`, `BACKUP_DIR`) + `$CONFIG_DIR/secrets.env` (`SAS` → `DEST_URL`, `PROM_GTW`)
  **before** adopting the git repo. Uses srv-1/infra-1/lab-3 as prose examples only.
- Lifecycle policy install (`az` snippet above).
- Reading the last-5 run logs.
- Importing the Grafana dashboard JSON.
- Deploying the alert rules.

## Verification

1. `shellcheck backup.sh`.
2. `DRY_RUN=1 ./backup.sh` (run `tar` + metrics, skip `azcopy`); confirm `$CONFIG_DIR` is
   inside the tar.
3. Self-update: run with `--branch test`, confirm it checks out that branch and re-execs;
   simulate a git failure → WARNING + continues.
4. Empty `PROM_GTW` → INFO log + success, no push.
5. Apply lifecycle policy; verify via `az storage account management-policy show`.
6. `promtool check rules alerts/linux-backups-rules.yaml`; import the dashboard JSON.

## Scope

- **Included**: `backup.sh` (self-update + backup + metrics + logging), `prometheus.bash`,
  `conf/example.conf`, `secrets.env.example`, `lifecycle-policy.example.json`, dashboard JSON,
  alert rules, `.gitignore`, README; removal of legacy dirs/`purge.sh`/`exclude_file.txt`.
- **Excluded**: deploying the Pushgateway (exists), SAS rotation, restic migration,
  cron/systemd automation (documented only), any script-based pruning.

---

# Plan: Docker Compose volume backup extension

## Goal

Add a generic way to back up the persistent state of Docker Compose stacks on each host,
reusing this repo's existing conventions (bash, self-update, `azcopy copy` upload, Pushgateway
metrics, Azure lifecycle retention). Each **stack** is backed up as its own archive containing
all of its named volumes so a restore is per-stack and less error-prone. Databases are made
consistent **without** dump tooling by using **stop-cold-copy** (`docker compose stop` → tar the
volumes → `docker compose start`). Stacks that hold persistent state but are not configured for
backup are **detected and alerted on** (never auto-added). Bind mounts — the classic blind spot —
are detected, coverage-checked against the host-path backup, and can be explicitly acknowledged.

## Decisions (final)

- **Integration**: a new bash companion script `docker-backup.sh` in this repo, reusing shared
  helpers (config load, `azcopy` upload, Pushgateway push) — no new runtime, no companion
  container.
- **DB consistency**: **stop-cold-copy** per stack. Stopping the containers flushes state to disk,
  so a raw `tar` of the volumes is consistent. No `pg_dump`/`mysqldump`/etc. tooling. Trade-off:
  brief per-stack downtime, accepted for guaranteed consistency and zero DB-specific code.
- **Backup selection**: an explicit **allowlist** (`STACKS`) of compose project names. Only listed
  stacks are backed up.
- **Auto-detection**: **alert only, never auto-add**. Running stacks that own named volumes but are
  not on the allowlist raise a Pushgateway metric + Prometheus alert.
- **Discovery**: **live Docker**, via `com.docker.compose.project` labels on volumes and
  containers — independent of how a stack was started.
- **Restore**: include a `restore.sh` helper.
- **Bind mounts**: detected and coverage-checked (see below); acknowledged declaratively via
  `BIND_IGNORE`. Named volumes are the default backup unit; bind-mount *state* is expected to be
  covered by the host-path backup (`INCLUDE_PATHS` in `backup.conf`).

## Repository structure (additions)

```
linux-backups/
  lib.sh                         # NEW — shared helpers extracted from backup.sh
  backup.sh                      # refactored to source lib.sh (no behavior change)
  docker-backup.sh               # NEW — compose stack backup orchestrator
  docker-backup-init.sh          # NEW — interactive config bootstrap & reconcile helper
  restore.sh                     # NEW — per-stack restore helper
  conf/docker-backup.example.conf# NEW — template for CONFIG_DIR/docker-backup.conf
  alerts/linux-backups-rules.yaml# + docker backup alerts
  dashboards/linux-backups.json  # + per-stack panels
  lifecycle-policy.example.json  # + <container>/<node>/docker/ prefix rule
  README.md                      # + "Docker Compose backups" section
```

## Local, per-server config (never committed)

New file `$CONFIG_DIR/docker-backup.conf`, alongside the existing `backup.conf` /
`secrets.env` (reuses `DEST_URL`, `SAS_TOKEN`, `PROM_GTW` from `secrets.env`):

- `STACKS=(...)` — allowlist of compose project names to back up.
- `DOCKER_BACKUP_DIR` — local output dir (default `$BACKUP_DIR/docker`).
- `RETENTION_DAYS`, `REMOTE_RETENTION_DAYS`, `BLOCK_SIZE_MB` — as per host backup.
- `STOP_TIMEOUT` — grace period for `docker compose stop`.
- `BIND_IGNORE=(...)` — declarative acknowledgments of transient bind mounts (see below).

## Phase 1 — Shared library (`lib.sh`)

1. Extract `log`, `self_update`, the secrets/config sourcing, the `azcopy copy` upload, and the
   Pushgateway `curl` push from `backup.sh` into `lib.sh`.
2. Refactor `backup.sh` to `source lib.sh` with **no behavior change** (guarded by shellcheck +
   `DRY_RUN=1`). *Blocks Phase 2.*

## Phase 2 — `docker-backup.sh`

1. Self-update (shared), load `secrets.env` + `docker-backup.conf`, set up logging.
2. **Discover** stateful stacks live: `docker volume ls -f label=com.docker.compose.project=<s>`
   → `docker volume inspect` for mountpoints. A stack "has state" if it owns named volumes.
3. **Per stack** (sequential, to minimise downtime):
   - Resolve the stack's named volumes and their mountpoints.
   - Derive the compose project dir/config files from container labels
     (`com.docker.compose.project.working_dir` / `.config_files`); fall back to
     `docker stop`/`start` by container list.
   - `docker compose stop` (with `STOP_TIMEOUT`).
   - `tar` each volume's `_data` into a per-volume subdir + write a `manifest.json`
     (volume names, mountpoints, project, compose files, timestamp).
   - `docker compose start`.
   - Verify (`gzip -t` + non-empty), purge local old tarballs for that stack, then
     `azcopy copy` to `$DEST_URL/<node>/docker/<stack>/`.
4. **Unmanaged detection**: compare discovered stateful stacks vs `STACKS`; log the difference and
   emit `docker_backup_unmanaged_stacks`.

### Bind-mount detection & acknowledgment

For every stack (managed **and** unmanaged), during discovery:

1. Enumerate containers by project label; per container
   `docker inspect --format '{{range .Mounts}}{{.Type}} {{.Source}} {{.Destination}} {{.RW}}{{"\n"}}{{end}}'`.
   Keep `Type=bind`, `RW=true`.
2. **Ephemeral filter** (hardcoded infra noise): `docker.sock`, `/etc/localtime`,
   `/etc/timezone`, `/etc/hosts`, `/etc/resolv.conf`, `/proc`, `/sys`, `/dev`, `/run`, and
   compose config-file sources.
3. **`BIND_IGNORE` acknowledgment** (user-curated, separate from the ephemeral filter): matched
   after `realpath` as exact path, directory subtree (trailing `/`), or glob (e.g. `/srv/*/cache`);
   optional `stack:` qualifier (e.g. `immich:/data/thumbs-cache`) to scope to one stack. Each entry
   is expected to carry a comment documenting **why** it is transient.
4. **Coverage check**: `docker-backup.sh` sources `backup.conf` (same `CONFIG_DIR`) and tests each
   remaining bind source against `INCLUDE_PATHS` / `EXCLUDE_PATHS` (realpath + prefix match with a
   trailing-slash guard) → **covered** or **uncovered**. If `backup.conf` is absent, report without
   a coverage verdict.

Pipeline: detect bind → ephemeral filter → `BIND_IGNORE` ack → coverage check → only
**uncovered and unacknowledged** binds alert.

Hygiene: if a `BIND_IGNORE` entry matches nothing on a run, log a **WARNING**
("stale BIND_IGNORE entry") so the list is pruned and cannot silently hide a newly-important path.

## Phase 3 — `restore.sh`

`restore.sh <archive>`: read `manifest.json` → `docker volume create` each volume → extract each
per-volume subdir into its volume via a throwaway `alpine` helper container → print the
`docker compose up` next steps. (Optionally stop the stack first if running.)

## Phase 4 — Observability & retention

Metrics pushed with POST, `job=docker_backup`, **grouped per stack**
(`.../instance/<node>/stack/<stack>`) so a POST only replaces that stack's group and each stack's
`last_success` survives another stack's failure:

- `docker_backup_success`
- `docker_backup_duration_seconds`
- `docker_backup_size_bytes`
- `docker_backup_volume_count`
- `docker_backup_stop_seconds` (downtime)
- `docker_backup_last_run_timestamp_seconds`
- `docker_backup_last_success_timestamp_seconds` (**only on success**)
- `docker_backup_uncovered_bind_mounts{stack}` — genuinely uncovered, unacknowledged binds.
- `docker_backup_ignored_bind_mounts{stack}` — acknowledged binds (audit visibility).

Detector group per node (`.../instance/<node>`): `docker_backup_unmanaged_stacks`,
`docker_backup_last_run_timestamp_seconds`.

Alerts (added to `alerts/linux-backups-rules.yaml`):

- `DockerBackupFailed` — `docker_backup_success == 0` (critical).
- `DockerBackupStale` — no success in >N h (critical); also catches "cron didn't run".
- `DockerBackupUnmanagedStack` — `docker_backup_unmanaged_stacks > 0` (warning).
- `DockerBackupUncoveredBindMount` — `docker_backup_uncovered_bind_mounts > 0` (warning).

Dashboard: add per-stack panels (success, downtime, size, uncovered/ignored binds).
Lifecycle policy: add a rule for the `<container>/<node>/docker/` prefix using
`REMOTE_RETENTION_DAYS`.

## Phase 5 — `docker-backup-init.sh` (config bootstrap & reconcile)

An interactive admin helper (run manually, **not** from cron) that inspects the node's live Docker
Compose landscape and guides the operator to create `docker-backup.conf` or fill in the gaps in an
existing one. It is the "fix-it" companion to the runtime `DockerBackupUnmanagedStack` /
`DockerBackupUncoveredBindMount` alerts.

Reuses the Phase 2 discovery functions (shared in `lib.sh`): stateful-stack discovery, per-stack
volumes, bind-mount enumeration + coverage check — no duplicated discovery logic.

Each reported stack lists its named volumes and bind mounts with their on-disk size (`du`) so the
operator can judge what is worth backing up (a volume shows `?` when its mountpoint is not
host-accessible, e.g. on Docker Desktop).

Behaviour:

- **No `docker-backup.conf` yet** → offer to create one from `conf/docker-backup.example.conf`,
  pre-populating `STACKS` with the discovered stateful stacks (interactive per-stack yes/no) and
  sensible defaults; list discovered uncovered bind mounts as **commented** `BIND_IGNORE` review
  candidates (never auto-acknowledged).
- **Existing `docker-backup.conf`** → print a reconciliation report:
  - stateful stacks running but **not** in `STACKS` (unmanaged) → offer to append.
  - stacks in `STACKS` with **no** live state (removed/renamed) → warn only, never auto-remove
    (a stack may just be temporarily down).
  - newly uncovered bind mounts → print suggested `BIND_IGNORE` / `INCLUDE_PATHS` review items.

Safety & idempotency:

- Never rewrites the existing array literal; appends additive `STACKS+=( "name" )` lines under a
  dated, clearly-marked comment block, so manual edits/comments are preserved.
- Backs up the conf (`docker-backup.conf.bak-<ts>`) before any write.
- Bind-mount acknowledgments are **printed, not applied** — they require human judgement.

Flags: `--print` (report only; default when non-interactive), `--write` / `--yes` (apply additive
suggestions non-interactively), `--config <path>` (override `CONFIG_DIR` location).

## Verification

1. `shellcheck lib.sh backup.sh docker-backup.sh restore.sh`.
2. `DRY_RUN=1 ./backup.sh` — confirm the `lib.sh` refactor is behavior-neutral.
3. Test host: run against a small file-volume stack → confirm per-volume subdirs + `manifest.json`
   in the tarball, and the stack is stopped then restarted; `gzip -t` passes.
4. Run against a DB stack (e.g. postgres) → restore into fresh volumes with `restore.sh`,
   `docker compose up`, verify the DB starts clean and data is intact.
5. Start a stateful stack **not** on the allowlist → confirm `docker_backup_unmanaged_stacks` +
   `DockerBackupUnmanagedStack` fire.
6. Add a stack with an uncovered bind mount → confirm `docker_backup_uncovered_bind_mounts` +
   `DockerBackupUncoveredBindMount`; add it to `BIND_IGNORE` → confirm it moves to
   `docker_backup_ignored_bind_mounts` and no longer alerts; add a bogus `BIND_IGNORE` entry →
   confirm the "stale entry" WARNING.
7. `promtool check rules alerts/linux-backups-rules.yaml`; import the dashboard JSON.
8. `docker-backup-init.sh`: on a host with **no** conf → generates a valid `docker-backup.conf`
   (`shellcheck` / `bash -n` clean) containing the discovered stacks; on a host **with** an existing
   conf and a new stateful stack → `--print` reports it as unmanaged and `--write` appends a
   `STACKS+=( ... )` line without touching existing entries, creating a `.bak-<ts>` first.

## Scope

- **Included**: `lib.sh` (shared helpers + `backup.sh` refactor), `docker-backup.sh` (discover +
  stop-cold-copy + verify + upload + metrics + unmanaged/bind detection),
  `docker-backup-init.sh` (interactive config bootstrap & reconcile), `restore.sh`,
  `conf/docker-backup.example.conf`, docker alerts, dashboard panels, lifecycle prefix rule,
  README section.
- **Excluded**: live database dumps (chose stop-cold-copy), backing up bind-mount *state* by
  default (covered by host-path backups; alerting only, with optional acknowledgment), Docker
  Swarm, non-`local` volume drivers, cron automation (documented only).

---

# Plan: Multiple backup targets

## Goal

Generalise the single Azure/`azcopy` upload into an abstract set of **targets**, so one locally
built archive is fanned out to N destinations (e.g. `azcopy` → Azure **and** `rsync` over ssh → an
on-site box). Metrics gain a **`target`** dimension so we can see, per destination, whether the
local archive was delivered. Retention becomes **per target**: Azure keeps its server-side
lifecycle policy (cost-driven, no client calls), while client-managed targets (rsync) prune
themselves ("keep newest N"). This applies to **both** the host backup (`backup.sh`) and the
Docker Compose backup (`docker-backup.sh`) via the shared `lib.sh`.

## Decisions (final)

- **Config shape**: one file per target — `$CONFIG_DIR/targets/<name>.conf` — each sourced as
  bash. The filename stem (`<name>`) is the target's metric label and remote sub-prefix. Optional
  `ENABLED` (default true) toggles a target without deleting it.
- **rsync transport**: **ssh only** (`user@host:/path`). No locally-mounted-path mode.
- **Retention modes**: `none` (target-managed, e.g. Azure lifecycle) and `count` (keep newest N).
  No days-based mode for now.
- **Metric model**: **split**. `backup_success` now means *local archive built + integrity OK*;
  per-target `backup_target_success{target}` covers delivery; `backup_all_targets_success` is the
  AND across targets. `backup_azcopy_rc` is **renamed** to `backup_target_rc{target}`
  (dashboards/alerts updated in the same change).
- **Shared**: the target layer lives in `lib.sh` and is used by both `backup.sh` and
  `docker-backup.sh`.
- **Failure isolation**: each target is attempted independently; one failing never aborts the
  others, and the local archive is always retained (per `RETENTION_DAYS`) so nothing is lost.
- **Depends on** the `lib.sh` extraction from the Docker Compose plan (Phase 1) — one shared lib.

## Target config

`$CONFIG_DIR/targets/*.conf`, sensitive (SAS tokens, ssh key paths) → `chmod 600`, never
committed. Committed templates: `conf/targets/azure.example.conf`, `conf/targets/rsync.example.conf`.

Common keys: `TYPE`, `ENABLED` (default true), `RETENTION_MODE` (`none` | `count`), `KEEP` (for
`count`).

- **azure**: `TYPE=azure`, `DEST_URL`, `SAS_TOKEN`, `BLOCK_SIZE_MB`, `RETENTION_MODE=none`.
- **rsync**: `TYPE=rsync`, `DEST=user@host:/path`, optional `SSH_KEY`, `SSH_OPTS`, `BW_LIMIT`,
  `RETENTION_MODE=count`, `KEEP=N`.

Each target stores archives under the same node layout beneath its own root
(`<root>/<node>/...`, and `<root>/<node>/docker/<stack>/...` for stack backups).

## `lib.sh` target interface

- `target_send <name> <archive> <subpath>` — dispatch on `TYPE`:
  - `_send_azure` → `azcopy copy` to `${DEST_URL}/<subpath>/${SAS_TOKEN}` with `--block-size-mb`
    (today's logic, parameterised).
  - `_send_rsync` → `rsync -a [--bwlimit] -e "ssh [-i SSH_KEY] [SSH_OPTS]" <archive>
    <DEST>/<subpath>/` (creates the remote dir).
  - Captures rc, duration, bytes.
- `target_prune <name> <subpath>`:
  - `none` → no-op (INFO: "retention managed by target/lifecycle policy").
  - `count` → over ssh: `ls -1t <DEST path>/<subpath>/*.tar.gz | tail -n +$((KEEP+1)) | xargs -r
    rm --`; returns the number of files pruned.
- Both wrapped in `set +e` with explicit rc capture.

## Phase A — Target layer in `lib.sh`

1. Add target discovery (iterate `targets/*.conf`, skip `ENABLED=false`), `target_send`,
   `target_prune`, and the per-type helpers.
2. **Backward-compat shim**: if `targets/` is missing/empty but a legacy `DEST_URL` is set in
   `secrets.env`, synthesize a single `azure` target (`RETENTION_MODE=none`) and log an INFO line
   recommending migration to a target file.

## Phase B — Wire `backup.sh`

3. Replace the single `upload_archive` call with a loop over targets: `target_send` → record
   per-target metrics → on success `target_prune`.
4. Recompute success: `backup_success` = archive+integrity; `backup_all_targets_success` = AND of
   per-target results; `backup_last_success_timestamp_seconds` set only when archive **and all
   targets** succeed.
5. `DRY_RUN=1` skips actual sends but still enumerates targets and marks each successful (parity
   with today).

## Phase C — Wire `docker-backup.sh`

6. Reuse the same `target_send`/`target_prune` for each per-stack archive; push per-stack **and**
   per-target metrics.

## Metrics (restructured)

Node group (`.../instance/<node>`):

- `backup_success` — archive built + integrity OK (**semantics changed**).
- `backup_all_targets_success` — 1 iff every enabled target delivered.
- `backup_last_success_timestamp_seconds` — only on archive + **all** targets OK (fully
  replicated); survives failures via POST semantics.
- `backup_tar_rc`, `backup_size_bytes`, `backup_duration_seconds`,
  `backup_last_run_timestamp_seconds`, `backup_retention_days`.

Per-target group (`.../instance/<node>/target/<t>`):

- `backup_target_success`
- `backup_target_rc` — transfer tool exit code (**renamed** from `backup_azcopy_rc`).
- `backup_target_duration_seconds`
- `backup_target_bytes`
- `backup_target_last_success_timestamp_seconds` — only on success (per-target staleness survives).
- `backup_target_pruned_files` — files removed by `count` retention (0 for `none`).

Docker Compose analog: per-stack **and** per-target group
(`.../instance/<node>/stack/<stack>/target/<t>`).

## Alerts (updated `alerts/linux-backups-rules.yaml`)

- `LinuxBackupFailed` — `backup_success == 0` (archive failure) — kept.
- `LinuxBackupTargetFailed` — `backup_target_success == 0` (critical), labelled `target`.
- `LinuxBackupTargetStale` — `time() - backup_target_last_success_timestamp_seconds > N` per target.
- `LinuxBackupStale` — now reflects fully-replicated staleness (archive + all targets).

Dashboard: add a node×target success matrix, per-target last-success age, per-target duration, and
pruned-files panels; update panels that referenced `backup_azcopy_rc`.

## Migration

- Move `DEST_URL` / `SAS_TOKEN` from `secrets.env` into `targets/azure.conf`
  (`RETENTION_MODE=none`); add `targets/onsite.conf` (`TYPE=rsync`, `DEST`, `KEEP`).
- Until migrated, the compat shim keeps existing single-Azure installs working across self-update.
- README: document the target files, the metric rename, and the rsync ssh prerequisites (key
  access, remote path).

## Verification

1. `shellcheck lib.sh backup.sh docker-backup.sh`.
2. Two targets configured (azure + rsync-to-a-test-host): run `backup.sh` → archive delivered to
   both; per-target metrics present with distinct `target` labels; `backup_all_targets_success=1`.
3. Break one target (bad ssh host) → that target's `backup_target_success=0` +
   `LinuxBackupTargetFailed` fires; the other still succeeds; archive retained locally;
   `backup_all_targets_success=0`.
4. rsync `count` retention: upload > `KEEP` archives → confirm only newest `KEEP` remain on the
   remote and `backup_target_pruned_files` reflects the deletions; azure target performs no client
   prune.
5. Compat shim: with no `targets/` but legacy `DEST_URL`, confirm a synthesized `azure` target runs
   and logs the migration hint.
6. `DRY_RUN=1 ./backup.sh` → targets enumerated, no sends, each marked successful.
7. `promtool check rules alerts/linux-backups-rules.yaml`; import updated dashboard.

## Scope

- **Included**: target layer in `lib.sh` (`target_send`/`target_prune` + azure/rsync helpers +
  discovery + compat shim), `backup.sh` and `docker-backup.sh` wiring, `conf/targets/*.example.conf`,
  restructured metrics with `target` label + `backup_azcopy_rc` rename, new/updated alerts,
  dashboard updates, README migration section.
- **Excluded**: rsync to locally-mounted paths, days-based remote retention, additional target
  types (S3/WebDAV/etc.), encryption changes, parallel fan-out (targets run sequentially),
  automatic secrets rotation.
