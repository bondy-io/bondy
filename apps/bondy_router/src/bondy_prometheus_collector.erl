%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_prometheus_collector).
-moduledoc """
A `prometheus_collector` producing scrape-time gauges from router-level
runtime state, collecting only when the `bondy_router` application is
running:

- **Partisan** — connection counts per peer and per channel (lock-free
  reads of the `partisan_peer_connections` ETS registry), one level deeper
  than the membership/connectivity gauges exported by
  `bondy_prometheus_db`.
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

All reads are defensive: a failing source degrades to an absent metric
family, never a scrape error.
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
                    Metrics =
                        try
                            Fun()
                        catch
                            _:_ -> []
                        end,
                    case Metrics of
                        [] ->
                            ok;
                        _ ->
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
%% per declared family. Defensive like every other source in this
%% collector — a missing registry table or a bad row skips the family,
%% never fails the scrape.
collect_bondy_metrics_families(CB) ->
    maps:foreach(
        fun(Name, Descriptor) ->
            Help = maps:get(help, Descriptor, <<>>),
            Rows =
                try
                    bondy_metrics:family(Name)
                catch
                    _:_ -> []
                end,
            case Rows of
                [] ->
                    ok;
                _ ->
                    emit_family(CB, Name, Help, Rows)
            end
        end,
        bondy_metrics:declared()
    ).

%% @private
%% The type is fixed per name at first touch (`bondy_metrics:operate/3`),
%% so inspecting the first row is authoritative for the family.
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
%% log-linear layout's inclusive upper bounds (`hist_bucket_high/1`),
%% which is exactly the `le` semantic.
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
%% list (or a crash, caught by the caller) skips the family.
families() ->
    [
        {bondy_cluster_connections,
            "Partisan connections established to each peer.", gauge,
            fun peer_connection_rows/0},
        {bondy_cluster_channel_connections,
            "Partisan connections per channel (all peers).", gauge,
            fun channel_connection_rows/0},
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
peer_connection_rows() ->
    Nodes =
        try partisan:nodes() of
            L when is_list(L) -> L;
            _ -> []
        catch
            _:_ -> []
        end,
    lists:filtermap(
        fun(Node) ->
            try partisan_peer_connections:count(Node) of
                N when is_integer(N) ->
                    {true, {[{peer, Node}], N}};
                _ ->
                    false
            catch
                _:_ -> false
            end
        end,
        Nodes
    ).

%% @private
channel_connection_rows() ->
    Channels =
        try partisan_config:channels() of
            M when is_map(M) -> maps:keys(M);
            _ -> []
        catch
            _:_ -> []
        end,
    lists:filtermap(
        fun(Channel) ->
            try partisan_peer_connections:count('_', Channel) of
                N when is_integer(N) ->
                    {true, {[{channel, Channel}], N}};
                _ ->
                    false
            catch
                _:_ -> false
            end
        end,
        Channels
    ).

%% @private
rpc_promises() ->
    Tabs =
        try tuplespace:tables(bondy_rpc_promise) of
            L when is_list(L) -> L;
            _ -> []
        catch
            _:_ -> []
        end,
    Sizes = [
        S
     || T <- Tabs,
        S <- [
            try
                ets:info(T, size)
            catch
                _:_ -> undefined
            end
        ],
        is_integer(S)
    ],
    case Tabs of
        [] -> [];
        _ -> [{[], lists:sum(Sizes)}]
    end.

%% @private
rpc_promises_by_procedure() ->
    try bondy_rpc_promise:count_by_procedure() of
        Counts when is_map(Counts) ->
            [
                {[{procedure_uri, Uri}], N}
             || Uri := N <- Counts
            ];
        _ ->
            []
    catch
        _:_ -> []
    end.

%% @private
registry_info_rows(Key) ->
    try bondy_registry:info() of
        #{} = Info ->
            case maps:get(Key, Info, undefined) of
                N when is_integer(N) -> [{[], N}];
                _ -> []
            end;
        _ ->
            []
    catch
        _:_ -> []
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
listeners() ->
    try ranch:info() of
        M when is_map(M) -> maps:to_list(M);
        _ -> []
    catch
        _:_ -> []
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
            try jobs:queue_info(Queue) of
                {queue, Props} when is_list(Props) ->
                    case jobs_queue_value(Kind, Props) of
                        N when is_integer(N) ->
                            {true, {[{shard, Index}], N}};
                        _ ->
                            false
                    end;
                _ ->
                    false
            catch
                _:_ -> false
            end
        end,
        lists:seq(1, PoolSize)
    ).

%% @private
jobs_queue_value(depth, Props) ->
    case lists:keyfind(st, 1, Props) of
        {st, {st, Tab}} ->
            try
                ets:info(Tab, size)
            catch
                _:_ -> undefined
            end;
        _ ->
            undefined
    end;
jobs_queue_value(enqueued, Props) ->
    case lists:keyfind(queued, 1, Props) of
        {queued, N} -> N;
        _ -> undefined
    end.

%% @private
rate_limiter_rows() ->
    [
        {[{table, Tab}], Size}
     || Tab <- [bondy_rate_limiter, bondy_regulator_rate_limit],
        Size <- [
            try
                ets:info(Tab, size)
            catch
                _:_ -> undefined
            end
        ],
        is_integer(Size)
    ].

%% @private
oidc_inflight() ->
    try ets:info(bondy_oidc_state, size) of
        N when is_integer(N) -> [{[], N}];
        _ -> []
    catch
        _:_ -> []
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
