%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% `bondy_oplog_registry:merge_applied/2` — the applied frontier's incremental
%% writer: a PREFIX bound plus the folded seqs above it.
%%
%% `contiguity_alone_would_stall/0` is the discriminating case. A plain
%% contiguous bound is equally sound, so only COMPLETENESS separates the two,
%% and no one-integer-per-origin rule can achieve it
%% (`proofs/isabelle/Frontier_Pending.thy`, `no_scalar_writer_sound_and_complete`).
%%
%% These drive the registry directly: the schedules that discriminate the rules
%% are schedules of BATCHES, and a batch boundary is set by drain timing a test
%% cannot address. The end-to-end case is
%% `bondy_oplog_frontier_fold_gap_test:split_batch/1`.
%% =============================================================================
-module(bondy_oplog_frontier_pending_test).

-include_lib("eunit/include/eunit.hrl").

frontier_pending_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun contiguous_run_absorbs_immediately/0},
        {timeout, 30, fun a_hole_holds_the_prefix_but_keeps_the_seq/0},
        {timeout, 30, fun contiguity_alone_would_stall/0},
        {timeout, 30, fun out_of_order_arrival_converges/0},
        {timeout, 30, fun absorbing_is_idempotent/0},
        {timeout, 30, fun a_reap_clears_both_components/0},
        {timeout, 30, fun origins_are_independent/0},
        {timeout, 30, fun merge_frontier_absorbs_covered_pending/0}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% The healthy case: a contiguous run costs nothing. `pending` stays empty, so
%% the entry is exactly the integer it was before this design
%% (`pending_zero_cost_when_healthy`).
contiguous_run_absorbs_immediately() ->
    {Id, O} = fresh(),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [1, 2, 3]}),
    ?assertEqual(3, prefix(Id, O)),
    ?assertEqual(#{}, bondy_oplog_registry:pending(Id)),
    %% and across batches, still nothing pending
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [4]}),
    ?assertEqual(4, prefix(Id, O)),
    ?assertEqual(#{}, bondy_oplog_registry:pending(Id)).

%% A seq folded above a hole must NOT raise the prefix — the prefix asserts an
%% applied prefix and seq 1 was never folded — but it must not be forgotten
%% either. This is the state a single integer cannot represent.
a_hole_holds_the_prefix_but_keeps_the_seq() ->
    {Id, O} = fresh(),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [2]}),
    ?assertEqual(0, prefix(Id, O)),
    ?assertEqual([2], pending(Id, O)).

%% THE DISCRIMINATING CASE, and the reason the pending half exists.
%%
%% Seq 2 folds while seq 1 is missing; seq 1 arrives in a LATER batch. Both
%% rules agree the prefix is 0 after the first batch. They disagree after the
%% second: a rule holding one integer has forgotten seq 2 and can only reach 1,
%% leaving seq 2 unclaimable without an O(live MST) re-fold. Reaching 2 is only
%% possible because the first batch's knowledge was kept.
%%
%% `proofs/tla/FrontierPending_Contig_Dead.cfg` violates `Complete` on exactly
%% this shape; `FrontierPending_Pending.cfg` is clean.
contiguity_alone_would_stall() ->
    {Id, O} = fresh(),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [2]}),
    ?assertEqual(0, prefix(Id, O)),

    ok = bondy_oplog_registry:merge_applied(Id, #{O => [1]}),
    %% 1, not 2, is the answer a forgetful rule gives.
    ?assertEqual(2, prefix(Id, O)),
    ?assertEqual(#{}, bondy_oplog_registry:pending(Id)).

%% The general form: seqs arriving in an arbitrary order converge on the exact
%% prefix, and nothing is left pending once delivery is complete
%% (`pending_complete`). Anti-entropy delivers no per-origin order guarantee,
%% so this is the shape the AAE path actually produces.
out_of_order_arrival_converges() ->
    {Id, O} = fresh(),
    lists:foreach(
        fun(Seq) ->
            ok = bondy_oplog_registry:merge_applied(Id, #{O => [Seq]})
        end,
        [5, 3, 9, 1, 4, 8, 6, 2, 7]
    ),
    ?assertEqual(9, prefix(Id, O)),
    ?assertEqual(#{}, bondy_oplog_registry:pending(Id)),

    %% ... and a hole left open holds the prefix exactly at its edge while
    %% keeping everything above it.
    {Id2, O2} = fresh(),
    lists:foreach(
        fun(Seq) ->
            ok = bondy_oplog_registry:merge_applied(Id2, #{O2 => [Seq]})
        end,
        [1, 2, 4, 5, 6, 9]
    ),
    ?assertEqual(2, prefix(Id2, O2)),
    %% One interval per hole, not one entry per seq above it
    %% (`pending_intervals_bounded_by_holes`): two holes here (3 and 7-8),
    %% and the pending set is two elements however many seqs sit above them.
    ?assertEqual([{4, 6}, 9], pending(Id2, O2)),
    ?assertEqual(2, bondy_interval_set:size(pending(Id2, O2))).

%% Re-presenting an already-folded seq must not move anything. The projection
%% fold is idempotent and the boot re-fold re-presents the whole live oplog, so
%% this is the common case at boot, not an edge case.
absorbing_is_idempotent() ->
    {Id, O} = fresh(),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [1, 2, 4]}),
    Before = {prefix(Id, O), pending(Id, O)},
    ?assertEqual({2, [4]}, Before),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [1, 2, 4]}),
    ?assertEqual(Before, {prefix(Id, O), pending(Id, O)}),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [2]}),
    ?assertEqual(Before, {prefix(Id, O), pending(Id, O)}).

%% A reap must clear BOTH components. An origin left in `pending` would
%% re-enter the frontier the moment a later batch absorbed it, undoing the
%% reap — and `pending` is the half no checkpoint would ever correct.
a_reap_clears_both_components() ->
    {Id, O} = fresh(),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [1, 2, 5]}),
    ?assertEqual(2, prefix(Id, O)),
    ?assertEqual([5], pending(Id, O)),

    ?assertEqual([O], bondy_oplog_registry:reap_frontier(Id, [O])),
    ?assertEqual(0, prefix(Id, O)),
    ?assertEqual(#{}, bondy_oplog_registry:pending(Id)),

    %% An origin present ONLY in pending is still cleared, and reports as no
    %% frontier entry removed.
    {Id2, O2} = fresh(),
    ok = bondy_oplog_registry:merge_applied(Id2, #{O2 => [7]}),
    ?assertEqual(0, prefix(Id2, O2)),
    ?assertEqual([7], pending(Id2, O2)),
    ?assertEqual([], bondy_oplog_registry:reap_frontier(Id2, [O2])),
    ?assertEqual(#{}, bondy_oplog_registry:pending(Id2)).

%% The frontier is a map and every operation on it is pointwise. The Isabelle
%% development reduces to ONE origin on exactly this assumption, so it is
%% checked rather than assumed (`FrontierPending_Pending_TwoOrigins.cfg`).
origins_are_independent() ->
    {Id, A} = fresh(),
    B = bondy_oplog_origin:new(),
    ok = bondy_oplog_registry:merge_applied(Id, #{A => [2], B => [1, 2, 3]}),
    %% A's hole does not hold B back, and B's progress does not fill A's hole.
    ?assertEqual(0, prefix(Id, A)),
    ?assertEqual(3, prefix(Id, B)),
    ?assertEqual([2], pending(Id, A)),
    ?assertEqual([], pending(Id, B)),

    ok = bondy_oplog_registry:merge_applied(Id, #{A => [1]}),
    ?assertEqual(2, prefix(Id, A)),
    ?assertEqual(3, prefix(Id, B)).

%% `merge_frontier/2` still exists for the checkpoint restore and the catalogue
%% bootstrap, which supply a prefix directly. A prefix that lands above pending
%% seqs must absorb them rather than leave both components describing the same
%% seq.
merge_frontier_absorbs_covered_pending() ->
    {Id, O} = fresh(),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [3, 4]}),
    ?assertEqual(0, prefix(Id, O)),
    ?assertEqual([{3, 4}], pending(Id, O)),

    %% A checkpoint says the prefix is 2; 3 and 4 continue it, so the entry
    %% must land on 4 with nothing left over.
    ok = bondy_oplog_registry:merge_frontier(Id, #{O => 2}),
    ?assertEqual(4, prefix(Id, O)),
    ?assertEqual(#{}, bondy_oplog_registry:pending(Id)).

%% =============================================================================
%% Helpers
%% =============================================================================

fresh() ->
    Id = list_to_binary(
        "pending_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    {ok, _} = bondy_oplog:start_instance(Id),
    {Id, bondy_oplog_origin:new()}.

prefix(Id, Origin) ->
    maps:get(Origin, bondy_oplog_registry:frontier(Id), 0).

pending(Id, Origin) ->
    maps:get(Origin, bondy_oplog_registry:pending(Id), []).
