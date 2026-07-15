%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_crdt).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
This module implements the logic for an efficient, *state-based* Conflict-Free
Replicated Data Type (CRDT) designed for open, potentially untrusted networks.
It is designed for distributed systems where efficient merging and verification
of large datasets are required.

Anti-entropy merges are performed in the background and without blocking
local operations. The underlying tree is not changed until all the remote
information necessary for the merge is obtained from a peer.

This module allows a set of remote trees that we want to merge with the local
tree to be kept in the state (`#?bondy_mst_crdt.merge_buffer`) and all missing
pages are requested to the remote peers. Once all pages are locally
available, the merge operation is done without network communication and the
local tree is updated.

# CRDT Types
By selecting the type of values stored we can obtain various CRDTs:

1. If value is a boolean indicating if an item is present or not, we obtain
a grow-only set.
2. If value is a last-writer-wins register with a version number then we obtain a
key-value store with last-writer-wins reconciliation.
3. If value is another existing CRDT type, then we obtain a map CRDT with
efficient detection of differing items.

# Supported Consistency models
This CRDT support two modes of operation: eventual consistency and causal
consistency. The default is causal consistency.

### Causal Consistency
Causal consistency is a consistency model in distributed systems that ensures
if one event (for example, sending a message) causally depends on another event
(for example, an earlier message), then all nodes (replicas) in the system will
observe these events in the same causal order.

In simpler terms, if action A causes action B, every node in the distributed
system will always see action A before it sees action B.

In `causal` consistency mode, a full state sync is performed at every gossip
event with the sender's replica.

This CRDT achieves casual consistency without any conditions on the network
topology as is required by causal broadcast.

### Eventual Consistency
If causal consistency is not required, the CRDT can operate in `eventual`
consistency mode, by gossiping individual single operations and applying them as
soon as they are received, while executing periodic syncs to ensure
termination.

# How To Use

This module implements the state and logic for anti-entropy synchronization
exchanges.
The idea is for the user to choose the right processinfrastructure e.g. using
this module as helper for a `gen_server`, `gen_statem` or alternatives e.g.
Partisan equivalents or standard processes.

## Synchronization Messages

Synchronisation messages should be handled by calling `handle/2`. However, it’s
important to note that most messages cannot be handled concurrently. In general,
an MST supports a single writer, so write operations must be serialised by an
Erlang process. However, some write operations that occur during a sync can be
handled concurrently depending on the backend store used.

|Message Type|Purpose|Can be handled concurrently|
|===|===|===|
|`gossip()`|Initiate a full sync or notify a key value change|No|
|`get_cmd()`|Obtain missing data from replica|Yes|
|`put_cmd()`|Responds to a `get_cmd()`|Yes|
|`missing_cmd()`|Responds to a `get_cmd()`|No|

## Network Operations
This module relies on a callback module provided by you that implements the
following callbacks:

* send/2
* broadcast/1

## Options

""").

-record(?MODULE, {
    %% Normally node() but it can be a binary when testing
    node_id :: node_id(),
    callback_mod :: module(),
    callback_args :: list(),
    tree :: bondy_mst:t(),
    consistency_model :: consistency_model(),
    %% Set it to false if you are using a peer service that handles gossip
    %% When true, every gossip message received will be broadcasted again
    fwd_bcast = false :: boolean(),
    %% The interval, measured in milliseconds, between two fwd_bcasts.
    fwd_bcast_interval = 1000 :: integer(),
    last_fwd_bcast_time :: integer(),
    %% The maximum number of concurrent merges.
    %% Bounds the size of 'merge_buffer'.
    max_merges = 1 :: pos_integer(),
    %% The maximum number of concurrent merges having the same root.
    %% This occurs when considering merging with N peers, as two or more of
    %% them might be in sync and hence having the same root hash.
    max_merges_per_root = 1 :: pos_integer(),
    %% max_versions
    %% The max number of versions to keep i.e. the version will not be eligible
    %% for garbage collection.
    max_versions = 10 :: pos_integer(),
    %% version_ttl
    %% The time, measured in milliseconds, after which a version becomes
    %% eligible for garbage collection.
    version_ttl :: pos_integer(),
    %% history
    %% This map's size is bounded by max_versions.
    history = #{} :: #{epoch() => hash()},
    %% merge_buffer
    %% A buffer of the remote MSTs we are merging with.
    %% Its size is bounded by max_merges.
    merge_buffer = #{} :: #{node_id() => hash()},
    %% A queue containing the latest gossiped roots from peers i.e. candidates
    %% for merges.
    %% It colesces base on peer and thus its size is naturally bounded to the
    %% number of peers in the CRDT.
    merge_backlog :: bondy_mst_coalescing_queue:t(),
    %% A queue of delayed broadcasts.
    bcast_backlog :: bondy_mst_coalescing_queue:t()
}).

%% The payload use for broadcasting changes to peers in the CRDT.
%% key and value can be 'undefined' when triggering an exchange.
-record(gossip, {
    from :: node_id(),
    root :: hash(),
    key :: any(),
    value :: any()
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

%% Normally a node() but we allow a binary for simulation purposes
-type node_id() :: node() | binary().
-type consistency_model() :: causal | eventual.
-type opts() ::
    [bondy_mst:opt() | opt()]
    | opts_map().
-type opt() ::
    bondy_mst:opt()
    | {max_merges, pos_integer()}
    | {max_merges_per_root, pos_integer()}
    | {callback_mod, module()}
    | {callback_args, list()}.
-type opts_map() :: #{
    %% bondy_mst
    store => bondy_mst_store:t(),
    hash_algorithm => bondy_mst:hash_algorithm(),
    store_opts => bondy_mst_store:opts(),
    merger => bondy_mst:merger(),
    comparator => bondy_mst:comparator(),
    %%
    max_merges => pos_integer(),
    max_merges_per_root => pos_integer(),
    callback_mod => module(),
    callback_args => list()
}.
-type gossip() :: #gossip{}.
-type get_cmd() :: #get{}.
-type missing_cmd() :: #missing{}.
-type put_cmd() :: #put{}.
-type message() ::
    gossip()
    | get_cmd()
    | put_cmd()
    | missing_cmd().
-type gossip_data() ::
    #{
        from => node_id(),
        root => hash(),
        key => undefined,
        value => undefined
    }
    | #{
        from => node_id(),
        root => hash(),
        key => any(),
        value => any()
    }.
-export_type([t/0]).
-export_type([gossip/0]).
-export_type([node_id/0]).
-export_type([message/0]).
-export_type([gossip_data/0]).

-export([broadcast_pending/1]).
-export([cancel_merge/2]).
-export([gc/1]).
-export([gc/2]).
-export([gossip_data/1]).
-export([gossip_message/2]).
-export([gossip_message/4]).
-export([handle/2]).
-export([is_stale/2]).
-export([merges/1]).
-export([new/2]).
-export([node_id/1]).
-export([put/3]).
-export([put/4]).
-export([root/1]).
-export([tree/1]).
-export([trigger/2]).

%% =============================================================================
%% TELEMETRY EVENTS
%% =============================================================================

-telemetry_event(#{
    event => [?MODULE, broadcast, sent],
    description =>
        <<"Emitted when the CRDT broadcast's a gossip message">>,
    measurements => <<
        "#{system_time => non_neg_integer(), "
        "monotonic_time => non_neg_integer()}"
    >>,
    metadata => <<"#{from => node_id()}">>
}).

-telemetry_event(#{
    event => [?MODULE, broadcast, recv],
    description =>
        <<"Emitted when the CRDT received a gossip message">>,
    measurements => <<
        "#{system_time => non_neg_integer(), "
        "monotonic_time => non_neg_integer()"
        "count => 1, bytes => integer()"
        "}"
    >>,
    metadata => <<"#{from => node_id()}">>
}).

-telemetry_event(#{
    event => [?MODULE, merge, abandoned],
    description =>
        <<"Emitted when the CRDT received a gossip message">>,
    measurements => <<
        "#{system_time => non_neg_integer(), "
        "monotonic_time => non_neg_integer()}"
    >>,
    metadata => <<"#{from => node_id()}">>
}).

%% =============================================================================
%% CALLBACKS
%% =============================================================================

?DOC("""
Called when this module wants to send a message to a peer.

## Example Implementations

### Using `disterl`

```
send(Peer, Msg) ->
    gen_server:cast({CBMod, Peer}, {mst_message, Msg}).
```

### Using `partisan`

```
send(Peer, Msg) ->
    partisan_gen_server:cast({CBMod, Peer}, {mst_message, Msg}).
```


""").
-callback send(Peer :: node_id(), message()) -> ok | {error, any()}.

?DOC("""
Whenever this module wants to send a gossip message it will call
`Module:broadcast/1`.
The callback `Module` is responsible for sending the gossip to some random
peers, either by implementing or using a peer sampling service e.g.
`partisan_plumtree_broadcast`.

## Example using `partisan_plumtree_broadcast`

```
broadcast(Gossip) ->
    partisan:broadcast(Gossip, CBMod).
```
""").
-callback broadcast(Gossip :: gossip()) -> ok | {error, any()}.

?DOC("""
Called when a merge exchange has finished.
""").
-callback on_merge(Peer :: node_id()) -> ok.

%% Extended callbacks (when using callback_args)
-callback send(ExtraArg :: term(), Peer :: node_id(), message()) ->
    ok | {error, any()}.
-callback broadcast(ExtraArg :: term(), Gossip :: gossip()) ->
    ok | {error, any()}.
-callback on_merge(ExtraArg :: term(), Peer :: node_id()) -> ok.

-optional_callbacks([on_merge/1, send/3, broadcast/2, on_merge/2]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Cretes a new MST-based CRDT.

# Options
* `store => bondy_mst_store:t()` - the backend store for this grove
* `merger => bondy_mst:merger()` - the function used by the tree to merge the
values of a key. See `bondy_mst:merger()`
* `comparator => bondy_mst:comparator()` - the function used by the tree to
compare keys for sorting. See `bondy_mst:comparator()`
* `callback_mod => module()` - The module implementing this modules' callbacks
* `callback_args => list()` - Optional extra arguments to be passed to all callback functions
* `consistency_model => causal | eventual` - if `causal`, a full merge will be
done on each update. If `eventual` full merges will only occur then triggered
via `trigger/2`. Default is `causal`
* `max_merges => pos_integer()` - the maximum number of concurrent merges.
Default is `6`
* `max_merges_per_root => pos_integer()` - the maximum number of concurrent
merges having the same root. Default is `1`
* `fwd_bcast => boolean()` - if true, this modules re-broadcasts gossip messages
to peers. Default is `false`
* `fwd_bcast_interval => pos_integer()` - When `fwd_bcast` is enabled, defines
the minimum time, measured in milliseconds, between broadcasts. This is used to
avoid floding the network with too many messages. Default is `1000`
* `max_versions => pos_integer()` - the max number of versions to keep i.e. the
version will not be eligible for garbage collection. Default is `10`
* `version_ttl => pos_integer()` - The time, measured in milliseconds, after
which a version becomes eligible for garbage collection. Default is `60000`
(1 minute).

""").
-spec new(node_id(), opts()) -> CRDT :: t() | no_return().

new(NodeId, Opts) when is_list(Opts) ->
    new(NodeId, maps:from_list(Opts));
new(NodeId, Opts0) when
    (is_atom(NodeId) orelse is_binary(NodeId)) andalso is_map(Opts0)
->
    %% Configure the tree
    TreeOpts = maps:with([store, store_opts, merger, comparator], Opts0),
    Tree = bondy_mst:new(TreeOpts),

    %% Configure the grove
    Opts = maps:with(
        [callback_mod, callback_args, max_merges, max_merges_per_root], Opts0
    ),

    #?MODULE{
        node_id = NodeId,
        callback_mod = validate_callback_mod(Opts),
        callback_args = key_value:get(callback_args, Opts, []),
        tree = Tree,
        consistency_model = key_value:get(consistency_model, Opts, causal),
        fwd_bcast = key_value:get(fwd_bcast, Opts, false),
        fwd_bcast_interval = key_value:get(fwd_bcast_interval, Opts, 1000),
        last_fwd_bcast_time = erlang:monotonic_time(),
        max_merges = key_value:get(max_merges, Opts, 6),
        max_merges_per_root = key_value:get(max_merges_per_root, Opts, 1),
        max_versions = key_value:get(max_versions, Opts, 10),
        version_ttl = key_value:get(version_ttl, Opts, timer:minutes(1)),
        history = #{},
        merge_buffer = #{},
        merge_backlog = bondy_mst_coalescing_queue:new(),
        bcast_backlog = bondy_mst_coalescing_queue:new()
    }.

?DOC("""
Returns the grove's local `node_id`.
""").
-spec node_id(t()) -> node_id().

node_id(#?MODULE{node_id = Val}) ->
    Val.

?DOC("""
Returns the grove's local tree.
""").
-spec tree(t()) -> bondy_mst:t().

tree(#?MODULE{tree = Tree}) ->
    Tree.

%% =============================================================================
%% API: TREE API
%% =============================================================================

?DOC("""
Returns the root of the grove's local tree.
""").
-spec root(t()) -> hash() | undefined.

root(#?MODULE{tree = Tree}) ->
    bondy_mst:root(Tree).

?DOC("""
Calls `bondy_mst:put/3` on the local tree.
If the operation changed the tree (previous and new root differ), it broadcasts
the change to the peers by calling the callback's `Module:broadcast/1` with a
`gossip()`.

When the gossip event is received by the peer it must handle it calling
`handle/2` on its local grove instance which will merge the value locally and
possibly trigger an exchange.
""").
-spec put(CRDT0 :: t(), Key :: any(), Value :: any()) -> CRDT1 :: t().

put(CRDT, Key, Value) ->
    put(CRDT, Key, Value, #{}).

?DOC("""
Calls `bondy_mst:put/3` on the local tree and if the operation changed
the tree (previous and new root differ), it broadcasts the change to the
peers by calling the callback's `Module:broadcast/1` with a `gossip()`.

When the event is received by the peer it must handle it calling `handle/2`
on its local grove instance.

## Options

* `broadcast => boolean` - If `false` it doesn't broadcast the change to
peers. This means you will rely on peers performing periodic anti-entropy
sync exchanges to learn about this change. Default is `true`.
""").
-spec put(CRDT0 :: t(), Key :: any(), Value :: any(), Opts :: key_value:t()) ->
    CRDT1 :: t().

put(CRDT0, Key, Value, Opts) ->
    Store = bondy_mst:store(CRDT0#?MODULE.tree),

    Fun = fun() ->
        NodeId = CRDT0#?MODULE.node_id,
        Tree0 = CRDT0#?MODULE.tree,
        Root0 = bondy_mst:root(Tree0),

        %% We perform the put and update the grove state
        Tree = bondy_mst:put(Tree0, Key, Value),
        CRDT1 = CRDT0#?MODULE{tree = Tree},

        %% We obtain the new root
        Root = bondy_mst:root(Tree),

        %% We store the new root on the version history so that is not
        %% immediately elegible for garbage collection.
        %% The version will automatically elegible when its TTL is reached or
        %% when history has reached its maximum size.
        CRDT = add_history(CRDT1, Root),

        %% We conditionally broadcast
        case Root0 =/= Root andalso key_value:get(broadcast, Opts, true) of
            true ->
                Gossip = #gossip{
                    from = NodeId,
                    root = Root,
                    key = Key,
                    value = Value
                },
                broadcast(CRDT, Gossip);
            _ ->
                CRDT
        end
    end,
    bondy_mst_store:transaction(Store, Fun).

?DOC("""
Triggers a garbage collection.
Garbage collection removes all pages that are not descendants of either the
current root or the roots of versions in the history whose TTL have not been
reached.
""").
-spec gc(t()) -> t().
gc(#?MODULE{} = CRDT) ->
    gc(CRDT, keep_roots(CRDT)).

?DOC("""
Triggers a garbage collection overriding the versions to keep.
Garbage collection removes all pages that are not descendants of either the
current root or the roots in `KeepRoots`.
""").
-spec gc
    (t(), KeepRoots :: [binary()]) -> t();
    (t(), Epoch :: integer()) -> t().

gc(#?MODULE{} = CRDT, Arg) when is_list(Arg) orelse is_integer(Arg) ->
    %% bondy_mst:gc will add the current root when is_list(Arg)
    Tree = bondy_mst:gc(CRDT#?MODULE.tree, Arg),
    CRDT#?MODULE{tree = Tree}.

?DOC("""
Returns the list of peers that have ongoing merges with this node.
""").
-spec merges(t()) -> [node()].

merges(#?MODULE{merge_buffer = Merges}) ->
    maps:keys(Merges).

?DOC("""
Cancels an ongoing merge (if it exists for peer `Peer`).

You should use a fault detector to cancel merges when a peer crashes.
Cancelled merge pages will be purged on the next garbage collection run.
""").
-spec cancel_merge(t(), node_id()) -> ok.

cancel_merge(#?MODULE{merge_buffer = Merges} = CRDT, Peer) ->
    CRDT#?MODULE{merge_buffer = maps:without([Peer], Merges)}.

%% =============================================================================
%% API: ANTI-ENTROPY EXCHANGE PROTOCOL
%% =============================================================================

?DOC("""
Broadcasts all gossip messages in the backlog.
""").
-spec broadcast_pending(t()) -> t().

broadcast_pending(#?MODULE{} = CRDT) ->
    LastTime = CRDT#?MODULE.last_fwd_bcast_time,
    Pred = fun({_, Time}) -> LastTime < Time end,
    broadcast_pending(CRDT, Pred).

?DOC("""
Triggers a full merge by sending the local tree's root to `Peer`.
The exchange might not occur if Peer has reached its `max_merges`.
""").
-spec trigger(t(), node_id()) -> ok.

trigger(#?MODULE{node_id = Peer}, Peer) ->
    ok;
trigger(#?MODULE{} = CRDT, Peer) when is_atom(Peer) ->
    Event = #gossip{
        from = CRDT#?MODULE.node_id,
        root = root(CRDT),
        key = undefined,
        value = undefined
    },
    call_callback(CRDT, send, [Peer, Event]).

?DOC("""
Returns a map with the contents of a `gossip()` message.
""").
-spec gossip_data(gossip()) -> gossip_data().

gossip_data(#gossip{} = Gossip) ->
    #{
        from => Gossip#gossip.from,
        root => Gossip#gossip.root,
        key => Gossip#gossip.key,
        value => Gossip#gossip.value
    }.

?DOC("""
Creates a gossip message.
""").
-spec gossip_message(node_id(), hash()) -> gossip().

gossip_message(Peer, Root) ->
    gossip_message(Peer, Root, undefined, undefined).

?DOC("""
Creates a gossip message.
""").
-spec gossip_message(node_id(), hash(), any(), any()) -> gossip().

gossip_message(Peer, Root, Key, Value) ->
    #gossip{
        from = Peer,
        root = Root,
        key = Key,
        value = Value
    }.

?DOC("""
Returns `true` if `PeerRoot` is not contained in the tree.
""").
-spec is_stale(t(), hash()) -> boolean().

is_stale(#?MODULE{} = CRDT, PeerRoot) ->
    Tree = CRDT#?MODULE.tree,
    Root = bondy_mst:root(Tree),

    case Root == PeerRoot of
        true ->
            false;
        false ->
            MissingSet = bondy_mst:missing_set(Tree, PeerRoot),
            not sets:is_empty(MissingSet)
    end.

?DOC("""
Call this function when your node receives a message or broadcast from a
peer.
""").
-spec handle(t(), message()) -> t().

handle(CRDT0, #gossip{} = Gossip) ->
    Tree0 = CRDT0#?MODULE.tree,
    Peer = Gossip#gossip.from,
    PeerRoot = Gossip#gossip.root,
    Key = Gossip#gossip.key,
    Value = Gossip#gossip.value,

    telemetry:execute(
        [bondy_mst, broadcast, recv],
        #{count => 1, bytes => erlang:external_size(Gossip)},
        #{from => Peer}
    ),

    Root = bondy_mst:root(Tree0),

    case Root == PeerRoot of
        true ->
            ?LOG_DEBUG(#{
                message => <<"No merged required, replicas in sync">>,
                root => encode_hash(PeerRoot),
                peer => Peer
            }),
            CRDT0;
        false when Key == undefined andalso Value == undefined ->
            %% This is a full merge request, so slways try a merge regardless
            %% of consistency model
            maybe_merge(CRDT0, Peer, PeerRoot);
        false ->
            %% We insert the broadcasted change and get the new root
            Tree1 = bondy_mst:put(Tree0, Key, Value),
            CRDT1 = CRDT0#?MODULE{tree = Tree1},
            NewRoot = bondy_mst:root(Tree1),
            %% We will only do a full merge in case model is causal
            Model = CRDT0#?MODULE.consistency_model,

            case Root =/= NewRoot of
                true when Model == causal ->
                    CRDT2 = cancel_merges(CRDT1, NewRoot),
                    CRDT3 = maybe_broadcast(CRDT2, Gossip),

                    case NewRoot =/= PeerRoot of
                        true ->
                            %% We have missing data
                            maybe_merge(CRDT3, Peer, PeerRoot);
                        false ->
                            ?LOG_DEBUG(#{
                                message => <<
                                    "Broadcasted data merged, replicas in sync"
                                >>,
                                root => encode_hash(NewRoot),
                                peer => Peer
                            }),
                            CRDT3
                    end;
                true when Model == eventual ->
                    %% We skip a full merge
                    cancel_merges(CRDT1, NewRoot);
                false when Model == causal ->
                    %% We have missing data, so we try do a full merge
                    maybe_merge(CRDT1, Peer, PeerRoot);
                false when Model == eventual ->
                    %% We skip a full merge
                    CRDT1
            end
    end;
handle(CRDT, #get{from = Peer, root = PeerRoot, set = Set}) ->
    ?LOG_DEBUG(#{
        message => <<"Received GET message">>,
        peer => Peer,
        set_size => sets:size(Set)
    }),
    %% We are being asked to produce a set of pages
    Tree = CRDT#?MODULE.tree,
    Store = bondy_mst:store(Tree),

    %% We determine the hashes we don't have
    Missing = sets:filter(
        fun(Hash) -> not bondy_mst_store:has(Store, Hash) end,
        Set
    ),

    ok =
        case sets:is_empty(Missing) of
            true ->
                %% We collect the pages for the requested hashes and reply
                Map = sets:fold(
                    fun(Hash, Acc) ->
                        Page = bondy_mst_store:get(Store, Hash),
                        maps:put(Hash, Page, Acc)
                    end,
                    #{},
                    Set
                ),
                Msg = #put{from = CRDT#?MODULE.node_id, map = Map},
                call_callback(CRDT, send, [Peer, Msg]);
            false ->
                %% We don't have all the pages, we reply a missing message
                Msg = #missing{from = CRDT#?MODULE.node_id},
                call_callback(CRDT, send, [Peer, Msg])
        end,

    case PeerRoot == bondy_mst:root(Tree) of
        true ->
            CRDT;
        false ->
            %% TODO split this into a separate action executed by the wrapping
            %% server, so that the GET can be handled concurrently
            maybe_merge(CRDT, Peer, PeerRoot)
    end;
handle(CRDT, #put{from = Peer, map = Map}) ->
    case maps:is_key(Peer, CRDT#?MODULE.merge_buffer) of
        true ->
            ?LOG_DEBUG(#{
                message => <<"Received peer data">>,
                peer => Peer,
                payload_size => maps:size(Map)
            }),
            Tree = maps:fold(
                fun(Hash0, Page, Acc0) ->
                    {Hash1, Acc} = bondy_mst:put_page(Acc0, Page),

                    %% Post-condition: Input and output hash should be the same
                    %% A difference might occur when the peer runs a different
                    %% implementation or when is using a different hashing
                    %% algorithm, in which case we fail.
                    Hash0 == Hash1 orelse
                        error({inconsistency, Hash0, Page, Hash1}),

                    Acc
                end,
                CRDT#?MODULE.tree,
                Map
            ),
            %% TODO split this into a separate action executed by the wrapping
            %% server, so that the GET can be handled concurrently
            merge(CRDT#?MODULE{tree = Tree}, Peer);
        false ->
            ?LOG_DEBUG(#{
                message => <<
                    "Ignored data from peer. Peer is not in merge set."
                >>,
                peer => Peer,
                payload_size => maps:size(Map)
            }),
            %% REVIEW: Will this happen when a previous merge has been evicted
            %% from the merge buffer?
            CRDT
    end;
handle(CRDT, #missing{from = Peer}) ->
    case maps:take(Peer, CRDT#?MODULE.merge_buffer) of
        {_, Merges} ->
            %% Abandon merge
            telemetry:execute(
                [bondy_mst, merge, abandoned],
                #{count => 1},
                #{peer => Peer, node => CRDT#?MODULE.node_id}
            ),
            CRDT#?MODULE{merge_buffer = Merges};
        error ->
            CRDT
    end;
handle(_CRDT, Msg) ->
    error({unknown_event, Msg}).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
validate_callback_mod(Opts) ->
    CallbackMod = maps:get(callback_mod, Opts),

    is_atom(CallbackMod) orelse
        error({badarg, [{callback_mod, CallbackMod}]}),

    bondy_mst_utils:implements_behaviour(CallbackMod, ?MODULE) orelse
        error(
            io_lib:format(
                "Expected ~p to implement behaviour ~p",
                [CallbackMod, ?MODULE]
            )
        ),
    CallbackMod.

%% @private
call_callback(
    #?MODULE{callback_mod = CallbackMod, callback_args = ExtraArgs},
    Function,
    Args
) ->
    erlang:apply(CallbackMod, Function, ExtraArgs ++ Args).

%% @private
-spec maybe_broadcast(t(), gossip()) -> t().

maybe_broadcast(#?MODULE{fwd_bcast = false} = CRDT, _) ->
    CRDT;
maybe_broadcast(CRDT0, #gossip{key = undefined, value = undefined} = Gossip) ->
    Now = erlang:monotonic_time(),
    Elapsed = elapsed(Now, CRDT0#?MODULE.last_fwd_bcast_time),

    %% We make sure we broadcast pending gossip messages first
    CRDT = broadcast_pending(CRDT0),

    case Elapsed >= CRDT#?MODULE.fwd_bcast_interval of
        true ->
            broadcast(CRDT, Gossip);
        false ->
            %% Delay broadcast, coalescing by Peer
            Backlog = bondy_mst_coalescing_queue:in(
                CRDT#?MODULE.bcast_backlog,
                Gossip#gossip.from,
                {Gossip, Now}
            ),
            CRDT#?MODULE{bcast_backlog = Backlog}
    end;
maybe_broadcast(CRDT0, Gossip) ->
    %% We make sure we broadcast pending gossip messages first
    CRDT = broadcast_pending(CRDT0),
    broadcast(CRDT, Gossip).

%% @private
broadcast(CRDT0, Gossip) ->
    case call_callback(CRDT0, broadcast, [Gossip]) of
        ok ->
            telemetry:execute(
                [bondy_mst, broadcast, sent],
                #{count => 1, bytes => erlang:external_size(Gossip)},
                #{from => CRDT0#?MODULE.node_id}
            ),
            CRDT0#?MODULE{last_fwd_bcast_time = erlang:monotonic_time()};
        {error, Reason} ->
            ?LOG_ERROR(#{
                message => <<"Error while broadcasting gossip message">>,
                data => Gossip,
                reason => Reason
            }),
            CRDT0
    end.

%% private
broadcast_pending(#?MODULE{} = CRDT, Pred) when is_function(Pred, 1) ->
    B0 = CRDT#?MODULE.bcast_backlog,

    case bondy_mst_coalescing_queue:out_when(B0, Pred) of
        {empty, B0} ->
            CRDT;
        {{value, {Gossip, _Time}}, B1} ->
            _ = broadcast(CRDT, Gossip),
            broadcast_pending(CRDT#?MODULE{bcast_backlog = B1}, Pred)
    end.

%% @private
-spec maybe_merge(t(), node_id(), hash() | undefined) -> t().

maybe_merge(#?MODULE{} = CRDT, Peer, undefined) ->
    %% Peer is empty, so we trigger an exchange in the other direction
    ok = trigger(CRDT, Peer),
    CRDT;
maybe_merge(#?MODULE{} = CRDT0, Peer, PeerRoot) ->
    Max = CRDT0#?MODULE.max_merges,
    MaxSame = CRDT0#?MODULE.max_merges_per_root,
    Merges = CRDT0#?MODULE.merge_buffer,
    Same = count_same_merges(Merges, PeerRoot),
    Size = map_size(Merges),

    case Same < MaxSame andalso Size < Max of
        true ->
            CRDT = CRDT0#?MODULE{
                merge_buffer = maps:put(Peer, PeerRoot, Merges)
            },
            ?LOG_INFO(#{
                message => <<"Starting merge with peer.">>,
                peer => Peer,
                merge_count => Size + 1,
                max_merges => {Max, MaxSame}
            }),
            merge(CRDT, Peer);
        false ->
            ?LOG_DEBUG(#{
                message => <<
                    "Skipping merge, merge concurrency limits reached."
                >>,
                peer => Peer,
                merge_count => Size + 1,
                max_merges => {Max, MaxSame}
            }),
            CRDT0
    end.

%% @private
count_same_merges(Merges, Root) ->
    maps:fold(
        fun
            (_, V, Acc) when V == Root ->
                Acc + 1;
            (_, _, Acc) ->
                Acc
        end,
        0,
        Merges
    ).

%% @private
%% This is called directly only when receiving a PUT. Otherwise it is called
%% by maybe_merge/2.
merge(CRDT0, Peer) ->
    Tree = CRDT0#?MODULE.tree,

    PeerRoot = maps:get(Peer, CRDT0#?MODULE.merge_buffer),
    %% Pre-condition
    true = PeerRoot =/= undefined,

    MissingSet = bondy_mst:missing_set(Tree, PeerRoot),

    case sets:is_empty(MissingSet) of
        true ->
            %% All pages are locally available, so we perform the merge and
            %% update the local tree.
            ?LOG_DEBUG(#{
                message => <<
                    "All peer pages are now locally available. "
                    "Finishing merge."
                >>,
                peer => Peer
            }),
            CRDT = do_merge(CRDT0, Peer, PeerRoot),
            ok = on_merge(CRDT, Peer),
            CRDT;
        false ->
            %% We still have missing pages, so we request them and keep the
            %% remote reference in a buffer until we receive those pages from
            %% peer.
            ?LOG_DEBUG(#{
                message => <<"Requesting missing pages from peer.">>,
                missing_count => sets:size(MissingSet),
                peer => Peer
            }),
            Root = bondy_mst:root(Tree),
            Cmd = #get{
                from = CRDT0#?MODULE.node_id,
                root = Root,
                set = MissingSet
            },
            ok = call_callback(CRDT0, send, [Peer, Cmd]),
            CRDT0
    end.

%% @private
do_merge(CRDT0, Peer, PeerRoot) ->
    Tree0 = CRDT0#?MODULE.tree,
    Root = bondy_mst:root(Tree0),

    Tree1 = bondy_mst:merge(Tree0, Tree0, PeerRoot),
    NewRoot = bondy_mst:root(Tree1),

    %% Post-condition
    true = sets:is_empty(bondy_mst:missing_set(Tree1, NewRoot)),

    NewMerges = maps:filter(
        fun(_, V) -> V =/= PeerRoot andalso V =/= NewRoot end,
        CRDT0#?MODULE.merge_buffer
    ),

    CRDT1 = CRDT0#?MODULE{tree = Tree1, merge_buffer = NewMerges},

    case Root =/= NewRoot of
        true ->
            %% We store the new root on the version history so that is not
            %% immediately elegible for garbage collection.
            %% The version will automatically elegible when its TTL is reached
            %% or when history has reached its maximum size.
            CRDT2 = add_history(CRDT1, NewRoot),
            CRDT = maybe_gc(CRDT2),

            case NewRoot =/= PeerRoot of
                true ->
                    Event = #gossip{
                        from = CRDT#?MODULE.node_id,
                        root = NewRoot,
                        key = undefined,
                        value = undefined
                    },
                    call_callback(CRDT, send, [Peer, Event]);
                false ->
                    ok
            end,
            CRDT;
        false ->
            CRDT1
    end.

%% @private
on_merge(CRDT0, Peer) ->
    ?LOG_INFO(#{
        message => <<"Finished merge with peer.">>,
        peer => Peer
    }),

    CRDT = broadcast_pending(CRDT0),

    try
        bondy_mst_utils:apply_lazy(
            CRDT#?MODULE.callback_mod,
            on_merge,
            1,
            CRDT#?MODULE.callback_args ++ [Peer],
            fun() -> ok end
        )
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                message => "Error while evaluating callback on_merge/1",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end.

%% @private
maybe_gc(CRDT) ->
    %% We preserve all roots being merged and all history roots
    gc(CRDT, keep_roots(CRDT)).

%% @private
encode_hash(undefined) -> undefined;
encode_hash(Bin) -> binary:encode_hex(Bin).

%% @private
cancel_merges(CRDT, NewRoot) ->
    %% We remove any ongoing merges matching the merged NewRoot.
    Merges = maps:filter(
        fun(_, V) -> V =/= NewRoot end,
        CRDT#?MODULE.merge_buffer
    ),

    %% We remove any pending merges matching the merged NewRoot.
    Backlog = bondy_mst_coalescing_queue:filter(
        CRDT#?MODULE.merge_backlog,
        fun(_, V) -> V =/= NewRoot end
    ),

    CRDT#?MODULE{merge_buffer = Merges, merge_backlog = Backlog}.

%% @private
add_history(#?MODULE{} = CRDT, Root) ->
    Epoch = erlang:monotonic_time(),
    TTL = CRDT#?MODULE.version_ttl,

    %% We purge expired versions
    H1 = maps:filter(
        fun(Epoch0, _Root) -> elapsed(Epoch, Epoch0) =< TTL end,
        CRDT#?MODULE.history
    ),
    %% We add the new version
    H = maps:put(Epoch, Root, H1),

    CRDT#?MODULE{history = H}.

%% @private
keep_roots(#?MODULE{} = CRDT) ->
    MergeRoots = maps:values(CRDT#?MODULE.merge_buffer),
    HistoryRoots = maps:values(CRDT#?MODULE.history),
    MergeRoots ++ HistoryRoots.

%% @private
elapsed(Start, Stop) ->
    elapsed(Start, Stop, millisecond).

%% @private
elapsed(Start, Stop, Unit) ->
    erlang:convert_time_unit(Start - Stop, native, Unit).
