%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% The tier_2 stamp-site context-regression guard.
%%
%% On the tier_2 write path the substrate reads a cell's current causal
%% context and stamps it into the new event so the origin's next dot
%% strictly succeeds what it already wrote. That is sound only while the
%% context the stamp reads never regresses below what this origin already
%% observed for the cell — otherwise the write re-mints a used dot and the
%% value forks SILENTLY (`bondy_oplog_crdt_mv_register` /
%% `bondy_oplog_crdt_aw_map`, "Convergence preconditions").
%%
%% The guard (`bondy_oplog_applier:stamp_ctx_guard/4`) remembers the
%% highest context it handed out per cell and refuses (loudly, with a
%% `[bondy_oplog, applier, context_regression]` telemetry event) any stamp
%% that regressed below it. This test induces such a regression in process
%% — by deleting the cell's projection entry the stamp reads its context
%% from, while the applier still remembers the prior context — and asserts
%% the next write is refused rather than silently forking, AND that a
%% normal monotone write sequence is NOT a false positive.

-module(bondy_db_tier2_stamp_guard_test).

-include_lib("eunit/include/eunit.hrl").

-define(MV, bondy_oplog_crdt_mv_register).
-define(R, <<"r">>).
-define(K, <<"k">>).

%% =============================================================================
%% Fixture
%% =============================================================================

stamp_guard_test_() ->
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
    {Db, _O} = open_db(t2guard_mono),
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
%% there) while the applier still holds the prior high-water. The next
%% same-origin write would re-mint a used dot and fork; the guard refuses
%% it.
%%
%% Two writes precede the wipe deliberately: a stamp records the context it
%% reads BEFORE that write lands, so the high-water lags one write — after
%% v1+v2 it is the post-v1 context `[{Origin, 1}]`, which an empty
%% (wiped-cell) read regresses below. A single prior write would leave the
%% high-water empty and a wipe-to-empty would be indistinguishable from a
%% legitimate first write (an inherent best-effort limit of the guard).
regression_is_refused() ->
    {Db, _O} = open_db(t2guard_regress),
    {ok, T} = bondy_db:open_table(Db, items, #{}),
    ok = bondy_db:apply(T, ?R, ?K, {set, <<"v1">>}),
    ok = bondy_db:apply(T, ?R, ?K, {set, <<"v2">>}),
    ?assertEqual({ok, [<<"v2">>], read_hlc}, norm(bondy_db:read(T, ?R, ?K))),

    %% Wipe the projection cell the stamp reads its context from. The
    %% applier's per-cell high-water still remembers the prior context, so
    %% the next read of an empty cell context is a regression.
    ok = delete_projection_cell(T, ?R, ?K),

    %% The applier reports a regression at the CELL level — `(Bucket, CellKey)`
    %% — which under the bucket-by-entity-type, realm-folded memory layout is
    %% the entity-type bucket and the `<<Realm,0,Key>>` cell key (the same shape
    %% `shared_shards` reports).
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
        oplog_instance_opts => #{origin => Origin}
    }),
    {Db, Origin}.

%% Memory now buckets a cell by entity type (`bucket_for/3`) and folds the realm
%% into the cell key (G-1), shard 0 (shard_count 1). Reach the shard's projection
%% adapter via the registry and delete the single cell at its real
%% `(EntityType bucket, <<Realm,0,Key>>)` address, simulating an in-process
%% durable-state loss.
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
