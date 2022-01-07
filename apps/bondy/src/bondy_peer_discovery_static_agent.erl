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
                try
                    Node = bondy_config:node(),
                    Peers = [
                        P ||
                            #{name := Name} = P <- [to_peer(Bin) || Bin <- L],
                            Name =/= Node
                    ],
                    {ok, Peers}
                catch
                    throw:Reason ->
                        {error, Reason}
                end;
            (_) ->
                false
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
        #{nodes := Peers} = maps_utils:validate(Opts, ?OPTS_SPEC),
        {ok, #state{peers = Peers}}
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


to_peer(Bin) when is_binary(Bin) ->
    {Hostname, Port} =
        case binary:split(Bin, <<$:>>) of
            [_] ->
                {Bin, partisan_config:get(peer_port)};
            [Hostname0, Port0] ->
                try
                    {Hostname0, binary_to_integer(Port0)}
                catch
                    error:_ ->
                        throw("invalid port")
                end;
            _ ->
                throw("invalid hostname")
        end,

    {Name, Host, IPAddress} =
        case binary:split(Hostname, <<$@>>) of
            [Name0, Value] ->
                Str = binary_to_list(Value),

                case inet_parse:address(Str) of
                    {ok, IPAddress0} ->
                        {Name0, Value, IPAddress0};
                    {error, _} ->
                        case inet:getaddr(Str, inet) of
                            {ok, IPAddress0} ->
                                {Name0, Value, IPAddress0};
                            {error, _} ->
                                throw("invalid hostname")
                        end
                end;
            _ ->
                throw("invalid hostname")
        end,

    Node = binary_to_atom(<<Name/binary, $@, Host/binary>>, utf8),

    Channels = partisan_config:get(channels, [undefined]),
    Parallelism = partisan_config:get(parallelism, 1),

    #{
        name => Node,
        listen_addrs => [#{ip => IPAddress, port => Port}],
        channels => Channels,
        parallelism => Parallelism
    }.
