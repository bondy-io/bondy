%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Catalogue (projection-backed) compaction truncates the MST's stable prefix:
%% the materialised state lives in the durable projection, so the compaction
%% checkpoint records only the watermark. Truncation must not outrun the async
%% projection: a peer-merged event can be in the MST, and so in the stability
%% frontier, before the applier folds it. Truncation is therefore capped at the
%% projection's applied high-water. With a projection that has folded every
%% event (await_apply → high-water covers the frontier), compaction truncates
%% the MST to empty and reads stay correct (the projection is the durable read
%% source, untouched by truncation).

-module(bondy_oplog_catalogue_compaction_test).

-include_lib("eunit/include/eunit.hrl").

%% Default cell bucket — substrate `read/3` aliases land on `<<>>`.
-define(B, <<>>).
-define(CRDT, bondy_oplog_crdt_lww_register).
-define(HELD, <<"held">>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Deterministic: no background sync dispatch, no auto-compaction.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

catalogue_compaction_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun truncates_and_preserves_reads/0},
        {timeout, 30, fun idempotent_after_truncation/0},
        {timeout, 30, fun crdt_kernel_compaction_matches_from_scratch/0},
        {timeout, 30, fun remote_event_survives_catalogue_compaction/0},
        {timeout, 30, fun compaction_makes_no_synchronous_applier_call/0},
        {timeout, 30, fun held_event_folds_after_compaction/0},
        {timeout, 30, fun held_event_folds_after_compaction_fused/0},
        {timeout, 60, fun owed_refold_survives_compaction_before_gate/0}
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

%% A catalogue with a projection that has folded every event: a peer
%% converged to exactly our tree makes the stability frontier the whole
%% tree, capped at the applied high-water (which covers every applied
%% cell), so compaction truncates the MST to empty. Reads are unchanged
%% — including a key first read *after* truncation, which can only come
%% from the projection — and new writes still work post-compaction.
truncates_and_preserves_reads() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    {ok, _} = open_instance(InstId, NS, bondy_oplog_origin:new()),
    try
        ok = append_cell(InstId, <<"a">>, 10, <<"v-a">>),
        ok = append_cell(InstId, <<"b">>, 20, <<"v-b">>),
        ok = append_cell(InstId, <<"c">>, 30, <<"v-c">>),
        %% Drain into the projection so the applier advances the
        %% per-shard high-water (the safe-truncation cap).
        _ = bondy_oplog_instance:await_apply(InstId),
        %% Read two keys pre-compaction (these warm the read cache).
        %% `<<"b">>` is deliberately left unread until after truncation.
        ?assertEqual(
            {<<"v-a">>, 10}, bondy_oplog_core:read(NS, primary, <<"a">>)
        ),
        ?assertEqual(
            {<<"v-c">>, 30}, bondy_oplog_core:read(NS, primary, <<"c">>)
        ),
        ?assert(bondy_oplog:size(InstId) >= 3),

        Witness = bondy_oplog_registry:frontier(InstId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(InstId, [Witness])
        ),
        ?assertEqual(0, bondy_oplog:size(InstId)),
        ?assertNotEqual(undefined, bondy_oplog:current_watermark(InstId)),

        %% Reads survive truncation. `<<"b">>` was never read, so it is
        %% not cached: a correct value here proves the projection (not
        %% the cache) served it AND that truncation left it intact.
        ?assertEqual(
            {<<"v-b">>, 20}, bondy_oplog_core:read(NS, primary, <<"b">>)
        ),
        ?assertEqual(
            {<<"v-a">>, 10}, bondy_oplog_core:read(NS, primary, <<"a">>)
        ),
        ?assertEqual(
            {<<"v-c">>, 30}, bondy_oplog_core:read(NS, primary, <<"c">>)
        ),

        ok = append_cell(InstId, <<"d">>, 40, <<"v-d">>),
        _ = bondy_oplog_instance:await_apply(InstId),
        ?assertEqual(
            {<<"v-d">>, 40}, bondy_oplog_core:read(NS, primary, <<"d">>)
        )
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% A second compaction with no new stable events advances nothing.
idempotent_after_truncation() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    {ok, _} = open_instance(InstId, NS, bondy_oplog_origin:new()),
    try
        ok = append_cell(InstId, <<"k">>, 5, <<"v">>),
        _ = bondy_oplog_instance:await_apply(InstId),
        Witness = bondy_oplog_registry:frontier(InstId),
        {ok, {compacted, W1, _}} =
            bondy_oplog_instance:compact(InstId, [Witness]),
        ?assertEqual(0, bondy_oplog:size(InstId)),
        ?assertEqual(
            {ok, no_change},
            bondy_oplog_instance:compact(InstId, [Witness])
        ),
        ?assertEqual(W1, bondy_oplog:current_watermark(InstId))
    after
        ok = bondy_oplog:stop_instance(InstId),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

%% The catalogue's per-cell `interpret_cog` checkpoint IS the durable
%% projection, maintained by the applier's CRDT kernel. This pins the
%% invariant — **post-compaction read == from-scratch `interpret_cog`** —
%% on the NATIVE `crdt_module` path (the tests above exercise only the
%% fold kernel).
%%
%% Two instances apply the SAME event set (LWW overwrites in non-HLC
%% order, plus a clear). Instance A compacts (stable prefix truncated from
%% the MST); instance B never compacts. Every cell must read identically
%% on both — and equal to the hand-computed `interpret_cog` winner —
%% proving truncation does not change any cell's value when the projection
%% is the checkpoint.
crdt_kernel_compaction_matches_from_scratch() ->
    Events = [
        {<<"x">>, {set, 10, <<"x1">>}},
        {<<"x">>, {set, 30, <<"x3">>}},
        {<<"x">>, {set, 20, <<"x2">>}},
        {<<"y">>, {set, 15, <<"y1">>}},
        {<<"y">>, {set, 5, <<"y0">>}},
        {<<"z">>, {set, 25, <<"z1">>}},
        {<<"z">>, {clear, 40}}
    ],
    %% From-scratch `interpret_cog` (LWW): highest HLC wins per cell;
    %% `z` is cleared by the HLC-40 clear above the HLC-25 set.
    Expected = [
        {<<"x">>, {<<"x3">>, 30}},
        {<<"y">>, {<<"y1">>, 15}},
        {<<"z">>, undefined}
    ],

    AId = mk_id(),
    ANS = ns_of(AId),
    {AC, AP} = register_shard_crdt(ANS, primary, 0, lww_register, ?CRDT),
    {ok, _} = open_instance(AId, ANS, bondy_oplog_origin:new()),
    BId = mk_id(),
    BNS = ns_of(BId),
    {BC, BP} = register_shard_crdt(BNS, primary, 0, lww_register, ?CRDT),
    {ok, _} = open_instance(BId, BNS, bondy_oplog_origin:new()),
    try
        [append_op(AId, K, Op) || {K, Op} <- Events],
        [append_op(BId, K, Op) || {K, Op} <- Events],
        _ = bondy_oplog_instance:await_apply(AId),
        _ = bondy_oplog_instance:await_apply(BId),

        %% A: a peer converged to exactly our tree ⇒ frontier = whole
        %% tree; the stable prefix is truncated. Do NOT read A before
        %% compacting, so post-truncation reads can only come from the
        %% projection (the checkpoint), not a warm cache.
        Witness = bondy_oplog_registry:frontier(AId),
        ?assertMatch(
            {ok, {compacted, _, _}},
            bondy_oplog_instance:compact(AId, [Witness])
        ),
        ?assertEqual(0, bondy_oplog:size(AId)),
        ?assertNotEqual(undefined, bondy_oplog:current_watermark(AId)),

        lists:foreach(
            fun({K, Want}) ->
                ARead = bondy_oplog_core:read(ANS, primary, K),
                BRead = bondy_oplog_core:read(BNS, primary, K),
                ?assertEqual(Want, ARead),
                ?assertEqual(ARead, BRead)
            end,
            Expected
        )
    after
        ok = bondy_oplog:stop_instance(AId),
        ok = bondy_oplog:stop_instance(BId),
        ok = bondy_oplog_core_registry:unregister(ANS, primary, 0),
        ok = bondy_oplog_core_registry:unregister(BNS, primary, 0),
        close_shard(AC, AP),
        close_shard(BC, BP)
    end.

%% A genuinely-REMOTE event (authored on B, pulled into A via sync, so it
%% carries B's origin) must survive A's catalogue compaction. Compaction
%% folds nothing itself: a remote event the applier's replay has not
%% folded yet is never-applied by the applied VV and the truncation point
%% is capped below it (`capped_truncation_point/2`) — the tick replies
%% `{ok, no_change}` — and once the replay has folded it the next tick
%% truncates. Compacting immediately after the pull (no settle) makes the
%% first outcome possible; the loop below tolerates either and pins the
%% invariant: the tree empties and the remote value is in A's projection.
remote_event_survives_catalogue_compaction() ->
    AId = mk_id(),
    ANS = ns_of(AId),
    BId = mk_id(),
    BNS = ns_of(BId),
    {AC, AP} = register_shard(ANS, primary, 0, lww_register),
    {BC, BP} = register_shard(BNS, primary, 0, lww_register),
    {ok, _} = open_instance(AId, ANS, bondy_oplog_origin:new()),
    {ok, _} = open_instance(BId, BNS, bondy_oplog_origin:new()),
    try
        append_cell(AId, <<"l">>, 60, <<"lval">>),
        _ = bondy_oplog_instance:await_apply(AId),
        append_cell(BId, <<"r">>, 50, <<"rval">>),
        _ = bondy_oplog_instance:await_apply(BId),
        {ok, _} = bondy_oplog:sync(AId, BId),
        ok = compact_until_empty(AId, 200),

        ?assertEqual(
            {<<"rval">>, 50}, bondy_oplog_core:read(ANS, primary, <<"r">>)
        ),
        ?assertEqual(
            {<<"lval">>, 60}, bondy_oplog_core:read(ANS, primary, <<"l">>)
        )
    after
        ok = bondy_oplog:stop_instance(AId),
        ok = bondy_oplog:stop_instance(BId),
        ok = bondy_oplog_core_registry:unregister(ANS, primary, 0),
        ok = bondy_oplog_core_registry:unregister(BNS, primary, 0),
        close_shard(AC, AP),
        close_shard(BC, BP)
    end.

%% Falsifies the cross-node compaction↔commit deadlock. With a remote event
%% just delivered, the compaction handler must make ZERO synchronous calls
%% to the applier — the applier's own synchronous `drain_install_queue`
%% call (`commit_now/1`) deadlocks against any such call the moment a
%% compaction overlaps a commit boundary. Every call from the instance
%% process into `bondy_oplog_applier` during `compact/2` is traced; the
%% only one allowed is the `advance_replayed_root/2` cast that re-anchors
%% the replay cursor after a truncate. (The remote event `r` sits in the
%% whole-tree truncation range, so the compaction has a remote event to be
%% tempted by whether or not the replay has folded it.)
compaction_makes_no_synchronous_applier_call() ->
    AId = mk_id(),
    ANS = ns_of(AId),
    BId = mk_id(),
    BNS = ns_of(BId),
    {AC, AP} = register_shard(ANS, primary, 0, lww_register),
    {BC, BP} = register_shard(BNS, primary, 0, lww_register),
    {ok, _} = open_instance(AId, ANS, bondy_oplog_origin:new()),
    {ok, _} = open_instance(BId, BNS, bondy_oplog_origin:new()),
    Pattern = {bondy_oplog_applier, '_', '_'},
    try
        append_cell(AId, <<"l">>, 60, <<"lval">>),
        _ = bondy_oplog_instance:await_apply(AId),
        append_cell(BId, <<"r">>, 50, <<"rval">>),
        _ = bondy_oplog_instance:await_apply(BId),
        {ok, _} = bondy_oplog:sync(AId, BId),

        InstancePid = bondy_oplog_instance:whereis(AId),
        _ = erlang:trace_pattern(Pattern, true, [global]),
        _ = erlang:trace(InstancePid, true, [call]),
        try
            ok = compact_until_empty(AId, 200)
        after
            _ = erlang:trace(InstancePid, false, [call]),
            _ = erlang:trace_pattern(Pattern, false, [global])
        end,
        Called = lists:usort(collect_applier_calls([])),
        ?assertEqual([{advance_replayed_root, 2}], Called),
        ?assertEqual(
            {<<"rval">>, 50}, bondy_oplog_core:read(ANS, primary, <<"r">>)
        )
    after
        ok = bondy_oplog:stop_instance(AId),
        ok = bondy_oplog:stop_instance(BId),
        ok = bondy_oplog_core_registry:unregister(ANS, primary, 0),
        ok = bondy_oplog_core_registry:unregister(BNS, primary, 0),
        close_shard(AC, AP),
        close_shard(BC, BP)
    end.

%% A remote event held behind its origin's gap sits above the local prefix a
%% compaction truncates; the gap then fills. The held event must fold with it
%% (`proofs/tla/ReplayReanchor_Shipped_NoRestart.cfg` is this schedule).
held_event_folds_after_compaction() ->
    held_event_folds_after_compaction(#{}).

held_event_folds_after_compaction_fused() ->
    held_event_folds_after_compaction(#{
        fused => true, wal_backend => mem, durability => ephemeral, seed => true
    }).

held_event_folds_after_compaction(Opts) ->
    with_held_event(Opts, fun(Id, NS, Src) ->
        {ok, {compacted, _, 1}} = compact_own_root(Id),
        ok = bondy_oplog_test_helpers:settle(Id),
        ok = deliver_and_fold(Id, Src, 1),
        ?assertEqual(2, remote_seq(Id, Src)),
        ?assertEqual({<<"v2">>, 2}, bondy_oplog_core:read(NS, primary, ?HELD))
    end).

%% A drain-gated applier restarts while an event is held, so its boot anchor
%% is undefined and the re-fold it owes waits for the gate. A compaction lands
%% first; the re-fold must still present the held event
%% (`proofs/tla/ReplayReanchor_Shipped_Gated.cfg`).
owed_refold_survives_compaction_before_gate() ->
    with_dir(fun(Dir) ->
        Opts = #{
            backend => bondy_mst_pack_store,
            storage_path => unicode:characters_to_binary(Dir),
            seed => true,
            applier => #{drain_gated => true, commit_every => 1}
        },
        with_held_event(Opts, fun(Id, NS, Src) ->
            _ = bondy_oplog:append(
                Id, {cell_apply, ?B, <<"m">>, {set, 1, <<"m">>}}
            ),
            ok = bondy_oplog_test_projection:drain(Id),
            Inst = bondy_oplog_instance:whereis(Id),
            Wal = bondy_oplog_registry:wal_pid(Id),
            true = exit(Inst, kill),
            ok = bondy_oplog_test_helpers:await_subtree_restart(
                Id, Inst, Wal, 10_000
            ),
            ?assertEqual(4, bondy_oplog:size(Id)),
            {ok, {compacted, _, 1}} = compact_own_root(Id),
            ok = bondy_oplog_test_helpers:open_gate(Id),
            ok = bondy_oplog_test_helpers:settle(Id),
            ok = deliver_and_fold(Id, Src, 1),
            ?assertEqual(2, remote_seq(Id, Src)),
            ?assertEqual(
                {<<"v2">>, 2}, bondy_oplog_core:read(NS, primary, ?HELD)
            )
        end)
    end).

%% Drains the call-trace messages for `bondy_oplog_applier`, returning the
%% `{Function, Arity}` of every call the traced process made.
collect_applier_calls(Acc) ->
    receive
        {trace, _, call, {bondy_oplog_applier, F, Args}} ->
            collect_applier_calls([{F, length(Args)} | Acc])
    after 100 ->
        Acc
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

%% Compacts against the instance's own root until the tree is empty, or
%% `Retries` 10ms ticks elapse. A tick that finds a delivered-but-not-yet-
%% folded remote event replies `{ok, no_change}` (the compaction cap); the
%% applier's replay folds it a beat later and the next tick truncates.
compact_until_empty(_InstId, 0) ->
    {error, timeout};
compact_until_empty(InstId, Retries) ->
    Witness = bondy_oplog_registry:frontier(InstId),
    _ = bondy_oplog_instance:compact(InstId, [Witness]),
    case bondy_oplog:size(InstId) of
        0 ->
            ok;
        _ ->
            timer:sleep(10),
            compact_until_empty(InstId, Retries - 1)
    end.

%% Runs `Fun(Id, NS, Src)` on an instance holding, in key order: a local
%% write `l`; seq 2 of the remote origin `Src`, held behind its missing seq 1;
%% and seq 1 of another remote origin, which folded first and so anchored the
%% replay cursor.
with_held_event(Opts, Fun) ->
    Id = mk_id(),
    NS = ns_of(Id),
    {Cache, Proj} = register_shard(NS, primary, 0, lww_register),
    Applier = maps:get(applier, Opts, #{}),
    {ok, _} = bondy_oplog:start_instance(Id, Opts#{
        origin => bondy_oplog_origin:new(),
        applier => Applier#{cell_apply_target => {NS, primary, 0}}
    }),
    Src = {bondy_oplog_origin:new(), os:system_time(millisecond) + 60_000},
    try
        ok = bondy_oplog_test_helpers:open_gate(Id),
        _ = bondy_oplog:append(
            Id, {cell_apply, ?B, <<"l">>, {set, 10, <<"l">>}}
        ),
        ok = bondy_oplog_test_helpers:settle(Id),
        {_, Base} = Src,
        Anchor = {bondy_oplog_origin:new(), Base + 10},
        ok = deliver_and_fold(Id, Anchor, 1),
        ?assertEqual(1, remote_seq(Id, Anchor)),
        ok = deliver_and_fold(Id, Src, 2),
        ?assertEqual(0, remote_seq(Id, Src)),
        ?assertEqual(3, bondy_oplog:size(Id)),
        Fun(Id, NS, Src)
    after
        ok = bondy_oplog:stop_instance(Id),
        ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
        close_shard(Cache, Proj)
    end.

held_event({Origin, Base}, Seq) ->
    bondy_oplog_event:new(
        bondy_oplog_event:key(
            bondy_connect_hlc:encode(Base + Seq, 0), Origin, Seq
        ),
        {cell_apply, ?B, ?HELD,
            {set, Seq, <<"v", (integer_to_binary(Seq))/binary>>}},
        undefined
    ).

deliver_and_fold(Id, Src, Seq) ->
    ok = bondy_oplog:append_remote(Id, held_event(Src, Seq)),
    bondy_oplog_test_helpers:settle(Id).

remote_seq(Id, {Origin, _Base}) ->
    maps:get(Origin, bondy_oplog_instance:frontier(Id), 0).

compact_own_root(Id) ->
    bondy_oplog_instance:compact(Id, [bondy_oplog_registry:frontier(Id)]).

with_dir(Fun) ->
    Dir = filename:join(["/tmp", os:getpid(), binary_to_list(mk_id())]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    try
        Fun(Dir)
    after
        _ = file:del_dir_r(Dir)
    end.

mk_id() ->
    list_to_binary(
        "catcomp_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

register_shard(NS, Index, Shard, FoldModule) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => FoldModule,
        overlay => disabled
    }),
    {Cache, Proj}.

%% Like `register_shard/4` but also wires a `crdt_module`, so the
%% applier's cell kernel selects the operation-based `{crdt, _}` branch.
%% `fold_module` remains (a required registry field + the native CRDT
%% shares its state-byte format).
register_shard_crdt(NS, Index, Shard, FoldModule, CrdtModule) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => FoldModule,
        crdt_module => CrdtModule,
        overlay => disabled
    }),
    {Cache, Proj}.

close_shard(Cache, Proj) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

open_instance(InstanceId, NS, Origin) ->
    bondy_oplog:start_instance(InstanceId, #{
        origin => Origin,
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }).

append_cell(InstanceId, Key, Hlc, Value) ->
    append_op(InstanceId, Key, {set, Hlc, Value}).

append_op(InstanceId, Key, Op) ->
    _ = bondy_oplog:append(InstanceId, {cell_apply, ?B, Key, Op}),
    ok = bondy_oplog_test_projection:drain(InstanceId),
    ok.
