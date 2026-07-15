%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_http).

-include_lib("kernel/include/logger.hrl").

%% Starts a Cowboy HTTP listener used by the Jepsen Java client.
%% The dispatch table is deliberately small and modelled on
%% `ra-kv-store`'s API so the Clojure / Java client maps over with
%% minimal changes:
%%
%%   GET  /healthz                       liveness
%%   GET  /tables/:table/:realm/:key     read fold state
%%   PUT  /tables/:table/:realm/:key     write or compare-and-set
%%        body: value=<v>                set
%%        body: value=<v>&expected=<e>   compare-and-set
%%
%% The path is `/tables/` (not just `/`) so each request carries the
%% (table, realm) coordinates the bondy_db facade needs. The Java
%% client deterministically maps Jepsen's integer keys onto a
%% (table, realm, key) tuple — see io.leapsight.jepsen.Utils.

-export([start_link/0]).

start_link() ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/healthz", bondy_mst_jepsen_http_health, []},
            {"/tables/:table/:realm/:key",
                bondy_mst_jepsen_http_handler, []},
            %% Set-convergence workload (POST {add|rmv}, GET read
            %% members). Routes to the same per-shard projection as
            %% /tables/, but the handler applies pure set ops; meaningful
            %% when the table's CRDT is a set (`aw_set`, `rw_set`,
            %% `two_p_set`, `g_set`) selected via the cluster's
            %% `crdt_module`.
            {"/sets/:table/:realm/:key",
                bondy_mst_jepsen_http_set, []},
            %% Counter-convergence workload (POST {inc, Delta}, GET
            %% value). Meaningful when the table's CRDT is `pn_counter`.
            {"/counters/:table/:realm/:key",
                bondy_mst_jepsen_http_counter, []}
        ]}
    ]),
    Port = application:get_env(bondy_mst_jepsen, http_port, 8080),
    %% Cowboy returns the listener pid; the supervisor links us to it
    %% via the spawn return so a listener crash cascades through this
    %% worker. We deliberately do not name the listener so multiple
    %% instances could coexist in CT-style tests.
    cowboy:start_clear(
        bondy_mst_jepsen_listener,
        [{port, Port}],
        #{
            env             => #{dispatch => Dispatch},
            request_timeout => 30_000
        }
    ).
