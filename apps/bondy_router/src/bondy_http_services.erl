%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_services).

-moduledoc """
Route contributions for every carrier built into `bondy_router`.

One module rather than one per carrier: each contribution is a handful of route
rules, and keeping them together makes the whole HTTP surface of a listener
readable in one place.

`dispatch/1` assembles a listener's full table, grouped by virtual host. A
`{Host, Path}` claimed by two carriers raises
`{route_collision, Path, CarrierA, CarrierB}` when both route sets are static —
silently keeping the first would make the second carrier unreachable with no
diagnostic. Once either side comes from an API Gateway specification it is
operator data and is logged instead; see `on_collision/4`.

The route sets of the `api_gateway` and `admin_api` carriers are not written
here: they are compiled from API Gateway specifications, which can arrive by
anti-entropy at any time, so both clauses delegate to `bondy_http_gateway`.
Those are also the only carriers that can name a host other than `'_'`, because
a specification declares one.
""".

-behaviour(bondy_http_service).

-include_lib("kernel/include/logger.hrl").

-export([dispatch/1]).
-export([routes/3]).

-ifdef(TEST).
%% Both exposed because their behaviour cannot be reached through `dispatch/1`
%% without a booted node: the specification-derived carriers get their routes from
%% `bondy_http_gateway`, which loads stored specifications.
%%
%% `carrier_order/1` is not an implementation detail — it is what makes a static
%% route win over one from a specification, so it is pinned directly. Without
%% that, a change back to `lists:sort/1` would silently hand `/ws` to any
%% specification that asked for it.
-export([carrier_order/1]).
-export([merge_routes/3]).
-endif.

%% =============================================================================
%% API
%% =============================================================================

-doc """
Assembles the complete Cowboy dispatch table for `Listener`, grouped by host.

Carriers are asked in a stable order so the resulting table — and therefore the
`persistent_term` it is stored in — does not churn between boots. Which order,
and why it is not merely alphabetical, is in `carrier_order/1`.

Every route a carrier declares for `'_'` is also copied into each named host
entry, and the `'_'` entry is emitted last. Both follow from the same property of
`cowboy_router:match/3` — it commits to the first host entry that matches and
never falls through — and both are load-bearing rather than cosmetic; see
`with_wildcard_routes/1` and `by_host/1`.
""".
-spec dispatch(bondy_listener_config:t()) -> cowboy_router:routes().

dispatch(Listener) ->
    Carriers = maps:get(carriers, Listener),

    Claims = lists:foldl(
        fun(Carrier, Acc) ->
            #{module := Module} = Spec = maps:get(Carrier, Carriers),
            Contributed = Module:routes(Carrier, Spec, Listener),
            merge_routes(Contributed, Carrier, Acc)
        end,
        [],
        carrier_order(Carriers)
    ),

    by_host(with_wildcard_routes(lists:reverse(Claims))).

-doc "Route rules for a built-in carrier. See `bondy_http_service`.".
-spec routes(
    atom(), bondy_listener_config:carrier(), bondy_listener_config:t()
) ->
    [bondy_http_service:route_rule()].

routes(websocket, Spec, Listener) ->
    [
        {'_', [
            {"/ws", bondy_wamp_ws_connection_handler,
                carrier_state(Spec, Listener)}
        ]}
    ];
routes(sse, Spec, Listener) ->
    St = carrier_state(Spec, Listener),
    [
        {'_', [
            {"/wamp/sse/open", bondy_http_sse_handler, St#{action => open}},
            {"/wamp/sse/:transport_id/receive", bondy_http_sse_stream_handler,
                St},
            {"/wamp/sse/:transport_id/send", bondy_http_sse_handler, St#{
                action => send
            }},
            {"/wamp/sse/:transport_id/close", bondy_http_sse_handler, St#{
                action => close
            }}
        ]}
    ];
routes(longpoll, Spec, Listener) ->
    St = carrier_state(Spec, Listener),
    [
        {'_', [
            {"/wamp/longpoll/open", bondy_http_longpoll_handler, St#{
                action => open
            }},
            {"/wamp/longpoll/:transport_id/receive",
                bondy_http_longpoll_handler, St#{action => receive_msgs}},
            {"/wamp/longpoll/:transport_id/send", bondy_http_longpoll_handler,
                St#{action => send}},
            {"/wamp/longpoll/:transport_id/close", bondy_http_longpoll_handler,
                St#{action => close}}
        ]}
    ];
routes(admin, _Spec, _Listener) ->
    [
        {'_', [
            {"/ping", bondy_admin_ping_http_handler, #{}},
            {"/ready", bondy_admin_ready_http_handler, #{}},
            {"/cluster/topology", bondy_admin_cluster_topology_http_handler,
                #{}}
        ]}
    ];
routes(metrics, _Spec, _Listener) ->
    [{'_', [{"/metrics/[:registry]", prometheus_cowboy2_handler, []}]}];
%% The two specification-derived carriers. Both route sets come from the gateway
%% — `api_gateway`'s from the specifications stored in bondy_db, `admin_api`'s
%% from the built-in specification in `priv/` — and a listener that declares
%% neither service has neither carrier, so neither clause runs and nothing asks
%% the gateway for routes.
%%
%% They are two carriers rather than one because they differ by route SOURCE and
%% not by protocol: both declare `undefined` for protocol, so a shared carrier's
%% protocol union could not tell them apart and this function had to read
%% `services` to decide which of the two route sets to fetch.
%%
%% Both are backed by the durable store — `api_gateway` reads its
%% specifications from it, and compiling either table consults the realm
%% table to drop routes whose realm is absent — so on a degraded boot
%% (`main` failed to open; `bondy_namespace_catalog:main_status/0`) neither
%% can be built, and neither could serve a request if it were. The dispatch
%% is made HERE, once per carrier, rather than by catching
%% `*_table_unavailable` per route inside the compiler: the listener still
%% mounts every static carrier, so `/ping`, `/ready` and `/metrics` answer on
%% a degraded node. This is the same mode dispatch `bondy_app:start_services/1`
%% boots by. Exercised by `bondy_degraded_boot_SUITE`.
routes(api_gateway, _Spec, Listener) ->
    specification_routes(
        api_gateway, fun bondy_http_gateway:routes/1, Listener
    );
routes(admin_api, _Spec, Listener) ->
    specification_routes(
        admin_api, fun bondy_http_gateway:admin_api_routes/1, Listener
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
specification_routes(Carrier, Compile, Listener) ->
    case bondy_namespace_catalog:main_status() of
        failed ->
            ?LOG_WARNING(#{
                description =>
                    "Mounting no specification-derived routes on this "
                    "listener; the durable main database is not open. The "
                    "listener's static routes are unaffected.",
                carrier => Carrier,
                listener => maps:get(name, Listener),
                main_status => failed
            }),
            [];
        _ ->
            Compile(Listener)
    end.

%% @private
%% The handler receives its listener's name and resolved carrier configuration
%% in the route state, so it performs no configuration lookup per connection.
carrier_state(#{protocols := Protocols, config := Config}, Listener) ->
    #{
        listener => maps:get(name, Listener),
        protocols => lists:sort(Protocols),
        config => Config
    }.

%% @private
%% Carriers are asked in this order, and the FIRST claim on a `{Host, Path}`
%% wins — so this order is what decides who wins, and it is chosen rather than
%% incidental: static carriers first, specification-derived ones last, each
%% alphabetically.
%%
%% That makes "first claim wins" mean "a static route beats one from a
%% specification" structurally, with no precedence test in the collision path.
%% Plain `lists:sort/1` gets it backwards, because `api_gateway` sorts before
%% `websocket`: a stored specification claiming `/ws` would have taken it from
%% the WebSocket carrier.
%%
%% Deterministic, because the assembled table is stored in `persistent_term` and
%% order churn between boots would be noise.
carrier_order(Carriers) ->
    [
        Carrier
     || {_, Carrier} <- lists:sort([
            {spec_derived(C), C}
         || C <- maps:keys(Carriers)
        ])
    ].

%% @private
%% Accumulates one claim per `{Host, Path}`, newest first.
%%
%% Keyed on the host as well as the path because two specifications declaring one
%% path for two different virtual hosts are not in conflict at all — under a
%% path-only key the second was reported as colliding with the first.
merge_routes(Contributed, Carrier, Acc) ->
    lists:foldl(
        fun({Host, Paths}, Outer) ->
            lists:foldl(
                fun({Path, _, _} = Route, Inner) ->
                    claim({Host, Path}, Route, Carrier, Inner)
                end,
                Outer,
                Paths
            )
        end,
        Acc,
        Contributed
    ).

%% @private
claim(Key, Route, Carrier, Claims) ->
    case lists:keyfind(Key, 1, Claims) of
        false -> [{Key, Route, Carrier} | Claims];
        {Key, _, Other} -> on_collision(Key, Other, Carrier, Claims)
    end.

%% @private
%% A `{Host, Path}` claimed twice is one of two different mistakes.
%%
%% Between two STATIC route sets it is a code-level error: two in-tree carriers,
%% or an extension's carrier and an in-tree one, mounting the same path. Nothing
%% an operator does can produce or fix it, and keeping the first silently would
%% make the second carrier permanently unreachable — so it raises.
%%
%% As soon as EITHER side comes from an API Gateway specification it is operator
%% data, and raising is wrong: specifications arrive by anti-entropy after boot,
%% so it would abort a dispatch rebuild — or a listener start — on account of a
%% document some other node accepted. Logged instead, and the incumbent stands,
%% which by `carrier_order/1` is the static route whenever there is one.
%%
%% Returns the accumulator unchanged rather than appending the loser: Cowboy's
%% router answers with the first matching rule, so a second rule for one path
%% never ran.
on_collision({Host, Path}, Other, Carrier, Claims) ->
    case spec_derived(Other) orelse spec_derived(Carrier) of
        true ->
            ?LOG_WARNING(#{
                description =>
                    "Two route sets on this listener declare the same path "
                    "for the same host. The first one assembled answers it; "
                    "the other is unreachable here.",
                path => Path,
                host => Host,
                carrier => Carrier,
                claimed_by => Other
            }),
            Claims;
        false ->
            error({route_collision, Path, Other, Carrier})
    end.

%% @private
%% Copies every `'_'` route into each named host entry.
%%
%% `cowboy_router:match/3` walks host entries in order and commits to the first
%% one whose host matches: `match_path([], _, _, _)` answers
%% `{error, notfound, path}` rather than trying the next entry
%% (`cowboy_router.erl:253`, cowboy 2.17). So a route that lives only under `'_'`
%% is unreachable on any request whose Host header matches a named entry — which
%% would take `/ws`, `/ping` and `/metrics` off any host a specification names.
%%
%% A path the named host already claims is left alone: the operator declared that
%% path for that host specifically, so the more specific declaration stands. The
%% skip is logged, because it means one of Bondy's own endpoints is not answering
%% there.
with_wildcard_routes(Claims) ->
    Wildcard = [C || {{'_', _}, _, _} = C <- Claims],
    Named = lists:usort([H || {{H, _}, _, _} <- Claims, H =/= '_']),
    Claims ++ lists:append([replicate(H, Wildcard, Claims) || H <- Named]).

%% @private
replicate(Host, Wildcard, Claims) ->
    lists:filtermap(
        fun({{'_', Path}, Route, Carrier}) ->
            case lists:keyfind({Host, Path}, 1, Claims) of
                false ->
                    {true, {{Host, Path}, Route, Carrier}};
                {_, _, Owner} ->
                    ?LOG_WARNING(#{
                        description =>
                            "A route set declares a path for one host that a "
                            "listener-wide route set also declares. The "
                            "host-specific one answers it on that host.",
                        path => Path,
                        host => Host,
                        carrier => Owner,
                        shadowed => Carrier
                    }),
                    false
            end
        end,
        Wildcard
    ).

%% @private
%% Named hosts first, `'_'` LAST — `match/3`'s `'_'` clause matches
%% unconditionally (`cowboy_router.erl:225`), so a `'_'` entry placed first
%% shadows every named host entirely.
%%
%% The `'_'` entry is emitted even when it holds no route. A listener declaring
%% only `api_gateway` with no stored specification contributes nothing, and an
%% empty dispatch list would change its answer to an unmatched request from
%% `{error, notfound, path}` to `{error, notfound, host}`.
by_host(Claims) ->
    Named = lists:usort([H || {{H, _}, _, _} <- Claims, H =/= '_']),
    [
        {Host, [Route || {{H, _}, Route, _} <- Claims, H =:= Host]}
     || Host <- Named ++ ['_']
    ].

%% @private
%% The carriers whose route set comes from an API Gateway specification rather
%% than from this module. An extension's carrier is not one of them: its routes
%% are code, so a collision involving it is a code-level error.
spec_derived(api_gateway) -> true;
spec_derived(admin_api) -> true;
spec_derived(_) -> false.
