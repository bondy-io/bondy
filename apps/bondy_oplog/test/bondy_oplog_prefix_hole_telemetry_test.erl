%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% `bondy_oplog_cell_apply:detect_prefix_holes/2` — the contiguity detector
%% behind `bondy_oplog_prefix_holes_total`. Presence is `{1..prefix} ∪ pending`.
%%
%% `pending_seqs_are_not_missing/0` is the falsifier and `a_real_gap_still_fires/0`
%% its guard: consulting pending must make the detector exact, not blind. The
%% same claim is quantified in `prop_bondy_oplog_frontier_holes`.
%% =============================================================================
-module(bondy_oplog_prefix_hole_telemetry_test).

-include_lib("eunit/include/eunit.hrl").

-define(EVENT, [bondy_oplog, applier, prefix_hole]).

prefix_hole_telemetry_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun pending_seqs_are_not_missing/0},
        {timeout, 30, fun a_real_gap_still_fires/0},
        {timeout, 30, fun a_contiguous_batch_is_silent/0},
        {timeout, 30, fun a_gap_with_no_pending_is_unchanged/0}
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
%% The detector
%% =============================================================================

%% THE FALSIFIER. Prefix 3 with seq 5 folded and held above the hole at 4. A
%% batch carrying 4 and 6 leaves NOTHING absent: 4 closes the hole, 5 is
%% already folded, 6 is in the batch. The prefix-only test cannot see 5 and
%% reports `[{5, 5}]`.
pending_seqs_are_not_missing() ->
    {Id, O} = fresh(),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [1, 2, 3, 5]}),
    ?assertEqual(3, prefix(Id, O)),
    ?assertEqual([5], pending(Id, O)),
    ?assertEqual([], capture(fun() -> detect(Id, #{O => [4, 6]}) end)).

%% And it is not blind: with 4 still absent the detector fires, reporting the
%% ONE seq that is actually missing. The prefix-only test reports two —
%% `[{4, 5}]`, `missing => 2` — because it counts the folded 5.
a_real_gap_still_fires() ->
    {Id, O} = fresh(),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [1, 2, 3, 5]}),
    [{Meas, Meta}] = capture(fun() -> detect(Id, #{O => [6]}) end),
    ?assertEqual(#{count => 1, missing => 1}, Meas),
    ?assertEqual([{4, 4}], maps:get(gaps, Meta)),
    ?assertEqual(3, maps:get(applied_seq, Meta)),
    ?assertEqual(1, maps:get(held, Meta)),
    ?assertEqual(O, maps:get(origin, Meta)).

a_contiguous_batch_is_silent() ->
    {Id, O} = fresh(),
    ?assertEqual([], capture(fun() -> detect(Id, #{O => [1, 2, 3]}) end)),
    ok = bondy_oplog_registry:merge_applied(Id, #{O => [1, 2, 3]}),
    ?assertEqual([], capture(fun() -> detect(Id, #{O => [4]}) end)).

a_gap_with_no_pending_is_unchanged() ->
    {Id, O} = fresh(),
    [{Meas, Meta}] = capture(fun() -> detect(Id, #{O => [3]}) end),
    ?assertEqual(#{count => 1, missing => 2}, Meas),
    ?assertEqual([{1, 2}], maps:get(gaps, Meta)),
    ?assertEqual(0, maps:get(held, Meta)).

%% =============================================================================
%% Helpers
%% =============================================================================

detect(Id, OriginSeqs) ->
    bondy_oplog_cell_apply:detect_prefix_holes(Id, OriginSeqs).

capture(Fun) ->
    Ref = make_ref(),
    Id = {?MODULE, Ref},
    Self = self(),
    ok = telemetry:attach(
        Id,
        ?EVENT,
        fun(_E, Meas, Meta, _Cfg) -> Self ! {Ref, Meas, Meta} end,
        []
    ),
    try
        ok = Fun(),
        drain(Ref)
    after
        telemetry:detach(Id)
    end.

drain(Ref) ->
    receive
        {Ref, Meas, Meta} -> [{Meas, Meta} | drain(Ref)]
    after 0 -> []
    end.

fresh() ->
    Id = list_to_binary(
        "prefix_hole_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    {ok, _} = bondy_oplog:start_instance(Id),
    {Id, bondy_oplog_origin:new()}.

prefix(Id, Origin) ->
    maps:get(Origin, bondy_oplog_registry:frontier(Id), 0).

pending(Id, Origin) ->
    maps:get(Origin, bondy_oplog_registry:pending(Id), []).
