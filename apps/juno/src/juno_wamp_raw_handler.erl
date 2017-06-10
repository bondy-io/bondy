%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% A ranch handler for the wamp protocol over either tcp or tls transports.
%% @end
%% =============================================================================
-module(juno_wamp_raw_handler).
-behaviour(gen_server).
-behaviour(ranch_protocol).
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").


-define(TIMEOUT, 60000*10).
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
-define(RAW_ERROR(Upper), <<?RAW_MAGIC:8, Upper:4, 0:4, 0:8, 0:8>>).
-define(RAW_FRAME(Bin), <<0:5, 0:3, (byte_size(Bin)):24, Bin/binary>>).

-record(state, {
    frame_type              ::  frame_type(),
    protocol_state          ::  juno_wamp_protocol:state() | undefined,
    socket                  ::  gen_tcp:socket(),
    transport               ::  module(),
    max_len                 ::  pos_integer(),
    ping_sent               ::  binary() | undefined,
    hibernate = false       ::  boolean()
}).
-type state() :: #state{}.

-export([start_link/4]).

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
%% @end
%% -----------------------------------------------------------------------------
start_link(Ref, Socket, Transport, Opts) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Socket, Transport, Opts}])}.



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
    io:format("Init ~p~n", [self()]),
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
            lager:info("TCP Connection closing, error=~p", [Reason]),
            {stop, reason, St1}
    end;

handle_info({?JUNO_PEER_CALL, Pid, M}, St) when Pid =:= self() ->
    handle_outbound(M, St);

handle_info({?JUNO_PEER_CALL, Pid, Ref, M}, St) ->
    %% Here we receive the messages that either the router or another peer
    %% sent to us using juno:send/2,3
    ok = juno:ack(Pid, Ref),
    handle_outbound(M, St);

handle_info({tcp_closed, _Socket}, State) ->
	{stop, normal, State};

handle_info({tcp_error, _, Reason}, State) ->
	{stop, Reason, State};

handle_info(timeout, State) ->
	{stop, normal, State};

handle_info(_Info, State) ->
	{stop, normal, State}.


handle_call(_Request, _From, State) ->
	{reply, ok, State}.


handle_cast(_Msg, State) ->
	{noreply, State}.


terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.







%% =============================================================================
%% PRIVATE
%% =============================================================================



-spec handle_data(Data :: binary(), State :: state()) ->
    {ok, state()} 
    | {stop, state()}
    | {error, any(), state()}.

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

handle_data(<<0:5, _:3, _:24, Data/binary>>, #state{max_len = Max} = St) 
when byte_size(Data) > Max->
    io:format("Message length is ~p~n", [byte_size(Data)]), 
    send_frame(error_response(maximum_message_length_unacceptable), St),
    {stop, St};

handle_data(<<0:5, 1:3, Len:24, Data/binary>>, St) ->
    %% We received a PING, send a PONG
    send_frame(<<0:5, 2:3, Len, Data>>, St),
    {ok, St};

handle_data(<<0:5, 2:3, _Len:24, Data/binary>>, St) ->
    %% We received a PONG
    case St#state.ping_sent of
        undefined ->
            %% We never sent this ping
            {ok, St};
        Data ->
            {ok, St#state{ping_sent = undefined}};
        _ ->
            %% Wrong answer
            {error, wrong_ping_answer, St}
    end;

handle_data(<<0:5, R:3, _Len:24, _Rest/binary>>, St) when R > 2 andalso R < 8 ->
    send_frame(error_response(use_of_reserved_bits), St),
    {stop, St};

handle_data(<<0:5, 0:3, _Len:24, Data/binary>>, St) ->
    case juno_wamp_protocol:handle_inbound(Data, St#state.protocol_state) of
        {ok, PSt} ->
            {ok, St#state{protocol_state = PSt}}; 
        {reply, L, PSt} ->
            St1 = St#state{protocol_state = PSt},
            send(L, St1),
            {ok, St1};
        {stop, PSt} ->
            {stop, St#state{protocol_state = PSt}};
        {stop, L, PSt} ->
            St1 = St#state{protocol_state = PSt},
            send(L, St1),
            {stop, St1}
    end.



handle_outbound(M, St0) ->
    case juno_wamp_protocol:handle_outbound(M, St0#state.protocol_state) of
        {ok, Bin, PSt} ->
            St1 = St0#state{protocol_state = PSt},
            send(Bin, St1),
            {noreply, St1, ?TIMEOUT};
        {stop, PSt} ->
            {stop, normal, St0#state{protocol_state = PSt}};
        {stop, Bin, PSt} ->
            send(Bin, St0#state{protocol_state = PSt}),
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
            send_frame(error_response(Reason), St),
            lager:info("TCP Connection closing, error=~p", [Reason]),
            {stop, St}
    end.


%% @private
init_wamp(Len, Enc, St0) ->
    case inet:peername(St0#state.socket) of
        {ok, {_, _} = Peer} ->
            MaxLen = validate_max_len(Len),
            {FrameType, EncName} = validate_encoding(Enc),
            case juno_wamp_protocol:init({ws, FrameType, EncName}, Peer, #{}) of
                {ok, CBState} ->
                    St1 = St0#state{
                        frame_type = FrameType,
                        protocol_state = CBState,
                        max_len = MaxLen
                    },
                    send_frame(<<?RAW_MAGIC, Len:4, Enc:4, 0:8, 0:8>>, St1),
                    {ok, St1};
                {error, Reason} ->
                    {error, Reason, St0}
            end;
        {ok, Peer} ->
            lager:info("Unexpected peername, result=~p", [Peer]),
            {error, invalid_socket, St0};
        {error, Reason} ->
            lager:info("Invalid peername, error=~p", [Reason]),
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
validate_encoding(1) -> {text, json};
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
error_response(serializer_unsupported) ->?RAW_ERROR(1);
error_response(maximum_message_length_unacceptable) ->?RAW_ERROR(2);
error_response(use_of_reserved_bits) ->?RAW_ERROR(3);
error_response(maximum_connection_count_reached) ->?RAW_ERROR(4).


%% @private
send(L, St) when is_list(L) ->
    lists:foreach(fun(Bin) -> send(Bin, St) end, L);

send(Bin, St) ->
    send_frame(?RAW_FRAME(Bin), St).





%% @private
send_frame(Frame, St) when is_binary(Frame) ->
    (St#state.transport):send(St#state.socket, Frame).