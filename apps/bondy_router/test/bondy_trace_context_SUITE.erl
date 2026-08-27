%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% W3C trace-context propagation through the router, end to end on a real
%% cluster: the `_traceparent' / `_tracestate' / `_baggage' extension
%% options of a CALL reach the callee verbatim in INVOCATION.Details, and
%% those of a PUBLISH reach the subscriber verbatim in EVENT.Details —
%% same-node and across the relay. Each sequence enters through
%% `bondy_router:forward/2' as a client transport would.
%%
%% Also pinned, in both directions: a message sent WITHOUT trace options
%% produces details WITHOUT the trace keys (no defaults, no leakage), and
%% an UNDECLARED `_'-prefixed option is stripped at message construction —
%% the extended-options declaration is load-bearing, not decorative.
-module(bondy_trace_context_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-compile([export_all, nowarn_export_all]).

-define(NODE_NAMES, [bondy_trace1, bondy_trace2]).
%% Cross-node registry convergence rides AAE; budget matches the other
%% cluster suites (see bondy_aae_cluster_SUITE).
-define(CONVERGE_MS, 120000).

%% The W3C Trace Context spec's own example values, plus a Baggage header
%% with a percent-encoded value — pass-through must not decode it.
-define(TP, <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>).
-define(TS, <<"congo=t61rcWkgMzE,rojo=00f067aa0ba902b7">>).
-define(BG, <<"userId=alice,serverNode=DF%2028">>).

all() ->
    [
        wire_declaration_gates_options,
        same_node_call_trace_context,
        cross_node_call_trace_context,
        same_node_publish_trace_context,
        cross_node_publish_trace_context,
        same_node_call_latency_trace,
        cross_node_call_latency_trace,
        same_node_call_error_outcome,
        cross_node_call_error_outcome,
        minted_root_context
    ].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    _ = [push_module(N) || {_, N, _} <- Nodes],
    [{nodes, Nodes} | Config].

end_per_suite(Config) ->
    Nodes = proplists:get_value(nodes, Config, []),
    try
        bondy_ct:stop_cluster(Nodes)
    catch
        _:_ -> ok
    end,
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

%% Message construction under the node's extended-options declaration:
%% wire-shaped (binary) trace keys are accepted and canonicalized to their
%% atom form, an undeclared `_'-prefixed key is silently stripped.
wire_declaration_gates_options(Config) ->
    [N1, _] = nodes_of(Config),
    ok = erpc:call(N1, ?MODULE, do_assert_wire_declaration, []).

same_node_call_trace_context(Config) ->
    [N1, _] = nodes_of(Config),
    Uri = <<"com.bondy.trace_rpc_local">>,
    Proc = <<"com.trace.rpc.local.echo">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = erpc:call(N1, ?MODULE, do_start_callee, [Uri, [Proc]]),
    ok = erpc:call(N1, ?MODULE, do_call_pair, [Uri, Proc]),

    assert_trace_pair(N1).

cross_node_call_trace_context(Config) ->
    [N1, N2] = nodes_of(Config),
    Uri = <<"com.bondy.trace_rpc_remote">>,
    Proc = <<"com.trace.rpc.remote.echo">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = wait_realm(N2, Uri),
    ok = erpc:call(N2, ?MODULE, do_start_callee, [Uri, [Proc]]),
    ok = wait_remote_registration(N1, Uri, Proc),
    ok = erpc:call(N1, ?MODULE, do_call_pair, [Uri, Proc]),

    assert_trace_pair(N2).

same_node_publish_trace_context(Config) ->
    [N1, _] = nodes_of(Config),
    Uri = <<"com.bondy.trace_pub_local">>,
    Topic = <<"com.trace.pub.local.alpha">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = erpc:call(N1, ?MODULE, do_start_probe, [
        Uri, [{Topic, #{match => ?EXACT_MATCH}}]
    ]),
    ok = erpc:call(N1, ?MODULE, do_publish_pair, [Uri, Topic]),

    assert_trace_pair(N1).

cross_node_publish_trace_context(Config) ->
    [N1, N2] = nodes_of(Config),
    Uri = <<"com.bondy.trace_pub_remote">>,
    Topic = <<"com.trace.pub.remote.alpha">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = wait_realm(N2, Uri),
    ok = erpc:call(N2, ?MODULE, do_start_probe, [
        Uri, [{Topic, #{match => ?EXACT_MATCH}}]
    ]),
    ok = wait_topic_routable(N1, Uri, Topic),
    ok = erpc:call(N1, ?MODULE, do_publish_pair, [Uri, Topic]),

    assert_trace_pair(N2).

%% The router-hop span seat: settling a call emits `[bondy, rpc,
%% latency]` whose `trace` metadata is the call's W3C context (header-
%% named binary keys, verbatim), `#{}` for an untraced call. A local
%% caller and local callee share one invocation promise, so one settle
%% emits BOTH kinds — each must carry the context.
same_node_call_latency_trace(Config) ->
    [N1, _] = nodes_of(Config),
    Uri = <<"com.bondy.trace_lat_local">>,
    Proc = <<"com.trace.lat.local.echo">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = erpc:call(N1, ?MODULE, do_start_yielding_callee, [Uri, [Proc]]),
    ok = erpc:call(N1, ?MODULE, do_attach_latency_capture, [self()]),
    try
        ok = erpc:call(N1, ?MODULE, do_call_await, [Uri, Proc, traced]),
        Traced = collect_latency(Proc, 2),
        ?assertEqual(
            [call, invocation],
            lists:sort([maps:get(kind, M) || {_, M} <- Traced])
        ),
        ?assertEqual(
            [wire_trace(), wire_trace()],
            [maps:get(trace, M) || {_, M} <- Traced]
        ),
        %% A YIELD settlement is a `success` outcome on both legs.
        ?assertEqual(
            [success, success],
            [maps:get(outcome, M) || {_, M} <- Traced]
        ),

        ok = erpc:call(N1, ?MODULE, do_call_await, [Uri, Proc, plain]),
        Plain = collect_latency(Proc, 2),
        ?assertEqual([#{}, #{}], [maps:get(trace, M) || {_, M} <- Plain])
    after
        detach_latency_capture([N1])
    end.

%% A local call settled by the callee's WAMP ERROR (site: the dealer's
%% `#error{request_type = ?INVOCATION}` clause): both legs of the one
%% invocation promise emit outcome `error`, trace context intact.
same_node_call_error_outcome(Config) ->
    [N1, _] = nodes_of(Config),
    Uri = <<"com.bondy.trace_err_local">>,
    Proc = <<"com.trace.err.local.fail">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = erpc:call(N1, ?MODULE, do_start_erroring_callee, [Uri, [Proc]]),
    ok = erpc:call(N1, ?MODULE, do_attach_latency_capture, [self()]),
    try
        ok = erpc:call(N1, ?MODULE, do_call_await_error, [Uri, Proc]),
        Events = collect_latency(Proc, 2),
        ?assertEqual(
            [call, invocation],
            lists:sort([maps:get(kind, M) || {_, M} <- Events])
        ),
        ?assertEqual(
            [error, error],
            [maps:get(outcome, M) || {_, M} <- Events]
        ),
        ?assertEqual(
            [wire_trace(), wire_trace()],
            [maps:get(trace, M) || {_, M} <- Events]
        )
    after
        detach_latency_capture([N1])
    end.

%% Cross-node: the caller's node observes the `call` leg (its call
%% promise settles on the returned RESULT), the callee's node the
%% `invocation` leg — each with the full context of its own message
%% (CALL options on the caller's node, INVOCATION details on the
%% callee's), so a handler on either node can export its leg's span.
cross_node_call_latency_trace(Config) ->
    [N1, N2] = nodes_of(Config),
    Uri = <<"com.bondy.trace_lat_remote">>,
    Proc = <<"com.trace.lat.remote.echo">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = wait_realm(N2, Uri),
    ok = erpc:call(N2, ?MODULE, do_start_yielding_callee, [Uri, [Proc]]),
    ok = wait_remote_registration(N1, Uri, Proc),
    ok = erpc:call(N1, ?MODULE, do_attach_latency_capture, [self()]),
    ok = erpc:call(N2, ?MODULE, do_attach_latency_capture, [self()]),
    try
        ok = erpc:call(N1, ?MODULE, do_call_await, [Uri, Proc, traced]),
        Traced = collect_latency(Proc, 2),
        ?assertEqual(
            lists:sort([{N1, call}, {N2, invocation}]),
            lists:sort([{Node, maps:get(kind, M)} || {Node, M} <- Traced])
        ),
        ?assertEqual(
            [wire_trace(), wire_trace()],
            [maps:get(trace, M) || {_, M} <- Traced]
        ),
        ?assertEqual(
            [success, success],
            [maps:get(outcome, M) || {_, M} <- Traced]
        ),

        ok = erpc:call(N1, ?MODULE, do_call_await, [Uri, Proc, plain]),
        Plain = collect_latency(Proc, 2),
        ?assertEqual([#{}, #{}], [maps:get(trace, M) || {_, M} <- Plain])
    after
        detach_latency_capture([N1, N2])
    end.

%% Cross-node ERROR: the callee's node settles its invocation promise on
%% the local callee's ERROR (`#error{request_type = ?INVOCATION}`); the
%% caller's node settles its call promise on the forwarded
%% `#error{request_type = ?CALL}` — the two distinct dealer error seats.
%% Each leg reports outcome `error` on its own node.
cross_node_call_error_outcome(Config) ->
    [N1, N2] = nodes_of(Config),
    Uri = <<"com.bondy.trace_err_remote">>,
    Proc = <<"com.trace.err.remote.fail">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = wait_realm(N2, Uri),
    ok = erpc:call(N2, ?MODULE, do_start_erroring_callee, [Uri, [Proc]]),
    ok = wait_remote_registration(N1, Uri, Proc),
    ok = erpc:call(N1, ?MODULE, do_attach_latency_capture, [self()]),
    ok = erpc:call(N2, ?MODULE, do_attach_latency_capture, [self()]),
    try
        ok = erpc:call(N1, ?MODULE, do_call_await_error, [Uri, Proc]),
        Events = collect_latency(Proc, 2),
        ?assertEqual(
            lists:sort([{N1, call}, {N2, invocation}]),
            lists:sort([{Node, maps:get(kind, M)} || {Node, M} <- Events])
        ),
        ?assertEqual(
            [error, error],
            [maps:get(outcome, M) || {_, M} <- Events]
        ),
        ?assertEqual(
            [wire_trace(), wire_trace()],
            [maps:get(trace, M) || {_, M} <- Events]
        )
    after
        detach_latency_capture([N1, N2])
    end.

%% With `tracing.mint.enabled` on, an UNTRACED cross-node call gets a
%% W3C context minted ONCE at the caller's node dealer (the trace
%% boundary): both latency legs — the caller-node call promise (from
%% CALL options) and the callee-node invocation promise (from INVOCATION
%% details) — carry the SAME freshly minted sampled traceparent, proving
%% the mint rides the existing carry seats across the cluster. A call
%% that arrives WITH a context keeps it verbatim: minting never
%% overwrites. Runs LAST: every earlier case pins the mint-off default.
minted_root_context(Config) ->
    [N1, N2] = nodes_of(Config),
    Uri = <<"com.bondy.trace_mint">>,
    Proc = <<"com.trace.mint.echo">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = wait_realm(N2, Uri),
    ok = erpc:call(N2, ?MODULE, do_start_yielding_callee, [Uri, [Proc]]),
    ok = wait_remote_registration(N1, Uri, Proc),
    ok = erpc:call(N1, ?MODULE, do_attach_latency_capture, [self()]),
    ok = erpc:call(N2, ?MODULE, do_attach_latency_capture, [self()]),
    MintOn = [{enabled, true}, {ratio, 1.0}],
    try
        ok = erpc:call(N1, bondy_config, set, [tracing_mint, MintOn]),
        ok = erpc:call(N2, bondy_config, set, [tracing_mint, MintOn]),

        ok = erpc:call(N1, ?MODULE, do_call_await, [Uri, Proc, plain]),
        Events = collect_latency(Proc, 2),
        ?assertEqual(
            lists:sort([{N1, call}, {N2, invocation}]),
            lists:sort([{Node, maps:get(kind, M)} || {Node, M} <- Events])
        ),
        [TPa, TPb] = [
            maps:get(<<"traceparent">>, maps:get(trace, M))
         || {_, M} <- Events
        ],
        ?assertEqual(TPa, TPb),
        ?assertMatch(
            {match, _}, re:run(TPa, "^00-[0-9a-f]{32}-[0-9a-f]{16}-01$")
        ),
        %% The span-id-bound mint marker rides BOTH legs: it is what
        %% lets the bridge realize the pre-allocated span id as the
        %% trace's root span at the minting node.
        <<"00-", _:32/binary, "-", SpanHex:16/binary, "-01">> = TPa,
        ?assertEqual(
            [<<"bondy=", SpanHex/binary>>, <<"bondy=", SpanHex/binary>>],
            [maps:get(<<"tracestate">>, maps:get(trace, M)) || {_, M} <- Events]
        ),

        %% A caller-supplied context is honoured, never re-minted.
        ok = erpc:call(N1, ?MODULE, do_call_await, [Uri, Proc, traced]),
        Traced = collect_latency(Proc, 2),
        ?assertEqual(
            [wire_trace(), wire_trace()],
            [maps:get(trace, M) || {_, M} <- Traced]
        )
    after
        _ = erpc:call(N1, bondy_config, set, [
            tracing_mint, [{enabled, false}]
        ]),
        _ = erpc:call(N2, bondy_config, set, [
            tracing_mint, [{enabled, false}]
        ]),
        detach_latency_capture([N1, N2])
    end.

%% =============================================================================
%% ASSERTIONS
%% =============================================================================

%% @private
%% Every case sends exactly two messages from one session: the first WITH
%% the three trace options, the second WITHOUT any. Per-publisher FIFO
%% (pinned by bondy_router_ordering_SUITE) makes the arrival order the
%% send order.
assert_trace_pair(Node) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    [First, Second] = await_probe(Node, 2, Deadline),
    ?assertEqual(?TP, maps:get('_traceparent', First)),
    ?assertEqual(?TS, maps:get('_tracestate', First)),
    ?assertEqual(?BG, maps:get('_baggage', First)),
    %% No defaults, no leakage from the previous message.
    ?assertNot(maps:is_key('_traceparent', Second)),
    ?assertNot(maps:is_key('_tracestate', Second)),
    ?assertNot(maps:is_key('_baggage', Second)).

%% @private
%% Collects N `[bondy, rpc, latency]` captures for `Proc` (each is
%% `{Node, Metadata}`), ignoring events for other procedures (internal
%% traffic on the shared cluster). Both legs are emitted before the
%% caller receives its RESULT, so after do_call_await returns the
%% events are in flight at worst.
collect_latency(Proc, N) ->
    collect_latency(Proc, N, []).

%% @private
collect_latency(_, 0, Acc) ->
    lists:reverse(Acc);
collect_latency(Proc, N, Acc) ->
    receive
        {rpc_latency, Node, #{procedure_uri := Proc} = Meta} ->
            collect_latency(Proc, N - 1, [{Node, Meta} | Acc]);
        {rpc_latency, _, _} ->
            collect_latency(Proc, N, Acc)
    after 30000 ->
        error({latency_capture_timeout, Proc, N, Acc})
    end.

%% @private
await_probe(Node, N, Deadline) ->
    Details = erpc:call(Node, ?MODULE, do_probe_details, []),
    case length(Details) >= N of
        true ->
            Details;
        false ->
            erlang:monotonic_time(millisecond) < Deadline orelse
                error({probe_timeout, Node, Details}),
            timer:sleep(100),
            await_probe(Node, N, Deadline)
    end.

%% =============================================================================
%% REMOTE FUNCTIONS (run on the peer nodes via erpc)
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
do_assert_wire_declaration() ->
    WireOpts = #{
        <<"_traceparent">> => ?TP,
        <<"_tracestate">> => ?TS,
        <<"_baggage">> => ?BG,
        <<"_notdeclared">> => <<"x">>
    },
    #call{options = CallOpts} =
        bondy_wamp_message:call(1, WireOpts, <<"com.trace.wire.p">>, []),
    ?assertEqual(?TP, maps:get('_traceparent', CallOpts)),
    ?assertEqual(?TS, maps:get('_tracestate', CallOpts)),
    ?assertEqual(?BG, maps:get('_baggage', CallOpts)),
    ?assertNot(maps:is_key('_notdeclared', CallOpts)),
    ?assertNot(maps:is_key(<<"_notdeclared">>, CallOpts)),

    #publish{options = PubOpts} =
        bondy_wamp_message:publish(1, WireOpts, <<"com.trace.wire.t">>, []),
    ?assertEqual(?TP, maps:get('_traceparent', PubOpts)),
    ?assertEqual(?TS, maps:get('_tracestate', PubOpts)),
    ?assertEqual(?BG, maps:get('_baggage', PubOpts)),
    ?assertNot(maps:is_key('_notdeclared', PubOpts)),
    ?assertNot(maps:is_key(<<"_notdeclared">>, PubOpts)),
    ok.

%% @private
do_start_probe(RealmUri, Subscriptions) ->
    start_probe(RealmUri, Subscriptions, [], none).

%% @private
do_start_callee(RealmUri, Procedures) ->
    start_probe(RealmUri, [], Procedures, none).

%% @private
do_start_yielding_callee(RealmUri, Procedures) ->
    start_probe(RealmUri, [], Procedures, yield).

%% @private
%% As do_start_yielding_callee/2, but the probe answers every
%% INVOCATION with a WAMP ERROR — the settlement the error-outcome
%% cases observe.
do_start_erroring_callee(RealmUri, Procedures) ->
    start_probe(RealmUri, [], Procedures, error).

%% @private
%% Forwards every `[bondy, rpc, latency]` event's metadata to `To`
%% (the ct process on the master node) tagged with the emitting node.
do_attach_latency_capture(To) ->
    telemetry:attach(
        {?MODULE, latency_capture},
        [bondy, rpc, latency],
        fun(_, _, Meta, _) -> To ! {rpc_latency, node(), Meta} end,
        undefined
    ).

%% @private
do_detach_latency_capture() ->
    telemetry:detach({?MODULE, latency_capture}).

%% @private
detach_latency_capture(Nodes) ->
    lists:foreach(
        fun(N) ->
            try
                erpc:call(N, ?MODULE, do_detach_latency_capture, [])
            catch
                _:_ -> ok
            end
        end,
        Nodes
    ).

%% @private
%% Sends one CALL and blocks until its RESULT arrives, so the promise
%% has settled (and its latency events were emitted) when this returns.
do_call_await(RealmUri, Proc, Mode) ->
    Ctxt = caller_context(RealmUri),
    Opts =
        case Mode of
            traced -> trace_opts();
            plain -> #{}
        end,
    M = bondy_wamp_message:call(1, Opts, Proc, [1]),
    {ok, _} = bondy_router:forward(M, Ctxt),
    receive
        {'$bondy_request', _, _, #result{}} ->
            ok;
        {'$bondy_request', _, _, #error{} = E} ->
            error({call_failed, E})
    after 30000 ->
        error(call_result_timeout)
    end.

%% @private
%% As do_call_await/3 (always traced) but the call is expected to settle
%% with the erroring probe's WAMP ERROR.
do_call_await_error(RealmUri, Proc) ->
    Ctxt = caller_context(RealmUri),
    M = bondy_wamp_message:call(1, trace_opts(), Proc, [1]),
    {ok, _} = bondy_router:forward(M, Ctxt),
    receive
        {'$bondy_request', _, _, #error{
            error_uri = <<"com.example.probe_error">>
        }} ->
            ok;
        {'$bondy_request', _, _, #result{} = R} ->
            error({unexpected_result, R})
    after 30000 ->
        error(call_error_timeout)
    end.

%% @private
%% Sends one message WITH the trace options and one WITHOUT, from the
%% same session and process (see assert_trace_pair/1). Options use the
%% wire (binary-key) shape a client transport would deliver.
do_call_pair(RealmUri, Proc) ->
    Ctxt = caller_context(RealmUri),
    Traced = bondy_wamp_message:call(1, trace_opts(), Proc, [1]),
    {ok, _} = bondy_router:forward(Traced, Ctxt),
    Plain = bondy_wamp_message:call(2, #{}, Proc, [2]),
    {ok, _} = bondy_router:forward(Plain, Ctxt),
    ok.

%% @private
do_publish_pair(RealmUri, Topic) ->
    Ctxt = publisher_context(RealmUri),
    Traced = bondy_wamp_message:publish(1, trace_opts(), Topic, [1]),
    {ok, _} = bondy_router:forward(Traced, Ctxt),
    Plain = bondy_wamp_message:publish(2, #{}, Topic, [2]),
    {ok, _} = bondy_router:forward(Plain, Ctxt),
    ok.

%% @private
do_probe_details() ->
    trace_ctx_probe ! {get, self()},
    receive
        {trace_ctx_probe_details, Details} -> Details
    after 5000 ->
        error(probe_drain_timeout)
    end.

%% @private
trace_opts() ->
    #{
        <<"_traceparent">> => ?TP,
        <<"_tracestate">> => ?TS,
        <<"_baggage">> => ?BG
    }.

%% @private
%% The `trace' telemetry-metadata shape (see
%% bondy_telemetry:trace_meta/1) the latency events must carry for a
%% call traced with trace_opts/0.
wire_trace() ->
    #{
        <<"traceparent">> => ?TP,
        <<"tracestate">> => ?TS,
        <<"baggage">> => ?BG
    }.

%% =============================================================================
%% PROBE
%% =============================================================================

%% @private
start_probe(RealmUri, Subscriptions, Procedures, ReplyMode) ->
    Parent = self(),
    Pid = spawn(fun() ->
        probe_init(RealmUri, Subscriptions, Procedures, ReplyMode, Parent)
    end),
    receive
        {Pid, ready} -> ok
    after 5000 ->
        error(probe_start_timeout)
    end,
    try
        unregister(trace_ctx_probe)
    catch
        error:badarg -> ok
    end,
    true = register(trace_ctx_probe, Pid),
    ok.

%% @private
%% A stored session backs the entries (the registry requires one on add,
%% and the owner self-clean sweep reaps entries whose session cannot be
%% looked up); a client-type ref delivers EVENT and INVOCATION straight to
%% this process. Same shape as bondy_router_ordering_SUITE's probe, but
%% recording each delivery's DETAILS map. `ReplyMode' selects how the
%% probe answers an INVOCATION through the router, as a callee client
%% would: `yield' — an empty YIELD; `error' — a WAMP ERROR; `none' —
%% record only. The settlement is what the latency/outcome cases
%% observe.
probe_init(RealmUri, Subscriptions, Procedures, ReplyMode, Parent) ->
    Roles =
        case Procedures of
            [] -> #{subscriber => #{}};
            _ -> #{callee => #{}}
        end,
    Session0 = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 10993},
        authid => <<"traceprobe">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => Roles
    }),
    {ok, Session} = bondy_session:store(Session0),
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

    %% The reply context's ref carries this session (and this process),
    %% matching the registrations' callee session id — the key the
    %% dealer resolves the YIELD/ERROR against.
    Ctxt =
        case ReplyMode of
            none ->
                undefined;
            _ ->
                bondy_context:new(
                    bondy_session:peer(Session),
                    {ws, text, json},
                    #{session => Session}
                )
        end,

    Parent ! {self(), ready},
    probe_loop([], ReplyMode, Ctxt).

%% @private
probe_loop(Acc, ReplyMode, Ctxt) ->
    receive
        {get, From} ->
            From ! {trace_ctx_probe_details, lists:reverse(Acc)},
            probe_loop(Acc, ReplyMode, Ctxt);
        {'$bondy_request', _, _, #event{details = Details}} ->
            probe_loop([Details | Acc], ReplyMode, Ctxt);
        {'$bondy_request', _, _, #invocation{} = I} when Ctxt =/= undefined ->
            Reply =
                case ReplyMode of
                    yield ->
                        bondy_wamp_message:yield(I#invocation.request_id, #{});
                    error ->
                        bondy_wamp_message:error(
                            ?INVOCATION,
                            I#invocation.request_id,
                            #{},
                            <<"com.example.probe_error">>
                        )
                end,
            {ok, _} = bondy_router:forward(Reply, Ctxt),
            probe_loop([I#invocation.details | Acc], ReplyMode, Ctxt);
        {'$bondy_request', _, _, #invocation{details = Details}} ->
            probe_loop([Details | Acc], ReplyMode, Ctxt);
        _Other ->
            probe_loop(Acc, ReplyMode, Ctxt)
    end.

%% =============================================================================
%% HELPERS
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
publisher_context(RealmUri) ->
    local_context(RealmUri, 10992, <<"tracepub">>, #{publisher => #{}}).

%% @private
caller_context(RealmUri) ->
    local_context(RealmUri, 10991, <<"tracecall">>, #{caller => #{}}).

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

%% @private
wait_realm(Node, Uri) ->
    wait_until(
        fun() -> erpc:call(Node, ?MODULE, do_has_realm, [Uri]) end,
        {realm, Node, Uri}
    ).

%% @private
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
            erlang:monotonic_time(millisecond) < Deadline orelse
                error({timeout, Tag}),
            timer:sleep(100),
            wait_until(Fun, Tag, Deadline)
    end.
