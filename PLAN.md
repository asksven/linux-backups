# Plans

> **Current system:** see [ARCHITECTURE.md](ARCHITECTURE.md). This file tracks
> **pending work only**. The already-implemented host FS backup, backup targets,
> and Docker stack backup are documented there; the plans that delivered them
> have been moved out of this file.

# Plan: Self-contained Docker stack backups (decouple from host FS backup)

> **Status: NOT STARTED.** Reworks the current Docker stack backup's bind-mount
> handling (documented in [ARCHITECTURE.md](ARCHITECTURE.md)) and adjusts the
> bind-related metrics/alerts it introduced. Everything else about that subsystem
> (stop-cold-copy, discovery, `STACKS` allowlist, unmanaged detection, per-stack
> archive, targets) is kept.

## Problem (current, flawed architecture)

- `docker-backup.sh` backs up **named volumes only**. Bind-mount state is
  *delegated* to the host FS backup: `load_config()` sources `backup.conf`,
  `analyze_stack_binds()` → `path_is_covered()` (in `lib.sh`) tests each bind
  source against `INCLUDE_PATHS` and only **warns**
  (`docker_backup_uncovered_bind_mounts`) when uncovered — it never backs the
  data up.
- The per-stack archive is **not disaster-recoverable on its own**:
  `manifest.json` records the compose `working_dir` + `config_files` **paths**
  only — no `.env`, no `docker-compose.yml` / `docker-compose.override.yml`
  contents, no bind data.
- `restore.sh` restores volumes only, then prints `cd <working_dir> &&
  docker compose up -d` — which fails on a wiped host because the project dir is
  gone (it was only backed up if `working_dir` happened to be in the host
  backup's `INCLUDE_PATHS`).
- Net: “docker backup” == named-volume snapshot + a linter nagging you to push
  everything else into the host backup. No separation of concerns; the two
  subsystems are advertised as independent but are not.

## Goal

Make `docker-backup.sh` a **fully self-contained, auto-detecting** stack backup.
For each managed stack it captures EVERYTHING needed to rebuild the stack on a
wiped machine:

- named volumes (existing stop-cold-copy),
- **local bind-mount data** (NEW),
- **compose project files**: `docker-compose.yml`, `docker-compose.override.yml`,
  referenced config files, and `.env` (NEW),
- extended **metadata** for restore (manifest schema 2).

It no longer sources `backup.conf` and never references `INCLUDE_PATHS`. The host
FS backup (`backup.sh`) and the Docker backup become **independent** — run either
or both. `restore.sh` rehydrates a stack from one archive on a fresh host.

## Decisions (final)

- Docker backup **owns all stack data**; it never reads `INCLUDE_PATHS` /
  `backup.conf`. (Rationale: the docker backup auto-detects what to back up; the
  host backup relies on the admin declaring paths — mixing the two is the flaw.)
- The per-stack archive is a **complete DR unit**.
- **Duplication accepted** when both backups run; the docker archive is
  authoritative for stack DR.
- **Intelligent bind classification by filesystem type**: network/remote
  filesystems are **auto-excluded**. Validated on host `media-1`: SMB media
  shares report `cifs` and are correctly skipped, while `*arr`/Plex config on
  local `ext4` is captured.
- `BIND_IGNORE` is **repurposed** to exclude transient **LOCAL** bind data
  (caches, download scratch) from the archive.
- `.env` / secrets ARE captured into the docker archive (same trust model as the
  host backup already capturing `CONFIG_DIR/secrets.env`).

## Archive layout v2 (manifest schema 2)

```
<node>-<stack>-<ts>.tar.gz
  manifest.json          # schema 2
  compose/               # NEW: captured compose files + override + .env
    docker-compose.yml
    docker-compose.override.yml
    .env
  volumes/<vol>/...      # existing: named-volume data (stop-cold-copy)
  binds/<id>/...         # NEW: captured LOCAL bind-mount source data (id = 0,1,2…)
```

`binds/<id>` uses a numeric index (not the path) to avoid collisions and unsafe
characters; the index → source mapping lives in the manifest. `compose/` files
are placed by basename; on a basename collision, prefix with the index and
record the real mapping in `captured_files[]`.

### manifest.json (schema 2)

```json
{
  "schema": 2,
  "node": "media-1",
  "stack": "sonarr",
  "timestamp": "2026-07-19T03:00:00Z",
  "epoch": 1784...,
  "compose": {
    "working_dir": "/opt/stacks/sonarr",
    "config_files": ["/opt/stacks/sonarr/docker-compose.yml"],
    "captured_files": [
      {"path": "docker-compose.yml", "source": "/opt/stacks/sonarr/docker-compose.yml"},
      {"path": ".env", "source": "/opt/stacks/sonarr/.env"}
    ]
  },
  "volumes": [
    {"name": "<vol>", "mountpoint": "/var/lib/docker/volumes/<vol>/_data", "archive_path": "volumes/<vol>"}
  ],
  "binds": [
    {"source": "/mnt/ssd/sonarr", "destination": "/config", "ro": false, "fstype": "ext4", "archive_path": "binds/0"}
  ],
  "excluded_binds": [
    {"source": "/mnt/tv/TV", "destination": "/tv", "fstype": "cifs", "reason": "network-fs"},
    {"source": "/mnt/ssd/downloads/complete", "destination": "/downloads", "fstype": "ext4", "reason": "bind-ignore"}
  ]
}
```

`excluded_binds[]` is important for DR awareness: on restore you can see what was
deliberately NOT captured (e.g. “remount the SMB media share at `/mnt/tv`”).

## Bind classification & selection (the core change)

Evaluate every writable **and read-only** non-ephemeral bind source; first match
wins:

1. **Ephemeral/system** (existing `_is_ephemeral_bind`): `docker.sock`,
   `/etc/localtime`, `/etc/timezone`, `/etc/hosts`, `/etc/resolv.conf`, `/proc`,
   `/sys`, `/dev`, `/run`, plus compose config-file sources → SKIP (not counted).
2. **Network/remote filesystem** (NEW): `_bind_fstype <src>` via
   `findmnt -no FSTYPE --target <src>` (fallback `stat -f -c %T <src>`); if
   `_is_network_fs` matches `cifs|smb2|smb3|nfs|nfs4|fuse.sshfs|fuse.rclone|glusterfs|ceph|tmpfs`
   → SKIP, unless `<src>` matches `BIND_INCLUDE_NETFS`. Log each skip; count
   `docker_backup_network_binds`. Detection is fstype-based, so it catches host
   SMB/NFS mounts bind-mounted into containers **mounted outside compose**.
3. **`BIND_INCLUDE_NETFS`** allowlist (NEW, rare): force-capture a specific
   network path despite rule 2.
4. **`BIND_IGNORE`** (repurposed): manual exclude of transient LOCAL data
   (caches, download scratch). Same matching as today (exact / subtree trailing
   `/` / glob / optional `stack:` qualifier). Stale-entry WARNING retained. Count
   `docker_backup_excluded_binds`.
5. Otherwise → **CAPTURE** into `binds/<id>/`.

### Validated on `media-1` (sonarr / radarr / plex)

| bind source | fstype | verdict |
|---|---|---|
| `/mnt/tv/TV`, `/mnt/movies/MOVIES`, `/mnt/movies/Movies` | `cifs` | SKIP (network-fs) |
| `/mnt/ssd/sonarr`, `/mnt/ssd/radarr/config`, `/mnt/ssd/plex` | `ext4` | CAPTURE (holds *arr SQLite DB → cold copy matters) |
| `/etc/localtime` | ext4 | SKIP (ephemeral filter, before fstype check) |
| `/mnt/ssd/downloads/complete` | `ext4` | CAPTURE by default; **recommend `BIND_IGNORE`** (transient, large, shared by sonarr+radarr → duplicated) |

No new fstypes needed — `cifs` is already in the network set.

## Phase 1 — Decouple config & discovery (`docker-backup.sh`, `lib.sh`)

1. `load_config()`: **stop sourcing `backup.conf`**; drop `HAVE_COVERAGE`.
   `NODE_NAME` defaults to `hostname -s`; `DOCKER_BACKUP_DIR` gets a standalone
   default (`/var/backups/linux-backups/docker`) not derived from `BACKUP_DIR`.
2. Remove the coverage machinery: delete `analyze_stack_binds()`’s coverage logic
   and retire `path_is_covered()` / `_path_under()` in `lib.sh` (no longer used
   anywhere — confirm with a repo grep).
3. `lib.sh` `stack_bind_mounts`: **also return read-only** non-ephemeral binds
   (config files needed for DR) and expose the `ro` flag in its output
   (`<source>\t<destination>\t<ro>`).
4. NEW `lib.sh` helpers: `_bind_fstype <path>` and `_is_network_fs <fstype>`
   (see rule 2). `_is_network_fs` returns 0 for the network/remote/tmpfs set.
5. New selection function (replaces `analyze_stack_binds`), e.g.
   `classify_stack_binds <stack>` → populates arrays
   `CAPTURE_BINDS`, `EXCLUDED_BINDS` (with reason + fstype) using the precedence
   above; sets counters `BIND_COUNT`, `EXCLUDED_BINDS_COUNT`, `NETWORK_BINDS_COUNT`.

## Phase 2 — Capture everything into the archive (`docker-backup.sh`, `lib.sh`)

6. NEW `lib.sh` `stack_compose_files <stack>`: from the compose labels
   (`working_dir`, `config_files`) list the compose file paths; add
   `working_dir/.env` if present. (Limitation: `env_file:` directives and files
   outside `working_dir` are not parsed — documented.)
7. `build_stack_archive`: during the **cold window** (stack stopped), append
   (a) `compose/` files, (b) `binds/<id>/` for each `CAPTURE_BINDS` source
   (handle single-file vs directory sources; use `--numeric-owner` as for
   volumes), in addition to the existing `volumes/`. Keep the uncompressed
   intermediate `.tar` + `--append` + final `gzip` approach.
8. `write_manifest`: emit **schema 2** with `compose.captured_files[]`,
   `binds[]{source,dest,ro,fstype,archive_path}`, and `excluded_binds[]{source,
   dest,fstype,reason}`.
9. Metrics (`push_stack_metrics` + callers): **remove**
   `docker_backup_uncovered_bind_mounts` and `docker_backup_ignored_bind_mounts`;
   **add** `docker_backup_bind_count`, `docker_backup_bind_bytes`,
   `docker_backup_excluded_binds`, `docker_backup_network_binds`. Update the
   `push_stack_metrics` argument list accordingly (it currently ends with
   `uncovered ignored`).

## Phase 3 — Full DR restore (`restore.sh`)

10. Extend `restore.sh` to rehydrate a stack end-to-end:
    - restore named volumes (existing behavior),
    - restore binds: for each `binds[]` entry recreate the source path and extract
      `binds/<id>` into it (`--numeric-owner`); default to the original absolute
      source, with `--bind-root <dir>` to remap all bind sources under a new root,
    - restore compose files: write `compose/` (incl. `.env` and override) to a
      target dir — default `manifest.compose.working_dir`, override with
      `--project-dir <dir>`,
    - then print (and optionally run) `docker compose up -d`.
    - New flags: `--project-dir`, `--bind-root`, `--no-binds`, `--no-compose`
      (plus existing `--force`, `--volume`).
    - Print `excluded_binds[]` as a reminder of external data to re-provision
      (e.g. remount SMB shares) before `up`.
11. **Schema compatibility**: `restore.sh` must still read schema-1 archives
    (volumes only). Branch on `manifest.schema`.

## Phase 4 — Reconciler & detectors (`docker-backup-init.sh`)

12. Drop the `INCLUDE_PATHS` coverage reporting (`load_coverage`, coverage status
    in `report_stack_binds`). Instead show, per bind, its **fstype** and the
    verdict it would get (`capture` / `netfs-excluded` / `ephemeral` /
    `bind-ignore`), plus on-disk size.
13. Flag likely-transient LOCAL binds as `BIND_IGNORE` candidates — e.g.
    download/scratch dirs and binds shared across multiple stacks (like
    `/mnt/ssd/downloads/complete`). Keep `STACKS` bootstrap/reconcile logic.
14. Remove the uncovered-bind detector output; keep unmanaged-stack detection.

## Phase 5 — Config template, alerts, docs

15. `conf/docker-backup.example.conf`: rewrite the `BIND_IGNORE` section as
    “exclude transient LOCAL bind data from the archive” (remove all host-backup
    coverage language); ship a commented download/scratch example. Add a
    commented `BIND_INCLUDE_NETFS=()` section documenting the netfs escape hatch,
    and a short note that SMB/NFS binds are auto-excluded.
16. `alerts/linux-backups-rules.yaml`: **remove** `DockerBackupUncoveredBindMount`
    (the `docker_backup_uncovered_bind_mounts` alert). Keep `DockerBackupFailed`,
    `DockerBackupStale`, `DockerBackupUnmanagedStack`, and the target alerts.
17. `README.md`: rewrite the “Docker Compose backups” section — self-contained
    archives, subsystem independence, layout v2, network-fs auto-exclusion,
    repurposed `BIND_IGNORE`, and the full DR restore flow. `dashboards/*.json`:
    replace panels referencing the removed bind metrics with the new ones.
    `ARCHITECTURE.md`: update the "Docker stack backup" and metrics/alerts
    sections to describe the self-contained bind capture and remove the
    "being reworked" notes once implemented.

## Migration notes (existing deployments)

- `BIND_IGNORE` **semantics flip**: old meaning “bind is transient, don’t warn
  (host backup covers it)” → new meaning “exclude this LOCAL bind from the docker
  archive”. In practice entries carry over (transient ⇒ don’t back up), but the
  README must call this out.
- After upgrade, **bind data now lands in the docker archive**. Admins who were
  relying on `INCLUDE_PATHS` to cover container bind mounts can remove those
  paths from the host `backup.conf` (optional; duplication is otherwise
  accepted).
- No archive-format migration required: schema-1 archives remain restorable.

## Verification

1. `shellcheck lib.sh backup.sh docker-backup.sh docker-backup-init.sh restore.sh`.
2. `DRY_RUN=1 docker-backup.sh` on `media-1`: lists per stack the CAPTURE binds,
   netfs-excluded binds (the `cifs` media shares), and the compose files that
   would be captured — no stop/tar/upload.
3. Real run against a test stack with a local bind (e.g. sonarr `/config`) and an
   SMB bind: archive contains `compose/`, `binds/`, `volumes/`, and a schema-2
   `manifest.json`; the SMB path appears under `excluded_binds` (reason
   `network-fs`), never under `binds/`.
4. Run `docker-backup.sh` with **no `backup.conf` present** → still produces a
   complete archive (proves the decoupling).
5. `restore.sh` on a clean host/dir: volumes recreated, binds restored to their
   sources, `compose/` written to `--project-dir`, `docker compose up -d` brings
   the stack up; `--bind-root` remap works; a schema-1 archive still restores.
6. Confirm removed metrics are gone and new ones present; `promtool check rules
   alerts/linux-backups-rules.yaml`; import the updated dashboard.

## Confirmed decisions (settled 2026-07-19)

All five were confirmed by the maintainer — implement exactly as stated:

1. **Read-only binds** — **CAPTURE** non-ephemeral read-only binds (usually small
   host config files needed for DR).
2. **Network-fs auto-exclusion** — **ON** by default, with the
   `BIND_INCLUDE_NETFS` allowlist as the escape hatch.
3. **`restore.sh` schema compatibility** — **SUPPORT both** schema 1 (volumes
   only) and schema 2.
4. **Template `BIND_IGNORE` example** — **SHIP** a commented download/scratch
   example (documentation only, no behavior change).
5. **`.env`/secrets in the archive** — **INCLUDE** (same trust model as the host
   backup capturing `secrets.env`); accepted for shared/off-site targets.

## Scope

- **Included**: decoupling `docker-backup.sh` from `backup.conf`/`INCLUDE_PATHS`;
  fstype-based network bind auto-exclusion (`_bind_fstype` / `_is_network_fs`);
  read-only bind capture; compose-file + `.env` capture; bind-data capture;
  manifest schema 2 (`binds[]`, `excluded_binds[]`, `captured_files[]`);
  repurposed `BIND_IGNORE` + new `BIND_INCLUDE_NETFS`; restructured bind metrics;
  full DR `restore.sh`; reconciler rework; template/alerts/README/dashboard/ARCHITECTURE
  updates.
- **Excluded**: backing up network-fs bind data (media libraries — deliberately
  skipped); live DB dumps (still stop-cold-copy); volumes on non-`local` drivers;
  parsing `env_file:` / compose files outside `working_dir`; automatic removal of
  now-redundant `INCLUDE_PATHS` entries from host configs.
