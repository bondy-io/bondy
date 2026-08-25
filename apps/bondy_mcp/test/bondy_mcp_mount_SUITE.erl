%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_mcp_mount_SUITE).

-moduledoc """
Drives the MCP mounting model against real sockets: a listener declaring the
`mcp` service answers the stub handler on both MCP paths (on every virtual
host the listener serves), a listener declaring `mcp` and `admin_api`
together refuses to boot, and a per-listener `mcp.*` option reaches the
route state through the manager's own configuration path.

Runs on a booted node (`bondy_ct:start_bondy/0`): although the subject is
the listener machinery, not MCP semantics, the mounting proof rides the
real handler's realm check and the manager mounts the metrics stream
handler — both need what a booted node seats (measured: the previously
declared lean ranch+cowboy environment fails when the suite runs first
in a fresh VM and was green in batteries only via an earlier suite's
booted node).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([mcp_listener_answers_the_stub_on_both_paths/1]).
-export([mcp_and_admin_api_do_not_boot_together/1]).
-export([per_listener_mcp_option_reaches_route_state/1]).
-export([stub_answers_on_a_host_another_route_set_names/1]).

%% This module doubles as a `bondy_http_service` implementation, giving one
%% case a carrier with a named virtual host without needing a stored API
%% Gateway specification (whose loading needs a booted node).
-export([routes/3]).
-export([init/2]).

all() ->
    [
        mcp_listener_answers_the_stub_on_both_paths,
        mcp_and_admin_api_do_not_boot_together,
        per_listener_mcp_option_reaches_route_state,
        stub_answers_on_a_host_another_route_set_names
    ].

init_per_suite(Config) ->
    %% A booted node, not the leaner ranch+cowboy environment this suite
    %% originally declared: the mounting proof rides the real handler's
    %% realm check (`no_such_realm`), and the manager mounts the cowboy
    %% metrics stream handler whose per-request emission reads prometheus
    %% families a booted node declares — measured 2026-08-26: standalone
    %% (suite first in a fresh VM) both crash, and every green battery
    %% run had ridden a previous suite's booted node. The case comments
    %% below were already written for the shared-node reality.
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(cowboy),
    %% `bondy_listener_manager:init/0` appends the internal `admin_local`
    %% listener, whose socket path is `platform_tmp_dir`-relative and read
    %% without a default. This suite does not boot `bondy_config:init/1`, so
    %% it supplies the key itself; the OS pid keeps parallel CT runs from
    %% sharing the directory.
    %% Node-global like `listeners` below: an already-running bondy resolved
    %% its `admin_local` socket path from the value at ITS boot, and a later
    %% suite recomputes the same path from this key — leaving ours in place
    %% points them at a socket that does not exist. Restored in
    %% `end_per_suite/1`.
    OriginalTmpDir = bondy_config:get(platform_tmp_dir, undefined),
    ok = bondy_config:set(
        platform_tmp_dir, filename:join("/tmp", "bondy_ct_" ++ os:getpid())
    ),
    %% `bondy_router.listeners` and the resolved inventory the manager caches
    %% in `persistent_term` are node-global and outlive this suite in a
    %% `rebar3 ct` run; `end_per_suite/1` restores what was here.
    Original = bondy_config:get(listeners, undefined),
    [
        {original_listeners, Original},
        {original_tmp_dir, OriginalTmpDir}
        | Config
    ].

end_per_suite(Config) ->
    ok = bondy_config:set(listeners, ?config(original_listeners, Config)),
    ok = bondy_config:set(
        platform_tmp_dir, ?config(original_tmp_dir, Config)
    ),
    ok = bondy_listener_manager:init(),
    Config.

%% =============================================================================
%% CASES
%% =============================================================================

mcp_listener_answers_the_stub_on_both_paths(_Config) ->
    %% The whole enablement mechanism: naming `mcp` in `services`. No global
    %% toggle exists to also flip, so a bound socket answering both paths is
    %% the complete proof of mounting.
    ok = bondy_config:set(listeners, [
        {ct_mcp, #{
            transport => tcp, protocol => http, port => 0, services => [mcp]
        }}
    ]),
    ok = bondy_listener_manager:init(),
    ok = bondy_listener_manager:start(normal),
    Port = ranch:get_port(ct_mcp),

    %% A GET on the JSON-RPC path reaches the real handler — since §21.8
    %% GET is a real method (the handshake era's held stream), so the
    %% mounting proof is the handler's own realm check: only OUR handler
    %% answers `no_such_realm` for the URL's realm binding.
    Rpc = http_get(Port, "localhost", "/mcp/realm/com.example.test"),
    ?assertMatch({404, _}, Rpc),
    {_, RpcBody} = Rpc,
    ?assertMatch(
        {match, _},
        re:run(RpcBody, <<"no_such_realm">>, [{capture, all, binary}])
    ),

    %% The OAuth metadata document is still the 501 stub.
    ?assertMatch(
        {501, _},
        http_get(
            Port,
            "localhost",
            "/.well-known/oauth-protected-resource/realm/com.example.test"
        )
    ),

    %% And a path neither route claims is untouched by the carrier.
    ?assertMatch({404, _}, http_get(Port, "localhost", "/mcp")),

    %% `stop(normal)` mirrors the `start(normal)` above: it stops exactly the
    %% listeners this case declared. `stop(all)` also sweeps the early phase —
    %% the injected `admin`/`admin_local` — and ranch listeners are node-global
    %% by name, so on a shared `rebar3 ct` node where an earlier suite left
    %% bondy running it kills THAT node's admin listeners for every later
    %% suite (bondy_admin_listener_SUITE failed exactly this way).
    ok = bondy_listener_manager:stop(normal).

mcp_and_admin_api_do_not_boot_together(_Config) ->
    %% The manager-level spelling of the co-tenancy rule: the boot aborts
    %% naming both services, before any socket binds.
    ok = bondy_config:set(listeners, [
        {ct_mcp_admin, #{
            transport => tcp,
            protocol => http,
            port => 0,
            services => [mcp, admin_api]
        }}
    ]),
    ?assertError(
        {invalid_listener, ct_mcp_admin,
            {incompatible_services, mcp, admin_api}},
        bondy_listener_manager:init()
    ).

per_listener_mcp_option_reaches_route_state(_Config) ->
    %% The configured path end to end: an operator's `mcp.max_body_size`
    %% lands in the compiled dispatch table's route state through
    %% `bondy_config`, while every key the operator did not name carries the
    %% carrier default — total, so the handler reads with bare `maps:get/2`.
    ok = bondy_config:set(listeners, [
        {ct_mcp_opts, #{
            transport => tcp, protocol => http, port => 0, services => [mcp]
        }}
    ]),
    ok = bondy_config:set(ct_mcp_opts, [{mcp, [{max_body_size, 1024}]}]),
    ok = bondy_listener_manager:init(),
    ok = bondy_listener_manager:start(normal),

    States = mcp_route_states(ct_mcp_opts),
    ?assertEqual(2, length(States)),
    ?assertEqual(
        [oauth_metadata, rpc],
        lists:sort([maps:get(action, St) || St <- States]),
        "one handler for both paths, selected by the action in route state"
    ),
    Expected = maps:put(
        max_body_size, 1024, bondy_listener_config:carrier_defaults(mcp)
    ),
    _ = [?assertEqual(Expected, maps:get(config, St)) || St <- States],

    ok = bondy_listener_manager:stop(normal).

stub_answers_on_a_host_another_route_set_names(_Config) ->
    %% MCP's routes are contributed under `'_'`, and
    %% `bondy_http_services:dispatch/1` replicates them into each named host
    %% entry — without which they would be unreachable on any host another
    %% route set declares, since `cowboy_router:match/3` commits to the
    %% first host entry that matches and never falls through.
    ok = application:set_env(bondy_router, http_services, [
        {vhost, #{carrier => vhost, protocol => undefined}}
    ]),
    ok = application:set_env(bondy_router, http_carriers, [{vhost, ?MODULE}]),
    ok = bondy_config:set(listeners, [
        {ct_mcp_vhost, #{
            transport => tcp,
            protocol => http,
            port => 0,
            services => [mcp, vhost]
        }}
    ]),
    try
        ok = bondy_listener_manager:init(),
        ok = bondy_listener_manager:start(normal),
        Port = ranch:get_port(ct_mcp_vhost),

        %% The named host's own route answers there...
        ?assertMatch(
            {204, _}, http_get(Port, "api.example.com", "/only-here")
        ),
        %% ...and the MCP handler answers on that same named host (the
        %% `no_such_realm` 404 for the URL's realm binding is OUR
        %% handler's answer — see the stub case above).
        {404, VhostBody} = http_get(
            Port, "api.example.com", "/mcp/realm/com.example.test"
        ),
        ?assertMatch(
            {match, _},
            re:run(VhostBody, <<"no_such_realm">>, [{capture, all, binary}])
        ),

        ok = bondy_listener_manager:stop(normal)
    after
        ok = application:unset_env(bondy_router, http_services),
        ok = application:unset_env(bondy_router, http_carriers)
    end.

%% =============================================================================
%% bondy_http_service + cowboy handler DOUBLE
%% =============================================================================

routes(vhost, _Spec, _Listener) ->
    [{<<"api.example.com">>, [{"/only-here", ?MODULE, #{}}]}].

init(Req, State) ->
    {ok, cowboy_req:reply(204, Req), State}.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% The route states of the two MCP paths, read from the compiled dispatch
%% table the running listener serves from — the same `persistent_term` its
%% protocol options point Cowboy at, so this is the state a request would
%% reach the handler with.
mcp_route_states(Name) ->
    Dispatch = persistent_term:get({bondy_http_gateway, dispatch, Name}),
    [
        St
     || {_Host, _, Paths} <- Dispatch,
        {_Path, _, Module, St} <- Paths,
        Module =:= bondy_mcp_http_handler
    ].

%% A bare HTTP/1.1 GET with an explicit Host header, answering with the
%% status code and everything received until the server closes.
http_get(Port, Host, Path) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, [
        "GET ",
        Path,
        " HTTP/1.1\r\n",
        "Host: ",
        Host,
        "\r\n",
        "Connection: close\r\n\r\n"
    ]),
    Response = recv_all(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Response,
    {binary_to_integer(Code), Response}.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.
