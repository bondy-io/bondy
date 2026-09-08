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
%% Its own cluster (not `bondy_reclamation_cluster_SUITE`'s) because retiring
%% the only peer is exclusive: two tests cannot both spend it.

-define(NODE_NAMES, [rribrec1, rribrec2]).
-define(REALM, <<"com.bondy.rib_reclaim">>).
-define(PROC, <<"com.example.rib_reclaim.proc">>).
-define(TOPIC, <<"com.example.rib_reclaim.topic">>).
-define(POLICY, <<"exact">>).
-define(CONVERGE_MS, 120000).

all() ->
    [departed_node_rib_state_is_reclaimed].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Nodes],
    %% Scheduler-driven GC (compaction) is frozen suite-wide, as in
    %% `bondy_reclamation_cluster_SUITE`. The reap enumerates cells through
    %% `bondy_oplog_cell_utils:primary_cell_directory/4`, which for the
    %% ephemeral ETS adapter falls back to the TRUNCATABLE MST `cell_apply`
    %% directory — so a compaction inside the test window empties the very
    %% directory the reap walks, and the pass reports `cells_scanned => 0`
    %% for reasons that have nothing to do with what is being tested.
    _ = [bondy_ct:freeze_gc(Node) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(cluster, Config)),
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

departed_node_rib_state_is_reclaimed(Config) ->
    [N1, N2] = nodes_of(Config),
    {_, N2, Peer2} = lists:keyfind(N2, 2, ?config(cluster, Config)),

    ok = erpc:call(N1, ?MODULE, do_create_realm, [?REALM]),

    %% N2 owns one registration and one subscription.
    ok = erpc:call(N2, ?MODULE, do_create_realm, [?REALM]),
    ok = erpc:call(N2, ?MODULE, do_add_registration, [?REALM, ?PROC]),
    ok = erpc:call(N2, ?MODULE, do_add_subscription, [?REALM, ?TOPIC]),
    N2Str = erpc:call(N2, bondy_config, nodestring, []),

    %% Precondition: all four artifacts are present on the survivor. If this
    %% does not hold the test proves nothing about reclamation, so it is an
    %% assertion, not a wait-and-hope.
    ok = wait_state(N1, N2Str, #{
        reg_cell => true,
        reg_stub => true,
        sub_cell => true,
        sub_stub => true
    }),
    ct:pal("seeded: ~p", [rib_state(N1, N2Str)]),

    %% N2 departs for good and is retired — the deliberate, replicated
    %% membership act that licenses reclamation.
    ok = peer:stop(Peer2),
    ok = erpc:call(N1, ?MODULE, do_retire, [N2]),

    %% Drive the passes synchronously rather than waiting on their timers.
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
push_module(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

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
        reg_cell => has_cell(bondy_registration_rib, ?PROC, Owner),
        reg_stub => has_stub(registration, ?PROC, Owner),
        sub_cell => has_cell(bondy_subscription_rib, ?TOPIC, Owner),
        sub_stub => has_stub(subscription, ?TOPIC, Owner)
    }.

%% @private
has_cell(Table0, Uri, Owner) ->
    Table = bondy_namespace_catalog:table(Table0),
    Key = term_to_binary({?REALM, ?POLICY, Uri, Owner}),
    case bondy_db:read(Table, ?REALM, Key) of
        {ok, _} -> true;
        _ -> false
    end.

%% @private
has_stub(Type, Uri, Owner) ->
    Stubs = bondy_registry_rib:stub_nodes(Type, ?REALM, ?POLICY, Uri),
    lists:keymember(Owner, 1, Stubs).

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
    Table = bondy_namespace_catalog:table(bondy_registration_rib),
    Key = term_to_binary({?REALM, ?POLICY, ?PROC, Owner}),
    Cell =
        try
            bondy_db:read(Table, ?REALM, Key)
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
