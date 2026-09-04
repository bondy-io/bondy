%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Projection-cell reclamation vs the tier_2 stamp-site context guard.
%%
%% The guard (`bondy_oplog_ctx_guard`) remembers the highest causal context it
%% handed a stamp per cell and refuses any later stamp that reads a lower one,
%% because that means the cell's projection state was lost and the write would
%% re-mint a used dot and fork the value silently.
%%
%% The reclamation sweep DELETES a causally-stable dead cell on purpose. Its
%% context goes with it, so the next write to that key legitimately reads an
%% empty context — which is bit-for-bit what an accidental loss looks like. The
%% sweep therefore has to drop the cell from the guard as it deletes it; when it
%% did not, reclaiming a cell made the next write to that key fail, permanently,
%% for a loss that never happened. That is what the first test here pins.
%%
%% The complement — the guard STILL refusing an unexplained loss — is
%% `bondy_db_tier2_stamp_guard_test:regression_is_refused/0`, and the third test
%% here pins that reclaiming one cell does not disarm the guard for another.
%%
%% The CRDT has to be one that both carries a causal context and can discard, so
%% `bondy_oplog_crdt_ew_flag` (tier_2, and `delete/3` issues the `disable` whose
%% stable cell `stabilize/2` discards). A `lww_register` table cannot stand in:
%% LWW carries no context, so nothing is ever guarded and every test here passes
%% whatever the sweep does — which is how the third test caught this file's own
%% first draft.
%% =============================================================================

-module(bondy_db_tier2_reclaim_coevict_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_ew_flag).
-define(R, <<"r">>).
-define(TAB, items).

%% =============================================================================
%% Fixture
%% =============================================================================

reclaim_coevict_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(T) ->
        [
            {"the CRDT under test really is context-carrying", fun() ->
                crdt_is_tier_2()
            end},
            {"a reclaimed cell accepts the write that re-creates it", fun() ->
                rewrite_after_reclaim_is_accepted(T)
            end},
            {"reclaiming a cell repeatedly leaves it writable", fun() ->
                repeated_reclaim_cycles_stay_writable(T)
            end},
            {"reclaiming one cell keeps the guard armed for another", fun() ->
                reclaim_does_not_disarm_other_cells(T)
            end}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Only the sweep this module calls explicitly may reclaim, so a cell is
    %% deleted at a point the test knows.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    {ok, Db} = bondy_db:open(t2reclaim_db, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => ?CRDT,
        oplog_instance_opts => #{origin => bondy_oplog_origin:new()}
    }),
    {ok, T} = bondy_db:open_table(Db, ?TAB, #{}),
    put(db, Db),
    T.

cleanup(T) ->
    try
        bondy_db:close_table(T)
    catch
        _:_ -> ok
    end,
    try
        bondy_db:close(get(db))
    catch
        _:_ -> ok
    end,
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% The premise every other test rests on: a tier_0/tier_1 CRDT carries no
%% context, `bondy_oplog_ctx_guard:stamp/5` passes it through untracked, and
%% nothing here would be testing the guard at all.
crdt_is_tier_2() ->
    ?assertEqual(tier_2, ?CRDT:causal_tier()).

%% Two enables then a delete: `delete/3` issues `disable`, and `stabilize/2`
%% discards the disabled cell once its HLC is causally stable, deleting it.
%% Two writes precede the delete deliberately — a stamp records the context it
%% read BEFORE its write landed, so one write alone would leave the high-water
%% empty and an empty post-reclaim read would not regress below it, passing this
%% test whether or not the sweep co-evicts.
rewrite_after_reclaim_is_accepted(T) ->
    K = <<"reclaimed">>,
    ok = bondy_db:apply(T, ?R, K, enable),
    ok = bondy_db:apply(T, ?R, K, enable),
    ok = bondy_db:delete(T, ?R, K),

    %% The premise: the cell really was reclaimed. Without this the test would
    %% pass vacuously the day `stabilize/2` stops discarding a disabled flag.
    {ok, Stats} = sweep(T),
    ?assert(maps:get(discarded, Stats) >= 1),
    ?assertEqual({error, not_found}, bondy_db:read(T, ?R, K)),

    %% THE ASSERTION: re-creating the reclaimed cell is a legitimate write.
    %% Before the sweep co-evicted, this was
    %% `{error, {context_regression, <<"items">>, <<"r", 0, "reclaimed">>}}`.
    ?assertEqual(ok, bondy_db:apply(T, ?R, K, enable)),
    ?assertEqual(true, value(bondy_db:read(T, ?R, K))).

%% Reclaim is not a one-shot: a cell written, reclaimed, rewritten and
%% reclaimed again must stay writable. A co-eviction that fired only once per
%% cell — or a guard entry re-armed by the rewrite and not cleared by the second
%% sweep — fails here and not above.
repeated_reclaim_cycles_stay_writable(T) ->
    K = <<"cycled">>,
    lists:foreach(
        fun(_N) ->
            ?assertEqual(ok, bondy_db:apply(T, ?R, K, enable)),
            ?assertEqual(ok, bondy_db:apply(T, ?R, K, enable)),
            ok = bondy_db:delete(T, ?R, K),
            {ok, Stats} = sweep(T),
            ?assert(maps:get(discarded, Stats) >= 1),
            ?assertEqual({error, not_found}, bondy_db:read(T, ?R, K))
        end,
        lists:seq(1, 3)
    ),
    ?assertEqual(ok, bondy_db:apply(T, ?R, K, enable)),
    ?assertEqual(true, value(bondy_db:read(T, ?R, K))).

%% The co-eviction must be exactly as wide as the delete. A sweep that reset the
%% whole guard would also pass the two tests above while silently disarming the
%% detection this guard exists for, so this holds a SECOND cell whose projection
%% is destroyed behind the substrate's back and asserts it is still refused.
reclaim_does_not_disarm_other_cells(T) ->
    Reclaimed = <<"goes">>,
    Kept = <<"stays">>,

    ok = bondy_db:apply(T, ?R, Reclaimed, enable),
    ok = bondy_db:apply(T, ?R, Reclaimed, enable),
    ok = bondy_db:apply(T, ?R, Kept, enable),
    ok = bondy_db:apply(T, ?R, Kept, enable),
    ok = bondy_db:delete(T, ?R, Reclaimed),

    {ok, Stats} = sweep(T),
    ?assert(maps:get(discarded, Stats) >= 1),
    %% The live cell is untouched by the sweep.
    ?assertEqual(true, value(bondy_db:read(T, ?R, Kept))),

    %% An unexplained loss of the OTHER cell: delete its projection entry
    %% directly, which is not something the substrate did.
    ok = delete_projection_cell(T, Kept),
    ?assertEqual(
        {error, {context_regression, bucket(), cell_key(Kept)}},
        bondy_db:apply(T, ?R, Kept, enable)
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

%% One unbounded sweep at an HLC above every write so far, so a stable disabled
%% cell is judged reclaimable. Drains first: the sweep judges the projection,
%% which the applier has to have caught up to.
sweep(T) ->
    StableHlc = bondy_db:tick(T) + 1,
    InstanceId = instance_of(T),
    ok = bondy_oplog_instance:await_apply(InstanceId),
    Pid = bondy_oplog_registry:applier_pid(InstanceId),
    ?assert(is_pid(Pid)),
    bondy_oplog_applier:sweep_stable_cells(Pid, StableHlc).

%% Delete a cell straight out of the shard's projection, at the
%% `(EntityType bucket, <<Realm, 0, Key>>)` address the memory topology folds a
%% realm into — the same shape `bondy_db_tier2_stamp_guard_test` uses to
%% simulate durable-state loss.
delete_projection_cell(T, Key) ->
    NS = maps:get(namespace, bondy_db:info(T)),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    Adapter:delete(Handle, bucket(), cell_key(Key)).

bucket() ->
    atom_to_binary(?TAB, utf8).

cell_key(Key) ->
    <<?R/binary, 0, Key/binary>>.

instance_of(_T) ->
    [InstanceId | _] = [
        I
     || I <- bondy_oplog:list_instances(),
        binary:match(I, <<"t2reclaim_db-">>) =/= nomatch
    ],
    InstanceId.

value({ok, {V, _Hlc}}) -> V;
value(Other) -> Other.
