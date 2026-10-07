# bondy_log

Append-only, segmented log core. `bondy_oplog` uses it as the writer under its
WAL; the core is also intended to serve Bondy Streams. It owns everything
about a segmented log that does not depend on what a log record *is*, who the
log belongs to, or where its writer is found:

- `bondy_log_wal`: the writer gen_server. It writes atomic batch frames,
  fsyncs per write or in batches with group commit, rotates segments, and
  maintains the sparse index and the manifest. It also applies retention and
  backpressure. `open/2` returns the retained `max_seq`, so the consumer can
  seed its own sequence counter.
- `bondy_log_recovery`: boot-time recovery. It validates the manifest, removes
  orphan files, verifies sealed segments and rebuilds their index, and
  truncates the head segment at its first corrupt frame (`strict` mode) or
  rewrites it without the corrupt frames (`rescan` mode). It also clamps
  the consumer offset.
- `bondy_log_reader`: the drain cursor over sealed segments and the live
  head, with key seek through the sparse index.
- `bondy_log_segment`, `bondy_log_idx`, `bondy_log_manifest`,
  `bondy_log_state`: the on-disk layout. These are the segment header, the
  `.qidx` sparse index, the manifest, and the consumer-offset and
  snapshot-watermark files.
- `bondy_log_scrubber`: a periodic CRC walk of sealed segments.
- `bondy_log_frame`: the 16-byte frame envelope (magic, length, CRC,
  version, flags) around an opaque body. The magic is a required parameter,
  so several kinds of log can share one segment scanner without accepting
  each other's frames.
- `bondy_log_codec`: body compression (zlib) and encryption (AES-256-GCM),
  selected by the frame flags. The `lz4` algorithm id is reserved and
  `validate_algorithm/1` rejects it.
- `bondy_log_record`, `bondy_log_identity`, `bondy_log_directory`: the three
  behaviours that a log adapter implements in one module. The writer receives
  the module as its `adapter` option.
  - `bondy_log_record` defines a record: the frame magic, body encoding and
    decoding, the integer key that indexes each record, record validation,
    and the highest own-origin sequence in a batch.
  - `bondy_log_identity` fills and verifies the two identity fields of the
    segment header.
  - `bondy_log_directory` registers and looks up the writer pid.

  `bondy_oplog_log_adapter` is the adapter of the oplog, and
  `bondy_oplog_wal` is the facade that opens the core with it.
- `bondy_log_key_registry`: the behaviour that a codec key provider
  implements. `bondy_keyring` in `bondy_router` implements it.
- `bondy_log_io`: `write_atomic/2,3`. It writes a temporary file, datasyncs
  it, renames it over the target and fsyncs the directory. The manifest,
  the sparse index, the consumer offset and the snapshot watermark are
  written this way.
- `include/bondy_log.hrl`: the format constants and the default writer
  policy.

The core names no consumer module: the writer calls a consumer only through
the adapter module that the consumer passes in. Each telemetry event is named
under the `telemetry_prefix` option, which defaults to `[bondy_log]`.
`bondy_oplog` re-exports the format constants under `BONDY_OPLOG_WAL_*`
names in `bondy_oplog_wal.hrl`.
