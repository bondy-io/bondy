%% =============================================================================
%%  bondy_rbac.erl -
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
%% ### WAMP Permissions:
%%
%% * "wamp.register"
%% * "wamp.unregister"
%% * "wamp.call"
%% * "wamp.cancel"
%% * "wamp.subscribe"
%% * "wamp.unsubscribe"
%% * "wamp.publish"
%% * "wamp.disclose_caller"
%% * "wamp.disclose_publisher"
%%
%% ### Reserved Names
%% Reserved names are role (user or group) or resource names that act as
%% keywords in RBAC in either binary or atom forms and thus cannot be used.
%%
%% The following is the list of all reserved names.
%%
%% * all - group
%% * anonymous - the anonymous user and group
%% * any - use to denote a resource
%% * from - use to denote a resource
%% * on - not used
%% * to - use to denote a resource
%% %% **Note:**
%% Usernames and group names are stored in lower case. All functions in this
%% module are case sensitice so when using the functions in this module make
%% sure the inputs you provide are in lowercase to. If you need to convert your
%% input to lowercase use {@link string:casefold/1}.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rbac).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").


-define(GRANT_REQ_VALIDATOR_V1, ?GRANT_RESOURCE_VALIDATOR#{
    <<"roles">> => #{
        alias => roles,
		key => roles,
        required => true,
        validator => fun bondy_data_validators:rolenames/1
    },
    <<"permissions">> => #{
        alias => permissions,
		key => permissions,
        required => true,
        datatype => list,
        validator => {list, fun permission_validator/1}
    }
}).

-define(GRANT_REQ_VALIDATOR_V2, #{
    <<"roles">> => #{
        alias => roles,
		key => roles,
        required => true,
        validator => fun bondy_data_validators:rolenames/1
    },
    <<"permissions">> => #{
        alias => permissions,
		key => permissions,
        required => true,
        datatype => list,
        validator => {list, fun permission_validator/1}
    },
    <<"resources">> => #{
        alias => resources,
		key => resources,
        required => true,
        datatype => list,
        validator => {list, ?GRANT_RESOURCE_VALIDATOR}
    }
}).

-define(GRANT_RESOURCE_VALIDATOR, #{
    <<"uri">> => #{
        alias => uri,
		key => uri,
        required => true,
        datatype => [binary, {in, [any]}],
        validator => fun resource_validator/1
    },
    <<"match">> => #{
        alias => match,
		key => match,
        required => true,
        allow_undefined => true,
        default => undefined,
        datatype => {in, [<<"exact">>, <<"prefix">>, <<"wildcard">>]}
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

-ifdef(TEST).
-define(CTXT_REFRESH_TIME, 1).
-else.
-define(CTXT_REFRESH_TIME, 1000).
-endif.

-record(bondy_rbac_context, {
    realm_uri               ::  binary(),
    username                ::  binary(),
    grants                  ::  [grant()],
    epoch                   ::  erlang:timestamp(),
    is_anonymous = false    ::  boolean()
}).

-type context()             ::  #bondy_rbac_context{}.
-type permission()          ::  binary().
-type resource()            ::  any
                                | binary()  % <<"any">>
                                | #{uri := binary(), strategy := binary()}
                                | normalised_resource().
-type normalised_resource() ::  any | {Uri :: uri(), MatchStrategy :: binary()}.
-type rolename()            ::  all
                                | bondy_rbac_user:username()
                                | bondy_rbac_group:name().
-type request_data()        ::  map().
-type request()             ::  #{
    type                :=  request,
    roles               :=  [rolename()],
    permissions         :=  [binary()],
    resources           :=  [normalised_resource()]
}.
-type grant()               ::  {
                                    normalised_resource(),
                                    [Permission :: permission()]
                                }.

-export_type([context/0]).
-export_type([grant/0]).
-export_type([permission/0]).
-export_type([request/0]).
-export_type([request_data/0]).
-export_type([resource/0]).

-export([authorize/3]).
-export([get_anonymous_context/1]).
-export([get_anonymous_context/2]).
-export([get_context/1]).
-export([get_context/2]).
-export([is_reserved_name/1]).
-export([normalize_name/1]).
-export([grant/2]).
-export([group_grants/2]).
-export([request/1]).
-export([grants/3]).
-export([revoke/2]).
-export([revoke_group/2]).
-export([revoke_user/2]).
-export([user_grants/2]).




%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc Returns 'ok' or an exception.
%% @end
%% -----------------------------------------------------------------------------
-spec authorize(binary(), binary(), bondy_context:t() | context()) ->
    ok | no_return().

authorize(Permission, Resource, #bondy_rbac_context{} = Ctxt) ->
    do_authorize(Permission, Resource, Ctxt);

authorize(Permission, Resource, Ctxt) ->
    case bondy_context:is_security_enabled(Ctxt) of
        true ->
            %% TODO We need to cache the RBAC Context in the Bondy Context
            SecurityCtxt = get_context(Ctxt),
            do_authorize(Permission, Resource, SecurityCtxt);
        false ->
            ok
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_context(Ctxt :: bondy_context:t()) -> context().

get_context(Ctxt) ->
    case bondy_context:is_anonymous(Ctxt) of
        true ->
            get_anonymous_context(Ctxt);
        false ->
            AuthId = bondy_context:authid(Ctxt),
            RealmUri = bondy_context:realm_uri(Ctxt),
            get_context(RealmUri, AuthId)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_anonymous_context(Ctxt :: bondy_context:t()) -> context().

get_anonymous_context(Ctxt) ->
    case bondy_config:get([security, allow_anonymous_user], true) of
        true ->
            AuthId = bondy_context:authid(Ctxt),
            RealmUri = bondy_context:realm_uri(Ctxt),
            get_anonymous_context(RealmUri, AuthId);
        false ->
            error({not_authorized, <<"Anonymous user not allowed.">>})
    end.


%% -----------------------------------------------------------------------------
%% @doc Contexts are only valid until the GRANT epoch changes, and it will
%% change whenever a GRANT or a REVOKE is performed. This is a little coarse
%% grained right now, but it'll do for the moment.
%% @end
%% -----------------------------------------------------------------------------

get_context(RealmUri, Username)
when is_binary(Username) orelse Username == anonymous ->
    #bondy_rbac_context{
        realm_uri = RealmUri,
        username = Username,
        grants = grants(RealmUri, Username, user),
        epoch = erlang:timestamp(),
        is_anonymous = Username == anonymous
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
get_anonymous_context(RealmUri, Username) ->
    #bondy_rbac_context{
        realm_uri = RealmUri,
        username = Username,
        grants = grants(RealmUri, anonymous, group),
        epoch = erlang:timestamp(),
        is_anonymous = true
    }.


%% -----------------------------------------------------------------------------
%% @doc Returns true if term is a reserved name in binary or atom form.
%%
%% **Reserved names:**
%%
%% * all
%% * anonymous
%% * any
%% * from
%% * on
%% * to
%%
%% @end
%% -----------------------------------------------------------------------------
-spec is_reserved_name(Term :: binary() | atom()) -> boolean() | no_return().

is_reserved_name(Term) when is_binary(Term) ->
    try binary_to_existing_atom(Term, utf8) of
        Atom -> is_reserved_name(Atom)
    catch
        _:_ ->
            false
    end;

is_reserved_name(anonymous) ->
    true;

is_reserved_name(all) ->
    true;

is_reserved_name(on) ->
    true;

is_reserved_name(to) ->
    true;

is_reserved_name(from) ->
    true;

is_reserved_name(any) ->
    true;

is_reserved_name(Term) when is_atom(Term) ->
    false;

is_reserved_name(_) ->
    error(invalid_name).


%% -----------------------------------------------------------------------------
%% @doc Normalizes the utf8 binary `Bin' into a Normalized Form of compatibly
%% equivalent Decomposed characters according to the Unicode standard and
%% converts it to a case-agnostic comparable string.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec normalize_name(Term :: binary() | atom()) -> boolean() | no_return().

normalize_name(Bin) when is_binary(Bin) ->
    string:casefold(unicode:characters_to_nfkd_binary(Bin)).


%% -----------------------------------------------------------------------------
%% @doc Validates the data for a grant or revoke request.
%% @end
%% -----------------------------------------------------------------------------
-spec request(Data :: request_data()) -> Request :: request() | no_return().

request(Data) ->
    validate(Data).


%% -----------------------------------------------------------------------------
%% @doc
%% **Use cases**
%%
%% ```
%% grant <permissions> on any to all|{<user>|<group>[,...]}
%% grant <permissions> on {<resource>, <exact|prefix|wildcard>} to all|{<user>|<group>[,...]}
%% '''
%% @end
%% -----------------------------------------------------------------------------
-spec grant(RealmUri :: uri(), Request :: request() | map()) ->
    ok | {error, Reason :: any()} | no_return().

grant(RealmUri, #{type := request} = Request) ->
    bondy_realm:exists(RealmUri) orelse error({no_such_realm, RealmUri}),
    #{
        roles := Roles,
        permissions := Permissions,
        resources := Resources
    } = Request,

    grant(RealmUri, Roles, Resources, Permissions);

grant(RealmUri, Data) when is_map(Data) ->
    grant(RealmUri, request(Data)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke(RealmUri :: uri(), Request :: request() | map()) ->
    ok | {error, Reason :: any()} | no_return().

revoke(RealmUri, #{type := request} = Request) ->
    bondy_realm:exists(RealmUri) orelse error({no_such_realm, RealmUri}),
    #{
        roles := Roles,
        permissions := Permissions,
        resources := Resources
    } = Request,
    revoke(RealmUri, Roles, Resources, Permissions);

revoke(RealmUri, Data) when is_map(Data) ->
    revoke(RealmUri, validate(Data)).


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
-spec grants(
    RealmUri :: uri(), Name :: binary(), RoleType :: user | group) ->
    [grant()].

grants(RealmUri, Name, Type) ->
    group_grants(accumulate_grants(RealmUri, Name, Type)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec user_grants(RealmUri :: uri(), Username :: binary()) -> [grant()].

user_grants(RealmUri, Username) ->
    grants(RealmUri, Username, user).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec group_grants(RealmUri :: uri(), Name :: binary()) -> [grant()].

group_grants(RealmUri, Name) ->
    grants(RealmUri, Name, group).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec check_permission(Permission :: permission(), Context :: context()) ->
    {true, context()} | {false, binary(), context()}.

check_permission(
    {Permission}, #bondy_rbac_context{realm_uri = Uri} = Context0) ->
    Context = maybe_refresh_context(Uri, Context0),
    %% The user needs to have this permission applied *globally*
    %% This is for things with undetermined inputs or
    %% permissions that don't tie to a particular resource, like 'ping' and
    %% 'stats'.
    MatchG = match_grants(any, Context#bondy_rbac_context.grants),
    case lists:member(Permission, MatchG) of
        true ->
            {true, Context};
        false ->
            %% no applicable grant
            Mssg = permission_denied_message(Permission, any, Context),
            {false, Mssg, Context}
    end;

check_permission(
    {Permission, Resource}, #bondy_rbac_context{realm_uri = Uri} = Ctxt0) ->
    Ctxt = maybe_refresh_context(Uri, Ctxt0),
    MatchG = match_grants(Resource, Ctxt#bondy_rbac_context.grants),
    case lists:member(Permission, MatchG) of
        true ->
            {true, Ctxt};
        false ->
            %% no applicable grant
            Mssg = permission_denied_message(Permission, Resource, Ctxt),
            {false, Mssg, Ctxt}
    end.



%% =============================================================================
%% PRIVATE: AUTHORIZATION
%% =============================================================================



%% @private
do_authorize(Permission, Resource, SecCtxt) ->
    %% We could be cashing the security ctxt,
    %% the data is in ets so it should be pretty fast.
    case check_permission({Permission, Resource}, SecCtxt) of
        {true, _SecCtxt1} ->
            ok;
        {false, Mssg, _SecCtxt1} ->
            error({not_authorized, Mssg})
    end.


%% @private
maybe_refresh_context(RealmUri, Context) ->
    %% TODO replace this with a cluster metadata hash check, or something
    Epoch = erlang:timestamp(),
    Diff = timer:now_diff(Epoch, Context#bondy_rbac_context.epoch),

    case Diff < ?CTXT_REFRESH_TIME of
        false when Context#bondy_rbac_context.is_anonymous ->
            %% context has expired
            get_anonymous_context(
                RealmUri, Context#bondy_rbac_context.username
            );
        false ->
            %% context has expired
            get_context(RealmUri, Context#bondy_rbac_context.username);
        _ ->
            Context
    end.


%% @private
match_grants(Resource, Grants) ->
    match_grants(Resource, Grants, []).


%% @private
match_grants(any, Grants, Acc) ->
    case lists:keyfind(any, 1, Grants) of
        {any, Permissions} ->
            Acc ++ Permissions;
        false ->
            Acc
    end;

match_grants(Resource, Grants, Acc) ->
    %% find the first grant that matches the resource name
    %% and then merge in the 'any' grants, if any
    Fun = fun
        ({{Uri, Strategy}, Permissions}, IAcc) ->
            case wamp_uri:match(Resource, Uri, Strategy) of
                true ->
                    Permissions ++ IAcc;
                false ->
                    IAcc
            end;
        (_, IAcc) ->
            IAcc
    end,
    lists:umerge(
        lists:sort(lists:foldl(Fun, Acc, Grants)),
        lists:sort(match_grants(any, Grants))
    ).


%% @private
to_bin(anonymous) -> <<"anonymous">>;
to_bin(Bin) when is_binary(Bin) -> Bin.



%% @private
resource_to_iolist({Type, Bucket}) ->
    [Type, "/", Bucket];
resource_to_iolist(any) ->
    "any";
resource_to_iolist(Bucket) ->
    Bucket.


%% @private
permission_denied_message(
    Permission, Resource, #bondy_rbac_context{is_anonymous = false} = Ctxt) ->
    Username = to_bin(Ctxt#bondy_rbac_context.username),
    unicode:characters_to_binary(
        [
            "Permission denied. ",
            "User '", Username,
            "' does not have permission '",
            Permission, "' on '", resource_to_iolist(Resource), "'"
        ],
        utf8,
        utf8
    );

permission_denied_message(
    Permission, Resource, #bondy_rbac_context{is_anonymous = true} = Ctxt) ->
    Username = to_bin(Ctxt#bondy_rbac_context.username),
    unicode:characters_to_binary(
        [
            "Permission denied. ",
            "Anonymous user '", Username,
            "' does not have permission '",
            Permission, "' on '", resource_to_iolist(Resource), "'"
        ],
        utf8,
        utf8
    ).



%% =============================================================================
%% PRIVATE: REQUEST, GRANT, REVOKE
%% =============================================================================



%% @private
permission_validator(Term) ->
    wamp_uri:is_valid(Term, loose).


%% @private
resource_validator(any) ->
    {ok, any};

resource_validator(<<"any">>) ->
    {ok, any};

resource_validator(Term) ->
    %% We need to know the match strategy to validate the URI
    is_binary(Term).


%% @private
validate(Data) ->
    try
        validate_v2(Data)
    catch
        error:Error when is_map(Error) ->
            validate_v1(Data)
    end.

%% @private
validate_v1(Data) ->
    Req0 = maps_utils:validate(Data, ?GRANT_REQ_VALIDATOR_V1),
    {Resource, Req1} = maps_utils:split([uri, match], Req0),
    Req2 = maps:put(resources, validate_resources([Resource]), Req1),
    maps:put(type, request, Req2).

validate_v2(Data) ->
    Req0 = maps_utils:validate(Data, ?GRANT_REQ_VALIDATOR_V2),
    Req1 = maps:update_with(resources, fun validate_resources/1, Req0),
    maps:put(type, request, Req1).


%% @private
validate_resources(Resources) ->
    [validate_uri_match(normalise_resource(R)) || R <- Resources].


%% @private
normalise_resource(any) ->
    any;

normalise_resource(#{uri := any}) ->
    any;

normalise_resource(#{uri := Uri, match := Strategy}) ->
    {Uri, Strategy}.


%% @private
validate_uri_match(any) ->
    any;

validate_uri_match({<<"*">>, S}) ->
    validate_uri_match({<<>>, S});

validate_uri_match({<<>>, undefined}) ->
    {<<>>, ?PREFIX_MATCH};

validate_uri_match({<<>>, ?PREFIX_MATCH} = P) ->
    P;

validate_uri_match({<<>>, _}) ->
    inconsistency_error([<<"uri">>, <<"match">>]);

validate_uri_match({Uri, undefined}) ->
    %% We try to derive the missing strategy from the URI
    {Uri, derive_strategy(Uri)};

validate_uri_match({Uri, S} = P) ->
    Uri = wamp_uri:validate(Uri, S),
    P.


%% @private
derive_strategy(Uri) ->
    derive_strategy(Uri, [?EXACT_MATCH, ?WILDCARD_MATCH, ?PREFIX_MATCH]).


%% @private
derive_strategy(Uri, [H|T]) ->
    case wamp_uri:is_valid(Uri, H) of
        true ->
            H;
        false ->
            derive_strategy(Uri, T)
    end;

derive_strategy(_, []) ->
    error(bondy_error:map({missing_required_value, <<"match">>})).


%% @private
inconsistency_error(Keys) ->
    error(bondy_error:map({inconsistency_error, Keys})).


%% -----------------------------------------------------------------------------
%% @private
%% @doc Grant permissions to one or more roles(
%% @end
%% -----------------------------------------------------------------------------
-spec grant(binary(), all | [binary()], [normalised_resource()], [binary()]) ->
    ok | {error, term()}.

grant(RealmUri, Keyword, Resources, Permissions)
when Keyword == all orelse Keyword == anonymous->
    do_grant([{Keyword, group}], RealmUri, Resources, Permissions);

grant(RealmUri, RoleList0, Resources, Permissions) ->
    {Anon, RoleList} = lists:splitwith(
        fun
            (anonymous) -> true;
            (<<"anonymous">>) -> true;
            (_) -> false
        end,
        RoleList0
    ),

    %% If anonymous was found in the list, add the grant for it
    _ = length(Anon) > 0 andalso
        grant(RealmUri, anonymous, Resources, Permissions),


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
            do_grant(RoleTypes, RealmUri, Resources, Permissions);
        Error ->
            Error
    end.


%% @private
do_grant([], _, _, _) ->
    ok;

do_grant([{RoleName, RoleType} | T], RealmUri, Resources, Permissions0) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri, RoleType),

    ok = lists:foreach(
        fun(Resource) ->
            %% We store the list of permissions as the value
            Existing = case plum_db:get(Prefix, {RoleName, Resource}) of
                undefined -> [];
                List -> List
            end,

            %% We deduplicate
            Permissions1 = lists:umerge(
                lists:sort(Existing), lists:sort(Permissions0)
            ),

            %% We finally store the updated grant
            Key = {RoleName, Resource},
            ok = plum_db:put(Prefix, Key, Permissions1)
        end,
        Resources
    ),

    do_grant(T, RealmUri, Resources, Permissions0).




%% -----------------------------------------------------------------------------
%% @doc Revoke permissions to one or more roles
%% @end
%% -----------------------------------------------------------------------------
-spec revoke(
    RealmUri :: binary(),
    Roles :: all | [binary()],
    Resource :: [normalised_resource()],
    Permissions :: [uri()]) -> ok | {error, term()}.

revoke(RealmUri, all, Resources, Permissions)  ->
    %% all and anonymous are always valid
    do_revoke([{all, group}], RealmUri, Resources, Permissions);

revoke(RealmUri, RoleList, Resources, Permissions) ->
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
            do_revoke(RoleTypes, RealmUri, Resources, Permissions);
        Error ->
            Error
    end.


do_revoke([], _, _, _) ->
    ok;

do_revoke([{RoleName, RoleType}|Roles], RealmUri, Resources, Permissions) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri, RoleType),

    ok = lists:foreach(
        fun(Resource) ->
            %% check if there is currently a GRANT we can revoke
            case plum_db:get(Prefix, {RoleName, Resource}) of
                undefined ->
                    %% can't REVOKE what wasn't GRANTED
                    ok;
                GrantedPerms ->
                    NewPerms = [
                        X
                        || X <- GrantedPerms, not lists:member(X, Permissions)
                    ],

                    %% TODO - do deletes here, once cluster metadata supports it for
                    %% real, if NewPerms == []

                    case NewPerms of
                        [] ->
                            plum_db:delete(Prefix, {RoleName, Resource});
                        _ ->
                            plum_db:put(Prefix, {RoleName, Resource}, NewPerms)
                    end
            end
        end,
        Resources
    ),
    do_revoke(Roles, RealmUri, Resources, Permissions).


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
        find_grants(RealmUri, {all, '_'}, group)
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
        find_grants(RealmUri, {Rolename, '_'}, Type)
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

%% @private
find_grants(Realm, KeyPattern, Type) ->
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



% on_grant(RealmUri, RoleType, Rolename) ->
%     ok = bondy_event_manager:notify(
%         {rbac_policy_granted, RealmUri, RoleType, Rolename}
%     ),
%     ok.


% on_revoke(RealmUri, RoleType, Rolename) ->
%     ok = bondy_event_manager:notify(
%         {rbac_policy_revoked, RealmUri, RoleType, Rolename}
%     ),
%     ok.
