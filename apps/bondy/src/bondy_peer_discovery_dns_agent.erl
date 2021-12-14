%% =============================================================================
%%  bondy_peer_discovery_dns_agent.erl -
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
%% that uses DNS for service discovery.
%%
%% It is enabled by using the following options in the bondy.conf file
%%
%% ```bash
%% cluster.peer_discovery_agent.type = bondy_peer_discovery_dns_agent
%% cluster.peer_discovery_agent.config.service_name = my-service-name
%% '''
%% Where service_name is the service to be used by the DNS lookup.
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_peer_discovery_dns_agent).
-behaviour(bondy_peer_discovery_agent).

-include_lib("kernel/include/logger.hrl").

-define(OPTS_SPEC, #{
    <<"service_name">> => #{
        key => service_name,
        alias => <<"service_name">>,
        required => true,
        datatype => binary
    }
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
        {ok, maps_utils:validate(Opts, ?OPTS_SPEC)}
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

lookup(State, Timeout) ->
    SrvName = binary_to_list(maps:get(service_name, State)),

    case inet_res:resolve(SrvName, in, srv, [], Timeout) of
        {ok, DNSMessage} ->
            ?LOG_DEBUG(#{
                description => "Got DNS lookup response",
                response => DNSMessage,
                service_name => SrvName
            }),
            {ok, to_peer_list(DNSMessage), State};
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "DNS lookup error",
                reason => Reason,
                service_name => SrvName
            }),
            {error, Reason, State}
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Example:
%% ```erlang
%% #{
%%      name => 'bondy@bondy-1.bondy.infra.svc.cluster.local',
%%      listen_addrs => [#{ip => {10,1,0,56}, port => 19086}]
%% }.
%% '''
%% @end
%% -----------------------------------------------------------------------------
to_peer_list(DNSMessage) ->
    %% We are assuming all nodes export the same peer_port
    {ok, Port} = application:get_env(partisan, peer_port),
    %% We are assuming all nodes have the same nodename prefix
    Prefix = "bondy",
    MyNode = bondy_config:node(),

    L = [
        maps:from_list([
            to_peer_entry(R, Prefix, Port)
            || {K, _} = R <- inet_dns:rr(ARecord),
                K == data orelse K == domain
        ])
        || ARecord <- inet_dns:msg(DNSMessage, arlist)
    ],

    %% We remove ourselves from the list
    lists:filter(
        fun(#{name := Name}) when Name == MyNode -> false; (_) -> true end,
        L
    ).





%% @private
to_peer_entry({domain, Domain}, Prefix, _) ->
    {name, list_to_atom(Prefix ++ "@" ++ Domain)};

to_peer_entry({data, IP}, _, Port) ->
    {listen_addrs , [#{ip => IP, port => Port}]}.


