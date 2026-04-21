%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_ptrie).

-include_lib("kernel/include/logger.hrl").

-moduledoc """
A persistent (functional) path-copied Adaptive Radix Tree on ETS.

Every write allocates fresh copies of the O(log_256 N) nodes on the
root-to-leaf path and publishes the new version with a single-row CAS on the
root-pointer row. Readers grab the current root once and traverse an
immutable snapshot; they never take locks, never retry, never bump
refcounts. Old nodes are reclaimed by a janitor (see
`bondy_registry_ptrie_janitor`) using QSBR via the `atomics` module.

This module is a prototype and intentionally isolated from
`bondy_registry_store` — its API is generic (opaque `key()`, opaque
`value()`) so it can be tested standalone before being wired into the
registry.

""".


%% =============================================================================
%% MACROS AND RECORDS
%% =============================================================================

-define(CHILDREN_ARITY, 256).
-define(EMPTY_CHILDREN, {n_small, #{}}).
%% Threshold at which the small-map representation promotes to the dense
%% 256-tuple. BEAM keeps integer-keyed maps as a sorted FlatMap up to ~32
%% entries, then transitions to a HashMap. Both give O(log n) `maps:get/2`.
%% The dense 256-tuple is O(1) but costs 256 words regardless of
%% occupancy. 48 matches PART's n48 intermediate tier — nodes with
%% 17–48 children use the map (memory = ~80–200 words) instead of the
%% dense tuple (256 words), at the cost of a few extra log-n comparisons
%% per lookup.
-define(N_SMALL_CAPACITY, 48).
-define(ROOT_KEY, root).
%% Chosen so a realistic peak-contention workload (O(10) concurrent writers
%% on the same tree) does not return `cas_exhausted` as a normal outcome —
%% it is a safety valve against pathological livelock, not a load-shedding
%% mechanism.
-define(DEFAULT_CAS_RETRIES, 1024).
%% Sentinel byte that stands for "empty URI component" (WAMP wildcard
%% single-segment match). The WAMP URI grammars forbid `\0` in valid URI
%% components (strict: `[0-9a-z_]+`, loose: `[^\s.#]+`), so this byte
%% unambiguously marks a wildcard position during match-time traversal.
%% Byte-indexed into a 256-tuple, so it lives at tuple index 1.
-define(WILDCARD_BYTE, 0).
-define(SEGMENT_SEP, $.).
-define(IS_POLICY(P),
        (P =:= exact orelse P =:= prefix orelse P =:= wildcard)).


-record(pnode, {
    id          ::  node_id(),
    prefix      ::  binary(),
    children    ::  children(),
    leaves      ::  #{policy() => value()}
}).


-record(handle, {
    root_tab        ::  ets:tab(),
    node_tab        ::  ets:tab(),
    retire_tab      ::  ets:tab(),
    epoch_tab       ::  ets:tab(),
    current_epoch   ::  atomics:atomics_ref(),
    name            ::  atom()
}).


%% =============================================================================
%% TYPES
%% =============================================================================

-type node_id()     ::  pos_integer().
-type key()         ::  binary().
-type value()       ::  term().
-type policy()      ::  exact | prefix | wildcard.
-type leaf()        ::  {key(), policy(), value()}.
-type update_fun()  ::  fun((undefined | value()) ->
                             {ok, value()} | delete | noop).
-type update_result() :: ok
                       | deleted
                       | noop
                       | {error, cas_exhausted}.

%% Adaptive child-container shapes (PART §4.3). Path copying allocates a
%% fresh node on every mutation, so "adaptive sizing" collapses to:
%% pick the smallest container type that fits the current child count.
%%
%%   n_small — up to ?N_SMALL_CAPACITY (16) children, stored as an
%%             integer-keyed map. BEAM's FlatMap representation keeps
%%             keys sorted internally at small sizes; `maps:get/2` is an
%%             O(log n) binary search; `maps:size/1` is O(1); and
%%             `maps:iterator(M, ordered)` produces a key-sorted
%%             iterator — crucial for the fold-in-byte-order path.
%%   n256    — full 256-slot tuple, direct byte-indexed access.
%%
%% A future optimization (PART's n48) inserts a 256-byte index table +
%% 48-slot child array between these two to save memory on medium-wide
%% nodes. Skipped here for simplicity.
-type child_ptr()   ::  {node, node_id()}.
-type children()    ::  {n_small, #{byte() => child_ptr()}}
                      | {n256,    tuple()}.

-opaque handle()    ::  #handle{}.

-export_type([handle/0]).
-export_type([key/0]).
-export_type([value/0]).
-export_type([policy/0]).
-export_type([leaf/0]).
-export_type([node_id/0]).
-export_type([update_fun/0]).
-export_type([update_result/0]).


%% =============================================================================
%% EXPORTS
%% =============================================================================

%% API
-export([new/1]).
-export([delete/1]).
-export([insert/3]).
-export([insert/4]).
-export([remove/2]).
-export([remove/3]).
-export([update/4]).
-export([lookup/2]).
-export([lookup/3]).
-export([match/2]).
-export([fold/3]).
-export([truncate/1]).
-export([size/1]).
-export([info/1]).

%% WAMP PATTERN HELPERS — encode/decode URI wildcard components
-export([encode_pattern/1]).
-export([decode_pattern/1]).

%% RECLAMATION API — called by the janitor
-export([reclaim/1]).
-export([current_epoch/1]).
-export([min_active_epoch/1]).
-export([retire_tab/1]).
-export([node_tab/1]).

%% TEST HELPERS — internal inspection, not part of the public contract
-ifdef(TEST).
-export([root_id/1]).
-export([node_count/1]).
-export([dump/1]).
-export([retire_count/1]).
-export([epoch_tab_count/1]).
-endif.


%% =============================================================================
%% API
%% =============================================================================


-doc """
Create a new ptrie handle identified by `Name`. The atom is used to name the
underlying ETS tables (`<Name>_root`, `<Name>_nodes`, `<Name>_retire`) so they
can be inspected with `observer` and named-looked-up in tests.

The handle owns three ETS tables. The caller process becomes their heir.
""".
-spec new(Name :: atom()) -> handle().

new(Name) when is_atom(Name) ->
    RootTab = ets:new(
        list_to_atom(atom_to_list(Name) ++ "_root"),
        [set, public, {keypos, 1},
         {read_concurrency, true},
         {write_concurrency, true},
         {decentralized_counters, true}]
    ),
    NodeTab = ets:new(
        list_to_atom(atom_to_list(Name) ++ "_nodes"),
        [set, public, {keypos, #pnode.id},
         {read_concurrency, true},
         {write_concurrency, true},
         {decentralized_counters, true}]
    ),
    RetireTab = ets:new(
        list_to_atom(atom_to_list(Name) ++ "_retire"),
        [ordered_set, public, {keypos, 1},
         {read_concurrency, true},
         {write_concurrency, true}]
    ),
    EpochTab = ets:new(
        list_to_atom(atom_to_list(Name) ++ "_epochs"),
        [set, public, {keypos, 1},
         {read_concurrency, true},
         {write_concurrency, true}]
    ),
    %% Single-slot monotonic counter. `add_get` on slot 1 is our epoch bump.
    CurrentEpoch = atomics:new(1, [{signed, false}]),
    H = #handle{
        root_tab = RootTab,
        node_tab = NodeTab,
        retire_tab = RetireTab,
        epoch_tab = EpochTab,
        current_epoch = CurrentEpoch,
        name = Name
    },
    init_root(H),
    H.


-doc """
Delete the handle's ETS tables. Frees all storage.
""".
-spec delete(Handle :: handle()) -> ok.

delete(#handle{root_tab = R, node_tab = N, retire_tab = Rt,
               epoch_tab = E}) ->
    ets:delete(R),
    ets:delete(N),
    ets:delete(Rt),
    ets:delete(E),
    ok.


-doc """
Insert `{Key, exact, Value}`. Convenience shim — equivalent to
`insert(Handle, Key, exact, Value)`.
""".
-spec insert(Handle :: handle(), Key :: key(), Value :: value()) ->
    ok | {error, cas_exhausted}.

insert(H, Key, Value) ->
    insert(H, Key, exact, Value).


-doc """
Insert `{Key, Policy, Value}` into the trie. If a leaf with the same
`{Key, Policy}` pair already exists, its value is replaced — leaves with
the same `Key` but different `Policy` coexist.

`Policy` is one of:

  - `exact`    — matches only a target that equals `Key` byte-for-byte.
  - `prefix`   — matches any target that starts with `Key`.
  - `wildcard` — `Key` must already be encoded with the `\\0` sentinel
                 byte marking each wildcard URI component. See
                 `encode_pattern/1`.

Concurrent-safe via CAS on the root row. On CAS contention the walk is
retried up to `?DEFAULT_CAS_RETRIES` times; fresh nodes allocated in losing
attempts are deleted before the retry.
""".
-spec insert(
    Handle :: handle(),
    Key :: key(),
    Policy :: policy(),
    Value :: value()
) -> ok | {error, cas_exhausted}.

insert(#handle{} = H, Key, Policy, Value)
    when is_binary(Key) andalso ?IS_POLICY(Policy) ->
    do_write(H, fun(Root) -> walk_insert(H, Root, Key, 0, Policy, Value) end,
             ?DEFAULT_CAS_RETRIES).


-doc """
Remove the leaf with `{Key, exact}`. Shim — equivalent to
`remove(Handle, Key, exact)`.
""".
-spec remove(Handle :: handle(), Key :: key()) ->
    ok | {error, cas_exhausted}.

remove(H, Key) ->
    remove(H, Key, exact).


-doc """
Remove the leaf with `{Key, Policy}`. Returns `ok` whether or not the
leaf existed.
""".
-spec remove(Handle :: handle(), Key :: key(), Policy :: policy()) ->
    ok | {error, cas_exhausted}.

remove(#handle{} = H, Key, Policy)
    when is_binary(Key) andalso ?IS_POLICY(Policy) ->
    do_write(H, fun(Root) -> walk_remove(H, Root, Key, 0, Policy) end,
             ?DEFAULT_CAS_RETRIES).


-doc """
Atomically read-modify-write the leaf at `{Key, Policy}`.

`UpdateFun` is called with the leaf's current value (`undefined` if
absent) and must return:

  - `{ok, NewValue}` — replace (or insert) the leaf with `NewValue`.
  - `delete`         — remove the leaf.
  - `noop`           — make no change.

Returns `ok` on insert/update, `deleted` on removal, `noop` when the
function requested no change (or requested delete on an already-absent
leaf), or `{error, cas_exhausted}` if retry budget runs out under
sustained contention.

Concurrent-safe: uses the same CAS-on-root protocol as `insert/remove`.
Under contention, `UpdateFun` may be invoked more than once — each retry
re-reads the current value before re-deciding. The function must be
idempotent / safe under repeated calls.
""".
-spec update(
    Handle    :: handle(),
    Key       :: key(),
    Policy    :: policy(),
    UpdateFun :: update_fun()
) -> update_result().

update(#handle{} = H, Key, Policy, UpdateFun)
    when is_binary(Key) andalso ?IS_POLICY(Policy)
    andalso is_function(UpdateFun, 1) ->
    do_update(H, Key, Policy, UpdateFun, ?DEFAULT_CAS_RETRIES).


-doc """
Lookup the value for `Key`. Returns `{ok, Value}` if present, `error`
otherwise. This is the reader path and takes no locks.
""".
-spec lookup(Handle :: handle(), Key :: key()) ->
    {ok, value()} | error.

lookup(H, Key) ->
    lookup(H, Key, exact).


-doc """
Lookup the value for `{Key, Policy}`. Returns `{ok, Value}` if the leaf
exists, `error` otherwise. This does NOT do wildcard-style matching — use
`match/2` for that. Lookup is a direct byte-level trie walk.
""".
-spec lookup(Handle :: handle(), Key :: key(), Policy :: policy()) ->
    {ok, value()} | error.

lookup(#handle{} = H, Key, Policy)
    when is_binary(Key) andalso ?IS_POLICY(Policy) ->
    with_epoch(H, fun() ->
        {RootId, _V} = read_root(H),
        case ets:lookup(H#handle.node_tab, RootId) of
            [] -> error;
            [Root] -> walk_lookup(H#handle.node_tab, Root, Key, 0, Policy)
        end
    end).


-doc """
Match `Target` against all leaves in the trie. Returns every leaf whose
stored key matches `Target` under its policy:

  - `exact`    — leaf key equals `Target`.
  - `prefix`   — leaf key is a byte-prefix of `Target`.
  - `wildcard` — leaf key (with `\\0` bytes marking wildcard positions)
                 matches `Target` component-wise, with each `\\0` consuming
                 one non-empty target URI segment (bytes up to the next `.`
                 separator, or end of target).

Returns a list of `{Key, Policy, Value}` triples in arbitrary order.

`Target` must be a "strict" URI — no empty components. Wildcard matching is
an asymmetric relation: stored patterns may contain wildcards, targets
may not.
""".
-spec match(Handle :: handle(), Target :: key()) -> [leaf()].

match(#handle{} = H, Target) when is_binary(Target) ->
    with_epoch(H, fun() ->
        {RootId, _V} = read_root(H),
        case ets:lookup(H#handle.node_tab, RootId) of
            [] -> [];
            [Root] ->
                match_walk(H#handle.node_tab, Root, Target, [], [])
        end
    end).


-doc """
Fold `Fun(Key, Value, Acc)` over all `{Key, Value}` pairs in insertion order
(actually: byte-lexicographic order, which is the trie traversal order).
""".
-spec fold(
    Handle :: handle(),
    Fun :: fun((key(), value(), Acc) -> Acc),
    Acc0 :: Acc
) -> Acc.

fold(#handle{} = H, Fun, Acc0) when is_function(Fun, 3) ->
    with_epoch(H, fun() ->
        {RootId, _V} = read_root(H),
        case ets:lookup(H#handle.node_tab, RootId) of
            [] -> Acc0;
            [Root] -> fold_node(H#handle.node_tab, Root, [], Fun, Acc0)
        end
    end).


-doc """
Number of leaves in the trie. O(trie) — counts via fold. Each
`{Key, Policy}` pair is counted separately even when the keys are
identical.
""".
-spec size(Handle :: handle()) -> non_neg_integer().

size(#handle{} = H) ->
    fold(H, fun(_, _, N) -> N + 1 end, 0).


-doc """
Atomically replace the trie with a fresh, empty one. All old nodes become
reclamation candidates (they'll be deleted by the janitor when all
currently-active readers have moved past the post-truncate epoch).

Concurrent-safe: uses CAS on the root row, same protocol as insert/delete.
""".
-spec truncate(Handle :: handle()) -> ok | {error, cas_exhausted}.

truncate(#handle{} = H) ->
    do_write(H, fun(OldRoot) -> walk_truncate(H, OldRoot) end,
             ?DEFAULT_CAS_RETRIES).


%% @private
%% Returns {NewEmptyRootId, [AllReachableNodeIds], [NewEmptyRootId]}.
%% Walks the existing tree to collect every live node id, replacing the
%% whole tree with a fresh empty root.
walk_truncate(H, OldRoot) ->
    NewId = fresh_id(),
    Empty = #pnode{
        id = NewId,
        prefix = <<>>,
        children = ?EMPTY_CHILDREN,
        leaves = #{}
    },
    true = ets:insert(H#handle.node_tab, Empty),
    ReachableIds = collect_reachable(H#handle.node_tab, OldRoot, []),
    {NewId, ReachableIds, [NewId]}.


%% @private
collect_reachable(Tab, Node, Acc0) ->
    Acc = [Node#pnode.id | Acc0],
    children_fold(
        fun(_Byte, {node, ChildId}, A) ->
            case ets:lookup(Tab, ChildId) of
                [] -> A;
                [Child] -> collect_reachable(Tab, Child, A)
            end
        end,
        Acc,
        Node#pnode.children
    ).


-doc """
Return implementation-level metrics about the handle. Intended for
observability and tests.
""".
-spec info(Handle :: handle()) -> map().

info(#handle{} = H) ->
    {RootId, V} = read_root(H),
    #{
        name => H#handle.name,
        root_id => RootId,
        version => V,
        current_epoch => atomics:get(H#handle.current_epoch, 1),
        active_readers => ets:info(H#handle.epoch_tab, size),
        node_count => ets:info(H#handle.node_tab, size),
        retire_count => ets:info(H#handle.retire_tab, size)
    }.


%% =============================================================================
%% RECLAMATION API
%% =============================================================================


-doc """
Reclaim retired nodes that no active reader can reach. Returns the number
of `#pnode{}` rows deleted.

This is the core janitor operation. It is exposed as a plain function so it
can be driven by an external gen_server (see
`bondy_registry_ptrie_janitor`) or invoked directly by tests.

Safety: a node `N` is reclaimable iff every live reader is pinning an epoch
strictly greater than `N`'s retirement tag. The protocol ensures the writer
bumped the epoch *after* the CAS that made `N` unreachable; any reader with
a slot >= that bumped value saw the post-CAS root and thus cannot reach
`N`. See `_design/PATTERN_MATCHING_DESIGN_v2.md` §4.6.
""".
-spec reclaim(Handle :: handle()) -> non_neg_integer().

reclaim(#handle{} = H) ->
    SafeTag = safe_reclaim_epoch(H),
    %% Select all retire entries with tag < SafeTag. Because retire_tab is
    %% an ordered_set, this is a prefix of the keyspace but the key is the
    %% NodeId (not the tag), so we walk with a match spec.
    MS = [{{'$1', '$2'}, [{'<', '$2', SafeTag}], ['$_']}],
    Reclaimable = ets:select(H#handle.retire_tab, MS),
    lists:foreach(
        fun({NodeId, _Tag}) ->
            ets:delete(H#handle.node_tab, NodeId),
            ets:delete(H#handle.retire_tab, NodeId)
        end,
        Reclaimable
    ),
    length(Reclaimable).


-doc """
Current epoch value. Strictly increases on every successful write.
""".
-spec current_epoch(Handle :: handle()) -> non_neg_integer().

current_epoch(#handle{current_epoch = E}) ->
    atomics:get(E, 1).


-doc """
Minimum epoch pinned by any active reader, or `infinity` if there are no
active readers. The janitor reclaims anything tagged strictly less than
this value.
""".
-spec min_active_epoch(Handle :: handle()) -> non_neg_integer() | infinity.

min_active_epoch(#handle{epoch_tab = E}) ->
    %% Collect all active reader slots and take the minimum.
    %% Using ets:foldl is fine for small reader populations (expected O(#
    %% concurrent readers)); for very large populations an ordered_set with
    %% {Epoch, Ref} keying would give O(1) min, but the tradeoff is per-op
    %% cost during reader registration. Kept simple for the prototype.
    case ets:foldl(
        fun({_Ref, Ep}, Min) -> min(Ep, Min) end,
        infinity,
        E
    ) of
        infinity -> infinity;
        Value -> Value
    end.


-doc false.
-spec retire_tab(Handle :: handle()) -> ets:tab().

retire_tab(#handle{retire_tab = R}) -> R.


-doc false.
-spec node_tab(Handle :: handle()) -> ets:tab().

node_tab(#handle{node_tab = N}) -> N.


%% =============================================================================
%% TEST HELPERS
%% =============================================================================

-ifdef(TEST).

root_id(#handle{} = H) ->
    element(1, read_root(H)).

node_count(#handle{} = H) ->
    ets:info(H#handle.node_tab, size).

dump(#handle{} = H) ->
    lists:sort(ets:tab2list(H#handle.node_tab)).

retire_count(#handle{} = H) ->
    ets:info(H#handle.retire_tab, size).

epoch_tab_count(#handle{} = H) ->
    ets:info(H#handle.epoch_tab, size).

-endif.


%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
init_root(#handle{} = H) ->
    RootId = fresh_id(),
    Empty = #pnode{
        id = RootId,
        prefix = <<>>,
        children = ?EMPTY_CHILDREN,
        leaves = #{}
    },
    true = ets:insert(H#handle.node_tab, Empty),
    true = ets:insert(H#handle.root_tab, {?ROOT_KEY, RootId, 0}),
    ok.


%% @private
read_root(#handle{root_tab = R}) ->
    [{?ROOT_KEY, RootId, V}] = ets:lookup(R, ?ROOT_KEY),
    {RootId, V}.


%% @private
fresh_id() ->
    erlang:unique_integer([positive, monotonic]).


%% @private
%% Retire a list of node IDs, tagging each with the post-bump epoch. The
%% invariant we need for safe reclamation is: the epoch bump happens AFTER
%% the CAS that makes these nodes unreachable. `publish/*` guarantees that
%% ordering. See `reclaim/1` for the reclamation rule.
retire(#handle{retire_tab = R, current_epoch = E}, NodeIds) ->
    NewEpoch = atomics:add_get(E, 1, 1),
    Rows = [{Id, NewEpoch} || Id <- NodeIds],
    ets:insert(R, Rows),
    NewEpoch.


%% @private
%% Compute the largest tag such that reclaiming everything with tag < this
%% value is safe.
%%
%% If no reader is active, we can reclaim everything: SafeTag is one past
%% the current epoch (strictly greater than any assigned tag).
%%
%% If readers are active, SafeTag is the minimum epoch any reader is
%% pinning. A retire entry tagged T is reclaimable iff T < SafeTag, i.e.
%% every active reader has moved strictly past T.
safe_reclaim_epoch(#handle{} = H) ->
    case min_active_epoch(H) of
        infinity -> current_epoch(H) + 1;
        MinActive -> MinActive
    end.


%% @private
%% Reader wrapper that pins the current epoch for the duration of Fun.
%%
%% Uses a unique `make_ref()` as the slot key so nested reads (rare but
%% possible in tests or callbacks) never clobber an outer reader's slot,
%% and scheduler migration between operations is irrelevant. `try/after`
%% guarantees cleanup even under exception.
with_epoch(#handle{epoch_tab = ET, current_epoch = CE}, Fun) ->
    Ref = erlang:make_ref(),
    E = atomics:get(CE, 1),
    true = ets:insert(ET, {Ref, E}),
    try
        Fun()
    after
        ets:delete(ET, Ref)
    end.


%% @private
%% Core write loop: walk (path-copy), CAS on root, discard + retry on loss.
%%
%% `Walk` is a fun/1 that takes the in-memory root #pnode{} and returns
%% {NewRootId, RetiredIds, FreshIds} — see walk_insert / walk_remove.
do_write(_H, _Walk, 0) ->
    {error, cas_exhausted};
do_write(#handle{} = H, Walk, N) ->
    {OldRootId, V} = read_root(H),
    case ets:lookup(H#handle.node_tab, OldRootId) of
        [] ->
            %% The root row we saw was concurrently retired out from under us.
            do_write(H, Walk, N - 1);
        [OldRoot] ->
            {NewRootId, Retired, Fresh} = Walk(OldRoot),
            case NewRootId =:= OldRootId of
                true ->
                    %% No-op (e.g., remove of a non-existent key). No CAS
                    %% needed. `Fresh` should be empty in this case, and
                    %% `Retired` carries nothing the caller cares about.
                    ok;
                false ->
                    publish(H, OldRootId, V, NewRootId, Retired, Fresh, Walk, N)
            end
    end.


%% @private
publish(#handle{root_tab = RT} = H, OldRootId, V, NewRootId, Retired, Fresh,
        Walk, N) ->
    NewVersion = V + 1,
    Match = [{{?ROOT_KEY, OldRootId, V},
              [],
              [{const, {?ROOT_KEY, NewRootId, NewVersion}}]}],
    case ets:select_replace(RT, Match) of
        1 ->
            %% CAS succeeded → the retired nodes are now unreachable from
            %% the current root. Bump the epoch (inside `retire/2`) AFTER
            %% the CAS so any reader that reads `current_epoch` and then
            %% `root_tab` in that order sees either (old epoch, old root)
            %% or (new epoch, new root) — never (new epoch, old root).
            %% `Retired` already starts with OldRootId because each walk's
            %% top level path-copies the root it was handed.
            _NewEpoch = retire(H, Retired),
            ok;
        0 ->
            discard_fresh(H, Fresh),
            erlang:yield(),
            do_write(H, Walk, N - 1)
    end.


%% @private
discard_fresh(#handle{node_tab = T}, FreshIds) ->
    lists:foreach(fun(Id) -> ets:delete(T, Id) end, FreshIds).


%% @private
%% Update loop: reads the leaf's current value, applies UpdateFun,
%% dispatches to walk_insert/walk_remove/noop, then CAS-publishes. On CAS
%% failure, re-reads and re-applies — so the UpdateFun must be safe to
%% invoke multiple times under contention.
do_update(_H, _Key, _Policy, _UpdateFun, 0) ->
    {error, cas_exhausted};
do_update(#handle{} = H, Key, Policy, UpdateFun, N) ->
    {OldRootId, V} = read_root(H),
    case ets:lookup(H#handle.node_tab, OldRootId) of
        [] ->
            do_update(H, Key, Policy, UpdateFun, N - 1);
        [OldRoot] ->
            CurrentVal =
                case walk_lookup(H#handle.node_tab, OldRoot, Key, 0, Policy) of
                    {ok, Val} -> Val;
                    error     -> undefined
                end,
            case UpdateFun(CurrentVal) of
                noop ->
                    noop;
                {ok, NewValue} ->
                    {NewRootId, Retired, Fresh} =
                        walk_insert(H, OldRoot, Key, 0, Policy, NewValue),
                    finalize_update(H, Key, Policy, UpdateFun, N,
                                    OldRootId, V,
                                    NewRootId, Retired, Fresh, ok);
                delete when CurrentVal =:= undefined ->
                    noop;
                delete ->
                    {NewRootId, Retired, Fresh} =
                        walk_remove(H, OldRoot, Key, 0, Policy),
                    case NewRootId =:= OldRootId of
                        true ->
                            noop;
                        false ->
                            finalize_update(H, Key, Policy, UpdateFun, N,
                                            OldRootId, V,
                                            NewRootId, Retired, Fresh,
                                            deleted)
                    end
            end
    end.


%% @private
finalize_update(#handle{root_tab = RT} = H, Key, Policy, UpdateFun, N,
                OldRootId, V, NewRootId, Retired, Fresh, Outcome) ->
    NewVersion = V + 1,
    Match = [{{?ROOT_KEY, OldRootId, V},
              [],
              [{const, {?ROOT_KEY, NewRootId, NewVersion}}]}],
    case ets:select_replace(RT, Match) of
        1 ->
            _ = retire(H, Retired),
            Outcome;
        0 ->
            discard_fresh(H, Fresh),
            erlang:yield(),
            do_update(H, Key, Policy, UpdateFun, N - 1)
    end.


%% -----------------------------------------------------------------------------
%% CHILDREN — adaptive-sized container operations
%% -----------------------------------------------------------------------------


%% @private
%% Fetch the child pointer stored under `Byte`. Returns `undefined` if
%% there is none.
child_get(Byte, {n_small, Map}) ->
    maps:get(Byte, Map, undefined);
child_get(Byte, {n256, Tuple}) ->
    element(Byte + 1, Tuple).


%% @private
%% Store `Ptr` under `Byte`. Promotes `n_small` to `n256` when the map
%% crosses the threshold. Path copying already allocates a fresh node per
%% mutation, so promotion here is just picking the right container shape.
child_set(Byte, Ptr, {n_small, Map}) ->
    Map1 = maps:put(Byte, Ptr, Map),
    case map_size(Map1) of
        N when N =< ?N_SMALL_CAPACITY -> {n_small, Map1};
        _                             -> {n256, small_to_tuple(Map1)}
    end;
child_set(Byte, Ptr, {n256, Tuple}) ->
    {n256, setelement(Byte + 1, Tuple, Ptr)}.


%% @private
%% Remove the child stored under `Byte`. Demotes `n256` back to `n_small`
%% when occupancy drops to the threshold, keeping memory proportional to
%% the current child count after heavy deletes.
child_delete(Byte, {n_small, Map}) ->
    {n_small, maps:remove(Byte, Map)};
child_delete(Byte, {n256, Tuple}) ->
    Tuple1 = setelement(Byte + 1, Tuple, undefined),
    case n256_count(Tuple1, 1, 0, ?N_SMALL_CAPACITY + 1) of
        over -> {n256, Tuple1};
        _N   -> {n_small, tuple_to_small(Tuple1)}
    end.


%% @private
small_to_tuple(Map) ->
    T0 = erlang:make_tuple(?CHILDREN_ARITY, undefined),
    maps:fold(
        fun(B, C, T) -> setelement(B + 1, T, C) end,
        T0,
        Map
    ).


%% @private
tuple_to_small(Tuple) ->
    tuple_to_small(Tuple, 1, #{}).

tuple_to_small(_Tuple, I, Acc) when I > ?CHILDREN_ARITY ->
    Acc;
tuple_to_small(Tuple, I, Acc) ->
    case element(I, Tuple) of
        undefined -> tuple_to_small(Tuple, I + 1, Acc);
        C         -> tuple_to_small(Tuple, I + 1, maps:put(I - 1, C, Acc))
    end.


%% @private
%% Count non-undefined slots in an n256 tuple, short-circuiting at `Limit`
%% so the delete path doesn't pay O(256) on every operation against a
%% node that is staying wide.
n256_count(_Tuple, I, N, _Limit) when I > ?CHILDREN_ARITY ->
    N;
n256_count(_Tuple, _I, N, Limit) when N >= Limit ->
    over;
n256_count(Tuple, I, N, Limit) ->
    case element(I, Tuple) of
        undefined -> n256_count(Tuple, I + 1, N, Limit);
        _         -> n256_count(Tuple, I + 1, N + 1, Limit)
    end.


%% @private
%% True iff the container has no children at all.
children_is_empty({n_small, Map}) -> map_size(Map) =:= 0;
children_is_empty({n256, T})      -> n256_count(T, 1, 0, 1) =:= 0.


%% @private
%% Fold Fun(Byte, ChildPtr, Acc) over all children in ascending byte
%% order. Used by fold/3 and by `collect_reachable` during truncate.
%% `maps:iterator/2` with the `ordered` arg is the documented way to get
%% key-sorted iteration; `maps:to_list/1` order is undefined.
children_fold(Fun, Acc0, {n_small, Map}) ->
    small_map_fold_ordered(Fun, Acc0, maps:iterator(Map, ordered));
children_fold(Fun, Acc0, {n256, Tuple}) ->
    tuple_fold_children(Fun, Acc0, Tuple, 1).


%% @private
small_map_fold_ordered(Fun, Acc, Iter) ->
    case maps:next(Iter) of
        none -> Acc;
        {B, C, Iter1} ->
            small_map_fold_ordered(Fun, Fun(B, C, Acc), Iter1)
    end.


%% @private
tuple_fold_children(_Fun, Acc, _Tuple, I) when I > ?CHILDREN_ARITY ->
    Acc;
tuple_fold_children(Fun, Acc, Tuple, I) ->
    case element(I, Tuple) of
        undefined -> tuple_fold_children(Fun, Acc, Tuple, I + 1);
        C         -> tuple_fold_children(Fun, Fun(I - 1, C, Acc), Tuple, I + 1)
    end.


%% -----------------------------------------------------------------------------
%% INSERT
%% -----------------------------------------------------------------------------


%% @private
%% walk_insert/6 — path-copy insert.
%%
%% Returns {NewNodeId, Retired, Fresh} where
%%   Retired :: [node_id()] — IDs of old nodes replaced by this walk
%%                             (candidates for reclamation on successful CAS)
%%   Fresh   :: [node_id()] — IDs of nodes newly inserted in ETS by this walk
%%                             (rows to delete on CAS failure)
walk_insert(H, Node, Key, Depth, Policy, Value) ->
    Remaining = binary_part(Key, Depth, byte_size(Key) - Depth),
    NodePrefix = Node#pnode.prefix,
    case prefix_compare(NodePrefix, Remaining) of
        {match, Consumed} when Consumed == byte_size(Remaining) ->
            store_leaf(H, Node, Key, Policy, Value);
        {match, Consumed} ->
            insert_into_child(H, Node, Key, Depth + Consumed, Policy, Value);
        {mismatch, CommonLen} ->
            split_node(H, Node, Key, Depth, CommonLen, Policy, Value)
    end.


%% @private
%% prefix_compare(NodePrefix, Remaining) returns how many leading bytes of
%% NodePrefix match Remaining.
%%   - {match, Len}    — NodePrefix is fully consumed by Remaining (Len == |NP|)
%%   - {mismatch, N}   — they diverge at position N, OR Remaining is shorter
%%                       than NodePrefix (N == |Remaining|)
prefix_compare(NodePrefix, Remaining) ->
    NPSize = byte_size(NodePrefix),
    N = common_prefix(NodePrefix, Remaining, 0),
    if
        N =:= NPSize -> {match, NPSize};
        true         -> {mismatch, N}  %% covers both "Remaining shorter"
                                       %% and "diverged mid-way"
    end.


%% @private
%% Count matching leading bytes by binary-pattern-match walk. Avoids the
%% BIF-per-byte cost of `binary:at/2` with an index argument.
common_prefix(<<B, At/binary>>, <<B, Bt/binary>>, N) ->
    common_prefix(At, Bt, N + 1);
common_prefix(_, _, N) ->
    N.


%% @private
%% Store a leaf directly on this node. Because `store_leaf` is only
%% reached when the caller's Key has been fully consumed by the walk,
%% Node's path IS the caller's Key — we don't store the Key at all.
%% Leaves are keyed by Policy only (at most one leaf per policy per node:
%% exact, prefix, wildcard).
store_leaf(H, Node, _Key, Policy, Value) ->
    NewLeaves = maps:put(Policy, Value, Node#pnode.leaves),
    NewId = fresh_id(),
    NewNode = Node#pnode{id = NewId, leaves = NewLeaves},
    true = ets:insert(H#handle.node_tab, NewNode),
    {NewId, [Node#pnode.id], [NewId]}.


%% @private
%% Descend into the child keyed by the next byte of Key.
insert_into_child(H, Node, Key, Depth, Policy, Value) ->
    Byte = binary:at(Key, Depth),
    case child_get(Byte, Node#pnode.children) of
        undefined ->
            TailKey = binary_part(Key, Depth + 1, byte_size(Key) - Depth - 1),
            NewChildId = fresh_id(),
            NewChild = #pnode{
                id = NewChildId,
                prefix = TailKey,
                children = ?EMPTY_CHILDREN,
                leaves = #{Policy => Value}
            },
            true = ets:insert(H#handle.node_tab, NewChild),
            NewChildren = child_set(Byte, {node, NewChildId},
                                    Node#pnode.children),
            NewId = fresh_id(),
            NewNode = Node#pnode{id = NewId, children = NewChildren},
            true = ets:insert(H#handle.node_tab, NewNode),
            {NewId, [Node#pnode.id], [NewId, NewChildId]};
        {node, ChildId} ->
            [Child] = ets:lookup(H#handle.node_tab, ChildId),
            {NewChildId, RetiredBelow, FreshBelow} =
                walk_insert(H, Child, Key, Depth + 1, Policy, Value),
            NewChildren = child_set(Byte, {node, NewChildId},
                                    Node#pnode.children),
            NewId = fresh_id(),
            NewNode = Node#pnode{id = NewId, children = NewChildren},
            true = ets:insert(H#handle.node_tab, NewNode),
            {NewId,
             [Node#pnode.id | RetiredBelow],
             [NewId | FreshBelow]}
    end.


%% @private
%% Node's prefix diverges from Remaining at position CommonLen. Build a new
%% inner node with the common part as its prefix, and up to two children:
%% the trimmed old node, and (if the new key has a non-empty tail past the
%% divergence) a new leaf-bearing sibling.
split_node(H, Node, Key, Depth, CommonLen, Policy, Value) ->
    OldPrefix = Node#pnode.prefix,
    Remaining = binary_part(Key, Depth, byte_size(Key) - Depth),
    CommonPart = binary_part(OldPrefix, 0, CommonLen),
    OldTail = binary_part(OldPrefix, CommonLen,
                          byte_size(OldPrefix) - CommonLen),

    OldTailByte = binary:at(OldTail, 0),
    OldTailRest = binary_part(OldTail, 1, byte_size(OldTail) - 1),
    OldTrimmedId = fresh_id(),
    OldTrimmed = Node#pnode{id = OldTrimmedId, prefix = OldTailRest},
    true = ets:insert(H#handle.node_tab, OldTrimmed),

    InnerChildren1 = child_set(OldTailByte, {node, OldTrimmedId},
                               ?EMPTY_CHILDREN),

    case byte_size(Remaining) == CommonLen of
        true ->
            InnerId = fresh_id(),
            Inner = #pnode{
                id = InnerId,
                prefix = CommonPart,
                children = InnerChildren1,
                leaves = #{Policy => Value}
            },
            true = ets:insert(H#handle.node_tab, Inner),
            {InnerId, [Node#pnode.id], [InnerId, OldTrimmedId]};
        false ->
            NewKeyTailByte = binary:at(Remaining, CommonLen),
            NewKeyTailRest = binary_part(Remaining,
                                         CommonLen + 1,
                                         byte_size(Remaining) - CommonLen - 1),
            NewLeafId = fresh_id(),
            NewLeafNode = #pnode{
                id = NewLeafId,
                prefix = NewKeyTailRest,
                children = ?EMPTY_CHILDREN,
                leaves = #{Policy => Value}
            },
            true = ets:insert(H#handle.node_tab, NewLeafNode),
            InnerChildren2 = child_set(NewKeyTailByte, {node, NewLeafId},
                                       InnerChildren1),
            InnerId = fresh_id(),
            Inner = #pnode{
                id = InnerId,
                prefix = CommonPart,
                children = InnerChildren2,
                leaves = #{}
            },
            true = ets:insert(H#handle.node_tab, Inner),
            {InnerId,
             [Node#pnode.id],
             [InnerId, NewLeafId, OldTrimmedId]}
    end.




%% -----------------------------------------------------------------------------
%% REMOVE
%% -----------------------------------------------------------------------------


%% @private
%% walk_remove/5 — path-copy delete. Same 3-tuple contract as walk_insert/6.
%%
%% In the "{Key, Policy} not present" case, returns {Node#pnode.id, [], []}
%% — unchanged ID with empty retired/fresh lists. Callers detect the no-op
%% via NewId =:= OldId and skip the CAS.
walk_remove(H, Node, Key, Depth, Policy) ->
    Remaining = binary_part(Key, Depth, byte_size(Key) - Depth),
    NodePrefix = Node#pnode.prefix,
    case prefix_compare(NodePrefix, Remaining) of
        {match, Consumed} when Consumed == byte_size(Remaining) ->
            remove_leaf_here(H, Node, Key, Policy);
        {match, Consumed} ->
            remove_from_child(H, Node, Key, Depth + Consumed, Policy);
        {mismatch, _} ->
            {Node#pnode.id, [], []}
    end.


%% @private
remove_leaf_here(H, Node, _Key, Policy) ->
    case maps:is_key(Policy, Node#pnode.leaves) of
        false ->
            {Node#pnode.id, [], []};
        true ->
            NewLeaves = maps:remove(Policy, Node#pnode.leaves),
            NewId = fresh_id(),
            NewNode = Node#pnode{id = NewId, leaves = NewLeaves},
            true = ets:insert(H#handle.node_tab, NewNode),
            {NewId, [Node#pnode.id], [NewId]}
    end.


%% @private
remove_from_child(H, Node, Key, Depth, Policy) ->
    Byte = binary:at(Key, Depth),
    case child_get(Byte, Node#pnode.children) of
        undefined ->
            {Node#pnode.id, [], []};
        {node, ChildId} ->
            [Child] = ets:lookup(H#handle.node_tab, ChildId),
            {NewChildId, RetiredBelow, FreshBelow} =
                walk_remove(H, Child, Key, Depth + 1, Policy),
            case NewChildId =:= ChildId of
                true ->
                    {Node#pnode.id, RetiredBelow, FreshBelow};
                false ->
                    [NewChild] = ets:lookup(H#handle.node_tab, NewChildId),
                    {NewChildren, ExtraRetired, ExtraFresh} =
                        case is_child_empty(NewChild) of
                            true ->
                                ets:delete(H#handle.node_tab, NewChildId),
                                {child_delete(Byte, Node#pnode.children),
                                 [],
                                 lists:delete(NewChildId, FreshBelow)};
                            false ->
                                {child_set(Byte, {node, NewChildId},
                                           Node#pnode.children),
                                 [],
                                 FreshBelow}
                        end,
                    NewId = fresh_id(),
                    NewNode = Node#pnode{id = NewId, children = NewChildren},
                    true = ets:insert(H#handle.node_tab, NewNode),
                    {NewId,
                     [Node#pnode.id | RetiredBelow ++ ExtraRetired],
                     [NewId | ExtraFresh]}
            end
    end.




%% @private
is_child_empty(#pnode{leaves = L, children = C}) when map_size(L) =:= 0 ->
    children_is_empty(C);
is_child_empty(_) ->
    false.


%% -----------------------------------------------------------------------------
%% LOOKUP / FOLD
%% -----------------------------------------------------------------------------


%% @private
walk_lookup(Tab, Node, Key, Depth, Policy) ->
    Remaining = binary_part(Key, Depth, byte_size(Key) - Depth),
    case prefix_compare(Node#pnode.prefix, Remaining) of
        {match, Consumed} when Consumed == byte_size(Remaining) ->
            maps:find(Policy, Node#pnode.leaves);
        {match, Consumed} ->
            Byte = binary:at(Key, Depth + Consumed),
            case child_get(Byte, Node#pnode.children) of
                undefined -> error;
                {node, ChildId} ->
                    case ets:lookup(Tab, ChildId) of
                        [] -> error;
                        [Child] ->
                            walk_lookup(Tab, Child, Key,
                                        Depth + Consumed + 1, Policy)
                    end
            end;
        {mismatch, _} ->
            error
    end.


%% @private
%% `Path0` is an iolist of the stored bytes walked so far (root → this
%% node, excluding this node's own prefix). Leaves at this node have key
%% = `Path0 ++ Node.prefix` — realised as a binary once per node when the
%% node has any leaves to emit. Most nodes have no leaves, so the typical
%% per-node cost is zero allocations.
fold_node(Tab, #pnode{prefix = P, leaves = L, children = C}, Path0, Fun, Acc0) ->
    PathHere = [Path0, P],
    Acc1 = case map_size(L) of
        0 ->
            Acc0;
        _ ->
            Key = iolist_to_binary(PathHere),
            maps:fold(fun(_Policy, V, A) -> Fun(Key, V, A) end, Acc0, L)
    end,
    children_fold(
        fun(Byte, {node, ChildId}, A) ->
            case ets:lookup(Tab, ChildId) of
                [] -> A;
                [Child] ->
                    ChildPath = [PathHere, Byte],
                    fold_node(Tab, Child, ChildPath, Fun, A)
            end
        end,
        Acc1,
        C
    ).


%% -----------------------------------------------------------------------------
%% MATCH
%% -----------------------------------------------------------------------------


%% @private
%% Walk the trie against Target, collecting every leaf whose stored key
%% matches under its policy. The algorithm:
%%
%%   - Walk each node's prefix bytes against Target. A stored byte of
%%     `\0` (?WILDCARD_BYTE) means "consume one non-empty target segment"
%%     (for wildcard patterns).
%%   - At every node reached, collect `prefix`-tagged leaves unconditionally
%%     (reaching the node means Target has the stored key as a byte-prefix).
%%     Collect `exact` and `wildcard` leaves only when Target is fully
%%     consumed at this node.
%%   - Descend into the literal-byte child at the next target byte AND into
%%     the wildcard child (byte `\0`), with the latter consuming a segment
%%     from Target first.
%% `Path0` is the stored-key path (iolist) from root to `Node`, excluding
%% `Node.prefix`. Wildcard bytes in the stored path appear verbatim (`\0`);
%% the caller that emitted them can `decode_pattern/1` if they want the
%% URI-level form. Emitted only when a leaf is actually collected.
%%
%% `TargetRest` is the sub-binary of Target yet to be matched. It shrinks
%% as bytes are consumed. Using a shrinking sub-binary (rather than
%% Target+index) keeps the hot path free of `binary:at/2` BIF calls — the
%% binary pattern-match compiler emits direct byte loads.
match_walk(Tab, Node, TargetRest, Path0, Acc0) ->
    case walk_prefix_bytes(Node#pnode.prefix, TargetRest) of
        no_match ->
            Acc0;
        {match, NewTargetRest} ->
            PathHere = [Path0, Node#pnode.prefix],
            Acc1 = collect_leaves_for_match(Node, PathHere,
                                            NewTargetRest, Acc0),
            descend_match(Tab, Node, NewTargetRest, PathHere, Acc1)
    end.


%% @private
collect_leaves_for_match(#pnode{leaves = L}, PathHere, TargetRest, Acc0) ->
    case map_size(L) of
        0 ->
            Acc0;
        _ ->
            Key = iolist_to_binary(PathHere),
            TargetFullyConsumed = (TargetRest =:= <<>>),
            maps:fold(
                fun
                    (prefix, V, A) ->
                        [{Key, prefix, V} | A];
                    (Policy, V, A)
                        when (Policy =:= exact orelse Policy =:= wildcard)
                        andalso TargetFullyConsumed ->
                        [{Key, Policy, V} | A];
                    (_, _, A) ->
                        A
                end,
                Acc0,
                L
            )
    end.


%% @private
descend_match(_Tab, _Node, <<>>, _PathHere, Acc) ->
    Acc;
descend_match(Tab, Node, <<TargetByte, RestAfter/binary>> = TargetRest,
              PathHere, Acc0) ->
    Acc1 = descend_literal(Tab, Node, TargetByte, RestAfter, PathHere, Acc0),
    descend_wildcard(Tab, Node, TargetRest, PathHere, Acc1).


%% @private
descend_literal(Tab, Node, TargetByte, RestAfter, PathHere, Acc) ->
    case child_get(TargetByte, Node#pnode.children) of
        undefined -> Acc;
        {node, ChildId} ->
            case ets:lookup(Tab, ChildId) of
                [] -> Acc;
                [Child] ->
                    ChildPath = [PathHere, TargetByte],
                    match_walk(Tab, Child, RestAfter, ChildPath, Acc)
            end
    end.


%% @private
descend_wildcard(Tab, Node, TargetRest, PathHere, Acc) ->
    case child_get(?WILDCARD_BYTE, Node#pnode.children) of
        undefined -> Acc;
        {node, ChildId} ->
            case skip_segment(TargetRest) of
                end_of_target -> Acc;
                {ok, NewRest} ->
                    case ets:lookup(Tab, ChildId) of
                        [] -> Acc;
                        [Child] ->
                            ChildPath = [PathHere, ?WILDCARD_BYTE],
                            match_walk(Tab, Child, NewRest, ChildPath, Acc)
                    end
            end
    end.


%% @private
%% Walk `Prefix` against `TargetRest`, consuming bytes as we go. On a `\0`
%% in Prefix, skip one non-empty URI segment from TargetRest. Returns
%% `no_match` or `{match, NewTargetRest}`.
%%
%% Binary-pattern-match walk: each step is a single-byte check + sub-binary
%% reference update. No `binary:at/2` or indexing BIF in the hot path.
walk_prefix_bytes(<<>>, TargetRest) ->
    {match, TargetRest};
walk_prefix_bytes(<<?WILDCARD_BYTE, RestPrefix/binary>>, TargetRest) ->
    case skip_segment(TargetRest) of
        end_of_target -> no_match;
        {ok, NewRest} -> walk_prefix_bytes(RestPrefix, NewRest)
    end;
walk_prefix_bytes(<<B, RestPrefix/binary>>, <<B, RestTarget/binary>>) ->
    walk_prefix_bytes(RestPrefix, RestTarget);
walk_prefix_bytes(_, _) ->
    no_match.


%% @private
%% Advance past the current target URI segment. The segment must be
%% non-empty (WAMP targets are "strict" — no empty components; a wildcard
%% must match at least one byte). Returns `{ok, NewRest}` on success, or
%% `end_of_target` if TargetRest is empty or starts with a separator.
skip_segment(TargetRest) ->
    skip_segment(TargetRest, 0).

%% Count > 0: we've consumed at least one byte.
skip_segment(<<>>, Count) when Count > 0 ->
    {ok, <<>>};
skip_segment(<<?SEGMENT_SEP, _/binary>> = Rest, Count) when Count > 0 ->
    {ok, Rest};
%% Count == 0 with end-of-target OR an immediate separator: empty segment.
skip_segment(<<>>, 0) ->
    end_of_target;
skip_segment(<<?SEGMENT_SEP, _/binary>>, 0) ->
    end_of_target;
%% Consume one byte.
skip_segment(<<_, Rest/binary>>, Count) ->
    skip_segment(Rest, Count + 1).


%% -----------------------------------------------------------------------------
%% WAMP PATTERN ENCODING
%% -----------------------------------------------------------------------------


-doc """
Encode a WAMP wildcard-pattern URI for insertion as a `wildcard` leaf.

Replaces each empty URI component with the sentinel byte `\\0`. E.g.
`com..service.add` → `com.\\0.service.add`.

Callers MUST use this before `insert(H, Encoded, wildcard, Value)` so
that the walk against a target URI performs segment-skipping at the
wildcard positions.

`prefix` and `exact` patterns are stored unchanged — no encoding needed.
""".
-spec encode_pattern(URI :: binary()) -> key().

encode_pattern(URI) when is_binary(URI) ->
    Parts = binary:split(URI, <<?SEGMENT_SEP>>, [global]),
    Encoded = [case P of
                   <<>> -> <<?WILDCARD_BYTE>>;
                   _ -> P
               end || P <- Parts],
    iolist_to_binary(lists:join(<<?SEGMENT_SEP>>, Encoded)).


-doc """
Decode a wildcard-encoded key back to its WAMP URI form, replacing each
`\\0` component with the empty string.

Inverse of `encode_pattern/1`: `decode_pattern(encode_pattern(U)) =:= U`
for any valid wildcard URI.
""".
-spec decode_pattern(Encoded :: key()) -> binary().

decode_pattern(Encoded) when is_binary(Encoded) ->
    Parts = binary:split(Encoded, <<?SEGMENT_SEP>>, [global]),
    Decoded = [case P of
                   <<?WILDCARD_BYTE>> -> <<>>;
                   _ -> P
               end || P <- Parts],
    iolist_to_binary(lists:join(<<?SEGMENT_SEP>>, Decoded)).
