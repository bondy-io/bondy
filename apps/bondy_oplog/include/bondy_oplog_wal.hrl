%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Constants and record definitions shared by the bondy_oplog_wal modules.
%% -----------------------------------------------------------------------------

-ifndef(BONDY_OPLOG_WAL_HRL).
-define(BONDY_OPLOG_WAL_HRL, true).

%% -----------------------------------------------------------------------------
%% Frame format (§3)
%% -----------------------------------------------------------------------------

%% "BDOP" in ASCII — Bondy OPlog frame magic.
-define(BONDY_OPLOG_WAL_FRAME_MAGIC, 16#42444F50).

%% Header bytes for a frame: Magic(4) + FrameLen(4) + CRC32(4) +
%% FrameVersion(1) + Flags(3) = 16.
-define(BONDY_OPLOG_WAL_FRAME_HEADER_BYTES, 16).

%% Frame schema versions. v2 differs from v1 only in the on-wire
%% `FrameVersion` byte and the set of flag bits its reader accepts:
%% bits 0 (compressed_body) and 1 (encrypted_body) are active in v2;
%% bit 2 (CRC32C) is reserved on-disk but unused (the upgrade was
%% evaluated and deferred — see `WAL_DESIGN_V2.md` §PR6).
-define(BONDY_OPLOG_WAL_FRAME_VERSION_V1, 1).
-define(BONDY_OPLOG_WAL_FRAME_VERSION_V2, 2).

%% Current writer version — what `encode/1,2` produces by default.
-define(BONDY_OPLOG_WAL_FRAME_VERSION,
    ?BONDY_OPLOG_WAL_FRAME_VERSION_V2
).

-define(BONDY_OPLOG_WAL_FRAME_FLAG_COMPRESSED, 16#000001).
-define(BONDY_OPLOG_WAL_FRAME_FLAG_ENCRYPTED, 16#000002).
-define(BONDY_OPLOG_WAL_FRAME_FLAG_CRC32C, 16#000004).

%% Codec algorithm ids used as the first byte of a compressed body
%% envelope. The Flags bit advertises "body is compressed"; the
%% envelope byte selects how to decompress. This decoupling lets a
%% writer swap algorithms (zlib → lz4 → …) without a wire-format break:
%% old segments stay readable as long as their algorithm id is still
%% understood. Reserved ids never write but may appear in fixtures.
-define(BONDY_OPLOG_WAL_CODEC_ALGO_ZLIB, 1).
-define(BONDY_OPLOG_WAL_CODEC_ALGO_LZ4, 2).

%% Encryption envelope (when Flags bit 1 is set):
%%
%%   Offset  Size  Field
%%      0     1    AlgorithmId   (1 = AES-256-GCM)
%%      1     2    KeyId         (operator-managed registry index)
%%      3    12    IV            (96-bit per AES-GCM)
%%     15    16    Tag           (GCM authentication tag)
%%     31   var    Ciphertext    (encrypted body bytes)
%%
%% AES-256-GCM is the only algorithm supported today; the id widens
%% the same way the compression-algorithm id does.
-define(BONDY_OPLOG_WAL_CODEC_CIPHER_AES_256_GCM, 1).
-define(BONDY_OPLOG_WAL_CODEC_IV_BYTES, 12).
-define(BONDY_OPLOG_WAL_CODEC_TAG_BYTES, 16).
-define(BONDY_OPLOG_WAL_CODEC_KEY_ID_BYTES, 2).
-define(BONDY_OPLOG_WAL_CODEC_KEY_BYTES, 32).
%% AlgorithmId(1) + KeyId(2) + IV(12) + Tag(16) = 31 bytes.
-define(BONDY_OPLOG_WAL_CODEC_ENCRYPT_HEADER_BYTES, 31).

%% Default `body_compression_min_bytes` — bodies below this threshold
%% are written uncompressed even when compression is enabled. Tunable
%% per-instance; trades a small CPU win on small bodies for the codec
%% cycles + envelope-byte overhead. 256 matches the design default.
-define(BONDY_OPLOG_WAL_BODY_COMPRESSION_MIN_BYTES_DEFAULT, 256).

%% Bitmask of flag bits each frame version's reader understands. Bits
%% outside the mask are rejected (encode-side `badarg`, decode-side
%% `unknown_flag`). v1 implemented neither codec nor algorithm choice
%% so the mask is zero; v2's mask covers bits 0 (compressed_body) and
%% 1 (encrypted_body). Bit 2 (CRC32C) is reserved on-disk via
%% `FLAG_CRC32C` but excluded from this mask — the upgrade was
%% evaluated and deferred (`WAL_DESIGN_V2.md` §PR6); a future activation
%% widens this mask and adds a `compute_crc(crc32c, _)` clause without
%% a wire-format change.
-define(BONDY_OPLOG_WAL_FRAME_KNOWN_FLAGS_V1, 16#000000).
-define(BONDY_OPLOG_WAL_FRAME_KNOWN_FLAGS_V2,
    (?BONDY_OPLOG_WAL_FRAME_FLAG_COMPRESSED bor
        ?BONDY_OPLOG_WAL_FRAME_FLAG_ENCRYPTED)
).

%% -----------------------------------------------------------------------------
%% Segment format (§4)
%% -----------------------------------------------------------------------------

%% "BDSG" in ASCII — segment header magic.
-define(BONDY_OPLOG_WAL_SEGMENT_MAGIC, 16#42445347).

%% Segment header: Magic(4) + Version(1) + Flags(3) + SegmentId(8) +
%% InstanceIdHash(8) + CreatedAt(8) + Origin(16) = 48.
-define(BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES, 48).

-define(BONDY_OPLOG_WAL_SEGMENT_VERSION, 1).

-define(BONDY_OPLOG_WAL_INSTANCE_ID_HASH_BYTES, 8).

%% -----------------------------------------------------------------------------
%% Manifest (§5)
%% -----------------------------------------------------------------------------

-define(BONDY_OPLOG_WAL_MANIFEST_VERSION, 1).
-define(BONDY_OPLOG_WAL_MANIFEST_FILENAME, "manifest").
-define(BONDY_OPLOG_WAL_MANIFEST_TMP_FILENAME, "manifest.tmp").

%% -----------------------------------------------------------------------------
%% Consumer offset (§6)
%% -----------------------------------------------------------------------------

-define(BONDY_OPLOG_WAL_CONSUMER_OFFSET_FILENAME, "consumer.offset").
-define(BONDY_OPLOG_WAL_CONSUMER_OFFSET_TMP_FILENAME, "consumer.offset.tmp").
-define(BONDY_OPLOG_WAL_CONSUMER_OFFSET_VERSION, 1).

%% -----------------------------------------------------------------------------
%% Sparse index `.qidx` (§7)
%% -----------------------------------------------------------------------------

%% "BDIX" in ASCII — sparse index file magic.
-define(BONDY_OPLOG_WAL_IDX_MAGIC, 16#42444958).

%% Index header: Magic(4) + Version(1) + Flags(3) + EntryCount(4) +
%% Reserved(4) = 16.
-define(BONDY_OPLOG_WAL_IDX_HEADER_BYTES, 16).

%% v1 entry: HLC(8) + ByteOffset(8) = 16.
%% v2 entry: HLC_first(8) + HLC_last(8) + ByteOffset(8) = 24. v2 carries
%% each indexed frame's *batch-HLC range* so the reader-side seek picks
%% the offset of the batch that contains a target HLC in O(log N)
%% without a forward scan into the un-indexed gap. See
%% `WAL_DESIGN_V2.md` §PR7.
-define(BONDY_OPLOG_WAL_IDX_ENTRY_BYTES_V1, 16).
-define(BONDY_OPLOG_WAL_IDX_ENTRY_BYTES_V2, 24).

-define(BONDY_OPLOG_WAL_IDX_VERSION_V1, 1).
-define(BONDY_OPLOG_WAL_IDX_VERSION_V2, 2).

%% Current writer version — what `write_file/2` produces by default.
%% v1 files remain readable (entries are lifted to the v2 shape at read
%% time); a rebuild during recovery upgrades them to v2.
-define(BONDY_OPLOG_WAL_IDX_VERSION, ?BONDY_OPLOG_WAL_IDX_VERSION_V2).
-define(BONDY_OPLOG_WAL_IDX_ENTRY_BYTES,
    ?BONDY_OPLOG_WAL_IDX_ENTRY_BYTES_V2
).

%% Default index interval in bytes — the writer emits one index entry per
%% ~64 KB of frames written.
-define(BONDY_OPLOG_WAL_IDX_DEFAULT_INTERVAL_BYTES, (64 * 1024)).

%% -----------------------------------------------------------------------------
%% Fsync modes + batched-mode defaults (§8.1)
%% -----------------------------------------------------------------------------

%% Default fsync mode for instances that do not specify one. Per-write is
%% the conservative choice — security-class namespaces rely on it
%% (`grants`, `tickets`, `users`). High-churn namespaces (`registry`)
%% override to `batched` in their per-instance config.
-define(BONDY_OPLOG_WAL_FSYNC_MODE_DEFAULT, per_write).

%% In `batched` mode the writer fsyncs at most every
%% `batched_fsync_interval` ms. 50 ms gives a 20 Hz fsync cadence which
%% is fast enough that `await_durable/3` callers rarely block more than
%% one tick, and slow enough that 1000-event bursts amortise to ~50
%% fsyncs.
-define(BONDY_OPLOG_WAL_BATCHED_FSYNC_INTERVAL_DEFAULT_MS, 50).

%% Size-trigger: fsync if `pending_fsync` bytes exceed this threshold,
%% even before the interval elapses. 1 MB is the WAL_DESIGN default — it
%% bounds tail-of-log loss on crash to ~1 MB of buffered writes per
%% writer.
-define(BONDY_OPLOG_WAL_BATCHED_FSYNC_BYTES_DEFAULT, (1 * 1024 * 1024)).

%% Group commit (boxcar) for `per_write` mode. When enabled, the writer
%% writes each concurrently-queued append's frame, then issues a single
%% `datasync` covering the whole group and replies to every caller only
%% after that shared fsync. Durability is identical to plain per_write
%% (durable-on-return), but one fsync amortises across many appends —
%% removing the "one fsync per concurrent appender" wall. No effect in
%% `batched` mode, which already coalesces by size/time.
-define(BONDY_OPLOG_WAL_GROUP_COMMIT_DEFAULT, true).

%% Upper bound on the number of queued appends folded into one group (one
%% datasync). Bounds the first caller's fsync latency and the work done
%% in a single `handle_call`. 1024 is far above realistic per-writer
%% concurrency, so in practice a whole burst coalesces into one fsync.
-define(BONDY_OPLOG_WAL_GROUP_COMMIT_MAX_DEFAULT, 1024).

%% -----------------------------------------------------------------------------
%% Atomic batches (§3, §8.3 — Q9)
%% -----------------------------------------------------------------------------

%% Hard upper bound on the encoded body of a single atomic batch frame.
%% 4 MiB is large enough to hold tens of thousands of small events in one
%% atomic write, while keeping a single frame well below the default
%% `max_segment_bytes` (64 MiB) so pre-rotation always has room.
-define(BONDY_OPLOG_WAL_MAX_BATCH_BYTES_DEFAULT, (4 * 1024 * 1024)).

%% -----------------------------------------------------------------------------
%% Retention + snapshot watermark (§10)
%% -----------------------------------------------------------------------------

-define(BONDY_OPLOG_WAL_SNAPSHOT_WATERMARK_FILENAME, "snapshot.watermark").
-define(BONDY_OPLOG_WAL_SNAPSHOT_WATERMARK_TMP_FILENAME,
    "snapshot.watermark.tmp"
).
-define(BONDY_OPLOG_WAL_SNAPSHOT_WATERMARK_VERSION, 1).

%% Minimum number of live segments to keep after a retention sweep, even
%% if all segments are otherwise eligible for deletion. Provides a
%% recent-history safety net for ad-hoc inspection / replay.
-define(BONDY_OPLOG_WAL_MIN_LIVE_SEGMENTS_DEFAULT, 2).

%% Default cadence of the periodic retention sweep (ms). 5 minutes per
%% WAL_DESIGN §10.4 — a safety net behind the event-driven triggers
%% (applier commit advance, watermark advance).
-define(BONDY_OPLOG_WAL_RETENTION_SWEEP_INTERVAL_DEFAULT_MS, (5 * 60 * 1000)).

%% -----------------------------------------------------------------------------
%% Backpressure (§14, §15)
%% -----------------------------------------------------------------------------

%% Hard cap on the sum of `.qdata` sizes across all live segments. Once
%% crossed, `append`/`append_batch` return `{error, wal_full}` until
%% retention frees space. 8 GiB matches the WAL_DESIGN §14 default.
-define(BONDY_OPLOG_WAL_MAX_TOTAL_WAL_SIZE_DEFAULT, (8 * 1024 * 1024 * 1024)).

%% Hard cap on `length(live_segments)`. Once reached, the writer refuses
%% the rotation that would create segment N+1 — the in-flight append is
%% rejected with `{error, wal_full}`. 256 matches WAL_DESIGN §14.
-define(BONDY_OPLOG_WAL_MAX_LIVE_SEGMENTS_DEFAULT, 256).

%% Minimum interval between `wal_full` telemetry events (ms). A backpressured
%% client typically retries on a tight loop; without debouncing the WAL
%% would emit one event per retry. 30 s matches the WAL_DESIGN §15
%% recommendation.
-define(BONDY_OPLOG_WAL_WAL_FULL_TELEMETRY_DEBOUNCE_MS, (30 * 1000)).

-endif.
