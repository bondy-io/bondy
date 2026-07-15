%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests the adaptive live-sync throttle in `bondy_oplog_sync_scheduler`.
%%
%% A `live` instance only re-syncs to discover divergence; once its data
%% has converged there is nothing to pull, yet the historical dispatch
%% spawned a session against every peer on every tick. The throttle
%% gates that with a per-instance geometric backoff keyed on the
%% instance's MST root as a change detector. These tests drive the
%% backoff state machine (`live_decide/5`) directly with synthetic roots
%% and a controlled clock, so they are deterministic and need neither a
%% running instance nor real sync sessions:
%%
%%   - First sight of an instance dispatches.
%%   - A root change always dispatches and resets the window to base.
%%   - A quiescent (unchanged-root) instance is skipped until its poll
%%     window elapses, then polls once and doubles the window.
%%   - The window is capped at `Max`.
%%   - A root change after backoff resets the cadence to base.
%% =============================================================================
-module(bondy_oplog_sync_scheduler_live_backoff_test).

-include_lib("eunit/include/eunit.hrl").

-define(BASE, 500).
-define(MAX, 30000).

live_backoff_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 10, fun first_sight_dispatches/0},
        {timeout, 10, fun unchanged_root_skips_within_window/0},
        {timeout, 10, fun window_elapsed_polls_and_doubles/0},
        {timeout, 10, fun window_caps_at_max/0},
        {timeout, 10, fun root_change_resets_to_base/0}
    ]}.

setup() ->
    %% Brings up the scheduler, whose `init/1` creates the live-backoff
    %% ETS table `live_decide/5` reads and writes.
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Stop periodic ticks so the real scheduler never touches the table
    %% under our synthetic ids.
    ok = bondy_oplog_sync_scheduler:set_interval_ms(0),
    ok.

cleanup(_) ->
    ok = bondy_oplog_sync_scheduler:set_interval_ms(500),
    ok.

%% A never-before-seen instance always dispatches (records the entry).
first_sight_dispatches() ->
    Id = mk_id(),
    ?assert(
        bondy_oplog_sync_scheduler:live_decide(Id, root(1), 0, ?BASE, ?MAX)
    ).

%% Same root, clock has not reached the next-due time → skip.
unchanged_root_skips_within_window() ->
    Id = mk_id(),
    R = root(1),
    ?assert(bondy_oplog_sync_scheduler:live_decide(Id, R, 0, ?BASE, ?MAX)),
    %% A tick before the window elapses (?BASE) — skipped.
    ?assertNot(
        bondy_oplog_sync_scheduler:live_decide(Id, R, ?BASE - 1, ?BASE, ?MAX)
    ),
    ?assertNot(
        bondy_oplog_sync_scheduler:live_decide(Id, R, 1, ?BASE, ?MAX)
    ).

%% Once the clock reaches the due time, a quiescent instance polls once
%% and the window doubles (?BASE → 2*?BASE → 4*?BASE ...).
window_elapsed_polls_and_doubles() ->
    Id = mk_id(),
    R = root(1),
    %% First sight: window = ?BASE, due at ?BASE.
    ?assert(bondy_oplog_sync_scheduler:live_decide(Id, R, 0, ?BASE, ?MAX)),
    %% At ?BASE the window elapsed → poll; window grows to 2*?BASE, due
    %% at ?BASE + 2*?BASE.
    ?assert(bondy_oplog_sync_scheduler:live_decide(Id, R, ?BASE, ?BASE, ?MAX)),
    %% Just before the new due time → skip.
    Due2 = ?BASE + 2 * ?BASE,
    ?assertNot(
        bondy_oplog_sync_scheduler:live_decide(Id, R, Due2 - 1, ?BASE, ?MAX)
    ),
    %% At the new due time → poll again; window grows to 4*?BASE.
    ?assert(
        bondy_oplog_sync_scheduler:live_decide(Id, R, Due2, ?BASE, ?MAX)
    ),
    Due3 = Due2 + 4 * ?BASE,
    ?assertNot(
        bondy_oplog_sync_scheduler:live_decide(Id, R, Due3 - 1, ?BASE, ?MAX)
    ),
    ?assert(
        bondy_oplog_sync_scheduler:live_decide(Id, R, Due3, ?BASE, ?MAX)
    ).

%% The doubling window never exceeds Max. Use a small Max so few rounds
%% reach the cap; once capped, successive polls stay exactly Max apart.
window_caps_at_max() ->
    Id = mk_id(),
    R = root(1),
    Base = 100,
    Max = 400,
    %% Drive successive polls, always stepping the clock to the current
    %% due time, and assert the inter-poll gap caps at Max.
    Now0 = 0,
    ?assert(bondy_oplog_sync_scheduler:live_decide(Id, R, Now0, Base, Max)),
    %% windows: 100 -> 200 -> 400 -> 400 (capped) -> 400 ...
    Gaps = drive_polls(Id, R, Now0, Base, Max, 5),
    ?assertEqual([100, 200, 400, 400, 400], Gaps).

%% A changed root always dispatches and resets the window to base, even
%% deep into a backed-off window.
root_change_resets_to_base() ->
    Id = mk_id(),
    R1 = root(1),
    %% Back off a few rounds so the window is wide.
    ?assert(bondy_oplog_sync_scheduler:live_decide(Id, R1, 0, ?BASE, ?MAX)),
    ?assert(bondy_oplog_sync_scheduler:live_decide(Id, R1, ?BASE, ?BASE, ?MAX)),
    Due2 = ?BASE + 2 * ?BASE,
    ?assert(bondy_oplog_sync_scheduler:live_decide(Id, R1, Due2, ?BASE, ?MAX)),
    %% Window is now 4*?BASE. A root change at the very next tick must
    %% still dispatch (activity beats backoff)...
    R2 = root(2),
    ?assert(
        bondy_oplog_sync_scheduler:live_decide(Id, R2, Due2 + 1, ?BASE, ?MAX)
    ),
    %% ...and the window is back to base: skip within ?BASE of the reset.
    ?assertNot(
        bondy_oplog_sync_scheduler:live_decide(
            Id, R2, Due2 + 1 + (?BASE - 1), ?BASE, ?MAX
        )
    ),
    %% At base after the reset → poll again.
    ?assert(
        bondy_oplog_sync_scheduler:live_decide(
            Id, R2, Due2 + 1 + ?BASE, ?BASE, ?MAX
        )
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Steps the clock to each successive due time, polling N times, and
%% returns the list of inter-poll gaps (the effective windows).
drive_polls(Id, Root, Now, Base, Max, N) ->
    drive_polls(Id, Root, Now, Base, Max, N, []).

drive_polls(_Id, _Root, _Now, _Base, _Max, 0, Acc) ->
    lists:reverse(Acc);
drive_polls(Id, Root, Now, Base, Max, N, Acc) ->
    Window = current_window(Id),
    Next = Now + Window,
    ?assert(bondy_oplog_sync_scheduler:live_decide(Id, Root, Next, Base, Max)),
    drive_polls(Id, Root, Next, Base, Max, N - 1, [Window | Acc]).

%% Reads the current window straight from the scheduler's backoff table.
current_window(Id) ->
    [{Id, _Root, _Due, Window}] =
        ets:lookup(bondy_oplog_sync_scheduler_live_backoff, Id),
    Window.

mk_id() ->
    list_to_binary(
        "livebo_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

root(N) ->
    crypto:hash(sha256, integer_to_binary(N)).
