%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_broker_bridge_sup).

-moduledoc """
Top-level supervisor for the `bondy_broker_bridge` application.

Supervises a single child — `bondy_broker_bridge_manager` — using a
`one_for_one` strategy with at most 1 restart in 5 seconds.

```
bondy_broker_bridge_sup (one_for_one)
  └── bondy_broker_bridge_manager (worker, permanent)
```
""".

-behaviour(supervisor).

-define(CHILD(Id, Type, Args, Restart, Timeout), #{
    id => Id,
    start => {Id, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => Type,
    modules => [Id]
}).

-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).



%% =============================================================================
%% API
%% =============================================================================


-doc "Start the supervisor, registered locally.".
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).



%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================


-doc false.
init([]) ->
    Children = [
        ?CHILD(bondy_broker_bridge_manager, worker, [], permanent, 5000)
    ],
    {ok, {{one_for_one, 1, 5}, Children}}.
