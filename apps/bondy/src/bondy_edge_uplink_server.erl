-module(bondy_edge_uplink_server).
-behaviour(gen_statem).
-behaviour(ranch_protocol).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy.hrl").

-define(TIMEOUT, 30000).

-define(SOCKET_DATA(Tag), Tag == tcp orelse Tag == ssl).
-define(SOCKET_ERROR(Tag), Tag == tcp_error orelse Tag == ssl_error).
-define(CLOSED_TAG(Tag), Tag == tcp_closed orelse Tag == ssl_closed).
% -define(PASSIVE_TAG(Tag), Tag == tcp_passive orelse Tag == ssl_passive).


-record(state, {
    ref                     ::  atom(),
    transport               ::  module(),
    socket                  ::  gen_tcp:socket() | ssl:sslsocket()
}).

% -type t()                   ::  #state{}.

%% API.
-export([start_link/3]).
-export([start_link/4]).

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
start_link(Ref, Transport, Opts) ->
	gen_statem:start_link(?MODULE, {Ref, Transport, Opts}, []).


%% -----------------------------------------------------------------------------
%% @doc
%% This will be deprecated with Ranch 2.0
%% @end
%% -----------------------------------------------------------------------------
start_link(Ref, _, Transport, Opts) ->
    start_link(Ref, Transport, Opts).



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
init({Ref, Transport, _Opts = []}) ->
    State = #state{ref = Ref, transport = Transport},
	{ok, connected, State, ?TIMEOUT}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
terminate(Reason, StateName, #state{transport = T, socket = S} = State)
when T =/= undefined andalso S =/= undefined ->
    ?LOG_INFO(#{
        description => "Closing connection",
        reason => Reason
    }),
    catch T:close(S),
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
    Ref = State#state.ref,
    Transport = State#state.transport,

    Opts = [
        binary,
        {packet, 4},
        {active, once}
        | bondy_config:get([Ref, socket_opts], [])
    ],

    {ok, Socket} = ranch:handshake(Ref),

	ok = Transport:setopts(Socket, Opts),

    {keep_state, State#state{socket = Socket}};

connected(info, {Tag, Socket, Data}, #state{socket = Socket} = State)
when ?SOCKET_DATA(Tag) ->
    Transport = State#state.transport,
	Transport:setopts(Socket, [{active, once}]),
	handle_message(binary_to_term(Data), State),
	{keep_state_and_data, ?TIMEOUT};

connected(info, {Tag, _Socket}, _) when ?CLOSED_TAG(Tag) ->
	{stop, normal};

connected(info, {Tag, _, Reason}, _) when ?SOCKET_ERROR(Tag) ->
	{stop, Reason};

connected(info, Msg, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => info,
        event => Msg
    }),
	keep_state_and_data;

connected({call, From}, Request, _) ->
    ?LOG_INFO(#{
        description => "Received unknown request",
        type => call,
        event => Request
    }),
	gen_statem:reply(From, {error, badcall}),
	keep_state_and_data;

connected(cast, Msg, _) ->
    ?LOG_INFO(#{
        description => "Received unknown message",
        type => cast,
        event => Msg
    }),
	keep_state_and_data;

connected(timeout, _Msg, _) ->
    ?LOG_INFO(#{
        description => "Closing connection",
        reason => timeout
    }),
	{stop, normal};

connected(_EventType, _Msg, _) ->
	{stop, normal}.



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% {hello, Node, Details}
%% - {challenge, Method, Extra}
%% {authenticate, Signature, Extra}
%% - {welcome, Details}
%% - {abort, Details}
%% {join, Realm, Details}
handle_message(_, #state{} = _State) ->
    ok.


on_close(_Reason, _State) ->
    ok.
