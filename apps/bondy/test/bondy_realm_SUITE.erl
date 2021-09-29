%% =============================================================================
%%  bondy_realm_SUITE.erl -
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

-module(bondy_realm_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").
-include("bondy.hrl").

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(U3, <<"user_3">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        uri,
        reserved,
        delete_master_realm,
        invalid_uri,
        invalid_description,

        sso_inconsistency_error,
        sso_uri_not_found_error,
        is_sso_realm,

        prototype_inconsistency_error,
        prototype_badarg,
        prototype_uri_not_found_error,
        is_prototype,
        prototype_uri,
        prototype_inheritance

    ].


init_per_suite(Config) ->
    common:start_bondy(),
    Config.


end_per_suite(Config) ->
    % common:stop_bondy(),
    {save_config, Config}.


uri(_) ->
    Uri = bondy_utils:generate_fragment(6),
    R = bondy_realm:create(#{uri => Uri}),

    ?assertEqual(Uri, bondy_realm:uri(R)),

    ?assertMatch(
        R,
        bondy_realm:update(Uri, #{uri => Uri}),
        "Property is immutable"
    ),

    ?assertMatch(
        R,
        bondy_realm:update(R, #{uri => Uri}),
        "Property is immutable"
    ),

    ?assertMatch(
        R,
        bondy_realm:update(Uri, #{uri => bondy_utils:generate_fragment(6)}),
        "Property is immutable"
    ),

    ?assertMatch(
        R,
        bondy_realm:update(R, #{uri => bondy_utils:generate_fragment(6)}),
        "Property is immutable"
    ).


reserved(_) ->
    ?assertMatch(
        true,
        is_tuple(bondy_realm:create(#{uri => <<"com.leapsight.a">>}))
    ),

    ?assertError(
        badarg,
        bondy_realm:create(#{uri => ?MASTER_REALM_URI})
    ),

    ?assertError(
        badarg,
        bondy_realm:create(#{uri => <<"com.leapsight.bondy.foo">>})
    ).


delete_master_realm(_) ->
    Uri = ?MASTER_REALM_URI,
    R = bondy_realm:fetch(Uri),

    ?assertError(
        badarg,
        bondy_realm:delete(Uri)
    ),

    ?assertError(
        badarg,
        bondy_realm:delete(R)
    ).



invalid_uri(_) ->
    ?assertError(
        #{
            code := invalid_value
        },
        bondy_realm:create(#{uri => <<"foo\s">>})
    ).


invalid_description(_) ->
    TooLong = bondy_utils:generate_fragment(513),
    ?assertError(
        #{
            code := invalid_value,
            description := <<"The value for 'description' did not pass the validator. Value is too big (max. is 512 bytes).">>
        },
        bondy_realm:create(#{uri => <<"foo">>, description => TooLong})
    ).


sso_inconsistency_error(_) ->
    ?assertError(
        {inconsistency_error, [is_sso_realm, sso_realm_uri]},
        bondy_realm:create(#{
            uri => bondy_utils:generate_fragment(6),
            is_sso_realm => true,
            sso_realm_uri => bondy_utils:generate_fragment(6)
        }),
        "An sso realm cannot itself have an sso realm"
    ).


sso_uri_not_found_error(_) ->
    ?assertError(
        {badarg, _},
        bondy_realm:create(#{
            uri => bondy_utils:generate_fragment(6),
            sso_realm_uri => bondy_utils:generate_fragment(6)
        }),
        "SSO realm should exist"
    ).


is_sso_realm(_) ->
    Uri = bondy_utils:generate_fragment(6),
    R = bondy_realm:create(#{
        uri => Uri,
        is_sso_realm => true
    }),

    ?assertMatch(
        R,
        bondy_realm:update(Uri, #{is_sso_realm => true}),
        "Property is immutable"
    ),

    ?assertError(
        {badarg, _},
        bondy_realm:update(Uri, #{is_sso_realm => false}),
        "Property is immutable"
    ).


prototype_inconsistency_error(_) ->
    ?assertError(
        {inconsistency_error, [is_prototype, prototype_uri]},
        bondy_realm:create(#{
            uri => bondy_utils:generate_fragment(6),
            is_prototype => true,
            prototype_uri => bondy_utils:generate_fragment(6)
        }),
        "a prototype cannot have a prototype"
    ).

prototype_badarg(_) ->
    Uri = bondy_utils:generate_fragment(6),
    ?assertError(
        {badarg, [uri, prototype_uri], _},
        bondy_realm:create(#{
            uri => Uri,
            prototype_uri => Uri
        }),
        "uri and prototype_uri cannot be equal"
    ).


prototype_uri_not_found_error(_) ->
    ?assertError(
        {badarg, _},
        bondy_realm:create(#{
            uri => bondy_utils:generate_fragment(6),
            prototype_uri => bondy_utils:generate_fragment(6)
        }),
        "Prototype realm should exist"
    ).


is_prototype(_) ->
    Uri = bondy_utils:generate_fragment(6),
    R = bondy_realm:create(#{
        uri => Uri,
        is_prototype => true
    }),

    ?assertEqual(true, bondy_realm:is_prototype(R)),
    ?assertEqual(true, bondy_realm:is_prototype(Uri)),

    ?assertMatch(
        R,
        bondy_realm:update(Uri, #{is_prototype => true}),
        "Property is immutable"
    ),

    ?assertError(
        {badarg, _},
        bondy_realm:update(Uri, #{is_prototype => false}),
        "Property is immutable"
    ).


prototype_uri(_) ->
    ProtoUri = bondy_utils:generate_fragment(6),
    _ = bondy_realm:create(#{
        uri => ProtoUri,
        is_prototype => true
    }),

    Uri = bondy_utils:generate_fragment(6),
    R = bondy_realm:create(#{
        uri => Uri,
        prototype_uri => ProtoUri
    }),

    ?assertEqual(ProtoUri, bondy_realm:prototype_uri(R)),
    ?assertEqual(ProtoUri, bondy_realm:prototype_uri(Uri)),

    ?assertMatch(
        R,
        bondy_realm:update(Uri, #{
            prototype_uri => ProtoUri
        }),
        "Property is immutable"
    ),

    ?assertError(
        {badarg, _},
        bondy_realm:update(Uri, #{
            prototype_uri => bondy_utils:generate_fragment(6)
        }),
        "Property is immutable"
    ).


prototype_inheritance(_) ->
    SSOUri = bondy_utils:generate_fragment(6),
    _SSO = bondy_realm:create(#{
        uri => SSOUri,
        is_sso_realm => true
    }),

    ProtoUri = bondy_utils:generate_fragment(6),
    P = bondy_realm:create(#{
        uri => ProtoUri,
        is_prototype => true,
        allow_connections => false,
        authmethods => [?WAMP_TICKET_AUTH],
        is_sso_realm => false,
        security_enabled => false,
        sso_realm_uri => SSOUri
    }),

    Uri = bondy_utils:generate_fragment(6),
    R = bondy_realm:create(#{
        uri => Uri,
        prototype_uri => ProtoUri
    }),


    ?assertEqual(false, bondy_realm:allow_connections(P)),
    ?assertEqual(false, bondy_realm:allow_connections(R)),
    ?assertEqual(false, bondy_realm:is_value_inherited(P, allow_connections)),
    ?assertEqual(true, bondy_realm:is_value_inherited(R, allow_connections)),

    ?assertEqual([?WAMP_TICKET_AUTH], bondy_realm:authmethods(P)),
    ?assertEqual([?WAMP_TICKET_AUTH], bondy_realm:authmethods(R)),
    ?assertEqual(false, bondy_realm:is_value_inherited(P, authmethods)),
    ?assertEqual(true, bondy_realm:is_value_inherited(R, authmethods)),

    ?assertEqual(SSOUri, bondy_realm:sso_realm_uri(P)),
    ?assertEqual(SSOUri, bondy_realm:sso_realm_uri(R)),
    ?assertEqual(false, bondy_realm:is_value_inherited(P, sso_realm_uri)),
    ?assertEqual(true, bondy_realm:is_value_inherited(R, sso_realm_uri)),

    ?assertEqual(false, bondy_realm:is_security_enabled(P)),
    ?assertEqual(false, bondy_realm:is_security_enabled(R)),
    ?assertEqual(false, bondy_realm:is_value_inherited(P, is_security_enabled)),
    ?assertEqual(true, bondy_realm:is_value_inherited(R, is_security_enabled)).


test(_) ->
    Config = #{
        uri => <<"com.test.realm">>,
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
    _ = bondy_realm:create(Config).