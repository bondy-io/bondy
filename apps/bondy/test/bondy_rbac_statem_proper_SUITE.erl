%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rbac_statem_proper_SUITE).
-moduledoc """
Property-based stateful tests for the RBAC subsystem.

Uses PropEr `proper_statem` to maintain a pure mathematical model of the RBAC
system and verify that the SUT's authorization decisions match the model after
arbitrary sequences of RBAC mutations (add/remove groups and users, grant/revoke
permissions, modify group membership).

Also includes standalone FORALL properties for normalization transparency,
grant monotonicity, 'all' group universality, prototype inheritance, and
explicit-groups normalization.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

-define(STATEM_NUMTESTS, 60).
-define(FORALL_NUMTESTS, 50).
-define(MAX_CMDS, 30).
-define(REALM, <<"com.test.proper.rbac.statem">>).


%% =============================================================================
%% MODEL STATE
%% =============================================================================


-record(model, {
    realm_uri     :: binary(),
    %% #{NormalizedGroupName => [NormalizedParentGroupNames]}
    groups = #{}  :: #{binary() => [binary()]},
    %% #{NormalizedUsername => [NormalizedGroupNames]}
    users = #{}   :: #{binary() => [binary()]},
    %% #{{user|group, NormalizedName|all} => #{Resource => ordsets(Perm)}}
    grants = #{}  :: #{grant_key() => #{resource() => [binary()]}},
    %% Resources that have been granted (for biased test URI generation)
    granted_resources = [] :: [resource()],
    next_gid = 1  :: pos_integer(),
    next_uid = 1  :: pos_integer()
}).

-type grant_key() :: {user | group, binary() | all}.
-type resource()  :: any | {binary(), binary()}.



%% =============================================================================
%% CT CALLBACKS
%% =============================================================================



all() ->
    [
        prop_rbac_statem,
        prop_normalization_transparency,
        prop_grant_monotonicity,
        prop_all_group_universality,
        prop_prototype_inheritance,
        prop_explicit_groups_normalization
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.


end_per_suite(Config) ->
    {save_config, Config}.



%% =============================================================================
%% GENERATORS
%% =============================================================================



%% @private
gen_case_variant(Bin) ->
    oneof([
        Bin,
        unicode:characters_to_binary(string:uppercase(Bin)),
        capitalize_first(Bin)
    ]).


%% @private
capitalize_first(<<C, Rest/binary>>) when C >= $a, C =< $z ->
    <<(C - 32), Rest/binary>>;
capitalize_first(Bin) ->
    Bin.


%% @private
gen_permission() ->
    elements([
        <<"wamp.call">>,
        <<"wamp.register">>,
        <<"wamp.unregister">>,
        <<"wamp.subscribe">>,
        <<"wamp.unsubscribe">>,
        <<"wamp.cancel">>,
        <<"wamp.publish">>
    ]).


%% @private
gen_permissions() ->
    non_empty(list(gen_permission())).


%% @private
%% Small vocabulary so exact-match collisions happen often enough.
-define(URI_PARTS, [<<"a">>, <<"b">>, <<"c">>]).

gen_resource() ->
    frequency([
        {4, gen_exact_resource()},
        {4, gen_prefix_resource()},
        {2, gen_wildcard_resource()},
        {1, exactly(any)},
        {1, exactly({<<>>, <<"prefix">>})}
    ]).


%% @private
gen_exact_resource() ->
    ?LET(
        Parts,
        vector(3, elements(?URI_PARTS)),
        {iolist_to_binary(lists:join(<<".">>, Parts)), <<"exact">>}
    ).


%% @private
gen_prefix_resource() ->
    ?LET(
        Parts,
        non_empty(list(elements(?URI_PARTS))),
        {<<(iolist_to_binary(lists:join(<<".">>, Parts)))/binary, ".">>,
         <<"prefix">>}
    ).


%% @private
gen_wildcard_resource() ->
    ?LET(
        Parts,
        vector(3, frequency([
            {3, elements(?URI_PARTS)},
            {1, exactly(<<>>)}  %% wildcard component
        ])),
        {iolist_to_binary(lists:join(<<".">>, Parts)), <<"wildcard">>}
    ).


%% @private
%% Biased: preferentially generates URIs that could match granted resources,
%% so that authorize checks exercise the "authorized" path, not just "denied".
gen_test_uri(#model{granted_resources = Granted}) ->
    BaseGen = ?LET(
        Parts,
        vector(3, elements(?URI_PARTS)),
        iolist_to_binary(lists:join(<<".">>, Parts))
    ),
    %% Extract concrete URIs from granted resources to reuse
    ConcreteUris = [Uri || {Uri, _} <- Granted,
                           is_binary(Uri), byte_size(Uri) > 0],
    case ConcreteUris of
        [] ->
            frequency([
                {1, exactly(any)},
                {6, BaseGen}
            ]);
        _ ->
            frequency([
                {1, exactly(any)},
                {3, BaseGen},
                %% Reuse a granted URI directly (high chance of exact hit)
                {3, elements(ConcreteUris)},
                %% Extend a granted prefix (high chance of prefix hit)
                {2, ?LET(
                    {Prefix, Suffix},
                    {elements(ConcreteUris), elements(?URI_PARTS)},
                    <<Prefix/binary, Suffix/binary>>
                )}
            ])
    end.


%% --- State-dependent generators ---


%% @private
gen_new_group_spec(#model{groups = Groups, next_gid = N}) ->
    ExistingNames = maps:keys(Groups),
    BaseName = <<"grp_", (integer_to_binary(N))/binary>>,
    Parents = case ExistingNames of
        [] -> exactly([]);
        _ -> list(elements(ExistingNames))
    end,
    ?LET(
        {CaseVariant, Prnts},
        {gen_case_variant(BaseName), Parents},
        {CaseVariant, lists:usort(Prnts)}
    ).


%% @private
gen_new_user_spec(#model{groups = Groups, next_uid = N}) ->
    GroupNames = maps:keys(Groups),
    BaseName = <<"usr_", (integer_to_binary(N))/binary>>,
    Membership = case GroupNames of
        [] -> exactly([]);
        _ -> list(elements(GroupNames))
    end,
    ?LET(
        {CaseVariant, Grps},
        {gen_case_variant(BaseName), Membership},
        {CaseVariant, lists:usort(Grps)}
    ).


%% @private
gen_existing_groupname(#model{groups = Groups}) ->
    elements(maps:keys(Groups)).


%% @private
gen_existing_username(#model{users = Users}) ->
    elements(maps:keys(Users)).


%% @private
gen_role_name(#model{users = Users, groups = Groups}) ->
    AllRoles = maps:keys(Users) ++ maps:keys(Groups),
    frequency([
        {8, elements(AllRoles)},
        {2, exactly(<<"all">>)}
    ]).



%% =============================================================================
%% PROPER_STATEM CALLBACKS
%% =============================================================================



initial_state() ->
    #model{realm_uri = ?REALM}.


command(#model{} = S) ->
    GroupNames = maps:keys(S#model.groups),
    UserNames = maps:keys(S#model.users),
    HasGroups = GroupNames =/= [],
    HasUsers = UserNames =/= [],
    HasRoles = HasGroups orelse HasUsers,

    %% Always available: add new entities
    Base = [
        {8, {call, ?MODULE, sut_add_group,
             [S#model.realm_uri, gen_new_group_spec(S)]}},
        {5, {call, ?MODULE, sut_add_user,
             [S#model.realm_uri, gen_new_user_spec(S)]}}
    ],

    %% Need at least one role for grant/revoke
    Grant = case HasRoles of
        true -> [
            {15, {call, ?MODULE, sut_grant, [
                S#model.realm_uri, gen_role_name(S),
                gen_resource(), gen_permissions()
            ]}},
            {8, {call, ?MODULE, sut_revoke, [
                S#model.realm_uri, gen_role_name(S),
                gen_resource(), gen_permissions()
            ]}}
        ];
        false -> []
    end,

    %% Need at least one user for authorization checks
    Auth = case HasUsers of
        true -> [
            {20, {call, ?MODULE, sut_authorize, [
                S#model.realm_uri, gen_existing_username(S),
                gen_permission(), gen_test_uri(S)
            ]}}
        ];
        false -> []
    end,

    %% Authorize via get_context/3 with explicit (possibly mixed-case) groups
    AuthExplicit = case HasUsers andalso HasGroups of
        true -> [
            {8, {call, ?MODULE, sut_authorize_explicit, [
                S#model.realm_uri, gen_existing_username(S),
                non_empty(list(
                    ?LET(G, gen_existing_groupname(S), gen_case_variant(G))
                )),
                gen_permission(), gen_test_uri(S)
            ]}}
        ];
        false -> []
    end,

    %% Need both users and groups for membership changes
    Membership = case HasUsers andalso HasGroups of
        true -> [
            {5, {call, ?MODULE, sut_add_user_to_group, [
                S#model.realm_uri,
                gen_existing_username(S),
                gen_existing_groupname(S)
            ]}}
        ];
        false -> []
    end,

    %% Destructive
    Remove = lists:append([
        case HasGroups of
            true -> [{3, {call, ?MODULE, sut_remove_group, [
                S#model.realm_uri, gen_existing_groupname(S)
            ]}}];
            false -> []
        end,
        case HasUsers of
            true -> [{2, {call, ?MODULE, sut_remove_user, [
                S#model.realm_uri, gen_existing_username(S)
            ]}}];
            false -> []
        end
    ]),

    frequency(lists:append([
        Base, Grant, Auth, AuthExplicit, Membership, Remove
    ])).


precondition(S, {call, _, sut_add_group, [_, {Name, Parents}]}) ->
    NormName = string:casefold(Name),
    (not maps:is_key(NormName, S#model.groups))
    andalso lists:all(
        fun(P) -> maps:is_key(P, S#model.groups) end,
        Parents
    );

precondition(S, {call, _, sut_add_user, [_, {Username, Groups}]}) ->
    NormUser = string:casefold(Username),
    (not maps:is_key(NormUser, S#model.users))
    andalso (not maps:is_key(NormUser, S#model.groups))
    andalso lists:all(
        fun(G) -> maps:is_key(G, S#model.groups) end,
        Groups
    );

precondition(S, {call, _, sut_grant, [_, RoleName, _, _]}) ->
    role_exists(RoleName, S);

precondition(S, {call, _, sut_revoke, [_, RoleName, _, _]}) ->
    role_exists(RoleName, S);

precondition(S, {call, _, sut_authorize, [_, Username, _, _]}) ->
    maps:is_key(Username, S#model.users);

precondition(S, {call, _, sut_authorize_explicit, [_, Username, Groups, _, _]}) ->
    maps:is_key(Username, S#model.users)
    andalso lists:all(
        fun(G) -> maps:is_key(string:casefold(G), S#model.groups) end,
        Groups
    );

precondition(S, {call, _, sut_add_user_to_group, [_, Username, GroupName]}) ->
    maps:is_key(Username, S#model.users)
    andalso maps:is_key(GroupName, S#model.groups);

precondition(S, {call, _, sut_remove_group, [_, Name]}) ->
    maps:is_key(Name, S#model.groups);

precondition(S, {call, _, sut_remove_user, [_, Username]}) ->
    maps:is_key(Username, S#model.users);

precondition(_, _) ->
    true.


next_state(S, _Res, {call, _, sut_add_group, [_, {Name, Parents}]}) ->
    NormName = string:casefold(Name),
    S#model{
        groups = maps:put(NormName, Parents, S#model.groups),
        next_gid = S#model.next_gid + 1
    };

next_state(S, _Res, {call, _, sut_add_user, [_, {Username, Groups}]}) ->
    NormUser = string:casefold(Username),
    S#model{
        users = maps:put(NormUser, Groups, S#model.users),
        next_uid = S#model.next_uid + 1
    };

next_state(S, _Res, {call, _, sut_grant, [_, RoleName, Resource, Permissions]}) ->
    RoleKey = model_role_key(RoleName, S),
    NormResource = normalize_resource(Resource),
    ExistingRoleGrants = maps:get(RoleKey, S#model.grants, #{}),
    ExistingPerms = maps:get(NormResource, ExistingRoleGrants, []),
    NewPerms = lists:usort(ExistingPerms ++ Permissions),
    NewRoleGrants = maps:put(NormResource, NewPerms, ExistingRoleGrants),
    S#model{
        grants = maps:put(RoleKey, NewRoleGrants, S#model.grants),
        granted_resources = lists:usort([NormResource | S#model.granted_resources])
    };

next_state(S, _Res, {call, _, sut_revoke, [_, RoleName, Resource, Permissions]}) ->
    RoleKey = model_role_key(RoleName, S),
    NormResource = normalize_resource(Resource),
    case maps:find(RoleKey, S#model.grants) of
        {ok, RoleGrants} ->
            case maps:find(NormResource, RoleGrants) of
                {ok, ExistingPerms} ->
                    NewPerms = ExistingPerms -- Permissions,
                    NewRoleGrants = case NewPerms of
                        [] ->
                            maps:remove(NormResource, RoleGrants);
                        _ ->
                            maps:put(NormResource,
                                     lists:usort(NewPerms), RoleGrants)
                    end,
                    case map_size(NewRoleGrants) of
                        0 ->
                            S#model{
                                grants = maps:remove(RoleKey, S#model.grants)
                            };
                        _ ->
                            S#model{
                                grants = maps:put(
                                    RoleKey, NewRoleGrants, S#model.grants)
                            }
                    end;
                error ->
                    S
            end;
        error ->
            S
    end;

next_state(S, _Res, {call, _, sut_add_user_to_group, [_, Username, GroupName]}) ->
    CurrentGroups = maps:get(Username, S#model.users),
    NewGroups = lists:usort([GroupName | CurrentGroups]),
    S#model{users = maps:put(Username, NewGroups, S#model.users)};

next_state(S, _Res, {call, _, sut_remove_group, [_, Name]}) ->
    %% Remove the group itself
    NewGroups0 = maps:remove(Name, S#model.groups),
    %% Remove from other groups' parent lists
    NewGroups = maps:map(
        fun(_K, Parents) -> Parents -- [Name] end,
        NewGroups0
    ),
    %% Remove from users' group lists
    NewUsers = maps:map(
        fun(_K, Grps) -> Grps -- [Name] end,
        S#model.users
    ),
    %% Remove grants for this group
    NewGrants = maps:remove({group, Name}, S#model.grants),
    S#model{groups = NewGroups, users = NewUsers, grants = NewGrants};

next_state(S, _Res, {call, _, sut_remove_user, [_, Username]}) ->
    S#model{
        users = maps:remove(Username, S#model.users),
        grants = maps:remove({user, Username}, S#model.grants)
    };

next_state(S, _Res, _Call) ->
    S.


postcondition(S, {call, _, sut_authorize, [_, Username, Permission, Resource]},
              Result) ->
    EffGrants = model_effective_grants(Username, S),
    ModelDecision = model_authorize(Permission, Resource, EffGrants),
    case {Result, ModelDecision} of
        {authorized, true} ->
            true;
        {denied, false} ->
            true;
        {authorized, false} ->
            ct:pal(
                "OVER-PERMISSIVE:~n"
                "  User=~p Permission=~p Resource=~p~n"
                "  Model effective grants: ~p~n"
                "  Model state: ~p",
                [Username, Permission, Resource, EffGrants, S]
            ),
            false;
        {denied, true} ->
            ct:pal(
                "UNDER-PERMISSIVE:~n"
                "  User=~p Permission=~p Resource=~p~n"
                "  Model effective grants: ~p~n"
                "  Model state: ~p",
                [Username, Permission, Resource, EffGrants, S]
            ),
            false;
        _ ->
            ct:pal("UNEXPECTED RESULT: ~p", [Result]),
            false
    end;

postcondition(S, {call, _, sut_authorize_explicit,
              [_, _Username, ExplicitGroups, Permission, Resource]}, Result) ->
    %% For explicit groups, effective grants come from those groups
    %% (after normalization) + 'all' group, NOT the user's stored groups.
    NormGroups = [string:casefold(G) || G <- ExplicitGroups],
    EffGrants = model_effective_grants_explicit(NormGroups, S),
    ModelDecision = model_authorize(Permission, Resource, EffGrants),
    case {Result, ModelDecision} of
        {authorized, true} ->
            true;
        {denied, false} ->
            true;
        {authorized, false} ->
            ct:pal(
                "OVER-PERMISSIVE (explicit):~n"
                "  ExplicitGroups=~p Permission=~p Resource=~p~n"
                "  Model effective grants: ~p",
                [ExplicitGroups, Permission, Resource, EffGrants]
            ),
            false;
        {denied, true} ->
            ct:pal(
                "UNDER-PERMISSIVE (explicit):~n"
                "  ExplicitGroups=~p Permission=~p Resource=~p~n"
                "  Model effective grants: ~p~n"
                "  Model state: ~p",
                [ExplicitGroups, Permission, Resource, EffGrants, S]
            ),
            false;
        _ ->
            ct:pal("UNEXPECTED RESULT (explicit): ~p", [Result]),
            false
    end;

postcondition(_S, {call, _, sut_add_group, _}, {ok, _}) ->
    true;

postcondition(_S, {call, _, sut_add_group, _}, Result) ->
    ct:pal("add_group unexpected: ~p", [Result]),
    false;

postcondition(_S, {call, _, sut_add_user, _}, {ok, _}) ->
    true;

postcondition(_S, {call, _, sut_add_user, _}, Result) ->
    ct:pal("add_user unexpected: ~p", [Result]),
    false;

postcondition(_S, {call, _, sut_grant, _}, ok) ->
    true;

postcondition(_S, {call, _, sut_grant, _}, Result) ->
    ct:pal("grant unexpected: ~p", [Result]),
    false;

postcondition(_S, {call, _, sut_revoke, _}, ok) ->
    true;

postcondition(_S, {call, _, sut_revoke, _}, Result) ->
    ct:pal("revoke unexpected: ~p", [Result]),
    false;

postcondition(_S, {call, _, sut_add_user_to_group, _}, ok) ->
    true;

postcondition(_S, {call, _, sut_add_user_to_group, _}, Result) ->
    ct:pal("add_user_to_group unexpected: ~p", [Result]),
    false;

postcondition(_S, {call, _, sut_remove_group, _}, ok) ->
    true;

postcondition(_S, {call, _, sut_remove_group, _}, Result) ->
    ct:pal("remove_group unexpected: ~p", [Result]),
    false;

postcondition(_S, {call, _, sut_remove_user, _}, ok) ->
    true;

postcondition(_S, {call, _, sut_remove_user, _}, Result) ->
    ct:pal("remove_user unexpected: ~p", [Result]),
    false;

postcondition(_, _, _) ->
    true.



%% =============================================================================
%% MODEL FUNCTIONS (PURE)
%% =============================================================================



%% @private
role_exists(<<"all">>, _S) ->
    true;
role_exists(RoleName, #model{users = Users, groups = Groups}) ->
    NR = string:casefold(RoleName),
    maps:is_key(NR, Users) orelse maps:is_key(NR, Groups).


%% @private
model_role_key(<<"all">>, _S) ->
    {group, all};
model_role_key(RoleName, #model{users = Users}) ->
    NR = string:casefold(RoleName),
    case maps:is_key(NR, Users) of
        true -> {user, NR};
        false -> {group, NR}
    end.


%% @private
normalize_resource(any) -> any;
normalize_resource({Uri, Strategy}) -> {Uri, Strategy}.


%% @doc Compute transitive closure of group membership.
%% Returns all groups reachable from the given seed group names.
model_resolve_groups(GroupNames, GroupsMap) ->
    model_resolve_groups(GroupNames, GroupsMap, sets:new([{version, 2}])).


%% @private
model_resolve_groups([], _GroupsMap, Seen) ->
    sets:to_list(Seen);

model_resolve_groups([Name | Rest], GroupsMap, Seen) ->
    case sets:is_element(Name, Seen) of
        true ->
            model_resolve_groups(Rest, GroupsMap, Seen);
        false ->
            NewSeen = sets:add_element(Name, Seen),
            Parents = maps:get(Name, GroupsMap, []),
            model_resolve_groups(Parents ++ Rest, GroupsMap, NewSeen)
    end.


%% @doc Compute the full set of effective grants for a user.
%%
%% Effective grants = union of:
%% 1. 'all' group grants (always apply)
%% 2. Grants from all transitively reachable groups
%% 3. Direct user grants
model_effective_grants(Username, #model{
    groups = GroupsMap, users = Users, grants = Grants
}) ->
    %% 1. 'all' group grants
    AllGrants = maps:get({group, all}, Grants, #{}),

    %% 2. User's group memberships → transitive closure
    UserGroups = maps:get(Username, Users, []),
    ReachableGroups = model_resolve_groups(UserGroups, GroupsMap),

    %% 3. Accumulate grants from all reachable groups
    GroupGrantsAcc = lists:foldl(
        fun(GroupName, Acc) ->
            GGrants = maps:get({group, GroupName}, Grants, #{}),
            merge_grant_maps(Acc, GGrants)
        end,
        AllGrants,
        ReachableGroups
    ),

    %% 4. Direct user grants
    UserGrants = maps:get({user, Username}, Grants, #{}),
    merge_grant_maps(GroupGrantsAcc, UserGrants).


%% @private
merge_grant_maps(Map1, Map2) ->
    maps:fold(
        fun(Resource, Perms2, Acc) ->
            Perms1 = maps:get(Resource, Acc, []),
            maps:put(Resource, lists:usort(Perms1 ++ Perms2), Acc)
        end,
        Map1,
        Map2
    ).


%% @doc Compute effective grants for explicit group memberships (get_context/3).
%% Uses the provided groups instead of the user's stored groups.
%% Also includes 'all' group grants and direct user grants.
model_effective_grants_explicit(ExplicitGroups, #model{
    groups = GroupsMap, grants = Grants
}) ->
    %% 1. 'all' group grants
    AllGrants = maps:get({group, all}, Grants, #{}),

    %% 2. Transitive closure of explicit groups
    ReachableGroups = model_resolve_groups(ExplicitGroups, GroupsMap),

    %% 3. Accumulate grants from all reachable groups
    lists:foldl(
        fun(GroupName, Acc) ->
            GGrants = maps:get({group, GroupName}, Grants, #{}),
            merge_grant_maps(Acc, GGrants)
        end,
        AllGrants,
        ReachableGroups
    ).


%% @doc Check if a permission is authorized given the effective grants.
model_authorize(Permission, Resource, EffectiveGrants) ->
    maps:fold(
        fun
            (_, _, true) ->
                true;
            (GrantResource, Perms, false) ->
                grant_resource_matches(Resource, GrantResource)
                andalso lists:member(Permission, Perms)
        end,
        false,
        EffectiveGrants
    ).


%% @private
%% Does a grant on GrantResource cover an authorization check for Resource?
grant_resource_matches(any, any) ->
    true;
grant_resource_matches(_, any) ->
    %% 'any' grants only match when authorize is called with 'any'
    false;
grant_resource_matches(any, _) ->
    false;
grant_resource_matches(Resource, {Uri, Strategy}) when is_binary(Resource) ->
    bondy_wamp_uri:match(Resource, Uri, Strategy);
grant_resource_matches(_, _) ->
    false.



%% =============================================================================
%% SUT WRAPPERS
%% =============================================================================



sut_add_group(RealmUri, {Name, Parents}) ->
    Group = bondy_rbac_group:new(#{
        name => Name,
        groups => Parents,
        meta => #{}
    }),
    bondy_rbac_group:add(RealmUri, Group).


sut_add_user(RealmUri, {Username, Groups}) ->
    User = bondy_rbac_user:new(#{
        username => Username,
        groups => Groups,
        authorized_keys => []
    }),
    bondy_rbac_user:add(RealmUri, User).


sut_grant(RealmUri, RoleName, Resource, Permissions) ->
    UniquePerms = lists:usort(Permissions),
    GrantData = grant_request_data(RoleName, Resource, UniquePerms),
    bondy_rbac:grant(RealmUri, GrantData).


sut_revoke(RealmUri, RoleName, Resource, Permissions) ->
    UniquePerms = lists:usort(Permissions),
    GrantData = grant_request_data(RoleName, Resource, UniquePerms),
    bondy_rbac:revoke(RealmUri, GrantData).


sut_authorize(RealmUri, Username, Permission, Resource) ->
    Ctxt = bondy_rbac:get_context(RealmUri, Username),
    try
        ok = bondy_rbac:authorize(Permission, Resource, Ctxt),
        authorized
    catch
        error:{not_authorized, _} -> denied
    end.


sut_authorize_explicit(RealmUri, Username, ExplicitGroups, Permission, Resource) ->
    Ctxt = bondy_rbac:get_context(RealmUri, Username, ExplicitGroups),
    try
        ok = bondy_rbac:authorize(Permission, Resource, Ctxt),
        authorized
    catch
        error:{not_authorized, _} -> denied
    end.


sut_add_user_to_group(RealmUri, Username, GroupName) ->
    bondy_rbac_user:add_groups(RealmUri, Username, [GroupName]).


sut_remove_group(RealmUri, Name) ->
    bondy_rbac_group:remove(RealmUri, Name).


sut_remove_user(RealmUri, Username) ->
    bondy_rbac_user:remove(RealmUri, Username).


%% @private
grant_request_data(RoleName, Resource, Permissions) ->
    RolesVal = case RoleName of
        <<"all">> -> <<"all">>;
        _ -> [RoleName]
    end,
    Base = #{
        <<"permissions">> => Permissions,
        <<"roles">> => RolesVal
    },
    case Resource of
        any ->
            Base#{<<"uri">> => any};
        {Uri, Strategy} ->
            Base#{<<"uri">> => Uri, <<"match">> => Strategy}
    end.



%% =============================================================================
%% STATEFUL PROPERTY
%% =============================================================================



prop_rbac_statem(_Config) ->
    ensure_realm(?REALM),

    Prop = ?FORALL(
        Cmds,
        proper_statem:commands(?MODULE),
        begin
            cleanup_realm(?REALM),
            {History, State, Result} =
                proper_statem:run_commands(?MODULE, Cmds),
            ?WHENFAIL(
                ct:pal(
                    "~n=== STATEM FAILURE ===~n"
                    "Commands: ~p~n"
                    "History length: ~p~n"
                    "Final state: ~p~n"
                    "Result: ~p~n",
                    [Cmds, length(History), State, Result]
                ),
                Result =:= ok
            )
        end
    ),
    ?assert(proper:quickcheck(Prop, [
        {numtests, ?STATEM_NUMTESTS},
        {max_size, ?MAX_CMDS},
        quiet
    ])).



%% =============================================================================
%% STANDALONE FORALL PROPERTIES
%% =============================================================================



%% @doc Normalization transparency: authorization decisions must be identical
%% regardless of the case used for role names during grant operations.
%%
%% Grants via a mixed-case group name, then checks authorization. The result
%% must match authorization when the group was created with the lowercase name.
prop_normalization_transparency(_Config) ->
    Prop = ?FORALL(
        {Perms, CaseStyle},
        {gen_permissions(), elements([upper, capitalize])},
        begin
            UniquePerms = lists:usort(Perms),
            RealmUri = make_realm_uri(<<"norm">>),
            LowerGroup = <<"norm_test_group">>,
            LowerUser = <<"norm_test_user">>,
            MixedGroup = apply_case_style(CaseStyle, LowerGroup),

            _ = bondy_realm:create(#{
                uri => RealmUri,
                security_enabled => true,
                authmethods => [?TRUST_AUTH],
                groups => [#{name => LowerGroup}],
                users => [#{username => LowerUser,
                            groups => [LowerGroup]}]
            }),

            %% Grant using a mixed-case group name
            ok = bondy_rbac:grant(RealmUri, #{
                <<"permissions">> => UniquePerms,
                <<"uri">> => <<"com.norm.test">>,
                <<"match">> => <<"exact">>,
                <<"roles">> => [MixedGroup]
            }),

            %% Authorize with the normalized (lowercase) username
            C1 = bondy_rbac:get_context(RealmUri, LowerUser),
            Results = lists:map(
                fun(Perm) ->
                    try
                        ok = bondy_rbac:authorize(
                            Perm, <<"com.norm.test">>, C1
                        ),
                        true
                    catch
                        error:{not_authorized, _} -> false
                    end
                end,
                UniquePerms
            ),

            %% All permissions should be authorized
            lists:all(fun(R) -> R end, Results)
        end
    ),
    ?assert(proper:quickcheck(Prop, [
        {numtests, ?FORALL_NUMTESTS}, quiet
    ])).


%% @doc Grant monotonicity: adding a grant never removes existing permissions.
prop_grant_monotonicity(_Config) ->
    Prop = ?FORALL(
        {Perms1, Perms2},
        {gen_permissions(), gen_permissions()},
        begin
            P1 = lists:usort(Perms1),
            P2 = lists:usort(Perms2),
            RealmUri = make_realm_uri(<<"mono">>),
            GroupName = <<"mono_group">>,
            Username = <<"mono_user">>,

            _ = bondy_realm:create(#{
                uri => RealmUri,
                security_enabled => true,
                authmethods => [?TRUST_AUTH],
                groups => [#{name => GroupName}],
                users => [#{username => Username,
                            groups => [GroupName]}]
            }),

            GrantBase = #{
                <<"uri">> => <<"com.mono.">>,
                <<"match">> => <<"prefix">>,
                <<"roles">> => [GroupName]
            },

            %% Grant first set of permissions
            ok = bondy_rbac:grant(
                RealmUri, GrantBase#{<<"permissions">> => P1}
            ),

            C1 = bondy_rbac:get_context(RealmUri, Username),
            Before = [
                try
                    ok = bondy_rbac:authorize(
                        P, <<"com.mono.x">>, C1
                    ),
                    true
                catch
                    error:{not_authorized, _} -> false
                end
                || P <- P1
            ],

            %% Grant additional permissions
            ok = bondy_rbac:grant(
                RealmUri, GrantBase#{<<"permissions">> => P2}
            ),

            C2 = bondy_rbac:get_context(RealmUri, Username),
            After = [
                try
                    ok = bondy_rbac:authorize(
                        P, <<"com.mono.x">>, C2
                    ),
                    true
                catch
                    error:{not_authorized, _} -> false
                end
                || P <- P1
            ],

            %% Everything authorized before must still be authorized
            lists:all(
                fun({B, A}) -> (not B) orelse A end,
                lists:zip(Before, After)
            )
        end
    ),
    ?assert(proper:quickcheck(Prop, [
        {numtests, ?FORALL_NUMTESTS}, quiet
    ])).


%% @doc 'all' group universality: permissions granted to 'all' apply to every
%% user in the realm.
prop_all_group_universality(_Config) ->
    Prop = ?FORALL(
        {Perms, UserCount},
        {gen_permissions(), range(1, 5)},
        begin
            UniquePerms = lists:usort(Perms),
            RealmUri = make_realm_uri(<<"allg">>),
            UserNames = [
                <<"allg_u_", (integer_to_binary(I))/binary>>
                || I <- lists:seq(1, UserCount)
            ],

            _ = bondy_realm:create(#{
                uri => RealmUri,
                security_enabled => true,
                authmethods => [?TRUST_AUTH],
                users => [#{username => U} || U <- UserNames]
            }),

            %% Grant to 'all' group
            ok = bondy_rbac:grant(RealmUri, #{
                <<"permissions">> => UniquePerms,
                <<"uri">> => <<"com.allg.">>,
                <<"match">> => <<"prefix">>,
                <<"roles">> => <<"all">>
            }),

            %% Every user must be authorized
            lists:all(
                fun(Username) ->
                    C = bondy_rbac:get_context(RealmUri, Username),
                    lists:all(
                        fun(P) ->
                            try
                                ok = bondy_rbac:authorize(
                                    P, <<"com.allg.test">>, C
                                ),
                                true
                            catch
                                error:{not_authorized, _} -> false
                            end
                        end,
                        UniquePerms
                    )
                end,
                UserNames
            )
        end
    ),
    ?assert(proper:quickcheck(Prop, [
        {numtests, ?FORALL_NUMTESTS}, quiet
    ])).


%% @doc Prototype inheritance: child realm inherits prototype grants;
%% overriding a group in the child shadows the prototype group completely.
prop_prototype_inheritance(_Config) ->
    Prop = ?FORALL(
        Perms,
        gen_permissions(),
        begin
            UniquePerms = lists:usort(Perms),
            N = erlang:unique_integer([positive]),
            ProtoUri = <<"com.test.proto.",
                         (integer_to_binary(N))/binary>>,
            ChildUri = <<"com.test.child.",
                         (integer_to_binary(N))/binary>>,

            %% Create prototype with a group and grant
            _ = bondy_realm:create(#{
                uri => ProtoUri,
                is_prototype => true,
                security_enabled => true,
                authmethods => [?TRUST_AUTH],
                groups => [#{name => <<"inherited_grp">>}]
            }),

            ok = bondy_rbac:grant(ProtoUri, #{
                <<"permissions">> => UniquePerms,
                <<"uri">> => <<"com.proto.">>,
                <<"match">> => <<"prefix">>,
                <<"roles">> => [<<"inherited_grp">>]
            }),

            %% Create child realm using prototype
            _ = bondy_realm:create(#{
                uri => ChildUri,
                prototype_uri => ProtoUri,
                security_enabled => true,
                authmethods => [?TRUST_AUTH],
                users => [#{username => <<"proto_user">>,
                            groups => [<<"inherited_grp">>]}]
            }),

            %% User should have inherited permissions
            C1 = bondy_rbac:get_context(ChildUri, <<"proto_user">>),
            InheritedOk = lists:all(
                fun(P) ->
                    try
                        ok = bondy_rbac:authorize(
                            P, <<"com.proto.x">>, C1
                        ),
                        true
                    catch
                        error:{not_authorized, _} -> false
                    end
                end,
                UniquePerms
            ),

            %% Override the group in child realm (with no grants)
            _ = bondy_rbac_group:add(ChildUri,
                bondy_rbac_group:new(#{name => <<"inherited_grp">>})),

            %% After override, inherited permissions should be gone
            C2 = bondy_rbac:get_context(ChildUri, <<"proto_user">>),
            OverrideOk = lists:all(
                fun(P) ->
                    try
                        bondy_rbac:authorize(
                            P, <<"com.proto.x">>, C2
                        ),
                        false
                    catch
                        error:{not_authorized, _} -> true
                    end
                end,
                UniquePerms
            ),

            InheritedOk andalso OverrideOk
        end
    ),
    ?assert(proper:quickcheck(Prop, [
        {numtests, 20}, quiet
    ])).


%% @doc Explicit groups normalization: get_context/3 with mixed-case explicit
%% group names must produce the same authorization as with normalized names.
%%
%% This tests the fix where get_context/3 now normalizes ExplicitGroups.
prop_explicit_groups_normalization(_Config) ->
    Prop = ?FORALL(
        {Perms, CaseStyle},
        {gen_permissions(), elements([upper, capitalize])},
        begin
            UniquePerms = lists:usort(Perms),
            RealmUri = make_realm_uri(<<"explg">>),
            GroupName = <<"explicit_test_grp">>,

            _ = bondy_realm:create(#{
                uri => RealmUri,
                security_enabled => true,
                authmethods => [?TRUST_AUTH],
                groups => [#{name => GroupName}]
            }),

            ok = bondy_rbac:grant(RealmUri, #{
                <<"permissions">> => UniquePerms,
                <<"uri">> => <<"com.explg.">>,
                <<"match">> => <<"prefix">>,
                <<"roles">> => [GroupName]
            }),

            MixedGroupName = apply_case_style(CaseStyle, GroupName),

            %% Context with normalized group name
            C1 = bondy_rbac:get_context(
                RealmUri, <<"ext_user">>, [GroupName]
            ),
            R1 = [
                try
                    ok = bondy_rbac:authorize(
                        P, <<"com.explg.test">>, C1
                    ),
                    true
                catch
                    error:{not_authorized, _} -> false
                end
                || P <- UniquePerms
            ],

            %% Context with mixed-case group name
            C2 = bondy_rbac:get_context(
                RealmUri, <<"ext_user">>, [MixedGroupName]
            ),
            R2 = [
                try
                    ok = bondy_rbac:authorize(
                        P, <<"com.explg.test">>, C2
                    ),
                    true
                catch
                    error:{not_authorized, _} -> false
                end
                || P <- UniquePerms
            ],

            %% Both must give identical results
            R1 =:= R2
        end
    ),
    ?assert(proper:quickcheck(Prop, [
        {numtests, ?FORALL_NUMTESTS}, quiet
    ])).



%% =============================================================================
%% HELPERS
%% =============================================================================



%% @private
make_realm_uri(Prefix) ->
    N = erlang:unique_integer([positive]),
    <<"com.test.proper.", Prefix/binary, ".",
      (integer_to_binary(N))/binary>>.


%% @private
ensure_realm(RealmUri) ->
    case bondy_realm:exists(RealmUri) of
        true -> ok;
        false ->
            _ = bondy_realm:create(#{
                uri => RealmUri,
                security_enabled => true,
                authmethods => [?TRUST_AUTH]
            }),
            ok
    end.


%% @private
cleanup_realm(RealmUri) ->
    %% Remove all grants (user and group)
    _ = (catch bondy_rbac:remove_all(RealmUri, #{})),
    %% Remove all custom users
    lists:foreach(
        fun(User) ->
            catch bondy_rbac_user:remove(
                RealmUri, bondy_rbac_user:username(User)
            )
        end,
        try bondy_rbac_user:list(RealmUri) catch _:_ -> [] end
    ),
    %% Remove all custom groups
    lists:foreach(
        fun(Group) ->
            catch bondy_rbac_group:remove(
                RealmUri, bondy_rbac_group:name(Group)
            )
        end,
        try bondy_rbac_group:list(RealmUri) catch _:_ -> [] end
    ),
    ok.


%% @private
apply_case_style(upper, Bin) ->
    unicode:characters_to_binary(string:uppercase(Bin));
apply_case_style(capitalize, Bin) ->
    capitalize_first(Bin).
