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
        fun trigger_error_does_not_crash/0
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
