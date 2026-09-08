%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% The gap between an event being RECEIVED (present in the oplog/MST) and
%% MATERIALISED (folded into the projection), and the applied frontier's
%% claim about it.
%%
%% The frontier is a `#{Origin => Seq}` map whose per-origin maximum asserts
%% an applied PREFIX. Four readers respond to an over-claim by discarding or
%% refusing data — `bondy_oplog_instance:watermark_door/3`,
%% `capped_truncation_point/2`, `append_remote_below_watermark/3` and
%% `bondy_oplog_sync_session:frontier_deficit/2` — so an over-claim is user
%% loss, and it is invisible to the convergence oracle
%% (`bondy_prometheus_db.erl`'s `Instances DIVERGED`) because both replicas
%% report the same over-claimed vector.
%%
%% This module pins the smallest configuration that produces the gap: ONE
%% multiplexed instance, two buckets, one of them with no registered table.
%% The unroutable bucket's cell is skipped by
%% `bondy_oplog_cell_apply:apply_cell_batch_mux/3` (which logs and returns
%% `ok`), while a LATER seq on the routable bucket folds — so the folded set
%% is `{2}`, which is not prefix-closed, and the only sound claim is 0.
%%
%% `across_a_restart/0` is the case a per-batch cap in the apply path does NOT
%% cover: capping the live claim achieves nothing if a boot fold re-derives it
%% from RECEIPT at `init/1`. A test that stops before the restart certifies a
%% fix that does not work.
%%
%% Both cases are RED at the commit that introduced this module. See
%% `_design/applied_frontier.md` (invariant I6) and
%% `proofs/isabelle/Frontier_Writers.thy`
%% (`receipt_log_overclaims`, `shipped_restart_overclaims`).
%% =============================================================================
-module(bondy_oplog_frontier_fold_gap_test).

-include_lib("eunit/include/eunit.hrl").

%% The routable bucket: a table is registered for it.
-define(BUCKET_A, <<"table_a">>).
%% The unroutable bucket: NO table is ever registered for it, so
%% `bondy_oplog_mux:resolve/2` returns `undefined` for every one of its
%% cells and the fold is skipped.
-define(BUCKET_B, <<"table_b">>).

frontier_fold_gap_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        [
            {timeout, 60, fun() -> live_path(Dir) end},
            {timeout, 60, fun() -> across_a_restart(Dir) end},
            {timeout, 60, fun() -> split_batch(Dir) end},
            {timeout, 60, fun() ->
                unroutable_bucket_keeps_the_replay_cursor(Dir)
            end}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% No AAE and no GC: this is a single-instance property about the local
    %% apply path, and a background round would add a second frontier writer.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = filename:join(
        "/tmp/" ++ os:getpid(),
        "foldgap_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

cleanup(Dir) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    _ =
        try
            del_tree(Dir)
        catch
            _:_ -> ok
        end,
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% Seq 1 goes to the unroutable bucket and never reaches a projection; seq 2
%% goes to the routable one and does. The frontier must not claim 2, because
%% claiming 2 asserts the prefix `{1, 2}` and seq 1 was never applied.
live_path(Dir) ->
    {Id, NS, Origin, H} = open(Dir, mk_id()),
    try
        {S1, S2} = append_the_gap(Id),
        ?assertEqual(1, S1),
        ?assertEqual(2, S2),

        %% The premise: seq 2 DID fold, so the assertion below is a real cap
        %% and not just "nothing happened".
        ?assertEqual(
            {<<"va">>, 2},
            bondy_oplog_core:read(NS, primary, ?BUCKET_A, <<"ka">>)
        ),
        %% ... and seq 1 did not.
        ?assertEqual(
            undefined,
            bondy_oplog_core:read(NS, primary, ?BUCKET_B, <<"kb">>)
        ),

        %% The oplog holds BOTH: tree membership means received, not applied.
        %% `bondy_oplog_instance:install_event/5` is the shared insert path
        %% for the local and the peer-received case alike.
        ?assertEqual(2, bondy_oplog:size(Id)),

        ?assertEqual(0, claimed(Id, Origin))
    after
        close(Id, NS, H)
    end.

%% As `live_path/1`, then a real stop/start of a DURABLE instance on the same
%% directory, with the reopened instance fully drained and re-folded.
%%
%% What it discriminates: a boot fold that re-derives the claim from the MST at
%% `init/1` erases any cap the apply path applied, which is why a per-batch cap
%% alone is not a fix. It is NOT the
%% falsifier for the boot re-fold that replaced it: with the live claim already
%% capped, the checkpoint carries 0 and this stays green even if the re-fold
%% does nothing. The re-fold's own falsifier is
%% `bondy_oplog_frontier_recovery_test:crash_restart_reconstructs_frontier/0`,
%% where the checkpoint is deleted and only a re-fold can rebuild the frontier.
across_a_restart(Dir) ->
    {Id, NS, Origin, H} = open(Dir, mk_id()),
    try
        {_, 2} = append_the_gap(Id),
        ok = bondy_oplog:stop_instance(Id),
        {ok, _} = start(Id, NS, Dir, Origin),
        %% Release the reopened instance's drain gate and settle both applier
        %% stages, so the assertion below is made against a replica that has
        %% finished booting — not one that never ran.
        ok = bondy_oplog:open_drain_gate(Id),
        _ = bondy_oplog_instance:await_apply(Id),
        ok = bondy_oplog_applier:replay_cell_events_sync(
            bondy_oplog_registry:applier_pid(Id)
        ),

        %% Unchanged premise after the restart: the oplog still holds both
        %% events, and bucket B still has no table.
        ?assertEqual(2, bondy_oplog:size(Id)),
        ?assertEqual(
            undefined,
            bondy_oplog_core:read(NS, primary, ?BUCKET_B, <<"kb">>)
        ),

        ?assertEqual(0, claimed(Id, Origin))
    after
        close(Id, NS, H)
    end.

%% As `live_path/1`, but the two appends reach the applier in SEPARATE batches
%% and there is no restart, so nothing repairs the claim afterwards.
%%
%% The falsifier for increment 9 of `_design/applied_frontier_pending.md`. A
%% rule that caps below the lowest seq THIS batch failed to materialise lets
%% batch one fail seq 1 and materialise nothing, batch two materialise seq 2
%% and observe no failure at all, and the claim reach 2 over a projection
%% holding only seq 2.
%%
%% The point is not that the cap is mis-computed. It is that a single integer
%% per origin cannot carry "seq 2 folded" across the batch boundary while seq 1
%% is missing: PROVED impossible in
%% `proofs/isabelle/Frontier_Pending.thy` (`no_scalar_writer_sound_and_complete`),
%% checked under concurrency and restarts in `proofs/tla/FrontierPending.tla`
%% (`FrontierPending_MaxCap.cfg`, `NoOverClaim` violated). Note that BOTH
%% batches here are individually blameless — batch two never saw a failure.
%%
%% `live_path/1` gates the drain so both appends share one batch, which is the
%% regime where the shipped rule IS sound
%% (`shipped_sound_when_visible`); this case is the complement.
split_batch(Dir) ->
    {Id, NS, Origin, H} = open(Dir, mk_id()),
    try
        %% BATCH ONE: the unroutable bucket alone. Nothing materialises, so
        %% this batch makes no claim at all.
        K1 = bondy_oplog:append(
            Id, {cell_apply, ?BUCKET_B, <<"kb">>, {set, 1, <<"vb">>}}
        ),
        ok = bondy_oplog:open_drain_gate(Id),
        _ = bondy_oplog_instance:await_apply(Id),
        _ = bondy_oplog:projection(Id),
        ?assertEqual(1, bondy_oplog_event:key_seq(K1)),
        %% The failure is now in the PAST, and out of reach of every later
        %% batch's cap.
        ?assertEqual(0, claimed(Id, Origin)),

        %% BATCH TWO: the routable bucket. It materialises seq 2 and sees no
        %% failure of its own.
        K2 = bondy_oplog:append(
            Id, {cell_apply, ?BUCKET_A, <<"ka">>, {set, 2, <<"va">>}}
        ),
        _ = bondy_oplog_instance:await_apply(Id),
        _ = bondy_oplog:projection(Id),
        ?assertEqual(2, bondy_oplog_event:key_seq(K2)),

        %% Premise, as in `live_path/1`: seq 2 folded and seq 1 did not, so
        %% the assertion below is a real cap rather than an empty batch.
        ?assertEqual(
            {<<"va">>, 2},
            bondy_oplog_core:read(NS, primary, ?BUCKET_A, <<"ka">>)
        ),
        ?assertEqual(
            undefined,
            bondy_oplog_core:read(NS, primary, ?BUCKET_B, <<"kb">>)
        ),
        ?assertEqual(2, bondy_oplog:size(Id)),

        %% The only sound claim is 0: claiming 2 asserts the prefix `{1, 2}`
        %% and seq 1 was never folded. Claiming 2 also DISARMS the repair —
        %% `bondy_oplog_instance:watermark_door/3` and
        %% `capped_truncation_point/2` judge "never applied" against this same
        %% frontier, so they would release seq 1 for truncation.
        ?assertEqual(0, claimed(Id, Origin))
    after
        close(Id, NS, H)
    end.

%% Bucket resolution is part of the hold decision. A peer's seq riding a
%% bucket this shard has no table for is HELD, so the replay keeps its
%% cursor and the cell re-presents when the sibling table registers. Take
%% that away and the cursor advances past a discarded cell: this case ends
%% at claim 0, the cell absent from every projection for good while the MST
%% still holds it (measured — reverting `unroutable/2` turns it red there).
%%
%% The origin is REMOTE deliberately. A replica's own events are never held
%% (they arrive in seq order down the local WAL, whose boot race the drain
%% gate covers), so a local-origin version of this case would assert nothing.
unroutable_bucket_keeps_the_replay_cursor(Dir) ->
    {Id, NS, _Origin, H} = open(Dir, mk_id()),
    Peer = <<"peer-origin-cursor">>,
    try
        ok = bondy_oplog:open_drain_gate(Id),
        ok = append_peer(Id, Peer, 1, ?BUCKET_B, <<"kb">>, <<"vb">>),
        ok = append_peer(Id, Peer, 2, ?BUCKET_A, <<"ka">>, <<"va">>),
        _ = bondy_oplog_instance:await_apply(Id),
        Applier = bondy_oplog_registry:applier_pid(Id),
        ok = bondy_oplog_applier:replay_cell_events_sync(Applier),

        %% The premise: the tree holds both events, only the routable one
        %% reached a projection. Without this the assertion below is vacuous.
        ?assertEqual(2, bondy_oplog:size(Id)),
        ?assertEqual(
            undefined,
            bondy_oplog_core:read(NS, primary, ?BUCKET_B, <<"kb">>)
        ),

        %% THE ASSERTION. Registering the sibling table is the only repair a
        %% held cell needs: the next replay re-presents it, it folds, and the
        %% claim rises unaided — `contig_mono` in
        %% `proofs/isabelle/Bucket_Skip_Soundness.thy`. It can only re-present
        %% if the replay that skipped it kept its cursor, so this fails
        %% whenever an unroutable bucket is not treated as a hold.
        %%
        %% Note it is the FIRST replay that must hold: seq 1 arrives alone and
        %% unroutable, and a contiguity-only rule sees a complete run [1] and
        %% advances. The later hold on seq 2 (genuinely non-contiguous) keeps
        %% the cursor from that point on, which is why every observation made
        %% after seq 2 arrives looks healthy while seq 1 is already lost.
        NsB = binary_to_atom(<<"nsb_", Id/binary>>, utf8),
        HB = register_shard_at(NsB, Id, ?BUCKET_B, 0),
        try
            ok = bondy_oplog_applier:register_table(
                Applier, ?BUCKET_B, {NsB, primary, 0}, #{}
            ),
            ok = bondy_oplog_applier:replay_cell_events_sync(Applier),
            ?assertEqual(2, claimed(Id, Peer)),
            ?assertEqual(
                {<<"vb">>, 1},
                bondy_oplog_core:read(NsB, primary, ?BUCKET_B, <<"kb">>)
            )
        after
            close_extra(NsB, HB)
        end
    after
        close(Id, NS, H)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

%% A peer-authored cell at an explicit seq — the shape anti-entropy delivers.
append_peer(Id, Origin, Seq, Bucket, Key, Value) ->
    Hlc = bondy_oplog_hlc:encode(
        erlang:system_time(millisecond) + 1000 + Seq, 0
    ),
    Event = bondy_oplog_event:new(
        bondy_oplog_event:key(Hlc, Origin, Seq),
        {cell_apply, Bucket, Key, {set, Seq, Value}},
        undefined
    ),
    bondy_oplog:append_remote(Id, Event).

%% Appends seq 1 to the unroutable bucket and seq 2 to the routable one, and
%% waits for the applier to have processed both. Returns the two seqs so the
%% caller can assert the ORDER it depends on: the skipped seq must be the
%% LOWER one, or there is no prefix to violate.
%%
%% Both appends land while the drain is GATED, so the applier sees them in ONE
%% batch. That is deliberate and it is what makes `live_path/1` deterministic:
%% a rule that caps below the lowest seq THIS batch failed to materialise
%% cannot see a failure in an earlier batch. Ungated, the two appends split
%% across
%% batches under load and the live claim reaches 2, which is why an ungated
%% version of this case passed alone and failed when another module shared the
%% VM. `across_a_restart/1` is the case that covers the split-batch shape: the
%% boot re-fold repairs the claim however the batches fell.
append_the_gap(Id) ->
    K1 = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_B, <<"kb">>, {set, 1, <<"vb">>}}
    ),
    K2 = bondy_oplog:append(
        Id, {cell_apply, ?BUCKET_A, <<"ka">>, {set, 2, <<"va">>}}
    ),
    ok = bondy_oplog:open_drain_gate(Id),
    _ = bondy_oplog_instance:await_apply(Id),
    _ = bondy_oplog:projection(Id),
    {bondy_oplog_event:key_seq(K1), bondy_oplog_event:key_seq(K2)}.

%% What the frontier asserts this replica has APPLIED for `Origin`. Absent
%% entry reads as 0 — nothing applied.
claimed(Id, Origin) ->
    maps:get(Origin, bondy_oplog_registry:frontier(Id), 0).

open(Dir, Id) ->
    NS = binary_to_atom(<<"ns_", Id/binary>>, utf8),
    Origin = bondy_oplog_origin:new(),
    H = register_shard(NS, Id, ?BUCKET_A),
    {ok, _} = start(Id, NS, Dir, Origin),
    {Id, NS, Origin, H}.

%% A durable (pack-store) instance in cell-apply DIRECTORY mode: the founding
%% table stamps `cell_apply_bucket`, which is what makes the applier route by
%% bucket instead of sending every cell to one target. Bucket B resolves to
%% no context precisely because no table ever claims it.
start(Id, NS, Dir, Origin) ->
    bondy_oplog:start_instance(Id, #{
        origin => Origin,
        fold_module => lww_register,
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        %% A `storage_path` instance starts in `pre_bootstrap`; `seed` makes
        %% this genesis instance `live` so its applier drains.
        seed => true,
        applier => #{
            cell_apply_target => {NS, primary, 0},
            cell_apply_bucket => ?BUCKET_A,
            %% Hold the drain so `append_the_gap/1`'s two appends reach the
            %% applier as ONE batch; `open_drain_gate/1` releases it.
            drain_gated => true
        }
    }).

%% Stamped with `instance_id` + `cell_apply_bucket` so the applier's init
%% rebuild (`primary_entries_for_instance/1`) recovers this table's context
%% from the registry alone — which is what makes the restart case reopen with
%% bucket A routable and bucket B not.
register_shard(NS, Id, Bucket) ->
    register_shard_at(NS, Id, Bucket, 0).

%% As `register_shard/3`, at an explicit shard index, so a SECOND bucket can
%% join an instance that is already serving — which is how a routing directory
%% heals in production.
register_shard_at(NS, Id, Bucket, Shard) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, Shard, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, Shard, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, Shard, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => lww_register,
        overlay => disabled,
        instance_id => Id,
        cell_apply_bucket => Bucket
    }),
    {Shard, Cache, Proj}.

close_extra(NS, {Shard, Cache, Proj}) ->
    ok = bondy_oplog_core_registry:unregister(NS, primary, Shard),
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

close(Id, NS, {Shard, Cache, Proj}) ->
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NS, primary, Shard),
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

mk_id() ->
    list_to_binary(
        "foldgap_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

del_tree(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Names} = file:list_dir(Dir),
            lists:foreach(
                fun(N) -> del_tree(filename:join(Dir, N)) end, Names
            ),
            file:del_dir(Dir);
        false ->
            file:delete(Dir)
    end.
