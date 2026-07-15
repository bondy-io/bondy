%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Unit tests for the generic routing multiplexer reused by the one-log-per-shard
%% collapse (the cell-apply ctx directory, and any future shared-worker member
%% directory).
%% =============================================================================
-module(bondy_oplog_mux_test).

-include_lib("eunit/include/eunit.hrl").

single_resolves_every_key_test() ->
    M = bondy_oplog_mux:single(ctx),
    ?assertEqual(ctx, bondy_oplog_mux:resolve(M, <<"a">>)),
    ?assertEqual(ctx, bondy_oplog_mux:resolve(M, <<"b">>)),
    ?assertEqual(ctx, bondy_oplog_mux:resolve(M, anything)).

dir_routes_by_key_test() ->
    M = bondy_oplog_mux:dir([{<<"a">>, 1}, {<<"b">>, 2}]),
    ?assertEqual(1, bondy_oplog_mux:resolve(M, <<"a">>)),
    ?assertEqual(2, bondy_oplog_mux:resolve(M, <<"b">>)),
    %% Absent key resolves to undefined (the "no member" signal).
    ?assertEqual(undefined, bondy_oplog_mux:resolve(M, <<"c">>)).

empty_dir_resolves_undefined_test() ->
    ?assertEqual(undefined, bondy_oplog_mux:resolve(bondy_oplog_mux:dir(), k)).

put_upgrades_seedless_single_test() ->
    %% A seedless single grows into a directory on the first put.
    M0 = bondy_oplog_mux:single(undefined),
    M1 = bondy_oplog_mux:put(M0, <<"a">>, 1),
    M2 = bondy_oplog_mux:put(M1, <<"b">>, 2),
    ?assertEqual(1, bondy_oplog_mux:resolve(M2, <<"a">>)),
    ?assertEqual(2, bondy_oplog_mux:resolve(M2, <<"b">>)).

put_into_dir_test() ->
    M = bondy_oplog_mux:put(bondy_oplog_mux:dir([{<<"a">>, 1}]), <<"b">>, 2),
    ?assertEqual(1, bondy_oplog_mux:resolve(M, <<"a">>)),
    ?assertEqual(2, bondy_oplog_mux:resolve(M, <<"b">>)).

put_on_seeded_single_errors_test() ->
    %% A single holding a founding value but no key cannot be keyed.
    ?assertError(
        put_requires_dir,
        bondy_oplog_mux:put(bondy_oplog_mux:single(ctx), <<"a">>, 1)
    ).

remove_from_dir_test() ->
    M0 = bondy_oplog_mux:dir([{<<"a">>, 1}, {<<"b">>, 2}]),
    M1 = bondy_oplog_mux:remove(M0, <<"a">>),
    ?assertEqual(undefined, bondy_oplog_mux:resolve(M1, <<"a">>)),
    ?assertEqual(2, bondy_oplog_mux:resolve(M1, <<"b">>)).

remove_from_single_is_noop_test() ->
    M = bondy_oplog_mux:single(ctx),
    ?assertEqual(M, bondy_oplog_mux:remove(M, <<"a">>)).

group_by_groups_and_preserves_order_test() ->
    Items = [{a, 1}, {b, 2}, {a, 3}, {b, 4}, {a, 5}],
    KeyOf = fun({K, _}) -> {ok, K} end,
    Groups = maps:from_list(bondy_oplog_mux:group_by(Items, KeyOf)),
    ?assertEqual([{a, 1}, {a, 3}, {a, 5}], maps:get(a, Groups)),
    ?assertEqual([{b, 2}, {b, 4}], maps:get(b, Groups)).

group_by_drops_skipped_test() ->
    Items = [keep, drop, keep, drop],
    KeyOf = fun
        (keep) -> {ok, k};
        (drop) -> skip
    end,
    ?assertEqual([{k, [keep, keep]}], bondy_oplog_mux:group_by(Items, KeyOf)).
