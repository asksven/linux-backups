# Plans

> **Current system:** see [ARCHITECTURE.md](ARCHITECTURE.md). This file retains
> the implemented self-contained Docker backup phases as context for the
> outstanding work in [Phase 7](#phase-7--docker-compose-mvp-local-only--optional-stop--config-tooling).

# Plan: Self-contained Docker stack backups (decouple from host FS backup)

> **Status: PHASES 1–6 IMPLEMENTED AND VERIFIED** (code-checked 2026-09-19).
> Phases 1–5 reworked the Docker stack backup's bind-mount handling and related
> restore, metrics, alerts, and docs. Phase 6 addressed correctness findings from
> the post-implementation architecture review, including a contract test suite
> under `tests/`. **Phase 7 (below) is the remaining work** for the
> docker-compose MVP.

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
found several paths that could still produce an incomplete archive, report a
failed operation as successful, or restore the wrong filesystem shape. All of it
is now implemented; this section is retained as the behavioural contract for
schema-2 archives as reliable DR units.

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

### Findings — all implemented (code-verified 2026-09-19)

The detailed findings have been collapsed now that each is in the codebase. What
they changed, with the landing site for future reference:

| # | Finding | Landed as |
|---|---|---|
| 18 | Back up and detect bind-only stacks | `volcount == 0` early return dropped from `backup_stack()`; `stack_is_stateful()` (volume **or** non-ephemeral bind) shared by the runtime, the unmanaged detector and the reconciler |
| 19 | Represent and restore file binds correctly | `kind: file\|directory` per `binds[]` entry via `_bind_kind()`; `restore.sh` `_infer_bind_kind()` covers pre-`kind` manifests and errors clearly when ambiguous |
| 20 | Missing/unreadable inputs fatal | `validate_stack_inputs()` runs before the stop; the bind tar loop assigns `_rc` per branch and folds it into `TAR_RC` |
| 21 | Stop/start state transitions | explicit `stop_ok` / `archive_ok` / `restart_ok`; `RESTART_GUARD_STACK` EXIT-trap guard armed only after a successful stop |
| 22 | Restore the captured Compose invocation | `manifest_captured_files()` maps every `config_files[]` entry, aborts on mismatch, and emits `-f` args in the original order |
| 23 | Fail-safe restore overwrite | `_assert_safe_members()` rejects absolute and `..` members; `--force` clears the target first (replace, not merge) |
| 24 | One bind-classification implementation | `bind_capture_verdict()` in `lib.sh`, called by both the runtime and `docker-backup-init.sh` |
| 25 | Bind metrics and duplicate sources | `network-forced` binds counted into `BIND_BYTES`; unique sources archived once with a `mounts[]` array; README documents the unique-source definition |
| 26 | Contract tests | five files under `tests/`, including round-trip restore and a schema-1 fixture |
| 27 | Stale comments and plan state | `docker-backup.sh` header flow and the `stack_bind_mounts` comment updated (one stale `azcopy copy` mention remains — see Phase 7 item 50) |

### Phase 6 behaviour contracts (keep as regression guard)

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

---

# Phase 7 — docker-compose MVP: local-only, optional stop, config tooling

> **Status: IMPLEMENTED (7A–7D complete, 2026-09-20).** Scoped 2026-09-19
> against the four MVP criteria below. All items 28–50 landed: `LOCAL_ONLY`,
> `NO_STOP_STACKS` + `consistency.stopped`, `docker-backup-init.sh --check` and
> combined `STACKS`/`BIND_IGNORE`/`NO_STOP_STACKS` auto-append, the dashboard
> panel, and tests (`test_local_only.sh`, `test_stop_policy.sh`,
> `test_init_check.sh`, plus extensions to `test_manifest_and_archive.sh` and
> `test_restore_roundtrip.sh`). A real bug was found and fixed during test
> authoring: `stack_stop_policy()` originally returned its verdict via `echo`
> for command-substitution capture, which silently discarded its
> `NO_STOP_STACKS_HITS` side effect in the forked subshell — fixed to set a
> `STOP_POLICY` global instead (same pattern as `bind_capture_verdict`).

## MVP criteria and current state

| # | Criterion | State |
|---|---|---|
| 1 | Docker backups are self-contained; no reliance on the host FS backup | **Done** (Phases 1–6) |
| 2 | Each run produces local files; no cloud/NAS sync required | **~90%** — the tarball is always written to `DOCKER_BACKUP_DIR` and pruned by `RETENTION_DAYS`, the pushgateway no-ops on an empty `PROM_GTW`, and there is no `azcopy`/`rsync` preflight. But `send_stack_to_targets()` logs `ERROR "no targets configured"` every run and sets `STACK_ALL_TARGETS_OK=0`. `docker_backup_success` is unaffected (it tracks archive/overall success), so no alert fires — it is log noise plus a misleading dashboard value. There is no way to declare "local only" as intent. |
| 3 | Per-stack choice to stop or not stop the stack around the backup | **Missing** — the stop is unconditional in `backup_stack()`; only a global `STOP_TIMEOUT` exists; `STACKS` is a plain name array with no per-entry qualifiers |
| 4 | Tooling to create the initial config and suggest additions for new stacks | **~70%** — `docker-backup-init.sh` bootstraps from the template and additively appends `STACKS+=( … )`, and reports per-bind fstype/verdict/size. But `BIND_IGNORE` suggestions are print-only, there is no non-interactive drift check for cron/CI, and it knows nothing about a stop policy |

## Decisions (confirmed 2026-09-19)

1. **Stop policy syntax** — a separate `NO_STOP_STACKS=( "immich" )` array.
   Keeps `STACKS` a plain name list, is backwards compatible, and is trivial for
   the init tooling to append to. (Rejected: `"immich:hot"` qualifiers inside
   `STACKS`, which would need parsing at every read site; and a
   `STACK_STOP[immich]=false` associative array, which is more verbose.)
2. **Local-only** — an explicit `LOCAL_ONLY=true` flag rather than silently
   downgrading the zero-targets `ERROR`, so a genuinely broken target setup is
   still detected on hosts that *do* expect delivery.
3. **Init tooling** — `--write`/`--yes` appends `STACKS`, `BIND_IGNORE` **and**
   `NO_STOP_STACKS` suggestions, not just `STACKS`.
4. **Drift detection** — add a `--check` mode that exits non-zero on drift, for
   cron/systemd-timer/CI, alongside the existing `DockerBackupUnmanagedStack`
   alert.
5. **Manifest** — the stop policy is recorded as an *additive optional* field.
   **No schema bump**: schema stays 2 so schema-1 and older schema-2 archives
   keep restoring unchanged.

## Phase 7A — Local-only operation

Independent of 7B; the two can be implemented in parallel.

28. `conf/docker-backup.example.conf`: add a documented `LOCAL_ONLY=false` near
    `DOCKER_BACKUP_DIR` / `RETENTION_DAYS`. Explain that archives then stay on
    this host only, retention is `RETENTION_DAYS`, and neither `conf/targets/`
    nor `secrets.env` is required.
29. `docker-backup.sh` `load_config()`: default `LOCAL_ONLY="${LOCAL_ONLY:-false}"`.
30. `docker-backup.sh` `backup_stack()` delivery block: when `LOCAL_ONLY` is
    true, skip `send_stack_to_targets` entirely, log INFO
    `"local-only mode; archive retained at <path>"`, and set
    `STACK_TARGETS_TOTAL=0`, `STACK_TARGETS_OK=0`, **`STACK_ALL_TARGETS_OK=1`**
    so dashboards do not show a phantom delivery failure. Leave the existing
    zero-targets `ERROR` branch in `send_stack_to_targets()` untouched for
    non-local-only runs.
31. `--check-targets`: print `"local-only mode; no targets to check"` and exit 0
    instead of reporting the absence of targets as a problem.
32. Docs: `README.md` ("Docker Compose backups") and `ARCHITECTURE.md` — document
    `LOCAL_ONLY` as the supported MVP mode, and state plainly that DR then
    depends on this host's disk alone.

## Phase 7B — Per-stack stop policy

Item 34 blocks 35–39.

33. `conf/docker-backup.example.conf`: add a commented `NO_STOP_STACKS=()` block.
    Document it as "back up these stacks **hot** (no downtime) — only safe when
    the stack cannot write inconsistent state while tar runs: no embedded
    database, no SQLite/WAL, no long-running writers". State that the default
    remains stop-cold-copy.
34. `lib.sh`: new `stack_stop_policy <stack>` printing `stop` or `no-stop`.
    Match `NO_STOP_STACKS` entries by exact name or glob, reusing the matching
    style of `bind_ignored()` / `bind_include_netfs()`, including the same
    optional hit-tracking so a stale entry can be warned about (mirror
    `warn_stale_bind_ignore()` in `docker-backup.sh`).
35. `docker-backup.sh` `backup_stack()`: introduce an explicit `stopped` flag,
    distinct from `stop_ok`, and resolve the policy after `validate_stack_inputs`
    (which stays unconditional).
    - `no-stop`: skip `_compose_action stop`, do **not** arm the restart guard
      (`RESTART_GUARD_STACK` stays empty), do **not** call
      `_compose_action start`; set `stop_ok=1`, `restart_ok=1`, `down=0`; log
      INFO `"hot backup (stack left running)"`.
    - `stop`: unchanged path.
    - Note: `_compose_action start` currently runs *unconditionally*, even when
      the stop failed. Gate it on `stopped`.
    - `overall_ok` still requires `archive_ok`.
36. Metrics: add `docker_backup_stack_stopped` (1/0) to `push_stack_metrics()`
    and every call site — the two in `backup_stack()` plus the dry-run branch in
    the `STACKS` loop. `docker_backup_stop_seconds` stays 0 for hot stacks.
37. `write_manifest()`: emit an additive optional
    `"consistency": {"stopped": true|false}`. Schema stays **2**; `restore.sh`
    must tolerate its absence in older archives.
38. `restore.sh`: read `consistency.stopped` and print a prominent warning when
    it is false — the archive is crash-consistent only. No other behaviour change.
39. `dashboards/linux-backups.json`: a stat panel on
    `docker_backup_stack_stopped` to distinguish hot from cold stacks. No new
    alert rule.

## Phase 7C — Config tooling

Depends on item 34 for the shared policy helper.

40. `docker-backup-init.sh`: new `--check` mode. Non-interactive, writes nothing,
    prints drift, and **exits 1** when a running stateful project is missing from
    `STACKS` or a configured stack no longer exists; exits 0 when in sync. Reuse
    the existing `discover_compose_projects()` / `stack_is_stateful()` comparison.
41. Generalise `append_stacks()` into
    `append_entries <conf> <array-name> <values…>` so one dated comment block can
    carry `STACKS+=( … )`, `BIND_IGNORE+=( … )` and `NO_STOP_STACKS+=( … )`.
    `apply_append()` keeps the `.bak-<ts>` backup; `create_conf()` keeps working
    from the template.
42. Wire `suggest_bind_ignore()` output into the writer so `--write` / `--yes`
    actually appends `BIND_IGNORE` entries (today they are printed only).
43. New `suggest_stop_policy()`: per stack, report the effective policy via
    `stack_stop_policy()`, and propose `NO_STOP_STACKS` candidates
    **conservatively** — only when no database signature is found. Inspect
    `.Config.Image` of the stack's containers for
    `postgres|mysql|mariadb|mongo|redis|influx|elastic`, and scan captured bind
    and volume roots for `*.sqlite*`, `*.db`, and WAL files. Anything matching →
    recommend keeping the stop. Print the reasoning per stack; never append
    without `--write` or explicit confirmation.
44. Ship a cron / systemd-timer sample for `docker-backup-init.sh --check`
    (README section plus a commented unit or crontab snippet), noting that init
    itself stays manual-only for writes.

## Phase 7D — Tests and docs

Depends on 7A–7C.

45. `tests/test_stop_policy.sh` (new): a stack in `NO_STOP_STACKS` makes no
    stop/start calls (assert via the docker stub in `tests/stub_lib.sh`), never
    arms the restart guard, reports downtime 0 and
    `docker_backup_stack_stopped=0`, writes `consistency.stopped=false` into the
    manifest, and still builds and delivers the archive. Cover the cold inverse
    and a stale-`NO_STOP_STACKS`-entry warning.
46. `tests/test_local_only.sh` (new): `LOCAL_ONLY=true` → `send_stack_to_targets`
    not called, no ERROR logged, `STACK_ALL_TARGETS_OK=1`, tarball present in
    `DOCKER_BACKUP_DIR`. `LOCAL_ONLY=false` with zero targets → the ERROR is
    preserved.
47. Extend `tests/test_manifest_and_archive.sh` for the `consistency` field, and
    `tests/test_restore_roundtrip.sh` for the hot-archive warning plus a fixture
    that lacks `consistency` (backwards compatibility).
48. Add an init `--check` exit-code test: drift → 1, in sync → 0.
49. Docs: `README.md` (`LOCAL_ONLY`, `NO_STOP_STACKS`, the `--check` workflow,
    the new metric) and `ARCHITECTURE.md` (stop policy and local-only in the
    Docker stack backup and metrics sections).
50. Leftover from item 27: step 4 of the `docker-backup.sh` header flow still
    ends with `-> azcopy copy`, which predates the pluggable target layer —
    delivery goes through `list_targets()` / `target_send()` and supports rsync
    too. Reword it to "deliver to configured targets" while the same header is
    being touched for `LOCAL_ONLY`.

## Phase 7 acceptance criteria

1. With `LOCAL_ONLY=true` and no targets configured, a run completes with no
   ERROR lines, leaves a valid tarball in `DOCKER_BACKUP_DIR`, and reports
   `docker_backup_success=1`.
2. With `LOCAL_ONLY=false` and no targets configured, the existing
   "no targets configured" ERROR still appears.
3. A stack listed in `NO_STOP_STACKS` is never stopped (`docker ps` uptime is
   uninterrupted), yields `docker_backup_stop_seconds=0`,
   `docker_backup_stack_stopped=0`, and a manifest with
   `consistency.stopped=false`, and still produces a restorable archive.
4. A stack **not** listed keeps the exact current stop-cold-copy behaviour,
   including the restart guard.
5. `restore.sh` warns when restoring a hot archive and restores older archives
   without a `consistency` field unchanged.
6. `docker-backup-init.sh --check` exits 0 in sync and 1 on drift; `--write`
   appends `STACKS`, `BIND_IGNORE` and `NO_STOP_STACKS` suggestions under one
   dated block and leaves a `.bak-<ts>`.
   > **Amended by follow-up items 51/52 (2026-09-20):** `--write`/`--yes`
   > applies `STACKS` drift unconditionally, but `BIND_IGNORE`/`NO_STOP_STACKS`
   > suggestions are heuristics and are only applied with the added
   > `--apply-bind-ignore`/`--apply-stop-policy` flags (or per-suggestion
   > interactive approval) — never just because `--write`/`--yes` was passed.
7. `tests/run_all.sh` passes including the two new test files; `shellcheck`
   passes on every changed script; the manifest JSON still validates and still
   reports `"schema": 2`.

## Phase 7 verification

1. `cd tests && ./run_all.sh` — all files green, including the new ones.
2. `bash -n` on every changed script; `shellcheck` if available.
3. On a real Docker host: configure one stack in `NO_STOP_STACKS` with
   `LOCAL_ONLY=true`, run `docker-backup.sh`, and confirm the stack never went
   down, the log says hot backup, a tarball lands in `DOCKER_BACKUP_DIR`, and no
   "no targets configured" ERROR appears.
4. `tar -xOf <archive> manifest.json | python3 -m json.tool` — verify
   `consistency.stopped=false` and `"schema": 2`.
5. `restore.sh --project-dir /tmp/r --bind-root /tmp/r <archive>` — the
   hot-archive warning is printed and files are restored.
6. `docker-backup-init.sh --check` → 0 when in sync; add a throwaway compose
   stack → 1 with the stack listed; `--write` appends it plus any suggestions.

## Phase 7 scope

- **Included**: `LOCAL_ONLY` mode; per-stack `NO_STOP_STACKS` policy; the
  `consistency` manifest field and `docker_backup_stack_stopped` metric;
  `docker-backup-init.sh --check` and richer auto-append; the dashboard panel;
  tests and docs for all of the above.
- **Excluded**: any change to target delivery (`conf/targets/`, azcopy, rsync
  retention); encryption; `env_file:` discovery; multi-node orchestration; any
  change to the host `backup.sh`; a manifest schema version bump.

## Phase 7 file map

| File | Touch points |
|---|---|
| `docker-backup.sh` | `backup_stack()` (stop/guard/start/delivery sequencing), `send_stack_to_targets()`, `push_stack_metrics()`, `write_manifest()`, `warn_stale_bind_ignore()`, the `STACKS` loop, `load_config()`, the file header flow |
| `lib.sh` | new `stack_stop_policy()`; reuse the matching style of `bind_ignored()` / `bind_include_netfs()`. `list_targets()`'s legacy `__compat__` shim and `pushgateway_post()` already degrade cleanly — leave them alone |
| `restore.sh` | `consistency.stopped` warning in the schema-2 path |
| `docker-backup-init.sh` | flag parsing, `append_stacks()` → `append_entries()`, `create_conf()`, `apply_append()`, `suggest_bind_ignore()`, new `suggest_stop_policy()`, new `--check` mode |
| `conf/docker-backup.example.conf` | `LOCAL_ONLY`, `NO_STOP_STACKS` |
| `tests/` | new `test_stop_policy.sh`, `test_local_only.sh`; extend `test_manifest_and_archive.sh`, `test_restore_roundtrip.sh`; harness/stubs as needed |
| `README.md`, `ARCHITECTURE.md`, `dashboards/linux-backups.json` | docs and the hot/cold panel |

# Phase 7 follow-up — post-implementation review

> **Status: Must fix (51–55) and should fix (56–60) IMPLEMENTED 2026-09-20.**
> Review findings recorded 2026-09-20. `docker-backup-init.sh` gained
> `--apply-bind-ignore`/`--apply-stop-policy` opt-in flags (BIND_IGNORE
> and NO_STOP_STACKS suggestions are no longer auto-applied by `--write`/
> `--yes`); the reconcile early-return no longer discards suggestion-only
> changes; `docker-backup.sh` now arms the restart guard before calling
> `docker compose stop` instead of after it returns success; new tests added:
> `tests/test_init_writer.sh` and two cases in `tests/test_backup_stack_failures.sh`
> (`test_stop_failure_still_attempts_restart`,
> `test_restart_guard_armed_before_stop_is_attempted`).
> `docker_backup_stack_stopped` is now only pushed alongside a valid archive;
> `LOCAL_ONLY` local-only delivery no longer claims retention without a valid
> archive; `load_config()` validates `LOCAL_ONLY` and `NO_STOP_STACKS`;
> reconcile reports "no additions to make" instead of "in sync" when only
> stale (`GONE`) entries exist; `--check` treats a missing config as drift
> even with nothing currently running. New tests: `tests/test_config_validation.sh`,
> plus additions to `tests/test_backup_stack_failures.sh`, `tests/test_local_only.sh`,
> `tests/test_init_check.sh`, and `tests/test_init_writer.sh`. `tests/run_all.sh`
> passes (10 files).

## Must fix — IMPLEMENTED 2026-09-20

51. Make `BIND_IGNORE` suggestions advisory by default. `suggest_bind_ignore()`
   currently treats a source shared by several stacks as a global exclusion
   candidate; accepting that suggestion can exclude the source from every
   stack and leave no backup copy. Broad transient-path matches carry the same
   data-loss risk. Keep objective `STACKS` drift auto-fixable, but require an
   explicit per-category opt-in or interactive approval before appending
   `BIND_IGNORE`. Prefer stack-scoped entries when only one stack should omit a
   shared source.
52. Make `NO_STOP_STACKS` suggestions advisory by default.
   `_stack_looks_stateful_db()` only proves that a shallow best-effort scan
   found no known signature; unreadable roots, files below the scan depth,
   unknown database images, and arbitrary writers can all produce false-safe
   hot candidates. `--write` must not silently weaken consistency. Require an
   explicit opt-in or interactive approval, treat scan/access errors as
   stop-cold-copy, and document that the result is a hint rather than a safety
   proof.
53. Fix reconciliation so suggestion-only changes are not discarded. The
   existing-config path returns when `UNMANAGED` is empty before mode handling,
   so `--write` cannot append approved `BIND_IGNORE` or `NO_STOP_STACKS`
   suggestions unless a new stack also exists. Determine all pending groups
   before deciding whether there is work, and create a `.bak-<ts>` only when a
   change will actually be written.
54. Arm cold-backup restart recovery before invoking `docker compose stop`.
   The current guard is armed only after stop returns success, so an interrupt
   during stop can leave some or all services down without EXIT recovery.
   Track `stop_attempted` separately from `stopped_successfully`, arm the guard
   before the stop command, perform a best-effort start after any attempted
   stop, and use only `stopped_successfully` for archive consistency and
   metrics.
55. Add tests for the init writer and suggestion safety. Current Phase 7 init
   tests cover only `--check`; add create/reconcile cases for one dated block,
   shell-safe quoting, `.bak-<ts>`, suggestion-only writes, duplicate
   avoidance, and proof that heuristic bind/hot suggestions are not accepted
   without explicit consent. Extend failure tests for interruption during stop
   and the separate attempted/successful stop states.

## Should fix — IMPLEMENTED 2026-09-20

56. Correct stop-policy observability on failed runs. Validation failure
   currently emits `docker_backup_stack_stopped=0` and appears HOT, while stop
   failure emits `1` although no valid archive exists. Emit achieved
   consistency only for a valid archive, or split configured policy from
   achieved archive consistency, and make failed/no-archive states explicit in
   the dashboard.
57. Gate the local-only retention message on a valid archive. The current branch
   can say an archive was retained and report target success after stop/tar
   failure removed or never produced the archive. Keep zero-target success
   semantics, but log the retained path only when `archive_ok=1`; otherwise
   report delivery as skipped because no valid archive exists.
58. Validate the new config values during load. Require `LOCAL_ONLY` to be
   exactly `true` or `false`, and require `NO_STOP_STACKS` to be an indexed
   array. Fail early with a clear config error instead of silently treating a
   typo such as `TRUE` as remote-delivery mode.
59. Make reconcile output truthful when only `GONE` entries exist. It currently
   warns about gone stacks and then says the config is "in sync" because only
   `UNMANAGED` controls the early return. Report that no additions are
   available and stale entries require manual removal.
60. Treat a missing config as drift in `docker-backup-init.sh --check`, even
   when no stateful stack is currently running, because `docker-backup.sh`
   itself cannot run without that file. Add a no-config/no-project test.

## Follow-up acceptance criteria

1. `--write` may still add objective `STACKS` drift non-interactively, but it
   never adds `BIND_IGNORE` or `NO_STOP_STACKS` guesses without a separate,
   explicit consent mechanism.
2. Suggestion-only reconciliation works, writes one dated block, creates one
   backup only when changing the config, and does not append duplicates.
3. A signal or stop failure during the cold path triggers a best-effort start;
   hot stacks never arm the guard or call stop/start.
4. Metrics and logs distinguish configured hot policy, successful cold archive,
   failed stop, failed archive, and local-only delivery skipped for lack of an
   archive.
5. Invalid Phase 7 config values fail before any stack is stopped or any target
   is contacted.
6. `--check` exits 1 for a missing config and for unmanaged/gone drift, and its
   normal reconcile report never labels a config with gone entries as in sync.
7. Focused regression tests, `tests/run_all.sh`, `bash -n`, and ShellCheck all
   pass after the follow-up work is implemented.
