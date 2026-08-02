%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_catalogue_snapshot).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Peer-side responder for the catalogue-snapshot bootstrap protocol.

Two entry points:

- `init/1,2` — opens a session. Detects whether the instance has a
  catalogue projection at all. Returns `{ok, {Watermark, Cursor}}` on
  success, or `{ok, no_snapshot}` for legacy single-CRDT instances and
  for catalogue instances that have not yet wired a `cell_apply_target`.
- `next/2` — pulls the next chunk of `(Bucket, Key, Frame)` triples
  from the projection. Returns `{ok, {batch, {Cursor, Cells}}}` while
  there is more, `{ok, {done, []}}` on end-of-keyspace, or
  `{error, cursor_expired}` when the session's cursor was reaped.

The implementation is direct ETS / direct adapter — no instance
gen_server round-trip in the hot path so multiple bootstrap sessions
on the same peer run fully in parallel. Only the initial `init/1` call
hits the applier (to discover `cell_apply_target`).

## Single-shard, single-bucket assumption

This v1 services single-shard catalogues that store all cells in one
bucket. The default bucket is `<<>>` (matching the convention in
existing test instances). Multi-shard / multi-bucket catalogue
bootstrap is a follow-up.

## Snapshot consistency

The cursor captures the high-water HLC at session start. Cells
returned in subsequent batches MAY include writes past that HLC — the
range scan is live, not a frozen snapshot. The bootstrap install
contract does NOT depend on snapshot freezing: each cell is
applied via the fold's idempotent `apply_event/3`, and live events
arriving during the bootstrap window are guarded by the per-cell HLC
skip-if-older check on `pre_bootstrap`.
""").

-export([init/1]).
-export([init/2]).
-export([next/2]).

-ifdef(TEST).
-export([cap_cells/4]).
-endif.

%% Default bucket for catalogue projections. Matches the convention in
%% `bondy_oplog_applier_cell_apply_test` and the e2e test suites: cell
%% events are appended with `Bucket = <<>>`.
-define(DEFAULT_BUCKET, <<>>).

%% Max binary sentinel for unbounded-high range scans. 256 bytes of
%% 0xFF — beyond any production catalogue key.
-define(MAX_KEY_SENTINEL,
    <<255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255>>
).

%% Default batch size. Configurable via app env
%% `catalogue_snapshot_batch_size`.
-define(DEFAULT_BATCH_SIZE, 64).

%% =============================================================================
%% API
%% =============================================================================

-spec init(instance_id()) ->
    {ok, {non_neg_integer(), bondy_oplog_catalogue_cursor:cursor()}}
    | {ok, no_snapshot}.

?DOC("""
Opens a catalogue-snapshot session on the given instance, walking EVERY
table on the shard. A collapsed per-shard instance carries several tables,
each under its own entity-type bucket (and, on a memory topology, its own
projection handle); the session streams them all in one cursor, advancing
from one table to the next as each table's keyspace is exhausted
(`bondy_oplog_catalogue_cursor:next_target/1`). A single-table instance (no
per-table bucket on its registry entry) falls back to the legacy
single-bucket walk over the default bucket (`<<>>`). See `init/2` to snapshot
one explicit bucket.
""").
init(InstanceId) ->
    case bondy_oplog_instance:crdt_module(InstanceId) of
        Mod when is_atom(Mod), Mod =/= undefined ->
            {ok, no_snapshot};
        undefined ->
            init_catalogue_multi(InstanceId)
    end.

-spec init(instance_id(), Bucket :: binary()) ->
    {ok, {non_neg_integer(), bondy_oplog_catalogue_cursor:cursor()}}
    | {ok, no_snapshot}.

init(InstanceId, Bucket) when
    is_binary(InstanceId), is_binary(Bucket)
->
    %% Step 1 — detect catalogue mode. Single-CRDT mode has a defined
    %% `crdt_module`; catalogue mode does not.
    case bondy_oplog_instance:crdt_module(InstanceId) of
        Mod when is_atom(Mod), Mod =/= undefined ->
            {ok, no_snapshot};
        undefined ->
            init_catalogue(InstanceId, Bucket)
    end.

-spec next(
    instance_id(),
    bondy_oplog_catalogue_cursor:cursor()
) ->
    {ok,
        {batch,
            {bondy_oplog_catalogue_cursor:cursor(), [
                bondy_oplog_transport:cell()
            ]}}}
    | {ok, {done, []}}
    | {error, cursor_expired}
    | {error, term()}.

?DOC("""
Pulls the next batch from the given cursor. The cursor is opaque to
the initiator and is returned unchanged on `batch` so the caller can
chain calls without state.
""").
next(InstanceId, Cursor) when
    is_binary(InstanceId), is_binary(Cursor)
->
    case bondy_oplog_catalogue_cursor:lookup(Cursor) of
        not_found ->
            %% A cursor unknown to the peer means the session was
            %% started on a different peer, or the peer was restarted —
            %% either way the initiator must retry from `init/1`. We
            %% report this as `expired` for protocol simplicity (the
            %% initiator's recovery path is the same).
            {error, cursor_expired};
        expired ->
            {error, cursor_expired};
        {ok, #{instance_id := SessionId} = _CState} when
            SessionId =/= InstanceId
        ->
            %% Cursor belongs to a different instance. Treat as expired
            %% so the initiator restarts cleanly on the correct
            %% instance.
            {error, cursor_expired};
        {ok, CState} ->
            do_next(Cursor, CState)
    end.

%% =============================================================================
%% PRIVATE — init flow
%% =============================================================================

%% @private
init_catalogue(InstanceId, Bucket) ->
    case resolve_cell_apply_target(InstanceId) of
        undefined ->
            %% Not running, or a catalogue instance with no projection
            %% wiring — nothing to snapshot.
            {ok, no_snapshot};
        {ok, {NS, Index, Shard}} ->
            init_with_target(InstanceId, NS, Index, Shard, Bucket)
    end.

%% @private
%% Multi-target init: snapshot every table on the shard. The target set is
%% derived from the registry (every primary entry sharing the instance's id,
%% each tagged with its `cell_apply_bucket`), so a collapsed per-shard instance
%% streams all of its tables; a single-table instance with no per-table bucket
%% falls back to the legacy single-bucket walk.
init_catalogue_multi(InstanceId) ->
    case resolve_cell_apply_target(InstanceId) of
        undefined ->
            {ok, no_snapshot};
        {ok, {NS, Index, Shard}} ->
            Targets = build_targets(InstanceId, NS),
            init_with_targets(InstanceId, NS, Index, Shard, Targets)
    end.

%% @private
%% The instance's founding projection target, resolved through whichever
%% process owns it: the applier for a non-fused instance, the fused
%% instance's own gen_server otherwise (`bondy_oplog_instance:
%% cell_apply_target/1` — a fused instance has no applier pid, which
%% previously made every fused instance answer `no_snapshot` and left
%% retention-bounded registry shards with no bootstrap producer at all).
resolve_cell_apply_target(InstanceId) ->
    case bondy_oplog_registry:applier_pid(InstanceId) of
        undefined ->
            case
                bondy_oplog_registry:fused(InstanceId) andalso
                    bondy_oplog_instance:whereis(InstanceId)
            of
                Pid when is_pid(Pid) ->
                    case bondy_oplog_instance:cell_apply_target(Pid) of
                        {ok, {_, _, _}} = Ok -> Ok;
                        _ -> undefined
                    end;
                _ ->
                    undefined
            end;
        ApplierPid ->
            case bondy_oplog_applier:cell_apply_target(ApplierPid) of
                {ok, {_, _, _}} = Ok -> Ok;
                _ -> undefined
            end
    end.

%% @private
%% Every `(NS, Bucket)` target on the shard: one per primary table that carries
%% a `cell_apply_bucket` (a collapsed per-shard instance). When none do — a
%% single-table or raw registration — fall back to the founding namespace and
%% the default bucket, which is exactly the legacy single-target walk.
build_targets(InstanceId, FoundingNS) ->
    Entries = bondy_oplog_core_registry:primary_entries_for_instance(
        InstanceId
    ),
    Tagged = lists:filtermap(
        fun(E) ->
            case bondy_oplog_core_registry:entry_cell_apply_bucket(E) of
                undefined ->
                    false;
                Bucket ->
                    {NS, _Index, _Shard} =
                        bondy_oplog_core_registry:entry_key(E),
                    {true, {NS, Bucket}}
            end
        end,
        Entries
    ),
    case Tagged of
        [] -> [{FoundingNS, default_bucket()}];
        _ -> lists:usort(Tagged)
    end.

%% @private
%% The watermark is read from the founding namespace (it only seeds that
%% table's freshness mark on finalize; each table's own high-water is advanced
%% cell-by-cell as the install materialises its cells). The first target is the
%% current scan position; the rest ride on the cursor for `next_target/1`.
init_with_targets(InstanceId, FoundingNS, Index, Shard, Targets) ->
    [{NS1, Bucket1} | Rest] = Targets,
    case bondy_oplog_core_registry:high_water_hlc(FoundingNS, Index, Shard) of
        not_found ->
            {ok, no_snapshot};
        {ok, no_watermark} ->
            Cursor = bondy_oplog_catalogue_cursor:mint(
                InstanceId, NS1, Index, Shard, Bucket1, 0, Rest
            ),
            {ok, {0, Cursor}};
        {ok, Watermark} when is_integer(Watermark) ->
            Cursor = bondy_oplog_catalogue_cursor:mint(
                InstanceId, NS1, Index, Shard, Bucket1, Watermark, Rest
            ),
            {ok, {Watermark, Cursor}}
    end.

%% @private
init_with_target(InstanceId, NS, Index, Shard, Bucket) ->
    case bondy_oplog_core_registry:high_water_hlc(NS, Index, Shard) of
        not_found ->
            %% Shard was unregistered between the applier opening it
            %% and us reading the watermark. Bail out as no_snapshot —
            %% the initiator can retry.
            {ok, no_snapshot};
        {ok, no_watermark} ->
            %% Fresh shard, no cells applied yet. A snapshot would be
            %% empty; we still mint a cursor so the initiator's pull
            %% loop terminates cleanly via `{ok, {done, []}}`.
            Cursor = bondy_oplog_catalogue_cursor:mint(
                InstanceId, NS, Index, Shard, Bucket, 0
            ),
            {ok, {0, Cursor}};
        {ok, Watermark} when is_integer(Watermark) ->
            Cursor = bondy_oplog_catalogue_cursor:mint(
                InstanceId, NS, Index, Shard, Bucket, Watermark
            ),
            {ok, {Watermark, Cursor}}
    end.

%% =============================================================================
%% PRIVATE — next flow
%% =============================================================================

%% @private
do_next(Cursor, CState) ->
    #{
        instance_id := InstanceId,
        ns := NS,
        index := Index,
        shard := Shard,
        bucket := Bucket,
        last_key := LastKey
    } = CState,
    case bondy_oplog_core_registry:lookup(NS, Index, Shard) of
        not_found ->
            %% Shard vanished mid-session — initiator must restart.
            ok = bondy_oplog_catalogue_cursor:discard(Cursor),
            {error, cursor_expired};
        {ok, Entry} ->
            Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
            Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
            Low = next_key_after(LastKey),
            High = ?MAX_KEY_SENTINEL,
            BatchSize = batch_size(),
            case
                Adapter:range(Handle, Bucket, Low, High, #{limit => BatchSize})
            of
                {ok, []} ->
                    %% Current target's keyspace exhausted. Advance to the next
                    %% table on the shard, if any, and scan it; only when no
                    %% targets remain is the whole shard done.
                    case bondy_oplog_catalogue_cursor:next_target(Cursor) of
                        done ->
                            ok = bondy_oplog_catalogue_cursor:discard(Cursor),
                            {ok, {done, []}};
                        not_found ->
                            {error, cursor_expired};
                        {ok, NextState} ->
                            do_next(Cursor, NextState)
                    end;
                {ok, Pairs} ->
                    MaxBytes = bondy_oplog_config:sync_max_response_bytes(),
                    {Cells, AdvanceKey} = cap_cells(
                        InstanceId, Bucket, Pairs, MaxBytes
                    ),
                    %% AdvanceKey is the last key decided this round (kept, or
                    %% skipped because it was oversized). The cursor advances to
                    %% it so the next round resumes strictly after it: a
                    %% byte-capped round leaves the untouched tail for the next
                    %% call, and an all-oversized round yields an empty-but-
                    %% advanced batch the initiator loops past. `Pairs` is
                    %% non-empty here, so AdvanceKey is always defined.
                    case
                        bondy_oplog_catalogue_cursor:advance(Cursor, AdvanceKey)
                    of
                        ok ->
                            {ok, {batch, {Cursor, Cells}}};
                        not_found ->
                            %% Cursor was reaped concurrently — rare but
                            %% possible if the session sat idle past the
                            %% TTL right at the moment the GC ran.
                            {error, cursor_expired}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% @private
%% Pack cells into a batch no larger than the sync byte ceiling (derived from
%% Partisan's frame cap), mirroring the responder's page capping so bootstrap
%% snapshots never exceed the transport frame. Returns the kept cells (in key
%% order) and the key to advance the cursor to — the last key decided, so the
%% untouched tail is re-scanned next round and never lost. A single cell whose
%% serialized size alone exceeds the ceiling cannot be framed to a peer; it is
%% reported and skipped (advanced past), so it never trips the frame cap — it
%% simply cannot replicate until `cluster.max_message_size` is raised above it.
cap_cells(InstanceId, Bucket, Pairs, MaxBytes) ->
    cap_cells(InstanceId, Bucket, Pairs, MaxBytes, 0, [], undefined).

%% @private
cap_cells(_InstanceId, _Bucket, [], _MaxBytes, _Used, KeptRev, Advance) ->
    {lists:reverse(KeptRev), Advance};
cap_cells(
    InstanceId, Bucket, [{K, F} | Rest], MaxBytes, Used, KeptRev, Advance
) ->
    Cell = {Bucket, K, F},
    Size = erlang:external_size(Cell),
    if
        Size > MaxBytes ->
            ok = bondy_oplog_sync_metrics:report_oversized(
                cell, {InstanceId, Bucket, K}, Size, MaxBytes
            ),
            cap_cells(InstanceId, Bucket, Rest, MaxBytes, Used, KeptRev, K);
        KeptRev =:= [] orelse Used + Size =< MaxBytes ->
            cap_cells(
                InstanceId,
                Bucket,
                Rest,
                MaxBytes,
                Used + Size,
                [Cell | KeptRev],
                K
            );
        true ->
            %% Ceiling reached; leave {K, F} and the rest for the next round.
            {lists:reverse(KeptRev), Advance}
    end.

%% @private
%% Lexicographic successor for binary keys: `<<K/binary, 0>>` is the
%% smallest binary strictly greater than `K`. Initial `undefined` maps
%% to `<<>>` (the smallest possible Low).
next_key_after(undefined) -> <<>>;
next_key_after(K) when is_binary(K) -> <<K/binary, 0>>.

%% @private
default_bucket() ->
    application:get_env(
        bondy_oplog, catalogue_default_bucket, ?DEFAULT_BUCKET
    ).

%% @private
batch_size() ->
    application:get_env(
        bondy_oplog, catalogue_snapshot_batch_size, ?DEFAULT_BATCH_SIZE
    ).
