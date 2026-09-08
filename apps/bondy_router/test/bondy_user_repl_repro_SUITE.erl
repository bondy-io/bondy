%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_user_repl_repro_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

%% Reproduction harness for a customer report: "users are not replicated"
%% with the Grafana `Instances DIVERGED` panel showing 23.
%%
%% The panel counts instance_ids for which
%% `bondy_oplog_instance_frontier_hash` takes more than one distinct value
%% across the scraped nodes, i.e.
%%   count(count by (instance_id)(count_values by (instance_id)(...)) > 1)
%% This suite computes exactly that quantity from
%% `bondy_oplog_registry:frontier/1`, the same source the exporter reads.
%%
%% DIFFERENCE FROM `bondy_aae_cluster_SUITE`: that suite runs with the CT
%% harness overrides applied by `bondy_ct:node_env/2` — `live_sync_adaptive
%% => false` and `aae_max_concurrency => 8`. The customer runs the shipped
%% defaults. This suite restores the SHIPPED DEFAULTS so the configuration
%% under test is the customer's, and writes users through the real RBAC API
%% (`bondy_rbac_user:add/2`) rather than through `bondy_db:apply/…`.

%% schema/bondy.schema defaults for the `db.aae.*` keys the customer does
%% not set (their bondy.conf carries no `db.*` key at all).
-define(PROD_AAE_ENV, [
    {[bondy_oplog, aae_enabled], true},
    {[bondy_oplog, sync_interval_ms], 500},
    {[bondy_oplog, live_sync_adaptive], true},
    {[bondy_oplog, live_sync_max_ms], 5000},
    {[bondy_oplog, aae_max_concurrency], 3},
    {[bondy_oplog, aae_max_pages_in_flight], 2048},
    {[bondy_oplog, aae_load_adaptive], false},
    {[bondy_oplog, aae_fanout], 3}
]).

-define(NODE_NAMES, [
    {bondy1, ?PROD_AAE_ENV},
    {bondy2, ?PROD_AAE_ENV},
    {bondy3, ?PROD_AAE_ENV}
]).

-define(REALM, <<"com.bondy.user_repl_repro">>).
-define(NUSERS, 3000).
-define(WRITERS_PER_NODE, 4).
-define(SETTLE_MS, 180000).
%% Sustained-churn window: how long writes keep flowing after the bulk add.
-define(CHURN_MS, 60000).
-define(RR_USERS, 6000).

all() ->
    [
        users_converge_under_write_load,
        users_converge_across_rolling_restart
    ].

suite() ->
    [{timetrap, {minutes, 15}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_suite(Config) ->
    %% `users_converge_across_rolling_restart` replaces node 3's peer pid, so
    %% the spec held in Config can be stale by now.
    _ = safe(fun() -> bondy_ct:stop_cluster(?config(cluster, Config)) end),
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

%% Create the realm on N1, wait for it everywhere, then add ?NUSERS users
%% concurrently across all three nodes through the RBAC API. After the writers
%% drain, every node must list every username, and the frontier-hash
%% divergence count (the Grafana panel) must fall to zero.
users_converge_under_write_load(Config) ->
    [N1, N2, N3] = Nodes = nodes_of(Config),

    ok = erpc:call(N1, ?MODULE, do_create_realm, [?REALM], 30000),
    ok = wait_realm(Nodes, ?REALM, 60000),

    Usernames = [
        iolist_to_binary(io_lib:format("user_~4..0b", [I]))
     || I <- lists:seq(1, ?NUSERS)
    ],

    %% Round-robin the username space across the three nodes, then run
    %% ?WRITERS_PER_NODE concurrent writers on each node.
    Assigned = assign(Usernames, [N1, N2, N3]),
    Sampler = start_sampler(Nodes),
    T0 = erlang:monotonic_time(millisecond),
    Results = write_concurrently(Assigned),
    T1 = erlang:monotonic_time(millisecond),
    DuringTrace = stop_sampler(Sampler),
    ct:pal("divergence WHILE writing (elapsed_ms, diverged, counts):~n~p", [
        DuringTrace
    ]),
    ct:pal("scheduler/instance snapshot:~n~p", [snapshot(Nodes)]),

    %% Phase 2 — sustained churn. The customer's cluster is not quiescent when
    %% the panel reads 23; it is taking writes. Hold the cluster under a steady
    %% update stream for ?CHURN_MS and sample the panel quantity throughout.
    ChurnSampler = start_sampler(Nodes),
    ChurnErrs = churn(Nodes, Usernames, ?CHURN_MS),
    ChurnTrace = stop_sampler(ChurnSampler),
    ct:pal("churn: ~p errors~n~p", [
        length(ChurnErrs), lists:sublist(ChurnErrs, 5)
    ]),
    ct:pal(
        "divergence DURING sustained churn (elapsed_ms, diverged, counts):~n~p",
        [
            ChurnTrace
        ]
    ),
    ct:pal("sync counters after churn:~n~p", [counters(Nodes)]),

    Failed = [R || {_, _, R} <- Results, R =/= ok],
    ct:pal(
        "writes: ~p users over ~p ms, ~p write errors~n~p",
        [?NUSERS, T1 - T0, length(Failed), lists:sublist(Failed, 10)]
    ),

    %% Sample the Grafana quantity while (and after) the cluster settles.
    {Converged, Trace} = wait_converged(Nodes, Usernames, ?SETTLE_MS),

    ct:pal(
        "convergence trace (elapsed_ms, diverged_instances, per-node "
        "user counts):~n~p",
        [Trace]
    ),

    Missing = missing_report(Nodes, Usernames),
    ct:pal("missing users per node: ~p", [
        [{N, length(M)} || {N, M} <- Missing]
    ]),
    ct:pal("diverged instances (detail): ~p", [
        lists:sublist(diverged_detail(Nodes), 40)
    ]),

    ?assertEqual([], Failed, "no RBAC write may fail"),
    ?assertEqual(
        [{N, []} || N <- Nodes],
        Missing,
        "every node must list every user"
    ),
    ?assert(Converged, "frontier hashes must converge across the cluster"),
    ok.

%% The customer redeploys. A graceful stop + restart of one node WHILE user
%% writes keep flowing on the survivors is the rolling-deploy path: the
%% restarted node comes back on its own data dir, rejoins, and must catch up
%% on everything written while it was gone AND everything written since.
users_converge_across_rolling_restart(Config) ->
    Cluster = ?config(cluster, Config),
    [S1, S2, N3Spec] = Cluster,
    Survivors = [N || {_, N, _} <- [S1, S2]],
    Nodes0 = nodes_of(Config),

    ok = erpc:call(hd(Survivors), ?MODULE, do_create_realm, [?REALM], 30000),

    %% A background writer keeps adding users to the two survivors for the
    %% whole case. Node 3 is restarted in the middle of that stream, so users
    %% land while it is DOWN and while it is CATCHING UP — the rolling-deploy
    %% shape.
    Sampler = start_sampler(Nodes0),
    Writer = start_writer(Survivors, ?RR_USERS),

    timer:sleep(3000),
    T0 = erlang:monotonic_time(millisecond),
    N3New = bondy_ct:restart_node(N3Spec, 3, ?PROD_AAE_ENV, Config, graceful),
    ok = push_module(element(2, N3New), ?MODULE),
    ok = bondy_ct:rejoin(N3New, [S1, S2], 60000),
    T1 = erlang:monotonic_time(millisecond),
    ct:pal("node 3 restart+rejoin took ~p ms", [T1 - T0]),

    {Written, WriteErrs} = stop_writer(Writer),
    Trace = stop_sampler(Sampler),
    ct:pal("rolling restart — divergence trace:~n~p", [Trace]),
    ct:pal("rolling restart — ~p users written, ~p errors~n~p", [
        length(Written), length(WriteErrs), lists:sublist(WriteErrs, 10)
    ]),

    Nodes = [S || {_, S, _} <- [S1, S2, N3New]],
    {Converged, Trace2} = wait_converged(Nodes, Written, ?SETTLE_MS),
    ct:pal("rolling restart — settle trace:~n~p", [Trace2]),
    ct:pal("rolling restart — sync counters:~n~p", [counters(Nodes)]),
    ct:pal("rolling restart — snapshot:~n~p", [snapshot(Nodes)]),

    Missing = missing_report(Nodes, Written),
    ct:pal("rolling restart — missing users per node: ~p", [
        [{N, length(M)} || {N, M} <- Missing]
    ]),
    ct:pal("rolling restart — diverged detail: ~p", [
        lists:sublist(diverged_detail(Nodes), 40)
    ]),
    ok = diagnose_missing(Nodes, Missing),

    ?assertEqual([], WriteErrs, "no RBAC write may fail"),
    ?assertEqual(
        [{N, []} || N <- Nodes],
        Missing,
        "every node must list every user written across the restart"
    ),
    ?assert(Converged, "frontier hashes must converge after the restart"),
    ok.

%% =============================================================================
%% PRIVATE — controller side
%% =============================================================================

nodes_of(Config) ->
    [N || {_, N, _} <- ?config(cluster, Config)].

push_module(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

%% Round-robin `Names' over `Nodes' → [{Node, [Name]}].
assign(Names, Nodes) ->
    Indexed = lists:zip(Names, lists:seq(1, length(Names))),
    N = length(Nodes),
    [
        {Node, [
            Name
         || {Name, I} <- Indexed, ((I - 1) rem N) + 1 =:= Pos
        ]}
     || {Node, Pos} <- lists:zip(Nodes, lists:seq(1, N))
    ].

%% Spawn ?WRITERS_PER_NODE writers per node, each adding its slice.
write_concurrently(Assigned) ->
    Parent = self(),
    Pids = lists:flatten([
        begin
            Chunks = chunk(Names, ?WRITERS_PER_NODE),
            [
                spawn_monitor(fun() ->
                    Parent ! {self(), do_writes(Node, Chunk)}
                end)
             || Chunk <- Chunks
            ]
        end
     || {Node, Names} <- Assigned
    ]),
    collect(Pids, []).

do_writes(Node, Names) ->
    [
        {Node, Name,
            erpc:call(Node, ?MODULE, do_add_user, [?REALM, Name], 30000)}
     || Name <- Names
    ].

collect([], Acc) ->
    lists:flatten(Acc);
collect([{Pid, Ref} | T], Acc) ->
    R =
        receive
            {Pid, Res} ->
                receive
                    {'DOWN', Ref, process, Pid, _} -> ok
                after 5000 -> ok
                end,
                Res;
            {'DOWN', Ref, process, Pid, Reason} ->
                [{Pid, writer_crashed, Reason}]
        after 300000 ->
            [{Pid, writer_timeout, timeout}]
        end,
    collect(T, [R | Acc]).

chunk(L, N) when N > 0 ->
    chunk(L, N, lists:duplicate(N, [])).

chunk([], _N, Acc) ->
    [lists:reverse(B) || B <- Acc, B =/= []];
chunk([H | T], N, [B | Rest]) ->
    chunk(T, N, Rest ++ [[H | B]]).

wait_realm(Nodes, Uri, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_realm_(Nodes, Uri, Deadline).

wait_realm_(Nodes, Uri, Deadline) ->
    case [N || N <- Nodes, not erpc:call(N, ?MODULE, do_has_realm, [Uri])] of
        [] ->
            ok;
        Pending ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(500),
                    wait_realm_(Nodes, Uri, Deadline);
                false ->
                    error({realm_not_converged, Uri, Pending})
            end
    end.

%% Polls the Grafana quantity and the per-node user counts until BOTH the
%% divergence count is 0 and every node lists every user, or the deadline
%% passes. Returns `{Converged, Trace}'.
wait_converged(Nodes, Usernames, Timeout) ->
    Start = erlang:monotonic_time(millisecond),
    Deadline = Start + Timeout,
    wait_converged_(Nodes, Usernames, Start, Deadline, []).

wait_converged_(Nodes, Usernames, Start, Deadline, Trace) ->
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    Diverged = diverged_count(Nodes),
    Missing = missing_report(Nodes, Usernames),
    Counts = [{N, length(M)} || {N, M} <- Missing],
    Sample = {Elapsed, Diverged, {missing, Counts}},
    Trace1 = [Sample | Trace],
    AllSeen = lists:all(fun({_, C}) -> C =:= 0 end, Counts),
    case Diverged =:= 0 andalso AllSeen of
        true ->
            {true, lists:reverse(Trace1)};
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(2000),
                    wait_converged_(Nodes, Usernames, Start, Deadline, Trace1);
                false ->
                    {false, lists:reverse(Trace1)}
            end
    end.

%% The Grafana `Instances DIVERGED` value: instance_ids whose frontier hash
%% takes more than one distinct value across the cluster.
diverged_count(Nodes) ->
    length(diverged_detail(Nodes)).

%% `{Count, SortedIds}` — which instances the Grafana panel would be counting
%% at this instant. The ids answer whether the count comes from the durable
%% `main-*` shards, the ephemeral `registry-*` shards, or both.
diverged_ids(Nodes) ->
    Ids = [Id || {Id, _} <- diverged_detail(Nodes)],
    {length(Ids), lists:sort(Ids)}.

diverged_detail(Nodes) ->
    PerNode = [
        {N, erpc:call(N, ?MODULE, do_frontier_hashes, [])}
     || N <- Nodes
    ],
    Ids = lists:usort(lists:flatten([maps:keys(M) || {_, M} <- PerNode])),
    [
        {Id, Vals}
     || Id <- Ids,
        Vals <- [[{N, maps:get(Id, M, absent)} || {N, M} <- PerNode]],
        length(lists:usort([V || {_, V} <- Vals])) > 1
    ].

missing_report(Nodes, Usernames) ->
    Want = sets:from_list(Usernames, [{version, 2}]),
    [
        begin
            Have = sets:from_list(
                erpc:call(N, ?MODULE, do_list_usernames, [?REALM], 60000),
                [{version, 2}]
            ),
            {N, lists:sort(sets:to_list(sets:subtract(Want, Have)))}
        end
     || N <- Nodes
    ].

%% For every user a node is missing, report the instance the cell routes to,
%% what a direct read on each node returns, and that instance's frontier /
%% MST root on each node. This is what separates "the frontier claims events
%% it does not hold" (oracle-blind loss) from ordinary lag.
diagnose_missing(_Nodes, Missing) ->
    case [{N, M} || {N, M} <- Missing, M =/= []] of
        [] ->
            ok;
        Bad ->
            lists:foreach(
                fun({Node, Users}) ->
                    Sample = lists:sublist(Users, 5),
                    ct:pal(
                        "MISSING on ~p: ~p of ~p users; sample diagnosis:~n~p",
                        [
                            Node,
                            length(Users),
                            length(Users),
                            [
                                erpc:call(
                                    Node,
                                    ?MODULE,
                                    do_diagnose,
                                    [?REALM, U],
                                    30000
                                )
                             || U <- Sample
                            ]
                        ]
                    )
                end,
                Bad
            ),
            ok
    end.

%% Background writer: adds `rr_user_NNNN` to `Nodes` round-robin until asked
%% to stop or `Max` users are written. Returns `{WrittenNames, Errors}`.
start_writer(Nodes, Max) ->
    Parent = self(),
    spawn(fun() -> writer_loop(Parent, Nodes, Max, 1, [], []) end).

writer_loop(Parent, _Nodes, Max, I, Written, Errs) when I > Max ->
    writer_wait(Parent, Written, Errs);
writer_loop(Parent, Nodes, Max, I, Written, Errs) ->
    receive
        {stop, From} ->
            From ! {writer, lists:reverse(Written), lists:reverse(Errs)}
    after 0 ->
        Name = iolist_to_binary(io_lib:format("rr_user_~4..0b", [I])),
        Node = lists:nth(((I - 1) rem length(Nodes)) + 1, Nodes),
        {W, E} =
            try erpc:call(Node, ?MODULE, do_add_user, [?REALM, Name], 30000) of
                ok -> {[Name | Written], Errs};
                Other -> {Written, [{Name, Other} | Errs]}
            catch
                C:R -> {Written, [{Name, C, R} | Errs]}
            end,
        writer_loop(Parent, Nodes, Max, I + 1, W, E)
    end.

writer_wait(Parent, Written, Errs) ->
    receive
        {stop, From} ->
            From ! {writer, lists:reverse(Written), lists:reverse(Errs)}
    after 300000 ->
        Parent ! {writer, lists:reverse(Written), lists:reverse(Errs)}
    end.

stop_writer(Pid) ->
    Pid ! {stop, self()},
    receive
        {writer, Written, Errs} -> {Written, Errs}
    after 120000 -> {[], [writer_timeout]}
    end.

%% Steady update stream: each node repeatedly bumps the `meta` of users it
%% owns, for `Ms` milliseconds. Returns the errors seen.
churn(Nodes, Usernames, Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    Parent = self(),
    Pids = [
        element(
            1,
            spawn_monitor(fun() ->
                Parent ! {self(), churn_loop(N, Usernames, Deadline, 0, [])}
            end)
        )
     || N <- Nodes
    ],
    lists:flatten([
        receive
            {P, R} -> R
        after Ms + 120000 -> [{P, churn_timeout}]
        end
     || P <- Pids
    ]).

churn_loop(Node, Usernames, Deadline, Round, Errs) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        false ->
            Errs;
        true ->
            %% A small slice per round so the stream is steady rather than
            %% one long burst.
            Slice = lists:sublist(
                lists:nthtail(
                    (Round * 25) rem max(1, length(Usernames) - 25),
                    Usernames
                ),
                25
            ),
            E =
                try
                    erpc:call(
                        Node,
                        ?MODULE,
                        do_touch_users,
                        [?REALM, Slice, Round],
                        60000
                    )
                catch
                    C:R -> [{Node, Round, C, R}]
                end,
            churn_loop(Node, Usernames, Deadline, Round + 1, E ++ Errs)
    end.

%% Per-node AAE session outcome + gap/rebootstrap counters — the same series
%% the Grafana `Sync sessions` and `Frontier gap` panels read.
counters(Nodes) ->
    [{N, erpc:call(N, ?MODULE, do_counters, [], 30000)} || N <- Nodes].

%% Samples the Grafana divergence quantity every 2s in the background.
start_sampler(Nodes) ->
    Parent = self(),
    spawn(fun() ->
        sampler_loop(Parent, Nodes, erlang:monotonic_time(millisecond), [])
    end).

sampler_loop(Parent, Nodes, Start, Acc) ->
    receive
        {stop, From} ->
            From ! {sampler, lists:reverse(Acc)}
    after 1000 ->
        Elapsed = erlang:monotonic_time(millisecond) - Start,
        Sample =
            try
                Counts = [
                    {N,
                        length(
                            erpc:call(
                                N, ?MODULE, do_list_usernames, [?REALM], 15000
                            )
                        )}
                 || N <- Nodes
                ],
                {Elapsed, diverged_ids(Nodes), Counts}
            catch
                C:R -> {Elapsed, {sample_error, C, R}, []}
            end,
        sampler_loop(Parent, Nodes, Start, [Sample | Acc])
    end.

stop_sampler(Pid) ->
    Pid ! {stop, self()},
    receive
        {sampler, Trace} -> Trace
    after 30000 -> [sampler_timeout]
    end.

%% Per-node scheduler + instance facts, for diagnosing WHY sync is not
%% converging.
snapshot(Nodes) ->
    [{N, erpc:call(N, ?MODULE, do_snapshot, [], 30000)} || N <- Nodes].

%% =============================================================================
%% PRIVATE — peer side (run via erpc on the cluster nodes)
%% =============================================================================

do_create_realm(Uri) ->
    case bondy_realm:exists(Uri) of
        true -> ok;
        false -> do_create_realm_(Uri)
    end.

do_create_realm_(Uri) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"user replication repro realm">>,
        security_enabled => true,
        authmethods => [?PASSWORD_AUTH]
    }),
    ok.

do_has_realm(Uri) ->
    try bondy_realm:exists(Uri) of
        Bool -> Bool
    catch
        _:_ -> false
    end.

do_add_user(Uri, Username) ->
    User = bondy_rbac_user:new(#{
        username => Username,
        password => <<"repro_pass_123">>,
        groups => []
    }),
    case bondy_rbac_user:add(Uri, User) of
        {ok, _} -> ok;
        {error, already_exists} -> ok;
        Other -> Other
    end.

do_list_usernames(Uri) ->
    try
        [bondy_rbac_user:username(U) || U <- bondy_rbac_user:list(Uri)]
    catch
        _:_ -> []
    end.

%% Mirrors `bondy_prometheus_db:frontier_hash_rows/0'.
do_frontier_hashes() ->
    maps:from_list([
        {Id, erlang:phash2(do_frontier(Id))}
     || Id <- do_instances()
    ]).

do_instances() ->
    try bondy_oplog:list_instances() of
        L when is_list(L) -> lists:sort(L);
        _ -> []
    catch
        _:_ -> []
    end.

do_frontier(Id) ->
    try bondy_oplog_registry:frontier(Id) of
        F when is_map(F) -> F;
        _ -> #{}
    catch
        _:_ -> #{}
    end.

%% Facts that decide whether the live-sync throttle and the node-wide
%% concurrency cap are actually in force on this node.
do_snapshot() ->
    Ids = do_instances(),
    NoTargets = [
        Id
     || Id <- Ids, safe(fun() -> bondy_oplog_registry:ae_targets(Id) end) =:= []
    ],
    Lifecycles = lists:foldl(
        fun(Id, Acc) ->
            S = safe(fun() -> bondy_oplog_instance:lifecycle_state(Id) end),
            maps:update_with(S, fun(X) -> X + 1 end, 1, Acc)
        end,
        #{},
        Ids
    ),
    #{
        node => node(),
        instance_count => length(Ids),
        lifecycles => Lifecycles,
        %% Instances with NO ae_targets are the ONLY ones the adaptive
        %% live-sync throttle and the node-wide concurrency cap can apply to
        %% (`bondy_oplog_sync_scheduler:backs_fence/1`).
        instances_without_ae_targets => length(NoTargets),
        scheduler => safe(fun() -> bondy_oplog_sync_scheduler:info() end),
        aae_enabled => application:get_env(bondy_oplog, aae_enabled),
        live_sync_adaptive =>
            application:get_env(bondy_oplog, live_sync_adaptive),
        aae_max_concurrency =>
            application:get_env(bondy_oplog, aae_max_concurrency),
        sync_session_opts =>
            safe(fun() -> bondy_oplog_config:sync_session_opts() end),
        members => safe(fun() -> partisan:nodes() end),
        oversized_total =>
            safe(fun() -> bondy_oplog_sync_metrics:oversized_total() end),
        %% Which instance FAMILIES can diverge at all: an instance whose
        %% frontier VV is permanently empty hashes identically everywhere, so
        %% it can never contribute to the Grafana `Instances DIVERGED` count.
        frontier_sizes_by_family => frontier_sizes_by_family(Ids)
    }.

frontier_sizes_by_family(Ids) ->
    lists:foldl(
        fun(Id, Acc) ->
            Family = hd(binary:split(Id, <<"-">>)),
            Size = map_size(do_frontier(Id)),
            maps:update_with(
                Family,
                fun({N, NonEmpty, Max}) ->
                    {N + 1, NonEmpty + min(Size, 1), max(Max, Size)}
                end,
                {1, min(Size, 1), Size},
                Acc
            )
        end,
        #{},
        Ids
    ).

do_touch_users(Uri, Usernames, Round) ->
    lists:foldl(
        fun(U, Acc) ->
            Data = #{meta => #{<<"round">> => integer_to_binary(Round)}},
            case bondy_rbac_user:update(Uri, U, Data) of
                {ok, _} -> Acc;
                {error, {no_such_user, _}} -> Acc;
                Other -> [{U, Other} | Acc]
            end
        end,
        [],
        Usernames
    ).

do_counters() ->
    Names = [
        bondy_oplog_sync_sessions_total,
        bondy_oplog_frontier_gap_verdicts_total,
        bondy_oplog_rebootstraps_scheduled_total,
        bondy_oplog_doored_events_total,
        bondy_oplog_mst_rebuilt_total
    ],
    maps:from_list([
        {Name, safe(fun() -> aggregate(Name) end)}
     || Name <- Names
    ]).

%% Sum a labelled counter family by its LAST label (outcome, when present),
%% so the result is small enough to read in a log.
aggregate(Name) ->
    Vals = prometheus_counter:values(default, Name),
    lists:foldl(
        fun({Labels, V}, Acc) ->
            Key =
                case Labels of
                    [] -> total;
                    _ -> element(2, lists:last(Labels))
                end,
            maps:update_with(Key, fun(X) -> X + V end, V, Acc)
        end,
        #{},
        Vals
    ).

do_diagnose(Realm, Username) ->
    T = bondy_namespace_catalog:table(security_users),
    Shard = safe(fun() -> bondy_db:shard_for(T, Realm, Username) end),
    Id = safe(fun() -> maps:get(Shard, maps:get(instance_ids, T)) end),
    #{
        node => node(),
        username => Username,
        shard => Shard,
        instance => Id,
        %% The RBAC read (what the customer sees) and the raw cell read.
        rbac_lookup =>
            safe(fun() -> ok_or_err(bondy_rbac_user:lookup(Realm, Username)) end),
        raw_read => safe(fun() ->
            ok_or_err(bondy_db:read(T, Realm, Username))
        end),
        frontier => safe(fun() -> bondy_oplog_registry:frontier(Id) end),
        root_hash => safe(fun() -> bondy_oplog_instance:root_hash(Id) end),
        lifecycle => safe(fun() -> bondy_oplog_instance:lifecycle_state(Id) end),
        watermark => safe(fun() -> bondy_oplog:current_watermark(Id) end)
    }.

ok_or_err({ok, _}) -> found;
ok_or_err(Other) -> Other.

safe(F) ->
    try
        F()
    catch
        C:R -> {error, C, R}
    end.
