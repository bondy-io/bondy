%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_oplog_catalogue_cursor_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Setup
%% =============================================================================

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

cursor_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun mint_returns_opaque_binary/0,
        fun lookup_unknown_returns_not_found/0,
        fun lookup_after_mint_returns_state/0,
        fun advance_updates_last_key/0,
        fun advance_unknown_returns_not_found/0,
        fun discard_removes_cursor/0,
        fun two_cursors_are_independent/0,
        fun cursor_distinct_per_mint/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

mint_returns_opaque_binary() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Cursor = bondy_oplog_catalogue_cursor:mint(
        InstId, NS, primary, 0, <<>>, 42
    ),
    ?assert(is_binary(Cursor)),
    ?assertEqual(16, byte_size(Cursor)),
    ok = bondy_oplog_catalogue_cursor:discard(Cursor).

lookup_unknown_returns_not_found() ->
    Bogus = crypto:strong_rand_bytes(16),
    ?assertEqual(not_found, bondy_oplog_catalogue_cursor:lookup(Bogus)).

lookup_after_mint_returns_state() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Cursor = bondy_oplog_catalogue_cursor:mint(
        InstId, NS, primary, 0, <<"bkt">>, 100
    ),
    {ok, State} = bondy_oplog_catalogue_cursor:lookup(Cursor),
    ?assertMatch(
        #{
            instance_id := InstId,
            ns := NS,
            index := primary,
            shard := 0,
            bucket := <<"bkt">>,
            last_key := undefined,
            watermark := 100
        },
        State
    ),
    ok = bondy_oplog_catalogue_cursor:discard(Cursor).

advance_updates_last_key() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Cursor = bondy_oplog_catalogue_cursor:mint(
        InstId, NS, primary, 0, <<>>, 0
    ),
    ok = bondy_oplog_catalogue_cursor:advance(Cursor, <<"k1">>),
    {ok, S1} = bondy_oplog_catalogue_cursor:lookup(Cursor),
    ?assertEqual(<<"k1">>, maps:get(last_key, S1)),
    ok = bondy_oplog_catalogue_cursor:advance(Cursor, <<"k99">>),
    {ok, S2} = bondy_oplog_catalogue_cursor:lookup(Cursor),
    ?assertEqual(<<"k99">>, maps:get(last_key, S2)),
    ok = bondy_oplog_catalogue_cursor:discard(Cursor).

advance_unknown_returns_not_found() ->
    Bogus = crypto:strong_rand_bytes(16),
    ?assertEqual(
        not_found,
        bondy_oplog_catalogue_cursor:advance(Bogus, <<"k">>)
    ).

discard_removes_cursor() ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Cursor = bondy_oplog_catalogue_cursor:mint(
        InstId, NS, primary, 0, <<>>, 0
    ),
    ?assertMatch({ok, _}, bondy_oplog_catalogue_cursor:lookup(Cursor)),
    ok = bondy_oplog_catalogue_cursor:discard(Cursor),
    ?assertEqual(not_found, bondy_oplog_catalogue_cursor:lookup(Cursor)),
    %% Discard is idempotent.
    ok = bondy_oplog_catalogue_cursor:discard(Cursor).

two_cursors_are_independent() ->
    Inst1 = mk_id(),
    Inst2 = mk_id(),
    NS1 = ns_of(Inst1),
    NS2 = ns_of(Inst2),
    C1 = bondy_oplog_catalogue_cursor:mint(Inst1, NS1, primary, 0, <<>>, 10),
    C2 = bondy_oplog_catalogue_cursor:mint(Inst2, NS2, primary, 0, <<>>, 20),
    ?assertNotEqual(C1, C2),
    ok = bondy_oplog_catalogue_cursor:advance(C1, <<"only_c1">>),
    {ok, S1} = bondy_oplog_catalogue_cursor:lookup(C1),
    {ok, S2} = bondy_oplog_catalogue_cursor:lookup(C2),
    ?assertEqual(<<"only_c1">>, maps:get(last_key, S1)),
    ?assertEqual(undefined, maps:get(last_key, S2)),
    ?assertEqual(Inst1, maps:get(instance_id, S1)),
    ?assertEqual(Inst2, maps:get(instance_id, S2)),
    ok = bondy_oplog_catalogue_cursor:discard(C1),
    ok = bondy_oplog_catalogue_cursor:discard(C2).

cursor_distinct_per_mint() ->
    %% 50 mints should yield 50 distinct cursors.
    Cursors = [
        bondy_oplog_catalogue_cursor:mint(
            mk_id(), n, primary, 0, <<>>, 0
        )
     || _ <- lists:seq(1, 50)
    ],
    ?assertEqual(50, length(lists:usort(Cursors))),
    [bondy_oplog_catalogue_cursor:discard(C) || C <- Cursors],
    ok.

%% =============================================================================
%% Helpers
%% =============================================================================

mk_id() ->
    iolist_to_binary([
        "cur_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).
