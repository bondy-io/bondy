%% =============================================================================
%% End-to-end test for the per-shard high-water HLC mark
%% (`bondy_oplog_high_water`).
%%
%% Verifies:
%%   - A fresh registration reports `{ok, no_watermark}`.
%%   - After one `cell_apply` event, the watermark equals the cell's
%%     HLC.
%%   - Monotonically-increasing cells advance the watermark each time.
%%   - An older-HLC event arriving after a newer one does NOT regress
%%     the watermark (the applier's HLC merge keeps the cell's HLC at
%%     the max, and `bondy_oplog_high_water:advance/2` is itself
%%     monotonic).
%%   - The watermark is per-shard: distinct shards report independent
%%     values.
%% =============================================================================
-module(bondy_oplog_applier_high_water_test).

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

high_water_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun fresh_shard_reports_no_watermark/0,
        fun one_cell_apply_advances_watermark/0,
        fun monotonic_cells_advance_each_time/0,
        fun older_cell_does_not_regress_watermark/0,
        fun watermark_is_per_shard/0,
        fun unregistered_shard_reports_not_found/0
    ]}.

fresh_shard_reports_no_watermark() ->
    {_Id, NS, _Cache, _Proj} = setup_instance(),
    ?assertEqual(
        {ok, no_watermark},
        bondy_oplog_core_registry:high_water_hlc(NS, primary, 0)
    ),
    teardown(NS).

one_cell_apply_advances_watermark() ->
    {Id, NS, _Cache, _Proj} = setup_instance(),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"alice">>, {set, 42, <<"v1">>}}
    ),
    _ = barrier(Id),
    ?assertEqual(
        {ok, 42},
        bondy_oplog_core_registry:high_water_hlc(NS, primary, 0)
    ),
    teardown(NS).

monotonic_cells_advance_each_time() ->
    {Id, NS, _Cache, _Proj} = setup_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k1">>, {set, 1, <<"a">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k2">>, {set, 5, <<"b">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k3">>, {set, 17, <<"c">>}}),
    _ = barrier(Id),
    ?assertEqual(
        {ok, 17},
        bondy_oplog_core_registry:high_water_hlc(NS, primary, 0)
    ),
    teardown(NS).

older_cell_does_not_regress_watermark() ->
    {Id, NS, _Cache, _Proj} = setup_instance(),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?B, <<"k1">>, {set, 100, <<"new">>}}
    ),
    _ = barrier(Id),
    %% Older HLC on a different key: the new cell's frame HLC is 3, but
    %% the high-water atomic should NOT regress.
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k2">>, {set, 3, <<"old">>}}),
    _ = barrier(Id),
    ?assertEqual(
        {ok, 100},
        bondy_oplog_core_registry:high_water_hlc(NS, primary, 0)
    ),
    teardown(NS).

watermark_is_per_shard() ->
    %% Two distinct shards in the same namespace. cell_apply against
    %% shard 0 must not move shard 1's watermark.
    {Id, NS, _Cache0, _Proj0} = setup_instance(),
    {_Cache1, _Proj1} = register_shard(NS, primary, 1),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k">>, {set, 77, <<"v">>}}),
    _ = barrier(Id),
    ?assertEqual(
        {ok, 77}, bondy_oplog_core_registry:high_water_hlc(NS, primary, 0)
    ),
    ?assertEqual(
        {ok, no_watermark},
        bondy_oplog_core_registry:high_water_hlc(NS, primary, 1)
    ),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 1),
    teardown(NS).

unregistered_shard_reports_not_found() ->
    ?assertEqual(
        not_found,
        bondy_oplog_core_registry:high_water_hlc(unknown_ns, primary, 0)
    ).

%% =============================================================================
%% Helpers (mirror bondy_oplog_applier_cell_apply_test)
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

teardown(NS) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)],
        N =:= NS
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
        "hwm_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

barrier(Id) ->
    bondy_oplog:projection(Id).
