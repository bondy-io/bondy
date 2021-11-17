-module(bondy_edge_uplink_client).
-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy.hrl").

-define(TIMEOUT, 5000).

-define(SOCKET_DATA(Tag), Tag == tcp orelse Tag == ssl).
-define(SOCKET_ERROR(Tag), Tag == tcp_error orelse Tag == ssl_error).
-define(CLOSED_TAG(Tag), Tag == tcp_closed orelse Tag == ssl_closed).
% -define(PASSIVE_TAG(Tag), Tag == tcp_passive orelse Tag == ssl_passive).


-record(state, {
    transport               ::  gen_tcp | ssl,
    socket                  ::  gen_tcp:socket() | ssl:sslsocket(),
    max_retries             ::  integer(),
    retry_count = 0         ::  integer(),
    backoff                 ::  maybe(backoff:backoff())
}).

-type t()                   ::  #state{}.


%% API.
-export([start_link/3]).

%% GEN_STATEM CALLBACKS
-export([callback_mode/0]).
-export([init/1]).
-export([terminate/3]).
-export([code_change/4]).

%% STATE FUNCTIONS
-export([connected/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link(Transport, Endpoint, Opts) ->
	gen_statem:start_link(?MODULE, {Transport, Endpoint, Opts}, []).



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
init({Transport0, Endpoint, Opts}) ->
    TransportMod = transport_mod(Transport0),

    ok = bondy_logger_utils:set_process_metadata(#{
        transport => TransportMod,
        endpoint => Endpoint
    }),

    case connect(TransportMod, Endpoint, Opts) of
        {ok, Socket} ->
            Retries = key_value:get([reconnect, max_retries], Opts),

            State0 = #state{
                transport = TransportMod,
                socket = Socket,
                max_retries = Retries
            },
            ReconnectOpts = key_value:get(reconnect, Opts),
            State = maybe_init_backoff(ReconnectOpts, State0),

            {ok, connected, State};
        Error ->
            ?LOG_ERROR(#{
                description => "Failed to establish uplink with remote router",
                reason => Error
            }),
            {stop, normal}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec terminate(term(), atom(), t()) -> term().

terminate(Reason, StateName, #state{transport = T, socket = S} = State)
when T =/= undefined andalso S =/= undefined ->
    catch T:close(S),

    ?LOG_ERROR(#{
        description => "Connection terminated",
        reason => Reason
    }),

    ok = on_close(Reason, State),
    NewState = State#state{transport = undefined, socket = undefined},

    terminate(Reason, StateName, NewState);

terminate(_Reason, _StateName, _StateData) ->
	ok.


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
connected(enter, connected, State) ->
    {keep_state, State};

connected(info, {Tag, Socket, _Data}, #state{socket = Socket} = State)
when ?SOCKET_DATA(Tag) ->
    Transport = State#state.transport,
	Transport:setopts(Socket, [{active, once}]),
	% handle_message(binary_to_term(Data), State),
	{keep_state_and_data, ?TIMEOUT};

connected(info, {Tag, _Socket}, _) when ?CLOSED_TAG(Tag) ->
	{stop, normal};

connected(info, {Tag, _, Reason}, _) when ?SOCKET_ERROR(Tag) ->
	{stop, Reason};

connected(info, Msg, _) ->
    ?LOG_DEBUG(#{
        description => "Received unknown message",
        type => info,
        event => Msg
    }),
	keep_state_and_data;

connected({call, From}, Request, _) ->
    ?LOG_DEBUG(#{
        description => "Received unknown request",
        type => call,
        event => Request
    }),
	gen_statem:reply(From, {error, badcall}),
	keep_state_and_data;

connected(cast, Msg, _) ->
    ?LOG_DEBUG(#{
        description => "Received unknown message",
        type => cast,
        event => Msg
    }),
	keep_state_and_data;

connected(timeout, _Msg, _) ->
	{stop, normal};

connected(_EventType, _Msg, _) ->
	{stop, normal}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



maybe_init_backoff(Opts, State) ->
    case key_value:get(enabled, Opts) of
        true ->
            Min = key_value:get(backoff_min, Opts, 10),
            Max = key_value:get(backoff_max, Opts, 120000),
            Type = key_value:get(backoff_type, Opts, jitter),
            Backoff = backoff:type(backoff:init(Min, Max), Type),
            State#state{backoff = Backoff};
        false ->
            undefined
    end.

connect(Transport, {Host, Port}, Opts) ->
    Timeout = key_value:get(timeout, Opts, 5000),
    SocketOpts = bondy_config:get([edge, uplink, socket_opts], []),
    TransportOpts = [
        binary,
        {packet, 4},
        {active, once}
        | SocketOpts
    ],

    case Transport:connect(Host, Port, TransportOpts, Timeout) of
        {ok, _Socket} = OK ->
            OK;
        {error, _} = Error ->
            Error
    end.



on_close(_Reason, _State) ->
    ok.


transport_mod(tcp) -> gen_tcp;
transport_mod(tls) -> ssl.