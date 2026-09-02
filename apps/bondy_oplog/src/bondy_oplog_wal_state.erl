%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal_state).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance persistent-state files for the WAL: the applier's
`consumer.offset` and the WAL's `snapshot.watermark`.

Both files share the tmp-then-rename atomic-write pattern and use the
same `bondy_mst_io` primitives (`datasync/1`, `rename/2`,
`fsync_dir/1`). Keeping them in one module avoids duplicating that
boilerplate.

## Consumer offset

The applier writes `consumer.offset` to commit the position up to
which events have been durably applied to the MST. The WAL reads it
on recovery to resume the applier from a known-good frame boundary.

The on-disk format is a sequence of `file:consult/1`-readable Erlang
terms, one per line, matching the manifest pattern for debuggability:

```erlang
{committed_segment, 42}.
{committed_frame_offset, 1048576}.
{committed_hlc, 1715521234567890}.
{commit_count, 1234567}.
{schema_version, 1}.
```

The consumer offset is exposed as the record type
`consumer_offset()` with read-only accessors and copy-and-replace
setters (`with_*`).

A missing `consumer.offset` is **not** an error — it means nothing
has ever been committed. `read_consumer_offset/1` returns
`{ok, new_consumer_offset()}` in that case so the WAL's recovery
treats a fresh WAL identically to a never-committed-against WAL.

## Snapshot watermark

The watermark is the highest HLC that has been covered by a
compaction snapshot. It bounds retention: a segment is only eligible
for deletion once **all** of its events are HLC-covered by the
watermark.

File format is a single-term, `file:consult/1`-readable Erlang file:

```erlang
{snapshot_watermark_version, 1}.
{hlc, 17155200001230000}.
```

The watermark is the slowest-evolving piece of WAL state — a few
writes per minute at most — so the per-rewrite fsync cost is
negligible.

## Atomic write sequence

Both files use the same four-step durability sequence:

1. Write `<file>.tmp` with the new content.
2. `datasync` the temp file.
3. `rename(<file>.tmp, <file>)` — atomic on POSIX.
4. `datasync` the enclosing directory — required on ext4/xfs.

An interrupted rename leaves either the old or the new content on
disk, never a partial mix.
""").

-record(consumer_offset, {
    %% Initially 0 for a fresh WAL; clamped to the first live segment on
    %% recovery if the previously committed segment has been swept.
    committed_segment :: non_neg_integer(),
    %% Byte offset of the START of the next frame to apply. Always a
    %% frame boundary — the applier never commits mid-frame. On
    %% recovery, clamped to the largest frame-start offset ≤ the file
    %% value, with `≤ last_valid_offset_of(committed_segment)` enforced.
    committed_frame_offset :: non_neg_integer(),
    %% HLC of the last applied event. `undefined` for a never-committed
    %% WAL.
    committed_hlc :: bondy_oplog_hlc:hlc() | undefined,
    %% Monotonic counter incremented on every commit. Diagnostic only.
    commit_count :: non_neg_integer(),
    schema_version = ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_VERSION :: pos_integer()
}).

-type consumer_offset() :: #consumer_offset{}.

-export_type([consumer_offset/0]).

%% Consumer offset
-export([new_consumer_offset/0]).
-export([read_consumer_offset/1]).
-export([write_consumer_offset/2]).
-export([committed_segment/1]).
-export([committed_frame_offset/1]).
-export([committed_hlc/1]).
-export([commit_count/1]).
-export([with_position/3]).
-export([with_hlc/2]).
-export([with_commit_count/2]).

%% Snapshot watermark
-export([read_snapshot_watermark/1]).
-export([write_snapshot_watermark/2]).

-define(SEG_HEADER_BYTES, ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES).

%% =============================================================================
%% CONSUMER OFFSET API
%% =============================================================================

?DOC("""
Returns a fresh consumer offset: segment 0, offset at the segment
header boundary, no HLC, count zero. This is the "nothing committed
yet" state and is what `read_consumer_offset/1` returns for a missing
file.
""").
-spec new_consumer_offset() -> consumer_offset().

new_consumer_offset() ->
    #consumer_offset{
        committed_segment = 0,
        committed_frame_offset = ?SEG_HEADER_BYTES,
        committed_hlc = undefined,
        commit_count = 0
    }.

?DOC("""
Reads and parses `consumer.offset` from `Dir`.

Returns:
- `{ok, consumer_offset()}` on success.
- `{ok, new_consumer_offset()}` when the file is missing — a fresh /
  never-committed WAL is indistinguishable from one whose applier has
  never run.
- `{error, Reason}` for malformed content / unsupported version /
  missing required field.
""").
-spec read_consumer_offset(file:filename_all()) ->
    {ok, consumer_offset()} | {error, term()}.

read_consumer_offset(Dir) ->
    Path = filename:join(Dir, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_FILENAME),
    case file:consult(Path) of
        {ok, Terms} ->
            parse_consumer_offset_terms(Terms);
        {error, enoent} ->
            {ok, new_consumer_offset()};
        {error, _} = E ->
            E
    end.

?DOC("""
Atomically writes `consumer_offset()` to `Dir`. Uses the four-step
durability sequence (write tmp → datasync → rename → fsync dir).
""").
-spec write_consumer_offset(file:filename_all(), consumer_offset()) ->
    ok | {error, term()}.

write_consumer_offset(Dir, #consumer_offset{} = CO) ->
    TmpPath = filename:join(
        Dir, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_TMP_FILENAME
    ),
    FinalPath = filename:join(
        Dir, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_FILENAME
    ),
    atomic_write(Dir, TmpPath, FinalPath, format_consumer_offset(CO)).

?DOC("Returns the committed segment id.").
-spec committed_segment(consumer_offset()) -> non_neg_integer().
committed_segment(#consumer_offset{committed_segment = S}) -> S.

?DOC("Returns the committed frame-start byte offset within the segment.").
-spec committed_frame_offset(consumer_offset()) -> non_neg_integer().
committed_frame_offset(#consumer_offset{committed_frame_offset = O}) -> O.

?DOC(
    "Returns the committed HLC, or `undefined` if nothing was ever committed."
).
-spec committed_hlc(consumer_offset()) -> bondy_oplog_hlc:hlc() | undefined.
committed_hlc(#consumer_offset{committed_hlc = H}) -> H.

?DOC("Returns the monotonic commit count.").
-spec commit_count(consumer_offset()) -> non_neg_integer().
commit_count(#consumer_offset{commit_count = N}) -> N.

?DOC("""
Replaces the `committed_segment` and `committed_frame_offset` fields.
""").
-spec with_position(consumer_offset(), non_neg_integer(), non_neg_integer()) ->
    consumer_offset().
with_position(#consumer_offset{} = CO, Seg, Off) when
    is_integer(Seg),
    Seg >= 0,
    is_integer(Off),
    Off >= ?SEG_HEADER_BYTES
->
    CO#consumer_offset{
        committed_segment = Seg,
        committed_frame_offset = Off
    }.

?DOC("Replaces the `committed_hlc` field.").
-spec with_hlc(consumer_offset(), bondy_oplog_hlc:hlc() | undefined) ->
    consumer_offset().
with_hlc(#consumer_offset{} = CO, Hlc) when is_integer(Hlc), Hlc >= 0 ->
    CO#consumer_offset{committed_hlc = Hlc};
with_hlc(#consumer_offset{} = CO, undefined) ->
    CO#consumer_offset{committed_hlc = undefined}.

?DOC("Replaces the `commit_count` field.").
-spec with_commit_count(consumer_offset(), non_neg_integer()) ->
    consumer_offset().
with_commit_count(#consumer_offset{} = CO, N) when is_integer(N), N >= 0 ->
    CO#consumer_offset{commit_count = N}.

%% =============================================================================
%% SNAPSHOT WATERMARK API
%% =============================================================================

?DOC("""
Reads the snapshot watermark from `Dir`.

Returns:
- `{ok, Hlc}` — the persisted watermark.
- `{ok, undefined}` — no watermark file exists yet (fresh WAL).
- `{error, Reason}` — the file exists but cannot be parsed (wrong
  version, missing field, etc.).
""").
-spec read_snapshot_watermark(file:filename_all()) ->
    {ok, bondy_oplog_hlc:hlc() | undefined} | {error, term()}.

read_snapshot_watermark(Dir) ->
    Path = filename:join(
        Dir, ?BONDY_OPLOG_WAL_SNAPSHOT_WATERMARK_FILENAME
    ),
    case filelib:is_regular(Path) of
        false ->
            {ok, undefined};
        true ->
            case file:consult(Path) of
                {ok, Terms} -> parse_snapshot_watermark_terms(Terms);
                {error, _} = E -> E
            end
    end.

?DOC("""
Atomically writes `Hlc` as the new watermark. Uses the same four-step
durability sequence as `write_consumer_offset/2`. Errors at any step
short-circuit and leave the prior on-disk watermark intact.
""").
-spec write_snapshot_watermark(file:filename_all(), bondy_oplog_hlc:hlc()) ->
    ok | {error, term()}.

write_snapshot_watermark(Dir, Hlc) when is_integer(Hlc), Hlc >= 0 ->
    TmpPath = filename:join(
        Dir, ?BONDY_OPLOG_WAL_SNAPSHOT_WATERMARK_TMP_FILENAME
    ),
    FinalPath = filename:join(
        Dir, ?BONDY_OPLOG_WAL_SNAPSHOT_WATERMARK_FILENAME
    ),
    atomic_write(Dir, TmpPath, FinalPath, format_snapshot_watermark(Hlc)).

%% =============================================================================
%% PRIVATE — CONSUMER OFFSET
%% =============================================================================

%% @private
parse_consumer_offset_terms(Terms) ->
    Map = terms_to_map(Terms),
    try
        Seg = required(committed_segment, Map),
        validate_non_neg_integer(committed_segment, Seg),
        Off = required(committed_frame_offset, Map),
        validate_non_neg_integer(committed_frame_offset, Off),
        Hlc = maps:get(committed_hlc, Map, undefined),
        validate_hlc_or_undefined(Hlc),
        Count = maps:get(commit_count, Map, 0),
        validate_non_neg_integer(commit_count, Count),
        Version = maps:get(
            schema_version, Map, ?BONDY_OPLOG_WAL_CONSUMER_OFFSET_VERSION
        ),
        validate_consumer_offset_version(Version),
        {ok, #consumer_offset{
            committed_segment = Seg,
            committed_frame_offset = Off,
            committed_hlc = Hlc,
            commit_count = Count,
            schema_version = Version
        }}
    catch
        throw:{missing_field, F} ->
            {error, {missing_field, F}};
        throw:{invalid, R} ->
            {error, R}
    end.

%% @private
validate_consumer_offset_version(?BONDY_OPLOG_WAL_CONSUMER_OFFSET_VERSION) ->
    ok;
validate_consumer_offset_version(V) ->
    throw({invalid, {unsupported_schema_version, V}}).

%% @private
format_consumer_offset(#consumer_offset{
    committed_segment = Seg,
    committed_frame_offset = Off,
    committed_hlc = Hlc,
    commit_count = Count,
    schema_version = Version
}) ->
    bondy_consult:encode([
        {committed_segment, Seg},
        {committed_frame_offset, Off},
        {committed_hlc, Hlc},
        {commit_count, Count},
        {schema_version, Version}
    ]).

%% =============================================================================
%% PRIVATE — SNAPSHOT WATERMARK
%% =============================================================================

%% @private
parse_snapshot_watermark_terms(Terms) ->
    Map = terms_to_map(Terms),
    try
        Version = required(snapshot_watermark_version, Map),
        validate_snapshot_watermark_version(Version),
        Hlc = required(hlc, Map),
        validate_hlc(Hlc),
        {ok, Hlc}
    catch
        throw:{missing_field, F} -> {error, {missing_field, F}};
        throw:{invalid, R} -> {error, R}
    end.

%% @private
validate_snapshot_watermark_version(
    ?BONDY_OPLOG_WAL_SNAPSHOT_WATERMARK_VERSION
) ->
    ok;
validate_snapshot_watermark_version(V) ->
    throw({invalid, {unsupported_snapshot_watermark_version, V}}).

%% @private
format_snapshot_watermark(Hlc) ->
    bondy_consult:encode([
        {snapshot_watermark_version,
            ?BONDY_OPLOG_WAL_SNAPSHOT_WATERMARK_VERSION},
        {hlc, Hlc}
    ]).

%% =============================================================================
%% PRIVATE — SHARED HELPERS
%% =============================================================================

%% @private
terms_to_map(Terms) ->
    lists:foldl(
        fun
            ({K, V}, Acc) -> Acc#{K => V};
            (_, Acc) -> Acc
        end,
        #{},
        Terms
    ).

%% @private
required(K, M) ->
    case maps:find(K, M) of
        {ok, V} -> V;
        error -> throw({missing_field, K})
    end.

%% @private
validate_non_neg_integer(_K, V) when is_integer(V), V >= 0 -> ok;
validate_non_neg_integer(K, V) -> throw({invalid, {invalid_field, K, V}}).

%% @private
validate_hlc_or_undefined(undefined) ->
    ok;
validate_hlc_or_undefined(V) when is_integer(V), V >= 0 -> ok;
validate_hlc_or_undefined(V) ->
    throw({invalid, {invalid_field, committed_hlc, V}}).

%% @private
validate_hlc(H) when is_integer(H), H >= 0 -> ok;
validate_hlc(V) -> throw({invalid, {invalid_hlc, V}}).

%% @private
%% Shared atomic-write helper: tmp → datasync → rename → fsync dir.
atomic_write(Dir, TmpPath, FinalPath, Bin) ->
    case write_and_sync(TmpPath, Bin) of
        ok ->
            case bondy_mst_io:rename(TmpPath, FinalPath) of
                ok ->
                    bondy_mst_io:fsync_dir(Dir);
                {error, _} = E ->
                    _ = prim_file:delete(TmpPath),
                    E
            end;
        {error, _} = E ->
            _ = prim_file:delete(TmpPath),
            E
    end.

%% @private
write_and_sync(TmpPath, Bin) ->
    case prim_file:open(TmpPath, [write, raw, binary]) of
        {ok, Fd} ->
            Res =
                case prim_file:write(Fd, Bin) of
                    ok ->
                        case bondy_mst_io:datasync(Fd) of
                            ok -> ok;
                            {error, _} = E1 -> E1
                        end;
                    {error, _} = E2 ->
                        E2
                end,
            ok = prim_file:close(Fd),
            Res;
        {error, _} = E ->
            E
    end.
