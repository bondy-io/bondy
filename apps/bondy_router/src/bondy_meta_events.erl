%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_meta_events).
-moduledoc """
Demand-gated publication of the WAMP registration/subscription meta
events (`wamp.registration.on_create`, `wamp.subscription.on_subscribe`,
…).

Per METRICS_GAP_ANALYSIS.md Part III, a meta event is only worth
producing when someone can observe it. `maybe_publish/2` therefore:

1. checks the `wamp.meta_events` config (`demand | on | off`,
   default `demand`);
2. under `demand`, asks the registry's existence predicate
   (`bondy_registry:has_matches/3`) whether any subscription — local or
   remote, exact, prefix or wildcard — matches the concrete meta topic;
3. only then builds the publication closure and enqueues it into the
   `bondy_jobs` pool, partition-keyed by the entry's session id so
   per-session meta-event ordering is preserved.

In the common case (no meta-topic subscribers) the cost per registry
operation is one fail-fast registry probe — no closure, no queue
traffic, no publish machinery. When the jobs pool sheds a demanded
event, the drop is counted in
`bondy_wamp_dropped_total{reason=shed}` and logged (warning at most
once per window). WAMP meta events carry no delivery guarantee;
consumers must snapshot via the `wamp.*.list` meta procedures after
subscribing, which also covers the window between a meta-subscription
commit and a concurrent emitter's demand check.

The aggregate metrics (how many subscriptions/registrations happened)
are NOT produced here — emission sites count them unconditionally via
`bondy_telemetry:registry_event/3` before calling this module.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

%% Minimum seconds between load-shedding warnings; further drops within
%% the window are counted in metrics and logged at debug level only.
-define(SHED_WARN_WINDOW_SECS, 60).
-define(SHED_WARN_KEY, {?MODULE, last_shed_warning}).

%% API
-export([setup/0]).
-export([demanded/2]).
-export([maybe_publish/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Eagerly allocates the shed-warning rate-limit cell at boot, off the shed
path. Idempotent; called once from `bondy_app`.
""".
-spec setup() -> ok.

setup() ->
    _ = warn_ref(),
    ok.

-doc """
Returns `true` when a meta event for `TopicUri` should be produced in
`RealmUri`, according to the `wamp.meta_events` config and — in
`demand` mode — the registry's existence predicate.

Fails open: an error in the predicate returns `true`, degrading to the
publish path (which routes exactly), never losing a demanded event.
""".
-spec demanded(RealmUri :: uri(), TopicUri :: uri()) -> boolean().

demanded(RealmUri, TopicUri) ->
    case bondy_config:get(wamp_meta_events, demand) of
        off ->
            false;
        on ->
            true;
        demand ->
            try
                bondy_registry:has_matches(subscription, RealmUri, TopicUri)
            catch
                _:_ ->
                    true
            end
    end.

-doc """
Publishes the meta event(s) implied by a registration/subscription
lifecycle action, subject to demand.

`Action` is the registry lifecycle action (`created | added | removed |
deleted`); the meta topic is derived from it and the entry type. Each
implied topic is demand-checked independently. Total: never throws.
""".
-spec maybe_publish(
    Action :: created | added | removed | deleted,
    Entry :: bondy_registry_entry:t()
) -> ok.

maybe_publish(Action, Entry) ->
    try
        Type = bondy_registry_entry:type(Entry),
        RealmUri = bondy_registry_entry:realm_uri(Entry),
        Topic = topic(Type, Action),

        case demanded(RealmUri, Topic) of
            true ->
                enqueue(Topic, Action, Entry);
            false ->
                ok
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_DEBUG(#{
                description => "Failed to produce WAMP meta event",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
topic(subscription, created) -> ?WAMP_SUBSCRIPTION_ON_CREATE;
topic(subscription, added) -> ?WAMP_SUBSCRIPTION_ON_SUBSCRIBE;
topic(subscription, removed) -> ?WAMP_SUBSCRIPTION_ON_UNSUBSCRIBE;
topic(subscription, deleted) -> ?WAMP_SUBSCRIPTION_ON_DELETE;
topic(registration, created) -> ?WAMP_REG_ON_CREATE;
topic(registration, added) -> ?WAMP_REG_ON_REGISTER;
topic(registration, removed) -> ?WAMP_REG_ON_UNREGISTER;
topic(registration, deleted) -> ?WAMP_REG_ON_DELETE.

%% @private
%% Builds the publication closure and enqueues it, partition-keyed by
%% session id (per-session meta-event ordering). This is the demanded
%% path only — the closure capture and queue traffic never happen when
%% nobody is subscribed.
enqueue(Topic, Action, Entry) ->
    Type = bondy_registry_entry:type(Entry),
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    SessionId = bondy_registry_entry:session_id(Entry),

    Fun = fun() ->
        ExtSessionId = bondy_utils:external_session_id(SessionId),
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        EntryId = bondy_registry_entry:id(Entry),
        Args =
            case Action == created of
                true ->
                    [
                        ExtSessionId,
                        bondy_registry_entry:to_external(Entry, wamp_meta)
                    ];
                false ->
                    [ExtSessionId, EntryId]
            end,
        KWArgs =
            case Type of
                registration ->
                    #{procedure => bondy_registry_entry:uri(Entry)};
                subscription ->
                    %% https://github.com/wamp-proto/wamp-proto/issues/349
                    #{topic => bondy_registry_entry:uri(Entry)}
            end,
        Ref = bondy_ref:new(internal),
        Ctxt = bondy_context:local_context(RealmUri, Ref),
        bondy_broker:publish(ReqId, #{}, Topic, Args, KWArgs, Ctxt)
    end,

    PartitionKey = bondy_stdlib:lazy_or_else(
        SessionId, fun bondy_wamp_utils:rand_uniform/0
    ),

    case bondy_jobs:enqueue(Fun, PartitionKey) of
        ok ->
            ok;
        {error, full} ->
            on_shed(Type);
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Unexpected error while enqueuing WAMP meta event job",
                reason => Reason,
                topic => Topic
            }),
            ok
    end.

%% @private
%% Counts the shed and warns at most once per window. Runs in the
%% emitting process, so the window timestamp lives in a shared atomics
%% cell (a process-dictionary window would warn once per process and
%% flood under a storm).
on_shed(Family) ->
    ok = bondy_prometheus:report_dropped(shed, Family),

    Now = erlang:monotonic_time(second),

    case should_warn(Now) of
        true ->
            ?LOG_WARNING(#{
                description =>
                    "Dropping WAMP meta events due to load shedding: "
                    "jobs queue at capacity. Subscribers to meta topics "
                    "are missing events; further drops in the next "
                    "window are counted in bondy_wamp_dropped_total "
                    "and logged at debug level.",
                family => Family,
                window_secs => ?SHED_WARN_WINDOW_SECS
            });
        false ->
            ?LOG_DEBUG(#{
                description =>
                    "Dropping WAMP meta event due to load shedding: "
                    "jobs queue at capacity",
                family => Family
            })
    end,
    ok.

%% @private
%% One warning wins per window across all shedding processes: read the
%% last-warn second, and iff a full window has elapsed, CAS it forward.
%% The atomics cell is seeded (see `setup/0`) one window in the past, so
%% the FIRST shed always warns — a plain `0` default would misfire while
%% `erlang:monotonic_time(second)` is still negative (its origin is
%% arbitrary and typically negative early in a node's life).
should_warn(Now) ->
    Ref = warn_ref(),
    Last = atomics:get(Ref, 1),
    Now - Last >= ?SHED_WARN_WINDOW_SECS andalso
        ok == atomics:compare_exchange(Ref, 1, Last, Now).

%% @private
%% The ref is allocated once, eagerly, by `setup/0` at boot — never on
%% the shed path, so a shed storm cannot trigger a `persistent_term:put`
%% (a global GC scan) exactly when the node is already overloaded. The
%% lazy fallback exists only for callers that skip `setup/0` (e.g. unit
%% tests); production always hits the fast `get`.
warn_ref() ->
    case persistent_term:get(?SHED_WARN_KEY, undefined) of
        undefined -> allocate_warn_ref();
        Ref -> Ref
    end.

%% @private
allocate_warn_ref() ->
    Ref = atomics:new(1, []),
    %% Seed one window in the past so the first shed warns regardless of
    %% the monotonic clock's origin.
    ok = atomics:put(
        Ref, 1, erlang:monotonic_time(second) - ?SHED_WARN_WINDOW_SECS - 1
    ),
    ok = persistent_term:put(?SHED_WARN_KEY, Ref),
    Ref.
