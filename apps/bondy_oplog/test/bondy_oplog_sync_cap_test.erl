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
        {"an oversized cell is skipped, metered, and advanced past",
            fun cells_oversized/0},
        {"an all-oversized range yields an empty batch advanced past all",
            fun cells_all_oversized/0},
        {"at least one fitting cell is always kept", fun cells_at_least_one/0}
    ]}.

cells_small() ->
    Pairs = pairs([1000, 1000, 1000]),
    {Cells, Advance} = bondy_oplog_catalogue_snapshot:cap_cells(
        <<"i">>, <<"b">>, Pairs, ?BUDGET
    ),
    ?assertEqual(3, length(Cells)),
    ?assertEqual(key(3), Advance).

cells_over() ->
    Pairs = pairs(lists:duplicate(20, 1000)),
    {Cells, Advance} = bondy_oplog_catalogue_snapshot:cap_cells(
        <<"i">>, <<"b">>, Pairs, ?BUDGET
    ),
    ?assert(length(Cells) > 0),
    ?assert(length(Cells) < 20),
    {_, LastKeptK, _} = lists:last(Cells),
    ?assertEqual(LastKeptK, Advance),
    Total = lists:sum([erlang:external_size(C) || C <- Cells]),
    ?assert(Total =< ?BUDGET).

cells_oversized() ->
    Before = counter_value(cell),
    Pairs = [{key(1), blob(1000)}, {key(2), blob(20000)}, {key(3), blob(1000)}],
    {Cells, Advance} = bondy_oplog_catalogue_snapshot:cap_cells(
        <<"i">>, <<"b">>, Pairs, ?BUDGET
    ),
    Keys = [K || {_, K, _} <- Cells],
    ?assertEqual([key(1), key(3)], Keys),
    ?assertEqual(key(3), Advance),
    ?assert(counter_value(cell) >= Before + 1).

cells_all_oversized() ->
    Pairs = [{key(1), blob(20000)}, {key(2), blob(20000)}],
    {Cells, Advance} = bondy_oplog_catalogue_snapshot:cap_cells(
        <<"i">>, <<"b">>, Pairs, ?BUDGET
    ),
    ?assertEqual([], Cells),
    ?assertEqual(key(2), Advance).

cells_at_least_one() ->
    Pairs = pairs([9000, 9000]),
    {Cells, Advance} = bondy_oplog_catalogue_snapshot:cap_cells(
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
    _ = catch alarm_handler:set_alarm({bondy_oplog_sync_oversized_items, x}),
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
            _ = catch alarm_handler:clear_alarm(Id),
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
    _ = catch alarm_handler:clear_alarm(bondy_oplog_sync_oversized_items),
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
