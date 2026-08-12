%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rbac_source_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        no_sources,
        multiple_methods,
        match_first_covers_realm_wide_sources,
        match_first_prefers_the_most_specific
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.rbac_source">>,
    ok = add_realm(RealmUri),
    [{realm_uri, RealmUri} | Config].

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.

no_sources(Config) ->
    RealmUri = ?config(realm_uri, Config),
    ?assertEqual(
        [],
        bondy_rbac_source:list(RealmUri)
    ).

multiple_methods(Config) ->
    RealmUri = ?config(realm_uri, Config),

    Source1 = bondy_rbac_source:new_assignment(#{
        usernames => <<"all">>,
        authmethod => ?PASSWORD_AUTH,
        cidr => <<"0.0.0.0/0">>
    }),

    ?assertMatch(
        {ok, _},
        bondy_rbac_source:add(RealmUri, Source1)
    ),

    ?assertMatch(
        [#{authmethod := ?PASSWORD_AUTH}],
        bondy_rbac_source:list(RealmUri)
    ),

    Source2 = bondy_rbac_source:new_assignment(#{
        usernames => <<"all">>,
        authmethod => ?WAMP_CRA_AUTH,
        cidr => <<"0.0.0.0/0">>
    }),

    ?assertMatch(
        {ok, _},
        bondy_rbac_source:add(RealmUri, Source2)
    ),

    ?assertMatch(
        [_, _],
        bondy_rbac_source:list(RealmUri)
    ).

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
        ]
    },
    _ = bondy_realm:create(Config),
    ok.

match_first_covers_realm_wide_sources(_) ->
    %% A source assigned to `all` governs every user of the realm. Resolving one
    %% user must therefore consider it, exactly as `match/3` does — a resolver
    %% that only looks at the user's own sources reports no rule for a realm
    %% whose rules are all realm-wide.
    Uri = <<"com.example.source.match_first.all">>,
    ok = new_realm(Uri),
    {ok, _} = bondy_rbac_source:add(Uri, #{
        <<"usernames">> => <<"all">>,
        <<"authmethod">> => ?PASSWORD_AUTH,
        <<"cidr">> => <<"0.0.0.0/0">>,
        <<"meta">> => #{}
    }),
    ok = add_user(Uri, <<"usr1">>),

    ?assertMatch(
        [#{authmethod := ?PASSWORD_AUTH}],
        bondy_rbac_source:match(Uri, <<"usr1">>, {127, 0, 0, 1})
    ),
    ?assertMatch(
        {ok, #{authmethod := ?PASSWORD_AUTH}},
        bondy_rbac_source:match_first(Uri, <<"usr1">>, {127, 0, 0, 1})
    ).

match_first_prefers_the_most_specific(_) ->
    %% Where several sources match, the resolver picks the one `match/3` ranks
    %% first: the user's own over the realm-wide, and the narrowest CIDR within
    %% that. Returning any other match would offer a method the operator scoped
    %% away.
    Uri = <<"com.example.source.match_first.specific">>,
    ok = new_realm(Uri),
    ok = add_user(Uri, <<"usr1">>),
    {ok, _} = bondy_rbac_source:add(Uri, #{
        <<"usernames">> => <<"all">>,
        <<"authmethod">> => ?TRUST_AUTH,
        <<"cidr">> => <<"0.0.0.0/0">>,
        <<"meta">> => #{}
    }),
    {ok, _} = bondy_rbac_source:add(Uri, #{
        <<"usernames">> => [<<"usr1">>],
        <<"authmethod">> => ?PASSWORD_AUTH,
        <<"cidr">> => <<"127.0.0.0/8">>,
        <<"meta">> => #{}
    }),

    [First | _] = bondy_rbac_source:match(Uri, <<"usr1">>, {127, 0, 0, 1}),
    {ok, Chosen} = bondy_rbac_source:match_first(
        Uri, <<"usr1">>, {127, 0, 0, 1}
    ),
    ?assertEqual(?PASSWORD_AUTH, bondy_rbac_source:authmethod(Chosen)),
    ?assertEqual(
        bondy_rbac_source:authmethod(First),
        bondy_rbac_source:authmethod(Chosen),
        "match_first must agree with the head of match/3"
    ).

new_realm(Uri) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?PASSWORD_AUTH, ?TRUST_AUTH]
    }),
    ok.

add_user(Uri, Username) ->
    User = bondy_rbac_user:new(#{
        username => Username,
        password => <<"aWe11KeptSecret">>
    }),
    {ok, _} = bondy_rbac_user:add(Uri, User),
    ok.
