%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_mcp_cluster_SUITE).

-moduledoc """
Cross-node forwarding for the handshake era (design §12.1's cluster
affinity, built as `bondy_mcp_handshake`'s per-node door): a session is
OWNED by the node that served its `initialize`, and every operation a
request on another member makes — dispatch binding checks, subscribes,
in-flight registration, cancellation, close, and the held `GET` stream
through an owner-side proxy — reaches the owner through the door, while
authentication and the WAMP dispatch itself run on the receiving node.

Two full Bondy peers each mount a REAL `mcp`-service listener through the
boot inventory; the suite's HTTP clients talk to both from the CT node,
and the callee joins over WAMP TCP — so every assertion crosses real
sockets on both planes.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_router/include/bondy_security.hrl").

-define(OPEN_REALM, <<"com.example.mcp.cluster.open">>).
-define(RBAC_REALM, <<"com.example.mcp.cluster.rbac">>).
-define(ECHO, <<"com.example.mcp.cx.echo">>).
-define(SLOW, <<"com.example.mcp.cx.slow">>).
-define(GET_USER, <<"com.example.mcp.cx.get_user">>).
-define(USER, <<"mcp_cx_user_1">>).
-define(USER2, <<"mcp_cx_user_2">>).
-define(PASSWORD, <<"aWamp2Password">>).
-define(LATEST, <<"2025-11-25">>).
-define(HOST, "127.0.0.1").
-define(N1_MCP_PORT, 22086).
-define(N2_MCP_PORT, 22087).
-define(N1_WAMP_PORT, 22096).
-define(N2_WAMP_PORT, 22097).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        session_ops_forward_to_the_owner,
        principal_binding_holds_across_nodes,
        cancel_executes_on_the_callers_node,
        stream_serves_across_nodes,
        stream_conflict_heals_across_nodes,
        delete_via_peer_closes_the_owner_session
    ].

suite() ->
    [{timetrap, {minutes, 5}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(
        [
            {mcp_cx1, [
                {
                    [bondy_router, listeners],
                    peer_listeners(?N1_MCP_PORT, ?N1_WAMP_PORT)
                }
            ]},
            {mcp_cx2, [
                {
                    [bondy_router, listeners],
                    peer_listeners(?N2_MCP_PORT, ?N2_WAMP_PORT)
                }
            ]}
        ],
        Config
    ),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),

    [{_, Node1, _}, {_, Node2, _}] = Nodes,

    %% These cases pin cross-node forwarding, not the exposure policy:
    %% run both peers under `derived` so the URI-named fixture tools
    %% exist without an overlay entry each. The shipped default
    %% (`curated`) is pinned by bondy_mcp_gateway_SUITE.
    _ = [
        ok = erpc:call(N, application, set_env, [
            bondy_mcp, manifest_mode, derived
        ])
     || N <- [Node1, Node2]
    ],

    Open = erpc:call(Node1, bondy_realm, create, [?OPEN_REALM]),
    ok = erpc:call(Node1, bondy_realm, disable_security, [Open]),
    _ = erpc:call(Node1, bondy_realm, create, [rbac_realm_config()]),

    ok = erpc:call(Node1, bondy_interface, load, [
        #{
            <<"id">> => <<"mcp_cx_iface">>,
            <<"entries">> => [
                #{
                    <<"realm">> => ?OPEN_REALM,
                    <<"kind">> => <<"procedure">>,
                    <<"uri">> => Uri
                }
             || Uri <- [?ECHO, ?SLOW]
            ]
        }
    ]),
    ok = erpc:call(Node1, bondy_mcp_gateway, load, [
        #{
            <<"id">> => <<"mcp_cx_overlay">>,
            <<"entries">> => [
                #{
                    <<"realm">> => ?OPEN_REALM,
                    <<"name">> => <<"user">>,
                    <<"kind">> => <<"resource_template">>,
                    <<"wamp_procedure">> => ?GET_USER,
                    <<"uri_template">> => <<"users:///{id}">>,
                    <<"uri_vars_schema">> => #{
                        <<"id">> => #{<<"type">> => <<"integer">>}
                    },
                    <<"wamp_kwargs">> => #{<<"id">> => <<"{{id}}">>},
                    <<"update_topic">> =>
                        <<"com.example.mcp.cx.user.{{id}}.changed">>,
                    <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
                }
            ]
        }
    ]),

    %% Both edges must serve the SAME surface before any case runs: the
    %% realm (with security disabled), the RBAC realm's auth sources, and
    %% a manifest carrying the tools.
    ok = wait_until(
        fun() ->
            erpc:call(Node2, bondy_realm, exists, [?OPEN_REALM]) andalso
                not erpc:call(Node2, bondy_realm, is_security_enabled, [
                    ?OPEN_REALM
                ])
        end,
        30000,
        open_realm_not_replicated
    ),
    ok = wait_until(
        fun() ->
            erpc:call(Node2, bondy_realm, exists, [?RBAC_REALM]) andalso
                erpc:call(Node2, bondy_rbac_source, list, [?RBAC_REALM]) =/= []
        end,
        30000,
        rbac_realm_not_replicated
    ),
    ok = wait_until(
        fun() ->
            case erpc:call(Node2, bondy_mcp_gateway, manifest, [?OPEN_REALM]) of
                {ok, #{entries := E}} -> maps:is_key(?ECHO, E);
                _ -> false
            end
        end,
        30000,
        manifest_not_replicated
    ),

    Owner = spawn_callee_owner(),

    [{nodes, Nodes}, {callee_owner, Owner} | Config].

end_per_suite(Config) ->
    ?config(callee_owner, Config) ! stop,
    ok = bondy_ct:stop_cluster(?config(nodes, Config)).

rbac_realm_config() ->
    %% No grants: the binding case only needs 404-vs-200 on `tools/list`,
    %% and an empty projected list is still a 200.
    #{
        uri => ?RBAC_REALM,
        description => <<"MCP cluster RBAC">>,
        authmethods => [?PASSWORD_AUTH],
        security_enabled => true,
        groups => [#{name => <<"mcp_cx_users">>}],
        users => [
            #{
                username => U,
                password => ?PASSWORD,
                groups => [<<"mcp_cx_users">>],
                meta => #{}
            }
         || U <- [?USER, ?USER2]
        ],
        sources => [
            #{
                usernames => [?USER, ?USER2],
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    }.

%% The peer's boot inventory: a real MCP edge plus the WAMP TCP listener
%% the callee joins through. `admin` is restated at `port => 0` — setting
%% `[bondy_router, listeners]` REPLACES what `bondy_ct:node_env/2`
%% installed, and the default fixed admin port would collide across the
%% two peers on this host.
peer_listeners(McpPort, WampPort) ->
    [
        {admin, #{
            transport => tcp,
            protocol => http,
            port => 0,
            start_phase => early,
            services => [admin_api, wamp_ws, admin, metrics]
        }},
        {mcp_edge, #{
            transport => tcp,
            protocol => http,
            port => McpPort,
            services => [mcp]
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

session_ops_forward_to_the_owner(Config) ->
    [{_, Node1, _}, {_, _, _}] = ?config(nodes, Config),
    %% Initialize on node 1: the session id names node 1.
    SessionId = initialize(?N1_MCP_PORT, ?OPEN_REALM, []),
    {ok, OwnerBin, _} = bondy_mcp_handshake:parse_session_id(SessionId),
    ?assertEqual(atom_to_binary(Node1, utf8), OwnerBin),

    %% Every established operation lands on node 2 and is served against
    %% the node-1 session through the door.
    {200, _, #{<<"result">> := PingR}} = post_session(
        ?N2_MCP_PORT, ?OPEN_REALM, SessionId, req(1, <<"ping">>, #{})
    ),
    ?assertEqual(#{}, PingR),
    {202, _, _} = post_session(
        ?N2_MCP_PORT,
        ?OPEN_REALM,
        SessionId,
        notif(<<"notifications/initialized">>, #{})
    ),
    {200, _, #{<<"result">> := ListR}} = post_session(
        ?N2_MCP_PORT, ?OPEN_REALM, SessionId, req(2, <<"tools/list">>, #{})
    ),
    Names = [maps:get(<<"name">>, T) || T <- maps:get(<<"tools">>, ListR)],
    ?assert(lists:member(?ECHO, Names)),
    %% The WAMP call executes on node 2 (the dealer is already
    %% cluster-transparent); only the session checks crossed the door.
    {200, _, #{<<"result">> := CallR}} = post_session(
        ?N2_MCP_PORT,
        ?OPEN_REALM,
        SessionId,
        req(3, <<"tools/call">>, #{
            <<"name">> => ?ECHO, <<"arguments">> => #{<<"n">> => 7}
        })
    ),
    ?assertMatch(#{<<"isError">> := false}, CallR),
    ok = delete_session(?N1_MCP_PORT, ?OPEN_REALM, SessionId, []).

principal_binding_holds_across_nodes(Config) ->
    [{_, _, _}, {_, _, _}] = ?config(nodes, Config),
    Auth1 = basic_auth(?USER, ?PASSWORD),
    Auth2 = basic_auth(?USER2, ?PASSWORD),
    SessionId = initialize(?N1_MCP_PORT, ?RBAC_REALM, [Auth1]),
    %% A different principal presenting the session id THROUGH ANOTHER
    %% NODE gets the same unknown-session 404 — the principal term
    %% crosses the door and the owner enforces the binding.
    {404, _, #{<<"error">> := #{<<"code">> := -32001}}} = post_session(
        ?N2_MCP_PORT,
        ?RBAC_REALM,
        SessionId,
        req(1, <<"tools/list">>, #{}),
        [Auth2]
    ),
    {200, _, #{<<"result">> := _}} = post_session(
        ?N2_MCP_PORT,
        ?RBAC_REALM,
        SessionId,
        req(2, <<"tools/list">>, #{}),
        [Auth1]
    ),
    ok = delete_session(?N1_MCP_PORT, ?RBAC_REALM, SessionId, [Auth1]).

cancel_executes_on_the_callers_node(Config) ->
    [{_, _, _}, {_, _, _}] = ?config(nodes, Config),
    SessionId = initialize(?N1_MCP_PORT, ?OPEN_REALM, []),
    %% The slow call dispatches on NODE 2 — its dealer holds the promise
    %% — while the in-flight entry lives on the owner, node 1.
    {ok, Conn} = gun:open(?HOST, ?N2_MCP_PORT, #{
        transport => tcp, protocols => [http]
    }),
    {ok, _} = gun:await_up(Conn, 5000),
    CallBody = req(77, <<"tools/call">>, #{
        <<"name">> => ?SLOW, <<"arguments">> => #{}
    }),
    Ref = gun:post(
        Conn,
        "/mcp/realm/" ++ binary_to_list(?OPEN_REALM),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"mcp-session-id">>, SessionId},
            {<<"mcp-protocol-version">>, ?LATEST}
        ],
        iolist_to_binary(json:encode(CallBody))
    ),
    timer:sleep(500),
    %% The cancellation arrives at NODE 1: the entry is taken there and
    %% the CANCEL is routed back to node 2 to execute where the promise
    %% lives. The callee sleeps 8s and the call timeout is 30s — only a
    %% real cross-node cancel answers within 4s.
    {202, _, _} = post_session(
        ?N1_MCP_PORT,
        ?OPEN_REALM,
        SessionId,
        notif(<<"notifications/cancelled">>, #{<<"requestId">> => 77})
    ),
    {response, nofin, 200, _} = gun:await(Conn, Ref, 4000),
    {ok, RespBody} = gun:await_body(Conn, Ref, 4000),
    #{<<"result">> := R} = json:decode(RespBody),
    ?assertMatch(#{<<"isError">> := true}, R),
    ok = gun:close(Conn),
    ok = delete_session(?N1_MCP_PORT, ?OPEN_REALM, SessionId, []).

stream_serves_across_nodes(Config) ->
    [{_, _, _}, {_, _, _}] = ?config(nodes, Config),
    SessionId = initialize(?N1_MCP_PORT, ?OPEN_REALM, []),
    %% Subscribe through node 2 — executes inside the owner's session.
    {200, _, #{<<"result">> := #{}}} = post_session(
        ?N2_MCP_PORT,
        ?OPEN_REALM,
        SessionId,
        req(1, <<"resources/subscribe">>, #{<<"uri">> => <<"users:///9">>})
    ),
    %% Published while NO stream is connected: buffered in the OWNER's
    %% queue (§12.2).
    ok = publish(Config, <<"com.example.mcp.cx.user.9.changed">>, [], #{}),
    %% The GET stream lands on node 2; the owner-side proxy drains the
    %% backlog and pushes it door-to-door.
    {Conn, Ref, Buf0} = open_stream(?N2_MCP_PORT, ?OPEN_REALM, SessionId),
    {Msg1, Buf1} = next_or_fail(Conn, Ref, Buf0, 15000),
    ?assertMatch(
        #{
            <<"method">> := <<"notifications/resources/updated">>,
            <<"params">> := #{<<"uri">> := <<"users:///9">>}
        },
        Msg1
    ),
    %% And live delivery while connected.
    ok = publish(Config, <<"com.example.mcp.cx.user.9.changed">>, [], #{}),
    {Msg2, _} = next_or_fail(Conn, Ref, Buf1, 15000),
    ?assertMatch(
        #{<<"method">> := <<"notifications/resources/updated">>}, Msg2
    ),
    ok = gun:close(Conn),
    ok = delete_session(?N1_MCP_PORT, ?OPEN_REALM, SessionId, []).

stream_conflict_heals_across_nodes(Config) ->
    [{_, _, _}, {_, Node2, _}] = ?config(nodes, Config),
    SessionId = initialize(?N1_MCP_PORT, ?OPEN_REALM, []),
    {Conn, _Ref, _} = open_stream(?N2_MCP_PORT, ?OPEN_REALM, SessionId),
    %% The one-stream rule holds cluster-wide: the owner's own edge
    %% refuses while the remote proxy holds the slot...
    {409, C1} = open_stream_status(?N1_MCP_PORT, ?OPEN_REALM, SessionId),
    ok = gun:close(C1),
    %% ...and a second remote attach is refused after the liveness probe
    %% confirms the consumer.
    {409, C2} = open_stream_status(?N2_MCP_PORT, ?OPEN_REALM, SessionId),
    ok = gun:close(C2),
    %% Kill node 2's consumer BRUTALLY — no terminate, no detach. The
    %% stale proxy must not pin the conflict: the next remote attach
    %% probes the consumer node, finds it dead, detaches and takes over.
    [ConsumerPid] = consumer_pids(Node2),
    true = erpc:call(Node2, erlang, exit, [ConsumerPid, kill]),
    ok = gun:close(Conn),
    ok = wait_until(
        fun() ->
            case open_stream_status(?N2_MCP_PORT, ?OPEN_REALM, SessionId) of
                {200, C, _} ->
                    gun:close(C),
                    true;
                {_, C} ->
                    gun:close(C),
                    false
            end
        end,
        15000,
        stale_stream_not_taken_over
    ),
    ok = delete_session(?N1_MCP_PORT, ?OPEN_REALM, SessionId, []).

delete_via_peer_closes_the_owner_session(Config) ->
    [{_, _, _}, {_, _, _}] = ?config(nodes, Config),
    SessionId = initialize(?N1_MCP_PORT, ?OPEN_REALM, []),
    ok = delete_session(?N2_MCP_PORT, ?OPEN_REALM, SessionId, []),
    {404, _, _} = post_session(
        ?N1_MCP_PORT, ?OPEN_REALM, SessionId, req(1, <<"tools/list">>, #{})
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% The gproc names of the handshake stream consumers on `Node`.
consumer_pids(Node) ->
    erpc:call(Node, gproc, select, [
        {l, n},
        [
            {
                {{n, l, {bondy_mcp_handshake, consumer, '_'}}, '$1', '_'},
                [],
                ['$1']
            }
        ]
    ]).

spawn_callee_owner() ->
    Caller = self(),
    Owner = spawn(fun() ->
        Conn = sdk_connect(?N1_WAMP_PORT),
        {ok, _} = bondy_connect_client:register(
            Conn, ?ECHO, fun(Args, KwArgs, _) ->
                {ok, #{args => Args, kwargs => KwArgs}}
            end
        ),
        {ok, _} = bondy_connect_client:register(
            Conn, ?GET_USER, fun(_, KwArgs, _) ->
                {ok, #{kwargs => KwArgs#{<<"name">> => <<"ada">>}}}
            end
        ),
        %% The SLOW callee joins NODE 2 — deliberately NOT the session
        %% owner. The cancel falsifier depends on this topology: the
        %% dealer can settle a cancel from the CALLER's node (the call
        %% promise) or the CALLEE's node (the invocation promise), so a
        %% cancel mis-executed on the owner would still succeed if the
        %% owner also hosted the callee, and the routing mutation would
        %% survive.
        Conn2 = sdk_connect(?N2_WAMP_PORT),
        {ok, _} = bondy_connect_client:register(
            Conn2, ?SLOW, fun(_, _, _) ->
                timer:sleep(8000),
                {ok, #{kwargs => #{<<"late">> => true}}}
            end
        ),
        Caller ! {callee_ready, self()},
        callee_owner_loop(Conn, Conn2)
    end),
    receive
        {callee_ready, Owner} -> Owner
    after 20000 ->
        error(callee_owner_timeout)
    end.

%% Session data (auth sources) can arrive after the realm object; retry
%% the join until the deadline.
sdk_connect(Port) ->
    sdk_connect(Port, erlang:monotonic_time(millisecond) + 15000).

sdk_connect(Port, Deadline) ->
    Spec = #{
        transport => tcp,
        endpoint => {?HOST, Port},
        realm => ?OPEN_REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    },
    case bondy_connect_client:connect(Spec) of
        {ok, Conn} ->
            Conn;
        {error, _} = Error ->
            erlang:monotonic_time(millisecond) < Deadline orelse
                error({sdk_connect_failed, Error}),
            timer:sleep(250),
            sdk_connect(Port, Deadline)
    end.

callee_owner_loop(Conn, Conn2) ->
    receive
        {publish, From, Topic, Args, KwArgs} ->
            From !
                {published,
                    bondy_connect_client:publish(Conn, Topic, Args, KwArgs)},
            callee_owner_loop(Conn, Conn2);
        stop ->
            _ = bondy_connect_client:disconnect(Conn2),
            bondy_connect_client:disconnect(Conn)
    end.

publish(Config, Topic, Args, KwArgs) ->
    Owner = ?config(callee_owner, Config),
    Owner ! {publish, self(), Topic, Args, KwArgs},
    receive
        {published, ok} -> ok;
        {published, Other} -> error({publish_failed, Other})
    after 5000 ->
        error(publish_timeout)
    end.

req(Id, Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }.

notif(Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params
    }.

init_body(Version) ->
    req(0, <<"initialize">>, #{
        <<"protocolVersion">> => Version,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{
            <<"name">> => <<"ct">>, <<"version">> => <<"1">>
        }
    }).

url(Port, Realm) ->
    lists:flatten(
        io_lib:format("http://~s:~b/mcp/realm/~s", [?HOST, Port, Realm])
    ).

initialize(Port, Realm, Headers) ->
    {200, RespHeaders, #{<<"result">> := _}} = do_post(
        Port, Realm, Headers, init_body(?LATEST)
    ),
    {_, V} = lists:keyfind("mcp-session-id", 1, RespHeaders),
    list_to_binary(V).

session(SessionId) ->
    {"mcp-session-id", binary_to_list(SessionId)}.

post_session(Port, Realm, SessionId, Body) ->
    post_session(Port, Realm, SessionId, Body, []).

post_session(Port, Realm, SessionId, Body, Headers) ->
    do_post(
        Port,
        Realm,
        [
            session(SessionId),
            {"mcp-protocol-version", binary_to_list(?LATEST)}
            | Headers
        ],
        Body
    ).

do_post(Port, Realm, Headers, Body) ->
    {ok, {{_, Status, _}, RespHeaders, RespBody}} = httpc:request(
        post,
        {
            url(Port, Realm),
            Headers,
            "application/json",
            iolist_to_binary(json:encode(Body))
        },
        [],
        [{body_format, binary}]
    ),
    Decoded =
        case RespBody of
            <<>> -> #{};
            _ -> json:decode(RespBody)
        end,
    {Status, RespHeaders, Decoded}.

delete_session(Port, Realm, SessionId, Headers) ->
    {ok, {{_, 204, _}, _, _}} = httpc:request(
        delete,
        {url(Port, Realm), [session(SessionId) | Headers]},
        [],
        []
    ),
    ok.

basic_auth(User, Password) ->
    {"authorization",
        "Basic " ++
            base64:encode_to_string(<<User/binary, ":", Password/binary>>)}.

open_stream(Port, Realm, SessionId) ->
    case open_stream_status(Port, Realm, SessionId) of
        {200, Conn, Ref} -> {Conn, Ref, <<>>};
        Other -> error({open_stream_failed, Other})
    end.

open_stream_status(Port, Realm, SessionId) ->
    {ok, Conn} = gun:open(?HOST, Port, #{
        transport => tcp, protocols => [http]
    }),
    {ok, _} = gun:await_up(Conn, 5000),
    Headers = [
        {<<"accept">>, <<"text/event-stream">>},
        {<<"mcp-session-id">>, SessionId},
        {<<"mcp-protocol-version">>, ?LATEST}
    ],
    Path = "/mcp/realm/" ++ binary_to_list(Realm),
    Ref = gun:get(Conn, Path, Headers),
    case gun:await(Conn, Ref, 10000) of
        {response, nofin, 200, RespHeaders} ->
            {_, CT} = lists:keyfind(<<"content-type">>, 1, RespHeaders),
            ?assertMatch(<<"text/event-stream", _/binary>>, CT),
            {200, Conn, Ref};
        {response, _, Status, _} ->
            {Status, Conn}
    end.

next_or_fail(Conn, Ref, Buf, Timeout) ->
    case sse_next(Conn, Ref, Buf, Timeout) of
        {Msg, Rest} -> {Msg, Rest};
        Other -> error({expected_sse_message, Other})
    end.

sse_next(Conn, Ref, Buf, Timeout) ->
    case take_frame(Buf) of
        {Frame, Rest} ->
            {json:decode(Frame), Rest};
        more ->
            case gun:await(Conn, Ref, Timeout) of
                {data, _IsFin, Data} ->
                    sse_next(Conn, Ref, <<Buf/binary, Data/binary>>, Timeout);
                {error, timeout} ->
                    timeout;
                {error, _} ->
                    closed
            end
    end.

take_frame(Buf) ->
    case binary:split(Buf, <<"\n\n">>) of
        [Frame, Rest] -> {frame_data(Frame), Rest};
        [_] -> more
    end.

frame_data(Frame) ->
    Datas = [
        D
     || <<"data: ", D/binary>> <- binary:split(Frame, <<"\n">>, [global])
    ],
    iolist_to_binary(lists:join(<<"\n">>, Datas)).

wait_until(Fun, TimeoutMs, Label) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_until_loop(Fun, Deadline, Label).

wait_until_loop(Fun, Deadline, Label) ->
    case Fun() of
        true ->
            ok;
        false ->
            erlang:monotonic_time(millisecond) < Deadline orelse
                error({wait_until_timeout, Label}),
            timer:sleep(200),
            wait_until_loop(Fun, Deadline, Label)
    end.
