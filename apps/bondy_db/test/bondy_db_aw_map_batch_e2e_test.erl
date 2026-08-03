%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end tests for packed multi-command writes to a single Map cell:
%% `bondy_db:apply_batch/4` and the `map_update/4` sugar over the native
%% tier_2 add-wins map (`bondy_oplog_crdt_aw_map`).
%%
%% A batch of field commands is packed into ONE `{batch, Ops}` event — one
%% WAL entry, one MST entry, one projection read-modify-write — and expanded
%% at the CRDT seam (`bondy_oplog_crdt_commutative:apply_op/5`). All commands
%% share one dot + one observed context, so the batch is one atomic,
%% mutually-concurrent causal unit. These tests exercise the real substrate
%% seams the pure unit/PropEr tests cannot:
%%
%%   - the multi-field value materialises through one apply,
%%   - the `[put K, rmv K]` add-wins caveat under the shared context,
%%   - cross-replica convergence of a batch event against single ops,
%%   - the `map_update/4` declarative sugar, and
%%   - the not-batchable guard on a counter table.

-module(bondy_db_aw_map_batch_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(AW, bondy_oplog_crdt_aw_map).

%% =============================================================================
%% Fixture
%% =============================================================================

aw_map_batch_e2e_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"batch writes several fields in one apply",
                fun batch_multi_field/0},
            {"map_update sugar puts and removes fields",
                fun map_update_sugar/0},
            {"put+rmv of the same field in one batch is add-wins",
                fun batch_atomic_put_rmv_same_field/0},
            {"empty batch is a no-op", fun empty_batch_noop/0},
            {"unknown map_update key is rejected", fun unknown_map_edit_key/0},
            {"counter table refuses apply_batch", fun counter_not_batchable/0},
            {"duplicate same-key nested sub-ops in one batch are rejected",
                fun duplicate_nested_subop_rejected/0},
            {"a batch event converges with concurrent single ops",
                {timeout, 30, fun batch_converges_with_single/0}}
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

%% =============================================================================
%% Tests
%% =============================================================================

%% A single batch of three field commands materialises every field — one
%% packed event, one read-modify-write of the cell.
batch_multi_field() ->
    {Db, _O} = open_db(awmapb_multi),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply_batch(T, <<"r">>, <<"c">>, [
        {put, <<"name">>, <<"alice">>},
        {put, <<"age">>, 30},
        %% remove of an absent field is a harmless no-op in the same batch
        {rmv, <<"tmp">>}
    ]),
    ?assertEqual(
        {ok, #{<<"name">> => [<<"alice">>], <<"age">> => [30]}, read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"c">>))
    ),
    ok = bondy_db:close(Db).

%% The declarative `#{put => ..., rmv => ...}` sugar: seed a map, then a
%% single map_update overwrites one field and removes another.
map_update_sugar() ->
    {Db, _O} = open_db(awmapb_sugar),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply_batch(T, <<"r">>, <<"c">>, [
        {put, <<"name">>, <<"alice">>},
        {put, <<"tmp">>, <<"x">>}
    ]),
    ok = bondy_db:map_update(T, <<"r">>, <<"c">>, #{
        put => #{<<"name">> => <<"bob">>},
        rmv => [<<"tmp">>]
    }),
    ?assertEqual(
        {ok, #{<<"name">> => [<<"bob">>]}, read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"c">>))
    ),
    ok = bondy_db:close(Db).

%% A `{put, K, V}` and a `{rmv, K}` packed in ONE batch share one dot and
%% one (pre-batch) observed context, so the remove does not observe the
%% put: add-wins, the put survives.
batch_atomic_put_rmv_same_field() ->
    {Db, _O} = open_db(awmapb_atomic),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply_batch(T, <<"r">>, <<"c">>, [
        {put, <<"k">>, <<"v">>},
        {rmv, <<"k">>}
    ]),
    ?assertEqual(
        {ok, #{<<"k">> => [<<"v">>]}, read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"c">>))
    ),
    ok = bondy_db:close(Db).

%% An empty op list applies nothing and never reaches the WAL.
empty_batch_noop() ->
    {Db, _O} = open_db(awmapb_empty),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ?assertEqual(ok, bondy_db:apply_batch(T, <<"r">>, <<"c">>, [])),
    ?assertEqual({error, not_found}, bondy_db:read(T, <<"r">>, <<"c">>)),
    ok = bondy_db:close(Db).

%% A top-level edit key other than `put`/`rmv` is rejected before any write.
unknown_map_edit_key() ->
    {Db, _O} = open_db(awmapb_badkey),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ?assertMatch(
        {error, {unknown_map_edit_keys, [bogus]}},
        bondy_db:map_update(T, <<"r">>, <<"c">>, #{bogus => 1})
    ),
    ok = bondy_db:close(Db).

%% A pn_counter table is not batchable (its ops dedup by the event Seq), so
%% apply_batch refuses it rather than silently collapsing the increments.
counter_not_batchable() ->
    Db = open_counter_db(awmapb_counter),
    {ok, T} = bondy_db:open_table(Db, counters, #{}),
    ?assertMatch(
        {error, {not_batchable, bondy_oplog_crdt_pn_counter}},
        bondy_db:apply_batch(T, <<"r">>, <<"c">>, [{inc, 1}, {inc, 2}])
    ),
    ok = bondy_db:close(Db).

%% A batch is ONE dot and nested sub-ops accumulate BY dot, so two
%% sub-ops on the same key under one packed identity would silently
%% collapse to the last — both batch entry points reject the batch
%% before the WAL append instead.
duplicate_nested_subop_rejected() ->
    {Db, _O} = open_db(awmapb_dup),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    PN = bondy_oplog_crdt_pn_counter,
    Dup = [
        {apply, <<"hits">>, PN, {inc, 1}},
        {apply, <<"hits">>, PN, {inc, 2}}
    ],
    ?assertEqual(
        {error, {duplicate_batch_subop, [<<"hits">>]}},
        bondy_db:apply_batch(T, <<"r">>, <<"c">>, Dup)
    ),
    ?assertEqual(
        {error, {duplicate_batch_subop, [<<"hits">>]}},
        bondy_db:apply_batch_async(T, <<"r">>, <<"c">>, Dup)
    ),
    %% Nothing was written — the cell does not exist.
    ?assertEqual({error, not_found}, bondy_db:read(T, <<"r">>, <<"c">>)),

    %% Distinct keys (and flat forms mixed in) remain batchable: one
    %% sub-op per key is exactly the intended shape.
    ok = bondy_db:apply_batch(T, <<"r">>, <<"c">>, [
        {apply, <<"hits">>, PN, {inc, 3}},
        {apply, <<"misses">>, PN, {inc, 1}},
        {put, <<"name">>, <<"alice">>}
    ]),
    ?assertEqual(
        {ok,
            #{
                <<"hits">> => 3,
                <<"misses">> => 1,
                <<"name">> => [<<"alice">>]
            },
            read_hlc},
        normalise(bondy_db:read(T, <<"r">>, <<"c">>))
    ),
    ok = bondy_db:close(Db).

%% Replica A writes two fields as one batch (one dot); replica B writes the
%% same first field as a single op (a distinct, concurrent dot). After a
%% bidirectional sync both replicas converge: the shared field carries both
%% values as siblings, the batch-only field survives, and the MST roots are
%% equal (the batch replicated as one opaque event).
batch_converges_with_single() ->
    {DbA, _Oa} = open_db(awmapb_conv_a),
    {DbB, _Ob} = open_db(awmapb_conv_b),
    {ok, Ta} = bondy_db:open_table(DbA, items, #{}),
    {ok, Tb} = bondy_db:open_table(DbB, items, #{}),
    Ia = instance_of(Ta),
    Ib = instance_of(Tb),
    ok = bondy_db:apply_batch(Ta, <<"r">>, <<"c">>, [
        {put, <<"k1">>, <<"a1">>},
        {put, <<"k2">>, <<"a2">>}
    ]),
    ok = bondy_db:apply(Tb, <<"r">>, <<"c">>, {put, <<"k1">>, <<"b1">>}),
    {ok, _} = bondy_oplog:sync(Ia, Ib),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    ok = bondy_oplog:await_apply(Ia),
    ok = bondy_oplog:await_apply(Ib),
    ok = replay(Ia),
    ok = replay(Ib),
    Expected = #{<<"k1">> => [<<"a1">>, <<"b1">>], <<"k2">> => [<<"a2">>]},
    {ok, {Va, _}} = bondy_db:read(Ta, <<"r">>, <<"c">>),
    {ok, {Vb, _}} = bondy_db:read(Tb, <<"r">>, <<"c">>),
    ?assertEqual(Expected, Va),
    ?assertEqual(Expected, Vb),
    ?assertEqual(bondy_oplog:root_hash(Ia), bondy_oplog:root_hash(Ib)),
    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

%% =============================================================================
%% Helpers
%% =============================================================================

open_db(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => ?AW,
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

open_counter_db(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => pn_counter,
        oplog_instance_opts => #{origin => Origin}
    }),
    Db.

instance_of(Table) ->
    #{0 := InstanceId} = maps:get(instance_ids, Table),
    InstanceId.

replay(InstanceId) ->
    Pid = bondy_oplog_registry:applier_pid(InstanceId),
    bondy_oplog_applier:replay_cell_events_sync(Pid).

normalise({ok, {V, _Hlc}}) -> {ok, V, read_hlc};
normalise(Other) -> Other.
