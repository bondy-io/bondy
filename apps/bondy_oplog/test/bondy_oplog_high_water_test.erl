%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_oplog_high_water_test).

-include_lib("eunit/include/eunit.hrl").

%% Sanity: a fresh ref reads as `{ok, no_watermark}`.
new_ref_reads_as_no_watermark_test() ->
    Ref = bondy_oplog_high_water:new(),
    ?assertEqual({ok, no_watermark}, bondy_oplog_high_water:read(Ref)),
    ?assertEqual(0, bondy_oplog_high_water:read_raw(Ref)).

%% Advance from zero is observable.
advance_from_zero_test() ->
    Ref = bondy_oplog_high_water:new(),
    ok = bondy_oplog_high_water:advance(Ref, 42),
    ?assertEqual({ok, 42}, bondy_oplog_high_water:read(Ref)),
    ?assertEqual(42, bondy_oplog_high_water:read_raw(Ref)).

%% Advance is monotonic — a lower HLC does not lower the watermark.
advance_is_monotonic_test() ->
    Ref = bondy_oplog_high_water:new(),
    ok = bondy_oplog_high_water:advance(Ref, 100),
    ok = bondy_oplog_high_water:advance(Ref, 50),
    ok = bondy_oplog_high_water:advance(Ref, 99),
    ?assertEqual({ok, 100}, bondy_oplog_high_water:read(Ref)).

%% Advance to the same value is a no-op (still returns ok).
advance_same_value_test() ->
    Ref = bondy_oplog_high_water:new(),
    ok = bondy_oplog_high_water:advance(Ref, 200),
    ok = bondy_oplog_high_water:advance(Ref, 200),
    ?assertEqual({ok, 200}, bondy_oplog_high_water:read(Ref)).

%% Advance to a higher value updates the watermark.
advance_to_higher_test() ->
    Ref = bondy_oplog_high_water:new(),
    ok = bondy_oplog_high_water:advance(Ref, 10),
    ok = bondy_oplog_high_water:advance(Ref, 20),
    ok = bondy_oplog_high_water:advance(Ref, 30),
    ?assertEqual({ok, 30}, bondy_oplog_high_water:read(Ref)).

%% Concurrent advancers — the final value is the max across all of them.
concurrent_advancers_converge_to_max_test() ->
    Ref = bondy_oplog_high_water:new(),
    Self = self(),
    Hlcs = lists:seq(1, 500),
    Pids = [
        spawn(fun() ->
            bondy_oplog_high_water:advance(Ref, H),
            Self ! {done, H}
        end)
     || H <- Hlcs
    ],
    [
        receive
            {done, _} -> ok
        end
     || _ <- Pids
    ],
    ?assertEqual({ok, 500}, bondy_oplog_high_water:read(Ref)).

%% Concurrent advancers each contributing a random HLC: the final value
%% must equal `lists:max(Hlcs)` regardless of interleaving.
concurrent_advancers_random_max_test() ->
    Ref = bondy_oplog_high_water:new(),
    Self = self(),
    Hlcs = [rand:uniform(1_000_000) || _ <- lists:seq(1, 200)],
    Pids = [
        spawn(fun() ->
            bondy_oplog_high_water:advance(Ref, H),
            Self ! {done, H}
        end)
     || H <- Hlcs
    ],
    [
        receive
            {done, _} -> ok
        end
     || _ <- Pids
    ],
    ?assertEqual({ok, lists:max(Hlcs)}, bondy_oplog_high_water:read(Ref)).

%% Advance with 0 from a fresh ref leaves the ref at 0 — read still
%% returns `{ok, no_watermark}` because the no-watermark sentinel IS 0.
advance_with_zero_stays_no_watermark_test() ->
    Ref = bondy_oplog_high_water:new(),
    ok = bondy_oplog_high_water:advance(Ref, 0),
    ?assertEqual({ok, no_watermark}, bondy_oplog_high_water:read(Ref)).
