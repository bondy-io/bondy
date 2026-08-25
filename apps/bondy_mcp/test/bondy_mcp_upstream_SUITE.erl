%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_mcp_upstream_SUITE).

-moduledoc """
The client direction (design §13, §21 increment 9) over real sockets:
declared upstream MCP servers are projected into the WAMP registry, and
every projected call flows WAMP → Streamable HTTP → upstream → back.

Two upstreams under test:

- a STUB MCP server (this module doubles as its cowboy handler) built to
  falsify the client's transport obligations — token auth on every
  request, the `MCP-Protocol-Version` header requirement, session
  expiry (404 → re-initialize once, single-flight), SSE-framed `POST`
  responses with an in-stream server `ping` answered post-hoc, cursor
  pagination, and definition drift;
- Bondy's OWN handshake-era MCP endpoint on a second realm — the whole
  chain against a server verified against the specification, including
  version negotiation and result mapping through a real manifest.

Plus the projection policies: TOFU pinning with canonical-JSON hashes,
drift blocking until explicit `approve/2`, per-realm prefix isolation,
and the audit trail's `upstream_call`/`derivation` record (§13.1).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_router/include/bondy_security.hrl").
-include_lib("bondy_router/include/bondy_db_tables.hrl").

-define(PROJ_REALM, <<"com.bondy.mcp.up.proj">>).
-define(UP_REALM, <<"com.bondy.mcp.up.target">>).
-define(UP_ECHO, <<"com.example.mcp.up.echo">>).
-define(STUB_SVC, <<"mcp_ct_stub">>).
-define(SELF_SVC, <<"mcp_ct_self">>).
-define(TAB, mcp_upstream_stub_tab).
-define(TOKEN, <<"tok-1">>).
-define(STUB_LISTENER, ct_mcp_up_stub).
-define(SELF_LISTENER, ct_mcp_up_self).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        projection_registers_pinned_tools,
        call_maps_results_symmetrically,
        trace_context_reaches_upstream_meta,
        sse_response_and_server_ping,
        session_expiry_reinitializes,
        drift_blocks_until_approved,
        namespace_isolation_across_upstreams,
        audit_records_the_service_account,
        metrics_upstream_series,
        pin_hash_is_canonical,
        projection_via_real_bondy_upstream,
        invalid_declarations_refuse_start
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),

    Proj = bondy_realm:create(?PROJ_REALM),
    ok = bondy_realm:disable_security(Proj),
    Up = bondy_realm:create(?UP_REALM),
    ok = bondy_realm:disable_security(Up),

    %% The self-upstream's served surface: one declared tool over a live
    %% callee.
    ok = bondy_interface:load(#{
        <<"id">> => <<"mcp_up_iface">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?UP_REALM,
                <<"kind">> => <<"procedure">>,
                <<"uri">> => ?UP_ECHO
            }
        ]
    }),
    ok = bondy_mcp_gateway:load(#{
        <<"id">> => <<"mcp_up_overlay">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?UP_REALM,
                <<"name">> => <<"up_echo">>,
                <<"kind">> => <<"tool">>,
                <<"wamp_procedure">> => ?UP_ECHO,
                <<"kwargs_schema">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"x">> => #{<<"type">> => <<"integer">>}
                    }
                }
            }
        ]
    }),
    Owner = spawn_callee_owner(),

    %% The stub upstream. A named ETS table dies with its owner and
    %% `init_per_suite` runs in a transient process, so a holder owns it.
    TabHolder = spawn(fun() ->
        ?TAB = ets:new(?TAB, [named_table, public, set]),
        receive
            stop -> ok
        end
    end),
    ok = wait_until(fun() -> ets:whereis(?TAB) =/= undefined end),
    stub_reset(),
    StubRoutes = cowboy_router:compile([
        {'_', [
            {"/token", ?MODULE, token},
            {"/mcp", ?MODULE, stub},
            {"/[...]", ?MODULE, ok}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(
        ?STUB_LISTENER,
        [{port, 0}],
        #{env => #{dispatch => StubRoutes}}
    ),
    StubPort = ranch:get_port(?STUB_LISTENER),

    %% Bondy's own MCP endpoint as an upstream.
    SelfRoutes = bondy_mcp_http_service:routes(
        mcp,
        #{config => carrier_config()},
        #{name => ?SELF_LISTENER, transport => tcp}
    ),
    {ok, _} = cowboy:start_clear(
        ?SELF_LISTENER,
        [{port, 0}],
        #{env => #{dispatch => cowboy_router:compile(SelfRoutes)}}
    ),
    SelfPort = ranch:get_port(?SELF_LISTENER),

    %% Restart the connector with this suite's services: its supervisor
    %% starts pools and the manager only when services are configured at
    %% ITS start.
    ok = application:stop(bondy_http_connector),
    ok = application:set_env(bondy_http_connector, services, [
        stub_service(StubPort),
        self_service(SelfPort)
    ]),
    {ok, _} = application:ensure_all_started(bondy_http_connector),

    ok = application:set_env(bondy_mcp, upstreams, upstreams()),
    {ok, _} = bondy_mcp_sup:start_upstreams(),

    %% Projection is retried asynchronously; wait for the full surface.
    ok = wait_projected([
        <<"com.acme.stub.echo">>,
        <<"com.acme.stub.boom">>,
        <<"com.acme.stub2.echo">>,
        <<"com.acme.self.up_echo">>
    ]),

    [{callee_owner, Owner}, {tab_holder, TabHolder} | Config].

end_per_suite(Config) ->
    ?config(callee_owner, Config) ! stop,
    _ = supervisor:terminate_child(bondy_mcp_sup, bondy_mcp_upstream_sup),
    _ = supervisor:delete_child(bondy_mcp_sup, bondy_mcp_upstream_sup),
    ok = application:set_env(bondy_mcp, upstreams, []),
    ok = application:stop(bondy_http_connector),
    ok = application:set_env(bondy_http_connector, services, []),
    {ok, _} = application:ensure_all_started(bondy_http_connector),
    ok = cowboy:stop_listener(?STUB_LISTENER),
    ok = cowboy:stop_listener(?SELF_LISTENER),
    ok = bondy_interface:delete(<<"mcp_up_iface">>),
    ok = bondy_mcp_gateway:delete(<<"mcp_up_overlay">>),
    ?config(tab_holder, Config) ! stop,
    {save_config, Config}.

%% =============================================================================
%% CONFIG
%% =============================================================================

upstreams() ->
    [
        #{
            name => <<"stub">>,
            service => ?STUB_SVC,
            realm => ?PROJ_REALM,
            prefix => <<"com.acme.stub">>,
            path => <<"/mcp">>,
            identity => service,
            enabled => true,
            timeout => undefined
        },
        #{
            name => <<"stub2">>,
            service => ?STUB_SVC,
            realm => ?PROJ_REALM,
            prefix => <<"com.acme.stub2">>,
            path => <<"/mcp">>,
            identity => service,
            enabled => true,
            timeout => undefined
        },
        #{
            name => <<"self">>,
            service => ?SELF_SVC,
            realm => ?PROJ_REALM,
            prefix => <<"com.acme.self">>,
            path => <<"/mcp/realm/", ?UP_REALM/binary>>,
            identity => service,
            enabled => true,
            timeout => undefined
        }
    ].

stub_service(Port) ->
    TokenUrl = <<
        "http://127.0.0.1:",
        (integer_to_binary(Port))/binary,
        "/token"
    >>,
    (base_service(?STUB_SVC, Port))#{
        auth_mod => bondy_http_connector_auth_generic,
        auth_conf => #{
            fetch => #{
                method => post,
                url => TokenUrl,
                body_encoding => json,
                body => #{},
                headers => [],
                token_path => [<<"access_token">>]
            },
            apply => #{
                placement => header,
                name => <<"Authorization">>,
                format => <<"Bearer {{token}}">>
            },
            vars => #{},
            cache => #{default_ttl => 3600, refresh_margin => 60}
        }
    }.

self_service(Port) ->
    base_service(?SELF_SVC, Port).

base_service(Name, Port) ->
    #{
        name => Name,
        base_url => <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
        prefix => <<"/">>,
        timeout => 15000,
        retries => 1,
        tls_verify => verify_none,
        pool => #{size => 8},
        liveness => #{
            enabled => false,
            path => <<"/">>,
            method => head,
            interval => 60000,
            timeout => 5000,
            failure_threshold => 3,
            success_threshold => 1
        },
        procedures => #{}
    }.

carrier_config() ->
    #{
        protocol_versions => [<<"2025-11-25">>, <<"2025-06-18">>],
        public_base_uri => undefined,
        max_body_size => 1048576,
        max_inflight => 64,
        idle_timeout => 600000,
        list => #{default_page_size => 50},
        schema => #{max_depth => 32, max_validation_ms => 50}
    }.

%% =============================================================================
%% CASES
%% =============================================================================

projection_registers_pinned_tools(_) ->
    %% Both stub tools are projected — `boom` only arrives on the second
    %% tools/list page, so a callable `boom` proves cursor pagination.
    {ok, #{kwargs := _}} = proj_call(<<"com.acme.stub.echo">>, #{}),
    {ok, Info} = bondy_mcp_upstream:info(<<"stub">>),
    ?assertEqual(
        #{
            <<"echo">> => <<"com.acme.stub.echo">>,
            <<"boom">> => <<"com.acme.stub.boom">>
        },
        maps:get(registered, Info)
    ),
    ?assertEqual([], maps:get(blocked, Info)),

    %% And both were pinned (trust on first use) with the canonical hash
    %% of their current definitions.
    [{_, EchoDef}] = ets:lookup(?TAB, {tool, <<"echo">>}),
    Table = bondy_namespace_catalog:table(?BONDY_DB_MCP_UPSTREAM_TAB),
    Key = <<(byte_size(<<"stub">>)):16, "stub", "echo">>,
    {ok, {Pin, _}} = bondy_db:read(Table, ?PROJ_REALM, Key),
    ?assertEqual(bondy_mcp_upstream:pin_hash(EchoDef), maps:get(hash, Pin)).

call_maps_results_symmetrically(_) ->
    %% structuredContent → kwargs.
    {ok, #{kwargs := KW}} = proj_call(
        <<"com.acme.stub.echo">>, #{<<"x">> => 1}
    ),
    ?assertEqual(#{<<"echoed">> => #{<<"x">> => 1}}, KW),

    %% isError: true → a WAMP error under the fixed URI, the upstream's
    %% structured content as kwargs.
    {error, #{kind := wamp, uri := Uri, kwargs := EKW}} = proj_call(
        <<"com.acme.stub.boom">>, #{}
    ),
    ?assertEqual(<<"bondy.error.mcp.upstream_tool_error">>, Uri),
    ?assertEqual(<<"kaput">>, maps:get(<<"reason">>, EKW)).

trace_context_reaches_upstream_meta(_) ->
    %% SEP-414 end to end, client direction (§13): a WAMP CALL's trace
    %% context — attached through the SDK, carried in the CALL's options
    %% to the dealer's internal-callback application — continues into
    %% the upstream request as `params._meta`, verbatim (the stub echoes
    %% `_meta` back under `meta`), and rides the completion event as its
    %% `trace` metadata (the §15.4 span contract).
    TP = <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>,
    TS = <<"congo=t61rcWkgMzE">>,
    BG = <<"userId=alice">>,
    Ctx = #{traceparent => TP, tracestate => TS, baggage => BG},
    Self = self(),
    ok = telemetry:attach(
        {?MODULE, up_trace},
        [bondy, mcp, upstream, call, stop],
        fun(_, _, Meta, _) -> Self ! {upstream_call_stop, Meta} end,
        undefined
    ),
    try
        {ok, #{kwargs := KW}} = proj_call(
            <<"com.acme.stub.echo">>,
            #{<<"y">> => 1},
            bondy_connect_trace:attach(#{}, Ctx)
        ),
        ?assertEqual(#{<<"y">> => 1}, maps:get(<<"echoed">>, KW)),
        Trio = #{
            <<"traceparent">> => TP,
            <<"tracestate">> => TS,
            <<"baggage">> => BG
        },
        ?assertEqual(Trio, maps:get(<<"meta">>, KW)),
        ?assertEqual(Trio, maps:get(trace, next_upstream_event())),
        %% An untraced call sends no `_meta` at all, and its event says
        %% so.
        {ok, #{kwargs := KW2}} = proj_call(<<"com.acme.stub.echo">>, #{}),
        ?assertNot(maps:is_key(<<"meta">>, KW2)),
        ?assertEqual(#{}, maps:get(trace, next_upstream_event()))
    after
        telemetry:detach({?MODULE, up_trace})
    end.

%% @private
next_upstream_event() ->
    receive
        {upstream_call_stop, Meta} -> Meta
    after 5000 ->
        error(upstream_call_event_missing)
    end.

sse_response_and_server_ping(_) ->
    %% The stub answers this call as an SSE stream: an unrelated
    %% notification first (a naive first-message parse fails on it), then
    %% a server→client `ping` request, then the response. The call must
    %% succeed, and the ping must receive its post-hoc answer.
    true = ets:insert(?TAB, {sse_mode, true}),
    try
        {ok, #{kwargs := KW}} = proj_call(
            <<"com.acme.stub.echo">>, #{<<"via">> => <<"sse">>}
        ),
        ?assertEqual(#{<<"via">> => <<"sse">>}, maps:get(<<"echoed">>, KW)),
        ok = wait_until(fun() ->
            ets:lookup(?TAB, pong) == [{pong, true}]
        end)
    after
        true = ets:insert(?TAB, {sse_mode, false})
    end.

session_expiry_reinitializes(_) ->
    [{_, C0}] = ets:lookup(?TAB, init_count),
    %% The stub terminates every session server-side: requests with the
    %% old ids now answer 404 (transport §Session Management).
    true = ets:match_delete(?TAB, {{session, '_'}, '_'}),
    {ok, #{kwargs := _}} = proj_call(<<"com.acme.stub.echo">>, #{}),
    [{_, C1}] = ets:lookup(?TAB, init_count),
    %% Exactly one re-initialization for the one expired caller: the
    %% single-flight owner path (`stub2` did not call, so it did not
    %% reconnect).
    ?assertEqual(C0 + 1, C1).

metrics_upstream_series(_) ->
    Node = bondy_config:node(),
    OkLabel = #{node => Node, upstream => <<"stub">>, status => success},
    ErrLabel = #{node => Node, upstream => <<"stub">>, status => tool_error},
    DurLabel = #{node => Node, upstream => <<"stub">>},
    Ok0 = mval(bondy_mcp_upstream_calls_total, OkLabel),
    Err0 = mval(bondy_mcp_upstream_calls_total, ErrLabel),
    D0 = hcount(bondy_mcp_upstream_call_duration_microseconds, DurLabel),

    {ok, _} = proj_call(<<"com.acme.stub.echo">>, #{<<"m">> => 1}),
    %% The upstream's isError result must COUNT as tool_error — a
    %% classification collapsed to one status fails one of these two.
    {error, _} = proj_call(<<"com.acme.stub.boom">>, #{}),

    ?assertEqual(Ok0 + 1, mval(bondy_mcp_upstream_calls_total, OkLabel)),
    ?assertEqual(Err0 + 1, mval(bondy_mcp_upstream_calls_total, ErrLabel)),
    ?assertEqual(
        D0 + 2,
        hcount(bondy_mcp_upstream_call_duration_microseconds, DurLabel)
    ).

drift_blocks_until_approved(_) ->
    %% Drift stub2's `boom` (each upstream pins independently, so
    %% `stub`'s registrations are untouched throughout).
    DriftLabel = #{node => bondy_config:node(), upstream => <<"stub2">>},
    Blocked0 = mval(bondy_mcp_upstream_drift_blocked_total, DriftLabel),
    [{_, V1}] = ets:lookup(?TAB, {tool, <<"boom">>}),
    V2 = V1#{<<"description">> => <<"Changed upstream">>},
    true = ets:insert(?TAB, {{tool, <<"boom">>}, V2}),
    try
        ok = bondy_mcp_upstream:refresh(<<"stub2">>),
        {ok, Info1} = bondy_mcp_upstream:info(<<"stub2">>),
        ?assertEqual([<<"boom">>], maps:get(blocked, Info1)),
        %% The pin gate counted the block (§15, as-built extension).
        ?assert(
            mval(bondy_mcp_upstream_drift_blocked_total, DriftLabel) >=
                Blocked0 + 1
        ),
        ?assertNot(
            is_map_key(<<"boom">>, maps:get(registered, Info1))
        ),
        %% The drifted tool is gone from the registry...
        {error, #{kind := wamp, uri := <<"wamp.error.no_such_procedure">>}} =
            proj_call(<<"com.acme.stub2.boom">>, #{}),
        %% ...while its sibling and the other upstream still serve.
        {ok, _} = proj_call(<<"com.acme.stub2.echo">>, #{}),
        {error, #{uri := <<"bondy.error.mcp.upstream_tool_error">>}} =
            proj_call(<<"com.acme.stub.boom">>, #{}),

        %% Explicit re-approval re-pins at the CURRENT definition and
        %% restores the registration.
        ok = bondy_mcp_upstream:approve(<<"stub2">>, <<"boom">>),
        {error, #{uri := <<"bondy.error.mcp.upstream_tool_error">>}} =
            proj_call(<<"com.acme.stub2.boom">>, #{}),
        {ok, Info2} = bondy_mcp_upstream:info(<<"stub2">>),
        ?assertEqual([], maps:get(blocked, Info2))
    after
        %% Restore v1 and re-approve it so the suite ends consistent.
        true = ets:insert(?TAB, {{tool, <<"boom">>}, V1}),
        ok = bondy_mcp_upstream:refresh(<<"stub2">>),
        _ = bondy_mcp_upstream:approve(<<"stub2">>, <<"boom">>)
    end.

namespace_isolation_across_upstreams(_) ->
    %% The same upstream tool name serves under each upstream's own
    %% prefix — neither shadows the other.
    {ok, _} = proj_call(<<"com.acme.stub.echo">>, #{}),
    {ok, _} = proj_call(<<"com.acme.stub2.echo">>, #{}).

audit_records_the_service_account(_) ->
    %% Records reach the audit seam as `[bondy, mcp, audit, record]`
    %% telemetry (MCP-D27: no local sink) — capture them there.
    Self = self(),
    Id = {?MODULE, make_ref()},
    ok = telemetry:attach(
        Id,
        [bondy, mcp, audit, record],
        fun(_, _, #{record := R}, _) -> Self ! {audit, R} end,
        undefined
    ),
    try
        {ok, _} = proj_call(<<"com.acme.stub.echo">>, #{<<"a">> => 1}),
        R = receive_upstream_record(),
        ?assertEqual(
            <<"service:", ?STUB_SVC/binary>>, maps:get(principal, R)
        ),
        ?assertEqual(
            #{
                type => service_account,
                service => ?STUB_SVC,
                upstream => <<"stub">>
            },
            maps:get(derivation, R)
        )
    after
        telemetry:detach(Id)
    end.

%% The audited upstream call may interleave with other records (the
%% projected tool_call itself) — wait for the first upstream_call.
receive_upstream_record() ->
    receive
        {audit, #{type := upstream_call} = R} -> R;
        {audit, _} -> receive_upstream_record()
    after 5000 ->
        error(no_upstream_audit_record)
    end.

pin_hash_is_canonical(_) ->
    %% The hash must equal SHA-256 over an INDEPENDENTLY constructed
    %% key-sorted JSON encoding. Insertion-order tricks cannot falsify
    %% the sort — equal maps iterate identically however they were
    %% built — so the expectation is built from an explicit
    %% `lists:sort/1`. The schema is > 32 keys deliberately: a large
    %% map's own iteration order is not sorted, so an implementation
    %% that stops sorting diverges here.
    Keys = [
        <<"k", (integer_to_binary(N))/binary>>
     || N <- lists:seq(1, 40)
    ],
    Schema = maps:from_list([{K, #{}} || K <- Keys]),
    D1 = #{<<"name">> => <<"t">>, <<"inputSchema">> => Schema},
    Inner = [[$", K, <<"\":{}">>] || K <- lists:sort(Keys)],
    Expected = iolist_to_binary([
        <<"{\"inputSchema\":{">>,
        lists:join($,, Inner),
        <<"},\"name\":\"t\"}">>
    ]),
    ExpectedHash = <<
        "sha256:",
        (binary:encode_hex(
            crypto:hash(sha256, Expected), lowercase
        ))/binary
    >>,
    ?assertEqual(ExpectedHash, bondy_mcp_upstream:pin_hash(D1)),
    %% And a normative-field change changes the hash.
    ?assertNotEqual(
        bondy_mcp_upstream:pin_hash(D1),
        bondy_mcp_upstream:pin_hash(D1#{<<"description">> => <<"v2">>})
    ),
    %% While a non-normative field does not.
    ?assertEqual(
        bondy_mcp_upstream:pin_hash(D1),
        bondy_mcp_upstream:pin_hash(D1#{<<"_meta">> => #{<<"x">> => 1}})
    ).

projection_via_real_bondy_upstream(_) ->
    %% WAMP → upstream owner → Streamable HTTP → Bondy's own MCP server
    %% (handshake era: initialize, session id, version header) → WAMP →
    %% the UP_REALM callee → all the way back.
    {ok, #{kwargs := KW}} = proj_call(
        <<"com.acme.self.up_echo">>, #{<<"x">> => 7}
    ),
    ?assertEqual(<<"up">>, maps:get(<<"via">>, KW)),
    ?assertEqual(7, maps:get(<<"x">>, KW)).

invalid_declarations_refuse_start(_) ->
    Good = upstreams(),
    [U1, U2 | _] = Good,
    _ = supervisor:terminate_child(bondy_mcp_sup, bondy_mcp_upstream_sup),
    _ = supervisor:delete_child(bondy_mcp_sup, bondy_mcp_upstream_sup),
    try
        %% Two upstreams sharing a realm+prefix: refused (§13.3).
        ok = application:set_env(bondy_mcp, upstreams, [
            U1, U2#{prefix => maps:get(prefix, U1)}
        ]),
        ?assertMatch({error, _}, bondy_mcp_sup:start_upstreams()),

        %% An upstream without the explicit identity declaration:
        %% refused (§13.1) — both the missing-key shape and a present
        %% key with a value other than `service` (the two are enforced
        %% by distinct mechanisms in the owner's init).
        ok = application:set_env(bondy_mcp, upstreams, [
            maps:remove(identity, U1)
        ]),
        ?assertMatch({error, _}, bondy_mcp_sup:start_upstreams()),
        ok = application:set_env(bondy_mcp, upstreams, [
            U1#{identity => none}
        ]),
        ?assertMatch({error, _}, bondy_mcp_sup:start_upstreams()),

        %% A reserved prefix: refused.
        ok = application:set_env(bondy_mcp, upstreams, [
            U1#{prefix => <<"bondy.up">>}
        ]),
        ?assertMatch({error, _}, bondy_mcp_sup:start_upstreams())
    after
        ok = application:set_env(bondy_mcp, upstreams, Good),
        {ok, _} = bondy_mcp_sup:start_upstreams(),
        ok = wait_projected([<<"com.acme.stub.echo">>])
    end.

%% =============================================================================
%% STUB MCP SERVER (cowboy handler)
%% =============================================================================

init(Req0, ok) ->
    {ok, cowboy_req:reply(200, #{}, <<>>, Req0), ok};
init(Req0, token) ->
    {ok, _, Req1} = cowboy_req:read_body(Req0),
    Body = json:encode(#{<<"access_token">> => ?TOKEN}),
    Req = cowboy_req:reply(
        200, #{<<"content-type">> => <<"application/json">>}, Body, Req1
    ),
    {ok, Req, token};
init(Req0, stub) ->
    Expected = <<"Bearer ", ?TOKEN/binary>>,
    case cowboy_req:header(<<"authorization">>, Req0) of
        Expected ->
            stub_handle(cowboy_req:method(Req0), Req0);
        _ ->
            {ok, cowboy_req:reply(401, Req0), stub}
    end.

%% @private
stub_handle(<<"DELETE">>, Req0) ->
    case cowboy_req:header(<<"mcp-session-id">>, Req0) of
        undefined -> ok;
        Session -> true = ets:delete(?TAB, {session, Session})
    end,
    {ok, cowboy_req:reply(204, Req0), stub};
stub_handle(<<"POST">>, Req0) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Msg = json:decode(Body),
    case maps:get(<<"method">>, Msg, undefined) of
        <<"initialize">> ->
            stub_initialize(Msg, Req1);
        Method ->
            stub_established(Method, Msg, Req1)
    end;
stub_handle(_, Req0) ->
    {ok, cowboy_req:reply(405, Req0), stub}.

%% @private
stub_initialize(#{<<"id">> := Id}, Req0) ->
    N = ets:update_counter(?TAB, init_count, 1),
    Session = <<"stub-", (integer_to_binary(N))/binary>>,
    true = ets:insert(?TAB, {{session, Session}, true}),
    Result = #{
        <<"protocolVersion">> => <<"2025-11-25">>,
        <<"capabilities">> => #{<<"tools">> => #{<<"listChanged">> => true}},
        <<"serverInfo">> => #{
            <<"name">> => <<"stub">>, <<"version">> => <<"1">>
        }
    },
    reply_json(
        200,
        #{<<"mcp-session-id">> => Session},
        bondy_json_rpc:result_response(Id, Result),
        Req0
    ).

%% @private
%% Every established request must carry the negotiated version header
%% (transport §Protocol Version Header) and the live session id.
stub_established(Method, Msg, Req0) ->
    VersionOk =
        cowboy_req:header(<<"mcp-protocol-version">>, Req0) ==
            <<"2025-11-25">>,
    SessionOk =
        case cowboy_req:header(<<"mcp-session-id">>, Req0) of
            undefined -> false;
            Session -> ets:member(?TAB, {session, Session})
        end,
    case {VersionOk, SessionOk} of
        {false, _} ->
            {ok, cowboy_req:reply(400, Req0), stub};
        {_, false} ->
            {ok, cowboy_req:reply(404, Req0), stub};
        {true, true} ->
            stub_dispatch(Method, Msg, Req0)
    end.

%% @private
stub_dispatch(
    undefined, #{<<"id">> := <<"srv-ping">>, <<"result">> := _}, Req0
) ->
    %% The client's post-hoc answer to our in-stream ping.
    true = ets:insert(?TAB, {pong, true}),
    {ok, cowboy_req:reply(202, Req0), stub};
stub_dispatch(undefined, _, Req0) ->
    {ok, cowboy_req:reply(202, Req0), stub};
stub_dispatch(<<"notifications/", _/binary>>, _, Req0) ->
    {ok, cowboy_req:reply(202, Req0), stub};
stub_dispatch(<<"tools/list">>, #{<<"id">> := Id} = Msg, Req0) ->
    Params = maps:get(<<"params">>, Msg, #{}),
    [{_, Echo}] = ets:lookup(?TAB, {tool, <<"echo">>}),
    [{_, Boom}] = ets:lookup(?TAB, {tool, <<"boom">>}),
    Result =
        case maps:get(<<"cursor">>, Params, undefined) of
            undefined ->
                #{<<"tools">> => [Echo], <<"nextCursor">> => <<"p2">>};
            <<"p2">> ->
                #{<<"tools">> => [Boom]}
        end,
    reply_json(200, #{}, bondy_json_rpc:result_response(Id, Result), Req0);
stub_dispatch(<<"tools/call">>, #{<<"id">> := Id} = Msg, Req0) ->
    #{<<"params">> := #{<<"name">> := Name} = Params} = Msg,
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    case Name of
        <<"echo">> ->
            %% `_meta` (when sent) is echoed under `meta` so the trace
            %% case can assert on it; absent, the response shape every
            %% other case pins is unchanged.
            Structured =
                case maps:get(<<"_meta">>, Params, undefined) of
                    undefined -> #{<<"echoed">> => Arguments};
                    Meta -> #{<<"echoed">> => Arguments, <<"meta">> => Meta}
                end,
            Result = #{
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"ok">>}
                ],
                <<"structuredContent">> => Structured,
                <<"isError">> => false
            },
            Response = bondy_json_rpc:result_response(Id, Result),
            case ets:lookup(?TAB, sse_mode) of
                [{_, true}] ->
                    reply_sse(Response, Req0);
                _ ->
                    reply_json(200, #{}, Response, Req0)
            end;
        <<"boom">> ->
            Result = #{
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"kaput">>}
                ],
                <<"structuredContent">> => #{<<"reason">> => <<"kaput">>},
                <<"isError">> => true
            },
            reply_json(
                200, #{}, bondy_json_rpc:result_response(Id, Result), Req0
            );
        _ ->
            reply_json(
                200,
                #{},
                bondy_json_rpc:error_response(
                    Id, -32602, <<"Unknown tool">>
                ),
                Req0
            )
    end;
stub_dispatch(_, #{<<"id">> := Id}, Req0) ->
    reply_json(
        200,
        #{},
        bondy_json_rpc:error_response(Id, -32601, <<"Method not found">>),
        Req0
    ).

%% @private
reply_json(Status, Headers0, Payload, Req0) ->
    Headers = Headers0#{<<"content-type">> => <<"application/json">>},
    Req = cowboy_req:reply(
        Status, Headers, bondy_json_rpc:encode(Payload), Req0
    ),
    {ok, Req, stub}.

%% @private
%% An SSE-framed response preceded by every shape a client must NOT take
%% for its answer: an unrelated notification, a stale RESPONSE carrying a
%% foreign id (a resumed/replayed message — only id-matching excludes
%% it), and a server→client `ping` request. A client that takes the
%% first message, the first response-shaped message, or a request fails
%% here.
reply_sse(Response, Req0) ->
    Noise = bondy_json_rpc:notification(
        <<"notifications/message">>, #{<<"level">> => <<"info">>}
    ),
    Stale = bondy_json_rpc:result_response(-1, #{
        <<"stale">> => true
    }),
    Ping = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => <<"srv-ping">>,
        <<"method">> => <<"ping">>
    },
    Body = [
        sse_event(Noise),
        sse_event(Stale),
        sse_event(Ping),
        sse_event(Response)
    ],
    Req = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"text/event-stream">>},
        Body,
        Req0
    ),
    {ok, Req, stub}.

%% @private
sse_event(Msg) ->
    [
        <<"event: message\ndata: ">>,
        bondy_json_rpc:encode(Msg),
        <<"\n\n">>
    ].

%% @private
stub_reset() ->
    true = ets:insert(?TAB, [
        {init_count, 0},
        {pong, false},
        {sse_mode, false},
        {{tool, <<"echo">>}, #{
            <<"name">> => <<"echo">>,
            <<"description">> => <<"Echoes v1">>,
            <<"inputSchema">> => #{<<"type">> => <<"object">>}
        }},
        {{tool, <<"boom">>}, #{
            <<"name">> => <<"boom">>,
            <<"description">> => <<"Always errors">>,
            <<"inputSchema">> => #{<<"type">> => <<"object">>}
        }}
    ]),
    ok.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% Current value of a counter/gauge cell, 0 when never touched.
mval(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        undefined -> 0;
        V when is_integer(V) -> V
    end.

%% @private
%% Observation count of a histogram cell, 0 when never touched.
hcount(Name, Label) ->
    case bondy_metrics:histogram_snapshot(#{name => Name, label => Label}) of
        {ok, #{count := C}} -> C;
        not_found -> 0
    end.

%% @private
%% A fresh local SDK session per call: cases run in different processes
%% and the connection is process-bound.
proj_call(Uri, KWArgs) ->
    proj_call(Uri, KWArgs, #{}).

%% @private
proj_call(Uri, KWArgs, Opts) ->
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => local,
        endpoint => local,
        realm => ?PROJ_REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    }),
    try
        bondy_connect_client:call(Conn, Uri, [], KWArgs, Opts)
    after
        bondy_connect_client:disconnect(Conn)
    end.

%% @private
spawn_callee_owner() ->
    Caller = self(),
    Owner = spawn(fun() ->
        {ok, Conn} = bondy_connect_client:connect(#{
            transport => local,
            endpoint => local,
            realm => ?UP_REALM,
            auth => #{method => ?WAMP_ANON_AUTH},
            serializers => [json]
        }),
        {ok, _} = bondy_connect_client:register(
            Conn, ?UP_ECHO, fun(_, KwArgs, _) ->
                {ok, #{kwargs => KwArgs#{<<"via">> => <<"up">>}}}
            end
        ),
        Caller ! {callee_ready, self()},
        receive
            stop -> bondy_connect_client:disconnect(Conn)
        end
    end),
    receive
        {callee_ready, Owner} -> Owner
    after 10000 ->
        error(callee_owner_timeout)
    end.

%% @private
wait_projected(Uris) ->
    ok = wait_until(fun() ->
        lists:all(
            fun(Uri) ->
                case proj_call(Uri, #{}) of
                    {ok, _} ->
                        true;
                    {error, #{kind := wamp, uri := EUri}} ->
                        %% `boom` projects and then errors by design.
                        EUri ==
                            <<"bondy.error.mcp.upstream_tool_error">>;
                    {error, _} ->
                        false
                end
            end,
            Uris
        )
    end).

%% @private
wait_until(Fun) ->
    wait_until(Fun, 300).

%% @private
wait_until(_, 0) ->
    error(wait_until_timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(Fun, N - 1)
    end.
