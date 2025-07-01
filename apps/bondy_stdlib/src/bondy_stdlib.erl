%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_stdlib).

-include("bondy_stdlib.hrl").

%% Retry defaults
-define(DEFAULT_RETRY_OPTS, #{
        max_retries => 3,
        base_delay => 100,
        max_delay => 5000,
        mode => jitter
}).

-type retry_opts()  :: #{
                            max_retries => pos_integer() | infinity,
                            base_delay => pos_integer(),
                            max_delay => pos_integer(),
                            mode => normal | jitter
                        }.

-export_type([retry_opts/0]).


-export([and_then/2]).
-export([lazy_or_else/2]).
-export([or_else/2]).
-export([retry/1]).
-export([retry/2]).

-export([increment/1]).
-export([increment/2]).
-export([rand_increment/1]).
-export([rand_increment/2]).



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



?DOC("""
Increment an integer exponentially
""").
-spec increment(pos_integer()) -> pos_integer().

increment(N) when is_integer(N) ->
    N bsl 1.


?DOC("""
Increment an integer exponentially within a range.
""").
-spec increment(N :: pos_integer(), Max :: pos_integer()) -> pos_integer().

increment(N, Max) ->
    min(increment(N), Max).

?DOC("""
Increment an integer exponentially with randomness or jitter.-behaviour(behaviour).
Chooses a delay uniformly from `[0.5 * Time, 1.5 * Time]' as recommended in:
[Sally Floyd and Van Jacobson, The Synchronization of Periodic Routing Messages,
April 1994 IEEE/ACM Transactions on Networking](http://ee.lbl.gov/papers/sync_94.pdf).
Implementation borrowed from Hex package [backoff](https://hex.pm/packages/backoff) (MIT Licence, Copyright (c) 2013 Heroku <mononcqc@ferd.ca>).
""").
-spec rand_increment(N :: pos_integer()) -> pos_integer().

rand_increment(N) ->
    %% New delay chosen from [N, 3N], i.e. [0.5 * 2N, 1.5 * 2N]
    Width = N bsl 1,
    N + rand:uniform(Width + 1) - 1.


?DOC("""
Increment an integer exponentially with randomness or jitter within a range.

Chooses a delay uniformly from `[0.5 * Time, 1.5 * Time]' as recommended in:
[Sally Floyd and Van Jacobson, The Synchronization of Periodic Routing Messages,
April 1994 IEEE/ACM Transactions on Networking](http://ee.lbl.gov/papers/sync_94.pdf).
Implementation borrowed from Hex package [backoff](https://hex.pm/packages/backoff) (MIT Licence, Copyright (c) 2013 Heroku <mononcqc@ferd.ca>).
""").
-spec rand_increment(N :: pos_integer(), Max :: pos_integer()) -> pos_integer().

rand_increment(N, Max) ->
    %% The largest interval for [0.5 * Time, 1.5 * Time] with maximum Max is
    %% [Max div 3, Max].
    MaxMinDelay = Max div 3,

    if
        MaxMinDelay =:= 0 ->
            rand:uniform(Max);

        N > MaxMinDelay ->
            rand_increment(MaxMinDelay);

        true ->
            rand_increment(N)
    end.


?DOC("""
Calls retry/2 with the default the follwing default options:

- `max_retries` = 3,
- `base_delay` = 100 i.e. 100 milliseconds
- `max_delay` = 5000 i.e. 5 seconds
- `mode` = jitter
""").
-spec retry(fun(() -> resulto:t())) -> resulto:t().

retry(Fun) ->
    retry(Fun, ?DEFAULT_RETRY_OPTS).


?DOC("""
Retries a function with full control over timing parameters.

Implements exponential backoff with jitter:
- Delay = min(BaseDelay * 2^Attempt, MaxDelay) ± Jitter
- Jitter prevents multiple clients from retrying simultaneously
- Each failure increments the attempt counter

### Success conditions (no retry):
- Function returns `{ok, Result}`
- Function returns `ok` - Success without value
- Function returns a value that is not a result - Success without value

### Retry conditions:
- Function returns `{error, Reason}` - Will retry if attempts remain

### No retry conditions (immediate return):
- Function throws exception - Propagated immediately
- Function calls exit/1 - Propagated immediately
- Maximum retries exceeded - Returns last error or `{error, timeout}`

### Paramters
- `Fun` Function to execute. Should be side-effect free for reliable retries.
@param MaxRetries Maximum number of retry attempts (0 means no retries).
@param BaseDelay Initial delay in milliseconds (must be > 0).
@param MaxDelay Maximum delay cap in milliseconds (must be >= BaseDelay).
@returns {ok, Result} | ok on success, {error, Reason} on final failure.
@example
Retry expensive operation with longer delays
retry:retry(fun() ->
 case expensive_remote_call() of
     {ok, Data} -> {ok, Data};
     timeout -> {error, timeout};
     {error, temporary} -> {error, temporary};
     {error, permanent} -> exit(permanent_failure)
 end
end, 10, 1000, 30000).

Notice this function will not catch exceptions and thus there will be no retries
in that scenario.
""").
-spec retry(fun(() -> resulto:t()), retry_opts()) -> resulto:t().

retry(Fun, Opts) ->
    State = maps:merge(?DEFAULT_RETRY_OPTS, Opts),
    retry_loop(Fun, 0, undefined, State).



%% =============================================================================
%% PRIVATE
%% =============================================================================



retry_loop(Fun, Attempt, _Reason, #{max_retries := MaxRetries} = State0)
when Attempt =< MaxRetries ->
    Result = resulto:then_recover(Fun(), fun
        (Reason) when Attempt =:= MaxRetries ->
            {error, Reason};

        (Reason) ->
            State = incr_delay(State0),
            timer:sleep(maps:get(base_delay, State)),
            retry_loop(Fun, Attempt + 1, Reason, State)
    end),

    %% Ensure we return a result.
    resulto:flatten(resulto:ok(Result));

retry_loop(_, _, Reason, _) ->
    {error, Reason}.


incr_delay(#{mode := normal, max_delay := infinity} = State) ->
    State#{base_delay => increment(maps:get(base_delay, State))};

incr_delay(#{mode := normal, max_delay := Max} = State) ->
    State#{base_delay => increment(maps:get(base_delay, State), Max)};

incr_delay(#{mode := jitter, max_delay := infinity} = State) ->
    State#{base_delay => rand_increment(maps:get(base_delay, State))};

incr_delay(#{mode := jitter, max_delay := Max} = State) ->
    State#{base_delay => rand_increment(maps:get(base_delay, State), Max)}.


