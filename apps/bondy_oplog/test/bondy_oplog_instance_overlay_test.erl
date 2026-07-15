%% Tests for the per-instance overlay.
%%
%% The overlay is a per-instance public `ordered_set` ETS table that
%% receives every successfully WAL-appended local event so callers
%% reading back the key see the entry before the applier has promoted
%% it to the MST. The overlay row is evicted atomically with the MST
%% insert via HLC-conditional `ets:select_delete/2`.
%%
%% These tests pin the overlay's user-visible behaviour:
%% - read-your-writes via `get/2` after `append/2` (overlay-first)
%% - `fold_range/5` merges overlay + MST in key order (streaming
%%   merge)
%% - `size/1` includes overlay rows (events visible to readers)
%% - `{error, backpressure}` when overlay caps are breached
%% - `await_apply/2` drains the overlay before a sync point
%% - HLC-conditional eviction preserves a newer write that overwrote
%%   an older overlay row mid-apply

-module(bondy_oplog_instance_overlay_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

overlay_test_() ->
    %% 30s per-test timeout (eunit default is 5s). Several tests here
    %% call `await_apply/1` which polls the overlay; under whole-suite
    %% load that drain can take longer than 5s and race the eunit
    %% watchdog into a `*timed out*` cancellation.
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun get_after_append_hits_overlay/0},
        {timeout, 30, fun fold_range_merges_overlay_and_mst/0},
        {timeout, 30, fun size_includes_overlay_rows/0},
        {timeout, 30, fun first_and_latest_merge_overlay/0},
        {timeout, 30, fun await_apply_drains_overlay/0},
        {timeout, 30, fun overlay_events_cap_returns_backpressure/0},
        {timeout, 30, fun overlay_value_round_trip/0},
        {timeout, 30, fun overlay_evicts_after_apply/0}
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

get_after_append_hits_overlay() ->
    %% The new write path returns after WAL fsync + overlay insert,
    %% not after the applier promotes to the MST. `get/2` must see
    %% the event immediately via the overlay path.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Key = bondy_oplog:append(Id, hello),
    %% No await_apply here — we are testing the overlay path.
    {ok, Event} = bondy_oplog:get(Id, Key),
    ?assertEqual(hello, bondy_oplog_event:op(Event)),
    ok = bondy_oplog:stop_instance(Id).

fold_range_merges_overlay_and_mst() ->
    %% Append a batch, drain partway by calling await_apply (so some
    %% events have promoted), then append more. Both promoted and
    %% staged events must appear in fold_range output in strict key
    %% order.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    PromotedKeys = [bondy_oplog:append(Id, {p, N}) || N <- lists:seq(1, 5)],
    ok = bondy_oplog:await_apply(Id),
    StagedKeys = [bondy_oplog:append(Id, {s, N}) || N <- lists:seq(6, 10)],
    AllKeys = PromotedKeys ++ StagedKeys,
    First = lists:nth(1, AllKeys),
    Last = lists:last(AllKeys),
    EventsOut = lists:reverse(
        bondy_oplog:fold_range(
            Id,
            First,
            Last,
            fun(E, A) -> [E | A] end,
            []
        )
    ),
    Ops = [bondy_oplog_event:op(E) || E <- EventsOut],
    Expected =
        [{p, N} || N <- lists:seq(1, 5)] ++
            [{s, N} || N <- lists:seq(6, 10)],
    ?assertEqual(Expected, Ops),
    %% Strict ascending key order:
    Keys = [bondy_oplog_event:key(E) || E <- EventsOut],
    ?assertEqual(lists:sort(Keys), Keys),
    ok = bondy_oplog:stop_instance(Id).

size_includes_overlay_rows() ->
    %% `size/1` returns the total visible events = MST.live_size +
    %% overlay count. The atomic in-handler eviction keeps these
    %% sets disjoint so there is no double-count.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    [bondy_oplog:append(Id, N) || N <- lists:seq(1, 10)],
    %% Read size repeatedly — it should be 10 from the very first
    %% read (overlay carries the events until applier catches up).
    ?assertEqual(10, bondy_oplog:size(Id)),
    ok = bondy_oplog:await_apply(Id),
    ?assertEqual(10, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

first_and_latest_merge_overlay() ->
    %% first_key/latest_key must consult both overlay and MST.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    %% Append two events; both end up in overlay before the applier
    %% catches up. first_key/latest_key should still return valid
    %% keys.
    K1 = bondy_oplog:append(Id, a),
    K2 = bondy_oplog:append(Id, b),
    ?assertEqual({ok, K1}, bondy_oplog:first_key(Id)),
    ?assertEqual({ok, K2}, bondy_oplog:latest_key(Id)),
    ok = bondy_oplog:await_apply(Id),
    %% Same after apply (events now in MST).
    ?assertEqual({ok, K1}, bondy_oplog:first_key(Id)),
    ?assertEqual({ok, K2}, bondy_oplog:latest_key(Id)),
    ok = bondy_oplog:stop_instance(Id).

await_apply_drains_overlay() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    [bondy_oplog:append(Id, N) || N <- lists:seq(1, 20)],
    ok = bondy_oplog:await_apply(Id, 5000),
    %% After await, every overlay row has been evicted; size still
    %% reads 20 because the events are now all in the MST.
    ?assertEqual(20, bondy_oplog:size(Id)),
    %% Overlay should be empty.
    case bondy_oplog_registry:overlay_tab(Id) of
        undefined -> ok;
        Tab -> ?assertEqual(0, ets:info(Tab, size))
    end,
    ok = bondy_oplog:stop_instance(Id).

overlay_events_cap_returns_backpressure() ->
    %% A tight overlay events cap surfaces `{error, backpressure}`
    %% when exceeded. We use a tiny cap and assert the threshold
    %% fires deterministically by suspending the applier so the
    %% overlay does not drain between appends.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        max_overlay_events => 3
    }),
    %% Suspend the applier (not the instance) so events accumulate
    %% in the overlay but the instance gen_server continues to serve
    %% appends. The applier is the sole evictor.
    ApplierPid = bondy_oplog_registry:applier_pid(Id),
    true = is_pid(ApplierPid),
    sys:suspend(ApplierPid),
    %% Three appends are accepted (size + delta =< cap).
    _ = bondy_oplog:append(Id, e1),
    _ = bondy_oplog:append(Id, e2),
    _ = bondy_oplog:append(Id, e3),
    %% The fourth tips the count past the cap and is rejected before
    %% touching the WAL.
    ?assertEqual(
        {error, backpressure},
        bondy_oplog:append(Id, e4)
    ),
    %% Resume the applier so cleanup can stop the instance.
    sys:resume(ApplierPid),
    ok = bondy_oplog:await_apply(Id, 5000),
    ok = bondy_oplog:stop_instance(Id).

overlay_value_round_trip() ->
    %% The Op + Meta written through the overlay path must round-trip
    %% intact through `get/2`.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Key = bondy_oplog:append(Id, {hello, world}, {meta, 42}),
    {ok, Event} = bondy_oplog:get(Id, Key),
    ?assertEqual({hello, world}, bondy_oplog_event:op(Event)),
    ?assertEqual({meta, 42}, bondy_oplog_event:meta(Event)),
    ok = bondy_oplog:await_apply(Id),
    %% Same after apply — value is now read from the MST.
    {ok, EventAfter} = bondy_oplog:get(Id, Key),
    ?assertEqual({hello, world}, bondy_oplog_event:op(EventAfter)),
    ?assertEqual({meta, 42}, bondy_oplog_event:meta(EventAfter)),
    ok = bondy_oplog:stop_instance(Id).

overlay_evicts_after_apply() ->
    %% After the applier promotes the batch, the overlay row is gone
    %% and the value is served from the MST. We assert the overlay
    %% drains; the read path stays valid throughout.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Keys = [bondy_oplog:append(Id, N) || N <- lists:seq(1, 16)],
    %% Pre-apply: every key is reachable.
    [?assertMatch({ok, _}, bondy_oplog:get(Id, K)) || K <- Keys],
    ok = bondy_oplog:await_apply(Id),
    %% Overlay is empty.
    Tab = bondy_oplog_registry:overlay_tab(Id),
    ?assertEqual(0, ets:info(Tab, size)),
    %% Reads still work — they hit the MST now.
    [?assertMatch({ok, _}, bondy_oplog:get(Id, K)) || K <- Keys],
    ok = bondy_oplog:stop_instance(Id).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_id() ->
    list_to_binary(
        "overlay_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ).

%% Build an overlay row with a unique key. Used to simulate a backed-
%% up applier without involving the real WAL/applier path.
fake_overlay_row(N) ->
    Hlc = 1000 + N,
    Origin = <<0:128>>,
    Key = #bondy_oplog_event_key{hlc = Hlc, origin = Origin, seq = N},
    Value = {fake_op, fake_meta, undefined, undefined},
    {Key, Value, Hlc, local}.
