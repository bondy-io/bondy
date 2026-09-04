%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% =============================================================================
%% Restart-recovery coverage for the per-instance applied-frontier version
%% vector (`bondy_oplog_instance:frontier/1`), the compaction-invariant
%% convergence oracle. This drives the FULL durable stack (`bondy_db` facade →
%% per-shard `bondy_oplog` instance → leveled projection + pack-store MST)
%% through a stop/restart and asserts the frontier survives by BOTH recovery
%% paths:
%%
%%   - CLEAN restart — `terminate/2` persists the live frontier into the
%%     compaction checkpoint; `init/1` restores it with a max-merge before the
%%     applier drains.
%%   - CRASH restart (the checkpoint wiped) — `init/1` finds no persisted
%%     frontier, and the applier's WAL-tail replay reconstructs it on the normal
%%     apply path. No O(N) projection fold, no `warming` state: re-applying an
%%     already-counted event is an idempotent max-merge.
%%
%% The crash case is the load-bearing one: it proves the meltdown-free property
%% — a hard kill recovers the frontier from the cheap WAL replay the instance
%% already runs, not from a full projection rescan.
%% =============================================================================
-module(bondy_oplog_frontier_recovery_test).

-include_lib("eunit/include/eunit.hrl").

-define(FOLD, bondy_oplog_crdt_lww_register).
-define(AW, bondy_oplog_crdt_aw_map).
-define(SHARDS, 4).
-define(KEYS, 24).
-define(DB, frontier_recovery_db).
-define(TOPOLOGY, bondy_db_topology_per_entity).

%% =============================================================================
%% Test generators
%% =============================================================================

frontier_tracks_applied_events_test_() ->
    {timeout, 120, fun frontier_tracks_applied_events/0}.

clean_restart_restores_frontier_test_() ->
    {timeout, 120, fun clean_restart_restores_frontier/0}.

crash_restart_reconstructs_frontier_test_() ->
    {timeout, 120, fun crash_restart_reconstructs_frontier/0}.

%% Same crash/reconstruct path, but the table carries an `aw_map` (add-wins)
%% CRDT — exactly `bondy_realm_keys`. Exercises frontier reconstruction over an
%% aw cell through the durable stack.
crash_restart_reconstructs_aw_frontier_test_() ->
    {timeout, 120, fun crash_restart_reconstructs_aw_frontier/0}.

%% =============================================================================
%% Tests
%% =============================================================================

%% The frontier is populated by the apply path: after writing/draining, every
%% instance that materialised events has a non-empty `#{Origin => max Seq}` with
%% positive seqs.
frontier_tracks_applied_events() ->
    {Sup, Db, LDir, PDir} = start_db(),
    try
        {ok, T} = bondy_db:open_table(Db, users, #{}),
        ok = write_keys(T, ?KEYS),
        ok = drain_all(),
        Frontiers = maps:values(frontier_map()),
        %% At least one instance materialised events ⇒ a non-empty frontier.
        ?assert(lists:any(fun(F) -> map_size(F) >= 1 end, Frontiers)),
        %% Every recorded per-origin seq is a positive integer.
        lists:foreach(
            fun(F) ->
                maps:foreach(
                    fun(_Origin, Seq) ->
                        ?assert(is_integer(Seq) andalso Seq >= 1)
                    end,
                    F
                )
            end,
            Frontiers
        ),
        ok = bondy_db:close_table(T)
    after
        stop_db(Sup, Db),
        cleanup_dirs(LDir, PDir)
    end.

clean_restart_restores_frontier() ->
    {Sup0, Db0, LDir, PDir} = start_db(),
    Baseline =
        try
            {ok, T} = bondy_db:open_table(Db0, users, #{}),
            ok = write_keys(T, ?KEYS),
            ok = drain_all(),
            B = frontier_map(),
            %% At least one instance must hold data, else the test proves
            %% nothing about restore.
            ?assert(lists:any(fun(F) -> map_size(F) >= 1 end, maps:values(B))),
            ok = bondy_db:close_table(T),
            B
        after
            stop_db(Sup0, Db0)
        end,

    %% CLEAN restart: terminate persisted the frontier into the checkpoint;
    %% reopen restores it (then the WAL tail idempotently tops it up).
    {Sup1, Db1, _, _} = reopen_db(LDir, PDir),
    try
        {ok, _T1} = bondy_db:open_table(Db1, users, #{}),
        ok = drain_all(),
        assert_dominates(Baseline, frontier_map())
    after
        stop_db(Sup1, Db1),
        cleanup_dirs(LDir, PDir)
    end.

crash_restart_reconstructs_frontier() ->
    {Sup0, Db0, LDir, PDir} = start_db(),
    Baseline =
        try
            {ok, T} = bondy_db:open_table(Db0, users, #{}),
            ok = write_keys(T, ?KEYS),
            ok = drain_all(),
            B = frontier_map(),
            ?assert(lists:any(fun(F) -> map_size(F) >= 1 end, maps:values(B))),
            ok = bondy_db:close_table(T),
            B
        after
            stop_db(Sup0, Db0)
        end,

    %% Simulate a CRASH: delete every checkpoint file so the persisted frontier
    %% is gone. The durable leveled projection, the pack-store MST and the WAL
    %% survive — exactly the post-crash on-disk state. Compaction is quiesced
    %% (see start_db/1), so the WAL retains every event and replay reconstructs
    %% the full frontier with no recompute fold.
    Deleted = delete_checkpoints(PDir),
    ?assert(Deleted >= 1),

    {Sup1, Db1, _, _} = reopen_db(LDir, PDir),
    try
        {ok, _T1} = bondy_db:open_table(Db1, users, #{}),
        ok = drain_all(),
        assert_dominates(Baseline, frontier_map())
    after
        stop_db(Sup1, Db1),
        cleanup_dirs(LDir, PDir)
    end.

crash_restart_reconstructs_aw_frontier() ->
    {Sup0, Db0, LDir, PDir} = start_db(#{crdt_module => ?AW}),
    Baseline =
        try
            {ok, T} = bondy_db:open_table(Db0, realm_keys, #{}),
            ok = write_aw_keys(T, ?KEYS),
            ok = drain_all(),
            B = frontier_map(),
            ?assert(lists:any(fun(F) -> map_size(F) >= 1 end, maps:values(B))),
            ok = bondy_db:close_table(T),
            B
        after
            stop_db(Sup0, Db0)
        end,

    Deleted = delete_checkpoints(PDir),
    ?assert(Deleted >= 1),

    {Sup1, Db1, _, _} = reopen_db(LDir, PDir, #{crdt_module => ?AW}),
    try
        {ok, _T1} = bondy_db:open_table(Db1, realm_keys, #{}),
        ok = drain_all(),
        assert_dominates(Baseline, frontier_map())
    after
        stop_db(Sup1, Db1),
        cleanup_dirs(LDir, PDir)
    end.

%% =============================================================================
%% Helpers — lifecycle
%% =============================================================================

start_db() ->
    start_db(#{}).

start_db(ExtraDbOpts) ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Quiesce background AAE + compaction so the test owns the checkpoint
    %% lifecycle deterministically (and the WAL retains every event).
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    LDir = make_tempdir("leveled"),
    PDir = make_tempdir("pack"),
    {Sup, Db} = open_db(LDir, PDir, #{seed => true}, ExtraDbOpts),
    {Sup, Db, LDir, PDir}.

reopen_db(LDir, PDir) ->
    reopen_db(LDir, PDir, #{}).

reopen_db(LDir, PDir, ExtraDbOpts) ->
    %% Reopen over the SAME on-disk dirs; not a genesis peer this time, so no
    %% `seed` opt — the durable state is recovered, not re-seeded.
    {Sup, Db} = open_db(LDir, PDir, #{}, ExtraDbOpts),
    {Sup, Db, LDir, PDir}.

open_db(LDir, PDir, ExtraInstanceOpts) ->
    open_db(LDir, PDir, ExtraInstanceOpts, #{}).

open_db(LDir, PDir, ExtraInstanceOpts, ExtraDbOpts) ->
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    BaseDbOpts = #{
        topology => ?TOPOLOGY,
        topology_opts => #{sup => Sup, dir => LDir},
        shard_count => ?SHARDS,
        fold_module => ?FOLD,
        oplog_instance_opts => maps:merge(
            #{
                backend => bondy_mst_pack_store,
                storage_path => unicode:characters_to_binary(PDir)
            },
            ExtraInstanceOpts
        )
    },
    {ok, Db} = bondy_db:open(?DB, maps:merge(BaseDbOpts, ExtraDbOpts)),
    {Sup, Db}.

stop_db(Sup, Db) ->
    _ =
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end,
    %% Stop every instance so `terminate/2` runs (this is what persists the
    %% clean-shutdown frontier into the checkpoint).
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
            try
                bondy_db_leveled_sup:stop(Sup)
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end,
    ok.

cleanup_dirs(LDir, PDir) ->
    rmrf(LDir),
    rmrf(PDir),
    rmrf(wal_dir_for_this_db()),
    ok.

%% =============================================================================
%% Helpers — writes / frontier
%% =============================================================================

write_keys(T, N) ->
    Realm = <<"r1">>,
    lists:foreach(
        fun(I) ->
            K = <<"k-", (integer_to_binary(I))/binary>>,
            H = bondy_db:tick(T),
            V = <<"v-", (integer_to_binary(I))/binary>>,
            ok = bondy_db:apply(T, Realm, K, {set, H, V})
        end,
        lists:seq(1, N)
    ).

%% One aw_map cell per key (mirrors `bondy_realm_keys`: a cell keyed by a Uri
%% holding `kid => bundle`). The value bundle is a map of binaries, like a real
%% key bundle.
write_aw_keys(T, N) ->
    Realm = <<"r1">>,
    lists:foreach(
        fun(I) ->
            Uri = <<"com.example.realm", (integer_to_binary(I))/binary>>,
            Kid = <<"kid-", (integer_to_binary(I))/binary>>,
            Bundle = #{
                private => <<"priv-", (integer_to_binary(I))/binary>>,
                public => <<"pub-", (integer_to_binary(I))/binary>>
            },
            ok = bondy_db:apply(T, Realm, Uri, {put, Kid, Bundle})
        end,
        lists:seq(1, N)
    ).

%% Wait for every instance's applier to drain so the frontier reflects all
%% writes (the hook fires on the applier's projection write, not on `apply/4`).
drain_all() ->
    lists:foreach(
        fun(I) ->
            _ =
                try
                    bondy_oplog_instance:await_apply(I)
                catch
                    _:_ -> ok
                end
        end,
        bondy_oplog:list_instances()
    ).

%% Map of InstanceId => Frontier over every live instance (the table's shards).
frontier_map() ->
    lists:foldl(
        fun(I, Acc) -> Acc#{I => bondy_oplog_instance:frontier(I)} end,
        #{},
        bondy_oplog:list_instances()
    ).

%% Assert the recovered frontier map dominates the baseline: every baseline
%% instance's per-origin maximum is present and not regressed (max-merge is
%% monotone, so recovery may only equal or advance it).
assert_dominates(Baseline, Recovered) ->
    maps:foreach(
        fun(InstanceId, BaseVV) ->
            RecVV = maps:get(InstanceId, Recovered, #{}),
            maps:foreach(
                fun(Origin, BaseSeq) ->
                    ?assert(maps:get(Origin, RecVV, 0) >= BaseSeq)
                end,
                BaseVV
            )
        end,
        Baseline
    ).

%% Delete every `checkpoint.etf` under the pack dir, simulating the loss of the
%% persisted frontier (a crash). Returns the count deleted.
delete_checkpoints(PDir) ->
    Files = filelib:wildcard(filename:join(PDir, "**/checkpoint.etf")),
    lists:foreach(fun(F) -> _ = file:delete(F) end, Files),
    length(Files).

%% =============================================================================
%% Helpers — dirs
%% =============================================================================

make_tempdir(Prefix) ->
    Base = filename:join([
        "/tmp",
        "bondy_oplog_frontier_recovery",
        Prefix,
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

wal_dir_for_this_db() ->
    filename:join(["/tmp", "bondy_oplog_wal", os:getpid(), atom_to_list(?DB)]).

rmrf(Dir) ->
    %% An instance id names ONE directory (`<Db>-<Shard>`), so a DB's
    %% instances are SIBLINGS rather than children of `<Db>/`. Removing `Dir`
    %% alone therefore leaves their WAL behind, and the next case in the
    %% module reads the previous case's rows.
    _ = [
        file:del_dir_r(P)
     || P <- filelib:wildcard(unicode:characters_to_list(Dir) ++ "-*")
    ],
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
