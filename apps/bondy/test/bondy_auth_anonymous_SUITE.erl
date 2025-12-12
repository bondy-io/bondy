%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_auth_anonymous_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        test
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.auth_anonymous">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri}|Config].

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.


test(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Roles = [],
    SourceIP = {127, 0, 0, 1},
    SessionId = bondy_session_id:new(),

    {ok, Ctxt} = bondy_auth:init(
        SessionId, RealmUri, anonymous, Roles, SourceIP
    ),

    ?assertMatch(
        {false, _},
        bondy_auth:challenge(?WAMP_ANON_AUTH, undefined, Ctxt)
    ),


    ?assertEqual(
        true,
        lists:member(?WAMP_ANON_AUTH, bondy_auth:available_methods(Ctxt))
    ),

    ?assertMatch(
        {ok, _, _},
        authenticate(?WAMP_ANON_AUTH, RealmUri, Roles, SourceIP)
    ),

    ?assertMatch(
        {error, method_not_allowed},
        authenticate(?PASSWORD_AUTH, RealmUri, Roles, SourceIP)
    ),

    ?assertMatch(
        {error, invalid_method},
        authenticate(<<"foo">>, RealmUri, Roles, SourceIP)
    ).



authenticate(Method, Uri, Roles, Peer) ->
    SessionId = bondy_session_id:new(),
    Roles = [],
    {ok, Ctxt} = bondy_auth:init(SessionId, Uri, anonymous, Roles, Peer),
    bondy_auth:authenticate(Method, undefined, undefined, Ctxt).


add_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?WAMP_ANON_AUTH, ?PASSWORD_AUTH
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
            },
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
                roles => [<<"anonymous">>]
            }
        ],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:create(Config),
    ok.
