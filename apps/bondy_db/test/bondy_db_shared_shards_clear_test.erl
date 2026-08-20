%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end validation of the `bondy_db_topology_shared_shards` topology —
%% the PRODUCTION DEFAULT for nine of Bondy's twelve tables
%% (`doc_extras/architecture/07_app_developers_tour.md`) — focused on the
%% secondary-index CLEAR/REBUILD path across its N shared Bookies.
%%
%% Why this suite exists: `shared_shards` had ZERO topology-level test
%% coverage. The entity-scoped index clear (`{entity, ET, IndexName}`) is
%% proven only at the adapter level (`bondy_db_projection_leveled_test`,
%% hand-written buckets, a single Bookie). That cannot exercise the two
%% properties that only the real topology has:
%%
%%   1. **Co-location isolation.** Many tables share each Bookie, so a
%%      rebuild of one table's index must wipe ONLY that entity type's
%%      buckets — a sibling table declaring the SAME `IndexName` (which is
%%      exactly the shared_shards case: every table uses the same index
%%      names) must be left intact. A wrong clear scope (`{suffix, _}`
%%      instead of `{entity, ET, _}`) would over-wipe the sibling.
%%
%%   2. **N-Bookie fan-out.** A secondary index spreads its terms across
%%      the N shared Bookies (one sec-shard per term-hash). A rebuild's
%%      clear + re-derive must reach every Bookie, not just one.
%%
%% Construction: two co-located tables (`users`, `items`) both declare a
%% `by_status` index over an `lww_register` value (`extract => []` ⇒ the
%% index term IS the cell value). The index terms are chosen so the
%% `users` index spans ALL ?SHARDS secondary shards (asserted), forcing the
%% rebuild to fan out across every Bookie. Each rebuild then asserts the
%% rebuilt table is re-derived identically AND the co-located sibling is
%% byte-for-byte untouched.
%% =============================================================================

-module(bondy_db_shared_shards_clear_test).

-include_lib("eunit/include/eunit.hrl").

-define(FOLD, bondy_oplog_crdt_lww_register).
-define(SHARDS, 4).
-define(DB, mst_shared_shards_clear_db).
-define(R, <<"r1">>).
-define(IDX, by_status).

%% =============================================================================
%% Generators
%% =============================================================================

shared_shards_clear_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        gen("primary_fan_out_smoke", fun primary_fan_out_smoke/1),
        gen(
            "rebuild_users_isolates_items_across_all_bookies",
            fun rebuild_users_isolates_items/1
        ),
        gen(
            "rebuild_items_isolates_users_across_all_bookies",
            fun rebuild_items_isolates_users/1
        )
    ]}.

gen(Title, Fn) ->
    fun(Ctx) -> {Title, {timeout, 60, fun() -> Fn(Ctx) end}} end.

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Deterministic timing — no AE/GC scheduler racing the rebuild.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = make_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(?DB, #{
        topology => bondy_db_topology_shared_shards,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => ?SHARDS,
        fold_module => ?FOLD
    }),
    {Db, Sup, Dir}.

cleanup({Db, Sup, Dir}) ->
    %% A mid-test assertion failure bypasses `close_table/1`, leaving
    %% applier instances alive whose cached projection-adapter handles
    %% point at the (about-to-die) bookies. Force-stop every running
    %% instance so the next test boots from a clean substrate.
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
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    rmrf(wal_dir_for_this_db()),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% shared_shards had no topology-level test at all; first prove the basic
%% primary write/read path routes through the shared Bookies and fans the
%% key set out across all ?SHARDS shards.
primary_fan_out_smoke({Db, _Sup, _Dir}) ->
    {ok, T} = open_indexed(Db, users),
    Keys = [<<"k-", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 60)],
    lists:foreach(
        fun(K) ->
            ok = bondy_db:apply(
                T, ?R, K, {set, bondy_db:tick(T), <<K/binary, "-v">>}
            )
        end,
        Keys
    ),
    lists:foreach(
        fun(K) ->
            ?assertEqual(
                {ok, {<<K/binary, "-v">>, '_'}},
                mask_hlc(bondy_db:read(T, ?R, K))
            )
        end,
        Keys
    ),
    %% The shared Bookie pool partitions the primary by `phash2({Bucket, Key})`;
    %% prove the key set actually reaches every shard (bucket = entity binary).
    Bucket = atom_to_binary(users, utf8),
    Used = lists:foldl(
        fun(K, Acc) ->
            sets:add_element(erlang:phash2({Bucket, K}, ?SHARDS), Acc)
        end,
        sets:new([{version, 2}]),
        Keys
    ),
    ?assertEqual(?SHARDS, sets:size(Used)),
    ok = bondy_db:close_table(T).

%% HEADLINE: rebuild `users.by_status` and assert (a) `users` is re-derived
%% identically across every Bookie its terms span, and (b) the co-located
%% `items.by_status` sibling is left byte-for-byte intact.
rebuild_users_isolates_items({Db, _Sup, _Dir}) ->
    {Users, Items, Terms, UsersBefore, ItemsBefore} = setup_colocated(Db),

    ok = bondy_db:rebuild_index(Users, ?IDX),

    ?assertEqual(UsersBefore, snapshot(Users, Terms)),
    ?assertEqual(ItemsBefore, snapshot(Items, Terms)),

    ok = bondy_db:close_table(Users),
    ok = bondy_db:close_table(Items).

%% Symmetric direction: rebuilding `items` must not touch `users`.
rebuild_items_isolates_users({Db, _Sup, _Dir}) ->
    {Users, Items, Terms, UsersBefore, ItemsBefore} = setup_colocated(Db),

    ok = bondy_db:rebuild_index(Items, ?IDX),

    ?assertEqual(ItemsBefore, snapshot(Items, Terms)),
    ?assertEqual(UsersBefore, snapshot(Users, Terms)),

    ok = bondy_db:close_table(Users),
    ok = bondy_db:close_table(Items).

%% =============================================================================
%% Co-located fixture
%% =============================================================================

%% Open `users` and `items` (same `by_status` index), pick terms that span
%% all ?SHARDS secondary shards of the `users` index (so a rebuild fans out
%% across every Bookie), write 2 keys per (table, term), flush, and return
%% the two index snapshots taken while both are live.
setup_colocated(Db) ->
    {ok, Users} = open_indexed(Db, users),
    {ok, Items} = open_indexed(Db, items),
    Terms = terms_spanning_shards(users, ?SHARDS),
    %% Sanity: the terms genuinely cover every Bookie, else the fan-out is
    %% not exercised and the isolation claim is weaker than advertised.
    ?assertEqual(
        ?SHARDS, length(lists:usort([sec_shard(users, Tm) || Tm <- Terms]))
    ),

    write_terms(Users, <<"u">>, Terms),
    write_terms(Items, <<"i">>, Terms),
    flush_index(Users, ?IDX),
    flush_index(Items, ?IDX),

    UsersBefore = snapshot(Users, Terms),
    ItemsBefore = snapshot(Items, Terms),

    %% Pre-condition: each table's index holds only its own keys.
    lists:foreach(
        fun(Tm) ->
            ?assertEqual(keys(<<"u">>, Tm), maps:get(Tm, UsersBefore)),
            ?assertEqual(keys(<<"i">>, Tm), maps:get(Tm, ItemsBefore))
        end,
        Terms
    ),
    {Users, Items, Terms, UsersBefore, ItemsBefore}.

open_indexed(Db, ET) ->
    bondy_db:open_table(Db, ET, #{
        fold_module => ?FOLD,
        indexes => [#{name => ?IDX, extract => []}]
    }).

%% Two keys per term; the lww value IS the indexed term (`extract => []`).
write_terms(T, Prefix, Terms) ->
    lists:foreach(
        fun(Tm) ->
            lists:foreach(
                fun(K) ->
                    ok = bondy_db:apply(T, ?R, K, {set, bondy_db:tick(T), Tm})
                end,
                keys(Prefix, Tm)
            )
        end,
        Terms
    ).

keys(Prefix, Term) ->
    lists:sort([
        <<Prefix/binary, "-", Term/binary, "-1">>,
        <<Prefix/binary, "-", Term/binary, "-2">>
    ]).

%% #{Term => sorted primary keys} read back through the equality index path
%% (single-shard per term — exactly the co-location surface).
snapshot(T, Terms) ->
    maps:from_list([
        begin
            {ok, Rows} = bondy_db:index_get(T, ?R, ?IDX, Tm, #{}),
            {Tm, lists:sort([K || {K, _Cols} <- Rows])}
        end
     || Tm <- Terms
    ]).

%% =============================================================================
%% Shard math (deterministic fan-out)
%% =============================================================================

%% Pick one term per secondary shard of `ET`'s `by_status` index, so the
%% returned list covers all N Bookies with minimal data.
terms_spanning_shards(ET, N) ->
    pick_terms(ET, N, 0, #{}).

pick_terms(_ET, N, _I, Acc) when map_size(Acc) =:= N ->
    [maps:get(S, Acc) || S <- lists:seq(0, N - 1)];
pick_terms(ET, N, I, Acc) when I < 100000 ->
    Term = <<"term", (integer_to_binary(I))/binary>>,
    S = sec_shard(ET, Term),
    Acc1 =
        case maps:is_key(S, Acc) of
            true -> Acc;
            false -> Acc#{S => Term}
        end,
    pick_terms(ET, N, I + 1, Acc1);
pick_terms(_ET, N, _I, Acc) ->
    error({could_not_span_shards, N, Acc}).

%% Mirror the facade's term routing: `index_bucket` for shared_shards is
%% `<<ET, "/$idx/", IndexName>>` (realm-less), and the index has no
%% `normalize` so the raw binary term routes directly.
sec_shard(ET, Term) ->
    Bucket = bondy_oplog_index_key:bucket(atom_to_binary(ET, utf8), ?IDX),
    bondy_oplog_index_key:shard(Bucket, Term, ?SHARDS).

%% =============================================================================
%% Index flush
%% =============================================================================

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

%% =============================================================================
%% Misc helpers
%% =============================================================================

mask_hlc({ok, {V, _H}}) -> {ok, {V, '_'}};
mask_hlc(Other) -> Other.

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_shared_shards_clear",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

wal_dir_for_this_db() ->
    filename:join(["/tmp", "bondy_oplog_wal", os:getpid(), atom_to_list(?DB)]).

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
