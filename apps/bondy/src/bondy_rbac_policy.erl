%% =============================================================================
%%  bondy_rbac_policy.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%  Copyright (c) 2013 Basho Technologies, Inc.
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

%% -----------------------------------------------------------------------------
%% @doc
%% **Note:**
%% Usernames and group names are stored in lower case. All functions in this
%% module are case sensitice so when using the functions in this module make
%% sure the inputs you provide are in lowercase to. If you need to convert your
%% input to lowercase use {@link string:casefold/1}.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rbac_policy).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").


-define(POLICY_VALIDATOR, #{
    <<"uri">> => #{
        alias => uri,
		key => uri,
        required => true,
        allow_null => false,
        datatype => [binary, {in, [any]}],
        validator => fun bondy_data_validators:policy_resource/1
    },
    <<"match">> => #{
        alias => match,
		key => match,
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => {in, [<<"exact">>, <<"prefix">>, <<"wildcard">>]}
    },
    <<"permissions">> => #{
        alias => permissions,
		key => permissions,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => list,
        validator => {list, fun bondy_data_validators:permission/1}
    },
    <<"roles">> => #{
        alias => roles,
		key => roles,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun bondy_data_validators:rolenames/1
    }
}).

-define(VERSION, <<"1.1">>).
-define(USER_GRANTS_PREFIX(RealmUri),   {security_user_grants, RealmUri}).
-define(GROUP_GRANTS_PREFIX(RealmUri),  {security_group_grants, RealmUri}).
-define(PLUMDB_PREFIX(RealmUri, Type),
    case Type of
        user -> ?USER_GRANTS_PREFIX(RealmUri);
        group -> ?GROUP_GRANTS_PREFIX(RealmUri)
    end
).
-define(FOLD_OPTS, [{resolver, lww}]).


-type t()       ::  #{
    type                :=  policy,
    version             :=  binary(),
    uri                 :=  binary(),
    match               :=  binary(),
    resource            :=  any | {binary(), binary()},
    roles               :=  [binary()],
    permissions         :=  [binary()]
}.

-type resource()        ::  any
                            | binary()
                            | {Uri :: uri(), MatchStrategy :: binary()}.
-type external()        ::  t().
-type permission()      ::  [{any(), any()}].

-export_type([external/0]).
-export_type([permission/0]).
-export_type([resource/0]).
-export_type([t/0]).

-export([grant/2]).
-export([group_permissions/2]).
-export([new/1]).
-export([permissions/3]).
-export([revoke/2]).
-export([revoke_group/2]).
-export([revoke_user/2]).
-export([to_external/1]).
-export([user_permissions/2]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Validates the data for a grant or revoke request.
%% @end
%% -----------------------------------------------------------------------------
-spec new(Data :: map()) -> Policy :: map() | no_return().

new(Data) ->
    Policy0 = maps_utils:validate(Data, ?POLICY_VALIDATOR),
    Policy = validate_uri_match(Policy0),
    type_and_version(Policy).


%% -----------------------------------------------------------------------------
%% @doc
%%
%% **Use cases**
%%
%% * grant <permissions> on any to all|{<user>|<group>[,...]}
%% * grant <permissions> on {<resource>, <exact|prefix|wildcard>} to all|{<user>|<group>[,...]}

%% @end
%% -----------------------------------------------------------------------------
-spec grant(RealmUri :: uri(), Map0 :: map()) -> ok | {error, Reason :: any()}.

grant(RealmUri, Data) when is_map(Data) ->
    bondy_realm:exists(RealmUri) orelse error({no_such_realm, RealmUri}),
    #{
        uri := Uri,                     % uri() | 'any'
        match := Strategy,
        roles := Roles,                 % [Groupname, Username | 'all']
        permissions := Permissions
    } = new(Data),

    Resource = normalise_resource(Uri, Strategy),
    grant(RealmUri, Roles, Resource, Permissions).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke(RealmUri :: uri(), Map0 :: map()) -> ok | {error, Reason :: any()}.

revoke(RealmUri, Data) when is_map(Data) ->
    #{
        uri := Uri,
        match := Strategy,
        roles := Roles,
        permissions := Permissions
    } = new(Data),
    Resource = normalise_resource(Uri, Strategy),
    revoke(RealmUri, Roles, Resource, Permissions).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
revoke_user(RealmUri, Username) ->
    Prefix = ?USER_GRANTS_PREFIX(RealmUri),
    plum_db:fold(
        fun({Key, _Value}, Acc) ->
            %% destructive iteration is allowed
            ok = plum_db:delete(Prefix, Key),
            Acc
        end,
        ok,
        Prefix,
        [{match, {Username, '_'}}, {resolver, lww}]
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
revoke_group(RealmUri, Name) ->
    Prefix = ?GROUP_GRANTS_PREFIX(RealmUri),

    plum_db:fold(
        fun({Key, _Value}, Acc) ->
            %% destructive iteration is allowed
            ok = plum_db:delete(Prefix, Key),
            Acc
        end,
        ok,
        Prefix,
        [{match, {Name, '_'}}, {resolver, lww}]
    ).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec permissions(
    RealmUri :: uri(), Name :: binary(), RoleType :: user | group) ->
    [t()].

permissions(RealmUri, Name, Type) ->
    group_grants(accumulate_grants(RealmUri, Name, Type)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec user_permissions(RealmUri :: uri(), Username :: binary()) -> [t()].

user_permissions(RealmUri, Username) ->
    permissions(RealmUri, Username, user).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec group_permissions(RealmUri :: uri(), Name :: binary()) -> [t()].

group_permissions(RealmUri, Name) ->
    permissions(RealmUri, Name, group).


%% -----------------------------------------------------------------------------
%% @doc Returns the external representation of the policy `Policy'.
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(Policy :: t()) -> external().

to_external(#{type := policy, version := ?VERSION} = Policy) ->
    Policy.



%% =============================================================================
%% PRIVATE
%% =============================================================================



validate_uri_match(#{uri := <<"*">>} = P) ->
    validate_uri_match(P#{uri => <<>>});

validate_uri_match(#{uri := any, match := undefined} = P) ->
    P;

validate_uri_match(#{uri := any, match := _} = P) ->
    maps:put(match, undefined, P);

validate_uri_match(#{uri := <<>>, match := undefined} = P) ->
    P#{match => ?PREFIX_MATCH};

validate_uri_match(#{uri := <<>>, match := ?PREFIX_MATCH} = P) ->
    P;

validate_uri_match(#{uri := <<>>, match := _}) ->
    inconsistency_error([<<"uri">>, <<"match">>]);

validate_uri_match(#{uri := Uri, match := undefined} = P) ->
    %% We try to derive the missing strategy from the URI
    maps:put(match, derive_strategy(Uri), P);

validate_uri_match(#{uri := Uri, match := S} = P) ->
    Uri = wamp_uri:validate(Uri, S),
    P.


%% @private
type_and_version(Map) ->
    Map#{
        version => ?VERSION,
        type => policy
    }.



%% @private

normalise_resource(any, _) ->
    any;

normalise_resource(Uri, Strategy) ->
    {Uri, Strategy}.






% @private
derive_strategy(Uri) ->
    derive_strategy(Uri, [?EXACT_MATCH, ?WILDCARD_MATCH, ?PREFIX_MATCH]).


% @private
derive_strategy(Uri, [H|T]) ->
    case wamp_uri:is_valid(Uri, H) of
        true ->
            H;
        false ->
            derive_strategy(Uri, T)
    end;

derive_strategy(_, []) ->
    error(bondy_error:map({missing_required_value, <<"match">>})).


% @private
inconsistency_error(Keys) ->
    error(bondy_error:map({inconsistency_error, Keys})).


%% -----------------------------------------------------------------------------
%% @private
%% @doc Grant permissions to one or more roles(
%% @end
%% -----------------------------------------------------------------------------
-spec grant(binary(), all | [binary()], resource(), [binary()]) ->
    ok | {error, term()}.

grant(RealmUri, Keyword, Resource, Permissions)
when Keyword == all orelse Keyword == anonymous->
    do_grant([{Keyword, group}], RealmUri, Resource, Permissions);

grant(RealmUri, RoleList0, Resource, Permissions) ->
    {Anon, RoleList} = lists:splitwith(
        fun
            (anonymous) -> true;
            (<<"anonymous">>) -> true;
            (_) -> false
        end,
        RoleList0
    ),

    _ = length(Anon) > 0 andalso
        grant(RealmUri, anonymous, Resource, Permissions),


    RoleTypes = lists:map(
        fun(Role) ->
            {chop_name(Role), role_type(RealmUri, Role)}
        end,
        RoleList
    ),

    UnknownRoles = lists:foldl(
        fun
            ({Name, unknown}, Accum) -> Accum ++ [Name];
            ({_Name, _Type}, Accum) -> Accum
        end,
        [],
        RoleTypes
    ),

    NameOverlaps = lists:foldl(
        fun
            ({Name, both}, Accum) -> Accum ++ [Name];
            ({_Name, _Type}, Accum) -> Accum
        end,
        [],
        RoleTypes
    ),

    case check_grant_blockers(UnknownRoles, NameOverlaps) of
        none ->
            do_grant(RoleTypes, RealmUri, Resource, Permissions);
        Error ->
            Error
    end.


%% @private
do_grant([], _, _, _) ->
    ok;

do_grant([{RoleName, RoleType} | T], RealmUri, Resource, Permissions0) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri, RoleType),

    %% We store the list of permissions as the value
    Existing = case plum_db:get(Prefix, {RoleName, Resource}) of
        undefined -> [];
        List -> List
    end,

    %% We deduplicate
    Permissions1 = lists:umerge(lists:sort(Existing), lists:sort(Permissions0)),

    %% We store the updated list of permissions
    Key = {RoleName, Resource},

    ok = plum_db:put(Prefix, Key, Permissions1),

    do_grant(T, RealmUri, Resource, Permissions0).




%% -----------------------------------------------------------------------------
%% @doc Revoke permissions to one or more roles
%% @end
%% -----------------------------------------------------------------------------
-spec revoke(
    RealmUri :: binary(),
    Roles :: all | [binary()],
    Resource :: resource(),
    Permissions :: [uri()]) -> ok | {error, term()}.

revoke(RealmUri, all, Resource, Permissions)  ->
    %% all and anonymous are always valid
    do_revoke([{all, group}], RealmUri, Resource, Permissions);

revoke(RealmUri, RoleList, Resource, Permissions) ->
    RoleTypes = lists:map(
        fun(Name) ->
            {chop_name(Name), role_type(RealmUri, Name)}
        end,
        RoleList
    ),

    UnknownRoles = lists:foldl(
        fun
            ({Name, unknown}, Accum) ->
                Accum ++ [Name];
            ({_Name, _Type}, Accum) ->
                Accum
        end,
        [],
        RoleTypes
    ),

    NameOverlaps = lists:foldl(
        fun
            ({Name, both}, Accum) ->
                Accum ++ [Name];
            ({_Name, _Type}, Accum) ->
                Accum
        end,
        [],
        RoleTypes
    ),

    case check_grant_blockers(UnknownRoles, NameOverlaps) of
        none ->
            do_revoke(RoleTypes, RealmUri, Resource, Permissions);
        Error ->
            Error
    end.


do_revoke([], _, _, _) ->
    ok;

do_revoke([{Name, RoleType}|Roles], RealmUri, Resource, Permissions) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri, RoleType),

    %% check if there is currently a GRANT we can revoke
    case plum_db:get(Prefix, {Name, Resource}) of
        undefined ->
            %% can't REVOKE what wasn't GRANTED
            do_revoke(Roles, RealmUri, Resource, Permissions);
        GrantedPerms ->
            NewPerms = [
                X
                || X <- GrantedPerms, not lists:member(X, Permissions)
            ],

            %% TODO - do deletes here, once cluster metadata supports it for
            %% real, if NewPerms == []

            case NewPerms of
                [] ->
                    plum_db:delete(Prefix, {Name, Resource});
                _ ->
                    plum_db:put(Prefix, {Name, Resource}, NewPerms)
            end,
            do_revoke(Roles, RealmUri, Resource, Permissions)
    end.


%% @private
chop_name(<<"user/", Name/binary>>) ->
    Name;
chop_name(<<"group/", Name/binary>>) ->
    Name;
chop_name(Name) ->
    Name.


%% When we need to know whether a role name is a group or user (or
%% both), use this
role_type(RealmUri, <<"user/", Name/binary>>) ->
    do_role_type(
        bondy_rbac_user:lookup(RealmUri, Name),
        undefined
    );
role_type(RealmUri, <<"group/", Name/binary>>) ->
    do_role_type(
        undefined,
        bondy_rbac_group:lookup(RealmUri, Name)
    );

role_type(RealmUri, Name) ->
    do_role_type(
        bondy_rbac_user:lookup(RealmUri, Name),
        bondy_rbac_group:lookup(RealmUri, Name)
    ).

%% @private
do_role_type({error, not_found}, undefined) ->
    unknown;

do_role_type(_, {error, not_found}) ->
    user;

do_role_type({error, not_found}, _) ->
    group;

do_role_type(_, _) ->
    both.


%% @private
check_grant_blockers([], []) ->
    none;

check_grant_blockers(UnknownRoles, []) ->
    {error, {unknown_roles, UnknownRoles}};


check_grant_blockers([], NameOverlaps) ->
    {error, {duplicate_roles, NameOverlaps}};

check_grant_blockers(UnknownRoles, NameOverlaps) ->
    {error, [
        {unknown_roles, UnknownRoles},
        {duplicate_roles, NameOverlaps}
    ]}.


%% @private
accumulate_grants(RealmUri, Role, Type) ->
    %% The 'all' grants always apply
    Acc0 = lists:map(
        fun({{_Role, Resource}, Permissions}) ->
            {{<<"group/all">>, Resource}, Permissions}
        end,
        match_grants(RealmUri, {all, '_'}, group)
    ),

    {Acc1, _} = accumulate_grants([Role], [], Acc0, Type, RealmUri),
    lists:flatten(Acc1).


%% @private
accumulate_grants([], Seen, Acc, _Type, _) ->
    {Acc, Seen};

accumulate_grants([Rolename|Rolenames], Seen, Acc, Type, RealmUri) ->
    Groups = [Name ||
        Name <- role_groups(RealmUri, Rolename, Type),
        not lists:member(Name, Seen),
        bondy_rbac_group:exists(RealmUri, Name)
    ],

    %% We iterate over the role's groups to gather grants (permissions)
    %% assigned to this role via the group membership relationship.
    %% We avoid iterating over already seen role groups. This is because group
    %% membership is recursive and a group can be a member of another group
    %% multiple times through different paths.
    {NewAcc, NewSeen} = accumulate_grants(
        Groups, [Rolename|Seen], Acc, group, RealmUri
    ),

    %% We gather the grants associated directly to this role
    Grants = lists:map(
        fun ({{_, Resource}, Permissions}) ->
            {{concat_role(Type, Rolename), Resource}, Permissions}
        end,
        match_grants(RealmUri, {Rolename, '_'}, Type)
    ),

    %% We continue iterating over the roles
    accumulate_grants(Rolenames, NewSeen, [Grants|NewAcc], Type, RealmUri).


%% @private
role_groups(RealmUri, Rolename, user) ->
    case bondy_rbac_user:lookup(RealmUri, Rolename) of
        {error, not_found} -> [];
        User -> bondy_rbac_user:groups(User)
    end;

role_groups(RealmUri, Rolename, group) ->
    case bondy_rbac_group:lookup(RealmUri, Rolename) of
        {error, not_found} -> [];
        Group -> bondy_rbac_group:groups(Group)
    end.


% match_grants(Realm, Match, Type) ->
%     Opts = [{match, Match}, {resolver, lww}],
%     Grants = plum_db:to_list(?PLUMDB_PREFIX(Realm, Type), Opts),
%     %% [{Key, Val} || {Key, [Val]} <- Grants, Val /= ?TOMBSTONE].
%     [{Key, Val} || {Key, Val} <- Grants, Val /= [?TOMBSTONE]].

%% @private
match_grants(Realm, KeyPattern, Type) ->
    Opts = [{resolver, lww}, {remove_tombstones, true}],
    plum_db:match(?PLUMDB_PREFIX(Realm, Type), KeyPattern, Opts).


%% @private
concat_role(user, Name) ->
    <<"user/", Name/binary>>;

concat_role(group, anonymous) ->
    <<"group/anonymous">>;

concat_role(group, Name) ->
    <<"group/", Name/binary>>.


%% @private
group_grants(Grants) ->
    D = lists:foldl(
        fun({{_Role, Resource}, Permissions}, Acc) ->
            dict:append(Resource, Permissions, Acc)
        end,
        dict:new(),
        Grants
    ),
    [
        {Resource, lists:usort(lists:flatten(ListOfLists))}
        || {Resource, ListOfLists} <- dict:to_list(D)
    ].


%% @private
% on_create(RealmUri, Name) ->
%     ok = bondy_event_manager:notify(
%         {security_grant_added, RealmUri, Name}
%     ),
%     ok.


% %% @private
% on_update(RealmUri, Name) ->
%     ok = bondy_event_manager:notify(
%         {security_grant_updated, RealmUri, Name}
%     ),
%     ok.


% %% @private
% on_delete(RealmUri, Name) ->
%     ok = bondy_event_manager:notify(
%         {security_grant_deleted, RealmUri, Name}
%     ),
%     ok.
