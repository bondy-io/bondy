%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rib_reclamation_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

%% Does a DEPARTED node's registry RIB state actually go away on the
%% survivors?
%%
%% A RIB cell is single-writer — its key carries the owner's nodestring — so
%% only the owner can drive its `count` to the `stabilize_zero` that makes it
%% reclaimable, and a node that is gone never will. `bondy_registry_rib`'s
%% "Departure" section states the consequence; this suite is what decides
%% whether the reclamation path actually closes it, end to end, over a real
%% cluster and a real membership act (`partisan_peer_service:leave/1`).
%%
%% It asserts BOTH artifacts for BOTH registry types, separately, so that
%% neither can mask the other:
%%
%%   - the replicated cell in the survivor's projection, and
%%   - the derived stub row the routing read paths actually consult.
%%
%% Each case gets its own cluster (not `bondy_reclamation_cluster_SUITE`'s)
%% because retiring a member is exclusive: two tests cannot both spend it. The
%% cluster has three nodes so the survivors stay a cluster: a sole member with
%% clustering enabled confirms nothing. Node names differ per case so a case
%% never boots on the data dir a previous case's departed node left behind.

-define(REALM, <<"com.bondy.rib_reclaim">>).
-define(PROC, <<"com.example.rib_reclaim.proc">>).
-define(TOPIC, <<"com.example.rib_reclaim.topic">>).
-define(POLICY, <<"exact">>).
-define(CONVERGE_MS, 120000).

all() ->
    [
        departed_node_rib_state_is_reclaimed,
        departed_node_rib_state_is_reclaimed_after_compaction
    ].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_testcase(Case, Config) ->
    Nodes = bondy_ct:start_cluster(node_names(Case), Config),
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Nodes],
    %% Scheduler-driven compaction is frozen so that each case decides
    %% whether the registry MST is compacted before the node departs: the
    %% first case never compacts, the second compacts explicitly.
    _ = [bondy_ct:freeze_gc(Node) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_testcase(_Case, Config) ->
    ok = bondy_ct:stop_cluster(?config(cluster, Config)),
    Config.

node_names(departed_node_rib_state_is_reclaimed) ->
    [rribrec1, rribrec2, rribrec3];
node_names(departed_node_rib_state_is_reclaimed_after_compaction) ->
    [rribcmp1, rribcmp2, rribcmp3].

%% =============================================================================
%% TESTS
%% =============================================================================

departed_node_rib_state_is_reclaimed(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    {_, N2, Peer2} = lists:keyfind(N2, 2, ?config(cluster, Config)),
    N2Str = seed_owner_cells(N1, N2),

    %% N2 departs for good and is retired — the deliberate, replicated
    %% membership act that licenses reclamation.
    ok = peer:stop(Peer2),
    assert_reclaimed(N1, N2Str).

%% The same departure after the survivor has compacted its registry MSTs,
%% the state a long-running cluster is in: the compaction cluster suite
%% locks registry history to drain to quiescent. It holds only if the
%% directory the reap and the stability sweep enumerate outlives the MST
%% events compaction removes (`CellContextReap.tla`, `DirectoryComplete`).
departed_node_rib_state_is_reclaimed_after_compaction(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    {_, N2, Peer2} = lists:keyfind(N2, 2, ?config(cluster, Config)),
    N2Str = seed_owner_cells(N1, N2),

    %% Precondition: compaction has removed the seeded cells from the MST
    %% directory on the survivor while the projection still holds them.
    ok = wait_directory_empty(N1, N2Str),
    [
        ?assert(count_of(cell_value(N1, T, U, N2Str)) > 0)
     || {T, U} <- rib_cells()
    ],
    ct:pal("compacted: ~p", [rib_state(N1, N2Str)]),

    ok = peer:stop(Peer2),
    assert_reclaimed(N1, N2Str).

%% @private
%% N2 owns one registration and one subscription; returns N2's nodestring.
%% All four artifacts must be present on the survivor before the case goes
%% on: without that precondition the case proves nothing about reclamation.
seed_owner_cells(N1, N2) ->
    ok = erpc:call(N1, ?MODULE, do_create_realm, [?REALM]),
    ok = erpc:call(N2, ?MODULE, do_create_realm, [?REALM]),
    ok = erpc:call(N2, ?MODULE, do_add_registration, [?REALM, ?PROC]),
    ok = erpc:call(N2, ?MODULE, do_add_subscription, [?REALM, ?TOPIC]),
    N2Str = erpc:call(N2, bondy_config, nodestring, []),
    ok = wait_state(N1, N2Str, #{
        reg_cell => true,
        reg_stub => true,
        sub_cell => true,
        sub_stub => true
    }),
    ct:pal("seeded: ~p", [rib_state(N1, N2Str)]),
    [
        ?assert(count_of(cell_value(N1, T, U, N2Str)) > 0)
     || {T, U} <- rib_cells()
    ],
    N2Str.

%% @private
%% Retires the (stopped) N2 on N1, drives the passes synchronously rather
%% than waiting on their timers, and asserts all four artifacts are gone.
assert_reclaimed(N1, N2Str) ->
    ok = erpc:call(N1, ?MODULE, do_retire, [node_of(N1, N2Str)]),
    Report = erpc:call(N1, ?MODULE, do_run_retirement, []),
    ct:pal("retirement pass: ~p", [Report]),
    Reclaimed = erpc:call(N1, ?MODULE, do_reclaim_all, []),
    ct:pal("reclaim pass: ~p", [Reclaimed]),

    Final = wait_all_gone(N1, N2Str),
    ct:pal("post-retirement RIB state on ~p: ~p", [N1, Final]),

    %% Only on failure: the reap declining a cell it scanned is the hard case
    %% to diagnose after the fact, and the cluster is gone once the suite ends.
    Final =:=
        #{
            reg_cell => false,
            reg_stub => false,
            sub_cell => false,
            sub_stub => false
        } orelse
        ct:pal(
            "DIAGNOSTIC: ~p", [erpc:call(N1, ?MODULE, do_diagnose, [N2Str])]
        ),

    #{
        reg_cell := RegCell,
        reg_stub := RegStub,
        sub_cell := SubCell,
        sub_stub := SubStub
    } = Final,
    ?assertEqual(false, RegCell, "registration cell survived retirement"),
    ?assertEqual(false, RegStub, "registration stub survived retirement"),
    ?assertEqual(false, SubCell, "subscription cell survived retirement"),
    ?assertEqual(false, SubStub, "subscription stub survived retirement"),
    ok.

%% =============================================================================
%% CONTROLLER HELPERS
%% =============================================================================

%% @private
nodes_of(Config) ->
    [Node || {_, Node, _} <- ?config(cluster, Config)].

%% @private
node_of(Node, NodeStr) ->
    erpc:call(Node, erlang, list_to_atom, [binary_to_list(NodeStr)]).

%% @private
%% Compacts every registry instance on `Node` until the MST directory there
%% lists neither seeded cell, or fails naming what the directory still held
%% and what the last compaction round answered.
wait_directory_empty(Node, Owner) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_directory_empty(Node, Owner, Deadline).

wait_directory_empty(Node, Owner, Deadline) ->
    Rounds = erpc:call(Node, ?MODULE, do_compact_registry, []),
    case erpc:call(Node, ?MODULE, do_mst_directory_for, [Owner]) of
        [] ->
            ok;
        Held ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    ct:fail(
                        {registry_mst_not_compacted, #{
                            directory => Held, compaction => Rounds
                        }}
                    );
                false ->
                    timer:sleep(1000),
                    wait_directory_empty(Node, Owner, Deadline)
            end
    end.

%% @private
push_module(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

%% @private
rib_cells() ->
    [{bondy_rib_registrations, ?PROC}, {bondy_rib_subscriptions, ?TOPIC}].

%% @private
cell_value(Node, Table, Uri, Owner) ->
    erpc:call(Node, ?MODULE, do_read_cell, [Table, Uri, Owner]).

%% @private
%% A registration cell's value is a struct with a `count` field; a
%% subscription cell's value is the count itself.
count_of({ok, {#{count := C}, _}}) when is_integer(C) -> C;
count_of({ok, {C, _}}) when is_integer(C) -> C.

%% @private
rib_state(Node, Owner) ->
    erpc:call(Node, ?MODULE, do_rib_state, [Owner]).

%% @private
%% Polls until the survivor's view matches `Expected`, so a slow AAE hop is a
%% wait rather than a flake. Returns `ok`, or fails the test with the last
%% observed state so a mismatch names what actually differed.
wait_state(Node, Owner, Expected) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_state(Node, Owner, Expected, Deadline).

wait_state(Node, Owner, Expected, Deadline) ->
    case rib_state(Node, Owner) of
        Expected ->
            ok;
        Other ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    ct:fail(
                        {rib_state_mismatch, #{
                            expected => Expected, actual => Other
                        }}
                    );
                false ->
                    timer:sleep(500),
                    wait_state(Node, Owner, Expected, Deadline)
            end
    end.

%% @private
%% Polls until every artifact is gone, returning the LAST observed state
%% either way — reclamation may need more than one pass, and on failure the
%% caller asserts per artifact so the report names which ones survived.
wait_all_gone(Node, Owner) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_all_gone(Node, Owner, Deadline).

wait_all_gone(Node, Owner, Deadline) ->
    All = #{
        reg_cell => false,
        reg_stub => false,
        sub_cell => false,
        sub_stub => false
    },
    case rib_state(Node, Owner) of
        All ->
            All;
        Other ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    Other;
                false ->
                    timer:sleep(1000),
                    _ = erpc:call(Node, ?MODULE, do_reclaim_all, []),
                    _ = erpc:call(Node, ?MODULE, do_rib_check, []),
                    wait_all_gone(Node, Owner, Deadline)
            end
    end.

%% =============================================================================
%% PEER-SIDE HELPERS (run ON the cluster nodes)
%% =============================================================================

%% @private
%% Tolerant of `already_exists`: the realm is created on both nodes, and AAE
%% may well have replicated the first create before the second runs.
do_create_realm(Uri) ->
    try
        _ = bondy_realm:create(Uri),
        ok
    catch
        error:{already_exists, _} -> ok
    end.

%% @private
do_add_registration(Uri, Proc) ->
    Ref = bondy_ref:new(internal, {bondy_wamp_api, resolve}),
    Opts = #{match => ?POLICY, invoke => <<"single">>},
    case bondy_registry:add(registration, Uri, Proc, Opts, Ref) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> error({registration_add_failed, Other})
    end.

%% @private
do_add_subscription(Uri, Topic) ->
    Ref = bondy_ref:new(internal, {bondy_wamp_api, resolve}),
    case bondy_registry:add(subscription, Uri, Topic, #{}, Ref) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> error({subscription_add_failed, Other})
    end.

%% @private
%% The four artifacts, read on this node, for cells owned by `Owner`.
do_rib_state(Owner) ->
    #{
        reg_cell => has_cell(bondy_rib_registrations, ?PROC, Owner),
        reg_stub => has_stub(registration, ?PROC, Owner),
        sub_cell => has_cell(bondy_rib_subscriptions, ?TOPIC, Owner),
        sub_stub => has_stub(subscription, ?TOPIC, Owner)
    }.

%% @private
has_cell(Table, Uri, Owner) ->
    case do_read_cell(Table, Uri, Owner) of
        {ok, _} -> true;
        _ -> false
    end.

%% @private
do_read_cell(Table, Uri, Owner) ->
    Key = term_to_binary({?REALM, ?POLICY, Uri, Owner}),
    bondy_db:read(bondy_namespace_catalog:table(Table), ?REALM, Key).

%% @private
has_stub(Type, Uri, Owner) ->
    Stubs = bondy_registry_rib:stub_nodes(Type, ?REALM, ?POLICY, Uri),
    lists:keymember(Owner, 1, Stubs).

%% @private
%% One compaction cycle per registry instance, as the GC scheduler's default
%% trigger runs it.
do_compact_registry() ->
    [
        {I, bondy_oplog_compaction:compact(I)}
     || <<"registry-", _/binary>> = I <- bondy_oplog:list_instances()
    ].

%% @private
%% The `cell_apply` entries still in any registry instance's MST for the
%% cells `Owner` wrote: what `bondy_oplog_cell_utils:primary_cell_directory/4`
%% enumerates for the ephemeral ETS adapter. A storage key is the raw cell
%% key, realm-prefixed under a realm-folding topology, so match on suffix.
do_mst_directory_for(Owner) ->
    Raws = [
        term_to_binary({?REALM, ?POLICY, Uri, Owner})
     || {_, Uri} <- rib_cells()
    ],
    [
        {I, Bucket}
     || <<"registry-", _/binary>> = I <- bondy_oplog:list_instances(),
        MST <- [bondy_oplog_registry:mst(I)],
        MST =/= undefined,
        {_, {{cell_apply, Bucket, Key, _}, _, _, _}} <- bondy_mst:to_list(MST),
        is_binary(Key),
        lists:any(
            fun(Raw) ->
                binary:longest_common_suffix([Key, Raw]) =:= byte_size(Raw)
            end,
            Raws
        )
    ].

%% @private
%% Retirement: remove the (dead) node from the Partisan membership.
do_retire(Node) ->
    Specs =
        case partisan_peer_service:members_for_orchestration() of
            {ok, L} when is_list(L) -> L;
            L when is_list(L) -> L
        end,
    case [S || #{name := N} = S <- Specs, N =:= Node] of
        [Spec | _] -> partisan_peer_service:leave(Spec);
        [] -> error({not_a_member, Node})
    end.

%% @private
do_run_retirement() ->
    #{
        enabled => bondy_oplog_config:origin_retirement_enabled(),
        run =>
            try
                bondy_oplog_origin_retirement:run()
            catch
                C:R -> {'EXIT', {C, R}}
            end
    }.

%% @private
do_reclaim_all() ->
    [
        {I,
            try
                bondy_oplog_instance:reclaim_stable_cells(I)
            catch
                C:R -> {'EXIT', {C, R}}
            end}
     || I <- bondy_oplog:list_instances()
    ].

%% @private
%% Why did the reap not fire? Reports, for the registration RIB cell owned by
%% `Owner`: the origins its stored state actually carries, the dead set this
%% node computes, and a DIRECT per-instance reap report (which carries
%% `supported` and `cells_scanned`, both of which `reap_instance/2` discards).
do_diagnose(Owner) ->
    Dead = dead_origins(),
    Cell =
        try
            do_read_cell(bondy_rib_registrations, ?PROC, Owner)
        catch
            C0:R0 -> {'EXIT', {C0, R0}}
        end,
    Reports = [
        {I,
            try
                bondy_oplog_instance:reap_origins(I, Dead)
            catch
                C:R -> {'EXIT', {C, R}}
            end}
     || I <- bondy_oplog:list_instances()
    ],
    #{
        dead => Dead,
        dead_count => length(Dead),
        cell => Cell,
        reap_reports => [
            {I, Rep}
         || {I, Rep} <- Reports,
            case Rep of
                {ok, #{cells_scanned := N}} when N > 0 -> true;
                {ok, #{supported := true}} -> true;
                _ -> false
            end
        ],
        unsupported => [
            I
         || {I, {ok, #{supported := false}}} <- Reports
        ],
        %% For every instance that actually SCANNED a cell: does its applied
        %% frontier carry any of the origins we just declared dead? If yes,
        %% the writer IS known dead and present here, and the decline happens
        %% inside `reap_one_cell/6`. If no, the dead set never named the
        %% cell's writer and the fault is upstream.
        scanned_frontiers => [
            {I, #{
                frontier => maps:keys(bondy_oplog_instance:frontier(I)),
                dead_here =>
                    [
                        O
                     || O <- Dead,
                        is_map_key(O, bondy_oplog_instance:frontier(I))
                    ]
            }}
         || {I, {ok, #{cells_scanned := N}}} <- Reports, N > 0
        ]
    }.

%% @private
dead_origins() ->
    Frontier = lists:usort(
        lists:append([
            maps:keys(bondy_oplog_instance:frontier(I))
         || I <- bondy_oplog:list_instances()
        ])
    ),
    Own = bondy_oplog_origin_retirement:local_origins(),
    [O || O <- Frontier, not lists:member(O, Own)].

%% @private
%% Drive the registry's periodic RIB sweep NOW rather than waiting out
%% `registry_rib_check_interval` (5 minutes). Sent as the real `rib_check`
%% message so the test exercises the production handler and its wiring, not
%% just `reap_orphan_stubs/1` in isolation.
do_rib_check() ->
    bondy_registry ! rib_check,
    timer:sleep(250),
    ok.
