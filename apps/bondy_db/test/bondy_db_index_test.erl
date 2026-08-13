%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% IDX-2 — secondary index provisioning + read API.
%%
%% Covers: provisioning a table's declared indexes (registry shard-sets,
%% `info/1` reporting), empty reads, single-shard equality + cross-shard
%% range routing, bucket/realm isolation, the `{max_lag, Ms}` refusal,
%% spec validation (reserved/duplicate/invalid), and teardown.
%%
%% The secondary writer (IDX-3) does not exist yet, so the populated-read
%% tests insert index-entry cell frames straight into the index's ETS
%% projection tables — using the *real* fold-state and cell-frame encoders
%% — and read them back through `bondy_db:index_get/index_range`. That
%% exercises the full substrate range + decode path (composite-key
%% recovery, column decode, ordering) without the not-yet-built writer.
%% =============================================================================

-module(bondy_db_index_test).

-include_lib("eunit/include/eunit.hrl").

-define(TOPOLOGY, bondy_db_topology_per_entity).

%% Two indexes on the `users` table: a projecting equality index on
%% `status` and a pointer-only index on `age`.
indexes() ->
    [
        #{
            name => by_status,
            extract => [status],
            projects => [[name], [status]]
        },
        #{name => by_age, extract => [age], sec_shard_count => 2}
    ].

%% =============================================================================
%% Fixtures
%% =============================================================================

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    Dir = make_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(idx_db, #{
        topology => ?TOPOLOGY,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => 4,
        fold_module => lww_register
    }),
    {ok, Table} = bondy_db:open_table(Db, users, #{indexes => indexes()}),
    {Db, Table, Sup, Dir}.

cleanup({Db, Table, Sup, Dir}) ->
    _ = catch bondy_db:close_table(Table),
    _ = catch bondy_db:close(Db),
    case is_process_alive(Sup) of
        true -> _ = catch bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    ok.

with_table(Title, Fn) ->
    {Title,
        {setup, fun setup/0, fun cleanup/1, fun(Ctx) ->
            {Title, fun() -> Fn(Ctx) end}
        end}}.

index_test_() ->
    [
        with_table(
            "provision_reports_indexes", fun provision_reports_indexes/1
        ),
        with_table(
            "secondary_shards_registered", fun secondary_shards_registered/1
        ),
        with_table("custom_sec_shard_count", fun custom_sec_shard_count/1),
        with_table("empty_index_get", fun empty_index_get/1),
        with_table("empty_index_range", fun empty_index_range/1),
        with_table("unknown_index_error", fun unknown_index_error/1),
        with_table("max_lag_refusal", fun max_lag_refusal/1),
        with_table("populated_index_get", fun populated_index_get/1),
        with_table("pointer_only_index", fun pointer_only_index/1),
        with_table("index_range_ordered", fun index_range_ordered/1),
        with_table("realm_isolation", fun realm_isolation/1),
        with_table(
            "teardown_unregisters_shards", fun teardown_unregisters_shards/1
        )
    ].

%% =============================================================================
%% Provisioning
%% =============================================================================

provision_reports_indexes({_Db, Table, _Sup, _Dir}) ->
    Info = bondy_db:info(Table),
    Indexes = maps:get(indexes, Info),
    ?assertEqual([by_age, by_status], lists:sort(maps:keys(Indexes))),
    ?assertEqual(
        #{sec_shard_count => 4, projects => [[name], [status]]},
        maps:get(by_status, Indexes)
    ),
    ?assertEqual(
        #{sec_shard_count => 2, projects => []},
        maps:get(by_age, Indexes)
    ).

secondary_shards_registered({_Db, Table, _Sup, _Dir}) ->
    NS = maps:get(namespace, bondy_db:info(Table)),
    %% by_status has 4 shards (inherits primary shard_count); each is backed
    %% by the native index-entry CRDT (PR-Z; the retired `index_entry` fold's
    %% op-based twin), on the **same projection backend as the primary table**
    %% — here `per_entity` is durable, so the index projection is leveled too.
    lists:foreach(
        fun(Shard) ->
            {ok, Entry} = bondy_oplog_core_registry:lookup(
                NS, by_status, Shard
            ),
            ?assertEqual(
                bondy_oplog_crdt_index_entry,
                bondy_oplog_core_registry:entry_crdt_module(Entry)
            ),
            ?assertEqual(
                bondy_db_projection_leveled,
                bondy_oplog_core_registry:entry_projection_adapter(Entry)
            ),
            ?assertEqual(
                4, bondy_oplog_core_registry:entry_shard_count(Entry)
            )
        end,
        lists:seq(0, 3)
    ),
    ?assertEqual(not_found, bondy_oplog_core_registry:lookup(NS, by_status, 4)).

custom_sec_shard_count({_Db, Table, _Sup, _Dir}) ->
    NS = maps:get(namespace, bondy_db:info(Table)),
    %% by_age declared sec_shard_count => 2.
    ?assertMatch({ok, _}, bondy_oplog_core_registry:lookup(NS, by_age, 0)),
    ?assertMatch({ok, _}, bondy_oplog_core_registry:lookup(NS, by_age, 1)),
    ?assertEqual(not_found, bondy_oplog_core_registry:lookup(NS, by_age, 2)),
    ?assertEqual({ok, 2}, bondy_oplog_core_registry:shard_count(NS, by_age)).

%% =============================================================================
%% Empty reads
%% =============================================================================

empty_index_get({_Db, Table, _Sup, _Dir}) ->
    ?assertEqual(
        {ok, []},
        bondy_db:index_get(Table, <<"r1">>, by_status, <<"active">>, #{})
    ).

empty_index_range({_Db, Table, _Sup, _Dir}) ->
    ?assertEqual(
        {ok, []},
        bondy_db:index_range(Table, <<"r1">>, by_status, <<"a">>, <<"z">>, #{})
    ).

unknown_index_error({_Db, Table, _Sup, _Dir}) ->
    ?assertEqual(
        {error, {unknown_index, nope}},
        bondy_db:index_get(Table, <<"r1">>, nope, <<"x">>, #{})
    ),
    ?assertEqual(
        {error, {unknown_index, nope}},
        bondy_db:index_range(Table, <<"r1">>, nope, <<"a">>, <<"z">>, #{})
    ).

%% A finite max_lag refuses while a shard is flagged for rebuild. (Since
%% IDX-4 the startup backfill freshens every shard at open, so the refusal
%% path is exercised by simulating a saturation drop — marking the shards
%% `needs_rebuild` — which makes them unconditionally stale until a rebuild
%% clears the flag. The error now carries the lag diagnostic, `infinity`
%% for a flagged shard.)
max_lag_refusal({_Db, Table, _Sup, _Dir}) ->
    NS = maps:get(namespace, bondy_db:info(Table)),
    #{by_status := #{sec_shard_count := N}} = maps:get(
        indexes, bondy_db:info(Table)
    ),
    lists:foreach(
        fun(S) ->
            {ok, E} = bondy_oplog_core_registry:lookup(NS, by_status, S),
            ok = bondy_oplog_core_registry:index_mark_rebuild(E)
        end,
        lists:seq(0, N - 1)
    ),
    ?assertMatch(
        {error, {stale_secondary, by_status, infinity}},
        bondy_db:index_get(
            Table, <<"r1">>, by_status, <<"active">>, #{max_lag => 0}
        )
    ),
    ?assertMatch(
        {error, {stale_secondary, by_status, infinity}},
        bondy_db:index_range(
            Table, <<"r1">>, by_status, <<"a">>, <<"z">>, #{max_lag => 0}
        )
    ).

%% =============================================================================
%% Populated reads (direct substrate insertion; IDX-3 supplies the writer)
%% =============================================================================

populated_index_get({_Db, Table, _Sup, _Dir}) ->
    Realm = <<"r1">>,
    Cols = bondy_oplog_index_spec:project(
        by_status_spec(), #{name => <<"alice">>, status => <<"active">>}
    ),
    put_index_entry(Table, Realm, by_status, <<"active">>, <<"u1">>, Cols, 10),
    %% A different term must not appear under "active".
    put_index_entry(Table, Realm, by_status, <<"idle">>, <<"u2">>, <<>>, 11),
    {ok, Rows} = bondy_db:index_get(Table, Realm, by_status, <<"active">>, #{}),
    ?assertEqual(
        [{<<"u1">>, #{[name] => <<"alice">>, [status] => <<"active">>}}],
        Rows
    ),
    ?assertEqual(
        {ok, []}, bondy_db:index_get(Table, Realm, by_status, <<"gone">>, #{})
    ).

pointer_only_index({_Db, Table, _Sup, _Dir}) ->
    Realm = <<"r1">>,
    put_index_entry(Table, Realm, by_age, 30, <<"u1">>, <<>>, 5),
    {ok, Rows} = bondy_db:index_get(Table, Realm, by_age, 30, #{}),
    ?assertEqual([{<<"u1">>, #{}}], Rows).

%% Range over a span of terms that hash to different secondary shards is
%% reassembled in (term, primary-key) order by range_all.
index_range_ordered({_Db, Table, _Sup, _Dir}) ->
    Realm = <<"r1">>,
    put_index_entry(Table, Realm, by_status, <<"a">>, <<"u3">>, <<>>, 1),
    put_index_entry(Table, Realm, by_status, <<"a">>, <<"u1">>, <<>>, 2),
    put_index_entry(Table, Realm, by_status, <<"b">>, <<"u2">>, <<>>, 3),
    put_index_entry(Table, Realm, by_status, <<"c">>, <<"u9">>, <<>>, 4),
    {ok, Rows} =
        bondy_db:index_range(Table, Realm, by_status, <<"a">>, <<"c">>, #{}),
    %% Half-open [a, c): a (u1<u3) and b, but NOT c.
    ?assertEqual(
        [{<<"u1">>, #{}}, {<<"u3">>, #{}}, {<<"u2">>, #{}}], Rows
    ).

realm_isolation({_Db, Table, _Sup, _Dir}) ->
    put_index_entry(
        Table, <<"rA">>, by_status, <<"active">>, <<"u1">>, <<>>, 7
    ),
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}]},
        bondy_db:index_get(Table, <<"rA">>, by_status, <<"active">>, #{})
    ),
    %% Same term, different realm — different SecBucket, no crossover.
    ?assertEqual(
        {ok, []},
        bondy_db:index_get(Table, <<"rB">>, by_status, <<"active">>, #{})
    ).

teardown_unregisters_shards({_Db, Table, _Sup, _Dir}) ->
    NS = maps:get(namespace, bondy_db:info(Table)),
    ?assertMatch({ok, _}, bondy_oplog_core_registry:lookup(NS, by_status, 0)),
    ok = bondy_db:close_table(Table),
    ?assertEqual(not_found, bondy_oplog_core_registry:lookup(NS, by_status, 0)),
    ?assertEqual(not_found, bondy_oplog_core_registry:lookup(NS, by_age, 0)).
%% The fixture's `catch bondy_db:close_table(Table)` re-runs teardown;
%% unregister/release_cache/close_table are all idempotent.

%% =============================================================================
%% Spec validation (no fixture — these assert open_table rejects)
%% =============================================================================

reserved_index_name_test() ->
    with_db(fun(Db) ->
        ?assertEqual(
            {error, {reserved_index_name, primary}},
            bondy_db:open_table(Db, t, #{
                indexes => [#{name => primary, extract => []}]
            })
        )
    end).

duplicate_index_name_test() ->
    with_db(fun(Db) ->
        ?assertEqual(
            {error, {duplicate_index_name, by_x}},
            bondy_db:open_table(Db, t, #{
                indexes => [
                    #{name => by_x, extract => [a]},
                    #{name => by_x, extract => [b]}
                ]
            })
        )
    end).

invalid_index_spec_test() ->
    with_db(fun(Db) ->
        ?assertMatch(
            {error, {invalid_index_spec, {missing_key, extract}}},
            bondy_db:open_table(Db, t, #{
                indexes => [#{name => by_x}]
            })
        )
    end).

invalid_indexes_type_test() ->
    with_db(fun(Db) ->
        ?assertEqual(
            {error, {invalid_indexes, not_a_list}},
            bondy_db:open_table(Db, t, #{indexes => not_a_list})
        )
    end).

invalid_sec_shard_count_test() ->
    with_db(fun(Db) ->
        ?assertEqual(
            {error, {invalid_sec_shard_count, 0}},
            bondy_db:open_table(Db, t, #{
                indexes => [
                    #{name => by_x, extract => [a], sec_shard_count => 0}
                ]
            })
        )
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

by_status_spec() ->
    hd(indexes()).

%% Insert one live index entry straight into the right secondary shard's
%% ETS projection table, via the registry — the faithful "what the writer
%% will eventually do" without the writer. Builds a real index_entry state
%% and a real V2 value_equals_state cell frame.
put_index_entry(Table, Realm, IndexName, Term, PrimaryKey, Cols, Hlc) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := SecCount}} = maps:get(indexes, Info),
    SecBucket = bondy_oplog_index_key:bucket(Realm, IndexName),
    SecShard = bondy_oplog_index_key:shard(SecBucket, Term, SecCount),
    SecKey = bondy_oplog_index_key:encode(Term, PrimaryKey),
    StateBytes = bondy_oplog_crdt_index_entry:encode_state({live, Cols, Hlc}),
    Frame = bondy_oplog_cell_frame:encode(Hlc, StateBytes, undefined, true),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, IndexName, SecShard),
    PA = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    PH = bondy_oplog_core_registry:entry_projection_handle(Entry),
    ok = PA:put_batch(PH, [{SecBucket, SecKey, Frame}]).

with_db(Fn) ->
    {ok, _} = application:ensure_all_started(bondy_db),
    Dir = make_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(idx_val_db, #{
        topology => ?TOPOLOGY,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => 2,
        fold_module => lww_register
    }),
    try
        Fn(Db)
    after
        _ = catch bondy_db:close(Db),
        _ = catch bondy_db_leveled_sup:stop(Sup),
        rmrf(Dir)
    end.

make_tempdir() ->
    Base = filename:join([
        "/tmp/" ++ os:getpid(),
        "bondy_db_index_test",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
