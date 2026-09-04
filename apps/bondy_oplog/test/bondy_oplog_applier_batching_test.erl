%% =============================================================================
%% Frame-coalescing tests for `bondy_oplog_applier`.
%%
%% The applier coalesces consecutive WAL frames into one batch until
%% `apply_batch_max_events` events have accumulated, amortising the
%% pack-store spine rebuild and the leveled `put_batch` over many events.
%%
%% The observable is the `[bondy_oplog, applier, applied]` telemetry event,
%% which fires once per applier batch carrying that batch's event `count`.
%% A backlog is created deterministically (no scheduler races) by suspending
%% the applier with `sys:suspend/1`, appending N single-event frames into the
%% WAL, then `sys:resume/1` + an explicit `drain` kick. The number of
%% `applied` events fired for the same N appends is the falsifying signal:
%%
%%   - apply_batch_max_events large : N frames -> 1 batch.
%%   - apply_batch_max_events = 1    : N frames -> N batches (the control).
%%   - apply_batch_max_events = K    : N frames -> ceil(N/K) batches.
%%
%% Same workload; the only difference is the knob. A separate test proves
%% coalescing engages ONLY under backlog: when the applier is caught up,
%% single appends still apply one frame at a time regardless of the knob.
%% =============================================================================

-module(bondy_oplog_applier_batching_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

batching_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun coalesces_backlog_into_single_batch/0,
        fun disabled_applies_one_frame_per_batch/0,
        fun respects_soft_cap/0,
        fun caught_up_does_not_coalesce/0,
        fun all_events_applied_exactly_once/0,
        fun invalid_apply_batch_max_events_rejected/0,
        fun valid_minimum_apply_batch_max_events_accepted/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

%% A backlog of N single-event frames coalesces into ONE applier batch
%% when the cap comfortably exceeds N.
coalesces_backlog_into_single_batch() ->
    N = 30,
    {Total, Batches, Proj} = run_backlog(1000, N),
    ?assertEqual(N, Total),
    ?assertEqual(1, Batches),
    ?assertMatch({ok, {set, _, N}}, Proj).

%% Control: the SAME backlog with the cap at 1 applies one frame per
%% batch. Flipping the single knob from 1000 to 1 changes the batch count
%% from 1 to N — the falsifying comparison.
disabled_applies_one_frame_per_batch() ->
    N = 30,
    {Total, Batches, Proj} = run_backlog(1, N),
    ?assertEqual(N, Total),
    ?assertEqual(N, Batches),
    ?assertMatch({ok, {set, _, N}}, Proj).

%% The soft cap bounds the batch: N single-event frames at a cap of K
%% yield ceil(N/K) batches.
respects_soft_cap() ->
    N = 30,
    K = 10,
    {Total, Batches, Proj} = run_backlog(K, N),
    ?assertEqual(N, Total),
    ?assertEqual(N div K, Batches),
    ?assertMatch({ok, {set, _, N}}, Proj).

%% Coalescing engages only under backlog. When the applier is caught up
%% (one append, drained, before the next), each frame applies on its own
%% even with a large cap — so there is no steady-state latency regression.
caught_up_does_not_coalesce() ->
    N = 10,
    Id = mk_id(),
    {ok, _} = start(Id, 1000),
    {Total, Batches} = with_collector(Id, N, fun() ->
        lists:foreach(
            fun(K) ->
                _ = bondy_oplog:append(Id, {set, K, mk_val(K)}),
                ok = bondy_oplog:await_apply(Id)
            end,
            lists:seq(1, N)
        )
    end),
    ?assertEqual(N, Total),
    ?assertEqual(N, Batches),
    ?assertEqual({ok, {set, mk_val(N), N}}, bondy_oplog:projection(Id)),
    ok = bondy_oplog:stop_instance(Id).

%% Coalescing must not lose or duplicate events: the total event count
%% across all batches equals the number appended, exactly.
all_events_applied_exactly_once() ->
    N = 50,
    {Total, _Batches, Proj} = run_backlog(16, N),
    ?assertEqual(N, Total),
    ?assertMatch({ok, {set, _, N}}, Proj).

invalid_apply_batch_max_events_rejected() ->
    Id = mk_id(),
    ?assertMatch({error, _}, start(Id, 0)).

valid_minimum_apply_batch_max_events_accepted() ->
    Id = mk_id(),
    ?assertMatch({ok, _}, start(Id, 1)),
    ok = bondy_oplog:stop_instance(Id).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Suspend the applier, append N single-event frames (building a WAL
%% backlog the applier cannot touch), resume + kick a drain, then collect
%% the per-batch `applied` telemetry. Returns {TotalEvents, NumBatches,
%% Projection}.
run_backlog(MaxEvents, N) ->
    Id = mk_id(),
    {ok, _} = start(Id, MaxEvents),
    ApplierPid = applier_pid_wait(Id),
    {Total, Batches} = with_collector(Id, N, fun() ->
        ok = sys:suspend(ApplierPid),
        lists:foreach(
            fun(K) -> _ = bondy_oplog:append(Id, {set, K, mk_val(K)}) end,
            lists:seq(1, N)
        ),
        ok = sys:resume(ApplierPid),
        %% Deterministic drain trigger (the queued idle-waiter DOWN would
        %% also fire one; a duplicate drain simply hits end_of_log).
        ApplierPid ! drain,
        ok = bondy_oplog:await_apply(Id)
    end),
    Proj = bondy_oplog:projection(Id),
    ok = bondy_oplog:stop_instance(Id),
    {Total, Batches, Proj}.

%% Attach an `applied`-event collector scoped to Id, run Fun, then gather
%% the per-batch counts until the total reaches Target (or a deadline).
with_collector(Id, Target, Fun) ->
    Self = self(),
    HandlerId = {?MODULE, make_ref()},
    Handler = fun
        (_Event, #{count := C}, #{instance_id := MId}, _Cfg) when MId == Id ->
            Self ! {applied_batch, C};
        (_Event, _Meas, _Md, _Cfg) ->
            ok
    end,
    ok = telemetry:attach(
        HandlerId, [bondy_oplog, applier, applied], Handler, undefined
    ),
    try
        ok = Fun(),
        collect_applied(Target)
    after
        telemetry:detach(HandlerId)
    end.

%% Collect {applied_batch, C} messages, summing the event counts and
%% counting the batches, until the sum reaches Target or a 5s deadline.
%% Because every event is applied exactly once the sum lands exactly on
%% Target, so the batch count is exact.
collect_applied(Target) ->
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    collect_applied(Target, 0, 0, Deadline).

collect_applied(Target, Sum, N, _Deadline) when Sum >= Target ->
    {Sum, N};
collect_applied(Target, Sum, N, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            {Sum, N};
        false ->
            receive
                {applied_batch, C} ->
                    collect_applied(Target, Sum + C, N + 1, Deadline)
            after min(Remaining, 200) ->
                collect_applied(Target, Sum, N, Deadline)
            end
    end.

start(Id, MaxEvents) ->
    bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{apply_batch_max_events => MaxEvents}
    }).

applier_pid_wait(Id) ->
    applier_pid_wait(Id, 50).

applier_pid_wait(Id, 0) ->
    error({no_applier_pid, Id});
applier_pid_wait(Id, Tries) ->
    case bondy_oplog_registry:applier_pid(Id) of
        Pid when is_pid(Pid) ->
            Pid;
        _ ->
            timer:sleep(20),
            applier_pid_wait(Id, Tries - 1)
    end.

mk_val(K) ->
    integer_to_binary(K).

mk_id() ->
    Int = erlang:unique_integer([positive]),
    <<"applier-batching-test-", (integer_to_binary(Int))/binary>>.
