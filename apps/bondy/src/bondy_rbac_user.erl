%% =============================================================================
%%  bondy_rbac_user.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
%% Users have attributes associated with themelves like username, credentials
%% (password or authorized keys) and metadata determined by the client
%% applications. Users can be assigned group memberships.
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rbac_user).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").
-include("bondy_plum_db.hrl").

-define(MAX_ALIASES, 5).
-define(ALIAS_TYPE, alias).
-define(IS_ALIAS(X), ?ALIAS_TYPE =:= map_get(type, X)).
-define(USER_TYPE, user).
-define(IS_USER(X), ?USER_TYPE =:= map_get(type, X)).
-define(VERSION, <<"1.1">>).
-define(PLUMDB_PREFIX(RealmUri), {?PLUM_DB_USER_TAB, RealmUri}).

%% TODO resolver function to reconcile sso_realm_uri, meta, groups,
%% password and authorized_keys. In the case of sso_realm_uri and groups
%% checking whether they exist.
-define(FOLD_OPTS, [{resolver, lww}]).

-define(VALIDATOR, begin ?OPTS_VALIDATOR end#{
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


-define(UPDATE_VALIDATOR, begin ?OPTS_VALIDATOR end#{
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
        validator => bondy_password:opts_validator()
    }
}).

%% The anonymous user object (a constant)
-define(ANONYMOUS, #{
    type => ?USER_TYPE,
    version => ?VERSION,
    username => anonymous,
    groups => [anonymous],
    meta => #{}
}).


-type t()       ::  #{
    type                :=  ?USER_TYPE,
    version             :=  binary(),
    username            :=  username(),
    groups              :=  [binary()],
    password            =>  bondy_password:future() | bondy_password:t(),
    authorized_keys     =>  [binary()],
    sso_realm_uri       =>  optional(uri()),
    meta                =>  #{binary() => any()},
    %% Transient, will not be stored
    password_opts       =>  bondy_password:opts()
}.

% -type alias()    ::  #{
%     type                :=  ?ALIAS_TYPE,
%     alias               :=  username(),
%     username            :=  username()
% }.


-type external() ::  #{
    type                :=  ?USER_TYPE,
    version             :=  binary(),
    username            :=  username_int(),
    groups              :=  [binary()],
    has_password        :=  boolean(),
    has_authorized_keys :=  boolean(),
    authorized_keys     =>  [binary()],
    sso_realm_uri       =>  optional(uri()),
    meta                =>  #{binary() => any()}
}.

-type username()        ::  binary().
-type username_int()    ::  username() | anonymous.
-type new_opts()        ::  #{
    password_opts       => bondy_password:opts()
}.
-type add_opts()        ::  #{
    password_opts       =>  bondy_password:opts(),
    rebase              => boolean(),
    actor_id            => term(),
    if_exists           => fail | update
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
                            | {no_such_user, username_int()}
                            | {no_such_groups, [bondy_rbac_group:name()]}.


-export_type([t/0]).
-export_type([external/0]).
-export_type([username/0]).
-export_type([new_opts/0]).
-export_type([add_opts/0]).
-export_type([update_opts/0]).


-export([add/2]).
-export([add/3]).
-export([add_alias/3]).
-export([add_group/3]).
-export([add_groups/3]).
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
-export([remove/3]).
-export([remove_all/2]).
-export([remove_alias/3]).
-export([remove_group/3]).
-export([remove_groups/3]).
-export([resolve/1]).
-export([resolve/2]).
-export([sso_realm_uri/1]).
-export([to_external/1]).
-export([unknown/2]).
-export([update/3]).
-export([update/4]).
-export([username/1]).

%% PLUM_DB PREFIX CALLBACKS
-export([will_merge/3]).
-export([on_merge/3]).
-export([on_update/3]).
-export([on_delete/2]).
-export([on_erase/2]).



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
    User = type_and_version(?USER_TYPE, maps_utils:validate(Data, ?VALIDATOR)),
    maybe_apply_password(User, Opts).


%% -----------------------------------------------------------------------------
%% @doc Returns the group names the user's username.
%% @end
%% -----------------------------------------------------------------------------
username(#{type := ?USER_TYPE, username := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the group names the user `User' is member of.
%% @end
%% -----------------------------------------------------------------------------
groups(#{type := ?USER_TYPE, groups := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user `User' is a member of the group named
%% `Name'. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_member(Name0 :: bondy_rbac_group:name(), User :: t()) -> boolean().

is_member(Name0, #{type := ?USER_TYPE, groups := Val}) ->
    Name = bondy_rbac_group:normalise_name(Name0),
    Name == all orelse lists:member(Name, Val).


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user `User' is managed in a SSO Realm, `false' if it
%% is locally managed.
%% @end
%% -----------------------------------------------------------------------------
-spec is_sso_user(User :: t()) -> boolean().

is_sso_user(#{type := ?USER_TYPE, sso_realm_uri := Val}) when is_binary(Val) ->
    true;

is_sso_user(#{type := ?USER_TYPE}) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc Returns the URI of the Same Sign-on Realm in case the user is a SSO
%% user. Otherwise, returns `undefined'.
%% @end
%% -----------------------------------------------------------------------------
-spec sso_realm_uri(User :: t()) -> optional(uri()).

sso_realm_uri(#{type := ?USER_TYPE, sso_realm_uri := Val})
when is_binary(Val) ->
    Val;

sso_realm_uri(#{type := ?USER_TYPE}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user `User' is active. Otherwise returns `false'.
%% A user that is not active cannot establish a session.
%% See {@link enable/3} and {@link disable/3}.
%% @end
%% -----------------------------------------------------------------------------
-spec is_enabled(User :: t()) -> boolean().

is_enabled(#{type := ?USER_TYPE, enabled := Val}) ->
    Val;

is_enabled(#{type := ?USER_TYPE}) ->
    true.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user identified with `Username' is enabled. Otherwise
%% returns `false'.
%% A user that is not enabled cannot establish a session.
%% See {@link enable/2} and {@link disable/3}.
%% @end
%% -----------------------------------------------------------------------------
-spec is_enabled(RealmUri :: uri(), Username :: username_int()) -> boolean().

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

resolve(#{type := ?USER_TYPE, sso_realm_uri := Uri} = User)
when is_binary(Uri) ->
    SSOUser = fetch(Uri, maps:get(username, User)),
    resolve(User, SSOUser);

resolve(#{type := ?USER_TYPE} = User) ->
    User.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec resolve(User :: t(), SSOUser :: t()) -> Resolved :: t() | no_return().

resolve(LocalUser, SSOUser) ->
    User1 = maps:merge(
        LocalUser,
        maps:with([password, authorized_keys], SSOUser)
    ),

    User2 = case maps:find(meta, SSOUser) of
        {ok, Meta} ->
            maps_utils:put_path([meta, sso], Meta, User1);
        error ->
            User1
    end,

    Enabled =
        maps:get(enabled, SSOUser, true)
        andalso maps:get(enabled, LocalUser, true),

    maps:put(enabled, Enabled, User2).



%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user `User' has a password. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec has_password(User :: t()) -> boolean().

has_password(#{type := ?USER_TYPE} = User) ->
    maps:is_key(password, User).


%% -----------------------------------------------------------------------------
%% @doc Returns the password object or `undefined' if the user does not have a
%% password. See {@link bondy_password}.
%% @end
%% -----------------------------------------------------------------------------
-spec password(User :: t()) ->
    optional(bondy_password:future() | bondy_password:t()).

password(#{type := ?USER_TYPE, password := Future})
when is_function(Future, 1) ->
    Future;

password(#{type := ?USER_TYPE, password := PW}) ->
    %% In previous versions we stored a proplists,
    %% so we call from_term/1. This is not an actual upgrade as the resulting
    %% value does not replace the previous one in the database.
    %% Upgrades will be forced during authentication or can be done by batch
    %% migration process.
    bondy_password:from_term(PW);

password(#{type := ?USER_TYPE}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if user `User' has authorized keys.
%% Otherwise returns `false'.
%% See {@link authorized_keys/1}.
%% @end
%% -----------------------------------------------------------------------------
-spec has_authorized_keys(User :: t()) -> boolean().

has_authorized_keys(#{type := ?USER_TYPE, authorized_keys := Val}) ->
    length(Val) > 0;

has_authorized_keys(#{type := ?USER_TYPE}) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc Returns the list of authorized keys for this user. These keys are used
%% with the WAMP Cryptosign authentication method or equivalent.
%% @end
%% -----------------------------------------------------------------------------
authorized_keys(#{type := ?USER_TYPE, authorized_keys := Val}) ->
    Val;

authorized_keys(#{type := ?USER_TYPE}) ->
    [].


%% -----------------------------------------------------------------------------
%% @doc Returns the metadata map associated with the user `User'.
%% @end
%% -----------------------------------------------------------------------------
-spec meta(User :: t()) -> map().

meta(#{type := ?USER_TYPE, meta := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Adds a new user to the RBAC store. `User' MUST have been
%% created using {@link new/1} or {@link new/2}.
%% This record is globally replicated.
%%
%% The call returns an error if the username is already associated with another
%% user. Notice that this check is currently performed locally only, this means
%% that a concurrent add on another node will succeed unless this operation
%% broadcast arrives first. To ensure uniqueness the caller could use a strong
%% consistency service e.g. a database with ACID guarantees, or act as a
%% singleton serializing this call.
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), t()) -> {ok, t()} | {error, add_error()}.

add(RealmUri, User) ->
    add(RealmUri, User, #{}).


%% -----------------------------------------------------------------------------
%% @doc Adds a new user to the RBAC store. `User' MUST have been
%% created using {@link new/1} or {@link new/2}.
%% This record is globally replicated.
%%
%% The call returns an error if the username is already associated with another
%% user. Notice that this check is currently performed locally only, this means
%% that a concurrent add on another node will succeed unless this operation
%% broadcast arrives first. To ensure uniqueness the caller could use a strong
%% consistency service e.g. a database with ACID guarantees, or act as a
%% singleton serializing this call.
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), t(), add_opts()) -> {ok, t()} | {error, add_error()}.

add(RealmUri, #{type := ?USER_TYPE, username := Username} = User, Opts) ->
    IfExists = maps:get(if_exists, Opts, fail),
    try
        %% This should have been validated before but just to avoid any issues
        %% we do it again.
        %% We assume the username is normalised
        ok = not_reserved_name_check(Username),
        do_add(RealmUri, User, Opts)
    catch
        throw:already_exists when IfExists == update ->
            Username = maps:get(username, User),
            update(RealmUri, Username, User, Opts);

        throw:already_exists ->
            {error, already_exists};

        throw:Reason ->
            {error, Reason}
    end.



%% -----------------------------------------------------------------------------
%% @doc Updates an existing user.
%% This change is globally replicated.
%% @end
%% -----------------------------------------------------------------------------
-spec update(RealmUri :: uri(), Arg :: username() | t(), Data :: map()) ->
    {ok, NewUser :: t()} | {error, update_error()}.

update(RealmUri, Arg, Data) ->
    update(RealmUri, Arg, Data, #{}).


%% -----------------------------------------------------------------------------
%% @doc Updates an existing user.
%% This change is globally replicated.
%% @end
%% -----------------------------------------------------------------------------
-spec update(
    RealmUri :: uri(),
    Arg :: username() | t(),
    Data :: map(),
    Opts :: update_opts()) ->
    {ok, NewUser :: t()} | {error, any()}.

update(RealmUri, #{type := ?USER_TYPE} = User, Data0, Opts) ->
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

        %% Validations
        Username == anonymous andalso throw(not_allowed),
        ok = not_reserved_name_check(Username),

        User = fetch(RealmUri, Username),
        do_update(RealmUri, User, Data, Opts)
    catch
        error:{no_such_user, _} = Reason ->
            {error, Reason};

        throw:Reason ->
            {error, Reason}
    end;

update(_, anonymous, _, _) ->
    {error, not_allowed}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(RealmUri :: uri(), Arg :: username() | t()) ->
    ok | {error, {no_such_user, username()} | reserved_name}.

remove(RealmUri, Arg) ->
    remove(RealmUri, Arg, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), username() | t(), Opts :: map()) ->
    ok | {error, {no_such_user, username()} | reserved_name}.

remove(RealmUri, #{type := ?USER_TYPE, username := Username}, Opts) ->
    remove(RealmUri, Username, Opts);

remove(RealmUri, Username0, _Opts) when is_binary(Username0) ->
    %% TODO do not allow remove when this is an SSO realm and user exists in
    %% other realms (we need a reverse index - array with the list of realms
    %% this user belongs to.
    try
        Username = normalise_username(Username0),

        ok = not_reserved_name_check(Username),

        User = fetch(RealmUri, Username),
        Aliases = maps:get(aliases, User, []),
        PDBPrefix = ?PLUMDB_PREFIX(RealmUri),

        %% We remove all aliases (if it has any)
        _ = [
            plum_db:delete(PDBPrefix, Alias) || Alias <- Aliases
        ],

        %% We remove this user from sources
        ok = bondy_rbac_source:remove_all(RealmUri, Username),

        %% delete any associated grants, so if a user with the same name
        %% is added again, it doesn't pick up these grants
        ok = bondy_rbac:revoke_user(RealmUri, Username),

        %% We finally delete the user, on_delete/2 will be called by plum_db
        ok = plum_db:delete(PDBPrefix, Username)

    catch
        error:{no_such_user, _} = Reason ->
            {error, Reason};
        throw:Reason ->
            {error, Reason}
    end;

remove(_, anonymous, _) ->
    {error, reserved_name}.


%% -----------------------------------------------------------------------------
%% @doc Removes all users that belongs to realm `RealmUri'.
%% If the option `dirty` is set to `true` this removes the user directly from
%% store (triggering a broadcast to other Bondy nodes). If set to `false` (the
%% default) then for each user the function remove/2 is called.
%%
%% Use `dirty' with a value of `true' only when you are removing the realm
%% entirely.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(uri(), #{dirty => boolean()}) -> ok.

remove_all(RealmUri, Opts) ->
    Dirty = maps:get(dirty, Opts, false),
    Prefix = ?PLUMDB_PREFIX(RealmUri),
    FoldOpts = [{keys_only, true} , {remove_tombstones, true}],

    _ = plum_db:foreach(
        fun
            (Name) when Dirty == true ->
                _ = plum_db:delete(Prefix, Name);
            (Name) ->
                _ = remove(RealmUri, Name, Opts)
        end,
        Prefix,
        FoldOpts
    ),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(RealmUri :: uri(), Username :: username_int()) ->
    t() | {error, not_found}.

lookup(RealmUri, Username0) ->
    case normalise_username(Username0) of
        anonymous ->
            ?ANONYMOUS;

        Username ->
            Prefix = ?PLUMDB_PREFIX(RealmUri),

            case plum_db:get(Prefix, Username) of
                undefined ->
                    {error, not_found};

                Val0 when ?IS_ALIAS(Val0) ->
                    case lookup(RealmUri, maps:get(username, Val0)) of
                        {error, _} = Error ->
                            Error;
                        Val1 when ?IS_USER(Val1) ->
                            Val1;
                        Val1 when ?IS_ALIAS(Val1) ->
                            ?LOG_WARNING(#{
                                description => "Recursive index for user alias",
                                alias => Val0
                            }),
                            {error, not_found};
                        Val1 ->
                            from_term({Username, Val1})
                    end;

                Val0 ->
                    from_term({Username, Val0})
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec exists(RealmUri :: uri(), Username :: username_int()) -> boolean().

exists(RealmUri, Username0) ->
    lookup(RealmUri, Username0) =/= {error, not_found}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(uri(), username_int()) -> t() | no_return().

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
                %% Deleted, we ignore it
                Acc;
            ({_, #{type := ?ALIAS_TYPE}}, Acc) ->
                %% An alias, we ignore it
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
-spec change_password(
    RealmUri :: uri(),
    Username :: username(),
    New :: binary()) -> ok | {error, any()}.

change_password(RealmUri, Username, New) ->
    change_password(RealmUri, Username, New, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec change_password(
    RealmUri :: uri(),
    Username :: username(),
    New :: binary(),
    Old :: binary() | undefined) -> ok | {error, any()}.

change_password(RealmUri, Username, New, Old) ->
    case lookup(RealmUri, Username) of
        {error, not_found} = Error ->
            Error;

        #{} = User ->
            do_change_password(RealmUri, resolve(User), New, Old)
    end.


%% -----------------------------------------------------------------------------
%% @doc Sets the value of the `enabled' property to `true'.
%% See {@link is_enabled/2}.
%% @end
%% -----------------------------------------------------------------------------
-spec enable(RealmUri :: uri(), Arg :: t() | username()) ->
    ok | {error, any()}.

enable(RealmUri, Arg) ->
    case update(RealmUri, Arg, #{enabled => true}) of
        {ok, _} ->
            ok;
        Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc Sets the value of the `enabled' property to `false'.
%% See {@link is_enabled/2}.
%% @end
%% -----------------------------------------------------------------------------
-spec disable(RealmUri :: uri(), Arg :: t() | binary()) ->
    ok | {error, any()}.

disable(RealmUri, Arg) ->
    case update(RealmUri, Arg, #{enabled => false}) of
        {ok, _} ->
            ok;
        Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc Returns the external representation of the user `User'.
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(User :: t()) -> external().

to_external(#{type := ?USER_TYPE, version := ?VERSION} = User) ->
    Keys = maps:get(authorized_keys, User, []),
    Map = maps:without([password, authorized_keys], User),

    Map#{
        authorized_keys => [
            list_to_binary(hex_utils:bin_to_hexstr(Key)) || Key <- Keys
        ],
        has_password => has_password(User),
        has_authorized_keys => has_authorized_keys(User)
    }.


%% -----------------------------------------------------------------------------
%% @doc Adds an alias to the user. If the user is an SSO user, the alias is
%% added on the SSO Realm only.
%% @end
%% -----------------------------------------------------------------------------
-spec add_alias(
    RealmUri :: uri(), User :: t() | username(), Alias :: username()) ->
    ok | {error, Reason :: any()}.

add_alias(_, #{type := ?USER_TYPE, sso_realm_uri := RealmUri} = User, Alias)
when is_binary(RealmUri) ->
    Username = maps:get(username, User),
    do_add_alias(RealmUri, fetch(RealmUri, Username), Alias);

add_alias(RealmUri, #{type := ?USER_TYPE} = User, Alias) ->
   do_add_alias(RealmUri, User, Alias);

add_alias(RealmUri, Username, Alias) ->
    add_alias(RealmUri, fetch(RealmUri, Username), Alias).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_alias(
    RealmUri :: uri(), User :: t() | username(), Alias :: username()) ->
    ok | {error, Reason :: any()}.

remove_alias(
    _, #{type := ?USER_TYPE, sso_realm_uri := RealmUri} = User, Alias)
    when is_binary(RealmUri) ->
    Username = maps:get(username, User),
    remove_alias(RealmUri, Username, Alias);

remove_alias(RealmUri, #{type := ?USER_TYPE} = User, Alias) ->
    do_remove_alias(RealmUri, User, Alias);

remove_alias(RealmUri, Username, Alias) ->
    remove_alias(RealmUri, fetch(RealmUri, Username), Alias).


%% -----------------------------------------------------------------------------
%% @doc Adds group named `Groupname' to users `Users' in realm with uri
%% `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec add_group(
    RealmUri :: uri(),
    Users :: all | t() | list(t()) | username() | list(username()),
    Groupname :: bondy_rbac_group:name()) -> ok | {error, Reason :: any()}.

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
    Groupnames :: [bondy_rbac_group:name()]) -> ok | {error, Reason :: any()}.

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
%% PLUM_DB PREFIX CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc bondy_config
%% @end
%% -----------------------------------------------------------------------------
will_merge(_PKey, _New, _Old) ->
    true.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
on_merge({?PLUMDB_PREFIX(RealmUri), _}, New, undefined = Old) ->
    ?LOG_DEBUG(#{
        description => "on_merge",
        realm_uri => RealmUri,
        new => New,
        old => Old
    }),
    ok;

on_merge({?PLUMDB_PREFIX(RealmUri), Username}, New, Old) ->
    ?LOG_DEBUG(#{
        description => "on_merge",
        new => New,
        old => Old
    }),
    %% We need to determine if the user was deleted or its credentials updated
    %% in which case we need to close all local sessions.
    %% Tickets and tokens have been revoked by the peer node.
    %% We do it async so that we return immediately to avoid blocking the
    %% plum_db process.
    Fun = fun() ->
        case plum_db_object:value(plum_db_object:resolve(New, lww)) of
            ?TOMBSTONE ->
                %% The user was deleted
                Reason = ?BONDY_USER_DELETED,
                close_sessions(RealmUri, Username, Reason);

            NewVal ->
                OldVal = plum_db_object:value(plum_db_object:resolve(Old, lww)),
                case have_credentials_changed(NewVal, OldVal) of
                    true ->
                        %% Credentials were updated
                        Reason = ?BONDY_USER_CREDENTIALS_CHANGED,
                        close_sessions(RealmUri, Username, Reason);
                    false ->
                        ok
                end
        end
    end,

    bondy_jobs:enqueue(RealmUri, Fun).


%% -----------------------------------------------------------------------------
%% @doc A local update
%% @end
%% -----------------------------------------------------------------------------
on_update({?PLUMDB_PREFIX(RealmUri), Username}, _New, Old) ->
    IsCreate =
        Old == undefined orelse
        ?TOMBSTONE == plum_db_object:value(plum_db_object:resolve(Old, lww)),

    case IsCreate of
        true ->
            ok = bondy_event_manager:notify({user_added, RealmUri, Username});
        false ->
            %% 1. We need to revoke all auth tokens/tickets
            ok = revoke_tickets(RealmUri, Username),
            %% 2. TODO revoke all OAUTH2 Tokens
            %% 3. We need to close all sessions in this node if the user changed
            %% its credentials.
            %% However we need to keep the calling session alive if the session
            %% authid was the same user. So we cannot do it here as we do not
            %% have the session_id (this function invoked by the plum_db server
            %% process so no bondy metadata present). We do it on the update
            %% operation.
            %% 4. Finally we publish the event
            ok = bondy_event_manager:notify({user_updated, RealmUri, Username})
    end.


%% -----------------------------------------------------------------------------
%% @doc A local delete
%% @end
%% -----------------------------------------------------------------------------
on_delete({?PLUMDB_PREFIX(RealmUri), Username}, _Old) ->
    %% 1. We need to revoke all auth tokens/tickets
    ok = revoke_tickets(RealmUri, Username),
    %% 2. TODO revoke all OAUTH2 Tokens
    %% 3. Close all sessions in this node.
    ok = close_sessions(RealmUri, Username, ?BONDY_USER_DELETED),
    %% 4. Finally we publish the event
    ok = bondy_event_manager:notify({user_deleted, RealmUri, Username}).


%% -----------------------------------------------------------------------------
%% @doc A local erase
%% @end
%% -----------------------------------------------------------------------------
on_erase(_PKey, _Old) ->
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec do_add(RealmUri :: binary(), User :: t(), add_opts()) -> ok | no_return().

do_add(RealmUri, #{sso_realm_uri := SSOUri} = User0, Opts)
when is_binary(SSOUri) ->
    Username = maps:get(username, User0),

    %% Key validations first
    %% We avoid checking when we are rebasing
    Rebase = maps:get(rebase, Opts, false),
    Rebase == true orelse not_exists_check(RealmUri, Username),
    ok = groups_exists_check(RealmUri, maps:get(groups, User0, [])),

    %% We split the user into LocalUser, SSOUser and Opts
    {UserOpts, User1} = maps_utils:split([password_opts], User0),
    User2 = apply_password(User1, password_opts(RealmUri, UserOpts)),

    {SSOUser0, LocalUser} = maps_utils:split(
        [password, authorized_keys], User2
    ),

    SSOUser = type_and_version(?USER_TYPE, SSOUser0#{
        username => Username,
        groups => [],
        meta => #{}
    }),

    Flag = Rebase == true orelse not exists(SSOUri, Username),
    ok = maybe_add_sso_user(Flag, RealmUri, SSOUri, SSOUser, Opts),

    %% We finally add the local user to the realm
    store(RealmUri, LocalUser, Opts);

do_add(RealmUri, User0, Opts) ->
    %% A local-only user
    Username = maps:get(username, User0),

    %% Key validations first
    %% We avoid checking when we are rebasing
    Rebase = maps:get(rebase, Opts, false),
    Rebase == true orelse not_exists_check(RealmUri, Username),
    ok = groups_exists_check(RealmUri, maps:get(groups, User0, [])),

    %% We split the user into LocalUser, SSOUSer and Opts
    {UserOpts, User1} = maps_utils:split([sso_opts, password_opts], User0),
    User = apply_password(User1, password_opts(RealmUri, UserOpts)),

    store(RealmUri, User, Opts).


%% @private
maybe_add_sso_user(true, RealmUri, SSOUri, SSOUser, Opts) ->

    bondy_realm:is_allowed_sso_realm(RealmUri, SSOUri)
        orelse throw(invalid_sso_realm),

    ok = groups_exists_check(SSOUri, maps:get(groups, SSOUser, [])),

    %% We add the user to the SSO realm
    {ok, _} = maybe_throw(store(SSOUri, SSOUser, Opts)),
    ok;

maybe_add_sso_user(false, _, _, _, _) ->
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

            ok = maybe_on_credentials_change(RealmUri, User, SSOData),

            do_local_update(RealmUri, User, LocalData, Opts)
    end;

do_update(RealmUri, User, Data, Opts) when is_map(User) ->
    ok = maybe_on_credentials_change(RealmUri, User, Data),
    do_local_update(RealmUri, User, Data, Opts).


%% @private
%% User can't be a TOMBSTONE because is checked before calling this function
have_credentials_changed(User, Data) when is_list(User) ->
    %% Support for legacy formar
    have_credentials_changed(value_from_term(User), Data);

have_credentials_changed(User, Data) when is_list(Data) ->
    %% Support for legacy formar
    have_credentials_changed(User, value_from_term(Data));

have_credentials_changed(_, ?TOMBSTONE) ->
    %% Credentials were deleted
    true;

have_credentials_changed(User, Data) ->
    has_password_changed(User, Data)
        orelse have_authorized_keys_changed(User, Data).


%% @private
has_password_changed(User, Data) ->
    NewPassword = maps:get(password, Data, undefined),
    NewPassword =/= undefined
        andalso NewPassword =/= maps:get(password, User, undefined).


%% @private
have_authorized_keys_changed(User, Data) ->
    NewKeys = maps:get(authorized_keys, Data, undefined),
    NewKeys =/= undefined
        andalso NewKeys =/= maps:get(authorized_keys, User, undefined).


%% @private
maybe_on_credentials_change(RealmUri, User, Data) ->
    case have_credentials_changed(User, Data) of
        true ->
            on_credentials_change(RealmUri, User);
        false ->
            ok
    end.


%% @private
do_local_update(RealmUri, User, Data0, Opts0) ->
    ok = groups_exists_check(RealmUri, maps:get(groups, Data0, [])),

    %% We split the data into LocalUser and Opts
    {UserOpts, Data} = maps_utils:split([password_opts], Data0),
    Opts = maps:merge(UserOpts, Opts0),
    NewUser = merge(RealmUri, User, Data, Opts),

    store(RealmUri, NewUser, Opts0).


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


%% @private
update_credentials(RealmUri, Username, Data) ->
    Opts = #{update_credentials => true},
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
    plum_db:foreach(fun
        ({_, ?TOMBSTONE}) ->
            %% Deleted, we ignore it
            ok;
        ({_, #{type := ?ALIAS_TYPE}}) ->
            %% An alias, we ignore it
            ok;
        ({_, _} = Term) ->
            ok = update_groups(RealmUri, from_term(Term), Groupnames, Fun)
        end,
        ?PLUMDB_PREFIX(RealmUri),
        ?FOLD_OPTS
    );

update_groups(RealmUri, Users, Groupnames, Fun) when is_list(Users) ->
    _ = [
        update_groups(RealmUri, User, Groupnames, Fun) || User <- Users
    ],
    ok;

update_groups(RealmUri, #{type := ?USER_TYPE} = User, Groupnames, Fun)
when is_function(Fun, 2) ->
    Update = #{groups => Fun(maps:get(groups, User), Groupnames)},
    case update(RealmUri, User, Update) of
        {ok, _} -> ok;
        {error, Reason} -> throw(Reason)
    end;

update_groups(RealmUri, Username, Groupnames, Fun) when is_binary(Username) ->
    update_groups(RealmUri, fetch(RealmUri, Username), Groupnames, Fun).


%% @private
store(RealmUri, #{username := Username} = User, #{rebase := true} = Opts) ->
    ActorId = maps:get(actor_id, Opts, undefined),
    Object = bondy_utils:rebase_object(User, ActorId),

    case plum_db:dirty_put(?PLUMDB_PREFIX(RealmUri), Username, Object, []) of
        ok ->
            {ok, User};
        Error ->
            Error
    end;

store(RealmUri, #{username := Username} = User, _) ->
    case plum_db:put(?PLUMDB_PREFIX(RealmUri), Username, User) of
        ok ->
            {ok, User};
        Error ->
            Error
    end.


%% @private
password_opts(_, #{password_opts := Opts}) when is_map(Opts) ->
    Opts;

password_opts(RealmUri, _) ->
    case bondy_realm:password_opts(RealmUri) of
        undefined -> #{};
        Map when is_map(Map) -> Map
    end.


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
    %% We only allow updates to modify password if explicitly requested via
    %% option update_credentials.
    %% authorized_keys are always allowed to be merged
    %% as they contain public keys.
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

% %% @private
% exists_check(RealmUri, Username) ->
%     case plum_db:get(?PLUMDB_PREFIX(RealmUri), Username) of
%         undefined -> throw({no_such_user, Username});
%         _ -> ok
%     end.


%% @private
not_exists_check(RealmUri, Username) ->
    case plum_db:get(?PLUMDB_PREFIX(RealmUri), Username) of
        undefined -> ok;
        _ -> throw(already_exists)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Takes into account realm inheritance
%% @end
%% -----------------------------------------------------------------------------
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
validate_alias(Alias0) ->
    case bondy_data_validators:strict_username(Alias0) of
        {ok, Alias} ->
            Alias;
        true ->
            Alias0;
        _ ->
            throw(invalid_alias)
    end.


%% @private
do_add_alias(_, #{username := anonymous}, _) ->
    {error, not_allowed};

do_add_alias(RealmUri, User0, Alias0) ->
    try
        %% We validate the value
        Alias = validate_alias(Alias0),
        Username = maps:get(username, User0),
        AliasEntry = #{type => ?ALIAS_TYPE, username => Username},
        Aliases0 = sets:from_list(maps:get(aliases, User0, [])),

        sets:size(Aliases0) < ?MAX_ALIASES orelse throw(alias_limit),

        case sets:add_element(Alias, Aliases0) of
            Aliases0 ->
                %% The alias was already there, we store it just in case
                ok = store_alias(RealmUri, Alias, AliasEntry);
            Aliases ->
                ok = store_alias(RealmUri, Alias, AliasEntry),
                User = User0#{aliases => sets:to_list(Aliases)},
                _ = store(RealmUri, User, #{}),
                ok
        end
    catch
        throw:alias_limit ->
            {error, {property_range_limit, alias, ?MAX_ALIASES}};
        throw:invalid_alias ->
            {error, {invalid_value, alias, Alias0}};
        throw:already_exists ->
            {error, {already_exists, Alias0}}
    end.


%% @private
do_remove_alias(RealmUri, User0, Alias0) ->
    try
        Alias = validate_alias(Alias0),
        Aliases0 = sets:from_list(maps:get(aliases, User0, [])),
        case sets:del_element(Alias, Aliases0) of
            Aliases0 ->
                %% Delete anyway
                _ = plum_db:delete(?PLUMDB_PREFIX(RealmUri), Alias),
                ok;
            Aliases ->
                _ = plum_db:delete(?PLUMDB_PREFIX(RealmUri), Alias),
                User = User0#{aliases => sets:to_list(Aliases)},
                _ = store(RealmUri, User, #{}),
                ok
        end

    catch
        throw:invalid_alias ->
            {error, {invalid_value, alias, Alias0}}
    end.



%% @private
store_alias(RealmUri, Alias, AliasEntry) ->
    Modifier = fun
        (undefined) ->
            AliasEntry;
        ([?TOMBSTONE]) ->
            AliasEntry;
        ([Val]) when Val == AliasEntry ->
            AliasEntry;
        ([_]) ->
            %% This is a user whose username == Alias or an alias.
            throw(already_exists);
        ([_|_]) ->
            %% We found multiple values, we just ignore
            %% TODO what if the last one is a tombstone?
            throw(already_exists)
    end,

    case plum_db:put(?PLUMDB_PREFIX(RealmUri), Alias, Modifier) of
        ok ->
            ok;
        {error, Reason} ->
            throw(Reason)
    end.


%% @private
from_term({Username, PList}) when is_list(PList) ->
    User0 = value_from_term(PList),
    %% Prev to v1.1 we removed the username (key) from the payload (value).
    User = maps:put(username, Username, User0),
    type_and_version(?USER_TYPE, User);

from_term({_, #{type := ?USER_TYPE, version := ?VERSION} = User}) ->
    User.


value_from_term(PList) when is_list(PList) ->
    maps:from_list(
        lists:keymap(fun erlang:binary_to_existing_atom/1, 1, PList)
    ).


%% @private
type_and_version(Type, Map) ->
    Map#{
        version => ?VERSION,
        type => Type
    }.


%% @private
on_credentials_change(RealmUri, User) ->
    Username = maps:get(username, User),

    %% on_update/3 will be called by plum_db
    ok = bondy_event_manager:notify(
        {user_credentials_updated, RealmUri, Username}
    ),

    Reason = ?BONDY_USER_CREDENTIALS_CHANGED,
    Opts =
        case bondy:get_process_metadata() of
            #{session_id := SessionId} ->
                #{exclude => SessionId};
            _ ->
                #{}
        end,
    ok = close_sessions(RealmUri, Username, Reason, Opts).


%% @private
revoke_tickets(RealmUri, Username) ->
    bondy_jobs:enqueue(
        RealmUri, fun() ->
            bondy_ticket:revoke_all(RealmUri, Username)
        end
    ).


%% @private
close_sessions(RealmUri, Username, Reason) ->
    close_sessions(RealmUri, Username, Reason, #{}).


%% @private
close_sessions(RealmUri, Username, Reason, Opts) ->
    ok = bondy_session_manager:close_all(RealmUri, Username, Reason, Opts).

