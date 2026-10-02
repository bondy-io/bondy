%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_boot_probes_SUITE).

-moduledoc """
Holds a booting node inside the open of its durable `main` store and asserts
what its `early` `admin` listener answers there: `/ping` 204, `/ready` 503,
and none of the routes whose handlers need the router (`/ws`, `/metrics`).
Once the open is released and boot completes, the same listener serves its
full route set and `/ready` answers 204.

The stall is `bondy_ct:stall_main_open/1`, a pre-boot hook that mocks
`bondy_namespace_catalog:init/1` on the peer to block until the testcase
releases it; `init/1` is where `main` opens, inside `bondy_router_sup:start_link/0`.
A node that binds its early listeners only after that point answers `/ping`
with a refused connection, and `probes_answer_while_main_opens` fails on its
first assertion.

Not covered: a store whose open actually takes minutes, and an open that
fails (`bondy_degraded_boot_SUITE`).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([suite/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([probes_answer_while_main_opens/1]).

-define(NODE_NAME, bondy_boot_probes1).

suite() -> [{timetrap, {minutes, 5}}].

all() ->
    [probes_answer_while_main_opens].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    Config.

end_per_suite(_Config) ->
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

probes_answer_while_main_opens(Config) ->
    Gate = self(),
    Hook = {bondy_ct, stall_main_open, [Gate]},
    Booter = spawn_link(fun() ->
        Nodes = bondy_ct:start_nodes(
            [{?NODE_NAME, [{[bondy_ct, pre_boot], Hook}]}], Config
        ),
        Gate ! {booted, Nodes}
    end),
    {Node, Catalog} =
        receive
            {main_opening, N, Pid} -> {N, Pid}
        after 60_000 -> error(main_open_never_reached)
        end,
    try
        ?assertEqual(204, admin_get(Node, "/ping")),
        ?assertEqual(503, admin_get(Node, "/ready")),
        ?assertEqual(404, admin_get(Node, "/ws")),
        ?assertEqual(404, admin_get(Node, "/metrics")),

        Catalog ! release,
        receive
            {booted, _} -> ok
        after 60_000 -> error({boot_never_finished, Booter})
        end,

        ?assertEqual(204, admin_get(Node, "/ping")),
        ?assertEqual(204, admin_get(Node, "/ready")),
        ?assertNotEqual(404, admin_get(Node, "/ws")),
        ?assertEqual(200, admin_get(Node, "/metrics"))
    after
        unlink(Booter),
        halt_peer(Node)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% The peer's `admin` listener binds `port => 0` (`bondy_ct:node_env/2`), so
%% the port is read from ranch.
admin_get(Node, Path) ->
    Port = erpc:call(Node, ranch, get_port, [admin]),
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), Path]),
    {ok, Status, _, _} = hackney:request(get, Url, [], <<>>, []),
    Status.

%% @private
%% `erpc` reports the halted node as a lost connection.
halt_peer(Node) ->
    try
        erpc:call(Node, erlang, halt, [], 5000)
    catch
        error:{erpc, _} -> ok
    end.
