%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_observer_cli_cluster).
-moduledoc """
`observer_cli` plugin rendering the Partisan cluster view: this node, the
membership view size, the connected-peer count, and a per-node table showing
each node's membership and connection status.

Register it via the `observer_cli` application env (see `sys.config`):

```erlang
{observer_cli, [
    {plugins, [
        #{module => bondy_observer_cli_cluster, title => "Cluster",
          interval => 2000, shortcut => "C", sort_column => 1}
    ]}
]}
```

Then `observer_cli:start_plugin()` (or `observer_cli:start()` and switch to the
plugin view) and press the plugin's shortcut.

All data is gathered defensively: a failing source degrades to an empty/`n/a`
cell rather than crashing the render loop.
""".

-behaviour(observer_cli_plugin).

%% observer_cli colour escapes (mirrors observer_cli.hrl so we don't depend on
%% its private records).
-define(GREEN, <<"\e[32;1m">>).
-define(RED, <<"\e[31m">>).

%% OBSERVER_CLI_PLUGIN CALLBACKS
-export([attributes/1]).
-export([sheet_header/0]).
-export([sheet_body/1]).

%% =============================================================================
%% OBSERVER_CLI_PLUGIN CALLBACKS
%% =============================================================================

-doc "Top summary block: node, membership size, connected count, manager.".
-spec attributes(State :: term()) ->
    #{rows := [[map()]], state := NewState :: term()}.

attributes(State) ->
    Self = self_node(),
    Members = members(),
    Connected = connected(),
    Manager = manager(),
    Rows = [
        [
            cell("Node", 12),
            cell(to_str(Self), 34),
            cell("Members", 12),
            cell(integer_to_list(length(Members)), 12)
        ],
        [
            cell("Manager", 12),
            cell(Manager, 34),
            cell("Connected", 12),
            cell(
                integer_to_list(length(Connected)),
                12,
                connected_colour(Members, Connected, Self)
            )
        ]
    ],
    #{rows => Rows, state => State}.

-doc "Per-node table columns.".
-spec sheet_header() -> #{columns := [map()], default_sort := atom()}.

sheet_header() ->
    #{
        columns => [
            #{id => node, title => "Node", width => 36},
            #{id => membership, title => "Membership", width => 14},
            #{id => connected, title => "Connected", width => 12},
            #{id => self, title => "Self", width => 8}
        ],
        default_sort => node
    }.

-doc "One row per known node (membership view ∪ connected ∪ self).".
-spec sheet_body(State :: term()) ->
    #{rows := [map()], state := NewState :: term()}.

sheet_body(State) ->
    Self = self_node(),
    Members = members(),
    Connected = connected(),
    Nodes = lists:usort(Members ++ Connected ++ [Self]),
    Rows = [
        begin
            IsSelf = N =:= Self,
            IsConnected = IsSelf orelse lists:member(N, Connected),
            Membership =
                case lists:member(N, Members) of
                    true -> "member";
                    false -> "non-member"
                end,
            #{
                cells => #{
                    node => to_str(N),
                    membership => Membership,
                    connected => yes_no(IsConnected),
                    self => yes_no(IsSelf)
                }
            }
        end
     || N <- Nodes
    ],
    #{rows => Rows, state => State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
cell(Content, Width) ->
    #{content => Content, width => Width}.

%% @private
cell(Content, Width, Colour) ->
    #{content => Content, width => Width, color => Colour}.

%% @private
self_node() ->
    try
        partisan:node()
    catch
        _:_ -> node()
    end.

%% @private
members() ->
    try partisan_peer_service:members() of
        {ok, M} when is_list(M) -> M;
        M when is_list(M) -> M;
        _ -> []
    catch
        _:_ -> []
    end.

%% @private
connected() ->
    try partisan:nodes() of
        N when is_list(N) -> N;
        _ -> []
    catch
        _:_ -> []
    end.

%% @private
manager() ->
    case application:get_env(partisan, peer_service_manager) of
        {ok, Mod} -> to_str(Mod);
        undefined -> "n/a"
    end.

%% @private
%% Green when every member is connected, otherwise red (a member we cannot
%% reach).
connected_colour(Members, Connected, Self) ->
    Reachable = lists:usort([Self | Connected]),
    case Members -- Reachable of
        [] -> ?GREEN;
        _ -> ?RED
    end.

%% @private
yes_no(true) -> "yes";
yes_no(false) -> "no".

%% @private
to_str(V) when is_atom(V) -> atom_to_list(V);
to_str(V) when is_binary(V) -> binary_to_list(V);
to_str(V) when is_list(V) -> V;
to_str(V) -> lists:flatten(io_lib:format("~p", [V])).
