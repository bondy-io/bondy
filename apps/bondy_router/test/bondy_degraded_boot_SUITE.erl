%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_degraded_boot_SUITE).

-moduledoc """
Boots one node whose durable `main` database CANNOT open — a regular file
squats on the directory `bondy_namespace_catalog` will try to create — and
asserts the degraded posture `bondy_router_app:start_services/1` documents actually
holds end-to-end, next to an identically configured CONTROL node whose store
opens fine.

The degraded contract on this branch:

  1. the node STANDS UP: `bondy_router` is running, `main_status/0` is
     `failed`, the `bondy_db_main_unavailable` alarm is raised;
  2. it does NOT present itself as ready: `bondy_router_app:is_ready/0` — the one
     oracle the `/ready` probe and the `bondy_node_ready` gauge answer from —
     is `false`, and the real `/ready` endpoint on the `early` `admin`
     listener answers 503; `bondy_config:get(status)` stays `initialising`
     because only `start_normal_listeners/0` promotes it;
  3. only the `early` listeners are bound — the `normal`-phase listener in
     the peer inventory never opens — and the bridge-relay manager, a
     `bondy_router_sup` child that is up on every boot, holds no bridges because its
     store load is part of `start_bridges/0`, which the degraded path never
     calls;
  4. the supervision tree HOLDS over a window: the pre-fix failure modes were
     a VM halt (`configure_services/0` raising through `bondy_router_app:start/2`,
     observed in production on 2026-09-02) and a crash loop
     (`bondy_bridge_relay_manager` reading the store from its `init/1`
     continuation until `reached_max_restart_intensity` collapsed
     `bondy_router_sup`);
  5. durable operations fail with their documented error instead of killing
     the node, and the ephemeral registry half is alive.

The whole boot runs against the poisoned directory, so any OTHER boot-path
consumer of the durable tables that raises fails `init_per_suite/1` here —
the suite covers the property, not the call sites that were fixed. The
control node pins the other half of every gate: a healthy node takes the
durable path, IS ready, and has all of its listeners.

Why this is a CT suite and not only `bondy_router_app_degraded_boot_test`: that
eunit module mocks the catalogue and the listener manager and can only
assert which branch `start_services/1` takes. It cannot see a `bondy_router_sup`
child that reads the store on its own, nor what the probe actually answers.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([suite/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([node_stands_up_degraded/1]).
-export([node_is_not_ready/1]).
-export([only_early_listeners_and_no_bridges/1]).
-export([supervision_tree_holds/1]).
-export([durable_ops_fail_cleanly_and_registry_works/1]).
-export([healthy_control_takes_the_durable_path/1]).
-export([main_is_not_open_while_it_closes_or_opens/1]).
-export([main_closes_cleanly_however_long_it_takes/1]).
-export([a_leftover_handle_is_not_open/1]).
-export([a_reopened_main_is_no_longer_failed/1]).
-export([a_serving_node_is_not_ready_until_main_reopens/1]).

-define(NODE_NAME, bondy_degraded1).
-define(CONTROL_NODE_NAME, bondy_degraded_ctrl).
-define(MASTER_REALM_URI, <<"com.leapsight.bondy">>).
%% The `normal`-phase listener every CT peer declares
%% (`bondy_ct:node_env/2`); `admin` and the injected `admin_local` are the
%% `early` ones.
-define(NORMAL_LISTENER, ordering_probe_tls).

suite() -> [{timetrap, {minutes, 5}}].

all() ->
    [
        node_stands_up_degraded,
        node_is_not_ready,
        only_early_listeners_and_no_bridges,
        supervision_tree_holds,
        durable_ops_fail_cleanly_and_registry_works,
        healthy_control_takes_the_durable_path,
        main_is_not_open_while_it_closes_or_opens,
        main_closes_cleanly_however_long_it_takes,
        %% Last: they restart the degraded node's catalogue, repair it, and
        %% break the control.
        a_leftover_handle_is_not_open,
        a_reopened_main_is_no_longer_failed,
        a_serving_node_is_not_ready_until_main_reopens
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    PrivDir = ?config(priv_dir, Config),
    %% `bondy_ct:start_node/5` gives the peer `<priv>/<name>` as its
    %% `platform_data_dir`, so the main DB directory it will try to create is
    %% `<priv>/<name>/bondy_db/main`. Squat a regular file there BEFORE the
    %% boot: `filelib:ensure_path/1` then fails, only for `main` — the `wal`
    %% and `mst` siblings and everything else under the data dir stay usable.
    %% The second node is the untouched CONTROL.
    DataDir = filename:join(PrivDir, atom_to_list(?NODE_NAME)),
    ok = filelib:ensure_path(filename:join(DataDir, "bondy_db")),
    ok = file:write_file(
        filename:join([DataDir, "bondy_db", "main"]), <<"squatter">>
    ),
    Nodes = bondy_ct:start_cluster([?NODE_NAME, ?CONTROL_NODE_NAME], Config),
    [{nodes, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(nodes, Config)).

%% =============================================================================
%% TESTS
%% =============================================================================

node_stands_up_degraded(Config) ->
    Node = degraded_node(Config),
    ?assertEqual(
        failed, erpc:call(Node, bondy_namespace_catalog, main_status, [])
    ),
    Running = [
        A
     || {A, _, _} <- erpc:call(Node, application, which_applications, [])
    ],
    ?assert(lists:member(bondy_router, Running)),
    Alarms = erpc:call(Node, bondy_alarm_handler, get_alarms, []),
    ?assert(lists:keymember(bondy_db_main_unavailable, 1, Alarms)).

%% Both inputs to the oracle, the oracle, and the probe that serves it.
node_is_not_ready(Config) ->
    Node = degraded_node(Config),
    %% `start_normal_listeners/0` is what promotes the status; the degraded
    %% path stops before it.
    ?assertEqual(
        initialising, erpc:call(Node, bondy_config, get, [status, undefined])
    ),
    ?assertNot(erpc:call(Node, bondy_router_app, is_ready, [])),
    %% The probe itself, over HTTP, on the `early` admin listener — which
    %% must therefore be bound on a degraded node for the probe to exist.
    ?assertEqual(503, admin_get(Node, "/ready")),
    %% Liveness is served from the same listener: the node is inspectable.
    ?assertEqual(204, admin_get(Node, "/ping")).

only_early_listeners_and_no_bridges(Config) ->
    Node = degraded_node(Config),
    Bound = bound_listeners(Node),
    ?assert(lists:member(admin, Bound)),
    ?assert(lists:member(admin_local, Bound)),
    ?assertNot(lists:member(?NORMAL_LISTENER, Bound)),
    %% Declared, so its absence above is the phase gate and not a missing
    %% inventory entry.
    ?assertMatch(
        {ok, _},
        erpc:call(Node, bondy_listener_manager, listener, [?NORMAL_LISTENER])
    ),
    %% The manager is up (a `bondy_router_sup` child) and has read nothing.
    ?assert(
        is_pid(erpc:call(Node, erlang, whereis, [bondy_bridge_relay_manager]))
    ),
    ?assertEqual(
        [], erpc:call(Node, bondy_bridge_relay_manager, list_bridges, [])
    ).

supervision_tree_holds(Config) ->
    Node = degraded_node(Config),
    Pids0 = supervised_pids(Node),
    lists:foreach(fun(P) -> ?assert(is_pid(P)) end, Pids0),
    %% The pre-fix bridge-relay failure was a crash LOOP, so liveness is
    %% asserted across a window, not at an instant: the same pids after the
    %% window means no process in the set was restarted during it.
    ok = timer:sleep(3000),
    ?assertEqual(Pids0, supervised_pids(Node)).

durable_ops_fail_cleanly_and_registry_works(Config) ->
    Node = degraded_node(Config),
    %% A durable operation raises its documented error — it does not kill the
    %% node (the calls after it still answer).
    ?assertError(
        {exception, bondy_realm_table_unavailable, _},
        erpc:call(Node, bondy_realm, get, [?MASTER_REALM_URI])
    ),
    %% The ephemeral half is alive: the registry answers.
    ?assert(is_map(erpc:call(Node, bondy_registry, info, []))),
    ?assertEqual(
        failed, erpc:call(Node, bondy_namespace_catalog, main_status, [])
    ).

%% The CONTROL: an identically configured node whose main DB opens fine must
%% take the durable path, not the degraded one — the master realm exists
%% right after boot WITHOUT lazy creation (`bondy_realm:lookup/1` never
%% creates), `main_status/0` is `open`, no main-unavailable alarm is raised,
%% every declared listener is bound, and the node IS ready by the oracle and
%% by the probe. This is what pins the dispatch to `failed` rather than to
%% merely "not raising": a dispatch inverted to always-degrade boots too.
healthy_control_takes_the_durable_path(Config) ->
    Node = control_node(Config),
    ?assertEqual(
        open, erpc:call(Node, bondy_namespace_catalog, main_status, [])
    ),
    ?assertMatch(
        {ok, _}, erpc:call(Node, bondy_realm, lookup, [?MASTER_REALM_URI])
    ),
    Alarms = erpc:call(Node, bondy_alarm_handler, get_alarms, []),
    ?assertNot(lists:keymember(bondy_db_main_unavailable, 1, Alarms)),
    ?assertEqual(
        ready, erpc:call(Node, bondy_config, get, [status, undefined])
    ),
    ?assert(erpc:call(Node, bondy_router_app, is_ready, [])),
    ?assertEqual(204, admin_get(Node, "/ready")),
    Bound = bound_listeners(Node),
    ?assert(lists:member(admin, Bound)),
    ?assert(lists:member(admin_local, Bound)),
    ?assert(lists:member(?NORMAL_LISTENER, Bound)).

%% The handle is withdrawn before anything closes and published only once the
%% drain gates are released, so `main` is not reported open while the
%% catalogue is inside either.
main_is_not_open_while_it_closes_or_opens(Config) ->
    Node = control_node(Config),
    ok = erpc:call(Node, meck, new, [bondy_db, [passthrough, no_link]]),
    try
        ok = hold(Node, close),
        ok = while_held(fun() -> stop_catalogue(Node) end, Node),
        ok = hold(Node, start_draining),
        ok = while_held(fun() -> start_catalogue(Node) end, Node)
    after
        erpc:call(Node, meck, unload, [bondy_db])
    end,
    ?assertEqual(
        open, erpc:call(Node, bondy_namespace_catalog, main_status, [])
    ).

%% Stopping the catalogue closes every `main` Bookie, however long the closes
%% take together: here they take longer than 5 s. A Bookie cut short exits
%% `shutdown` instead of `normal`.
main_closes_cleanly_however_long_it_takes(Config) ->
    Node = control_node(Config),
    #{topology_state := #{sup := Sup}} = erpc:call(
        Node, persistent_term, get, [{bondy_namespace_catalog, db, main}]
    ),
    Bookies = erpc:call(Node, bondy_db_leveled_sup, bookies, [Sup]),
    Delay = 6000 div length(Bookies) + 1,
    ok = erpc:call(Node, meck, new, [leveled_bookie, [passthrough, no_link]]),
    try
        ok = erpc:call(Node, meck, expect, [
            leveled_bookie,
            book_close,
            fun(Bookie) ->
                timer:sleep(Delay),
                meck:passthrough([Bookie])
            end
        ]),
        Mons = [{B, erlang:monitor(process, B)} || B <- Bookies],
        ok = stop_catalogue(Node),
        Exits = [
            receive
                {'DOWN', M, process, B, R} -> R
            after 30000 -> still_up
            end
         || {B, M} <- Mons
        ],
        ?assertEqual([normal], lists:usort(Exits))
    after
        erpc:call(Node, meck, unload, [leveled_bookie])
    end,
    ok = start_catalogue(Node),
    ?assertEqual(
        open, erpc:call(Node, bondy_namespace_catalog, main_status, [])
    ).

%% A catalogue that dies without running `terminate/2` leaves its handle
%% published. The next one withdraws it before opening, so a failed open is
%% not read as `open`.
a_leftover_handle_is_not_open(Config) ->
    Node = degraded_node(Config),
    ok = stop_catalogue(Node),
    ok = erpc:call(
        Node, persistent_term, put, [{bondy_namespace_catalog, db, main}, stale]
    ),
    ok = start_catalogue(Node),
    ?assertEqual(
        failed, erpc:call(Node, bondy_namespace_catalog, main_status, [])
    ),
    ?assertNot(erpc:call(Node, bondy_router_app, is_ready, [])).

%% Once the squatter is gone, a restarted catalogue opens `main`, and neither
%% the status nor the alarm may still report the earlier failure. The node
%% stays NOT READY: its boot stopped at `start_services(failed)`, so its
%% realms were never configured.
a_reopened_main_is_no_longer_failed(Config) ->
    Node = degraded_node(Config),
    DataDir = filename:join(
        ?config(priv_dir, Config), atom_to_list(?NODE_NAME)
    ),
    ok = file:delete(filename:join([DataDir, "bondy_db", "main"])),
    ok = stop_catalogue(Node),
    ok = start_catalogue(Node),
    ?assertEqual(
        open, erpc:call(Node, bondy_namespace_catalog, main_status, [])
    ),
    Alarms = erpc:call(Node, bondy_alarm_handler, get_alarms, []),
    ?assertNot(lists:keymember(bondy_db_main_unavailable, 1, Alarms)),
    ?assertNot(erpc:call(Node, bondy_router_app, is_ready, [])).

%% A node that booted ready is NOT READY from the moment its catalogue stops
%% until a restarted catalogue has opened `main` again, including while a
%% reopen is failing.
a_serving_node_is_not_ready_until_main_reopens(Config) ->
    Node = control_node(Config),
    MainDir = filename:join([
        ?config(priv_dir, Config),
        atom_to_list(?CONTROL_NODE_NAME),
        "bondy_db",
        "main"
    ]),
    Aside = MainDir ++ ".aside",
    ok = stop_catalogue(Node),
    ?assertNot(erpc:call(Node, bondy_router_app, is_ready, [])),
    ok = file:rename(MainDir, Aside),
    ok = file:write_file(MainDir, <<"squatter">>),
    ok = start_catalogue(Node),
    ?assertEqual(
        failed, erpc:call(Node, bondy_namespace_catalog, main_status, [])
    ),
    ?assertNot(erpc:call(Node, bondy_router_app, is_ready, [])),
    ok = stop_catalogue(Node),
    ok = file:delete(MainDir),
    ok = file:rename(Aside, MainDir),
    ok = start_catalogue(Node),
    ?assertEqual(
        open, erpc:call(Node, bondy_namespace_catalog, main_status, [])
    ),
    Alarms = erpc:call(Node, bondy_alarm_handler, get_alarms, []),
    ?assertNot(lists:keymember(bondy_db_main_unavailable, 1, Alarms)),
    ?assert(erpc:call(Node, bondy_router_app, is_ready, [])).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
degraded_node(Config) ->
    {_, Node, _} = lists:keyfind(?NODE_NAME, 1, ?config(nodes, Config)),
    Node.

%% @private
control_node(Config) ->
    {_, Node, _} = lists:keyfind(?CONTROL_NODE_NAME, 1, ?config(nodes, Config)),
    Node.

%% @private
stop_catalogue(Node) ->
    erpc:call(
        Node, supervisor, terminate_child, [
            bondy_router_sup, bondy_namespace_catalog
        ]
    ).

%% @private
start_catalogue(Node) ->
    {ok, _} = erpc:call(
        Node, supervisor, restart_child, [
            bondy_router_sup, bondy_namespace_catalog
        ]
    ),
    ok.

%% @private
%% Every call to `bondy_db:Fun/1` on `Node` waits for the test to release it.
hold(Node, Fun) ->
    Test = self(),
    erpc:call(Node, meck, expect, [
        bondy_db,
        Fun,
        fun(Arg) ->
            Test ! {held, self()},
            receive
                release -> meck:passthrough([Arg])
            end
        end
    ]).

%% @private
%% Runs `Action`, asserting at each held call that `main` is not open.
while_held(Action, Node) ->
    {_, Ref} = spawn_monitor(fun() -> ok = Action() end),
    while_held_loop(Ref, Node, 0).

%% @private
while_held_loop(Ref, Node, Held) ->
    receive
        {held, Pid} ->
            ?assertEqual(
                failed,
                erpc:call(Node, bondy_namespace_catalog, main_status, [])
            ),
            Pid ! release,
            while_held_loop(Ref, Node, Held + 1);
        {'DOWN', Ref, process, _, normal} ->
            ?assert(Held > 0),
            ok;
        {'DOWN', Ref, process, _, Reason} ->
            error(Reason)
    after 30000 ->
        error(timeout)
    end.

%% @private
%% The processes whose death was each pre-fix failure mode, plus the root
%% supervisor they would have taken down.
supervised_pids(Node) ->
    [
        erpc:call(Node, erlang, whereis, [Name])
     || Name <- [
            bondy_router_sup,
            bondy_namespace_catalog,
            bondy_bridge_relay_manager
        ]
    ].

%% @private
%% What ranch actually has bound on the node — the listeners that started,
%% as opposed to the inventory `bondy_listener_manager:listeners/0` resolved.
bound_listeners(Node) ->
    maps:keys(erpc:call(Node, ranch, info, [])).

%% @private
%% Ports come from `ranch:get_port/1` on the peer, never from a literal: the
%% peer's `admin` listener is declared `port => 0`
%% (`bondy_ct:node_env/2`), and `ranch:get_port/1` raises `badarg` for a
%% listener that never bound, which distinguishes "never started" from
%% "wrong port".
admin_get(Node, Path) ->
    Port = erpc:call(Node, ranch, get_port, [admin]),
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), Path]),
    {ok, Status, _, _} = hackney:request(get, Url, [], <<>>, []),
    Status.
