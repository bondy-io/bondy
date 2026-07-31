%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_dispatch).

-moduledoc """
Callee invocation + subscriber FIFO dispatch + worker lifecycle for a
`bondy_connect` connection — a **pure(-ish) data** helper extracted from
`bondy_connect_connection` (review A2).

It owns the three previously-scattered `gen_statem` maps (in-flight callee
`invocations`, the monitor reverse-index `mons`, and the per-subscription FIFO
`queues`) plus the `bondy_connect_load` regulator, and answers the connection's
dispatch questions by returning **a new state and a list of effects** the
connection interprets:

```
-type effect() ::
      {spawn, invocation | event, Key, Job}   %% statem spawns+monitors, feeds back
    | {spawn_nomon, Job}                       %% unordered event: fire-and-forget
    | {send, Msg}                              %% put a WAMP message on the wire
    | {kill, Pid}.                             %% force-stop a worker
```

The connection is the only party that can spawn/monitor a worker (it owns the
`handler_sup` and its own pid), so the spawn is an **effect**: the connection
runs `start_worker/2`, then feeds the `{ok,{Pid,MonRef}} | {error,_}` result back
via `worker_started/4`, which records the monitor (or, on failure, releases the
load token / advances the FIFO). The single recursive spawn site is the FIFO
drain — `event_done/2`, `worker_down/3` and a failed event spawn all emit at most
one further `{spawn, event, …}`, so the connection's effect interpreter drains
the queue hop-by-hop, mirroring the pre-A2 `next_event/4` recursion.

`erlang:monitor/2` happens in the connection (it needs the spawned pid);
`erlang:demonitor/2` stays **inline here**, paired with the map writes, so the
monitor reverse-index can never desync — the module is ~95% pure (its only direct
effects are demonitors), and that pairing removes a whole class of lockstep bugs.

## Invariants

1. **Per-subscription FIFO** — at most one busy worker per subscription; queued
   events run strictly in order; an *idle* subscription is the **absence** of its
   `queues` entry (a `busy => false` state never occurs).
2. **`mons` lockstep** — `mons[Mon] = {invocation, ReqId}` iff
   `invocations[ReqId] = {_, Mon}`, and `mons[Mon] = {event, SubId}` iff
   `queues[SubId].mon = Mon` (a real reference; `pending` while a spawn is
   in-flight is never indexed).
3. **Load admitted/released exactly once per invocation** — events never touch
   the load regulator. `admit_invocation/3` admits; the matching release is one
   of `worker_started(invocation,_,{error,_},_)`, `handler_done/3`,
   `interrupt/3` or `worker_down/3` (invocation branch).
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-record(dispatch, {
    %% in-flight callee invocations: InvReqId => {WorkerPid, MonRef}
    %% (the pid lets an inbound INTERRUPT kill the servicing worker).
    invocations = #{} :: #{pos_integer() => {pid(), reference()}},
    %% worker monitor reverse index: MonRef => {invocation, InvReqId}
    %%                                       | {event, SubId}
    mons = #{} :: #{reference() => mon_tag()},
    %% per-subscription FIFO dispatch: SubId => entry(); an absent SubId is idle.
    queues = #{} :: #{pos_integer() => entry()},
    load :: bondy_connect_load:t()
}).

-type entry() :: #{
    busy := true,
    queue := queue:queue(job()),
    %% the live worker's monitor, or `pending` between a
    %% {spawn, event, …} effect and its worker_started/4.
    mon := reference() | pending
}.
-type mon_tag() :: {invocation, pos_integer()} | {event, pos_integer()}.
-type job() :: map().
-type reply() ::
    {yield, list() | undefined, map() | undefined}
    | {error, uri(), list() | undefined, map() | undefined}.

-type effect() ::
    {spawn, invocation | event, Key :: pos_integer(), Job :: job()}
    | {spawn_nomon, Job :: job()}
    | {send, Msg :: term()}
    | {kill, Pid :: pid()}.

-opaque t() :: #dispatch{}.

-export_type([t/0]).
-export_type([effect/0]).

%% API
-export([new/1]).
-export([admit_invocation/3]).
-export([dispatch_event/4]).
-export([worker_started/4]).
-export([handler_done/3]).
-export([event_done/2]).
-export([has_invocation/2]).
-export([worker_pid/2]).
-export([interrupt/3]).
-export([progressive_yield/3]).
-export([worker_down/3]).
-export([clear_subscription/2]).
-export([kill_all/1]).
-export([reset/1]).
-export([delete/1]).
-export([in_flight/1]).
-export([inspect/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Build dispatch state wrapping the (already-built) load regulator.".
-spec new(Load :: bondy_connect_load:t()) -> t().

new(Load) ->
    #dispatch{load = Load}.

-doc """
Admit an inbound INVOCATION (the registration was found by the connection).
Charges the load regulator and, on success, asks the connection to spawn a
monitored worker; when the in-flight cap is hit, answers the router with
`ERROR(?WAMP_UNAVAILABLE)` and charges nothing.
""".
-spec admit_invocation(ReqId :: pos_integer(), Job :: job(), t()) ->
    {t(), [effect()]}.

admit_invocation(ReqId, Job, #dispatch{load = Load} = D) ->
    case bondy_connect_load:admit(Load) of
        {ok, Load1} ->
            {D#dispatch{load = Load1}, [{spawn, invocation, ReqId, Job}]};
        {error, overloaded} ->
            Err = bondy_wamp_message:error(
                ?INVOCATION, ReqId, #{}, ?WAMP_UNAVAILABLE
            ),
            {D, [{send, Err}]}
    end.

-doc """
Dispatch an inbound EVENT for `SubId`. `Ordered =:= false` fires an unmonitored,
unqueued, load-free worker (the `handler_sup` contains any crash). `Ordered =:=
true` enforces per-subscription FIFO: at most one worker runs at a time and the
rest queue, draining on `event_done/2` (or a worker `DOWN`).
""".
-spec dispatch_event(
    SubId :: pos_integer(),
    Ordered :: boolean(),
    Job :: job(),
    t()
) -> {t(), [effect()]}.

dispatch_event(_SubId, false, Job, D) ->
    {D, [{spawn_nomon, Job}]};
dispatch_event(SubId, true, Job, #dispatch{queues = Queues} = D) ->
    case maps:get(SubId, Queues, undefined) of
        #{busy := true, queue := Q} = Entry ->
            Entry1 = Entry#{queue := queue:in(Job, Q)},
            {D#dispatch{queues = maps:put(SubId, Entry1, Queues)}, []};
        undefined ->
            %% Idle subscription: start now with an empty queue and a `pending`
            %% monitor that worker_started/4 patches with the real reference.
            Entry = #{busy => true, queue => queue:new(), mon => pending},
            {
                D#dispatch{queues = maps:put(SubId, Entry, Queues)},
                [{spawn, event, SubId, Job}]
            }
    end.

-doc """
Feed back the result of a `{spawn, Tag, Key, _}` effect.

`{ok, {Pid, MonRef}}` records the monitor (and, for events, patches the queue
entry's `pending` monitor). `{error, _}` is handled exactly like the worker dying
immediately: an invocation releases its load token and answers the router; an
event advances its FIFO. Only the event/error branches can emit a further
`{spawn, event, …}` (the drain).
""".
-spec worker_started(
    Tag :: invocation | event,
    Key :: pos_integer(),
    Result :: {ok, {pid(), reference()}} | {error, term()},
    t()
) -> {t(), [effect()]}.

worker_started(invocation, ReqId, {ok, {Pid, MonRef}}, D) ->
    #dispatch{invocations = Inv, mons = Mons} = D,
    {
        D#dispatch{
            invocations = maps:put(ReqId, {Pid, MonRef}, Inv),
            mons = maps:put(MonRef, {invocation, ReqId}, Mons)
        },
        []
    };
worker_started(invocation, ReqId, {error, Reason}, #dispatch{load = Load} = D) ->
    %% Pitfall 1: admit_invocation/3 charged the token; releasing it here is the
    %% other half — forgetting it leaks a token and wedges the in-flight cap.
    ?LOG_WARNING(#{
        description => "Failed to start invocation worker",
        req_id => ReqId,
        reason => Reason
    }),
    Err = bondy_wamp_message:error(
        ?INVOCATION, ReqId, #{}, ?BONDY_CONNECT_INTERNAL_ERROR
    ),
    {D#dispatch{load = bondy_connect_load:release(Load)}, [{send, Err}]};
worker_started(event, SubId, {ok, {_Pid, MonRef}}, D) ->
    #dispatch{queues = Queues, mons = Mons} = D,
    case maps:get(SubId, Queues, undefined) of
        #{} = Entry ->
            Entry1 = Entry#{mon := MonRef},
            {
                D#dispatch{
                    queues = maps:put(SubId, Entry1, Queues),
                    mons = maps:put(MonRef, {event, SubId}, Mons)
                },
                []
            };
        undefined ->
            %% The subscription vanished between the spawn and its feedback
            %% (cannot happen within one synchronous drain, but stay safe):
            %% demonitor so the orphaned monitor cannot leak.
            _ = demonitor_mon(MonRef),
            {D, []}
    end;
worker_started(event, SubId, {error, Reason}, #dispatch{queues = Queues} = D) ->
    ?LOG_WARNING(#{
        description => "Failed to start event worker",
        sub_id => SubId,
        reason => Reason
    }),
    case maps:get(SubId, Queues, undefined) of
        #{} = Entry ->
            %% Drop this event and advance the FIFO so the rest still drains.
            drain_next(SubId, Entry, D);
        undefined ->
            {D, []}
    end.

-doc """
Returns true while invocation `ReqId` is still in flight (admitted and not
yet finished, interrupted or crashed). Used by the connection to decide
whether a worker's progressive result may still be forwarded.
""".
-spec has_invocation(ReqId :: pos_integer(), t()) -> boolean().

has_invocation(ReqId, #dispatch{invocations = Inv}) ->
    is_map_key(ReqId, Inv).

-doc """
The pid of the worker servicing invocation `ReqId`, or `{error, not_found}`
if none is in flight (never started, or already finished/interrupted). Used
to deliver a progressive-input argument chunk to the live worker.
""".
-spec worker_pid(ReqId :: term(), t()) -> {ok, pid()} | {error, not_found}.

worker_pid(ReqId, #dispatch{invocations = Inv}) ->
    case maps:find(ReqId, Inv) of
        {ok, {Pid, _MonRef}} ->
            {ok, Pid};
        error ->
            {error, not_found}
    end.

-doc """
Build the progressive YIELD (`Options.progress = true`) a worker emits for
an in-flight invocation. Unlike `handler_done/3` this releases nothing —
the worker keeps running and its final reply still settles the invocation.
""".
-spec progressive_yield(
    ReqId :: pos_integer(),
    Args :: list() | undefined,
    KWArgs :: map() | undefined
) -> wamp_yield().

progressive_yield(ReqId, Args, KWArgs) ->
    case normalize_payload(Args, KWArgs) of
        {undefined, undefined} ->
            bondy_wamp_message:yield(ReqId, #{progress => true});
        {A, K} ->
            bondy_wamp_message:yield(ReqId, #{progress => true}, A, K)
    end.

-doc """
The worker servicing invocation `ReqId` finished — release its load token, drop
the monitor and answer the router with the worker's YIELD/ERROR. Unknown/already
-finished invocations are a no-op.
""".
-spec handler_done(ReqId :: pos_integer(), Reply :: reply(), t()) ->
    {t(), [effect()]}.

handler_done(ReqId, Reply, #dispatch{invocations = Inv, mons = Mons} = D) ->
    case maps:take(ReqId, Inv) of
        {{_Pid, MonRef}, Inv1} ->
            _ = demonitor_mon(MonRef),
            Out = invocation_reply(ReqId, Reply),
            {
                D#dispatch{
                    invocations = Inv1,
                    mons = maps:remove(MonRef, Mons),
                    load = bondy_connect_load:release(D#dispatch.load)
                },
                [{send, Out}]
            };
        error ->
            {D, []}
    end.

-doc """
The worker servicing subscription `SubId` finished cleanly — flush its `DOWN`,
drop the monitor and start the next queued event (or leave the subscription
idle). Pitfall 2: this clean path demonitors-with-flush; the `DOWN` path
(`worker_down/3`) must **not** (the `DOWN` already consumed the monitor).
""".
-spec event_done(SubId :: pos_integer(), t()) -> {t(), [effect()]}.

event_done(SubId, #dispatch{queues = Queues, mons = Mons} = D) ->
    case maps:get(SubId, Queues, undefined) of
        #{mon := Mon} = Entry ->
            _ = demonitor_mon(Mon),
            drain_next(SubId, Entry, D#dispatch{mons = maps:remove(Mon, Mons)});
        undefined ->
            {D, []}
    end.

-doc """
The router is cancelling an in-flight INVOCATION (`kill`/`killnowait`). Cancel
**forcefully**: kill the servicing worker, drop the monitor, release the load
token and answer the INTERRUPT with `ERROR(?WAMP_CANCELLED)`. Unknown/already
-finished invocations are a no-op.
""".
-spec interrupt(InvReqId :: pos_integer(), Opts :: map(), t()) ->
    {t(), [effect()]}.

interrupt(InvReqId, _Opts, #dispatch{invocations = Inv, mons = Mons} = D) ->
    case maps:take(InvReqId, Inv) of
        {{Pid, MonRef}, Inv1} ->
            _ = demonitor_mon(MonRef),
            Err = bondy_wamp_message:error(
                ?INTERRUPT, InvReqId, #{}, ?WAMP_CANCELLED
            ),
            {
                D#dispatch{
                    invocations = Inv1,
                    mons = maps:remove(MonRef, Mons),
                    load = bondy_connect_load:release(D#dispatch.load)
                },
                [{kill, Pid}, {send, Err}]
            };
        error ->
            {D, []}
    end.

-doc """
A monitored worker died. An invocation worker that died before replying yields a
synthetic `ERROR` and releases its load token; an event worker advances the FIFO.
Also handles a `start_worker` failure (review B1) routed in as a DOWN. Pitfall 2:
the `DOWN` already removed the monitor, so this path never demonitors.
""".
-spec worker_down(MonRef :: reference(), Reason :: term(), t()) ->
    {t(), [effect()]}.

worker_down(MonRef, _Reason, #dispatch{mons = Mons} = D) ->
    case maps:take(MonRef, Mons) of
        {{invocation, ReqId}, Mons1} ->
            case maps:take(ReqId, D#dispatch.invocations) of
                {{_Pid, MonRef}, Inv1} ->
                    Err = bondy_wamp_message:error(
                        ?INVOCATION, ReqId, #{}, ?BONDY_CONNECT_INTERNAL_ERROR
                    ),
                    {
                        D#dispatch{
                            invocations = Inv1,
                            mons = Mons1,
                            load = bondy_connect_load:release(D#dispatch.load)
                        },
                        [{send, Err}]
                    };
                _ ->
                    {D#dispatch{mons = Mons1}, []}
            end;
        {{event, SubId}, Mons1} ->
            D1 = D#dispatch{mons = Mons1},
            case maps:get(SubId, D1#dispatch.queues, undefined) of
                #{} = Entry ->
                    %% No demonitor: the DOWN consumed the monitor (pitfall 2).
                    drain_next(SubId, Entry, D1);
                undefined ->
                    {D1, []}
            end;
        error ->
            {D, []}
    end.

-doc """
Forget subscription `SubId` (unsubscribe): demonitor its busy worker so a stale
`DOWN` cannot advance a now-dead subscription, and drop its queue. Pitfall 3:
emits **no** spawn (a cleared subscription must never be re-armed by effect
ordering), and removes from both `queues` and `mons` in the returned value.
""".
-spec clear_subscription(SubId :: pos_integer(), t()) -> {t(), [effect()]}.

clear_subscription(SubId, #dispatch{queues = Queues, mons = Mons} = D) ->
    case maps:get(SubId, Queues, undefined) of
        #{mon := Mon} ->
            _ = demonitor_mon(Mon),
            {
                D#dispatch{
                    queues = maps:remove(SubId, Queues),
                    mons = maps:remove(Mon, Mons)
                },
                []
            };
        undefined ->
            {D, []}
    end.

-doc """
Teardown on a disconnect: kill in-flight invocation workers and demonitor event
workers (so their late `DOWN`s are ignored and they finish under the temporary
`handler_sup`). Returns the `{kill, Pid}` effects for the invocation workers; the
caller follows with `reset/1` to clear the maps and reset the load counter.
""".
-spec kill_all(t()) -> {t(), [effect()]}.

kill_all(#dispatch{invocations = Inv, queues = Queues} = D) ->
    KillEffects = maps:fold(
        fun(_ReqId, {Pid, MonRef}, Acc) ->
            _ = demonitor_mon(MonRef),
            [{kill, Pid} | Acc]
        end,
        [],
        Inv
    ),
    _ = maps:foreach(
        fun(_SubId, #{mon := Mon}) -> _ = demonitor_mon(Mon) end,
        Queues
    ),
    {D, KillEffects}.

-doc """
Clear all dispatch maps and reset the load counter, **reusing** the same token
bucket across reconnects (a fresh `bondy_connect_load:new/1` would orphan a
`bondy_regulator` ETS row each time — review B4).
""".
-spec reset(t()) -> t().

reset(#dispatch{load = Load}) ->
    #dispatch{load = bondy_connect_load:reset(Load)}.

-doc "Free the load regulator's ETS row on connection terminate (review B4).".
-spec delete(t()) -> ok.

delete(#dispatch{load = Load}) ->
    bondy_connect_load:delete(Load).

-doc "The number of in-flight callee invocations (test/introspection helper).".
-spec in_flight(t()) -> non_neg_integer().

in_flight(#dispatch{invocations = Inv}) ->
    maps:size(Inv).

-doc """
A snapshot of the internal maps for tests/debugging (the `t()` is otherwise
opaque). `load_in_flight` is the load regulator's current count, used to assert
the admit/release-exactly-once invariant.
""".
-spec inspect(t()) ->
    #{
        invocations := map(),
        mons := map(),
        queues := map(),
        load_in_flight := non_neg_integer()
    }.

inspect(#dispatch{invocations = Inv, mons = Mons, queues = Q, load = L}) ->
    #{
        invocations => Inv,
        mons => Mons,
        queues => Q,
        load_in_flight => bondy_connect_load:in_flight(L)
    }.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private Start the next queued event for `SubId` (the worker's monitor is
%% already gone — demonitored on the clean path, consumed by the DOWN, or never
%% set for a failed spawn). Pops the FIFO and, on a job, re-arms the entry with a
%% `pending` monitor and emits a single `{spawn, event, …}`; on an empty queue
%% the subscription returns to idle (its entry is removed).
drain_next(SubId, #{queue := Q} = Entry, #dispatch{queues = Queues} = D) ->
    case queue:out(Q) of
        {{value, Job}, Q1} ->
            Entry1 = Entry#{queue := Q1, mon := pending},
            {
                D#dispatch{queues = maps:put(SubId, Entry1, Queues)},
                [{spawn, event, SubId, Job}]
            };
        {empty, _} ->
            {D#dispatch{queues = maps:remove(SubId, Queues)}, []}
    end.

%% @private Demonitor a real reference (flushing any pending DOWN); a no-op for a
%% `pending`/`undefined` placeholder so callers need not special-case it.
demonitor_mon(Mon) when is_reference(Mon) ->
    _ = erlang:demonitor(Mon, [flush]),
    ok;
demonitor_mon(_) ->
    ok.

%% @private Build the YIELD/ERROR a finished invocation worker reports back.
invocation_reply(ReqId, {yield, Args, KWArgs}) ->
    case normalize_payload(Args, KWArgs) of
        {undefined, undefined} ->
            bondy_wamp_message:yield(ReqId, #{});
        {A, K} ->
            bondy_wamp_message:yield(ReqId, #{}, A, K)
    end;
invocation_reply(ReqId, {error, Uri, Args, KWArgs}) ->
    {A, K} = normalize_payload(Args, KWArgs),
    bondy_wamp_message:error(?INVOCATION, ReqId, #{}, Uri, A, K).

%% @private Normalise a (Args, KWArgs) payload for the WAMP constructors: empty
%% kwargs collapse to `undefined`; non-empty kwargs require a (possibly empty)
%% args list.
normalize_payload(undefined, undefined) ->
    {undefined, undefined};
normalize_payload(undefined, K) when is_map(K), map_size(K) == 0 ->
    {undefined, undefined};
normalize_payload(undefined, K) ->
    {[], K};
normalize_payload(A, undefined) ->
    {A, undefined};
normalize_payload(A, K) when is_map(K), map_size(K) == 0 ->
    {A, undefined};
normalize_payload(A, K) ->
    {A, K}.
