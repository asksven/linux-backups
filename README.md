# linux-backups

Standardized, self-updating backups for Linux hosts. One shared script is kept in
this git repo; each server only holds a small local config. On every run the
script pulls the latest version from git, creates a `tar.gz` of the paths you
declare (plus its own config), uploads **only the new archive** to Azure Blob
Storage with `azcopy copy`, keeps a rolling local history, and pushes
success/failure metrics to a Prometheus Pushgateway.

Remote retention is handled **server-side by an Azure Blob lifecycle policy** —
not by the script — to keep Azure transaction (API-call) costs low.

## How it works

```
git pull (self-update)  ->  tar -czf  ->  verify (gzip -t)  ->  purge local old
                                                                     |
        push metrics  <-  azcopy copy (new tarball only)  <----------+
```

- **No `azcopy sync` / `--delete-destination`.** `sync` indexes the whole
  destination on every run (List Blob operations) — the main driver of Azure
  transaction costs. `copy` uploads just today's tarball.
- Each node uploads under its own prefix: `<container>/<node>/<node>-<timestamp>.tar.gz`.
- Local retention (`RETENTION_DAYS`) and remote retention
  (`REMOTE_RETENTION_DAYS`, via lifecycle policy) are independent.

## Repository layout

| Path | Purpose |
| --- | --- |
| `backup.sh` | The shared backup + self-update script. |
| `conf/example.conf` | Template for a per-server `backup.conf`. |
| `secrets.env.example` | Template for a per-server `secrets.env`. |
| `lifecycle-policy.example.json` | Azure lifecycle policy template (remote retention). |
| `alerts/linux-backups-rules.yaml` | Prometheus alerting rules. |
| `dashboards/linux-backups.json` | Importable Grafana dashboard. |

Per-server configs and secrets are **never committed** — they live in `CONFIG_DIR`
on each host (default `/etc/linux-backups`) and are themselves included in the
backup so a node is fully restorable.

## Per-server setup

1. **Clone the repo** somewhere stable, e.g.:

   ```bash
   sudo git clone https://github.com/<you>/linux-backups.git /opt/linux-backups
   ```

2. **Create the config directory** and drop in your config + secrets:

   ```bash
   sudo mkdir -p /etc/linux-backups
   sudo cp /opt/linux-backups/conf/example.conf   /etc/linux-backups/backup.conf
   sudo cp /opt/linux-backups/secrets.env.example /etc/linux-backups/secrets.env
   sudo chmod 600 /etc/linux-backups/secrets.env
   sudoedit /etc/linux-backups/backup.conf      # set paths, retention, node name
   sudoedit /etc/linux-backups/secrets.env      # set DEST_URL, SAS_TOKEN, PROM_GTW
   ```

3. **Test it** without uploading:

   ```bash
   sudo DRY_RUN=1 /opt/linux-backups/backup.sh
   ```

   `DRY_RUN=1` skips both the self-update and the `azcopy` upload, but still
   builds the archive and pushes metrics.

4. **Schedule it** via cron (self-update happens automatically on each run).
   Create `/etc/cron.d/linux-backups` with the following content. The `PATH` line
   matters: cron's default `PATH` is minimal and would not find `git`, `azcopy`
   or `curl`.

   ```cron
   SHELL=/bin/bash
   PATH=/usr/local/bin:/usr/bin:/bin

   # Run the backup daily at 02:30
   30 2 * * * root /opt/linux-backups/backup.sh
   ```

   The full run is already written to a per-run logfile under `$BACKUP_DIR/logs`
   (see [Logs](#logs)), so no output redirection is needed. Optionally, append
   `>> /var/log/linux-backups-cron.log 2>&1` to also capture the *early* phase
   (the git self-update and any config-loading errors that occur before that
   per-run logfile is opened); otherwise that output goes to cron mail.



### Testing a branch

To try changes from a non-default branch on a single host, pass `--branch`:

```bash
sudo /opt/linux-backups/backup.sh --branch my-test-branch
```

The script hard-resets its checkout to `origin/<branch>` before running. If git
is unreachable (offline), it logs a warning and continues with the current local
version — a backup is never skipped because of a failed update.

## Backup targets

The built archive is delivered to one or more **targets** — one file per target
under `$CONFIG_DIR/targets/<name>.conf` (the filename stem is the target's name
and its Prometheus `target` label). Copy a template and fill it in:

```bash
sudo mkdir -p /etc/linux-backups/targets
sudo install -m 600 conf/targets/azure.example.conf /etc/linux-backups/targets/azure.conf
sudo install -m 600 conf/targets/rsync.example.conf /etc/linux-backups/targets/onsite.conf
sudoedit /etc/linux-backups/targets/azure.conf
sudoedit /etc/linux-backups/targets/onsite.conf
```

Two target types are supported:

- **azure** — `azcopy copy` to Azure Blob Storage (`DEST_URL`, `SAS_TOKEN`,
  `BLOCK_SIZE_MB`). Retention is `none`: enforced by the Azure lifecycle policy.
- **rsync** — `rsync` over ssh to `DEST=user@host:/path` (`SSH_KEY`, `SSH_OPTS`,
  `BW_LIMIT`). Retention `count` keeps only the newest `KEEP` archives per
  prefix, pruned over ssh after each successful upload.

Each target is attempted independently; one failing never blocks the others, and
the local archive is always kept (per `RETENTION_DAYS`). `backup_success` reflects
the **local archive**, `backup_all_targets_success` reflects delivery to **all**
targets, and per-target `backup_target_*` metrics carry a `target` label. Set
`ENABLED=false` in a target file to skip it without deleting it.

The same targets are used by the Docker Compose backup (each stack archive is
fanned out to every target under `<node>/docker/<stack>/`).

**Verify credentials before relying on a target.** Run a read-only preflight that
probes every enabled target and prints a pass/fail table (no backup is made):

```bash
sudo /opt/linux-backups/backup.sh --check-targets
sudo /opt/linux-backups/docker-backup.sh --check-targets
```

For **azure** it uploads a tiny `.healthcheck` probe blob (the only way to verify
a write-only SAS token) and best-effort deletes it; for **rsync** it opens an ssh
connection and checks the base path is writable. It exits non-zero if any target
fails.

**Compatibility:** if no `targets/*.conf` exist but `secrets.env` still has a
legacy `DEST_URL`/`SAS_TOKEN`, a single `azure` target named `azure` is
synthesised automatically (with an INFO hint to migrate).

## Remote retention (Azure lifecycle policy)

Retention of remote tarballs is enforced by an account-level Blob lifecycle
policy. It runs daily, server-side, costs nothing, and makes **zero** client API
calls — unlike client-side listing/deletion.

The policy holds **one rule per node**, each filtered on that node's prefix and
using its `REMOTE_RETENTION_DAYS` value. Edit
[`lifecycle-policy.example.json`](lifecycle-policy.example.json) — set the
container name in each `prefixMatch` (`<container>/<node>/`) and the
`daysAfterModificationGreaterThan` value — then apply it:

```bash
az storage account management-policy create \
  --account-name <storage-account> \
  --resource-group <resource-group> \
  --policy @lifecycle-policy.json
```

To update later (e.g. change a retention value or add a node), edit the same
JSON and re-run with `... management-policy update ...`. Inspect the current
policy with:

```bash
az storage account management-policy show \
  --account-name <storage-account> \
  --resource-group <resource-group>
```

> The management policy is **account-wide**: a single policy document contains
> the rules for all nodes. Keep all node rules in one JSON file and re-apply the
> whole document when changing any of them.

## Metrics, dashboard and alerts

On every run (unless `PROM_GTW` is empty) the script POSTs these gauges to the
Pushgateway under `job="linux_backup"`, `instance="<node>"`:

| Metric | Meaning |
| --- | --- |
| `backup_success` | 1 = local archive built & verified, 0 = failure. |
| `backup_all_targets_success` | 1 = archive delivered to **every** target, 0 = a target failed or none configured. |
| `backup_tar_rc` | `tar` exit code. |
| `backup_duration_seconds` | Total run time. |
| `backup_size_bytes` | Archive size. |
| `backup_last_run_timestamp_seconds` | When the last run happened. |
| `backup_last_success_timestamp_seconds` | Last run where the archive built **and** all targets received it (persists across failures). |
| `backup_retention_days` | Configured local retention. |

Per-target gauges are pushed under an extra `target="<name>"` label:
`backup_target_success`, `backup_target_rc` (transfer tool exit code),
`backup_target_duration_seconds`, `backup_target_bytes`,
`backup_target_pruned_files`, and `backup_target_last_success_timestamp_seconds`.

If `PROM_GTW` is empty the run logs an INFO line and still succeeds.

- **Dashboard:** import [`dashboards/linux-backups.json`](dashboards/linux-backups.json)
  in Grafana (Dashboards → New → Import) and pick your Prometheus data source.
- **Alerts:** deploy [`alerts/linux-backups-rules.yaml`](alerts/linux-backups-rules.yaml)
  with your Prometheus rules. `LinuxBackupFailed` fires on a failed archive;
  `LinuxBackupStale` fires when no fully-replicated success has occurred for >25h
  (also catching a job that stopped running); `LinuxBackupTargetFailed` /
  `LinuxBackupTargetStale` fire per target on delivery problems.

## Logs

Each run is tee'd to `"$LOG_DIR/run-<timestamp>.log"` (default
`$BACKUP_DIR/logs`). The **5 most recent** logs are kept; older ones are removed
automatically. To investigate a failure:

```bash
ls -1t /var/backups/linux-backups/logs/
less "$(ls -1t /var/backups/linux-backups/logs/run-*.log | head -1)"
```

## Migrating an existing host to this repo

If a server already runs an ad-hoc `backup.sh` + `env`, convert it before
adopting this repo. Map the old pieces into the two new files:

**Old `env`** → **`/etc/linux-backups/secrets.env`**

- Split the old `SAS_URL` (container URL + token) into:
  - `DEST_URL` — the container URL **without** the `?...` token and without a
    trailing slash, e.g. `https://acct.blob.core.windows.net/backups`.
  - `SAS_TOKEN` — the `?sv=...&sig=...` query string, **including** the leading `?`.
- Add `PROM_GTW` (or leave empty to disable metrics).

**Old `backup.sh`** → **`/etc/linux-backups/backup.conf`**

- The positional paths after `tar -czf <file>` become `INCLUDE_PATHS=( ... )`.
- Each `--exclude=...` becomes an entry in `EXCLUDE_PATHS=( ... )`.
- The old `RETENTION` becomes `RETENTION_DAYS` (local only); pick a separate
  `REMOTE_RETENTION_DAYS` for the lifecycle policy.
- The old backup output directory becomes `BACKUP_DIR`.

For example, a host that previously ran:

```bash
tar --exclude="/mnt/ssd/downloads" -cvzf /home/ubuntu/backups/server-$TODAY.tar.gz \
    /home/ubuntu/.config /mnt/ssd/ \
    "/var/lib/plexmediaserver/.../Preferences.xml"
find /home/ubuntu/backups/ -type f -mtime +30 -name '*.gz' -delete
```

becomes a `backup.conf` with:

```bash
NODE_NAME="srv-1"
BACKUP_DIR="/home/ubuntu/backups"
RETENTION_DAYS=30
REMOTE_RETENTION_DAYS=30
INCLUDE_PATHS=(
  "/home/ubuntu/.config"
  "/mnt/ssd/"
  "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
)
EXCLUDE_PATHS=(
  "/mnt/ssd/downloads"
)
```

Then add the matching lifecycle rule for the `srv-1/` prefix, schedule the new
cron job, and remove the old script/`env`/`purge.sh`.

## Docker Compose backups

`docker-backup.sh` backs up the **named volumes** of your Docker Compose stacks,
one archive per stack, so a restore is per-stack and less error-prone. To keep
databases consistent without any dump tooling it uses **stop-cold-copy**: it runs
`docker compose stop`, tars the stack's volumes, then `docker compose start`.
There is therefore a brief per-stack downtime while the archive is built.

```
discover stateful stacks  ->  for each allowlisted stack:
  docker compose stop  ->  tar volumes + manifest  ->  docker compose start
      ->  verify (gzip -t)  ->  purge local old  ->  azcopy copy  ->  push metrics
```

Each stack archive is uploaded to `<container>/<node>/docker/<stack>/` and
contains a `manifest.json` plus `volumes/<volume-name>/...` for every named
volume.

> The archive is built by reading each volume's mountpoint **directly on the
> host**, so this requires a native Linux Docker engine (where a volume lives at
> `/var/lib/docker/volumes/<name>/_data`). On Docker Desktop (macOS/Windows)
> volumes live inside a VM and are not host-accessible; the run fails loudly
> (`mountpoint not accessible`) rather than producing an incomplete archive.

### Configuration

Create `$CONFIG_DIR/docker-backup.conf` from the template (it reuses
`DEST_URL` / `SAS_TOKEN` / `PROM_GTW` from `secrets.env`):

```bash
sudo cp /opt/linux-backups/conf/docker-backup.example.conf /etc/linux-backups/docker-backup.conf
sudoedit /etc/linux-backups/docker-backup.conf   # set STACKS, retention, STOP_TIMEOUT
```

Only stacks listed in `STACKS` are backed up. `RETENTION_DAYS` controls the
**local** copies; remote retention is enforced by the Azure lifecycle policy on
the `<container>/<node>/docker/` prefix (see below).

### Discovering and reconciling stacks

`docker-backup-init.sh` inspects the running compose landscape and helps you fill
in `docker-backup.conf`. Run it manually (never from cron):

```bash
sudo /opt/linux-backups/docker-backup-init.sh            # interactive
sudo /opt/linux-backups/docker-backup-init.sh --print    # report only, no changes
sudo /opt/linux-backups/docker-backup-init.sh --write    # append missing stacks non-interactively
```

With no config it offers to create one from the discovered stacks. With an
existing config it reports stacks that are **running but unmanaged**,
**configured but gone**, and **bind mounts nothing backs up**, and can append the
missing stacks (additively, after backing your file up to `docker-backup.conf.bak-<ts>`).
Each reported stack lists its named volumes and bind mounts with their **on-disk
size** (`du`) so you can judge what is worth backing up. (A volume shows `?` when
its mountpoint is not host-accessible, e.g. on Docker Desktop.)

### Scheduling

Give the compose backup its own cron entry (it self-updates like `backup.sh`):

```cron
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin

# Back up compose stacks daily at 03:00
0 3 * * * root /opt/linux-backups/docker-backup.sh
```

Test it without stopping anything or uploading:

```bash
sudo DRY_RUN=1 /opt/linux-backups/docker-backup.sh
```

`DRY_RUN=1` only discovers stacks, evaluates bind-mount coverage, and reports —
it does **not** stop stacks, build archives, or upload.

### Unmanaged stacks and bind mounts

`docker-backup.sh` never backs up a stack unless it is on the `STACKS`
allowlist. Instead it **detects and alerts**:

- **Unmanaged stacks** — a running stack that owns named volumes but isn't on the
  allowlist raises `docker_backup_unmanaged_stacks` (alert `DockerBackupUnmanagedStack`).
- **Uncovered bind mounts** — compose stacks often keep state in host bind mounts.
  For every stack the script inspects its bind mounts, filters ephemeral ones
  (`docker.sock`, `/etc/localtime`, …), and checks the rest against the host-path
  backup (`INCLUDE_PATHS` in `backup.conf`). A bind that is neither covered nor
  acknowledged raises `docker_backup_uncovered_bind_mounts` (alert
  `DockerBackupUncoveredBindMount`).

Once you have checked a bind mount and confirmed it is throwaway data, add it to
`BIND_IGNORE` in `docker-backup.conf` to silence the warning. Entries that stop
matching anything are reported as `stale BIND_IGNORE entry` so the list stays honest.

### Metrics

Pushed under `job="docker_backup"`, grouped per stack
(`instance="<node>"`, `stack="<stack>"`):

| Metric | Meaning |
| --- | --- |
| `docker_backup_success` | 1 = stack backup OK, 0 = failure. |
| `docker_backup_size_bytes` | Stack archive size. |
| `docker_backup_volume_count` | Named volumes captured. |
| `docker_backup_stop_seconds` | Per-stack downtime during stop-cold-copy. |
| `docker_backup_duration_seconds` | Total time for the stack. |
| `docker_backup_last_run_timestamp_seconds` | When the stack was last processed. |
| `docker_backup_last_success_timestamp_seconds` | Last successful stack backup (persists across failures). |
| `docker_backup_uncovered_bind_mounts` | Bind mounts nothing backs up. |
| `docker_backup_ignored_bind_mounts` | Bind mounts acknowledged via `BIND_IGNORE`. |
| `docker_backup_managed` | 1 = on the allowlist, 0 = detected-only. |

A node-level group (`instance="<node>"`, no `stack`) carries
`docker_backup_unmanaged_stacks` and `docker_backup_last_run_timestamp_seconds`.

### Restoring a stack

`restore.sh` recreates a stack's volumes from an archive (run as root on the host):

```bash
# Restore all volumes from the archive into (re)created named volumes
sudo /opt/linux-backups/restore.sh /var/backups/linux-backups/docker/srv-1-immich-2026-07-12-03-00.tar.gz

# Overwrite existing non-empty volumes, or restore only some volumes
sudo /opt/linux-backups/restore.sh <archive> --force
sudo /opt/linux-backups/restore.sh <archive> --volume immich_pgdata
```

It reads `manifest.json`, recreates each named volume, extracts its contents,
and prints the `docker compose up -d` step to bring the stack back.

### Remote retention for stacks

Add a lifecycle rule for each node's `docker/` prefix (see
`lifecycle-policy.example.json`, which includes a `srv-1-docker-retention`
example) using the node's `REMOTE_RETENTION_DAYS`.

## Migrating from v0.1.0 to v0.2.0

v0.2.0 adds multiple backup targets and Docker Compose backups. The **host backup
keeps working with no config changes**, but the Prometheus **metrics were
restructured**, so the dashboard, alert rules, and any custom queries must be
updated in lockstep.

### Config — no action required (backward compatible)

- Your existing `secrets.env` with `DEST_URL` / `SAS_TOKEN` keeps working via a
  compatibility shim: when no `targets/*.conf` exist, a single `azure` target is
  synthesised automatically. `backup.conf` is unchanged.
- **Recommended (optional):** migrate to explicit target files so you can add more
  destinations and see per-target metrics:

  ```bash
  sudo mkdir -p /etc/linux-backups/targets
  sudo install -m 600 /opt/linux-backups/conf/targets/azure.example.conf \
      /etc/linux-backups/targets/azure.conf
  # move DEST_URL / SAS_TOKEN from secrets.env into azure.conf, then optionally
  # add /etc/linux-backups/targets/onsite.conf (TYPE=rsync) for a second target.
  ```

  `PROM_GTW` stays in `secrets.env`. Verify each target with
  `sudo backup.sh --check-targets`.

- **Docker Compose backups (opt-in, new):** create
  `/etc/linux-backups/docker-backup.conf` (see [Docker Compose
  backups](#docker-compose-backups)) and add a separate cron entry for
  `docker-backup.sh`. Nothing runs until you configure `STACKS`.

### Metrics — breaking changes (host backup, `job="linux_backup"`)

| v0.1.0 | v0.2.0 | Note |
| --- | --- | --- |
| `backup_azcopy_rc` | `backup_target_rc{target}` | **Renamed + labelled.** The old name is gone. |
| `backup_success` = tar && integrity && upload | `backup_success` = tar && integrity only | **Semantics narrowed.** Delivery moved out. |
| — | `backup_all_targets_success` | New: 1 iff every target received the archive. |
| — | `backup_target_success{target}` | New: per-target delivery. |
| — | `backup_target_{duration_seconds,bytes,pruned_files,last_success_timestamp_seconds}{target}` | New per-target gauges. |
| `backup_last_success_timestamp_seconds` = archive+upload | same name, now = archive + **all** targets | Slightly stricter; unchanged for a single target. |

**Impact:** an old alert on `backup_success == 0` no longer fires on an upload
failure — that is now `backup_target_success == 0` / `backup_all_targets_success == 0`.

### Dashboard & alerts — redeploy together with the scripts

- **Dashboard:** re-import [`dashboards/linux-backups.json`](dashboards/linux-backups.json).
  The "azcopy rc" panel is replaced by an all-targets health column, and new
  per-target and per-stack panels were added.
- **Alerts:** redeploy [`alerts/linux-backups-rules.yaml`](alerts/linux-backups-rules.yaml).
  New rules: `LinuxBackupTargetFailed`, `LinuxBackupTargetStale`,
  `DockerBackupFailed`, `DockerBackupStale`, `DockerBackupUnmanagedStack`,
  `DockerBackupUncoveredBindMount`, `DockerBackupTargetFailed`. `LinuxBackupFailed`
  now reflects an archive failure only; `LinuxBackupStale` reflects
  fully-replicated staleness.

### Upgrade checklist

1. Merge/deploy the new scripts (self-update pulls `lib.sh` automatically).
2. Re-import the Grafana dashboard JSON.
3. Redeploy the Prometheus alert rules (`promtool check rules …` first).
4. Fix any custom queries referencing `backup_azcopy_rc` or relying on the old
   `backup_success` meaning.
5. (Optional) migrate `secrets.env` → `targets/azure.conf`; run
   `backup.sh --check-targets`.
6. (Optional) set up `docker-backup.conf` + cron for Docker Compose backups.

## Requirements


`bash`, `git`, `tar`, `gzip`, `find`, `curl`, and
[`azcopy`](https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-v10)
on each host. GNU `tar` is required (the Docker Compose backup uses
`--transform` / `--append`). The Docker Compose backup additionally needs the
`docker` CLI (with the Compose plugin) and access to the Docker daemon.
