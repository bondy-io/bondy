%% =============================================================================
%%  bondy_password_SUITE.erl -
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

-module(bondy_password_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(P1, <<"aWe11KeptSecret">>).
-define(P2, <<"An0therWe11KeptSecret">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        new_default,
        new_cra_too_low_iterations,
        new_cra_too_high_iterations,
        new_cra_invalid_kdf,
        new_cra_options,

        new_scram_too_low_iterations,
        new_scram_too_high_iterations,
        new_scram_options_pbkdf2,
        new_scram_options_argon2id13
    ].


init_per_suite(Config) ->
    common:start_bondy(),
    [{realm_uri, <<"com.myrealm">>}|Config].

end_per_suite(Config) ->
    % common:stop_bondy(),
    {save_config, Config}.


new_default(_) ->
    Protocol = bondy_config:get([security, password, protocol]),

    A = bondy_password:new(?P1),

    ?assertMatch(#{protocol := Protocol}, A),
    ?assertEqual(true, bondy_password:verify_string(?P1, A)),
    ?assertEqual(false, bondy_password:verify_string(<<"foo">>, A)),

    B = bondy_password:new(fun() -> ?P1 end),

    ?assertMatch(#{protocol := Protocol}, B),
    ?assertEqual(true, bondy_password:verify_string(?P1, B)),
    ?assertEqual(false, bondy_password:verify_string(<<"foo">>, B)),

    ok.



new_cra_too_low_iterations(_) ->

    ?assertError(
        {invalid_argument, iterations},
        bondy_password:new(?P1, #{
            protocol => cra,
            params => #{kdf => pbkdf2, iterations => 1000}
        })
    ).


new_cra_too_high_iterations(_) ->
    ?assertError(
        {invalid_argument, iterations},
        bondy_password:new(?P1, #{
            protocol => cra,
            params => #{kdf => pbkdf2, iterations => 66000}
        })
    ).


new_cra_invalid_kdf(_) ->

    ?assertError(
        {invalid_argument, kdf},
        bondy_password:new(?P1, #{
            protocol => cra,
            params => #{kdf => argon2id13}
        })
    ).


new_cra_options(_) ->

    Opts = #{
        protocol => cra,
        params => #{kdf => pbkdf2, iterations => 5000}
    },


    A = bondy_password:new(?P1, Opts),

    ?assertMatch(
        #{protocol := cra, params := #{kdf := pbkdf2, iterations := 5000}},
        A
    ),
    ?assertEqual(true, bondy_password:verify_string(?P1, A)),
    ?assertEqual(false, bondy_password:verify_string(<<"foo">>, A)),

    B = bondy_password:new(fun() -> ?P1 end, Opts),

    ?assertMatch(
        #{protocol := cra, params := #{kdf := pbkdf2, iterations := 5000}},
        B
    ),
    ?assertEqual(true, bondy_password:verify_string(?P1, B)),
    ?assertEqual(false, bondy_password:verify_string(<<"foo">>, B)),

    ok.


new_scram_too_low_iterations(_) ->

    ?assertError(
        {invalid_argument, iterations},
        bondy_password:new(?P1, #{
            protocol => scram,
            params => #{kdf => pbkdf2, iterations => 1000}
        })
    ),

    ?assertError(
        {invalid_argument, iterations},
        bondy_password:new(?P1, #{
            protocol => scram,
            params => #{kdf => argon2id13, iterations => 0}
        })
    ).


new_scram_too_high_iterations(_) ->

    ?assertError(
        {invalid_argument, iterations},
        bondy_password:new(?P1, #{
            protocol => scram,
            params => #{kdf => pbkdf2, iterations => 66000}
        })
    ),

    ?assertError(
        {invalid_argument, iterations},
        bondy_password:new(?P1, #{
            protocol => scram,
            params => #{kdf => argon2id13, iterations => 4294967295 + 1}
        })
    ).


new_scram_options_pbkdf2(_) ->

    Opts = #{
        protocol => scram,
        params => #{kdf => pbkdf2, iterations => 5000}
    },


    A = bondy_password:new(?P1, Opts),

    ?assertMatch(
        #{protocol := scram, params := #{kdf := pbkdf2, iterations := 5000}},
        A
    ),
    ?assertEqual(true, bondy_password:verify_string(?P1, A)),
    ?assertEqual(false, bondy_password:verify_string(<<"foo">>, A)),

    B = bondy_password:new(fun() -> ?P1 end, Opts),

    ?assertMatch(
        #{protocol := scram, params := #{kdf := pbkdf2, iterations := 5000}},
        B
    ),
    ?assertEqual(true, bondy_password:verify_string(?P1, B)),
    ?assertEqual(false, bondy_password:verify_string(<<"foo">>, B)),

    ok.


new_scram_options_argon2id13(_) ->

    Opts = #{
        protocol => scram,
        params => #{kdf => argon2id13}
    },


    A = bondy_password:new(?P1, Opts),

    ?assertMatch(
        #{protocol := scram, params := #{kdf := argon2id13}},
        A
    ),
    ?assertEqual(true, bondy_password:verify_string(?P1, A)),
    ?assertEqual(false, bondy_password:verify_string(<<"foo">>, A)),

    B = bondy_password:new(fun() -> ?P1 end, Opts),

    ?assertMatch(
        #{protocol := scram, params := #{kdf := argon2id13}},
        B
    ),
    ?assertEqual(true, bondy_password:verify_string(?P1, B)),
    ?assertEqual(false, bondy_password:verify_string(<<"foo">>, B)),

    ok.
