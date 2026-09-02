%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% EUnit suite for the instance-id contract shared by `bondy_db` and
%% `bondy_oplog`.
%%
%% An instance id is an opaque NAME. Two properties have to hold at once, and
%% they belong to different apps, so no single-app suite covers the pair:
%%
%%   - `bondy_oplog_path:storage_path/3` uses the id as ONE directory
%%     component, so `bondy_db` has to compose it without a `/`;
%%   - `bondy_oplog:db_of/1` answers which DB an instance belongs to, which
%%     selects the anti-entropy topology fingerprint — two nodes refuse to sync
%%     when theirs differ. It answers from the instance's REGISTRY ROW, not by
%%     parsing the id, so `bondy_db` has to carry the DB in the instance opts.
%%
%% The parse this replaced failed silently: a separator change made `db_of/1`
%% return `undefined` and stopped replication with nothing logged
%% (`bondy_oplog_compaction_cluster_SUITE` timed out waiting for convergence).
%% The cases below pin both halves, and are written to kill a reintroduced
%% parse — see `lookup_not_parse/0`.
%% =============================================================================

-module(bondy_db_instance_id_test).

-include_lib("eunit/include/eunit.hrl").

-define(TOPOLOGY, bondy_db_topology_shared_shards).
-define(SHARDS, 4).
-define(DB, instance_id_db).

%% =============================================================================
%% db_of/1 — a registry lookup, not a parse
%% =============================================================================

registry_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Ctx) ->
        [
            {"db_of answers the DB an instance was provisioned into",
                {timeout, 60, fun() -> provisioned_db(Ctx) end}},
            {"db_of is a lookup, not a parse",
                {timeout, 60, fun lookup_not_parse/0}},
            {"db_of is total", fun total/0}
        ]
    end}.

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
    {Db, Users, Sup, Dir}.

cleanup({Db, _Users, Sup, Dir}) ->
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
    _ =
        case is_process_alive(Sup) of
            true ->
                try
                    bondy_db_leveled_sup:stop(Sup)
                catch
                    _:_ -> ok
                end;
            false ->
                ok
        end,
    rmrf(Dir),
    rmrf(wal_dir()),
    ok.

%% The end-to-end half: provisioning must CARRY the DB into the instance opts.
%% Nothing else here proves `bondy_db` does that — the hand-started instances
%% below would pass with the opt never threaded through provisioning.
provisioned_db({_Db, Users, _Sup, _Dir}) ->
    Ids = touch_every_shard(Users),
    ?assertEqual(?SHARDS, length(Ids)),
    lists:foreach(
        fun(Id) -> ?assertEqual({Id, ?DB}, {Id, bondy_oplog:db_of(Id)}) end,
        Ids
    ).

%% The two witnesses a parse cannot satisfy. Each instance is started directly
%% on the library API, so its id and its `db` opt are independent:
%%
%%   1. an id that does NOT follow `bondy_db`'s convention still answers the
%%      DB it was started with — a parse would answer `free`;
%%   2. an id that DOES look like a `bondy_db` id, started with no `db` opt,
%%      answers `undefined` — a parse would answer `main`, i.e. some other
%%      DB's fingerprint. That is the failure direction that matters: a wrong
%%      fingerprint is compared and refused, silently halting anti-entropy.
lookup_not_parse() ->
    Carried = <<"free-form-id">>,
    {ok, _} = bondy_oplog:start_instance(Carried, #{db => somedb}),
    ?assertEqual(somedb, bondy_oplog:db_of(Carried)),

    Lookalike = <<"main-0">>,
    {ok, _} = bondy_oplog:start_instance(Lookalike, #{}),
    ?assertEqual(undefined, bondy_oplog:db_of(Lookalike)),

    ok = bondy_oplog:stop_instance(Carried),
    ok = bondy_oplog:stop_instance(Lookalike),

    %% ...and the answer goes with the instance: the row is the only source.
    ?assertEqual(undefined, bondy_oplog:db_of(Carried)).

%% Callers on the sync path treat `undefined` as "no fingerprint" and skip the
%% compatibility check, so an id with no row must answer, not crash.
total() ->
    ?assertEqual(undefined, bondy_oplog:db_of(<<"never_started-3">>)),
    ?assertEqual(undefined, bondy_oplog:db_of(<<>>)).

%% =============================================================================
%% The encoding — one directory component, injective
%% =============================================================================

%% An id has to survive `storage_path/3` as a single component: the directory
%% it names is exactly the id, under exactly the base.
encoded_ids_name_one_directory_test() ->
    Ids = [
        bondy_db:encode_instance_id(main, 4),
        bondy_db:encode_instance_id(main, realm, 7)
    ],
    lists:foreach(
        fun(Id) ->
            P = unicode:characters_to_binary(
                bondy_oplog_path:storage_path(Id, <<"/data">>, flat)
            ),
            ?assertEqual(<<"/data">>, filename:dirname(P)),
            ?assertEqual(Id, filename:basename(P))
        end,
        Ids
    ).

%% The encoding must be INJECTIVE, because an id names one storage directory:
%% two instances sharing an id would share a WAL and an MST. The differing
%% arity keeps the two forms apart only while no component holds the
%% separator — the assertions below exhibit the collision that closes,
%% `<<"a-b-1">>` being reachable from both `(a, b, 1)` and `('a-b', 1)`.
hyphenated_component_is_refused_test() ->
    ?assertEqual(<<"a-b-1">>, bondy_db:encode_instance_id(a, b, 1)),
    ?assertError(
        {invalid_instance_id_component, 'a-b'},
        bondy_db:encode_instance_id('a-b', 1)
    ),
    ?assertError(
        {invalid_instance_id_component, 'realm-x'},
        bondy_db:encode_instance_id(main, 'realm-x', 0)
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Writes across every shard so all shared instances are founded, then returns
%% this DB's instance ids.
touch_every_shard(Users) ->
    _ = [
        ok = bondy_db:apply(
            Users,
            <<"r1">>,
            iolist_to_binary(io_lib:format("k~4..0b", [I])),
            {set, bondy_db:tick(Users), <<"v">>}
        )
     || I <- lists:seq(1, 40)
    ],
    Prefix = <<(atom_to_binary(?DB, utf8))/binary, "-">>,
    lists:sort([
        I
     || I <- bondy_oplog:list_instances(),
        binary:longest_common_prefix([I, Prefix]) =:= byte_size(Prefix)
    ]).

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_instance_id_test",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

wal_dir() ->
    filename:join([
        "/tmp", "bondy_oplog_wal", os:getpid(), atom_to_list(?DB)
    ]).

rmrf(Dir) ->
    %% An instance id names ONE directory (`<Db>-<Shard>`), so a DB's
    %% instances are SIBLINGS rather than children of `<Db>/`.
    _ = [
        file:del_dir_r(P)
     || P <- filelib:wildcard(unicode:characters_to_list(Dir) ++ "-*")
    ],
    _ = file:del_dir_r(Dir),
    ok.
