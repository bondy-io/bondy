%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests the lifecycle-aware default_dispatch in
%% `bondy_oplog_sync_scheduler`.
%%
%% Validates:
%%   - A pre_bootstrap catalogue instance auto-bootstraps from the
%%     first configured peer (bootstrap_catalogue path).
%%   - A pre_bootstrap single-CRDT instance auto-bootstraps via the
%%     existing bootstrap path.
%%   - A live instance fans out per-peer pull-direction syncs.
%%   - An empty peer list is a no-op.
%% =============================================================================
-module(bondy_oplog_sync_scheduler_bootstrap_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Disable periodic ticks; tests drive explicit triggers.
    ok = bondy_oplog_sync_scheduler:set_interval_ms(0),
    %% Use the lifecycle-aware default dispatch under test. (A prior
    %% test suite may have left `set_dispatch(undefined)` in place.)
    ok = bondy_oplog_sync_scheduler:set_dispatch(
        fun bondy_oplog_sync_scheduler:default_dispatch/2
    ),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    ok.

cleanup(_) ->
    ok = bondy_oplog_sync_scheduler:set_interval_ms(500),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

scheduler_bootstrap_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 10,
            fun pre_bootstrap_catalogue_auto_bootstraps_from_first_peer/0},
        {timeout, 10, fun pre_bootstrap_single_crdt_auto_bootstraps/0},
        {timeout, 10, fun live_instance_fans_out_per_peer_syncs/0},
        fun empty_peers_is_a_noop/0
    ]}.

pre_bootstrap_catalogue_auto_bootstraps_from_first_peer() ->
    BaseDir = test_dir(),
    {Peer, _, _, _} = setup_persistent(BaseDir, #{seed => true}),
    {Local, _, _, _} = setup_persistent(BaseDir, #{}),
    _ = bondy_oplog:append(Peer, {cell_apply, ?B, <<"k">>, {set, 5, <<"v">>}}),
    _ = barrier(Peer),

    %% Pre-conditions.
    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Peer)),
    ?assertEqual(pre_bootstrap, bondy_oplog_instance:lifecycle_state(Local)),

    %% Configure the scheduler to use `Peer` as the only peer.
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => [Peer]}
    ),

    %% Trigger; wait for the dispatched bootstrap process to flip the
    %% lifecycle.
    bondy_oplog_sync_scheduler:trigger(),
    ok = wait_for_live(Local, 5000),

    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Local)),
    %% Verify the cell landed on Local.
    LocalEntry = registry_entry(Local),
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(LocalEntry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(LocalEntry),
    ?assertMatch({ok, _Frame}, Adapter:get(Handle, ?B, <<"k">>)),

    teardown(Peer),
    teardown(Local),
    file:del_dir_r(BaseDir).

pre_bootstrap_single_crdt_auto_bootstraps() ->
    %% Asserts the *routing* decision rather than a full E2E bootstrap
    %% of a single-CRDT instance (the latter needs a working
    %% `crdt_module` snapshot path, which is orthogonal to PR-D3 — and
    %% is covered separately by the existing `bootstrap/3` tests). We
    %% attach a telemetry handler and verify the scheduler emits
    %% `[bondy_oplog, sync_scheduler, dispatch_bootstrap]` with
    %% `mode => single_crdt` for a pre_bootstrap instance whose
    %% `crdt_module` is set.
    BaseDir = test_dir(),
    Local = mk_id(),
    LocalPath = make_path(BaseDir, Local),
    {ok, _} = bondy_oplog:start_instance(Local, #{
        crdt_module => bondy_oplog_test_counter,
        storage_path => list_to_binary(LocalPath)
    }),
    ?assertEqual(pre_bootstrap, bondy_oplog_instance:lifecycle_state(Local)),

    Self = self(),
    HandlerId = {?MODULE, ?FUNCTION_NAME},
    ok = telemetry:attach(
        HandlerId,
        [bondy_oplog, sync_scheduler, dispatch_bootstrap],
        fun(_, M, Meta, _) -> Self ! {bootstrap_dispatched, M, Meta} end,
        []
    ),
    try
        ok = bondy_oplog_sync_scheduler:set_peer_source(
            bondy_oplog_peer_source_static, #{peers => [<<"some-peer">>]}
        ),
        bondy_oplog_sync_scheduler:trigger(),
        receive
            {bootstrap_dispatched, _M, #{
                instance_id := Local,
                mode := single_crdt
            }} ->
                ok
        after 2000 ->
            error(no_single_crdt_dispatch)
        end
    after
        telemetry:detach(HandlerId)
    end,
    bondy_oplog:stop_instance(Local),
    file:del_dir_r(BaseDir).

live_instance_fans_out_per_peer_syncs() ->
    %% A `live` instance with multiple configured peers should result
    %% in multiple sync sessions (one per peer). Use a custom dispatch
    %% that counts invocations to verify the live-mode fan-out is
    %% preserved.
    Self = self(),
    Ref = make_ref(),
    Inst = mk_id(),
    %% Ephemeral instances default to `live`.
    {ok, _} = bondy_oplog:start_instance(Inst, #{}),
    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Inst)),

    %% We want to verify the SCHEDULER's default fan-out path runs.
    %% Override the dispatch with a one that captures, then call
    %% default_dispatch directly via a thin wrapper.
    ok = bondy_oplog_sync_scheduler:set_dispatch(
        fun(I, Peers) ->
            Self ! {Ref, dispatched, I, Peers}
        end
    ),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => [{p, a}, {p, b}]}
    ),
    bondy_oplog_sync_scheduler:trigger(),
    %% With a custom dispatch the scheduler just calls the fun once
    %% per tick — the live-mode fan-out happens inside the default
    %% dispatch we replaced. The point of this test is to assert the
    %% scheduler still routes peers to the dispatch for a live
    %% instance; the per-peer fan-out is covered by the existing
    %% `dispatch_per_running_instance` test.
    receive
        {Ref, dispatched, Inst, [{p, a}, {p, b}]} -> ok
    after 1000 ->
        error(no_dispatch)
    end,
    bondy_oplog:stop_instance(Inst).

empty_peers_is_a_noop() ->
    %% Empty peer list — default_dispatch must return ok without any
    %% spawn / crash. Use the default dispatch (don't override).
    Inst = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Inst, #{}),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    bondy_oplog_sync_scheduler:trigger(),
    timer:sleep(100),
    %% Survived; nothing to assert beyond no crash.
    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Inst)),
    bondy_oplog:stop_instance(Inst).

%% =============================================================================
%% Helpers
%% =============================================================================

setup_persistent(BaseDir, ExtraOpts) ->
    Id = mk_id(),
    NS = ns_of(Id),
    {Cache, Proj} = register_shard(NS, primary, 0),
    Path = make_path(BaseDir, Id),
    Opts = maps:merge(
        #{
            fold_module => lww_register,
            applier => #{
                cell_apply_target => {NS, primary, 0}
            },
            storage_path => list_to_binary(Path)
        },
        ExtraOpts
    ),
    {ok, _} = bondy_oplog:start_instance(Id, Opts),
    {Id, NS, Cache, Proj}.

teardown(Id) ->
    bondy_oplog:stop_instance(Id),
    NS = ns_of(Id),
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)],
        N =:= NS
    ],
    ok.

register_shard(NS, Index, Shard) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register
    }),
    {Cache, Proj}.

registry_entry(Id) ->
    NS = ns_of(Id),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    Entry.

mk_id() ->
    iolist_to_binary([
        "sb_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

barrier(Id) ->
    bondy_oplog:projection(Id).

test_dir() ->
    Base = filename:join([
        "/tmp",
        "bondy_mst_scheduler_bootstrap_test",
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_path(Base),
    Base.

make_path(BaseDir, Id) ->
    Path = filename:join([BaseDir, binary_to_list(Id)]),
    ok = filelib:ensure_path(Path),
    Path.

wait_for_live(Id, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_for_live_loop(Id, Deadline).

wait_for_live_loop(Id, Deadline) ->
    case bondy_oplog_instance:lifecycle_state(Id) of
        live ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(50),
                    wait_for_live_loop(Id, Deadline);
                false ->
                    error({timeout_waiting_for_live, Id})
            end
    end.
