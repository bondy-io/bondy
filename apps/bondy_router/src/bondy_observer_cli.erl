%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_observer_cli).
-moduledoc """
Launcher for Bondy's `observer_cli` plugin dashboard (the Cluster and Sync
panes). Call `bondy_observer_cli:start/0` from a node console:

```erlang
bondy_observer_cli:start().
```

It registers the plugins in the `observer_cli` application env (so it works even
when the release `sys.config` was not updated) and opens the plugin view
directly. Inside the view, switch panes with the plugin shortcuts — type the key
**followed by Enter** (`observer_cli` reads a full line): `C` for Cluster, `Y`
for Sync. `H`+Enter returns to the observer home; `q`+Enter quits.

The panes are `bondy_observer_cli_cluster` (Partisan membership/connectivity) and
`bondy_observer_cli_sync` (per-shard MST root comparison vs each peer — the
bondy_db AAE sync status).
""".

-export([plugins/0]).
-export([start/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc "The observer_cli plugin specs for Bondy's Cluster and Sync panes.".
-spec plugins() -> [map()].

plugins() ->
    [
        #{
            module => bondy_observer_cli_cluster,
            title => "Cluster",
            interval => 2000,
            shortcut => "C",
            sort => node
        },
        #{
            module => bondy_observer_cli_sync,
            title => "Sync",
            interval => 2000,
            shortcut => "Y",
            sort => status
        }
    ].

-doc """
Register the Bondy plugins and open the `observer_cli` plugin dashboard. Blocks
the calling shell until you quit the view (`q`+Enter).
""".
-spec start() -> no_return().

start() ->
    {ok, _} = application:ensure_all_started(observer_cli),
    ok = application:set_env(observer_cli, plugins, plugins()),
    observer_cli:start_plugin().
