%% =============================================================================
%%  bondy_peer_discovery_static_agent.erl -
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
%% @doc An implementation of the {@link bondy_peer_discovery_agent} behaviour
%% that uses a static list of node names for service discovery.
%%
%% It is enabled by using the following options in the bondy.conf file
%%
%% ```bash
%% cluster.peer_discovery_agent.type = bondy_peer_discovery_static_agent
%% cluster.peer_discovery_agent.config.seed = HOSTNAME
%% '''
%% Where HOSTNAME is the name of a bondy node.
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_peer_discovery_static_agent).
-behaviour(bondy_peer_discovery_agent).

-include_lib("kernel/include/logger.hrl").

-define(OPTS_SPEC, #{
    <<"nodes">> => #{
        key => nodes,
        alias => <<"nodes">>,
        required => true,
        datatype => {list, binary},
        validator => fun
            (L) when is_list(L) ->
                {ok, [binary_to_atom(Node, utf8) || Node <- L]}
        end
    }
}).

-record(state, {
    peers = []  :: [bondy_peer_service:peer()]
}).

-export([init/1]).
-export([lookup/2]).



%% =============================================================================
%% AGENT CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(Opts :: map()) -> {ok, State :: any()} | {error, Reason ::  any()}.

init(Opts) ->
    try
        #{nodes := All} = maps_utils:validate(Opts, ?OPTS_SPEC),
        Myself = bondy_config:node(),

        State = #state{
            peers = [Node || Node <- All, Node =/= Myself]
        },
        {ok, State}

    catch
        _:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(State :: any(), timeout()) ->
    {ok, [bondy_peer_service:peer()], NewState :: any()}
    | {error, Reason :: any(), NewState :: any()}.

lookup(State, _Timeout) ->
    {ok, State#state.peers, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================

