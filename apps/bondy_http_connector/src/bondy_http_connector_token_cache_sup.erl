%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_connector_token_cache_sup).

-moduledoc """
Supervisor for a pool of token cache workers.

Workers are `permanent` — if one crashes, it is automatically restarted.

## Supervision tree position

```
bondy_http_connector_sup (rest_for_one)
└── bondy_http_connector_token_cache_sup  ← this module
    ├── worker(~"a")
    ├── worker(~"b")
    └── worker(~"c")
```
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([start_worker/2]).
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Start the supervisor, registered locally.".
-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "Start a token-cache worker child belonging to the given gproc pool.".
-spec start_worker(PoolName :: atom(), WorkerName :: atom()) ->
    {ok, pid()} | {error, term()}.

start_worker(PoolName, WorkerName) ->
    ChildSpec = #{
        id => WorkerName,
        start => {
            bondy_http_connector_token_cache_worker,
            start_link,
            [PoolName, WorkerName]
        },
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [bondy_http_connector_token_cache_worker]
    },
    supervisor:start_child(?MODULE, ChildSpec).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

-doc false.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        % max restarts
        intensity => 5,
        % seconds
        period => 10,
        auto_shutdown => never
    },
    Children = [],
    {ok, {SupFlags, Children}}.
