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

## The queue is this application's own

A worker holds its queue in its own state, and a caller hands work over by
sending it a message. Nothing on the send path calls into a process shared with
anything else.

That is a correction rather than a preference. This used to enqueue into
`jobs`, where `jobs:enqueue/2` is a `gen_server:call/3` -- with an `infinity`
timeout -- into the single, node-global `jobs_server` that also serves
`bondy_jobs`, `bondy_event_wamp_publisher`, `bondy_meta_events` and the
retained-message manager. The whole message, decoded attachments included, was
copied into that process and held there until a worker took it. So a relay that
stopped answering filled its queue exactly as designed and, in doing so, grew
the heap of a process the router depends on. The claim above was false, by way
of the queue library rather than by way of SMTP.

Messages now sit in the process that will deliver them, which is where they
were always supposed to be.

## Backpressure is a bound, not a wait

The bound is a pair of `atomics` counters per worker on the relay's record: how
many messages are queued for that worker, and how many bytes they hold. A caller
picks its worker, reserves against that worker's pair, and is refused
immediately if the relay's totals are exhausted -- a caller that blocks on a
stalled relay has simply moved the stall somewhere else. Refusal is transient,
and says so.

Two counters because one is not a bound. `queue.max_size` alone says nothing
about memory when a message may be a hundred bytes or twenty megabytes, and it
was the byte total that made a full queue anyone else's problem.

**The bound is the relay's, the slots are each worker's.** Both are needed. The
bound has to be relay-wide because that is what an operator configures and what
a dashboard shows; the slots have to be per worker because that is what makes a
leak recoverable. A reservation can be stranded -- a worker that dies between
`gproc:where/1` and the send takes the message with it, and no release path can
reach what was never received -- and a single relay-wide counter would carry
that loss for the lifetime of the node, silently shrinking the queue bound with
nothing to say so. A worker zeroes its own pair in `start_link/2`, before it
exists and before it is registered, so a restart returns the room. Summing a
handful of slots on the way in costs two orders of magnitude less than the
message it admits.

The reservation is released when a worker takes the message, not when delivery
finishes: the queue is what is waiting, and a message being delivered is no
longer waiting.

## Draining

A worker returns to its mailbox between every delivery. It drains by sending
itself a message rather than by looping inside `handle_continue/2`, and the
difference matters: `gen_server` dispatches a `{continue, _}` without receiving
anything, so a worker that re-armed one on every pass would never serve a
system message, never see anything sent to it, and never run any of the
callbacks below. Newly arrived messages are absorbed into the lanes before the
next one is taken, which is also what makes `priority` mean something.

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

%% Every worker owns two adjacent slots in the relay's `queue_counters`: the
%% messages queued for it, and the bytes they hold. `atomics` slots are
%% one-based, so worker 1 owns 1 and 2, worker 2 owns 3 and 4, and so on.
-define(COUNT(Index), (2 * (Index) - 1)).
-define(BYTES(Index), (2 * (Index))).

-define(MAIL, '$bondy_mail').
-define(DRAIN, '$bondy_mail_drain').

-type item() :: {
    Request :: #bondy_mail_request{},
    Reply :: reply(),
    EnqueuedAt :: integer()
}.

-type reply() :: {pid(), reference()} | undefined.

-record(state, {
    relay_name :: binary(),
    index :: pos_integer(),
    %% Two lanes, served normal-before-low. Deliberately not a priority queue:
    %% there are two priorities, and `queue:out/1` on the right one is cheaper
    %% and easier to read than a general structure ordering two values.
    normal = queue:new() :: queue:queue(item()),
    low = queue:new() :: queue:queue(item()),
    %% At most one drain message is ever in flight. Without this every enqueue
    %% would post one, and a busy relay would carry a mailbox of drain requests
    %% alongside the mail they are about.
    draining = false :: boolean()
}).

%% API
-export([enqueue/2]).
-export([start_link/2]).

%% GEN_SERVER CALLBACKS
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Start worker `Index` for `Relay`.".
-spec start_link(Relay :: #bondy_mail_relay{}, Index :: pos_integer()) ->
    {ok, pid()} | {error, any()}.

start_link(#bondy_mail_relay{name = Name} = Relay, Index) ->
    %% Zeroed here rather than in `init/1`, because here is the one moment at
    %% which nothing can hold a reservation against this worker: it runs in the
    %% supervisor, the process does not exist yet, and its `gproc` name is
    %% unregistered, so no caller can have resolved it. A worker that died
    %% holding messages -- or one whose caller resolved its pid and sent to it
    %% in the moment after it died -- leaves reservations behind that no release
    %% path can reach, and a counter that only ever accumulates them shrinks the
    %% relay's queue bound a little more with every restart. Starting from zero
    %% makes that self-healing instead.
    ok = reset(Relay, Index),
    Via = {via, gproc, key(Name, Index)},
    gen_server:start_link(Via, ?MODULE, [Relay, Index], []).

-doc """
Hand a request to a worker.

Answers `ok` once the request is queued, or a transient error when the relay's
queue is at either of its bounds. `Reply` is where the outcome is sent: a pid
and reference for a synchronous caller, or `undefined` to fire and forget.

Runs in the caller's process and never blocks: a worker is chosen with one
atomic increment, the bound is checked with a handful more, and the message is
then sent. Nothing here waits for a worker, and nothing here waits for a process
shared with anything else.
""".
-spec enqueue(Request :: #bondy_mail_request{}, Reply :: reply()) ->
    ok | {error, bondy_mail_transport:reason()}.

enqueue(#bondy_mail_request{relay = Name} = Request, Reply) ->
    case bondy_mail_config:relay(Name) of
        {ok, Relay} ->
            do_enqueue(Request, Reply, Relay);
        {error, no_such_relay} ->
            {error, {permanent, no_such_relay, Name}}
    end.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

-doc false.
init([#bondy_mail_relay{name = Name}, Index]) ->
    %% Without this the supervisor's shutdown kills this process outright and
    %% `terminate/2` never runs, so everything still queued would vanish with
    %% no reply to a waiting caller, no status update, and -- on a restart --
    %% no release of the queue reservations those messages hold. A
    %% `terminate/2` that is never called looks exactly like one that works.
    %%
    %% Safe here: `gen_smtp_client:send_blocking/2` runs inline and links
    %% nothing, so trapping exits does not turn a delivery failure into a
    %% message the worker would then have to interpret.
    _ = process_flag(trap_exit, true),
    {ok, #state{relay_name = Name, index = Index}}.

-doc false.
handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From,
        relay => State#state.relay_name,
        worker => State#state.index
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

-doc false.
handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        relay => State#state.relay_name,
        worker => State#state.index
    }),
    {noreply, State}.

-doc false.
handle_info({?MAIL, Item}, State) ->
    {noreply, schedule_drain(push(Item, State))};
handle_info(?DRAIN, State) ->
    {noreply, drain_one(State#state{draining = false})};
handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unsupported_event,
        event => Info,
        relay => State#state.relay_name,
        worker => State#state.index
    }),
    {noreply, State}.

-doc false.
%% Whatever is still queued is refused rather than dropped in silence. A
%% synchronous caller is told, a status record stops saying `queued`, and the
%% reservation each message holds is released -- a worker that restarted
%% without releasing them would shrink its relay's queue bound by exactly the
%% amount it was holding, permanently, with nothing to say so.
%%
%% The mailbox is drained too. A message that arrived but had not yet reached a
%% lane holds a reservation just the same, and is just as lost.
terminate(_Reason, #state{index = Index} = State) ->
    Queued =
        queue:to_list(State#state.normal) ++
            queue:to_list(State#state.low) ++
            flush(),
    lists:foreach(
        fun({Request, _, _} = Item) ->
            ok = with_relay(Request, fun(R) -> release(Request, R, Index) end),
            ok = shed(Item, shutdown, State)
        end,
        Queued
    ).

-doc false.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The worker is chosen before the reservation is made, because the reservation
%% is against that worker's slots. Choosing is a single atomic increment and
%% cannot fail, so nothing is spent finding out where the message is going.
do_enqueue(Request, Reply, Relay) ->
    Index = next_index(Relay),
    case reserve(Request, Relay, Index) of
        ok ->
            case worker(Relay, Index) of
                {ok, Pid} ->
                    Item = {Request, Reply, erlang:monotonic_time(millisecond)},
                    _ = Pid ! {?MAIL, Item},
                    ok;
                {error, _} = Error ->
                    ok = release(Request, Relay, Index),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @private
%% Reserve first and check afterwards, rather than reading and then adding: two
%% callers reading the same total would both be admitted, which is the race the
%% bound exists to lose. A reservation that turns out to exceed the bound is
%% given straight back, so at worst the totals are briefly high by what the
%% racing callers hold -- never permanently, and never by more than that.
%%
%% Under contention the error is in the direction of refusing: two callers can
%% both see the other's reservation in the total and both back out where one
%% could have been admitted. A transient refusal on a queue that is at its bound
%% anyway is the cheap side of this trade; the expensive side is admitting past
%% the bound, and that cannot happen.
reserve(#bondy_mail_request{size_bytes = Size}, Relay, Index) ->
    #bondy_mail_relay{
        name = Name,
        queue_counters = Ref,
        pool_size = PoolSize,
        queue_max_size = MaxSize,
        queue_max_bytes = MaxBytes
    } = Relay,

    _ = atomics:add(Ref, ?COUNT(Index), 1),
    _ = atomics:add(Ref, ?BYTES(Index), Size),

    Full =
        total(Ref, count, PoolSize) > MaxSize orelse
            total(Ref, bytes, PoolSize) > MaxBytes,

    case Full of
        true ->
            ok = give_back(Ref, Index, Size),
            {error, {transient, queue_full, Name}};
        false ->
            ok
    end.

%% @private
release(#bondy_mail_request{size_bytes = Size}, Relay, Index) ->
    give_back(Relay#bondy_mail_relay.queue_counters, Index, Size).

%% @private
give_back(Ref, Index, Size) ->
    _ = atomics:sub(Ref, ?COUNT(Index), 1),
    _ = atomics:sub(Ref, ?BYTES(Index), Size),
    ok.

%% @private
reset(#bondy_mail_relay{queue_counters = Ref}, Index) ->
    ok = atomics:put(Ref, ?COUNT(Index), 0),
    ok = atomics:put(Ref, ?BYTES(Index), 0).

%% @private
%% One of the two counters, summed across the pool. This is the relay's number:
%% what the bound is enforced against, and what the depth gauge publishes. A
%% single worker's slot is a fraction of it, and a gauge labelled by relay that
%% is written with one worker's fraction -- as this used to be -- has every
%% worker in the pool overwriting the same series with its own share.
total(Ref, Which, PoolSize) ->
    total(Ref, Which, PoolSize, 0).

%% @private
total(_Ref, _Which, 0, Acc) ->
    Acc;
total(Ref, count, Index, Acc) ->
    total(Ref, count, Index - 1, Acc + atomics:get(Ref, ?COUNT(Index)));
total(Ref, bytes, Index, Acc) ->
    total(Ref, bytes, Index - 1, Acc + atomics:get(Ref, ?BYTES(Index))).

%% @private
%% What the relay's depth gauge publishes. Answers 0 for a relay that has been
%% reconfigured away, which is true: nothing is queued for something that no
%% longer exists.
depth(Name) ->
    case bondy_mail_config:relay(Name) of
        {ok, #bondy_mail_relay{queue_counters = Ref, pool_size = PoolSize}} ->
            total(Ref, count, PoolSize);
        {error, no_such_relay} ->
            0
    end.

%% @private
%% Round-robin over the relay's workers, as one wait-free atomic increment.
%%
%% Not a hash of anything: hashing spreads on average and unevenly in any
%% particular burst, so eight messages across four workers land 3/2/2/1 as
%% readily as 2/2/2/2 and the tail of a burst waits behind a worker that was
%% given more than its share. A rotation gives every burst an even split for
%% free -- which is also what makes per-worker slots a fair division of a
%% relay-wide bound rather than a lottery.
%%
%% Wraps by construction: the cursor is unsigned 64-bit, so it is taken modulo
%% the pool size rather than being reset, and no two callers can collide on the
%% reset.
%%
%% There is no ordering guarantee between messages, and none is claimed: SMTP
%% has none either.
next_index(#bondy_mail_relay{pool_cursor = Cursor, pool_size = Size}) ->
    (atomics:add_get(Cursor, 1, 1) rem Size) + 1.

%% @private
worker(#bondy_mail_relay{name = Name}, Index) ->
    case gproc:where(key(Name, Index)) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        undefined ->
            %% Restarting, or removed from the configuration while a caller
            %% held the record. Transient: the supervisor is very likely
            %% bringing it back.
            {error, {transient, queue_unavailable, Name}}
    end.

%% @private
%% One place that knows the shape of a worker's registered name, so that
%% registering one and finding one cannot disagree.
key(Name, Index) ->
    {n, l, {?MODULE, Name, Index}}.

%% @private
push({Request, _, _} = Item, State) ->
    case Request#bondy_mail_request.priority of
        low ->
            State#state{low = queue:in(Item, State#state.low)};
        _ ->
            State#state{normal = queue:in(Item, State#state.normal)}
    end.

%% @private
%% Sending to self rather than re-arming `{continue, _}`: see the module docs.
%% The message lands behind whatever is already in the mailbox, so every
%% message that has arrived is in a lane before the next one is chosen.
schedule_drain(#state{draining = true} = State) ->
    State;
schedule_drain(#state{normal = N, low = L} = State) ->
    %% `is_empty/1` rather than a length: `queue:len/1` is `length(R) + length(F)`
    %% (`stdlib/src/queue.erl:151`), and asking it on every push and every pop
    %% makes a burst quadratic in the queue bound for an answer that is a
    %% one-bit question.
    case queue:is_empty(N) andalso queue:is_empty(L) of
        true ->
            State;
        false ->
            _ = self() ! ?DRAIN,
            State#state{draining = true}
    end.

%% @private
%% Everything handed over but not yet filed into a lane. Only reached from
%% `terminate/2`, where the alternative is losing both the message and the
%% reservation it holds.
flush() ->
    flush([]).

%% @private
flush(Acc) ->
    receive
        {?MAIL, Item} -> flush([Item | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

%% @private
%% Normal before low, and arrival order within each.
pop(#state{normal = N0, low = L0} = State) ->
    case queue:out(N0) of
        {{value, Item}, N} ->
            {Item, State#state{normal = N}};
        {empty, _} ->
            case queue:out(L0) of
                {{value, Item}, L} -> {Item, State#state{low = L}};
                {empty, _} -> empty
            end
    end.

%% @private
drain_one(#state{index = Index} = State0) ->
    case pop(State0) of
        empty ->
            State0;
        {{Request, _, _} = Item, State} ->
            %% Released here, before delivery: the counters bound what is
            %% WAITING, and this one is not waiting any more.
            ok = with_relay(Request, fun(R) -> release(Request, R, Index) end),
            ok = handle_item(Item, State),
            schedule_drain(State)
    end.

%% @private
%% A message that waited longer than the relay allows is not worth a delivery
%% slot: whoever asked for it has long since been answered by their own
%% deadline. Shedding it is reported rather than silent, which is more than the
%% queue this replaced managed -- `jobs` dropped an expired entry inside its own
%% server, leaving a synchronous caller to wait out its timeout and a status
%% record saying `queued` for ever.
handle_item({Request, _, EnqueuedAt} = Item, State) ->
    Waited = erlang:monotonic_time(millisecond) - EnqueuedAt,
    case Waited >= queue_ttl(Request) of
        true ->
            shed(Item, expired, State);
        false ->
            run(Item, Waited)
    end.

%% @private
queue_ttl(#bondy_mail_request{relay = Name}) ->
    case bondy_mail_config:relay(Name) of
        {ok, #bondy_mail_relay{queue_ttl = Ttl}} -> Ttl;
        {error, no_such_relay} -> 0
    end.

%% @private
%% Deliberately NOT reported to `bondy_mail_relay`: our queue backing up says
%% nothing about whether the relay is answering, and letting it mark one down
%% would raise a page about our own load.
%%
%% Recorded as SHED rather than as a failure, which is not a wording preference.
%% A status of `failed` leaves the idempotency claim consumed, so a caller who
%% retried with the same key would be handed the recorded failure and nothing
%% would ever be sent -- for a message no relay was ever shown. That is the
%% opposite of what a key asks for. `bondy_mail_status:shed/2` records what
%% happened and leaves the key available to the next request that carries it.
shed({Request, Reply, _}, Reason, #state{relay_name = Name} = State) ->
    Result = {error, {transient, deadline, Reason}},
    ok = bondy_mail_status:shed(Request, Reason),
    ok = bondy_mail_telemetry:rejected(Name, Reason),
    ?LOG_WARNING(#{
        description => "Mail shed from the queue before it was attempted",
        relay => Name,
        worker => State#state.index,
        realm_uri => bondy_mail_request:realm(Request),
        reason => Reason
    }),
    reply(Reply, Result).

%% @private
%% The outcome is recorded before the caller is told, so that a client which
%% reacts to a reply by asking for status cannot beat the write.
run({#bondy_mail_request{} = Request, Reply, _}, Waited) ->
    Started = erlang:monotonic_time(millisecond),
    Name = Request#bondy_mail_request.relay,
    ok = bondy_mail_telemetry:queue(Name, depth(Name), Waited),

    Result = deliver(Request),
    Duration = erlang:monotonic_time(millisecond) - Started,

    ok = bondy_mail_status:update(
        bondy_mail_request:message_id(Request), Result
    ),
    ok = report(Request, Reply, Result, Duration),
    ok = reply(Reply, Result),
    ok.

%% @private
with_relay(#bondy_mail_request{relay = Name}, Fun) ->
    case bondy_mail_config:relay(Name) of
        {ok, Relay} -> Fun(Relay);
        {error, no_such_relay} -> ok
    end.

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
%% Sent to the alias the caller minted, so a reply that arrives after the
%% caller gave up is dropped by the runtime instead of sitting in a mailbox
%% that may outlive it. See bondy_mail:await/2.
reply(undefined, _Result) ->
    ok;
reply({Pid, Ref}, Result) ->
    _ = Pid ! {bondy_mail, Ref, Result},
    ok.

%% @private
deliver(#bondy_mail_request{relay = Name} = Request) ->
    case bondy_mail_config:relay(Name) of
        {ok, Relay} ->
            case bondy_mail_mime:encode(Request, Relay) of
                {ok, Message} ->
                    attempt(Request, Message, Relay, new_retry(Relay), 1);
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
attempt(Request, Message, Relay, Retry0, Attempt) ->
    case expired(Request) of
        true ->
            {error, {transient, deadline, Attempt}};
        false ->
            Mod = Relay#bondy_mail_relay.transport_mod,
            case Mod:send(Request, Message, Relay) of
                {ok, Receipt} ->
                    {ok, #{receipt => Receipt, attempts => Attempt}};
                {error, {permanent, _, _} = Reason} ->
                    {error, Reason};
                {error, {transient, _, _} = Reason} ->
                    retry(Request, Message, Relay, Retry0, Attempt, Reason)
            end
    end.

%% @private
retry(Request, Message, Relay, Retry0, Attempt, Reason) ->
    case bondy_retry:fail(Retry0) of
        {Delay, Retry} when is_integer(Delay) ->
            case sleep_within_deadline(Request, Delay) of
                ok ->
                    ok = log_retry(Request, Attempt, Reason),
                    attempt(Request, Message, Relay, Retry, Attempt + 1);
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
log_retry(Request, Attempt, {_, Class, _}) ->
    Name = bondy_mail_request:relay(Request),
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
