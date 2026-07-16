%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% End-to-end test for the catalogue-snapshot bootstrap session
%% (`bondy_oplog_sync_session:bootstrap_catalogue/3`) using the inline
%% transport.
%%
%% Validates:
%%   - A fresh local replica pulls all cells from a peer replica.
%%   - The local projection ends up with byte-identical V2 frames.
%%   - finalize_catalogue_bootstrap marks the local instance `live`.
%%   - When the peer reports `no_snapshot` (single-CRDT mode) the
%%     caller falls through to plain sync and the local instance is
%%     left untouched.
%%   - A single-CRDT local instance refuses bootstrap_catalogue with
%%     `{error, not_a_catalogue_instance}`.
%% =============================================================================
-module(bondy_oplog_bootstrap_catalogue_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

bootstrap_catalogue_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun fresh_replica_bootstraps_from_peer/0,
        fun bootstrap_marks_local_live/0,
        fun finalize_adopts_peer_frontier/0,
        fun bootstrap_seeds_local_frontier/0,
        fun live_sync_adopts_peer_frontier/0,
        fun no_snapshot_falls_through_to_sync/0,
        fun single_crdt_local_refuses_bootstrap_catalogue/0,
        fun live_replica_recovers_lossless_via_anti_entropy/0
    ]}.

%% A LIVE sync round (`run/3`) adopts the peer's applied-frontier even for
%% maxima the local replica can NEVER derive from the transferred events — the
%% production core/12 & core/13 symptom. A shard the peer has fully compacted
%% has EQUAL roots (nothing to page-sync) and a snapshot MST with no
%% `cell_apply` keys, so neither the replay path nor a restart's
%% `frontier_from_mst` can reconstruct those maxima; the ONLY path to a
%% converged oracle is adopting the peer's frontier on the live sync. Modelled
%% by injecting a phantom origin into the peer's frontier that no transferred
%% event carries: a converged round must still adopt it. Before the fix the
%% local frontier omits it and the oracle stays DIVERGED-with-identical-data.
live_sync_adopts_peer_frontier() ->
    {Peer, _, _, _} = setup_instance(),
    {Local, _, _, _} = setup_instance(),
    %% A real shared event so the round genuinely converges (equal roots).
    _ = bondy_oplog:append(Peer, {cell_apply, ?B, <<"k">>, {set, 10, <<"v">>}}),
    _ = barrier(Peer),
    %% Inject a phantom origin: present in the peer's frontier but carried by NO
    %% event `Local` can pull — stands in for a compacted-prefix maximum.
    Phantom = <<"peer-compacted-origin">>,
    ok = bondy_oplog_registry:merge_frontier(Peer, #{Phantom => 777}),

    ?assertEqual(
        undefined,
        maps:get(Phantom, bondy_oplog_instance:frontier(Local), undefined)
    ),

    %% THE FIX (production behaviour): a converged round adopts the peer's
    %% frontier, including the phantom maximum no transferred event carries.
    %%
    %% We assert this against the CONVERGED STEADY STATE rather than a single
    %% `run/1`. `run/4` captures the peer frontier BEFORE the round via
    %% `request_peer_frontier/4`, whose inline `get_frontier` request has a
    %% `catch` that degrades to `#{}` on ANY error — including a transient
    %% gen_server-call timeout under heavy test-VM load. When that happens the
    %% round still returns `{ok, _}` but skips the adoption (empty peer frontier),
    %% exactly as it would in production — where the scheduler simply adopts on
    %% the next AE tick. Mirror that by running rounds until the phantom is
    %% adopted (bounded). This cannot mask a real "never adopts" regression: a
    %% frontier that is genuinely never adopted still exhausts the budget and
    %% fails loudly below.
    ok = adopt_phantom_within(Local, Peer, Phantom, 777, 100),

    teardown(Peer),
    teardown(Local).

%% @private
adopt_phantom_within(_Local, _Peer, Phantom, Expected, 0) ->
    error({frontier_not_adopted, Phantom, Expected});
adopt_phantom_within(Local, Peer, Phantom, Expected, N) ->
    %% Tolerate a transient `{error, _}` round (e.g. a load-induced
    %% budget/timeout) the same way the scheduler does — retry.
    _ = bondy_oplog_sync_session:run(Local, Peer, #{}),
    case maps:get(Phantom, bondy_oplog_instance:frontier(Local), undefined) of
        Expected ->
            ok;
        _ ->
            timer:sleep(20),
            adopt_phantom_within(Local, Peer, Phantom, Expected, N - 1)
    end.

%% Direct, deterministic regression for the fix mechanism. A catalogue bootstrap
%% ships the peer's projection cells, which carry only HLC + value — NOT the
%% per-origin `{Origin, Seq}` the applied-frontier VV is built from — so the
%% frontier cannot be derived from the install and must be ADOPTED from the
%% peer. `finalize_catalogue_bootstrap/4` does that; the legacy `/3` must not
%% (an empty merge), preserving its historical behaviour.
finalize_adopts_peer_frontier() ->
    {Local, _, _, _} = setup_instance(),
    ?assertEqual(#{}, bondy_oplog_instance:frontier(Local)),

    PeerFrontier = #{<<"origin-a">> => 42, <<"origin-b">> => 7},
    ok = bondy_oplog_instance:finalize_catalogue_bootstrap(
        Local, 0, PeerFrontier, true
    ),
    %% THE FIX: the peer's applied frontier is adopted.
    ?assertEqual(PeerFrontier, bondy_oplog_instance:frontier(Local)),

    %% Legacy `/3` leaves the frontier untouched (empty merge), unchanged.
    {Other, _, _, _} = setup_instance(),
    ok = bondy_oplog_instance:finalize_catalogue_bootstrap(Other, 0, true),
    ?assertEqual(#{}, bondy_oplog_instance:frontier(Other)),

    teardown(Local),
    teardown(Other).

%% End-to-end reproduction of node2's production symptom: a DURABLE
%% `pre_bootstrap` replica bootstrapping from a peer whose MST has been
%% COMPACTED EMPTY (data folded into the checkpoint + projection, the normal
%% post-import state). With the source MST empty the tail anti-entropy transfers
%% nothing, so the ONLY way the bootstrapped replica gets a non-empty frontier
%% is by adopting the peer's in finalize. `WasLive = false` (pre_bootstrap)
%% means `finish_bootstrap` does not rederive either. Before the fix the
%% replica therefore held all the projection data yet kept an EMPTY frontier —
%% DIVERGED-with-data forever against the convergence oracle.
bootstrap_seeds_local_frontier() ->
    BaseDir = test_dir(),
    {Peer, _, _, _} = setup_instance_persistent(BaseDir, #{seed => true}),
    {Local, _, _, _} = setup_instance_persistent(BaseDir, #{}),
    Cells = [
        {<<"k1">>, 10, <<"v1">>},
        {<<"k2">>, 20, <<"v2">>},
        {<<"k3">>, 30, <<"v3">>}
    ],
    [
        bondy_oplog:append(Peer, {cell_apply, ?B, K, {set, Hlc, V}})
     || {K, Hlc, V} <- Cells
    ],
    _ = barrier(Peer),

    %% Compact the peer's MST empty — exactly node1's post-import state: the
    %% data lives in the projection + checkpoint, the MST is gone.
    PeerRoot = bondy_oplog:root_hash(Peer),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(Peer, [PeerRoot])
    ),
    ?assertEqual(undefined, bondy_oplog:root_hash(Peer)),

    PeerFrontier = bondy_oplog_instance:frontier(Peer),
    %% Precondition: peer's applied frontier persists across compaction;
    %% local is a fresh pre_bootstrap replica with an empty frontier.
    ?assert(map_size(PeerFrontier) > 0),
    ?assertEqual(#{}, bondy_oplog_instance:frontier(Local)),
    ?assertEqual(pre_bootstrap, bondy_oplog_instance:lifecycle_state(Local)),

    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{}),

    %% THE FIX: with the source MST compacted-empty, the only path to a
    %% non-empty frontier is adopting the peer's in finalize. Without it the
    %% replica stays DIVERGED-with-data — the production symptom.
    ?assertEqual(PeerFrontier, bondy_oplog_instance:frontier(Local)),

    teardown(Peer),
    teardown(Local),
    file:del_dir_r(BaseDir).

fresh_replica_bootstraps_from_peer() ->
    %% Set up the peer with cells, the local replica with nothing.
    {Peer, _PeerNS, _, _} = setup_instance(),
    {Local, _LocalNS, _, _} = setup_instance(),
    Cells = [
        {<<"k1">>, 10, <<"v1">>},
        {<<"k2">>, 20, <<"v2">>},
        {<<"k3">>, 5, <<"v3">>},
        {<<"k4">>, 25, <<"v4">>}
    ],
    [
        bondy_oplog:append(Peer, {cell_apply, ?B, K, {set, Hlc, V}})
     || {K, Hlc, V} <- Cells
    ],
    _ = barrier(Peer),

    %% Pre-bootstrap: peer high-water = 25, local high-water = 0.
    ?assertMatch(
        {ok, 25},
        high_water(Peer)
    ),
    ?assertMatch(
        {ok, no_watermark},
        high_water(Local)
    ),

    ?assertMatch(
        {ok, _Root},
        bondy_oplog_sync_session:bootstrap_catalogue(
            Local, Peer, #{transport_opts => #{}}
        )
    ),

    %% Post-bootstrap: local high-water has caught up to peer.
    ?assertMatch({ok, 25}, high_water(Local)),

    %% Verify every key has the right cell present on the local replica.
    PeerEntry = peer_entry(Peer),
    LocalEntry = peer_entry(Local),
    LocalAdapter = bondy_oplog_core_registry:entry_projection_adapter(
        LocalEntry
    ),
    LocalHandle = bondy_oplog_core_registry:entry_projection_handle(LocalEntry),
    PeerAdapter = bondy_oplog_core_registry:entry_projection_adapter(PeerEntry),
    PeerHandle = bondy_oplog_core_registry:entry_projection_handle(PeerEntry),
    [
        begin
            {ok, LocalFrame} = LocalAdapter:get(LocalHandle, ?B, K),
            {ok, PeerFrame} = PeerAdapter:get(PeerHandle, ?B, K),
            ?assertEqual(PeerFrame, LocalFrame)
        end
     || {K, _, _} <- Cells
    ],

    teardown(Peer),
    teardown(Local).

bootstrap_marks_local_live() ->
    %% Persistent (storage_path-backed) instances default to
    %% `pre_bootstrap`. Ephemeral in-memory instances default to `live`
    %% — those are tested in `fresh_replica_bootstraps_from_peer/0`.
    %% Here we set `storage_path` on both, and seed the Peer as a
    %% genesis (`live`) replica so it can serve the bootstrap.
    BaseDir = test_dir(),
    {Peer, _, _, _} = setup_instance_persistent(BaseDir, #{seed => true}),
    {Local, _, _, _} = setup_instance_persistent(BaseDir, #{}),
    _ = bondy_oplog:append(Peer, {cell_apply, ?B, <<"k">>, {set, 1, <<"v">>}}),
    _ = barrier(Peer),

    %% Peer is live (seeded), Local is pre_bootstrap.
    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Peer)),
    ?assertEqual(pre_bootstrap, bondy_oplog_instance:lifecycle_state(Local)),

    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(
        Local, Peer, #{}
    ),

    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Local)),
    teardown(Peer),
    teardown(Local),
    file:del_dir_r(BaseDir).

no_snapshot_falls_through_to_sync() ->
    %% Peer = single-CRDT mode (returns no_snapshot). Local = catalogue.
    Peer = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Peer, #{
        crdt_module => bondy_oplog_crdt_lww_register
    }),
    {Local, _, _, _} = setup_instance(),
    ?assertMatch(
        {ok, _},
        bondy_oplog_sync_session:bootstrap_catalogue(
            Local, Peer, #{}
        )
    ),
    bondy_oplog:stop_instance(Peer),
    teardown(Local).

live_replica_recovers_lossless_via_anti_entropy() ->
    %% A LIVE replica calling `bootstrap_catalogue` no longer pulls and
    %% REPLACES from the peer snapshot — PR-G removed the CvRDT merge-mode.
    %% It converges via op-based anti-entropy (`run/3`: MST page union +
    %% per-cell replay), which is LOSSLESS: a local-only write the peer
    %% never observed survives, and a cell both hold resolves by the op's
    %% HLC (LWW). The replace-mode wipe a naive cutover would use could drop
    %% the local-only cell, so this is the recovering-bootstrap convergence
    %% gate for the cutover.
    {Peer, _, _, _} = setup_instance(),
    {Local, _, _, _} = setup_instance(),

    %% Local (live): a shared K1@5 and a LOCAL-ONLY K2@30 the peer never sees.
    _ = bondy_oplog:append(
        Local, {cell_apply, ?B, <<"k1">>, {set, 5, <<"local-k1">>}}
    ),
    _ = bondy_oplog:append(
        Local, {cell_apply, ?B, <<"k2">>, {set, 30, <<"local-k2">>}}
    ),
    _ = barrier(Local),
    %% Peer: a higher-HLC K1@20 and nothing else.
    _ = bondy_oplog:append(
        Peer, {cell_apply, ?B, <<"k1">>, {set, 20, <<"peer-k1">>}}
    ),
    _ = barrier(Peer),

    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Local)),

    {ok, _} = bondy_oplog_sync_session:bootstrap_catalogue(
        Local, Peer, #{}
    ),
    %% Anti-entropy lands the peer events in the MST; force the per-cell
    %% projection replay so the read observes them (production casts async).
    ok = replay(Local),

    LocalEntry = peer_entry(Local),
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(LocalEntry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(LocalEntry),
    {ok, K1Frame} = Adapter:get(Handle, ?B, <<"k1">>),
    {ok, K2Frame} = Adapter:get(Handle, ?B, <<"k2">>),
    {K1Hlc, _, _} = bondy_oplog_cell_frame:decode_full(K1Frame),
    {K2Hlc, _, _} = bondy_oplog_cell_frame:decode_full(K2Frame),
    %% Shared cell converges to the higher-HLC value (peer@20).
    ?assertEqual(20, K1Hlc),
    %% Local-only cell is PRESERVED — the lossless property (no replace-wipe).
    ?assertEqual(30, K2Hlc),

    teardown(Peer),
    teardown(Local).

single_crdt_local_refuses_bootstrap_catalogue() ->
    Local = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Local, #{
        crdt_module => bondy_oplog_crdt_lww_register
    }),
    Peer = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Peer, #{
        crdt_module => bondy_oplog_crdt_lww_register
    }),
    ?assertEqual(
        {error, not_a_catalogue_instance},
        bondy_oplog_sync_session:bootstrap_catalogue(Local, Peer, #{})
    ),
    bondy_oplog:stop_instance(Local),
    bondy_oplog:stop_instance(Peer).

%% =============================================================================
%% Helpers
%% =============================================================================

setup_instance() ->
    Id = mk_id(),
    NS = ns_of(Id),
    {Cache, Proj} = register_shard(NS, primary, 0),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        %% A distinct origin per instance — these model two separate replicas,
        %% which in production carry distinct persisted origins. Without it both
        %% ephemeral instances inherit `bondy_oplog_origin:default()` and their
        %% first append can mint an identical `(HLC, Origin, Seq)` event key for
        %% the SHARED `k1` cell, which the MST merge correctly rejects as a
        %% `divergent_value`. (The persistent variant gets distinct origins for
        %% free via its distinct `storage_path`.)
        origin => bondy_oplog_origin:new(),
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }),
    {Id, NS, Cache, Proj}.

setup_instance_persistent(BaseDir, ExtraOpts) ->
    Id = mk_id(),
    NS = ns_of(Id),
    {Cache, Proj} = register_shard(NS, primary, 0),
    Path = filename:join([BaseDir, binary_to_list(Id)]),
    ok = filelib:ensure_path(Path),
    Opts = maps:merge(
        #{
            fold_module => lww_register,
            applier => #{
                cell_apply_target => {NS, primary, 0}
            },
            storage_path => list_to_binary(Path)
        },
        ExtraOpts
    ),
    {ok, _} = bondy_oplog:start_instance(Id, Opts),
    {Id, NS, Cache, Proj}.

test_dir() ->
    Base = filename:join([
        "/tmp",
        "bondy_mst_bootstrap_catalogue_test",
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_path(Base),
    Base.

teardown(Id) ->
    bondy_oplog:stop_instance(Id),
    NS = ns_of(Id),
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)],
        N =:= NS
    ],
    ok.

register_shard(NS, Index, Shard) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register
    }),
    {Cache, Proj}.

mk_id() ->
    iolist_to_binary([
        "btc_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

barrier(Id) ->
    bondy_oplog:projection(Id).

%% Force the synchronous per-cell projection replay: project the events a
%% sync session integrated into the MST onto the per-cell projection.
replay(Id) ->
    Pid = bondy_oplog_registry:applier_pid(Id),
    bondy_oplog_applier:replay_cell_events_sync(Pid).

high_water(Id) ->
    NS = ns_of(Id),
    bondy_oplog_core_registry:high_water_hlc(NS, primary, 0).

peer_entry(Id) ->
    NS = ns_of(Id),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    Entry.
