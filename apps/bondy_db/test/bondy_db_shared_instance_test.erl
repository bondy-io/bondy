%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Proves the one-log-per-shard collapse on the production `core` topology
%% (`bondy_db_topology_shared_shards`, `instances_strategy => per_shard`): every
%% table on a shard shares ONE `bondy_oplog` instance (one WAL + MST + applier),
%% distinguished by the entity-type `Bucket` each event carries. Two tables on
%% the same DB must:
%%
%%   1. project independently (no cross-table contamination), even for an
%%      identical `(Realm, Key)`;
%%   2. resolve to exactly `shard_count` instances total — `DbName/Shard`, NOT
%%      `DbName/EntityType/Shard` — not `tables × shards`;
%%   3. keep the shared instance alive while any sibling table still references
%%      it (refcounted teardown), and stop it only once the last table closes.
%% =============================================================================
-module(bondy_db_shared_instance_test).

-include_lib("eunit/include/eunit.hrl").

-define(TOPOLOGY, bondy_db_topology_shared_shards).
-define(SHARDS, 4).
-define(DB, shared_inst_db).

shared_instance_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        gen("one_instance_per_shard", fun one_instance_per_shard/1),
        gen("independent_projections", fun independent_projections/1),
        gen("refcounted_teardown", fun refcounted_teardown/1),
        gen(
            "compaction_preserves_all_tables",
            fun compaction_preserves_all_tables/1
        )
    ]}.

gen(Title, Fn) ->
    fun(Ctx) -> {Title, {timeout, 60, fun() -> Fn(Ctx) end}} end.

setup() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = make_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(?DB, #{
        topology => ?TOPOLOGY,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => ?SHARDS,
        fold_module => lww_register
    }),
    {ok, Users} = bondy_db:open_table(Db, users, #{}),
    {ok, Groups} = bondy_db:open_table(Db, groups, #{}),
    {Db, Users, Groups, Sup, Dir}.

cleanup({Db, _U, _G, Sup, Dir}) ->
    _ = catch bondy_db:close(Db),
    _ = [
        catch bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    case is_process_alive(Sup) of
        true -> _ = catch bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    rmrf(wal_dir()),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% Two tables, `shard_count` shards ⇒ exactly `shard_count` shared instances,
%% each named `DbName/Shard` — NOT `tables × shards`, and NOT carrying the
%% entity type in the id.
one_instance_per_shard({_Db, Users, Groups, _Sup, _Dir}) ->
    %% Touch every shard from both tables so all shard instances are founded
    %% (the first table founds, the second joins) before we count.
    Keys = [key(I) || I <- lists:seq(1, 40)],
    [put_cell(Users, <<"r1">>, K, <<"u">>) || K <- Keys],
    [put_cell(Groups, <<"r1">>, K, <<"g">>) || K <- Keys],

    Instances = lists:sort(db_instances()),
    Expected = lists:sort([instance_id(S) || S <- lists:seq(0, ?SHARDS - 1)]),
    ?assertEqual(Expected, Instances),
    %% No per-table (entity-type-bearing) instance id leaked through.
    ?assertEqual(
        [],
        [I || I <- Instances, binary:match(I, <<"/users/">>) =/= nomatch]
    ),
    ?assertEqual(
        [],
        [I || I <- Instances, binary:match(I, <<"/groups/">>) =/= nomatch]
    ).

%% An identical `(Realm, Key)` written to both tables holds independent state —
%% the shared instance routes each event to its own table's projection by
%% bucket.
independent_projections({_Db, Users, Groups, _Sup, _Dir}) ->
    Realm = <<"r1">>,
    Key = <<"shared_key">>,
    put_cell(Users, Realm, Key, <<"user_value">>),
    put_cell(Groups, Realm, Key, <<"group_value">>),
    ?assertMatch({ok, {<<"user_value">>, _}}, bondy_db:read(Users, Realm, Key)),
    ?assertMatch(
        {ok, {<<"group_value">>, _}}, bondy_db:read(Groups, Realm, Key)
    ),
    %% The other table never sees this one's value for a key it did not write.
    put_cell(Users, Realm, <<"only_user">>, <<"uv">>),
    ?assertEqual(
        {error, not_found}, bondy_db:read(Groups, Realm, <<"only_user">>)
    ).

%% Closing one table leaves the sibling fully working AND keeps the shared
%% instances up (refcount > 0); closing the last table stops them.
refcounted_teardown({_Db, Users, Groups, _Sup, _Dir}) ->
    Keys = [key(I) || I <- lists:seq(1, 40)],
    [put_cell(Users, <<"r1">>, K, <<"u">>) || K <- Keys],
    [put_cell(Groups, <<"r1">>, K, <<"g">>) || K <- Keys],
    ?assertEqual(?SHARDS, length(db_instances())),

    %% Drop `users`: its sibling `groups` still shares the instances, so they
    %% must stay up.
    ok = bondy_db:close_table(Users),
    ?assertEqual(?SHARDS, length(db_instances())),

    %% `groups` is unaffected — reads and writes still work.
    ?assertMatch({ok, {<<"g">>, _}}, bondy_db:read(Groups, <<"r1">>, key(1))),
    put_cell(Groups, <<"r1">>, <<"post_close">>, <<"still_ok">>),
    ?assertMatch(
        {ok, {<<"still_ok">>, _}},
        bondy_db:read(Groups, <<"r1">>, <<"post_close">>)
    ),

    %% Drop the last table: the shared instances now stop.
    ok = bondy_db:close_table(Groups),
    ?assertEqual([], db_instances()).

%% Compacting the shared per-shard MST must not lose either table's cells: the
%% truncate bounds the one MST that holds BOTH tables' events, and each table's
%% durable projection still answers reads. Drives `compact/2` with each shard
%% instance's own root as the sole peer root, so the stability frontier confirms
%% the whole tree and the truncate bounds it maximally.
compaction_preserves_all_tables({_Db, Users, Groups, _Sup, _Dir}) ->
    Keys = [key(I) || I <- lists:seq(1, 40)],
    [put_cell(Users, <<"r1">>, K, <<K/binary, "/u">>) || K <- Keys],
    [put_cell(Groups, <<"r1">>, K, <<K/binary, "/g">>) || K <- Keys],

    %% Compact every shard instance against its own root.
    lists:foreach(
        fun(InstanceId) ->
            Root = bondy_oplog_instance:root_hash(InstanceId),
            ?assertMatch(
                {ok, {compacted, _, _}},
                bondy_oplog_instance:compact(InstanceId, [Root])
            )
        end,
        db_instances()
    ),

    %% Both tables' cells survive — read from the durable projection.
    lists:foreach(
        fun(K) ->
            ?assertEqual(
                {ok, {<<K/binary, "/u">>, ignore}}, ok_kv(Users, <<"r1">>, K)
            ),
            ?assertEqual(
                {ok, {<<K/binary, "/g">>, ignore}}, ok_kv(Groups, <<"r1">>, K)
            )
        end,
        Keys
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

%% `read/3` with the Hlc projected away, so a per-key assertion can compare just
%% the value (the macro cannot bind `_` inside the expected tuple).
ok_kv(Table, Realm, Key) ->
    case bondy_db:read(Table, Realm, Key) of
        {ok, {V, _Hlc}} -> {ok, {V, ignore}};
        Other -> Other
    end.

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

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_shared_instance_test",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

wal_dir() ->
    filename:join([
        "/tmp", "bondy_oplog_wal", os:getpid(), atom_to_list(?DB)
    ]).

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
