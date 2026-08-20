%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Durability coverage for the frontier a catalogue bootstrap ADOPTS from its
%% peer (`bondy_oplog_instance:finalize_catalogue_bootstrap/4`).
%%
%% A fresh replica installs the peer's projection snapshot, then adopts the
%% peer's applied-frontier version vector — which includes the peer's
%% COMPACTED-prefix maxima. Those maxima can be reconstructed from NO local
%% durable source on this replica: they are not in its MST (the peer compacted
%% them away before page-sync, so they never transfer), and not in a WAL-tail
%% replay (the bootstrap installed a projection snapshot, not events through the
%% WAL). The adoption puts them in the in-memory registry only.
%%
%% Before the fix, that frontier reached the durable checkpoint solely at the
%% next clean `terminate/2`. An UNCLEAN restart (kill/crash) therefore lost the
%% compacted-prefix maxima, and the convergence oracle reported DIVERGED forever
%% despite the replica holding all the data. The fix persists the adopted
%% frontier into the checkpoint AT bootstrap.
%%
%% This test drives the full durable stack (`bondy_db` facade → per-shard
%% `bondy_oplog` instance → leveled projection + pack-store MST) and asserts the
%% adopted frontier is in the durable checkpoint IMMEDIATELY after bootstrap —
%% before any clean stop — so `restore_frontier/2` recovers it on any restart.
%% The restore half is covered by `bondy_oplog_frontier_recovery_test`.
%% =============================================================================
-module(bondy_oplog_bootstrap_frontier_durability_test).

-include_lib("eunit/include/eunit.hrl").

-define(FOLD, bondy_oplog_crdt_lww_register).
-define(SHARDS, 4).
-define(DB, bootstrap_frontier_durability_db).
-define(TOPOLOGY, bondy_db_topology_per_entity).

%% A phantom origin with no local events — it stands in for the peer's
%% compacted-prefix maxima, reconstructable from no local durable source.
-define(PHANTOM_ORIGIN, <<"peer-compacted-origin">>).
-define(PHANTOM_SEQ, 4242).

%% =============================================================================
%% Test generators
%% =============================================================================

adopted_frontier_is_durable_at_bootstrap_test_() ->
    {timeout, 120, fun adopted_frontier_is_durable_at_bootstrap/0}.

%% =============================================================================
%% Tests
%% =============================================================================

%% After a catalogue-bootstrap adoption, the phantom (compacted-prefix) origin's
%% maximum must be BOTH in the live registry frontier AND persisted in the
%% durable checkpoint — the latter WITHOUT a clean stop, so an unclean restart
%% still recovers it.
adopted_frontier_is_durable_at_bootstrap() ->
    {Sup, Db, LDir, PDir} = start_db(),
    try
        {ok, T} = bondy_db:open_table(Db, users, #{}),
        %% Some local writes so the instances are real durable shards with a
        %% populated MST — the phantom origin is deliberately NOT among them.
        ok = write_keys(T, 12),
        ok = drain_all(),

        PeerFrontier = #{?PHANTOM_ORIGIN => ?PHANTOM_SEQ},

        %% Adopt the peer's frontier on every instance, exactly as the catalogue
        %% bootstrap does at completion. `WasLive = true` keeps the lifecycle
        %% untouched (no `mark_live` side effect).
        Instances = bondy_oplog:list_instances(),
        ?assert(Instances =/= []),
        lists:foreach(
            fun(I) ->
                ok = bondy_oplog_instance:finalize_catalogue_bootstrap(
                    I, 0, PeerFrontier, true
                )
            end,
            Instances
        ),

        %% 1. Adopted into the live registry frontier of every instance.
        lists:foreach(
            fun(I) ->
                Live = bondy_oplog_instance:frontier(I),
                ?assertEqual(
                    ?PHANTOM_SEQ,
                    maps:get(?PHANTOM_ORIGIN, Live, undefined)
                )
            end,
            Instances
        ),

        %% 2. THE FIX: durable on disk NOW, before any `terminate/2`. Read the
        %%    actual checkpoint files (what `restore_frontier/2` reads on
        %%    restart), not the registry cache. Without the fix there are no
        %%    checkpoint files — a freshly-bootstrapped shard that has neither
        %%    compacted nor been cleanly stopped has never written one.
        Files = filelib:wildcard(
            filename:join(PDir, "**/checkpoint.etf")
        ),
        ?assert(length(Files) >= 1),
        lists:foreach(
            fun(F) ->
                {ok, Bin} = file:read_file(F),
                case erlang:binary_to_term(Bin) of
                    {checkpoint_v1, _W, {projection_managed, frontier, VV}} ->
                        ?assertEqual(
                            ?PHANTOM_SEQ,
                            maps:get(?PHANTOM_ORIGIN, VV, undefined)
                        );
                    Other ->
                        erlang:error({unexpected_checkpoint, F, Other})
                end
            end,
            Files
        ),

        ok = bondy_db:close_table(T)
    after
        stop_db(Sup, Db),
        cleanup_dirs(LDir, PDir)
    end.

%% =============================================================================
%% Helpers — lifecycle (mirrors bondy_oplog_frontier_recovery_test)
%% =============================================================================

start_db() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Quiesce background AAE + compaction so the test owns the checkpoint
    %% lifecycle deterministically (a compaction would ALSO write the frontier
    %% into the checkpoint, masking whether the bootstrap path did).
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    LDir = make_tempdir("leveled"),
    PDir = make_tempdir("pack"),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    DbOpts = #{
        topology => ?TOPOLOGY,
        topology_opts => #{sup => Sup, dir => LDir},
        shard_count => ?SHARDS,
        fold_module => ?FOLD,
        oplog_instance_opts => #{
            backend => bondy_mst_pack_store,
            storage_path => unicode:characters_to_binary(PDir),
            seed => true
        }
    },
    {ok, Db} = bondy_db:open(?DB, DbOpts),
    {Sup, Db, LDir, PDir}.

stop_db(Sup, Db) ->
    _ =
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end,
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

%% =============================================================================
%% Helpers — dirs
%% =============================================================================

make_tempdir(Prefix) ->
    Base = filename:join([
        "/tmp",
        "bondy_oplog_bootstrap_frontier_durability",
        Prefix,
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

wal_dir_for_this_db() ->
    filename:join(["/tmp", "bondy_oplog_wal", os:getpid(), atom_to_list(?DB)]).

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
