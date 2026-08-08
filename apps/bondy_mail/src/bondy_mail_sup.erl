%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_sup).

-moduledoc """
Top-level supervisor for the `bondy_mail` application.

`rest_for_one`, so that a child restarting also restarts the children that
depend on it.

## Supervision tree

```
bondy_mail_sup (rest_for_one)
├── bondy_mail_status      (worker    - message status and idempotency table)
└── bondy_mail_relay_sup   (supervisor - one child tree per configured relay)
```

`bondy_mail_status` comes first because the workers under `bondy_mail_relay_sup`
write their outcomes into its table. Under `rest_for_one` that ordering also
means a status table that has to be rebuilt takes the relays with it, rather
than leaving workers writing into a table that no longer exists.

With no relay configured the tree is empty. That is the whole of the "dormant"
behaviour: nothing to supervise, nothing to fail, and `bondy_mail:send/2`
answers `{error, not_configured}`.
""".

-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

%% API
-export([start_link/0]).

%% SUPERVISOR CALLBACKS
-export([init/1]).

-define(SERVER, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

-doc "Start the supervisor, registered as `bondy_mail_sup`.".
-spec start_link() -> {ok, pid()} | {error, any()}.

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

-doc false.
init([]) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 5,
        period => 10
    },
    {ok, {SupFlags, children()}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
children() ->
    case bondy_mail_config:is_configured() of
        false ->
            [];
        true ->
            [
                #{
                    id => bondy_mail_status,
                    start => {bondy_mail_status, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [bondy_mail_status]
                },
                #{
                    id => bondy_mail_relay_sup,
                    start => {bondy_mail_relay_sup, start_link, []},
                    restart => permanent,
                    shutdown => infinity,
                    type => supervisor,
                    modules => [bondy_mail_relay_sup]
                }
            ]
    end.
