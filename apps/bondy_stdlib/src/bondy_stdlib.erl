-module(bondy_stdlib).

-include("bondy_stdlib.hrl").

-export([or_else/2]).
-export([lazy_or_else/2]).



%% =============================================================================
%% API
%% =============================================================================



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