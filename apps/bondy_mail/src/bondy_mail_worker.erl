%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_worker).

-moduledoc """
One worker in a relay's pool. The only place SMTP I/O happens.

This is the design's central claim: a slow or dead relay degrades mail delivery
and nothing else. Every send is handed to one of these, which is not a router
process, is not a subscriber, and is not on any dispatch path. A relay that
stops answering fills its queue and then refuses new work; publish and
subscribe are untouched throughout.

## Backpressure is a bound, not a wait

Each worker owns a `jobs` queue with a maximum size and a time-to-live, the
same shape `bondy_jobs_worker` uses for the router's own async work. Enqueueing
into a full queue is refused immediately rather than blocking the caller: a
caller that blocks on a stalled relay has simply moved the stall somewhere
else. Refusal is transient, and says so.

## Retry

Transient failures retry on a jittered exponential backoff from `bondy_retry`,
bounded by both the relay's attempt count and the request's deadline --
whichever runs out first. Permanent failures do not retry at all: a rejected
recipient is rejected however many times it is offered.

The wait between attempts happens inside the worker, which is deliberate. A
worker is a delivery slot, and holding one across a backoff is what stops a
failing relay from being hammered. It costs nothing else, because the queue in
front of it is what callers actually interact with.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mail.hrl").

-record(state, {
    relay_name :: binary(),
    index :: pos_integer(),
    queue :: atom()
}).

%% API
-export([enqueue/2]).
-export([queue_name/2]).
-export([start_link/2]).

%% GEN_SERVER CALLBACKS
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_continue/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Start worker `Index` for `Relay`.".
-spec start_link(Relay :: #bondy_mail_relay{}, Index :: pos_integer()) ->
    {ok, pid()} | {error, any()}.

start_link(#bondy_mail_relay{} = Relay, Index) ->
    gen_server:start_link(?MODULE, [Relay, Index], []).

-doc "Return the `jobs` queue name for worker `Index` of `Name`.".
-spec queue_name(Name :: binary(), Index :: pos_integer()) -> atom().

queue_name(Name, Index) ->
    binary_to_atom(
        iolist_to_binary([~"bondy_mail_q_", Name, $_, integer_to_binary(Index)]),
        utf8
    ).

-doc """
Hand a request to a worker.

Answers `ok` once the request is queued, or `{error, {transient, queue_full,
_}}` when the relay's queue is at its bound. `Reply` is where the outcome is
sent: a pid for a synchronous caller, or `undefined` to fire and forget.
""".
-spec enqueue(
    Request :: #bondy_mail_request{},
    Reply :: {pid(), reference()} | undefined
) ->
    ok | {error, bondy_mail_transport:reason()}.

enqueue(#bondy_mail_request{} = Request, Reply) ->
    Name = Request#bondy_mail_request.relay,
    Queue = pick_queue(Request),
    EnqueuedAt = erlang:monotonic_time(millisecond),
    case jobs:enqueue(Queue, {Request, Reply, EnqueuedAt}) of
        ok ->
            %% After the enqueue, never before: a refused message was never in
            %% the queue, and counting it would leave the depth permanently
            %% overstated because nothing will ever take it out again.
            _ = depth_add(Request, 1),
            ok;
        %% `jobs:enqueue/2` answers `{error, full}`. The `rejected` reason
        %% comes from `jobs:ask/1`, a different path this does not use --
        %% matching on it instead would misreport every full queue as an
        %% unavailable one.
        {error, full} ->
            {error, {transient, queue_full, Name}};
        {error, Reason} ->
            {error, {transient, queue_unavailable, Reason}}
    end.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

-doc false.
init([#bondy_mail_relay{} = Relay, Index]) ->
    Name = Relay#bondy_mail_relay.name,
    Queue = queue_name(Name, Index),

    %% The bound is per worker, so a relay's total is `pool.size` times this.
    %% Divided rather than shared, because a shared queue would need a lock in
    %% front of it and this needs none.
    MaxSize = max(
        1,
        Relay#bondy_mail_relay.queue_max_size div
            Relay#bondy_mail_relay.pool_size
    ),
    QOpts = [
        {type, {passive, fifo}},
        {max_time, Relay#bondy_mail_relay.queue_ttl},
        {max_size, MaxSize},
        {link, self()}
    ],
    ok = jobs:add_queue(Queue, QOpts),

    State = #state{relay_name = Name, index = Index, queue = Queue},
    {ok, State, {continue, dequeue}}.

-doc false.
%% Blocks until there is work, which is what `passive` means: the worker is
%% idle in `jobs:dequeue/2` rather than spinning on a timer.
handle_continue(dequeue, #state{queue = Queue} = State) ->
    Jobs = jobs:dequeue(Queue, 1),
    ok = lists:foreach(fun({_, Job}) -> run(Job, State) end, Jobs),
    {noreply, State, {continue, dequeue}}.

-doc false.
handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {noreply, State}.

-doc false.
handle_cast(Event, State) ->
    ?LOG_WARNING(#{reason => unsupported_event, event => Event}),
    {noreply, State}.

-doc false.
handle_info(Info, State) ->
    ?LOG_DEBUG(#{reason => unsupported_event, event => Info}),
    {noreply, State}.

-doc false.
terminate(_Reason, _State) ->
    ok.

-doc false.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Round-robin over the relay's workers, as one wait-free atomic increment.
%%
%% This used to hash a unique integer, which spreads *on average* and unevenly
%% in any particular burst: eight messages across four workers land 3/2/2/1 as
%% readily as 2/2/2/2, so a relay's effective concurrency was below the pool
%% size it was configured with, and the tail of a burst waited behind a worker
%% that had been given more than its share. A rotation gives every burst an even
%% split for free.
%%
%% There is no ordering guarantee between messages, and none is claimed: SMTP
%% has none either.
pick_queue(#bondy_mail_request{relay = Name}) ->
    case bondy_mail_config:relay(Name) of
        {ok, #bondy_mail_relay{pool_size = Size, pool_cursor = Cursor}} ->
            queue_name(Name, next_index(Cursor, Size));
        {error, _} ->
            queue_name(Name, 1)
    end.

%% @private
%% Wraps by construction: the counter is unsigned 64-bit, so it is taken modulo
%% the pool size rather than being reset, and no two callers can collide on the
%% reset.
next_index(Cursor, Size) ->
    (atomics:add_get(Cursor, 1, 1) rem Size) + 1.

%% @private
%% The outcome is recorded before the caller is told, so that a client which
%% reacts to a reply by asking for status cannot beat the write.
run({#bondy_mail_request{} = Request, Reply, EnqueuedAt}, State) ->
    Depth = depth_add(Request, -1),
    Started = erlang:monotonic_time(millisecond),
    ok = bondy_mail_telemetry:queue(
        Request#bondy_mail_request.relay, Depth, Started - EnqueuedAt
    ),

    Result = deliver(Request, State),
    Duration = erlang:monotonic_time(millisecond) - Started,

    ok = bondy_mail_status:update(
        bondy_mail_request:message_id(Request), Result
    ),
    ok = report(Request, Reply, Result, Duration),
    ok = reply(Reply, Result),
    ok.

%% @private
%% Two audiences: the metrics, and the relay's own health.
%%
%% Only a transient failure counts against a relay's health. A rejected
%% recipient or an oversized message is the relay working correctly, and
%% letting either mark it down would raise a page about a caller's mistake.
report(Request, _Reply, {ok, Result}, Duration) ->
    Relay = bondy_mail_request:relay(Request),
    Realm = bondy_mail_request:realm(Request),
    Attempts = maps:get(attempts, Result, 1),
    ok = bondy_mail_telemetry:sent(Relay, Realm, Attempts, Duration),
    bondy_mail_relay:report(Relay, ok);
report(Request, Reply, {error, {Nature, Class, _}}, Duration) ->
    Relay = bondy_mail_request:relay(Request),
    Realm = bondy_mail_request:realm(Request),
    ok = bondy_mail_telemetry:failed(Relay, Realm, Nature, Class, Duration),
    ok = maybe_dead_letter(Reply, Relay, Realm, Class),
    bondy_mail_relay:report(Relay, Nature);
report(_Request, _Reply, _Result, _Duration) ->
    ok.

%% @private
%% A message nobody is waiting for has failed silently unless this says so. A
%% synchronous caller receives the error and decides what to do about it; every
%% message the broker bridge sends has no such caller, so this event and the
%% log line beside it are the only record it existed.
maybe_dead_letter(undefined, Relay, Realm, Class) ->
    ok = bondy_mail_telemetry:dead_letter(Relay, Realm, Class),
    ?LOG_ERROR(#{
        description => "Message could not be delivered and had no caller",
        relay => Relay,
        realm_uri => Realm,
        error_class => Class
    }),
    ok;
maybe_dead_letter(_Reply, _Relay, _Realm, _Class) ->
    ok.

%% @private
%% Depth is a counter on the relay's own record rather than a question put to
%% the `jobs` server: `jobs:queue_info/2` is a call into a single process, and
%% asking it once per message would put that process on the path of every send.
%%
%% Signed, and floored at zero on the way out: a worker draining a queue built
%% up before a reconfiguration can decrement past what it incremented, and a
%% negative depth on a dashboard is worse than a slightly stale zero.
depth_add(#bondy_mail_request{relay = Name}, Delta) ->
    case bondy_mail_config:relay(Name) of
        {ok, #bondy_mail_relay{queue_depth = Ref}} ->
            max(0, atomics:add_get(Ref, 1, Delta));
        {error, _} ->
            0
    end.

%% @private
reply(undefined, _Result) ->
    ok;
reply({Pid, Ref}, Result) ->
    _ = Pid ! {bondy_mail, Ref, Result},
    ok.

%% @private
deliver(#bondy_mail_request{relay = Name} = Request, State) ->
    case bondy_mail_config:relay(Name) of
        {ok, Relay} ->
            case bondy_mail_mime:encode(Request, Relay) of
                {ok, Message} ->
                    attempt(
                        Request, Message, Relay, new_retry(Relay), 1, State
                    );
                {error, {too_large_payload, _, _} = Reason} ->
                    {error, {permanent, too_large_payload, Reason}};
                {error, Reason} ->
                    log_encoding_failure(Request, Reason),
                    {error, {permanent, encoding_failed, mime}}
            end;
        {error, no_such_relay} ->
            %% The relay was reconfigured away while this was queued.
            {error, {permanent, no_such_relay, Name}}
    end.

%% @private
attempt(Request, Message, Relay, Retry0, Attempt, State) ->
    case expired(Request) of
        true ->
            {error, {transient, deadline, Attempt}};
        false ->
            Result = bondy_mail_transport_smtp:send(Request, Message, Relay),
            case Result of
                {ok, Receipt} ->
                    {ok, #{receipt => Receipt, attempts => Attempt}};
                {error, {permanent, _, _} = Reason} ->
                    {error, Reason};
                {error, {transient, _, _} = Reason} ->
                    retry(
                        Request, Message, Relay, Retry0, Attempt, Reason, State
                    )
            end
    end.

%% @private
retry(Request, Message, Relay, Retry0, Attempt, Reason, State) ->
    case bondy_retry:fail(Retry0) of
        {Delay, Retry} when is_integer(Delay) ->
            case sleep_within_deadline(Request, Delay) of
                ok ->
                    ok = log_retry(Request, Attempt, Reason, State),
                    attempt(
                        Request, Message, Relay, Retry, Attempt + 1, State
                    );
                deadline ->
                    {error, {transient, deadline, Attempt}}
            end;
        {Limit, _Retry} when Limit == deadline orelse Limit == max_retries ->
            {error, Reason}
    end.

%% @private
%% Two budgets bound a retry: the relay's attempt count and the request's
%% deadline. Sleeping past the deadline would hold a worker for work whose
%% result nobody is waiting for any more.
sleep_within_deadline(Request, Delay) ->
    Remaining =
        bondy_mail_request:deadline(Request) -
            erlang:monotonic_time(millisecond),
    case Remaining =< 0 orelse Delay >= Remaining of
        true -> deadline;
        false -> timer:sleep(Delay)
    end.

%% @private
expired(Request) ->
    erlang:monotonic_time(millisecond) >=
        bondy_mail_request:deadline(Request).

%% @private
new_retry(#bondy_mail_relay{} = Relay) ->
    bondy_retry:init(?MODULE, #{
        max_retries => Relay#bondy_mail_relay.retry_max_attempts,
        %% Bounded by attempts and by the request's deadline, checked
        %% separately, so no wall-clock deadline is set here.
        deadline => 0,
        interval => Relay#bondy_mail_relay.retry_backoff_min,
        backoff_enabled => true,
        backoff_min => Relay#bondy_mail_relay.retry_backoff_min,
        backoff_max => Relay#bondy_mail_relay.retry_backoff_max,
        backoff_type => jitter
    }).

%% @private
%% Never the body, never the recipients.
log_retry(Request, Attempt, {_, Class, _}, #state{relay_name = Name}) ->
    ok = bondy_mail_telemetry:retried(Name, Class),
    ?LOG_INFO(#{
        description => "Retrying mail delivery",
        relay => Name,
        realm_uri => bondy_mail_request:realm(Request),
        attempt => Attempt,
        error_class => Class
    }),
    ok.

%% @private
log_encoding_failure(Request, Reason) ->
    ?LOG_ERROR(#{
        description => "Could not encode message",
        relay => bondy_mail_request:relay(Request),
        realm_uri => bondy_mail_request:realm(Request),
        reason => Reason
    }),
    ok.
