%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Unit tests for the cluster Node Graph payload assembled by
%% `bondy_cluster_topology:graph/0`. Runs standalone (no Partisan cluster, no
%% Bondy app) — every source is defensive, so a solo node yields just itself
%% with no edges. Asserts the Node Graph field contract and a JSON round-trip.
-module(bondy_cluster_topology_test).

-include_lib("eunit/include/eunit.hrl").

solo_shape_test() ->
    #{<<"nodes">> := Nodes, <<"edges">> := Edges} =
        bondy_cluster_topology:graph(),
    %% No Partisan peers here → exactly this node, no edges.
    ?assertEqual([], Edges),
    ?assert(length(Nodes) >= 1),
    Self = hd(Nodes),
    lists:foreach(
        fun(K) -> ?assert(maps:is_key(K, Self)) end,
        [<<"id">>, <<"title">>, <<"subTitle">>, <<"mainStat">>, <<"arc__ok">>]
    ),
    ?assertEqual(<<"self">>, maps:get(<<"mainStat">>, Self)),
    ?assertEqual(<<"this node">>, maps:get(<<"subTitle">>, Self)).

arcs_sum_to_one_test() ->
    #{<<"nodes">> := Nodes} = bondy_cluster_topology:graph(),
    lists:foreach(
        fun(N) ->
            Ok = maps:get(<<"arc__ok">>, N),
            Down = maps:get(<<"arc__down">>, N),
            ?assert(is_number(Ok) andalso is_number(Down)),
            ?assert(abs((Ok + Down) - 1.0) < 1.0e-9)
        end,
        Nodes
    ).

json_round_trip_test() ->
    G = bondy_cluster_topology:graph(),
    Bin = iolist_to_binary(json:encode(G)),
    Decoded = json:decode(Bin),
    ?assert(is_map(Decoded)),
    ?assert(maps:is_key(<<"nodes">>, Decoded)),
    ?assert(maps:is_key(<<"edges">>, Decoded)),
    ?assertEqual([], maps:get(<<"edges">>, Decoded)).

%% Every node-map variant — including the PEER subtitles the solo graph never
%% reaches — must JSON-encode. Guards the class of bug where a non-ASCII char in
%% a string literal becomes invalid UTF-8 and crashes json:encode.
peer_node_maps_json_encode_test() ->
    Self = 'self@h',
    Peer = 'peer@h',
    Cases = [
        % member + connected
        {[Peer], [Peer]},
        % member + DISCONNECTED
        {[Peer], []},
        % non-member + connected
        {[], [Peer]},
        % unknown
        {[], []}
    ],
    lists:foreach(
        fun({Members, Connected}) ->
            M = bondy_cluster_topology:node_map(
                Peer, Self, Members, Connected, 0
            ),
            %% Must not crash (the invalid-UTF-8 regression), and round-trips.
            Bin = iolist_to_binary(json:encode(M)),
            ?assert(is_map(json:decode(Bin)))
        end,
        Cases
    ),
    %% And the self node with alarms (the 0.5 arc branch).
    Self0 = bondy_cluster_topology:node_map(Self, Self, [Self], [], 3),
    ?assertEqual(0.5, maps:get(<<"arc__ok">>, Self0)),
    _ = json:encode(Self0).
