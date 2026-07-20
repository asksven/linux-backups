# Plans

> **Current system:** see [ARCHITECTURE.md](ARCHITECTURE.md). This file retains
> the implemented self-contained Docker backup phases as context for the pending
> correctness-hardening work in Phase 6.

# Plan: Self-contained Docker stack backups (decouple from host FS backup)

> **Status: PHASES 1–6 IMPLEMENTED.** Phases 1–5 reworked the Docker stack
> backup's bind-mount handling and related restore, metrics, alerts, and docs.
> Phase 6 addressed correctness findings from the post-implementation
> architecture review, including a contract test suite under `tests/`.

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
11. **Schema compatibility**: `restore.sh` must support schema-1 archives
  (volumes only) and schema-2 archives. Branch on `manifest.schema`; schema 1
  skips compose/bind restore while retaining the existing volume restore.

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

## Phase 6 — Correctness hardening after implementation review

Phases 1–5 implemented the intended archive format and workflow, but the review
found several paths that can still produce an incomplete archive, report a
failed operation as successful, or restore the wrong filesystem shape. This
phase is required before treating schema-2 archives as reliable DR units.

### Confirmed failure policy

These choices were confirmed by the maintainer on 2026-07-19:

- If `docker compose stop` fails, **abort that stack backup**. Do not build,
  deliver, or report a successful archive from potentially live data. Make a
  best-effort restart before returning failure.
- If archive creation succeeds but `docker compose start` fails, **deliver the
  valid archive but mark the stack run failed** so monitoring reports that the
  service was not recovered.
- Bind-only Compose projects are first-class stateful stacks: **back up managed
  bind-only stacks and alert on unmanaged bind-only stacks**.

### Must fix (red)

18. **Back up and detect bind-only stacks** (`docker-backup.sh`,
    `docker-backup-init.sh`):
    - Remove the `volcount == 0` early return in `backup_stack()`. A managed
      project with compose files and/or captured binds must run the same
      stop/archive/start/deliver flow with an empty `volumes[]` array.
    - Define a stateful project as one with at least one named volume or at least
      one non-ephemeral bind after discovery. Use the same definition for the
      unmanaged detector and reconciler/bootstrap suggestions.
    - Do not auto-manage projects whose only mounts are ephemeral/system binds.
    - Ensure metrics for bind-only stacks report `volume_count=0`, the real bind
      counters/bytes, and normal backup success/target status.

19. **Represent and restore file binds correctly** (`docker-backup.sh`,
    `restore.sh`, manifest schema 2):
    - Add bind source kind metadata, e.g. `kind: "file" | "directory"`, to each
      captured `binds[]` entry. Determine it before writing the manifest.
    - Directory binds keep the current `binds/<id>/...` layout and restore into
      a directory.
    - File binds must restore to the exact source filename, not to a directory
      named after that file. With `--bind-root /restore`, `/etc/app/config.yml`
      must become `/restore/etc/app/config.yml`.
    - Create only the parent directory for a file bind, extract to a temporary
      location if needed, then install/move the file while preserving numeric
      owner and mode. Refuse to replace an incompatible existing path unless
      `--force` is set.
    - Continue accepting existing schema-2 manifests without `kind`: infer file
      versus directory from archive members, or fail with a clear actionable
      message if inference is ambiguous.

20. **Make missing or unreadable inputs fatal to archive success**
    (`docker-backup.sh`, `lib.sh`):
    - Resolve and validate all named-volume mountpoints, compose files, and
      capture-selected bind sources before stopping the stack.
    - A labelled compose config file that is missing/unreadable is a hard
      failure; do not silently omit it from `COMPOSE_FILE_ENTRIES`.
    - A capture-selected bind that disappears, changes kind, or becomes
      unreadable before/during tar is a hard archive failure. Never retain it in
      `manifest.binds[]` while omitting its data.
    - Fix the bind tar loop so every branch assigns its own return code. Do not
      reuse a stale `_rc` after the missing-source branch.
    - On any tar/input failure, remove the incomplete archive, restart the stack,
      skip target delivery, and push failure metrics.

21. **Enforce stop/start state transitions and success semantics**
    (`docker-backup.sh`):
    - Track explicit per-stack state such as `stop_ok`, `archive_ok`, and
      `restart_ok`; do not derive overall success from tar/gzip alone.
    - If stop fails, do not call `build_stack_archive` or target delivery. Attempt
      a best-effort start, then push `docker_backup_success=0`.
    - Install a per-stack cleanup/restart guard immediately after a successful
      stop so shell errors, signals, or archive failures cannot leave the stack
      stopped. Clear the guard only after a successful start attempt has run.
    - If restart fails after a valid archive was built, still run integrity
      verification and target delivery, but push `docker_backup_success=0`.
      Target metrics continue to describe delivery independently.
    - Log stop, archive, restart, and delivery outcomes separately. The process
      should finish non-zero if any managed stack failed, while still processing
      later stacks where safe.

22. **Restore the captured Compose invocation, not only basenames**
    (`restore.sh`, manifest writer):
    - Parse `compose.captured_files[]` with the structured JSON parser and map
      every original config path to its archived/restored filename, including
      basename-collision prefixes.
    - Print a runnable command containing the required `-f <restored-file>`
      arguments in the original `compose.config_files[]` order. Do not assume
      plain `docker compose up -d` loads collision-renamed or non-default files.
    - Fail compose restore if a manifest-declared captured file is absent from
      the archive. Do not claim a full restore after partial extraction.
    - Keep the documented limitation that `env_file:` files are not discovered,
      but change broad “everything needed” claims to state that only labelled
      Compose config files plus top-level `.env` are captured.

### Recommended fixes (yellow)

23. **Make restore overwrite behavior explicit and fail-safe** (`restore.sh`):
    - Without `--force`, encountering any non-empty target volume, existing bind
      target, missing selected volume, or extraction failure must make the
      command exit non-zero; collect errors if continuing to inspect later items.
    - Define `--force` as replacement, not merge: clear the target volume or bind
      directory before extraction so files removed since the backup do not
      survive the restore. Never clear outside the exact validated target path.
    - Validate archive member paths before extraction and reject absolute paths
      or `..` traversal entries.

24. **Use one bind-classification implementation everywhere** (`lib.sh`,
    `docker-backup.sh`, `docker-backup-init.sh`):
    - Extract the precedence decision into a shared helper used by runtime and
      reconciler reporting.
    - The shared order must remain: ephemeral skip → network-fs exclusion unless
      `BIND_INCLUDE_NETFS` matches → `BIND_IGNORE` → capture.
    - `docker-backup-init.sh` must honor `BIND_INCLUDE_NETFS` and show a distinct
      force-capture verdict. Its suggestions must use the same decision.

25. **Correct bind metrics and duplicate-source handling** (`docker-backup.sh`,
    manifest schema 2):
    - Include force-captured network binds in `BIND_BYTES`.
    - Archive identical source data once even when several containers or
      destinations mount it. Preserve all destination/RO relationships in the
      manifest, either as a `mounts[]` list on one source record or another
      explicit normalized structure.
    - Define `docker_backup_bind_count` as unique captured sources and document
      that definition. Excluded/network counters should follow the same unique
      source rule to avoid container-count-dependent metrics.

26. **Add executable archive/restore contract tests**:
    - Add a test harness suitable for Bash (Bats is acceptable) with Docker
      commands stubbed where a daemon is unnecessary.
    - Cover schema-2 manifest validity, empty volumes, bind-only stacks, empty
      directories, file binds, duplicate sources, compose basename collisions,
      missing compose/bind sources, and path names containing spaces.
    - Cover stop failure, archive failure after stop, restart failure with valid
      delivery, and the restart guard.
    - Build a synthetic archive and perform a round-trip restore under a temp
      root. Assert exact file/directory shape, contents, modes, config-file order,
      `--bind-root`, `--project-dir`, `--no-binds`, `--no-compose`, and
      replacement semantics with/without `--force`.
    - Retain a schema-1 fixture because the implementation and confirmed
      decision support schema-1 restore.

### Nice to have (green)

27. **Clean stale comments and plan state**:
    - Update the `docker-backup.sh` header flow to mention compose files and bind
      data rather than named volumes only.
    - Update the `stack_bind_mounts` comment to say writable and read-only binds.
    - Keep the plan status current as Phase 6 items are completed.

### Phase 6 acceptance criteria

1. A managed bind-only test stack produces and delivers a valid schema-2 archive;
   an equivalent unmanaged project increments `docker_backup_unmanaged_stacks`.
2. Directory and single-file binds round-trip to exactly their original shape,
   both at original paths and under `--bind-root`.
3. Missing compose files, missing binds, stop failure, and tar failure cannot
   produce or deliver a successful archive.
4. Restart failure still delivers a verified archive but reports stack/run
   failure and exits non-zero.
5. A forced restore replaces prior data; a non-forced conflicting restore exits
   non-zero without changing the conflicting target.
6. Collision-renamed Compose files restore with a printed `docker compose -f …`
   command that preserves the original config-file order.
7. Runtime and reconciler produce identical verdicts for ephemeral, ignored,
   network-excluded, and force-included binds.
8. `shellcheck` passes, all new contract tests pass, manifest JSON validates,
   `promtool check rules alerts/linux-backups-rules.yaml` passes, and the
   dashboard JSON parses.

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
