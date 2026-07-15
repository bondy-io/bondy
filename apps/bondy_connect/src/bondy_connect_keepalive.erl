%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_keepalive).

-moduledoc """
Idle keepalive (ping/pong) state for a `bondy_connect` connection — a **pure
data** helper extracted from `bondy_connect_connection` (review A2).

After `idle_timeout` ms of inbound silence the connection sends a transport
**ping** and waits up to `timeout` ms for the matching **pong**; an unanswered
ping is retried up to `max_attempts` times before the link is declared dead and
the connection reconnects. Any inbound traffic proves the link alive and resets
the budget.

This module owns the retry budget (a `bondy_retry` state machine), the idle
timeout, and the per-connection ping payload, and answers the connection's
keepalive questions purely — *should I ping now, and by when must the pong
arrive?* / *the deadline elapsed, retry or give up?* / *traffic arrived, reset*.
The connection performs the actual transport sends and owns the `gen_statem`
timers; the `idle_actions/1` and `reset_actions/1` helpers return the timer
actions as data so the connection only has to apply them.
""".

-record(keepalive, {
    retry :: bondy_retry:t() | undefined,
    idle_timeout :: pos_integer() | undefined,
    payload :: binary() | undefined
}).

-opaque t() :: #keepalive{}.
-type decision() :: disabled | {ping, Deadline :: pos_integer()} | give_up.

-export_type([t/0]).

-export([new/1]).
-export([payload/1]).
-export([idle_actions/1]).
-export([reset_actions/1]).
-export([on_idle/1]).
-export([on_ping_timeout/1]).
-export([on_activity/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Build keepalive state from the (validated) `ping` config. With `#{enabled :=
true}` the retry budget is `timeout`/`max_attempts`, the idle timer is
`idle_timeout`, and a stable per-connection `payload` is generated (echoed in the
pong; no crypto — uniqueness across connections is not required). Any other input
yields a **disabled** keepalive whose every operation is a no-op.

Must be called from the connection process (the payload derives from `self()`).
""".
-spec new(PingConfig :: map()) -> t().

new(#{enabled := true} = Ping) ->
    Retry = bondy_retry:init(ping_timeout, #{
        deadline => 0,
        interval => maps:get(timeout, Ping),
        max_retries => maps:get(max_attempts, Ping),
        backoff_enabled => false
    }),
    #keepalive{
        retry = Retry,
        idle_timeout = maps:get(idle_timeout, Ping),
        payload = <<
            (erlang:phash2(self())):32, (erlang:unique_integer([positive])):64
        >>
    };
new(_) ->
    #keepalive{}.

-doc "The ping payload to send (or `undefined` when keepalive is disabled).".
-spec payload(t()) -> binary() | undefined.

payload(#keepalive{payload = P}) ->
    P.

-doc "Actions to arm the idle timer (empty when keepalive is disabled).".
-spec idle_actions(t()) -> [gen_statem:action()].

idle_actions(#keepalive{idle_timeout = undefined}) ->
    [];
idle_actions(#keepalive{idle_timeout = T}) ->
    [{{timeout, ping_idle}, T, ping_idle}].

-doc """
Actions to reset keepalive on inbound traffic: cancel any pending ping deadline
and re-arm the idle timer (empty when keepalive is disabled).
""".
-spec reset_actions(t()) -> [gen_statem:action()].

reset_actions(#keepalive{idle_timeout = undefined}) ->
    [];
reset_actions(#keepalive{idle_timeout = T}) ->
    [{{timeout, ping}, cancel}, {{timeout, ping_idle}, T, ping_idle}].

-doc """
The idle timer fired. Returns the keepalive decision: `{ping, Deadline}` to send
a ping that must be answered within `Deadline` ms, `give_up` when the attempts
are already exhausted, or `disabled`. Does not advance the budget (a sent ping is
only counted as failed when its deadline elapses, via `on_ping_timeout/1`).
""".
-spec on_idle(t()) -> decision().

on_idle(#keepalive{retry = undefined}) ->
    disabled;
on_idle(#keepalive{retry = R}) ->
    case bondy_retry:get(R) of
        Deadline when is_integer(Deadline) -> {ping, Deadline};
        _Limit -> give_up
    end.

-doc """
A ping deadline elapsed with no pong. Count the failure via `bondy_retry:fail/1`
and act on **its** result: `{ping, Deadline, t()}` to retry, `{give_up, t()}`
once the attempts are exhausted, or `disabled`.

NB: we use `fail/1`'s returned signal, not a follow-up `get/1`. `fail/1` caps the
count at `max_retries` (returning the `max_retries` atom there) and never lets it
*exceed* the limit — so `get/1` (which only reports `max_retries` when
`count > max_retries`) would never report exhaustion, and with `deadline => 0` it
always returns the interval. The pre-A2 code read `get/1` after `fail/1` and so
**never gave up** — the ping keepalive could not trigger a reconnect.
""".
-spec on_ping_timeout(t()) ->
    disabled | {ping, Deadline :: pos_integer(), t()} | {give_up, t()}.

on_ping_timeout(#keepalive{retry = undefined}) ->
    disabled;
on_ping_timeout(#keepalive{retry = R} = KA) ->
    case bondy_retry:fail(R) of
        {Deadline, R1} when is_integer(Deadline) ->
            {ping, Deadline, KA#keepalive{retry = R1}};
        {_Limit, R1} ->
            {give_up, KA#keepalive{retry = R1}}
    end.

-doc "Inbound traffic proves the link alive: reset the failure budget.".
-spec on_activity(t()) -> t().

on_activity(#keepalive{retry = undefined} = KA) ->
    KA;
on_activity(#keepalive{retry = R} = KA) ->
    {_, R1} = bondy_retry:succeed(R),
    KA#keepalive{retry = R1}.
