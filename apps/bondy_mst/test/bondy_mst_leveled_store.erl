%% =============================================================================
%%  bondy_mst_leveled_store.erl -
%%
%%  Copyright (c) 2023-2025 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

-module(bondy_mst_leveled_store).
-behaviour(bondy_mst_store).

-include_lib("kernel/include/logger.hrl").
-include_lib("leveled/include/leveled.hrl").
-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("Non-concurrent, MST backend using `leveled`.").

-record(?MODULE, {
    pid :: pid(),
    name :: atom() | binary(),
    hashing_algorithm :: atom()
}).

-type t() :: #?MODULE{}.
-type page() :: bondy_mst_page:t().
-type opts() :: #{} | [].

-export_type([t/0]).
-export_type([page/0]).

%% API
-export([capabilities/1]).
-export([close/1]).
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
open(Algo, Opts) when is_atom(Algo), is_map(Opts) ->
    Name = maps:get(name, Opts, undefined),
    Name =/= undefined orelse error(badarg),

    %% TODO at the moment we use a global instance, we should give the option
    %% to create a dedicated instance or have shared store
    Pid = persistent_term:get({bondy_mst, leveled}),
    #?MODULE{
        pid = Pid,
        name = Name,
        hashing_algorithm = Algo
    }.

-spec capabilities(t()) -> map().

capabilities(#?MODULE{}) ->
    #{
        transactions => false,
        read_concurrency => false
    }.

-spec close(t()) -> ok.

close(#?MODULE{}) ->
    %% TODO at the moment we use a global instance, we should give the option
    %% to create a dedicated instance or have shared store
    ok.

-spec get_root(T :: t()) -> Root :: hash() | undefined.

get_root(#?MODULE{pid = Pid, name = Name}) ->
    do_get(Pid, Name, ?ROOT_KEY).

-spec set_root(T :: t(), Hash :: hash()) -> t().

set_root(#?MODULE{pid = Pid, name = Name} = T, Hash) ->
    ok = leveled_bookie:book_put(Pid, Name, ?ROOT_KEY, Hash, []),
    T.

-spec get(T :: t(), Hash :: binary()) -> Page :: page() | undefined.

get(#?MODULE{pid = Pid, name = Name}, Hash) ->
    do_get(Pid, Name, Hash).

-spec has(T :: t(), Hash :: binary()) -> boolean().

has(#?MODULE{pid = Pid, name = Name}, Hash) ->
    leveled_bookie:book_head(Pid, Name, Hash) /= not_found.

-spec put(T :: t(), Page :: page()) -> {Hash :: binary(), T :: t()}.

put(#?MODULE{pid = Pid, name = Name, hashing_algorithm = Algo} = T, Page) ->
    Hash = bondy_mst_page:hash(Page, Algo),
    ok = leveled_bookie:book_put(Pid, Name, Hash, Page, []),
    {Hash, T}.

-spec delete(T :: t(), Hash :: binary()) -> T :: t().

delete(#?MODULE{pid = Pid, name = Name} = T, Hash) ->
    ok = leveled_bookie:book_delete(Pid, Name, Hash, []),
    T.

-spec copy(t(), OtherStore :: bondy_mst_store:t(), Hash :: binary()) -> t().

copy(#?MODULE{pid = Pid, name = Name} = T, OtherStore, Hash) ->
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
            ok = leveled_bookie:book_put(Pid, Name, Hash, Page, []),
            T
    end.

-spec list(t()) -> [page()].

list(#?MODULE{}) ->
    %% TODO
    [].

-spec free(T :: t(), Hash :: binary(), Page :: page()) -> T :: t().

free(#?MODULE{pid = Pid, name = Name} = T, Hash, _Page) ->
    %% We immediately delete
    ok = leveled_bookie:book_delete(Pid, Name, Hash, []),
    T.

-spec gc(T :: t(), KeepRoots :: [list()] | epoch()) ->
    {T :: t(), Metadata :: map()}.

gc(#?MODULE{} = T, _) ->
    %% Do nothing, we free instead
    {T, #{}}.

-spec missing_set(T :: t(), Root :: binary()) -> sets:set(page()).

missing_set(T, Root) ->
    case get(T, Root) of
        undefined ->
            sets:from_list([Root], [{version, 2}]);
        Page ->
            lists:foldl(
                fun(P, Acc) -> sets:union(Acc, missing_set(T, P)) end,
                sets:new([{version, 2}]),
                page_refs(Page)
            )
    end.

-spec page_refs(Page :: page()) -> [binary()].

page_refs(Page) ->
    bondy_mst_page:refs(Page).

-spec destroy(t()) -> ok.

destroy(#?MODULE{pid = _Pid, name = _Name}) ->
    %% TODO fold over bucket (name) elements and delete them
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_get(Pid, Name, Hash) when is_binary(Hash) orelse Hash =:= ?ROOT_KEY ->
    case leveled_bookie:book_get(Pid, Name, Hash) of
        {ok, Page} ->
            Page;
        not_found ->
            undefined
    end.
