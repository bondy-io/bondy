%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% The declarative security configuration file: every entity it can declare,
%% every relationship between them, and the three properties the declarative
%% apply must have.
%%
%% The subject is `bondy_realm:from_file(File, #{declarative => true})` — the
%% exact call `bondy_realm:apply_config/0` makes from `bondy_app:start/2`, so
%% these cases exercise the boot path itself rather than a near-equivalent.
%%
%% The properties under test:
%%
%%   * COMPLETENESS  — every entity and relationship the file declares exists
%%     after the apply. Relationships are asserted through the authorization
%%     path where one exists, because a membership or grant that is stored but
%%     does not resolve is indistinguishable from a missing one to a caller.
%%   * IDEMPOTENCE   — re-applying an unchanged file emits no write. Each cell's
%%     HLC is the observable: an unchanged HLC means no operation entered the
%%     op-set, which is what keeps cross-node convergence undisturbed at boot.
%%   * RECONCILIATION — a changed file moves the declared state to match it,
%%     including retractions, and the change is visible to authorization.
%% -----------------------------------------------------------------------------
-module(bondy_realm_config_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_db_tables.hrl").

%% The realm identity cells share one global band (`bondy_realm` keys the band
%% by the realm Uri, not by realm).
-define(REALM_BAND, <<>>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        realm_and_entities,
        user_group_membership,
        group_inheritance,
        grants_bind_to_users_and_groups,
        sources_bind_to_usernames,
        idempotent_reapply,
        reconciles_membership_change,
        reconciles_group_and_grant_change,
        undeclared_entities_survive,
        realm_prototype_out_of_order,
        sso_realm_out_of_order,
        group_declared_after_its_parent,
        rate_limit_property_from_config_file
    ].

%% A declared realm's `rate_limit` lands as the realm property and is
%% enforced — the JSON file round-trip (binary keys, encode/decode) is
%% the shape under test; the chain mechanics have their own falsifiers
%% (`bondy_rate_limit_SUITE`).
rate_limit_property_from_config_file(Config) ->
    Uri = uri(<<"ratelimit">>),
    ok = apply_config(Config, [
        realm(Uri, #{
            <<"rate_limit">> => #{
                <<"http">> => #{
                    <<"per_caller">> => #{
                        <<"rate">> => 1, <<"capacity">> => 1
                    }
                }
            }
        })
    ]),
    ?assertEqual(
        #{http => #{per_caller => #{rate => 1, capacity => 1}}},
        bondy_realm:rate_limit(Uri)
    ),
    SavedNode = bondy_config:get([security, rate_limit], undefined),
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    try
        K = {test_ip, erlang:unique_integer([positive])},
        Dims = #{realm => Uri},
        ?assertEqual(ok, bondy_rate_limit:throttle(http, K, Dims)),
        ?assertEqual(throttled, bondy_rate_limit:throttle(http, K, Dims))
    after
        ok = bondy_config:set([security, rate_limit], SavedNode)
    end.

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    Config.

%% =============================================================================
%% CASES
%% =============================================================================

realm_and_entities(Config) ->
    Uri = uri(<<"entities">>),
    ok = apply_config(Config, [
        realm(Uri, #{
            <<"description">> => <<"A declared realm">>,
            <<"groups">> => [group(<<"grp1">>), group(<<"grp2">>)],
            <<"users">> => [user(<<"usr1">>, [<<"grp1">>])],
            <<"sources">> => [source([<<"usr1">>], <<"password">>)],
            <<"grants">> => [grant([<<"grp1">>], <<"com.example.">>)]
        })
    ]),

    %% The realm itself, with the declared properties.
    {ok, Realm} = bondy_realm:lookup(Uri),
    ?assertEqual(<<"A declared realm">>, bondy_realm:description(Realm)),
    ?assert(bondy_realm:is_security_enabled(Realm)),

    %% Groups.
    ?assertEqual(
        [<<"grp1">>, <<"grp2">>],
        declared_groups(Uri)
    ),

    %% Users.
    ?assertMatch({ok, _}, bondy_rbac_user:lookup(Uri, <<"usr1">>)),

    %% Sources — declared for the named user under the declared method.
    ?assertMatch(
        [_ | _],
        [
            S
         || S <- bondy_rbac_source:list(Uri),
            bondy_rbac_source:authmethod(S) == <<"password">>
        ]
    ),

    %% Grants.
    ?assertMatch([_ | _], bondy_realm:grants(Uri)).

user_group_membership(Config) ->
    %% The file declares a user's groups; the membership relation must hold
    %% them. This is the relationship the config file cannot express any other
    %% way — nothing else in the file names a (user, group) pair.
    Uri = uri(<<"membership">>),
    ok = apply_config(Config, [
        realm(Uri, #{
            <<"groups">> => [group(<<"grp1">>), group(<<"grp2">>)],
            <<"users">> => [
                user(<<"usr1">>, [<<"grp1">>, <<"grp2">>]),
                user(<<"usr2">>, [])
            ]
        })
    ]),

    ?assertEqual([<<"grp1">>, <<"grp2">>], user_groups(Uri, <<"usr1">>)),
    ?assertEqual([], user_groups(Uri, <<"usr2">>)),

    %% The relation reads in both directions: the group's member list is the
    %% same fact seen from the other side.
    {Members, _} = bondy_rbac_group:members(Uri, <<"grp2">>, #{}),
    ?assertEqual([<<"usr1">>], lists:sort(Members)).

group_inheritance(Config) ->
    %% A group's `groups` property is role inheritance. A user in the child
    %% must receive a grant held by the parent — the chain
    %% user -> child group -> parent group -> grant.
    Uri = uri(<<"group_inheritance">>),
    ok = apply_config(Config, [
        realm(Uri, #{
            <<"groups">> => [
                group(<<"parent">>),
                group(<<"child">>, [<<"parent">>])
            ],
            <<"users">> => [user(<<"usr1">>, [<<"child">>])],
            <<"grants">> => [grant([<<"parent">>], <<"com.inherited.">>)]
        })
    ]),

    ?assertEqual(
        [<<"parent">>],
        bondy_rbac_group:groups(bondy_rbac_group:fetch(Uri, <<"child">>))
    ),
    ?assertEqual(ok, authorize(Uri, <<"usr1">>, <<"com.inherited.thing">>)).

grants_bind_to_users_and_groups(Config) ->
    %% `roles` names either a group or a user. Both must resolve, and a role
    %% that was not granted must not.
    Uri = uri(<<"grants">>),
    ok = apply_config(Config, [
        realm(Uri, #{
            <<"groups">> => [group(<<"grp1">>)],
            <<"users">> => [
                user(<<"by_group">>, [<<"grp1">>]),
                user(<<"by_name">>, []),
                user(<<"ungranted">>, [])
            ],
            <<"grants">> => [
                grant([<<"grp1">>], <<"com.viagroup.">>),
                grant([<<"by_name">>], <<"com.viauser.">>)
            ]
        })
    ]),

    ?assertEqual(
        ok, authorize(Uri, <<"by_group">>, <<"com.viagroup.thing">>)
    ),
    ?assertEqual(ok, authorize(Uri, <<"by_name">>, <<"com.viauser.thing">>)),

    %% A grant on a group the user does not belong to does not reach them.
    ?assertMatch(
        {not_authorized, _},
        authorize(Uri, <<"ungranted">>, <<"com.viagroup.thing">>)
    ),
    %% Nor does a grant made by username reach a different user.
    ?assertMatch(
        {not_authorized, _},
        authorize(Uri, <<"by_group">>, <<"com.viauser.thing">>)
    ).

sources_bind_to_usernames(Config) ->
    %% A source assignment binds (username | all, authmethod, cidr). Both the
    %% named and the `all` form must be matchable for a user.
    Uri = uri(<<"sources">>),
    ok = apply_config(Config, [
        realm(Uri, #{
            <<"users">> => [user(<<"usr1">>, []), user(<<"usr2">>, [])],
            <<"sources">> => [
                source([<<"usr1">>], <<"trust">>),
                source(<<"all">>, <<"password">>)
            ]
        })
    ]),

    U1Methods = source_methods(Uri, <<"usr1">>),
    U2Methods = source_methods(Uri, <<"usr2">>),

    %% The named assignment reaches only its user; the `all` assignment reaches
    %% both.
    ?assert(lists:member(<<"trust">>, U1Methods)),
    ?assertNot(lists:member(<<"trust">>, U2Methods)),
    ?assert(lists:member(<<"password">>, U1Methods)),
    ?assert(lists:member(<<"password">>, U2Methods)).

idempotent_reapply(Config) ->
    %% Re-reading the same file on every boot must emit no operation. Each
    %% cell's HLC is the witness: an advanced HLC is a write that entered the
    %% op-set and perturbed cross-node convergence for no reason.
    Uri = uri(<<"idempotent">>),
    Realms = [
        realm(Uri, #{
            <<"groups">> => [group(<<"grp1">>)],
            <<"users">> => [user(<<"usr1">>, [<<"grp1">>])],
            <<"sources">> => [source([<<"usr1">>], <<"password">>)],
            <<"grants">> => [grant([<<"grp1">>], <<"com.example.">>)]
        })
    ],

    ok = apply_config(Config, Realms),
    Before = versions(Uri, <<"usr1">>, <<"grp1">>),

    ok = apply_config(Config, Realms),
    ?assertEqual(Before, versions(Uri, <<"usr1">>, <<"grp1">>)),

    %% A third apply, to catch a mechanism that is stable only in one direction.
    ok = apply_config(Config, Realms),
    ?assertEqual(Before, versions(Uri, <<"usr1">>, <<"grp1">>)),

    %% And nothing was lost while nothing was written.
    ?assertEqual([<<"grp1">>], user_groups(Uri, <<"usr1">>)),
    ?assertEqual(ok, authorize(Uri, <<"usr1">>, <<"com.example.thing">>)).

reconciles_membership_change(Config) ->
    %% The file is the desired state for a declared user's group set: a group
    %% added to it is asserted, a group dropped from it is retracted, and both
    %% are visible to authorization.
    Uri = uri(<<"membership_change">>),
    Base = #{
        <<"groups">> => [group(<<"grp1">>), group(<<"grp2">>)],
        <<"grants">> => [
            grant([<<"grp1">>], <<"com.one.">>),
            grant([<<"grp2">>], <<"com.two.">>)
        ]
    },

    ok = apply_config(Config, [
        realm(Uri, Base#{<<"users">> => [user(<<"usr1">>, [<<"grp1">>])]})
    ]),
    ?assertEqual([<<"grp1">>], user_groups(Uri, <<"usr1">>)),
    ?assertEqual(ok, authorize(Uri, <<"usr1">>, <<"com.one.thing">>)),
    ?assertMatch(
        {not_authorized, _}, authorize(Uri, <<"usr1">>, <<"com.two.thing">>)
    ),
    {ok, V0} = bondy_rbac_user:token_version(Uri, <<"usr1">>),

    %% Gaining a group.
    ok = apply_config(Config, [
        realm(Uri, Base#{
            <<"users">> => [user(<<"usr1">>, [<<"grp1">>, <<"grp2">>])]
        })
    ]),
    ?assertEqual([<<"grp1">>, <<"grp2">>], user_groups(Uri, <<"usr1">>)),
    ?assertEqual(ok, authorize(Uri, <<"usr1">>, <<"com.two.thing">>)),

    %% The user cell is the revocation zookie, so a membership change must
    %% advance it even though the record itself did not change. Without this a
    %% group revoked through the file leaves already-issued tokens valid.
    {ok, V1} = bondy_rbac_user:token_version(Uri, <<"usr1">>),
    ?assert(V1 > V0),

    %% Losing a group.
    ok = apply_config(Config, [
        realm(Uri, Base#{<<"users">> => [user(<<"usr1">>, [<<"grp2">>])]})
    ]),
    ?assertEqual([<<"grp2">>], user_groups(Uri, <<"usr1">>)),
    ?assertMatch(
        {not_authorized, _}, authorize(Uri, <<"usr1">>, <<"com.one.thing">>)
    ),
    {ok, V2} = bondy_rbac_user:token_version(Uri, <<"usr1">>),
    ?assert(V2 > V1).

reconciles_group_and_grant_change(Config) ->
    %% Entities added to the file after the first apply appear, and a changed
    %% group record is overwritten rather than merged.
    Uri = uri(<<"entity_change">>),

    ok = apply_config(Config, [
        realm(Uri, #{
            <<"groups">> => [group(<<"grp1">>)],
            <<"users">> => [user(<<"usr1">>, [<<"grp1">>])]
        })
    ]),
    ?assertMatch(
        {not_authorized, _}, authorize(Uri, <<"usr1">>, <<"com.later.thing">>)
    ),

    ok = apply_config(Config, [
        realm(Uri, #{
            <<"groups">> => [
                group(<<"grp1">>, [], #{<<"note">> => <<"changed">>}),
                group(<<"grp2">>)
            ],
            <<"users">> => [user(<<"usr1">>, [<<"grp1">>])],
            <<"grants">> => [grant([<<"grp1">>], <<"com.later.">>)]
        })
    ]),

    ?assertEqual(ok, authorize(Uri, <<"usr1">>, <<"com.later.thing">>)),
    ?assertEqual(
        [<<"grp1">>, <<"grp2">>],
        declared_groups(Uri)
    ),
    ?assertEqual(
        #{<<"note">> => <<"changed">>},
        bondy_rbac_group:meta(bondy_rbac_group:fetch(Uri, <<"grp1">>))
    ).

undeclared_entities_survive(Config) ->
    %% The file is authoritative for each object it declares, not for the
    %% population: an entity dropped from the file is left alone. An operator
    %% removing a user from the file must not expect that to delete the user.
    Uri = uri(<<"undeclared">>),

    ok = apply_config(Config, [
        realm(Uri, #{
            <<"groups">> => [group(<<"grp1">>), group(<<"grp2">>)],
            <<"users">> => [
                user(<<"usr1">>, [<<"grp1">>]), user(<<"usr2">>, [])
            ]
        })
    ]),

    ok = apply_config(Config, [
        realm(Uri, #{
            <<"groups">> => [group(<<"grp1">>)],
            <<"users">> => [user(<<"usr1">>, [<<"grp1">>])]
        })
    ]),

    ?assertMatch({ok, _}, bondy_rbac_user:lookup(Uri, <<"usr2">>)),
    ?assertMatch(
        #{name := <<"grp2">>}, bondy_rbac_group:lookup(Uri, <<"grp2">>)
    ).

realm_prototype_out_of_order(Config) ->
    %% A realm may reference a prototype declared later in the file; the apply
    %% topologically sorts the realms so the referent exists first.
    Proto = uri(<<"proto">>),
    Child = uri(<<"proto_child">>),

    ok = apply_config(Config, [
        realm(Child, #{<<"prototype_uri">> => Proto}),
        prototype_realm(Proto)
    ]),

    {ok, Realm} = bondy_realm:lookup(Child),
    ?assertEqual(Proto, bondy_realm:prototype_uri(Realm)),

    %% The relationship resolves: the child inherits the prototype's methods.
    ?assertEqual(
        lists:sort(bondy_realm:authmethods(Proto)),
        lists:sort(bondy_realm:authmethods(Child))
    ).

sso_realm_out_of_order(Config) ->
    %% Same ordering guarantee for `sso_realm_uri`, and the relationship it
    %% creates: an SSO user's credentials live in the SSO realm, not the local
    %% one, while the local realm holds the user's membership.
    SSO = uri(<<"sso">>),
    Local = uri(<<"sso_local">>),

    ok = apply_config(Config, [
        realm(Local, #{
            <<"sso_realm_uri">> => SSO,
            <<"groups">> => [group(<<"grp1">>)],
            <<"users">> => [
                maps:put(
                    <<"sso_realm_uri">>, SSO, user(<<"usr1">>, [<<"grp1">>])
                )
            ]
        }),
        sso_realm(SSO)
    ]),

    ?assertEqual(SSO, bondy_realm:sso_realm_uri(Local)),

    %% The user exists in both realms; the local record carries the membership.
    ?assertMatch({ok, _}, bondy_rbac_user:lookup(Local, <<"usr1">>)),
    ?assertMatch({ok, _}, bondy_rbac_user:lookup(SSO, <<"usr1">>)),
    ?assertEqual([<<"grp1">>], user_groups(Local, <<"usr1">>)).

group_declared_after_its_parent(Config) ->
    %% Groups are topologically sorted within a realm, so a group may list a
    %% parent that appears later in the array.
    Uri = uri(<<"group_order">>),
    ok = apply_config(Config, [
        realm(Uri, #{
            <<"groups">> => [
                group(<<"child">>, [<<"parent">>]),
                group(<<"parent">>)
            ],
            <<"users">> => [user(<<"usr1">>, [<<"child">>])],
            <<"grants">> => [grant([<<"parent">>], <<"com.ordered.">>)]
        })
    ]),

    ?assertEqual(ok, authorize(Uri, <<"usr1">>, <<"com.ordered.thing">>)).

%% =============================================================================
%% CONFIG FILE HELPERS
%% =============================================================================

%% Writes `Realms` as a security config file and applies it exactly as
%% `bondy_realm:apply_config/0` does at boot.
apply_config(Config, Realms) ->
    Dir = ?config(priv_dir, Config),
    File = filename:join(Dir, "security_config.json"),
    ok = file:write_file(File, bondy_wamp_json:encode(Realms)),
    bondy_realm:from_file(File, #{declarative => true}).

uri(Suffix) ->
    <<"com.example.config.", Suffix/binary>>.

realm(Uri, Extra) ->
    maps:merge(
        #{
            <<"uri">> => Uri,
            <<"security_enabled">> => true,
            <<"authmethods">> => [
                <<"password">>, <<"trust">>, <<"anonymous">>
            ]
        },
        Extra
    ).

prototype_realm(Uri) ->
    maps:put(<<"is_prototype">>, true, realm(Uri, #{})).

sso_realm(Uri) ->
    maps:put(<<"is_sso_realm">>, true, realm(Uri, #{})).

group(Name) ->
    group(Name, [], #{}).

group(Name, Parents) ->
    group(Name, Parents, #{}).

group(Name, Parents, Meta) ->
    #{
        <<"name">> => Name,
        <<"groups">> => Parents,
        <<"meta">> => Meta
    }.

%% A password would be the more realistic declaration, but the config apply
%% salts it deterministically, which is a property of its own; these cases hold
%% credentials out so an unchanged file is unchanged for a plainer reason.
user(Username, Groups) ->
    #{
        <<"username">> => Username,
        <<"groups">> => Groups,
        <<"meta">> => #{}
    }.

source(Usernames, Authmethod) ->
    #{
        <<"usernames">> => Usernames,
        <<"authmethod">> => Authmethod,
        <<"cidr">> => <<"0.0.0.0/0">>,
        <<"meta">> => #{}
    }.

grant(Roles, UriPrefix) ->
    #{
        <<"permissions">> => [
            <<"wamp.call">>, <<"wamp.publish">>, <<"wamp.subscribe">>
        ],
        <<"uri">> => UriPrefix,
        <<"match">> => <<"prefix">>,
        <<"roles">> => Roles
    }.

%% =============================================================================
%% ASSERTION HELPERS
%% =============================================================================

%% Every realm carries a built-in `anonymous` group that the file does not
%% declare; these cases are about the declared ones.
declared_groups(RealmUri) ->
    lists:sort([
        bondy_rbac_group:name(G)
     || G <- bondy_realm:groups(RealmUri),
        bondy_rbac_group:name(G) =/= anonymous
    ]).

user_groups(RealmUri, Username) ->
    lists:sort(
        bondy_rbac_user:groups(bondy_rbac_user:fetch(RealmUri, Username))
    ).

%% `authorize/3` raises on denial; these cases assert on both outcomes, so the
%% denial is returned rather than propagated.
authorize(RealmUri, Username, Resource) ->
    Ctxt = bondy_rbac:get_context(RealmUri, Username),
    try
        bondy_rbac:authorize(<<"wamp.call">>, Resource, Ctxt)
    catch
        error:Reason -> Reason
    end.

source_methods(RealmUri, Username) ->
    [
        bondy_rbac_source:authmethod(S)
     || S <- bondy_rbac_source:match(RealmUri, Username, {127, 0, 0, 1})
    ].

%% The cell HLCs of the realm, a user and a group. An unchanged tuple across an
%% apply means no operation was emitted for any of them.
versions(RealmUri, Username, Groupname) ->
    {ok, UserVsn} = bondy_rbac_user:token_version(RealmUri, Username),
    {
        UserVsn,
        cell_version(?BONDY_DB_GROUP_TAB, RealmUri, Groupname),
        cell_version(?BONDY_DB_REALM_TAB, ?REALM_BAND, RealmUri)
    }.

cell_version(TableName, Band, Key) ->
    Table = bondy_namespace_catalog:table(TableName),
    case bondy_db:read(Table, Band, Key) of
        {ok, {_Value, Hlc}} -> Hlc;
        {error, not_found} -> not_found
    end.
