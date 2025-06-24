%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_stdlib).

-include("bondy_stdlib.hrl").

-export([and_then/2]).
-export([or_else/2]).
-export([lazy_or_else/2]).



%% =============================================================================
%% API
%% =============================================================================



?DOC("""
If `Value` is the atom `undefined`, return `undefined`, otherwise apply `Fun` to
`Value`.

Conceptually the dual of `or_else/2`:
* `or_else/2`  – provide an *alternative* when the value is missing.
* `and_then/2` – continue the computation when the value is present.
""").
-spec and_then(optional(T), fun((T) -> R)) -> optional(R).

and_then(undefined, _Fun) ->
    undefined;

and_then(Value, Fun) when is_function(Fun, 1) ->
    Fun(Value).


?DOC("""
Returns the first argument if it is not the atom `undefined`, otherwise the second.
""").
-spec or_else(optional(any()), any()) -> any().

or_else(undefined, Default) ->
    Default;

or_else(Value, _) ->
    Value.


?DOC("""
Returns the first argument if it is not the atom `undefined`, otherwise calls the second argument.
""").
-spec lazy_or_else(optional(any()), function()) -> any().

lazy_or_else(undefined, Fun) when is_function(Fun, 0) ->
    Fun();

lazy_or_else(Value, _) ->
    Value.

