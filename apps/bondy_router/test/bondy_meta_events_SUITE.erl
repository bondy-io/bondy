%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_meta_events_SUITE).
-moduledoc """
End-to-end checks of demand-gated WAMP meta events (bondy_meta_events +
bondy_registry:has_matches/3, METRICS_GAP_ANALYSIS.md Part III): the
demand predicate under every match policy, unconditional aggregate
counting, delivery when demanded, and the `wamp.meta_events` config
knob.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-define(REALM, <<"com.test.meta.events">>).
-define(ON_SUBSCRIBE, ?WAMP_SUBSCRIPTION_ON_SUBSCRIBE).

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).

-export([predicate_reflects_subscriptions/1]).
-export([aggregates_counted_unconditionally/1]).
-export([delivery_with_subscribers/1]).
-export([config_off_silences/1]).
-export([realm_meta_events_published/1]).

all() ->
    [
        predicate_reflects_subscriptions,
        aggregates_counted_unconditionally,
        delivery_with_subscribers,
        config_off_silences,
        realm_meta_events_published
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    _ = bondy_realm:create(?REALM),
    Config.

end_per_suite(Config) ->
    ok = bondy_config:set(wamp_meta_events, demand),
    {save_config, Config}.

%% =============================================================================
%% CASES
%% =============================================================================

predicate_reflects_subscriptions(_) ->
    %% Fresh realm: no meta subscribers.
    false = bondy_registry:has_matches(subscription, ?REALM, ?ON_SUBSCRIBE),

    %% Exact
    {ok, Id1} = subscribe(#{}, ?ON_SUBSCRIBE),
    true = bondy_registry:has_matches(subscription, ?REALM, ?ON_SUBSCRIBE),
    %% A subscriber to one meta topic does not demand another.
    false = bondy_registry:has_matches(
        subscription, ?REALM, ?WAMP_REG_ON_REGISTER
    ),
    ok = bondy_broker:unsubscribe(Id1, ?REALM),
    false = bondy_registry:has_matches(subscription, ?REALM, ?ON_SUBSCRIBE),

    %% Prefix (a `wamp.` subscriber demands every wamp.* meta topic)
    {ok, Id2} = subscribe(
        #{match => ?PREFIX_MATCH}, <<"wamp.">>
    ),
    true = bondy_registry:has_matches(subscription, ?REALM, ?ON_SUBSCRIBE),
    true = bondy_registry:has_matches(
        subscription, ?REALM, ?WAMP_REG_ON_REGISTER
    ),
    ok = bondy_broker:unsubscribe(Id2, ?REALM),
    false = bondy_registry:has_matches(subscription, ?REALM, ?ON_SUBSCRIBE),

    %% Wildcard
    {ok, Id3} = subscribe(
        #{match => ?WILDCARD_MATCH}, <<"wamp..on_subscribe">>
    ),
    true = bondy_registry:has_matches(subscription, ?REALM, ?ON_SUBSCRIBE),
    false = bondy_registry:has_matches(
        subscription, ?REALM, ?WAMP_SUBSCRIPTION_ON_CREATE
    ),
    ok = bondy_broker:unsubscribe(Id3, ?REALM),
    false = bondy_registry:has_matches(subscription, ?REALM, ?ON_SUBSCRIBE),

    %% Realm isolation: another realm's subscriber creates no demand here.
    false = bondy_registry:has_matches(
        subscription, <<"com.leapsight.bondy">>, ?ON_SUBSCRIBE
    ),
    ok.

aggregates_counted_unconditionally(_) ->
    %% No meta subscribers exist, yet the aggregate counters advance.
    Node = bondy_config:node(),
    Label = fun(Action) ->
        #{node => Node, realm => ?REALM, type => subscription, action => Action}
    end,
    Created0 = counter_value(bondy_registry_events_total, Label(created)),
    Added0 = counter_value(bondy_registry_events_total, Label(added)),
    Removed0 = counter_value(bondy_registry_events_total, Label(removed)),

    Topic = <<"com.test.meta.app.aggregates">>,
    {ok, Id} = subscribe(#{}, Topic),

    %% The sink is inline and wait-free — visible immediately.
    true =
        counter_value(bondy_registry_events_total, Label(created)) ==
            Created0 + 1,
    true =
        counter_value(bondy_registry_events_total, Label(added)) ==
            Added0 + 1,

    ok = bondy_broker:unsubscribe(Id, ?REALM),
    true =
        counter_value(bondy_registry_events_total, Label(removed)) ==
            Removed0 + 1,
    ok.

delivery_with_subscribers(_) ->
    %% Exact meta subscriber receives on_subscribe for later subscriptions.
    {ok, MetaId} = subscribe(#{}, ?ON_SUBSCRIBE),
    ok = flush_events(),

    Topic = <<"com.test.meta.app.delivery">>,
    {ok, AppId} = subscribe(#{}, Topic),
    #event{subscription_id = MetaId} = await_event(5000),

    ok = bondy_broker:unsubscribe(AppId, ?REALM),
    %% The unsubscribe is not demanded (no on_unsubscribe subscriber), so
    %% nothing else arrives.
    ok = assert_no_event(300),

    %% Prefix meta subscriber.
    {ok, PrefixId} = subscribe(
        #{match => ?PREFIX_MATCH}, <<"wamp.subscription.">>
    ),
    ok = flush_events(),
    {ok, AppId2} = subscribe(
        #{}, <<"com.test.meta.app.delivery2">>
    ),
    %% Both the exact and the prefix subscriber match on_subscribe; we
    %% receive at least one event for our two subscriptions.
    #event{} = await_event(5000),

    ok = bondy_broker:unsubscribe(AppId2, ?REALM),
    ok = bondy_broker:unsubscribe(PrefixId, ?REALM),
    ok = bondy_broker:unsubscribe(MetaId, ?REALM),
    ok = flush_events(),
    ok.

config_off_silences(_) ->
    {ok, MetaId} = subscribe(#{}, ?ON_SUBSCRIBE),
    ok = flush_events(),

    ok = bondy_config:set(wamp_meta_events, off),
    {ok, AppId} = subscribe(
        #{}, <<"com.test.meta.app.off">>
    ),
    ok = assert_no_event(500),

    ok = bondy_config:set(wamp_meta_events, demand),
    {ok, AppId2} = subscribe(
        #{}, <<"com.test.meta.app.on_again">>
    ),
    #event{subscription_id = MetaId} = await_event(5000),

    ok = bondy_broker:unsubscribe(AppId, ?REALM),
    ok = bondy_broker:unsubscribe(AppId2, ?REALM),
    ok = bondy_broker:unsubscribe(MetaId, ?REALM),
    ok.

realm_meta_events_published(_) ->
    %% Regression: bondy_event_wamp_publisher's realm clause matched
    %% `[bondy, realm, created, Type]` while the emitted path is
    %% `[bondy, realm, Type]`, so the bondy.realm.* meta events were
    %% silently never published (breaking e.g. the HTTP gateway's
    %% realm-deleted cleanup subscription).
    Master = <<"com.leapsight.bondy">>,
    Ref = bondy_ref:new(internal, self(), bondy_session_id:new()),
    {ok, SubId} = bondy_broker:subscribe(
        Master, #{}, ?BONDY_REALM_CREATED, Ref
    ),

    Uri = <<"com.test.meta.events.realmpub">>,
    _ = bondy_realm:create(Uri),

    receive
        {?BONDY_REQ, _, Master, #event{subscription_id = SubId} = Event} ->
            [Uri] = Event#event.args
    after 5000 ->
        error(realm_meta_event_timeout)
    end,
    ok = bondy_broker:unsubscribe(SubId, Master),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Internal subscription with a session-scoped ref (the pid-only variant
%% builds a ref without a session id, which the registry rejects).
subscribe(Opts, Topic) ->
    Ref = bondy_ref:new(internal, self(), bondy_session_id:new()),
    bondy_broker:subscribe(?REALM, Opts, Topic, Ref).

%% @private
counter_value(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        undefined -> 0;
        V -> V
    end.

%% @private
%% Internal (pid) subscriptions receive events as bondy requests.
await_event(TimeoutMs) ->
    receive
        {?BONDY_REQ, _Pid, ?REALM, #event{} = Event} ->
            Event
    after TimeoutMs ->
        error(await_event_timeout)
    end.

%% @private
assert_no_event(WaitMs) ->
    receive
        {?BONDY_REQ, _Pid, ?REALM, #event{} = Event} ->
            error({unexpected_event, Event})
    after WaitMs ->
        ok
    end.

%% @private
flush_events() ->
    %% Meta events are published async through the jobs pool; give the
    %% in-flight ones a moment, then drain the mailbox.
    timer:sleep(300),
    do_flush().

%% @private
do_flush() ->
    receive
        {?BONDY_REQ, _, _, _} -> do_flush()
    after 0 ->
        ok
    end.
