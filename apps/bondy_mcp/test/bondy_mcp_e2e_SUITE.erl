%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_mcp_e2e_SUITE).

-moduledoc """
End-to-end cases (§21.12): the official MCP SDK client of each era and the
official conformance suite (@modelcontextprotocol/conformance) driven
against a real listener over real sockets, plus the §18.5 two-endpoint
deployment claim.

The node-based cases run the SDKs pinned by this suite's data dir
`package-lock.json` in a copy of that directory under `priv_dir`; they
skip — not fail — when the node toolchain is missing or the npm registry
is unreachable with a cold cache. `two_endpoint_deployment` is pure
Erlang and always runs.

The conformance case asserts exit 0 against the committed
`expected-failures.yaml` baseline, which pins the result set in
BOTH directions: a scenario failing outside the baseline fails the case,
and a baselined scenario that starts passing fails it too (stale entry).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_router/include/bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.bondy.mcp.e2e">>).
-define(ECHO, <<"com.example.mcp.e2e.echo">>).
-define(SIMPLE, <<"com.example.mcp.e2e.simple_text">>).
-define(FAIL, <<"com.example.mcp.e2e.fail">>).
-define(STATIC, <<"com.example.mcp.e2e.static_text">>).
-define(TPL, <<"com.example.mcp.e2e.tpl_data">>).
-define(WATCHED, <<"com.example.mcp.e2e.watched">>).
-define(WATCHED_TOPIC, <<"com.example.mcp.e2e.watched.changed">>).
-define(STUB, <<"com.example.mcp.e2e.stub">>).

%% The conformance scenarios each call a tool of this NAME; all ride one
%% stub procedure, so their failures measure the gateway's deviation
%% (text-only §16.2 output mapping; no server-initiated logging,
%% progress, sampling, or elicitation) rather than a missing fixture.
-define(SCENARIO_TOOLS, [
    <<"test_image_content">>,
    <<"test_audio_content">>,
    <<"test_embedded_resource">>,
    <<"test_multiple_content_types">>,
    <<"test_tool_with_logging">>,
    <<"test_tool_with_progress">>,
    <<"test_sampling">>,
    <<"test_elicitation">>
]).
-define(LISTENER, ct_mcp_e2e).
-define(MODERN, <<"2026-07-28">>).
-define(HS_VERSIONS, [<<"2025-11-25">>, <<"2025-06-18">>]).

suite() ->
    [{timetrap, {minutes, 15}}].

all() ->
    [
        two_endpoint_deployment,
        modern_sdk_client,
        handshake_sdk_client,
        conformance_active_suite
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(inets),

    Realm = bondy_realm:create(?REALM),
    ok = bondy_realm:disable_security(Realm),

    %% Every unclaimed procedure projects as a base tool named by its
    %% URI, and the conformance `tools-list` scenario requires a
    %% description on EVERY listed tool — so each interface entry
    %% carries one.
    ok = bondy_interface:load(#{
        <<"id">> => <<"mcp_e2e_iface">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?REALM,
                <<"kind">> => <<"procedure">>,
                <<"uri">> => Uri,
                <<"description">> => Desc
            }
         || {Uri, Desc} <- [
                {?ECHO, <<"Echoes its arguments back">>},
                {?SIMPLE, <<"Returns a fixed text payload">>},
                {?FAIL, <<"Fails deliberately">>},
                {?STATIC, <<"Static text resource read">>},
                {?TPL, <<"Template-bound resource read">>},
                {?WATCHED, <<"Watched resource read">>},
                {?STUB, <<"Conformance scenario stub">>}
            ]
        ]
    }),
    ok = bondy_mcp_gateway:load(#{
        <<"id">> => <<"mcp_e2e_overlay">>,
        <<"entries">> => [
            #{
                <<"realm">> => ?REALM,
                <<"name">> => <<"echo">>,
                <<"kind">> => <<"tool">>,
                <<"wamp_procedure">> => ?ECHO,
                <<"description">> => <<"Echoes its arguments back">>
            },
            #{
                <<"realm">> => ?REALM,
                <<"name">> => <<"test_simple_text">>,
                <<"kind">> => <<"tool">>,
                <<"wamp_procedure">> => ?SIMPLE,
                <<"description">> =>
                    <<"Returns a simple text response for testing">>
            },
            #{
                <<"realm">> => ?REALM,
                <<"name">> => <<"test_error_handling">>,
                <<"kind">> => <<"tool">>,
                <<"wamp_procedure">> => ?FAIL,
                <<"description">> => <<"Returns isError: true for testing">>
            },
            #{
                <<"realm">> => ?REALM,
                <<"name">> => <<"static_text">>,
                <<"kind">> => <<"resource_template">>,
                <<"wamp_procedure">> => ?STATIC,
                <<"uri_template">> => <<"test://static-text">>,
                <<"description">> => <<"Static text resource">>,
                <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
            },
            #{
                <<"realm">> => ?REALM,
                <<"name">> => <<"template_data">>,
                <<"kind">> => <<"resource_template">>,
                <<"wamp_procedure">> => ?TPL,
                <<"uri_template">> => <<"test://template/{id}/data">>,
                <<"uri_vars_schema">> => #{
                    <<"id">> => #{<<"type">> => <<"string">>}
                },
                <<"wamp_kwargs">> => #{<<"id">> => <<"{{id}}">>},
                <<"description">> => <<"Parameter-substituting resource">>,
                <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
            },
            #{
                <<"realm">> => ?REALM,
                <<"name">> => <<"watched">>,
                <<"kind">> => <<"resource_template">>,
                <<"wamp_procedure">> => ?WATCHED,
                <<"uri_template">> => <<"test://watched-resource">>,
                <<"update_topic">> => ?WATCHED_TOPIC,
                <<"description">> => <<"Subscribable resource">>,
                <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
            }
            | [
                #{
                    <<"realm">> => ?REALM,
                    <<"name">> => Name,
                    <<"kind">> => <<"tool">>,
                    <<"wamp_procedure">> => ?STUB,
                    <<"description">> =>
                        <<"Conformance scenario tool ", Name/binary>>
                }
             || Name <- ?SCENARIO_TOOLS
            ]
        ]
    }),

    Owner = spawn_callee_owner(),

    Routes = bondy_mcp_http_service:routes(
        mcp,
        #{config => carrier_config(dual)},
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
        {node_setup, node_setup(Config)}
        | Config
    ].

end_per_suite(Config) ->
    ?config(callee_owner, Config) ! stop,
    ok = cowboy:stop_listener(?LISTENER),
    ok = bondy_interface:delete(<<"mcp_e2e_iface">>),
    ok = bondy_mcp_gateway:delete(<<"mcp_e2e_overlay">>),
    {save_config, Config}.

init_per_testcase(two_endpoint_deployment, Config) ->
    Config;
init_per_testcase(_Case, Config) ->
    case ?config(node_setup, Config) of
        {ok, _Dir} -> Config;
        {skip, Reason} -> {skip, Reason}
    end.

end_per_testcase(_Case, _Config) ->
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

two_endpoint_deployment(_Config) ->
    %% §18.5: two listeners on one node with different per-listener
    %% `mcp.*` options serve the SAME per-realm manifest; the era set and
    %% the body limit are per-listener; retiring one endpoint is deleting
    %% its block (here: stopping its listener) and does not touch the
    %% other. The conf-file `listeners.$name.mcp.*` resolution into this
    %% carrier config shape is `bondy_listener_config`'s property, pinned
    %% by `bondy_mcp_mount_SUITE` — this case composes the resolved
    %% shapes with the real MCP semantics on real sockets.
    InternalCfg = (carrier_config(modern_only))#{max_inflight => 256},
    PartnerCfg = (carrier_config(dual))#{max_body_size => 600},
    {ok, _} = start_extra_listener(ct_mcp_e2e_internal, InternalCfg),
    {ok, _} = start_extra_listener(ct_mcp_e2e_partner, PartnerCfg),
    try
        Internal = ranch:get_port(ct_mcp_e2e_internal),
        Partner = ranch:get_port(ct_mcp_e2e_partner),

        %% Same manifest on both.
        {200, #{<<"result">> := #{<<"tools">> := T1}}} =
            post_port(Internal, modern_req(1, <<"tools/list">>, #{})),
        {200, #{<<"result">> := #{<<"tools">> := T2}}} =
            post_port(Partner, modern_req(1, <<"tools/list">>, #{})),
        Names = fun(Ts) ->
            lists:sort([maps:get(<<"name">>, T) || T <- Ts])
        end,
        ?assertEqual(Names(T1), Names(T2)),
        ?assert(lists:member(<<"echo">>, Names(T1))),

        %% The era set is per-listener: the same initialize bootstraps a
        %% session on the partner endpoint and is refused on the
        %% modern-only internal one.
        Init = init_req(2),
        {200, #{<<"result">> := #{<<"protocolVersion">> := <<"2025-11-25">>}},
            PHdrs} =
            post_port_hdrs(Partner, [], Init),
        ?assertMatch(
            {_, _}, lists:keyfind("mcp-session-id", 1, PHdrs)
        ),
        {200, #{<<"error">> := #{<<"data">> := #{<<"supported">> := Sup}}}} =
            post_port(Internal, Init),
        ?assertEqual([?MODERN], Sup),

        %% The body limit is per-listener: a ~1KB request overflows the
        %% partner's 600-byte cap and rides the internal default fine.
        Pad = binary:copy(<<"x">>, 900),
        Big = modern_req(3, <<"tools/call">>, #{
            <<"name">> => <<"echo">>,
            <<"arguments">> => #{<<"pad">> => Pad}
        }),
        {413, _} = post_port(Partner, Big),
        {200, #{<<"result">> := #{<<"isError">> := false}}} =
            post_port(Internal, Big),

        %% Retiring the partner endpoint leaves the internal one serving.
        ok = cowboy:stop_listener(ct_mcp_e2e_partner),
        {200, #{<<"result">> := _}} =
            post_port(Internal, modern_req(4, <<"tools/list">>, #{}))
    after
        stop_listener_quietly(ct_mcp_e2e_internal),
        stop_listener_quietly(ct_mcp_e2e_partner)
    end.

stop_listener_quietly(Name) ->
    try
        cowboy:stop_listener(Name)
    catch
        _:_ -> ok
    end.

modern_sdk_client(Config) ->
    {ok, Dir} = node_setup_result(Config),
    {Exit, Out} = run_node(
        Dir, ["modern_client.mjs", url(Config)], 120000
    ),
    ct:log("modern_client.mjs (exit ~p):~n~ts", [Exit, Out]),
    Verdict = last_json_line(Out),
    ?assertEqual(0, Exit),
    ?assertMatch(#{<<"ok">> := true, <<"era">> := ?MODERN}, Verdict).

handshake_sdk_client(Config) ->
    {ok, Dir} = node_setup_result(Config),
    {Exit, Out} = run_node(
        Dir, ["handshake_client.mjs", url(Config)], 120000
    ),
    ct:log("handshake_client.mjs (exit ~p):~n~ts", [Exit, Out]),
    Verdict = last_json_line(Out),
    ?assertEqual(0, Exit),
    ?assertMatch(#{<<"ok">> := true, <<"era">> := <<"handshake">>}, Verdict).

conformance_active_suite(Config) ->
    {ok, Dir} = node_setup_result(Config),
    OutDir = filename:join(?config(priv_dir, Config), "conformance"),
    {Exit, Out} = run_node(
        Dir,
        [
            "node_modules/@modelcontextprotocol/conformance/dist/index.js",
            "server",
            "--url",
            url(Config),
            "--suite",
            "active",
            "--expected-failures",
            filename:join(Dir, "expected-failures.yaml"),
            "-o",
            OutDir
        ],
        600000
    ),
    ct:log("conformance (exit ~p):~n~ts", [Exit, Out]),
    ?assertEqual(0, Exit).

%% =============================================================================
%% HELPERS
%% =============================================================================

spawn_callee_owner() ->
    Caller = self(),
    Owner = spawn(fun() ->
        {ok, Conn} = bondy_connect_client:connect(#{
            transport => local,
            endpoint => local,
            realm => ?REALM,
            auth => #{method => ?WAMP_ANON_AUTH},
            serializers => [json]
        }),
        {ok, _} = bondy_connect_client:register(
            Conn, ?ECHO, fun(Args, KwArgs, _) ->
                {ok, #{args => Args, kwargs => KwArgs}}
            end
        ),
        {ok, _} = bondy_connect_client:register(
            Conn, ?SIMPLE, fun(_, _, _) ->
                {ok, #{
                    kwargs => #{
                        <<"message">> =>
                            <<"This is a simple text response for testing.">>
                    }
                }}
            end
        ),
        {ok, _} = bondy_connect_client:register(
            Conn, ?FAIL, fun(_, _, _) ->
                {error, #{
                    uri => <<"com.example.mcp.e2e.deliberate_failure">>,
                    kwargs => #{<<"message">> => <<"deliberate failure">>}
                }}
            end
        ),
        {ok, _} = bondy_connect_client:register(
            Conn, ?STATIC, fun(_, _, _) ->
                {ok, #{kwargs => #{<<"text">> => <<"Hello, world!">>}}}
            end
        ),
        {ok, _} = bondy_connect_client:register(
            Conn, ?TPL, fun(_, KwArgs, _) ->
                {ok, #{kwargs => KwArgs}}
            end
        ),
        {ok, _} = bondy_connect_client:register(
            Conn, ?WATCHED, fun(_, _, _) ->
                {ok, #{kwargs => #{<<"status">> => <<"watched">>}}}
            end
        ),
        {ok, _} = bondy_connect_client:register(
            Conn, ?STUB, fun(_, _, _) ->
                {ok, #{
                    kwargs => #{
                        <<"note">> =>
                            <<"bondy maps WAMP results to text content">>
                    }
                }}
            end
        ),
        Caller ! {ready, self()},
        receive
            stop -> bondy_connect_client:disconnect(Conn)
        end
    end),
    receive
        {ready, Owner} -> Owner
    after 10000 ->
        error(callee_owner_timeout)
    end.

carrier_config(dual) ->
    (carrier_config(modern_only))#{
        protocol_versions => [?MODERN | ?HS_VERSIONS]
    };
carrier_config(modern_only) ->
    #{
        protocol_versions => [?MODERN],
        allowed_origins => [local],
        public_base_uri => undefined,
        max_body_size => 1048576,
        max_inflight => 64,
        idle_timeout => 600000,
        list => #{default_page_size => 50},
        schema => #{max_depth => 32, max_validation_ms => 50}
    }.

start_extra_listener(Name, CarrierConfig) ->
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

url(Port) when is_integer(Port) ->
    lists:flatten(
        io_lib:format(
            "http://127.0.0.1:~b/mcp/realm/~s", [Port, ?REALM]
        )
    );
url(Config) when is_list(Config) ->
    url(?config(port, Config)).

modern_req(Id, Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params#{
            <<"_meta">> => #{
                <<"io.modelcontextprotocol/protocolVersion">> => ?MODERN,
                <<"io.modelcontextprotocol/clientCapabilities">> => #{}
            }
        }
    }.

init_req(Id) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2025-11-25">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{
                <<"name">> => <<"e2e">>, <<"version">> => <<"1">>
            }
        }
    }.

post_port(Port, Body) ->
    {Status, Decoded, _} = post_port_hdrs(Port, [], Body),
    {Status, Decoded}.

post_port_hdrs(Port, ExtraHeaders, #{<<"method">> := Method} = Body) ->
    Params = maps:get(<<"params">>, Body, #{}),
    Meta = maps:get(<<"_meta">>, Params, #{}),
    H0 =
        case
            maps:get(
                <<"io.modelcontextprotocol/protocolVersion">>, Meta, undefined
            )
        of
            undefined ->
                [];
            V ->
                [
                    {"mcp-protocol-version", binary_to_list(V)},
                    {"mcp-method", binary_to_list(Method)}
                ]
        end,
    H1 =
        case {Method, Params} of
            {<<"tools/call">>, #{<<"name">> := N}} ->
                [{"mcp-name", binary_to_list(N)} | H0];
            _ ->
                H0
        end,
    Encoded = iolist_to_binary(json:encode(Body)),
    {ok, {{_, Status, _}, RespHeaders, RespBody}} = httpc:request(
        post,
        {url(Port), H1 ++ ExtraHeaders, "application/json", Encoded},
        [{timeout, 15000}],
        [{body_format, binary}]
    ),
    Decoded =
        case RespBody of
            <<>> -> undefined;
            _ -> json:decode(RespBody)
        end,
    {Status, Decoded, RespHeaders}.

node_setup(Config) ->
    case os:find_executable("node") of
        false ->
            {skip, "node executable not found"};
        _Node ->
            case os:find_executable("npm") of
                false ->
                    {skip, "npm executable not found"};
                Npm ->
                    install_node_deps(Config, Npm)
            end
    end.

install_node_deps(Config, Npm) ->
    %% The committed sources live in this suite's CT data dir; npm runs
    %% against a copy under `priv_dir` so `node_modules` never lands in
    %% the repository tree.
    Src = ?config(data_dir, Config),
    Dir = filename:join(?config(priv_dir, Config), "e2e"),
    ok = filelib:ensure_path(Dir),
    [
        {ok, _} = file:copy(
            filename:join(Src, F), filename:join(Dir, F)
        )
     || F <- [
            "package.json",
            "package-lock.json",
            "modern_client.mjs",
            "handshake_client.mjs",
            "expected-failures.yaml"
        ]
    ],
    case
        run_cmd(
            Dir,
            Npm,
            [
                "ci",
                "--prefer-offline",
                "--no-audit",
                "--no-fund",
                "--loglevel=error"
            ],
            300000
        )
    of
        {0, _} ->
            {ok, Dir};
        {Exit, Out} ->
            ct:log("npm ci failed (~p):~n~ts", [Exit, Out]),
            {skip, "npm ci failed (no registry access?)"}
    end.

node_setup_result(Config) ->
    ?config(node_setup, Config).

run_node(Dir, Args, Timeout) ->
    Node = os:find_executable("node"),
    run_cmd(Dir, Node, Args, Timeout).

run_cmd(Dir, Exe, Args, Timeout) ->
    Port = erlang:open_port(
        {spawn_executable, Exe},
        [
            {cd, Dir},
            {args, Args},
            exit_status,
            binary,
            stderr_to_stdout,
            hide
        ]
    ),
    collect_port(Port, [], Timeout).

collect_port(Port, Acc, Timeout) ->
    receive
        {Port, {data, D}} ->
            collect_port(Port, [D | Acc], Timeout);
        {Port, {exit_status, S}} ->
            {S, iolist_to_binary(lists:reverse(Acc))}
    after Timeout ->
        _ =
            try
                erlang:port_close(Port)
            catch
                _:_ -> false
            end,
        {timeout, iolist_to_binary(lists:reverse(Acc))}
    end.

last_json_line(Out) ->
    Lines = [
        L
     || <<C, _/binary>> = L <- binary:split(Out, <<"\n">>, [global, trim_all]),
        C == ${
    ],
    json:decode(lists:last(Lines)).
