%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal_manifest).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance WAL manifest read/write with atomic rename semantics.

The manifest records the metadata required to open a WAL: the current
head segment id, the list of live sealed segments with their
`FirstHlc`, retention configuration, etc.

Format is a sequence of `file:consult/1`-readable Erlang terms, one
per line, for human debuggability:

```erlang
{manifest_version, 1}.
{instance_id, <<"registry-shard-17">>}.
{current_segment, 42}.
{live_segments, [{40, 1715520000123}, {41, 1715520600456}, {42, undefined}]}.
{deleted_through, 39}.
{retention, [...]}.
{scrubber_alerts, [{40, bad_crc}]}.
{schema_version, 1}.
{created_at, 1715520000000}.
{last_rotated_at, 1715522400000}.
```

`scrubber_alerts` is a proplist of `{SegmentId, Reason}` raised by
the integrity scrubber. Defaults to `[]`. Entries are added by
`bondy_oplog_wal:mark_segment_alert/3` and cleared by
`bondy_oplog_wal:clear_segment_alert/2`. The list is read as
`[]` if the term is absent from the manifest (forward-compat).

Writes follow the tmp-then-rename pattern:

1. Write `manifest.tmp` with the new content.
2. `datasync` the temp file.
3. `rename(manifest.tmp, manifest)` — atomic on POSIX same-filesystem.
4. `datasync` the enclosing directory — required on ext4/xfs.

An interrupted rename leaves either the old or the new manifest; never
a partial mix.
""").

-record(?MODULE, {
    manifest_version = ?BONDY_OPLOG_WAL_MANIFEST_VERSION ::
        non_neg_integer(),
    instance_id :: instance_id(),
    current_segment :: non_neg_integer(),
    live_segments :: [{non_neg_integer(), hlc_or_undefined()}],
    deleted_through :: non_neg_integer(),
    retention = [] :: [{atom(), term()}],
    scrubber_alerts = [] :: [scrubber_alert()],
    schema_version = 1 :: pos_integer(),
    created_at :: non_neg_integer(),
    last_rotated_at :: non_neg_integer()
}).

-type hlc_or_undefined() :: bondy_oplog_hlc:hlc() | undefined.
-type t() :: #?MODULE{}.
-type live_segment() :: {non_neg_integer(), hlc_or_undefined()}.
-type scrubber_alert() :: {SegmentId :: non_neg_integer(), Reason :: atom()}.

-export_type([t/0]).
-export_type([live_segment/0]).
-export_type([scrubber_alert/0]).

-export([new/3]).
-export([read/1]).
-export([write/2]).
-export([instance_id/1]).
-export([current_segment/1]).
-export([live_segments/1]).
-export([deleted_through/1]).
-export([retention/1]).
-export([scrubber_alerts/1]).
-export([created_at/1]).
-export([last_rotated_at/1]).
-export([with_current_segment/3]).
-export([with_live_segments/2]).
-export([with_deleted_through/2]).
-export([with_retention/2]).
-export([with_scrubber_alert/3]).
-export([without_scrubber_alert/2]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Constructs a fresh manifest for a new instance.

`SegmentId` is the id of the first segment to be created (typically
`0`); it is set as both `current_segment` and the sole entry in
`live_segments` with an `undefined` `FirstHlc` (it will be filled in
when the first batch is written and the manifest is rewritten on
rotation).
""").
-spec new(
    InstanceId :: instance_id(),
    SegmentId :: non_neg_integer(),
    Retention :: [{atom(), term()}]
) -> t().

new(InstanceId, SegmentId, Retention) when
    is_binary(InstanceId),
    byte_size(InstanceId) > 0,
    is_integer(SegmentId),
    SegmentId >= 0,
    is_list(Retention)
->
    Now = erlang:system_time(millisecond),
    #?MODULE{
        instance_id = InstanceId,
        current_segment = SegmentId,
        live_segments = [{SegmentId, undefined}],
        deleted_through = 0,
        retention = Retention,
        created_at = Now,
        last_rotated_at = Now
    }.

?DOC("""
Reads and parses the manifest at `Dir`.

Returns `{ok, Manifest}` on success or `{error, Reason}` if the file is
missing, unreadable, or fails validation (unknown manifest version,
missing required field, structurally invalid live_segments list, etc.).

The on-disk format is `file:consult/1`-readable; this function uses
`file:consult/1` directly so a hand-edited manifest is still loadable.
""").
-spec read(Dir :: file:filename_all()) ->
    {ok, t()} | {error, term()}.

read(Dir) ->
    Path = filename:join(Dir, ?BONDY_OPLOG_WAL_MANIFEST_FILENAME),
    case file:consult(Path) of
        {ok, Terms} ->
            parse_terms(Terms);
        {error, _} = E ->
            E
    end.

?DOC("""
Atomically writes `Manifest` to `Dir`.

Implements the four-step durability sequence described in the module
docstring. Returns `ok` or `{error, Reason}`.

Errors at any step short-circuit the sequence and leave the prior
on-disk manifest intact (because the rename has not yet happened).
""").
-spec write(Dir :: file:filename_all(), t()) -> ok | {error, term()}.

write(Dir, #?MODULE{} = Manifest) ->
    TmpPath = filename:join(Dir, ?BONDY_OPLOG_WAL_MANIFEST_TMP_FILENAME),
    FinalPath = filename:join(Dir, ?BONDY_OPLOG_WAL_MANIFEST_FILENAME),
    Bin = format(Manifest),
    case write_and_sync(TmpPath, Bin) of
        ok ->
            case bondy_mst_io:rename(TmpPath, FinalPath) of
                ok ->
                    bondy_mst_io:fsync_dir(Dir);
                {error, _} = E ->
                    %% Leave the old manifest intact; remove the tmp
                    %% file so retries don't see a stale dangling tmp.
                    _ = prim_file:delete(TmpPath),
                    E
            end;
        {error, _} = E ->
            _ = prim_file:delete(TmpPath),
            E
    end.

?DOC("Returns the InstanceId of `Manifest`.").
-spec instance_id(t()) -> instance_id().
instance_id(#?MODULE{instance_id = Id}) -> Id.

?DOC("Returns the current head segment id.").
-spec current_segment(t()) -> non_neg_integer().
current_segment(#?MODULE{current_segment = Id}) -> Id.

?DOC("Returns the list of `{SegmentId, FirstHlc}` for live segments.").
-spec live_segments(t()) -> [live_segment()].
live_segments(#?MODULE{live_segments = L}) -> L.

?DOC("Returns the largest segment id known to be deleted.").
-spec deleted_through(t()) -> non_neg_integer().
deleted_through(#?MODULE{deleted_through = D}) -> D.

?DOC("Returns the retention configuration proplist.").
-spec retention(t()) -> [{atom(), term()}].
retention(#?MODULE{retention = R}) -> R.

?DOC("""
Returns the list of integrity-scrubber alerts as `{SegmentId, Reason}`
pairs. Empty list when no segment is quarantined.
""").
-spec scrubber_alerts(t()) -> [scrubber_alert()].
scrubber_alerts(#?MODULE{scrubber_alerts = A}) -> A.

?DOC("Returns the manifest creation timestamp (ms since epoch).").
-spec created_at(t()) -> non_neg_integer().
created_at(#?MODULE{created_at = T}) -> T.

?DOC("Returns the last rotation timestamp (ms since epoch).").
-spec last_rotated_at(t()) -> non_neg_integer().
last_rotated_at(#?MODULE{last_rotated_at = T}) -> T.

?DOC("""
Rotates the manifest: advances `current_segment`, appends the new
segment to `live_segments` with an `undefined` `FirstHlc`, and refreshes
`last_rotated_at`.

The `FirstHlc` of the previous (now-sealed) head segment is passed in;
the corresponding entry in `live_segments` is updated. Pass `undefined`
if the segment was empty (no batches written before rotation).
""").
-spec with_current_segment(
    t(),
    NewSegmentId :: non_neg_integer(),
    PrevSegmentFirstHlc :: hlc_or_undefined()
) -> t().

with_current_segment(
    #?MODULE{current_segment = Prev, live_segments = Live0} = M,
    NewSegmentId,
    PrevSegmentFirstHlc
) when
    is_integer(NewSegmentId), NewSegmentId > Prev
->
    Live1 = update_first_hlc(Live0, Prev, PrevSegmentFirstHlc),
    Live2 = Live1 ++ [{NewSegmentId, undefined}],
    M#?MODULE{
        current_segment = NewSegmentId,
        live_segments = Live2,
        last_rotated_at = erlang:system_time(millisecond)
    }.

?DOC("Replaces the `live_segments` list verbatim. Used by retention sweep.").
-spec with_live_segments(t(), [live_segment()]) -> t().
with_live_segments(#?MODULE{} = M, Live) when is_list(Live) ->
    M#?MODULE{live_segments = Live}.

?DOC("Advances `deleted_through`. Monotonically non-decreasing.").
-spec with_deleted_through(t(), non_neg_integer()) -> t().
with_deleted_through(#?MODULE{deleted_through = Old} = M, New) when
    is_integer(New), New >= Old
->
    M#?MODULE{deleted_through = New}.

?DOC("Replaces the retention proplist.").
-spec with_retention(t(), [{atom(), term()}]) -> t().
with_retention(#?MODULE{} = M, Retention) when is_list(Retention) ->
    M#?MODULE{retention = Retention}.

?DOC("""
Records a scrubber alert for `SegmentId` with `Reason`. If an alert
already exists for the segment, its reason is replaced (last writer
wins — multiple bad frames in the same segment still produce one
alert).
""").
-spec with_scrubber_alert(t(), non_neg_integer(), atom()) -> t().
with_scrubber_alert(#?MODULE{scrubber_alerts = A} = M, SegmentId, Reason) when
    is_integer(SegmentId), SegmentId >= 0, is_atom(Reason)
->
    A1 = lists:keystore(SegmentId, 1, A, {SegmentId, Reason}),
    M#?MODULE{scrubber_alerts = A1}.

?DOC("""
Clears any scrubber alert for `SegmentId`. Returns the manifest
unchanged if no alert was present.
""").
-spec without_scrubber_alert(t(), non_neg_integer()) -> t().
without_scrubber_alert(#?MODULE{scrubber_alerts = A} = M, SegmentId) when
    is_integer(SegmentId), SegmentId >= 0
->
    M#?MODULE{scrubber_alerts = lists:keydelete(SegmentId, 1, A)}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
parse_terms(Terms) ->
    %% Required fields per the manifest format. Missing required field is
    %% an error; unknown fields are tolerated for forward compatibility.
    Map = lists:foldl(
        fun
            ({K, V}, Acc) -> Acc#{K => V};
            (_, Acc) -> Acc
        end,
        #{},
        Terms
    ),
    try
        ManifestVersion = required(manifest_version, Map),
        validate_manifest_version(ManifestVersion),
        InstanceId = required(instance_id, Map),
        validate_instance_id(InstanceId),
        CurrentSegment = required(current_segment, Map),
        LiveSegments = required(live_segments, Map),
        validate_live_segments(LiveSegments),
        DeletedThrough = maps:get(deleted_through, Map, 0),
        Retention = maps:get(retention, Map, []),
        ScrubberAlerts = maps:get(scrubber_alerts, Map, []),
        validate_scrubber_alerts(ScrubberAlerts),
        SchemaVersion = maps:get(schema_version, Map, 1),
        CreatedAt = maps:get(created_at, Map, 0),
        LastRotatedAt = maps:get(last_rotated_at, Map, CreatedAt),
        {ok, #?MODULE{
            manifest_version = ManifestVersion,
            instance_id = InstanceId,
            current_segment = CurrentSegment,
            live_segments = LiveSegments,
            deleted_through = DeletedThrough,
            retention = Retention,
            scrubber_alerts = ScrubberAlerts,
            schema_version = SchemaVersion,
            created_at = CreatedAt,
            last_rotated_at = LastRotatedAt
        }}
    catch
        throw:{missing_field, F} ->
            {error, {missing_field, F}};
        throw:{invalid, Reason} ->
            {error, Reason}
    end.

%% @private
required(K, M) ->
    case maps:find(K, M) of
        {ok, V} -> V;
        error -> throw({missing_field, K})
    end.

%% @private
validate_manifest_version(?BONDY_OPLOG_WAL_MANIFEST_VERSION) ->
    ok;
validate_manifest_version(V) ->
    throw({invalid, {unsupported_manifest_version, V}}).

%% @private
validate_instance_id(B) when is_binary(B), byte_size(B) > 0 ->
    ok;
validate_instance_id(V) ->
    throw({invalid, {invalid_instance_id, V}}).

%% @private
validate_live_segments(L) when is_list(L) ->
    lists:foreach(
        fun
            ({Id, undefined}) when is_integer(Id), Id >= 0 -> ok;
            ({Id, H}) when is_integer(Id), Id >= 0, is_integer(H), H >= 0 -> ok;
            (Other) -> throw({invalid, {invalid_live_segment, Other}})
        end,
        L
    ).

%% @private
validate_scrubber_alerts(L) when is_list(L) ->
    lists:foreach(
        fun
            ({Id, R}) when is_integer(Id), Id >= 0, is_atom(R) -> ok;
            (Other) -> throw({invalid, {invalid_scrubber_alert, Other}})
        end,
        L
    );
validate_scrubber_alerts(V) ->
    throw({invalid, {invalid_scrubber_alerts, V}}).

%% @private
update_first_hlc(Live, SegmentId, FirstHlc) ->
    [
        case S of
            SegmentId -> {S, prefer_existing(H, FirstHlc)};
            _ -> {S, H}
        end
     || {S, H} <- Live
    ].

%% @private
%% Preserve an existing first_hlc rather than overwriting with the new
%% one — once a segment has its first HLC, it never changes.
prefer_existing(undefined, New) -> New;
prefer_existing(Existing, _) -> Existing.

%% @private
format(#?MODULE{
    manifest_version = MV,
    instance_id = InstanceId,
    current_segment = CurrentSegment,
    live_segments = LiveSegments,
    deleted_through = DeletedThrough,
    retention = Retention,
    scrubber_alerts = ScrubberAlerts,
    schema_version = SchemaVersion,
    created_at = CreatedAt,
    last_rotated_at = LastRotatedAt
}) ->
    %% `bondy_consult:encode/1` owns the byte encoding: one term per line,
    %% UTF-8. `instance_id` is a caller-supplied binary and `retention` a
    %% caller-supplied term, so both can carry bytes or characters that an
    %% `iolist_to_binary/1` of the rendering would write as invalid UTF-8
    %% and `file:consult/1` would then refuse. Pinned through disk by
    %% `bondy_oplog_wal_manifest_test:write_read_survives_high_bytes_test_`.
    bondy_consult:encode([
        {manifest_version, MV},
        {instance_id, InstanceId},
        {current_segment, CurrentSegment},
        {live_segments, LiveSegments},
        {deleted_through, DeletedThrough},
        {retention, Retention},
        {scrubber_alerts, ScrubberAlerts},
        {schema_version, SchemaVersion},
        {created_at, CreatedAt},
        {last_rotated_at, LastRotatedAt}
    ]).

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
