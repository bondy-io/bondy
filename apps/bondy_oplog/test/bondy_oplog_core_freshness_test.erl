%% =============================================================================
%% Tests for the freshness family (`MST_DB_DESIGN.md` §11, wired in D7):
%% `ensure_fresh/2`, `ensure_fresh_for_keys/2`, `freshness/1`, plus the
%% `bump_ae/3` / `last_ae_at/3` registry primitives the family rests on.
%% =============================================================================

-module(bondy_oplog_core_freshness_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

freshness_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun ensure_fresh_infinity_skips_check/0,
        fun ensure_fresh_empty_namespaces_is_ok/0,
        fun ensure_fresh_unknown_namespace_is_vacuously_fresh/0,
        fun ensure_fresh_unbumped_shard_is_stale/0,
        fun ensure_fresh_freshly_bumped_shard_is_ok/0,
        fun ensure_fresh_reports_all_stale_namespaces/0,
        fun ensure_fresh_partial_stale_only_lists_failing_ns/0,
        fun ensure_fresh_for_keys_only_checks_touched_shards/0,
        fun ensure_fresh_for_keys_infinity_skips/0,
        fun freshness_returns_per_shard_lag_map/0,
        fun freshness_unknown_namespace_is_empty_map/0,
        fun bump_ae_unknown_shard_returns_not_found/0,
        fun bump_ae_with_explicit_now_writes_supplied_timestamp/0,
        fun last_ae_at_unknown_shard_returns_not_found/0,
        fun owner_down_removes_registration/0,
        fun re_register_demonitors_previous_owner/0,
        fun explicit_owner_decouples_from_caller/0,
        fun register_missing_required_field_returns_error/0,
        fun registry_crash_loses_all_registrations/0,
        fun owner_down_does_not_call_adapter_close/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

ensure_fresh_infinity_skips_check() ->
    %% No registrations; `infinity` is the cheapest path and returns
    %% `ok` without ever touching the registry.
    ?assertEqual(ok, bondy_oplog_core:ensure_fresh([nonexistent], infinity)).

ensure_fresh_empty_namespaces_is_ok() ->
    ?assertEqual(ok, bondy_oplog_core:ensure_fresh([], 100)).

ensure_fresh_unknown_namespace_is_vacuously_fresh() ->
    %% A namespace with zero registered shards is "vacuously fresh"
    %% per the design's quantifier semantics — no shard can be stale
    %% if there are no shards. Documented gap; flagged for D10.
    NS = mk_ns(),
    ?assertEqual(ok, bondy_oplog_core:ensure_fresh([NS], 100)).

ensure_fresh_unbumped_shard_is_stale() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    ?assertEqual(
        {stale, [NS]},
        bondy_oplog_core:ensure_fresh([NS], 100)
    ),
    teardown_shard(Setup).

ensure_fresh_freshly_bumped_shard_is_ok() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    ok = bondy_oplog_core_registry:bump_ae(NS, primary, 0),
    ?assertEqual(ok, bondy_oplog_core:ensure_fresh([NS], 1_000_000)),
    teardown_shard(Setup).

ensure_fresh_reports_all_stale_namespaces() ->
    NS1 = mk_ns(),
    NS2 = mk_ns(),
    {S1, _} = setup_shard(NS1, primary, 0, 1, lww_register),
    {S2, _} = setup_shard(NS2, primary, 0, 1, lww_register),
    %% Neither bumped. Both should appear in the stale list, sorted.
    ?assertEqual(
        {stale, lists:sort([NS1, NS2])},
        bondy_oplog_core:ensure_fresh([NS1, NS2], 100)
    ),
    teardown_shard(S1),
    teardown_shard(S2).

ensure_fresh_partial_stale_only_lists_failing_ns() ->
    NS_fresh = mk_ns(),
    NS_stale = mk_ns(),
    {SF, _} = setup_shard(NS_fresh, primary, 0, 1, lww_register),
    {SS, _} = setup_shard(NS_stale, primary, 0, 1, lww_register),
    ok = bondy_oplog_core_registry:bump_ae(NS_fresh, primary, 0),
    ?assertEqual(
        {stale, [NS_stale]},
        bondy_oplog_core:ensure_fresh([NS_fresh, NS_stale], 1_000_000)
    ),
    teardown_shard(SF),
    teardown_shard(SS).

ensure_fresh_for_keys_only_checks_touched_shards() ->
    %% Two shards in the same NS. Bump only shard 0. A read against
    %% a key that hashes to shard 0 must succeed; against shard 1 must
    %% fail. We pin both branches by directly addressing each shard
    %% via the `shard => N` override in `range/4` for setup, and the
    %% per-key path via crafted keys.
    NS = mk_ns(),
    {S0, _} = setup_shard(NS, primary, 0, 2, lww_register),
    {S1, _} = setup_shard(NS, primary, 1, 2, lww_register),
    ok = bondy_oplog_core_registry:bump_ae(NS, primary, 0),
    %% Find one key per shard.
    K0 = find_key_for_shard(NS, primary, 0),
    K1 = find_key_for_shard(NS, primary, 1),
    %% Keys hitting only shard 0 are fresh.
    ?assertEqual(
        ok,
        bondy_oplog_core:ensure_fresh_for_keys(
            [{NS, primary, <<>>, K0}],
            1_000_000
        )
    ),
    %% Keys hitting shard 1 surface NS as stale.
    ?assertEqual(
        {stale, [NS]},
        bondy_oplog_core:ensure_fresh_for_keys(
            [{NS, primary, <<>>, K1}],
            1_000_000
        )
    ),
    teardown_shard(S0),
    teardown_shard(S1).

ensure_fresh_for_keys_infinity_skips() ->
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    ?assertEqual(
        ok,
        bondy_oplog_core:ensure_fresh_for_keys(
            [{NS, primary, <<>>, <<"k">>}],
            infinity
        )
    ),
    teardown_shard(Setup).

freshness_returns_per_shard_lag_map() ->
    NS = mk_ns(),
    {S0, _} = setup_shard(NS, primary, 0, 2, lww_register),
    {S1, _} = setup_shard(NS, primary, 1, 2, lww_register),
    ok = bondy_oplog_core_registry:bump_ae(NS, primary, 0),
    ok = bondy_oplog_core_registry:bump_ae(NS, primary, 1),
    Map = bondy_oplog_core:freshness(NS),
    ?assertEqual(2, map_size(Map)),
    ?assert(maps:is_key({primary, 0}, Map)),
    ?assert(maps:is_key({primary, 1}, Map)),
    %% Both lags must be small (well below 1 second on a healthy box).
    ?assert(maps:get({primary, 0}, Map) < 1_000),
    ?assert(maps:get({primary, 1}, Map) < 1_000),
    teardown_shard(S0),
    teardown_shard(S1).

freshness_unknown_namespace_is_empty_map() ->
    NS = mk_ns(),
    ?assertEqual(#{}, bondy_oplog_core:freshness(NS)).

bump_ae_unknown_shard_returns_not_found() ->
    NS = mk_ns(),
    ?assertEqual(not_found, bondy_oplog_core_registry:bump_ae(NS, primary, 0)).

bump_ae_with_explicit_now_writes_supplied_timestamp() ->
    %% `bump_ae/4` lets the applier reuse one monotonic timestamp across
    %% a batch of shards.
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    Now = erlang:monotonic_time(millisecond) - 5_000,
    ok = bondy_oplog_core_registry:bump_ae(NS, primary, 0, Now),
    ?assertEqual(Now, bondy_oplog_core_registry:last_ae_at(NS, primary, 0)),
    teardown_shard(Setup).

last_ae_at_unknown_shard_returns_not_found() ->
    NS = mk_ns(),
    ?assertEqual(
        not_found, bondy_oplog_core_registry:last_ae_at(NS, primary, 0)
    ).

owner_down_removes_registration() ->
    %% A shard registered by a process that subsequently exits must be
    %% torn down by the registry's DOWN handler — otherwise readers
    %% would dispatch into dead handles.
    NS = mk_ns(),
    Parent = self(),
    Owner = spawn(fun() ->
        {ok, CH} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
        {ok, PH} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
        OV = bondy_oplog_db_overlay:new(),
        ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
            shard_count => 1,
            cache_adapter => bondy_oplog_cache_ets,
            cache_handle => CH,
            projection_adapter => bondy_oplog_projection_ets,
            projection_handle => PH,
            overlay => OV,
            fold_module => lww_register
        }),
        Parent ! registered,
        receive
            go_down -> ok
        end
    end),
    Mon = erlang:monitor(process, Owner),
    receive
        registered -> ok
    end,
    ?assertMatch({ok, _}, bondy_oplog_core_registry:lookup(NS, primary, 0)),
    Owner ! go_down,
    receive
        {'DOWN', Mon, process, Owner, _} -> ok
    end,
    %% Sync with the registry to let it process the DOWN.
    _ = sys:get_state(bondy_oplog_core_registry),
    ?assertEqual(not_found, bondy_oplog_core_registry:lookup(NS, primary, 0)).

explicit_owner_decouples_from_caller() ->
    %% Register on behalf of a different process: the row's lifetime is
    %% bound to the explicit Owner, not to the calling process.
    NS = mk_ns(),
    Parent = self(),
    Owner = spawn(fun() ->
        Parent ! ready,
        receive
            go_down -> ok
        end
    end),
    OwnerMon = erlang:monitor(process, Owner),
    receive
        ready -> ok
    end,
    %% Register from the test process, with Owner as the registry's
    %% monitor target.
    {ok, CH} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, PH} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    OV = bondy_oplog_db_overlay:new(),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => CH,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => PH,
        overlay => OV,
        fold_module => lww_register,
        owner => Owner
    }),
    %% Test process is still alive; row exists.
    ?assertMatch({ok, _}, bondy_oplog_core_registry:lookup(NS, primary, 0)),
    %% Kill Owner — the registry must tear the row down.
    Owner ! go_down,
    receive
        {'DOWN', OwnerMon, process, Owner, _} -> ok
    end,
    _ = sys:get_state(bondy_oplog_core_registry),
    ?assertEqual(not_found, bondy_oplog_core_registry:lookup(NS, primary, 0)),
    ok = bondy_oplog_cache_ets:close(CH),
    ok = bondy_oplog_projection_ets:close(PH),
    ok = bondy_oplog_db_overlay:delete(OV).

register_missing_required_field_returns_error() ->
    %% Bad config must surface a clean error — not crash the registry
    %% and lose every other registration on the node.
    NS = mk_ns(),
    Config = #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets
        %% intentionally omit cache_handle and other required fields
    },
    ?assertMatch(
        {error, {missing_required_field, _}},
        bondy_oplog_core_registry:register(NS, primary, 0, Config)
    ),
    %% Registry is still alive and serving.
    ?assert(is_pid(whereis(bondy_oplog_core_registry))).

registry_crash_loses_all_registrations() ->
    %% Pin the documented operational gap: a registry crash wipes all
    %% in-memory state. Owners must re-register; the substrate does not
    %% recover automatically.
    NS = mk_ns(),
    {Setup, _} = setup_shard(NS, primary, 0, 1, lww_register),
    ?assertMatch({ok, _}, bondy_oplog_core_registry:lookup(NS, primary, 0)),
    OldPid = whereis(bondy_oplog_core_registry),
    OldMon = erlang:monitor(process, OldPid),
    exit(OldPid, kill),
    receive
        {'DOWN', OldMon, process, OldPid, killed} -> ok
    end,
    %% Wait for the supervisor to restart the registry.
    ok = wait_for_registry_restart(OldPid, 50),
    %% Previously registered shard is gone — no recovery.
    ?assertEqual(not_found, bondy_oplog_core_registry:lookup(NS, primary, 0)),
    %% Re-registering succeeds against the fresh table.
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => maps:get(cache_adapter, Setup, bondy_oplog_cache_ets),
        cache_handle => maps:get(cache_handle, Setup),
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => maps:get(projection, Setup),
        overlay => maps:get(overlay, Setup),
        fold_module => lww_register
    }),
    ?assertMatch({ok, _}, bondy_oplog_core_registry:lookup(NS, primary, 0)),
    teardown_shard(Setup).

owner_down_does_not_call_adapter_close() ->
    %% Contract pin: when the registry tears down an entry because the
    %% owner died, it MUST NOT call `close/1` on the cache adapter.
    %% Adapters that own external resources are responsible for their
    %% own owner-monitoring (see `bondy_oplog_cache_adapter` docstring).
    NS = mk_ns(),
    Counter = bondy_oplog_cache_counting:new_counter(),
    Parent = self(),
    Owner = spawn(fun() ->
        {ok, CH} = bondy_oplog_cache_counting:init(
            NS,
            primary,
            0,
            #{counter => Counter}
        ),
        {ok, PH} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
        OV = bondy_oplog_db_overlay:new(),
        ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
            shard_count => 1,
            cache_adapter => bondy_oplog_cache_counting,
            cache_handle => CH,
            projection_adapter => bondy_oplog_projection_ets,
            projection_handle => PH,
            overlay => OV,
            fold_module => lww_register
        }),
        Parent ! registered,
        receive
            go_down -> ok
        end
    end),
    Mon = erlang:monitor(process, Owner),
    receive
        registered -> ok
    end,
    ?assertEqual(0, bondy_oplog_cache_counting:close_count(Counter)),
    Owner ! go_down,
    receive
        {'DOWN', Mon, process, Owner, _} -> ok
    end,
    _ = sys:get_state(bondy_oplog_core_registry),
    %% Row removed by the registry on DOWN.
    ?assertEqual(not_found, bondy_oplog_core_registry:lookup(NS, primary, 0)),
    %% BUT close was NOT called — the substrate does not invoke close
    %% on adapters when owners die. ETS adapters self-clean via Erlang
    %% GC; other adapters must monitor internally.
    ?assertEqual(0, bondy_oplog_cache_counting:close_count(Counter)),
    ok = bondy_oplog_cache_counting:delete_counter(Counter).

wait_for_registry_restart(OldPid, 0) ->
    case whereis(bondy_oplog_core_registry) of
        New when is_pid(New), New =/= OldPid -> ok;
        _ -> {error, timeout}
    end;
wait_for_registry_restart(OldPid, N) ->
    case whereis(bondy_oplog_core_registry) of
        New when is_pid(New), New =/= OldPid ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_registry_restart(OldPid, N - 1)
    end.

re_register_demonitors_previous_owner() ->
    %% Re-registering the same shard must demonitor the old owner so
    %% a later DOWN from that owner does NOT remove the new entry.
    NS = mk_ns(),
    Parent = self(),
    Owner1 = spawn(fun() ->
        {ok, CH} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
        {ok, PH} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
        OV = bondy_oplog_db_overlay:new(),
        ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
            shard_count => 1,
            cache_adapter => bondy_oplog_cache_ets,
            cache_handle => CH,
            projection_adapter => bondy_oplog_projection_ets,
            projection_handle => PH,
            overlay => OV,
            fold_module => lww_register
        }),
        Parent ! registered1,
        receive
            go_down -> ok
        end
    end),
    Mon1 = erlang:monitor(process, Owner1),
    receive
        registered1 -> ok
    end,
    %% Re-register from this process (the test process). This must
    %% demonitor Owner1's reference so its exit no longer takes down
    %% the row.
    {ok, CH2} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, PH2} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    OV2 = bondy_oplog_db_overlay:new(),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => CH2,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => PH2,
        overlay => OV2,
        fold_module => lww_register
    }),
    Owner1 ! go_down,
    receive
        {'DOWN', Mon1, process, Owner1, _} -> ok
    end,
    _ = sys:get_state(bondy_oplog_core_registry),
    %% Registration must still exist, owned by us.
    ?assertMatch({ok, _}, bondy_oplog_core_registry:lookup(NS, primary, 0)),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok = bondy_oplog_cache_ets:close(CH2),
    ok = bondy_oplog_projection_ets:close(PH2),
    ok = bondy_oplog_db_overlay:delete(OV2).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_ns() ->
    list_to_atom(
        "mst_db_fresh_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

%% Generate keys until we find one that hashes to the wanted shard.
find_key_for_shard(NS, Index, WantedShard) ->
    find_key_for_shard(NS, Index, WantedShard, 0).

find_key_for_shard(NS, Index, WantedShard, N) when N < 10_000 ->
    K = integer_to_binary(N),
    case bondy_oplog_core:shard_for(NS, Index, K) of
        {ok, WantedShard} -> K;
        _ -> find_key_for_shard(NS, Index, WantedShard, N + 1)
    end;
find_key_for_shard(_, _, _, _) ->
    erlang:error(no_key_for_shard).

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
