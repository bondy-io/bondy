%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_bridge_relay_exchanges_sup).
-moduledoc """
A `simple_one_for_one` supervisor for bridge relay exchange processes
(`bondy_bridge_relay_exchange_statem`), enforcing the configured
`aae_concurrency` limit when starting new exchanges.
""".

-behaviour(supervisor).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(WORKER(Id, Args, Restart, Timeout), #{
    id => Id,
    start => {Id, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => worker,
    modules => [Id]
}).

%% API
-export([start_link/0]).
-export([start_exchange/3]).
-export([stop_exchange/1]).

%% SUPERVISOR CALLBACKS
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc """
Starts a new exchange provided we would not reach the limit set by the
`aae_concurrency` config parameter. If the limit is reached returns the error
tuple `{error, concurrency_limit}`.
""".
-spec start_exchange(
    Conn :: pid(), Sessions :: [bondy_bridge_relay_session:t()], Opts :: map()
) ->
    {ok, pid()} | {error, any()}.

start_exchange(Conn, Sessions, Opts) ->
    Children = supervisor:count_children(?MODULE),
    {active, Count} = lists:keyfind(active, 1, Children),
    case bondy_config:get([edge, aae_concurrency], 1) > Count of
        true ->
            Args = [Conn, Sessions, Opts],
            supervisor:start_child(?MODULE, Args);
        false ->
            {error, concurrency_limit}
    end.

stop_exchange(Pid) when is_pid(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

init([]) ->
    Children = [
        ?WORKER(bondy_bridge_relay_exchange_statem, [], temporary, 5000)
    ],
    Specs = {{simple_one_for_one, 0, 1}, Children},
    {ok, Specs}.
