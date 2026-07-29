%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_frontier_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

%% A 2-node Partisan cluster (bondy_db AAE on) that proves the applied-frontier
%% version vector (`bondy_oplog_instance:frontier/1`) is a faithful cross-node
%% convergence oracle where the MST root is NOT — specifically under ASYMMETRIC
%% compaction, the failure mode the root cannot survive:
%%
%%   - FALSE DIVERGED: one node compacts (empty MST ⇒ `undefined` root) while the
%%     other has not (full MST ⇒ binary root) for IDENTICAL data. An MST-root
%%     comparison reports DIVERGED; the frontier is compaction-invariant, stays
%%     equal, and reports IN SYNC. `asymmetric_compaction_keeps_oracle_in_sync`.
%%   - FALSE IN SYNC (the dangerous one): once BOTH nodes compact, both roots are
%%     `undefined`, so a root comparison reports IN SYNC with nothing actually
%%     verifying the projections match. The frontier still genuinely agrees when
%%     they match (equal AND non-empty) AND detects a real divergence injected
%%     while both roots stay `undefined`.
%%     `both_compacted_frontier_detects_real_divergence`.
%%
%% Both tests drive the PRODUCTION paths: writes through `bondy_db`, the live
%% per-instance frontier (`bondy_oplog_instance:frontier/1`), and the peer
%% frontier fetched over the AAE Partisan transport with the `get_frontier`
%% request — the same request `bondy_observer_cli_sync` uses. The sync scheduler
%% is quiesced (`set_dispatch(undefined)`) for the compaction phases so the
%% asymmetric state stays frozen: a live scheduler would re-pull the compacted
%% node's MST back from its peer, which is the very false-DIVERGED re-pull the
%% frontier oracle exists to avoid.

-define(NODE_NAMES, [cfront1, cfront2]).
-define(USERS_TABLE, security_users).
%% security_users shards by realm, so distinct realm bands spread across shard
%% instances (`phash2(realm_prefix, ShardCount)`) — giving several data-bearing
%% compaction targets rather than a single shard.
-define(BANDS, 16).
%% Generous so the convergence assertions stay robust under CT load (200ms tick).
%% Belt-and-suspenders alongside the patient root-hash reads in
%% `do_instance_sigs/0`: even if convergence is genuinely slow under a loaded
%% full-CT run, the barrier waits it out rather than failing.
-define(CONVERGE_MS, 120000).

%% Root-hash call timeout for `do_instance_sigs/0` — wide enough that a
%% CPU-starved but live instance under full-CT load still answers with its
%% (binary) root instead of the swallowed `undefined` that flaked the barrier.
-define(ROOT_HASH_TIMEOUT_MS, 30000).

all() ->
    [
        asymmetric_compaction_keeps_oracle_in_sync,
        both_compacted_frontier_detects_real_divergence
    ].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    %% The peer-side helpers below run on the cluster nodes, so make this module
    %% loadable there.
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Nodes],
    %% Freeze scheduler-driven GC for the WHOLE suite, before any writes.
    %% Both tests compact explicitly (`do_compact`) and assert on which
    %% node's MSTs are truncated; a background compaction tick landing
    %% during seeding truncates one node's MST ahead of the baseline
    %% snapshot — equal frontiers, unequal roots, the intermittent step-3
    %% `R1 =:= R2` failure — and can even empty the deliberately-UNCOMPACTED
    %% node's roots. Convergence needs only the sync scheduler, not GC.
    _ = [bondy_ct:freeze_gc(Node) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(cluster, Config)),
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

%% Asymmetric compaction: write + converge identical data on both nodes, then
%% compact node 1's shards ONLY. Node 1's MSTs go empty (`undefined` root) while
%% node 2 keeps its full binary roots — so an MST-root comparison reports
%% DIVERGED for identical data (the false-DIVERGED failure mode). The frontier is
%% compaction-invariant, so it is UNCHANGED by the compaction and still equal
%% across nodes — locally and over the `get_frontier` transport — reporting IN
%% SYNC, which is correct.
asymmetric_compaction_keeps_oracle_in_sync(Config) ->
    [N1, N2] = nodes_of(Config),
    Pairs = seed_pairs(<<"asym">>),

    %% 1. Write through bondy_db on N1, converge to N2 via background AAE.
    seed_and_converge(N1, N2, Pairs),

    try
        %% 2. Select targets and let the ROOTS pairwise-converge BEFORE the
        %% freeze. Frontier adoption runs ahead of MST page transfer (a live
        %% round adopts the peer's applied-frontier VV even for events whose
        %% pages arrive on a later round), so "equal frontiers, unequal
        %% roots" is a normal in-between state — the intermittent `R1 =:= R2`
        %% failure here. Freezing first PINS that state forever; the barrier
        %% must run while sync can still deliver the lagging pages. Errors
        %% with per-node diagnostics if the roots genuinely never equalise.
        Sigs1a = erpc:call(N1, ?MODULE, do_instance_sigs, []),
        Sigs2a = erpc:call(N2, ?MODULE, do_instance_sigs, []),
        Targets = converged_data_targets(Sigs1a, Sigs2a),
        ct:pal("asym: ~p data-bearing converged target instances", [
            length(Targets)
        ]),
        ?assert(length(Targets) >= 1),
        {_, _} = await_pairwise_sigs(N1, N2, Targets),

        %% 3. NOW freeze the cluster: a live scheduler would re-pull a
        %% compacted node's MST back from its peer (the false-DIVERGED
        %% re-pull). Drain in-flight appliers, then re-read the settled
        %% baseline — nothing mutates events after the freeze (GC is frozen
        %% suite-wide, seeding is done), so this settles immediately.
        quiesce(N1, N2),
        ok = erpc:call(N1, ?MODULE, do_drain_all, []),
        ok = erpc:call(N2, ?MODULE, do_drain_all, []),
        %% Frozen: do NOT drive sync here (a trigger would re-pull and defeat the
        %% quiesce); the drained baseline settles on its own.
        {Sigs1, Sigs2} = await_pairwise_sigs(N1, N2, Targets, false),

        lists:foreach(
            fun(I) ->
                {F1, R1} = maps:get(I, Sigs1),
                {F2, R2} = maps:get(I, Sigs2),
                ?assertEqual(F1, F2),
                ?assertEqual(R1, R2),
                ?assert(is_binary(R1)),
                %% Over the transport: N1 asks N2 and N2 asks N1; each sees the
                %% other's frontier, and it equals the local one.
                ?assertEqual(F2, peer_frontier(N1, I)),
                ?assertEqual(F1, peer_frontier(N2, I)),
                ?assert(oracle_in_sync(N1, I))
            end,
            Targets
        ),

        %% 4. ASYMMETRIC COMPACTION: compact N1's instances only.
        lists:foreach(
            fun(I) ->
                ?assertMatch({ok, _}, erpc:call(N1, ?MODULE, do_compact, [I]))
            end,
            Targets
        ),

        %% N1 was compacted (roots settle to `undefined`); N2 was not (roots
        %% stay binary). Snapshot each side at its steady state so a `root_hash/1`
        %% call that transiently times out under CT load — swallowed to
        %% `undefined` by `do_instance_sigs/1` — cannot flake the root assertions.
        Sigs1b = await_instance_sigs(N1, Targets, fun(R) -> R =:= undefined end),
        Sigs2b = await_instance_sigs(N2, Targets, fun erlang:is_binary/1),

        lists:foreach(
            fun(I) ->
                {F1, _} = maps:get(I, Sigs1),
                {F1b, R1b} = maps:get(I, Sigs1b),
                {F2b, R2b} = maps:get(I, Sigs2b),

                %% The false-DIVERGED trigger: N1's MST is empty (`undefined`
                %% root) while N2 still holds the full binary root — an MST-root
                %% comparison would report DIVERGED for identical data.
                ?assertEqual(undefined, R1b),
                ?assert(is_binary(R2b)),
                ?assertNotEqual(R1b, R2b),

                %% The oracle is correct: compaction did not touch the frontier,
                %% so it is unchanged and still equal across nodes — locally and
                %% over the transport — i.e. IN SYNC.
                ?assertEqual(F1, F1b),
                ?assertEqual(F1b, F2b),
                ?assertEqual(F2b, peer_frontier(N1, I)),
                ?assertEqual(F1b, peer_frontier(N2, I)),
                ?assert(oracle_in_sync(N1, I))
            end,
            Targets
        ),
        ok
    after
        %% Restore AAE so the shared cluster heals before the next test (N2 still
        %% holds the full MST, so N1 re-pulls and re-grows it).
        unquiesce(N1, N2)
    end.

%% Symmetric compaction: the dangerous false-IN-SYNC case. Once BOTH nodes
%% compact, both roots are `undefined`, so an MST-root comparison reports IN SYNC
%% with nothing actually verifying the projections match. We prove the frontier
%% (a) genuinely verifies the match (equal AND non-empty) and (b) detects a REAL
%% divergence injected while both roots stay `undefined` — exactly what the root
%% comparison cannot do.
both_compacted_frontier_detects_real_divergence(Config) ->
    [N1, N2] = nodes_of(Config),
    Pairs = seed_pairs(<<"sym">>),

    seed_and_converge(N1, N2, Pairs),

    try
        quiesce(N1, N2),
        ok = erpc:call(N1, ?MODULE, do_drain_all, []),
        ok = erpc:call(N2, ?MODULE, do_drain_all, []),

        Sigs1 = erpc:call(N1, ?MODULE, do_instance_sigs, []),
        Sigs2 = erpc:call(N2, ?MODULE, do_instance_sigs, []),
        Targets = converged_data_targets(Sigs1, Sigs2),
        ct:pal("sym: ~p data-bearing converged target instances", [
            length(Targets)
        ]),
        ?assert(length(Targets) >= 1),

        %% SYMMETRIC COMPACTION: both nodes compact ⇒ both roots `undefined`.
        lists:foreach(
            fun(I) ->
                ?assertMatch({ok, _}, erpc:call(N1, ?MODULE, do_compact, [I])),
                ?assertMatch({ok, _}, erpc:call(N2, ?MODULE, do_compact, [I]))
            end,
            Targets
        ),

        %% Wait for both compactions to settle to `undefined` roots before
        %% asserting: `do_compact` returns before the root_hash has finished
        %% collapsing, so a one-shot read races it. The cluster is frozen
        %% (quiesced above), so no re-pull can re-populate the compacted MST —
        %% the barrier just polls the local settle.
        SigsC1 = await_instance_sigs(N1, Targets, fun(R) -> R =:= undefined end),
        SigsC2 = await_instance_sigs(N2, Targets, fun(R) -> R =:= undefined end),
        lists:foreach(
            fun(I) ->
                {Fc1, Rc1} = maps:get(I, SigsC1),
                {Fc2, Rc2} = maps:get(I, SigsC2),
                %% Both roots `undefined` ⇒ a root comparison reports IN SYNC
                %% trusting, not checking. The frontier still genuinely agrees
                %% AND is non-empty, so it is actually verifying the match.
                ?assertEqual(undefined, Rc1),
                ?assertEqual(undefined, Rc2),
                ?assertEqual(Rc1, Rc2),
                ?assert(map_size(Fc1) >= 1),
                ?assertEqual(Fc1, Fc2)
            end,
            Targets
        ),

        %% Inject a REAL divergence on N1 with both MSTs empty: write a fresh cell
        %% to an existing band, then re-compact that shard on N1 so its MST
        %% returns to empty (root stays `undefined`). The write is a new event
        %% from N1's origin, so N1's frontier advances and now differs from N2's —
        %% while BOTH roots are still `undefined`. We pin the assertions to the
        %% exact instance the cell routes to (a known target, compacted on both
        %% nodes above, so N2's side is a known frozen baseline).
        Bands = [B || {B, _} <- Pairs],
        DivBand = erpc:call(
            N1, ?MODULE, do_band_on_target, [?USERS_TABLE, Bands, Targets]
        ),
        DivInst = erpc:call(
            N1, ?MODULE, do_instance_for, [
                ?USERS_TABLE, DivBand, <<"divergent">>
            ]
        ),
        ct:pal("sym: injecting divergence into ~s via band ~s", [
            DivInst, DivBand
        ]),
        ?assert(lists:member(DivInst, Targets)),
        {PreF, _} = maps:get(DivInst, SigsC1),

        %% `do_apply` is synchronous (append + drain), so the frontier is updated
        %% and the MST has re-grown by the time it returns.
        ok = erpc:call(
            N1, ?MODULE, do_apply, [
                ?USERS_TABLE,
                DivBand,
                <<"divergent">>,
                val(DivBand, <<"divergent">>)
            ]
        ),
        %% The synchronous `do_apply` re-grew `DivInst`'s MST; snapshot at the
        %% steady state so a load-induced `root_hash/1` timeout (swallowed to
        %% `undefined` by `do_instance_sigs/0`) cannot flake `is_binary(PostR)`.
        SigsDpre = await_instance_sigs(N1, [DivInst], fun erlang:is_binary/1),
        {PostF, PostR} = maps:get(DivInst, SigsDpre),
        ct:pal("sym: divergent write ~s frontier ~p -> ~p", [
            DivInst, PreF, PostF
        ]),
        ?assertNotEqual(PreF, PostF),
        ?assert(is_binary(PostR)),

        %% Re-compact the diverged shard on N1 → empty MST again (`undefined`
        %% root), frontier unchanged (compaction-invariant).
        ?assertMatch({ok, _}, erpc:call(N1, ?MODULE, do_compact, [DivInst])),
        SigsD = erpc:call(N1, ?MODULE, do_instance_sigs, []),
        {Fd1, Rd1} = maps:get(DivInst, SigsD),
        %% N2 has not changed since the symmetric compaction.
        {Fd2, Rd2} = maps:get(DivInst, SigsC2),

        %% BOTH roots are still `undefined` — a root comparison STILL reports IN
        %% SYNC (the dangerous lie) ...
        ?assertEqual(undefined, Rd1),
        ?assertEqual(undefined, Rd2),
        ?assertEqual(Rd1, Rd2),
        ?assertEqual(PostF, Fd1),

        %% ... but the frontiers DIFFER, so the oracle correctly reports DIVERGED
        %% — locally and over the transport.
        ?assertNotEqual(Fd1, Fd2),
        ?assertEqual(Fd2, peer_frontier(N1, DivInst)),
        ?assertNot(oracle_in_sync(N1, DivInst)),
        ok
    after
        unquiesce(N1, N2)
    end.

%% =============================================================================
%% CONTROLLER-SIDE HELPERS
%% =============================================================================

%% @private
nodes_of(Config) ->
    [Node || {_, Node, _} <- ?config(cluster, Config)].

%% @private
%% The `(Band, Key)` cells to seed: one key per distinct realm band, so the cells
%% spread across the realm-sharded table's shard instances.
seed_pairs(Tag) ->
    [{band_for(Tag, B), <<"k">>} || B <- lists:seq(1, ?BANDS)].

%% @private
band_for(Tag, B) ->
    <<"com.bondy.cfront.", Tag/binary, ".", (integer_to_binary(B))/binary>>.

%% @private
val(Band, Key) ->
    #{band_uri => Band, key => Key, marker => <<"cfront">>}.

%% @private
%% Write every cell on N1, then wait for each to converge on N2 via background
%% AAE (nudging the scheduler each round).
seed_and_converge(N1, N2, Pairs) ->
    lists:foreach(
        fun({B, K}) ->
            ok = erpc:call(N1, ?MODULE, do_apply, [
                ?USERS_TABLE, B, K, val(B, K)
            ])
        end,
        Pairs
    ),
    lists:foreach(
        fun({B, K}) -> ok = wait_converge(N2, B, K, val(B, K)) end,
        Pairs
    ).

%% @private
%% GC is frozen suite-wide in `init_per_suite` (see the rationale there);
%% quiesce/unquiesce toggle only the sync scheduler. The `freeze_gc/1` here
%% is a belt-and-braces drain of any straggling compaction worker.
quiesce(N1, N2) ->
    ok = erpc:call(N1, ?MODULE, do_set_dispatch, [off]),
    ok = erpc:call(N2, ?MODULE, do_set_dispatch, [off]),
    ok = bondy_ct:freeze_gc(N1),
    ok = bondy_ct:freeze_gc(N2).

%% @private
unquiesce(N1, N2) ->
    _ = catch erpc:call(N1, ?MODULE, do_set_dispatch, [on]),
    _ = catch erpc:call(N2, ?MODULE, do_set_dispatch, [on]),
    ok.

%% @private
%% The data-bearing, converged instances: non-empty frontier, binary root, and
%% the same frontier + a binary root on the peer's snapshot. These are the
%% meaningful compaction targets.
%%
%% MAIN instances only, deliberately. The ephemeral REGISTRY instances can
%% transiently qualify (both nodes hold internal registrations) but their
%% cross-node MST contents are not required to equalise — entries are
%% node-local and session-scoped (owner self-cleanup removes them without a
%% cross-node contract) — so a registry bystander in the target set makes the
%% baseline root assertions flake on state this suite does not test. Both
%% tests here assert the DURABLE main DB's compaction/frontier semantics.
converged_data_targets(Sigs1, Sigs2) ->
    [
        I
     || {I, {F1, R1}} <- maps:to_list(Sigs1),
        bondy_oplog:db_of(I) =:= bondy_namespace_catalog:main_db_name(),
        map_size(F1) >= 1,
        is_binary(R1),
        case maps:get(I, Sigs2, undefined) of
            {F2, R2} -> F2 =:= F1 andalso is_binary(R2);
            _ -> false
        end
    ].

%% @private
%% `LocalNode`'s view of its single Partisan peer's frontier for `InstId`,
%% fetched with the `get_frontier` request — the production observer path.
peer_frontier(LocalNode, InstId) ->
    {F, _Fp} = erpc:call(LocalNode, ?MODULE, do_peer_sig, [InstId]),
    F.

%% @private
%% The observer verdict (`bondy_observer_cli_sync:status/3`, live path),
%% reproduced over the real cross-node signatures: equal frontiers under matching
%% topology fingerprints ⇒ IN SYNC — independent of the MST roots. (We reproduce
%% the verdict here rather than call the `-ifdef(TEST)`-gated `status/3`, which is
%% not exported in the release build the cluster nodes run.)
oracle_in_sync(LocalNode, InstId) ->
    {LF, LFp} = erpc:call(LocalNode, ?MODULE, do_local_frontier_sig, [InstId]),
    {PF, PFp} = erpc:call(LocalNode, ?MODULE, do_peer_sig, [InstId]),
    not (is_binary(LFp) andalso is_binary(PFp) andalso LFp =/= PFp) andalso
        LF =:= PF.

%% @private
%% Polls `Node` until its local read of `(Band, Key)` returns `Expected`, forcing
%% a sync tick each round so we don't merely wait on the periodic timer.
wait_converge(Node, Band, Key, Expected) ->
    Deadline = now_ms() + ?CONVERGE_MS,
    wait_converge_loop(Node, Band, Key, Expected, Deadline).

%% @private
wait_converge_loop(Node, Band, Key, Expected, Deadline) ->
    _ = catch erpc:call(Node, bondy_oplog_sync_scheduler, trigger, []),
    case erpc:call(Node, ?MODULE, do_read, [?USERS_TABLE, Band, Key]) of
        {ok, {Expected, _Hlc}} ->
            ok;
        Other ->
            case now_ms() > Deadline of
                true ->
                    error({converge_timeout, Node, Band, Key, Other});
                false ->
                    timer:sleep(200),
                    wait_converge_loop(Node, Band, Key, Expected, Deadline)
            end
    end.

%% @private
now_ms() ->
    erlang:monotonic_time(millisecond).

%% @private
%% Re-reads `Node`'s instance signatures until every `Target` instance's root
%% satisfies `Pred` (bounded by `?CONVERGE_MS`).
%%
%% `do_instance_sigs/0` wraps `root_hash/1` in a `catch` and maps any non-binary
%% result — INCLUDING a swallowed gen_server-call timeout — to `undefined`. Under
%% full-suite CT load a busy instance (draining, sealing, or GC-hibernating) can
%% transiently exceed the call timeout, so an unguarded snapshot of a live,
%% uncompacted node occasionally reads `undefined` for a root it still holds.
%% Polling to the steady state removes that flake without masking a real loss: if
%% the roots never settle to `Pred` the wait fails loudly rather than silently
%% reading a transient value.
await_instance_sigs(Node, Targets, Pred) ->
    await_instance_sigs(Node, Targets, Pred, now_ms() + ?CONVERGE_MS).

%% @private
%% Poll BOTH nodes until every target's signature is PAIRWISE equal — same
%% frontier and same binary MST root on both. See the baseline comment in
%% `asymmetric_compaction_keeps_oracle_in_sync/1` for why a one-shot
%% snapshot is not enough. Errors with per-node diagnostics at the deadline.
%% Pre-freeze use (sync still LIVE): drive the pull-only sync on both nodes each
%% poll so a load-starved background scheduler cannot leave the lagging MST pages
%% undelivered past the deadline — the same active drive `seed_and_converge`
%% uses. This is only safe while the cluster is unfrozen and nothing is
%% compacted; a post-`quiesce` caller MUST pass `DriveSync = false` (a trigger
%% then would re-pull and defeat the freeze).
await_pairwise_sigs(N1, N2, Targets) ->
    await_pairwise_sigs(N1, N2, Targets, true).

%% @private
await_pairwise_sigs(N1, N2, Targets, DriveSync) ->
    await_pairwise_sigs(N1, N2, Targets, DriveSync, now_ms() + ?CONVERGE_MS).

%% @private
await_pairwise_sigs(N1, N2, Targets, DriveSync, Deadline) ->
    _ = DriveSync andalso drive_sync([N1, N2]),
    S1 = erpc:call(N1, ?MODULE, do_instance_sigs, [Targets]),
    S2 = erpc:call(N2, ?MODULE, do_instance_sigs, [Targets]),
    Settled = lists:all(
        fun(I) ->
            case {maps:get(I, S1, undefined), maps:get(I, S2, undefined)} of
                {{F, R}, {F, R}} -> is_binary(R);
                _ -> false
            end
        end,
        Targets
    ),
    case Settled of
        true ->
            {S1, S2};
        false ->
            now_ms() =< Deadline orelse
                error(
                    {pairwise_sigs_unsettled, [
                        {targets, Targets},
                        {sigs, S1, S2},
                        {n1, erpc:call(N1, ?MODULE, do_target_diag, [Targets])},
                        {n2, erpc:call(N2, ?MODULE, do_target_diag, [Targets])}
                    ]}
                ),
            timer:sleep(200),
            await_pairwise_sigs(N1, N2, Targets, DriveSync, Deadline)
    end.

%% @private
%% Trigger a (pull-only) AAE sync on each node so convergence is actively driven
%% rather than left to the background scheduler, which starves under full-suite
%% CT load. Best-effort: a node mid-restart just misses this tick.
drive_sync(Nodes) ->
    _ = [
        catch erpc:call(N, bondy_oplog_sync_scheduler, trigger, [])
     || N <- Nodes
    ],
    ok.

%% @private
await_instance_sigs(Node, Targets, Pred, Deadline) ->
    %% Read ONLY the target instances (not every instance on the node) so the
    %% poll does not itself starve them — see `do_instance_sigs/1`.
    Sigs = erpc:call(Node, ?MODULE, do_instance_sigs, [Targets]),
    Settled = lists:all(
        fun(I) ->
            case maps:get(I, Sigs, undefined) of
                {_F, R} -> Pred(R);
                _ -> false
            end
        end,
        Targets
    ),
    case Settled of
        true ->
            Sigs;
        false ->
            now_ms() =< Deadline orelse
                error(
                    {instance_sigs_unsettled, Node,
                        erpc:call(Node, ?MODULE, do_target_diag, [Targets])}
                ),
            timer:sleep(200),
            await_instance_sigs(Node, Targets, Pred, Deadline)
    end.

%% @private
%% Per-target diagnosis captured when a barrier times out: is the instance
%% process alive, what does a bounded `root_hash` read actually return or
%% raise, and — the piece that distinguishes "never dispatched" from
%% "dispatched but stuck" — is there a live/bootstrap sync session currently
%% in flight for this instance, and for how long has it been running?
%% `Read` distinguishes "deregistered" (`no_pid`) from "alive but starved"
%% (`{read_failed, ...}` / timeout) from "genuinely empty root"
%% (`root_undefined`); `Inflight` turns "roots never equalised" into either
%% "no session is even trying" (`[]`) or "a session has been running for
%% AgeMs without completing" (`[{Pid, Kind, Peer, AgeMs}]`) — the latter,
%% with a large `AgeMs`, is the fingerprint of a stuck session rather than
%% ordinary bulk-sync latency. Runs ON the node (via erpc) so
%% `is_process_alive/1` sees a local pid.
do_target_diag(InstIds) ->
    [
        begin
            Pid = bondy_oplog_registry:instance_pid(I),
            Alive = is_pid(Pid) andalso erlang:is_process_alive(Pid),
            Read =
                case Pid of
                    undefined ->
                        no_pid;
                    _ ->
                        try gen_server:call(Pid, root_hash, 5000) of
                            R when is_binary(R) -> {binary, byte_size(R)};
                            undefined -> root_undefined;
                            Other -> {other, Other}
                        catch
                            C:R2 -> {read_failed, C, R2}
                        end
                end,
            Inflight =
                try bondy_oplog_sync_scheduler:inflight_for(I) of
                    L when is_list(L) -> L
                catch
                    _:_ -> unavailable
                end,
            {I, Pid, Alive, Read, Inflight}
        end
     || I <- InstIds
    ].

%% @private
push_module(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

%% =============================================================================
%% PEER-SIDE HELPERS (run on the cluster nodes via erpc)
%% =============================================================================

%% @private
do_apply(Table, Band, Key, Val) ->
    bondy_db:apply(table_handle(Table), Band, Key, {set, Val}).

%% @private
do_read(Table, Band, Key) ->
    bondy_db:read(table_handle(Table), Band, Key).

%% @private
table_handle(Table) ->
    case bondy_namespace_catalog:table(Table) of
        undefined -> error({table_not_provisioned, Table});
        Tab -> Tab
    end.

%% @private
%% The oplog instance id the cell `(Realm, Key)` of `Table` routes to — the same
%% placement `apply/4`/`read/3` derive (`shard_for/3` then the table's
%% shard→instance map).
do_instance_for(Table, Realm, Key) ->
    #{instance_ids := Ids} = T = table_handle(Table),
    maps:get(bondy_db:shard_for(T, Realm, Key), Ids).

%% @private
%% The first `Band` (with key `<<"divergent">>`) whose shard instance is one of
%% `Targets` — so a write to it lands on an instance we compacted on both nodes.
%% A shard that also carries non-converged bootstrap data is not a target, so we
%% must pick a band that routes to a clean, converged one.
do_band_on_target(Table, Bands, Targets) ->
    #{instance_ids := Ids} = T = table_handle(Table),
    OnTarget = [
        B
     || B <- Bands,
        lists:member(
            maps:get(bondy_db:shard_for(T, B, <<"divergent">>), Ids), Targets
        )
    ],
    case OnTarget of
        [B | _] -> B;
        [] -> error({no_seeded_band_on_target, length(Bands), length(Targets)})
    end.

%% @private
%% `InstanceId => {Frontier, Root}` over every live instance on this node
%% (`Frontier` is the applied version vector `#{Origin => max Seq}`; `Root` is
%% `undefined` for an empty / compacted MST).
%%
%% `Root` is read with a GENEROUS timeout (`?ROOT_HASH_TIMEOUT_MS`), not
%% `root_hash/1`'s 5s default: under the CPU pressure of a full CT run a
%% live-but-starved instance blows the 5s call and the read collapses to
%% `undefined` for a root that is in fact binary — making the
%% `await_instance_sigs/4` barrier poll a value that never settles and time out.
%% The value read is the SAME live `root_hash` snapshot (via the instance
%% gen_server, for AAE consistency); only the patience differs.
do_instance_sigs() ->
    do_instance_sigs(bondy_oplog:list_instances()).

%% @private
%% Signatures for a SPECIFIC set of instances. `await_instance_sigs/4` passes
%% just its `Targets` (typically 1-2 instances) rather than reading EVERY oplog
%% instance on the node (dozens, per-table × shard) on every 200ms poll: that
%% whole-node `root_hash` gen_server fan-out, five times a second for up to 120s,
%% was itself a heavy CPU load that could starve the very instances it reads,
%% collapsing their `root_hash` to a swallowed `undefined` and making the barrier
%% time out (`instance_sigs_unsettled`). Reading only the targets removes that
%% self-inflicted observer effect. `InstIds` is intersected with the live set so
%% a target that has since deregistered is simply absent (same as the /0 fold),
%% never a crash in `frontier/1`.
do_instance_sigs(InstIds) ->
    Live = bondy_oplog:list_instances(),
    Wanted = [I || I <- InstIds, lists:member(I, Live)],
    lists:foldl(
        fun(I, Acc) ->
            Frontier = bondy_oplog_instance:frontier(I),
            Root =
                case catch patient_root_hash(I) of
                    R when is_binary(R) -> R;
                    _ -> undefined
                end,
            Acc#{I => {Frontier, Root}}
        end,
        #{},
        Wanted
    ).

%% @private
%% `bondy_oplog_instance:root_hash/1` with a generous call timeout. root_hash/1
%% is a `gen_server:call` into the instance (for AAE snapshot consistency) with
%% the default 5s timeout; under load that collapses to a swallowed `undefined`.
%% We call the same `root_hash` message directly with a wide timeout so a loaded
%% instance still answers.
patient_root_hash(InstId) ->
    case bondy_oplog_registry:instance_pid(InstId) of
        undefined -> undefined;
        Pid -> gen_server:call(Pid, root_hash, ?ROOT_HASH_TIMEOUT_MS)
    end.

%% @private
%% The local frontier signature the observer compares: `{Frontier, Fingerprint}`.
do_local_frontier_sig(InstId) ->
    Frontier = bondy_oplog_instance:frontier(InstId),
    Fp =
        case
            catch bondy_oplog:topology_fingerprint(bondy_oplog:db_of(InstId))
        of
            F when is_binary(F) -> F;
            _ -> undefined
        end,
    {Frontier, Fp}.

%% @private
%% This node's single Partisan peer's frontier signature for `InstId`, fetched
%% over the AAE channel with `get_frontier` (mirrors
%% `bondy_observer_cli_sync:peer_sig/2`). `{Frontier, Fingerprint}`.
do_peer_sig(InstId) ->
    Peer = single_peer(),
    Opts = #{timeout => 5000, channel => aae_channel()},
    case
        catch bondy_oplog_transport_partisan:request(
            Peer, InstId, get_frontier, Opts
        )
    of
        {ok, Frontier, Fp} -> {Frontier, Fp};
        Other -> error({peer_frontier_failed, Peer, InstId, Other})
    end.

%% @private
single_peer() ->
    case partisan:nodes() of
        [Peer | _] -> Peer;
        _ -> error(no_partisan_peer)
    end.

%% @private
aae_channel() ->
    case catch bondy_config:get(aae_channel) of
        Ch when is_atom(Ch) -> Ch;
        _ -> bondy_aae
    end.

%% @private
do_drain_all() ->
    lists:foreach(
        fun(I) -> _ = catch bondy_oplog_instance:await_apply(I) end,
        bondy_oplog:list_instances()
    ).

%% @private
%% Drain, then compact the instance to its CURRENT root (frontier = everything),
%% emptying its MST. Mirrors `bondy_oplog_compaction_durable_test`. A no-op
%% (`{ok, no_change}`) for an already-empty MST.
do_compact(InstId) ->
    _ = catch bondy_oplog_instance:await_apply(InstId),
    case bondy_oplog_instance:root_hash(InstId) of
        Root when is_binary(Root) ->
            bondy_oplog_instance:compact(InstId, [Root]);
        _ ->
            {ok, no_change}
    end.

%% @private
do_set_dispatch(off) ->
    bondy_oplog_sync_scheduler:set_dispatch(undefined);
do_set_dispatch(on) ->
    bondy_oplog_sync_scheduler:set_dispatch(
        fun bondy_oplog_sync_scheduler:default_dispatch/2
    ).
