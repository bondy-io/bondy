%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Transport-layer test for the catalogue-snapshot bootstrap protocol.
%%
%% Drives `bondy_oplog_transport_inline:request/4` with the new
%% request shapes and verifies the wire envelopes:
%%   - get_catalogue_snapshot_init -> {ok, {init, {W, C}}} | {ok, no_snapshot}
%%   - {get_catalogue_snapshot_next, C} -> {ok, {batch, {C, [Cell]}}}
%%                                        | {ok, {done, []}}
%%                                        | {error, cursor_expired}
%% =============================================================================
-module(bondy_oplog_catalogue_snapshot_transport_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(T, bondy_oplog_transport_inline).

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

transport_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun init_wire_envelope/0,
        fun next_batch_then_done_wire_envelope/0,
        fun init_for_unknown_instance_errors/0,
        fun single_crdt_instance_returns_no_snapshot/0
    ]}.

init_wire_envelope() ->
    {Id, _NS, _, _} = setup_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"x">>, {set, 50, <<"v">>}}),
    _ = barrier(Id),
    ?assertMatch(
        {ok, {init, {50, Cursor}}} when is_binary(Cursor),
        ?T:request(Id, Id, get_catalogue_snapshot_init, #{})
    ),
    teardown(Id).

next_batch_then_done_wire_envelope() ->
    {Id, _NS, _, _} = setup_instance(),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"a">>, {set, 1, <<"va">>}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"b">>, {set, 2, <<"vb">>}}),
    _ = barrier(Id),
    {ok, {init, {_W, Cursor}}} =
        ?T:request(Id, Id, get_catalogue_snapshot_init, #{}),
    %% First call returns a batch.
    ?assertMatch(
        {ok, {batch, {Cursor, [_ | _]}}},
        ?T:request(Id, Id, {get_catalogue_snapshot_next, Cursor}, #{})
    ),
    %% Second call returns done.
    ?assertMatch(
        {ok, {done, []}},
        ?T:request(Id, Id, {get_catalogue_snapshot_next, Cursor}, #{})
    ),
    teardown(Id).

init_for_unknown_instance_errors() ->
    Bogus = <<"ghost-instance-id">>,
    ?assertMatch(
        {error, {peer_not_running, Bogus}},
        ?T:request(Bogus, Bogus, get_catalogue_snapshot_init, #{})
    ).

single_crdt_instance_returns_no_snapshot() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        crdt_module => bondy_oplog_crdt_lww_register
    }),
    try
        ?assertEqual(
            {ok, no_snapshot},
            ?T:request(Id, Id, get_catalogue_snapshot_init, #{})
        )
    after
        bondy_oplog:stop_instance(Id)
    end.

%% =============================================================================
%% Helpers
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
        "txp_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

barrier(Id) ->
    bondy_oplog:projection(Id).
