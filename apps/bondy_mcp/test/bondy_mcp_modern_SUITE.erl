%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_mcp_modern_SUITE).

-moduledoc """
The modern (2026-07-28) per-request MCP edge (design §5.2, §21 increment 4)
over a real socket on a booted node: `tools/list` is the RBAC-projected,
paginated manifest; `tools/call` and `resources/read` speak WAMP inward
through an UNSTORED per-request session; §10.1's transport validation
(protocol-version negotiation, header/body agreement incl. the Base64
sentinel and `x-mcp-header` params) answers with the specification's
status/code pairs; and the era's defining property — N requests leave zero
processes and zero stored sessions behind, an unauthenticated request
starts nothing — is pinned directly.

The suite starts its OWN cowboy listener from the carrier's real route
contribution (`bondy_mcp_http_service:routes/3`), deliberately bypassing
`bondy_listener_manager`: mounting is the mount suite's subject and the
manager's inventory is node-global state a suite must not disturb on the
shared CT node.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_router/include/bondy_security.hrl").

-define(AUDIT_TAB, mcp_modern_audit_capture).
-define(OPEN_REALM, <<"com.bondy.mcp.mod.open">>).
-define(RBAC_REALM, <<"com.bondy.mcp.mod.rbac">>).
-define(ECHO, <<"com.example.mcp.mod.echo">>).
-define(GET_USER, <<"com.example.mcp.mod.get_user">>).
-define(XHDR, <<"com.example.mcp.mod.xhdr">>).
-define(GHOST, <<"com.example.mcp.mod.ghost">>).
-define(ALLOWED, <<"com.example.mcp.mod.rbac.allowed">>).
-define(DENIED, <<"com.example.mcp.mod.rbac.denied">>).
-define(SECRET, <<"com.example.mcp.mod.secret">>).
-define(TRACED, <<"com.example.mcp.mod.traced">>).
-define(APPROVE, <<"com.example.mcp.mod.approve">>).
-define(PENDING, <<"com.example.mcp.mod.pending">>).
-define(INPUT_REQUIRED_URI, <<"bondy.error.mcp.input_required">>).
-define(TICKS, <<"com.example.mcp.mod.ticks">>).
-define(TICKS_RESOURCE, <<"wamp:", ?OPEN_REALM/binary, ":", ?TICKS/binary>>).
-define(SUB_OK_TOPIC, <<"com.example.mcp.mod.rbac.sub.ok">>).
-define(SUB_NO_TOPIC, <<"com.example.mcp.mod.rbac.sub.no">>).
-define(USER, <<"mcp_user_1">>).
-define(USER2, <<"mcp_user_2">>).
-define(PASSWORD, <<"aWamp2Password">>).
-define(VERSION, <<"2026-07-28">>).
-define(LISTENER, ct_mcp_modern).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        tools_list_answers_the_projected_manifest,
        tools_list_paginates,
        tools_call_round_trip,
        tools_call_unregistered_is_retryable,
        resources_read_binds_the_template,
        tools_call_maps_meta_trace_context,
        resources_read_maps_meta_trace_context,
        unknown_method_is_404_with_method_not_found,
        version_negotiation,
        header_body_agreement,
        param_headers_are_cross_checked,
        basic_auth_and_the_rbac_projection,
        unauthenticated_request_starts_nothing,
        requests_leave_zero_footprint,
        notification_is_accepted,
        rbac_context_build_is_measured,
        audit_tool_call_records,
        audit_denied_call_is_recorded_invisibly,
        audit_redaction_applies_at_capture,
        tools_call_input_required_round_trip,
        state_only_continuation_round_trip,
        request_state_bindings_are_enforced,
        request_state_replay_by_another_principal_is_rejected,
        listen_ack_first_and_filter_enforced,
        listen_resource_updates_round_trip,
        listen_rbac_denied_subscription_is_omitted_and_audited,
        closing_stream_unsubscribes_everything,
        server_teardown_sends_completion,
        stream_survives_quiet_hold_at_connection_floor,
        requests_are_rate_limited,
        server_discover_answers_the_probe,
        origin_policy_is_enforced
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(gun),

    %% Audit records reach their seam as `[bondy, mcp, audit, record]`
    %% telemetry (MCP-D27: no local sink). Capture them for the audit
    %% cases. The handler runs synchronously in the emitting process, so
    %% a record is in the table before any response or SSE frame that
    %% follows its emission — the cases may query right after a reply.
    %% CT runs this callback in its own short-lived process, so the
    %% table needs a suite-lived owner.
    Starter = self(),
    TabOwner = spawn(fun() ->
        ?AUDIT_TAB = ets:new(
            ?AUDIT_TAB, [ordered_set, public, named_table]
        ),
        Starter ! {audit_tab_ready, self()},
        receive
            stop -> ok
        end
    end),
    receive
        {audit_tab_ready, TabOwner} -> ok
    after 5000 -> error(audit_tab_not_ready)
    end,
    ok = telemetry:attach(
        {?MODULE, audit_capture},
        [bondy, mcp, audit, record],
        fun(_, _, #{record := R}, _) ->
            true = ets:insert(
                ?AUDIT_TAB, {erlang:unique_integer([monotonic]), R}
            ),
            ok
        end,
        undefined
    ),

    Open = bondy_realm:create(?OPEN_REALM),
    ok = bondy_realm:disable_security(Open),
    _ = bondy_realm:create(#{
        uri => ?RBAC_REALM,
        description => <<"MCP modern-edge RBAC">>,
        authmethods => [?PASSWORD_AUTH],
        security_enabled => true,
        groups => [#{name => <<"mcp_users">>}],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => ?ALLOWED,
                match => <<"exact">>,
                roles => [<<"mcp_users">>]
            },
            #{
                permissions => [<<"wamp.subscribe">>],
                uri => ?SUB_OK_TOPIC,
                match => <<"exact">>,
                roles => [<<"mcp_users">>]
            }
        ],
        %% Two users in the SAME group: the requestState replay falsifier
        %% needs a second principal every other check passes for.
        users => [
            #{
                username => U,
                password => ?PASSWORD,
                groups => [<<"mcp_users">>],
                meta => #{}
            }
         || U <- [?USER, ?USER2]
        ],
        %% A user authenticates only through a matching source assignment.
        sources => [
            #{
                usernames => [?USER, ?USER2],
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    }),

    ok = bondy_interface:load(#{
        <<"id">> => <<"mcp_modern_iface">>,
        <<"entries">> =>
            [
                #{
                    <<"realm">> => ?OPEN_REALM,
                    <<"kind">> => <<"procedure">>,
                    <<"uri">> => Uri,
                    <<"description">> => <<"modern-edge test procedure">>,
                    <<"kwargs_schema">> => #{
                        <<"type">> => <<"object">>,
                        <<"properties">> => #{
                            <<"n">> => #{<<"type">> => <<"integer">>}
                        }
                    }
                }
             || Uri <- [?ECHO, ?GHOST]
            ] ++
            [
                %% The SEP-414 probe: its callee answers with whatever
                %% trace context its INVOCATION details carried.
                #{
                    <<"realm">> => ?OPEN_REALM,
                    <<"kind">> => <<"procedure">>,
                    <<"uri">> => ?TRACED
                }
            ] ++
            [
                #{
                    <<"realm">> => ?OPEN_REALM,
                    <<"kind">> => <<"procedure">>,
                    <<"uri">> => ?XHDR,
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
            ] ++
            [
                %% The §11.1 callees: one elicits (requests + state), one
                %% load-sheds (state only).
                #{
                    <<"realm">> => ?OPEN_REALM,
                    <<"kind">> => <<"procedure">>,
                    <<"uri">> => Uri
                }
             || Uri <- [?APPROVE, ?PENDING]
            ] ++
            [
                %% A topic in the open realm: the base resource
                %% `wamp:<realm>:<topic>` the stream cases subscribe to.
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
            ] ++
            [
                %% Two topics in the RBAC realm; only one carries a
                %% `wamp.subscribe` grant below.
                #{
                    <<"realm">> => ?RBAC_REALM,
                    <<"kind">> => <<"topic">>,
                    <<"uri">> => Uri
                }
             || Uri <- [?SUB_OK_TOPIC, ?SUB_NO_TOPIC]
            ]
    }),
    ok = bondy_mcp_gateway:load(#{
        <<"id">> => <<"mcp_modern_overlay">>,
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
                    <<"com.example.mcp.mod.user.{{id}}.changed">>,
                <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
            },
            %% An overlay-only tool with a §14.3 redaction policy: what
            %% the redaction CT case captures through.
            #{
                <<"realm">> => ?OPEN_REALM,
                <<"name">> => <<"secret_tool">>,
                <<"kind">> => <<"tool">>,
                <<"wamp_procedure">> => ?SECRET,
                <<"redaction">> => #{<<"fields">> => [<<"ssn">>]}
            },
            %% The SEP-414 probe as a resource too, so the resources/read
            %% path's trace threading is pinned independently.
            #{
                <<"realm">> => ?OPEN_REALM,
                <<"name">> => <<"trace_probe">>,
                <<"kind">> => <<"resource_template">>,
                <<"wamp_procedure">> => ?TRACED,
                <<"uri_template">> => <<"trace:///probe">>,
                <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
            }
        ]
    }),

    %% The live callees, on an in-VM SDK connection. The connection links
    %% to its opener, and CT's init_per_suite process dies once init
    %% returns — so a dedicated owner process holds it for the suite.
    Owner = spawn_callee_owner(),

    %% The suite's own listener, mounting the carrier's REAL routes.
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
    [
        {port, Port},
        {callee_owner, Owner},
        {audit_tab_owner, TabOwner}
        | Config
    ].

end_per_suite(Config) ->
    ok = telemetry:detach({?MODULE, audit_capture}),
    ?config(audit_tab_owner, Config) ! stop,
    ?config(callee_owner, Config) ! stop,
    ok = cowboy:stop_listener(?LISTENER),
    ok = bondy_interface:delete(<<"mcp_modern_iface">>),
    ok = bondy_mcp_gateway:delete(<<"mcp_modern_overlay">>),
    {save_config, Config}.

%% The §3.4 shape, hand-built: resolution totality is
%% `bondy_listener_config`'s property, pinned by its own tests; this
%% suite's subject is the handler. `default_page_size => 2` keeps the
%% pagination case honest; `2025-11-25` makes the endpoint dual-era —
%% the version case pins that a handshake-version request without a
%% session id is refused with the transport spec's 400.
carrier_config() ->
    #{
        protocol_versions => [?VERSION, <<"2025-11-25">>],
        allowed_origins => [local],
        public_base_uri => undefined,
        max_body_size => 1048576,
        max_inflight => 64,
        idle_timeout => 600000,
        list => #{default_page_size => 2},
        schema => #{max_depth => 32, max_validation_ms => 50}
    }.

%% =============================================================================
%% CASES
%% =============================================================================

tools_list_answers_the_projected_manifest(Config) ->
    {Status, Resp} = post(Config, ?OPEN_REALM, req(1, <<"tools/list">>, #{})),
    ?assertEqual(200, Status),
    #{<<"result">> := Result} = Resp,
    ?assertMatch(
        #{
            <<"resultType">> := <<"complete">>,
            <<"cacheScope">> := <<"private">>,
            <<"ttlMs">> := _
        },
        Result
    ),
    Tools = all_tools(Config, ?OPEN_REALM, #{}),
    Names = [maps:get(<<"name">>, T) || T <- Tools],
    ?assert(lists:member(?ECHO, Names)),
    ?assert(lists:member(?GHOST, Names)),
    %% The resource template is NOT a tool.
    ?assertNot(lists:member(<<"user">>, Names)),
    Echo = hd([T || T <- Tools, maps:get(<<"name">>, T) == ?ECHO]),
    ?assertMatch(
        #{
            <<"description">> := _,
            <<"inputSchema">> := #{<<"properties">> := #{<<"n">> := _}},
            <<"_meta">> := #{<<"bondy:hash">> := <<"sha256:", _/binary>>}
        },
        Echo
    ).

tools_list_paginates(Config) ->
    %% Page size 2 over >2 tools: every page but the last carries a
    %% cursor, the union is the whole list, and nothing repeats.
    {200, #{<<"result">> := First}} = post(
        Config, ?OPEN_REALM, req(1, <<"tools/list">>, #{})
    ),
    ?assertEqual(2, length(maps:get(<<"tools">>, First))),
    ?assert(maps:is_key(<<"nextCursor">>, First)),
    Tools = all_tools(Config, ?OPEN_REALM, #{}),
    Names = [maps:get(<<"name">>, T) || T <- Tools],
    ?assertEqual(lists:sort(Names), lists:usort(Names)),
    ?assert(length(Names) >= 3),
    %% An unintelligible cursor is a client error.
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32602}}},
        post(
            Config,
            ?OPEN_REALM,
            req(2, <<"tools/list">>, #{<<"cursor">> => <<"garbage">>})
        )
    ).

tools_call_round_trip(Config) ->
    {Status, Resp} = post(
        Config,
        ?OPEN_REALM,
        req(3, <<"tools/call">>, #{
            <<"name">> => ?ECHO,
            <<"arguments">> => #{<<"n">> => 7, <<"@args">> => [<<"a">>]}
        })
    ),
    ?assertEqual(200, Status),
    #{<<"result">> := Result} = Resp,
    %% §16.1 both directions: @args became WAMP positional arguments, the
    %% echoed payload flattens back under @args.
    ?assertMatch(
        #{
            <<"resultType">> := <<"complete">>,
            <<"isError">> := false,
            <<"structuredContent">> := #{
                <<"@args">> := [<<"a">>],
                <<"n">> := 7
            },
            <<"content">> := [#{<<"type">> := <<"text">>}]
        },
        Result
    ).

tools_call_unregistered_is_retryable(Config) ->
    %% §7.7 + §10.2: declared in the manifest, no callee registered — a
    %% SUCCESSFUL response carrying isError and a STRUCTURED retryable
    %% marker, so an agent waits or retries instead of abandoning the tool.
    {200, #{<<"result">> := Result}} = post(
        Config,
        ?OPEN_REALM,
        req(4, <<"tools/call">>, #{
            <<"name">> => ?GHOST, <<"arguments">> => #{}
        })
    ),
    ?assertMatch(
        #{
            <<"isError">> := true,
            <<"structuredContent">> := #{<<"retryable">> := true},
            <<"_meta">> := #{<<"bondy:error_uri">> := _}
        },
        Result
    ).

%% SEP-414 end to end, inbound: a request's `_meta.traceparent` /
%% `tracestate` / `baggage` reach the callee's INVOCATION details as the
%% router's trace extension options, verbatim — through the handler's
%% mapping, `bondy:call`, the dealer's carry and the SDK's decode. The
%% completion event carries the same context as its `trace` metadata —
%% the §15.4 span contract, asserted at the telemetry seam.
tools_call_maps_meta_trace_context(Config) ->
    TP = <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>,
    TS = <<"congo=t61rcWkgMzE">>,
    BG = <<"userId=alice">>,
    Self = self(),
    ok = telemetry:attach(
        {?MODULE, tc_trace},
        [bondy, mcp, tool, call, stop],
        fun(_, _, Meta, _) -> Self ! {tool_call_stop, Meta} end,
        undefined
    ),
    try
        {200, #{<<"result">> := R1}} = post(
            Config,
            ?OPEN_REALM,
            req(60, <<"tools/call">>, #{
                <<"name">> => ?TRACED,
                <<"arguments">> => #{},
                <<"_meta">> => #{
                    <<"traceparent">> => TP,
                    <<"tracestate">> => TS,
                    <<"baggage">> => BG
                }
            })
        ),
        ?assertMatch(#{<<"isError">> := false}, R1),
        ?assertEqual(
            #{
                <<"traced">> => true,
                <<"traceparent">> => TP,
                <<"tracestate">> => TS,
                <<"baggage">> => BG
            },
            maps:get(<<"structuredContent">>, R1)
        ),
        ?assertEqual(
            #{
                <<"traceparent">> => TP,
                <<"tracestate">> => TS,
                <<"baggage">> => BG
            },
            maps:get(trace, next_event(tool_call_stop))
        ),
        %% An untraced request maps nothing — no defaults, no leakage
        %% from the previous call — and its event says so.
        {200, #{<<"result">> := R2}} = post(
            Config,
            ?OPEN_REALM,
            req(61, <<"tools/call">>, #{
                <<"name">> => ?TRACED, <<"arguments">> => #{}
            })
        ),
        ?assertEqual(
            #{<<"traced">> => false}, maps:get(<<"structuredContent">>, R2)
        ),
        ?assertEqual(#{}, maps:get(trace, next_event(tool_call_stop))),
        %% The W3C gate holds at the edge: tracestate without a
        %% traceparent maps to nothing.
        {200, #{<<"result">> := R3}} = post(
            Config,
            ?OPEN_REALM,
            req(62, <<"tools/call">>, #{
                <<"name">> => ?TRACED,
                <<"arguments">> => #{},
                <<"_meta">> => #{<<"tracestate">> => TS}
            })
        ),
        ?assertEqual(
            #{<<"traced">> => false}, maps:get(<<"structuredContent">>, R3)
        ),
        ?assertEqual(#{}, maps:get(trace, next_event(tool_call_stop)))
    after
        telemetry:detach({?MODULE, tc_trace})
    end.

%% The `resources/read` path threads the same mapping, and its
%% completion event carries the same `trace` metadata.
resources_read_maps_meta_trace_context(Config) ->
    TP = <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>,
    Self = self(),
    ok = telemetry:attach(
        {?MODULE, rr_trace},
        [bondy, mcp, resource, read, stop],
        fun(_, _, Meta, _) -> Self ! {resource_read_stop, Meta} end,
        undefined
    ),
    try
        {200, #{<<"result">> := Result}} = post(
            Config,
            ?OPEN_REALM,
            req(63, <<"resources/read">>, #{
                <<"uri">> => <<"trace:///probe">>,
                <<"_meta">> => #{<<"traceparent">> => TP}
            })
        ),
        #{<<"contents">> := [Content]} = Result,
        ?assertEqual(
            #{<<"traced">> => true, <<"traceparent">> => TP},
            json:decode(maps:get(<<"text">>, Content))
        ),
        ?assertEqual(
            #{<<"traceparent">> => TP},
            maps:get(trace, next_event(resource_read_stop))
        )
    after
        telemetry:detach({?MODULE, rr_trace})
    end.

resources_read_binds_the_template(Config) ->
    {200, #{<<"result">> := Result}} = post(
        Config,
        ?OPEN_REALM,
        req(5, <<"resources/read">>, #{<<"uri">> => <<"users:///42">>})
    ),
    #{<<"contents">> := [Content]} = Result,
    ?assertMatch(
        #{
            <<"uri">> := <<"users:///42">>,
            <<"mimeType">> := <<"application/json">>
        },
        Content
    ),
    %% The variable arrived TYPED (uri_vars_schema says integer).
    ?assertMatch(
        #{<<"id">> := 42, <<"name">> := <<"ada">>},
        json:decode(maps:get(<<"text">>, Content))
    ),
    %% A value the schema cannot carry is a client error...
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32602}}},
        post(
            Config,
            ?OPEN_REALM,
            req(6, <<"resources/read">>, #{<<"uri">> => <<"users:///nope">>})
        )
    ),
    %% ...and an unknown resource is one too.
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32602}}},
        post(
            Config,
            ?OPEN_REALM,
            req(7, <<"resources/read">>, #{<<"uri">> => <<"orders:///1">>})
        )
    ).

unknown_method_is_404_with_method_not_found(Config) ->
    %% §10.1: status and code together — the body distinguishes this 404
    %% from one served by something that is not an MCP endpoint at all.
    ?assertMatch(
        {404, #{<<"error">> := #{<<"code">> := -32601}}},
        post(Config, ?OPEN_REALM, req(8, <<"prompts/list">>, #{}))
    ).

version_negotiation(Config) ->
    %% Missing header.
    Body = req(9, <<"tools/list">>, #{}),
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32020}}},
        raw_post(Config, ?OPEN_REALM, [{"mcp-method", "tools/list"}], Body)
    ),
    %% Header disagreeing with the body's _meta.
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32020}}},
        raw_post(
            Config,
            ?OPEN_REALM,
            [
                {"mcp-protocol-version", binary_to_list(?VERSION)},
                {"mcp-method", "tools/list"}
            ],
            req_v(10, <<"tools/list">>, #{}, <<"2025-11-25">>)
        )
    ),
    %% A version NO era of this endpoint carries. The error names the
    %% modern supported set.
    OldBody = req_v(10, <<"tools/list">>, #{}, <<"2024-11-05">>),
    {400, #{<<"error">> := Err}} = raw_post(
        Config,
        ?OPEN_REALM,
        [
            {"mcp-protocol-version", "2024-11-05"},
            {"mcp-method", "tools/list"}
        ],
        OldBody
    ),
    ?assertMatch(
        #{
            <<"code">> := -32022,
            <<"data">> := #{
                <<"supported">> := [?VERSION],
                <<"requested">> := <<"2024-11-05">>
            }
        },
        Err
    ),
    %% A handshake-era version header on a session-less request: since
    %% §21 increment 8 the endpoint carries `2025-11-25`, and the
    %% transport specification's session rule answers before anything
    %% else — a session id is required for everything but `initialize`.
    {400, #{<<"error">> := Err2}} = raw_post(
        Config,
        ?OPEN_REALM,
        [
            {"mcp-protocol-version", "2025-11-25"},
            {"mcp-method", "tools/list"}
        ],
        req_v(10, <<"tools/list">>, #{}, <<"2025-11-25">>)
    ),
    ?assertMatch(#{<<"code">> := -32600}, Err2).

header_body_agreement(Config) ->
    Body = req(11, <<"tools/call">>, #{
        <<"name">> => ?ECHO, <<"arguments">> => #{}
    }),
    %% Mcp-Method disagreeing with the body's method.
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32020}}},
        raw_post(
            Config,
            ?OPEN_REALM,
            [
                {"mcp-protocol-version", binary_to_list(?VERSION)},
                {"mcp-method", "tools/list"},
                {"mcp-name", binary_to_list(?ECHO)}
            ],
            Body
        )
    ),
    %% Mcp-Name missing on a method that requires it.
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32020}}},
        raw_post(
            Config,
            ?OPEN_REALM,
            [
                {"mcp-protocol-version", binary_to_list(?VERSION)},
                {"mcp-method", "tools/call"}
            ],
            Body
        )
    ),
    %% A Base64-sentinel Mcp-Name decodes before comparison.
    Sentinel = binary_to_list(
        <<"=?base64?", (base64:encode(?ECHO))/binary, "?=">>
    ),
    ?assertMatch(
        {200, _},
        raw_post(
            Config,
            ?OPEN_REALM,
            [
                {"mcp-protocol-version", binary_to_list(?VERSION)},
                {"mcp-method", "tools/call"},
                {"mcp-name", Sentinel}
            ],
            Body
        )
    ).

param_headers_are_cross_checked(Config) ->
    %% The xhdr tool's `region` property is annotated `x-mcp-header:
    %% Region`, so a request providing the value MUST mirror it.
    Params = #{
        <<"name">> => ?XHDR,
        <<"arguments">> => #{<<"region">> => <<"us-west1">>}
    },
    Headers = fun(Extra) ->
        [
            {"mcp-protocol-version", binary_to_list(?VERSION)},
            {"mcp-method", "tools/call"},
            {"mcp-name", binary_to_list(?XHDR)}
            | Extra
        ]
    end,
    Body12 = req(12, <<"tools/call">>, Params),
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32020}}},
        raw_post(Config, ?OPEN_REALM, Headers([]), Body12)
    ),
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32020}}},
        raw_post(
            Config,
            ?OPEN_REALM,
            Headers([{"mcp-param-region", "eu-west1"}]),
            Body12
        )
    ),
    {200, #{<<"result">> := Result}} = raw_post(
        Config,
        ?OPEN_REALM,
        Headers([{"mcp-param-region", "us-west1"}]),
        Body12
    ),
    ?assertMatch(
        #{<<"structuredContent">> := #{<<"region">> := <<"us-west1">>}},
        Result
    ).

basic_auth_and_the_rbac_projection(Config) ->
    Auth = basic_auth(?USER, ?PASSWORD),
    %% The projected list holds EXACTLY what the principal may call.
    Tools = all_tools(Config, ?RBAC_REALM, #{auth => Auth}),
    ?assertEqual([?ALLOWED], [maps:get(<<"name">>, T) || T <- Tools]),
    %% A hidden entry called directly answers EXACTLY like an absent one
    %% (§6: the distinction is an information leak).
    {S1, R1} = post(
        Config,
        ?RBAC_REALM,
        req(13, <<"tools/call">>, #{
            <<"name">> => ?DENIED, <<"arguments">> => #{}
        }),
        #{auth => Auth}
    ),
    {S2, R2} = post(
        Config,
        ?RBAC_REALM,
        req(13, <<"tools/call">>, #{
            <<"name">> => <<"com.example.mcp.mod.rbac.absent">>,
            <<"arguments">> => #{}
        }),
        #{auth => Auth}
    ),
    ?assertEqual(404, S1),
    ?assertEqual(S1, S2),
    ?assertEqual(
        maps:get(<<"code">>, maps:get(<<"error">>, R1)),
        maps:get(<<"code">>, maps:get(<<"error">>, R2))
    ),
    %% A wrong password is refused.
    ?assertMatch(
        {401, _},
        post(
            Config,
            ?RBAC_REALM,
            req(14, <<"tools/list">>, #{}),
            #{auth => basic_auth(?USER, <<"wrong">>)}
        )
    ).

unauthenticated_request_starts_nothing(Config) ->
    Sessions0 = stored_session_count(),
    Baseline = mcp_owned_pids(),
    {Status, _} = post(Config, ?RBAC_REALM, req(15, <<"tools/list">>, #{})),
    ?assertEqual(401, Status),
    ?assertEqual(Sessions0, stored_session_count()),
    ?assertEqual(Baseline, mcp_owned_pids()).

requests_leave_zero_footprint(Config) ->
    %% Prime every path once so on-demand infrastructure (the manifest
    %% manager) exists before the baseline is taken.
    {200, _} = post(Config, ?OPEN_REALM, req(0, <<"tools/list">>, #{})),
    {200, _} = post(
        Config,
        ?OPEN_REALM,
        req(0, <<"tools/call">>, #{
            <<"name">> => ?ECHO, <<"arguments">> => #{<<"n">> => 0}
        })
    ),
    {200, _} = post(
        Config,
        ?OPEN_REALM,
        req(0, <<"resources/read">>, #{<<"uri">> => <<"users:///7">>})
    ),
    Sessions0 = stored_session_count(),
    Pids0 = mcp_owned_pids(),
    Transport0 = transport_session_count(),
    _ = [
        begin
            {200, _} = post(
                Config, ?OPEN_REALM, req(N, <<"tools/list">>, #{})
            ),
            {200, _} = post(
                Config,
                ?OPEN_REALM,
                req(N, <<"tools/call">>, #{
                    <<"name">> => ?ECHO,
                    <<"arguments">> => #{<<"n">> => N}
                })
            ),
            {200, _} = post(
                Config,
                ?OPEN_REALM,
                req(N, <<"resources/read">>, #{
                    <<"uri">> => <<"users:///7">>
                })
            )
        end
     || N <- lists:seq(1, 20)
    ],
    ?assertEqual(Sessions0, stored_session_count()),
    ?assertEqual(Pids0, mcp_owned_pids()),
    ?assertEqual(Transport0, transport_session_count()).

rbac_context_build_is_measured(Config) ->
    %% §2.5.4 / §21.4: the per-request RBAC context build is the modern
    %% path's floor; it must be MEASURED and published, not estimated.
    Self = self(),
    Id = {?MODULE, rbac_measure},
    ok = telemetry:attach(
        Id,
        [bondy_mcp, modern, rbac_context_build],
        fun(_, Measurements, Meta, _) ->
            Self ! {rbac_measured, Measurements, Meta}
        end,
        undefined
    ),
    try
        {200, _} = post(
            Config,
            ?RBAC_REALM,
            req(30, <<"tools/list">>, #{}),
            #{auth => basic_auth(?USER, ?PASSWORD)}
        ),
        receive
            {rbac_measured, #{duration := D}, #{realm := ?RBAC_REALM}} ->
                Us = erlang:convert_time_unit(D, native, microsecond),
                ct:pal("modern per-request RBAC context build: ~p us", [Us]),
                ?assert(Us >= 0)
        after 5000 ->
            error(rbac_context_build_not_measured)
        end
    after
        telemetry:detach(Id)
    end.

notification_is_accepted(Config) ->
    Body = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/whatever">>,
        <<"params">> => #{}
    },
    {Status, _} = raw_post(Config, ?OPEN_REALM, [], Body),
    ?assertEqual(202, Status).

audit_tool_call_records(Config) ->
    %% §14.1: one record per tool call, tied to the exact entry version
    %% by the §7.5 hash, emitted at the telemetry seam a sink attaches
    %% to (MCP-D27).
    Args = #{<<"n">> => 991},
    {200, _} = post(
        Config,
        ?OPEN_REALM,
        req(40, <<"tools/call">>, #{
            <<"name">> => ?ECHO, <<"arguments">> => Args
        })
    ),
    Expected = bondy_mcp_audit:digest(Args, none),
    [R] = [
        X
     || X <- audit_records(), maps:get(args_digest, X) == Expected
    ],
    {ok, #{entries := Entries}} = bondy_mcp_gateway:manifest(?OPEN_REALM),
    ?assertMatch(
        #{
            v := 1,
            type := tool_call,
            status := success,
            realm := ?OPEN_REALM,
            listener := ?LISTENER,
            transport := tcp,
            is_anonymous := true,
            name := ?ECHO,
            procedure := ?ECHO,
            redaction := none,
            decision := #{verdict := allow, source := none},
            %% §14.2: present from the first release, unpopulated.
            agent := undefined,
            delegation := [],
            derivation := undefined,
            obligation := undefined
        },
        R
    ),
    ?assertEqual(
        maps:get(hash, maps:get(?ECHO, Entries)), maps:get(entry_hash, R)
    ),
    ?assert(is_binary(maps:get(principal, R))),
    ?assertMatch(<<"sha256:", _/binary>>, maps:get(result_digest, R)),
    ?assert(is_integer(maps:get(wamp_request_id, R))),
    ?assertNotEqual(undefined, maps:get(session_id, R)).

audit_denied_call_is_recorded_invisibly(Config) ->
    %% §14.1's policy decision: the wire answers exactly like absence
    %% (§6), the audit record does not — and true absence leaves NO
    %% record, so the two are distinguishable only where they should be.
    Auth = basic_auth(?USER, ?PASSWORD),
    Before = length(audit_records()),
    {404, _} = post(
        Config,
        ?RBAC_REALM,
        req(41, <<"tools/call">>, #{
            <<"name">> => ?DENIED, <<"arguments">> => #{}
        }),
        #{auth => Auth}
    ),
    Records = audit_records(),
    ?assertEqual(Before + 1, length(Records)),
    R = lists:last(Records),
    ?assertMatch(
        #{
            type := policy_decision,
            status := denied,
            realm := ?RBAC_REALM,
            principal := ?USER,
            is_anonymous := false,
            name := ?DENIED,
            decision := #{verdict := deny, source := rbac}
        },
        R
    ),
    {404, _} = post(
        Config,
        ?RBAC_REALM,
        req(42, <<"tools/call">>, #{
            <<"name">> => <<"com.example.mcp.mod.rbac.absent">>,
            <<"arguments">> => #{}
        }),
        #{auth => Auth}
    ),
    ?assertEqual(Before + 1, length(audit_records())).

audit_redaction_applies_at_capture(Config) ->
    %% §14.3 end to end: the overlay's redaction policy travels
    %% parser → store → compiled manifest → capture, and the redacted
    %% field influences nothing the record captures.
    Args = #{<<"customer">> => <<"acme">>, <<"ssn">> => <<"123-45-6789">>},
    {200, _} = post(
        Config,
        ?OPEN_REALM,
        req(43, <<"tools/call">>, #{
            <<"name">> => <<"secret_tool">>, <<"arguments">> => Args
        })
    ),
    Expected = bondy_mcp_audit:digest(#{<<"customer">> => <<"acme">>}, none),
    [R] = [
        X
     || X <- audit_records(), maps:get(args_digest, X) == Expected
    ],
    ?assertEqual(<<"secret_tool">>, maps:get(name, R)),
    ?assertEqual(#{fields => [<<"ssn">>]}, maps:get(redaction, R)),
    %% The unredacted digest appears NOWHERE in the captured records.
    Unredacted = bondy_mcp_audit:digest(Args, none),
    ?assertEqual(
        [],
        [X || X <- audit_records(), maps:get(args_digest, X) == Unredacted]
    ).

%% =============================================================================
%% CASES — multi round-trip requests (§11.1, §21.7)
%% =============================================================================

tools_call_input_required_round_trip(Config) ->
    Self = self(),
    TelId = {?MODULE, mrtr_audit},
    ok = telemetry:attach(
        TelId,
        [bondy, mcp, audit, record],
        fun(_, _, #{record := R}, _) -> Self ! {mrtr_audit, R} end,
        undefined
    ),
    Args = #{<<"purpose">> => <<"demo">>},
    try
        {200, #{<<"result">> := R1}} = post(
            Config,
            ?OPEN_REALM,
            req(60, <<"tools/call">>, #{
                <<"name">> => ?APPROVE, <<"arguments">> => Args
            })
        ),
        %% The InputRequiredResult shape, EXACTLY: no content, no isError.
        ?assertEqual(
            [<<"inputRequests">>, <<"requestState">>, <<"resultType">>],
            lists:sort(maps:keys(R1))
        ),
        ?assertEqual(<<"input_required">>, maps:get(<<"resultType">>, R1)),
        #{<<"who">> := Who} = maps:get(<<"inputRequests">>, R1),
        ?assertMatch(
            #{
                <<"method">> := <<"elicitation/create">>,
                <<"params">> := #{<<"message">> := <<"Who approves?">>}
            },
            Who
        ),
        Sealed = maps:get(<<"requestState">>, R1),
        %% Opaque: a compact JWE (five dot-separated parts) whose
        %% plaintext — the callee's continuation — does not appear.
        ?assertEqual(5, length(binary:split(Sealed, <<".">>, [global]))),
        ?assertEqual(nomatch, binary:match(Sealed, <<"tomato-42">>)),

        %% The retry: SAME name and arguments, plus the gathered
        %% responses and the echoed request state.
        Responses = #{
            <<"who">> => #{
                <<"action">> => <<"accept">>,
                <<"content">> => #{<<"name">> => <<"ada">>}
            }
        },
        {200, #{<<"result">> := R2}} = post(
            Config,
            ?OPEN_REALM,
            req(61, <<"tools/call">>, #{
                <<"name">> => ?APPROVE,
                <<"arguments">> => Args,
                <<"inputResponses">> => Responses,
                <<"requestState">> => Sealed
            })
        ),
        ?assertMatch(
            #{<<"resultType">> := <<"complete">>, <<"isError">> := false},
            R2
        ),
        SC = maps:get(<<"structuredContent">>, R2),
        %% The callee got its continuation back, and the responses.
        ?assertEqual(
            #{<<"nonce">> => <<"tomato-42">>},
            maps:get(<<"resumed_state">>, SC)
        ),
        ?assertEqual(Responses, maps:get(<<"responses">>, SC)),

        %% §14: both legs audited as ONE logical call — two records
        %% sharing a continuation id nothing else carries.
        [A1, A2] = collect_mrtr_audit(2, []),
        ?assertEqual(
            [input_required, success],
            [maps:get(status, A) || A <- [A1, A2]]
        ),
        Cont = maps:get(continuation, A1),
        ?assert(is_binary(Cont)),
        ?assertEqual(Cont, maps:get(continuation, A2))
    after
        telemetry:detach(TelId)
    end.

state_only_continuation_round_trip(Config) ->
    %% §11.2's primitive: no input requests at all — "check back later"
    %% as a requestState-only InputRequiredResult (the specification's
    %% load-shedding example), completed by an out-of-band condition the
    %% callee models.
    {200, #{<<"result">> := R1}} = post(
        Config,
        ?OPEN_REALM,
        req(62, <<"tools/call">>, #{
            <<"name">> => ?PENDING, <<"arguments">> => #{}
        })
    ),
    %% `inputRequests` is OMITTED, not empty.
    ?assertEqual(
        [<<"requestState">>, <<"resultType">>], lists:sort(maps:keys(R1))
    ),
    {200, #{<<"result">> := R2}} = post(
        Config,
        ?OPEN_REALM,
        req(63, <<"tools/call">>, #{
            <<"name">> => ?PENDING,
            <<"arguments">> => #{},
            <<"requestState">> => maps:get(<<"requestState">>, R1)
        })
    ),
    ?assertMatch(#{<<"resultType">> := <<"complete">>}, R2),
    ?assertMatch(#{<<"done">> := true}, maps:get(<<"structuredContent">>, R2)).

request_state_bindings_are_enforced(Config) ->
    Args = #{<<"purpose">> => <<"demo">>},
    {200, #{<<"result">> := R1}} = post(
        Config,
        ?OPEN_REALM,
        req(64, <<"tools/call">>, #{
            <<"name">> => ?APPROVE, <<"arguments">> => Args
        })
    ),
    Sealed = maps:get(<<"requestState">>, R1),
    Retry = fun(N, Name, RetryArgs, State) ->
        post(
            Config,
            ?OPEN_REALM,
            req(N, <<"tools/call">>, #{
                <<"name">> => Name,
                <<"arguments">> => RetryArgs,
                <<"inputResponses">> => #{},
                <<"requestState">> => State
            })
        )
    end,
    %% A tampered envelope is rejected (AEAD integrity)...
    Pos = byte_size(Sealed) - 10,
    <<A:Pos/binary, C, B/binary>> = Sealed,
    C1 =
        case C of
            $A -> $B;
            _ -> $A
        end,
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32602}}},
        Retry(65, ?APPROVE, Args, <<A/binary, C1, B/binary>>)
    ),
    %% ...as is a genuine one presented with DIFFERENT arguments (the
    %% originating-request digest binding)...
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32602}}},
        Retry(66, ?APPROVE, #{<<"purpose">> => <<"other">>}, Sealed)
    ),
    %% ...or on a DIFFERENT tool (the name binding).
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32602}}},
        Retry(67, ?PENDING, Args, Sealed)
    ),
    %% And the gateway's channel to the callee cannot be impersonated:
    %% the `_mcp` argument namespace is reserved.
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32602}}},
        post(
            Config,
            ?OPEN_REALM,
            req(68, <<"tools/call">>, #{
                <<"name">> => ?ECHO,
                <<"arguments">> => #{<<"_mcp_state">> => #{}}
            })
        )
    ).

request_state_replay_by_another_principal_is_rejected(Config) ->
    %% THE §21.7 falsification target. Leg 1 is minted in-VM as ?USER —
    %% the handler's `open` is the enforcement point and runs BEFORE any
    %% callee, so none is needed.
    {ok, Sealed} = bondy_mcp_request_state:seal(?RBAC_REALM, #{
        continuation => <<"ct-replay">>,
        principal => ?USER,
        method => <<"tools/call">>,
        name => ?ALLOWED,
        args_hash => bondy_mcp_request_state:args_hash(#{}),
        state => #{<<"granted">> => true}
    }),
    Retry = fun(N, User) ->
        post(
            Config,
            ?RBAC_REALM,
            req(N, <<"tools/call">>, #{
                <<"name">> => ?ALLOWED,
                <<"arguments">> => #{},
                <<"inputResponses">> => #{},
                <<"requestState">> => Sealed
            }),
            #{auth => basic_auth(User, ?PASSWORD)}
        )
    end,
    %% A different principal — same group, same grants, every OTHER
    %% binding matching — is rejected...
    ?assertMatch(
        {400, #{<<"error">> := #{<<"code">> := -32602}}},
        Retry(69, ?USER2)
    ),
    %% ...while the minted-for principal passes the state gate and
    %% proceeds to the call, hitting the declared-but-unregistered
    %% procedure (§7.7's retryable tool error) — proof the rejection
    %% above was the principal binding and nothing else.
    {200, #{<<"result">> := R}} = Retry(70, ?USER),
    ?assertMatch(
        #{
            <<"isError">> := true,
            <<"structuredContent">> := #{<<"retryable">> := true}
        },
        R
    ).

%% Collect audit records for the two MRTR legs. Leg order is recovered
%% from the status (`input_required` precedes `success`) — arrival order
%% across two emitting request processes is not pledged.
collect_mrtr_audit(0, Acc) ->
    Rank = fun
        (input_required) -> 0;
        (_) -> 1
    end,
    lists:sort(
        fun(X, Y) ->
            Rank(maps:get(status, X)) =< Rank(maps:get(status, Y))
        end,
        lists:reverse(Acc)
    );
collect_mrtr_audit(N, Acc) ->
    receive
        {mrtr_audit, R} ->
            case maps:get(name, R) of
                ?APPROVE -> collect_mrtr_audit(N - 1, [R | Acc]);
                _ -> collect_mrtr_audit(N, Acc)
            end
    after 5000 ->
        error({mrtr_audit_records_missing, N})
    end.

%% =============================================================================
%% CASES — subscriptions/listen (§9, §21.6)
%% =============================================================================

-define(SUBID_KEY, <<"io.modelcontextprotocol/subscriptionId">>).

listen_ack_first_and_filter_enforced(Config) ->
    %% The spec's two MUSTs at once: the acknowledgment is the FIRST
    %% message and reflects the honored subset (prompts unsupported →
    %% omitted), and a notification type the client did not request is
    %% NEVER sent — a resource publish delivers nothing to a stream that
    %% asked only for toolsListChanged.
    {Conn, Ref, Buf0} = listen_open(Config, ?OPEN_REALM, 60, #{
        <<"toolsListChanged">> => true,
        <<"promptsListChanged">> => true
    }),
    {Ack, Buf1} = sse_next(Conn, Ref, Buf0, 5000),
    ?assertMatch(
        #{
            <<"method">> := <<"notifications/subscriptions/acknowledged">>,
            <<"params">> := #{
                <<"_meta">> := #{?SUBID_KEY := 60},
                <<"notifications">> := #{<<"toolsListChanged">> := true}
            }
        },
        Ack
    ),
    #{<<"params">> := #{<<"notifications">> := AckN}} = Ack,
    ?assertNot(maps:is_key(<<"promptsListChanged">>, AckN)),
    ?assertNot(maps:is_key(<<"resourceSubscriptions">>, AckN)),

    ok = publish(Config, ?TICKS, [], #{<<"n">> => 1}),
    ?assertEqual(timeout, sse_next(Conn, Ref, Buf1, 1500)),

    %% A manifest CHANGE reaches the stream as the requested type,
    %% tagged with the subscription id.
    %% This load changes BOTH kinds — a tool AND a resource template —
    %% so the rebuild offers both list-changed types; the stream asked
    %% only for tools.
    ok = bondy_mcp_gateway:load(#{
        <<"id">> => <<"mcp_stream_extra">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?OPEN_REALM,
                <<"name">> => <<"extra_tool">>,
                <<"kind">> => <<"tool">>,
                <<"wamp_procedure">> => <<"com.example.mcp.mod.extra">>
            },
            #{
                <<"realm">> => ?OPEN_REALM,
                <<"name">> => <<"extra_res">>,
                <<"kind">> => <<"resource_template">>,
                <<"wamp_procedure">> => <<"com.example.mcp.mod.extra.get">>,
                <<"uri_template">> => <<"extra:///{id}">>,
                <<"uri_vars_schema">> => #{
                    <<"id">> => #{<<"type">> => <<"integer">>}
                },
                <<"wamp_kwargs">> => #{<<"id">> => <<"{{id}}">>},
                <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
            }
        ]
    }),
    try
        {N1, Buf2} = sse_next(Conn, Ref, Buf1, 15000),
        ?assertMatch(
            #{
                <<"method">> := <<"notifications/tools/list_changed">>,
                <<"params">> := #{<<"_meta">> := #{?SUBID_KEY := 60}}
            },
            N1
        ),
        %% resources ALSO changed, but resourcesListChanged was not
        %% requested — nothing else arrives (the spec's MUST NOT).
        ?assertEqual(timeout, sse_next(Conn, Ref, Buf2, 1500))
    after
        ok = bondy_mcp_gateway:delete(<<"mcp_stream_extra">>),
        ok = gun:close(Conn)
    end.

listen_resource_updates_round_trip(Config) ->
    %% §9.2 both resolution paths: a base resource (`wamp:<realm>:<topic>`)
    %% and a template instance whose `update_topic` interpolates the bound
    %% variable. An unknown URI is silently omitted from the ack, and an
    %% update for a DIFFERENT template instance never arrives.
    TicksResource = ?TICKS_RESOURCE,
    {Conn, Ref, Buf0} = listen_open(Config, ?OPEN_REALM, 61, #{
        <<"resourceSubscriptions">> => [
            TicksResource, <<"users:///42">>, <<"nope:///x">>
        ]
    }),
    {Ack, Buf1} = sse_next(Conn, Ref, Buf0, 5000),
    ?assertMatch(
        #{
            <<"params">> := #{
                <<"notifications">> := #{
                    <<"resourceSubscriptions">> := [
                        TicksResource, <<"users:///42">>
                    ]
                }
            }
        },
        Ack
    ),
    ok = publish(Config, ?TICKS, [1], #{}),
    {E1, Buf2} = sse_next(Conn, Ref, Buf1, 5000),
    ?assertMatch(
        #{
            <<"method">> := <<"notifications/resources/updated">>,
            <<"params">> := #{
                <<"uri">> := TicksResource,
                <<"_meta">> := #{?SUBID_KEY := 61}
            }
        },
        E1
    ),
    %% §9.2: only the URI travels; the payload does not.
    #{<<"params">> := E1Params} = E1,
    ?assertEqual(
        [<<"_meta">>, <<"uri">>], lists:sort(maps:keys(E1Params))
    ),
    ok = publish(Config, <<"com.example.mcp.mod.user.42.changed">>, [], #{}),
    {E2, Buf3} = sse_next(Conn, Ref, Buf2, 5000),
    ?assertMatch(
        #{<<"params">> := #{<<"uri">> := <<"users:///42">>}}, E2
    ),
    ok = publish(Config, <<"com.example.mcp.mod.user.43.changed">>, [], #{}),
    ?assertEqual(timeout, sse_next(Conn, Ref, Buf3, 1500)),
    ok = gun:close(Conn).

listen_rbac_denied_subscription_is_omitted_and_audited(Config) ->
    %% §6 applied to the subscription filter: a topic the principal lacks
    %% `wamp.subscribe` on is omitted from the ack exactly like an unknown
    %% one — and the denial is a §14.1 policy-decision audit record.
    OkUri = <<"wamp:", ?RBAC_REALM/binary, ":", ?SUB_OK_TOPIC/binary>>,
    NoUri = <<"wamp:", ?RBAC_REALM/binary, ":", ?SUB_NO_TOPIC/binary>>,
    Before = length(audit_records()),
    {Conn, Ref, Buf0} = listen_open(
        Config,
        ?RBAC_REALM,
        62,
        #{<<"resourceSubscriptions">> => [OkUri, NoUri]},
        #{auth => basic_auth(?USER, ?PASSWORD)}
    ),
    {Ack, _} = sse_next(Conn, Ref, Buf0, 5000),
    ?assertMatch(
        #{
            <<"params">> := #{
                <<"notifications">> := #{
                    <<"resourceSubscriptions">> := [OkUri]
                }
            }
        },
        Ack
    ),
    Records = audit_records(),
    ?assertEqual(Before + 1, length(Records)),
    ?assertMatch(
        #{
            type := policy_decision,
            status := denied,
            realm := ?RBAC_REALM,
            principal := ?USER,
            name := ?SUB_NO_TOPIC,
            uri := NoUri,
            decision := #{verdict := deny, source := rbac}
        },
        lists:last(Records)
    ),
    ok = gun:close(Conn).

closing_stream_unsubscribes_everything(Config) ->
    %% The transport-drop ending (§9.3): the client closes; NOTHING was
    %% sent to it; the session-manager DOWN cleanup removes the stored
    %% session and every WAMP subscription the stream held.
    ok = drain_streams(?OPEN_REALM),
    %% Quiesce: an earlier stream's DOWN cleanup is asynchronous — wait
    %% for its subscription to be gone before taking baselines, or the
    %% restore condition below can never be met.
    ok = wait_until(
        fun() -> sub_count(?OPEN_REALM, ?TICKS) == 0 end, 10000, quiesce
    ),
    ok = ct:sleep(300),
    Sessions0 = stored_session_count(),
    {Conn, Ref, Buf0} = listen_open(Config, ?OPEN_REALM, 63, #{
        <<"resourceSubscriptions">> => [?TICKS_RESOURCE, <<"users:///7">>]
    }),
    {_Ack, Buf1} = sse_next(Conn, Ref, Buf0, 5000),
    ?assertEqual(Sessions0 + 1, stored_session_count()),
    ?assertEqual(1, sub_count(?OPEN_REALM, ?TICKS)),
    ?assertMatch([_], bondy_mcp_stream:pids(?OPEN_REALM)),
    %% Nothing pending — the drop sends nothing either way.
    ?assertEqual(timeout, sse_next(Conn, Ref, Buf1, 200)),
    ok = gun:close(Conn),
    ok = wait_until(
        fun() ->
            stored_session_count() == Sessions0 andalso
                sub_count(?OPEN_REALM, ?TICKS) == 0 andalso
                bondy_mcp_stream:pids(?OPEN_REALM) == []
        end,
        10000,
        {post_close, Sessions0}
    ).

server_teardown_sends_completion(Config) ->
    %% The graceful ending (§9.3): `notifications/cancelled` naming the
    %% listen request id — the spec's ONLY sanctioned server-side use —
    %% then the completion response correlated by that id. A transport
    %% drop (previous case) sends neither.
    ok = drain_streams(?OPEN_REALM),
    {Conn, Ref, Buf0} = listen_open(Config, ?OPEN_REALM, 64, #{
        <<"toolsListChanged">> => true
    }),
    {_Ack, Buf1} = sse_next(Conn, Ref, Buf0, 5000),
    [Pid] = bondy_mcp_stream:pids(?OPEN_REALM),
    ok = bondy_mcp_stream:close(Pid, shutdown),
    {Cancelled, Buf2} = sse_next(Conn, Ref, Buf1, 5000),
    ?assertMatch(
        #{
            <<"method">> := <<"notifications/cancelled">>,
            <<"params">> := #{<<"requestId">> := 64}
        },
        Cancelled
    ),
    {Final, _} = sse_next(Conn, Ref, Buf2, 5000),
    ?assertMatch(
        #{
            <<"id">> := 64,
            <<"result">> := #{
                <<"resultType">> := <<"complete">>,
                <<"_meta">> := #{?SUBID_KEY := 64}
            }
        },
        Final
    ),
    ok = wait_until(
        fun() -> bondy_mcp_stream:pids(?OPEN_REALM) == [] end, 10000
    ),
    ok = gun:close(Conn).

stream_survives_quiet_hold_at_connection_floor(Config) ->
    %% §3.8 / §21.6: stream lifetime is the CONNECTION idle timer, seated
    %% for a listener whose services include `mcp` from the carrier's own
    %% `idle_timeout` with reset-on-send — checked here against the REAL
    %% resolution (`with_option_defaults/1`), then proved on the wire: a
    %% quiet 18s hold survives on a listener carrying the resolved floor
    %% and dies on one carrying the bare 15s HTTP default.
    Resolved = bondy_listener_config:with_option_defaults(#{
        transport => tcp, protocol => http, services => [mcp]
    }),
    #{
        protocol_opts := #{
            idle_timeout := FloorIT,
            reset_idle_timeout_on_send := ResetOnSend
        }
    } = Resolved,
    ?assert(FloorIT >= 60000),
    ?assertEqual(true, ResetOnSend),
    Routes = bondy_mcp_http_service:routes(
        mcp,
        #{config => carrier_config()},
        #{name => ct_mcp_floor, transport => tcp}
    ),
    Dispatch = cowboy_router:compile(Routes),
    {ok, _} = cowboy:start_clear(ct_mcp_floor, [{port, 0}], #{
        env => #{dispatch => Dispatch},
        idle_timeout => FloorIT,
        reset_idle_timeout_on_send => ResetOnSend
    }),
    {ok, _} = cowboy:start_clear(ct_mcp_bare, [{port, 0}], #{
        env => #{dispatch => Dispatch},
        idle_timeout => 15000
    }),
    try
        FloorPort = ranch:get_port(ct_mcp_floor),
        BarePort = ranch:get_port(ct_mcp_bare),
        {C1, R1, B1} = listen_open_port(FloorPort, ?OPEN_REALM, 65, #{
            <<"resourceSubscriptions">> => [?TICKS_RESOURCE]
        }),
        {_, B1a} = sse_next(C1, R1, B1, 5000),
        {C2, R2, B2} = listen_open_port(BarePort, ?OPEN_REALM, 66, #{
            <<"resourceSubscriptions">> => [?TICKS_RESOURCE]
        }),
        {_, B2a} = sse_next(C2, R2, B2, 5000),
        ct:sleep(18000),
        %% The bare listener killed its held stream at ~15s...
        ?assertEqual(closed, sse_next(C2, R2, B2a, 2000)),
        %% ...the floor listener's stream is alive AND still delivers.
        ok = publish(Config, ?TICKS, [], #{}),
        ?assertMatch(
            {#{<<"method">> := <<"notifications/resources/updated">>}, _},
            sse_next(C1, R1, B1a, 5000)
        ),
        ok = gun:close(C1),
        ok = gun:close(C2)
    after
        ok = cowboy:stop_listener(ct_mcp_floor),
        ok = cowboy:stop_listener(ct_mcp_bare)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% The suite's callees on an in-VM SDK connection owned by a process that
%% outlives init_per_suite (the connection links to its opener, and CT's
%% init_per_suite process dies once init returns).
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
            Conn, ?SECRET, fun(_, KwArgs, _) -> {ok, #{kwargs => KwArgs}} end
        ),
        %% The SEP-414 probe: reports the trace context its INVOCATION
        %% details carried, read through the SDK's own extract surface.
        {ok, _} = bondy_connect_client:register(
            Conn, ?TRACED, fun(_, _, Details) ->
                KWArgs =
                    case bondy_connect_trace:extract(Details) of
                        undefined ->
                            #{<<"traced">> => false};
                        Ctx ->
                            maps:fold(
                                fun(K, V, Acc) ->
                                    Acc#{atom_to_binary(K) => V}
                                end,
                                #{<<"traced">> => true},
                                Ctx
                            )
                    end,
                {ok, #{kwargs => KWArgs}}
            end
        ),
        %% §11.1: first leg elicits and hands the gateway a continuation;
        %% the resume leg receives it back with the responses and echoes
        %% both, proving the whole loop.
        {ok, _} = bondy_connect_client:register(
            Conn, ?APPROVE, fun(_, KwArgs, _) ->
                case maps:get(<<"_mcp_state">>, KwArgs, undefined) of
                    undefined ->
                        {error, #{
                            uri => ?INPUT_REQUIRED_URI,
                            kwargs => #{
                                <<"input_requests">> => #{
                                    <<"who">> => #{
                                        <<"method">> =>
                                            <<"elicitation/create">>,
                                        <<"params">> => #{
                                            <<"mode">> => <<"form">>,
                                            <<"message">> =>
                                                <<"Who approves?">>,
                                            <<"requestedSchema">> => #{
                                                <<"type">> => <<"object">>,
                                                <<"properties">> => #{
                                                    <<"name">> => #{
                                                        <<"type">> =>
                                                            <<"string">>
                                                    }
                                                }
                                            }
                                        }
                                    }
                                },
                                <<"state">> => #{
                                    <<"nonce">> => <<"tomato-42">>
                                }
                            }
                        }};
                    State ->
                        {ok, #{
                            kwargs => #{
                                <<"resumed_state">> => State,
                                <<"responses">> => maps:get(
                                    <<"_mcp_input_responses">>, KwArgs, #{}
                                )
                            }
                        }}
                end
            end
        ),
        %% §11.2's primitive: a state-only continuation ("check back
        %% later") with no input requests at all.
        {ok, _} = bondy_connect_client:register(
            Conn, ?PENDING, fun(_, KwArgs, _) ->
                case maps:get(<<"_mcp_state">>, KwArgs, undefined) of
                    undefined ->
                        {error, #{
                            uri => ?INPUT_REQUIRED_URI,
                            kwargs => #{
                                <<"state">> => #{<<"poll">> => 1}
                            }
                        }};
                    _ ->
                        {ok, #{kwargs => #{<<"done">> => true}}}
                end
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

%% The next telemetry metadata a case's capture handler tagged `Tag`.
next_event(Tag) ->
    receive
        {Tag, Meta} -> Meta
    after 5000 ->
        error({telemetry_event_missing, Tag})
    end.

%% Publish on the suite's SDK connection (open realm).
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
    req_v(Id, Method, Params, ?VERSION).

req_v(Id, Method, Params, Version) ->
    %% Merge: a case's own `_meta` entries (e.g. SEP-414 trace keys) ride
    %% alongside the protocol keys, as a real client sends them.
    Meta = maps:merge(
        #{
            <<"io.modelcontextprotocol/protocolVersion">> => Version,
            <<"io.modelcontextprotocol/clientCapabilities">> => #{}
        },
        maps:get(<<"_meta">>, Params, #{})
    ),
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => Meta}
    }.

%% POST with the standard headers derived from the body, the way a
%% conforming client sends them.
%% The MCP endpoint applies the same per-source-IP `http`-class admission
%% the WS and raw-socket handlers apply per connection, BEFORE any realm
%% or parse work. Enabling ONLY that class both trips it and PINS it —
%% a site drawing from any other class would never 429 here. 429 carries
%% no session meaning, so it is safe alongside the reserved 404 (§12).
%% The `{http, 127.0.0.1}` bucket is shared across a run, so only "rapid
%% requests trip 429" and "off means served" are asserted.
requests_are_rate_limited(Config) ->
    {S0, _} = post(Config, ?OPEN_REALM, req(1, <<"tools/list">>, #{})),
    ?assertNotEqual(429, S0),
    ok = bondy_config:set([security, rate_limit], #{
        enabled => true,
        http => #{rate => 1, capacity => 2}
    }),
    try
        Statuses = [
            element(
                1, post(Config, ?OPEN_REALM, req(N, <<"tools/list">>, #{}))
            )
         || N <- lists:seq(2, 7)
        ],
        ?assertEqual(429, lists:last(Statuses))
    after
        ok = bondy_config:set([security, rate_limit], undefined)
    end,
    %% Off again: the same source IP serves immediately — the verdict is
    %% config-driven, no depleted bucket outlives the feature.
    {S1, _} = post(Config, ?OPEN_REALM, req(8, <<"tools/list">>, #{})),
    ?assertNotEqual(429, S1).

server_discover_answers_the_probe(Config) ->
    %% The official 2026-era client's negotiation probe, byte-shaped as
    %% measured on the wire (string JSON-RPC id, `_meta` envelope,
    %% `Mcp-Method: server/discover`): the answer must offer the modern
    %% revision in `supportedVersions` and carry `capabilities` — the two
    %% fields the client's DiscoverResult validator requires for a modern
    %% era verdict.
    ProbeId = <<"server-discover-probe-1">>,
    {200, #{<<"id">> := ProbeId, <<"result">> := Result}} = post(
        Config, ?OPEN_REALM, req(ProbeId, <<"server/discover">>, #{})
    ),
    ?assertEqual([?VERSION], maps:get(<<"supportedVersions">>, Result)),
    ?assertMatch(
        #{
            <<"tools">> := #{<<"listChanged">> := true},
            <<"resources">> := #{<<"subscribe">> := true}
        },
        maps:get(<<"capabilities">>, Result)
    ),
    ?assertMatch(
        #{
            <<"io.modelcontextprotocol/serverInfo">> := #{
                <<"name">> := <<"Bondy">>,
                <<"version">> := _
            }
        },
        maps:get(<<"_meta">>, Result)
    ),
    %% A probe declaring a HANDSHAKE version without a session stays
    %% refused (transport spec rule 2) — discover cannot leak an era
    %% verdict out of a version the request never negotiated.
    {400, _} = post(
        Config,
        ?OPEN_REALM,
        req_v(2, <<"server/discover">>, #{}, <<"2025-11-25">>)
    ).

origin_policy_is_enforced(Config) ->
    %% DNS-rebinding protection on the suite's default carrier
    %% (`allowed_origins => [local]`): a browser-borne evil `Origin` is
    %% refused before any realm work, localhost origins pass on any
    %% scheme/port/case, and the ABSENT header always serves — the
    %% non-browser SDK path every other case in this suite rides.
    Probe = fun(Hdrs) ->
        Body = req(1, <<"tools/list">>, #{}),
        element(
            1,
            raw_post(Config, ?OPEN_REALM, Hdrs ++ std_headers(Body, #{}), Body)
        )
    end,
    ?assertEqual(200, Probe([])),
    ?assertEqual(200, Probe([{"origin", "http://127.0.0.1:9999"}])),
    ?assertEqual(200, Probe([{"origin", "HTTP://LOCALHOST:3000"}])),
    ?assertEqual(403, Probe([{"origin", "http://evil.example.com"}])),
    %% Present-but-unparseable matches no rule: explicit garbage fails
    %% closed.
    ?assertEqual(403, Probe([{"origin", "::garbage::"}])),

    %% `local` is a RULE, not a hardcode: an explicit-origins listener
    %% refuses localhost and serves exactly what it lists
    %% (case-insensitively); `any` disables the check.
    Explicit = (carrier_config())#{
        allowed_origins => [<<"https://app.example.com">>]
    },
    Any = (carrier_config())#{allowed_origins => any},
    {ok, _} = start_origin_listener(ct_mcp_origin_explicit, Explicit),
    {ok, _} = start_origin_listener(ct_mcp_origin_any, Any),
    try
        ExplicitPort = ranch:get_port(ct_mcp_origin_explicit),
        AnyPort = ranch:get_port(ct_mcp_origin_any),
        ?assertEqual(
            200, origin_probe(ExplicitPort, "https://app.example.com")
        ),
        ?assertEqual(
            200, origin_probe(ExplicitPort, "HTTPS://APP.Example.COM")
        ),
        ?assertEqual(403, origin_probe(ExplicitPort, "http://127.0.0.1:1")),
        ?assertEqual(200, origin_probe(AnyPort, "http://evil.example.com"))
    after
        ok = cowboy:stop_listener(ct_mcp_origin_explicit),
        ok = cowboy:stop_listener(ct_mcp_origin_any)
    end.

start_origin_listener(Name, CarrierConfig) ->
    Routes = bondy_mcp_http_service:routes(
        mcp,
        #{config => CarrierConfig},
        #{name => Name, transport => tcp}
    ),
    cowboy:start_clear(
        Name,
        [{port, 0}],
        #{env => #{dispatch => cowboy_router:compile(Routes)}}
    ).

origin_probe(Port, Origin) ->
    Body = req(1, <<"tools/list">>, #{}),
    Url = lists:flatten(
        io_lib:format(
            "http://127.0.0.1:~b/mcp/realm/~s", [Port, ?OPEN_REALM]
        )
    ),
    Headers = [{"origin", Origin} | std_headers(Body, #{})],
    {ok, {{_, Status, _}, _, _}} = httpc:request(
        post,
        {Url, Headers, "application/json", iolist_to_binary(json:encode(Body))},
        [],
        [{body_format, binary}]
    ),
    Status.

post(Config, Realm, Body) ->
    post(Config, Realm, Body, #{}).

post(Config, Realm, Body, Opts) ->
    raw_post(Config, Realm, std_headers(Body, Opts), Body).

std_headers(#{<<"method">> := Method} = Body, Opts) ->
    Params = maps:get(<<"params">>, Body, #{}),
    Meta = maps:get(<<"_meta">>, Params, #{}),
    Version = maps:get(
        <<"io.modelcontextprotocol/protocolVersion">>, Meta, ?VERSION
    ),
    H0 = [
        {"mcp-protocol-version", binary_to_list(Version)},
        {"mcp-method", binary_to_list(Method)}
    ],
    H1 =
        case Method of
            <<"tools/call">> ->
                [
                    {"mcp-name", binary_to_list(maps:get(<<"name">>, Params))}
                    | H0
                ];
            <<"resources/read">> ->
                [
                    {"mcp-name", binary_to_list(maps:get(<<"uri">>, Params))}
                    | H0
                ];
            _ ->
                H0
        end,
    case maps:get(auth, Opts, undefined) of
        undefined -> H1;
        Auth -> [Auth | H1]
    end.

raw_post(Config, Realm, Headers, Body) ->
    Port = ?config(port, Config),
    Url = lists:flatten(
        io_lib:format(
            "http://127.0.0.1:~b/mcp/realm/~s", [Port, Realm]
        )
    ),
    {ok, {{_, Status, _}, _, RespBody}} = httpc:request(
        post,
        {Url, Headers, "application/json", iolist_to_binary(json:encode(Body))},
        [],
        [{body_format, binary}]
    ),
    Decoded =
        case RespBody of
            <<>> -> #{};
            _ -> json:decode(RespBody)
        end,
    {Status, Decoded}.

basic_auth(User, Password) ->
    {"authorization",
        "Basic " ++
            base64:encode_to_string(<<User/binary, ":", Password/binary>>)}.

%% Walk the cursor chain and return every tool.
all_tools(Config, Realm, Opts) ->
    all_tools(Config, Realm, Opts, undefined, []).

all_tools(Config, Realm, Opts, Cursor, Acc) ->
    Params =
        case Cursor of
            undefined -> #{};
            _ -> #{<<"cursor">> => Cursor}
        end,
    {200, #{<<"result">> := Result}} = post(
        Config, Realm, req(100, <<"tools/list">>, Params), Opts
    ),
    Acc1 = Acc ++ maps:get(<<"tools">>, Result),
    case maps:get(<<"nextCursor">>, Result, undefined) of
        undefined -> Acc1;
        Next -> all_tools(Config, Realm, Opts, Next, Acc1)
    end.

%% Opens a `subscriptions/listen` SSE stream over gun; returns the
%% connection, the stream ref and an (empty) parse buffer after asserting
%% the 200 + text/event-stream response.
listen_open(Config, Realm, Id, Filter) ->
    listen_open(Config, Realm, Id, Filter, #{}).

listen_open(Config, Realm, Id, Filter, Opts) ->
    listen_open_port(?config(port, Config), Realm, Id, Filter, Opts).

listen_open_port(Port, Realm, Id, Filter) ->
    listen_open_port(Port, Realm, Id, Filter, #{}).

listen_open_port(Port, Realm, Id, Filter, Opts) ->
    {ok, Conn} = gun:open("127.0.0.1", Port, #{
        transport => tcp, protocols => [http]
    }),
    {ok, _} = gun:await_up(Conn, 5000),
    Body = req(Id, <<"subscriptions/listen">>, #{
        <<"notifications">> => Filter
    }),
    Headers0 = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json, text/event-stream">>},
        {<<"mcp-protocol-version">>, ?VERSION},
        {<<"mcp-method">>, <<"subscriptions/listen">>}
    ],
    Headers =
        case maps:get(auth, Opts, undefined) of
            undefined ->
                Headers0;
            {K, V} ->
                [{list_to_binary(K), list_to_binary(V)} | Headers0]
        end,
    Path = "/mcp/realm/" ++ binary_to_list(Realm),
    Ref = gun:post(Conn, Path, Headers, iolist_to_binary(json:encode(Body))),
    case gun:await(Conn, Ref, 10000) of
        {response, nofin, 200, RespHeaders} ->
            {_, CT} = lists:keyfind(<<"content-type">>, 1, RespHeaders),
            ?assertMatch(<<"text/event-stream", _/binary>>, CT),
            {Conn, Ref, <<>>};
        Other ->
            error({listen_open_failed, Other})
    end.

%% The next JSON-RPC message on the SSE stream: `{Message, Buf}` with the
%% unconsumed bytes, `timeout`, or `closed` when the peer ended the
%% connection.
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

%% One SSE frame's `data:` payload, if the buffer holds a complete frame.
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

%% Local subscription count for one exact topic. Zero matches come back
%% as the registry's `'$end_of_table'`, not as an empty list.
sub_count(Realm, Topic) ->
    case bondy_broker:match_subscriptions(Topic, Realm) of
        '$end_of_table' -> 0;
        {{Local, _Nodes}, _Cont} when is_list(Local) -> length(Local);
        {Local, _} when is_list(Local) -> length(Local)
    end.

%% A clean slate for cases that assert on the realm's stream set: close
%% any stream a FAILED earlier case may have leaked (its gun connection
%% belongs to gun's supervisor, not the dead case process).
drain_streams(Realm) ->
    _ = [
        bondy_mcp_stream:close(P, cleanup)
     || P <- bondy_mcp_stream:pids(Realm)
    ],
    wait_until(
        fun() -> bondy_mcp_stream:pids(Realm) == [] end, 10000, drain_streams
    ).

wait_until(Fun, TimeoutMs) ->
    wait_until(Fun, TimeoutMs, unnamed).

wait_until(Fun, TimeoutMs, Label) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_until_loop(Fun, Deadline, Label).

wait_until_loop(Fun, Deadline, Label) ->
    case Fun() of
        true ->
            ok;
        false ->
            erlang:monotonic_time(millisecond) < Deadline orelse
                error(
                    {wait_until_timeout, Label, #{
                        pids_open => bondy_mcp_stream:pids(?OPEN_REALM),
                        ticks_subs => sub_count(?OPEN_REALM, ?TICKS),
                        sessions => stored_session_count()
                    }}
                ),
            ct:sleep(100),
            wait_until_loop(Fun, Deadline, Label)
    end.

%% The audit records captured at the telemetry seam, in emission order
%% (`ordered_set` on a node-monotonic key).
audit_records() ->
    ets:select(?AUDIT_TAB, [{{'_', '$1'}, [], ['$1']}]).

stored_session_count() ->
    case bondy_session:list() of
        L when is_list(L) -> length(L);
        {L, _} when is_list(L) -> length(L)
    end.

transport_session_count() ->
    length(supervisor:which_children(bondy_http_transport_session_sup)).

%% Every live process currently executing (or spawned into) a bondy_mcp
%% module: the modern edge must add NONE beyond the on-demand manifest
%% manager captured in the baseline.
mcp_owned_pids() ->
    lists:sort([
        P
     || P <- erlang:processes(),
        Info <- [process_info(P, [current_function, initial_call])],
        Info =/= undefined,
        is_mcp_fun(Info)
    ]).

is_mcp_fun([{current_function, {M1, _, _}}, {initial_call, {M2, _, _}}]) ->
    is_mcp_module(M1) orelse is_mcp_module(M2);
is_mcp_fun(_) ->
    false.

is_mcp_module(M) ->
    case atom_to_binary(M) of
        <<"bondy_mcp", _/binary>> -> true;
        _ -> false
    end.
