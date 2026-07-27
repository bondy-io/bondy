%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_cluster_topology).

-moduledoc """
Assembles this node's view of the cluster as a **Grafana Node Graph** payload:
`#{<<"nodes">> => [...], <<"edges">> => [...]}`, with every map already shaped to
the Node Graph field names (`id`, `title`, `subTitle`, `mainStat`, `arc__*`(+
`_color`), `detail__*` for nodes; `id`, `source`, `target`, `mainStat`,
`secondaryStat`, `detail__*` for edges). Served as JSON by
`bondy_admin_cluster_topology_http_handler` and consumed by an Infinity
datasource so the graph needs no Prometheus-side reshaping.

Every source is read-only and defensive: partisan membership + live connections
for the topology, `bondy_alarm_handler` for node health, and the
`bondy_cluster_peer_rtt_milliseconds` histogram for the edge latency (a lifetime
average — the live quantiles live in the inter-node dashboard panels). A solo or
mid-boot node yields just itself with no edges.
""".

-export([graph/0]).

-ifdef(TEST).
-export([node_map/5]).
-endif.

%% =============================================================================
%% API
%% =============================================================================

-doc "The cluster topology as a Grafana Node Graph nodes/edges payload.".
-spec graph() -> #{binary() => [map()]}.

graph() ->
    Self = self_node(),
    Members = members(),
    Connected = connected(),
    Alarms = alarm_count(),
    Nodes = lists:usort([Self | Members ++ Connected]),
    #{
        <<"nodes">> => [
            node_map(N, Self, Members, Connected, Alarms)
         || N <- Nodes
        ],
        <<"edges">> => [edge_map(Self, Peer) || Peer <- Connected]
    }.

%% =============================================================================
%% PRIVATE — nodes
%% =============================================================================

%% @private
node_map(N, Self, Members, Connected, Alarms) ->
    IsSelf = N =:= Self,
    IsMember = lists:member(N, Members),
    IsConnected = IsSelf orelse lists:member(N, Connected),
    Ok = health(IsSelf, IsConnected, Alarms),
    NB = to_bin(N),
    #{
        <<"id">> => NB,
        <<"title">> => NB,
        <<"subTitle">> => sub_title(IsSelf, IsMember, IsConnected),
        <<"mainStat">> => main_stat(IsSelf, IsConnected),
        %% Health ring: arc__ok + arc__down always sum to 1.
        <<"arc__ok">> => Ok,
        <<"arc__ok_color">> => <<"green">>,
        <<"arc__down">> => 1.0 - Ok,
        <<"arc__down_color">> => <<"red">>,
        <<"detail__member">> => yesno(IsMember),
        <<"detail__connected">> => yesno(IsConnected),
        <<"detail__alarms">> => detail_alarms(IsSelf, Alarms)
    }.

%% @private
%% ok-fraction of the health ring: a connected peer (or a self node with no
%% alarms) is fully healthy; a self node holding alarms is half-degraded; a
%% member we cannot reach is fully down.
health(true, _, Alarms) when Alarms > 0 -> 0.5;
health(true, _, _) -> 1.0;
health(false, true, _) -> 1.0;
health(false, false, _) -> 0.0.

%% @private
%% NOTE: keep every string value ASCII — these become UTF-8 JSON strings, and a
%% non-ASCII char in a `<<"...">>` literal is a bare high byte that json:encode
%% rejects as invalid UTF-8.
sub_title(true, _, _) -> <<"this node">>;
sub_title(false, true, true) -> <<"member, connected">>;
sub_title(false, true, false) -> <<"member, DISCONNECTED">>;
sub_title(false, false, true) -> <<"connected, non-member">>;
sub_title(false, false, false) -> <<"unknown">>.

%% @private
main_stat(true, _) -> <<"self">>;
main_stat(false, true) -> <<"UP">>;
main_stat(false, false) -> <<"DOWN">>.

%% =============================================================================
%% PRIVATE — edges
%% =============================================================================

%% @private
edge_map(Self, Peer) ->
    SB = to_bin(Self),
    PB = to_bin(Peer),
    Count = conn_count(Peer),
    #{
        <<"id">> => <<SB/binary, "->", PB/binary>>,
        <<"source">> => SB,
        <<"target">> => PB,
        <<"mainStat">> => rtt_stat(Peer),
        <<"secondaryStat">> =>
            <<(integer_to_binary(Count))/binary, " conns">>,
        <<"detail__connections">> => integer_to_binary(Count)
    }.

%% @private
rtt_stat(Peer) ->
    case peer_rtt_ms(Peer) of
        undefined -> <<"n/a">>;
        Ms -> <<(integer_to_binary(Ms))/binary, " ms">>
    end.

%% @private
%% Lifetime-average heartbeat RTT to a peer, summed across every channel and
%% side from the histogram. `undefined` before the first heartbeat lands.
peer_rtt_ms(Peer) ->
    {Sum, Count} = lists:foldl(
        fun(Ch, Acc0) ->
            lists:foldl(
                fun(Side, Acc) -> add_rtt(Peer, Ch, Side, Acc) end,
                Acc0,
                [client, server]
            )
        end,
        {0, 0},
        maps:keys(channels())
    ),
    case Count of
        0 -> undefined;
        _ -> Sum div Count
    end.

%% @private
add_rtt(Peer, Channel, Side, {Sum, Count}) ->
    Q = #{
        name => bondy_cluster_peer_rtt_milliseconds,
        label => #{peer => Peer, channel => Channel, side => Side}
    },
    case catch bondy_metrics:histogram_snapshot(Q) of
        {ok, #{count := C, sum := S}} -> {Sum + S, Count + C};
        _ -> {Sum, Count}
    end.

%% =============================================================================
%% PRIVATE — sources (all read-only, defensive)
%% =============================================================================

%% @private
self_node() ->
    try
        partisan:node()
    catch
        _:_ -> node()
    end.

%% @private
members() ->
    case catch partisan_peer_service:members() of
        {ok, M} when is_list(M) -> M;
        M when is_list(M) -> M;
        _ -> []
    end.

%% @private
connected() ->
    case catch partisan:nodes() of
        N when is_list(N) -> N;
        _ -> []
    end.

%% @private
channels() ->
    case catch partisan_config:channels() of
        M when is_map(M) -> M;
        _ -> #{}
    end.

%% @private
conn_count(Peer) ->
    case catch partisan_peer_connections:count(Peer) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

%% @private
alarm_count() ->
    case catch bondy_alarm_handler:get_alarms() of
        L when is_list(L) -> length(L);
        _ -> 0
    end.

%% @private
to_bin(N) when is_atom(N) -> atom_to_binary(N, utf8);
to_bin(N) when is_binary(N) -> N;
to_bin(N) -> list_to_binary(io_lib:format("~p", [N])).

%% @private
yesno(true) -> <<"yes">>;
yesno(false) -> <<"no">>.

%% @private
detail_alarms(true, N) -> integer_to_binary(N);
detail_alarms(false, _) -> <<"-">>.
