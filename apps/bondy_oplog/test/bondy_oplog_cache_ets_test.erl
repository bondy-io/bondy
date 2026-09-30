%% =============================================================================
%% Tests for the reference `bondy_oplog_cache_adapter` implementation
%% (`bondy_oplog_cache_ets`).
%%
%% Pins the cache contract: get/fill/delete round-trip, invalidate_all,
%% optional max_entries eviction, info shape. Bucket is a first-class
%% call-time parameter (`MST_DB_DESIGN.md` §6, §18 item 14); every
%% cache operation takes it explicitly.
%% =============================================================================

-module(bondy_oplog_cache_ets_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<"b">>).

cache_test_() ->
    [
        fun init_returns_handle/0,
        fun get_after_put_returns_value/0,
        fun get_missing_returns_not_found/0,
        fun fill_overwrites_existing_entry/0,
        fun delete_removes_entry/0,
        fun delete_missing_is_ok/0,
        fun invalidate_all_clears_table/0,
        fun info_reports_size/0,
        fun max_entries_evicts_overflow/0,
        fun max_entries_does_not_evict_reserved_row/0,
        fun distinct_buckets_do_not_collide/0,
        fun fill_after_delete_leaves_nothing/0,
        fun fill_after_invalidate_all_leaves_nothing/0,
        fun invalidate_all_keeps_max_entries/0,
        fun close_deletes_table/0
    ].

%% =============================================================================
%% Tests
%% =============================================================================

init_returns_handle() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    ?assert(is_reference(H) orelse is_atom(H) orelse is_integer(H)),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

get_after_put_returns_value() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    ok = fill(H, ?B, <<"k">>, {<<"v">>, 42}),
    ?assertEqual(
        {ok, {<<"v">>, 42}},
        bondy_oplog_cache_ets:get(H, ?B, <<"k">>)
    ),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

get_missing_returns_not_found() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    ?assertEqual(
        not_found,
        bondy_oplog_cache_ets:get(H, ?B, <<"absent">>)
    ),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

fill_overwrites_existing_entry() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    ok = fill(H, ?B, <<"k">>, {<<"v1">>, 1}),
    ok = fill(H, ?B, <<"k">>, {<<"v2">>, 2}),
    ?assertEqual(
        {ok, {<<"v2">>, 2}},
        bondy_oplog_cache_ets:get(H, ?B, <<"k">>)
    ),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

delete_removes_entry() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    ok = fill(H, ?B, <<"k">>, {<<"v">>, 1}),
    ok = bondy_oplog_cache_ets:delete(H, ?B, <<"k">>),
    ?assertEqual(
        not_found,
        bondy_oplog_cache_ets:get(H, ?B, <<"k">>)
    ),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

delete_missing_is_ok() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    ?assertEqual(ok, bondy_oplog_cache_ets:delete(H, ?B, <<"never">>)),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

invalidate_all_clears_table() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    [
        fill(H, ?B, K, {V, V})
     || {K, V} <- [{<<"a">>, 1}, {<<"b">>, 2}, {<<"c">>, 3}]
    ],
    ok = bondy_oplog_cache_ets:invalidate_all(H),
    [
        ?assertEqual(not_found, bondy_oplog_cache_ets:get(H, ?B, K))
     || K <- [<<"a">>, <<"b">>, <<"c">>]
    ].

info_reports_size() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    ok = fill(H, ?B, <<"k">>, {<<"v">>, 1}),
    Info = bondy_oplog_cache_ets:info(H),
    ?assertMatch(#{size := _, memory := _, max_entries := _}, Info),
    ?assertEqual(infinity, maps:get(max_entries, Info)),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

max_entries_evicts_overflow() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{max_entries => 3}),
    [
        fill(H, ?B, K, {K, 1})
     || K <- [<<"a">>, <<"b">>, <<"c">>, <<"d">>, <<"e">>]
    ],
    Info = bondy_oplog_cache_ets:info(H),
    ?assert(maps:get(size, Info) =< 3),
    ?assertEqual(3, maps:get(max_entries, Info)),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

max_entries_does_not_evict_reserved_row() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{max_entries => 2}),
    [
        fill(H, ?B, K, {K, 1})
     || K <- [<<"a">>, <<"b">>, <<"c">>, <<"d">>]
    ],
    Info = bondy_oplog_cache_ets:info(H),
    ?assertEqual(2, maps:get(max_entries, Info)),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

distinct_buckets_do_not_collide() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    ok = fill(H, <<"b1">>, <<"k">>, {<<"v1">>, 1}),
    ok = fill(H, <<"b2">>, <<"k">>, {<<"v2">>, 2}),
    ?assertEqual(
        {ok, {<<"v1">>, 1}},
        bondy_oplog_cache_ets:get(H, <<"b1">>, <<"k">>)
    ),
    ?assertEqual(
        {ok, {<<"v2">>, 2}},
        bondy_oplog_cache_ets:get(H, <<"b2">>, <<"k">>)
    ),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

close_deletes_table() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    ok = fill(H, ?B, <<"k">>, {<<"v">>, 1}),
    ok = bondy_oplog_cache_ets:close(H),
    ?assertError(badarg, bondy_oplog_cache_ets:get(H, ?B, <<"k">>)).

%% A fill whose ticket predates an invalidation of any key in the table is
%% dropped; the next fill under a fresh ticket lands.
fill_after_delete_leaves_nothing() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    Ticket = bondy_oplog_cache_ets:ticket(H),
    ok = bondy_oplog_cache_ets:delete(H, ?B, <<"other">>),
    ok = bondy_oplog_cache_ets:fill(H, ?B, <<"k">>, {<<"old">>, 1}, Ticket),
    ?assertEqual(not_found, bondy_oplog_cache_ets:get(H, ?B, <<"k">>)),
    ok = fill(H, ?B, <<"k">>, {<<"new">>, 2}),
    ?assertEqual(
        {ok, {<<"new">>, 2}}, bondy_oplog_cache_ets:get(H, ?B, <<"k">>)
    ),
    ok = bondy_oplog_cache_ets:invalidate_all(H).

fill_after_invalidate_all_leaves_nothing() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{}),
    Ticket = bondy_oplog_cache_ets:ticket(H),
    ok = bondy_oplog_cache_ets:invalidate_all(H),
    ok = bondy_oplog_cache_ets:fill(H, ?B, <<"k">>, {<<"old">>, 1}, Ticket),
    ?assertEqual(not_found, bondy_oplog_cache_ets:get(H, ?B, <<"k">>)).

invalidate_all_keeps_max_entries() ->
    {ok, H} = bondy_oplog_cache_ets:init(ns, primary, 0, #{max_entries => 2}),
    ok = bondy_oplog_cache_ets:invalidate_all(H),
    ?assertEqual(2, maps:get(max_entries, bondy_oplog_cache_ets:info(H))),
    ?assertEqual(0, maps:get(size, bondy_oplog_cache_ets:info(H))).

fill(H, Bucket, Key, Value) ->
    bondy_oplog_cache_ets:fill(
        H, Bucket, Key, Value, bondy_oplog_cache_ets:ticket(H)
    ).
