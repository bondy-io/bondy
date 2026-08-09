%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% The tier_2 stamp-site context guard on a **fused** oplog instance — the
%% ephemeral single-process writer that has no separate applier.
%% `bondy_oplog_registry:applier_pid/1` is permanently `undefined` for a fused
%% instance, so a tier_2 write routing `apply_with_context/4` through the
%% applier would fail with `{error, {instance_unavailable, _}}` for ever — not
%% a transient race, a dead end. `bondy_oplog_instance:cell_context/3` answers
%% the same query in-process, guarded by the same `bondy_oplog_ctx_guard` the
%% applier uses, so this file is the fused mirror of
%% `bondy_db_tier2_stamp_guard_test.erl`: same two scenarios, same assertions,
%% only `open_db/1` differs (`fused => true`).
-module(bondy_db_tier2_stamp_guard_fused_test).

-include_lib("eunit/include/eunit.hrl").

-define(MV, bondy_oplog_crdt_mv_register).
-define(R, <<"r">>).
-define(K, <<"k">>).

%% =============================================================================
%% Fixture
%% =============================================================================

stamp_guard_fused_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"monotone sequential writes are not refused (no false positive)",
                fun monotone_writes_pass/0},
            {"a regressed cell context refuses the write + telemeters",
                fun regression_is_refused/0}
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

%% The guard sits on the hot stamp path; a correct, monotone context must
%% pass it untouched. Eight sequential same-cell writes each advance the
%% context, so none regresses — all succeed and collapse to the last.
monotone_writes_pass() ->
    {Db, _O} = open_db(t2guard_fused_mono),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    lists:foreach(
        fun(N) ->
            V = <<"v", (integer_to_binary(N))/binary>>,
            ?assertEqual(ok, bondy_db:apply(T, ?R, ?K, {set, V}))
        end,
        lists:seq(1, 8)
    ),
    ?assertEqual({ok, [<<"v8">>], read_hlc}, norm(bondy_db:read(T, ?R, ?K))),
    ok = bondy_db:close(Db).

%% Induce a real in-process durable-state loss: after a couple of writes,
%% delete the cell's projection entry (the stamp reads its context from
%% there) while the fused instance still holds the prior high-water. The
%% next same-origin write would re-mint a used dot and fork; the guard
%% refuses it. See `bondy_db_tier2_stamp_guard_test:regression_is_refused/0`
%% for the two-writes-before-the-wipe rationale — identical here.
regression_is_refused() ->
    {Db, _O} = open_db(t2guard_fused_regress),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply(T, ?R, ?K, {set, <<"v1">>}),
    ok = bondy_db:apply(T, ?R, ?K, {set, <<"v2">>}),
    ?assertEqual({ok, [<<"v2">>], read_hlc}, norm(bondy_db:read(T, ?R, ?K))),

    ok = delete_projection_cell(T, ?R, ?K),

    Bucket = atom_to_binary(items, utf8),
    CellKey = <<?R/binary, 0, ?K/binary>>,
    Ref = attach_regression_telemetry(),
    try
        ?assertEqual(
            {error, {context_regression, Bucket, CellKey}},
            bondy_db:apply(T, ?R, ?K, {set, <<"v3">>})
        ),
        ?assertEqual({telemetered, Bucket, CellKey}, await_regression_event())
    after
        detach_regression_telemetry(Ref)
    end,
    ok = bondy_db:close(Db).

%% =============================================================================
%% Helpers
%% =============================================================================

open_db(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => ?MV,
        fused => true,
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

delete_projection_cell(T, Realm, Key) ->
    NS = maps:get(namespace, bondy_db:info(T)),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    Adapter = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    Handle = bondy_oplog_core_registry:entry_projection_handle(Entry),
    Bucket = atom_to_binary(items, utf8),
    CellKey = <<Realm/binary, 0, Key/binary>>,
    Adapter:delete(Handle, Bucket, CellKey).

attach_regression_telemetry() ->
    Ref = {?MODULE, erlang:unique_integer()},
    Self = self(),
    ok = telemetry:attach(
        Ref,
        [bondy_oplog, applier, context_regression],
        fun(_Event, _Meas, Meta, _) ->
            Self ! {ctx_regression, maps:get(bucket, Meta), maps:get(key, Meta)}
        end,
        undefined
    ),
    Ref.

detach_regression_telemetry(Ref) ->
    telemetry:detach(Ref).

await_regression_event() ->
    receive
        {ctx_regression, B, K} -> {telemetered, B, K}
    after 1000 ->
        no_telemetry
    end.

norm({ok, {V, _Hlc}}) -> {ok, V, read_hlc};
norm(Other) -> Other.
