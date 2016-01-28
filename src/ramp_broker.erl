-module(ramp_broker).
-include("ramp.hrl").

-define(SUBSCRIPTION_TABLE_NAME, subscription).
-define(SESSION_SUBSCRIPTION_TABLE_NAME, session_subscription).

-type subscription_key()    ::  {
                                    RealmUri :: uri(),
                                    TopicUri :: uri(),
                                    MatchPolicy :: binary()
                                }.

-record (subscription, {
    key                     ::  subscription_key(),
    session_id              ::  id(),
    subscription_id         ::  id()
}).

-record (session_subscription, {
    key                     ::  {
                                    RealmUri :: uri(),
                                    SessionId :: id(),
                                    SubsId :: id()
                                },
    topic_uri               ::  uri(),
    match_policy            ::  binary()
}).

-export([subscribe/3]).
-export([subscribers/1]).
-export([subscribers/3]).
-export([unsubscribe/2]).
%% -export([notify/2]).



%% =============================================================================
%% API
%% =============================================================================



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
%% Prefix matching identical
%% 1) Tokenize uris (works patially i.e. a.b.c will match a.b.c.d but not a.b.c-d)
%% 2) use prefix matching from https://github.com/Feuerlabs/kvdb/tree/master/src
%% a.b.*
%% a.b.c.*

%% a.b.c.d
%% a.b.c.e
%% {RealmUri, TopicUri, MatchPolicy} -> Id
%% {RealmUri, Id} -> SessionId, MatchPolicy ...



-spec subscribe(uri(), map(), ramp_context:context()) ->
    {ok, id()} | {error, Reason :: any()}.
subscribe(TopicUri, Options, Ctxt) ->
    #{
        realm_uri := RealmUri,
        session_id := SessionId
    } = Ctxt,
    MatchPolicy = validate_match_policy(Options),

    SSKey = {RealmUri,  SessionId, '$1'},
    SS0 = #session_subscription{
        key = SSKey,
        topic_uri = TopicUri,
        match_policy = MatchPolicy
    },
    Tab = session_subscription_table({RealmUri,  SessionId}),

    case ets:match(Tab, SS0) of
        [SubsId] ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already subscribed topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            {ok, SubsId};
        [] ->
            SubsId = ramp_id:new({session, SessionId}),
            SS1 = SS0#session_subscription{key = setelement(3, SSKey, SubsId)},
            S = #subscription{
                key = {RealmUri, TopicUri, MatchPolicy},
                subscription_id = SubsId,
                session_id = SessionId
            },
            SSTab = session_subscription_table({RealmUri, SessionId}),
            true = ets:insert(SSTab, SS1),
            STab = subscription_table(RealmUri),
            true = ets:insert(STab, S),
            {ok, SubsId}
    end.


-spec unsubscribe(id(), ramp_context:context()) -> ok | {error, any()}.
unsubscribe(SubsId, Ctxt) ->
    #{
        realm_uri := RealmUri,
        session_id := SessionId
    } = Ctxt,
    Tab = session_subscription_table({RealmUri, SessionId}),
    case ets:take(Tab, {RealmUri, SessionId, SubsId}) of
        [] ->
            %% The session had no subscription with subsId.
            {error, invalid_subscription};
        [SS] ->
            #session_subscription{
                topic_uri = TopicUri,
                match_policy = MatchPolicy
            } = SS,
            true = ets:delete(
                subscription_table(RealmUri), {RealmUri, TopicUri, MatchPolicy})
    end.


-spec subscribers(uri(), binary(), ramp_context:context()) ->
    {[SessionId :: id()], ets:continuation()} | '$end_of_table'.
subscribers(TopicUri, MatchPolicy, Ctxt) ->
    #{
        realm_uri := RealmUri
    } = Ctxt,
    MS = {{{RealmUri, TopicUri, MatchPolicy}, '$1', '_'}, [], ['$1']},
    ets:select(
        subscription_table(RealmUri), MS, 1000).


-spec subscribers(ets:continuation()) ->
    {[SessionId :: id()], ets:continuation()} | '$end_of_table'.
subscribers(Cont) ->
    ets:select(Cont).



%% =============================================================================
%% PRIVATE
%% =============================================================================

validate_match_policy(Options) when is_map(Options) ->
    P = maps:get(match, Options, <<"exact">>),
    P == <<"exact">> orelse P == <<"prefix">> orelse P == <<"wildcard">>
    orelse error({invalid_pattern_match_policy, P}),
    P.

%% @private
subscription_table(RealmUri) when is_binary(RealmUri) ->
    tuplespace:locate_table(?SUBSCRIPTION_TABLE_NAME, RealmUri).

session_subscription_table({_, _} = Key) ->
    tuplespace:locate_table(?SESSION_SUBSCRIPTION_TABLE_NAME, Key).
