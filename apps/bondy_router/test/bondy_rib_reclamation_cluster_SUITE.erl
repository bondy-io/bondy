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
-define(POLICY, <<"exact">>).
-define(CONVERGE_MS, 120000).
-define(SWEEP_EVENT, [bondy_oplog, applier, cells_swept]).

all() ->
    [
        departed_node_rib_state_is_reclaimed,
        departed_node_rib_state_is_reclaimed_after_compaction,
        departed_node_rib_state_is_reclaimed_in_single_cell_sweeps
    ].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_testcase(Case, Config) ->
    Nodes = bondy_ct:start_cluster(node_names(Case), Config),
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Nodes],
    %% Scheduler-driven compaction is frozen so that each case decides
    %% whether the registry MST is compacted before the node departs: the
    %% first case never compacts, the others compact explicitly.
    _ = [bondy_ct:freeze_gc(Node) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_testcase(_Case, Config) ->
    ok = bondy_ct:stop_cluster(?config(cluster, Config)),
    Config.

node_names(departed_node_rib_state_is_reclaimed) ->
    [rribrec1, rribrec2, rribrec3];
node_names(departed_node_rib_state_is_reclaimed_after_compaction) ->
    [rribcmp1, rribcmp2, rribcmp3];
node_names(departed_node_rib_state_is_reclaimed_in_single_cell_sweeps) ->
    [rribpag1, rribpag2, rribpag3].

%% =============================================================================
%% TESTS
%% =============================================================================

departed_node_rib_state_is_reclaimed(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    {_, N2, Peer2} = lists:keyfind(N2, 2, ?config(cluster, Config)),
    Cells = cells(1),
    N2Str = seed_owner_cells(N1, N2, Cells),

    %% N2 departs for good and is retired — the deliberate, replicated
    %% membership act that licenses reclamation.
    ok = peer:stop(Peer2),
    assert_reclaimed(N1, N2Str, Cells).

%% The same departure after the survivor has compacted its registry MSTs,
%% the state a long-running cluster is in: the compaction cluster suite
%% locks registry history to drain to quiescent. It holds only if the
%% directory the reap and the stability sweep enumerate outlives the MST
%% events compaction removes (`CellContextReap.tla`, `DirectoryComplete`).
departed_node_rib_state_is_reclaimed_after_compaction(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    {_, N2, Peer2} = lists:keyfind(N2, 2, ?config(cluster, Config)),
    Cells = cells(1),
    N2Str = seed_owner_cells(N1, N2, Cells),

    %% Precondition: compaction has removed the seeded cells from the MST
    %% directory on the survivor while the projection still holds them.
    ok = wait_directory_empty(N1, N2Str, Cells),
    assert_cells_held(N1, N2Str, Cells),
    ct:pal("compacted: ~p", [rib_state(N1, N2Str, Cells)]),

    ok = peer:stop(Peer2),
    assert_reclaimed(N1, N2Str, Cells).

%% The stability sweep pages through the compacted directory one cell per
%% batch (`reclaim_batch_cells` = 1, each batch resumed from the cursor the
%% previous one returned), so a cursor that skipped a cell shows as a sweep
%% that scanned fewer cells than seeded, and a page cut past the budget as a
%% batch that scanned more than one. The departure then has to reclaim every
%% seeded cell through the same paged sweep.
departed_node_rib_state_is_reclaimed_in_single_cell_sweeps(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    {_, N2, Peer2} = lists:keyfind(N2, 2, ?config(cluster, Config)),
    Cells = cells(4),
    N2Str = seed_owner_cells(N1, N2, Cells),
    ok = wait_directory_empty(N1, N2Str, Cells),
    assert_cells_held(N1, N2Str, Cells),

    ok = erpc:call(
        N1, application, set_env, [bondy_oplog, reclaim_batch_cells, 1]
    ),
    ok = erpc:call(N1, ?MODULE, do_count_sweeps, []),
    Swept = erpc:call(N1, ?MODULE, do_reclaim_all, []),
    ct:pal("single-cell sweep: ~p", [Swept]),
    {Batches, Scanned} = erpc:call(N1, ?MODULE, do_sweep_counts, []),
    ct:pal("sweep batches: ~p, cells scanned: ~p", [Batches, Scanned]),
    ?assert(Scanned >= length(Cells), "the paged sweep skipped a cell"),
    ?assert(Scanned =< Batches, "a batch swept more than one cell"),
    assert_cells_held(N1, N2Str, Cells),

    ok = peer:stop(Peer2),
    assert_reclaimed(N1, N2Str, Cells).

%% =============================================================================
%% CONTROLLER HELPERS
%% =============================================================================

%% @private
%% `N` registrations and `N` subscriptions, each a distinct URI.
cells(N) ->
    lists:append([
        [
            {registration, uri("proc", I)},
            {subscription, uri("topic", I)}
        ]
     || I <- lists:seq(1, N)
    ]).

%% @private
uri(Kind, I) ->
    iolist_to_binary(["com.example.rib_reclaim.", Kind, ".", integer_to_list(I)]).

%% @private
%% Every artifact of `Cells` present (`true`) or absent (`false`).
artifacts(Cells, Present) ->
    maps:from_list([
        {{Artifact, Type, Uri}, Present}
     || {Type, Uri} <- Cells, Artifact <- [cell, stub]
    ]).

%% @private
%% N2 owns every cell; returns N2's nodestring. Every artifact must be
%% present on the survivor before the case goes on: without that
%% precondition the case proves nothing about reclamation.
seed_owner_cells(N1, N2, Cells) ->
    ok = erpc:call(N1, ?MODULE, do_create_realm, [?REALM]),
    ok = erpc:call(N2, ?MODULE, do_create_realm, [?REALM]),
    _ = [
        ok = erpc:call(N2, ?MODULE, do_add, [Type, Uri])
     || {Type, Uri} <- Cells
    ],
    N2Str = erpc:call(N2, bondy_config, nodestring, []),
    ok = wait_state(N1, N2Str, Cells, artifacts(Cells, true)),
    ct:pal("seeded: ~p", [rib_state(N1, N2Str, Cells)]),
    assert_cells_held(N1, N2Str, Cells),
    N2Str.

%% @private
assert_cells_held(Node, Owner, Cells) ->
    [
        ?assert(count_of(cell_value(Node, Type, Uri, Owner)) > 0)
     || {Type, Uri} <- Cells
    ],
    ok.

%% @private
%% Retires the (stopped) N2 on N1, drives the passes synchronously rather
%% than waiting on their timers, and asserts every artifact is gone.
assert_reclaimed(N1, N2Str, Cells) ->
    ok = erpc:call(N1, ?MODULE, do_retire, [node_of(N1, N2Str)]),
    Report = erpc:call(N1, ?MODULE, do_run_retirement, []),
    ct:pal("retirement pass: ~p", [Report]),
    Reclaimed = erpc:call(N1, ?MODULE, do_reclaim_all, []),
    ct:pal("reclaim pass: ~p", [Reclaimed]),

    Final = wait_all_gone(N1, N2Str, Cells),
    ct:pal("post-retirement RIB state on ~p: ~p", [N1, Final]),
    Survivors = [Artifact || Artifact := true <- Final],

    %% Only on failure: the reap declining a cell it scanned is the hard case
    %% to diagnose after the fact, and the cluster is gone once the suite ends.
    Survivors =:= [] orelse
        ct:pal(
            "DIAGNOSTIC: ~p",
            [erpc:call(N1, ?MODULE, do_diagnose, [N2Str, hd(Cells)])]
        ),
    ?assertEqual([], Survivors, "RIB artifacts survived retirement"),
    ok.

%% @private
nodes_of(Config) ->
    [Node || {_, Node, _} <- ?config(cluster, Config)].

%% @private
node_of(Node, NodeStr) ->
    erpc:call(Node, erlang, list_to_atom, [binary_to_list(NodeStr)]).

%% @private
%% Compacts every registry instance on `Node` until the MST directory there
%% lists no seeded cell, or fails naming what the directory still held and
%% what the last compaction round answered.
wait_directory_empty(Node, Owner, Cells) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    Raws = [raw_key(Uri, Owner) || {_, Uri} <- Cells],
    wait_directory_empty_until(Node, Raws, Deadline).

wait_directory_empty_until(Node, Raws, Deadline) ->
    Rounds = erpc:call(Node, ?MODULE, do_compact_registry, []),
    case erpc:call(Node, ?MODULE, do_mst_directory_for, [Raws]) of
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
                    wait_directory_empty_until(Node, Raws, Deadline)
            end
    end.

%% @private
push_module(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

%% @private
cell_value(Node, Type, Uri, Owner) ->
    erpc:call(Node, ?MODULE, do_read_cell, [Type, Uri, Owner]).

%% @private
%% A registration cell's value is a struct with a `count` field; a
%% subscription cell's value is the count itself.
count_of({ok, {#{count := C}, _}}) when is_integer(C) -> C;
count_of({ok, {C, _}}) when is_integer(C) -> C.

%% @private
rib_state(Node, Owner, Cells) ->
    erpc:call(Node, ?MODULE, do_rib_state, [Owner, Cells]).

%% @private
%% Polls until the survivor's view matches `Expected`, so a slow AAE hop is a
%% wait rather than a flake. Returns `ok`, or fails the test with the last
%% observed state so a mismatch names what actually differed.
wait_state(Node, Owner, Cells, Expected) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_state(Node, Owner, Cells, Expected, Deadline).

wait_state(Node, Owner, Cells, Expected, Deadline) ->
    case rib_state(Node, Owner, Cells) of
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
                    wait_state(Node, Owner, Cells, Expected, Deadline)
            end
    end.

%% @private
%% Polls until every artifact is gone, returning the LAST observed state
%% either way — reclamation may need more than one pass, and on failure the
%% caller reports which artifacts survived.
wait_all_gone(Node, Owner, Cells) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_all_gone(Node, Owner, Cells, artifacts(Cells, false), Deadline).

wait_all_gone(Node, Owner, Cells, Gone, Deadline) ->
    case rib_state(Node, Owner, Cells) of
        Gone ->
            Gone;
        Other ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    Other;
                false ->
                    timer:sleep(1000),
                    _ = erpc:call(Node, ?MODULE, do_reclaim_all, []),
                    _ = erpc:call(Node, ?MODULE, do_rib_check, []),
                    wait_all_gone(Node, Owner, Cells, Gone, Deadline)
            end
    end.

%% @private
raw_key(Uri, Owner) ->
    term_to_binary({?REALM, ?POLICY, Uri, Owner}).

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
do_add(registration, Uri) ->
    Ref = bondy_ref:new(internal, {bondy_wamp_api, resolve}),
    Opts = #{match => ?POLICY, invoke => <<"single">>},
    case bondy_registry:add(registration, ?REALM, Uri, Opts, Ref) of
        {ok, _, _} -> ok;
        {ok, _} -> ok
    end;
do_add(subscription, Uri) ->
    Ref = bondy_ref:new(internal, {bondy_wamp_api, resolve}),
    case bondy_registry:add(subscription, ?REALM, Uri, #{}, Ref) of
        {ok, _, _} -> ok;
        {ok, _} -> ok
    end.

%% @private
%% Both artifacts of every cell of `Cells`, read on this node, for the cells
%% `Owner` wrote.
do_rib_state(Owner, Cells) ->
    maps:from_list(
        lists:append([
            [
                {{cell, Type, Uri}, has_cell(Type, Uri, Owner)},
                {{stub, Type, Uri}, has_stub(Type, Uri, Owner)}
            ]
         || {Type, Uri} <- Cells
        ])
    ).

%% @private
has_cell(Type, Uri, Owner) ->
    case do_read_cell(Type, Uri, Owner) of
        {ok, _} -> true;
        {error, not_found} -> false
    end.

%% @private
do_read_cell(Type, Uri, Owner) ->
    Table = bondy_namespace_catalog:table(table_of(Type)),
    bondy_db:read(Table, ?REALM, raw_key(Uri, Owner)).

%% @private
table_of(registration) -> bondy_rib_registrations;
table_of(subscription) -> bondy_rib_subscriptions.

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
%% cells with raw keys `Raws`: what `bondy_oplog_cell_utils:
%% primary_cell_directory/4` enumerates for the ephemeral ETS adapter. A
%% storage key is the raw cell key, realm-prefixed under a realm-folding
%% topology, so match on suffix.
do_mst_directory_for(Raws) ->
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
        run => bondy_oplog_origin_retirement:run()
    }.

%% @private
do_reclaim_all() ->
    [
        {I, bondy_oplog_instance:reclaim_stable_cells(I)}
     || I <- bondy_oplog:list_instances()
    ].

%% @private
%% Counts, per registry instance sweep batch, the batches and the cells they
%% scanned; `do_sweep_counts/0` reads them back.
do_count_sweeps() ->
    Ref = counters:new(2, []),
    telemetry:attach(?MODULE, ?SWEEP_EVENT, fun ?MODULE:on_cells_swept/4, Ref).

%% @private
on_cells_swept(?SWEEP_EVENT, #{scanned := Scanned}, #{instance_id := Id}, Ref) ->
    case Id of
        <<"registry-", _/binary>> ->
            ok = counters:add(Ref, 1, 1),
            ok = counters:add(Ref, 2, Scanned);
        <<_/binary>> ->
            ok
    end.

%% @private
do_sweep_counts() ->
    [#{config := Ref}] = [
        H
     || #{id := ?MODULE} = H <- telemetry:list_handlers(?SWEEP_EVENT)
    ],
    {counters:get(Ref, 1), counters:get(Ref, 2)}.

%% @private
%% Why did the reap not fire? Reports, for the cell `{Type, Uri}` owned by
%% `Owner`: the origins its stored state actually carries, the dead set this
%% node computes, and a DIRECT per-instance reap report (which carries
%% `supported` and `cells_scanned`, both of which `reap_instance/2` discards).
do_diagnose(Owner, {Type, Uri}) ->
    Dead = dead_origins(),
    Reports = [
        {I, bondy_oplog_instance:reap_origins(I, Dead)}
     || I <- bondy_oplog:list_instances()
    ],
    #{
        dead => Dead,
        dead_count => length(Dead),
        cell => do_read_cell(Type, Uri, Owner),
        reap_reports => [
            {I, Rep}
         || {I, {ok, #{cells_scanned := N, supported := Supported}} = Rep} <-
                Reports,
            N > 0 orelse Supported
        ],
        unsupported => [
            I
         || {I, {ok, #{supported := false}}} <- Reports
        ],
        %% For every instance that actually SCANNED a cell: does its applied
        %% frontier carry any of the origins we just declared dead? If yes,
        %% the writer IS known dead and present here, and the decline happens
        %% inside `reap_one_cell/5`. If no, the dead set never named the
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
