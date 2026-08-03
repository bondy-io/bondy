%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_cell_utils).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Shared per-cell batch-admin primitives, extracted from `bondy_oplog_applier`
so both the applier (a normal instance's separate per-cell fold process)
and a fused instance (which folds in-process, no separate applier) run
every batch cell-admin op — dead-origin reap, causally-stable cell
reclamation, secondary-index rebuild — identically, plus the generic
per-cell enumeration and safe-read helpers all three share.

One module, four sections (WALK / REAP / STABILIZE / REINDEX) rather than
four small modules: each section is a self-contained pass over a shard's
cells, but they all rest on the same "iterate the mux MEMBERS, not the
founding ctx alone" foundation (A6 — kernel fidelity, see WALK below), so
splitting them across files bought no isolation, just more places to look.

Every function here takes its inputs as explicit parameters (an adapter, a
handle, an instance id, a causal-context guard, ...), never a gen_server
`#state{}` — the caller's own state shape (the applier's or a fused
instance's) never leaks in.

## A6 — kernel fidelity (applies to REAP, STABILIZE, and REINDEX alike)

On a multiplexed per-shard instance the shard's cells span every
registered table, each with its own CRDT kernel, projection handle and
cell scope. Each pass therefore iterates the mux MEMBERS (`member_cells/4`
below): each table's cells are enumerated through ITS OWN ctx (scope +
handle) and decoded with ITS OWN kernel. Sweeping from a single founding
ctx alone would both miss every other table's cells and misdecode them
with the wrong kernel.
""").

-export([distinct_cell_keys/1]).
-export([member_cells/4]).
-export([mst_cell_directory/1]).
-export([primary_cell_directory/4]).
-export([with_cell_state/10]).
-export([reap/4]).
-export([sweep/5]).
-export([reindex/3]).

-export_type([reap_report/0]).

-doc "Result of a `reap/4` pass.".
-type reap_report() :: #{
    %% `false` when the shard's kernel is not a context-carrying tier_2
    %% CRDT (legacy fold / tier_0) — the whole pass was a no-op.
    supported := boolean(),
    cells_scanned := non_neg_integer(),
    cells_reaped := non_neg_integer(),
    origins_reaped := [term()]
}.

%% =============================================================================
%% WALK — generic per-shard cell enumeration and safe cell-state reads
%% =============================================================================

-doc """
The `{Bucket, Key}` cell keys a table member owns, sorted, optionally
resuming past a cursor. `MKey =:= all` matches every bucket in the
directory (a `{single, Ctx}` source); otherwise only cells whose bucket is
`MKey` (one bucket of a `{dir, #{Bucket => Ctx}}` multiplexed source).
""".
-spec member_cells(
    MCtx :: map(),
    MKey :: term(),
    CellCursor :: undefined | {term(), {term(), term()}},
    InstanceId :: term()
) -> [{term(), term()}].

member_cells(
    #{adapter := Adapter, handle := Handle} = MCtx, MKey, CellCursor, Id
) ->
    Scope = maps:get(primary_cell_scope, MCtx, undefined),
    All = lists:sort([
        BK
     || {B, _K} = BK <- primary_cell_directory(Adapter, Handle, Id, Scope),
        MKey =:= all orelse B =:= MKey
    ]),
    case CellCursor of
        undefined -> All;
        {MKey, LastCell} -> [BK || BK <- All, BK > LastCell]
    end.

-doc """
The primary cell directory for one member: the adapter's own key
enumeration when it exports `cell_keys/2` (and a scope is configured),
else the MST fallback (`mst_cell_directory/1`) — truncatable, so only
sound where cells are never compacted past what a peer re-ships.
""".
-spec primary_cell_directory(
    Adapter :: module(),
    Handle :: term(),
    InstanceId :: term(),
    Scope :: term() | undefined
) -> [{term(), term()}].

primary_cell_directory(Adapter, Handle, Id, Scope) when
    Scope =/= undefined
->
    case bondy_oplog_projection_adapter:cell_keys_exported(Adapter) of
        true -> Adapter:cell_keys(Handle, Scope);
        false -> mst_cell_directory(Id)
    end;
primary_cell_directory(_Adapter, _Handle, Id, undefined) ->
    mst_cell_directory(Id).

-doc """
The MST `cell_apply` cell directory — the fallback for an adapter that
cannot enumerate its keyspace (the ephemeral ETS adapter) or an instance
with no `cell_keys_scope()`. Truncatable (see `primary_cell_directory/4`),
so only sound where cells are never compacted past what a peer re-ships.
""".
-spec mst_cell_directory(InstanceId :: term()) -> [{term(), term()}].

mst_cell_directory(Id) ->
    case bondy_oplog_registry:mst(Id) of
        undefined -> [];
        MST -> distinct_cell_keys(MST)
    end.

-doc """
The distinct `{Bucket, Key}` cell keys named by the MST's `cell_apply`
events, de-duplicated. Fallback directory only (the MST is truncatable;
see `primary_cell_directory/4`).
""".
-spec distinct_cell_keys(MST :: bondy_mst:t()) -> [{term(), term()}].

distinct_cell_keys(MST) ->
    lists:usort([
        {Bucket, Key}
     || {_MstKey, {{cell_apply, Bucket, Key, _FE}, _Meta, _Prev, _Sig}} <-
            bondy_mst:to_list(MST)
    ]).

-doc """
Reads and decodes one cell's current projection frame, calling
`Fun(Hlc, State, ValueBytes)` with it — `NotFound` when the cell has no
projection value, `OnFail` (after a structured `?LOG_WARNING`) when the
read/decode/`Fun` raises. Total by construction: every batch cell-admin op
uses this so one malformed/unreadable cell degrades only itself, never
the whole pass.
""".
-spec with_cell_state(
    Adapter :: module(),
    Handle :: term(),
    Kernel :: term(),
    InstanceId :: term(),
    Bucket :: term(),
    Key :: term(),
    Desc :: iodata(),
    NotFound :: term(),
    OnFail :: term(),
    Fun :: fun(
        (
            Hlc :: term(), State :: term(), ValueBytes :: binary() | undefined
        ) -> term()
    )
) -> term().

with_cell_state(
    Adapter, Handle, Kernel, Id, Bucket, Key, Desc, NotFound, OnFail, Fun
) ->
    try
        case Adapter:get(Handle, Bucket, Key) of
            not_found ->
                NotFound;
            {ok, Frame} ->
                {Hlc, StateBytes, ValueBytes} =
                    bondy_oplog_cell_frame:decode_full(Frame),
                State = bondy_oplog_cell_kernel:decode_state(
                    Kernel, StateBytes
                ),
                Fun(Hlc, State, ValueBytes)
        end
    catch
        C:R:S ->
            ?LOG_WARNING(#{
                description => Desc,
                instance_id => Id,
                bucket => Bucket,
                cell_key => Key,
                class => C,
                reason => R,
                stacktrace => S
            }),
            OnFail
    end.

%% =============================================================================
%% REAP — dead-origin causal-context GC
%% =============================================================================

%% A tier_2 CRDT carries one version-vector entry per origin that ever
%% wrote a cell; a decommissioned node leaves those entries behind forever
%% — the one cost that grows with cluster *churn*, not with live data.
%% `reap/4` drops only the value-preserving (causal-history-only) entries
%% of the supplied retired origins, so the cell's *value* is unchanged.
%%
%% The caller owns the causal-context stamp-site guard
%% (`bondy_oplog_ctx_guard`): a reaped cell's context legitimately shrinks,
%% which `bondy_oplog_ctx_guard:stamp/5` would otherwise flag as a
%% regression, so `reap/4` returns the guard with every reaped cell
%% co-evicted (`bondy_oplog_ctx_guard:coevict/2`) — the caller stores the
%% returned guard back into its own state.
%%
%% A reap rewrites the projection checkpoint, not the MST, so it is undone
%% by a subsequent **live re-bootstrap** (which re-folds the full MST) and
%% skips **fully-compacted** cells — re-run it after a re-bootstrap. Both
%% are bounded-by-churn, not convergence bugs.

-doc """
Reaps `RetiredOrigins`'s value-preserving causal-context entries from
every cell of every table registered in `Source` (a
`bondy_oplog_cell_apply:ctx_source()` — the applier's `cell_apply_source`,
or a fused instance's `#fused_drain.cell_apply_source`, same shape).
Idempotent: a premature or repeated call just reaps fewer/no entries.

Returns `{{ok, Report}, Guard1}` or `{{error, Reason}, Guard}` (unchanged
on error — a partial pass never advances the guard past what it actually
wrote).
""".
-spec reap(
    InstanceId :: term(),
    Guard :: bondy_oplog_ctx_guard:guard(),
    Source :: bondy_oplog_cell_apply:ctx_source(),
    RetiredOrigins :: [term()]
) -> {{ok, reap_report()} | {error, term()}, bondy_oplog_ctx_guard:guard()}.

reap(InstanceId, Guard, Source, RetiredOrigins) ->
    Members = [
        E
     || {_, MCtx} = E <- lists:keysort(1, bondy_oplog_mux:entries(Source)),
        MCtx =/= undefined,
        kernel_reap_supported(maps:get(kernel, MCtx))
    ],
    case Members of
        [] ->
            {{ok, reap_report(false, 0, [])}, Guard};
        _ ->
            reap_members(Members, InstanceId, Guard, RetiredOrigins, 0, [], 0)
    end.

%% @private
reap_members([], _Id, Guard, _Retired, Scanned, Origins, CellsReaped) ->
    OriginsReaped = lists:usort(Origins),
    CellsReaped > 0 andalso
        telemetry:execute(
            [bondy_oplog, applier, origins_reaped],
            #{cells => CellsReaped, origins => length(OriginsReaped)},
            #{instance_id => _Id}
        ),
    Report = reap_report(true, Scanned, OriginsReaped),
    {{ok, Report#{cells_reaped => CellsReaped}}, Guard};
reap_members(
    [{MKey, MCtx} | Rest], Id, Guard, Retired, Scanned, Origins, CellsN
) ->
    #{adapter := Adapter, handle := Handle, kernel := Kernel} = MCtx,
    Cells = member_cells(MCtx, MKey, undefined, Id),
    Reaped = lists:foldl(
        fun(CellKey, Acc) ->
            case reap_one_cell(Adapter, Handle, Kernel, Id, CellKey, Retired) of
                skip -> Acc;
                {Frame, Ids} -> [{CellKey, Frame, Ids} | Acc]
            end
        end,
        [],
        Cells
    ),
    case finish_reap_member(Id, Guard, MCtx, Reaped) of
        {ok, Guard1, MemberOrigins} ->
            reap_members(
                Rest,
                Id,
                Guard1,
                Retired,
                Scanned + length(Cells),
                MemberOrigins ++ Origins,
                CellsN + length(Reaped)
            );
        {error, _} = E ->
            {E, Guard}
    end.

%% @private
kernel_reap_supported({crdt, Mod}) ->
    erlang:function_exported(Mod, reap_origins, 2).

%% @private
%% Read one cell's CURRENT projection frame, reap the retired origins from
%% its decoded state, and re-encode a value-preserving frame (same Hlc and
%% value column — only the state bytes shrink). `skip` when the cell has no
%% projection value, nothing was reaped, or the read/decode/reap raises
%% (`with_cell_state/10` owns the protection).
reap_one_cell(Adapter, Handle, Kernel, Id, {Bucket, Key}, Retired) ->
    with_cell_state(
        Adapter,
        Handle,
        Kernel,
        Id,
        Bucket,
        Key,
        "bondy_oplog_cell_utils dead-origin reap could not read a cell's "
        "projection value; it is skipped this pass.",
        skip,
        skip,
        fun(Hlc, State, ValueBytes) ->
            case bondy_oplog_cell_kernel:reap_origins(Kernel, State, Retired) of
                {NewState, [_ | _] = Ids} ->
                    StateBytes2 = bondy_oplog_cell_kernel:encode_state(
                        Kernel, NewState
                    ),
                    {value_preserving_frame(Hlc, StateBytes2, ValueBytes), Ids};
                _ ->
                    %% `{_NewState, []}` (no matching entry) or
                    %% `not_supported` (defensive — already gated above).
                    skip
            end
        end
    ).

%% @private
%% Re-encode a cell frame around new (smaller) state bytes, preserving the
%% Hlc and the value column exactly — the shape shared by the dead-origin
%% reap and the stabilization sweep's `{keep, Reduced}` rewrite, both of
%% which are value-preserving by contract. `undefined` value bytes ⇒ a
%% `value_equals_state` frame (no value column); otherwise the original
%% value column.
value_preserving_frame(Hlc, StateBytes, undefined) ->
    bondy_oplog_cell_frame:encode(Hlc, StateBytes, undefined, true);
value_preserving_frame(Hlc, StateBytes, ValueBytes) when is_binary(ValueBytes) ->
    bondy_oplog_cell_frame:encode(Hlc, StateBytes, ValueBytes, false).

%% @private
%% Persist one member's reaped frames through the MEMBER's own ctx (adapter,
%% handle, caches) and co-evict its reaped origins from the tier_2
%% stamp-site guard: the cell's context legitimately shrank, and
%% `bondy_oplog_ctx_guard:stamp/5` would otherwise flag the next write as a
%% regression. Returns the origins this member reaped.
finish_reap_member(_Id, Guard, _MCtx, []) ->
    {ok, Guard, []};
finish_reap_member(Id, Guard, MCtx, Reaped) ->
    #{adapter := Adapter, handle := Handle} = MCtx,
    CacheAdapter = maps:get(cache_adapter, MCtx, undefined),
    CacheHandle = maps:get(cache_handle, MCtx, undefined),
    OldStateCache = maps:get(oldstate_cache, MCtx, undefined),
    Entries = [{B, K, F} || {{B, K}, F, _Ids} <- Reaped],
    case Adapter:put_batch(Handle, Entries) of
        ok ->
            lists:foreach(
                fun({{B, K}, _F, _Ids}) ->
                    bondy_oplog_cell_apply:invalidate_cache(
                        CacheAdapter, CacheHandle, B, K
                    )
                end,
                Reaped
            ),
            %% A3 — write-through the rewritten frames into the OldValue
            %% cache (no-op when disabled), so a hit returns the reaped state.
            bondy_oplog_cell_apply:oldstate_cache_put_entries(
                OldStateCache, Entries
            ),
            Guard1 = bondy_oplog_ctx_guard:coevict(Guard, Reaped),
            OriginsReaped = lists:usort(
                lists:append([Ids || {_C, _F, Ids} <- Reaped])
            ),
            {ok, Guard1, OriginsReaped};
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_cell_utils dead-origin reap projection "
                    "write failed; this member's cells were not reaped "
                    "this pass.",
                instance_id => Id,
                count => length(Entries),
                reason => Reason
            }),
            {error, Reason}
    end.

%% @private
reap_report(Supported, Scanned, OriginsReaped) ->
    #{
        supported => Supported,
        cells_scanned => Scanned,
        cells_reaped => 0,
        origins_reaped => OriginsReaped
    }.

%% =============================================================================
%% STABILIZE — causally-stable CRDT cell reclamation sweep
%% =============================================================================

%% Reads each cell's CURRENT projection state — not the event history —
%% and asks the fold's `stabilize/2` callback what survives once every op
%% that could ever compare against it is causally stable (below
%% `StableHlc`): `keep`, `discard` (the cell is dead — e.g. a disabled
%% flag, an emptied group — and physically removed), or `{keep, Reduced}`
%% (causal-stabilization reduction, e.g. a struct field's per-origin
%% sub-op runs folded into synthetic ops — persisted as a
%% value-preserving frame rewrite, see `apply_stabilize/10`). Folds that
%% declare no `stabilize/2` are left untouched (`not_supported`).
%%
%% Overlay fence: a cell can only be *deleted* from the projection once
%% its overlay (the WAL-appended, not-yet-installed events pending
%% promotion into the MST) holds nothing at all for that key — reading an
%% ABSENT cell restarts overlay replay from HLC 0, so removing a cell
%% widens the replay window; a pending event older than the state just
%% judged stale would replay and resurrect a value. `Ctx`'s `shard_key`
%% resolves the shard's overlay table exactly as the applier's own
%% founding ctx does — the fence is instance-wide, not per-registered-table.
%%
%% Representation divergence: a `{keep, Reduced}` rewrite (like a reap)
%% makes the projection FRAME a local representation — two replicas that
%% reduce at different stability points hold different (semantically
%% equal) state bytes for the same cell. This is sound only while frames
%% never feed hash-compared state: AAE ships EVENTS (MST pages), the
%% convergence oracle is the applied-frontier VV, and catalogue bootstrap
%% replaces frames wholesale. Anything that ever starts hashing or
%% diffing projection frames across replicas must first re-derive them
%% canonically (e.g. re-fold from events).

-doc """
One bounded sweep pass over `Source`'s member tables' cells, judging
against `StableHlc`. `Opts`: `max_cells` (default `infinity`) bounds this
call's work, returning `{ok, Stats, {resume, Cursor}}` when the budget
runs out with cells still pending — pass `Cursor` back as `Opts#{cursor =>
Cursor}` on the next call to continue; `{ok, Stats, done}` once every
member's cells have been swept. `Stats` is
`#{scanned, discarded, rewritten, skipped}`.
""".
-spec sweep(
    InstanceId :: term(),
    Ctx :: map(),
    Source :: bondy_oplog_cell_apply:ctx_source(),
    StableHlc :: integer(),
    Opts :: map()
) -> {ok, map(), done | {resume, term()}}.

sweep(InstanceId, Ctx, Source, StableHlc, Opts) ->
    Limit = maps:get(max_cells, Opts, infinity),
    Cursor = maps:get(cursor, Opts, undefined),
    Overlay = overlay_tab(Ctx),
    %% Sorted so the {MemberKey, CellKey} cursor is deterministic across
    %% calls (`maps:to_list` order is not).
    Members = lists:keysort(
        1,
        [
            E
         || {_, MCtx} = E <- bondy_oplog_mux:entries(Source),
            MCtx =/= undefined
        ]
    ),
    {Acc, Next} = sweep_members(
        Members,
        Cursor,
        Limit,
        Overlay,
        InstanceId,
        StableHlc,
        #{
            scanned => 0,
            discarded => 0,
            rewritten => 0,
            skipped => 0
        },
        undefined
    ),
    telemetry:execute(
        [bondy_oplog, applier, cells_swept],
        maps:with(
            [scanned, discarded, rewritten, skipped], Acc
        ),
        #{instance_id => InstanceId, stable_hlc => StableHlc}
    ),
    {ok, Acc, Next}.

%% @private
%% Bounded pass over the sorted mux members. `Cursor` names where the
%% previous call stopped ({MemberKey, CellKey}): members strictly before it
%% are skipped WITHOUT enumerating their directories; the member it points
%% into resumes strictly after its cell; later members sweep from the start.
%% `Rem` is the remaining cell budget; `Last` the cursor of the last cell
%% swept this call (what a `{resume, _}` returns).
sweep_members([], _Cursor, _Rem, _Overlay, _Id, _StableHlc, Acc, _Last) ->
    {Acc, done};
sweep_members(Members, _Cursor, 0, _Overlay, _Id, _StableHlc, Acc, Last) when
    Members =/= []
->
    %% Budget exhausted with members still pending. `Last` is defined: the
    %% budget only decrements by sweeping a cell.
    {Acc, {resume, Last}};
sweep_members(
    [{MKey, MCtx} | Rest], Cursor, Rem, Overlay, Id, StableHlc, Acc0, Last
) ->
    case member_start(MKey, Cursor) of
        skip ->
            sweep_members(
                Rest, Cursor, Rem, Overlay, Id, StableHlc, Acc0, Last
            );
        {sweep, CellCursor} ->
            Cells = member_cells(MCtx, MKey, CellCursor, Id),
            case
                sweep_cells(
                    Cells, MCtx, MKey, Overlay, Id, StableHlc, Rem, Acc0, Last
                )
            of
                {complete, Acc, Rem1, Last1} ->
                    sweep_members(
                        Rest, Cursor, Rem1, Overlay, Id, StableHlc, Acc, Last1
                    );
                {stopped, Acc, Last1} ->
                    {Acc, {resume, Last1}}
            end
    end.

%% @private
%% Where this member stands relative to the resume cursor.
member_start(_MKey, undefined) ->
    {sweep, undefined};
member_start(MKey, {MKey, _CellKey} = Cursor) ->
    {sweep, Cursor};
member_start(MKey, {CursorMKey, _}) when MKey < CursorMKey ->
    skip;
member_start(_MKey, _Cursor) ->
    {sweep, undefined}.

%% @private
%% Sweep this member's cells until they run out (`complete`) or the budget
%% does with cells still pending (`stopped`).
sweep_cells([], _MCtx, _MKey, _Overlay, _Id, _StableHlc, Rem, Acc, Last) ->
    {complete, Acc, Rem, Last};
sweep_cells(
    [{Bucket, Key} = BK | RestCells],
    MCtx,
    MKey,
    Overlay,
    Id,
    StableHlc,
    Rem,
    Acc0,
    _Last
) ->
    Acc = sweep_one_cell(MCtx, Overlay, Id, Bucket, Key, StableHlc, Acc0),
    Rem1 = dec_budget(Rem),
    case Rem1 =:= 0 andalso RestCells =/= [] of
        true ->
            {stopped, Acc, {MKey, BK}};
        false ->
            sweep_cells(
                RestCells,
                MCtx,
                MKey,
                Overlay,
                Id,
                StableHlc,
                Rem1,
                Acc,
                {MKey, BK}
            )
    end.

%% @private
dec_budget(infinity) -> infinity;
dec_budget(N) when is_integer(N), N > 0 -> N - 1.

%% @private
%% One cell's stabilization verdict. A cell we cannot read is a cell we
%% must not reclaim — we have no evidence it is stale — so failure
%% skips-and-counts and a later pass retries.
sweep_one_cell(
    #{adapter := Adapter, handle := Handle, kernel := Kernel} = MCtx,
    Overlay,
    Id,
    Bucket,
    Key,
    StableHlc,
    Acc0
) ->
    Acc = bump(scanned, Acc0),
    with_cell_state(
        Adapter,
        Handle,
        Kernel,
        Id,
        Bucket,
        Key,
        "bondy_oplog_cell_utils cell sweep could not read a cell's "
        "projection value; it is left in place and retried on a later pass.",
        Acc,
        bump(skipped, Acc),
        fun(Hlc, State, ValueBytes) ->
            apply_stabilize(
                MCtx,
                Overlay,
                Id,
                Bucket,
                Key,
                StableHlc,
                Hlc,
                State,
                ValueBytes,
                Acc
            )
        end
    ).

%% @private
apply_stabilize(
    #{adapter := Adapter, handle := Handle, kernel := Kernel} = MCtx,
    Overlay,
    Id,
    Bucket,
    Key,
    StableHlc,
    Hlc,
    State,
    ValueBytes,
    Acc
) ->
    case bondy_oplog_cell_kernel:stabilize(Kernel, StableHlc, State) of
        keep ->
            Acc;
        discard ->
            %% OVERLAY FENCE — see the section note above.
            %% Only reclaim when the overlay holds nothing at all for the key.
            case overlay_clear(Overlay, Bucket, Key) of
                true ->
                    ok = Adapter:delete(Handle, Bucket, Key),
                    %% The point-read cache and the A3 OldValue cache both
                    %% mirror the projection; a reclaimed cell left in either
                    %% would serve the pre-reclaim value (visible for a fold
                    %% whose empty value is real data, e.g. a flag's `false`)
                    %% or feed the next apply a stale OldState.
                    bondy_oplog_cell_apply:invalidate_cache(
                        maps:get(cache_adapter, MCtx, undefined),
                        maps:get(cache_handle, MCtx, undefined),
                        Bucket,
                        Key
                    ),
                    bondy_oplog_cell_apply:oldstate_cache_delete(
                        maps:get(oldstate_cache, MCtx, undefined),
                        Bucket,
                        Key
                    ),
                    bump(discarded, Acc);
                false ->
                    %% Pending work for this cell: leave it and retry on a
                    %% later pass, once the applier has drained.
                    bump(skipped, Acc)
            end;
        {keep, Reduced} ->
            %% Causal-stabilization reduction (arXiv:1710.04469 §7.2.1): the
            %% cell's value survives; its state sheds representation that only
            %% served to order it against operations that can no longer
            %% arrive (e.g. a struct field's stable per-origin sub-op runs
            %% folded into synthetic ops). A value-preserving frame rewrite —
            %% same Hlc, same value column, smaller state bytes — exactly as
            %% the dead-origin reap performs, behind the SAME overlay fence
            %% as `discard`: a WAL-pended event for this cell may be one the
            %% reduction's license did not account for (its stamped context
            %% may select among the very dots being folded), so the cell is
            %% left for a later pass until the applier has drained it.
            %%
            %% Unlike the reap, no `bondy_oplog_ctx_guard` co-eviction: the
            %% `stabilize/2` contract forbids the reduction from shrinking
            %% the cell's causal context, so the stamp-site guard never sees
            %% a regression.
            case overlay_clear(Overlay, Bucket, Key) of
                true ->
                    write_reduced_cell(
                        MCtx, Id, Bucket, Key, Hlc, Reduced, ValueBytes, Acc
                    );
                false ->
                    bump(skipped, Acc)
            end;
        not_supported ->
            %% Fold declares no stabilization: nothing is reclaimable for it.
            %% MUST NOT be read as "reclaimable".
            Acc
    end.

%% @private
%% Persist one reduced cell frame, mirroring `finish_reap_member/4`'s
%% write path for a single cell: put, invalidate the point-read cache,
%% write-through the A3 OldValue cache so the next apply folds onto the
%% reduced state instead of resurrecting the unreduced one from cache. A
%% failed write leaves the cell as-is (`skipped`) — the unreduced state is
%% still correct, only larger — and a later pass retries.
write_reduced_cell(
    #{adapter := Adapter, handle := Handle, kernel := Kernel} = MCtx,
    Id,
    Bucket,
    Key,
    Hlc,
    Reduced,
    ValueBytes,
    Acc
) ->
    StateBytes = bondy_oplog_cell_kernel:encode_state(Kernel, Reduced),
    Frame = value_preserving_frame(Hlc, StateBytes, ValueBytes),
    case Adapter:put_batch(Handle, [{Bucket, Key, Frame}]) of
        ok ->
            bondy_oplog_cell_apply:invalidate_cache(
                maps:get(cache_adapter, MCtx, undefined),
                maps:get(cache_handle, MCtx, undefined),
                Bucket,
                Key
            ),
            bondy_oplog_cell_apply:oldstate_cache_put_entries(
                maps:get(oldstate_cache, MCtx, undefined),
                [{Bucket, Key, Frame}]
            ),
            bump(rewritten, Acc);
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "bondy_oplog_cell_utils stabilization sweep could not "
                    "persist a reduced cell frame; the cell is left "
                    "unreduced and retried on a later pass.",
                instance_id => Id,
                bucket => Bucket,
                cell_key => Key,
                reason => Reason
            }),
            bump(skipped, Acc)
    end.

%% @private
%% The shard's overlay table; `disabled` when the topology declares none;
%% `unavailable` when the shard IS registered but its registry entry cannot be
%% read right now — the fence must then FAIL CLOSED (skip the cell), because a
%% transient registry failure says nothing about what is pending in the
%% overlay (A5).
overlay_tab(Ctx) ->
    case maps:get(shard_key, Ctx, undefined) of
        undefined ->
            disabled;
        {NS, Index, Shard} ->
            case bondy_oplog_core_registry:lookup(NS, Index, Shard) of
                {ok, Entry} ->
                    bondy_oplog_core_registry:entry_overlay(Entry);
                _ ->
                    unavailable
            end
    end.

%% @private
%% `0` — not the cell's HLC — deliberately: the fence asks whether ANY event is
%% pending for this key, because after the delete the read path would replay
%% from 0.
overlay_clear(disabled, _Bucket, _Key) ->
    true;
overlay_clear(undefined, _Bucket, _Key) ->
    %% Registered shard that declares no overlay: nothing can be pending.
    true;
overlay_clear(unavailable, _Bucket, _Key) ->
    %% FAIL CLOSED: the overlay exists (or may exist) but cannot be consulted.
    false;
overlay_clear(Tab, Bucket, Key) ->
    bondy_oplog_db_overlay:events_for(Tab, Bucket, Key, 0) =:= [].

%% @private
bump(Key, Acc) ->
    maps:update_with(Key, fun(X) -> X + 1 end, Acc).

%% =============================================================================
%% REINDEX — full secondary-index rebuild
%% =============================================================================

%% Re-derives every live term of every primary cell from its CURRENT
%% projection value — not by replaying events — with the back-pressure cap
%% bypassed so the full working set lands in one pass even when a prior
%% saturation left the cap tripped. Reading the converged value (rather
%% than replaying) is correct for context-carrying (tier_2) CRDTs, where a
%% naive event replay would double-count or miss concurrent siblings;
%% combined with the rebuild orchestrator first clearing the stale index
%% shard, a `put` for every current term fully restores it.
%%
%% Scoped to the FOUNDING primary only (`Ctx`, not every table registered
%% on a multiplexed shard) — unlike REAP/STABILIZE above, which generalize
%% to every mux member — kept as-is here since index rebuild is already
%% dispatched per registered table (one `{register_table, ...}`/founding
%% ctx per rebuild target), not per-shard.

-doc """
Re-indexes every primary cell reachable from `Ctx` (an
`#{adapter, handle, kernel, ...}` cell-apply context — the applier's
founding `cell_apply_ctx`, or a fused instance's
`#fused_drain.cell_apply_ctx`) into `SecIdx` (a
`bondy_oplog_cell_apply:sec_idx()` — the primary's secondary-index
descriptors). A no-op when `SecIdx` names no indexes (callers should check
this themselves via `bondy_oplog_cell_apply:sec_idx/1` before calling, to
skip the cell-directory walk entirely when there is nothing to rebuild).
""".
-spec reindex(
    InstanceId :: term(),
    Ctx :: map(),
    SecIdx :: bondy_oplog_cell_apply:sec_idx()
) -> ok.

reindex(
    InstanceId,
    #{adapter := Adapter, handle := Handle, kernel := Kernel} = Ctx,
    SecIdx
) ->
    Scope = maps:get(primary_cell_scope, Ctx, undefined),
    CellKeys = primary_cell_directory(Adapter, Handle, InstanceId, Scope),
    {IdxAcc, MaxHlc} = lists:foldl(
        fun({Bucket, Key}, {IAcc, HAcc}) ->
            case
                reindex_one_cell(
                    Adapter, Handle, Kernel, SecIdx, InstanceId, Bucket, Key
                )
            of
                {ok, IdxOps, Hlc} ->
                    {
                        bondy_oplog_cell_apply:merge_idx_ops(IAcc, IdxOps),
                        bondy_oplog_cell_apply:max_hlc(HAcc, Hlc)
                    };
                skip ->
                    {IAcc, HAcc}
            end
        end,
        {#{}, undefined},
        CellKeys
    ),
    bondy_oplog_cell_apply:dispatch_index_ops(SecIdx, IdxAcc, MaxHlc, true),
    ok.

%% @private
%% Read one cell's CURRENT projection frame and term-project its value into
%% index `put` ops. Returns `skip` when the cell has no projection value
%% yet (a not-yet-replayed peer cell) or the read/decode/projection raises
%% (`with_cell_state/10` owns the protection).
reindex_one_cell(Adapter, Handle, Kernel, SecIdx, Id, Bucket, Key) ->
    with_cell_state(
        Adapter,
        Handle,
        Kernel,
        Id,
        Bucket,
        Key,
        "bondy_oplog_cell_utils index rebuild could not read a cell's "
        "projection value; its index terms are skipped this pass (the "
        "shard stays marked and a later trigger retries).",
        skip,
        skip,
        fun(Hlc, State, _ValueBytes) ->
            IdxOps = index_puts_for_cell(
                SecIdx, Id, Kernel, Bucket, Key, State, Hlc
            ),
            {ok, IdxOps, Hlc}
        end
    ).

%% @private
%% Puts-only term projection of one cell's CURRENT value across every
%% secondary index — the rebuild variant of the incremental apply path's
%% diff-based index ops. No old/new diff: the rebuild orchestrator wipes
%% the target shard first, so a `put` for every current term fully
%% restores it, and the idempotent re-puts that reach sibling indexes only
%% refresh them. Own try/catch so a malformed spec degrades only the
%% index, never the rebuild as a whole.
index_puts_for_cell({_NS, []}, _Id, _Kernel, _Bucket, _Key, _State, _Hlc) ->
    [];
index_puts_for_cell({_NS, SecIndexes}, Id, Kernel, Bucket, Key, State, Hlc) ->
    try
        Value = bondy_oplog_cell_kernel:to_value(Kernel, State),
        lists:flatmap(
            fun(Desc) ->
                index_puts_for_one(Desc, Bucket, Key, Value, Hlc)
            end,
            SecIndexes
        )
    catch
        C:R:S ->
            ?LOG_ERROR(#{
                description =>
                    "bondy_oplog_cell_utils rebuild index op computation "
                    "raised; the index is degraded for this cell "
                    "(rebuildable). The primary is unaffected.",
                instance_id => Id,
                bucket => Bucket,
                cell_key => Key,
                class => C,
                reason => R,
                stacktrace => S
            }),
            []
    end.

%% @private
index_puts_for_one(
    #{index_name := IName, spec := Spec, sec_shard_count := SCount} = Desc,
    Bucket,
    Key,
    Value,
    Hlc
) ->
    RealmFolded = maps:get(realm_folded, Desc, false),
    Terms = lists:usort(bondy_oplog_index_spec:terms(Spec, Value)),
    SecBucket = bondy_oplog_index_key:bucket(Bucket, IName),
    Cols = bondy_oplog_index_spec:project(Spec, Value),
    [
        bondy_oplog_cell_apply:index_op(
            IName, SecBucket, SCount, T, Key, {put, Cols, Hlc}, RealmFolded
        )
     || T <- Terms
    ].
