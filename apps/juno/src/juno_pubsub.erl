%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% @doc
%%
%% @end
-module(juno_pubsub).
-include_lib("wamp/include/wamp.hrl").

-define(DEFAULT_LIMIT, 1000).

-export([match_subscriptions/1]).
-export([match_subscriptions/2]).
-export([match_subscriptions/3]).
-export([publish/5]).
-export([subscribe/3]).
-export([subscriptions/1]).
-export([subscriptions/2]).
-export([subscriptions/3]).
-export([unsubscribe_all/1]).
-export([unsubscribe/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subscribe(uri(), map(), juno_context:context()) -> {ok, id()}.
subscribe(TopicUri, Options, Ctxt) ->
    juno_registry:add(subscription, TopicUri, Options, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe_all(juno_context:context()) -> ok.
unsubscribe_all(Ctxt) ->
    juno_registry:remove_all(subscription, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(id(), juno_context:context()) -> ok.
unsubscribe(SubsId, Ctxt) ->
    juno_registry:remove(subscription, SubsId, Ctxt).


%% -----------------------------------------------------------------------------
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
            Pid = juno_session:pid(juno_registry:session_id(Entry)),
            Pid ! wamp_message:event(SubsId, PubId, Details, Args, Payload)
    end,
    ok = publish(Subs, Fun),
    {ok, PubId}.



%% -----------------------------------------------------------------------------
%% @doc
%% Returns the list of subscriptions for the active session.
%%
%% When called with a juno:context() it is equivalent to calling
%% subscriptions/2 with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(
    ContextOrCont :: juno_context:context() | ets:continuation()) ->
    [juno_registry:entry()].
subscriptions(Ctxt) when is_map(Ctxt) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    SessionId = juno_context:session_id(Ctxt),
    juno_registry:entries(
        subscription, RealmUri, SessionId);
subscriptions(Cont) ->
    juno_registry:entries(Cont).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of subscriptions matching the RealmUri
%% and SessionId.
%%
%% Use {@link subscriptions/3} and {@link subscriptions/1} to limit the number
%% of subscriptions returned.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(RealmUri :: uri(), SessionId :: id()) -> [juno_registry:entry()].
subscriptions(RealmUri, SessionId) ->
    juno_registry:entries(
        subscription, RealmUri, SessionId, infinity).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of subscriptions matching the RealmUri
%% and SessionId.
%%
%% Use {@link subscriptions/3} to limit the number of subscriptions returned.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(RealmUri :: uri(), SessionId :: id(), non_neg_integer()) ->
    {[juno_registry:entry()], Cont :: '$end_of_table' | term()}.
subscriptions(RealmUri, SessionId, Limit) ->
    juno_registry:entries(
        subscription, RealmUri, SessionId, Limit).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_subscriptions(uri(), juno_context:context()) ->
    [{SessionId :: id(), pid(), SubsId :: id(), Opts :: map()}].
match_subscriptions(TopicUri, Ctxt) ->
    juno_registry:match(subscription, TopicUri, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_subscriptions(
    uri(), juno_context:context(), non_neg_integer()) ->
    {[juno_registry:entry()], ets:continuation()}
    | '$end_of_table'.
match_subscriptions(TopicUri, Ctxt, Limit) ->
    juno_registry:match(subscription, TopicUri, Ctxt, Limit).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_subscriptions(ets:continuation()) ->
    {[juno_registry:entry()], ets:continuation()} | '$end_of_table'.
match_subscriptions(Cont) ->
    ets:select(Cont).



%% =============================================================================
%% PRIVATE
%% =============================================================================



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
