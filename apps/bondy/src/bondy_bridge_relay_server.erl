%% =============================================================================
%%  bondy_bridge_relay_server.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
%% @doc EARLY DRAFT implementation of the server-side connection between and
%% client node ({@link bondy_bridge_relay_client}) and a remote/core node
%% (this module).
%%
%% <pre><code class="mermaid">
%% stateDiagram-v2
%%     %%{init:{'state':{'nodeSpacing': 50, 'rankSpacing': 200}}}%%
%%    [*] --> connected
%%    connected --> active: session_opened
%%    connected --> [*]: auth_timeout
%%    active --> active: rcv(data|ping) | snd(data|pong)
%%    active --> idle: ping_idle_timeout
%%    active --> [*]: error
%%    idle --> idle: snd(ping|pong) | rcv(ping|pong)
%%    idle --> active: snd(data)
%%    idle --> active: rcv(data)
%%    idle --> [*]: error
%%    idle --> [*]: ping_timeout
%%    idle --> [*]: idle_timeout
%% </code></pre>
%%
%% == Configuration Options ==
%% <ul>
%% <li>auth_timeout - once the connection is established how long to wait for
%% the client to send the HELLO message.</li>
%% </ul>
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_bridge_relay_server).
-behaviour(gen_statem).
-behaviour(ranch_protocol).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include_lib("bondy_plum_db.hrl").
-include("bondy.hrl").
-include("bondy_bridge_relay.hrl").


-record(state, {
    ranch_ref               ::  atom(),
    transport               ::  module(),
    opts                    ::  key_value:t(),
    socket                  ::  gen_tcp:socket() | ssl:sslsocket(),
    proxy_protocol          ::  bondy_tcp_proxy_protocol:t(),
    peername                ::  binary() | undefined,
    source_ip               ::  inet:ip_address() | undefined,
    auth_timeout            ::  pos_integer(),
    ping_retry              ::  optional(bondy_retry:t()),
    ping_payload            ::  optional(binary()),
    ping_idle_timeout       ::  optional(non_neg_integer()),
    idle_timeout            ::  pos_integer(),
    hibernate = idle        ::  never | idle | always,
    sessions = #{}          ::  #{id() => bondy_session:t()},
    sessions_by_realm = #{} ::  #{uri() => bondy_session_id:t()},
    %% The context for the session currently being established
    auth_context            ::  optional(bondy_auth:context()),
    registrations = #{}     ::  reg_indx(),
    start_ts                ::  pos_integer()
}).


% -type t()                   ::  #state{}.
-type reg_indx()            ::  #{
    SessionId :: bondy_session_id:t() => proxy_map()
}.
%% A mapping between a client entry id and the local (server) proxy id
-type proxy_map()           ::  #{OrigEntryId :: id() => ProxyEntryId :: id()}.

%% API.
-export([start_link/3]).
-export([start_link/4]).

%% GEN_STATEM CALLBACKS
-export([callback_mode/0]).
-export([init/1]).
-export([terminate/3]).
-export([code_change/4]).

%% STATE FUNCTIONS
-export([connecting/3]).
-export([active/3]).
-export([idle/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link(RanchRef, Transport, Opts) ->
    gen_statem:start_link(?MODULE, {RanchRef, Transport, Opts}, []).


%% -----------------------------------------------------------------------------
%% @doc
%% This will be deprecated with Ranch 2.0
%% @end
%% -----------------------------------------------------------------------------
start_link(RanchRef, _, Transport, Opts) ->
    start_link(RanchRef, Transport, Opts).



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
    ok = logger:update_process_metadata(#{
        listener => Ref,
        transport => Transport
    }),

    AuthTimeout = key_value:get(auth_timeout, Opts, 5000),
    IdleTimeout = key_value:get(idle_timeout, Opts, infinity),
    %% Shall we hibernate when we are idle?
    Hibernate = key_value:get(hibernate, Opts, idle),

    State0 = #state{
        ranch_ref = Ref,
        transport = Transport,
        opts = Opts,
        auth_timeout = AuthTimeout,
        idle_timeout = IdleTimeout,
        hibernate = Hibernate,
        start_ts = erlang:system_time(millisecond)
    },

    %% Setup ping
    PingOpts = maps:from_list(key_value:get(ping, Opts, [])),
    State = maybe_enable_ping(PingOpts, State0),

    %% We setup the auth_timeout timer. This is the period we allow between
    %% opening a connection and authenticating at least one session. Having
    %% passed that time we will close the connection.
    Actions = [auth_timeout(State)],
    {ok, connecting, State, Actions}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
terminate({shutdown, Info}, StateName, #state{socket = undefined} = State) ->
    ok = remove_all_registry_entries(State),
    ?LOG_INFO(Info#{
        state_name => StateName
    }),
    ok;

terminate(Reason, StateName, #state{socket = undefined} = State) ->
    ok = remove_all_registry_entries(State),
    ?LOG_INFO(#{
        description => "Closing connection",
        reason => Reason,
        state_name => StateName
    }),
    ok;

terminate(Reason, StateName, #state{} = State) ->
    Transport = State#state.transport,
    Socket = State#state.socket,

    catch Transport:close(Socket),

    terminate(Reason, StateName, State#state{socket = undefined}).


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
connecting(enter, connecting, State0) ->
    Ref = State0#state.ranch_ref,
    Transport = State0#state.transport,

    %% We to make this call before ranch:handshake/2
    ProxyProtocol = bondy_tcp_proxy_protocol:init(Ref, 15_000),

    %% Setup and configure socket
    TLSOpts = bondy_config:get([Ref, tls_opts], []),
    {ok, Socket} = ranch:handshake(Ref, TLSOpts),

    {PeerIP, _} = Peername = peername(Transport, Socket),

    case bondy_tcp_proxy_protocol:source_ip(ProxyProtocol, PeerIP) of
        {ok, SourceIP} ->
            State = State0#state{
                proxy_protocol = ProxyProtocol,
                source_ip = SourceIP,
                peername = Peername,
                socket = Socket
            },
            {keep_state, State, [{next_event, internal, connection_setup}]};

        {error, {socket_error, Message}} ->
            ?LOG_INFO(#{
                description =>
                    "Connection rejected. "
                    "The source IP Address couldn't be obtained "
                    "due to a socket error.",
                reason => Message,
                proxy_protocol => maps:without([error], ProxyProtocol)
            }),
            {stop, normal, State0};

        {error, {protocol_error, Message}} ->
            ?LOG_INFO(#{
                description =>
                    "Connection rejected. "
                    "The source IP Address couldn't be obtained "
                    "due to a proxy protocol error.",
                reason => Message,
                proxy_protocol => maps:without([error], ProxyProtocol)
            }),
            {stop, normal, State0}
    end;

connecting(internal, connection_setup, State) ->
    Transport = State#state.transport,
    Socket = State#state.socket,
    SocketOpts = [
        binary,
        {packet, 4},
        {active, once}
        | bondy_config:get([State#state.ranch_ref, socket_opts], [])
    ],

    %% If Transport == ssl, upgrades a gen_tcp, or equivalent socket to an SSL
    %% socket by performing the TLS server-side handshake, returning a TLS
    %% socket.
    ok = Transport:setopts(Socket, SocketOpts),

    ok = logger:set_process_metadata(#{
        transport => Transport,
        socket => Socket,
        peername => inet_utils:peername_to_binary(State#state.peername),
        source_ip => inet:ntoa(State#state.source_ip)
    }),

    ?LOG_INFO(#{
        description => "Established connection with client router."
    }),

    Actions = [auth_timeout(State)],
    {next_state, active, State, Actions};

connecting(EventType, EventContent, State) ->
    handle_event(EventType, EventContent, connecting, State).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
active(enter, active, _) ->
    keep_state_and_data;

active(enter, idle, State) ->
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state_and_data, Actions};

active(
    internal, {hello, Uri, Details}, #state{auth_context = undefined} = State0
) ->
    %% TODO validate Details
    ?LOG_DEBUG(#{
        description => "Got hello",
        details => Details
    }),

    try

        Realm = bondy_realm:fetch(Uri),

        bondy_realm:allow_connections(Realm)
            orelse throw(connections_not_allowed),

        %% We send the challenge
        State = challenge(Realm, Details, State0),

        %% We wait for response and timeout using auth_timeout again
        Actions = [auth_timeout(State)],
        {keep_state, State, Actions}

    catch
        error:{not_found, Uri} ->
            Abort = {
                abort,
                undefined,
                no_such_realm,
                #{
                    message => <<"Realm does not exist.">>,
                    realm => Uri
                }
            },
            ok = send_message(Abort, State0),
            {stop, normal, State0};

        throw:connections_not_allowed = Reason ->
            Abort = {abort, undefined, Reason, #{
                message => <<"The Realm does not allow user connections ('allow_connections' setting is off). This might be a temporary measure taken by the administrator or the realm is meant to be used only as a Same Sign-on (SSO) realm.">>,
                realm => Uri
            }},
            ok = send_message(Abort, State0),
            {stop, normal, State0};

        throw:{no_authmethod, ReqMethods} ->
            Abort = {abort, undefined, no_authmethod, #{
                message => <<"The requested authentication methods are not available for this user on this realm.">>,
                realm => Uri,
                authmethods => ReqMethods
            }},
            ok = send_message(Abort, State0),
            {stop, normal, State0};

        throw:{authentication_failed, Reason} ->
            Abort = {abort, undefined, authentication_failed, #{
                message => <<"Authentication failed.">>,
                realm => Uri,
                reason => Reason
            }},
            ok = send_message(Abort, State0),
            {stop, normal, State0}

    end;

active(internal, {hello, _, _}, #state{} = State) ->
    %% Assumption: no concurrent session establishment on this transport
    %% Session already being established, invalid message
    Abort = {abort, undefined, protocol_violation, #{
        message => <<"You've sent the HELLO message twice">>
    }},
    ok = send_message(Abort, State),
    {stop, normal, State};

active(internal, {authenticate, Signature, Extra}, State0) ->
    %% TODO validate Details
    ?LOG_DEBUG(#{
        description => "Got authenticate",
        signature => Signature,
        extra => Extra
    }),

    try

        State = authenticate(<<"cryptosign">>, Signature, Extra, State0),
        %% We cancel the auth timeout as soon as the connection has at least
        %% one authenticate session
        Actions = [
            {{timeout, auth_timeout}, cancel},
            ping_idle_timeout(State)
        ],
        {keep_state, State, Actions}

    catch
        throw:{authentication_failed, Reason} ->
            AuthCtxt = State0#state.auth_context,
            RealmUri = bondy_auth:realm_uri(AuthCtxt),
            SessionId = bondy_auth:realm_uri(AuthCtxt),
            Abort = {abort, SessionId, authentication_failed, #{
                message => <<"Authentication failed.">>,
                realm_uri => RealmUri,
                reason => Reason
            }},
            ok = send_message(Abort, State0),
            {stop, normal, State0}
    end;

active(internal, {aae_sync, SessionId, Opts}, State) ->
    RealmUri = session_realm(SessionId, State),
    ok = full_sync(SessionId, RealmUri, Opts, State),
    Finish = {aae_sync, SessionId, finished},
    ok = gen_statem:cast(self(), {forward_message, Finish}),
    Actions = [ping_idle_timeout(State)],
    {keep_state_and_data, Actions};

active(internal, {session_message, SessionId, Msg}, State) ->
    ?LOG_DEBUG(#{
        description => "Got session message from client",
        session_id => SessionId,
        message => Msg
    }),
    try
        handle_in(Msg, SessionId, State)
    catch
        throw:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Unhandled error",
                session_id => SessionId,
                message => Msg,
                class => throw,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            Actions = [ping_idle_timeout(State)],
            {keep_state_and_data, Actions};

        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while handling session message",
                session_id => SessionId,
                message => Msg,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            Abort = {abort, SessionId, server_error, #{
                reason => Reason
            }},
            ok = send_message(Abort, State),
            {stop, Reason, State}
    end;

active({timeout, auth_timeout}, auth_timeout, _) ->
    ?LOG_INFO(#{
        description => "Closing connection due to authentication timeout.",
        reason => auth_timeout
    }),
    {stop, normal};

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
    Info = #{
        description => "Shutting down connection due to inactivity.",
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
%% PRIVATE: COMMON EVENT HANDLING
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Handle events common to all states
%% @end
%% -----------------------------------------------------------------------------

%% TODO forward_message or forward?
handle_event({call, From}, Request, _, _) ->
    ?LOG_INFO(#{
        description => "Received unknown request",
        type => call,
        event => Request
    }),
    %% We should not reset timers, nor change state here as this is an invalid
    %% message
    Actions = [
        {reply, From, {error, badcall}}
    ],
    {keep_state_and_data, Actions};

handle_event(cast, {forward_message, Msg}, _, State) ->
    %% This is a cast we do to ourselves
    ok = send_message(Msg, State),
    Actions = [
        {{timeout, ping_timeout}, cancel},
        {{timeout, ping_idle_timeout}, cancel}
    ],
    {next_state, active, State, Actions};

handle_event(internal, {ping, Data}, _, State) ->
    %% The client is sending us a ping
    ok = send_message({pong, Data}, State),
    %% We keep all timers
    keep_state_and_data;

handle_event(info, {?BONDY_REQ, Pid, RealmUri, M}, _, State) ->
    %% A local bondy:send(), we need to forward to client
    ?LOG_DEBUG(#{
        description => "Received WAMP request we need to FWD to client",
        message => M
    }),

    handle_out(M, RealmUri, Pid, State);

handle_event(info, {Tag, Socket, Data}, _, #state{socket = Socket} = State)
when ?SOCKET_DATA(Tag) ->
    ok = set_socket_active(State),

    try binary_to_term(Data) of
        Msg ->
            ?LOG_DEBUG(#{
                description => "Received message from client",
                reason => Msg
            }),
            %% The message can be a ping|pong and in the case of idle state we
            %% should not reset timers here, we'll do that in the handling
            %% of next_event
            Actions = [
                {next_event, internal, Msg}
            ],
            {keep_state, State, Actions}
    catch
        Class:Reason ->
            Info = #{
                description => "Received invalid data from client.",
                data => Data,
                class => Class,
                reason => Reason
            },
            {stop, {shutdown, Info}}
    end;

handle_event(info, {Tag, _Socket}, _, _) when ?CLOSED_TAG(Tag) ->
    ?LOG_INFO(#{
        description => "Connection closed by client."
    }),
    {stop, normal};

handle_event(info, {Tag, _, Reason}, _, _) when ?SOCKET_ERROR(Tag) ->
    ?LOG_INFO(#{
        description => "Connection closed due to error.",
        reason => Reason
    }),
    {stop, Reason};


handle_event(EventType, EventContent, StateName, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message.",
        type => EventType,
        event => EventContent,
        state_name => StateName
    }),
    keep_state_and_data.



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
peername(Transport, Socket) ->
    case bondy_utils:peername(Transport, Socket) of
        {ok, {_, _} = Peername} ->
           Peername;

        {ok, NonIPAddr} ->
            ?LOG_ERROR(#{
                description =>
                    "Unexpected peername when establishing connection",
                reason => invalid_socket,
                peername => NonIPAddr
            }),
            error(invalid_socket);

        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Unexpected peername when establishing connection",
                reason => inet:format_error(Reason)
            }),
            error(invalid_socket)
    end.


%% @private
challenge(Realm, Details, State0) ->
    SessionId = bondy_session_id:new(),
    Authid = maps:get(authid, Details),
    Authroles0 = maps:get(authroles, Details, []),
    SourceIP = State0#state.source_ip,

    case bondy_auth:init(SessionId, Realm, Authid, Authroles0, SourceIP) of
        {ok, AuthCtxt} ->
            %% TODO take it from conf
            ReqMethods = [<<"cryptosign">>],

            case bondy_auth:available_methods(ReqMethods, AuthCtxt) of
                [] ->
                    throw({no_authmethod, ReqMethods});

                [Method|_] ->
                    Uri = bondy_realm:uri(Realm),
                    FinalAuthid = bondy_auth:user_id(AuthCtxt),
                    Authrole = bondy_auth:role(AuthCtxt),
                    Authroles = bondy_auth:roles(AuthCtxt),
                    Authprovider = bondy_auth:provider(AuthCtxt),
                    SecEnabled = bondy_realm:is_security_enabled(Realm),

                    Properties = #{
                        type => bridge_relay,
                        peer => State0#state.peername,
                        source_ip => SourceIP,
                        security_enabled => SecEnabled,
                        is_anonymous => FinalAuthid == anonymous,
                        agent => bondy_router:agent(),
                        roles => maps:get(roles, Details, undefined),
                        authid => maybe_gen_authid(FinalAuthid),
                        authprovider => Authprovider,
                        authmethod => Method,
                        authrole => Authrole,
                        authroles => Authroles
                    },

                    %% We create a new session object but we do not open it
                    %% yet, as we need to send the callenge and verify the
                    %% response
                    Session = bondy_session:new(Uri, Properties),

                    Sessions0 = State0#state.sessions,
                    Sessions = maps:put(SessionId, Session, Sessions0),

                    SessionsByUri0 = State0#state.sessions_by_realm,
                    SessionsByUri = maps:put(Uri, SessionId, SessionsByUri0),

                    State = State0#state{
                        auth_context = AuthCtxt,
                        sessions = Sessions,
                        sessions_by_realm = SessionsByUri
                    },
                    send_challenge(Details, Method, State)
            end;

        {error, Reason0} ->
            throw({authentication_failed, Reason0})
    end.


%% @private
send_challenge(Details, Method, State0) ->
    AuthCtxt0 = State0#state.auth_context,

    {Reply, State} =
        case bondy_auth:challenge(Method, Details, AuthCtxt0) of
            {false, _} ->
                %% We got no challenge? This cannot happen with cryptosign
                exit(invalid_authmethod);

            {true, ChallengeExtra, AuthCtxt1} ->
                M = {challenge, Method, ChallengeExtra},
                {M, State0#state{auth_context = AuthCtxt1}};

            {error, Reason} ->
                %% At the moment we only support a single session/realm
                %% so we crash
                throw({authentication_failed, Reason})
        end,

    ok = send_message(Reply, State),

    State.


%% @private
authenticate(AuthMethod, Signature, Extra, State0) ->
    AuthCtxt0 = State0#state.auth_context,

    case bondy_auth:authenticate(AuthMethod, Signature, Extra, AuthCtxt0) of
        {ok, AuthExtra0, _} ->
            SessionId = bondy_auth:session_id(AuthCtxt0),
            Session = session(SessionId, State0),

            ok = bondy_session_manager:open(Session),

            AuthExtra = AuthExtra0#{node => bondy_config:nodestring()},
            M = {welcome, SessionId, #{authextra => AuthExtra}},

            State = State0#state{auth_context = undefined},

            ok = send_message(M, State),

            State;
        {error, Reason} ->
            %% At the moment we only support a single session/realm
            %% so we crash
            throw({authentication_failed, Reason})
    end.


%% @private
set_socket_active(State) ->
    (State#state.transport):setopts(State#state.socket, [{active, once}]).


%% @private
send_message(Message, State) ->
    ?LOG_DEBUG(#{description => "sending message", message => Message}),
    Data = term_to_binary(Message),
    (State#state.transport):send(State#state.socket, Data).


%% -----------------------------------------------------------------------------
%% @private
%% @doc Handles inbound session messages
%% @end
%% -----------------------------------------------------------------------------
handle_in({registration_created, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state, State, Actions};

handle_in({registration_added, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state, State, Actions};

handle_in({registration_removed, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state, State, Actions};

handle_in({registration_deleted, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state, State, Actions};

handle_in({subscription_created, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state, State, Actions};

handle_in({subscription_added, Entry}, SessionId, State0) ->
    State = add_registry_entry(SessionId, Entry, State0),
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state, State, Actions};

handle_in({subscription_removed, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state, State, Actions};

handle_in({subscription_deleted, Entry}, SessionId, State0) ->
    State = remove_registry_entry(SessionId, Entry, State0),
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state, State, Actions};

handle_in({forward, _, #publish{} = M, _Opts}, SessionId, State) ->
    RealmUri = session_realm(SessionId, State),
    ReqId = M#publish.request_id,
    TopicUri = M#publish.topic_uri,
    Args = M#publish.args,
    KWArg = M#publish.kwargs,
    Opts0 = M#publish.options,
    Opts = Opts0#{exclude_me => true},
    Ref = session_ref(SessionId, State),

    %% We do a re-publish so that bondy_broker disseminates the event using its
    %% normal optimizations
    Job = fun() ->
        Ctxt = bondy_context:local_context(RealmUri, Ref),
        bondy_broker:publish(ReqId, Opts, TopicUri, Args, KWArg, Ctxt)
    end,

    case bondy_router_worker:cast(Job) of
        ok ->
            ok;
        {error, overload} ->
            %% TODO return proper return ...but we should move this to router
            error(overload)
    end,

    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state_and_data, Actions};

handle_in({forward, To, Msg, Opts}, SessionId, State) ->
    %% using cast here in theory breaks the CALL order guarantee!!!
    %% We either need to implement Partisan 4 plus:
    %% a) causality or
    %% b) a pool of relays (selecting one by hashing {CallerID, CalleeId}) and
    %% do it sync
    RealmUri = session_realm(SessionId, State),

    Fwd = fun() ->
        bondy_router:forward(Msg, To, Opts#{realm_uri => RealmUri})
    end,

    case bondy_router_worker:cast(Fwd) of
        ok ->
            ok;
        {error, overload} ->
            %% TODO return proper return ...but we should move this to router
            error(overload)
    end,
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],

    {keep_state_and_data, Actions};

handle_in(Other, SessionId, State) ->
    ?LOG_INFO(#{
        description => "Unhandled message",
        session_id => SessionId,
        message => Other
    }),
    Actions = [
        ping_idle_timeout(State),
        maybe_hibernate(active, State)
    ],
    {keep_state_and_data, Actions}.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
handle_out(#goodbye{} = M, RealmUri, _From, State) ->
    Details = M#goodbye.details,
    ReasonUri = M#goodbye.reason_uri,
    SessionId = session_id(RealmUri, State),
    ControlMsg = {goodbye, SessionId, ReasonUri, Details},
    ok = send_message(ControlMsg, State),
    {stop, normal};

handle_out(M, RealmUri, _From, State) ->
    SessionId = session_id(RealmUri, State),
    ok = send_message({session_message, SessionId, M}, State),
    Actions = [
        {{timeout, ping_timeout}, cancel},
        {{timeout, ping_idle_timeout}, cancel}
    ],
    {next_state, active, State, Actions}.


%% @private
add_registry_entry(SessionId, ExtEntry, State) ->
    Ref = session_ref(SessionId, State),

    ProxyEntry = bondy_registry_entry:proxy(Ref, ExtEntry),

    Id = bondy_registry_entry:id(ProxyEntry),
    OriginId = bondy_registry_entry:origin_id(ProxyEntry),

    case bondy_registry:add(ProxyEntry) of
        {ok, _} ->
            Index0 = State#state.registrations,
            Index = key_value:put([SessionId, OriginId], Id, Index0),
            State#state{registrations = Index};

        {error, already_exists} ->
            ok
    end.


%% @private
remove_registry_entry(SessionId, ExtEntry, State) ->
    Index0 = State#state.registrations,
    OriginId = maps:get(entry_id, ExtEntry),
    Type = maps:get(type, ExtEntry),

    try key_value:get([SessionId, OriginId], Index0) of
        ProxyId ->
            %% TODO get ctxt from session once we have real sessions
            RealmUri = session_realm(SessionId, State),
            Node = bondy_config:node(),
            Ctxt = #{
                realm_uri => RealmUri,
                node => Node,
                session_id => SessionId
            },

            ok = bondy_registry:remove(Type, ProxyId, Ctxt),

            Index = key_value:remove([SessionId, OriginId], Index0),
            State#state{registrations = Index}
    catch
        error:badkey ->
            State
    end.


remove_all_registry_entries(State) ->
    maps:foreach(
        fun(_, Session) ->
            RealmUri = bondy_session:realm_uri(Session),
            Ref = bondy_session:ref(Session),
            bondy_router:flush(RealmUri, Ref)
        end,
        State#state.sessions
    ).


%% @private
full_sync(SessionId, RealmUri, Opts, State) ->
    Realm = bondy_realm:fetch(RealmUri),

    %% If the realm has a prototype we sync the prototype first
    case bondy_realm:prototype_uri(Realm) of
        undefined ->
            ok;
        ProtoUri ->
            full_sync(SessionId, ProtoUri, Opts, State)
    end,

    %% We do not automatically sync the SSO Realms, if the client node wants it,
    %% that should be requested explicitly

    %% TODO However, we should sync a projection of the SSO Realm, the realm
    %% definition itself but with users, groups, sources and grants that affect
    %% the Realm's users, and avoiding bringing the password
    %% SO WE NEED REPLICATION FILTERS AT PLUM_DB LEVEL
    %% This means that only non SSO Users can login.
    %% ALSO we are currently copying the CRA passwords which we shouldn't

    %% Finally we sync the realm
    ok = do_full_sync(SessionId, RealmUri, Opts, State).



%% -----------------------------------------------------------------------------
%% @private
%% @doc A temporary POC of full sync, not elegant at all.
%% This should be resolved at the plum_db layer and not here, but we are
%% interested in having a POC ASAP.
%% @end
%% -----------------------------------------------------------------------------
do_full_sync(SessionId, RealmUri, _Opts, _State0) ->
    %% TODO we should spawn an exchange statem for this
    Me = self(),

    Prefixes = [
        %% TODO We should NOT sync the priv keys!!
        %% We might need to split the realm from the priv keys to enable a
        %% AAE hash comparison.
        {?PLUM_DB_REALM_TAB, RealmUri},
        {?PLUM_DB_GROUP_TAB, RealmUri},
        %% TODO we should not sync passwords! We might need to split the
        %% password from the user object and allow admin to enable sync or not
        %% (e.g. WAMPSCRAM)
        {?PLUM_DB_USER_TAB, RealmUri},
        {?PLUM_DB_SOURCE_TAB, RealmUri},
        {?PLUM_DB_USER_GRANT_TAB, RealmUri},
        {?PLUM_DB_GROUP_GRANT_TAB, RealmUri}
        % ,
        % {?PLUM_DB_REGISTRATION_TAB, RealmUri},
        % {?PLUM_DB_SUBSCRIPTION_TAB, RealmUri},
        % {?PLUM_DB_TICKET_TAB, RealmUri}
    ],

    _ = lists:foreach(
        fun(Prefix) ->
            lists:foreach(
                fun(Obj0) ->
                    Obj = prepare_object(Obj0),
                    Msg = {aae_data, SessionId, Obj},
                    gen_statem:cast(Me, {forward_message, Msg})
                end,
                pdb_objects(Prefix)
            )
        end,
        Prefixes
    ),
    ok.


%% @private
prepare_object(Obj) ->
    case bondy_realm:is_type(Obj) of
        true ->
            %% A temporary hack to prevent keys being synced with an client
            %% router. We will use this until be implement partial replication
            %% and decide on Key management strategies.
            bondy_realm:strip_private_keys(Obj);
        false ->
            Obj
    end.


pdb_objects(FullPrefix) ->
    It = plum_db:iterator(FullPrefix, []),
    try
        pdb_objects(It, [])
    catch
        {break, Result} -> Result
    after
        ok = plum_db:iterator_close(It)
    end.


%% @private
pdb_objects(It, Acc0) ->
    case plum_db:iterator_done(It) of
        true ->
            Acc0;
        false ->
            Acc = [plum_db:iterator_element(It) | Acc0],
            pdb_objects(plum_db:iterate(It), Acc)
    end.


%% @private
session(SessionId, #state{sessions = Map}) ->
    maps:get(SessionId, Map).

%% @private
session_realm(SessionId, #state{sessions = Map}) ->
    bondy_session:realm_uri(maps:get(SessionId, Map)).


%% @private
session_ref(SessionId, #state{sessions = Map}) ->
    bondy_session:ref(maps:get(SessionId, Map)).


%% @private
session_id(RealmUri, #state{sessions_by_realm = Map}) ->
    maps:get(RealmUri, Map).


%% @private
maybe_gen_authid(anonymous) ->
    bondy_utils:uuid();

maybe_gen_authid(UserId) ->
    UserId.


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
            ok = send_message({ping, Bin}, State),
            %% We set the timeout
            Actions = [
                ping_timeout(Time),
                maybe_hibernate(idle, State)
                | Actions0
            ],
            {keep_state, State, Actions};

        Limit when Limit == deadline orelse Limit == max_retries ->
            Info = #{
                description => "Client router has not responded to our ping on time. Shutting down.",
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
auth_timeout(State) ->
    %% We use an generic timeout meaning we only reset the timer manually by
    %% setting it again.
    Time = State#state.auth_timeout,
    {{timeout, auth_timeout}, Time, auth_timeout}.


%% @private
maybe_hibernate(_, #state{hibernate = never}) ->
    {hibernate, false};

maybe_hibernate(_, #state{hibernate = always}) ->
    {hibernate, true};

maybe_hibernate(StateName, #state{hibernate = idle}) ->
    {hibernate, StateName == idle}.