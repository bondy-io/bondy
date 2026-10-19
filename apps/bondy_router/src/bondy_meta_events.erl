%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_meta_events).
-moduledoc """
Demand-gated publication of the WAMP registration/subscription meta
events: `wamp.registration.on_register`, `wamp.registration.on_unregister`,
`wamp.subscription.on_subscribe` and `wamp.subscription.on_unsubscribe`.

Bondy does not publish `on_create` or `on_delete`. WAMP fires them when a URI
gains its first registration or subscription and loses its last. A cluster
cannot decide "first" and "last" for a URI without coordinating its nodes, so
each node would announce its own, and a subscriber would see a URI deleted
while other nodes still serve it. `bondy_meta_events_SUITE` checks that neither
is published. A consumer that needs to know whether a URI has registrations or
subscriptions asks the `wamp.registration.*` and `wamp.subscription.*` meta
procedures.

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
path. Idempotent; called once from `bondy_router_app`.
""".
-spec setup() -> ok.

setup() ->
    _ = warn_ref(),
    ok.

-doc """
Returns `true` when a meta event for `TopicUri` should be produced in
`RealmUri`, according to the `wamp.meta_events` config and — in
`demand` mode — the registry's existence predicate.

Fails open while a registry partition is down: this function then returns
`true`, degrading to the publish path (which routes exactly), never losing a
demanded event. Any other error in the predicate raises.
""".
-spec demanded(RealmUri :: uri(), TopicUri :: uri()) -> boolean().

demanded(RealmUri, TopicUri) ->
    case bondy_config:get(wamp_meta_events, demand) of
        off ->
            false;
        on ->
            true;
        demand ->
            %% While a registry partition is down, `bondy_registry_partition`
            %% has no pool (`badarg`), no connected worker (`function_clause`
            %% on `false`), or no published store (`{badrecord, undefined}`).
            try
                bondy_registry:has_matches(subscription, RealmUri, TopicUri)
            catch
                error:badarg ->
                    true;
                error:function_clause ->
                    true;
                error:{badrecord, undefined} ->
                    true
            end
    end.

-doc """
Publishes the meta event(s) implied by a registration/subscription
lifecycle action, subject to demand.

`Action` is the registry lifecycle action, `added` or `removed`; the meta
topic is derived from it and the entry type.
""".
-spec maybe_publish(
    Action :: added | removed,
    Entry :: bondy_registry_entry:t()
) -> ok.

maybe_publish(Action, Entry) ->
    Type = bondy_registry_entry:type(Entry),
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Topic = topic(Type, Action),

    case demanded(RealmUri, Topic) of
        true ->
            enqueue(Topic, Entry);
        false ->
            ok
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
topic(subscription, added) -> ?WAMP_SUBSCRIPTION_ON_SUBSCRIBE;
topic(subscription, removed) -> ?WAMP_SUBSCRIPTION_ON_UNSUBSCRIBE;
topic(registration, added) -> ?WAMP_REG_ON_REGISTER;
topic(registration, removed) -> ?WAMP_REG_ON_UNREGISTER.

%% @private
%% Builds the publication closure and enqueues it, partition-keyed by
%% session id (per-session meta-event ordering). This is the demanded
%% path only — the closure capture and queue traffic never happen when
%% nobody is subscribed.
enqueue(Topic, Entry) ->
    Type = bondy_registry_entry:type(Entry),
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    SessionId = bondy_registry_entry:session_id(Entry),

    Fun = fun() ->
        ExtSessionId = bondy_router_utils:external_session_id(SessionId),
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        EntryId = bondy_registry_entry:id(Entry),
        Args = [ExtSessionId, EntryId],
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

    PartitionKey = bondy_connect_lib:lazy_or_else(
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
    ok = bondy_telemetry:wamp_dropped(shed, Family),

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
