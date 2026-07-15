%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end test for the Add-Wins Set CRDT through the public `bondy_db`
%% facade (ephemeral memory topology). Proves the tier_2 type wires through
%% the cell kernel + applier + projection + read, including the substrate's
%% per-write **causal-context stamp** (the applier stamps `context_of/1`
%% into each write's meta): a remove observes the prior add's dot and drops
%% it, and — unlike the tier_0 2P-Set — a later add brings the element back.

-module(bondy_db_aw_set_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_aw_set).

aw_set_e2e_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            {ok, Db} = bondy_db:open(aw_set_db, #{
                topology => bondy_db_topology_memory,
                shard_count => 1,
                fold_module => lww_register,
                crdt_module => ?CRDT
            }),
            Db
        end,
        fun(Db) -> ok = bondy_db:close(Db) end, fun(Db) ->
            [
                {"tier_2 + crdt_module reported", fun() -> info(Db) end},
                {"add / remove / re-add", fun() -> add_rmv_readd(Db) end}
            ]
        end}.

info(Db) ->
    {ok, T} = bondy_db:open_table(Db, t_info, #{}),
    ?assertEqual(?CRDT, maps:get(crdt_module, bondy_db:info(T))),
    ?assertEqual(tier_2, ?CRDT:causal_tier()),
    ok = bondy_db:close_table(T).

add_rmv_readd(Db) ->
    {ok, T} = bondy_db:open_table(Db, t_set, #{}),
    ok = bondy_db:apply(T, <<"r1">>, <<"s">>, {add, <<"x">>}),
    ok = bondy_db:apply(T, <<"r1">>, <<"s">>, {add, <<"y">>}),
    {ok, {V0, _}} = bondy_db:read(T, <<"r1">>, <<"s">>),
    ?assertEqual([<<"x">>, <<"y">>], lists:sort(V0)),
    %% Remove observes x's dot (the applier stamped the cell's context) and
    %% drops it.
    ok = bondy_db:apply(T, <<"r1">>, <<"s">>, {rmv, <<"x">>}),
    {ok, {V1, _}} = bondy_db:read(T, <<"r1">>, <<"s">>),
    ?assertEqual([<<"y">>], V1),
    %% A later add brings x back — the add-wins difference from a 2P-Set.
    ok = bondy_db:apply(T, <<"r1">>, <<"s">>, {add, <<"x">>}),
    {ok, {V2, _}} = bondy_db:read(T, <<"r1">>, <<"s">>),
    ?assertEqual([<<"x">>, <<"y">>], lists:sort(V2)),
    ok = bondy_db:close_table(T).
