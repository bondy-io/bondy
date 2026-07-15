%% =============================================================================
%% Cold-start index recovery (PLUM_DB_TO_BONDY_DB_DESIGN.md §6.6.1–6.6.3).
%%
%% These tests pin the durable-index cold-start contract over a real graceful
%% stop/restart on a fully durable stack (single-bookie leveled projection +
%% pack-store MST + WAL, all rooted at a `storage_path`, like
%% `bondy_db_tier2_durability_test`):
%%
%%   - A CLEAN restart of a durable table TRUSTS the persisted index cells:
%%     `bondy_db:open_table` does NOT run an O(table) rebuild (no
%%     `[bondy_oplog, secondary_index, rebuild]` telemetry), the index data is
%%     immediately readable, and a finite-`max_lag` read passes at once
%%     (the shards are freshened, not left sentinel-stale).
%%
%%   - A restart of a table whose shard was left untrusted (its durable trust
%%     marker removed, simulating a pre-restart saturation drop) REBUILDS that
%%     index from the primary on open (the rebuild telemetry fires) and the
%%     data is correct afterwards.
%%
%% Together they verify the durable trust marker (§6.6.2) drives the cold-start
%% trust-vs-rebuild decision: presence ⇒ trust, absence ⇒ rebuild.
%% =============================================================================

-module(bondy_db_index_coldstart_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB, idx_coldstart).
-define(ET, users).
-define(R, <<"r1">>).
-define(REBUILD_EVENT, [bondy_oplog, secondary_index, rebuild]).

%% =============================================================================
%% Generators
%% =============================================================================

coldstart_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(Dirs) ->
            {"clean restart trusts the index (no rebuild)",
                {timeout, 90, fun() -> clean_restart_trusts(Dirs) end}}
        end,
        fun(Dirs) ->
            {"untrusted shard restart rebuilds",
                {timeout, 90, fun() -> untrusted_restart_rebuilds(Dirs) end}}
        end,
        fun(Dirs) ->
            {"graceful-tail restart trusts (flush-on-close) and keeps the tail",
                {timeout, 90, fun() -> graceful_tail_restart_trusts(Dirs) end}}
        end,
        fun(Dirs) ->
            {"crash-tail restart rebuilds and recovers the unflushed tail",
                {timeout, 90, fun() -> crash_tail_restart_rebuilds(Dirs) end}}
        end
    ]}.

setup() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    {ok, _} = application:ensure_all_started(bondy_oplog),
    %% Tests want full control of compaction/GC timing — silence the
    %% schedulers (mirrors bondy_db_tier2_durability_test).
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    #{
        leveled => make_tempdir("leveled"),
        pack => make_tempdir("pack")
    }.

cleanup(Dirs) ->
    stop_everything(),
    rmrf(maps:get(leveled, Dirs)),
    rmrf(maps:get(pack, Dirs)),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

clean_restart_trusts(Dirs) ->
    %% --- First lifetime: write + index two entries, flush, close. ---
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = open_table(Db0),
    write(T0, <<"u1">>, <<"active">>),
    write(T0, <<"u2">>, <<"active">>),
    flush_index(T0, by_value),
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}]},
        bondy_db:index_get(T0, ?R, by_value, <<"active">>, #{})
    ),
    close(T0, Db0, Sup0),

    %% --- Second lifetime: count rebuilds across the reopen. ---
    Ctr = counters:new(1, []),
    attach_rebuild_counter(Ctr),
    {Db1, Sup1} = open(Dirs),
    {ok, T1} = open_table(Db1),
    try
        %% The persisted index cells are TRUSTED — no O(table) rebuild ran.
        ?assertEqual(0, counters:get(Ctr, 1)),
        %% The data survived and is immediately readable.
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}]},
            bondy_db:index_get(T1, ?R, by_value, <<"active">>, #{})
        ),
        %% Freshened on open: a finite-max_lag read passes at once.
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}]},
            bondy_db:index_get(
                T1, ?R, by_value, <<"active">>, #{max_lag => 60000}
            )
        )
    after
        detach_rebuild_counter(),
        close(T1, Db1, Sup1)
    end.

untrusted_restart_rebuilds(Dirs) ->
    %% --- First lifetime: write + index, flush, then strip every shard's
    %% durable trust marker (simulating a pre-restart saturation drop), close.
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = open_table(Db0),
    write(T0, <<"u1">>, <<"active">>),
    flush_index(T0, by_value),
    ?assertEqual(
        {ok, [{<<"u1">>, #{}}]},
        bondy_db:index_get(T0, ?R, by_value, <<"active">>, #{})
    ),
    untrust_all_shards(T0, by_value),
    close(T0, Db0, Sup0),

    %% --- Second lifetime: the unmarked index triggers a rebuild on open. ---
    %% We assert the DECISION Step 3 owns: a shard whose durable trust marker
    %% is absent is rebuilt (not silently trusted). We do NOT assert the
    %% rebuilt contents here: the rebuild re-derives from the primary via
    %% `reindex_from_projection`, whose cell directory for this durable table is
    %% the projection (`cell_keys/2`, the complete durable directory — see
    %% `bondy_oplog_applier:primary_cell_directory/3`). Its completeness depends
    %% on the primary's own durable recovery / tail-replay — a separate concern
    %% from the marker-driven decision, and exercised by the rebuild suites
    %% (lag / writer / tier2). The trusted path (and its full data survival) is
    %% covered by `clean_restart_trusts`.
    Ctr = counters:new(1, []),
    attach_rebuild_counter(Ctr),
    {Db1, Sup1} = open(Dirs),
    {ok, T1} = open_table(Db1),
    try
        ?assert(counters:get(Ctr, 1) >= 1)
    after
        detach_rebuild_counter(),
        close(T1, Db1, Sup1)
    end.

%% F1-minimal, Test A — a GRACEFUL restart with a tail that was written but not
%% explicitly flushed must stay on the cheap TRUST path (no O(table) rebuild)
%% AND keep the tail. This pins flush-on-close: `close_table/1` `flush_sync`s the
%% writer and stamps the clean-shutdown flag, so the durable index is
%% complete-to-head at shutdown and the next open trusts it.
%%
%% u1,u2 are flushed durably; u3 is written (durable in the primary) and left
%% BUFFERED in the index writer (a large `coalesce_ms` stops the 5ms timer from
%% flushing it early). Only the graceful close flushes u3.
graceful_tail_restart_trusts(Dirs) ->
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = open_table_slow(Db0),
    write(T0, <<"u1">>, <<"active">>),
    write(T0, <<"u2">>, <<"active">>),
    flush_index(T0, by_value),
    write(T0, <<"u3">>, <<"active">>),
    %% u3 is durable in the primary, still buffered in the index writer.
    ?assertMatch({ok, {_, _}}, bondy_db:read(T0, ?R, <<"u3">>)),
    close(T0, Db0, Sup0),

    Ctr = counters:new(1, []),
    attach_rebuild_counter(Ctr),
    {Db1, Sup1} = open(Dirs),
    {ok, T1} = open_table_slow(Db1),
    try
        %% Clean shutdown ⇒ trusted ⇒ no rebuild.
        ?assertEqual(0, counters:get(Ctr, 1)),
        %% flush-on-close persisted u3, so the trusted index holds the tail.
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}, {<<"u3">>, #{}}]},
            bondy_db:index_get(T1, ?R, by_value, <<"active">>, #{})
        ),
        %% Freshened on open, so a finite-max_lag read passes at once.
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}, {<<"u3">>, #{}}]},
            bondy_db:index_get(
                T1, ?R, by_value, <<"active">>, #{max_lag => 60000}
            )
        )
    after
        detach_rebuild_counter(),
        close(T1, Db1, Sup1)
    end.

%% F1-minimal, Test B — the original (C) data-loss scenario, now correctly
%% recovered. A write durable in the PRIMARY whose index dispatch is lost on a
%% CRASH (in-flight coalesce buffer gone, no clean close) must still be present
%% after reopen — via a REBUILD (the shard is not trusted, because no
%% clean-shutdown flag was written). The fix turns the silent under-count into a
%% rebuild; rebuilding is the accepted F1-minimal cost on the crash path.
%%
%% Construction: u3 is durable in the primary; `reset/1` drops its buffered index
%% op (the crash's effect on the in-memory buffer); `crash/2` tears the processes
%% down WITHOUT `close_table` (so flush-on-close never runs and no clean flag is
%% written) — a faithful power-loss.
crash_tail_restart_rebuilds(Dirs) ->
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = open_table_slow(Db0),
    write(T0, <<"u1">>, <<"active">>),
    write(T0, <<"u2">>, <<"active">>),
    flush_index(T0, by_value),
    write(T0, <<"u3">>, <<"active">>),
    %% u3 is durable in the primary now...
    ?assertMatch({ok, {_, _}}, bondy_db:read(T0, ?R, <<"u3">>)),
    %% ...but its index op is lost from the writer's buffer, then we crash
    %% (no close ⇒ no flush-on-close ⇒ no clean-shutdown flag).
    reset_index(T0, by_value),
    crash(Db0, Sup0),

    Ctr = counters:new(1, []),
    attach_rebuild_counter(Ctr),
    {Db1, Sup1} = open(Dirs),
    {ok, T1} = open_table_slow(Db1),
    try
        %% No clean flag ⇒ the shard is NOT trusted ⇒ it rebuilds.
        ?assert(counters:get(Ctr, 1) >= 1),
        %% u3 survived in the primary and the rebuild re-derived it.
        ?assertMatch({ok, {_, _}}, bondy_db:read(T1, ?R, <<"u3">>)),
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}, {<<"u3">>, #{}}]},
            bondy_db:index_get(T1, ?R, by_value, <<"active">>, #{})
        )
    after
        detach_rebuild_counter(),
        close(T1, Db1, Sup1)
    end.

%% =============================================================================
%% Harness
%% =============================================================================

%% A fully durable single-bookie stack rooted at `storage_path` so the whole
%% table (primary MST/WAL + leveled index projection) survives a stop/restart.
open(Dirs) ->
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(?DB, #{
        topology => bondy_db_topology_single_bookie,
        topology_opts => #{sup => Sup, dir => maps:get(leveled, Dirs)},
        shard_count => 1,
        fold_module => lww_register,
        oplog_instance_opts => #{
            backend => bondy_mst_pack_store,
            storage_path =>
                unicode:characters_to_binary(maps:get(pack, Dirs)),
            seed => true
        }
    }),
    {Db, Sup}.

open_table(Db) ->
    bondy_db:open_table(Db, ?ET, #{
        fold_module => lww_register,
        indexes => [#{name => by_value, extract => []}]
    }).

%% Like `open_table/1` but with a huge coalesce window so the secondary writer's
%% auto-flush timer never fires mid-test — a buffered op stays buffered until we
%% deterministically drop it with `reset_index/2`.
open_table_slow(Db) ->
    bondy_db:open_table(Db, ?ET, #{
        fold_module => lww_register,
        indexes => [#{name => by_value, extract => [], coalesce_ms => 600000}]
    }).

write(T, Key, Value) ->
    ok = bondy_db:apply(T, ?R, Key, {set, bondy_db:tick(T), Value}).

%% Graceful shutdown: close the DB (stops the leveled Bookies), stop every
%% oplog instance (they cache now-dead Bookie handles), then stop the leveled
%% supervisor. The on-disk leveled/pack/WAL state survives.
close(Table, Db, Sup) ->
    %% NOTE: `close_table/1` takes the TABLE handle (from `open_table/3`), not
    %% the DB handle — it is what runs the F1-minimal flush-on-close
    %% (`flush_and_mark_clean`) that stamps each index shard's clean-shutdown
    %% flag. Passing `Db` here (as an earlier version did) silently no-ops under
    %% `catch` and leaves every shard dirty → a needless rebuild on reopen.
    _ = catch bondy_db:close_table(Table),
    _ = catch bondy_db:close(Db),
    stop_everything(),
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    ok.

%% Simulate a crash: tear down the running processes WITHOUT `close_table/1`, so
%% the F1-minimal flush-on-close (`flush_and_mark_clean`) never runs and no
%% clean-shutdown flag is written — exactly a power-loss / kill. The on-disk
%% leveled/pack/WAL survive, so the primary's durable state (including u3) is
%% recovered on the next open, but the index is left without its tail or a clean
%% flag, forcing a rebuild.
crash(Db, Sup) ->
    _ = catch bondy_db:close(Db),
    stop_everything(),
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    ok.

stop_everything() ->
    _ = [
        catch bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

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

%% Drop every shard's buffered-but-unflushed index ops WITHOUT touching the
%% durable cells or the trust marker (`bondy_oplog_secondary_writer:reset/2`),
%% simulating a crash that loses the writer's in-memory coalesce buffer.
reset_index(Table, IndexName) ->
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
            ok = bondy_oplog_secondary_writer:reset(Pid, {NS, IndexName})
        end,
        lists:seq(0, N - 1)
    ).

%% Remove every shard's durable trust marker (via `index_mark_rebuild`, which
%% also deletes the marker), simulating a pre-restart saturation drop.
untrust_all_shards(Table, IndexName) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    lists:foreach(
        fun(Shard) ->
            {ok, Entry} = bondy_oplog_core_registry:lookup(
                NS, IndexName, Shard
            ),
            ok = bondy_oplog_core_registry:index_mark_rebuild(Entry)
        end,
        lists:seq(0, N - 1)
    ).

%% =============================================================================
%% Telemetry counter
%% =============================================================================

attach_rebuild_counter(Ctr) ->
    ok = telemetry:attach(
        rebuild_counter_handler(),
        ?REBUILD_EVENT,
        fun(_Event, _Measurements, _Meta, C) -> counters:add(C, 1, 1) end,
        Ctr
    ).

detach_rebuild_counter() ->
    _ = telemetry:detach(rebuild_counter_handler()),
    ok.

rebuild_counter_handler() ->
    {?MODULE, rebuild_counter}.

%% =============================================================================
%% Tempdirs
%% =============================================================================

make_tempdir(Prefix) ->
    Base = filename:join([
        "/tmp",
        "bondy_db_index_coldstart",
        Prefix,
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
