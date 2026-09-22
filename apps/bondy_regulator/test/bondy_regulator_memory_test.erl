%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Pins `bondy_regulator_memory': the readers against cgroup fixtures, the
%% dwell window, and the whole sampler driven from a fixture through both
%% transitions with the alarm raised and cleared.
%%
%% The fixture is a directory the monitor is pointed at through
%% `memory_monitor_cgroup_root', laid out like the kernel's `/sys/fs/cgroup'.
%% Rewriting the fixture between samples is how memory "moves"; nothing in the
%% monitor is mocked.
-module(bondy_regulator_memory_test).

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_regulator_memory).
-define(PT_KEY, {bondy_regulator_memory, status}).
-define(ALARM, bondy_memory_high).
-define(ENV_KEYS, [
    memory_monitor_high_watermark,
    memory_monitor_low_watermark,
    memory_monitor_sample_interval_ms,
    memory_monitor_limit,
    memory_monitor_cgroup_root
]).

%% =============================================================================
%% FAIL OPEN
%% =============================================================================

fails_open_when_not_running_test() ->
    _ = persistent_term:erase(?PT_KEY),
    ?assertNot(?M:high()),
    ?assertEqual(normal, ?M:status()),
    ?assertMatch(#{status := normal, source := none}, ?M:usage()).

%% =============================================================================
%% READERS
%% =============================================================================

cgroup_v2_reads_anon_against_max_test() ->
    Root = fixture(v2, 900, 1000),
    ?assertEqual({ok, {900, 1000}}, ?M:read_cgroup(cgroup_v2, Root)).

cgroup_v2_max_is_unlimited_test() ->
    Root = fixture(v2, 900, max),
    ?assertEqual(unlimited, ?M:read_cgroup(cgroup_v2, Root)).

cgroup_v1_reads_total_rss_against_limit_test() ->
    Root = fixture(v1, 700, 1000),
    ?assertEqual({ok, {700, 1000}}, ?M:read_cgroup(cgroup_v1, Root)).

cgroup_v1_huge_limit_is_unlimited_test() ->
    %% The value the kernel reports for "no limit" on a 4 KiB page size.
    Root = fixture(v1, 700, 9223372036854771712),
    ?assertEqual(unlimited, ?M:read_cgroup(cgroup_v1, Root)).

%% A v2 fixture does not read as v1 and vice versa; an empty root reads as
%% neither. This is what keeps source resolution from guessing.
absent_files_are_an_error_test() ->
    V2 = fixture(v2, 900, 1000),
    ?assertMatch({error, _}, ?M:read_cgroup(cgroup_v1, V2)),
    V1 = fixture(v1, 700, 1000),
    ?assertMatch({error, _}, ?M:read_cgroup(cgroup_v2, V1)),
    Empty = tmp_dir(),
    ?assertMatch({error, _}, ?M:read_cgroup(cgroup_v2, Empty)),
    ?assertMatch({error, _}, ?M:read_cgroup(cgroup_v1, Empty)).

%% =============================================================================
%% DWELL (same semantics as the load monitor)
%% =============================================================================

transient_spike_does_not_flip_test() ->
    ?assertEqual({hold, 1}, ?M:step(0, 1, 0)),
    ?assertEqual({hold, 2}, ?M:step(0, 1, 1)),
    ?assertEqual({hold, 0}, ?M:step(0, 0, 2)).

sustained_crossing_commits_test() ->
    ?assertEqual({hold, 1}, ?M:step(0, 1, 0)),
    ?assertEqual({hold, 2}, ?M:step(0, 1, 1)),
    ?assertEqual({commit, 1}, ?M:step(0, 1, 2)).

sustained_recovery_commits_test() ->
    ?assertEqual({hold, 1}, ?M:step(1, 0, 0)),
    ?assertEqual({hold, 0}, ?M:step(1, 1, 1)),
    ?assertEqual({hold, 1}, ?M:step(1, 0, 0)),
    ?assertEqual({hold, 2}, ?M:step(1, 0, 1)),
    ?assertEqual({commit, 0}, ?M:step(1, 0, 2)).

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

lifecycle_test_() ->
    {timeout, 30, [
        {"a bounded cgroup drives high and back, alarm included",
            fun cgroup_drives_both_transitions/0},
        {"an explicit limit wins over the cgroup", fun explicit_limit_wins/0},
        {"no limit anywhere never reports high", fun no_source_never_high/0},
        {"restart and stop fail open, alarm included", fun restart_fails_open/0}
    ]}.

%% Usage sits at 90% of the limit: after the dwell the node is high and the
%% alarm is up with the declared details. The fixture then drops to 50%: after
%% the dwell the node is normal and the alarm is gone. A single low sample in
%% between must not clear it (the dwell), which the middle step pins.
cgroup_drives_both_transitions() ->
    Root = fixture(v2, 900, 1000),
    with_monitor(
        #{memory_monitor_cgroup_root => Root},
        fun() ->
            ok = await(fun() -> ?M:high() end),
            ?assertMatch(
                #{
                    status := high,
                    usage_bytes := 900,
                    limit_bytes := 1000,
                    source := cgroup_v2
                },
                ?M:usage()
            ),
            ?assertMatch(
                {ok, #{
                    usage_bytes := 900,
                    limit_bytes := 1000,
                    source := cgroup_v2
                }},
                alarm_details(?ALARM)
            ),

            %% One low sample, then back up: still high (dwell not met).
            ok = write_fixture(v2, Root, 500, 1000),
            ok = timer:sleep(interval() + interval() div 2),
            ok = write_fixture(v2, Root, 900, 1000),
            ok = timer:sleep(3 * interval()),
            ?assert(?M:high()),

            %% Sustained low: normal, alarm cleared.
            ok = write_fixture(v2, Root, 500, 1000),
            ok = await(fun() -> not ?M:high() end),
            ?assertEqual(error, alarm_details(?ALARM))
        end
    ).

%% With an explicit limit the fixture is ignored: the cgroup says 90% but the
%% reading is `erlang:memory(total)' against a limit far above it.
explicit_limit_wins() ->
    Root = fixture(v2, 900, 1000),
    with_monitor(
        #{
            memory_monitor_cgroup_root => Root,
            memory_monitor_limit => 1 bsl 50
        },
        fun() ->
            ok = timer:sleep(4 * interval()),
            ?assertNot(?M:high()),
            ?assertMatch(
                #{source := explicit, limit_bytes := 1125899906842624},
                ?M:usage()
            ),
            #{usage_bytes := U} = ?M:usage(),
            ?assert(U > 0)
        end
    ).

no_source_never_high() ->
    Root = fixture(v2, 900, max),
    with_monitor(
        #{memory_monitor_cgroup_root => Root},
        fun() ->
            ok = timer:sleep(4 * interval()),
            ?assertNot(?M:high()),
            ?assertMatch(#{source := none}, ?M:usage())
        end
    ).

%% The alarm goes with the monitor. A stop clears it on the way out; a kill
%% skips `terminate/2', so the next incarnation clears what the dead one
%% left before its own first sample. Without either, the alarm would outlive
%% the condition: nothing but a high-to-normal transition clears it, and a
%% fresh monitor starts at normal.
restart_fails_open() ->
    Root = fixture(v2, 900, 1000),
    with_monitor(
        #{memory_monitor_cgroup_root => Root},
        fun() ->
            ok = await(fun() -> ?M:high() end),
            Pid = whereis(?M),
            ok = gen_server:stop(Pid),
            ?assertNot(?M:high()),
            ?assertEqual(error, alarm_details(?ALARM)),

            {ok, Pid2} = ?M:start_link(),
            ?assertNot(?M:high()),
            ok = await(fun() -> ?M:high() end),
            ?assertMatch({ok, _}, alarm_details(?ALARM)),
            true = unlink(Pid2),
            Mon = monitor(process, Pid2),
            true = exit(Pid2, kill),
            receive
                {'DOWN', Mon, process, Pid2, killed} -> ok
            end,
            %% Nothing ran on the way out: the alarm (and the status) are
            %% the dead incarnation's until the supervisor's restart.
            ?assert(?M:high()),
            ?assertMatch({ok, _}, alarm_details(?ALARM)),

            {ok, Pid3} = ?M:start_link(),
            ?assertNot(?M:high()),
            ?assertEqual(error, alarm_details(?ALARM)),
            ok = gen_server:stop(Pid3)
        end
    ).

%% =============================================================================
%% UTILS
%% =============================================================================

interval() -> 20.

%% Runs `Fun' with a fresh monitor started under `Env', restoring the
%% application environment afterwards. The app's own instance goes first:
%% this test owns the server's lifecycle.
with_monitor(Env, Fun) ->
    {ok, _} = application:ensure_all_started(sasl),
    _ = application:stop(bondy_regulator),
    alarm_handler:clear_alarm(?ALARM),
    Saved = [{K, application:get_env(bondy_regulator, K)} || K <- ?ENV_KEYS],
    _ = [application:unset_env(bondy_regulator, K) || K <- ?ENV_KEYS],
    ok = application:set_env(
        bondy_regulator, memory_monitor_sample_interval_ms, interval()
    ),
    _ = [application:set_env(bondy_regulator, K, V) || K := V <- Env],
    {ok, Pid} = ?M:start_link(),
    try
        Fun()
    after
        is_process_alive(Pid) andalso gen_server:stop(Pid),
        alarm_handler:clear_alarm(?ALARM),
        _ = [restore_env(K, V) || {K, V} <- Saved]
    end.

restore_env(Key, undefined) ->
    application:unset_env(bondy_regulator, Key);
restore_env(Key, {ok, Value}) ->
    application:set_env(bondy_regulator, Key, Value).

%% Polls `Pred' for up to ten dwell windows.
await(Pred) ->
    await(Pred, 10 * 3 * interval()).

await(Pred, Left) when Left =< 0 ->
    ?assert(Pred());
await(Pred, Left) ->
    case Pred() of
        true ->
            ok;
        false ->
            ok = timer:sleep(interval()),
            await(Pred, Left - interval())
    end.

%% The alarm's `details' as recorded, or `error'. Read through OTP's
%% `alarm_handler:get_alarms/0': the `bondy_alarm_handler' projection needs
%% `bondy_router', which this app does not depend on. OTP's own handler keeps
%% the raised term as is, so the monitor's 3-tuple comes back whole.
alarm_details(Id) ->
    case lists:keyfind(Id, 1, alarm_handler:get_alarms()) of
        {Id, _Desc, #{details := Details}} -> {ok, Details};
        false -> error;
        Other -> {ok, Other}
    end.

%% A cgroup fixture: `v2' writes `memory.max' + `memory.stat' at the root,
%% `v1' writes `memory/memory.limit_in_bytes' + `memory/memory.stat'.
fixture(Layout, Usage, Limit) ->
    Root = tmp_dir(),
    ok = write_fixture(Layout, Root, Usage, Limit),
    Root.

write_fixture(v2, Root, Usage, Limit) ->
    ok = file:write_file(
        filename:join(Root, "memory.max"), [limit_text(Limit), "\n"]
    ),
    ok = file:write_file(
        filename:join(Root, "memory.stat"),
        io_lib:format("anon ~b~nfile 12345~nkernel 678~n", [Usage])
    );
write_fixture(v1, Root, Usage, Limit) ->
    Dir = filename:join(Root, "memory"),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(
        filename:join(Dir, "memory.limit_in_bytes"), [limit_text(Limit), "\n"]
    ),
    ok = file:write_file(
        filename:join(Dir, "memory.stat"),
        io_lib:format(
            "cache 12345~nrss ~b~ntotal_cache 12345~ntotal_rss ~b~n", [
                Usage, Usage
            ]
        )
    ).

limit_text(max) -> "max";
limit_text(N) -> integer_to_list(N).

%% `unique_integer' restarts with the VM, so a path can repeat across runs:
%% whatever an earlier run left there is removed first.
tmp_dir() ->
    Dir = filename:join(
        "/tmp",
        "bondy_regulator_memory_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    _ = file:del_dir_r(Dir),
    ok = filelib:ensure_path(Dir),
    Dir.
