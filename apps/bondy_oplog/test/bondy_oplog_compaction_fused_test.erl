%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% MST/WAL compaction on **ephemeral, fused** instances — the shape the
%% `registry` DB uses (`bondy_namespace_catalog:registry_db_spec/0`:
%% `fused => true`, `projection_backend => ets`, `durability => ephemeral`).
%%
%% The all-peer-confirmed frontier (`compute_frontier_for/2`) cannot advance
%% under sustained load (peer roots lag the write rate), and for the
%% memory-topology registry DB the retained event history is pure RAM — the
%% fleet-scale OOM. Ephemeral catalogue instances are therefore bounded by a
%% LOCAL `retention` policy (`#{max_age_ms, max_events}`): when the
%% peer-confirmed frontier yields nothing, `retention_frontier/3` truncates
%% by age or size instead. Sound because the projection materializes all
%% applied state (truncation loses nothing locally) and a peer that missed
%% truncated history recovers via catalogue bootstrap (the
%% `peer_pages_unavailable`/`frontier_gap` → rebootstrap path).
%%
%% These tests pin: retention truncates on size and age breaches; no
%% retention ⇒ the old defer-forever behavior (no hidden solo carve-out);
%% retention requires `fused`; retention without a projection never fires;
%% the truncate-vs-drain race loses no data (the fused MST never holds
%% unapplied events); the peer-confirmed and mux paths are unchanged.
-module(bondy_oplog_compaction_fused_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(BUCKET_SUB, <<"sub_rib">>).
-define(BUCKET_REG, <<"reg_rib">>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

compaction_fused_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun solo_fused_without_retention_defers/0},
        {timeout, 30, fun retention_size_breach_truncates/0},
        {timeout, 30, fun retention_age_breach_truncates/0},
        {timeout, 30, fun retention_below_thresholds_defers/0},
        {timeout, 30, fun retention_requires_fused_rejected/0},
        {timeout, 30, fun retention_without_projection_never_fires/0},
        {timeout, 30, fun retention_truncate_vs_drain_race/0},
        {timeout, 30, fun retention_compaction_is_idempotent/0},
        {timeout, 30, fun self_root_confirms_ephemeral_fused_compacts/0},
        {timeout, 30, fun mux_shard_both_tables_compact_together/0},
        {timeout, 30, fun fused_catalogue_bootstrap_roundtrip/0},
        {timeout, 30, fun watermark_door_folds_unapplied_peer_event_fused/0},
        {timeout, 30, fun watermark_door_holds_unapplied_peer_event_applier/0},
        {timeout, 30, fun live_door_accepts_unapplied_remote_event_fused/0},
        {timeout, 30, fun live_door_accepts_unapplied_remote_event_applier/0},
        {timeout, 30, fun live_filter_drops_already_applied_remote_event/0},
        {timeout, 30, fun live_append_remote_reaches_projection_fused/0},
        {timeout, 30, fun live_append_remote_reaches_projection_applier/0},
        {timeout, 30, fun frontier_gap_detected_after_peer_truncation/0},
        {timeout, 30, fun rederive_restores_cell_clobbered_by_live_bootstrap/0},
        {timeout, 30, fun truncation_reclaims_store_pages/0}
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

%% Without a retention policy, a peerless fused instance defers forever —
%% the pre-retention behavior, now again the ONLY no-policy behavior (the
%% interim solo-membership carve-out was subsumed by retention and
%% removed). Retention is the mechanism, explicitly configured; nothing
%% truncates behind the operator's back.
solo_fused_without_retention_defers() ->
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    K = <<"vehicle_0">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, -1}}),
    ok = bondy_oplog_instance:await_apply(Id),
    SizeBefore = bondy_oplog:size(Id),
    ?assert(SizeBefore >= 1),

    ?assertEqual({ok, no_change}, bondy_oplog_instance:compact(Id, [])),
    ?assertEqual(SizeBefore, bondy_oplog:size(Id)),

    teardown(Id).

%% `max_events` breach: the whole applied tree truncates — with NO peer
%% roots at all, the exact shape `bondy_oplog_compaction:compact/1` drives
%% every second via `bondy_oplog_gc_scheduler` on a loaded cluster whose
%% peer-confirmed frontier is stalled.
retention_size_breach_truncates() ->
    Retention = #{max_age_ms => 0, max_events => 3},
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, Retention),
    _ = [
        bondy_oplog:append(
            Id,
            {cell_apply, ?B, <<"vehicle_", (integer_to_binary(N))/binary>>,
                {inc, 1}}
        )
     || N <- lists:seq(1, 6)
    ],
    ok = bondy_oplog_instance:await_apply(Id),
    ?assert(bondy_oplog:size(Id) > 3),

    ?assertMatch(
        {ok, {compacted, _, _}}, bondy_oplog_instance:compact(Id, [])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),
    ?assertNotEqual(undefined, bondy_oplog:current_watermark(Id)),

    teardown(Id).

%% `max_age_ms` breach: everything older than the cutoff truncates. The
%% frontier is a REAL key selected via the synthetic HLC bound (see
%% `retention_age_frontier/4`).
retention_age_breach_truncates() ->
    Retention = #{max_age_ms => 50, max_events => 0},
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, Retention),
    K = <<"vehicle_age">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(Id),
    ?assert(bondy_oplog:size(Id) >= 2),

    %% Let the events age past the 50ms window.
    timer:sleep(120),
    ?assertMatch(
        {ok, {compacted, _, _}}, bondy_oplog_instance:compact(Id, [])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),

    teardown(Id).

%% Policy present but neither knob breached: defers exactly like the
%% no-policy case — retention never truncates early.
retention_below_thresholds_defers() ->
    Retention = #{max_age_ms => 60_000, max_events => 1000},
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, Retention),
    K = <<"vehicle_young">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(Id),
    SizeBefore = bondy_oplog:size(Id),
    ?assert(SizeBefore >= 1),

    ?assertEqual({ok, no_change}, bondy_oplog_instance:compact(Id, [])),
    ?assertEqual(SizeBefore, bondy_oplog:size(Id)),

    teardown(Id).

%% Retention on a non-fused instance is rejected at start — retention
%% requires fused (⇒ ephemeral, enforced upstream): a durable instance's
%% history must never be bounded by local policy.
retention_requires_fused_rejected() ->
    Id = mk_id(),
    ?assertMatch(
        {error, _},
        bondy_oplog:start_instance(Id, #{
            fold_module => lww_register,
            origin => bondy_oplog_origin:new(),
            mst_retention => #{max_age_ms => 1000, max_events => 10}
        })
    ).

%% A fused bare-CRDT instance (no `cell_apply_target` → no projection)
%% accepts the retention opt at start but the policy NEVER fires: without
%% a projection nothing holds the state, so truncation would lose it.
%% Pins `retention_ctx/2`'s `HasProjection` gate.
retention_without_projection_never_fires() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        crdt_module => bondy_oplog_test_counter,
        origin => bondy_oplog_origin:new(),
        fused => true,
        mst_retention => #{max_age_ms => 1, max_events => 1}
    }),
    try
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 5)],
        ok = bondy_oplog_instance:await_apply(Id),
        SizeBefore = bondy_oplog:size(Id),
        ?assert(SizeBefore >= 5),
        timer:sleep(30),

        ?assertEqual({ok, no_change}, bondy_oplog_instance:compact(Id, [])),
        ?assertEqual(SizeBefore, bondy_oplog:size(Id))
    after
        ok = bondy_oplog:stop_instance(Id)
    end.

%% The truncate-vs-drain race: a burst is appended and compaction invoked
%% IMMEDIATELY, with no await barrier. The invariant under test — the
%% fused MST never holds unapplied events (local events install during the
%% in-process drain; remote events fold inline at integrate) — means a
%% retention truncation can never drop an event the projection has not
%% materialized. Every appended cell must read back after the dust
%% settles, whichever side of the truncation it landed on.
retention_truncate_vs_drain_race() ->
    Retention = #{max_age_ms => 0, max_events => 1},
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, Retention),
    NS = ns_of(Id),
    Keys = [
        <<"vehicle_race_", (integer_to_binary(N))/binary>>
     || N <- lists:seq(1, 50)
    ],
    _ = [
        bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}})
     || K <- Keys
    ],
    %% No await: compact races the fused drain.
    _ = bondy_oplog_instance:compact(Id, []),
    ok = bondy_oplog_instance:await_apply(Id),

    %% No cell lost: every key materialized in the projection.
    Missing = [K || K <- Keys, bondy_oplog_core:read(NS, primary, K) =:= undefined],
    ?assertEqual([], Missing),

    %% And the tree is (or becomes, one more cycle) bounded BY THE
    %% POLICY: events that raced in above the first cycle's watermark
    %% survive it, and a follow-up cycle truncates them only while the
    %% size still BREACHES max_events — exactly 1 event left is at the
    %% bound, not over it, and correctly defers.
    _ = bondy_oplog_instance:compact(Id, []),
    ?assert(bondy_oplog:size(Id) =< 1),

    teardown(Id).

%% A second retention cycle with nothing new degrades to `{ok, no_change}`
%% with the watermark unmoved — same idempotence the peer-confirmed path
%% pins in `bondy_oplog_catalogue_compaction_test:idempotent_after_truncation/0`.
retention_compaction_is_idempotent() ->
    Retention = #{max_age_ms => 0, max_events => 1},
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, Retention),
    K = <<"vehicle_idem">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(Id),

    ?assertMatch(
        {ok, {compacted, _, _}}, bondy_oplog_instance:compact(Id, [])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),
    Watermark1 = bondy_oplog:current_watermark(Id),
    ?assertNotEqual(undefined, Watermark1),

    ?assertEqual({ok, no_change}, bondy_oplog_instance:compact(Id, [])),
    ?assertEqual(Watermark1, bondy_oplog:current_watermark(Id)),
    ?assertEqual(0, bondy_oplog:size(Id)),

    teardown(Id).

%% The peer-confirmed path on a fused instance is untouched by retention:
%% a confirmed peer root truncates exactly as before (the
%% "self-root-as-fake-confirmed-peer" technique from
%% `bondy_oplog_catalogue_compaction_test.erl`), retention configured or
%% not.
self_root_confirms_ephemeral_fused_compacts() ->
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    K = <<"vehicle_2">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, -1}}),
    ok = bondy_oplog_instance:await_apply(Id),
    ?assert(bondy_oplog:size(Id) >= 1),

    Root = bondy_oplog_instance:root_hash(Id),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(Id, [Root])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),

    teardown(Id).

%% Regression-lock for the real registry mux shape: one fused instance
%% multiplexing TWO tables with heterogeneous CRDT kernels, distinguished by
%% `Bucket` (`bondy_oplog_crdt_pn_counter` founding the instance —
%% `?BUCKET_SUB`, mirroring `bondy_subscription_rib` — with
%% `bondy_oplog_crdt_struct` joining at runtime via `register_table/4` as
%% `?BUCKET_REG`, mirroring `bondy_registration_rib`'s
%% `?RIB_REGISTRATION_SCHEMA` shape). The core compaction mechanism
%% operates purely on the MST as a flat key/value tree — mux-agnostic by
%% construction; self-root-confirms and asserts combined size returns to 0
%% across both tables.
mux_shard_both_tables_compact_together() ->
    Id = mk_id(),
    NsSub = ns_of(Id),
    NsReg = binary_to_atom(<<"reg_", Id/binary>>, utf8),

    {SubCache, SubProj} = register_shard_with_bucket(
        NsSub, Id, ?BUCKET_SUB, bondy_oplog_crdt_pn_counter, #{}
    ),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        origin => bondy_oplog_origin:new(),
        fused => true,
        applier => #{
            cell_apply_target => {NsSub, primary, 0},
            cell_apply_bucket => ?BUCKET_SUB
        }
    }),

    StructSchema = #{
        count => {bondy_oplog_crdt_pn_counter, #{stabilize_zero => 0}},
        invoke => bondy_oplog_crdt_lww_register
    },
    {RegCache, RegProj} = register_shard_with_bucket(
        NsReg, Id, ?BUCKET_REG, bondy_oplog_crdt_struct, StructSchema
    ),
    ok = bondy_oplog_instance:register_table(
        Id, ?BUCKET_REG, {NsReg, primary, 0}, #{}
    ),

    K1 = <<"sub_1">>,
    K2 = <<"reg_1">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?BUCKET_SUB, K1, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?BUCKET_SUB, K1, {inc, -1}}),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_REG, K2, {apply, count, {inc, 1}}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_REG, K2, {apply, count, {inc, -1}}}
    ),
    ok = bondy_oplog_instance:await_apply(Id),
    ?assert(bondy_oplog:size(Id) >= 2),

    Root = bondy_oplog_instance:root_hash(Id),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(Id, [Root])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),

    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NsSub, primary, 0),
    ok = bondy_oplog_core_registry:unregister(NsReg, primary, 0),
    close_shard(SubCache, SubProj),
    close_shard(RegCache, RegProj).

%% Fused-to-fused catalogue bootstrap end to end — the recovery path a
%% retention-truncating cluster depends on (page-sync alone covers only the
%% retention window, so a joining/lagging peer's ONLY complete source is
%% the snapshot stream). Mirrors
%% `bondy_oplog_applier_multiplex_test:install_catalogue_batch_routes_by_bucket/0`
%% with FUSED source and target: previously the producer answered
%% `{ok, no_snapshot}` for any fused instance (it resolved the projection
%% target via the applier pid) and the installer refused outright with
%% `fused_bootstrap_unsupported`.
fused_catalogue_bootstrap_roundtrip() ->
    %% Source: a fused mux instance with two buckets and retention (the
    %% real registry shape), with data ALREADY TRUNCATED from its MST —
    %% proving the snapshot streams from the projection, not the history.
    SrcId = mk_id(),
    SrcNsSub = ns_of(SrcId),
    SrcNsReg = binary_to_atom(<<"reg_", SrcId/binary>>, utf8),
    {SC1, SP1} = register_shard_with_bucket(
        SrcNsSub, SrcId, ?BUCKET_SUB, bondy_oplog_crdt_pn_counter, #{}
    ),
    {ok, _} = bondy_oplog:start_instance(SrcId, #{
        fold_module => lww_register,
        origin => bondy_oplog_origin:new(),
        fused => true,
        mst_retention => #{max_age_ms => 0, max_events => 1},
        applier => #{
            cell_apply_target => {SrcNsSub, primary, 0},
            cell_apply_bucket => ?BUCKET_SUB
        }
    }),
    {SC2, SP2} = register_shard_with_bucket(
        SrcNsReg, SrcId, ?BUCKET_REG, bondy_oplog_crdt_pn_counter, #{}
    ),
    ok = bondy_oplog_instance:register_table(
        SrcId, ?BUCKET_REG, {SrcNsReg, primary, 0}, #{}
    ),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_SUB, <<"ka">>, {inc, 1}}
    ),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_REG, <<"kb">>, {inc, 1}}
    ),
    ok = bondy_oplog_instance:await_apply(SrcId),
    %% Retention-truncate the source history: the projection is now the
    %% ONLY holder of the cells.
    ?assertMatch(
        {ok, {compacted, _, _}}, bondy_oplog_instance:compact(SrcId, [])
    ),
    ?assertEqual(0, bondy_oplog:size(SrcId)),

    %% Producer: the fused instance serves a full multi-bucket snapshot.
    {ok, {_Watermark, Cursor}} = bondy_oplog_catalogue_snapshot:init(SrcId),
    Cells = pull_snapshot(SrcId, Cursor, []),
    Buckets = lists:usort([B || {B, _K, _F} <- Cells]),
    ?assertEqual([?BUCKET_REG, ?BUCKET_SUB], Buckets),
    ?assertEqual(2, length(Cells)),

    %% Installer: a FRESH fused mux target materializes each bucket's
    %% cells in its own table's projection.
    TgtId = mk_id(),
    TgtNsSub = ns_of(TgtId),
    TgtNsReg = binary_to_atom(<<"reg_", TgtId/binary>>, utf8),
    {TC1, TP1} = register_shard_with_bucket(
        TgtNsSub, TgtId, ?BUCKET_SUB, bondy_oplog_crdt_pn_counter, #{}
    ),
    {ok, _} = bondy_oplog:start_instance(TgtId, #{
        fold_module => lww_register,
        origin => bondy_oplog_origin:new(),
        fused => true,
        applier => #{
            cell_apply_target => {TgtNsSub, primary, 0},
            cell_apply_bucket => ?BUCKET_SUB
        }
    }),
    {TC2, TP2} = register_shard_with_bucket(
        TgtNsReg, TgtId, ?BUCKET_REG, bondy_oplog_crdt_pn_counter, #{}
    ),
    ok = bondy_oplog_instance:register_table(
        TgtId, ?BUCKET_REG, {TgtNsReg, primary, 0}, #{}
    ),

    {ok, Counts} = bondy_oplog_instance:install_catalogue_batch(
        TgtId, {replace, Cells}
    ),
    ?assertEqual(2, maps:get(installed, Counts)),
    ?assertNotEqual(
        undefined,
        bondy_oplog_core:read(TgtNsSub, primary, ?BUCKET_SUB, <<"ka">>)
    ),
    ?assertNotEqual(
        undefined,
        bondy_oplog_core:read(TgtNsReg, primary, ?BUCKET_REG, <<"kb">>)
    ),
    %% No misroute across buckets.
    ?assertEqual(
        undefined,
        bondy_oplog_core:read(TgtNsSub, primary, ?BUCKET_SUB, <<"kb">>)
    ),

    %% Finalize adopts the source's applied-frontier VV — without it a
    %% snapshot-seeded replica converges by data but never by the oracle.
    SrcFrontier = bondy_oplog_registry:frontier(SrcId),
    ?assertNotEqual(#{}, SrcFrontier),
    ok = bondy_oplog_instance:finalize_catalogue_bootstrap(
        TgtId, 0, SrcFrontier, true
    ),
    TgtFrontier = bondy_oplog_registry:frontier(TgtId),
    _ = [
        ?assertEqual(Max, maps:get(Origin, TgtFrontier, missing))
     || {Origin, Max} <- maps:to_list(SrcFrontier)
    ],

    ok = bondy_oplog:stop_instance(SrcId),
    ok = bondy_oplog:stop_instance(TgtId),
    _ = [
        bondy_oplog_core_registry:unregister(N, primary, 0)
     || N <- [SrcNsSub, SrcNsReg, TgtNsSub, TgtNsReg]
    ],
    close_shard(SC1, SP1),
    close_shard(SC2, SP2),
    close_shard(TC1, TP1),
    close_shard(TC2, TP2).

%% The frontier-GAP detection end to end: a retention peer truncates
%% history a laggard never received; the laggard's next FULL sync round
%% completes but must (a) fail with `{frontier_gap, _}` rather than
%% silently succeed, and (b) NOT adopt the peer's frontier (the adoption's
%% "can never over-claim" argument requires all-peer-confirmed compaction,
%% which retention bypasses — adopting would flip the convergence oracle
%% to CONVERGED over silently missing data). The catalogue bootstrap is
%% then the remedy: after install + finalize the same sync round passes.
%% THE WATERMARK DOOR — data-loss reproducer and fix lock (fused).
%% A peer event whose key sorts at or below this replica's watermark can
%% arrive AFTER the watermark advanced: the peer-confirmed frontier and
%% in-flight events race by design under concurrent writes.
%% `integrate_peer_root` used to discard such an event UNAPPLIED at its
%% watermark re-truncate — the op never reached this replica's
%% projection, the completed round's `confirm_root` (a PAGE-holding
%% claim) then let the origin compact the event away, and the applied
%% VV max-merged past the hole on the next same-origin apply, masking
%% the loss from every oracle. The door must FOLD a never-applied event
%% into the projection (advancing the VV) before dropping it.
watermark_door_folds_unapplied_peer_event_fused() ->
    A = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    B = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    BNs = ns_of(B),

    %% A mints the in-flight event FIRST — the lowest HLC in this test.
    _ = bondy_oplog:append(A, {cell_apply, ?B, <<"doored">>, {inc, 5}}),
    ok = bondy_oplog_instance:await_apply(A),

    %% B writes AFTER (higher HLCs) and self-root-confirm compacts, so
    %% B's watermark lands ABOVE A's in-flight event which B has never
    %% seen.
    _ = bondy_oplog:append(B, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    _ = bondy_oplog:append(B, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(B),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_instance:root_hash(B)])
    ),
    ?assertNotEqual(undefined, bondy_oplog:current_watermark(B)),

    %% B pulls A. The round completes and A's event sorts at or below
    %% B's watermark: the door folds it inline (fused), so the round
    %% ends with no frontier deficit.
    ?assertMatch(
        {ok, _},
        bondy_oplog_sync_session:run(B, A, #{record_in_peer_state => false})
    ),
    %% The op's effect reached B's projection...
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),
    %% ...the applied VV witnesses it honestly (no max-merge lie)...
    AOrigin = bondy_oplog_instance:origin(A),
    ?assertEqual(1, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),
    %% ...and the fused door still truncated it from the MST after the
    %% fold (fold-before-drop, not keep-forever).
    ?assertEqual(0, bondy_oplog:size(B)),

    teardown(A),
    teardown(B).

%% As above, for an APPLIER-backed (non-fused) instance. The instance
%% process cannot fold cells itself (the applier is the projection's
%% single writer), so the door HOLDS the never-applied event below the
%% watermark — truncating only the prefix strictly below it — and the
%% applier's normal replay applies it; the next compaction cycle then
%% truncates the (now applied) held prefix via the async catch-up gate.
watermark_door_holds_unapplied_peer_event_applier() ->
    A = start_applier_instance(),
    B = start_applier_instance(),
    BNs = ns_of(B),

    _ = bondy_oplog:append(A, {cell_apply, ?B, <<"doored">>, {inc, 5}}),
    ok = bondy_oplog_instance:await_apply(A),

    _ = bondy_oplog:append(B, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    _ = bondy_oplog:append(B, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(B),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_instance:root_hash(B)])
    ),
    ?assertNotEqual(undefined, bondy_oplog:current_watermark(B)),

    %% B pulls A: the door holds A's event; the session's settle
    %% (instance drain + applier barrier) covers the replay, so the
    %% round ends deficit-free.
    ?assertMatch(
        {ok, _},
        bondy_oplog_sync_session:run(B, A, #{record_in_peer_state => false})
    ),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),
    AOrigin = bondy_oplog_instance:origin(A),
    ?assertEqual(1, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),
    %% The held event is still in the MST (below the watermark) — the
    %% hold is what kept it alive for the applier's replay.
    ?assert(bondy_oplog:size(B) >= 1),

    %% Next compaction cycle folds-then-truncates the held prefix.
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_instance:root_hash(B)])
    ),
    ?assertEqual(0, bondy_oplog:size(B)),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),

    teardown(A),
    teardown(B).

%% THE LIVE-EVENT WATERMARK DOOR, fused: a never-applied peer event
%% pushed via `append_remote/2` whose key sorts at or below the local
%% watermark must be accepted — folded into the projection inline —
%% not silently dropped on key order (the page-sync door's premise
%% "at or below the watermark ⇒ already folded" is just as false for
%% a live single event).
live_door_accepts_unapplied_remote_event_fused() ->
    A = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    B = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    BNs = ns_of(B),

    %% A mints the in-flight event FIRST — the lowest HLC in this test.
    KA = bondy_oplog:append(A, {cell_apply, ?B, <<"doored">>, {inc, 5}}),
    ok = bondy_oplog_instance:await_apply(A),
    {ok, EventA} = bondy_oplog:get(A, KA),

    %% B writes AFTER (higher HLCs) and self-root-confirm compacts, so
    %% B's watermark lands ABOVE A's in-flight event.
    _ = bondy_oplog:append(B, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    _ = bondy_oplog:append(B, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(B),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_instance:root_hash(B)])
    ),
    ?assertNotEqual(undefined, bondy_oplog:current_watermark(B)),

    %% Live push of the at-or-below-watermark event. Fused delivery is
    %% inline: the op's effect is visible as soon as the call returns.
    ?assertEqual(ok, bondy_oplog:append_remote(B, EventA)),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),
    %% The applied VV witnesses it honestly.
    AOrigin = bondy_oplog_instance:origin(A),
    ?assertEqual(1, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),
    %% The event was installed (not dropped); the next compaction
    %% truncates it as applied history with the projection intact.
    ?assert(bondy_oplog:size(B) >= 1),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_instance:root_hash(B)])
    ),
    ?assertEqual(0, bondy_oplog:size(B)),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),

    teardown(A),
    teardown(B).

%% As above, for an APPLIER-backed instance: the accept installs the
%% event below the watermark (a hold) and the delivery point fences +
%% casts the applier replay; the async catch-up gate keeps every later
%% truncation from eating it un-folded.
live_door_accepts_unapplied_remote_event_applier() ->
    A = start_applier_instance(),
    B = start_applier_instance(),
    BNs = ns_of(B),

    KA = bondy_oplog:append(A, {cell_apply, ?B, <<"doored">>, {inc, 5}}),
    ok = bondy_oplog_instance:await_apply(A),
    {ok, EventA} = bondy_oplog:get(A, KA),

    _ = bondy_oplog:append(B, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    _ = bondy_oplog:append(B, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(B),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_instance:root_hash(B)])
    ),
    ?assertNotEqual(undefined, bondy_oplog:current_watermark(B)),

    ?assertEqual(ok, bondy_oplog:append_remote(B, EventA)),
    %% Applier delivery is async — settle on the applier barrier (it
    %% runs the I1 fence, so even a lost replay cast is covered).
    ok = bondy_oplog_applier:barrier(
        bondy_oplog_registry:applier_pid(B)
    ),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),
    AOrigin = bondy_oplog_instance:origin(A),
    ?assertEqual(1, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),
    ?assert(bondy_oplog:size(B) >= 1),

    %% Next compaction cycle folds-then-truncates the held prefix.
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_instance:root_hash(B)])
    ),
    ?assertEqual(0, bondy_oplog:size(B)),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),

    teardown(A),
    teardown(B).

%% The idempotent half of the live door: an ALREADY-applied event
%% re-pushed after compaction truncated it must still be dropped —
%% no MST reinstall, no double-apply.
live_filter_drops_already_applied_remote_event() ->
    A = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    B = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    BNs = ns_of(B),

    KA = bondy_oplog:append(A, {cell_apply, ?B, <<"applied">>, {inc, 5}}),
    ok = bondy_oplog_instance:await_apply(A),
    {ok, EventA} = bondy_oplog:get(A, KA),

    %% B applies it the normal way (page sync), then compacts past it.
    ?assertMatch(
        {ok, _},
        bondy_oplog_sync_session:run(B, A, #{record_in_peer_state => false})
    ),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"applied">>)
    ),
    _ = bondy_oplog:append(B, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(B),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_instance:root_hash(B)])
    ),
    ?assertEqual(0, bondy_oplog:size(B)),

    %% The re-push is witnessed by the applied VV → filtered.
    ?assertEqual(ok, bondy_oplog:append_remote(B, EventA)),
    ?assertEqual(0, bondy_oplog:size(B)),
    AOrigin = bondy_oplog_instance:origin(A),
    ?assertEqual(1, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),

    teardown(A),
    teardown(B).

%% Above-watermark live push, fused: `append_remote/2` is a remote
%% DELIVERY, not just an MST install — the projection reflects the op
%% as soon as the call returns, without waiting for the next AE round.
live_append_remote_reaches_projection_fused() ->
    A = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    B = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    BNs = ns_of(B),

    KA = bondy_oplog:append(A, {cell_apply, ?B, <<"live">>, {inc, 3}}),
    ok = bondy_oplog_instance:await_apply(A),
    {ok, EventA} = bondy_oplog:get(A, KA),

    ?assertEqual(ok, bondy_oplog:append_remote(B, EventA)),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"live">>)
    ),
    AOrigin = bondy_oplog_instance:origin(A),
    ?assertEqual(1, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),

    teardown(A),
    teardown(B).

%% As above for an applier-backed instance: the delivery point casts
%% the replay and bumps the I1 fence, so the applier barrier suffices
%% — no AE round needed.
live_append_remote_reaches_projection_applier() ->
    A = start_applier_instance(),
    B = start_applier_instance(),
    BNs = ns_of(B),

    KA = bondy_oplog:append(A, {cell_apply, ?B, <<"live">>, {inc, 3}}),
    ok = bondy_oplog_instance:await_apply(A),
    {ok, EventA} = bondy_oplog:get(A, KA),

    ?assertEqual(ok, bondy_oplog:append_remote(B, EventA)),
    ok = bondy_oplog_applier:barrier(
        bondy_oplog_registry:applier_pid(B)
    ),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"live">>)
    ),
    AOrigin = bondy_oplog_instance:origin(A),
    ?assertEqual(1, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),

    teardown(A),
    teardown(B).

frontier_gap_detected_after_peer_truncation() ->
    Retention = #{max_age_ms => 0, max_events => 1},
    A = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, Retention),
    B = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, Retention),
    ANs = ns_of(A),
    BNs = ns_of(B),

    %% Round 0: A writes, B pulls — both converged.
    _ = bondy_oplog:append(A, {cell_apply, ?B, <<"k1">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(A),
    {ok, _} = bondy_oplog:sync(B, A),
    ok = bondy_oplog_instance:await_apply(B),

    %% A writes MORE and retention-truncates them before B ever syncs.
    _ = bondy_oplog:append(A, {cell_apply, ?B, <<"k2">>, {inc, 1}}),
    _ = bondy_oplog:append(A, {cell_apply, ?B, <<"k3">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(A),
    ?assertMatch(
        {ok, {compacted, _, _}}, bondy_oplog_instance:compact(A, [])
    ),
    ?assertEqual(0, bondy_oplog:size(A)),

    %% B's next round completes against A's (now truncated) live window —
    %% and must surface the deficit instead of adopting A's frontier.
    BFrontier0 = bondy_oplog_registry:frontier(B),
    ?assertMatch(
        {error, {frontier_gap, [_ | _]}},
        bondy_oplog_sync_session:run(B, A, #{record_in_peer_state => false})
    ),
    ?assertEqual(BFrontier0, bondy_oplog_registry:frontier(B)),

    %% Remedy: catalogue bootstrap B <- A (data + frontier), after which
    %% the same round passes clean.
    {ok, {_W, Cursor}} = bondy_oplog_catalogue_snapshot:init(A),
    Cells = pull_snapshot(A, Cursor, []),
    {ok, _Counts} = bondy_oplog_instance:install_catalogue_batch(
        B, {replace, Cells}
    ),
    ok = bondy_oplog_instance:finalize_catalogue_bootstrap(
        B, 0, bondy_oplog_registry:frontier(A), true
    ),
    ?assertMatch(
        {ok, _},
        bondy_oplog_sync_session:run(B, A, #{record_in_peer_state => false})
    ),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"k2">>)
    ),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"k3">>)
    ),
    _ = ANs,

    teardown(A),
    teardown(B).

%% A live re-bootstrap's `replace`-mode install clobbers a per-Origin-
%% accumulating cell when the peer's copy has a HIGHER HLC yet omits ops
%% the peer had not applied when its snapshot was cut. The clobbered ops
%% are covered by the local applied-frontier VV, so no oracle ever flags
%% the loss — the designed remedy is the post-bootstrap rederive
%% (re-apply every retained MST event; already-held ops are rejected by
%% the kernel's causal metadata, missing ops integrate), which used to
%% silently NO-OP for fused instances. This pins the fused branch:
%% clobber observed → rederive heals → rederive is idempotent.
rederive_restores_cell_clobbered_by_live_bootstrap() ->
    A = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    B = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    ANs = ns_of(A),
    BNs = ns_of(B),
    K = <<"k_clobber">>,

    %% B applies its own inc first; A applies a LATER (higher-HLC) inc on
    %% the same key without ever seeing B's — so A's cell has the higher
    %% HLC but misses B's contribution.
    _ = bondy_oplog:append(B, {cell_apply, ?B, K, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(B),
    _ = bondy_oplog:append(A, {cell_apply, ?B, K, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(A),
    ?assertMatch({1, _}, bondy_oplog_core:read(ANs, primary, K)),
    ?assertMatch({1, _}, bondy_oplog_core:read(BNs, primary, K)),

    %% Live re-bootstrap B <- A: skip-if-older replaces B's cell with A's
    %% higher-HLC copy — B's own inc is now gone from the projection while
    %% B's frontier still covers it. The undetectable-divergence state.
    {ok, {_W, Cursor}} = bondy_oplog_catalogue_snapshot:init(A),
    Cells = pull_snapshot(A, Cursor, []),
    {ok, #{installed := 1}} = bondy_oplog_instance:install_catalogue_batch(
        B, {replace, Cells}
    ),
    ?assertMatch({1, _}, bondy_oplog_core:read(BNs, primary, K)),

    %% The remedy: rederive re-applies B's retained MST events over the
    %% installed cell; B's inc integrates (it is absent from A's copy),
    %% converging to both contributions.
    ok = bondy_oplog_instance:rederive_projection(B),
    ?assertMatch({2, _}, bondy_oplog_core:read(BNs, primary, K)),

    %% Idempotent: a second full re-apply must not double-count — the
    %% kernel rejects ops the cell already holds.
    ok = bondy_oplog_instance:rederive_projection(B),
    ?assertMatch({2, _}, bondy_oplog_core:read(BNs, primary, K)),

    teardown(A),
    teardown(B).

%% Truncation must PHYSICALLY reclaim the dropped history's pages, not
%% just unlink them: `bondy_mst:truncate/2` frees only the spine pages it
%% rewrites and leaves the dropped subtrees unreachable in the page
%% store, and nothing else ever ran the store's GC — so shards whose
%% event count read 0 still pinned their whole history as orphaned ETS
%% pages (the residual RAM plateau after the scheduler-starvation fix;
%% ~5 GB/node at fleet scale). Pins `truncate_below_or_equal/3`'s
%% mark-and-sweep on the ephemeral backend, asserted at the ETS level —
%% the blind spot every event-count assertion missed.
truncation_reclaims_store_pages() ->
    Retention = #{max_age_ms => 0, max_events => 10},
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, Retention),
    _ = [
        bondy_oplog:append(
            Id,
            {cell_apply, ?B, <<"page_", (integer_to_binary(N))/binary>>,
                {inc, 1}}
        )
     || N <- lists:seq(1, 500)
    ],
    ok = bondy_oplog_instance:await_apply(Id),
    ?assert(bondy_oplog:size(Id) > 10),
    RowsBefore = instance_page_rows(Id),
    ?assert(RowsBefore > 100),

    ?assertMatch(
        {ok, {compacted, _, _}}, bondy_oplog_instance:compact(Id, [])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),

    %% The empty tree keeps at most a handful of rows (root marker +
    %% stragglers of the current version) — orders of magnitude below the
    %% pre-compaction page count, and NOT retained wholesale.
    RowsAfter = instance_page_rows(Id),
    ?assert(
        RowsAfter < RowsBefore div 10,
        lists:flatten(
            io_lib:format(
                "expected the page store to shrink 10x+ on truncation, "
                "got ~p -> ~p rows",
                [RowsBefore, RowsAfter]
            )
        )
    ),

    teardown(Id).

%% The MST page table is the largest ETS table owned by the instance
%% gen_server (unnamed; the projection/cache tables belong to the shard
%% registration, not the instance process).
instance_page_rows(Id) ->
    Pid = bondy_oplog_instance:whereis(Id),
    Sizes = [
        ets:info(T, size)
     || T <- ets:all(),
        ets:info(T, owner) =:= Pid,
        is_integer(ets:info(T, size))
    ],
    lists:max([0 | Sizes]).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Pulls the complete snapshot stream off a cursor session.
pull_snapshot(Id, Cursor, Acc) ->
    case bondy_oplog_catalogue_snapshot:next(Id, Cursor) of
        {ok, {batch, {NextCursor, Cells}}} ->
            pull_snapshot(Id, NextCursor, Acc ++ Cells);
        {ok, {done, Cells}} ->
            Acc ++ Cells
    end.

start_fused_instance(CrdtModule, CrdtOpts, Retention) ->
    Id = mk_id(),
    NS = ns_of(Id),
    _ = register_shard(NS, primary, 0, CrdtModule, CrdtOpts),
    Opts0 = #{
        fold_module => lww_register,
        origin => bondy_oplog_origin:new(),
        fused => true,
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    },
    Opts =
        case Retention of
            undefined -> Opts0;
            #{} -> Opts0#{mst_retention => Retention}
        end,
    {ok, _} = bondy_oplog:start_instance(Id, Opts),
    Id.

start_applier_instance() ->
    Id = mk_id(),
    NS = ns_of(Id),
    _ = register_shard(NS, primary, 0, bondy_oplog_crdt_pn_counter, #{}),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        origin => bondy_oplog_origin:new(),
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }),
    Id.

register_shard(NS, Index, Shard, CrdtModule, CrdtOpts) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register,
        crdt_module => CrdtModule,
        crdt_opts => CrdtOpts
    }),
    {Cache, Proj}.

close_shard(Cache, Proj) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

%% Like `register_shard/5` but also stamps `instance_id`/`cell_apply_bucket`
%% on the registry entry — the multi-table mux shape
%% (`bondy_oplog_applier_multiplex_test.erl`'s `register_shard/3`) — so the
%% shared instance can route events for this table by `Bucket`.
register_shard_with_bucket(NS, InstanceId, Bucket, CrdtModule, CrdtOpts) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register,
        crdt_module => CrdtModule,
        crdt_opts => CrdtOpts,
        instance_id => InstanceId,
        cell_apply_bucket => Bucket
    }),
    {Cache, Proj}.

mk_id() ->
    iolist_to_binary([
        "compact_fused_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

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
