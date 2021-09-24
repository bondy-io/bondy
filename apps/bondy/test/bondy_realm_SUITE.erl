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

-define(U1, <<"user_1">>).
-define(U2, <<"user_2">>).
-define(U3, <<"user_3">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        invalid_uri,
        invalid_description,
        prototype_inconsistency_error,
        prototype_badarg,
        prototype_uri_not_found_error,
        sso_inconsistency_error,
        sso_uri_not_found_error

    ].


init_per_suite(Config) ->
    common:start_bondy(),
    Config.

end_per_suite(Config) ->
    % common:stop_bondy(),
    {save_config, Config}.


invalid_uri(_) ->
    ?assertError(
        #{
            code := invalid_value
        },
        bondy_realm:add(#{uri => <<"foo\s">>})
    ).

invalid_description(_) ->
    TooLong = bondy_utils:generate_fragment(513),
    ?assertError(
        #{
            code := invalid_value,
            description := <<"The value for 'description' did not pass the validator. Value is too big (max. is 512 bytes).">>
        },
        bondy_realm:add(#{uri => <<"foo">>, description => TooLong})
    ).


prototype_inconsistency_error(_) ->
    ?assertError(
        {inconsistency_error, [<<"is_prototype">>,<<"prototype_uri">>]},
        bondy_realm:add(#{
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
        bondy_realm:add(#{
            uri => Uri,
            prototype_uri => Uri
        }),
        "uri and prototype_uri cannot be equal"
    ).


prototype_uri_not_found_error(_) ->
    ?assertError(
        {badarg, _},
        bondy_realm:add(#{
            uri => bondy_utils:generate_fragment(6),
            prototype_uri => bondy_utils:generate_fragment(6)
        })
    ).


sso_inconsistency_error(_) ->
    ?assertError(
        {inconsistency_error, [<<"is_sso_realm">>,<<"sso_realm_uri">>]},
        bondy_realm:add(#{
            uri => bondy_utils:generate_fragment(6),
            is_sso_realm => true,
            sso_realm_uri => bondy_utils:generate_fragment(6)
        })
    ).

sso_uri_not_found_error(_) ->
    ?assertError(
        {badarg, _},
        bondy_realm:add(#{
            uri => bondy_utils:generate_fragment(6),
            sso_realm_uri => bondy_utils:generate_fragment(6)
        })
    ).




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
    _ = bondy_realm:add(Config).