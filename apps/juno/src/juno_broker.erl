%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
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
-export([close_context/1]).
-export([features/0]).
-export([handle_message/2]).
-export([handle_call/2]).
-export([is_feature_enabled/1]).
-export([match_subscriptions/2]).
-export([publish/5]).
-export([subscriptions/1]).
-export([subscriptions/2]).
-export([subscriptions/3]).


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


-spec is_feature_enabled(binary()) -> boolean().
is_feature_enabled(F) when is_binary(F) ->
    maps:get(F, ?BROKER_FEATURES).



%% -----------------------------------------------------------------------------
%% @doc
%% Handles a wamp message. This function is called by the juno_router module.
%% The message might be handled synchronously (it is performed by the calling
%% process i.e. the transport handler) or asynchronously (by sending the
%% message to the broker worker pool).
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: wamp_message(), Ctxt :: juno_context:context()) -> ok.
handle_message(#subscribe{} = M, Ctxt) ->
    subscribe(M, Ctxt);

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
    juno:send(juno_context:peer_id(Ctxt), Reply);

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
    Acknowledge = maps:get(<<"acknowledge">>, Opts, false),
    %% (RFC) By default, publications are unacknowledged, and the _Broker_ will
    %% not respond, whether the publication was successful indeed or not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    case publish(TopicUri, Opts, Args, Payload, Ctxt) of
        {ok, PubId} when Acknowledge == true ->
            Reply = wamp_message:published(ReqId, PubId),
            ok = juno:send(juno_context:peer_id(Ctxt), Reply),
            %% TODO publish metaevent
            ok;
        {ok, _} ->
            %% TODO publish metaevent
            ok;
        {error, not_authorized} when Acknowledge == true ->
            Reply = wamp_message:error(
                ?PUBLISH, ReqId, #{}, ?WAMP_ERROR_NOT_AUTHORIZED),
            juno:send(juno_context:peer_id(Ctxt), Reply);
        {error, Reason} when Acknowledge == true ->
            Reply = wamp_message:error(
                ?PUBLISH, 
                ReqId, 
                juno:error_map(Reason), 
                ?WAMP_ERROR_CANCELLED),
            juno:send(juno_context:peer_id(Ctxt), Reply);
        {error, _} ->
            ok
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% Handles the following META API wamp calls:
%%
%% * "wamp.subscription.list": Retrieves subscription IDs listed according to match policies.
%% * "wamp.subscription.lookup": Obtains the subscription (if any) managing a topic, according to some match policy.
%% * "wamp.subscription.match": Retrieves a list of IDs of subscriptions matching a topic URI, irrespective of match policy.
%% * "wamp.subscription.get": Retrieves information on a particular subscription.
%% * "wamp.subscription.list_subscribers": Retrieves a list of session IDs for sessions currently attached to the subscription.
%% * "wamp.subscription.count_subscribers": Obtains the number of sessions currently attached to the subscription.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_call(wamp_call(), juno_context:context()) -> ok | no_return().

handle_call(#call{procedure_uri = <<"wamp.subscription.list">>} = M, Ctxt) ->
    %% TODO, BUT This call might be too big, dos not make any sense as it is a dump of the whole database
    Res = #{
        <<"exact">> => [],
        <<"prefix">> => [],
        <<"wildcard">> => []
    },
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.lookup">>} = M, Ctxt) ->
    % #{<<"topic">> := TopicUri} = Args = M#call.arguments,
    % Opts = maps:get(<<"options">>, Args, #{}),
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.match">>} = M, Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.get">>} = M, Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_call(
    #call{procedure_uri = <<"wamp.subscription.list_subscribers">>} = M, 
    Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_call(
    #call{procedure_uri = <<"wamp.subscription.count_subscribers">>} = M, 
    Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M).


%% =============================================================================
%% PRIVATE
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(wamp_subscribe(), juno_context:context()) -> ok.
subscribe(M, Ctxt) ->
    ReqId = M#subscribe.request_id,
    Opts = M#subscribe.options,
    Topic = M#subscribe.topic_uri,
    PeerId = juno_context:peer_id(Ctxt),
    %% TODO check authorization and reply with wamp.error.not_authorized if not

    case juno_registry:add(subscription, Topic, Opts, Ctxt) of
        {ok, #{<<"id">> := Id} = Details, true} ->
            juno:send(PeerId, wamp_message:subscribed(ReqId, Id)),
            on_create(Details, Ctxt);
        {ok, #{<<"id">> := Id}, false} ->
            juno:send(PeerId, wamp_message:subscribed(ReqId, Id)),
            on_subscribe(Id, Ctxt);
        {error, {already_exists, #{id := Id}}} -> 
            juno:send(PeerId, wamp_message:subscribed(ReqId, Id))
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
%% TODO Rename to flush()
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
    case juno_registry:remove(subscription, SubsId, Ctxt) of
        ok ->
            on_unsubscribe(SubsId, Ctxt);
        {ok, false} ->
            on_unsubscribe(SubsId, Ctxt);
        {ok, true} ->
            on_delete(SubsId, Ctxt);
        Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Throws not_authorized
%% @end
%% -----------------------------------------------------------------------------
-spec publish(uri(), map(), list(), map(), juno_context:context()) ->
    {ok, id()}.
publish(TopicUri, _Opts, Args, Payload, Ctxt) ->
    Session = juno_context:session(Ctxt),
    SessionId = juno_session:id(Session),
    %% TODO check if authorized and if not throw wamp.error.not_authorized
    PubId = juno_utils:get_id(global),
    Details = #{}, % TODO
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





%% =============================================================================
%% PRIVATE: META EVENTS
%% =============================================================================



%% @private
on_create(Details, Ctxt) ->
    Map = #{
        <<"session">> => juno_context:session_id(Ctxt), 
        <<"SubscriptionDetails">> => Details
    },
    % TODO Records stats
    {ok, _} = publish(
        <<"wamp.subscription.on_create">>, #{}, [], Map, Ctxt),
    ok.


%% @private
on_subscribe(SubsId, Ctxt) ->
    % TODO Records stats
    on_event(<<"wamp.subscription.on_subscribe">>, SubsId, Ctxt).


%% @private
on_unsubscribe(SubsId, Ctxt) ->
    % TODO Records stats
    on_event(<<"wamp.subscription.on_unsubscribe">>, SubsId, Ctxt).


%% @private
on_delete(SubsId, Ctxt) ->
    % TODO Records stats
    on_event(<<"wamp.subscription.on_delete">>, SubsId, Ctxt).


%% @private
on_event(Uri, SubsId, Ctxt) ->
    Map = #{
        <<"session">> => juno_context:session_id(Ctxt), 
        <<"subscription">> => SubsId
    },
    {ok, _} = publish(Uri, #{}, [], Map, Ctxt),
    ok.