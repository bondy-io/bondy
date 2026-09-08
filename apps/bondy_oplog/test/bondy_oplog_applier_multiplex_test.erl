%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Proves the per-shard multiplexer: ONE oplog instance (one WAL + MST + applier)
%% serving TWO tables, distinguished by the `Bucket` carried in each
%% `{cell_apply, Bucket, Key, FoldEvent}` event. The founding table seeds the
%% applier's cell-apply directory (via `cell_apply_bucket`, putting the applier
%% in `{dir, _}` mode); a second table joins the SAME instance at runtime with
%% `bondy_oplog_applier:register_table/4`. Each table's cells must land in its
%% OWN projection (registered under its own namespace), with no cross-bucket
%% contamination even for an identical key — the core premise of the
%% one-log-per-shard collapse.
%% =============================================================================
-module(bondy_oplog_applier_multiplex_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([prop_adoption_survives_any_batching/0]).

-define(BUCKET_A, <<"table_a">>).
-define(BUCKET_B, <<"table_b">>).

multiplex_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun two_tables_one_instance_project_independently/0,
        fun unregister_table_stops_routing/0,
        fun siblings_self_heal_from_registry/0,
        fun gated_drain_defers_until_siblings_register/0,
        fun install_catalogue_batch_routes_by_bucket/0,
        fun install_names_the_buckets_it_could_not_route/0,
        fun partial_install_does_not_adopt_the_peer_frontier/0,
        {timeout, 600, fun adoption_survives_any_batching/0}
    ]}.

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

%% =============================================================================
%% Tests
%% =============================================================================

two_tables_one_instance_project_independently() ->
    {Id, NsA, NsB, HA, HB} = setup_two_tables(),

    %% Append cells for BOTH tables through the SAME instance.
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"k">>, {set, 1, <<"va">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"k">>, {set, 1, <<"vb">>}}
    ),
    %% A key shared by the two tables must NOT collide — distinct buckets.
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"shared">>, {set, 2, <<"a2">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"shared">>, {set, 2, <<"b2">>}}
    ),
    _ = bondy_oplog:projection(Id),

    %% Each table's cells materialise in its OWN projection.
    ?assertEqual(
        {<<"va">>, 1}, bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"k">>)
    ),
    ?assertEqual(
        {<<"vb">>, 1}, bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"k">>)
    ),
    ?assertEqual(
        {<<"a2">>, 2},
        bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"shared">>)
    ),
    ?assertEqual(
        {<<"b2">>, 2},
        bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"shared">>)
    ),

    %% No cross-contamination: a namespace never sees the other's bucket.
    ?assertEqual(
        undefined, bondy_oplog_core:read(NsA, primary, ?BUCKET_B, <<"k">>)
    ),
    ?assertEqual(
        undefined, bondy_oplog_core:read(NsB, primary, ?BUCKET_A, <<"k">>)
    ),

    teardown_two_tables(Id, NsA, NsB, HA, HB).

unregister_table_stops_routing() ->
    {Id, NsA, NsB, HA, HB} = setup_two_tables(),
    ApplierPid = bondy_oplog_registry:applier_pid(Id),

    %% Drop table B: its events now resolve to no ctx and are skipped
    %% (logged), while table A keeps projecting.
    ok = bondy_oplog_applier:unregister_table(ApplierPid, ?BUCKET_B),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"x">>, {set, 1, <<"a">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"x">>, {set, 1, <<"b">>}}
    ),
    _ = bondy_oplog:projection(Id),

    ?assertEqual(
        {<<"a">>, 1}, bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"x">>)
    ),
    ?assertEqual(
        undefined, bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"x">>)
    ),

    teardown_two_tables(Id, NsA, NsB, HA, HB).

%% A multiplexed instance rebuilds its FULL per-bucket directory from the durable
%% registry at init — the exact path a `one_for_all` subtree restart re-runs. We
%% register BOTH tables' entries (each stamped with the shared `instance_id` and
%% its `cell_apply_bucket`) and start ONE instance, but DO NOT call
%% `register_table/4` for table B. Table B's cells must still project, because
%% the applier's init reconstructs its ctx from table B's registry entry — proof
%% that a restart self-heals routing for non-founding tables.
siblings_self_heal_from_registry() ->
    Id = mk_id(),
    NsA = binary_to_atom(<<"sh_a_", Id/binary>>, utf8),
    NsB = binary_to_atom(<<"sh_b_", Id/binary>>, utf8),
    HA = register_shard(NsA, Id, ?BUCKET_A),
    HB = register_shard(NsB, Id, ?BUCKET_B),
    %% Founding table A seeds via `cell_apply_bucket`; table B is NOT registered
    %% at runtime — it is recovered from its registry entry by the init rebuild.
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {NsA, primary, 0},
            cell_apply_bucket => ?BUCKET_A
        }
    }),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"k">>, {set, 1, <<"va">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"k">>, {set, 1, <<"vb">>}}
    ),
    _ = bondy_oplog:projection(Id),
    ?assertEqual(
        {<<"va">>, 1}, bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"k">>)
    ),
    %% Table B projected with NO register_table call — recovered from the registry.
    ?assertEqual(
        {<<"vb">>, 1}, bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"k">>)
    ),
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NsA, primary, 0),
    ok = bondy_oplog_core_registry:unregister(NsB, primary, 0),
    teardown_handles(HA),
    teardown_handles(HB).

%% Reproduces the cold-boot ordering bug (#104). A collapsed per-shard instance
%% is founded by the FIRST table opened on the shard, but its single WAL holds
%% cells for EVERY table sharing the shard. If the founding applier replayed the
%% WAL at init — before the sibling tables registered their cell-apply buckets —
%% the siblings' cells would resolve to no ctx and be SKIPPED, and (because the
%% MST install is unconditional) the resume frontier would advance past them:
%% permanent loss of every non-founding table's WAL-tail on the durable backend.
%%
%% Here only table A is registered when the instance starts (so even the init
%% self-heal rebuild cannot recover B's ctx), and the instance is founded with
%% the drain GATED. A table B cell is written to the shared WAL; while gated it
%% is HELD, not skipped. After B registers and the gate is released, the deferred
%% drain replays the whole WAL with a complete routing directory and B's cell
%% projects. Without the gate this would assert `undefined` for table B.
gated_drain_defers_until_siblings_register() ->
    Id = mk_id(),
    NsA = binary_to_atom(<<"gate_a_", Id/binary>>, utf8),
    NsB = binary_to_atom(<<"gate_b_", Id/binary>>, utf8),
    %% Only table A is registered at founding time — exactly the cold-boot
    %% window where the sibling has not provisioned yet.
    HA = register_shard(NsA, Id, ?BUCKET_A),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {NsA, primary, 0},
            cell_apply_bucket => ?BUCKET_A,
            drain_gated => true
        }
    }),

    %% Write cells for BOTH the founding table and the not-yet-registered
    %% sibling B into the shared WAL.
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"k">>, {set, 1, <<"va">>}}
    ),
    _ = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"k">>, {set, 1, <<"vb">>}}
    ),

    %% Gate holds: nothing has been replayed into the projection yet. A direct
    %% projection read does NOT await the drain, so this observes the gate.
    ?assertEqual(
        undefined, bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"k">>)
    ),

    %% Sibling B provisions: durable registry entry + runtime bucket
    %% registration — the state the orchestrator reaches before releasing.
    HB = register_shard(NsB, Id, ?BUCKET_B),
    ApplierPid = bondy_oplog_registry:applier_pid(Id),
    ok = bondy_oplog_applier:register_table(
        ApplierPid, ?BUCKET_B, {NsB, primary, 0}, #{}
    ),

    %% Release the gate; the deferred drain replays the whole WAL now that the
    %% routing directory is complete.
    ok = bondy_oplog:open_drain_gate(Id),
    _ = bondy_oplog:projection(Id),

    %% Both cells projected — B's cell was held across the gate, not skipped.
    ?assertEqual(
        {<<"va">>, 1}, bondy_oplog_core:read(NsA, primary, ?BUCKET_A, <<"k">>)
    ),
    ?assertEqual(
        {<<"vb">>, 1}, bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"k">>)
    ),

    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NsA, primary, 0),
    ok = bondy_oplog_core_registry:unregister(NsB, primary, 0),
    teardown_handles(HA),
    teardown_handles(HB).

%% End-to-end catalogue-snapshot bootstrap across a collapsed per-shard instance:
%% the PRODUCTION side (`init/1`) must stream EVERY table on the shard in one
%% session — walking each table's bucket in turn — and the INSTALL side must
%% route each returned cell back to its OWN table's ctx by bucket, not funnel
%% them through the founding table's ctx. We populate two tables on a source
%% multiplexed instance, pull its whole-shard snapshot, and install it on a
%% fresh multiplexed target, asserting the batch genuinely spans both buckets
%% and each lands in its own projection. The per-table separate ETS projections
%% here are a STRICTER check than the shared Bookie of `shared_shards` (where a
%% shared handle would mask a misroute).
install_catalogue_batch_routes_by_bucket() ->
    {SrcId, SrcNsA, SrcNsB, SrcHA, SrcHB} = setup_two_tables(),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_A, <<"ka">>, {set, 5, <<"va">>}}
    ),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_A, <<"shared">>, {set, 9, <<"a_shared">>}}
    ),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_B, <<"kb">>, {set, 7, <<"vb">>}}
    ),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_B, <<"shared">>, {set, 9, <<"b_shared">>}}
    ),
    _ = bondy_oplog:projection(SrcId),

    %% The whole-shard snapshot (`init/1`) genuinely spans BOTH tables' buckets.
    Cells = pull_snapshot(SrcId),
    Buckets = lists:usort([B || {B, _K, _F} <- Cells]),
    ?assertEqual([?BUCKET_A, ?BUCKET_B], Buckets),
    ?assertEqual(4, length(Cells)),

    %% Install onto a fresh target multiplexed instance.
    {TgtId, TgtNsA, TgtNsB, TgtHA, TgtHB} = setup_two_tables(),
    TgtApplier = bondy_oplog_registry:applier_pid(TgtId),
    {ok, Counts} =
        bondy_oplog_applier:install_catalogue_batch(TgtApplier, Cells),
    ?assertEqual(length(Cells), maps:get(installed, Counts)),

    %% Each bucket's cells materialised in its OWN table's projection.
    ?assertEqual(
        {<<"va">>, 5},
        bondy_oplog_core:read(TgtNsA, primary, ?BUCKET_A, <<"ka">>)
    ),
    ?assertEqual(
        {<<"vb">>, 7},
        bondy_oplog_core:read(TgtNsB, primary, ?BUCKET_B, <<"kb">>)
    ),
    ?assertEqual(
        {<<"a_shared">>, 9},
        bondy_oplog_core:read(TgtNsA, primary, ?BUCKET_A, <<"shared">>)
    ),
    ?assertEqual(
        {<<"b_shared">>, 9},
        bondy_oplog_core:read(TgtNsB, primary, ?BUCKET_B, <<"shared">>)
    ),
    %% No misrouting: the B cell never leaked into table A's projection.
    ?assertEqual(
        undefined,
        bondy_oplog_core:read(TgtNsA, primary, ?BUCKET_B, <<"kb">>)
    ),
    ?assertEqual(
        undefined,
        bondy_oplog_core:read(TgtNsB, primary, ?BUCKET_A, <<"ka">>)
    ),

    teardown_two_tables(SrcId, SrcNsA, SrcNsB, SrcHA, SrcHB),
    teardown_two_tables(TgtId, TgtNsA, TgtNsB, TgtHA, TgtHB).

%% =============================================================================
%% PropEr — the adoption rule under batch boundaries the PEER chooses
%% =============================================================================

%% Where the projection stream is cut is not this replica's decision: the
%% peer's `catalogue_snapshot_batch_size`, the inter-node frame cap and the
%% chunking of an oversized cell all move the boundaries. The adoption verdict
%% must be a property of WHAT was shipped and not of how it was cut, so this
%% drives the real path end to end — snapshot, batching, install,
%% `merge_counts/2`, `adopt_frontier/3` — at batch sizes from one cell up, with
%% the unroutable cells at generated positions in the mint order.
%%
%% `partial_install_does_not_adopt_the_peer_frontier/0` above is one point of
%% this space and cannot see the fold at all: it ships two cells in a single
%% batch. Two mutants were run against this, and every eunit case above passed
%% under both:
%%
%%   - `merge_counts/2` as plain `maps:merge/2` (right-wins, so a later clean
%%     batch erases an earlier batch's `unclaimable`) — caught in 3 to 21
%%     trials, and only because `skew/0` also generates the FIRST bucket;
%%   - `adopt_frontier/3` raising under a different alarm id — caught in 1.
prop_adoption_survives_any_batching() ->
    ?FORALL(
        {BatchSize, Plan, Skew},
        {integer(1, 3), mint_plan(), skew()},
        adoption_holds(BatchSize, Plan, Skew)
    ).

%% The bucket this replica does not declare, or `none`. BOTH buckets are
%% generated and that is the point: the snapshot streams bucket-major, so
%% skewing only the LAST bucket would put every unroutable cell in the final
%% batch, where a fold that keeps just the last batch's answer still looks
%% right. Skewing the first bucket is what makes the fold observable.
skew() ->
    elements([none, ?BUCKET_A, ?BUCKET_B]).

%% A non-empty mint order over the two buckets. Bounded rather than `list/1`
%% so a trial stays two instances and a handful of cells: the cost here is the
%% fixture, not the search.
mint_plan() ->
    ?LET(N, integer(1, 4), vector(N, elements([?BUCKET_A, ?BUCKET_B]))).

%% @private
adoption_holds(BatchSize, Plan, Skew) ->
    Was = application:get_env(bondy_oplog, catalogue_snapshot_batch_size),
    ok = application:set_env(
        bondy_oplog, catalogue_snapshot_batch_size, BatchSize
    ),
    Peer = setup_two_tables(),
    Tgt = setup_two_tables(),
    try
        adoption_holds(Peer, Tgt, Plan, Skew)
    after
        ok = restore_env(catalogue_snapshot_batch_size, Was),
        teardown_two_tables(Peer),
        teardown_two_tables(Tgt)
    end.

%% @private
adoption_holds({PeerId, _, _, _, _}, {TgtId, _, _, _, _}, Plan, Skew) ->
    _ = [
        bondy_oplog:append(
            PeerId,
            {cell_apply, B, integer_to_binary(I), {set, I, <<"v">>}}
        )
     || {I, B} <- lists:enumerate(Plan)
    ],
    _ = bondy_oplog:projection(PeerId),
    PeerFrontier = bondy_oplog_instance:frontier(PeerId),

    ok =
        case Skew of
            none ->
                ok;
            Bucket ->
                bondy_oplog_applier:unregister_table(
                    bondy_oplog_registry:applier_pid(TgtId), Bucket
                )
        end,
    %% Return not asserted, for the reason
    %% `partial_install_does_not_adopt_the_peer_frontier/0` gives.
    _ = bondy_oplog_sync_session:bootstrap_catalogue(
        TgtId, PeerId, #{transport_opts => #{}}
    ),
    Frontier = bondy_oplog_instance:frontier(TgtId),
    Alarmed = alarm_raised({bondy_oplog_bucket_unroutable, TgtId}),

    case not lists:member(Skew, Plan) of
        true ->
            %% Every shipped cell routed, so the claim is the peer's exactly
            %% and there is nothing to alarm about.
            PeerFrontier =:= Frontier andalso not Alarmed;
        false ->
            %% A cell did not land. The claim must stay STRICTLY below the
            %% peer's for every origin — what the frontier does hold is earned
            %% by the fold, never adopted — and an operator must be told,
            %% because nothing else ends the re-bootstrap cycle this starts.
            Alarmed andalso strictly_below(Frontier, PeerFrontier)
    end.

%% @private
strictly_below(Frontier, PeerFrontier) ->
    maps:fold(
        fun(Origin, Seq, Acc) ->
            Acc andalso maps:get(Origin, Frontier, 0) < Seq
        end,
        %% A peer that minted nothing would make the fold vacuously true, and
        %% `mint_plan/0` is non-empty precisely so this cannot happen.
        map_size(PeerFrontier) > 0,
        PeerFrontier
    ).

%% @private
%% The OTP default handler stores whatever term was raised, so an alarm set
%% with options is a 3-tuple here and a bare one a 2-tuple. Only the id is
%% being asked about.
alarm_raised(Id) ->
    lists:any(
        fun(A) -> element(1, A) =:= Id end, alarm_handler:get_alarms()
    ).

%% @private
restore_env(Key, undefined) -> application:unset_env(bondy_oplog, Key);
restore_env(Key, {ok, V}) -> application:set_env(bondy_oplog, Key, V).

%% @private
%% EUnit is where this repo's properties run — `rebar3 proper` discovers
%% `prop_*`-NAMED modules only. It lives in this module rather than its own so
%% it reuses `setup_two_tables/0` instead of copying the fixture.
adoption_survives_any_batching() ->
    ?assert(
        proper:quickcheck(
            prop_adoption_survives_any_batching(),
            [{to_file, user}, {numtests, 25}]
        )
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Pull the complete whole-shard catalogue snapshot (every table on the shard)
%% off a collapsed instance.
pull_snapshot(Id) ->
    {ok, {_W, Cursor}} = bondy_oplog_catalogue_snapshot:init(Id),
    pull_snapshot_loop(Id, Cursor, []).

pull_snapshot_loop(Id, Cursor, Acc) ->
    case bondy_oplog_catalogue_snapshot:next(Id, Cursor) of
        {ok, {batch, {NextCursor, Cells}}} ->
            pull_snapshot_loop(Id, NextCursor, Acc ++ Cells);
        {ok, {done, Cells}} ->
            Acc ++ Cells
    end.

setup_two_tables() ->
    Id = mk_id(),
    NsA = binary_to_atom(<<"ns_a_", Id/binary>>, utf8),
    NsB = binary_to_atom(<<"ns_b_", Id/binary>>, utf8),
    %% Stamp the shared instance_id + each table's bucket on the entries, as
    %% real per-shard provisioning does — so the catalogue snapshot can derive
    %% the full set of tables on the shard from the registry alone.
    HA = register_shard(NsA, Id, ?BUCKET_A),
    HB = register_shard(NsB, Id, ?BUCKET_B),
    %% Founding table A seeds the cell-apply directory (dir-mode via
    %% `cell_apply_bucket`).
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {NsA, primary, 0},
            cell_apply_bucket => ?BUCKET_A
        }
    }),
    %% Table B joins the SAME instance at runtime.
    ApplierPid = bondy_oplog_registry:applier_pid(Id),
    ok = bondy_oplog_applier:register_table(
        ApplierPid, ?BUCKET_B, {NsB, primary, 0}, #{}
    ),
    {Id, NsA, NsB, HA, HB}.

%% END TO END. The peer's applied frontier says "every event of this origin up
%% to N is materialised here". Adopting it over an install that could not route
%% some of the peer's cells asserts exactly what this replica does NOT hold —
%% and the install cannot say which origin lost history, because a cell is
%% `{Bucket, Key, Frame}` with no origin and no seq. So adoption is
%% all-or-nothing.
%%
%% The bootstrap must still COMPLETE: the usual cause is a peer running a build
%% that declares a table this one does not, which never resolves on its own, so
%% refusing would strand the replica forever without the data it CAN route
%% (`proofs/tla/MuxBucketSkip.tla`, `Live` under `VersionSkew`).
%%
%% Mutation-checked: pass `PeerFrontier` unconditionally in
%% `bondy_oplog_sync_session:do_bootstrap_snapshot/6` and the withheld-frontier
%% assertion fails with the peer's vector.
partial_install_does_not_adopt_the_peer_frontier() ->
    {PeerId, PeerNsA, PeerNsB, PeerHA, PeerHB} = setup_two_tables(),
    _ = bondy_oplog:append(
        PeerId, {cell_apply, ?BUCKET_A, <<"ka">>, {set, 5, <<"va">>}}
    ),
    _ = bondy_oplog:append(
        PeerId, {cell_apply, ?BUCKET_B, <<"kb">>, {set, 7, <<"vb">>}}
    ),
    _ = bondy_oplog:projection(PeerId),
    PeerFrontier = bondy_oplog_instance:frontier(PeerId),
    %% Guard the guard: a peer with an empty frontier would make the
    %% withheld-frontier assertion below pass for the wrong reason.
    ?assertNotEqual(#{}, PeerFrontier),

    %% CONTROL: a local that routes BOTH buckets installs everything, so the
    %% peer's frontier is adopted.
    {OkId, OkNsA, OkNsB, OkHA, OkHB} = setup_two_tables(),
    ?assertMatch(
        {ok, _},
        bondy_oplog_sync_session:bootstrap_catalogue(
            OkId, PeerId, #{transport_opts => #{}}
        )
    ),
    ?assertEqual(PeerFrontier, bondy_oplog_instance:frontier(OkId)),

    %% SKEW: this local cannot route table B, so the peer's B cell never lands.
    {TgtId, TgtNsA, TgtNsB, TgtHA, TgtHB} = setup_two_tables(),
    ok = bondy_oplog_applier:unregister_table(
        bondy_oplog_registry:applier_pid(TgtId), ?BUCKET_B
    ),
    ?assertEqual(#{}, bondy_oplog_instance:frontier(TgtId)),
    %% The session's RETURN is deliberately not asserted here. Withholding the
    %% claim leaves this replica behind the peer's frontier, so the
    %% post-bootstrap round's `maybe_frontier_gap/5` reports
    %% `{error, {frontier_gap, _}}`. That is correct rather than a defect to
    %% fix: the verdict schedules a re-bootstrap, and the catalogue install is
    %% the only writer of applied state that does not pass through the fold —
    %% so it is how the events the contiguity hold parks are eventually
    %% delivered. Suppressing the verdict to stop the cycle violates `Live`
    %% (`MuxBucketSkip_Minus_GapVerdict`). What ends the cycle is an operator,
    %% which is what `adopt_frontier/3` raises its alarm for.
    _ = bondy_oplog_sync_session:bootstrap_catalogue(
        TgtId, PeerId, #{transport_opts => #{}}
    ),
    %% The peer's vector is NOT adopted. What the frontier does hold is
    %% EARNED, not claimed: the post-bootstrap round folds the routable
    %% bucket-A event through `merge_applied/2`, so the contiguous prefix
    %% stops at it and never reaches the unroutable bucket-B seq above.
    Withheld = bondy_oplog_instance:frontier(TgtId),
    ?assertNotEqual(PeerFrontier, Withheld),
    [{Origin, PeerSeq}] = maps:to_list(PeerFrontier),
    ?assert(maps:get(Origin, Withheld, 0) < PeerSeq),
    %% ...and the bootstrap still completed: what COULD be routed is here.
    ?assertEqual(
        {<<"va">>, 5},
        bondy_oplog_core:read(TgtNsA, primary, ?BUCKET_A, <<"ka">>)
    ),

    teardown_two_tables(PeerId, PeerNsA, PeerNsB, PeerHA, PeerHB),
    teardown_two_tables(OkId, OkNsA, OkNsB, OkHA, OkHB),
    teardown_two_tables(TgtId, TgtNsA, TgtNsB, TgtHA, TgtHB).

%% A snapshot from a peer running a build that declares a table this one does
%% not: its cells carry a bucket that resolves to no ctx here, so they are
%% skipped and the projection ends up short of what the peer shipped. The
%% install must NAME that bucket, because `skipped` alone cannot be told apart
%% from the benign HLC-older skip, and
%% `bondy_oplog_sync_session:do_bootstrap_snapshot/6` decides whether to adopt
%% the peer's applied frontier on exactly this distinction. Mutation-checked:
%% drop the `unclaimable(Bucket, Acc)` wrapper in
%% `bondy_oplog_applier:do_install_catalogue_batch/3` and the third assertion
%% fails with `[]`.
install_names_the_buckets_it_could_not_route() ->
    {SrcId, SrcNsA, SrcNsB, SrcHA, SrcHB} = setup_two_tables(),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_A, <<"ka">>, {set, 5, <<"va">>}}
    ),
    _ = bondy_oplog:append(
        SrcId, {cell_apply, ?BUCKET_B, <<"kb">>, {set, 7, <<"vb">>}}
    ),
    _ = bondy_oplog:projection(SrcId),
    Cells = pull_snapshot(SrcId),

    {TgtId, TgtNsA, TgtNsB, TgtHA, TgtHB} = setup_two_tables(),
    TgtApplier = bondy_oplog_registry:applier_pid(TgtId),

    %% CONTROL: every bucket resolves here, so nothing is unclaimable and the
    %% caller may adopt the peer's frontier.
    {ok, Ok} = bondy_oplog_applier:install_catalogue_batch(TgtApplier, Cells),
    ?assertEqual(2, maps:get(installed, Ok)),
    ?assertEqual([], maps:get(unclaimable, Ok)),

    %% SKEW: re-tag table B's cells with a bucket no table on this instance
    %% declares. The A cell still lands; the C cells cannot.
    Skewed = [
        case B of
            ?BUCKET_B -> {<<"table_c">>, K, F};
            _ -> {B, K, F}
        end
     || {B, K, F} <- Cells
    ],
    {ok, Counts} = bondy_oplog_applier:install_catalogue_batch(
        TgtApplier, Skewed
    ),
    ?assertEqual([<<"table_c">>], maps:get(unclaimable, Counts)),
    %% The unroutable cells are counted as skipped too, but that counter also
    %% carries this batch's HLC-older re-install of the A cell, so it cannot
    %% stand in for the set above.
    ?assertEqual(2, maps:get(skipped, Counts)),
    ?assertEqual(0, maps:get(installed, Counts)),

    teardown_two_tables(SrcId, SrcNsA, SrcNsB, SrcHA, SrcHB),
    teardown_two_tables(TgtId, TgtNsA, TgtNsB, TgtHA, TgtHB).

%% Register a primary shard entry, stamping the shared `instance_id` and the
%% table's `cell_apply_bucket`, so the applier's init rebuild
%% (`primary_entries_for_instance/1`) can recover this table's ctx — and the
%% catalogue snapshot can derive the shard's table set — from the registry alone.
register_shard(NS, Id, Bucket) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    Config0 = #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => lww_register,
        overlay => disabled
    },
    Config =
        case Id of
            undefined ->
                Config0;
            _ ->
                Config0#{instance_id => Id, cell_apply_bucket => Bucket}
        end,
    ok = bondy_oplog_core_registry:register(NS, primary, 0, Config),
    {Cache, Proj}.

teardown_handles({Cache, Proj}) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache).

teardown_two_tables({Id, NsA, NsB, HA, HB}) ->
    teardown_two_tables(Id, NsA, NsB, HA, HB).

teardown_two_tables(Id, NsA, NsB, {CA, PA}, {CB, PB}) ->
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NsA, primary, 0),
    ok = bondy_oplog_core_registry:unregister(NsB, primary, 0),
    ok = bondy_oplog_projection_ets:close(PA),
    ok = bondy_oplog_cache_ets:close(CA),
    ok = bondy_oplog_projection_ets:close(PB),
    ok = bondy_oplog_cache_ets:close(CB),
    ok.

mk_id() ->
    list_to_binary(
        "mux_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).
