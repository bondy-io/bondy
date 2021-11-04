%% =============================================================================
%%  bondy_auth.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
%% @doc This module provides the behaviour to be implemented by the
%% authentication methods used by Bondy. The module provides the functions
%% required to setup an authentication context, compute a challenge (in the
%% case of challenge-response methods and authenticate a user based on the
%% selected method out of the available methods offered by the Realm and
%% restricted by the access control system and the user's password capabilities.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_auth).
-behaviour(bondy_sensitive).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy_security.hrl").

-type context()         ::  #{
    session_id := id() | undefined,
    realm_uri := uri(),
    user := bondy_rbac_user:t() | undefined,
    user_id := binary() | undefined,
    available_methods := [binary()],
    role := binary(),
    roles := [binary()],
    conn_ip := [{ip, inet:ip_address()}],
    provider => binary(),
    method => binary(),
    callback_mod => module(),
    callback_mod_state => term()
}.

%% TODO change to
% #{
%     password => #{required => boolean(), protocols => list()},
%     authorized_keys => #{required => boolean()},
%     channel_binding => required => boolean(), types => list()}
% }.
-type requirements()    ::  #{
    identification := boolean,
    password := {true, #{protocols := [cra | scram]}} | boolean(),
    authorized_keys := boolean(),
    any => requirements(),
    all => requirements()
}.

-export_type([context/0]).
-export_type([requirements/0]).

%% BONDY_SENSITIVE CALLBACKS
-export([format_status/2]).

%% API
-export([authenticate/4]).
-export([method/1]).
-export([provider/1]).
-export([role/1]).
-export([roles/1]).
-export([available_methods/1]).
-export([available_methods/2]).
-export([challenge/3]).
-export([conn_ip/1]).
-export([init/5]).
-export([method_info/0]).
-export([method_info/1]).
-export([methods/0]).
-export([session_id/1]).
-export([realm_uri/1]).
-export([user_id/1]).
-export([user/1]).





%% =============================================================================
%% CALLBACKS
%% =============================================================================



-callback init(Ctxt :: context()) ->
    {ok, CBState :: term()}
    | {error, Reason :: any()}.


-callback requirements() -> requirements().


-callback challenge(DataIn :: map(), Ctxt :: context(), CBState :: term()) ->
    {ok, CBState :: term()}
    | {ok, ChallengeData :: map(), CBState :: term()}
    | {error, Reason :: any(), CBState :: term()}.


-callback authenticate(
    Signature :: binary(),
    DataIn :: map(),
    Ctxt :: context(),
    CBState :: term()) ->
    {ok, DataOut :: map(), CBState :: term()}
    | {error, Reason :: any(), CBState :: term()}.



%% =============================================================================
%% BONDY_SENSITIVE CALLBACKS
%% =============================================================================



-spec format_status(Opt :: normal | terminate, Ctxt :: context()) -> term().

format_status(_Opt, Ctxt) ->
    #{user_id := Id, user := User, callback_mod_state := CBModState} = Ctxt,

    Ctxt#{
        user_id => bondy_sensitive:wrap(Id),
        user => bondy_sensitive:wrap(User),
        callback_mod_state => bondy_sensitive:wrap(CBModState)
    }.



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(
    SessionId :: id(),
    Realm :: bondy_realm:t() | uri(),
    UserId :: binary() | anonymous,
    Roles :: all | binary() | [binary()] | undefined,
    Peer :: {inet:ip_address(), inet:port_number()}) ->
    {ok, context()}
    | {error, {no_such_user, binary()} | no_such_realm | no_such_group}
    | no_return().

init(SessionId, Uri, UserId, Roles, Peer) when is_binary(Uri) ->
    case bondy_realm:lookup(string:casefold(Uri)) of
        {error, not_found} ->
            {error, no_such_realm};
        Realm ->
            init(SessionId, Realm, UserId, Roles, Peer)
    end;

init(SessionId, Realm, UserId0, Roles0, {IPAddress, _}) ->
    try
        RealmUri = bondy_realm:uri(Realm),
        UserId = casefold(UserId0),
        User = get_user(RealmUri, UserId),
        {Role, Roles} = valid_roles(Roles0, User),

        Ctxt = #{
            session_id => SessionId,
            realm_uri => RealmUri,
            user_id => UserId,
            user => User,
            role => Role,
            roles => Roles,
            conn_ip => IPAddress
        },
        Methods = compute_available_methods(Realm, Ctxt),
        {ok, maps:put(available_methods, Methods, Ctxt)}

    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec methods() -> [binary()].

methods() ->
    maps:keys(?BONDY_AUTHMETHODS_INFO).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec method_info() -> map().

method_info() ->
    ?BONDY_AUTHMETHODS_INFO.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec method_info(Method :: binary()) -> map() | no_return().

method_info(Method) ->
    maps:get(Method, ?BONDY_AUTHMETHODS_INFO).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(context()) -> id().

session_id(#{session_id := Value}) ->
    Value.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec user_id(context()) -> binary() | undefined.

user_id(#{user_id := Value}) ->
    Value.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec method(context()) -> [binary()].

method(#{method := Value}) ->
    Value.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec available_methods(context()) -> [binary()].

available_methods(#{available_methods := Value}) ->
    Value.


%% -----------------------------------------------------------------------------
%% @doc Returns the sublist of `List' containing only the available
%% authentication methods that can be used with user `User' in realm `Realm'
%% when connecting from the current IP Address.
%% @end
%% -----------------------------------------------------------------------------
-spec available_methods(List :: [binary()], Ctxt :: context()) -> [binary()].

available_methods(List, #{available_methods := Available}) ->
    sets:to_list(
        sets:intersection(sets:from_list(List), sets:from_list(Available))
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec provider(context()) -> [binary()].

provider(#{provider := Value}) ->
    Value.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec role(context()) -> binary().

role(#{role := Value}) ->
    Value.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec roles(context()) -> [binary()].

roles(#{roles := Value}) ->
    Value.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec user(context()) -> bondy_rbac_user:t() | undefined.

user(#{user := Value}) ->
    Value;

user(_) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(context()) -> uri().

realm_uri(#{realm_uri := Value}) ->
    Value.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec conn_ip(context()) -> [{ip, inet:ip_address()}].

conn_ip(#{conn_ip := Value}) ->
    Value.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec challenge(Method :: binary(), DataIn :: map(), Ctxt :: context()) ->
    {ok, AuthData :: map(), NewCtxt :: context()}
    | {challenge, ChallengeData :: map(), NewCtxt :: context()}
    | {error, Reason :: any()}.

challenge(Method, DataIn, #{method := Method} = Ctxt0) ->
    #{
        callback_mod := CBMod,
        callback_mod_state := CBModState0
    } = Ctxt0,

    try CBMod:challenge(DataIn, Ctxt0, CBModState0) of
        {ok, CBModState1} ->
            Ctxt = maps:put(callback_mod_state, CBModState1, Ctxt0),
            {ok, Ctxt};
        {ok, ChallengeData, CBModState1} ->
            Ctxt = maps:put(callback_mod_state, CBModState1, Ctxt0),
            {ok, ChallengeData, Ctxt};
        {error, Reason, _} ->
            {error, Reason}
    catch
        throw:EReason ->
            {error, EReason}
    end;

challenge(_, _, #{method := _}) ->
    %% This might happen when you init and call challenge twice with a
    %% different Method. The first call sets the context 'method',
    %% the second call in principle should never happen. We allow IFF the value
    %% for Method matches the context 'method'.
    {error, invalid_method};

challenge(Method, DataIn, Ctxt0) ->
    try
        %% We check Method is one of the available methods and set it as the
        %% selected one for the authentication process.
        %% This can fail with an exception in case the requested method was not
        %% in the 'available_methods' set.
        Ctxt = maybe_set_method(Method, Ctxt0),
        challenge(Method, DataIn, Ctxt)
    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    Method :: binary(),
    Signature :: binary(),
    DataIn :: map(),
    Ctxt :: context()) ->
    {ok, ReturnExtra :: map(), NewCtxt :: context()}
    | {error, Reason :: any()}.

authenticate(Method, Signature, DataIn, #{method := Method} = Ctxt0) ->
    try
        #{
            callback_mod := CBMod,
            callback_mod_state := CBModState0
        } = Ctxt0,

        case CBMod:authenticate(Signature, DataIn, Ctxt0, CBModState0) of
            {ok, DataOut, CBModState1} ->
                Ctxt = maps:put(callback_mod_state, CBModState1, Ctxt0),
                {ok, DataOut, Ctxt};
            {error, Reason, _} ->
                {error, Reason}
        end
    catch
        throw:EReason ->
            {error, EReason}
    end;

authenticate(_, _, _, #{method := _}) ->
    %% This might happen when you init and call challenge and authenticate with
    %% different Method values (or called authenticate twice).
    {error, invalid_method};

authenticate(Method, Signature, DataIn, Ctxt) ->
    try
        %% No context 'method' defined yet as challenge was never called (not
        %% every method operates with challenge-response) so we try to set it.
        authenticate(
            Method, Signature, DataIn, maybe_set_method(Method, Ctxt)
        )
    catch
        throw:Reason ->
            {error, Reason}
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc Returns the requested role `Role' if user `User' is a member of that
%% role, otherwise throws an 'no_such_group' exception.
%% In case the requested role is the
%% atom 'undefined' it returns the first group in the user's groups or
%% undefined if the user is not a member of any group.
%% @end
%% -----------------------------------------------------------------------------
-spec valid_roles(
    Role :: binary() | [binary()] | undefined,
    User :: bondy_rbac_user:t()) ->
    {Role :: binary() | undefined, Roles :: [binary()]}.

valid_roles(_, undefined) ->
    {undefined, []};

valid_roles([], _) ->
    {undefined, []};

valid_roles(undefined, User) ->
    valid_roles(all, User);

valid_roles(_, #{username := anonymous}) ->
    %% If anonymous (user) the only valid role (group) is anonymous
    %% so we drop the requested ones.
    {anonymous, [anonymous]};

valid_roles(<<"all">>, User) ->
    valid_roles(all, User);

valid_roles(all, User) ->
    {undefined, bondy_rbac_user:groups(User)};

valid_roles(Role, User) when is_binary(Role) ->
    All = bondy_rbac_user:groups(User),
    case lists:member(Role, All) of
        true ->
            {Role, [Role]};
        false when Role =:= <<"default">> ->
            %% Some clients will send "default" as opposed to NULL (undefined).
            %% Yes, it is very nasty for them to do this.
            {undefined, All};
        false ->
            throw(no_such_group)
    end;

valid_roles(Roles, User) ->
    RolesSet = sets:from_list(Roles),
    AllSet = sets:from_list(bondy_rbac_user:groups(User)),

    RolesSet =:= sets:intersection(RolesSet, AllSet)
        orelse throw(no_such_group),

    {undefined, Roles}.


%% @private
casefold(anonymous) ->
    anonymous;

casefold(Bin) when is_binary(Bin) ->
    string:casefold(Bin).


%% @private
callback_mod(Method) ->
    callback_mod(Method, fun(X) -> X end).

callback_mod(Method, Fun) when is_function(Fun, 1) ->
    case maps:get(Method, ?BONDY_AUTHMETHODS_INFO, undefined) of
        undefined ->
            throw(invalid_method);
        #{callback_mod := undefined} ->
            throw(unsupported_method);
        #{callback_mod := Mod} ->
            Fun(Mod)
    end.


%% @private
compute_available_methods(Realm, Ctxt) ->
    #{
        realm_uri := RealmUri,
        user_id := UserId,
        conn_ip := IPAddress
    } = Ctxt,

    %% The allowed methods for the Realm
    RealmAllowed = bondy_realm:authmethods(Realm),
    R1 = leap_relation:relation({{var, method}}, [{X} || X <- RealmAllowed]),

    %% The allowed methods for this AuthID when connecting from IPAddress,
    %% we keep the order as the sources are already sorted from most specific
    %% to most general
    Sources = bondy_rbac_source:match(RealmUri, UserId, IPAddress),
    {_, UserAllowed} = lists:foldl(
        fun(Source, {N, Acc}) ->
            {N + 1, [{N, bondy_rbac_source:authmethod(Source)} | Acc]}
        end,
        {1, []},
        Sources
    ),
    R2 = leap_relation:relation({{var, order}, {var, method}}, UserAllowed),

    %% We compute the join of the two relations and we filter to return
    %% only those methods that are satisfied by the user record based on the
    %% method requirements
    Allowed = leap_relation:tuples(
        leap_relation:project(
            leap_relation:join(R1, R2, #{}),
            [{var, order}, {var, method}]
        )
    ),

    Filter = fun
        ({_, ?WAMP_ANON_AUTH = Method}) ->
            true =:= bondy_config:get([security, allow_anonymous_user], true)
                andalso matches_requirements(Method, Ctxt);
        ({_Order, Method}) ->
            matches_requirements(Method, Ctxt)
    end,

    Available = lists:usort(lists:filtermap(Filter, Allowed)),

    %% We remove the order attribute, returning only the list of methods
    [Method || {_, Method} <- Available].



%% @private
matches_requirements(Method, #{user_id := UserId, user := User}) ->
    Password = bondy_rbac_user:password(User),

    Requirements = maps:to_list((callback_mod(Method)):requirements()),

    lists:all(
        fun
            Match({identification, false}) ->
                %% The special case. If the client provided an auth_id /=
                %% anonymous then the anonymous method is not allowed.
                UserId == anonymous;
            Match({_, false}) ->
                true;
            Match({identification, true}) ->
                UserId =/= anonymous;
            Match({authorized_keys, true}) ->
                bondy_rbac_user:has_authorized_keys(User);
            Match({password, true}) ->
                Password =/= undefined;
            Match({password, {true, #{protocols := Ps}}}) ->
                Password =/= undefined
                andalso lists:member(bondy_password:protocol(Password), Ps);
            Match({any, Any}) ->
                lists:any(Match, maps:to_list(Any));
            Match({all, All}) ->
                lists:any(Match, maps:to_list(All))
        end,
        Requirements
    ).


%% @private
get_user(_, undefined) ->
    undefined;

get_user(RealmUri, UserId) ->
    case bondy_rbac_user:lookup(RealmUri, UserId) of
        {error, not_found} ->
            throw({no_such_user, UserId});
        User ->
            bondy_rbac_user:is_enabled(User) orelse throw(user_disabled),
            %% We call resolve so that we merge the local user to the SSO user
            %% (if any), so that we get the credentials (password and
            %% authorized_keys).
            %% If for whatever reason the local user had values for the
            %% credentials, they will be overriden by those from the SSO.
            bondy_rbac_user:resolve(User)
    end.


%% @private
maybe_set_method(Method, #{method := Method} = Ctxt) ->
    Ctxt;

maybe_set_method(_, #{method := _}) ->
    %% Method was already set and does not match the one requested
    throw(invalid_method);

maybe_set_method(Method, Ctxt) ->
    Allowed = [Method] =:= available_methods([Method], Ctxt),

    Mod = callback_mod(Method,
        fun
            (Mod) when Allowed -> Mod;
            (_Mod) -> throw(method_not_allowed)
        end
    ),

    case Mod:init(Ctxt) of
        {ok, CBState} ->
            Ctxt#{
                provider => ?BONDY_AUTH_PROVIDER,
                method => Method,
                callback_mod => Mod,
                callback_mod_state => CBState
            };
        {error, Reason} ->
            throw(Reason)
    end.

