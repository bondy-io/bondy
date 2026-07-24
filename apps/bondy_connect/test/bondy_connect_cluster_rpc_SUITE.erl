%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_cluster_rpc_SUITE).

-moduledoc """
Distributed RPC integration tests: a two-node Bondy cluster (peer nodes
with their `wamp_tcp` listeners re-enabled on distinct ports) with real
`bondy_connect` clients running in the CT controller VM — the caller
connected to node1 and the callee to node2 — so every message crosses the
cluster relay.

Validates progressive call results end to end in distributed mode: the
CALL is forwarded node1 → node2 (call promise on node1, invocation
promise on node2), the callee streams progressive YIELDs on node2, and
the relayed progressive RESULTs must reach the caller on node1 in yield
order without settling the call before the final result.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.cluster.rpc">>).
-define(HOST, "127.0.0.1").
-define(NODE1_WAMP_PORT, 18201).
-define(NODE2_WAMP_PORT, 18202).
-define(PROC, <<"com.example.cluster.progressive">>).

all() ->
    [
        progressive_across_cluster,
        progressive_across_cluster_feature_disabled,
        progressive_remote_cancel_interrupts_callee,
        progressive_remote_caller_death_interrupts_callee
    ].

suite() ->
    [{timetrap, {minutes, 5}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(
        [
            {bcx_rpc1, [
                {[bondy_router, wamp_tcp, enabled], true},
                {
                    [
                        bondy_router,
                        wamp_tcp,
                        transport_opts,
                        socket_opts,
                        port
                    ],
                    ?NODE1_WAMP_PORT
                }
            ]},
            {bcx_rpc2, [
                {[bondy_router, wamp_tcp, enabled], true},
                {
                    [
                        bondy_router,
                        wamp_tcp,
                        transport_opts,
                        socket_opts,
                        port
                    ],
                    ?NODE2_WAMP_PORT
                }
            ]}
        ],
        Config
    ),
    {ok, _} = application:ensure_all_started(bondy_connect),

    [{_, Node1, _}, {_, Node2, _}] = Nodes,

    %% Create the realm on node1 and wait until it replicates to node2 so
    %% the callee can join there. The realm object can arrive before its
    %% RBAC data, so also wait for the anonymous auth sources — joining
    %% before they land gets the client rejected.
    _ = erpc:call(Node1, bondy_realm, create, [realm_config()]),
    ok = wait_until(
        fun() ->
            case erpc:call(Node2, bondy_realm, lookup, [?REALM]) of
                {ok, _} -> true;
                _ -> false
            end
        end,
        30000,
        realm_not_replicated
    ),
    ok = wait_until(
        fun() ->
            erpc:call(Node2, bondy_rbac_source, list, [?REALM]) =/= []
        end,
        30000,
        sources_not_replicated
    ),

    [{nodes, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(nodes, Config)).

init_per_testcase(progressive_across_cluster_feature_disabled, Config) ->
    ok = set_progressive_feature(Config, false),
    Config;
init_per_testcase(_, Config) ->
    ok = set_progressive_feature(Config, true),
    Config.

end_per_testcase(_, Config) ->
    ok = set_progressive_feature(Config, false).

%% =============================================================================
%% TESTS
%% =============================================================================

progressive_across_cluster(Config) ->
    [{_, Node1, _}, {_, _Node2, _}] = ?config(nodes, Config),

    %% Callee on node2: streams N progressive chunks, then the final.
    N = 10,
    Callee = connect(?NODE2_WAMP_PORT),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        _ = [ok = Progress([I], #{}) || I <- lists:seq(1, N)],
        {reply, [<<"final">>]}
    end,
    {ok, _} = bondy_connect:register(Callee, ?PROC, Handler),

    %% Wait until node1 can route to node2's registration: its RIB stub view
    %% has the callee (full entries are not replicated cross-node).
    ok = wait_until(
        fun() ->
            erpc:call(Node1, bondy_registry_rib, match_stubs, [?REALM, ?PROC]) =/=
                []
        end,
        30000,
        registration_not_visible_on_node1
    ),

    %% Caller on node1.
    Caller = connect(?NODE1_WAMP_PORT),
    {ok, Token} = bondy_connect:call_async(Caller, ?PROC, [], #{}, #{
        receive_progress => true
    }),

    %% All N progressive results arrive, flagged and in yield order —
    %% relayed node2 → node1 across the cluster connection.
    _ = [
        begin
            Reply = next_reply(Token),
            ?assertMatch({progress, #{args := [I]}}, Reply),
            {progress, #{details := D}} = Reply,
            ?assertEqual(true, maps:get(progress, D))
        end
     || I <- lists:seq(1, N)
    ],

    %% Exactly one terminal, not flagged progressive.
    Final = next_reply(Token),
    ?assertMatch({ok, #{args := [<<"final">>]}}, Final),
    {ok, #{details := DF}} = Final,
    ?assertNot(maps:get(progress, DF, false)),

    receive
        {bondy_connect, Token, Extra} -> ct:fail({extra_reply, Extra})
    after 300 -> ok
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_across_cluster_feature_disabled(Config) ->
    %% With the dealer feature off on the caller's node, receive_progress
    %% is stripped at node1 before the CALL is forwarded: the callee on
    %% node2 sees no progress fun and the caller gets a single final.
    [{_, Node1, _}, {_, _Node2, _}] = ?config(nodes, Config),

    TestPid = self(),
    Callee = connect(?NODE2_WAMP_PORT),
    Handler = fun(_, _, Details) ->
        TestPid !
            {details_flags, maps:is_key(receive_progress, Details),
                maps:is_key(progress, Details)},
        {reply, [<<"done">>]}
    end,
    Proc = <<"com.example.cluster.progressive.off">>,
    {ok, _} = bondy_connect:register(Callee, Proc, Handler),

    ok = wait_until(
        fun() ->
            erpc:call(Node1, bondy_registry_rib, match_stubs, [?REALM, Proc]) =/=
                []
        end,
        30000,
        registration_not_visible_on_node1
    ),

    Caller = connect(?NODE1_WAMP_PORT),
    {ok, Token} = bondy_connect:call_async(Caller, Proc, [], #{}, #{
        receive_progress => true
    }),

    ?assertMatch({ok, #{args := [<<"done">>]}}, next_reply(Token)),

    receive
        {details_flags, HasReceiveProgress, HasProgressFun} ->
            ?assertNot(HasReceiveProgress),
            ?assertNot(HasProgressFun)
    after 1000 -> ct:fail(no_details_flags)
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_remote_cancel_interrupts_callee(Config) ->
    %% Cancelling a call whose callee is on ANOTHER node: node1 answers
    %% the caller immediately (killnowait) and relays the CANCEL to
    %% node2, which resolves its invocation promise and INTERRUPTs the
    %% callee — killing the streaming worker.
    [{_, Node1, _}, {_, _Node2, _}] = ?config(nodes, Config),

    TestPid = self(),
    Callee = connect(?NODE2_WAMP_PORT),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        TestPid ! {worker, self()},
        Loop = fun Loop() ->
            _ = Progress([<<"tick">>], #{}),
            timer:sleep(50),
            Loop()
        end,
        Loop()
    end,
    Proc = <<"com.example.cluster.progressive.cancel">>,
    {ok, _} = bondy_connect:register(Callee, Proc, Handler),

    ok = wait_until(
        fun() ->
            erpc:call(Node1, bondy_registry_rib, match_stubs, [?REALM, Proc]) =/=
                []
        end,
        30000,
        registration_not_visible_on_node1
    ),

    Caller = connect(?NODE1_WAMP_PORT),
    {ok, Token} = bondy_connect:call_async(Caller, Proc, [], #{}, #{
        receive_progress => true
    }),

    ?assertMatch({progress, _}, next_reply(Token)),

    WorkerPid =
        receive
            {worker, W} -> W
        after 1000 -> ct:fail(no_worker)
        end,
    MRef = monitor(process, WorkerPid),

    ok = bondy_connect:cancel(Caller, Token, killnowait),

    %% The caller gets the cancellation as the terminal reply (progress
    %% already in flight may arrive before it).
    {_, Terminal} = drain_progress(Token, 10000),
    ?assertMatch({error, #{uri := <<"wamp.error.canceled">>}}, Terminal),

    %% ...and the remote worker is killed.
    receive
        {'DOWN', MRef, process, WorkerPid, _} -> ok
    after 5000 ->
        ct:fail(worker_not_interrupted)
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_remote_caller_death_interrupts_callee(Config) ->
    %% The caller's session dies on node1 mid-stream: node1 flushes the
    %% call promise and relays a CANCEL (killnowait) to node2, which
    %% INTERRUPTs the callee — the stream must not keep running for a
    %% dead caller on another node.
    [{_, Node1, _}, {_, _Node2, _}] = ?config(nodes, Config),

    TestPid = self(),
    Callee = connect(?NODE2_WAMP_PORT),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        TestPid ! {worker, self()},
        Loop = fun Loop() ->
            _ = Progress([<<"tick">>], #{}),
            timer:sleep(50),
            Loop()
        end,
        Loop()
    end,
    Proc = <<"com.example.cluster.progressive.abandon">>,
    {ok, _} = bondy_connect:register(Callee, Proc, Handler),

    ok = wait_until(
        fun() ->
            erpc:call(Node1, bondy_registry_rib, match_stubs, [?REALM, Proc]) =/=
                []
        end,
        30000,
        registration_not_visible_on_node1
    ),

    Caller = connect(?NODE1_WAMP_PORT),
    {ok, Token} = bondy_connect:call_async(Caller, Proc, [], #{}, #{
        receive_progress => true
    }),

    ?assertMatch({progress, _}, next_reply(Token)),

    WorkerPid =
        receive
            {worker, W} -> W
        after 1000 -> ct:fail(no_worker)
        end,
    MRef = monitor(process, WorkerPid),

    ok = bondy_connect:disconnect(Caller),

    receive
        {'DOWN', MRef, process, WorkerPid, _} -> ok
    after 5000 ->
        ct:fail(worker_not_interrupted)
    end,

    ok = bondy_connect:disconnect(Callee).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private Drain progress replies until the terminal one arrives.
drain_progress(Token, Timeout) ->
    receive
        {bondy_connect, Token, {progress, _}} ->
            drain_progress(Token, Timeout);
        {bondy_connect, Token, Terminal} ->
            {ok, Terminal}
    after Timeout ->
        ct:fail(no_terminal_reply)
    end.

%% @private
%% Connect with a bounded retry: RBAC data (sources/grants) replicates
%% asynchronously across the cluster, so a first join can race it and be
%% rejected even after the realm object is visible.
connect(Port) ->
    connect(Port, erlang:monotonic_time(millisecond) + 15000).

%% @private
connect(Port, Deadline) ->
    Spec = #{
        transport => tcp,
        endpoint => {?HOST, Port},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    },
    case bondy_connect:connect(Spec) of
        {ok, Conn} ->
            Conn;
        {error, Reason} ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    ct:fail({connect_failed, Port, Reason});
                false ->
                    timer:sleep(200),
                    connect(Port, Deadline)
            end
    end.

%% @private
next_reply(Token) ->
    receive
        {bondy_connect, Token, Reply} -> Reply
    after 10000 ->
        ct:fail(no_reply)
    end.

%% @private
%% The dealer's caller-side gate runs at the origin node, but set the flag
%% on every node for realism.
set_progressive_feature(Config, Bool) when is_boolean(Bool) ->
    _ = [
        ok = erpc:call(Node, bondy_config, set, [
            [wamp, dealer, features, progressive_call_results], Bool
        ])
     || {_, Node, _} <- ?config(nodes, Config)
    ],
    ok.

%% @private
wait_until(Fun, Timeout, FailReason) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_until_loop(Fun, Deadline, FailReason).

%% @private
wait_until_loop(Fun, Deadline, FailReason) ->
    case Fun() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    ct:fail(FailReason);
                false ->
                    timer:sleep(200),
                    wait_until_loop(Fun, Deadline, FailReason)
            end
    end.

%% @private
realm_config() ->
    #{
        uri => ?REALM,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [
                    <<"wamp.register">>,
                    <<"wamp.unregister">>,
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>,
                    <<"wamp.call">>,
                    <<"wamp.cancel">>,
                    <<"wamp.publish">>
                ],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => [<<"anonymous">>]
            }
        ],
        sources => [
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    }.
