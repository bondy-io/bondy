%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_cluster_app).
-moduledoc """
The `bondy_cluster` application callback, and its supervisor, which has no
children.

Starting the application initialises Partisan's configuration, which holds
this node's cluster name, so `partisan:node/0` answers in every app that
depends on `bondy_cluster`, clustered or not. It starts no Partisan process;
Partisan itself is started by `bondy_router_app`, and only when
`bondy_cluster:enabled/0`.
""".

-behaviour(application).
-behaviour(supervisor).

-export([init/1]).
-export([start/2]).
-export([stop/1]).

-doc """
Application behaviour callback.
""".
start(_StartType, _StartArgs) ->
    ok = partisan_config:init(),
    supervisor:start_link({local, bondy_cluster_sup}, ?MODULE, []).

-doc """
Application behaviour callback.
""".
stop(_State) ->
    ok.

-doc """
Supervisor behaviour callback.
""".
init([]) ->
    {ok, {#{}, []}}.
