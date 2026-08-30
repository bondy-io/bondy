%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_clock_skew_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

-define(BITS, ?BONDY_OPLOG_HLC_LOGICAL_BITS).

%% Pack a physical millisecond value with a logical counter, the way
%% `bondy_oplog_hlc:encode/2` does.
hlc(PhysMs, Logical) ->
    (PhysMs bsl ?BITS) bor Logical.

wall() ->
    1756500000000.

%% =============================================================================
%% IN TOLERANCE
%% =============================================================================

same_instant_is_not_ahead_test() ->
    ?assertEqual(ok, bondy_oplog_clock_skew:check(hlc(wall(), 0), wall())).

within_tolerance_is_not_ahead_test() ->
    Ms = wall() + timer:minutes(1),
    ?assertEqual(ok, bondy_oplog_clock_skew:check(hlc(Ms, 0), wall())).

%% The boundary belongs to the tolerance: exactly `max_skew_ms` ahead is
%% still acceptable, so the first reported value is strictly past it.
at_the_boundary_is_not_ahead_test() ->
    Ms = wall() + bondy_oplog_clock_skew:max_skew_ms(),
    ?assertEqual(ok, bondy_oplog_clock_skew:check(hlc(Ms, 0), wall())).

%% =============================================================================
%% OUT OF TOLERANCE
%% =============================================================================

just_past_the_boundary_is_ahead_test() ->
    Skew = bondy_oplog_clock_skew:max_skew_ms() + 1,
    Ms = wall() + Skew,
    ?assertEqual(
        {ahead, Skew}, bondy_oplog_clock_skew:check(hlc(Ms, 0), wall())
    ).

%% A snapshot restore, which is the failure mode this exists for. The
%% reported figure is the RAW distance, not the distance past the
%% threshold: "30 days" tells an operator what happened, "30 days minus
%% five minutes" tells them nothing extra.
snapshot_restore_reports_raw_distance_test() ->
    Skew = 30 * 24 * 60 * 60 * 1000,
    Ms = wall() + Skew,
    ?assertEqual(
        {ahead, Skew}, bondy_oplog_clock_skew:check(hlc(Ms, 0), wall())
    ).

%% =============================================================================
%% FALSIFIERS
%% =============================================================================

%% A peer BEHIND us is harmless -- its writes lose last-writer-wins on their
%% own and it drags this replica's clock nowhere. Reporting it would make the
%% signal useless, because a node with an unset clock (epoch 0) is behind by
%% five decades and would drown out every real case.
peer_behind_is_never_reported_test() ->
    Ms = wall() - timer:hours(72),
    ?assertEqual(ok, bondy_oplog_clock_skew:check(hlc(Ms, 0), wall())),
    ?assertEqual(ok, bondy_oplog_clock_skew:check(hlc(0, 0), wall())).

%% THE bit-shift falsifier. The logical counter occupies the low 16 bits and
%% carries no wall-clock meaning. Comparing the PACKED value against
%% milliseconds -- the obvious mistake -- multiplies every timestamp by 65536
%% and reports every peer, forever, as roughly 3.7 million years ahead. A
%% maxed logical counter at the current instant must still read as `ok`.
maxed_logical_counter_is_not_skew_test() ->
    Packed = hlc(wall(), 65535),
    ?assertEqual(ok, bondy_oplog_clock_skew:check(Packed, wall())),
    %% and the packed value really is far larger than the millisecond figure,
    %% so the assertion above is not vacuous
    ?assert(Packed > wall() * 60000).

%% The logical counter must not contribute to the reported distance either.
logical_counter_does_not_inflate_the_report_test() ->
    Skew = bondy_oplog_clock_skew:max_skew_ms() + 1,
    Ms = wall() + Skew,
    ?assertEqual(
        {ahead, Skew},
        bondy_oplog_clock_skew:check(hlc(Ms, 65535), wall())
    ).

%% Detection must never be able to break the path it observes. `check/2` runs
%% on remote-event ingress, so an input it cannot interpret has to cost the
%% caller nothing -- a `function_clause` here would be an outage on precisely
%% the traffic being watched.
non_integer_input_never_raises_test() ->
    ?assertEqual(ok, bondy_oplog_clock_skew:check(undefined, wall())),
    ?assertEqual(ok, bondy_oplog_clock_skew:check(<<"nonsense">>, wall())),
    ?assertEqual(ok, bondy_oplog_clock_skew:check(hlc(wall(), 0), undefined)),
    ?assertEqual(ok, bondy_oplog_clock_skew:check(-1, wall())).
