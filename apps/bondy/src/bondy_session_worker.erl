-module(bondy_session_worker).
-behaviour(gen_server).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(TIMEOUT, 20000).
-define(NAME(Id), {n, l, Id}).
-define(REF(Id), {via, gproc, ?NAME(Id)}).

-record(state, {
    session_id      ::  id(),
    peer            ::  bondy_wamp_peer:local(),
    monitor_ref     ::  reference(),
    protocol_state  ::  bondy_wamp_protocol:state() | undefined
}).


%% API
-export([start_link/2]).
-export([handle_incoming/3]).
-export([async_send/2]).
-export([send/2]).

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
    gen_server:start_link(?REF(SessionId), ?MODULE, {SessionId, Peer}, []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_incoming(pid() | id(), binary(), bondy_context:t()) ->
    ok.

handle_incoming(SessionId, Data, Ctxt) when is_integer(SessionId) ->
    handle_incoming(?REF(SessionId), Data, Ctxt);

handle_incoming(Server, Data, Ctxt) ->
    gen_server:cast(Server, {incoming, Data, Ctxt}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec async_send(pid() | id(), binary()) ->
    ok.

async_send(SessionId, Data) when is_integer(SessionId) ->
    async_send(?REF(SessionId), Data);

async_send(Server, Data) ->
    gen_server:cast(Server, {send, Data}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec send(pid() | id(), binary()) ->
    ok | {error, any()}.

send(SessionId, Data) when is_integer(SessionId) ->
    send(?REF(SessionId), Data);

send(Server, Data) ->
    gen_server:call(Server, {send, Data}).



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


handle_call({send, Data}, _From, State) ->
    Reply = do_send(Data, State),
    {reply, Reply, State};

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

handle_cast({async_send, Data, _Ctxt}, State) ->
    _ = do_send(Data, State),
    {noreply, State};

handle_cast(Event, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p", [Event]),
    {noreply, State}.


%% handle_info({?BONDY_PEER_REQUEST, Pid, M}, St) when Pid =:= self() ->
%%     %% Here we receive a message from the bondy_router in those cases
%%     %% in which the router is embodied by our process i.e. the sync part
%%     %% of a routing process, so we do not ack
%%     handle_outbound(M, St);

%% handle_info({?BONDY_PEER_REQUEST, Pid, Ref, M}, St) ->
%%     %% Here we receive the messages that either the router or another peer
%%     %% have sent to us using bondy_wamp_peer:send/2,3 which requires us to ack
%%     %% its reception
%%     ok = bondy_wamp_peer:ack(Pid, Ref),
%%     %% We send the message to the peer
%%     handle_outbound(M, St);

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



%% @private
do_send(Data, State) when is_binary(Data) ->
    Peer = State#state.peer,
    Socket = bondy_wamp_peer:socket(Peer),

    %% Mod = bondy_wamp_peer:transport_mod(Peer),
    %% case Mod:send(Socket, ?RAW_FRAME(Data)) of
    %%     ok ->
    %%         ok;
    %%     {error, _} = Error ->
    %%         Error
    %% end.

    try
        case erlang:port_command(Socket, ?RAW_FRAME(Data), [nosuspend]) of
            false ->
                %% Port busy and nosuspend option passed
                throw(busy);
            true ->
                receive
                    {inet_reply, Socket, ok} ->
                        ok;
                    {inet_reply, Socket, Status} ->
                        throw(Status)
                end
        end
    catch
        _:Reason ->
            {error, Reason}
    end.