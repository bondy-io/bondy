%% -----------------------------------------------------------------------------
%% @doc Implements Eviction amogst other things
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_retained_message_manager).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").


-record(state, {
}).


-export([counters/1]).
-export([incr_counters/3]).
-export([decr_counters/3]).
-export([default_ttl/0]).
-export([get/2]).
-export([match/1]).
-export([match/4]).
-export([match/5]).
-export([max_memory/0]).
-export([max_message_size/0]).
-export([max_messages/0]).
-export([put/4]).
-export([put/5]).
-export([start_link/0]).
-export([take/2]).

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
%% @end
%% -----------------------------------------------------------------------------
-spec get(Realm :: uri(), Topic :: uri()) ->
    bondy_retained_message:t() | undefined.

get(Realm, Topic) ->
    bondy_retained_message:get(Realm, Topic).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec take(Realm :: uri(), Topic :: uri()) ->
    bondy_retained_message:t() | undefined.

take(Realm, Topic) ->
    Mssg = bondy_retained_message:take(Realm, Topic),
    ok = maybe_decr_counters(get_counters_ref(Realm), Mssg),
    Mssg.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(bondy_retained_message:continuation()) ->
    {[bondy_retained_message:t()] | bondy_retained_message:continuation()}
    | bondy_retained_message:eot().

match(Cont) ->
    bondy_retained_message:match(Cont).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(
    Realm :: uri(),
    Topic :: uri(),
    SessionId :: id(),
    Strategy :: binary()) ->
    {[bondy_retained_message:t()], bondy_retained_message:continuation()}
    | bondy_retained_message:eot().

match(Realm, Topic, SessionId, Strategy) ->
    bondy_retained_message:match(Realm, Topic, SessionId, Strategy).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(
    Realm :: uri(),
    Topic :: uri(),
    SessionId :: id(),
    Strategy :: binary(),
    Opts :: plum_db:fold_opts()) ->
    {[bondy_retained_message:t()], bondy_retained_message:continuation()}
    | bondy_retained_message:eot().

match(Realm, Topic, SessionId, Strategy, Opts0) ->
    bondy_retained_message:match(Realm, Topic, SessionId, Strategy, Opts0).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec put(
    Realm :: uri(),
    Topic :: uri(),
    Event :: wamp_event(),
    MatchOpts :: bondy_retained_message:match_opts()) ->
    ok.

put(Realm, Topic, Event, MatchOpts) ->
    put(Realm, Topic, Event, MatchOpts, default_ttl()).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec put(
    Realm :: uri(),
    Topic :: uri(),
    Event :: wamp_event(),
    MatchOpts :: bondy_retained_message:match_opts(),
    TTL :: non_neg_integer() | undefined) -> ok.

put(Realm, Topic, Event, MatchOpts, undefined) ->
    put(Realm, Topic, Event, MatchOpts, default_ttl());

put(Realm, Topic, Event, MatchOpts, TTL) ->
    case bondy_retained_message:size(Event) =< max_message_size() of
        true ->
            N = max_messages(),
            MaxMem = max_memory(),

            case counters(Realm) of
                #{count := Val} when Val > N ->
                    bondy_alarm_handler:set_alarm({
                        retained_messages_count_limit,
                        <<"The number of retained messages has reached the system limit.">>
                    }),
                    ?LOG_INFO(#{
                        description => "Cannot retain message",
                        reason => count_limit,
                        realm_uri => Realm,
                        topic => Topic,
                        publication_id => Event#event.publication_id
                    }),
                    ok;
                #{memory := Val} when Val > MaxMem ->
                    bondy_alarm_handler:set_alarm({
                        retained_messages_memory_limit,
                        <<"The memory allocation for retained messages has reached the system limit.">>
                    }),
                    ?LOG_INFO(#{
                        description => "Cannot retain message",
                        reason => memory_limit,
                        realm_uri => Realm,
                        topic => Topic,
                        publication_id => Event#event.publication_id
                    }),
                    ok;
                _ ->
                    try
                        bondy_retained_message:put(
                            Realm, Topic, Event, MatchOpts, TTL
                        )
                    catch
                        Class:Reason:Stacktrace ->
                            ?LOG_WARNING(#{
                                class => Class,
                                reason => Reason,
                                stacktrace => Stacktrace
                            }),
                            ok
                    end
            end;
        false ->
            ?LOG_INFO(#{
                description => "Cannot retain message",
                reason => max_size_limit,
                realm_uri => Realm,
                topic => Topic,
                publication_id => Event#event.publication_id
            }),
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc The max size for an event message.
%% All events whose size exceeds this value will not be retained.
%% @end
%% -----------------------------------------------------------------------------
max_message_size() ->
    bondy_config:get([wamp_message_retention, max_message_size]).


%% -----------------------------------------------------------------------------
%% @doc Maximum space in memory used by retained messages.
%% Once the max has been reached no more events will be stored.
%% A value of 0 means no limit is enforced.
%% @end
%% -----------------------------------------------------------------------------
max_memory() ->
    bondy_config:get([wamp_message_retention, max_memory]).


%% -----------------------------------------------------------------------------
%% @doc Maximum number of messages that can be store in a Bondy node.
%% Once the max has been reached no more events will be stored.
%% A value of 0 means no limit is enforced.
%% @end
%% -----------------------------------------------------------------------------
max_messages() ->
    bondy_config:get([wamp_message_retention, max_messages]).


%% -----------------------------------------------------------------------------
%% @doc Default TTL for retained messages.
%% @end
%% -----------------------------------------------------------------------------
default_ttl() ->
    bondy_config:get([wamp_message_retention, default_ttl]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec counters(Realm :: uri()) -> #{messages => integer(), memory => integer()}.

counters(Realm) ->
    Ref = get_counters_ref(Realm),
    #{
        messages => counters:get(Ref, 1),
        memory => counters:get(Ref, 2)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
incr_counters(Realm, N, Size) ->
    Ref = get_counters_ref(Realm),
    ok = counters:add(Ref, 1, N),
    counters:add(Ref, 2, Size).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
decr_counters(Realm, N, Size) ->
    Ref = get_counters_ref(Realm),
    ok = counters:sub(Ref, 1, N),
    counters:sub(Ref, 2, Size).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).




%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->

    %% We subscribe to plum_db_events change notifications. We get updates
    %% in handle_info so that we can we update the tries
    MS = [{
        %% {{{_, _} = FullPrefix, Key}, NewObj, ExistingObj}
        {{{retained_messages, '_'}, '_'}, '_', '_'},
        [],
        [true]
    }],
    ok = plum_db_events:subscribe(object_update, MS),

    ok = init_evictor(),

    {ok, #state{}}.


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info(
    {plum_db_event, object_update, {{{_, Realm}, _Key}, Obj, PrevObj}},
    State) ->
    ?LOG_DEBUG(#{
        description => "Object update notification",
        object => Obj,
        previous => PrevObj
    }),
    case maybe_resolve(Obj) of
        '$deleted' when PrevObj =/= undefined ->
            %% We make sure we get the last event from the dvvset
            Reconciled = plum_db_object:resolve(PrevObj, lww),
            OldMessg = plum_db_object:value(Reconciled),
            maybe_decr_counters(Realm, OldMessg);
        '$deleted' when PrevObj == undefined ->
            %% We got a delete for an entry we do not know anymore.
            %% This happens when the registry has just been reset
            %% as we do not persist registrations any more
            ok;
        Mssg ->
            maybe_incr_counters(Realm, Mssg)
    end,
    {noreply, State};

handle_info(Info, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Info
    }),
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
%% PRIVATE
%% =============================================================================



%% @private
init_evictor() ->

    Decr = fun(Realm, Mssg) ->
        decr_counters(Realm, 1, bondy_retained_message:size(Mssg))
    end,
    Fun = fun() ->
        N = bondy_retained_message:evict_expired('_', Decr),
        _ = case N > 0 of
            true ->
                ?LOG_INFO(#{
                    description => "Evicted retained messages",
                    count => N
                }),
                ok;
            false ->
                ok
        end,
        %% We sleep for 60 secs (jobs standard min rate is 1/sec)
        timer:sleep(60 * 1000)
    end,

    ok = jobs:add_queue(bondy_retained_message_eviction, [
        {producer, Fun},
        {regulators, [
            {counter, [{limit, 1}]}
        ]}
    ]),

    ?LOG_NOTICE(#{description => "Retained message evictor initialised"}),
    ok.


%% @private
maybe_resolve(Object) ->
    case plum_db_object:value_count(Object) > 1 of
        true ->
            Resolved = plum_db_object:resolve(Object, lww),
            plum_db_object:value(Resolved);
        false ->
            plum_db_object:value(Object)
    end.


%% @private
maybe_incr_counters(Realm, Mssg) when is_tuple(Mssg) ->
    incr_counters(Realm, 1, bondy_retained_message:size(Mssg));

maybe_incr_counters(_, _) ->
    ok.


%% @private
maybe_decr_counters(Realm, Mssg) when is_tuple(Mssg) ->
    decr_counters(Realm, 1, bondy_retained_message:size(Mssg));

maybe_decr_counters(_, _) ->
    ok.



%% @private
get_counters_ref(Realm) ->
    case persistent_term:get({?MODULE, Realm, counters}, undefined) of
        undefined ->
            Ref = counters:new(2, [write_concurrency]),
            ok = persistent_term:put({?MODULE, Realm, counters}, Ref),
            Ref;
        Ref ->
            Ref
    end.
