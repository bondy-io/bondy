%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Single-node smoke test for the bondy_mst_jepsen app: brings the
%% supervision tree up locally (with an empty peer list), exercises
%% the HTTP shim against bondy_db, then shuts down. This is the
%% Erlang-side guardrail; the full 3-node Jepsen run lives under
%% `jepsen/jepsen.bondymst/` and is driven by lein.

-module(bondy_mst_jepsen_smoke_test).

-include_lib("eunit/include/eunit.hrl").

-define(BASE_URL, "http://127.0.0.1:18080").
-define(TIMEOUT_S, 30).

bondy_mst_jepsen_smoke_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
         {timeout, ?TIMEOUT_S, fun healthz_returns_cluster_info/0},
         {timeout, ?TIMEOUT_S, fun set_then_get/0},
         {timeout, ?TIMEOUT_S, fun cas_success_then_failure/0},
         {timeout, ?TIMEOUT_S, fun unknown_table_404/0}
     ]}.

setup() ->
    %% Force a unique data dir per run; tests sharing /tmp would otherwise
    %% replay each other's WALs.
    DataDir = filename:join("/tmp/bondy_mst_jepsen_smoke",
                            integer_to_list(os:system_time(microsecond))),
    %% Load the app first so application:set_env/3 doesn't get
    %% clobbered by the .app.src defaults at load time.
    ok = case application:load(bondy_mst_jepsen) of
             ok -> ok;
             {error, {already_loaded, _}} -> ok
         end,
    application:set_env(bondy_mst_jepsen, http_port, 18080),
    application:set_env(bondy_mst_jepsen, data_dir, DataDir),
    application:set_env(bondy_mst_jepsen, peers, []),
    %% Smaller scale than production so the test is brisk.
    application:set_env(bondy_mst_jepsen, tables, [t0, t1]),
    application:set_env(bondy_mst_jepsen, shard_count, 2),
    application:set_env(bondy_mst_jepsen, fold_module, lww_register),
    {ok, _} = application:ensure_all_started(bondy_mst_jepsen),
    {ok, _} = application:ensure_all_started(inets),
    DataDir.

cleanup(DataDir) ->
    application:stop(bondy_mst_jepsen),
    %% Best-effort cleanup of WAL + leveled artefacts (CLAUDE feedback:
    %% leftover WAL data under /tmp accumulates).
    os:cmd("rm -rf " ++ DataDir),
    ok.

healthz_returns_cluster_info() ->
    {ok, {{_, 200, _}, _, Body}} =
        httpc:request(get,
                      {?BASE_URL ++ "/healthz", []},
                      [], []),
    Info = jsx:decode(list_to_binary(Body), [return_maps]),
    ?assertEqual(<<"jepsen">>, maps:get(<<"db">>, Info)),
    ?assertEqual([<<"t0">>, <<"t1">>], maps:get(<<"tables">>, Info)),
    ?assertEqual([], maps:get(<<"peers">>, Info)).

set_then_get() ->
    URL = ?BASE_URL ++ "/tables/t0/r1/k1",
    {ok, {{_, 200, _}, _, _}} =
        httpc:request(put,
                      {URL,
                       [],
                       "application/x-www-form-urlencoded",
                       "value=hello"},
                      [], []),
    {ok, {{_, 200, _}, _, Body}} =
        httpc:request(get, {URL, []}, [], []),
    ?assertEqual("hello", Body).

cas_success_then_failure() ->
    URL = ?BASE_URL ++ "/tables/t1/r1/cas-key",
    %% Initial set.
    {ok, {{_, 200, _}, _, _}} =
        httpc:request(put,
                      {URL, [], "application/x-www-form-urlencoded",
                       "value=v1"},
                      [], []),
    %% Round-trip read to confirm v1 is durable before the CAS.
    {ok, {{_, 200, _}, _, "v1"}} =
        httpc:request(get, {URL, []}, [], []),
    %% CAS v1 -> v2 succeeds.
    {ok, {{_, 200, _}, _, _}} =
        httpc:request(put,
                      {URL, [], "application/x-www-form-urlencoded",
                       "value=v2&expected=v1"},
                      [], []),
    %% Round-trip read to confirm v2 is durable before the failure CAS.
    {ok, {{_, 200, _}, _, "v2"}} =
        httpc:request(get, {URL, []}, [], []),
    %% CAS v1 -> v3 now fails (current is v2).
    {ok, {{_, 409, _}, _, _}} =
        httpc:request(put,
                      {URL, [], "application/x-www-form-urlencoded",
                       "value=v3&expected=v1"},
                      [], []).

unknown_table_404() ->
    URL = ?BASE_URL ++ "/tables/nope/r1/k1",
    {ok, {{_, 404, _}, _, _}} =
        httpc:request(get, {URL, []}, [], []).
