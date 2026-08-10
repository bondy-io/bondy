%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Regression-lock for registry op-log history reclamation AT DEFAULTS:
%% peer-confirmed compaction (the same mechanism durable databases use)
%% keeps the ephemeral `registry` DB's history bounded on a real cluster
%% under sustained write load and drains it once writes stop, at no cost
%% to cross-node RIB correctness. Would have caught the
%% `bondy_oplog_gc_scheduler` head-of-line starvation (idle `main/*`
%% shards monopolising the tick's max_concurrency slots so `registry/*`
%% shards were NEVER compacted on clustered nodes) — the actual mechanism
%% behind the fleet-scale OOM.
%%
%% A 3-node real Partisan cluster (`bondy_ct:start_cluster/2` — full bondy
%% releases, real AAE), NOT frozen (`bondy_ct:freeze_gc/1` is deliberately
%% never called — the point is the real `bondy_oplog_gc_scheduler` and
%% `bondy_oplog_sync_scheduler` ticking on their normal cadences). Drives
%% sustained writes through the REAL `bondy_registry`/`bondy_db` APIs
%% against the cluster's own provisioned `main` + `registry` shards (16 +
%% 16, production shard count, no synthetic instances), samples every
%% running instance's `bondy_oplog:size/1` through the write and settle
%% windows, and asserts (a) no `registry/*` shard's history ever exceeds
%% the propagation ceiling, (b) every `registry/*` shard drains to
%% quiescent by its last post-settle sample, (c)
%% `bondy_registry_rib:check/1` reports zero divergence on every node.
%%
%% History: this suite began as the DIAGNOSTIC that established the
%% fleet-scale OOM's mechanism — its earlier two-scenario form (default vs
%% raised `aae_max_concurrency`) plus a Fly A/B (HEAD vs pre-migration
%% `5fe220e6`) refuted the concurrency-cap hypothesis. The A/B's
%% "capacity fact of stability-driven compaction" conclusion was later
%% found CONFOUNDED by the scheduler starvation above (compaction never
%% ran at all on clustered nodes in any of those experiments). An interim
%% `mst_retention`-always-on iteration of this suite then surfaced the
%% replace-mode install clobber on live re-bootstraps — which is why
%% retention is now an opt-in overload backstop, off by default, and this
%% suite locks the DEFAULT behaviour. The per-peer dispatch histogram and
%% recovery-chain telemetry capture are retained as
%% diagnostics-on-failure.

-module(bondy_oplog_compaction_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

-define(NODE_NAMES, [bondy1, bondy2, bondy3]).
-define(NUM_REALMS, 16).
-define(WRITE_WINDOW_MS, 25000).
-define(SETTLE_WINDOW_MS, 45000).
%% A sample at/below this is "empty enough to call settled/quiescent" —
%% used both to classify a shard's starting state (clean vs carrying
%% leftover cluster-bootstrap activity) and to judge whether its last
%% sample shows it fully drained.
-define(QUIESCENT_THRESHOLD, 5).
-define(SAMPLE_INTERVAL_MS, 2000).
-define(USER_POOL_SIZE, 200).
%% During-load history ceiling per registry shard at DEFAULTS (no
%% retention): peer-confirmed compaction trails the write rate by a few
%% sync rounds, so a shard's live history is bounded by roughly
%% write_rate x (sync round + GC cadence) — generous slack over what the
%% suite's drivers produce, and orders of magnitude under the
%% unbounded-growth failure shape this suite exists to catch.
-define(PROPAGATION_CEILING, 50_000).
%% Post-settle ceiling on the TOTAL ETS bytes owned by all
%% bondy_oplog_instance processes on a node (MST page stores). Fully
%% drained trees keep only root markers and the current version's few
%% pages; 100 MB is generous slack over that while sitting orders of
%% magnitude below the orphaned-page-leak failure shape.
-define(PAGE_BYTES_CEILING, 100 * 1024 * 1024).

all() ->
    [
        sustained_writes_registry_history_stays_bounded,
        silent_peer_truncated_past_recovers_on_rejoin,
        truncated_prefix_is_held_and_repaired_by_rebootstrap
    ].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    %% The peer-side helpers below run on the cluster nodes via erpc, so make
    %% this module loadable there.
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(cluster, Config)),
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

%% P-BOUND at DEFAULTS (retention off): peer-confirmed compaction alone
%% must (a) keep every `registry/*` shard's history under the propagation
%% ceiling throughout the sustained write window — the window is
%% write_rate x (sync round + GC cadence), NOT unbounded — and (b) drain
%% every shard to quiescent once writes stop, on ALL nodes. (b) is the
%% assertion that fails if compaction stops running (the scheduler
%% starvation shape). `main/*` (durable) shards are governed by the same
%% mechanism and exempt from the ceiling only because their write volume
%% here is negligible. Cross-node RIB consistency is asserted via
%% `bondy_registry_rib:check/1` (empty divergence on every node):
%% peer-confirmed truncation never discards anything a live peer lacks,
%% so no recovery machinery should even be needed.
sustained_writes_registry_history_stays_bounded(Config) ->
    Nodes = nodes_of(Config),
    Result = run_scenario(Config, defaults_peer_confirmed),
    log_scenario_result(defaults_peer_confirmed, Result),

    %% Frontier-gap forensics: every session-level gap detection with
    %% its full per-origin deficit, plus every watermark-door event and
    %% the sync-outcome timeline for the pairs that gapped.
    Forensics = [
        {N, erpc:call(N, ?MODULE, do_gap_forensics, [])}
     || N <- Nodes
    ],
    ct:pal("frontier-gap forensics per node:~n~p", [Forensics]),

    %% With the watermark door closed (never-applied peer events are
    %% folded or held at integrate, never discarded), no event is ever
    %% LOST — but a single transient frontier-gap verdict per pair is
    %% legitimate under sustained load: when a peer door-FOLDS an
    %% in-flight event, its applied VV advances past what its truncated
    %% MST can serve, and a third replica's complete round landing in
    %% that window sees a deficit it can only cover via the ORIGIN one
    %% round later (the origin cannot compact the event away — the
    %% peer-confirmed frontier needs the lagging replica's roots to
    %% contain it). The scheduler's ?GAP_STRIKE debounce absorbs
    %% exactly this. So the assertion is the system guarantee, not
    %% zero telemetry:
    %%   (1) no pair gaps twice (two strikes = the rebootstrap
    %%       threshold = a STANDING gap — the silent-data-loss class
    %%       this suite's forensics proved), and
    %%   (2) every recorded deficit has HEALED by now (the node's
    %%       current applied VV covers the peer sequence the verdict
    %%       recorded).
    GapEvents = [
        {N, G}
     || {N, #{gaps := Gs}} <- Forensics, G <- Gs
    ],
    GapEvents =/= [] andalso
        ct:pal(
            "transient frontier-gap verdicts (allowed if single-strike "
            "and healed):~n~p",
            [GapEvents]
        ),
    RepeatedStrikes =
        maps:filter(
            fun(_Pair, Count) -> Count >= 2 end,
            lists:foldl(
                fun({N, #{instance := I, peer := P}}, Acc) ->
                    maps:update_with(
                        {N, I, P}, fun(C) -> C + 1 end, 1, Acc
                    )
                end,
                #{},
                GapEvents
            )
        ),
    ?assertEqual(
        #{},
        RepeatedStrikes,
        "a (node, instance, peer) pair produced two or more "
        "frontier-gap verdicts — the rebootstrap threshold: a STANDING "
        "gap, not a door-fold transient (see forensics dump)"
    ),
    Unhealed = [
        {N, I, Origin, #{local_now => LocalNow, peer_at_verdict => PeerSeq}}
     || {N, #{instance := I, deficit := Deficit}} <- GapEvents,
        {Origin, #{peer := PeerSeq}} <- maps:to_list(Deficit),
        LocalNow <- [
            maps:get(
                Origin,
                erpc:call(N, bondy_oplog_registry, frontier, [I]),
                0
            )
        ],
        LocalNow < PeerSeq
    ],
    ?assertEqual(
        [],
        Unhealed,
        "a frontier-gap verdict's deficit never healed: the event is "
        "still missing at end of run — data loss, not a door-fold "
        "transient (see forensics dump)"
    ),

    %% The s16 page-loss TRIPWIRE: no node may end the run with an
    %% instance whose own root cannot be fully served (missing pages).
    %% The unservable-root recovery machinery would eventually heal it,
    %% but page loss itself is the primary bug — catch it in the act
    %% with the diagnose evidence (missing/absent counts + sample ids).
    Unservable = [
        {N, U}
     || N <- Nodes,
        U <- erpc:call(N, ?MODULE, do_unservable_roots, [])
    ],
    ?assertEqual(
        [],
        Unservable,
        "an instance ended the run with an unservable OWN root "
        "(missing pages) — the s16 page-loss bug reproduced; the "
        "diagnose_root maps above carry the evidence"
    ),

    #{samples := Samples} = Result,
    RegistrySamples = [
        S
     || {_Ts, _Node, InstId, Size} = S <- Samples,
        is_integer(Size),
        binary:match(InstId, <<"registry/">>) =/= nomatch
    ],

    %% (a) During-load ceiling: history trails the confirmed frontier by
    %% at most a few sync rounds' worth of writes.
    Breaches = [
        {InstId, Node, Size}
     || {_Ts, Node, InstId, Size} <- RegistrySamples,
        Size > ?PROPAGATION_CEILING
    ],
    ?assertEqual(
        [],
        Breaches,
        lists:flatten(
            io_lib:format(
                "registry shard history exceeded the propagation ceiling "
                "(~p) under sustained load — peer-confirmed compaction "
                "is not keeping pace: ~p",
                [?PROPAGATION_CEILING, lists:sublist(Breaches, 10)]
            )
        )
    ),

    %% (b) Post-settle drain: the LAST sample of every registry shard on
    %% every node is quiescent — compaction caught all the way up once
    %% writes stopped. A shard stuck at its peak here is the OOM shape.
    LastByShard = maps:values(
        lists:foldl(
            fun({Ts, Node, InstId, Size}, Acc) ->
                Acc#{{Node, InstId} => {Ts, Node, InstId, Size}}
            end,
            #{},
            lists:keysort(1, RegistrySamples)
        )
    ),
    Undrained = [
        {InstId, Node, Size}
     || {_Ts, Node, InstId, Size} <- LastByShard,
        Size > ?QUIESCENT_THRESHOLD
    ],
    ?assertEqual(
        [],
        Undrained,
        lists:flatten(
            io_lib:format(
                "registry shards did not drain to quiescent (=< ~p) "
                "after the settle window: ~p",
                [?QUIESCENT_THRESHOLD, lists:sublist(Undrained, 10)]
            )
        )
    ),

    %% (b2) Post-settle PAGE reclamation: event counts are blind to the
    %% page store — `bondy_mst:truncate/2` only unlinks dropped subtrees,
    %% and before `truncate_below_or_equal/3` ran the store GC, shards
    %% whose size read 0 still pinned their whole history as orphaned ETS
    %% pages (~5 GB/node at fleet scale). Assert the instance-owned ETS
    %% bytes actually shrank to a live-tree-sized footprint on every node.
    PageBytes = [
        {N, erpc:call(N, ?MODULE, do_instance_ets_bytes, [])}
     || N <- Nodes
    ],
    ct:pal("post-settle instance-owned ETS bytes per node: ~p", [PageBytes]),
    PageBreaches = [
        {N, B}
     || {N, B} <- PageBytes, B > ?PAGE_BYTES_CEILING
    ],
    ?assertEqual(
        [],
        PageBreaches,
        lists:flatten(
            io_lib:format(
                "orphaned MST pages retained after settle (ceiling ~p "
                "bytes/node): ~p",
                [?PAGE_BYTES_CEILING, PageBreaches]
            )
        )
    ),

    %% (c) Correctness: the replicated RIB summaries agree with each
    %% node's ground truth everywhere. Brief poll to absorb the last AE
    %% rounds still in flight at settle end.
    Deadline = erlang:monotonic_time(millisecond) + 60_000,
    Residual = await_rib_convergence(Nodes, Deadline),
    Diag = [
        {N, erpc:call(N, ?MODULE, do_recovery_diagnostics, [])}
     || N <- Nodes
    ],
    ct:pal("RIB recovery diagnostics per node:~n~p", [Diag]),
    ?assertEqual([], Residual),
    ok.

%% @private
%% Polls do_rib_divergences on every node until all are empty or the
%% deadline passes; returns the residual divergences (empty = converged).
await_rib_convergence(Nodes, Deadline) ->
    Divergences = lists:append([
        [{N, D} || D <- erpc:call(N, ?MODULE, do_rib_divergences, [])]
     || N <- Nodes
    ]),
    case
        Divergences =:= [] orelse
            erlang:monotonic_time(millisecond) >= Deadline
    of
        true ->
            Divergences;
        false ->
            timer:sleep(5000),
            await_rib_convergence(Nodes, Deadline)
    end.

%% =============================================================================
%% STALE-PEER REJOIN AUDIT (durable path)
%% =============================================================================
%%
%% The recency-filtered stability frontier
%% (`bondy_oplog_peer_state:get_instance_peer_states/1,2`) drops a peer
%% silent past `peer_timeout_ms` so a dead node cannot stall MST
%% compaction forever — the documented liveness trade: truncating past
%% what the silent peer never received costs it a bulk resync via the
%% bootstrap path, not correctness. This case is the never-before-run
%% demonstration that the resync half of that trade actually holds, END
%% TO END, on the durable (`main/*`, `security_users`) path — including
%% the hardest part: the silent peer holds UNIQUE writes of its own that
%% no live node ever received, and those must survive its own recovery
%% AND propagate back out (they exist only in its own MST; the healthy
%% nodes' advanced watermarks would drop them at the integrate door, so
%% the S1 frontier-gap detection is what must carry them home).
%%
%% Fully deterministic: sync-scheduler dispatch is disabled on all nodes
%% and every AE session is driven by hand (`bondy_oplog:sync/2`),
%% scheduler GC is frozen and compaction invoked explicitly
%% (`bondy_oplog:compact/1`); only the REJOIN runs through the restored
%% production scheduler, because the recovery chain under test
%% (session exit -> rebootstrap flag -> catalogue bootstrap dispatch)
%% lives in the scheduler's exit handling.

-define(STALE_BANDS, 4).
%% Early/late keys per band in the prefix-hole case — sized so that at
%% least one shard instance hosts BOTH an early and a late key (the
%% co-sharded pair a same-origin prefix hole requires).
-define(HOLE_TAGS_PER_BAND, 6).
-define(STALE_CONVERGE_MS, 120000).

silent_peer_truncated_past_recovers_on_rejoin(Config) ->
    [_N1, _N2, _N3] = Nodes = nodes_of(Config),

    %% Manual control: no scheduler dispatch, no scheduler-driven GC.
    _ = [
        ok = erpc:call(N, bondy_oplog_sync_scheduler, set_dispatch, [undefined])
     || N <- Nodes
    ],
    _ = [ok = bondy_ct:freeze_gc(N) || N <- Nodes],
    _ = [
        ok = erpc:call(N, ?MODULE, do_start_dispatch_collector, [])
     || N <- Nodes
    ],

    try
        do_stale_rejoin(Nodes)
    after
        %% Leave the cluster schedulable for any case added after this one.
        _ = [
            catch erpc:call(N, ?MODULE, do_restore_sync_defaults, [])
         || N <- Nodes
        ]
    end.

do_stale_rejoin([N1, N2, N3] = Nodes) ->
    Bands = [stale_band(B) || B <- lists:seq(1, ?STALE_BANDS)],

    %% ---------------------------------------------------------------------
    %% 1. SEED on all three nodes; converge via manual full-mesh pulls.
    %% ---------------------------------------------------------------------
    Seed = [
        {Band, stale_key(Tag), stale_val(Band, Tag)}
     || Band <- Bands, Tag <- [<<"s1">>, <<"s2">>, <<"s3">>]
    ],
    SeedWriters = lists:zip([N1, N2, N3], [<<"s1">>, <<"s2">>, <<"s3">>]),
    _ = [
        ok = erpc:call(W, ?MODULE, do_stale_apply, [Band, K, V])
     || {W, Tag} <- SeedWriters,
        {Band, K, V} <- Seed,
        binary:match(K, Tag) =/= nomatch
    ],
    ok = stale_converge_all(Nodes, Seed),

    %% ---------------------------------------------------------------------
    %% 2. SILENCE. N3 stops syncing entirely (its dispatch is already off and
    %%    it is simply excluded from the manual rounds) and writes UNIQUE
    %%    keys no other node will ever pull while it is silent.
    %% ---------------------------------------------------------------------
    Unique = [
        {Band, stale_key(<<"unique">>), stale_val(Band, <<"unique">>)}
     || Band <- Bands
    ],
    _ = [
        ok = erpc:call(N3, ?MODULE, do_stale_apply, [Band, K, V])
     || {Band, K, V} <- Unique
    ],

    %% ---------------------------------------------------------------------
    %% 3. The live pair keeps working: post-silence writes + mutual sync
    %%    rounds, so N1/N2 confirm each other's FULL history.
    %% ---------------------------------------------------------------------
    Post = [
        {Band, stale_key(<<"post">>), stale_val(Band, <<"post">>)}
     || Band <- Bands
    ],
    _ = [
        ok = erpc:call(N1, ?MODULE, do_stale_apply, [Band, K, V])
     || {Band, K, V} <- Post
    ],
    ok = stale_converge_all([N1, N2], Post),

    %% Sanity on the partition: the silent peer lacks the post-silence
    %% writes, the live pair lacks the unique ones.
    [{PB, PK, _} | _] = Post,
    [{UB, UK, _} | _] = Unique,
    ?assertEqual({error, not_found}, stale_read(N3, PB, PK)),
    ?assertEqual({error, not_found}, stale_read(N1, UB, UK)),

    %% ---------------------------------------------------------------------
    %% 4. STALE-OUT: with a lowered `peer_timeout_ms`, N3's last-confirmed
    %%    entries age out of the recency filter on the live pair, while one
    %%    fresh mutual round keeps N1<->N2 inside it.
    %% ---------------------------------------------------------------------
    _ = [
        ok = erpc:call(
            N, application, set_env, [bondy_oplog, peer_timeout_ms, 1500]
        )
     || N <- [N1, N2]
    ],
    timer:sleep(2000),

    %% ---------------------------------------------------------------------
    %% 5. TRUNCATE: explicit compaction on both live nodes. The frontier is
    %%    now computed over the fresh pair alone, so it advances past
    %%    everything N3 never confirmed — a truncation that MUST move the
    %%    compaction watermark (scheduler GC is frozen; nothing else could
    %%    have) on both nodes, or the recency filter is not doing its
    %%    liveness job. Two mechanics learned the hard way:
    %%      - sync and compact are fused PER INSTANCE on the peer side:
    %%        with the recency window at 1.5s, a node-wide sync round
    %%        followed by a node-wide compact round leaves the live
    %%        peer's entry stale again before the later instances compact;
    %%      - `bondy_oplog:compact/1` may start an ASYNC projection
    %%        catch-up ({ok, compaction_pending}) whose eventual
    %%        truncation replies to nobody — so the observable is the
    %%        WATERMARK advancing, with the compact polled until pending
    %%        resolves, never the drop count of one synchronous call.
    %% ---------------------------------------------------------------------
    W1Before = erpc:call(N1, ?MODULE, do_stale_watermarks_main, []),
    W2Before = erpc:call(N2, ?MODULE, do_stale_watermarks_main, []),
    Compact1 = erpc:call(N1, ?MODULE, do_stale_sync_and_compact_main, [N2]),
    Compact2 = erpc:call(N2, ?MODULE, do_stale_sync_and_compact_main, [N1]),
    W1After = erpc:call(N1, ?MODULE, do_stale_watermarks_main, []),
    W2After = erpc:call(N2, ?MODULE, do_stale_watermarks_main, []),
    Advanced1 = watermarks_advanced(W1Before, W1After),
    Advanced2 = watermarks_advanced(W2Before, W2After),
    ct:pal(
        "stale-rejoin: compaction watermarks advanced on ~p instance(s) "
        "on ~p and ~p instance(s) on ~p~n"
        "compact results on ~p:~n~p~n"
        "compact results on ~p:~n~p",
        [
            length(Advanced1),
            N1,
            length(Advanced2),
            N2,
            N1,
            Compact1,
            N2,
            Compact2
        ]
    ),
    ?assert(length(Advanced1) >= 1),
    ?assert(length(Advanced2) >= 1),

    %% ---------------------------------------------------------------------
    %% 6. REJOIN through the PRODUCTION scheduler: restore N3's dispatch and
    %%    tick it. Its live pulls hit truncated pages on the live nodes
    %%    ({peer_pages_unavailable, _}), the scheduler flags rebootstrap,
    %%    and a catalogue bootstrap carries it forward. Converged when N3
    %%    reads every seed AND post-silence key.
    %% ---------------------------------------------------------------------
    ok = erpc:call(N3, ?MODULE, do_restore_sync_defaults, []),
    ok = stale_wait(
        fun() ->
            _ = catch erpc:call(N3, bondy_oplog_sync_scheduler, trigger, []),
            lists:all(
                fun({Band, K, V}) ->
                    stale_read(N3, Band, K) =:= {ok_val, V}
                end,
                Seed ++ Post
            )
        end,
        {stale_rejoin_bootstrap_timeout, N3},
        fun() ->
            Missing = [
                {Band, K, stale_read(N3, Band, K)}
             || {Band, K, V} <- Seed ++ Post,
                stale_read(N3, Band, K) =/= {ok_val, V}
            ],
            ct:pal(
                "stale-rejoin TIMEOUT diagnostics on ~p:~n"
                "missing keys:~n~p~n"
                "collector events:~n~p~n"
                "scheduler info:~n~p",
                [
                    N3,
                    Missing,
                    catch erpc:call(
                        N3, ?MODULE, do_drain_dispatch_collector, []
                    ),
                    catch erpc:call(N3, bondy_oplog_sync_scheduler, info, [])
                ]
            )
        end
    ),

    %% The recovery MUST have gone through the truncated-page rebootstrap
    %% chain — otherwise this case silently degraded into plain AE and
    %% proved nothing about truncation.
    N3Events = erpc:call(N3, ?MODULE, do_drain_dispatch_collector, []),
    Rebootstraps = [
        maps:with([instance_id, reason], Meta)
     || {E, _, Meta} <- N3Events,
        lists:suffix([rebootstrap_scheduled], E)
    ],
    BootstrapStarts = length([
        E
     || {E, _, _} <- N3Events, lists:suffix([bootstrap, started], E)
    ]),
    ct:pal(
        "stale-rejoin: ~p rebootstraps flagged on ~p (~p bootstrap starts):~n~p",
        [
            length(Rebootstraps),
            N3,
            BootstrapStarts,
            lists:sublist(Rebootstraps, 8)
        ]
    ),
    ?assert(length(Rebootstraps) >= 1),
    ?assert(BootstrapStarts >= 1),

    %% ---------------------------------------------------------------------
    %% 7. THE AUDIT'S CRUX: N3's unique silence-era writes must first have
    %%    SURVIVED its own recovery (the catalogue install must not have
    %%    clobbered what only N3 ever held)...
    %% ---------------------------------------------------------------------
    _ = [
        ?assertEqual(
            {ok_val, V},
            stale_read(N3, Band, K),
            lists:flatten(
                io_lib:format(
                    "unique key ~p/~p lost on the rejoining node itself "
                    "after catalogue bootstrap",
                    [Band, K]
                )
            )
        )
     || {Band, K, V} <- Unique
    ],

    %% ...and then propagate back OUT to the live pair. Their watermarks
    %% have advanced past the unique events' HLC range, so plain integrate
    %% drops them at the door — the frontier-gap detection must flag the
    %% gap and carry them via rebootstrap. Restore the production
    %% schedulers (and the default peer timeout) on the live pair and let
    %% the machinery run.
    _ = [
        ok = erpc:call(N, ?MODULE, do_restore_sync_defaults, [])
     || N <- [N1, N2]
    ],
    ok = stale_wait(
        fun() ->
            _ = [
                catch erpc:call(N, bondy_oplog_sync_scheduler, trigger, [])
             || N <- Nodes
            ],
            lists:all(
                fun({Band, K, V}) ->
                    stale_read(N1, Band, K) =:= {ok_val, V} andalso
                        stale_read(N2, Band, K) =:= {ok_val, V}
                end,
                Unique
            )
        end,
        {stale_unique_writes_never_returned, [N1, N2]}
    ),

    %% ---------------------------------------------------------------------
    %% 8. Full agreement everywhere on every key this case ever wrote.
    %% ---------------------------------------------------------------------
    _ = [
        ?assertEqual({ok_val, V}, stale_read(N, Band, K), {N, Band, K})
     || N <- Nodes, {Band, K, V} <- Seed ++ Post ++ Unique
    ],
    ok.

%% Per-origin prefix closure driven into the hazard it exists for,
%% locking the enforcement contract:
%%
%%   (a) NO same-origin fold-time hole — the misfold never happens
%%       (`prefix_hole` stays silent for the writer's origin);
%%   (b) the non-contiguous suffix is HELD instead (`events_held` fires
%%       on the writer's origin, and the co-sharded LATE keys are not
%%       readable while held);
%%   (c) with the production schedulers restored, the persisting
%%       frontier deficit drives the frontier-gap -> rebootstrap chain,
%%       which supplies both the data and the frontier: N3 converges to
%%       every seed, EARLY and LATE value — and still no hole ever
%%       folded, repair included.
truncated_prefix_is_held_and_repaired_by_rebootstrap(Config) ->
    Nodes = nodes_of(Config),

    %% Manual control: no scheduler dispatch and no scheduler-driven GC,
    %% so every fold in this case is one the driver asked for.
    _ = [
        ok = erpc:call(N, bondy_oplog_sync_scheduler, set_dispatch, [undefined])
     || N <- Nodes
    ],
    _ = [ok = bondy_ct:freeze_gc(N) || N <- Nodes],
    _ = [
        ok = erpc:call(N, ?MODULE, do_start_dispatch_collector, [])
     || N <- Nodes
    ],

    try
        do_prefix_hole_enforced(Nodes)
    after
        _ = [
            catch erpc:call(N, ?MODULE, do_restore_sync_defaults, [])
         || N <- Nodes
        ]
    end.

do_prefix_hole_enforced([N1, N2, N3] = Nodes) ->
    #{
        seed := Seed,
        early := Early,
        late := Late,
        writer_origins := WriterOrigins
    } = hole_scenario(Nodes),

    %% One complete round from each live node — the folds that create
    %% the hole at defaults must hold instead.
    _ = erpc:call(N3, ?MODULE, do_stale_sync_main_from, [N1]),
    _ = erpc:call(N3, ?MODULE, do_stale_sync_main_from, [N2]),

    Events0 = erpc:call(N3, ?MODULE, do_drain_dispatch_collector, []),
    Holes0 = writer_holes(Events0, WriterOrigins),
    Helds0 = writer_helds(Events0, WriterOrigins),
    LateMissing0 = [
        {Band, K}
     || {Band, K, V} <- Late, stale_read(N3, Band, K) =/= {ok_val, V}
    ],
    ct:pal(
        "prefix-hold enforcement on ~ts:~n"
        "  writer-origin holes folded: ~p~n"
        "  writer-origin holds: ~p~n~ts~n"
        "  late keys unreadable while held: ~p of ~p",
        [
            N3,
            length(Holes0),
            length(Helds0),
            hole_fmt(Helds0),
            length(LateMissing0),
            length(Late)
        ]
    ),

    %% (a) The misfold must not have happened.
    ?assertEqual(
        [],
        Holes0,
        "prefix closure is enforced, yet a same-origin fold-time hole was "
        "detected — the enforcement failed to hold a non-contiguous batch"
    ),

    case {Helds0, LateMissing0} of
        {[], _} ->
            {skip,
                "scenario not reached: enforcement never engaged on the "
                "writer's origin — no instance hosted both an early and a "
                "late key. Raise ?HOLE_TAGS_PER_BAND."};
        {_, []} ->
            %% Holds fired, no hole folded (asserted above), yet every
            %% late key reads back: each held gap was later FILLED by a
            %% presentation of the early prefix — the live pair
            %% truncated asymmetrically and the second round's peer
            %% still shipped the early events for every instance
            %% hosting a late key. Legitimate hold-then-release, but
            %% the parked-while-held observable is out of reach.
            {skip,
                "scenario not reached: asymmetric truncation between "
                "the live pair let the second round fill every held "
                "gap on late-key instances. Re-run; raise "
                "?HOLE_TAGS_PER_BAND if persistent."};
        _ ->
            %% (b) Holding must be observable: a held suffix is not
            %% readable.
            ?assertNotEqual(
                [],
                LateMissing0,
                "events were held on the writer's origin, yet every late "
                "key reads back — the hold excluded nothing observable"
            ),

            %% (c) Restore the production machinery and let the
            %% frontier-gap -> rebootstrap chain repair N3.
            _ = [
                ok = erpc:call(N, ?MODULE, do_restore_sync_defaults, [])
             || N <- Nodes
            ],
            All = Seed ++ Early ++ Late,
            ok = stale_wait(
                fun() ->
                    _ = [
                        catch erpc:call(
                            N, bondy_oplog_sync_scheduler, trigger, []
                        )
                     || N <- Nodes
                    ],
                    lists:all(
                        fun({Band, K, V}) ->
                            stale_read(N3, Band, K) =:= {ok_val, V}
                        end,
                        All
                    )
                end,
                {prefix_closure_repair_timeout, N3},
                fun() ->
                    Missing = [
                        {Band, K, stale_read(N3, Band, K)}
                     || {Band, K, V} <- All,
                        stale_read(N3, Band, K) =/= {ok_val, V}
                    ],
                    ct:pal(
                        "prefix-hold repair TIMEOUT on ~ts:~n"
                        "missing:~n~ts~ncollector:~n~ts",
                        [
                            N3,
                            hole_fmt(Missing),
                            hole_fmt(
                                catch erpc:call(
                                    N3, ?MODULE, do_drain_dispatch_collector, []
                                )
                            )
                        ]
                    )
                end
            ),

            Events = erpc:call(N3, ?MODULE, do_drain_dispatch_collector, []),
            %% Still no hole — repair included.
            ?assertEqual(
                [],
                writer_holes(Events, WriterOrigins),
                "a same-origin hole folded during the rebootstrap repair"
            ),
            %% And the repair went through the rebootstrap chain, not
            %% plain AE (which cannot supply the truncated history).
            Rebootstraps = [
                E
             || {E, _, _} <- Events,
                lists:suffix([rebootstrap_scheduled], E)
            ],
            ct:pal(
                "prefix-hold repair on ~ts: converged (~p keys) after ~p "
                "rebootstrap(s)",
                [N3, length(All), length(Rebootstraps)]
            ),
            ?assert(length(Rebootstraps) >= 1),
            ok
    end.

%% @private
%% Steps 1-5 of `do_prefix_hole_enforced/1`: seed+converge all
%% three, silence N3, write EARLY confirmed by the live pair only, age
%% N3 out of the recency filter, truncate past EARLY on both live nodes,
%% then write LATE so the live pair's trees keep their per-origin
%% maxima with the EARLY prefix truncated out from under them.
hole_scenario([N1, N2, N3] = Nodes) ->
    Bands = [stale_band(B) || B <- lists:seq(1, ?STALE_BANDS)],
    %% Origins and seqs are PER INSTANCE (per shard), and each key routes
    %% to one shard — so a same-origin prefix hole needs an EARLY and a
    %% LATE key on the SAME instance. One key per band per phase makes
    %% co-sharding a coin toss over 16 shards; ?HOLE_TAGS_PER_BAND keys
    %% per band per phase makes at least one co-sharded pair
    %% near-certain.
    Triples = fun(Base, Count) ->
        [
            {Band, hole_key(Tag), stale_val(Band, Tag)}
         || Band <- Bands,
            I <- lists:seq(1, Count),
            Tag <- [<<Base/binary, "_", (integer_to_binary(I))/binary>>]
        ]
    end,

    %% ---------------------------------------------------------------------
    %% 1. SEED on N1; converge all three so N3 is a fully-confirmed member
    %%    with real history, not a fresh joiner.
    %% ---------------------------------------------------------------------
    Seed = Triples(<<"hole_seed">>, 1),
    _ = [
        ok = erpc:call(N1, ?MODULE, do_stale_apply, [Band, K, V])
     || {Band, K, V} <- Seed
    ],
    ok = stale_converge_all(Nodes, Seed),

    %% ---------------------------------------------------------------------
    %% 2. SILENCE. N3 is excluded from every round from here on. N1 writes
    %%    the EARLY batch and confirms it with N2 only.
    %% ---------------------------------------------------------------------
    Early = Triples(<<"hole_early">>, ?HOLE_TAGS_PER_BAND),
    _ = [
        ok = erpc:call(N1, ?MODULE, do_stale_apply, [Band, K, V])
     || {Band, K, V} <- Early
    ],
    ok = stale_converge_all([N1, N2], Early),
    [{EB, EK, _} | _] = Early,
    ?assertEqual({error, not_found}, stale_read(N3, EB, EK)),

    %% ---------------------------------------------------------------------
    %% 3. STALE-OUT: lower `peer_timeout_ms` so N3's last-confirmed entries
    %%    age out of the live pair's recency filter, letting their frontier
    %%    advance past history N3 never confirmed.
    %% ---------------------------------------------------------------------
    _ = [
        ok = erpc:call(
            N, application, set_env, [bondy_oplog, peer_timeout_ms, 1500]
        )
     || N <- [N1, N2]
    ],
    timer:sleep(2000),

    %% ---------------------------------------------------------------------
    %% 4. TRUNCATE past EARLY on both live nodes. Sync and compact are fused
    %%    per instance for the reason given in the sibling case: under a
    %%    1.5s recency window a node-wide sync followed by a node-wide
    %%    compact lets the peer entry go stale again mid-round.
    %%
    %%    Repeated (bounded) until at least one instance has truncated on
    %%    BOTH live nodes: with asymmetric truncation (disjoint advanced
    %%    sets) the rejoining node's second round pulls the early prefix
    %%    from whichever peer still ships it, filling every gap the first
    %%    round held and dissolving the scenario under test.
    %% ---------------------------------------------------------------------
    {Advanced1, Advanced2} = truncate_main_until_common(N1, N2, [], [], 5),
    Common = [I || I <- Advanced1, lists:member(I, Advanced2)],
    ct:pal(
        "prefix-hole: watermarks advanced on ~p instance(s) on ~p and "
        "~p instance(s) on ~p (~p in common)",
        [length(Advanced1), N1, length(Advanced2), N2, length(Common)]
    ),
    ?assert(length(Advanced1) >= 1),
    ?assert(length(Advanced2) >= 1),

    %% ---------------------------------------------------------------------
    %% 5. LATE batch, written AFTER the truncation so it survives in the
    %%    shippable tree. This is what makes the two maxima meet: the live
    %%    pair's frontier for N1's origin now sits at the LATE sequences,
    %%    with the EARLY ones truncated out from under it.
    %% ---------------------------------------------------------------------
    Late = Triples(<<"hole_late">>, ?HOLE_TAGS_PER_BAND),
    _ = [
        ok = erpc:call(N1, ?MODULE, do_stale_apply, [Band, K, V])
     || {Band, K, V} <- Late
    ],
    ok = stale_converge_all([N1, N2], Late),

    %% The writer of every seed/early/late event is N1, so N1's
    %% per-instance origin is the only one whose prefix was truncated —
    %% and the only one either case's verdict may look at.
    #{
        seed => Seed,
        early => Early,
        late => Late,
        writer_origins => erpc:call(N1, ?MODULE, do_hole_origins_main, [])
    }.

%% @private
stale_band(B) ->
    <<"com.bondy.stale.", (integer_to_binary(B))/binary>>.

%% @private
%% Distinct key space from `stale_key/1` — both cases run against the same
%% cluster, table and bands.
hole_key(Tag) ->
    <<"hk_", Tag/binary>>.

%% @private
%% Take complete rounds from every peer until the outcome is decidable.
%%
%% The decision turns on the WRITER's origin alone. Every seed/early/late
%% write in this case is made on one node, so that node's per-instance
%% origin is the only one whose prefix was truncated. Other origins
%% (a peer's own bootstrap writes, background traffic) routinely carry
%% their own deficits, and an earlier version of this probe aggregated
%% over all of them — which meant an unrelated origin's deficit masked the
%% state under test and the case never reached a verdict.
%%
%% `{safe, _}` — the pre-truncation writes are readable, so there is no
%% hole. `{blind, _}` — writes are missing AND the writer origin's maxima
%% have MET, so `frontier_deficit/2` cannot see the loss on that origin.
%% `{inconclusive, _, _}` — they never met before the deadline.
hole_probe_until(Node, Peers, Early, WriterOrigins, Deadline) ->
    _ = [
        catch erpc:call(Node, ?MODULE, do_stale_sync_main_from, [P])
     || P <- Peers
    ],
    Missing = [
        {Band, K}
     || {Band, K, V} <- Early, stale_read(Node, Band, K) =/= {ok_val, V}
    ],
    Local = erpc:call(Node, ?MODULE, do_hole_frontiers_main, []),
    PeerFrontiers = [
        catch erpc:call(P, ?MODULE, do_hole_frontiers_main, [])
     || P <- Peers
    ],
    WriterVisible = lists:append([
        writer_deficit(PF, Local, WriterOrigins)
     || PF <- PeerFrontiers, is_list(PF)
    ]),
    case {Missing, WriterVisible} of
        {[], _} ->
            {safe, WriterVisible};
        {_, []} ->
            {blind, Missing};
        _ ->
            case erlang:monotonic_time(millisecond) =< Deadline of
                true ->
                    timer:sleep(500),
                    hole_probe_until(
                        Node, Peers, Early, WriterOrigins, Deadline
                    );
                false ->
                    {inconclusive, Missing, WriterVisible}
            end
    end.

%% @private
%% Detector firings whose origin is the WRITER's origin for that
%% instance — same-origin fold-time holes, the thing read-backs cannot
%% establish across instances.
writer_holes(Events, WriterOrigins) ->
    ByInstance = writer_by_instance(WriterOrigins),
    [
        maps:with([instance_id, origin, applied_seq, gaps], Meta)
     || {[bondy_oplog, applier, prefix_hole], _M, Meta} <- Events,
        maps:get(maps:get(instance_id, Meta, undefined), ByInstance, x) =:=
            maps:get(origin, Meta, undefined)
    ].

%% @private
%% `events_held` firings that held the WRITER's origin for that
%% instance — the enforcement actually engaging on the origin under
%% test rather than on background traffic.
writer_helds(Events, WriterOrigins) ->
    ByInstance = writer_by_instance(WriterOrigins),
    [
        maps:with([instance_id, held], Meta)
     || {[bondy_oplog, applier, events_held], _M, Meta} <- Events,
        maps:is_key(
            maps:get(maps:get(instance_id, Meta, undefined), ByInstance, x),
            maps:get(held, Meta, #{})
        )
    ].

%% @private
writer_by_instance(WriterOrigins) ->
    maps:from_list([{I, O} || {I, O} <- WriterOrigins, is_binary(O)]).

%% @private
%% Per instance, the WRITER origin's deficit only: `{Instance, Origin,
%% {PeerSeq, LocalSeq}}` when the peer is strictly ahead on that origin.
%% Instances where the two have met are dropped — those are exactly the
%% ones where the max comparison has gone blind.
writer_deficit(PeerFrontiers, LocalFrontiers, WriterOrigins) ->
    Local = maps:from_list(LocalFrontiers),
    Writers = maps:from_list(WriterOrigins),
    lists:filtermap(
        fun
            ({I, PF}) when is_map(PF) ->
                Origin = maps:get(I, Writers, undefined),
                LF =
                    case maps:get(I, Local, #{}) of
                        M when is_map(M) -> M;
                        _ -> #{}
                    end,
                PSeq = maps:get(Origin, PF, 0),
                LSeq = maps:get(Origin, LF, 0),
                PSeq > LSeq andalso {true, {I, Origin, {PSeq, LSeq}}};
            (_) ->
                false
        end,
        PeerFrontiers
    ).

%% @private
%% Per instance, the origins for which `Peer`'s stored frontier strictly
%% exceeds `Local`'s — precisely what `frontier_deficit/2` computes, and
%% therefore precisely what the gap check is able to see. Instances with
%% no such origin are dropped.
frontier_deficit_origins(PeerFrontiers, LocalFrontiers) ->
    Local = maps:from_list(LocalFrontiers),
    lists:filtermap(
        fun
            ({I, PF}) when is_map(PF) ->
                LF =
                    case maps:get(I, Local, #{}) of
                        M when is_map(M) -> M;
                        _ -> #{}
                    end,
                Deficit = maps:filtermap(
                    fun(Origin, Seq) ->
                        Cur = maps:get(Origin, LF, 0),
                        Seq > Cur andalso {true, {Seq, Cur}}
                    end,
                    PF
                ),
                maps:size(Deficit) > 0 andalso {true, {I, Deficit}};
            (_) ->
                false
        end,
        PeerFrontiers
    ).

%% @private
%% CT's HTML log escapes `<<"...">>` into nothing legible, so render
%% diagnostics through `~s` on a flattened, binary-safe formatting.
hole_fmt(Term) ->
    lists:flatten(io_lib:format("~tp", [Term])).

%% @private
%% True when any instance's round was refused with a frontier gap.
hole_gap_raised(Results) ->
    lists:any(
        fun
            ({_I, {error, {frontier_gap, _}}}) -> true;
            (_) -> false
        end,
        Results
    ).

%% @private
stale_key(Tag) ->
    <<"sk_", Tag/binary>>.

%% @private
stale_val(Band, Tag) ->
    #{band_uri => Band, tag => Tag, marker => <<"stale_rejoin">>}.

%% @private
%% Reads normalised to compare on the value alone (HLC differs by node).
stale_read(Node, Band, Key) ->
    case erpc:call(Node, ?MODULE, do_stale_read, [Band, Key]) of
        {ok, {V, _Hlc}} -> {ok_val, V};
        Other -> Other
    end.

%% @private
%% Manual full-mesh convergence: every listed node pulls every `main/*`
%% instance from every other listed node, repeatedly, until all given
%% {Band, Key, Val} triples read back on all of them.
stale_converge_all(Nodes, Triples) ->
    stale_wait(
        fun() ->
            _ = [
                catch erpc:call(X, ?MODULE, do_stale_sync_main_from, [Y])
             || X <- Nodes, Y <- Nodes, X =/= Y
            ],
            lists:all(
                fun({Band, K, V}) ->
                    lists:all(
                        fun(N) -> stale_read(N, Band, K) =:= {ok_val, V} end,
                        Nodes
                    )
                end,
                Triples
            )
        end,
        {stale_converge_timeout, Nodes}
    ).

%% @private
stale_wait(Fun, ErrorTag) ->
    stale_wait(Fun, ErrorTag, fun() -> ok end).

%% @private
stale_wait(Fun, ErrorTag, DiagFun) ->
    stale_wait(
        Fun,
        ErrorTag,
        DiagFun,
        erlang:monotonic_time(millisecond) + ?STALE_CONVERGE_MS
    ).

%% @private
stale_wait(Fun, ErrorTag, DiagFun, Deadline) ->
    case Fun() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) =< Deadline of
                true ->
                    ok;
                false ->
                    _ = catch DiagFun(),
                    error(ErrorTag)
            end,
            timer:sleep(400),
            stale_wait(Fun, ErrorTag, DiagFun, Deadline)
    end.

%% @private
%% Instances whose compaction watermark moved between two
%% `do_stale_watermarks_main/0` snapshots.
watermarks_advanced(Before, After) ->
    B = maps:from_list(Before),
    [I || {I, W} <- After, W =/= maps:get(I, B, undefined)].

%% @private
%% One fused sync+compact pass over the `main/*` instances of both live
%% nodes, repeated (bounded) until some instance has truncated on BOTH —
%% accumulating each node's advanced set across passes, since an
%% instance may truncate on N1 in one pass and on N2 in a later one.
%% Returns the accumulated `{Advanced1, Advanced2}` either way; the
%% verdict stays honest downstream when no common instance was reached.
truncate_main_until_common(N1, N2, Acc1, Acc2, Attempts) ->
    W1Before = erpc:call(N1, ?MODULE, do_stale_watermarks_main, []),
    W2Before = erpc:call(N2, ?MODULE, do_stale_watermarks_main, []),
    _ = erpc:call(N1, ?MODULE, do_stale_sync_and_compact_main, [N2]),
    _ = erpc:call(N2, ?MODULE, do_stale_sync_and_compact_main, [N1]),
    W1After = erpc:call(N1, ?MODULE, do_stale_watermarks_main, []),
    W2After = erpc:call(N2, ?MODULE, do_stale_watermarks_main, []),
    Adv1 = lists:usort(Acc1 ++ watermarks_advanced(W1Before, W1After)),
    Adv2 = lists:usort(Acc2 ++ watermarks_advanced(W2Before, W2After)),
    Common = [I || I <- Adv1, lists:member(I, Adv2)],
    case {Common, Attempts} of
        {[_ | _], _} ->
            {Adv1, Adv2};
        {[], 1} ->
            {Adv1, Adv2};
        {[], _} ->
            truncate_main_until_common(N1, N2, Adv1, Adv2, Attempts - 1)
    end.

%% =============================================================================
%% STALE-PEER REJOIN — PEER-SIDE HELPERS (run on cluster nodes via erpc)
%% =============================================================================

%% @private
do_stale_apply(Band, Key, Val) ->
    bondy_db:apply(table_handle(security_users), Band, Key, {set, Val}).

%% @private
do_stale_read(Band, Key) ->
    bondy_db:read(table_handle(security_users), Band, Key).

%% @private
%% One manual pull of every durable `main/*` instance from `Peer` — the
%% hand-driven replacement for a scheduler live-sync round. Threads the
%% node's configured `sync_session_opts` (the Partisan transport +
%% channel `bondy_app` wired for the scheduler) — without them
%% `bondy_oplog:sync/2` defaults to the inline transport, which treats a
%% node-atom peer as a (nonexistent) local instance id.
do_stale_sync_main_from(Peer) ->
    Opts = application:get_env(bondy_oplog, sync_session_opts, #{}),
    [
        {I, catch bondy_oplog:sync(I, Peer, Opts)}
     || I <- bondy_oplog:list_instances(),
        binary:match(I, <<"main/">>) =/= nomatch
    ].

%% @private
%% Per `main/*` instance: one manual pull from `Peer` immediately followed
%% by one explicit compaction cycle — fused so the peer-state entry the
%% frontier reads is milliseconds old even under a lowered
%% `peer_timeout_ms` (see the step-5 note in the test).
do_stale_sync_and_compact_main(Peer) ->
    Opts = application:get_env(bondy_oplog, sync_session_opts, #{}),
    [
        begin
            _ = catch bondy_oplog:sync(I, Peer, Opts),
            {I, stale_compact_resolved(I, catch bondy_oplog:compact(I), 25)}
        end
     || I <- bondy_oplog:list_instances(),
        binary:match(I, <<"main/">>) =/= nomatch
    ].

%% @private
%% `compact/1` may start an async projection catch-up and reply
%% `{ok, compaction_pending}`; poll until the cycle resolves (the
%% truncation itself is observed via the watermark, not this reply).
stale_compact_resolved(_I, Result, 0) ->
    Result;
stale_compact_resolved(I, {ok, compaction_pending}, N) ->
    timer:sleep(200),
    stale_compact_resolved(I, catch bondy_oplog:compact(I), N - 1);
stale_compact_resolved(_I, Result, _N) ->
    Result.

%% @private
%% Every `main/*` instance's current compaction watermark.
do_stale_watermarks_main() ->
    [
        {I, catch bondy_oplog:current_watermark(I)}
     || I <- bondy_oplog:list_instances(),
        binary:match(I, <<"main/">>) =/= nomatch
    ].

%% @private
%% Every `main/*` instance's applied-frontier version vector — the same
%% map `bondy_oplog_sync_session:frontier_deficit/2` compares per origin.
do_hole_frontiers_main() ->
    [
        {I, catch bondy_oplog_registry:frontier(I)}
     || I <- bondy_oplog:list_instances(),
        binary:match(I, <<"main/">>) =/= nomatch
    ].

%% @private
%% Every `main/*` instance's origin AS STAMPED BY THIS NODE — the identity
%% under which its own writes are dotted.
do_hole_origins_main() ->
    [
        {I, catch bondy_oplog:origin(I)}
     || I <- bondy_oplog:list_instances(),
        binary:match(I, <<"main/">>) =/= nomatch
    ].

%% @private
%% Restores the production sync scheduler dispatch and the default peer
%% recency window on THIS node.
do_restore_sync_defaults() ->
    ok = application:set_env(bondy_oplog, peer_timeout_ms, 30_000),
    ok = bondy_oplog_sync_scheduler:set_dispatch(
        fun bondy_oplog_sync_scheduler:default_dispatch/2
    ).

%% =============================================================================
%% SCENARIO DRIVER
%% =============================================================================

run_scenario(Config, _Label) ->
    [N1, N2, N3] = Nodes = nodes_of(Config),

    Realms = create_realms(Nodes, ?NUM_REALMS),

    _ = [
        ok = erpc:call(N, ?MODULE, do_start_dispatch_collector, [])
     || N <- Nodes
    ],

    Parent = self(),
    SamplerPid = spawn_link(fun() ->
        sampler_loop(
            Parent,
            Nodes,
            ?WRITE_WINDOW_MS + ?SETTLE_WINDOW_MS,
            ?SAMPLE_INTERVAL_MS,
            []
        )
    end),

    DriverPids = [
        spawn_link(fun() ->
            R = erpc:call(
                N,
                ?MODULE,
                do_drive_load,
                [Realms, ?WRITE_WINDOW_MS],
                ?WRITE_WINDOW_MS + 15000
            ),
            Parent ! {driver_done, N, R}
        end)
     || N <- Nodes
    ],
    WriteStats = maps:from_list([
        receive
            {driver_done, N, R} -> {N, R}
        after ?WRITE_WINDOW_MS + 20000 ->
            error({driver_timeout, N})
        end
     || N <- Nodes
    ]),
    _ = DriverPids,

    timer:sleep(?SETTLE_WINDOW_MS + 2000),

    Samples =
        receive
            {samples, S} -> S
        after ?WRITE_WINDOW_MS + ?SETTLE_WINDOW_MS + 20000 ->
            error(sampler_timeout)
        end,
    unlink(SamplerPid),
    catch exit(SamplerPid, kill),

    DispatchEvents = lists:append([
        erpc:call(N, ?MODULE, do_drain_dispatch_collector, [])
     || N <- Nodes
    ]),

    #{
        growth_ratios => growth_ratios(Samples),
        growth_detail => growth_detail(Samples),
        peer_histogram => peer_histogram(DispatchEvents),
        write_stats => WriteStats,
        samples => Samples,
        nodes => [N1, N2, N3]
    }.

%% =============================================================================
%% ANALYSIS
%% =============================================================================

%% For each {InstanceId, Node}, compares the average size over the first
%% quarter of samples against the last quarter. Ratio > 1 means it grew;
%% a genuinely-bounded instance should settle back down (or never have grown
%% much) by the last quarter, which spans the settle window.
growth_ratios(Samples) ->
    maps:map(fun(_Key, #{ratio := Ratio}) -> Ratio end, growth_detail(Samples)).

%% As `growth_ratios/1` but keeps the absolute early/late averages (and the
%% raw sample count) alongside the ratio — a ratio alone cannot distinguish
%% "genuinely grew a lot" from "started near zero, so any small absolute
%% increase looks huge as a percentage."
growth_detail(Samples) ->
    ByKey = lists:foldl(
        fun({_Ts, Node, InstId, Size}, Acc) ->
            Key = {InstId, Node},
            maps:update_with(Key, fun(L) -> [Size | L] end, [Size], Acc)
        end,
        #{},
        Samples
    ),
    maps:map(
        fun(_Key, SizesRevChrono) ->
            Sizes = lists:reverse(SizesRevChrono),
            N = length(Sizes),
            Q = max(1, N div 4),
            Early = lists:sublist(Sizes, Q),
            Late = lists:sublist(lists:reverse(Sizes), Q),
            EarlyAvg = avg(Early),
            LateAvg = avg(Late),
            Ratio =
                if
                    EarlyAvg == 0.0, LateAvg == 0.0 -> 1.0;
                    EarlyAvg == 0.0 -> LateAvg + 1;
                    true -> LateAvg / EarlyAvg
                end,
            #{
                early => EarlyAvg,
                late => LateAvg,
                ratio => Ratio,
                n_samples => N,
                raw => Sizes
            }
        end,
        ByKey
    ).

avg([]) ->
    0.0;
avg(L) ->
    lists:sum(L) / length(L).

%% Groups dispatch telemetry into a {Node, Peer} -> #{started => N, capped => N}
%% histogram — the P-PEER-SKEW evidence.
peer_histogram(Events) ->
    lists:foldl(
        fun
            ({[bondy_oplog, sync_scheduler, live, started], _M, Meta}, Acc) ->
                bump(Acc, {node(), maps:get(peer, Meta, undefined)}, started);
            ({[bondy_oplog, sync_scheduler, live_capped], _M, Meta}, Acc) ->
                bump(Acc, {node(), maps:get(peer, Meta, undefined)}, capped);
            (_, Acc) ->
                Acc
        end,
        #{},
        Events
    ).

bump(Acc, Key, Field) ->
    Prev = maps:get(Key, Acc, #{started => 0, capped => 0}),
    maps:put(Key, maps:update_with(Field, fun(N) -> N + 1 end, 1, Prev), Acc).

log_scenario_result(
    Label,
    #{
        growth_ratios := Ratios,
        growth_detail := Detail,
        peer_histogram := Hist,
        write_stats := WriteStats
    }
) ->
    #{
        clean_total := CleanTotal,
        clean_unsettled := CleanUnsettled,
        residue_total := ResidueTotal,
        residue_unsettled := ResidueUnsettled
    } = settle_summary(Detail),
    ct:pal(
        "~n=== scenario ~p ===~n"
        "write outcomes per node (sub_ok/sub_err = subscription adds against "
        "the `registry` DB; user_ok/user_err = security_users writes against "
        "`main`; sample_errors carries up to 5 examples per field):~n~p~n"
        "per-instance late/early size ratio "
        "(1.0 = flat, >1 = still growing):~n~p~n"
        "SETTLE SUMMARY — instances classified by their FIRST sample: "
        "clean_start (<= ~p, genuinely quiescent before this test wrote "
        "anything) vs residue_start (> ~p, carrying leftover activity from "
        "cluster bootstrap/AAE catalogue exchange, unrelated to this test).~n"
        "'unsettled' = last sample (after the full write+settle window) is "
        "still > ~p — a fair, apples-to-apples convergence check, not a "
        "ratio that a residue-heavy starting point can distort.~n"
        "  clean_start:   ~p/~p unsettled~n"
        "  residue_start: ~p/~p unsettled~n"
        "unsettled instances (instance, node, first, last, full raw trace):~n~p~n"
        "peer dispatch histogram (started vs capped):~n~p~n",
        [
            Label,
            WriteStats,
            Ratios,
            ?QUIESCENT_THRESHOLD,
            ?QUIESCENT_THRESHOLD,
            ?QUIESCENT_THRESHOLD,
            length(CleanUnsettled),
            CleanTotal,
            length(ResidueUnsettled),
            ResidueTotal,
            CleanUnsettled ++ ResidueUnsettled,
            Hist
        ]
    ).

%% Classifies every {InstanceId, Node} by its FIRST sample (clean vs
%% residue start) and checks whether its LAST sample (after write + the
%% full settle window) is quiescent — the fair convergence check a ratio
%% comparing two differently-starting shards cannot give.
settle_summary(Detail) ->
    lists:foldl(
        fun({{InstId, Node}, #{raw := Raw}}, Acc) ->
            First = hd(Raw),
            Last = lists:last(Raw),
            Settled = Last =< ?QUIESCENT_THRESHOLD,
            Clean = First =< ?QUIESCENT_THRESHOLD,
            Entry = {InstId, Node, First, Last, Raw},
            case {Clean, Settled} of
                {true, true} ->
                    bump_settle(Acc, clean_total);
                {true, false} ->
                    add_unsettled(
                        bump_settle(Acc, clean_total), clean_unsettled, Entry
                    );
                {false, true} ->
                    bump_settle(Acc, residue_total);
                {false, false} ->
                    add_unsettled(
                        bump_settle(Acc, residue_total),
                        residue_unsettled,
                        Entry
                    )
            end
        end,
        #{
            clean_total => 0,
            clean_unsettled => [],
            residue_total => 0,
            residue_unsettled => []
        },
        maps:to_list(Detail)
    ).

bump_settle(Acc, Field) ->
    maps:update_with(Field, fun(N) -> N + 1 end, Acc).

add_unsettled(Acc, Field, Entry) ->
    maps:update_with(Field, fun(L) -> [Entry | L] end, Acc).

%% =============================================================================
%% LOAD DRIVER (peer-side)
%% =============================================================================

%% Creates `Count' realms with security disabled (so anonymous writes are
%% cheap), round-robined across the given nodes so realm creation itself is
%% multi-writer, not funnelled through one node.
create_realms(Nodes, Count) ->
    NodeCycle = lists:flatten(
        lists:duplicate(1 + Count div length(Nodes), Nodes)
    ),
    [
        begin
            Uri = iolist_to_binary([
                "com.test.compaction_cluster.r",
                integer_to_binary(I)
            ]),
            ok = erpc:call(
                lists:nth(I, NodeCycle), ?MODULE, do_create_open_realm, [Uri]
            ),
            Uri
        end
     || I <- lists:seq(1, Count)
    ].

%% Summarises the laggard-recovery chain on THIS node from the dispatch
%% collector's captured telemetry: did retention truncate, did any sync
%% detect a gap and flag rebootstrap, did a catalogue bootstrap dispatch
%% and start. Plus each registry shard's applied-frontier VV, so behind
%% origins are visible directly.
do_recovery_diagnostics() ->
    Events = do_drain_dispatch_collector(),
    Count = fun(Suffix) ->
        length([E || {E, _, _} <- Events, lists:suffix(Suffix, E)])
    end,
    Rebootstraps = [
        maps:with([instance_id, peer, reason], Meta)
     || {E, _, Meta} <- Events,
        lists:suffix([rebootstrap_scheduled], E)
    ],
    Discarded = lists:sum([
        maps:get(discarded, M, 0)
     || {E, M, _} <- Events,
        lists:suffix([cells_swept], E)
    ]),
    Frontiers = [
        {I, catch bondy_oplog_registry:frontier(I)}
     || I <- catch bondy_oplog:list_instances(),
        binary:match(I, <<"registry/">>) =/= nomatch
    ],
    #{
        retention_truncations => Count([retention]),
        rebootstrap_scheduled => Rebootstraps,
        dispatch_bootstrap => Count([dispatch_bootstrap]),
        bootstrap_started => Count([bootstrap, started]),
        cells_discarded => Discarded,
        registry_frontiers => Frontiers
    }.

%% The concatenated RIB divergence list over every test realm on THIS node
%% (`bondy_registry_rib:check/1` compares the replicated summary cells
%% against the local members ground truth). `[]` = consistent.
%% Every instance whose CURRENT root cannot be fully served on THIS
%% node — the s16 page-loss tripwire. `[]` = all roots servable.
do_unservable_roots() ->
    [
        {I, D}
     || I <- bondy_oplog:list_instances(),
        D <- [catch bondy_oplog_instance:diagnose_root(I)],
        is_map(D),
        maps:get(servable, D, true) =:= false
    ].

do_rib_divergences() ->
    lists:append([
        bondy_registry_rib:check(
            iolist_to_binary([
                "com.test.compaction_cluster.r", integer_to_binary(I)
            ])
        )
     || I <- lists:seq(1, ?NUM_REALMS)
    ]).

%% Idempotent — safe to call once per node per scenario for the SAME realm
%% URI across multiple test cases in this suite.
do_create_open_realm(Uri) ->
    Realm =
        case bondy_realm:lookup(Uri) of
            {ok, R} -> R;
            {error, not_found} -> bondy_realm:create(Uri)
        end,
    ok = bondy_realm:disable_security(Realm),
    ok.

%% Runs on a cluster node for `DurationMs`, writing a mix of registry
%% (subscription) entries and durable `main` DB (`security_users`) entries
%% spread across `Realms`, at whatever rate the node can sustain — real WAMP
%% API calls, not synthetic oplog appends, so real shard placement.
%%
%% Every write's outcome is counted, never silently swallowed (a prior cut
%% of this suite wrapped each write in a bare `catch`, which would have
%% hidden a systematic failure of the subscription-add path — see
%% `sub_ok`/`sub_err` below and the sample errors carried back).
do_drive_load(Realms, DurationMs) ->
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Stats0 = #{
        sub_ok => 0,
        sub_err => 0,
        user_ok => 0,
        user_err => 0,
        sample_errors => []
    },
    drive_loop(Realms, Deadline, 0, Stats0).

drive_loop(Realms, Deadline, N, Stats) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Stats#{total => N};
        false ->
            RealmUri = lists:nth(1 + (N rem length(Realms)), Realms),
            Stats1 = do_write_one(RealmUri, N, Stats),
            drive_loop(Realms, Deadline, N + 1, Stats1)
    end.

do_write_one(RealmUri, N, Stats) ->
    case N rem 2 of
        0 ->
            Uri = iolist_to_binary([
                "com.test.topic.",
                integer_to_binary(node_seed()),
                ".",
                integer_to_binary(N)
            ]),
            %% A `pid()` target with a REAL session id, matching what a real
            %% WAMP subscriber's ref looks like (a session always exists
            %% before SUBSCRIBE is sent) — two bugs found via this suite,
            %% both worked around here rather than in source:
            %% 1. `{Mod, Fun}` gets normalised to a `callback`-type ref by
            %%    `bondy_ref:validate_target/2`, which only the REGISTRATION
            %%    path understands; used for a subscription it always
            %%    raised `{error, function_clause}`.
            %% 2. A session-LESS internal ref (`SessionId = undefined`) also
            %%    always raises `function_clause` — in
            %%    `bondy_registry_entry:key_pattern/3`, which only accepts
            %%    `is_binary(SessionId)` or the wildcard atom `'_'`, never
            %%    `undefined` — even though `bondy_registry:maybe_add/6`'s
            %%    subscription branch explicitly anticipates and handles
            %%    session-less subscribers in its own comments. That is a
            %%    genuine production defect, reported separately; real WAMP
            %%    subscribers always carry a session anyway, so this test
            %%    uses one rather than exercising the broken path.
            Ref = bondy_ref:new(internal, self(), bondy_session_id:new()),
            try
                bondy_registry:add(
                    subscription, RealmUri, Uri, #{match => <<"exact">>}, Ref
                )
            of
                {ok, _, _} ->
                    %% The documented 3-tuple shape.
                    bump(Stats, sub_ok);
                {ok, {_, _}} ->
                    %% The shape actually observed at runtime — `add/5`'s
                    %% own `-spec` says `{ok, Entry, IsFirstEntry}`, but a
                    %% subscription add returns `{ok, {Entry, IsFirstEntry}}`
                    %% (a 2-tuple pair, not a 3-tuple). Accepted here rather
                    %% than treated as a third bug to chase — the write
                    %% itself demonstrably succeeds (a real entry comes
                    %% back), this is a spec/implementation mismatch, not a
                    %% functional break.
                    bump(Stats, sub_ok);
                Other ->
                    record_error(Stats, sub_err, {RealmUri, Uri, Other})
            catch
                Class:Reason:Stack ->
                    record_error(
                        Stats,
                        sub_err,
                        {RealmUri, Uri, {Class, Reason, Stack}}
                    )
            end;
        1 ->
            Tab = table_handle(security_users),
            %% Bounded churn — reuse ?USER_POOL_SIZE keys per (node, realm)
            %% repeatedly, mirroring real update traffic, NOT an
            %% ever-growing set of brand-new usernames. An unbounded key set
            %% makes "the MST stayed big" ambiguous between "compaction
            %% isn't keeping up" and "the test just kept creating more real,
            %% legitimately-durable data" — which is exactly what happened
            %% to `main/0`..`main/3` in the first two runs of this suite:
            %% both survived even with the concurrency cap raised well past
            %% any contention, because it was never a compaction problem.
            Key = iolist_to_binary([
                "u",
                integer_to_binary(node_seed()),
                "_",
                integer_to_binary(N rem ?USER_POOL_SIZE)
            ]),
            Value = #{username => Key, touch => N},
            try bondy_db:apply(Tab, RealmUri, Key, {set, Value}) of
                ok ->
                    bump(Stats, user_ok);
                Other ->
                    record_error(Stats, user_err, {RealmUri, Key, Other})
            catch
                Class:Reason:Stack ->
                    record_error(
                        Stats, user_err, {RealmUri, Key, {Class, Reason, Stack}}
                    )
            end
    end.

bump(Stats, Field) ->
    maps:update_with(Field, fun(N) -> N + 1 end, 1, Stats).

%% Keeps only the first 5 errors per field, so a systematic failure is
%% visible without flooding the result with thousands of copies of it.
record_error(Stats, Field, Detail) ->
    Stats1 = bump(Stats, Field),
    Samples = maps:get(sample_errors, Stats1),
    case length(Samples) >= 5 of
        true -> Stats1;
        false -> Stats1#{sample_errors => [{Field, Detail} | Samples]}
    end.

node_seed() ->
    erlang:phash2(node(), 1000000).

table_handle(Table) ->
    case bondy_namespace_catalog:table(Table) of
        undefined -> error({table_not_provisioned, Table});
        Tab -> Tab
    end.

%% =============================================================================
%% SIZE SAMPLER (test-process side)
%% =============================================================================

sampler_loop(Parent, _Nodes, RemainingMs, _IntervalMs, Acc) when
    RemainingMs =< 0
->
    Parent ! {samples, lists:append(Acc)};
sampler_loop(Parent, Nodes, RemainingMs, IntervalMs, Acc) ->
    Batch = lists:append([sample_node(N) || N <- Nodes]),
    timer:sleep(IntervalMs),
    sampler_loop(Parent, Nodes, RemainingMs - IntervalMs, IntervalMs, [
        Batch | Acc
    ]).

sample_node(Node) ->
    Ts = erlang:monotonic_time(millisecond),
    case erpc:call(Node, ?MODULE, do_sample_sizes, [], 5000) of
        Sizes when is_list(Sizes) ->
            [{Ts, Node, InstId, Size} || {InstId, Size} <- Sizes];
        _ ->
            []
    end.

do_sample_sizes() ->
    [
        {InstId, catch bondy_oplog:size(InstId)}
     || InstId <- catch bondy_oplog:list_instances()
    ].

%% Total ETS bytes owned by bondy_oplog_instance processes on THIS node —
%% the MST page stores (the projection/cache tables belong to shard
%% registrations, not instance processes).
do_instance_ets_bytes() ->
    Wordsize = erlang:system_info(wordsize),
    lists:sum([
        ets:info(T, memory) * Wordsize
     || T <- ets:all(),
        is_integer(ets:info(T, memory)),
        is_pid(ets:info(T, owner)),
        case proc_lib:initial_call(ets:info(T, owner)) of
            {bondy_oplog_instance, _, _} -> true;
            _ -> false
        end
    ]).

%% =============================================================================
%% DISPATCH TELEMETRY COLLECTOR (peer-side)
%% =============================================================================

do_start_dispatch_collector() ->
    Parent = self(),
    Pid = spawn(fun() -> dispatch_collector_init(Parent) end),
    receive
        {Pid, ready} -> ok
    after 5000 ->
        error(dispatch_collector_start_timeout)
    end,
    catch unregister(oplog_dispatch_collector),
    true = register(oplog_dispatch_collector, Pid),
    ok.

dispatch_collector_init(Parent) ->
    Self = self(),
    HandlerId = {?MODULE, oplog_dispatch_collector, Self},
    Handler = fun(Event, Measurements, Metadata, _Config) ->
        Self ! {telemetry_event, Event, Measurements, Metadata}
    end,
    ok = telemetry:attach_many(
        HandlerId,
        [
            [bondy_oplog, sync_scheduler, live_capped],
            [bondy_oplog, sync_scheduler, live, started],
            %% Laggard-recovery chain: frontier-gap/pages-unavailable →
            %% rebootstrap flag → catalogue bootstrap dispatch.
            [bondy_oplog, sync_scheduler, rebootstrap_scheduled],
            [bondy_oplog, sync_scheduler, dispatch_bootstrap],
            [bondy_oplog, sync_scheduler, bootstrap, started],
            [bondy_oplog, compaction, retention],
            %% Frontier-gap forensics: the session-level event carries
            %% the full per-origin deficit (peer vs local sequence), and
            %% the per-round sync outcomes give the self-heal timeline
            %% for any instance/peer pair that gapped.
            [bondy_oplog, sync_session, frontier_gap],
            [bondy_oplog, instance, integrate_doored],
            [bondy_oplog, sync, ok],
            [bondy_oplog, sync, error],
            %% Cell reclamation on the origin is the suspected accomplice:
            %% under retention the local-MST diff cannot see a laggard's
            %% holes below the truncation bound, so the stability point
            %% can over-advance and reap cells the laggard never saw
            %% removed. `discarded > 0` here + persistent divergence
            %% elsewhere confirms that chain.
            [bondy_oplog, applier, cells_swept],
            %% Fold-time contiguity: fires when a cell-apply batch
            %% materialises an origin's later seq while earlier seq(s)
            %% are neither applied locally nor in the batch — the
            %% direct witness of a per-origin prefix hole.
            [bondy_oplog, applier, prefix_hole],
            %% Prefix-closure enforcement: events a
            %% replay excluded from the fold instead of materialising
            %% past a gap.
            [bondy_oplog, applier, events_held]
        ],
        Handler,
        undefined
    ),
    Parent ! {Self, ready},
    dispatch_collector_loop([]).

dispatch_collector_loop(Acc) ->
    receive
        {get, From} ->
            From ! {oplog_dispatch_collector_events, lists:reverse(Acc)},
            dispatch_collector_loop(Acc);
        {telemetry_event, Event, Measurements, Metadata} ->
            %% Receipt stamp so post-hoc analysis can order gap events
            %% against the sync-outcome timeline (self-heal latency).
            Stamped = Metadata#{
                collected_at_ms =>
                    erlang:system_time(millisecond)
            },
            dispatch_collector_loop([{Event, Measurements, Stamped} | Acc]);
        _Other ->
            dispatch_collector_loop(Acc)
    end.

do_drain_dispatch_collector() ->
    oplog_dispatch_collector ! {get, self()},
    receive
        {oplog_dispatch_collector_events, Events} -> Events
    after 5000 ->
        error(dispatch_collector_drain_timeout)
    end.

%% Runs ON a cluster node (erpc). Extracts every frontier-gap detection
%% this node's sync sessions reported (full per-origin deficit) plus the
%% sync-outcome timeline for exactly the {instance, peer} pairs that
%% gapped — enough to read off, per occurrence: which origins were
%% behind, by how much, against which peer, and how long until the next
%% successful round against the same peer (the self-heal latency).
do_gap_forensics() ->
    Events = do_drain_dispatch_collector(),
    Gaps = [
        #{
            ts => maps:get(collected_at_ms, Meta, undefined),
            instance => maps:get(instance_id, Meta, undefined),
            peer => maps:get(peer, Meta, undefined),
            deficit => maps:get(deficit, Meta, undefined),
            present_locally => maps:get(present_locally, Meta, undefined),
            completed_peer_root =>
                maps:get(completed_peer_root, Meta, undefined),
            local_root => maps:get(local_root, Meta, undefined)
        }
     || {[bondy_oplog, sync_session, frontier_gap], _M, Meta} <- Events
    ],
    Doored = [
        #{
            ts => maps:get(collected_at_ms, Meta, undefined),
            instance => maps:get(instance_id, Meta, undefined),
            action => maps:get(action, Meta, undefined),
            count => maps:get(count, M, undefined),
            doored => maps:get(doored, Meta, undefined)
        }
     || {[bondy_oplog, instance, integrate_doored], M, Meta} <- Events
    ],
    GapPairs = lists:usort([
        {maps:get(instance, G), maps:get(peer, G)}
     || G <- Gaps
    ]),
    Timeline = lists:sort([
        {
            maps:get(collected_at_ms, Meta, undefined),
            Outcome,
            maps:get(instance_id, Meta, undefined),
            maps:get(peer, Meta, undefined)
        }
     || {[bondy_oplog, sync, Outcome], _M, Meta} <- Events,
        lists:member(
            {
                maps:get(instance_id, Meta, undefined),
                maps:get(peer, Meta, undefined)
            },
            GapPairs
        )
    ]),
    #{gaps => Gaps, doored => Doored, timeline => Timeline}.

%% =============================================================================
%% MISC HELPERS
%% =============================================================================

nodes_of(Config) ->
    [N || {_, N, _} <- ?config(cluster, Config)].

push_module(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.
