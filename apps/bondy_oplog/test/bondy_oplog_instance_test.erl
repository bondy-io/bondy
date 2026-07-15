%% Tests for the per-instance MST owner (Stage 2 after second course
%% correction). Instance ids are binaries; lifecycle goes through the
%% library façade.

-module(bondy_oplog_instance_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

instance_test_() ->
    %% 30s per-test timeout (eunit default is 5s). Tests that call
    %% `await_apply/1`, `range/3`, or `concurrent_appends` wait for
    %% the applier to drain — under whole-suite load that occasionally
    %% takes longer than 5s and races the eunit watchdog.
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun empty_root_is_undefined/0},
        {timeout, 30, fun append_changes_root/0},
        {timeout, 30, fun append_round_trip/0},
        {timeout, 30, fun append_orders_keys/0},
        {timeout, 30, fun append_meta_round_trip/0},
        {timeout, 30, fun idempotent_append_remote/0},
        {timeout, 30, fun deterministic_root_across_replicas/0},
        {timeout, 30, fun fold_range_inclusive/0},
        {timeout, 30, fun range_returns_events_in_key_order/0},
        {timeout, 30, fun truncate_prefix/0},
        {timeout, 30, fun truncate_prefix_advances_watermark/0},
        {timeout, 30, fun size_tracks_inserts_and_truncations/0},
        {timeout, 60, fun concurrent_appends_unique_and_ordered/0},
        {timeout, 30, fun append_many_atomic/0},
        {timeout, 30, fun first_and_latest_keys/0},
        {timeout, 30, fun rejects_remote_event_with_local_origin/0},
        {timeout, 30, fun info_returns_diagnostic/0},
        {timeout, 30, fun divergent_remote_events_are_quarantined/0},
        {timeout, 30, fun custom_validator_can_reject_remote/0},
        {timeout, 30, fun refresh_validator_rotates_applier_snapshot/0},
        {timeout, 30, fun refresh_validator_noop_when_callback_not_exported/0},
        {timeout, 30, fun refresh_validator_returns_error_when_no_applier/0},
        {timeout, 30, fun refresh_validator_in_flight_keeps_old_snapshot/0},
        {timeout, 30, fun list_instances_reports_running/0},
        {timeout, 30, fun start_instance_idempotent/0}
    ]}.

empty_root_is_undefined() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    ?assertEqual(undefined, bondy_oplog:root_hash(Id)),
    ?assertEqual(0, bondy_oplog:size(Id)),
    ?assertEqual(empty, bondy_oplog:first_key(Id)),
    ?assertEqual(empty, bondy_oplog:latest_key(Id)),
    ok = bondy_oplog:stop_instance(Id).

append_changes_root() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    _ = bondy_oplog:append(Id, a),
    ok = bondy_oplog:await_apply(Id),
    R1 = bondy_oplog:root_hash(Id),
    _ = bondy_oplog:append(Id, b),
    ok = bondy_oplog:await_apply(Id),
    R2 = bondy_oplog:root_hash(Id),
    ?assert(is_binary(R1) andalso is_binary(R2)),
    ?assertNotEqual(R1, R2),
    ok = bondy_oplog:stop_instance(Id).

append_round_trip() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    K = bondy_oplog:append(Id, {payload, hello}),
    {ok, E} = bondy_oplog:get(Id, K),
    ?assertEqual({payload, hello}, bondy_oplog_event:op(E)),
    ?assertEqual(undefined, bondy_oplog_event:meta(E)),
    Missing = bondy_oplog_event:key(0, <<0>>, 0),
    ?assertEqual(not_found, bondy_oplog:get(Id, Missing)),
    ok = bondy_oplog:stop_instance(Id).

append_orders_keys() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Keys = [
        bondy_oplog:append(Id, {n, N})
     || N <- lists:seq(1, 50)
    ],
    ?assertEqual(Keys, lists:sort(Keys)),
    ?assertEqual(length(Keys), length(lists:usort(Keys))),
    ok = bondy_oplog:stop_instance(Id).

append_meta_round_trip() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Meta = {dots, [bondy_oplog_event:key(1, <<"x">>, 1)]},
    K = bondy_oplog:append(Id, op, Meta),
    {ok, E} = bondy_oplog:get(Id, K),
    ?assertEqual(Meta, bondy_oplog_event:meta(E)),
    ok = bondy_oplog:stop_instance(Id).

idempotent_append_remote() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    PeerKey = bondy_oplog_event:key(
        bondy_oplog_hlc:encode(erlang:system_time(millisecond) + 1000, 0),
        <<"peer-origin-aaaa">>,
        1
    ),
    PeerEvent = bondy_oplog_event:new(PeerKey, {peer_op, 1}, undefined),
    ok = bondy_oplog:append_remote(Id, PeerEvent),
    R1 = bondy_oplog:root_hash(Id),
    ok = bondy_oplog:append_remote(Id, PeerEvent),
    R2 = bondy_oplog:root_hash(Id),
    ?assertEqual(R1, R2),
    ?assertEqual(1, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

%% Two replicas, distinct origins, fed the same event set in opposite
%% orders → identical root hashes. Core convergence invariant.
deterministic_root_across_replicas() ->
    Events = [
        bondy_oplog_event:new(
            bondy_oplog_event:key(
                bondy_oplog_hlc:encode(1_000_000_000 + N, 0),
                <<"peer-origin-fixed">>,
                N
            ),
            {op, N},
            undefined
        )
     || N <- lists:seq(1, 100)
    ],
    IdA = mk_id(),
    IdB = mk_id(),
    {ok, _} = bondy_oplog:start_instance(IdA, #{
        origin => bondy_oplog_origin:new()
    }),
    {ok, _} = bondy_oplog:start_instance(IdB, #{
        origin => bondy_oplog_origin:new()
    }),
    [bondy_oplog:append_remote(IdA, E) || E <- Events],
    [bondy_oplog:append_remote(IdB, E) || E <- lists:reverse(Events)],
    RA = bondy_oplog:root_hash(IdA),
    RB = bondy_oplog:root_hash(IdB),
    ?assertEqual(RA, RB),
    ok = bondy_oplog:stop_instance(IdA),
    ok = bondy_oplog:stop_instance(IdB).

fold_range_inclusive() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Keys = [bondy_oplog:append(Id, N) || N <- lists:seq(1, 10)],
    [_, _, K3 | _] = Keys,
    K8 = lists:nth(8, Keys),
    Got = bondy_oplog:fold_range(
        Id,
        K3,
        K8,
        fun(E, Acc) -> [bondy_oplog_event:key(E) | Acc] end,
        []
    ),
    ?assertEqual(lists:sublist(Keys, 3, 6), lists:reverse(Got)),
    ok = bondy_oplog:stop_instance(Id).

range_returns_events_in_key_order() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    %% Capture append returns so a silent `{error, _}` from one of
    %% the writes does not masquerade as a read-path bug downstream.
    AppendKeys = [bondy_oplog:append(Id, N) || N <- lists:seq(1, 20)],
    Bad = [
        R
     || R <- AppendKeys,
        not is_tuple(R) orelse
            element(1, R) =:= error
    ],
    ?assertEqual([], Bad),
    Min = bondy_oplog_event:min_key(),
    Max = bondy_oplog_event:max_key_for_hlc(16#FFFFFFFFFFFFFFFF),
    Es = bondy_oplog:range(Id, Min, Max),
    Keys = [bondy_oplog_event:key(E) || E <- Es],
    ?assertEqual(20, length(Keys)),
    ?assertEqual(Keys, lists:sort(Keys)),
    ok = bondy_oplog:stop_instance(Id).

truncate_prefix() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Keys = [bondy_oplog:append(Id, N) || N <- lists:seq(1, 20)],
    Watermark = lists:nth(10, Keys),
    Removed = bondy_oplog:truncate_prefix(Id, Watermark),
    ?assertEqual(10, Removed),
    ?assertEqual(10, bondy_oplog:size(Id)),
    {ok, First} = bondy_oplog:first_key(Id),
    ?assert(First > Watermark),
    ok = bondy_oplog:stop_instance(Id).

%% After truncate_prefix, peer events with HLC =< Watermark must be
%% rejected by the receive-side filter — otherwise a peer that has not
%% yet seen the truncate would keep re-shipping the events we just
%% dropped.
truncate_prefix_advances_watermark() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Base = erlang:system_time(millisecond) + 1_000_000,
    MkEvent = fun(N) ->
        Key = bondy_oplog_event:key(
            bondy_oplog_hlc:encode(Base + N, 0),
            <<"peer-twwm-aaaa">>,
            N
        ),
        bondy_oplog_event:new(Key, {n, N}, undefined)
    end,
    Events = [MkEvent(N) || N <- lists:seq(1, 5)],
    [ok = bondy_oplog:append_remote(Id, E) || E <- Events],
    ok = bondy_oplog:await_apply(Id),
    ?assertEqual(5, bondy_oplog:size(Id)),
    ?assertEqual(undefined, bondy_oplog:current_watermark(Id)),
    K3 = bondy_oplog_event:key(lists:nth(3, Events)),
    Removed = bondy_oplog:truncate_prefix(Id, K3),
    ?assertEqual(3, Removed),
    ?assertEqual(2, bondy_oplog:size(Id)),
    ?assertEqual(K3, bondy_oplog:current_watermark(Id)),
    %% Re-shipped peer event with HLC =< Watermark: filtered, no install.
    ok = bondy_oplog:append_remote(Id, MkEvent(2)),
    ok = bondy_oplog:await_apply(Id),
    ?assertEqual(2, bondy_oplog:size(Id)),
    %% Fresh peer event past the watermark: installs normally.
    FreshKey = bondy_oplog_event:key(
        bondy_oplog_hlc:encode(Base + 100, 0),
        <<"peer-twwm-aaaa">>,
        100
    ),
    ok = bondy_oplog:append_remote(
        Id, bondy_oplog_event:new(FreshKey, {n, 100}, undefined)
    ),
    ok = bondy_oplog:await_apply(Id),
    ?assertEqual(3, bondy_oplog:size(Id)),
    %% Calling truncate_prefix with a lower watermark must NOT regress.
    K1 = bondy_oplog_event:key(lists:nth(1, Events)),
    _ = bondy_oplog:truncate_prefix(Id, K1),
    ?assertEqual(K3, bondy_oplog:current_watermark(Id)),
    ok = bondy_oplog:stop_instance(Id).

size_tracks_inserts_and_truncations() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    ?assertEqual(0, bondy_oplog:size(Id)),
    _ = [bondy_oplog:append(Id, N) || N <- lists:seq(1, 5)],
    ?assertEqual(5, bondy_oplog:size(Id)),
    {ok, K3} = pick_nth_key(Id, 3),
    _ = bondy_oplog:truncate_prefix(Id, K3),
    ?assertEqual(2, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

concurrent_appends_unique_and_ordered() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Parent = self(),
    NWorkers = 8,
    NPerWorker = 100,
    Pids = [
        spawn_link(fun() ->
            Keys = [
                bondy_oplog:append(Id, {worker, W, N})
             || N <- lists:seq(1, NPerWorker)
            ],
            Parent ! {self(), Keys}
        end)
     || W <- lists:seq(1, NWorkers)
    ],
    All = lists:flatten([
        receive
            {Wp, Ks} -> Ks
        end
     || Wp <- Pids
    ]),
    ?assertEqual(NWorkers * NPerWorker, length(All)),
    ?assertEqual(NWorkers * NPerWorker, length(lists:usort(All))),
    ?assertEqual(NWorkers * NPerWorker, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

append_many_atomic() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Items = [{op_a, undefined}, {op_b, undefined}, {op_c, undefined}],
    Keys = bondy_oplog:append_many(Id, Items),
    ?assertEqual(3, length(Keys)),
    ?assertEqual(Keys, lists:sort(Keys)),
    ?assertEqual(3, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

first_and_latest_keys() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    K1 = bondy_oplog:append(Id, a),
    K2 = bondy_oplog:append(Id, b),
    K3 = bondy_oplog:append(Id, c),
    ?assertEqual({ok, K1}, bondy_oplog:first_key(Id)),
    ?assertEqual({ok, K3}, bondy_oplog:latest_key(Id)),
    ?assert(K2 > K1 andalso K3 > K2),
    ok = bondy_oplog:stop_instance(Id).

rejects_remote_event_with_local_origin() ->
    Id = mk_id(),
    Origin = bondy_oplog_origin:new(),
    {ok, _} = bondy_oplog:start_instance(Id, #{origin => Origin}),
    Bogus = bondy_oplog_event:new(
        bondy_oplog_event:key(1, Origin, 1),
        op,
        undefined
    ),
    ?assertError(
        {remote_event_with_local_origin, _},
        bondy_oplog:append_remote(Id, Bogus)
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

info_returns_diagnostic() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Info = bondy_oplog:info(Id),
    ?assertMatch(#{instance_id := Id}, Info),
    ?assertMatch(#{backend := ets}, Info),
    ?assertMatch(
        #{validator := bondy_oplog_validator_trust},
        Info
    ),
    %% F7: fold_module defaults to undefined; fold_opts to #{}.
    ?assertMatch(#{fold_module := undefined, fold_opts := #{}}, Info),
    ok = bondy_oplog:stop_instance(Id).

%% Two remote events with the same `{HLC, Origin, Seq}` but different
%% payloads are equivocation. The instance must NOT crash — it must
%% reject the second event with `{error, equivocation_detected}`,
%% record the proof in the quarantine table, and keep the first event
%% as the canonical value.
divergent_remote_events_are_quarantined() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Key = bondy_oplog_event:key(
        bondy_oplog_hlc:encode(erlang:system_time(millisecond) + 1000, 0),
        <<"peer-origin-zzzz">>,
        1
    ),
    E1 = bondy_oplog_event:new(Key, value_a, undefined),
    E2 = bondy_oplog_event:new(Key, value_b, undefined),
    ok = bondy_oplog:append_remote(Id, E1),
    ?assertEqual(
        {error, equivocation_detected},
        bondy_oplog:append_remote(Id, E2)
    ),
    %% E1 is preserved; E2 is rejected.
    {ok, Stored} = bondy_oplog:get(Id, Key),
    ?assertEqual(value_a, bondy_oplog_event:op(Stored)),
    ?assertEqual(1, bondy_oplog:size(Id)),
    %% Quarantine row was recorded.
    ok = bondy_oplog_peer_state:sync(),
    {ok, Q} = wait_until_value(
        fun() -> bondy_oplog_quarantine:lookup(Id, Key) end,
        2000
    ),
    ?assertEqual(value_a, bondy_oplog_event:op(maps:get(event_one, Q))),
    ?assertEqual(value_b, bondy_oplog_event:op(maps:get(event_two, Q))),
    ok = bondy_oplog:stop_instance(Id).

%% A custom validator can reject peer events. We provide one that
%% returns `{error, refused}` and check the API surfaces the error.
custom_validator_can_reject_remote() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        validator => bondy_oplog_test_reject_validator
    }),
    Peer = bondy_oplog_event:new(
        bondy_oplog_event:key(1, <<"peer-origin-bbbb">>, 1),
        op,
        undefined
    ),
    ?assertEqual(
        {error, refused},
        bondy_oplog:append_remote(Id, Peer)
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

%% An operator rotates the validator snapshot at runtime via
%% `bondy_oplog_instance:refresh_validator/1`. Before the refresh the
%% validator accepts only `op_a` events; after the refresh it accepts
%% only `op_b` events. No subtree restart.
refresh_validator_rotates_applier_snapshot() ->
    Id = mk_id(),
    Tab = ets:new(refresh_rule, [public, set]),
    true = ets:insert(Tab, {allow_op, op_a}),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        validator => bondy_oplog_test_refreshable_validator,
        validator_opts => #{rule_table => Tab}
    }),
    %% Pre-refresh: only op_a is accepted.
    ?assertEqual(ok, append_peer_event(Id, op_a, 1)),
    ?assertEqual({error, refused}, append_peer_event(Id, op_b, 2)),
    %% Rotate the rule and trigger refresh.
    true = ets:insert(Tab, {allow_op, op_b}),
    ok = bondy_oplog_instance:refresh_validator(Id, test_rotation),
    %% Drain the cast so the applier's snapshot is swapped before we
    %% observe behaviour. `sys:get_state/1` is processed in mailbox
    %% order, so any prior cast has been handled by the time it
    %% returns.
    ApplierPid = bondy_oplog_registry:applier_pid(Id),
    ?assert(is_pid(ApplierPid)),
    _ = sys:get_state(ApplierPid),
    %% Post-refresh: only op_b is accepted; the old rule is gone.
    ?assertEqual(ok, append_peer_event(Id, op_b, 3)),
    ?assertEqual({error, refused}, append_peer_event(Id, op_a, 4)),
    ok = bondy_oplog:stop_instance(Id),
    true = ets:delete(Tab).

%% A validator without `refresh/1` is treated as "snapshot never
%% refreshes". The cast is silently ignored — no crash, no swap —
%% and subsequent verifications still use the original snapshot.
refresh_validator_noop_when_callback_not_exported() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        validator => bondy_oplog_test_reject_validator
    }),
    ?assertEqual(
        ok,
        bondy_oplog_instance:refresh_validator(Id, no_op_check)
    ),
    %% Validator is still alive and still rejecting.
    ?assertEqual({error, refused}, append_peer_event(Id, anything, 1)),
    ok = bondy_oplog:stop_instance(Id).

%% The applier-unavailable error surfaces when the subtree is not
%% running. Operators / tests can retry.
refresh_validator_returns_error_when_no_applier() ->
    Id = mk_id(),
    ?assertEqual(
        {error, applier_unavailable},
        bondy_oplog_instance:refresh_validator(Id)
    ).

%% An `enqueue_remote` worker that captured the OLD snapshot before
%% the refresh cast was processed continues to verify against that
%% old snapshot. We force the interleaving by
%% having `verify_event/2` block until the test releases each
%% worker; the test releases worker A (started under snapshot-1)
%% only after refreshing the applier to snapshot-2 and starting
%% worker B (which captures snapshot-2). If the implementation
%% were to read `state.validator_state` at verify-time rather than
%% at call-arrival, worker A would have returned snapshot-2's
%% verdict — the assertions below prove it does not.
refresh_validator_in_flight_keeps_old_snapshot() ->
    Id = mk_id(),
    Self = self(),
    %% Public ETS table for the blocking validator's `refresh/1` to
    %% read its next-state from. We seed `snapshot-2` here so the
    %% applier's eventual refresh swaps verdict ok -> refused.
    Tab = ets:new(bondy_oplog_test_blocking_validator, [public, named_table]),
    true = ets:insert(Tab, {Self, #{verdict => refused}}),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        validator => bondy_oplog_test_blocking_validator,
        validator_opts => #{coordinator => Self, verdict => ok}
    }),
    %% Spawn a helper that issues append_remote for event A. The
    %% helper will block until the test releases worker A.
    ResultA = make_ref(),
    HelperA = spawn_link(fun() ->
        Reply = append_peer_event(Id, op_alpha, 1),
        Self ! {ResultA, Reply}
    end),
    %% Wait for worker A's `verifying` notification — proves A is
    %% parked on its captured snapshot.
    WorkerA =
        receive
            {verifying, ok, WA} -> WA
        after 2000 ->
            ets:delete(Tab),
            exit(HelperA, kill),
            bondy_oplog:stop_instance(Id),
            error({timeout_waiting_for_worker_a})
        end,
    %% Refresh the applier's snapshot. Worker A is still parked
    %% inside `verify_event/2` and must remain unaffected.
    ok = bondy_oplog_instance:refresh_validator(Id, in_flight_test),
    ApplierPid = bondy_oplog_registry:applier_pid(Id),
    _ = sys:get_state(ApplierPid),
    %% Spawn helper for event B. Worker B captures the refreshed
    %% snapshot (verdict=refused).
    ResultB = make_ref(),
    HelperB = spawn_link(fun() ->
        Reply = append_peer_event(Id, op_beta, 2),
        Self ! {ResultB, Reply}
    end),
    WorkerB =
        receive
            {verifying, refused, WB} -> WB
        after 2000 ->
            ets:delete(Tab),
            exit(HelperA, kill),
            exit(HelperB, kill),
            bondy_oplog:stop_instance(Id),
            error({timeout_waiting_for_worker_b})
        end,
    %% Release worker A first; it must return ok (snapshot-1 verdict),
    %% proving in-flight events stick with their captured snapshot.
    WorkerA ! {release, WorkerA},
    WorkerB ! {release, WorkerB},
    ReplyA =
        receive
            {ResultA, RA} -> RA
        after 2000 -> error(timeout_a)
        end,
    ReplyB =
        receive
            {ResultB, RB} -> RB
        after 2000 -> error(timeout_b)
        end,
    ?assertEqual(ok, ReplyA),
    ?assertEqual({error, refused}, ReplyB),
    ets:delete(Tab),
    ok = bondy_oplog:stop_instance(Id).

list_instances_reports_running() ->
    A = mk_id(),
    B = mk_id(),
    {ok, _} = bondy_oplog:start_instance(A),
    {ok, _} = bondy_oplog:start_instance(B),
    Inst = bondy_oplog:list_instances(),
    ?assert(lists:member(A, Inst)),
    ?assert(lists:member(B, Inst)),
    ok = bondy_oplog:stop_instance(A),
    ok = bondy_oplog:stop_instance(B).

start_instance_idempotent() ->
    Id = mk_id(),
    {ok, Pid1} = bondy_oplog:start_instance(Id),
    {ok, Pid2} = bondy_oplog:start_instance(Id),
    ?assertEqual(Pid1, Pid2),
    ok = bondy_oplog:stop_instance(Id).

%% Helpers

mk_id() ->
    list_to_binary(
        "inst_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

%% Builds a synthetic peer-originated event with the given op and HLC
%% and forwards it through `append_remote/2`. The origin binary is
%% fixed across calls so the per-origin equivocation / ban logic is
%% never triggered; tests that need distinct origins should construct
%% events themselves.
append_peer_event(Id, Op, Hlc) ->
    Event = bondy_oplog_event:new(
        bondy_oplog_event:key(Hlc, <<"peer-origin-rfrsh">>, Hlc),
        Op,
        undefined
    ),
    bondy_oplog:append_remote(Id, Event).

pick_nth_key(Id, N) ->
    Es = bondy_oplog:range(
        Id,
        bondy_oplog_event:min_key(),
        bondy_oplog_event:max_key_for_hlc(16#FFFFFFFFFFFFFFFF)
    ),
    case length(Es) >= N of
        true -> {ok, bondy_oplog_event:key(lists:nth(N, Es))};
        false -> error
    end.

wait_until_value(_F, T) when T =< 0 -> error(timeout);
wait_until_value(F, T) ->
    case F() of
        not_found ->
            timer:sleep(20),
            wait_until_value(F, T - 20);
        {ok, _} = OK ->
            OK
    end.

%% =============================================================================
%% Stage 6: backpressure
%% =============================================================================

backpressure_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun rejects_append_when_full/0,
        fun infinity_disables_backpressure/0,
        fun append_many_atomic_under_cap/0
    ]}.

rejects_append_when_full() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        max_working_set => 3,
        origin => bondy_oplog_origin:new()
    }),
    [bondy_oplog:append(Id, X) || X <- lists:seq(1, 3)],
    %% Cap reached.
    ?assertEqual(
        {error, working_set_full},
        bondy_oplog:append(Id, x)
    ),
    ?assertEqual(3, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

infinity_disables_backpressure() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        max_working_set => infinity,
        origin => bondy_oplog_origin:new()
    }),
    [bondy_oplog:append(Id, X) || X <- lists:seq(1, 100)],
    ?assertEqual(100, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

%% append_many is atomic: either all events fit under the cap or none.
append_many_atomic_under_cap() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        max_working_set => 5,
        origin => bondy_oplog_origin:new()
    }),
    %% Fits.
    Items3 = [{op_a, undefined}, {op_b, undefined}, {op_c, undefined}],
    Keys = bondy_oplog:append_many(Id, Items3),
    ?assertEqual(3, length(Keys)),
    %% Doesn't fit (3 + 5 > cap=5).
    Items5 = [{op_x, undefined} || _ <- lists:seq(1, 5)],
    ?assertEqual(
        {error, working_set_full},
        bondy_oplog:append_many(Id, Items5)
    ),
    %% Atomic — no partial insert.
    ?assertEqual(3, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

%% =============================================================================
%% F7: Fold strategy config wiring (FOLD_STRATEGY_DESIGN §6/§7)
%% =============================================================================

fold_config_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun fold_module_defaults_to_undefined/0,
        fun fold_module_shorthand_accepted/0,
        fun fold_module_custom_module_accepted/0,
        fun fold_module_unknown_atom_crashes_init/0,
        fun fold_module_non_atom_crashes_init/0,
        fun fold_opts_non_map_crashes_init/0,
        fun fold_opts_passed_through_verbatim/0,
        fun registry_exposes_fold_fields/0
    ]}.

fold_module_defaults_to_undefined() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Info = bondy_oplog:info(Id),
    ?assertEqual(undefined, maps:get(fold_module, Info)),
    ?assertEqual(#{}, maps:get(fold_opts, Info)),
    ok = bondy_oplog:stop_instance(Id).

fold_module_shorthand_accepted() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register
    }),
    Info = bondy_oplog:info(Id),
    %% Shorthand atom recorded verbatim; resolution happens at call time.
    ?assertEqual(lww_register, maps:get(fold_module, Info)),
    ?assertEqual(#{}, maps:get(fold_opts, Info)),
    ok = bondy_oplog:stop_instance(Id).

fold_module_custom_module_accepted() ->
    %% The fully-qualified former-fold module name is a valid label — it
    %% resolves to its native CRDT twin (PR-Z) and is recorded verbatim.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => bondy_oplog_fold_lww_register
    }),
    Info = bondy_oplog:info(Id),
    ?assertEqual(bondy_oplog_fold_lww_register, maps:get(fold_module, Info)),
    ok = bondy_oplog:stop_instance(Id).

fold_module_unknown_atom_crashes_init() ->
    Id = mk_id(),
    Result = bondy_oplog:start_instance(Id, #{
        fold_module => not_a_real_fold_module_xyz
    }),
    %% init/1 raises (the label has no native CRDT twin); the supervisor
    %% surfaces the wrapped reason. We assert on the unwrapped structured
    %% reason and skip stop_instance — the instance never started.
    ?assertMatch(
        {error,
            {invalid_fold_module, Id, {unknown, not_a_real_fold_module_xyz}}},
        normalize_start_error(Result)
    ).

fold_module_non_atom_crashes_init() ->
    Id = mk_id(),
    Result = bondy_oplog:start_instance(Id, #{fold_module => 42}),
    ?assertMatch(
        {error, {invalid_fold_module, Id, {unknown, 42}}},
        normalize_start_error(Result)
    ).

fold_opts_non_map_crashes_init() ->
    Id = mk_id(),
    Result = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        fold_opts => [{not_a_map, 1}]
    }),
    ?assertMatch(
        {error, {invalid_fold_opts, _}},
        normalize_start_error(Result)
    ).

fold_opts_passed_through_verbatim() ->
    Id = mk_id(),
    Opts = #{custom_key => some_value, nested => #{deep => true}},
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        fold_opts => Opts
    }),
    ?assertEqual(Opts, maps:get(fold_opts, bondy_oplog:info(Id))),
    ok = bondy_oplog:stop_instance(Id).

registry_exposes_fold_fields() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        fold_opts => #{tag => abc}
    }),
    ?assertEqual(lww_register, bondy_oplog_registry:fold_module(Id)),
    ?assertEqual(#{tag => abc}, bondy_oplog_registry:fold_opts(Id)),
    %% Also verify presence in the full lookup map.
    {ok, Entry} = bondy_oplog_registry:lookup(Id),
    ?assertMatch(#{fold_module := lww_register}, Entry),
    ?assertMatch(#{fold_opts := #{tag := abc}}, Entry),
    ok = bondy_oplog:stop_instance(Id).

%% Supervisor start_instance wraps init/1 errors. The actual nesting
%% observed in practice is
%%   {error, {shutdown, {failed_to_start_child, Mod, {{Reason, Stack}, _}}}}
%% which we unwrap to surface `{error, Reason}` for the test assertions.
%% Various intermediate forms are tolerated so the helper stays useful
%% if the supervisor changes its wrapping later.
normalize_start_error({ok, _Pid}) ->
    %% Failure was expected — surfacing ok lets the assertMatch fail
    %% with a descriptive expected/got pair.
    ok;
normalize_start_error({error, Term}) ->
    {error, unwrap_supervisor_error(Term)};
normalize_start_error(Other) ->
    {error, Other}.

unwrap_supervisor_error({shutdown, Inner}) ->
    unwrap_supervisor_error(Inner);
unwrap_supervisor_error({failed_to_start_child, _Mod, Inner}) ->
    unwrap_supervisor_error(Inner);
unwrap_supervisor_error({Reason, Stack}) when is_list(Stack) ->
    %% gen_server crash form: `{Reason, Stacktrace}`. Distinguish
    %% from a "Reason that happens to be a 2-tuple with list payload"
    %% by checking that Stack is a list of 4-element stack frames.
    case is_stacktrace(Stack) of
        true -> Reason;
        false -> {Reason, Stack}
    end;
unwrap_supervisor_error(Reason) ->
    Reason.

is_stacktrace([Top | _]) when is_tuple(Top), tuple_size(Top) =:= 4 ->
    is_atom(element(1, Top)) andalso is_atom(element(2, Top));
is_stacktrace(_) ->
    false.
