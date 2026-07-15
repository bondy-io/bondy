%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Fused-writer rollout, Step 3: a `fused` ephemeral instance drains its own
%% WAL and installs into BOTH the projection and the MST inline, with NO
%% separate applier (the supervisor omits it). These tests prove the fused
%% drain actually runs end-to-end: a local write reaches the MST (live_size
%% advances — overlay-served reads would pass even with a broken drain, so we
%% gate on the install, not the read) and the value reads back correctly.
%%
%% Scope: the local drain path (the H1 removal). Cross-node convergence is
%% Step 4; these are single-node.

-module(bondy_db_fused_writer_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

fused_writer_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun fused_drain_installs_single_write/0},
        {timeout, 30, fun fused_drain_installs_batch/0}
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

fused_drain_installs_single_write() ->
    with_fused_db(fun(Db) ->
        {ok, T} = bondy_db:open_table(Db, things, #{fused => true}),
        Id = instance_id(T),
        Realm = <<"r1">>,
        K = <<"k1">>,
        H = bondy_db:tick(T),
        V = <<"v1">>,
        ok = bondy_db:apply(T, Realm, K, {set, H, V}),
        %% The fused drain installs into the MST asynchronously (no applier).
        %% Gate on live_size advancing — that is the proof the drain ran and
        %% the MST install happened, independent of the overlay-served read.
        ok = wait_until(fun() -> live_size(Id) >= 1 end, 5000),
        ?assertEqual({ok, {V, H}}, bondy_db:read(T, Realm, K)),
        ok = bondy_db:close_table(T)
    end).

fused_drain_installs_batch() ->
    with_fused_db(fun(Db) ->
        {ok, T} = bondy_db:open_table(Db, batch_things, #{fused => true}),
        Id = instance_id(T),
        Realm = <<"r1">>,
        N = 50,
        Writes = lists:map(
            fun(I) ->
                K = list_to_binary("k" ++ integer_to_list(I)),
                H = bondy_db:tick(T),
                V = list_to_binary("v" ++ integer_to_list(I)),
                ok = bondy_db:apply(T, Realm, K, {set, H, V}),
                {K, V, H}
            end,
            lists:seq(1, N)
        ),
        %% Every write must land in the MST via the fused drain.
        ok = wait_until(fun() -> live_size(Id) >= N end, 5000),
        lists:foreach(
            fun({K, V, H}) ->
                ?assertEqual({ok, {V, H}}, bondy_db:read(T, Realm, K))
            end,
            Writes
        ),
        ok = bondy_db:close_table(T)
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Shard-0 instance id from the table descriptor.
instance_id(Table) ->
    maps:get(0, maps:get(instance_ids, Table)).

live_size(Id) ->
    case bondy_oplog_registry:live_size(Id) of
        undefined -> 0;
        N -> N
    end.

wait_until(_Pred, Remaining) when Remaining =< 0 ->
    {error, timeout};
wait_until(Pred, Remaining) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(Pred, Remaining - 20)
    end.

mk_name() ->
    list_to_atom(
        "fw_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

with_fused_db(Fun) ->
    {ok, Db} = bondy_db:open(mk_name(), #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register
    }),
    try
        Fun(Db)
    after
        catch bondy_db:close(Db)
    end.
