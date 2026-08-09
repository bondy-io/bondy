%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_queue_SUITE).

-moduledoc """
The queue in front of a relay: its bounds, its ordering, and what happens to a
message it cannot deliver.

This is the part of `bondy_mail` that carries the application's central claim --
that a slow or dead relay degrades mail delivery and nothing else -- so it is
tested on its own rather than through the send path that happens to use it.

Every case here is a regression. The queue used to be a `jobs` queue, which is
to say a `gen_server:call/3` with an `infinity` timeout into a single
node-global process shared with the router's own job pool, holding whole
messages in its heap. Replacing it fixed the coupling and, in the same change,
a worker loop that never returned to its mailbox.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_mail/include/bondy_mail.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, ~"com.example.app").

all() ->
    [
        %% Bounds
        message_bound_refuses_transiently,
        byte_bound_refuses_transiently,
        the_bound_is_the_relays_not_one_workers,
        taking_a_message_releases_its_reservation,
        killing_a_worker_does_not_strand_its_reservation,
        %% Ordering
        normal_priority_is_served_before_low,
        %% Shedding
        expired_message_is_shed_and_reported,
        stopping_a_worker_sheds_what_it_held,
        %% Liveness
        a_worker_answers_while_it_is_idle,
        a_worker_reports_its_state_to_sys
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(bondy_regulator),
    {ok, Port} = mock_smtp_server:start(),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    _ = application:stop(bondy_mail),
    ok = mock_smtp_server:stop(),
    ok.

init_per_testcase(_Case, Config) ->
    ok = mock_smtp_server:clear(),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = application:stop(bondy_mail),
    ok.

%% =============================================================================
%% BOUNDS
%% =============================================================================

-doc """
A queue at its message bound refuses immediately, and says so transiently.

Immediately is the point. A caller that blocks on a stalled relay has moved the
stall onto whatever asked to send -- which, for the broker bridge, is a process
delivering router events.
""".
message_bound_refuses_transiently(Config) ->
    ok = start(Config, #{queue_max_size => 2}),
    %% One message occupies the worker for a second; the rest queue behind it.
    ok = mock_smtp_server:latency(1000),

    Results = [async(N) || N <- lists:seq(1, 12)],

    ?assert(lists:any(fun is_queue_full/1, Results)),
    %% And the first few were accepted: a bound that refused everything would
    %% satisfy the assertion above just as well.
    ?assertMatch({ok, _}, hd(Results)).

-doc """
The byte bound refuses even when the message bound has room.

The reason there are two. `queue.max_size` alone says nothing about memory,
because a message may be a hundred bytes or twenty megabytes -- and it was the
byte total, not the message count, that used to decide how much of a shared
process's heap a stalled relay could occupy.
""".
byte_bound_refuses_transiently(Config) ->
    %% Room for a thousand messages, and for about three of these.
    ok = start(Config, #{queue_max_size => 1000, queue_max_bytes => 30000}),
    ok = mock_smtp_server:latency(1000),

    Body = binary:copy(~"a", 10000),
    Results = [
        bondy_mail:send_async(?REALM, (base())#{~"text" => Body})
     || _ <- lists:seq(1, 12)
    ],

    ?assert(lists:any(fun is_queue_full/1, Results)),
    ?assertMatch({ok, _}, hd(Results)).

-doc """
`queue.max_size` bounds the relay, not each of its workers.

The counters are per worker -- which is what makes a stranded reservation
recoverable -- and the bound is the sum of them. Reading it as a single worker's
share would let a relay configured for four hold sixteen, and the same mistake
made in the other direction is what the depth gauge used to publish.

Four workers and a bound of four hold at most eight messages: one in flight per
worker, whose reservation has already been given back, and four waiting. Reading
the bound per worker would hold twenty and refuse none of the twelve below.
""".
the_bound_is_the_relays_not_one_workers(Config) ->
    ok = start(Config, #{pool_size => 4, queue_max_size => 4}),
    ok = mock_smtp_server:latency(2000),

    Results = [async(N) || N <- lists:seq(1, 12)],
    Accepted = [R || {ok, _} = R <- Results],

    ?assert(lists:any(fun is_queue_full/1, Results)),
    ?assertMatch({ok, _}, hd(Results)),
    ?assert(length(Accepted) =< 8).

-doc """
A worker taking a message gives its reservation back.

The counters bound what is *waiting*. A message being delivered is not waiting,
and holding its reservation until delivery finished would make a relay's
effective queue smaller than its configuration says by exactly the number of
workers it has.
""".
taking_a_message_releases_its_reservation(Config) ->
    %% One message at a time, in the queue and in the pool.
    ok = start(Config, #{queue_max_size => 1, pool_size => 1}),

    ?assertMatch({ok, _}, async(1)),
    ok = await_messages(1),

    %% If the reservation had not been released, this would be refused.
    ?assertMatch({ok, _}, async(2)),
    ok = await_messages(2).

-doc """
A worker killed outright does not take the relay's queue bound with it.

`terminate/2` releases what a worker was holding, but there is no `terminate/2`
on this path -- and there is a narrower window with no callback at all, where a
caller resolves a worker's pid and sends to it in the moment after it died. A
message sent to a dead process is dropped by the runtime; the reservation it
holds is reachable by nothing.

A single relay-wide counter would carry that loss for the lifetime of the node,
so a relay bounded at one would refuse everything for ever after one kill, with
no log line and a depth gauge reading zero. The counters are per worker and a
worker zeroes its own pair before it starts, which is what makes this
self-healing rather than a slow, silent leak.
""".
killing_a_worker_does_not_strand_its_reservation(Config) ->
    ok = start(Config, #{queue_max_size => 1, pool_size => 1}),
    Pid = worker(1),

    %% Suspended, so the message is provably still held when the worker dies.
    ok = sys:suspend(Pid),
    {ok, _} = async(1),

    %% `kill` rather than a stop: brutal, so no callback runs and nothing is
    %% released on the way out.
    true = exit(Pid, kill),
    ok = await_worker(1, Pid),

    ?assertMatch({ok, _}, async(2)),
    ok = await_messages(1).

%% =============================================================================
%% ORDERING
%% =============================================================================

-doc """
A `low` priority message waits behind a `normal` one that arrived after it.

`priority` was accepted, documented and inert: every message went into one
queue and the field decided nothing. It decides which lane a message joins, and
a worker absorbs everything already sent to it before choosing the next one --
which is what makes a lane mean anything.
""".
normal_priority_is_served_before_low(Config) ->
    ok = start(Config, #{pool_size => 1}),
    %% Holds the worker while the next two arrive, so both are queued when it
    %% comes to choose between them.
    ok = mock_smtp_server:latency(700),

    ?assertMatch({ok, _}, async(1, ~"first", normal)),
    ok = timer:sleep(100),
    ?assertMatch({ok, _}, async(2, ~"low", low)),
    ?assertMatch({ok, _}, async(3, ~"normal", normal)),

    ok = await_messages(3),
    ?assertEqual(
        [~"first", ~"normal", ~"low"],
        [subject(M) || M <- mock_smtp_server:messages()]
    ).

%% =============================================================================
%% SHEDDING
%% =============================================================================

-doc """
A message that waited longer than `queue.ttl` is shed, and everyone is told.

Shed rather than delivered, because whoever asked for it has long since been
answered by their own deadline. Told rather than dropped, because the queue
this replaced dropped an expired entry inside its own server: a synchronous
caller waited out its full timeout for an answer that was never coming, and the
status record said `queued` until it was swept.

Deliberately not counted against relay health: our queue backing up says
nothing about whether the relay is answering.

Recorded as `shed` rather than `failed`, which is not a wording preference. A
`failed` record holds the caller's idempotency key, so a retry carrying the same
key would be handed the recorded failure and nothing would ever be sent -- for a
message no relay was ever shown. `bondy_mail_status_SUITE` holds that half.
""".
expired_message_is_shed_and_reported(Config) ->
    ok = start(Config, #{pool_size => 1, queue_ttl => 50}),
    ok = mock_smtp_server:latency(600),

    {ok, _} = async(1),
    {ok, #{id := Id}} = async(2),

    ok = await_messages(1),
    ok = await_status(Id, shed),

    %% The first was delivered; the second never reached the relay.
    ?assertEqual(1, length(mock_smtp_server:messages())),

    Info = bondy_mail_status:get(?REALM, Id),
    ?assertEqual(shed, maps:get(status, Info)),
    ?assertEqual(transient, maps:get(nature, Info)),
    ?assertEqual(expired, maps:get(error_class, Info)),

    %% Up, not down: this failure says nothing about the relay.
    {ok, Relay} = bondy_mail_relay:info(~"q"),
    ?assertEqual(up, maps:get(status, Relay)).

-doc """
A worker that stops sheds what it was holding, and gives back the room.

Both halves are the point. Without the reply and the status update a message
would simply cease to exist; without the release, the relay's queue bound would
shrink by exactly what that worker held, permanently, with nothing to say so.

The worker is suspended so the message is provably still in its mailbox rather
than in a lane -- which is the case that is easy to miss, and just as lost.
""".
stopping_a_worker_sheds_what_it_held(Config) ->
    ok = start(Config, #{queue_max_size => 1, pool_size => 1}),
    Pid = worker(1),

    ok = sys:suspend(Pid),
    {ok, #{id := Id}} = async(1),

    ok = sys:terminate(Pid, shutdown),
    ok = await_status(Id, shed),

    ?assertEqual([], mock_smtp_server:messages()),

    %% The supervisor brought a replacement, and the room came back with it:
    %% on a bound of one, a leaked reservation would refuse this for ever.
    %%
    %% Waiting for a DIFFERENT pid, not merely for a pid: `gproc` unregisters a
    %% dead process asynchronously, so the old registration outlives the process
    %% by a moment and "is there a worker" answers yes about a corpse.
    ok = await_worker(1, Pid),
    ?assertMatch({ok, _}, async(2)),
    ok = await_messages(1).

%% =============================================================================
%% LIVENESS
%% =============================================================================

-doc """
An idle worker answers.

It used to not. `handle_continue/2` re-armed `{continue, dequeue}` on every
pass, and `gen_server` dispatches a continuation without receiving anything --
so the process never touched its mailbox, every callback below `handle_continue`
was unreachable, and anything sent to a worker stayed there for ever.

The assertion is not about `ping`. It is that a call to a worker returns at all.
""".
a_worker_answers_while_it_is_idle(Config) ->
    ok = start(Config, #{pool_size => 1}),

    ?assertEqual(
        {error, {unsupported_call, ping}},
        gen_server:call(worker(1), ping, 2000)
    ).

-doc """
A worker serves system messages, so it can be inspected and upgraded.

The same defect as above seen from the other side: `sys:get_state/1` hung, which
also means a release upgrade would have hung on every mail worker on the node.

The assertion is that `sys` is answered at all. Matching the shape of the
worker's private state -- which this used to do -- couples a liveness test to
the field order of a record it cannot see, so adding a field breaks it for a
reason that has nothing to do with what it is testing.
""".
a_worker_reports_its_state_to_sys(Config) ->
    ok = start(Config, #{pool_size => 1}),
    Pid = worker(1),

    ?assertMatch(
        {status, Pid, {module, gen_server}, _}, sys:get_status(Pid, 2000)
    ),
    ?assertEqual(state, element(1, sys:get_state(Pid, 2000))).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
start(Config, Overrides) ->
    Relay = maps:merge(
        #{
            name => ~"q",
            host => ~"127.0.0.1",
            port => ?config(port, Config),
            transport => plain,
            auth => never,
            from => ~"no-reply@example.com",
            realms => any,
            retry_max_attempts => 0,
            queue_ttl => 300000
        },
        Overrides
    ),
    _ = application:stop(bondy_mail),
    ok = application:set_env(bondy_mail, relays, [Relay]),
    ok = application:set_env(bondy_mail, default_relay, undefined),
    {ok, _} = application:ensure_all_started(bondy_mail),
    ok.

%% @private
async(N) ->
    async(N, <<"m", (integer_to_binary(N))/binary>>, normal).

%% @private
async(_N, Subject, Priority) ->
    bondy_mail:send_async(?REALM, (base())#{
        ~"subject" => Subject,
        ~"priority" => Priority
    }).

%% @private
base() ->
    #{
        ~"relay" => ~"q",
        ~"to" => [~"user@example.com"],
        ~"subject" => ~"Hello",
        ~"text" => ~"Body"
    }.

%% @private
is_queue_full({error, {transient, queue_full, _}}) -> true;
is_queue_full(_) -> false.

%% @private
subject(Msg) ->
    maps:get(~"subject", maps:get(headers, Msg), undefined).

%% @private
worker(Index) ->
    gproc:where({n, l, {bondy_mail_worker, ~"q", Index}}).

%% @private
await_worker(Index, Old) ->
    await(
        fun() ->
            case worker(Index) of
                Pid when is_pid(Pid) andalso Pid =/= Old ->
                    is_process_alive(Pid);
                _ ->
                    false
            end
        end,
        {no_worker, Index}
    ).

%% @private
await_messages(N) ->
    await(
        fun() -> length(mock_smtp_server:messages()) >= N end,
        {expected_messages, N}
    ).

%% @private
await_status(Id, Status) ->
    await(
        fun() ->
            maps:get(status, bondy_mail_status:get(?REALM, Id)) == Status
        end,
        {expected_status, Id, Status}
    ).

%% @private
await(Fun, Reason) ->
    await(Fun, Reason, 100).

%% @private
await(_Fun, Reason, 0) ->
    ct:fail(Reason);
await(Fun, Reason, Retries) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            await(Fun, Reason, Retries - 1)
    end.
