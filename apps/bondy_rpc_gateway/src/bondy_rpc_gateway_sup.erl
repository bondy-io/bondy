%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_sup).

-moduledoc """
Top-level supervisor for the `bondy_rpc_gateway` application.

Uses the `rest_for_one` strategy so that downstream children restart
when an upstream dependency restarts.

## Supervision tree

```
bondy_rpc_gateway_sup (rest_for_one)
├── bondy_rpc_gateway_token_cache_sup   (supervisor)
├── bondy_rpc_gateway_token_cache       (worker)
├── bondy_rpc_gateway_http_pool_sup     (supervisor – simple_one_for_one)
├── bondy_rpc_gateway_callee_sup        (supervisor – simple_one_for_one)
└── bondy_rpc_gateway_manager           (worker)
```
""".

-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

-doc "Start the supervisor, registered as `bondy_rpc_gateway_sup`.".
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).




%% =============================================================================
%% CALLBACKS
%% =============================================================================



-doc false.
init([]) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 5,
        period => 10
    },

    Children =
        case bondy_rpc_gateway_config:get(services, []) of
            [] ->
                ?LOG_NOTICE(#{
                    description => "No services configured, skipping startup"
                }),
                [];

            L when is_list(L) ->
                ?LOG_NOTICE(#{
                    description => io_lib:format(
                        ~"Starting RPC Gateway (~p services)",
                        [length(L)]
                    )
                }),
                children()
        end,

    {ok, {SupFlags, Children}}.




%% =============================================================================
%% PRIVATE
%% =============================================================================

children() ->
     [
        #{
            id => bondy_rpc_gateway_token_cache_sup,
            start => {
                bondy_rpc_gateway_token_cache_sup, start_link, []
            },
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [bondy_rpc_gateway_token_cache_sup]
        },
        #{
            id => bondy_rpc_gateway_token_cache,
            start => {bondy_rpc_gateway_token_cache, start_link, []},
            restart => permanent,
            shutdown => 5_000,
            type => worker,
            modules => [bondy_rpc_gateway_token_cache]
        },
        #{
            id => bondy_rpc_gateway_http_pool_sup,
            start => {bondy_rpc_gateway_http_pool_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [bondy_rpc_gateway_http_pool_sup]
        },
        #{
            id => bondy_rpc_gateway_callee_sup,
            start => {bondy_rpc_gateway_callee_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [bondy_rpc_gateway_callee_sup]
        },
        #{
            id => bondy_rpc_gateway_manager,
            start => {bondy_rpc_gateway_manager, start_link, []},
            restart => permanent,
            shutdown => 5_000,
            type => worker,
            modules => [bondy_rpc_gateway_manager]
        }
    ].


