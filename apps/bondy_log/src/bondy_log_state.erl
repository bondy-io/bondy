%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_log_state).

-include("bondy_log.hrl").

-moduledoc """
Per-instance persistent-state files for the WAL: the consumer's
`consumer.offset` and the WAL's `snapshot.watermark`.

Both files are written with `bondy_log_io:write_atomic/3` (tmp →
datasync → rename → fsync dir over the `bondy_mst_io` seams). Keeping
them in one module avoids duplicating that
boilerplate.

## Consumer offset

The log's consumer writes `consumer.offset` to commit the position up
to which records have been durably consumed (the oplog applier: applied
to the MST). The WAL reads it on recovery to clamp it to a known-good
frame boundary, and the consumer resumes from it.

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

The watermark is the highest key that has been covered by a
compaction snapshot. It bounds retention: a segment is only eligible
for deletion once **all** of its events are key-covered by the
watermark.

File format is a single-term, `file:consult/1`-readable Erlang file:

```erlang
{snapshot_watermark_version, 1}.
{hlc, 17155200001230000}.
```

The watermark is the slowest-evolving piece of WAL state — a few
writes per minute at most — so the per-rewrite fsync cost is
negligible.

## Durability

Both files use the same four-step durability sequence:

1. Write `<file>.tmp` with the new content.
2. `datasync` the temp file.
3. `rename(<file>.tmp, <file>)` — atomic on POSIX.
4. `datasync` the enclosing directory — required on ext4/xfs.

An interrupted rename leaves either the old or the new content on
disk, never a partial mix.
""".

-record(consumer_offset, {
    %% Initially 0 for a fresh WAL; clamped to the first live segment on
    %% recovery if the previously committed segment has been swept.
    committed_segment :: non_neg_integer(),
    %% Byte offset of the START of the next frame to apply. Always a
    %% frame boundary — a consumer never commits mid-frame. On
    %% recovery, clamped to the largest frame-start offset ≤ the file
    %% value, with `≤ last_valid_offset_of(committed_segment)` enforced.
    committed_frame_offset :: non_neg_integer(),
    %% key of the last applied event. `undefined` for a never-committed
    %% WAL.
    %% The committed record key; `committed_hlc` on disk, the name the
    %% file had when only the oplog wrote it.
    committed_key :: bondy_log_record:key() | undefined,
    %% Monotonic counter incremented on every commit. Diagnostic only.
    commit_count :: non_neg_integer(),
    schema_version = ?BONDY_LOG_CONSUMER_OFFSET_VERSION :: pos_integer()
}).

-type consumer_offset() :: #consumer_offset{}.

-export_type([consumer_offset/0]).

%% Consumer offset
-export([new_consumer_offset/0]).
-export([read_consumer_offset/1]).
-export([write_consumer_offset/2]).
-export([committed_segment/1]).
-export([committed_frame_offset/1]).
-export([committed_key/1]).
-export([commit_count/1]).
-export([with_position/3]).
-export([with_key/2]).
-export([with_commit_count/2]).

%% Snapshot watermark
-export([read_snapshot_watermark/1]).
-export([write_snapshot_watermark/2]).

-define(SEG_HEADER_BYTES, ?BONDY_LOG_SEGMENT_HEADER_BYTES).

%% =============================================================================
%% CONSUMER OFFSET API
%% =============================================================================

-doc """
Returns a fresh consumer offset: segment 0, offset at the segment
header boundary, no key, count zero. This is the "nothing committed
yet" state and is what `read_consumer_offset/1` returns for a missing
file.
""".
-spec new_consumer_offset() -> consumer_offset().

new_consumer_offset() ->
    #consumer_offset{
        committed_segment = 0,
        committed_frame_offset = ?SEG_HEADER_BYTES,
        committed_key = undefined,
        commit_count = 0
    }.

-doc """
Reads and parses `consumer.offset` from `Dir`.

Returns:
- `{ok, consumer_offset()}` on success.
- `{ok, new_consumer_offset()}` when the file is missing — a fresh /
  never-committed WAL is indistinguishable from one whose consumer has
  never run.
- `{error, Reason}` for malformed content / unsupported version /
  missing required field.
""".
-spec read_consumer_offset(file:filename_all()) ->
    {ok, consumer_offset()} | {error, term()}.

read_consumer_offset(Dir) ->
    Path = filename:join(Dir, ?BONDY_LOG_CONSUMER_OFFSET_FILENAME),
    case file:consult(Path) of
        {ok, Terms} ->
            parse_consumer_offset_terms(Terms);
        {error, enoent} ->
            {ok, new_consumer_offset()};
        {error, _} = E ->
            E
    end.

-doc """
Atomically writes `consumer_offset()` to `Dir`. Uses the four-step
durability sequence (write tmp → datasync → rename → fsync dir) and has
`bondy_log_io:write_atomic/3`'s error contract, raising on a directory
fsync that fails once the rename has happened.
""".
-spec write_consumer_offset(file:filename_all(), consumer_offset()) ->
    ok | {error, term()}.

write_consumer_offset(Dir, #consumer_offset{} = CO) ->
    TmpPath = filename:join(
        Dir, ?BONDY_LOG_CONSUMER_OFFSET_TMP_FILENAME
    ),
    FinalPath = filename:join(
        Dir, ?BONDY_LOG_CONSUMER_OFFSET_FILENAME
    ),
    bondy_log_io:write_atomic(FinalPath, format_consumer_offset(CO), #{
        tmp_path => TmpPath
    }).

-doc "Returns the committed segment id.".
-spec committed_segment(consumer_offset()) -> non_neg_integer().
committed_segment(#consumer_offset{committed_segment = S}) -> S.

-doc "Returns the committed frame-start byte offset within the segment.".
-spec committed_frame_offset(consumer_offset()) -> non_neg_integer().
committed_frame_offset(#consumer_offset{committed_frame_offset = O}) -> O.

-doc "Returns the committed key, or `undefined` if nothing was ever committed.".
-spec committed_key(consumer_offset()) -> bondy_log_record:key() | undefined.
committed_key(#consumer_offset{committed_key = H}) -> H.

-doc "Returns the monotonic commit count.".
-spec commit_count(consumer_offset()) -> non_neg_integer().
commit_count(#consumer_offset{commit_count = N}) -> N.

-doc """
Replaces the `committed_segment` and `committed_frame_offset` fields.
""".
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

-doc "Replaces the committed key.".
-spec with_key(consumer_offset(), bondy_log_record:key() | undefined) ->
    consumer_offset().
with_key(#consumer_offset{} = CO, Key) when is_integer(Key), Key >= 0 ->
    CO#consumer_offset{committed_key = Key};
with_key(#consumer_offset{} = CO, undefined) ->
    CO#consumer_offset{committed_key = undefined}.

-doc "Replaces the `commit_count` field.".
-spec with_commit_count(consumer_offset(), non_neg_integer()) ->
    consumer_offset().
with_commit_count(#consumer_offset{} = CO, N) when is_integer(N), N >= 0 ->
    CO#consumer_offset{commit_count = N}.

%% =============================================================================
%% SNAPSHOT WATERMARK API
%% =============================================================================

-doc """
Reads the snapshot watermark from `Dir`.

Returns:
- `{ok, Key}` — the persisted watermark.
- `{ok, undefined}` — no watermark file exists yet (fresh WAL).
- `{error, Reason}` — the file exists but cannot be parsed (wrong
  version, missing field, etc.).
""".
-spec read_snapshot_watermark(file:filename_all()) ->
    {ok, bondy_log_record:key() | undefined} | {error, term()}.

read_snapshot_watermark(Dir) ->
    Path = filename:join(
        Dir, ?BONDY_LOG_SNAPSHOT_WATERMARK_FILENAME
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

-doc """
Atomically writes `Key` as the new watermark. Uses the same four-step
durability sequence as `write_consumer_offset/2`, with the same error
contract: a returned error leaves the prior on-disk watermark intact; a
directory fsync that fails after the rename raises.
""".
-spec write_snapshot_watermark(file:filename_all(), bondy_log_record:key()) ->
    ok | {error, term()}.

write_snapshot_watermark(Dir, Key) when is_integer(Key), Key >= 0 ->
    TmpPath = filename:join(
        Dir, ?BONDY_LOG_SNAPSHOT_WATERMARK_TMP_FILENAME
    ),
    FinalPath = filename:join(
        Dir, ?BONDY_LOG_SNAPSHOT_WATERMARK_FILENAME
    ),
    bondy_log_io:write_atomic(FinalPath, format_snapshot_watermark(Key), #{
        tmp_path => TmpPath
    }).

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
        Key = maps:get(committed_hlc, Map, undefined),
        validate_key_or_undefined(Key),
        Count = maps:get(commit_count, Map, 0),
        validate_non_neg_integer(commit_count, Count),
        Version = maps:get(
            schema_version, Map, ?BONDY_LOG_CONSUMER_OFFSET_VERSION
        ),
        validate_consumer_offset_version(Version),
        {ok, #consumer_offset{
            committed_segment = Seg,
            committed_frame_offset = Off,
            committed_key = Key,
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
validate_consumer_offset_version(?BONDY_LOG_CONSUMER_OFFSET_VERSION) ->
    ok;
validate_consumer_offset_version(V) ->
    throw({invalid, {unsupported_schema_version, V}}).

%% @private
format_consumer_offset(#consumer_offset{
    committed_segment = Seg,
    committed_frame_offset = Off,
    committed_key = Key,
    commit_count = Count,
    schema_version = Version
}) ->
    bondy_consult:encode([
        {committed_segment, Seg},
        {committed_frame_offset, Off},
        {committed_hlc, Key},
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
        Key = required(hlc, Map),
        validate_key(Key),
        {ok, Key}
    catch
        throw:{missing_field, F} -> {error, {missing_field, F}};
        throw:{invalid, R} -> {error, R}
    end.

%% @private
validate_snapshot_watermark_version(
    ?BONDY_LOG_SNAPSHOT_WATERMARK_VERSION
) ->
    ok;
validate_snapshot_watermark_version(V) ->
    throw({invalid, {unsupported_snapshot_watermark_version, V}}).

%% @private
format_snapshot_watermark(Key) ->
    bondy_consult:encode([
        {snapshot_watermark_version, ?BONDY_LOG_SNAPSHOT_WATERMARK_VERSION},
        {hlc, Key}
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
validate_key_or_undefined(undefined) ->
    ok;
validate_key_or_undefined(V) when is_integer(V), V >= 0 -> ok;
validate_key_or_undefined(V) ->
    throw({invalid, {invalid_field, committed_hlc, V}}).

%% @private
validate_key(H) when is_integer(H), H >= 0 -> ok;
validate_key(V) -> throw({invalid, {invalid_key, V}}).
