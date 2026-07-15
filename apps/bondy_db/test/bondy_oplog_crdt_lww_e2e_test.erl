%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end test for the operation-based projection path.
%%
%% A catalogue shard is registered with `crdt_module =>
%% bondy_oplog_crdt_lww_register`, so the applier's cell kernel selects
%% the `{crdt, _}` branch: it maintains the materialised projection with
%% the commutative O(1) `apply_op/3` step (== `interpret_cog`), NOT the
%% deprecated `apply_event` fold. The same `{cell_apply, ...}` events the
%% fold path handles drive a real applier -> projection -> read round
%% trip, and the LWW semantics hold.
%%
%% This is the proof the selector + kernel + native CRDT wire together
%% through the live applier. The fold path is exercised (and proven
%% byte-identical) by `bondy_oplog_applier_cell_apply_test`; here the same
%% scenarios run on the CRDT kernel.

-module(bondy_oplog_crdt_lww_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(CRDT, bondy_oplog_crdt_lww_register).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

crdt_lww_e2e_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun crdt_kernel_writes_projection/0,
        fun crdt_read_round_trips/0,
        fun later_hlc_wins/0,
        fun earlier_hlc_is_absorbed/0,
        fun clear_then_resurrect/0,
        fun registry_records_crdt_module/0
    ]}.

%% The public-API path: `bondy_db:open_table` with `crdt_module` set,
%% driving the cell kernel through the facade end to end (ephemeral memory
%% topology — no leveled/disk).
crdt_lww_public_api_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            {ok, Db} = bondy_db:open(crdt_pub_db, #{
                topology => bondy_db_topology_memory,
                shard_count => 1,
                fold_module => lww_register,
                crdt_module => ?CRDT
            }),
            Db
        end,
        fun(Db) -> ok = bondy_db:close(Db) end, fun(Db) ->
            [
                {"info reports crdt_module", fun() -> pub_info(Db) end},
                {"apply then read on crdt kernel", fun() ->
                    pub_apply_read(Db)
                end}
            ]
        end}.

pub_info(Db) ->
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    ?assertEqual(?CRDT, maps:get(crdt_module, bondy_db:info(T))),
    ok = bondy_db:close_table(T).

pub_apply_read(Db) ->
    {ok, T} = bondy_db:open_table(Db, accounts, #{}),
    H1 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H1, <<"v1">>}),
    ?assertEqual({ok, {<<"v1">>, H1}}, bondy_db:read(T, <<"r1">>, <<"alice">>)),
    %% A later set wins; an earlier one is absorbed — LWW on the crdt kernel.
    H2 = bondy_db:tick(T),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H2, <<"v2">>}),
    ?assertEqual({ok, {<<"v2">>, H2}}, bondy_db:read(T, <<"r1">>, <<"alice">>)),
    ok = bondy_db:apply(T, <<"r1">>, <<"alice">>, {set, H1, <<"stale">>}),
    ?assertEqual({ok, {<<"v2">>, H2}}, bondy_db:read(T, <<"r1">>, <<"alice">>)),
    ok = bondy_db:close_table(T).

%% The read-overlay path (step 3b): a CRDT shard registered with the
%% overlay ENABLED. The read merges pending overlay events on top of the
%% projection via `interpret_cog` (the operation-based primitive), NOT a
%% per-event `apply_event` fold. Deterministic — seeds a projection frame
%% and inserts overlay rows directly (no live instance).
crdt_lww_overlay_test_() ->
    {setup, fun ov_setup/0, fun ov_teardown/1, fun(Ctx) ->
        [
            {
                "overlay sets interpreted as a COG (highest HLC wins, "
                "order-independent)",
                fun() -> ov_highest_hlc_wins(Ctx) end
            },
            {"overlay clear above the projection clears the cell", fun() ->
                ov_clear_clears(Ctx)
            end},
            {"overlay below the projection HLC is not merged", fun() ->
                ov_below_projection_ignored(Ctx)
            end}
        ]
    end}.

ov_highest_hlc_wins(#{ns := NS}) ->
    %% Projection base at HLC 5; two out-of-order overlay sets above it.
    materialise(NS, <<"k1">>, {set, <<"base">>, 5}, 5),
    overlay_insert(NS, <<"k1">>, 20, {set, 20, <<"newest">>}),
    overlay_insert(NS, <<"k1">>, 10, {set, 10, <<"mid">>}),
    ?assertEqual(
        {<<"newest">>, 20}, bondy_oplog_core:read(NS, primary, ?B, <<"k1">>)
    ).

ov_clear_clears(#{ns := NS}) ->
    materialise(NS, <<"k2">>, {set, <<"v">>, 5}, 5),
    overlay_insert(NS, <<"k2">>, 20, {clear, 20}),
    ?assertEqual(undefined, bondy_oplog_core:read(NS, primary, ?B, <<"k2">>)).

ov_below_projection_ignored(#{ns := NS}) ->
    %% An overlay event at or below the projection HLC is filtered by
    %% `read_overlay/4` (key_hlc > ProjHlc), so the projection value stands.
    materialise(NS, <<"k3">>, {set, <<"current">>, 50}, 50),
    overlay_insert(NS, <<"k3">>, 30, {set, 30, <<"stale">>}),
    ?assertEqual(
        {<<"current">>, 50}, bondy_oplog_core:read(NS, primary, ?B, <<"k3">>)
    ).

%% =============================================================================
%% Tests
%% =============================================================================

crdt_kernel_writes_projection() ->
    %% The frame the applier wrote must decode through the NATIVE CRDT's
    %% `decode_state/1` — proving the crdt kernel, not the fold, produced
    %% it.
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"alice">>, {set, 1, <<"v1">>}}
    ),
    _ = barrier(Id),
    {ok, Frame} = bondy_oplog_projection_ets:get(Proj, ?B, <<"alice">>),
    {Hlc, StateBytes, _ValueBytes} = bondy_oplog_cell_frame:decode_full(Frame),
    ?assertEqual({set, <<"v1">>, 1}, ?CRDT:decode_state(StateBytes)),
    ?assertEqual(1, Hlc),
    teardown_instance(Id, NS, Cache, Proj).

crdt_read_round_trips() ->
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"bob">>, {set, 42, <<"v">>}}),
    _ = barrier(Id),
    ?assertEqual({<<"v">>, 42}, bondy_oplog_core:read(NS, primary, <<"bob">>)),
    teardown_instance(Id, NS, Cache, Proj).

later_hlc_wins() ->
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"k">>, {set, 1, <<"first">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"k">>, {set, 2, <<"second">>}}
    ),
    _ = barrier(Id),
    ?assertEqual(
        {<<"second">>, 2}, bondy_oplog_core:read(NS, primary, <<"k">>)
    ),
    teardown_instance(Id, NS, Cache, Proj).

earlier_hlc_is_absorbed() ->
    %% A lower-HLC op applied after a higher one must leave the cell
    %% unchanged — proving the crdt kernel does a true read-modify-write
    %% (`apply_op/3` reads current state), not a blind overwrite.
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"k">>, {set, 5, <<"newer">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"k">>, {set, 3, <<"older">>}}
    ),
    _ = barrier(Id),
    ?assertEqual({<<"newer">>, 5}, bondy_oplog_core:read(NS, primary, <<"k">>)),
    teardown_instance(Id, NS, Cache, Proj).

clear_then_resurrect() ->
    {Id, NS, Cache, Proj} = setup_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k">>, {set, 1, <<"v1">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k">>, {clear, 2}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k">>, {set, 3, <<"v2">>}}),
    _ = barrier(Id),
    ?assertEqual({<<"v2">>, 3}, bondy_oplog_core:read(NS, primary, <<"k">>)),
    teardown_instance(Id, NS, Cache, Proj).

registry_records_crdt_module() ->
    {Id, NS, Cache, Proj} = setup_instance(),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    ?assertEqual(?CRDT, bondy_oplog_core_registry:entry_crdt_module(Entry)),
    teardown_instance(Id, NS, Cache, Proj).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_id() ->
    list_to_binary(
        "crdtlww_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

%% Register an `(NS, primary, 0)` shard whose cell projection runs on the
%% NATIVE CRDT kernel: `crdt_module` set (takes precedence), `fold_module`
%% present only because it is a required registry field (and is the read
%% path's value decoder — it agrees with the CRDT on value_equals_state).
register_shard(NS, Index, Shard) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => lww_register,
        crdt_module => ?CRDT,
        overlay => disabled
    }),
    {Cache, Proj}.

setup_instance() ->
    Id = mk_id(),
    NS = ns_of(Id),
    {Cache, Proj} = register_shard(NS, primary, 0),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }),
    {Id, NS, Cache, Proj}.

teardown_instance(Id, NS, Cache, Proj) ->
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

barrier(Id) ->
    bondy_oplog:projection(Id).

%% --- overlay fixture (deterministic, no live instance) ---------------------

ov_setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    NS = ns_of(mk_id()),
    {ok, CH} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, PH} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    OV = bondy_oplog_db_overlay:new(),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => CH,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => PH,
        overlay => OV,
        fold_module => lww_register,
        crdt_module => ?CRDT
    }),
    #{ns => NS, cache => CH, projection => PH, overlay => OV}.

ov_teardown(#{ns := NS, cache := CH, projection := PH, overlay := OV}) ->
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok = bondy_oplog_cache_ets:close(CH),
    ok = bondy_oplog_projection_ets:close(PH),
    ok = bondy_oplog_db_overlay:delete(OV).

materialise(NS, Key, State, Hlc) ->
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    PH = bondy_oplog_core_registry:entry_projection_handle(Entry),
    %% The native CRDT shares the fold's state-byte format, so the test
    %% helper's `lww_register` frame decodes through the crdt kernel.
    Frame = bondy_oplog_test_helpers:frame(lww_register, State, Hlc),
    ok = bondy_oplog_projection_ets:put_batch(PH, [{?B, Key, Frame}]).

overlay_insert(NS, Key, Hlc, Op) ->
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    OV = bondy_oplog_core_registry:entry_overlay(Entry),
    EvKey = bondy_oplog_event:key(Hlc, <<"ov_origin">>, Hlc),
    Event = bondy_oplog_event:new(EvKey, Op, #{}),
    ok = bondy_oplog_db_overlay:insert(OV, ?B, Key, Event).
