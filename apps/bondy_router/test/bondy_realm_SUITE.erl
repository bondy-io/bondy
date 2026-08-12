%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_realm_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy.hrl").
-include("bondy_db_tables.hrl").
-include("bondy_security.hrl").

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
        prototype_inheritance,

        migration,
        strip_private_keys,
        delete_removes_key_material,
        delete_removes_retained_messages
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    % bondy_ct:stop_bondy(),
    {save_config, Config}.

gen_uri() ->
    string:casefold(bondy_utils:generate_fragment(6)).

uri(_) ->
    Uri = gen_uri(),
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
        bondy_realm:update(Uri, #{uri => gen_uri()}),
        "Property is immutable"
    ),

    ?assertMatch(
        R,
        bondy_realm:update(R, #{uri => gen_uri()}),
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
            description :=
                <<"The value for 'description' did not pass the validator. Value is too big (max. is 512 bytes).">>
        },
        bondy_realm:create(#{uri => <<"foo">>, description => TooLong})
    ).

sso_inconsistency_error(_) ->
    ?assertError(
        {inconsistency_error, [is_sso_realm, sso_realm_uri]},
        bondy_realm:create(#{
            uri => gen_uri(),
            is_sso_realm => true,
            sso_realm_uri => gen_uri()
        }),
        "An sso realm cannot itself have an sso realm"
    ).

sso_uri_not_found_error(_) ->
    ?assertError(
        {badarg, _},
        bondy_realm:create(#{
            uri => gen_uri(),
            sso_realm_uri => gen_uri()
        }),
        "SSO realm should exist"
    ).

is_sso_realm(_) ->
    Uri = gen_uri(),
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
            uri => gen_uri(),
            is_prototype => true,
            prototype_uri => gen_uri()
        }),
        "a prototype cannot have a prototype"
    ).

prototype_badarg(_) ->
    Uri = gen_uri(),
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
            uri => gen_uri(),
            prototype_uri => gen_uri()
        }),
        "Prototype realm should exist"
    ).

is_prototype(_) ->
    Uri = gen_uri(),
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
    ProtoUri = gen_uri(),
    _ = bondy_realm:create(#{
        uri => ProtoUri,
        is_prototype => true
    }),

    Uri = gen_uri(),
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
            prototype_uri => gen_uri()
        }),
        "Property is immutable"
    ).

prototype_inheritance(_) ->
    SSOUri = gen_uri(),
    _SSO = bondy_realm:create(#{
        uri => SSOUri,
        is_sso_realm => true
    }),

    ProtoUri = gen_uri(),
    P = bondy_realm:create(#{
        uri => ProtoUri,
        is_prototype => true,
        allow_connections => false,
        authmethods => [?WAMP_TICKET_AUTH],
        is_sso_realm => false,
        security_enabled => false,
        sso_realm_uri => SSOUri
    }),

    Uri = gen_uri(),
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

strip_private_keys(_) ->
    Uri = gen_uri(),
    R0 = bondy_realm:create(#{
        uri => Uri
    }),
    ?assertNotEqual(
        0,
        length(bondy_realm:private_keys(R0))
    ),

    R1 = bondy_realm:strip_private_keys(R0),

    ?assertEqual(
        0,
        length(bondy_realm:private_keys(R1))
    ).

migration(_) ->
    Uri = gen_uri(),
    %% 0.9.SNAPSHOT-SSO
    %% -record(realm, {
    %%     [2] uri                      ::  gen_uri(),
    %%     [3] description              ::  binary(),
    %%     [4] authmethods              ::  [binary()],
    %%     [5] security_enabled = true  ::  boolean(),
    %%     [6] is_sso_realm = false     ::  boolean(),
    %%     [7] allow_connections = true ::  boolean(),
    %%     [8] sso_realm_uri            ::  optional(gen_uri()),
    %%     [9] private_keys = #{}       ::  keyset(),
    %%     [10] public_keys = #{}        ::  keyset(),
    %%     [11] password_opts            ::  bondy_password:opts() | undefined,
    %%     [12] encryption_keys = #{}    ::  keyset(),
    %%     [13] info = #{}               ::  map()
    %% }).
    Desc = bondy_utils:generate_fragment(10),
    Authmethods = [?WAMP_CRYPTOSIGN_AUTH],
    Sec = true,
    IsSSO = false,
    AllowConnections = true,
    SSOUri = undefined,
    PrivKeys = #{},
    PubKeys = #{},
    PassOpts = #{},
    EncKeys = #{},
    Info = #{},

    Old =
        {realm, Uri, Desc, Authmethods, Sec, IsSSO, AllowConnections, SSOUri,
            PrivKeys, PubKeys, PassOpts, EncKeys, Info},
    %% We store an older-version realm directly into the global realm band
    %% (the empty binary) so that fetch/1 exercises the legacy from_term
    %% migration path (design §11.4: realms now live in bondy_db).
    Table = bondy_namespace_catalog:table(?BONDY_DB_REALM_TAB),
    ok = bondy_db:apply(Table, <<>>, Uri, {set, Old}),

    %% We should now have a migrated realm
    New = bondy_realm:fetch(Uri),

    ?assertMatch(
        Uri,
        bondy_realm:uri(New)
    ),
    ?assertMatch(
        Desc,
        bondy_realm:description(New)
    ),
    ?assertMatch(
        Authmethods,
        bondy_realm:authmethods(New)
    ),
    ?assertMatch(
        Sec,
        bondy_realm:is_security_enabled(New)
    ),
    ?assertMatch(
        AllowConnections,
        bondy_realm:allow_connections(New)
    ),
    ?assertMatch(
        SSOUri,
        bondy_realm:sso_realm_uri(New)
    ),
    ?assertMatch(
        [_, _, _],
        bondy_realm:private_keys(New)
    ),
    ?assertMatch(
        [_, _, _],
        bondy_realm:public_keys(New)
    ),
    ?assertMatch(
        PassOpts,
        bondy_realm:password_opts(New)
    ),
    ?assertMatch(
        [_, _, _],
        bondy_realm:encryption_keys(New)
    ),
    ?assertMatch(
        Info,
        bondy_realm:info(New)
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
    _ = bondy_realm:create(Config).

delete_removes_key_material(_) ->
    %% A realm's signing/encryption keys live OUTSIDE its identity cell, in
    %% `bondy_realm_keys`, so that the identity's cross-node digest is the Uri
    %% plus config and not the random key bytes. Deleting the realm must take
    %% that second cell with it; otherwise the key material of a deleted realm
    %% stays on disk and is replicated forever.
    Uri = <<"com.example.realm.delete.keys">>,
    Realm = bondy_realm:create(#{uri => Uri, security_enabled => true}),

    %% Keys were minted with the realm (an authoritative, non-declarative
    %% create generates eagerly).
    ?assertNotEqual([], bondy_realm:private_keys(Realm)),
    ?assertNotEqual(#{}, stored_keys(Uri)),

    ok = bondy_realm:delete(Uri, #{force => true}),

    %% Associated data is removed by a router worker, so the cell empties
    %% shortly after `delete/2` returns rather than within it.
    ok = wait_until(fun() -> stored_keys(Uri) == #{} end, 5000),
    ?assertEqual(#{}, stored_keys(Uri)),
    ?assertEqual({error, not_found}, bondy_realm:lookup(Uri)).

delete_removes_retained_messages(_) ->
    %% Retained events are per-realm state keyed by topic. Deleting the realm
    %% must take them with it: the URI can be created again, and a new realm
    %% must not deliver the deleted realm's events to its subscribers.
    Uri = <<"com.example.realm.delete.retained">>,
    _ = bondy_realm:create(#{uri => Uri, security_enabled => true}),

    Topic = <<"com.example.retained.topic">>,
    Event = bondy_wamp_message:event(1, 1, #{}),
    ok = bondy_retained_message:put(Uri, Topic, Event, #{}),
    ?assertNotEqual(undefined, bondy_retained_message:get(Uri, Topic)),

    ok = bondy_realm:delete(Uri, #{force => true}),

    %% Associated data is removed by a router worker, so the band empties
    %% shortly after `delete/2` returns rather than within it.
    ok = wait_until(fun() -> retained(Uri) == [] end, 5000),
    ?assertEqual([], retained(Uri)),
    ?assertEqual(undefined, bondy_retained_message:get(Uri, Topic)).

%% Every retained-message cell of a realm, as `{Topic, Message}`.
retained(Uri) ->
    Table = bondy_namespace_catalog:table(retained_messages),
    {ok, Rows} = bondy_db:list(Table, Uri),
    [{K, V} || {K, V, _Hlc} <- Rows].

%% The raw `bondy_realm_keys` cell as `#{Kid => Bundle}`, or `#{}` when the cell
%% is absent or has had every kid retracted.
stored_keys(Uri) ->
    Table = bondy_namespace_catalog:table(?BONDY_DB_REALM_KEYS_TAB),
    case bondy_db:read(Table, <<>>, Uri) of
        {ok, {Map, _Hlc}} when is_map(Map) -> Map;
        _ -> #{}
    end.

wait_until(_Fun, Remaining) when Remaining =< 0 ->
    {error, timeout};
wait_until(Fun, Remaining) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(Fun, Remaining - 100)
    end.
