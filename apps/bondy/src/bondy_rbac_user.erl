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
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rbac_user).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").


-define(VALIDATOR, ?OPTS_VALIDATOR#{
    <<"username">> => #{
        alias => username,
		key => username,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary,
        validator => fun bondy_data_validators:strict_username/1
    },
    <<"password">> => #{
        alias => password,
		key => password,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => [binary, {function, 0}, map],
        validator => fun bondy_data_validators:password/1
    },
    <<"authorized_keys">> => #{
        alias => authorized_keys,
		key => authorized_keys,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => {list, binary},
        validator => {list, fun bondy_data_validators:authorized_key/1}
    },
    <<"groups">> => #{
        alias => groups,
		key => groups,
        allow_null => false,
        allow_undefined => false,
        required => true,
        default => [],
        datatype => {list, binary},
        validator => fun bondy_data_validators:groupnames/1
    },
    <<"meta">> => #{
        alias => meta,
		key => meta,
        allow_null => false,
        allow_undefined => false,
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
        allow_null => false,
        allow_undefined => false,
        datatype => [binary, {function, 0}, map],
        validator => fun bondy_data_validators:password/1
    },
    <<"authorized_keys">> => #{
        alias => authorized_keys,
		key => authorized_keys,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => {list, binary},
        validator => {list, fun bondy_data_validators:authorized_key/1}
    },
    <<"groups">> => #{
        alias => groups,
		key => groups,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => {list, binary},
        validator => {list, fun bondy_data_validators:groupname/1}
    },
    <<"meta">> => #{
        alias => meta,
		key => meta,
        allow_null => false,
        allow_undefined => false,
        required => false,
        datatype => map
    }
}).


-define(OPTS_VALIDATOR, #{
    <<"sso_opts">> => #{
        alias => sso_opts,
        key => sso_opts,
        required => false,
        datatype => map,
        validator => ?SSO_OPTS_VALIDATOR
    },
    <<"password_opts">> => #{
        alias => password_opts,
        key => password_opts,
        required => false,
        datatype => map,
        validator => fun bondy_password:opts_validator/1
    }
}).

-define(SSO_OPTS_VALIDATOR, #{
    <<"realm_uri">> => #{
        alias => realm_uri,
        key => realm_uri,
        required => true,
        datatype => binary,
        allow_undefined => true,
        default => undefined,
        validator => fun bondy_data_validators:realm_uri/1
    },
    <<"password">> => #{
        alias => password,
		key => password,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => [binary, {function, 0}, map],
        validator => fun bondy_data_validators:password/1
    },
    <<"authorized_keys">> => #{
        alias => authorized_keys,
		key => authorized_keys,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => {list, binary},
        validator => {list, fun bondy_data_validators:authorized_key/1}
    },
    <<"groups">> => #{
        alias => groups,
		key => groups,
        allow_null => false,
        allow_undefined => false,
        required => false,
        datatype => {list, binary},
        validator => fun bondy_data_validators:groupnames/1
    },
    <<"meta">> => #{
        alias => meta,
		key => meta,
        allow_null => false,
        allow_undefined => false,
        datatype => map
    }
}).


-define(ANONYMOUS, type_and_version(#{
    username => anonymous,
    groups => [anonymous],
    meta => #{}
})).

-define(TYPE, user).
-define(VERSION, <<"1.1">>).
-define(PLUMDB_PREFIX(RealmUri), {security_users, RealmUri}).
-define(FOLD_OPTS, [{resolver, lww}]).

-type t()       ::  #{
    type                :=  ?TYPE,
    version             :=  binary(),
    username            :=  username(),
    groups              :=  [binary()],
    password            =>  bondy_password:future() | bondy_password:t(),
    authorized_keys     =>  [binary()],
    sso_realm_uri       =>  maybe(uri()),
    meta                =>  #{binary() => any()},
    %% Transient will not be stored
    sso_opts            =>  sso_opts(),
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
    sso_opts            =>  sso_opts(),
    password_opts       =>  bondy_password:opts()
}.
-type update_opts()        ::  #{
    forward_credentials     =>  boolean(),
    update_credentials      =>  boolean(),
    sso_opts                =>  sso_opts(),
    password_opts           =>  bondy_password:opts()
}.
-type sso_opts()        ::  #{
    realm_uri           =>  uri(),
    password            =>  bondy_password:future() | bondy_password:t(),
    authorized_keys     =>  [binary()],
    groups              =>  [binary()],
    meta                =>  #{binary() => any()}
}.
-type add_error()       ::  no_such_realm | reserved_name | already_exists.
-type update_error()    ::  no_such_realm
                            | reserved_name
                            | no_such_user
                            | {no_such_groups, [bondy_rbac_group:name()]}.

-type list_opts()       ::  #{
    limit => pos_integer()
}.


-export_type([t/0]).
-export_type([external/0]).
-export_type([new_opts/0]).
-export_type([sso_opts/0]).
-export_type([add_opts/0]).
-export_type([update_opts/0]).


-export([add/2]).
-export([add_group/3]).
-export([add_groups/3]).
-export([add_or_update/2]).
-export([add_or_update/3]).
-export([authorized_keys/1]).
-export([change_authorized_keys/3]).
-export([change_password/3]).
-export([change_password/4]).
-export([exists/2]).
-export([fetch/2]).
-export([groups/1]).
-export([has_authorized_keys/1]).
-export([has_password/1]).
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
%% @doc If the user `User' is no sso-managed, returns `User' unmodified.
%% Otherwise, fetches the user's credentials and additional metadata from the
%% SSO Realm and merges it into `User' using the following procedure:
%%
%% * Copies the `password' and `authorized_keys' from the SSO user into `User'.
%% * Adds the `meta` contents from the SSO user to a key names `sso' to the
%% `User' `meta' map.
%%
%% The call fails with an exception if the SSO user associated with `User' was
%% not found.
%% @end
%% -----------------------------------------------------------------------------
-spec resolve(User :: t()) -> Resolved :: t() | no_return().

resolve(#{type := ?TYPE, sso_realm_uri := Uri, username := Username} = User0) ->
    SSOUser = fetch(Uri, Username),
    User = maps:merge(User0, maps:with([password, authorized_keys], SSOUser)),
    case maps:find(meta, SSOUser) of
        {ok, Meta} ->
            maps_utils:put_path([meta, sso], Meta, User);
        error ->
            User
    end;

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

has_authorized_keys(#{type := user}) ->
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
%% created using {@link new/1,2}.
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
    Username :: binary(),
    Data :: map(),
    Opts :: update_opts()) ->
    {ok, NewUser :: t()} | {error, any()}.

update(RealmUri, Username0, Data0, Opts) when is_binary(Username0) ->
    try

        Data = maps_utils:validate(Data0, ?UPDATE_VALIDATOR),
        Username = normalise_username(Username0),
        ok = not_reserved_name_check(Username),
        User = fetch(RealmUri, Username),
        do_update(RealmUri, User, Data, Opts)
    catch
        error:no_such_user ->
            {error, no_such_user};
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), binary() | map()) ->
    ok | {error, no_such_user | reserved_name}.

remove(RealmUri, #{type := ?TYPE, username := Username}) ->
    remove(RealmUri, Username);

remove(RealmUri, Username0) ->
    try
        Username = normalise_username(Username0),

        ok = not_reserved_name_check(Username),
        ok = exists_check(RealmUri, Username),

        %% We remove this user from sources
        ok = bondy_rbac_source:remove_all(RealmUri, Username),

        %% delete any associated grants, so if a user with the same name
        %% is added again, they don't pick up these grants
        ok = bondy_rbac_policy:revoke_user(RealmUri, Username),

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
            error(no_such_user);
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
change_authorized_keys(RealmUri, Username, Keys) when is_list(Keys) ->
    update_credentials(RealmUri, Username, #{authorized_keys => Keys}).


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
        #{password := PW} when Old =/= undefined ->
            case bondy_password:verify_string(Old, PW) of
                true when Old == New ->
                    ok;
                true ->
                    update_credentials(RealmUri, Username, #{password => New});
                false ->
                    {error, bad_signature}
            end;
        _ ->
            %% User did not have a password or is an SSO user,
            %% update_credentials knows how to forward the change to the
            %% SSO realm
            update_credentials(RealmUri, Username, #{password => New})
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
         sets:to_list(
            sets:union(
                sets:from_list(Current),
                sets:from_list(ToAdd)
            )
        )
    end,
    update_groups(RealmUri, Users, Groupnames, Fun).


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
    update_groups(RealmUri, Users, Groupnames, Fun).


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

do_add(RealmUri, #{sso_opts := #{realm_uri := SSOUri} = SSOOpts} = User0)
when is_binary(SSOUri) ->
    Username = maps:get(username, User0),

    %% Key validations first
    ok = not_exists_check(RealmUri, Username),
    ok = groups_exists_check(RealmUri, maps:get(groups, User0, [])),

    %% We split the user into LocalUser, SSOUser and Opts
    {Opts, User1} = maps_utils:split([sso_opts, password_opts], User0),
    User2 = apply_password(User1, password_opts(RealmUri, Opts)),
    {SSOUser0, LocalUser0} = maps_utils:split(
        [password, authorized_keys], User2
    ),

    LocalUser = LocalUser0#{
        sso_realm_uri => SSOUri
    },

    SSOUser = type_and_version(SSOUser0#{
        username => Username,
        groups => maps:get(groups, SSOOpts, []),
        meta => maps:get(meta, SSOOpts, #{})
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

do_update(
    RealmUri,
    User,
    #{sso_opts := #{realm_uri := SSOUri} = SSOOpts} = Data0,
    Opts
) when is_map(User) ->
    Username = maps:get(username, User),

    case lookup(SSOUri, Username) of
        {error, not_found} ->
            throw(not_such_user);

        SSOUser ->
            Keys = case maps:find(forward_credentials, Opts) of
                {ok, true} ->
                    [sso_opts];
                _ ->
                    [
                        sso_opts,
                        password_opts,
                        password,
                        authorized_keys
                    ]
            end,

            {SSOData0, LocalData} = maps_utils:split(
                [password_opts, password, authorized_keys],
                maps:without(Keys, Data0)
            ),

            SSOData1 = case maps:find(groups, SSOOpts) of
                {ok, Groups} ->
                    maps:put(groups, Groups, SSOData0);
                _ ->
                    SSOData0
            end,

            SSOData = case maps:find(meta, SSOOpts) of
                {ok, Meta} ->
                    maps:put(meta, Meta, SSOData1);
                _ ->
                    SSOData1
            end,

            _ = maybe_throw(
                do_update(SSOUri, SSOUser, SSOData, Opts)
            ),
            do_update(RealmUri, User, LocalData, Opts)
    end;

do_update(RealmUri, User, Data0, Opts0) when is_map(User) ->
    ok = groups_exists_check(RealmUri, maps:get(groups, Data0, [])),
    %% We split the user into LocalUser and Opts
    {UserOpts, Data} = maps_utils:split([sso_opts, password_opts], Data0),
    Opts = maps:merge(UserOpts, Opts0),
    NewUser = merge(RealmUri, User, Data, Opts),
    store(RealmUri, NewUser, fun on_update/2).


%% @private
update_credentials(RealmUri, Username, Data) ->
    %% We force credentials to be updated and forwarded to the SSO realm if
    %% defined
    Opts = #{
        update_credentials => true,
        forward_credentials => true
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
) -> ok.

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
when is_function(2, Fun) ->
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
    %% We only allow updates to modify credentials if explicitely requested via
    %% option update_credentials
    maps:merge(U1, maps:without([password, authorized_keys], U2)).


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
        undefined -> throw(no_such_user);
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


