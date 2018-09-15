-module(bondy_session_worker).
-behaviour(gen_server).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(TIMEOUT, 20000).

-record(state, {
    session_id      ::  id(),
    peer            ::  bondy_wamp_peer:local(),
    monitor_ref     ::  reference(),
    protocol_state  ::  bondy_wamp_protocol:state() | undefined
}).

-type state()   ::  #state{}.

%% API
-export([start_link/2]).
-export([handle_incoming/3]).

%% GEN_SERVER CALLBACKS
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
start_link(SessionId, Peer) ->
    gen_server:start_link(
        {via, gproc, {n, l, SessionId}}, ?MODULE, {SessionId, Peer}, []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_incoming(pid() | id(), binary(), bondy_context:t()) ->
    ok.

handle_incoming(Server, Data, Ctxt) ->
    gen_server:cast(Server, {incoming, Data, Ctxt}).



%% =============================================================================
%% GEN SERVER CALLBACKS
%% =============================================================================



init({SessionId, Peer}) ->
    process_flag(trap_exit, true),
    St = #state{
        session_id = SessionId,
        peer = Peer
    },
    {ok, St}.


handle_call(Event, From, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p, from=~p", [Event, From]),
    {noreply, State}.


handle_cast({incoming, Data, Ctxt}, State) ->
    Subproto = bondy_context:subprotocol(Ctxt),
    try wamp_encoding:decode(Subproto, Data) of
        {[M], <<>>} -> bondy_router:forward(M, Ctxt)
    catch
        _:Reason ->
            lager:error("Error while decoding meesage; reason=~p", [Reason])
    end,
    {noreply, State};

handle_cast(Event, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p", [Event]),
    {noreply, State}.


handle_info({?BONDY_PEER_REQUEST, Pid, M}, St) when Pid =:= self() ->
    %% Here we receive a message from the bondy_router in those cases
    %% in which the router is embodied by our process i.e. the sync part
    %% of a routing process, so we do not ack
    handle_outbound(M, St);

handle_info({?BONDY_PEER_REQUEST, Pid, Ref, M}, St) ->
    %% Here we receive the messages that either the router or another peer
    %% have sent to us using bondy_wamp_peer:send/2,3 which requires us to ack
    %% its reception
    ok = bondy_wamp_peer:ack(Pid, Ref),
    %% We send the message to the peer
    handle_outbound(M, St);

handle_info(Info, State) ->
    _ = lager:debug("Unexpected message, message=~p", [Info]),
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.




%% =============================================================================
%% PRIVATE
%% =============================================================================


-spec handle_outbound(any(), state()) ->
    {noreply, state(), timeout()}
    | {stop, normal, state()}.

handle_outbound(_M, St0) ->
%%     case bondy_wamp_protocol:handle_outbound(M, St0#state.protocol_state) of
%%         {reply, Bin, PSt} ->
%%             St1 = St0#state{protocol_state = PSt},
%%             ok = send(Bin, St1),
%%             {noreply, St1, ?TIMEOUT};
%%         {stop, PSt} ->
%%             {stop, normal, St0#state{protocol_state = PSt}};
%%         {stop, Bin, PSt} ->
%%             ok = send(Bin, St0#state{protocol_state = PSt}),
%%             {stop, normal, St0#state{protocol_state = PSt}};
%%         {stop, Bin, PSt, Time} when is_integer(Time), Time > 0 ->
%%             %% We send ourselves a message to stop after Time
%%             erlang:send_after(
%%                 Time, self(), {stop, normal}),
%%             ok = send(Bin, St0#state{protocol_state = PSt}),
%%             {noreply, St0#state{protocol_state = PSt}}
%%     end.
    {noreply, St0}.