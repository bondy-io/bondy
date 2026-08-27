%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_degraded_boot_SUITE).

-moduledoc """
Boots one node whose durable `main` database CANNOT open — a regular file
squats on the directory path `bondy_namespace_catalog:main_dir/0` resolves —
and asserts the degraded posture `open_main_into/1` documents actually holds:

  1. the node STANDS UP: `bondy_router` is running, `main_status/0` is
     `failed`, and the `bondy_db_main_unavailable` alarm is raised (the
     readiness probe reads `main_status/0`, so NOT READY follows from it);
  2. the supervision tree HOLDS over a window: the catalogue and the
     bridge-relay manager keep their pids — the pre-fix failure modes were a
     VM halt (`configure_services/0` raising through `bondy_app:start/2`) and
     a crash loop (`bondy_bridge_relay_manager` hitting
     `bridge_relay_table_unavailable` until `reached_max_restart_intensity`
     collapsed `bondy_sup`);
  3. durable operations fail with their documented errors instead of killing
     the node, and the ephemeral registry half is alive.

The whole boot runs against the poisoned directory, so any OTHER boot-path
consumer of the durable tables that raises would fail `init_per_suite/1`
here — the suite covers the property, not just the three call sites fixed
with it.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([suite/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([node_stands_up_degraded/1]).
-export([supervision_tree_holds/1]).
-export([durable_ops_fail_cleanly_and_registry_works/1]).
-export([healthy_control_still_configures_services/1]).

-define(NODE_NAME, bondy_degraded1).
-define(CONTROL_NODE_NAME, bondy_degraded_ctrl).
-define(MASTER_REALM_URI, <<"com.leapsight.bondy">>).

suite() -> [{timetrap, {minutes, 5}}].

all() ->
    [
        node_stands_up_degraded,
        supervision_tree_holds,
        durable_ops_fail_cleanly_and_registry_works,
        healthy_control_still_configures_services
    ].

init_per_suite(Config) ->
    PrivDir = ?config(priv_dir, Config),
    %% `bondy_ct:start_node/5` gives the peer `<priv>/<name>` as its
    %% `platform_data_dir`, so the main DB directory it will try to create is
    %% `<priv>/<name>/bondy_db/main`. Squat a regular file there BEFORE the
    %% boot: `filelib:ensure_path/1` then fails, only for `main` — the `wal`
    %% and `mst` siblings and everything else under the data dir stay usable.
    %% The second node is the untouched CONTROL for
    %% `healthy_control_still_configures_services/1`.
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

%% The CONTROL: an identically-configured node whose main DB opens fine must
%% take the configured path, not the degraded one — the master realm exists
%% right after boot WITHOUT lazy creation (`bondy_realm:lookup/1` never
%% creates), `main_status/0` is `open` and no main-unavailable alarm is
%% raised. This is what pins the `main_status` gates to `open` rather than
%% merely "not raising": a gate inverted to always-skip boots too.
healthy_control_still_configures_services(Config) ->
    Node = control_node(Config),
    ?assertEqual(
        open, erpc:call(Node, bondy_namespace_catalog, main_status, [])
    ),
    ?assertMatch(
        {ok, _}, erpc:call(Node, bondy_realm, lookup, [?MASTER_REALM_URI])
    ),
    Alarms = erpc:call(Node, bondy_alarm_handler, get_alarms, []),
    ?assertNot(lists:keymember(bondy_db_main_unavailable, 1, Alarms)).

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
%% The processes whose death was each pre-fix failure mode, plus the root
%% supervisor they would have taken down.
supervised_pids(Node) ->
    [
        erpc:call(Node, erlang, whereis, [Name])
     || Name <- [
            bondy_sup,
            bondy_namespace_catalog,
            bondy_bridge_relay_manager
        ]
    ].
