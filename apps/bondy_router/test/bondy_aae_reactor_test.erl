%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_aae_reactor_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").
-include("bondy_db_tables.hrl").

-define(REALM, <<"com.example.reactor">>).
-define(USER, <<"alice">>).
%% G-1 realm-folded security_users cell key: <<Realm, 0, Username>>.
-define(USER_KEY, <<?REALM/binary, 0, ?USER/binary>>).
%% bondy_realm global-band cell key on the folding main topology: <<0, Uri>>.
-define(REALM_KEY, <<0, ?REALM/binary>>).
%% Realm-folded grant cell key: <<Realm, 0, EncGrantKey>>, where the composite
%% grant key (`bondy_rbac:encode_key/1`) carries its OWN 0x00 role/resource
%% separator — so this key has a SECOND NUL the realm unfold must not trip on.
-define(GRANT_KEY, <<?REALM/binary, 0, "g_admin", 0, "uri_resource">>).
%% Realm-folded membership cell: realm, NUL, then the band-tagged fact key
%% (its own NULs separate the band tag / user / group columns).
-define(MEMBER_KEY, <<?REALM/binary, 0, "f", 0, "alice", 0, "admins">>).

%% A remote user delete (a `clear` op) must close this node's sessions for that
%% user with reason ?BONDY_USER_DELETED.
remote_delete_closes_user_sessions_test() ->
    ok = meck:new(bondy_rbac_user, [passthrough]),
    ok = meck:expect(
        bondy_rbac_user,
        close_sessions,
        fun(R, U, Reason) -> {closed, R, U, Reason} end
    ),
    try
        ?assertEqual(
            {closed, ?REALM, ?USER, ?BONDY_USER_DELETED},
            bondy_aae_reactor:react_user(?USER_KEY, clear, undefined)
        ),
        ?assert(
            meck:called(
                bondy_rbac_user,
                close_sessions,
                [?REALM, ?USER, ?BONDY_USER_DELETED]
            )
        )
    after
        meck:unload(bondy_rbac_user)
    end.

%% A remote user `set` that does NOT change credential material (a create, or a
%% metadata-only edit) must NOT close sessions.
remote_set_does_not_close_user_sessions_test() ->
    ok = meck:new(bondy_rbac_user, [passthrough]),
    ok = meck:expect(
        bondy_rbac_user, close_sessions, fun(_, _, _) -> ok end
    ),
    try
        %% Create: no pre-merge value.
        ?assertEqual(
            ok, bondy_aae_reactor:react_user(?USER_KEY, {set, #{}}, undefined)
        ),
        %% Metadata-only edit: credentials unchanged.
        ?assertEqual(
            ok,
            bondy_aae_reactor:react_user(
                ?USER_KEY,
                {set, #{password => p1, meta => 2}},
                #{password => p1, meta => 1}
            )
        ),
        ?assertNot(
            meck:called(bondy_rbac_user, close_sessions, ['_', '_', '_'])
        )
    after
        meck:unload(bondy_rbac_user)
    end.

%% A remote user `set` whose password or authorized keys differ from the
%% pre-merge value closes this node's sessions with
%% ?BONDY_USER_CREDENTIALS_CHANGED (plum_db `on_merge` parity).
remote_credential_change_closes_user_sessions_test() ->
    ok = meck:new(bondy_rbac_user, [passthrough]),
    ok = meck:expect(
        bondy_rbac_user,
        close_sessions,
        fun(R, U, Reason) -> {closed, R, U, Reason} end
    ),
    try
        Expected = {closed, ?REALM, ?USER, ?BONDY_USER_CREDENTIALS_CHANGED},
        %% Password changed.
        ?assertEqual(
            Expected,
            bondy_aae_reactor:react_user(
                ?USER_KEY, {set, #{password => p2}}, #{password => p1}
            )
        ),
        %% Authorized keys changed (explicit HLC-carrying op form).
        ?assertEqual(
            Expected,
            bondy_aae_reactor:react_user(
                ?USER_KEY,
                {set, 123, #{authorized_keys => [k2]}},
                #{authorized_keys => [k1]}
            )
        )
    after
        meck:unload(bondy_rbac_user)
    end.

%% A remote realm delete (a `clear` op) must close this node's sessions for that
%% realm with reason ?WAMP_CLOSE_REALM.
remote_delete_closes_realm_sessions_test() ->
    ok = meck:new(bondy_realm, [passthrough]),
    ok = meck:expect(
        bondy_realm, close, fun(R, Reason) -> {closed, R, Reason} end
    ),
    try
        ?assertEqual(
            {closed, ?REALM, ?WAMP_CLOSE_REALM},
            bondy_aae_reactor:react_realm(?REALM_KEY, clear)
        ),
        ?assert(
            meck:called(bondy_realm, close, [?REALM, ?WAMP_CLOSE_REALM])
        )
    after
        meck:unload(bondy_realm)
    end.

%% A remote realm `set` (create / update) is a no-op here — it must NOT close
%% sessions.
remote_set_does_not_close_realm_sessions_test() ->
    ok = meck:new(bondy_realm, [passthrough]),
    ok = meck:expect(bondy_realm, close, fun(_, _) -> ok end),
    try
        ?assertEqual(
            ok, bondy_aae_reactor:react_realm(?REALM_KEY, {set, #{}})
        ),
        ?assertNot(meck:called(bondy_realm, close, ['_', '_']))
    after
        meck:unload(bondy_realm)
    end.

%% A remote grant change re-evaluates the realm's RBAC contexts in place (§9.5),
%% for BOTH a grant (`set`) and a revoke (`clear`) — it never tears the session
%% down (react_grant only invalidates; it does not call any close function).
remote_grant_invalidates_realm_rbac_test() ->
    ok = meck:new(bondy_session_manager, [passthrough]),
    ok = meck:expect(
        bondy_session_manager,
        invalidate_rbac_all,
        fun(R) -> {invalidated, R} end
    ),
    try
        ?assertEqual(
            {invalidated, ?REALM},
            bondy_aae_reactor:react_grant(
                "security_user_grants", ?GRANT_KEY, {set, #{}}, undefined
            )
        ),
        ?assertEqual(
            {invalidated, ?REALM},
            bondy_aae_reactor:react_grant(
                "security_user_grants", ?GRANT_KEY, clear, #{}
            )
        ),
        ?assertEqual(
            2,
            meck:num_calls(
                bondy_session_manager, invalidate_rbac_all, [?REALM]
            )
        )
    after
        meck:unload(bondy_session_manager)
    end.

%% The lww conflict alarm: a remote `set` that replaced a DIFFERENT existing
%% value emits [bondy, aae, merge_conflict]; a create (Old = undefined), an
%% identical rewrite, and a `clear` stay silent. Asserted via a telemetry
%% handler on both the grant and the source reactions.
merge_conflict_alarm_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = {?MODULE, ?FUNCTION_NAME},
    ok = telemetry:attach(
        HandlerId,
        [bondy, aae, merge_conflict],
        fun(_Event, Meas, Meta, _Cfg) -> Self ! {alarm, Meas, Meta} end,
        undefined
    ),
    ok = meck:new(bondy_session_manager, [passthrough]),
    ok = meck:expect(
        bondy_session_manager, invalidate_rbac_all, fun(_) -> ok end
    ),
    try
        %% Grant: replaced a differing value → alarm.
        ok = bondy_aae_reactor:react_grant(
            "security_user_grants", ?GRANT_KEY, {set, v2}, v1
        ),
        Meta1 =
            receive
                {alarm, #{count := 1}, M1} -> M1
            after 1000 -> error(no_alarm)
            end,
        ?assertEqual("security_user_grants", maps:get(table, Meta1)),
        ?assertEqual(?REALM, maps:get(realm_uri, Meta1)),

        %% Source: alarm-only reaction, same rule.
        ok = bondy_aae_reactor:react_source(
            "security_sources", ?GRANT_KEY, {set, v2}, v1
        ),
        receive
            {alarm, _, _} -> ok
        after 1000 -> error(no_source_alarm)
        end,

        %% Silent cases: create, identical rewrite, clear (revoke).
        ok = bondy_aae_reactor:react_grant(
            "security_user_grants", ?GRANT_KEY, {set, v2}, undefined
        ),
        ok = bondy_aae_reactor:react_grant(
            "security_user_grants", ?GRANT_KEY, {set, v2}, v2
        ),
        ok = bondy_aae_reactor:react_source(
            "security_sources", ?GRANT_KEY, clear, v1
        ),
        receive
            {alarm, _, _} = Unexpected -> error({unexpected_alarm, Unexpected})
        after 200 -> ok
        end
    after
        meck:unload(bondy_session_manager),
        telemetry:detach(HandlerId)
    end.

%% A remote membership change (security_group_members) invalidates this node's
%% RBAC contexts for the realm, in place — for BOTH an `enable` (add) and a
%% `disable` (remove). Like grants, it never tears the session down.
remote_member_invalidates_realm_rbac_test() ->
    ok = meck:new(bondy_session_manager, [passthrough]),
    ok = meck:expect(
        bondy_session_manager,
        invalidate_rbac_all,
        fun(R) -> {invalidated, R} end
    ),
    try
        ?assertEqual(
            {invalidated, ?REALM},
            bondy_aae_reactor:react_member(?MEMBER_KEY, enable)
        ),
        ?assertEqual(
            {invalidated, ?REALM},
            bondy_aae_reactor:react_member(?MEMBER_KEY, disable)
        ),
        ?assertEqual(
            2,
            meck:num_calls(
                bondy_session_manager, invalidate_rbac_all, [?REALM]
            )
        )
    after
        meck:unload(bondy_session_manager)
    end.

%% The realm-folded security_users cell key splits back into {RealmUri, Username}.
unfold_user_key_test() ->
    ?assertEqual(
        {?REALM, ?USER}, bondy_aae_reactor:unfold_user_key(?USER_KEY)
    ).

%% The global-band bondy_realm cell key splits back into the realm URI.
unfold_realm_key_test() ->
    ?assertEqual(?REALM, bondy_aae_reactor:unfold_realm_key(?REALM_KEY)).

%% The realm-folded grant cell key splits back to the realm URI at the FIRST
%% separator, even though the trailing composite grant key has its own NUL.
unfold_grant_key_test() ->
    ?assertEqual(?REALM, bondy_aae_reactor:unfold_grant_key(?GRANT_KEY)).

%% The realm-folded membership cell key splits back to the realm URI at the
%% FIRST separator, even though the trailing band-tagged fact key has its own
%% NULs.
unfold_member_key_test() ->
    ?assertEqual(?REALM, bondy_aae_reactor:unfold_member_key(?MEMBER_KEY)).

%% =============================================================================
%% REGISTRY PRESENCE REACTIONS (§9.6)
%% =============================================================================

%% `react_rib/3` is now a thin dispatcher: resolve `Type` from `Table` and
%% delegate everything else — reading the cell's current converged value,
%% self-vs-peer routing, and stub-store maintenance — to
%% `bondy_registry_rib:on_remote_merge/2` (covered by
%% `bondy_registry_rib_test.erl` and `bondy_aae_cluster_SUITE.erl`'s RIB
%% cases). `Op` is irrelevant here — the per-field CRDT write path has no
%% single op that represents "the current summary" the way the pre-migration
%% whole-blob `lww_register` cell's `{set, V}` did, so `on_remote_merge/2`
%% re-reads the cell instead — this test pins only the table→Type dispatch.
react_rib_dispatches_by_table_test() ->
    ok = meck:new(bondy_registry_rib, [passthrough]),
    ok = meck:expect(bondy_registry_rib, on_remote_merge, fun(_, _) -> ok end),
    try
        Key = <<"some-key">>,
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_REGISTRATION_RIB_TAB, Key, {set, #{}}
        ),
        ?assert(
            meck:called(
                bondy_registry_rib, on_remote_merge, [registration, Key]
            )
        ),
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_SUBSCRIPTION_RIB_TAB, Key, clear
        ),
        ?assert(
            meck:called(
                bondy_registry_rib, on_remote_merge, [subscription, Key]
            )
        )
    after
        meck:unload(bondy_registry_rib)
    end.

%% =============================================================================
%% POOL ROUTING (bondy_aae_reactor_worker + gproc_pool)
%% =============================================================================

%% The reactor hashes each merge event by cell Key to a worker in the
%% ?AAE_REACTOR_POOL: same key -> same worker (a cell's set/clear stay ordered),
%% the worker dispatches by the sub's kind to the reaction, and a malformed event
%% is swallowed (best-effort AP) rather than taking the worker down.
pool_test_() ->
    {setup, fun setup_pool/0, fun cleanup_pool/1, fun(Workers) ->
        [
            same_key_same_worker(Workers),
            worker_dispatches_by_kind(Workers),
            worker_survives_bad_event(Workers)
        ]
    end}.

setup_pool() ->
    {ok, _} = application:ensure_all_started(gproc),
    N = 4,
    _ =
        try
            gproc_pool:new(?AAE_REACTOR_POOL, hash, [{size, N}])
        catch
            _:_ -> ok
        end,
    [
        begin
            _ =
                try
                    gproc_pool:add_worker(
                        ?AAE_REACTOR_POOL, {bondy_aae_reactor_worker, I}, I
                    )
                catch
                    _:_ -> ok
                end,
            {ok, Pid} = bondy_aae_reactor_worker:start_link(I),
            true = unlink(Pid),
            Pid
        end
     || I <- lists:seq(1, N)
    ].

cleanup_pool(Workers) ->
    _ = [
        try
            gen_server:stop(P)
        catch
            _:_ -> ok
        end
     || P <- Workers
    ],
    _ =
        try
            gproc_pool:force_delete(?AAE_REACTOR_POOL)
        catch
            _:_ -> ok
        end,
    ok.

%% Same cell key always hashes to the same worker (ordering); a pid is returned
%% (pool wiring).
same_key_same_worker(_) ->
    fun() ->
        K = <<"com.example.ordered.proc">>,
        W1 = gproc_pool:pick_worker(?AAE_REACTOR_POOL, K),
        W2 = gproc_pool:pick_worker(?AAE_REACTOR_POOL, K),
        ?assert(is_pid(W1)),
        ?assertEqual(W1, W2)
    end.

%% A cast routed to a worker dispatches by the sub's kind: a user `clear` closes
%% this node's sessions for that user.
worker_dispatches_by_kind(_) ->
    fun() ->
        ok = meck:new(bondy_rbac_user, [passthrough]),
        ok = meck:expect(
            bondy_rbac_user, close_sessions, fun(_, _, _) -> ok end
        ),
        try
            Sub = bondy_aae_reactor:make_sub(
                user, "security_users", ?BONDY_DB_USER_TAB
            ),
            Worker = gproc_pool:pick_worker(?AAE_REACTOR_POOL, ?USER_KEY),
            gen_server:cast(Worker, {react, Sub, ?USER_KEY, clear, undefined}),
            %% A sync call is served after the preceding cast, so once it
            %% returns the reaction has run.
            _ = gen_server:call(Worker, flush),
            ?assert(
                meck:called(
                    bondy_rbac_user,
                    close_sessions,
                    [?REALM, ?USER, ?BONDY_USER_DELETED]
                )
            )
        after
            meck:unload(bondy_rbac_user)
        end
    end.

%% A malformed reaction payload is logged and swallowed — the worker stays alive
%% and responsive so its queued backlog is not lost.
worker_survives_bad_event(_) ->
    fun() ->
        Worker = gproc_pool:pick_worker(?AAE_REACTOR_POOL, <<"whatever">>),
        gen_server:cast(Worker, {react, not_a_sub, <<"k">>, clear, undefined}),
        ?assertEqual(
            {error, {unsupported_call, flush}},
            gen_server:call(Worker, flush)
        ),
        ?assert(is_process_alive(Worker))
    end.

%% A remote group-record change invalidates this node's cached RBAC contexts
%% for the realm. The group's `groups` property is the role-inheritance edge and
%% a cached context bakes in the grants it resolves to, so a peer's change to it
%% must re-evaluate live sessions exactly as a membership change does.
remote_group_invalidates_realm_rbac_test() ->
    GroupKey = <<?REALM/binary, 0, "admins">>,
    ok = meck:new(bondy_session_manager, [passthrough]),
    ok = meck:expect(
        bondy_session_manager,
        invalidate_rbac_all,
        fun(R) -> {invalidated, R} end
    ),
    try
        %% Any op: a parent list is changed by a `set`, and a `clear` arriving
        %% from a peer's group delete is equally a permission change here.
        ?assertEqual(
            {invalidated, ?REALM},
            bondy_aae_reactor:react_group(GroupKey, {set, #{}})
        ),
        ?assertEqual(
            {invalidated, ?REALM},
            bondy_aae_reactor:react_group(GroupKey, clear)
        ),

        %% And it is reachable through the dispatcher, not just directly — a
        %% reaction the `reacted_tables/0` set never routes to is dead code.
        Sub = bondy_aae_reactor:make_sub(
            group, "security_groups", ?BONDY_DB_GROUP_TAB
        ),
        ?assertEqual(
            {invalidated, ?REALM},
            bondy_aae_reactor:apply_reaction(
                Sub, GroupKey, {set, #{}}, undefined
            )
        ),
        ?assertEqual(
            3,
            meck:num_calls(
                bondy_session_manager, invalidate_rbac_all, [?REALM]
            )
        )
    after
        meck:unload(bondy_session_manager)
    end.

%% Every reaction above is only ever reached if BOTH ends are wired: the reactor
%% must route the table, and the catalogue entry must publish its merges. Either
%% half missing leaves a reaction that is dead code and still passes its own
%% test — which is exactly how the inheritance edge went uninvalidated, the
%% reactor having no `security_groups` subscription to route to.
%%
%% This is the reaction→flag direction. The flag→consumer direction is
%% `bondy_rbac_SUITE:every_publishing_table_has_a_live_subscriber/1`, which
%% needs a running dispatcher and covers consumers other than this reactor.
reacted_tables_publish_their_merges_test() ->
    Reacted = bondy_aae_reactor:reacted_table_names(),
    ?assertNotEqual([], Reacted),

    Publishing = [
        Name
     || #{name := Name} = Spec <- bondy_namespace_catalog:tables(),
        maps:get(publish, Spec, false)
    ],
    ?assertEqual(
        [],
        Reacted -- Publishing,
        "the reactor routes a table whose merges are never published"
    ),
    %% The table this went wrong on, named so the case cannot be weakened into
    %% vacuity by an empty `reacted_table_names/0`.
    ?assert(lists:member(?BONDY_DB_GROUP_TAB, Reacted)).
