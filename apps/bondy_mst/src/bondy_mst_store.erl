%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_store).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Behaviour to be implemented for page stores to allow their manipulation.
This behaviour may also be implemented by store proxies that track operations
and implement different synchronization or caching mechanisms.
""").

-define(DEFAULT_CAPABILITIES, #{
    read_concurrency => false,
    transactions => false,
    %% `true` when the backend reads pages through a resource bound to the
    %% process that opened the store (e.g. the pack store's raw sealed-pack
    %% fds), in which case any fold MUST run in the owning process. Defaults
    %% to `false` — process-independent terms — which is what every memory
    %% backend serves; a backend that IS process-bound but fails to declare
    %% it fails loudly (`not_on_controlling_process`) rather than silently,
    %% the same way it would have before this capability existed.
    process_bound_reads => false
}).

-record(?MODULE, {
    mod :: module(),
    state :: backend(),
    transactions :: boolean()
}).

-type t() :: #?MODULE{}.
-type page() :: any().
-type backend() :: any().
-type encode_fun() :: fun((encode, bondy_mst_page:t()) -> binary()).
-type decode_fun() :: fun((decode, binary()) -> bondy_mst_page:t()).
-type serializer() :: module | encode_fun() | decode_fun().
-type opt() :: {serializer, serializer()} | {atom(), any()}.
-type opts() ::
    #{
        serializer => serializer(),
        atom() => any()
    }
    | [opt()].

-export_type([t/0]).
-export_type([backend/0]).
-export_type([serializer/0]).
-export_type([page/0]).
-export_type([opts/0]).

%% API
-export([close/1]).
-export([flush/1]).
-export([capabilities/1]).
-export([maybe_roll_for_seal/1]).
-export([complete_seal/2]).
-export([seal_in_flight/1]).
-export([copy/3]).
-export([destroy/1]).
-export([delete/2]).
-export([free/3]).
-export([gc/2]).
-export([get/2]).
-export([get_root/1]).
-export([has/2]).
-export([is_type/1]).
-export([list/1]).
-export([list/2]).
-export([missing_set/2]).
-export([name/1]).
-export([page_state/2]).
-export([open/3]).
-export([page_refs/2]).
-export([put/2]).
-export([set_root/2]).
-export([transaction/2]).

%% =============================================================================
%% CALLBACKS
%% =============================================================================

-callback open(HashAlgorithm :: atom(), Opts :: opts()) -> backend().

-callback close(backend()) -> ok.

%% Forces any state staged in memory (the current root, buffered pages) durable
%% WITHOUT releasing the backend. Optional: backends that hold no deferred
%% durable state (`ets`, `map`) need not implement it — the facade treats an
%% absent callback as a no-op. Durable backends return the updated backend so
%% the caller can thread the cleared dirty state forward.
-callback flush(backend()) -> {ok, backend()} | {error, term()}.

-optional_callbacks([flush/1]).

-callback get_root(backend()) -> hash() | undefined.

-callback set_root(backend(), hash()) -> backend().

-callback get(backend(), page()) -> page() | undefined.

-callback has(backend(), page()) -> boolean().

-callback list(backend()) -> [page()].

-callback put(backend(), page()) -> {Hash :: hash(), backend()}.

-callback delete(backend(), hash()) -> backend().

-callback copy(backend(), OtherStore :: t(), Hash :: hash()) -> backend().

?DOC("""
Releases the caller's claim on a page hash.

Called by every path-copying operation on the pages of the spine it just
rewrote. **A page hash reaching `free/3` is NOT necessarily garbage**: under
structural sharing it may still be referenced by an older root the consumer
retains (the defining property of a persistent structure — see
`bondy_mst:diff_to_list/2` against a previously captured root), by a peer
root pinned mid-pull, or by an in-flight merge accumulator.

An implementation may therefore delete the page immediately ONLY IF BOTH
hold:

1. it declares `concurrent_writes => false` in `capabilities/1` — otherwise
   another process may be mid-operation on that very hash; and
2. its consumer retains no root other than the current one — otherwise the
   deletion breaks a live tree.

When either is in doubt, TOMBSTONE and let `gc/2` establish liveness. That is
what `bondy_mst_ets_store` does (it cannot satisfy (1) — its pages live in a
shared public table), and what `bondy_mst_pack_store` does via its free set.
`bondy_mst_map_store` deletes outright, which is sound only because the store
IS its owning gen_server's state (satisfying (1)) and it is used where no old
root is retained.

Getting this wrong produces a root that references an absent page — a fault
that surfaces far from its cause, as an unservable root.
""").
-callback free(backend(), hash(), page()) -> backend().

-callback gc(backend(), KeepRoots :: [hash()]) ->
    {backend(), Metadata :: map()}.

-callback missing_set(backend(), Root :: binary()) -> sets:set(hash()).

-callback page_refs(Page :: page()) -> Refs :: [binary()].

-callback destroy(backend()) -> ok.

-callback transaction(backend(), Fun :: fun(() -> any())) ->
    any() | no_return().

-optional_callbacks([transaction/2]).

-callback capabilities(backend()) -> map().

-optional_callbacks([capabilities/1]).

-callback name(backend()) -> binary() | undefined.

-optional_callbacks([name/1]).

%% Forensic state of a single page hash: `live`, `{tombstoned, FreedAt}`
%% (freed but still readable), or `absent` (the row is gone).
%%
%% Optional. Implemented by backends that can distinguish the three, so a
%% diagnosing caller can tell WHICH layer lost a page: `absent` under a live
%% root means something deleted a still-referenced page (store layer), whereas
%% `live`/`tombstoned` means the page was readable all along and the miss came
%% from the walk (consumer / read path).
%% The epoch in `{tombstoned, _}` is whatever the backend can supply: a
%% monotonic free time where one is recorded per hash (`bondy_mst_ets_store`),
%% `undefined` where tombstoning is set membership with no per-hash time
%% (`bondy_mst_pack_store`). Callers classify on the TAG, never the payload.
-callback page_state(backend(), hash()) ->
    live | {tombstoned, integer() | undefined} | absent.

-optional_callbacks([page_state/2]).

-callback maybe_roll_for_seal(backend()) ->
    {rolled, Job :: term(), backend()}
    | {defer, backend()}
    | {noop, backend()}.

-callback complete_seal(backend(), PackId :: pos_integer()) ->
    {ok, backend()} | {error, term()}.

-callback seal_in_flight(backend()) -> boolean().

-optional_callbacks([maybe_roll_for_seal/1, complete_seal/2, seal_in_flight/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec open(Mod :: module(), HashAlgo :: atom(), Opts :: map() | list()) ->
    t() | no_return().

open(Mod, HashAlgo, Opts) when
    is_atom(Mod) andalso
        is_atom(HashAlgo) andalso
        (is_map(Opts) orelse is_list(Opts))
->
    #?MODULE{
        mod = Mod,
        state = Mod:open(HashAlgo, Opts),
        transactions = supports_transactions(Mod)
    }.

-spec close(t()) -> ok.

close(#?MODULE{mod = Mod, state = State}) ->
    Mod:close(State).

?DOC("""
Forces any in-memory durable state (the current root, buffered pages) to disk
without releasing the backend. For a durable backend this is the per-commit
durability barrier — it advances the on-disk root in lockstep with the WAL
consumer offset so crash replay is bounded to one commit window. For an
in-memory backend (`ets`/`map`) it is a no-op. Returns the updated store so the
caller threads the cleared dirty state forward.
""").
-spec flush(Store :: t()) -> {ok, t()} | {error, term()}.

flush(#?MODULE{mod = Mod, state = State0} = T) ->
    Default = fun() -> {ok, State0} end,
    case bondy_mst_utils:apply_lazy(Mod, flush, 1, [State0], Default) of
        {ok, State1} ->
            {ok, T#?MODULE{state = State1}};
        {error, _} = Error ->
            Error
    end.

?DOC("""
Rolls the backend's incoming buffer aside for an asynchronous seal, if its
threshold is crossed and no seal is in flight. Returns
`{rolled, {Mod, Job}, T1}` — a self-contained token the caller runs
off-process via `bondy_mst:run_seal_job/1` and then finalises with
`complete_seal/2` — or `{defer, T1}` (a seal is already in flight — apply
backpressure), or `{noop, T1}`.

The token carries the backend module so a worker process can execute it
without holding the store. Backends that do not implement the
asynchronous-seal callbacks (in-memory stores, which never seal) always
answer `{noop, T}`.
""").
-spec maybe_roll_for_seal(t()) ->
    {rolled, {module(), term()}, t()} | {defer, t()} | {noop, t()}.

maybe_roll_for_seal(#?MODULE{mod = Mod, state = State0} = T) ->
    Default = fun() -> {noop, State0} end,
    case
        bondy_mst_utils:apply_lazy(
            Mod, maybe_roll_for_seal, 1, [State0], Default
        )
    of
        {rolled, Job, State1} ->
            {rolled, {Mod, Job}, T#?MODULE{state = State1}};
        {defer, State1} ->
            {defer, T#?MODULE{state = State1}};
        {noop, State1} ->
            {noop, T#?MODULE{state = State1}}
    end.

?DOC("""
Finalises the asynchronous seal whose worker has completed the job for
`PackId`: commits it and mounts the new sealed view. Returns the updated
store. A backend without the callback treats it as a no-op.
""").
-spec complete_seal(t(), PackId :: pos_integer()) ->
    {ok, t()} | {error, term()}.

complete_seal(#?MODULE{mod = Mod, state = State0} = T, PackId) ->
    Default = fun() -> {ok, State0} end,
    case
        bondy_mst_utils:apply_lazy(
            Mod, complete_seal, 2, [State0, PackId], Default
        )
    of
        {ok, State1} ->
            {ok, T#?MODULE{state = State1}};
        {error, _} = Error ->
            Error
    end.

?DOC("""
Whether the backend has an asynchronous seal in flight. Backends without the
callback always answer `false`.
""").
-spec seal_in_flight(t()) -> boolean().

seal_in_flight(#?MODULE{mod = Mod, state = State}) ->
    Default = fun() -> false end,
    bondy_mst_utils:apply_lazy(Mod, seal_in_flight, 1, [State], Default).

-spec is_type(any()) -> boolean().

is_type(#?MODULE{}) -> true;
is_type(_) -> false.

?DOC("""
Get the root hash.
Returns hash or `undefined`.
""").
-spec get_root(Store :: t()) -> Root :: hash() | undefined.

get_root(#?MODULE{mod = Mod, state = State}) ->
    Mod:get_root(State).

?DOC("""
Get the root hash.
Returns hash or `undefined`.
> #### [.warn}
> WARNING: You should never call this function. It is used internally.
""").
-spec set_root(Store :: t(), Hash :: hash()) -> t().

set_root(#?MODULE{} = T, Hash) when is_binary(Hash) ->
    do_set_root(T, Hash).

?DOC("""
Get a page referenced by its hash.
Returns page or `undefined`.
""").
-spec get(Store :: t(), Hash :: hash()) -> Page :: page() | undefined.

get(#?MODULE{mod = Mod, state = State}, Hash) ->
    Mod:get(State, Hash).

-spec has(Store :: t(), Hash :: hash()) -> boolean().

has(#?MODULE{mod = Mod, state = State}, Hash) ->
    Mod:has(State, Hash).

?DOC("""
Returns the list of all the pages in the store.
""").
-spec list(Store :: t()) -> [page()].

list(#?MODULE{mod = Mod, state = State}) ->
    Mod:list(State).

?DOC("""
Returns the list of pages which have root `Root`.
""").
-spec list(Store :: t(), Root :: hash()) -> [page()].

list(#?MODULE{} = Store, Root) when is_binary(Root) ->
    fold_descendants(
        Store,
        Root,
        fun({_, P}, Acc) -> [P | Acc] end,
        []
    ).

?DOC("""
Put a page. Argument is the content of the page, returns the
hash that the store has associated to it.
""").
-spec put(Store :: t(), Page :: page()) -> {Hash :: hash(), Store :: t()}.

put(#?MODULE{mod = Mod, state = State0} = T, Page) ->
    {Hash, State} = Mod:put(State0, Page),
    {Hash, T#?MODULE{state = State}}.

?DOC("""
Deletes a page.
""").
-spec delete(Store :: t(), Hash :: hash()) -> Store :: t().

delete(#?MODULE{mod = Mod, state = State} = T, Page) ->
    T#?MODULE{state = Mod:delete(State, Page)}.

-spec copy(Store :: t(), OtherStore :: t(), Hash :: hash()) -> Store :: t().

copy(#?MODULE{mod = Mod, state = State0} = T, OtherStore, Hash) ->
    T#?MODULE{state = Mod:copy(State0, OtherStore, Hash)}.

-spec free(Store :: t(), Hash :: hash(), Page :: page()) -> Store :: t().

free(#?MODULE{mod = Mod, state = State0} = T0, Hash, Page) ->
    T = T0#?MODULE{state = Mod:free(State0, Hash, Page)},
    case get_root(T) of
        Hash ->
            do_set_root(T, undefined);
        _ ->
            T
    end.

-spec gc(Store :: t(), KeepRoots :: [hash()]) ->
    {Store :: t(), Metadata :: map()}.

gc(#?MODULE{mod = Mod, state = State0} = T, KeepRoots) ->
    {State, Meta} = Mod:gc(State0, KeepRoots),
    {T#?MODULE{state = State}, Meta}.

-spec page_refs(Store :: t(), Page :: page()) -> Refs :: [binary()].

page_refs(#?MODULE{mod = Mod}, Page) ->
    Mod:page_refs(Page).

?DOC("""
Returns the hashes of the pages identified by root hash that are missing
from the store.
""").
-spec missing_set(Store :: t(), Root :: binary()) -> [hash()].

missing_set(#?MODULE{mod = Mod, state = State}, Root) ->
    Mod:missing_set(State, Root).

?DOC("""
Destroys the backing store entirely (filesystem directory wipe / ETS
table teardown / etc.). Irreversible. Distinct from `delete/2`, which
tombstones a single page hash.
""").
-spec destroy(Store :: t()) -> ok.

destroy(#?MODULE{mod = Mod, state = State}) ->
    Mod:destroy(State).

-spec transaction(Store :: t(), Fun :: fun(() -> any())) ->
    any() | {error, Reason :: any()}.

transaction(#?MODULE{transactions = true, mod = Mod, state = State}, Fun) ->
    Mod:transaction(State, Fun);
transaction(#?MODULE{transactions = false}, Fun) ->
    Fun().

?DOC("""
The backend's configured name, or `undefined` when the backend has none
(or does not implement the optional callback). For the trees `bondy_oplog`
opens, the name is the instance id — which is what makes telemetry emitted
at this layer attributable to a shard.
""").
-spec name(Store :: t()) -> binary() | undefined.

name(#?MODULE{mod = Mod, state = State}) ->
    bondy_mst_utils:apply_lazy(
        Mod, name, 1, [State], fun() -> undefined end
    ).

?DOC("""
See the `page_state/2` callback. Returns `unknown` when the backend does not
implement it.
""").
-spec page_state(Store :: t(), Hash :: hash()) ->
    live | {tombstoned, integer()} | absent | unknown.

page_state(#?MODULE{mod = Mod, state = State}, Hash) ->
    bondy_mst_utils:apply_lazy(
        Mod, page_state, 2, [State, Hash], fun() -> unknown end
    ).

-spec capabilities(Store :: t()) -> map().

capabilities(#?MODULE{mod = Mod, state = State}) ->
    bondy_mst_utils:apply_lazy(
        Mod, capabilities, 1, [State], fun() ->
            maps:put(
                transactions,
                supports_transactions(Mod),
                ?DEFAULT_CAPABILITIES
            )
        end
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

supports_transactions(Mod) ->
    ok = bondy_mst_utils:ensure_loaded(Mod),
    erlang:function_exported(Mod, transaction, 2).

do_set_root(#?MODULE{mod = Mod, state = State0} = T, Hash) when
    is_binary(Hash) orelse Hash == undefined
->
    State = Mod:set_root(State0, Hash),
    T#?MODULE{state = State}.

%% @private
fold_descendants(_, undefined, _, Acc) ->
    Acc;
fold_descendants(Store, Root, Fun, AccIn) ->
    case ?MODULE:get(Store, Root) of
        undefined ->
            AccIn;
        Page ->
            Low = bondy_mst_page:low(Page),
            AccOut = fold_descendants(Store, Low, Fun, AccIn),

            bondy_mst_page:fold(
                Page,
                fun({_, _, Hash}, Acc0) ->
                    fold_descendants(Store, Hash, Fun, Acc0)
                end,
                Fun({Root, Page}, AccOut)
            )
    end.
