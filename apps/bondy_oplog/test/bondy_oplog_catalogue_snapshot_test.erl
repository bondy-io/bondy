%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% End-to-end test for the catalogue-snapshot bootstrap responder.
%%
%% Drives `bondy_oplog_catalogue_snapshot:init/1,2` and `next/2`
%% through real `cell_apply` events appended via `bondy_oplog:append/2`.
%% Verifies:
%%   - Fresh shard (no cells applied yet) reports {ok, {0, Cursor}}.
%%   - After cell_apply events, init returns the high-water HLC and a
%%     cursor that paginates correctly through `next/2`.
%%   - Multiple `next/2` calls cover the full keyspace and terminate
%%     in `{ok, {done, []}}`.
%%   - A new bucket has no cells (single-bucket assumption holds).
%%   - Single-CRDT instances (with `crdt_module` set) report no_snapshot.
%%   - An expired/unknown cursor reports `cursor_expired`.
%% =============================================================================
-module(bondy_oplog_catalogue_snapshot_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

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

catalogue_snapshot_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun fresh_shard_init_returns_no_watermark_cursor/0,
        fun init_returns_watermark_after_cells/0,
        fun next_returns_batch_then_done/0,
        fun next_paginates_with_small_batch_size/0,
        fun single_crdt_instance_returns_no_snapshot/0,
        fun unknown_cursor_returns_expired/0,
        fun cursor_for_other_instance_returns_expired/0
    ]}.

fresh_shard_init_returns_no_watermark_cursor() ->
    {Id, _NS, _, _} = setup_instance(),
    {ok, {W, Cursor}} = bondy_oplog_catalogue_snapshot:init(Id),
    ?assertEqual(0, W),
    ?assert(is_binary(Cursor)),
    ?assertEqual(16, byte_size(Cursor)),
    %% Immediate `next` should return done since there are no cells.
    ?assertEqual(
        {ok, {done, []}},
        bondy_oplog_catalogue_snapshot:next(Id, Cursor)
    ),
    teardown(Id).

init_returns_watermark_after_cells() ->
    {Id, _NS, _, _} = setup_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"a">>, {set, 10, <<"va">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"b">>, {set, 25, <<"vb">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"c">>, {set, 17, <<"vc">>}}),
    _ = barrier(Id),
    {ok, {W, Cursor}} = bondy_oplog_catalogue_snapshot:init(Id),
    ?assertEqual(25, W),
    ?assert(is_binary(Cursor)),
    teardown(Id).

next_returns_batch_then_done() ->
    {Id, _NS, _, _} = setup_instance(),
    Keys = [<<"k0">>, <<"k1">>, <<"k2">>, <<"k3">>, <<"k4">>],
    [
        bondy_oplog:append(Id, {cell_apply, ?B, K, {set, 10 + I, <<I>>}})
     || {I, K} <- lists:zip(lists:seq(1, length(Keys)), Keys)
    ],
    _ = barrier(Id),
    {ok, {_W, Cursor}} = bondy_oplog_catalogue_snapshot:init(Id),
    {ok, {batch, {Cursor, Cells}}} =
        bondy_oplog_catalogue_snapshot:next(Id, Cursor),
    %% All 5 cells fit in the default batch of 64.
    ?assertEqual(5, length(Cells)),
    ReturnedKeys = [K || {_B, K, _F} <- Cells],
    ?assertEqual(lists:sort(Keys), lists:sort(ReturnedKeys)),
    %% Second `next` is the terminator.
    ?assertEqual(
        {ok, {done, []}},
        bondy_oplog_catalogue_snapshot:next(Id, Cursor)
    ),
    teardown(Id).

next_paginates_with_small_batch_size() ->
    %% Force a tiny batch size so we observe pagination.
    application:set_env(bondy_oplog, catalogue_snapshot_batch_size, 2),
    try
        {Id, _NS, _, _} = setup_instance(),
        Keys = [
            <<"k", (integer_to_binary(I))/binary>>
         || I <- lists:seq(0, 6)
        ],
        [
            bondy_oplog:append(Id, {cell_apply, ?B, K, {set, 10 + I, <<I>>}})
         || {I, K} <- lists:zip(lists:seq(1, length(Keys)), Keys)
        ],
        _ = barrier(Id),
        {ok, {_W, Cursor}} = bondy_oplog_catalogue_snapshot:init(Id),
        AllCells = pull_all(Id, Cursor, []),
        ReturnedKeys = [K || {_B, K, _F} <- AllCells],
        ?assertEqual(lists:sort(Keys), lists:sort(ReturnedKeys)),
        teardown(Id)
    after
        application:unset_env(bondy_oplog, catalogue_snapshot_batch_size)
    end.

single_crdt_instance_returns_no_snapshot() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        crdt_module => bondy_oplog_crdt_lww_register
    }),
    try
        ?assertEqual(
            {ok, no_snapshot},
            bondy_oplog_catalogue_snapshot:init(Id)
        )
    after
        bondy_oplog:stop_instance(Id)
    end.

unknown_cursor_returns_expired() ->
    {Id, _NS, _, _} = setup_instance(),
    Bogus = crypto:strong_rand_bytes(16),
    ?assertEqual(
        {error, cursor_expired},
        bondy_oplog_catalogue_snapshot:next(Id, Bogus)
    ),
    teardown(Id).

cursor_for_other_instance_returns_expired() ->
    {Id1, _, _, _} = setup_instance(),
    {Id2, _, _, _} = setup_instance(),
    {ok, {_W1, Cursor1}} = bondy_oplog_catalogue_snapshot:init(Id1),
    %% Using Cursor1 against Id2 must report expired.
    ?assertEqual(
        {error, cursor_expired},
        bondy_oplog_catalogue_snapshot:next(Id2, Cursor1)
    ),
    teardown(Id1),
    teardown(Id2).

%% =============================================================================
%% Helpers (mirror bondy_oplog_applier_high_water_test)
%% =============================================================================

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

teardown(Id) ->
    bondy_oplog:stop_instance(Id),
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

register_shard(NS, Index, Shard) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register
    }),
    {Cache, Proj}.

mk_id() ->
    iolist_to_binary([
        "cat_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

barrier(Id) ->
    bondy_oplog:projection(Id).

pull_all(Id, Cursor, Acc) ->
    case bondy_oplog_catalogue_snapshot:next(Id, Cursor) of
        {ok, {done, []}} ->
            lists:reverse(Acc);
        {ok, {batch, {Cursor, Cells}}} ->
            pull_all(Id, Cursor, lists:reverse(Cells) ++ Acc)
    end.
