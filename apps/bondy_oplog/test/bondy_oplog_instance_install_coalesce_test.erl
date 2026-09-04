%% =============================================================================
%% Instance-side install coalescing tests for `bondy_oplog_instance`.
%%
%% When the applier outruns the instance, several `install_local_batch`
%% casts queue in the instance's mailbox while it is mid-`put_batch`. A4
%% drains the queued casts (up to `install_coalesce_max`) and merges every
%% cast's events into ONE `bondy_mst:put_batch/2` — amortising the O(log n)
%% spine rebuild (the dominant per-event durable cost, A0b) over many
%% casts' worth of events.
%%
%% The observable is the `[bondy_oplog, instance, mst_install]` telemetry
%% event, which fires once per `put_batch` carrying that batch's event
%% `count`. A backlog is created deterministically (no scheduler races, no
%% dependence on the applier/WAL durability pipeline) by suspending the
%% instance gen_server with `sys:suspend/1` and casting N synthetic
%% single-event `install_local_batch` messages straight at it; all N queue
%% while it is suspended. On `sys:resume/1` the first cast handler
%% coalesces them:
%%
%%   - install_coalesce_max large : N queued casts -> 1 put_batch.
%%   - install_coalesce_max = 1    : N queued casts -> N put_batch (control).
%%   - install_coalesce_max = K    : N queued casts -> ceil(N/K) put_batch.
%%
%% Same workload; the only difference is the knob.
%% =============================================================================

-module(bondy_oplog_instance_install_coalesce_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

coalesce_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun coalesces_queued_install_casts/0,
        fun disabled_one_put_batch_per_cast/0,
        fun respects_coalesce_cap/0,
        fun all_events_installed_exactly_once/0,
        fun invalid_install_coalesce_max_rejected/0,
        fun valid_minimum_install_coalesce_max_accepted/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

%% N queued install casts collapse into ONE put_batch when the cap
%% comfortably exceeds N.
coalesces_queued_install_casts() ->
    N = 30,
    {Total, Batches, Size} = run_queued(1000, N),
    ?assertEqual(N, Total),
    ?assertEqual(1, Batches),
    ?assertEqual(N, Size).

%% Control: cap 1 disables coalescing — one put_batch per cast. Flipping
%% the single knob from 1000 to 1 changes the put_batch count from 1 to N.
disabled_one_put_batch_per_cast() ->
    N = 30,
    {Total, Batches, Size} = run_queued(1, N),
    ?assertEqual(N, Total),
    ?assertEqual(N, Batches),
    ?assertEqual(N, Size).

%% The cap bounds the merge: N queued casts at cap K yield ceil(N/K)
%% put_batch calls. N=25, K=10 is deliberately NOT divisible (ceil=3,
%% floor=2) so the assertion distinguishes ceil from truncating division.
respects_coalesce_cap() ->
    N = 25,
    K = 10,
    {Total, Batches, Size} = run_queued(K, N),
    ?assertEqual(N, Total),
    ?assertEqual((N + K - 1) div K, Batches),
    ?assertEqual(N, Size).

%% Coalescing must not lose or duplicate events: the total installed event
%% count and the resulting MST size both equal the number cast, exactly.
all_events_installed_exactly_once() ->
    N = 50,
    {Total, _Batches, Size} = run_queued(16, N),
    ?assertEqual(N, Total),
    ?assertEqual(N, Size).

invalid_install_coalesce_max_rejected() ->
    Id = mk_id(),
    ?assertMatch({error, _}, start(Id, 0)).

valid_minimum_install_coalesce_max_accepted() ->
    Id = mk_id(),
    ?assertMatch({ok, _}, start(Id, 1)),
    ok = bondy_oplog:stop_instance(Id).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Suspend the instance, cast N synthetic single-event install_local_batch
%% messages straight at it (they queue while it is suspended), resume, then
%% collect the per-put_batch `mst_install` telemetry. Returns
%% {TotalEvents, NumBatches, MstSize}.
run_queued(CoalesceMax, N) ->
    Id = mk_id(),
    {ok, _} = start(Id, CoalesceMax),
    InstancePid = instance_pid_wait(Id),
    Origin = bondy_oplog:origin(Id),
    Events = mk_events(Origin, N),
    InFlightRef = bondy_oplog_registry:install_in_flight(Id),
    {Total, Batches} = with_collector(Id, N, fun() ->
        ok = sys:suspend(InstancePid),
        %% Mirror the applier's pre-cast increments so the instance's
        %% slot-release decrements land back on zero (no atomic underflow).
        ok = atomics:add(InFlightRef, 1, N),
        lists:foreach(
            fun(E) ->
                gen_server:cast(InstancePid, {install_local_batch, [E]})
            end,
            Events
        ),
        %% All N casts must be queued before resume so the first handler
        %% sees the whole backlog and coalesces deterministically.
        ok = wait_mailbox(InstancePid, N, 5000),
        ok = sys:resume(InstancePid)
    end),
    %% A synchronous call serialises after every queued cast handler, so by
    %% the time it returns the final install state is committed.
    Size = bondy_oplog:size(Id),
    ok = bondy_oplog:stop_instance(Id),
    {Total, Batches, Size}.

%% Attach an `mst_install`-event collector scoped to Id, run Fun, then
%% gather the per-put_batch counts until the total reaches Target.
with_collector(Id, Target, Fun) ->
    Self = self(),
    HandlerId = {?MODULE, make_ref()},
    Handler = fun
        (_Event, #{count := C}, #{instance_id := MId}, _Cfg) when MId == Id ->
            Self ! {mst_install, C};
        (_Event, _Meas, _Md, _Cfg) ->
            ok
    end,
    ok = telemetry:attach(
        HandlerId, [bondy_oplog, instance, mst_install], Handler, undefined
    ),
    try
        ok = Fun(),
        collect_installs(Target)
    after
        telemetry:detach(HandlerId)
    end.

%% Collect {mst_install, C} messages, summing the event counts and counting
%% the put_batch calls, until the sum reaches Target or a 5s deadline. Every
%% event is installed exactly once, so the sum lands exactly on Target and
%% the batch count is exact.
collect_installs(Target) ->
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    collect_installs(Target, 0, 0, Deadline).

collect_installs(Target, Sum, N, _Deadline) when Sum >= Target ->
    {Sum, N};
collect_installs(Target, Sum, N, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            {Sum, N};
        false ->
            receive
                {mst_install, C} ->
                    collect_installs(Target, Sum + C, N + 1, Deadline)
            after min(Remaining, 200) ->
                collect_installs(Target, Sum, N, Deadline)
            end
    end.

%% Poll until the process mailbox holds at least N messages (the queued
%% install casts) or the deadline passes.
wait_mailbox(_Pid, _N, Remaining) when Remaining =< 0 ->
    ok;
wait_mailbox(Pid, N, Remaining) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} when Len >= N ->
            ok;
        _ ->
            timer:sleep(10),
            wait_mailbox(Pid, N, Remaining - 10)
    end.

%% N local events with the instance's own origin, strictly-increasing HLCs
%% (one clock, N ticks) and seqs 1..N — so `is_fast_install/3` classifies
%% every one as a fast local install.
mk_events(Origin, N) ->
    Clock = bondy_oplog_hlc:new(),
    [
        mk_event(Origin, bondy_oplog_hlc:now(Clock), Seq)
     || Seq <- lists:seq(1, N)
    ].

mk_event(Origin, Hlc, Seq) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, {set, Seq, mk_val(Seq)}, undefined).

start(Id, CoalesceMax) ->
    bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        max_install_in_flight => 100000,
        install_coalesce_max => CoalesceMax
    }).

instance_pid_wait(Id) ->
    instance_pid_wait(Id, 50).

instance_pid_wait(Id, 0) ->
    error({no_instance_pid, Id});
instance_pid_wait(Id, Tries) ->
    case bondy_oplog_registry:instance_pid(Id) of
        Pid when is_pid(Pid) ->
            Pid;
        _ ->
            timer:sleep(20),
            instance_pid_wait(Id, Tries - 1)
    end.

mk_val(K) ->
    integer_to_binary(K).

mk_id() ->
    Int = erlang:unique_integer([positive]),
    <<"install-coalesce-test-", (integer_to_binary(Int))/binary>>.
