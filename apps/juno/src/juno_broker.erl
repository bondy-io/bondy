%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% This module implements the capabilities of a Broker. It is used by
%% {@link juno_router}.

%% Regarding *Publish & Subscribe*, the ordering guarantees are as
%% follows:
%%
%% If _Subscriber A_ is subscribed to both *Topic 1* and *Topic 2*, and
%% _Publisher B_ first publishes an *Event 1* to *Topic 1* and then an
%% *Event 2* to *Topic 2*, then _Subscriber A_ will first receive *Event
%% 1* and then *Event 2*. This also holds if *Topic 1* and *Topic 2* are
%% identical.
%%
%% In other words, WAMP guarantees ordering of events between any given
%% _pair_ of _Publisher_ and _Subscriber_.
%% Further, if _Subscriber A_ subscribes to *Topic 1*, the "SUBSCRIBED"
%% message will be sent by the _Broker_ to _Subscriber A_ before any
%% "EVENT" message for *Topic 1*.
%%
%% There is no guarantee regarding the order of return for multiple
%% subsequent subscribe requests.  A subscribe request might require the
%% _Broker_ to do a time-consuming lookup in some database, whereas
%% another subscribe request second might be permissible immediately.
%%
%% ,---------.          ,------.             ,----------.
%% |Publisher|          |Broker|             |Subscriber|
%% `----+----'          `--+---'             `----+-----'
%%      |                  |                      |
%%      |                  |                      |
%%      |                  |       SUBSCRIBE      |
%%      |                  | <---------------------
%%      |                  |                      |
%%      |                  |  SUBSCRIBED or ERROR |
%%      |                  | --------------------->
%%      |                  |                      |
%%      |                  |                      |
%%      |                  |                      |
%%      |                  |                      |
%%      |                  |      UNSUBSCRIBE     |
%%      |                  | <---------------------
%%      |                  |                      |
%%      |                  | UNSUBSCRIBED or ERROR|
%%      |                  | --------------------->
%% ,----+----.          ,--+---.             ,----+-----.
%% |Publisher|          |Broker|             |Subscriber|
%% `---------'          `------'             `----------'
%% @end
%% =============================================================================
-module(juno_broker).
-include_lib("wamp/include/wamp.hrl").
-include("juno.hrl").


%% API
-export([features/0]).
-export([handle_message/2]).
-export([is_feature_enabled/1]).
-export([close_context/1]).


%% =============================================================================
%% API
%% =============================================================================


-spec close_context(juno_context:context()) -> juno_context:context().
close_context(Ctxt) -> 
    ok = unsubscribe_all(Ctxt),
    Ctxt.


-spec features() -> map().
features() ->
    ?BROKER_FEATURES.


-spec is_feature_enabled(broker_features()) -> boolean().
is_feature_enabled(F) ->
    maps:get(F, ?BROKER_FEATURES).



%% -----------------------------------------------------------------------------
%% @doc
%% Handles a wamp message. This function is called by the juno_router module.
%% The message might be handled synchronously (it is performed by the calling
%% process i.e. the transport handler) or asynchronously (by sending the
%% message to the broker worker pool).
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: message(), Ctxt :: juno_context:context()) -> ok.
handle_message(#subscribe{} = M, Ctxt) ->
    ReqId = M#subscribe.request_id,
    Opts = M#subscribe.options,
    Topic = M#subscribe.topic_uri,
    %% TODO check authorization and reply with wamp.error.not_authorized if not
    {ok, SubsId} = subscribe(Topic, Opts, Ctxt),
    Reply = wamp_message:subscribed(ReqId, SubsId),
    juno:send(Reply, Ctxt);

handle_message(#unsubscribe{} = M, Ctxt) ->
    ReqId = M#unsubscribe.request_id,
    SubsId = M#unsubscribe.subscription_id,
    Reply = case unsubscribe(SubsId, Ctxt) of
        ok -> 
            wamp_message:unsubscribed(ReqId);
        {error, not_found} ->
            wamp_message:error(
                ?UNSUBSCRIBE, ReqId, #{}, ?WAMP_ERROR_NO_SUCH_SUBSCRIPTION
            )
    end,
    juno:send(Reply, Ctxt);

handle_message(#publish{} = M, Ctxt) ->
    %% (RFC) Asynchronously notifies all subscribers of the published event.
    %% Note that the _Publisher_ of an event will never receive the
    %% published event even if the _Publisher_ is also a _Subscriber_ of the
    %% topic published to.
    ReqId = M#publish.request_id,
    Opts = M#publish.options,
    TopicUri = M#publish.topic_uri,
    Args = M#publish.arguments,
    Payload = M#publish.payload,
    Acknowledge = maps:get(acknowledge, Opts, false),
    %% (RFC) By default, publications are unacknowledged, and the _Broker_ will
    %% not respond, whether the publication was successful indeed or not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    case publish(TopicUri, Opts, Args, Payload, Ctxt) of
        {ok, PubId} when Acknowledge == true ->
            Reply = wamp_message:published(ReqId, PubId),
            ok = juno:send(Reply, Ctxt),
            %% TODO publish metaevent
            ok;
        {ok, _} ->
            %% TODO publish metaevent
            ok;
        {error, not_authorized} when Acknowledge == true ->
            Reply = wamp_message:error(
                ?PUBLISH, ReqId, #{}, ?WAMP_ERROR_NOT_AUTHORIZED),
            juno:send(Reply, Ctxt);
        {error, Reason} when Acknowledge == true ->
            Reply = wamp_message:error(
                ?PUBLISH, 
                ReqId, 
                juno:error_dict(Reason), 
                ?WAMP_ERROR_CANCELLED),
            juno:send(Reply, Ctxt);
        {error, _} ->
            ok
    end.






%% =============================================================================
%% PRIVATE
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(uri(), map(), juno_context:context()) -> {ok, id()}.
subscribe(TopicUri, Options, Ctxt) ->
    case juno_registry:add(subscription, TopicUri, Options, Ctxt) of
        {ok, _} = OK -> OK;
        {error, {already_exists, Id}} -> {ok, Id}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe_all(juno_context:context()) -> ok.
unsubscribe_all(Ctxt) ->
    juno_registry:remove_all(subscription, Ctxt).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(id(), juno_context:context()) -> ok | {error, not_found}.
unsubscribe(SubsId, Ctxt) ->
    juno_registry:remove(subscription, SubsId, Ctxt).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Throws not_authorized
%% @end
%% -----------------------------------------------------------------------------
-spec publish(uri(), map(), list(), map(), juno_context:context()) ->
    {ok, id()}.
publish(TopicUri, _Opts, Args, Payload, Ctxt) ->
    SessionId = juno_context:session_id(Ctxt),
    %% TODO check if authorized and if not throw wamp.error.not_authorized
    PubId = wamp_id:new(global),
    Details = #{},
    %% REVIEW We need to parallelise this based on batches
    %% (RFC) When a single event matches more than one of a _Subscriber's_
    %% subscriptions, the event will be delivered for each subscription.

    %% We should not send the publication to the published
    %% (RFC) Note that the _Publisher_ of an event will never
    %% receive the published event even if the _Publisher_ is
    %% also a _Subscriber_ of the topic published to.
    Subs = match_subscriptions(TopicUri, Ctxt, #{exclude => [SessionId]}),
    Fun = fun
        (Entry) ->
            SubsId = juno_registry:entry_id(Entry),
            Session = juno_session:fetch(juno_registry:session_id(Entry)),
            Pid = juno_session:pid(Session),
            Pid ! wamp_message:event(SubsId, PubId, Details, Args, Payload)
    end,
    ok = publish(Subs, Fun),
    {ok, PubId}.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the list of subscriptions for the active session.
%%
%% When called with a juno:context() it is equivalent to calling
%% subscriptions/2 with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(
    ContextOrCont :: juno_context:context() | juno_registry:continuation()) ->
    [juno_registry:entry()].
subscriptions(Ctxt) when is_map(Ctxt) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    SessionId = juno_context:session_id(Ctxt),
    juno_registry:entries(
        subscription, RealmUri, SessionId);

subscriptions(Cont) ->
    juno_registry:entries(Cont).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the complete list of subscriptions matching the RealmUri
%% and SessionId.
%%
%% Use {@link subscriptions/3} and {@link subscriptions/1} to limit the number
%% of subscriptions returned.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(RealmUri :: uri(), SessionId :: id()) ->       
    [juno_registry:entry()].
subscriptions(RealmUri, SessionId) ->
    juno_registry:entries(
        subscription, RealmUri, SessionId, infinity).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the complete list of subscriptions matching the RealmUri
%% and SessionId.
%%
%% Use {@link subscriptions/3} to limit the number of subscriptions returned.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(RealmUri :: uri(), SessionId :: id(), non_neg_integer()) ->
    {[juno_registry:entry()], juno_registry:continuation()}
    | '$end_of_table'.
subscriptions(RealmUri, SessionId, Limit) ->
    juno_registry:entries(
        subscription, RealmUri, SessionId, Limit).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_subscriptions(uri(), juno_context:context()) ->
    [{SessionId :: id(), pid(), SubsId :: id(), Opts :: map()}].
match_subscriptions(TopicUri, Ctxt) ->
    case juno_registry:match(subscription, TopicUri, Ctxt) of
        {L, '$end_of_table'} -> L;
        '$end_of_table' -> []
    end.

%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_subscriptions(
    uri(), juno_context:context(), non_neg_integer()) ->
    {[juno_registry:entry()], juno_registry:continuation()}
    | '$end_of_table'.
match_subscriptions(TopicUri, Ctxt, Opts) ->
    juno_registry:match(subscription, TopicUri, Ctxt, Opts).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_subscriptions(juno_registry:continuation()) ->
    {[juno_registry:entry()], juno_registry:continuation()} | '$end_of_table'.
match_subscriptions(Cont) ->
    ets:select(Cont).



%% @private
publish('$end_of_table', _Fun) ->
    ok;

publish({L, '$end_of_table'}, Fun) ->
    lists:foreach(Fun, L);

publish({L, Cont}, Fun ) ->
    ok = lists:foreach(Fun, L),
    publish(match_subscriptions(Cont), Fun);

publish(L, Fun) when is_list(L) ->
    lists:foreach(Fun, L).
