%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Realm-scoped secondary index reads on a `shared_shards` (G-1) table — the
%% production `main` topology, where the realm is folded into the cell KEY
%% (not the bucket). The index entry key is therefore
%% `<<enc(Term), 0, Realm, 0, Key>>`, so a term's entries span every realm
%% and `index_get/5` must restrict its scan to the term's realm sub-band
%% (`index_eq_bounds/4`) or it would leak other realms' entries. These tests
%% pin that, plus the multi-valued (list-leaf) index and the `after_key`
%% within-term keyset pagination — the substrate piece the `member` relation's
%% reverse access path (the `by_group` index on `security_users`) rides on.
%%
%% Unlike `bondy_db_index_test` (per_entity, realm-in-bucket, direct cell
%% insertion), these drive the REAL write path: `apply/4` → `cell_apply`
%% term-diff → secondary writer, made deterministic with `await_index/2`.
%% =============================================================================

-module(bondy_db_index_realm_test).

-include_lib("eunit/include/eunit.hrl").

-define(TOPOLOGY, bondy_db_topology_shared_shards).
-define(SHARDS, 4).

%% A multi-valued index over the user record's `groups` list: one entry per
%% (group, user) — exactly the `security_users` `by_group` shape.
indexes() ->
    [#{name => by_group, extract => [groups]}].

%% =============================================================================
%% Fixtures
%% =============================================================================

index_realm_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        gen("realm_isolation", fun realm_isolation/1),
        gen("multi_valued_membership", fun multi_valued_membership/1),
        gen("after_key_pages_one_term", fun after_key_pages_one_term/1),
        gen("delete_removes_all_entries", fun delete_removes_all_entries/1),
        gen("range_filters_foreign_realms", fun range_filters_foreign_realms/1),
        gen("range_rejects_a_realm_prefix", fun range_rejects_a_realm_prefix/1)
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
    {ok, Db} = bondy_db:open(idx_realm_db, #{
        topology => ?TOPOLOGY,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => ?SHARDS,
        fold_module => lww_register
    }),
    {ok, Table} = bondy_db:open_table(Db, users, #{
        fold_module => lww_register,
        indexes => indexes()
    }),
    {Db, Table, Sup, Dir}.

cleanup({Db, _Table, Sup, Dir}) ->
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
    rmrf(wal_dir()),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% Two realms with the SAME group name and overlapping usernames. A realm's
%% `index_get` must return only that realm's members — no cross-realm leak,
%% even though both realms' "g1" entries share one (realm-agnostic) index
%% bucket and shard.
realm_isolation({_Db, Table, _Sup, _Dir}) ->
    put_user(Table, <<"rA">>, <<"a1">>, [<<"g1">>]),
    put_user(Table, <<"rA">>, <<"a2">>, [<<"g1">>]),
    put_user(Table, <<"rB">>, <<"b1">>, [<<"g1">>]),
    %% same username in both realms, only rB has it in g2
    put_user(Table, <<"rA">>, <<"shared">>, [<<"g1">>]),
    put_user(Table, <<"rB">>, <<"shared">>, [<<"g1">>, <<"g2">>]),
    ok = bondy_db:await_index(Table, by_group),

    ?assertEqual(
        [<<"a1">>, <<"a2">>, <<"shared">>],
        members(Table, <<"rA">>, <<"g1">>)
    ),
    ?assertEqual(
        [<<"b1">>, <<"shared">>],
        members(Table, <<"rB">>, <<"g1">>)
    ),
    %% g2 exists only in rB
    ?assertEqual([<<"shared">>], members(Table, <<"rB">>, <<"g2">>)),
    ?assertEqual([], members(Table, <<"rA">>, <<"g2">>)),
    %% a group present in no realm
    ?assertEqual([], members(Table, <<"rA">>, <<"none">>)).

%% A user in N groups yields N index entries — one per group — and appears
%% under each group's read.
multi_valued_membership({_Db, Table, _Sup, _Dir}) ->
    put_user(Table, <<"r1">>, <<"u1">>, [<<"g1">>, <<"g2">>, <<"g3">>]),
    put_user(Table, <<"r1">>, <<"u2">>, [<<"g2">>]),
    ok = bondy_db:await_index(Table, by_group),
    ?assertEqual([<<"u1">>], members(Table, <<"r1">>, <<"g1">>)),
    ?assertEqual([<<"u1">>, <<"u2">>], members(Table, <<"r1">>, <<"g2">>)),
    ?assertEqual([<<"u1">>], members(Table, <<"r1">>, <<"g3">>)).

%% `after_key` resumes strictly after a primary key within ONE term's band,
%% so a high-cardinality group pages cleanly with no skip/dup.
after_key_pages_one_term({_Db, Table, _Sup, _Dir}) ->
    Keys = [ukey(I) || I <- lists:seq(1, 25)],
    [put_user(Table, <<"r1">>, K, [<<"g1">>]) || K <- Keys],
    ok = bondy_db:await_index(Table, by_group),
    %% page size 10 ⇒ [10, 10, 5]
    {P1, A1} = page(Table, <<"r1">>, <<"g1">>, undefined, 10),
    {P2, A2} = page(Table, <<"r1">>, <<"g1">>, A1, 10),
    {P3, A3} = page(Table, <<"r1">>, <<"g1">>, A2, 10),
    ?assertEqual([10, 10, 5], [length(P1), length(P2), length(P3)]),
    ?assertEqual(Keys, P1 ++ P2 ++ P3),
    %% Page 3 was short ⇒ it already signalled the end (cursor undefined).
    ?assertEqual(undefined, A3),
    %% Paging strictly after the very last key yields nothing.
    ?assertEqual(
        {[], undefined}, page(Table, <<"r1">>, <<"g1">>, <<"u00025">>, 10)
    ).

%% Clearing a user removes EVERY index entry it contributed (the OLD→NEW
%% term diff with NewTerms = []), across all its groups.
delete_removes_all_entries({_Db, Table, _Sup, _Dir}) ->
    put_user(Table, <<"r1">>, <<"u1">>, [<<"g1">>, <<"g2">>]),
    put_user(Table, <<"r1">>, <<"u2">>, [<<"g1">>]),
    ok = bondy_db:await_index(Table, by_group),
    ?assertEqual([<<"u1">>, <<"u2">>], members(Table, <<"r1">>, <<"g1">>)),
    %% Remove u1 from g1 only (still in g2).
    put_user(Table, <<"r1">>, <<"u1">>, [<<"g2">>]),
    ok = bondy_db:await_index(Table, by_group),
    ?assertEqual([<<"u2">>], members(Table, <<"r1">>, <<"g1">>)),
    ?assertEqual([<<"u1">>], members(Table, <<"r1">>, <<"g2">>)),
    %% Clear u1 entirely ⇒ gone from every group.
    ok = bondy_db:apply(Table, <<"r1">>, <<"u1">>, clear),
    ok = bondy_db:await_index(Table, by_group),
    ?assertEqual([], members(Table, <<"r1">>, <<"g2">>)),
    ?assertEqual([<<"u2">>], members(Table, <<"r1">>, <<"g1">>)).

%% A term RANGE cannot use the realm sub-band an equality read gets, because a
%% term range spans realms non-contiguously — so `index_rows/3` must FILTER on
%% the realm prefix. Before it did, a foreign row had a fixed
%% `byte_size(Realm) + 1` bytes lopped off and came back as a corrupted key
%% indistinguishable from a real one.
range_filters_foreign_realms({_Db, Table, _Sup, _Dir}) ->
    put_user(Table, <<"rA">>, <<"a1">>, [<<"g1">>]),
    put_user(Table, <<"rA">>, <<"a2">>, [<<"g3">>]),
    put_user(Table, <<"rB">>, <<"b1">>, [<<"g1">>]),
    put_user(Table, <<"rB">>, <<"b2">>, [<<"g2">>]),
    ok = bondy_db:await_index(Table, by_group),

    %% A band covering g1..g3 — every realm's entries share it.
    ?assertEqual([<<"a1">>, <<"a2">>], range(Table, <<"rA">>, ~"g1", ~"g4")),
    ?assertEqual([<<"b1">>, <<"b2">>], range(Table, <<"rB">>, ~"g1", ~"g4")),

    %% Keys come back as the caller wrote them, NOT still realm-folded.
    [
        ?assertEqual(nomatch, binary:match(K, <<0>>))
     || K <- range(Table, <<"rA">>, ~"g1", ~"g4")
    ],

    %% A realm with no entry in the band gets nothing rather than someone
    %% else's rows.
    ?assertEqual([], range(Table, <<"rC">>, ~"g1", ~"g4")).

%% The check must be exact, not "starts with". Realm `<<"r">>` is a byte-prefix
%% of `<<"rr">>`, so a naive `byte_size` strip would turn `<<"rr",0,"u1">>` into
%% `<<0,"u1">>` and hand it back as one of `<<"r">>`'s keys. Requiring the NUL
%% separator to land immediately after the realm rejects it — the same
%% injectivity `assert_nul_free_realm/1` guards on the write side.
range_rejects_a_realm_prefix({_Db, Table, _Sup, _Dir}) ->
    put_user(Table, ~"r", ~"u1", [<<"g1">>]),
    put_user(Table, ~"rr", ~"u2", [<<"g1">>]),
    ok = bondy_db:await_index(Table, by_group),

    ?assertEqual([~"u1"], range(Table, ~"r", ~"g1", ~"g2")),
    ?assertEqual([~"u2"], range(Table, ~"rr", ~"g1", ~"g2")),
    %% And the equality path agrees with the range path.
    ?assertEqual([~"u1"], members(Table, ~"r", ~"g1")),
    ?assertEqual([~"u2"], members(Table, ~"rr", ~"g1")).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Usernames returned by index_range over `[Lo, Hi)`, in (term, key) order.
range(Table, Realm, Lo, Hi) ->
    {ok, Rows} = bondy_db:index_range(Table, Realm, by_group, Lo, Hi, #{}),
    [U || {U, _Cols} <- Rows].

put_user(Table, Realm, Username, Groups) ->
    V = #{type => user, username => Username, groups => Groups},
    ok = bondy_db:apply(Table, Realm, Username, {set, bondy_db:tick(Table), V}).

%% Usernames returned by index_get for a group, in key order.
members(Table, Realm, Group) ->
    {ok, Rows} = bondy_db:index_get(Table, Realm, by_group, Group, #{}),
    [U || {U, _Cols} <- Rows].

%% One keyset page within a term: {Usernames, NextAfterKey | undefined}.
page(Table, Realm, Group, After, Limit) ->
    Opts0 = #{limit => Limit + 1},
    Opts =
        case After of
            undefined -> Opts0;
            _ -> Opts0#{after_key => After}
        end,
    {ok, Rows} = bondy_db:index_get(Table, Realm, by_group, Group, Opts),
    Users = [U || {U, _} <- Rows],
    case length(Users) > Limit of
        true ->
            Page = lists:sublist(Users, Limit),
            {Page, lists:last(Page)};
        false ->
            {Users, undefined}
    end.

ukey(I) ->
    iolist_to_binary(io_lib:format("u~5..0b", [I])).

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_index_realm_test",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

wal_dir() ->
    filename:join(["/tmp", "bondy_oplog_wal", os:getpid(), "idx_realm_db"]).

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
