%% =============================================================================
%%  bondy_rbac_user.erl -
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
%% @doc A user is a role that is able to log into a Bondy Realm.
%% They  have attributes associated with themelves like username, credentials
%% (password or authorized keys) and metadata determined by the client
%% applications. Users can be assigned group memberships.
%%
%% **Note:**
%% Usernames and group names are stored in lower case. All functions in this
%% module are case sensitice so when using the functions in this module make
%% sure the inputs you provide are in lowercase to. If you need to convert your
%% input to lowercase use {@link string:casefold/1}.
%%

%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rbac_user).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(TYPE, user).
-define(VERSION, <<"1.1">>).
-define(PLUMDB_PREFIX(RealmUri), {security_users, RealmUri}).

%% TODO resolver function to reconcile sso_realm_uri, meta, groups,
%% password and authorized_keys. In the case of sso_realm_uri and groups
%% checking whether they exist.
-define(FOLD_OPTS, [{resolver, lww}]).

-define(VALIDATOR, ?OPTS_VALIDATOR#{
    <<"username">> => #{
        alias => username,
		key => username,
        required => true,
        datatype => binary,
        validator => fun bondy_data_validators:strict_username/1
    },
    <<"password">> => #{
        alias => password,
		key => password,
        required => false,
        datatype => [binary, {function, 0}, map],
        validator => fun bondy_data_validators:password/1
    },
    <<"authorized_keys">> => #{
        alias => authorized_keys,
		key => authorized_keys,
        required => false,
        datatype => {list, binary},
        validator => {list, fun bondy_data_validators:authorized_key/1}
    },
    <<"groups">> => #{
        alias => groups,
		key => groups,
        required => true,
        default => [],
        datatype => {list, binary},
        validator => fun bondy_data_validators:groupnames/1
    },
    <<"sso_realm_uri">> => #{
        alias => sso_realm_uri,
        key => sso_realm_uri,
        required => true,
        datatype => binary,
        allow_undefined => true,
        default => undefined,
        validator => fun bondy_data_validators:realm_uri/1
    },
    <<"enabled">> => #{
        alias => enabled,
		key => enabled,
        required => true,
        datatype => boolean,
        default => true
    },
    <<"meta">> => #{
        alias => meta,
		key => meta,
        required => true,
        datatype => map,
        default => #{}
    }
}).


-define(UPDATE_VALIDATOR, ?OPTS_VALIDATOR#{
    <<"password">> => #{
        alias => password,
		key => password,
        required => false,
        datatype => [binary, {function, 0}, map],
        validator => fun bondy_data_validators:password/1
    },
    <<"authorized_keys">> => #{
        alias => authorized_keys,
		key => authorized_keys,
        required => false,
        datatype => {list, binary},
        validator => {list, fun bondy_data_validators:authorized_key/1}
    },
    <<"groups">> => #{
        alias => groups,
		key => groups,
        required => false,
        datatype => {list, binary},
        validator => {list, fun bondy_data_validators:groupname/1}
    },
    <<"enabled">> => #{
        alias => enabled,
		key => enabled,
        required => false,
        datatype => boolean
    },
    <<"meta">> => #{
        alias => meta,
		key => meta,
        required => false,
        datatype => map
    }
}).


-define(OPTS_VALIDATOR, #{
    <<"password_opts">> => #{
        alias => password_opts,
        key => password_opts,
        required => false,
        datatype => map,
        validator => fun bondy_password:opts_validator/1
    }
}).


-define(ANONYMOUS, type_and_version(#{
    username => anonymous,
    groups => [anonymous],
    meta => #{}
})).


-type t()       ::  #{
    type                :=  ?TYPE,
    version             :=  binary(),
    username            :=  username(),
    groups              :=  [binary()],
    password            =>  bondy_password:future() | bondy_password:t(),
    authorized_keys     =>  [binary()],
    sso_realm_uri       =>  maybe(uri()),
    meta                =>  #{binary() => any()},
    %% Transient, will not be stored
    password_opts       =>  bondy_password:opts()
}.


-type external() ::  #{
    type                :=  ?TYPE,
    version             :=  binary(),
    username            :=  username(),
    groups              :=  [binary()],
    has_password        :=  boolean(),
    has_authorized_keys :=  boolean(),
    sso_realm_uri       =>  maybe(uri()),
    meta                =>  #{binary() => any()}
}.

-type username()        ::  binary() | anonymous.
-type new_opts()        ::  #{
    password_opts       => bondy_password:opts()
}.
-type add_opts()        ::  #{
    password_opts       =>  bondy_password:opts()
}.
-type update_opts()        ::  #{
    update_credentials      =>  boolean(),
    password_opts           =>  bondy_password:opts()
}.
-type list_opts()       ::  #{
    limit => pos_integer()
}.
-type add_error()       ::  no_such_realm | reserved_name | already_exists.
-type update_error()    ::  no_such_realm
                            | reserved_name
                            | {no_such_user, username()}
                            | {no_such_groups, [bondy_rbac_group:name()]}.


-export_type([t/0]).
-export_type([external/0]).
-export_type([new_opts/0]).
-export_type([add_opts/0]).
-export_type([update_opts/0]).


-export([add/2]).
-export([add_group/3]).
-export([add_groups/3]).
-export([add_or_update/2]).
-export([add_or_update/3]).
-export([authorized_keys/1]).
%% TODO new API
%% -export([add_authorized_key/2]).
%% -export([remove_authorized_key/2]).
%% -export([is_authorized_key/2]).
-export([change_password/3]).
-export([change_password/4]).
-export([disable/2]).
-export([enable/2]).
-export([exists/2]).
-export([fetch/2]).
-export([groups/1]).
-export([has_authorized_keys/1]).
-export([has_password/1]).
-export([is_enabled/1]).
-export([is_enabled/2]).
-export([is_member/2]).
-export([is_sso_user/1]).
-export([list/1]).
-export([list/2]).
-export([lookup/2]).
-export([meta/1]).
-export([new/1]).
-export([new/2]).
-export([normalise_username/1]).
-export([password/1]).
-export([remove/2]).
-export([remove_group/3]).
-export([remove_groups/3]).
-export([resolve/1]).
-export([sso_realm_uri/1]).
-export([to_external/1]).
-export([unknown/2]).
-export([update/3]).
-export([update/4]).
-export([username/1]).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Data :: map()) -> User :: t().

new(Data) ->
    new(Data, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Data :: map(), Opts :: new_opts()) -> User :: t().

new(Data, Opts) ->
    User = type_and_version(maps_utils:validate(Data, ?VALIDATOR)),
    maybe_apply_password(User, Opts).


%% -----------------------------------------------------------------------------
%% @doc Returns the group names the user's username.
%% @end
%% -----------------------------------------------------------------------------
username(#{type := ?TYPE, username := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the group names the user `User' is member of.
%% @end
%% -----------------------------------------------------------------------------
groups(#{type := ?TYPE, groups := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user `User' is a member of the group named
%% `Name'. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_member(Name0 :: bondy_rbac_group:name(), User :: t()) -> boolean().

is_member(Name0, #{type := ?TYPE, groups := Val}) ->
    Name = bondy_rbac_group:normalise_name(Name0),
    Name == all orelse lists:member(Name, Val).


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user `User' is managed in a SSO Realm, `false' if it
%% is locally managed.
%% @end
%% -----------------------------------------------------------------------------
-spec is_sso_user(User :: t()) -> boolean().

is_sso_user(#{type := ?TYPE, sso_realm_uri := Val}) when is_binary(Val) ->
    true;

is_sso_user(#{type := ?TYPE}) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc Returns the URI of the Same Sign-on Realm in case the user is a SSO
%% user. Otherwise, returns `undefined'.
%% @end
%% -----------------------------------------------------------------------------
-spec sso_realm_uri(User :: t()) -> maybe(uri()).

sso_realm_uri(#{type := ?TYPE, sso_realm_uri := Val}) when is_binary(Val) ->
    Val;

sso_realm_uri(#{type := ?TYPE}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user `User' is active. Otherwise returns `false'.
%% A user that is not active cannot establish a session.
%% See {@link enable/3} and {@link disable/3}.
%% @end
%% -----------------------------------------------------------------------------
-spec is_enabled(User :: t()) -> boolean().

is_enabled(#{type := ?TYPE, enabled := Val}) ->
    Val;

is_enabled(#{type := ?TYPE}) ->
    true.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user identified with `Username' is enabled. Otherwise
%% returns `false'.
%% A user that is not enabled cannot establish a session.
%% See {@link enable/2} and {@link disable/3}.
%% @end
%% -----------------------------------------------------------------------------
-spec is_enabled(RealmUri :: uri(), Username :: binary()) -> boolean().

is_enabled(RealmUri, Username) ->
    is_enabled(fetch(RealmUri, Username)).


%% -----------------------------------------------------------------------------
%% @doc If the user `User' is not sso-managed, returns `User' unmodified.
%% Otherwise, fetches the user's credentials, the enabled status and additional
%% metadata from the SSO Realm and merges it into `User' using the following
%% procedure:
%%
%% * Copies the `password' and `authorized_keys' from the SSO user into `User'.
%% * Adds the `meta` contents from the SSO user to a key names `sso' to the
%% `User' `meta' map.
%% * Sets the `enabled' property by performing the conjunction (logical AND) of
%% both user records.
%%
%% The call fails with an exception if the SSO user associated with `User' was
%% not found.
%% @end
%% -----------------------------------------------------------------------------
-spec resolve(User :: t()) -> Resolved :: t() | no_return().

resolve(#{type := ?TYPE, sso_realm_uri := Uri} = User0) when is_binary(Uri) ->
    SSOUser = fetch(Uri, maps:get(username, User0)),
    User1 = maps:merge(User0, maps:with([password, authorized_keys], SSOUser)),

    User2 = case maps:find(meta, SSOUser) of
        {ok, Meta} ->
            maps_utils:put_path([meta, sso], Meta, User1);
        error ->
            User1
    end,

    Enabled = maps:get(enabled, SSOUser, true)
        andalso maps:get(enabled, User0, true),

    maps:put(enabled, Enabled, User2);

resolve(#{type := ?TYPE} = User) ->
    User.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user `User' has a password. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec has_password(User :: t()) -> boolean().

has_password(#{type := ?TYPE} = User) ->
    maps:is_key(password, User).


%% -----------------------------------------------------------------------------
%% @doc Returns the password object or `undefined' if the user does not have a
%% password. See {@link bondy_password}.
%% @end
%% -----------------------------------------------------------------------------
-spec password(User :: t()) ->
    maybe(bondy_password:future() | bondy_password:t()).

password(#{type := ?TYPE, password := Future}) when is_function(Future, 1) ->
    Future;

password(#{type := ?TYPE, password := PW}) ->
    %% In previous versions we stored a proplists,
    %% so we call from_term/1. This is not an actual upgrade as the resulting
    %% value does not replace the previous one in the database.
    %% Upgrades will be forced during authentication or can be done by batch
    %% migration process.
    bondy_password:from_term(PW);

password(#{type := ?TYPE}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user `User' has a authorized keys.
%% Otherwise returns `false'.
%% See {@link authorized_keys/1}.
%% @end
%% -----------------------------------------------------------------------------
-spec has_authorized_keys(User :: t()) -> boolean().

has_authorized_keys(#{type := ?TYPE, authorized_keys := Val}) ->
    length(Val) > 0;

has_authorized_keys(#{type := ?TYPE}) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc Returns the list of authorized keys for this user. These keys are used
%% with the WAMP Cryptosign authentication method or equivalent.
%% @end
%% -----------------------------------------------------------------------------
authorized_keys(#{type := ?TYPE, authorized_keys := Val}) ->
    Val;

authorized_keys(#{type := ?TYPE}) ->
    [].

%% -----------------------------------------------------------------------------
%% @doc Returns the metadata map associated with the user `User'.
%% @end
%% -----------------------------------------------------------------------------
-spec meta(User :: t()) -> map().

meta(#{type := ?TYPE, meta := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Adds a new user to the RBAC store. `User' MUST have been
%% created using {@link new/1} or {@link new/2}.
%% This record is globally replicated.
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), t()) -> {ok, t()} | {error, add_error()}.

add(RealmUri, #{type := ?TYPE, username := Username} = User) ->
    try
        %% This should have been validated before but just to avoid any issues
        %% we do it again.
        %% We asume the username is normalised
        ok = not_reserved_name_check(Username),
        do_add(RealmUri, User)
    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc Adds a new user or updates an existing one.
%% This change is globally replicated.
%% @end
%% -----------------------------------------------------------------------------
-spec add_or_update(RealmUri :: uri(), User :: t()) ->
    {ok, t()} | {error, add_error()}.

add_or_update(RealmUri, User) ->
    add_or_update(RealmUri, User, #{}).


%% -----------------------------------------------------------------------------
%% @doc Adds a new user or updates an existing one.
%% This change is globally replicated.
%% @end
%% -----------------------------------------------------------------------------
-spec add_or_update(RealmUri :: uri(), User :: t(), Opts :: update_opts()) ->
    {ok, t()} | {error, add_error()}.

add_or_update(RealmUri, #{type := ?TYPE, username := Username} = User, Opts) ->
    try
        maybe_throw(add(RealmUri, User))
    catch
        throw:already_exists ->
            update(RealmUri, Username, User, Opts);

        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc Updates an existing user.
%% This change is globally replicated.
%% @end
%% -----------------------------------------------------------------------------
-spec update(RealmUri :: uri(), Username :: binary(), Data :: map()) ->
    {ok, NewUser :: t()} | {error, update_error()}.

update(RealmUri, Username, Data) ->
    update(RealmUri, Username, Data, #{}).


%% -----------------------------------------------------------------------------
%% @doc Updates an existing user.
%% This change is globally replicated.
%% @end
%% -----------------------------------------------------------------------------
-spec update(
    RealmUri :: uri(),
    UserOrUsername :: t() | binary(),
    Data :: map(),
    Opts :: update_opts()) ->
    {ok, NewUser :: t()} | {error, any()}.

update(RealmUri, #{type := ?TYPE} = User, Data0, Opts) ->
    try

        Data = maps_utils:validate(Data0, ?UPDATE_VALIDATOR),
        do_update(RealmUri, User, Data, Opts)
    catch
        error:{no_such_user, _} = Reason ->
            {error, Reason};
        throw:Reason ->
            {error, Reason}
    end;

update(RealmUri, Username0, Data0, Opts) when is_binary(Username0) ->
    try

        Data = maps_utils:validate(Data0, ?UPDATE_VALIDATOR),
        Username = normalise_username(Username0),
        ok = not_reserved_name_check(Username),
        User = fetch(RealmUri, Username),
        do_update(RealmUri, User, Data, Opts)
    catch
        error:{no_such_user, _} = Reason ->
            {error, Reason};
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), binary() | map()) ->
    ok | {error, {no_such_user, username()} | reserved_name}.

remove(RealmUri, #{type := ?TYPE, username := Username}) ->
    remove(RealmUri, Username);

remove(RealmUri, Username0) ->
    %% TODO do not allow remove when this is an SSO realm and user exists in
    %% other realms (we need a reverse index - array with the list of realms
    %% this user belongs to.
    try
        Username = normalise_username(Username0),

        ok = not_reserved_name_check(Username),
        ok = exists_check(RealmUri, Username),

        %% We remove this user from sources
        ok = bondy_rbac_source:remove_all(RealmUri, Username),

        %% delete any associated grants, so if a user with the same name
        %% is added again, they don't pick up these grants
        ok = bondy_rbac:revoke_user(RealmUri, Username),

        %% We finally delete the user
        ok = plum_db:delete(?PLUMDB_PREFIX(RealmUri), Username),

        on_delete(RealmUri, Username)

    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(RealmUri :: uri(), Username :: binary()) ->
    t() | {error, not_found}.

lookup(RealmUri, Username0) ->
    case normalise_username(Username0) of
        anonymous ->
            ?ANONYMOUS;
        Username ->
            Prefix = ?PLUMDB_PREFIX(RealmUri),

            case plum_db:get(Prefix, Username) of
                undefined -> {error, not_found};
                Value -> from_term({Username, Value})
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec exists(RealmUri :: uri(), Username :: binary()) -> boolean().

exists(RealmUri, Username0) ->
    lookup(RealmUri, Username0) =/= {error, not_found}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(uri(), binary()) -> t() | no_return().

fetch(RealmUri, Username) ->
    case lookup(RealmUri, Username) of
        {error, not_found} ->
            error({no_such_user, Username});
        User ->
            User
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri()) -> list(t()).

list(RealmUri) ->
    list(RealmUri, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(RealmUri :: uri(), Opts :: list_opts()) -> list(t()).

list(RealmUri, Opts) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),

    FoldOpts = case maps_utils:get_any([limit, <<"limit">>], Opts, undefined) of
        undefined ->
            ?FOLD_OPTS;
        Limit ->
            [{limit, Limit} | ?FOLD_OPTS]
    end,

    plum_db:fold(
        fun
            ({_, ?TOMBSTONE}, Acc) ->
                Acc;
            ({_, _} = Term, Acc) ->
                %% Consider legacy storage formats
                [from_term(Term)|Acc]
        end,
        [],
        Prefix,
        FoldOpts
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
change_password(RealmUri, Username, New) when is_binary(New) ->
    change_password(RealmUri, Username, New, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------

change_password(RealmUri, Username, New, Old) ->
    case lookup(RealmUri, Username) of
        {error, not_found} = Error ->
            Error;
        #{} = User ->
            do_change_password(RealmUri, resolve(User), New, Old)
    end.


%% @private
do_change_password(RealmUri, #{password := PW, username := Username}, New, Old)
when Old =/= undefined ->
    case bondy_password:verify_string(Old, PW) of
        true when Old == New ->
            ok;
        true ->
            update_credentials(RealmUri, Username, #{password => New});
        false ->
            {error, bad_signature}
    end;

do_change_password(RealmUri, #{username := Username}, New, _) ->
        %% User did not have a password or is an SSO user,
        %% update_credentials knows how to forward the change to the
        %% SSO realm
        update_credentials(RealmUri, Username, #{password => New}).


%% -----------------------------------------------------------------------------
%% @doc Sets the value of the `enabled' property to `true'.
%% See {@link is_enabled/2}.
%% @end
%% -----------------------------------------------------------------------------
-spec enable(RealmUri :: uri(), User :: t()) ->
    ok | {error, any()}.

enable(RealmUri, #{type := ?TYPE} = User) ->
    case update(RealmUri, User, #{enabled => true}) of
        {ok, _} -> ok;
        Error -> Error
    end.


%% -----------------------------------------------------------------------------
%% @doc Sets the value of the `enabled' property to `false'.
%% See {@link is_enabled/2}.
%% @end
%% -----------------------------------------------------------------------------
-spec disable(RealmUri :: uri(), User :: t()) ->
    ok | {error, any()}.

disable(RealmUri, #{type := ?TYPE} = User) ->
    case update(RealmUri, User, #{enabled => false}) of
        {ok, _} -> ok;
        Error -> Error
    end.

%% -----------------------------------------------------------------------------
%% @doc Returns the external representation of the user `User'.
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(User :: t()) -> external().

to_external(#{type := ?TYPE, version := ?VERSION} = User) ->
    Map = maps:without([password, authorized_keys], User),

    Map#{
        has_password => has_password(User),
        has_authorized_keys => has_authorized_keys(User)
    }.


%% -----------------------------------------------------------------------------
%% @doc Adds group named `Groupname' to users `Users' in realm with uri
%% `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec add_group(
    RealmUri :: uri(),
    Users :: all | t() | list(t()) | username() | list(username()),
    Groupname :: bondy_rbac_group:name()) -> ok.

add_group(RealmUri, Users, Groupname) ->
    add_groups(RealmUri, Users, [Groupname]).


%% -----------------------------------------------------------------------------
%% @doc Adds groups `Groupnames' to users `Users' in realm with uri
%% `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec add_groups(
    RealmUri :: uri(),
    Users :: all | t() | list(t()) | username() | list(username()),
    Groupnames :: [bondy_rbac_group:name()]) -> ok.

add_groups(RealmUri, Users, Groupnames)  ->
    Fun = fun(Current, ToAdd) ->
        ordsets:to_list(
            ordsets:union(
                ordsets:from_list(Current),
                ordsets:from_list(ToAdd)
            )
        )
    end,

    try
        update_groups(RealmUri, Users, Groupnames, Fun)
    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc Removes groups `Groupnames' from users `Users' in realm with uri
%% `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_group(
    RealmUri :: uri(),
    Users :: all | t() | list(t()) | username() | list(username()),
    Groupname :: bondy_rbac_group:name()) -> ok.

remove_group(RealmUri, Users, Groupname) ->
    remove_groups(RealmUri, Users, [Groupname]).


%% -----------------------------------------------------------------------------
%% @doc Removes groups `Groupnames' from users `Users' in realm with uri
%% `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_groups(
    RealmUri :: uri(),
    Users :: all | t() | list(t()) | username() | list(username()),
    Groupnames :: [bondy_rbac_group:name()]) -> ok.

remove_groups(RealmUri, Users, Groupnames) ->
    Fun = fun(Current, ToRemove) ->
        Current -- ToRemove
    end,

    try
        update_groups(RealmUri, Users, Groupnames, Fun)
    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc Takes a list of usernames and returns any that can't be found.
%% @end
%% -----------------------------------------------------------------------------
-spec unknown(RealmUri :: uri(), Usernames :: [username()]) ->
    Unknown :: [username()].

unknown(_, []) ->
    [];

unknown(RealmUri, Usernames) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),
    Set = ordsets:from_list(Usernames),
    ordsets:fold(
        fun
            (anonymous, Acc) ->
                Acc;
            (Username0, Acc) when is_binary(Username0) ->
                Username = normalise_username(Username0),
                case plum_db:get(Prefix, Username) of
                    undefined -> [Username | Acc];
                    _ -> Acc
                end
        end,
        [],
        Set
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec normalise_username(Term :: username()) -> username() | no_return().

normalise_username(anonymous) ->
    anonymous;

normalise_username(<<"anonymous">>) ->
    anonymous;

normalise_username(Term) when is_binary(Term) ->
    string:casefold(Term);

normalise_username(_) ->
    error(badarg).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec do_add(RealmUri :: binary(), User :: t()) -> ok | no_return().

do_add(RealmUri, #{sso_realm_uri := SSOUri} = User0) when is_binary(SSOUri) ->
    Username = maps:get(username, User0),

    %% Key validations first
    ok = not_exists_check(RealmUri, Username),
    ok = groups_exists_check(RealmUri, maps:get(groups, User0, [])),

    %% We split the user into LocalUser, SSOUser and Opts
    {Opts, User1} = maps_utils:split([password_opts], User0),
    User2 = apply_password(User1, password_opts(RealmUri, Opts)),

    {SSOUser0, LocalUser} = maps_utils:split(
        [password, authorized_keys], User2
    ),

    SSOUser = type_and_version(SSOUser0#{
        username => Username,
        groups => [],
        meta => #{}
    }),

    ok = maybe_add_sso_user(
        not exists(SSOUri, Username), RealmUri, SSOUri, SSOUser
    ),

    %% We finally add the local user to the realm
    store(RealmUri, LocalUser, fun on_create/2);

do_add(RealmUri, User0) ->
    Username = maps:get(username, User0),

    %% Key validations first
    ok = not_exists_check(RealmUri, Username),
    ok = groups_exists_check(RealmUri, maps:get(groups, User0, [])),

    %% We split the user into LocalUser, SSOUSer and Opts
    {Opts, User1} = maps_utils:split([sso_opts, password_opts], User0),
    User = apply_password(User1, password_opts(RealmUri, Opts)),

    store(RealmUri, User, fun on_create/2).


%% @private
maybe_add_sso_user(true, RealmUri, SSOUri, SSOUser) ->

    bondy_realm:is_allowed_sso_realm(RealmUri, SSOUri)
        orelse throw(invalid_sso_realm),

    ok = groups_exists_check(SSOUri, maps:get(groups, SSOUser, [])),

    %% We first add the user to the SSO realm
    {ok, _} = maybe_throw(store(SSOUri, SSOUser, fun on_create/2)),
    ok;

maybe_add_sso_user(false, _, _, _) ->
    ok.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec do_update(
    RealmUri :: binary(),
    User :: t(),
    Data :: map(),
    Opts :: update_opts()) ->
    ok | no_return().

do_update(RealmUri, #{sso_realm_uri := SSOUri} = User, Data0, Opts)
when is_binary(SSOUri) ->
    Username = maps:get(username, User),

    case lookup(SSOUri, Username) of
        {error, not_found} ->
            throw(not_such_user);
        SSOUser ->
            {SSOData, LocalData} = maps_utils:split(
                [password_opts, password, authorized_keys], Data0
            ),

            _ = maybe_throw(
                do_local_update(SSOUri, SSOUser, SSOData, Opts)
            ),
            do_local_update(RealmUri, User, LocalData, Opts)
    end;

do_update(RealmUri, User, Data, Opts) when is_map(User) ->
    do_local_update(RealmUri, User, Data, Opts).


%% @private
do_local_update(RealmUri, User, Data0, Opts0) ->
    ok = groups_exists_check(RealmUri, maps:get(groups, Data0, [])),
    %% We split the data into LocalUser and Opts
    {UserOpts, Data} = maps_utils:split([password_opts], Data0),
    Opts = maps:merge(UserOpts, Opts0),
    NewUser = merge(RealmUri, User, Data, Opts),
    store(RealmUri, NewUser, fun on_update/2).


%% @private
update_credentials(RealmUri, Username, Data) ->
    Opts = #{
        update_credentials => true
    },
    case update(RealmUri, Username, Data, Opts) of
        {ok, User} ->
            on_credentials_change(RealmUri, User);
        Error ->
            Error
    end.


%% @private
-spec update_groups(
    RealmUri :: uri(),
    Users :: all | t() | list(t()) | username() | list(username()),
    Groupnames :: [bondy_rbac_group:name()],
    Fun :: fun((list(), list()) -> list())
) -> ok | no_return().

update_groups(RealmUri, all, Groupnames, Fun) ->
    plum_db:fold(fun
        ({_, [?TOMBSTONE]}, Acc) ->
            Acc;
        ({_, _} = Term, Acc) ->
            ok = update_groups(RealmUri, from_term(Term), Groupnames, Fun),
            Acc
        end,
        ok,
        ?PLUMDB_PREFIX(RealmUri),
        ?FOLD_OPTS
    );

update_groups(RealmUri, Users, Groupnames, Fun) when is_list(Users) ->
    _ = [
        update_groups(RealmUri, User, Groupnames, Fun) || User <- Users
    ],
    ok;

update_groups(RealmUri, #{type := ?TYPE} = User, Groupnames, Fun)
when is_function(Fun, 2) ->
    Update = #{groups => Fun(maps:get(groups, User), Groupnames)},
    case update(RealmUri, User, Update) of
        {ok, _} -> ok;
        {error, Reason} -> throw(Reason)
    end;

update_groups(RealmUri, Username, Groupnames, Fun) when is_binary(Username) ->
    update_groups(RealmUri, fetch(RealmUri, Username), Groupnames, Fun).


%% @private
store(RealmUri, #{username := Username} = User, Fun) ->
    case plum_db:put(?PLUMDB_PREFIX(RealmUri), Username, User) of
        ok ->
            ok = Fun(RealmUri, User),
            {ok, User};
        Error ->
            Error
    end.


%% @private
password_opts(_, #{password_opts := Opts}) when is_map(Opts) ->
    Opts;

password_opts(RealmUri, _) ->
    bondy_realm:password_opts(RealmUri).


%% @private
merge(RealmUri, U1, U2, #{update_credentials := true} = Opts) ->
    User = maps:merge(U1, U2),
    P0 = maps:get(password, U1, undefined),
    Future = maps:get(password, U2, undefined),

    case {P0, Future} of
        {undefined, undefined} ->
            User;

        {undefined, _}  ->
            apply_password(User, password_opts(RealmUri, Opts));

        {P0, undefined} ->
            bondy_password:is_type(P0) orelse error(badarg),
            User;

        {P0, Future} when is_function(Future, 1) ->
            apply_password(User, password_opts(RealmUri, Opts));

        {_, P1} ->
            bondy_password:is_type(P1) orelse error(badarg),
            maps:put(password, P1, User)

    end;

merge(_, U1, U2, _) ->
    %% We only allow updates to modify password if explicitely requested via
    %% option update_credentials.
    %% authorized_keys are allowed to be merge as the contain public keys.
    maps:merge(U1, maps:without([password], U2)).


%% @private
maybe_apply_password(User, #{password_opts := POpts}) when is_map(POpts) ->
    apply_password(User, POpts);

maybe_apply_password(User, _) ->
    User.


%% @private
apply_password(#{password := Future} = User, POpts)
when is_function(Future, 1) ->
    PWD = bondy_password:new(Future, POpts),
    maps:put(password, PWD, User);

apply_password(#{password := P} = User, _) ->
    bondy_password:is_type(P) orelse error(badarg),
    %% The password was already generated
    User;

apply_password(User, _) ->
    User.


%% @private
maybe_throw({error, Reason}) ->
    throw(Reason);

maybe_throw(Term) ->
    Term.

%% @private
exists_check(RealmUri, Username) ->
    case plum_db:get(?PLUMDB_PREFIX(RealmUri), Username) of
        undefined -> throw({no_such_user, Username});
        _ -> ok
    end.


%% @private
not_exists_check(RealmUri, Username) ->
    case plum_db:get(?PLUMDB_PREFIX(RealmUri), Username) of
        undefined -> ok;
        _ -> throw(already_exists)
    end.

%% @private
groups_exists_check(RealmUri, Groups) ->
    case bondy_rbac_group:unknown(RealmUri, Groups) of
        [] ->
            ok;
        Unknown ->
            throw({no_such_groups, Unknown})
    end.


%% @private
not_reserved_name_check(Term) ->
    not bondy_rbac:is_reserved_name(Term) orelse throw(reserved_name),
    ok.


%% @private
from_term({Username, PList}) when is_list(PList) ->
    User0 = maps:from_list(
        lists:keymap(fun erlang:binary_to_existing_atom/1, 1, PList)
    ),
    %% Prev to v1.1 we removed the username (key) from the payload (value).
    User = maps:put(username, Username, User0),
    type_and_version(User);

from_term({_, #{type := ?TYPE, version := ?VERSION} = User}) ->
    User.


%% @private
type_and_version(Map) ->
    Map#{
        version => ?VERSION,
        type => ?TYPE
    }.


%% @private
on_create(RealmUri, #{username := Username}) ->
    ok = bondy_event_manager:notify(
        {rbac_user_added, RealmUri, Username}
    ),
    ok.


%% @private
on_update(RealmUri, #{username := Username}) ->
    ok = bondy_event_manager:notify(
        {rbac_user_updated, RealmUri, Username}
    ),
    ok.


%% @private
on_credentials_change(RealmUri, #{username := Username} = User) ->
    ok = bondy_event_manager:notify(
        {rbac_user_credentials_changed, RealmUri, Username}
    ),
    on_update(RealmUri, User).


%% @private
on_delete(RealmUri, Username) ->
    ok = bondy_event_manager:notify(
        {rbac_user_deleted, RealmUri, Username}
    ),
    ok.


