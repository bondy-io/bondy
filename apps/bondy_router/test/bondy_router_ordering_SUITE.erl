%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% The WAMP pairwise ordering guarantees, end to end, on a real cluster:
%% events from one publisher session reach a subscriber session in
%% publication order — across topics — and calls from one caller session
%% reach a callee session in call order — across procedures. Each sequence
%% is submitted through `bondy_router:forward/2' from a single process, as
%% a client transport would, so the cases exercise the ordered flow pool
%% on the publishing node, the per-flow relay partition key on the wire
%% and the keyed flow dispatch on the receiving node.
-module(bondy_router_ordering_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-compile([export_all, nowarn_export_all]).

-define(NODE_NAMES, [bondy_ord1, bondy_ord2]).
%% Cross-node registry convergence rides AAE; budget matches the other
%% cluster suites (see bondy_aae_cluster_SUITE).
-define(CONVERGE_MS, 120000).
-define(SEQ_LEN, 150).

all() ->
    [
        same_node_publish_order,
        cross_node_publish_order,
        cross_node_invocation_order,
        cross_node_publish_order_with_ack
    ].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    _ = [push_module(N) || {_, N, _} <- Nodes],
    [{nodes, Nodes} | Config].

end_per_suite(Config) ->
    Nodes = proplists:get_value(nodes, Config, []),
    catch bondy_ct:stop_cluster(Nodes),
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

%% Publisher and subscriber on the SAME node: two publications by one
%% session must not race across flow pool workers.
same_node_publish_order(Config) ->
    [N1, _N2] = nodes_of(Config),
    Uri = <<"com.bondy.ordering_local">>,
    TopicA = <<"com.ordering.local.alpha">>,
    Prefix = <<"com.ordering.local.pfx.">>,
    TopicB = <<"com.ordering.local.pfx.beta">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = erpc:call(N1, ?MODULE, do_start_probe, [
        Uri,
        [
            {TopicA, #{match => ?EXACT_MATCH}},
            {Prefix, #{match => ?PREFIX_MATCH}}
        ]
    ]),

    ok = erpc:call(N1, ?MODULE, do_publish_seq, [
        Uri, [TopicA, TopicB], ?SEQ_LEN
    ]),

    assert_probe_order(N1, ?SEQ_LEN).

%% Publisher on node 1, subscriber on node 2, subscribed to two topics
%% (one exact, one via prefix): publication order must hold across both
%% (the RFC cross-topic case) through relay egress, wire and ingress.
cross_node_publish_order(Config) ->
    [N1, N2] = nodes_of(Config),
    Uri = <<"com.bondy.ordering_remote">>,
    TopicA = <<"com.ordering.remote.alpha">>,
    Prefix = <<"com.ordering.remote.pfx.">>,
    TopicB = <<"com.ordering.remote.pfx.beta">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = wait_realm(N2, Uri),
    ok = erpc:call(N2, ?MODULE, do_start_probe, [
        Uri,
        [
            {TopicA, #{match => ?EXACT_MATCH}},
            {Prefix, #{match => ?PREFIX_MATCH}}
        ]
    ]),

    %% Publish only once node 1 can route both topics to node 2.
    ok = wait_topic_routable(N1, Uri, TopicA),
    ok = wait_topic_routable(N1, Uri, TopicB),

    ok = erpc:call(N1, ?MODULE, do_publish_seq, [
        Uri, [TopicA, TopicB], ?SEQ_LEN
    ]),

    assert_probe_order(N2, ?SEQ_LEN).

%% Caller on node 1, callee on node 2 registering two procedures: the
%% callee must receive the invocations in call order across both (the RFC
%% 11.2 case).
cross_node_invocation_order(Config) ->
    [N1, N2] = nodes_of(Config),
    Uri = <<"com.bondy.ordering_rpc">>,
    ProcA = <<"com.ordering.rpc.alpha">>,
    ProcB = <<"com.ordering.rpc.beta">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = wait_realm(N2, Uri),
    ok = erpc:call(N2, ?MODULE, do_start_callee, [Uri, [ProcA, ProcB]]),

    ok = wait_remote_registration(N1, Uri, ProcA),
    ok = wait_remote_registration(N1, Uri, ProcB),

    ok = erpc:call(N1, ?MODULE, do_call_seq, [Uri, [ProcA, ProcB], ?SEQ_LEN]),

    assert_probe_order(N2, ?SEQ_LEN).

%% As `cross_node_publish_order' but on a cluster tuned with
%% `router.forward.ack = on' — the other supported relay configuration,
%% which routes through Partisan's acknowledgement machinery.
cross_node_publish_order_with_ack(Config) ->
    Names = [
        {bondy_ord_ack1, [
            {[bondy_router, router], [
                {forward, #{ack => true, retransmission => false}}
            ]},
            {[partisan, peer_port], 18390}
        ]},
        {bondy_ord_ack2, [
            {[bondy_router, router], [
                {forward, #{ack => true, retransmission => false}}
            ]},
            {[partisan, peer_port], 18391}
        ]}
    ],
    Nodes = bondy_ct:start_cluster(Names, Config),
    [A1, A2] = [Node || {_, Node, _} <- Nodes],

    try
        _ = [push_module(N) || N <- [A1, A2]],

        Uri = <<"com.bondy.ordering_ack">>,
        TopicA = <<"com.ordering.ack.alpha">>,
        Prefix = <<"com.ordering.ack.pfx.">>,
        TopicB = <<"com.ordering.ack.pfx.beta">>,

        ok = erpc:call(A1, ?MODULE, do_create_open_realm, [Uri]),
        ok = wait_realm(A2, Uri),
        ok = erpc:call(A2, ?MODULE, do_start_probe, [
            Uri,
            [
                {TopicA, #{match => ?EXACT_MATCH}},
                {Prefix, #{match => ?PREFIX_MATCH}}
            ]
        ]),

        ok = wait_topic_routable(A1, Uri, TopicA),
        ok = wait_topic_routable(A1, Uri, TopicB),

        ok = erpc:call(A1, ?MODULE, do_publish_seq, [
            Uri, [TopicA, TopicB], ?SEQ_LEN
        ]),

        assert_probe_order(A2, ?SEQ_LEN)
    after
        bondy_ct:stop_cluster(Nodes)
    end.

%% =============================================================================
%% CONTROLLER-SIDE HELPERS
%% =============================================================================

%% @private
nodes_of(Config) ->
    [Node || {_, Node, _} <- proplists:get_value(nodes, Config)].

%% @private
push_module(Node) ->
    {?MODULE, Bin, File} = code:get_object_code(?MODULE),
    {module, ?MODULE} = erpc:call(Node, code, load_binary, [?MODULE, File, Bin]),
    ok.

%% @private
%% Polls `Node's probe until `N' deliveries arrived, then asserts they are
%% exactly the sequence 1..N in order: in-order (FIFO), complete (no
%% drops at this volume) and duplicate-free (at-most-once).
assert_probe_order(Node, N) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    Seqs = await_probe(Node, N, Deadline),
    ?assertEqual(lists:seq(1, N), Seqs),
    ok.

%% @private
await_probe(Node, N, Deadline) ->
    Seqs = erpc:call(Node, ?MODULE, do_probe_seqs, []),

    case length(Seqs) >= N of
        true ->
            Seqs;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    %% Return what we have; the assertion will report it.
                    Seqs;
                false ->
                    timer:sleep(100),
                    await_probe(Node, N, Deadline)
            end
    end.

%% @private
wait_realm(Node, Uri) ->
    wait_until(
        fun() -> erpc:call(Node, ?MODULE, do_has_realm, [Uri]) end,
        {realm, Node, Uri}
    ).

%% @private
%% Waits until `OnNode' can route `Topic' to at least one subscriber (the
%% probe is the only one, and it is remote) — the same ptrie-backed check
%% the broker's routing uses.
wait_topic_routable(OnNode, Uri, Topic) ->
    wait_until(
        fun() ->
            erpc:call(OnNode, bondy_registry, has_matches, [
                subscription, Uri, Topic
            ])
        end,
        {topic_routable, OnNode, Topic}
    ).

%% @private
wait_remote_registration(OnNode, Uri, Proc) ->
    wait_until(
        fun() ->
            erpc:call(OnNode, bondy_registry, has_matches, [
                registration, Uri, Proc
            ])
        end,
        {remote_registration, OnNode, Proc}
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
%% A long-lived delivery probe on THIS node, registered as
%% `router_ordering_probe': one stored-session internal ref delivered every
%% EVENT (via subscriptions) or INVOCATION (via registrations) in mailbox
%% order, recording the single positional argument of each.
do_start_probe(RealmUri, Subscriptions) ->
    start_probe(RealmUri, Subscriptions, []).

%% @private
do_start_callee(RealmUri, Procedures) ->
    start_probe(RealmUri, [], Procedures).

%% @private
start_probe(RealmUri, Subscriptions, Procedures) ->
    Parent = self(),
    Pid = spawn(fun() ->
        probe_init(RealmUri, Subscriptions, Procedures, Parent)
    end),
    receive
        {Pid, ready} -> ok
    after 5000 ->
        error(probe_start_timeout)
    end,
    catch unregister(router_ordering_probe),
    true = register(router_ordering_probe, Pid),
    ok.

%% @private
probe_init(RealmUri, Subscriptions, Procedures, Parent) ->
    %% A STORED session backs the entries: the registry requires a session
    %% on add, and the owner self-clean sweep reaps entries whose session
    %% cannot be looked up — this probe must outlive convergence waits.
    Roles =
        case Procedures of
            [] -> #{subscriber => #{}};
            _ -> #{callee => #{}}
        end,
    Session0 = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 10996},
        authid => <<"ordprobe">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => Roles
    }),
    {ok, Session} = bondy_session:store(Session0),
    %% A client-type ref: the representative WAMP subscriber/callee shape,
    %% delivered EVENT and INVOCATION straight to this process.
    Ref = bondy_ref:new(client, self(), bondy_session:id(Session)),

    _ = [
        case bondy_registry:add(subscription, RealmUri, Topic, Opts, Ref) of
            {ok, _, _} -> ok;
            {ok, _} -> ok;
            Other -> error({subscription_add_failed, Other})
        end
     || {Topic, Opts} <- Subscriptions
    ],

    _ = [
        case
            bondy_dealer:register(Proc, #{invoke => ~"single"}, RealmUri, Ref)
        of
            {ok, _} -> ok;
            Other -> error({registration_failed, Other})
        end
     || Proc <- Procedures
    ],

    Parent ! {self(), ready},
    probe_loop([]).

%% @private
probe_loop(Acc) ->
    receive
        {get, From} ->
            From ! {router_ordering_probe_seqs, lists:reverse(Acc)},
            probe_loop(Acc);
        {'$bondy_request', _, _, #event{args = [Seq]}} ->
            probe_loop([Seq | Acc]);
        {'$bondy_request', _, _, #invocation{args = [Seq]}} ->
            probe_loop([Seq | Acc]);
        _Other ->
            probe_loop(Acc)
    end.

%% @private
do_probe_seqs() ->
    router_ordering_probe ! {get, self()},
    receive
        {router_ordering_probe_seqs, Seqs} -> Seqs
    after 5000 ->
        error(probe_drain_timeout)
    end.

%% @private
%% Publishes `[1..N]' from ONE publisher session — the messages enter
%% through `bondy_router:forward/2' as a client transport would, from this
%% single process — alternating over `Topics' so ordering is asserted
%% across topics.
do_publish_seq(RealmUri, Topics, N) ->
    Ctxt = publisher_context(RealmUri),
    ok = lists:foreach(
        fun(Seq) ->
            Topic = lists:nth(1 + (Seq rem length(Topics)), Topics),
            M = bondy_wamp_message:publish(Seq, #{}, Topic, [Seq]),
            {ok, _} = bondy_router:forward(M, Ctxt)
        end,
        lists:seq(1, N)
    ).

%% @private
%% Issues CALL `[1..N]' from ONE caller session through
%% `bondy_router:forward/2', alternating over `Procedures'. Results and
%% errors are irrelevant here (the callee probe never yields) — the
%% assertion is about INVOCATION arrival order at the callee.
do_call_seq(RealmUri, Procedures, N) ->
    Ctxt = caller_context(RealmUri),
    ok = lists:foreach(
        fun(Seq) ->
            Proc = lists:nth(1 + (Seq rem length(Procedures)), Procedures),
            M = bondy_wamp_message:call(Seq, #{}, Proc, [Seq]),
            {ok, _} = bondy_router:forward(M, Ctxt)
        end,
        lists:seq(1, N)
    ).

%% @private
publisher_context(RealmUri) ->
    local_context(RealmUri, 10995, <<"ordpub">>, #{publisher => #{}}).

%% @private
caller_context(RealmUri) ->
    local_context(RealmUri, 10994, <<"ordcall">>, #{caller => #{}}).

%% @private
local_context(RealmUri, Port, AuthId, Roles) ->
    Peer = {{127, 0, 0, 1}, Port},
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => AuthId,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => Roles
    }),
    bondy_context:new(Peer, {ws, text, json}, #{session => Session}).
