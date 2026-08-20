%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% RPC failover when a callee's node dies, end to end on a real cluster.
%%
%% A node's RIB cells outlive the node. Only the node named in the key may
%% write them, so no peer can clear a dead node's registrations, and nothing
%% consumes node-down for registry cleanup. Without a liveness check the node
%% stage of RPC selection therefore keeps handing calls to a corpse, and they
%% time out instead of failing over to a live sibling —
%% `bondy_dealer:prefer_reachable/2' is what stops that.
%%
%% `bondy_router_ordering_SUITE' already covers cross-node invocation with
%% ONE callee node. What is exercised here is the MULTI-CANDIDATE node stage:
%% the same procedure registered on two nodes, which is the only shape in
%% which "failover" means anything.
%%
%% The case asserts BOTH halves deliberately. A test that only checked "the
%% calls still arrived" would pass just as well if something had quietly
%% removed the dead node's stub — a different mechanism, with different
%% consequences, and one whose absence is the whole premise here. So the dead
%% node's stub is asserted to be STILL PRESENT after the kill, and every
%% subsequent invocation is asserted to land on the survivor anyway.
-module(bondy_rpc_failover_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-compile([export_all, nowarn_export_all]).

-define(NODE_NAMES, [bondy_rpcfo1, bondy_rpcfo2]).
%% Cross-node registry convergence rides AAE; budget matches the other
%% cluster suites (see bondy_aae_cluster_SUITE).
-define(CONVERGE_MS, 120000).
%% Round robin over two equally-weighted nodes alternates strictly, so an
%% even count splits exactly in half. Small on purpose: the callee probe
%% never YIELDs, so every call leaves a promise outstanding until it expires.
-define(BASELINE_CALLS, 20).
-define(POST_KILL_CALLS, 20).

all() ->
    [dead_node_callee_is_skipped].

suite() ->
    %% Two Bondy nodes to boot plus AAE convergence, and the case then waits
    %% for a peer to be observed down.
    [{timetrap, {minutes, 10}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    _ = [push_module(N) || {_, N, _} <- Nodes],
    [{nodes, Nodes} | Config].

end_per_suite(Config) ->
    Nodes = proplists:get_value(nodes, Config, []),
    %% The case stops node 2 itself; `stop_cluster/1' catches per node, so
    %% the already-dead one is harmless here.
    try
        bondy_ct:stop_cluster(Nodes)
    catch
        _:_ -> ok
    end,
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

dead_node_callee_is_skipped(Config) ->
    [{_, N1, _}, {_, N2, _} = Node2] = proplists:get_value(nodes, Config),
    Uri = <<"com.bondy.rpc_failover">>,
    Proc = <<"com.failover.rpc.echo">>,
    NS2 = atom_to_binary(N2, utf8),

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = wait_realm(N2, Uri),

    %% The SAME procedure on both nodes. `roundrobin` is what admits more
    %% than one registration; `single` would be rejected on the second node.
    ok = erpc:call(N1, ?MODULE, do_start_callee, [Uri, Proc]),
    ok = erpc:call(N2, ?MODULE, do_start_callee, [Uri, Proc]),
    ok = wait_stub(N1, Uri, Proc, NS2),

    %% Baseline. If calls did not already reach BOTH nodes, killing one
    %% would prove nothing — so this is a precondition, not a nicety.
    ok = erpc:call(N1, ?MODULE, do_call_seq, [Uri, Proc, ?BASELINE_CALLS]),
    ok = wait_count_at_least(N1, 1, "local callee before the kill"),
    ok = wait_count_at_least(N2, 1, "remote callee before the kill"),

    %% `peer:stop/1' halts the node — no graceful shutdown, so no unregister
    %% runs and node 2's RIB cells stay exactly where they were. That is the
    %% permanently-dead-node shape this is about.
    ok = bondy_ct:stop_node(Node2),
    ok = wait_unreachable(N1, N2),

    %% The premise, asserted rather than assumed: the corpse is still a
    %% candidate as far as the registry is concerned.
    ?assert(
        erpc:call(N1, ?MODULE, do_has_stub, [Uri, Proc, NS2]),
        "node 2's RIB stub must survive its death — otherwise this case "
        "is measuring registry cleanup, not selection-time liveness"
    ),

    Before = erpc:call(N1, ?MODULE, do_probe_count, []),
    ok = erpc:call(N1, ?MODULE, do_call_seq, [Uri, Proc, ?POST_KILL_CALLS]),

    %% Every one of them must land locally. Before the fix the rotation
    %% would still hand half of them to the dead node, where they would be
    %% lost and the caller would wait out its timeout.
    ok = wait_count_at_least(
        N1, Before + ?POST_KILL_CALLS, "local callee after the kill"
    ),
    ok.

%% =============================================================================
%% CONTROLLER-SIDE HELPERS
%% =============================================================================

%% @private
push_module(Node) ->
    {?MODULE, Bin, File} = code:get_object_code(?MODULE),
    {module, ?MODULE} = erpc:call(Node, code, load_binary, [?MODULE, File, Bin]),
    ok.

%% @private
wait_realm(Node, Uri) ->
    wait_until(
        fun() -> erpc:call(Node, ?MODULE, do_has_realm, [Uri]) end,
        {realm, Node, Uri}
    ).

%% @private
%% Waits until `OnNode' sees `Nodestring' advertising `Proc' in the RIB —
%% the exact input the dealer's node stage reads.
wait_stub(OnNode, Uri, Proc, Nodestring) ->
    wait_until(
        fun() ->
            erpc:call(OnNode, ?MODULE, do_has_stub, [Uri, Proc, Nodestring])
        end,
        {stub, OnNode, Nodestring}
    ).

%% @private
%% Waits until `OnNode' observes `Peer' as disconnected. Polled rather than
%% slept: this is the state the selection filter reads, so the case must not
%% race ahead of it.
wait_unreachable(OnNode, Peer) ->
    wait_until(
        fun() ->
            not erpc:call(
                OnNode, partisan_peer_connections, is_connected, [Peer]
            )
        end,
        {unreachable, OnNode, Peer}
    ).

%% @private
wait_count_at_least(Node, N, What) ->
    wait_until(
        fun() -> erpc:call(Node, ?MODULE, do_probe_count, []) >= N end,
        {invocation_count, Node, N, What}
    ).

%% @private
wait_until(Fun, Tag) ->
    wait_until(Fun, Tag, erlang:monotonic_time(millisecond) + ?CONVERGE_MS).

%% @private
wait_until(Fun, Tag, Deadline) ->
    case Fun() of
        true ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({wait_timeout, Tag});
                false ->
                    timer:sleep(100),
                    wait_until(Fun, Tag, Deadline)
            end
    end.

%% =============================================================================
%% PEER-SIDE HELPERS (run on the cluster nodes via erpc)
%% =============================================================================

%% @private
do_create_open_realm(Uri) ->
    Realm = bondy_realm:create(Uri),
    ok = bondy_realm:disable_security(Realm),
    ok.

%% @private
do_has_realm(Uri) ->
    bondy_realm:exists(Uri).

%% @private
do_has_stub(RealmUri, Proc, Nodestring) ->
    lists:any(
        fun({_Pattern, _Policy, Ns}) -> lists:keymember(Nodestring, 1, Ns) end,
        bondy_registry_rib:match_stubs(RealmUri, Proc)
    ).

%% @private
%% A long-lived callee on THIS node that counts the INVOCATIONs it receives.
%% It never YIELDs — the assertion is about where invocations land, not about
%% results — so callers time out, which is why the call counts stay small.
do_start_callee(RealmUri, Proc) ->
    Parent = self(),
    Pid = spawn(fun() -> callee_init(RealmUri, Proc, Parent) end),
    receive
        {Pid, ready} -> ok
    after 5000 ->
        error(callee_start_timeout)
    end,
    try
        unregister(rpc_failover_callee)
    catch
        _:_ -> ok
    end,
    true = register(rpc_failover_callee, Pid),
    ok.

%% @private
callee_init(RealmUri, Proc, Parent) ->
    %% A STORED session backs the entry: the registry requires a session on
    %% add, and the owner self-clean sweep reaps entries whose session cannot
    %% be looked up — this callee must outlive the convergence waits.
    Session0 = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 10993},
        authid => <<"failovercallee">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{callee => #{}}
    }),
    {ok, Session} = bondy_session:store(Session0),
    Ref = bondy_ref:new(client, self(), bondy_session:id(Session)),

    Opts = #{invoke => ?INVOKE_ROUND_ROBIN},

    case bondy_dealer:register(Proc, Opts, RealmUri, Ref) of
        {ok, _} -> ok;
        Other -> error({registration_failed, Other})
    end,

    Parent ! {self(), ready},
    callee_loop(0).

%% @private
callee_loop(Count) ->
    receive
        {count, From} ->
            From ! {rpc_failover_callee_count, Count},
            callee_loop(Count);
        {'$bondy_request', _, _, #invocation{}} ->
            callee_loop(Count + 1);
        _Other ->
            callee_loop(Count)
    end.

%% @private
do_probe_count() ->
    rpc_failover_callee ! {count, self()},
    receive
        {rpc_failover_callee_count, Count} -> Count
    after 5000 ->
        error(callee_count_timeout)
    end.

%% @private
%% Issues CALL `[1..N]' from ONE caller session through
%% `bondy_router:forward/2', as a client transport would.
do_call_seq(RealmUri, Proc, N) ->
    Ctxt = caller_context(RealmUri),
    ok = lists:foreach(
        fun(Seq) ->
            M = bondy_wamp_message:call(Seq, #{}, Proc, [Seq]),
            {ok, _} = bondy_router:forward(M, Ctxt)
        end,
        lists:seq(1, N)
    ).

%% @private
caller_context(RealmUri) ->
    Peer = {{127, 0, 0, 1}, 10992},
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => <<"failovercaller">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}}
    }),
    bondy_context:new(Peer, {ws, text, json}, #{session => Session}).
