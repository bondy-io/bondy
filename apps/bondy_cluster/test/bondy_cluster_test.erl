%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_cluster_test).

-include_lib("eunit/include/eunit.hrl").

%% Runs without the Partisan application. Clustered, the membership table is
%% created here so each test controls exactly what Partisan would have
%% published; standalone, any call that still reached Partisan would raise.

standalone_never_reaches_partisan_test_() ->
    Self = 'standalone@h',
    {setup,
        fun() ->
            ok = application:set_env(partisan, name, Self),
            {ok, Apps} = application:ensure_all_started(bondy_cluster),
            undefined = whereis(partisan_sup),
            Apps
        end,
        fun(Apps) ->
            [ok = application:stop(A) || A <- lists:reverse(Apps)],
            ok = application:unset_env(partisan, name)
        end,
        [
            ?_assertNot(bondy_cluster:enabled()),
            ?_assertEqual([Self], bondy_cluster:members()),
            ?_assertEqual(ok, bondy_cluster:subscribe()),
            ?_assertEqual(ok, bondy_cluster:on_up(fun(_) -> ok end)),
            ?_assertEqual(ok, bondy_cluster:on_down(fun(_) -> ok end)),
            ?_assertEqual([], bondy_cluster:connections()),
            ?_assertEqual(
                {badrpc, nodedown},
                bondy_cluster:call(Self, erlang, node, [], 100)
            ),
            ?_assertEqual(
                {[], ['a@h']},
                bondy_cluster:multicall(['a@h'], erlang, node, [], 100)
            ),
            ?_assertEqual(ok, bondy_cluster:leave()),
            ?_assertEqual(ok, bondy_cluster:leave('a@h')),
            ?_assertEqual(ok, bondy_cluster:monitor_network(true))
        ]}.

unavailable_membership_raises_test_() ->
    {setup,
        fun() ->
            undefined = ets:whereis(partisan_membership),
            enable()
        end,
        fun disable/1, [
            ?_assertError(badarg, bondy_cluster:members()),
            {setup, fun new_table/0, fun delete_table/1, [
                ?_assertError(membership_unavailable, bondy_cluster:members())
            ]}
        ]}.

members_are_the_published_names_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(telemetry),
            enable(),
            Tab = new_table(),
            ok = partisan_membership:set([
                #{name => 'b@h'}, #{name => 'a@h'}, #{name => 'b@h'}
            ]),
            Tab
        end,
        fun(Tab) ->
            delete_table(Tab),
            disable(Tab)
        end,
        [
            ?_assertEqual(['a@h', 'b@h'], bondy_cluster:members()),
            ?_assertEqual(ok, bondy_cluster:leave('nobody@h'))
        ]}.

%% A single-node cluster has no peer connections, so the connection without a
%% listen address (Partisan raises `badarg` reading it) is only reachable here.
connections_are_plain_maps_test_() ->
    Addr = #{ip => {127, 0, 0, 1}, port => 18086},
    {setup,
        fun() ->
            enable(),
            ok = meck:new(partisan_peer_connections, [no_link]),
            meck:expect(partisan_peer_connections, connections, 0, [c1, c2]),
            meck:expect(partisan_peer_connections, node, fun
                (c1) -> 'a@h';
                (c2) -> 'b@h'
            end),
            meck:expect(partisan_peer_connections, channel, 1, undefined),
            meck:expect(partisan_peer_connections, listen_addr, fun
                (c1) -> Addr;
                (c2) -> error(badarg)
            end)
        end,
        fun(X) ->
            meck:unload(partisan_peer_connections),
            disable(X)
        end,
        ?_assertEqual(
            [
                #{node => 'a@h', channel => undefined, listen_addr => Addr},
                #{node => 'b@h', channel => undefined, listen_addr => undefined}
            ],
            bondy_cluster:connections()
        )}.

enable() ->
    ok = application:set_env(bondy_cluster, enabled, true).

disable(_) ->
    ok = application:unset_env(bondy_cluster, enabled).

new_table() ->
    ets:new(partisan_membership, [named_table, public, set]).

delete_table(Tab) ->
    true = ets:delete(Tab).
