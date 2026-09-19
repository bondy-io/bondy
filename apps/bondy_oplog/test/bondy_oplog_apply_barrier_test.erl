%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% The per-event apply barrier: an appender waits for ITS event, answered
%% through the alias its overlay row carries (`bondy_oplog:append/4`,
%% `await_applied/3`, `append_applied/4`).
%%
%% Each case names the claim it can break:
%%
%% - `own_event_not_whole_overlay`: with other events pending on the shard
%%   forever, the appender's own event is still answered — while the
%%   whole-overlay `await_apply/2` barrier times out on the same shard.
%% - `rejection_is_reported`: an event the applier refuses answers
%%   `{error, rejected}`, never `ok`.
%% - `rejection_cannot_be_missed`: the answer survives the appender not
%%   listening until AFTER the applier has refused and evicted the event —
%%   the interleaving a barrier registered after the append would lose.
%% - `timeout_leaves_no_stray_answer`: after `{error, timeout}` the late
%%   answer never reaches the appender's mailbox.
%% - `refused_append_sends_nothing`: an append the WAL/admission refuses
%%   stages no row, so nothing is ever sent for its alias.
%% - `batch_is_answered_per_event` / `batch_rejection_is_reported`: a
%%   batch collects one answer per event; any refusal decides the batch.
%% - `fused_instance_answers`: the fused install path (no applier process)
%%   answers both outcomes too.
%% - `instance_death_answers_at_once` / `batch_instance_death_answers_at_once`:
%%   the instance dying with answers owed ends the wait immediately with
%%   `{error, instance_unavailable}` — not after the timeout.
%% =============================================================================

-module(bondy_oplog_apply_barrier_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

-define(VALIDATOR, bondy_oplog_validator_trust).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    _ =
        try
            meck:unload(?VALIDATOR)
        catch
            _:_ -> ok
        end,
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

apply_barrier_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun own_event_not_whole_overlay/0},
        {timeout, 30, fun rejection_is_reported/0},
        {timeout, 30, fun rejection_cannot_be_missed/0},
        {timeout, 30, fun timeout_leaves_no_stray_answer/0},
        {timeout, 30, fun refused_append_sends_nothing/0},
        {timeout, 30, fun batch_is_answered_per_event/0},
        {timeout, 30, fun batch_rejection_is_reported/0},
        {timeout, 30, fun fused_instance_answers/0},
        {timeout, 30, fun instance_death_answers_at_once/0},
        {timeout, 30, fun batch_instance_death_answers_at_once/0}
    ]}.

%% =============================================================================
%% TESTS
%% =============================================================================

own_event_not_whole_overlay() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    %% Three events that will never be applied: rows the applier does not
    %% know about, so nothing ever evicts them. This is the shard-level
    %% backlog the customer's single hot key produced.
    Tab = bondy_oplog_registry:overlay_tab(Id),
    true = ets:insert(Tab, [fake_overlay_row(N) || N <- lists:seq(1, 3)]),
    ?assertEqual(ok, bondy_oplog:append_applied(Id, mine, undefined, 5000)),
    %% The backlog is still there, and the whole-overlay barrier is what
    %% it blocks.
    ?assertEqual(3, ets:info(Tab, size)),
    ?assertEqual({error, timeout}, bondy_oplog:await_apply(Id, 300)),
    true = ets:delete_all_objects(Tab),
    ok = bondy_oplog:stop_instance(Id).

rejection_is_reported() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    ok = refuse_every_event(),
    ?assertEqual(
        {error, rejected},
        bondy_oplog:append_applied(Id, refused, undefined, 5000)
    ),
    %% The refused event's row is gone: it is in the WAL, not pending.
    ?assertEqual(0, ets:info(bondy_oplog_registry:overlay_tab(Id), size)),
    ok = meck:unload(?VALIDATOR),
    ok = bondy_oplog:stop_instance(Id).

rejection_cannot_be_missed() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    ok = refuse_every_event(),
    Barrier = bondy_oplog:barrier(Id),
    _Key = bondy_oplog:append(Id, refused, undefined, Barrier),
    %% Only start listening once the applier has refused the event and
    %% evicted its row — the row is what carried the interest.
    ok = wait_until_overlay_empty(Id),
    ?assertEqual(
        {error, rejected}, bondy_oplog:await_applied(Barrier, 1, 1000)
    ),
    ok = meck:unload(?VALIDATOR),
    ok = bondy_oplog:stop_instance(Id).

timeout_leaves_no_stray_answer() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Applier = bondy_oplog_registry:applier_pid(Id),
    true = is_pid(Applier),
    sys:suspend(Applier),
    ?assertEqual(
        {error, timeout},
        bondy_oplog:append_applied(Id, late, undefined, 100)
    ),
    sys:resume(Applier),
    %% The event is applied now — and its answer, sent to a deactivated
    %% alias, was dropped by the VM rather than delivered to us.
    ?assertEqual(ok, bondy_oplog:await_apply(Id, 5000)),
    ?assertEqual(none, stray_answer()),
    ok = bondy_oplog:stop_instance(Id).

refused_append_sends_nothing() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{max_overlay_events => 1}),
    %% Fill the cap with a real pending event (admission reads the
    %% counters the append path maintains, not the table), then have the
    %% next append refused at admission.
    Applier = bondy_oplog_registry:applier_pid(Id),
    sys:suspend(Applier),
    _ = bondy_oplog:append(Id, filler),
    ?assertEqual(
        {error, backpressure},
        bondy_oplog:append_applied(Id, refused, undefined, 1000)
    ),
    sys:resume(Applier),
    ?assertEqual(ok, bondy_oplog:await_apply(Id, 5000)),
    ?assertEqual(none, stray_answer()),
    ok = bondy_oplog:stop_instance(Id).

batch_is_answered_per_event() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Barrier = bondy_oplog:barrier(Id),
    Items = [{{item, N}, undefined} || N <- lists:seq(1, 5)],
    Keys = bondy_oplog:append_many(Id, Items, Barrier),
    ?assertEqual(5, length(Keys)),
    ?assertEqual(ok, bondy_oplog:await_applied(Barrier, 5, 5000)),
    ?assertEqual(none, stray_answer()),
    ok = bondy_oplog:stop_instance(Id).

batch_rejection_is_reported() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    ok = refuse_every_event(),
    Barrier = bondy_oplog:barrier(Id),
    Items = [{{item, N}, undefined} || N <- lists:seq(1, 3)],
    _Keys = bondy_oplog:append_many(Id, Items, Barrier),
    ?assertEqual(
        {error, rejected}, bondy_oplog:await_applied(Barrier, 3, 5000)
    ),
    ?assertEqual(none, stray_answer()),
    ok = meck:unload(?VALIDATOR),
    ok = bondy_oplog:stop_instance(Id).

fused_instance_answers() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        origin => bondy_oplog_origin:new(),
        fused => true
    }),
    ?assertEqual(
        ok, bondy_oplog:append_applied(Id, {set, 1}, undefined, 5000)
    ),
    ok = refuse_every_event(),
    ?assertEqual(
        {error, rejected},
        bondy_oplog:append_applied(Id, {set, 2}, undefined, 5000)
    ),
    ok = meck:unload(?VALIDATOR),
    ok = bondy_oplog:stop_instance(Id).

instance_death_answers_at_once() ->
    %% The instance is suspended so its install cast is never processed:
    %% the appender's row stays pending. Killing the instance kills the
    %% overlay table with it, so no answer can ever come — the appender
    %% must learn that now, not at the 5 s deadline. Kill, not stop: the
    %% subtree's one_for_all restart is what production would see.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Instance = bondy_oplog_registry:instance_pid(Id),
    sys:suspend(Instance),
    Parent = self(),
    Appender = spawn_link(fun() ->
        Parent !
            {
                self(),
                timer:tc(fun() ->
                    bondy_oplog:append_applied(Id, doomed, undefined, 5000)
                end)
            }
    end),
    ok = wait_until_overlay_size(Id, 1),
    exit(Instance, kill),
    receive
        {Appender, {Micros, Result}} ->
            ?assertEqual({error, instance_unavailable}, Result),
            ?assert(Micros < 1_000_000, {took_us, Micros})
    after 7000 ->
        error(appender_waited_for_the_deadline)
    end,
    ok = wait_until_instance_restarted(Id, Instance),
    ok = bondy_oplog:stop_instance(Id).

batch_instance_death_answers_at_once() ->
    %% Same, with a batch whose barrier was taken before the append and
    %% whose first event may already have been answered: the death still
    %% ends the wait at once.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Instance = bondy_oplog_registry:instance_pid(Id),
    sys:suspend(Instance),
    Parent = self(),
    Appender = spawn_link(fun() ->
        Barrier = bondy_oplog:barrier(Id),
        Items = [{{item, N}, undefined} || N <- lists:seq(1, 3)],
        _Keys = bondy_oplog:append_many(Id, Items, Barrier),
        Parent !
            {
                self(),
                timer:tc(fun() ->
                    bondy_oplog:await_applied(Barrier, 3, 5000)
                end)
            }
    end),
    ok = wait_until_overlay_size(Id, 3),
    exit(Instance, kill),
    receive
        {Appender, {Micros, Result}} ->
            ?assertEqual({error, instance_unavailable}, Result),
            ?assert(Micros < 1_000_000, {took_us, Micros})
    after 7000 ->
        error(appender_waited_for_the_deadline)
    end,
    ok = wait_until_instance_restarted(Id, Instance),
    ok = bondy_oplog:stop_instance(Id).

%% =============================================================================
%% HELPERS
%% =============================================================================

mk_id() ->
    list_to_binary(
        "barrier_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

%% The trust validator (the instances' default) refuses every event on
%% replay; signing is untouched, so appends still succeed.
refuse_every_event() ->
    ok = meck:new(?VALIDATOR, [passthrough, no_link]),
    ok = meck:expect(?VALIDATOR, verify_event, fun(_Event, _State) ->
        {error, bad_signature}
    end),
    ok.

wait_until_overlay_empty(Id) ->
    wait_until_overlay_empty(Id, 500).

wait_until_overlay_empty(_Id, 0) ->
    exit(overlay_never_emptied);
wait_until_overlay_empty(Id, N) ->
    case ets:info(bondy_oplog_registry:overlay_tab(Id), size) of
        0 ->
            ok;
        _ ->
            timer:sleep(10),
            wait_until_overlay_empty(Id, N - 1)
    end.

wait_until_overlay_size(Id, Size) ->
    wait_until_overlay_size(Id, Size, 500).

wait_until_overlay_size(_Id, _Size, 0) ->
    exit(overlay_never_reached_size);
wait_until_overlay_size(Id, Size, N) ->
    Current =
        try
            ets:info(bondy_oplog_registry:overlay_tab(Id), size)
        catch
            error:badarg -> undefined
        end,
    case Current of
        Size ->
            ok;
        _ ->
            timer:sleep(10),
            wait_until_overlay_size(Id, Size, N - 1)
    end.

%% The subtree restarts the killed instance; wait for the new pid so the
%% case's `stop_instance` stops a live one.
wait_until_instance_restarted(Id, OldPid) ->
    wait_until_instance_restarted(Id, OldPid, 500).

wait_until_instance_restarted(_Id, _OldPid, 0) ->
    exit(instance_never_restarted);
wait_until_instance_restarted(Id, OldPid, N) ->
    case bondy_oplog_registry:instance_pid(Id) of
        Pid when is_pid(Pid), Pid =/= OldPid ->
            ok;
        _ ->
            timer:sleep(10),
            wait_until_instance_restarted(Id, OldPid, N - 1)
    end.

%% An answer for ANY alias that reached this process's mailbox.
stray_answer() ->
    receive
        {Alias, Reply} when is_reference(Alias) -> {stray, Reply}
    after 200 -> none
    end.

%% An overlay row the applier will never evict: a key it never sees.
fake_overlay_row(N) ->
    Hlc = 1000 + N,
    Origin = <<0:128>>,
    Key = #bondy_oplog_event_key{hlc = Hlc, origin = Origin, seq = N},
    Value = {fake_op, fake_meta, undefined, undefined},
    {Key, Value, Hlc, local, undefined}.
