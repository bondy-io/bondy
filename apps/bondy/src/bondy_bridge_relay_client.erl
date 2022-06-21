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
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_bridge_relay_client).
-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_bridge_relay.hrl").

-define(SOCKET_DATA(Tag), Tag == tcp orelse Tag == ssl).
-define(SOCKET_ERROR(Tag), Tag == tcp_error orelse Tag == ssl_error).
-define(CLOSED_TAG(Tag), Tag == tcp_closed orelse Tag == ssl_closed).
% -define(PASSIVE_TAG(Tag), Tag == tcp_passive orelse Tag == ssl_passive).
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
    transport               ::  gen_tcp | ssl,
    endpoint                ::  {inet:ip_address(), inet:port_number()},
    config                  ::  bondy_bridge_relay:t(),
    socket                  ::  gen_tcp:socket() | ssl:sslsocket(),
    idle_timeout            ::  pos_integer(),
    ping_retry              ::  optional(bondy_retry:t()),
    ping_retry_tref         ::  optional(timer:ref()),
    ping_sent               ::  optional({timer:ref(), binary()}),
    reconnect_retry         ::  optional(bondy_retry:t()),
    hibernate = false       ::  boolean(),
    sessions = #{}          ::  sessions(),
    sessions_by_realm = #{} ::  #{uri() => bondy_session_id:t()},
    session                 ::  optional(session()),
    start_ts                ::  integer()
}).


-type t()                   ::  #state{}.
-type sessions()            ::  #{
    bondy_session_id:t() => session()
}.
-type session()             ::  #{
    id := bondy_session_id:t(),
    ref := bondy_ref:t(),
    realm_uri := uri(),
    authid := binary(),
    pubkey := binary(),
    signer => fun((Challenge :: binary()) -> Signature :: binary()),
    subscriptions => map(),
    registrations => map()
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
-export([connected/3]).
% -export([established/3]).



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
%% @doc
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
    #{
        transport := Transport,
        endpoint := Endpoint,
        parallelism := _,
        idle_timeout := IdleTimeout,
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
        hibernate = key_value:get(hibernate, Config, false),
        start_ts = erlang:system_time(millisecond)
    },

    %% Setup reconnect
    ReconnectOpts = key_value:get(reconnect, Config),

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
    PingOpts = key_value:get(ping, Config),

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

terminate(_, _, #state{socket = undefined}) ->
    ok;

terminate(Reason, StateName, #state{} = State0) ->
    Transport = State0#state.transport,
    Socket = State0#state.socket,

    catch Transport:close(Socket),

    State = on_disconnect(State0),

    terminate(Reason, StateName, State#state{socket = undefined}).


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
format_status(Opt, [_PDict, _Statename, #state{} = State]) ->
    gen_format(Opt, State#state{config = sensitive}).


%% =============================================================================
%% PRIVATE
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @private
%% @doc Use format recommended by gen_server:format_status/2
%% @end
%% -----------------------------------------------------------------------------
gen_format(normal, Term) ->
    [{data, [{"State", Term}]}];

gen_format(_, Term) ->
    Term.

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
    ok = logger:set_process_metadata(#{
        transport => State#state.transport,
        endpoint => State#state.endpoint,
        reconnect => State#state.reconnect_retry =/= undefined
    }),
    {keep_state_and_data, [{state_timeout, 0, connect}]};

connecting(state_timeout, connect, State0) ->
    case connect(State0) of
        {ok, Socket} ->
            State = State0#state{socket = Socket},
            {next_state, connected, State};

        {error, Reason} ->
            maybe_reconnect(Reason, State0)
    end;

connecting(EventType, Msg, _) ->
    ?LOG_DEBUG(#{
        description => "Received unexpected event",
        type => EventType,
        event => Msg
    }),
    {stop, {error, unexpected_event}}.


%% -----------------------------------------------------------------------------
%% @doc The edge router established the uplink connection with the core router.
%% At this point the edge router has noy yet joined any realms.
%% @end
%% -----------------------------------------------------------------------------
connected(enter, connecting, #state{} = State0) ->
    State = on_connect(State0),
    {keep_state, State};

connected(internal, {challenge, <<"cryptosign">>, ChallengeExtra}, State) ->
    ?LOG_DEBUG(#{
        description => "Got challenge",
        extra => ChallengeExtra
    }),
    ok = authenticate(ChallengeExtra, State),

    {keep_state_and_data, idle_timeout(State)};

connected(internal, {welcome, SessionId, Details}, State0) ->
    ?LOG_DEBUG(#{
        description => "Got welcome",
        session_id => SessionId,
        details => Details
    }),

    State1 = init_session_and_sync(SessionId, State0),
    State = reset_reconnect_retry_state(State1),

    %% TODO open sessions on remaning realms
    {keep_state, State, idle_timeout(State)};

connected(internal, {goodbye, SessionId, ?WAMP_CLOSE_REALM, Details}, State) ->

    RealmUri = session_realm(SessionId, State),
    Name = maps:get(name, State#state.config),

    ?LOG_WARNING(#{
        description => "Closing connection.",
        reason => ?WAMP_CLOSE_REALM,
        name => Name,
        session_id => SessionId,
        realm_uri => RealmUri,
        details => Details
    }),

    %% Kick out all local sessions
    bondy_realm_manager:close(RealmUri, ?WAMP_CLOSE_REALM),

    %% We currently support a single session so we shutdown.
    %% We will NOT be restarted
    {stop, shutdown};

connected(internal, {goodbye, SessionId, Reason, Details}, _State) ->
    %% We currently support a single session, so we stop
    ?LOG_NOTICE(#{
        description => "Closing connection.",
        reason => Reason,
        session_id => SessionId,
        details => Details
    }),
    %% We will be restarted
    {stop, {goodbye, Reason}};

connected(internal, {abort, _SessionId, Reason, Details}, _State) ->
    %% We currently support a single session, so we stop
    ?LOG_NOTICE(#{
        description => "Got abort message from server, closing connection.",
        reason => Reason,
        details => Details
    }),
    %% We will be restarted
    {stop, {abort, Reason}};

connected(internal, {aae_sync, SessionId, finished}, State0) ->
    ?LOG_INFO(#{
        description => "AAE sync finished",
        session_id => SessionId
    }),

    State = setup_proxing(SessionId, State0),

    {keep_state, State, idle_timeout(State)};

connected(internal, {aae_data, SessionId, Data}, State) ->
    ?LOG_DEBUG(#{
        description => "Got aae_sync data",
        session_id => SessionId,
        data => Data
    }),

    ok = handle_aae_data(Data, State),

    {keep_state, State, idle_timeout(State)};

connected(
    internal, {receive_message, SessionId, {forward, To, Msg, Opts}}, State) ->
    ?LOG_DEBUG(#{
        description => "Got session message from core router",
        session_id => SessionId,
        message => Msg
    }),

    ok = handle_session_message(Msg, To, Opts, SessionId, State),

    {keep_state, State, idle_timeout(State)};


connected(info, {Tag, Socket, Data}, #state{socket = Socket} = State)
when ?SOCKET_DATA(Tag) ->
    ok = set_socket_active(State),

    ?LOG_DEBUG(#{
        description => "Got TCP message",
        message => Data
    }),

    Actions = [
        {next_event, internal, binary_to_term(Data)},
        idle_timeout(State)
    ],
    {keep_state_and_data, Actions};

connected(info, {Tag, _Socket}, State0) when ?CLOSED_TAG(Tag) ->
    ?LOG_INFO(#{
        description => "Socket closed",
        reason => closed_by_remote
    }),
    State = on_disconnect(State0),
    {next_state, connecting, State};

connected(info, {Tag, _, Reason}, State0) when ?SOCKET_ERROR(Tag) ->
    ?LOG_ERROR(#{description => "Socket error", reason => Reason}),
    State = on_disconnect(State0),
    {next_state, connecting, State};

connected(info, timeout, #state{ping_sent = false} = State0) ->
    ?LOG_DEBUG(#{description => "Connection timeout, sending first ping"}),
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

connected(info, {?BONDY_REQ, _Pid, RealmUri, Msg}, State) ->
    ?LOG_DEBUG(#{
        description => "Received WAMP request we need to FWD to core",
        message => Msg
    }),
    SessionId = session_id(RealmUri, State),
    ok = send_session_message(SessionId, Msg, State),
    {keep_state_and_data, [idle_timeout(State)]};

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

connected(cast, {forward_message, Msg, SessionId}, State) ->
    case has_session(SessionId, State) of
        true ->
            send_session_message(SessionId, Msg, State);
        _ ->
            ?LOG_INFO(#{
                description => "Received message for an uplink session that doesn't exist",
                type => cast,
                event => Msg,
                session_id => SessionId
            }),
            ok
    end,
    keep_state_and_data;

connected(cast, Msg, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => cast,
        event => Msg
    }),
    keep_state_and_data;

connected(timeout, Msg, _) ->
    ?LOG_DEBUG(#{
        description => "Received timeout message",
        type => timeout,
        event => Msg
    }),
    %% We will be restarted
    {stop, {timeout, Msg}};

connected(EventType, Msg, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => EventType,
        event => Msg
    }),
    keep_state_and_data.



%% =============================================================================
%% PRIVATE: CONNECT
%% =============================================================================



%% @private
maybe_reconnect(Reason, #state{reconnect_retry = R0} = State0)
when R0 =/= undefined andalso
(?IS_RETRIABLE(Reason) orelse ?IS_NETDOWN(Reason)) ->
    %% Reconnect enabled
    case bondy_retry:fail(R0) of
        {Delay, R1} when is_integer(Delay) ->
            ?LOG_NOTICE(#{
                description => "Failed to establish uplink connection to core router. Will retry after delay.",
                delay => Delay,
                reason => Reason,
                reason_description => inet:format_error(Reason)
            }),
            State = State0#state{reconnect_retry = R1},
            {keep_state, State, [{state_timeout, Delay, connect}]};

        {Limit, R1} when Limit == deadline orelse Limit == max_retries ->
            %% We reached max retries
            ?LOG_NOTICE(#{
                description => "Failed to establish uplink connection to core router. Re-starting.",
                reason => Reason
            }),
            State = State0#state{reconnect_retry = R1},
            {stop, {limit, Limit}, State}
    end;

maybe_reconnect(Reason, _) ->
    %% Reconnect disabled or error is not retriable
    ?LOG_WARNING(#{
        description => "Failed to establish uplink connection to core router.",
        reason => Reason,
        reason_description => inet:format_error(Reason)
    }),
    %% We will NOT be restarted
    {stop, normal}.


%% @private
connect(State) ->
    Transport = State#state.transport,
    Endpoint = State#state.endpoint,
    Config = State#state.config,
    connect(Transport, Endpoint, Config).


%% @private
connect(Transport, {Host, PortNumber}, Config) ->

    Timeout = key_value:get(timeout, Config, 5000),
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
send_message(Message, State) ->
    Data = term_to_binary(Message),
    (State#state.transport):send(State#state.socket, Data).


%% @private
on_connect(State) ->
    ?LOG_NOTICE(#{description => "Established connection with remote router"}),

    %% We join any realms defined by the config
    open_sessions(State).


%% @private
reset_reconnect_retry_state(State) ->
    {_, R1} = bondy_retry:succeed(State#state.reconnect_retry),
    State#state{reconnect_retry = R1}.


%% @private
on_disconnect(State) ->
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


%% @private
idle_timeout(State) ->
    %% We use an event timeout meaning any event received will cancel it
    {timeout, State#state.idle_timeout, idle_timeout}.



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
%% PRIVATE: ESTABLISH SESSIONS
%% =============================================================================



%% @private
open_sessions(State0) ->
    case maps:to_list(maps:get(realms, State0#state.config)) of
        [] ->
            State0;
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
                },
                roles => ?WAMP_CLIENT_ROLES
            },

            %% TODO HELLO should include the Bondy Router Bridge Relay protocol
            %% version
            ok = send_message({hello, Uri, Details}, State0),

            Session = #{
                realm_uri => Uri,
                authid => AuthId,
                pubkey => PubKey,
                signer => signer(PubKey, H),
                authroles => []
            },

            State0#state{session = Session}
        end.


%% @private
init_session_and_sync(SessionId, #state{session = Session0} = State0) ->
    Session = Session0#{
        id => SessionId,
        ref => bondy_ref:new(bridge_relay, self(), SessionId)
    },

    State1 = add_session(Session, State0),

    %% Synchronise the realm configuraiton state before proxying
    State2 = aae_sync(Session, State1),

    State2#state{session = undefined}.


setup_proxing(SessionId, State0) ->
    %% Setup the meta subscriptions so that we can dynamically proxy
    %% events
    Session = session(SessionId, State0),

    State1 = subscribe_meta_events(Session, State0),

    %% Get the already registered registrations and subscriptions and proxy them
    State2 = proxy_existing(Session, State1),

    %% We finally subscribe to user events so that we can re-publish on the
    %% remote cluster
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


% update_session(Key, Value, Id, #state{} = State) ->
%     Sessions = State#state.sessions,
%     Session0 =  maps:get(Id, Sessions),
%     Session = maps:put(Key, Value, Session0),
%     State#state{sessions = maps:put(Id, Session, Sessions)}.



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
aae_sync(#{id := SessionId}, State) ->
    % Ref = make_ref(),
    % State = update_session(sync_ref, Ref, SessionId, State0),
    Msg = {aae_sync, SessionId, #{}},
    ok = send_message(Msg, State),
    State.


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
subscribe_meta_events(Session, State) ->
    SessionId = maps:get(id, Session),
    RealmUri = maps:get(realm_uri, Session),
    MyRef = maps:get(ref, Session),

    %% We subscribe to registration and subscription meta events
    %% The event handler will call
    %% forward(Me, Event, SessionId)

    _ = bondy_event_manager:add_sup_handler(
        {bondy_bridge_relay_event_handler, SessionId}, [RealmUri, MyRef]
    ),

    State.


%% -----------------------------------------------------------------------------
%% @private
%% @doc We subscribe to the topics configured for this realm.
%% But instead of receiving an EVENT we will get a PUBLISH message. This is an
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
            (#{uri := Uri, match := Match, direction := out}, Acc) ->
                {ok, Id} = bondy_broker:subscribe(
                    RealmUri, #{match => Match}, Uri, MyRef
                ),
                key_value:set([subscriptions, Id], Uri, Acc);

            (#{uri := _Uri, match := _Match, direction := _} = Subs, Acc) ->
                %% Not implemented yet
                ?LOG_WARNING(#{
                    description => "[Experimental] Bridge relay subscription direction type not currently supported",
                    subscription => Subs
                }),
                Acc
        end,
        Session0,
        Topics
    ),

    add_session(Session, State).


%% @private
proxy_existing(Session, State0) ->
    RealmUri = maps:get(realm_uri, Session),

    %% We want all sessions, callback modules or processes
    SessionId = '_',
    Limit = 100,

    %% We proxy all existing registrations
    Regs = bondy_dealer:registrations(RealmUri, SessionId, Limit),
    GetRegs = fun(Cont) -> bondy_dealer:registrations(Cont) end,
    State1 = proxy_existing(Session, State0, GetRegs, Regs),

    %% We proxy all existing subscriptions
    Subs = bondy_broker:subscriptions(RealmUri, SessionId, Limit),
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
            ok = send_session_message(SessionId, Msg, State),
            State;

        false when Type == subscription ->
            Msg = {subscription_added, bondy_registry_entry:to_external(Entry)},
            ok = send_session_message(SessionId, Msg, State),
            State
    end.



%% =============================================================================
%% PRIVATE: HANDLING WAMP EVENTS
%% =============================================================================



%% @private
send_session_message(SessionId, Msg, State) ->
    send_message({receive_message, SessionId, Msg}, State).



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

handle_session_message(Msg, To, Opts, SessionId, State) ->
    #{realm_uri := RealmUri, ref := MyRef} = session(SessionId, State),

    SendOpts = bondy:add_via(MyRef, Opts),
    bondy_router:forward(Msg, To, SendOpts#{realm_uri => RealmUri}).



% handle_event(#event{} = Event, State) ->
%     case maps:get(topic, Event#event.details) of

