%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end RPC across a REAL bridge relay: two sovereign routers (no
%% Partisan membership, no replicated registry), the edge dialing the
%% core's `bridge_relay` listener and authenticating by cryptosign. A
%% callee registered on the edge is proxied into the core's registry by
%% the bridge, and a core-side caller's CALL crosses the bridge on the
%% dealer's entry-addressed forward path — the path a clustered suite
%% can never reach, since RIB routing node-addresses every cluster
%% forward.
%%
%% Pinned here: the cluster-forward hop marker
%% (`bondy_telemetry:maybe_hop_trace/1`) is stamped on that path too —
%% the delivered INVOCATION details and BOTH legs' latency events carry
%% the SAME `bondyhop=` id with traceparent/baggage verbatim, and an
%% untraced call still carries nothing. The probe, caller, capture and
%% assertion machinery is `bondy_trace_context_SUITE`'s, reused
%% cross-module so the bridged path is held to exactly the assertions
%% the RIB path already passes.
-module(bondy_bridge_relay_rpc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").

-compile([export_all, nowarn_export_all]).

-define(CORE, bondy_bridge_rpc_core).
-define(EDGE, bondy_bridge_rpc_edge).
-define(REALM, <<"com.bondy.bridge_rpc">>).
-define(PROC, <<"com.bridge.rpc.echo">>).
-define(DEVICE, <<"ct_device">>).

all() ->
    [
        bridged_call_hop_trace,
        crashing_server_redials_with_backoff
    ].

init_per_suite(Config) ->
    %% The core node declares a `bridge_relay` listener on an ephemeral
    %% port. Setting the inventory replaces the per-node default, so the
    %% `admin` entry is restated at port 0 — left out, the listener
    %% manager's default binds it at the fixed port 18081 and peers on
    %% this host race for it (see bondy_ct:node_env/2).
    Listeners = [
        {admin, #{
            transport => tcp,
            protocol => http,
            port => 0,
            start_phase => early,
            services => [admin_api, wamp_ws, admin, metrics]
        }},
        {bridge, #{transport => tcp, protocol => bridge_relay, port => 0}}
    ],
    Nodes = bondy_ct:start_nodes(
        [{?CORE, [{[bondy_router, listeners], Listeners}]}, ?EDGE],
        Config
    ),
    _ = [push_modules(N) || {_, N, _} <- Nodes],
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

bridged_call_hop_trace(Config) ->
    [{_, Core, _}, {_, Edge, _}] = proplists:get_value(nodes, Config),
    #{public := Pub} = KeyPair = bondy_cryptosign:generate_key(),

    %% Peer error logs relayed to this process: on any failure below,
    %% the peers' crash reports land in the CT log next to the error.
    Self = self(),
    _ = [
        ok = erpc:call(N, ?MODULE, do_attach_log_relay, [Self])
     || N <- [Core, Edge]
    ],
    try
        bridged_call_hop_trace_steps(Core, Edge, KeyPair, Pub)
    catch
        Class:Reason:Stack ->
            ct:pal("peer error logs:~n~p", [flush_peer_logs()]),
            erlang:raise(Class, Reason, Stack)
    end.

bridged_call_hop_trace_steps(Core, Edge, KeyPair, Pub) ->
    %% Sovereign realms: the core's authenticates the bridge device by
    %% cryptosign (security ENABLED — the bridge authenticates for
    %% real); the edge's hosts the callee probe.
    ok = erpc:call(Core, ?MODULE, do_create_core_realm, [?REALM, Pub]),
    ok = erpc:call(
        Edge, bondy_trace_context_SUITE, do_create_open_realm, [?REALM]
    ),

    %% Callee on the edge, then the bridge: `proxy_existing` ships the
    %% registration to the core the moment the bridge session opens.
    ok = erpc:call(
        Edge,
        bondy_trace_context_SUITE,
        do_start_yielding_callee,
        [?REALM, [?PROC]]
    ),
    Port = erpc:call(Core, ranch, get_port, [bridge]),
    ok = erpc:call(Edge, ?MODULE, do_add_bridge, [Port, ?REALM, KeyPair]),

    %% The core now holds a proxy entry (a bridge_relay-typed local
    %% entry) for the edge's registration.
    ok = wait_proxy_registration(Core, ?REALM, ?PROC, Edge),

    Self = self(),
    _ = [
        ok =
            erpc:call(
                N,
                bondy_trace_context_SUITE,
                do_attach_latency_capture,
                [Self]
            )
     || N <- [Core, Edge]
    ],
    try
        %% One traced + one plain CALL from the core-side caller.
        ok = erpc:call(
            Core, bondy_trace_context_SUITE, do_call_pair, [?REALM, ?PROC]
        ),

        %% The INVOCATION delivered on the edge carries the hop-prefixed
        %% tracestate with traceparent/baggage verbatim; the untraced
        %% call carries nothing — the exact cross-node contract.
        ok = bondy_trace_context_SUITE:assert_cross_call_trace_pair(Edge),

        %% Four latency events (2 calls x 2 legs). The traced pair:
        %% call leg on the core, invocation leg on the edge, both
        %% carrying the SAME hop id (minted once at the forward seat).
        Events = bondy_trace_context_SUITE:collect_latency(?PROC, 4),
        Traced = [
            {N, M}
         || {N, #{trace := T} = M} <- Events, map_size(T) > 0
        ],
        ?assertEqual(
            lists:sort([{Core, call}, {Edge, invocation}]),
            lists:sort([{N, maps:get(kind, M)} || {N, M} <- Traced])
        ),
        [HopA, HopB] = [
            bondy_trace_context_SUITE:assert_hop_trace(maps:get(trace, M))
         || {_, M} <- Traced
        ],
        ?assertEqual(HopA, HopB),
        Untraced = [M || {_, #{trace := T} = M} <- Events, map_size(T) == 0],
        ?assertEqual(2, length(Untraced))
    after
        lists:foreach(
            fun(N) ->
                try
                    erpc:call(
                        N,
                        bondy_trace_context_SUITE,
                        do_detach_latency_capture,
                        []
                    )
                catch
                    _:_ -> ok
                end
            end,
            [Core, Edge]
        )
    end.

%% A router that accepts and then dies on every connection: the client
%% must treat each session-less death as a retry FAILURE — redialing
%% with the configured backoff and stopping at the retry limit, where
%% its permanent supervisor child restarts it on a fresh budget (a
%% bridge cycles at the backoff pace by design; it never redials in a
%% tight loop). The budget used to reset both on TCP establishment and
%% on re-entering `connecting`, so this exact server was redialed
%% unboundedly fast and no limit was ever reached. The accept counter
%% bounds the dial rate; the pid change pins the exhaustion.
crashing_server_redials_with_backoff(Config) ->
    [_, {_, Edge, _}] = proplists:get_value(nodes, Config),
    Self = self(),
    {ok, LSock} = gen_tcp:listen(0, [
        binary, {ip, {127, 0, 0, 1}}, {active, false}, {reuseaddr, true}
    ]),
    {ok, Port} = inet:port(LSock),
    Acceptor = spawn(fun() -> accept_close_loop(LSock, Self) end),
    try
        %% Fresh log relay (warning level): the exhaustion witness
        %% below arrives through it.
        ok = erpc:call(Edge, ?MODULE, do_attach_log_relay, [Self]),
        ok = erpc:call(Edge, ?MODULE, do_add_crashing_bridge, [Port]),
        InitialPid = erpc:call(Edge, ?MODULE, do_bridge_child_pid, [
            <<"ct_bridge_backoff">>
        ]),
        ?assert(is_pid(InitialPid)),

        %% Dial schedule with backoff_min 500 / backoff_max 1000 /
        %% max_retries 3: accepts at ~0, 500, 1500, 2500ms, then the
        %% budget is exhausted and the client stops. 4s covers it with
        %% slack; the old tight loop produced hundreds of accepts here.
        timer:sleep(4000),
        Count = drain_accepts(0),
        ?assert(Count >= 3, {too_few_dials, Count}),
        ?assert(Count =< 8, {redial_loop_not_backed_off, Count}),

        %% Budget exhaustion is REAL and directly observed: the client
        %% logs the exhaustion warning and stops ({shutdown, _}); its
        %% permanent supervisor child restarts it on a fresh budget —
        %% by design a bridge cycles at the backoff pace, it never
        %% gives up and never tight-loops. A budget that resets
        %% mid-episode (the bug class) never reaches the limit and
        %% never emits this warning.
        ok = await_exhaustion_warning(
            Edge, erlang:monotonic_time(millisecond) + 8000
        )
    after
        exit(Acceptor, kill),
        gen_tcp:close(LSock),
        _ =
            try
                erpc:call(Edge, bondy_bridge_relay_manager, remove_bridge, [
                    <<"ct_bridge_backoff">>
                ])
            catch
                _:_ -> ok
            end
    end.

%% =============================================================================
%% REMOTE FUNCTIONS (run on the peer nodes via erpc)
%% =============================================================================

%% @private Relay error-level log events on this node to `To` (the CT
%% process). This module doubles as the logger handler (`log/2`).
%% CAPPED: a crash loop on a peer (e.g. a server that dies on every
%% inbound connection while the client reconnects) emits large crash
%% reports continuously, and an unbounded relay copies every one into
%% the CT process mailbox — measured at tens of GB over a one-minute
%% wait. The first few reports carry all the signal.
do_attach_log_relay(To) ->
    _ = logger:remove_handler(ct_bridge_log_relay),
    logger:add_handler(ct_bridge_log_relay, ?MODULE, #{
        config => #{to => To, budget => atomics:new(1, [])}, level => warning
    }).

%% @private logger handler callback (runs on the peers).
log(LogEvent, #{config := #{to := To, budget := Counter}}) ->
    case atomics:add_get(Counter, 1, 1) =< 20 of
        true -> To ! {peer_log, node(), LogEvent};
        false -> ok
    end,
    ok.

%% @private The core realm: cryptosign-only, security enabled, with the
%% bridge device's public key authorized and a blanket grant for its
%% session's actions (registering the proxied procedures, routing the
%% calls). The suite's internal caller/probe sessions set their own
%% `security_enabled => false`, so no anonymous grants are needed.
do_create_core_realm(Uri, PubKey) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"bridge relay rpc test realm">>,
        authmethods => [?WAMP_CRYPTOSIGN_AUTH],
        security_enabled => true,
        users => [
            #{
                username => ?DEVICE,
                authorized_keys => [PubKey],
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [?DEVICE],
                authmethod => ?WAMP_CRYPTOSIGN_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ],
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
                roles => <<"all">>
            }
        ]
    }),
    ok.

%% @private Dial the core's bridge listener and start the bridge. The
%% `privkey` field is the testing-only signer the client supports
%% (`bondy_bridge_relay_client:signer/2`); keys travel hex-encoded as
%% they do in bondy.conf.
do_add_bridge(Port, RealmUri, #{public := Pub, secret := Priv}) ->
    Data = #{
        name => <<"ct_bridge">>,
        enabled => true,
        endpoint => {{127, 0, 0, 1}, Port},
        transport => tcp,
        realms => [
            #{
                uri => RealmUri,
                authid => ?DEVICE,
                cryptosign => #{
                    pubkey => binary:encode_hex(Pub, lowercase),
                    privkey => binary:encode_hex(Priv, lowercase)
                }
            }
        ]
    },
    {ok, _} = bondy_bridge_relay_manager:add_bridge(
        Data, #{autostart => true}
    ),
    %% The client is a temporary child: a crash removes it and its
    %% reason with it. Watch it briefly so a config/connect/auth
    %% failure surfaces as this call's error instead of a downstream
    %% wait timeout.
    case supervisor:which_children(bondy_bridge_relay_client_sup) of
        [{_, Pid, _, _} | _] when is_pid(Pid) ->
            Ref = monitor(process, Pid),
            receive
                {'DOWN', Ref, process, Pid, Reason} ->
                    error({bridge_client_died, Reason})
            after 3000 ->
                demonitor(Ref, [flush]),
                ok
            end;
        Other ->
            error({bridge_client_not_running, Other})
    end.

%% @private A bridge dialing the crashing listener: tight, jitter-free
%% retry config so the dial schedule is assertable. The realm config is
%% never exercised — every connection dies before AUTH — but the spec
%% requires a well-formed entry.
do_add_crashing_bridge(Port) ->
    Hex = binary:copy(<<"ab">>, 32),
    Data = #{
        name => <<"ct_bridge_backoff">>,
        enabled => true,
        endpoint => {{127, 0, 0, 1}, Port},
        transport => tcp,
        reconnect => #{
            enabled => true,
            max_retries => 3,
            backoff_min => 500,
            backoff_max => 1000,
            backoff_type => normal
        },
        realms => [
            #{
                uri => <<"com.bondy.bridge_backoff">>,
                authid => ?DEVICE,
                cryptosign => #{
                    pubkey => Hex,
                    privkey => Hex
                }
            }
        ]
    },
    {ok, _} = bondy_bridge_relay_manager:add_bridge(
        Data, #{autostart => true}
    ),
    ok.

%% @private The child's pid, `undefined` for a terminated (or absent)
%% child, `restarting` while the supervisor restarts it.
do_bridge_child_pid(Id) ->
    case
        lists:keyfind(
            Id, 1, supervisor:which_children(bondy_bridge_relay_client_sup)
        )
    of
        {Id, Pid, _, _} -> Pid;
        false -> undefined
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private Accept, notify, close immediately — a router that dies on
%% every inbound connection, distilled.
accept_close_loop(LSock, To) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            To ! accepted,
            gen_tcp:close(Sock),
            accept_close_loop(LSock, To);
        {error, _} ->
            ok
    end.

%% @private
drain_accepts(N) ->
    receive
        accepted -> drain_accepts(N + 1)
    after 0 -> N
    end.

%% @private The relayed retry-budget-exhaustion warning from `Node`
%% (`bondy_bridge_relay_client:redial_failed/2`'s limit branch); other
%% relayed events are skipped.
await_exhaustion_warning(Node, Deadline) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {peer_log, Node, #{msg := {report, #{description := D}}}} when
            is_list(D)
        ->
            case string:prefix(D, "Bridge relay retry budget exhausted") of
                nomatch -> await_exhaustion_warning(Node, Deadline);
                _ -> ok
            end;
        {peer_log, _, _} ->
            await_exhaustion_warning(Node, Deadline)
    after Timeout ->
        error(retry_budget_never_exhausted)
    end.

%% @private The suite's own module plus the helper module whose probe,
%% caller and capture functions run on the peers.
push_modules(Node) ->
    lists:foreach(
        fun(Mod) ->
            {Mod, Bin, File} = code:get_object_code(Mod),
            {module, Mod} =
                erpc:call(Node, code, load_binary, [Mod, File, Bin])
        end,
        [?MODULE, bondy_trace_context_SUITE]
    ).

%% @private The bridge connect + session open + registration proxying
%% are all asynchronous; the proxy entry appearing in the core registry
%% is the one observable that says the route exists. On timeout the
%% error carries the bridge's own status from both ends, so a
%% connect/auth failure is readable from the CT log.
wait_proxy_registration(Node, Uri, Proc, Edge) ->
    try
        wait_until(
            fun() ->
                erpc:call(Node, bondy_registry, has_matches, [
                    registration, Uri, Proc
                ])
            end,
            {proxy_registration, Node, Proc},
            erlang:monotonic_time(millisecond) + 30000
        )
    catch
        error:{timeout, Tag} ->
            Status =
                try
                    erpc:call(Edge, bondy_bridge_relay_manager, status, [])
                catch
                    C1:R1 -> {C1, R1}
                end,
            Children =
                try
                    erpc:call(Edge, supervisor, which_children, [
                        bondy_bridge_relay_client_sup
                    ])
                catch
                    C2:R2 -> {C2, R2}
                end,
            %% Stop the bridge before failing: a client that keeps
            %% redialing a crashing server churns crash reports for as
            %% long as the peers live.
            _ =
                try
                    erpc:call(Edge, bondy_bridge_relay_manager, remove_bridge, [
                        <<"ct_bridge">>
                    ])
                catch
                    _:_ -> ok
                end,
            error({timeout, Tag, {bridge_status, Status}, {sup, Children}})
    end.

%% @private
flush_peer_logs() ->
    receive
        {peer_log, Node, Event} -> [{Node, Event} | flush_peer_logs()]
    after 0 -> []
    end.

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
