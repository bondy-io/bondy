%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_oauth2_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(U_NOPASS, <<"user_no_password">>).
-define(APP1, <<"app_1">>).
-define(PASS, <<"aWe11KeptSecret">>).

-define(REALM, #{
    description => <<"A test realm">>,
    authmethods => [
        ?WAMP_OAUTH2_AUTH, ?PASSWORD_AUTH
    ],
    security_enabled => true,
    grants => [
        #{
            permissions => [
                <<"wamp.register">>,
                <<"wamp.unregister">>,
                <<"wamp.subscribe">>,
                <<"wamp.unsubscribe">>,
                <<"wamp.call">>,
                <<"wamp.cancel">>,
                <<"wamp.publish">>
            ],
            uri => <<"">>,
            match => <<"prefix">>,
            roles => <<"all">>
        }
    ],
    groups => [
        #{name => <<"group_1">>},
        #{name => <<"api_clients">>},
        #{name => <<"resource_owners">>}
    ],
    users => [
        #{
            username => ?U1,
            password => ?PASS,
            groups => [<<"resource_owners">>, <<"group_1">>]
        },
        #{
            username => ?U2,
            password => ?PASS,
            groups => [<<"group_1">>]
        },
        #{
            username => ?APP1,
            password => ?PASS,
            groups => [<<"api_clients">>]
        },
        #{
            username => ?U_NOPASS,
            groups => [],
            meta => #{}
        }
    ],
    sources => [
        #{
            usernames => [?U1, ?APP1],
            authmethod => ?WAMP_OAUTH2_AUTH,
            cidr => <<"0.0.0.0/0">>
        },
        #{
            usernames => [?U2],
            authmethod => ?WAMP_OAUTH2_AUTH,
            cidr => <<"192.168.0.0/16">>
        },
        #{
            usernames => <<"all">>,
            authmethod => ?PASSWORD_AUTH,
            cidr => <<"0.0.0.0/0">>
        },
        #{
            usernames => [?U_NOPASS],
            authmethod => ?WAMP_OAUTH2_AUTH,
            cidr => <<"0.0.0.0/0">>
        }
    ]
}).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        %% Original tests (preserved)
        resource_owner_password,
        client_credentials,

        %% OAuth2 method availability
        oauth2_method_available,

        %% Challenge step
        challenge_returns_true_empty_extra,

        %% Token issuance
        password_grant_jwt_has_required_claims,
        client_credentials_grant_issues_token,
        custom_expiry_in_token,

        %% Full auth flow
        full_oauth2_auth_flow,
        wrong_user_token_rejected,
        invalid_jwt_rejected,

        %% Source / CIDR
        user2_rejected_outside_cidr,
        user2_allowed_within_cidr,

        %% Method selection
        method_mismatch_after_challenge,
        invalid_method_rejected,

        %% User without password
        user_without_password_excluded,

        %% Error cases
        nonexistent_user_error,

        %% Context
        context_method_set_after_auth
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.auth_oauth2">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri} | Config].

end_per_suite(Config) ->
    {save_config, Config}.


add_realm(RealmUri) ->
    _ = bondy_realm:create(maps:merge(?REALM, #{uri => RealmUri})),
    ok.



%% =============================================================================
%% HELPERS
%% =============================================================================



%% @private
issue_jwt(RealmUri, Username, Roles) ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, Username, Roles, {127, 0, 0, 1}
    ),
    {ok, Token} = bondy_oauth_token:issue(password, Ctxt, #{}),
    {ok, {JWT, _}} = bondy_oauth_token:to_access_token(Token),
    JWT.



%% =============================================================================
%% ORIGINAL TESTS (PRESERVED)
%% =============================================================================



resource_owner_password(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [<<"group_1">>],
    SourceIP = {127, 0, 0, 1},
    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, ?U1, Roles, SourceIP),
    {ok, Token} = bondy_oauth_token:issue(password, Ctxt1, #{}),
    {ok, {JWT, _}} = bondy_oauth_token:to_access_token(Token),

    ?assertMatch(
        {ok, #{
            <<"id">> := _,
            <<"vsn">> := _,
            <<"exp">> := _,
            <<"iat">> := _,
            <<"ion">> := _,
            <<"kid">> := _,
            <<"iss">> := _,
            <<"aud">> := RealmUri,
            <<"sub">> := ?U1,
            <<"auth">> := #{
                <<"scope">> := #{
                    <<"realm">> := RealmUri,
                    <<"client_id">> := _,
                    <<"device_id">> := _
                }
            },
            <<"meta">> := _,
            <<"groups">> := _
        }},
        bondy_oauth_jwt:verify(RealmUri, JWT)
    ),

    ?assertEqual(
        true,
        lists:member(?WAMP_OAUTH2_AUTH, bondy_auth:available_methods(Ctxt1))
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_OAUTH2_AUTH, JWT, #{}, Ctxt1)
    ),

    ok.


client_credentials(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    SourceIP = {127, 0, 0, 1},
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?APP1, [<<"api_clients">>], SourceIP
    ),
    {ok, Token} = bondy_oauth_token:issue(client_credentials, Ctxt, #{}),
    {ok, {JWT, _}} = bondy_oauth_token:to_access_token(Token),

    ?assertMatch(
        {ok, #{
            <<"aud">> := RealmUri,
            <<"sub">> := ?APP1
        }},
        bondy_oauth_jwt:verify(RealmUri, JWT)
    ),

    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?WAMP_OAUTH2_AUTH, JWT, #{}, Ctxt)
    ).



%% =============================================================================
%% OAUTH2 METHOD AVAILABILITY
%% =============================================================================



oauth2_method_available(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    ?assert(
        lists:member(?WAMP_OAUTH2_AUTH, bondy_auth:available_methods(Ctxt))
    ).



%% =============================================================================
%% CHALLENGE STEP
%% =============================================================================



challenge_returns_true_empty_extra(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    {true, Extra, _Ctxt1} = bondy_auth:challenge(
        ?WAMP_OAUTH2_AUTH, #{}, Ctxt0
    ),

    %% OAuth2 challenge returns true with empty extra
    ?assertEqual(#{}, Extra).



%% =============================================================================
%% TOKEN ISSUANCE
%% =============================================================================



password_grant_jwt_has_required_claims(Config) ->
    RealmUri = ?config(realm_uri, Config),
    JWT = issue_jwt(RealmUri, ?U1, [<<"group_1">>]),

    {ok, Claims} = bondy_oauth_jwt:verify(RealmUri, JWT),

    %% Required top-level claims
    ?assert(maps:is_key(<<"id">>, Claims)),
    ?assert(maps:is_key(<<"vsn">>, Claims)),
    ?assert(maps:is_key(<<"exp">>, Claims)),
    ?assert(maps:is_key(<<"iat">>, Claims)),
    ?assert(maps:is_key(<<"kid">>, Claims)),
    ?assert(maps:is_key(<<"iss">>, Claims)),
    ?assert(maps:is_key(<<"aud">>, Claims)),
    ?assert(maps:is_key(<<"sub">>, Claims)),
    ?assert(maps:is_key(<<"auth">>, Claims)),

    ?assertEqual(RealmUri, maps:get(<<"aud">>, Claims)),
    ?assertEqual(?U1, maps:get(<<"sub">>, Claims)),

    %% auth.scope must have realm, client_id, device_id
    Auth = maps:get(<<"auth">>, Claims),
    ?assert(maps:is_key(<<"scope">>, Auth)),
    Scope = maps:get(<<"scope">>, Auth),
    ?assert(maps:is_key(<<"realm">>, Scope)),
    ?assert(maps:is_key(<<"client_id">>, Scope)),
    ?assert(maps:is_key(<<"device_id">>, Scope)).


client_credentials_grant_issues_token(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?APP1, [<<"api_clients">>], {127, 0, 0, 1}
    ),
    {ok, Token} = bondy_oauth_token:issue(client_credentials, Ctxt, #{}),
    {ok, {JWT, ExpiresIn}} = bondy_oauth_token:to_access_token(Token),

    ?assert(is_binary(JWT)),
    ?assert(is_integer(ExpiresIn)),
    ?assert(ExpiresIn > 0),

    {ok, Claims} = bondy_oauth_jwt:verify(RealmUri, JWT),
    ?assertEqual(?APP1, maps:get(<<"sub">>, Claims)),
    ?assertEqual(RealmUri, maps:get(<<"aud">>, Claims)).


custom_expiry_in_token(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    CustomExpiry = 3600,
    {ok, Token} = bondy_oauth_token:issue(
        password, Ctxt, #{expiry_time_secs => CustomExpiry}
    ),
    {ok, {JWT, _}} = bondy_oauth_token:to_access_token(Token),

    {ok, Claims} = bondy_oauth_jwt:verify(RealmUri, JWT),
    ?assert(maps:is_key(<<"exp">>, Claims)),
    ?assert(is_integer(maps:get(<<"exp">>, Claims))).



%% =============================================================================
%% FULL AUTH FLOW
%% =============================================================================



full_oauth2_auth_flow(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% Step 1: Init auth context
    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [<<"group_1">>], {127, 0, 0, 1}
    ),

    %% Step 2: Challenge
    {true, #{}, Ctxt1} = bondy_auth:challenge(
        ?WAMP_OAUTH2_AUTH, #{}, Ctxt0
    ),

    %% Step 3: Issue token (simulating client already has one)
    JWT = issue_jwt(RealmUri, ?U1, [<<"group_1">>]),

    %% Step 4: Authenticate
    {ok, AuthExtra, Ctxt2} = bondy_auth:authenticate(
        ?WAMP_OAUTH2_AUTH, JWT, #{}, Ctxt1
    ),

    %% AuthExtra contains the JWT claims
    ?assert(is_map(AuthExtra)),
    ?assertEqual(?U1, maps:get(<<"sub">>, AuthExtra)),
    ?assertEqual(?WAMP_OAUTH2_AUTH, bondy_auth:method(Ctxt2)).


wrong_user_token_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% Issue JWT for U1
    JWT = issue_jwt(RealmUri, ?U1, [<<"group_1">>]),

    %% Try to authenticate as U2 with U1's token (from within U2's CIDR)
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U2, [], {192, 168, 1, 1}
    ),

    ?assertMatch(
        {error, oauth2_invalid_grant},
        bondy_auth:authenticate(?WAMP_OAUTH2_AUTH, JWT, #{}, Ctxt)
    ).


invalid_jwt_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),

    ?assertMatch(
        {error, _},
        bondy_auth:authenticate(
            ?WAMP_OAUTH2_AUTH, <<"not.a.valid.jwt">>, #{}, Ctxt
        )
    ).



%% =============================================================================
%% SOURCE / CIDR
%% =============================================================================



user2_rejected_outside_cidr(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% U2 source is 192.168.0.0/16; 127.0.0.1 is outside
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U2, [], {127, 0, 0, 1}
    ),
    ?assertNot(
        lists:member(?WAMP_OAUTH2_AUTH, bondy_auth:available_methods(Ctxt))
    ).


user2_allowed_within_cidr(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    %% U2 source is 192.168.0.0/16; 192.168.1.1 is inside
    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U2, [], {192, 168, 1, 1}
    ),
    ?assert(
        lists:member(?WAMP_OAUTH2_AUTH, bondy_auth:available_methods(Ctxt))
    ).



%% =============================================================================
%% METHOD SELECTION
%% =============================================================================



method_mismatch_after_challenge(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    {true, _, Ctxt1} = bondy_auth:challenge(
        ?WAMP_OAUTH2_AUTH, #{}, Ctxt0
    ),

    %% After oauth2 challenge, trying password auth should fail
    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?PASS, undefined, Ctxt1)
    ).


invalid_method_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [], {127, 0, 0, 1}
    ),
    ?assertMatch(
        {error, invalid_method},
        bondy_auth:authenticate(
            <<"bogus_method">>, <<"data">>, undefined, Ctxt
        )
    ).



%% =============================================================================
%% USER WITHOUT PASSWORD
%% =============================================================================



user_without_password_excluded(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, ?U_NOPASS, [], {127, 0, 0, 1}
    ),
    %% OAuth2 requires password (cra or scram protocol); user without password excluded
    ?assertNot(
        lists:member(?WAMP_OAUTH2_AUTH, bondy_auth:available_methods(Ctxt))
    ).



%% =============================================================================
%% ERROR CASES
%% =============================================================================



nonexistent_user_error(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    ?assertMatch(
        {error, {no_such_user, <<"ghost">>}},
        bondy_auth:init(SessionId, RealmUri, <<"ghost">>, [], {127, 0, 0, 1})
    ).



%% =============================================================================
%% CONTEXT
%% =============================================================================



context_method_set_after_auth(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),

    {ok, Ctxt0} = bondy_auth:init(
        SessionId, RealmUri, ?U1, [<<"group_1">>], {127, 0, 0, 1}
    ),

    JWT = issue_jwt(RealmUri, ?U1, [<<"group_1">>]),

    {ok, _, Ctxt1} = bondy_auth:authenticate(
        ?WAMP_OAUTH2_AUTH, JWT, #{}, Ctxt0
    ),

    ?assertEqual(?WAMP_OAUTH2_AUTH, bondy_auth:method(Ctxt1)),
    ?assertEqual(RealmUri, bondy_auth:realm_uri(Ctxt1)),
    ?assertEqual(?U1, bondy_auth:user_id(Ctxt1)).
