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

4. **Schedule it** via cron (self-update happens automatically on each run):

   ```cron
   # /etc/cron.d/linux-backups — daily at 02:30
   30 2 * * * root /opt/linux-backups/backup.sh >> /var/log/linux-backups-cron.log 2>&1
   ```

### Testing a branch

To try changes from a non-default branch on a single host, pass `--branch`:

```bash
sudo /opt/linux-backups/backup.sh --branch my-test-branch
```

The script hard-resets its checkout to `origin/<branch>` before running. If git
is unreachable (offline), it logs a warning and continues with the current local
version — a backup is never skipped because of a failed update.

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
| `backup_success` | 1 = overall success, 0 = failure. |
| `backup_tar_rc` | `tar` exit code. |
| `backup_azcopy_rc` | `azcopy` exit code. |
| `backup_duration_seconds` | Total run time. |
| `backup_size_bytes` | Archive size. |
| `backup_last_run_timestamp_seconds` | When the last run happened. |
| `backup_last_success_timestamp_seconds` | When the last **successful** run happened (persists across failures). |
| `backup_retention_days` | Configured local retention. |

If `PROM_GTW` is empty the run logs an INFO line and still succeeds.

- **Dashboard:** import [`dashboards/linux-backups.json`](dashboards/linux-backups.json)
  in Grafana (Dashboards → New → Import) and pick your Prometheus data source.
- **Alerts:** deploy [`alerts/linux-backups-rules.yaml`](alerts/linux-backups-rules.yaml)
  with your Prometheus rules. `LinuxBackupFailed` fires on a failed run;
  `LinuxBackupStale` fires when no success has occurred for >25h (also catching a
  job that stopped running).

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

## Requirements

`bash`, `git`, `tar`, `gzip`, `find`, `curl`, and
[`azcopy`](https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-v10)
on each host.
