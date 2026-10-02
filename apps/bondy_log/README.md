# bondy_log

Append-only log core shared by `bondy_oplog` (the replicated operation log)
and Bondy Streams. It owns everything about a segmented log that does not
depend on what a log record *is*, who the log belongs to, or where its
writer is found:

- `bondy_log_wal` — the writer gen_server: atomic batch frames, per-write
  or batched fsync with group commit, rotation, the sparse index, the
  manifest, retention and backpressure. `open/2` returns the retained
  `max_seq` so the consumer seeds its own counter; the log never calls its
  consumer.
- `bondy_log_recovery` — boot-time recovery: manifest validation, orphan
  cleanup, sealed-segment verification and index rebuild, head-segment
  break-and-truncate (or rescan), consumer-offset clamp.
- `bondy_log_reader` — the drain cursor over sealed segments and the live
  head, with key seek through the sparse index.
- `bondy_log_segment`, `bondy_log_idx`, `bondy_log_manifest`,
  `bondy_log_state` — the on-disk layout: segment header, `.qidx`, the
  manifest, the consumer offset and snapshot watermark files.
- `bondy_log_scrubber` — periodic CRC walk of sealed segments.
- `bondy_log_frame` — the 16-byte frame envelope (magic, length, CRC32,
  version, flags) around an opaque body. The magic is a parameter so several
  log kinds can share one segment scanner without accepting each other's
  frames.
- `bondy_log_codec` — body compression (zlib) and encryption (AES-256-GCM),
  selected by the frame flags.
- `bondy_log_record`, `bondy_log_identity`, `bondy_log_directory` — the
  three behaviours a log adapter implements in one module, passed to the
  writer as `adapter`: what a record is (frame magic, body encode/decode,
  the integer key each record is indexed by, membership validation, the
  batch's own-origin sequence maximum), what fills the segment header's
  two identity fields, and where the writer pid is registered and looked
  up. `bondy_oplog_log_adapter` is the oplog's; it writes the bytes the
  WAL wrote before the seams existed, and `bondy_oplog_wal` is the facade
  that opens the core with it.
- `bondy_log_key_registry` — the behaviour a codec key provider implements
  (`bondy_keyring` in `bondy_router` is the production implementation).
- `bondy_log_io` — `write_atomic/2,3`: tmp file → datasync → rename →
  directory fsync, the idiom every small metadata file in the storage stack
  (manifest, sparse index, consumer offset, checkpoint) is written with.
- `include/bondy_log.hrl` — the format constants and the writer's policy
  defaults.

The core names no consumer module (`scripts/check_layering.escript` keeps
`bondy_db -> bondy_oplog -> bondy_log -> bondy_mst` acyclic), and every
telemetry event it emits is named under the consumer's `telemetry_prefix`.
`bondy_oplog` re-exports the constants under its historical
`BONDY_OPLOG_WAL_*` names.
