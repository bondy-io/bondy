%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2016. All rights reserved.
%% =============================================================================


-module(juno_stats).
-behaviour(gen_server).

-define(POOL_NAME, juno_stats_pool).


-record(state, {
    pool_type = permanent       ::  permanent | transient,
    event                       ::  tuple()
}).

-export([update/1]).
-export([update/2]).
-export([get_stats/0]).
-export([create_metrics/0]).
-export([start_pool/0]).

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
-spec start_pool() -> ok.
start_pool() ->
    case do_start_pool() of
        {ok, _Child} -> ok;
        {ok, _Child, _Info} -> ok;
        {error, already_present} -> ok;
        {error, {already_started, _Child}} -> ok;
        {error, Reason} -> error(Reason)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec create_metrics() -> ok.

create_metrics() ->
    %% TODO Process aliases
    lists:foreach(
        fun({Name, Type , Opts, _Aliases}) ->
            exometer:new(Name, Type, Opts)
        end,
        static_specs()
    ).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_stats() -> any().
get_stats() ->
    exometer:get_values([juno]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(tuple()) -> ok.
update(Event) ->
    async_update(Event).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(wamp_message:message(), juno_context:context()) -> ok.

update(M, #{peer := {IP, _}} = Ctxt) ->
    Type = element(1, M),
    Size = erts_debug:flat_size(M) * 8,
    case Ctxt of
        #{realm_uri := Uri, session := S} ->
            async_update({message, Uri, juno_session:id(S), IP, Type, Size});
        #{realm_uri := Uri} ->
            async_update({message, Uri, IP, Type, Size});
        _ ->
            async_update({message, IP, Type, Size})
    end.


%% =============================================================================
%% API : GEN_SERVER CALLBACKS
%% =============================================================================



init([?POOL_NAME]) ->
    %% We've been called by sidejob_worker
    %% We will be called via a a cast (handle_cast/2)
    %% TODO publish metaevent and stats
    {ok, #state{pool_type = permanent}};

init([Event]) ->
    %% We've been called by sidejob_supervisor
    %% We immediately timeout so that we find ourselfs in handle_info/2.
    %% TODO publish metaevent and stats
    State = #state{
        pool_type = transient,
        event = Event
    },
    {ok, State, 0}.


handle_call(Event, _From, State) ->
    lager:debug("Received unknown call ~p.", [Event]),
    {noreply, State}.


handle_cast(Event, State) ->
    try
        ok = do_update(Event)
    catch
        Class:Reason ->
            lager:debug(
                "Failed to update stat ~p due to (~p) ~p.", 
                [Event, Class, Reason])
    end,
    {noreply, State}.


handle_info(timeout, #state{pool_type = transient} = State) ->
    %% We've been spawned to handle this single event, so we should stop after
    ok = do_update(State#state.event),
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
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.




%% =============================================================================
%% PRIVATE
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Actually starts a sidejob pool based on system configuration.
%% @end
%% -----------------------------------------------------------------------------
do_start_pool() ->
    Size = juno_config:pool_size(?POOL_NAME),
    Capacity = juno_config:pool_capacity(?POOL_NAME),
    case juno_config:pool_type(?POOL_NAME) of
        permanent ->
            sidejob:new_resource(?POOL_NAME, ?MODULE, Capacity, Size);
        transient ->
            sidejob:new_resource(?POOL_NAME, sidejob_supervisor, Capacity, Size)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
async_update(Event) ->
    PoolName = ?POOL_NAME,
    PoolType = juno_config:pool_type(PoolName),
    case async_update(PoolType, PoolName, Event) of
        ok ->
            ok;
        {ok, _} ->
            ok;
        overload ->
            overload
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Helper function for {@link async_route_event/2}
%% @end
%% -----------------------------------------------------------------------------
async_update(permanent, PoolName, Event) ->
    %% We send a request to an existing permanent worker
    %% using juno_stats acting as a sidejob_worker
    sidejob:unbounded_cast(PoolName, Event);

async_update(transient, PoolName, Event) ->
    %% We spawn a transient worker using sidejob_supervisor
    sidejob_supervisor:start_child(
        PoolName,
        gen_server,
        start_link,
        [?MODULE, [Event], []]
    ).



%% @private
do_update({session_opened, Realm, _SessionId, IP}) ->
    BIP = list_to_binary(inet_parse:ntoa(IP)),
    exometer:update([juno, sessions], 1),
    exometer:update([juno, sessions, active], 1),

    exometer:update_or_create(
        [juno, realm, sessions, Realm], 1, spiral, []),
    exometer:update_or_create(
        [juno, realm, sessions, active, Realm], 1, counter, []),
    
    exometer:update_or_create(
        [juno, ip, sessions, BIP], 1, spiral, []),
    exometer:update_or_create(
        [juno, ip, sessions, active, BIP], 1, counter, []);

do_update({session_closed, Realm, SessionId, IP, Secs}) ->
    BIP = list_to_binary(inet_parse:ntoa(IP)),
    exometer:update([juno, sessions, active], -1),
    exometer:update([juno, sessions, duration], Secs),

    exometer:update_or_create(
        [juno, realm, sessions, active, Realm], -1, []),
    exometer:update_or_create(
        [juno, realm, sessions, duration, Realm], Secs, []),
    
    exometer:update_or_create(
        [juno, ip, sessions, active, BIP], -1, []),
    exometer:update_or_create(
        [juno, ip, sessions, duration, BIP], Secs, []),
    
    %% Cleanup
    exometer:delete([juno, session, messages, SessionId]),
    lists:foreach(
        fun({Name, _, _}) ->
            exometer:delete(Name)
        end,
        exometer:find_entries([juno, session, messages, '_', SessionId])
    ), 
    ok;

do_update({message, IP, Type, Sz}) ->
    BIP = list_to_binary(inet_parse:ntoa(IP)),
    exometer:update([juno, messages], 1),
    exometer:update([juno, messages, size], Sz),
    exometer:update_or_create([juno, messages, Type], 1, spiral, []),

    exometer:update_or_create(
        [juno, ip, messages, BIP], 1, counter, []),
    exometer:update_or_create(
        [juno, ip, messages, size, BIP], Sz, histogram, []),
    exometer:update_or_create(
        [juno, ip, messages, Type, BIP], 1, spiral, []);


do_update({message, Realm, IP, Type, Sz}) ->
    BIP = list_to_binary(inet_parse:ntoa(IP)),
    exometer:update([juno, messages], 1),
    exometer:update([juno, messages, size], Sz),
    exometer:update_or_create([juno, messages, Type], 1, spiral, []),

    exometer:update_or_create(
        [juno, ip, messages, BIP], 1, counter, []),
    exometer:update_or_create(
        [juno, ip, messages, size, BIP], Sz, histogram, []),
    exometer:update_or_create(
        [juno, ip, messages, Type, BIP], 1, spiral, []),

    exometer:update_or_create(
        [juno, realm, messages, Realm], 1, counter, []),
    exometer:update_or_create(
        [juno, realm, messages, size, Realm], Sz, histogram, []),
    exometer:update_or_create(
        [juno, realm, messages, Type, Realm], 1, spiral, []);

do_update({message, Realm, Session, IP, Type, Sz}) ->
    BIP = list_to_binary(inet_parse:ntoa(IP)),
    exometer:update([juno, messages], 1),
    exometer:update([juno, messages, size], Sz),
    exometer:update_or_create([juno, messages, Type], 1, spiral, []),

    exometer:update_or_create(
        [juno, ip, messages, BIP], 1, counter, []),
    exometer:update_or_create(
        [juno, ip, messages, size, BIP], Sz, histogram, []),
    exometer:update_or_create(
        [juno, ip, messages, Type, BIP], 1, spiral, []),

    exometer:update_or_create(
        [juno, realm, messages, Realm], 1, counter, []),
    exometer:update_or_create(
        [juno, realm, messages, size, Realm], Sz, histogram, []),
    exometer:update_or_create(
        [juno, realm, messages, Type, Realm], 1, spiral, []),

    exometer:update_or_create(
        [juno, session, messages, Session], 1, counter, []),
    exometer:update_or_create(
        [juno, session, messages, size, Session], Sz, histogram, []),
    exometer:update_or_create(
        [juno, session, messages, Type, Session], 1, spiral, []).




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
static_specs() ->
    [
        {[juno, sessions], 
            spiral, [], [
                {one, sessions}, 
                {count, sessions_total}]},
        {[juno, messages], 
            spiral, [], [
                {one, messages}, 
                {count, messages_total}]},
        {[juno, requests], 
            spiral, [], [
                {one, requests}, 
                {count, requests_total}]},
        {[juno, sessions, active], 
            counter, [], [
                {value, sessions_active}]},
        {[juno, sessions, duration], 
            histogram, [], [
                {mean, sessions_duration_mean},
                {median, sessions_duration_median},
                {95, sessions_duration_95},
                {99, sessions_duration_99},
                {max, sessions_duration_100}]}
    ].


