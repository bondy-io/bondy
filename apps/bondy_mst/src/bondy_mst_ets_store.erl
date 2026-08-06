%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_ets_store).

-behaviour(bondy_mst_store).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Read-concurrent, MST backend using `ets`.
""").

%%% 'public' unconditionally: the store's capabilities/1 advertises
%%% concurrent_writes => true, which bondy_oplog_sync_session:merge_pages/2
%%% relies on to short-circuit the gen_server hop and ets:insert/2
%%% directly from the sync session process. 'protected' made that path
%%% fail with {badarg, [{error_info, #{cause => access}}]} and the
%%% sync session would error out before integrate_peer_root could
%%% run, so peer events never reached the local MST and bondy_db:read/3
%%% saw only local writes. read_concurrency=true already covers the
%%% read path; the writer-side cost of 'public' is negligible compared
%%% to the per-tick gen_server round-trip the fast path avoids.
-define(ETS_ACCESS, public).

%% Page rows are 3-tuples `{Hash, Page, FreedAt}`. `FreedAt` is a
%% per-replica GC bookkeeping column (epoch | undefined), kept OUTSIDE
%% the page record so that `free/3` can mark a page via
%% `ets:update_element/3` (a single-slot, in-place write) instead of
%% re-inserting the whole page just to flip one field. The page's own
%% `freed_at` field is unused on this backend. The root row stays the
%% 2-tuple `{?ROOT_KEY, Hash}`; the 3-tuple match specs below never
%% match it (arity differs), so it is naturally excluded from listing
%% and pruning.
-define(FREED_AT_POS, 3).

-record(?MODULE, {
    name :: binary(),
    tab :: ets:tid(),
    hashing_algorithm :: atom(),
    opts :: opts_map()
}).

-type t() :: #?MODULE{}.
-type opt() ::
    {name, binary()}
    | {persistent, boolean()}.
-type opts() :: [opt()] | opts_map().
-type opts_map() :: #{
    name := binary(),
    persistent => boolean()
}.
-type page() :: bondy_mst_page:t().

-export_type([t/0]).
-export_type([page/0]).

%% API
-export([capabilities/1]).
-export([close/1]).
-export([flush/1]).
-export([copy/3]).
-export([destroy/1]).
-export([delete/2]).
-export([free/3]).
-export([gc/2]).
-export([get/2]).
-export([get_root/1]).
-export([has/2]).
-export([list/1]).
-export([missing_set/2]).
-export([name/1]).
-export([open/2]).
-export([page_refs/1]).
-export([put/2]).
-export([set_root/2]).

%% =============================================================================
%% BONDY_MST_STORE CALLBACKS
%% =============================================================================

-spec open(Algo :: atom(), Opts :: opts()) -> t() | no_return().

open(Algo, Opts) when is_atom(Algo), is_list(Opts) ->
    open(Algo, maps:from_list(Opts));
open(Algo, Opts0) when is_atom(Algo), is_map(Opts0) ->
    DefaultOpts = #{
        name => undefined,
        persistent => true
    },

    Opts = maps:merge(DefaultOpts, Opts0),

    ok = maps:foreach(
        fun
            (name, V) ->
                is_binary(V) orelse
                    error({badarg, [{name, V}]});
            (persistent, V) ->
                is_boolean(V) orelse
                    error({badarg, [{persistent, V}]})
        end,
        Opts
    ),

    Tab = ets:new(undefined, [
        set,
        ?ETS_ACCESS,
        {read_concurrency, true},
        {write_concurrency, auto},
        {decentralized_counters, true}
    ]),

    #?MODULE{
        name = maps:get(name, Opts),
        tab = Tab,
        hashing_algorithm = Algo,
        opts = Opts
    }.

-spec capabilities(t()) -> map().

capabilities(#?MODULE{} = T) ->
    #{
        transactions => false,
        read_concurrency => maps:get(persistent, T#?MODULE.opts),
        %% Pages live in a shared ETS table; any process holding the
        %% store handle can write concurrently.
        concurrent_writes => true,
        %% No seal flow at all — pages are never rolled into sealed packs,
        %% so the asynchronous-seal surface is a no-op for this backend.
        async_seal => false,
        %% Volatile: the ETS table does not survive an instance/node restart,
        %% so a WAL consumer must replay from the log to rebuild it.
        durable => false,
        %% Pages live in ETS: any process holding the handle can read them,
        %% so a fold may run wherever the caller pleases.
        process_bound_reads => false
    }.

-spec close(t()) -> ok.

close(#?MODULE{}) ->
    ok.

-spec flush(t()) -> {ok, t()}.

flush(#?MODULE{} = T) ->
    %% In-memory backend: nothing is staged for durability.
    {ok, T}.

-spec name(T :: t()) -> binary() | undefined.

name(#?MODULE{name = Val}) ->
    Val.

-spec get_root(T :: t()) -> Root :: hash() | undefined.

get_root(#?MODULE{tab = Tab}) ->
    do_get(Tab, ?ROOT_KEY).

-spec set_root(T :: t(), Hash :: hash()) -> t().

set_root(#?MODULE{tab = Tab} = T, Hash) ->
    true = ets:insert(Tab, {?ROOT_KEY, Hash}),
    T.

-spec get(T :: t(), Hash :: binary()) -> Page :: page() | undefined.

get(#?MODULE{tab = Tab}, Hash) ->
    do_get(Tab, Hash).

-spec has(T :: t(), Hash :: binary()) -> boolean().

has(#?MODULE{tab = Tab}, Hash) ->
    ets:member(Tab, Hash).

-spec put(T :: t(), Page :: page()) -> {Hash :: binary(), T :: t()}.

put(#?MODULE{tab = Tab, hashing_algorithm = Algo} = T, Page) ->
    Hash = bondy_mst_page:hash(Page, Algo),
    true = ets:insert(Tab, {Hash, Page, undefined}),
    {Hash, T}.

-spec delete(T :: t(), Hash :: binary()) -> T :: t().

delete(#?MODULE{tab = Tab} = T, Hash) ->
    true = ets:delete(Tab, Hash),
    T.

-spec copy(t(), OtherStore :: bondy_mst_store:t(), Hash :: binary()) -> t().

copy(#?MODULE{tab = Tab} = T, OtherStore, Hash) ->
    case bondy_mst_store:get(OtherStore, Hash) of
        undefined ->
            T;
        Page ->
            Refs = bondy_mst_store:page_refs(OtherStore, Page),
            T = lists:foldl(
                fun(Ref, Acc) -> copy(Acc, OtherStore, Ref) end,
                T,
                Refs
            ),
            true = ets:insert(Tab, {Hash, Page, undefined}),
            T
    end.

-spec list(t()) -> [page()].

list(#?MODULE{tab = Tab}) ->
    MS = [{{'$1', '$2', '_'}, [{'=/=', '$1', ?ROOT_KEY}], ['$2']}],
    ets:select(Tab, MS).

-spec free(T :: t(), Hash :: binary(), Page :: page()) -> T :: t().

free(#?MODULE{tab = Tab, opts = #{persistent := true}} = T, Hash, _Page0) ->
    %% Mark the page free by stamping only the FreedAt column in place;
    %% gc/2 (prune_freed) actually deletes it. `update_element` writes a
    %% single tuple slot rather than re-copying the whole page into the
    %% table (as a full re-insert would), so the cost is independent of
    %% page size. A concurrent reader still sees the intact page.
    _ = ets:update_element(Tab, Hash, {?FREED_AT_POS, erlang:monotonic_time()}),
    T;
free(#?MODULE{tab = Tab, opts = #{persistent := false}} = T, Hash, _Page) ->
    %% We immediately delete
    true = ets:delete(Tab, Hash),
    T.

-spec gc(T :: t(), KeepRoots :: [list()] | epoch()) ->
    {T :: t(), Metadata :: map()}.

gc(#?MODULE{opts = #{persistent := true}} = T, Epoch) when is_integer(Epoch) ->
    %% When the tree is marked as persistent we have several roots sharing
    %% subtrees. During destructive operations we mark freed pages with an
    %% epoch (freed_at) so that we can prune them here
    prune_freed(T, Epoch);
gc(#?MODULE{opts = #{persistent := _}} = T, KeepRoots) when
    is_list(KeepRoots)
->
    %% The algorithmm found in the paper, which is suboptimal to say the least
    case ets:info(T#?MODULE.tab, size) > 0 of
        true ->
            prune_unreachable(T, KeepRoots);
        false ->
            {T, #{name => T#?MODULE.name, freed_count => 0, freed_bytes => 0}}
    end.

-spec missing_set(T :: t(), Root :: binary()) -> sets:set(page()).

missing_set(T, Root) ->
    case get(T, Root) of
        undefined ->
            sets:from_list([Root], [{version, 2}]);
        Page ->
            lists:foldl(
                fun(Hash, Acc) -> sets:union(Acc, missing_set(T, Hash)) end,
                sets:new([{version, 2}]),
                page_refs(Page)
            )
    end.

-spec page_refs(Page :: page()) -> [binary()].

page_refs(Page) ->
    bondy_mst_page:refs(Page).

-spec destroy(t()) -> ok.

destroy(#?MODULE{tab = Tab}) ->
    ets:delete(Tab),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_get(Tab, Hash) ->
    case ets:lookup_element(Tab, Hash, 2, undefined) of
        undefined ->
            undefined;
        [Value] ->
            %% bag and duplicate bag tables
            Value;
        Value ->
            %%  set and ordered_set tables
            Value
    end.

%% @private
fold_pages(_, _, Acc, undefined) ->
    Acc;
fold_pages(Tab, Fun, AccIn, Root) ->
    case do_get(Tab, Root) of
        undefined ->
            AccIn;
        Page ->
            Low = bondy_mst_page:low(Page),
            AccOut = fold_pages(Tab, Fun, AccIn, Low),
            bondy_mst_page:fold(
                Page,
                fun({_, _, Hash}, Acc0) ->
                    fold_pages(Tab, Fun, Acc0, Hash)
                end,
                Fun({Root, Page}, AccOut)
            )
    end.

%% =============================================================================
%% PRIVATE: GARBAGE COLLECTION
%% =============================================================================

%% @private
bloom_filter(T, KeepRoots) ->
    Size = estimate_bloomfi_capacity(T),
    lists:foldl(
        fun(Root, Acc) ->
            Fun = fun({Hash, _}, InnerAcc) -> bloomfi:add(Hash, InnerAcc) end,
            fold_pages(T#?MODULE.tab, Fun, Acc, Root)
        end,
        bloomfi:new(Size),
        KeepRoots
    ).

%% @private
estimate_bloomfi_capacity(#?MODULE{} = T) ->
    ets:info(T#?MODULE.tab, size).

%% @private
prune_unreachable(#?MODULE{opts = #{persistent := _}} = T, KeepRoots) ->
    %% We build a bloomfilter containing all the hashes of pages emanating from
    %% roots in KeepRoots
    BF = bloom_filter(T, KeepRoots),

    Tab = T#?MODULE.tab,
    W0 = ets:info(Tab, memory),

    %% We iterate over all the tree hashes and remove any hash not in the bloom
    %% filter.
    MS = [{{'$1', '_', '_'}, [{'=/=', '$1', ?ROOT_KEY}], ['$1']}],
    All = ets:select(Tab, MS),

    Num = lists:foldl(
        fun(Hash, Acc) ->
            case bloomfi:member(Hash, BF) of
                true ->
                    %% This could be a false positive, which means we will not
                    %% free the page when we should, but we will eventually in
                    %% future executions
                    Acc;
                false ->
                    %% Definitely not in the set so we free
                    true = ets:delete(Tab, Hash),
                    Acc + 1
            end
        end,
        0,
        All
    ),

    W1 = ets:info(Tab, memory),
    %% `ets:info(_, memory)` reports words; convert the freed delta to
    %% bytes (was `memory:words/1`, no longer exported by the dep).
    Bytes = (W0 - W1) * erlang:system_info(wordsize),
    Meta = #{name => T#?MODULE.name, freed_count => Num, freed_bytes => Bytes},
    {T, Meta}.

%% @private
prune_freed(#?MODULE{} = T, Epoch) ->
    Tab = T#?MODULE.tab,
    %% Delete every page row whose FreedAt column (3rd element) is an
    %% integer epoch `=< Epoch`. Live pages carry `undefined` and the
    %% `is_integer` guard excludes them; the 2-tuple root row has no 3rd
    %% element and never matches this 3-tuple pattern.
    MatchSpec = [
        {
            {'_', '_', '$1'},
            [{is_integer, '$1'}, {'=<', '$1', {const, Epoch}}],
            [true]
        }
    ],
    W0 = ets:info(Tab, memory),
    Num = ets:select_delete(Tab, MatchSpec),
    W1 = ets:info(Tab, memory),
    %% `ets:info(_, memory)` reports words; convert the freed delta to
    %% bytes. (Was `memory:words/1`, which the resolved `memory` dep no
    %% longer exports — undef in this GC telemetry path.)
    Bytes = (W0 - W1) * erlang:system_info(wordsize),

    Meta = #{name => T#?MODULE.name, freed_count => Num, freed_bytes => Bytes},
    {T, Meta}.
