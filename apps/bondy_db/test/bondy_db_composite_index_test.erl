%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Composite (covering permutation) secondary indices on a `shared_shards` (G-1)
%% table — the substrate's "key capability" for RDF-quad / Datalog-EDB relations
%% and the general piece-#2b machinery. A single relation (an RDF quad
%% `(s,p,o,g)`) is materialised in SEVERAL config-declared collation orders so
%% that any *prefix* access pattern is a bounded scan on some order:
%%
%%   - `spog` answers "by subject", "by (subject,predicate)", …
%%   - `pogs` answers "by predicate", "by (predicate,object)", …
%%   - `gspo` answers "by graph" (graph = realm's content), …
%%
%% These pin: (1) the orders are user-declared, never auto-permuted; (2) a
%% prefix scan returns the WHOLE fact (covering — no primary fetch); (3) every
%% order is realm-scoped via the realm-FIRST key layout on G-1; (4) a range over
%% a collation slice; (5) `delete` removes the fact from EVERY order at once
%% (the OLD→NEW term diff). Drives the real write path (`apply/4` →
%% `cell_apply` → secondary writer), made deterministic with `await_index/2`.
%% =============================================================================

-module(bondy_db_composite_index_test).

-include_lib("eunit/include/eunit.hrl").

-define(TOPOLOGY, bondy_db_topology_shared_shards).
-define(SHARDS, 4).
-define(ORDERS, [spog, pogs, gspo]).

%% Three config-declared covering permutations of the quad (s,p,o,g) — the user
%% picks exactly these; the substrate maintains them, it does not invent others.
indexes() ->
    [
        #{name => spog, collation => [[s], [p], [o], [g]]},
        #{name => pogs, collation => [[p], [o], [g], [s]]},
        #{name => gspo, collation => [[g], [s], [p], [o]]}
    ].

%% =============================================================================
%% Fixtures
%% =============================================================================

composite_index_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        gen("prefix_each_order", fun prefix_each_order/1),
        gen("covering_returns_whole_fact", fun covering_returns_whole_fact/1),
        gen("realm_isolation", fun realm_isolation/1),
        gen("prefix_range_slice", fun prefix_range_slice/1),
        gen("delete_removes_all_orders", fun delete_removes_all_orders/1)
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
    {ok, Db} = bondy_db:open(quad_db, #{
        topology => ?TOPOLOGY,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => ?SHARDS,
        fold_module => lww_register
    }),
    {ok, Table} = bondy_db:open_table(Db, quads, #{
        fold_module => lww_register,
        indexes => indexes()
    }),
    {Db, Table, Sup, Dir}.

cleanup({Db, _Table, Sup, Dir}) ->
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

%% Each declared order answers its own access pattern as a bounded prefix scan,
%% returning the full facts in that collation's order.
prefix_each_order({_Db, Table, _Sup, _Dir}) ->
    R = <<"g">>,
    put_quad(Table, R, <<"s1">>, <<"p1">>, <<"o1">>, <<"g1">>),
    put_quad(Table, R, <<"s1">>, <<"p2">>, <<"o2">>, <<"g1">>),
    put_quad(Table, R, <<"s2">>, <<"p1">>, <<"o1">>, <<"g2">>),
    flush(Table),

    %% spog: by subject s1
    ?assertEqual(
        [
            [<<"s1">>, <<"p1">>, <<"o1">>, <<"g1">>],
            [<<"s1">>, <<"p2">>, <<"o2">>, <<"g1">>]
        ],
        prefix(Table, R, spog, [<<"s1">>])
    ),
    %% pogs: by (predicate p1, object o1)
    ?assertEqual(
        [
            [<<"p1">>, <<"o1">>, <<"g1">>, <<"s1">>],
            [<<"p1">>, <<"o1">>, <<"g2">>, <<"s2">>]
        ],
        prefix(Table, R, pogs, [<<"p1">>, <<"o1">>])
    ),
    %% gspo: by graph g1
    ?assertEqual(
        [
            [<<"g1">>, <<"s1">>, <<"p1">>, <<"o1">>],
            [<<"g1">>, <<"s1">>, <<"p2">>, <<"o2">>]
        ],
        prefix(Table, R, gspo, [<<"g1">>])
    ),
    %% an unbound value yields nothing
    ?assertEqual([], prefix(Table, R, spog, [<<"s9">>])).

%% The prefix read is COVERING: the result carries every column of the fact, so
%% no primary fetch is needed to reconstruct (s,p,o,g).
covering_returns_whole_fact({_Db, Table, _Sup, _Dir}) ->
    R = <<"g">>,
    put_quad(Table, R, <<"s1">>, <<"p1">>, <<"o1">>, <<"g1">>),
    flush(Table),
    {ok, [{Cols, _Proj}]} = bondy_db:index_prefix(
        Table, R, pogs, [<<"p1">>], #{}
    ),
    %% pogs order, all four columns present
    ?assertEqual([<<"p1">>, <<"o1">>, <<"g1">>, <<"s1">>], Cols).

%% The SAME prefix in two realms returns only that realm's facts (realm-FIRST
%% layout keeps each realm's collation band contiguous and disjoint).
realm_isolation({_Db, Table, _Sup, _Dir}) ->
    put_quad(Table, <<"rA">>, <<"s1">>, <<"pA">>, <<"oA">>, <<"gA">>),
    put_quad(Table, <<"rB">>, <<"s1">>, <<"pB">>, <<"oB">>, <<"gB">>),
    flush(Table),
    ?assertEqual(
        [[<<"s1">>, <<"pA">>, <<"oA">>, <<"gA">>]],
        prefix(Table, <<"rA">>, spog, [<<"s1">>])
    ),
    ?assertEqual(
        [[<<"s1">>, <<"pB">>, <<"oB">>, <<"gB">>]],
        prefix(Table, <<"rB">>, spog, [<<"s1">>])
    ),
    %% a subject present only in rA is absent from rB
    put_quad(Table, <<"rA">>, <<"sA_only">>, <<"p">>, <<"o">>, <<"g">>),
    flush(Table),
    ?assertEqual([], prefix(Table, <<"rB">>, spog, [<<"sA_only">>])).

%% A half-open range over a collation slice: fix p=p1, scan o in [o1, o2).
prefix_range_slice({_Db, Table, _Sup, _Dir}) ->
    R = <<"g">>,
    put_quad(Table, R, <<"s1">>, <<"p1">>, <<"o1">>, <<"g1">>),
    put_quad(Table, R, <<"s2">>, <<"p1">>, <<"o2">>, <<"g1">>),
    put_quad(Table, R, <<"s3">>, <<"p1">>, <<"o3">>, <<"g1">>),
    flush(Table),
    {ok, Rows} = bondy_db:index_prefix_range(
        Table, R, pogs, [<<"p1">>, <<"o1">>], [<<"p1">>, <<"o3">>], #{}
    ),
    Os = [O || {[<<"p1">>, O, _G, _S], _Proj} <- Rows],
    %% [o1, o3): o1 and o2 included, o3 excluded
    ?assertEqual([<<"o1">>, <<"o2">>], lists:sort(Os)).

%% Clearing a fact removes it from EVERY declared order at once (one delete,
%% all permutations), via the OLD→NEW term diff.
delete_removes_all_orders({_Db, Table, _Sup, _Dir}) ->
    R = <<"g">>,
    put_quad(Table, R, <<"s1">>, <<"p1">>, <<"o1">>, <<"g1">>),
    put_quad(Table, R, <<"s2">>, <<"p1">>, <<"o1">>, <<"g1">>),
    flush(Table),
    ?assertEqual(2, length(prefix(Table, R, pogs, [<<"p1">>, <<"o1">>]))),

    ok = bondy_db:apply(
        Table, R, quad_key(<<"s1">>, <<"p1">>, <<"o1">>, <<"g1">>), clear
    ),
    flush(Table),

    %% gone from all three orders
    ?assertEqual(
        [[<<"s2">>, <<"p1">>, <<"o1">>, <<"g1">>]],
        prefix(Table, R, spog, [<<"s2">>])
    ),
    ?assertEqual([], prefix(Table, R, spog, [<<"s1">>])),
    ?assertEqual(
        [[<<"p1">>, <<"o1">>, <<"g1">>, <<"s2">>]],
        prefix(Table, R, pogs, [<<"p1">>, <<"o1">>])
    ),
    ?assertEqual([], prefix(Table, R, gspo, [<<"g1">>, <<"s1">>])).

%% =============================================================================
%% Helpers
%% =============================================================================

quad_key(S, P, O, G) ->
    term_to_binary({S, P, O, G}).

put_quad(Table, Realm, S, P, O, G) ->
    V = #{s => S, p => P, o => O, g => G},
    ok = bondy_db:apply(
        Table, Realm, quad_key(S, P, O, G), {set, bondy_db:tick(Table), V}
    ).

flush(Table) ->
    _ = [ok = bondy_db:await_index(Table, I) || I <- ?ORDERS],
    ok.

%% The full facts (decoded collation tuples) for a prefix, in key order.
prefix(Table, Realm, Index, Cols) ->
    {ok, Rows} = bondy_db:index_prefix(Table, Realm, Index, Cols, #{}),
    [Tuple || {Tuple, _Proj} <- Rows].

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_composite_index_test",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

wal_dir() ->
    filename:join(["/tmp", "bondy_oplog_wal", os:getpid(), "quad_db"]).

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
