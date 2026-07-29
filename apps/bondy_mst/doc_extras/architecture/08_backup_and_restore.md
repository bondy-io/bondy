# Backup & restore — operator runbook

This page is the **operator's runbook** for backing up and restoring an oplog
instance's on-disk store — the WAL, the MST pack-store, and the compaction
checkpoint that live together under one `storage_path`. For what each of those
stores contains, see the storage-stack architecture chapters 00 (the layered
storage model) and 01 (the WAL and recovery).

The Erlang API for these operations is in `bondy_mst_admin`; it copies the tree
generically, so it backs up whatever a shard owns under `storage_path`.

## What gets backed up

A Bondy node persists three things under `storage_path`:

```
<storage_path>/
└── <shard1>/<shard2>/<InstanceId>/
    ├── wal/<InstanceId>/...           ← WAL segments + manifest + consumer offset
    ├── <pack store files>             ← MST packfiles, .idx files, manifest
    └── checkpoint.etf                 ← compaction checkpoint
```

`bondy_mst_admin:backup/2` copies this entire tree byte-for-byte and writes
a `manifest.etf` recording every file's SHA-256.

**Leveled (the projection store) is NOT backed up by this tool.** Bondy
runs Leveled in head-only mode (PR-PS-15b); on disk loss the projection
is rebuilt from a peer (`bondy_oplog_catalogue_snapshot` — see chapter
06) or from a Leveled-specific backup. The tools here cover the **WAL +
MST + checkpoint** triple, which is what the oplog itself owns.

## Cold backup

The supported flow assumes the writer is stopped. The library does **not**
provide a hot-backup write-barrier in this release; for zero-downtime
backups use a filesystem-level snapshot (LVM, ZFS, btrfs, AWS EBS) of
`storage_path`, then point `backup/2` at the snapshot mount.

### Recommended sequence

```erlang
%% 1. Stop the instance(s) you want to back up.
ok = bondy_oplog:stop_instance(InstanceId),

%% 2. Run the backup.
{ok, Manifest} = bondy_mst_admin:backup(StoragePath, BackupDir),

%% 3. Optionally re-verify the destination.
{ok, _} = bondy_mst_admin:verify(BackupDir),

%% 4. Restart.
{ok, _} = bondy_oplog:start_instance(InstanceId, Opts).
```

`backup/2` refuses a non-empty target by default. Pass
`#{allow_nonempty_target => true}` to bypass that guard (e.g. if you are
re-writing into a snapshot directory that already has metadata).

### Telemetry

| Event | When |
|---|---|
| `[bondy_mst, admin, backup, start]` | A backup call begins. |
| `[bondy_mst, admin, backup, complete]` | Backup succeeded. Measurements include `file_count`, `total_bytes`, `duration_us`. |
| `[bondy_mst, admin, backup, failed]` | Backup raised. Metadata carries `reason`. |

(`verify` and `restore` emit the same shapes under their own suffixes.)

## Verifying a backup

```erlang
{ok, Manifest} = bondy_mst_admin:verify(BackupDir).
```

`verify/1` reads `manifest.etf`, then for each entry confirms the file
exists, has the recorded size, and hashes to the recorded SHA-256.

Error variants:

| Error | Meaning |
|---|---|
| `{manifest, not_found}` | `manifest.etf` is missing in `BackupDir`. |
| `{manifest, {corrupted, _}}` | `manifest.etf` could not be decoded. |
| `{manifest, {unexpected_term, _}}` | Decoded fine but wasn't the expected `backup_v1` shape. |
| `{file, RelPath, missing}` | A manifest-listed file isn't on disk. |
| `{file, RelPath, size_mismatch}` | File size differs from manifest. |
| `{file, RelPath, hash_mismatch}` | File content differs from manifest. |

You should `verify` any backup that has been transported (copied to S3,
moved between hosts, restored from tape) before you trust it.

## Restoring

```erlang
%% 1. Stop the instance if it is running.
ok = bondy_oplog:stop_instance(InstanceId),

%% 2. Make sure the target storage_path is empty (or allow non-empty).
%% 3. Run the restore — verify happens first.
{ok, _} = bondy_mst_admin:restore(BackupDir, StoragePath),

%% 4. Restart with the same opts you used before the backup.
{ok, _} = bondy_oplog:start_instance(InstanceId, Opts).
```

`restore/2` calls `verify/1` first, so it never copies a tampered or
truncated backup into a live data dir.

On restart the instance:

1. Opens the MST pack-store from the restored files — re-sealing any
   `incoming-sealing-*` file left behind by an async seal that was in
   flight when the node stopped. That roll-aside file is part of the
   byte-for-byte tree, so the reopen completes the seal deterministically;
   no manifest change is involved, so a backup taken mid-seal is still
   consistent.
2. Reads `checkpoint.etf` for the watermark + folded CRDT state.
3. Replays the WAL tail past the watermark.
4. Seeds the HLC from the restored watermark so further appends are
   strictly newer than the pre-backup events.

## When to take a backup

| Deployment | Suggested cadence |
|---|---|
| Single-node, security-critical | Hourly cold copy + filesystem snapshot for sub-hour RPO |
| Single-node, routing-only | Daily |
| Multi-node (≥ 3 peers) | Weekly snapshot for DR; routine recovery is peer bootstrap |

For multi-node clusters the catalogue-snapshot bootstrap protocol
(chapter 06) is the *primary* recovery mechanism — backups are a
secondary safety net for the case where the whole cluster is lost.

## Limits in this release

- **Cold only.** No write-barrier primitive (`freeze/unfreeze`) in this
  release. Use filesystem snapshots for hot backups.
- **Single-tree only.** Each `backup/2` call covers one source tree. If
  your deployment has `storage_path` and Leveled at different roots,
  invoke `backup/2` once per tree.
- **Full only.** No incremental / streaming format yet — every backup
  is a complete copy.
- **No compression or encryption.** Both are out of scope. Pipe the
  backup directory through `tar | zstd | age` (or your tool of choice)
  if you need either.

These constraints exist because the cold-copy primitive is enough for
the documented recovery flows. Streaming and write-barrier support can
be added without breaking the manifest format (`backup_v1`).
