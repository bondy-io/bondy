%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% End-to-end test for the Enable-Wins Flag through the public `bondy_db`
%% facade (ephemeral memory topology). Proves the tier_2 flag wires through
%% the cell kernel + applier + projection + read, including the substrate's
%% per-write causal-context stamp: a disable observes the prior enable and
%% clears the flag; a later enable sets it again.

-module(bondy_db_ew_flag_e2e_test).

-include_lib("eunit/include/eunit.hrl").

-define(CRDT, bondy_oplog_crdt_ew_flag).

ew_flag_e2e_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_db),
            {ok, Db} = bondy_db:open(ew_flag_db, #{
                topology => bondy_db_topology_memory,
                shard_count => 1,
                fold_module => lww_register,
                crdt_module => ?CRDT
            }),
            Db
        end,
        fun(Db) -> ok = bondy_db:close(Db) end, fun(Db) ->
            [
                {"tier_2 + crdt_module reported", fun() -> info(Db) end},
                {"enable / disable / re-enable", fun() -> toggle(Db) end},
                {"delete/3 disables; sweep reclaims once stable", fun() ->
                    delete_and_sweep(Db)
                end}
            ]
        end}.

info(Db) ->
    {ok, T} = bondy_db:open_table(Db, t_info, #{}),
    ?assertEqual(?CRDT, maps:get(crdt_module, bondy_db:info(T))),
    ?assertEqual(tier_2, ?CRDT:causal_tier()),
    ok = bondy_db:close_table(T).

toggle(Db) ->
    {ok, T} = bondy_db:open_table(Db, t_flag, #{}),
    %% Fresh cell: absent reads as not_found (no enable yet).
    ?assertEqual({error, not_found}, bondy_db:read(T, <<"r1">>, <<"f">>)),
    ok = bondy_db:apply(T, <<"r1">>, <<"f">>, enable),
    ?assertEqual(true, read_value(T, <<"f">>)),
    %% A disable observes the prior enable and clears the flag.
    ok = bondy_db:apply(T, <<"r1">>, <<"f">>, disable),
    ?assertEqual(false, read_value(T, <<"f">>)),
    %% A later enable sets it again.
    ok = bondy_db:apply(T, <<"r1">>, <<"f">>, enable),
    ?assertEqual(true, read_value(T, <<"f">>)),
    ok = bondy_db:close_table(T).

%% `removal_op() -> disable` + `stabilize/2` end-to-end
%% (BONDY_DB_RECLAMATION_PROOF.md §9): `delete/3` on an ew table issues a
%% disable (value hidden at once, cell retained), and the applier's stable-cell
%% sweep physically discards it once its HLC is strictly below the stability
%% point — while a LIVE (enabled) flag survives the same sweep.
delete_and_sweep(Db) ->
    {ok, T} = bondy_db:open_table(Db, t_sweep, #{}),
    ok = bondy_db:apply(T, <<"r1">>, <<"doomed">>, enable),
    ok = bondy_db:apply(T, <<"r1">>, <<"keeper">>, enable),

    %% delete/3 now works on a flag table (was {error, {no_removal_op, _}}).
    ok = bondy_db:delete(T, <<"r1">>, <<"doomed">>),
    ?assertEqual(false, read_value(T, <<"doomed">>)),

    InstanceId = instance_of(T),
    ok = bondy_oplog_instance:await_apply(InstanceId),
    Pid = bondy_oplog_registry:applier_pid(InstanceId),
    ?assert(is_pid(Pid)),

    %% Below the disable's HLC nothing is reclaimed (strict bound)...
    {ok, Low} = bondy_oplog_applier:sweep_stable_cells(Pid, 1),
    ?assertEqual(0, maps:get(discarded, Low)),

    %% ...at a stability point above every written HLC the disabled cell is
    %% physically discarded and the live one survives.
    Stable = bondy_db:tick(T) + 1,
    {ok, Stats} = bondy_oplog_applier:sweep_stable_cells(Pid, Stable),
    ?assertEqual(1, maps:get(discarded, Stats)),
    ?assertEqual({error, not_found}, bondy_db:read(T, <<"r1">>, <<"doomed">>)),
    ?assertEqual(true, read_value(T, <<"keeper">>)),
    ok = bondy_db:close_table(T).

%% @private
%% The memory topology collapses to one instance per shard (`per_shard`), so
%% the db's single shard-0 instance covers every table incl. t_sweep.
instance_of(_T) ->
    [InstanceId | _] = [
        I
     || I <- bondy_oplog:list_instances(),
        binary:match(I, <<"ew_flag_db-">>) =/= nomatch
    ],
    InstanceId.

%% Read the boolean value, ignoring the HLC.
read_value(T, Key) ->
    {ok, {V, _Hlc}} = bondy_db:read(T, <<"r1">>, Key),
    V.
