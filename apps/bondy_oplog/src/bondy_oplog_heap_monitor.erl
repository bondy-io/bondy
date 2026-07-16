%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_heap_monitor).
-moduledoc """
Periodic heap monitor for a long-lived `bondy_oplog_instance` process.

A long-lived instance accumulates transient apply/anti-entropy garbage that the
BEAM does not return until a fullsweep. Under a solo import (no peers) the
anti-entropy-driven hibernate never fires, so the process heap climbs unbounded
until the next major GC. This monitor periodically fullsweep-hibernates the
instance once its heap has grown past `instance_gc_heap_delta_bytes` over the
post-GC baseline — capping the transient peak without touching the hot
append/drain path.

Keying on *growth* (not absolute size) is what keeps an instance with a large
live MST from being GC-thrashed: only the delta above the last post-fullsweep
live size trips the reclaim, so a big-but-stable working set never fires it.

## No process of its own

The monitor is passive state, driven entirely by the owning instance:
`arm/1` schedules a `gc_tick` message to the caller, and the instance calls
`handle_tick/1` when that message arrives. Both `arm/1` and `handle_tick/1` read
`self()`'s heap and schedule the timer against `self()`, so they **must** run in
the process being monitored.
""".

-record(?MODULE, {
    baseline = 0 :: non_neg_integer(),
    timer = undefined :: undefined | reference()
}).

-type t() :: #?MODULE{}.
-type decision() ::
    {hibernate, non_neg_integer()}
    | {rebaseline, non_neg_integer()}
    | keep.

-export_type([t/0]).

-export([arm/1]).
-export([gc_decision/3]).
-export([handle_tick/1]).
-export([new/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc "A disarmed monitor with a zero baseline.".
-spec new() -> t().

new() ->
    #?MODULE{}.

-doc """
(Re-)arms the periodic heap-monitor tick, scheduling a `gc_tick` message to the
calling process after `instance_gc_interval_ms`. An interval of `0` disables the
monitor (leaves the timer unset). Cancels any pending timer first so a runtime
interval change takes effect cleanly. Must be called from the process being
monitored.
""".
-spec arm(T :: t()) -> t().

arm(#?MODULE{timer = Ref} = T) ->
    is_reference(Ref) andalso erlang:cancel_timer(Ref),
    case bondy_oplog_config:instance_gc_interval_ms() of
        Ms when is_integer(Ms), Ms > 0 ->
            T#?MODULE{timer = erlang:send_after(Ms, self(), gc_tick)};
        _ ->
            T#?MODULE{timer = undefined}
    end.

-doc """
Handles a `gc_tick`: re-arms the timer, then decides whether the calling process
should hibernate given how far its heap has grown past the baseline.

Returns `{hibernate, T}` when the caller should hand `hibernate` back to the BEAM
(a fullsweep GC that returns the heap to its live size); the baseline is set
provisionally at the pre-GC size so the next tick doesn't immediately re-fire.
Returns `{ok, T}` otherwise. Must be called from the monitored process.
""".
-spec handle_tick(T :: t()) -> {hibernate, t()} | {ok, t()}.

handle_tick(#?MODULE{} = T0) ->
    T = arm(T0),
    Cur = total_heap_words(),
    DeltaWords =
        bondy_oplog_config:instance_gc_heap_delta_bytes() div
            erlang:system_info(wordsize),
    case gc_decision(Cur, T#?MODULE.baseline, DeltaWords) of
        {hibernate, NewBase} ->
            {hibernate, T#?MODULE{baseline = NewBase}};
        {rebaseline, NewBase} ->
            {ok, T#?MODULE{baseline = NewBase}};
        keep ->
            {ok, T}
    end.

-doc """
Pure heap-monitor decision. Given the current heap size `Cur`, the post-GC
baseline `Base` (the live size after the last fullsweep), and the growth
threshold `DeltaWords`:

- grown past the delta → `{hibernate, Cur}` (reclaim; provisionally baseline at
  `Cur` so the next tick doesn't immediately re-fire — the tick after sees the
  lower post-GC heap and rebaselines);
- shrank below the baseline → `{rebaseline, Cur}` (adopt the lower live size,
  e.g. right after a hibernate or a compaction that freed state);
- grew but under the delta → `keep` (accumulate against the same baseline, so
  slow steady growth still trips eventually).
""".
-spec gc_decision(
    Cur :: non_neg_integer(),
    Base :: non_neg_integer(),
    DeltaWords :: pos_integer()
) -> decision().

gc_decision(Cur, Base, DeltaWords) when Cur - Base >= DeltaWords ->
    {hibernate, Cur};
gc_decision(Cur, Base, _DeltaWords) when Cur < Base ->
    {rebaseline, Cur};
gc_decision(_Cur, _Base, _DeltaWords) ->
    keep.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The calling process's total heap size (young + old generations) in words —
%% the growth signal the monitor keys on.
total_heap_words() ->
    case erlang:process_info(self(), total_heap_size) of
        {total_heap_size, W} -> W;
        _ -> 0
    end.
