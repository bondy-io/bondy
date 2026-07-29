%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_export_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.export_test">>).

-define(TOKEN_REALM, <<"com.example.export_token">>).
-define(TOKEN_USER, <<"tokuser">>).

all() ->
    [export_import_roundtrip, legacy_token_refresh_roundtrip].

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
