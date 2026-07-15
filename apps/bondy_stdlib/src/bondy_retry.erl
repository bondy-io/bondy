%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_retry).
-moduledoc """
Retry state with optional exponential backoff and an overall deadline.

A `t/0` value tracks an attempt counter, a per-attempt interval (or a `m:backoff`
curve when backoff is enabled) and a deadline. `fail/1` advances the state after
a failed attempt, returning the next delay — or `deadline` / `max_retries` once
the budget is exhausted; `succeed/1` resets it.
""".

-record(bondy_retry, {
    id :: any(),
    deadline :: non_neg_integer(),
    max_retries = 0 :: non_neg_integer(),
    interval :: pos_integer(),
    count = 0 :: non_neg_integer(),
    backoff :: backoff:backoff() | undefined,
    start_ts :: pos_integer() | undefined
}).

-type t() :: #bondy_retry{}.
-type opt() ::
    {deadline, non_neg_integer()}
    | {max_retries, non_neg_integer()}
    | {interval, pos_integer()}
    | {backoff_enabled, boolean()}
    | {backoff_min, pos_integer()}
    | {backoff_max, pos_integer()}
    | {backoff_type, jitter | normal}.
-type opts_map() :: #{
    deadline => non_neg_integer(),
    max_retries => non_neg_integer(),
    interval => pos_integer(),
    backoff_enabled => boolean(),
    backoff_min => pos_integer(),
    backoff_max => pos_integer(),
    backoff_type => jitter | normal
}.
-type opts() :: [opt()] | opts_map().

-export_type([t/0]).
-export_type([opts/0]).

-export([init/2]).
-export([fail/1]).
-export([succeed/1]).
-export([get/1]).
-export([fire/1]).
-export([count/1]).

-compile({no_auto_import, [get/1]}).

-eqwalizer({nowarn_function, init/2}).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Set `deadline` to zero to disable the deadline and rely on `max_retries` only.
""".
-spec init(Id :: any(), Opts :: opts()) -> t().

init(Id, Opts) ->
    State0 = #bondy_retry{
        id = Id,
        max_retries = key_value:get(max_retries, Opts, 10),
        deadline = key_value:get(deadline, Opts, 30000),
        interval = key_value:get(interval, Opts, 3000)
    },

    case key_value:get(backoff_enabled, Opts, false) of
        true ->
            Min = key_value:get(backoff_min, Opts, 10),
            Max = key_value:get(backoff_max, Opts, 120000),
            Type = key_value:get(backoff_type, Opts, jitter),
            Backoff = backoff:type(backoff:init(Min, Max), Type),
            State0#bondy_retry{backoff = Backoff};
        false ->
            State0
    end.

-doc "Returns the current timer value.".
-spec get(State :: t()) -> integer() | deadline | max_retries.

get(#bondy_retry{start_ts = undefined, backoff = undefined} = State) ->
    State#bondy_retry.interval;
get(#bondy_retry{start_ts = undefined, backoff = B}) ->
    backoff:get(B);
get(#bondy_retry{count = N, max_retries = M}) when N > M ->
    max_retries;
get(#bondy_retry{} = State) ->
    Now = erlang:system_time(millisecond),
    Deadline = State#bondy_retry.deadline,
    B = State#bondy_retry.backoff,

    Start =
        case State#bondy_retry.start_ts of
            undefined ->
                0;
            Val ->
                Val
        end,

    case Deadline > 0 andalso Now > (Start + Deadline) of
        true ->
            deadline;
        false when B == undefined ->
            State#bondy_retry.interval;
        false ->
            backoff:get(B)
    end.

-spec fail(State :: t()) ->
    {Time :: integer(), NewState :: t()}
    | {deadline | max_retries, NewState :: t()}.

fail(#bondy_retry{max_retries = N, count = N} = State) ->
    {max_retries, State};
fail(#bondy_retry{backoff = undefined} = State0) ->
    State1 = State0#bondy_retry{
        count = State0#bondy_retry.count + 1
    },
    State = maybe_init_ts(State1),
    %% eqwalizer:ignore
    {get(State), State};
fail(#bondy_retry{backoff = B0} = State0) ->
    {_, B1} = backoff:fail(B0),

    State1 = State0#bondy_retry{
        count = State0#bondy_retry.count + 1,
        backoff = B1
    },
    State = maybe_init_ts(State1),
    %% eqwalizer:ignore
    {get(State), State}.

-spec succeed(State :: t()) -> {Time :: integer(), NewState :: t()}.

succeed(#bondy_retry{backoff = undefined} = State0) ->
    State = State0#bondy_retry{
        count = 0,
        start_ts = undefined
    },
    %% eqwalizer:ignore
    {get(State), State};
succeed(#bondy_retry{backoff = B0} = State0) ->
    {_, B1} = backoff:succeed(B0),
    State = State0#bondy_retry{
        count = 0,
        start_ts = undefined,
        backoff = B1
    },
    %% eqwalizer:ignore
    {get(State), State}.

-spec fire(State :: t()) -> Ref :: reference() | no_return().

fire(#bondy_retry{} = State) ->
    case get(State) of
        Delay when is_integer(Delay) ->
            erlang:start_timer(Delay, self(), State#bondy_retry.id);
        Other ->
            error(Other)
    end.

-spec count(State :: t()) -> non_neg_integer().

count(#bondy_retry{count = Val}) ->
    Val.

%% =============================================================================
%% PRIVATE
%% =============================================================================

maybe_init_ts(#bondy_retry{start_ts = undefined} = State) ->
    State#bondy_retry{
        start_ts = erlang:system_time(millisecond)
    };
maybe_init_ts(#bondy_retry{} = State) ->
    State.
