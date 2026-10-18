%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_prometheus_collector).
-moduledoc """
A `prometheus_collector` producing scrape-time gauges from router-level
runtime state, collecting only when the `bondy_router` application is
running:

- **Partisan** — connection counts per peer, and per peer and channel
  (lock-free reads of the `partisan_peer_connections` ETS registry), one
  level deeper than the membership/connectivity gauges exported by
  `bondy_prometheus_db`. The per-channel family pairs, by its labels, with
  the event-driven `bondy_cluster_channel_connections_target`
  (`bondy_prometheus`).
- **RPC** — in-flight promises (pending calls/invocations awaiting yield),
  summed over the `bondy_rpc_promise` tuplespace partitions.
- **Listeners** — per-ranch-listener active vs max connections and
  cumulative accept/terminate counters (`ranch:info/0`).
- **Registry** — substrate size and memory (`bondy_registry:info/0`,
  lock-free persistent_term + `ets:info` path).
- **Jobs** — per-shard queue depth of the load-regulation pool (the
  router's async-work backpressure signal).
- **Rate limiting / OIDC** — live token-bucket and in-flight auth-flow
  table sizes.
- **Mailboxes** — `message_queue_len` of critical singleton processes
  (e.g. `bondy_event_manager`, where one slow gen_event handler backs up
  all eventing).

A source with nothing to report returns no rows and its family is absent
from the scrape. Sources run only while `bondy_router` is running; a source
that raises fails the scrape.
""".
-behaviour(prometheus_collector).

%% Critical singleton processes whose mailbox depth is a cheap, high-signal
%% backpressure indicator.
-define(WATCHED_PROCESSES, [
    bondy_event_manager,
    bondy_registry,
    bondy_rpc_promise_manager,
    bondy_bridge_relay_manager,
    bondy_oplog_sync_scheduler,
    jobs_server
]).

-export([collect_mf/2]).
-export([deregister_cleanup/1]).

%% =============================================================================
%% PROMETHEUS_COLLECTOR CALLBACKS
%% =============================================================================

-spec collect_mf(
    prometheus_registry:registry(), prometheus_collector:callback()
) -> ok.

collect_mf(_Registry, CB) ->
    ok = collect_bondy_metrics_families(CB),
    case lists:keymember(bondy_router, 1, application:which_applications()) of
        true ->
            lists:foreach(
                fun({Name, Help, Type, Fun}) ->
                    case Fun() of
                        [] ->
                            ok;
                        [_ | _] = Metrics ->
                            CB(
                                prometheus_model_helpers:create_mf(
                                    Name, Help, Type, Metrics
                                )
                            )
                    end
                end,
                families()
            );
        false ->
            ok
    end.

deregister_cleanup(_) -> ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Renders the `bondy_metrics` (BIF-counter) families declared via
%% `bondy_metrics:declare/1`. All the deferred cost of the
%% wait-free capture path lands here, on the scraper: one registry walk
%% per declared family. The declared and the counter tables share one owner,
%% so `declared/0` raising covers a missing registry.
collect_bondy_metrics_families(CB) ->
    maps:foreach(
        fun(Name, Descriptor) ->
            Help = maps:get(help, Descriptor, <<>>),
            case bondy_metrics:family(Name) of
                [] ->
                    ok;
                [_ | _] = Rows ->
                    emit_family(CB, Name, Help, Rows)
            end
        end,
        bondy_metrics:declared()
    ).

%% @private
%% `bondy_metrics` fixes a family's type at first touch and answers
%% `{error, {wrong_type, _}}` to any other type (see its `counter/1`,
%% `gauge/1` and `histogram/1` docs), so the first row's type is the family's.
emit_family(CB, Name, Help, [#{type := histogram} | _] = Rows) ->
    Specs = [
        {
            label_pairs(Label),
            cumulative_buckets(Snapshot),
            maps:get(count, Snapshot),
            maps:get(sum, Snapshot)
        }
     || #{label := Label, value := Snapshot} <- Rows
    ],
    CB(prometheus_model_helpers:create_mf(Name, Help, histogram, Specs));
emit_family(CB, Name, Help, [#{type := Type} | _] = Rows) ->
    Metrics = [
        {label_pairs(Label), Value}
     || #{label := Label, value := Value} <- Rows
    ],
    CB(prometheus_model_helpers:create_mf(Name, Help, Type, Metrics)).

%% @private
%% Deterministic label ordering across rows of a family.
label_pairs(Label) when is_map(Label) ->
    lists:sort(maps:to_list(Label)).

%% @private
%% Converts a sparse ascending `[{BucketIndex, Count}]` snapshot into the
%% Prometheus cumulative form `[{UpperBound, CumulativeCount}]`,
%% terminated with the mandatory `+Inf` bucket. Bounds come from the
%% log-linear layout's inclusive upper bounds
%% (`bondy_metrics:hist_bucket_high/1`), which is exactly the `le` semantic.
cumulative_buckets(#{count := Total, buckets := Sparse}) ->
    {Buckets, _} = lists:mapfoldl(
        fun({I, C}, Acc0) ->
            Acc = Acc0 + C,
            {{bondy_metrics:hist_bucket_high(I), Acc}, Acc}
        end,
        0,
        Sparse
    ),
    Buckets ++ [{infinity, Total}].

%% @private
%% Scrape-time families. Each fun returns `[{Labels, Value}]`; an empty
%% list skips the family.
families() ->
    [
        {bondy_cluster_connections,
            "Partisan connections established to each peer.", gauge,
            fun peer_connection_rows/0},
        {bondy_cluster_channel_connections,
            "Partisan connections per peer and channel; below "
            "bondy_cluster_channel_connections_target the channel is "
            "under-provisioned.", gauge, fun channel_connection_rows/0},
        {bondy_rpc_promises_inflight,
            "Pending RPC promises (calls/invocations awaiting a yield or "
            "error). Rising values mean callee saturation.", gauge,
            fun rpc_promises/0},
        {bondy_rpc_inflight_invocations,
            "Pending RPC promises per procedure. Rising values mean callee "
            "saturation for that procedure. Computed from the live promise "
            "store at scrape time (drift-free).", gauge,
            fun rpc_promises_by_procedure/0},
        {bondy_registry_size,
            "Registry substrate size (exact-match entries, per-URI "
            "counters and trie nodes; approximate entry count).", gauge,
            fun() -> registry_info_rows(size) end},
        {bondy_registry_memory, "Registry substrate memory.", gauge, fun() ->
            registry_info_rows(memory)
        end},
        {bondy_listener_connections, "Active connections per ranch listener.",
            gauge, fun() -> listener_gauge_rows(active_connections) end},
        {bondy_listener_max_connections, "Connection limit per ranch listener.",
            gauge, fun() -> listener_gauge_rows(max_connections) end},
        {bondy_listener_accepts_total,
            "Connections accepted per ranch listener since start.", counter,
            fun() -> listener_metric_rows(accept) end},
        {bondy_listener_terminates_total,
            "Connections terminated per ranch listener since start.", counter,
            fun() -> listener_metric_rows(terminate) end},
        {bondy_jobs_queue_depth, "Queued jobs per load-regulation pool shard.",
            gauge, fun() -> jobs_queue_rows(depth) end},
        {bondy_jobs_enqueued_total,
            "Jobs enqueued per load-regulation pool shard since start.",
            counter, fun() -> jobs_queue_rows(enqueued) end},
        {bondy_rate_limiter_buckets,
            "Live rate-limiter entries (keyspace growth / GC health).", gauge,
            fun rate_limiter_rows/0},
        {bondy_oidc_flows_inflight,
            "Pending OIDC/PKCE login flows awaiting the callback.", gauge,
            fun oidc_inflight/0},
        {bondy_process_message_queue_len,
            "Mailbox depth of critical singleton processes.", gauge,
            fun mailbox_rows/0}
    ].

%% @private
%% `partisan_config:init/0` runs at `bondy_cluster` start, before
%% `bondy_router`. The Partisan connection reads answer `[]` or `0` while the
%% peer-connections table is absent (clustering off).
peer_connection_rows() ->
    [
        {[{peer, Node}], partisan_peer_connections:count(Node)}
     || Node <- partisan:nodes()
    ].

%% @private
channel_connection_rows() ->
    Channels = maps:keys(partisan_config:channels()),
    [
        {
            [{peer, Node}, {channel, Channel}],
            partisan_peer_connections:count(Node, Channel)
        }
     || Node <- partisan:nodes(),
        Channel <- Channels
    ].

%% @private
%% `bondy_router` starts `tuplespace` before it runs, and `tuplespace` never
%% erases its ring. `ets:info/2` answers `undefined` for a dropped table.
rpc_promises() ->
    Tabs = tuplespace:tables(bondy_rpc_promise),
    Sizes = [S || T <- Tabs, S <- [ets:info(T, size)], is_integer(S)],
    case Tabs of
        [] -> [];
        _ -> [{[], lists:sum(Sizes)}]
    end.

%% @private
rpc_promises_by_procedure() ->
    [
        {[{procedure_uri, Uri}], N}
     || Uri := N <- bondy_rpc_promise:count_by_procedure()
    ].

%% @private
%% `/metrics` stays up while the router tree stops. A stopping partition
%% erases its store first (`function_clause` in `bondy_registry_store:info/1`),
%% then its ptrie tables die with it (`badarg`).
registry_info_rows(Key) ->
    try bondy_registry:info() of
        #{Key := N} -> [{[], N}]
    catch
        error:function_clause -> [];
        error:badarg -> []
    end.

%% @private
listener_gauge_rows(Key) ->
    [
        {[{listener, label(Ref)}], V}
     || {Ref, Info} <- listeners(),
        V <- [maps:get(Key, Info, undefined)],
        is_integer(V)
    ].

%% @private
%% Sums the ranch conns-sup counters whose key ends in `Suffix` (keys are
%% `{conns_sup, Id, accept | terminate}`).
listener_metric_rows(Suffix) ->
    lists:filtermap(
        fun({Ref, Info}) ->
            case maps:get(metrics, Info, undefined) of
                Metrics when is_map(Metrics) ->
                    Total = maps:fold(
                        fun
                            (K, V, Acc) when
                                is_tuple(K),
                                is_integer(V),
                                element(tuple_size(K), K) == Suffix
                            ->
                                Acc + V;
                            (_, _, Acc) ->
                                Acc
                        end,
                        0,
                        Metrics
                    ),
                    {true, {[{listener, label(Ref)}], Total}};
                _ ->
                    false
            end
        end,
        listeners()
    ).

%% @private
%% A listener that stops during `ranch:info/0` raises `badarg` from
%% `ranch_server`, a call exit from its dead supervisor, or the `noproc`,
%% `shutdown` or `timeout` exit of `ranch_conns_sup:active_connections/1`.
listeners() ->
    try ranch:info() of
        M -> maps:to_list(M)
    catch
        error:badarg -> [];
        exit:{noproc, {gen_server, call, _}} -> [];
        exit:{shutdown, {gen_server, call, _}} -> [];
        exit:noproc -> [];
        exit:shutdown -> [];
        exit:timeout -> []
    end.

%% @private
%% Reads the pool shards' queues via the full `jobs:queue_info/1`
%% pretty-printed property list. NOTE: `jobs:queue_info(Q, length)` must
%% not be used — `length` is not a `#queue` record field, so the exprecs
%% getter inside jobs_server raises and logs an error report on every
%% query. Depth comes from the passive queue's backing ETS table (the
%% `st` property is jobs_queue's `#st{table = Tab}`); `queued` is the
%% cumulative enqueue counter field.
jobs_queue_rows(Kind) ->
    PoolSize = bondy_config:get([job_manager_pool, size], 32),
    lists:filtermap(
        fun(Index) ->
            Queue = {bondy_jobs_worker, Index, queue},
            case jobs:queue_info(Queue) of
                {queue, Props} ->
                    case jobs_queue_value(Kind, Props) of
                        N when is_integer(N) ->
                            {true, {[{shard, Index}], N}};
                        undefined ->
                            false
                    end;
                undefined ->
                    false
            end
        end,
        lists:seq(1, PoolSize)
    ).

%% @private
jobs_queue_value(depth, Props) ->
    {st, {st, Tab}} = lists:keyfind(st, 1, Props),
    ets:info(Tab, size);
jobs_queue_value(enqueued, Props) ->
    {queued, N} = lists:keyfind(queued, 1, Props),
    N.

%% @private
rate_limiter_rows() ->
    [
        {[{table, Tab}], Size}
     || Tab <- [bondy_rate_limiter, bondy_regulator_rate_limit],
        Size <- [ets:info(Tab, size)],
        is_integer(Size)
    ].

%% @private
oidc_inflight() ->
    case ets:info(bondy_oidc_state, size) of
        N when is_integer(N) -> [{[], N}];
        undefined -> []
    end.

%% @private
mailbox_rows() ->
    lists:filtermap(
        fun(Name) ->
            with_pid_info(Name, erlang:whereis(Name))
        end,
        ?WATCHED_PROCESSES
    ).

%% @private
with_pid_info(_Name, undefined) ->
    false;
with_pid_info(Name, Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> {true, {[{name, Name}], N}};
        _ -> false
    end.

%% @private
label(V) when is_atom(V) orelse is_binary(V) ->
    V;
label(V) ->
    unicode:characters_to_binary(io_lib:format("~0p", [V])).
