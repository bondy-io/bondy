%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_mcp_handshake_SUITE).

-moduledoc """
The handshake protocol era (design §12, §21 increment 8) over a real
socket: `initialize` creates a `bondy_http_transport_session`-backed
session named by `Mcp-Session-Id`; every subsequent request authenticates
at the HTTP layer AND binds to the session's principal; the held `GET`
stream serves `resources/subscribe` updates and list-changed
notifications with the transport queue as its disconnection backlog;
`notifications/cancelled` cancels the in-flight WAMP call; `DELETE`
closes gracefully; and the idle timer counts only POSTs — an open GET
stream does not keep a session alive.

Like the modern suite, this one mounts the carrier's REAL routes on its
own cowboy listener and never touches the node-global listener manager.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_router/include/bondy_security.hrl").

-define(OPEN_REALM, <<"com.bondy.mcp.hs.open">>).
-define(RBAC_REALM, <<"com.bondy.mcp.hs.rbac">>).
-define(ECHO, <<"com.example.mcp.hs.echo">>).
-define(GET_USER, <<"com.example.mcp.hs.get_user">>).
-define(XHDR, <<"com.example.mcp.hs.xhdr">>).
-define(SLOW, <<"com.example.mcp.hs.slow">>).
-define(APPROVE, <<"com.example.mcp.hs.approve">>).
-define(ALLOWED, <<"com.example.mcp.hs.rbac.allowed">>).
-define(DENIED, <<"com.example.mcp.hs.rbac.denied">>).
-define(TICKS, <<"com.example.mcp.hs.ticks">>).
-define(TICKS_RESOURCE, <<"wamp:", ?OPEN_REALM/binary, ":", ?TICKS/binary>>).
-define(INPUT_REQUIRED_URI, <<"bondy.error.mcp.input_required">>).
-define(USER, <<"mcp_hs_user_1">>).
-define(USER2, <<"mcp_hs_user_2">>).
-define(PASSWORD, <<"aWamp2Password">>).
-define(LATEST, <<"2025-11-25">>).
-define(OLDER, <<"2025-06-18">>).
-define(MODERN, <<"2026-07-28">>).
-define(LISTENER, ct_mcp_handshake).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        initialize_negotiates_and_mints_a_session,
        initialize_on_modern_only_endpoint_is_refused,
        repeat_initialize_is_rejected,
        established_requests_require_the_session,
        session_is_bound_to_the_principal,
        auth_is_per_request_not_per_session,
        ping_and_initialized,
        tools_call_round_trip_shares_the_session_identity,
        input_required_callee_is_a_plain_tool_error,
        param_headers_are_not_required,
        lists_and_stale_cursor,
        rbac_projection_and_status_dialect,
        resource_lists,
        resources_subscribe_round_trip,
        notifications_buffer_while_disconnected,
        second_get_stream_is_conflict,
        list_changed_reaches_the_stream,
        cancelled_notification_cancels_the_call,
        delete_terminates_the_session,
        idle_timeout_ignores_the_open_stream,
        metrics_session_and_call_series,
        metrics_version_refused_series,
        metrics_rbac_denied_series,
        metrics_notifications_series,
        transport_lifecycle_close_reasons_and_active_gauge
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    %% These cases pin the edge protocol machinery, not the exposure
    %% policy: run under `derived` so URI-named fixture tools exist
    %% without an overlay entry each. The shipped default (`curated`)
    %% is pinned by bondy_mcp_gateway_SUITE.
    ok = application:set_env(bondy_mcp, manifest_mode, derived),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(gun),

    Open = bondy_realm:create(?OPEN_REALM),
    ok = bondy_realm:disable_security(Open),
    _ = bondy_realm:create(#{
        uri => ?RBAC_REALM,
        description => <<"MCP handshake RBAC">>,
        authmethods => [?PASSWORD_AUTH],
        security_enabled => true,
        groups => [#{name => <<"mcp_hs_users">>}],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => ?ALLOWED,
                match => <<"exact">>,
                roles => [<<"mcp_hs_users">>]
            }
        ],
        users => [
            #{
                username => U,
                password => ?PASSWORD,
                groups => [<<"mcp_hs_users">>],
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
    }),

    ok = bondy_interface:load(#{
        <<"id">> => <<"mcp_hs_iface">>,
        <<"entries">> =>
            [
                #{
                    <<"realm">> => ?OPEN_REALM,
                    <<"kind">> => <<"procedure">>,
                    <<"uri">> => Uri
                }
             || Uri <- [?ECHO, ?XHDR, ?SLOW, ?APPROVE]
            ] ++
            [
                #{
                    <<"realm">> => ?OPEN_REALM,
                    <<"kind">> => <<"topic">>,
                    <<"uri">> => ?TICKS
                }
            ] ++
            [
                #{
                    <<"realm">> => ?RBAC_REALM,
                    <<"kind">> => <<"procedure">>,
                    <<"uri">> => Uri
                }
             || Uri <- [?ALLOWED, ?DENIED]
            ]
    }),
    ok = bondy_mcp_gateway:load(#{
        <<"id">> => <<"mcp_hs_overlay">>,
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
                    <<"com.example.mcp.hs.user.{{id}}.changed">>,
                <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
            },
            %% The `x-mcp-header` annotation whose HEADERS only the
            %% modern era requires.
            #{
                <<"realm">> => ?OPEN_REALM,
                <<"name">> => <<"region_tool">>,
                <<"kind">> => <<"tool">>,
                <<"wamp_procedure">> => ?XHDR,
                <<"kwargs_schema">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"region">> => #{
                            <<"type">> => <<"string">>,
                            <<"x-mcp-header">> => <<"Region">>
                        }
                    }
                }
            }
        ]
    }),

    Owner = spawn_callee_owner(),

    Routes = bondy_mcp_http_service:routes(
        mcp,
        #{config => carrier_config()},
        #{name => ?LISTENER, transport => tcp}
    ),
    {ok, _} = cowboy:start_clear(
        ?LISTENER,
        [{port, 0}],
        #{env => #{dispatch => cowboy_router:compile(Routes)}}
    ),
    Port = ranch:get_port(?LISTENER),
    [{port, Port}, {callee_owner, Owner} | Config].

end_per_suite(Config) ->
    ok = application:set_env(bondy_mcp, manifest_mode, curated),
    ?config(callee_owner, Config) ! stop,
    ok = cowboy:stop_listener(?LISTENER),
    ok = bondy_interface:delete(<<"mcp_hs_iface">>),
    ok = bondy_mcp_gateway:delete(<<"mcp_hs_overlay">>),
    _ = bondy_mcp_gateway:delete(<<"mcp_hs_overlay2">>),
    _ = bondy_mcp_gateway:delete(<<"mcp_hs_overlay3">>),
    {save_config, Config}.

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, _Config) ->
    %% A case that shrank the transport idle timeout restores it.
    bondy_config:set([http_transport, idle_timeout], 3600000),
    ok.

carrier_config() ->
    #{
        protocol_versions => [?MODERN, ?LATEST, ?OLDER],
        allowed_origins => [local],
        public_base_uri => undefined,
        max_body_size => 1048576,
        max_inflight => 64,
        idle_timeout => 600000,
        list => #{default_page_size => 2},
        schema => #{max_depth => 32, max_validation_ms => 50}
    }.

%% =============================================================================
%% CASES — lifecycle (§12.1)
%% =============================================================================

initialize_negotiates_and_mints_a_session(Config) ->
    %% A supported requested version is echoed.
    {200, Headers, #{<<"result">> := R1}} = post_init(
        Config, ?OPEN_REALM, ?OLDER, []
    ),
    ?assertEqual(?OLDER, maps:get(<<"protocolVersion">>, R1)),
    %% The session id is node-prefixed and visible ASCII, and parses.
    SessionId = session_header(Headers),
    ?assertMatch(
        {ok, _, _}, bondy_mcp_handshake:parse_session_id(SessionId)
    ),
    {ok, Node, _} = bondy_mcp_handshake:parse_session_id(SessionId),
    ?assertEqual(bondy_config:nodestring(), Node),
    ?assert(
        lists:all(
            fun(C) -> C >= 16#21 andalso C =< 16#7E end,
            binary_to_list(SessionId)
        )
    ),
    %% Capabilities and serverInfo per §12.1.
    ?assertMatch(
        #{
            <<"tools">> := #{<<"listChanged">> := true},
            <<"resources">> := #{
                <<"subscribe">> := true, <<"listChanged">> := true
            }
        },
        maps:get(<<"capabilities">>, R1)
    ),
    ?assertMatch(#{<<"name">> := <<"Bondy">>}, maps:get(<<"serverInfo">>, R1)),
    %% An unsupported requested version negotiates to the latest carried.
    {200, Headers2, #{<<"result">> := R2}} = post_init(
        Config, ?OPEN_REALM, <<"2027-01-01">>, []
    ),
    ?assertEqual(?LATEST, maps:get(<<"protocolVersion">>, R2)),
    ok = delete_session(Config, ?OPEN_REALM, session_header(Headers2), []),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

initialize_on_modern_only_endpoint_is_refused(_Config) ->
    ModernOnly = (carrier_config())#{protocol_versions => [?MODERN]},
    Routes = bondy_mcp_http_service:routes(
        mcp,
        #{config => ModernOnly},
        #{name => ct_mcp_hs_modern_only, transport => tcp}
    ),
    {ok, _} = cowboy:start_clear(
        ct_mcp_hs_modern_only,
        [{port, 0}],
        #{env => #{dispatch => cowboy_router:compile(Routes)}}
    ),
    Port = ranch:get_port(ct_mcp_hs_modern_only),
    try
        %% The lifecycle specification's own error shape, naming what IS
        %% supported.
        {200, _, #{<<"error">> := Err}} = do_post_init(
            Port, ?OPEN_REALM, ?LATEST, []
        ),
        ?assertMatch(
            #{
                <<"code">> := -32602,
                <<"data">> := #{<<"supported">> := [?MODERN]}
            },
            Err
        ),
        %% GET and DELETE do not exist on a modern-only endpoint; 405 is
        %% exactly the transport spec's "no SSE stream offered".
        Url = url(Port, ?OPEN_REALM),
        {ok, {{_, 405, _}, _, _}} = httpc:request(
            get, {Url, [{"mcp-session-id", "x.y"}]}, [], []
        ),
        {ok, {{_, 405, _}, _, _}} = httpc:request(
            delete, {Url, [{"mcp-session-id", "x.y"}]}, [], []
        )
    after
        cowboy:stop_listener(ct_mcp_hs_modern_only)
    end.

repeat_initialize_is_rejected(Config) ->
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {200, _, #{<<"error">> := Err}} = post_init(
        Config, ?OPEN_REALM, ?LATEST, [session(SessionId)]
    ),
    ?assertMatch(#{<<"code">> := -32600}, Err),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

established_requests_require_the_session(Config) ->
    %% A handshake-version request without a session id: the transport
    %% spec's 400.
    {400, _, #{<<"error">> := #{<<"code">> := -32600}}} = post_hs(
        Config,
        ?OPEN_REALM,
        [{"mcp-protocol-version", binary_to_list(?LATEST)}],
        req(1, <<"tools/list">>, #{})
    ),
    %% An unknown session id is 404 with the session-not-found code — the
    %% client MUST re-initialize.
    Fake = binary_to_list(
        bondy_mcp_handshake:mint_session_id(
            bondy_utils:uuid()
        )
    ),
    {404, _, #{<<"error">> := #{<<"code">> := -32001}}} = post_hs(
        Config,
        ?OPEN_REALM,
        [{"mcp-session-id", Fake}],
        req(2, <<"tools/list">>, #{})
    ),
    %% A session owned by another node answers the same 404 (forwarding
    %% is a recorded deviation; re-initializing here is the recovery the
    %% spec mandates).
    {404, _, #{<<"error">> := #{<<"code">> := -32001}}} = post_hs(
        Config,
        ?OPEN_REALM,
        [
            {"mcp-session-id",
                "other@203.0.113.9." ++
                    binary_to_list(bondy_utils:uuid())}
        ],
        req(3, <<"tools/list">>, #{})
    ),
    %% The real session works — and its list result speaks the handshake
    %% dialect: no modern envelope keys.
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {200, _, #{<<"result">> := R}} = post_session(
        Config, ?OPEN_REALM, SessionId, req(4, <<"tools/list">>, #{})
    ),
    ?assert(maps:is_key(<<"tools">>, R)),
    ?assertNot(maps:is_key(<<"resultType">>, R)),
    ?assertNot(maps:is_key(<<"ttlMs">>, R)),
    %% A session presented against a different realm's URL is the same
    %% 404 an unknown session gets.
    {404, _, _} = post_hs(
        Config,
        ?RBAC_REALM,
        [
            {"mcp-session-id", binary_to_list(SessionId)},
            basic_auth(?USER, ?PASSWORD)
        ],
        req(5, <<"tools/list">>, #{})
    ),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

session_is_bound_to_the_principal(Config) ->
    %% THE binding falsifier: a second principal with the same grants
    %% presenting user 1's session id gets the unknown-session answer,
    %% while user 1's own next request passes (the control).
    Auth1 = basic_auth(?USER, ?PASSWORD),
    Auth2 = basic_auth(?USER2, ?PASSWORD),
    SessionId = initialize(Config, ?RBAC_REALM, [Auth1]),
    {404, _, #{<<"error">> := #{<<"code">> := -32001}}} = post_session(
        Config, ?RBAC_REALM, SessionId, req(1, <<"tools/list">>, #{}), [Auth2]
    ),
    {200, _, #{<<"result">> := _}} = post_session(
        Config, ?RBAC_REALM, SessionId, req(2, <<"tools/list">>, #{}), [Auth1]
    ),
    ok = delete_session(Config, ?RBAC_REALM, SessionId, [Auth1]).

auth_is_per_request_not_per_session(Config) ->
    %% Sessions are never credentials (security best practices MUST):
    %% a session-carrying request with no or bad credentials is 401.
    Auth = basic_auth(?USER, ?PASSWORD),
    SessionId = initialize(Config, ?RBAC_REALM, [Auth]),
    {401, _, _} = post_session(
        Config, ?RBAC_REALM, SessionId, req(1, <<"tools/list">>, #{}), []
    ),
    {401, _, _} = post_session(
        Config,
        ?RBAC_REALM,
        SessionId,
        req(2, <<"tools/list">>, #{}),
        [basic_auth(?USER, <<"wrong">>)]
    ),
    ok = delete_session(Config, ?RBAC_REALM, SessionId, [Auth]).

ping_and_initialized(Config) ->
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {202, _, _} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        notif(<<"notifications/initialized">>, #{})
    ),
    {200, _, #{<<"result">> := R}} = post_session(
        Config, ?OPEN_REALM, SessionId, req(1, <<"ping">>, #{})
    ),
    ?assertEqual(#{}, R),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

%% =============================================================================
%% CASES — requests through the session
%% =============================================================================

tools_call_round_trip_shares_the_session_identity(Config) ->
    SessionId = initialize(Config, ?OPEN_REALM, []),
    Ref = attach_audit_telemetry(),
    {200, _, #{<<"result">> := R1}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(1, <<"tools/call">>, #{
            <<"name">> => ?ECHO,
            <<"arguments">> => #{<<"n">> => 1}
        })
    ),
    ?assertMatch(#{<<"isError">> := false}, R1),
    {200, _, _} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(2, <<"tools/call">>, #{
            <<"name">> => ?ECHO,
            <<"arguments">> => #{<<"n">> => 2}
        })
    ),
    %% Both audit records carry the SAME session id — the MCP session's
    %% stored WAMP session — where modern per-request records each mint
    %% their own. This is the §14 identity the handshake era adds.
    [S1, S2] = [
        maps:get(session_id, Record)
     || Record <- collect_audit(Ref, 2)
    ],
    detach_audit_telemetry(Ref),
    ?assert(is_binary(S1)),
    ?assertEqual(S1, S2),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

input_required_callee_is_a_plain_tool_error(Config) ->
    %% The MRTR result type does not exist in these revisions: the §11.1
    %% callee signal surfaces as an ordinary tool error, never as an
    %% InputRequiredResult.
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {200, _, #{<<"result">> := R}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(1, <<"tools/call">>, #{
            <<"name">> => ?APPROVE, <<"arguments">> => #{}
        })
    ),
    ?assertMatch(#{<<"isError">> := true}, R),
    ?assertNot(maps:is_key(<<"inputRequests">>, R)),
    ?assertNot(maps:is_key(<<"requestState">>, R)),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

param_headers_are_not_required(Config) ->
    %% `Mcp-Param-{Name}` is a modern mechanism; the same tool whose
    %% modern call REQUIRES the Region header answers a handshake call
    %% without it.
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {200, _, #{<<"result">> := R}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(1, <<"tools/call">>, #{
            <<"name">> => <<"region_tool">>,
            <<"arguments">> => #{<<"region">> => <<"emea">>}
        })
    ),
    ?assertMatch(#{<<"isError">> := false}, R),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

lists_and_stale_cursor(Config) ->
    SessionId = initialize(Config, ?OPEN_REALM, []),
    %% Page size 2: the first page carries a cursor.
    {200, _, #{<<"result">> := P1}} = post_session(
        Config, ?OPEN_REALM, SessionId, req(1, <<"tools/list">>, #{})
    ),
    Cursor = maps:get(<<"nextCursor">>, P1),
    {200, _, #{<<"result">> := P2}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(2, <<"tools/list">>, #{<<"cursor">> => Cursor})
    ),
    Names = [
        maps:get(<<"name">>, T)
     || T <- maps:get(<<"tools">>, P1) ++ maps:get(<<"tools">>, P2)
    ],
    ?assert(lists:member(?ECHO, Names)),
    ?assert(lists:member(<<"region_tool">>, Names)),
    %% Change the manifest, then present the old cursor: §12.7 requires
    %% the stale answer, and the client restarts the listing.
    ok = bondy_mcp_gateway:load(#{
        <<"id">> => <<"mcp_hs_overlay2">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?OPEN_REALM,
                <<"name">> => <<"late_tool">>,
                <<"kind">> => <<"tool">>,
                <<"wamp_procedure">> => ?SLOW
            }
        ]
    }),
    ok = wait_until(
        fun() ->
            {ok, #{entries := E}} = bondy_mcp_gateway:manifest(?OPEN_REALM),
            maps:is_key(<<"late_tool">>, E)
        end,
        10000,
        manifest_rebuild
    ),
    {200, _, #{<<"error">> := Err}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(3, <<"tools/list">>, #{<<"cursor">> => Cursor})
    ),
    ?assertMatch(#{<<"code">> := -32602}, Err),
    ok = bondy_mcp_gateway:delete(<<"mcp_hs_overlay2">>),
    ok = wait_until(
        fun() ->
            {ok, #{entries := E}} = bondy_mcp_gateway:manifest(?OPEN_REALM),
            not maps:is_key(<<"late_tool">>, E)
        end,
        10000,
        manifest_rebuild_back
    ),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

rbac_projection_and_status_dialect(Config) ->
    %% The projection holds in the handshake era, and JSON-RPC-level
    %% failures ride 200 — 404 stays reserved for the SESSION (a modern
    %% 404 here would make the client destroy its session).
    Auth = basic_auth(?USER, ?PASSWORD),
    SessionId = initialize(Config, ?RBAC_REALM, [Auth]),
    {200, _, #{<<"result">> := R}} = post_session(
        Config, ?RBAC_REALM, SessionId, req(1, <<"tools/list">>, #{}), [Auth]
    ),
    Names = [maps:get(<<"name">>, T) || T <- maps:get(<<"tools">>, R)],
    ?assertEqual([?ALLOWED], Names),
    {200, _, #{<<"error">> := E1}} = post_session(
        Config,
        ?RBAC_REALM,
        SessionId,
        req(2, <<"tools/call">>, #{
            <<"name">> => ?DENIED, <<"arguments">> => #{}
        }),
        [Auth]
    ),
    ?assertMatch(#{<<"code">> := -32601}, E1),
    %% An unknown method inside a session: 200 + -32601, not HTTP 404.
    {200, _, #{<<"error">> := E2}} = post_session(
        Config,
        ?RBAC_REALM,
        SessionId,
        req(3, <<"prompts/list">>, #{}),
        [Auth]
    ),
    ?assertMatch(#{<<"code">> := -32601}, E2),
    ok = delete_session(Config, ?RBAC_REALM, SessionId, [Auth]).

resource_lists(Config) ->
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {200, _, #{<<"result">> := R1}} = post_session(
        Config, ?OPEN_REALM, SessionId, req(1, <<"resources/list">>, #{})
    ),
    [TicksRes] = maps:get(<<"resources">>, R1),
    ?assertEqual(?TICKS_RESOURCE, maps:get(<<"uri">>, TicksRes)),
    ?assertEqual(?TICKS, maps:get(<<"name">>, TicksRes)),
    {200, _, #{<<"result">> := R2}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(2, <<"resources/templates/list">>, #{})
    ),
    ?assertMatch(
        [#{<<"uriTemplate">> := <<"users:///{id}">>, <<"name">> := <<"user">>}],
        maps:get(<<"resourceTemplates">>, R2)
    ),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

%% =============================================================================
%% CASES — the GET stream and subscriptions (§12.2, §12.4)
%% =============================================================================

resources_subscribe_round_trip(Config) ->
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {200, _, #{<<"result">> := #{}}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(1, <<"resources/subscribe">>, #{<<"uri">> => <<"users:///42">>})
    ),
    {Conn, Ref, Buf0} = open_stream(Config, ?OPEN_REALM, SessionId, []),
    ok = publish(
        Config, <<"com.example.mcp.hs.user.42.changed">>, [], #{}
    ),
    {Msg, Buf1} = next_or_fail(Conn, Ref, Buf0, 10000),
    ?assertMatch(
        #{
            <<"method">> := <<"notifications/resources/updated">>,
            <<"params">> := #{<<"uri">> := <<"users:///42">>}
        },
        Msg
    ),
    %% A DIFFERENT instantiation of the template is a different update
    %% stream: nothing arrives for it.
    ok = publish(
        Config, <<"com.example.mcp.hs.user.43.changed">>, [], #{}
    ),
    ?assertEqual(timeout, sse_next(Conn, Ref, Buf1, 1500)),
    %% Unsubscribe, then the subscribed stream goes quiet too.
    {200, _, #{<<"result">> := #{}}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(2, <<"resources/unsubscribe">>, #{<<"uri">> => <<"users:///42">>})
    ),
    ok = publish(
        Config, <<"com.example.mcp.hs.user.42.changed">>, [], #{}
    ),
    ?assertEqual(timeout, sse_next(Conn, Ref, Buf1, 1500)),
    %% Unsubscribing what is not subscribed is a visible error.
    {200, _, #{<<"error">> := #{<<"code">> := -32002}}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(3, <<"resources/unsubscribe">>, #{<<"uri">> => <<"users:///42">>})
    ),
    %% An unknown resource answers the resources dialect's -32002.
    {200, _, #{<<"error">> := #{<<"code">> := -32002}}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(4, <<"resources/subscribe">>, #{<<"uri">> => <<"nope:///1">>})
    ),
    ok = gun:close(Conn),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

notifications_buffer_while_disconnected(Config) ->
    %% §12.2's backlog falsifier: events published while NO GET stream is
    %% connected are waiting when one connects.
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {200, _, #{<<"result">> := #{}}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(1, <<"resources/subscribe">>, #{<<"uri">> => <<"users:///7">>})
    ),
    ok = publish(
        Config, <<"com.example.mcp.hs.user.7.changed">>, [], #{}
    ),
    {Conn, Ref, Buf0} = open_stream(Config, ?OPEN_REALM, SessionId, []),
    {Msg, _} = next_or_fail(Conn, Ref, Buf0, 10000),
    ?assertMatch(
        #{
            <<"method">> := <<"notifications/resources/updated">>,
            <<"params">> := #{<<"uri">> := <<"users:///7">>}
        },
        Msg
    ),
    ok = gun:close(Conn),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

second_get_stream_is_conflict(Config) ->
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {Conn1, _Ref1, _} = open_stream(Config, ?OPEN_REALM, SessionId, []),
    {409, Conn2} = open_stream_status(Config, ?OPEN_REALM, SessionId, []),
    ok = gun:close(Conn2),
    ok = gun:close(Conn1),
    %% Once the first stream's death is observed, a new one attaches.
    ok = wait_until(
        fun() ->
            case open_stream_status(Config, ?OPEN_REALM, SessionId, []) of
                {200, C, _} ->
                    gun:close(C),
                    true;
                {_, C} ->
                    gun:close(C),
                    false
            end
        end,
        10000,
        stream_reattach
    ),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

list_changed_reaches_the_stream(Config) ->
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {Conn, Ref, Buf0} = open_stream(Config, ?OPEN_REALM, SessionId, []),
    ok = bondy_mcp_gateway:load(#{
        <<"id">> => <<"mcp_hs_overlay2">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?OPEN_REALM,
                <<"name">> => <<"late_tool">>,
                <<"kind">> => <<"tool">>,
                <<"wamp_procedure">> => ?SLOW
            }
        ]
    }),
    {Msg, _} = next_or_fail(Conn, Ref, Buf0, 10000),
    ?assertMatch(
        #{<<"method">> := <<"notifications/tools/list_changed">>}, Msg
    ),
    ok = gun:close(Conn),
    ok = bondy_mcp_gateway:delete(<<"mcp_hs_overlay2">>),
    ok = wait_until(
        fun() ->
            {ok, #{entries := E}} = bondy_mcp_gateway:manifest(?OPEN_REALM),
            not maps:is_key(<<"late_tool">>, E)
        end,
        10000,
        manifest_rebuild_back
    ),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

%% =============================================================================
%% CASES — cancellation and shutdown (§12.5, §12.8)
%% =============================================================================

cancelled_notification_cancels_the_call(Config) ->
    SessionId = initialize(Config, ?OPEN_REALM, []),
    %% The in-flight call goes over its OWN gun connection —
    %% asynchronously, so this process is free to send the cancellation,
    %% and independent of httpc's session pooling.
    Port = ?config(port, Config),
    {ok, Conn} = gun:open("127.0.0.1", Port, #{
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
    %% Let the call reach the dealer and register in flight.
    timer:sleep(500),
    {202, _, _} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        notif(<<"notifications/cancelled">>, #{
            <<"requestId">> => 77,
            <<"reason">> => <<"user changed their mind">>
        })
    ),
    %% The callee sleeps 8s and the WAMP call timeout is 30s: a response
    %% within 4s proves the WAMP CANCEL released the caller — neither
    %% completion nor timeout can answer that fast.
    {response, nofin, 200, _} = gun:await(Conn, Ref, 4000),
    {ok, RespBody} = gun:await_body(Conn, Ref, 4000),
    #{<<"result">> := CancelledR} = json:decode(RespBody),
    ?assertMatch(#{<<"isError">> := true}, CancelledR),
    ok = gun:close(Conn),
    %% Cancelling a request that is no longer in flight is a no-op.
    {202, _, _} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        notif(<<"notifications/cancelled">>, #{<<"requestId">> => 77})
    ),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

delete_terminates_the_session(Config) ->
    SessionId = initialize(Config, ?OPEN_REALM, []),
    %% DELETE without the header is 400 (§12.8).
    {ok, {{_, 400, _}, _, _}} = httpc:request(
        delete, {url(Config, ?OPEN_REALM), []}, [], []
    ),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []),
    %% The session is gone: requests and a second DELETE answer 404.
    {404, _, _} = post_session(
        Config, ?OPEN_REALM, SessionId, req(1, <<"tools/list">>, #{})
    ),
    {ok, {{_, 404, _}, _, _}} = httpc:request(
        delete,
        {url(Config, ?OPEN_REALM), [
            {"mcp-session-id", binary_to_list(SessionId)}
        ]},
        [],
        []
    ).

idle_timeout_ignores_the_open_stream(Config) ->
    %% §12.8: only POSTs reset the idle timer — an open GET stream does
    %% not. The session is started under a 1.5s TTL; its stream is held
    %% open the whole time; the first inactivity check (the substrate's
    %% 5s floor) must stop it.
    bondy_config:set([http_transport, idle_timeout], 1500),
    SessionId = initialize(Config, ?OPEN_REALM, []),
    {Conn, _Ref, _Buf} = open_stream(Config, ?OPEN_REALM, SessionId, []),
    %% Observed WITHOUT touching the session — a POST would reset the
    %% very timer under test. The substrate checks at a 5s floor, so the
    %% session dies at the first check.
    {ok, _, TransportId} = bondy_mcp_handshake:parse_session_id(SessionId),
    ok = wait_until(
        fun() ->
            bondy_http_transport_session:whereis(TransportId) == undefined
        end,
        10000,
        idle_stop_with_stream_open
    ),
    ok = gun:close(Conn),
    {404, _, _} = post_session(
        Config, ?OPEN_REALM, SessionId, req(1, <<"tools/list">>, #{})
    ).

%% =============================================================================
%% CASES — §15 metrics (delta-based: the node is shared across the run)
%% =============================================================================

metrics_session_and_call_series(Config) ->
    Node = bondy_config:node(),
    SLabel = #{node => Node, realm => ?OPEN_REALM, listener => ?LISTENER},
    CLabel = SLabel#{reason => client_close},
    OkLabel = SLabel#{name => ?ECHO, status => success},
    ErrLabel = SLabel#{name => ?APPROVE, status => tool_error},
    HLabel = #{node => Node, realm => ?OPEN_REALM, status => success},
    RLabel = #{
        node => Node, realm => ?OPEN_REALM, method => <<"tools/call">>
    },
    Opened0 = mval(bondy_mcp_session_opened_total, SLabel),
    Closed0 = mval(bondy_mcp_session_closed_total, CLabel),
    Ok0 = mval(bondy_mcp_tool_calls_total, OkLabel),
    Err0 = mval(bondy_mcp_tool_calls_total, ErrLabel),
    H0 = hcount(bondy_mcp_tool_call_duration_microseconds, HLabel),
    R0 = hcount(bondy_mcp_request_duration_microseconds, RLabel),

    SessionId = initialize(Config, ?OPEN_REALM, []),
    {200, _, #{<<"result">> := #{<<"isError">> := false}}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(1, <<"tools/call">>, #{
            <<"name">> => ?ECHO, <<"arguments">> => #{<<"n">> => 1}
        })
    ),
    %% In this era the §11.1 input-required signal is an ordinary tool
    %% error — and must be COUNTED as one (a status classification
    %% collapsed to `success` fails here).
    {200, _, #{<<"result">> := #{<<"isError">> := true}}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(2, <<"tools/call">>, #{
            <<"name">> => ?APPROVE, <<"arguments">> => #{}
        })
    ),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []),

    ?assertEqual(Opened0 + 1, mval(bondy_mcp_session_opened_total, SLabel)),
    ?assertEqual(Closed0 + 1, mval(bondy_mcp_session_closed_total, CLabel)),
    ?assertEqual(Ok0 + 1, mval(bondy_mcp_tool_calls_total, OkLabel)),
    ?assertEqual(Err0 + 1, mval(bondy_mcp_tool_calls_total, ErrLabel)),
    ?assertEqual(
        H0 + 1, hcount(bondy_mcp_tool_call_duration_microseconds, HLabel)
    ),
    ?assertEqual(
        R0 + 2, hcount(bondy_mcp_request_duration_microseconds, RLabel)
    ),
    %% The in-flight gauge is back at rest — its decrement runs in an
    %% `after`, so an unpaired increment (drift) shows here.
    ?assertEqual(0, mval(bondy_mcp_inflight_calls, SLabel)).

metrics_version_refused_series(Config) ->
    Node = bondy_config:node(),
    OtherLabel = #{
        node => Node, listener => ?LISTENER, version => <<"other">>
    },
    KnownLabel = #{node => Node, listener => ?LISTENER, version => ?MODERN},
    RawLabel = #{
        node => Node, listener => ?LISTENER, version => <<"9999-01-01">>
    },
    O0 = mval(bondy_mcp_version_refused_total, OtherLabel),
    K0 = mval(bondy_mcp_version_refused_total, KnownLabel),
    Raw0 = mval(bondy_mcp_version_refused_total, RawLabel),

    SessionId = initialize(Config, ?OPEN_REALM, []),
    %% A client-invented version must aggregate under `other` — the raw
    %% value never mints a Prometheus series (§15.2).
    {400, _, _} = post_hs(
        Config,
        ?OPEN_REALM,
        [session(SessionId), {"mcp-protocol-version", "9999-01-01"}],
        req(1, <<"ping">>, #{})
    ),
    %% A version Bondy KNOWS but this era does not accept keeps its exact
    %% label (a sanitizer collapsing everything to `other` fails here).
    {400, _, _} = post_hs(
        Config,
        ?OPEN_REALM,
        [
            session(SessionId),
            {"mcp-protocol-version", binary_to_list(?MODERN)}
        ],
        req(2, <<"ping">>, #{})
    ),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []),

    ?assertEqual(O0 + 1, mval(bondy_mcp_version_refused_total, OtherLabel)),
    ?assertEqual(K0 + 1, mval(bondy_mcp_version_refused_total, KnownLabel)),
    ?assertEqual(Raw0, mval(bondy_mcp_version_refused_total, RawLabel)),
    ?assertEqual(0, Raw0).

metrics_rbac_denied_series(Config) ->
    Node = bondy_config:node(),
    ListLabel = #{
        node => Node, realm => ?RBAC_REALM, surface => list_filter
    },
    CallLabel = #{
        node => Node, realm => ?RBAC_REALM, surface => call_authz
    },
    L0 = mval(bondy_mcp_rbac_denied_total, ListLabel),
    C0 = mval(bondy_mcp_rbac_denied_total, CallLabel),

    Auth = basic_auth(?USER, ?PASSWORD),
    SessionId = initialize(Config, ?RBAC_REALM, [Auth]),
    %% The realm carries 2 tools and the principal sees 1: exactly one
    %% entry was filtered (a count taken from the whole list rather than
    %% the hidden difference reports 2 and fails).
    {200, _, #{<<"result">> := R}} = post_session(
        Config, ?RBAC_REALM, SessionId, req(1, <<"tools/list">>, #{}), [Auth]
    ),
    ?assertEqual(1, length(maps:get(<<"tools">>, R))),
    {200, _, #{<<"error">> := _}} = post_session(
        Config,
        ?RBAC_REALM,
        SessionId,
        req(2, <<"tools/call">>, #{
            <<"name">> => ?DENIED, <<"arguments">> => #{}
        }),
        [Auth]
    ),
    ok = delete_session(Config, ?RBAC_REALM, SessionId, [Auth]),

    ?assertEqual(L0 + 1, mval(bondy_mcp_rbac_denied_total, ListLabel)),
    ?assertEqual(C0 + 1, mval(bondy_mcp_rbac_denied_total, CallLabel)).

metrics_notifications_series(Config) ->
    Node = bondy_config:node(),
    NLabel = #{
        node => Node, realm => ?OPEN_REALM, type => tools_list_changed
    },
    SubLabel = #{node => Node, realm => ?OPEN_REALM, name => ?TICKS},
    N0 = mval(bondy_mcp_notifications_emitted_total, NLabel),
    S0 = mval(bondy_mcp_resource_subscribes_total, SubLabel),

    SessionId = initialize(Config, ?OPEN_REALM, []),
    {200, _, #{<<"result">> := _}} = post_session(
        Config,
        ?OPEN_REALM,
        SessionId,
        req(1, <<"resources/subscribe">>, #{<<"uri">> => ?TICKS_RESOURCE})
    ),
    ?assertEqual(S0 + 1, mval(bondy_mcp_resource_subscribes_total, SubLabel)),

    %% A manifest change reaches this session's queue as a pre-encoded
    %% list_changed notification, and the emission is counted per session
    %% notified.
    ok = bondy_mcp_gateway:load(#{
        <<"id">> => <<"mcp_hs_overlay3">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?OPEN_REALM,
                <<"name">> => <<"metrics_late_tool">>,
                <<"kind">> => <<"tool">>,
                <<"wamp_procedure">> => ?SLOW
            }
        ]
    }),
    ok = wait_until(
        fun() ->
            mval(bondy_mcp_notifications_emitted_total, NLabel) >= N0 + 1
        end,
        10000,
        list_changed_not_counted
    ),
    ok = bondy_mcp_gateway:delete(<<"mcp_hs_overlay3">>),
    ok = wait_until(
        fun() ->
            {ok, #{entries := E}} = bondy_mcp_gateway:manifest(?OPEN_REALM),
            not maps:is_key(<<"metrics_late_tool">>, E)
        end,
        10000,
        manifest_rebuild_back
    ),
    ok = delete_session(Config, ?OPEN_REALM, SessionId, []).

%% Every close reason is counted at ONE seat — the transport session's
%% terminate — and the active-sessions gauge returns to rest after each.
%% Coverage per sub-scenario (and what each does NOT cover):
%% - client_close: the DELETE path, end to end. Exactly +1 — a second
%%   emission left at the DELETE handler would fail here.
%% - idle_timeout: the check is TRIGGERED DIRECTLY (the message the
%%   timer would send), so this pins the classification, the distinct
%%   `{shutdown, idle_timeout}` stop reason, and the emission — NOT the
%%   timer's scheduling (`idle_timeout_ignores_the_open_stream` rides
%%   the real timer).
%% - crash: `sys:terminate/2` with a non-shutdown reason reaches
%%   `terminate/2` as-is (probed); classified `crash`.
%% - stored_session_closed: the WAMP session is closed underneath the
%%   transport; the next request's liveness check closes it.
transport_lifecycle_close_reasons_and_active_gauge(Config) ->
    Node = bondy_config:node(),
    SLabel = #{node => Node, realm => ?OPEN_REALM, listener => ?LISTENER},
    Closed = fun(Reason) ->
        mval(bondy_mcp_session_closed_total, SLabel#{reason => Reason})
    end,
    Active = fun() -> mval(bondy_mcp_active_sessions, SLabel) end,

    %% client_close via DELETE.
    Del0 = Closed(client_close),
    A0 = Active(),
    S1 = initialize(Config, ?OPEN_REALM, []),
    ?assertEqual(A0 + 1, Active()),
    ok = delete_session(Config, ?OPEN_REALM, S1, []),
    ?assertEqual(Del0 + 1, Closed(client_close)),
    ?assertEqual(A0, Active()),

    %% idle_timeout. The TTL is captured at transport init, so it is
    %% shrunk only around the initialize and restored at once.
    Idle0 = Closed(idle_timeout),
    OldTTL = bondy_config:get([http_transport, idle_timeout], 3600000),
    ok = bondy_config:set([http_transport, idle_timeout], 1),
    S2 = initialize(Config, ?OPEN_REALM, []),
    ok = bondy_config:set([http_transport, idle_timeout], OldTTL),
    Pid2 = transport_pid(S2),
    MRef2 = erlang:monitor(process, Pid2),
    ok = timer:sleep(5),
    Pid2 ! check_inactivity,
    receive
        {'DOWN', MRef2, process, Pid2, Reason2} ->
            ?assertEqual({shutdown, idle_timeout}, Reason2)
    after 5000 ->
        ct:fail(no_idle_stop)
    end,
    ?assertEqual(Idle0 + 1, Closed(idle_timeout)),
    ?assertEqual(A0, Active()),

    %% crash.
    Crash0 = Closed(crash),
    S3 = initialize(Config, ?OPEN_REALM, []),
    Pid3 = transport_pid(S3),
    MRef3 = erlang:monitor(process, Pid3),
    ok = sys:terminate(Pid3, boom),
    receive
        {'DOWN', MRef3, process, Pid3, boom} -> ok
    after 5000 ->
        ct:fail(no_crash_stop)
    end,
    ?assertEqual(Crash0 + 1, Closed(crash)),
    ?assertEqual(A0, Active()),

    %% stored_session_closed: close the stored WAMP session underneath
    %% (the manager close is a cast — poll it gone), then the next
    %% request's liveness check closes the transport and answers 404.
    Gone0 = Closed(stored_session_closed),
    S4 = initialize(Config, ?OPEN_REALM, []),
    Pid4 = transport_pid(S4),
    {ok, HS} = bondy_http_transport_session:with_state(
        Pid4, fun(H) -> {H, H} end
    ),
    Stored = maps:get(session, HS),
    ok = bondy_session_manager:close(Stored),
    ok = wait_until(
        fun() ->
            bondy_session:lookup(bondy_session:id(Stored)) ==
                {error, not_found}
        end,
        10000,
        stored_session_not_closed
    ),
    {404, _, _} = post_session(
        Config, ?OPEN_REALM, S4, req(1, <<"tools/list">>, #{})
    ),
    ?assertEqual(Gone0 + 1, Closed(stored_session_closed)),
    ?assertEqual(A0, Active()).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% The transport session pid behind a wire session id.
transport_pid(WireId) ->
    {ok, _, TransportId} = bondy_mcp_handshake:parse_session_id(WireId),
    Pid = bondy_http_transport_session:whereis(TransportId),
    true = is_pid(Pid),
    Pid.

%% Current value of a counter/gauge cell, 0 when never touched.
mval(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        undefined -> 0;
        V when is_integer(V) -> V
    end.

%% Observation count of a histogram cell, 0 when never touched.
hcount(Name, Label) ->
    case bondy_metrics:histogram_snapshot(#{name => Name, label => Label}) of
        {ok, #{count := C}} -> C;
        not_found -> 0
    end.

spawn_callee_owner() ->
    Caller = self(),
    Owner = spawn(fun() ->
        {ok, Conn} = bondy_connect_client:connect(#{
            transport => local,
            endpoint => local,
            realm => ?OPEN_REALM,
            auth => #{method => ?WAMP_ANON_AUTH},
            serializers => [json]
        }),
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
        {ok, _} = bondy_connect_client:register(
            Conn, ?XHDR, fun(_, KwArgs, _) -> {ok, #{kwargs => KwArgs}} end
        ),
        {ok, _} = bondy_connect_client:register(
            Conn, ?SLOW, fun(_, _, _) ->
                timer:sleep(8000),
                {ok, #{kwargs => #{<<"late">> => true}}}
            end
        ),
        {ok, _} = bondy_connect_client:register(
            Conn, ?APPROVE, fun(_, _, _) ->
                {error, #{
                    uri => ?INPUT_REQUIRED_URI,
                    kwargs => #{
                        <<"state">> => #{<<"nonce">> => <<"pear-7">>}
                    }
                }}
            end
        ),
        Caller ! {callee_ready, self()},
        callee_owner_loop(Conn)
    end),
    receive
        {callee_ready, Owner} -> Owner
    after 10000 ->
        error(callee_owner_timeout)
    end.

callee_owner_loop(Conn) ->
    receive
        {publish, From, Topic, Args, KwArgs} ->
            From !
                {published,
                    bondy_connect_client:publish(Conn, Topic, Args, KwArgs)},
            callee_owner_loop(Conn);
        stop ->
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

url(Config, Realm) when is_list(Config) ->
    url(?config(port, Config), Realm);
url(Port, Realm) when is_integer(Port) ->
    lists:flatten(
        io_lib:format("http://127.0.0.1:~b/mcp/realm/~s", [Port, Realm])
    ).

post_init(Config, Realm, Version, Headers) ->
    do_post_init(?config(port, Config), Realm, Version, Headers).

do_post_init(Port, Realm, Version, Headers) ->
    do_post_hs(Port, Realm, Headers, init_body(Version)).

%% Initialize and return the minted session id.
initialize(Config, Realm, Headers) ->
    {200, RespHeaders, #{<<"result">> := _}} = post_init(
        Config, Realm, ?LATEST, Headers
    ),
    session_header(RespHeaders).

session_header(Headers) ->
    {_, V} = lists:keyfind("mcp-session-id", 1, Headers),
    list_to_binary(V).

session(SessionId) ->
    {"mcp-session-id", binary_to_list(SessionId)}.

post_session(Config, Realm, SessionId, Body) ->
    post_session(Config, Realm, SessionId, Body, []).

post_session(Config, Realm, SessionId, Body, Headers) ->
    post_hs(
        Config,
        Realm,
        [
            session(SessionId),
            {"mcp-protocol-version", binary_to_list(?LATEST)}
            | Headers
        ],
        Body
    ).

post_hs(Config, Realm, Headers, Body) ->
    do_post_hs(?config(port, Config), Realm, Headers, Body).

do_post_hs(Port, Realm, Headers, Body) ->
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

delete_session(Config, Realm, SessionId, Headers) ->
    {ok, {{_, 204, _}, _, _}} = httpc:request(
        delete,
        {url(Config, Realm), [session(SessionId) | Headers]},
        [],
        []
    ),
    ok.

basic_auth(User, Password) ->
    {"authorization",
        "Basic " ++
            base64:encode_to_string(<<User/binary, ":", Password/binary>>)}.

%% Opens the held GET stream, asserting 200 + text/event-stream.
open_stream(Config, Realm, SessionId, AuthHeaders) ->
    case open_stream_status(Config, Realm, SessionId, AuthHeaders) of
        {200, Conn, Ref} -> {Conn, Ref, <<>>};
        Other -> error({open_stream_failed, Other})
    end.

%% Opens the GET and returns its status: `{200, Conn, Ref}` for a stream,
%% `{Status, Conn}` otherwise (the caller closes the connection).
open_stream_status(Config, Realm, SessionId, AuthHeaders) ->
    Port = ?config(port, Config),
    {ok, Conn} = gun:open("127.0.0.1", Port, #{
        transport => tcp, protocols => [http]
    }),
    {ok, _} = gun:await_up(Conn, 5000),
    Headers =
        [
            {<<"accept">>, <<"text/event-stream">>},
            {<<"mcp-session-id">>, SessionId},
            {<<"mcp-protocol-version">>, ?LATEST}
        ] ++
            [
                {list_to_binary(K), list_to_binary(V)}
             || {K, V} <- AuthHeaders
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

attach_audit_telemetry() ->
    Ref = make_ref(),
    Self = self(),
    ok = telemetry:attach(
        {?MODULE, Ref},
        [bondy, mcp, audit, record],
        fun(_, _, #{record := Record}, _) ->
            Self ! {audit_record, Ref, Record}
        end,
        undefined
    ),
    Ref.

detach_audit_telemetry(Ref) ->
    telemetry:detach({?MODULE, Ref}).

collect_audit(_, 0) ->
    [];
collect_audit(Ref, N) ->
    receive
        {audit_record, Ref, Record} -> [Record | collect_audit(Ref, N - 1)]
    after 10000 ->
        error({audit_records_missing, N})
    end.

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
            timer:sleep(100),
            wait_until_loop(Fun, Deadline, Label)
    end.
