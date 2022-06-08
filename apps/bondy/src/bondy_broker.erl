%% =============================================================================
%%  bondy_broker.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
%% @doc This module implements the capabilities of a Broker. It is used by
%% {@link bondy_router}.
%% Regarding *Publish &amp; Subscribe*, the ordering guarantees are as
%% follows:
%%
%% If _Subscriber A_ is subscribed to both *Topic 1* and *Topic 2*, and
%% _Publisher B_ first publishes an *Event 1* to *Topic 1* and then an
%% *Event 2* to *Topic 2*, then _Subscriber A_ will first receive *Event
%% 1* and then *Event 2*. This also holds if *Topic 1* and *Topic 2* are
%% identical.
%%
%% In other words, WAMP guarantees ordering of events between any given
%% _pair_ of _Publisher_ &amp; _Subscriber_.
%% Further, if _Subscriber A_ subscribes to *Topic 1*, the "SUBSCRIBED"
%% message will be sent by the _Broker_ to _Subscriber A_ before any
%% "EVENT" message for *Topic 1*.
%%
%% There is no guarantee regarding the order of return for multiple
%% subsequent subscribe requests.  A subscribe request might require the
%% _Broker_ to do a time-consuming lookup in some database, whereas
%% another subscribe request second might be permissible immediately.
%%
%% ```
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
%% '''
%% @end
%% =============================================================================
-module(bondy_broker).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


-define(GET_REALM_URI(Map),
    case maps:find(realm_uri, Map) of
        {ok, Val} -> Val;
        error -> error(no_realm)
    end
).

%% API
-export([features/0]).
-export([flush/2]).
-export([forward/2]).
-export([forward/3]).
-export([is_feature_enabled/1]).
-export([match_subscriptions/2]).
-export([match_subscriptions/3]).
-export([publish/5]).
-export([publish/6]).
-export([subscribe/3]).
-export([subscribe/4]).
-export([subscriptions/1]).
-export([subscriptions/2]).
-export([subscriptions/3]).
-export([unsubscribe/1]).
-export([unsubscribe/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec features() -> map().

features() ->
    ?BROKER_FEATURES.


%% -----------------------------------------------------------------------------
%% @doc Returns true if feature F is enabled by the broker.
%% @end
%% -----------------------------------------------------------------------------
-spec is_feature_enabled(binary()) -> boolean().

is_feature_enabled(F) when is_binary(F) ->
    maps:get(F, ?BROKER_FEATURES, false).


%% -----------------------------------------------------------------------------
%% @doc Removes all subscriptions that are associated for reference `Ref' in
%% realm `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec flush(RealmUri :: uri(), Ref :: bondy_ref:t()) -> ok.

flush(RealmUri, Ref) ->
    try
        %% TODO If subscription is deleted we need to also call on_delete/1
        %% Cleanup all registrations for the ref's session
        SessionId = bondy_ref:session_id(Ref),
        bondy_registry:remove_all(
            subscription, RealmUri, SessionId, fun on_unsubscribe/1
        )

    catch
        Class:Reason:Stacktrace ->
        ?LOG_DEBUG(#{
            description => "Error while flushin subscriptions",
            class => Class,
            reason => Reason,
            stacktrace => Stacktrace,
            realm_uri => RealmUri,
            ref => Ref
        }),
        ok
    end.


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
    ReqId = bondy_context:gen_message_id(Ctxt, session),
    publish(ReqId, Opts, TopicUri, Args, ArgsKw, Ctxt).


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
    bondy_context:t()) -> {ok, id()} | {error, any()}.

publish(ReqId, Opts, TopicUri, Args, KWArgs, Ctxt)
when is_map(Ctxt) ->
    try

        ok = bondy_rbac:authorize(<<"wamp.publish">>, TopicUri, Ctxt),
        M = wamp_message:publish(ReqId, Opts, TopicUri, Args, KWArgs),
        do_publish(M, Ctxt)

    catch
        _:{not_authorized, _Reason} ->
            {error, not_authorized};

        _:Reason:Stacktrace->
            SessionId = bondy_context:session_id(Ctxt),
            ExtId = bondy_utils:external_session_id(SessionId),
            ?LOG_WARNING(#{
                description => "Error while publishing",
                reason => Reason,
                protocol_session_id => ExtId,
                session_id => SessionId,
                topic => TopicUri,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(RealmUri :: uri(), Opts :: map(), Topic :: uri()) ->
    {ok, id()} | {ok, id(), pid()} | {error, already_exists | any()}.
subscribe(RealmUri, Opts, Topic) ->
    subscribe(RealmUri, Opts, Topic, self()).


%% -----------------------------------------------------------------------------
%% @doc For internal use.
%% If the last argument is a function, spawns a supervised instance of a
%% bondy_subscriber by calling bondy_subscribers_sup:start_subscriber/4.
%% The new process, calls subscribe/4 passing its pid as last argument.
%%
%% If the last argument is a pid, it registers the pid as a subscriber
%% (a.k.a a local subscription)
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(
    RealmUri :: uri(),
    Opts :: map(),
    Topic :: uri(),
    SubscriberOrFun :: pid() | function()) ->
    {ok, id()} | {ok, id(), pid()} | {error, already_exists | any()}.

subscribe(RealmUri, Opts, Topic, Fun) when is_function(Fun, 2) ->
    %% We preallocate an id so that we can keep the same even when the process
    %% is restarted by the supervisor.
    Id = case maps:find(subscription_id, Opts) of
        {ok, Value} -> Value;
        error -> bondy_utils:gen_message_id(global)
    end,

    %% subscriber will call subscribe(RealmUri, Opts, Topic, Pid)
    Result = bondy_subscribers_sup:start_subscriber(
        Id, RealmUri, Opts, Topic, Fun
    ),

    case Result of
        {ok, Pid} ->
            {ok, Id, Pid};
        Error ->
            Error
    end;

subscribe(RealmUri, Opts, Topic, Pid) when is_pid(Pid) ->
    %% Add a local subscription
    Ref = bondy_ref:new(internal, Pid),
    subscribe(RealmUri, Opts, Topic, Ref);

subscribe(RealmUri, Opts, Topic, Ref)  ->
    bondy_ref:is_type(Ref) orelse error({badarg, Ref}),

    case bondy_registry:add(subscription, Topic, Opts, RealmUri, Ref) of
        {ok, Entry, true} ->
            on_create(Entry),
            {ok, bondy_registry_entry:id(Entry)};

        {ok, Entry, false} ->
            on_subscribe(Entry),
            {ok, bondy_registry_entry:id(Entry)};

        {error, {already_exists, _}} ->
            {error, already_exists}
    end.


%% -----------------------------------------------------------------------------
%% @doc For internal Bondy use.
%% Terminates the process identified by Pid by
%% bondy_subscribers_sup:terminate_subscriber/1
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(pid() | integer()) -> ok | {error, not_found}.

unsubscribe(SubscriberId) when is_integer(SubscriberId) ->
    unsubscribe(bondy_subscriber:pid(SubscriberId));

unsubscribe(Subscriber) when is_pid(Subscriber) ->
    bondy_subscribers_sup:terminate_subscriber(Subscriber).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(id(), bondy_context:t() | uri()) -> ok | {error, not_found}.

unsubscribe(SubsId, RealmUri) when is_integer(SubsId), is_binary(RealmUri) ->
    unsubscribe(SubsId, bondy_context:local_context(RealmUri));

unsubscribe(SubsId, Ctxt) when is_integer(SubsId) ->
    RealmUri = bondy_context:realm_uri(Ctxt),

    case bondy_registry:lookup(subscription, SubsId, RealmUri) of
        {error, not_found} = Error ->
            Error;

        Entry ->
            Topic = bondy_registry_entry:uri(Entry),
            ok = bondy_rbac:authorize(<<"wamp.unsubscribe">>, Topic, Ctxt),

            case bondy_registry:remove(Entry) of
                ok ->
                    on_unsubscribe(Entry);

                {ok, false} ->
                    on_unsubscribe(Entry);

                {ok, true} ->
                    ok = on_unsubscribe(Entry),
                    on_delete(Entry);

                Error ->
                    Error
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc Handles a wamp message. This function is called by the bondy_router
%% module.
%% The message might be handled synchronously (it is performed by the calling
%% process i.e. the transport handler) or asynchronously (by sending the
%% message to the broker worker pool).
%% @end
%% -----------------------------------------------------------------------------
-spec forward(M :: wamp_message(), Ctxt :: bondy_context:t()) ->
    ok | no_return().

forward(M, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),

    try
        do_forward(M, Ctxt)
    catch
        _:{not_authorized, Reason} when is_record(M, publish) ->
            Opts = M#publish.options,
            case maps:get(acknowledge, Opts, false) of
                true ->
                    Reply = not_authorized_error(M, Reason),
                    bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply);
                false ->
                    ok
            end;

        _:{not_authorized, Reason} ->
            Reply = not_authorized_error(M, Reason),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply);

        throw:not_found ->
            Reply = not_found_error(M, Ctxt),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply)
    end.


%% -----------------------------------------------------------------------------
%% @doc Handles a message sent by a peer node through the bondy_relay.
%% @end
%% -----------------------------------------------------------------------------
-spec forward(
    M :: wamp_publish(),
    To :: optional(bondy_ref:t()),
    Opts :: map()) ->
    ok | no_return().

forward(#publish{} = M, undefined, FwdOpts) ->
    #{
        from := Publisher,
        relayed_by := Relay,
        publication_id := PubId,
        event_details := Details
    } = FwdOpts,

    %% Fails with no_realm exception if not present
    RealmUri = ?GET_REALM_URI(FwdOpts),
    SessionId = bondy_ref:session_id(Publisher),
    TopicUri = M#publish.topic_uri,
    Args = M#publish.args,
    KWArgs = M#publish.kwargs,

    MatchOpts0 = make_match_opts(SessionId, M#publish.options),

    MatchOpts = case bondy_ref:is_bridge_relay(Relay) of
        true ->
            %% A publish relayed from another cluster or node e.g. bridge relay.
            %% We need to send to all subscribers in the cluster.
            MatchOpts0;
        false ->
            %% A publish relayed by a cluster peer.
            %% We need to send to this node local subscribers only.
            MatchOpts0#{nodestring => bondy_config:nodestring()}
    end,

    Subscriptions = match_subscriptions(TopicUri, RealmUri, MatchOpts),

    %% We create a high order fun that will generate the event for each
    %% subscription_id
    MakeEvent = fun(SubsId) ->
        wamp_message:event(SubsId, PubId, Details, Args, KWArgs)
    end,

    %% No need to retain events here as this has been done already
    %% by the original publication time in the original node (see forward/2).

    %% We publish to all matching local subscribers and we get back the list of
    %% local bridge relays and the cluster peer nodes where we found remote
    %% subscribers
    case do_publish(RealmUri, Subscriptions, MakeEvent, remote) of
        {[], []} ->
            ok;

        {Relays, Nodes} ->
            ok = forward_using_relay(M, FwdOpts, Nodes),

            ok = forward_using_bridge_relay(M, FwdOpts, Relays)
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
do_forward(#subscribe{} = M, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Topic = M#subscribe.topic_uri,

    ok = bondy_rbac:authorize(<<"wamp.subscribe">>, Topic, Ctxt),

    Ref = bondy_context:ref(Ctxt),
    Opts = M#subscribe.options,
    ReqId = M#subscribe.request_id,

    case bondy_registry:add(subscription, Topic, Opts, RealmUri, Ref) of
        {ok, Entry, true} ->
            Id = bondy_registry_entry:id(Entry),
            bondy:send(RealmUri, Ref, wamp_message:subscribed(ReqId, Id)),
            on_create(Entry);

        {ok, Entry, false} ->
            Id = bondy_registry_entry:id(Entry),
            bondy:send(RealmUri, Ref, wamp_message:subscribed(ReqId, Id)),
            on_subscribe(Entry);

        {error, {already_exists, Entry}} ->
            Id = bondy_registry_entry:id(Entry),
            bondy:send(RealmUri, Ref, wamp_message:subscribed(ReqId, Id))
    end;

do_forward(#unsubscribe{} = M, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    SubsId = M#unsubscribe.subscription_id,

    case unsubscribe(SubsId, Ctxt) of
        ok ->
            ReqId = M#unsubscribe.request_id,
            Reply = wamp_message:unsubscribed(ReqId),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply);

        {error, not_found} ->
            throw(not_found)
    end;

do_forward(#publish{} = M, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    ReqId = M#publish.request_id,
    Topic = M#publish.topic_uri,
    Opts = M#publish.options,

    ok = bondy_rbac:authorize(<<"wamp.publish">>, Topic, Ctxt),

    %% (RFC) Asynchronously notifies all subscribers of the published event.
    %% Note that the _Publisher_ of an event will never receive the
    %% published event even if the _Publisher_ is also a _Subscriber_ of the
    %% topic published to.
    {ok, PubId} = do_publish(M, Ctxt),

    %% (RFC) By default, publications are unacknowledged, and the _Broker_
    %% will not respond, whether the publication was successful indeed or
    %% not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    %% We publish first to the local subscribers and if succeed we forward
    %% to cluster peers
    case maps:get(acknowledge, Opts, false) of
        true ->
            Reply = wamp_message:published(ReqId, PubId),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply);
        false ->
            ok
    end.


%% @private
not_found_error(M, _Ctxt) ->
    Msg = iolist_to_binary(
        <<"There are no subcriptions matching the id ",
        $', (M#unsubscribe.subscription_id)/integer, $'>>
    ),
    wamp_message:error(
        ?UNSUBSCRIBE,
        M#unsubscribe.request_id,
        #{},
        ?WAMP_NO_SUCH_SUBSCRIPTION,
        [Msg],
        #{
            message => Msg,
            description => <<"The unsubscribe request failed.">>
        }
    ).


%% @private
not_authorized_error(M, Reason) ->
    wamp_message:error_from(
        M,
        #{},
        ?WAMP_NOT_AUTHORIZED,
        [Reason],
        #{message => Reason}
    ).



%% =============================================================================
%% PRIVATE
%% =============================================================================



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
    }
    | bondy_registry:eot().

subscriptions(?EOT) ->
    ?EOT;

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
-spec subscriptions(RealmUri :: uri(), SessionId :: id()) ->
    [bondy_registry_entry:t()].

subscriptions(RealmUri, SessionId) ->
    bondy_registry:entries(subscription, RealmUri, SessionId).


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
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

subscriptions(RealmUri, SessionId, Limit) ->
    bondy_registry:entries(subscription, RealmUri, SessionId, Limit).


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


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec do_publish(M :: wamp_message:publish(), bondy_context:t()) -> {ok, id()}.

do_publish(#publish{} = M, Ctxt) ->
    %% REVIEW We need to parallelise this based on batches.

    %% (RFC) When a single event matches more than one of a _Subscriber's_
    %% subscriptions, the event will be delivered for each subscription.
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    Publisher = bondy_context:ref(Ctxt),

    TopicUri = M#publish.topic_uri,
    Opts = M#publish.options,
    Args = M#publish.args,
    KWArgs = M#publish.kwargs,

    %% We find matching subscriptions
    MatchOpts = make_match_opts(SessionId, Opts),
    Subscriptions = match_subscriptions(TopicUri, RealmUri, MatchOpts),

    Details = make_event_details(TopicUri, Opts, Ctxt),

    %% We generate a new publication id
    PubId = bondy_utils:gen_message_id(global),

    %% We create a high order fun that will generate the event for each
    %% subscription_id
    Template = wamp_message:event(0, PubId, Details, Args, KWArgs),

    MakeEvent = fun(SubsId) ->
        wamp_message:copy_event(Template, SubsId)
    end,

    %% If retained options is provided the message will be retained, this is
    %% regardless of whether there are any current subscribers to the topic or
    %% not.
    ok = maybe_retain(Opts, RealmUri, TopicUri, MatchOpts, MakeEvent),

    %% We publish to all matching local subscribers and we get back the list of
    %% local bridge relays and the cluster peer nodes where we found remote
    %% subscribers
    case do_publish(RealmUri, Subscriptions, MakeEvent, local) of
        {[], []} ->
            ok;

        {Relays, Nodes} ->
            FwdOpts = #{
                realm_uri => RealmUri,
                from => Publisher,
                publication_id => PubId,
                event_details => Details
            },

            ok = forward_using_relay(M, FwdOpts, Nodes),

            ok = forward_using_bridge_relay(M, FwdOpts, Relays)
    end,

    {ok, PubId}.


%% @private
do_publish(RealmUri, Subscriptions, MakeEvent, Origin) ->
    %% REVIEW Consider creating a Broadcast tree out of the registry trie
    %% results so that instead of us sending possibly millions of Erlang
    %% messages to millions of peers (processes) we delegate that to peers as
    %% Erlang might penalise a process that is sending lots of messages to many
    %% processes.
    Fun = fun(Entry, {RelayAcc0, NodeAcc0}) ->
        Subscriber = bondy_registry_entry:ref(Entry),
        IsLocal = bondy_ref:is_local(Subscriber),
        Publish =
            case bondy_registry_entry:find_option(group_id, Entry) of
                {ok, _} when Origin == remote ->
                    %% We MUST not publish or forward if Subscriber is in a
                    %% group and the message has been forwarded, as the
                    %% instance of this subscriber local to the Publisher must
                    %% have already received this event.
                    false;
                _ ->
                    true
            end,

        case {Publish, IsLocal} of
            {true, true} ->
                case bondy_ref:is_bridge_relay(Subscriber) of
                    true ->
                        {[Subscriber|RelayAcc0], NodeAcc0};

                    false ->
                        Event = MakeEvent(bondy_registry_entry:id(Entry)),
                        ok = bondy:send(RealmUri, Subscriber, Event),
                        {RelayAcc0, NodeAcc0}
                end;

            {true, false} ->
                %% A remote subscriber in a peer cluster node.
                %% We just acummulate the subscribers per node, later we will
                %% forward a single message to each node.
                Nodestring = bondy_ref:nodestring(Subscriber),
                NodeAcc = maps:update_with(
                    Nodestring, fun(V) -> V + 1 end, 1, NodeAcc0
                ),
                {RelayAcc0, NodeAcc};

            {false, _} ->
                {RelayAcc0, NodeAcc0}
        end
    end,

    %% We send the event to the local subscribers and we get back a list of
    %% (local) Bridge Relays and Cluster Peer nodestrings where we foudn at
    %% least one subscriber
    Acc = {[], #{}},
    {Relays, Nodestrings0} = publish_fold(Subscriptions, Fun, Acc),

    MyNodestring = bondy_config:nodestring(),
    Nodestrings = lists:usort(maps:keys(Nodestrings0)) -- [MyNodestring],
    Nodes = [binary_to_atom(Bin, utf8) || Bin <- Nodestrings],

    {Relays, Nodes}.


%% @private
make_match_opts(SessionId, Opts) ->
    %% An (authorized) Subscriber to topic T will receive an event published to
    %% T if and only if all of the following statements hold true:
    %%
    %% 1. if there is an eligible attribute present, the Subscriber's sessionid
    %% is in this list [DONE]
    %% 2. if there is an exclude attribute present, the Subscriber's sessionid is NOT in this list [DONE]
    %% 3. if there is an eligible_authid attribute present, the
    %% Subscriber's authid is in this list  [TODO]
    %% 4. if there is an exclude_authid attribute present, the Subscriber's
    %% authid is NOT in this list [TODO]
    %% 5. if there is an eligible_authrole attribute present, the Subscriber's
    %% authrole is in this list [TODO]
    %% 6. if there is an exclude_authrole attribute present, the Subscriber's authrole is NOT in this list [TODO]

    %% Subscriber Exclusion: we only support sessionIds for now
    %% TODO Add support for eligible_authid, eligible_authrole, exclude_authid
    %% and exclude_authrole.
    Exclusions0 = maps:get(exclude, Opts, []),

    %% Publisher exclusion:
    %% By default, a Publisher of an event will not itself receive an event
    %% published, even when subscribed to the Topic the Publisher is publishing
    %% to. This behavior can be overridden using this feature.
    Exclusions = case maps:get(exclude_me, Opts, true) of
        true ->
            lists:append(
                [
                    %% We get the protocol (WAMP) session identifier from the
                    %% session identifier
                    bondy_session_id:to_external(S)
                    || S <- [SessionId], S =/= undefined
                ],
                Exclusions0
            );
        false ->
            Exclusions0
    end,

    MatchOpts0 = #{exclude => Exclusions},

    %% Subscriber Eligibility: we only support sessionIds for now
    case maps:find(eligible, Opts) of
        error ->
            MatchOpts0;
        {ok, L} when is_list(L) ->
            Eligible = sets:subtract(
                sets:from_list(L), sets:from_list(Exclusions)
            ),
            MatchOpts0#{eligible => sets:to_list(Eligible)}
    end.


%% @private
make_event_details(TopicUri, Opts, Ctxt) ->

    %% TODO disclose info only if feature is announced by Publishers, Brokers
    %% and Subscribers

    Details0 = #{
        %% This is mandatory only for pattern-based subscriptions but we prefer
        %% to always have it
        topic => TopicUri,
        %% Private internal
        <<"timestamp">> => erlang:system_time(millisecond)
    },

    %% TODO disclose info only if feature is announced by Publishers, Brokers
    %% and Subscribers
    case maps:get(disclose_me, Opts, true) of
        true ->
            bondy_context:publisher_details(Ctxt, Details0);
        false ->
            Details0
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc This is an optimization for sending an EVENT to N remote subscribers
%% that located at cluster peer nodes. Instead of generating the N different
%% EVENT messages we send a single PUBLISH per node (the equivalent of the
%% original PUBLISH message).
%% @end
%% -----------------------------------------------------------------------------
forward_using_relay( _, _, []) ->
    ok;

forward_using_relay(M, FwdOpts, Nodes) ->
    %% We forward the publication to all Nodes.
    %% @TODO stop replicating individual remote subscribers and instead
    %% use a per node reference counter

    RelayMsg = {forward, undefined, M, FwdOpts},

    #{realm_uri := RealmUri} = FwdOpts,

    RelayOpts = #{
        ack => true,
        retransmission => true,
        partition_key => erlang:phash2(RealmUri)
    },

    ok = bondy_relay:forward(Nodes, RelayMsg, RelayOpts).


%% -----------------------------------------------------------------------------
%% @private
%% @doc This is an optimization for sending an EVENT to N local bridge relays
%% that will need to re-publish the event at their remote clusters. We send %%
%% them the equivalent of the original PUBLISH message
%% @end
%% -----------------------------------------------------------------------------
forward_using_bridge_relay(_, _, []) ->
    ok;

forward_using_bridge_relay(M, FwdOpts, [H|T]) ->
    RelayMsg = {forward, undefined, M, FwdOpts},

    ok = bondy_bridge_relay:forward(H, RelayMsg),

    forward_using_bridge_relay(M, FwdOpts, T).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
publish_fold(?EOT, _Fun, Acc) ->
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
-spec on_create(bondy_registry_entry:t()) -> ok.

on_create(Entry) ->
    ok = maybe_send_retained(Entry),
    bondy_event_manager:notify({subscription_created, Entry}).


%% @private
-spec on_subscribe(bondy_registry_entry:t()) -> ok.

on_subscribe(Entry) ->
    ok = maybe_send_retained(Entry),
    bondy_event_manager:notify({subscription_added, Entry}).


%% @private
-spec on_unsubscribe(bondy_registry_entry:t()) -> ok.

on_unsubscribe(Entry) ->
    bondy_event_manager:notify({subscription_removed, Entry}).


%% @private
-spec on_delete(bondy_registry_entry:t()) -> ok.

on_delete(Entry) ->
    bondy_event_manager:notify({subscription_deleted, Entry}).



%% =============================================================================
%% PRIVATE: EVENT RETENTION
%% =============================================================================



%% @private
maybe_retain(#{retain := true} = Opts, Realm, Topic, MatchOpts, MakeEvent) ->
    %% We treat it as a template passing 0
    %% as the real SubsId will be provided by the user in
    %% bondy_retained_message:to_event/2 when retrieving it
    Event = MakeEvent(0),
    TTL = maps:get('_retained_ttl', Opts, undefined),
    bondy_retained_message_manager:put(Realm, Topic, Event, MatchOpts, TTL);

maybe_retain(_, _, _, _, _) ->
    ok.


%% @private
maybe_send_retained(Entry) ->
    case maps:get(get_retained, bondy_registry_entry:options(Entry), false) of
        true ->
            send_retained(Entry);
        false ->
            ok
    end.


%% @private
send_retained(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    SessionId = bondy_registry_entry:session_id(Entry),
    Ref = bondy_registry_entry:ref(Entry),
    SubsId = bondy_registry_entry:id(Entry),
    Topic = bondy_registry_entry:uri(Entry),
    Policy = bondy_registry_entry:match_policy(Entry),

    Matches = bondy_retained_message_manager:match(
        RealmUri, Topic, SessionId, Policy
    ),

    bondy_utils:foreach(
        fun
            ({continue, Cont}) ->
                bondy_retained_message_manager:match(Cont);
            (M) ->
                Event = bondy_retained_message:to_event(M, SubsId),
                catch bondy:send(RealmUri, Ref, Event)
        end,
        Matches
    ).
