%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_retry_cluster_SUITE).
-moduledoc """
The dealer's retry of a call to an idempotent procedure (`bondy_dealer:retry/1`)
when the callee is on another node: a two-node cluster, `bondy_connect_sdk`
callees in the CT controller VM connected to either node, and a router-internal
caller on node1 (`bondy_router_peer:call/5`, the path the HTTP gateway's
`wamp_call` action takes), so every call crosses the cluster relay.

The caller is router-internal because a `bondy_connect_sdk` caller stops
waiting at the call's `timeout`, whatever `_retries` asks for.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-define(REALM, ~"com.example.test.rpc_retry_cluster").
-define(HOST, "127.0.0.1").
-define(NODE1_WAMP_PORT, 18211).
-define(NODE2_WAMP_PORT, 18212).
-define(IDEMPOTENT, #{'_idempotent' => true, invoke => ~"roundrobin"}).

-export([all/0]).
-export([suite/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([remote_timeout_retries_an_idempotent_call/1]).
-export([remote_callee_loss_retries_on_the_caller_node/1]).
-export([remote_call_to_a_procedure_not_idempotent_is_not_retried/1]).
-export([remote_registration_ends_the_wait/1]).
-export([do_call/2]).

all() ->
    [
        remote_timeout_retries_an_idempotent_call,
        remote_callee_loss_retries_on_the_caller_node,
        remote_call_to_a_procedure_not_idempotent_is_not_retried,
        remote_registration_ends_the_wait
    ].

suite() ->
    [{timetrap, {minutes, 5}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(
        [
            {bcx_retry1, [
                {[bondy_router, listeners], peer_listeners(?NODE1_WAMP_PORT)}
            ]},
            {bcx_retry2, [
                {[bondy_router, listeners], peer_listeners(?NODE2_WAMP_PORT)}
            ]}
        ],
        Config
    ),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    %% The callees' REGISTER options are validated in this VM, which runs no
    %% router to declare the extension options.
    ok = bondy_wamp_config:set(extended_options, ?WAMP_EXT_OPTIONS),
    [{_, Node1, _}, {_, Node2, _}] = Nodes,
    {?MODULE, Bin, File} = code:get_object_code(?MODULE),
    {module, ?MODULE} = erpc:call(
        Node1, code, load_binary, [?MODULE, File, Bin]
    ),
    _ = erpc:call(Node1, bondy_realm, create, [
        #{
            uri => ?REALM,
            authmethods => [?WAMP_ANON_AUTH],
            security_enabled => false
        }
    ]),
    ok = wait_until(fun() ->
        element(1, erpc:call(Node2, bondy_realm, lookup, [?REALM])) =:= ok
    end),
    [{nodes, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(nodes, Config)).

%% See `bondy_connect_cluster_rpc_SUITE` for why `admin` is restated.
peer_listeners(WampPort) ->
    [
        {admin, #{
            transport => tcp,
            protocol => http,
            port => 0,
            start_phase => early,
            services => [admin_api, wamp_ws, admin, metrics]
        }},
        {wamp_tcp, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => WampPort,
            enabled => true
        }}
    ].

%% =============================================================================
%% CASES
%% =============================================================================

%% Node2 times the first attempt out at the call's timeout and makes the next
%% one, while node1 waits for the retry deadline.
remote_timeout_retries_an_idempotent_call(Config) ->
    Proc = ~"com.example.test.rpc_retry_cluster.timeout",
    Callee = connect(?NODE2_WAMP_PORT),
    try
        ok = register(Callee, Proc, ?IDEMPOTENT, fun
            (1) ->
                timer:sleep(10000),
                [1];
            (N) ->
                [N]
        end),
        ok = wait_stub(Config, Proc),
        Opts = #{timeout => 1000, '_retries' => 1, '_deadline' => 8000},
        ?assertMatch({ok, #{args := [2]}}, call(Config, Proc, Opts)),
        ?assertEqual([1, 2], attempts(Proc, 0))
    after
        _ = bondy_connect_client:disconnect(Callee)
    end.

%% The callee on node2 goes away with the invocation in flight and node2 has no
%% other registration, so node1 routes the call to the registration it has.
remote_callee_loss_retries_on_the_caller_node(Config) ->
    Proc = ~"com.example.test.rpc_retry_cluster.callee_loss",
    Self = self(),
    Callee2 = connect(?NODE2_WAMP_PORT),
    ok = register(Callee2, Proc, ?IDEMPOTENT, fun(_) ->
        Self ! {invoked, self()},
        receive
            die ->
                _ = spawn(fun() -> bondy_connect_client:disconnect(Callee2) end)
        end,
        timer:sleep(10000),
        [node2]
    end),
    ok = wait_stub(Config, Proc),
    Caller = spawn_call(Config, Proc, #{timeout => 5000, '_retries' => 1}),
    Handler =
        receive
            {invoked, Pid} -> Pid
        after 5000 ->
            ct:fail(node2_not_invoked)
        end,
    Callee1 = connect(?NODE1_WAMP_PORT),
    try
        ok = register(Callee1, Proc, ?IDEMPOTENT, fun(_) -> [~"node1"] end),
        Handler ! die,
        ?assertMatch({ok, #{args := [~"node1"]}}, call_result(Caller)),
        ?assertEqual([1, 1], attempts(Proc, 0))
    after
        _ = bondy_connect_client:disconnect(Callee1),
        _ = bondy_connect_client:disconnect(Callee2)
    end.

%% Node1 waits for the retry deadline, but node2 does not retry, and its ERROR
%% settles the call when the only attempt times out.
remote_call_to_a_procedure_not_idempotent_is_not_retried(Config) ->
    Proc = ~"com.example.test.rpc_retry_cluster.not_idempotent",
    Callee = connect(?NODE2_WAMP_PORT),
    try
        ok = register(Callee, Proc, #{}, fun(N) ->
            timer:sleep(10000),
            [N]
        end),
        ok = wait_stub(Config, Proc),
        Opts = #{timeout => 1000, '_retries' => 1, '_deadline' => 8000},
        Start = erlang:monotonic_time(millisecond),
        ?assertMatch(
            {error, #{error_uri := ?WAMP_ERROR_TIMEOUT}},
            call(Config, Proc, Opts)
        ),
        ?assert(erlang:monotonic_time(millisecond) - Start < 4000),
        ?assertEqual([1], attempts(Proc, 3000))
    after
        _ = bondy_connect_client:disconnect(Callee)
    end.

%% The call finds no registration and waits; the callee then registers on
%% node2, and node1 routes the next attempt there once it learns of it.
remote_registration_ends_the_wait(Config) ->
    Proc = ~"com.example.test.rpc_retry_cluster.wait",
    Opts = #{timeout => 1000, '_retries' => 10, '_deadline' => 20000},
    Caller = spawn_call(Config, Proc, Opts),
    Callee = connect(?NODE2_WAMP_PORT),
    try
        ok = register(Callee, Proc, #{}, fun(N) -> [N] end),
        ?assertMatch({ok, #{args := [1]}}, call_result(Caller)),
        ?assertEqual([1], attempts(Proc, 0))
    after
        _ = bondy_connect_client:disconnect(Callee)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

connect(Port) ->
    connect(Port, erlang:monotonic_time(millisecond) + 15000).

%% A first join can race the realm's replication to the node.
connect(Port, Deadline) ->
    Spec = #{
        transport => tcp,
        endpoint => {?HOST, Port},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    },
    case bondy_connect_client:connect(Spec) of
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

%% Registers `Proc` with a handler that reports each invocation as
%% `{attempt, Proc, N}` and answers what `Reply(N)` returns.
register(Conn, Proc, RegOpts, Reply) ->
    Self = self(),
    Counter = counters:new(1, []),
    Handler = fun(_, _, _) ->
        ok = counters:add(Counter, 1, 1),
        N = counters:get(Counter, 1),
        Self ! {attempt, Proc, N},
        {ok, #{args => Reply(N)}}
    end,
    {ok, _} = bondy_connect_client:register(Conn, Proc, Handler, RegOpts),
    ok.

attempts(Proc, Quiet) ->
    receive
        {attempt, Proc, N} -> [N | attempts(Proc, Quiet)]
    after Quiet ->
        []
    end.

%% Waits until node1 can route `Proc` to node2.
wait_stub(Config, Proc) ->
    [{_, Node1, _}, _] = ?config(nodes, Config),
    wait_until(fun() ->
        erpc:call(Node1, bondy_registry_rib, match_stubs, [?REALM, Proc]) =/= []
    end).

wait_until(Fun) ->
    wait_until(Fun, erlang:monotonic_time(millisecond) + 30000).

wait_until(Fun, Deadline) ->
    case Fun() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    ct:fail(wait_timeout);
                false ->
                    timer:sleep(200),
                    wait_until(Fun, Deadline)
            end
    end.

call(Config, Proc, Opts) ->
    [{_, Node1, _}, _] = ?config(nodes, Config),
    erpc:call(Node1, ?MODULE, do_call, [Proc, Opts], 20000).

spawn_call(Config, Proc, Opts) ->
    Self = self(),
    spawn_link(fun() ->
        Self ! {call_result, self(), call(Config, Proc, Opts)}
    end).

call_result(Pid) ->
    receive
        {call_result, Pid, Result} -> Result
    after 20000 ->
        ct:fail(no_call_result)
    end.

%% Runs on node1. Calls with the shape of context the HTTP gateway's
%% `wamp_call` action builds.
do_call(Proc, Opts) ->
    Peer = {{127, 0, 0, 1}, 0},
    Session = bondy_session:new(?REALM, #{
        peer => Peer,
        is_anonymous => true,
        authid => ~"anonymous",
        authroles => [],
        roles => #{caller => #{features => #{call_timeout => true}}}
    }),
    Ctxt = bondy_context:new(Peer, {http, text, json}, #{session => Session}),
    bondy_router_peer:call(Proc, Opts, [1], #{}, Ctxt).
