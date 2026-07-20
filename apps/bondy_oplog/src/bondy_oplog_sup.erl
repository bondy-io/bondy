%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_sup).

-behaviour(supervisor).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Top-level library supervisor.

Children, in start order:

| Child | Strategy |
|---|---|
| `bondy_oplog_registry`           | `gen_server`; node-shared per-instance read-snapshot ETS |
| `bondy_metrics`                  | `gen_server`; counters/atomics registry (Name+Label → counters ref) |
| `bondy_oplog_core_events`            | `gen_server`; intra-node pub/sub for substrate restart-recovery |
| `bondy_oplog_core_registry`          | `gen_server`; node-shared per-(NS,Index,Shard) read-handle ETS |
| `bondy_oplog_core_dispatcher`        | `gen_server`; local-only `subscribe/2` ref dispatcher |
| `bondy_oplog_core_metrics`           | `gen_server`; periodic per-namespace gauge emitter |
| `bondy_oplog_peer_state`         | `gen_server`; node-shared peer ETS |
| `bondy_oplog_origin_bans`        | `gen_server`; node-shared origin ban ETS |
| `bondy_oplog_quarantine`         | `gen_server`; node-shared equivocation quarantine ETS |
| `bondy_oplog_responder`          | `gen_server`; sync request demuxer |
| `bondy_oplog_catalogue_cursor`   | `gen_server`; node-shared catalogue-bootstrap cursor ETS |
| `bondy_oplog_sync_scheduler`     | `gen_server`; optional default scheduler |
| `bondy_oplog_gc_scheduler`       | `gen_server`; optional default scheduler |
| `bondy_oplog_index_rebuild`      | `gen_server`; serialised secondary-index rebuild orchestrator |
| `bondy_oplog_secondary_sup`      | `simple_one_for_one`; spawns per-(NS,Index,Shard) index writers |
| `bondy_oplog_instance_dyn_sup`   | `simple_one_for_one`; spawns per-instance workers |

Strategy is `one_for_one`: a singleton crash does not cascade across
the others. In particular, peer state crashing must not take running
instances down.

The schedulers can be disabled via app env (`{sync_scheduler, false}`,
`{gc_scheduler, false}`); when disabled the gen_servers still start
but their tick timers are quiescent.
""").

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },
    ChildSpecs = [
        bondy_oplog_registry:child_spec(),
        bondy_metrics:child_spec(),
        bondy_oplog_core_events:child_spec(),
        bondy_oplog_core_registry:child_spec(),
        bondy_oplog_core_dispatcher:child_spec(),
        bondy_oplog_core_metrics:child_spec(),
        bondy_oplog_latency:child_spec(),
        bondy_oplog_peer_state:child_spec(#{}),
        bondy_oplog_origin_bans:child_spec(),
        bondy_oplog_origin_retirement:child_spec(),
        bondy_oplog_quarantine:child_spec(),
        bondy_oplog_responder:child_spec(),
        bondy_oplog_catalogue_cursor:child_spec(),
        bondy_oplog_sync_scheduler:child_spec(#{}),
        bondy_oplog_gc_scheduler:child_spec(#{}),
        %% Projection-cell reclamation: a SECOND gc_scheduler instance on
        %% its own (much slower) cadence, driving the causal-stability
        %% sweep. On by default (`reclaim_enabled`); a disabled scheduler
        %% idles at the cost of one process.
        bondy_oplog_gc_scheduler:child_spec(#{
            name => bondy_oplog_reclaim_scheduler,
            enabled => bondy_oplog_config:reclaim_enabled(),
            interval_ms => bondy_oplog_config:reclaim_interval_ms(),
            trigger => fun bondy_oplog_instance:reclaim_stable_cells/1
        }),
        bondy_oplog_index_rebuild:child_spec(),
        #{
            id => bondy_oplog_secondary_sup,
            start => {bondy_oplog_secondary_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [bondy_oplog_secondary_sup]
        },
        #{
            id => bondy_oplog_instance_dyn_sup,
            start => {bondy_oplog_instance_dyn_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [bondy_oplog_instance_dyn_sup]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
