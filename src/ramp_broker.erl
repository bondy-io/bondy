%% @doc
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
%% @end
-module(ramp_broker).
-behaviour(gen_server).
-include("ramp.hrl").

-define(LIMIT, 1000).
-define(POOL_NAME, ramp_broker_pool).
-define(SESSION_SUBSCRIPTION_TABLE_NAME, subscription).
-define(SUBSCRIPTION_INDEX_TABLE_NAME, subscription_index).

-record(state, {
    pool_type = permanent       :: permanent | transient,
    event                       :: term()
}).

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


%% API
-export([handle_message/2]).
-export([matching_subscriptions/1]).
-export([matching_subscriptions/2]).
-export([publish/5]).
-export([subscribe/3]).
-export([subscriptions/1]).
-export([subscriptions/2]).
-export([subscriptions/3]).
-export([unsubscribe_all/1]).
-export([unsubscribe/2]).

%% GEN_SERVER API
-export([start_pool/0]).
-export([pool_name/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% Handles a wamp message. This function is used by the ramp_router.
%% The message might be handled asynchronously by sending the message to the
%% broker worker pool.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: message(), Ctxt :: map()) ->
    {ok, NewCtxt :: ramp_context:context()}
    | {stop, NewCtxt :: ramp_context:context()}
    | {reply, Reply :: message(), NewCtxt :: ramp_context:context()}
    | {stop, Reply :: message(), NewCtxt :: ramp_context:context()}.
handle_message(#subscribe{} = M, Ctxt) ->
    ReqId = M#subscribe.request_id,
    Opts = M#subscribe.options,
    Topic = M#subscribe.topic_uri,
    %% REVIEW We currently do this synchronously
    {ok, SubsId} = subscribe(Topic, Opts, Ctxt),
    Reply = ramp_message:subscribed(ReqId, SubsId),
    {reply, Reply, Ctxt};

handle_message(#unsubscribe{} = M, Ctxt) ->
    ReqId = M#unsubscribe.request_id,
    SubsId = M#unsubscribe.subscription_id,
    %% REVIEW We currently do this synchronously
    Reply = case unsubscribe(SubsId, Ctxt) of
        ok ->
            ramp_message:unsubscribed(ReqId);
        {error, no_such_subscription} ->
            ramp_error:error(
                ?UNSUBSCRIBE, ReqId, #{}, ?WAMP_ERROR_NO_SUCH_SUBSCRIPTION
            )
    end,
    {reply, Reply, Ctxt};

handle_message(#publish{} = M, Ctxt) ->
    %% (RFC) Asynchronously notifies all subscribers of the published event.
    %% Note that the _Publisher_ of an event will never receive the
    %% published event even if the _Publisher_ is also a _Subscriber_ of the
    %% topic published to.
    %% By default, publications are unacknowledged, and the _Broker_ will
    %% not respond, whether the publication was successful indeed or not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    ReqId = M#publish.request_id,
    Opts = M#publish.options,
    Acknowledge = maps:get(<<"acknowledge">>, Opts, false),
    %% We ask a broker worker to handle the message
    case cast(M, Ctxt) of
        {ok, _}->
            %% The broker will conditionally reply when Acknowledge == true
            {ok, Ctxt};
        {error, Reason} when Acknowledge == true ->
            %% REVIEW are we using the right error uri?
            Reply = ramp_error:error(
                ?PUBLISH, ReqId, ramp:error_dict(Reason), ?WAMP_ERROR_CANCELED
            ),
            {reply, Reply, Ctxt};
        {error, _}->
            {ok, Ctxt}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the list of subscriptions for the active session.
%%
%% When called with a ramp:context() it is equivalent to calling
%% subscriptions/2 with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec subscriptions(
    ContextOrCont :: ramp_context:context() | ets:continuation()) ->
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
-spec subscribe(uri(), map(), ramp_context:context()) ->
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
            SubsId = ramp_id:new({session, SessionId}),
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
-spec unsubscribe_all(ramp_context:context()) -> ok | {error, any()}.
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



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unsubscribe(id(), ramp_context:context()) -> ok | {error, any()}.
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
-spec publish(uri(), map(), list(), map(), ramp_context:context()) ->
    {ok, id()} | {error, any()}.
publish(TopicUri, _Opts, Args, Payload, Ctxt) ->
    #{session_id := SessionId} = Ctxt,
    %% TODO Do publish
    PubId = ramp_id:new(global),
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
                    Pid ! ramp_message:event(
                        SubsId, PubId, Details, Args, Payload)
            end
    end,
    ok = publish(matching_subscriptions(TopicUri, Ctxt), Fun),
    {ok, PubId}.


%% @private
publish('$end_of_table', _Fun) ->
    ok;

publish({L, '$end_of_table'}, Fun) ->
    lists:foreach(Fun, L);

publish({L, Cont}, Fun ) ->
    ok = lists:foreach(Fun, L),
    publish(matching_subscriptions(Cont), Fun).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec matching_subscriptions(uri(), ramp_context:context()) ->
    {[{SessionId :: id(), pid(), SubsId :: id()}], ets:continuation()}
    | '$end_of_table'.
matching_subscriptions(TopicUri, Ctxt) ->
    matching_subscriptions(TopicUri, Ctxt, ?LIMIT).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec matching_subscriptions(
    uri(), ramp_context:context(), non_neg_integer()) ->
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
%% API : GEN_SERVER
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pool_name() -> atom().
pool_name() -> ?POOL_NAME.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_pool() -> ok.
start_pool() ->
    case do_start_pool() of
        {ok, _Child} -> ok;
        {ok, _Child, _Info} -> ok;
        {error, already_present} -> ok;
        {error, {already_started, _Child}} -> ok;
        {error, Reason} -> error(Reason)
    end.



%% =============================================================================
%% API : GEN_SERVER CALLBACKS
%% =============================================================================



init([?POOL_NAME]) ->
    %% We've been called by sidejob_worker
    %% TODO publish metaevent
    {ok, #state{pool_type = permanent}};

init([Event]) ->
    %% We've been called by sidejob_supervisor
    %% We immediately timeout so that we find ourselfs in handle_info.
    %% TODO publish metaevent

    State = #state{
        pool_type = transient,
        event = Event
    },
    {ok, State, 0}.


handle_call(Event, _From, State) ->
    try
        Reply = handle_event(Event, State),
        {reply, Reply, State}
    catch
        throw:abort ->
            %% TODO publish metaevent
            {reply, abort, State};
        _:Reason ->
            %% TODO publish metaevent
            error_logger:error_report([
                {reason, Reason},
                {stacktrace, erlang:get_stacktrace()}
            ]),
            {reply, {error, Reason}, State}
    end.


handle_cast(Event, State) ->
    try
        handle_event(Event, State),
        {noreply, State}
    catch
        throw:abort ->
            %% TODO publish metaevent
            {noreply, State};
        _:Reason ->
            %% TODO publish metaevent
            error_logger:error_report([
                {reason, Reason},
                {stacktrace, erlang:get_stacktrace()}
            ]),
            {noreply, State}
    end.



handle_info(timeout, #state{pool_type = transient} = State) ->
    ok = handle_event(State#state.event, State),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.


terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    %% TODO publish metaevent
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE : GEN_SERVER
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Asynchronously handles a message by either calling an existing worker or
%% spawning a new one depending on the ramp_broker_pool_type type.
%% This message will be handled by the worker's (gen_server)
%% handle_info callback function.
%% @end.
%% -----------------------------------------------------------------------------
-spec cast(term(), ramp_context:context()) -> ok | overload | {error, any()}.
cast(M, Ctxt) ->
    PoolName = pool_name(),
    Resp = case ramp_config:pool_type(PoolName) of
        permanent ->
            %% We send a request to an existing permanent worker
            %% using sidejob_worker
            sidejob:cast(PoolName, {M, Ctxt});
        transient ->
            %% We spawn a transient process with sidejob_supervisor
            sidejob_supervisor:start_child(
                PoolName,
                gen_server,
                start_link,
                [ramp_broker, [{M, Ctxt}], []]
            )
    end,
    return(Resp, PoolName, false).


%% @private
return(ok, _, _) ->
    ok;
return(overload, PoolName, _) ->
    error_logger:info_report([
        {reason, overload},
        {pool, PoolName}
    ]),
    %% TODO publish metaevent
    overload;
return({ok, _}, _, _) ->
    ok;
return({error, overload}, PoolName, _) ->
    error_logger:info_report([
        {reason, overload},
        {pool, PoolName}
    ]),
    overload;
return({error, Reason}, _, true) ->
    error(Reason);
return({error, _} = Error, _, false) ->
    Error.


%% @private
do_start_pool() ->
    Size = ramp_config:pool_size(?POOL_NAME),
    Capacity = ramp_config:pool_capacity(?POOL_NAME),
    case ramp_config:pool_type(?POOL_NAME) of
        permanent ->
            sidejob:new_resource(?POOL_NAME, ?MODULE, Capacity, Size);
        transient ->
            sidejob:new_resource(?POOL_NAME, sidejob_supervisor, Capacity, Size)
    end.


%% @private
handle_event({#publish{} = M, Ctxt}, _State) ->
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
            Reply = ramp_message:published(ReqId, PubId),
            To = ramp_session:pid(ramp_context:session(Ctxt)),
            ramp:send(Reply, To, Ctxt),
            %% TODO publish metaevent
            ok;
        {ok, _} ->
            %% TODO publish metaevent
            ok;
        {error, Reason} when Acknowledge == true->
            %% REVIEW use the right error uri
            Reply = ramp_error:error(
                ?PUBLISH, ReqId, ramp:error_dict(Reason), ?WAMP_ERROR_CANCELED
            ),
            ramp:send(Reply, Ctxt),
            %% TODO publish metaevent
            ok;
        {error, _} ->
            %% TODO publish metaevent
            ok
    end;

handle_event({#unsubscribe{} = M, Ctxt}, _State) ->
    ReqId = M#unsubscribe.request_id,
    SubsId = M#unsubscribe.subscription_id,
    Reply = case unsubscribe(SubsId, Ctxt) of
        ok ->
            ramp_message:unsubscribed(ReqId);
        {error, no_such_subscription} ->
            ramp_error:error(
                ?UNSUBSCRIBE, ReqId, #{}, ?WAMP_ERROR_NO_SUCH_SUBSCRIPTION
            )
    end,
    ramp:send(Reply, Ctxt),
    ok.



%% =============================================================================
%% PRIVATE - MATCHING
%% =============================================================================



%% @private
validate_match_policy(Options) when is_map(Options) ->
    P = maps:get(<<"match">>, Options, <<"exact">>),
    P == <<"exact">> orelse P == <<"prefix">> orelse P == <<"wildcard">>
    orelse error({invalid_pattern_match_policy, P}),
    P.


%% @private
subscription_table({_, _} = Key) ->
    tuplespace:locate_table(?SESSION_SUBSCRIPTION_TABLE_NAME, Key).


%% @private
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
index_entry(SubsId, TopicUri, Policy, Ctxt) ->
    #{realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    Entry = #subscription_index{
        session_id = SessionId,
        session_pid = ramp_session:pid(SessionId),
        subscription_id = SubsId
    },
    Cs = [RealmUri | uri_components(TopicUri)],
    case Policy of
        <<"exact">> ->
            Entry#subscription_index{key = list_to_tuple(Cs)};
        <<"prefix">> ->
            Entry#subscription_index{key = list_to_tuple(Cs ++ [<<"*">>])};
        <<"wildcard">> ->
            %% Wildcard-matching allows to provide wildcards for *whole* URI
            %% components.
            Entry#subscription_index{key = list_to_tuple(Cs)}
    end.


%% @private
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
prefix_conditions(L) ->
    prefix_conditions(L, []).


%% @private
prefix_conditions(L, Acc) when length(L) == 3 ->
    lists:reverse(Acc);
prefix_conditions(L0, Acc) ->
    L1 = lists:droplast(L0),
    C = {'=:=', '$1', {const, list_to_tuple(L1 ++ [<<"*">>])}},
    prefix_conditions(L1, [C|Acc]).


%% @private
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
