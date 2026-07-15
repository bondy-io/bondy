%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% EUnit suite for the `bondy_mst` asynchronous-seal surface: the
%% `maybe_roll_for_seal/1` → `run_seal_job/1` → `complete_seal/2` delegation
%% (with `seal_job_pack_id/1` and `seal_in_flight/1`) through a tree backed by
%% the durable pack store in `seal_mode => async`, and the no-op answers a
%% non-sealing in-memory backend gives.
%% =============================================================================

-module(bondy_mst_async_seal_surface_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_mst_async_seal_surface_test_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        ]
    ),
    Dir = lists:flatten(Base),
    ok = filelib:ensure_path(Dir),
    Dir.

with_tmp_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        _ = file:del_dir_r(Dir)
    end.

new_async_tree(Dir, Threshold) ->
    bondy_mst:new(#{
        store => bondy_mst_pack_store,
        store_opts => #{
            dir => Dir,
            instance_id => <<"surface-async">>,
            seal_mode => async,
            auto_seal_records => Threshold,
            auto_seal_bytes => infinity
        },
        merger => fun(_K, _A, B) -> B end
    }).

val(K) ->
    integer_to_binary(K).

put_keys(T, Ks) ->
    bondy_mst:put_batch(T, [{K, val(K)} || K <- Ks]).

assert_all_get(T, Ks) ->
    lists:foreach(
        fun(K) -> ?assertEqual(val(K), bondy_mst:get(T, K)) end, Ks
    ).

%% =============================================================================
%% Pack-store (async) surface
%% =============================================================================

surface_roll_run_complete_roundtrip_test() ->
    with_tmp_dir(fun(Dir) ->
        Ks = lists:seq(1, 40),
        T0 = new_async_tree(Dir, 3),
        T1 = put_keys(T0, Ks),
        ?assertNot(bondy_mst:seal_in_flight(T1)),

        {rolled, Job, T2} = bondy_mst:maybe_roll_for_seal(T1),
        ?assert(bondy_mst:seal_in_flight(T2)),
        PackId = bondy_mst:seal_job_pack_id(Job),
        ?assert(is_integer(PackId) andalso PackId >= 1),

        %% Reads are served across the in-flight seal.
        assert_all_get(T2, Ks),

        ?assertEqual(ok, bondy_mst:run_seal_job(Job)),
        {ok, T3} = bondy_mst:complete_seal(T2, PackId),
        ?assertNot(bondy_mst:seal_in_flight(T3)),

        %% Reads still correct after the sealed view is mounted.
        assert_all_get(T3, Ks),
        bondy_mst:close(T3)
    end).

surface_defer_while_in_flight_test() ->
    with_tmp_dir(fun(Dir) ->
        T0 = new_async_tree(Dir, 3),
        T1 = put_keys(T0, lists:seq(1, 20)),
        {rolled, _Job, T2} = bondy_mst:maybe_roll_for_seal(T1),

        %% More writes past the threshold while the seal is in flight → defer.
        T3 = put_keys(T2, lists:seq(100, 130)),
        ?assertMatch({defer, _}, bondy_mst:maybe_roll_for_seal(T3)),
        bondy_mst:close(T3)
    end).

%% =============================================================================
%% In-memory backend: surface is a no-op
%% =============================================================================

surface_ets_backend_noop_test() ->
    T0 = bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => <<"surface-ets">>},
        merger => fun(_K, _A, B) -> B end
    }),
    T1 = put_keys(T0, lists:seq(1, 10)),
    ?assertNot(bondy_mst:seal_in_flight(T1)),
    ?assertMatch({noop, _}, bondy_mst:maybe_roll_for_seal(T1)),
    %% complete_seal on a non-sealing backend is a harmless no-op.
    ?assertMatch({ok, _}, bondy_mst:complete_seal(T1, 1)),
    bondy_mst:close(T1).
