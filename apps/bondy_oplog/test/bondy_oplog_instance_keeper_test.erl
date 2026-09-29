%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% `bondy_oplog_instance_keeper` starts a stopped instance again.
%%
%% Each case stops a started instance's subtree one way: killing its
%% supervisor, or killing its instance until the supervisor's restart
%% intensity is exhausted (it then stops with `shutdown`). The instance must
%% come back under a new supervisor and accept appends. The remaining cases
%% try to break that: a `stop_instance/1` during the backoff must be final, a
%% `start_instance/2` during the backoff must leave exactly one subtree once
%% the pending restart is due, a restarted keeper must still watch what the
%% old one watched, and a restart that fails must be retried rather than
%% dropped, including one that cannot read the persisted origin, which must
%% heal with that origin and its events once the file is readable again.
%% The backoff's growth beyond the first retry is not measured here.
%% =============================================================================

-module(bondy_oplog_instance_keeper_test).

-include_lib("eunit/include/eunit.hrl").

-define(KEEPER, bondy_oplog_instance_keeper).
%% First retry of a subtree that ran under 60 s: 2 s, plus the start.
-define(HEAL_TIMEOUT, 10000).

keeper_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a killed subtree is started again",
            {timeout, 60, fun killed_subtree_restarts/0}},
        {"a subtree that exhausts its restart intensity is started again",
            {timeout, 60, fun exhausted_subtree_restarts/0}},
        {"stop_instance during the backoff is final",
            {timeout, 60, fun stop_during_backoff_is_final/0}},
        {"start_instance during the backoff starts one subtree",
            {timeout, 60, fun start_during_backoff_starts_one/0}},
        {"a restarted keeper still watches",
            {timeout, 60, fun restarted_keeper_still_watches/0}},
        {"a failed restart is retried",
            {timeout, 60, fun failed_restart_is_retried/0}},
        {"an unreadable origin heals with the persisted origin",
            {timeout, 60, fun unreadable_origin_heals/0}}
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

killed_subtree_restarts() ->
    Id = mk_id(),
    {ok, Sup} = bondy_oplog:start_instance(Id),
    exit(Sup, kill),
    assert_heals(Id, Sup),
    ok = bondy_oplog:stop_instance(Id),
    assert_stays_stopped(Id).

exhausted_subtree_restarts() ->
    Id = mk_id(),
    {ok, Sup} = bondy_oplog:start_instance(Id),
    Ref = monitor(process, Sup),
    ok = kill_instance_until_down(Id, Ref),
    assert_heals(Id, Sup).

stop_during_backoff_is_final() ->
    Id = mk_id(),
    {ok, Sup} = bondy_oplog:start_instance(Id),
    Ref = monitor(process, Sup),
    exit(Sup, kill),
    receive
        {'DOWN', Ref, _, _, _} -> ok
    end,
    _ = bondy_oplog:stop_instance(Id),
    assert_stays_stopped(Id).

%% The caller's start is slowed past the keeper's first retry (2 s), so the
%% pending restart falls due while that start is still filling its subtree.
start_during_backoff_starts_one() ->
    Id = mk_id(),
    {ok, Sup} = bondy_oplog:start_instance(Id),
    Before = subtrees(),
    Ref = monitor(process, Sup),
    exit(Sup, kill),
    receive
        {'DOWN', Ref, _, _, _} -> ok
    end,
    Test = self(),
    ok = meck:new(bondy_oplog_instance_sup, [passthrough, no_link]),
    ok = meck:expect(
        bondy_oplog_instance_sup, start_children, fun(SupPid, I, Opts) ->
            _ =
                case self() of
                    Test -> timer:sleep(3000);
                    _ -> ok
                end,
            meck:passthrough([SupPid, I, Opts])
        end
    ),
    {ok, NewSup} = bondy_oplog:start_instance(Id),
    ?assertNotEqual(Sup, NewSup),
    timer:sleep(3000),
    ?assertEqual(Before, subtrees()),
    ?assertEqual(NewSup, bondy_oplog_registry:sup_pid(Id)),
    assert_heals(Id, Sup).

restarted_keeper_still_watches() ->
    Id = mk_id(),
    {ok, Sup} = bondy_oplog:start_instance(Id),
    Keeper = whereis(?KEEPER),
    exit(Keeper, kill),
    ok = wait_until(
        fun() ->
            P = whereis(?KEEPER),
            is_pid(P) andalso P =/= Keeper
        end,
        5000
    ),
    exit(Sup, kill),
    assert_heals(Id, Sup).

failed_restart_is_retried() ->
    Id = mk_id(),
    {ok, Sup} = bondy_oplog:start_instance(Id),
    Test = self(),
    Attempts = counters:new(1, []),
    ok = meck:new(bondy_oplog_instance_dyn_sup, [passthrough, no_link]),
    ok = meck:expect(
        bondy_oplog_instance_dyn_sup, restart_instance, fun(I, Opts) ->
            Test ! restart_attempt,
            ok = counters:add(Attempts, 1, 1),
            case counters:get(Attempts, 1) of
                1 -> {error, refused};
                _ -> meck:passthrough([I, Opts])
            end
        end
    ),
    exit(Sup, kill),
    [
        receive
            restart_attempt -> ok
        after ?HEAL_TIMEOUT -> error({no_restart_attempt, N})
        end
     || N <- [1, 2]
    ],
    assert_heals(Id, Sup).

%% The origin file is unreadable across the first retry (2 s), so that
%% restart fails; the next one, after the file is readable again, must bring
%% the instance back with the origin its WAL segments were written with.
unreadable_origin_heals() ->
    Id = mk_id(),
    Dir = filename:join(
        "/tmp/" ++ os:getpid(), "keeper_origin_" ++ binary_to_list(Id)
    ),
    Opts = #{
        storage_path => unicode:characters_to_binary(Dir),
        backend => bondy_mst_pack_store,
        seed => true
    },
    try
        {ok, Sup} = bondy_oplog:start_instance(Id, Opts),
        Origin = bondy_oplog:origin(Id),
        K = bondy_oplog:append(Id, before_restart),
        [File] = filelib:wildcard(Dir ++ "/**/origin"),
        ok = file:change_mode(File, 8#000),
        exit(Sup, kill),
        timer:sleep(3000),
        ?assertNot(is_pid(bondy_oplog_instance:whereis(Id))),
        ok = file:change_mode(File, 8#644),
        assert_heals(Id, Sup),
        ?assertEqual(Origin, bondy_oplog:origin(Id)),
        ?assertMatch({ok, _}, bondy_oplog:get(Id, K))
    after
        _ = os:cmd("chmod -R u+rw " ++ Dir ++ "; rm -rf " ++ Dir)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

%% `Id` is running under a supervisor other than `OldSup` and accepts writes.
assert_heals(Id, OldSup) ->
    ok = wait_until(
        fun() ->
            case bondy_oplog_registry:sup_pid(Id) of
                P when is_pid(P), P =/= OldSup -> is_process_alive(P);
                _ -> false
            end
        end,
        ?HEAL_TIMEOUT
    ),
    K = bondy_oplog:append(Id, healed),
    ?assertMatch({ok, _}, bondy_oplog:get(Id, K)).

%% Longer than the first retry's backoff, so a restart that was going to
%% happen has happened.
assert_stays_stopped(Id) ->
    timer:sleep(3000),
    ?assertNot(lists:member(Id, bondy_oplog:list_instances())),
    ?assertEqual(undefined, bondy_oplog_instance:whereis(Id)).

kill_instance_until_down(Id, Ref) ->
    receive
        {'DOWN', Ref, _, _, shutdown} -> ok
    after 100 ->
        case bondy_oplog_instance:whereis(Id) of
            P when is_pid(P) -> exit(P, kill);
            _ -> ok
        end,
        kill_instance_until_down(Id, Ref)
    end.

subtrees() ->
    length(supervisor:which_children(bondy_oplog_instance_dyn_sup)).

mk_id() ->
    list_to_binary(
        "keeper_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

wait_until(Fun, Timeout) when Timeout =< 0 ->
    error({timeout, Fun()});
wait_until(Fun, Timeout) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, Timeout - 50)
    end.
