%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% `bondy_db:close/1` closes every table still open on the DB. A table left
%% open at `close/1` must leave no `bondy_oplog_core_registry` row, no oplog
%% instance and no index writer behind: a registered index shard whose
%% projection handle is dead is restarted by `bondy_oplog_secondary_sup` from
%% the registry, crashes in `init/1`, and the restart loop takes
%% `bondy_oplog_sup` and the application down with it.

-module(bondy_db_close_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(R, <<"r1">>).
-define(INDEXES, [#{name => by_value, extract => []}]).

all() ->
    [
        close_closes_an_open_leveled_table,
        close_closes_an_open_memory_table,
        close_closes_only_the_tables_still_open,
        secondary_sup_restart_after_close_keeps_the_oplog_app_up
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok = bondy_oplog_sync_scheduler:set_dispatch(undefined),
    ok = bondy_oplog_gc_scheduler:set_trigger(undefined),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    ok = filelib:ensure_path(Dir),
    [{dir, Dir}, {baseline, baseline()} | Config].

end_per_testcase(_Case, Config) ->
    ?assertEqual(?config(baseline, Config), baseline()),
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

close_closes_an_open_leveled_table(Config) ->
    {Db, Sup} = open_leveled(close_suite_leveled, Config),
    {ok, Table} = open_table(Db, users),
    write(Table, <<"alice">>, <<"active">>),
    ok = flush_index(Table, by_value),
    Pids = live_pids(Table),
    ?assertNotEqual(?config(baseline, Config), baseline()),

    ok = bondy_db:close(Db),

    assert_closed(Table, Pids),
    ?assertNot(is_process_alive(Sup)).

close_closes_an_open_memory_table(Config) ->
    {ok, Db} = open_memory(close_suite_memory, Config),
    {ok, Table} = open_table(Db, users),
    write(Table, <<"alice">>, <<"active">>),
    ok = flush_index(Table, by_value),
    Pids = live_pids(Table),
    ?assertNotEqual(?config(baseline, Config), baseline()),

    ok = bondy_db:close(Db),

    assert_closed(Table, Pids).

%% A table closed with `close_table/1` is not closed a second time by
%% `close/1`; the table still open is.
close_closes_only_the_tables_still_open(Config) ->
    {ok, Db} = open_memory(close_suite_two_tables, Config),
    {ok, Users} = open_table(Db, users),
    {ok, Groups} = open_table(Db, groups),
    write(Users, <<"alice">>, <<"active">>),
    write(Groups, <<"admins">>, <<"active">>),
    UserPids = live_pids(Users),
    GroupPids = live_pids(Groups),

    ok = bondy_db:close_table(Users),
    ?assertNot(lists:member(namespace(Users), registered_namespaces())),
    ?assert(lists:member(namespace(Groups), registered_namespaces())),

    ok = bondy_db:close(Db),

    assert_closed(Users, UserPids),
    assert_closed(Groups, GroupPids).

secondary_sup_restart_after_close_keeps_the_oplog_app_up(Config) ->
    {Db, _Sup} = open_leveled(close_suite_restart, Config),
    {ok, Table} = open_table(Db, users),
    write(Table, <<"alice">>, <<"active">>),
    ok = flush_index(Table, by_value),
    ok = bondy_db:close(Db),
    assert_closed(Table, []),

    OplogSup = erlang:whereis(bondy_oplog_sup),
    SecSup = erlang:whereis(bondy_oplog_secondary_sup),
    Ref = erlang:monitor(process, SecSup),
    exit(SecSup, kill),
    receive
        {'DOWN', Ref, process, SecSup, killed} -> ok
    after 5000 ->
        ct:fail(secondary_sup_not_killed)
    end,
    ok = wait_until(
        fun() ->
            New = erlang:whereis(bondy_oplog_secondary_sup),
            is_pid(New) andalso New =/= SecSup
        end
    ),

    ?assertEqual(OplogSup, erlang:whereis(bondy_oplog_sup)),
    ?assert(is_process_alive(OplogSup)),
    ?assert(lists:keymember(bondy_oplog, 1, application:which_applications())),
    ?assertEqual([], index_writers_of(close_suite_restart)).

%% =============================================================================
%% HELPERS
%% =============================================================================

open_leveled(Name, Config) ->
    Dir = ?config(dir, Config),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_single_bookie,
        topology_opts => #{sup => Sup, dir => filename:join(Dir, "leveled")},
        shard_count => 1,
        fold_module => lww_register,
        oplog_instance_opts => instance_opts(Dir)
    }),
    {Db, Sup}.

open_memory(Name, Config) ->
    Dir = ?config(dir, Config),
    bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        oplog_instance_opts => instance_opts(Dir)
    }).

instance_opts(Dir) ->
    #{wal_dir => unicode:characters_to_binary(filename:join(Dir, "wal"))}.

open_table(Db, EntityType) ->
    bondy_db:open_table(Db, EntityType, #{
        fold_module => lww_register,
        indexes => ?INDEXES
    }).

write(Table, Key, Value) ->
    ok = bondy_db:apply(Table, ?R, Key, {set, bondy_db:tick(Table), Value}).

namespace(Table) ->
    maps:get(namespace, bondy_db:info(Table)).

registered_namespaces() ->
    bondy_oplog_core_registry:namespaces().

%% The oplog-side state a table leaves behind if it is not closed.
baseline() ->
    #{
        namespaces => lists:sort(registered_namespaces()),
        writers => lists:sort(bondy_oplog_core_registry:index_writers()),
        writer_children => length(
            supervisor:which_children(bondy_oplog_secondary_sup)
        ),
        instances => lists:sort(bondy_oplog:list_instances())
    }.

live_pids(Table) ->
    Pids = bondy_db:table_pids(Table) ++ writer_pids(Table, by_value),
    ?assert(lists:all(fun erlang:is_process_alive/1, Pids)),
    Pids.

writer_pids(Table, IndexName) ->
    NS = namespace(Table),
    #{IndexName := #{sec_shard_count := N}} =
        maps:get(indexes, bondy_db:info(Table)),
    [
        begin
            {ok, Entry} = bondy_oplog_core_registry:lookup(NS, IndexName, S),
            Pid = bondy_oplog_core_registry:entry_writer_pid(Entry),
            true = is_pid(Pid),
            Pid
        end
     || S <- lists:seq(0, N - 1)
    ].

flush_index(Table, IndexName) ->
    lists:foreach(
        fun(Pid) -> ok = bondy_oplog_secondary_writer:flush_sync(Pid) end,
        writer_pids(Table, IndexName)
    ).

%% The secondary supervisor is shared with every DB open in the VM, so only
%% this DB's writers (child id `<<DbName, "/idx/", Shard>>`) count.
index_writers_of(DbName) ->
    Prefix = <<(atom_to_binary(DbName))/binary, "/">>,
    Size = byte_size(Prefix),
    [
        Id
     || {Id, _, _, _} <- supervisor:which_children(bondy_oplog_secondary_sup),
        is_binary(Id),
        binary:part(Id, 0, min(Size, byte_size(Id))) =:= Prefix
    ].

assert_closed(Table, Pids) ->
    ?assertNot(lists:member(namespace(Table), registered_namespaces())),
    ?assertEqual([], [P || P <- Pids, is_process_alive(P)]),
    ok.

wait_until(Fun) ->
    wait_until(Fun, 100).

wait_until(Fun, 0) ->
    ?assert(Fun());
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, N - 1)
    end.
