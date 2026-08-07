%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal_reader).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
WAL reader / iterator.

The reader is the consumer side of the WAL: it walks the on-disk
frame stream forward, one frame (one batch) at a time, across segment
boundaries, and is the path the applier uses to consume events.

Two cooperating reader contracts are supported in v1:

- **Bounded** (`follow = false`, the default). The reader returns
  `end_of_log` once it reaches the writer's published head. Useful for
  one-shot scans, operator/debug tools, and the read-side of CRDT
  bootstrap.
- **Tail-follow** (`follow = true`). The reader blocks (poll-loop) when
  it reaches the head, and resumes the moment the writer publishes
  more bytes. This is the applier's mode.

The reader is wait-free against the writer: it never sends the writer
a message during steady-state iteration. Coordination is via the
writer's `head_pos_ref` atomics ref (slot 1 = head segment id, slot 2 =
head offset within that segment), obtained once via
`bondy_oplog_wal:reader_view/1` at open.

This module is exported directly so the test suite and the applier
can build against it; the public entry points will be re-exported
from `bondy_oplog_wal` once the API stabilises with the applier
integration.

### Cross-segment iteration

When the reader exhausts its current segment's frames, it advances to
`segment_id + 1` and re-opens. Two terminating cases:

1. Reader was on a sealed segment (i.e., `head_segment_id` has advanced
   past it). The next segment file exists; open it and continue.
2. Reader was on the head segment. In `follow = true`, poll the
   atomic until either the offset moves (more frames in this segment)
   or the segment id moves (rotation just happened). In
   `follow = false`, return `end_of_log`.

### Frame-boundary discipline

`next/1` always returns a `{Segment, NextOffset}` pair where
`NextOffset` is the byte position of the *next* frame's header — i.e.
a frame boundary. The applier persists this offset back to the WAL via
`commit/3`; guaranteeing the boundary means recovery clamping can
rely on `committed_frame_offset` being a real frame start.

### Known limitations

- Multi-instance addressing: callers currently pass the writer Pid;
  this will become an `InstanceId` lookup once the per-instance
  supervisor lands alongside the applier.
""").

-define(SEG_HEADER_BYTES, ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES).
-define(FRAME_HEADER_BYTES, ?BONDY_OPLOG_WAL_FRAME_HEADER_BYTES).
-define(DEFAULT_POLL_INTERVAL_MS, 5).
-define(MAX_POLL_INTERVAL_MS, 200).

-record(iter, {
    writer_pid :: pid(),
    instance_id :: instance_id(),
    dir :: file:filename_all(),
    origin :: bondy_oplog_origin:t(),
    head_pos_ref :: atomics:atomics_ref(),
    follow :: boolean(),
    poll_interval_ms :: pos_integer(),
    %% Position within the WAL. `fd` is the open file descriptor for
    %% `segment_id`; `offset` is the byte at which the next frame
    %% header is expected.
    segment_id :: bondy_oplog_wal_segment:segment_id(),
    fd :: file:fd(),
    offset :: non_neg_integer(),
    %% Cached `prim_file:position(Fd, eof)` for the current segment,
    %% set the first time we observe `segment_id < head_segment_id` so
    %% subsequent `next/1` calls within the same sealed segment avoid
    %% a per-frame syscall. Reset to `undefined` on segment advance.
    %% A sealed segment's file size is frozen by the writer (datasync
    %% then close before bumping the head atomic), so this value is
    %% safe to cache across the segment's lifetime in the reader.
    sealed_size :: non_neg_integer() | undefined,
    %% HLC seek bookkeeping. Set when `{hlc, T}` is the start position;
    %% `next/1` keeps decoding frames until the batch's first HLC is
    %% `>= seek_target`, then stops filtering. `undefined` for
    %% `beginning` / `tail` / `{offset, _, _}` starts.
    seek_target :: bondy_oplog_hlc:hlc() | undefined,
    %% Upper bound for `{hlc_upper_bound, T}` opt. If set, frames whose
    %% first HLC is `> hlc_upper_bound` terminate the reader as if it
    %% had hit end_of_log. `undefined` means no upper bound.
    hlc_upper_bound :: bondy_oplog_hlc:hlc() | undefined,
    %% Body-encryption config inherited from the writer's
    %% `reader_view/1` map. `disabled` skips the decrypt branch;
    %% `{enabled, Module}` lets the codec resolve frame `KeyId`s via
    %% `Module:lookup_key/1`. The reader does not call `current_key/0`
    %% — historic frames carry the id they were written with.
    body_encryption :: bondy_oplog_wal_codec:encryption()
}).

-type t() :: #iter{}.
-type segment_id() :: bondy_oplog_wal_segment:segment_id().
-type offset() :: non_neg_integer().
-type position() :: {segment_id(), offset()}.
-type start_position() ::
    beginning
    | tail
    | {offset, segment_id(), offset()}
    | {hlc, bondy_oplog_hlc:hlc()}.
-type reader_opt() ::
    {follow, boolean()}
    | {poll_interval_ms, pos_integer()}
    | {hlc_upper_bound, bondy_oplog_hlc:hlc()}.
-type next_result() ::
    {ok, Batch :: [bondy_oplog_event:t()], Hlcs :: [bondy_oplog_hlc:hlc()],
        Pos :: position(), NewIter :: t()}
    | end_of_log
    | {error, term()}.

-export_type([t/0]).
-export_type([start_position/0]).
-export_type([reader_opt/0]).
-export_type([next_result/0]).

-export([open/2]).
-export([open/3]).
-export([next/1]).
-export([close/1]).
-export([position/1]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("Equivalent to `open(Writer, Start, [])`.").
-spec open(bondy_oplog_wal:wal(), start_position()) ->
    {ok, t()} | {error, term()}.

open(Writer, Start) ->
    open(Writer, Start, []).

?DOC("""
Opens an iterator over the WAL owned by `Writer`.

`Start` selects the starting frame:
- `beginning` — start at the first frame of the earliest live segment.
- `tail` — start at the writer's current head position (skipping
  everything already written).
- `{offset, Seg, Off}` — start at byte `Off` in segment `Seg`. `Off`
  must be a frame boundary (the start of the next-to-read frame header)
  and `>= 48` (i.e., past the segment header). The caller is
  responsible for choosing a real frame start; passing an offset
  mid-frame returns `{error, crc_mismatch}` or `{error, bad_magic}` on
  the next `next/1`.
- `{hlc, T}` — start at the first frame whose first event's HLC is
  `>= T`. The candidate segment is identified via the writer's
  manifest `first_hlc` values (sealed segments) + the writer's live
  `head_first_hlc`; the segment's `.qidx` (or, for the head segment,
  the writer's in-memory accumulator) is binary-searched for the
  largest entry `<= T`; the reader then forward-scans, decoding each
  frame to find the first one with `first_hlc >= T`. Subsequent
  `next/1` calls return frames without filtering.

`Opts`:
- `{follow, true|false}` — defaults to `false`. When `true`, `next/1`
  blocks on the head segment instead of returning `end_of_log`.
- `{poll_interval_ms, pos_integer()}` — defaults to 5. Initial poll
  interval used in follow mode; the reader backs off geometrically
  up to 200 ms while waiting for new data so a quiescent applier
  does not burn a core.
- `{hlc_upper_bound, hlc()}` — when set, the reader treats a frame
  whose first event's HLC is `> hlc_upper_bound` as the end of the
  log: `next/1` returns `end_of_log` instead of the frame. Useful
  for HLC-bounded scans (e.g., snapshot bootstrap).

Errors:
- `{not_supported, _}` — the start position or option is not yet
  implemented in this phase.
- `{enoent, _}` — the segment file named by `Start` does not exist.
- `{invalid_start, _}` — the start position is structurally invalid
  (negative offset, offset below the segment header, HLC seek on
  empty WAL, etc.).
""").
-spec open(bondy_oplog_wal:wal(), start_position(), [reader_opt()]) ->
    {ok, t()} | {error, term()}.

open(Writer, Start, Opts) when is_pid(Writer), is_list(Opts) ->
    do_open(Writer, Start, Opts).

?DOC("""
Returns the iterator's current position `{Segment, Offset}` — the byte
offset of the next frame to be read. Useful for tests and for the
applier's commit point.
""").
-spec position(t()) -> position().

position(#iter{segment_id = Seg, offset = Off}) ->
    {Seg, Off}.

?DOC("""
Reads the next batch frame.

Returns `{ok, Batch, Hlcs, {Segment, NextOffset}, NewIter}` on success,
where `Batch` is the list of events in the frame's batch (length ≥ 1)
and `Hlcs` is the parallel list of HLCs. `NextOffset` is a frame
boundary — the byte offset of the *next* frame's header, ready to be
passed to a subsequent `commit/3`.

Returns `end_of_log` when the reader is at the writer's head and
`follow = false`. In `follow = true` mode this function never returns
`end_of_log`; it blocks (with a bounded back-off poll loop) until new
data is published.

Returns `{error, Reason}` on a frame integrity failure (CRC mismatch,
unknown flag, etc.) or an I/O failure. The reader does **not** attempt
to recover — recovery is the writer's open-time job. The caller may
choose to `close/1` and reopen at a known-good offset.
""").
-spec next(t()) -> next_result().

next(#iter{} = Iter) ->
    do_next(Iter).

?DOC("""
Closes the iterator and releases its file descriptor.

Effectively idempotent: calling `close/1` a second time issues a
second `prim_file:close/1` on the same descriptor; the OS returns
`ebadf` which we discard, so the call still returns `ok`. A caller
that wants a strict single-close should drop its handle on first
close.
""").
-spec close(t()) -> ok.

close(#iter{fd = undefined}) ->
    ok;
close(#iter{fd = Fd}) ->
    _ = prim_file:close(Fd),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_open(Writer, Start, Opts) ->
    Follow = proplists:get_value(follow, Opts, false),
    Poll = proplists:get_value(
        poll_interval_ms, Opts, ?DEFAULT_POLL_INTERVAL_MS
    ),
    UpperBound = proplists:get_value(hlc_upper_bound, Opts, undefined),
    View = bondy_oplog_wal:reader_view(Writer),
    Dir = maps:get(dir, View),
    InstanceId = maps:get(instance_id, View),
    Origin = maps:get(origin, View),
    case resolve_start(Start, View) of
        {ok, SegId, Off, SeekTarget} ->
            case open_segment(Dir, InstanceId, Origin, SegId) of
                {ok, Fd} ->
                    {ok, #iter{
                        writer_pid = Writer,
                        instance_id = InstanceId,
                        dir = Dir,
                        origin = Origin,
                        head_pos_ref = maps:get(head_pos_ref, View),
                        follow = Follow,
                        poll_interval_ms = Poll,
                        segment_id = SegId,
                        fd = Fd,
                        offset = Off,
                        sealed_size = undefined,
                        seek_target = SeekTarget,
                        hlc_upper_bound = UpperBound,
                        body_encryption =
                            maps:get(body_encryption, View, disabled)
                    }};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% All branches return `{ok, SegId, Offset, SeekTarget}` on success
%% where `SeekTarget` is `undefined` except for `{hlc, T}` starts. The
%% reader's `next/1` filters frames whose first HLC is `< SeekTarget`
%% until it lands on the first qualifying frame, then clears the
%% target.
resolve_start(beginning, View) ->
    case live_segment_ids(View) of
        [] ->
            {error, {invalid_start, no_live_segments}};
        Ids ->
            FirstSeg = lists:min(Ids),
            {ok, FirstSeg, ?SEG_HEADER_BYTES, undefined}
    end;
resolve_start(tail, View) ->
    %% Use the gen_server-snapshotted `head_pos` rather than racing
    %% two `atomics:get/2` calls against a rotating writer.
    {SegId, Off} = maps:get(head_pos, View),
    {ok, SegId, Off, undefined};
resolve_start({offset, Seg, Off}, View) when
    is_integer(Seg), Seg >= 0, is_integer(Off)
->
    Ids = live_segment_ids(View),
    Current = maps:get(current_segment, View),
    case Off < ?SEG_HEADER_BYTES of
        true ->
            {error, {invalid_start, {offset_below_segment_header, Off}}};
        false ->
            case Seg =< Current andalso lists:member(Seg, Ids) of
                true ->
                    {ok, Seg, Off, undefined};
                false ->
                    {error, {invalid_start, {unknown_segment, Seg}}}
            end
    end;
resolve_start({hlc, T}, View) when is_integer(T), T >= 0 ->
    resolve_hlc_start(T, View);
resolve_start(Other, _View) ->
    {error, {invalid_start, Other}}.

%% @private
live_segment_ids(View) ->
    [Id || {Id, _FirstHlc} <- maps:get(live_segments, View)].

%% @private
%% Resolves a `{hlc, T}` start to a concrete `{SegId, Offset}` pair plus
%% the seek target the reader uses to filter the first batch of frames
%% it decodes.
%%
%% 1. Pick the candidate segment by walking `live_segments` (with the
%%    head segment patched in from `head_first_hlc`) and selecting the
%%    largest segment whose `FirstHlc <= T`.
%% 2. Within that segment, binary-search the `.qidx` (for sealed
%%    segments) or the writer's in-memory accumulator (for the head
%%    segment) for the largest entry `HLC <= T`. The returned byte
%%    offset is the seek's starting frame.
%% 3. If the index has no entry `<= T` (the segment's frames have all
%%    been written since the last sparse boundary), fall back to
%%    scanning from the segment header — the linear scan will still
%%    find the first frame `>= T` (the writer indexes the first frame
%%    of every segment, so the only path here is a defensive one for
%%    rebuilt or external indexes that omitted the first entry).
resolve_hlc_start(T, View) ->
    Current = maps:get(current_segment, View),
    HeadFirstHlc = maps:get(head_first_hlc, View),
    LiveWithHead = patch_head_first_hlc(
        maps:get(live_segments, View), Current, HeadFirstHlc
    ),
    case select_segment_for_hlc(LiveWithHead, T) of
        none ->
            %% T is below every segment's FirstHlc. Start at the
            %% earliest live segment with a seek target of T so the
            %% reader still respects the lower bound (returns the
            %% first frame >= T).
            case lists:sort(LiveWithHead) of
                [] ->
                    {error, {invalid_start, no_live_segments}};
                [{FirstSeg, _} | _] ->
                    {ok, FirstSeg, ?SEG_HEADER_BYTES, T}
            end;
        {ok, SegId} ->
            case index_seek(SegId, T, View, Current) of
                {ok, Offset} ->
                    {ok, SegId, Offset, T};
                none ->
                    {ok, SegId, ?SEG_HEADER_BYTES, T};
                {error, _} = E ->
                    E
            end
    end.

%% @private
%% Replaces the head-segment entry's `FirstHlc` with the writer's live
%% value. The manifest entry for the head segment carries `undefined`
%% until the next rotation; reusing that here would make HLC seek miss
%% the head segment whenever it actually has events.
patch_head_first_hlc(Live, Current, HeadFirstHlc) ->
    [
        case Id of
            Current -> {Id, HeadFirstHlc};
            _ -> {Id, FH}
        end
     || {Id, FH} <- Live
    ].

%% @private
%% Returns `{ok, SegId}` for the largest segment with `FirstHlc <= T`,
%% or `none` if every segment's `FirstHlc > T`. Segments with
%% `FirstHlc = undefined` (e.g., the head segment before any append) are
%% skipped — they have no events to satisfy any seek.
%%
%% Single-pass max via foldl: O(N) and indifferent to incoming order,
%% so this stays correct under any future re-ordering of
%% `live_segments` in the writer's `reader_view/1`.
select_segment_for_hlc(Live, T) ->
    Pick = lists:foldl(
        fun
            ({Id, FH}, none) when is_integer(FH), FH =< T ->
                {Id, FH};
            ({Id, FH}, {_, BestFH}) when
                is_integer(FH), FH =< T, FH > BestFH
            ->
                {Id, FH};
            (_, Acc) ->
                Acc
        end,
        none,
        Live
    ),
    case Pick of
        none -> none;
        {Id, _} -> {ok, Id}
    end.

%% @private
%% Seeks within a segment using either the on-disk `.qidx` (sealed
%% segment) or the writer's in-memory accumulator (head segment).
%% Returns the same shape as `bondy_oplog_wal_idx:seek/2`, except
%% additionally `{error, Reason}` from a non-enoent file-open failure.
index_seek(SegId, T, View, CurrentSeg) when SegId =:= CurrentSeg ->
    Entries = maps:get(head_idx_entries, View, []),
    Handle = bondy_oplog_wal_idx:from_entries(Entries),
    bondy_oplog_wal_idx:seek(Handle, T);
index_seek(SegId, T, View, _CurrentSeg) ->
    Dir = maps:get(dir, View),
    Path = filename:join(Dir, bondy_oplog_wal_idx:filename(SegId)),
    case bondy_oplog_wal_idx:open(Path) of
        {ok, Handle} ->
            bondy_oplog_wal_idx:seek(Handle, T);
        {error, enoent} ->
            %% No `.qidx` for a sealed segment — the recovery rebuild
            %% hasn't run, or the writer crashed before flushing. Fall
            %% back to a linear scan from the segment header; the
            %% reader still finds the first frame >= T.
            none;
        {error, _} = E ->
            E
    end.

%% @private
%% Opens a segment file read-only and verifies its header against the
%% reader's expected `InstanceId` / `Origin`. Returns the open fd or
%% closes-and-returns on any header / verify failure.
open_segment(Dir, InstanceId, Origin, SegId) ->
    Path = filename:join(Dir, bondy_oplog_wal_segment:filename(SegId)),
    case prim_file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            case bondy_oplog_wal_segment:read_header(Fd) of
                {ok, Header} ->
                    case
                        bondy_oplog_wal_segment:verify(
                            Header, InstanceId, Origin
                        )
                    of
                        ok ->
                            {ok, Fd};
                        {error, _} = E ->
                            _ = prim_file:close(Fd),
                            E
                    end;
                {error, _} = E ->
                    _ = prim_file:close(Fd),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Single-entry dispatch. Walks the bound first to know whether we're
%% on the head segment or behind it, then decides on read / poll /
%% advance based on whether the current offset is below the bound.
do_next(#iter{} = Iter0) ->
    {Kind, Bound, Iter} = bound(Iter0),
    case {Iter#iter.offset < Bound, Kind} of
        {true, _} ->
            read_frame(Iter, Kind, Bound);
        {false, head} ->
            await_head_or_end(Iter);
        {false, sealed} ->
            advance_segment(Iter)
    end.

%% @private
%% Returns `{Kind, Bound, Iter}` where `Kind` is `head` or `sealed`,
%% `Bound` is the highest byte position the reader may read up to (and
%% not including), and `Iter` is the iter possibly updated with a
%% newly-cached `sealed_size` so we don't re-syscall on every frame.
bound(#iter{head_pos_ref = Ref, segment_id = MySeg} = Iter) ->
    HeadSeg = atomics:get(Ref, 1),
    if
        MySeg > HeadSeg ->
            %% Invariant violation: a reader is on a segment past the
            %% writer's published head. Either the writer rolled back
            %% (impossible by design) or the iter was opened against a
            %% different writer instance. Crash loudly so the bug is
            %% visible rather than producing nonsense data.
            error(
                {invariant_violation, {reader_ahead_of_head, MySeg, HeadSeg}}
            );
        MySeg < HeadSeg ->
            cached_sealed_bound(Iter);
        true ->
            {head, atomics:get(Ref, 2), Iter}
    end.

%% @private
%% Sealed segments are immutable; their physical size is the bound and
%% never changes. Cache it on first observation so subsequent `next/1`
%% calls within the same sealed segment avoid the `position(eof)`
%% syscall per frame.
cached_sealed_bound(#iter{sealed_size = Size} = Iter) when
    is_integer(Size)
->
    {sealed, Size, Iter};
cached_sealed_bound(#iter{fd = Fd} = Iter) ->
    Size =
        case prim_file:position(Fd, eof) of
            {ok, S} -> S;
            {error, _} -> 0
        end,
    {sealed, Size, Iter#iter{sealed_size = Size}}.

%% @private
%% On the head segment with nothing new to read. In `follow=true` we
%% sleep and retry; otherwise we report `end_of_log`.
await_head_or_end(#iter{follow = false}) ->
    end_of_log;
await_head_or_end(#iter{follow = true} = Iter) ->
    poll_then_retry(Iter, Iter#iter.poll_interval_ms).

%% @private
%% Bounded back-off poll loop. Each pass re-reads the atomic. Four
%% possible transitions:
%%
%% 1. `{head, B}` with `off < B` — writer published more bytes; read
%%    the next frame.
%% 2. `{head, _}` with `off == B` — still caught up; back off and
%%    retry.
%% 3. `{sealed, B}` with `off < B` — writer rotated past us; our
%%    segment is now frozen but has more frames left; read them first.
%% 4. `{sealed, _}` with `off == B` — sealed segment fully consumed;
%%    advance to the next.
%%
%% The interval doubles each pass up to `?MAX_POLL_INTERVAL_MS`.
poll_then_retry(#iter{} = Iter0, Interval) ->
    timer:sleep(Interval),
    {Kind, Bound, Iter} = bound(Iter0),
    Off = Iter#iter.offset,
    case {Off < Bound, Kind} of
        {true, _} ->
            read_frame(Iter, Kind, Bound);
        {false, head} ->
            poll_then_retry(Iter, next_interval(Interval));
        {false, sealed} ->
            advance_segment(Iter)
    end.

%% @private
next_interval(I) when I * 2 =< ?MAX_POLL_INTERVAL_MS -> I * 2;
next_interval(_) -> ?MAX_POLL_INTERVAL_MS.

%% @private
%% Advance to the next segment. Closes the current fd; opens
%% `segment_id + 1`. If the next segment doesn't exist (shouldn't
%% happen with a healthy writer, but might during a tight race window
%% just before the rotation atomic update lands), back off and retry
%% via the poll loop.
advance_segment(
    #iter{
        segment_id = OldSeg,
        fd = OldFd,
        follow = Follow,
        dir = Dir,
        instance_id = InstanceId,
        origin = Origin
    } = Iter
) ->
    NextSegId = OldSeg + 1,
    case open_segment(Dir, InstanceId, Origin, NextSegId) of
        {ok, NewFd} ->
            _ = prim_file:close(OldFd),
            do_next(Iter#iter{
                segment_id = NextSegId,
                fd = NewFd,
                offset = ?SEG_HEADER_BYTES,
                sealed_size = undefined
            });
        {error, enoent} when Follow ->
            poll_then_retry(Iter, Iter#iter.poll_interval_ms);
        {error, enoent} ->
            %% In non-follow mode, a missing successor is treated as
            %% the natural end of the log — the writer has finished
            %% with this segment but has not yet (and may never)
            %% create the next one.
            end_of_log;
        {error, _} = E ->
            E
    end.

%% @private
%% Reads one frame at `offset`. `Bound` is the byte position past which
%% the reader must not read (head_offset for the head segment, file
%% size for a sealed segment). `Kind` carries the interpretation of
%% `Bound`:
%%
%% - `head` — `Bound` is the writer's published head offset. The
%%   publish protocol guarantees that any frame whose header is visible
%%   below `Bound` is fully written below `Bound` (the writer publishes
%%   only after `prim_file:write/2` returns). Both `fsync_mode = sync`
%%   and `fsync_mode = batched` follow this contract — `batched` only
%%   defers the `datasync` past publish, it does not publish ahead of
%%   the write. The `FrameEnd > Bound` branch is therefore unreachable
%%   under any shipped fsync mode; it is retained as a defensive guard
%%   so a hypothetical future publish-ahead mode (e.g. a "publish on
%%   intent" or pre-write reservation scheme) cannot tip a reader into
%%   the corruption-handling path against the head.
%% - `sealed` — `Bound` is the file's exact byte size, frozen by the
%%   writer's `datasync` + `close` before bumping the head atomic.
%%   `FrameEnd > Bound` here means the segment is corrupt; surface as
%%   `{error, truncated_segment}` so the recovery scanner can decide
%%   policy.
read_frame(#iter{} = Iter, Kind, Bound) ->
    Off = Iter#iter.offset,
    case read_frame_header(Iter#iter.fd, Off) of
        {ok, FrameLen} ->
            FrameEnd = Off + FrameLen,
            case {FrameEnd =< Bound, Kind} of
                {true, _} ->
                    read_frame_body(Iter, FrameLen);
                {false, head} ->
                    not_enough_bytes_response(Iter);
                {false, sealed} ->
                    {error,
                        {truncated_segment, #{
                            segment => Iter#iter.segment_id,
                            offset => Off,
                            frame_len => FrameLen,
                            file_size => Bound
                        }}}
            end;
        not_enough_bytes ->
            not_enough_bytes_response(Iter);
        {error, _} = E ->
            E
    end.

%% @private
not_enough_bytes_response(#iter{follow = true} = Iter) ->
    poll_then_retry(Iter, Iter#iter.poll_interval_ms);
not_enough_bytes_response(#iter{}) ->
    end_of_log.

%% @private
read_frame_header(Fd, Off) ->
    case prim_file:pread(Fd, Off, ?FRAME_HEADER_BYTES) of
        {ok, <<Magic:32/big-unsigned, FrameLen:32/big-unsigned, _/binary>>} when
            Magic =:= ?BONDY_OPLOG_WAL_FRAME_MAGIC,
            FrameLen >= ?FRAME_HEADER_BYTES
        ->
            {ok, FrameLen};
        {ok, Bin} when byte_size(Bin) < ?FRAME_HEADER_BYTES ->
            not_enough_bytes;
        {ok, <<Magic:32/big-unsigned, _/binary>>} when
            Magic =/= ?BONDY_OPLOG_WAL_FRAME_MAGIC
        ->
            {error, bad_magic};
        {ok, <<_:32, FrameLen:32, _/binary>>} when
            FrameLen < ?FRAME_HEADER_BYTES
        ->
            {error, length_invalid};
        eof ->
            not_enough_bytes;
        {error, _} = E ->
            E
    end.

%% @private
read_frame_body(
    #iter{fd = Fd, offset = Off, segment_id = Seg} = Iter, FrameLen
) ->
    case prim_file:pread(Fd, Off, FrameLen) of
        {ok, FrameBin} when byte_size(FrameBin) =:= FrameLen ->
            decode_and_advance(Iter, FrameBin, FrameLen, Seg, Off);
        {ok, _Short} ->
            not_enough_bytes_response(Iter);
        eof ->
            not_enough_bytes_response(Iter);
        {error, _} = E ->
            E
    end.

%% @private
decode_and_advance(#iter{} = Iter, FrameBin, FrameLen, Seg, Off) ->
    case bondy_oplog_wal_frame:decode(FrameBin) of
        {ok, RawBody, #{flags := Flags}} ->
            case
                bondy_oplog_wal_codec:decode_body(
                    RawBody, Flags, codec_opts(Iter)
                )
            of
                {ok, Body} ->
                    case decode_batch_body(Body) of
                        {ok, Batch} ->
                            Hlcs = [
                                bondy_oplog_event:key_hlc(
                                    bondy_oplog_event:key(E)
                                )
                             || E <- Batch
                            ],
                            NextOff = Off + FrameLen,
                            NewIter = Iter#iter{offset = NextOff},
                            deliver_or_filter(
                                NewIter, Batch, Hlcs, Seg, NextOff
                            );
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
codec_opts(#iter{instance_id = Id, body_encryption = Enc}) ->
    #{instance_id => Id, body_encryption => Enc}.

%% @private
%% Applies the HLC seek-target lower bound and `hlc_upper_bound` opt to a
%% just-decoded batch.
%%
%% - If `hlc_upper_bound` is set and the batch's first HLC exceeds it,
%%   return `end_of_log` (the bound makes this frame and everything
%%   later out of scope for this reader).
%% - If `seek_target` is set and the batch's first HLC is below it, skip
%%   the frame and recurse into `do_next/1` so the iter advances. The
%%   seek target stays in place because later frames in the same
%%   segment may also be below T (sparse index entries land at frame
%%   boundaries, not on exact HLCs).
%% - Otherwise clear `seek_target` (one-shot) and deliver the batch.
deliver_or_filter(
    #iter{hlc_upper_bound = UB}, _Batch, [FirstHlc | _], _Seg, _NextOff
) when is_integer(UB), FirstHlc > UB ->
    end_of_log;
deliver_or_filter(
    #iter{seek_target = T} = Iter, _Batch, [FirstHlc | _], _Seg, _NextOff
) when is_integer(T), FirstHlc < T ->
    do_next(Iter);
deliver_or_filter(#iter{seek_target = T} = Iter, Batch, Hlcs, Seg, NextOff) when
    is_integer(T)
->
    %% First qualifying frame reached. Clear the target so subsequent
    %% `next/1` calls don't re-check (it's monotonically irrelevant
    %% after this point: the writer assigns HLCs in append order).
    {ok, Batch, Hlcs, {Seg, NextOff}, Iter#iter{seek_target = undefined}};
deliver_or_filter(#iter{} = Iter, Batch, Hlcs, Seg, NextOff) ->
    {ok, Batch, Hlcs, {Seg, NextOff}, Iter}.

%% @private
%% A frame body is `term_to_binary([Event, ...])`. We accept any
%% non-empty list of `#bondy_oplog_event{}` records; anything else is a
%% framing error.
%%
%% Deliberately NOT `[safe]`: this reads frames THIS node wrote. Under
%% `[safe]` an event carrying an atom absent from the VM's atom table at
%% replay time raises `badarg` and is reported as `{invalid_batch, badarg}` —
%% i.e. a perfectly good record is misattributed to frame corruption and
%% silently dropped. `binary_to_term/1` still raises `badarg` on malformed
%% bytes, so real framing errors are caught exactly as before. Peer-shipped
%% bytes are decoded under `[safe]` at the wire boundary (`C-2`), which is
%% where that control belongs.
decode_batch_body(Body) ->
    try binary_to_term(Body) of
        [_ | _] = Batch ->
            case lists:all(fun is_event/1, Batch) of
                true -> {ok, Batch};
                false -> {error, {invalid_batch, non_event}}
            end;
        [] ->
            {error, {invalid_batch, empty}};
        Other ->
            {error, {invalid_batch, {non_list, Other}}}
    catch
        error:badarg ->
            {error, {invalid_batch, badarg}}
    end.

%% @private
is_event(#bondy_oplog_event{}) -> true;
is_event(_) -> false.
