%% =============================================================================
%%  bondy_broker.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================


%% =============================================================================
%% @doc
%% This module implements the capabilities of a Broker. It is used by
%% {@link bondy_router}.

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
-module(bondy_broker).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


%% API
-export([close_context/1]).
-export([features/0]).
-export([handle_message/2]).
-export([handle_peer_message/4]).
-export([handle_call/2]).
-export([is_feature_enabled/1]).
-export([match_subscriptions/2]).
-export([publish/5]).
-export([publish/6]).
-export([subscriptions/1]).
-export([subscriptions/3]).
-export([subscriptions/4]).


%% =============================================================================
%% API
%% =============================================================================


-spec close_context(bondy_context:context()) -> bondy_context:context().
close_context(Ctxt) ->
    ok = unsubscribe_all(Ctxt),
    Ctxt.


-spec features() -> map().
features() ->
    ?BROKER_FEATURES.


-spec is_feature_enabled(binary()) -> boolean().

is_feature_enabled(F) when is_binary(F) ->
    maps:get(F, ?BROKER_FEATURES, false).



%% -----------------------------------------------------------------------------
%% @doc
%% Handles a wamp message. This function is called by the bondy_router module.
%% The message might be handled synchronously (it is performed by the calling
%% process i.e. the transport handler) or asynchronously (by sending the
%% message to the broker worker pool).
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: wamp_message(), Ctxt :: bondy_context:context()) -> ok.

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
                ?UNSUBSCRIBE, ReqId, #{}, ?WAMP_NO_SUCH_SUBSCRIPTION
            )
    end,
    bondy:send(bondy_context:peer_id(Ctxt), Reply);

handle_message(#publish{} = M, Ctxt) ->
    %% (RFC) Asynchronously notifies all subscribers of the published event.
    %% Note that the _Publisher_ of an event will never receive the
    %% published event even if the _Publisher_ is also a _Subscriber_ of the
    %% topic published to.
    ReqId = M#publish.request_id,
    Opts = M#publish.options,
    TopicUri = M#publish.topic_uri,
    Args = M#publish.arguments,
    Payload = M#publish.arguments_kw,
    Acknowledge = maps:get(acknowledge, Opts, false),
    %% (RFC) By default, publications are unacknowledged, and the _Broker_ will
    %% not respond, whether the publication was successful indeed or not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    %% We publish first to the local subscribers and if succeed we forward to
    %% cluster peers
    case publish(ReqId, Opts, TopicUri, Args, Payload, Ctxt) of
        {ok, PubId} when Acknowledge == true ->
            Reply = wamp_message:published(ReqId, PubId),
            ok = bondy:send(bondy_context:peer_id(Ctxt), Reply),
            %% TODO publish metaevent
            ok;
        {ok, _} ->
            %% TODO publish metaevent
            ok;
        {error, not_authorized} when Acknowledge == true ->
            Reply = wamp_message:error(
                ?PUBLISH, ReqId, #{}, ?WAMP_NOT_AUTHORIZED),
            bondy:send(bondy_context:peer_id(Ctxt), Reply);
        {error, Reason} when Acknowledge == true ->
            ErrorMap = bondy_error:map(?WAMP_CANCELLED, Reason),
            Reply = wamp_message:error(
                ?PUBLISH,
                ReqId,
                #{},
                ?WAMP_CANCELLED,
                [maps:get(<<"message">>, ErrorMap)],
                ErrorMap
            ),
            bondy:send(bondy_context:peer_id(Ctxt), Reply);
        {error, _} ->
            ok
    end.




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_peer_message(
    wamp_publish(),
    To :: remote_peer_id(),
    From :: remote_peer_id(),
    Opts :: map()) ->
    ok | no_return().

handle_peer_message(#publish{} = M, PeerId, _From,  Opts) ->
    PubId = maps:get(publication_id, Opts),
    RealmUri = RealmUri = element(1, PeerId),
    TopicUri = M#publish.topic_uri,
    Args = M#publish.arguments,
    ArgsKW = M#publish.arguments_kw,
    Subs = match_subscriptions(TopicUri, RealmUri, #{}),

    Node = bondy_peer_service:mynode(),

    Fun = fun(Entry, Acc) ->
        case bondy_registry_entry:node(Entry) of
            Node ->
                %% We publish to a local subscriber
                SubsId = bondy_registry_entry:id(Entry),
                ESessionId = bondy_registry_entry:session_id(Entry),
                ESession = bondy_session:fetch(ESessionId),
                Event = wamp_message:event(SubsId, PubId, Opts, Args, ArgsKW),
                bondy:send(bondy_session:peer_id(ESession), Event),
                maps:update_with(Node, fun(V) -> V + 1 end, 1, Acc);
            _ ->
                %% This is a forwarded PUBLISH so we do not forward it
                Acc
        end
    end,
    _Acc1 = publish_fold(Subs, Fun, #{}),
    ok.



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
-spec handle_call(wamp_call(), bondy_context:context()) -> ok | no_return().

handle_call(#call{procedure_uri = <<"wamp.subscription.list">>} = M, Ctxt) ->
    %% TODO, BUT This call might be too big, dos not make any sense as it is a dump of the whole database
    Res = #{
        ?EXACT_MATCH => [],
        ?PREFIX_MATCH=> [],
        ?WILDCARD_MATCH => []
    },
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.lookup">>} = M, Ctxt) ->
    % #{<<"topic">> := TopicUri} = Args = M#call.arguments,
    % Opts = maps:get(<<"options">>, Args, #{}),
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.match">>} = M, Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.get">>} = M, Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M);

handle_call(
    #call{procedure_uri = <<"wamp.subscription.list_subscribers">>} = M,
    Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M);

handle_call(
    #call{procedure_uri = <<"wamp.subscription.count_subscribers">>} = M,
    Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
publish(Opts, TopicUri, Args, Payload, Ctxt) ->
    publish(bondy_utils:get_id(global), Opts, TopicUri, Args, Payload, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% Throws not_authorized
%% @end
%% -----------------------------------------------------------------------------
-spec publish(id(), map(), uri(), list(), map(), bondy_context:context()) ->
    {ok, id()}.

publish(ReqId, Opts, TopicUri, Args, Payload, Ctxt) ->
    %% TODO check if authorized and if not throw wamp.error.not_authorized

    %% REVIEW We need to parallelise this based on batches
    %% (RFC) When a single event matches more than one of a _Subscriber's_
    %% subscriptions, the event will be delivered for each subscription.

    %% We should not send the publication to the published, so we exclude it
    %% (RFC) Note that the _Publisher_ of an event will never
    %% receive the published event even if the _Publisher_ is
    %% also a _Subscriber_ of the topic published to.
    MatchOpts = case maps:get(exclude_me, Opts, true) of
        true -> #{exclude => [bondy_context:session_id(Ctxt)]};
        false -> #{}
    end,
    RealmUri = bondy_context:realm_uri(Ctxt),
    Subs = match_subscriptions(TopicUri, RealmUri, MatchOpts),
    Node = bondy_peer_service:mynode(),
    PubId = bondy_utils:get_id(global),

    Fun = fun(Entry, Acc) ->
        case bondy_registry_entry:node(Entry) of
            Node ->
                %% We publish to a local subscriber
                SubsId = bondy_registry_entry:id(Entry),
                ESessionId = bondy_registry_entry:session_id(Entry),
                ESession = bondy_session:fetch(ESessionId),
                Event = wamp_message:event(SubsId, PubId, Opts, Args, Payload),
                bondy:send(bondy_session:peer_id(ESession), Event),
                maps:update_with(Node, fun(V) -> V + 1 end, 1, Acc);
            Other ->
                %% We just acummulate the subscribers per peer, later we will
                %% forward a single message to each peer.
                maps:update_with(Other, fun(V) -> V + 1 end, 1, Acc)
        end
    end,

    %% We send the event to the subscribers
    Acc1 = publish_fold(Subs, Fun, #{}),

    %% If we have remote subscribers we forward the publication
    Nodes = maps:keys(Acc1) -- [Node],
    ok = case length(Nodes) > 0 of
        true ->
            M = wamp_message:publish(ReqId, Opts, TopicUri, Args, Payload),
            %% We also forward the PubId
            FOpts = #{publication_id => PubId},
            forward_publication(Nodes, M, FOpts, Ctxt);
        false ->
            ok
    end,
    {ok, PubId}.



%% =============================================================================
%% PRIVATE
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(wamp_subscribe(), bondy_context:context()) -> ok.

subscribe(M, Ctxt) ->
    ReqId = M#subscribe.request_id,
    Opts = M#subscribe.options,
    Topic = M#subscribe.topic_uri,
    PeerId = bondy_context:peer_id(Ctxt),
    %% TODO check authorization and reply with wamp.error.not_authorized if not

    case bondy_registry:add(subscription, Topic, Opts, Ctxt) of
        {ok, #{id := Id} = Details, true} ->
            bondy:send(PeerId, wamp_message:subscribed(ReqId, Id)),
            on_create(Details, Ctxt);
        {ok, #{id := Id}, false} ->
            bondy:send(PeerId, wamp_message:subscribed(ReqId, Id)),
            on_subscribe(Id, Ctxt);
        {error, {already_exists, #{id := Id}}} ->
            bondy:send(PeerId, wamp_message:subscribed(ReqId, Id))
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
%% TODO Rename to flush()
-spec unsubscribe_all(bondy_context:context()) -> ok.

unsubscribe_all(Ctxt) ->
    bondy_registry:remove_all(subscription, Ctxt).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(id(), bondy_context:context()) -> ok | {error, not_found}.

unsubscribe(SubsId, Ctxt) ->
    case bondy_registry:remove(subscription, SubsId, Ctxt) of
        ok ->
            on_unsubscribe(SubsId, Ctxt);
        {ok, false} ->
            on_unsubscribe(SubsId, Ctxt);
        {ok, true} ->
            on_delete(SubsId, Ctxt);
        Error ->
            Error
    end.



%% @private
forward_publication(Nodes, #publish{} = M, Opts, Ctxt) ->
    %% We forward the publication to all cluster peers.
    %% @TODO stop replicating individual remote subscribers and instead
    %% use a per node reference counter
    RealmUri = bondy_context:realm_uri(Ctxt),
    {ok, Good, Bad} = bondy_peer_wamp_forwarder:broadcast(
        RealmUri, Nodes, M, Opts),

    Nodes =:= Good orelse
    bondy_utils:log(
        error,
        "Publication broadcast failed; good_nodes=~p, bad_nodes=~p",
        [Good, Bad],
        M,
        Ctxt
    ),

    ok.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the list of subscriptions for the active session.
%%
%% When called with a bondy:context() it is equivalent to calling
%% subscriptions/2 with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(bondy_registry:continuation()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

subscriptions({subscription, _} = Cont) ->
    bondy_registry:entries(Cont).


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
-spec subscriptions(RealmUri :: uri(), Node :: atom(), SessionId :: id()) ->
    [bondy_registry_entry:t()].

subscriptions(RealmUri, Node, SessionId) ->
    bondy_registry:entries(subscription, RealmUri, Node, SessionId).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the complete list of subscriptions matching the RealmUri
%% and SessionId.
%%
%% Use {@link subscriptions/3} to limit the number of subscriptions returned.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(
    RealmUri :: uri(), Node :: atom(),SessionId :: id(), non_neg_integer()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

subscriptions(RealmUri, Node, SessionId, Limit) ->
    bondy_registry:entries(
        subscription, RealmUri, Node, SessionId, Limit).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_subscriptions(uri(), RealmUri :: uri()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

match_subscriptions(TopicUri, RealmUri) ->
    bondy_registry:match(subscription, TopicUri, RealmUri).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_subscriptions(uri(), RealmUri :: uri(), non_neg_integer()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

match_subscriptions(TopicUri, RealmUri, Opts) ->
    bondy_registry:match(subscription, TopicUri, RealmUri, Opts).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_subscriptions(bondy_registry:continuation()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

match_subscriptions(Cont) ->
    ets:select(Cont).


%% @private
publish_fold({[], ?EOT}, _Fun, Acc) ->
    Acc;

publish_fold({L, ?EOT}, Fun, Acc) ->
    publish_fold(L, Fun, Acc);

publish_fold({L, Cont}, Fun, Acc0) ->
    Acc1 = publish_fold(L, Fun, Acc0),
    publish_fold(match_subscriptions(Cont), Fun, Acc1);

publish_fold([H|T], Fun, Acc) ->
    publish_fold(T, Fun, Fun(H, Acc));

publish_fold([], Fun, Acc) when is_function(Fun, 2) ->
    Acc.


%% =============================================================================
%% PRIVATE: META EVENTS
%% =============================================================================



%% @private
on_create(Details, Ctxt) ->
    Map = #{
        <<"session">> => bondy_context:session_id(Ctxt),
        <<"subscriptionDetails">> => Details
    },
    % TODO Records stats
    _ = publish(#{}, <<"wamp.subscription.on_create">>, [], Map, Ctxt),
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
        <<"session">> => bondy_context:session_id(Ctxt),
        <<"subscription">> => SubsId
    },
    _ = publish(#{}, Uri, [], Map, Ctxt),
    ok.