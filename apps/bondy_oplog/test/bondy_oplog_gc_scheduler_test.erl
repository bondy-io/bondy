%% Stage-3 gc-scheduler tests. Stage 3 only verifies the trigger
%% plumbing; the actual compaction body lands in Stage 5.

-module(bondy_oplog_gc_scheduler_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    %% Disable periodic ticks for the duration of the suite — these
    %% tests assert on explicit `trigger/0` and `trigger_for/1` calls
    %% and a stray periodic tick (default 1s cadence) racing into the
    %% test window has caused intermittent `unexpected_trigger_for_b`
    %% failures under whole-suite load.
    ok = bondy_oplog_gc_scheduler:set_interval_ms(0),
    ok.

cleanup(_) ->
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    %% Restore the default periodic cadence so other suites that
    %% expect periodic behaviour are not silently de-instrumented.
    ok = bondy_oplog_gc_scheduler:set_interval_ms(1000),
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

gc_scheduler_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun trigger_invokes_callback/0,
        fun trigger_per_running_instance/0,
        fun trigger_for_single_instance/0,
        fun no_trigger_when_unset/0,
        fun trigger_error_does_not_crash/0,
        fun named_second_scheduler_is_independent/0
    ]}.

trigger_invokes_callback() ->
    Self = self(),
    Ref = make_ref(),
    bondy_oplog_gc_scheduler:set_trigger(
        fun(I) -> Self ! {Ref, I} end
    ),
    Inst = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(Inst),
    bondy_oplog_gc_scheduler:trigger(),
    receive
        {Ref, Inst} -> ok
    after 1000 ->
        error(no_trigger)
    end,
    ok = bondy_oplog:stop_instance(Inst).

trigger_per_running_instance() ->
    Self = self(),
    Ref = make_ref(),
    bondy_oplog_gc_scheduler:set_trigger(
        fun(I) -> Self ! {Ref, I} end
    ),
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A),
    {ok, _} = bondy_oplog:start_instance(B),
    bondy_oplog_gc_scheduler:trigger(),
    Got = collect(Ref, 2, 1000),
    ?assertEqual(lists:sort([A, B]), lists:sort(Got)),
    ok = bondy_oplog:stop_instance(A),
    ok = bondy_oplog:stop_instance(B).

trigger_for_single_instance() ->
    Self = self(),
    Ref = make_ref(),
    bondy_oplog_gc_scheduler:set_trigger(
        fun(I) -> Self ! {Ref, I} end
    ),
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A),
    {ok, _} = bondy_oplog:start_instance(B),
    bondy_oplog_gc_scheduler:trigger_for(A),
    receive
        {Ref, A} -> ok
    after 1000 ->
        error(no_trigger)
    end,
    %% Should not have triggered for B.
    receive
        {Ref, B} -> error(unexpected_trigger_for_b)
    after 100 ->
        ok
    end,
    ok = bondy_oplog:stop_instance(A),
    ok = bondy_oplog:stop_instance(B).

no_trigger_when_unset() ->
    Inst = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(Inst),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    bondy_oplog_gc_scheduler:trigger(),
    timer:sleep(50),
    ok = bondy_oplog:stop_instance(Inst).

trigger_error_does_not_crash() ->
    Self = self(),
    Ref = make_ref(),
    bondy_oplog_gc_scheduler:set_trigger(
        fun(_) ->
            Self ! {Ref, fired},
            erlang:error(boom)
        end
    ),
    Inst = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(Inst),
    bondy_oplog_gc_scheduler:trigger(),
    receive
        {Ref, fired} -> ok
    after 1000 ->
        error(no_trigger)
    end,
    %% The scheduler must still be alive after the callback raised.
    Pid = whereis(bondy_oplog_gc_scheduler),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)),
    ok = bondy_oplog:stop_instance(Inst).

%% Step 5 of BONDY_DB_RECLAMATION_PLAN.md — a SECOND scheduler instance with
%% its own name, interval, cap and trigger runs concurrently with the default
%% one, and neither observes the other's ticks or settings. This is what lets
%% reclamation run on its own cadence without duplicating the module.
named_second_scheduler_is_independent() ->
    Self = self(),
    RefD = make_ref(),
    RefN = make_ref(),
    Name = gc_sched_test_named,
    bondy_oplog_gc_scheduler:set_trigger(fun(I) -> Self ! {RefD, I} end),
    {ok, Pid} = bondy_oplog_gc_scheduler:start_link(#{
        name => Name,
        interval_ms => 0,
        trigger => fun(I) -> Self ! {RefN, I} end
    }),
    Inst = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(Inst),
    try
        %% Distinct registrations and distinct child ids — two children under
        %% one supervisor must not collide.
        ?assertNotEqual(whereis(bondy_oplog_gc_scheduler), Pid),
        ?assertEqual(
            Name,
            maps:get(
                id, bondy_oplog_gc_scheduler:child_spec(#{name => Name})
            )
        ),

        %% The named scheduler ticks ITS trigger, not the default's...
        bondy_oplog_gc_scheduler:trigger(Name),
        receive
            {RefN, Inst} -> ok
        after 1000 -> error(no_named_trigger)
        end,
        receive
            {RefD, _} -> error(default_fired_by_named_tick)
        after 100 -> ok
        end,

        %% ...and the default ticks only its own.
        bondy_oplog_gc_scheduler:trigger(),
        receive
            {RefD, Inst} -> ok
        after 1000 -> error(no_default_trigger)
        end,
        receive
            {RefN, _} -> error(named_fired_by_default_tick)
        after 100 -> ok
        end,

        %% Independent intervals: retuning the named one leaves the default
        %% untouched (the suite runs the default at 0).
        ok = bondy_oplog_gc_scheduler:set_interval_ms(Name, 60_000),
        ?assertEqual(
            60_000,
            maps:get(interval_ms, bondy_oplog_gc_scheduler:info(Name))
        ),
        ?assertEqual(
            0, maps:get(interval_ms, bondy_oplog_gc_scheduler:info())
        ),
        ?assertEqual(Name, maps:get(name, bondy_oplog_gc_scheduler:info(Name)))
    after
        gen_server:stop(Pid),
        bondy_oplog:stop_instance(Inst),
        bondy_oplog_gc_scheduler:set_trigger(undefined)
    end.

%% Helpers

mk_inst() ->
    list_to_binary(
        "gcsched_" ++
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
