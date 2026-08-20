%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_listener_boot_SUITE).

-moduledoc """
Boots one node whose listeners come ONLY from the `bondy_router.listeners`
inventory — the configured path — and asserts against the booted state:

  1. the configured path was actually taken (the provenance gate);
  2. no listener the manager resolved fell back to the legacy path;
  3. the resolved set is exactly the declared inventory plus the injected
     `admin_local`, and a legacy-only name is absent;
  4. traffic completes: a real WAMP raw-socket handshake against a declared
     listener, and a real HTTP request against the declared `admin` listener.

This complements, rather than repeats, the coverage at the two ends of this
path: `bondy_listener_schema_SUITE` renders `listeners.$name.*` through
cuttlefish and boots nothing; `bondy_listener_SUITE` drives
`bondy_listener_config` and `bondy_listener_manager` directly against real
sockets and its own `init_per_suite/1` says outright that it does not call
`bondy_config:init/1`; `bondy_admin_listener_SUITE` boots a full node but
deliberately pins the LEGACY path. None of the three boots a node whose
listeners come from the inventory and then asserts anything about the result.

The peer is booted through `bondy_ct:start_cluster/2`'s `{Name, ExtraEnv}`
form, which overrides `[bondy_router, listeners]` on that one peer only —
`bondy_ct`'s shared `?ENV` and `start_bondy/0` are untouched, so every other
suite in the same `rebar3 ct` run keeps booting the legacy path this suite is
not exercising.

Two things this suite does NOT exercise, because of what it is: it boots
exactly ONE node, so it says nothing about two nodes agreeing on an inventory;
and every assertion below runs against the STEADY STATE after boot has
already returned `ok`, not against any ordering internal to
`bondy_config:init/1` (for instance the relative order of the legacy-key
splat and `bondy_listener_manager:init/0`, which `bondy_ct:node_env/2`
documents as a hazard for a different listener).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([suite/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([configured_path_was_taken/1]).
-export([resolved_set_matches_the_declared_inventory/1]).
-export([traffic_completes_on_the_declared_listeners/1]).

-define(NODE_NAME, bondy_listener_boot1).
-define(RAW_LISTENER, boot_probe_raw).

%% Only combinations `bondy_listener_config` resolves: `tcp`/`tls`/`uds` on the
%% transport axis, `http`/`wamp_rawsocket`/`bridge_relay` on the protocol axis,
%% with `uds` + `bridge_relay` refused by `assert_transport_protocol/3`.
%%
%% `admin` is declared explicitly, at `port => 0`, rather than left for
%% `bondy_listener_manager:with_reserved/1` to inject: an inventory that omits
%% it gets the reserved default at its hardcoded port, which collides with
%% whatever this OS process is already bound to. `?RAW_LISTENER` carries no
%% `ping` block at all — `bondy_listener_config:assert_listener_ping/3` accepts
%% that (absent) and refuses a PARTIAL one, and this suite is not about ping.
-define(INVENTORY, [
    {admin, #{
        transport => tcp,
        protocol => http,
        port => 0,
        start_phase => early,
        services => [admin_api, wamp_ws, admin, metrics]
    }},
    {?RAW_LISTENER, #{
        transport => tcp,
        protocol => wamp_rawsocket,
        port => 0
    }}
]).

all() ->
    [
        configured_path_was_taken,
        resolved_set_matches_the_declared_inventory,
        traffic_completes_on_the_declared_listeners
    ].

suite() ->
    [{timetrap, {minutes, 5}}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    [{Name, Node, Peer}] = bondy_ct:start_cluster(
        [{?NODE_NAME, [{[bondy_router, listeners], ?INVENTORY}]}], Config
    ),
    [{node, Node}, {name, Name}, {peer, Peer} | Config].

end_per_suite(Config) ->
    Name = ?config(name, Config),
    Node = ?config(node, Config),
    Peer = ?config(peer, Config),
    try
        bondy_ct:stop_cluster([{Name, Node, Peer}])
    catch
        _:_ -> ok
    end,
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

%% The provenance gate: an ABSENT `listeners` key is what `init/0` reads as
%% legacy, so a list (rather than `undefined`) is what proves this peer took
%% the configured path at all.
configured_path_was_taken(Config) ->
    Node = ?config(node, Config),
    Listeners = erpc:call(Node, bondy_config, get, [listeners, undefined]),
    ?assertNotEqual(undefined, Listeners),
    ?assert(is_list(Listeners)).

%% The resolved set is exactly what was declared plus the one listener no
%% inventory can omit (`admin_local`) — nothing more, nothing fewer. In
%% particular a legacy-only name (`wamp_tcp`, part of the nine hardcoded
%% listeners this branch replaced) must be absent: a node on the configured
%% path must not also start the hardcoded set.
resolved_set_matches_the_declared_inventory(Config) ->
    Node = ?config(node, Config),
    Resolved = erpc:call(Node, bondy_listener_manager, listeners, []),
    Names = [maps:get(name, L) || L <- Resolved],
    ?assertEqual(
        lists:sort([admin, ?RAW_LISTENER, admin_local]), lists:sort(Names)
    ),
    ?assertNot(lists:member(wamp_tcp, Names)).

%% The half no render-and-resolve test can reach: a real WAMP handshake
%% against the declared raw-socket listener, and a real HTTP request against
%% the declared `admin` listener. Ports come from `ranch:get_port/1` on the
%% peer, never from a literal: every listener here is declared `port => 0`, so
%% `bondy_listener_manager:listener/1`'s `bind` field still reads `{port, 0}`
%% after boot — it carries the CONFIGURED target, not what the OS actually
%% assigned. `ranch:get_port/1` is what ranch itself resolved that to; it
%% raises `badarg` for a listener that never bound, which distinguishes "wrong
%% port" from "never started" rather than confusing the two under
%% `econnrefused`.
traffic_completes_on_the_declared_listeners(Config) ->
    Node = ?config(node, Config),

    RawPort = erpc:call(Node, ranch, get_port, [?RAW_LISTENER]),
    ok = assert_wamp_rawsocket_handshake(RawPort),

    AdminPort = erpc:call(Node, ranch, get_port, [admin]),
    ?assertEqual(204, admin_get(AdminPort, "/ping")).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% The WAMP raw-socket handshake: `MaxLen` nibble 15 (2^24) and encoding 1
%% (JSON), both accepted by `validate_max_len/1' and `validate_encoding/1' in
%% the connection handler. On success the server echoes the same two nibbles,
%% which cannot be confused with an error frame (whose second octet's low
%% nibble is 0). Mirrors
%% `bondy_listener_SUITE:wamp_handshake_on_a_listener_with_no_option_block/1`.
assert_wamp_rawsocket_handshake(Port) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, <<16#7F, 15:4, 1:4, 0:8, 0:8>>),
    Result = gen_tcp:recv(Sock, 4, 5000),
    ok = gen_tcp:close(Sock),
    ?assertEqual({ok, <<16#7F, 15:4, 1:4, 0:8, 0:8>>}, Result).

%% `/ping` comes from the `admin` service and replies 204 with no
%% authentication (`bondy_admin_ping_http_handler:init/2`). Mirrors
%% `bondy_admin_listener_SUITE:get_path/2`.
admin_get(Port, Path) ->
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), Path]),
    {ok, Status, _, _} = hackney:request(get, Url, [], <<>>, []),
    Status.
