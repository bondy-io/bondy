%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Proves the secondary-index-writer collapse on the production `main` topology
%% (`bondy_db_topology_shared_shards`, `instances_strategy => per_shard`): every
%% index of every table on a secondary shard shares ONE
%% `bondy_oplog_secondary_writer`, demuxing the dispatched ops back to each
%% `(NS, IndexName)` stream — the secondary-side mirror of the per-shard primary
%% instance, which multiplexes tables by entity-type bucket.
%%
%% Two tables, each with an index, on the same DB must:
%%
%%   1. resolve to exactly `sec_shard_count` writers total — one per
%%      `(DbName, SecShard)` — NOT `indexes × sec_shards`; both tables' index
%%      shard-N entries point at the same writer pid;
%%   2. project each index independently (no cross-stream contamination), with
%%      the shared writer routing each stream to its own projection;
%%   3. keep the shared writer alive while any index shard still references its
%%      `writer_key` (refcounted teardown), stopping it only once the last one
%%      closes.
%% =============================================================================
-module(bondy_db_shared_writer_test).

-include_lib("eunit/include/eunit.hrl").

-define(TOPOLOGY, bondy_db_topology_shared_shards).
-define(SHARDS, 4).
-define(DB, shared_writer_db).

shared_writer_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        gen("one_writer_per_secshard", fun one_writer_per_secshard/1),
        gen(
            "independent_index_projections",
            fun independent_index_projections/1
        ),
        gen("refcounted_writer_teardown", fun refcounted_writer_teardown/1)
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
    {ok, Users} = bondy_db:open_table(Db, users, #{
        fold_module => lww_register,
        indexes => [#{name => by_value, extract => []}]
    }),
    {ok, Groups} = bondy_db:open_table(Db, groups, #{
        fold_module => lww_register,
        indexes => [#{name => by_value, extract => []}]
    }),
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

%% Two tables, each with an index ⇒ exactly `sec_shard_count` writers, one per
%% secondary shard, shared across BOTH tables — not `indexes × sec_shards`. Both
%% tables' shard-N index entries resolve to the same writer pid.
one_writer_per_secshard({_Db, Users, Groups, _Sup, _Dir}) ->
    populate(Users, <<"u">>),
    populate(Groups, <<"g">>),
    ok = flush_index(Users, by_value),
    ok = flush_index(Groups, by_value),

    UserPids = writer_pids(Users, by_value),
    GroupPids = writer_pids(Groups, by_value),

    %% Each table's index spans `sec_shard_count` shards.
    ?assertEqual(?SHARDS, map_size(UserPids)),
    ?assertEqual(?SHARDS, map_size(GroupPids)),

    %% Shard-by-shard, both tables' index writers are the SAME process.
    lists:foreach(
        fun(Shard) ->
            ?assertEqual(
                maps:get(Shard, UserPids), maps:get(Shard, GroupPids)
            )
        end,
        lists:seq(0, ?SHARDS - 1)
    ),

    %% The whole DB has exactly `sec_shard_count` distinct index writers.
    Distinct = lists:usort(
        maps:values(UserPids) ++ maps:values(GroupPids)
    ),
    ?assertEqual(?SHARDS, length(Distinct)),
    ?assert(lists:all(fun erlang:is_process_alive/1, Distinct)).

%% Both indexes answer correctly and independently — the shared writer routes
%% each `(NS, IndexName)` stream to its own projection, with no cross-stream
%% contamination, even for an identical `(Realm, Key, Term)`.
independent_index_projections({_Db, Users, Groups, _Sup, _Dir}) ->
    R = <<"r1">>,
    %% Same key, same indexed term in both tables.
    ok = bondy_db:apply(
        Users, R, <<"k1">>, {set, bondy_db:tick(Users), <<"x">>}
    ),
    ok = bondy_db:apply(
        Groups, R, <<"k1">>, {set, bondy_db:tick(Groups), <<"x">>}
    ),
    %% A term only one table holds.
    ok = bondy_db:apply(
        Users, R, <<"k2">>, {set, bondy_db:tick(Users), <<"only_users">>}
    ),
    ok = flush_index(Users, by_value),
    ok = flush_index(Groups, by_value),

    %% The shared term resolves to each table's OWN key, not the sibling's.
    ?assertEqual(
        {ok, [{<<"k1">>, #{}}]},
        bondy_db:index_get(Users, R, by_value, <<"x">>, #{})
    ),
    ?assertEqual(
        {ok, [{<<"k1">>, #{}}]},
        bondy_db:index_get(Groups, R, by_value, <<"x">>, #{})
    ),
    %% The users-only term is absent from the groups index stream.
    ?assertEqual(
        {ok, [{<<"k2">>, #{}}]},
        bondy_db:index_get(Users, R, by_value, <<"only_users">>, #{})
    ),
    ?assertEqual(
        {ok, []},
        bondy_db:index_get(Groups, R, by_value, <<"only_users">>, #{})
    ).

%% Closing one table leaves its sibling's index fully working AND keeps the
%% shared writers up (a sibling index shard still references each `writer_key`);
%% closing the last table stops them.
refcounted_writer_teardown({_Db, Users, Groups, _Sup, _Dir}) ->
    populate(Users, <<"u">>),
    populate(Groups, <<"g">>),
    ok = flush_index(Users, by_value),
    ok = flush_index(Groups, by_value),

    Shared = lists:usort(maps:values(writer_pids(Groups, by_value))),
    ?assertEqual(?SHARDS, length(Shared)),
    ?assert(lists:all(fun erlang:is_process_alive/1, Shared)),

    %% Drop `users`: `groups`' index shards still reference every writer_key,
    %% so the shared writers must stay up.
    ok = bondy_db:close_table(Users),
    ?assert(lists:all(fun erlang:is_process_alive/1, Shared)),

    %% `groups`' index is unaffected — a fresh write still indexes.
    ok = bondy_db:apply(
        Groups,
        <<"r1">>,
        <<"post_close">>,
        {set, bondy_db:tick(Groups), <<"pc">>}
    ),
    ok = flush_index(Groups, by_value),
    ?assertEqual(
        {ok, [{<<"post_close">>, #{}}]},
        bondy_db:index_get(Groups, <<"r1">>, by_value, <<"pc">>, #{})
    ),
    %% The writer pids are unchanged (same shared processes serving `groups`).
    ?assertEqual(
        Shared, lists:usort(maps:values(writer_pids(Groups, by_value)))
    ),

    %% Drop the last table: nothing references the writer_keys now, so the
    %% shared writers stop.
    ok = bondy_db:close_table(Groups),
    ok = wait_until(
        fun() -> lists:all(fun(P) -> not is_process_alive(P) end, Shared) end,
        50
    ),
    ?assert(lists:all(fun(P) -> not is_process_alive(P) end, Shared)).

%% =============================================================================
%% Helpers
%% =============================================================================

populate(Table, Tag) ->
    R = <<"r1">>,
    lists:foreach(
        fun(I) ->
            K = key(I),
            V = <<Tag/binary, "/", K/binary>>,
            ok = bondy_db:apply(Table, R, K, {set, bondy_db:tick(Table), V})
        end,
        lists:seq(1, 40)
    ).

%% `#{Shard => WriterPid}` for an index, read off each shard's registry row.
writer_pids(Table, IndexName) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    maps:from_list([
        begin
            {ok, Entry} = bondy_oplog_core_registry:lookup(
                NS, IndexName, Shard
            ),
            Pid = bondy_oplog_core_registry:entry_writer_pid(Entry),
            true = is_pid(Pid),
            {Shard, Pid}
        end
     || Shard <- lists:seq(0, N - 1)
    ]).

flush_index(Table, IndexName) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    lists:foreach(
        fun(Shard) ->
            {ok, Entry} = bondy_oplog_core_registry:lookup(
                NS, IndexName, Shard
            ),
            Pid = bondy_oplog_core_registry:entry_writer_pid(Entry),
            true = is_pid(Pid),
            ok = bondy_oplog_secondary_writer:flush_sync(Pid)
        end,
        lists:seq(0, N - 1)
    ).

wait_until(_Pred, 0) ->
    timeout;
wait_until(Pred, N) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(10),
            wait_until(Pred, N - 1)
    end.

key(I) ->
    iolist_to_binary(io_lib:format("k~4..0b", [I])).

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_shared_writer_test",
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
