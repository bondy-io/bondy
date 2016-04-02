-module(juno_pubsub).
-include_lib("wamp/include/wamp.hrl").

-define(ANY, <<"*">>).
-define(EXACT_MATCH, <<"exact">>).
-define(PREFIX_MATCH, <<"prefix">>).
-define(WILDCARD_MATCH, <<"wildcard">>).
-define(DEFAULT_LIMIT, 1000).
-define(SESSION_SUBSCRIPTION_TABLE_NAME, subscription).
-define(SUBSCRIPTION_INDEX_TABLE_NAME, subscription_index).


-record(subscription, {
    key                     ::  {
                                    RealmUri :: uri(),
                                    SessionId :: id(),
                                    SubsId :: id()
                                },
    topic_uri               ::  uri(),
    match_policy            ::  binary(),
    criteria                ::  [{'=:=', Field :: binary(), Value :: any()}]

}).

-record(subscription_index, {
    key                     ::  tuple(),
    session_id              ::  id(),
    session_pid             ::  pid(),
    subscription_id         ::  id()
}).


-export([matching_subscriptions/1]).
-export([matching_subscriptions/2]).
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
-spec subscribe(uri(), map(), juno_context:context()) ->
    {ok, id()} | {error, Reason :: any()}.
subscribe(TopicUri, Options, Ctxt) ->
    #{ realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    MatchPolicy = validate_match_policy(Options),
    SSKey = {RealmUri,  SessionId, '$1'},
    SS0 = #subscription{
        key = SSKey,
        topic_uri = TopicUri,
        match_policy = MatchPolicy
    },
    Tab = subscription_table({RealmUri,  SessionId}),

    case ets:match(Tab, SS0) of
        [[SubsId]] ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already subscribed topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            {ok, SubsId};
        [] ->
            SubsId = wamp_id:new({session, SessionId}),
            SS1 = SS0#subscription{key = setelement(3, SSKey, SubsId)},
            IdxEntry = index_entry(SubsId, TopicUri, MatchPolicy, Ctxt),
            SSTab = subscription_table({RealmUri, SessionId}),
            IdxTab = subscription_index_table(RealmUri),
            true = ets:insert(SSTab, SS1),
            true = ets:insert(IdxTab, IdxEntry),
            {ok, SubsId}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe_all(juno_context:context()) -> ok | {error, any()}.
unsubscribe_all(Ctxt) ->
    #{realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    Pattern = #subscription{
        key = {RealmUri, SessionId, '_'},
        topic_uri = '_',
        match_policy = '_',
        criteria = '_'
    },
    Tab = subscription_table({RealmUri, SessionId}),
    case ets:match_object(Tab, Pattern, 1) of
        '$end_of_table' ->
            %% There are no subscriptions for this session
            ok;
        {[First], _} ->
            do_unsubscribe_all(First, Tab, Ctxt)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(id(), juno_context:context()) -> ok | {error, any()}.
unsubscribe(SubsId, Ctxt) ->
    #{realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    Tab = subscription_table({RealmUri, SessionId}),
    Key = {RealmUri, SessionId, SubsId},
    case ets:take(Tab, Key) of
        [] ->
            %% The session had no subscription with subsId.
            {error, no_such_subscription};
        [#subscription{topic_uri = TopicUri, match_policy = MP}] ->
            IdxTab = subscription_index_table(RealmUri),
            IdxEntry = index_entry(SubsId, TopicUri, MP, Ctxt),
            true = ets:delete_object(IdxTab, IdxEntry),
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec publish(uri(), map(), list(), map(), juno_context:context()) ->
    {ok, id()} | {error, any()}.
publish(TopicUri, _Opts, Args, Payload, Ctxt) ->
    #{session_id := SessionId} = Ctxt,
    %% TODO Do publish
    PubId = wamp_id:new(global),
    Details = #{},
    %% REVIEW We need to parallelise this based on batches
    %% (RFC) When a single event matches more than one of a _Subscriber's_
    %% subscriptions, the event will be delivered for each subscription.
    Fun = fun
        ({S, Pid, SubsId}) ->
            case S =:= SessionId of
                true ->
                    %% We should not send the publication to the published
                    %% (RFC) Note that the _Publisher_ of an event will never
                    %% receive the published event even if the _Publisher_ is
                    %% also a _Subscriber_ of the topic published to.
                    ok;
                false ->
                    Pid ! wamp_message:event(
                        SubsId, PubId, Details, Args, Payload)
            end
    end,
    ok = publish(matching_subscriptions(TopicUri, Ctxt), Fun),
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
    [#subscription{}].
subscriptions(#{realm_uri := RealmUri, session_id := SessionId}) ->
    subscriptions(RealmUri, SessionId);
subscriptions(Cont) ->
    ets:match_object(Cont).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of subscriptions matching the RealmUri
%% and SessionId.
%%
%% Use {@link subscriptions/3} and {@link subscriptions/1} to limit the number
%% of subscriptions returned.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(RealmUri :: uri(), SessionId :: id()) -> [#subscription{}].
subscriptions(RealmUri, SessionId) ->
    session_subscriptions(RealmUri, SessionId, infinity).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of subscriptions matching the RealmUri
%% and SessionId.
%%
%% Use {@link subscriptions/3} to limit the number of subscriptions returned.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(RealmUri :: uri(), SessionId :: id(), non_neg_integer()) ->
    {[#subscription{}], Cont :: '$end_of_table' | term()}.
subscriptions(RealmUri, SessionId, Limit) ->
    session_subscriptions(RealmUri, SessionId, Limit).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec matching_subscriptions(uri(), juno_context:context()) ->
    {[{SessionId :: id(), pid(), SubsId :: id()}], ets:continuation()}
    | '$end_of_table'.
matching_subscriptions(TopicUri, Ctxt) ->
    matching_subscriptions(TopicUri, Ctxt, ?DEFAULT_LIMIT).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec matching_subscriptions(
    uri(), juno_context:context(), non_neg_integer()) ->
    {[{SessionId :: id(), pid(), SubsId :: id()}], ets:continuation()}
    | '$end_of_table'.
matching_subscriptions(TopicUri, Ctxt, Limit) ->
    #{realm_uri := RealmUri} = Ctxt,
    MS = index_ms(RealmUri, TopicUri),
    Tab = subscription_index_table(RealmUri),
    ets:select(Tab, MS, Limit).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec matching_subscriptions(ets:continuation()) ->
    {[SessionId :: id()], ets:continuation()} | '$end_of_table'.
matching_subscriptions(Cont) ->
    ets:select(Cont).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_unsubscribe_all('$end_of_table', _, _) ->
    ok;
do_unsubscribe_all([], _, _) ->
    ok;
do_unsubscribe_all(#subscription{} = S, Tab, Ctxt) ->
    {RealmUri, _, SubsId} = Key = S#subscription.key,
    TopicUri = S#subscription.topic_uri,
    MatchPolicy = S#subscription.match_policy,
    IdxTab = subscription_index_table(RealmUri),
    IdxEntry = index_entry(SubsId, TopicUri, MatchPolicy, Ctxt),
    true = ets:delete_object(Tab, S),
    true = ets:delete_object(IdxTab, IdxEntry),
    do_unsubscribe_all(ets:next(Tab, Key), Tab, Ctxt);
do_unsubscribe_all({_, Sid, _} = Key, Tab, #{session_id := Sid} = Ctxt) ->
    do_unsubscribe_all(ets:lookup(Tab, Key), Tab, Ctxt);
do_unsubscribe_all(_, _, _) ->
    %% No longer our session
    ok.


%% @private
publish('$end_of_table', _Fun) ->
    ok;

publish({L, '$end_of_table'}, Fun) ->
    lists:foreach(Fun, L);

publish({L, Cont}, Fun ) ->
    ok = lists:foreach(Fun, L),
    publish(matching_subscriptions(Cont), Fun).


%% @private
session_subscriptions(RealmUri, SessionId, Limit) ->
    Pattern = #subscription{
        key = {RealmUri,  SessionId, '_'},
        topic_uri = '_',
        match_policy = '_'
    },
    Tab = subscription_table({RealmUri,  SessionId}),
    case Limit of
        infinity ->
            ets:match_object(Tab, Pattern);
        _ ->
            ets:match_object(Tab, Pattern, Limit)
    end.



%% =============================================================================
%% PRIVATE - MATCHING
%% =============================================================================



%% @private
-spec validate_match_policy(map()) -> binary().
validate_match_policy(Options) when is_map(Options) ->
    P = maps:get(<<"match">>, Options, ?EXACT_MATCH),
    P == ?EXACT_MATCH orelse P == ?PREFIX_MATCH orelse P == ?WILDCARD_MATCH
    orelse error({invalid_pattern_match_policy, P}),
    P.


%% @private
-spec subscription_table(tuple()) -> ets:tid().
subscription_table({_, _} = Key) ->
    tuplespace:locate_table(?SESSION_SUBSCRIPTION_TABLE_NAME, Key).


%% @private
-spec subscription_index_table(any()) -> ets:tid().
subscription_index_table(Key) ->
    tuplespace:locate_table(?SUBSCRIPTION_INDEX_TABLE_NAME, Key).


%% @private
%% @doc
%% Example:
%% uri_components(<<"com.mycompany.foo.bar">>) ->
%% {<<"com.mycompany">>, [<<"foo">>, <<"bar">>]}.
%% @end
-spec uri_components(uri()) -> [binary()].
uri_components(Uri) ->
    case binary:split(Uri, <<".">>, [global]) of
        [TopLevelDomain, AppName | Rest] when length(Rest) > 0 ->
            Domain = <<TopLevelDomain/binary, $., AppName/binary>>,
            [Domain | Rest];
        _Other ->
            %% Invalid Uri
            error({badarg, Uri})
    end.


%% @private
-spec index_entry(id(), uri(), binary(), juno_context:context()) ->
    #subscription_index{}.
index_entry(SubsId, TopicUri, Policy, Ctxt) ->
    #{realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    Entry = #subscription_index{
        session_id = SessionId,
        session_pid = juno_session:pid(SessionId),
        subscription_id = SubsId
    },
    Cs = [RealmUri | uri_components(TopicUri)],
    case Policy of
        ?EXACT_MATCH ->
            Entry#subscription_index{key = list_to_tuple(Cs)};
        ?PREFIX_MATCH ->
            Entry#subscription_index{key = list_to_tuple(Cs ++ [?ANY])};
        ?WILDCARD_MATCH ->
            %% Wildcard-matching allows to provide wildcards for *whole* URI
            %% components.
            Entry#subscription_index{key = list_to_tuple(Cs)}
    end.


%% @private
-spec index_ms(uri(), uri()) -> ets:match_spec().
index_ms(RealmUri, TopicUri) ->
    Cs = [RealmUri | uri_components(TopicUri)],
    ExactConds = [{'=:=', '$1', {const, list_to_tuple(Cs)}}],
    PrefixConds = prefix_conditions(Cs),
    WildcardConds = wilcard_conditions(Cs),
    Conds = lists:append([ExactConds, PrefixConds, WildcardConds]),
    MP = #subscription_index{
        key = '$1',
        session_id = '$2',
        session_pid = '$3',
        subscription_id = '$4'
    },
    Proj = [{{'$2', '$3', '$4'}}],
    [
        { MP, [list_to_tuple(['or' | Conds])], Proj }
    ].


%% @private
-spec prefix_conditions(list()) -> list().
prefix_conditions(L) ->
    prefix_conditions(L, []).


%% @private
-spec prefix_conditions(list(), list()) -> list().
prefix_conditions(L, Acc) when length(L) == 3 ->
    lists:reverse(Acc);
prefix_conditions(L0, Acc) ->
    L1 = lists:droplast(L0),
    C = {'=:=', '$1', {const, list_to_tuple(L1 ++ [?ANY])}},
    prefix_conditions(L1, [C|Acc]).


%% @private
-spec wilcard_conditions(list()) -> list().
wilcard_conditions([H|T] = L) ->
    Ordered = lists:zip(T, lists:seq(2, length(T) + 1)),
    Cs0 = [
        {'or',
            {'=:=', {element, N, '$1'}, {const, E}},
            {'=:=', {element, N, '$1'}, {const, <<>>}}
        } || {E, N} <- Ordered
    ],
    Cs1 = [{'=:=',{element, 1, '$1'}, {const, H}}, {'=:=', {size, '$1'}, {const, length(L)}} | Cs0],
    [list_to_tuple(['and' | Cs1])].
