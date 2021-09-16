%% =============================================================================
%%  bondy_rbac_SUITE.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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

-module(bondy_rbac_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(U3, <<"user_3">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        test_1,
        test_grants,
        group_topsort_error,
        group_topsort
    ].


init_per_suite(Config) ->
    common:start_bondy(),
    RealmUri = <<"com.example.test.rbac">>,
    ok = add_realm(RealmUri),

    [{realm_uri, RealmUri}| Config].

end_per_suite(Config) ->
    % common:stop_bondy(),
    {save_config, Config}.


add_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?TRUST_AUTH
        ],
        security_enabled => true,
        groups => [
            #{
                name => <<"com.thing.system.service">>,
                groups => [],
                meta => #{}
            },
            #{
                name => <<"com.thing.system.other">>,
                groups => [],
                meta => #{}
            }
        ],
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
                roles => [
                    <<"com.thing.system.service">>,
                    <<"com.thing.system.other">>,
                    ?U3
                ]
            },
            #{
                permissions => [
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>,
                    <<"wamp.call">>,
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
                groups => [<<"com.thing.system.service">>],
                meta => #{}
            },
            #{
                username => ?U2,
                groups => [],
                meta => #{}
            },
            #{
                username => ?U3,
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [?U1],
                authmethod => ?TRUST_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [?U2],
                authmethod => ?TRUST_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:add(Config),
    ok.


test_1(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Peer = {{127,0,0,0}, 52000},
    SessionOpts = #{
        is_anonymous => false,
        security_enabled => bondy_realm:is_security_enabled(RealmUri),
        roles => #{
            caller => #{
                features => #{
                    call_timeout => true,
                    caller_identification => true,
                    call_trustlevels => true,
                    call_canceling => true,
                    progressive_call_results => false
                }
            }
        }
    },
    U1Ctxt = #{
        realm_uri => RealmUri,
        security_enabled => true,
        authid => ?U1,
        session => bondy_session:new(
            Peer, RealmUri, SessionOpts#{authid => ?U1}
        )
    },
    U2Ctxt = #{
        realm_uri => RealmUri,
        security_enabled => true,
        authid => ?U2,
        session => bondy_session:new(
            Peer, RealmUri, SessionOpts#{authid => ?U2}
        )
    },
    U3Ctxt = #{
        realm_uri => RealmUri,
        security_enabled => true,
        authid => ?U3,
        session => bondy_session:new(
            Peer, RealmUri, SessionOpts#{authid => ?U3}
        )
    },

    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.my.call">>, U1Ctxt),
        "U1 can register"
    ),

    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.my.call">>, U2Ctxt),
        "U2 cannot register"
    ),

    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.my.call">>, U3Ctxt),
        "U3 can register"
    ).


test_grants(_) ->
    Uri = <<"com.example.foo">>,
    Data = #{
        uri  => Uri,
        authmethods => [
            <<"wampcra">>, <<"anonymous">>, <<"password">>, <<"cryptosign">>
        ],
        security_enabled => true,
        users => [
            #{
                username => <<"urn:user:admin">>,
                authorized_keys =>[
                    <<"1766c9e6ec7d7b354fd7a2e4542753a23cae0b901228305621e5b8713299ccdd">>
                ],
                groups => [
                    <<"urn:group:system:admin">>
                ]
            },
            #{
                username => <<"urn:user:device_registry">>,
                authorized_keys => [
                    <<"1766c9e6ec7d7b354fd7a2e4542753a23cae0b901228305621e5b8713299ccdd">>
                ],
                groups => [
                    <<"urn:group:system:service:device_registry">>
                ]
            },
            #{
                username => <<"urn:user:account">>,
                authorized_keys => [
                    <<"1766c9e6ec7d7b354fd7a2e4542753a23cae0b901228305621e5b8713299ccdd">>
                ],
                groups => [
                    <<"urn:group:system:service:account">>
                ]
            },
            #{
                username => <<"device_registry_test">>,
                password => <<"Password123">>,
                authorized_keys => [
                    <<"1766c9e6ec7d7b354fd7a2e4542753a23cae0b901228305621e5b8713299ccdd">>
                ],
                groups => [
                    <<"urn:group:device_manager">>,
                    <<"urn:group:system:admin">>
                ]
            }
        ],
        groups => [
            #{
                name => <<"urn:group:system:service:device_registry">>,
                groups => [
                    <<"urn:group:system:service">>
                ]
            },
            #{
                name => <<"urn:group:system:service:account">>,
                groups => [
                    <<"urn:group:system:service">>
                ]
            },
            #{
                name => <<"urn:group:device_manager">>,
                groups => []
            },
            #{
                name => <<"urn:group:system:admin">>,
                groups => []
            },
            #{
                name => <<"urn:group:system:admin">>,
                groups => []
            },
            #{
                name => <<"urn:group:system:service">>,
                groups => []
            }
        ],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => <<"wampcra">>,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => <<"all">>,
                authmethod => <<"cryptosign">>,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => <<"all">>,
                authmethod => <<"trust">>,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [<<"anonymous">>],
                authmethod => <<"anonymous">>,
                cidr => <<"0.0.0.0/0">>
            }
        ],
        grants => [
            #{
                permissions => [
                    <<"wamp.call">>,
                    <<"wamp.cancel">>,
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>
                ],
                resources => [
                    #{uri => <<"bondy.">>, match => <<"prefix">>},
                    #{uri => <<"wamp.">>, match => <<"prefix">>}
                ],
                roles => [
                    <<"urn:group:system:admin">>,
                    <<"urn:group:device_manager">>
                ]
            },
            #{
                permissions => [
                    <<"wamp.call">>,
                    <<"wamp.cancel">>,
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>
                ],
                resources => [
                    #{uri => <<"bondy.">>, match => <<"prefix">>},
                    #{uri => <<"wamp.">>, match => <<"prefix">>}
                ],
                roles => [
                    <<"urn:group:system:service">>
                ]
            },
            #{
                permissions => [
                    <<"wamp.call">>
                ],
                resources => [
                    #{uri => <<"bondy.">>, match => <<"prefix">>}
                ],
                roles => [<<"anonymous">>]
            }
        ]
    },
    _ = bondy_realm:add(Data),
    C = bondy_rbac:get_context(Uri, <<"device_registry_test">>),

    % dbg:tracer(), dbg:p(all,c), dbg:tpl(bondy_rbac, '_', x),

    ?assertMatch(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"bondy.realm.list">>, C)
    ).

group_topsort_error(_) ->
    Groups = [bondy_rbac_group:new(G) || G <- [
        #{
            name => <<"a">>,
            groups => [<<"b">>],
            meta => #{}
        },
        #{
            name => <<"b">>,
            groups => [<<"a">>],
            meta => #{}
        }
    ]],
    ?assertError(
        {cycle, [<<"b">>,<<"a">>]},
        [maps:get(name, G) || G <- bondy_rbac_group:topsort(Groups)]
    ).

group_topsort(_) ->
    Groups = [bondy_rbac_group:new(G) || G <- [
        #{
            name => <<"a">>,
            groups => [<<"z">>],
            meta => #{}
        },
        #{
            name => <<"b">>,
            groups => [<<"a">>],
            meta => #{}
        },
        #{
            name => <<"c">>,
            groups => [<<"d">>, <<"b">>],
            meta => #{}
        },
        #{
            name => <<"d">>,
            groups => [<<"z">>],
            meta => #{}
        }
    ]],
    ?assertEqual(
        [<<"a">>, <<"b">>, <<"d">>, <<"c">>],
        [maps:get(name, G) || G <- bondy_rbac_group:topsort(Groups)]
    ).