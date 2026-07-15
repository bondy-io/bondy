%% =============================================================================
%% Tests for the per-shard overlay ETS primitive
%% (`MST_DB_DESIGN.md` §4, wired in D2).
%%
%% Pins the key shape `{{Bucket, Key}, EventHlc, EventKey}`, the
%% HLC-windowed select helpers, the range scan, and the post-projection
%% eviction match-spec. The unit-test scope exercises the module in
%% isolation against a single default bucket (`<<>>`); cross-bucket
%% isolation is verified at the substrate level.
%% =============================================================================

-module(bondy_oplog_db_overlay_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

-define(B, <<>>).

%% =============================================================================
%% Setup / teardown
%% =============================================================================

new_table_returns_tid_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    ?assertEqual(0, bondy_oplog_db_overlay:size(Tab)),
    ok = bondy_oplog_db_overlay:delete(Tab).

%% =============================================================================
%% insert/3 + size/1
%% =============================================================================

insert_single_event_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    E = mk_event(<<"k">>, 10, <<"alice">>, 0),
    ok = bondy_oplog_db_overlay:insert(Tab, ?B, <<"k">>, E),
    ?assertEqual(1, bondy_oplog_db_overlay:size(Tab)),
    ok = bondy_oplog_db_overlay:delete(Tab).

%% =============================================================================
%% events_for/3
%% =============================================================================

events_for_returns_events_above_hlc_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    E1 = mk_event(<<"k">>, 5, <<"a">>, 0),
    E2 = mk_event(<<"k">>, 10, <<"a">>, 1),
    E3 = mk_event(<<"k">>, 15, <<"a">>, 2),
    [bondy_oplog_db_overlay:insert(Tab, ?B, <<"k">>, E) || E <- [E1, E2, E3]],
    ?assertEqual(
        [E2, E3],
        bondy_oplog_db_overlay:events_for(Tab, ?B, <<"k">>, 5)
    ),
    ?assertEqual(
        [E1, E2, E3],
        bondy_oplog_db_overlay:events_for(Tab, ?B, <<"k">>, 0)
    ),
    ?assertEqual(
        [],
        bondy_oplog_db_overlay:events_for(Tab, ?B, <<"k">>, 15)
    ),
    ok = bondy_oplog_db_overlay:delete(Tab).

events_for_isolates_by_cell_key_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    Ea = mk_event(<<"a">>, 10, <<"o">>, 0),
    Eb = mk_event(<<"b">>, 10, <<"o">>, 1),
    bondy_oplog_db_overlay:insert(Tab, ?B, <<"a">>, Ea),
    bondy_oplog_db_overlay:insert(Tab, ?B, <<"b">>, Eb),
    ?assertEqual([Ea], bondy_oplog_db_overlay:events_for(Tab, ?B, <<"a">>, 0)),
    ?assertEqual([Eb], bondy_oplog_db_overlay:events_for(Tab, ?B, <<"b">>, 0)),
    ok = bondy_oplog_db_overlay:delete(Tab).

events_for_isolates_by_bucket_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    Ea = mk_event(<<"k">>, 10, <<"o">>, 0),
    Eb = mk_event(<<"k">>, 10, <<"o">>, 1),
    bondy_oplog_db_overlay:insert(Tab, <<"b1">>, <<"k">>, Ea),
    bondy_oplog_db_overlay:insert(Tab, <<"b2">>, <<"k">>, Eb),
    ?assertEqual(
        [Ea], bondy_oplog_db_overlay:events_for(Tab, <<"b1">>, <<"k">>, 0)
    ),
    ?assertEqual(
        [Eb], bondy_oplog_db_overlay:events_for(Tab, <<"b2">>, <<"k">>, 0)
    ),
    ok = bondy_oplog_db_overlay:delete(Tab).

events_for_orders_by_hlc_then_origin_then_seq_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    %% Same HLC, different origins — must come out in origin order.
    E_b = mk_event(<<"k">>, 5, <<"b-origin">>, 0),
    E_a = mk_event(<<"k">>, 5, <<"a-origin">>, 0),
    %% Insert out of order to verify the ordered_set sort.
    bondy_oplog_db_overlay:insert(Tab, ?B, <<"k">>, E_b),
    bondy_oplog_db_overlay:insert(Tab, ?B, <<"k">>, E_a),
    ?assertEqual(
        [E_a, E_b],
        bondy_oplog_db_overlay:events_for(Tab, ?B, <<"k">>, 0)
    ),
    ok = bondy_oplog_db_overlay:delete(Tab).

%% =============================================================================
%% range/4
%% =============================================================================

range_returns_keys_in_window_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    Ea = mk_event(<<"a">>, 5, <<"o">>, 0),
    Eb = mk_event(<<"b">>, 5, <<"o">>, 1),
    Ec = mk_event(<<"c">>, 5, <<"o">>, 2),
    [
        bondy_oplog_db_overlay:insert(Tab, ?B, K, E)
     || {K, E} <- [{<<"a">>, Ea}, {<<"b">>, Eb}, {<<"c">>, Ec}]
    ],
    %% Half-open interval [a, c) — excludes c.
    ?assertEqual(
        [{<<"a">>, Ea}, {<<"b">>, Eb}],
        bondy_oplog_db_overlay:range(Tab, ?B, <<"a">>, <<"c">>, 0)
    ),
    ok = bondy_oplog_db_overlay:delete(Tab).

range_filters_by_hlc_window_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    Ea = mk_event(<<"a">>, 5, <<"o">>, 0),
    Eb = mk_event(<<"b">>, 15, <<"o">>, 1),
    bondy_oplog_db_overlay:insert(Tab, ?B, <<"a">>, Ea),
    bondy_oplog_db_overlay:insert(Tab, ?B, <<"b">>, Eb),
    %% HLC > 10 ⇒ only Eb survives.
    ?assertEqual(
        [{<<"b">>, Eb}],
        bondy_oplog_db_overlay:range(Tab, ?B, <<"a">>, <<"z">>, 10)
    ),
    ok = bondy_oplog_db_overlay:delete(Tab).

range_isolates_by_bucket_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    Ea = mk_event(<<"k">>, 5, <<"o">>, 0),
    Eb = mk_event(<<"k">>, 5, <<"o">>, 1),
    bondy_oplog_db_overlay:insert(Tab, <<"b1">>, <<"k">>, Ea),
    bondy_oplog_db_overlay:insert(Tab, <<"b2">>, <<"k">>, Eb),
    ?assertEqual(
        [{<<"k">>, Ea}],
        bondy_oplog_db_overlay:range(Tab, <<"b1">>, <<"a">>, <<"z">>, 0)
    ),
    ?assertEqual(
        [{<<"k">>, Eb}],
        bondy_oplog_db_overlay:range(Tab, <<"b2">>, <<"a">>, <<"z">>, 0)
    ),
    ok = bondy_oplog_db_overlay:delete(Tab).

%% =============================================================================
%% evict_to/3
%% =============================================================================

evict_to_removes_rows_at_or_below_watermark_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    E1 = mk_event(<<"k">>, 5, <<"o">>, 0),
    E2 = mk_event(<<"k">>, 10, <<"o">>, 1),
    E3 = mk_event(<<"k">>, 15, <<"o">>, 2),
    [bondy_oplog_db_overlay:insert(Tab, ?B, <<"k">>, E) || E <- [E1, E2, E3]],
    Watermark = bondy_oplog_event:key(E2),
    Deleted = bondy_oplog_db_overlay:evict_to(Tab, 10, Watermark),
    ?assertEqual(2, Deleted),
    ?assertEqual([E3], bondy_oplog_db_overlay:events_for(Tab, ?B, <<"k">>, 0)),
    ok = bondy_oplog_db_overlay:delete(Tab).

evict_to_preserves_higher_hlc_at_same_cell_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    E1 = mk_event(<<"k">>, 5, <<"o">>, 0),
    E2 = mk_event(<<"k">>, 100, <<"o">>, 1),
    bondy_oplog_db_overlay:insert(Tab, ?B, <<"k">>, E1),
    bondy_oplog_db_overlay:insert(Tab, ?B, <<"k">>, E2),
    Deleted = bondy_oplog_db_overlay:evict_to(
        Tab, 5, bondy_oplog_event:key(E1)
    ),
    ?assertEqual(1, Deleted),
    ?assertEqual([E2], bondy_oplog_db_overlay:events_for(Tab, ?B, <<"k">>, 0)),
    ok = bondy_oplog_db_overlay:delete(Tab).

evict_to_uses_event_key_tiebreaker_at_same_hlc_test() ->
    Tab = bondy_oplog_db_overlay:new(),
    %% Same HLC, two origins.
    Ea = mk_event(<<"k">>, 10, <<"a">>, 0),
    Eb = mk_event(<<"k">>, 10, <<"b">>, 0),
    bondy_oplog_db_overlay:insert(Tab, ?B, <<"k">>, Ea),
    bondy_oplog_db_overlay:insert(Tab, ?B, <<"k">>, Eb),
    %% Watermark = Ea ⇒ only Ea evicted; Eb survives because its
    %% event_key is greater under term order.
    Deleted = bondy_oplog_db_overlay:evict_to(
        Tab, 10, bondy_oplog_event:key(Ea)
    ),
    ?assertEqual(1, Deleted),
    ?assertEqual([Eb], bondy_oplog_db_overlay:events_for(Tab, ?B, <<"k">>, 0)),
    ok = bondy_oplog_db_overlay:delete(Tab).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_event(_CellKey, Hlc, Origin, Seq) ->
    K = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(K, {set, Hlc, <<"v">>}, undefined).
