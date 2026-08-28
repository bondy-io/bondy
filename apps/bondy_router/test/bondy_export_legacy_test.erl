%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_export_legacy_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_db_tables.hrl").

-define(REALM, <<"com.magenta.public">>).

%% =============================================================================
%% resolve_object/1 — dvvset resolution + the {Value, Timestamp} unwrap
%% =============================================================================

%% A single live value unwraps to its payload (the modification timestamp the
%% former bondy_backup wrapped it in is discarded).
resolve_live_test() ->
    Obj = obj([{dot(1), 2, [{the_value, {1700, 0, 0}}]}]),
    ?assertEqual({ok, the_value}, bondy_export:resolve_object(Obj)).

%% An all-tombstone object resolves to `deleted` (skipped on import).
resolve_tombstone_test() ->
    Obj = obj([{dot(1), 2, [{'$deleted', {1700, 0, 0}}]}]),
    ?assertEqual(deleted, bondy_export:resolve_object(Obj)).

%% Concurrent siblings resolve last-writer-wins by the wrapped timestamp.
resolve_siblings_lww_test() ->
    Obj = obj([
        {dot(1), 1, [{old, {1000, 0, 0}}]},
        {dot(2), 1, [{new, {2000, 0, 0}}]}
    ]),
    ?assertEqual({ok, new}, bondy_export:resolve_object(Obj)).

%% A tombstone sibling alongside a live one yields the live value.
resolve_mixed_test() ->
    Obj = obj([
        {dot(1), 1, [{'$deleted', {3000, 0, 0}}]},
        {dot(2), 1, [{kept, {2000, 0, 0}}]}
    ]),
    ?assertEqual({ok, kept}, bondy_export:resolve_object(Obj)).

%% =============================================================================
%% legacy_translate/4 — the per-domain reshape
%% =============================================================================

%% A `security_users` cell is banded by the realm and keyed by the cell's own
%% key, and its value is passed through untouched: a user record and an alias
%% pointer share this domain, and `bondy_rbac_user:import_legacy/3` is what
%% tells them apart. Deciding here as well would split that knowledge in two.
translate_user_test() ->
    PList = [
        {<<"groups">>, []},
        {<<"meta">>, #{}},
        {<<"password">>, [{auth_name, pbkdf2}]}
    ],
    ?assertEqual(
        {entry, ?BONDY_DB_USER_TAB, ?REALM, <<"admin">>, PList},
        bondy_export:legacy_translate(
            security_users, ?REALM, <<"admin">>, PList
        )
    ).

%% An alias-pointer cell keeps its own key, and is not mistaken for the user it
%% names — the target's record is the one thing an alias must never overwrite.
translate_user_alias_test() ->
    Entry = #{type => alias, username => <<"admin">>},
    ?assertEqual(
        {entry, ?BONDY_DB_USER_TAB, ?REALM, <<"root">>, Entry},
        bondy_export:legacy_translate(
            security_users, ?REALM, <<"root">>, Entry
        )
    ).

%% A group value is upgraded via from_term, banded + keyed by realm / name.
translate_group_test() ->
    Group = #{
        type => group,
        version => <<"1.1">>,
        name => <<"resource_owners">>,
        groups => [],
        meta => #{}
    },
    {entry, Table, Band, Key, Value} =
        bondy_export:legacy_translate(
            security_groups, ?REALM, <<"resource_owners">>, Group
        ),
    ?assertEqual(?BONDY_DB_GROUP_TAB, Table),
    ?assertEqual(?REALM, Band),
    ?assertEqual(<<"resource_owners">>, Key),
    ?assertEqual(Group, Value).

%% A group grant re-keys through the live encode_key and reshapes the bare
%% permission list into the `#{resource, permissions}` cell value.
translate_group_grant_test() ->
    LKey = {<<"resource_owners">>, {<<>>, <<"prefix">>}},
    Perms = [<<"wamp.call">>, <<"wamp.publish">>],
    {entry, Table, Band, Key, Value} =
        bondy_export:legacy_translate(
            security_group_grants, ?REALM, LKey, Perms
        ),
    ?assertEqual(?BONDY_DB_GROUP_GRANT_TAB, Table),
    ?assertEqual(?REALM, Band),
    ?assertEqual(bondy_rbac:encode_key(LKey), Key),
    ?assertEqual(
        #{resource => {<<>>, <<"prefix">>}, permissions => Perms}, Value
    ).

%% A user grant takes the same shape, on the user-grant table.
translate_user_grant_test() ->
    LKey = {<<"alice">>, any},
    Perms = [<<"wamp.call">>],
    {entry, Table, _Band, Key, Value} =
        bondy_export:legacy_translate(
            security_user_grants, ?REALM, LKey, Perms
        ),
    ?assertEqual(?BONDY_DB_USER_GRANT_TAB, Table),
    ?assertEqual(bondy_rbac:encode_key(LKey), Key),
    ?assertEqual(#{resource => any, permissions => Perms}, Value).

%% A source re-keys via encode_key (mask + method come from the value) and folds
%% the username (the legacy key's leading element) back into the value.
translate_source_test() ->
    LKey = {anonymous, {{0, 0, 0, 0}, 0}, <<"anonymous">>},
    Source = #{
        type => source,
        version => <<"1.1">>,
        authmethod => <<"anonymous">>,
        cidr => {{0, 0, 0, 0}, 0},
        meta => #{}
    },
    {entry, Table, Band, Key, Value} =
        bondy_export:legacy_translate(security_sources, ?REALM, LKey, Source),
    ?assertEqual(?BONDY_DB_SOURCE_TAB, Table),
    ?assertEqual(?REALM, Band),
    ?assertEqual(
        bondy_rbac_source:encode_key(
            {anonymous, {{0, 0, 0, 0}, 0}, <<"anonymous">>}
        ),
        Key
    ),
    ?assertEqual(Source#{username => anonymous}, Value).

%% An OAuth refresh-token record is parsed into a token spec: realm + client from
%% the sub-prefix, authid = casefolded username, device from the meta.
translate_oauth_token_test() ->
    Sub = <<"com.magenta.public,strixios">>,
    RefreshToken = <<"3ROuiqVl92G4KEjpt9UwaHwac1iLnQle8a8Uxwrv">>,
    Meta = #{<<"client_device_id">> => <<"DEV-1">>},
    Rec =
        {bondy_oauth2_token, <<"strixios">>, <<"Mares+TestQA@strix.com.ar">>,
            [<<"account_admin">>], Meta, 2592000, 1780410535, true},
    {oauth_token, AuthRealm, AuthId, IssuedAt, ExpiresIn, Spec} =
        bondy_export:legacy_translate(
            oauth2_refresh_tokens, Sub, RefreshToken, Rec
        ),
    ?assertEqual(<<"com.magenta.public">>, AuthRealm),
    ?assertEqual(<<"mares+testqa@strix.com.ar">>, AuthId),
    ?assertEqual(1780410535, IssuedAt),
    ?assertEqual(2592000, ExpiresIn),
    ?assertEqual(<<"com.magenta.public">>, maps:get(authrealm, Spec)),
    ?assertEqual(RefreshToken, maps:get(refresh_token, Spec)),
    ?assertEqual(<<"strixios">>, maps:get(client_id, Spec)),
    ?assertEqual(<<"DEV-1">>, maps:get(device_id, Spec)),
    ?assertEqual([<<"account_admin">>], maps:get(groups, Spec)).

%% A token record of an unexpected shape is skipped, not mis-applied.
translate_oauth_token_unparsable_test() ->
    ?assertEqual(
        {skip, oauth_token_unparsable},
        bondy_export:legacy_translate(
            oauth2_refresh_tokens, <<"r,iss">>, <<"tok">>, {bondy_oauth2_token}
        )
    ).

%% An API gateway spec is stored under the global band, keyed by the spec id.
translate_api_gateway_test() ->
    Spec = #{<<"id">> => <<"com.magenta.public">>, <<"host">> => <<"_">>},
    ?assertEqual(
        {entry, api_gateway, <<>>, <<"com.magenta.public">>, Spec},
        bondy_export:legacy_translate(
            api_gateway, api_specs, <<"com.magenta.public">>, Spec
        )
    ).

%% =============================================================================
%% legacy_translate/4 — the intentionally-skipped domains
%% =============================================================================

translate_skips_test_() ->
    [
        ?_assertEqual(
            {skip, realm_recreate_from_config},
            bondy_export:legacy_translate(bondy_realm, ?REALM, ?REALM, {realm})
        ),
        ?_assertEqual(
            {skip, realm_recreate_from_config},
            bondy_export:legacy_translate(security, realms, ?REALM, {realm})
        ),
        ?_assertEqual(
            {skip, security_status_dead},
            bondy_export:legacy_translate(
                security_status, ?REALM, enabled, true
            )
        ),
        %% A pre-v1.1 source (2-tuple key, non-map value) gets a precise skip.
        ?_assertEqual(
            {skip, legacy_source_format},
            bondy_export:legacy_translate(
                security_sources,
                ?REALM,
                {all, {{0, 0, 0, 0}, 0}},
                {password, []}
            )
        ),
        %% An unknown prefix is skipped (never mis-written).
        ?_assertEqual(
            {skip, {unsupported_prefix, something_else}},
            bondy_export:legacy_translate(something_else, foo, bar, baz)
        )
    ].

%% =============================================================================
%% decode_key/1 — own-persisted key bytes decode plain (C-2 own-bytes rule)
%% =============================================================================

%% The grant key's resource suffix is this node's own persisted bytes
%% (`bondy_rbac:encode_key/1` writes it via `bondy_db:apply`), so its decode
%% must intern the bytes' own atoms rather than refuse them (rationale:
%% `bondy_oplog_cell_kernel:decode_value_bytes/2`). The atom below exists
%% only as bytes (SMALL_ATOM_UTF8_EXT) until the decode interns it.
grant_key_own_bytes_decode_interns_own_atom_test() ->
    Name = <<"bondy_c2_grant_atom_qz3">>,
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
    ResBin = <<131, 119, (byte_size(Name)):8, Name/binary>>,
    Key = <<
        (bondy_oplog_index_key:encode_col(<<"r">>))/binary, 0, ResBin/binary
    >>,
    ?assertMatch({<<"r">>, A} when is_atom(A), bondy_rbac:decode_key(Key)),
    {_, Atom} = bondy_rbac:decode_key(Key),
    ?assertEqual(Name, atom_to_binary(Atom, utf8)).

%% Same contract for the source key's `{AMask, Authmethod}` suffix
%% (`bondy_rbac_source:encode_key/1` is the writer).
source_key_own_bytes_decode_interns_own_atom_test() ->
    Name = <<"bondy_c2_source_atom_qz2">>,
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
    Suffix = <<
        131,
        104,
        2,
        119,
        (byte_size(Name)):8,
        Name/binary,
        109,
        1:32/big-unsigned,
        "x"
    >>,
    Key = <<
        (bondy_oplog_index_key:encode_col(<<"u">>))/binary, 0, Suffix/binary
    >>,
    ?assertMatch(
        {<<"u">>, A, <<"x">>} when is_atom(A),
        bondy_rbac_source:decode_key(Key)
    ),
    {_, Atom, _} = bondy_rbac_source:decode_key(Key),
    ?assertEqual(Name, atom_to_binary(Atom, utf8)).

%% =============================================================================
%% Helpers
%% =============================================================================

obj(Entries) ->
    {object, {Entries, []}}.

dot(N) ->
    {1, list_to_atom("node" ++ integer_to_list(N))}.
