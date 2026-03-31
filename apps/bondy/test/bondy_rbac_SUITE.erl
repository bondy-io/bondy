%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
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
        %% Original tests
        test_1,
        test_grants,
        group_topsort_error,
        group_topsort,
        prototype_1,

        %% New coverage tests
        is_reserved_name_atoms,
        is_reserved_name_binaries,
        is_reserved_name_non_reserved,
        normalise_name_casefold,
        request_v1_format,
        request_v2_format,
        grant_revoke_lifecycle,
        partial_revoke,
        grant_deduplication,
        grant_unknown_role_error,
        revoke_user_grants,
        revoke_group_grants,
        exact_match_grant,
        wildcard_match_grant,
        mixed_match_strategies,
        user_specific_grants,
        anonymous_context_authorization,
        anonymous_permission_denied_message,
        context_refresh_after_epoch,
        explicit_groups_oidc,
        nested_group_inheritance_deep,
        explicit_groups_deep_inheritance,
        externalize_grant_formats,
        group_deletion_cascades_grants,
        grant_to_any_resource,
        security_disabled_allows_all
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    RealmUri = <<"com.example.test.rbac">>,
    ok = add_realm(RealmUri),

    [{realm_uri, RealmUri}| Config].

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.


add_realm(RealmUri) ->
    add_realm(RealmUri, undefined).


add_realm(RealmUri, Prototype) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?TRUST_AUTH
        ],
        prototype_uri => Prototype,
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
    _ = bondy_realm:create(Config),
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
    % dbg:tracer(), dbg:p(all,c),
    % dbg:tpl(bondy_rbac, 'acc_grants', x),
    % dbg:tpl(bondy_rbac, 'role_groups', x),
    % dbg:tpl(bondy_rbac, 'acc_grants_find', x),
    U1Ctxt = #{
        realm_uri => RealmUri,
        security_enabled => true,
        authid => ?U1,
        session => bondy_session:new(
            RealmUri, SessionOpts#{authid => ?U1, peer => Peer}
        )
    },
    U2Ctxt = #{
        realm_uri => RealmUri,
        security_enabled => true,
        authid => ?U2,
        session => bondy_session:new(
            RealmUri, SessionOpts#{authid => ?U2, peer => Peer}
        )
    },
    U3Ctxt = #{
        realm_uri => RealmUri,
        security_enabled => true,
        authid => ?U3,
        session => bondy_session:new(
            RealmUri, SessionOpts#{authid => ?U3, peer => Peer}
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
    _ = bondy_realm:create(Data),
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

    {_, L} = lists:foldl(
        fun(X, {Cnt, Acc}) ->
            NewCnt = Cnt + 1,
            {NewCnt, [{maps:get(name, X), NewCnt}|Acc]} end,
        {1, []},
        bondy_rbac_group:topsort(Groups)
    ),
    Map = maps:from_list(L),

    ?assert(
        maps:get(<<"a">>, Map) < maps:get(<<"b">>, Map)
    ),
    ?assert(
        maps:get(<<"b">>, Map) < maps:get(<<"c">>, Map)
    ),
    ?assert(
        maps:get(<<"d">>, Map) < maps:get(<<"c">>, Map)
    ).


prototype_1(_) ->

    Config = #{
        uri => <<"prototype_1.proto">>,
        authmethods => [
            ?TRUST_AUTH
        ],
        is_prototype => true,
        prototype_uri => undefined,
        security_enabled => true,
        groups => [
            #{
                name => <<"prototype_group_a">>,
                groups => [<<"prototype_group_b">>, <<"prototype_group_c">>]
            },
            #{
                name => <<"prototype_group_b">>
            },
            #{
                name => <<"prototype_group_c">>
            }
        ],
        grants => [
            #{
                permissions => [
                    <<"test.permission">>
                ],
                uri => <<"bar">>,
                match => <<"exact">>,
                roles => [<<"prototype_group_b">>]
            },
            #{
                permissions => [
                    <<"test.permission">>
                ],
                uri => <<"foo">>,
                match => <<"exact">>,
                roles => <<"all">>
            }
        ]
    },
    %% We create a proto realm
    _ = bondy_realm:create(Config),

    %% We create a new realm with the proto
    Uri = <<"prototype_1.child">>,
    _ = add_realm(Uri, <<"prototype_1.proto">>),

    %% We get a fresh context
    C1 = bondy_rbac:get_context(Uri, ?U1),
    ?assertMatch(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"any_procedure">>, C1),
        "Allowed by child realm"
    ),
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"test.permission">>, <<"foo">>, C1),
        "Allowed by proto. Grants to 'all' are merged between proto and child"
    ),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"test.permission">>, <<"bar">>, C1),
        "U1 should not yet have permission"
    ),

    %% We grant permission through group membership
    ?assertMatch(
        ok,
        bondy_rbac_user:add_group(Uri, ?U1, <<"prototype_group_a">>)
    ),

    %% We get a fresh context
    C2 = bondy_rbac:get_context(Uri, ?U1),

    ?assertMatch(
        ok,
        bondy_rbac:authorize(<<"test.permission">>, <<"bar">>, C2),
        "U1 should now have permission via prototypical inheritance"
    ),

    %% We override prototype_group_b by creating a group of the same name on
    %% the child realm.
    _ = bondy_rbac_group:add(
        Uri, bondy_rbac_group:new(#{name => <<"prototype_group_b">>})
    ),

    %% We get a fresh context
    C3 = bondy_rbac:get_context(Uri, ?U1),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"test.permission">>, <<"bar">>, C3),
        "U1 should no longer have permission via prototypical inheritance, because we have overridden prototype_group_b"
    ).



%% =============================================================================
%% is_reserved_name / normalise_name
%% =============================================================================



is_reserved_name_atoms(_) ->
    ?assert(bondy_rbac:is_reserved_name(all)),
    ?assert(bondy_rbac:is_reserved_name(anonymous)),
    ?assert(bondy_rbac:is_reserved_name(any)),
    ?assert(bondy_rbac:is_reserved_name(on)),
    ?assert(bondy_rbac:is_reserved_name(to)),
    ?assert(bondy_rbac:is_reserved_name(from)),
    ?assertNot(bondy_rbac:is_reserved_name(foobar)),
    ?assertNot(bondy_rbac:is_reserved_name(admin)).


is_reserved_name_binaries(_) ->
    ?assert(bondy_rbac:is_reserved_name(<<"all">>)),
    ?assert(bondy_rbac:is_reserved_name(<<"anonymous">>)),
    ?assert(bondy_rbac:is_reserved_name(<<"any">>)),
    ?assert(bondy_rbac:is_reserved_name(<<"on">>)),
    ?assert(bondy_rbac:is_reserved_name(<<"to">>)),
    ?assert(bondy_rbac:is_reserved_name(<<"from">>)),
    %% Non-existing atoms as binaries should return false
    ?assertNot(bondy_rbac:is_reserved_name(<<"not_a_reserved_name_xyz123">>)).


is_reserved_name_non_reserved(_) ->
    ?assertNot(bondy_rbac:is_reserved_name(<<"admin">>)),
    ?assertNot(bondy_rbac:is_reserved_name(<<"my_group">>)),
    ?assertNot(bondy_rbac:is_reserved_name(<<"com.example.service">>)),
    %% Non-binary, non-atom should error
    ?assertError(invalid_name, bondy_rbac:is_reserved_name(123)).


normalise_name_casefold(_) ->
    ?assertEqual(<<"hello">>, bondy_rbac:normalise_name(<<"Hello">>)),
    ?assertEqual(<<"hello">>, bondy_rbac:normalise_name(<<"HELLO">>)),
    %% Already lowercased
    ?assertEqual(<<"hello">>, bondy_rbac:normalise_name(<<"hello">>)),
    %% Idempotent
    Name = <<"MiXeD_CaSe">>,
    N1 = bondy_rbac:normalise_name(Name),
    N2 = bondy_rbac:normalise_name(N1),
    ?assertEqual(N1, N2).



%% =============================================================================
%% REQUEST VALIDATION
%% =============================================================================



request_v1_format(_) ->
    %% v1 format uses top-level uri/match (single resource)
    Data = #{
        <<"permissions">> => [<<"wamp.call">>],
        <<"uri">> => <<"com.example.">>,
        <<"match">> => <<"prefix">>,
        <<"roles">> => [<<"my_group">>]
    },
    Req = bondy_rbac:request(Data),
    ?assertMatch(#{type := request}, Req),
    ?assertEqual([<<"wamp.call">>], maps:get(permissions, Req)),
    ?assertEqual([<<"my_group">>], maps:get(roles, Req)),
    ?assertMatch([{<<"com.example.">>, <<"prefix">>}], maps:get(resources, Req)).


request_v2_format(_) ->
    %% v2 format uses resources list
    Data = #{
        <<"permissions">> => [<<"wamp.call">>, <<"wamp.subscribe">>],
        <<"resources">> => [
            #{<<"uri">> => <<"com.foo.">>, <<"match">> => <<"prefix">>},
            #{<<"uri">> => <<"com.bar.baz">>, <<"match">> => <<"exact">>}
        ],
        <<"roles">> => [<<"admin">>]
    },
    Req = bondy_rbac:request(Data),
    ?assertMatch(#{type := request}, Req),
    ?assertEqual(
        [<<"wamp.call">>, <<"wamp.subscribe">>],
        maps:get(permissions, Req)
    ),
    Resources = maps:get(resources, Req),
    ?assertEqual(2, length(Resources)),
    ?assert(lists:member({<<"com.foo.">>, <<"prefix">>}, Resources)),
    ?assert(lists:member({<<"com.bar.baz">>, <<"exact">>}, Resources)).



%% =============================================================================
%% GRANT / REVOKE LIFECYCLE
%% =============================================================================



grant_revoke_lifecycle(_) ->
    Uri = <<"com.test.grant_revoke_lifecycle">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"testers">>}],
        users => [#{username => <<"tester_1">>, groups => [<<"testers">>]}]
    }),

    %% Grant call permission to testers group on a prefix resource
    ok = bondy_rbac:grant(Uri, #{
        <<"permissions">> => [<<"wamp.call">>],
        <<"uri">> => <<"com.api.">>,
        <<"match">> => <<"prefix">>,
        <<"roles">> => [<<"testers">>]
    }),

    C1 = bondy_rbac:get_context(Uri, <<"tester_1">>),
    ?assertEqual(ok, bondy_rbac:authorize(<<"wamp.call">>, <<"com.api.foo">>, C1)),

    %% Revoke it
    ok = bondy_rbac:revoke(Uri, #{
        <<"permissions">> => [<<"wamp.call">>],
        <<"uri">> => <<"com.api.">>,
        <<"match">> => <<"prefix">>,
        <<"roles">> => [<<"testers">>]
    }),

    C2 = bondy_rbac:get_context(Uri, <<"tester_1">>),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.api.foo">>, C2)
    ).


partial_revoke(_) ->
    Uri = <<"com.test.partial_revoke">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"devs">>}],
        users => [#{username => <<"dev_1">>, groups => [<<"devs">>]}]
    }),

    %% Grant multiple permissions
    ok = bondy_rbac:grant(Uri, #{
        <<"permissions">> => [<<"wamp.call">>, <<"wamp.register">>],
        <<"uri">> => <<"com.svc.">>,
        <<"match">> => <<"prefix">>,
        <<"roles">> => [<<"devs">>]
    }),

    C1 = bondy_rbac:get_context(Uri, <<"dev_1">>),
    ?assertEqual(ok, bondy_rbac:authorize(<<"wamp.call">>, <<"com.svc.a">>, C1)),
    ?assertEqual(ok, bondy_rbac:authorize(<<"wamp.register">>, <<"com.svc.a">>, C1)),

    %% Revoke only wamp.register
    ok = bondy_rbac:revoke(Uri, #{
        <<"permissions">> => [<<"wamp.register">>],
        <<"uri">> => <<"com.svc.">>,
        <<"match">> => <<"prefix">>,
        <<"roles">> => [<<"devs">>]
    }),

    C2 = bondy_rbac:get_context(Uri, <<"dev_1">>),
    ?assertEqual(ok, bondy_rbac:authorize(<<"wamp.call">>, <<"com.svc.a">>, C2)),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.svc.a">>, C2)
    ).


grant_deduplication(_) ->
    Uri = <<"com.test.dedup">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"ops">>}],
        users => [#{username => <<"op_1">>, groups => [<<"ops">>]}]
    }),

    Grant = #{
        <<"permissions">> => [<<"wamp.call">>],
        <<"uri">> => <<"com.dup.">>,
        <<"match">> => <<"prefix">>,
        <<"roles">> => [<<"ops">>]
    },

    %% Grant same thing twice
    ok = bondy_rbac:grant(Uri, Grant),
    ok = bondy_rbac:grant(Uri, Grant),

    %% Should have no duplicates in accumulated grants
    Grants = bondy_rbac:group_grants(Uri, <<"ops">>),
    PermLists = [Perms || {_, Perms} <- Grants],
    lists:foreach(
        fun(Perms) ->
            ?assertEqual(lists:usort(Perms), Perms)
        end,
        PermLists
    ).


grant_unknown_role_error(_) ->
    Uri = <<"com.test.unknown_role">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH]
    }),

    Result = bondy_rbac:grant(Uri, #{
        <<"permissions">> => [<<"wamp.call">>],
        <<"uri">> => <<"com.x.">>,
        <<"match">> => <<"prefix">>,
        <<"roles">> => [<<"nonexistent_role">>]
    }),
    ?assertMatch({error, {unknown_roles, [<<"nonexistent_role">>]}}, Result).


revoke_user_grants(_) ->
    Uri = <<"com.test.revoke_user">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        users => [#{username => <<"revoke_me">>}],
        grants => [
            #{
                permissions => [<<"wamp.call">>, <<"wamp.register">>],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => [<<"revoke_me">>]
            }
        ]
    }),

    C1 = bondy_rbac:get_context(Uri, <<"revoke_me">>),
    ?assertEqual(ok, bondy_rbac:authorize(<<"wamp.call">>, <<"anything">>, C1)),

    %% Revoke all grants for this user
    ok = bondy_rbac:revoke_user(Uri, <<"revoke_me">>),

    C2 = bondy_rbac:get_context(Uri, <<"revoke_me">>),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.call">>, <<"anything">>, C2)
    ).


revoke_group_grants(_) ->
    Uri = <<"com.test.revoke_group">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"doomed">>}],
        users => [#{username => <<"member_1">>, groups => [<<"doomed">>]}],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => [<<"doomed">>]
            }
        ]
    }),

    C1 = bondy_rbac:get_context(Uri, <<"member_1">>),
    ?assertEqual(
        ok, bondy_rbac:authorize(<<"wamp.call">>, <<"any_uri">>, C1)
    ),

    ok = bondy_rbac:revoke_group(Uri, <<"doomed">>),

    C2 = bondy_rbac:get_context(Uri, <<"member_1">>),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.call">>, <<"any_uri">>, C2)
    ).



%% =============================================================================
%% MATCH STRATEGIES
%% =============================================================================



exact_match_grant(_) ->
    Uri = <<"com.test.exact_match">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"exact_g">>}],
        users => [#{username => <<"exact_u">>, groups => [<<"exact_g">>]}],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"com.my.procedure">>,
                match => <<"exact">>,
                roles => [<<"exact_g">>]
            }
        ]
    }),

    C = bondy_rbac:get_context(Uri, <<"exact_u">>),

    %% Exact match should work
    ?assertEqual(
        ok, bondy_rbac:authorize(<<"wamp.call">>, <<"com.my.procedure">>, C)
    ),

    %% Different URI should not match
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.my.procedure.sub">>, C)
    ),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.my.other">>, C)
    ).


wildcard_match_grant(_) ->
    Uri = <<"com.test.wildcard_match">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"wild_g">>}],
        users => [#{username => <<"wild_u">>, groups => [<<"wild_g">>]}],
        grants => [
            #{
                permissions => [<<"wamp.subscribe">>],
                resources => [
                    #{
                        uri => <<"com..events">>,
                        match => <<"wildcard">>
                    }
                ],
                roles => [<<"wild_g">>]
            }
        ]
    }),

    C = bondy_rbac:get_context(Uri, <<"wild_u">>),

    %% Wildcard should match any single component in the gap
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.subscribe">>, <<"com.foo.events">>, C)
    ),
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.subscribe">>, <<"com.bar.events">>, C)
    ),

    %% Should not match when the fixed parts differ
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.subscribe">>, <<"com.foo.other">>, C)
    ).


mixed_match_strategies(_) ->
    Uri = <<"com.test.mixed_match">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"mixed_g">>}],
        users => [#{username => <<"mixed_u">>, groups => [<<"mixed_g">>]}],
        grants => [
            %% Exact match for one specific procedure
            #{
                permissions => [<<"wamp.register">>],
                resources => [
                    #{uri => <<"com.api.health">>, match => <<"exact">>}
                ],
                roles => [<<"mixed_g">>]
            },
            %% Prefix match for a namespace
            #{
                permissions => [<<"wamp.call">>],
                resources => [
                    #{uri => <<"com.api.">>, match => <<"prefix">>}
                ],
                roles => [<<"mixed_g">>]
            }
        ]
    }),

    C = bondy_rbac:get_context(Uri, <<"mixed_u">>),

    %% wamp.register only on exact URI
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.api.health">>, C)
    ),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.api.other">>, C)
    ),

    %% wamp.call on any URI with the prefix
    ?assertEqual(
        ok, bondy_rbac:authorize(<<"wamp.call">>, <<"com.api.health">>, C)
    ),
    ?assertEqual(
        ok, bondy_rbac:authorize(<<"wamp.call">>, <<"com.api.other">>, C)
    ).



%% =============================================================================
%% USER-SPECIFIC GRANTS
%% =============================================================================



user_specific_grants(_) ->
    Uri = <<"com.test.user_grants">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"base_g">>}],
        users => [
            #{username => <<"direct_u">>, groups => [<<"base_g">>]},
            #{username => <<"group_only_u">>, groups => [<<"base_g">>]}
        ],
        grants => [
            %% Group grant
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"com.shared.">>,
                match => <<"prefix">>,
                roles => [<<"base_g">>]
            },
            %% Direct user grant
            #{
                permissions => [<<"wamp.register">>],
                uri => <<"com.special.">>,
                match => <<"prefix">>,
                roles => [<<"direct_u">>]
            }
        ]
    }),

    CDirect = bondy_rbac:get_context(Uri, <<"direct_u">>),
    CGroupOnly = bondy_rbac:get_context(Uri, <<"group_only_u">>),

    %% Both users have group grant
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.shared.x">>, CDirect)
    ),
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.shared.x">>, CGroupOnly)
    ),

    %% Only direct_u has the direct user grant
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.special.x">>, CDirect)
    ),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(
            <<"wamp.register">>, <<"com.special.x">>, CGroupOnly
        )
    ).



%% =============================================================================
%% ANONYMOUS AUTHORIZATION
%% =============================================================================



anonymous_context_authorization(_) ->
    Uri = <<"com.test.anon_auth">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH, ?WAMP_ANON_AUTH],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"com.public.">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ],
        sources => [
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    }),

    AnonC = bondy_rbac:get_anonymous_context(Uri, <<"anon_user">>),

    %% Anonymous user should have 'all' group grants
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.public.data">>, AnonC)
    ),

    %% But not permissions not granted to 'all'
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.public.data">>, AnonC)
    ).


anonymous_permission_denied_message(_) ->
    Uri = <<"com.test.anon_denied_msg">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH]
    }),

    AnonC = bondy_rbac:get_anonymous_context(Uri, <<"anon_test">>),

    %% Verify error message mentions "Anonymous user"
    try
        bondy_rbac:authorize(<<"wamp.register">>, <<"some.uri">>, AnonC),
        ct:fail("Expected not_authorized error")
    catch
        error:{not_authorized, Msg} ->
            ?assert(is_binary(Msg)),
            ?assertNotEqual(nomatch, binary:match(Msg, <<"Anonymous user">>))
    end.



%% =============================================================================
%% CONTEXT REFRESH
%% =============================================================================



context_refresh_after_epoch(_) ->
    Uri = <<"com.test.ctx_refresh">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"refresh_g">>}],
        users => [#{username => <<"refresh_u">>, groups => [<<"refresh_g">>]}]
    }),

    C1 = bondy_rbac:get_context(Uri, <<"refresh_u">>),

    %% Immediately, context should not refresh
    {false, C2} = bondy_rbac:refresh_context(C1),
    ?assertEqual(C1, C2),

    %% Wait for epoch to expire (CTXT_REFRESH_SECS = 1 in TEST mode)
    timer:sleep(1100),

    %% Now it should refresh
    {true, _C3} = bondy_rbac:refresh_context(C1).



%% =============================================================================
%% EXPLICIT GROUPS (OIDC)
%% =============================================================================



explicit_groups_oidc(_) ->
    Uri = <<"com.test.oidc_groups">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [
            #{name => <<"idp_admin">>},
            #{name => <<"idp_reader">>}
        ],
        grants => [
            #{
                permissions => [<<"wamp.register">>],
                uri => <<"com.admin.">>,
                match => <<"prefix">>,
                roles => [<<"idp_admin">>]
            },
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"com.read.">>,
                match => <<"prefix">>,
                roles => [<<"idp_reader">>]
            }
        ]
    }),

    %% User not in local DB, but carries groups from IdP claims
    C = bondy_rbac:get_context(
        Uri, <<"oidc_user@idp.com">>, [<<"idp_admin">>, <<"idp_reader">>]
    ),

    %% Should have grants from both explicit groups
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.admin.x">>, C)
    ),
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.read.y">>, C)
    ),

    %% Should not have grants not assigned to those groups
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.publish">>, <<"com.admin.x">>, C)
    ).



%% =============================================================================
%% NESTED GROUP INHERITANCE
%% =============================================================================



nested_group_inheritance_deep(_) ->
    Uri = <<"com.test.deep_groups">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [
            #{name => <<"level_0">>},
            #{name => <<"level_1">>, groups => [<<"level_0">>]},
            #{name => <<"level_2">>, groups => [<<"level_1">>]},
            #{name => <<"level_3">>, groups => [<<"level_2">>]}
        ],
        users => [
            #{username => <<"deep_user">>, groups => [<<"level_3">>]}
        ],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"com.deep.">>,
                match => <<"prefix">>,
                roles => [<<"level_0">>]
            }
        ]
    }),

    C = bondy_rbac:get_context(Uri, <<"deep_user">>),

    %% User in level_3 should inherit grants from level_0 through the chain
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.deep.resource">>, C)
    ).


%% @doc Tests that `bondy_rbac:get_context/3` (the OIDC explicit-groups path)
%% correctly computes the transitive closure of group inheritance up to 4
%% levels deep, with grants assigned at every level.
%%
%% Group hierarchy:
%%
%%   level_0  (root)         — grants wamp.call   on com.l0.
%%     ^
%%     |  member-of
%%   level_1                 — grants wamp.register on com.l1.
%%     ^
%%     |  member-of
%%   level_2                 — grants wamp.subscribe on com.l2.
%%     ^
%%     |  member-of
%%   level_3  (leaf)         — grants wamp.publish on com.l3.
%%
%% Also tests diamond inheritance:
%%
%%   level_0
%%     ^       ^
%%     |       |
%%   level_1  level_1b
%%     ^       ^
%%     |       |
%%     level_2d
%%
explicit_groups_deep_inheritance(_) ->
    Uri = <<"com.test.oidc_deep_groups">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [
            #{name => <<"level_0">>},
            #{name => <<"level_1">>, groups => [<<"level_0">>]},
            #{name => <<"level_2">>, groups => [<<"level_1">>]},
            #{name => <<"level_3">>, groups => [<<"level_2">>]},
            %% Diamond: level_1b also member of level_0
            #{name => <<"level_1b">>, groups => [<<"level_0">>]},
            %% level_2d member of both level_1 and level_1b
            #{name => <<"level_2d">>, groups => [<<"level_1">>, <<"level_1b">>]}
        ],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"com.l0.">>,
                match => <<"prefix">>,
                roles => [<<"level_0">>]
            },
            #{
                permissions => [<<"wamp.register">>],
                uri => <<"com.l1.">>,
                match => <<"prefix">>,
                roles => [<<"level_1">>]
            },
            #{
                permissions => [<<"wamp.subscribe">>],
                uri => <<"com.l2.">>,
                match => <<"prefix">>,
                roles => [<<"level_2">>]
            },
            #{
                permissions => [<<"wamp.publish">>],
                uri => <<"com.l3.">>,
                match => <<"prefix">>,
                roles => [<<"level_3">>]
            }
        ]
    }),

    %% ---- Linear chain: explicit group = [level_3] ----
    %% Should inherit grants from level_3, level_2, level_1, and level_0
    C3 = bondy_rbac:get_context(
        Uri, <<"oidc_deep@idp.com">>, [<<"level_3">>]
    ),

    %% level_3 own grant
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.publish">>, <<"com.l3.x">>, C3)
    ),
    %% level_2 grant (1 hop up)
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.subscribe">>, <<"com.l2.x">>, C3)
    ),
    %% level_1 grant (2 hops up)
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.l1.x">>, C3)
    ),
    %% level_0 grant (3 hops up — root)
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.l0.x">>, C3)
    ),

    %% Negative: a permission not granted at any level
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.unregister">>, <<"com.l0.x">>, C3)
    ),

    %% ---- Middle of chain: explicit group = [level_2] ----
    %% Should inherit level_2, level_1, level_0 but NOT level_3
    C2 = bondy_rbac:get_context(
        Uri, <<"oidc_mid@idp.com">>, [<<"level_2">>]
    ),

    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.subscribe">>, <<"com.l2.x">>, C2)
    ),
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.l1.x">>, C2)
    ),
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.l0.x">>, C2)
    ),
    %% Must NOT have level_3 grant
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.publish">>, <<"com.l3.x">>, C2)
    ),

    %% ---- Multiple explicit groups: [level_3, level_1] ----
    %% Redundant but should not break (level_1 already visited via level_3)
    CMulti = bondy_rbac:get_context(
        Uri, <<"oidc_multi@idp.com">>, [<<"level_3">>, <<"level_1">>]
    ),

    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.publish">>, <<"com.l3.x">>, CMulti)
    ),
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.l0.x">>, CMulti)
    ),

    %% ---- Diamond: explicit group = [level_2d] ----
    %% level_2d → level_1 → level_0  AND  level_2d → level_1b → level_0
    %% Should get grants from level_1, level_1b, and level_0 (no duplicates)
    CDiamond = bondy_rbac:get_context(
        Uri, <<"oidc_diamond@idp.com">>, [<<"level_2d">>]
    ),

    %% level_1 grant (via level_2d → level_1)
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.l1.x">>, CDiamond)
    ),
    %% level_0 grant (via either path)
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.l0.x">>, CDiamond)
    ),

    ok.



%% =============================================================================
%% EXTERNALIZE GRANTS
%% =============================================================================



externalize_grant_formats(_) ->
    %% Test role + resource format
    Ext1 = bondy_rbac:externalize_grant(
        {{<<"group/admin">>, {<<"com.api.">>, <<"prefix">>}},
         [<<"wamp.call">>]}
    ),
    ?assertMatch(
        #{
            <<"roles">> := [<<"group/admin">>],
            <<"resource">> := #{
                <<"uri">> := <<"com.api.">>,
                <<"match">> := <<"prefix">>
            },
            <<"permissions">> := [<<"wamp.call">>]
        },
        Ext1
    ),

    %% Test exact match resource
    Ext2 = bondy_rbac:externalize_grant(
        {{<<"com.my.proc">>, <<"exact">>}, [<<"wamp.register">>]}
    ),
    ?assertMatch(
        #{
            <<"resource">> := #{
                <<"uri">> := <<"com.my.proc">>,
                <<"match">> := <<"exact">>
            },
            <<"permissions">> := [<<"wamp.register">>]
        },
        Ext2
    ),

    %% Test empty URI (any) resource
    Ext3 = bondy_rbac:externalize_grant(
        {{<<>>, <<"prefix">>}, [<<"wamp.call">>]}
    ),
    ?assertMatch(
        #{
            <<"resource">> := #{
                <<"uri">> := any,
                <<"match">> := <<"prefix">>
            },
            <<"permissions">> := [<<"wamp.call">>]
        },
        Ext3
    ),

    %% Test the bare 'any' resource
    Ext4 = bondy_rbac:externalize_grant({any, [<<"wamp.call">>]}),
    ?assertMatch(
        #{
            <<"resource">> := #{
                <<"uri">> := <<>>,
                <<"match">> := <<"prefix">>
            },
            <<"permissions">> := [<<"wamp.call">>]
        },
        Ext4
    ).



%% =============================================================================
%% GROUP DELETION CASCADES GRANTS
%% =============================================================================



group_deletion_cascades_grants(_) ->
    Uri = <<"com.test.group_delete_cascade">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"ephemeral">>}],
        users => [#{username => <<"cascade_u">>, groups => [<<"ephemeral">>]}],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"com.eph.">>,
                match => <<"prefix">>,
                roles => [<<"ephemeral">>]
            }
        ]
    }),

    C1 = bondy_rbac:get_context(Uri, <<"cascade_u">>),
    ?assertEqual(
        ok, bondy_rbac:authorize(<<"wamp.call">>, <<"com.eph.x">>, C1)
    ),

    %% Delete the group — should cascade-revoke its grants
    ok = bondy_rbac_group:remove(Uri, <<"ephemeral">>),

    C2 = bondy_rbac:get_context(Uri, <<"cascade_u">>),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.eph.x">>, C2)
    ).



%% =============================================================================
%% GRANT TO 'any' RESOURCE
%% =============================================================================



grant_to_any_resource(_) ->
    Uri = <<"com.test.any_resource">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"super">>}],
        users => [#{username => <<"super_u">>, groups => [<<"super">>]}],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                resources => [#{uri => any}],
                roles => [<<"super">>]
            }
        ]
    }),

    C = bondy_rbac:get_context(Uri, <<"super_u">>),

    %% Grant on 'any' resource allows authorization when resource is the
    %% atom 'any' (used internally by Bondy for blanket permission checks)
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, any, C)
    ),

    %% For matching arbitrary binary URIs, use empty-prefix grant instead
    Uri2 = <<"com.test.any_resource2">>,
    _ = bondy_realm:create(#{
        uri => Uri2,
        security_enabled => true,
        authmethods => [?TRUST_AUTH],
        groups => [#{name => <<"super2">>}],
        users => [#{username => <<"super_u2">>, groups => [<<"super2">>]}],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                resources => [#{uri => <<"">>, match => <<"prefix">>}],
                roles => [<<"super2">>]
            }
        ]
    }),

    C2 = bondy_rbac:get_context(Uri2, <<"super_u2">>),

    %% Empty-prefix matches any binary URI
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"com.anything.here">>, C2)
    ),
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.call">>, <<"totally.different">>, C2)
    ).



%% =============================================================================
%% SECURITY DISABLED
%% =============================================================================



security_disabled_allows_all(_) ->
    Uri = <<"com.test.sec_disabled">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => false,
        authmethods => [?TRUST_AUTH]
    }),

    Peer = {{127, 0, 0, 1}, 9999},
    SessionOpts = #{
        is_anonymous => false,
        security_enabled => false,
        roles => #{caller => #{features => #{}}},
        authid => <<"anyone">>,
        peer => Peer
    },
    Ctxt = #{
        realm_uri => Uri,
        security_enabled => false,
        authid => <<"anyone">>,
        session => bondy_session:new(Uri, SessionOpts)
    },

    %% When security is disabled, all operations are allowed
    ?assertEqual(
        ok,
        bondy_rbac:authorize(<<"wamp.register">>, <<"com.any.thing">>, Ctxt)
    ).
