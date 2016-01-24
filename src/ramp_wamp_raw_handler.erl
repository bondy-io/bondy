%% -----------------------------------------------------------------------------
%% @doc
%% A ranch handler for the wamp protocol over either tcp or tls transports.
%% @end
%% -----------------------------------------------------------------------------
-module(ramp_wamp_raw_handler).
-behaviour(ranch_protocol).

-record(state, {
    socket,
    transport
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
    Transport:setopts(Socket, [{packet,4}]),
    State = #state{
        socket = Socket,
        transport = Transport
    },
    loop(State).


loop(State = #state{socket = Socket, transport = Transport}) ->
    case Transport:recv(Socket, 0, 15000) of
        {ok, Data} ->
            ok = handle_data(Data, State),
            loop(State);
        _ ->
            ok = Transport:close(Socket)
    end.


-spec handle_data(Data :: binary(), State :: state()) ->
    ok |
    {error, atom()}.

handle_data(Data, #state{socket = Socket, transport = Transport}) ->
    Cmd = decode(Data),
    lager:debug("Bert Command: ~p", [Cmd]),
    Response = encode(handle_command(Cmd)),
    Transport:send(Socket, Response).


-spec handle_command(Cmd :: term()) ->
    {ok, Result :: term()} |
    {error, Reason :: term()}.

handle_command(ping) ->
    {ok, pong};

handle_command({F, Args} = Cmd)
when is_atom(F), is_list(Args) ->
    try
        apply(lsd_client, F, Args)
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
