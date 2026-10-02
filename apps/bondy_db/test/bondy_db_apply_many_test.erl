%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Proves `bondy_db:apply_many/1`, the atomic multi-entity batch facade: a list
%% of `{Table, Realm, Key, Event}` writes spanning several tables of one DB is
%% grouped by shard and each shard's group is appended as ONE atomic WAL frame.
%%
%%   - With `shard_count => 1` every write lands on the one shard ⇒ one frame ⇒
%%     fully atomic across the entities (the co-located-aggregate payoff). All
%%     three tables' cells must be readable the moment `apply_many/1` returns.
%%   - With `shard_count => 4` a batch fanning across shards commits one atomic
%%     frame per shard; every write is still visible afterwards (read-your-writes).
%% =============================================================================
-module(bondy_db_apply_many_test).

-include_lib("eunit/include/eunit.hrl").

-define(TOPOLOGY, bondy_db_topology_shared_shards).

apply_many_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        gen("multi_entity_single_frame", fun multi_entity_single_frame/1),
        gen(
            "cross_shard_batch_all_visible", fun cross_shard_batch_all_visible/1
        ),
        gen("empty_batch_is_ok", fun empty_batch_is_ok/1),
        gen("invalid_write_is_rejected", fun invalid_write_is_rejected/1)
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
    {Dir, Sup}.

cleanup({Dir, Sup}) ->
    _ = [
        try
            bondy_oplog:stop_instance(I)
        catch
            _:_ -> ok
        end
     || I <- bondy_oplog:list_instances()
    ],
    case is_process_alive(Sup) of
        true ->
            _ =
                try
                    bondy_db_leveled_sup:stop(Sup)
                catch
                    _:_ -> ok
                end;
        false ->
            ok
    end,
    rmrf(Dir),
    rmrf(filename:join(["/tmp", "bondy_oplog_wal", os:getpid()])),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% One shard ⇒ a batch spanning users + groups + sessions for one subject is a
%% SINGLE atomic WAL frame. After `apply_many/1` returns, every entity reads back.
multi_entity_single_frame({Dir, Sup}) ->
    {Db, [Users, Groups, Sessions]} = open_db(
        Dir, Sup, am_one, 1, [users, groups, sessions]
    ),
    Realm = <<"r1">>,
    Subject = <<"alice">>,
    ok = bondy_db:apply_many([
        {Users, Realm, Subject, set(<<"user:alice">>)},
        {Groups, Realm, Subject, set(<<"grp:alice">>)},
        {Sessions, Realm, Subject, set(<<"sess:alice">>)}
    ]),
    ?assertMatch(
        {ok, {<<"user:alice">>, _}}, bondy_db:read(Users, Realm, Subject)
    ),
    ?assertMatch(
        {ok, {<<"grp:alice">>, _}}, bondy_db:read(Groups, Realm, Subject)
    ),
    ?assertMatch(
        {ok, {<<"sess:alice">>, _}}, bondy_db:read(Sessions, Realm, Subject)
    ),
    close(Db, [Users, Groups, Sessions]).

%% A batch whose keys fan out across 4 shards commits one frame per shard; all
%% writes remain visible (read-your-writes across shards).
cross_shard_batch_all_visible({Dir, Sup}) ->
    {Db, [Users, Groups]} = open_db(Dir, Sup, am_many, 4, [users, groups]),
    Realm = <<"r1">>,
    Keys = [key(I) || I <- lists:seq(1, 40)],
    Writes =
        lists:flatmap(
            fun(K) ->
                [
                    {Users, Realm, K, set(<<K/binary, "/u">>)},
                    {Groups, Realm, K, set(<<K/binary, "/g">>)}
                ]
            end,
            Keys
        ),
    ok = bondy_db:apply_many(Writes),
    lists:foreach(
        fun(K) ->
            Eu = <<K/binary, "/u">>,
            Eg = <<K/binary, "/g">>,
            ?assertMatch({ok, {Eu, _}}, bondy_db:read(Users, Realm, K)),
            ?assertMatch({ok, {Eg, _}}, bondy_db:read(Groups, Realm, K))
        end,
        Keys
    ),
    close(Db, [Users, Groups]).

empty_batch_is_ok({Dir, Sup}) ->
    {Db, Tables} = open_db(Dir, Sup, am_empty, 1, [users]),
    ?assertEqual(ok, bondy_db:apply_many([])),
    close(Db, Tables).

invalid_write_is_rejected({Dir, Sup}) ->
    {Db, [Users] = Tables} = open_db(Dir, Sup, am_bad, 1, [users]),
    ?assertMatch(
        {error, {invalid_batch_write, _}},
        bondy_db:apply_many([{Users, <<"r1">>, not_a_binary_key, set(<<"v">>)}])
    ),
    close(Db, Tables).

%% =============================================================================
%% Helpers
%% =============================================================================

set(V) ->
    {set, V}.

open_db(Dir, Sup, DbName, ShardCount, TableNames) ->
    {ok, Db} = bondy_db:open(DbName, #{
        topology => ?TOPOLOGY,
        topology_opts => #{sup => Sup, dir => filename:join(Dir, DbName)},
        shard_count => ShardCount,
        fold_module => lww_register
    }),
    Tables = [
        begin
            {ok, T} = bondy_db:open_table(Db, Name, #{}),
            T
        end
     || Name <- TableNames
    ],
    {Db, Tables}.

close(Db, Tables) ->
    [ok = bondy_db:close_table(T) || T <- Tables],
    ok = bondy_db:close(Db).

key(I) ->
    iolist_to_binary(io_lib:format("k~4..0b", [I])).

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_apply_many_test",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

rmrf(Dir) ->
    %% An instance id names ONE directory (`<Db>-<Shard>`), so a DB's
    %% instances are SIBLINGS rather than children of `<Db>/`. Removing `Dir`
    %% alone therefore leaves their WAL behind, and the next case in the
    %% module reads the previous case's rows.
    _ = [
        file:del_dir_r(P)
     || P <- filelib:wildcard(unicode:characters_to_list(Dir) ++ "-*")
    ],
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
