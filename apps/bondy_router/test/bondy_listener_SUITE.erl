%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Exercises the listener driver against real sockets: a listener that starts
%% accepts a connection, a suspended one refuses new connections while keeping
%% existing ones, and a stopped one releases its port.
%% =============================================================================
-module(bondy_listener_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([tcp_listener_accepts/1]).
-export([suspend_refuses_new_connections/1]).
-export([stop_releases_the_port/1]).
-export([uds_listener_accepts/1]).
-export([manager_resolves_and_starts_by_phase/1]).
-export([manager_aborts_boot_on_invalid_config/1]).
-export([tls_listeners_are_derived/1]).
-export([listener_with_no_option_block_starts/1]).
-export([option_block_reaches_the_consumer/1]).
-export([configured_inventory_gets_the_reserved_admin/1]).
-export([operator_admin_block_wins_over_the_injected_one/1]).
-export([top_level_ip_does_not_reach_ranch/1]).
-export([ws_listener_restricted_to_one_protocol/1]).
-export([ws_max_frame_size_is_enforced_per_listener/1]).
-export([new_style_tls_listener_binds/1]).
-export([http_versions_decide_alpn/1]).
-export([splat_merges_into_an_existing_transport_block/1]).
-export([new_style_tls_material_is_visible_to_rotation/1]).
-export([new_style_mtls_material_is_visible_to_rotation/1]).
-export([splatted_cors_and_security_headers_reach_the_consumers/1]).
-export([wamp_handshake_on_a_listener_with_no_option_block/1]).
-export([rawsocket_ping_interval_comes_from_the_ping_block/1]).
-export([ipv6_listener_binds_without_an_explicit_ip/1]).
-export([explicit_ipv6_binds_without_an_ip_version/1]).
-export([one_port_two_addresses/1]).
-export([connection_alarms_reach_ranch/1]).
-export([rawsocket_linger_reaches_the_socket_as_one_second/1]).
-export([partial_proxy_protocol_reaches_the_http_consumer/1]).
-export([partial_proxy_protocol_survives_a_real_connection/1]).
-export([drain_spares_the_early_phase/1]).
-export([virtual_hosts_are_routed_independently/1]).
-export([max_cookies_is_enforced_per_listener/1]).

%% This module doubles as a `bondy_http_service` implementation and as the
%% cowboy handler its routes point at, so
%% `virtual_hosts_are_routed_independently/1` depends on no Bondy handler's
%% configuration.
-export([routes/3]).
-export([init/2]).

%% ...and as a logger handler, for the same reason:
%% `connection_alarms_reach_ranch/1` reads the level an alarm actually logged at.
-export([log/2]).

all() ->
    [
        tcp_listener_accepts,
        suspend_refuses_new_connections,
        stop_releases_the_port,
        uds_listener_accepts,
        manager_resolves_and_starts_by_phase,
        manager_aborts_boot_on_invalid_config,
        tls_listeners_are_derived,
        listener_with_no_option_block_starts,
        option_block_reaches_the_consumer,
        configured_inventory_gets_the_reserved_admin,
        operator_admin_block_wins_over_the_injected_one,
        top_level_ip_does_not_reach_ranch,
        ws_listener_restricted_to_one_protocol,
        ws_max_frame_size_is_enforced_per_listener,
        new_style_tls_listener_binds,
        http_versions_decide_alpn,
        splat_merges_into_an_existing_transport_block,
        new_style_tls_material_is_visible_to_rotation,
        new_style_mtls_material_is_visible_to_rotation,
        splatted_cors_and_security_headers_reach_the_consumers,
        wamp_handshake_on_a_listener_with_no_option_block,
        rawsocket_ping_interval_comes_from_the_ping_block,
        ipv6_listener_binds_without_an_explicit_ip,
        explicit_ipv6_binds_without_an_ip_version,
        one_port_two_addresses,
        connection_alarms_reach_ranch,
        rawsocket_linger_reaches_the_socket_as_one_second,
        partial_proxy_protocol_reaches_the_http_consumer,
        partial_proxy_protocol_survives_a_real_connection,
        drain_spares_the_early_phase,
        virtual_hosts_are_routed_independently,
        max_cookies_is_enforced_per_listener
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(cowboy),
    %% Common Test's cwd for this run is the per-run log dir, not the repo
    %% root, so the relative certificate paths a real TLS bind needs
    %% (`./etc/ssl/server/*.pem`) resolve only after this. Normally a no-op
    %% here: whatever `rebar3 ct` run already booted Bondy once through
    %% `bondy_ct:start_bondy/0` did this already, for the life of the VM.
    ok = bondy_ct:ensure_etc(),
    %% A real WAMP WebSocket handshake reaches `bondy_wamp_protocol:init/3',
    %% which builds a session id from `bondy_config:node_hash/0', which reads
    %% `partisan_config:get(name)`. Verified directly: without this, that read
    %% raises `badarg` (the key is never set) and every handshake in this
    %% suite fails with 400 regardless of subprotocol. `partisan_config:init/0`
    %% is the function `partisan_sup`'s own `init/1` calls to populate it, and
    %% its doc sanctions calling it directly for tests ("idempotent, which is
    %% required for testing") — it only sets persistent_term/application-env
    %% config, so it does not start the peer-connection supervision tree the
    %% full `partisan` application would.
    ok = partisan_config:init(),
    %% `bondy_listener_manager:init/0` appends the internal `admin_local`
    %% listener, whose socket path is `platform_tmp_dir`-relative and read
    %% without a default (the schema always supplies the key; an absent one
    %% means a mis-rendered release). This suite does not boot
    %% `bondy_config:init/1`,
    %% so it supplies the key itself. The OS pid keeps parallel CT runs from
    %% sharing the directory.
    ok = bondy_config:set(
        platform_tmp_dir, filename:join("/tmp", "bondy_ct_" ++ os:getpid())
    ),
    %% `bondy_router.listeners` and the resolved inventory
    %% `bondy_listener_manager:init/0` caches in `persistent_term` are
    %% NODE-GLOBAL and outlive this suite in a `rebar3 ct` run that goes on
    %% to another suite in the same VM. Every case below that calls
    %% `bondy_listener_manager:init/0` first sets its own `listeners` value,
    %% so nothing here leaks from one case to the NEXT case in this suite —
    %% verified by reading every case: each one sets `listeners` (to a real
    %% inventory or explicitly to `undefined`) before relying on it. What is
    %% not restored is the value the LAST case in `all/0` happens to leave
    %% behind, which is what `end_per_suite/1` puts back.
    Original = bondy_config:get(listeners, undefined),
    [{original_listeners, Original} | Config].

end_per_suite(Config) ->
    %% Restoring `bondy_config`'s value is not enough on its own: if
    %% `bondy_router` is already running by the time a later suite starts —
    %% e.g. a bigger `rebar3 ct` run where some earlier suite already called
    %% `bondy_ct:start_bondy/0` — `bondy_listener_manager:init/0` will not run
    %% again on its own (`bondy_ct:start_bondy/0` is a one-shot per VM), so
    %% the resolved-inventory cache this suite last wrote would survive
    %% regardless of what `bondy_config:get(listeners, _)` now says. Calling
    %% `init/0` here makes the fix work in both cases: `bondy_router` not yet
    %% started (a later `start_bondy/0` resolves fresh from the restored
    %% value anyway) and `bondy_router` already started (this call is the
    %% only thing that will refresh the cache before that later suite reads
    %% it).
    ok = bondy_config:set(listeners, ?config(original_listeners, Config)),
    ok = bondy_listener_manager:init(),
    Config.

%% A raw-socket listener on an ephemeral port. `port => 0` makes the OS choose,
%% which keeps parallel CT runs from colliding.
listener(Name, Extra) ->
    ok = set_listener_env(Name),
    Spec = maps:merge(
        #{transport => tcp, protocol => wamp_rawsocket, port => 0}, Extra
    ),
    {ok, [L]} = bondy_listener_config:resolve(
        [{Name, Spec}], fun(_K, D) -> D end
    ),
    L.

%% `bondy_listener_ranch` builds its ranch options through
%% `bondy_config:listener_transport_opts/2`. That resolves via `app_config`,
%% which reads `persistent_term` — NOT application environment — so
%% `application:set_env/3` is invisible to it. And `bondy_config:get/1` has no
%% default, so a listener with no block raises rather than returning
%% `undefined`, and `key_value:to_map/1` has no clause for `undefined` either.
%% Each test listener therefore needs its block installed before the driver
%% starts it.
%%
%% A full boot does this from application env via `bondy_config:init/1`; this
%% suite starts only ranch and cowboy, so it installs the block directly.
%%
%% `ip_version` and `proxy_protocol` are stated here to give every case that
%% uses this helper one known block, NOT because either is required: no default
%% of any kind is in play in this suite, which bypasses cuttlefish entirely, and
%% both consumers now supply their own. `normalise_socket_opts/1` falls back to
%% `inet` for an absent `ip_version`, and `bondy_tcp_proxy_protocol:init/2`
%% merges `enabled` and `mode` into whatever the block holds. The absent-block
%% path is covered by `wamp_handshake_on_a_listener_with_no_option_block`, which
%% installs nothing at all and completes a handshake, and the partial-block path
%% by the two `partial_proxy_protocol_*` cases.
set_listener_env(Name) ->
    bondy_config:set(Name, [
        {transport_opts, [
            {num_acceptors, 2},
            {max_connections, 128},
            {socket_opts, [{ip_version, inet}]}
        ]},
        {proxy_protocol, [{enabled, false}]}
    ]).

%% The server-side connection process is spawned asynchronously after
%% `gen_tcp:connect/4` returns, so poll rather than assume it is counted
%% already.
await_connections(L, N) ->
    await_connections(L, N, 50).

await_connections(L, N, 0) ->
    ?assertEqual(N, length(bondy_listener:connections(L))),
    ok;
await_connections(L, N, Retries) ->
    case length(bondy_listener:connections(L)) of
        N ->
            ok;
        _ ->
            ok = timer:sleep(20),
            await_connections(L, N, Retries - 1)
    end.

tcp_listener_accepts(_Config) ->
    L = listener(ct_accept, #{}),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_accept),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 5000),
    ok = gen_tcp:close(Sock),
    ok = bondy_listener:stop(L).

suspend_refuses_new_connections(_Config) ->
    L = listener(ct_suspend, #{}),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_suspend),
    {ok, Existing} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 5000),
    ok = await_connections(L, 1),

    ok = bondy_listener:suspend(L),
    ?assertMatch(
        {error, econnrefused},
        gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 1000)
    ),
    %% The established connection must survive suspension. `gen_tcp:send/2`
    %% cannot show this: it is a local kernel-buffer write that returns `ok`
    %% whether or not the peer is gone, so it would pass even if `suspend/1`
    %% had torn the connection down — a remote close only surfaces on a LATER
    %% send/recv. Worse, the only bytes available to send are a WAMP protocol
    %% violation, which makes the handler log an `invalid_handshake` crash
    %% report. Counting the connection process instead proves the property and
    %% provokes nothing.
    ok = await_connections(L, 1),

    ok = bondy_listener:resume(L),
    %% `ranch:resume_listener/1` re-listens from the transport options stored
    %% at `start/1` time, which still say `port => 0`: it binds a NEW
    %% ephemeral port rather than reclaiming the original one. Verified by
    %% observation — reusing `Port` here reproducibly yields `econnrefused`
    %% even though `resume/1` returned `ok`.
    ResumedPort = ranch:get_port(ct_suspend),
    {ok, After} = gen_tcp:connect({127, 0, 0, 1}, ResumedPort, [binary], 5000),
    ok = gen_tcp:close(After),
    ok = gen_tcp:close(Existing),
    ok = bondy_listener:stop(L).

stop_releases_the_port(_Config) ->
    L = listener(ct_stop, #{}),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_stop),
    ok = bondy_listener:stop(L),
    ?assertMatch(
        {error, econnrefused},
        gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 1000)
    ).

manager_resolves_and_starts_by_phase(_Config) ->
    ok = set_listener_env(ct_early),
    ok = set_listener_env(ct_late),
    Inventory = [
        {ct_early, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => 0,
            start_phase => early
        }},
        {ct_late, #{
            transport => tcp, protocol => wamp_rawsocket, port => 0
        }}
    ],
    %% `init/0` reads the inventory through `bondy_config`, which resolves
    %% against persistent_term — `application:set_env/3` is invisible to it
    %% unless `bondy_config:init/1` has since re-cached. Set it directly.
    ok = bondy_config:set(listeners, Inventory),
    ok = bondy_listener_manager:init(),

    %% Both resolved, each carrying the phase its inventory entry gave it.
    {ok, Early} = bondy_listener_manager:listener(ct_early),
    ?assertEqual(early, maps:get(start_phase, Early)),
    {ok, Late} = bondy_listener_manager:listener(ct_late),
    ?assertEqual(normal, maps:get(start_phase, Late)),

    %% `init/0` appends the internal `admin_local` listener to an inventory that
    %% does not mention it.
    ?assertMatch(
        {ok, #{transport := uds, start_phase := early}},
        bondy_listener_manager:listener(admin_local)
    ),

    %% `start/1` starts exactly the phase asked for, over real sockets.
    %%
    %% The NORMAL phase, deliberately: `admin_local` is `early` and declares
    %% `admin_api`, so starting the early phase here would reach
    %% `bondy_http_gateway:admin_api_routes/1`, and through it
    %% `bondy_config:get(priv_dir)` and the admin realm's RBAC groups. This
    %% suite runs on ranch and cowboy alone, and booting most of a node into it
    %% to check a selection rule would cost the isolation that makes the rest of
    %% these cases cheap. Driving the normal phase exercises the same rule from
    %% the other side: `ct_late` binds, and both `early` listeners must not.
    ok = bondy_listener_manager:start(normal),
    ?assertMatch(Port when is_integer(Port), ranch:get_port(ct_late)),
    %% Not up: that is what lets the probe paths answer while the node still
    %% reports `initialising`, without a client reaching a public listener first
    %% — `bondy_app:start_normal_listeners/0` sets the status to `ready` only
    %% after the normal phase. `ranch:get_port/1` reaches
    %% `ets:lookup_element/3` on the ranch table (`ranch_server.erl:135-136`),
    %% which raises `badarg` for a listener that was never started.
    ?assertError(badarg, ranch:get_port(ct_early)),
    %% `admin_local` is `early` too, and `init/0` injected it, so `start(normal)`
    %% must have skipped it as well. Checked through the manager's own inventory
    %% rather than `ranch:get_port(admin_local)`: that name is NODE-GLOBAL, and in
    %% a full `rebar3 ct` run an earlier suite's `bondy_ct:start_bondy/0` leaves a
    %% real `admin_local` registered in ranch, so the ranch assertion failed on VM
    %% state this suite does not own while the selection rule it was testing was
    %% intact. `ct_early` above still covers the operator-declared side over a
    %% real socket.
    {ok, AdminLocal} = bondy_listener_manager:listener(admin_local),
    ?assertEqual(early, maps:get(start_phase, AdminLocal)),

    ok = bondy_listener_manager:stop(all).

manager_aborts_boot_on_invalid_config(_Config) ->
    %% A static config error must abort, not skip the listener. A node that
    %% boots serving nothing is harder to diagnose than one that refuses to.
    ok = bondy_config:set(listeners, [{ct_bad, #{protocol => http}}]),
    ?assertError(
        {invalid_listener, ct_bad, {missing, transport}},
        bondy_listener_manager:init()
    ).

tls_listeners_are_derived(_Config) ->
    Inventory = [
        {ct_plain, #{transport => tcp, protocol => wamp_rawsocket, port => 0}},
        {ct_secure, #{transport => tls, protocol => wamp_rawsocket, port => 0}}
    ],
    ok = bondy_config:set(listeners, Inventory),
    ok = bondy_config:set(ct_secure, [
        {tls, [{certfile, "/tmp/c.pem"}, {keyfile, "/tmp/k.pem"}]}
    ]),
    ok = bondy_listener_manager:init(),
    ?assertEqual([ct_secure], bondy_listener_manager:tls_listeners()).

listener_with_no_option_block_starts(_Config) ->
    %% A listener specified by its inventory entry and NOTHING else: no
    %% `[ct_bare, ...]` block anywhere in configuration. That is a legitimate
    %% listener — transport, protocol and a bind target fully determine it, and
    %% the per-listener option keys carry no defaults of their own — so it must
    %% bind a real socket, not raise.
    %%
    %% Deliberately NOT using this suite's `listener/2` helper: that installs an
    %% option block, which is what hid three no-default reads
    %% (`bondy_config:listener_transport_opts/2`'s block and `num_acceptors`,
    %% and `normalise_socket_opts/1`'s `ip_version`). Each raised out of
    %% `bondy_listener:start/1` rather than returning `{error, _}`, so
    %% `bondy_app`'s `ok ?= start_normal_listeners()` could not catch it and the
    %% node did not boot.
    %%
    %% `fun bondy_config:get/2` is the production accessor, so the resolver and
    %% the driver read exactly what a real boot reads.
    Inventory = [
        {ct_bare, #{transport => tcp, protocol => wamp_rawsocket, port => 0}}
    ],
    {ok, [L]} = bondy_listener_config:resolve(
        Inventory, fun bondy_config:get/2
    ),
    ok = bondy_listener:start(L),

    %% Started, not merely resolved: ranch reports a bound port for it.
    ?assertMatch(Port when is_integer(Port), ranch:get_port(ct_bare)),

    %% The defaults reached ranch. `infinity` distinguishes the value carried
    %% over from the deleted UDS listener module from ranch's own default of
    %% 1024, which is what an absent key would otherwise have selected.
    ?assertEqual(infinity, ranch:get_max_connections(ct_bare)),

    %% The protocol-opts leg of the same problem, checked directly because an
    %% HTTP listener cannot be started here (its API Gateway routes need the
    %% store): an absent block is no overrides, not a raise.
    ?assertEqual(#{}, bondy_config:listener_protocol_opts(ct_bare)),

    %% And it serves: an accepted connection's handler SURVIVES. Without a
    %% `proxy_protocol` block `bondy_tcp_proxy_protocol:init/2` returned `#{}`
    %% and `source_ip/2` had no clause for it, so the handler died on every
    %% accepted connection — a listener that binds but serves nothing.
    %%
    %% Counting connections cannot show this: `ranch:procs/2` counts the process
    %% as soon as it is spawned, before `init/1` runs, so the count reaches 1
    %% either way (verified — with the defect reintroduced, a count-based
    %% assertion still passed). Monitoring it does show it, and reports the exit
    %% reason. The handler's `idle_timeout` defaults to `infinity` for a
    %% listener with no block, so it has no reason of its own to exit inside
    %% the window.
    BoundPort = ranch:get_port(ct_bare),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, BoundPort, [binary], 5000),
    ok = await_connections(L, 1),
    [Handler] = bondy_listener:connections(L),
    MRef = erlang:monitor(process, Handler),
    receive
        {'DOWN', MRef, process, Handler, Reason} ->
            ct:fail({connection_handler_died, Reason})
    after 500 ->
        true = erlang:demonitor(MRef, [flush, info])
    end,
    ok = gen_tcp:close(Sock),

    ok = bondy_listener:stop(L).

option_block_reaches_the_consumer(_Config) ->
    %% The schema renders ONE key; a listener's options arrive nested inside its
    %% inventory entry. Nothing else in the system reads them there, so a splat
    %% that silently did nothing would leave every listener on defaults —
    %% indistinguishable from a working system until an operator's tuning is
    %% ignored. Assert through the accessor the driver actually calls.
    Inventory = [
        {ct_splat, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => 0,
            transport_opts => [
                {num_acceptors, 7},
                {socket_opts, [{ip_version, inet}, {backlog, 321}]}
            ],
            proxy_protocol => [{enabled, false}],
            %% A key that lands at the spec's TOP level, not inside a block.
            %% `bondy_wamp_tcp_connection_handler.erl:118' reads it flat, so a
            %% splat that only moved the named blocks would drop it — and drop
            %% `ping' and `server_header' with it.
            idle_timeout => 12345
        }}
    ],
    ok = bondy_config:splat_listener_blocks(Inventory),
    Opts = bondy_config:listener_transport_opts(ct_splat, undefined),
    ?assertEqual(7, maps:get(num_acceptors, Opts)),
    ?assertEqual(
        321, key_value:get(backlog, maps:get(socket_opts, Opts))
    ),
    ?assertEqual(12345, bondy_config:get([ct_splat, idle_timeout], undefined)),
    %% A structural key stays in the inventory and is NOT splatted: nothing
    %% reads `[Name, transport]`, and writing it would create a second place
    %% where a listener's transport is recorded.
    ?assertEqual(
        undefined, bondy_config:get([ct_splat, transport], undefined)
    ).

uds_listener_accepts(_Config) ->
    %% The path must include the OS pid: parallel CT runs share /tmp.
    %%
    %% NOT placed under `?config(priv_dir, Config)`: CT nests it under
    %% `ct_run.<node>.<ts>/lib.<app>.<suite>.logs/run.<ts>/log_private/`, which
    %% measured 189 characters on this checkout — over `sockaddr_un.sun_path`,
    %% 104 bytes on Darwin (108 on Linux). Verified directly:
    %% `gen_tcp:listen(0, [{ifaddr, {local, Path}}])` returns `ok` for a
    %% 26-character path and `{error, einval}` for a 155-character one. `/tmp`
    %% keeps the path short; the pid suffix still makes it unique against
    %% other parallel CT runs sharing that directory.
    Path = filename:join("/tmp", "bondy_ct_" ++ os:getpid() ++ ".sock"),
    L = listener(ct_uds, #{transport => uds, path => Path}),
    ok = bondy_listener:start(L),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0, [binary], 5000),
    ok = gen_tcp:close(Sock),

    %% An operator's own Unix domain listener keeps the mode `gen_tcp:listen/2`
    %% gave it, which is the process umask. Only `admin_local` — injected, with
    %% no key an operator could use to widen it — is narrowed to 0600
    %% (`bondy_admin_listener_SUITE:admin_local_socket_is_bound_and_serves`
    %% asserts that end). Narrowing every path bind would break a sidecar under
    %% a different uid on upgrade, with no key to opt out.
    %%
    %% Asserted as "not 0600" rather than against a computed mode: the umask is
    %% not readable from Erlang, and 0777 & ~umask equals 0600 only under a
    %% umask of 0177.
    {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
    ?assertNotEqual(8#600, Mode band 8#777),

    ok = bondy_listener:stop(L).

configured_inventory_gets_the_reserved_admin(_Config) ->
    %% An operator who adopted `listeners.*` and did not write an admin listener
    %% still gets one: otherwise a single conf edit can lock them out.
    ok = bondy_config:set(listeners, [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws]
        }}
    ]),
    ok = bondy_listener_manager:init(),
    ?assertMatch({ok, _}, bondy_listener_manager:listener(admin)),
    %% ...on the port the built-in default gives it, since the operator declared
    %% no admin block of their own.
    {ok, Admin} = bondy_listener_manager:listener(admin),
    ?assertEqual({port, 18081}, maps:get(bind, Admin)).

operator_admin_block_wins_over_the_injected_one(_Config) ->
    %% Reserved means "cannot be removed", not "cannot be configured": an
    %% operator must be able to move the admin port or put it behind TLS.
    ok = bondy_config:set(listeners, [
        {admin, #{
            transport => tcp,
            protocol => http,
            port => 18099,
            services => [admin_api, admin]
        }}
    ]),
    ok = bondy_listener_manager:init(),
    {ok, Admin} = bondy_listener_manager:listener(admin),
    ?assertEqual({port, 18099}, maps:get(bind, Admin)),
    %% Exactly one, not the operator's plus an injected default.
    Names = [maps:get(name, L) || L <- bondy_listener_manager:listeners()],
    ?assertEqual(1, length([N || N <- Names, N =:= admin])).

top_level_ip_does_not_reach_ranch(_Config) ->
    %% The case above stops at the resolved map; this one binds. `ip` is not a
    %% ranch transport option, and `key_value:to_map/1` is shallow, so an `ip`
    %% sitting at the top of a listener's `transport_opts` block survives the
    %% merge in `bondy_config:listener_transport_opts/2` and reaches
    %% `ranch:start_listener/5`, whose `validate_transport_opt/3` catch-all
    %% answers `false` for an unknown key — `{error, {bad_option, ip}}`, which
    %% `fold_until_error/2` propagates and `bondy_app:start_normal_listeners/0`
    %% turns into a refused boot.
    %%
    %% The block below puts the address at the top of `transport_opts` and the
    %% same address on the spec. No schema key renders that shape, but
    %% `bondy_config` still has to strip it, because the inventory's own `ip` key
    %% reaches the same code. The listener name and ephemeral port are this
    %% suite's, not `wamp_tcp`'s 18082, which the CT runner VM already holds.
    ok = bondy_config:set(ct_raw_ip, [
        {transport_opts, [{ip, "127.0.0.1"}, {num_acceptors, 2}]}
    ]),
    {ok, [L]} = bondy_listener_config:resolve(
        [
            {ct_raw_ip, #{
                transport => tcp,
                protocol => wamp_rawsocket,
                port => 0,
                ip => {127, 0, 0, 1}
            }}
        ],
        fun(_K, D) -> D end
    ),
    ok = bondy_listener:start(L),
    %% `ranch:get_addr/1` is the listening socket's own `sockname`, so this
    %% confirms the address took effect rather than merely that a port opened.
    ?assertEqual(
        {{127, 0, 0, 1}, ranch:get_port(ct_raw_ip)},
        ranch:get_addr(ct_raw_ip)
    ),
    ok = bondy_listener:stop(L).

%% Opens a WebSocket handshake against `Port' offering `Subprotocol' and
%% returns the response status line.
ws_handshake(Port, Subprotocol) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 5000
    ),
    Req = [
        "GET /ws HTTP/1.1\r\n",
        "Host: localhost\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "Sec-WebSocket-Protocol: ",
        Subprotocol,
        "\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
    ok = gen_tcp:close(Sock),
    hd(binary:split(Data, <<"\r\n">>)).

ws_listener_restricted_to_one_protocol(_Config) ->
    %% A WAMP subprotocol that is valid globally must be REFUSED on a listener
    %% whose services do not include it. This is the operator requirement:
    %% offering BAMP over WebSocket without offering WAMP.
    %%
    %% It no longer exercises the ping-ABSENT path in `do_init/4'. It did while
    %% an unset `wamp_websocket' left the resolved carrier config with no
    %% `ping' key, which made the coverage an ordering dependency rather than
    %% an assertion. `bondy_listener_config:resolve_carrier_config/3' now
    %% merges `carrier_defaults/1' under every carrier key, so a resolved
    %% `websocket' config always carries a complete `ping' block and
    %% `do_init/4''s `#{enabled => false}' fallback is unreachable from here.
    Inventory = [
        {ct_wamp_only, #{
            transport => tcp,
            protocol => http,
            port => 0,
            services => [wamp_ws]
        }},
        {ct_bamp_only, #{
            transport => tcp,
            protocol => http,
            port => 0,
            services => [bamp_ws]
        }}
    ],
    %% `init/0` reads the inventory through `bondy_config`, which resolves
    %% against persistent_term — `application:set_env/3` is invisible to it
    %% unless `bondy_config:init/1` has since re-cached. Set it directly.
    ok = bondy_config:set(listeners, Inventory),
    ok = bondy_listener_manager:init(),
    %% NOT `start(all)`: `init/0` always injects the early-phase `admin` and
    %% `admin_local` listeners, both declaring `admin_api`, and compiling
    %% their dispatch table reaches `bondy_http_gateway:admin_spec/0`'s
    %% `priv_dir`/admin-realm machinery, which this suite's ranch+cowboy-only
    %% harness never boots — verified directly: `start(all)` here raises
    %% `badarg` in `app_config:maybe_badarg/1` via `admin_spec/0`, before this
    %% test's own listeners are even reached.
    %% `manager_resolves_and_starts_by_phase` above documents and avoids the
    %% same landmine. Both of this test's
    %% listeners default to `start_phase => normal`, so `start(normal)` is
    %% enough to bind them.
    ok = bondy_listener_manager:start(normal),

    WampPort = ranch:get_port(ct_wamp_only),
    BampPort = ranch:get_port(ct_bamp_only),

    ?assertMatch(
        <<"HTTP/1.1 101", _/binary>>, ws_handshake(WampPort, "wamp.2.json")
    ),
    %% Same subprotocol, different listener: refused.
    ?assertMatch(
        <<"HTTP/1.1 400", _/binary>>, ws_handshake(BampPort, "wamp.2.json")
    ),

    ok = bondy_listener_manager:stop(all).

%% Like `ws_handshake/2`, but leaves the socket OPEN and returns it instead of
%% closing it, so the caller can exchange further frames on the same
%% connection.
ws_connect(Port, Subprotocol) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 5000
    ),
    Req = [
        "GET /ws HTTP/1.1\r\n",
        "Host: localhost\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "Sec-WebSocket-Protocol: ",
        Subprotocol,
        "\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
    ?assertMatch(
        <<"HTTP/1.1 101", _/binary>>, hd(binary:split(Data, <<"\r\n">>))
    ),
    Sock.

ws_max_frame_size_is_enforced_per_listener(_Config) ->
    %% The falsification this task's design names: two listeners with
    %% different `websocket.max_frame_size`, the SAME oversized frame
    %% accepted on one and rejected on the other. Before `do_init/4' read the
    %% listener's own resolved carrier config, both listeners shared one
    %% global `wamp_websocket' block and could not disagree on this at all.
    Inventory = [
        {ct_frame_small, #{
            transport => tcp,
            protocol => http,
            port => 0,
            services => [wamp_ws]
        }},
        {ct_frame_big, #{
            transport => tcp,
            protocol => http,
            port => 0,
            services => [wamp_ws]
        }}
    ],
    ok = bondy_config:set(listeners, Inventory),
    ok = bondy_config:set(
        ct_frame_small, [{websocket, [{max_frame_size, 100}]}]
    ),
    ok = bondy_config:set(
        ct_frame_big, [{websocket, [{max_frame_size, 1048576}]}]
    ),
    ok = bondy_listener_manager:init(),
    %% NOT `start(all)`: see `ws_listener_restricted_to_one_protocol` above.
    ok = bondy_listener_manager:start(normal),

    SmallPort = ranch:get_port(ct_frame_small),
    BigPort = ranch:get_port(ct_frame_big),

    %% Larger than `ct_frame_small`'s limit, smaller than `ct_frame_big`'s.
    %% Sent as a `binary` frame, not `text`: the negotiated `wamp.2.json`
    %% frame type is `text`, so
    %% `bondy_wamp_ws_connection_handler:websocket_handle/2`'s catch-all
    %% clause ignores a `binary` frame instead of handing it to
    %% `bondy_wamp_protocol` — this keeps the assertion about frame SIZE
    %% only, never reaching the WAMP layer at all.
    Oversized = binary:copy(<<"a">>, 200),
    Frame = cow_ws:masked_frame({binary, Oversized}, #{}),

    %% Rejected. Verified directly against `cowboy_websocket.erl`: a frame
    %% header whose declared length exceeds `max_frame_size` is refused
    %% before the payload is even read (`parse_header/3`, `Len > MaxFrameSize
    %% -> websocket_close(_, _, {error, badsize})`, line 529), and
    %% `websocket_send_close/2` (line 757) frames `badsize` as an unmasked
    %% `{close, 1009, <<>>}` — 4 bytes: opcode 0x88, length 2, code 1009.
    SmallSock = ws_connect(SmallPort, "wamp.2.json"),
    ok = gen_tcp:send(SmallSock, Frame),
    {ok, CloseFrame} = gen_tcp:recv(SmallSock, 0, 5000),
    ?assertEqual(<<16#88, 2, 1009:16>>, CloseFrame),
    ok = gen_tcp:close(SmallSock),

    %% Accepted: the identical bytes, on the listener with the larger limit.
    %% A `ping` sent right after gets Cowboy's automatic `pong` back only if
    %% the connection is still alive and its WS loop is still running — proof
    %% the oversized frame was NOT rejected, rather than a timeout that could
    %% equally mean the frame was silently dropped for some other reason.
    %% `ranch:procs/2` cannot show this either way: it counts a connection as
    %% soon as it is spawned, before `init/1' runs.
    BigSock = ws_connect(BigPort, "wamp.2.json"),
    ok = gen_tcp:send(BigSock, Frame),
    ok = gen_tcp:send(BigSock, cow_ws:masked_frame(ping, #{})),
    {ok, PongFrame} = gen_tcp:recv(BigSock, 0, 5000),
    ?assertEqual(<<16#8a, 0>>, PongFrame),
    ok = gen_tcp:close(BigSock),

    ok = bondy_listener_manager:stop(all).

new_style_tls_listener_binds(_Config) ->
    %% The certificate is in the `tls` block and NOWHERE else, so this fails
    %% with `no_cert` until the block reaches ranch's socket options. Port 0:
    %% the bind target is irrelevant to what is being tested and an ephemeral
    %% port cannot collide with a parallel run.
    ok = bondy_config:set(listeners, [
        {ct_new_tls, #{
            transport => tls,
            protocol => wamp_rawsocket,
            port => 0,
            tls => #{
                certfile => "./etc/ssl/server/keycert.pem",
                keyfile => "./etc/ssl/server/key.pem",
                cacertfile => "./etc/ssl/server/cacert.pem"
            }
        }}
    ]),
    ok = bondy_listener_manager:init(),
    ok = bondy_listener_manager:start(normal),
    {ok, L} = bondy_listener_manager:listener(ct_new_tls),
    ?assertMatch(#{transport := tls}, L),
    %% Bound, not merely resolved: ask ranch for the port it actually got.
    ?assert(is_integer(ranch:get_port(ct_new_tls))),

    ok = bondy_listener_manager:stop(all).

http_versions_decide_alpn(_Config) ->
    %% The property an operator depends on, probed with a REAL handshake: the
    %% `http.versions' order decides what an h2-capable client is served,
    %% DESPITE `cowboy:start_tls/3' prepending its own h2-first
    %% `alpn_preferred_protocols' entry (`cowboy.erl:161'). It holds because
    %% ssl resolves a duplicate option to its LAST occurrence
    %% (`ssl_config:process_options/3') and `with_http_versions/3' appends.
    %% This test is what fails if that chain breaks — e.g. a cowboy upgrade
    %% that appends its entry instead of prepending it.
    {ok, _} = application:ensure_all_started(ssl),
    Tls = #{
        certfile => "./etc/ssl/server/keycert.pem",
        keyfile => "./etc/ssl/server/key.pem",
        cacertfile => "./etc/ssl/server/cacert.pem"
    },
    ok = bondy_config:set(listeners, [
        {ct_alpn_h1, #{
            transport => tls,
            protocol => http,
            port => 0,
            services => [wamp_ws],
            http_versions => [http],
            tls => Tls
        }},
        {ct_alpn_h2, #{
            transport => tls,
            protocol => http,
            port => 0,
            services => [wamp_ws],
            http_versions => [http2, http],
            tls => Tls
        }}
    ]),
    ok = bondy_listener_manager:init(),
    ok = bondy_listener_manager:start(normal),

    Connect = fun(Name, AlpnOpts) ->
        {ok, Sock} = ssl:connect(
            "127.0.0.1",
            ranch:get_port(Name),
            [binary, {active, false}, {verify, verify_none} | AlpnOpts],
            5000
        ),
        Sock
    end,
    Negotiated = fun(Name) ->
        Sock = Connect(Name, [
            {alpn_advertised_protocols, [<<"h2">>, <<"http/1.1">>]}
        ]),
        Result = ssl:negotiated_protocol(Sock),
        ok = ssl:close(Sock),
        Result
    end,

    %% h1-only listener: the client offered h2 first and did not get it.
    ?assertEqual({ok, <<"http/1.1">>}, Negotiated(ct_alpn_h1)),
    %% h2-first listener: HTTP/2 is genuinely offered, not just accepted.
    ?assertEqual({ok, <<"h2">>}, Negotiated(ct_alpn_h2)),

    %% Negotiating is not being served: `cowboy_tls' routes every non-`h2'
    %% ALPN outcome — a negotiated `http/1.1' included — through
    %% `alpn_default_protocol' (`cowboy_tls.erl:38-46'), so an h2-first
    %% listener must still name the h1 codec there. When it instead named
    %% `hd(Versions)', both requests below were answered by `cowboy_http2'
    %% with a SETTINGS frame (first bytes `<<0,0,6,4>>'), which is how the
    %% whole `bondy_connect_conformance_SUITE' wss group died.
    ServedH1 = fun(AlpnOpts) ->
        Sock = Connect(ct_alpn_h2, AlpnOpts),
        ok = ssl:send(Sock, <<"GET / HTTP/1.1\r\nHost: a\r\n\r\n">>),
        {ok, Reply} = ssl:recv(Sock, 0, 5000),
        ok = ssl:close(Sock),
        binary:part(Reply, 0, 8)
    end,
    ?assertEqual(
        <<"HTTP/1.1">>,
        ServedH1([{alpn_advertised_protocols, [<<"http/1.1">>]}]),
        "an h1-negotiating client must reach the h1 codec"
    ),
    ?assertEqual(
        <<"HTTP/1.1">>,
        ServedH1([]),
        "a no-ALPN client is an h1 client (RFC 7540 requires ALPN for h2)"
    ),

    ok = bondy_listener_manager:stop(all).

splat_merges_into_an_existing_transport_block(_Config) ->
    %% `splat/3` writes each leaf beside its siblings rather than replacing the
    %% block that holds them. Nothing in the schema now writes a listener's
    %% `transport_opts` except the splat itself, so this is no longer reachable
    %% from configuration -- it guards the property directly, because a
    %% regression to replace-semantics would silently drop whatever a caller had
    %% already put there.
    ok = bondy_config:set(
        [ct_merge, transport_opts],
        [{socket_opts, [{backlog, 4096}, {nodelay, true}]}]
    ),
    ok = bondy_config:splat_listener_blocks([
        {ct_merge, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => 0,
            transport_opts => #{num_acceptors => 7}
        }}
    ]),
    Opts = bondy_config:listener_transport_opts(ct_merge, undefined),
    ?assertEqual(7, maps:get(num_acceptors, Opts)),
    SocketOpts = maps:get(socket_opts, Opts),
    ?assertEqual(4096, key_value:get(backlog, SocketOpts)),
    ?assertEqual(true, key_value:get(nodelay, SocketOpts)).

rawsocket_linger_reaches_the_socket_as_one_second(_Config) ->
    %% The restored `linger.timeout` default, checked at the socket rather than
    %% in `option_defaults/2`. Three things have to hold in sequence for it to
    %% arrive and none of them is exercised by asserting on the defaults map:
    %% `with_option_defaults/1` has to put it in the spec, the splat has to write
    %% it under `[Name, transport_opts, socket_opts]`, and
    %% `normalise_socket_opts/1` has to turn `linger_timeout` into `inet`'s
    %% `{linger, {true, N}}` pair. It goes through the MANAGER for that reason —
    %% `bondy_listener_config:resolve/2` does not apply option defaults.
    %%
    %% `1`, not `1000`: `inet` documents that component in seconds
    %% (`kernel/src/inet.erl:1124`, OTP 28.5), and the pre-correction value was a
    %% 1000-second blocking close on every raw-socket listener.
    ok = bondy_config:set(listeners, [
        {ct_linger, #{
            transport => tcp, protocol => wamp_rawsocket, port => 0
        }}
    ]),
    ok = bondy_listener_manager:init(),
    Opts = bondy_config:listener_transport_opts(ct_linger, undefined),
    SocketOpts = maps:get(socket_opts, Opts),
    ?assertEqual({true, 1}, key_value:get(linger, SocketOpts)),
    %% And `linger_timeout` is gone from the list rather than sitting beside
    %% `linger`: it is not an `inet` option, so ranch would reject the bind.
    ?assertEqual(
        undefined, key_value:get(linger_timeout, SocketOpts, undefined)
    ),

    %% It binds. A `{linger, _}` ranch would refuse is the failure this is for.
    {ok, L} = bondy_listener_manager:listener(ct_linger),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_linger),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 5000),
    ok = gen_tcp:close(Sock),
    ok = bondy_listener:stop(L).

new_style_tls_material_is_visible_to_rotation(_Config) ->
    %% Binding already works; this is about `bondy_cert_manager` finding the
    %% same material the bind path uses. A listener whose certificate lives
    %% ONLY in its `tls` block must be rotatable, or an operator who adopts
    %% the new spelling silently loses live rotation.
    ok = bondy_config:set(listeners, [
        {ct_rotate_tls, #{
            transport => tls,
            protocol => wamp_rawsocket,
            port => 0,
            tls => #{
                certfile => "./etc/ssl/server/keycert.pem",
                keyfile => "./etc/ssl/server/key.pem"
            }
        }}
    ]),
    ok = bondy_listener_manager:init(),
    ?assertMatch(
        {ok, #{certfile := _, keyfile := _}},
        bondy_cert_manager:server_cert_from_config(ct_rotate_tls)
    ).

new_style_mtls_material_is_visible_to_rotation(_Config) ->
    %% Same defect as `new_style_tls_material_is_visible_to_rotation/1`,
    %% mTLS instead of the server certificate: a listener whose `verify` and
    %% `cacertfile` live ONLY in its `tls` block must still be found by
    %% `bondy_cert_manager`'s own mTLS bookkeeping (`get_client_auth/1`), or
    %% an operator who adopts the new spelling silently loses it — even
    %% though `verify_peer` is already enforced at the socket by the static
    %% bind (`bondy_config:with_tls_material/2`), independently of this.
    ok = bondy_config:set(listeners, [
        {ct_rotate_mtls, #{
            transport => tls,
            protocol => wamp_rawsocket,
            port => 0,
            tls => #{
                certfile => "./etc/ssl/server/keycert.pem",
                keyfile => "./etc/ssl/server/key.pem",
                cacertfile => "./etc/ssl/server/cacert.pem",
                verify => verify_peer
            }
        }}
    ]),
    ok = bondy_listener_manager:init(),
    ok = bondy_cert_manager:init(),
    ?assertMatch(
        {ok, #{verify := verify_peer, cacerts := [_ | _]}},
        bondy_cert_manager:get_client_auth(ct_rotate_mtls)
    ).

splatted_cors_and_security_headers_reach_the_consumers(_Config) ->
    %% The render → splat → consumer boundary, which no other case spans: the
    %% schema suite asserts on `bondy_router.listeners' only and says so, and
    %% both consumers predate the inventory.
    %%
    %% `bondy_config:splat/3' descends every map and writes LEAVES, so
    %% `bondy_config:get([Name, cors], _)' answers a PROPLIST while both
    %% consumers require a map. Only the four historical names escaped, because
    %% their legacy translations put a real map at `[Name, cors]' first and
    %% `key_value:put/3' merges into it — so this case uses a name with no
    %% legacy translation, which is every name an operator picks, `admin'
    %% included.
    Cors = #{
        enabled => true,
        allowed_origins => '*',
        allowed_methods => <<"GET,POST">>,
        allowed_headers => <<"content-type">>,
        max_age => <<"600">>
    },
    SecurityHeaders = #{
        enabled => true,
        hsts => <<"max-age=31536000">>,
        frame_options => <<"DENY">>,
        content_type_options => <<"nosniff">>,
        content_security_policy => undefined
    },
    Inventory = [
        {ct_headers, #{
            transport => tcp,
            protocol => http,
            port => 0,
            services => [wamp_ws],
            cors => Cors,
            security_headers => SecurityHeaders
        }}
    ],
    ok = bondy_config:set(listeners, Inventory),
    %% Splatted here rather than left to `bondy_listener_manager:init/0` below,
    %% because the two assertions between the two calls are about what the splat
    %% itself writes. The manager writes these same leaves again, plus the
    %% protocol-implied defaults this inventory does not state.
    ok = bondy_config:splat_listener_blocks(Inventory),

    %% The premise, asserted rather than assumed: what arrives at the consumer's
    %% path is a proplist. If this ever becomes a map the rest of this case
    %% stops testing anything, so it must fail loudly instead.
    ?assert(is_list(bondy_config:get([ct_headers, cors], undefined))),
    ?assert(
        is_list(bondy_config:get([ct_headers, security_headers], undefined))
    ),

    ok = bondy_listener_manager:init(),
    %% NOT `start(all)`: see `ws_listener_restricted_to_one_protocol' above.
    %% Starting is the point — `bondy_listener_ranch:protocol_opts/1' calls
    %% `bondy_http_security_headers:init/1', so a `badmap' there aborts the
    %% start as an EXCEPTION, which `bondy_app''s
    %% `ok ?= start_early_listeners()' cannot catch.
    ok = bondy_listener_manager:start(normal),
    ?assert(is_integer(ranch:get_port(ct_headers))),

    %% Cached at start, so this reads what the listener actually installed.
    Cached = bondy_http_security_headers:headers(ct_headers),
    ?assertEqual(<<"DENY">>, maps:get(<<"x-frame-options">>, Cached)),
    ?assertEqual(<<"nosniff">>, maps:get(<<"x-content-type-options">>, Cached)),
    ?assertEqual(
        <<"max-age=31536000">>,
        maps:get(<<"strict-transport-security">>, Cached)
    ),
    %% Absent, not the atom: `build_headers/1' drops an `undefined' member.
    ?assertNot(maps:is_key(<<"content-security-policy">>, Cached)),

    %% The request leg. `config_from_req/1' returned the proplist unchanged, so
    %% every one of `effective_origin/2''s three clauses failed with
    %% `function_clause' on EVERY request. A `#{ref := _}' map is all either
    %% function reads out of the request here.
    Req = #{ref => ct_headers},
    Resolved = bondy_http_cors:config_from_req(Req),
    ?assertEqual('*', maps:get(allowed_origins, Resolved)),
    ?assertEqual(<<"600">>, maps:get(max_age, Resolved)),
    %% `build_headers/2' reads `allowed_methods', `allowed_headers' and
    %% `max_age' with `maps:get/2' and no default, so reaching it at all is
    %% part of the assertion.
    CorsHeaders = bondy_http_cors:headers(Req, Resolved),
    ?assertEqual(
        <<"*">>, maps:get(<<"access-control-allow-origin">>, CorsHeaders)
    ),
    ?assertEqual(
        <<"GET,POST">>,
        maps:get(<<"access-control-allow-methods">>, CorsHeaders)
    ),
    ?assertEqual(
        <<"600">>, maps:get(<<"access-control-max-age">>, CorsHeaders)
    ),

    ok = bondy_listener_manager:stop(all).

wamp_handshake_on_a_listener_with_no_option_block(_Config) ->
    %% `listener_with_no_option_block_starts' above stops one step short: it
    %% opens a bare socket and never handshakes, so the handshake path is never
    %% entered. That path reads `[Listener, ping]' with NO default, and every
    %% `listeners.$name.ping.*' mapping is default-free, so for a name an
    %% operator chose nothing supplies the key and `app_config' raises `badarg'.
    %% The listener binds, accepts, and dies on the first client's 4 octets —
    %% which is what the guide's first example configures.
    Inventory = [
        {ct_handshake, #{
            transport => tcp, protocol => wamp_rawsocket, port => 0
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(
        Inventory, fun bondy_config:get/2
    ),
    %% The production accessor, and no block installed for this name anywhere.
    ?assertEqual(
        undefined, bondy_config:get([ct_handshake, ping], undefined)
    ),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_handshake),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 5000
    ),
    %% `MaxLen' nibble 15 (2^24) and encoding 1 (JSON), both accepted by
    %% `validate_max_len/1' and `validate_encoding/1'. The server echoes the
    %% same two nibbles on success, so a correct reply is 4 octets and cannot
    %% be confused with an error frame (whose second octet's low nibble is 0).
    ok = gen_tcp:send(Sock, <<16#7F, 15:4, 1:4, 0:8, 0:8>>),
    ?assertEqual(
        {ok, <<16#7F, 15:4, 1:4, 0:8, 0:8>>}, gen_tcp:recv(Sock, 4, 5000)
    ),
    ok = gen_tcp:close(Sock),
    ok = bondy_listener:stop(L).

rawsocket_ping_interval_comes_from_the_ping_block(_Config) ->
    %% Where the probe interval comes FROM, on the wire. The listener's own
    %% `idle_timeout` is 8h and its ping block's is 300ms, so a PING frame inside
    %% two seconds can only have come from the ping block. Read from
    %% `idle_timeout`, as `bondy_wamp_tcp_connection_handler:maybe_enable_ping/2`
    %% used to, the first probe is eight hours away and this case times out.
    %%
    %% Driven through the manager rather than `bondy_listener_config:resolve/2`:
    %% the handler reads the block from `[Name, ping]`, which nothing populates
    %% until `bondy_config:splat_listener_blocks/1` has copied it out of the
    %% inventory entry, and that is the manager's job.
    ok = bondy_config:set(listeners, [
        {ct_ping, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => 0,
            idle_timeout => 28800000,
            ping => #{
                enabled => true,
                idle_timeout => 300,
                timeout => 5000,
                max_attempts => 2
            }
        }}
    ]),
    ok = bondy_listener_manager:init(),
    %% NOT `start(all)`: `admin` and `admin_local` are both `early` and bind
    %% fixed targets, which parallel runs on one host would collide on.
    ok = bondy_listener_manager:start(normal),
    Port = ranch:get_port(ct_ping),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 5000
    ),
    %% `reset_ping/1` starts the timer on a SUCCESSFUL handshake, so the
    %% handshake has to complete before the probe is on its way.
    ok = gen_tcp:send(Sock, <<16#7F, 15:4, 1:4, 0:8, 0:8>>),
    ?assertEqual(
        {ok, <<16#7F, 15:4, 1:4, 0:8, 0:8>>}, gen_tcp:recv(Sock, 4, 5000)
    ),
    %% The RawSocket PING frame: 5 reserved bits, frame type 1, then a 24-bit
    %% length — `bondy_wamp_tcp_connection_handler.erl:883`.
    {ok, <<0:5, 1:3, Len:24>>} = gen_tcp:recv(Sock, 4, 2000),
    ?assertEqual(16, Len),
    {ok, Payload} = gen_tcp:recv(Sock, Len, 1000),
    ?assertEqual(Len, byte_size(Payload)),
    ok = gen_tcp:close(Sock),
    ok = bondy_listener_manager:stop(all).

%% A listener block in the shape a legacy `*.ip_version = 6' mapping renders:
%% `[Name, transport_opts, socket_opts, ip_version]' and no `ip' anywhere.
set_v6_listener_env(Name) ->
    bondy_config:set(Name, [
        {transport_opts, [
            {num_acceptors, 2},
            {max_connections, 128},
            {socket_opts, [{ip_version, inet6}]}
        ]},
        {proxy_protocol, [{enabled, false}]}
    ]).

ipv6_listener_binds_without_an_explicit_ip(_Config) ->
    %% `ip_version = 6' with no `ip' — the combination
    %% `api_gateway.http.ip_version = 6' produces on the legacy path, and
    %% `listeners.x.ip_version = 6' on the new one.
    %%
    %% `bondy_config:normalise_socket_opts/1' reconciles the two and prepends
    %% the family atom; anything that writes `ip' AFTER it can contradict that
    %% atom, and `gen_tcp:listen(0, [inet6, {ip, {0,0,0,0}}])' raises `badarg'
    %% (verified directly) rather than returning an error.
    ok = set_v6_listener_env(ct_v6),
    {ok, [L]} = bondy_listener_config:resolve(
        [{ct_v6, #{transport => tcp, protocol => wamp_rawsocket, port => 0}}],
        fun bondy_config:get/2
    ),
    %% Absence survives resolution: no `ip' key at all, rather than a v4
    %% wildcard that contradicts the configured family.
    ?assertNot(maps:is_key(ip, L)),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_v6),
    %% Bound on the v6 wildcard, so the v6 loopback reaches it. A connection,
    %% not a count: `ranch:procs/2' counts a process before `init/1' runs.
    {ok, Sock} = gen_tcp:connect(
        {0, 0, 0, 0, 0, 0, 0, 1}, Port, [binary, inet6], 5000
    ),
    ok = gen_tcp:close(Sock),
    ok = bondy_listener:stop(L).

explicit_ipv6_binds_without_an_ip_version(_Config) ->
    %% The third reachable case: an explicit v6 address and NO `ip_version'.
    %% `normalise_socket_opts/1' defaults the family to `inet' when the key is
    %% absent, so the address has to be the thing that decides the family —
    %% otherwise this is `[inet, {ip, {0,0,0,0,0,0,0,1}}]' and `badarg' again.
    ok = set_listener_env(ct_v6_explicit),
    {ok, [L]} = bondy_listener_config:resolve(
        [
            {ct_v6_explicit, #{
                transport => tcp,
                protocol => wamp_rawsocket,
                port => 0,
                ip => "::1"
            }}
        ],
        fun bondy_config:get/2
    ),
    ?assertEqual({0, 0, 0, 0, 0, 0, 0, 1}, maps:get(ip, L)),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_v6_explicit),
    {ok, Sock} = gen_tcp:connect(
        {0, 0, 0, 0, 0, 0, 0, 1}, Port, [binary, inet6], 5000
    ),
    ok = gen_tcp:close(Sock),
    ok = bondy_listener:stop(L).

%% A port nothing is listening on. Probed rather than hardcoded, and port 0 —
%% which every other bind case here uses — cannot express this one, because two
%% listeners have to ask for the SAME port and 0 gives each a different one.
a_free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Sock),
    ok = gen_tcp:close(Sock),
    Port.

one_port_two_addresses(_Config) ->
    %% `bondy_listener_config:assert_bind_free/2` permits one port across
    %% distinct addresses; this is what establishes the OS permits it too. The
    %% resolver agreeing with itself proves nothing.
    %%
    %% `127.0.0.1` and `::1` rather than two loopback aliases: measured on darwin
    %% 25.5, `gen_tcp:listen(0, [{ip, {127,0,0,2}}])` answers `eaddrnotavail`
    %% because only `127.0.0.1` is on `lo0`, so a 127.0.0.0/8 pair would pass on
    %% Linux and fail here.
    ok = set_listener_env(ct_share_v4),
    ok = set_v6_listener_env(ct_share_v6),
    Port = a_free_port(),
    Spec = #{transport => tcp, protocol => wamp_rawsocket, port => Port},
    %% Resolved TOGETHER, so the clash check actually runs on the pair.
    {ok, [V4, V6]} = bondy_listener_config:resolve(
        [
            {ct_share_v4, Spec#{ip => "127.0.0.1"}},
            {ct_share_v6, Spec#{ip => "::1"}}
        ],
        fun bondy_config:get/2
    ),
    ok = bondy_listener:start(V4),
    ok = bondy_listener:start(V6),
    ?assertEqual(Port, ranch:get_port(ct_share_v4)),
    ?assertEqual(Port, ranch:get_port(ct_share_v6)),
    {ok, S4} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, inet], 5000),
    {ok, S6} = gen_tcp:connect(
        {0, 0, 0, 0, 0, 0, 0, 1}, Port, [binary, inet6], 5000
    ),
    %% One connection EACH, so each listener holds its own listen socket. Both
    %% ports reading back as `Port` would also be true if one of them had lost
    %% the bind and no acceptor were running behind it.
    ok = await_connections(V4, 1),
    ok = await_connections(V6, 1),
    ok = gen_tcp:close(S4),
    ok = gen_tcp:close(S6),
    ok = bondy_listener:stop(V4),
    ok = bondy_listener:stop(V6).

%% Logger handler. Matches on `alarm_name`, which only the connection-alarm
%% reports carry, so the node's own logging does not reach the test process.
log(#{level := Level, msg := {report, #{alarm_name := Alarm}}}, Config) ->
    #{config := #{pid := Pid}} = Config,
    Pid ! {alarm_logged, Level, Alarm},
    ok;
log(_Event, _Config) ->
    ok.

connection_alarms_reach_ranch(_Config) ->
    %% `alarms/1` builds both entries from one row per threshold, so the two
    %% things a shared builder can get wrong — which threshold and which level
    %% belongs to which alarm — are what this asserts. Neither had any coverage.
    %% 125, not the 128 `set_listener_env/1` uses: both percentages of 125 land
    %% on a fraction above a half (93.75 and 112.5), so `trunc` and `round` give
    %% different answers and the truncation is actually pinned. At 128 they agree
    %% and a `round` mutant survives — measured.
    ok = bondy_config:set(ct_alarms, [
        {transport_opts, [
            {num_acceptors, 2},
            {max_connections, 125},
            {socket_opts, [{ip_version, inet}]}
        ]},
        {proxy_protocol, [{enabled, false}]}
    ]),
    {ok, [L]} = bondy_listener_config:resolve(
        [
            {ct_alarms, #{
                transport => tcp, protocol => wamp_rawsocket, port => 0
            }}
        ],
        fun bondy_config:get/2
    ),
    ok = bondy_listener:start(L),
    #{alarms := Alarms} = ranch:get_transport_options(ct_alarms),
    ?assertEqual(
        [num_connections_75, num_connections_90], lists:sort(maps:keys(Alarms))
    ),
    ?assertEqual(93, maps:get(threshold, maps:get(num_connections_75, Alarms))),
    ?assertEqual(
        112, maps:get(threshold, maps:get(num_connections_90, Alarms))
    ),

    %% The primary level is forced, so this does not depend on how the harness
    %% configured logging: `warning` would be filtered out before any handler ran
    %% if the node were set to `error`.
    #{level := Primary} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{pid => self()}}),
    try
        lists:foreach(
            fun({Alarm, Expected}) ->
                #{callback := Callback} = maps:get(Alarm, Alarms),
                ok = Callback(ct_alarms, Alarm, self(), [self()]),
                receive
                    {alarm_logged, Level, Alarm} ->
                        ?assertEqual(Expected, Level)
                after 5000 ->
                    ct:fail({no_log_event, Alarm})
                end
            end,
            [{num_connections_75, warning}, {num_connections_90, alert}]
        )
    after
        ok = logger:remove_handler(?MODULE),
        ok = logger:set_primary_config(level, Primary)
    end,
    ok = bondy_listener:stop(L).

partial_proxy_protocol_reaches_the_http_consumer(_Config) ->
    %% `listeners.$name.proxy_protocol` and `listeners.$name.proxy_protocol.mode`
    %% are two INDEPENDENT default-free mappings, so an operator who writes only
    %% `proxy_protocol = on` renders the block `[{enabled, true}]` with no
    %% `mode`. Every `bondy_http_proxy_protocol:source_ip/1` clause matches on
    %% `mode`, so the pair `init/1` → `source_ip/1` is what this exercises — the
    %% pair every request runs. Asserting on the map `init/1` returns would pass
    %% while the request path still raised `function_clause`.
    ok = bondy_config:set(ct_pp_http, [{proxy_protocol, [{enabled, true}]}]),
    %% `init/1` reads only `peer` (through `bondy_http_utils:peer/1`) and the
    %% three forwarding headers, so a map is a sufficient request here.
    Req = #{
        ref => ct_pp_http,
        peer => {{127, 0, 0, 1}, 54321},
        headers => #{}
    },
    T = bondy_http_proxy_protocol:init(Req),
    ?assertEqual(true, bondy_http_proxy_protocol:enabled(T)),
    ?assertEqual(relaxed, bondy_http_proxy_protocol:mode(T)),
    %% No `trusted_proxies` is configured, so no peer is trusted and the socket
    %% peer IS the source address — the header-spoofing guard, unchanged here.
    ?assertEqual({ok, {127, 0, 0, 1}}, bondy_http_proxy_protocol:source_ip(T)).

partial_proxy_protocol_survives_a_real_connection(_Config) ->
    %% The raw-socket half of the case above, and the half a boundary test
    %% cannot reach: `bondy_tcp_proxy_protocol:source_ip/2` runs inside
    %% `bondy_wamp_tcp_connection_handler:init/1`, so a missing `mode` kills the
    %% connection process before the handshake rather than failing a request.
    %% Note the block installed here carries NO `transport_opts` and no `ping`:
    %% a listener that states one option block does not thereby state the rest.
    ok = bondy_config:set(ct_pp_tcp, [{proxy_protocol, [{enabled, true}]}]),
    {ok, [L]} = bondy_listener_config:resolve(
        [
            {ct_pp_tcp, #{
                transport => tcp, protocol => wamp_rawsocket, port => 0
            }}
        ],
        fun(_K, D) -> D end
    ),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_pp_tcp),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 5000
    ),
    %% One send, so the PROXY line and the WAMP handshake are parsed from the
    %% same `recv`: `ranch_tcp:recv_proxy_header/2` pushes the trailing octets
    %% back with `gen_tcp:unrecv/2`, which is the branch that keeps the
    %% handshake intact. The v1 line is the grammar `ranch_proxy_header:parse/1`
    %% accepts for `TCP4`. A successful parse is what makes `source_ip/2` take
    %% its `proxy_info` clause — the one that needs `mode` and has no fallback.
    ok = gen_tcp:send(Sock, [
        <<"PROXY TCP4 192.168.0.7 127.0.0.1 56324 18082\r\n">>,
        <<16#7F, 15:4, 1:4, 0:8, 0:8>>
    ]),
    %% The server echoes the two nibbles it accepted, so a correct reply is 4
    %% octets. Reaching it means the handler got past `source_ip/2`.
    ?assertEqual(
        {ok, <<16#7F, 15:4, 1:4, 0:8, 0:8>>}, gen_tcp:recv(Sock, 4, 5000)
    ),
    ok = gen_tcp:close(Sock),
    ok = bondy_listener:stop(L).

drain_spares_the_early_phase(_Config) ->
    %% `bondy_app:prep_stop/1' suspends, then SLEEPS the whole grace period.
    %% `/ping', `/ready' and `/metrics' answer on an `early' listener, so a
    %% drain that suspended every phase would make an orchestrator read the
    %% draining node as dead and hard-kill it — the grace period inverted.
    %% Written to break the selection rule from both sides: the `normal`
    %% listener must be refused and the `early` one must still accept, and then
    %% survive `stop(normal)' too.
    ok = set_listener_env(ct_drain_early),
    ok = set_listener_env(ct_drain_normal),
    ok = bondy_config:set(listeners, [
        {ct_drain_early, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => 0,
            start_phase => early
        }},
        {ct_drain_normal, #{
            transport => tcp, protocol => wamp_rawsocket, port => 0
        }}
    ]),
    ok = bondy_listener_manager:init(),
    %% Started one by one rather than through `start(early)'/`start(normal)':
    %% `init/0' also injects the early-phase `admin' and `admin_local'
    %% listeners, and compiling their dispatch table needs machinery this
    %% ranch+cowboy-only harness never boots (see
    %% `ws_listener_restricted_to_one_protocol'). The manager's own phase
    %% selection is still what is under test — `suspend/1' and `stop/1' below go
    %% through it, and both are harmless for the two listeners that were never
    %% started, since the driver wraps each ranch call in a `catch'.
    {ok, Early} = bondy_listener_manager:listener(ct_drain_early),
    {ok, Normal} = bondy_listener_manager:listener(ct_drain_normal),
    ok = bondy_listener:start(Early),
    ok = bondy_listener:start(Normal),
    EarlyPort = ranch:get_port(ct_drain_early),
    NormalPort = ranch:get_port(ct_drain_normal),

    ok = bondy_listener_manager:suspend(normal),
    ?assertMatch(
        {error, econnrefused},
        gen_tcp:connect({127, 0, 0, 1}, NormalPort, [binary], 1000)
    ),
    {ok, Probe1} = gen_tcp:connect(
        {127, 0, 0, 1}, EarlyPort, [binary], 5000
    ),
    ok = gen_tcp:close(Probe1),

    ok = bondy_listener_manager:stop(normal),
    {ok, Probe2} = gen_tcp:connect(
        {127, 0, 0, 1}, EarlyPort, [binary], 5000
    ),
    ok = gen_tcp:close(Probe2),

    ok = bondy_listener_manager:stop(early),
    ?assertMatch(
        {error, econnrefused},
        gen_tcp:connect({127, 0, 0, 1}, EarlyPort, [binary], 1000)
    ).

%% =============================================================================
%% VIRTUAL HOSTS
%% =============================================================================

routes(vhost, _Spec, _Listener) ->
    [
        {<<"api.example.com">>, [{"/only-here", ?MODULE, #{}}]},
        {'_', [{"/everywhere", ?MODULE, #{}}]}
    ];
routes(cookies, _Spec, _Listener) ->
    [{'_', [{"/cookies", ?MODULE, #{}}]}].

%% `/cookies` parses through `bondy_http_utils:parse_cookies/1` — the function
%% under test — and answers with the count it got, so a case can tell "the
%% limit was applied and the request still succeeded" from "the limit rejected
%% the request". Over the limit that call raises, which Cowboy answers with a
%% 400 (`cowboy_stream_h:info/3`'s `request_error` clause maps every reason but
%% `timeout` and `payload_too_large` to 400).
init(#{path := <<"/cookies">>} = Req, State) ->
    Count = length(bondy_http_utils:parse_cookies(Req)),
    Headers = #{<<"x-cookie-count">> => integer_to_binary(Count)},
    {ok, cowboy_req:reply(204, Headers, <<>>, Req), State};
init(Req, State) ->
    {ok, cowboy_req:reply(204, Req), State}.

%% A bare HTTP/1.1 GET with an explicit Host header, answering with the status
%% code alone. Raw `gen_tcp` rather than an HTTP client because the Host header
%% IS the subject: a client that derives it from the connection address could not
%% express these four requests.
http_status(Port, Host, Path) ->
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
    {ok, <<"HTTP/1.1 ", Code:3/binary>>} = gen_tcp:recv(Sock, 12, 5000),
    ok = gen_tcp:close(Sock),
    binary_to_integer(Code).

virtual_hosts_are_routed_independently(_Config) ->
    %% The wire-level proof that a route set's HOST is honoured, and the
    %% falsification of the two ordering rules `bondy_http_services` derives from
    %% `cowboy_router`'s source.
    %%
    %% One carrier contributes both a named host and `'_'`. Cowboy commits to the
    %% first host entry whose host matches and never falls through
    %% (`match_path([], _, _, _)` answers `{error, notfound, path}`,
    %% `cowboy_router.erl:253`), so:
    %%
    %%   * `/everywhere` on `api.example.com` answers ONLY because every `'_'`
    %%     route is replicated into each named host entry. Without that it is
    %%     404 — which is what a specification-declared host did before this
    %%     branch, taking `/ws` and `/metrics` off that host.
    %%   * `/only-here` on `api.example.com` answers ONLY because the `'_'` entry
    %%     is emitted LAST. `'_'` matches unconditionally
    %%     (`cowboy_router.erl:225`), so emitted first it would swallow the
    %%     request and 404.
    ok = application:set_env(bondy_router, http_services, [
        {vhost, #{carrier => vhost, protocol => undefined}}
    ]),
    ok = application:set_env(bondy_router, http_carriers, [{vhost, ?MODULE}]),
    ok = bondy_config:set(listeners, [
        {ct_vhost, #{
            transport => tcp, protocol => http, port => 0, services => [vhost]
        }}
    ]),
    try
        ok = bondy_listener_manager:init(),
        ok = bondy_listener_manager:start(normal),
        Port = ranch:get_port(ct_vhost),

        %% Replication: a listener-wide route reaches the named host.
        ?assertEqual(204, http_status(Port, "api.example.com", "/everywhere")),
        %% Ordering: the named host's own route is reachable at all.
        ?assertEqual(204, http_status(Port, "api.example.com", "/only-here")),
        %% Confinement: it is reachable NOWHERE else, which is the point of
        %% declaring a host.
        ?assertEqual(404, http_status(Port, "other.example.com", "/only-here")),
        %% And the listener-wide route still answers on every other host.
        ?assertEqual(
            204, http_status(Port, "other.example.com", "/everywhere")
        ),

        ok = bondy_listener_manager:stop(all)
    after
        ok = application:unset_env(bondy_router, http_services),
        ok = application:unset_env(bondy_router, http_carriers)
    end.

%% =============================================================================
%% COOKIE LIMIT
%% =============================================================================

max_cookies_is_enforced_per_listener(_Config) ->
    %% `listeners.$name.http.max_cookies` is the one key in the `http.` block
    %% Cowboy's protocol loop does not read: cowlib takes the limit per call
    %% (`cow_cookie:parse_cookie/2`), so it only reaches a request because
    %% `bondy_http_utils:parse_cookies/1` reads it back out of the listener's
    %% `protocol_opts` and passes it to `cowboy_req:parse_cookies/2`. Handing
    %% the option to Cowboy and asserting on the resolved configuration would
    %% therefore both pass with the read site deleted; only a request proves it.
    %%
    %% Two listeners, because the option has two live values and each needs its
    %% own socket: what an operator wrote, and — since every
    %% `listeners.$name.*` mapping is default-free — the 100 cowlib applies when
    %% nothing was written. The second half is not decoration: unbounded cookie
    %% parsing is what Bondy did before cowboy 2.18, so `ct_cookies_default`
    %% pins the new upstream limit reaching a listener nobody configured.
    ok = application:set_env(bondy_router, http_services, [
        {cookies, #{carrier => cookies, protocol => undefined}}
    ]),
    ok = application:set_env(bondy_router, http_carriers, [{cookies, ?MODULE}]),
    ok = bondy_config:set(listeners, [
        {ct_cookies_limited, #{
            transport => tcp,
            protocol => http,
            port => 0,
            services => [cookies],
            protocol_opts => #{max_cookies => 2}
        }},
        {ct_cookies_default, #{
            transport => tcp, protocol => http, port => 0, services => [cookies]
        }}
    ]),
    try
        ok = bondy_listener_manager:init(),
        ok = bondy_listener_manager:start(normal),
        Limited = ranch:get_port(ct_cookies_limited),
        Default = ranch:get_port(ct_cookies_default),

        %% At the limit the request succeeds AND every cookie is returned, so
        %% this cannot pass by silently truncating the list.
        ?assertEqual({204, 2}, cookie_response(Limited, 2)),
        %% One over, and cowlib raises `limit_reached`, which Cowboy answers
        %% with a 400 rather than by dropping the extra cookie.
        ?assertEqual({400, undefined}, cookie_response(Limited, 3)),

        %% The same two assertions either side of cowlib's own 100, on a
        %% listener that configured nothing.
        ?assertEqual({204, 100}, cookie_response(Default, 100)),
        ?assertEqual({400, undefined}, cookie_response(Default, 101)),

        %% The limit belongs to the listener, not to the node: 3 cookies are
        %% refused on one socket and accepted on the other in the same run.
        ?assertEqual({204, 3}, cookie_response(Default, 3)),

        ok = bondy_listener_manager:stop(all)
    after
        ok = application:unset_env(bondy_router, http_services),
        ok = application:unset_env(bondy_router, http_carriers)
    end.

%% A GET of `/cookies` carrying `N` distinct cookies in one `Cookie` header,
%% answering `{Status, Count | undefined}` where `Count` is what
%% `bondy_http_utils:parse_cookies/1` returned. Raw `gen_tcp` for the same
%% reason `http_status/3` uses it: the request header IS the subject, and an
%% HTTP client with its own cookie jar would not send this one verbatim.
%%
%% `N` cookies of the form `cN=1` stay well under the 4096-byte
%% `max_header_value_length` Cowboy defaults to at N = 101 (~800 bytes), so a
%% 400 here is the cookie COUNT limit and not the header SIZE limit.
cookie_response(Port, N) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 5000
    ),
    Cookies = lists:join(
        "; ", ["c" ++ integer_to_list(I) ++ "=1" || I <- lists:seq(1, N)]
    ),
    ok = gen_tcp:send(Sock, [
        "GET /cookies HTTP/1.1\r\n",
        "Host: localhost\r\n",
        "Cookie: ",
        Cookies,
        "\r\n",
        "Connection: close\r\n\r\n"
    ]),
    Response = recv_until_closed(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Response,
    {binary_to_integer(Code), cookie_count(Response)}.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Bin} ->
            recv_until_closed(Sock, <<Acc/binary, Bin/binary>>);
        {error, closed} ->
            Acc
    end.

cookie_count(Response) ->
    Name = <<"x-cookie-count: ">>,
    case binary:match(Response, Name) of
        nomatch ->
            undefined;
        {Start, Len} ->
            At = Start + Len,
            Rest = binary:part(Response, At, byte_size(Response) - At),
            [Value | _] = binary:split(Rest, <<"\r\n">>),
            binary_to_integer(Value)
    end.
