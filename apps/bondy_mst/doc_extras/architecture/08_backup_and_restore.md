# Backup and restore: operator runbook

This runbook backs up and restores the on-disk state of `bondy_oplog`
instances with `bondy_mst_admin`. `bondy_mst_admin` copies a directory tree
file by file. It does not interpret the files, so it backs up whatever lies
under the source directory.

## What gets backed up

An instance started with `storage_path` keeps its files in one instance
directory. With the default `sharded` path layout, that directory is
`<storage_path>/<h2>/<h4>/<InstanceId>/`, where `<h2>` and `<h4>` are the
first 2 and 4 hex characters of `sha256(InstanceId)`. With the `flat` layout,
it is `<storage_path>/<InstanceId>/`.

```
<instance dir>/
├── manifest, tombstones, incoming.pack,
│   pack-NNNN.pack, pack-NNNN.idx        ← MST pack store
├── wal/<InstanceId>/...                 ← WAL segments, manifest, consumer offset
├── origin/                              ← persisted origin of the instance
└── checkpoint.etf                       ← compaction checkpoint
```

`bondy_mst_admin:backup/2` copies every regular file under the source
directory and writes `manifest.etf` into the backup directory. The manifest
records the relative path, size and SHA-256 of each file.

The backup covers only the files under the source directory:

- An instance configured with an explicit `wal_dir` keeps its WAL there, not
  under `storage_path`. Back up that directory as well.
- The Leveled projection store of `bondy_db` has its own directory. A backup
  of `storage_path` includes it only when that directory lies under
  `storage_path`.

## Cold backup

`bondy_mst_admin` has no write barrier. Stop every writer on the source
directory before the backup. For a backup without downtime, take a
filesystem snapshot (LVM, ZFS, btrfs, AWS EBS) of `storage_path` and back up
the snapshot mount.

### Procedure

```erlang
%% 1. Stop the instance.
ok = bondy_oplog:stop_instance(InstanceId),

%% 2. Back up.
{ok, Manifest} = bondy_mst_admin:backup(StoragePath, BackupDir),

%% 3. Verify the copy.
{ok, Manifest} = bondy_mst_admin:verify(BackupDir),

%% 4. Restart.
{ok, _Pid} = bondy_oplog:start_instance(InstanceId, Opts).
```

`backup/2` creates `BackupDir` when it does not exist. When `BackupDir`
exists and is not empty, `backup/2` returns `{error, {target, not_empty,
BackupDir}}`. To back up into a non-empty directory, call `backup/3` with
`#{allow_nonempty_target => true}`.

### Telemetry

Each call emits a `start` event and then a `complete` or a `failed` event.

| Event | Measurements | Metadata |
|---|---|---|
| `[bondy_mst, admin, backup, start]` | none | `source`, `target` |
| `[bondy_mst, admin, backup, complete]` | `file_count`, `total_bytes`, `duration_us` | `source`, `target` |
| `[bondy_mst, admin, backup, failed]` | `duration_us` | `source`, `target`, `reason` |
| `[bondy_mst, admin, verify, start]` | none | `target` |
| `[bondy_mst, admin, verify, complete]` | `file_count`, `total_bytes`, `duration_us` | `target` |
| `[bondy_mst, admin, verify, failed]` | `duration_us` | `target`, `reason` |
| `[bondy_mst, admin, restore, start]` | none | `source`, `target` |
| `[bondy_mst, admin, restore, complete]` | `file_count`, `total_bytes`, `duration_us` | `source`, `target` |
| `[bondy_mst, admin, restore, failed]` | `duration_us` | `source`, `target`, `reason` |

## Verifying a backup

```erlang
{ok, Manifest} = bondy_mst_admin:verify(BackupDir).
```

`verify/1` reads `manifest.etf`. For each entry, it checks that the file
exists, that its size matches, and that its SHA-256 matches. It does not
report files that are on disk but not in the manifest.

| Error | Meaning |
|---|---|
| `{manifest, not_found}` | `BackupDir` has no `manifest.etf`. |
| `{manifest, {corrupted, _}}` | `manifest.etf` does not decode. |
| `{manifest, {unexpected_term, _}}` | `manifest.etf` decodes, but not to a `backup_v1` term. |
| `{manifest, Reason}` | `manifest.etf` cannot be read. |
| `{file, RelPath, missing}` | A file in the manifest is not on disk. |
| `{file, RelPath, size_mismatch}` | The size of a file differs from the manifest. |
| `{file, RelPath, hash_mismatch}` | The content of a file differs from the manifest. |
| `{read, Reason}` | A file cannot be read. |

Verify every backup that has been moved (to object storage, to another host,
or to tape) before you rely on it.

## Restoring

```erlang
%% 1. Stop the instance if it runs.
ok = bondy_oplog:stop_instance(InstanceId),

%% 2. Restore. restore/2 verifies the backup first.
{ok, _Manifest} = bondy_mst_admin:restore(BackupDir, StoragePath),

%% 3. Restart with the options used before the backup.
{ok, _Pid} = bondy_oplog:start_instance(InstanceId, Opts).
```

`restore/2` calls `verify/1` on `BackupDir`. When verification fails,
`restore/2` returns the error and copies nothing. It then applies the same
target check as `backup/2`: the target has to be absent or empty, unless you
call `restore/3` with `#{allow_nonempty_target => true}`. `restore/2`
datasyncs every file it writes and fsyncs the top-level target directory.

When the instance restarts, its pack store opens from the restored files. A
backup taken while an asynchronous seal was in flight holds an
`incoming-sealing-NNNN.pack` file. The pack store finishes that seal when it
opens, before it serves reads. The `recovery_*` tests in
`bondy_mst_pack_writer_async_seal_test` cover this path. The instance then
recovers its WAL and replays the events past its resume position, as
`apps/bondy_db/doc_extras/architecture/01_bondy_oplog.md` describes under
"Recovery on boot".

## Backups in a cluster

In a cluster, a replica that loses its disk can bootstrap from a peer.
`apps/bondy_db/doc_extras/architecture/06_compaction_and_bootstrap.md`
describes bootstrap. A backup is then the recovery path for the loss of
every replica.

## Limits

- **Cold only.** There is no write barrier. Use a filesystem snapshot to back
  up without stopping the writer.
- **One tree per call.** Each `backup/2` call covers one source directory.
  Call it once for each directory that holds state.
- **Full copies only.** Every backup is a complete copy. There is no
  incremental format.
- **No compression or encryption.** Process the backup directory with your
  own tools (for example `tar | zstd | age`) when you need either.
