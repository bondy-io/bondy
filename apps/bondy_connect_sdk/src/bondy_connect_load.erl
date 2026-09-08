%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_load).

-moduledoc """
Per-connection load regulation for callee **invocation** admission.

It combines two independent limits:

1. a hard **in-flight cap** (`max_concurrency`) — a count of invocations
   currently being serviced by handler workers; `0` means unlimited; and
2. an optional **rate limiter** (`bondy_regulator_rate_limit`, token bucket) —
   when a `rate` spec is configured, admission also consumes a token.

The connection calls `admit/1` before spawning a handler worker and `release/1`
when the worker finishes (or dies). When admission is denied the connection
replies to the router with a backpressure `ERROR` instead of running the
handler. The handler supervisor governs *execution*; this module governs
*admission*.

A pure value (`t()`) — the rate limiter's mutable counters live in the
`bondy_regulator` runtime (atomics), so copying the value is safe. The bucket
is UNREGISTERED (`bondy_regulator_rate_limit:new/2`): it owns no row in the
`bondy_regulator` table, and its atomics array is freed by the VM when the last
reference to the value goes. There is therefore no teardown to run and nothing
a dropped connection can orphan. Reconnects still reuse the bucket (`reset/1`,
not a fresh `new/1`) — not to avoid a leak now, but because the token counters
are time-based and a fresh bucket would hand the reconnecting peer a full
burst.
""".

-include_lib("kernel/include/logger.hrl").

-record(load, {
    max = 0 :: non_neg_integer(),
    in_flight = 0 :: non_neg_integer(),
    limiter :: bondy_regulator_rate_limit:t() | undefined
}).

-type t() :: #load{}.

-export_type([t/0]).

-export([new/1]).
-export([admit/1]).
-export([release/1]).
-export([in_flight/1]).
-export([reset/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Build a load regulator from a handler config map. Recognised keys:

- `max_concurrency` (non_neg_integer, default `0` = unlimited).
- `rate` (a `bondy_regulator_rate_limit` token-bucket opts map). When present a
  token bucket is created; if creation fails the rate limit is silently
  disabled and only the in-flight cap applies.
""".
-spec new(map()) -> t().
new(Opts) when is_map(Opts) ->
    Max = maps:get(max_concurrency, Opts, 0),
    #load{max = Max, limiter = make_limiter(maps:get(rate, Opts, undefined))}.

-doc """
Try to admit one invocation. Increments the in-flight count (and consumes a
rate-limit token when configured) on success.
""".
-spec admit(t()) -> {ok, t()} | {error, overloaded}.
admit(#load{max = Max, in_flight = N}) when Max > 0, N >= Max ->
    {error, overloaded};
admit(#load{limiter = undefined, in_flight = N} = L) ->
    {ok, L#load{in_flight = N + 1}};
admit(#load{limiter = T, in_flight = N} = L) ->
    case bondy_regulator_rate_limit:allow(T, 1) of
        {true, _} ->
            {ok, L#load{in_flight = N + 1}};
        {false, _} ->
            {error, overloaded}
    end.

-doc "Release one previously-admitted invocation.".
-spec release(t()) -> t().
release(#load{in_flight = N} = L) ->
    L#load{in_flight = max(0, N - 1)}.

-doc "The current number of in-flight invocations.".
-spec in_flight(t()) -> non_neg_integer().
in_flight(#load{in_flight = N}) ->
    N.

-doc """
Reset for a reconnect: zero the in-flight count (the previous session's handler
workers have been torn down) while **keeping the same token bucket**. The
bucket's token counters are time-based and intentionally survive the reconnect;
a fresh bucket would hand the reconnecting peer a full burst.
""".
-spec reset(t()) -> t().
reset(#load{} = L) ->
    L#load{in_flight = 0}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
make_limiter(undefined) ->
    undefined;
make_limiter(Opts) when is_map(Opts) ->
    %% UNREGISTERED (`new/2`): this bucket is private to one connection's
    %% handler state and is never looked up by key, so it owns no row that a
    %% teardown could fail to remove.
    case bondy_regulator_rate_limit:new(token_bucket, Opts) of
        {ok, T} ->
            T;
        {error, Reason} ->
            %% The operator configured a `rate' but the limiter could not be
            %% built: fall back to in-flight-only admission, but say so loudly —
            %% otherwise the rate limit is silently inert.
            ?LOG_WARNING(#{
                description =>
                    "Rate limiter could not be created; "
                    "falling back to in-flight-cap admission only.",
                rate => Opts,
                reason => Reason
            }),
            undefined
    end.
