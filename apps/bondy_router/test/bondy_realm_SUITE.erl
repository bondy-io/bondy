%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_realm_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").
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
        invalid_encryption_keys,
        split_for_import_keeps_an_unknown_term,

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
        delete_removes_retained_messages,
        delete_refuses_a_referenced_prototype,
        delete_refuses_a_referenced_sso_realm,
        sso_switch_is_refused_while_users_link_to_the_sso_realm,
        prototype_sso_switch_is_refused_while_a_member_has_linked_users,
        sso_switch_cannot_hand_a_user_another_identity,
        delete_api_reports_a_refusal_as_a_conflict
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

gen_uri() ->
    string:casefold(bondy_router_utils:generate_fragment(6)).

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
    TooLong = bondy_router_utils:generate_fragment(513),
    ?assertError(
        #{
            code := invalid_value,
            description :=
                <<"The value for 'description' did not pass the validator. Value is too big (max. is 512 bytes).">>
        },
        bondy_realm:create(#{uri => <<"foo">>, description => TooLong})
    ).

%% Each value is rejected by a distinct path of `jose_jwk:from_pem/1`: no PEM
%% entry, a PEM body that is not DER, and a term that is not PEM.
invalid_encryption_keys(_) ->
    NotDer = <<
        "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"
    >>,
    lists:foreach(
        fun(Key) ->
            ?assertError(
                #{code := invalid_value},
                bondy_realm:create(#{
                    uri => <<"com.example.invalid_encryption_keys">>,
                    encryption_keys => [Key]
                })
            )
        end,
        [<<"not a pem">>, NotDer, 42]
    ).

split_for_import_keeps_an_unknown_term(_) ->
    Term = {not_a_realm, 1},
    ?assertEqual({Term, []}, bondy_realm:split_for_import(Term)).

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

%% A realm another realm inherits from cannot be deleted while it does: the
%% dependent resolves its SSO realm through the prototype on every HELLO
%% (`bondy_realm:sso_realm_uri/1`).
delete_refuses_a_referenced_prototype(_) ->
    ProtoUri = gen_uri(),
    _ = bondy_realm:create(#{uri => ProtoUri, is_prototype => true}),
    Uri = gen_uri(),
    _ = bondy_realm:create(#{uri => Uri, prototype_uri => ProtoUri}),
    ?assertEqual({error, {in_use, [Uri]}}, bondy_realm:delete(ProtoUri)),
    ?assertMatch({ok, _}, bondy_realm:lookup(ProtoUri)),
    ?assertEqual(undefined, bondy_realm:sso_realm_uri(Uri)),
    ok = bondy_realm:delete(Uri),
    ?assertEqual(ok, bondy_realm:delete(ProtoUri)).

delete_refuses_a_referenced_sso_realm(_) ->
    SSOUri = gen_uri(),
    _ = bondy_realm:create(#{uri => SSOUri, is_sso_realm => true}),
    Uri = gen_uri(),
    _ = bondy_realm:create(#{uri => Uri, sso_realm_uri => SSOUri}),
    ?assertEqual({error, {in_use, [Uri]}}, bondy_realm:delete(SSOUri)),
    ?assertMatch({ok, _}, bondy_realm:lookup(SSOUri)),
    ok = bondy_realm:delete(Uri),
    ?assertEqual(ok, bondy_realm:delete(SSOUri)).

sso_switch_is_refused_while_users_link_to_the_sso_realm(_) ->
    [S1, S2] = [sso_realm() || _ <- [1, 2]],
    Uri = gen_uri(),
    _ = bondy_realm:create(#{uri => Uri, sso_realm_uri => S1}),
    ok = add_sso_user(Uri, ?U1, S1),
    ?assertError(
        {inconsistency_error, [sso_realm_uri], _},
        bondy_realm:update(Uri, #{sso_realm_uri => S2})
    ),
    ?assertError(
        {inconsistency_error, [sso_realm_uri], _},
        bondy_realm:update(Uri, #{sso_realm_uri => undefined})
    ),
    ?assertEqual(S1, bondy_realm:sso_realm_uri(Uri)),
    ?assertEqual(
        S1,
        bondy_realm:sso_realm_uri(
            bondy_realm:update(Uri, #{sso_realm_uri => S1})
        )
    ),
    ok = bondy_rbac_user:remove(Uri, ?U1),
    ?assertEqual(
        S2,
        bondy_realm:sso_realm_uri(
            bondy_realm:update(Uri, #{sso_realm_uri => S2})
        )
    ).

%% A member that sets its own `sso_realm_uri` does not inherit the prototype's,
%% so its users do not hold the prototype back.
prototype_sso_switch_is_refused_while_a_member_has_linked_users(_) ->
    [S1, S2, S3] = [sso_realm() || _ <- [1, 2, 3]],
    ProtoUri = gen_uri(),
    _ = bondy_realm:create(#{
        uri => ProtoUri, is_prototype => true, sso_realm_uri => S1
    }),
    Inherits = gen_uri(),
    _ = bondy_realm:create(#{uri => Inherits, prototype_uri => ProtoUri}),
    Overrides = gen_uri(),
    _ = bondy_realm:create(#{
        uri => Overrides, prototype_uri => ProtoUri, sso_realm_uri => S3
    }),
    ok = add_sso_user(Inherits, ?U1, S1),
    ok = add_sso_user(Overrides, ?U2, S3),
    ?assertError(
        {inconsistency_error, [sso_realm_uri], _},
        bondy_realm:update(ProtoUri, #{sso_realm_uri => S2})
    ),
    ?assertEqual(S1, bondy_realm:sso_realm_uri(Inherits)),
    ok = bondy_rbac_user:remove(Inherits, ?U1),
    _ = bondy_realm:update(ProtoUri, #{sso_realm_uri => S2}),
    ?assertEqual(S2, bondy_realm:sso_realm_uri(Inherits)),
    ?assertEqual(S3, bondy_realm:sso_realm_uri(Overrides)).

%% Two realms with SSO realms `S1` and `S2` each hold a user named `?U1`, two
%% people. Were the first realm switched to `S2`, its `?U1` would log in with
%% `S1` credentials and receive an `S2`-issued token the second realm accepts as
%% its own `?U1`.
sso_switch_cannot_hand_a_user_another_identity(_) ->
    [S1, S2] = [sso_realm() || _ <- [1, 2]],
    Mine = gen_uri(),
    Theirs = gen_uri(),
    _ = bondy_realm:create(token_realm(Mine, S1)),
    _ = bondy_realm:create(token_realm(Theirs, S2)),
    ok = add_sso_user(Mine, ?U1, S1),
    ok = add_sso_user(Theirs, ?U1, S2),
    _ = catch_inconsistency(fun() ->
        bondy_realm:update(Mine, #{sso_realm_uri => S2})
    end),
    {ok, Ctxt} = bondy_auth:init(
        bondy_session_id:new(), Mine, ?U1, [], {127, 0, 0, 1}
    ),
    {ok, Token} = bondy_oauth_token:issue(password, Ctxt, #{allow_sso => true}),
    {ok, {JWT, _}} = bondy_oauth_token:to_access_token(Token),
    ?assertEqual(
        {error, untrusted_issuer}, bondy_oauth_jwt:verify(Theirs, JWT)
    ).

%% The admin API reports the refusal as a permanent `conflict` naming the
%% dependent realms, not as an internal error a client would retry.
delete_api_reports_a_refusal_as_a_conflict(_) ->
    ProtoUri = gen_uri(),
    _ = bondy_realm:create(#{uri => ProtoUri, is_prototype => true}),
    Uri = gen_uri(),
    _ = bondy_realm:create(#{uri => Uri, prototype_uri => ProtoUri}),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI),
    Call = bondy_wamp_message:call(1, #{}, ?BONDY_REALM_DELETE, [ProtoUri]),
    {reply, Error0} = bondy_realm_api:handle_call(
        ?BONDY_REALM_DELETE, Call, Ctxt
    ),
    Error = bondy_wamp_message:decode_partial(Error0),
    ?assertEqual(<<"bondy.error.conflict">>, Error#error.error_uri),
    ?assertMatch(
        #{
            <<"nature">> := <<"permanent">>,
            <<"details">> := #{<<"realms">> := [Uri]}
        },
        Error#error.kwargs
    ),
    ok = bondy_realm:delete(Uri),
    ok = bondy_realm:delete(ProtoUri).

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
    %% The field order below is the 0.9.SNAPSHOT-SSO `realm` record layout.
    Desc = bondy_router_utils:generate_fragment(10),
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
    %% migration path.
    Table = bondy_namespace_catalog:table(?BONDY_DB_REALM_TAB),
    ok = bondy_db:apply(Table, <<>>, Uri, {set, Old}),

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

sso_realm() ->
    Uri = gen_uri(),
    _ = bondy_realm:create(#{uri => Uri, is_sso_realm => true}),
    Uri.

add_sso_user(RealmUri, Username, SSOUri) ->
    User = bondy_rbac_user:new(#{
        username => Username,
        password => ~"a-good-password",
        sso_realm_uri => SSOUri
    }),
    {ok, _} = bondy_rbac_user:add(RealmUri, User),
    ok.

token_realm(Uri, SSOUri) ->
    #{
        uri => Uri,
        sso_realm_uri => SSOUri,
        security_enabled => true,
        authmethods => [?PASSWORD_AUTH, ?WAMP_OAUTH2_AUTH],
        sources => [
            #{usernames => ~"all", authmethod => M, cidr => ~"0.0.0.0/0"}
         || M <- [?PASSWORD_AUTH, ?WAMP_OAUTH2_AUTH]
        ]
    }.

%% The refusal under test; any other failure propagates.
catch_inconsistency(Fun) ->
    try
        Fun()
    catch
        error:{inconsistency_error, [sso_realm_uri], _} = Reason -> Reason
    end.
