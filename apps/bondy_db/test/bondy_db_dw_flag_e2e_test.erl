%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end test for the Disable-Wins Flag through the public `bondy_db`
%% facade (ephemeral memory topology). Proves the tier_2 flag wires through
%% the cell kernel + applier + projection + read. The disable-wins
%% *concurrency* resolution is exercised exhaustively by
%% `bondy_oplog_crdt_dw_flag_proper_test`.

-module(bondy_db_dw_flag_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_dw_flag).

dw_flag_e2e_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            {ok, Db} = bondy_db:open(dw_flag_db, #{
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
                {"enable / disable / re-enable", fun() -> toggle(Db) end}
            ]
        end}.

info(Db) ->
    {ok, T} = bondy_db:open_table(Db, t_info, #{}),
    ?assertEqual(?CRDT, maps:get(crdt_module, bondy_db:info(T))),
    ?assertEqual(tier_2, ?CRDT:causal_tier()),
    ok = bondy_db:close_table(T).

toggle(Db) ->
    {ok, T} = bondy_db:open_table(Db, t_flag, #{}),
    ?assertEqual({error, not_found}, bondy_db:read(T, <<"r1">>, <<"f">>)),
    ok = bondy_db:apply(T, <<"r1">>, <<"f">>, enable),
    ?assertEqual(true, read_value(T, <<"f">>)),
    %% A disable observes the prior enable and clears the flag.
    ok = bondy_db:apply(T, <<"r1">>, <<"f">>, disable),
    ?assertEqual(false, read_value(T, <<"f">>)),
    %% A later enable observed the disable, so it survives — flag true.
    ok = bondy_db:apply(T, <<"r1">>, <<"f">>, enable),
    ?assertEqual(true, read_value(T, <<"f">>)),
    ok = bondy_db:close_table(T).

read_value(T, Key) ->
    {ok, {V, _Hlc}} = bondy_db:read(T, <<"r1">>, Key),
    V.
