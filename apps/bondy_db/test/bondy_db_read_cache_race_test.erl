%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% A read that misses the per-shard read cache fills it with the value it read
%% from the projection. This forces the interleaving where a newer value is
%% installed, and the cache entry invalidated, between that projection read
%% and the fill: the reader is held just after `bondy_oplog_projection_ets:get/3`
%% returns while the newer write lands. A later read must return the newer
%% value. Covers one reader and one writer on one key; the order of the
%% invalidation's own steps is covered by `proofs/tla/ReadCache.tla` only.

-module(bondy_db_read_cache_race_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_lww_register).
-define(REALM, <<"r">>).
-define(KEY, <<"k">>).

read_cache_race_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"a fill racing an install does not pin the older value",
                fun fill_racing_install/0}
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

fill_racing_install() ->
    {ok, Db} = bondy_db:open(read_cache_race, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register
    }),
    {ok, T} = bondy_db:open_table(Db, items, #{
        fold_module => lww_register,
        crdt_module => ?CRDT
    }),
    Test = self(),
    ok = meck:new(bondy_oplog_projection_ets, [passthrough]),
    try
        ok = bondy_db:apply(T, ?REALM, ?KEY, {set, bondy_db:tick(T), old}),
        Reader = spawn_link(fun() ->
            receive
                go -> ok
            end,
            Test ! {read, bondy_db:read(T, ?REALM, ?KEY)}
        end),
        ok = meck:expect(bondy_oplog_projection_ets, get, fun(Tab, B, K) ->
            Result = meck:passthrough([Tab, B, K]),
            case self() of
                Reader ->
                    Test ! {read_projection, Result},
                    receive
                        resume -> ok
                    end;
                _ ->
                    ok
            end,
            Result
        end),
        Reader ! go,
        receive
            {read_projection, {ok, _}} -> ok
        after 5000 -> error(reader_never_read)
        end,
        ok = bondy_db:apply(T, ?REALM, ?KEY, {set, bondy_db:tick(T), new}),
        Reader ! resume,
        receive
            {read, {ok, {old, _}}} -> ok
        after 5000 -> error(reader_never_returned)
        end,
        ?assertMatch({ok, {new, _}}, bondy_db:read(T, ?REALM, ?KEY))
    after
        meck:unload(bondy_oplog_projection_ets),
        ok = bondy_db:close(Db)
    end.
