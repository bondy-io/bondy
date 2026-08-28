%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst).

-feature(maybe_expr, enable).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
This module implements a Merkle Search Tree (MST), a probabilistic
data structure optimised for efficient storage and retrieval of
key-value pairs.

The MST construction is from Alex Auvolat and François Taïani's
2019 paper [*Merkle Search Trees: Efficient State-Based CRDTs in
Open Networks*](https://inria.hal.science/hal-02303490/document)
(SRDS 2019, Inria HAL-02303490). This Erlang implementation was
ported from the authors' [reference Elixir
prototype](https://gitlab.inria.fr/aauvolat/mst_exp) and extended
with additional features (multiple storage backends, configurable
GC, deletion).

An MST is as an efficient, *state-based* Conflict-Free Replicated Data
Type (CRDT) designed for open, potentially untrusted networks. It is designed
for distributed systems where efficient merging and verification of large
datasets are required.

By combining the properties of Merkle trees (for secure hashing and partial
verification) with search-tree–like organization (for efficient data access and
updates), MSTs aim to reduce both the *bandwidth overhead* and *update
complexity* associated with typical CRDTs in large-scale distributed
environments.

MSTs support:
- Deterministic contruction - the MST algorithm produces a single possible
representation for a given set of items
- Keys are sorted lexicographically
- Efficient key-value insertion and retrieval
- Merkle-based verification for integrity checks
- Custom comparators and mergers

An MST is a search tree, similar to a B-tree in the sense that internal tree
nodes contain several values that define a partition of the keys in which the
children values are separated.

The tree is divided in layers which are numbered starting at layer `0` which
corresponds to the layer of the leaf nodes.

The tree nodes in layer `L` are blocks of consecutive items whose boundaries
corresponds to items of layers `L' > L`.

Deterministic randomness obtained by hashind the values is used to determine
the tree shape. Values stored in the MST are asigned a layer by computing
their hash and writing that value in base `B`. The layer to which an item is
assigned is the layer whose numner is the length of the longest prefix of the
hash.
""").

-record(bondy_mst, {
    store :: bondy_mst_store:t(),
    %% `comparator` is a compare function for keys
    comparator :: comparator(),
    %% `merger` is a function for merging two items that have the same key
    merger :: merger(),
    %% By default we user Erlang External Term Format unless a function is
    %% provided
    serializer :: optional(bondy_mst_store:serializer()),
    hash_algorithm :: atom()
}).

-type t() :: #?MODULE{}.
-type opts() :: [opt()] | opts_map().
-type opt() ::
    {hash_algorithm, hash_algorithm()}
    | {store, module()}
    | {store_opts, key_value:t()}
    | {merger, merger()}
    | {comparator, comparator()}.
-type opts_map() :: #{
    store => module(),
    hash_algorithm => hash_algorithm(),
    store_opts => key_value:t(),
    merger => merger(),
    comparator => comparator()
}.
-type hash_algorithm() :: sha256 | sha512.
-type comparator() :: fun((key(), key()) -> eq | lt | gt).
-type merger() :: fun((key(), value(), value()) -> value()).
%% Fold
-type fold_fun() :: fun(({key(), value()}, any()) -> any()).
-type fold_opts() :: [fold_opt()].
-type fold_opt() ::
    {root, hash()}
    | {first, key()}
    | {match_spec, term()}
    | {stop, key()}
    | {keys_only, boolean()}
    | {limit, pos_integer() | infinity}.
-type fold_pages_fun() :: fun(({hash(), bondy_mst_page:t()}, any()) -> any()).
%% Opaque token returned by maybe_roll_for_seal/1. Carries the backend
%% module and its self-contained seal job so a worker process can run the
%% seal (run_seal_job/1) without holding the tree.
-opaque seal_job() :: {module(), term()}.

%% Retained GC-abort reports (see `gc_aborts/0`). Kept small: any occurrence
%% is a defect, so a handful of reports is plenty of evidence, and the ring
%% must never become a memory sink on a node that is already misbehaving.
-define(GC_ABORTS_KEY, {?MODULE, gc_aborts}).
-define(GC_ABORTS_MAX, 20).
-define(GC_ABORT_MAX_HASHES, 32).
%% Long enough for a not-yet-visible insert to land, short enough not to hold
%% up the collector meaningfully — this runs only on the abort path.
-define(GC_ABORT_REPROBE_MS, 50).
-define(SWEPT_TAB, bondy_mst_recent_swept).

%% Default for the `verify_gc` post-conditions (`verify_published_root/2`,
%% `verify_post_sweep/2`). ON in test builds, OFF in production — each check
%% costs a full `missing_set/2` walk, which is right for a suite and wrong for
%% a hot path. `application:set_env(bondy_mst, verify_gc, _)` overrides either
%% way, which is how a field node is armed for diagnosis.
-ifdef(BONDY_MST_VERIFY).
-define(VERIFY_DEFAULT, true).
-else.
-define(VERIFY_DEFAULT, false).
-endif.

-export_type([t/0]).
-export_type([opt/0]).
-export_type([opts/0]).
-export_type([opts_map/0]).
-export_type([comparator/0]).
-export_type([merger/0]).
-export_type([hash_algorithm/0]).
-export_type([seal_job/0]).

%% Defined in bondy_mst.hrl
-export_type([level/0]).
-export_type([key/0]).
-export_type([value/0]).
-export_type([hash/0]).

-export([capabilities/1]).
-export([close/1]).
-export([flush/1]).
-export([maybe_roll_for_seal/1]).
-export([run_seal_job/1]).
-export([seal_job_pack_id/1]).
-export([complete_seal/2]).
-export([seal_in_flight/1]).
-export([destroy/1]).
-export([delete/2]).
-export([diff_to_list/2]).
-export([dump/1]).
-export([first/1]).
-export([fold/3]).
-export([fold/4]).
-export([fold_pages/4]).
-export([foreach/2]).
-export([foreach/3]).
-export([forget_gc_aborts/0]).
-export([gc/1]).
-export([gc_aborts/0]).
-export([recent_swept/0]).
-export([verify_default/0]).
-export([forget_swept/0]).
-export([gc/2]).
-export([get/2]).
-export([get/3]).
-export([keys/1]).
-export([last/1]).
-export([last_n/3]).
-export([merge/2]).
-export([merge/3]).
-export([missing_set/2]).
-export([new/0]).
-export([new/1]).
-export([put/2]).
-export([put/3]).
-export([put_batch/2]).
-export([put_page/2]).
-export([root/1]).
-export([store/1]).
-export([set_store/2]).
-export([to_list/1]).
-export([to_list/2]).
-export([truncate/2]).

-export([format_error/2]).

%% =============================================================================
%% TELEMETRY EVENTS
%% =============================================================================

-telemetry_event(#{
    event => [?MODULE, gc, start],
    description =>
        <<"Emitted at the start of the garbage collection execution">>,
    measurements => <<
        "#{system_time => non_neg_integer(), "
        "monotonic_time => non_neg_integer()}"
    >>,
    metadata => <<"#{}">>
}).

-telemetry_event(#{
    event => [?MODULE, gc, stop],
    description =>
        <<"Emitted at the end of the garbage collection execution">>,
    measurements => <<
        "#{system_time => non_neg_integer(), "
        "monotonic_time => non_neg_integer()}"
    >>,
    metadata => <<"#{freed_count := integer(), freed_bytes := integer()}">>
}).

-telemetry_event(#{
    event => [?MODULE, gc, exception],
    description =>
        <<"Emitted when garbage collection fails">>,
    measurements => <<
        "#{system_time => non_neg_integer(), "
        "monotonic_time => non_neg_integer()}"
    >>,
    metadata => <<"#{}">>
}).

-telemetry_event(#{
    event => [?MODULE, merge, start],
    description =>
        <<"Emitted at the start of the merge execution">>,
    measurements => <<
        "#{system_time => non_neg_integer(), "
        "monotonic_time => non_neg_integer()}"
    >>,
    metadata => <<"#{}">>
}).

-telemetry_event(#{
    event => [?MODULE, merge, stop],
    description =>
        <<"Emitted at the end of the merge execution">>,
    measurements => <<
        "#{system_time => non_neg_integer(), "
        "monotonic_time => non_neg_integer()}"
    >>,
    metadata => <<"#{}">>
}).

-telemetry_event(#{
    event => [?MODULE, merge, exception],
    description =>
        <<"Emitted when merge fails">>,
    measurements => <<
        "#{system_time => non_neg_integer(), "
        "monotonic_time => non_neg_integer()}"
    >>,
    metadata => <<"#{}">>
}).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Create a new Merkle Search Tree using the default store.
The same as calling `new(#{})`.
""").
-spec new() -> t().

new() ->
    new(#{}).

?DOC("""
Creates a new MST instance with configurable options.

This structure can be used as a CRDT set with only true keys (default)
or as a CRDT map if a proper merger function is given.
### Options

* `store => bondy_mst_store:t()` - Defaults to an instance of
`bondy_mst_map_store`
* `merger => merger()` - a merger function.
Defaults to the grow-only set merger function `merger/3`
* `comparator => comparator()` - a key comparator function.
Defaults to `comparator/2`

Returns a new MST instance.
""").
-spec new(Opts :: opts()) -> t().

new(Opts) when is_list(Opts) ->
    new(maps:from_list(Opts));
new(Opts) when is_map(Opts); is_list(Opts) ->
    Comparator = key_value:get(comparator, Opts, fun comparator/2),
    is_function(Comparator, 2) orelse
        badarg(
            Opts, comparator, <<"a 'bondy_mst:comparator()' function.">>
        ),

    Merger = key_value:get(merger, Opts, fun merger/3),
    is_function(Merger, 3) orelse
        badarg(
            Opts, merger, <<"a 'bondy_mst:merger()' function">>
        ),

    Algo = key_value:get(hash_algorithm, Opts, sha256),
    Algo == sha256 orelse Algo == sha512 orelse
        badarg(Opts, hash_algorithm, <<"either 'sha256' or 'sha512'.">>),

    Store =
        maybe
            Mod = key_value:get(store, Opts, bondy_mst_map_store),
            true ?= bondy_mst_utils:implements_behaviour(Mod, bondy_mst_store),
            StoreOpts = key_value:get(store_opts, Opts, #{}),
            bondy_mst_store:open(Mod, Algo, StoreOpts)
        else
            false ->
                badarg(
                    Opts,
                    store,
                    <<"a module implementing the 'bondy_mst_store' behaviour.">>
                )
        end,

    #?MODULE{
        store = Store,
        comparator = Comparator,
        merger = Merger,
        hash_algorithm = Algo
    }.

?DOC("""
Returns the store capabilities.
""").
-spec capabilities(t()) -> map().

capabilities(#?MODULE{store = Store}) ->
    bondy_mst_store:capabilities(Store).

?DOC("""
Gracefully closes the tree's backend store, preserving any persisted state so a
later `new/1` against the same store options restores it. For a durable backend
this flushes the current root and pending buffers and releases file descriptors;
for an in-memory backend (`ets`/`map`) it is a no-op (the data is freed when the
owning process exits). Use this — NOT `destroy/1` — when stopping a tree whose
data must survive a restart.
""").
-spec close(t()) -> ok.

close(#?MODULE{store = Val}) ->
    bondy_mst_store:close(Val).

?DOC("""
Forces the tree's staged state (the current root and any buffered pages)
durable WITHOUT closing the backend. For a durable backend this is the
per-commit durability barrier: the on-disk root advances so a later `new/1`
resumes from the latest committed root rather than replaying from the
beginning. For an in-memory backend (`ets`/`map`) it is a no-op. Returns
`{ok, Tree}` with the staged-state bookkeeping cleared, or `{error, Reason}`
if the durable write failed (the in-memory root is unchanged and the next
`flush/1`/`close/1` retries).
""").
-spec flush(t()) -> {ok, t()} | {error, term()}.

flush(#?MODULE{store = Store0} = T) ->
    case bondy_mst_store:flush(Store0) of
        {ok, Store1} ->
            {ok, T#?MODULE{store = Store1}};
        {error, _} = Error ->
            Error
    end.

?DOC("""
Rolls the backend's incoming buffer aside for an asynchronous seal when its
threshold is crossed and no seal is in flight, returning a `seal_job()` for
a worker to execute off the caller's process.

For a durable backend that supports it this is the entry point to the
off-critical-path seal: `{rolled, Job, Tree1}` — run `Job` via
`run_seal_job/1` (typically in a linked worker), then finalise with
`complete_seal/2` using `seal_job_pack_id(Job)`. `{defer, Tree1}` means a
seal is already in flight (the in-flight=1 cap fired — apply backpressure
rather than starting a second rewrite). `{noop, Tree1}` means nothing to do.

For an in-memory backend (`ets`/`map`) — which never seals — this is always
`{noop, Tree}`.
""").
-spec maybe_roll_for_seal(t()) ->
    {rolled, seal_job(), t()} | {defer, t()} | {noop, t()}.

maybe_roll_for_seal(#?MODULE{store = Store0} = T) ->
    case bondy_mst_store:maybe_roll_for_seal(Store0) of
        {rolled, Job, Store1} ->
            {rolled, Job, T#?MODULE{store = Store1}};
        {defer, Store1} ->
            {defer, T#?MODULE{store = Store1}};
        {noop, Store1} ->
            {noop, T#?MODULE{store = Store1}}
    end.

?DOC("""
Executes a `seal_job()` produced by `maybe_roll_for_seal/1`. Self-contained
and stateless — it holds no tree or store reference and mutates no live
state — so it is designed to run in a separate (linked) worker process while
the owner keeps serving writes and reads. Returns `ok` or `{error, _}`; on
error the owner must NOT `complete_seal/2`.
""").
-spec run_seal_job(seal_job()) -> ok | {error, term()}.

run_seal_job({Mod, Job}) ->
    Mod:run_seal_job(Job).

?DOC("""
The target pack id of a `seal_job()` — the argument to `complete_seal/2`
once the worker reports the job done.
""").
-spec seal_job_pack_id(seal_job()) -> pos_integer().

seal_job_pack_id({Mod, Job}) ->
    Mod:seal_job_pack_id(Job).

?DOC("""
Finalises the asynchronous seal whose worker has completed `run_seal_job/1`
for `PackId`: commits it and mounts the new sealed view so reads move from
the in-flight snapshot to the durable pack. Returns the updated tree, or
`{error, _}` (treat as fatal — a reopen re-mounts the durable pack).
""").
-spec complete_seal(t(), PackId :: pos_integer()) ->
    {ok, t()} | {error, term()}.

complete_seal(#?MODULE{store = Store0} = T, PackId) ->
    case bondy_mst_store:complete_seal(Store0, PackId) of
        {ok, Store1} ->
            {ok, T#?MODULE{store = Store1}};
        {error, _} = Error ->
            Error
    end.

?DOC("""
Whether the backend has an asynchronous seal in flight (rolled but not yet
completed). Always `false` for in-memory backends.
""").
-spec seal_in_flight(t()) -> boolean().

seal_in_flight(#?MODULE{store = Store}) ->
    bondy_mst_store:seal_in_flight(Store).

?DOC("""
Destroys the tree by destroying its backend store. Irreversible: a durable
backend's on-disk data is DELETED. Distinct from `close/1`, which preserves
persisted state, and from `delete/2`, which removes a single key from the tree.
""").
-spec destroy(t()) -> ok.

destroy(#?MODULE{store = Val}) ->
    bondy_mst_store:destroy(Val).

?DOC("""
Returns the tree's root hash.
""").
-spec root(Tree :: t()) -> hash() | undefined.

root(#?MODULE{store = Store}) ->
    bondy_mst_store:get_root(Store).

?DOC("""
Returns the tree's store.
""").
-spec store(t()) -> bondy_mst_store:t().

store(#?MODULE{store = Val}) ->
    Val.

?DOC("""
Returns the tree with its store reference replaced by `Store`.

This is the setter counterpart to `store/1`. It exists for tests
and tooling that perform an out-of-band operation on the store
(e.g. forcing a seal, rotating an fd) and need to thread the
returned store back into the tree wrapper without rebuilding it.
Callers must guarantee that `Store` is a valid store of the same
backend module as the tree was opened with — no validation is
done here.
""").
-spec set_store(t(), bondy_mst_store:t()) -> t().

set_store(#?MODULE{} = T, Store) ->
    T#?MODULE{store = Store}.

?DOC("""
Returns the value associated with key `Key`.
""").
-spec get(T :: t(), Key :: key()) -> Value :: any().

get(#?MODULE{} = T, Key) ->
    %% Call do get as root might be undefined
    do_get(T, Key, root(T)).

?DOC("""
Returns the value associated with key `Key` starting at root `Root`.
This allows to read from a previous version.
""").
-spec get(T :: t(), Key :: key(), Root :: binary()) -> Value :: any().

get(#?MODULE{} = T, Key, Root) when is_binary(Root) ->
    do_get(T, Key, Root).

?DOC("""
Returns the first key-value pair in the MST or `undefined` if empty.
""").
-spec first(T :: t()) -> Value :: {key(), value()} | undefined.

first(#?MODULE{} = T) ->
    first(T, root(T)).

?DOC("""
Returns the last key-value pair in the MST or `undefined` if empty.
""").
-spec last(T :: t()) -> Value :: {key(), value()} | undefined.

last(#?MODULE{} = T) ->
    last(T, root(T)).

?DOC("""
List all items.
""").
-spec to_list(t()) -> [{key(), value()}].

to_list(#?MODULE{} = T) ->
    to_list(T, root(T)).

?DOC("""
List all items.
""").
-spec to_list(t(), hash() | undefined) -> [{key(), value()}].

to_list(#?MODULE{}, undefined) ->
    [];
to_list(#?MODULE{} = T, Root) when is_binary(Root) ->
    lists:reverse(
        fold(T, fun(E, Acc) -> [E | Acc] end, [], [{root, Root}])
    ).

?DOC("""
Calls `Fun(Elem)` for each element `Elem` in the tree, starting from its
current root.
This function is used for its side effects and the evaluation order is
defined to be the same as the order of the elements in the tree.

The same as calling `foreach(T, root(T))`.
""").
-spec foreach(t(), fun(({key(), value()}) -> ok)) -> ok.

foreach(#?MODULE{} = T, Fun) ->
    foreach(T, Fun, []).

?DOC("""
Calls `Fun(Elem)` for each element `Elem` in the tree, starting from
`Root`.
This function is used for its side effects and the evaluation order is
defined to be the same as the order of the elements in the tree.
""").
-spec foreach(t(), fun(({key(), value()}) -> ok), Opts :: list()) -> ok.

foreach(#?MODULE{store = Store} = T, Fun, Opts) ->
    Root = key_value:get_lazy(root, Opts, fun() -> root(T) end),
    do_foreach(Store, Fun, Opts, Root).

?DOC("""
Calls `Fun(Elem, AccIn)` on successive elements of tree `T`, starting
from the current root with `AccIn == Acc0`. `Fun/2` must return a new
accumulator, which is passed to the next call. The function returns the final
value of the accumulator. `Acc0` is returned if the tree is empty.
""").
-spec fold(t(), Fun :: fold_fun(), AccIn :: any()) -> AccOut :: any().

fold(T, Fun, AccIn) ->
    fold(T, Fun, AccIn, []).

?DOC("""
Calls `Fun(Elem, AccIn)` on successive elements of tree `T`, starting
from the current root with `AccIn == Acc0`. `Fun/2` must return a new
accumulator, which is passed to the next call. The function returns the final
value of the accumulator. `Acc0` is returned if the tree is empty.
""").
-spec fold(t(), Fun :: fold_fun(), AccIn :: any(), Opts :: fold_opts()) ->
    AccOut :: any().

fold(#?MODULE{store = Store} = T, Fun, AccIn, Opts) ->
    Root = key_value:get_lazy(root, Opts, fun() -> root(T) end),
    do_fold(Store, Fun, AccIn, Opts, Root).

?DOC("""

""").
-spec fold_pages(
    t(), Fun :: fold_pages_fun(), AccIn :: any(), Opts :: fold_opts()
) ->
    AccOut :: any().

fold_pages(#?MODULE{store = Store} = T, Fun, AccIn, Opts) when
    is_function(Fun, 2) andalso (is_map(Opts) orelse is_list(Opts))
->
    Root = key_value:get_lazy(root, Opts, fun() -> root(T) end),
    do_fold_pages(Store, Fun, AccIn, Opts, Root).

?DOC("""
List all items.
""").
-spec keys(t()) -> [{key(), value()}].

keys(#?MODULE{} = T) ->
    lists:reverse(fold(T, fun({K, _}, Acc) -> [K | Acc] end, [])).

?DOC("""
Computes the difference between two MSTs (or between an MST and a
previous root of the same store) and returns it as a list of
`{Key, Value}` pairs.

When the second argument is an MST handle, both stores and roots are
used. When it is a binary root hash (or `undefined`), the first MST's
store is used for both sides and the diff is taken against that root.
Pages shared by hash between the two roots are pruned from the
descent, so the walk is O(diff) rather than O(tree).

A binary root that does not resolve in the store (typically because GC
has pruned it) is treated as `undefined`, and the result is equivalent
to `to_list(T1)`. Callers that need different fallback semantics
should pre-check the page's reachability.
""").
-spec diff_to_list(t(), t() | hash() | undefined) -> [{key(), value()}].

diff_to_list(#?MODULE{} = T1, #?MODULE{} = T2) ->
    diff_to_list(
        T1,
        T1#?MODULE.store,
        root(T1),
        T2#?MODULE.store,
        root(T2)
    );
diff_to_list(#?MODULE{store = Store} = T, undefined) ->
    diff_to_list(T, Store, root(T), Store, undefined);
diff_to_list(#?MODULE{store = Store} = T, OtherRoot) when
    is_binary(OtherRoot)
->
    case bondy_mst_store:get(Store, OtherRoot) of
        undefined ->
            %% Previous root has been GC'd; fall back to full list.
            diff_to_list(T, Store, root(T), Store, undefined);
        _Page ->
            diff_to_list(T, Store, root(T), Store, OtherRoot)
    end.

?DOC("""
Get the last `N` items of the tree, or the last `N` items strictly
before given upper bound `TopBound` if non `undefined`.
""").
last_n(#?MODULE{} = T, TopBound, N) ->
    last_n(T, TopBound, N, root(T)).

?DOC("""
Inserts a key in the tree. The same as calling `put(T, Key, true)`.
""").
-spec put(t(), key()) -> t().

put(#?MODULE{} = T, Key) ->
    put(T, Key, true).

?DOC("""
Inserts a key-value pair into the MST.

If key `Key` already exists in tree `Tree1`, the old associated value is
merged with `Value` by calling the configured `merger` function. The function
returns a new map `Tree2` containing the new association and the old
associations in `Tree1`.

The call fails with an exception if the tree has not been initialised with a
`merger` function supporting the type of `Value`.
""").
-spec put(Tree1 :: t(), Key :: key(), Value :: value()) -> Tree2 :: t().

put(#?MODULE{store = Store0} = T, Key, Value) ->
    Fun = fun() ->
        Level = calc_level(T, Key),
        {Root, Store1} = put_at(T, Key, Value, Level),
        Store = bondy_mst_store:set_root(Store1, Root),
        T#?MODULE{store = Store}
    end,
    bondy_mst_store:transaction(Store0, Fun).

?DOC("""
Inserts each `{Key, Value}` pair in `Items` into the tree.

For batches of more than one entry the implementation builds a small
volatile in-process MST from `Items` and merges it into the receiver
in a single tree traversal, amortising the per-event spine rebuild
that successive `put/3` calls would do. The receiver's `comparator`,
`merger`, and `hash_algorithm` are used; the temporary tree uses a
map-backed store that is discarded once the merge completes.

The temporary tree is built bottom-up from the comparator-sorted
items rather than by sequential `put/3` calls: the MST is
history-independent (a given key set has a single canonical
structure), so constructing the canonical pages directly yields a
byte-identical tree while serialising and hashing each page exactly
once — instead of rehashing the insertion spine once per item, which
profiling showed was ~86% of `put_batch`'s page serialisation work.

Keys that occur more than once in `Items` are pre-merged with the
receiver's `merger` in batch order (earlier value as the merger's
existing-value argument), exactly as sequential `put/3` calls would.
Collisions between an entry's key and a key already in the receiver
invoke the receiver's `merger` exactly as `put/3` would.
""").
-spec put_batch(Tree1 :: t(), Items :: [{key(), value()}]) -> Tree2 :: t().

put_batch(#?MODULE{} = T, []) ->
    T;
put_batch(#?MODULE{} = T, [{K, V}]) ->
    put(T, K, V);
put_batch(#?MODULE{} = T, Items) when is_list(Items) ->
    B0 = new(#{
        store => bondy_mst_map_store,
        store_opts => #{},
        comparator => T#?MODULE.comparator,
        merger => T#?MODULE.merger,
        hash_algorithm => T#?MODULE.hash_algorithm
    }),
    B = bulk_build(B0, Items),
    do_merge(T, B, root(B), put_batch).

?DOC("""
Structurally deletes a key from the MST.

This performs a true structural deletion, removing the key-value pair from the
tree and merging affected subtrees. This is primarily used for garbage
collection of tombstones.

If the key is not found in the tree, the tree is returned unchanged.

Returns a new tree with the key removed.
""").
-spec delete(Tree1 :: t(), Key :: key()) -> Tree2 :: t().

delete(#?MODULE{store = Store0} = T, Key) ->
    Fun = fun() ->
        case root(T) of
            undefined ->
                T;
            Root ->
                Level = calc_level(T, Key),
                case delete_at(T, Key, Level, Store0, Root) of
                    not_found ->
                        T;
                    {undefined, Store1} ->
                        %% Tree became empty, handle undefined root
                        T#?MODULE{store = Store1};
                    {NewRoot, Store1} when is_binary(NewRoot) ->
                        Store = bondy_mst_store:set_root(Store1, NewRoot),
                        T#?MODULE{store = Store}
                end
        end
    end,
    bondy_mst_store:transaction(Store0, Fun).

?DOC("""
Structurally removes every key `=< Watermark` from the tree, keeping
only the suffix of keys strictly greater than `Watermark`. Returns a
new tree whose root is the canonical MST of the remaining key set.

Unlike calling `delete/2` once per stale key — which is `O(P·log N)` in
the prefix size `P` and rebuilds a spine per deletion — this walks only
the **left spine** of the tree once: it rewrites `O(log N)` pages and
leaves the dropped subtrees unreferenced for the store's garbage
collector to reclaim (the same page lifecycle as `split/4`/`put/3`).

The result is byte-identical (same root hash) to the equivalent
sequence of `delete/2` calls and to a fresh tree built from
`{K | K > Watermark}`, because the MST is history-independent: a given
key set has a single canonical structure.

Used by compaction to drop the stable prefix once it has been folded
into the projection/checkpoint. Returns the tree unchanged when it is
empty.
""").
-spec truncate(Tree1 :: t(), Watermark :: key()) -> Tree2 :: t().

truncate(#?MODULE{store = Store0} = T, Watermark) ->
    Fun = fun() ->
        case root(T) of
            undefined ->
                T;
            Root ->
                {NewRoot, Store1} = truncate_at(T, Store0, Root, Watermark),
                Store =
                    case NewRoot of
                        undefined ->
                            %% `free/3` already nulled the store root when
                            %% it freed the old root page (mirrors the
                            %% empty-tree branch of delete/2).
                            Store1;
                        _ when is_binary(NewRoot) ->
                            bondy_mst_store:set_root(Store1, NewRoot)
                    end,
                T#?MODULE{store = Store}
        end
    end,
    bondy_mst_store:transaction(Store0, Fun).

?DOC("""

""").
-spec put_page(t(), bondy_mst_page:t()) -> {Hash :: hash(), t()}.

put_page(#?MODULE{store = Store0} = T, Page) ->
    Fun = fun() ->
        {Hash, Store} = bondy_mst_store:put(Store0, Page),
        {Hash, T#?MODULE{store = Store}}
    end,
    bondy_mst_store:transaction(Store0, Fun).

?DOC("""
Merges two MSTs into a single tree.
""").
-spec merge(T1 :: t(), T2 :: t()) -> NewT1 :: t().

merge(#?MODULE{} = T1, #?MODULE{} = T2) ->
    do_merge(T1, T2, root(T2), merge).

?DOC("""
Merges two MSTs into a single tree.
""").
-spec merge(T1 :: t(), T2 :: t(), Root :: hash() | undefined) -> NewT1 :: t().

merge(#?MODULE{} = T1, #?MODULE{} = T2, Root) when
    is_binary(Root) orelse Root == undefined
->
    do_merge(T1, T2, Root, merge).

%% @private
%% `Op` names the CALLER for the publication post-condition below — a merge
%% that publishes a root referencing uncopied donor pages is fatal only when
%% the donor store is then discarded (`put_batch/2`), so the two call sites
%% must be distinguishable in the evidence.
do_merge(#?MODULE{store = Store0} = T1, #?MODULE{} = T2, Root, Op) ->
    telemetry:span(
        [bondy_mst, merge],
        #{},
        fun() ->
            Fun = fun() ->
                {NewRoot, Store1} = merge_aux(T1, T2, Store0, root(T1), Root),
                Store = bondy_mst_store:set_root(Store1, NewRoot),
                T1#?MODULE{store = Store}
            end,
            Result = bondy_mst_store:transaction(Store0, Fun),
            ok = verify_published_root(Result, Op),
            {Result, #{}}
        end
    ).

?DOC("""
Returns the hashes of the pages identified by root hash that are missing
from the store.
""").
-spec missing_set(t(), Root :: binary()) -> [hash()].

missing_set(#?MODULE{store = Store}, Root) ->
    %% Backends build the set as a `sets:set()` internally; this wrapper is
    %% the single normalisation point to the spec'd list, so no caller needs
    %% shape-dispatching.
    case bondy_mst_store:missing_set(Store, Root) of
        L when is_list(L) -> L;
        Set -> sets:to_list(Set)
    end.

?DOC("""
Dumps the structure of the MST for debugging purposes.
""").
-spec dump(t()) -> ok.

dump(#?MODULE{store = Store} = T) ->
    dump(Store, root(T)).

?DOC("""

""").
-spec gc(t()) -> t().

gc(#?MODULE{} = T) ->
    gc(T, []).

?DOC("""
Reclaims pages by reachability from `KeepRoots` (plus the current root,
which is always protected).

Reachability is the ONLY collection mode. Structural sharing makes any
reachability-blind sweep unsound: `free/3` tombstones a page whose
content-addressed hash may still be referenced — by an older root, a
pinned peer root, a merge accumulator, or a content-identical twin the
tree keeps by reference — and no timestamp on the tombstone can say
that those references are gone. Only a mark from the live roots can.

## Precondition — the caller must establish liveness

`gc/2` MUST be serialized with the tree's writers, OR be given a keep-root
list that already covers every root any writer may publish. This is not a
`concurrent_writes` matter: that capability governs `put`/`get`, and
`bondy_mst_ets_store` declares it `true`. Collection is different: a writer
that publishes a NEW root after the mark has its root page swept — the mark
never saw it. There is no ordering that fixes this: with unsynchronized
writers the live-root set is not knowable.

`bondy_oplog` satisfies the precondition by construction: compaction is a
`gen_server:call` into the instance, and every tree mutation runs in that same
process, so the root marked from IS the only live root.

The collector additionally refuses to sweep when the current root is
already unservable — see the abort below; a hole would otherwise be amplified
into subtree loss, because the mark walk skips missing pages silently.
""").
-spec gc(t(), KeepRoots :: [hash()]) -> t().

gc(#?MODULE{store = Store0} = T, KeepRoots) when is_list(KeepRoots) ->
    telemetry:span(
        [bondy_mst, gc],
        #{},
        fun() ->
            Fun = fun() ->
                %% Protect the current version.
                Arg = [root(T) | KeepRoots],
                case unservable_current_root(T) of
                    false ->
                        {Store, Meta} = bondy_mst_store:gc(Store0, Arg),
                        T1 = T#?MODULE{store = Store},
                        ok = record_swept(Meta),
                        ok = verify_post_sweep(T1, Store),
                        ?LOG_DEBUG(#{
                            description => "Garbage collection completed",
                            name => maps:get(name, Meta, <<"unknown">>),
                            freed_count => maps:get(freed_count, Meta, 0),
                            freed_bytes => maps:get(freed_bytes, Meta, 0)
                        }),
                        {T1, Meta};
                    {true, Missing} ->
                        %% ABORT, do not sweep. The list-mode collector marks
                        %% by walking the keep-roots THROUGH PRESENT PAGES
                        %% (`fold_pages/4` skips a missing page silently), so
                        %% a hole under the current root would under-mark its
                        %% whole subtree below the hole and the sweep would
                        %% then delete live, reachable pages — amplifying a
                        %% small anomaly into large, permanent data loss. A
                        %% hole in the CURRENT root is always a defect
                        %% upstream (pinned peer roots, by contrast, are
                        %% legitimately partial mid-pull); surface it loudly
                        %% and keep the garbage for a cycle instead of making
                        %% the damage worse.
                        %%
                        %% The store name is the instance id for the trees
                        %% `bondy_oplog` opens, which is what makes the event
                        %% attributable to a shard on a dashboard.
                        Name = bondy_mst_store:name(Store0),
                        Report = abort_report(Store0, Name, T, Missing),
                        ok = record_gc_abort(Report),
                        ?LOG_ERROR(#{
                            description =>
                                "MST garbage collection aborted: the current "
                                "root is unservable (missing pages). Sweeping "
                                "would amplify the loss; keeping garbage for "
                                "this cycle. Full report retained in-node: "
                                "bondy_mst:gc_aborts().",
                            name => Name,
                            missing_count => length(Missing),
                            classification => maps:get(classification, Report),
                            missing => Missing
                        }),
                        telemetry:execute(
                            [bondy_mst, gc, aborted],
                            #{count => 1, missing_count => length(Missing)},
                            #{
                                reason => unservable_root,
                                name => Name,
                                classification =>
                                    maps:get(classification, Report)
                            }
                        ),
                        {T, #{freed_count => 0, freed_bytes => 0}}
                end
            end,
            bondy_mst_store:transaction(Store0, Fun)
        end
    ).

?DOC("""
The most recent GC-abort reports retained by this node, newest first.

The abort is the own-root page-loss tripwire; this is the evidence it
captures. A field occurrence is rare and its log line ages out of a
platform's log buffer long before anyone looks (exactly what happened on Fly
s25), so the report is ALSO kept in-node and can be recovered at any later
time with `bondy_mst:gc_aborts()` — no log shipper, no retention window.

Each report carries the store `name` (the instance id, for the trees
`bondy_oplog` opens), the `root`, every missing page hash with its
per-hash state at abort time and again after a short delay, and the
`classification` those states imply:

- `deleted`      — at least one hash is `absent` from the store. A page a
                   live root references was DELETED: a store-layer fault, or
                   a consumer that collected without establishing liveness.
- `tombstoned`   — the pages are present but `free/3`-marked, so a walk that
                   called them missing did not learn that from the store: a
                   consumer / read-path fault.
- `transient`    — the pages were readable on re-probe: the miss was a
                   visibility artifact and nothing was lost.
- `mixed`        — more than one of the above across the missing set.

That distinction is the whole point: it says WHICH layer to investigate,
which a hash list alone does not.
""").
-spec gc_aborts() -> [map()].

gc_aborts() ->
    persistent_term:get(?GC_ABORTS_KEY, []).

?DOC("""
Discards the retained GC-abort reports (see `gc_aborts/0`).
""").
-spec forget_gc_aborts() -> ok.

forget_gc_aborts() ->
    persistent_term:erase(?GC_ABORTS_KEY),
    ok.

?DOC("""
The page hashes most recently reclaimed by this node's collectors, newest
first, when `bondy_mst.trace_swept` is enabled (otherwise empty).

Diagnosis instrument. If a root is missing pages, intersecting its missing set
with this answers the question that names the faulting party: pages that ARE
here were reclaimed by a collector whose mark set did not include them, which
means whoever published that root derived it from a base the collector had
already moved past. Pages that are NOT here were never collected, so they were
never stored.
""").
-spec verify_default() -> boolean().

verify_default() ->
    %% Observable so a test can assert the safety net is actually armed. A
    %% post-condition that silently compiled itself out would be worse than
    %% none: the suite would report green while checking nothing.
    ?VERIFY_DEFAULT.

?DOC("""
The page hashes most recently reclaimed by this node's collectors, newest
first, when `bondy_mst.trace_swept` is enabled (otherwise empty).
""").
-spec recent_swept() -> [hash()].

recent_swept() ->
    case ets:whereis(?SWEPT_TAB) of
        undefined -> [];
        Tab -> [H || {H} <- ets:tab2list(Tab)]
    end.

%% @private
%% Deliberately ETS and NOT `persistent_term`, unlike the abort ring next to
%% it. An abort is rare, so a `persistent_term:put` per abort costs nothing; a
%% SWEEP happens on every collection (~50/s on a busy shard), and each
%% `persistent_term:put` of a large term forces a global scan of every process
%% heap. Recording there slowed the collector enough to change the timing of
%% the very race this instrument exists to observe — the measurement suppressed
%% the phenomenon.
record_swept(#{swept := [_ | _] = Swept}) ->
    _ = ets:insert(swept_tab(), [{H} || H <- Swept]),
    ok;
record_swept(_) ->
    ok.

?DOC("""
Discards the recorded sweep window (see `recent_swept/0`).

The window is UNBOUNDED while `trace_swept` is on, because a bounded one is
worse than useless here: any eviction policy cheap enough to run per sweep
also empties the window most of the time, and an empty window answers "these
pages were never collected" for pages that were — the exact false negative
this instrument exists to rule out. The consumer owns the lifetime and must
clear it per observation window.
""").
-spec forget_swept() -> ok.

forget_swept() ->
    case ets:whereis(?SWEPT_TAB) of
        undefined ->
            ok;
        Tab ->
            true = ets:delete_all_objects(Tab),
            ok
    end.

%% @private
swept_tab() ->
    case ets:whereis(?SWEPT_TAB) of
        undefined ->
            try
                ets:new(?SWEPT_TAB, [named_table, public, set, {keypos, 1}])
            catch
                error:badarg -> ?SWEPT_TAB
            end;
        Tab ->
            Tab
    end.

%% @private
%% Publication post-condition, gated on the same `verify_gc` diagnosis mode as
%% `verify_post_sweep/2`.
%%
%% An operation must never install a root whose pages are not all in the
%% RECEIVER's store. `merge/3` is the one that can: MST merge prunes any
%% subtree whose hash both sides share, which is sound only if the receiver
%% really holds it — and `put_batch/2` merges from a volatile map-backed store
%% that is discarded immediately afterwards, so anything wrongly pruned is
%% gone for good. That failure looks exactly like the s16 signature: a
%% brand-new root referencing pages that were never stored here.
verify_published_root(#?MODULE{store = Store} = T, Op) ->
    case application:get_env(bondy_mst, verify_gc, ?VERIFY_DEFAULT) of
        false ->
            ok;
        _ ->
            case unservable_current_root(T) of
                false ->
                    ok;
                {true, Missing} ->
                    Name = bondy_mst_store:name(Store),
                    Report = (abort_report(Store, Name, T, Missing))#{
                        reason => {published_unservable_root, Op}
                    },
                    ok = record_gc_abort(Report),
                    ?LOG_ERROR(#{
                        description =>
                            "MST published an unservable root: the operation "
                            "installed a root referencing pages that are not "
                            "in this store. Full report retained in-node: "
                            "bondy_mst:gc_aborts().",
                        name => Name,
                        op => Op,
                        missing_count => length(Missing),
                        classification => maps:get(classification, Report)
                    }),
                    ok
            end
    end.

%% @private
%% Post-sweep self-check on the collector.
%%
%% Reachability-mode `gc/2` is only entered when the current root is servable
%% (the abort above establishes that), and the sweep only ever deletes pages
%% the mark walk did not reach. Those two facts together mean the collector
%% MUST leave the current root servable. If it does not, the sweep itself
%% deleted a live, reachable page — which is a defect in this module, not in a
%% consumer, and the distinction is otherwise almost impossible to make after
%% the fact because a concurrent writer can re-create a content-identical page
%% and heal the hole before anyone looks.
%%
%% Costs a second full walk of the tree, so it is opt-in via
%% `bondy_mst.verify_gc` (default `false`) and belongs in test and
%% field-diagnosis runs, not in the steady state. The report lands in the same
%% in-node ring as the aborts (`gc_aborts/0`) and is tagged `swept_live` to
%% distinguish "the collector refused because it found damage" from "the
%% collector CAUSED damage".
verify_post_sweep(T, Store) ->
    case application:get_env(bondy_mst, verify_gc, ?VERIFY_DEFAULT) of
        false ->
            ok;
        _ ->
            case unservable_current_root(T) of
                false ->
                    ok;
                {true, Missing} ->
                    Name = bondy_mst_store:name(Store),
                    Report = (abort_report(Store, Name, T, Missing))#{
                        reason => swept_live
                    },
                    ok = record_gc_abort(Report),
                    ?LOG_ERROR(#{
                        description =>
                            "MST garbage collection SWEPT A LIVE PAGE: the "
                            "current root was servable on entry and is "
                            "unservable on exit, so the sweep deleted a page "
                            "reachable from it. Full report retained in-node: "
                            "bondy_mst:gc_aborts().",
                        name => Name,
                        missing_count => length(Missing),
                        classification => maps:get(classification, Report),
                        missing => Missing
                    }),
                    ok
            end
    end.

%% @private
%% Builds the forensic report. Probes each missing hash immediately and again
%% after a short delay, so a page that merely had not become visible yet is
%% distinguished from one that is really gone. Bounded: only the first
%% `?GC_ABORT_MAX_HASHES` hashes are probed and retained, so a pathological
%% miss set cannot blow up the node's heap or stall the collector.
abort_report(Store, Name, T, Missing) ->
    Probed = lists:sublist(Missing, ?GC_ABORT_MAX_HASHES),
    Immediate = [{H, bondy_mst_store:page_state(Store, H)} || H <- Probed],
    ok = timer:sleep(?GC_ABORT_REPROBE_MS),
    Delayed = [{H, bondy_mst_store:page_state(Store, H)} || H <- Probed],
    #{
        name => Name,
        root => root(T),
        at => erlang:system_time(millisecond),
        monotonic => erlang:monotonic_time(millisecond),
        missing_count => length(Missing),
        probed => length(Probed),
        immediate => Immediate,
        delayed => Delayed,
        classification => classify_states([S || {_, S} <- Delayed])
    }.

%% @private
classify_states(States) ->
    Kinds = lists:usort([kind(S) || S <- States]),
    case Kinds of
        [K] -> K;
        [] -> transient;
        _ -> mixed
    end.

%% @private
kind(absent) -> deleted;
kind({tombstoned, _}) -> tombstoned;
kind(live) -> transient;
kind(unknown) -> unknown.

%% @private
%% Newest-first ring in `persistent_term`. Aborts are rare (any occurrence is
%% a defect), so the write cost of persistent_term is irrelevant here, and it
%% buys survival across every process death short of a VM restart — which is
%% precisely what an ETS table owned by a crashing instance would not.
record_gc_abort(Report) ->
    Old = persistent_term:get(?GC_ABORTS_KEY, []),
    New = lists:sublist([Report | Old], ?GC_ABORTS_MAX),
    persistent_term:put(?GC_ABORTS_KEY, New),
    ok.

%% @private
%% `{true, MissingHashes}` when the current root's subtree has pages absent
%% from the store — the precondition under which a list-mode sweep is unsafe.
unservable_current_root(T) ->
    case root(T) of
        undefined ->
            false;
        Root ->
            case missing_set(T, Root) of
                [] -> false;
                Missing -> {true, Missing}
            end
    end.

format_error(Reason, [{_M, _F, _As, Info} | _]) when is_list(Info) ->
    ErrorInfo = proplists:get_value(error_info, Info, #{}),
    %% `cause' is optional: reading it without a default crashed the formatter
    %% whenever a raise supplied error_info without one.
    Cause = maps:get(cause, ErrorInfo, #{}),
    Cause#{
        reason => io_lib:format("~p: ~p", [?MODULE, Reason])
    };
format_error(Reason, _) ->
    #{reason => io_lib:format("~p: ~p", [?MODULE, Reason])}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
badarg(Opts, Opt, Expected) when is_atom(Opt) ->
    badarg(Opts, atom_to_binary(Opt), Expected);
badarg(Opts, Opt, Expected) when is_binary(Opt) ->
    erlang:error(
        badarg,
        [Opts],
        [
            {error_info, #{
                module => ?MODULE,
                cause => #{
                    1 => <<
                        "value for option '",
                        Opt/binary,
                        "' is invalid. ",
                        "Expected ",
                        Expected/binary
                    >>
                }
            }}
        ]
    ).

%% @private
%% The default comparator function used in the MST.
comparator(A, B) when A < B -> lt;
comparator(A, B) when A == B -> eq;
comparator(A, B) when A > B -> gt.

%% -----------------------------------------------------------------------------
%% @private
%% The default merger function, assuming MST as a set. (where all
%% values are `true`).
merger(_Key, true, true) ->
    true.

%% @private
%% Computes the level of a key by hashing and counting the leading
%% zero hex digits of the digest. A leading zero hex digit is exactly a
%% leading zero 4-bit nibble, so we walk the raw digest's nibbles
%% directly rather than allocating a hex-encoded binary (2x the digest
%% size) only to scan it for "0" characters. Byte-for-byte identical
%% level to the previous `binary:encode_hex/1`-based implementation.
calc_level(#?MODULE{hash_algorithm = Algo}, Key) ->
    count_leading_zero_nibbles(bondy_mst_utils:hash(Key, Algo), 0).

%% @private
%% Counts the leading zero 4-bit nibbles of a binary digest.
count_leading_zero_nibbles(<<0:4, Rest/bitstring>>, Acc) ->
    count_leading_zero_nibbles(Rest, Acc + 1);
count_leading_zero_nibbles(_, Acc) ->
    Acc.

%% @private
%% Compares two keys using the MST’s configured comparator.
compare(#?MODULE{comparator = Fun}, A, B) ->
    Fun(A, B).

%% @private
%% Merges two values using the MST’s configured merger function.
merge_values(#?MODULE{merger = Fun}, Key, A, B) ->
    Fun(Key, A, B).

%% @private
-spec do_get(T :: t(), Key :: key(), Root :: binary() | undefined) ->
    Value :: any().

do_get(#?MODULE{}, _, undefined) ->
    undefined;
do_get(#?MODULE{} = T, Key, Root) ->
    case bondy_mst_store:get(T#?MODULE.store, Root) of
        undefined ->
            undefined;
        Page ->
            Low = bondy_mst_page:low(Page),
            List = bondy_mst_page:list(Page),
            do_get(T, Key, Low, List)
    end.

%% @private
%% Recursively retrieves a value from the MST.
do_get(T, Key, Low, []) ->
    do_get(T, Key, Low);
do_get(T, Key, Low, [{K, V, Low2} | Rest]) ->
    case compare(T, Key, K) of
        eq ->
            V;
        lt ->
            do_get(T, Key, Low);
        gt ->
            do_get(T, Key, Low2, Rest)
    end.

first(#?MODULE{}, undefined) ->
    undefined;
first(#?MODULE{} = T, Root) ->
    case bondy_mst_store:get(T#?MODULE.store, Root) of
        undefined ->
            undefined;
        Page ->
            case bondy_mst_page:low(Page) of
                Low when is_binary(Low) ->
                    %% Anything reachable from `low` has keys smaller
                    %% than the leftmost entry — descend.
                    first(T, Low);
                undefined ->
                    %% No left subtree: the first entry's key IS the
                    %% leftmost. Its right-subtree (`_R`) is irrelevant
                    %% for this lookup — `R` may be a hash on internal
                    %% pages whose `low` was emptied by a prior
                    %% `delete/2` and is `undefined` only on leaves.
                    case bondy_mst_page:list(Page) of
                        [] ->
                            undefined;
                        [{K, V, _R} | _] ->
                            {K, V}
                    end
            end
    end.

last(#?MODULE{}, undefined) ->
    undefined;
last(#?MODULE{} = T, Root) ->
    case bondy_mst_store:get(T#?MODULE.store, Root) of
        undefined ->
            undefined;
        Page ->
            case bondy_mst_page:list(Page) of
                [] ->
                    undefined;
                L ->
                    case lists:last(L) of
                        {K, V, undefined} ->
                            %% No right subtree: this entry's key is
                            %% the rightmost.
                            {K, V};
                        {_K, _V, Next} when is_binary(Next) ->
                            %% Right subtree exists — descend.
                            last(T, Next)
                    end
            end
    end.

%% @private
last_n(#?MODULE{}, _, _, undefined) ->
    [];
last_n(#?MODULE{} = T, TopBound, N, Root) ->
    case bondy_mst_store:get(T#?MODULE.store, Root) of
        undefined ->
            [];
        Page ->
            Low = bondy_mst_page:low(Page),
            List = bondy_mst_page:list(Page),
            do_last_n(T, TopBound, N, Low, List)
    end.

%% @private
do_last_n(T, TopBound, N, Low, []) ->
    last_n(T, TopBound, N, Low);
do_last_n(T, TopBound, N, Low, [{K, V, Low2} | Rest]) ->
    case TopBound == undefined orelse compare(T, TopBound, K) == gt of
        true ->
            Items0 = do_last_n(T, TopBound, N, Low2, Rest),
            Items =
                case length(Items0) < N of
                    true ->
                        [{K, V} | Items0];
                    false ->
                        Items0
                end,
            Cnt = length(Items),
            case Cnt < N of
                true ->
                    last_n(T, TopBound, N - Cnt, Low) ++ Items;
                false ->
                    Items
            end;
        false ->
            last_n(T, TopBound, N, Low)
    end.

%% -----------------------------------------------------------------------------
%% Bulk canonical construction (put_batch's temporary tree)
%% -----------------------------------------------------------------------------
%% Builds the canonical MST of `Items` bottom-up into `B0`'s (map-backed)
%% store. Because the MST is deterministic/history-independent, this
%% produces pages byte-identical to those a sequence of `put/3` calls
%% would converge on, but serialises + hashes each page exactly once
%% instead of rehashing the insertion spine once per item.
%%
%% Construction: within any contiguous key range, the items carrying the
%% range's maximum level `M` are exactly the entries of the range's top
%% page (no higher-level separator splits them), and the runs of
%% lower-level items between consecutive level-`M` items form the page's
%% child subtrees (`low` for the run before the first entry, the entry's
%% right-child for the run after it). Recursing on each run yields the
%% canonical tree of the whole set.

%% @private
bulk_build(#?MODULE{store = Store0} = B0, Items) ->
    Sorted = sort_items(B0, Items),
    Leveled = [{K, V, calc_level(B0, K)} || {K, V} <- Sorted],
    {Root, Store1} = build_canonical(Leveled, Store0),
    Store =
        case Root of
            undefined ->
                Store1;
            _ when is_binary(Root) ->
                bondy_mst_store:set_root(Store1, Root)
        end,
    B0#?MODULE{store = Store}.

%% @private
%% Comparator-sorted unique items. Duplicate keys are pre-merged with the
%% tree's `merger` in batch order: the earlier occurrence is passed as the
%% merger's existing-value argument — the same call sequential `put/3`s
%% would make. The sort is made stable by tie-breaking on the original
%% batch index, so merge order never depends on `lists:sort/2` internals.
sort_items(T, Items) ->
    Indexed = lists:enumerate(Items),
    Sorted = lists:sort(
        fun({IA, {KA, _}}, {IB, {KB, _}}) ->
            case compare(T, KA, KB) of
                lt -> true;
                gt -> false;
                eq -> IA =< IB
            end
        end,
        Indexed
    ),
    merge_duplicates(T, [KV || {_, KV} <- Sorted]).

%% @private
merge_duplicates(_, []) ->
    [];
merge_duplicates(T, [{K, V} | Rest]) ->
    merge_duplicates(T, K, V, Rest).

%% @private
merge_duplicates(T, K, V, [{K2, V2} | Rest]) ->
    case compare(T, K, K2) of
        eq ->
            merge_duplicates(T, K, merge_values(T, K, V, V2), Rest);
        lt ->
            [{K, V} | merge_duplicates(T, K2, V2, Rest)]
    end;
merge_duplicates(_, K, V, []) ->
    [{K, V}].

%% @private
%% Recursively builds the canonical subtree of a sorted, unique
%% `[{Key, Value, Level}]` run. Returns `{RootHash | undefined, Store}`.
build_canonical([], Store) ->
    {undefined, Store};
build_canonical(Items, Store0) ->
    Max = lists:max([L || {_, _, L} <- Items]),
    {LowRun, Groups} = lists:splitwith(
        fun({_, _, L}) -> L < Max end, Items
    ),
    {LowHash, Store1} = build_canonical(LowRun, Store0),
    {Entries, Store2} = build_entries(Groups, Max, Store1),
    Page = bondy_mst_page:new(Max, LowHash, Entries),
    bondy_mst_store:put(Store2, Page).

%% @private
%% `Groups` starts with a level-`Max` item; pair each such separator with
%% the run of lower-level items that follows it (its right-child subtree).
build_entries([], _, Store) ->
    {[], Store};
build_entries([{K, V, Max} | Rest0], Max, Store0) ->
    {Run, Rest} = lists:splitwith(fun({_, _, L}) -> L < Max end, Rest0),
    {RightHash, Store1} = build_canonical(Run, Store0),
    {Entries, Store} = build_entries(Rest, Max, Store1),
    {[{K, V, RightHash} | Entries], Store}.

%% @private
put_at(T, Key, Value, Level) ->
    put_at(T, Key, Value, Level, T#?MODULE.store, root(T)).

%% @private
put_at(_T, Key, Value, Level, Store, undefined) ->
    NewPage = bondy_mst_page:new(Level, undefined, [{Key, Value, undefined}]),
    bondy_mst_store:put(Store, NewPage);
put_at(T, Key, Value, Level, Store0, Hash) when is_binary(Hash) ->
    case bondy_mst_store:get(Store0, Hash) of
        undefined ->
            %% Dangling page: this (sub)tree root references a hash that
            %% resolves in no store — the same condition `split/4` and
            %% `merge_aux/5` already recover from (see the dangling-page
            %% recovery note above `log_dangling_page/5`). Recover the same
            %% way: log once with context and treat the missing subtree as
            %% empty, delegating to the `undefined`-root clause to insert a
            %% fresh single-entry page. The dropped content re-heals via
            %% anti-entropy. Without this guard the missing page crashed the
            %% owning `bondy_oplog_instance` gen_server with a
            %% `function_clause` in `bondy_mst_page:list/1` — taking the
            %% supervisor subtree down with it.
            log_dangling_page(
                "put_at: dangling page, treating subtree as empty",
                T,
                Store0,
                Hash,
                Key
            ),
            put_at(T, Key, Value, Level, Store0, undefined);
        Page ->
            [First | _] = bondy_mst_page:list(Page),
            case bondy_mst_page:level(Page) of
                PageLevel when PageLevel < Level ->
                    put_above(T, Key, Value, Level, Hash, Store0);
                PageLevel when PageLevel == Level ->
                    Store = bondy_mst_store:free(Store0, Hash, Page),
                    put_alongside(T, Key, Value, Level, First, Store, Page);
                PageLevel when PageLevel > Level ->
                    Store = bondy_mst_store:free(Store0, Hash, Page),
                    put_below(T, Key, Value, Level, First, Store, Page)
            end
    end.

%% @private
put_above(T, Key, Value, Level, Root, Store0) ->
    {Low, High, Store} = split(T, Store0, Root, Key),
    NewRootPage = bondy_mst_page:new(Level, Low, [{Key, Value, High}]),
    bondy_mst_store:put(Store, NewRootPage).

%% @private
put_alongside(T, Key, Value, Level, {K0, _, _}, Store0, Page) ->
    List0 = bondy_mst_page:list(Page),
    Low = bondy_mst_page:low(Page),
    PageLevel = bondy_mst_page:level(Page),

    case compare(T, Key, K0) of
        lt ->
            {LowA, LowB, Store} = split(T, Store0, Low, Key),
            List = [{Key, Value, LowB} | List0],
            NewPage = bondy_mst_page:new(Level, LowA, List),
            bondy_mst_store:put(Store, NewPage);
        Other when Other == gt orelse Other == eq ->
            {List1, Store} = put_after_first(T, Key, Value, Store0, List0),
            NewPage = bondy_mst_page:new(PageLevel, Low, List1),
            bondy_mst_store:put(Store, NewPage)
    end.

%% @private
put_below(T, Key, Value, Level, {K0, _, _}, Store0, Page) ->
    List0 = bondy_mst_page:list(Page),
    Low0 = bondy_mst_page:low(Page),
    PageLevel = bondy_mst_page:level(Page),

    case compare(T, Key, K0) of
        lt ->
            {Low, Store} = put_at(T, Key, Value, Level, Store0, Low0),
            NewPage = bondy_mst_page:new(PageLevel, Low, List0),
            bondy_mst_store:put(Store, NewPage);
        gt ->
            {List, Store} = put_sub_after_first(
                T, Key, Value, Store0, Level, List0
            ),
            NewPage = bondy_mst_page:new(PageLevel, Low0, List),
            bondy_mst_store:put(Store, NewPage)
    end.

%% @private
put_after_first(T, Key, Value, Store0, [{K1, V1, R1}]) ->
    case compare(T, Key, K1) of
        eq ->
            List = [{K1, merge_values(T, Key, V1, Value), R1}],
            {List, Store0};
        gt ->
            {R1A, R1B, Store} = split(T, Store0, R1, Key),
            List = [{K1, V1, R1A}, {Key, Value, R1B}],
            {List, Store}
    end;
put_after_first(T, Key, Value, Store0, [First, Second | Rest0]) ->
    {K1, V1, R1} = First,
    {K2, _, _} = Second,

    case compare(T, Key, K1) of
        eq ->
            List = [{K1, merge_values(T, K1, V1, Value), R1}, Second | Rest0],
            {List, Store0};
        gt ->
            case compare(T, Key, K2) of
                lt ->
                    {R1A, R1B, Store} = split(T, Store0, R1, Key),
                    List = [{K1, V1, R1A}, {Key, Value, R1B}, Second | Rest0],
                    {List, Store};
                _ ->
                    {Rest, Store} = put_after_first(
                        T, Key, Value, Store0, [Second | Rest0]
                    ),
                    List = [First | Rest],
                    {List, Store}
            end
    end.

%% @private
put_sub_after_first(T, Key, Value, Store0, Level, [{K1, V1, R1}]) ->
    case compare(T, K1, Key) of
        eq ->
            error(inconsistency);
        _ ->
            {R, Store} = put_at(T, Key, Value, Level, Store0, R1),
            List = [{K1, V1, R}],
            {List, Store}
    end;
put_sub_after_first(T, Key, Value, Store0, Level, [First, Second | Rest0]) ->
    {K1, V1, R1} = First,
    {K2, _, _} = Second,

    case compare(T, K1, Key) of
        eq ->
            error(inconsistency);
        _ ->
            case compare(T, Key, K2) of
                lt ->
                    {R, Store} = put_at(T, Key, Value, Level, Store0, R1),
                    List = [{K1, V1, R}, Second | Rest0],
                    {List, Store};
                _ ->
                    {Rest, Store} = put_sub_after_first(
                        T, Key, Value, Store0, Level, [Second | Rest0]
                    ),
                    List = [First | Rest],
                    {List, Store}
            end
    end.

%% @private
%% Dangling-page recovery
%% ----------------------
%%
%% `merge_aux/5` and `split/5` look pages up by content hash; the
%% invariant is that every hash they are handed resolves in Store0
%% (the merge accumulator), A's store, or B's store. Each way a store
%% or collector can break that invariant is a contract with its own
%% falsifier:
%%
%% - `free/3` never hard-deletes a page that older roots, pins, or
%%   accumulators may still reference — the ETS backend always
%%   tombstones (`bondy_mst_free_reachable_test`);
%% - the reachability sweep takes its candidate snapshot before the
%%   mark walk, so a concurrently inserted page cannot be swept on
%%   arrival (`bondy_mst_gc_guard_test:
%%   sweep_spares_pages_inserted_after_snapshot_test`);
%% - a FOREIGN split — decomposing the donor's pages while merging an
%%   adopted (sync-pulled) root — frees nothing in the receiver's
%%   store (`bondy_mst_free_reachable_test:foreign_split_frees_nothing/0`).
%%
%% A hole that arises anyway does not amplify — `gc/2` refuses to
%% sweep under an unservable current root and retains a classified
%% report (`gc_aborts/0`) naming the layer at fault — and does not
%% crash: the handlers below treat a dangling subtree as empty and
%% log with diagnostic context, so the cost is bounded content loss,
%% never a dead supervisor subtree (an unhandled miss raises
%% `FunctionClauseError` on `bondy_mst_page:level/1`).
log_dangling_page(Tag, T, Store0, Hash, Key) ->
    ?LOG_WARNING(#{
        description => Tag,
        hash => Hash,
        key => Key,
        store0_has => bondy_mst_store:has(Store0, Hash),
        t_store_has => bondy_mst_store:has(T#?MODULE.store, Hash)
    }).

log_dangling_root(Tag, A, B, Store0, ARoot, BRoot) ->
    ?LOG_WARNING(#{
        description => Tag,
        a_root => ARoot,
        b_root => BRoot,
        store0_has_a => bondy_mst_store:has(Store0, ARoot),
        store0_has_b => bondy_mst_store:has(Store0, BRoot),
        a_store_has_a => bondy_mst_store:has(A#?MODULE.store, ARoot),
        b_store_has_b => bondy_mst_store:has(B#?MODULE.store, BRoot),
        b_store_has_a => bondy_mst_store:has(B#?MODULE.store, ARoot),
        a_store_has_b => bondy_mst_store:has(A#?MODULE.store, BRoot)
    }).

%% Splitting a subtree of the tree that OWNS `Store` — a path-copy rewrite, so
%% the page being replaced is freed (`owned`).
split(T, Store, Hash, Key) ->
    split(T, Store, Hash, Key, owned).

%% `Owner` says whose page `Hash` is relative to the store being written:
%%
%%   `owned`   — `T`'s pages live in this store and we are path-copying it, so
%%               the page we replace must be freed. Every insert/delete/truncate
%%               caller is this case.
%%   `foreign` — we are decomposing a page of the OTHER tree (`merge_aux_rec/7`
%%               splitting the donor `B` while writing into the receiver's
%%               store). Freeing there would tombstone `Hash` in a store that
%%               either never held it or — because pages are content-addressed
%%               — holds it as a LIVE page of the receiver's own tree. On
%%               `bondy_mst_ets_store` that is currently masked by reachability
%%               GC re-marking it; on `bondy_mst_pack_store` the pack rewrite
%%               keeps `reachable INTERSECT non-tombstoned`, so a reachable
%%               page carrying a stray tombstone would be dropped outright.
%%               Skipping the free instead leaves a temporary page for the next
%%               collection: deleting late is a bounded memory cost, deleting
%%               early is data loss.
split(_, Store, undefined, _, _) ->
    {undefined, undefined, Store};
split(T, Store0, Hash, Key, Owner) ->
    Page = get_page(T, Store0, Hash),
    case Page of
        undefined ->
            %% Dangling Hash: a parent page referenced a child by hash
            %% but the child is in no store we can see. Treat the
            %% subtree as empty rather than crashing the gen_server —
            %% see the "Dangling-page recovery" note at the top of
            %% merge_aux for the contracts that make this unreachable
            %% and the guards behind it.
            log_dangling_page("split: page missing", T, Store0, Hash, Key),
            {undefined, undefined, Store0};
        _ ->
            split_page(T, Store0, Hash, Key, Page, Owner)
    end.

%% @private
split_page(T, Store0, Hash, Key, Page, Owner) ->
    Level = bondy_mst_page:level(Page),
    Low = bondy_mst_page:low(Page),
    [{K0, _, _} | _] = List0 = bondy_mst_page:list(Page),

    Store1 =
        case Owner of
            owned -> bondy_mst_store:free(Store0, Hash, Page);
            foreign -> Store0
        end,

    case compare(T, Key, K0) of
        lt ->
            {LowLow, LowHi, Store2} = split(T, Store1, Low, Key, Owner),
            NewPage = bondy_mst_page:new(Level, LowHi, List0),
            {NewPageHash, Store} = bondy_mst_store:put(Store2, NewPage),
            {LowLow, NewPageHash, Store};
        gt ->
            {List, P2, Store2} =
                split_aux(T, Store1, Key, Level, List0, Owner),
            NewPage = bondy_mst_page:new(Level, Low, List),
            {NewPageHash, Store} = bondy_mst_store:put(Store2, NewPage),
            {NewPageHash, P2, Store}
    end.

%% @private
%% `Owner` threads through unchanged: a foreign split must stay foreign all the
%% way down, or the deeper levels of a donor subtree would still be freed in
%% the receiver's store.
split_aux(T, Store0, Key, _, [{K1, V1, R1}], Owner) ->
    case compare(T, K1, Key) of
        eq ->
            error(inconsistency);
        _ ->
            {R1L, R1H, Store} = split(T, Store0, R1, Key, Owner),
            {[{K1, V1, R1L}], R1H, Store}
    end;
split_aux(T, Store0, Key, Level, [First, Second | Rest0], Owner) ->
    {K1, V1, R1} = First,
    {K2, _, _} = Second,

    case compare(T, Key, K2) of
        eq ->
            error(inconsistency);
        lt ->
            {R1L, R1H, Store1} = split(T, Store0, R1, Key, Owner),
            NewPage = bondy_mst_page:new(Level, R1H, [Second | Rest0]),
            {NewPageHash, Store} = bondy_mst_store:put(Store1, NewPage),
            {[{K1, V1, R1L}], NewPageHash, Store};
        gt ->
            {Rest, Hi, Store} = split_aux(
                T, Store0, Key, Level, [Second | Rest0], Owner
            ),
            {[First | Rest], Hi, Store}
    end.

%% @private
%% Structural prefix-truncate: returns the root hash of the subtree
%% containing exactly the keys strictly greater than `W`, freeing the
%% pages it rewrites along the left spine. Dropped subtrees are left
%% unreferenced for GC (same lifecycle as `split/4`). Mirrors
%% `split_page/5` but routes keys `=< W` to the discard side, so an
%% exact match on `W` (always an existing key for compaction) is dropped
%% rather than raising `inconsistency`.
truncate_at(_, Store, undefined, _) ->
    {undefined, Store};
truncate_at(T, Store0, Hash, W) ->
    case get_page(T, Store0, Hash) of
        undefined ->
            %% Dangling hash — treat the subtree as empty rather than
            %% crashing (see the dangling-page note above `merge_aux`).
            log_dangling_page("truncate: page missing", T, Store0, Hash, W),
            {undefined, Store0};
        Page ->
            Level = bondy_mst_page:level(Page),
            Low = bondy_mst_page:low(Page),
            List0 = bondy_mst_page:list(Page),
            Store1 = bondy_mst_store:free(Store0, Hash, Page),
            truncate_scan(T, Store1, W, Level, Low, List0)
    end.

%% @private
%% Walks the page's entry list left-to-right. `Prev` is the child
%% subtree immediately to the left of the current entry (its keys are
%% all `< CurrentKey`); it starts as the page's `low`. Keys `=< W` are
%% dropped together with their left subtrees; the first child that
%% straddles `W` is truncated recursively and becomes the new `low` of
%% the rebuilt page.
truncate_scan(T, Store0, W, _Level, Prev, []) ->
    %% Every entry was `=< W`; only the rightmost child (`Prev`, keys
    %% `> last key`) can hold survivors. The page level collapses.
    truncate_at(T, Store0, Prev, W);
truncate_scan(T, Store0, W, Level, Prev, [{K, _V, R} | Rest] = List) ->
    case compare(T, W, K) of
        lt ->
            %% W < K: K and everything after it survive. `Prev` (keys
            %% `< K`) straddles W → truncate it into the new low.
            {NewLow, Store} = truncate_at(T, Store0, Prev, W),
            rebuild_truncated(Store, Level, NewLow, List);
        eq ->
            %% W == K: K is dropped; `Prev` (keys `< K =< W`) is dropped
            %% wholesale. R (keys in `(K, next)`, all `> W`) becomes the
            %% new low; the remaining entries survive untouched.
            rebuild_truncated(Store0, Level, R, Rest);
        gt ->
            %% W > K: K is dropped; advance, R becomes the next `Prev`.
            truncate_scan(T, Store0, W, Level, R, Rest)
    end.

%% @private
%% Builds the rebuilt page for the surviving entries, or collapses to a
%% bare subtree hash when no entries survive at this level.
rebuild_truncated(Store, _Level, NewLow, []) ->
    {NewLow, Store};
rebuild_truncated(Store0, Level, NewLow, [_ | _] = List) ->
    NewPage = bondy_mst_page:new(Level, NewLow, List),
    {NewHash, Store} = bondy_mst_store:put(Store0, NewPage),
    {NewHash, Store}.

%% @private
get_page(T, Store, Hash) ->
    case bondy_mst_store:get(Store, Hash) of
        undefined ->
            bondy_mst_store:get(T#?MODULE.store, Hash);
        Page ->
            Page
    end.

%% @private
%% Materialises the subtree rooted at `Hash` in the RECEIVER's store, so that
%% a reference `merge_aux/5` keeps is always resolvable there afterwards.
%%
%% `bondy_mst_store:copy/3` cannot serve this: it resolves every page from the
%% DONOR alone. But `merge_aux_rec/7` calls `split/4` on donor subtrees, and
%% `split_page/5` writes the rewritten spine pages it produces into the
%% RECEIVER's store while their children still live only in the donor. For
%% exactly those hashes `copy/3` looked in the donor, found nothing, and
%% returned the store untouched — so merge published a root referencing
%% children that were never copied. With `merge/3` that is survivable (the
%% donor IS the receiver, so the reference still resolves), which is why the
%% peer-integrate path never showed it; with `put_batch/2` the donor is a
%% volatile map store that is discarded on return, making the loss permanent.
%% That is the own-root page loss observed on Fly s16/s25.
%%
%% Hence the two rules here: resolve each page receiver-first then donor (the
%% same fallback `get_page/3` uses), and ALWAYS walk a page's refs — presence
%% in the receiver does not imply its subtree is closed under the receiver,
%% precisely because `split/4` can put a page there ahead of its children.
copy_subtree(_B, Store, undefined) ->
    Store;
copy_subtree(B, Store0, Hash) ->
    case bondy_mst_store:get(Store0, Hash) of
        undefined ->
            case bondy_mst_store:get(B#?MODULE.store, Hash) of
                undefined ->
                    %% Resolvable in neither store: a genuinely dangling
                    %% reference, which the callers' guards report.
                    Store0;
                Page ->
                    %% Children first: the store must never hold a page whose
                    %% subtree is not already there, or a crash between the two
                    %% inserts leaves exactly the hole this function exists to
                    %% prevent.
                    Store1 = copy_refs(B, Store0, Page),
                    {_Hash, Store} = bondy_mst_store:put(Store1, Page),
                    Store
            end;
        Page ->
            copy_refs(B, Store0, Page)
    end.

%% @private
copy_refs(B, Store, Page) ->
    lists:foldl(
        fun(Ref, Acc) -> copy_subtree(B, Acc, Ref) end,
        Store,
        bondy_mst_page:refs(Page)
    ).

%% @private
-spec merge_aux(
    A :: t(),
    B :: t(),
    Store :: bondy_mst_store:t(),
    ARoot :: hash(),
    BRoot :: hash()
) ->
    {NewRootHash :: hash(), NewStore :: bondy_mst_store:t()}.

merge_aux(_, _, Store0, Root, Root) ->
    {Root, Store0};
merge_aux(_, _, Store0, ARoot, undefined) ->
    {ARoot, Store0};
merge_aux(_, B, Store0, undefined, BRoot) ->
    Store = copy_subtree(B, Store0, BRoot),
    {BRoot, Store};
merge_aux(A, B, Store0, ARoot, BRoot) ->
    APage = bondy_mst_store:get(Store0, ARoot),
    BPage = get_page(B, Store0, BRoot),
    case {APage, BPage} of
        {undefined, undefined} ->
            %% Both sides are dangling — pathologically corrupt
            %% input. Reset to empty.
            log_dangling_root(
                "merge_aux: both A and B roots dangling",
                A,
                B,
                Store0,
                ARoot,
                BRoot
            ),
            {undefined, Store0};
        {undefined, _} ->
            %% A's root hash doesn't resolve in any store. Treat A as
            %% empty for this subtree — fall back to clause 3's
            %% "copy B over" behaviour.
            log_dangling_root(
                "merge_aux: A root dangling, falling back to B",
                A,
                B,
                Store0,
                ARoot,
                BRoot
            ),
            Store = copy_subtree(B, Store0, BRoot),
            {BRoot, Store};
        {_, undefined} ->
            %% B's root hash doesn't resolve. Keep A as-is.
            log_dangling_root(
                "merge_aux: B root dangling, keeping A",
                A,
                B,
                Store0,
                ARoot,
                BRoot
            ),
            {ARoot, Store0};
        _ ->
            merge_aux_pages(A, B, Store0, ARoot, BRoot, APage, BPage)
    end.

%% @private
%% Pulled out so the head of `merge_aux/5` stays focused on the
%% dangling-page guards. Reached only when both APage and BPage are
%% real page records.
merge_aux_pages(A, B, Store0, ARoot, BRoot, APage, BPage) ->
    ALevel = bondy_mst_page:level(APage),
    ALow = bondy_mst_page:low(APage),
    AEntries = bondy_mst_page:list(APage),

    BLevel = bondy_mst_page:level(BPage),
    BLow = bondy_mst_page:low(BPage),
    BEntries = bondy_mst_page:list(BPage),

    {Level, {Low, List, Store}} =
        case BLevel of
            ALevel ->
                {
                    ALevel,
                    merge_aux_rec(A, B, Store0, ALow, AEntries, BLow, BEntries)
                };
            BLevel when ALevel > BLevel ->
                {
                    ALevel,
                    merge_aux_rec(A, B, Store0, ALow, AEntries, BRoot, [])
                };
            BLevel when ALevel < BLevel ->
                {
                    BLevel,
                    merge_aux_rec(A, B, Store0, ARoot, [], BLow, BEntries)
                }
        end,
    NewPage = bondy_mst_page:new(Level, Low, List),
    bondy_mst_store:put(Store, NewPage).

%% @private
merge_aux_rec(A, B, Store0, ALow, [], BLow, []) ->
    {Hash, Store} = merge_aux(A, B, Store0, ALow, BLow),
    {Hash, [], Store};
merge_aux_rec(A, B, Store0, ALow, [], BLow, [{K, V, R} | BRest]) ->
    {ALowL, ALowH, Store1} = split(A, Store0, ALow, K),
    {NewLow, Store2} = merge_aux(A, B, Store1, ALowL, BLow),
    {NewR, NewRest, Store} = merge_aux_rec(A, B, Store2, ALowH, [], R, BRest),
    {NewLow, [{K, V, NewR} | NewRest], Store};
merge_aux_rec(A, B, Store0, ALow, [{K, V, R} | ARest], BLow, []) ->
    {BLowL, BLowH, Store1} = split(B, Store0, BLow, K, foreign),
    {NewLow, Store2} = merge_aux(A, B, Store1, ALow, BLowL),
    {NewR, NewRest, Store} = merge_aux_rec(A, B, Store2, R, ARest, BLowH, []),
    {NewLow, [{K, V, NewR} | NewRest], Store};
merge_aux_rec(
    A,
    B,
    Store0,
    ALow,
    [{AKey, AValue, ARoot} | ARest] = AEntries,
    BLow,
    [{BKey, BValue, BRoot} | BRest] = BEntries
) ->
    case compare(A, AKey, BKey) of
        lt ->
            {BLowL, BLowH, Store1} = split(B, Store0, BLow, AKey, foreign),
            {NewLow, Store2} = merge_aux(A, B, Store1, ALow, BLowL),
            {NewR, NewRest, Store} = merge_aux_rec(
                A, B, Store2, ARoot, ARest, BLowH, BEntries
            ),
            {NewLow, [{AKey, AValue, NewR} | NewRest], Store};
        gt ->
            {ALowL, ALowH, Store1} = split(A, Store0, ALow, BKey),
            {NewLow, Store2} = merge_aux(A, B, Store1, ALowL, BLow),
            {NewR, NewRest, Store} = merge_aux_rec(
                A, B, Store2, ALowH, AEntries, BRoot, BRest
            ),
            {NewLow, [{BKey, BValue, NewR} | NewRest], Store};
        eq ->
            {NewLow, Store1} = merge_aux(A, B, Store0, ALow, BLow),
            NewV = merge_values(A, AKey, AValue, BValue),
            {NewR, NewRest, Store} = merge_aux_rec(
                A, B, Store1, ARoot, ARest, BRoot, BRest
            ),
            {NewLow, [{AKey, NewV, NewR} | NewRest], Store}
    end.

%% @private
%% Iterates over the MST and applies a function to each element.
do_fold(_, _, AccIn, _, undefined) ->
    AccIn;
do_fold(Store, Fun, AccIn, Opts, Root) ->
    case bondy_mst_store:get(Store, Root) of
        undefined ->
            AccIn;
        Page ->
            Low = bondy_mst_page:low(Page),
            AccOut = do_fold(Store, Fun, AccIn, Opts, Low),
            bondy_mst_page:fold(
                Page,
                fun({K, V, Hash}, Acc0) ->
                    Acc1 = Fun({K, V}, Acc0),
                    do_fold(Store, Fun, Acc1, Opts, Hash)
                end,
                AccOut
            )
    end.

%% @private
%% Iterates over the MST and applies a function to each element.
do_fold_pages(_, _, Acc, _, undefined) ->
    Acc;
do_fold_pages(Store, Fun, AccIn, Opts, Root) ->
    case bondy_mst_store:get(Store, Root) of
        undefined ->
            AccIn;
        Page ->
            Low = bondy_mst_page:low(Page),
            AccOut = do_fold_pages(Store, Fun, AccIn, Opts, Low),
            bondy_mst_page:fold(
                Page,
                fun({_, _, Hash}, Acc0) ->
                    do_fold_pages(Store, Fun, Acc0, Opts, Hash)
                end,
                Fun({Root, Page}, AccOut)
            )
    end.

%% @private
do_foreach(_, _, _, undefined) ->
    ok;
do_foreach(Store, Fun, Opts, Root) ->
    case bondy_mst_store:get(Store, Root) of
        undefined ->
            ok;
        Page ->
            Low = bondy_mst_page:low(Page),
            ok = do_foreach(Store, Fun, Opts, Low),
            bondy_mst_page:foreach(
                Page,
                fun({K, V, Hash}) ->
                    ok = Fun({K, V}),
                    do_foreach(Store, Fun, Opts, Hash)
                end
            )
    end.

%% @private
%% Read-only diff entry. Tree comparison in a Merkle Search Tree is
%% read-only by design (Auvolat & Taïani, SRDS 2019): descend both roots,
%% prune any subtree whose Merkle hash matches on both sides, and surface
%% only the differing entries. Aligning two differently-shaped trees at a
%% key boundary still needs `split`-style partition pages, but those pages
%% are *synthetic* — here they live in an in-memory overlay (`Acc ::
%% #{hash() => page()}`) threaded through the descent, never written to
%% the store and never freed. So neither input tree is mutated (cf. the
%% earlier split-based implementation, which `free`d live pages and
%% corrupted mutable ETS/pack stores). The overlay is content-addressed,
%% so a synthetic page is keyed by its own hash exactly as
%% `bondy_mst_store:put/2` would key it, and reads resolve overlay-first.
diff_to_list(T, Store1, ARoot, Store2, BRoot) ->
    {List, _Acc} = do_diff(T, Store1, ARoot, Store2, BRoot, #{}),
    List.

%% @private
do_diff(_, _, R, _, R, Acc) ->
    {[], Acc};
do_diff(_, _, undefined, _, _, Acc) ->
    {[], Acc};
do_diff(T, Store1, ARoot, _, undefined, Acc) ->
    {ro_to_list(T, Store1, Acc, ARoot), Acc};
do_diff(T, Store1, ARoot, Store2, BRoot, Acc) ->
    case {ro_store_get(Store1, Acc, ARoot), ro_store_get(Store2, Acc, BRoot)} of
        {undefined, undefined} ->
            %% Dangling-page recovery (see the note above `merge_aux/5`):
            %% a hash resolved to no page in either store. Treat both
            %% subtrees as empty rather than crashing on
            %% `bondy_mst_page:list(undefined)`. The pack store serves any
            %% physically-present page, so for a live tree this branch means
            %% a genuinely-absent page.
            log_dangling_diff(ARoot, BRoot),
            {[], Acc};
        {undefined, _} ->
            %% A-side dangling: treat A's subtree as empty, so every key
            %% under BRoot is reported as changed.
            log_dangling_diff(ARoot, BRoot),
            {ro_to_list(T, Store2, Acc, BRoot), Acc};
        {_, undefined} ->
            %% B-side dangling: symmetric.
            log_dangling_diff(ARoot, BRoot),
            {ro_to_list(T, Store1, Acc, ARoot), Acc};
        {APage, BPage} ->
            ALow = bondy_mst_page:low(APage),
            AEntries = bondy_mst_page:list(APage),
            ALevel = bondy_mst_page:level(APage),
            BEntries = bondy_mst_page:list(BPage),
            BLow = bondy_mst_page:low(BPage),
            BLevel = bondy_mst_page:level(BPage),
            case BLevel of
                ALevel ->
                    do_diff_rec(
                        T, Store1, ALow, AEntries, Store2, BLow, BEntries, Acc
                    );
                BLevel when ALevel > BLevel ->
                    do_diff_rec(
                        T, Store1, ALow, AEntries, Store2, BRoot, [], Acc
                    );
                BLevel when ALevel < BLevel ->
                    do_diff_rec(
                        T, Store1, ARoot, [], Store2, BLow, BEntries, Acc
                    )
            end
    end.

%% @private
log_dangling_diff(ARoot, BRoot) ->
    ?LOG_WARNING(#{
        description =>
            "diff: dangling page, treating subtree as empty",
        a_root => ARoot,
        b_root => BRoot
    }).

%% @private
do_diff_rec(T, Store1, ALow, [], Store2, BLow, [], Acc) ->
    do_diff(T, Store1, ALow, Store2, BLow, Acc);
do_diff_rec(T, Store1, ALow, [], Store2, BLow, [{K, _, R} | Rest2], Acc0) ->
    {ALowL, ALowH, Acc1} = ro_split(T, Store1, Acc0, ALow, K),
    {L1, Acc2} = do_diff(T, Store1, ALowL, Store2, BLow, Acc1),
    {L2, Acc} = do_diff_rec(T, Store1, ALowH, [], Store2, R, Rest2, Acc2),
    {L1 ++ L2, Acc};
do_diff_rec(T, Store1, ALow, [{K, V, R} | Rest1], Store2, BLow, [], Acc0) ->
    {BLowL, BLowH, Acc1} = ro_split(T, Store2, Acc0, BLow, K),
    {L1, Acc2} = do_diff(T, Store1, ALow, Store2, BLowL, Acc1),
    {L2, Acc} = do_diff_rec(T, Store1, R, Rest1, Store2, BLowH, [], Acc2),
    {L1 ++ [{K, V} | L2], Acc};
do_diff_rec(T, Store1, ALow, AEntries, Store2, BLow, BEntries, Acc0) ->
    [{K1, V1, ARoot} | Rest1] = AEntries,
    [{K2, V2, BRoot} | Rest2] = BEntries,

    case compare(T, K1, K2) of
        lt ->
            {BLowL, BLowH, Acc1} = ro_split(T, Store2, Acc0, BLow, K1),
            {L1, Acc2} = do_diff(T, Store1, ALow, Store2, BLowL, Acc1),
            {L2, Acc} = do_diff_rec(
                T, Store1, ARoot, Rest1, Store2, BLowH, BEntries, Acc2
            ),
            {L1 ++ [{K1, V1} | L2], Acc};
        gt ->
            {ALowL, ALowH, Acc1} = ro_split(T, Store1, Acc0, ALow, K2),
            {L1, Acc2} = do_diff(T, Store1, ALowL, Store2, BLow, Acc1),
            {L2, Acc} = do_diff_rec(
                T, Store1, ALowH, AEntries, Store2, BRoot, Rest2, Acc2
            ),
            {L1 ++ L2, Acc};
        eq ->
            {L0, Acc1} = do_diff_rec(
                T, Store1, ARoot, Rest1, Store2, BRoot, Rest2, Acc0
            ),
            {LL, Acc} = do_diff(T, Store1, ALow, Store2, BLow, Acc1),

            case V1 == V2 of
                true ->
                    {LL ++ L0, Acc};
                false ->
                    {LL ++ [{K1, V1} | L0], Acc}
            end
    end.

%% @private
%% Overlay-aware page read for the top-level diff descent (mirrors the old
%% `bondy_mst_store:get(Store, Hash)` reads — no `T`-store fallback): a
%% synthetic page minted by `ro_split/5` resolves from `Acc`, any real
%% page from `Store`.
ro_store_get(Store, Acc, Hash) ->
    case Acc of
        #{Hash := Page} -> Page;
        _ -> bondy_mst_store:get(Store, Hash)
    end.

%% @private
%% Overlay-aware page read for `ro_split/5` (mirrors `split/4`'s
%% `get_page/3`, which additionally falls back to `T`'s own store).
ro_get_page(T, Store, Acc, Hash) ->
    case Acc of
        #{Hash := Page} -> Page;
        _ -> get_page(T, Store, Hash)
    end.

%% @private
%% Read-only counterpart of `split/4`: partitions the subtree rooted at
%% `Hash` at `Key` into `{Low, High}` exactly as `split/4` does, but emits
%% the synthetic partition pages into the overlay `Acc` rather than the
%% store, and never `free`s the page it rewrites. Returns the two child
%% hashes plus the grown overlay.
ro_split(_, _, Acc, undefined, _) ->
    {undefined, undefined, Acc};
ro_split(T, Store, Acc, Hash, Key) ->
    case ro_get_page(T, Store, Acc, Hash) of
        undefined ->
            %% Dangling hash — treat the subtree as empty (see the
            %% dangling-page note above `merge_aux`); `split/4` does the
            %% same.
            {undefined, undefined, Acc};
        Page ->
            ro_split_page(T, Store, Acc, Key, Page)
    end.

%% @private
ro_split_page(T, Store, Acc0, Key, Page) ->
    Level = bondy_mst_page:level(Page),
    Low = bondy_mst_page:low(Page),
    [{K0, _, _} | _] = List0 = bondy_mst_page:list(Page),

    case compare(T, Key, K0) of
        lt ->
            {LowLow, LowHi, Acc1} = ro_split(T, Store, Acc0, Low, Key),
            NewPage = bondy_mst_page:new(Level, LowHi, List0),
            {NewPageHash, Acc} = ro_put(T, Acc1, NewPage),
            {LowLow, NewPageHash, Acc};
        gt ->
            {List, P2, Acc1} = ro_split_aux(T, Store, Acc0, Key, Level, List0),
            NewPage = bondy_mst_page:new(Level, Low, List),
            {NewPageHash, Acc} = ro_put(T, Acc1, NewPage),
            {NewPageHash, P2, Acc}
    end.

%% @private
ro_split_aux(T, Store, Acc0, Key, _, [{K1, V1, R1}]) ->
    case compare(T, K1, Key) of
        eq ->
            error(inconsistency);
        _ ->
            {R1L, R1H, Acc} = ro_split(T, Store, Acc0, R1, Key),
            {[{K1, V1, R1L}], R1H, Acc}
    end;
ro_split_aux(T, Store, Acc0, Key, Level, [First, Second | Rest0]) ->
    {K1, V1, R1} = First,
    {K2, _, _} = Second,

    case compare(T, Key, K2) of
        eq ->
            error(inconsistency);
        lt ->
            {R1L, R1H, Acc1} = ro_split(T, Store, Acc0, R1, Key),
            NewPage = bondy_mst_page:new(Level, R1H, [Second | Rest0]),
            {NewPageHash, Acc} = ro_put(T, Acc1, NewPage),
            {[{K1, V1, R1L}], NewPageHash, Acc};
        gt ->
            {Rest, Hi, Acc} = ro_split_aux(
                T, Store, Acc0, Key, Level, [Second | Rest0]
            ),
            {[First | Rest], Hi, Acc}
    end.

%% @private
%% Mints a synthetic partition page into the overlay, keyed by the same
%% content hash `bondy_mst_store:put/2` would assign (`bondy_mst_page:hash/2`
%% with the tree's hash algorithm), so downstream `ro_*_get` reads resolve
%% it identically to a stored page.
ro_put(#?MODULE{hash_algorithm = Algo}, Acc, Page) ->
    Hash = bondy_mst_page:hash(Page, Algo),
    {Hash, maps:put(Hash, Page, Acc)}.

%% @private
%% In-order `{Key, Value}` list of the subtree rooted at `Root`,
%% overlay-aware. Replaces the `do_fold/5`-based full-list fallback used
%% when the B side is `undefined`; identical ordering, but resolves
%% synthetic pages from `Acc`.
ro_to_list(T, Store, Acc, Root) ->
    lists:reverse(ro_fold(T, Store, Acc, Root, [])).

%% @private
ro_fold(_, _, _, undefined, L) ->
    L;
ro_fold(T, Store, Acc, Root, L0) ->
    case ro_store_get(Store, Acc, Root) of
        undefined ->
            L0;
        Page ->
            Low = bondy_mst_page:low(Page),
            L1 = ro_fold(T, Store, Acc, Low, L0),
            bondy_mst_page:fold(
                Page,
                fun({K, V, Hash}, A0) ->
                    ro_fold(T, Store, Acc, Hash, [{K, V} | A0])
                end,
                L1
            )
    end.

%% @private
dump(Store, R) ->
    dump(Store, R, "").

%% @private
dump(_, undefined, _) ->
    ok;
dump(Store, Root, Space) ->
    Page = bondy_mst_store:get(Store, Root),
    Low = bondy_mst_page:low(Page),
    List = bondy_mst_page:list(Page),
    Level = bondy_mst_page:level(Page),

    io:format("~s~s (~p)~n", [Space, binary:encode_hex(Root), Level]),
    dump(Store, Low, Space ++ [$\s, $\s]),
    [
        begin
            io:format("~s- ~p => ~p~n", [Space, K, V]),
            dump(Store, R, Space ++ [$\s, $\s])
        end
     || {K, V, R} <- List
    ].

%% -----------------------------------------------------------------------------
%% @private
%% Navigate to the appropriate level to delete the key
%% -----------------------------------------------------------------------------
delete_at(T, Key, KeyLevel, Store0, Hash) when is_binary(Hash) ->
    Page = bondy_mst_store:get(Store0, Hash),
    PageLevel = bondy_mst_page:level(Page),

    if
        PageLevel < KeyLevel ->
            %% Key should be at a higher level, doesn't exist here
            not_found;
        PageLevel == KeyLevel ->
            %% Delete from this level
            Store1 = bondy_mst_store:free(Store0, Hash, Page),
            delete_from_level(T, Key, Page, Store1);
        PageLevel > KeyLevel ->
            %% Descend into subtrees to find the key
            Store1 = bondy_mst_store:free(Store0, Hash, Page),
            delete_below_level(T, Key, KeyLevel, Page, Store1)
    end;
delete_at(_, _, _, _, undefined) ->
    not_found.

%% @private
%% Delete key from this level (key's calculated level matches page level)
delete_from_level(T, Key, Page, Store0) ->
    Level = bondy_mst_page:level(Page),
    Low = bondy_mst_page:low(Page),
    List = bondy_mst_page:list(Page),

    delete_from_list(T, Key, Level, Low, List, Store0).

%% @private
%% Scan the list to find and remove the key
delete_from_list(T, Key, _Level, Low, [{K, _V, R}], Store0) ->
    case compare(T, Key, K) of
        eq ->
            %% Only entry in page, merge Low with R and return merged tree
            %% The page disappears
            merge_subtrees(T, Store0, Low, R);
        _ ->
            not_found
    end;
delete_from_list(T, Key, Level, Low, [{K, V, R} | Rest], Store0) ->
    case compare(T, Key, K) of
        eq ->
            %% First entry matches, merge Low with R
            {NewLow, Store1} = merge_subtrees(T, Store0, Low, R),
            %% Create page with merged low and remaining entries
            NewPage = bondy_mst_page:new(Level, NewLow, Rest),
            bondy_mst_store:put(Store1, NewPage);
        lt ->
            %% Key should be before first entry, doesn't exist
            not_found;
        gt ->
            %% Continue searching in rest of list, accumulating entries before
            %% the match
            delete_in_list_tail(
                T, Key, Level, Low, [{K, V, R}], Rest, Store0
            )
    end;
delete_from_list(_, _, _, _, [], _) ->
    not_found.

%% @private
%% Search for key in the tail of the list, accumulating entries before the match
delete_in_list_tail(T, Key, Level, Low, Before, [{K, _V, R}], Store0) ->
    case compare(T, Key, K) of
        eq ->
            %% Found it as last entry
            %% Get the R from the previous entry
            {_, _, PrevR} = lists:last(Before),
            %% Merge PrevR with R
            {MergedR, Store1} = merge_subtrees(T, Store0, PrevR, R),
            %% Update the last entry in Before to point to MergedR
            BeforeInit = lists:droplast(Before),
            {PrevK, PrevV, _} = lists:last(Before),
            NewList = BeforeInit ++ [{PrevK, PrevV, MergedR}],
            NewPage = bondy_mst_page:new(Level, Low, NewList),
            bondy_mst_store:put(Store1, NewPage);
        lt ->
            not_found;
        gt ->
            not_found
    end;
delete_in_list_tail(T, Key, Level, Low, Before, [{K, V, R} | Rest], Store0) ->
    case compare(T, Key, K) of
        eq ->
            %% Found it in middle
            %% Get the R from the previous entry
            {_, _, PrevR} = lists:last(Before),
            %% Merge PrevR with R
            {MergedR, Store1} = merge_subtrees(T, Store0, PrevR, R),
            %% Update the last entry in Before to point to MergedR
            BeforeInit = lists:droplast(Before),
            {PrevK, PrevV, _} = lists:last(Before),
            NewList = BeforeInit ++ [{PrevK, PrevV, MergedR} | Rest],
            NewPage = bondy_mst_page:new(Level, Low, NewList),
            bondy_mst_store:put(Store1, NewPage);
        lt ->
            not_found;
        gt ->
            %% Keep searching, accumulate this entry
            delete_in_list_tail(
                T, Key, Level, Low, Before ++ [{K, V, R}], Rest, Store0
            )
    end.

%% @private
%% Delete key from a subtree below this level
delete_below_level(T, Key, KeyLevel, Page, Store0) ->
    Level = bondy_mst_page:level(Page),
    Low = bondy_mst_page:low(Page),
    List = bondy_mst_page:list(Page),
    [{K0, _, _} | _] = List,

    case compare(T, Key, K0) of
        lt ->
            %% Key is in Low subtree
            case delete_at(T, Key, KeyLevel, Store0, Low) of
                not_found ->
                    not_found;
                {NewLow, Store1} ->
                    NewPage = bondy_mst_page:new(Level, NewLow, List),
                    bondy_mst_store:put(Store1, NewPage)
            end;
        _ ->
            %% Key is in one of the list entries' subtrees
            delete_sub_after_first(T, Key, KeyLevel, Level, Low, Store0, List)
    end.

%% @private
%% Navigate through list entries to find which subtree contains the key
delete_sub_after_first(T, Key, KeyLevel, PageLevel, Low, Store0, [{K, V, R}]) ->
    %% Must be in this last subtree R
    case delete_at(T, Key, KeyLevel, Store0, R) of
        not_found ->
            not_found;
        {NewR, Store1} ->
            NewList = [{K, V, NewR}],
            NewPage = bondy_mst_page:new(PageLevel, Low, NewList),
            bondy_mst_store:put(Store1, NewPage)
    end;
delete_sub_after_first(
    T,
    Key,
    KeyLevel,
    PageLevel,
    Low,
    Store0,
    [{K1, V1, R1}, {K2, V2, R2} | Rest]
) ->
    case compare(T, Key, K2) of
        lt ->
            %% Key is in R1 subtree (between K1 and K2)
            case delete_at(T, Key, KeyLevel, Store0, R1) of
                not_found ->
                    not_found;
                {NewR1, Store1} ->
                    NewList = [{K1, V1, NewR1}, {K2, V2, R2} | Rest],
                    NewPage = bondy_mst_page:new(PageLevel, Low, NewList),
                    bondy_mst_store:put(Store1, NewPage)
            end;
        _ ->
            %% Key is after K2, continue searching
            delete_sub_after_first_cont(
                T,
                Key,
                KeyLevel,
                PageLevel,
                Low,
                [{K1, V1, R1}],
                Store0,
                [{K2, V2, R2} | Rest]
            )
    end.

%% @private
delete_sub_after_first_cont(
    T, Key, KeyLevel, PageLevel, Low, Before, Store0, [{K, V, R}]
) ->
    %% Must be in this last subtree
    case delete_at(T, Key, KeyLevel, Store0, R) of
        not_found ->
            not_found;
        {NewR, Store1} ->
            NewList = Before ++ [{K, V, NewR}],
            NewPage = bondy_mst_page:new(PageLevel, Low, NewList),
            bondy_mst_store:put(Store1, NewPage)
    end;
delete_sub_after_first_cont(
    T,
    Key,
    KeyLevel,
    PageLevel,
    Low,
    Before,
    Store0,
    [{K1, V1, R1}, {K2, V2, R2} | Rest]
) ->
    case compare(T, Key, K2) of
        lt ->
            %% Key is in R1 subtree
            case delete_at(T, Key, KeyLevel, Store0, R1) of
                not_found ->
                    not_found;
                {NewR1, Store1} ->
                    NewList = Before ++ [{K1, V1, NewR1}, {K2, V2, R2} | Rest],
                    NewPage = bondy_mst_page:new(PageLevel, Low, NewList),
                    bondy_mst_store:put(Store1, NewPage)
            end;
        _ ->
            %% Continue searching
            delete_sub_after_first_cont(
                T,
                Key,
                KeyLevel,
                PageLevel,
                Low,
                Before ++ [{K1, V1, R1}],
                Store0,
                [{K2, V2, R2} | Rest]
            )
    end.

%% @private
%% Merge two subtrees using the existing merge algorithm
merge_subtrees(_T, Store, undefined, undefined) ->
    {undefined, Store};
merge_subtrees(_T, Store, Hash, undefined) ->
    {Hash, Store};
merge_subtrees(_T, Store, undefined, Hash) ->
    {Hash, Store};
merge_subtrees(T, Store, Hash1, Hash2) ->
    %% Reuse the existing merge_aux to combine the two subtrees
    merge_aux(T, T, Store, Hash1, Hash2).
