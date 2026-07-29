%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_connector_callee_sup).

-moduledoc """
`simple_one_for_one` supervisor for `bondy_http_connector_callee` workers.

The manager calls `start_callee/3` for each service/realm pair.
""".

-behaviour(supervisor).
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(CHILD(Id, Type, Args, Restart, Timeout), #{
    id => Id,
    start => {Id, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => Type,
    modules => [Id]
}).

%% API
-export([start_link/0]).
-export([start_callee/3]).

%% SUPERVISOR CALLBACKS
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Start a callee child for the given realm, service, and pool.".
-spec start_callee(binary(), map(), atom()) ->
    {ok, pid()} | {error, any()}.

start_callee(RealmUri, Service, PoolName) ->
    supervisor:start_child(?MODULE, [RealmUri, Service, PoolName]).

-doc "Start the supervisor, registered locally.".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

-doc false.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        % max restarts
        intensity => 5,
        % seconds
        period => 10,
        auto_shutdown => never
    },
    Children = [
        ?CHILD(bondy_http_connector_callee, worker, [], transient, 5000)
    ],

    {ok, {SupFlags, Children}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================
