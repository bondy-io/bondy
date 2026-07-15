%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end test for the Two-Phase Set CRDT through the public
%% `bondy_db` facade (ephemeral memory topology — no leveled/disk). Proves
%% the type wires through the cell kernel + applier + projection + read,
%% and that the defining 2P-Set semantics hold: removal is permanent.

-module(bondy_db_two_p_set_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_two_p_set).

two_p_set_e2e_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            {ok, Db} = bondy_db:open(two_p_set_db, #{
                topology => bondy_db_topology_memory,
                shard_count => 1,
                %% `fold_module` is a required registry field; `crdt_module`
                %% takes precedence at runtime (both have
                %% value_equals_state == false, so the read-path value
                %% decoder agrees).
                fold_module => lww_register,
                crdt_module => ?CRDT
            }),
            Db
        end,
        fun(Db) -> ok = bondy_db:close(Db) end, fun(Db) ->
            [
                {"info reports crdt_module", fun() -> info(Db) end},
                {"add then read", fun() -> add_read(Db) end},
                {"remove is permanent", fun() -> remove_permanent(Db) end}
            ]
        end}.

info(Db) ->
    {ok, T} = bondy_db:open_table(Db, t_info, #{}),
    ?assertEqual(?CRDT, maps:get(crdt_module, bondy_db:info(T))),
    ?assertEqual(tier_0, ?CRDT:causal_tier()),
    ok = bondy_db:close_table(T).

add_read(Db) ->
    {ok, T} = bondy_db:open_table(Db, t_add, #{}),
    ok = bondy_db:apply(T, <<"r1">>, <<"s">>, {add, <<"x">>}),
    ok = bondy_db:apply(T, <<"r1">>, <<"s">>, {add, <<"y">>}),
    {ok, {V, _Hlc}} = bondy_db:read(T, <<"r1">>, <<"s">>),
    ?assertEqual([<<"x">>, <<"y">>], lists:sort(V)),
    ok = bondy_db:close_table(T).

remove_permanent(Db) ->
    {ok, T} = bondy_db:open_table(Db, t_rm, #{}),
    ok = bondy_db:apply(T, <<"r1">>, <<"s">>, {add, <<"x">>}),
    ok = bondy_db:apply(T, <<"r1">>, <<"s">>, {add, <<"y">>}),
    ok = bondy_db:apply(T, <<"r1">>, <<"s">>, {rmv, <<"x">>}),
    {ok, {V1, _}} = bondy_db:read(T, <<"r1">>, <<"s">>),
    ?assertEqual([<<"y">>], V1),
    %% Re-adding a removed element must NOT bring it back — the defining
    %% 2P-Set property, verified through the real projection round-trip.
    ok = bondy_db:apply(T, <<"r1">>, <<"s">>, {add, <<"x">>}),
    {ok, {V2, _}} = bondy_db:read(T, <<"r1">>, <<"s">>),
    ?assertEqual([<<"y">>], V2),
    ok = bondy_db:close_table(T).
