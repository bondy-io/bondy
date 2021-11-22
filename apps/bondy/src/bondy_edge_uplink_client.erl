-module(bondy_edge_uplink_client).
-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include_lib("bondy.hrl").

-define(CONNECTION_FAILED_MESSAGE,
    "Failed to establish uplink connection to core router"
).
-define(SOCKET_DATA(Tag), Tag == tcp orelse Tag == ssl).
-define(SOCKET_ERROR(Tag), Tag == tcp_error orelse Tag == ssl_error).
-define(CLOSED_TAG(Tag), Tag == tcp_closed orelse Tag == ssl_closed).
% -define(PASSIVE_TAG(Tag), Tag == tcp_passive orelse Tag == ssl_passive).


-record(state, {
    transport               ::  gen_tcp | ssl,
    endpoint                ::  {inet:ip_address(), inet:port_number()},
    opts                    ::  key_value:t(),
    socket                  ::  gen_tcp:socket() | ssl:sslsocket(),
    idle_timeout            ::  pos_integer(),
    reconnect_retry         ::  maybe(bondy_retry:t()),
    reconnect_retry_tref    ::  maybe(timer:ref()),
    reconnect_retry_reason  ::  maybe(any()),
    ping_retry              ::  maybe(bondy_retry:t()),
    ping_retry_tref         ::  maybe(timer:ref()),
    ping_sent               ::  maybe({Ref :: timer:ref(), Data :: binary()}),
    hibernate = false       ::  boolean(),
    realms                  ::  map(),
    sessions = #{}          ::  #{uri() => bondy_edge:session()},
    session                 ::  maybe(map()),
    start_ts                ::  integer()
}).

-type t()                   ::  #state{}.

%% API.
-export([start_link/3]).

%% GEN_STATEM CALLBACKS
-export([callback_mode/0]).
-export([init/1]).
-export([terminate/3]).
-export([code_change/4]).

%% STATE FUNCTIONS
-export([connecting/3]).
-export([connected/3]).
% -export([establishing/3]).
% -export([established/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link(Transport, Endpoint, Opts) ->
	gen_statem:start_link(?MODULE, {Transport, Endpoint, Opts}, []).



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
init({Transport0, Endpoint, Opts}) ->
    TransportMod = transport_mod(Transport0),

    %% TODO Validate realms

    State0 = #state{
        transport = TransportMod,
        endpoint = Endpoint,
        opts = Opts,
        realms = key_value:get(realms, Opts, #{}),
        idle_timeout = key_value:get(idle_timeout, Opts, timer:minutes(1)),
        start_ts = erlang:system_time(millisecond)
    },

    %% Setup reconnect
    ReconnectOpts = key_value:get(reconnect, Opts),

    State1 = case key_value:get(enabled, ReconnectOpts) of
        true ->
            RetryOpts = key_value:set(backoff_enabled, true, ReconnectOpts),
            State0#state{
                reconnect_retry = bondy_retry:init(connect, RetryOpts)
            };
        false ->
            State0
    end,

    %% Setup ping
    PingOpts = key_value:get(ping, Opts),

    State = case key_value:get(enabled, PingOpts) of
        true ->
            State1#state{
                ping_retry = bondy_retry:init(ping, PingOpts)
            };
        false ->
            State1
    end,

    {ok, connecting, State}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec terminate(term(), atom(), t()) -> term().

terminate(Reason, StateName, #state{transport = T, socket = S} = State0)
when T =/= undefined andalso S =/= undefined ->
    catch T:close(S),

    ?LOG_ERROR(#{
        description => "Connection terminated",
        reason => Reason
    }),

    ok = on_close(Reason, State0),

    State = State0#state{transport = undefined, socket = undefined},

    terminate(Reason, StateName, State);

terminate(Reason, _StateName, _State) ->
    ?LOG_ERROR(#{
        description => "Process terminated",
        reason => Reason
    }),
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
%% @doc The edge router is trying to establish an uplink connection to the core
%% router.
%% If reconnect is configured it will retry using the reconnect options defined.
%% @end
%% -----------------------------------------------------------------------------
connecting(enter, _, State) ->
    ok = bondy_logger_utils:set_process_metadata(#{
        transport => State#state.transport,
        endpoint => State#state.endpoint,
        reconnect => State#state.reconnect_retry =/= undefined
    }),
    {keep_state_and_data, [{state_timeout, 0, connect}]};

connecting(state_timeout, connect, State0) ->
    case connect(State0) of
        {ok, Socket} ->
            State = State0#state{socket = Socket},
            ok = on_connect(State),
            {next_state, connected, State};

        {error, Reason} ->
            State = State0#state{reconnect_retry_reason = Reason},
            maybe_reconnect(State)
    end;

connecting(EventType, Msg, _) ->
    ?LOG_DEBUG(#{
        description => "Received unexpected event",
        type => EventType,
        event => Msg
    }),
	{stop, normal}.


%% -----------------------------------------------------------------------------
%% @doc The edge router established the uplink connection with the core router.
%% At this point the edge router has noy yet joined any realms.
%% @end
%% -----------------------------------------------------------------------------
connected(enter, connecting, #state{} = State0) ->
    ok = on_connect(State0),

    %% We join any realms defined by the config
    case maps:to_list(State0#state.realms) of
        [] ->
            keep_state_and_data;
        [{Uri, H}|_T] ->
            %% POC, we join only the first realm
            %% TODO join all
            AuthId = key_value:get(authid, H),
            PubKey = key_value:get([cryptosign, pubkey], H),

            Details = #{
                authid => AuthId,
                authextra => #{
                    <<"pubkey">> => PubKey,
                    <<"trustroot">> => undefined,
                    <<"challenge">> => undefined,
                    <<"channel_binding">> => undefined
                }
            },

            ok = send_message({hello, Uri, Details}, State0),

            Session = #{
                realm => Uri,
                authid => AuthId,
                pubkey => PubKey,
                signer => signer(PubKey, H),
                x_authroles => []
            },

            State = State0#state{session = Session},

            {keep_state, State}
    end;

connected(internal, {challenge, <<"cryptosign">>, ChallengeExtra}, State) ->
    ?LOG_INFO(#{
        description => "Got challenge",
        extra => ChallengeExtra
    }),
    HexMessage = maps:get(challenge, ChallengeExtra, undefined),
    Message = hex_utils:hexstr_to_bin(HexMessage),
    Signer = maps:get(signer, State#state.session),

    Signature = Signer(Message),
    Extra = #{},
    ok = send_message({authenticate, Signature, Extra}, State),

    {keep_state_and_data, idle_timeout(State)};

connected(internal, {welcome, SessionId, Details}, State0) ->
    ?LOG_INFO(#{
        description => "Got welcome",
        session_id => SessionId,
        details => Details
    }),

    Sessions0 = State0#state.sessions,
    Session0 = State0#state.session,
    Session = Session0#{
        id => SessionId
    },
    Uri = maps:get(realm, Session),
    Sessions = maps:put(Uri, Session, Sessions0),
    State = State0#state{sessions = Sessions},

    {keep_state, State, idle_timeout(State)};

connected(info, {Tag, Socket, Data}, #state{socket = Socket} = State)
when ?SOCKET_DATA(Tag) ->
    ok = set_socket_active(State),

    ?LOG_INFO(#{
        description => "Got TCP message",
        message => Data
    }),

    Actions = [
        {next_event, internal, binary_to_term(Data)},
        idle_timeout(State)
    ],
    {keep_state_and_data, Actions};

connected(info, {Tag, _Socket}, State) when ?CLOSED_TAG(Tag) ->
    ?LOG_INFO(#{
        description => "Socket closed"
    }),
    ok = on_disconnect(State),
	{stop, normal};

connected(info, {Tag, _, Reason}, State) when ?SOCKET_ERROR(Tag) ->
    ?LOG_INFO(#{
        description => "Socket error",
        reason => Reason
    }),
    ok = on_disconnect(State),
	{stop, Reason};

connected(info, timeout, #state{ping_sent = false} = State0) ->
    ?LOG_INFO(#{
        description => "Connection timeout, sending first ping"
    }),
    %% Here we do not return a timeout value as send_ping set an ah-hoc timer
    {ok, State1} = send_ping(State0),
    {keep_state, State1};

% connected(info, {timeout, Ref, ping}, #state{ping_sent = {Ref, _}} = State)->

%     ?LOG_DEBUG(#{
%         description => "Connection closing",
%         reason => ping_timeout
%     }),
%     {stop, ping_timeout, State#state{ping_sent = undefined}};

% connected(info, {timeout, Ref, ping}, #state{ping_sent = {_Ref, Bin}} = State) ->
%     ?LOG_DEBUG(#{
%         description => "Ping timeout, sending another ping"
%     }),
%     %% We reuse the same payload, in case the server responds the previous one
%     {ok, State1} = send_ping(Bin, State),
%     %% Here we do not return a timeout value as send_ping set an ah-hoc timer
%     {keep_state, State1};

connected(info, Msg, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => info,
        event => Msg
    }),
	keep_state_and_data;

connected({call, _From}, {join, _Realms, _AuthId, _PubKey}, _State) ->
    %% TODO
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

connected(timeout, Msg, _) ->
    ?LOG_INFO(#{
        description => "Received timeout message",
        type => timeout,
        event => Msg
    }),
	{stop, normal};

connected(EventType, Msg, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => EventType,
        event => Msg
    }),
	{stop, normal}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
maybe_reconnect(#state{reconnect_retry = undefined} = State) ->
    %% Reconnect disabled
    ?LOG_ERROR(#{
        description => ?CONNECTION_FAILED_MESSAGE,
        reason => State#state.reconnect_retry_reason
    }),
    {stop, normal};

maybe_reconnect(#state{reconnect_retry = R0} = State0) ->
    %% Reconnect enabled
    {Res, R1} = bondy_retry:fail(R0),
    State = State0#state{reconnect_retry = R1},

    case Res of
        Delay when is_integer(Delay) ->
            ?LOG_ERROR(#{
                description => "Will retry",
                delay => Delay
            }),
            {keep_state, State, [{state_timeout, Delay, connect}]};

        Reason ->
            %% We reached max retries
            ?LOG_ERROR(#{
                description => ?CONNECTION_FAILED_MESSAGE,
                reason => Reason,
                last_error_reason => State#state.reconnect_retry_reason
            }),
            {stop, normal}
    end.


%% @private
connect(State) ->
    Transport = State#state.transport,
    Endpoint = State#state.endpoint,
    Opts = State#state.opts,
    connect(Transport, Endpoint, Opts).


%% @private
connect(Transport, {Host, Port}, Opts) ->
    Timeout = key_value:get(timeout, Opts, 5000),
    SocketOpts = key_value:get(socket_opts, Opts, []),

    %% We use Erlang packet mode i.e. {packet, 4}
    %% So erlang first reads 4 bytes to get length of our data, allocates a
    %% buffer to hold it and reads data into buffer after on each tcp
    %% packet. When finished it sends the buffer as one packet to our process.
    %% This is more efficient than buidling the buffer ourselves.
    TransportOpts = [
        binary,
        {packet, 4},
        {active, once}
        | SocketOpts
    ],

    case Transport:connect(Host, Port, TransportOpts, Timeout) of
        {ok, _Socket} = OK ->
            OK;
        {error, _} = Error ->
            Error
    end.


%% @private
transport_mod(tcp) -> gen_tcp;
transport_mod(tls) -> ssl;
transport_mod(gen_tcp) -> gen_tcp;
transport_mod(ssl) -> ssl.


%% @private
set_socket_active(State) ->
    inet:setopts(State#state.socket, [{active, once}]).


%% @private
send_message(Message, State) ->
    Data = term_to_binary(Message),
    (State#state.transport):send(State#state.socket, Data).


%% @private
on_connect(_State) ->
    ?LOG_NOTICE(#{
        description => "Established uplink connection to core router"
    }),
    ok.


%% @private
on_disconnect(_State) ->
    ok.


%% @private
on_close(_Reason, _State) ->
    ok.


%% @private
send_ping(St) ->
    send_ping(integer_to_binary(erlang:system_time(microsecond)), St).


%% -----------------------------------------------------------------------------
%% @private
%% @doc Sends a ping message with a reference() as a payload to the client and
%% sent ourselves a ping_timeout message in the future.
%% @end
%% -----------------------------------------------------------------------------
send_ping(Data, State0) ->
    ok = send_message({ping, Data}, State0),
    Timeout = State0#state.idle_timeout,

    TimerRef = erlang:send_after(Timeout, self(), ping_timeout),

    State = State0#state{
        ping_sent = {TimerRef, Data}
        % ping_retry =
    },
    {ok, State}.


% join(State) ->
%     State.


%% @private
idle_timeout(State) ->
    {state_timeout, State#state.idle_timeout, idle_timeout}.


%% @private
signer(_, #{cryptosign := #{procedure := _}}) ->
    error(not_implemented);

signer(PubKey, #{cryptosign := #{exec := Filename}}) ->

    SignerFun = fun(Message) ->
        try
            Port = erlang:open_port(
                {spawn_executable, Filename}, [{args, [PubKey, Message]}]
            ),
            receive
                {Port, {data, Signature}} ->
                    %% Signature should be a hex string
                    erlang:port_close(Port),
                    list_to_binary(Signature)
            after
                10000 ->
                    erlang:port_close(Port),
                    throw(timeout)
            end
        catch
            error:Reason ->
                error({invalid_executable, Reason})
        end
    end,

    %% We call it first to validate
    try SignerFun(<<"foo">>) of
        Val when is_binary(Val) ->
            SignerFun
    catch
        error:Reason ->
            error(Reason)
    end;

signer(_, #{cryptosign := #{privkey_env_var := Bin}}) ->
    Var = binary_to_list(Bin),

    case os:getenv(Var) of
        false ->
            error({invalid_config, {privkey_env_var, Var}});
        HexString ->
            PrivKey = hex_utils:hexstr_to_bin(HexString),
            fun(Message) ->
                list_to_binary(
                    hex_utils:bin_to_hexstr(
                        enacl:sign_detached(Message, PrivKey)
                    )
                )
            end
    end;

signer(_, _) ->
    error(invalid_cryptosign_config).