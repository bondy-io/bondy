%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Durable stop/restart end-to-end tests for the tier_2 CRDTs
%% (`bondy_oplog_crdt_mv_register`, `bondy_oplog_crdt_aw_map`).
%%
%% A tier_2 type's convergence rests on a substrate precondition
%% (documented in both modules' "Convergence preconditions"): an origin's
%% observed causal context for a cell never regresses between its
%% successive writes. Across a process restart that holds only if recovery
%% rebuilds the cell's causal context (the DVV / version vector, which
%% lives in the projection's `StateBytes`) from durable state BEFORE the
%% origin stamps another write. If it does not, a post-restart same-origin
%% write re-mints a used dot and the value SILENTLY forks into a spurious
%% sibling.
%%
%% These tests pin that across a real graceful stop/restart on the durable
%% stack (leveled projection + pack-store MST + WAL, all rooted under a
%% `storage_path` that also auto-persists the origin — PR-J4/J6):
%%
%%   1. write a value, read it back;
%%   2. close the table + DB, stop every oplog instance, stop the leveled
%%      supervisor (every Bookie under it) — a clean shutdown, on-disk
%%      state survives;
%%   3. reopen a FRESH leveled supervisor over the SAME directories +
%%      `storage_path` (the same-`storage_path` reopen recovers the same
%%      origin, WAL and MST) — the PR-D blocker was a reopen-same-`Sup`
%%      leveled `noproc`; a fresh `Sup` over the same dir is the fix;
%%   4. assert the prior value survived (the DVV round-tripped through
%%      durable recovery), and
%%   5. assert a post-restart same-origin write DOMINATES — a single
%%      value, NOT a `[old, new]` sibling pair. That dominance is the
%%      precondition-#2 proof: recovery rebuilt the context so the origin's
%%      next dot strictly succeeds the pre-restart one.
%%
%% `mv_register` proves the per-cell-context recovery path; `aw_map`
%% additionally proves the global per-origin Seq (the dot axis) recovers
%% (PR-J1/J2), since its observed-remove depends on the new dot being
%% fresh AND the old dot being observed.

-module(bondy_db_tier2_durability_test).

-include_lib("eunit/include/eunit.hrl").

-define(MV, bondy_oplog_crdt_mv_register).
-define(AW, bondy_oplog_crdt_aw_map).
-define(DB, bondy_db_tier2_durable_db).
-define(R, <<"r">>).
-define(K, <<"k">>).

%% =============================================================================
%% Fixture
%% =============================================================================

tier2_durability_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(Dirs) ->
            {"mv_register value + context survive a stop/restart",
                {timeout, 90, fun() -> mv_register_survives_restart(Dirs) end}}
        end,
        fun(Dirs) ->
            {"aw_map value + observed-remove survive a stop/restart",
                {timeout, 90, fun() -> aw_map_survives_restart(Dirs) end}}
        end
    ]}.

setup() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dirs = #{
        leveled => make_tempdir("leveled"),
        pack => make_tempdir("pack")
    },
    Dirs.

cleanup(Dirs) ->
    stop_everything(),
    rmrf(maps:get(leveled, Dirs)),
    rmrf(maps:get(pack, Dirs)),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

mv_register_survives_restart(Dirs) ->
    %% --- First lifetime: write v1, read it back. ---
    {Db0, Sup0} = open(?MV, Dirs),
    {ok, T0} = bondy_db:open_table(Db0, items, #{}),
    ?assertEqual(tier_2, maps:get(causal_tier, bondy_db:info(T0))),
    ok = bondy_db:apply(T0, ?R, ?K, {set, <<"v1">>}),
    ?assertEqual({ok, [<<"v1">>]}, value(bondy_db:read(T0, ?R, ?K))),
    close(Db0, Sup0),

    %% --- Second lifetime: same dirs + storage_path + recovered origin. ---
    {Db1, Sup1} = open(?MV, Dirs),
    {ok, T1} = bondy_db:open_table(Db1, items, #{}),
    try
        %% The DVV survived recovery: v1 is still the value.
        ?assertEqual({ok, [<<"v1">>]}, value(bondy_db:read(T1, ?R, ?K))),
        %% A same-origin write that observed v1 (via the recovered
        %% context) DOMINATES — no spurious `[v1, v2]` sibling.
        ok = bondy_db:apply(T1, ?R, ?K, {set, <<"v2">>}),
        ?assertEqual({ok, [<<"v2">>]}, value(bondy_db:read(T1, ?R, ?K)))
    after
        close(Db1, Sup1)
    end.

aw_map_survives_restart(Dirs) ->
    %% --- First lifetime: put color=red. ---
    {Db0, Sup0} = open(?AW, Dirs),
    {ok, T0} = bondy_db:open_table(Db0, items, #{}),
    ok = bondy_db:apply(T0, ?R, ?K, {put, <<"color">>, <<"red">>}),
    ?assertEqual(
        {ok, #{<<"color">> => [<<"red">>]}}, value(bondy_db:read(T0, ?R, ?K))
    ),
    close(Db0, Sup0),

    %% --- Second lifetime. ---
    {Db1, Sup1} = open(?AW, Dirs),
    {ok, T1} = bondy_db:open_table(Db1, items, #{}),
    try
        %% The dot-store + context survived recovery.
        ?assertEqual(
            {ok, #{<<"color">> => [<<"red">>]}},
            value(bondy_db:read(T1, ?R, ?K))
        ),
        %% A same-origin put that observed red's dot OBSERVED-REMOVES it
        %% (a fresh dot for blue; red dropped because the recovered
        %% context observed it). The result is the single value blue, NOT
        %% the sibling set `[blue, red]` a context/Seq loss would yield.
        ok = bondy_db:apply(T1, ?R, ?K, {put, <<"color">>, <<"blue">>}),
        ?assertEqual(
            {ok, #{<<"color">> => [<<"blue">>]}},
            value(bondy_db:read(T1, ?R, ?K))
        )
    after
        close(Db1, Sup1)
    end.

%% =============================================================================
%% Harness
%% =============================================================================

%% Open the durable stack: a leveled projection (single-bookie topology
%% over a fresh supervisor) + a pack-store MST + WAL, all rooted at a
%% `storage_path` that also auto-persists/recovers the origin. `seed` makes
%% the single genesis instance `live` so its applier drains (no peer to
%% bootstrap from). No explicit `origin` is passed: a same-`storage_path`
%% reopen recovers the persisted one, which is exactly the property under
%% test.
open(CrdtMod, Dirs) ->
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(?DB, #{
        topology => bondy_db_topology_single_bookie,
        topology_opts => #{sup => Sup, dir => maps:get(leveled, Dirs)},
        shard_count => 1,
        fold_module => lww_register,
        crdt_module => CrdtMod,
        oplog_instance_opts => #{
            backend => bondy_mst_pack_store,
            storage_path =>
                unicode:characters_to_binary(maps:get(pack, Dirs)),
            seed => true
        }
    }),
    {Db, Sup}.

%% Graceful shutdown: close the DB (stops the leveled Bookies), stop every
%% oplog instance (they cache now-dead Bookie handles), then stop the
%% leveled supervisor. The on-disk leveled/pack/WAL state survives.
close(Db, Sup) ->
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

%% Strip the read HLC; tier_2 reads return `{ok, {Value, Hlc}}`.
value({ok, {V, _Hlc}}) -> {ok, V};
value(Other) -> Other.

%% =============================================================================
%% Tempdirs
%% =============================================================================

make_tempdir(Prefix) ->
    Base = filename:join([
        "/tmp/" ++ os:getpid(),
        "bondy_db_tier2_durability",
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
