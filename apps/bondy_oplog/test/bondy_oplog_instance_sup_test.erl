%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% How `bondy_oplog_instance_dyn_sup` and `bondy_oplog_instance_sup` start a
%% subtree.
%%
%% `starts_overlap` holds every instance `init/1` at a gate (through the
%% default validator's `init/2`) and requires all instances to be inside it at
%% once. Starts serialised by one supervisor reach the gate one at a time, the
%% second only after the first's hold expires, past the gate timeout. It does
%% not measure how much two real recoveries overlap.
%% =============================================================================

-module(bondy_oplog_instance_sup_test).

-include_lib("eunit/include/eunit.hrl").

-define(INSTANCES, 4).
-define(GATE_TIMEOUT, 1500).
%% Longer than `GATE_TIMEOUT`, so the starts the case waits for can only all
%% arrive while every one of them is still held; finite, so a serialised
%% supervisor fails the case instead of hanging its cleanup.
-define(HOLD, 4000).
-define(START_ORDER, [
    bondy_oplog_instance,
    bondy_oplog_wal,
    bondy_oplog_applier,
    bondy_log_scrubber
]).

instance_sup_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"instances start at once", {timeout, 60, fun starts_overlap/0}},
        {"a one_for_all restart keeps the start order",
            {timeout, 60, fun restart_keeps_order/0}},
        {"a failed start leaves no subtree and no row",
            {timeout, 60, fun failed_start/0}}
    ]}.

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    _ = meck:unload(),
    _ = [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

starts_overlap() ->
    Test = self(),
    ok = meck:new(bondy_oplog_validator_trust, [passthrough, no_link]),
    ok = meck:expect(bondy_oplog_validator_trust, init, fun(Id, Opts) ->
        Test ! {starting, self()},
        receive
            release -> ok
        after ?HOLD -> ok
        end,
        meck:passthrough([Id, Opts])
    end),
    Ids = [mk_id() || _ <- lists:seq(1, ?INSTANCES)],
    _ = [
        spawn_link(fun() ->
            Test ! {started, Id, bondy_oplog_test_projection:start_instance(Id)}
        end)
     || Id <- Ids
    ],
    Starting = [
        receive
            {starting, Pid} -> Pid
        after ?GATE_TIMEOUT -> error({starts_serialised, N - 1})
        end
     || N <- lists:seq(1, ?INSTANCES)
    ],
    _ = [P ! release || P <- Starting],
    _ = [
        receive
            {started, Id, Result} -> ?assertMatch({ok, _}, Result)
        after ?HOLD -> error({never_started, Id})
        end
     || Id <- Ids
    ].

restart_keeps_order() ->
    Id = mk_id(),
    {ok, Sup} = bondy_oplog_test_projection:start_instance(Id),
    ?assertEqual(?START_ORDER, child_ids(Sup)),
    Old = bondy_oplog_instance:whereis(Id),
    exit(Old, kill),
    ok = wait_until(
        fun() ->
            P = bondy_oplog_instance:whereis(Id),
            is_pid(P) andalso P =/= Old andalso
                lists:all(fun is_pid/1, child_pids(Sup))
        end,
        2000
    ),
    ?assertEqual(?START_ORDER, child_ids(Sup)),
    K = bondy_oplog:append(Id, hi),
    ?assertMatch({ok, _}, bondy_oplog:get(Id, K)).

failed_start() ->
    Id = mk_id(),
    Before = length(supervisor:which_children(bondy_oplog_instance_dyn_sup)),
    ?assertMatch(
        {error,
            {shutdown,
                {failed_to_start_child, bondy_oplog_applier,
                    {error, {invalid_opt, oldstate_cache, _}}}}},
        bondy_oplog_test_projection:start_instance(Id, #{
            applier => #{oldstate_cache => yes}
        })
    ),
    ?assertEqual(
        Before, length(supervisor:which_children(bondy_oplog_instance_dyn_sup))
    ),
    ?assertEqual(undefined, bondy_oplog_registry:sup_pid(Id)),
    ?assertNot(lists:member(Id, bondy_oplog:list_instances())).

%% =============================================================================
%% Helpers
%% =============================================================================

%% `supervisor:which_children/1` lists children last-started first.
child_ids(Sup) ->
    lists:reverse([Id || {Id, _, _, _} <- supervisor:which_children(Sup)]).

child_pids(Sup) ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(Sup)].

mk_id() ->
    list_to_binary(
        "isup_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

wait_until(Fun, Timeout) when Timeout =< 0 ->
    error({timeout, Fun()});
wait_until(Fun, Timeout) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(Fun, Timeout - 20)
    end.
