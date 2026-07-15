%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_event_handler_watcher_sup).
-moduledoc """
A `simple_one_for_one` supervisor for `bondy_event_handler_watcher` processes.
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
-export([start_watcher/2]).
-export([start_watcher/3]).
-export([terminate_watcher/1]).

%% SUPERVISOR CALLBACKS
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_watcher(
    Manager :: module(),
    {swap, OldHandler :: {module(), any()}, NewHandler :: {module(), any()}}
) ->
    ok | {error, any()}.

start_watcher(Manager, {swap, {_, _}, {_, _}} = Cmd) ->
    supervisor:start_child(?MODULE, [Manager, Cmd]).

-spec start_watcher(Manager :: module(), Handler :: module(), Args :: any()) ->
    ok | {error, any()}.

start_watcher(Manager, Handler, Args) ->
    supervisor:start_child(?MODULE, [Manager, Handler, Args]).

terminate_watcher(Watcher) when is_pid(Watcher) ->
    supervisor:terminate_child(?MODULE, Watcher).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

init([]) ->
    Children = [
        ?CHILD(bondy_event_handler_watcher, worker, [], temporary, 5000)
    ],
    Specs = {{simple_one_for_one, 0, 1}, Children},
    {ok, Specs}.

%% =============================================================================
%% PRIVATE
%% =============================================================================
