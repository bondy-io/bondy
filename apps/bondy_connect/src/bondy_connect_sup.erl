%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_sup).

-moduledoc """
Top supervisor for the `bondy_connect` application (`one_for_one`, permanent):

```
bondy_connect_sup            (one_for_one)
├── bondy_connect_manager            (gen_server)        name registry + connect/disconnect
└── bondy_connect_connections_sup    (simple_one_for_one) one bondy_connect_conn_sup per connection
```

The manager starts first so it is available before any connection is created.
""".

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> supervisor:startlink_ret().

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

-spec init([]) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    ChildSpecs = [
        #{
            id => bondy_connect_manager,
            start => {bondy_connect_manager, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_connect_manager]
        },
        #{
            id => bondy_connect_connections_sup,
            start => {bondy_connect_connections_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [bondy_connect_connections_sup]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
