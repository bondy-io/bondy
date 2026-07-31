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
        progressive_remote_caller_death_interrupts_callee,
        progressive_input_across_cluster,
        progressive_input_across_cluster_callee_unsupported,
        progressive_input_remote_cancel_interrupts_callee,
        progressive_input_remote_caller_death_interrupts_callee,
        progressive_input_remote_callee_death_errors_caller
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
        {ok, #{args => [<<"final">>]}}
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
        {ok, #{args => [<<"done">>]}}
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
    ?assertMatch(
        {error, #{kind := wamp, uri := <<"wamp.error.canceled">>}}, Terminal
    ),

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

progressive_input_across_cluster(Config) ->
    %% The INPUT mirror of progressive_across_cluster: the caller on node1
    %% opens a progressive call with call_stream and streams the sequence
    %% 1..N as chunks; each CALL crosses node1 -> node2, where the callee
    %% PULLS the chunks (in arrival order) via the input fun and replies with
    %% the collected list. A reordering anywhere on the relayed path would make
    %% the list differ from 1..N.
    [{_, Node1, _}, {_, _Node2, _}] = ?config(nodes, Config),

    N = 10,
    Callee = connect(?NODE2_WAMP_PORT),
    Handler = fun([First], _KWArgs, Details) ->
        Input = maps:get(input, Details),
        {ok, #{args => [collect_input_list(Input, [First])]}}
    end,
    Proc = <<"com.example.cluster.progressive.input">>,
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
    {ok, Token} = bondy_connect:call_stream(Caller, Proc, [1], #{}, #{}),
    _ = [
        ok = bondy_connect:send_input(Caller, Token, [I], #{})
     || I <- lists:seq(2, N - 1)
    ],
    ok = bondy_connect:finish_input(Caller, Token, [N], #{}),

    {ok, #{args := [Collected]}} = next_reply(Token),
    ?assertEqual(lists:seq(1, N), Collected),

    receive
        {bondy_connect, Token, Extra} -> ct:fail({extra_reply, Extra})
    after 300 -> ok
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_input_across_cluster_callee_unsupported(Config) ->
    %% The remote callee did NOT announce progressive_calls. A progressive
    %% input CALL must be rejected at the callee's OWN node (no silent degrade
    %% for a started stream) and the caller must get option_not_allowed — the
    %% handler must never run. This exercises the owner-node callee gate that
    %% closes the distributed hole (the caller gate alone cannot see a remote
    %% callee's features).
    [{_, Node1, _}, {_, _Node2, _}] = ?config(nodes, Config),

    TestPid = self(),
    Callee = connect_roles(
        ?NODE2_WAMP_PORT, callee_roles_without_progressive_calls()
    ),
    Handler = fun(_, _, _) ->
        TestPid ! handler_ran,
        {ok, #{args => [<<"unexpected">>]}}
    end,
    Proc = <<"com.example.cluster.progressive.input.unsupported">>,
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
    {ok, Token} = bondy_connect:call_stream(Caller, Proc, [1], #{}, #{}),

    ?assertMatch(
        {error, #{kind := wamp, uri := <<"wamp.error.option_not_allowed">>}},
        next_reply(Token)
    ),

    receive
        handler_ran -> ct:fail(handler_should_not_run)
    after 300 -> ok
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_input_remote_cancel_interrupts_callee(Config) ->
    %% Cancelling a progressive-INPUT call whose callee is on another node:
    %% the caller opens the stream (call_stream), the callee starts running on
    %% node2, then the caller cancels. node1 answers the caller immediately
    %% (killnowait) and relays the CANCEL to node2, which resolves its
    %% invocation promise and INTERRUPTs the callee worker.
    [{_, Node1, _}, {_, _Node2, _}] = ?config(nodes, Config),

    TestPid = self(),
    Callee = connect(?NODE2_WAMP_PORT),
    Handler = fun(_, _, _Details) ->
        TestPid ! {worker, self()},
        Loop = fun Loop() ->
            timer:sleep(50),
            Loop()
        end,
        Loop()
    end,
    Proc = <<"com.example.cluster.progressive.input.cancel">>,
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
    {ok, Token} = bondy_connect:call_stream(Caller, Proc, [1], #{}, #{}),

    WorkerPid =
        receive
            {worker, W} -> W
        after 5000 -> ct:fail(no_worker)
        end,
    MRef = monitor(process, WorkerPid),

    ok = bondy_connect:cancel(Caller, Token, killnowait),

    {ok, Terminal} = drain_progress(Token, 10000),
    ?assertMatch(
        {error, #{kind := wamp, uri := <<"wamp.error.canceled">>}}, Terminal
    ),

    receive
        {'DOWN', MRef, process, WorkerPid, _} -> ok
    after 5000 ->
        ct:fail(worker_not_interrupted)
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_input_remote_caller_death_interrupts_callee(Config) ->
    %% The caller's session dies on node1 mid-stream: node1 flushes the call
    %% promise and relays a CANCEL (killnowait) to node2, which INTERRUPTs the
    %% callee — an abandoned input stream must not keep a remote worker alive.
    [{_, Node1, _}, {_, _Node2, _}] = ?config(nodes, Config),

    TestPid = self(),
    Callee = connect(?NODE2_WAMP_PORT),
    Handler = fun(_, _, _Details) ->
        TestPid ! {worker, self()},
        Loop = fun Loop() ->
            timer:sleep(50),
            Loop()
        end,
        Loop()
    end,
    Proc = <<"com.example.cluster.progressive.input.abandon">>,
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
    {ok, _Token} = bondy_connect:call_stream(Caller, Proc, [1], #{}, #{}),

    WorkerPid =
        receive
            {worker, W} -> W
        after 5000 -> ct:fail(no_worker)
        end,
    MRef = monitor(process, WorkerPid),

    ok = bondy_connect:disconnect(Caller),

    receive
        {'DOWN', MRef, process, WorkerPid, _} -> ok
    after 5000 ->
        ct:fail(worker_not_interrupted)
    end,

    ok = bondy_connect:disconnect(Callee).

progressive_input_remote_callee_death_errors_caller(Config) ->
    %% The callee's session dies on node2 mid-input-stream: the caller must not
    %% hang waiting to feed a callee that is gone. node2 flushes its invocation
    %% promise and fast-fails the caller, whose call promise matches the ERROR.
    [{_, Node1, _}, {_, _Node2, _}] = ?config(nodes, Config),

    TestPid = self(),
    Callee = connect(?NODE2_WAMP_PORT),
    Handler = fun(_, _, _Details) ->
        TestPid ! {worker, self()},
        Loop = fun Loop() ->
            timer:sleep(50),
            Loop()
        end,
        Loop()
    end,
    Proc = <<"com.example.cluster.progressive.input.calleedeath">>,
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
    {ok, Token} = bondy_connect:call_stream(Caller, Proc, [1], #{}, #{}),

    _ =
        receive
            {worker, _} -> ok
        after 5000 -> ct:fail(no_worker)
        end,

    %% Kill the callee mid-stream.
    ok = bondy_connect:disconnect(Callee),

    %% The caller must receive a terminal error, not hang.
    {ok, Terminal} = drain_progress(Token, 10000),
    ?assertMatch({error, _}, Terminal),

    ok = bondy_connect:disconnect(Caller).

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
%% Connect announcing an explicit `roles` map instead of the client defaults —
%% used to model a callee that deliberately does NOT announce progressive_calls.
%% Retries like connect/1 while RBAC data replicates.
connect_roles(Port, Roles) ->
    connect_roles(Port, Roles, erlang:monotonic_time(millisecond) + 15000).

%% @private
connect_roles(Port, Roles, Deadline) ->
    Spec = #{
        transport => tcp,
        endpoint => {?HOST, Port},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json],
        roles => Roles
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
                    connect_roles(Port, Roles, Deadline)
            end
    end.

%% @private
%% A callee role set that simply OMITS progressive_calls — the router's
%% owner-node gate must then reject a progressive input CALL to this callee.
%% progressive_calls is strict opt-in: a peer that does not announce it does not
%% get it (no inheritance from the router's advertised default), so omission is
%% enough to model an unsupporting callee.
callee_roles_without_progressive_calls() ->
    #{
        callee => #{
            features => #{
                call_canceling => true,
                progressive_call_results => true
            }
        }
    }.

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
        begin
            ok = erpc:call(Node, bondy_config, set, [
                [wamp, dealer, features, progressive_call_results], Bool
            ]),
            ok = erpc:call(Node, bondy_config, set, [
                [wamp, dealer, features, progressive_calls], Bool
            ])
        end
     || {_, Node, _} <- ?config(nodes, Config)
    ],
    ok.

%% @private
%% Order-preserving accumulation of each chunk's single integer, in arrival
%% order, until the final chunk closes the stream.
collect_input_list(Input, Acc) ->
    case Input() of
        {more, [N], _} -> collect_input_list(Input, [N | Acc]);
        {last, [N], _} -> lists:reverse([N | Acc])
    end.

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
