%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_aae_reactor_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

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
            bondy_aae_reactor:react_user(?USER_KEY, clear)
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

%% A remote user `set` (update / credential change) is a no-op here for now —
%% it must NOT close sessions (deferred; see the module docs).
remote_set_does_not_close_user_sessions_test() ->
    ok = meck:new(bondy_rbac_user, [passthrough]),
    ok = meck:expect(
        bondy_rbac_user, close_sessions, fun(_, _, _) -> ok end
    ),
    try
        ?assertEqual(
            ok, bondy_aae_reactor:react_user(?USER_KEY, {set, #{}})
        ),
        ?assertNot(
            meck:called(bondy_rbac_user, close_sessions, ['_', '_', '_'])
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
            bondy_aae_reactor:react_grant(?GRANT_KEY, {set, #{}})
        ),
        ?assertEqual(
            {invalidated, ?REALM},
            bondy_aae_reactor:react_grant(?GRANT_KEY, clear)
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
