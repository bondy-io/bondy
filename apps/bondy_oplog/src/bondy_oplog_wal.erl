%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
-moduledoc """
Per-instance Write-Ahead Log writer.

Current behaviour:

- `open/2` creates a fresh per-instance WAL directory or recovers an
  existing one via `bondy_oplog_wal_recovery`.
- `append/2` writes a single event as a one-element batch frame
  (`term_to_binary([Event], ...)`), and either fsyncs immediately
  (`fsync_mode = per_write`) or defers fsync to a batched boundary
  (`fsync_mode = batched`). Returns the event's HLC plus the
  `{Segment, Offset}` of the frame start.
- `append_batch/2` writes N events as a single atomic batch frame
  (`term_to_binary([E1, ..., EN], ...)`). Either all events land
  durably in the same segment or none do (a crash mid-write leaves the
  partial frame to be break-and-truncated on recovery). Pre-rotation
  ensures a batch never spans segment boundaries.
- Rotation happens between appends when the next frame would push the
  head segment past `max_segment_bytes`. The manifest is rewritten
  atomically via `bondy_oplog_wal_manifest:write/2`. Rotation also
  fsyncs the just-sealed segment, advancing `durable_position/1`.
- Per-frame the writer feeds the sparse-index accumulator
  (`bondy_oplog_wal_idx`); on rotation the sealed segment's `.qidx` is
  flushed to disk, on `terminate/2` the head segment's `.qidx` is
  flushed.
- `sync/1` forces a head fsync, advancing durable and notifying any
  `await_durable/3` waiters covered by the new durable position.
- `durable_position/1` and `await_durable/3` expose the durability
  boundary distinct from the (possibly leading) head position. In
  `per_write` mode head ≡ durable so `await_durable/3` always returns
  immediately; in `batched` mode head can lead durable by up to one
  fsync interval.
- `close/1` fsyncs and stops the writer; `info/1` exposes the writer's
  current state (including `head_offset`, `durable_offset`,
  `fsync_mode`, `last_fsync_at`).

## Choosing an `fsync_mode`

The library default is `per_write` because security-class namespaces
(`grants`, `tickets`, `users`) rely on the strong "on disk before
`append/2` returns" contract. The conservative default protects
correctness for callers who do not opt in.

`per_write` is bounded by the device fsync rate (a few thousand
ops/s) and its tail latency grows linearly with the number of
concurrent appenders — the writer replies serially, one per fsync.
Concurrency benchmarks measure ~5,500 events/s on a single writer
and degrade under contention.

`batched` is the right choice for any high-churn workload that can
accept a bounded durability window (the larger of
`batched_fsync_interval` ms or `batched_fsync_bytes`). It reaches
~200 k events/s under 16 concurrent appenders on commodity NVMe and
keeps p99.9 latency bounded by the fsync interval. Pair it with
`await_durable/3` when the caller needs to know a specific position
is on disk. The reference high-churn namespace (`registry`)
overrides to `batched` in its per-instance config.

Retention, backpressure, the applier integration, and the full
stateful-PropEr fault-injection harness are still to land.
""".

%% Pending `await_durable/3` caller. Sorted ascending by `pos` in
%% `state.waiters` so satisfying on a durable advance is a
%% `lists:splitwith/2` over the head of the list.
-record(waiter, {
    id :: reference(),
    pos :: {bondy_oplog_wal_segment:segment_id(), non_neg_integer()},
    from :: gen_server:from(),
    %% `infinity` ⇒ no deadline; otherwise the timer ref the writer
    %% will receive on timeout (and cancel on satisfy).
    tref :: reference() | infinity
}).

-record(state, {
    instance_id :: instance_id(),
    dir :: file:filename_all(),
    origin :: bondy_oplog_origin:t(),
    max_segment_bytes :: pos_integer(),
    %% Hard cap on the encoded body of a single atomic batch. Bounds
    %% worst-case memory for `term_to_binary/2` of the batch list and
    %% guarantees a single frame can always fit in a fresh segment.
    %% Validated against `max_segment_bytes` at init.
    max_batch_bytes :: pos_integer(),
    retention :: [{atom(), term()}],
    head_fd :: file:fd() | undefined,
    segment_id :: bondy_oplog_wal_segment:segment_id(),
    current_offset :: non_neg_integer(),
    first_hlc :: bondy_oplog_hlc:hlc() | undefined,
    last_hlc :: bondy_oplog_hlc:hlc() | undefined,
    append_count :: non_neg_integer(),
    %% The largest own-origin seq appended to this WAL, ever. Recovered on
    %% open as `max(manifest max_seq, head-segment scan)` and persisted into
    %% the manifest at every rotation, so the retained WAL's maximum is known
    %% the moment the writer is open — before any reader has replayed a
    %% frame. `init/1` hands it to the instance (`seed_seq/2`) BEFORE
    %% publishing this pid: no writer can reserve a seq against a counter
    %% that has not absorbed it.
    max_seq :: non_neg_integer(),
    %% In-memory shadow of the on-disk manifest. Updated in place on
    %% rotation; flushed atomically via `bondy_oplog_wal_manifest:write/2`
    %% (tmp + datasync + rename + dir-fsync) so on-disk and in-memory
    %% never diverge.
    manifest :: bondy_oplog_wal_manifest:t() | undefined,
    %% Two-slot atomics ref published to tail readers (`bondy_oplog_wal_reader`).
    %% Slot 1: head segment id. Slot 2: head offset within that segment.
    %% Updated in this order on rotation so a reader who races never sees
    %% the new offset paired with the old segment id; see
    %% `publish_head_pos/3` and `publish_head_offset/2`.
    head_pos_ref :: atomics:atomics_ref() | undefined,
    %% Sparse-index accumulator for the current head segment.
    %% Entries are flushed to `.qidx` on rotation (sealed segment) and
    %% on `terminate/2` (live head segment). Per-frame I/O cost is zero —
    %% entries live in memory until a flush boundary.
    idx_acc :: bondy_oplog_wal_idx:accumulator() | undefined,
    idx_interval_bytes :: pos_integer(),
    %% --- Durability state -----------------------------------------------------
    %% `per_write`: each `append/2` includes a `prim_file:datasync/1`
    %% and returns durable. `batched`: appends accumulate until the
    %% size threshold or the interval timer fires; durability is
    %% reached at a fsync boundary or via `sync/1`/`await_durable/3`.
    fsync_mode :: per_write | batched,
    %% Batched-mode timer interval (ms) — bound on the lag between a
    %% successful `append/2` and the next fsync.
    batched_fsync_interval :: pos_integer(),
    %% Batched-mode size trigger (bytes) — bound on un-fsynced data.
    batched_fsync_bytes :: pos_integer(),
    %% Bytes written since the last fsync (head segment only; rotation
    %% always fsyncs before sealing).
    pending_fsync_bytes :: non_neg_integer(),
    %% Monotonic timestamp of the most recent fsync, used by
    %% `last_fsync_at` in `info/1` and lag-monitoring telemetry.
    last_fsync_at :: integer() | undefined,
    %% Active `send_after/3` timer that will fire `flush_tick`. Set when
    %% pending bytes accrue in batched mode; cancelled on fsync.
    flush_timer :: reference() | undefined,
    %% --- Group commit ---------------------------------------------------------
    %% When `true` (and `fsync_mode = per_write`), concurrently-queued
    %% appends are coalesced into one `datasync` per group; each caller is
    %% replied only after the shared fsync covers its frame, preserving the
    %% per_write durable-on-return contract while removing the
    %% one-fsync-per-appender wall. No effect in batched mode.
    group_commit :: boolean(),
    %% Max appends folded into a single group (one datasync); bounds the
    %% first caller's fsync latency and the per-`handle_call` work.
    group_commit_max :: pos_integer(),
    %% Count of head fsyncs issued via `do_fsync_head/1`. Does NOT count
    %% rotation seals, new-segment header syncs, or the terminate sync
    %% (those datasync independently). Surfaced in `info/1` as the
    %% coalescing observable: under load `append_count / fsync_count` is
    %% the average group size.
    fsync_count :: non_neg_integer(),
    %% Two-slot atomics ref mirroring `head_pos_ref`'s shape but carrying
    %% the durable position (slot 1: durable segment id, slot 2:
    %% durable byte offset). Tail readers / appliers may poll this
    %% wait-free; cross-segment reads are subject to the same race as
    %% `head_pos_ref` (see comment on `publish_durable_pos/3`). For a
    %% coherent snapshot use `durable_position/1` which reads in-memory
    %% state through the writer's gen_server.
    durable_pos_ref :: atomics:atomics_ref() | undefined,
    %% In-memory mirror of the durable position. The authoritative copy
    %% for `durable_position/1` and `await_durable/3` (both serialise
    %% through the gen_server). Advances on fsync; on rotation jumps to
    %% the new segment's header boundary (the new segment file is
    %% datasync'd at create time).
    durable_segment_id :: bondy_oplog_wal_segment:segment_id(),
    durable_offset :: non_neg_integer(),
    %% Pending `await_durable/3` callers, sorted ascending by `#waiter.pos`.
    %% Walked head-first on durable advance; replaced wholesale on each
    %% advance via `satisfy_waiters_up_to/2`.
    waiters :: [#waiter{}],
    %% --- Retention state -------------------------------------------------------
    %% Largest HLC covered by a compaction snapshot. `undefined` until
    %% the first `advance_snapshot_watermark/2` lands. Persisted to
    %% `snapshot.watermark` via tmp+rename on every advance.
    snapshot_watermark :: bondy_oplog_hlc:hlc() | undefined,
    %% Highest segment id known to be safely past the applier (its
    %% events have been committed to the projection). Lower bound for
    %% the retention sweep: only segments strictly below this can be
    %% deleted. The consumer-commit machinery lands later; for now this
    %% defaults to `max(deleted_through, 0)` and is mutated by the
    %% test/stub interface only.
    committed_segment :: non_neg_integer(),
    %% Lower bound on the size of `live_segments` after a sweep — the
    %% sweep refuses to delete a segment if doing so would drop the
    %% live-segment count below this threshold. Operator override
    %% via the `min_live_segments` opt.
    min_live_segments :: pos_integer(),
    %% Periodic sweep cadence (ms) and the active timer reference. The
    %% timer is rearmed at the end of every sweep so a long sweep
    %% doesn't pile up overlapping tick messages.
    retention_sweep_interval :: pos_integer(),
    retention_timer :: reference() | undefined,
    %% --- Backpressure ---------------------------------------------------------
    %% Running sum of `.qdata` bytes across all live segments (head and
    %% sealed). Updated on every successful frame write, every rotation,
    %% and every retention sweep. Authoritative source for the
    %% `bytes_total` info/telemetry field and for the hard
    %% `max_total_wal_size` backpressure check.
    bytes_total :: non_neg_integer(),
    %% Cached `length(manifest:live_segments)`. Kept in step with the
    %% manifest by `bootstrap/1`, `install_recovery/2`,
    %% `open_next_segment/1`, and `apply_deletable/2`. Avoids the O(N)
    %% list walk on every append's backpressure check.
    live_segments_count :: non_neg_integer(),
    %% Hard caps on aggregate WAL size and on the number of live
    %% segments. Either being breached causes `append`/`append_batch` to
    %% return `{error, wal_full}` and emit a debounced `[bondy_oplog,
    %% wal, wal_full]` telemetry event. Defaults: 8 GiB / 256 segments.
    max_total_wal_size :: pos_integer(),
    max_live_segments :: pos_integer(),
    %% Most recent `monotonic_time(millisecond)` at which a `wal_full`
    %% telemetry event was emitted. The next emission is suppressed
    %% until at least `wal_full_telemetry_debounce_ms` has elapsed —
    %% this prevents a tight retry loop on the caller's side from
    %% drowning the telemetry pipeline.
    wal_full_last_emit_ms :: integer() | undefined,
    %% Monotonic-millisecond timestamp of the most recent successful
    %% append (single or batch). Drives the `head_lag_ms` gauge in
    %% `info/1`. `undefined` until the first append lands.
    last_append_at_ms :: integer() | undefined,
    %% --- Body codec -----------------------------------------------------------
    %% Compression algorithm applied to each frame's body before
    %% `bondy_oplog_wal_frame:encode/2`. `none` is the v1-compatible
    %% default; `zlib` compresses bodies whose size meets the threshold.
    %% Flag bit 0 on the frame advertises that a body has been
    %% compressed; the algorithm id lives in the first byte of the
    %% compressed body envelope.
    body_compression :: bondy_oplog_wal_codec:algorithm(),
    body_compression_min_bytes :: pos_integer(),
    %% Body encryption. `disabled` is the default and means the writer
    %% emits cleartext bodies; `{enabled, Module}` makes every body go
    %% through `bondy_oplog_wal_codec:encrypt_now/3` against the
    %% writer's current key (resolved on each write via
    %% `Module:current_key/0`). Readers consult the same module via
    %% `Module:lookup_key/1` to resolve historic frames.
    body_encryption :: bondy_oplog_wal_codec:encryption()
}).

-type opts() :: #{
    dir := file:filename_all(),
    origin := bondy_oplog_origin:t(),
    max_segment_bytes => pos_integer(),
    max_batch_bytes => pos_integer(),
    retention => [{atom(), term()}],
    idx_interval_bytes => pos_integer(),
    fsync_mode => per_write | batched,
    batched_fsync_interval => pos_integer(),
    batched_fsync_bytes => pos_integer(),
    group_commit => boolean(),
    group_commit_max => pos_integer(),
    min_live_segments => pos_integer(),
    retention_sweep_interval => pos_integer(),
    max_total_wal_size => pos_integer(),
    max_live_segments => pos_integer(),
    recovery_mode => strict | rescan,
    body_compression => bondy_oplog_wal_codec:algorithm(),
    body_compression_min_bytes => pos_integer(),
    body_encryption => bondy_oplog_wal_codec:encryption()
}.

-type wal() :: pid().

-type segment_id() :: bondy_oplog_wal_segment:segment_id().
-type offset() :: non_neg_integer().
-type position() :: {segment_id(), offset()}.

-export_type([opts/0]).
-export_type([wal/0]).
-export_type([position/0]).

-export([start/2]).
-export([start_link/2]).
-export([child_spec/2]).
-export([open/2]).
-export([close/1]).
-export([append/2]).
-export([append_batch/2]).
-export([sync/1]).
-export([durable_position/1]).
-export([await_durable/3]).
-export([info/1]).
-export([reader_view/1]).
-export([advance_snapshot_watermark/2]).
-export([retention_sweep/1]).
-export([set_committed_segment/2]).
-export([mark_segment_alert/3]).
-export([clear_segment_alert/2]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-define(DEFAULT_MAX_SEGMENT_BYTES, 64 * 1024 * 1024).
-define(SEG_HEADER_BYTES, ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES).
-define(FRAME_HEADER_BYTES, ?BONDY_OPLOG_WAL_FRAME_HEADER_BYTES).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Starts a WAL writer linked to the caller. See `open/2` for the public
contract.
""".
-spec start_link(instance_id(), opts()) ->
    {ok, pid()} | {error, term()}.

start_link(InstanceId, Opts) when
    is_binary(InstanceId), byte_size(InstanceId) > 0, is_map(Opts)
->
    gen_server:start_link(?MODULE, {InstanceId, Opts}, []).

-doc """
Starts a WAL writer **without** linking to the caller. Useful in tests
that exercise init-failure paths, where a linked exit signal would kill
the test process. Production code should prefer `start_link/2` or
`open/2` so the writer participates in supervision.
""".
-spec start(instance_id(), opts()) ->
    {ok, pid()} | {error, term()}.

start(InstanceId, Opts) when
    is_binary(InstanceId), byte_size(InstanceId) > 0, is_map(Opts)
->
    gen_server:start(?MODULE, {InstanceId, Opts}, []).

-doc """
Returns a `supervisor:child_spec/0` for hosting a WAL writer under a
supervisor. Used by `bondy_oplog_instance_sup`, the per-instance
one_for_all subtree that owns the writer, applier, and instance API.
""".
-spec child_spec(instance_id(), opts()) -> supervisor:child_spec().

child_spec(InstanceId, Opts) ->
    #{
        id => {?MODULE, InstanceId},
        start => {?MODULE, start_link, [InstanceId, Opts]},
        restart => permanent,
        shutdown => 30000,
        type => worker,
        modules => [?MODULE]
    }.

-doc """
Opens a per-instance WAL, creating a fresh one or recovering an
existing one transparently.

Returns `{ok, Pid}` where `Pid` is the writer gen_server.

If `{Dir}/{InstanceId}/manifest` does not exist, this is a **fresh
open**: the directory is created, segment 0 is written with its
header, and the initial manifest is fsynced.

If a manifest exists, this is a **recovery open**: `bondy_oplog_wal_recovery`
validates the manifest, cleans orphan files left from interrupted
operations, validates the headers of all live sealed segments,
rebuilds any missing `.qidx` files, scans the head segment forward
break-and-truncate-style to its last valid frame, truncates the file
if necessary, and clamps `consumer.offset` (if present) to a real
frame boundary. The writer resumes appending immediately after the
last recovered frame.

`Opts` must contain:
- `dir` — the parent WAL directory; `InstanceId` is appended.
- `origin` — the 16-byte replica id stamped in each segment header
  (`bondy_oplog_origin:t()`).

Optional:
- `max_segment_bytes` — rotation threshold; defaults to 64 MiB.
- `retention` — proplist persisted in the manifest verbatim.
- `idx_interval_bytes` — sparse index emit interval; defaults to 64 KiB.
- `fsync_mode` — `per_write` (default) or `batched`. Per-write fsyncs
  every `append/2`; batched defers fsync to a size or time boundary
  (see `batched_fsync_*` below) and exposes durability via
  `durable_position/1` and `await_durable/3`.

  **Throughput hazard.** `per_write` ties one fsync to every caller's
  reply — the writer is bounded by the storage device's fsync rate
  (~6 k/s on a typical NVMe). With multiple concurrent appenders the
  reply queue stays full and throughput plateaus at the device fsync
  rate regardless of how many writers are added. Latency p99.9
  scales with concurrency (`N × fsync_us`). Concurrent-writer
  benchmarks (`bench/benchmarks/concurrency_wal.exs`) measure this
  directly.

  Use `per_write` only when the caller needs the WAL replicated to
  storage before its `append/2` returns. For any other shape —
  including the standard `bondy_oplog_instance` write path — prefer
  `batched` plus `await_durable/3` for explicit durability waits.
  The batched mode reaches ~200 k events/s under 16 concurrent
  appenders on the same device, two orders of magnitude better
  than `per_write`, with bounded fsync-interval latency.
- `batched_fsync_interval` — batched-mode time trigger in
  milliseconds; defaults to 50 ms. The writer fsyncs at most this
  long after the first un-fsynced append.
- `batched_fsync_bytes` — batched-mode size trigger; defaults to 1
  MiB. The writer fsyncs when accumulated un-fsynced bytes exceed
  this threshold.

Recovery errors are returned through `start_link/2`'s usual
`{error, Reason}` channel. Possible recovery-time failures:
- `{manifest, _}` — manifest unreadable or fails validation.
- `{instance_id_mismatch, Expected, Found}` — WAL belongs to another
  instance.
- `{head_segment, SegId, Reason}` — head segment header invalid or
  truncate failed.
- `{sealed_segment, SegId, Reason}` — a sealed segment's header
  doesn't match this instance/origin.
- `{consumer_offset, _}` — `consumer.offset` is malformed.
""".
-spec open(instance_id(), opts()) -> {ok, wal()} | {error, term()}.

open(InstanceId, Opts) ->
    start_link(InstanceId, Opts).

-doc """
Stops the WAL writer. The head segment is fsynced and the fd is closed
in `terminate/2`. Idempotent — calling `close/1` on a dead pid returns
`ok`. `is_process_alive/1` is intentionally **not** used: it would race
with the actual stop and tell us nothing the try/catch doesn't already
handle.
""".
-spec close(wal()) -> ok.

close(Pid) when is_pid(Pid) ->
    try gen_server:stop(Pid, normal, 30000) of
        ok -> ok
    catch
        exit:noproc -> ok;
        exit:{noproc, _} -> ok
    end.

-doc """
Appends a single event as a one-element batch frame. Sugar for
`append_batch(Pid, [Event])` that flattens the per-event result.

Returns `{ok, Hlc, {Segment, Offset}}` where:
- `Hlc` is the event's own HLC (taken from its key).
- `Segment` is the head segment id at the time of the append.
- `Offset` is the byte offset of the frame's first byte within the
  segment file. The next-frame offset (used by consumer commits later)
  is `Offset + FrameLen`.

In `per_write` mode every successful `append/2` includes a
`prim_file:datasync/1` and the returned position is durable. In
`batched` mode (`fsync_mode = batched`) the call returns as soon as
the frame has been written; durability is reached at a later fsync
boundary observable via `durable_position/1` or awaitable via
`await_durable/3`.
""".
-spec append(wal(), bondy_oplog_event:t()) ->
    {ok, bondy_oplog_hlc:hlc(), position()}
    | {error, term()}.

append(Pid, #bondy_oplog_event{} = Event) when is_pid(Pid) ->
    case append_batch(Pid, [Event]) of
        {ok, [{Hlc, Pos}]} -> {ok, Hlc, Pos};
        {error, _} = E -> E
    end.

-doc """
Appends a list of events as a single atomic batch frame. Either every
event in the batch is durably appended (and visible to readers) or none
of them is.

`Events` must be a non-empty list of `#bondy_oplog_event{}` records;
HLCs are taken from each event's key and must be strictly ascending in
list order (the writer trusts the caller's ordering; this matches the
contract of `append/2`).

Returns `{ok, [{Hlc, Pos}]}` where each `Hlc` is the corresponding
event's HLC and each `Pos = {Segment, Offset}` is the byte offset of
the **batch frame's start** within the segment. (All events in one
batch share the same frame position; the entries are returned
event-by-event so callers can correlate by HLC without re-walking the
list.)

Pre-rotation: if the encoded batch frame wouldn't fit in the current
segment, the writer rotates **before** writing the batch. A batch never
spans segments.

Rejections (all leave the writer state untouched):
- `{error, empty_batch}` — `Events` is the empty list.
- `{error, {invalid_batch, non_event}}` — `Events` contains a term that
  isn't a `#bondy_oplog_event{}` record.
- `{error, {invalid_batch, hlc_not_monotonic}}` — the events' HLCs are
  not strictly increasing in list order.
- `{error, batch_too_large}` — the encoded body exceeds
  `max_batch_bytes`. (Note: this cap is orthogonal to
  `max_segment_bytes`; a batch that fits the body cap but exceeds the
  segment cap is still written, and the segment is then rotated on
  the next append — `max_segment_bytes` is a soft target, not a hard
  limit.)

Durability semantics match `append/2`: in `per_write` mode the batch
is durable on return; in `batched` mode it is durable at the next
fsync boundary.
""".
-spec append_batch(wal(), [bondy_oplog_event:t(), ...]) ->
    {ok, [{bondy_oplog_hlc:hlc(), position()}, ...]}
    | {error, term()}.

append_batch(Pid, [_ | _] = Events) when is_pid(Pid) ->
    case lists:all(fun is_event/1, Events) of
        true ->
            gen_server:call(Pid, {append_batch, Events}, infinity);
        false ->
            {error, {invalid_batch, non_event}}
    end;
append_batch(Pid, []) when is_pid(Pid) ->
    {error, empty_batch}.

%% @private
is_event(#bondy_oplog_event{}) -> true;
is_event(_) -> false.

-doc """
Forces an fsync of the head segment file descriptor.

In `per_write` mode this is a barrier (every prior `append/2` was
already fsynced); the call still completes the protocol — advancing
`durable_position/1` to the current head and notifying any
`await_durable/3` waiters covered by the new durable boundary. In
`batched` mode this is the user-facing way to force durability.
""".
-spec sync(wal()) -> ok | {error, term()}.

sync(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, sync, infinity).

-doc """
Returns the current durable position `{Segment, Offset}` — the highest
byte offset that has been fsynced to disk.

In `per_write` mode this equals the head position at any quiescent
moment; in `batched` mode it may lag the head by up to one fsync
interval. The result is read from the writer's serialised state so
the pair is always consistent (unlike the `durable_pos_ref` atomics
ref exposed via `reader_view/1`, which may race across segment
rotations).
""".
-spec durable_position(wal()) -> position().

durable_position(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, durable_position, infinity).

-doc """
Blocks until the durable position reaches `{Segment, Offset}`, or
until `Timeout` milliseconds (or `infinity`) elapse.

`Pos` is the offset of the **byte just past** the data the caller
wants durable — the same coordinate as `head_offset` / `durable_offset`
in `info/1` and the same convention applier/consumer code uses for
"the next byte to be written". Equivalently: an append that returned
`{ok, _, {Seg, Off}}` for a frame of length `FrameLen` is durable
when `durable_position/1` returns a position `>= {Seg, Off + FrameLen}`.

Returns:
- `ok` — the position is (or has become) durable.
- `{error, timeout}` — durability not reached within `Timeout`.

In `per_write` mode `await_durable/3` always returns `ok` immediately:
appends are durable on return, so any `Pos <= head_offset` is
already covered.
""".
-spec await_durable(wal(), position(), timeout()) ->
    ok | {error, timeout} | {error, term()}.

await_durable(Pid, {Seg, Off} = Pos, Timeout) when
    is_pid(Pid),
    is_integer(Seg),
    Seg >= 0,
    is_integer(Off),
    Off >= 0,
    (Timeout =:= infinity orelse (is_integer(Timeout) andalso Timeout >= 0))
->
    %% Use a client-side `infinity` `gen_server:call/3` timeout —
    %% the writer enforces `Timeout` internally and replies (with
    %% `{error, timeout}` if applicable) when the deadline fires.
    %% This avoids the server-side waiter being satisfied just as
    %% the client-side gen_server timeout elapses, which would leak
    %% an `{Tag, Reply}` message into the caller's mailbox.
    gen_server:call(Pid, {await_durable, Pos, Timeout}, infinity).

-doc """
Returns a diagnostic snapshot of the writer's state. Suitable for
operator status pages and tests; not a load-bearing protocol surface.

Current shape:

```erlang
#{
    instance_id            => instance_id(),
    dir                    => file:filename_all(),
    origin                 => bondy_oplog_origin:t(),
    max_segment_bytes      => pos_integer(),
    max_batch_bytes        => pos_integer(),
    current_segment        => segment_id(),
    head_offset            => non_neg_integer(),
    durable_segment        => segment_id(),
    durable_offset         => non_neg_integer(),
    first_hlc              => hlc() | undefined,
    last_hlc               => hlc() | undefined,
    append_count           => non_neg_integer(),
    max_seq                => non_neg_integer(),
    fsync_mode             => per_write | batched,
    batched_fsync_interval => pos_integer(),
    batched_fsync_bytes    => pos_integer(),
    group_commit           => boolean(),
    group_commit_max       => pos_integer(),
    fsync_count            => non_neg_integer(),
    pending_fsync_bytes    => non_neg_integer(),
    last_fsync_at          => integer() | undefined,
    waiter_count           => non_neg_integer(),
    live_segments          => [segment_id()],
    live_segments_count    => non_neg_integer(),
    deleted_through        => non_neg_integer(),
    snapshot_watermark     => bondy_oplog_hlc:hlc() | undefined,
    committed_segment      => segment_id(),
    min_live_segments      => pos_integer(),
    retention_sweep_interval => pos_integer(),
    bytes_total            => non_neg_integer(),
    max_total_wal_size     => pos_integer(),
    max_live_segments      => pos_integer(),
    backpressure           => ok
                              | {hard, max_total_wal_size | max_live_segments},
    head_lag_ms            => non_neg_integer() | undefined
}
```

The keys `committed_offset` / `committed_hlc` are stubbed until the
consumer-commit machinery lands.
""".
-spec info(wal()) -> map().

info(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, info).

-doc """
Returns the static + atomics-published state a reader needs to open
itself against this writer:

```erlang
#{
    instance_id      => instance_id(),
    dir              => file:filename_all(),
    origin           => bondy_oplog_origin:t(),
    head_pos_ref     => atomics:atomics_ref(),
    durable_pos_ref  => atomics:atomics_ref(),
    head_pos         => {segment_id(), non_neg_integer()},
    current_segment  => segment_id(),
    live_segments    => [{segment_id(), hlc() | undefined}],
    deleted_through  => segment_id(),
    head_first_hlc   => hlc() | undefined,
    head_idx_entries => [{hlc(), hlc(), non_neg_integer()}]
}
```

`head_pos_ref` is the wait-free reference the reader uses in its hot
loop. `head_pos` is a one-shot consistent snapshot of the writer's
head segment id and head offset, read under the gen_server's serial
handle_call — readers resolving a `tail` start use this instead of
two separate `atomics:get/2` calls which can race with rotation.

`durable_pos_ref` is the sibling atomics ref for the durable
boundary; in `per_write` mode it tracks `head_pos_ref` after every
append, in `batched` mode it may lag by up to one fsync interval.
Cross-segment reads are subject to the same race as `head_pos_ref` —
callers needing a coherent snapshot should use `durable_position/1`
(gen_server-serialised) instead.

`live_segments` carries `{SegmentId, FirstHlc}` pairs as recorded in
the manifest. The head segment's `FirstHlc` is `undefined` until the
next rotation persists it; `head_first_hlc` exposes the writer's live
value so HLC seek can address the head segment via the sparse index.

`head_idx_entries` is the writer's in-memory sparse-index accumulator
for the head segment (entries it has not yet flushed to disk — flush
happens on rotation and on terminate). Readers wrap it via
`bondy_oplog_wal_idx:from_entries/1` to seek the head segment without
a disk round-trip.

`current_segment` and `live_segments` are a snapshot at call time and
may be stale before the reader has finished walking them (the atomics
ref keeps the reader correct even if the writer rotates afterwards).
The reader uses `live_segments` only to resolve `beginning` /
`{offset, Seg, Off}` starts and HLC-seek candidate selection.
""".
-spec reader_view(wal()) -> map().

reader_view(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, reader_view).

-doc """
Records `Hlc` as the new compaction snapshot watermark.

The watermark bounds retention: a segment becomes eligible for
deletion only when every event in it has an HLC `<= watermark`.

The new watermark is persisted to `snapshot.watermark` (tmp+rename
atomic) before the call returns. The advance is followed by an
opportunistic retention sweep — segments that become eligible are
deleted in the same call when possible, but the sweep is best-effort:
a `{error, _}` from the sweep is logged and swallowed so the
watermark advance still returns `ok`.

`Hlc` must be monotonically non-decreasing; a request to move
backwards is rejected with `{error, watermark_regression}`.
""".
-spec advance_snapshot_watermark(wal(), bondy_oplog_hlc:hlc()) ->
    ok | {error, term()}.

advance_snapshot_watermark(Pid, Hlc) when
    is_pid(Pid), is_integer(Hlc), Hlc >= 0
->
    gen_server:call(Pid, {advance_snapshot_watermark, Hlc}).

-doc """
Runs a retention sweep and returns the segments that were deleted and
the bytes freed.

The sweep is the on-disk realisation of the retention policy: a segment `S` is deleted
iff `S < committed_segment` AND `S < snapshot_watermark_segment` AND
the post-sweep live-segment count would remain `>= min_live_segments`.
The manifest is rewritten atomically (tmp+rename); only after the
manifest is durable do the `.qdata` / `.qidx` files unlink. A crash
between manifest commit and unlink leaves orphan files that the
startup orphan-cleanup removes on next open.

Returns `{ok, [SegmentId], FreedBytes}`. The list is in ascending
segment-id order. `FreedBytes` is the total bytes of `.qdata` files
that were unlinked (the `.qidx` rebuild is cheap so it's not counted).
""".
-spec retention_sweep(wal()) ->
    {ok, [segment_id()], non_neg_integer()} | {error, term()}.

retention_sweep(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, retention_sweep).

-doc """
Sets the committed segment id used by the retention sweep.

This is a stub interface for the consumer-commit machinery that lands
later (along with `commit/4` and `committed/1`). For now it lets tests
exercise retention without the full applier loop. `NewSegId` must be
monotonically non-decreasing.
""".
-spec set_committed_segment(wal(), segment_id()) -> ok | {error, term()}.

set_committed_segment(Pid, NewSegId) when
    is_pid(Pid), is_integer(NewSegId), NewSegId >= 0
->
    gen_server:call(Pid, {set_committed_segment, NewSegId}).

-doc """
Records an integrity-scrubber alert against `SegmentId`.

Called by the per-instance `bondy_oplog_wal_scrubber` when it detects
a bad frame in a sealed segment. The segment id is recorded in the
manifest under `scrubber_alerts` and persisted atomically so the alert
survives restart. The segment file itself is left untouched — the
scrubber does not auto-repair; an operator triggers re-derivation
from a peer or a snapshot.

`Reason` is one of the loose atoms reported by the segment walk
(`bad_crc`, `bad_magic`, `truncated`, `sealed_body_decode`).
Subsequent calls for the same segment replace the prior reason
(last-writer-wins — multiple bad frames in one segment still produce
one alert).
""".
-spec mark_segment_alert(wal(), segment_id(), atom()) -> ok | {error, term()}.

mark_segment_alert(Pid, SegmentId, Reason) when
    is_pid(Pid), is_integer(SegmentId), SegmentId >= 0, is_atom(Reason)
->
    gen_server:call(Pid, {mark_segment_alert, SegmentId, Reason}).

-doc """
Clears any integrity-scrubber alert for `SegmentId`.

Intended for operator use after a re-derivation has replaced the
quarantined bytes. Returns `ok` whether or not an alert was present.
""".
-spec clear_segment_alert(wal(), segment_id()) -> ok | {error, term()}.

clear_segment_alert(Pid, SegmentId) when
    is_pid(Pid), is_integer(SegmentId), SegmentId >= 0
->
    gen_server:call(Pid, {clear_segment_alert, SegmentId}).

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init({InstanceId, Opts}) ->
    process_flag(trap_exit, true),
    %% Off-heap inbox — same rationale as `bondy_oplog_instance`. The
    %% WAL writer's mailbox grows whenever fsync stalls or many
    %% concurrent appenders pile up; keeping messages off the main
    %% heap stops minor GC from scanning them on every collection.
    process_flag(message_queue_data, off_heap),
    T0 = erlang:monotonic_time(microsecond),
    case do_open(InstanceId, Opts) of
        {ok, State, RecoveryResult} ->
            Duration = erlang:monotonic_time(microsecond) - T0,
            %% Bootstrap returns `RecoveryResult = undefined`; only
            %% emit the recovery event when the writer actually walked
            %% the recovery pipeline.
            case RecoveryResult of
                undefined -> ok;
                _ -> emit_recovery_telemetry(State, Duration, RecoveryResult)
            end,
            %% The retained WAL's own-origin maximum reaches the instance's
            %% seq counter BEFORE this pid is published. Every minter
            %% resolves the WAL through the registry before it reserves a
            %% seq, so the bump happens-before any reservation; the applier's
            %% replay then has nothing left to seed, only to install
            %% (`proofs/tla/SeqSeed_CkptEarlyMint.cfg` is the window this
            %% closes). A WAL opened with no instance behind it (the library
            %% API) has no counter to seed.
            ok = seed_instance_seq(InstanceId, State#state.max_seq),
            ok = bondy_oplog_registry:set_wal_pid(InstanceId, self()),
            {ok, arm_retention_timer(State)};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({append_batch, Events}, From, State0) ->
    case use_group_commit(State0) of
        true ->
            group_commit_append(State0, From, Events);
        false ->
            handle_inline_append(State0, Events)
    end;
handle_call(sync, _From, #state{head_fd = Fd} = State) when Fd =/= undefined ->
    case do_fsync_head(State) of
        {ok, State1} -> {reply, ok, State1};
        {error, _} = E -> {reply, E, State}
    end;
handle_call(durable_position, _From, State) ->
    {reply, {State#state.durable_segment_id, State#state.durable_offset},
        State};
handle_call({await_durable, Pos, Timeout}, From, State) ->
    handle_await_durable(Pos, Timeout, From, State);
handle_call(info, _From, State) ->
    {reply, build_info(State), State};
handle_call(reader_view, _From, State) ->
    {reply, build_reader_view(State), State};
handle_call({advance_snapshot_watermark, Hlc}, _From, State0) ->
    case do_advance_snapshot_watermark(State0, Hlc) of
        {ok, State1} ->
            State2 = sweep_swallowing_errors(State1, watermark_advance),
            {reply, ok, State2};
        {error, _} = E ->
            {reply, E, State0}
    end;
handle_call(retention_sweep, _From, State0) ->
    case do_retention_sweep(State0) of
        {ok, Deleted, Freed, State1} ->
            {reply, {ok, Deleted, Freed}, State1};
        {error, _} = E ->
            {reply, E, State0}
    end;
handle_call({set_committed_segment, NewSegId}, _From, State0) ->
    case do_set_committed_segment(State0, NewSegId) of
        {ok, State1} ->
            State2 = sweep_swallowing_errors(State1, committed_advance),
            {reply, ok, State2};
        {error, _} = E ->
            {reply, E, State0}
    end;
handle_call({mark_segment_alert, SegId, Reason}, _From, State0) ->
    case do_mark_segment_alert(State0, SegId, Reason) of
        {ok, State1} -> {reply, ok, State1};
        {error, _} = E -> {reply, E, State0}
    end;
handle_call({clear_segment_alert, SegId}, _From, State0) ->
    case do_clear_segment_alert(State0, SegId) of
        {ok, State1} -> {reply, ok, State1};
        {error, _} = E -> {reply, E, State0}
    end;
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Batched-mode interval timer fired. Reset the timer ref (we re-arm on
%% the next un-fsynced append) and fsync if any bytes are pending. If
%% the writer crashes between scheduling and firing, the timer message
%% is dropped with the process exit.
handle_info(flush_tick, State0) ->
    State1 = State0#state{flush_timer = undefined},
    case maybe_batched_fsync(State1) of
        {ok, State2} -> {noreply, State2};
        {error, _} -> {noreply, State1}
    end;
%% `await_durable/3` deadline elapsed. Remove the matching waiter from
%% the pending list (if still present) and reply `{error, timeout}`.
%% If the waiter was already satisfied on an fsync that arrived ahead of
%% the timer message, the lookup is empty and we drop the timer event.
handle_info({timeout, _TRef, {await_timeout, WaiterId}}, State) ->
    {noreply, expire_waiter(WaiterId, State)};
%% Periodic retention safety-net. Best-effort: errors are
%% logged inside `sweep_swallowing_errors/2` and the timer rearms
%% either way so a transient I/O failure doesn't stop the cadence.
handle_info(retention_tick, State0) ->
    State1 = State0#state{retention_timer = undefined},
    State2 = sweep_swallowing_errors(State1, periodic),
    {noreply, arm_retention_timer(State2)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{head_fd = undefined} = State) ->
    _ = cancel_flush_timer(State),
    _ = cancel_retention_timer(State),
    ok;
terminate(
    _Reason,
    #state{
        head_fd = Fd,
        segment_id = Seg,
        current_offset = Off
    } = State0
) ->
    _ = cancel_retention_timer(State0),
    State =
        case bondy_mst_io:datasync(Fd) of
            ok ->
                %% The head fd is now durable up to `current_offset`.
                %% Advance the durable boundary so any waiter at or below
                %% head receives `ok` (their position IS durable) before
                %% the writer exits; pollers of `durable_pos_ref` see the
                %% accurate final state instead of a stale snapshot. Above-
                %% head waiters get the natural `noproc` exit (their
                %% position is unreachable in this writer's lifetime). The
                %% call also cancels the flush timer as part of its
                %% bookkeeping.
                advance_durable(State0, Seg, Off);
            {error, _} ->
                _ = cancel_flush_timer(State0),
                State0
        end,
    %% Flush the head segment's sparse index. Best-effort: on failure we
    %% log and continue closing the fd. Recovery rebuilds the `.qidx`
    %% from a segment scan if it's missing or stale.
    _ = flush_head_idx(State),
    _ = prim_file:close(Fd),
    ok.

%% @private
%% Cancel any active batched-fsync interval timer. Returns the state
%% with `flush_timer = undefined`. Pending `await_durable/3` waiters
%% are not replied to here — clients' `gen_server:call/3` raises with
%% the writer's exit signal, which is the natural shutdown contract.
cancel_flush_timer(#state{flush_timer = undefined} = S) ->
    S;
cancel_flush_timer(#state{flush_timer = TRef} = S) when is_reference(TRef) ->
    _ = erlang:cancel_timer(TRef),
    S#state{flush_timer = undefined}.

%% @private
%% Cancel any active periodic retention timer; idempotent. Used on
%% terminate and on rearm (where the just-fired tick is already
%% accounted for in the caller).
cancel_retention_timer(#state{retention_timer = undefined} = S) ->
    S;
cancel_retention_timer(#state{retention_timer = TRef} = S) when
    is_reference(TRef)
->
    _ = erlang:cancel_timer(TRef),
    S#state{retention_timer = undefined}.

%% @private
%% Arm the periodic retention timer. Idempotent: if a timer is already
%% pending, leave it alone. The tick handler clears the ref before
%% running the sweep so a second arm is always safe.
arm_retention_timer(#state{retention_timer = T} = S) when
    is_reference(T)
->
    S;
arm_retention_timer(#state{retention_sweep_interval = Ms} = S) ->
    TRef = erlang:send_after(Ms, self(), retention_tick),
    S#state{retention_timer = TRef}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_open(InstanceId, Opts) ->
    case maps:find(origin, Opts) of
        {ok, Origin} ->
            case bondy_oplog_origin:validate(Origin) of
                ok ->
                    open_after_origin_validated(InstanceId, Origin, Opts);
                {error, R} ->
                    {error, {invalid_origin, R}}
            end;
        error ->
            {error, {missing_opt, origin}}
    end.

%% @private
open_after_origin_validated(InstanceId, Origin, Opts) ->
    case validate_durability_opts(Opts) of
        ok ->
            case validate_retention_opts(Opts) of
                ok -> open_after_opts_validated(InstanceId, Origin, Opts);
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Validate `min_live_segments` (pos int) and `retention_sweep_interval`
%% (pos int ms). Both are init-time opts; defaults are applied later.
validate_retention_opts(Opts) ->
    case maps:find(min_live_segments, Opts) of
        {ok, M} when is_integer(M), M >= 1 ->
            validate_retention_sweep_interval(Opts);
        {ok, M} ->
            {error, {invalid_opt, min_live_segments, M}};
        error ->
            validate_retention_sweep_interval(Opts)
    end.

%% @private
validate_retention_sweep_interval(Opts) ->
    case maps:find(retention_sweep_interval, Opts) of
        {ok, I} when is_integer(I), I >= 1 ->
            validate_backpressure_opts(Opts);
        {ok, I} ->
            {error, {invalid_opt, retention_sweep_interval, I}};
        error ->
            validate_backpressure_opts(Opts)
    end.

%% @private
%% Validate `max_total_wal_size` and `max_live_segments` (both pos ints).
%% These are the hard backpressure limits; crossing either causes
%% `append`/`append_batch` to return `{error, wal_full}`.
validate_backpressure_opts(Opts) ->
    case maps:find(max_total_wal_size, Opts) of
        {ok, T} when is_integer(T), T >= 1 ->
            validate_max_live_segments(Opts);
        {ok, T} ->
            {error, {invalid_opt, max_total_wal_size, T}};
        error ->
            validate_max_live_segments(Opts)
    end.

%% @private
validate_max_live_segments(Opts) ->
    case maps:find(max_live_segments, Opts) of
        {ok, M} when is_integer(M), M >= 1 ->
            validate_recovery_mode(Opts);
        {ok, M} ->
            {error, {invalid_opt, max_live_segments, M}};
        error ->
            validate_recovery_mode(Opts)
    end.

%% @private
%% Validate `recovery_mode`: must be `strict` (default) or `rescan`.
%% In `rescan`, head-segment recovery skips corrupt frames and emits a
%% telemetry event with the skipped byte range; opt-in per instance.
validate_recovery_mode(Opts) ->
    case maps:find(recovery_mode, Opts) of
        {ok, M} when M =:= strict; M =:= rescan ->
            validate_body_compression(Opts);
        {ok, M} ->
            {error, {invalid_opt, recovery_mode, M}};
        error ->
            validate_body_compression(Opts)
    end.

%% @private
%% Validate `body_compression`: `none` (default), `zlib`, or `lz4`.
%% `lz4` is reserved (needs a NIF that isn't built in today) and is
%% rejected as `unsupported_codec` so an operator who flips it on by
%% mistake gets a loud failure at startup instead of silent fall-back.
%% On success, also validate the optional `body_compression_min_bytes`
%% threshold.
validate_body_compression(Opts) ->
    Algo = maps:get(body_compression, Opts, none),
    case bondy_oplog_wal_codec:validate_algorithm(Algo) of
        ok ->
            validate_body_compression_min_bytes(Opts);
        {error, _} = E ->
            E
    end.

%% @private
validate_body_compression_min_bytes(Opts) ->
    case maps:find(body_compression_min_bytes, Opts) of
        {ok, N} when is_integer(N), N >= 1 ->
            validate_body_encryption(Opts);
        {ok, N} ->
            {error, {invalid_opt, body_compression_min_bytes, N}};
        error ->
            validate_body_encryption(Opts)
    end.

%% @private
%% Validate `body_encryption`: `disabled` (default) or `{enabled,
%% Module}` where `Module` implements the
%% `bondy_oplog_wal_key_registry` behaviour. The startup check loads
%% the module, verifies the two callbacks are exported, and calls
%% `current_key/0` to ensure the writer can resolve a key before it
%% accepts any append. Failure modes surface as typed errors so
%% misconfiguration is visible to the operator at boot, not at the
%% first encrypted write.
validate_body_encryption(Opts) ->
    Cfg = maps:get(body_encryption, Opts, disabled),
    bondy_oplog_wal_codec:validate_encryption(Cfg).

%% @private
%% Reject malformed `fsync_mode` / interval / size / batch opts at init
%% time so the gen_server doesn't start with a state that would explode
%% on first batched-mode timer arming or oversize-batch comparison.
validate_durability_opts(Opts) ->
    case validate_group_commit_opts(Opts) of
        ok ->
            case
                maps:get(fsync_mode, Opts, ?BONDY_OPLOG_WAL_FSYNC_MODE_DEFAULT)
            of
                per_write ->
                    validate_batch_opts(Opts);
                batched ->
                    case validate_batched_opts(Opts) of
                        ok -> validate_batch_opts(Opts);
                        {error, _} = E -> E
                    end;
                Other ->
                    {error, {invalid_opt, fsync_mode, Other}}
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Validate the group-commit opts. `group_commit` (bool) applies to both
%% fsync modes — though it only changes behaviour in `per_write` — so it
%% is validated ahead of the mode dispatch. `group_commit_max` must be a
%% positive integer.
validate_group_commit_opts(Opts) ->
    case maps:get(group_commit, Opts, ?BONDY_OPLOG_WAL_GROUP_COMMIT_DEFAULT) of
        Bool when is_boolean(Bool) ->
            case
                maps:get(
                    group_commit_max,
                    Opts,
                    ?BONDY_OPLOG_WAL_GROUP_COMMIT_MAX_DEFAULT
                )
            of
                Max when is_integer(Max), Max >= 1 ->
                    ok;
                Max ->
                    {error, {invalid_opt, group_commit_max, Max}}
            end;
        Other ->
            {error, {invalid_opt, group_commit, Other}}
    end.

%% @private
%% Validate `max_batch_bytes`: must be a positive integer if supplied.
%% The cap is a memory bound on a single atomic batch's encoded body;
%% it is intentionally orthogonal to `max_segment_bytes` (the writer
%% pre-rotates before any batch that wouldn't fit in the current
%% segment, regardless of where the batch cap lives).
validate_batch_opts(Opts) ->
    case maps:find(max_batch_bytes, Opts) of
        {ok, MaxBatch} when is_integer(MaxBatch), MaxBatch >= 1 ->
            ok;
        {ok, MaxBatch} ->
            {error, {invalid_opt, max_batch_bytes, MaxBatch}};
        error ->
            ok
    end.

%% @private
validate_batched_opts(Opts) ->
    Interval = maps:get(
        batched_fsync_interval,
        Opts,
        ?BONDY_OPLOG_WAL_BATCHED_FSYNC_INTERVAL_DEFAULT_MS
    ),
    Bytes = maps:get(
        batched_fsync_bytes,
        Opts,
        ?BONDY_OPLOG_WAL_BATCHED_FSYNC_BYTES_DEFAULT
    ),
    case is_integer(Interval) andalso Interval >= 1 of
        false ->
            {error, {invalid_opt, batched_fsync_interval, Interval}};
        true ->
            case is_integer(Bytes) andalso Bytes >= 1 of
                false -> {error, {invalid_opt, batched_fsync_bytes, Bytes}};
                true -> ok
            end
    end.

%% @private
open_after_opts_validated(InstanceId, Origin, Opts) ->
    case maps:find(dir, Opts) of
        {ok, BaseDir} ->
            Dir = per_instance_dir(BaseDir, InstanceId),
            MaxBytes = maps:get(
                max_segment_bytes, Opts, ?DEFAULT_MAX_SEGMENT_BYTES
            ),
            MaxBatch = maps:get(
                max_batch_bytes,
                Opts,
                ?BONDY_OPLOG_WAL_MAX_BATCH_BYTES_DEFAULT
            ),
            Retention = maps:get(retention, Opts, []),
            IdxInterval = maps:get(
                idx_interval_bytes,
                Opts,
                ?BONDY_OPLOG_WAL_IDX_DEFAULT_INTERVAL_BYTES
            ),
            FsyncMode = maps:get(
                fsync_mode, Opts, ?BONDY_OPLOG_WAL_FSYNC_MODE_DEFAULT
            ),
            Interval = maps:get(
                batched_fsync_interval,
                Opts,
                ?BONDY_OPLOG_WAL_BATCHED_FSYNC_INTERVAL_DEFAULT_MS
            ),
            Bytes = maps:get(
                batched_fsync_bytes,
                Opts,
                ?BONDY_OPLOG_WAL_BATCHED_FSYNC_BYTES_DEFAULT
            ),
            GroupCommit = maps:get(
                group_commit, Opts, ?BONDY_OPLOG_WAL_GROUP_COMMIT_DEFAULT
            ),
            GroupCommitMax = maps:get(
                group_commit_max,
                Opts,
                ?BONDY_OPLOG_WAL_GROUP_COMMIT_MAX_DEFAULT
            ),
            MinLive = maps:get(
                min_live_segments,
                Opts,
                ?BONDY_OPLOG_WAL_MIN_LIVE_SEGMENTS_DEFAULT
            ),
            SweepInterval = maps:get(
                retention_sweep_interval,
                Opts,
                ?BONDY_OPLOG_WAL_RETENTION_SWEEP_INTERVAL_DEFAULT_MS
            ),
            MaxTotal = maps:get(
                max_total_wal_size,
                Opts,
                ?BONDY_OPLOG_WAL_MAX_TOTAL_WAL_SIZE_DEFAULT
            ),
            MaxLive = maps:get(
                max_live_segments,
                Opts,
                ?BONDY_OPLOG_WAL_MAX_LIVE_SEGMENTS_DEFAULT
            ),
            RecoveryMode = maps:get(recovery_mode, Opts, strict),
            BodyCompression = maps:get(body_compression, Opts, none),
            BodyCompressionMin = maps:get(
                body_compression_min_bytes,
                Opts,
                ?BONDY_OPLOG_WAL_BODY_COMPRESSION_MIN_BYTES_DEFAULT
            ),
            BodyEncryption = maps:get(body_encryption, Opts, disabled),
            State0 = #state{
                instance_id = InstanceId,
                dir = Dir,
                origin = Origin,
                max_segment_bytes = MaxBytes,
                max_batch_bytes = MaxBatch,
                retention = Retention,
                segment_id = 0,
                current_offset = ?SEG_HEADER_BYTES,
                max_seq = 0,
                append_count = 0,
                idx_interval_bytes = IdxInterval,
                idx_acc = bondy_oplog_wal_idx:new(IdxInterval),
                fsync_mode = FsyncMode,
                batched_fsync_interval = Interval,
                batched_fsync_bytes = Bytes,
                group_commit = GroupCommit,
                group_commit_max = GroupCommitMax,
                fsync_count = 0,
                pending_fsync_bytes = 0,
                last_fsync_at = undefined,
                flush_timer = undefined,
                durable_segment_id = 0,
                durable_offset = ?SEG_HEADER_BYTES,
                waiters = [],
                snapshot_watermark = undefined,
                committed_segment = 0,
                min_live_segments = MinLive,
                retention_sweep_interval = SweepInterval,
                retention_timer = undefined,
                bytes_total = 0,
                live_segments_count = 0,
                max_total_wal_size = MaxTotal,
                max_live_segments = MaxLive,
                wal_full_last_emit_ms = undefined,
                last_append_at_ms = undefined,
                body_compression = BodyCompression,
                body_compression_min_bytes = BodyCompressionMin,
                body_encryption = BodyEncryption
            },
            open_or_recover(
                Dir,
                InstanceId,
                Origin,
                IdxInterval,
                RecoveryMode,
                BodyEncryption,
                State0
            );
        error ->
            {error, {missing_opt, dir}}
    end.

%% @private
%% Branches on whether the WAL directory has been used before:
%%
%% - No manifest: this is a fresh WAL. Create the directory and the
%%   first segment (`bootstrap/1`).
%% - Manifest exists: this WAL has prior state. Run the recovery
%%   procedure (`bondy_oplog_wal_recovery`) to validate the manifest,
%%   clean orphans, scan and truncate the head segment, rebuild missing
%%   `.qidx` files, and clamp the consumer offset to a real frame
%%   boundary.
open_or_recover(
    Dir,
    InstanceId,
    Origin,
    IdxInterval,
    RecoveryMode,
    BodyEncryption,
    State0
) ->
    case filelib:ensure_path(Dir) of
        ok ->
            ManifestPath = filename:join(
                Dir, ?BONDY_OPLOG_WAL_MANIFEST_FILENAME
            ),
            case filelib:is_regular(ManifestPath) of
                false ->
                    case bootstrap(State0) of
                        {ok, State} -> {ok, State, undefined};
                        {error, _} = E -> E
                    end;
                true ->
                    case
                        bondy_oplog_wal_recovery:recover(
                            Dir,
                            InstanceId,
                            Origin,
                            #{
                                idx_interval_bytes => IdxInterval,
                                recovery_mode => RecoveryMode,
                                body_encryption => BodyEncryption
                            }
                        )
                    of
                        {ok, Result} ->
                            case install_recovery(State0, Result) of
                                {ok, State} -> {ok, State, Result};
                                {error, _} = E -> E
                            end;
                        {error, _} = E ->
                            E
                    end
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% An instance id names ONE directory component: every instance passed
%% `bondy_oplog_path:validate_instance_id/1` at admission
%% (`bondy_oplog_instance_dyn_sup:start_instance/2`), which refuses `/`, so
%% this join cannot turn the id into path structure. That check is what
%% covers this call — `BaseDir` here is an explicit `wal_dir` or the `/tmp`
%% default as often as it is a storage path, and only the latter goes
%% through `bondy_oplog_path:storage_path/3`.
per_instance_dir(BaseDir, InstanceId) ->
    filename:join(BaseDir, InstanceId).

%% @private
seed_instance_seq(_InstanceId, 0) ->
    ok;
seed_instance_seq(InstanceId, MaxSeq) ->
    case bondy_oplog_registry:instance_pid(InstanceId) of
        undefined -> ok;
        Pid -> bondy_oplog_instance:seed_seq(Pid, MaxSeq)
    end.

%% @private
%% Builds a `#state{}` from the recovery result and publishes the head
%% atomics. The recovery procedure already opened the head fd R/W and
%% positioned it past the last valid frame; we only need to wrap it
%% in state plus initialise the atomics ref the readers use.
install_recovery(State0, Result) ->
    #{
        manifest := Manifest,
        head_fd := Fd,
        head_segment_id := SegId,
        head_offset := Off,
        first_hlc := FirstHlc,
        last_hlc := LastHlc,
        append_count := N,
        max_seq := MaxSeq,
        idx_acc := IdxAcc
    } = Result,
    HeadRef = atomics:new(2, [{signed, false}]),
    DurableRef = atomics:new(2, [{signed, false}]),
    publish_head_pos(HeadRef, SegId, Off),
    %% On recovery, every frame on disk has been fsynced (the head's
    %% break-and-truncate scan only accepts CRC-valid frames, and the
    %% writer datasyncs before publishing head_pos on every prior
    %% successful append). Durable ≡ head at this instant.
    publish_durable_pos(DurableRef, SegId, Off),
    Watermark = read_snapshot_watermark_lenient(State0#state.dir),
    CommittedSeg = bondy_oplog_wal_manifest:deleted_through(Manifest),
    BytesTotal = sum_live_segment_bytes(State0#state.dir, Manifest),
    LiveCount = length(bondy_oplog_wal_manifest:live_segments(Manifest)),
    State = State0#state{
        head_fd = Fd,
        segment_id = SegId,
        current_offset = Off,
        first_hlc = FirstHlc,
        last_hlc = LastHlc,
        append_count = N,
        max_seq = MaxSeq,
        manifest = Manifest,
        head_pos_ref = HeadRef,
        idx_acc = IdxAcc,
        durable_pos_ref = DurableRef,
        durable_segment_id = SegId,
        durable_offset = Off,
        snapshot_watermark = Watermark,
        committed_segment = CommittedSeg,
        bytes_total = BytesTotal,
        live_segments_count = LiveCount
    },
    {ok, State}.

%% @private
%% Sum the on-disk sizes of every `.qdata` named by the manifest's
%% `live_segments`. A missing file (race or torn unlink) contributes 0;
%% recovery's orphan cleanup already runs before this is called, so a
%% gap here only matters if the segment was truly lost — in which case
%% the writer is about to error out anyway.
sum_live_segment_bytes(Dir, Manifest) ->
    Ids = [Id || {Id, _} <- bondy_oplog_wal_manifest:live_segments(Manifest)],
    lists:foldl(
        fun(Id, Acc) -> Acc + segment_size_or_zero(Dir, Id) end,
        0,
        Ids
    ).

%% @private
segment_size_or_zero(Dir, SegId) ->
    case prim_file:read_file_info(segment_path(Dir, SegId)) of
        {ok, #file_info{size = S}} -> S;
        _ -> 0
    end.

%% @private
%% The snapshot watermark is a soft retention hint, not a load-bearing
%% invariant. A missing file means "no watermark yet"; a corrupt file
%% (wrong version, missing field) is logged at WARNING and treated as
%% `undefined` — the next `advance_snapshot_watermark/2` overwrites it
%% atomically. Failing to open the WAL over a corrupt hint would be
%% disproportionate.
read_snapshot_watermark_lenient(Dir) ->
    case bondy_oplog_wal_state:read_snapshot_watermark(Dir) of
        {ok, Watermark} ->
            Watermark;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "snapshot.watermark unreadable; proceeding with no "
                    "watermark — the next advance_snapshot_watermark/2 "
                    "will overwrite it",
                dir => Dir,
                reason => Reason
            }),
            undefined
    end.

%% @private
bootstrap(#state{} = State) ->
    SegId = State#state.segment_id,
    SegPath = segment_path(State#state.dir, SegId),
    case
        bondy_oplog_wal_segment:create(
            SegPath, SegId, State#state.instance_id, State#state.origin
        )
    of
        {ok, Fd, _Header} ->
            Manifest = bondy_oplog_wal_manifest:new(
                State#state.instance_id, SegId, State#state.retention
            ),
            case bondy_oplog_wal_manifest:write(State#state.dir, Manifest) of
                ok ->
                    HeadRef = atomics:new(2, [{signed, false}]),
                    DurableRef = atomics:new(2, [{signed, false}]),
                    publish_head_pos(HeadRef, SegId, ?SEG_HEADER_BYTES),
                    publish_durable_pos(
                        DurableRef, SegId, ?SEG_HEADER_BYTES
                    ),
                    %% Fresh-open: segment header is datasync'd inside
                    %% `bondy_oplog_wal_segment:create/4`, so durable
                    %% equals head from the first instant after open.
                    {ok, State#state{
                        head_fd = Fd,
                        manifest = Manifest,
                        head_pos_ref = HeadRef,
                        durable_pos_ref = DurableRef,
                        durable_segment_id = SegId,
                        durable_offset = ?SEG_HEADER_BYTES,
                        bytes_total = ?SEG_HEADER_BYTES,
                        live_segments_count = 1
                    }};
                {error, _} = E ->
                    %% The .qdata is on disk but the manifest write
                    %% failed — without a manifest the segment is an
                    %% orphan that would confuse recovery. Roll back
                    %% here so retries see a clean directory.
                    _ = prim_file:close(Fd),
                    _ = prim_file:delete(SegPath),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
segment_path(Dir, SegId) ->
    filename:join(Dir, bondy_oplog_wal_segment:filename(SegId)).

%% NOTE (append-batch encoding): the batch body is encoded and
%% validated against `max_batch_bytes`, pre-rotating if the frame won't
%% fit in the current segment, then the frame is written and the
%% per-event return entries bound.
%%
%% Pre-rotation is the atomicity guarantee: a batch is either fully in
%% segment N or fully in segment N+1, never split. `max_batch_bytes` is
%% the memory bound on the encoded body; `max_segment_bytes` is a soft
%% cap that may be exceeded by a single oversized batch (segments grow
%% to hold their last frame, then the next append rotates). Callers
%% that want strict segment sizing should set `max_batch_bytes =<
%% max_segment_bytes - SEG_HEADER_BYTES - FRAME_HEADER_BYTES`.

%% @private
%% Group commit applies only to `per_write` mode (the durable-on-return
%% mode). `batched` already coalesces by size/time and replies before the
%% fsync, so it needs no boxcar.
use_group_commit(#state{group_commit = true, fsync_mode = per_write}) ->
    true;
use_group_commit(#state{}) ->
    false.

%% @private
%% The non-group-commit append path (batched mode, or group commit
%% disabled). Write + per-call durability + reply. Behaviour identical to
%% the historical `handle_call({append_batch, …})`.
handle_inline_append(State0, Events) ->
    case do_append_batch(State0, Events) of
        {ok, Entries, State1} ->
            State2 = emit_append_telemetry(State1, Entries),
            {reply, {ok, Entries}, State2};
        {wal_full, Reason} ->
            State1 = emit_wal_full_telemetry(State0, Reason),
            {reply, {error, wal_full}, State1};
        {fatal, Reason, State1} ->
            %% Rotation failed *after* the old segment fd was closed.
            %% The writer cannot serve further requests safely; stop so
            %% the supervisor can restart and recovery (run from `init/1`)
            %% reconciles the on-disk state. We reply to this caller with
            %% the underlying reason so the integration layer can surface
            %% a meaningful error before the gen_server exits.
            ?LOG_ERROR(#{
                description =>
                    "bondy_oplog_wal stopping after a non-recoverable "
                    "rotation failure; supervisor restart will run "
                    "recovery to reconcile the on-disk state",
                reason => Reason
            }),
            {stop, Reason, {error, Reason}, State1};
        {error, _} = E ->
            {reply, E, State0}
    end.

%% @private
%% Group-commit (boxcar) path for per_write mode. Write the first batch's
%% frame WITHOUT fsyncing, then drain any concurrently-queued
%% `append_batch` calls from the mailbox and write each (no fsync). One
%% `datasync` then makes the whole group durable before any caller is
%% replied — so every reply still observes the per_write durable-on-return
%% contract, but a single fsync amortises across the group.
group_commit_append(State0, From, Events) ->
    case do_write_batch(State0, Events) of
        {ok, Entries, State1, _FrameLen} ->
            State2 = emit_append_telemetry(State1, Entries),
            %% Acc = {OkReplies, ErrReplies}. Ok callers ride the shared
            %% group fsync; err/wal_full callers wrote nothing and carry
            %% their own error, but are replied together for simplicity.
            Acc0 = {[{From, {ok, Entries}}], []},
            Remaining = State2#state.group_commit_max - 1,
            case drain_queued_appends(State2, Acc0, Remaining) of
                {ok, {Oks, Errs}, StateN} ->
                    flush_group(StateN, Oks, Errs);
                {fatal, Reason, FatalFrom, {Oks, Errs}, StateF} ->
                    %% A drained batch hit a fatal rotation failure (fd
                    %% gone). Be conservative: reply an error to every
                    %% caller in the group — the good frames may or may
                    %% not have reached disk; recovery's break-and-
                    %% truncate reconciles the tail on restart and a
                    %% client retry is idempotent (content-addressed).
                    %% Then stop for a supervisor restart + recovery.
                    reply_all([{F, {error, Reason}} || {F, _} <- Oks]),
                    reply_all(Errs),
                    gen_server:reply(FatalFrom, {error, Reason}),
                    ?LOG_ERROR(#{
                        description =>
                            "bondy_oplog_wal stopping after a "
                            "non-recoverable rotation failure during a "
                            "group commit; supervisor restart will run "
                            "recovery to reconcile the on-disk state",
                        reason => Reason
                    }),
                    {stop, Reason, StateF}
            end;
        {wal_full, Reason} ->
            State1 = emit_wal_full_telemetry(State0, Reason),
            {reply, {error, wal_full}, State1};
        {fatal, Reason, State1} ->
            ?LOG_ERROR(#{
                description =>
                    "bondy_oplog_wal stopping after a non-recoverable "
                    "rotation failure; supervisor restart will run "
                    "recovery to reconcile the on-disk state",
                reason => Reason
            }),
            {stop, Reason, {error, Reason}, State1};
        {error, _} = E ->
            {reply, E, State0}
    end.

%% @private
%% Pull further queued `{append_batch, _}` gen_server calls out of the
%% mailbox (in arrival order — selective receive preserves order among
%% matching messages) and write each frame WITHOUT fsyncing, until the
%% mailbox has no more (`after 0`) or the per-group cap is reached. Other
%% message types are left untouched in the mailbox for normal dispatch
%% after this `handle_call` returns. Accumulates `{From, Reply}` pairs.
%% The selective `receive` scans the mailbox per iteration, so total work
%% is bounded by `group_commit_max` (the recursion cap), not the mailbox
%% depth unboundedly.
drain_queued_appends(State, Acc, 0) ->
    {ok, Acc, State};
drain_queued_appends(State, {Oks, Errs} = Acc, N) ->
    receive
        {'$gen_call', From, {append_batch, Events}} ->
            case do_write_batch(State, Events) of
                {ok, Entries, State1, _FrameLen} ->
                    State2 = emit_append_telemetry(State1, Entries),
                    drain_queued_appends(
                        State2,
                        {[{From, {ok, Entries}} | Oks], Errs},
                        N - 1
                    );
                {wal_full, Reason} ->
                    State1 = emit_wal_full_telemetry(State, Reason),
                    drain_queued_appends(
                        State1,
                        {Oks, [{From, {error, wal_full}} | Errs]},
                        N - 1
                    );
                {error, _} = E ->
                    drain_queued_appends(
                        State, {Oks, [{From, E} | Errs]}, N - 1
                    );
                {fatal, Reason, State1} ->
                    {fatal, Reason, From, Acc, State1}
            end
    after 0 ->
        {ok, Acc, State}
    end.

%% @private
%% One datasync makes every frame written in this group durable, then all
%% callers are replied. On a datasync failure the ok-write callers get the
%% error (per_write promised durability); err/wal_full callers keep their
%% own replies. Offsets stay advanced; recovery truncates any non-durable
%% tail on next open.
flush_group(StateN, Oks, Errs) ->
    case do_fsync_head(StateN) of
        {ok, StateD} ->
            reply_all(Oks),
            reply_all(Errs),
            {noreply, StateD};
        {error, Reason} ->
            reply_all([{F, {error, Reason}} || {F, _} <- Oks]),
            reply_all(Errs),
            {noreply, StateN}
    end.

%% @private
reply_all(Replies) ->
    lists:foreach(
        fun({From, Reply}) -> gen_server:reply(From, Reply) end, Replies
    ).

%% @private
%% Single-call append: write the frame, then apply per-call durability —
%% a `per_write` fsync now (returning durable), or a `batched`-mode
%% accumulate + maybe-trigger. Contract unchanged: `{ok, Entries, State}`
%% on success; a per_write datasync failure surfaces as `{error, Reason}`
%% (the caller keeps `State0` — recovery's break-and-truncate reconciles
%% the non-durable tail on next open).
do_append_batch(State0, Events) ->
    case do_write_batch(State0, Events) of
        {ok, Entries, State1, FrameLen} ->
            case post_write_durability(State1, FrameLen) of
                {ok, State2} -> {ok, Entries, State2};
                {error, _} = E -> E
            end;
        Other ->
            Other
    end.

%% @private
%% Write a batch frame to the head segment WITHOUT fsyncing. Validates
%% HLC monotonicity and the batch-size cap, applies backpressure and
%% pre-rotation, then appends the frame. Returns
%% `{ok, Entries, State, FrameLen}` (durability deferred to the caller),
%% or `{wal_full, _}` / `{fatal, _, _}` / `{error, _}`.
do_write_batch(#state{max_batch_bytes = MaxBatch} = State0, Events) ->
    Keys = [bondy_oplog_event:key(E) || E <- Events],
    Hlcs = [bondy_oplog_event:key_hlc(K) || K <- Keys],
    BatchMaxSeq = lists:max([bondy_oplog_event:key_seq(K) || K <- Keys]),
    case is_strictly_increasing(Hlcs) of
        false ->
            {error, {invalid_batch, hlc_not_monotonic}};
        true ->
            RawBody = term_to_binary(
                Events, [{minor_version, 2}, deterministic]
            ),
            RawSize = byte_size(RawBody),
            case RawSize > MaxBatch of
                true ->
                    {error, batch_too_large};
                false ->
                    %% Compress *after* the `max_batch_bytes` check —
                    %% the cap bounds the writer's in-memory footprint
                    %% for the encoded batch, which is the raw body
                    %% regardless of whether it ends up compressed.
                    %% FrameLen, rotation, and backpressure all run on
                    %% the post-codec size: a compressed body shrinks
                    %% the frame, so segment budget computations must
                    %% reflect what actually goes to disk.
                    {Flags, EncodedBody} =
                        bondy_oplog_wal_codec:encode_body(
                            RawBody, codec_opts(State0)
                        ),
                    EncodedSize = iolist_size(EncodedBody),
                    FrameLen = ?FRAME_HEADER_BYTES + EncodedSize,
                    case check_backpressure(State0, FrameLen) of
                        ok ->
                            case maybe_rotate(State0, FrameLen) of
                                {ok, State1} ->
                                    write_batch_frame(
                                        State1,
                                        EncodedBody,
                                        Flags,
                                        FrameLen,
                                        Hlcs,
                                        BatchMaxSeq
                                    );
                                {fatal, _, _} = Fatal ->
                                    Fatal;
                                {error, _} = E ->
                                    E
                            end;
                        {wal_full, _Reason} = Full ->
                            Full
                    end
            end
    end.

%% @private
%% Builds the codec opts map from the writer's state. The codec is
%% pure — it takes config + body in, returns flag + bytes out — so
%% rebuilding this map per append is a few-key copy with no
%% allocations beyond the map itself.
codec_opts(#state{
    instance_id = Id,
    body_compression = Algo,
    body_compression_min_bytes = Min,
    body_encryption = Enc
}) ->
    #{
        instance_id => Id,
        body_compression => Algo,
        body_compression_min_bytes => Min,
        body_encryption => Enc
    }.

%% @private
%% Hard backpressure check. Refuses the append iff EITHER
%% the projected post-append size would exceed `max_total_wal_size` OR
%% the current live-segment count already meets `max_live_segments`.
%% The first is forward-looking (the next byte you'd write); the second
%% is current-state — it prevents *any* further append once the segment
%% count cap is reached, which is the WAL_DESIGN-mandated behaviour
%% (the operator's failsafe before ENOSPC).
%%
%% Returns `ok` or `{wal_full, max_total_wal_size | max_live_segments}`.
%% The caller surfaces `{error, wal_full}` to the client and emits the
%% (debounced) telemetry event with the reason as metadata.
check_backpressure(
    #state{bytes_total = Bytes, max_total_wal_size = MaxTotal}, FrameLen
) when Bytes + FrameLen > MaxTotal ->
    {wal_full, max_total_wal_size};
check_backpressure(
    #state{live_segments_count = Live, max_live_segments = MaxLive}, _FrameLen
) when Live >= MaxLive ->
    {wal_full, max_live_segments};
check_backpressure(_State, _FrameLen) ->
    ok.

%% @private
%% Strict-ascending check over a list of HLCs. Used to enforce the
%% `append_batch/2` contract that HLCs within a batch are monotonic; a
%% violation would silently corrupt the segment's `(first,last)` HLC
%% bracket and the sparse-index seek invariant.
is_strictly_increasing([_]) ->
    true;
is_strictly_increasing([A, B | Rest]) when A < B ->
    is_strictly_increasing([B | Rest]);
is_strictly_increasing(_) ->
    false.

%% @private
%% Pre-rotate when the encoded batch frame wouldn't fit in the current
%% segment. The `Cur > ?SEG_HEADER_BYTES` guard is load-bearing: a
%% batch frame larger than `max_segment_bytes - SEG_HEADER_BYTES`
%% wouldn't fit even in a fresh segment, so unconditional rotation
%% would loop forever. The guard makes the rotation idempotent in that
%% case — the writer falls through to `write_batch_frame/4`, which
%% writes the oversized frame in place (overhanging the soft cap by
%% the excess bytes) and rotation kicks in on the *next* append.
maybe_rotate(
    #state{current_offset = Cur, max_segment_bytes = Max} = State, FrameLen
) when Cur > ?SEG_HEADER_BYTES, Cur + FrameLen > Max ->
    rotate(State);
maybe_rotate(State, _FrameLen) ->
    {ok, State}.

%% @private
%% Returns:
%%   {ok, NewState}            — rotation succeeded.
%%   {error, Reason}           — rotation failed *before* the old fd was
%%                               closed (only the initial datasync of
%%                               `OldFd`). State0 is unchanged and the
%%                               caller can retry.
%%   {fatal, Reason, PartialState}
%%                             — rotation failed *after* `OldFd` was
%%                               closed. The writer's in-memory state
%%                               (including the now-undefined `head_fd`)
%%                               is at odds with State0 and recovery is
%%                               required. `PartialState` reflects what
%%                               is actually on disk: head_fd cleared,
%%                               durable boundary advanced, segment_id
%%                               still at OldSegId because the manifest
%%                               commit did not succeed. The caller must
%%                               stop the gen_server using this state so
%%                               `terminate/2` doesn't datasync a closed
%%                               fd.
rotate(
    #state{
        head_fd = OldFd, segment_id = OldSegId, current_offset = OldOff
    } = State0
) ->
    T0 = erlang:monotonic_time(microsecond),
    case bondy_mst_io:datasync(OldFd) of
        {error, _} = E ->
            %% Pre-close failure: old fd still valid, state unchanged.
            E;
        ok ->
            %% The just-sealed segment is now fully durable. Advance the
            %% durable boundary so any `await_durable/3` waiters at
            %% offsets ≤ OldOff get woken before the rotation moves on.
            %% In batched mode this is also the implicit fsync of any
            %% pending writes — clear `pending_fsync_bytes` and cancel
            %% the interval timer here so the next batched window
            %% starts fresh in the new segment.
            State1 = advance_durable(State0, OldSegId, OldOff),
            close_sealed_segment(OldFd, OldSegId),
            %% Past the point of no return: OldFd is closed. Clear it
            %% from state so that any subsequent termination path does
            %% not datasync a closed fd.
            State2 = State1#state{head_fd = undefined},
            %% `.qidx` is a best-effort accelerator (recovery rebuilds
            %% from the segment scan if missing or stale). A flush
            %% failure here must not abort rotation — aborting after
            %% the old fd has already been closed would leave the
            %% writer's state holding a stale closed fd. Log and
            %% continue; recovery will rebuild the file next open.
            _ = flush_sealed_idx(State2),
            case open_next_segment(State2) of
                {ok, State3} ->
                    Duration = erlang:monotonic_time(microsecond) - T0,
                    emit_rotate_telemetry(
                        State3,
                        OldSegId,
                        State3#state.segment_id,
                        OldOff,
                        Duration,
                        size
                    ),
                    {ok, State3};
                {error, Reason} ->
                    {fatal, {rotation_failed_after_seal, Reason}, State2}
            end
    end.

%% @private
%% Closing a successfully-datasynced fd is a courtesy: the data is
%% already durable, so a close failure does not cost durability. Log
%% and keep going rather than crash the writer mid-rotation.
close_sealed_segment(Fd, SegId) ->
    case prim_file:close(Fd) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "prim_file:close/1 of sealed WAL segment fd failed; "
                    "data is already datasync'd so durability is intact, "
                    "but the fd may leak until the port is GC'd",
                segment => SegId,
                reason => Reason
            }),
            ok
    end.

%% @private
open_next_segment(
    #state{
        segment_id = OldSegId,
        first_hlc = OldFirstHlc,
        dir = Dir,
        instance_id = InstanceId,
        origin = Origin,
        head_pos_ref = HeadRef,
        durable_pos_ref = DurableRef,
        idx_interval_bytes = IdxInterval
    } = State
) ->
    NewSegId = OldSegId + 1,
    NewPath = segment_path(Dir, NewSegId),
    case
        bondy_oplog_wal_segment:create(
            NewPath, NewSegId, InstanceId, Origin
        )
    of
        {ok, NewFd, _Header} ->
            case commit_rotation(State, NewSegId, OldFirstHlc) of
                {ok, NewManifest} ->
                    publish_head_pos(HeadRef, NewSegId, ?SEG_HEADER_BYTES),
                    %% Segment header is datasync'd inside
                    %% `bondy_oplog_wal_segment:create/4`, so the new
                    %% segment's first 48 bytes are durable. Advance
                    %% durable to match — and wake any waiter parked
                    %% at the new segment's empty boundary (rare, but
                    %% legal under the `await_durable/3` contract).
                    publish_durable_pos(
                        DurableRef, NewSegId, ?SEG_HEADER_BYTES
                    ),
                    State1 = State#state{
                        head_fd = NewFd,
                        segment_id = NewSegId,
                        current_offset = ?SEG_HEADER_BYTES,
                        first_hlc = undefined,
                        manifest = NewManifest,
                        idx_acc = bondy_oplog_wal_idx:new(IdxInterval),
                        durable_segment_id = NewSegId,
                        durable_offset = ?SEG_HEADER_BYTES,
                        bytes_total =
                            State#state.bytes_total + ?SEG_HEADER_BYTES,
                        live_segments_count =
                            State#state.live_segments_count + 1
                    },
                    State2 = notify_durable_waiters(State1),
                    {ok, State2};
                {error, _} = E ->
                    %% Pre-commit failure: the new segment file is on
                    %% disk but the manifest still names the old one.
                    %% Delete the orphan eagerly so a retry of `rotate`
                    %% can `create/4` the same segment id without
                    %% colliding on the `exclusive` open.
                    _ = prim_file:close(NewFd),
                    _ = prim_file:delete(NewPath),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Commit point of rotation: update the cached manifest in memory and
%% atomically rewrite the on-disk file. On success the new manifest is
%% returned so the caller can install it in state.
commit_rotation(
    #state{manifest = M0, dir = Dir} = State, NewSegId, PrevSegmentFirstHlc
) ->
    M1 = bondy_oplog_wal_manifest:with_max_seq(
        bondy_oplog_wal_manifest:with_current_segment(
            M0, NewSegId, PrevSegmentFirstHlc
        ),
        %% The segment being sealed holds nothing above this.
        State#state.max_seq
    ),
    case bondy_oplog_wal_manifest:write(Dir, M1) of
        ok -> {ok, M1};
        {error, _} = E -> E
    end.

%% @private
%% Writes a frame to the head segment and performs the mode-specific
%% durability step:
%%
%% - `per_write`: datasync immediately; advance durable and notify any
%%   `await_durable/3` waiters covered by the new boundary.
%% - `batched`: accumulate bytes; trigger a fsync if the size threshold
%%   is reached; otherwise arm (or leave armed) the interval timer so
%%   `flush_tick` will fsync within `batched_fsync_interval` ms.
%%
%% The head_pos_ref publish happens after the durability step so that
%% in per_write mode tail readers only ever see frames whose bytes are
%% durable. In batched mode tail readers may observe non-durable frames
%% — the applier must `await_durable/3` before committing past them
%% (the applier must `await_durable/3` before committing past non-durable frames).
write_batch_frame(
    #state{
        head_fd = Fd,
        current_offset = Off,
        segment_id = Seg,
        head_pos_ref = HeadRef,
        idx_acc = Acc0
    } = State0,
    Body,
    Flags,
    FrameLen,
    Hlcs,
    BatchMaxSeq
) ->
    Frame = bondy_oplog_wal_frame:encode(Body, [{flags, Flags}]),
    case prim_file:write(Fd, Frame) of
        ok ->
            NewOff = Off + FrameLen,
            FirstHlc = hd(Hlcs),
            LastHlc = lists:last(Hlcs),
            %% Record the frame in the sparse-index accumulator keyed
            %% on the batch's first HLC. One index entry per frame,
            %% regardless of batch size — the reader's HLC seek finds
            %% the frame, then decodes its events as a unit.
            Acc1 = bondy_oplog_wal_idx:note_frame(
                Acc0, FirstHlc, LastHlc, Off, FrameLen
            ),
            State1 = State0#state{
                current_offset = NewOff,
                first_hlc = pick_first_hlc(State0#state.first_hlc, FirstHlc),
                last_hlc = LastHlc,
                append_count = State0#state.append_count + length(Hlcs),
                max_seq = max(State0#state.max_seq, BatchMaxSeq),
                idx_acc = Acc1,
                bytes_total = State0#state.bytes_total + FrameLen,
                last_append_at_ms = erlang:monotonic_time(millisecond)
            },
            Entries = [{H, {Seg, Off}} || H <- Hlcs],
            %% The frame's bytes are in the OS page cache and the head
            %% offset is published; the durability step (the fsync) is
            %% applied by the caller — per call in `do_append_batch/2`,
            %% or once per group in `flush_group/3` (driven by
            %% `group_commit_append/3`). Publishing
            %% the head offset here (before the fsync) is safe: the bytes
            %% are written, and head has always been allowed to run ahead
            %% of durable (readers reading head read non-durable data by
            %% design).
            publish_head_offset(HeadRef, NewOff),
            {ok, Entries, State1, FrameLen};
        {error, _} = E ->
            E
    end.

%% @private
%% Mode-specific durability step. The return contract differs by mode:
%%
%% - `per_write`: returns `{ok, State}` on a successful datasync, or
%%   `{error, Reason}` so the caller surfaces the failure to the
%%   client (durability was promised — silently swallowing the error
%%   would break the contract).
%%
%% - `batched`: ALWAYS returns `{ok, State}`. A failed size-triggered
%%   fsync is logged and retried via the interval timer; the batched
%%   contract is "best-effort fsync at some later boundary", so a
%%   single failed attempt is not promoted to a per-append error.
post_write_durability(#state{fsync_mode = per_write} = State, _FrameLen) ->
    case do_fsync_head(State) of
        {ok, _} = OK -> OK;
        {error, _} = E -> E
    end;
post_write_durability(
    #state{fsync_mode = batched, pending_fsync_bytes = P} = State, FrameLen
) ->
    State1 = State#state{pending_fsync_bytes = P + FrameLen},
    case maybe_size_trigger_fsync(State1) of
        {ok, State2} ->
            {ok, maybe_arm_flush_timer(State2)};
        {error, _} ->
            {ok, maybe_arm_flush_timer(State1)}
    end.

%% @private
pick_first_hlc(undefined, Hlc) -> Hlc;
pick_first_hlc(Existing, _) -> Existing.

%% =============================================================================
%% Retention + snapshot watermark
%% =============================================================================

%% @private
%% Validate and apply a new snapshot watermark. Persists to
%% `snapshot.watermark` (tmp+rename atomic) before mutating in-memory
%% state, so a crash mid-call cannot leave RAM ahead of disk.
do_advance_snapshot_watermark(
    #state{snapshot_watermark = Old}, NewHlc
) when Old =/= undefined, NewHlc < Old ->
    {error, {watermark_regression, Old, NewHlc}};
do_advance_snapshot_watermark(#state{dir = Dir} = State, NewHlc) ->
    case bondy_oplog_wal_state:write_snapshot_watermark(Dir, NewHlc) of
        ok ->
            {ok, State#state{snapshot_watermark = NewHlc}};
        {error, _} = E ->
            E
    end.

%% @private
%% Stub setter for `committed_segment` used until the consumer-commit
%% machinery lands. Monotonic; refuses to move backwards.
do_set_committed_segment(
    #state{committed_segment = Cur}, NewSeg
) when NewSeg < Cur ->
    {error, {committed_segment_regression, Cur, NewSeg}};
do_set_committed_segment(State, NewSeg) ->
    {ok, State#state{committed_segment = NewSeg}}.

%% @private
%% Add or update a scrubber alert for `SegId` and persist the manifest
%% via the same tmp+rename path retention uses. The alert survives
%% restart and is surfaced through `info/1`. Telemetry is emitted by
%% the caller (`bondy_oplog_wal_scrubber`) so the alert event keeps the
%% segment walk's offset/duration context that the WAL writer doesn't
%% have.
do_mark_segment_alert(#state{manifest = M, dir = Dir} = State, SegId, Reason) ->
    M1 = bondy_oplog_wal_manifest:with_scrubber_alert(M, SegId, Reason),
    case bondy_oplog_wal_manifest:write(Dir, M1) of
        ok -> {ok, State#state{manifest = M1}};
        {error, _} = E -> E
    end.

%% @private
%% Drop the alert for `SegId` and persist. Persisting on a no-op clear
%% is harmless (single tmp+rename) and keeps the call shape uniform
%% with `do_mark_segment_alert/3`.
do_clear_segment_alert(#state{manifest = M, dir = Dir} = State, SegId) ->
    M1 = bondy_oplog_wal_manifest:without_scrubber_alert(M, SegId),
    case bondy_oplog_wal_manifest:write(Dir, M1) of
        ok -> {ok, State#state{manifest = M1}};
        {error, _} = E -> E
    end.

%% @private
%% Run a retention sweep and swallow any error after logging — used by
%% the event-driven triggers (watermark advance, committed-segment
%% advance, periodic tick) where the caller's API contract is `ok`
%% regardless of whether the opportunistic sweep makes progress.
sweep_swallowing_errors(State0, Trigger) ->
    case do_retention_sweep(State0) of
        {ok, _Deleted, _Freed, State1} ->
            State1;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "Retention sweep failed; will retry on next trigger",
                instance_id => State0#state.instance_id,
                trigger => Trigger,
                reason => Reason
            }),
            State0
    end.

%% @private
%% Core sweep protocol:
%%
%% 1. Compute the set of deletable segments using the manifest's
%%    `live_segments`, the snapshot-watermark→segment mapping, the
%%    committed-segment cursor, and `min_live_segments`.
%% 2. If non-empty, rewrite the manifest atomically with the survivors
%%    and the bumped `deleted_through`.
%% 3. Unlink the `.qdata` (and best-effort `.qidx`) for each deleted
%%    segment. A crash between (2) and (3) leaves orphan files that the
%%    next open's `cleanup_orphans/2` removes.
%%
%% Returns `{ok, DeletedIds, FreedBytes, NewState}` or `{error, Reason}`
%% if the manifest rewrite fails (no files are touched in that case).
do_retention_sweep(#state{} = State0) ->
    T0 = erlang:monotonic_time(microsecond),
    Result =
        case compute_deletable(State0) of
            [] -> {ok, [], 0, State0};
            Deletable -> apply_deletable(State0, Deletable)
        end,
    case Result of
        {ok, Deleted, Freed, State1} ->
            Duration = erlang:monotonic_time(microsecond) - T0,
            emit_retention_sweep_telemetry(
                State1, length(Deleted), Freed, Duration
            ),
            Result;
        {error, _} ->
            Result
    end.

%% @private
%% Compute the deletable segment ids.
compute_deletable(#state{
    manifest = M,
    first_hlc = HeadFirstHlc,
    segment_id = HeadSegId,
    snapshot_watermark = Watermark,
    committed_segment = CommittedSeg,
    min_live_segments = MinLive
}) ->
    Live0 = bondy_oplog_wal_manifest:live_segments(M),
    %% The manifest's entry for the head segment carries
    %% `first_hlc = undefined` until the next rotation finalises it.
    %% The writer holds the live value in `#state.first_hlc`; patch
    %% it in so the watermark→segment mapping can see that the head
    %% has actually started.
    Live = patch_head_first_hlc(Live0, HeadSegId, HeadFirstHlc),
    WatermarkSeg = snapshot_watermark_segment(Live, Watermark),
    %% Hard bound: never delete enough to drop live-segments below
    %% MinLive. With Live sorted ascending, the deletable prefix is
    %% the first `length(Live) - MinLive` ids that also satisfy the
    %% committed/watermark cuts.
    LiveIds = [Id || {Id, _} <- Live],
    MaxDeletable = max(0, length(LiveIds) - MinLive),
    Eligible = [
        Id
     || Id <- LiveIds,
        Id < CommittedSeg,
        Id < WatermarkSeg
    ],
    lists:sublist(Eligible, MaxDeletable).

%% @private
%% Replace the `{HeadSegId, undefined}` entry in `Live` with the live
%% value the writer has in state. A `HeadFirstHlc = undefined` (head
%% segment has had no appends yet) leaves the entry untouched.
patch_head_first_hlc(Live, _HeadSegId, undefined) ->
    Live;
patch_head_first_hlc(Live, HeadSegId, HeadFirstHlc) ->
    [
        case Id of
            HeadSegId -> {Id, HeadFirstHlc};
            _ -> Entry
        end
     || {Id, _} = Entry <- Live
    ].

%% @private
%% Snapshot-watermark→segment mapping: the highest sealed segment
%% whose entire content is HLC-covered by `Watermark`.
%%
%% A sealed segment S is "fully covered" iff every event in S has
%% HLC ≤ Watermark. Since HLCs are strictly monotonic and every
%% event in S precedes the first event of S+1, the test reduces to
%% `first_hlc(S+1) =< Watermark`: if S+1's first event is itself
%% covered, S's last event (strictly older) must be covered too.
%% The head segment is never the answer — more events may yet be
%% appended, so its content isn't bounded.
%%
%% Returns `0` when no segment qualifies, so the `S < watermark_seg`
%% test in `compute_deletable/1` rejects everything.
%%
%% Note: the condition `first_hlc(S+1) > Watermark` would invert the
%% high-watermark / more-deletable correspondence and make a `W=max`
%% watermark prevent all deletions. We use `=<` here so the
%% retention behaviour matches the prose ("largest segment whose
%% entire content is HLC-covered by the watermark").
snapshot_watermark_segment(_Live, undefined) ->
    0;
snapshot_watermark_segment([], _Watermark) ->
    0;
snapshot_watermark_segment(Live, Watermark) ->
    walk_watermark(Live, Watermark, 0).

%% @private
%% `Best` is the largest qualifying segment found so far, `0` initially.
%% Clause order is significant — the `{_, undefined}`-successor clause
%% precedes the catch-all so an unknown next-first-HLC halts the walk
%% with whatever we've already proven covered.
walk_watermark([{_Id, _FirstHlc}], _Watermark, Best) ->
    %% Singleton: the only remaining entry is the head segment, which
    %% is never fully covered.
    Best;
walk_watermark(
    [{Id, _ThisHlc}, {_NextId, NextHlc} = Next | Rest], Watermark, _Best
) when is_integer(NextHlc), NextHlc =< Watermark ->
    %% Successor S+1 starts at or below the watermark ⇒ every event in
    %% S strictly precedes it ⇒ S is fully covered. Continue — a
    %% later segment may also qualify.
    walk_watermark([Next | Rest], Watermark, Id);
walk_watermark([_This, {_NextId, undefined} | _], _Watermark, Best) ->
    %% Successor's first_hlc not yet known (head segment, no appends
    %% yet). Conservatively halt with whatever we already proved.
    Best;
walk_watermark([_This | Rest], Watermark, Best) ->
    %% Successor exists but its first event is above the watermark —
    %% this predecessor is not yet fully covered. Skip past it.
    walk_watermark(Rest, Watermark, Best).

%% @private
%% Second phase of the sweep: rewrite the manifest, then unlink the files.
apply_deletable(#state{manifest = M, dir = Dir} = State0, Deletable) ->
    Live0 = bondy_oplog_wal_manifest:live_segments(M),
    Survivors = [
        {Id, FH}
     || {Id, FH} <- Live0,
        not lists:member(Id, Deletable)
    ],
    NewDeletedThrough = max(
        bondy_oplog_wal_manifest:deleted_through(M),
        lists:max(Deletable)
    ),
    M1 = bondy_oplog_wal_manifest:with_live_segments(M, Survivors),
    M2 = bondy_oplog_wal_manifest:with_deleted_through(M1, NewDeletedThrough),
    case bondy_oplog_wal_manifest:write(Dir, M2) of
        ok ->
            FreedBytes = unlink_segments(Dir, Deletable),
            State1 = State0#state{
                manifest = M2,
                bytes_total =
                    max(0, State0#state.bytes_total - FreedBytes),
                live_segments_count =
                    max(
                        0,
                        State0#state.live_segments_count -
                            length(Deletable)
                    )
            },
            {ok, Deletable, FreedBytes, State1};
        {error, _} = E ->
            E
    end.

%% @private
%% Unlink `.qdata` and best-effort `.qidx` for each deleted segment.
%% Sums up the `.qdata` sizes for the `FreedBytes` return value. A
%% per-file `prim_file:delete/1` failure is logged but does not abort
%% the sweep — the manifest already excludes the segment, so the file
%% is an orphan from this point on and the next startup's
%% `cleanup_orphans/2` will retry the unlink.
unlink_segments(Dir, Ids) ->
    lists:foldl(
        fun(Id, Acc) -> Acc + unlink_segment(Dir, Id) end,
        0,
        Ids
    ).

%% @private
%% Best-effort delete of the `.qdata` and `.qidx` for `Id`. Returns the
%% bytes actually freed (the `.qdata` size on a successful delete; `0`
%% if the file was already gone or the delete failed). The `.qidx` is
%% a recoverable accelerator — its size is not credited.
unlink_segment(Dir, Id) ->
    QData = segment_path(Dir, Id),
    QIdx = idx_path(Dir, Id),
    Freed = delete_and_size(QData, qdata),
    _ = delete_or_log(QIdx, qidx),
    Freed.

%% @private
%% Reads file size, then attempts delete. Returns the size iff the
%% delete succeeded (so failed deletes don't inflate `FreedBytes`).
delete_and_size(Path, Kind) ->
    Size =
        case prim_file:read_file_info(Path) of
            {ok, #file_info{size = S}} -> S;
            _ -> 0
        end,
    case delete_or_log(Path, Kind) of
        ok -> Size;
        _ -> 0
    end.

%% @private
%% `enoent` is treated as success (idempotent unlink). Other errors
%% are logged at WARNING and returned so the caller can react.
delete_or_log(Path, Kind) ->
    case prim_file:delete(Path) of
        ok ->
            ok;
        {error, enoent} ->
            ok;
        {error, Reason} = E ->
            ?LOG_WARNING(#{
                description =>
                    "Retention sweep: prim_file:delete/1 failed; file "
                    "remains as orphan and will be retried on the next "
                    "open's cleanup_orphans/2",
                path => Path,
                kind => Kind,
                reason => Reason
            }),
            E
    end.

%% =============================================================================
%% Durability + waiter management
%% =============================================================================

%% @private
%% Fsync the head fd and advance the durable boundary. Used by
%% `sync/1`, by per_write append, and by batched-mode fsyncs (size and
%% timer-triggered via `maybe_batched_fsync/1`).
do_fsync_head(
    #state{
        head_fd = Fd,
        segment_id = Seg,
        current_offset = Off,
        pending_fsync_bytes = Pending,
        fsync_count = FsyncCount
    } = State
) when Fd =/= undefined ->
    T0 = erlang:monotonic_time(microsecond),
    case bondy_mst_io:datasync(Fd) of
        ok ->
            Duration = erlang:monotonic_time(microsecond) - T0,
            emit_fsync_telemetry(State, Pending, Duration),
            State1 = advance_durable(State, Seg, Off),
            {ok, State1#state{fsync_count = FsyncCount + 1}};
        {error, _} = E ->
            E
    end.

%% @private
%% Try a size-triggered fsync. Returns the original state if the
%% threshold has not been crossed; otherwise fsyncs and advances
%% durable.
maybe_size_trigger_fsync(
    #state{pending_fsync_bytes = P, batched_fsync_bytes = T} = State
) when P >= T ->
    do_fsync_head(State);
maybe_size_trigger_fsync(State) ->
    {ok, State}.

%% @private
%% Fsync if any bytes are pending. Called from the `flush_tick` timer
%% handler. Returns `{ok, State}` (possibly unchanged) or `{error, _}`
%% on datasync failure — the timer handler treats the error as
%% best-effort and leaves the pending bytes for a later attempt.
maybe_batched_fsync(#state{pending_fsync_bytes = 0} = S) -> {ok, S};
maybe_batched_fsync(#state{head_fd = undefined} = S) -> {ok, S};
maybe_batched_fsync(State) -> do_fsync_head(State).

%% @private
%% Arm a `flush_tick` interval timer if one isn't already scheduled and
%% there are pending bytes. Per_write callers are a no-op (they never
%% accumulate pending bytes; defensive guard).
maybe_arm_flush_timer(#state{fsync_mode = per_write} = S) ->
    S;
maybe_arm_flush_timer(#state{flush_timer = T} = S) when is_reference(T) -> S;
maybe_arm_flush_timer(#state{pending_fsync_bytes = 0} = S) ->
    S;
maybe_arm_flush_timer(#state{batched_fsync_interval = Ms} = S) ->
    TRef = erlang:send_after(Ms, self(), flush_tick),
    S#state{flush_timer = TRef}.

%% @private
%% Advance the durable position to `{Seg, Off}`. Publishes to the
%% atomics ref, resets the batched-mode bookkeeping, and wakes any
%% `await_durable/3` waiters at or below the new position.
advance_durable(
    #state{durable_segment_id = DSeg, durable_offset = DOff} = State,
    Seg,
    Off
) when {DSeg, DOff} >= {Seg, Off} ->
    %% Idempotent / monotonic: the durable boundary only moves
    %% forward. A redundant call (e.g. `sync/1` with no new bytes) is
    %% a no-op for durable state but still resets pending bookkeeping
    %% — datasync was issued, so any in-flight pending bytes were
    %% serviced and `last_fsync_at` should advance.
    State#state{
        pending_fsync_bytes = 0,
        last_fsync_at = erlang:monotonic_time(millisecond),
        flush_timer = cancel_and_clear_timer(State#state.flush_timer)
    };
advance_durable(State, Seg, Off) ->
    publish_durable_pos(State#state.durable_pos_ref, Seg, Off),
    emit_durable_telemetry(State, Seg, Off),
    State1 = State#state{
        durable_segment_id = Seg,
        durable_offset = Off,
        pending_fsync_bytes = 0,
        last_fsync_at = erlang:monotonic_time(millisecond),
        flush_timer = cancel_and_clear_timer(State#state.flush_timer)
    },
    notify_durable_waiters(State1).

%% @private
notify_durable_waiters(
    #state{
        durable_segment_id = Seg, durable_offset = Off, waiters = Ws
    } = State
) ->
    State#state{waiters = satisfy_waiters_up_to({Seg, Off}, Ws)}.

%% @private
%% `Waiters` is sorted ascending by `#waiter.pos`. Reply `ok` to each
%% waiter at or below `DurablePos`; cancel its timer; return the
%% unsatisfied tail.
satisfy_waiters_up_to(DurablePos, Waiters) ->
    {Satisfied, Pending} = lists:splitwith(
        fun(#waiter{pos = WPos}) -> WPos =< DurablePos end,
        Waiters
    ),
    lists:foreach(
        fun(#waiter{from = From, tref = TRef}) ->
            cancel_and_clear_timer(TRef),
            gen_server:reply(From, ok)
        end,
        Satisfied
    ),
    Pending.

%% @private
%% Handles a `{await_durable, Pos, Timeout}` gen_server call. Replies
%% immediately if already durable; otherwise registers a waiter and
%% returns `{noreply, _}` so the caller blocks until satisfied or the
%% timer fires.
handle_await_durable(
    {Seg, Off},
    _Timeout,
    _From,
    #state{durable_segment_id = DSeg, durable_offset = DOff} = State
) when {Seg, Off} =< {DSeg, DOff} ->
    {reply, ok, State};
handle_await_durable(_Pos, 0, _From, State) ->
    %% Zero-timeout fast path: never blocks. Useful for "is this pos
    %% durable?" probes without the gen_server round-trip churn of a
    %% start_timer / cancel_timer pair.
    {reply, {error, timeout}, State};
handle_await_durable(Pos, Timeout, From, State) ->
    WaiterId = make_ref(),
    TRef =
        case Timeout of
            infinity ->
                infinity;
            T when is_integer(T), T > 0 ->
                erlang:start_timer(T, self(), {await_timeout, WaiterId})
        end,
    W = #waiter{id = WaiterId, pos = Pos, from = From, tref = TRef},
    NewWaiters = insert_waiter(W, State#state.waiters),
    {noreply, State#state{waiters = NewWaiters}}.

%% @private
%% Ordered insert by `#waiter.pos` ascending. Waiters at the same
%% position append after existing ones (FIFO for tie-breaking).
insert_waiter(#waiter{pos = WPos} = New, Waiters) ->
    {Before, After} = lists:splitwith(
        fun(#waiter{pos = P}) -> P =< WPos end,
        Waiters
    ),
    Before ++ [New | After].

%% @private
%% Remove a waiter by id (timeout path). Replies `{error, timeout}` if
%% the waiter is still in the list; no-op if it was satisfied between
%% the timer firing and this handler running.
expire_waiter(WaiterId, #state{waiters = Ws} = State) ->
    case
        lists:partition(
            fun(#waiter{id = Id}) -> Id =:= WaiterId end, Ws
        )
    of
        {[#waiter{from = From}], Rest} ->
            gen_server:reply(From, {error, timeout}),
            State#state{waiters = Rest};
        {[], _} ->
            State
    end.

%% @private
%% Cancel a timer if one is set, returning `undefined` so the field can
%% be reset uniformly. Accepts the three possible field values:
%% `undefined` (no timer set), `infinity` (sentinel for "no deadline" on
%% a `#waiter{}`), and a real `reference()` from `erlang:start_timer/3`.
cancel_and_clear_timer(undefined) ->
    undefined;
cancel_and_clear_timer(infinity) ->
    undefined;
cancel_and_clear_timer(TRef) when is_reference(TRef) ->
    _ = erlang:cancel_timer(TRef),
    undefined.

%% @private
build_info(#state{} = State) ->
    LiveIds = [
        Id
     || {Id, _} <-
            bondy_oplog_wal_manifest:live_segments(State#state.manifest)
    ],
    #{
        instance_id => State#state.instance_id,
        dir => State#state.dir,
        origin => State#state.origin,
        max_segment_bytes => State#state.max_segment_bytes,
        max_batch_bytes => State#state.max_batch_bytes,
        current_segment => State#state.segment_id,
        head_offset => State#state.current_offset,
        durable_segment => State#state.durable_segment_id,
        durable_offset => State#state.durable_offset,
        first_hlc => State#state.first_hlc,
        last_hlc => State#state.last_hlc,
        append_count => State#state.append_count,
        max_seq => State#state.max_seq,
        fsync_mode => State#state.fsync_mode,
        batched_fsync_interval => State#state.batched_fsync_interval,
        batched_fsync_bytes => State#state.batched_fsync_bytes,
        group_commit => State#state.group_commit,
        group_commit_max => State#state.group_commit_max,
        fsync_count => State#state.fsync_count,
        pending_fsync_bytes => State#state.pending_fsync_bytes,
        last_fsync_at => State#state.last_fsync_at,
        waiter_count => length(State#state.waiters),
        live_segments => LiveIds,
        live_segments_count => State#state.live_segments_count,
        deleted_through =>
            bondy_oplog_wal_manifest:deleted_through(State#state.manifest),
        scrubber_alerts =>
            bondy_oplog_wal_manifest:scrubber_alerts(State#state.manifest),
        snapshot_watermark => State#state.snapshot_watermark,
        committed_segment => State#state.committed_segment,
        min_live_segments => State#state.min_live_segments,
        retention_sweep_interval => State#state.retention_sweep_interval,
        bytes_total => State#state.bytes_total,
        max_total_wal_size => State#state.max_total_wal_size,
        max_live_segments => State#state.max_live_segments,
        backpressure => current_backpressure(State),
        head_lag_ms => head_lag_ms(State),
        consumer_lag_bytes => consumer_lag_bytes(State)
    }.

%% @private
%% Bytes appended but not yet committed by the log's consumer (the
%% applier): the distance from the durable consumer offset to the append
%% head. Reads `consumer.offset` from disk — the consumer owns that file —
%% so the figure stays available even when the consumer itself is
%% unresponsive, which is precisely when it matters: a node whose MSTs
%% compare "converged" can still hold an undrained WAL tail, and this is
%% the number that exposes it. Conservative on edge cases: an offset that
%% was never committed, or whose segment was already swept, counts every
%% live byte as lag. `undefined` on any read failure (the caller filters).
consumer_lag_bytes(#state{dir = Dir} = State) ->
    try
        CO =
            case bondy_oplog_wal_state:read_consumer_offset(Dir) of
                {ok, CO0} -> CO0;
                {error, _} -> bondy_oplog_wal_state:new_consumer_offset()
            end,
        case bondy_oplog_wal_state:commit_count(CO) of
            0 ->
                State#state.bytes_total;
            _ ->
                consumer_lag_bytes(
                    State,
                    bondy_oplog_wal_state:committed_segment(CO),
                    bondy_oplog_wal_state:committed_frame_offset(CO)
                )
        end
    catch
        _:_ ->
            undefined
    end.

%% @private
consumer_lag_bytes(#state{segment_id = Head} = State, CSeg, COff) when
    CSeg =:= Head
->
    max(0, State#state.current_offset - COff);
consumer_lag_bytes(#state{segment_id = Head} = State, CSeg, COff) when
    CSeg < Head
->
    Dir = State#state.dir,
    Live = [
        Id
     || {Id, _} <-
            bondy_oplog_wal_manifest:live_segments(State#state.manifest)
    ],
    case lists:member(CSeg, Live) of
        false ->
            %% The committed segment was already swept beneath the offset —
            %% stale; count the whole live log.
            State#state.bytes_total;
        true ->
            Middle = lists:sum([
                filelib:file_size(segment_path(Dir, Id))
             || Id <- Live, Id > CSeg, Id < Head
            ]),
            Tail = max(
                0, filelib:file_size(segment_path(Dir, CSeg)) - COff
            ),
            Tail + Middle + State#state.current_offset
    end;
consumer_lag_bytes(_State, _CSeg, _COff) ->
    %% Offset ahead of the head — a rotation race; nothing meaningful.
    0.

%% @private
%% Snapshot of the current backpressure status. `ok` when no hard cap
%% would refuse the next minimum-size append; otherwise `{hard, Reason}`
%% naming which cap is blocking. The frame-size lower bound is the
%% 16-byte frame header — anything below `MaxTotal - ?FRAME_HEADER_BYTES`
%% of headroom guarantees that even the smallest possible frame would
%% be refused.
current_backpressure(
    #state{bytes_total = Bytes, max_total_wal_size = MaxTotal}
) when Bytes + ?FRAME_HEADER_BYTES > MaxTotal ->
    {hard, max_total_wal_size};
current_backpressure(
    #state{live_segments_count = Live, max_live_segments = MaxLive}
) when Live >= MaxLive ->
    {hard, max_live_segments};
current_backpressure(_) ->
    ok.

%% @private
%% Wall-time lag (ms) between `now()` and the last append. `undefined`
%% before the first append. Feeds the operator's freshness gauges per
%% The delta is always ≥0 because both timestamps come
%% from `erlang:monotonic_time/1`, which never goes backwards.
head_lag_ms(#state{last_append_at_ms = undefined}) ->
    undefined;
head_lag_ms(#state{last_append_at_ms = T}) ->
    erlang:monotonic_time(millisecond) - T.

%% @private
build_reader_view(#state{manifest = Manifest} = State) ->
    #{
        instance_id => State#state.instance_id,
        dir => State#state.dir,
        origin => State#state.origin,
        head_pos_ref => State#state.head_pos_ref,
        durable_pos_ref => State#state.durable_pos_ref,
        %% Atomic snapshot of the writer's current head position, read
        %% from gen_server state under the call's serialisation. The
        %% reader uses this for `tail` start positions instead of two
        %% separate `atomics:get/2` calls (which can race with
        %% rotation and yield an inconsistent `{SegA, 48}` pair where
        %% the actual head is `{SegA+1, 48}`).
        head_pos => {State#state.segment_id, State#state.current_offset},
        current_segment => State#state.segment_id,
        %% Sealed segments carry the FirstHlc the manifest captured at
        %% rotation; the head segment's manifest entry has FirstHlc =
        %% `undefined` until it rotates and the post-rotation manifest
        %% write commits the captured value. The reader patches the
        %% head segment's entry with `head_first_hlc` below for HLC
        %% seek via the sparse index.
        live_segments =>
            bondy_oplog_wal_manifest:live_segments(Manifest),
        deleted_through =>
            bondy_oplog_wal_manifest:deleted_through(Manifest),
        %% Live first-HLC of the head segment, captured by the writer
        %% on the first append into the segment but not yet persisted
        %% in the manifest (the manifest only learns about it on the
        %% next rotation). `undefined` if no events have been written
        %% into the head segment yet.
        head_first_hlc => State#state.first_hlc,
        %% Sparse-index entries the writer has accumulated for the head
        %% segment but not yet flushed to `.qidx` (the file is written
        %% only on rotation and `terminate/2`). Readers doing HLC seek
        %% into the head segment wrap these via
        %% `bondy_oplog_wal_idx:from_entries/1` to avoid a redundant
        %% file read of data the writer already has in RAM.
        head_idx_entries => head_idx_entries(State),
        %% Body-encryption config so the reader can resolve `KeyId`s
        %% via the same registry the writer used. `disabled` when
        %% encryption is off — the reader's codec path skips the
        %% decrypt branch on frames whose Flags bit 1 is clear.
        body_encryption => State#state.body_encryption
    }.

%% @private
head_idx_entries(#state{idx_acc = undefined}) -> [];
head_idx_entries(#state{idx_acc = Acc}) -> bondy_oplog_wal_idx:entries(Acc).

%% @private
%% Writes the in-memory index accumulator for the just-sealed segment to
%% disk as `<seg>.qidx`. Called from `rotate/1` after the head segment's
%% `.qdata` is datasynced and closed, so the index is durably paired
%% with the data it describes before the manifest commit publishes the
%% new head segment.
flush_sealed_idx(#state{
    dir = Dir, segment_id = SegId, idx_acc = Acc
}) ->
    Entries = bondy_oplog_wal_idx:entries(Acc),
    Path = idx_path(Dir, SegId),
    case bondy_oplog_wal_idx:write_file(Path, Entries) of
        ok ->
            ok;
        {error, Reason} = E ->
            %% A failed `.qidx` write does not lose any committed event
            %% data — recovery rebuilds the file from a segment scan.
            %% Log and bubble up so the writer caller can decide
            %% whether to retry rotation.
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_wal_idx:write_file/2 failed during "
                    "rotation; .qidx for the sealed segment will be "
                    "rebuilt on next recovery",
                segment => SegId,
                reason => Reason
            }),
            E
    end.

%% @private
%% Flushes the head segment's `.qidx` on normal `terminate/2`. Best
%% effort: a failure is logged but does not block shutdown, since
%% recovery rebuilds the file from a segment scan.
%%
%% Gate on the accumulator's entry count, not `append_count`. After
%% rotation `append_count` reflects events across all segments, while
%% `idx_acc` is reset per-segment — `append_count > 0` would falsely
%% trigger a 16-byte empty `.qidx` write for a head segment that has
%% had no appends since the last rotation.
flush_head_idx(#state{idx_acc = Acc} = State) ->
    case bondy_oplog_wal_idx:entry_count(Acc) of
        0 ->
            ok;
        _ ->
            do_flush_head_idx(State)
    end.

%% @private
do_flush_head_idx(#state{dir = Dir, segment_id = SegId, idx_acc = Acc}) ->
    Entries = bondy_oplog_wal_idx:entries(Acc),
    Path = idx_path(Dir, SegId),
    case bondy_oplog_wal_idx:write_file(Path, Entries) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_wal_idx:write_file/2 failed during "
                    "shutdown; head segment .qidx will be rebuilt "
                    "on next recovery",
                segment => SegId,
                reason => Reason
            }),
            ok
    end.

%% @private
idx_path(Dir, SegId) ->
    filename:join(Dir, bondy_oplog_wal_idx:filename(SegId)).

%% @private
%% Publishes a full (SegId, Offset) head position. Updates `seg_id`
%% first, then `offset` — a racing reader that catches the intermediate
%% state sees (new_seg_id, old_offset) which interprets correctly as
%% "my segment is sealed; read it to EOF", which is true since the
%% writer has already datasynced and closed the previous fd before
%% calling here (see `rotate/1` → `close_sealed_segment/2`).
publish_head_pos(undefined, _SegId, _Offset) ->
    ok;
publish_head_pos(Ref, SegId, Offset) ->
    ok = atomics:put(Ref, 1, SegId),
    ok = atomics:put(Ref, 2, Offset).

%% @private
%% Publishes a new head offset within the current head segment. No
%% segment-id update — that's only done on rotation via
%% `publish_head_pos/3`.
publish_head_offset(undefined, _Offset) -> ok;
publish_head_offset(Ref, Offset) -> ok = atomics:put(Ref, 2, Offset).

%% @private
%% Publishes a full (SegId, Offset) durable position. Mirrors
%% `publish_head_pos/3` (slot 1 first, slot 2 second). A racing
%% wait-free reader using both slots may, during the cross-segment
%% transition, observe `(NewSegId, OldOff)` — that intermediate is
%% larger in tuple order than the prior consistent state, so reader
%% monotonicity is preserved, but the offset is meaningless to the new
%% segment (e.g., 64 MB into a segment that contains only 48 bytes).
%% `durable_position/1` (gen_server-serialised) is the consistent-
%% snapshot API for callers that need a coherent pair; atomics polling
%% is exposed for future hot-path consumers (the applier) which
%% compare against their own sub-segment positions and tolerate
%% same-segment monotonic reads.
publish_durable_pos(undefined, _SegId, _Offset) ->
    ok;
publish_durable_pos(Ref, SegId, Offset) ->
    ok = atomics:put(Ref, 1, SegId),
    ok = atomics:put(Ref, 2, Offset).

%% =============================================================================
%% Telemetry
%% =============================================================================

%% @private
%% Single safe entry point for all WAL telemetry. Wraps
%% `telemetry:execute/3` in a try/catch so a buggy handler can never
%% propagate into the writer's gen_server. The WAL must not crash on
%% telemetry handler failure.
emit(Event, Measurements, Metadata) ->
    try
        telemetry:execute(Event, Measurements, Metadata)
    catch
        Class:Reason:Stack ->
            ?LOG_WARNING(#{
                description =>
                    "telemetry:execute/3 raised; suppressing to keep the "
                    "WAL writer alive",
                event => Event,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            ok
    end.

%% @private
%% `[bondy_oplog, wal, append]`. Emitted after every successful
%% atomic batch frame write. `batch_size` is the number of events in the
%% frame; `body_len` excludes the 16-byte frame header. `hlc` is the
%% batch's last HLC — the highest HLC newly visible to readers after
%% this append. `Entries` are `[{Hlc, {Seg, FrameStartOffset}}, ...]` in
%% append order; all events in one batch share the same `{Seg, Off}`
%% (the frame start), so `current_offset - Off` is the frame length.
emit_append_telemetry(#state{} = State, [{_, {Seg, Off}} | _] = Entries) ->
    {LastHlc, _} = lists:last(Entries),
    BatchSize = length(Entries),
    FrameLen = State#state.current_offset - Off,
    Metadata = base_metadata(State, #{segment => Seg, offset => Off}),
    Measurements = #{
        frame_len => FrameLen,
        body_len => FrameLen - ?FRAME_HEADER_BYTES,
        batch_size => BatchSize,
        hlc => LastHlc
    },
    emit([bondy_oplog, wal, append], Measurements, Metadata),
    State.

%% @private
%% `[bondy_oplog, wal, fsync]`. Emitted from `do_fsync_head/1`
%% with the bytes synced (since the previous fsync) and the elapsed
%% wall-time of the syscall. `mode` lets handlers segment counters by
%% per_write vs batched.
emit_fsync_telemetry(#state{} = State, BytesSynced, DurationUs) ->
    Metadata = base_metadata(State, #{
        segment => State#state.segment_id,
        mode => State#state.fsync_mode
    }),
    Measurements = #{
        bytes_synced => BytesSynced,
        duration_us => DurationUs
    },
    emit([bondy_oplog, wal, fsync], Measurements, Metadata).

%% @private
%% `[bondy_oplog, wal, durable]`. Emitted from `advance_durable/3`
%% on every durable advance — paired one-to-one with `fsync` events in
%% per_write mode, and one-to-many in batched mode (one durable per
%% fsync, but one fsync covers many appends).
emit_durable_telemetry(#state{} = State, Seg, Off) ->
    Metadata = base_metadata(State, #{segment => Seg}),
    emit(
        [bondy_oplog, wal, durable],
        #{durable_offset => Off},
        Metadata
    ).

%% @private
%% `[bondy_oplog, wal, rotate]`. Emitted from `open_next_segment/1`
%% after the manifest commit lands. `old_size_bytes` is the on-disk size
%% of the just-sealed segment (header + frames); `duration_us` is
%% measured from the entry of `rotate/1`. `reason` is currently always
%% `size` — only size-triggered rotation exists today; age-triggered
%% rotation lands later.
emit_rotate_telemetry(
    #state{} = State,
    OldSegId,
    NewSegId,
    OldSizeBytes,
    DurationUs,
    Reason
) ->
    Metadata = base_metadata(State, #{
        old_segment => OldSegId,
        new_segment => NewSegId,
        reason => Reason
    }),
    Measurements = #{
        old_size_bytes => OldSizeBytes,
        duration_us => DurationUs
    },
    emit([bondy_oplog, wal, rotate], Measurements, Metadata).

%% @private
%% `[bondy_oplog, wal, retention_sweep]`. Emitted from
%% `do_retention_sweep/1` on every sweep that completes (no-op or
%% otherwise). `deleted_segments` counts the segments unlinked;
%% `freed_bytes` sums their `.qdata` sizes.
emit_retention_sweep_telemetry(
    #state{} = State, DeletedCount, FreedBytes, DurationUs
) ->
    Metadata = base_metadata(State, #{}),
    Measurements = #{
        deleted_segments => DeletedCount,
        freed_bytes => FreedBytes,
        duration_us => DurationUs
    },
    emit(
        [bondy_oplog, wal, retention_sweep], Measurements, Metadata
    ).

%% @private
%% `[bondy_oplog, wal, recovery]`. Emitted at the end of
%% `install_recovery/2`, before the writer is ready to accept appends.
%% `outcome` is `ok` here; failed recoveries short-circuit before this
%% call.
%%
%% `scanned_bytes` is the head-segment work the scanner actually
%% walked: `last_valid_offset - SEG_HEADER` (the run of accepted
%% frames) plus any bytes the rescan path skipped past. Sealed
%% segments are not included — they are validated by header check
%% only, not by walking their frames. `truncated_bytes` (bytes
%% discarded after a torn-write boundary) is reported separately on
%% the same event.
emit_recovery_telemetry(#state{} = State, DurationUs, Result) ->
    Manifest = maps:get(manifest, Result),
    FramesSkipped = maps:get(frames_skipped, Result, 0),
    BytesSkipped = maps:get(bytes_skipped, Result, 0),
    Measurements = #{
        duration_us => DurationUs,
        scanned_bytes => maps:get(scanned_bytes, Result, 0),
        truncated_bytes => maps:get(truncated_bytes, Result, 0),
        frames_skipped => FramesSkipped,
        bytes_skipped => BytesSkipped,
        segments_scanned =>
            length(bondy_oplog_wal_manifest:live_segments(Manifest))
    },
    Metadata = base_metadata(State, #{outcome => ok}),
    emit([bondy_oplog, wal, recovery], Measurements, Metadata),
    maybe_emit_rescan_telemetry(
        State, DurationUs, FramesSkipped, BytesSkipped
    ).

%% @private
%% `[bondy_oplog, wal, recovery, rescan]`. Emitted only when rescan-mode
%% recovery actually skipped one or more frames. Operators alert on
%% `frames_skipped > 0` and use the structured log records (one per
%% skipped range) for forensics.
maybe_emit_rescan_telemetry(_State, _DurationUs, 0, _BytesSkipped) ->
    ok;
maybe_emit_rescan_telemetry(State, DurationUs, FramesSkipped, BytesSkipped) ->
    Measurements = #{
        duration_us => DurationUs,
        frames_skipped => FramesSkipped,
        bytes_skipped => BytesSkipped
    },
    Metadata = base_metadata(State, #{}),
    emit(
        [bondy_oplog, wal, recovery, rescan], Measurements, Metadata
    ).

%% @private
%% `[bondy_oplog, wal, wal_full]`. Emitted on every hard-limit
%% refusal of `append`/`append_batch`. Debounced — clients typically
%% retry on a tight loop, so without the debounce the WAL would flood
%% telemetry at thousands of events/s.
%%
%% The debounce is monotonic-time based and uses the `last_emit_ms`
%% field threaded through `#state{}`. The first refusal in a window
%% always emits; subsequent refusals within
%% `?BONDY_OPLOG_WAL_WAL_FULL_TELEMETRY_DEBOUNCE_MS` are dropped.
%%
%% Reason-merging note: a single debounce window is shared across both
%% `max_total_wal_size` and `max_live_segments` refusals. If the writer
%% trips one reason and then transitions to the other within the same
%% 30 s window, only the first reason is emitted. The current `info/1`
%% `backpressure` field still reflects the live state for operators
%% polling outside the debounce window, so the merge does not hide the
%% transition — it only quiets the telemetry stream.
emit_wal_full_telemetry(#state{} = State, Reason) ->
    Now = erlang:monotonic_time(millisecond),
    LastEmit = State#state.wal_full_last_emit_ms,
    Debounce = ?BONDY_OPLOG_WAL_WAL_FULL_TELEMETRY_DEBOUNCE_MS,
    case LastEmit =:= undefined orelse (Now - LastEmit) >= Debounce of
        true ->
            Metadata = base_metadata(State, #{reason => Reason}),
            Measurements = #{
                bytes_total => State#state.bytes_total,
                live_segments_count => State#state.live_segments_count
            },
            emit([bondy_oplog, wal, wal_full], Measurements, Metadata),
            State#state{wal_full_last_emit_ms = Now};
        false ->
            State
    end.

%% @private
base_metadata(#state{instance_id = Id}, Extra) ->
    maps:merge(#{instance_id => Id}, Extra).
