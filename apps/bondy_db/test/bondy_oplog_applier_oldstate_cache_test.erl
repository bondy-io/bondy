%% =============================================================================
%% A3 — applier OldValue frame-cache tests for `bondy_oplog_applier`.
%%
%% On the durable stack the applier's per-event OldValue read
%% (`compute_one_cell/11` → projection `get/3`) is the single largest
%% per-event cost. A3 puts a private, write-through cache of the last
%% durable cell frame per `{Bucket, Key}` in front of that read: a hit
%% returns byte-identical `{OldState, OldValue}` to a projection read, so
%% the fold result is unchanged — only the read I/O is removed.
%%
%% The cache is coherent because the applier is the SOLE writer of its
%% shard's primary cells and write-throughs the exact frame it durably
%% wrote (after `put_batch` returns ok), at every live write path
%% (`apply_cell_batch/2` local + `apply_cell_pairs/4` peer/replay).
%%
%% Coverage:
%%   1. Semantic transparency — cache ON yields the SAME final values as
%%      cache OFF for an identical re-write sequence (the core property).
%%   2. The cache is actually exercised — a cross-batch re-read of a key
%%      emits `[bondy_oplog, applier, oldstate_cache]` hits (and OFF emits
%%      none).
%%   3. Write-through coherence — a counter incremented across many
%%      batches folds against the cached prior state and lands on N.
%%   4. Opt validation — bad `oldstate_cache` / `oldstate_cache_max`
%%      rejected at init.
%%   5. The cache primitive — get/put + bounded (coarse-clear) eviction.
%% =============================================================================

-module(bondy_oplog_applier_oldstate_cache_test).

-include_lib("eunit/include/eunit.hrl").

-define(REALM, <<"r1">>).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [catch bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

oldstate_cache_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60, fun cache_on_matches_cache_off/0},
        {timeout, 60, fun cache_emits_hits_on_cross_batch_reread/0},
        {timeout, 60, fun cache_off_emits_no_events/0},
        {timeout, 60, fun counter_coherent_across_batches/0},
        {timeout, 60, fun merge_install_does_not_serve_stale_oldstate/0},
        fun invalid_oldstate_cache_rejected/0,
        fun invalid_oldstate_cache_max_rejected/0,
        fun valid_oldstate_cache_accepted/0,
        fun cache_primitive_get_put_and_bounded/0
    ]}.

%% =============================================================================
%% 1. Semantic transparency
%% =============================================================================

%% The same re-write sequence over a bounded keyset must produce
%% byte-identical final reads whether the cache is on or off — the cache
%% changes latency, never results.
cache_on_matches_cache_off() ->
    Keys = [int_key(I) || I <- lists:seq(1, 8)],
    %% 5 cycles × 8 keys = 40 writes; every key is re-written, so the
    %% second cycle onward reads OldValue the cache would serve.
    Seq = [{K, C} || C <- lists:seq(1, 5), K <- Keys],
    Off = run_lww(lww_off_db, false, Seq, Keys),
    On = run_lww(lww_on_db, true, Seq, Keys),
    ?assertEqual(Off, On),
    %% Sanity: the last cycle won (LWW), so each key reads "<k>-5".
    ?assertEqual(
        lists:sort([{K, <<K/binary, "-5">>} || K <- Keys]),
        On
    ).

%% =============================================================================
%% 2. The cache is exercised (cross-batch hit)
%% =============================================================================

%% Re-reading a key in a LATER applier batch (forced by draining between
%% writes via a read) must take the cache path and emit a hit.
cache_emits_hits_on_cross_batch_reread() ->
    {Db, Sup, Dir} = open_db(hit_db, bondy_oplog_crdt_lww_register, true),
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    K = <<"hotkey">>,
    {Hits, Misses} = with_cache_counter(fun() ->
        write_lww(T, K, <<"v1">>),
        %% Drain v1 (RYOW) so the cache is written through before v2.
        _ = bondy_db:read(T, ?REALM, K),
        write_lww(T, K, <<"v2">>),
        %% This read drains v2's batch; computing v2's frame reads K's
        %% OldValue, which is now a cache hit (cross-batch).
        ?assertMatch({ok, {<<"v2">>, _}}, bondy_db:read(T, ?REALM, K))
    end),
    close_db(Db, Sup, Dir),
    ?assert(Hits >= 1),
    ?assert(Misses >= 1).

%% With the cache OFF the applier emits no `oldstate_cache` events at all.
cache_off_emits_no_events() ->
    {Db, Sup, Dir} = open_db(nohit_db, bondy_oplog_crdt_lww_register, false),
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    K = <<"hotkey">>,
    {Hits, Misses} = with_cache_counter(fun() ->
        write_lww(T, K, <<"v1">>),
        _ = bondy_db:read(T, ?REALM, K),
        write_lww(T, K, <<"v2">>),
        ?assertMatch({ok, {<<"v2">>, _}}, bondy_db:read(T, ?REALM, K))
    end),
    close_db(Db, Sup, Dir),
    ?assertEqual(0, Hits),
    ?assertEqual(0, Misses).

%% =============================================================================
%% 3. Write-through coherence
%% =============================================================================

%% A counter incremented N times, draining between each so every inc is
%% its own applier batch, must fold against the cached prior state and
%% reach exactly N. A stale cache would lose increments (< N).
counter_coherent_across_batches() ->
    N = 20,
    {Db, Sup, Dir} = open_db(ctr_db, bondy_oplog_crdt_pn_counter, true),
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    K = <<"c">>,
    {Hits, _Misses} = with_cache_counter(fun() ->
        lists:foreach(
            fun(_) ->
                ok = bondy_db:counter_inc(T, ?REALM, K, 1),
                %% Force a drain so the next inc is a separate batch that
                %% must read the counter's prior state from the cache.
                _ = bondy_db:read(T, ?REALM, K)
            end,
            lists:seq(1, N)
        )
    end),
    Final = counter_value(bondy_db:read(T, ?REALM, K)),
    close_db(Db, Sup, Dir),
    ?assertEqual(N, Final),
    %% The cache was genuinely on the path (not bypassed via LocalWrites).
    ?assert(Hits >= 1).

%% =============================================================================
%% 3b. Coherence vs the catalogue-install write path (Architecture QA fix)
%% =============================================================================

%% A catalogue install (now always `replace` mode — PR-G removed merge-
%% mode) writes the projection directly via `install_cell_unchecked/9`,
%% WITHOUT going through the write-through path. If the cache is not
%% cleared, a subsequent live event folds against the pre-install
%% OldState — a convergence break. This is the falsifying regression for
%% the `do_install_catalogue_batch/4` cache clear; it FAILS against the
%% pre-fix code.
merge_install_does_not_serve_stale_oldstate() ->
    B = <<"b">>,
    K = <<"k">>,
    {Id, NS, Proj} = setup_cached_cell_instance(),
    try
        %% Warm the cache via the live drain: LWW set at HLC 10.
        _ = bondy_oplog:append(Id, {cell_apply, B, K, {set, 10, <<"v_old">>}}),
        ok = bondy_oplog:await_apply(Id),
        ?assertEqual(<<"v_old">>, read_cell_value(Proj, B, K)),

        %% Install a NEWER frame (HLC 50) directly — replace mode is
        %% skip-if-older, so HLC 50 > 10 installs and writes the
        %% projection directly, not via write-through. The cache still
        %% holds the HLC-10 frame unless the install clears it.
        Cell = encoded_lww_cell(B, K, 50, <<"v_installed">>),
        {ok, _} = bondy_oplog_instance:install_catalogue_batch(
            Id, {replace, [Cell]}
        ),
        ?assertEqual(<<"v_installed">>, read_cell_value(Proj, B, K)),

        %% A live LWW set at HLC 30 must LOSE to the installed HLC-50
        %% value (30 < 50). A stale cache (HLC 10) would wrongly accept
        %% it (30 > 10) and clobber the install.
        _ = bondy_oplog:append(
            Id, {cell_apply, B, K, {set, 30, <<"v_should_lose">>}}
        ),
        ok = bondy_oplog:await_apply(Id),
        ?assertEqual(<<"v_installed">>, read_cell_value(Proj, B, K))
    after
        teardown_cell_instance(Id, NS)
    end.

%% =============================================================================
%% 4. Opt validation
%% =============================================================================

%% `start_instance` surfaces the applier's init validation error wrapped
%% in the supervisor's `failed_to_start_child` shutdown tuple.
invalid_oldstate_cache_rejected() ->
    ?assertMatch(
        {error,
            {shutdown,
                {failed_to_start_child, bondy_oplog_applier,
                    {error, {invalid_opt, oldstate_cache, _}}}}},
        start_instance_with(#{oldstate_cache => yes})
    ).

invalid_oldstate_cache_max_rejected() ->
    ?assertMatch(
        {error,
            {shutdown,
                {failed_to_start_child, bondy_oplog_applier,
                    {error, {invalid_opt, oldstate_cache_max, _}}}}},
        start_instance_with(#{oldstate_cache => true, oldstate_cache_max => 0})
    ).

valid_oldstate_cache_accepted() ->
    Id = mk_id(),
    ?assertMatch(
        {ok, _},
        bondy_oplog:start_instance(Id, #{
            fold_module => lww_register,
            applier => #{oldstate_cache => true, oldstate_cache_max => 16}
        })
    ),
    ok = bondy_oplog:stop_instance(Id).

%% =============================================================================
%% 5. The cache primitive (direct)
%% =============================================================================

%% `undefined` (disabled) is a no-op; an enabled cache returns hits/misses
%% and never exceeds its cap (coarse clear-on-overflow keeps it bounded).
cache_primitive_get_put_and_bounded() ->
    %% Disabled: every op a no-op.
    ?assertEqual(
        undefined, bondy_oplog_cell_apply:oldstate_cache_new(false, 10)
    ),
    ?assertEqual(
        miss,
        bondy_oplog_cell_apply:oldstate_cache_get(undefined, <<"b">>, <<"k">>)
    ),
    ?assertEqual(
        ok, bondy_oplog_cell_apply:oldstate_cache_put_entries(undefined, [])
    ),

    %% Enabled: put-then-get is a hit; absent key is a miss.
    Max = 4,
    Cache = bondy_oplog_cell_apply:oldstate_cache_new(true, Max),
    ?assertEqual(
        miss,
        bondy_oplog_cell_apply:oldstate_cache_get(Cache, <<"b">>, <<"k1">>)
    ),
    ok = bondy_oplog_cell_apply:oldstate_cache_put_entries(
        Cache, [{<<"b">>, <<"k1">>, <<"f1">>}]
    ),
    ?assertEqual(
        {hit, <<"f1">>},
        bondy_oplog_cell_apply:oldstate_cache_get(Cache, <<"b">>, <<"k1">>)
    ),

    %% Bounded: pushing well past the cap never leaves more than `Max`
    %% entries (the coarse clear fires at the cap; the cache is
    %% rebuildable, so a clear only costs re-warm misses).
    {Tab, Max} = Cache,
    lists:foreach(
        fun(I) ->
            ok = bondy_oplog_cell_apply:oldstate_cache_put_entries(
                Cache, [{<<"b">>, int_key(I), <<"f">>}]
            ),
            ?assert(ets:info(Tab, size) =< Max)
        end,
        lists:seq(1, 50)
    ),
    true = ets:delete(Tab),
    ok.

%% =============================================================================
%% Helpers
%% =============================================================================

run_lww(Name, CacheOn, Seq, Keys) ->
    {Db, Sup, Dir} = open_db(Name, bondy_oplog_crdt_lww_register, CacheOn),
    {ok, T} = bondy_db:open_table(Db, users, #{}),
    lists:foreach(
        fun({K, C}) ->
            write_lww(T, K, <<K/binary, "-", (integer_to_binary(C))/binary>>)
        end,
        Seq
    ),
    Result = lists:sort([
        {K, read_value(bondy_db:read(T, ?REALM, K))}
     || K <- Keys
    ]),
    close_db(Db, Sup, Dir),
    Result.

write_lww(T, K, V) ->
    H = bondy_db:tick(T),
    ok = bondy_db:apply(T, ?REALM, K, {set, H, V}).

read_value({ok, {V, _H}}) -> V;
read_value(Other) -> Other.

counter_value({ok, {V, _H}}) -> V;
counter_value(Other) -> Other.

%% Open a memory-topology DB whose per-shard appliers carry the A3 flag.
open_db(Name, Fold, CacheOn) ->
    Dir = make_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        topology_opts => #{sup => Sup, dir => Dir},
        shard_count => 2,
        fold_module => Fold,
        oplog_instance_opts => #{
            applier => #{oldstate_cache => CacheOn}
        }
    }),
    {Db, Sup, Dir}.

close_db(Db, Sup, Dir) ->
    _ = catch bondy_db:close(Db),
    _ = [
        catch bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    ok.

%% Attach a hit/miss counter over `[bondy_oplog, applier, oldstate_cache]`
%% for the duration of `Fun`, returning `{Hits, Misses}`.
with_cache_counter(Fun) ->
    Tab = ets:new(cache_counts, [public, set]),
    ets:insert(Tab, [{hit, 0}, {miss, 0}]),
    HandlerId = {?MODULE, make_ref()},
    Handler = fun(_E, _M, #{result := R}, _Cfg) ->
        catch ets:update_counter(Tab, R, 1)
    end,
    ok = telemetry:attach(
        HandlerId, [bondy_oplog, applier, oldstate_cache], Handler, undefined
    ),
    try
        ok = Fun(),
        [{hit, H}] = ets:lookup(Tab, hit),
        [{miss, M}] = ets:lookup(Tab, miss),
        {H, M}
    after
        telemetry:detach(HandlerId),
        ets:delete(Tab)
    end.

start_instance_with(ApplierOpts) ->
    bondy_oplog:start_instance(mk_id(), #{
        fold_module => lww_register,
        applier => ApplierOpts
    }).

%% Manually-wired, cache-ON instance with a registered shard + ETS
%% projection (so `install_catalogue_batch` and a direct projection read
%% are both reachable). `seed => true` makes it a genesis live peer that
%% drains the WAL immediately.
setup_cached_cell_instance() ->
    Id = mk_id(),
    NS = binary_to_atom(<<Id/binary, "-ns">>, utf8),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register
    }),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        seed => true,
        applier => #{
            cell_apply_target => {NS, primary, 0},
            oldstate_cache => true
        }
    }),
    {Id, NS, Proj}.

teardown_cell_instance(Id, NS) ->
    _ = catch bondy_oplog:stop_instance(Id),
    _ = catch bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok.

%% Build a catalogue cell `{Bucket, Key, Frame}` for the LWW fold at a
%% given HLC + value (mirrors the install-path frame wire shape).
encoded_lww_cell(B, K, Hlc, Value) ->
    StateBytes = bondy_oplog_crdt_lww_register:encode_state({set, Value, Hlc}),
    ValueBytes = term_to_binary(Value),
    Frame = bondy_oplog_cell_frame:encode(Hlc, StateBytes, ValueBytes, false),
    {B, K, Frame}.

%% Read the projection cell directly and decode the LWW value.
read_cell_value(Proj, B, K) ->
    case bondy_oplog_projection_ets:get(Proj, B, K) of
        {ok, Frame} ->
            {_H, StateBytes, _V} = bondy_oplog_cell_frame:decode_full(Frame),
            State = bondy_oplog_crdt_lww_register:decode_state(StateBytes),
            bondy_oplog_crdt_lww_register:to_value(State);
        not_found ->
            not_found
    end.

int_key(I) ->
    <<"k", (integer_to_binary(I))/binary>>.

mk_id() ->
    Int = erlang:unique_integer([positive]),
    <<"oldstate-cache-test-", (integer_to_binary(Int))/binary>>.

make_tempdir() ->
    Base = filename:join([
        "/tmp/" ++ os:getpid(),
        "a3_oldstate_cache_test",
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, "x")),
    Base.

rmrf(Dir) ->
    _ = catch file:del_dir_r(Dir),
    ok.
