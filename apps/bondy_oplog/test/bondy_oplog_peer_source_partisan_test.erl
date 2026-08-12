%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests peer selection in `bondy_oplog_peer_source_partisan`.
%%
%% Partisan membership and Partisan connectivity are different things: a node
%% that is down stays a member until it is removed from the cluster, so a source
%% that offers the raw membership offers peers that cannot answer. The scheduler
%% then opens a session per instance per tick against each of them, and every
%% one fails.
%% =============================================================================
-module(bondy_oplog_peer_source_partisan_test).

-include_lib("eunit/include/eunit.hrl").

-define(SELF, 'node1@127.0.0.1').
-define(UP, 'node2@127.0.0.1').
-define(DOWN, 'node3@127.0.0.1').

peer_source_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun unreachable_members_are_not_offered/0,
        fun the_local_node_is_never_offered/0,
        fun all_members_unreachable_offers_nothing/0
    ]}.

setup() ->
    ok = meck:new(partisan, [passthrough, unstick]),
    ok = meck:new(partisan_peer_service, [passthrough, unstick]),
    ok = meck:new(partisan_peer_connections, [passthrough, unstick]),
    ok = meck:expect(partisan, node, fun() -> ?SELF end),
    ok = meck:expect(
        partisan_peer_service, members, fun() -> {ok, [?SELF, ?UP, ?DOWN]} end
    ),
    ok = meck:expect(
        partisan_peer_connections,
        is_connected,
        fun
            (?DOWN) -> false;
            (_) -> true
        end
    ),
    ok.

cleanup(_) ->
    _ = meck:unload(partisan_peer_connections),
    _ = meck:unload(partisan_peer_service),
    _ = meck:unload(partisan),
    ok.

%% A member this node has no connection to cannot answer a sync request, so
%% offering it only produces a failed session per instance per tick.
unreachable_members_are_not_offered() ->
    ?assertEqual(
        [?UP],
        bondy_oplog_peer_source_partisan:peers_for(<<"main/0">>, #{count => 3})
    ).

the_local_node_is_never_offered() ->
    Peers = bondy_oplog_peer_source_partisan:peers_for(
        <<"main/0">>, #{count => 3}
    ),
    ?assertNot(lists:member(?SELF, Peers)).

%% An isolated node offers no peers at all rather than offering members it
%% cannot reach.
all_members_unreachable_offers_nothing() ->
    ok = meck:expect(
        partisan_peer_connections, is_connected, fun(_) -> false end
    ),
    ?assertEqual(
        [],
        bondy_oplog_peer_source_partisan:peers_for(<<"main/0">>, #{count => 3})
    ).
