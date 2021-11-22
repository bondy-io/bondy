-module(bondy_edge_uplink_server).
-behaviour(gen_statem).
-behaviour(ranch_protocol).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include_lib("bondy.hrl").

-define(TIMEOUT, 30000).

-define(SOCKET_DATA(Tag), Tag == tcp orelse Tag == ssl).
-define(SOCKET_ERROR(Tag), Tag == tcp_error orelse Tag == ssl_error).
-define(CLOSED_TAG(Tag), Tag == tcp_closed orelse Tag == ssl_closed).
% -define(PASSIVE_TAG(Tag), Tag == tcp_passive orelse Tag == ssl_passive).


-record(state, {
    ref                     ::  atom(),
    transport               ::  module(),
    opts                    ::  key_value:t(),
    socket                  ::  gen_tcp:socket() | ssl:sslsocket(),
    idle_timeout            ::  pos_integer(),
    ping_retry              ::  maybe(bondy_retry:t()),
    ping_retry_tref         ::  maybe(timer:ref()),
    ping_sent               ::  maybe({Ref :: timer:ref(), Data :: binary()}),
    sessions = #{}          ::  #{uri() => bondy_edge:session()},
    session                 ::  maybe(map()),
    auth_realm              ::  binary(),
    start_ts                ::  pos_integer()
}).

% -type t()                   ::  #state{}.

%% API.
-export([start_link/3]).
-export([start_link/4]).

%% GEN_STATEM CALLBACKS
-export([callback_mode/0]).
-export([init/1]).
-export([terminate/3]).
-export([code_change/4]).

%% STATE FUNCTIONS
-export([connected/3]).

%% TODO pings should only be allowed if we have at least one session, otherwise
%% they do not count towads the idle_timeout.
%% At least one session has to be active for the connection to stay
%% online.



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link(Ref, Transport, Opts) ->
	gen_statem:start_link(?MODULE, {Ref, Transport, Opts}, []).


%% -----------------------------------------------------------------------------
%% @doc
%% This will be deprecated with Ranch 2.0
%% @end
%% -----------------------------------------------------------------------------
start_link(Ref, _, Transport, Opts) ->
    start_link(Ref, Transport, Opts).



%% =============================================================================
%% GEN_STATEM CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
callback_mode() ->
	[state_functions, state_enter].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init({Ref, Transport, Opts}) ->
    State0 = #state{
        ref = Ref,
        transport = Transport,
        opts = Opts,
        idle_timeout = key_value:get(idle_timeout, Opts, timer:minutes(1)),
        start_ts = erlang:system_time(millisecond)
    },

    %% Setup ping
    PingOpts = key_value:get(ping, Opts, []),

    State = case key_value:get(enabled, PingOpts, false) of
        true ->
            State0#state{
                ping_retry = bondy_retry:init(ping, PingOpts)
            };
        false ->
            State0
    end,

    %% How much time till we get
    Timeout = key_value:get(auth_timeout, Opts, 5000),

	{ok, connected, State, Timeout}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
terminate(Reason, StateName, #state{transport = T, socket = S} = State)
when T =/= undefined andalso S =/= undefined ->
    ?LOG_DEBUG(#{
        description => "Closing connection",
        reason => Reason
    }),
    catch T:close(S),
    ok = on_close(Reason, State),
    NewState = State#state{transport = undefined, socket = undefined},
    terminate(Reason, StateName, NewState);

terminate(_Reason, _StateName, _StateData) ->
	ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
code_change(_OldVsn, StateName, StateData, _Extra) ->
	{ok, StateName, StateData}.



%% =============================================================================
%% STATE FUNCTIONS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
connected(enter, connected, State) ->
    Ref = State#state.ref,
    Transport = State#state.transport,

    Opts = [
        binary,
        {packet, 4},
        {active, once}
        | bondy_config:get([Ref, socket_opts], [])
    ],

    %% Setup and configure socket
    {ok, Socket} = ranch:handshake(Ref),
	ok = Transport:setopts(Socket, Opts),

    {ok, Peername} = inet:peername(Socket),
    PeernameBin = inet_utils:peername_to_binary(Peername),

    ok = bondy_logger_utils:set_process_metadata(#{
        transport => Transport,
        peername => PeernameBin,
        socket => Socket
    }),

    ok = on_connect(State),

    {keep_state, State#state{socket = Socket}};

connected(internal, {hello, _, _}, #state{session = Session} = State)
when Session =/= undefined ->
    %% Session already being established, wrong message
    ok = send_message({abort, #{}, protocol_violation}, State),
    {stop, State};

connected(internal, {hello, Uri, Details}, State0) ->
    %% TODO validate Details
    ?LOG_DEBUG(#{
        description => "Got hello",
        details => Details
    }),
    try

        Realm = bondy_realm:get(Uri),

        bondy_realm:allow_connections(Realm)
            orelse throw(connections_not_allowed),

        State = challenge(Realm, Details, State0),
        {keep_state, State, [idle_timeout(State)]}

    catch
        error:{not_found, Uri} ->
            Reason = no_such_realm,
            ok = send_message({abort, #{}, Reason}, State0),
            {stop, State0};

        throw:Reason ->
            ok = send_message({abort, #{}, Reason}, State0),
            {stop, State0}

    end;

connected(internal, {authenticate, Signature, Extra}, State0) ->
    %% TODO validate Details
    ?LOG_DEBUG(#{
        description => "Got authenticate",
        signature => Signature,
        extra => Extra
    }),

    try

        State = authenticate(<<"cryptosign">>, Signature, Extra, State0),
        {keep_state, State, [idle_timeout(State)]}

    catch
        throw:Reason ->
            ok = send_message({abort, #{}, Reason}, State0),
            {stop, State0}
    end,

    keep_state_and_data;

connected(info, {Tag, Socket, Data}, #state{socket = Socket} = State)
when ?SOCKET_DATA(Tag) ->
    ok = set_socket_active(State),
	Actions = [
        {next_event, internal, binary_to_term(Data)},
        idle_timeout(State)
    ],
	{keep_state_and_data, Actions};

connected(info, {Tag, _Socket}, _) when ?CLOSED_TAG(Tag) ->
	{stop, normal};

connected(info, {Tag, _, Reason}, _) when ?SOCKET_ERROR(Tag) ->
    ?LOG_INFO(#{
        description => "Edge connection closed due to error",
        reason => Reason
    }),
	{stop, Reason};

connected(info, Msg, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => info,
        event => Msg
    }),
	keep_state_and_data;

connected({call, From}, Request, _) ->
    ?LOG_INFO(#{
        description => "Received unknown request",
        type => call,
        event => Request
    }),
	gen_statem:reply(From, {error, badcall}),
	keep_state_and_data;

connected(cast, Msg, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => cast,
        event => Msg
    }),
	keep_state_and_data;

connected(timeout, _Msg, _) ->
    ?LOG_INFO(#{
        description => "Closing connection",
        reason => timeout
    }),
	{stop, normal};

connected(_EventType, _Msg, _) ->
	{stop, normal}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



challenge(Realm, Details, State0) ->
    {ok, Peer} = inet:peername(State0#state.socket),
    Sessions0 = State0#state.sessions,

    Uri = bondy_realm:uri(Realm),
    SessionId = bondy_utils:get_id(global),
    Authid = maps:get(authid, Details),
    Roles = maps:get(authroles, Details, []),

    case bondy_auth:init(SessionId, Realm, Authid, Roles, Peer) of
        {ok, AuthCtxt} ->
            %% TODO take it from conf
            ReqMethods = [<<"cryptosign">>],
            case bondy_auth:available_methods(ReqMethods, AuthCtxt) of
                [] ->
                    throw({no_authmethod, ReqMethods});

                [Method|_] ->
                    Session = #{
                        id => SessionId,
                        authid => Authid,
                        realm => bondy_realm:uri(Realm),
                        auth_context => AuthCtxt
                    },

                    State = State0#state{
                        session = Session,
                        sessions = maps:put(Uri, Session, Sessions0)
                    },
                    do_challenge(Uri, Details, Method, State)
            end;

        {error, Reason0} ->
            throw({authentication_failed, Reason0})
    end.


do_challenge(Uri, Details, Method, State0) ->
    Session0 = maps:get(Uri, State0#state.sessions),
    SessionId = maps:get(id, Session0),
    AuthCtxt0 = maps:get(auth_context, Session0),

    {AuthCtxt, Reply} =
        case bondy_auth:challenge(Method, Details, AuthCtxt0) of
            {ok, AuthCtxt1} ->
                M = {welcome, SessionId, #{}},
                {AuthCtxt1, M};

            {ok, ChallengeExtra, AuthCtxt1} ->
                M = {challenge, Method, ChallengeExtra},
                {AuthCtxt1, M};

            {error, Reason} ->
                throw({authentication_failed, Reason})
        end,

    Session = Session0#{
        auth_context => AuthCtxt,
        start_ts => erlang:system_time(millisecond)
    },

    State = State0#state{
        sessions = maps:put(Uri, Session, State0#state.sessions)
    },

    ok = send_message(Reply, State),

    State.


authenticate(AuthMethod, Signature, Extra, State0) ->
    Uri = maps:get(realm, State0#state.session),
    Session0 = maps:get(Uri, State0#state.sessions),
    SessionId = maps:get(id, Session0),
    AuthCtxt0 = maps:get(auth_context, Session0),

    {AuthCtxt, Reply} =
        case bondy_auth:authenticate(AuthMethod, Signature, Extra, AuthCtxt0) of
            {ok, WelcomeAuthExtra, AuthCtxt1} ->
                M = {welcome, SessionId, #{authextra => WelcomeAuthExtra}},
                {AuthCtxt1, M};
            {error, Reason} ->
                throw({authentication_failed, Reason})
        end,

    Session = Session0#{
        auth_context => AuthCtxt,
        start_ts => erlang:system_time(millisecond)
    },

    State = State0#state{
        sessions = maps:put(Uri, Session, State0#state.sessions),
        session = undefined
    },

    ok = send_message(Reply, State),

    State.


%% @private
set_socket_active(State) ->
    (State#state.transport):setopts(State#state.socket, [{active, once}]).


%% @private
send_message(Message, State) ->
    Data = term_to_binary(Message),
    (State#state.transport):send(State#state.socket, Data).


%% @private
on_connect(_State) ->
    ?LOG_NOTICE(#{
        description => "Established connection with edge router"
    }),
    ok.


%% @private
on_close(_Reason, _State) ->
    ok.


%% @private
idle_timeout(State) ->
    {state_timeout, State#state.idle_timeout, idle_timeout}.