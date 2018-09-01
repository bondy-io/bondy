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
-export([is_feature_enabled/1]).
-export([match_subscriptions/2]).
-export([publish/5]).
-export([publish/6]).
-export([subscriptions/1]).
-export([subscriptions/3]).
-export([subscriptions/4]).
-export([subscribe/4]).
-export([unsubscribe/1]).


%% =============================================================================
%% API
%% =============================================================================


-spec close_context(bondy_context:t()) -> bondy_context:t().
close_context(Ctxt) ->
    try
        %% Cleanup subscriptions for context's session
        ok = unsubscribe_all(Ctxt),
        Ctxt
    catch
    Class:Reason ->
        _ = lager:error(
            "Error while closing context; class=~p, reason=~p, trace=~p",
            [Class, Reason, erlang:get_stacktrace()]
        ),
        Ctxt
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec features() -> map().
features() ->
    ?BROKER_FEATURES.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
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
-spec handle_message(M :: wamp_message(), Ctxt :: bondy_context:t()) -> ok.

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
            ok;
        {ok, _} ->
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
                case bondy_session:lookup(ESessionId) of
                    {error, not_found} ->
                        Acc;
                    ESession ->
                        Event = wamp_message:event(
                            SubsId, PubId, Opts, Args, ArgsKW),
                        bondy:send(bondy_session:peer_id(ESession), Event),
                        maps:update_with(Node, fun(V) -> V + 1 end, 1, Acc)
                end;
            _ ->
                %% This is a forwarded PUBLISH so we do not forward it
                Acc
        end
    end,
    _Acc1 = publish_fold(Subs, Fun, #{}),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec publish(
    Opts :: map(),
    {Realm :: uri(), TopicUri :: uri()} | uri(),
    Args :: [],
    ArgsKw :: map(),
    bondy_context:t()) -> {ok, id()} | {error, any()}.
publish(Opts, TopicUri, Args, ArgsKw, Ctxt) ->
    publish(bondy_utils:get_id(global), Opts, TopicUri, Args, ArgsKw, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec publish(
    id(),
    Opts :: map(),
    {Realm :: uri(), TopicUri :: uri()} | uri(),
    Args :: list(),
    ArgsKw :: map(),
    bondy_context:t() | uri()) -> {ok, id()} | {error, any()}.

publish(ReqId, Opts, TopicUri, Args, ArgsKw, RealmUri)
when is_binary(RealmUri) ->
    Ctxt = bondy_context:local_context(RealmUri),
    publish(ReqId, Opts, TopicUri, Args, ArgsKw, Ctxt);

publish(ReqId, Opts, TopicUri, Args, ArgsKw, Ctxt)
when is_map(Ctxt) ->
    try do_publish(ReqId, Opts, TopicUri, Args, ArgsKw, Ctxt)
    catch
        _:Reason ->
            _ = lager:error(
                "Error while publishing; reason=~p, "
                "topic=~p, session_id=~p, stacktrace=~p",
                [
                    Reason,
                    TopicUri,
                    bondy_context:session_id(Ctxt),
                    erlang:get_stacktrace()
                ]
            ),
            {error, Reason}
    end.


%% @private
-spec do_publish(
    id(),
    Opts :: map(),
    {Realm :: uri(), TopicUri :: uri()},
    Args :: list(),
    ArgsKw :: map(),
    bondy_context:t()) -> {ok, id()} | {error, any()}.

do_publish(ReqId, Opts, {RealmUri, TopicUri}, Args, ArgsKw, Ctxt) ->
    %% TODO check if authorized and if not throw wamp.error.not_authorized

    %% REVIEW We need to parallelise this based on batches
    %% (RFC) When a single event matches more than one of a _Subscriber's_
    %% subscriptions, the event will be delivered for each subscription.

    %% We should not send the publication to the published, so we exclude it
    %% (RFC) Note that the _Publisher_ of an event will never
    %% receive the published event even if the _Publisher_ is
    %% also a _Subscriber_ of the topic published to.

    %% An (authorized) Subscriber to topic T will receive an event published to
    %% T if and only if all of the following statements hold true:
    %% * if there is an eligible attribute present, the Subscriber's sessionid
    %% is in this list
    %% * if there is an eligible_authid attribute present, the
    %% Subscriber's authid is in this list
    %% * if there is an eligible_authrole attribute present, the Subscriber's
    %% authrole is in this list
    %% * if there is an exclude attribute present, the Subscriber's sessionid is NOT in this list
    %% * if there is an exclude_authid attribute present, the Subscriber's
    %% authid is NOT in this list
    %% * if there is an exclude_authrole attribute present, the Subscriber's authrole is NOT in this list

    %% Subscriber Blacklisting: we only support sessionIds for now
    Exclusions0 = maps:get(exclude, Opts, []),

    %% Publisher exclusion: enabled by default
    Exclusions = case maps:get(exclude_me, Opts, true) of
        true ->
            lists:append(
                [S || S <- [bondy_context:session_id(Ctxt)], S =/= undefined], Exclusions0
            );
        false ->
            Exclusions0
    end,
    MatchOpts0 = #{exclude => Exclusions},

    %% Subscriber Whitelisting: we only support sessionIds for now
    MatchOpts = case maps:find(eligible, Opts) of
        error ->
            MatchOpts0;
        {ok, L} when is_list(L) ->
            Eligible = sets:subtract(
                sets:from_list(L), sets:from_list(Exclusions)),
            MatchOpts0#{eligible => sets:to_list(Eligible)}
    end,

    Subs = match_subscriptions(TopicUri, RealmUri, MatchOpts),
    Node = bondy_peer_service:mynode(),
    PubId = bondy_utils:get_id(global),

    Fun = fun(Entry, Acc) ->
        case bondy_registry_entry:node(Entry) of
            Node ->
                %% We publish to a local subscriber
                SubsId = bondy_registry_entry:id(Entry),
                case bondy_registry_entry:session_id(Entry) of
                    undefined ->
                        %% An internal PID subscriber
                        Event = wamp_message:event(
                            SubsId, PubId, Opts, Args, ArgsKw),
                        ok = bondy_broker_events:notify(Event),
                        Acc;
                    ESessionId ->
                        case bondy_session:lookup(ESessionId) of
                            {error, not_found} ->
                                Acc;
                            ESession ->
                                Event = wamp_message:event(
                                    SubsId, PubId, Opts, Args, ArgsKw),
                                bondy:send(
                                    bondy_session:peer_id(ESession), Event),
                                maps:update_with(
                                    Node, fun(V) -> V + 1 end, 1, Acc)
                        end
                end;
            Other ->
                %% We just acummulate the subscribers per peer, later we will
                %% forward a single message to each peer.
                maps:update_with(Other, fun(V) -> V + 1 end, 1, Acc)
        end
    end,

    %% We send the event to the subscribers
    Acc1 = publish_fold(Subs, Fun, #{}),

    %% If we have remote subscribers we forward the publication
    case bondy_peer_service:peers() of
        {ok, []} ->
            {ok, PubId};
        {ok, Peers} ->
            Nodes = maps:keys(Acc1) -- [Node],
            Set = sets:intersection(
                sets:from_list(Peers), sets:from_list(Nodes)),
            ok = case sets:size(Set) > 0 of
                true ->
                    M = wamp_message:publish(
                        ReqId, Opts, TopicUri, Args, ArgsKw),
                    %% We also forward the PubId
                    FOpts = #{publication_id => PubId},
                    forward_publication(sets:to_list(Set), M, FOpts, Ctxt);
                false ->
                    ok
            end,
            {ok, PubId}
    end;

do_publish(ReqId, Opts, TopicUri, Args, ArgsKw, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    do_publish(ReqId, Opts, {RealmUri, TopicUri}, Args, ArgsKw, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc For internal Bondy use
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(uri(), map(), uri(), pid() | function()) ->
    {ok, reference()} | {error, already_exists}.

subscribe(RealmUri, Opts, Topic, Fun) when is_function(Fun, 1) ->
    bondy_broker_events:subscribe(RealmUri, Opts, Topic, Fun);

subscribe(RealmUri, Opts, Topic, Pid) when is_pid(Pid) ->
    case
        bondy_registry:add_local_subscription(RealmUri, Topic, Opts, Pid)
    of
        {ok, #{id := SubsId}, _} ->
            {ok, SubsId};
        {error, {already_exists, _}} ->
            {error, already_exists}
    end.


%% -----------------------------------------------------------------------------
%% @doc For internal Bondy use
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(id()) -> ok | {error, not_found}.

unsubscribe(Ref) when is_reference(Ref) ->
    bondy_broker_events:unsubscribe(Ref);

unsubscribe(Id) ->
    case bondy_registry:remove(subscription, Id) of
        ok ->
            ok;
        {ok, _} ->
            ok;
        Error ->
            Error
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(wamp_subscribe(), bondy_context:t()) -> ok.

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
-spec unsubscribe_all(bondy_context:t()) -> ok.

unsubscribe_all(Ctxt) ->
    bondy_registry:remove_all(subscription, Ctxt).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(id(), bondy_context:t()) -> ok | {error, not_found}.

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
    Publisher = bondy_context:peer_id(Ctxt),
    {ok, Good, Bad} = bondy_peer_wamp_forwarder:broadcast(
        Publisher, Nodes, M, Opts),

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
    RealmUri :: uri(), Node :: atom(), SessionId :: id(), non_neg_integer()) ->
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
-spec match_subscriptions(uri(), RealmUri :: uri(), map()) ->
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