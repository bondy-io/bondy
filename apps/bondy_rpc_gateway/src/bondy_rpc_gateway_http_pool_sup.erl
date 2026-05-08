%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_http_pool_sup).

-moduledoc """
`simple_one_for_one` supervisor for `bondy_rpc_gateway_http_pool` workers.

The manager calls `start_pool/3` for each configured service.
""".

-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([start_pool/3]).

%% supervisor callback
-export([init/1]).



%% =============================================================================
%% API
%% =============================================================================


-doc "Start the supervisor, registered locally.".
-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


-doc "Start a pool child for the given endpoint.".
-spec start_pool(atom(), binary(), bondy_rpc_gateway_http_pool:start_opts()) ->
    {ok, pid()} | {error, term()}.

start_pool(Name, Endpoint, Opts) ->
    supervisor:start_child(?MODULE, [Name, Endpoint, Opts]).


%% =============================================================================
%% supervisor callback
%% =============================================================================


-doc false.
init([]) ->
    ChildSpec = #{
        id => bondy_rpc_gateway_http_pool,
        start => {bondy_rpc_gateway_http_pool, start_link, []},
        restart => permanent,
        shutdown => 5_000,
        type => worker,
        modules => [bondy_rpc_gateway_http_pool]
    },
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, [ChildSpec]}}.
