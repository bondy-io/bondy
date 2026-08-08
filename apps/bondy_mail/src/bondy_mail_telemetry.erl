%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_telemetry).

-moduledoc """
Telemetry events and metric families for `bondy_mail`.

Follows `bondy_http_connector_telemetry`: flat three-segment event names with
no `start`/`stop` suffix, scalar-only metadata, every emitter total, every sink
write total, and families declared in the module that populates them. This
module owns both emission and sink, which the router deliberately splits --
router events fire on every WAMP message, and these fire once per message
handed to a relay.

## The realm is in the events and not in the labels

Relay names come from `bondy.conf` and are bounded by it. Realms are not: a
large deployment has thousands, and a realm label would multiply every family
by that cardinality. So `realm` travels in telemetry metadata, where a consumer
that wants per-realm attribution can attach its own handler, and never reaches
a metric label. Per-realm attribution otherwise lives in the logs.

This mirrors the existing split where a `_total` counter carries an outcome
label and its paired duration histogram drops it.

## What is measured, and from when

Two clocks, because they answer different questions:

- `bondy_mail_queue_wait_milliseconds` is how long a message sat in front of a
  worker. It rises when a relay is saturated.
- `bondy_mail_send_duration_milliseconds` is how long the SMTP conversation
  took once a worker had it, including retries and the backoff between them. It
  rises when a relay is slow.

A single end-to-end number would move for either reason and distinguish
neither.

## Queue depth is counted, not asked for

`jobs:queue_info/2` is a call into the `jobs` server. Asking it per message
would put a shared process on the path of every send -- the exact coupling this
application exists to avoid. Depth is instead an `atomics` counter on the
relay's own record, incremented when a message is queued and decremented when a
worker takes it.

## Help strings are ASCII

They are rendered latin-1 on the way out, so a single em-dash or curly quote in
one of them stops the node booting. Hyphens only.
""".

-include_lib("kernel/include/logger.hrl").
-include("bondy_mail.hrl").

%% API
-export([accepted/3]).
-export([dead_letter/3]).
-export([failed/5]).
-export([init/0]).
-export([queue/3]).
-export([rate_limited/2]).
-export([rejected/2]).
-export([relay_status/2]).
-export([retried/2]).
-export([sent/4]).

%% TELEMETRY SINK, exported for telemetry:attach_many/4
-export([handle_event/4]).

-define(EVENTS, [
    [bondy, mail, accepted],
    [bondy, mail, sent],
    [bondy, mail, retried],
    [bondy, mail, failed],
    [bondy, mail, dead_letter],
    [bondy, mail, rate_limited],
    [bondy, mail, queue],
    [bondy, mail, rejected],
    [bondy, mail, relay_status]
]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Declare the metric families and attach the sink.

Called once from `bondy_mail_app:start/2`, including on a node with no relay
configured, so that the help text and type are registered whether or not this
node ever sends anything.

Declaring does not make a family appear in the exposition:
`bondy_prometheus_collector` skips a declared family with no rows, so a family
is scraped from its first write onwards. That is why `bondy_mail_relay` writes
`bondy_mail_relay_up` when it starts rather than waiting for traffic -- an
operator looking at a freshly booted node should see its relays, not an empty
table.
""".
-spec init() -> ok.

init() ->
    ok = declare_families(),
    Handler = fun ?MODULE:handle_event/4,
    case telemetry:attach_many(?MODULE, ?EVENTS, Handler, undefined) of
        ok -> ok;
        {error, already_exists} -> ok
    end.

%% @private
%% Declaration is best effort, and deliberately so.
%%
%% `bondy_metrics` declares no `{mod, _}`, so starting the application does not
%% start its registry -- a supervisor elsewhere does. Listing it as a dependency
%% therefore guarantees nothing about whether it is running when this is called.
%% An application that failed to start because a counter could not be described
%% would be an application that stops delivering mail when the thing watching it
%% is unavailable, which is exactly backwards.
%%
%% Warned rather than debugged, because a node running without its mail families
%% renders empty panels and an operator should be able to find out why from the
%% log rather than by reading this comment.
declare_families() ->
    try
        do_declare_families()
    catch
        Class:Reason ->
            ?LOG_WARNING(#{
                description =>
                    "Could not declare mail metric families, continuing "
                    "without them. Mail delivery is unaffected.",
                class => Class,
                reason => Reason
            }),
            ok
    end.

-doc """
A message passed validation, authorization and rate limiting, and is about to
be queued.

`Surface` is who asked -- `rpc` or `bridge`. It is attribution only: neither
surface is granted anything the other is not, and the value is set by the
caller inside Bondy rather than by anything a peer sends.
""".
-spec accepted(
    Relay :: binary(), Realm :: binary(), Surface :: atom()
) -> ok.

accepted(Relay, Realm, Surface) ->
    execute(
        [bondy, mail, accepted],
        #{count => 1},
        #{relay => Relay, realm => Realm, surface => Surface}
    ).

-doc "A relay accepted a message. `Duration` is the delivery, not the wait.".
-spec sent(
    Relay :: binary(),
    Realm :: binary(),
    Attempts :: pos_integer(),
    Duration :: integer()
) -> ok.

sent(Relay, Realm, Attempts, Duration) ->
    execute(
        [bondy, mail, sent],
        #{duration => max(0, Duration)},
        #{relay => Relay, realm => Realm, attempts => Attempts}
    ).

-doc "A transient failure is about to be retried.".
-spec retried(Relay :: binary(), ReasonClass :: atom()) -> ok.

retried(Relay, ReasonClass) ->
    execute(
        [bondy, mail, retried],
        #{count => 1},
        #{relay => Relay, reason_class => ReasonClass}
    ).

-doc """
Delivery failed and will not be attempted again.

`Nature` is `permanent` or `transient` -- the single number that tells an
operator whether to page someone or wait. A transient failure reaching here has
exhausted its attempt budget or its deadline.
""".
-spec failed(
    Relay :: binary(),
    Realm :: binary(),
    Nature :: permanent | transient,
    ReasonClass :: atom(),
    Duration :: integer()
) -> ok.

failed(Relay, Realm, Nature, ReasonClass, Duration) ->
    execute(
        [bondy, mail, failed],
        #{duration => max(0, Duration)},
        #{
            relay => Relay,
            realm => Realm,
            nature => Nature,
            reason_class => ReasonClass
        }
    ).

-doc """
A message failed with nobody waiting to be told.

That is what makes it dead rather than merely failed: a synchronous caller
receives the error and decides what to do, while a fire-and-forget message --
every message the bridge sends -- has no one to receive it, so this event and
the log line beside it are the only record it existed.

Republishing it into the router as a dead-letter topic is deliberately not
offered: that would put mail failures back onto the routing plane, which is the
coupling this application exists to avoid.
""".
-spec dead_letter(
    Relay :: binary(), Realm :: binary(), ReasonClass :: atom()
) -> ok.

dead_letter(Relay, Realm, ReasonClass) ->
    execute(
        [bondy, mail, dead_letter],
        #{count => 1},
        #{relay => Relay, realm => Realm, reason_class => ReasonClass}
    ).

-doc "A message was refused by the relay's rate limiter.".
-spec rate_limited(Relay :: binary(), Realm :: binary()) -> ok.

rate_limited(Relay, Realm) ->
    execute(
        [bondy, mail, rate_limited],
        #{count => 1},
        #{relay => Relay, realm => Realm}
    ).

-doc """
A worker took a message off a queue.

`Depth` is what was left behind, and `Wait` is how long this one sat there.
""".
-spec queue(
    Relay :: binary(), Depth :: integer(), Wait :: integer()
) -> ok.

queue(Relay, Depth, Wait) ->
    execute(
        [bondy, mail, queue],
        #{depth => max(0, Depth), wait => max(0, Wait)},
        #{relay => Relay}
    ).

-doc """
A message was refused before reaching a worker.

`Reason` is `queue_full`, `not_permitted` or `oversized`. Distinct from
`failed/5`, which is a relay declining a message it was shown: nothing here was
ever offered to a relay.
""".
-spec rejected(Relay :: binary(), Reason :: atom()) -> ok.

rejected(Relay, Reason) ->
    execute(
        [bondy, mail, rejected],
        #{count => 1},
        #{relay => Relay, reason => Reason}
    ).

-doc "A relay's health changed.".
-spec relay_status(Relay :: binary(), Status :: up | down) -> ok.

relay_status(Relay, Status) ->
    execute(
        [bondy, mail, relay_status],
        #{count => 1},
        #{relay => Relay, status => Status}
    ).

%% =============================================================================
%% TELEMETRY SINK
%% =============================================================================

-doc false.
handle_event([bondy, mail, accepted], _Meas, Meta, _Config) ->
    #{relay := Relay, surface := Surface} = Meta,
    counter(bondy_mail_accepted_total, #{relay => Relay, surface => Surface});
handle_event([bondy, mail, sent], #{duration := D}, Meta, _Config) ->
    #{relay := Relay} = Meta,
    counter(bondy_mail_sent_total, #{relay => Relay}),
    histogram(bondy_mail_send_duration_milliseconds, #{relay => Relay}, D);
handle_event([bondy, mail, retried], _Meas, Meta, _Config) ->
    #{relay := Relay, reason_class := Class} = Meta,
    counter(bondy_mail_retried_total, #{relay => Relay, reason_class => Class});
handle_event([bondy, mail, failed], #{duration := D}, Meta, _Config) ->
    #{relay := Relay, nature := Nature, reason_class := Class} = Meta,
    counter(bondy_mail_failed_total, #{
        relay => Relay, nature => Nature, reason_class => Class
    }),
    %% The same histogram as a success: a relay that is slow to refuse is as
    %% much of a problem as one that is slow to accept, and splitting them
    %% hides the failures inside a healthy-looking p95.
    histogram(bondy_mail_send_duration_milliseconds, #{relay => Relay}, D);
handle_event([bondy, mail, dead_letter], _Meas, Meta, _Config) ->
    #{relay := Relay, reason_class := Class} = Meta,
    counter(bondy_mail_dead_letter_total, #{
        relay => Relay, reason_class => Class
    });
handle_event([bondy, mail, rate_limited], _Meas, Meta, _Config) ->
    #{relay := Relay} = Meta,
    counter(bondy_mail_rate_limited_total, #{relay => Relay});
handle_event([bondy, mail, queue], Measurements, Meta, _Config) ->
    #{depth := Depth, wait := Wait} = Measurements,
    #{relay := Relay} = Meta,
    gauge(bondy_mail_queue_depth, #{relay => Relay}, Depth),
    histogram(bondy_mail_queue_wait_milliseconds, #{relay => Relay}, Wait);
handle_event([bondy, mail, rejected], _Meas, Meta, _Config) ->
    #{relay := Relay, reason := Reason} = Meta,
    counter(bondy_mail_rejected_total, #{relay => Relay, reason => Reason});
handle_event([bondy, mail, relay_status], _Meas, Meta, _Config) ->
    #{relay := Relay, status := Status} = Meta,
    gauge(bondy_mail_relay_up, #{relay => Relay}, up_value(Status));
handle_event(_Event, _Measurements, _Meta, _Config) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
up_value(up) -> 1;
up_value(down) -> 0.

%% @private
counter(Name, Label) ->
    safe(fun() -> bondy_metrics:counter(#{name => Name, label => Label}) end).

%% @private
gauge(Name, Label, Value) ->
    safe(fun() ->
        bondy_metrics:gauge(#{name => Name, label => Label, value => Value})
    end).

%% @private
histogram(Name, Label, Value) ->
    safe(fun() ->
        bondy_metrics:histogram(#{name => Name, label => Label, value => Value})
    end).

%% @private
do_declare_families() ->
    ok = bondy_metrics:declare(#{
        name => bondy_mail_accepted_total,
        help =>
            ~"Total messages accepted for delivery, by relay and surface (rpc | bridge). Accepted means validated, authorized and queued - not delivered."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_mail_sent_total,
        help => ~"Total messages a relay accepted, by relay."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_mail_failed_total,
        help =>
            ~"Total messages that will not be delivered, by relay, nature (permanent | transient) and error class. A transient failure counted here has exhausted its attempts or its deadline."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_mail_retried_total,
        help =>
            ~"Total delivery retries, by relay and error class. Only transient failures are retried."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_mail_dead_letter_total,
        help =>
            ~"Total failed messages with no caller waiting to be told, by relay and error class. Every message sent by the broker bridge is in this category if it fails."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_mail_rate_limited_total,
        help =>
            ~"Total messages refused by a relay's rate limiter, by relay."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_mail_rejected_total,
        help =>
            ~"Total messages refused before reaching a worker, by relay and reason (queue_full | not_permitted | oversized). Nothing counted here was offered to a relay."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_mail_send_duration_milliseconds,
        help =>
            ~"Duration of the SMTP conversation once a worker had the message, including retries and the backoff between them, by relay. Excludes time spent queued."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_mail_queue_wait_milliseconds,
        help =>
            ~"Time a message spent queued in front of a relay worker, by relay."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_mail_queue_depth,
        help =>
            ~"Messages queued for a relay and not yet taken by a worker, by relay."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_mail_relay_up,
        help =>
            ~"1 when a relay's recent deliveries are succeeding, 0 when consecutive transient failures have marked it down. Permanent failures do not change this: a rejected recipient says nothing about the relay."
    }),
    ok.

%% @private
%% Total wrapper for sink writes: a raising `bondy_metrics` call must not
%% detach this handler, which would silently kill every family it renders.
safe(Fun) ->
    try
        _ = Fun(),
        ok
    catch
        Class:Reason:Stacktrace ->
            ?LOG_DEBUG(#{
                description => "Failed to record mail metric",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% @private
%% Total wrapper: an emitter must never affect the caller. A send does not fail
%% because something went wrong counting it.
execute(Event, Measurements, Meta) ->
    try
        telemetry:execute(Event, Measurements, Meta)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_DEBUG(#{
                description => "Failed to emit telemetry event",
                event => Event,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.
