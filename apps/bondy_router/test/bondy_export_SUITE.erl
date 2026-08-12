%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_export_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_db_tables.hrl").
-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.export_test">>).

-define(TOKEN_REALM, <<"com.example.export_token">>).
-define(TOKEN_USER, <<"tokuser">>).

all() ->
    [
        export_import_roundtrip,
        membership_export_roundtrip,
        legacy_user_membership_roundtrip,
        legacy_user_alias_roundtrip,
        legacy_poison_record_is_skipped,
        legacy_token_refresh_roundtrip
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    %% A real realm so per-realm table enumeration includes it. Durable main
    %% DB ⇒ may survive a prior run.
    _ =
        case bondy_realm:exists(?REALM) of
            true -> ok;
            false -> bondy_realm:create(?REALM)
        end,
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

%% Round-trips a per-realm entry (security_users under the test realm's URI
%% band) and a global-band entry (bondy_bridge_relay under the <<>> band)
%% through export -> delete -> import, exercising both enumeration paths and
%% the new bondy_db export file format.
export_import_roundtrip(Config) ->
    Priv = ?config(priv_dir, Config),
    UsersTab = bondy_namespace_catalog:table(security_users),
    BridgeTab = bondy_namespace_catalog:table(bondy_bridge_relay),
    ?assertNotEqual(undefined, UsersTab),
    ?assertNotEqual(undefined, BridgeTab),

    UKey = <<"alice">>,
    UVal = #{username => UKey, marker => <<"export_test">>},
    BKey = <<"export_test_bridge">>,
    BVal = #{name => BKey, marker => <<"export_test">>},

    %% Seed: a per-realm entry and a global-band (<<>>) entry.
    ok = bondy_db:apply(UsersTab, ?REALM, UKey, {set, UVal}),
    ok = bondy_db:apply(BridgeTab, <<>>, BKey, {set, BVal}),
    ?assertMatch({ok, {UVal, _}}, bondy_db:read(UsersTab, ?REALM, UKey)),
    ?assertMatch({ok, {BVal, _}}, bondy_db:read(BridgeTab, <<>>, BKey)),

    %% Export the whole database.
    {ok, #{filename := File}} = bondy_export:export(#{path => Priv}),
    ok = wait_idle(100),

    %% The file carries the new bondy_db export header.
    {ok, Head} = bondy_export:status(#{filename => File}),
    ?assertMatch(
        #{format := bondy_db_export, vsn := <<"2.0.0">>, status := ok},
        Head
    ),

    %% Delete both entries.
    ok = bondy_db:apply(UsersTab, ?REALM, UKey, clear),
    ok = bondy_db:apply(BridgeTab, <<>>, BKey, clear),
    ?assertEqual({error, not_found}, bondy_db:read(UsersTab, ?REALM, UKey)),
    ?assertEqual({error, not_found}, bondy_db:read(BridgeTab, <<>>, BKey)),

    %% Import the export file.
    {ok, _} = bondy_export:import(#{filename => File}),
    ok = wait_idle(100),

    %% Both entries are restored byte-for-byte.
    ?assertMatch({ok, {UVal, _}}, bondy_db:read(UsersTab, ?REALM, UKey)),
    ?assertMatch({ok, {BVal, _}}, bondy_db:read(BridgeTab, <<>>, BKey)),
    ok.

membership_export_roundtrip(Config) ->
    Priv = ?config(priv_dir, Config),
    Realm = <<"com.example.export_membership">>,
    _ =
        case bondy_realm:exists(Realm) of
            true -> ok;
            false -> bondy_realm:create(Realm)
        end,
    G = <<"exp_group">>,
    U = <<"exp_user">>,
    _ =
        case bondy_rbac_group:lookup(Realm, G) of
            {error, not_found} ->
                {ok, _} = bondy_rbac_group:add(
                    Realm, bondy_rbac_group:new(#{name => G})
                );
            _ ->
                ok
        end,
    _ =
        case bondy_rbac_user:lookup(Realm, U) of
            {error, not_found} ->
                {ok, _} = bondy_rbac_user:add(
                    Realm,
                    bondy_rbac_user:new(#{username => U, groups => [G]})
                );
            _ ->
                ok
        end,

    ?assertEqual(
        [G],
        bondy_rbac_user:groups(bondy_rbac_user:fetch(Realm, U))
    ),

    {ok, #{filename := File}} = bondy_export:export(#{path => Priv}),
    ok = wait_idle(100),

    %% Drop the membership, keeping the user and the group.
    ok = bondy_rbac_user:remove_group(Realm, U, G),
    ?assertEqual(
        [], bondy_rbac_user:groups(bondy_rbac_user:fetch(Realm, U))
    ),

    {ok, _} = bondy_export:import(#{filename => File}),
    ok = wait_idle(100),

    %% A backup must restore group membership.
    ?assertEqual(
        [G],
        bondy_rbac_user:groups(bondy_rbac_user:fetch(Realm, U))
    ),
    ok.

legacy_user_membership_roundtrip(Config) ->
    %% A plum_db-era backup carries a user's groups INLINE on the user record —
    %% the membership relation did not exist yet. Importing one must land those
    %% groups in the relation, which is the only place authorization reads them.
    Priv = ?config(priv_dir, Config),
    Realm = <<"com.example.export_legacy_membership">>,
    _ =
        case bondy_realm:exists(Realm) of
            true -> ok;
            false -> bondy_realm:create(Realm)
        end,
    G = <<"legacy_group">>,
    U = <<"legacy_user">>,
    _ =
        case bondy_rbac_group:lookup(Realm, G) of
            {error, not_found} ->
                {ok, _} = bondy_rbac_group:add(
                    Realm, bondy_rbac_group:new(#{name => G})
                );
            _ ->
                ok
        end,

    File = filename:join(Priv, "legacy_membership.log"),
    _ = file:delete(File),
    LegacyUser = [
        {<<"groups">>, [G]},
        {<<"meta">>, #{}},
        {<<"password">>, [{auth_name, pbkdf2}]}
    ],
    Term =
        {
            {{security_users, Realm}, U},
            {object, {[{{1, node1}, 1, [{LegacyUser, {1700, 0, 0}}]}], []}}
        },
    {ok, Log} = disk_log:open([
        {name, legacy_membership_log},
        {file, File},
        {type, halt},
        {size, infinity},
        {head, #{format => dvvset_log, vsn => <<"1.0.0">>}}
    ]),
    ok = disk_log:log(Log, Term),
    ok = disk_log:close(Log),

    {ok, _} = bondy_export:import(#{filename => File}),
    ok = wait_idle(100),

    %% The user is restored...
    ?assertMatch({ok, _}, bondy_rbac_user:lookup(Realm, U)),
    %% ...with the membership its record declared.
    ?assertEqual(
        [G], bondy_rbac_user:groups(bondy_rbac_user:fetch(Realm, U))
    ),

    %% And the restored cell is in the CURRENT shape: membership lives in the
    %% relation, never inline on the record.
    Table = bondy_namespace_catalog:table(?BONDY_DB_USER_TAB),
    {ok, {Stored, _Hlc}} = bondy_db:read(Table, Realm, U),
    ?assertNot(maps:is_key(groups, Stored)),
    ok.

legacy_user_alias_roundtrip(Config) ->
    %% `security_users` holds two kinds of cell: user records, and alias-pointer
    %% cells (`#{type => alias, username => Target}`) that let a user
    %% authenticate under a second name. A legacy backup carries both, under the
    %% same prefix. The restore must keep them apart: the alias must land under
    %% its OWN key and resolve to its target, and it must not be mistaken for a
    %% user record — the target's record is the one thing an alias must never
    %% overwrite.
    Priv = ?config(priv_dir, Config),
    Realm = <<"com.example.export_legacy_alias">>,
    _ =
        case bondy_realm:exists(Realm) of
            true -> ok;
            false -> bondy_realm:create(Realm)
        end,
    G = <<"alias_group">>,
    U = <<"alias_target">>,
    Alias = <<"alias_one">>,
    _ =
        case bondy_rbac_group:lookup(Realm, G) of
            {error, not_found} ->
                {ok, _} = bondy_rbac_group:add(
                    Realm, bondy_rbac_group:new(#{name => G})
                );
            _ ->
                ok
        end,

    File = filename:join(Priv, "legacy_alias.log"),
    _ = file:delete(File),

    LegacyUser = [
        {<<"groups">>, [G]},
        {<<"aliases">>, [Alias]},
        {<<"meta">>, #{}},
        {<<"password">>, [{auth_name, pbkdf2}]}
    ],
    %% The alias cell is a MAP, keyed by the alias, whose `username` names the
    %% target. It carries a `username` key just like a user record does, which
    %% is exactly why the two cannot be told apart by that key alone.
    AliasEntry = #{type => alias, username => U},

    {ok, Log} = disk_log:open([
        {name, legacy_alias_log},
        {file, File},
        {type, halt},
        {size, infinity},
        {head, #{format => dvvset_log, vsn => <<"1.0.0">>}}
    ]),
    %% User first, alias second — the order in which the alias overwrites the
    %% target if the two cell kinds are conflated.
    ok = disk_log:log(Log, legacy_user_term(Realm, U, LegacyUser)),
    ok = disk_log:log(Log, legacy_user_term(Realm, Alias, AliasEntry)),
    ok = disk_log:close(Log),

    {ok, _} = bondy_export:import(#{filename => File}),
    ok = wait_idle(100),

    %% The target user survived intact, with the membership its record declared.
    ?assertMatch({ok, #{type := user}}, bondy_rbac_user:lookup(Realm, U)),
    ?assertEqual(
        [G], bondy_rbac_user:groups(bondy_rbac_user:fetch(Realm, U))
    ),

    %% The alias resolves to the target user.
    ?assertMatch(
        {ok, #{type := user, username := U}},
        bondy_rbac_user:lookup(Realm, Alias)
    ),

    %% And it is stored as an alias cell under its own key, not as a user.
    Table = bondy_namespace_catalog:table(?BONDY_DB_USER_TAB),
    ?assertMatch(
        {ok, {#{type := alias, username := U}, _Hlc}},
        bondy_db:read(Table, Realm, Alias)
    ),
    ok.

%% @private
legacy_user_term(Realm, Key, Payload) ->
    {
        {{security_users, Realm}, Key},
        {object, {[{{1, node1}, 1, [{Payload, {1700, 0, 0}}]}], []}}
    }.

legacy_poison_record_is_skipped(Config) ->
    %% One unimportable record must not abort the whole restore. The records
    %% after it still land, and the failure is counted rather than raised.
    Priv = ?config(priv_dir, Config),
    Realm = <<"com.example.export_legacy_poison">>,
    _ =
        case bondy_realm:exists(Realm) of
            true -> ok;
            false -> bondy_realm:create(Realm)
        end,

    File = filename:join(Priv, "legacy_poison.log"),
    _ = file:delete(File),

    %% A user whose payload is not a proplist or a current user map: the
    %% translation raises on it.
    Poison =
        {
            {{security_users, Realm}, <<"poison_user">>},
            {object,
                {[{{1, node1}, 1, [{not_a_user_payload, {1700, 0, 0}}]}], []}}
        },
    Good = [{<<"groups">>, []}, {<<"meta">>, #{}}],
    Sound =
        {
            {{security_users, Realm}, <<"sound_user">>},
            {object, {[{{1, node1}, 1, [{Good, {1700, 0, 0}}]}], []}}
        },

    {ok, Log} = disk_log:open([
        {name, legacy_poison_log},
        {file, File},
        {type, halt},
        {size, infinity},
        {head, #{format => dvvset_log, vsn => <<"1.0.0">>}}
    ]),
    ok = disk_log:log(Log, Poison),
    ok = disk_log:log(Log, Sound),
    ok = disk_log:close(Log),

    %% The import runs asynchronously; it completing at all is the point.
    {ok, _} = bondy_export:import(#{filename => File}),
    ok = wait_idle(100),

    %% The record AFTER the poison one was still applied — the import skipped
    %% the bad record and carried on rather than dying on it.
    ?assertMatch({ok, _}, bondy_rbac_user:lookup(Realm, <<"sound_user">>)),
    %% And the bad record was not applied.
    ?assertEqual(
        {error, not_found}, bondy_rbac_user:lookup(Realm, <<"poison_user">>)
    ),
    ok.

%% A legacy refresh-token string, imported via bondy_oauth_token:import_legacy/1,
%% must resolve on its first refresh (yielding a current self-describing token)
%% and then be one-time: the legacy string fails afterwards, the new token works.
legacy_token_refresh_roundtrip(_Config) ->
    ok = ensure_realm(?TOKEN_REALM),
    ok = ensure_user(?TOKEN_REALM, ?TOKEN_USER),

    Now = erlang:system_time(second),
    Legacy = <<"LEGACYrefreshTOKENstring0123456789abcd">>,
    Spec = #{
        authrealm => ?TOKEN_REALM,
        refresh_token => Legacy,
        username => ?TOKEN_USER,
        client_id => <<"test_client">>,
        device_id => all,
        groups => [],
        meta => #{},
        expires_in => 3600,
        issued_at => Now
    },

    %% Import the legacy token.
    ?assertEqual(ok, bondy_oauth_token:import_legacy(Spec)),

    %% First refresh with the bare legacy string resolves via the pointer and
    %% returns a current, self-describing refresh token.
    {ok, NewToken} = bondy_oauth_token:refresh(?TOKEN_REALM, Legacy),
    NewRefresh = bondy_oauth_token:to_refresh_token(NewToken),
    ?assertNotEqual(Legacy, NewRefresh),
    ?assertMatch(<<"bondy:rtoken:", _/binary>>, NewRefresh),

    %% One-time: the legacy string no longer resolves (pointer cleared).
    ?assertMatch({error, _}, bondy_oauth_token:refresh(?TOKEN_REALM, Legacy)),

    %% The upgraded token continues to work.
    ?assertMatch({ok, _}, bondy_oauth_token:refresh(?TOKEN_REALM, NewRefresh)),
    ok.

%% @private
ensure_realm(Uri) ->
    case bondy_realm:exists(Uri) of
        true ->
            ok;
        false ->
            _ = bondy_realm:create(#{uri => Uri, security_enabled => true}),
            ok
    end.

%% @private
ensure_user(Realm, Username) ->
    case bondy_rbac_user:lookup(Realm, Username) of
        {ok, _} ->
            ok;
        {error, not_found} ->
            User = bondy_rbac_user:new(#{username => Username, groups => []}),
            {ok, _} = bondy_rbac_user:add(Realm, User),
            ok
    end.

%% @private
%% Polls the (async) export/import worker until it returns to idle.
wait_idle(0) ->
    {error, timeout};
wait_idle(N) ->
    case bondy_export:status(#{}) of
        {ok, undefined} ->
            ok;
        {ok, _InProgress} ->
            timer:sleep(100),
            wait_idle(N - 1)
    end.
