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
-include("bondy_plum_db.hrl").
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

-define(USER_GRANTS_PREFIX(RealmUri),   {?PLUM_DB_USER_GRANT_TAB, RealmUri}).
-define(GROUP_GRANTS_PREFIX(RealmUri),  {?PLUM_DB_GROUP_GRANT_TAB, RealmUri}).
-define(PLUMDB_PREFIX(RealmUri, Type),
    case Type of
        user -> ?USER_GRANTS_PREFIX(RealmUri);
        group -> ?GROUP_GRANTS_PREFIX(RealmUri)
    end
).

-ifdef(TEST).

-define(CTXT_REFRESH_SECS, 1).

-else.

-define(CTXT_REFRESH_SECS, timer:minutes(5)).

-endif.

-record(bondy_rbac_context, {
    realm_uri               ::  binary(),
    username                ::  binary(),
    exact_grants = #{}      ::  [grant()],
    pattern_grants          ::  [grant()],
    epoch                   ::  integer(),
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

-export([authorize/2]).
-export([authorize/3]).
-export([get_anonymous_context/1]).
-export([get_anonymous_context/2]).
-export([get_context/1]).
-export([get_context/2]).
-export([grant/2]).
-export([grants/2]).
-export([grants/3]).
-export([group_grants/2]).
-export([is_reserved_name/1]).
-export([normalize_name/1]).
-export([refresh_context/1]).
-export([request/1]).
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
-spec authorize(binary(), bondy_context:t() | context()) ->
    ok | no_return().

authorize(Permission, Ctxt) ->
    authorize(Permission, any, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc Returns 'ok' or an exception.
%% @end
%% -----------------------------------------------------------------------------
-spec authorize(binary(), binary() | any, bondy_context:t() | context()) ->
    ok | no_return().

authorize(Permission, Resource, #bondy_rbac_context{} = Ctxt) ->
    do_authorize(Permission, Resource, Ctxt);

authorize(Permission, Resource, Ctxt) ->
    case bondy_context:is_security_enabled(Ctxt) of
        true ->
            RBACCtxt = bondy_session:rbac_context(
                bondy_context:session(Ctxt)
            ),
            do_authorize(Permission, Resource, RBACCtxt);
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
-spec refresh_context(Ctxt :: bondy_context:t()) -> {boolean(), context()}.

refresh_context(#bondy_rbac_context{realm_uri = Uri} = Context) ->
    Now = erlang:system_time(second),
    Diff = Now - Context#bondy_rbac_context.epoch,

    %% TODO Replace this with configurable value of 'session' so never
    %% refreshed during a session or an integer value.
    %% Also, consider refreshing it based on update events (expensice unless we
    %% use forward chaining algorithm like RETE).
    case Diff < ?CTXT_REFRESH_SECS of
        false when Context#bondy_rbac_context.is_anonymous ->
            %% context has expired
            Ctxt = get_anonymous_context(
                Uri, Context#bondy_rbac_context.username
            ),
            {true, Ctxt};
        false ->
            %% context has expired
            Ctxt = get_context(Uri, Context#bondy_rbac_context.username),
            {true, Ctxt};
        _ ->
            {false, Context}
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
get_anonymous_context(RealmUri, Username) ->
    Ctxt = get_context(RealmUri, Username, grants(RealmUri, anonymous, group)),
    Ctxt#bondy_rbac_context{is_anonymous = true}.


%% -----------------------------------------------------------------------------
%% @doc Contexts are only valid until the GRANT epoch changes, and it will
%% change whenever a GRANT or a REVOKE is performed. This is a little coarse
%% grained right now, but it'll do for the moment.
%% @end
%% -----------------------------------------------------------------------------

get_context(RealmUri, Username)
when is_binary(Username) orelse Username == anonymous ->
    get_context(RealmUri, Username, grants(RealmUri, Username, user)).


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
%% @doc Returns the local grants assigned in realm `RealmUri'. This function does not use protypical inheritance.
%% @end
%% -----------------------------------------------------------------------------
-spec grants(RealmUri :: uri(), Opts :: map()) -> [grant()].

grants(RealmUri, Opts0) ->
    Opts = maps:to_list(Opts0),
    lists:append(
        find_grants(RealmUri, '_', group, Opts),
        find_grants(RealmUri, '_', user, Opts)
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec grants(
    RealmUri :: uri(), Name :: binary(), RoleType :: user | group) ->
    [grant()].

grants(RealmUri, Name, Type) ->
    group_grants(acc_grants(RealmUri, Name, Type)).


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
%% Resource must be a binary or the atom `any'.
%% In the case the resource is `any', the role needs to have this permission
%% applied *globally*. This is for things with undetermined inputs or
%% permissions that don't tie to a particular resource.
%% @end
%% -----------------------------------------------------------------------------
-spec check_permission(Permission :: permission(), Context :: context()) ->
    {true, context()} | {false, binary(), context()}.

check_permission({Action, Resource} = Permission, #bondy_rbac_context{} = Ctxt0)
when is_binary(Resource) orelse Resource =:= any ->
    {_, Ctxt} = refresh_context(Ctxt0),
    case check_permission_exact(Permission, Ctxt) of
        true ->
            {true, Ctxt};
        false ->
            case check_permission_pattern(Permission, Ctxt) of
                true ->
                    {true, Ctxt};
                false ->
                    Mssg = permission_denied_message(Action, Resource, Ctxt),
                    {false, Mssg, Ctxt}
            end
    end.


%% =============================================================================
%% PRIVATE: AUTHORIZATION
%% =============================================================================



check_permission_exact({Action, Resource}, Ctxt) ->
    case maps:find(Resource, Ctxt#bondy_rbac_context.exact_grants) of
        {ok, Actions} ->
            lists:member(Action, Actions);
        error ->
            false
    end.


check_permission_pattern({Action, Resource}, Ctxt) ->
    Actions = match_grants(Resource, Ctxt#bondy_rbac_context.pattern_grants),
    lists:member(Action, Actions).


%% @private
get_context(RealmUri, Username, Grants) ->
    {Exact, Pattern} = lists:foldl(
        fun
            ({any, Permissions}, {Map, L}) ->
                {maps:put(any, Permissions, Map), L};
            ({{Uri, <<"exact">>}, Permissions}, {Map, L}) ->
                {maps:put(Uri, Permissions, Map), L};
            (Term, {Map, L}) ->
                {Map, [Term|L]}
        end,
        {#{}, []},
        Grants
    ),
    #bondy_rbac_context{
        realm_uri = RealmUri,
        username = Username,
        exact_grants = Exact,
        pattern_grants = Pattern,
        epoch = erlang:system_time(second),
        is_anonymous = Username == anonymous
    }.


%% @private
do_authorize(Permission, Resource, Ctxt) ->
    %% We could be cashing the security ctxt,
    %% the data is in ets so it should be pretty fast.
    case check_permission({Permission, Resource}, Ctxt) of
        {true, _Ctxt1} ->
            ok;
        {false, Mssg, _Ctxt1} ->
            error({not_authorized, Mssg})
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
    Tail = case Resource == any of
        true ->
            ["'"];
        false ->
            ["' on '", resource_to_iolist(Resource), "'"]
    end,

    unicode:characters_to_binary(
        [
            "Permission denied. ",
            "User '", Username,
            "' does not have permission '",
            Permission
            | Tail
        ],
        utf8,
        utf8
    );

permission_denied_message(
    Permission, Resource, #bondy_rbac_context{is_anonymous = true} = Ctxt) ->
    Username = to_bin(Ctxt#bondy_rbac_context.username),
    Tail = case Resource == any of
        true ->
            ["'"];
        false ->
            ["' on '", resource_to_iolist(Resource), "'"]
    end,
    unicode:characters_to_binary(
        [
            "Permission denied. ",
            "Anonymous user '", Username,
            "' does not have permission '",
            Permission
            | Tail
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

    ProtoUri = bondy_realm:prototype_uri(RealmUri),
    RealmProto = {RealmUri, ProtoUri},

    RoleTypes = lists:map(
        fun(Role) ->
            {chop_name(Role), role_type(RealmProto, Role)}
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

do_grant([{Rolename, RoleType} | T], RealmUri, Resources, Permissions0) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri, RoleType),

    ok = lists:foreach(
        fun(Resource) ->
            %% We store the list of permissions as the value
            Existing = case plum_db:get(Prefix, {Rolename, Resource}) of
                undefined -> [];
                List -> List
            end,

            %% We deduplicate
            Permissions1 = lists:umerge(
                lists:sort(Existing), lists:sort(Permissions0)
            ),

            %% We finally store the updated grant
            Key = {Rolename, Resource},
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
    ProtoUri = bondy_realm:prototype_uri(RealmUri),
    RealmProto = {RealmUri, ProtoUri},

    RoleTypes = lists:map(
        fun(Name) ->
            {chop_name(Name), role_type(RealmProto, Name)}
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

do_revoke([{Rolename, RoleType}|Roles], RealmUri, Resources, Permissions) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri, RoleType),

    ok = lists:foreach(
        fun(Resource) ->
            %% check if there is currently a GRANT we can revoke
            case plum_db:get(Prefix, {Rolename, Resource}) of
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
                            plum_db:delete(Prefix, {Rolename, Resource});
                        _ ->
                            plum_db:put(Prefix, {Rolename, Resource}, NewPerms)
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
role_type({RealmUri, _}, <<"user/", Name/binary>>) ->
    do_role_type(
        bondy_rbac_user:exists(RealmUri, Name),
        false
    );
role_type({_, _} = RealmProto, <<"group/", Name/binary>>) ->
    do_role_type(
        false,
        group_exists(RealmProto, Name)
    );

role_type({RealmUri, _} = RealmProto, Name) ->
    do_role_type(
        bondy_rbac_user:exists(RealmUri, Name),
        group_exists(RealmProto, Name)
    );

role_type(RealmUri, Name) ->
    role_type({RealmUri, undefined}, Name).


%% @private
group_exists({RealmUri, Prototype}, Name) ->
    case bondy_rbac_group:exists(RealmUri, Name) of
        false when Prototype == undefined ->
            false;
        false ->
            bondy_rbac_group:exists(Prototype, Name);
        true ->
            true
    end.


%% @private
do_role_type(false, false) ->
    unknown;

do_role_type(true, false) ->
    user;

do_role_type(false, true) ->
    group;

do_role_type(true, true) ->
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
acc_grants(RealmUri, Rolename, Type) ->
    ProtoUri = bondy_realm:prototype_uri(RealmUri),
    RealmProto = {RealmUri, ProtoUri},

    %% The 'all' grants always apply. The special group 'all' does not follow
    %% inheritance rules for normal groups i.e. a realm cannot override the
    %% prototype's 'all' group.
    Acc0 = lists:map(
        fun({{all, Resource}, Permissions}) ->
            {{<<"group/all">>, Resource}, Permissions}
        end,
        lists:append(
            find_grants(RealmUri, {all, '_'}, group),
            find_grants(ProtoUri, {all, '_'}, group)
        )
    ),

    {Acc1, _Seen} = acc_grants([Rolename], Type, RealmProto, [], Acc0),
    Acc1.


%% @private
acc_grants([], _, _, Seen, Acc) ->
    {lists:flatten(Acc), Seen};

acc_grants([Rolename|Rolenames], Type, RealmProto, Seen, Acc) ->
    %% A role can be a member of a group defined in the realm or in the realm's
    %% prototype.
    %% Grants can be assigned to a group defined in the realm or in the realm's
    %% prototype.

    %% We get the groups this role is member of.
    Groupnames = role_groupnames(Rolename, Type, RealmProto, Seen),

    %% We iterate over the role's groups to gather grants (permissions)
    %% assigned to them.
    %% We accumulate the rolename in the Seen list (without the realm qualifier)
    %% as this enables us to implement group override. If group A was defined
    %% in the Realm it overrides group A in the prototype (if defined), this
    %% means we will neither traverse the groups of {A, ProtoUri} nor
    %% accumulate the permissions granted for A in ProtoUri.
    {NewAcc, NewSeen} = acc_grants(
        Groupnames,
        group,
        RealmProto,
        acc_grants_append_seen(Rolename, Seen),
        Acc
    ),

    %% We gather the grants associated directly to this role
    Grants = [
        {{concat_role(Type, Name), Resource}, Permissions}
        || {{Name, Resource}, Permissions} <-
            acc_grants_find(Rolename, Type, RealmProto),
            Name == Rolename
    ],

    %% We continue iterating over the roles
    acc_grants(Rolenames, Type, RealmProto, NewSeen, [Grants|NewAcc]).


%% @private
acc_grants_append_seen({Rolename, _}, Acc) ->
    %% We acc only the rolename. In the case of users this does not make any
    %% difference as we do not support user inheritance. But in the case of
    %% groups, this means that once we've seen a local group, we do not read
    %% its super group from the prototype (if it existed), which simulates
    %% group override.
    acc_grants_append_seen(Rolename, Acc);

acc_grants_append_seen(Rolename, Acc) ->
    [Rolename | Acc].


%% @private
acc_grants_find({Rolename, RealmUri}, user = Type, _) ->
    find_grants(RealmUri, {Rolename, '_'}, Type);

acc_grants_find(Rolename, user = Type, {RealmUri, _}) ->
    %% No user inheritance, so we skip prototype
    find_grants(RealmUri, {Rolename, '_'}, Type);

acc_grants_find({Rolename, RealmUri}, group = Type, _) ->
    %% We know the groups exists as we have a qualified name
    find_grants(RealmUri, {Rolename, '_'}, Type);

acc_grants_find(Rolename, group = Type, {RealmUri, ProtoUri}) ->
    case bondy_rbac_group:exists(RealmUri, Rolename) of
        true ->
            find_grants(RealmUri, {Rolename, '_'}, Type);
        false ->
            find_grants(ProtoUri, {Rolename, '_'}, Type)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc We return the groups this role is a member of. If the groups does not
%% exist we try fetching from the prototype if it exists.
%% Returns qualified group names e.g. {Name, Uri} where Uri can be the Realm's
%% or its prototype.
%% @end
%% -----------------------------------------------------------------------------
role_groupnames(Rolename, Type, RealmProto, Seen) ->
    case lists:member(Rolename, Seen) of
        true ->
            %% We avoid iterating over already seen groups.
            %% This is because group membership is recursive and a
            %% group can be a member of another group multiple times
            %% through different paths.
            %% But also, to iinheritance overriding where a group in a realm
            %% overrides the group in the realm's prototype.
            [];
        false ->
            do_role_groupnames(Rolename, Type, RealmProto)
    end.


%% @private
do_role_groupnames(Rolename, user, {RealmUri, _}) ->
    case bondy_rbac_user:lookup(RealmUri, Rolename) of
        {error, not_found} ->
            [];
        User ->
            bondy_rbac_user:groups(User)
    end;

do_role_groupnames(Rolename, group, {RealmUri, ProtoUri}) ->
    case bondy_rbac_group:lookup(RealmUri, Rolename) of
        {error, not_found} when ProtoUri == undefined ->
            [];
        {error, not_found} ->
            do_role_groupnames(Rolename, group, {ProtoUri, undefined});
        Group ->
            bondy_rbac_group:groups(Group)
    end.


%% @private
find_grants(Realm, KeyPattern, Type) ->
    find_grants(Realm, KeyPattern, Type, []).


%% @private
find_grants(undefined, _, _, _) ->
    [];

find_grants(Realm, KeyPattern, Type, Opts0) ->
    Opts = lists:merge(
        lists:sort([{resolver, lww}, {remove_tombstones, true}]),
        lists:sort(Opts0)
    ),
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
