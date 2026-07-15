%% End-to-end integration test exercising the per-instance subtree
%% (`bondy_oplog_instance` + `bondy_oplog_wal` + `bondy_oplog_applier`).
%% A local `append` now writes to the WAL, the applier reads it back
%% and installs it in the MST, and `get` returns it through the
%% registry-published MST handle.
%%
%% The crash scenarios are the supervision-flavour ones from the
%% implementation plan:
%%
%% - kill the applier mid-replay; the subtree's one_for_all restart
%%   brings everything back and the same events become readable again.
%% - kill the WAL writer; the subtree restarts, recovery runs, the
%%   applier resumes from the committed offset and the surviving
%%   events stay readable.

-module(bondy_oplog_e2e_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

e2e_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun append_visible_via_get/0},
        {timeout, 30, fun append_many_atomic_visible/0},
        {timeout, 30, fun applier_crash_recovers/0},
        {timeout, 30, fun wal_crash_restarts_subtree/0}
    ]}.

%% Local append → WAL → applier → MST → readable.
append_visible_via_get() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    K = bondy_oplog:append(Id, {hello, world}),
    {ok, Event} = bondy_oplog:get(Id, K),
    ?assertEqual(K, bondy_oplog_event:key(Event)),
    ?assertEqual({hello, world}, bondy_oplog_event:op(Event)),
    ok = bondy_oplog:stop_instance(Id).

%% A batched local append is atomic end-to-end: every key the caller
%% receives is observable via get.
append_many_atomic_visible() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Items = [{op_a, undefined}, {op_b, undefined}, {op_c, undefined}],
    Keys = bondy_oplog:append_many(Id, Items),
    [?assertMatch({ok, _}, bondy_oplog:get(Id, K)) || K <- Keys],
    ?assertEqual(3, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

%% Killing the applier triggers a one_for_all restart of the subtree.
%% After restart the WAL is recovered, the applier replays from the
%% last committed offset and the events the caller observed before
%% the kill remain observable.
applier_crash_recovers() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Keys = [bondy_oplog:append(Id, {n, N}) || N <- lists:seq(1, 10)],
    ApplierPid = bondy_oplog_registry:applier_pid(Id),
    ?assert(is_pid(ApplierPid)),
    exit(ApplierPid, kill),
    ok = wait_until(
        fun() ->
            P = bondy_oplog_registry:applier_pid(Id),
            is_pid(P) andalso P =/= ApplierPid
        end,
        5000
    ),
    [?assertMatch({ok, _}, bondy_oplog:get(Id, K)) || K <- Keys],
    ?assertEqual(length(Keys), bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

%% Killing the WAL writer drags the whole subtree down. Recovery rebuilds
%% the head segment from disk, the applier resumes from the persisted
%% consumer.offset, and previously durable events stay observable
%% (provided the MST backend or the WAL itself preserved them — the
%% default `ets` MST backend is volatile across instance restarts, so
%% the applier must replay from the consumer offset to repopulate it).
wal_crash_restarts_subtree() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Keys = [bondy_oplog:append(Id, {n, N}) || N <- lists:seq(1, 10)],
    WalPid = bondy_oplog_registry:wal_pid(Id),
    ?assert(is_pid(WalPid)),
    exit(WalPid, kill),
    ok = wait_until(
        fun() ->
            P = bondy_oplog_registry:wal_pid(Id),
            is_pid(P) andalso P =/= WalPid andalso
                bondy_oplog:size(Id) =:= length(Keys)
        end,
        10000
    ),
    [?assertMatch({ok, _}, bondy_oplog:get(Id, K)) || K <- Keys],
    ok = bondy_oplog:stop_instance(Id).

%% =============================================================================
%% HELPERS
%% =============================================================================

mk_id() ->
    list_to_binary(
        "e2e_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

wait_until(Pred, TimeoutMs) ->
    wait_until(Pred, TimeoutMs, 10).

wait_until(Pred, Remaining, _StepMs) when Remaining =< 0 ->
    case Pred() of
        true -> ok;
        false -> {error, timeout}
    end;
wait_until(Pred, Remaining, StepMs) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(StepMs),
            wait_until(Pred, Remaining - StepMs, StepMs)
    end.
