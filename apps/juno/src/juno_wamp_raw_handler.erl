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
-define(RESERVED, 0). %% Todo all ceros

-type encoding()    ::  json | msgpack | bert.

-record(state, {
    socket,
    transport,
    encoding    :: encoding(),
    maxlen  :: integer()
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
    ok = ranch:accept_ack(Ref),
    Transport:setopts(Socket, [{packet, 4}]),
    State = #state{
        socket = Socket,
        transport = Transport
    },
    loop(State).


loop(State = #state{socket = Socket, transport = Transport}) ->
    case Transport:recv(Socket, 0, 15000) of
        {ok, Data} ->
            % TODO handle errors
            ok = handle_data(Data, State),
            loop(State);
        _ ->
            ok = Transport:close(Socket)
    end.


-spec handle_data(Data :: binary(), State :: state()) ->
    ok |
    {error, atom()}.

handle_data(
    <<?MAGIC:8/integer, Len:4/integer, Encoding:4/integer, _:8, _:8>>,
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
    Response = encode(handle_command(Cmd)),
    Transport:send(Socket, Response).


%% @private
handle_handshake(Len, Encoding, State) ->
    validate_length(Len),
    Key = encoding(Encoding),
    Response = <<?MAGIC, Len:4/integer, Encoding:4/integer, ?RESERVED:8, ?RESERVED:8>>,
    (State#state.transport):send(State#state.socket, Response),
    {ok, State#state{encoding = Key, maxlen = Len}}.



-spec handle_command(Cmd :: term()) ->
    {ok, Result :: term()} |
    {error, Reason :: term()}.

handle_command(ping) ->
    {ok, pong};

handle_command({F, Args} = Cmd)
when is_atom(F), is_list(Args) ->
    try
        apply(juno, F, Args)
    catch
        _:Reason ->
            lager:debug("Reason ~p", [Reason]),
            {error, {unknown_command, Cmd}}
    end;

handle_command(Cmd) ->
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
%% This means a _Client_ can choose the maximum message length between *512* and *16M* octets.
%% @end
%% -----------------------------------------------------------------------------
validate_length(N) when N >= 0, N =< 15 ->
    ok;
validate_length(_) ->
    %% TODO define correct error return
    error({invalid_length}).


encoding(1) -> json;
encoding(2) -> msgpack;
encoding(3) -> bert;
encoding(_) ->
    %% TODO define correct error return
    error({illegal_serializer}).
