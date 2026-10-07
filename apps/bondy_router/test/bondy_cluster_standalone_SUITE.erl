%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_cluster_standalone_SUITE).

-moduledoc """
Boots a standalone router (`[bondy_cluster, enabled]` false) next to a
clustered one, and asserts what clustering off changes: the standalone node
does not start Partisan, refuses connections on the address its peer service
would listen on, refuses `bondy.cluster.leave` with
`bondy.error.cluster_disabled`, and still becomes ready as a cluster of one
whose authentication fence passes with anti-entropy on (`db.aae`, which every
`bondy_ct` peer enables).
The clustered node is the control: the same probes find Partisan running, its
peer address accepting and `leave` reaching the membership check, so a probe
that cannot tell the modes apart fails there.

The `enabling` group restarts a node that wrote and truncated with clustering
disabled as the first node of a cluster that two nodes booted with clustering
enabled join, and asserts every write it kept reads back on all three and
every key it deleted stays deleted. Its negative case joins two nodes that
each truncated with clustering disabled, and asserts that each refuses to
install the other's snapshot (`source_behind_truncation`) while keeping its
own writes. That is the operator rule that a node that truncated alone joins
only nodes that never truncated: in `proofs/tla/JoinInstall.tla`, the
`_SoloJoinAny` configuration violates `NoStrandedRecord` and `_SoloClean`
holds it.

WAMP and the bridge relay between standalone routers are covered by
`bondy_bridge_relay_rpc_SUITE`, whose nodes `bondy_ct:start_nodes/2` boots
standalone.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-export([all/0]).
-export([groups/0]).
-export([suite/0]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([standalone_does_not_start_partisan/1]).
-export([standalone_peer_address_refuses/1]).
-export([standalone_is_a_ready_cluster_of_one/1]).
-export([standalone_refuses_leave/1]).
-export([standalone_partisan_config_is_bondys/1]).
-export([enabling_clustering_keeps_every_write/1]).
-export([nodes_that_truncated_alone_refuse_each_other/1]).
-export([do_apply/2]).
-export([do_read/2]).
-export([do_truncate_main/0]).
-export([do_bootstrap_truncated_main_from/1]).

-define(CLUSTERED, [{[bondy_cluster, enabled], true}]).
-define(BAND, ~"com.bondy.enabling").

suite() -> [{timetrap, {minutes, 15}}].

all() ->
    [{group, modes}, {group, enabling}].

groups() ->
    [
        {modes, [], [
            standalone_does_not_start_partisan,
            standalone_peer_address_refuses,
            standalone_is_a_ready_cluster_of_one,
            standalone_refuses_leave,
            standalone_partisan_config_is_bondys,
            lone_clustered_node_is_fenced_and_held
        ]},
        {enabling, [], [
            enabling_clustering_keeps_every_write,
            nodes_that_truncated_alone_refuse_each_other
        ]}
    ].

init_per_group(modes, Config) ->
    [Standalone, Clustered] = bondy_ct:start_nodes(
        [bondy_standalone1, {bondy_clustered1, ?CLUSTERED}], Config
    ),
    [{standalone, Standalone}, {clustered, Clustered} | Config];
init_per_group(enabling, Config) ->
    Config.

end_per_group(modes, Config) ->
    bondy_ct:stop_cluster([
        ?config(standalone, Config), ?config(clustered, Config)
    ]);
end_per_group(enabling, _Config) ->
    ok.

standalone_does_not_start_partisan(Config) ->
    ?assertNot(runs_partisan(node_of(standalone, Config))),
    ?assert(runs_partisan(node_of(clustered, Config))).

standalone_peer_address_refuses(Config) ->
    ?assertEqual(
        {error, econnrefused}, connect_peer(node_of(standalone, Config))
    ),
    ?assertMatch({ok, _}, connect_peer(node_of(clustered, Config))).

standalone_is_a_ready_cluster_of_one(Config) ->
    Node = node_of(standalone, Config),
    ?assertNot(erpc:call(Node, bondy_cluster, enabled, [])),
    ?assertEqual(
        [erpc:call(Node, partisan, node, [])],
        erpc:call(Node, bondy_cluster, members, [])
    ),
    ?assert(erpc:call(Node, bondy_router_app, is_ready, [])),
    ?assert(
        erpc:call(Node, application, get_env, [bondy_oplog, aae_enabled]) =:=
            {ok, true}
    ),
    ?assertEqual(ok, fence(Node, 50)).

%% A node left on `cluster.enabled = on` with no other member is not a single
%% node: under the default `db.aae.fence.on_isolation = refuse` it never
%% certifies its security tables, and compaction holds with `no_members`.
lone_clustered_node_is_fenced_and_held(Config) ->
    ok = push_module(?config(clustered, Config)),
    Node = node_of(clustered, Config),
    ?assert(erpc:call(Node, bondy_cluster, enabled, [])),
    ?assertEqual(
        {ok, true},
        erpc:call(Node, application, get_env, [bondy_oplog, aae_enabled])
    ),
    ?assertEqual({error, temporarily_unavailable}, fence(Node, 50)),
    [Instance | _] = erpc:call(Node, ?MODULE, main_instances, []),
    ?assertEqual(
        {error, no_members},
        erpc:call(Node, bondy_oplog_compaction, compact, [Instance])
    ).

standalone_refuses_leave(Config) ->
    ?assertEqual(
        ~"bondy.error.cluster_disabled",
        leave_error_uri(node_of(standalone, Config), ~"nosuch@nowhere")
    ),
    ?assertNotEqual(
        ~"bondy.error.cluster_disabled",
        leave_error_uri(node_of(clustered, Config), ~"nosuch@nowhere")
    ).

%% Partisan's own default for `pid_encoding` is `true`; Bondy sets `false`. A
%% standalone node never starts Partisan, so only `bondy_config:init/1` can
%% have put Bondy's value into the configuration Partisan reads.
standalone_partisan_config_is_bondys(Config) ->
    [
        ?assertNot(erpc:call(N, partisan_config, get, [pid_encoding]))
     || N <- [node_of(standalone, Config), node_of(clustered, Config)]
    ].

%% N1 writes, deletes and truncates with clustering disabled, then restarts
%% with it enabled; N2 and N3 boot with clustering enabled, so they cannot
%% truncate before joining, and join N1.
enabling_clustering_keeps_every_write(Config) ->
    [N1, N2, N3] = up(
        bondy_ct:start_nodes(
            [cen1, {cen2, ?CLUSTERED}, {cen3, ?CLUSTERED}], Config
        )
    ),
    try
        {Kept, Removed} = write_and_remove(N1, ~"cen", 20),
        ?assertMatch({0, [_ | _]}, call(N1, do_truncate_main, [])),
        N1b = restart_clustered(N1, 1, Config),
        ok = bondy_ct:rejoin(N2, [N1b, N2], 30000),
        ok = bondy_ct:rejoin(N3, [N1b, N2, N3], 30000),
        ok = await_reads([N1b, N2, N3], Kept, Removed)
    after
        bondy_ct:stop_cluster(get(?MODULE))
    end.

%% Both nodes truncate with clustering disabled, then join: each holds events
%% in its truncation record the other never received, so neither may install
%% the other's snapshot, and neither loses its own writes.
nodes_that_truncated_alone_refuse_each_other(Config) ->
    [A, B] = up(bondy_ct:start_nodes([cneg1, cneg2], Config)),
    try
        {KeptA, _} = write_and_remove(A, ~"cnega", 10),
        {KeptB, _} = write_and_remove(B, ~"cnegb", 10),
        ?assertMatch({0, [_ | _]}, call(A, do_truncate_main, [])),
        ?assertMatch({0, [_ | _]}, call(B, do_truncate_main, [])),
        Ab = restart_clustered(A, 1, Config),
        Bb = restart_clustered(B, 2, Config),
        ok = bondy_ct:rejoin(Bb, [Ab, Bb], 30000),
        lists:foreach(
            fun({Node, Peer}) ->
                Results = call(
                    Node, do_bootstrap_truncated_main_from, [node_of(Peer)]
                ),
                ?assertNotEqual([], Results),
                [
                    ?assertMatch(
                        {_,
                            {bootstrap_catalogue_failed,
                                {source_behind_truncation, _}}},
                        R
                    )
                 || R <- Results
                ]
            end,
            [{Ab, Bb}, {Bb, Ab}]
        ),
        ok = await_reads([Ab], KeptA, []),
        ok = await_reads([Bb], KeptB, [])
    after
        bondy_ct:stop_cluster(get(?MODULE))
    end.

node_of({_, Node, _}) ->
    Node.

node_of(Key, Config) ->
    {_, Node, _} = ?config(Key, Config),
    Node.

leave_error_uri(Node, Name) ->
    Ctxt = erpc:call(Node, bondy_context, local_context, [?MASTER_REALM_URI]),
    M = erpc:call(
        Node, bondy_wamp_message, call, [1, #{}, ?BONDY_CLUSTER_LEAVE, [Name]]
    ),
    {reply, #error{error_uri = Uri}} =
        erpc:call(Node, bondy_wamp_api, handle_call, [M, Ctxt]),
    Uri.

%% The fence passes once the sync scheduler's first tick has certified the
%% security tables fresh.
fence(Node, 0) ->
    erpc:call(Node, bondy_auth, security_fence, []);
fence(Node, N) ->
    case erpc:call(Node, bondy_auth, security_fence, []) of
        ok ->
            ok;
        {error, _} ->
            timer:sleep(200),
            fence(Node, N - 1)
    end.

%% The suite's nodes are kept where `after` can stop them, whichever
%% incarnation is current.
up(Nodes) ->
    _ = [push_module(N) || N <- Nodes],
    put(?MODULE, Nodes),
    Nodes.

restart_clustered({Name, _, _} = S, Idx, Config) ->
    New = bondy_ct:restart_node(S, Idx, [], Config, graceful),
    ok = push_module(New),
    put(?MODULE, lists:keyreplace(Name, 1, get(?MODULE), New)),
    New.

push_module({_, Node, _}) ->
    {Mod, Bin, File} = code:get_object_code(?MODULE),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

call(S, Fun, Args) ->
    erpc:call(node_of(S), ?MODULE, Fun, Args, 120000).

%% Writes `Count` keys on `S` and deletes every third one.
write_and_remove(S, Prefix, Count) ->
    Keys = [
        {<<Prefix/binary, "_", (integer_to_binary(I))/binary>>, I}
     || I <- lists:seq(1, Count)
    ],
    _ = [ok = call(S, do_apply, [K, {set, V}]) || {K, V} <- Keys],
    Removed = [K || {K, V} <- Keys, V rem 3 =:= 0],
    _ = [ok = call(S, do_apply, [K, clear]) || K <- Removed],
    {[{K, V} || {K, V} <- Keys, V rem 3 =/= 0], Removed}.

%% Polls until every node reads every kept value and no removed key, driving
%% the sync scheduler between attempts.
await_reads(Nodes, Kept, Removed) ->
    await_reads(Nodes, Kept, Removed, 180).

await_reads(Nodes, Kept, Removed, Tries) ->
    Wanted =
        [{K, {ok, V}} || {K, V} <- Kept] ++
            [{K, {error, not_found}} || K <- Removed],
    Wrong = [
        {node_of(S), K, Got}
     || S <- Nodes,
        {K, Want} <- Wanted,
        {Got, Want1} <- [{value(call(S, do_read, [?BAND, K])), Want}],
        Got =/= Want1
    ],
    case {Wrong, Tries} of
        {[], _} ->
            ok;
        {_, 0} ->
            ct:fail({reads_did_not_converge, Wrong});
        _ ->
            _ = [trigger_sync(S) || S <- Nodes],
            timer:sleep(1000),
            await_reads(Nodes, Kept, Removed, Tries - 1)
    end.

trigger_sync(S) ->
    try
        erpc:call(node_of(S), bondy_oplog_sync_scheduler, trigger, [])
    catch
        _:_ -> ok
    end.

value({ok, {V, _Hlc}}) -> {ok, V};
value(Other) -> Other.

do_apply(Key, Op) ->
    bondy_db:apply(users_table(), ?BAND, Key, Op).

do_read(Band, Key) ->
    bondy_db:read(users_table(), Band, Key).

users_table() ->
    bondy_namespace_catalog:table(security_users).

%% Compacts and sweeps every main-DB instance until none holds a live event,
%% and returns the live events left with the instances holding a watermark.
do_truncate_main() ->
    do_truncate_main(30).

do_truncate_main(Tries) ->
    Main = main_instances(),
    _ = [bondy_oplog:compact(I) || I <- Main],
    _ = [bondy_oplog_instance:reclaim_stable_cells(I) || I <- Main],
    Live = lists:sum([bondy_oplog:size(I) || I <- Main]),
    case Live =:= 0 orelse Tries =:= 0 of
        true ->
            {Live, [
                I
             || I <- Main, bondy_oplog:current_watermark(I) =/= undefined
            ]};
        false ->
            timer:sleep(200),
            do_truncate_main(Tries - 1)
    end.

%% One catalogue install from `Peer` on every main-DB instance whose
%% truncation record is not empty.
do_bootstrap_truncated_main_from(Peer) ->
    Opts = application:get_env(bondy_oplog, sync_session_opts, #{}),
    [
        {I,
            await_exit(
                bondy_oplog_sync_session:start_bootstrap_catalogue(
                    I, Peer, Opts
                )
            )}
     || I <- main_instances(), bondy_oplog_registry:truncated(I) =/= #{}
    ].

await_exit({ok, Pid}) ->
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, Reason} -> Reason
    after 60_000 -> error({no_exit, Pid})
    end.

main_instances() ->
    Main = bondy_namespace_catalog:main_db_name(),
    [I || I <- bondy_oplog:list_instances(), bondy_oplog:db_of(I) =:= Main].

runs_partisan(Node) ->
    lists:keymember(
        partisan, 1, erpc:call(Node, application, which_applications, [])
    ).

%% The address the node's peer service listens on when it runs, read from the
%% node's own Partisan configuration.
connect_peer(Node) ->
    #{listen_addrs := [#{ip := IP, port := Port} | _]} =
        erpc:call(Node, partisan, node_spec, []),
    case gen_tcp:connect(IP, Port, [], 2000) of
        {ok, Socket} ->
            ok = gen_tcp:close(Socket),
            {ok, Port};
        Error ->
            Error
    end.
