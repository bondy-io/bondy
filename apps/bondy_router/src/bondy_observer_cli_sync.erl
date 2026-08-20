%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_observer_cli_sync).
-moduledoc """
`observer_cli` plugin rendering bondy_db anti-entropy (AAE) sync status.

The authoritative convergence signal is the per-instance **applied-frontier
version vector** (`bondy_oplog_instance:frontier/1`), NOT the MST root. The MST
root is unreliable across nodes in different compaction states: compaction
empties the MST while the data persists in the projection, so two converged
nodes can advertise different roots (one compacted, one not) and — worse — two
nodes that have both compacted to an empty MST both advertise `undefined`, so a
root comparison reports IN SYNC without anything actually verifying they match.
The frontier is `#{Origin => max Seq}` over every `{HLC, Origin, Seq}` event the
instance has applied. Because the op-log is delivered causally (no per-origin
gaps), the max Seq per origin identifies the applied op-set, so equal frontiers
mean the nodes have applied the same operations — hence converged — and it is
compaction-invariant (the cumulative applied position does not move on
compaction).

Each row compares the local instance's LIVE frontier against the peer's,
fetched on demand with a `get_frontier` over the AAE channel (the same transport
the sync protocol uses). The verdict is gated three ways:

- **Lifecycle** — a `pre_bootstrap` instance (still pulling its initial
  snapshot) reads `bootstrap`, never IN SYNC; an unregistered one reads
  `starting`.
- **Reachability** — an unreachable peer / not-running instance reads `no data`.
- **Topology** — frontiers are compared only when both nodes' keying-topology
  fingerprints match; a mismatch reads `topo≠` (the frontiers are incomparable).

There is no `warming` state: the frontier is never recomputed (it is maintained
incrementally on the apply path), so it is always authoritative once the
instance is live.

Summary block: whether AAE is enabled, the scheduler tick interval, the instance
and peer counts, and an in-sync tally (bootstrapping and diverged shards count
toward the total but not in-sync, so it reads N/N only once every shard is
genuinely converged). Table: one row per `(instance, peer)` with both frontiers
(a short stable hash) and a status — `IN SYNC`, `DIVERGED`, `topo≠`,
`bootstrap`, `starting`, `no data` (peer unreachable / instance not running
there), or `solo` (no peers).

Register it via the `observer_cli` application env (see `sys.config`):

```erlang
{observer_cli, [
    {plugins, [
        #{module => bondy_observer_cli_sync, title => "Sync",
          interval => 2000, shortcut => "Y", sort_column => 5}
    ]}
]}
```

Reads are gathered defensively and run off the instance process: the frontier is
a lock-free ETS read and the peer calls are `gen_server` calls, so none of them
touch the pack store's process-bound file descriptors.
""".

-behaviour(observer_cli_plugin).

%% observer_cli colour escapes (mirrors observer_cli.hrl).
-define(GREEN, <<"\e[32;1m">>).
-define(RED, <<"\e[31m">>).
-define(YELLOW, <<"\e[33m">>).

%% OBSERVER_CLI_PLUGIN CALLBACKS
-export([attributes/1]).
-export([sheet_header/0]).
-export([sheet_body/1]).

-ifdef(TEST).
%% Exposed for unit-testing the lifecycle-gated row classifier.
-export([status/3]).
-export([status_label/1]).
-endif.

%% =============================================================================
%% OBSERVER_CLI_PLUGIN CALLBACKS
%% =============================================================================

-doc "Top summary block: AAE state, interval, instance/peer counts, in-sync tally.".
-spec attributes(State :: term()) ->
    #{rows := [[map()]], state := NewState :: term()}.

attributes(State) ->
    Instances = instances(),
    Peers = peers(),
    {InSync, Compared} = tally(Instances, Peers),
    {AaeStr, AaeColour} = aae_label(),
    Rows = [
        [
            cell("AAE", 10),
            cell(AaeStr, 12, AaeColour),
            cell("Interval", 12),
            cell(integer_to_list(interval_ms()) ++ "ms", 12),
            cell("Instances", 12),
            cell(integer_to_list(length(Instances)), 8)
        ],
        [
            cell("Peers", 10),
            cell(integer_to_list(length(Peers)), 12),
            cell("In sync", 12),
            cell(
                io_lib:format("~p/~p", [InSync, Compared]),
                12,
                tally_colour(InSync, Compared)
            ),
            cell("", 12),
            cell("", 8)
        ]
    ],
    #{rows => Rows, state => State}.

-doc "Per `(instance, peer)` table columns.".
-spec sheet_header() -> #{columns := [map()], default_sort := atom()}.

sheet_header() ->
    #{
        columns => [
            #{id => instance, title => "Instance", width => 16},
            #{id => peer, title => "Peer", width => 28},
            #{id => local_dig, title => "Local dig", width => 14},
            #{id => peer_dig, title => "Peer dig", width => 14},
            #{id => status, title => "Status", width => 12}
        ],
        default_sort => instance
    }.

-doc "One row per `(instance, connected-peer)`; `solo` when there are no peers.".
-spec sheet_body(State :: term()) ->
    #{rows := [map()], state := NewState :: term()}.

sheet_body(State) ->
    Peers = peers(),
    Rows = lists:flatmap(
        fun(Id) ->
            Life = lifecycle(Id),
            Local = local_sig(Id),
            case Peers of
                [] ->
                    [row(to_str(Id), "(solo)", local_cell(Local), "-", "solo")];
                _ ->
                    [
                        begin
                            Peer = peer_sig(P, Id),
                            row(
                                to_str(Id),
                                to_str(P),
                                local_cell(Local),
                                peer_cell(Peer),
                                status_label(status(Life, Local, Peer))
                            )
                        end
                     || P <- Peers
                    ]
            end
        end,
        instances()
    ),
    #{rows => Rows, state => State}.

%% @private
row(Instance, Peer, LocalDig, PeerDig, Status) ->
    #{
        cells => #{
            instance => Instance,
            peer => Peer,
            local_dig => LocalDig,
            peer_dig => PeerDig,
            status => Status
        }
    }.

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
instances() ->
    try bondy_oplog:list_instances() of
        L when is_list(L) -> lists:sort(L);
        _ -> []
    catch
        _:_ -> []
    end.

%% @private
peers() ->
    try partisan:nodes() of
        N when is_list(N) -> N;
        _ -> []
    catch
        _:_ -> []
    end.

%% @private
%% The local instance's frontier signature for comparison: `{Frontier, Fp}`.
%% `Frontier` is the applied-frontier version vector (`#{Origin => max Seq}`), a
%% lock-free registry read; the topology fingerprint gates cross-node comparison.
local_sig(Id) ->
    Frontier =
        try bondy_oplog_instance:frontier(Id) of
            F when is_map(F) -> F;
            _ -> #{}
        catch
            _:_ -> #{}
        end,
    {Frontier, local_fingerprint(Id)}.

%% @private
local_fingerprint(Id) ->
    try bondy_oplog:topology_fingerprint(bondy_oplog:db_of(Id)) of
        FP when is_binary(FP) -> FP;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

%% @private
%% The peer's LIVE frontier signature, fetched fresh over the AAE channel:
%%   - `{frontier, Map, Fingerprint}` — the peer answered `get_frontier`;
%%   - `not_found` — unreachable / slow, or the instance is not running there.
%% A fresh request (not the cached last-sync value) so it reflects what the peer
%% would serve right now.
peer_sig(Peer, Id) ->
    Opts = #{timeout => 2000, channel => aae_channel()},
    try bondy_oplog_transport_partisan:request(Peer, Id, get_frontier, Opts) of
        {ok, Map, Fp} when is_map(Map) -> {frontier, Map, Fp};
        {ok, Map} when is_map(Map) -> {frontier, Map, undefined};
        _ -> not_found
    catch
        _:_ -> not_found
    end.

%% @private
aae_channel() ->
    try bondy_config:get(aae_channel) of
        Ch when is_atom(Ch) -> Ch;
        _ -> bondy_aae
    catch
        _:_ -> bondy_aae
    end.

%% @private
%% Classify an `(instance, peer)` pair from the local frontier signature
%% `Local = {Frontier, Fingerprint}` and the peer signature `Peer` (see
%% `peer_sig/2`). Gated three ways:
%%
%%   - LIFECYCLE: a `pre_bootstrap` local instance is still pulling its initial
%%     snapshot ⇒ `bootstrap`, never IN SYNC; an unregistered one ⇒ `starting`.
%%   - REACHABILITY: no peer signature ⇒ `no_data`.
%%   - TOPOLOGY: frontiers are compared only when both fingerprints are present
%%     and EQUAL; a genuine mismatch ⇒ `topo` (incomparable keying). A missing
%%     fingerprint (either side) skips the check and compares anyway.
%%
%% Otherwise equal frontiers ⇒ `in_sync`, differing ⇒ `diverged`. There is no
%% `warming` state: the frontier is never recomputed, so it is always
%% authoritative once the instance is live.
status(pre_bootstrap, _Local, _Peer) ->
    bootstrap;
status(undefined, _Local, _Peer) ->
    starting;
status(live, _Local, not_found) ->
    no_data;
status(live, {LFrontier, LFp}, {frontier, PFrontier, PFp}) ->
    case fingerprints_differ(LFp, PFp) of
        true -> topo;
        false when LFrontier =:= PFrontier -> in_sync;
        false -> diverged
    end;
status(live, _Local, _Peer) ->
    unknown.

%% @private
%% Both fingerprints are present (not `undefined`) AND differ — only then are the
%% two nodes keying data differently, making their frontiers incomparable.
fingerprints_differ(LFp, PFp) ->
    LFp =/= undefined andalso PFp =/= undefined andalso LFp =/= PFp.

%% @private
status_label(in_sync) -> "IN SYNC";
status_label(diverged) -> "DIVERGED";
status_label(topo) -> "topo≠";
status_label(bootstrap) -> "bootstrap";
status_label(no_data) -> "no data";
status_label(starting) -> "starting";
status_label(unknown) -> "?".

%% @private
%% The instance's bootstrap lifecycle (`pre_bootstrap` until its initial
%% snapshot lands, then `live`). Any error / unknown maps to `undefined`
%% (rendered `starting`).
lifecycle(Id) ->
    try bondy_oplog_instance:lifecycle_state(Id) of
        live -> live;
        pre_bootstrap -> pre_bootstrap;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

%% @private
%% In-sync tally over the (instance, peer) pairs. A live pair with equal
%% frontiers counts as in-sync; live `diverged`/`topo` pairs and a `bootstrap`
%% pair (local instance still pulling its snapshot) all count toward the total
%% but not in-sync — so the summary reads e.g. 20/32 mid-rebuild and only reaches
%% N/N once every shard is genuinely converged. Pairs with no peer data, or a
%% still-`starting` local instance, are simply uncompared.
tally(Instances, Peers) ->
    lists:foldl(
        fun(Id, Acc0) ->
            Life = lifecycle(Id),
            Local = local_sig(Id),
            lists:foldl(
                fun(P, {Ok, Total} = Acc) ->
                    case status(Life, Local, peer_sig(P, Id)) of
                        in_sync -> {Ok + 1, Total + 1};
                        diverged -> {Ok, Total + 1};
                        topo -> {Ok, Total + 1};
                        bootstrap -> {Ok, Total + 1};
                        _ -> Acc
                    end
                end,
                Acc0,
                Peers
            )
        end,
        {0, 0},
        Instances
    ).

%% @private
aae_label() ->
    case application:get_env(bondy_oplog, aae_enabled, false) of
        true -> {"on", ?GREEN};
        _ -> {"off", ?YELLOW}
    end.

%% @private
interval_ms() ->
    application:get_env(bondy_oplog, sync_interval_ms, 500).

%% @private
tally_colour(_, 0) -> ?YELLOW;
tally_colour(N, N) -> ?GREEN;
tally_colour(_, _) -> ?RED.

%% @private
%% Render the LOCAL frontier cell from `local_sig/1`.
local_cell({Frontier, _Fp}) -> short_frontier(Frontier);
local_cell(_) -> "?".

%% @private
%% Render the PEER frontier cell from `peer_sig/2`.
peer_cell({frontier, Frontier, _Fp}) -> short_frontier(Frontier);
peer_cell(not_found) -> "-";
peer_cell(_) -> "?".

%% @private
%% A compact, comparable rendering of the applied-frontier VV: `(empty)` for no
%% applied events, else a short stable hash of the map so equal frontiers render
%% identically and differing ones visibly differ. The Status column is the
%% authoritative comparison; this is for eyeballing.
short_frontier(F) when is_map(F), map_size(F) =:= 0 ->
    "(empty)";
short_frontier(F) when is_map(F) ->
    integer_to_list(erlang:phash2(F), 16);
short_frontier(_) ->
    "?".

%% @private
to_str(V) when is_atom(V) -> atom_to_list(V);
to_str(V) when is_binary(V) -> binary_to_list(V);
to_str(V) when is_list(V) -> V;
to_str(V) -> lists:flatten(io_lib:format("~p", [V])).
