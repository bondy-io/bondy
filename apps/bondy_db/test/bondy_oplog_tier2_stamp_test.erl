%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PR-C: the generic tier_2 context-stamp. A `tier_2` table routes
%% `bondy_db:apply/4` through `apply_with_context`, which reads the cell's
%% current causal context (`context_of/1`) in the applier's single-cell
%% scope and stamps it into the event `meta` before WAL append. The CRDT's
%% `apply_op/4` then receives it.
%%
%% Driven by `bondy_oplog_crdt_ctx_probe` (tier_2, order_independent),
%% whose `context_of(State) = length(State)` (the count of ops absorbed),
%% so the recorded `(Op, Context)` pairs prove the stamp read the CURRENT
%% state — i.e. read-your-writes across two successive writes.

-module(bondy_oplog_tier2_stamp_test).

-include_lib("eunit/include/eunit.hrl").

-define(PROBE, bondy_oplog_crdt_ctx_probe).

tier2_stamp_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            {ok, Db} = bondy_db:open(probe_db, #{
                topology => bondy_db_topology_memory,
                shard_count => 1,
                fold_module => lww_register,
                crdt_module => ?PROBE
            }),
            Db
        end,
        fun(Db) -> ok = bondy_db:close(Db) end, fun(Db) ->
            [
                {"info reports tier_2", fun() -> reports_tier_2(Db) end},
                {"stamps evolving context (read-your-writes)", fun() ->
                    stamps_evolving_context(Db)
                end}
            ]
        end}.

reports_tier_2(Db) ->
    {ok, T} = bondy_db:open_table(Db, items_a, #{}),
    ?assertEqual(tier_2, maps:get(causal_tier, bondy_db:info(T))),
    ok = bondy_db:close_table(T).

stamps_evolving_context(Db) ->
    {ok, T} = bondy_db:open_table(Db, items_b, #{}),
    %% First write: cell is empty, context_of([]) = 0 → meta 0 →
    %% apply_op records {op1, 0}.
    ok = bondy_db:apply(T, <<"r">>, <<"k">>, op1),
    %% Second write to the SAME cell: context_of([{op1,0}]) = 1 (it sees
    %% the first write — read-your-writes via the await barrier) → meta 1
    %% → apply_op records {op2, 1}.
    ok = bondy_db:apply(T, <<"r">>, <<"k">>, op2),
    %% to_value is the in-order list of recorded (Op, Context) pairs.
    {ok, {Value, _Hlc}} = bondy_db:read(T, <<"r">>, <<"k">>),
    ?assertEqual([{op1, 0}, {op2, 1}], Value),
    ok = bondy_db:close_table(T).
