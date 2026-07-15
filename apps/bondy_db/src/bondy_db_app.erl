%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_app).

-behaviour(application).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Application entry point for the `bondy_db` consumer facade and its
leveled-backed storage topologies.

`bondy_db` sits above `bondy_oplog` and owns the leveled concern, so at start
it performs the two pieces of wiring that the lower layer deliberately does
not:

- `bondy_db_leveled_tag:install/0` — register the projection fold-tag
  extractor/head-builder with leveled (see `?BONDY_FOLD_TAG`). This must run
  before any leveled bookie opens; `bondy_db` owns the bookies (via the
  leveled topologies), so installing it here preserves that ordering.
- registers `{bondy_db, probe_write}` as the `bondy_oplog` latency monitor's
  idle-probe write (`application:set_env(bondy_oplog, latency_probe, …)`).
  This inverts the old direct `bondy_oplog_latency -> bondy_db` call so the
  dependency arrow points only downward.

The layer has no permanent processes of its own — leveled bookie supervisors
and topology ETS owners are started on demand per table — so `bondy_db_sup`
is a trivial root supervisor.
""").

-export([start/2, stop/1]).

%% =============================================================================
%% APPLICATION CALLBACKS
%% =============================================================================

start(_StartType, _StartArgs) ->
    ok = bondy_db_leveled_tag:install(),
    ok = application:set_env(
        bondy_oplog, latency_probe, {bondy_db, probe_write}
    ),
    bondy_db_sup:start_link().

stop(_State) ->
    ok.
