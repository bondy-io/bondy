%% Durable secondary-index recovery across restarts of a fully durable stack:
%% a single-bookie leveled projection, a pack-store MST and a WAL under one
%% `storage_path`. An open trusts an index that carries its trust marker
%% (`clean_restart_trusts/1`) and replays the primary's leftover intents into it
%% (`crash_tail_restart_replays/1`); it rebuilds an index without the marker
%% from the primary (`untrusted_restart_rebuilds/1`). A test that matches a
%% `proofs/tla/IndexIntents.tla` config names it.

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
            {"graceful-tail restart trusts and replays the unflushed tail",
                {timeout, 90, fun() -> graceful_tail_restart_trusts(Dirs) end}}
        end,
        fun(Dirs) ->
            {"crash-tail restart trusts and replays the unflushed tail",
                {timeout, 90, fun() -> crash_tail_restart_replays(Dirs) end}}
        end,
        fun(Dirs) ->
            {"clean reopen orders new index ops above the persisted ones",
                {timeout, 90, fun() ->
                    clean_reopen_orders_new_ops_above_old(Dirs)
                end}}
        end,
        fun(Dirs) ->
            {"a trust marker of another index cell format rebuilds",
                {timeout, 90, fun() -> old_format_marker_rebuilds(Dirs) end}}
        end,
        fun(Dirs) ->
            {"an index dropped after a crash does not block the open",
                {timeout, 90, fun() ->
                    dropped_index_does_not_block_open(Dirs)
                end}}
        end,
        fun(Dirs) ->
            {"a batch's intent is written with it and cleared by compaction",
                {timeout, 90, fun() -> intents_written_and_cleared(Dirs) end}}
        end,
        fun(Dirs) ->
            {"compaction keeps the intents when a writer does not flush",
                {timeout, 90, fun() -> wedged_writer_keeps_intents(Dirs) end}}
        end,
        fun(Dirs) ->
            {"compaction keeps the intents when an index write fails",
                {timeout, 90, fun() ->
                    failed_index_write_keeps_intents(Dirs)
                end}}
        end,
        fun(Dirs) ->
            {"compaction clears intents across several pages",
                {timeout, 120, fun() ->
                    clear_pages_through_many_intents(Dirs)
                end}}
        end,
        fun(Dirs) ->
            {"a reopen seeds the counter above the shard's intents",
                {timeout, 90, fun() -> reopen_seeds_from_intents(Dirs) end}}
        end,
        fun(Dirs) ->
            {"a rebuild syncs the index around the trust marker",
                {timeout, 90, fun() ->
                    rebuild_syncs_around_the_trust_marker(Dirs)
                end}}
        end,
        fun(Dirs) ->
            {"a rebuild that cannot remove the trust marker does not wipe",
                {timeout, 90, fun() -> failed_unmark_blocks_the_wipe(Dirs) end}}
        end,
        fun(Dirs) ->
            {"a catalogue install keeps the index",
                {timeout, 90, fun() -> install_keeps_the_index(Dirs) end}}
        end,
        fun(Dirs) ->
            {"a catalogue install syncs the primary before its first cell",
                {timeout, 90, fun() ->
                    install_syncs_before_its_first_cell(Dirs)
                end}}
        end,
        fun(Dirs) ->
            {"a failed open keeps the leftover intents",
                {timeout, 90, fun() ->
                    failed_open_keeps_intents(Dirs)
                end}}
        end,
        fun(Dirs) ->
            {"a writer dead at the open flush leaves the index unfreshened",
                {timeout, 90, fun() ->
                    writer_death_at_open_flush(Dirs)
                end}}
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
    detach_rebuild_counter(),
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

    %% Second lifetime: the unmarked index triggers a rebuild on open. The
    %% assertion is the DECISION — a shard whose durable trust marker is
    %% absent is rebuilt, not silently trusted — and NOT the rebuilt
    %% contents, whose completeness rests on the primary's own durable
    %% recovery and is exercised by the rebuild suites (lag / writer /
    %% tier2). `clean_restart_trusts` covers the trusted path.
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

%% A graceful restart with a tail that was written but not flushed trusts the
%% index (no rebuild) and keeps the tail. u1 and u2 are flushed; u3 is durable
%% in the primary and buffered in the writer (a large `coalesce_ms` keeps the
%% timer from flushing it). The close discards the buffer, and the open
%% replays u3 from the primary's index intents.
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
        ?assertEqual(0, counters:get(Ctr, 1)),
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

%% A write durable in the primary whose index op is lost in a crash is in the
%% index after the reopen, which trusts the index and runs no rebuild: the open
%% replays the op from the primary's index intents. `reset_index/2` drops u3's
%% buffered op, as the crash would, and `crash/2` stops everything without
%% `close_table/1`.
crash_tail_restart_replays(Dirs) ->
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = open_table_slow(Db0),
    write(T0, <<"u1">>, <<"active">>),
    write(T0, <<"u2">>, <<"active">>),
    flush_index(T0, by_value),
    write(T0, <<"u3">>, <<"active">>),
    ?assertMatch({ok, {_, _}}, bondy_db:read(T0, ?R, <<"u3">>)),
    reset_index(T0, by_value),
    crash(Db0, Sup0),

    Ctr = counters:new(1, []),
    attach_rebuild_counter(Ctr),
    {Db1, Sup1} = open(Dirs),
    {ok, T1} = open_table_slow(Db1),
    try
        ?assertEqual(0, counters:get(Ctr, 1)),
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}, {<<"u3">>, #{}}]},
            bondy_db:index_get(T1, ?R, by_value, <<"active">>, #{})
        )
    after
        detach_rebuild_counter(),
        close(T1, Db1, Sup1)
    end.

%% A trusted reopen keeps the persisted index cells, whose versions came from
%% the first lifetime's counter. u1 goes a, b, a, b, a, so the index holds `a`
%% live and `b` dead at the versions of the last two writes, at least 5 and 4.
%% After the reopen u1 becomes `b`: its put of `b` and remove of `a` must order
%% above those cells. A counter that restarted at 0, or was seeded before the
%% index shards were registered, gives them version 1: `b` stays dead and `a`
%% stays live.
clean_reopen_orders_new_ops_above_old(Dirs) ->
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = open_table(Db0),
    [
        write(T0, <<"u1">>, V)
     || V <- [<<"a">>, <<"b">>, <<"a">>, <<"b">>, <<"a">>]
    ],
    flush_index(T0, by_value),
    close(T0, Db0, Sup0),

    Ctr = counters:new(1, []),
    attach_rebuild_counter(Ctr),
    {Db1, Sup1} = open(Dirs),
    {ok, T1} = open_table(Db1),
    try
        ?assertEqual(0, counters:get(Ctr, 1)),
        write(T1, <<"u1">>, <<"b">>),
        flush_index(T1, by_value),
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}]},
            bondy_db:index_get(T1, ?R, by_value, <<"b">>, #{})
        ),
        ?assertEqual(
            {ok, []}, bondy_db:index_get(T1, ?R, by_value, <<"a">>, #{})
        )
    after
        detach_rebuild_counter(),
        close(T1, Db1, Sup1)
    end.

%% A built shard, closed gracefully, whose trust marker names no index cell
%% format (the marker an index ordered by HLC was written with), is rebuilt on
%% open.
old_format_marker_rebuilds(Dirs) ->
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = open_table(Db0),
    write(T0, <<"u1">>, <<"active">>),
    flush_index(T0, by_value),
    foreach_shard(T0, by_value, fun(NS, Shard, Entry) ->
        {B, K} = bondy_oplog_index_key:trust_marker_loc(NS, by_value, Shard),
        A = bondy_oplog_core_registry:entry_projection_adapter(Entry),
        H = bondy_oplog_core_registry:entry_projection_handle(Entry),
        ok = A:put_batch(H, [
            {B, K, bondy_oplog_cell_frame:encode(0, <<>>, undefined, true)}
        ])
    end),
    close(T0, Db0, Sup0),

    Ctr = counters:new(1, []),
    attach_rebuild_counter(Ctr),
    {Db1, Sup1} = open(Dirs),
    {ok, T1} = open_table(Db1),
    try
        ?assert(counters:get(Ctr, 1) >= 1),
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}]},
            bondy_db:index_get(T1, ?R, by_value, <<"active">>, #{})
        )
    after
        detach_rebuild_counter(),
        close(T1, Db1, Sup1)
    end.

%% Each applied batch that changes the index writes its ops as an intent in the
%% primary, at the batch's version. A compaction flushes the writers, syncs, and
%% clears every intent up to the version the shard had dispatched, recording
%% that bound.
intents_written_and_cleared(Dirs) ->
    {Db, Sup} = open(Dirs),
    {ok, T} = open_table(Db),
    try
        write(T, <<"u1">>, <<"a">>),
        write(T, <<"u2">>, <<"b">>),
        Intents = intents(T),
        ?assertEqual(2, length(Intents)),
        [
            ?assertMatch(#{{by_value, 0} := [_ | _]}, Ops)
         || {_Version, Ops} <- Intents
        ],
        {Top, _} = lists:last(Intents),
        compact(T),
        ?assertEqual([], intents(T)),
        ?assert(intents_cleared(T) >= Top)
    after
        close(T, Db, Sup)
    end.

%% A writer that does not flush within the barrier's timeout is marked for
%% rebuild, and its shard's ops may be in no store but the intents: the
%% compaction must leave them.
wedged_writer_keeps_intents(Dirs) ->
    {Db, Sup} = open(Dirs),
    {ok, T} = open_table(Db),
    [Pid] = writer_pids(T, by_value),
    try
        ok = sys:suspend(Pid),
        write(T, <<"u1">>, <<"a">>),
        compact(T),
        ?assertMatch([_], intents(T))
    after
        ok = sys:resume(Pid),
        close(T, Db, Sup)
    end.

%% The index store refuses the writer's batch, so u1's op is in no store but its
%% intent. The writer marks the shard for rebuild, and the compaction must leave
%% the intent. The rebuild server is held so no rebuild clears the mark first.
failed_index_write_keeps_intents(Dirs) ->
    {Db, Sup} = open(Dirs),
    {ok, T} = open_table(Db),
    ok = sys:suspend(bondy_oplog_index_rebuild),
    ok = meck:new(bondy_db_projection_leveled, [passthrough]),
    try
        ok = meck:expect(
            bondy_db_projection_leveled, put_batch, fun(H, Entries) ->
                case lists:keymember(<<"$idx_version">>, 1, Entries) of
                    true -> {error, injected};
                    false -> meck:passthrough([H, Entries])
                end
            end
        ),
        write(T, <<"u1">>, <<"a">>),
        flush_index(T, by_value),
        compact(T),
        ?assertMatch([_], intents(T))
    after
        meck:unload(bondy_db_projection_leveled),
        ok = sys:resume(bondy_oplog_index_rebuild),
        close(T, Db, Sup)
    end.

%% More intents than one range scan returns: the clear must page through all.
clear_pages_through_many_intents(Dirs) ->
    {Db, Sup} = open(Dirs),
    {ok, T} = open_table(Db),
    try
        [
            write(T, <<"u", (integer_to_binary(I))/binary>>, <<"a">>)
         || I <- lists:seq(1, 1100)
        ],
        ?assert(length(intents(T)) > 1000),
        compact(T),
        ?assertEqual([], intents(T))
    after
        close(T, Db, Sup)
    end.

%% The index never receives u1's last three ops (the writer's buffer is
%% dropped, then the node crashes), so only the primary's intents record their
%% versions. The reopen must seed the counter so a new op takes a version above
%% them.
reopen_seeds_from_intents(Dirs) ->
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = open_table_slow(Db0),
    write(T0, <<"u1">>, <<"a">>),
    flush_index(T0, by_value),
    [write(T0, <<"u1">>, V) || V <- [<<"b">>, <<"c">>, <<"d">>]],
    {Top, _} = lists:last(intents(T0)),
    reset_index(T0, by_value),
    crash(Db0, Sup0),

    {Db1, Sup1} = open(Dirs),
    {ok, T1} = open_table_slow(Db1),
    try
        write(T1, <<"u1">>, <<"e">>),
        {Next, _} = lists:last(intents(T1)),
        ?assert(Next > Top)
    after
        close(T1, Db1, Sup1)
    end.

%% A crash leaves the registry rows of both indexes behind, pointing at the
%% stopped Bookie. The reopen declares only `by_value`, so the primary shard's
%% version counter must start from `by_value`'s records alone: a read of the
%% dropped `by_other` rows fails, and with it the open.
dropped_index_does_not_block_open(Dirs) ->
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = bondy_db:open_table(Db0, ?ET, #{
        fold_module => lww_register,
        indexes => [
            #{name => by_value, extract => []},
            #{name => by_other, extract => []}
        ]
    }),
    write(T0, <<"u1">>, <<"active">>),
    flush_index(T0, by_value),
    crash(Db0, Sup0),

    {Db1, Sup1} = open(Dirs),
    {ok, T1} = open_table(Db1),
    try
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}]},
            bondy_db:index_get(T1, ?R, by_value, <<"active">>, #{})
        )
    after
        close(T1, Db1, Sup1)
    end.

%% A crash loses u2's index op. The next open fails after the index shards
%% came up (the primary instance refuses to start), and its rollback must leave
%% the primary's index intents in place: the open after that replays u2.
failed_open_keeps_intents(Dirs) ->
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = open_table_slow(Db0),
    write(T0, <<"u1">>, <<"active">>),
    flush_index(T0, by_value),
    write(T0, <<"u2">>, <<"active">>),
    reset_index(T0, by_value),
    crash(Db0, Sup0),

    {Db1, Sup1} = open(Dirs),
    ok = meck:new(bondy_oplog, [passthrough]),
    try
        ok = meck:expect(bondy_oplog, start_instance, fun(_Id, _Opts) ->
            {error, injected}
        end),
        ?assertMatch({error, _}, open_table_slow(Db1))
    after
        meck:unload(bondy_oplog)
    end,
    crash(Db1, Sup1),

    Ctr = counters:new(1, []),
    attach_rebuild_counter(Ctr),
    {Db2, Sup2} = open(Dirs),
    {ok, T2} = open_table_slow(Db2),
    try
        ?assertEqual(0, counters:get(Ctr, 1)),
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}]},
            bondy_db:index_get(T2, ?R, by_value, <<"active">>, #{})
        )
    after
        detach_rebuild_counter(),
        close(T2, Db2, Sup2)
    end.

%% A rebuild syncs the index after removing the trust marker and before the
%% wipe, and after its re-fold writes and before writing the marker
%% (`proofs/tla/IndexIntents_NoSyncBeforeWipe.cfg`,
%% `IndexIntents_NoSyncBeforeMark.cfg`). This checks the order of the calls on
%% the projection adapter, not what a crash keeps.
rebuild_syncs_around_the_trust_marker(Dirs) ->
    {Db, Sup} = open(Dirs),
    {ok, T} = open_table(Db),
    write(T, <<"u1">>, <<"a">>),
    flush_index(T, by_value),
    ok = meck:new(bondy_db_projection_leveled, [passthrough]),
    try
        ok = bondy_db:rebuild_index(T, by_value),
        Calls = [
            {F, A}
         || {_Pid, {_M, F, A}, _R} <- meck:history(
                bondy_db_projection_leveled
            )
        ],
        IsMarker = fun(Es) -> lists:keymember(~"$idx_trusted", 1, Es) end,
        IsIndexWrite = fun(Es) ->
            lists:any(
                fun({B, _K, _V}) ->
                    B =:= ~"$idx_version" orelse
                        binary:match(B, ~"/$idx/") =/= nomatch
                end,
                Es
            )
        end,
        [Unmark | _] = positions(
            fun
                ({delete, [_, B, _]}) -> B =:= ~"$idx_trusted";
                (_) -> false
            end,
            Calls
        ),
        [Wipe | _] = positions(fun({F, _}) -> F =:= clear end, Calls),
        [Mark | _] = positions(
            fun
                ({put_batch, [_, Es]}) -> IsMarker(Es);
                (_) -> false
            end,
            Calls
        ),
        Refold = lists:max(
            positions(
                fun
                    ({put_batch, [_, Es]}) ->
                        not IsMarker(Es) andalso IsIndexWrite(Es);
                    (_) ->
                        false
                end,
                lists:sublist(Calls, Mark - 1)
            )
        ),
        Syncs = positions(fun({F, _}) -> F =:= sync end, Calls),
        ?assert(Unmark < Wipe andalso Wipe < Refold andalso Refold < Mark),
        ?assert(lists:any(fun(S) -> S > Unmark andalso S < Wipe end, Syncs)),
        ?assert(lists:any(fun(S) -> S > Refold andalso S < Mark end, Syncs))
    after
        meck:unload(bondy_db_projection_leveled),
        close(T, Db, Sup)
    end.

positions(Pred, List) ->
    [I || {I, X} <- lists:enumerate(List), Pred(X)].

%% Every delete of the trust marker fails, as when the Bookie restarts during
%% it, so the removal by the rebuild's first mark is lost. The rebuild fails
%% without wiping the index (`proofs/tla/IndexIntents_UnmarkLost_2Shards.cfg`).
%% Once the delete works, the rebuild completes.
failed_unmark_blocks_the_wipe(Dirs) ->
    {Db, Sup} = open(Dirs),
    {ok, T} = open_table(Db),
    try
        write(T, <<"u1">>, <<"a">>),
        flush_index(T, by_value),
        ok = meck:new(bondy_db_projection_leveled, [passthrough]),
        try
            ok = meck:expect(
                bondy_db_projection_leveled,
                delete,
                fun
                    (_H, ~"$idx_trusted", _K) -> error(injected);
                    (H, B, K) -> meck:passthrough([H, B, K])
                end
            ),
            ?assertMatch({error, _}, bondy_db:rebuild_index(T, by_value)),
            ?assertEqual(
                0, meck:num_calls(bondy_db_projection_leveled, clear, '_')
            )
        after
            meck:unload(bondy_db_projection_leveled)
        end,
        ?assertEqual(ok, bondy_db:rebuild_index(T, by_value)),
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}]},
            bondy_db:index_get(T, ?R, by_value, <<"a">>, #{})
        )
    after
        close(T, Db, Sup)
    end.

%% A catalogue install gives u1 the frame of u2, whose value is b, and prunes
%% u2, which the snapshot lacks; the replay after the install applies u2's
%% local event again. The index then holds u1 and u2 under b and nothing under
%% a: the replay re-puts u1 under b but no remove of a, which only the
%% install's ops carry (`proofs/tla/IndexIntents_InstallBatch.cfg`).
install_keeps_the_index(Dirs) ->
    {Db, Sup} = open(Dirs),
    {ok, T} = open_table(Db),
    try
        write(T, <<"u1">>, <<"a">>),
        write(T, <<"u2">>, <<"b">>),
        flush_index(T, by_value),
        Entry = primary_entry(T),
        A = bondy_oplog_core_registry:entry_projection_adapter(Entry),
        H = bondy_oplog_core_registry:entry_projection_handle(Entry),
        [{B, K1}, {B, K2}] = lists:sort(
            A:cell_keys(
                H, bondy_oplog_core_registry:entry_primary_cell_scope(Entry)
            )
        ),
        {ok, F2} = A:get(H, B, K2),
        {ok, #{installed := 1, pruned := 1}} = bondy_oplog_test_helpers:install(
            bondy_oplog_core_registry:entry_instance_id(Entry), [{B, K1, F2}]
        ),
        flush_index(T, by_value),
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}, {<<"u2">>, #{}}]},
            bondy_db:index_get(T, ?R, by_value, <<"b">>, #{})
        ),
        ?assertEqual(
            {ok, []}, bondy_db:index_get(T, ?R, by_value, <<"a">>, #{})
        )
    after
        close(T, Db, Sup)
    end.

%% No barrier runs after the writes, so the primary may hold unsynced entries
%% when the install starts. The process that writes the install's first cell
%% syncs the primary before it, so a crash cannot keep the install and lose an
%% earlier write (`proofs/tla/IndexIntents_Intents_Subset_NoInstallSync.cfg`).
%% A sync by another process does not count: writes can land between it and
%% the install.
install_syncs_before_its_first_cell(Dirs) ->
    {Db, Sup} = open(Dirs),
    {ok, T} = open_table(Db),
    try
        write(T, <<"u1">>, <<"a">>),
        write(T, <<"u2">>, <<"b">>),
        Entry = primary_entry(T),
        A = bondy_oplog_core_registry:entry_projection_adapter(Entry),
        H = bondy_oplog_core_registry:entry_projection_handle(Entry),
        [{B, K1}, {B, K2}] = lists:sort(
            A:cell_keys(
                H, bondy_oplog_core_registry:entry_primary_cell_scope(Entry)
            )
        ),
        {ok, F2} = A:get(H, B, K2),
        ok = meck:new(bondy_db_projection_leveled, [passthrough]),
        try
            {ok, #{installed := 1}} = bondy_oplog_test_helpers:install(
                bondy_oplog_core_registry:entry_instance_id(Entry),
                [{B, K1, F2}]
            ),
            Calls = [
                {Pid, F}
             || {Pid, {_M, F, _A}, _R} <- meck:history(
                    bondy_db_projection_leveled
                )
            ],
            {Installer, write_batch} = lists:keyfind(write_batch, 2, Calls),
            Before = lists:takewhile(
                fun(C) -> C =/= {Installer, write_batch} end, Calls
            ),
            ?assert(lists:member({Installer, sync}, Before))
        after
            meck:unload(bondy_db_projection_leveled)
        end
    after
        close(T, Db, Sup)
    end.

%% The writer dies just before the open's flush. The open still succeeds,
%% runs no rebuild and leaves the index unfreshened, so a bounded-lag read
%% refuses. The restarted writer replays u2 from the primary's intent, and its
%% flush writes it and freshens the index.
writer_death_at_open_flush(Dirs) ->
    {Db0, Sup0} = open(Dirs),
    {ok, T0} = open_table_slow(Db0),
    write(T0, <<"u1">>, <<"active">>),
    flush_index(T0, by_value),
    write(T0, <<"u2">>, <<"active">>),
    crash(Db0, Sup0),

    Ctr = counters:new(1, []),
    attach_rebuild_counter(Ctr),
    {Db1, Sup1} = open(Dirs),
    Opener = self(),
    ok = meck:new(bondy_oplog_secondary_writer, [passthrough]),
    ok = meck:expect(
        bondy_oplog_secondary_writer, flush_entry, fun(Entry, Timeout) ->
            _ = self() =:= Opener andalso kill_writer(Entry),
            meck:passthrough([Entry, Timeout])
        end
    ),
    Opened =
        try
            open_table_slow(Db1)
        after
            meck:unload(bondy_oplog_secondary_writer)
        end,
    ?assertMatch({ok, _}, Opened),
    {ok, T1} = Opened,
    try
        ?assertEqual(0, counters:get(Ctr, 1)),
        ?assertMatch(
            {error, {stale_secondary, by_value, _}},
            bondy_db:index_get(
                T1, ?R, by_value, <<"active">>, #{max_lag => 60000}
            )
        ),
        flush_index(T1, by_value),
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

kill_writer(Entry) ->
    Pid = bondy_oplog_core_registry:entry_writer_pid(Entry),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, _, _, _} -> ok
    end,
    wait_restamped(bondy_oplog_core_registry:entry_key(Entry), Pid).

wait_restamped({NS, Name, Shard} = Key, Dead) ->
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, Name, Shard),
    case bondy_oplog_core_registry:entry_writer_pid(Entry) of
        Dead ->
            timer:sleep(10),
            wait_restamped(Key, Dead);
        _ ->
            ok
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
    _ =
        try
            bondy_db:close_table(Table)
        catch
            _:_ -> ok
        end,
    _ =
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end,
    stop_everything(),
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    ok.

%% Simulate a crash: tear down the running processes without `close_table/1`.
%% The on-disk leveled, pack and WAL state survives, so the next open recovers
%% the primary's durable state.
crash(Db, Sup) ->
    _ =
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end,
    stop_everything(),
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    ok.

stop_everything() ->
    _ = [
        try
            bondy_oplog:stop_instance(I)
        catch
            _:_ -> ok
        end
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
%% durable cells or the trust marker (`bondy_oplog_secondary_writer:reset/1`),
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
            true = is_pid(bondy_oplog_core_registry:entry_writer_pid(Entry)),
            ok = bondy_oplog_secondary_writer:reset(Entry)
        end,
        lists:seq(0, N - 1)
    ).

primary_entry(Table) ->
    NS = maps:get(namespace, bondy_db:info(Table)),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    Entry.

%% The primary shard's intents, `[{Version, Ops}]` in version order.
intents(Table) ->
    Entry = primary_entry(Table),
    {NS, primary, Shard} = bondy_oplog_core_registry:entry_key(Entry),
    A = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    H = bondy_oplog_core_registry:entry_projection_handle(Entry),
    {B, Low, High} = bondy_oplog_index_key:intent_range(NS, Shard),
    [
        {Version, binary_to_term(State)}
     || {Key, Frame} <- range_all(A, H, B, Low, High),
        <<_:(byte_size(Key) - 8)/binary, Version:64>> <- [Key],
        {_, State, _} <- [bondy_oplog_cell_frame:decode_full(Frame)]
    ].

range_all(A, H, B, Low, High) ->
    case A:range(H, B, Low, High, #{limit => 500}) of
        {ok, []} ->
            [];
        {ok, Rows} ->
            {Last, _} = lists:last(Rows),
            Rows ++ range_all(A, H, B, <<Last/binary, 0>>, High)
    end.

intents_cleared(Table) ->
    Entry = primary_entry(Table),
    {NS, primary, Shard} = bondy_oplog_core_registry:entry_key(Entry),
    A = bondy_oplog_core_registry:entry_projection_adapter(Entry),
    H = bondy_oplog_core_registry:entry_projection_handle(Entry),
    {B, K} = bondy_oplog_index_key:intents_cleared_loc(NS, Shard),
    {ok, Frame} = A:get(H, B, K),
    {_, <<Version:64>>, _} = bondy_oplog_cell_frame:decode_full(Frame),
    Version.

%% Compact the table's instance against its own frontier, so the stability
%% frontier covers every applied event.
compact(Table) ->
    InstanceId = bondy_oplog_core_registry:entry_instance_id(
        primary_entry(Table)
    ),
    Witness = bondy_oplog_registry:frontier(InstanceId),
    ?assertMatch(
        {ok, {compacted, _, _}},
        bondy_oplog_instance:compact(InstanceId, [Witness])
    ).

writer_pids(Table, IndexName) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    lists:usort([
        bondy_oplog_core_registry:entry_writer_pid(E)
     || Shard <- lists:seq(0, N - 1),
        {ok, E} <- [bondy_oplog_core_registry:lookup(NS, IndexName, Shard)]
    ]).

foreach_shard(Table, IndexName, Fun) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{IndexName := #{sec_shard_count := N}} = maps:get(indexes, Info),
    lists:foreach(
        fun(Shard) ->
            {ok, Entry} = bondy_oplog_core_registry:lookup(
                NS, IndexName, Shard
            ),
            Fun(NS, Shard, Entry)
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
        "/tmp/" ++ os:getpid(),
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
