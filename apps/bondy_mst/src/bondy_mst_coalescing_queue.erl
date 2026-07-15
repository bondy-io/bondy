%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_coalescing_queue).

-feature(maybe_expr, enable).

-record(?MODULE, {
    map = #{} :: map(),
    queue = queue:new() :: queue:queue(key())
}).

-type t() :: #?MODULE{}.
-type key() :: any().

-export_type([t/0]).

-export([delete/2]).
-export([filter/2]).
-export([in/3]).
-export([new/0]).
-export([out/1]).
-export([out_when/2]).
-export([peek/1]).
-export([size/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec new() -> t().

new() ->
    #?MODULE{}.

-spec size(t()) -> non_neg_integer().

size(#?MODULE{map = M}) ->
    maps:size(M).

-spec in(t(), key(), any()) -> t().

in(#?MODULE{} = T, Key, Elem) ->
    case maps:get(Key, T#?MODULE.map, undefined) of
        undefined ->
            T#?MODULE{
                map = maps:put(Key, Elem, T#?MODULE.map),
                queue = queue:in(Key, T#?MODULE.queue)
            };
        _ ->
            T#?MODULE{
                map = maps:put(Key, Elem, T#?MODULE.map)
            }
    end.

-spec out(t()) -> {{value, any()}, t()} | {empty, t()}.

out(#?MODULE{} = T) ->
    case queue:out(T#?MODULE.queue) of
        {{value, Key}, Q} ->
            {Elem, Map} = maps:take(Key, T#?MODULE.map),
            {{value, Elem}, T#?MODULE{map = Map, queue = Q}};
        {empty, _} = Result ->
            Result
    end.

-spec out_when(t(), fun((Elem :: any()) -> boolean())) ->
    {value, any()} | empty.

out_when(#?MODULE{} = T, Pred) when is_function(Pred, 1) ->
    maybe
        {value, K} ?= queue:peek(T#?MODULE.queue),
        V = maps:get(K, T#?MODULE.map),
        true ?= Pred(V),
        {_, Q} ?= queue:out(T#?MODULE.queue),
        M = maps:remove(K, T#?MODULE.map),
        {{value, V}, T#?MODULE{map = M, queue = Q}}
    else
        empty ->
            {empty, T};
        false ->
            {empty, T}
    end.

-spec peek(t()) -> {value, any()} | empty.

peek(#?MODULE{} = T) ->
    case queue:peek(T#?MODULE.queue) of
        {value, Key} ->
            {value, maps:get(Key, T#?MODULE.map)};
        empty ->
            empty
    end.

-spec delete(t(), key()) -> t().

delete(#?MODULE{} = T, Key) ->
    case maps:get(Key, T#?MODULE.map, undefined) of
        undefined ->
            T;
        _ ->
            T#?MODULE{
                map = maps:remove(Key, T#?MODULE.map),
                queue = queue:delete(Key, T#?MODULE.queue)
            }
    end.

-spec filter
    (t(), fun((key()) -> boolean())) -> t();
    (t(), fun((key(), any()) -> boolean())) -> t().

filter(#?MODULE{} = T, Fun) when is_function(Fun, 1) ->
    T#?MODULE{
        map = maps:filter(fun(K, _) -> Fun(K) end, T#?MODULE.map),
        queue = queue:filter(Fun, T#?MODULE.queue)
    };
filter(#?MODULE{} = T, Fun) when is_function(Fun, 2) ->
    {Map, Queue} =
        maps:fold(
            fun(K, V, {M, Q}) ->
                case Fun(K, V) of
                    true ->
                        {maps:put(K, V, M), Q};
                    false ->
                        {M, queue:delete(Q, V)}
                end
            end,
            {#{}, T#?MODULE.queue},
            T#?MODULE.map
        ),

    T#?MODULE{
        map = Map,
        queue = Queue
    }.
