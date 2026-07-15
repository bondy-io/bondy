%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PR-A: `causal_tier()` is wired end-to-end (provisioning only, no
%% behaviour change). Pins: the registry records the tier; a table with
%% no native CRDT (or a tier_0 native CRDT) defaults to `tier_0`; and
%% `open_table` fails fast when a `tier_2` CRDT is not `order_independent`.

-module(bondy_oplog_causal_tier_test).

-include_lib("eunit/include/eunit.hrl").

-define(LWW, bondy_oplog_crdt_lww_register).

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

causal_tier_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun registry_defaults_tier_0/0,
        fun registry_records_tier_2/0,
        fun open_table_no_crdt_is_tier_0/0,
        fun open_table_tier_0_native_crdt/0,
        fun tier_2_requires_order_independent/0
    ]}.

%% =============================================================================
%% Registry
%% =============================================================================

registry_defaults_tier_0() ->
    NS = mk_ns(),
    {C, P} = register_shard(NS, #{fold_module => lww_register}),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    ?assertEqual(tier_0, bondy_oplog_core_registry:entry_causal_tier(Entry)),
    teardown_shard(NS, C, P).

registry_records_tier_2() ->
    NS = mk_ns(),
    {C, P} = register_shard(NS, #{
        fold_module => lww_register, causal_tier => tier_2
    }),
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    ?assertEqual(tier_2, bondy_oplog_core_registry:entry_causal_tier(Entry)),
    teardown_shard(NS, C, P).

%% =============================================================================
%% Public open_table provisioning
%% =============================================================================

open_table_no_crdt_is_tier_0() ->
    with_db(#{fold_module => lww_register}, fun(Db) ->
        {ok, T} = bondy_db:open_table(Db, t_no_crdt, #{}),
        ?assertEqual(tier_0, maps:get(causal_tier, bondy_db:info(T))),
        ok = bondy_db:close_table(T)
    end).

open_table_tier_0_native_crdt() ->
    %% A native tier_0 CRDT (lww) records tier_0 and opens normally.
    with_db(#{fold_module => lww_register, crdt_module => ?LWW}, fun(Db) ->
        {ok, T} = bondy_db:open_table(Db, t_lww, #{}),
        Info = bondy_db:info(T),
        ?assertEqual(?LWW, maps:get(crdt_module, Info)),
        ?assertEqual(tier_0, maps:get(causal_tier, Info)),
        ok = bondy_db:close_table(T)
    end).

tier_2_requires_order_independent() ->
    %% A tier_2 CRDT that is NOT order_independent must be refused at
    %% open, before any shard/instance is provisioned.
    with_db(
        #{
            fold_module => lww_register,
            crdt_module => bondy_oplog_crdt_tier2_bad
        },
        fun(Db) ->
            ?assertError(
                {tier_2_requires_order_independent, bondy_oplog_crdt_tier2_bad},
                bondy_db:open_table(Db, t_bad, #{})
            )
        end
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_ns() ->
    list_to_atom(
        "ct_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

register_shard(NS, Extra) ->
    {ok, C} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, P} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    Config = maps:merge(
        #{
            shard_count => 1,
            cache_adapter => bondy_oplog_cache_ets,
            cache_handle => C,
            projection_adapter => bondy_oplog_projection_ets,
            projection_handle => P,
            overlay => disabled
        },
        Extra
    ),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, Config),
    {C, P}.

teardown_shard(NS, C, P) ->
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok = bondy_oplog_projection_ets:close(P),
    ok = bondy_oplog_cache_ets:close(C).

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
