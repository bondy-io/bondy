%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_exchange).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Anti-entropy exchange orchestration for Merkle Search Trees.

This module owns the bookkeeping for pairwise anti-entropy exchanges and
nothing else. It does not own a tree, does not decide when to start an
exchange, and does not interpret the result — those belong to the component
embedding it (`bondy_mst_crdt`, or an oplog instance).

## Non-blocking merges

The local tree is **not** mutated until every page required by the merge is
locally available. A peer root under consideration is held in a merge buffer;
`handle/3` requests the missing pages and returns, leaving the tree untouched,
so local reads and writes proceed while pages are in flight. Only once the
missing set is empty is the merge performed — entirely locally, with no network
round trip.

## Reciprocity

The `get_cmd()` carries the requester's root. A responder that serves those
pages therefore learns the requester's root for free and can start its own
exchange in the opposite direction. Bidirectional convergence needs no push
path and no unsolicited bulk transfer: each side pulls at its own pace.

The responder does **not** start that reverse exchange inline — `handle/3`
returns a `{peer_root, Peer, Root}` event and leaves the decision to the
embedder, so serving pages stays cheap and can be handled concurrently.

## Bounded concurrency

`max_merges` bounds the number of in-flight merges. `max_merges_per_root`
bounds how many of those may target the same root, which matters when several
peers are already in sync with each other and gossip the same root.

## Interaction with garbage collection

`merge_roots/1` returns the roots of all in-flight merges. Any GC over the
underlying store MUST treat these as reachable, or an exchange in progress will
have its pages collected from underneath it.

## Degradation

A responder that no longer holds the requested pages — because they were
garbage collected — replies `missing_cmd()`, and the initiator abandons the
merge rather than looping. Callers should treat that as the signal to fall back
to a bootstrap/snapshot transfer.

## Messages

|Message|Purpose|Concurrent-safe|
|---|---|---|
|`get_cmd()`|Request pages, announcing the requester's root|Yes|
|`put_cmd()`|Deliver requested pages|Yes|
|`missing_cmd()`|Decline — pages unavailable|Yes|

## Callbacks

The embedder supplies a callback module implementing `send/2` (or `send/3`
when `callback_args` is used).
""").

-record(?MODULE, {
    %% Normally node() but it can be a binary when testing
    node_id :: node_id(),
    callback_mod :: module(),
    callback_args :: list(),
    %% The maximum number of concurrent merges. Bounds `merge_buffer`.
    max_merges = 6 :: pos_integer(),
    %% The maximum number of concurrent merges having the same root. Two peers
    %% already in sync with each other gossip the same root; without this we
    %% would run the same merge once per peer.
    max_merges_per_root = 1 :: pos_integer(),
    %% The remote roots we are currently merging with, keyed by peer.
    %% Bounded by max_merges.
    merge_buffer = #{} :: #{node_id() => hash()}
}).

-record(get, {
    from :: node_id(),
    root :: hash(),
    set :: sets:set(hash())
}).

-record(put, {
    from :: node_id(),
    map :: #{hash() := bondy_mst_page:t()}
}).

-record(missing, {
    from :: node_id()
}).

-type t() :: #?MODULE{}.
-type node_id() :: node() | binary().
-type get_cmd() :: #get{}.
-type put_cmd() :: #put{}.
-type missing_cmd() :: #missing{}.
-type message() :: get_cmd() | put_cmd() | missing_cmd().
-type opts() :: #{
    callback_mod := module(),
    callback_args => list(),
    max_merges => pos_integer(),
    max_merges_per_root => pos_integer()
}.

-doc """
Emitted by `handle/3` and `maybe_merge/4` for the embedder to act on.

- `{merged, Peer, OldRoot, NewRoot}` — the local tree advanced. The embedder is
  responsible for whatever must follow: version history, garbage collection,
  announcing the new root, application-level hooks.
- `{in_sync, Peer}` — the merge completed without changing the local root.
- `{peer_root, Peer, Root}` — a peer announced a root while requesting pages.
  The embedder may start an exchange in that direction.
- `{merge_abandoned, Peer, Reason}` — the merge was dropped. `unavailable`
  means the peer could not serve the pages.
- `{merge_skipped, Peer, Reason}` — the merge was never started;
  `concurrency_limit` or `peer_empty`.
""".
-type event() ::
    {merged, node_id(), hash() | undefined, hash()}
    | {in_sync, node_id()}
    | {peer_root, node_id(), hash()}
    | {merge_abandoned, node_id(), unavailable}
    | {merge_skipped, node_id(), concurrency_limit | peer_empty}.

-export_type([t/0]).
-export_type([node_id/0]).
-export_type([message/0]).
-export_type([get_cmd/0]).
-export_type([put_cmd/0]).
-export_type([missing_cmd/0]).
-export_type([event/0]).
-export_type([opts/0]).

%% API
-export([cancel_merge/2]).
-export([cancel_merges/2]).
-export([handle/3]).
-export([is_message/1]).
-export([is_stale/2]).
-export([maybe_merge/4]).
-export([merge_roots/1]).
-export([merges/1]).
-export([new/2]).
-export([node_id/1]).
-export([peer/1]).

%% BEHAVIOUR
-callback send(Peer :: node_id(), message()) -> ok | {error, any()}.
-callback send(ExtraArg :: term(), Peer :: node_id(), message()) ->
    ok | {error, any()}.

-optional_callbacks([send/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Creates a new exchange state for local node `NodeId`.".
-spec new(node_id(), opts()) -> t().

new(NodeId, Opts) when is_map(Opts) ->
    #?MODULE{
        node_id = NodeId,
        callback_mod = validate_callback_mod(Opts),
        callback_args = maps:get(callback_args, Opts, []),
        max_merges = maps:get(max_merges, Opts, 6),
        max_merges_per_root = maps:get(max_merges_per_root, Opts, 1)
    }.

-spec node_id(t()) -> node_id().

node_id(#?MODULE{node_id = Val}) ->
    Val.

-doc "Returns the peers with an in-flight merge.".
-spec merges(t()) -> [node_id()].

merges(#?MODULE{merge_buffer = Merges}) ->
    maps:keys(Merges).

-doc """
Returns the roots of all in-flight merges.

Garbage collection over the underlying store MUST treat these as reachable.
""".
-spec merge_roots(t()) -> [hash()].

merge_roots(#?MODULE{merge_buffer = Merges}) ->
    maps:values(Merges).

-doc """
Cancels the in-flight merge with `Peer`, if any.

Use a failure detector to cancel merges when a peer crashes; the abandoned
pages are reclaimed by the next garbage collection.
""".
-spec cancel_merge(t(), node_id()) -> t().

cancel_merge(#?MODULE{merge_buffer = Merges} = State, Peer) ->
    State#?MODULE{merge_buffer = maps:without([Peer], Merges)}.

-doc """
Cancels every in-flight merge targeting `Root`.

Call this when the local tree reaches `Root` by another path, which makes those
merges redundant.
""".
-spec cancel_merges(t(), hash()) -> t().

cancel_merges(#?MODULE{merge_buffer = Merges} = State, Root) ->
    State#?MODULE{
        merge_buffer = maps:filter(fun(_, V) -> V =/= Root end, Merges)
    }.

-doc "Returns `true` if `PeerRoot` is not fully contained in `Tree`.".
-spec is_stale(bondy_mst:t(), hash()) -> boolean().

is_stale(Tree, PeerRoot) ->
    case bondy_mst:root(Tree) == PeerRoot of
        true ->
            false;
        false ->
            not sets:is_empty(bondy_mst:missing_set(Tree, PeerRoot))
    end.

-doc "Returns `true` if `Term` is an exchange protocol message.".
-spec is_message(any()) -> boolean().

is_message(#get{}) -> true;
is_message(#put{}) -> true;
is_message(#missing{}) -> true;
is_message(_) -> false.

-doc "Returns the sending peer of an exchange protocol message.".
-spec peer(message()) -> node_id().

peer(#get{from = Peer}) -> Peer;
peer(#put{from = Peer}) -> Peer;
peer(#missing{from = Peer}) -> Peer.

-doc """
Considers a merge of `Tree` with `Peer`'s tree rooted at `PeerRoot`.

Admits the merge if the concurrency limits allow, then drives it: if pages are
missing they are requested and the tree is returned unchanged; if every page is
already local the merge is performed immediately.
""".
-spec maybe_merge(t(), bondy_mst:t(), node_id(), hash() | undefined) ->
    {bondy_mst:t(), t(), [event()]}.

maybe_merge(#?MODULE{} = State, Tree, Peer, undefined) ->
    %% Peer is empty; there is nothing to merge. The embedder may wish to
    %% trigger an exchange in the other direction.
    {Tree, State, [{merge_skipped, Peer, peer_empty}]};
maybe_merge(#?MODULE{} = State0, Tree, Peer, PeerRoot) ->
    Max = State0#?MODULE.max_merges,
    MaxSame = State0#?MODULE.max_merges_per_root,
    Merges = State0#?MODULE.merge_buffer,
    Same = count_same_merges(Merges, PeerRoot),

    case Same < MaxSame andalso map_size(Merges) < Max of
        true ->
            ?LOG_DEBUG(#{
                message => <<"Starting merge with peer.">>,
                peer => Peer,
                merge_count => map_size(Merges) + 1,
                max_merges => {Max, MaxSame}
            }),
            State = State0#?MODULE{
                merge_buffer = maps:put(Peer, PeerRoot, Merges)
            },
            merge(State, Tree, Peer);
        false ->
            ?LOG_DEBUG(#{
                message => <<
                    "Skipping merge, merge concurrency limits reached."
                >>,
                peer => Peer,
                merge_count => map_size(Merges) + 1,
                max_merges => {Max, MaxSame}
            }),
            {Tree, State0, [{merge_skipped, Peer, concurrency_limit}]}
    end.

-doc """
Handles an exchange protocol message.

Returns the (possibly advanced) tree, the updated exchange state, and any
events the embedder must act on.
""".
-spec handle(t(), bondy_mst:t(), message()) ->
    {bondy_mst:t(), t(), [event()]}.

handle(#?MODULE{} = State, Tree, #get{from = Peer, root = PeerRoot, set = Set}) ->
    ?LOG_DEBUG(#{
        message => <<"Received GET message">>,
        peer => Peer,
        set_size => sets:size(Set)
    }),

    Store = bondy_mst:store(Tree),

    Missing = sets:filter(
        fun(Hash) -> not bondy_mst_store:has(Store, Hash) end,
        Set
    ),

    ok =
        case sets:is_empty(Missing) of
            true ->
                Map = sets:fold(
                    fun(Hash, Acc) ->
                        maps:put(Hash, bondy_mst_store:get(Store, Hash), Acc)
                    end,
                    #{},
                    Set
                ),
                Msg = #put{from = State#?MODULE.node_id, map = Map},
                send(State, Peer, Msg);
            false ->
                %% We cannot serve these pages — most likely they have been
                %% garbage collected. Decline so the peer abandons rather than
                %% retrying forever.
                Msg = #missing{from = State#?MODULE.node_id},
                send(State, Peer, Msg)
        end,

    %% Serving the request told us the peer's root. We report it rather than
    %% merging inline, so that serving pages remains cheap and concurrent-safe.
    Events =
        case PeerRoot == bondy_mst:root(Tree) of
            true -> [];
            false -> [{peer_root, Peer, PeerRoot}]
        end,

    {Tree, State, Events};
handle(#?MODULE{} = State, Tree0, #put{from = Peer, map = Map}) ->
    case maps:is_key(Peer, State#?MODULE.merge_buffer) of
        true ->
            ?LOG_DEBUG(#{
                message => <<"Received peer data">>,
                peer => Peer,
                payload_size => maps:size(Map)
            }),
            Tree = maps:fold(
                fun(Hash0, Page, Acc0) ->
                    {Hash1, Acc} = bondy_mst:put_page(Acc0, Page),

                    %% Post-condition: input and output hash must agree. They
                    %% diverge when the peer runs a different implementation or
                    %% hashing algorithm, in which case we fail loudly.
                    Hash0 == Hash1 orelse
                        error({inconsistency, Hash0, Page, Hash1}),

                    Acc
                end,
                Tree0,
                Map
            ),
            merge(State, Tree, Peer);
        false ->
            ?LOG_DEBUG(#{
                message => <<
                    "Ignored data from peer. Peer is not in merge set."
                >>,
                peer => Peer,
                payload_size => maps:size(Map)
            }),
            {Tree0, State, []}
    end;
handle(#?MODULE{} = State, Tree, #missing{from = Peer}) ->
    case maps:take(Peer, State#?MODULE.merge_buffer) of
        {_, Merges} ->
            telemetry:execute(
                [bondy_mst, merge, abandoned],
                #{count => 1},
                #{peer => Peer, node => State#?MODULE.node_id}
            ),
            {Tree, State#?MODULE{merge_buffer = Merges}, [
                {merge_abandoned, Peer, unavailable}
            ]};
        error ->
            {Tree, State, []}
    end;
handle(_State, _Tree, Msg) ->
    error({unknown_event, Msg}).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Drives an admitted merge: request what is missing, or complete it.
merge(#?MODULE{} = State, Tree, Peer) ->
    PeerRoot = maps:get(Peer, State#?MODULE.merge_buffer),
    true = PeerRoot =/= undefined,

    MissingSet = bondy_mst:missing_set(Tree, PeerRoot),

    case sets:is_empty(MissingSet) of
        true ->
            ?LOG_DEBUG(#{
                message => <<
                    "All peer pages are now locally available. "
                    "Finishing merge."
                >>,
                peer => Peer
            }),
            do_merge(State, Tree, Peer, PeerRoot);
        false ->
            %% Keep the peer root buffered and leave the tree untouched until
            %% the pages arrive.
            ?LOG_DEBUG(#{
                message => <<"Requesting missing pages from peer.">>,
                missing_count => sets:size(MissingSet),
                peer => Peer
            }),
            Cmd = #get{
                from = State#?MODULE.node_id,
                root = bondy_mst:root(Tree),
                set = MissingSet
            },
            ok = send(State, Peer, Cmd),
            {Tree, State, []}
    end.

%% @private
%% Every page is local: merge without network communication.
do_merge(#?MODULE{} = State0, Tree0, Peer, PeerRoot) ->
    Root = bondy_mst:root(Tree0),
    Tree = bondy_mst:merge(Tree0, Tree0, PeerRoot),
    NewRoot = bondy_mst:root(Tree),

    %% Post-condition: the merged tree must be complete.
    true = sets:is_empty(bondy_mst:missing_set(Tree, NewRoot)),

    %% Drop this merge, plus any other now subsumed by the new root.
    Merges = maps:filter(
        fun(_, V) -> V =/= PeerRoot andalso V =/= NewRoot end,
        State0#?MODULE.merge_buffer
    ),
    State = State0#?MODULE{merge_buffer = Merges},

    Event =
        case Root =/= NewRoot of
            true -> {merged, Peer, Root, NewRoot};
            false -> {in_sync, Peer}
        end,

    {Tree, State, [Event]}.

%% @private
count_same_merges(Merges, Root) ->
    maps:fold(
        fun
            (_, V, Acc) when V == Root -> Acc + 1;
            (_, _, Acc) -> Acc
        end,
        0,
        Merges
    ).

%% @private
send(#?MODULE{callback_mod = Mod, callback_args = ExtraArgs}, Peer, Msg) ->
    erlang:apply(Mod, send, ExtraArgs ++ [Peer, Msg]).

%% @private
validate_callback_mod(Opts) ->
    CallbackMod = maps:get(callback_mod, Opts),

    is_atom(CallbackMod) orelse
        error({badarg, [{callback_mod, CallbackMod}]}),

    CallbackMod.
