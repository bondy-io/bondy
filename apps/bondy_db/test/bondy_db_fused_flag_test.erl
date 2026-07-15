%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Fused-writer rollout, Step 1: the ephemeral `fused` flag is wired
%% end-to-end (provisioning only, no behaviour change). Pins: a table
%% defaults to NOT fused; an ephemeral (ets projection) table may opt in
%% and the flag is recorded in both `bondy_db:info/1` and the per-instance
%% `bondy_oplog_registry`; and `fused => true` is refused on a durable
%% (leveled) projection — the durable two-process pipeline must stay split.

-module(bondy_db_fused_flag_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

fused_flag_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun ephemeral_defaults_not_fused/0,
        fun ephemeral_opt_in_fused/0,
        fun fused_requires_ephemeral_guard/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

ephemeral_defaults_not_fused() ->
    %% No `fused` opt → the table is not fused; every shard instance
    %% records `false`. This is the no-behaviour-change default that
    %% keeps every existing (durable and ephemeral) table untouched.
    with_db(#{fold_module => lww_register}, fun(Db) ->
        {ok, T} = bondy_db:open_table(Db, t_default, #{}),
        ?assertEqual(false, maps:get(fused, bondy_db:info(T))),
        ?assertEqual(false, instance_fused(T)),
        ok = bondy_db:close_table(T)
    end).

ephemeral_opt_in_fused() ->
    %% Opt-in on an ephemeral (ets projection — the only kind the memory
    %% topology provisions) table: the flag flows provisioning → registry
    %% and is visible via both `info/1` and `bondy_oplog_registry:fused/1`.
    with_db(#{fold_module => lww_register}, fun(Db) ->
        {ok, T} = bondy_db:open_table(Db, t_fused, #{fused => true}),
        ?assertEqual(true, maps:get(fused, bondy_db:info(T))),
        ?assertEqual(true, instance_fused(T)),
        ok = bondy_db:close_table(T)
    end).

fused_requires_ephemeral_guard() ->
    %% The `fused ⇒ ephemeral` invariant. Off is always fine; on is fine
    %% only for an ets projection; on a durable (leveled) projection it is
    %% refused at open, before a single shard is provisioned.
    ?assertEqual(ok, bondy_db:assert_fused_requires_ephemeral(false, leveled)),
    ?assertEqual(ok, bondy_db:assert_fused_requires_ephemeral(false, ets)),
    ?assertEqual(ok, bondy_db:assert_fused_requires_ephemeral(true, ets)),
    ?assertError(
        {fused_requires_ephemeral, leveled},
        bondy_db:assert_fused_requires_ephemeral(true, leveled)
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

%% The `fused` flag as recorded by the per-instance registry for shard 0.
instance_fused(Table) ->
    InstanceIds = maps:get(instance_ids, Table),
    InstanceId = maps:get(0, InstanceIds),
    bondy_oplog_registry:fused(InstanceId).

mk_ns() ->
    list_to_atom(
        "ff_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

with_db(Opts, Fun) ->
    Name = mk_ns(),
    {ok, Db} = bondy_db:open(
        Name,
        maps:merge(
            #{
                topology => bondy_db_topology_memory,
                shard_count => 1
            },
            Opts
        )
    ),
    try
        Fun(Db)
    after
        catch bondy_db:close(Db)
    end.
