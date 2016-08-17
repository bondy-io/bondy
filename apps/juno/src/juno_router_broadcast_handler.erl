%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2016. All rights reserved.
%% =============================================================================


-module(juno_router_broadcast_handler).
-behaviour(plumtree_broadcast_handler).
-behaviour(gen_server).
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

-record(state, {
    %% identifier used in logical clocks
    serverid   :: term(),
    %% an ets table to hold iterators opened
    %% by other nodes
    iterators  :: ets:tab()
}).
% -type state() :: #state{}.

-record(juno_event, {
    key        ::  {uri(), id(), id()},
    message     ::  message() 
}).
-type juno_event() :: #juno_event{}.


-define(TIMEOUT, 60000).
-define(POOL_NAME, juno_router_broadcast_handler_pool).
-define(JUNO_EVENT(RealmUri, SessionId, Id, M), #juno_event{
    key = {RealmUri, SessionId, Id},
    message = M
}).


%% API
-export([start_pool/0]).

%% PLUMTREE_BROADCAST_HANDLER CALLBACKS
-export([broadcast_data/1]).
-export([exchange/1]).
-export([graft/1]).
-export([is_stale/1]).
-export([merge/2]).

%% SIDEJOB WORKER GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).





%% =============================================================================
%% API
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_pool() -> ok.
start_pool() ->
    case do_start_pool() of
        {ok, _Child} -> ok;
        {ok, _Child, _Info} -> ok;
        {error, already_present} -> ok;
        {error, {already_started, _Child}} -> ok;
        {error, Reason} -> error(Reason)
    end.



%% =============================================================================
%% PLUMTREE_BROADCAST_HANDLER CALLBACKS
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% Return a two-tuple of message id and payload from a given broadcast
%% @end
%% -----------------------------------------------------------------------------
-spec broadcast_data(juno_event()) -> {any(), any()}.
broadcast_data(#juno_event{} = E) ->
    io:format("I've got ~p~n", [E]),
    {E#juno_event.key, E#juno_event.message}.


%% -----------------------------------------------------------------------------
%% @doc
%% Given the message id and payload, merge the message in the local state.
%% If the message has already been received return `false', otherwise 
%% return `true'
%% @end
%% -----------------------------------------------------------------------------
-spec merge(any(), any()) -> boolean().
merge(A, B) -> 
    % @TODO
    io:format("I've got ~p and ~p~n", [A, B]),
    true.


%% -----------------------------------------------------------------------------
%% @doc
%% Return true if the message (given the message id) has already been received.
%% `false' otherwise
%% @end
%% -----------------------------------------------------------------------------
-spec is_stale(any()) -> boolean().
is_stale({Id, Clock}) ->
    % @TODO
    call({is_stale, Id, Clock}).


%% -----------------------------------------------------------------------------
%% @doc
%% Return the message associated with the given message id. 
%% In some cases a message has already been sent with information that subsumes 
%% the message associated with the given message id. 
%% In this case, `stale' is returned.
%% @end
%% -----------------------------------------------------------------------------
-spec graft(any()) -> stale | {ok, any()} | {error, any()}.
graft({_Key, _Clock}) ->
    %% TODO
    stale.


%% -----------------------------------------------------------------------------
%% @doc
%% Trigger an exchange between the local handler and the handler on the given 
%% node. How the exchange is performed is not defined but it should be 
%% performed as a background process and ensure that it delivers any messages 
%% missing on either the local or remote node.
%% The exchange does not need to account for messages in-flight when it is 
%% started or broadcast during its operation. 
%% These can be taken care of in future exchanges.
%% @end
%% -----------------------------------------------------------------------------
-spec exchange(node()) -> {ok, pid()} | {error, term()}.
exchange(_Peer) ->
    % Timeout = app_helper:get_env(juno, data_exchange_timeout, 60000),
    % case juno_data_exchange_coordinator:start(Peer, Timeout) of
    %     {ok, Pid} ->
    %         {ok, Pid};
    %     {error, Reason} ->
    %         {error, Reason};
    %     ignore ->
    %         {error, ignore}
    % end.
    %% TODO
    {error, ignore}.



%% =============================================================================
%% SIDEJOB WORKER GEN_SERVER CALLBACKS
%% =============================================================================


init([?POOL_NAME]) ->
    %% We've been called by sidejob_worker
    {ok, #state{}}.


handle_call(Event, _From, State) ->
    lager:debug("Unhandled call ~p", [Event]),
    {noreply, State}.


handle_cast(Event, State) ->
   try
        %% your handling of event here ...
        {noreply, State}
    catch
        throw:abort ->
            {noreply, State};
        Class:Reason ->
            lager:debug(
                "Error while handling cast ~p (~p) ~p", [Event, Class, Reason]),
            {noreply, State}
    end.


handle_info(_Info, State) ->
    {noreply, State}.


terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Actually starts a sidejob pool based on system configuration.
%% @end
%% -----------------------------------------------------------------------------
do_start_pool() ->
    Size = erlang:max(
        juno_config:pool_size(?POOL_NAME), tuplespace:ring_size()),
    Capacity = juno_config:pool_capacity(?POOL_NAME),
    %% Always a permanent pool
    sidejob:new_resource(?POOL_NAME, ?MODULE, Capacity, Size).



call(M) ->
    call(M, ?TIMEOUT).

%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Helper function for {@link async_route_event/2}
%% @end
%% -----------------------------------------------------------------------------
call(M, Timeout) ->
    %% We send a request to an existing permanent worker
    %% using juno_router_broadcast_handler acting as a sidejob_worker
    sidejob:call(?POOL_NAME, M, Timeout).

% cast(M) ->
%     %% We send a request to an existing permanent worker
%     %% using juno_router_broadcast_handler acting as a sidejob_worker
%     sidejob:cast(?POOL_NAME, M).

