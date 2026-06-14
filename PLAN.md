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
