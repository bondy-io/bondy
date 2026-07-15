%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Tests for the two facade additions that back the API Gateway cut-over
%% (design §11.4): opt-in apply publishing (`publish => true` → a reactor can
%% `bondy_oplog_core:subscribe/2` to the table namespace) and the whole-table
%% scan `bondy_db:list/2`.

-module(bondy_db_publish_list_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_lww_register).

publish_list_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"publish => true delivers cell_apply events to a subscriber",
                fun publish_delivers/0},
            {"publish off by default — no events", fun publish_off/0},
            {"list/2 enumerates all cells; clear removes from the scan",
                fun list_scans/0},
            {"short-form ops: term values, auto HLC, decoded reads",
                fun short_form_ops/0}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% A `publish => true` table wires every shard's applier to publish each
%% verified apply to the table namespace. A subscriber receives `{Key, FoldOp}`.
publish_delivers() ->
    {Db, T} = open(pub_on, true),
    try
        NS = bondy_db:namespace(T),
        {ok, _Ref} = bondy_oplog_core:subscribe(NS, all),
        H = bondy_db:tick(T),
        ok = bondy_db:apply(T, <<"r">>, <<"k1">>, {set, H, <<"v1">>}),
        %% The event carries the cell-level key, which on the memory topology is
        %% realm-folded (`<<Realm,0,Key>>`) — the same shape `shared_shards`
        %% publishes, where a reactor un-folds it to recover the key.
        CellKey = <<"r", 0, "k1">>,
        receive
            {bondy_oplog_core_event, NS, CellKey, _Hlc, Op} ->
                ?assertEqual({set, H, <<"v1">>}, Op)
        after 5000 ->
            ?assert(false)
        end
    after
        ok = bondy_db:close(Db)
    end.

%% Default (no `publish` opt): the applier does not publish — a subscriber
%% receives nothing.
publish_off() ->
    {Db, T} = open(pub_off, false),
    try
        NS = bondy_db:namespace(T),
        {ok, _Ref} = bondy_oplog_core:subscribe(NS, all),
        ok = bondy_db:apply(
            T, <<"r">>, <<"k1">>, {set, bondy_db:tick(T), <<"v">>}
        ),
        receive
            {bondy_oplog_core_event, NS, _, _, _} -> ?assert(false)
        after 300 ->
            ok
        end
    after
        ok = bondy_db:close(Db)
    end.

%% list/2 scans every cell across shards; a cleared cell drops out (its lww
%% state interprets to the empty value, surfaced as a non-binary state).
list_scans() ->
    {Db, T} = open(list_scan, false),
    try
        ok = bondy_db:apply(
            T, <<"r">>, <<"a">>, {set, bondy_db:tick(T), <<"va">>}
        ),
        ok = bondy_db:apply(
            T, <<"r">>, <<"b">>, {set, bondy_db:tick(T), <<"vb">>}
        ),
        ok = bondy_db:apply(
            T, <<"r">>, <<"c">>, {set, bondy_db:tick(T), <<"vc">>}
        ),
        {ok, Live0} = bondy_db:list(T, <<"r">>),
        ?assertEqual(
            [{<<"a">>, <<"va">>}, {<<"b">>, <<"vb">>}, {<<"c">>, <<"vc">>}],
            live(Live0)
        ),
        %% Clear one key — it must drop out of the scan.
        ok = bondy_db:apply(T, <<"r">>, <<"b">>, {clear, bondy_db:tick(T)}),
        {ok, Live1} = bondy_db:list(T, <<"r">>),
        ?assertEqual(
            [{<<"a">>, <<"va">>}, {<<"c">>, <<"vc">>}], live(Live1)
        )
    after
        ok = bondy_db:close(Db)
    end.

%% The ergonomic API: the short-form ops carry no caller HLC and arbitrary term
%% values; the substrate stamps the write HLC and serialises the term. A read
%% returns the decoded value paired with its HLC; `clear` is non-terminal.
short_form_ops() ->
    {Db, T} = open(short_form, false),
    try
        ok = bondy_db:apply(T, <<"r">>, <<"k">>, {set, #{name => <<"alice">>}}),
        ?assertMatch(
            {ok, {#{name := <<"alice">>}, _Hlc}},
            bondy_db:read(T, <<"r">>, <<"k">>)
        ),
        %% clear (short form) removes the cell.
        ok = bondy_db:apply(T, <<"r">>, <<"k">>, clear),
        ?assertEqual({error, not_found}, bondy_db:read(T, <<"r">>, <<"k">>)),
        %% A later set reanimates it — with a different term type.
        ok = bondy_db:apply(T, <<"r">>, <<"k">>, {set, 42}),
        ?assertMatch({ok, {42, _Hlc}}, bondy_db:read(T, <<"r">>, <<"k">>))
    after
        ok = bondy_db:close(Db)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

open(Name, Publish) ->
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 4,
        fold_module => lww_register
    }),
    {ok, T} = bondy_db:open_table(Db, items, #{
        fold_module => lww_register,
        crdt_module => ?CRDT,
        publish => Publish
    }),
    {Db, T}.

%% Keep only live (binary-valued) cells as {Key, Value}, sorted by key.
live(Cells) ->
    lists:sort([{K, V} || {K, V, _Hlc} <- Cells, is_binary(V)]).
