%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Step 3 (design §11.3) — the WAMP fold modules: proves that the per-table
%% CRDT each table is wired to (via `bondy_namespace_catalog:fold_opts/1`) has
%% the right op-apply and concurrent-merge semantics for that table's WAMP data,
%% independent of any plum_db cut-over.
%%
%% Each test opens two memory-topology replicas (distinct origins) using the
%% catalogue's OWN `fold_opts/1` output — so it exercises the real catalogue
%% wiring, not a hand-rolled copy — drives a WAMP-shaped operation, and asserts
%% the fold's defining property:
%%
%%   - `lww`  (realm / user / group / gateway / ticket / token / bridge):
%%            last-writer-wins, single value, and the clear→re-set reanimation
%%            that gives refresh-token "revoked → re-issued" for free (§3).
%%   - `mv`   (grants / sources): concurrent writes to the same cell survive as
%%            SIBLINGS — the silent-LWW-on-concurrent-grants fix that is the
%%            whole point (§0 / §3).
%%   - `aw`   (group membership, the §3 split table): a concurrent add survives
%%            a remove that did not observe it (add-wins observed-remove).
%%
%% The substrate already proves these CRDTs in isolation (`bondy_db_*_e2e_test`);
%% here the proof is that the CATALOGUE binds the correct CRDT to each fold class.

-module(bondy_namespace_catalog_folds_test).

-include_lib("eunit/include/eunit.hrl").

-define(CAT, bondy_namespace_catalog).
%% Membership marker values (the relation is the key; the value is a small
%% role / marker payload).
-define(M, <<"member">>).
-define(M2, <<"member-v2">>).

%% =============================================================================
%% Fixture
%% =============================================================================

folds_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"lww: concurrent writes converge to a single LWW winner",
                {timeout, 30, fun lww_concurrent_converges/0}},
            {"lww: a later write wins (op-apply read-modify-write)",
                fun lww_later_write_wins/0},
            {"lww: clear then re-set reanimates (token reissue)",
                fun lww_clear_then_reset_reanimates/0},
            {"mv: concurrent grants survive as siblings",
                {timeout, 30, fun mv_concurrent_grants_survive/0}},
            {"aw: disjoint member adds merge",
                {timeout, 30, fun aw_disjoint_adds_merge/0}},
            {"aw: concurrent add survives a non-observing remove",
                {timeout, 30, fun aw_add_survives_nonobserving_remove/0}}
        ]
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Take the schedulers out of the loop — the tests drive sync explicitly.
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

%% =============================================================================
%% lww — realm / user / group / gateway / ticket / token / bridge
%% =============================================================================

%% Two replicas write the same cell concurrently (distinct in-band HLCs). After
%% a bidirectional sync both converge to the higher-HLC value — a single bare
%% value, NOT a sibling list (the structural contrast with `mv`).
lww_concurrent_converges() ->
    {DbA, Ta} = open_replica(lww_conv_a, bondy_realm, lww),
    {DbB, Tb} = open_replica(lww_conv_b, bondy_realm, lww),
    try
        ok = bondy_db:apply(Ta, <<"r">>, <<"k">>, {set, 100, <<"va">>}),
        ok = bondy_db:apply(Tb, <<"r">>, <<"k">>, {set, 200, <<"vb">>}),
        ok = sync_both(Ta, Tb),
        %% Both replicas agree on the single LWW winner (highest HLC).
        ?assertEqual(
            {ok, {<<"vb">>, 200}}, bondy_db:read(Ta, <<"r">>, <<"k">>)
        ),
        ?assertEqual(
            {ok, {<<"vb">>, 200}}, bondy_db:read(Tb, <<"r">>, <<"k">>)
        ),
        ?assertEqual(root(Ta), root(Tb))
    after
        ok = bondy_db:close(DbA),
        ok = bondy_db:close(DbB)
    end.

%% A higher-HLC write applied after a lower one dominates; a stale (lower-HLC)
%% write is absorbed — a true read-modify-write op-apply, not a blind overwrite.
lww_later_write_wins() ->
    {Db, T} = open_replica(lww_later, security_users, lww),
    try
        ok = bondy_db:apply(T, <<"r">>, <<"u">>, {set, 1, <<"v1">>}),
        ?assertEqual({ok, {<<"v1">>, 1}}, bondy_db:read(T, <<"r">>, <<"u">>)),
        ok = bondy_db:apply(T, <<"r">>, <<"u">>, {set, 3, <<"v3">>}),
        ?assertEqual({ok, {<<"v3">>, 3}}, bondy_db:read(T, <<"r">>, <<"u">>)),
        %% Stale write is absorbed — the cell stays at v3.
        ok = bondy_db:apply(T, <<"r">>, <<"u">>, {set, 2, <<"stale">>}),
        ?assertEqual({ok, {<<"v3">>, 3}}, bondy_db:read(T, <<"r">>, <<"u">>))
    after
        ok = bondy_db:close(Db)
    end.

%% `clear` is non-terminal: a later `set` brings the cell back. This is the
%% refresh-token "revoked → re-issued" reanimation `lww_register` gives the
%% ticket / token tables for free (§3).
lww_clear_then_reset_reanimates() ->
    {Db, T} = open_replica(lww_reanimate, bondy_ticket, lww),
    try
        ok = bondy_db:apply(T, <<"r">>, <<"tok">>, {set, 1, <<"issued">>}),
        ?assertEqual(
            {ok, {<<"issued">>, 1}}, bondy_db:read(T, <<"r">>, <<"tok">>)
        ),
        %% Revoke — the cell reads as absent.
        ok = bondy_db:apply(T, <<"r">>, <<"tok">>, {clear, 2}),
        ?assertEqual({error, not_found}, bondy_db:read(T, <<"r">>, <<"tok">>)),
        %% Re-issue — a later set resurrects the cell.
        ok = bondy_db:apply(T, <<"r">>, <<"tok">>, {set, 3, <<"reissued">>}),
        ?assertEqual(
            {ok, {<<"reissued">>, 3}}, bondy_db:read(T, <<"r">>, <<"tok">>)
        )
    after
        ok = bondy_db:close(Db)
    end.

%% =============================================================================
%% mv — grants / sources
%% =============================================================================

%% Two replicas grant the same `(realm, principal, resource)` cell without
%% observing each other. After a bidirectional sync BOTH grants survive as
%% siblings (read returns a list) — so the auth layer sees the conflict instead
%% of silently accepting an LWW winner.
mv_concurrent_grants_survive() ->
    {DbA, Ta} = open_replica(mv_grant_a, security_user_grants, mv),
    {DbB, Tb} = open_replica(mv_grant_b, security_user_grants, mv),
    try
        ok = bondy_db:apply(
            Ta, <<"r">>, <<"alice/topic">>, {set, <<"perm_a">>}
        ),
        ok = bondy_db:apply(
            Tb, <<"r">>, <<"alice/topic">>, {set, <<"perm_b">>}
        ),
        ok = sync_both(Ta, Tb),
        ?assertEqual(
            {ok, [<<"perm_a">>, <<"perm_b">>], read_hlc},
            norm(bondy_db:read(Ta, <<"r">>, <<"alice/topic">>))
        ),
        ?assertEqual(
            {ok, [<<"perm_a">>, <<"perm_b">>], read_hlc},
            norm(bondy_db:read(Tb, <<"r">>, <<"alice/topic">>))
        ),
        ?assertEqual(root(Ta), root(Tb))
    after
        ok = bondy_db:close(DbA),
        ok = bondy_db:close(DbB)
    end.

%% =============================================================================
%% aw — group membership (the §3 split table)
%% =============================================================================

%% Two replicas add distinct members to the same group concurrently. After a
%% bidirectional sync both members are present on both replicas — membership is
%% a set-union, not an LWW replace of the whole member list.
aw_disjoint_adds_merge() ->
    {DbA, Ta} = open_replica(aw_merge_a, security_group_members, aw),
    {DbB, Tb} = open_replica(aw_merge_b, security_group_members, aw),
    try
        ok = bondy_db:apply(Ta, <<"r">>, <<"admins">>, {put, <<"alice">>, ?M}),
        ok = bondy_db:apply(Tb, <<"r">>, <<"admins">>, {put, <<"bob">>, ?M}),
        ok = sync_both(Ta, Tb),
        Expected = #{<<"alice">> => [?M], <<"bob">> => [?M]},
        ?assertEqual(
            {ok, Expected, read_hlc},
            norm(bondy_db:read(Ta, <<"r">>, <<"admins">>))
        ),
        ?assertEqual(
            {ok, Expected, read_hlc},
            norm(bondy_db:read(Tb, <<"r">>, <<"admins">>))
        ),
        ?assertEqual(root(Ta), root(Tb))
    after
        ok = bondy_db:close(DbA),
        ok = bondy_db:close(DbB)
    end.

%% The §3 motivation, end to end: replica B removes a member it has observed
%% while replica A concurrently re-adds that member (A never saw B's remove).
%% Add-wins — the member survives, carrying A's concurrent value.
aw_add_survives_nonobserving_remove() ->
    {DbA, Ta} = open_replica(aw_addwins_a, security_group_members, aw),
    {DbB, Tb} = open_replica(aw_addwins_b, security_group_members, aw),
    try
        %% A adds alice, then B observes it via a sync.
        ok = bondy_db:apply(Ta, <<"r">>, <<"admins">>, {put, <<"alice">>, ?M}),
        ok = sync_both(Ta, Tb),
        ?assertEqual(
            {ok, #{<<"alice">> => [?M]}, read_hlc},
            norm(bondy_db:read(Tb, <<"r">>, <<"admins">>))
        ),
        %% Concurrent: B removes the alice it observed; A re-adds alice with a
        %% NEW value, without observing B's remove.
        ok = bondy_db:apply(Tb, <<"r">>, <<"admins">>, {rmv, <<"alice">>}),
        ok = bondy_db:apply(Ta, <<"r">>, <<"admins">>, {put, <<"alice">>, ?M2}),
        ok = sync_both(Ta, Tb),
        %% Add-wins: A's concurrent (unobserved) add survives the remove.
        ?assertEqual(
            {ok, #{<<"alice">> => [?M2]}, read_hlc},
            norm(bondy_db:read(Ta, <<"r">>, <<"admins">>))
        ),
        ?assertEqual(
            {ok, #{<<"alice">> => [?M2]}, read_hlc},
            norm(bondy_db:read(Tb, <<"r">>, <<"admins">>))
        ),
        ?assertEqual(root(Ta), root(Tb))
    after
        ok = bondy_db:close(DbA),
        ok = bondy_db:close(DbB)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

%% Open a single-shard memory replica and a table wired through the catalogue's
%% own `fold_opts/1` for `Class` — so the test pins the catalogue's wiring.
open_replica(DbName, Entity, Class) ->
    Origin = bondy_oplog_origin:new(),
    {ok, Db} = bondy_db:open(DbName, #{
        topology => bondy_db_topology_memory,
        shard_count => 1,
        fold_module => lww_register,
        oplog_instance_opts => #{origin => Origin}
    }),
    {ok, T} = bondy_db:open_table(Db, Entity, ?CAT:fold_opts(Class)),
    {Db, T}.

instance_of(Table) ->
    #{0 := InstanceId} = maps:get(instance_ids, Table),
    InstanceId.

root(Table) ->
    bondy_oplog:root_hash(instance_of(Table)).

%% Exchange events both ways and force the per-cell replay barrier so the reads
%% below observe the merged events (production casts the replay async).
sync_both(Ta, Tb) ->
    Ia = instance_of(Ta),
    Ib = instance_of(Tb),
    {ok, _} = bondy_oplog:sync(Ia, Ib),
    {ok, _} = bondy_oplog:sync(Ib, Ia),
    ok = bondy_oplog:await_apply(Ia),
    ok = bondy_oplog:await_apply(Ib),
    ok = replay(Ia),
    ok = replay(Ib),
    ok.

replay(InstanceId) ->
    Pid = bondy_oplog_registry:applier_pid(InstanceId),
    bondy_oplog_applier:replay_cell_events_sync(Pid).

%% Collapse the timing-dependent read HLC for assertions.
norm({ok, {V, _Hlc}}) -> {ok, V, read_hlc};
norm(Other) -> Other.
