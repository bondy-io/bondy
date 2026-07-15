%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Fused-writer rollout, Step 4: cross-node convergence for `fused` ephemeral
%% instances. A fused instance has NO applier, so the peer-merge projection
%% replay that the applier normally runs (after `integrate_peer_root`) runs
%% INLINE in the instance. These tests prove a fused replica makes
%% peer-authored events visible to `bondy_db:read/3` after a real MST `sync`
%% WITHOUT any explicit replay barrier — the distinguishing difference from
%% the non-fused path (cf. `bondy_db_mv_register_e2e_test`, which must call
%% `replay_cell_events_sync/1` because production casts it async).
%%
%% Coverage: distinct-key convergence (inline replay folds peer events),
%% same-key lww convergence (equal value + equal MST root), read-your-peer's
%% -write after a one-way merge, and a catalogue compaction taken AFTER a
%% remote merge (the fused `remote_events_pending = false` + cursor
%% re-anchor path, which never touches an applier).

-module(bondy_db_fused_convergence_test).

-include_lib("eunit/include/eunit.hrl").

fused_convergence_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"distinct keys converge via inline replay (no applier)",
            {timeout, 30, fun converge_distinct_keys/0}},
        {"same-key concurrent writes converge (lww + equal roots)",
            {timeout, 30, fun converge_same_key_lww/0}},
        {"read-your-peer's-write after a one-way merge",
            {timeout, 30, fun ryow_after_merge/0}},
        {"catalogue compaction after a remote merge",
            {timeout, 30, fun compaction_under_remote/0}}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Drive sync/compaction explicitly — no background dispatch.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

%% A writes k1, B writes k2 (disjoint keys, no conflict). After a
%% bidirectional sync each replica answers reads for BOTH keys and the two
%% MST roots are identical — the peer events were folded into each
%% projection by the inline replay, with no applier and no replay barrier.
converge_distinct_keys() ->
    {DbA, Ta, Ia} = open_fused(fconv_dk_a),
    {DbB, Tb, Ib} = open_fused(fconv_dk_b),
    Ha = bondy_db:tick(Ta),
    ok = bondy_db:apply(Ta, <<"r">>, <<"k1">>, {set, Ha, <<"va">>}),
    Hb = bondy_db:tick(Tb),
    ok = bondy_db:apply(Tb, <<"r">>, <<"k2">>, {set, Hb, <<"vb">>}),
    %% Each local write must reach its own MST (the fused drain) and publish
    %% before the peer pulls it.
    ok = wait_live(Ia, 1),
    ok = wait_live(Ib, 1),
    %% Bidirectional sync. NO replay/2 barrier.
    {ok, _} = bondy_oplog:sync(Ia, Ib),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    ?assertEqual(<<"va">>, val(bondy_db:read(Ta, <<"r">>, <<"k1">>))),
    ?assertEqual(<<"vb">>, val(bondy_db:read(Ta, <<"r">>, <<"k2">>))),
    ?assertEqual(<<"va">>, val(bondy_db:read(Tb, <<"r">>, <<"k1">>))),
    ?assertEqual(<<"vb">>, val(bondy_db:read(Tb, <<"r">>, <<"k2">>))),
    ?assertEqual(bondy_oplog:root_hash(Ia), bondy_oplog:root_hash(Ib)),
    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

%% Concurrent writes to the SAME key from two origins. lww resolves to one
%% winner; both replicas must converge to the identical read (value + HLC)
%% and the identical MST root.
converge_same_key_lww() ->
    {DbA, Ta, Ia} = open_fused(fconv_sk_a),
    {DbB, Tb, Ib} = open_fused(fconv_sk_b),
    Ha = bondy_db:tick(Ta),
    ok = bondy_db:apply(Ta, <<"r">>, <<"k">>, {set, Ha, <<"va">>}),
    Hb = bondy_db:tick(Tb),
    ok = bondy_db:apply(Tb, <<"r">>, <<"k">>, {set, Hb, <<"vb">>}),
    ok = wait_live(Ia, 1),
    ok = wait_live(Ib, 1),
    {ok, _} = bondy_oplog:sync(Ia, Ib),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    Ra = bondy_db:read(Ta, <<"r">>, <<"k">>),
    Rb = bondy_db:read(Tb, <<"r">>, <<"k">>),
    ?assertEqual(Ra, Rb),
    ?assert(lists:member(val(Ra), [<<"va">>, <<"vb">>])),
    ?assertEqual(bondy_oplog:root_hash(Ia), bondy_oplog:root_hash(Ib)),
    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

%% B pulls A's write via a single one-way sync and reads it back (the inline
%% replay made it visible). B then writes the same key: the merge bumped B's
%% HLC past A's, so B's write dominates.
ryow_after_merge() ->
    {DbA, Ta, Ia} = open_fused(fconv_ryow_a),
    {DbB, Tb, Ib} = open_fused(fconv_ryow_b),
    Ha = bondy_db:tick(Ta),
    ok = bondy_db:apply(Ta, <<"r">>, <<"k">>, {set, Ha, <<"va">>}),
    ok = wait_live(Ia, 1),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    %% Read-your-peer's-write: no applier, no replay barrier.
    ?assertEqual(<<"va">>, val(bondy_db:read(Tb, <<"r">>, <<"k">>))),
    Hb = bondy_db:tick(Tb),
    ?assert(Hb > Ha),
    ok = bondy_db:apply(Tb, <<"r">>, <<"k">>, {set, Hb, <<"vb">>}),
    ok = wait_live(Ib, 2),
    ?assertEqual(<<"vb">>, val(bondy_db:read(Tb, <<"r">>, <<"k">>))),
    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

%% After B merges A's remote events, a catalogue compaction on B must run to
%% completion through the fused path (`remote_events_pending` stays false →
%% no `begin_async_catch_up`, which would need an applier) and re-anchor the
%% fused replay cursor on the post-truncate root. Reads still resolve for
%% both the remote and the local keys.
compaction_under_remote() ->
    {DbA, Ta, Ia} = open_fused(fconv_comp_a),
    {DbB, Tb, Ib} = open_fused(fconv_comp_b),
    Hk1 = bondy_db:tick(Ta),
    ok = bondy_db:apply(Ta, <<"r">>, <<"k1">>, {set, Hk1, <<"a1">>}),
    Hk2 = bondy_db:tick(Ta),
    ok = bondy_db:apply(Ta, <<"r">>, <<"k2">>, {set, Hk2, <<"a2">>}),
    ok = wait_live(Ia, 2),
    Hk3 = bondy_db:tick(Tb),
    ok = bondy_db:apply(Tb, <<"r">>, <<"k3">>, {set, Hk3, <<"b3">>}),
    ok = wait_live(Ib, 1),
    %% B pulls A's two events → B now holds k1,k2 (remote) + k3 (local).
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    ?assertEqual(<<"a1">>, val(bondy_db:read(Tb, <<"r">>, <<"k1">>))),
    %% Self-peer at B's live root so the compaction frontier can advance.
    Root = bondy_oplog:root_hash(Ib),
    bondy_oplog_peer_state:record_sync_complete({peer, fconv_dummy}, Ib, Root),
    bondy_oplog_peer_state:sync(),
    ?assertMatch({ok, {compacted, _, _}}, bondy_oplog:compact(Ib)),
    %% Projection survived the truncate; cursor re-anchored. All three keys
    %% (two remote, one local) still read back.
    ?assertEqual(<<"a1">>, val(bondy_db:read(Tb, <<"r">>, <<"k1">>))),
    ?assertEqual(<<"a2">>, val(bondy_db:read(Tb, <<"r">>, <<"k2">>))),
    ?assertEqual(<<"b3">>, val(bondy_db:read(Tb, <<"r">>, <<"k3">>))),
    bondy_oplog_peer_state:forget_peer({peer, fconv_dummy}),
    ok = bondy_db:close(DbA),
    ok = bondy_db:close(DbB).

%% =============================================================================
%% Helpers
%% =============================================================================

open_fused(Name) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(Name, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        oplog_instance_opts => #{origin => Origin}
    }),
    {ok, T} = bondy_db:open_table(Db, items, #{fused => true}),
    {Db, T, instance_of(T)}.

instance_of(Table) ->
    #{0 := InstanceId} = maps:get(instance_ids, Table),
    InstanceId.

val({ok, {V, _Hlc}}) -> V.

wait_live(Id, N) ->
    wait_until(fun() -> live_size(Id) >= N end, 5000).

live_size(Id) ->
    case bondy_oplog_registry:live_size(Id) of
        undefined -> 0;
        N -> N
    end.

wait_until(_Pred, Remaining) when Remaining =< 0 ->
    error(timeout);
wait_until(Pred, Remaining) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(Pred, Remaining - 20)
    end.
