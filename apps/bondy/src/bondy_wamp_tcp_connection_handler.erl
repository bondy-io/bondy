%% =============================================================================
%%  bondy_wamp_tcp_connection_handler.erl -
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
%% @doc
%% A ranch handler for the wamp protocol over either tcp or tls transports.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_wamp_tcp_connection_handler).
-behaviour(gen_server).
-behaviour(ranch_protocol).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").


-define(TIMEOUT(S), S#state.idle_timeout).


-record(state, {
    listener                ::  atom(),
    socket                  ::  gen_tcp:socket() | ssl:socket(),
    proxy_protocol          ::  bondy_tcp_proxy_protocol:t(),
    peername                ::  {inet:ip_address(), integer()},
    source_ip               ::  inet:ip_address(),
    transport               ::  module(),
    frame_type              ::  frame_type(),
    encoding                ::  atom(),
    max_len                 ::  pos_integer(),
    idle_timeout            ::  timeout(),
    ping_idle_timeout       ::  non_neg_integer(),
    ping_tref               ::  optional(reference()),
    ping_payload            ::  binary(),
    ping_retry              ::  optional(bondy_retry:t()),
    hibernate = false       ::  boolean(),
    start_time              ::  integer(),
    active_n = once         ::  once | -32768..32767,
    buffer = <<>>           ::  binary(),
    shutdown_reason         ::  term() | undefined,
    protocol_state          ::  bondy_wamp_protocol:state() | undefined
}).

-type state() :: #state{}.


-export([start_link/3]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([format_status/1]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_link(
    Ref :: ranch:ref(), Transport :: module(), ProtoOpts :: any()) ->
    {ok, ConnPid :: pid()}
    | {ok, SupPid :: pid(), ConnPid :: pid()}.

start_link(Ref, Transport, Opts) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Transport, Opts}])}.



%% =============================================================================
%% GEN SERVER CALLBACKS
%% =============================================================================



init({Ref, Transport, _Opts0}) ->
    ok = logger:update_process_metadata(#{
        listener => Ref,
        transport => Transport
    }),

    %% We to make this call before ranch:handshake/2
    ProxyProtocol = bondy_tcp_proxy_protocol:init(Ref, 15_000),

    %% Setup and configure socket
    TLSOpts = bondy_config:get([Ref, tls_opts], []),
    {ok, Socket} = ranch:handshake(Ref, TLSOpts),

    {PeerIP, _} = Peername = peername(Transport, Socket),

    SourceIP = source_ip(ProxyProtocol, PeerIP),

    ok = logger:update_process_metadata(#{
        peername => inet_utils:peername_to_binary(Peername),
        source_ip => inet:ntoa(SourceIP)
    }),

    State = #state{
        listener = Ref,
        idle_timeout = bondy_config:get([Ref, idle_timeout], infinity),
        start_time = erlang:monotonic_time(second),
        transport = Transport,
        socket = Socket,
        proxy_protocol = ProxyProtocol,
        peername = Peername,
        source_ip = SourceIP
    },

    SocketOpts = [
        {active, active_n(State)},
        {packet, 0}
        | bondy_config:get([Ref, socket_opts], [])
    ],

    %% If Transport == ssl, upgrades a gen_tcp, or equivalent, socket to an SSL
    %% socket by performing the TLS server-side handshake, returning a TLS
    %% socket.
    ok = maybe_exit(Transport:setopts(Socket, SocketOpts)),

    ok = socket_opened(State),

    ?LOG_INFO(#{
        description => "Established connection with client."
    }),

    gen_server:enter_loop(?MODULE, [], State, ?TIMEOUT(State)).


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {noreply, State, ?TIMEOUT(State)}.


handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State, ?TIMEOUT(State)}.


%% Handle TCP & SSL handshake
handle_info(
    {Transport, Socket, <<?RAW_MAGIC:8, MaxLen:4, Encoding:4, _:16>>},
    #state{socket = Socket, protocol_state = undefined} = State0)
when Transport =:= tcp orelse Transport =:= ssl ->
    case handle_handshake(MaxLen, Encoding, State0) of
        {ok, State} ->
            case maybe_active_once(State) of
                ok ->
                    {noreply, reset_ping(State), ?TIMEOUT(State)};
                {error, Reason} ->
                    {stop, Reason, State}
            end;
        {stop, Reason, State} ->
            {stop, Reason, State}
    end;

%% Handle invalid TCP % SSL handshake
handle_info(
    {Transport, Socket, Data},
    #state{socket = Socket, protocol_state = undefined} = St)
when Transport =:= tcp orelse Transport =:= ssl ->
    %% RFC: After a _Client_ has connected to a _Router_, the _Router_ will
    %% first receive the 4 octets handshake request from the _Client_.
    %% If the _first octet_ differs from "0x7F", it is not a WAMP-over-
    %% RawSocket request. Unless the _Router_ also supports other
    %% transports on the connecting port (such as WebSocket), the
    %% _Router_ MUST *fail the connection*.
    ?LOG_WARNING(#{
        description => "Received data before WAMP protocol handshake",
        reason => invalid_handshake,
        data => Data
    }),
    {stop, invalid_handshake, St};

%% Handle TCP & SSL data
handle_info({Transport, Socket, Data}, #state{socket = Socket} = State0)
when Transport =:= tcp orelse Transport =:= ssl ->
    %% We append the newly received data to the existing buffer
    Buffer = State0#state.buffer,
    State1 = State0#state{buffer = <<>>},

    case handle_inbound(<<Buffer/binary, Data/binary>>, State1) of
        {ok, State} ->
            case maybe_active_once(State1) of
                ok ->
                    {noreply, reset_ping(State), ?TIMEOUT(State)};
                {error, Reason} ->
                    {stop, Reason, State}
            end;
        {stop, Reason, State} ->
            {stop, Reason, disable_ping(State)}
    end;

handle_info({tcp_passive, Socket}, #state{socket = Socket} = State) ->
    %% We are using {active, N} and we consumed N messages from the socket
    ok = reset_inet_opts(State),
    {noreply, State, ?TIMEOUT(State)};

handle_info({tcp_closed, _Socket}, State) ->
    {stop, normal, State};

handle_info({tcp_error, _, _} = Reason, State) ->
    {stop, Reason, State};

%% SSL control message handlers
handle_info({ssl_passive, Socket}, #state{socket = Socket} = State) ->
    %% We are using {active, N} and we consumed N messages from the socket
    ok = reset_inet_opts(State),
    {noreply, State, ?TIMEOUT(State)};

handle_info({ssl_closed, _Socket}, State) ->
    {stop, normal, State};

handle_info({ssl_error, _, _} = Reason, State) ->
    {stop, Reason, State};

handle_info({?BONDY_REQ, Pid, _RealmUri, M}, St) when Pid =:= self() ->
    %% Here we receive a message from the bondy_router in those cases
    %% in which the router is embodied by our process i.e. the sync part
    %% of a routing process e.g. wamp calls
    handle_outbound(M, St);

handle_info({?BONDY_REQ, _Pid, _RealmUri, M}, St) ->
    %% Here we receive the messages that either the router or another peer
    %% have sent to us using bondy:send/2,3
    %% ok = bondy:ack(Pid, Ref),
    %% We send the message to the peer
    handle_outbound(M, St);


handle_info(
    {timeout, Ref, ping_idle_timeout}, #state{ping_tref = Ref} = State) ->
    ?LOG_DEBUG(#{
        description => "Connection timeout, sending first ping",
        attempts => bondy_retry:count(State#state.ping_retry)
    }),

    %% ping_idle_timeout (not to be confused with idle_timeout)
    %% We avoid using the gen_server timeout as the ping has already a timer
    maybe_send_ping(State);

handle_info({timeout, Ref, ping_timeout}, #state{ping_tref = Ref} = State) ->
    ?LOG_DEBUG(#{
        description => "Ping timeout, retrying ping",
        attempts => bondy_retry:count(State#state.ping_retry)
    }),
    %% We will retry or fail depending on retry configuration and state
    maybe_send_ping(State);

handle_info({timeout, Ref, Msg}, State) ->
    ?LOG_DEBUG(#{
        description => "Received unknown timeout",
        message => Msg,
        ref => Ref
    }),
    {noreply, State};

handle_info({stop, Reason}, State) ->
    {stop, Reason, State};

handle_info({'DOWN', Ref, process, Pid, Reason}, State) ->
    ?LOG_DEBUG(#{
        description => "Failed to send message to destination, process is gone",
        reason => noproc,
        destination => Pid,
        destination_ref => Ref,
        destination_termination_reason => Reason
    }),
    {noreply, State};

handle_info(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


terminate(Reason, #state{transport = T, socket = S} = State0)
when T =/= undefined andalso S =/= undefined ->
    ok = close_socket(Reason, State0),
    State = State0#state{transport = undefined, socket = undefined},
    terminate(Reason, State);

terminate(normal, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by client",
        reason => normal
    }),
    do_terminate(State);

terminate(closed, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by client",
        reason => closed
    }),
    do_terminate(State);

terminate(timeout, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by router",
        reason => idle_timeout
    }),
    do_terminate(State);

terminate(shutdown, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by router",
        reason => shutdown
    }),
    do_terminate(State);

terminate({shutdown, Reason}, State) ->
    ?LOG_INFO(#{
        description => "Connection closed by router",
        reason => Reason
    }),
    do_terminate(State);

terminate({tcp_error, _, Reason}, State) ->
    ?LOG_ERROR(#{
        description => "Connection closing due to TCP error",
        reason => Reason
    }),
    do_terminate(State);

terminate(Reason, State) ->
    ?LOG_ERROR(#{
        description => "Connection closing",
        reason => Reason
    }),
    do_terminate(State).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


format_status(#{state := State} = Status) ->
    PState0 = State#state.protocol_state,
    PState = bondy_sensitive:format_status(bondy_wamp_protocol, PState0),
    maps:put(Status, state, State#state{protocol_state = PState});

format_status(Status) ->
    Status.



%% =============================================================================
%% PRIVATE
%% =============================================================================


source_ip(ProxyProtocol, PeerIP) ->
    case bondy_tcp_proxy_protocol:source_ip(ProxyProtocol, PeerIP) of
        {ok, SourceIP} ->
            SourceIP;

        {error, {socket_error, Message}} ->
            ?LOG_INFO(#{
                description =>
                    "Connection rejected. "
                    "The source IP Address couldn't be obtained "
                    "due to a socket error.",
                reason => Message,
                proxy_protocol => maps:without([error], ProxyProtocol)
            }),
            exit(normal);

        {error, {protocol_error, Message}} ->
            ?LOG_INFO(#{
                description =>
                    "Connection rejected. "
                    "The source IP Address couldn't be obtained "
                    "due to a proxy protocol error.",
                reason => Message,
                proxy_protocol => maps:without([error], ProxyProtocol)
            }),
            exit(normal)
    end.


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
-spec handle_inbound(Data :: binary(), State :: state()) ->
    {ok, state()} | {stop, raw_error(), state()}.

handle_inbound(
    <<0:5, _:3, Len:24, _Data/binary>>, #state{max_len = MaxLen} = St
) when Len > MaxLen ->
    %% RFC: During the connection, Router MUST NOT send messages to the Client
    %% longer than the LENGTH requested by the Client, and the Client MUST NOT
    %% send messages larger than the maximum requested by the Router in it's
    %% handshake reply.
    %% If a message received during a connection exceeds the limit requested,
    %% a Peer MUST fail the connection.
    ?LOG_ERROR(#{
        description => "Client committed a WAMP protocol violation",
        reason => maximum_message_length_exceeded,
        maximum_length => MaxLen,
        message_length => Len
    }),
    {stop, maximum_message_length_exceeded, St};

handle_inbound(<<0:5, 0:3, Len:24, Msg:Len/binary, Rest/binary>>, State0) ->
    %% We received a WAMP message
    %% Len is the number of octets after serialization
    case bondy_wamp_protocol:handle_inbound(Msg, State0#state.protocol_state) of
        {noreply, PSt} ->
            handle_inbound(Rest, State0#state{protocol_state = PSt});

        {reply, L, PSt} ->
            State = State0#state{protocol_state = PSt},
            ok = send(L, State),
            handle_inbound(Rest, State);

        {stop, PSt} ->
            State = State0#state{protocol_state = PSt},
            {stop, normal, State};

        {stop, L, PSt} ->
            State = State0#state{protocol_state = PSt},
            ok = send(L, State),
            {stop, normal, State};

        {stop, normal, L, PSt} ->
            State = State0#state{protocol_state = PSt},
            ok = send(L, State),
            {stop, normal, State};

        {stop, Reason, L, PSt} ->
            State = State0#state{
                protocol_state = PSt,
                shutdown_reason = Reason
            },
            ok = send(L, State),
            {stop, shutdown, State}
    end;

handle_inbound(<<0:5, 1:3, Len:24, Payload:Len/binary, Rest/binary>>, State) ->
    %% We received a PING, send a PONG
    ok = send_frame(<<0:5, 2:3, Len:24, Payload/binary>>, State),
    handle_inbound(Rest, State);

handle_inbound(<<0:5, 2:3, Len:24, Payload:Len/binary, Rest/binary>>, State) ->
    %% We received a PONG
    ?LOG_DEBUG(#{
        description => "Received pong",
        payload => Payload
    }),

    case Payload == State#state.ping_payload of
        true ->
            handle_inbound(Rest, State);

        false ->
            ?LOG_ERROR(#{
                description => "Invalid pong message from peer",
                reason => invalid_ping_response,
                received => Payload,
                expected => State#state.ping_payload
            }),
            {stop, invalid_ping_response, State}
    end;

handle_inbound(<<0:5, R:3, Len:24, Msg:Len/binary, Rest/binary>>, State)
when R > 2 ->
    %% The three bits (R) encode the type of the transport message,
    %% values 3 to 7 are reserved
    ok = send_frame(error_number(use_of_reserved_bits), State),
    ?LOG_ERROR(#{
        description =>
            "Client committed a WAMP protocol violation, message dropped",
        reason => use_of_reserved_bits,
        value => R,
        message => Msg
    }),
    %% Should we stop instead?
    handle_inbound(Rest, State);

handle_inbound(<<>>, State) ->
    %% We finished consuming data
    {ok, State};

handle_inbound(Data, State0) ->
    %% We have a partial message i.e. byte_size(Data) < Len
    %% we store is as buffer
    State = State0#state{buffer = Data},
    {ok, State}.


-spec handle_outbound(any(), state()) ->
    {noreply, state(), timeout()}
    | {stop, normal, state()}.

handle_outbound(M, State0) ->
    case bondy_wamp_protocol:handle_outbound(M, State0#state.protocol_state) of
        {ok, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            {noreply, State, ?TIMEOUT(State)};

        {ok, Bin, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            case send(Bin, State) of
                ok ->
                    {noreply, State, ?TIMEOUT(State)};

                {error, Reason} ->
                    {stop, Reason, State}
            end;

        {stop, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            {stop, normal, disable_ping(State)};

        {stop, Bin, ProtoState} ->
            State = State0#state{protocol_state = ProtoState},
            case send(Bin, State) of
                ok ->
                    {stop, normal, disable_ping(State)};
                {error, Reason} ->
                    {stop, Reason, disable_ping(State)}
            end;

        {stop, Bin, ProtoState, Time} when is_integer(Time), Time > 0 ->
            %% We send ourselves a message to stop after Time
            State = State0#state{protocol_state = ProtoState},
            erlang:send_after(Time, self(), {stop, normal}),

            case send(Bin, State) of
                ok ->
                    {noreply, disable_ping(State)};

                {error, Reason} ->
                    {stop, Reason, disable_ping(State)}
            end
    end.


%% @private
handle_handshake(Len, Enc, State) ->
    try
        init_wamp(Len, Enc, State)
    catch
        throw:Reason:Stacktrace ->
            ok = send_frame(error_number(Reason), State),
            ?LOG_INFO(#{
                description => "WAMP protocol error, closing connection.",
                class => throw,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {stop, Reason, State}
    end.


%% @private
init_wamp(Len, Enc, State0) ->
    MaxLen = validate_max_len(Len),
    {FrameType, EncName} = validate_encoding(Enc),
    Proto = {raw, FrameType, EncName},
    Peer = State0#state.peername,
    Opts = #{source_ip => State0#state.source_ip},

    case bondy_wamp_protocol:init(Proto, Peer, Opts) of
        {ok, ProtoState} ->
            State1 = State0#state{
                frame_type = FrameType,
                encoding = EncName,
                max_len = MaxLen,
                protocol_state = ProtoState
            },

            PingOpts = maps_utils:from_property_list(
                bondy_config:get([State0#state.listener, ping])
            ),

            State = maybe_enable_ping(PingOpts, State1),

            ok = send_frame(
                <<?RAW_MAGIC, Len:4, Enc:4, 0:8, 0:8>>, State
            ),

            ok = logger:update_process_metadata(#{
                protocol => wamp,
                serializer => State#state.encoding
            }),

            ?LOG_INFO(#{
                description => "Established WAMP Session with client."
            }),

            {ok, State};

        {error, Reason} ->
            {stop, Reason, State0}
    end.

%% @private
do_terminate(undefined) ->
    ok;

do_terminate(State) ->
    ok = cancel_timer(State#state.ping_tref),
    bondy_wamp_protocol:terminate(State#state.protocol_state).


%% @private
-spec send(binary() | list(), state()) -> ok | {error, any()}.

send(L, St) when is_list(L) ->
    lists:foreach(fun(Bin) -> send(Bin, St) end, L);

send(Bin, St) ->
    send_frame(?RAW_FRAME(Bin), St).


%% @private
-spec send_frame(binary(), state()) -> ok | {error, any()}.

send_frame(Frame, St) when is_binary(Frame) ->
    (St#state.transport):send(St#state.socket, Frame).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% The possible values for "LENGTH" are:
%%
%% 0: 2**9 octets
%% 1: 2**10 octets ...
%% 15: 2**24 octets
%%
%% This means a _Client_ can choose the maximum message length between *512*
%% and *16M* octets.
%% @end
%% -----------------------------------------------------------------------------
validate_max_len(N) when N >= 0, N =< 15 ->
    trunc(math:pow(2, 9 + N));

validate_max_len(_) ->
    %% TODO define correct error return
    throw(maximum_message_length_unacceptable).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% 0: illegal
%% 1: JSON
%% 2: MessagePack
%% 3 - 15: reserved for future serializers
%% @end
%% -----------------------------------------------------------------------------
validate_encoding(1) ->
    {binary, json};

validate_encoding(2) ->
    {binary, msgpack};

validate_encoding(N) ->
    case lists:keyfind(N, 2, bondy_config:get(wamp_serializers, [])) of
        {erl, N} ->
            {binary, erl};
        {bert, N} ->
            {binary, bert};
        undefined ->
            %% TODO define correct error return
            throw(serializer_unsupported)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% 0: illegal (must not be used)
%% 1: serializer unsupported
%% 2: maximum message length unacceptable
%% 3: use of reserved bits (unsupported feature)
%% 4: maximum connection count reached
%% 5 - 15: reserved for future errors
%% @end
%% -----------------------------------------------------------------------------
error_number(serializer_unsupported) -> ?RAW_ERROR(1);
error_number(maximum_message_length_unacceptable) -> ?RAW_ERROR(2);
error_number(use_of_reserved_bits) -> ?RAW_ERROR(3);
error_number(maximum_connection_count_reached) -> ?RAW_ERROR(4).


%% error_reason(1) -> serializer_unsupported;
%% error_reason(2) -> maximum_message_length_unacceptable;
%% error_reason(3) -> use_of_reserved_bits;
%% error_reason(4) -> maximum_connection_count_reached.


%% @private
socket_opened(St) ->
    Event = {socket_open, wamp, raw, St#state.peername},
    bondy_event_manager:notify(Event).


%% @private
close_socket(Reason, St) ->
    Socket = St#state.socket,
    catch (St#state.transport):close(Socket),

    Seconds = erlang:monotonic_time(second) - St#state.start_time,

    %% We report socket stats
    ok = bondy_event_manager:notify(
        {[bondy, socket, closed], wamp, raw, St#state.peername, Seconds}
    ),

    case Reason of
        {tcp_error, _, _} ->
            %% We increase the socker error counter
            ok = bondy_event_manager:notify(
                {[bondy, socket, error], wamp, raw, St#state.peername}
            );

        _ ->
            ok
    end.


%% @private
active_n(#state{active_n = N}) ->
    %% TODO make this dynamic based on adaptive algorithm that takes into
    %% account:
    %% - overall node load
    %% - this socket traffic i.e. slow traffic => once, high traffic => N
    N.


%% @private
maybe_active_once(#state{active_n = once} = State) ->
    Transport = State#state.transport,
    Socket = State#state.socket,
    Transport:setopts(Socket, [{active, once}]);

maybe_active_once(#state{active_n = N} = State) ->
    Transport = State#state.transport,
    Socket = State#state.socket,
    Transport:setopts(Socket, [{active, N}]).


%% @private
reset_inet_opts(#state{} = State) ->
    Transport = State#state.transport,
    Socket = State#state.socket,
    N = active_n(State),
    Transport:setopts(Socket, [{active, N}]).


%% @private
maybe_exit({error, Reason}) ->
    exit(Reason);

maybe_exit(Term) ->
    Term.




%% =============================================================================
%% PRIVATE: PING TIMEOUT
%% =============================================================================



%% @private
maybe_enable_ping(#{enabled := true} = PingOpts, State) ->
    %% Use the listener's idle_timeout, not from ping options
    IdleTimeout = State#state.idle_timeout,
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
reset_ping(#state{ping_retry = undefined} = State) ->
    %% ping disabled
    State;

reset_ping(#state{ping_tref = undefined} = State) ->
    Time = State#state.ping_idle_timeout,
    Ref = erlang:start_timer(Time, self(), ping_idle_timeout),

    State#state{ping_tref = Ref};

reset_ping(#state{} = State) ->
    ok = cancel_timer(State#state.ping_tref),

    %% Reset retry state
    {_, Retry} = bondy_retry:succeed(State#state.ping_retry),

    Time = State#state.ping_idle_timeout,
    Ref = erlang:start_timer(Time, self(), ping_idle_timeout),

    State#state{
        ping_retry = Retry,
        ping_tref = Ref
    }.


%% @private
disable_ping(#state{ping_retry = undefined} = State) ->
    State;

disable_ping(#state{} = State) ->
    ok = cancel_timer(State#state.ping_tref),
    State#state{ping_retry = undefined}.


%% @private
cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;

cancel_timer(_) ->
    ok.


%% @private
maybe_send_ping(#state{ping_idle_timeout = undefined} = State) ->
    %% ping disabled
    {noreply, State};

maybe_send_ping(#state{} = State) ->
    {Result, Retry} = bondy_retry:fail(State#state.ping_retry),
    maybe_send_ping(Result, State#state{ping_retry = Retry}).


%% @private
maybe_send_ping(Limit, State)
when Limit == deadline orelse Limit == max_retries ->
    % ?LOG_INFO(#{
    %     description => "Connection closing.",
    %     reason => ping_timeout
    % }),
    {stop, {shutdown, ping_timeout}, State};

maybe_send_ping(_Time, #state{} = State0) ->
    %% We send a ping
    Bin = State0#state.ping_payload,
    Frame = <<0:5, 1:3, (byte_size(Bin)):24, Bin/binary>>,
    ok = send_frame(Frame, State0),

    %% We schedule the next retry
    Ref = bondy_retry:fire(State0#state.ping_retry),
    State = State0#state{ping_tref = Ref},

    {noreply, State}.