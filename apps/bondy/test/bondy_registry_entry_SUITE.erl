%% =============================================================================
%%  bondy_realm_SUITE.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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

-module(bondy_registry_entry_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_plum_db.hrl").
-include("bondy_security.hrl").


-compile([nowarn_export_all, export_all]).

all() ->
    [
        mg_comparator,
        composite_comparator
    ].


init_per_suite(Config) ->

    bondy_ct:start_bondy(),
    Config.


end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.



mg_comparator(_) ->
    %% All using ?INVOKE_SINGLE by default
    L = [
        {<<"a1....">>, ?WILDCARD_MATCH},
        {<<"a1....e5">>, ?WILDCARD_MATCH},
        {<<"a1...d4.e5">>, ?WILDCARD_MATCH},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH},
        {<<"a1.b2..d4.e5">>, ?WILDCARD_MATCH},
        {<<"a1.b2..d4.">>, ?WILDCARD_MATCH},
        {<<"a1.b2.c3">>, ?PREFIX_MATCH},
        {<<"a1.b2.c3.d4">>, ?PREFIX_MATCH},
        {<<"a1.b2.c3.d4.e55">>, ?EXACT_MATCH},
        {<<"a1.b2.c33..e5">>, ?WILDCARD_MATCH}
    ],

    Expected = [
        {<<"a1.b2.c3.d4.e55">>, ?EXACT_MATCH},
        {<<"a1.b2.c3.d4">>, ?PREFIX_MATCH},
        {<<"a1.b2.c3">>, ?PREFIX_MATCH},
        {<<"a1.b2.c33..e5">>, ?WILDCARD_MATCH},
        {<<"a1.b2..d4.e5">>, ?WILDCARD_MATCH},
        {<<"a1.b2..d4.">>, ?WILDCARD_MATCH},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH},
        {<<"a1...d4.e5">>, ?WILDCARD_MATCH},
        {<<"a1....e5">>, ?WILDCARD_MATCH},
        {<<"a1....">>, ?WILDCARD_MATCH}
    ],

    Ref = bondy_ref:new(internal, self()),
    Entries = [
        bondy_registry_entry:new(
            registration, <<"com.foo">>, Ref, Uri, #{match => P}
        )
        || {Uri, P} <- L
    ],

    Fun = bondy_registry_entry:mg_comparator(),

    ?assertEqual(
        Expected,
        [
            {bondy_registry_entry:uri(E), bondy_registry_entry:match_policy(E)}
            || E <- lists:sort(Fun, Entries)
        ]
    ),
    ok.




composite_comparator(_) ->
    L = [
        {<<"a1....">>, ?WILDCARD_MATCH, ?INVOKE_SINGLE},
        {<<"a1....">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1....e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1....e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1....e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1...d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1...d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1...d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2..d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2..d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2..d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2..d4.">>, ?WILDCARD_MATCH, ?INVOKE_SINGLE},
        {<<"a1.b2.c3">>, ?PREFIX_MATCH, ?INVOKE_SINGLE},
        {<<"a1.b2.c3.d4">>, ?PREFIX_MATCH, ?INVOKE_SINGLE},
        {<<"a1.b2.c3.d4.e55">>, ?EXACT_MATCH, ?INVOKE_SINGLE},
        {<<"a1.b2.c33..e5">>, ?WILDCARD_MATCH, ?INVOKE_SINGLE}
    ],

    Expected = [
        {<<"a1.b2.c3.d4.e55">>, ?EXACT_MATCH, ?INVOKE_SINGLE},
        {<<"a1.b2.c3.d4">>, ?PREFIX_MATCH, ?INVOKE_SINGLE},
        {<<"a1.b2.c3">>, ? PREFIX_MATCH, ?INVOKE_SINGLE},
        {<<"a1.b2.c33..e5">>, ?WILDCARD_MATCH, ?INVOKE_SINGLE},
        {<<"a1.b2..d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2..d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2..d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2..d4.">>, ?WILDCARD_MATCH, ?INVOKE_SINGLE},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH, ?INVOKE_FIRST},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1.b2...e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1...d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1...d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1...d4.e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1....e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1....e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1....e5">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN},
        {<<"a1....">>, ?WILDCARD_MATCH, ?INVOKE_SINGLE},
        {<<"a1....">>, ?WILDCARD_MATCH, ?INVOKE_ROUND_ROBIN}
    ],

    Ref = bondy_ref:new(internal, self()),
    Entries = [
        bondy_registry_entry:new(
            registration, <<"com.foo">>, Ref, Uri, #{match => P, invoke => I}
        )
        || {Uri, P, I} <- L
    ],

    Fun = bondy_registry_entry:mg_comparator(),

    ?assertEqual(
        Expected,
        [
            {
                bondy_registry_entry:uri(E),
                bondy_registry_entry:match_policy(E),
                bondy_registry_entry:invocation_policy(E)
            }
            || E <- lists:sort(Fun, Entries)
        ]
    ),
    ok.


