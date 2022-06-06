%% =============================================================================
%%  bondy_auth_password_SUITE.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

-module(bondy_auth_alias_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(P1, <<"aWe11KeptSecret">>).
-define(P2, <<"An0therWe11KeptSecret">>).
-define(REALM, #{
    description => <<"A test realm">>,
    authmethods => [
        ?PASSWORD_AUTH
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
    users => [
        #{
            username => ?U1,
            password => ?P1,
            groups => [],
            meta => #{}
        },
        #{
            username => ?U2,
            password => ?P1,
            groups => [],
            meta => #{}
        }
    ],
    sources => [
        #{
            usernames => [?U1],
            authmethod => ?PASSWORD_AUTH,
            cidr => <<"0.0.0.0/0">>
        },
        #{
            usernames => [?U2],
            authmethod => ?PASSWORD_AUTH,
            cidr => <<"192.168.0.0/16">>
        }
    ]
}).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        test_1,
        sso
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.auth_alias">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri}|Config].

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.


add_realm(RealmUri) ->
    _ = bondy_realm:create((?REALM)#{uri => RealmUri}),
    ok.


test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    SessionId = bondy_session_id:new(),
    Roles = [],
    Peer = {{127, 0, 0, 1}, 10000},
    Alias = <<?U1/binary, ":alias1">>,

    ok = bondy_rbac_user:add_alias(RealmUri, ?U1, Alias),

    {ok, Ctxt1} = bondy_auth:init(SessionId, RealmUri, Alias, Roles, Peer),


    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt1)
    ),

    ok = bondy_rbac_user:remove_alias(RealmUri, ?U1, Alias),

    ?assertEqual(
        {error,{no_such_user, Alias}},
        bondy_auth:init(SessionId, RealmUri, Alias, Roles, Peer)
    ).


sso(_) ->
    SSOUri = <<"com.leapsight.test+auth_alias_sso">>,
    Uri = <<"com.leapsight.test+auth_alias">>,

    _ = bondy_realm:create((?REALM)#{
        uri => SSOUri,
        is_sso_realm => true,
        users => [],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]

    }),
    _ = bondy_realm:create((?REALM)#{
        uri => Uri,
        authmethods => [?PASSWORD_AUTH],
        is_sso_realm => false,
        sso_realm_uri => SSOUri,
        users => [],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    }),

    User = #{
        username => ?U1,
        password => ?P1,
        sso_realm_uri => SSOUri
    },
    SessionId = bondy_session_id:new(),
    Roles = [],
    Peer = {{127, 0, 0, 1}, 10000},
    Alias = <<?U1/binary, ":alias2">>,

    {ok, _} = bondy_rbac_user:add(Uri, bondy_rbac_user:new(User)),

    {ok, Ctxt1} = bondy_auth:init(SessionId, SSOUri, ?U1, Roles, Peer),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt1)
    ),

    {ok, Ctxt2} = bondy_auth:init(SessionId, Uri, ?U1, Roles, Peer),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt2)
    ),

    ok = bondy_rbac_user:add_alias(Uri, ?U1, Alias),


    {ok, Ctxt3} = bondy_auth:init(SessionId, SSOUri, Alias, Roles, Peer),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt3)
    ),

    {ok, Ctxt4} = bondy_auth:init(SessionId, Uri, Alias, Roles, Peer),
    ?assertMatch(
        {ok, _, _},
        bondy_auth:authenticate(?PASSWORD_AUTH, ?P1, undefined, Ctxt4)
    ),

    ok = bondy_rbac_user:remove_alias(Uri, ?U1, Alias),

    ?assertEqual(
        {error,{no_such_user, Alias}},
        bondy_auth:init(SessionId, SSOUri, Alias, Roles, Peer)
    ),
    ?assertEqual(
        {error,{no_such_user, Alias}},
        bondy_auth:init(SessionId, Uri, Alias, Roles, Peer)
    ).

