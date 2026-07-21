%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_prometheus_SUITE).
-moduledoc """
End-to-end check of the Prometheus exposition on a booted node: the
event-driven families (bondy_prometheus), the storage-stack bridge
(bondy_prometheus_db) and the router collector (bondy_prometheus_collector)
must all render on a real scrape without error.
""".

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).

-export([exposition_renders_all_family_groups/1]).
-export([router_events_feed_metrics/1]).


all() ->
    [
        exposition_renders_all_family_groups,
        router_events_feed_metrics
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.


end_per_suite(Config) ->
    {save_config, Config}.


exposition_renders_all_family_groups(_) ->
    Output = prometheus_text_format:format(),
    true = is_binary(Output) andalso byte_size(Output) > 0,

    %% One representative family per collector/source. Families whose
    %% sources return no rows on a solo test node (e.g. per-peer
    %% connections) are deliberately not asserted.
    Expected = [
        %% bondy_prometheus (event-driven, declared at setup)
        <<"bondy_sessions_total">>,
        <<"bondy_http_requests_total">>,
        %% bondy_prometheus_db: declared counter families
        <<"bondy_oplog_wal_appends_total">>,
        <<"bondy_aae_merge_conflicts_total">>,
        %% bondy_prometheus_db: scrape-time collector families
        <<"bondy_cluster_members">>,
        <<"bondy_oplog_aae_enabled">>,
        <<"bondy_node_ready">>,
        %% bondy_prometheus_collector (router runtime state)
        <<"bondy_registry_size">>,
        <<"bondy_rpc_promises_inflight">>,
        <<"bondy_listener_connections">>,
        <<"bondy_jobs_queue_depth">>,
        %% Tier-3 source instrumentation (declared at setup)
        <<"bondy_wamp_call_latency_milliseconds">>,
        <<"bondy_rate_limited_total">>,
        <<"bondy_rpc_promise_timeouts_total">>,
        <<"bondy_registry_events_total">>,
        %% VM collectors incl. the msacc one registered at setup
        <<"erlang_vm_memory_bytes">>,
        <<"erlang_vm_msacc_emulator_seconds_total">>
    ],
    Missing = [N || N <- Expected, binary:match(Output, N) == nomatch],
    Missing == [] orelse ct:fail({missing_metric_families, Missing}),
    ok.


router_events_feed_metrics(_) ->
    %% Emit through the real event manager so the installed
    %% bondy_prometheus handler consumes them (async: poll for arrival).
    Proc = <<"com.test.latency">>,
    Node = bondy_config:node(),
    ok = bondy_event_manager:notify(
        {[bondy, wamp, call, latency], Proc, 42}
    ),
    ok = bondy_event_manager:notify(
        {[bondy, dealer, registration, created], fake_entry}
    ),
    ok = bondy_event_manager:notify(
        {[bondy, broker, subscription, deleted], fake_entry}
    ),
    ok = await(fun() ->
        {BucketCounts, Sum} = prometheus_histogram:value(
            bondy_wamp_call_latency_milliseconds, [Proc, Node]
        ),
        1 == lists:sum(BucketCounts) andalso 42 == round(Sum)
    end),
    ok = await(fun() ->
        1 ==
            prometheus_counter:value(
                bondy_registry_events_total, [registration, created]
            ) andalso
            1 ==
                prometheus_counter:value(
                    bondy_registry_events_total, [subscription, deleted]
                )
    end),
    ok.


%% @private
await(Fun) ->
    await(Fun, 50).


%% @private
await(_, 0) ->
    error(await_timeout);

await(Fun, N) ->
    try Fun() of
        true ->
            ok;
        _ ->
            timer:sleep(20),
            await(Fun, N - 1)
    catch
        _:_ ->
            timer:sleep(20),
            await(Fun, N - 1)
    end.
