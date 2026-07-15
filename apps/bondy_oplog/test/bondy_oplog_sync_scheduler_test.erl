%% Stage-3 sync-scheduler tests.

-module(bondy_oplog_sync_scheduler_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Reset state before each test:
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    %% Disable periodic ticks. The tests assert on explicit
    %% `trigger/0` invocations and on the exact count of dispatches
    %% the test produced — a stray periodic tick (default 500ms
    %% cadence) firing the configured dispatch fun in the window
    %% between the two `start_instance/1` calls of
    %% `dispatch_per_running_instance` produces an extra dispatch
    %% message that breaks the assertion.
    ok = bondy_oplog_sync_scheduler:set_interval_ms(0),
    ok.

cleanup(_) ->
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    %% Restore the default cadence; other suites may rely on periodic
    %% behaviour.
    ok = bondy_oplog_sync_scheduler:set_interval_ms(500),
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

sync_scheduler_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun trigger_invokes_dispatch/0,
        fun dispatch_per_running_instance/0,
        fun no_dispatch_when_no_instances/0,
        fun no_dispatch_when_dispatch_unset/0,
        fun peer_source_supplies_peers/0,
        fun static_source_returns_configured_peers/0,
        fun sample_source_picks_subset/0,
        fun partisan_source_excludes_self/0
    ]}.

trigger_invokes_dispatch() ->
    Self = self(),
    Ref = make_ref(),
    bondy_oplog_sync_scheduler:set_dispatch(
        fun(I, Peers) -> Self ! {Ref, I, Peers} end
    ),
    bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static,
        #{peers => [{peer, a}, {peer, b}]}
    ),
    Inst = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(Inst),
    bondy_oplog_sync_scheduler:trigger(),
    receive
        {Ref, Inst, [{peer, a}, {peer, b}]} -> ok
    after 1000 ->
        error(no_dispatch)
    end,
    ok = bondy_oplog:stop_instance(Inst).

dispatch_per_running_instance() ->
    Self = self(),
    Ref = make_ref(),
    bondy_oplog_sync_scheduler:set_dispatch(
        fun(I, _Peers) -> Self ! {Ref, I} end
    ),
    bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A),
    {ok, _} = bondy_oplog:start_instance(B),
    bondy_oplog_sync_scheduler:trigger(),
    Got = collect(Ref, 2, 1000),
    ?assertEqual(
        lists:sort([A, B]),
        lists:sort(Got)
    ),
    ok = bondy_oplog:stop_instance(A),
    ok = bondy_oplog:stop_instance(B).

no_dispatch_when_no_instances() ->
    Self = self(),
    Ref = make_ref(),
    bondy_oplog_sync_scheduler:set_dispatch(
        fun(I, _) -> Self ! {Ref, I} end
    ),
    bondy_oplog_sync_scheduler:trigger(),
    receive
        {Ref, _} -> error(unexpected_dispatch)
    after 200 ->
        ok
    end.

no_dispatch_when_dispatch_unset() ->
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    Inst = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(Inst),
    %% Should not crash even though no dispatch is set.
    bondy_oplog_sync_scheduler:trigger(),
    timer:sleep(50),
    ok = bondy_oplog:stop_instance(Inst).

peer_source_supplies_peers() ->
    Self = self(),
    Ref = make_ref(),
    %% Per-instance peer mapping handled by the static source's `peers`
    %% — verify it ends up in the dispatch.
    Peers = [{peer, x}, {peer, y}, {peer, z}],
    bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => Peers}
    ),
    bondy_oplog_sync_scheduler:set_dispatch(
        fun(_, Got) -> Self ! {Ref, Got} end
    ),
    Inst = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(Inst),
    bondy_oplog_sync_scheduler:trigger(),
    receive
        {Ref, Got} -> ?assertEqual(Peers, Got)
    after 1000 ->
        error(no_dispatch)
    end,
    ok = bondy_oplog:stop_instance(Inst).

static_source_returns_configured_peers() ->
    ?assertEqual(
        [a, b, c],
        bondy_oplog_peer_source_static:peers_for(
            <<"i">>, #{peers => [a, b, c]}
        )
    ),
    ?assertEqual(
        [],
        bondy_oplog_peer_source_static:peers_for(<<"i">>, #{})
    ).

sample_source_picks_subset() ->
    Pool = lists:seq(1, 20),
    Got = bondy_oplog_peer_source_sample:peers_for(
        <<"i">>, #{pool => Pool, count => 5}
    ),
    ?assertEqual(5, length(Got)),
    ?assert(lists:all(fun(X) -> lists:member(X, Pool) end, Got)),
    %% No duplicates.
    ?assertEqual(length(Got), length(lists:usort(Got))),
    %% When count >= pool size, returns the whole pool.
    All = bondy_oplog_peer_source_sample:peers_for(
        <<"i">>, #{pool => [1, 2, 3], count => 99}
    ),
    ?assertEqual([1, 2, 3], lists:sort(All)).

partisan_source_excludes_self() ->
    %% The partisan source reads live membership and removes the local
    %% node, so a single-node test cluster (members = [self]) yields an
    %% empty peer list. This pins both the self-exclusion and the
    %% members → sample delegation without needing a real cluster.
    ?assertEqual(
        [partisan:node()],
        element(2, partisan_peer_service:members())
    ),
    ?assertEqual(
        [],
        bondy_oplog_peer_source_partisan:peers_for(<<"i">>, #{})
    ),
    ?assertEqual(
        [],
        bondy_oplog_peer_source_partisan:peers_for(<<"i">>, #{count => 5})
    ).

%% Helpers

mk_inst() ->
    list_to_binary(
        "sched_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ).

collect(Ref, N, Timeout) ->
    collect(Ref, N, Timeout, []).

collect(_Ref, 0, _Timeout, Acc) ->
    Acc;
collect(Ref, N, Timeout, Acc) ->
    receive
        {Ref, X} -> collect(Ref, N - 1, Timeout, [X | Acc])
    after Timeout ->
        Acc
    end.
