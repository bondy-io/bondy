%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests `bondy_listener_config:resolve/2`, the pure boot-time validation of
%% the `bondy_router.listeners` inventory. Most cases here are written to
%% BREAK an invariant rather than confirm it: each asserts that a specific
%% malformed listener is REJECTED, because the resolver exists so that a static
%% config error is reported rather than papered over with a default. Three
%% cases are deliberately confirmatory — the minimal-listener defaults, the
%% accepted half of the uds bind rule, and the port-0 exemption — because each
%% pins behaviour a rejection test cannot express.
%% =============================================================================
-module(bondy_listener_config_test).

-include_lib("eunit/include/eunit.hrl").

%% A GetFun that knows nothing: every option block is empty. Used by the
%% required-key cases, where the inventory entry alone decides the outcome.
empty_get() ->
    fun(_Key, Default) -> Default end.

minimal_http_listener_resolves_test() ->
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual(pub, maps:get(name, L)),
    ?assertEqual(tcp, maps:get(transport, L)),
    ?assertEqual(http, maps:get(protocol, L)),
    ?assertEqual({port, 18080}, maps:get(bind, L)),
    %% Absent `enabled` means enabled: five call sites read
    %% `bondy_config:get([Ref, enabled], true)` today.
    ?assertEqual(true, maps:get(enabled, L)),
    ?assertEqual(normal, maps:get(start_phase, L)).

missing_transport_is_rejected_test() ->
    Inventory = [
        {pub, #{protocol => http, port => 18080, services => [wamp_ws]}}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, {missing, transport}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

missing_protocol_is_rejected_test() ->
    Inventory = [{pub, #{transport => tcp, port => 18080}}],
    ?assertMatch(
        {error, {invalid_listener, pub, {missing, protocol}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

missing_port_is_rejected_test() ->
    %% A mistyped listener NAME shows up here: the intended block loses its
    %% port, so boot fails naming the listener rather than silently binding a
    %% phantom one.
    Inventory = [
        {pub, #{transport => tcp, protocol => http, services => [wamp_ws]}}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, {missing, port}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

uds_requires_path_not_port_test() ->
    Ok = [
        {local, #{
            transport => uds,
            protocol => wamp_rawsocket,
            path => "/tmp/bondy_wamp.sock"
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Ok, empty_get()),
    ?assertEqual({path, "/tmp/bondy_wamp.sock"}, maps:get(bind, L)),

    Bad = [{local, #{transport => uds, protocol => wamp_rawsocket}}],
    ?assertMatch(
        {error, {invalid_listener, local, {missing, path}}},
        bondy_listener_config:resolve(Bad, empty_get())
    ).

http_requires_services_test() ->
    Inventory = [{pub, #{transport => tcp, protocol => http, port => 18080}}],
    ?assertMatch(
        {error, {invalid_listener, pub, {missing, services}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

services_on_non_http_is_rejected_test() ->
    %% RawSocket's whole demux surface is a fixed 4-octet header, so a service
    %% LIST is meaningless there. Accepting it silently would mislead.
    Inventory = [
        {raw, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => 18082,
            services => [wamp_ws]
        }}
    ],
    ?assertMatch(
        {error,
            {invalid_listener, raw, {services_not_supported, wamp_rawsocket}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

unknown_transport_is_rejected_test() ->
    Inventory = [{pub, #{transport => sctp, protocol => http, port => 1}}],
    ?assertMatch(
        {error, {invalid_listener, pub, {unknown_transport, sctp}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

unknown_protocol_is_rejected_test() ->
    Inventory = [{pub, #{transport => tcp, protocol => gopher, port => 1}}],
    ?assertMatch(
        {error, {invalid_listener, pub, {unknown_protocol, gopher}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

duplicate_name_is_rejected_test() ->
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }},
        {pub, #{
            transport => tcp, protocol => http, port => 2, services => [wamp_ws]
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, duplicate_name}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

duplicate_port_is_rejected_test() ->
    Inventory = [
        {a, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws]
        }},
        {b, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws]
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, b, {port_in_use_by, a}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

port_zero_never_clashes_test() ->
    %% Port 0 means "let the OS choose", so two such listeners cannot collide.
    %% Rejecting them would make it impossible to define more than one
    %% ephemeral-port listener, which every CT suite needs.
    Inventory = [
        {a, #{
            transport => tcp, protocol => http, port => 0, services => [wamp_ws]
        }},
        {b, #{
            transport => tcp, protocol => http, port => 0, services => [wamp_ws]
        }}
    ],
    ?assertMatch(
        {ok, [_, _]}, bondy_listener_config:resolve(Inventory, empty_get())
    ).

%% A raw-socket listener spec on `Port`, plus whatever address key the case
%% needs. Raw-socket rather than http so the spec needs no `services`.
on_port(Port, Extra) ->
    maps:merge(
        #{transport => tcp, protocol => wamp_rawsocket, port => Port}, Extra
    ).

distinct_addresses_may_share_a_port_test() ->
    %% The OS's uniqueness domain for a stream socket is (address, port) and not
    %% port: `bondy_listener_SUITE:one_port_two_addresses` binds this exact pair
    %% for real. Comparing the port alone refused a configuration the OS
    %% accepts, which is the per-tenant-TLS case the design names as motivation.
    Inventory = [
        {a, on_port(18099, #{ip => {127, 0, 0, 1}})},
        {b, on_port(18099, #{ip => {0, 0, 0, 0, 0, 0, 0, 1}})}
    ],
    ?assertMatch(
        {ok, [_, _]}, bondy_listener_config:resolve(Inventory, empty_get())
    ).

a_wildcard_conflicts_with_every_address_on_its_port_test() ->
    %% Both orders, because the wildcard may be either the incumbent or the
    %% newcomer and a comparison that widened only one side would pass one case
    %% and fail the other.
    Narrow = on_port(18099, #{ip => {127, 0, 0, 1}}),
    Wide = on_port(18099, #{}),
    ?assertMatch(
        {error, {invalid_listener, b, {port_in_use_by, a}}},
        bondy_listener_config:resolve([{a, Wide}, {b, Narrow}], empty_get())
    ),
    ?assertMatch(
        {error, {invalid_listener, b, {port_in_use_by, a}}},
        bondy_listener_config:resolve([{a, Narrow}, {b, Wide}], empty_get())
    ).

an_explicit_wildcard_address_conflicts_like_an_absent_one_test() ->
    %% `resolve_ip/3` leaves `ip` absent when none was configured, and
    %% `bondy_config:normalise_socket_opts/1` binds that to the wildcard of the
    %% configured family. An absent address and a written-out `0.0.0.0` are
    %% therefore the same socket, so they must get the same verdict.
    ?assertMatch(
        {error, {invalid_listener, b, {port_in_use_by, a}}},
        bondy_listener_config:resolve(
            [
                {a, on_port(18099, #{ip => {0, 0, 0, 0}})},
                {b, on_port(18099, #{ip => {127, 0, 0, 1}})}
            ],
            empty_get()
        )
    ).

a_path_clash_ignores_the_address_test() ->
    %% A uds socket node has no address, so an `ip` on either listener says
    %% nothing about whether the two collide. Written with two DIFFERENT
    %% addresses because that is precisely what an address-aware comparison
    %% applied to every bind kind would let through, and
    %% `duplicate_path_is_rejected_test` says why a path clash cannot be left to
    %% bind time.
    Path = "/tmp/bondy_ct_dup_addr.sock",
    Inventory = [
        {a, #{
            transport => uds,
            protocol => wamp_rawsocket,
            path => Path,
            ip => {127, 0, 0, 1}
        }},
        {b, #{
            transport => uds,
            protocol => wamp_rawsocket,
            path => Path,
            ip => {0, 0, 0, 0, 0, 0, 0, 1}
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, b, {path_in_use_by, a}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

%% A GetFun that answers a fixed set of option paths and defaults the rest.
%% Mirrors `bondy_config:get/2`'s contract: the path is a list of atoms.
get_with(Paths) ->
    fun(Key, Default) ->
        case lists:keyfind(Key, 1, Paths) of
            {Key, Value} -> Value;
            false -> Default
        end
    end.

tcp_listener_gets_ranch_driver_test() ->
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual(bondy_listener_ranch, maps:get(driver, L)).

tls_keys_on_plain_tcp_are_rejected_test() ->
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([{[pub, tls, certfile], "/tmp/cert.pem"}]),
    ?assertMatch(
        {error, {invalid_listener, pub, {tls_not_supported, tcp}}},
        bondy_listener_config:resolve(Inventory, Get)
    ),

    %% Every key of the `tls` block, not only the two a TLS listener requires:
    %% `verify` alone on a plaintext listener is the same misconception, and
    %% `assert_tls_keys/4` scans `?TLS_KEYS` rather than `?TLS_REQUIRED_KEYS`
    %% for exactly this case.
    VerifyOnly = get_with([{[pub, tls, verify], verify_peer}]),
    ?assertMatch(
        {error, {invalid_listener, pub, {tls_not_supported, tcp}}},
        bondy_listener_config:resolve(Inventory, VerifyOnly)
    ),
    VersionsOnly = get_with([{[pub, tls, versions], ['tlsv1.3']}]),
    ?assertMatch(
        {error, {invalid_listener, pub, {tls_not_supported, tcp}}},
        bondy_listener_config:resolve(Inventory, VersionsOnly)
    ).

disabling_a_listener_defers_the_tls_check_it_does_not_lose_it_test() ->
    %% ONE spec, resolved twice, differing only in `enabled`. Written this way
    %% because the risk in skipping a check is that it is skipped for good: the
    %% second assertion is what shows the check still exists and runs at the boot
    %% that enables the listener.
    Spec = #{
        transport => tls, protocol => http, port => 1, services => [wamp_ws]
    },

    Disabled = [{sec, Spec#{enabled => false}}],
    ?assertMatch(
        {ok, [#{name := sec, enabled := false}]},
        bondy_listener_config:resolve(Disabled, empty_get())
    ),

    Enabled = [{sec, Spec#{enabled => true}}],
    ?assertMatch(
        {error, {invalid_listener, sec, {missing, [tls, certfile]}}},
        bondy_listener_config:resolve(Enabled, empty_get())
    ),

    %% The reason the guard had to exist: `resolve/2` fails the whole inventory on
    %% the first bad entry, so before it, ONE disabled certificate-less listener
    %% stopped two healthy ones from starting -- it took the node down, not itself.
    Mixed = [
        {pub, #{
            transport => tcp, protocol => http, port => 2, services => [wamp_ws]
        }},
        {sec, Spec#{enabled => false}}
    ],
    ?assertMatch(
        {ok, [#{name := pub}, #{name := sec}]},
        bondy_listener_config:resolve(Mixed, empty_get())
    ).

disabled_listener_is_not_checked_for_tls_keys_on_a_plain_transport_test() ->
    %% The symmetric consequence, pinned so a reader knows it is intended rather
    %% than an oversight: a DISABLED plaintext listener carrying TLS material
    %% resolves. The misconception it guards against -- a port the operator
    %% believes is encrypted -- cannot be acted on while the listener does not
    %% start, and enabling it runs the check (asserted below).
    Spec = #{
        transport => tcp, protocol => http, port => 1, services => [wamp_ws]
    },
    Get = get_with([{[pub, tls, certfile], "/tmp/cert.pem"}]),

    ?assertMatch(
        {ok, [#{name := pub, enabled := false}]},
        bondy_listener_config:resolve([{pub, Spec#{enabled => false}}], Get)
    ),
    ?assertMatch(
        {error, {invalid_listener, pub, {tls_not_supported, tcp}}},
        bondy_listener_config:resolve([{pub, Spec#{enabled => true}}], Get)
    ).

tls_transport_requires_cert_and_key_test() ->
    %% No `enabled` key: absent means enabled, so this is the checked case.
    Inventory = [
        {sec, #{
            transport => tls, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, sec, {missing, [tls, certfile]}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ),
    OnlyCert = get_with([{[sec, tls, certfile], "/tmp/cert.pem"}]),
    ?assertMatch(
        {error, {invalid_listener, sec, {missing, [tls, keyfile]}}},
        bondy_listener_config:resolve(Inventory, OnlyCert)
    ),
    Both = get_with([
        {[sec, tls, certfile], "/tmp/cert.pem"},
        {[sec, tls, keyfile], "/tmp/key.pem"}
    ]),
    ?assertMatch({ok, [_]}, bondy_listener_config:resolve(Inventory, Both)).

default_inventory_resolves_with_no_configuration_test() ->
    %% The case every `prod`, `prod_named` and `docker` node is in: those
    %% releases overlay no `bondy.conf` at all, so this inventory resolves
    %% against nothing. It must succeed, or those nodes cannot boot.
    %%
    %% `get_with([])` supplies NO certificate material, which is the point of the
    %% test rather than an omission: `assert_tls_keys/3` has no `enabled` guard,
    %% so a single TLS entry in the default inventory would fail here — and would
    %% fail on every node that never asked for TLS. The assertion below is what
    %% keeps one from being added back.
    {ok, Listeners} = bondy_listener_config:resolve(
        bondy_listener_config:default_inventory(), get_with([])
    ),
    ?assertEqual(3, length(Listeners)),
    ?assertEqual(
        [admin, api_gateway_http, wamp_tcp],
        lists:sort([N || #{name := N} <- Listeners])
    ),
    %% All three enabled: a default node binds all of what it declares.
    ?assertEqual(
        [admin, api_gateway_http, wamp_tcp],
        lists:sort([N || #{name := N, enabled := true} <- Listeners])
    ),
    %% None is TLS.
    ?assertEqual(
        [], [N || #{name := N, transport := tls} <- Listeners]
    ),
    %% The admin listener carries the reserved name, which is what makes
    %% `bondy_listener_manager:with_reserved/1` a no-op over this inventory
    %% rather than a second listener on 18081.
    ?assert(
        lists:keymember(admin, 1, bondy_listener_config:default_inventory())
    ).

uds_rejects_tls_test() ->
    Inventory = [
        {local, #{
            transport => uds, protocol => wamp_rawsocket, path => "/tmp/s.sock"
        }}
    ],
    Get = get_with([{[local, tls, certfile], "/tmp/cert.pem"}]),
    ?assertMatch(
        {error, {invalid_listener, local, {tls_not_supported, uds}}},
        bondy_listener_config:resolve(Inventory, Get)
    ).

uds_bridge_relay_is_refused_test() ->
    %% A bridge relay is a connection between two Bondy nodes, not something a
    %% Unix domain socket can serve. `transport` and `protocol` validate
    %% independently above this check, so each half of this combination
    %% passes on its own; without the check the listener binds and only fails
    %% later, on its first connection, inside
    %% `inet_utils:peername_to_binary/1`, which has no clause for the raw
    %% `{local, <<>>}` peername `bondy_bridge_relay_server:peername/2` stores.
    Inventory = [
        {relay, #{
            transport => uds,
            protocol => bridge_relay,
            path => "/tmp/bondy_ct_uds_relay.sock"
        }}
    ],
    ?assertMatch(
        {error,
            {invalid_listener, relay,
                {unsupported_combination, uds, bridge_relay}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

uds_http_is_still_valid_test() ->
    %% `admin_local`: the co-located Admin API bound to a Unix domain socket.
    %% The cross-check added for `uds_bridge_relay_is_refused_test` must not
    %% widen beyond the one unsupported combination.
    Inventory = [
        {local_http, #{
            transport => uds,
            protocol => http,
            path => "/tmp/bondy_ct_uds_http.sock",
            services => [admin_api, admin]
        }}
    ],
    ?assertMatch(
        {ok, [_]}, bondy_listener_config:resolve(Inventory, empty_get())
    ).

uds_wamp_rawsocket_is_still_valid_test() ->
    %% `wamp_uds`: the pre-existing WAMP raw-socket listener over a Unix
    %% domain socket.
    Inventory = [
        {local_wamp, #{
            transport => uds,
            protocol => wamp_rawsocket,
            path => "/tmp/bondy_ct_uds_wamp.sock"
        }}
    ],
    ?assertMatch(
        {ok, [_]}, bondy_listener_config:resolve(Inventory, empty_get())
    ).

websocket_carrier_is_grouped_from_services_test() ->
    %% Two services on one carrier must UNION their protocols into a single
    %% carrier entry: both mount `/ws`, and two routes on one path would make
    %% the second unreachable.
    Inventory = [
        {mix, #{
            transport => tcp,
            protocol => http,
            port => 1,
            services => [wamp_ws, bamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    #{websocket := #{protocols := Protos}} = maps:get(carriers, L),
    ?assertEqual([bamp, wamp], lists:sort(Protos)).

restricting_a_carrier_to_one_protocol_test() ->
    %% The operator requirement: offer BAMP over WebSocket WITHOUT offering
    %% WAMP on the same port.
    Inventory = [
        {bamp, #{
            transport => tcp, protocol => http, port => 1, services => [bamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    #{websocket := #{protocols := Protos}} = maps:get(carriers, L),
    ?assertEqual([bamp], Protos).

unknown_service_is_rejected_test() ->
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 1,
            services => [wamp_ws, smtp]
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, {unknown_service, smtp}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

carrier_config_falls_back_to_global_test() ->
    %% A listener that sets NOTHING must receive the global value. This is the
    %% regression guard for the default-free rule: if anyone gives
    %% `listeners.$name.websocket.idle_timeout` a cuttlefish default, the key
    %% becomes always-present for every listener and this fallback dies
    %% silently.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([{[wamp_websocket, idle_timeout], 90000}]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(90000, maps:get(idle_timeout, Cfg)).

per_listener_carrier_value_beats_global_test() ->
    Inventory = [
        {iot, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([
        {[wamp_websocket, idle_timeout], 90000},
        {[iot, websocket, idle_timeout], 600000}
    ]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(600000, maps:get(idle_timeout, Cfg)).

sse_carrier_config_falls_back_to_global_test() ->
    %% The same fallback as `carrier_config_falls_back_to_global_test', for
    %% the carrier `bondy_http_sse_stream_handler' reads. The resolver code
    %% path is carrier-generic, but this is the connection between that and
    %% the actual global namespace (`wamp_sse') the SSE carrier falls back
    %% to — a wrong `carrier_global/1' entry would pass the websocket case
    %% and fail only here.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 1,
            services => [wamp_sse]
        }}
    ],
    Get = get_with([{[wamp_sse, idle_timeout], 90000}]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{sse := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(90000, maps:get(idle_timeout, Cfg)).

longpoll_carrier_config_falls_back_to_global_test() ->
    %% Same property, for the carrier `bondy_http_longpoll_handler' reads,
    %% falling back to `wamp_longpoll'.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 1,
            services => [wamp_longpoll]
        }}
    ],
    Get = get_with([{[wamp_longpoll, poll_timeout], 45000}]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{longpoll := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(45000, maps:get(poll_timeout, Cfg)).

nested_carrier_key_resolves_test() ->
    %% Carrier settings are not flat: `ping.enabled' and `deflate_opts.level'
    %% are nested under the carrier block, and the resolved config must mirror
    %% that shape. A flat implementation would silently drop every nested key —
    %% 11 of WebSocket's 15 overridable settings.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    %% `ping.enabled = true' requires its three siblings to be resolvable too
    %% (`assert_ping_complete/3'), so they are set here even though this case
    %% is not about ping completeness — see
    %% `partial_ping_with_enabled_true_is_rejected_test' for that property.
    Get = get_with([
        {[wamp_websocket, ping, enabled], true},
        {[wamp_websocket, ping, idle_timeout], 20000},
        {[wamp_websocket, ping, timeout], 10000},
        {[wamp_websocket, ping, max_attempts], 2},
        {[pub, websocket, deflate_opts, level], 9}
    ]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(true, maps:get(enabled, maps:get(ping, Cfg))),
    ?assertEqual(9, maps:get(level, maps:get(deflate_opts, Cfg))).

partial_ping_with_enabled_true_is_rejected_test() ->
    %% The structural guard for the ping subsystem: `ping.enabled' resolves
    %% independently of its siblings (`idle_timeout', `timeout',
    %% `max_attempts'), so an operator — or a global block missing a key —
    %% can produce `enabled => true' with a sibling absent. The connection
    %% handler reads every sibling with no default once `enabled' is true, so
    %% this must abort boot rather than reach a live connection.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([
        {[wamp_websocket, ping, enabled], true},
        {[wamp_websocket, ping, idle_timeout], 20000}
        %% `timeout' and `max_attempts' deliberately left unresolved.
    ]),
    ?assertMatch(
        {error,
            {invalid_listener, pub,
                {incomplete_ping, websocket, [max_attempts, timeout]}}},
        bondy_listener_config:resolve(Inventory, Get)
    ).

partial_ping_with_enabled_absent_is_accepted_test() ->
    %% A `ping' map with siblings but no `enabled' is a WORKING configuration:
    %% every `maybe_enable_ping/2' falls through to "ping off" when `enabled' is
    %% absent (pinned by `ping_off_is_the_handler_fall_through_test'), so there
    %% is no crash to prevent and rejecting it would refuse a node that runs.
    %% This used to be an error, which was a guard for a missing clause rather
    %% than for a real defect.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([{[wamp_websocket, ping, idle_timeout], 20000}]),
    ?assertMatch(
        {ok, [#{name := pub}]},
        bondy_listener_config:resolve(Inventory, Get)
    ).

ping_off_is_the_handler_fall_through_test() ->
    %% The premise `assert_ping_keys/4' now rests on, tested against the three
    %% handlers themselves rather than assumed: a `ping' map WITHOUT `enabled'
    %% means ping off, and is a no-op on the state. Before the fall-through
    %% clause each of these raised `function_clause' on the first connection —
    %% after the socket was accepted, so the listener bound and then died.
    %%
    %% `State' is opaque here on purpose: the clause under test returns it
    %% untouched, so it never has to be a real record.
    Partial = #{idle_timeout => 20000, timeout => 10000, max_attempts => 2},
    Sentinel = {state_untouched, make_ref()},
    lists:foreach(
        fun(Mod) ->
            ?assertEqual(
                Sentinel,
                Mod:maybe_enable_ping(Partial, Sentinel),
                atom_to_list(Mod) ++ " must treat an absent `enabled' as off"
            ),
            %% An explicit `false' keeps behaving the same way.
            ?assertEqual(
                Sentinel,
                Mod:maybe_enable_ping(#{enabled => false}, Sentinel)
            ),
            %% ...but a PRESENT non-boolean is not silently "off": ping is the
            %% mechanism for noticing a dead peer, so running without it because
            %% a value was misspelled is the one outcome worth crashing over.
            %% This is what separates the fall-through from a blanket catch-all.
            ?assertError(
                {invalid_ping_enabled, <<"on">>},
                Mod:maybe_enable_ping(
                    Partial#{enabled => <<"on">>}, Sentinel
                )
            )
        end,
        [
            bondy_wamp_tcp_connection_handler,
            bondy_wamp_ws_connection_handler,
            bondy_bridge_relay_server
        ]
    ).

malformed_ping_enabled_is_rejected_at_boot_test() ->
    %% The handler refuses a non-boolean `enabled', but only once a connection
    %% arrives — by then the listener has bound and every client dies on it. Any
    %% inventory that resolves is checked here first, so the operator gets the
    %% same boot-time error as for any other bad listener key, and the handler
    %% clause is left as the backstop for callers that never resolve.
    Raw = [
        {raw, #{transport => tcp, protocol => wamp_rawsocket, port => 18082}}
    ],
    Bad = get_with([{[raw, ping], [{enabled, 1}, {timeout, 10000}]}]),
    ?assertMatch(
        {error, {invalid_listener, raw, {invalid_ping_enabled, listener, 1}}},
        bondy_listener_config:resolve(Raw, Bad)
    ),
    %% Same for a carrier, whose ping block is assembled key-by-key.
    Ws = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    BadWs = get_with([{[wamp_websocket, ping, enabled], <<"yes">>}]),
    ?assertMatch(
        {error,
            {invalid_listener, pub,
                {invalid_ping_enabled, websocket, <<"yes">>}}},
        bondy_listener_config:resolve(Ws, BadWs)
    ).

ping_enabled_false_needs_no_siblings_test() ->
    %% The other half of `assert_ping_complete/3': `enabled => false' is a
    %% complete configuration on its own, because no handler reads a sibling
    %% once ping is off. Written to break the guard from the other side: a
    %% version that required every sibling unconditionally would reject this.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([{[wamp_websocket, ping, enabled], false}]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(false, maps:get(enabled, maps:get(ping, Cfg))).

carrier_key_set_nowhere_is_absent_test() ->
    %% Neither listener nor global set anything, so the resolved config is
    %% EMPTY rather than populated with values invented in this module. The
    %% schema owns defaults; a value fabricated here would silently override
    %% the handler's own default.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(#{}, Cfg).

websocket_dynamic_buffer_is_not_overridable_test() ->
    %% `wamp.websocket.buffer.{min,max}' cannot take effect: since Cowboy 2.13 a
    %% WebSocket inherits the listener's dynamic_buffer and cowboy_websocket
    %% overrides any handler-supplied value. Offering it per listener would be a
    %% knob that does nothing, so it must NOT appear in the resolved config even
    %% when an operator sets it.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([
        {[pub, websocket, protocol_opts, dynamic_buffer, min], 1024}
    ]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertNot(maps:is_key(protocol_opts, Cfg)).

admin_listener_defaults_to_loopback_test() ->
    %% Today's admin listeners default their bind address to loopback (schema
    %% comment "D-1: default to loopback"). That default moves here.
    Inventory = [
        {admin, #{
            transport => tcp,
            protocol => http,
            port => 18081,
            services => [admin, metrics]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual({127, 0, 0, 1}, maps:get(ip, L)).

absent_ip_stays_absent_test() ->
    %% A listener that configured no address and exposes neither `admin` nor
    %% `metrics` must carry NO `ip` key, not a v4 wildcard. Written to break the
    %% claim that a defaulted address is harmless: the resolved `ip` is written
    %% into ranch's `socket_opts`, and a v4 wildcard there contradicts the
    %% `inet6` family `bondy_config:normalise_socket_opts/1` derives from
    %% `ip_version = 6`, which `gen_tcp:listen/2` answers with `badarg`.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertNot(maps:is_key(ip, L)).

partial_listener_ping_is_rejected_test() ->
    %% The listener's own `ping` block, distinct from a carrier's. Every
    %% `listeners.$name.ping.*` mapping is default-free and resolves
    %% independently, so an operator can write `ping.timeout` and no
    %% `ping.enabled`. Only an ENABLED block is incomplete-able:
    %% `bondy_wamp_tcp_connection_handler:maybe_enable_ping/2` reads
    %% `idle_timeout`, `timeout` and `max_attempts` with `maps:get/2` once
    %% enabled, so a gap there kills the first connection instead of failing the
    %% boot.
    Inventory = [
        {raw, #{transport => tcp, protocol => wamp_rawsocket, port => 18082}}
    ],
    %% No `enabled` at all is ping OFF, not an error — the handler falls
    %% through (`ping_off_is_the_handler_fall_through_test`).
    NoEnabled = get_with([{[raw, ping], [{timeout, 10000}]}]),
    ?assertMatch(
        {ok, [#{name := raw}]},
        bondy_listener_config:resolve(Inventory, NoEnabled)
    ),
    NoSiblings = get_with([{[raw, ping], [{enabled, true}]}]),
    ?assertMatch(
        {error,
            {invalid_listener, raw,
                {incomplete_ping, listener, [
                    idle_timeout, timeout, max_attempts
                ]}}},
        bondy_listener_config:resolve(Inventory, NoSiblings)
    ),
    %% `enabled => false` is complete on its own: no handler reads a sibling
    %% once ping is off.
    Off = get_with([{[raw, ping], [{enabled, false}]}]),
    ?assertMatch({ok, [_]}, bondy_listener_config:resolve(Inventory, Off)).

stream_listener_ping_siblings_are_the_same_for_both_protocols_test() ->
    %% Both halves of the sibling list, one protocol each, because the list is
    %% now shared and a per-protocol list is what it replaced.
    %%
    %% A raw-socket block naming `interval` instead of `idle_timeout` — the
    %% shape the deleted `wamp.tls.ping.interval` mapping produced — is REJECTED.
    %% It used to be accepted, on the premise that
    %% `bondy_wamp_tcp_connection_handler:maybe_enable_ping/2` never read a ping
    %% idle period and took its interval from the listener's own `idle_timeout`.
    %% That is no longer true, and a listener carrying `interval` would enable
    %% ping and then crash on `maps:get(idle_timeout, PingOpts)`.
    Inventory = [
        {wamp_tls, #{
            transport => tcp, protocol => wamp_rawsocket, port => 18085
        }}
    ],
    Interval = get_with([
        {[wamp_tls, ping], [
            {enabled, true},
            {interval, 30000},
            {timeout, 10000},
            {max_attempts, 3}
        ]}
    ]),
    ?assertMatch(
        {error,
            {invalid_listener, wamp_tls,
                {incomplete_ping, listener, [idle_timeout]}}},
        bondy_listener_config:resolve(Inventory, Interval)
    ),
    %% The accepting side: the same block with the key the handler actually
    %% reads.
    Complete = get_with([
        {[wamp_tls, ping], [
            {enabled, true},
            {idle_timeout, 20000},
            {timeout, 10000},
            {max_attempts, 2}
        ]}
    ]),
    ?assertMatch({ok, [_]}, bondy_listener_config:resolve(Inventory, Complete)),
    %% `bondy_bridge_relay_server:maybe_enable_ping/2` has always read
    %% `ping.idle_timeout`, so the same omission was always an error there.
    Relay = [
        {relay, #{transport => tcp, protocol => bridge_relay, port => 18092}}
    ],
    Missing = get_with([
        {[relay, ping], [
            {enabled, true}, {timeout, 10000}, {max_attempts, 2}
        ]}
    ]),
    ?assertMatch(
        {error,
            {invalid_listener, relay,
                {incomplete_ping, listener, [idle_timeout]}}},
        bondy_listener_config:resolve(Relay, Missing)
    ).

explicit_ip_overrides_the_default_test() ->
    Inventory = [
        {admin, #{
            transport => tcp,
            protocol => http,
            port => 18081,
            services => [admin],
            ip => {0, 0, 0, 0}
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual({0, 0, 0, 0}, maps:get(ip, L)).

admin_listener_cannot_be_disabled_test() ->
    %% `enabled => false` on the reserved name is the exact configuration that
    %% would leave a node unadministrable, so it is refused rather than
    %% honoured.
    ?assertMatch(
        {error, {invalid_listener, admin, reserved_cannot_be_disabled}},
        bondy_listener_config:resolve(
            [
                {admin, #{
                    transport => tcp,
                    protocol => http,
                    port => 18081,
                    enabled => false,
                    services => [admin_api, admin]
                }}
            ],
            fun(_K, D) -> D end
        )
    ).

duplicate_path_is_rejected_test() ->
    %% Two listeners on one path do NOT race like two on one port. The driver
    %% deletes the socket node before binding, so the second listener succeeds
    %% and silently takes the path over while the first keeps an unreachable
    %% listen socket — no error from ranch, nothing in the log. Nothing at
    %% runtime can catch this, so the resolver has to.
    Inventory = [
        {a, #{
            transport => uds,
            protocol => wamp_rawsocket,
            path => "/tmp/bondy_ct_dup.sock"
        }},
        {b, #{
            transport => uds,
            protocol => wamp_rawsocket,
            path => "/tmp/bondy_ct_dup.sock"
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, b, {path_in_use_by, a}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

internal_listener_participates_in_uniqueness_test() ->
    %% The injected listener is checked against the resolved inventory, not
    %% exempt from it. Written to break the guarantee the way an operator
    %% actually could: point a `uds` listener at the internal socket's path.
    %% `wamp_uds` starts in the NORMAL phase, after `admin_local`, so without
    %% this every later connection to that path would reach the WAMP
    %% raw-socket handler instead of the Admin API.
    Path = "/tmp/bondy_ct_admin_steal.sock",
    {ok, Resolved} = bondy_listener_config:resolve(
        [
            {wamp_uds, #{
                transport => uds, protocol => wamp_rawsocket, path => Path
            }}
        ],
        empty_get()
    ),
    Spec = #{
        transport => uds,
        protocol => http,
        path => Path,
        start_phase => early,
        services => [admin_api, admin]
    },
    ?assertMatch(
        {error, {invalid_listener, admin_local, {path_in_use_by, wamp_uds}}},
        bondy_listener_config:resolve_internal(
            admin_local, Spec, Resolved, empty_get()
        )
    ).

resolve_internal_refuses_a_name_an_operator_may_use_test() ->
    %% `resolve_internal/4` skips nothing an operator-supplied entry gets, but
    %% its whole safety argument — that the name cannot already be taken —
    %% rests on `resolve/2` refusing that name. Only `?RESERVED_INTERNAL` names
    %% are refused there, so injecting any other name could produce two
    %% listeners with one name, which `bondy_listener_manager:listener/1`
    %% cannot resolve. A caller error, so it raises rather than returning
    %% `{error, _}`.
    Spec = #{
        transport => tcp, protocol => http, port => 1, services => [admin]
    },
    ?assertError(
        {not_a_reserved_internal_listener, admin},
        bondy_listener_config:resolve_internal(admin, Spec, [], empty_get())
    ),
    ?assertError(
        {not_a_reserved_internal_listener, pub},
        bondy_listener_config:resolve_internal(pub, Spec, [], empty_get())
    ).

operator_cannot_define_admin_local_test() ->
    %% `listeners.$name` is a cuttlefish FUZZY mapping, so
    %% `listeners.admin_local.transport` is accepted by the schema and reaches
    %% the inventory. Rejecting it explicitly is what stops an operator's block
    %% being silently overridden by the injected internal listener.
    ?assertMatch(
        {error, {invalid_listener, admin_local, reserved_name}},
        bondy_listener_config:resolve(
            [
                {admin_local, #{
                    transport => tcp,
                    protocol => http,
                    port => 19999,
                    services => [admin]
                }}
            ],
            fun(_K, D) -> D end
        )
    ).

legacy_hostname_ip_is_resolved_test() ->
    %% `localhost` is in /etc/hosts on every supported platform, so this does
    %% not depend on a live resolver.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws],
            ip => "localhost"
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual({127, 0, 0, 1}, maps:get(ip, L)).

literal_ip_string_is_parsed_not_resolved_test() ->
    %% The falsification, and the reason parse_address must be tried FIRST: a
    %% resolver with a wildcard record can answer a lookup for "0.0.0.0" with
    %% some other address entirely. A literal must never reach DNS.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws],
            ip => "0.0.0.0"
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual({0, 0, 0, 0}, maps:get(ip, L)).

ipv6_literal_string_is_accepted_test() ->
    %% Accepted by `inet:parse_address/1`, and also by the legacy `ip_address`
    %% validator: `inet:getaddr(Term, inet)` fails for an IPv6 literal
    %% (`{error, nxdomain}`, verified directly), but the validator falls back
    %% to `inet:getaddr(Term, inet6)`, which succeeds. So this pins a preserved
    %% behaviour, not a widening — the divergence between the two validators is
    %% hostnames, not which IP literal family is accepted.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws],
            ip => "::1"
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual({0, 0, 0, 0, 0, 0, 0, 1}, maps:get(ip, L)).

unresolvable_ip_is_rejected_test() ->
    %% `.invalid` is reserved by RFC 2606 and cannot resolve, so this asserts
    %% the error path without depending on any particular resolver's answer.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws],
            ip => "no-such-host.invalid"
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, {unresolvable_ip, _, _}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

non_string_non_tuple_ip_is_rejected_test() ->
    %% `ip => any` is neither a tuple nor a string/binary. Written to break the
    %% claim that a static configuration error always aborts boot as a named
    %% error: before `to_address/2` gained a catch-all,
    %% `unicode:characters_to_list(any)` raised `badarg` and `catching/1` only
    %% catches `throw:{invalid_listener, _, _}`, so this reached the caller as
    %% an opaque crash instead of `{error, {invalid_listener, pub, _}}`.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws],
            ip => any
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, {invalid_ip, any}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

malformed_ip_tuple_is_rejected_test() ->
    %% A 3-tuple is not an `inet:ip_address()`, but `is_tuple/1` alone cannot
    %% tell: written to break the claim that every tuple `resolve_ip/3` accepts
    %% is one `gen_tcp:listen/2` would too.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws],
            ip => {1, 2, 3}
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, {invalid_ip, {1, 2, 3}}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

%% =============================================================================
%% OPTION DEFAULTS IMPLIED BY TRANSPORT AND PROTOCOL
%% =============================================================================
%% Removing the legacy `wamp.{tcp,tls}.*', `api_gateway.*' and
%% `bridge.listener.*' mappings removed the `{default, ...}' each carried, and
%% `rebar3_scuttler' had been writing those defaults into every release's
%% generated `etc/bondy.conf' as active lines. A `listeners.$name.*' mapping
%% cannot replace them: a fuzzy default materialises for every listener name
%% under the prefix. So they live in `bondy_listener_config' and these cases pin
%% each one.
%%
%% Written to break the restoration, not to confirm it: each asserts the
%% specific value that was in force, and `..._is_independent_of_..._test' and
%% `operator_..._wins_..._test' assert the two properties a wrong restoration
%% would violate while still looking correct.

rawsocket_ping_defaults_are_restored_test() ->
    %% `wamp.tcp.ping.enabled' defaulted to `on', so raw-socket keepalive was on
    %% for every node. Its replacement is default-free, so with nothing here a
    %% raw-socket listener has no `ping' key at all and every connection runs
    %% without a keepalive.
    Defaults = bondy_listener_config:option_defaults(tcp, wamp_rawsocket),
    ?assertMatch(#{ping := #{enabled := true}}, Defaults),
    ?assertMatch(#{ping := #{timeout := 10000}}, Defaults),
    ?assertMatch(#{ping := #{max_attempts := 3}}, Defaults).

rawsocket_reap_deadline_is_restored_test() ->
    %% `wamp.tcp.idle_timeout' defaulted to `8h'; the handler's own fallback is
    %% `infinity' (bondy_wamp_tcp_connection_handler.erl:125), which never
    %% applied while the schema supplied a value. At `infinity' an idle
    %% raw-socket connection is never reaped.
    Defaults = bondy_listener_config:option_defaults(tcp, wamp_rawsocket),
    ?assertMatch(#{idle_timeout := 28800000}, Defaults).

rawsocket_ping_interval_is_independent_of_the_reap_deadline_test() ->
    %% The load-bearing case. `maybe_enable_ping/2' took the ping interval from
    %% the listener's `idle_timeout', so both timers came due at the same
    %% moment: at that deadline the connection was closed rather than probed,
    %% and the ping could neither hold a NAT binding open nor detect a dead peer
    %% any sooner than the reap already did. The two must be distinct, and the
    %% probe must be the shorter of the two.
    #{
        idle_timeout := Reap,
        ping := #{idle_timeout := Probe}
    } = bondy_listener_config:option_defaults(tcp, wamp_rawsocket),
    ?assertNotEqual(Reap, Probe),
    ?assert(Probe < Reap),
    %% 20s is the interval `wamp.tcp.ping.idle_timeout' documented and the one
    %% every WebSocket connection is already probed at
    %% (`wamp.websocket.ping.idle_timeout').
    ?assertEqual(20000, Probe).

bridge_relay_ping_defaults_are_restored_test() ->
    %% `bridge.listener.{tcp,tls}.ping.*' carried the same four defaults, and
    %% this handler reads `idle_timeout' out of the ping block itself
    %% (bondy_bridge_relay_server.erl:1062), so all four are load-bearing here.
    Defaults = bondy_listener_config:option_defaults(tcp, bridge_relay),
    ?assertMatch(
        #{
            idle_timeout := 28800000,
            ping := #{
                enabled := true,
                idle_timeout := 20000,
                timeout := 10000,
                max_attempts := 3
            }
        },
        Defaults
    ).

http_protocol_opts_defaults_are_restored_test() ->
    %% `api_gateway.http*.active_n' defaulted to 100 and `idle_timeout' to 15s.
    %% Cowboy's own are 1 (cowboy_http.erl:214) and 60000 (:337). The shipped
    %% templates restate these for `listeners.admin' only, so every other HTTP
    %% listener took Cowboy's on every release.
    Defaults = bondy_listener_config:option_defaults(tcp, http),
    ?assertMatch(#{protocol_opts := #{active_n := 100}}, Defaults),
    ?assertMatch(#{protocol_opts := #{idle_timeout := 15000}}, Defaults).

rawsocket_linger_default_is_one_second_test() ->
    %% `wamp.{tcp,tls}.linger.timeout' defaulted to `1s'. It was withheld until
    %% the key's unit was corrected, because the datatype was `{duration, ms}'
    %% and `bondy_config:normalise_socket_opts/1' passes the value straight into
    %% `{linger, {true, N}}', whose second component `inet' documents as SECONDS
    %% (`kernel/src/inet.erl:1124') — so `1s' had been requesting a 1000-second
    %% blocking close. With the datatype now `{duration, s}` the default is the
    %% one second it always read as.
    %%
    %% ONE, not 1000. That is the whole point of the correction, so it is
    %% asserted as a value rather than as a key being present.
    Defaults = bondy_listener_config:option_defaults(tcp, wamp_rawsocket),
    ?assertMatch(
        #{transport_opts := #{socket_opts := #{linger_timeout := 1}}}, Defaults
    ).

both_stream_protocols_get_the_linger_default_test() ->
    %% `bridge.listener.{tcp,tls}.linger.timeout' carried the same `1s', so the
    %% default belongs to the raw-socket SHAPE and not to one protocol. An HTTP
    %% listener gets none: its equivalent is Cowboy's own `linger_timeout`
    %% protocol option, reached through `listeners.$name.http.linger.timeout`,
    %% which is a genuinely different setting in genuinely different units.
    Expected = #{transport_opts => #{socket_opts => #{linger_timeout => 1}}},
    ?assertMatch(
        #{transport_opts := #{socket_opts := #{linger_timeout := 1}}},
        bondy_listener_config:option_defaults(tls, bridge_relay)
    ),
    ?assertEqual(
        maps:get(transport_opts, Expected),
        maps:get(
            transport_opts,
            bondy_listener_config:option_defaults(tcp, wamp_rawsocket)
        )
    ),
    ?assertNot(
        maps:is_key(
            transport_opts, bondy_listener_config:option_defaults(tcp, http)
        )
    ).

tls_http_listener_gets_hsts_test() ->
    %% `admin_api.https.security_headers.hsts' carried this value; today
    %% `bondy_http_security_headers:default_config/0' has `hsts => undefined',
    %% so a TLS listener sends no HSTS header.
    Tls = bondy_listener_config:option_defaults(tls, http),
    ?assertMatch(
        #{
            security_headers := #{
                hsts := <<"max-age=31536000; includeSubDomains">>
            }
        },
        Tls
    ).

plaintext_http_listener_gets_no_hsts_test() ->
    %% The other half, and the reason `option_defaults/2' takes the transport as
    %% well as the protocol: HSTS on a plaintext listener tells a browser to use
    %% TLS on a port that does not speak it.
    Tcp = bondy_listener_config:option_defaults(tcp, http),
    ?assertNot(maps:is_key(security_headers, Tcp)).

rawsocket_gets_no_http_defaults_test() ->
    %% `protocol_opts' are Cowboy's; a raw socket has no Cowboy. Written because
    %% one table keyed on two axes is easy to over-apply.
    Raw = bondy_listener_config:option_defaults(tcp, wamp_rawsocket),
    ?assertNot(maps:is_key(protocol_opts, Raw)),
    ?assertNot(maps:is_key(security_headers, Raw)).

operator_value_wins_over_a_protocol_default_test() ->
    %% `deployment/fly/config/bondy.conf.template:105' sets
    %% `listeners.wamp_tcp.ping.enabled = off'. It must stay off.
    Spec = #{
        transport => tcp,
        protocol => wamp_rawsocket,
        port => 18082,
        ping => #{enabled => false}
    },
    #{ping := Ping} = bondy_listener_config:with_option_defaults(Spec),
    ?assertMatch(#{enabled := false}, Ping).

protocol_defaults_merge_into_a_partial_block_test() ->
    %% The property that makes deleting the ping-completeness validation safe:
    %% an operator who sets ONE ping key gets the rest from the defaults, so an
    %% enabled block can no longer be missing a sibling the handler reads with
    %% `maps:get/2'. A shallow merge would drop `enabled', `timeout' and
    %% `max_attempts' here.
    Spec = #{
        transport => tcp,
        protocol => wamp_rawsocket,
        port => 18082,
        ping => #{timeout => 3000}
    },
    #{ping := Ping} = bondy_listener_config:with_option_defaults(Spec),
    ?assertEqual(3000, maps:get(timeout, Ping)),
    ?assertEqual(true, maps:get(enabled, Ping)),
    ?assertEqual(20000, maps:get(idle_timeout, Ping)),
    ?assertEqual(3, maps:get(max_attempts, Ping)).

with_option_defaults_leaves_an_unidentified_spec_alone_test() ->
    %% A spec with no `transport'/`protocol' is rejected by `resolve/2` with a
    %% named error; this must not raise first.
    Spec = #{port => 18082},
    ?assertEqual(Spec, bondy_listener_config:with_option_defaults(Spec)).

tls_rawsocket_ping_defaults_match_tcp_test() ->
    %% `wamp.tls.ping.max_attempts' defaulted to 3 while `wamp.tcp.ping.
    %% max_attempts' defaulted to 2, and nothing explained the difference. The
    %% transport does not change how many unanswered probes mean a dead peer, so
    %% the two are unified — at 3, which is also what a WebSocket connection
    %% gets, so one number covers every protocol. This case exists so the
    %% unification is a recorded decision rather than an oversight: it asserts
    %% both halves, that the two transports agree AND which value they agree on.
    Tcp = bondy_listener_config:option_defaults(tcp, wamp_rawsocket),
    Tls = bondy_listener_config:option_defaults(tls, wamp_rawsocket),
    ?assertEqual(maps:get(ping, Tcp), maps:get(ping, Tls)),
    ?assertMatch(#{ping := #{max_attempts := 3}}, Tls).

tls_rawsocket_gets_no_hsts_test() ->
    %% `security_headers' are HTTP response headers. The `tls' axis must not
    %% carry them on its own, or a raw-socket TLS listener would resolve with a
    %% block nothing can send.
    Tls = bondy_listener_config:option_defaults(tls, wamp_rawsocket),
    ?assertNot(maps:is_key(security_headers, Tls)).

%% =============================================================================
%% CARRIER → MODULE IS A FUNCTIONAL DEPENDENCY
%% =============================================================================
%% `module` used to ride on each SERVICE, so two services naming one carrier
%% each carried a value for a field that depends on the carrier alone — a state
%% in which an operator's service list can be internally inconsistent, and which
%% forced the dispatch assembler to re-derive the module by rescanning
%% `services` and taking the first match. These cases pin the normalised shape:
%% the resolver decides the module once, from the carrier.

resolved_carrier_carries_its_module_test() ->
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws, bamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    #{websocket := #{module := Module, protocols := Protos}} =
        maps:get(carriers, L),
    ?assertEqual(bondy_http_services, Module),
    %% Two services, one carrier, both protocols — the union is what makes the
    %% module a per-carrier fact rather than a per-service one.
    ?assertEqual([bamp, wamp], lists:sort(Protos)).

api_gateway_and_admin_api_are_separate_carriers_test() ->
    %% They differ by ROUTE SOURCE — stored specifications versus the built-in
    %% specification in `priv/` — not by protocol, and both declare `undefined`
    %% for protocol. So a shared carrier's protocol union cannot tell them apart
    %% and the dispatch assembler had to consult `services` to decide which route
    %% set to fetch. Two carriers removes that lookup.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [api_gateway, admin_api]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    Carriers = maps:get(carriers, L),
    ?assert(maps:is_key(api_gateway, Carriers)),
    ?assert(maps:is_key(admin_api, Carriers)),
    ?assertNot(maps:is_key(rest, Carriers)).

carrier_config_is_resolved_once_per_carrier_test() ->
    %% `wamp_ws` and `bamp_ws` share the `websocket` carrier. The fold this
    %% replaced built its accumulator entry with `maps:get/3`, whose default is
    %% evaluated EAGERLY, so the carrier's whole configuration was resolved once
    %% per service and thrown away for every service but the first.
    %%
    %% Counted through the `GetFun`, which is the only observable the resolver
    %% has: one read of a given carrier key per carrier, not per service.
    Key = [pub, websocket, compress],
    _ = erlang:erase(reads),
    Counting = fun(K, Default) ->
        K =:= Key andalso erlang:put(reads, 1 + count()),
        Default
    end,
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws, bamp_ws]
        }}
    ],
    {ok, [_]} = bondy_listener_config:resolve(Inventory, Counting),
    ?assertEqual(1, count()).

count() ->
    case erlang:get(reads) of
        undefined -> 0;
        N -> N
    end.

unknown_carrier_is_a_boot_error_test() ->
    %% An external service naming a carrier no module implements. Caught at BOOT
    %% naming the listener, the carrier and the service that asked for it —
    %% rather than inside a listener start or a dispatch rebuild, where the old
    %% `no_module_for_carrier` error was raised and could name no listener.
    ok = application:set_env(bondy_router, http_services, [
        {ghost, #{carrier => nowhere, protocol => undefined}}
    ]),
    try
        Inventory = [
            {pub, #{
                transport => tcp,
                protocol => http,
                port => 18080,
                services => [ghost]
            }}
        ],
        ?assertMatch(
            {error, {invalid_listener, pub, {unknown_carrier, nowhere, ghost}}},
            bondy_listener_config:resolve(Inventory, empty_get())
        )
    after
        ok = application:unset_env(bondy_router, http_services)
    end.

external_carrier_module_is_resolved_test() ->
    %% The registration path an application outside `bondy_router` uses, in its
    %% normalised form: the service says which carrier it rides, the carrier says
    %% which module serves it. Two env keys rather than one is the price of the
    %% dependency being expressible only once.
    ok = application:set_env(bondy_router, http_services, [
        {mcp, #{carrier => mcp, protocol => mcp}}
    ]),
    ok = application:set_env(bondy_router, http_carriers, [{mcp, bondy_mcp}]),
    try
        Inventory = [
            {pub, #{
                transport => tcp,
                protocol => http,
                port => 18080,
                services => [mcp]
            }}
        ],
        {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
        ?assertMatch(
            #{mcp := #{module := bondy_mcp, protocols := [mcp]}},
            maps:get(carriers, L)
        )
    after
        ok = application:unset_env(bondy_router, http_services),
        ok = application:unset_env(bondy_router, http_carriers)
    end.

http_listener_with_no_services_is_rejected_test() ->
    %% An empty list resolved, and produced a listener that bound a socket and
    %% answered 404 to everything with no diagnostic anywhere. An HTTP listener
    %% naming nothing to serve is the same operator mistake as one naming no
    %% `services` key at all — `listeners.pub.services =` renders as `[]` — so
    %% both report the same thing.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 18080, services => []
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, {missing, services}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

partial_security_headers_block_still_gets_the_hsts_default_test() ->
    %% The interaction between the HSTS default and the schema's CORS /
    %% security-header completion, which is why the completion had to go.
    %%
    %% While the translation handed over a TOTAL map, a TLS listener that set any
    %% one member — say `frame_options` — also arrived carrying
    %% `hsts => undefined`, and the operator's value wins the deep merge. So
    %% stating one unrelated header silently switched HSTS off, on exactly the
    %% listeners it is for.
    Spec = #{
        transport => tls,
        protocol => http,
        port => 18080,
        services => [api_gateway],
        security_headers => #{frame_options => <<"DENY">>}
    },
    #{security_headers := Headers} =
        bondy_listener_config:with_option_defaults(Spec),
    ?assertEqual(<<"DENY">>, maps:get(frame_options, Headers)),
    ?assertEqual(
        <<"max-age=31536000; includeSubDomains">>, maps:get(hsts, Headers)
    ).

an_explicit_undefined_hsts_still_disables_it_test() ->
    %% The other side of that merge, and the reason the fix is to stop
    %% completing the block rather than to stop the operator overriding it: an
    %% operator who says "do not send this header" must keep winning over the
    %% default a TLS listener gets.
    %%
    %% The conf spelling is `security_headers.hsts = off`, which the schema's
    %% `Header/1` renders as the `undefined` used here. NOT
    %% `security_headers.hsts =` with nothing after it — measured, that is a
    %% cuttlefish CONF SYNTAX ERROR, not an empty value
    %% (`an_empty_security_header_value_is_a_syntax_error` in
    %% `bondy_listener_schema_SUITE`).
    Spec = #{
        transport => tls,
        protocol => http,
        port => 18080,
        services => [api_gateway],
        security_headers => #{hsts => undefined}
    },
    #{security_headers := Headers} =
        bondy_listener_config:with_option_defaults(Spec),
    ?assertEqual(undefined, maps:get(hsts, Headers)).
