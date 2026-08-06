%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_map_store).

-behaviour(bondy_mst_store).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
This module implements the `bondy_mst_store` behaviour using an in-process
`map`.

As opposed to other backend stores, this module does not offer support for
read concurrency, and as a result:

* Versioning is not implemented, every mutating operation returns a copy of
the map; and
* All calls to `free/3` are made effective immediately by removing the pages
from the map.
""").

-record(?MODULE, {
    root :: hash() | undefined,
    hashing_algorithm :: atom(),
    pages = #{} :: map(),
    opts :: map()
}).

-type t() :: #?MODULE{}.
-type page() :: bondy_mst_page:t().
-type opts() :: #{} | [].

-export_type([t/0]).
-export_type([page/0]).

-export([close/1]).
-export([flush/1]).
-export([capabilities/1]).
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
    Default = #{read_concurrency => false},
    Opts = maps:merge(Default, Opts0),

    #?MODULE{
        hashing_algorithm = Algo,
        opts = Opts
    }.

-spec capabilities(t()) -> map().

capabilities(#?MODULE{}) ->
    #{
        transactions => false,
        read_concurrency => false,
        %% The store *is* the gen_server's state — outside processes
        %% cannot mutate it. Writes must go through the owner.
        concurrent_writes => false,
        %% No seal flow: pages are never rolled into sealed packs, so the
        %% asynchronous-seal surface is a no-op for this backend.
        async_seal => false,
        %% Volatile: the in-process map dies with the gen_server, so a WAL
        %% consumer must replay from the log to rebuild it.
        durable => false,
        %% The map is a plain term: any process holding a handle reads its
        %% own (possibly stale) copy, never a process-bound resource.
        process_bound_reads => false
    }.

-spec close(t()) -> ok.

close(#?MODULE{}) ->
    ok.

-spec flush(t()) -> {ok, t()}.

flush(#?MODULE{} = T) ->
    %% In-memory backend: nothing is staged for durability.
    {ok, T}.

-spec get_root(T :: t()) -> Root :: hash() | undefined.

get_root(#?MODULE{root = Root}) ->
    Root.

-spec set_root(T :: t(), Hash :: hash()) -> t().

set_root(#?MODULE{} = T, Hash) ->
    T#?MODULE{root = Hash}.

-spec get(t(), page()) -> page() | undefined.

get(#?MODULE{pages = Pages}, Hash) ->
    maps:get(Hash, Pages, undefined).

-spec has(t(), page()) -> boolean().

has(#?MODULE{pages = Pages}, Hash) ->
    maps:is_key(Hash, Pages).

-spec put(t(), page()) -> {Hash :: binary(), t()}.

put(#?MODULE{pages = Pages, hashing_algorithm = Algo} = T0, Page) ->
    Hash = bondy_mst_page:hash(Page, Algo),
    T = T0#?MODULE{pages = maps:put(Hash, Page, Pages)},
    {Hash, T}.

-spec delete(t(), hash()) -> t().

delete(#?MODULE{pages = Pages} = T, Hash) ->
    T#?MODULE{pages = maps:remove(Hash, Pages)}.

-spec copy(t(), OtherStore :: bondy_mst_store:t(), Hash :: binary()) -> t().

copy(#?MODULE{} = T0, OtherStore, Hash) ->
    case bondy_mst_store:get(OtherStore, Hash) of
        undefined ->
            T0;
        Page ->
            Refs = bondy_mst_store:page_refs(OtherStore, Page),
            T = lists:foldl(
                fun(Ref, Acc) -> copy(Acc, OtherStore, Ref) end,
                T0,
                Refs
            ),
            T#?MODULE{pages = maps:put(Hash, Page, T#?MODULE.pages)}
    end.

-spec list(t()) -> [page()].

list(#?MODULE{pages = Pages}) ->
    maps:values(Pages).

-spec free(t(), Hash :: binary(), Page :: page()) -> t().

free(#?MODULE{pages = Pages0} = T, Hash, _Page) ->
    Pages = maps:remove(Hash, Pages0),
    T#?MODULE{pages = Pages}.

-spec gc(t(), KeepRoots :: [list()] | epoch()) -> {T :: t(), Metadata :: map()}.

gc(#?MODULE{} = T, Epoch) when is_integer(Epoch) ->
    %% Epoch-based GC not implemented by this store
    {T, #{}};
gc(#?MODULE{pages = Pages0} = T, KeepRoots) when is_list(KeepRoots) ->
    %% Folds the roots we want to keep and create a new map containing only
    %% those roots and its descendants.
    Fun = fun(X, Acc) -> gc_aux(Acc, Pages0, X) end,
    Pages = lists:foldl(Fun, #{}, KeepRoots),
    %% `erts_debug:flat_size/1` reports words; convert to bytes (was
    %% `memory:words/1`, no longer exported by the dep).
    Bytes =
        (erts_debug:flat_size(Pages0) - erts_debug:flat_size(Pages)) *
            erlang:system_info(wordsize),
    Meta = #{
        freed_count => maps:size(Pages0) - maps:size(Pages),
        freed_bytes => Bytes
    },
    {T#?MODULE{pages = Pages}, Meta}.

-spec missing_set(t(), Root :: binary()) -> [Pages :: list()].

missing_set(#?MODULE{pages = Pages} = T, Root) ->
    case maps:get(Root, Pages, undefined) of
        undefined ->
            sets:from_list([Root], [{version, 2}]);
        Page ->
            lists:foldl(
                fun(Hash, Acc) -> sets:union(Acc, missing_set(T, Hash)) end,
                sets:new([{version, 2}]),
                page_refs(Page)
            )
    end.

-spec page_refs(Page :: page()) -> Refs :: [binary()].

page_refs(Page) ->
    bondy_mst_page:refs(Page).

-spec destroy(t()) -> ok.

destroy(#?MODULE{}) ->
    %% In-memory map: nothing to wipe. The map is GC'd with the store
    %% record once the caller drops it.
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% Accumulates in `Acc0` those pages that are decendants of Root.
%% Cycle Prevention: ensures that each page is processed only once by
%% checking if Root is already in the accumulator (`not is_map_key/2` guard).
gc_aux(Acc0, FromPages, Root) when
    is_map(Acc0) andalso not is_map_key(Root, Acc0)
->
    case maps:get(Root, FromPages, undefined) of
        undefined ->
            Acc0;
        Page ->
            case maps:is_key(Root, Acc0) of
                true ->
                    Acc0;
                false ->
                    Acc = maps:put(Root, Page, Acc0),
                    lists:foldl(
                        fun(X, IAcc) -> gc_aux(IAcc, FromPages, X) end,
                        Acc,
                        page_refs(Page)
                    )
            end
    end;
gc_aux(Acc, _, _) ->
    Acc.
