%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_page).

-include("bondy_mst.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Module that represents objects that are used as data pages in a
pagestore and that may reference other data pages by their hash.
""").

-record(?MODULE, {
    level :: level(),
    low :: hash() | undefined,
    list :: [entry()],
    freed_at :: epoch() | undefined
}).

-type t() :: #?MODULE{}.
-type entry() :: {key(), value(), hash() | undefined}.

-export_type([t/0]).
-export_type([entry/0]).

%% Defined in bondy_mst.hrl
-export_type([level/0]).
-export_type([key/0]).
-export_type([value/0]).
-export_type([hash/0]).

-export([field_index/1]).
-export([fold/3]).
-export([foreach/2]).
-export([freed_at/1]).
-export([hash/2]).
-export([is_referenced_at/2]).
-export([is_type/1]).
-export([level/1]).
-export([list/1]).
-export([low/1]).
-export([new/3]).
-export([pattern/0]).
-export([refs/1]).
-export([set_freed_at/2]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Creates a new page
""").
-spec new(level(), hash() | undefined, [entry()]) -> t().

new(Level, Low, List) when is_integer(Level), is_list(List) ->
    #?MODULE{
        level = Level,
        low = Low,
        list = List,
        freed_at = undefined
    }.

?DOC("""
Creates a new page
""").
-spec pattern() -> t().

pattern() ->
    {
        ?MODULE,
        % level
        '_',
        % low
        '_',
        % list
        '_',
        % freed_at
        '_'
    }.

?DOC("""
Returns true if `Arg` is a page.
""").
-spec is_type(Arg :: any()) -> boolean().

is_type(#?MODULE{}) -> true;
is_type(_) -> false.

-spec field_index(atom()) -> pos_integer().

field_index(level) -> #?MODULE.level;
field_index(low) -> #?MODULE.low;
field_index(list) -> #?MODULE.list;
field_index(freed_at) -> #?MODULE.freed_at.

?DOC("""
Returns the level of this page in the tree i.e. the logical height.
""").
-spec level(t()) -> level().

level(#?MODULE{level = Val}) -> Val.

-spec low(t()) -> hash().

low(#?MODULE{low = Val}) -> Val.

?DOC("""
Returns the epoch number at which this page has been freed or
`undefined` if it hasn't i.e. it is still active.
""").
-spec freed_at(t()) -> epoch() | undefined.

freed_at(#?MODULE{freed_at = Val}) -> Val.

?DOC("""
Sets the version number at which this page has been freed.
""").
-spec set_freed_at(t(), epoch()) -> t().

set_freed_at(#?MODULE{} = T, Epoch) when is_integer(Epoch) ->
    T#?MODULE{freed_at = Epoch}.

?DOC("""
Returns `true` if the page is referenced at `Epoch`.
Otherwise, returns `false`.
""").
-spec is_referenced_at(t(), epoch()) -> boolean().

is_referenced_at(#?MODULE{freed_at = undefined}, _) ->
    true;
is_referenced_at(#?MODULE{freed_at = LastEpoch}, Epoch) ->
    LastEpoch >= Epoch.

?DOC("""
Computes the hash of the page using algorithm `Algo`.
This function must be used to obtain a hash as it ignores certain fields that
will diverge between replicas and are used for operational and/or efficiency
purposes.
""").
hash(#?MODULE{} = T, Algo) when is_atom(Algo) ->
    #?MODULE{level = Level, low = Low, list = List} = T,
    %% Notice we are not including any metadata which would be local to this
    %% tree replica.
    bondy_mst_utils:hash({Level, Low, List}, Algo).

?DOC("""
Returns the list of entries in this page.
""").
-spec list(t()) -> [entry()].

list(#?MODULE{list = Val}) -> Val.

?DOC("""
Calls `Fun(Entry, AccIn)` on successive entries of the page, starting
with `AccIn == Acc0`. `Fun/2` must return a new accumulator, which is passed
to the next call. The function returns the final value of the accumulator.
`Acc0` is returned if the tree is empty.
""").
-spec fold(t(), fun((entry(), any()) -> any()), any()) -> any().

fold(#?MODULE{list = List}, Fun, Acc) ->
    lists:foldl(Fun, Acc, List).

-spec foreach(t(), fun((entry()) -> any())) -> ok.

foreach(#?MODULE{list = List}, Fun) ->
    lists:foreach(Fun, List).

?DOC("""
Returns the hashes of all pages referenced by this page.
""").
-spec refs(t()) -> [hash()].

refs(#?MODULE{list = List, low = Low}) ->
    Refs = [H || {_, _, H} <- List, H =/= undefined],

    case Low =/= undefined of
        true ->
            [Low | Refs];
        false ->
            Refs
    end.
