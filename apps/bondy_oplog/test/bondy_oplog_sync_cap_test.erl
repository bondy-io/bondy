%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_sync_cap_test).

-include_lib("eunit/include/eunit.hrl").

%% The byte ceiling the page/cell tests pin via the app env override.
-define(BUDGET, 10000).
%% Partisan's own default frame cap (64 MB) — the derivation falls back to it
%% when partisan is not running (as here in eunit).
-define(PARTISAN_DEFAULT, 67108864).

%% =============================================================================
%% CONFIG DERIVATION
%% =============================================================================

config_test_() ->
    [
        {"sync_max_response_bytes derives from the frame cap x headroom",
            fun derivation/0},
        {"an explicit sync_max_response_bytes override wins", fun override/0},
        {"headroom above the safe max is clamped; invalid falls back",
            fun headroom_clamp/0}
    ].

derivation() ->
    ok = application:unset_env(bondy_oplog, sync_max_response_bytes),
    ok = application:set_env(bondy_oplog, sync_response_headroom, 0.5),
    ?assertEqual(
        round(?PARTISAN_DEFAULT * 0.5),
        bondy_oplog_config:sync_max_response_bytes()
    ),
    ok = application:unset_env(bondy_oplog, sync_response_headroom).

override() ->
    ok = application:set_env(bondy_oplog, sync_max_response_bytes, 12345),
    ?assertEqual(12345, bondy_oplog_config:sync_max_response_bytes()),
    ok = application:unset_env(bondy_oplog, sync_max_response_bytes).

headroom_clamp() ->
    %% Above the safe max → clamped to 0.95 (never the raw value, which would
    %% leave no room for map/envelope/framing overhead → emsgsize).
    ok = application:set_env(bondy_oplog, sync_response_headroom, 5.0),
    ?assertEqual(0.95, bondy_oplog_config:sync_response_headroom()),
    %% Non-positive / non-numeric → fall back to the default.
    ok = application:set_env(bondy_oplog, sync_response_headroom, -1),
    ?assertEqual(0.8, bondy_oplog_config:sync_response_headroom()),
    ok = application:unset_env(bondy_oplog, sync_response_headroom).

%% =============================================================================
%% PAGE CAPPING (get_pages)
%% =============================================================================

pages_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"a batch under the ceiling is returned whole", fun pages_small/0},
        {"a batch over the ceiling is truncated to fit, non-empty",
            fun pages_over/0},
        {"an oversized single page is skipped and metered",
            fun pages_oversized/0},
        {"fitting pages are kept, an oversized one skipped", fun pages_mixed/0},
        {"at least one fitting page is always returned",
            fun pages_at_least_one/0}
    ]}.

pages_small() ->
    Pages = pages_map([1000, 1000, 1000]),
    Capped = bondy_oplog_responder:cap_pages(<<"i">>, Pages),
    ?assertEqual(Pages, Capped).

pages_over() ->
    Pages = pages_map(lists:duplicate(20, 1000)),
    Capped = bondy_oplog_responder:cap_pages(<<"i">>, Pages),
    ?assert(map_size(Capped) > 0),
    ?assert(map_size(Capped) < 20),
    Total = maps:fold(
        fun(_, P, Acc) -> Acc + erlang:external_size(P) end, 0, Capped
    ),
    ?assert(Total =< ?BUDGET).

pages_oversized() ->
    Before = counter_value(page),
    Pages = pages_map([20000]),
    Capped = bondy_oplog_responder:cap_pages(<<"i">>, Pages),
    ?assertEqual(0, map_size(Capped)),
    ?assert(counter_value(page) >= Before + 1).

pages_mixed() ->
    Pages = pages_map([20000, 1000, 1000]),
    Capped = bondy_oplog_responder:cap_pages(<<"i">>, Pages),
    ?assertEqual(2, map_size(Capped)).

pages_at_least_one() ->
    Pages = pages_map([9000, 9000]),
    Capped = bondy_oplog_responder:cap_pages(<<"i">>, Pages),
    ?assertEqual(1, map_size(Capped)).

%% =============================================================================
%% CELL CAPPING (catalogue snapshot)
%% =============================================================================

cells_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"a batch under the ceiling keeps every cell, advances to the last key",
            fun cells_small/0},
        {"a batch over the ceiling is truncated, advances to the last kept key",
            fun cells_over/0},
        {
            "an oversized cell behind kept cells flushes them first, and is NOT "
            "advanced past",
            fun cells_oversized/0
        },
        {
            "a leading oversized cell is surrendered for part-shipping, not "
            "skipped",
            fun cells_all_oversized/0
        },
        {"at least one fitting cell is always kept", fun cells_at_least_one/0},
        {"an oversized frame splits into parts that reassemble EXACTLY",
            fun parts_roundtrip/0},
        {"parts of two cells interleaved across rounds reassemble correctly",
            fun parts_interleaved/0},
        {"a reassembly missing any part stays pending, never installs",
            fun parts_incomplete_stays_pending/0},
        {"every emitted part fits under the round ceiling",
            fun parts_fit_ceiling/0}
    ]}.

cells_small() ->
    Pairs = pairs([1000, 1000, 1000]),
    {ok, Cells, Advance} = bondy_oplog_catalogue_snapshot:cap_cells(
        <<"i">>, <<"b">>, Pairs, ?BUDGET
    ),
    ?assertEqual(3, length(Cells)),
    ?assertEqual(key(3), Advance).

cells_over() ->
    Pairs = pairs(lists:duplicate(20, 1000)),
    {ok, Cells, Advance} = bondy_oplog_catalogue_snapshot:cap_cells(
        <<"i">>, <<"b">>, Pairs, ?BUDGET
    ),
    ?assert(length(Cells) > 0),
    ?assert(length(Cells) < 20),
    {_, LastKeptK, _} = lists:last(Cells),
    ?assertEqual(LastKeptK, Advance),
    Total = lists:sum([erlang:external_size(C) || C <- Cells]),
    ?assert(Total =< ?BUDGET).

%% The oversized cell is met at key(2). Cells are already accumulated, so
%% cap_cells flushes them and advances only to key(1) — key(2) leads the next
%% round and is part-shipped there. The OLD behaviour advanced to key(3),
%% stepping over key(2) permanently; that is the data loss this replaces.
cells_oversized() ->
    Pairs = [{key(1), blob(1000)}, {key(2), blob(20000)}, {key(3), blob(1000)}],
    {ok, Cells, Advance} = bondy_oplog_catalogue_snapshot:cap_cells(
        <<"i">>, <<"b">>, Pairs, ?BUDGET
    ),
    Keys = [K || {_, K, _} <- Cells],
    ?assertEqual([key(1)], Keys),
    ?assertEqual(key(1), Advance),
    ?assertNotEqual(key(3), Advance).

%% A leading oversized cell is handed back for part-shipping, carrying its
%% frame. It is still metered, so the operator alarm keeps working.
cells_all_oversized() ->
    Before = counter_value(cell),
    Frame = blob(20000),
    Pairs = [{key(1), Frame}, {key(2), blob(20000)}],
    ?assertEqual(
        {oversized, key(1), Frame},
        bondy_oplog_catalogue_snapshot:cap_cells(
            <<"i">>, <<"b">>, Pairs, ?BUDGET
        )
    ),
    ?assert(counter_value(cell) >= Before + 1).

%% =============================================================================
%% PART-SHIPPING ROUND TRIP
%% =============================================================================

%% Splits a frame the way `emit_parts/6` does, in as many rounds as it takes.
split_all(Bucket, Key, Frame, MaxBytes) ->
    PB = bondy_oplog_catalogue_snapshot:part_payload_bytes(
        Bucket, Key, MaxBytes
    ),
    Total = bondy_oplog_catalogue_snapshot:total_parts(Frame, PB),
    split_all(Bucket, Key, Frame, PB, Total, 1, MaxBytes, []).

split_all(_B, _K, _F, _PB, Total, Idx, _Max, Acc) when Idx > Total ->
    lists:reverse(Acc);
split_all(B, K, F, PB, Total, Idx, Max, Acc) ->
    {Parts, LastIdx} = bondy_oplog_catalogue_snapshot:take_parts(
        B, K, F, PB, Total, Idx, Max
    ),
    ?assert(Parts =/= []),
    ?assert(LastIdx >= Idx),
    split_all(B, K, F, PB, Total, LastIdx + 1, Max, [Parts | Acc]).

%% The property that matters: whatever the split, concatenation restores the
%% ORIGINAL bytes. An off-by-one in offset or length breaks this.
parts_roundtrip() ->
    Frame = crypto:strong_rand_bytes(20000),
    Rounds = split_all(<<"b">>, key(1), Frame, ?BUDGET),
    ?assert(length(Rounds) > 1),
    {Cells, Pending} = lists:foldl(
        fun(Round, {CellAcc, Pend}) ->
            {Done, Pend1} = bondy_oplog_sync_session:absorb_chunks(Round, Pend),
            {CellAcc ++ Done, Pend1}
        end,
        {[], #{}},
        Rounds
    ),
    ?assertEqual(#{}, Pending),
    ?assertEqual([{<<"b">>, key(1), Frame}], Cells).

%% Two cells in flight at once must not cross-contaminate.
parts_interleaved() ->
    F1 = crypto:strong_rand_bytes(20000),
    F2 = crypto:strong_rand_bytes(15000),
    R1 = lists:flatten(split_all(<<"b">>, key(1), F1, ?BUDGET)),
    R2 = lists:flatten(split_all(<<"b">>, key(2), F2, ?BUDGET)),
    %% Feed them one part at a time, alternating.
    Interleaved = interleave(R1, R2),
    {Cells, Pending} = lists:foldl(
        fun(Part, {CellAcc, Pend}) ->
            {Done, Pend1} = bondy_oplog_sync_session:absorb_chunks(
                [Part], Pend
            ),
            {CellAcc ++ Done, Pend1}
        end,
        {[], #{}},
        Interleaved
    ),
    ?assertEqual(#{}, Pending),
    ?assertEqual(
        lists:sort([{<<"b">>, key(1), F1}, {<<"b">>, key(2), F2}]),
        lists:sort(Cells)
    ).

interleave([], B) -> B;
interleave(A, []) -> A;
interleave([H1 | T1], [H2 | T2]) -> [H1, H2 | interleave(T1, T2)].

%% Drop one part and the cell must NOT be produced — it stays pending, which
%% is what makes `pull_install_loop` fail the bootstrap instead of finalizing
%% over a hole.
parts_incomplete_stays_pending() ->
    Frame = crypto:strong_rand_bytes(20000),
    All = lists:flatten(split_all(<<"b">>, key(1), Frame, ?BUDGET)),
    ?assert(length(All) > 1),
    Missing = tl(All),
    {Cells, Pending} = bondy_oplog_sync_session:absorb_chunks(Missing, #{}),
    ?assertEqual([], Cells),
    ?assertEqual([{<<"b">>, key(1)}], maps:keys(Pending)).

%% Every part must be framable on its own, or part-shipping just moves the
%% frame-cap failure rather than removing it.
parts_fit_ceiling() ->
    Frame = crypto:strong_rand_bytes(50000),
    Rounds = split_all(<<"b">>, key(1), Frame, ?BUDGET),
    lists:foreach(
        fun(Round) ->
            lists:foreach(
                fun(Part) ->
                    ?assert(erlang:external_size(Part) =< ?BUDGET)
                end,
                Round
            ),
            Total = lists:sum([erlang:external_size(P) || P <- Round]),
            ?assert(Total =< ?BUDGET)
        end,
        Rounds
    ).

cells_at_least_one() ->
    Pairs = pairs([9000, 9000]),
    {ok, Cells, Advance} = bondy_oplog_catalogue_snapshot:cap_cells(
        <<"i">>, <<"b">>, Pairs, ?BUDGET
    ),
    ?assertEqual(1, length(Cells)),
    ?assertEqual(key(1), Advance).

%% =============================================================================
%% OVERSIZED-ITEM ALARM (responder poll)
%% =============================================================================

alarm_test_() ->
    {setup, fun alarm_setup/0, fun alarm_cleanup/1, [
        {"a counter increase raises the SASL alarm", fun alarm_raises/0},
        {"a quiet window clears the alarm", fun alarm_clears/0}
    ]}.

alarm_raises() ->
    clear_all(bondy_oplog_sync_oversized_items),
    %% No new skips since PrevTotal → no alarm.
    Base = bondy_oplog_sync_metrics:oversized_total(),
    S0 = astate(false, Base, 0),
    S1 = bondy_oplog_responder:check_oversized_alarm(S0),
    ?assertNot(maps:get(oversized_alarm, S1)),
    ?assertNot(alarm_active(bondy_oplog_sync_oversized_items)),
    %% A skip bumps the counter → the poll asserts the alarm.
    ok = bondy_oplog_sync_metrics:report_oversized(page, {i, h}, 99999, 1000),
    S2 = bondy_oplog_responder:check_oversized_alarm(S1),
    ?assert(maps:get(oversized_alarm, S2)),
    ?assert(alarm_active(bondy_oplog_sync_oversized_items)).

alarm_clears() ->
    clear_all(bondy_oplog_sync_oversized_items),
    ok = bondy_oplog_sync_metrics:report_oversized(cell, {i, k}, 99999, 1000),
    Total = bondy_oplog_sync_metrics:oversized_total(),
    _ =
        try
            alarm_handler:set_alarm({bondy_oplog_sync_oversized_items, x})
        catch
            _:_ -> ok
        end,
    %% Alarmed, last increase older than the clear window (a real monotonic
    %% timestamp), no new skips → clears.
    Past = erlang:monotonic_time(millisecond) - 400000,
    S0 = astate(true, Total, Past),
    S1 = bondy_oplog_responder:check_oversized_alarm(S0),
    ?assertNot(maps:get(oversized_alarm, S1)),
    ?assertNot(alarm_active(bondy_oplog_sync_oversized_items)).

astate(Alarmed, Total, LastInc) ->
    #{
        oversized_alarm => Alarmed,
        oversized_total => Total,
        oversized_last_increase => LastInc
    }.

alarm_active(Id) ->
    lists:keymember(Id, 1, alarm_handler:get_alarms()).

%% The default OTP alarm_handler accumulates duplicate ids and clears one at a
%% time; drain all copies so each test starts from a known-clean state.
clear_all(Id) ->
    case alarm_active(Id) of
        true ->
            _ =
                try
                    alarm_handler:clear_alarm(Id)
                catch
                    _:_ -> ok
                end,
            clear_all(Id);
        false ->
            ok
    end.

alarm_setup() ->
    {ok, _} = application:ensure_all_started(sasl),
    {ok, _} = application:ensure_all_started(bondy_metrics),
    _ =
        case bondy_metrics:start_link() of
            {ok, _} -> ok;
            {error, {already_started, _}} -> ok
        end,
    ok.

alarm_cleanup(_) ->
    _ =
        try
            alarm_handler:clear_alarm(bondy_oplog_sync_oversized_items)
        catch
            _:_ -> ok
        end,
    ok.

%% =============================================================================
%% HELPERS
%% =============================================================================

setup() ->
    {ok, _} = application:ensure_all_started(bondy_metrics),
    %% bondy_metrics is a library app — its gen_server (which owns the counter
    %% tables) is started by the consumer's supervisor, so bring it up here.
    _ =
        case bondy_metrics:start_link() of
            {ok, _} -> ok;
            {error, {already_started, _}} -> ok
        end,
    ok = application:set_env(bondy_oplog, sync_max_response_bytes, ?BUDGET),
    ok.

cleanup(_) ->
    ok = application:unset_env(bondy_oplog, sync_max_response_bytes),
    ok.

%% A blob of N bytes — the payload that dominates a page/cell's serialized size.
blob(N) -> <<0:(N * 8)>>.

%% An MST page whose serialized size is ~ NBytes.
page(NBytes) ->
    bondy_mst_page:new(0, undefined, [{<<"k">>, blob(NBytes), undefined}]).

%% #{Hash => page()} with distinct hashes, one page per requested size.
pages_map(Sizes) ->
    maps:from_list([
        {integer_to_binary(I), page(S)}
     || {I, S} <- lists:zip(lists:seq(1, length(Sizes)), Sizes)
    ]).

%% Ordered {Key, Frame} pairs — the shape a catalogue range query returns.
pairs(Sizes) ->
    [
        {key(I), blob(S)}
     || {I, S} <- lists:zip(lists:seq(1, length(Sizes)), Sizes)
    ].

%% Zero-padded so lexicographic order matches numeric order past 9.
key(I) ->
    Bin = list_to_binary(io_lib:format("~4..0b", [I])),
    <<"k", Bin/binary>>.

counter_value(Kind) ->
    case
        bondy_metrics:value(#{
            name => bondy_oplog_sync_oversized_item_total,
            label => #{kind => Kind}
        })
    of
        undefined -> 0;
        N -> N
    end.
