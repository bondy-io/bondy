%% =============================================================================
%%  bondy_peer_discovery_agent.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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

%% -----------------------------------------------------------------------------
%% @doc This state machine is reponsible for discovering Bondy cluster peers
%% using the defined implementation backend (callback module).
%%
%% Its behaviour can be configured using the `cluster.peer_discovery' family of
%% `bondy.conf' options.
%%
%% If the agent is enabled (`cluster.peer_discovery.enabled') and the Bondy node
%%  has not yet joined a cluster, it will lookup for peers using the
%% defined implementation backend callback module
%%  (`cluster.peer_discovery.type').
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_peer_discovery_agent).
-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    enabled                 ::  boolean(),
    automatic_join          ::  boolean(),
    callback_mod            ::  module(),
    callback_config         ::  map(),
    callback_state          ::  any(),
    initial_delay           ::  integer(),
    polling_interval        ::  integer(),
    timeout                 ::  integer(),
    join_retry_interval     ::  integer(),
    peers = []              ::  [bondy_peer_service:peer()]
}).


%% API
-export([start/0]).
-export([start_link/0]).
-export([lookup/0]).
-export([enable/0]).
-export([disable/0]).

%% gen_statem callbacks
-export([init/1]).
-export([callback_mode/0]).
-export([terminate/3]).
-export([code_change/4]).

%% gen_statem states
-export([discovering/3]).
-export([joined/3]).
-export([disabled/3]).
-export([format_status/2]).



%% =============================================================================
%% CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% Initializes the peer discovery agent implementation
%% -----------------------------------------------------------------------------
-callback init(Opts :: map()) ->
    {ok, State :: any()}
    | {error, Reason ::  any()}.


%% -----------------------------------------------------------------------------
%%
%% -----------------------------------------------------------------------------
-callback lookup(State :: any(), Timeout :: timeout()) ->
    {ok, [bondy_peer_service:peer()], NewState :: any()}
    | {error, Reason :: any(), NewState :: any()}.



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start() ->
    {ok, pid()} | ignore | {error, term()}.

start() ->
    gen_statem:start({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_link() ->
    {ok, pid()} | ignore | {error, term()}.

start_link() ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
lookup() ->
    gen_statem:call(?MODULE, lookup).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec enable() -> boolean().

enable() ->
    gen_statem:call(?MODULE, enable).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec disable() -> boolean().

disable() ->
    gen_statem:call(?MODULE, disable).




%% =============================================================================
%% GEN_STATEM CALLBACKS
%% =============================================================================



init([]) ->
    Opts = maps:from_list(bondy_config:get(peer_discovery)),
    State = #state{
        enabled = maps:get(enabled, Opts),
        automatic_join = maps:get(automatic_join, Opts),
        callback_mod = maps:get(type, Opts),
        callback_config = maps:from_list(maps:get(config, Opts, [])),
        polling_interval = maps:get(polling_interval, Opts),
        initial_delay = maps:get(initial_delay, Opts),
        join_retry_interval = maps:get(join_retry_interval, Opts),
        timeout = maps:get(timeout, Opts)
    },
    case State#state.enabled of
        true ->
            do_init(State);
        false ->
            {ok, disabled, State}
    end.


callback_mode() ->
    state_functions.


terminate(_Reason, _StateName, _State) ->
    ok.


code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.


format_status(_Opts, [_PDict, StateName, State]) ->
    #{
        state => StateName,
        enabled => State#state.enabled,
        automatic_join => State#state.automatic_join,
        type => State#state.callback_mod,
        config => State#state.callback_config,
        data => State#state.callback_state,
        polling_interval => State#state.polling_interval,
        timeout => State#state.timeout,
        peers => State#state.peers
    }.



%% =============================================================================
%% STATE FUNCTIONS
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc In this state the agent uses the callback module to discover peers
%% by calling its lookup/2 callback.
%% @end
%% -----------------------------------------------------------------------------
discovering(cast, joined, State) ->
    %% We joined the cluster (manually or because we crashed and another peer
    %% remembered us, or other peer wants to join us.
    {next_state, joined, State};


discovering({call, From}, disable, State) ->
    ok = gen_statem:reply(From, ok),
    {next_state, disabled, State};

discovering(state_timeout, lookup, State) ->
    %% This is to instrument polling intervals.
    {keep_state, State, [{next_event, internal, lookup}]};

discovering(internal, lookup, State) ->
    CBMod = State#state.callback_mod,
    CBState = State#state.callback_state,
    Timeout = State#state.timeout,

    {ok, Members} = bondy_peer_service:members(),
    case length(Members) == 1 of
        true ->
            %% Not in cluster
            Res = CBMod:lookup(CBState, Timeout),
            ?LOG_DEBUG(#{
                description => "Got lookup response",
                callback_mod => CBMod,
                response => Res
            }),
            maybe_join(Res, State);
        false ->
            %% We have already joined the cluster
            {next_state, joined, State}
    end;

discovering(EventType, EventContent, State) ->
    handle_event(EventType, EventContent, State).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
joined(cast, left, State) ->
    ?LOG_NOTICE(#{
        description => "Received cluster leave event, disabling automatic join."
    }),
    {next_state, disabled, State};

joined(EventType, EventContent, State) ->
    handle_event(EventType, EventContent, State).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
disabled({call, From}, enable, State) ->
    ok = gen_statem:reply(From, true),
    {next_state, discovering, State, [{next_event, internal, next}]};

disabled(EventType, EventContent, State) ->
    handle_event(EventType, EventContent, State).



%% =============================================================================
%% PRIVATE
%% =============================================================================


do_init(State) ->
    case (State#state.callback_mod):init(State#state.callback_config) of
        {ok, CBState} ->
            Delay = State#state.initial_delay,

            Action = case Delay > 0 of
                false ->
                    {next_event, internal, lookup};
                true ->
                    ?LOG_INFO(#{
                        description => "Peer discovery agent will start after initial delay",
                        delay_msecs => Delay
                    }),
                    {state_timeout, Delay, lookup, []}
            end,

            NewState = State#state{callback_state = CBState},

            {ok, discovering, NewState, [Action]};

        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Peer discovery agent could not start due to misconfiguration",
                reason => Reason
            }),
            {error, Reason, State}
    end.


%% @private
maybe_join({ok, Peers, CBState}, #state{automatic_join = true} = State) ->
    NewState = State#state{peers = Peers, callback_state = CBState},
    do_maybe_join(lists_utils:shuffle(Peers), NewState);

maybe_join({ok, Peers, CBState}, #state{automatic_join = false} = State) ->
    NewState = State#state{peers = Peers, callback_state = CBState},
    schedule_lookup_action(NewState);

maybe_join({error, _, CBState}, State) ->
    NewState = State#state{callback_state = CBState},
    schedule_lookup_action(NewState).


%% @private
do_maybe_join([], State) ->
    schedule_lookup_action(State);

do_maybe_join([H|T], State) ->
    try bondy_peer_service:join(H) of
        ok ->
            {next_state, joined, State};
        {error, _} ->
            do_maybe_join(T, State)
    catch
        Class:_ ->
            ?LOG_ERROR(#{
                description => "Could not join peer, the node might be down or not reachable",
                peer => H,
                class => Class
            }),
            do_maybe_join(T, State)
    end.


%% @private
schedule_lookup_action(State) ->
    Action = {state_timeout, State#state.polling_interval, lookup, []},
    {next_state, discovering, State, [Action]}.


%% @private
handle_event(cast, joined, State) ->
    {next_state, joined, State};

handle_event({call, From}, disable, State) ->
    {next_state, disabled, State, [{reply, From, ok}]};

handle_event(_, _, State) ->
    {keep_state, State}.
