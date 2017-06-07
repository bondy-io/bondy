%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% A ranch handler for the wamp protocol over either tcp or tls transports.
%% @end
%% =============================================================================
-module(juno_wamp_raw_handler).
-behaviour(ranch_protocol).

-define(MAGIC, 16#7F).
-define(TIMEOUT, 5000).

%% 0: illegal (must not be used)
%% 1: serializer unsupported
%% 2: maximum message length unacceptable
%% 3: use of reserved bits (unsupported feature)
%% 4: maximum connection count reached
%% 5 - 15: reserved for future errors
-define(ERROR(Upper), <<?MAGIC:8, Upper:4, 0:4, 0:8, 0:8>>).

-type encoding()    ::  json | msgpack | bert.

-record(state, {
    socket          ::  gen_tcp:socket(),
    transport       ::  module(),
    encoding        ::  encoding(),
    maxlen          ::  integer(),
    buffer          ::  binary()
}).
-type state() :: #state{}.

-export([start_link/4]).
-export([init/4]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link(Ref, Socket, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
    {ok, Pid}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



init(Ref, Socket, Transport, _Opts) ->
    %% We must call ranch:accept_ack/1 before doing any socket operation. 
    %% This will ensure the connection process is the owner of the socket. 
    %% It expects the listener’s name as argument.
    ok = ranch:accept_ack(Ref),
    Transport:setopts(Socket, [{packet, 4}]),
    State = #state{
        socket = Socket,
        transport = Transport
    },
    loop(State).


loop(State = #state{socket = Socket, transport = Transport}) ->
    case Transport:recv(Socket, 0, ?TIMEOUT) of
        {ok, Data} ->
            % TODO handle errors
            ok = handle_data(Data, State),
            loop(State);
        _ ->
            ok = Transport:close(Socket)
    end.


-spec handle_data(Data :: binary(), State :: state()) ->
    ok | {error, atom()}.

handle_data(
    <<?MAGIC:8, Len:4, Encoding:4, _:8, _:8>>,
    #state{encoding = undefined} = State) ->
    handle_handshake(Len, Encoding, State);

handle_data(_Data, #state{encoding = undefined} = State) ->
    %% After a _Client_ has connected to a _Router_, the _Router_ will 
    %% first receive the 4 octets handshake request from the _Client_.
    %% If the _first octet_ differs from "0x7F", it is not a WAMP-over- 
    %% RawSocket request. Unless the _Router_ also supports other 
    %% transports on the connecting port (such as WebSocket), the 
    %% _Router_ MUST *fail the connection*.
    %% TODO define correct return value
    {error, foo, State};

handle_data(Data, #state{socket = Socket, transport = Transport}) ->
    Cmd = decode(Data),
    Response = encode(handle_message(Cmd)),
    Transport:send(Socket, Response).


%% @private
handle_handshake(Len, Encoding, State) ->
    try
        validate_max_length(Len),
        Key = validate_encoding(Encoding),
        Response = <<?MAGIC, Len:4, Encoding:4, 0:8, 0:8>>,
        (State#state.transport):send(State#state.socket, Response),
        {ok, State#state{encoding = Key, maxlen = Len}}
    catch
        throw:Reason ->
            Error = error_response(Reason),
            (State#state.transport):send(State#state.socket, Error),
            {stop, State}
    end.



-spec handle_message(Cmd :: term()) ->
    {ok, Result :: term()} |
    {error, Reason :: term()}.

handle_message(ping) ->
    {ok, pong};

handle_message({F, Args} = Cmd)
when is_atom(F), is_list(Args) ->
    try
        apply(juno, F, Args)
    catch
        _:Reason ->
            lager:debug("Reason ~p", [Reason]),
            {error, {unknown_command, Cmd}}
    end;

handle_message(Cmd) ->
    {error, {unknown_command, Cmd}}.

%% @private
decode(Data) ->
    bert:decode(Data).

%% @private
encode(Term) ->
    bert:encode(Term).


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
validate_max_length(N) when N >= 0, N =< 15 ->
    ok;

validate_max_length(_) ->
    %% TODO define correct error return
    throw(maximum_message_length_unacceptable).


%% 0: illegal
%% 1: JSON
%% 2: MessagePack
%% 3 - 15: reserved for future serializers
validate_encoding(1) -> json;
validate_encoding(2) -> msgpack;
validate_encoding(3) -> bert;
validate_encoding(_) ->
    %% TODO define correct error return
    throw(serializer_unsupported).


%% 0: illegal (must not be used)
%% 1: serializer unsupported
%% 2: maximum message length unacceptable
%% 3: use of reserved bits (unsupported feature)
%% 4: maximum connection count reached
%% 5 - 15: reserved for future errors
error_response(serializer_unsupported) ->?ERROR(1);
error_response(maximum_message_length_unacceptable) ->?ERROR(2);
error_response(use_of_reserved_bits) ->?ERROR(3);
error_response(maximum_connection_count_reached) ->?ERROR(4).