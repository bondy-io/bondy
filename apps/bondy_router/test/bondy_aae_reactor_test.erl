%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_aae_reactor_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").
-include("bondy_db_tables.hrl").

-define(REALM, <<"com.example.reactor">>).
-define(USER, <<"alice">>).
%% G-1 realm-folded security_users cell key: <<Realm, 0, Username>>.
-define(USER_KEY, <<?REALM/binary, 0, ?USER/binary>>).
%% bondy_realm global-band cell key on the folding core topology: <<0, Uri>>.
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

-define(REG_NS, '$registry_ns').
-define(REG_KEY, <<"entry-id-key">>).

%% A remote registry `set` whose owner node is connected adds the entry to this
%% node's routing trie (`add_indices`) and is remembered for a later `clear`.
remote_set_owner_up_adds_to_trie_test() ->
    Entry = fake_entry,
    with_registry_mecks(
        _OwnerUp = true,
        fun(Tab) ->
            ok = bondy_aae_reactor:react_registry(
                Tab, ?REG_NS, ?REG_KEY, {set, #{entry => Entry}}
            ),
            ?assert(
                meck:called(bondy_registry_partition, add_indices, ['_', Entry])
            ),
            ?assertNot(
                meck:called(bondy_registry_partition, index_remote, ['_', '_'])
            ),
            ?assertEqual(
                [{{?REG_NS, ?REG_KEY}, Entry}],
                ets:lookup(Tab, {?REG_NS, ?REG_KEY})
            )
        end
    ).

%% A remote registry `set` whose owner node is down records the entry masked
%% (`index_remote` only) — not selectable for routing — for a late joiner (§9.6).
remote_set_owner_down_masks_test() ->
    Entry = fake_entry,
    with_registry_mecks(
        _OwnerUp = false,
        fun(Tab) ->
            ok = bondy_aae_reactor:react_registry(
                Tab, ?REG_NS, ?REG_KEY, {set, #{entry => Entry}}
            ),
            ?assert(
                meck:called(
                    bondy_registry_partition, index_remote, ['_', Entry]
                )
            ),
            ?assertNot(
                meck:called(bondy_registry_partition, add_indices, ['_', '_'])
            )
        end
    ).

%% A remote registry `clear` resolves the cleared entry from the reactor's
%% tombstone table and removes its indices (`remove_indices`), draining the entry.
remote_clear_removes_indices_test() ->
    Entry = fake_entry,
    with_registry_mecks(
        _OwnerUp = true,
        fun(Tab) ->
            true = ets:insert(Tab, {{?REG_NS, ?REG_KEY}, Entry}),
            ok = bondy_aae_reactor:react_registry(
                Tab, ?REG_NS, ?REG_KEY, clear
            ),
            ?assert(
                meck:called(
                    bondy_registry_partition, remove_indices, ['_', Entry]
                )
            ),
            ?assertEqual([], ets:lookup(Tab, {?REG_NS, ?REG_KEY}))
        end
    ).

%% A `clear` for an entry this node never saw the `set` for is a no-op (nothing in
%% the trie to drop).
remote_clear_unknown_is_noop_test() ->
    with_registry_mecks(
        _OwnerUp = true,
        fun(Tab) ->
            ok = bondy_aae_reactor:react_registry(
                Tab, ?REG_NS, ?REG_KEY, clear
            ),
            ?assertNot(
                meck:called(
                    bondy_registry_partition, remove_indices, ['_', '_']
                )
            )
        end
    ).

%% `owner_up/1` is true for a self-owned entry and for a connected peer, false for
%% a disconnected peer.
owner_up_reflects_partisan_view_test() ->
    ok = meck:new(partisan, [passthrough]),
    ok = meck:new(bondy_registry_entry, [passthrough]),
    try
        ok = meck:expect(partisan, node, fun() -> 'me@host' end),
        ok = meck:expect(partisan, is_connected, fun
            ('up@host') -> true;
            (_) -> false
        end),

        ok = meck:expect(bondy_registry_entry, node, fun
            (self_e) -> 'me@host';
            (up_e) -> 'up@host';
            (down_e) -> 'down@host'
        end),

        ?assert(bondy_aae_reactor:owner_up(self_e)),
        ?assert(bondy_aae_reactor:owner_up(up_e)),
        ?assertNot(bondy_aae_reactor:owner_up(down_e))
    after
        meck:unload(bondy_registry_entry),
        meck:unload(partisan)
    end.

%% A peer's RIB summary cell merge maintains the stub store: both set forms
%% upsert, both clear forms drop, self-origin cells and garbage ops/keys are
%% ignored — the reaction is total.
react_rib_stub_lifecycle_test() ->
    %% Another test (or an app boot sharing this BEAM) may have created the
    %% named stub table already; reuse it — this test's realm is unique.
    _ =
        case ets:whereis(bondy_registry_rib_stubs) of
            undefined ->
                ets:new(
                    bondy_registry_rib_stubs,
                    [ordered_set, named_table, public, {keypos, 1}]
                );
            Ref ->
                Ref
        end,
    ok = meck:new(bondy_config, [passthrough]),
    ok = meck:expect(bondy_config, nodestring, fun() -> <<"me@host">> end),
    try
        Proc = <<"com.example.rib_proc">>,
        Peer = <<"peer@host">>,
        Key = term_to_binary({?REALM, ?EXACT_MATCH, Proc, Peer}),
        S1 = #{
            invoke => ?INVOKE_ROUND_ROBIN,
            count => 1,
            earliest => 1,
            latest => 1
        },

        %% Short-form set (the wire shape) upserts the stub.
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_REGISTRATION_RIB_TAB, Key, {set, S1}
        ),
        ?assertEqual(
            [{Peer, S1}],
            bondy_registry_rib:stub_nodes(
                registration, ?REALM, ?EXACT_MATCH, Proc
            )
        ),

        %% Long-form set replaces it.
        S2 = S1#{count := 2},
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_REGISTRATION_RIB_TAB, Key, {set, 123, S2}
        ),
        ?assertEqual(
            [{Peer, S2}],
            bondy_registry_rib:stub_nodes(
                registration, ?REALM, ?EXACT_MATCH, Proc
            )
        ),

        %% The subscription table routes to the subscription view.
        SubKey = term_to_binary({?REALM, ?EXACT_MATCH, Proc, Peer}),
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_SUBSCRIPTION_RIB_TAB, SubKey, {set, #{count => 1}}
        ),
        ?assertEqual(
            [{Peer, #{count => 1}}],
            bondy_registry_rib:stub_nodes(
                subscription, ?REALM, ?EXACT_MATCH, Proc
            )
        ),

        %% A cell naming this node is never stubbed.
        SelfKey = term_to_binary(
            {?REALM, ?EXACT_MATCH, <<"com.example.self">>, <<"me@host">>}
        ),
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_REGISTRATION_RIB_TAB, SelfKey, {set, S1}
        ),
        ?assertEqual(
            [],
            bondy_registry_rib:stub_nodes(
                registration, ?REALM, ?EXACT_MATCH, <<"com.example.self">>
            )
        ),

        %% The realm-folded wire form <<Realm, 0, RawKey>> — what a merge
        %% event actually delivers — decodes identically.
        FoldedProc = <<"com.example.rib_folded">>,
        Folded = <<
            ?REALM/binary,
            0,
            (term_to_binary({?REALM, ?EXACT_MATCH, FoldedProc, Peer}))/binary
        >>,
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_REGISTRATION_RIB_TAB, Folded, {set, S1}
        ),
        ?assertEqual(
            [{Peer, S1}],
            bondy_registry_rib:stub_nodes(
                registration, ?REALM, ?EXACT_MATCH, FoldedProc
            )
        ),
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_REGISTRATION_RIB_TAB, Folded, clear
        ),
        ?assertEqual(
            [],
            bondy_registry_rib:stub_nodes(
                registration, ?REALM, ?EXACT_MATCH, FoldedProc
            )
        ),

        %% Garbage op / key: ignored, no crash.
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_REGISTRATION_RIB_TAB, Key, {bogus, op}
        ),
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_REGISTRATION_RIB_TAB, <<"not a term">>, {set, S1}
        ),

        %% Both clear forms drop the stub.
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_REGISTRATION_RIB_TAB, Key, {clear, 123}
        ),
        ?assertEqual(
            [],
            bondy_registry_rib:stub_nodes(
                registration, ?REALM, ?EXACT_MATCH, Proc
            )
        ),
        ok = bondy_aae_reactor:react_rib(
            ?BONDY_DB_SUBSCRIPTION_RIB_TAB, SubKey, clear
        ),
        ?assertEqual(
            [],
            bondy_registry_rib:stub_nodes(
                subscription, ?REALM, ?EXACT_MATCH, Proc
            )
        )
    after
        meck:unload(bondy_config)
    end.

%% @private
%% Drives `react_registry/4` with the partition / entry / partisan calls mecked,
%% an `OwnerUp` membership verdict, and a fresh tombstone table.
with_registry_mecks(OwnerUp, Fun) ->
    Tab = ets:new(reg_entries, [set, {keypos, 1}]),
    ok = meck:new(partisan, [passthrough]),
    ok = meck:new(bondy_registry, [passthrough]),
    ok = meck:new(bondy_registry_partition, [passthrough]),
    ok = meck:new(bondy_registry_entry, [passthrough]),
    try
        ok = meck:expect(partisan, node, fun() -> 'me@host' end),
        ok = meck:expect(partisan, is_connected, fun(_) -> OwnerUp end),
        ok = meck:expect(bondy_registry_entry, node, fun(_) -> 'peer@host' end),
        ok = meck:expect(
            bondy_registry_entry, realm_uri, fun(_) -> ?REALM end
        ),
        ok = meck:expect(bondy_registry, pick_partition, fun(_) -> self() end),
        ok = meck:expect(
            bondy_registry_partition, add_indices, fun(_, _) -> ok end
        ),
        ok = meck:expect(
            bondy_registry_partition, index_remote, fun(_, _) -> ok end
        ),
        ok = meck:expect(
            bondy_registry_partition, remove_indices, fun(_, _) -> ok end
        ),
        Fun(Tab)
    after
        meck:unload(bondy_registry_entry),
        meck:unload(bondy_registry_partition),
        meck:unload(bondy_registry),
        meck:unload(partisan),
        ets:delete(Tab)
    end.
