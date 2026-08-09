%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_entry_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        mg_comparator,
        composite_comparator,
        key_pattern_sessionless
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
        {<<"a1.b2.c3">>, ?PREFIX_MATCH, ?INVOKE_SINGLE},
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

%% A ref without a session id (internal subscribers/callbacks) stores its
%% entries under `session_id = undefined', so `undefined' must be a valid
%% exact-match value for key_pattern/3 rather than one its guard rejects.
key_pattern_sessionless(_) ->
    RealmUri = <<"com.example.test.registry_entry">>,
    Ref = bondy_ref:new(internal, self()),
    ?assertEqual(undefined, bondy_ref:session_id(Ref)),

    Entry = bondy_registry_entry:new(
        subscription, RealmUri, Ref, <<"com.example.topic">>, #{}
    ),
    Key = bondy_registry_entry:key(Entry),
    ?assertEqual(undefined, bondy_registry_entry:session_id(Key)),

    Pattern = bondy_registry_entry:key_pattern(RealmUri, undefined, '_'),
    ?assertEqual(undefined, bondy_registry_entry:session_id(Pattern)),
    ?assertEqual(RealmUri, bondy_registry_entry:realm_uri(Pattern)),

    %% Wildcard and exact-binary forms still accepted.
    _ = bondy_registry_entry:key_pattern(RealmUri, '_', '_'),
    SessionId = bondy_session_id:new(),
    _ = bondy_registry_entry:key_pattern(RealmUri, SessionId, '_'),
    ok.
