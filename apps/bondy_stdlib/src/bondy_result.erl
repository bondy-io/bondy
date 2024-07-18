%% =============================================================================
%%  bondy_result.erl -
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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

%% -----------------------------------------------------------------------------
%% @doc Result represents the result of something that may succeed or not.
%% `{ok, any()}` means it was successful, `{error, any()}` means it was not.
%%
%% Borrowed from the elegant [homonimous Gleam module]
%% (https://hexdocs.pm/gleam_stdlib/gleam/result.html).
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_result).


-type t()       ::  ok | ok() | error().
-type ok()      ::  ok(any()).
-type error()   ::  error(any()).
-type ok(T)     ::  {ok, T}.
-type error(T)  ::  {error, T}.


-export([all/1]).
-export([error/1]).
-export([flatten/1]).
-export([is_error/1]).
-export([is_ok/1]).
-export([lazy_or/2]).
-export([lazy_unwrap/2]).
-export([map/2]).
-export([map_error/2]).
-export([ok/1]).
-export([or_else/2]).
-export([partition/1]).
-export([replace/2]).
-export([replace_error/2]).
-export([then/2]).
-export([then_recover/2]).
-export([then_both/3]).
-export(['try'/2]).
-export([try_recover/2]).
-export([try_both/3]).
-export([undefined_error/1]).
-export([unwrap/2]).
-export([unwrap_both/1]).
-export([unwrap_error/2]).
-export([values/1]).



-compile({no_auto_import, [error/1]}).


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec ok(Value :: any()) -> ok().

ok(Value) ->
    {ok, Value}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec error(Error :: any()) -> error().

error(Error) ->
    {error, Error}.


%% -----------------------------------------------------------------------------
%% @doc Combines a list of results into a single result.
%% If all elements in the list are `ok` then returns an `ok` holding the list of
%% values. If any element is `errore then returns the first `error`.
%% @end
%% -----------------------------------------------------------------------------
-spec all([t()]) -> t().

all(Results) when is_list(Results) ->
    try
        Values = lists:foldl(
            fun
                ({ok, Value}, Acc) ->
                    [Value | Acc];
                ({error, _} = Result, _) ->
                    throw(Result)
            end,
            [],
            Results
        ),
        {ok, lists:reverse(Values)}

    catch
        throw:{error, _} = Result ->
            Result
    end.


%% -----------------------------------------------------------------------------
%% @doc Merges a nested result into a single layer.
%% @end
%% -----------------------------------------------------------------------------
-spec flatten(t()) -> t().

flatten({ok, {ok, _} = Result}) ->
    flatten(Result);

flatten({ok, {error, _} = Result}) ->
    flatten(Result);

flatten({error, {error, _} = Result}) ->
    flatten(Result);

flatten({ok, _} = Result) ->
    Result;

flatten({error, _} = Result) ->
    Result.


%% -----------------------------------------------------------------------------
%% @doc Checks whether the result is an `error` value.
%% @end
%% -----------------------------------------------------------------------------
-spec is_error(t()) -> boolean().

is_error(ok) -> false;
is_error({ok, _}) -> false;
is_error({error, _}) -> true.


%% -----------------------------------------------------------------------------
%% @doc Checks whether the result is an `ok` value.
%% @end
%% -----------------------------------------------------------------------------
-spec is_ok(t()) -> boolean().

is_ok(ok) -> true;
is_ok({ok, _}) -> true;
is_ok({error, _}) -> false.


%% -----------------------------------------------------------------------------
%% @doc Returns the first value if it is `ok`, otherwise evaluates the given
%% function for a fallback value.
%% @end
%% -----------------------------------------------------------------------------
-spec lazy_or(Result :: t(), Fun :: fun(() -> t())) -> t().

lazy_or(ok = Result, Fun) when is_function(Fun, 0) ->
    Result;

lazy_or({ok, _} = Result, Fun) when is_function(Fun, 0) ->
    Result;

lazy_or({error, _}, Fun) when is_function(Fun, 0) ->
    Fun().


%% -----------------------------------------------------------------------------
%% @doc Extracts the `ok` value from a result, evaluating the default function
%% if the result is an `error`.
%% @end
%% -----------------------------------------------------------------------------
-spec lazy_unwrap(Result :: t(), Fun :: fun(() -> t())) -> any().

lazy_unwrap(ok, Fun) when is_function(Fun, 0) ->
    undefined;
lazy_unwrap({ok, Value}, Fun) when is_function(Fun, 0) ->
    Value;
lazy_unwrap({error, _}, Fun) when is_function(Fun, 0) ->
    Fun().


%% -----------------------------------------------------------------------------
%% @doc Updates a value held within the `ok` of a result by calling a given
%% function on it.
%% If the result is an `error` rather than `ok` the function is not called and
%% the result stays the same.
%% @end
%% -----------------------------------------------------------------------------

-spec map(Result :: t(), fun((any()) -> any())) -> error() | any().

map(ok, Fun) when is_function(Fun, 1) ->
    {ok, Fun(undefined)};

map({ok, Value}, Fun) when is_function(Fun, 1) ->
    {ok, Fun(Value)};

map({error, _} = Result, Fun) when is_function(Fun, 1) ->
    Result.


%% -----------------------------------------------------------------------------
%% @doc Updates a value held within the `error` of a result by calling a given
%% function on it.
%% If the result is `ok`rather than `error` the function is not called and the
%% result stays the same.
%% @end
%% -----------------------------------------------------------------------------

-spec map_error(Result :: t(), fun((any()) -> any())) -> error() | any().

map_error(ok = Result, Fun) when is_function(Fun, 1) ->
    Result;

map_error({ok, _} = Result, Fun) when is_function(Fun, 1) ->
    Result;

map_error({error, Error}, Fun) when is_function(Fun, 1) ->
    {error, Fun(Error)}.


%% -----------------------------------------------------------------------------
%% @doc Transforms any error into `error(undefined)`.
%% @end
%% -----------------------------------------------------------------------------

-spec undefined_error(Result :: t()) -> ok() | error(undefined).

undefined_error(ok = Result) ->
    Result;

undefined_error({ok, _} = Result) ->
    Result;

undefined_error({error, _}) ->
    error(undefined).


%% -----------------------------------------------------------------------------
%% @doc Returns the first value if it is `ok`, otherwise returns the second
%% value.
%% @end
%% -----------------------------------------------------------------------------
-spec or_else(First :: t(), Second :: t()) -> t().

or_else(ok = Result, _) -> Result;
or_else(_, ok = Result) -> Result;
or_else({ok, _} = Result, _) -> Result;
or_else(_, {ok, _} = Result) -> Result;
or_else(_, {error, _} = Result) -> Result.


%% -----------------------------------------------------------------------------
%% @doc Given a list of results, returns a pair where the first element is a
%% list of all the values inside `ok` and the second element is a list with all
%% the values inside `error`.
%%  The values in both lists appear in reverse order with respect to their
%%  position in the original list of results.
%% @end
%% -----------------------------------------------------------------------------
-spec partition(Results :: [t()]) -> {[any()], [any()]} | no_return().

partition(Results) ->
    lists:foldl(
        fun
            (ok, Acc) ->
                Acc;

            ({ok, Value}, {Values, Errors}) ->
                {[Value | Values], Errors};

            ({error, Error}, {Values, Errors}) ->
                {Values, [Error | Errors]};

            (_, _) ->
                error(badarg)
        end,
        {[], []},
        Results
    ).


%% -----------------------------------------------------------------------------
%% @doc Replace the value within a result.
%% @end
%% -----------------------------------------------------------------------------
-spec replace(Result :: t(), Value :: any()) -> t().

replace(ok, Value) -> {ok, Value};
replace({ok, _}, Value) -> {ok, Value};
replace({error, _} = Result, _) -> Result.


%% -----------------------------------------------------------------------------
%% @doc Replace the error within a result
%% @end
%% -----------------------------------------------------------------------------
-spec replace_error(Result :: t(), Error :: any()) -> t().

replace_error(ok = Result, _) -> Result;
replace_error({ok, _} = Result, _) -> Result;
replace_error({error, _}, Error) -> {error, Error}.



%% -----------------------------------------------------------------------------
%% @doc An alias for `try/2`.
%% @end
%% -----------------------------------------------------------------------------
-spec then(Result :: t(), Fun :: fun((any()) -> t())) -> t() | no_return().

then(Result, Fun) -> 'try'(Result, Fun).

%% -----------------------------------------------------------------------------
%% @doc An alias for `try_recover/2`.
%% @end
%% -----------------------------------------------------------------------------
-spec then_recover(Result :: t(), Fun :: fun((any()) -> t())) ->
    t() | no_return().

then_recover(Result, Fun) -> try_recover(Result, Fun).

%% -----------------------------------------------------------------------------
%% @doc An alias for `try_both/3`.
%% @end
%% -----------------------------------------------------------------------------
-spec then_both(
    Result :: t(),
    Fun :: fun((any()) -> t()),
    Fun :: fun((any()) -> t())) -> t() | no_return().

then_both(Result, Fun, RecoverFun) -> try_both(Result, Fun, RecoverFun).


%% -----------------------------------------------------------------------------
%% @doc “Updates” an `ok` result by passing its value to a function that yields
%% \a result, and returning the yielded result. (This may “replace” the `ok`
%%  with an `error`).
%%
%%  If the input is an `error` rather than an `ok`, the function is not called
%%  and the original `error` is returned.
%%
%%  This function is the equivalent of calling `map/2` followed by `flatten/1`,
%%  and it is useful for chaining together multiple functions that may fail.
%% @end
%% -----------------------------------------------------------------------------
-spec 'try'(Result :: t(), Fun :: fun((any()) -> t())) -> t() | no_return().

'try'(ok = Result, Fun) when is_function(Fun, 1) ->
    eval_result(Result, Fun);

'try'({ok, _} = Result, Fun) when is_function(Fun, 1) ->
    eval_result(Result, Fun);

'try'({error, _} = Result, Fun) when is_function(Fun, 1) ->
    Result.


%% -----------------------------------------------------------------------------
%% @doc Updates a value held within the Error of a result by calling a given
%% function on it, where the given function also returns a result. The two
%% results are then merged together into one result.
%%
%% If the result is an Ok rather than Error the function is not called and the
%% result stays the same.
%%
%% This function is useful for chaining together computations that may fail and
%% trying to recover from possible errors.
%% @end
%% -----------------------------------------------------------------------------
-spec try_recover(Result :: t(), Fun :: fun((any()) -> t())) ->
    t() | no_return().

try_recover(ok = Result, Fun) when is_function(Fun, 1) ->
    Result;

try_recover({ok, _} = Result, Fun) when is_function(Fun, 1) ->
    Result;

try_recover({error, _} = Result, Fun) when is_function(Fun, 1) ->
    eval_result(Result, Fun).

%% -----------------------------------------------------------------------------
%% @doc Updates an `ok' result by passing its value to a `fun' that yields
%% a result, and returning the yielded result. If the input is an `error' rather
%% than an `ok', updates a value held within the `error` of a result by calling
%% `recover_fun' on it, where the given function also returns a result.
%% @end
%% -----------------------------------------------------------------------------
-spec try_both(
    Result :: t(),
    Fun :: fun((any()) -> t()),
    Fun :: fun((any()) -> t())) -> t() | no_return().

try_both(ok = Result, Fun, _) ->
    'try'(Result, Fun);

try_both({ok, _} = Result, Fun, _) ->
    'try'(Result, Fun);

try_both({error, _} = Result, _, RecoverFun) ->
    try_recover(Result, RecoverFun).



%% -----------------------------------------------------------------------------
%% @doc Extracts the Ok value from a result, returning a default value if the
%% result is an Error.
%% @end
%% -----------------------------------------------------------------------------
-spec unwrap(Result :: t(), Default :: any()) -> any().

unwrap(ok, _) -> undefined;
unwrap({ok, Value}, _) -> Value;
unwrap({error, _}, Default) -> Default.


%% -----------------------------------------------------------------------------
%% @doc Extracts the inner value from a result.
%% @end
%% -----------------------------------------------------------------------------
-spec unwrap_both(Result :: t()) -> any().

unwrap_both(ok) -> undefined;
unwrap_both({ok, Value}) -> Value;
unwrap_both({error, Error}) -> Error.



%% -----------------------------------------------------------------------------
%% @doc Extracts the Error value from a result, returning a default value if the
%% result is an Ok.
%% @end
%% -----------------------------------------------------------------------------
-spec unwrap_error(Result :: t(), Default :: any()) -> any().

unwrap_error(ok, Default) -> Default;
unwrap_error({ok, _}, Default) -> Default;
unwrap_error({error, Error}, _) -> Error.


%% -----------------------------------------------------------------------------
%% @doc Given a list of results, returns only the values inside Ok.
%% @end
%% -----------------------------------------------------------------------------
-spec values(Results :: [t()]) -> [any()].

values(Results) ->
    lists:filtermap(
        fun
            ({ok, Value}) -> {true, Value};
            (_) -> false
        end,
        Results
    ).



%% =============================================================================
%% PRIVATE
%% =============================================================================


eval_result(Result0, Fun) when is_function(Fun, 0) ->
    case Fun() of
        ok = Result ->
            Result;
        {ok, _} = Result ->
            Result;
        {error, _} = Result ->
            Result;
        _ ->
            not_a_result([Result0, Fun], 2)
    end;

eval_result(Result0, Fun) when is_function(Fun, 1) ->
    case Fun(element(2, Result0)) of
        ok = Result ->
            Result;
        {ok, _} = Result ->
            Result;
        {error, _} = Result ->
            Result;
        _ ->
            not_a_result([Result0, Fun], 2)
    end.


not_a_result(Args, Pos) ->
    erlang:error(
        badarg,
        Args,
        [
            {error_info, #{
                module => ?MODULE,
                cause => #{
                    Pos => "Function should return a 'bondy_result:t()'."
                },
                meta => #{}
            }}
        ]
    ).




%% =============================================================================
%% EUNIT
%% =============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    [
        ?_assertEqual(ok([1, 2]), all([ok(1), ok(2)])),
        ?_assertEqual(error(foo), all([ok(1), ok(2), error(foo)])),
        ?_assertEqual(error(foo), all([ok(1), ok(2), error(foo), error(bar)])),
        ?_assertEqual(error(foo), all([error(foo), error(bar)])),

        ?_assertError(function_clause, all([foo]))
    ].


flatten_test_() ->
    [
        ?_assertEqual(ok(foo), flatten(ok(ok(foo)))),
        ?_assertEqual(ok(foo), flatten(ok(ok(ok(ok(foo)))))),
        ?_assertEqual(error(foo), flatten(error(error(foo)))),
        ?_assertEqual(error(foo), flatten(error(error(error(error(foo)))))),
        ?_assertEqual(error(foo), flatten(ok(error(foo)))),

        ?_assertError(function_clause, flatten(foo))
    ].


typecheck_test_() ->
    [
        ?_assert(is_ok(ok(foo))),
        ?_assertEqual(false, is_ok(error(foo))),
        ?_assert(is_error(error(foo))),
        ?_assertEqual(false, is_error(ok(foo))),

        ?_assertError(function_clause, is_ok(foo)),
        ?_assertError(function_clause, is_error(foo))
    ].


lazy_or_test_() ->
    [
        ?_assertEqual(ok(1), lazy_or(ok(1), fun() -> ok(2) end)),
        ?_assertEqual(ok(1), lazy_or(ok(1), fun() -> error(foo) end)),
        ?_assertEqual(ok(1), lazy_or(error(foo), fun() -> ok(1) end)),
        ?_assertEqual(error(bar), lazy_or(error(foo), fun() -> error(bar) end)),
        ?_assertEqual(ok(1), lazy_or(ok(1), fun() -> not_a_result end)),

        ?_assertError(badarg, lazy_or(error(foo), fun() -> not_a_result end)),
        ?_assertError(function_clause, lazy_or(ok(1), not_a_fun)),
        ?_assertError(function_clause, lazy_or(error(foo), not_a_fun))
    ].


lazy_unwrap_test_() ->
    [
        ?_assertEqual(1, lazy_unwrap(ok(1), fun() -> 2 end)),
        ?_assertEqual(2, lazy_unwrap(error(foo), fun() -> 2 end)),
        ?_assertError(function_clause, lazy_unwrap(ok(1), not_a_fun)),
        ?_assertError(function_clause, lazy_unwrap(error(foo), not_a_fun))
    ].

map_test_() ->
    [
        ?_assertEqual(ok(2), map(ok(1), fun(X) -> X + 1 end)),
        ?_assertEqual(error(foo), map(error(foo), fun(X) -> X + 1 end)),
        ?_assertError(function_clause, map(ok(1), not_a_fun)),
        ?_assertError(function_clause, map(error(foo), not_a_fun))
    ].

undefined_error_test_() ->
    [
        ?_assertEqual(ok(1), undefined_error(ok(1))),
        ?_assertEqual(error(undefined), undefined_error(error(foo)))
    ].


or_test_() ->
    [
        ?_assertEqual(ok(1), or_else(ok(1), ok(2))),
        ?_assertEqual(ok(1), or_else(ok(1), error(foo))),
        ?_assertEqual(ok(2), or_else(error(foo), ok(2))),
        ?_assertEqual(error(bar), or_else(error(foo), error(bar)))
    ].


partition_test_() ->
    [
        ?_assertEqual(
            {[2, 1], [bar, foo]},
            partition([ok(1), error(foo), ok(2), error(bar)])
        )
    ].


replace_test_() ->
    [
        ?_assertEqual(ok(2), replace(ok(1), 2)),
        ?_assertEqual(error(foo), replace(error(foo), 2))
    ].

replace_error_test_() ->
    [
        ?_assertEqual(ok(1), replace_error(ok(1), bar)),
        ?_assertEqual(error(bar), replace_error(error(foo), bar))
    ].


then_try_test_() ->
    [
        ?_assertEqual(ok(2), then(ok(1), fun(X) -> ok(X + 1) end)),
        ?_assertEqual(ok(2), 'try'(ok(1), fun(X) -> ok(X + 1) end)),
        ?_assertEqual(error("Oh no"), then(ok(1), fun(_) -> error("Oh no") end)),
        ?_assertEqual(error("Oh no"), 'try'(ok(1), fun(_) -> error("Oh no") end))
    ].

try_recover_test_() ->
    [

        ?_assertEqual(ok(1), try_recover(ok(1), fun(_) -> error("Oh no") end)),
        ?_assertEqual(ok(2), try_recover(error(1), fun(X) -> ok(X + 1) end)),
        ?_assertEqual(
            error("Oh no"), try_recover(error(1), fun(_) -> error("Oh no") end)
        )
    ].

unwrap_test_() ->
    [
        ?_assertEqual(1, unwrap(ok(1), 2)),
        ?_assertEqual(2, unwrap(error(1), 2))
    ].


unwrap_both_test_() ->
    [
        ?_assertEqual(1, unwrap_both(ok(1))),
        ?_assertEqual(1, unwrap_both(error(1)))
    ].


unwrap_error_test_() ->
    [
        ?_assertEqual(2, unwrap_error(ok(1), 2)),
        ?_assertEqual(1, unwrap_error(error(1), 2))
    ].


values_test_() ->
    [
        ?_assertEqual([1, 2], values([ok(1), ok(2), error(foo)])),
        ?_assertEqual([], values([error(foo)]))
    ].

-endif.













