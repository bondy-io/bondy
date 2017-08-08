%% =============================================================================
%%  bondy_wamp_raw_handler.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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



%% =============================================================================
%% @doc
%% A ranch handler for the wamp protocol over either tcp or tls transports.
%% @end
%% =============================================================================
-module(bondy_wamp_raw_handler).
-behaviour(gen_server).
-behaviour(ranch_protocol).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").


-define(TCP, wamp_tcp).
-define(TLS, wamp_tls).
-define(TIMEOUT, 60000 * 60).
-define(RAW_MAGIC, 16#7F).
-define(RAW_MSG_PREFIX, <<0:5, 0:3>>).
-define(RAW_PING_PREFIX, <<0:5, 1:3>>).
-define(RAW_PONG_PREFIX, <<0:5, 2:3>>).

%% 0: illegal (must not be used)
%% 1: serializer unsupported
%% 2: maximum message length unacceptable
%% 3: use of reserved bits (unsupported feature)
%% 4: maximum connection count reached
%% 5 - 15: reserved for future errors
-define(RAW_ERROR(Upper), <<?RAW_MAGIC:8, Upper:4, 0:20>>).
-define(RAW_FRAME(Bin), <<0:5, 0:3, (byte_size(Bin)):24, Bin/binary>>).

-record(state, {
    frame_type              ::  frame_type(),
    protocol_state          ::  bondy_wamp_protocol:state() | undefined,
    socket                  ::  gen_tcp:socket(),
    transport               ::  module(),
    max_len                 ::  pos_integer(),
    ping_sent               ::  binary() | undefined,
    hibernate = false       ::  boolean()
}).
-type state() :: #state{}.

-type raw_error()           :: invalid_response
                                | invalid_socket
                                | invalid_wamp_data
                                | maximum_connection_count_reached
                                | maximum_message_length_unacceptable
                                | serializer_unsupported
                                | use_of_reserved_bits.

-export([start_link/4]).
-export([start_listeners/0]).


-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Starts the tcp and tls raw socket listeners
%% @end
%% -----------------------------------------------------------------------------
-spec start_listeners() -> ok.

start_listeners() ->
    start_listeners([?TCP, ?TLS]).


%% @private
start_listeners([]) ->
    ok;

start_listeners([H|T]) ->
    {ok, Opts} = application:get_env(bondy, H),
    case lists:keyfind(enabled, 1, Opts) of
        {_, true} ->
            {_, PoolSize} = lists:keyfind(acceptors_pool_size, 1, Opts),
            {_, Port} = lists:keyfind(port, 1, Opts),
            {_, MaxConns} = lists:keyfind(max_connections, 1, Opts),
            TransportOpts = case H == ?TLS of
                true ->
                    {_, Files} = lists:keyfind(pki_files, 1, Opts),
                    Files;
                false ->
                    []
            end,
            {ok, _} = ranch:start_listener(
                H,
                PoolSize,
                ranch_mod(H),
                [{port, Port}],
                bondy_wamp_raw_handler,
                TransportOpts
            ),
            _ = ranch:set_max_connections(H, MaxConns),
            start_listeners(T);
        {_, false} ->
            start_listeners(T)
    end.


%% @private
ranch_mod(?TCP) -> ranch_tcp;
ranch_mod(?TLS) -> ranch_ssl.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link(Ref, Socket, Transport, Opts) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Socket, Transport, Opts}])}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init({Ref, Socket, Transport, _Opts}) ->
    %% We must call ranch:accept_ack/1 before doing any socket operation.
    %% This will ensure the connection process is the owner of the socket.
    %% It expects the listener’s name as argument.
    ok = ranch:accept_ack(Ref),
    Transport:setopts(Socket, [{active, once}, {packet, 0}]),
    St = #state{
        socket = Socket,
        transport = Transport
    },
    gen_server:enter_loop(?MODULE, [], St, ?TIMEOUT).


handle_info(
    {tcp, Socket, Data},
    #state{socket = Socket, transport = Transport} = St0) ->

    case handle_data(Data, St0) of
        {ok, St1} ->
            Transport:setopts(Socket, [{active, once}]),
            {noreply, St1, ?TIMEOUT};
        {stop, St1} ->
            {stop, normal, St1};
        {error, Reason, St1} ->
            _ = lager:error("TCP Connection closing, error=~p", [Reason]),
            {stop, reason, St1}
    end;

handle_info({?BONDY_PEER_CALL, Pid, M}, St) when Pid =:= self() ->
    handle_outbound(M, St);

handle_info({?BONDY_PEER_CALL, Pid, Ref, M}, St) ->
    %% Here we receive the messages that either the router or another peer
    %% sent to us using bondy:send/2,3
    ok = bondy:ack(Pid, Ref),
    handle_outbound(M, St);

handle_info({tcp_closed, Socket}, St) ->
    _ = lager:info(
        <<"TCP Connection closed by peer, socket=~p, pid=~p">>,
        [Socket, self()]
    ),
    {stop, normal, St};

handle_info({tcp_error, Socket, Reason}, State) ->
    _ = lager:error(
        "TCP Connection closing, error=tcp_error, reason=~p, socket=~p, pid=~p",
        [Reason, Socket, self()]),
	{stop, Reason, State};

handle_info(timeout, State) ->
    _ = lager:error(
        "TCP Connection closing, error=timeout, pid='~p'",
        [self()]
    ),
	{stop, normal, State};

handle_info(_Info, State) ->
	{stop, normal, State}.


handle_call(_Request, _From, State) ->
	{reply, ok, State}.


handle_cast(_Msg, State) ->
	{noreply, State}.


terminate(Reason, St) ->
    _ = lager:info("TCP Connection closing, reason=~p", [Reason]),
	bondy_wamp_protocol:terminate(St#state.protocol_state).


code_change(_OldVsn, State, _Extra) ->
	{ok, State}.







%% =============================================================================
%% PRIVATE
%% =============================================================================



-spec handle_data(Data :: binary(), State :: state()) ->
    {ok, state()}
    | {stop, state()}
    | {error, raw_error(), state()}.

handle_data(
    <<?RAW_MAGIC:8, MaxLen:4, Encoding:4, _:16>>,
    #state{protocol_state = undefined} = St) ->
    handle_handshake(MaxLen, Encoding, St);

handle_data(_Data, #state{protocol_state = undefined} = St) ->
    %% After a _Client_ has connected to a _Router_, the _Router_ will
    %% first receive the 4 octets handshake request from the _Client_.
    %% If the _first octet_ differs from "0x7F", it is not a WAMP-over-
    %% RawSocket request. Unless the _Router_ also supports other
    %% transports on the connecting port (such as WebSocket), the
    %% _Router_ MUST *fail the connection*.
    {error, invalid_wamp_data, St};

handle_data(<<?RAW_MAGIC:8, Error:4, 0:20>>, St) ->
    {error, error_reason(Error), St};

handle_data(<<0:5, _:3, _:24, Data/binary>>, #state{max_len = Max} = St)
when byte_size(Data) > Max->
    ok = send_frame(error_number(maximum_message_length_unacceptable), St),
    {stop, St};

handle_data(<<0:5, 1:3, Rest/binary>>, St) ->
    %% We received a PING, send a PONG
    ok = send_frame(<<0:5, 2:3, Rest/binary>>, St),
    {ok, St};

handle_data(<<0:5, 2:3, Rest/binary>>, St) ->
    %% We received a PONG
    case St#state.ping_sent of
        undefined ->
            %% We never sent this ping
            {ok, St};
        Rest ->
            {ok, St#state{ping_sent = undefined}};
        _ ->
            %% Wrong answer
            _ = lager:error("Invalid ping response from peer"),
            {error, invalid_response, St}
    end;

handle_data(<<0:5, R:3, _Len:24, _Rest/binary>>, St) when R > 2 andalso R < 8 ->
    ok = send_frame(error_number(use_of_reserved_bits), St),
    {stop, St};

handle_data(Data, St) when is_binary(Data) ->
    case bondy_wamp_protocol:handle_inbound(Data, St#state.protocol_state) of
        {ok, PSt} ->
            {ok, St#state{protocol_state = PSt}};
        {reply, L, PSt} ->
            St1 = St#state{protocol_state = PSt},
            ok = send(L, St1),
            {ok, St1};
        {stop, PSt} ->
            {stop, St#state{protocol_state = PSt}};
        {stop, L, PSt} ->
            St1 = St#state{protocol_state = PSt},
            ok = send(L, St1),
            {stop, St1}
    end.



handle_outbound(M, St0) ->
    case bondy_wamp_protocol:handle_outbound(M, St0#state.protocol_state) of
        {ok, Bin, PSt} ->
            St1 = St0#state{protocol_state = PSt},
            ok = send(Bin, St1),
            {noreply, St1, ?TIMEOUT};
        {stop, PSt} ->
            {stop, normal, St0#state{protocol_state = PSt}};
        {stop, Bin, PSt} ->
            ok = send(Bin, St0#state{protocol_state = PSt}),
            {stop, normal, St0#state{protocol_state = PSt}}
    end.


%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
handle_handshake(Len, Enc, St) ->
    try
        init_wamp(Len, Enc, St)
    catch
        throw:Reason ->
            ok = send_frame(error_number(Reason), St),
            _ = lager:info("TCP Connection closing, reason=~p", [Reason]),
            {stop, St}
    end.


%% @private
init_wamp(Len, Enc, St0) ->
    case inet:peername(St0#state.socket) of
        {ok, {_, _} = Peer} ->
            MaxLen = validate_max_len(Len),
            {FrameType, EncName} = validate_encoding(Enc),

            Proto = {raw, FrameType, EncName},
            case bondy_wamp_protocol:init(Proto, Peer, #{}) of
                {ok, CBState} ->
                    St1 = St0#state{
                        frame_type = FrameType,
                        protocol_state = CBState,
                        max_len = MaxLen
                    },
                    ok = send_frame(
                        <<?RAW_MAGIC, Len:4, Enc:4, 0:8, 0:8>>, St1),
                    _ = lager:info(
                        <<"Established connection with peer, transport=raw, frame_type=~p, encoding=~p, peer='~p'">>,
                        [FrameType, EncName, Peer]
                    ),
                    {ok, St1};
                {error, Reason} ->
                    {error, Reason, St0}
            end;
        {ok, Peer} ->
            _ = lager:error("Unexpected peername, result=~p", [Peer]),
            {error, invalid_socket, St0};
        {error, Reason} ->
            _ = lager:error("Invalid peername, error=~p", [Reason]),
            {error, invalid_socket, St0}
    end.


%% -----------------------------------------------------------------------------
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
    math:pow(2, 9 + N);

validate_max_len(_) ->
    %% TODO define correct error return
    throw(maximum_message_length_unacceptable).


%% 0: illegal
%% 1: JSON
%% 2: MessagePack
%% 3 - 15: reserved for future serializers
validate_encoding(1) -> {binary, json};
validate_encoding(2) -> {binary, msgpack};
% validate_encoding(3) -> cbor;
validate_encoding(4) -> {binary, bert};
validate_encoding(15) -> {binary, erl};
validate_encoding(_) ->
    %% TODO define correct error return
    throw(serializer_unsupported).


%% 0: illegal (must not be used)
%% 1: serializer unsupported
%% 2: maximum message length unacceptable
%% 3: use of reserved bits (unsupported feature)
%% 4: maximum connection count reached
%% 5 - 15: reserved for future errors
error_number(serializer_unsupported) ->?RAW_ERROR(1);
error_number(maximum_message_length_unacceptable) ->?RAW_ERROR(2);
error_number(use_of_reserved_bits) ->?RAW_ERROR(3);
error_number(maximum_connection_count_reached) ->?RAW_ERROR(4).


error_reason(1) -> serializer_unsupported;
error_reason(2) -> maximum_message_length_unacceptable;
error_reason(3) -> use_of_reserved_bits;
error_reason(4) -> maximum_connection_count_reached.

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

