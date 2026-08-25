%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests that the route sets extracted out of `bondy_http_gateway` produce
%% exactly the paths the hardcoded `base_routes/0` and `admin_base_routes/0`
%% produced, and that a listener declaring fewer services mounts strictly
%% fewer paths — the property the old fixed route sets could not express.
%% =============================================================================
-module(bondy_http_services_test).

-include_lib("eunit/include/eunit.hrl").

-export([routes/3]).

listener(Services) ->
    {ok, [L]} = bondy_listener_config:resolve(
        [
            {test, #{
                transport => tcp,
                protocol => http,
                port => 18080,
                services => Services
            }}
        ],
        fun(_K, D) -> D end
    ),
    L.

paths(Listener) ->
    [{'_', Routes}] = bondy_http_services:dispatch(Listener),
    lists:sort([Path || {Path, _Mod, _St} <- Routes]).

full_public_service_set_matches_the_old_base_routes_test() ->
    %% These are the nine paths `bondy_http_gateway:base_routes/0` mounted
    %% unconditionally on every public listener.
    Expected = lists:sort([
        "/ws",
        "/wamp/sse/open",
        "/wamp/sse/:transport_id/receive",
        "/wamp/sse/:transport_id/send",
        "/wamp/sse/:transport_id/close",
        "/wamp/longpoll/open",
        "/wamp/longpoll/:transport_id/receive",
        "/wamp/longpoll/:transport_id/send",
        "/wamp/longpoll/:transport_id/close"
    ]),
    L = listener([wamp_ws, wamp_sse, wamp_longpoll]),
    ?assertEqual(Expected, paths(L)).

admin_service_set_matches_the_old_admin_base_routes_test() ->
    Expected = lists:sort([
        "/ws", "/ping", "/ready", "/cluster/topology", "/metrics/[:registry]"
    ]),
    L = listener([wamp_ws, admin, metrics]),
    ?assertEqual(Expected, paths(L)).

dropping_longpoll_drops_only_its_paths_test() ->
    L = listener([wamp_ws, wamp_sse]),
    Paths = paths(L),
    ?assert(lists:member("/ws", Paths)),
    ?assert(lists:member("/wamp/sse/open", Paths)),
    ?assertNot(lists:member("/wamp/longpoll/open", Paths)).

websocket_route_carries_the_listener_protocol_set_test() ->
    L = listener([bamp_ws]),
    [{'_', Routes}] = bondy_http_services:dispatch(L),
    {"/ws", bondy_wamp_ws_connection_handler, State} = lists:keyfind(
        "/ws", 1, Routes
    ),
    ?assertEqual(test, maps:get(listener, State)),
    ?assertEqual([bamp], maps:get(protocols, State)).

everything_compiles_through_cowboy_router_test() ->
    %% A dispatch table that cowboy_router cannot compile would fail at
    %% listener start, far from the cause.
    L = listener([wamp_ws, wamp_sse, wamp_longpoll, admin, metrics]),
    ?assertMatch(
        [_ | _], cowboy_router:compile(bondy_http_services:dispatch(L))
    ).

two_carriers_claiming_one_path_is_an_error_test() ->
    %% Two services on the SAME carrier union their protocols into one route;
    %% two DIFFERENT carriers claiming one path must raise. Keeping the first
    %% silently would make the second carrier unreachable with no diagnostic.
    %%
    %% No built-in carrier pair collides, so the collision is induced by
    %% registering an external service whose carrier mounts a path `admin`
    %% already owns — the same mechanism a third-party app would use.
    ok = application:set_env(bondy_router, http_services, [
        {clashing, #{carrier => clashing, protocol => undefined}}
    ]),
    ok = application:set_env(bondy_router, http_carriers, [{clashing, ?MODULE}]),
    try
        L = listener([admin, clashing]),
        ?assertError(
            {route_collision, "/ping", _, _}, bondy_http_services:dispatch(L)
        )
    after
        ok = application:unset_env(bondy_router, http_services),
        ok = application:unset_env(bondy_router, http_carriers)
    end.

sse_and_longpoll_routes_carry_the_right_handlers_test() ->
    %% `paths/1` deliberately discards the handler module, so path equality
    %% alone would stay green if `bondy_http_sse_handler` and
    %% `bondy_http_sse_stream_handler` were swapped, or if an `action` key were
    %% dropped. Assert the full tuple for the two carriers whose routes differ
    %% in handler and in state.
    L = listener([wamp_sse, wamp_longpoll]),
    [{'_', Routes}] = bondy_http_services:dispatch(L),
    Mod = fun(Path) ->
        {Path, M, _} = lists:keyfind(Path, 1, Routes),
        M
    end,
    ?assertEqual(bondy_http_sse_handler, Mod("/wamp/sse/open")),
    ?assertEqual(
        bondy_http_sse_stream_handler, Mod("/wamp/sse/:transport_id/receive")
    ),
    ?assertEqual(bondy_http_sse_handler, Mod("/wamp/sse/:transport_id/send")),
    ?assertEqual(bondy_http_longpoll_handler, Mod("/wamp/longpoll/open")),

    %% The `action` a handler dispatches on must survive route assembly.
    {_, _, OpenSt} = lists:keyfind("/wamp/longpoll/open", 1, Routes),
    ?assertEqual(open, maps:get(action, OpenSt)),
    {_, _, RecvSt} = lists:keyfind(
        "/wamp/longpoll/:transport_id/receive", 1, Routes
    ),
    ?assertEqual(receive_msgs, maps:get(action, RecvSt)).

route_order_is_deterministic_test() ->
    %% The assembled table is stored in `persistent_term`, so order churn
    %% between boots would be noise. `dispatch/1` sorts carrier keys and
    %% reverses once at the end; nothing else pins that, and `paths/1` sorts
    %% before comparing, so a change that stopped reversing would leave every
    %% other test green.
    L = listener([wamp_ws, wamp_sse, admin]),
    [{'_', Routes}] = bondy_http_services:dispatch(L),
    Order = [Path || {Path, _, _} <- Routes],
    ?assertEqual(
        Order,
        [
            Path
         || {Path, _, _} <- element(2, hd(bondy_http_services:dispatch(L)))
        ]
    ),
    %% Carriers are visited in sorted key order: admin, then sse, then
    %% websocket. Within a carrier, contributed routes keep the order
    %% `routes/3` lists them in — admin's is `["/ping", "/ready",
    %% "/cluster/topology"]` — so the FIRST path overall is admin's first,
    %% "/ping", not "/cluster/topology".
    ?assertEqual("/ping", hd(Order)),
    ?assertEqual("/ws", lists:last(Order)).

api_gateway_and_admin_api_do_not_share_a_carrier_test() ->
    %% `admin_api` and `api_gateway` both mount HTTP paths, but from different
    %% sources: `api_gateway` from storage, `admin_api` from `priv/`. Keeping
    %% them separate is what lets an operator offer stored specs without also
    %% offering realm, user, grant and backup administration.
    %%
    %% They used to share a `rest` carrier, and a carrier's protocol set is built
    %% from `service_spec/1`'s `protocol` field, which is `undefined` for both —
    %% so nothing about the carrier distinguished them and `routes/3` had to read
    %% `services` to decide which route set to fetch. One carrier each removes
    %% the question.
    #{carrier := Gateway} = bondy_listener_config:service_spec(api_gateway),
    #{carrier := Admin} = bondy_listener_config:service_spec(admin_api),
    ?assertEqual(api_gateway, Gateway),
    ?assertEqual(admin_api, Admin),
    ?assertNotEqual(Gateway, Admin).

a_listener_naming_no_rest_service_has_no_rest_carrier_test() ->
    %% The falsification of "no service, no route", now expressed one level up:
    %% the carrier is simply absent, so `dispatch/1` never calls the clause that
    %% would reach into stored-specification loading. That call needs a booted
    %% node, so a regression to an unconditional gateway lookup fails this case
    %% rather than returning `[]`.
    L = listener([wamp_ws]),
    Carriers = maps:get(carriers, L),
    ?assertNot(maps:is_key(api_gateway, Carriers)),
    ?assertNot(maps:is_key(admin_api, Carriers)),
    ?assertEqual(["/ws"], paths(L)).

service_spec_no_longer_carries_a_module_test() ->
    %% The normalisation itself. While `module` rode on the service there was a
    %% place to write a per-service value for a fact that depends on the carrier,
    %% and two services naming one carrier could disagree. This asserts the field
    %% is gone, so that state cannot be expressed at all.
    ?assertEqual(
        [carrier, protocol],
        lists:sort(maps:keys(bondy_listener_config:service_spec(wamp_ws)))
    ).

host_qualified_collision_policy_test() ->
    %% Collisions are keyed on {Host, Path}, and a collision RAISES only when
    %% neither side comes from an API Gateway specification.
    %%
    %% Specifications arrive by anti-entropy after boot, so raising over one
    %% would abort this node's dispatch rebuild on account of a document another
    %% node accepted. That applies to a specification colliding with a STATIC
    %% path just as much as with another specification: the `andalso` this
    %% replaced tolerated only the second case, so a stored specification
    %% declaring `/ws` or `/ping` took the rebuild down.
    Static = [{'_', [{"/ws", ws_handler, #{}}]}],
    Claims = bondy_http_services:merge_routes(Static, websocket, []),

    %% Specification vs static: tolerated, and the incumbent stands. Statics are
    %% assembled first (see `carrier_order/1`), so the incumbent is always the
    %% static one and Bondy's own endpoints cannot be taken over.
    ?assertEqual(
        Claims, bondy_http_services:merge_routes(Static, api_gateway, Claims)
    ),
    %% Specification vs specification: tolerated too.
    Spec1 = bondy_http_services:merge_routes(Static, api_gateway, []),
    ?assertEqual(
        Spec1, bondy_http_services:merge_routes(Static, admin_api, Spec1)
    ),
    %% Static vs static: still a raise. No operator action can produce it, and
    %% keeping the first silently would make the second carrier unreachable.
    ?assertError(
        {route_collision, "/ws", websocket, admin},
        bondy_http_services:merge_routes(Static, admin, Claims)
    ).

one_path_on_two_hosts_is_not_a_collision_test() ->
    %% The reason the key is {Host, Path} and not Path. Two specifications for
    %% different virtual hosts declaring the same path are not in conflict, and
    %% under a Path-only key the second was reported as colliding with the first.
    A = [{<<"a.example.com">>, [{"/orders", h, #{}}]}],
    B = [{<<"b.example.com">>, [{"/orders", h, #{}}]}],
    Claims = bondy_http_services:merge_routes(A, api_gateway, []),
    ?assertEqual(
        2,
        length(bondy_http_services:merge_routes(B, api_gateway, Claims))
    ).

static_carriers_are_assembled_before_specification_carriers_test() ->
    %% What makes "the first claim on a path wins" mean "a static route wins over
    %% one from a specification", with no precedence test in the collision path.
    %% Plain `lists:sort/1` gets it backwards: `api_gateway` sorts before
    %% `websocket`, so a stored specification claiming `/ws` would have taken it.
    Carriers = #{
        websocket => ignored,
        api_gateway => ignored,
        admin => ignored,
        admin_api => ignored,
        metrics => ignored,
        mcp => ignored
    },
    ?assertEqual(
        [admin, mcp, metrics, websocket, admin_api, api_gateway],
        bondy_http_services:carrier_order(Carriers)
    ).

%% A carrier living on a named virtual host, registered the way a third-party
%% application would. `api_gateway` cannot stand in for one here: its routes come
%% from `bondy_http_gateway`, which loads stored specifications and needs a booted
%% node.
with_vhost_carrier(Fun) ->
    ok = application:set_env(bondy_router, http_services, [
        {vhost, #{carrier => vhost, protocol => undefined}}
    ]),
    ok = application:set_env(bondy_router, http_carriers, [{vhost, ?MODULE}]),
    try
        Fun()
    after
        ok = application:unset_env(bondy_router, http_services),
        ok = application:unset_env(bondy_router, http_carriers)
    end.

a_named_host_keeps_its_own_paths_test() ->
    with_vhost_carrier(fun() ->
        Dispatch = bondy_http_services:dispatch(listener([admin, vhost])),
        {_, Named} = lists:keyfind(<<"api.example.com">>, 1, Dispatch),
        {_, Wildcard} = lists:keyfind('_', 1, Dispatch),
        ?assert(lists:keymember("/only-here", 1, Named)),
        %% NOT on every host: that is the whole point of declaring one.
        ?assertNot(lists:keymember("/only-here", 1, Wildcard))
    end).

wildcard_routes_are_replicated_into_every_named_host_test() ->
    %% `cowboy_router:match/3` commits to the first host entry that matches and
    %% never falls through — `match_path([], _, _, _)` answers
    %% `{error, notfound, path}` (`cowboy_router.erl:253`, cowboy 2.17). So a
    %% route that lives only under `'_'` is unreachable on any request whose Host
    %% header matches a named entry, and `/ping` would 404 on `api.example.com`.
    %%
    %% This is what the pre-branch code did NOT do: `dispatch_table/2` put base
    %% routes under their own `'_'` host, so the host field "worked" and left
    %% Bondy's own endpoints unreachable on any host that used it.
    with_vhost_carrier(fun() ->
        Dispatch = bondy_http_services:dispatch(listener([admin, vhost])),
        {_, Named} = lists:keyfind(<<"api.example.com">>, 1, Dispatch),
        ?assert(lists:keymember("/ping", 1, Named)),
        ?assert(lists:keymember("/ready", 1, Named)),
        ?assert(lists:keymember("/cluster/topology", 1, Named))
    end).

the_wildcard_host_is_emitted_last_test() ->
    %% Order is load-bearing, not cosmetic: `match/3`'s `'_'` clause matches
    %% unconditionally (`cowboy_router.erl:225`), so a `'_'` entry placed first
    %% shadows every named host entirely.
    with_vhost_carrier(fun() ->
        Dispatch = bondy_http_services:dispatch(listener([admin, vhost])),
        ?assertEqual('_', element(1, lists:last(Dispatch))),
        ?assertEqual(2, length(Dispatch))
    end).

the_wildcard_host_is_always_emitted_test() ->
    %% A listener whose only carrier contributes no route still gets a `'_'`
    %% entry. An empty dispatch list would change the answer to an unmatched
    %% request from `{error, notfound, path}` to `{error, notfound, host}`.
    L = listener([wamp_ws]),
    ?assertMatch([{'_', [_ | _]}], bondy_http_services:dispatch(L)).

%% Stands in for a third-party `bondy_http_service` implementation. Deliberately
%% mounts a path `admin` already owns.
routes(clashing, _Spec, _Listener) ->
    [{'_', [{"/ping", bondy_admin_ping_http_handler, #{}}]}];
routes(vhost, _Spec, _Listener) ->
    [
        {<<"api.example.com">>, [
            {"/only-here", bondy_admin_ping_http_handler, #{}}
        ]}
    ].

%% =============================================================================
%% MCP CARRIER
%% =============================================================================

mcp_service_mounts_its_two_paths_test() ->
    %% The `mcp' carrier's whole route surface: the JSON-RPC endpoint and the
    %% OAuth protected-resource metadata document, both under `'_'' so they
    %% answer on every virtual host the listener serves.
    Expected = lists:sort([
        "/mcp/realm/:realm",
        "/.well-known/oauth-protected-resource/realm/:realm"
    ]),
    ?assertEqual(Expected, paths(listener([mcp]))).

mcp_route_state_carries_the_resolved_carrier_config_test() ->
    %% One handler module for both paths, selected by `action' — and the
    %% listener's resolved `mcp' config rides in the route state, so the
    %% handler performs no configuration lookup per request.
    [{'_', Routes}] = bondy_http_services:dispatch(listener([mcp])),
    States =
        #{
            Path => {Mod, St}
         || {Path, Mod, St} <- Routes
        },
    {bondy_mcp_http_handler, Rpc} = maps:get("/mcp/realm/:realm", States),
    {bondy_mcp_http_handler, Meta} = maps:get(
        "/.well-known/oauth-protected-resource/realm/:realm", States
    ),
    ?assertEqual(rpc, maps:get(action, Rpc)),
    ?assertEqual(oauth_metadata, maps:get(action, Meta)),
    ?assertEqual(test, maps:get(listener, Rpc)),
    ?assertEqual(
        bondy_listener_config:carrier_defaults(mcp), maps:get(config, Rpc)
    ).

a_specification_cannot_take_the_mcp_paths_test() ->
    %% A stored API Gateway specification claiming `/mcp/realm/:realm' is
    %% operator data arriving by anti-entropy, so it is tolerated and LOGGED,
    %% never raised — and it loses: statics are assembled first
    %% (`carrier_order/1'), so the incumbent is the MCP route and the
    %% specification's own route is unreachable on that listener.
    L = listener([mcp]),
    Spec = maps:get(mcp, maps:get(carriers, L)),
    Contributed = bondy_mcp_http_service:routes(mcp, Spec, L),
    Claims = bondy_http_services:merge_routes(Contributed, mcp, []),
    ?assertEqual(
        Claims,
        bondy_http_services:merge_routes(
            [{'_', [{"/mcp/realm/:realm", spec_handler, #{}}]}],
            api_gateway,
            Claims
        )
    ).
