%% =============================================================================
%%  bondy_wamp_tcp_connection_handler.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


-define(TIMEOUT, ?PING_TIMEOUT * 2).
-define(PING_TIMEOUT, 10000). % 10 secs


-record(state, {
    socket                  ::  gen_tcp:socket(),
    peername                ::  binary(),
    transport               ::  module(),
    frame_type              ::  frame_type(),
    encoding                ::  atom(),
    max_len                 ::  pos_integer(),
    ping_sent = false       ::  {true, binary(), reference()} | false,
    ping_attempts = 0       ::  non_neg_integer(),
    ping_max_attempts = 2   ::  non_neg_integer(),
    hibernate = false       ::  boolean(),
    start_time              ::  integer(),
    protocol_state          ::  bondy_wamp_protocol:state() | undefined,
    active_n = once         ::  once | -32768..32767,
    buffer = <<>>           ::  binary(),
    shutdown_reason         ::  term() | undefined
}).
-type state() :: #state{}.


-export([start_link/4]).


-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([format_status/2]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_link(
    Ref :: ranch:ref(), _, Transport :: module(), ProtoOpts :: any()) ->
    {ok, ConnPid :: pid()}
    | {ok, SupPid :: pid(), ConnPid :: pid()}.

start_link(Ref, _, Transport, Opts) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Transport, Opts}])}.



%% =============================================================================
%% GEN SERVER CALLBACKS
%% =============================================================================



init({Ref, Transport, _Opts0}) ->
    St0 = #state{
        start_time = erlang:monotonic_time(second),
        transport = Transport
    },

    Opts = [
        {active, active_n(St0)},
        {packet, 0}
        | bondy_config:get([Ref, socket_opts], [])
    ],

    {ok, Socket} = ranch:handshake(Ref),

    Res = Transport:setopts(Socket, Opts),

    ok = maybe_error(Res),

    {ok, Peername} = inet:peername(Socket),

    St1 = St0#state{socket = Socket},

    ok = bondy_logger_utils:set_process_metadata(#{
        transport => Transport,
        socket => Socket,
        peername => inet_utils:peername_to_binary(Peername)
    }),

    ok = socket_opened(St1),

    gen_server:enter_loop(?MODULE, [], St1, ?TIMEOUT).


handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {noreply, State, ?TIMEOUT}.


handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State, ?TIMEOUT}.


handle_info(
    {tcp, Socket, <<?RAW_MAGIC:8, MaxLen:4, Encoding:4, _:16>>},
    #state{socket = Socket, protocol_state = undefined} = St0) ->
    case handle_handshake(MaxLen, Encoding, St0) of
        {ok, St1} ->
            case maybe_active_once(St1) of
                ok ->
                    {noreply, St1, ?TIMEOUT};
                {error, Reason} ->
                    {stop, Reason, St1}
            end;
        {stop, Reason, St1} ->
            {stop, Reason, St1}
    end;

handle_info(
    {tcp, Socket, Data},
    #state{socket = Socket, protocol_state = undefined} = St) ->
    %% RFC: After a _Client_ has connected to a _Router_, the _Router_ will
    %% first receive the 4 octets handshake request from the _Client_.
    %% If the _first octet_ differs from "0x7F", it is not a WAMP-over-
    %% RawSocket request. Unless the _Router_ also supports other
    %% transports on the connecting port (such as WebSocket), the
    %% _Router_ MUST *fail the connection*.
    ?LOG_WARNING(#{
        description => "Received data before WAMP protocol handshake",
        reason => invalid_handshake,
        peername => St#state.peername,
        protocol => wamp,
        transport => St#state.transport,
        serializer => St#state.encoding,
        data => Data
    }),
    {stop, invalid_handshake, St};

handle_info({tcp, Socket, Data}, #state{socket = Socket} = St0) ->
    %% We append the newly received data to the existing buffer
    Buffer = St0#state.buffer,
    St1 = St0#state{buffer = <<>>},

    case handle_data(<<Buffer/binary, Data/binary>>, St1) of
        {ok, St2} ->
            case maybe_active_once(St1) of
                ok ->
                    {noreply, St2, ?TIMEOUT};
                {error, Reason} ->
                    {stop, Reason, St2}
            end;
        {stop, Reason, St2} ->
            {stop, Reason, St2}
    end;

handle_info({tcp_passive, Socket}, #state{socket = Socket} = St) ->
    %% We are using {active, N} and we consumed N messages from the socket
    ok = reset_inet_opts(St),
    {noreply, St, ?TIMEOUT};

handle_info({tcp_closed, _Socket}, State) ->
    {stop, normal, State};

handle_info({tcp_error, _, _} = Reason, State) ->
    {stop, Reason, State};

handle_info({?BONDY_PEER_REQUEST, Pid, _RealmUri, M}, St) when Pid =:= self() ->
    %% Here we receive a message from the bondy_router in those cases
    %% in which the router is embodied by our process i.e. the sync part
    %% of a routing process e.g. wamp calls
    handle_outbound(M, St);

handle_info({?BONDY_PEER_REQUEST, _Pid, _RealmUri, M}, St) ->
    %% Here we receive the messages that either the router or another peer
    %% have sent to us using bondy:send/2,3
    %% ok = bondy:ack(Pid, Ref),
    %% We send the message to the peer
    handle_outbound(M, St);


handle_info(timeout, #state{ping_sent = false} = State0) ->
    _ = log(
        debug,
        #{description => "Connection timeout, sending first ping"},
        State0
    ),
    {ok, State1} = send_ping(State0),
    %% Here we do not return a timeout value as send_ping set an ah-hoc timet
    {noreply, State1};

handle_info(
    ping_timeout,
    #state{ping_sent = Val, ping_attempts = N, ping_max_attempts = N} = State) when Val =/= false ->
    _ = log(
        error,
        #{
            description => "Connection closing",
            reason => ping_timeout,
            attempts => N
        },
        State
    ),
    {stop, ping_timeout, State#state{ping_sent = false}};

handle_info(ping_timeout, #state{ping_sent = {_, Bin, _}} = State) ->
    %% We try again until we reach ping_max_attempts
    _ = log(
        debug,
        #{description => "Ping timeout, sending another ping"},
        State
    ),
    %% We reuse the same payload, in case the client responds the previous one
    {ok, State1} = send_ping(Bin, State),
    %% Here we do not return a timeout value as send_ping set an ah-hoc timer
    {noreply, State1};

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



terminate(Reason, #state{transport = T, socket = S} = State)
when T =/= undefined andalso S =/= undefined ->
    ok = close_socket(Reason, State),
    terminate(Reason, State#state{transport = undefined, socket = undefined});

terminate(Reason, #state{protocol_state = P} = State) when P =/= undefined ->
    ok = bondy_wamp_protocol:terminate(P),
    terminate(Reason, State#state{protocol_state = undefined});

terminate(_, _) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


format_status(Opt, [_PDict, #state{} = State]) ->
    ProtocolState = bondy_sensitive:format_status(
        Opt, bondy_wamp_protocol, State#state.protocol_state
    ),
    gen_format(Opt, State#state{protocol_state = ProtocolState}).


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

gen_format(terminate, Term) ->
    Term.


%% @private
-spec handle_data(Data :: binary(), State :: state()) ->
    {ok, state()} | {stop, raw_error(), state()}.

handle_data(<<0:5, _:3, Len:24, _Data/binary>>, #state{max_len = MaxLen} = St)
when Len > MaxLen ->
    %% RFC: During the connection, Router MUST NOT send messages to the Client
    %% longer than the LENGTH requested by the Client, and the Client MUST NOT
    %% send messages larger than the maximum requested by the Router in it's
    %% handshake reply.
    %% If a message received during a connection exceeds the limit requested,
    %% a Peer MUST fail the connection.
    _ = log(
        error,
        #{
            description => "Client committed a WAMP protocol violation",
            reason => maximum_message_length_exceeded,
            message_length => Len
        },
        St
    ),
    {stop, maximum_message_length_exceeded, St};

handle_data(<<0:5, 0:3, Len:24, Mssg:Len/binary, Rest/binary>>, St) ->
    %% We received a WAMP message
    %% Len is the number of octets after serialization
    case bondy_wamp_protocol:handle_inbound(Mssg, St#state.protocol_state) of
        {ok, PSt} ->
            handle_data(Rest, St#state{protocol_state = PSt});
        {reply, L, PSt} ->
            St1 = St#state{protocol_state = PSt},
            ok = send(L, St1),
            handle_data(Rest, St1);
        {stop, PSt} ->
            {stop, normal, St#state{protocol_state = PSt}};
        {stop, L, PSt} ->
            St1 = St#state{protocol_state = PSt},
            ok = send(L, St1),
            {stop, normal, St1};
        {stop, normal, L, PSt} ->
            St1 = St#state{protocol_state = PSt},
            ok = send(L, St1),
            {stop, normal, St1};
        {stop, Reason, L, PSt} ->
            St1 = St#state{
                protocol_state = PSt,
                shutdown_reason = Reason
            },
            ok = send(L, St1),
            {stop, shutdown, St1}
    end;

handle_data(<<0:5, 1:3, Len:24, Payload:Len/binary, Rest/binary>>, St) ->
    %% We received a PING, send a PONG
    ok = send_frame(<<0:5, 2:3, Len:24, Payload/binary>>, St),
    handle_data(Rest, St);

handle_data(<<0:5, 2:3, Len:24, Payload:Len/binary, Rest/binary>>, St) ->
    %% We received a PONG
    _ = log(debug, #{description => "Received pong"}, St),
    case St#state.ping_sent of
        {true, Payload, TimerRef} ->
            %% We reset the state
            ok = erlang:cancel_timer(TimerRef, [{info, false}]),
            handle_data(Rest, St#state{ping_sent = false, ping_attempts = 0});
        {true, Bin, TimerRef} ->
            ok = erlang:cancel_timer(TimerRef, [{info, false}]),
            _ = log(error,
                #{
                    description => "Invalid pong message from peer",
                    reason => invalid_ping_response,
                    received => Bin,
                    expected => Payload
                },
                St
            ),
            {stop, invalid_ping_response, St};
        false ->
            _ = log(
                error,
                #{
                    description => "Unrequested pong message from peer"
                },
                St
            ),
            %% Should we stop instead?
            handle_data(Rest, St)
    end;

handle_data(<<0:5, R:3, Len:24, Mssg:Len/binary, Rest/binary>>, St)
when R > 2 ->
    %% The three bits (R) encode the type of the transport message,
    %% values 3 to 7 are reserved
    ok = send_frame(error_number(use_of_reserved_bits), St),
    _ = log(
        error,
        #{
            description => "Client committed a WAMP protocol violation, message dropped",
            reason => use_of_reserved_bits,
            value => R,
            message => Mssg
        },
        St
    ),
    %% Should we stop instead?
    handle_data(Rest, St);

handle_data(<<>>, St) ->
    %% We finished consuming data
    {ok, St};

handle_data(Data, St) ->
    %% We have a partial message i.e. byte_size(Data) < Len
    %% we store is as buffer
    {ok, St#state{buffer = Data}}.


-spec handle_outbound(any(), state()) ->
    {noreply, state(), timeout()}
    | {stop, normal, state()}.

handle_outbound(M, St0) ->
    case bondy_wamp_protocol:handle_outbound(M, St0#state.protocol_state) of
        {ok, Bin, PSt} ->
            St1 = St0#state{protocol_state = PSt},
            case send(Bin, St1) of
                ok ->
                    {noreply, St1, ?TIMEOUT};
                {error, Reason} ->
                    {stop, Reason, St1}
            end;
        {stop, PSt} ->
            {stop, normal, St0#state{protocol_state = PSt}};
        {stop, Bin, PSt} ->
            St1 = St0#state{protocol_state = PSt},
            case send(Bin, St1) of
                ok ->
                    {stop, normal, St1};
                {error, Reason} ->
                    {stop, Reason, St1}
            end;

        {stop, Bin, PSt, Time} when is_integer(Time), Time > 0 ->
            %% We send ourselves a message to stop after Time
            St1 = St0#state{protocol_state = PSt},
            erlang:send_after(
                Time, self(), {stop, normal}),
            case send(Bin, St1) of
                ok ->
                    {noreply, St1};
                {error, Reason} ->
                    {stop, Reason, St1}
            end
    end.


%% @private
handle_handshake(Len, Enc, St) ->
    try
        init_wamp(Len, Enc, St)
    catch
        throw:Reason:Stacktrace ->
            ok = send_frame(error_number(Reason), St),
            ?LOG_INFO(#{
                description => "WAMP protocol error, closing connection.",
                class => throw,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {stop, Reason, St}
    end.


%% @private
init_wamp(Len, Enc, St0) ->
    MaxLen = validate_max_len(Len),
    {FrameType, EncName} = validate_encoding(Enc),

    case inet:peername(St0#state.socket) of
        {ok, {_, _} = Peer} ->
            Proto = {raw, FrameType, EncName},

            case bondy_wamp_protocol:init(Proto, Peer, #{}) of
                {ok, CBState} ->
                    St1 = St0#state{
                        frame_type = FrameType,
                        encoding = EncName,
                        max_len = MaxLen,
                        protocol_state = CBState
                    },

                    ok = send_frame(
                        <<?RAW_MAGIC, Len:4, Enc:4, 0:8, 0:8>>, St1
                    ),

                    ?LOG_INFO(#{
                        description => "Established connection with peer"
                    }),

                    {ok, St1};
                {error, Reason} ->
                    {stop, Reason, St0}
            end;

        {ok, NonIPAddr} ->
            ?LOG_ERROR(#{
                description => "Unexpected peername when establishing connection",
                reason => invalid_socket,
                peername => NonIPAddr,
                protocol => wamp,
                transport => raw,
                frame_type => FrameType,
                serializer => EncName,
                message_max_length => MaxLen
            }),
            {stop, invalid_socket, St0};

        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Unexpected peername when establishing connection",
                reason => inet:format_error(Reason),
                protocol => wamp,
                transport => raw,
                frame_type => FrameType,
                serializer => EncName,
                message_max_length => MaxLen
            }),
            {stop, invalid_socket, St0}
    end.



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


%% @private
send_ping(St) ->
    send_ping(integer_to_binary(erlang:system_time(microsecond)), St).


%% -----------------------------------------------------------------------------
%% @private
%% @doc Sends a ping message with a reference() as a payload to the client and
%% sent ourselves a ping_timeout message in the future.
%% @end
%% -----------------------------------------------------------------------------
send_ping(Bin, St0) ->
    ok = send_frame(<<0:5, 1:3, (byte_size(Bin)):24, Bin/binary>>, St0),
    Timeout = bondy_config:get(ping_timeout, ?PING_TIMEOUT),
    TimerRef = erlang:send_after(Timeout, self(), ping_timeout),
    St1 = St0#state{
        ping_sent = {true, Bin, TimerRef},
        ping_attempts = St0#state.ping_attempts + 1
    },
    {ok, St1}.


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
error_number(serializer_unsupported) ->?RAW_ERROR(1);
error_number(maximum_message_length_unacceptable) ->?RAW_ERROR(2);
error_number(use_of_reserved_bits) ->?RAW_ERROR(3);
error_number(maximum_connection_count_reached) ->?RAW_ERROR(4).


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
        {socket_closed, wamp, raw, St#state.peername, Seconds}
    ),

    IncrSockerErrorCnt = fun() ->
        %% We increase the socker error counter
        bondy_event_manager:notify(
            {socket_error, wamp, raw, St#state.peername}
        )
    end,

    LogMsg = case Reason of
        normal ->
            #{
                description => <<"Connection closed by peer">>,
                reason => Reason
            };

        closed ->
            #{
                description => <<"Connection closed by peer">>,
                reason => Reason
            };

        shutdown ->
            #{
                description => <<"Connection closed by router">>,
                reason => Reason
            };

        {tcp_error, Socket, Reason} ->
            %% We increase the socker error counter
            ok = IncrSockerErrorCnt(),
            #{
                description => <<"Connection closing due to tcp_error">>,
                reason => Reason
            };


        _ ->
            %% We increase the socket error counter
            ok = IncrSockerErrorCnt(),
            #{
                description => <<"Connection closing due to system error">>,
                reason => Reason
            }
    end,

    _ = log(error, LogMsg, St),
    ok.



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
maybe_error({error, Reason}) ->
    error(Reason);

maybe_error(Term) ->
    Term.


%% @private
log(Level, Msg, #state{protocol_state = undefined}) ->
    logger:log(Level, Msg);

log(Level, Msg0, St) ->
    ProtocolState = St#state.protocol_state,

    Msg = Msg0#{
        agent => bondy_wamp_protocol:agent(ProtocolState),
        serializer => St#state.encoding,
        frame_type => St#state.frame_type,
        message_max_length => St#state.max_len,
        socket => St#state.socket
    },
    Meta = #{
        realm => bondy_wamp_protocol:realm_uri(ProtocolState),
        session_id => bondy_wamp_protocol:session_id(ProtocolState),
        peername => St#state.peername
    },
    logger:log(Level, Msg, Meta).