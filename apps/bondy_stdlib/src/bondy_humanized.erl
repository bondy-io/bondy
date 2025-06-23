%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_humanized).

-include("bondy_stdlib.hrl").

-export([join/1]).
-export([join/2]).



%% =============================================================================
%% API
%% =============================================================================


-doc """
Same as calling `join/2` with `~"and"` as `Conjunction`.
""".
-spec join([any()]) -> binary().

join(Items) ->
    join(Items, ~"and").


?DOC("""
Converts a list of items into a human-readable string where each item is
enclosed in single quotes
and the last item is preceded by the conjunction (defaults to "and").

Examples:
```
  > bondy_humanized:join([~"apple", banana, 100], ~"and").
  ~"'apple', 'banana' and '100'"
  > bondy_humanized:join([~"apple"]).
  ~"'apple'"
```
""").
-spec join([any()], Conjunction :: binary()) -> binary().

join([], _) ->
    ~"";

join([Item], _) ->
    iolist_to_binary(quote(Item));

join(Items, Conjunction) when is_list(Items), is_binary(Conjunction) ->
    Quoted = [quote(to_iodata(I)) || I <- Items],
    join(Quoted, Conjunction, []).



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
join([H, T], Conjunction, Acc)  ->
    iolist_to_binary(
        lists:reverse([T, $\s, Conjunction, $\s, H, $\s, $, | Acc])
    );

join([H | T], Conjunction, [] = Acc)  ->
    join(T, Conjunction, [H | Acc]);

join([H | T], Conjunction, Acc)  ->
    join(T, Conjunction, [H, $\s, $, | Acc]).


%% @private
%% Converts any term to bianry and wraps in single quotes
quote(Term) ->
    [$', Term, $'].


%% @private
to_iodata(Term) when is_atom(Term) ->
    atom_to_binary(Term);

to_iodata(Term) when is_integer(Term) ->
    integer_to_binary(Term);

to_iodata(Term) when is_float(Term) ->
    float_to_binary(Term, [{decimals, 16}]);

to_iodata(Term) when is_binary(Term) ->
    Term;

to_iodata(Term) when is_list(Term) ->
    list_to_binary(Term);

to_iodata(Term) ->
    io_lib:format("~p", [Term]).
