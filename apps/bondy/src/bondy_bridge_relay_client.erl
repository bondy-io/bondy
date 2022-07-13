%% =============================================================================
%%  bondy_bridge_relay_client.erl -
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

%% -----------------------------------------------------------------------------
%% @doc EARLY DRAFT implementation of the client-side connection between and
%% edge node (this module) and a remote/core node
%% ({@link bondy_bridge_relay_server}).
%%
%%
%% <pre><code class="mermaid">
%% stateDiagram-v2
%%     %%{init:{'state':{'nodeSpacing': 50, 'rankSpacing': 200}}}%%
%%     [*] --> connecting
%%     connecting --> [*]: retry_limit_reached
%%     connecting --> connecting: connect | tcp_error | socket_closed
%%     connecting --> waiting_for_network: network_disconnected
%%     connecting --> active: connected
%%     waiting_for_network --> connecting: network_connected
%%     waiting_for_network --> [*]: network_timeout
%%     active --> active: session_established | rcv(data|ping) | snd(data|pong)
%%     active --> idle: ping_idle_timeout
%%     active --> connecting: tcp_error | socket_closed
%%     active --> [*]: auth_timeout
%%     idle --> idle: snd(ping|pong) | rcv(ping|pong)
%%     idle --> active: snd(data)
%%     idle --> active: rcv(data)
%%     idle --> connecting: tcp_error
%%     idle --> [*]: ping_timeout
%%     idle --> [*]: idle_timeout
%% </code></pre>
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_bridge_relay_client).
-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_bridge_relay.hrl").


-define(IS_RETRIABLE(Reason), (
    Reason == timeout orelse
    Reason == econnrefused orelse
    Reason == econnreset orelse
    Reason == ehostdown orelse
    Reason == enotconn orelse
    Reason == etimedout
)).
-define(IS_NETDOWN(Reason), (
    Reason == enetdown orelse
    Reason == ehostunreach orelse
    Reason == enetunreach
)).


-record(state, {
    transport                   ::  gen_tcp | ssl,
    endpoint                    ::  {inet:ip_address(), inet:port_number()},
    config                      ::  bondy_bridge_relay:t(),
    socket                      ::  gen_tcp:socket() | ssl:sslsocket(),
    network_timeout             ::  pos_integer(),
    reconnect_retry             ::  optional(bondy_retry:t()),
    ping_retry                  ::  optional(bondy_retry:t()),
    ping_payload                ::  optional(binary()),
    ping_idle_timeout           ::  optional(non_neg_integer()),
    idle_timeout                ::  pos_integer(),
    hibernate = idle            ::  idle | always | never,
    sessions = #{}              ::  sessions(),
    sessions_by_realm = #{}     ::  #{uri() => bondy_session_id:t()},
    event_handlers = #{}        ::  #{{module(), term()} =>
                                        bondy_session_id:t()
                                    },
    session                     ::  optional(session()),
    start_ts                    ::  integer()
}).


-type t()                       ::  #state{}.
-type sessions()                ::  #{bondy_session_id:t() => session()}.
-type signer()                  ::  fun(
                                        (Challenge :: binary()) ->
                                            Signature :: binary()
                                    ).
-type session() ::  #{
    id                          :=  bondy_session_id:t(),
    ref                         :=  bondy_ref:t(),
    realm_uri                   :=  uri(),
    authid                      :=  binary(),
    pubkey                      :=  binary(),
    signer                      =>  signer(),
    subscriptions               =>  map(),
    registrations               =>  map()
}.

%% API.
-export([start_link/1]).
-export([forward/2]).

%% GEN_STATEM CALLBACKS
-export([callback_mode/0]).
-export([init/1]).
-export([terminate/3]).
-export([code_change/4]).
-export([format_status/2]).


%% STATE FUNCTIONS
-export([connecting/3]).
-export([waiting_for_network/3]).
-export([active/3]).
-export([idle/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link(Bridge) ->
    gen_statem:start_link(?MODULE, Bridge, []).


%% -----------------------------------------------------------------------------
%% @doc Forwards a message to the remote router.
%% @end
%% -----------------------------------------------------------------------------
-spec forward(Ref :: bondy_ref:t(), Msg :: any()) ->
    ok.

forward(Ref, Msg) ->
    Pid = bondy_ref:pid(Ref),
    SessionId = bondy_ref:session_id(Ref),
    gen_statem:cast(Pid, {forward_message, Msg, SessionId}).



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
init(Config0) ->
    % erlang:process_flag(sensitive, true),
    #{
        transport := Transport,
        endpoint := Endpoint,
        parallelism := _,
        idle_timeout := IdleTimeout,
        network_timeout := NetTimeout,
        hibernate := Hibernate,
        reconnect := ReconnectOpts,
        ping := PingOpts,
        realms := Realms0
    } = Config0,

    ?LOG_NOTICE(#{
        description => "Starting bridge-relay client",
        transport => Transport,
        endpoint => Endpoint,
        idle_timeout => IdleTimeout,
        realms => [maps:get(uri, R) || R <- Realms0]
    }),

    %% We rewrite the realms for fast access
    Realms = lists:foldl(
        fun(#{uri := Uri} = R, Acc) -> maps:put(Uri, R, Acc) end,
        #{},
        Realms0
    ),
    Config = maps:put(realms, Realms, Config0),


    State0 = #state{
        config = Config,
        transport = transport(Transport),
        endpoint = Endpoint,
        idle_timeout = IdleTimeout,
        network_timeout = NetTimeout,
        hibernate = Hibernate,
        start_ts = erlang:system_time(millisecond)
    },

    State1 = maybe_enable_reconnect(ReconnectOpts, State0),
    State = maybe_enable_ping(PingOpts, State1),

    %% We monitor net status. We will get two info messages:
    %% 1. {network_connected, Ref}
    %% 2. {network_disconnected, Ref}
    ok = partisan_inet:monitor(true),

    {ok, connecting, State}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec terminate(term(), atom(), t()) -> term().

terminate(normal, _, #state{socket = undefined}) ->
    ok;

terminate(shutdown, _, #state{socket = undefined} = State) ->
    Name = maps:get(name, State#state.config),
    %% We should not be restarted but we are using supervisor permanent restart,
    %% so we tell the manager to remove ourselves from the supervisor
    ok = bondy_bridge_relay_manager:stop_bridge(Name),
    ok;

terminate({shutdown, Info}, StateName, #state{socket = undefined}) ->
    ?LOG_NOTICE(Info#{
        state_name => StateName
    }),
    ok;

terminate(Reason, StateName, #state{socket = undefined}) ->
    ?LOG_INFO(#{
        description => "Closing connection",
        reason => Reason,
        state_name => StateName
    }),
    ok;

terminate(Reason, StateName, #state{} = State0) ->
    Transport = State0#state.transport,
    Socket = State0#state.socket,

    %% Ensure we closed socket
    State1 = State0#state{socket = undefined},
    catch Transport:close(Socket),

    %% Cleanup internal router state
    State = cleanup(State1),

    %% Cancel monitor
    ok = partisan_inet:monitor(false),

    %% Notify
    ok = on_disconnect(State),

    terminate(Reason, StateName, State).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
format_status(Opt, [_PDict, _StateName, #state{} = State]) ->
    gen_format(Opt, State#state{config = sensitive}).



%% =============================================================================
%% STATE FUNCTIONS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc A state function. In the `connecting' state the client is trying to
%% establish a connection to a remote router (server). This is the initial
%% state of the client.
%%
%% If establishing the connection fails because there is no network the client
%% transitions to the `waiting_for_network' state. Otherwise, if
%% `reconnect' is enabled it will retry up the configured limit (deadline or
%% maximum number of retries). If the reconnect limit is reached the client
%% will crash with an error reason and thus it will be restarted by the
%% supervisor.
%%
%% The client regards the connection error reasons
%% `enetdown', `ehostunreach' and `enetunreach' as the absense of network
%% connectivity.
%%
%% The client also monitors the network status using
%% {@link partisa_inet:monitor/1} and handles the resulting
%% `{network_connected, ref()}' and `{network_disconnected, ref()}' signals but
%% gives priority to the connection socket status.
%%
%% Previous states: `connecting', `waiting_for_network'.
%% Next states: `active', `waiting_for_network' or termination.
%% @end
%% -----------------------------------------------------------------------------
connecting(enter, connecting, State) ->

    ok = logger:set_process_metadata(#{
        transport => State#state.transport,
        endpoint => State#state.endpoint,
        id => maps:get(name, State#state.config)
    }),
    %% We use a timeout to immediately connect
    Actions = [{state_timeout, 0, connect}],
    {keep_state_and_data, Actions};

connecting(enter, _, State0) ->
    %% We reset the retry state, as we re-entered this state
    State = reset_reconnect_retry_state(State0),

    %% We use a timeout to immediately connect
    Actions = [{state_timeout, 0, connect}],
    {keep_state, State, Actions};

connecting(state_timeout, connect, State0) ->
    case connect(State0) of
        {ok, Socket} ->
            State = State0#state{socket = Socket},
            {next_state, active, State};

        {error, Reason} ->
            maybe_reconnect(Reason, State0)
    end;

connecting(info, {network_disconnected, _}, State) ->
    {next_state, waiting_for_network, State};

connecting(EventType, EventContent, _) ->
    ?LOG_DEBUG(#{
        description => "Received unexpected event",
        type => EventType,
        event => EventContent
    }),
    {stop, unexpected_event}.


%% -----------------------------------------------------------------------------
%% @doc A state function. In `waiting_for_network' state the client has
%% recognised that there is no network available and waits for a signal
%% indicating that the network has been re-established.
%%
%% If the client does not receive a `{network_connected, ref()}' signal
%% within the configured `network_timeout' it will crash with an error reason
%% `network_timeout' and thus it will be restarted by the supervisor.
%%
%% Previous states: `connecting'.
%% Next states: `connecting' or termination.
%% @end
%% -----------------------------------------------------------------------------
waiting_for_network(enter, _, State) ->
    NetTimeout = State#state.network_timeout,

    ?LOG_INFO(#{
        description =>
            "Network down. We will wait for the network to come up again before trying to connect.",
        timeout => NetTimeout
    }),

    Actions = [{state_timeout, NetTimeout, network_timeout}],
    {keep_state, State, Actions};

waiting_for_network(state_timeout, network_timeout, _State) ->
    %% We will be restarted
    Info = #{
        description => "Failed to establish connection with target router. Shutting down and restarting.",
        reason => network_timeout
    },
    {stop, {shutdown, Info}};

waiting_for_network(info, {network_connected, _}, State0) ->
    State = reset_reconnect_retry_state(State0),
    {next_state, connecting, State};

waiting_for_network(info, {network_disconnected, _}, _) ->
    keep_state_and_data;

waiting_for_network(EventType, EventContent, State) ->
    handle_event(EventType, EventContent, waiting_for_network, State).


%% -----------------------------------------------------------------------------
%% @doc A state function. In the `active' state the client is connected and has
%% at least one active session with a remote router or is trying to establish
%% such a session.
%%
%% In `active' state the client can send and receive messages.
%%
%%
%% Previous states: `connecting' or `idle'.
%% Next states: `idle', `connecting' or termination.
%% @end
%% -----------------------------------------------------------------------------
active(enter, connecting, #state{} = State0) ->
    ok = on_connect(State0),

    %% We rest the retry state as we've been succesful
    State1 = reset_reconnect_retry_state(State0),

    try
        %% We join any realms defined by the config
        State = open_sessions(State1),
        %% We start the idle timeout, if triggered we will transition to
        %% idle state
        Actions = [
            ping_idle_timeout(State),
            maybe_hibernate(active, State)
        ],
        {keep_state, State, Actions}
    catch
        throw:socket_closed ->
            {next_state, connecting, State1};
        throw:Reason ->
            {stop, Reason}
    end;

active(enter, idle, State) ->
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state_and_data, Actions};

active(internal, {abort, _SessionId, Reason, Details}, _State) ->
    %% We currently support a single session, so we stop.
    %% We will be restarted
    Info = #{
        description => "Connection closed by remote router. Shutting down and restarting.",
        reason => Reason,
        details => Details
    },
    {stop, {shutdown, Info}};

active(internal, {challenge, <<"cryptosign">>, ChallengeExtra}, State) ->
    %% We reply the challenge.
    case authenticate(ChallengeExtra, State) of
        ok ->
            Actions = [
                ping_idle_timeout(State),
                maybe_hibernate(active, State)
            ],
            {keep_state_and_data, Actions};
        {error, Reason} ->
            {stop, Reason}
    end;

active(internal, {welcome, SessionId, _Details}, State0) ->
    try
        State = init_session_and_sync(SessionId, State0),
        Actions = [
            ping_idle_timeout(State),
            maybe_hibernate(active, State)
        ],
        {keep_state, State, Actions}
    catch
        throw:socket_closed ->
            {next_state, connecting, State0};
        throw:Reason ->
            {stop, Reason}
    end;

active(internal, {goodbye, SessionId, ?WAMP_CLOSE_REALM, Details}, State) ->
    %% Remote router is kicking us out since the realm we were attached to
    %% has been deleted.
    RealmUri = session_realm(SessionId, State),
    Name = maps:get(name, State#state.config),

    ?LOG_WARNING(#{
        description => "Realm deleted by remote router. Shutting down.",
        name => Name,
        session_id => SessionId,
        realm_uri => RealmUri,
        details => Details
    }),

    %% Kick out all local sessions
    bondy_realm_manager:close(RealmUri, ?WAMP_CLOSE_REALM),

    %% We currently support a single session so we shutdown the connection.
    {stop, shutdown};

active(internal, {goodbye, _SessionId, Reason, Details}, _State) ->
    %% The remote router is kicking us out for another reason.
    % RealmUri = session_realm(SessionId, State),

    %% We currently support a single session, so we stop
    %% We will be restarted
    Info = #{
        description => "Session closed by remote router",
        reason => Reason,
        details => Details
    },
    {stop, {shutdown, Info}};

active(internal, {aae_sync, SessionId, finished}, State0) ->
    ?LOG_INFO(#{
        description => "AAE sync finished",
        session_id => SessionId
    }),

    try
        State = setup_proxing(SessionId, State0),
        Actions = [
            ping_idle_timeout(State),
            maybe_hibernate(active, State)
        ],
        {keep_state, State, Actions}
    catch
        throw:socket_closed ->
            {next_state, connecting, State0};
        throw:Reason ->
            {stop, Reason}
    end;

active(internal, {aae_data, SessionId, Data}, State) ->
    ?LOG_DEBUG(#{
        description => "Got aae_sync data",
        session_id => SessionId,
        data => Data
    }),

    ok = handle_aae_data(Data, State),
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state, State, Actions};

active(
    internal, {session_message, SessionId, {forward, To, Msg, Opts}}, State) ->
    ?LOG_DEBUG(#{
        description => "Got session message from remote router",
        session_id => SessionId,
        message => Msg,
        destination => To
    }),

    ok = forward_remote_message(Msg, To, Opts, SessionId, State),

    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state, State, Actions};

active({timeout, ping_idle_timeout}, ping_idle_timeout, State) ->
    %% We have had no activity, transition to idle and start sending pings
    {next_state, idle, State};

active(EventType, EventContent, State) ->
    handle_event(EventType, EventContent, active, State).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
idle(enter, active, State) ->
    %% We use an event timeout meaning any event received will cancel it
    IdleTimeout = State#state.idle_timeout,
    PingTimeout = State#state.idle_timeout,
    Adjusted = IdleTimeout - PingTimeout,
    Time = case Adjusted > 0 of
        true -> Adjusted;
        false -> IdleTimeout
    end,

    Actions = [
        {state_timeout, Time, idle_timeout}
    ],
    maybe_send_ping(State, Actions);

idle({timeout, ping_idle_timeout}, ping_idle_timeout, State) ->
    maybe_send_ping(State);

idle({timeout, ping_timeout}, ping_timeout, State0) ->
    %% No ping response in time
    State = ping_fail(State0),
    %% Try to send another one or stop if retry limit reached
    maybe_send_ping(State);

idle(state_timeout, idle_timeout, _State) ->
    %% We will be restarted
    Info = #{
        description => "Shutting down client due to inactivity.",
        reason => idle_timeout
    },
    {stop, {shutdown, Info}};

idle(internal, {pong, Bin}, #state{ping_payload = Bin} = State0) ->
    %% We got a response to our ping
    State = ping_succeed(State0),
    Actions = [
        {{timeout, ping_timeout}, cancel},
        ping_idle_timeout(State),
        maybe_hibernate(idle, State)
    ],
    {keep_state, State, Actions};

idle(internal, Msg, State) ->
    Actions = [
        {{timeout, ping_timeout}, cancel},
        {{timeout, ping_idle_timeout}, cancel},
        {next_event, internal, Msg}
    ],
    %% idle_timeout is a state timeout so it will be cancelled as we are
    %% transitioning to active
    {next_state, active, State, Actions};


idle(EventType, EventContent, State) ->
    handle_event(EventType, EventContent, idle, State).



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @private
%% @doc Use format recommended by gen_server:format_status/2
%% @end
%% -----------------------------------------------------------------------------
gen_format(normal, State) ->
    [{data, [{"State", gen_format(State)}]}];

gen_format(_, State) ->
    gen_format(State).


%% @private
gen_format(State) ->
    State.


%% =============================================================================
%% PRIVATE: COMMON EVENT HANDLING
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Handle events common to all states
%% @end
%% -----------------------------------------------------------------------------
handle_event({call, From}, Request, StateName, State) ->
    ?LOG_INFO(#{
        description => "Received unknown request",
        type => call,
        event => Request
    }),
    %% We should not reset timers, nor change state here as this is an invalid
    %% message
    Actions = [
        {reply, From, {error, badcall}},
        maybe_hibernate(StateName, State)
    ],
    {keep_state_and_data, Actions};

handle_event(cast, {forward_message, Msg, SessionId}, _, State) ->
    %% A call to ?MODULE:forward/2
    Result = case has_session(SessionId, State) of
        true ->
            send_session_message(SessionId, Msg, State);
        _ ->
            ?LOG_INFO(#{
                description => "Received message for a remote session that doesn't exist",
                type => cast,
                event => Msg,
                session_id => SessionId
            }),
            ok
    end,

    case Result of
        ok ->
            Actions = [
                {{timeout, ping_timeout}, cancel},
                {{timeout, ping_idle_timeout}, cancel}
            ],
            {next_state, active, State, Actions};
        {error, Reason} ->
            {stop, Reason}
    end;

handle_event(internal, {ping, Data}, _, State) ->
    %% The remote (server) is sending us a ping
    case send_message({pong, Data}, State) of
        ok ->
            %% We keep all timers as a ping should not reset the idle state
            keep_state_and_data;
        {error, Reason} ->
            {stop, Reason}
    end;

handle_event(internal, {pong, _}, active, _) ->
    %% A late pong, but we are active, so we ignore, the retry state was reset
    keep_state_and_data;

handle_event(info, {?BONDY_REQ, _Pid, RealmUri, Msg}, _StateName, State) ->
    ?LOG_DEBUG(#{
        description => "Received WAMP request we need to FWD to core",
        message => Msg
    }),
    SessionId = session_id(RealmUri, State),
    case send_session_message(SessionId, Msg, State) of
        ok ->
            Actions = [
                {{timeout, ping_timeout}, cancel},
                {{timeout, ping_idle_timeout}, cancel}
            ],
            {next_state, active, State, Actions};
        {error, Reason} ->
            {stop, Reason}
    end;

handle_event(info, {Tag, Socket, Data}, _, #state{socket = Socket} = State)
when ?SOCKET_DATA(Tag) ->
    %% Allow socket to send us more messages
    ok = set_socket_active(State),

    try
        Msg = binary_to_term(Data),
        ?LOG_DEBUG(#{
            description => "Received message from server",
            message => Msg
        }),

        %% The message can be a ping|pong and in the case of idle state we
        %% should not reset timers here, we'll do that in the handling of
        %% next_event
        Actions = [
            {next_event, internal, Msg}
        ],
        {keep_state, State, Actions}

    catch
        _:Reason ->
            ?LOG_ERROR(#{
                description => "Received invalid data from server",
                data => Data
            }),
            {stop, Reason}
    end;

handle_event(info, {Tag, _Socket}, _, State0) when ?CLOSED_TAG(Tag) ->
    ?LOG_INFO(#{
        description => "Socket closed.",
        reason => closed_by_remote
    }),
    State = cleanup(State0),
    {next_state, connecting, State};

handle_event(info, {Tag, _, Reason}, _, State0) when ?SOCKET_ERROR(Tag) ->
    ?LOG_ERROR(#{
        description => "Socket error",
        reason => Reason
    }),
    State = cleanup(State0),
    {next_state, connecting, State};

handle_event(info, {network_connected, _}, _, _) ->
    %% We do nothing here, this must be handled by the state functions when
    %% necessary e.g. waiting_for_network state does it.
    keep_state_and_data;

handle_event(info, {network_disconnected, _}, _, _) ->
    %% We do nothing here, this must be handled by the state functions as we
    %% give priority to the socket state rather than this event.
    %% If the socket had died then we wouldn't be here.
    keep_state_and_data;

handle_event(info, {gen_event_EXIT, {bondy_event_manager, _}, Reason}, _, _)
when Reason == normal; Reason == shutdown ->
    keep_state_and_data;

handle_event(
    info, 
    {gen_event_EXIT, {bondy_event_manager, Old}, {swapped, New, _} = Reason}, 
    StateName, 
    State0
) ->
    State =
        case maps:take(Old, State0#state.event_handlers) of
            {SessionId, Handlers0} ->
                ?LOG_DEBUG(#{
                    description => "Event handler terminated. Adding new handler.",
                    reason => Reason,
                    state_name => StateName
                }),
                    Handlers0 = maps:remove(Old, State0#state.event_handlers),
                    Handlers = maps:put(New, SessionId, Handlers0),
                    State0#state{event_handlers = Handlers};
            error ->
                ?LOG_DEBUG(#{
                    description => "Received exit signal for unknown handler",
                    reason => Reason,
                    handler => Old,
                    state_name => StateName
                }),
                State0
        end,

    {keep_state, State};

handle_event(
    info, 
    {gen_event_EXIT, {bondy_event_manager, Handler}, Reason}, 
    StateName,  
    State0) ->
    State =
        case maps:find(Handler, State0#state.event_handlers) of
            {ok, SessionId} ->
                ?LOG_DEBUG(#{
                    description => "Event handler terminated. Adding new handler.",
                    reason => Reason,
                    state_name => StateName
                }),
                add_event_handler(SessionId, State0);
            error ->
                ?LOG_DEBUG(#{
                    description => "Received exit signal for unknown handler",
                    reason => Reason,
                    handler => Handler,
                    state_name => StateName
                }),
                State0
        end,

    {keep_state, State};

handle_event(EventType, EventContent, StateName, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => EventType,
        event => EventContent,
        state_name => StateName
    }),
    %% We also keep timers
    keep_state_and_data.



%% =============================================================================
%% PRIVATE: CONNECT UTILS
%% =============================================================================



%% @private
maybe_enable_reconnect(#{enabled := true} = Opts0, State) ->
    Opts = key_value:set(backoff_enabled, true, Opts0),
    State#state{
        reconnect_retry = bondy_retry:init(connect, Opts)
    };

maybe_enable_reconnect(_, State) ->
    State.


%% @private
reset_reconnect_retry_state(State) ->
    {_, R1} = bondy_retry:succeed(State#state.reconnect_retry),
    State#state{reconnect_retry = R1}.


%% @private
maybe_reconnect(Reason, #state{reconnect_retry = R0} = State0)
when R0 =/= undefined andalso
(?IS_RETRIABLE(Reason) orelse ?IS_NETDOWN(Reason)) ->
    %% Reconnect enabled
    case bondy_retry:fail(R0) of
        {Delay, R1} when is_integer(Delay) ->
            ?LOG_NOTICE(#{
                description => "Failed to establish connection with target router. Will retry after delay.",
                delay => Delay,
                reason => Reason,
                details => inet:format_error(Reason)
            }),
            State = State0#state{reconnect_retry = R1},
            {keep_state, State, [{state_timeout, Delay, connect}]};

        {Limit, R1} when Limit == deadline orelse Limit == max_retries ->
            %% We reached max retries
            State = State0#state{reconnect_retry = R1},
            Info = #{
                description => "Failed to establish connection with target router. Shutting down and restarting.",
                reason => Reason
            },
            {stop, {shutdown, Info}, State}
    end;

maybe_reconnect(Reason, _) ->
    %% Reconnect disabled or error is not retriable
    ?LOG_WARNING(#{
        description => "Failed to establish connection with target router. Shutting down and restarting.",
        reason => Reason,
        details => inet:format_error(Reason)
    }),
    {stop, normal}.


%% @private
connect(State) ->
    Transport = State#state.transport,
    Endpoint = State#state.endpoint,
    Config = State#state.config,
    connect(Transport, Endpoint, Config).


%% @private
connect(Transport, {Host, PortNumber}, Config) ->
    Timeout = key_value:get(connect_timeout, Config, timer:seconds(5)),
    SocketOpts = maps:to_list(key_value:get(socket_opts, Config, [])),
    TLSOpts = maps:to_list(key_value:get(tls_opts, Config, [])),

    %% We use Erlang packet mode i.e. {packet, 4}
    %% So erlang first reads 4 bytes to get length of our data, allocates a
    %% buffer to hold it and reads data into buffer after on each tcp
    %% packet. When finished it sends the buffer as one packet to our process.
    %% This is more efficient than buidling the buffer ourselves.
    TransportOpts = [
        binary,
        {packet, 4},
        {active, once}
        | SocketOpts ++ TLSOpts
    ],

    Transport:connect(Host, PortNumber, TransportOpts, Timeout).


%% @private
transport(gen_tcp) -> gen_tcp;
transport(ssl) -> ssl;
transport(tcp) -> gen_tcp;
transport(tls) -> ssl.


setopts(gen_tcp, Socket, Opts) ->
    inet:setopts(Socket, Opts);

setopts(ssl, Socket, Opts) ->
    ssl:setopts(Socket, Opts).


%% @private
set_socket_active(State) ->
    setopts(State#state.transport, State#state.socket, [{active, once}]).


%% @private
-spec send_message(any(), t()) ->
    ok | {error, socket_closed | {socket_error, inet:posix()}}.

send_message(Message, State) ->
    ?LOG_DEBUG(#{description => "sending message", message => Message}),

    Data = term_to_binary(Message),
    case (State#state.transport):send(State#state.socket, Data) of
        ok ->
            ok;
        {error, closed} ->
            {error, socket_closed};
        {error, Reason} ->
            {error, {socket_error, Reason}}
    end.

%% @private
cleanup(State) ->
    %% We flush all subscriptions and registrations for the Bondy Relay session
    _ = maps:foreach(
        fun(_, #{realm_uri := RealmUri, ref := Ref}) ->
            bondy_router:flush(RealmUri, Ref)
        end,
        State#state.sessions
    ),

    State#state{
        socket = undefined,
        sessions = #{},
        sessions_by_realm = #{}
    }.


%% @private
on_connect(_State0) ->
    ?LOG_NOTICE(#{
        description => "Established connection with remote router."
    }),
    ok.


%% @private
on_disconnect(_State) ->
    ok.



%% =============================================================================
%% PRIVATE: KEEP ALIVE PING
%% =============================================================================


%% @private
maybe_enable_ping(#{enabled := true} = PingOpts, State) ->
    IdleTimeout = maps:get(idle_timeout, PingOpts),
    Timeout = maps:get(timeout, PingOpts),
    Attempts = maps:get(max_attempts, PingOpts),

    Retry = bondy_retry:init(
        ping_timeout,
        #{
            deadline => 0, % disable, use max_retries only
            interval => Timeout,
            max_retries => Attempts,
            backoff_enabled => false
        }
    ),

    State#state{
        ping_idle_timeout = IdleTimeout,
        ping_payload = bondy_utils:generate_fragment(16),
        ping_retry = Retry
    };

maybe_enable_ping(#{enabled := false}, State) ->
    State.


%% @private
ping_succeed(#state{ping_retry = undefined} = State) ->
    %% ping disabled
    State;

ping_succeed(#state{} = State) ->
    {_, Retry} = bondy_retry:succeed(State#state.ping_retry),
    State#state{ping_retry = Retry}.


%% @private
ping_fail(#state{ping_retry = undefined} = State) ->
    %% ping disabled
    State;

ping_fail(#state{} = State) ->
    {_, Retry} = bondy_retry:fail(State#state.ping_retry),
    State#state{ping_retry = Retry}.


%% @private
maybe_send_ping(State) ->
    maybe_send_ping(State, []).


%% @private
maybe_send_ping(#state{ping_retry = undefined} = State, Actions0) ->
    %% ping disabled
    Actions = [
        maybe_hibernate(idle, State) | Actions0
    ],
    {keep_state_and_data, Actions};

maybe_send_ping(#state{} = State, Actions0) ->
    case bondy_retry:get(State#state.ping_retry) of
        Time when is_integer(Time) ->
            %% We send a ping
            Bin = State#state.ping_payload,

            case send_message({ping, Bin}, State) of
                ok ->
                    Actions = [
                        ping_timeout(Time),
                        maybe_hibernate(idle, State)
                        | Actions0
                    ],
                    {keep_state, State, Actions};

                {error, Reason} ->
                    {stop, Reason}
            end;

        Limit when Limit == deadline orelse Limit == max_retries ->
            Info = #{
                description => "Remote router has not responded to our ping on time. Shutting down and restarting.",
                reason => ping_timeout
            },
            {stop, {shutdown, Info}, State}
    end.


%% @private
ping_idle_timeout(State) ->
    %% We use an generic timeout meaning we only reset the timer manually by
    %% setting it again.
    Time = State#state.ping_idle_timeout,
    {{timeout, ping_idle_timeout}, Time, ping_idle_timeout}.


%% @private
ping_timeout(Time) ->
    %% We use an generic timeout meaning we only reset the timer manually by
    %% setting it again.
    {{timeout, ping_timeout}, Time, ping_timeout}.


%% @private
maybe_hibernate(_, #state{hibernate = never}) ->
    {hibernate, false};

maybe_hibernate(_, #state{hibernate = always}) ->
    {hibernate, true};

maybe_hibernate(StateName, #state{hibernate = idle}) ->
    {hibernate, StateName == idle}.



%% =============================================================================
%% PRIVATE: AUTHN
%% =============================================================================



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
                    throw(cryptosign_timeout)
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

signer(_, #{cryptosign := #{privkey := HexString}}) ->
    %% For testing only, this will be remove on 1.0.0
    fun(Message) ->
        PrivKey = hex_utils:hexstr_to_bin(HexString),
        sign(Message, PrivKey)
    end;

signer(_, #{cryptosign := #{privkey_env_var := Var}}) ->

    case os:getenv(Var) of
        false ->
            error({invalid_config, {privkey_env_var, Var}});
        HexString ->
            fun(Message) ->
                PrivKey = hex_utils:hexstr_to_bin(HexString),
                sign(Message, PrivKey)
            end
    end;

signer(_, _) ->
    error(invalid_cryptosign_config).


%% @private
sign(Message, PrivKey) ->
    list_to_binary(
        hex_utils:bin_to_hexstr(
            enacl:sign_detached(Message, PrivKey)
        )
    ).


%% @private
authenticate(ChallengeExtra, State) ->
    HexMessage = maps:get(challenge, ChallengeExtra, undefined),
    Message = hex_utils:hexstr_to_bin(HexMessage),
    Signer = maps:get(signer, State#state.session),

    Signature = Signer(Message),
    Extra = #{},
    send_message({authenticate, Signature, Extra}, State).



%% =============================================================================
%% PRIVATE: SESSIONS
%% =============================================================================



%% @private
open_sessions(State0) ->
    case maps:to_list(maps:get(realms, State0#state.config)) of
        [] ->
            State0;
        [{Uri, H}|_T] ->
            %% POC, we join only the first realm
            %% TODO join all realms
            AuthId = key_value:get(authid, H),
            PubKey = key_value:get([cryptosign, pubkey], H),

            Details = #{
                authid => AuthId,
                authextra => #{
                    <<"pubkey">> => PubKey,
                    <<"trustroot">> => undefined,
                    <<"challenge">> => undefined,
                    <<"channel_binding">> => undefined
                },
                roles => ?WAMP_CLIENT_ROLES
            },

            %% TODO HELLO should include the Bondy Router Bridge Relay protocol
            %% version
            case send_message({hello, Uri, Details}, State0) of
                ok ->
                    Session = #{
                        realm_uri => Uri,
                        authid => AuthId,
                        pubkey => PubKey,
                        signer => signer(PubKey, H),
                        authroles => []
                    },
                    State0#state{session = Session};
                {error, Reason} ->
                    throw(Reason)
            end
        end.


%% @private
init_session_and_sync(SessionId, #state{session = Session0} = State0) ->
    Session = Session0#{
        id => SessionId,
        ref => bondy_ref:new(bridge_relay, self(), SessionId)
    },

    State1 = add_session(Session, State0),

    %% Request the server to initiate the sync of the realm configuration state
    State2 = init_aae_sync(Session, State1),

    State2#state{session = undefined}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
setup_proxing(SessionId, State0) ->
    %% We do this sequentially as we only support a single session for now.
    Session = session(SessionId, State0),

    %% Setup to WAMP meta topics so that we can receive registration and
    %% subscription events. We will use those to match against the
    %% configuration and create|remove their proxies on the remote
    State1 = add_event_handler(Session, State0),

    %% Get the existing local registrations and subscriptions and proxy them
    State2 = proxy_existing(Session, State1),

    %% We finally subscribe to user configured topics so that we can re-publish
    %% on the remote cluster
    subscribe_topics(Session, State2).



% %% @private
% leave_session(Id, #state{} = State) ->
%     Sessions0 = State#state.sessions,
%     {#{realm_uri := Uri}, Sessions} = maps:take(Id, Sessions0),
%     State#state{
%         sessions = Sessions,
%         sessions_by_realm = maps:remove(Uri, State#state.sessions_by_realm)
%     }.


%% @private
has_session(SessionId, #state{sessions = Sessions}) ->
    maps:is_key(SessionId, Sessions).


%% @private
add_session(#{id := Id, realm_uri := Uri} = Session, #state{} = State) ->
    State#state{
        sessions = maps:put(Id, Session, State#state.sessions),
        sessions_by_realm = maps:put(Uri, Id, State#state.sessions_by_realm)
    }.


session(Id, #state{sessions = Map}) ->
    maps:get(Id, Map).



%% @private
session_realm(SessionId, #state{sessions = Map}) ->
    key_value:get([SessionId, realm_uri], Map).

session_id(RealmUri, #state{sessions_by_realm = Map}) ->
    maps:get(RealmUri, Map).



%% =============================================================================
%% PRIVATE: SYNC
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc A temporary POC of full sync, not elegant at all.
%% This should be resolved at the plum_db layer and not here, but we are
%% interested in having a POC ASAP.
%% @end
%% -----------------------------------------------------------------------------
init_aae_sync(#{id := SessionId}, State) ->
    % Ref = make_ref(),
    % State = update_session(sync_ref, Ref, SessionId, State0),
    Msg = {aae_sync, SessionId, #{}},
    case send_message(Msg, State) of
        ok ->
            State;
        {error, Reason} ->
            throw(Reason)
    end.


handle_aae_data({PKey, RemoteObj}, _State) ->
    %% We should be getting plum_db_object instances to be able to sync, for
    %% now we do this
    %% TODO this can return false if local is newer
    _ = plum_db:merge({PKey, undefined}, RemoteObj),
    ok.



%% =============================================================================
%% PRIVATE: PROXYING
%% =============================================================================



%% @private
add_event_handler(SessionId, State) when is_binary(SessionId) ->
    add_event_handler(session(SessionId, State), State);

add_event_handler(Session, State) when is_map(Session) ->
    SessionId = maps:get(id, Session),
    RealmUri = maps:get(realm_uri, Session),
    MyRef = maps:get(ref, Session),

    %% We subscribe to registration|subscription events with the following
    %% callback function.
    Fun = fun
        ({Tag, Term}) ->
            IsMatch =
                %% It must be a registry event, so Term must be an entry
                bondy_registry_entry:is_entry(Term)
                %% We avoid forwarding our own subscriptions
                andalso SessionId =/= bondy_registry_entry:session_id(Term)
                %% We are only interested in events for this realm
                andalso RealmUri =:= bondy_registry_entry:realm_uri(Term)
                %% matching the following event types
                andalso (
                    Tag =:= registration_created
                    orelse Tag =:= registration_added
                    orelse Tag =:= registration_deleted
                    orelse Tag =:= registration_removed
                    orelse Tag =:= subscription_created
                    orelse Tag =:= subscription_added
                    orelse Tag =:= subscription_removed
                    orelse Tag =:= subscription_deleted
                ),

            case IsMatch of
                true ->
                    Msg = {Tag, bondy_registry_entry:to_external(Term)},
                    ok = ?MODULE:forward(MyRef, Msg);
                false ->
                    ok
            end;

        (_) ->
            %% Other event types
            ok
    end,

    %% We use the supervised version so that the event handler is terminated
    %% when we are.
    {ok, Ref} = bondy_event_manager:add_sup_callback(Fun),
    Refs = maps:put(Ref, SessionId, State#state.event_handlers),
    State#state{event_handlers = Refs}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc We subscribe to the topics configured for this realm.
%% Instead of receiving an EVENT we will get a PUBLISH message. This is an
%% optimization performed by bondy_broker to avoid sending N events to N
%% remote subscribers over the relay or bridge relay.
%% @end
%% -----------------------------------------------------------------------------
subscribe_topics(Session0, State) ->
    MyRef = maps:get(ref, Session0),
    RealmUri = maps:get(realm_uri, Session0),
    RealmConfig = key_value:get([realms, RealmUri], State#state.config),
    Topics = maps:get(topics, RealmConfig),

    Session = lists:foldl(
        fun
            Subs(#{uri := Uri, match := Match, direction := out}, Acc) ->
                %% We subscribe to the local topic so that we can forward its
                %% events to the remote router.
                %% We will receive an info ?BONDY_REQ message with the
                %% PUBLISH message that we will handle in handle_event/4
                {ok, Id} = bondy_broker:subscribe(
                    RealmUri, #{match => Match}, Uri, MyRef
                ),
                %% We store the subscription id so that we can match
                key_value:set([subscriptions, Id], Uri, Acc);

            Subs(#{uri := _Uri, match := _Match, direction := in}, Acc) ->
                %% We need to subscribe on the remote
                %% Not implemented yet
                ?LOG_WARNING(#{
                    description => "Bridge relay subscription direction 'in' not yet supported'",
                    subscription => Subs
                }),
                Acc;

            Subs(#{direction := both} = Conf, Acc0) ->
                Acc = Subs(Conf#{direction := out}, Acc0),
                Subs(Conf#{direction := in}, Acc)
        end,
        Session0,
        Topics
    ),

    add_session(Session, State).


%% @private
proxy_existing(Session, State0) ->
    RealmUri = maps:get(realm_uri, Session),

    %% We want all sessions, callback modules or processes
    AnySessionId = '_',
    Limit = 100,

    %% We proxy all existing registrations
    Regs = bondy_dealer:registrations(RealmUri, AnySessionId, Limit),
    GetRegs = fun(Cont) -> bondy_dealer:registrations(Cont) end,
    State1 = proxy_existing(Session, State0, GetRegs, Regs),

    %% We proxy all existing subscriptions
    Subs = bondy_broker:subscriptions(RealmUri, AnySessionId, Limit),
    GetSubs = fun(Cont) -> bondy_dealer:registrations(Cont) end,

    proxy_existing(Session, State1, GetSubs, Subs).


%% @private
proxy_existing(_, State, _, ?EOT) ->
    State;

proxy_existing(Session, State, Get, {[], Cont}) ->
    proxy_existing(Session, State, Get, Get(Cont));


proxy_existing(Session, State0, Get, {[H|T], Cont}) ->
    State = proxy_entry(Session, State0, H),
    proxy_existing(Session, State, Get, {T, Cont}).


%% @private
proxy_entry(#{id := SessionId}, State, Entry) ->
    Type = bondy_registry_entry:type(Entry),
    Ref = bondy_registry_entry:ref(Entry),

    case bondy_ref:is_self(Ref) of
        true ->
            %% We do not want to proxy our own registrations and subscriptions
            State;
        false when Type == registration ->
            Msg = {registration_added, bondy_registry_entry:to_external(Entry)},
            case send_session_message(SessionId, Msg, State) of
                ok ->
                    State;
                {error, Reason} ->
                    throw(Reason)
            end;

        false when Type == subscription ->
            Msg = {subscription_added, bondy_registry_entry:to_external(Entry)},
            case send_session_message(SessionId, Msg, State) of
                ok ->
                    State;
                {error, Reason} ->
                    throw(Reason)
            end
    end.



%% =============================================================================
%% PRIVATE: HANDLING WAMP EVENTS
%% =============================================================================



%% @private
send_session_message(SessionId, Msg, State) ->
    send_message({session_message, SessionId, Msg}, State).


% new_request_id(Type, RealmUri, State) ->
%     Tab = State#state.tab,
%     Pos = case Type of
%         subscribe -> #session_data.subscribe_req_id;
%         unsubscribe -> #session_data.unsubscribe_req_id;
%         publish -> #session_data.publish_req_id;
%         register -> #session_data.register_req_id;
%         unregister -> #session_data.unregister_req_id;
%         call -> #session_data.call_req_id
%     end,
%     ets:update_counter(Tab, RealmUri, {Pos, 1}).

forward_remote_message(Msg, To, Opts, SessionId, State) ->
    #{realm_uri := RealmUri, ref := MyRef} = session(SessionId, State),

    SendOpts = bondy:add_via(MyRef, Opts),
    bondy_router:forward(Msg, To, SendOpts#{realm_uri => RealmUri}).



