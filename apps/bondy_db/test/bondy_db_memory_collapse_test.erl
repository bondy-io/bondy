%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Proves the one-log-per-shard collapse on the ephemeral `memory` topology
%% (`bondy_db_topology_memory`, `instances_strategy => per_shard`) — the backing
%% for the registry DB. Every table on a shard shares ONE fused `bondy_oplog`
%% instance (one in-RAM WAL + MST + inline drain), distinguished by the
%% entity-type `Bucket` each event carries (the realm is folded into the cell
%% key instead). The per-`(EntityType, Shard)` ETS projections stay separate, so
%% two tables on the same DB must:
%%
%%   1. resolve to exactly `shard_count` instances total — `DbName/Shard`, NOT
%%      `DbName/EntityType/Shard` — not `tables × shards`;
%%   2. project independently (no cross-table contamination) for an identical
%%      `(Realm, Key)`, the shared instance routing each event to its own
%%      table's ETS by bucket;
%%   3. keep the shared instance alive while any sibling table still references
%%      it (refcounted teardown), stopping it only once the last table closes.
%% =============================================================================
-module(bondy_db_memory_collapse_test).

-include_lib("eunit/include/eunit.hrl").

-define(TOPOLOGY, bondy_db_topology_memory).
-define(SHARDS, 4).
-define(DB, mem_collapse_db).

memory_collapse_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        gen("one_instance_per_shard", fun one_instance_per_shard/1),
        gen("independent_projections", fun independent_projections/1),
        gen("refcounted_teardown", fun refcounted_teardown/1)
    ]}.

gen(Title, Fn) ->
    fun(Ctx) -> {Title, {timeout, 60, fun() -> Fn(Ctx) end}} end.

setup() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    {ok, Db} = bondy_db:open(?DB, #{
        topology => ?TOPOLOGY,
        shard_count => ?SHARDS,
        fold_module => lww_register
    }),
    {ok, Users} = bondy_db:open_table(Db, users, #{fold_module => lww_register}),
    {ok, Groups} = bondy_db:open_table(Db, groups, #{
        fold_module => lww_register
    }),
    {Db, Users, Groups}.

cleanup({Db, _U, _G}) ->
    _ =
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end,
    _ = [
        try
            bondy_oplog:stop_instance(I)
        catch
            _:_ -> ok
        end
     || I <- bondy_oplog:list_instances()
    ],
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% Two tables, `shard_count` shards ⇒ exactly `shard_count` fused instances,
%% each named `DbName/Shard` — NOT `tables × shards`, and NOT entity-type-bearing.
one_instance_per_shard({_Db, Users, Groups}) ->
    Keys = [key(I) || I <- lists:seq(1, 40)],
    [put_cell(Users, <<"r1">>, K, <<"u">>) || K <- Keys],
    [put_cell(Groups, <<"r1">>, K, <<"g">>) || K <- Keys],

    Instances = lists:sort(db_instances()),
    Expected = lists:sort([instance_id(S) || S <- lists:seq(0, ?SHARDS - 1)]),
    ?assertEqual(Expected, Instances),
    ?assertEqual(
        [],
        [I || I <- Instances, binary:match(I, <<"/users/">>) =/= nomatch]
    ),
    ?assertEqual(
        [],
        [I || I <- Instances, binary:match(I, <<"/groups/">>) =/= nomatch]
    ).

%% An identical `(Realm, Key)` written to both tables holds independent state —
%% the shared instance routes each event to its own table's ETS by bucket, and
%% the realm-folded key keeps two realms' same-key cells apart within a table.
independent_projections({_Db, Users, Groups}) ->
    Realm = <<"r1">>,
    Key = <<"shared_key">>,
    put_cell(Users, Realm, Key, <<"user_value">>),
    put_cell(Groups, Realm, Key, <<"group_value">>),
    ?assertMatch({ok, {<<"user_value">>, _}}, bondy_db:read(Users, Realm, Key)),
    ?assertMatch(
        {ok, {<<"group_value">>, _}}, bondy_db:read(Groups, Realm, Key)
    ),
    put_cell(Users, Realm, <<"only_user">>, <<"uv">>),
    ?assertEqual(
        {error, not_found}, bondy_db:read(Groups, Realm, <<"only_user">>)
    ),
    %% Two realms, same key, same table — realm-folding keeps them distinct.
    put_cell(Users, <<"r2">>, Key, <<"r2_value">>),
    ?assertMatch(
        {ok, {<<"user_value">>, _}}, bondy_db:read(Users, <<"r1">>, Key)
    ),
    ?assertMatch(
        {ok, {<<"r2_value">>, _}}, bondy_db:read(Users, <<"r2">>, Key)
    ).

%% Closing one table leaves the sibling working AND keeps the shared instances
%% up (refcount > 0); closing the last stops them.
refcounted_teardown({_Db, Users, Groups}) ->
    Keys = [key(I) || I <- lists:seq(1, 40)],
    [put_cell(Users, <<"r1">>, K, <<"u">>) || K <- Keys],
    [put_cell(Groups, <<"r1">>, K, <<"g">>) || K <- Keys],
    ?assertEqual(?SHARDS, length(db_instances())),

    ok = bondy_db:close_table(Users),
    ?assertEqual(?SHARDS, length(db_instances())),

    ?assertMatch({ok, {<<"g">>, _}}, bondy_db:read(Groups, <<"r1">>, key(1))),
    put_cell(Groups, <<"r1">>, <<"post_close">>, <<"still_ok">>),
    ?assertMatch(
        {ok, {<<"still_ok">>, _}},
        bondy_db:read(Groups, <<"r1">>, <<"post_close">>)
    ),

    ok = bondy_db:close_table(Groups),
    ?assertEqual([], db_instances()).

%% =============================================================================
%% Helpers
%% =============================================================================

put_cell(Table, Realm, Key, Value) ->
    ok = bondy_db:apply(Table, Realm, Key, {set, bondy_db:tick(Table), Value}).

db_instances() ->
    Prefix = <<(atom_to_binary(?DB, utf8))/binary, "/">>,
    [
        I
     || I <- bondy_oplog:list_instances(),
        binary:longest_common_prefix([I, Prefix]) =:= byte_size(Prefix)
    ].

instance_id(Shard) ->
    iolist_to_binary([
        atom_to_binary(?DB, utf8), $/, integer_to_binary(Shard)
    ]).

key(I) ->
    iolist_to_binary(io_lib:format("k~4..0b", [I])).
