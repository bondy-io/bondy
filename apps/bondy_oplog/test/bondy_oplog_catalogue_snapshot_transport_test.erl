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
        fun single_crdt_instance_returns_no_snapshot/0,
        fun oversized_cell_ships_in_parts_and_reassembles/0,
        fun oversized_cell_is_never_advanced_past/0
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

%% A cell whose frame alone exceeds the response ceiling used to be reported to
%% metrics and ADVANCED PAST -- lost permanently, while the bootstrap still
%% adopted the peer's frontier so the oracle read CONVERGED. It must now be
%% shipped as parts that reassemble to the identical frame.
%%
%% Exercises the whole path the unit tests cannot: the cursor's `pending`
%% threading across rounds, the wire envelope, and the receiver's reassembly.
oversized_cell_ships_in_parts_and_reassembles() ->
    {Id, _NS, _, _} = setup_instance(),
    Big = crypto:strong_rand_bytes(40000),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"big">>, {set, 1, Big}}),
    _ = barrier(Id),
    with_ceiling(4000, fun() ->
        {ok, {init, {_W, Cursor}}} =
            ?T:request(Id, Id, get_catalogue_snapshot_init, #{}),
        {Cells, Pending, Rounds} = drain(Id, Cursor, [], #{}, 0),
        %% More than one round, or nothing was actually chunked.
        ?assert(Rounds > 1),
        %% Nothing left half-assembled: the stream ended cleanly.
        ?assertEqual(#{}, Pending),
        %% The oversized cell arrived, byte-identical after reassembly.
        Frames = [F || {_B, <<"big">>, F} <- Cells],
        ?assertMatch([_], Frames),
        [Frame] = Frames,
        {_Hlc, _State, ValueBytes} = bondy_oplog_cell_frame:decode_full(Frame),
        ?assertEqual(Big, binary_to_term(ValueBytes))
    end),
    teardown(Id).

%% The cursor must not pass a key whose parts are still in flight. If it did,
%% the tail of the cell would be lost while the stream still reported `done`.
oversized_cell_is_never_advanced_past() ->
    {Id, _NS, _, _} = setup_instance(),
    Big = crypto:strong_rand_bytes(30000),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"big">>, {set, 1, Big}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"zzz">>, {set, 2, <<"v">>}}),
    _ = barrier(Id),
    with_ceiling(4000, fun() ->
        {ok, {init, {_W, Cursor}}} =
            ?T:request(Id, Id, get_catalogue_snapshot_init, #{}),
        %% First chunked round must NOT be `done`, and must carry parts of
        %% part 1 of the big cell only.
        {ok, {chunked_batch, {_, [], Parts}}} =
            ?T:request(Id, Id, {get_catalogue_snapshot_next, Cursor}, #{}),
        ?assert(Parts =/= []),
        [{_, K, Idx, Total, _} | _] = Parts,
        ?assertEqual(<<"big">>, K),
        ?assertEqual(1, Idx),
        ?assert(Total > 1),
        %% Carry the parts already consumed above into the drain, or the
        %% reassembly can never complete — the test would then be measuring
        %% its own dropped parts rather than the protocol's.
        {Done0, Pending0} = bondy_oplog_sync_session:absorb_chunks(Parts, #{}),
        %% Drain the rest: both cells must arrive.
        {Cells, Pending, _} = drain(Id, Cursor, Done0, Pending0, 0),
        ?assertEqual(#{}, Pending),
        Keys = lists:sort([Key || {_, Key, _} <- Cells]),
        ?assertEqual([<<"big">>, <<"zzz">>], Keys)
    end),
    teardown(Id).

%% Pulls to `done`, reassembling parts exactly as `pull_install_loop` does.
drain(Id, Cursor, CellAcc, Pending, N) ->
    case ?T:request(Id, Id, {get_catalogue_snapshot_next, Cursor}, #{}) of
        {ok, {done, []}} ->
            {CellAcc, Pending, N};
        {ok, {batch, {_, Cells}}} ->
            drain(Id, Cursor, CellAcc ++ Cells, Pending, N + 1);
        {ok, {chunked_batch, {_, Cells, Chunks}}} ->
            {Done, Pending1} = bondy_oplog_sync_session:absorb_chunks(
                Chunks, Pending
            ),
            drain(Id, Cursor, CellAcc ++ Cells ++ Done, Pending1, N + 1)
    end.

with_ceiling(Bytes, Fun) ->
    Prev = application:get_env(bondy_oplog, sync_max_response_bytes),
    ok = application:set_env(bondy_oplog, sync_max_response_bytes, Bytes),
    try
        Fun()
    after
        case Prev of
            {ok, V} ->
                application:set_env(bondy_oplog, sync_max_response_bytes, V);
            undefined ->
                application:unset_env(bondy_oplog, sync_max_response_bytes)
        end
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
