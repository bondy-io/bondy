%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% The Juno Router provides the routing logic for all interactions.
%% In general juno_router handles all messages asynchronously. It does this by
%% using either a static or a dynamic pool of workers based on configuration.
%% A dynamic pool actually spawns a new erlang process for each message.
%% By default a Juno Router uses a dynamic pool.
%%
%% This module implements both type of workers as a gen_server.
%%
%% A router provides load regulation, in case a maximum capacity has been
%% reached, the router will handle the message synchronously i.e. blocking the
%% calling processes (usually the one that handles the transport connection
%% e.g. {@link juno_ws_handler}).
%%
%% This module handles only the concurrency and basic routing logic, 
%% delegating the rest to either {@link juno_broker} or {@link juno_dealer}.
%%
%%
%%
%% ,------.                                    ,------.
%% | Peer |                                    | Peer |
%% `--+---'                                    `--+---'
%%    |                                           |
%%    |               TCP established             |
%%    |<----------------------------------------->|
%%    |                                           |
%%    |               TLS established             |
%%    |+<--------------------------------------->+|
%%    |+                                         +|
%%    |+           WebSocket established         +|
%%    |+|<------------------------------------->|+|
%%    |+|                                       |+|
%%    |+|            WAMP established           |+|
%%    |+|+<----------------------------------->+|+|
%%    |+|+                                     +|+|
%%    |+|+                                     +|+|
%%    |+|+            WAMP closed              +|+|
%%    |+|+<----------------------------------->+|+|
%%    |+|                                       |+|
%%    |+|                                       |+|
%%    |+|            WAMP established           |+|
%%    |+|+<----------------------------------->+|+|
%%    |+|+                                     +|+|
%%    |+|+                                     +|+|
%%    |+|+            WAMP closed              +|+|
%%    |+|+<----------------------------------->+|+|
%%    |+|                                       |+|
%%    |+|           WebSocket closed            |+|
%%    |+|<------------------------------------->|+|
%%    |+                                         +|
%%    |+              TLS closed                 +|
%%    |+<--------------------------------------->+|
%%    |                                           |
%%    |               TCP closed                  |
%%    |<----------------------------------------->|
%%    |                                           |
%% ,--+---.                                    ,--+---.
%% | Peer |                                    | Peer |
%% `------'                                    `------'
%%
%% @end
%% =============================================================================
-module(juno_router).
-behaviour(gen_server).
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(POOL_NAME, juno_router_pool).
-define(ROUTER_ROLES, #{
    broker => ?BROKER_FEATURES,
    dealer => ?DEALER_FEATURES
}).

-type event()                   ::  {message(), juno_context:context()}.

-record(state, {
    pool_type = permanent       ::  permanent | transient,
    event                       ::  event()
}).

%% API
-export([roles/0]).
-export([handle_message/2]).
-export([start_pool/0]).
%% -export([has_role/2]). ur, ctxt
%% -export([add_role/2]). uri, ctxt
%% -export([remove_role/2]). uri, ctxt
%% -export([authorise/4]). session, uri, action, ctxt
%% -export([start_realm/2]). uri, ctxt
%% -export([stop_realm/2]). uri, ctxt

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
-spec roles() -> #{broker => map(), dealer => map()}.
roles() ->
    ?ROUTER_ROLES.


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
%% Handles a wamp message.
%% The message might be handled synchronously (it is performed by the calling
%% process i.e. the transport handler) or asynchronously (by sending the
%% message to the router worker pool).
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: message(), Ctxt :: juno_context:context()) ->
    {ok, juno_context:context()}
    | {reply, Reply :: message(), juno_context:context()}
    | {stop, Reply :: message(), juno_context:context()}.

handle_message(#hello{} = M, #{session_id := _} = Ctxt) ->
    %% Client already has a session!
    %% RFC:
    %% It is a protocol error to receive a second "HELLO" message during the
    %% lifetime of the session and the _Peer_ must fail the session if that
    %% happens
    ok = update_stats(M, Ctxt),
    abort(
        ?JUNO_SESSION_ALREADY_EXISTS, 
        <<"You've sent a HELLO message more than once.">>, Ctxt);

handle_message(#hello{} = M, #{challenge_sent := true} = Ctxt) ->
    %% Client does not have a session but we already sent a challenge message
    %% Similar case as above
    ok = update_stats(M, Ctxt),
    abort(
        ?WAMP_ERROR_CANCELED, 
        <<"You've sent a HELLO message more than once.">>, Ctxt);

handle_message(#hello{realm_uri = Uri} = M, Ctxt0) ->
    %% Client is requesting a session
    Ctxt1 = Ctxt0#{realm_uri => Uri},
    ok = update_stats(M, Ctxt1),
    %% This will return either reply with wamp_welcome() | wamp_challenge()
    %% or abort 
    maybe_open_session(
        juno_auth:authenticate(M#hello.details, Ctxt1));

handle_message(#authenticate{} = M, #{session_id := _} = Ctxt) ->
    %% Client already has a session so is already authenticated.
    ok = update_stats(M, Ctxt),
    abort(
        ?JUNO_SESSION_ALREADY_EXISTS, 
        <<"You've sent an AUTHENTICATE message more than once.">>, 
        Ctxt);

handle_message(#authenticate{} = M, #{challenge_sent := true} = Ctxt0) ->
    %% Client is responding to a challenge
    ok = update_stats(M, Ctxt0),
    #authenticate{signature = Signature, extra = Extra} = M,
    case juno_auth:authenticate(Signature, Extra, Ctxt0) of
        {ok, Ctxt1} ->
            open_session(Ctxt1);
        {error, Reason, Ctxt1} ->
            abort(?WAMP_ERROR_AUTHORIZATION_FAILED, Reason, Ctxt1)
    end;
            
handle_message(#authenticate{} = M, Ctxt) ->
    %% Client does not have a session and has not been sent a challenge?
    ok = update_stats(M, Ctxt),
    abort(
        ?WAMP_ERROR_CANCELED, <<"You've sent an AUTHENTICATE message.">>, Ctxt);

handle_message(M, #{session_id := _} = Ctxt) ->
    %% Client has a session so this should be either a message
    %% for broker or dealer roles
    ok = update_stats(M, Ctxt),
    handle_session_message(M, Ctxt);

handle_message(_M, Ctxt) ->
    %% Client does not have a session and message is not HELLO
    abort(
        ?JUNO_ERROR_NOT_IN_SESSION, 
        <<"You need to establish a session first.">>, 
        Ctxt).




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
    error_logger:error_report([
        {reason, unsupported_event},
        {event, Event}
    ]),
    {noreply, State}.


handle_cast(Event, State) ->
    try
        ok = route_event(Event),
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


handle_info(timeout, #state{pool_type = transient, event = Event} = State)
when Event /= undefined ->
    %% We've been spawned to handle this single event, so we should stop after
    ok = route_event(Event),
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




%% @private
maybe_open_session({ok, Ctxt}) ->
    open_session(Ctxt);

maybe_open_session({error, {realm_not_found, Uri}, Ctxt}) ->
    abort(
        ?WAMP_ERROR_NO_SUCH_REALM,
        <<"Realm '", Uri/binary, "' does not exist.">>,
        Ctxt
    );

maybe_open_session({error, {missing_param, Param}, Ctxt}) ->
    abort(
        ?WAMP_ERROR_CANCELED,
        <<"Missing value for required parameter '", Param/binary, "'.">>,
        Ctxt
    );

maybe_open_session({error, {user_not_found, AuthId}, Ctxt}) ->
    abort(
        ?WAMP_ERROR_CANCELED,
        <<"User '", AuthId/binary, "' does not exist.">>,
        Ctxt
    );

maybe_open_session({challenge, AuthMethod, Challenge, Ctxt0}) ->
    M = wamp_message:challenge(AuthMethod, Challenge),
    Ctxt1 = Ctxt0#{
        challenge_sent => true % to avoid multiple hellos
    },
    ok = update_stats(M, Ctxt1),
    {reply, M, Ctxt1}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%% -----------------------------------------------------------------------------
-spec open_session(juno_context:context()) ->
    {reply, message(), juno_context:context()}
    | {stop, message(), juno_context:context()}.

open_session(Ctxt0) ->
    try 
        #{
            realm_uri := Uri, 
            id := Id, 
            request_details := Details
        } = Ctxt0,
        _Session = juno_session:open(Id, maps:get(peer, Ctxt0), Uri, Details),
    
        Ctxt1 = Ctxt0#{
            session_id => Id,
            roles => parse_roles(maps:get(roles, Details))
        },

        Welcome = wamp_message:welcome(
            Id,
            #{
                agent => ?JUNO_VERSION_STRING,
                roles => ?ROUTER_ROLES
            }
        ),
        ok = update_stats(Welcome, Ctxt1),
        {reply, Welcome, Ctxt1}
    catch
        error:{invalid_options, missing_client_role} ->
            abort(
                <<"wamp.error.missing_client_role">>, 
                <<"Please provide at least one client role.">>,
                Ctxt0)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%% -----------------------------------------------------------------------------
-spec handle_session_message(M :: message(), Ctxt :: map()) ->
    {ok, juno_context:context()}
    | {stop, Reply :: message(), juno_context:context()}
    | {reply, Reply :: message(), juno_context:context()}.

handle_session_message(#goodbye{}, #{goodbye_initiated := true} = Ctxt) ->
    %% The client is replying to our goodbye() message.
    {stop, Ctxt};

handle_session_message(#goodbye{} = M, Ctxt) ->
    %% Goodbye initiated by client, we reply with goodbye().
    #{session_id := SessionId} = Ctxt,
    error_logger:info_report(
        "Session ~p closed as per client request. Reason: ~p~n",
        [SessionId, M#goodbye.reason_uri]
    ),
    Reply = wamp_message:goodbye(#{}, ?WAMP_ERROR_GOODBYE_AND_OUT),
    ok = update_stats(Reply, Ctxt),
    {stop, Reply, Ctxt};

handle_session_message(M, Ctxt0) ->
    %% Client already has a session.
    %% By default, publications are unacknowledged, and the _Broker_ will
    %% not respond, whether the publication was successful indeed or not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    Acknowledge = acknowledge_message(M),
    %% We asynchronously handle the message by sending it to the router pool
    try async_route_event(M, Ctxt0) of
        ok ->
            {ok, Ctxt0};
        overload ->
            error_logger:info_report([{reason, overload}, {pool, ?POOL_NAME}]),
            %% TODO publish metaevent and stats
            %% TODO use throttling and send error to caller conditionally
            %% We do it synchronously i.e. blocking the caller
            ok = route_event({M, Ctxt0}),
            {ok, Ctxt0}
    catch
        error:Reason when Acknowledge == true ->
            %% TODO Maybe publish metaevent and stats
            %% REVIEW are we using the right error uri?
            Reply = wamp_message:error(
                ?UNSUBSCRIBE,
                M#unsubscribe.request_id,
                juno:error_dict(Reason),
                ?WAMP_ERROR_CANCELED
            ),
            ok = update_stats(Reply, Ctxt0),
            {reply, Reply, Ctxt0};
        _:_ ->
            %% TODO Maybe publish metaevent and stats
            {ok, Ctxt0}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec acknowledge_message(map()) -> boolean().
acknowledge_message(#publish{options = Opts}) ->
    maps:get(acknowledge, Opts, false);

acknowledge_message(_) ->
    true.



%% =============================================================================
%% PRIVATE : GEN_SERVER
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Asynchronously handles a message by either sending it to an 
%% existing worker or spawning a new one depending on the juno_broker_pool_type 
%% type.
%% This message will be handled by the worker's (gen_server)
%% handle_info callback function.
%% @end.
%% -----------------------------------------------------------------------------
-spec async_route_event(message(), juno_context:context()) -> ok | overload.
async_route_event(M, Ctxt) ->
    PoolName = ?POOL_NAME,
    PoolType = juno_config:pool_type(PoolName),
    case async_route_event(PoolType, PoolName, M, Ctxt) of
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
async_route_event(permanent, PoolName, M, Ctxt) ->
    %% We send a request to an existing permanent worker
    %% using juno_router acting as a sidejob_worker
    sidejob:cast(PoolName, {M, Ctxt});

async_route_event(transient, PoolName, M, Ctxt) ->
    %% We spawn a transient worker using sidejob_supervisor
    sidejob_supervisor:start_child(
        PoolName,
        gen_server,
        start_link,
        [?MODULE, [{M, Ctxt}], []]
    ).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end.
%% -----------------------------------------------------------------------------
-spec route_event(event()) -> ok.
route_event({#subscribe{} = M, Ctxt}) ->
    juno_broker:handle_message(M, Ctxt);

route_event({#unsubscribe{} = M, Ctxt}) ->
    juno_broker:handle_message(M, Ctxt);

route_event({#publish{} = M, Ctxt}) ->
    juno_broker:handle_message(M, Ctxt);

route_event({#register{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({#unregister{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({#call{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({#cancel{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({#yield{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({#error{request_type = ?INVOCATION} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

route_event({M, _Ctxt}) ->
    error({unexpected_message, M}).


%% ------------------------------------------------------------------------
%% private
%% @doc
%% Merges the client provided role features with the ones provided by
%% the router. This will become the feature set used by the router on
%% every session request.
%% @end
%% ------------------------------------------------------------------------
parse_roles(Roles) ->
    parse_roles(maps:keys(Roles), Roles).


%% @private
parse_roles([], Roles) ->
    Roles;

parse_roles([caller|T], Roles) ->
    F = juno_utils:merge_map_flags(
        maps:get(caller, Roles), ?CALLER_FEATURES),
    parse_roles(T, Roles#{caller => F});

parse_roles([callee|T], Roles) ->
    F = juno_utils:merge_map_flags(
        maps:get(callee, Roles), ?CALLEE_FEATURES),
    parse_roles(T, Roles#{callee => F});

parse_roles([subscriber|T], Roles) ->
    F = juno_utils:merge_map_flags(
        maps:get(subscriber, Roles), ?SUBSCRIBER_FEATURES),
    parse_roles(T, Roles#{subscriber => F});

parse_roles([publisher|T], Roles) ->
    F = juno_utils:merge_map_flags(
        maps:get(publisher, Roles), ?PUBLISHER_FEATURES),
    parse_roles(T, Roles#{publisher => F});

parse_roles([_|T], Roles) ->
    parse_roles(T, Roles).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update_stats(wamp_message:message(), juno_context:context()) -> ok.
update_stats(M, Ctxt) ->
    Type = element(1, M),
    Size = erts_debug:flat_size(M) * 8,
    Realm = juno_context:realm_uri(Ctxt),
    {IP, _} = juno_context:peer(Ctxt),
    case juno_context:session_id(Ctxt) of
        undefined ->
            juno_stats:update(
                {message, Realm, IP, Type, Size});
        SessionId ->
            juno_stats:update(
                {message, Realm, SessionId, IP, Type, Size})
    end.


%% @private
abort(Type, Reason, Ctxt) ->
    M = wamp_message:abort(#{message => Reason}, Type),
    ok = update_stats(M, Ctxt),
    {stop, M, Ctxt}.