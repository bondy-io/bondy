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
%% These tests pin, on a held cycle (clustering enabled, no witness):
%% retention truncates on size and age breaches; no retention ⇒ defer;
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
        {timeout, 30, fun held_fused_without_retention_defers/0},
        {timeout, 30, fun fused_compaction_waits_for_every_member/0},
        {timeout, 30, fun retention_size_breach_truncates/0},
        {timeout, 30, fun retention_age_breach_truncates/0},
        {timeout, 30, fun retention_below_thresholds_defers/0},
        {timeout, 30, fun retention_requires_fused_rejected/0},
        {timeout, 30, fun retention_truncate_vs_drain_race/0},
        {timeout, 30, fun retention_compaction_is_idempotent/0},
        {timeout, 30, fun self_root_confirms_ephemeral_fused_compacts/0},
        {timeout, 30, fun mux_shard_both_tables_compact_together/0},
        {timeout, 30, fun fused_catalogue_bootstrap_roundtrip/0},
        {timeout, 30, fun watermark_door_folds_unapplied_peer_event_fused/0},
        {timeout, 30, fun watermark_door_holds_unapplied_peer_event_applier/0},
        {timeout, 30,
            fun compaction_holds_doored_event_until_applied_watermark_path/0},
        {timeout, 30,
            fun compaction_holds_doored_event_until_applied_frontier_path/0},
        {timeout, 30, fun compaction_truncates_held_event_of_retired_origin/0},
        {timeout, 30, fun peer_compaction_does_not_stall_ours/0},
        {timeout, 30, fun rootless_live_peer_holds_compaction/0},
        {timeout, 30, fun live_door_accepts_unapplied_remote_event_fused/0},
        {timeout, 30, fun live_door_accepts_unapplied_remote_event_applier/0},
        {timeout, 30, fun live_filter_drops_already_applied_remote_event/0},
        {timeout, 30, fun live_append_remote_reaches_projection_fused/0},
        {timeout, 30, fun live_append_remote_reaches_projection_applier/0},
        {timeout, 30, fun frontier_gap_detected_after_peer_truncation/0},
        {timeout, 30, fun rederive_restores_cell_clobbered_by_live_bootstrap/0},
        {timeout, 30,
            fun live_bootstrap_with_churn_between_batches_converges/0},
        {timeout, 30, fun unservable_own_root_self_heals_when_peers_dominate/0},
        {timeout, 30,
            fun unservable_own_root_self_heals_when_right_edge_lost/0},
        {timeout, 30, fun unservable_own_root_holds_until_peers_dominate/0},
        {timeout, 30,
            fun unservable_own_root_rebuild_holds_unapplied_applier/0},
        {timeout, 30, fun truncation_reclaims_store_pages/0}
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

%% Without a retention policy, a held cycle on a fused instance defers: no
%% witness confirms anything.
held_fused_without_retention_defers() ->
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    K = <<"vehicle_0">>,
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, 1}}),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, K, {inc, -1}}),
    ok = bondy_oplog_instance:await_apply(Id),
    SizeBefore = bondy_oplog:size(Id),
    ?assert(SizeBefore >= 1),

    ?assertEqual({ok, no_change}, held_compact(Id)),
    ?assertEqual(SizeBefore, bondy_oplog:size(Id)),

    teardown(Id).

%% One member synced just now and claims everything; the other never
%% confirmed. Truncating on the recent member alone would leave the silent one
%% behind this replica's truncation record for good, so nothing is cut.
fused_compaction_waits_for_every_member() ->
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"k">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(Id),
    SizeBefore = bondy_oplog:size(Id),
    ok = bondy_oplog_peer_state:record_sync_complete(
        {peer, live},
        Id,
        bondy_oplog_registry:frontier(Id),
        os:system_time(millisecond)
    ),
    bondy_oplog_test_helpers:with_cluster(
        [{peer, live}, {peer, silent}],
        fun() ->
            ?assertEqual(
                {error, {unconfirmed, [{peer, silent}]}},
                bondy_oplog:compact(Id)
            )
        end
    ),
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
        {ok, {compacted, _, _}}, held_compact(Id)
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
        {ok, {compacted, _, _}}, held_compact(Id)
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

    ?assertEqual({ok, no_change}, held_compact(Id)),
    ?assertEqual(SizeBefore, bondy_oplog:size(Id)),

    teardown(Id).

%% Retention on a non-fused instance is rejected at start — retention
%% requires fused (⇒ ephemeral, enforced upstream): a durable instance's
%% history must never be bounded by local policy.
retention_requires_fused_rejected() ->
    Id = mk_id(),
    ?assertMatch(
        {error, _},
        bondy_oplog_test_projection:start_instance(Id, #{
            origin => bondy_oplog_origin:new(),
            mst_retention => #{max_age_ms => 1000, max_events => 10}
        })
    ).

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
    _ = held_compact(Id),
    ok = bondy_oplog_instance:await_apply(Id),

    Missing = [
        K
     || K <- Keys, bondy_oplog_core:read(NS, primary, K) =:= undefined
    ],
    ?assertEqual([], Missing),

    %% And the tree is (or becomes, one more cycle) bounded BY THE
    %% POLICY: events that raced in above the first cycle's watermark
    %% survive it, and a follow-up cycle truncates them only while the
    %% size still BREACHES max_events — exactly 1 event left is at the
    %% bound, not over it, and correctly defers.
    _ = held_compact(Id),
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
        {ok, {compacted, _, _}}, held_compact(Id)
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),
    Watermark1 = bondy_oplog:current_watermark(Id),
    ?assertNotEqual(undefined, Watermark1),

    ?assertEqual({ok, no_change}, held_compact(Id)),
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

    Witness = bondy_oplog_registry:frontier(Id),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(Id, [Witness])
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),

    teardown(Id).

%% Regression-lock for the real registry mux shape: one fused instance
%% multiplexing TWO tables with heterogeneous CRDT kernels, distinguished by
%% `Bucket` (`bondy_oplog_crdt_pn_counter` founding the instance as
%% `?BUCKET_SUB`, with `bondy_oplog_crdt_struct` joining at runtime via
%% `register_table/4` as `?BUCKET_REG`), as the registry's two RIB tables do.
%% The core compaction mechanism operates purely on the MST as a flat key/value
%% tree, so it is mux-agnostic; the case self-root-confirms and asserts
%% combined size returns to 0 across both tables.
mux_shard_both_tables_compact_together() ->
    Id = mk_id(),
    NsSub = ns_of(Id),
    NsReg = binary_to_atom(<<"reg_", Id/binary>>, utf8),

    {SubCache, SubProj} = register_shard_with_bucket(
        NsSub, Id, ?BUCKET_SUB, bondy_oplog_crdt_pn_counter, #{}
    ),
    {ok, _} = bondy_oplog:start_instance(Id, #{
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

    Witness = bondy_oplog_registry:frontier(Id),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(Id, [Witness])
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
%% with FUSED source and target: a producer resolving the projection target
%% through the applier pid answers `{ok, no_snapshot}` for any fused
%% instance, and an installer keyed the same way refuses with
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
    ?assertMatch(
        {ok, {compacted, _, _}}, bondy_oplog_instance:compact(SrcId, [])
    ),
    ?assertEqual(0, bondy_oplog:size(SrcId)),

    {ok, {_Watermark, Cursor, _}} = bondy_oplog_catalogue_snapshot:init(SrcId),
    Cells = pull_snapshot(SrcId, Cursor, []),
    Buckets = lists:usort([B || {B, _K, _F} <- Cells]),
    ?assertEqual([?BUCKET_REG, ?BUCKET_SUB], Buckets),
    ?assertEqual(2, length(Cells)),

    TgtId = mk_id(),
    TgtNsSub = ns_of(TgtId),
    TgtNsReg = binary_to_atom(<<"reg_", TgtId/binary>>, utf8),
    {TC1, TP1} = register_shard_with_bucket(
        TgtNsSub, TgtId, ?BUCKET_SUB, bondy_oplog_crdt_pn_counter, #{}
    ),
    {ok, _} = bondy_oplog:start_instance(TgtId, #{
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

    %% The rederive adopts the source's applied-frontier VV — without it a
    %% snapshot-seeded replica converges by data but never by the oracle.
    SrcFrontier = bondy_oplog_registry:frontier(SrcId),
    ?assertNotEqual(#{}, SrcFrontier),
    {ok, Counts} = bondy_oplog_test_helpers:install(TgtId, Cells, SrcFrontier),
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

    ok = bondy_oplog_instance:finalize_catalogue_bootstrap(TgtId, 0, 0, true),
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

%% THE WATERMARK DOOR (fused). A peer event whose key sorts at or below
%% this replica's watermark can arrive AFTER the watermark advanced: the
%% peer-confirmed frontier and in-flight events race by design under
%% concurrent writes. Discarding such an event UNAPPLIED at the watermark
%% re-truncate loses data silently — the op never reaches this replica's
%% projection, and the applied VV max-merges past the hole on the next
%% same-origin apply, masking the loss from every oracle. The door must FOLD
%% a never-applied event into the projection (advancing the VV) before
%% dropping it.
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
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
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
    %% ...and, with no witness to confirm it, it stays in the tree, so B can
    %% still ship it. Once A's row confirms it, compaction drops it.
    ?assertEqual(1, bondy_oplog:size(B)),
    {ok, _} = bondy_oplog_sync_session:run(B, A, #{}),
    ok = bondy_oplog_peer_state:sync(),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [
            F
         || #{frontier := F} <- bondy_oplog_peer_state:get_instance_peer_states(
                B, 0
            )
        ])
    ),
    ?assertEqual(0, bondy_oplog:size(B)),

    teardown(A),
    teardown(B).

%% As above, for an APPLIER-backed (non-fused) instance. The instance
%% process cannot fold cells itself (the applier is the projection's
%% single writer), so the door HOLDS the never-applied event below the
%% watermark — truncating only the prefix strictly below it — and the
%% applier's normal replay applies it; the next compaction cycle then
%% truncates the (now applied) held prefix.
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
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
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

    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
    ),
    ?assertEqual(0, bondy_oplog:size(B)),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),

    teardown(A),
    teardown(B).

%% A NEVER-APPLIED EVENT BELOW THE WATERMARK STAYS UNTIL APPLIED: the door
%% holds A's never-applied event below B's watermark, and a compaction tick
%% lands BEFORE the applier's replay has folded it. The tick must be a
%% `no_change`; the event must reach the projection once the applier
%% runs; the next tick then truncates it. B's own durable frontier, a
%% witness, does not cover the event, so the test passes with the compaction
%% cap disabled too.
%%
%% The applier is `sys:suspend`ed so the replay cannot race the tick;
%% the pages are pulled by hand because the sync session's settle
%% barrier would block on the suspended applier.
compaction_holds_doored_event_until_applied_watermark_path() ->
    A = start_applier_instance(),
    B = start_applier_instance(),
    BNs = ns_of(B),

    KA = bondy_oplog:append(A, {cell_apply, ?B, <<"doored">>, {inc, 5}}),
    ok = bondy_oplog_instance:await_apply(A),
    W = compact_above(B, KA),
    ?assertEqual(0, bondy_oplog:size(B)),

    ApplierPid = bondy_oplog_registry:applier_pid(B),
    ok = sys:suspend(ApplierPid),
    ok = pull_root(B, A),
    %% Held: below the watermark, not applied.
    ?assertEqual(1, bondy_oplog:size(B)),
    AOrigin = bondy_oplog_instance:origin(A),
    ?assertEqual(0, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),

    %% The tick beats the replay. Frontier = the held key =< W, so this
    %% is the below-watermark trim path: it must hold, not truncate.
    ?assertEqual(
        {ok, no_change},
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
    ),
    ?assertEqual(1, bondy_oplog:size(B)),
    ?assertEqual(W, bondy_oplog:current_watermark(B)),

    ok = sys:resume(ApplierPid),
    ok = bondy_oplog_applier:barrier(ApplierPid),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),
    ?assertEqual(1, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),

    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
    ),
    ?assertEqual(0, bondy_oplog:size(B)),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),

    teardown(A),
    teardown(B).

%% As above on the peer-confirmed FRONTIER path: B also holds an applied
%% own event ABOVE its watermark, so the confirmed frontier advances past
%% the watermark and the tick reaches `finalize_catalogue_compaction/4`
%% with a frontier above the held key. The cap must still hold the whole
%% tree: the held key is
%% the tree's smallest, so nothing may go, including the applied own
%% event above it (truncation is a prefix).
compaction_holds_doored_event_until_applied_frontier_path() ->
    A = start_applier_instance(),
    B = start_applier_instance(),
    BNs = ns_of(B),

    KA = bondy_oplog:append(A, {cell_apply, ?B, <<"doored">>, {inc, 5}}),
    ok = bondy_oplog_instance:await_apply(A),
    W = compact_above(B, KA),
    %% An applied own event above the watermark: the frontier candidate.
    _ = bondy_oplog:append(B, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(B),
    ?assertEqual(1, bondy_oplog:size(B)),

    ApplierPid = bondy_oplog_registry:applier_pid(B),
    ok = sys:suspend(ApplierPid),
    ok = pull_root(B, A),
    ?assertEqual(2, bondy_oplog:size(B)),

    ?assertEqual(
        {ok, no_change},
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
    ),
    ?assertEqual(2, bondy_oplog:size(B)),
    ?assertEqual(W, bondy_oplog:current_watermark(B)),

    ok = sys:resume(ApplierPid),
    ok = bondy_oplog_applier:barrier(ApplierPid),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),
    ?assertMatch(
        {ok, {compacted, _, 2}},
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
    ),
    ?assertEqual(0, bondy_oplog:size(B)),
    ?assert(bondy_oplog:current_watermark(B) > W),

    teardown(A),
    teardown(B).

%% The cap's retired-origin exemption. A held event whose origin is
%% RETIRED after the hold is dropped by the applier's replay
%% (`bondy_oplog_cell_apply:drop_retired/2`) and never raises the VV, so
%% "never applied" is permanent by design, not lag: the cap must let the
%% tick truncate it (and the door's next pass discard it), not hold the
%% tree forever. Retirement needs a `retirement_path`; the bans server is
%% restarted around the test so the retired set does not leak into the
%% rest of this VM.
compaction_truncates_held_event_of_retired_origin() ->
    Dir = filename:join(
        "/tmp", "bondy_oplog_compaction_fused_retire_" ++ os:getpid()
    ),
    _ = file:del_dir_r(Dir),
    ok = application:set_env(
        bondy_oplog, retirement_path, filename:join(Dir, "retired")
    ),
    ok = restart_bans(),
    try
        A = start_applier_instance(),
        B = start_applier_instance(),
        BNs = ns_of(B),

        KA = bondy_oplog:append(A, {cell_apply, ?B, <<"doored">>, {inc, 5}}),
        ok = bondy_oplog_instance:await_apply(A),
        _ = compact_above(B, KA),

        ApplierPid = bondy_oplog_registry:applier_pid(B),
        ok = sys:suspend(ApplierPid),
        ok = pull_root(B, A),
        ?assertEqual(1, bondy_oplog:size(B)),

        %% Retired while held: the replay drops it, the VV stays at 0.
        AOrigin = bondy_oplog_instance:origin(A),
        ok = bondy_oplog_origin_bans:retire(AOrigin, decommissioned),
        ok = sys:resume(ApplierPid),
        ok = bondy_oplog_applier:barrier(ApplierPid),
        ?assertEqual(
            undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
        ),
        ?assertEqual(0, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),

        %% Not "never applied" any more — nothing will ever fold it.
        ?assertMatch(
            {ok, {compacted, _, 1}},
            bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
        ),
        ?assertEqual(0, bondy_oplog:size(B)),

        teardown(A),
        teardown(B)
    after
        ok = application:unset_env(bondy_oplog, retirement_path),
        _ = file:del_dir_r(Dir),
        ok = restart_bans()
    end.

%% THE FRONTIER WITNESS SURVIVES THE PEER'S COMPACTION
%% (`proofs/tla/ConfirmedCompaction_2R_Async_Live.cfg`: every tree empties).
%% A compacts e1 once B confirms it; A then mints e2. A's tree has lost e1,
%% but the durable frontier B records for A still covers it, so B compacts.
%% Drives the production entry (`bondy_oplog_compaction:compact/1`), the
%% one that reads `bondy_oplog_peer_state`, with A and B as the members.
peer_compaction_does_not_stall_ours() ->
    A = start_applier_instance(),
    B = start_applier_instance(),
    AOrigin = bondy_oplog_instance:origin(A),

    _ = bondy_oplog:append(A, {cell_apply, ?B, <<"e1">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(A),
    ?assertMatch({ok, _}, bondy_oplog:sync(B, A)),
    ok = bondy_oplog_peer_state:sync(),
    %% B reported its frontier back (the swap), so A compacts e1.
    ?assertMatch(
        {ok, {compacted, _, 1}},
        bondy_oplog_test_helpers:compact_among(A, [A, B])
    ),
    ?assertEqual(0, bondy_oplog:size(A)),

    KA2 = bondy_oplog:append(A, {cell_apply, ?B, <<"e2">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(A),
    ?assertMatch({ok, _}, bondy_oplog:sync(B, A)),
    ok = bondy_oplog_peer_state:sync(),
    ?assertEqual(2, bondy_oplog:size(B)),

    %% A's tree holds e2 only; the frontier B records for it covers both.
    ?assertEqual(1, bondy_oplog:size(A)),
    [VVA] = [
        F
     || #{peer := P, frontier := F} <-
            bondy_oplog_peer_state:get_instance_peer_states(B, 0),
        P =:= A
    ],
    ?assertEqual(2, maps:get(AOrigin, VVA)),

    ok = compact_to_empty(B, [A, B]),
    ?assertEqual(KA2, bondy_oplog:current_watermark(B)),

    teardown(A),
    teardown(B).

%% A ROW WITH NO FRONTIER HOLDS COMPACTION
%% (`proofs/tla/ConfirmedCompaction_3R.cfg` holds `NoLoss` with every row
%% recording nothing at the start). B holds e1 from A and has completed a round
%% against C, whose tree was empty: C's row has no frontier. C is live and
%% has never received e1, so B must not truncate it. Once C pulls B (and
%% reports its frontier back), B compacts.
rootless_live_peer_holds_compaction() ->
    A = start_applier_instance(),
    B = start_applier_instance(),
    C = start_applier_instance(),

    _ = bondy_oplog:append(A, {cell_apply, ?B, <<"e1">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(A),
    ?assertMatch({ok, _}, bondy_oplog:sync(B, A)),
    ?assertMatch({ok, _}, bondy_oplog:sync(B, C)),
    ok = bondy_oplog_peer_state:sync(),
    ?assertMatch(
        [#{frontier := undefined}],
        [
            S
         || #{peer := P} = S <-
                bondy_oplog_peer_state:get_instance_peer_states(B, 0),
            P =:= C
        ]
    ),
    ?assertEqual(1, bondy_oplog:size(B)),

    ?assertEqual(
        {error, {unconfirmed, [C]}},
        bondy_oplog_test_helpers:compact_among(B, [A, B, C])
    ),
    ?assertEqual(1, bondy_oplog:size(B)),

    ?assertMatch({ok, _}, bondy_oplog:sync(C, B)),
    ok = bondy_oplog_peer_state:sync(),
    ?assertEqual(1, bondy_oplog:size(C)),
    ok = compact_to_empty(B, [A, B, C]),

    teardown(A),
    teardown(B),
    teardown(C).

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
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
    ),
    ?assertNotEqual(undefined, bondy_oplog:current_watermark(B)),

    %% Live push of the at-or-below-watermark event. Fused delivery is
    %% inline: the op's effect is visible as soon as the call returns.
    ?assertEqual(ok, bondy_oplog:append_remote(B, EventA)),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),
    AOrigin = bondy_oplog_instance:origin(A),
    ?assertEqual(1, maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)),
    %% The event was installed (not dropped); the next compaction
    %% truncates it as applied history with the projection intact.
    ?assert(bondy_oplog:size(B) >= 1),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
    ),
    ?assertEqual(0, bondy_oplog:size(B)),
    ?assertNotEqual(
        undefined, bondy_oplog_core:read(BNs, primary, <<"doored">>)
    ),

    teardown(A),
    teardown(B).

%% As above, for an APPLIER-backed instance: the accept installs the
%% event below the watermark (a hold) and the delivery point fences +
%% casts the applier replay; the compaction cap keeps every later
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
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
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

    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
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
        bondy_oplog_instance:compact(B, [bondy_oplog_registry:frontier(B)])
    ),
    ?assertEqual(0, bondy_oplog:size(B)),

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

%% The frontier-GAP detection end to end: a retention peer truncates
%% history a laggard never received; the laggard's next FULL sync round
%% completes but must (a) fail with `{frontier_gap, _}` rather than
%% silently succeed, and (b) NOT adopt the peer's frontier (the adoption's
%% "can never over-claim" argument requires all-peer-confirmed compaction,
%% which retention bypasses — adopting would flip the convergence oracle
%% to CONVERGED over silently missing data). The catalogue bootstrap is
%% then the remedy: after install + finalize the same sync round passes.
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
    {ok, {_W, Cursor, _}} = bondy_oplog_catalogue_snapshot:init(A),
    Cells = pull_snapshot(A, Cursor, []),
    {ok, _Counts} = bondy_oplog_test_helpers:install(
        B, Cells, bondy_oplog_registry:frontier(A)
    ),
    ok = bondy_oplog_instance:finalize_catalogue_bootstrap(B, 0, 0, true),
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

%% A live re-bootstrap's install replaces a per-Origin-accumulating cell
%% with the peer's copy, which omits ops the peer had not applied when its
%% snapshot was cut. The post-bootstrap rederive re-applies every retained
%% MST event: ops the cell holds are rejected by the kernel's causal
%% metadata, missing ops integrate. This pins the fused branch: clobber
%% observed, rederive heals, rederive is idempotent.
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

    %% Live re-bootstrap B <- A: the install replaces B's cell with A's
    %% copy, so B's own inc is gone from the projection while B's frontier
    %% still covers it.
    {ok, {_W, Cursor, Buckets}} = bondy_oplog_catalogue_snapshot:init(A),
    Cells = pull_snapshot(A, Cursor, []),
    {ok, Token} = bondy_oplog_instance:begin_install(B, Buckets, #{}),
    ok = bondy_oplog_instance:install_catalogue_batch(B, Token, Cells),
    ?assertMatch({1, _}, bondy_oplog_core:read(BNs, primary, K)),

    %% The remedy: rederive re-applies B's retained MST events over the
    %% installed cell; B's inc integrates (it is absent from A's copy),
    %% converging to both contributions.
    {ok, #{installed := 1}} = bondy_oplog_instance:rederive_projection(
        B, Token
    ),
    ?assertMatch({2, _}, bondy_oplog_core:read(BNs, primary, K)),

    %% Idempotent: a second full re-apply must not double-count — the
    %% kernel rejects ops the cell already holds.
    {ok, #{installed := 0}} = bondy_oplog_test_helpers:install(B, []),
    ?assertMatch({2, _}, bondy_oplog_core:read(BNs, primary, K)),

    teardown(A),
    teardown(B).

%% The CHURN variant of the clobber/rederive lock: a local op lands BETWEEN
%% install batches of a live re-bootstrap and folds onto B's own cell, since
%% the batches are only staged. The rederive installs A's cell and re-folds
%% both of B's incs, and the full bootstrap sequence (install, rederive,
%% finalize) converges to peer + pre-bootstrap + mid-install contributions.
live_bootstrap_with_churn_between_batches_converges() ->
    A = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    B = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    BNs = ns_of(B),
    K = <<"k_churn">>,

    %% B's own contribution first; A's LATER higher-HLC inc on the same
    %% key (never saw B's) plus a second key so the snapshot splits into
    %% two batches.
    _ = bondy_oplog:append(B, {cell_apply, ?B, K, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(B),
    _ = bondy_oplog:append(A, {cell_apply, ?B, K, {inc, 1}}),
    _ = bondy_oplog:append(A, {cell_apply, ?B, <<"k_other">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(A),

    {ok, {_W, Cursor, Buckets}} = bondy_oplog_catalogue_snapshot:init(A),
    Cells = pull_snapshot(A, Cursor, []),
    ?assertEqual(2, length(Cells)),
    {KCells, OtherCells} = lists:partition(
        fun({_Bucket, CellKey, _Frame}) -> CellKey =:= K end, Cells
    ),

    %% Batch 1 (without K), then the mid-install churn op on K, then
    %% batch 2, whose copy of K the rederive installs.
    {ok, Token} = bondy_oplog_instance:begin_install(
        B, Buckets, bondy_oplog_registry:frontier(A)
    ),
    ok = bondy_oplog_instance:install_catalogue_batch(B, Token, OtherCells),
    _ = bondy_oplog:append(B, {cell_apply, ?B, K, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(B),
    ok = bondy_oplog_instance:install_catalogue_batch(B, Token, KCells),
    ?assertMatch({2, _}, bondy_oplog_core:read(BNs, primary, K)),

    %% The production sequence as `bondy_oplog_sync_session` runs it: the
    %% rederive (frontier adoption, then restores whatever the install
    %% replaced), finalize, then a full AE round against the peer.
    {ok, _} = bondy_oplog_instance:rederive_projection(B, Token),
    ?assertMatch({3, _}, bondy_oplog_core:read(BNs, primary, K)),
    ok = bondy_oplog_instance:finalize_catalogue_bootstrap(B, 0, 0, true),
    ?assertMatch(
        {ok, _},
        bondy_oplog_sync_session:run(B, A, #{record_in_peer_state => false})
    ),
    ?assertMatch({3, _}, bondy_oplog_core:read(BNs, primary, K)),
    ?assertMatch({1, _}, bondy_oplog_core:read(BNs, primary, <<"k_other">>)),

    {ok, _} = bondy_oplog_test_helpers:install(B, []),
    ?assertMatch({3, _}, bondy_oplog_core:read(BNs, primary, K)),

    teardown(A),
    teardown(B).

%% A fused instance whose own root has lost pages can never serve a complete
%% page round again and its walk confirms nothing. Once every member's recorded
%% frontier covers ours, a compaction cycle rebuilds: it drops the tree,
%% advances the watermark, and keeps the projection and the applied frontier.
unservable_own_root_self_heals_when_peers_dominate() ->
    with_unservable_instance(first, fun(Id) ->
        %% The one other member's recorded frontier EQUALS ours, so it
        %% dominates: our surplus is fully covered elsewhere.
        ok = record_row(
            {peer, sh_dominating}, Id, bondy_oplog_registry:frontier(Id)
        ),
        bondy_oplog_test_helpers:with_cluster([{peer, sh_dominating}], fun() ->
            ?assert(compact_rebuilt(Id))
        end),
        %% Rebuilt: tree empty, projection intact, frontier kept, and
        %% the advertise guard is happy again (empty = servable).
        Ns = ns_of(Id),
        ?assertEqual(0, bondy_oplog:size(Id)),
        ?assertNotEqual(
            undefined, bondy_oplog_core:read(Ns, primary, <<"us_1">>)
        ),
        ?assert(map_size(bondy_oplog_registry:frontier(Id)) > 0),
        ?assertNotEqual(undefined, bondy_oplog:current_watermark(Id)),

        _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"us_new">>, {inc, 1}}),
        ok = bondy_oplog_instance:await_apply(Id),
        ?assertNotEqual(
            undefined, bondy_oplog_core:read(Ns, primary, <<"us_new">>)
        )
    end).

%% The rebuild drops the whole tree even when the lost page is the right edge,
%% where `bondy_mst:last/1` finds no key.
unservable_own_root_self_heals_when_right_edge_lost() ->
    with_unservable_instance(right_edge, fun(Id) ->
        ?assertEqual(undefined, bondy_oplog_instance:aae_root(Id)),
        ok = record_row(
            {peer, re_dominating}, Id, bondy_oplog_registry:frontier(Id)
        ),
        bondy_oplog_test_helpers:with_cluster([{peer, re_dominating}], fun() ->
            ?assert(compact_rebuilt(Id))
        end),
        ?assertEqual(undefined, bondy_oplog_instance:root_hash(Id)),
        _ = bondy_oplog:append(Id, {cell_apply, ?B, <<"us_new">>, {inc, 1}}),
        ok = bondy_oplog_instance:await_apply(Id),
        ?assert(is_binary(bondy_oplog_instance:aae_root(Id)))
    end).

%% The cover check, on a single origin with the lost page below the root's
%% first key: the member's recorded frontier covers up to that key only. A walk
%% that skipped the lost page would find every readable key up to it confirmed
%% and truncate there; nothing may be truncated, because no walk can tell
%% whether the member holds the keys it cannot read
%% (`proofs/tla/ConfirmedCompaction_3R_Lost.cfg` holds `NoStrand`;
%% `_3R_Lost_SkipWalk.cfg`, whose walk skips the page, violates it). Once the
%% member covers ours, the next cycle rebuilds.
unservable_own_root_holds_until_peers_dominate() ->
    with_unservable_instance(first, fun(Id) ->
        SizeBefore = bondy_oplog:size(Id),
        Ours = bondy_oplog_registry:frontier(Id),
        ?assertEqual(1, map_size(Ours)),
        {_, RootPage} = root_page(Id),
        {FirstKey, _, _} = hd(bondy_mst_page:list(RootPage)),
        Seq = bondy_oplog_event:key_seq(FirstKey),
        ok = record_row(
            {peer, hb_behind}, Id, maps:map(fun(_, _) -> Seq end, Ours)
        ),
        bondy_oplog_test_helpers:with_cluster([{peer, hb_behind}], fun() ->
            ?assertNot(compact_rebuilt(Id)),
            ?assertEqual(SizeBefore, bondy_oplog:size(Id)),
            ok = record_row({peer, hb_behind}, Id, Ours),
            ?assert(compact_rebuilt(Id)),
            ?assertEqual(0, bondy_oplog:size(Id))
        end)
    end).

%% An applier-backed instance rebuilds too, capped below the first event its
%% applier has not folded. One page is lost below that event, so the walk meets
%% it and the cycle rebuilds. Another is lost above it, so the capped
%% truncation keeps it, the tree stays unservable and no rebuild is reported.
%% Once the applier has folded what it can read and the member covers it, the
%% next cycle drops the page above too and reports the rebuild. The events on
%% that page come back from the peer
%% (`proofs/tla/ConfirmedCompaction_2R_Async_Lost.cfg` holds `NoDrop`;
%% `_2R_Async_Lost_Live.cfg` holds `Convergence`).
unservable_own_root_rebuild_holds_unapplied_applier() ->
    A = start_applier_instance(),
    B = start_applier_instance(),
    try
        ok = append_events(B, 1, 300),
        wait_past_ms(os:system_time(millisecond)),
        H = bondy_oplog:append(A, {cell_apply, ?B, <<"held">>, {inc, 1}}),
        ok = append_events(A, 1, 100),
        ApplierPid = bondy_oplog_registry:applier_pid(B),
        ok = sys:suspend(ApplierPid),
        ok = pull_root(B, A),
        {Tab, _} = root_page(B),
        Subtrees = subtrees(Tab, bondy_oplog_instance:root_hash(B)),
        [Below | _] = [R || {R, _, Hi} <- Subtrees, Hi =/= top, Hi =< H],
        [Above | _] = [R || {R, Lo, _} <- Subtrees, Lo =/= bottom, Lo >= H],
        true = ets:delete(Tab, Below),
        true = ets:delete(Tab, Above),
        ok = record_row(
            {peer, rb_applier}, B, bondy_oplog_registry:frontier(B)
        ),
        bondy_oplog_test_helpers:with_cluster([{peer, rb_applier}], fun() ->
            SizeBefore = bondy_oplog:size(B),
            ?assertNot(compact_rebuilt(B)),
            ?assert(bondy_oplog:size(B) < SizeBefore),
            ?assertEqual(undefined, bondy_oplog_instance:aae_root(B)),
            ok = sys:resume(ApplierPid),
            ok = bondy_oplog_applier:barrier(ApplierPid),
            ok = record_row(
                {peer, rb_applier}, B, bondy_oplog_registry:frontier(B)
            ),
            ?assert(compact_rebuilt(B)),
            ?assert(is_binary(bondy_oplog_instance:aae_root(B))),
            ok = pull_root(B, A),
            ok = bondy_oplog_applier:barrier(ApplierPid),
            AOrigin = bondy_oplog_instance:origin(A),
            ?assertEqual(
                maps:get(AOrigin, bondy_oplog_registry:frontier(A)),
                maps:get(AOrigin, bondy_oplog_registry:frontier(B), 0)
            )
        end)
    after
        teardown(A),
        teardown(B)
    end.

%% Every subtree under the page `Hash` of the page table `Tab`, as
%% `{Ref, Lo, Hi}`: its keys all sort strictly between `Lo` and `Hi`, where
%% `bottom` and `top` are unbounded.
subtrees(Tab, Hash) ->
    subtrees(Tab, Hash, bottom, top).

subtrees(Tab, Hash, Lo, Hi) ->
    [{Hash, Page, _}] = ets:lookup(Tab, Hash),
    Entries = bondy_mst_page:list(Page),
    Keys = [K || {K, _, _} <- Entries],
    Refs = [bondy_mst_page:low(Page) | [R || {_, _, R} <- Entries]],
    lists:append([
        [{R, L, U} | subtrees(Tab, R, L, U)]
     || {R, L, U} <- lists:zip3(Refs, [Lo | Keys], Keys ++ [Hi]),
        is_binary(R)
    ]).

%% Runs `Fun(Id)` on a fused instance holding at least 300 applied events
%% whose own root has lost the page `Pick` selects
%% (`drop_root_referenced_page/2`). The fixture does not ask for the root, so
%% compaction has to find the lost page itself.
with_unservable_instance(Pick, Fun) ->
    Id = start_fused_instance(bondy_oplog_crdt_pn_counter, #{}, undefined),
    try
        ok = append_events(Id, 1, 300),
        ok = await_right_edge(Id, Pick, 301),
        ?assert(bondy_oplog:size(Id) > 100),
        ok = drop_root_referenced_page(Id, Pick),
        Fun(Id)
    after
        teardown(Id)
    end.

append_events(Id, From, To) ->
    _ = [
        bondy_oplog:append(
            Id,
            {cell_apply, ?B, <<"us_", (integer_to_binary(N))/binary>>, {inc, 1}}
        )
     || N <- lists:seq(From, To)
    ],
    bondy_oplog_instance:await_apply(Id).

%% The tree's shape follows the hashes of its keys, so the root's last entry
%% may have no right child: append until it has one.
await_right_edge(_Id, first, _N) ->
    ok;
await_right_edge(Id, right_edge, N) when N < 400 ->
    {_, RootPage} = root_page(Id),
    case lists:last(bondy_mst_page:list(RootPage)) of
        {_, _, R} when is_binary(R) ->
            ok;
        _ ->
            ok = append_events(Id, N, N),
            await_right_edge(Id, right_edge, N + 1)
    end.

%% Runs one compaction cycle on the witnesses the recorded rows give and
%% returns whether it rebuilt the tree: an ordinary truncation may empty an
%% unservable tree too, so its size does not tell the two apart.
compact_rebuilt(Id) ->
    Self = self(),
    HandlerId = {?MODULE, rebuilt, Id},
    ok = telemetry:attach(
        HandlerId,
        [bondy_oplog, instance, mst_rebuilt],
        fun
            (_, _, #{instance_id := I}, _) when I =:= Id ->
                Self ! {rebuilt, I};
            (_, _, _, _) ->
                ok
        end,
        undefined
    ),
    try
        ?assertMatch({ok, _}, bondy_oplog_compaction:compact(Id)),
        receive
            {rebuilt, Id} -> true
        after 0 -> false
        end
    after
        telemetry:detach(HandlerId)
    end.

%% `record_sync_complete/4` is a cast; the call after it makes the row visible
%% before the next compaction reads it.
record_row(Peer, Id, Frontier) ->
    ok = bondy_oplog_peer_state:record_sync_complete(
        Peer, Id, Frontier, os:system_time(millisecond)
    ),
    _ = sys:get_state(bondy_oplog_peer_state),
    ok.

%% Deletes one page referenced by the instance's CURRENT MST root,
%% straight out of the (public) ETS page store — the fault observed
%% live on Fly s16 (2 pages absent from an own root). `first` picks the root's
%% first reference, `right_edge` the right child of its last entry, which holds
%% the tree's largest keys.
drop_root_referenced_page(Id, Pick) ->
    {Tab, RootPage} = root_page(Id),
    Ref =
        case Pick of
            first ->
                hd(bondy_mst_page:refs(RootPage));
            right_edge ->
                {_, _, R} = lists:last(bondy_mst_page:list(RootPage)),
                R
        end,
    true = ets:delete(Tab, Ref),
    ok.

%% The instance's page table, the instance-owned ETS table holding the store's
%% `<<"$root">>` row, and its current root page.
root_page(Id) ->
    Pid = bondy_oplog_instance:whereis(Id),
    [Tab] = [
        T
     || T <- ets:all(),
        ets:info(T, owner) =:= Pid,
        ets:info(T, type) =:= set,
        try
            ets:lookup(T, <<"$root">>) =/= []
        catch
            _:_ -> false
        end
    ],
    [{<<"$root">>, RootHash}] = ets:lookup(Tab, <<"$root">>),
    [{RootHash, RootPage, _}] = ets:lookup(Tab, RootHash),
    {Tab, RootPage}.

%% Truncation must PHYSICALLY reclaim the dropped history's pages, not
%% just unlink them: `bondy_mst:truncate/2` frees only the spine pages it
%% rewrites and leaves the dropped subtrees unreachable in the page
%% store, and nothing else ever ran the store's GC — so shards whose
%% event count read 0 still pinned their whole history as orphaned ETS
%% pages (the residual RAM plateau after the scheduler-starvation fix;
%% ~5 GB/node at fleet scale). Pins `truncate_below_or_equal/4`'s
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

%% Writes two own events on `Local` and self-root-confirm compacts them, so
%% its watermark lands strictly ABOVE `Key` (an event minted elsewhere
%% just before). Event keys sort by HLC physical ms first, and two
%% instances minting within the same ms order by origin — random — so the
%% ms is forced past `Key`'s before writing; the precondition is asserted
%% rather than assumed.
compact_above(Local, Key) ->
    {KeyMs, _} = bondy_connect_hlc:decode(bondy_oplog_event:key_hlc(Key)),
    wait_past_ms(KeyMs),
    _ = bondy_oplog:append(Local, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    _ = bondy_oplog:append(Local, {cell_apply, ?B, <<"own">>, {inc, 1}}),
    ok = bondy_oplog_instance:await_apply(Local),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(Local, [
            bondy_oplog_registry:frontier(Local)
        ])
    ),
    W = bondy_oplog:current_watermark(Local),
    ?assert(Key < W),
    W.

wait_past_ms(Ms) ->
    case os:system_time(millisecond) > Ms of
        true ->
            ok;
        false ->
            timer:sleep(1),
            wait_past_ms(Ms)
    end.

%% Runs the production compaction entry and asserts the tree emptied. A
%% refusal (`{ok, no_change}`) is the failure this guards. The applier is
%% settled first so a not-yet-folded remote event cannot make the cap hold
%% for a reason unrelated to the witness under test.
compact_to_empty(Id, Cluster) ->
    ok = bondy_oplog_applier:barrier(bondy_oplog_registry:applier_pid(Id)),
    case bondy_oplog_test_helpers:compact_among(Id, Cluster) of
        {ok, {compacted, _, _}} -> await_size(Id, 0, 0);
        Other -> erlang:error({compaction_refused, Other})
    end.

await_size(Id, Size, N) ->
    case bondy_oplog:size(Id) of
        Size ->
            ok;
        _ when N > 0 ->
            timer:sleep(10),
            await_size(Id, Size, N - 1);
        Other ->
            erlang:error({size_mismatch, #{expected => Size, got => Other}})
    end.

%% One page-sync round by hand: pull every page reachable from the peer's
%% current root, then integrate it. The inline transport's `get_root`
%% form is not used because it drains the PEER's applier; here the peer
%% is already settled and it is the LOCAL applier that is suspended.
pull_root(Local, Peer) ->
    Root = bondy_oplog_instance:root_hash(Peer),
    ok = pull_missing(Local, Peer, Root),
    bondy_oplog_instance:integrate_peer_root(Local, Root).

pull_missing(Local, Peer, Root) ->
    case bondy_oplog_instance:missing_set(Local, Root) of
        [] ->
            ok;
        Missing ->
            {ok, Pages} = bondy_oplog_transport_inline:request(
                Peer, Local, {get_pages, Missing}, #{}
            ),
            ok = bondy_oplog_instance:merge_pages(Local, Pages),
            pull_missing(Local, Peer, Root)
    end.

restart_bans() ->
    _ = supervisor:terminate_child(bondy_oplog_sup, bondy_oplog_origin_bans),
    {ok, _} = supervisor:restart_child(
        bondy_oplog_sup, bondy_oplog_origin_bans
    ),
    ok.

%% A cycle with no witness on a node with clustering enabled: the held cycle
%% `bondy_oplog_compaction:compact/1` runs, the one retention applies to.
held_compact(Id) ->
    bondy_oplog_test_helpers:with_members(
        fun() -> [partisan:node()] end,
        fun() -> bondy_oplog_instance:compact(Id, []) end
    ).

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
