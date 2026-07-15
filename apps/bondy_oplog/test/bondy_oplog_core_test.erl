%% =============================================================================
%% Tests for `bondy_oplog_core:read/3` and `write_through/4` against a
%% reference (ETS cache, in-memory projection adapter, overlay) wiring.
%%
%% Pins: shard_for/3, registry lookup, cache hit path, slow read with
%% projection only / overlay only / both, write-through coherence, and
%% the "not registered" / "no shards" error returns.
%% =============================================================================

-module(bondy_oplog_core_test).

-include_lib("eunit/include/eunit.hrl").

%% Default bucket the read/3 backward-compat alias substitutes.
-define(B, <<>>).

%% Per-test setup creates a single (NS, primary, 0) shard backed by the
%% reference ETS cache + the in-memory projection adapter + a fresh
%% overlay, then registers it with bondy_oplog_core_registry.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    %% Each test tears down its own shard via teardown_shard/1; the
    %% registry table drops on app shutdown.
    ok.

read_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun shard_for_returns_no_shards_when_unregistered/0,
        fun read_returns_shard_not_registered_for_unknown_shard/0,
        fun read_honours_shard_override/0,
        fun read_returns_undefined_when_projection_and_overlay_empty/0,
        fun read_returns_projection_value_when_no_overlay/0,
        fun read_merges_overlay_with_projection/0,
        fun read_hits_cache_after_first_slow_read/0,
        fun cache_returns_value_unchanged_when_set/0,
        fun write_through_invalidates_existing_cache_entry/0,
        fun write_through_skips_when_key_not_cached/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

shard_for_returns_no_shards_when_unregistered() ->
    NS = mk_ns(),
    ?assertEqual(
        {error, no_shards}, bondy_oplog_core:shard_for(NS, primary, <<"k">>)
    ).

read_returns_shard_not_registered_for_unknown_shard() ->
    %% Register one shard for NS/primary; then read a key that lands on
    %% a different (non-existent) shard. We force this by registering
    %% with shard_count=4 but only putting shard 0 in the registry.
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 4, lww_register),
    %% Find a key whose phash2 lands on shard 1..3.
    Key = pick_key_for_shard(NS, primary, 1),
    ?assertEqual(
        {error, shard_not_registered},
        bondy_oplog_core:read(NS, primary, Key)
    ),
    teardown_shard(Setup).

read_honours_shard_override() ->
    %% G-1: point reads honour an explicit `shard` override, mirroring the
    %% range path. Register ONLY shard 0 (of 4) and materialise a cell
    %% there. Pick a Key that hashes to shard 1 (not 0): without the
    %% override the read hashes to the unregistered shard 1 → error; with
    %% `shard => 0` it resolves to the registered shard and returns the
    %% value. This proves the override forces a shard the hash would never
    %% select — the invariant a `shard_by => realm` table relies on.
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0, 4, lww_register),
    Key = pick_key_for_shard(NS, primary, 1),
    Frame = bondy_oplog_test_helpers:frame(
        lww_register, {set, <<"v">>, 42}, 42
    ),
    ok = bondy_oplog_projection_ets:put_batch(PH, [{?B, Key, Frame}]),
    %% No override: hashes to shard 1 (unregistered).
    ?assertEqual(
        {error, shard_not_registered},
        bondy_oplog_core:read(NS, primary, Key)
    ),
    %% Override to shard 0 (registered): resolves there, returns the value.
    ?assertEqual(
        {<<"v">>, 42},
        bondy_oplog_core:read(NS, primary, ?B, Key, #{shard => 0})
    ),
    teardown_shard(Setup).

read_returns_undefined_when_projection_and_overlay_empty() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    %% lww_register's initial_value() is `undefined` → slow_read returns
    %% `undefined` and skips the cache populate.
    ?assertEqual(undefined, bondy_oplog_core:read(NS, primary, <<"absent">>)),
    teardown_shard(Setup).

read_returns_projection_value_when_no_overlay() ->
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0, 1, lww_register),
    %% Materialise a cell at HLC=42 with state {set, <<"v">>, 42};
    %% lww_register's to_value/1 unwraps to the bare value.
    State = {set, <<"v">>, 42},
    Frame = bondy_oplog_test_helpers:frame(lww_register, State, 42),
    ok = bondy_oplog_projection_ets:put_batch(PH, [{?B, <<"k">>, Frame}]),
    ?assertEqual(
        {<<"v">>, 42},
        bondy_oplog_core:read(NS, primary, <<"k">>)
    ),
    teardown_shard(Setup).

read_merges_overlay_with_projection() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, overlay := OV}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    %% Projection at HLC=10 → state {set, <<"old">>, 10}.
    OldFrame = bondy_oplog_test_helpers:frame(
        lww_register, {set, <<"old">>, 10}, 10
    ),
    ok = bondy_oplog_projection_ets:put_batch(PH, [{?B, <<"k">>, OldFrame}]),
    %% Overlay carries a newer event at HLC=20.
    Event = mk_event(20, <<"o">>, 0, {set, 20, <<"new">>}),
    ok = bondy_oplog_db_overlay:insert(OV, ?B, <<"k">>, Event),
    ?assertEqual(
        {<<"new">>, 20},
        bondy_oplog_core:read(NS, primary, <<"k">>)
    ),
    teardown_shard(Setup).

read_hits_cache_after_first_slow_read() ->
    NS = mk_ns(),
    {Setup, #{projection := PH, cache_handle := CH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    Frame = bondy_oplog_test_helpers:frame(
        lww_register, {set, <<"v">>, 7}, 7
    ),
    ok = bondy_oplog_projection_ets:put_batch(PH, [{?B, <<"k">>, Frame}]),
    %% First read: slow path populates the cache with the user-facing value.
    {<<"v">>, 7} = bondy_oplog_core:read(NS, primary, <<"k">>),
    ?assertMatch(
        {ok, {<<"v">>, 7}},
        bondy_oplog_cache_ets:get(CH, ?B, <<"k">>)
    ),
    teardown_shard(Setup).

cache_returns_value_unchanged_when_set() ->
    NS = mk_ns(),
    {Setup, #{cache_handle := CH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    %% Pre-populate the cache directly with a synthetic value; the read
    %% must come back from cache (projection is empty so a slow path
    %% would return `undefined`). After §3.6 the cache stores values
    %% (not states).
    ok = bondy_oplog_cache_ets:put(CH, ?B, <<"k">>, {<<"v">>, 99}),
    ?assertEqual(
        {<<"v">>, 99},
        bondy_oplog_core:read(NS, primary, <<"k">>)
    ),
    teardown_shard(Setup).

write_through_invalidates_existing_cache_entry() ->
    NS = mk_ns(),
    {Setup, #{cache_handle := CH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    %% Pre-populate the cache. After §3.6 the write-through path
    %% invalidates rather than folding (no fold currently exports
    %% `apply_value_delta/2`); the next read repopulates via HEAD.
    ok = bondy_oplog_cache_ets:put(CH, ?B, <<"k">>, {<<"v1">>, 5}),
    Event = mk_event(10, <<"o">>, 0, {set, 10, <<"v2">>}),
    ok = bondy_oplog_core:write_through(NS, primary, <<"k">>, Event),
    ?assertEqual(not_found, bondy_oplog_cache_ets:get(CH, ?B, <<"k">>)),
    teardown_shard(Setup).

write_through_skips_when_key_not_cached() ->
    NS = mk_ns(),
    {Setup, #{cache_handle := CH}} =
        setup_shard(NS, primary, 0, 1, lww_register),
    Event = mk_event(10, <<"o">>, 0, {set, 10, <<"v">>}),
    ok = bondy_oplog_core:write_through(NS, primary, <<"k">>, Event),
    %% Still cold.
    ?assertEqual(not_found, bondy_oplog_cache_ets:get(CH, ?B, <<"k">>)),
    teardown_shard(Setup).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_ns() ->
    list_to_atom(
        "mst_db_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

mk_event(Hlc, Origin, Seq, Op) ->
    K = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(K, Op, undefined).

setup_shard(NS, Index, Shard, ShardCount, Strategy) ->
    {ok, CH} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, PH} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    OV = bondy_oplog_db_overlay:new(),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => ShardCount,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => CH,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => PH,
        overlay => OV,
        fold_module => Strategy
    }),
    Setup = #{
        ns => NS,
        index => Index,
        shard => Shard,
        cache_handle => CH,
        projection => PH,
        overlay => OV
    },
    {Setup, Setup}.

teardown_shard(#{
    ns := NS,
    index := Index,
    shard := Shard,
    cache_handle := CH,
    projection := PH,
    overlay := OV
}) ->
    ok = bondy_oplog_core_registry:unregister(NS, Index, Shard),
    ok = bondy_oplog_cache_ets:close(CH),
    ok = bondy_oplog_projection_ets:close(PH),
    ok = bondy_oplog_db_overlay:delete(OV).

pick_key_for_shard(_NS, _Index, TargetShard) ->
    pick_key_for_shard_loop(TargetShard, 0).

pick_key_for_shard_loop(TargetShard, N) ->
    Key = list_to_binary("k" ++ integer_to_list(N)),
    %% Shard hash uses {Bucket, Key} composite; the read/3 backward-compat
    %% alias substitutes Bucket = <<>>, so match that here.
    case erlang:phash2({?B, Key}, 4) of
        TargetShard -> Key;
        _ -> pick_key_for_shard_loop(TargetShard, N + 1)
    end.
