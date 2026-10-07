%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_cluster).
-moduledoc """
The cluster, as every Bondy app reaches it: membership, connection events,
peer connections, RPC, leaving, and the host network-status monitor.

This is the only Bondy module that calls Partisan's service modules: the peer
service, its membership mirror, RPC, plumtree broadcast and the network monitor
(`?CLUSTER_SERVICES` in `scripts/check_layering.escript`, which enforces it
over the compiled apps). Calls that read only Partisan's configuration or
connection table, such as `partisan:node/0`, `partisan:nodes/0` and
`partisan:is_connected/1`, stay at their call sites. Messages to a remote node,
through `partisan:cast_message/4`, `partisan:broadcast/2` or a remote
`partisan_gen_server` call, also reach Partisan's processes and stay at their
call sites: without the Partisan application they are safe only while no
remote node is ever their target.

Membership changes only through a deliberate join or leave, never through
connectivity, so a down or partitioned member is still listed. Connected peers
are `partisan:nodes/0`, a different set.

`members/0` reads Partisan's ETS mirror of the peer service manager's member
list, which the manager republishes through `partisan_membership:set/1` on
every join, leave and gossip merge. The manager also prunes a stale address of
a member still connected on another one without republishing, which changes no
name. `partisan_peer_service:members/0` answers the same names through a
`gen_server:call(..., infinity)` on the manager, an unbounded wait on the
process a cluster fault would block, so nothing in Bondy calls it.

With clustering enabled, `members/0` raises while Partisan is not running or
has not yet published a member list (`bondy_cluster_test`): an unavailable
membership must never read as an empty one. `on_up/1`, `on_down/1` and
`leave/0,1` are calls with no timeout.

## Standalone

With clustering disabled (`enabled/0` is `false`, the default when the
application environment does not set it) Partisan is not started and this node
is the whole cluster: `members/0` is this node alone, there are no connections,
membership and connection events never fire, leaving does nothing, every RPC
target is down and the network monitor sends nothing (`bondy_cluster_test`).
Unset means standalone so that `bondy_oplog` and `bondy_db` run as libraries
without Partisan; a release sets the value from `cluster.enabled`, which
defaults to on.
""".

-export([call/5]).
-export([connections/0]).
-export([enabled/0]).
-export([leave/0]).
-export([leave/1]).
-export([members/0]).
-export([monitor_network/1]).
-export([multicall/5]).
-export([on_down/1]).
-export([on_up/1]).
-export([subscribe/0]).

-type connection() :: #{
    node := node(),
    channel := atom(),
    listen_addr :=
        #{ip := inet:ip_address(), port := inet:port_number()}
        | undefined
}.

-export_type([connection/0]).

-doc """
Returns whether this node is clustered: the `bondy_cluster` `enabled`
application environment value, set from `cluster.enabled`, `false` when unset.
""".
-spec enabled() -> boolean().

enabled() ->
    application:get_env(bondy_cluster, enabled, false).

-doc """
Returns the member node names, this node included, as an ordset.
""".
-spec members() -> ordsets:ordset(node()).

members() ->
    case enabled() of
        true ->
            %% `set/1` writes the member list before it bumps the version.
            case partisan_membership:version() of
                0 -> error(membership_unavailable);
                _ -> partisan_membership:node_names()
            end;
        false ->
            [partisan:node()]
    end.

-doc """
Subscribes the calling process to membership changes. Each change is delivered
as a `{partisan_membership, Specs}` message carrying the new member set.
""".
-spec subscribe() -> ok.

subscribe() ->
    case enabled() of
        true -> partisan_membership:subscribe();
        false -> ok
    end.

-doc """
Calls `Fun(Node)` whenever Partisan reports peer `Node` up.
""".
-spec on_up(fun((node()) -> any())) -> ok | {error, not_implemented}.

on_up(Fun) when is_function(Fun, 1) ->
    case enabled() of
        true -> partisan_peer_service:on_up('_', Fun);
        false -> ok
    end.

-doc """
Calls `Fun(Node)` whenever Partisan reports peer `Node` down.
""".
-spec on_down(fun((node()) -> any())) -> ok | {error, not_implemented}.

on_down(Fun) when is_function(Fun, 1) ->
    case enabled() of
        true -> partisan_peer_service:on_down('_', Fun);
        false -> ok
    end.

-doc """
Returns this node's open peer connections. `listen_addr` is `undefined` when
the connection carries none.
""".
-spec connections() -> [connection()].

connections() ->
    case enabled() of
        true ->
            [
                #{
                    node => partisan_peer_connections:node(C),
                    channel => partisan_peer_connections:channel(C),
                    listen_addr => listen_addr(C)
                }
             || C <- partisan_peer_connections:connections()
            ];
        false ->
            []
    end.

-doc """
Applies `Module:Function(Args...)` on `Node` over Partisan, waiting at most
`Timeout` milliseconds. Answers `{badrpc, Reason}` on failure, as
`partisan_rpc:call/5` does. Standalone, every node answers
`{badrpc, nodedown}`, this one included: call this node's function directly.
""".
-spec call(node(), module(), atom(), [term()], timeout()) ->
    term() | {badrpc, term()}.

call(Node, Module, Function, Args, Timeout) ->
    case enabled() of
        true -> partisan_rpc:call(Node, Module, Function, Args, Timeout);
        false -> {badrpc, nodedown}
    end.

-doc """
Applies `Module:Function(Args...)` on each of `Nodes` over Partisan, waiting
at most `Timeout` milliseconds, and answers the replies with the nodes that
gave none, as `partisan_rpc:multicall/5` does. Standalone, every node in
`Nodes` gives none.
""".
-spec multicall([node()], module(), atom(), [term()], timeout()) ->
    {[term()], [node()]}.

multicall(Nodes, Module, Function, Args, Timeout) ->
    case enabled() of
        true -> partisan_rpc:multicall(Nodes, Module, Function, Args, Timeout);
        false -> {[], Nodes}
    end.

-doc """
Removes this node from the cluster.
""".
-spec leave() -> ok.

leave() ->
    case enabled() of
        true -> partisan_peer_service:leave();
        false -> ok
    end.

-doc """
Removes member `Node` from the cluster. A node that is not a member is left
alone.
""".
-spec leave(node()) -> ok.

leave(Node) when is_atom(Node) ->
    case enabled() of
        true -> leave_member(Node);
        false -> ok
    end.

-doc """
Subscribes (`true`) or unsubscribes (`false`) the calling process to host
network-status changes, delivered as `{network_connected, Ref}` and
`{network_disconnected, Ref}` messages.
""".
-spec monitor_network(boolean()) -> ok.

monitor_network(Flag) when is_boolean(Flag) ->
    case enabled() of
        true -> partisan_inet:monitor(Flag);
        false -> ok
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
leave_member(Node) ->
    case [S || #{name := N} = S <- partisan_membership:members(), N == Node] of
        [Spec | _] -> partisan_peer_service:leave(Spec);
        [] -> ok
    end.

%% @private
listen_addr(C) ->
    try
        partisan_peer_connections:listen_addr(C)
    catch
        error:badarg -> undefined
    end.
