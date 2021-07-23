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


-define(VALIDATOR, ?ADD_OPTS_VALIDATOR#{
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

-define(ADD_OPTS_VALIDATOR, #{
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

-define(UPDATE_VALIDATOR, #{
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
-type sso_opts()        ::  #{
    realm_uri           =>  uri(),
    password            =>  bondy_password:future() | bondy_password:t(),
    authorized_keys     =>  [binary()],
    groups              =>  [binary()],
    meta                =>  #{binary() => any()}
}.
-type add_error()       ::  no_such_realm | reserved_name | role_exists.

-type list_opts()       ::  #{
    limit => pos_integer()
}.


-export_type([t/0]).
-export_type([external/0]).
-export_type([new_opts/0]).
-export_type([sso_opts/0]).
-export_type([add_opts/0]).


-export([add/2]).
-export([add_or_update/2]).
-export([authorized_keys/1]).
-export([change_password/3]).
-export([change_password/4]).
-export([fetch/2]).
-export([groups/1]).
-export([has_authorized_keys/1]).
-export([has_password/1]).
-export([is_member/2]).
-export([list/1]).
-export([list/2]).
-export([lookup/2]).
-export([meta/1]).
-export([new/1]).
-export([new/2]).
-export([password/1]).
-export([remove/2]).
-export([remove_group/2]).
-export([to_external/1]).
-export([unknown/2]).
-export([update/3]).
-export([username/1]).
-export([normalise_username/1]).
-export([sso_realm_uri/1]).


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
%% @doc Returns `true' if user `User' has a password. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec has_password(User :: t()) -> boolean().

has_password(User) ->
    maps:is_key(password, User).


%% -----------------------------------------------------------------------------
%% @doc Returns the password object or `undefined' if the user does not have a
%% password. See {@link bondy_password}.
%% @end
%% -----------------------------------------------------------------------------
-spec password(User :: t()) ->
    bondy_password:future() | bondy_password:t() |  undefined.

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
        {ok, _} = OK = do_add(RealmUri, User),
        ok = on_create(RealmUri, Username),
        OK
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

add_or_update(RealmUri, #{type := ?TYPE, username := Username} = User) ->
    try
        add(RealmUri, User)
    catch
        throw:role_exists ->
            update(RealmUri, Username, User);

        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc Updates an existing user.
%% This change is globally replicated.
%% @end
%% -----------------------------------------------------------------------------
-spec update(RealmUri :: uri(), Username :: binary(), Data :: map()) ->
    {ok, NewUser :: t()} | {error, any()}.

update(RealmUri, Username0, Data0) when is_binary(Username0) ->
    try

        Data = maps_utils:validate(Data0, ?UPDATE_VALIDATOR),
        Prefix = ?PLUMDB_PREFIX(RealmUri),
        Username = normalise_username(Username0),
        ok = not_reserved_name_check(Username),

        case plum_db:get(Prefix, Username) of
            undefined ->
                throw(unknown_user);
            Value ->
                User = from_term({Username, Value}),
                %% If we have a password string in Data we convert it to a
                %% bondy_password:t()
                NewUser = merge(RealmUri, User, Data),
                ok = no_unknown_groups(RealmUri, maps:get(groups, NewUser)),
                ok = plum_db:put(Prefix, Username, NewUser),
                ok = on_update(RealmUri, Username),
                {ok, NewUser}
        end

    catch
        throw:Reason ->
            {error, Reason}
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), binary() | map()) ->
    ok | {error, unknown_user | reserved_name}.

remove(RealmUri, #{type := ?TYPE, username := Username}) ->
    remove(RealmUri, Username);

remove(RealmUri, Username0) ->
    try
        Prefix = ?PLUMDB_PREFIX(RealmUri),
        Username = normalise_username(Username0),

        ok = not_reserved_name_check(Username),
        ok = exists_check(Prefix, Username),

        %% We remove this user from sources
        ok = bondy_rbac_source:remove_all(RealmUri, Username),

        %% delete any associated grants, so if a user with the same name
        %% is added again, they don't pick up these grants
        ok = bondy_rbac_policy:revoke_user(RealmUri, Username),

        %% We finally delete the user
        ok = plum_db:delete(Prefix, Username),

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
-spec fetch(uri(), binary()) -> t() | no_return().

fetch(RealmUri, Username) ->
    case lookup(RealmUri, Username) of
        {error, _} = Error -> Error;
        User -> User
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
    case update(RealmUri, Username, #{password => New}) of
        {ok, _} ->
            on_password_change(RealmUri, Username);
        Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
change_password(_, _, Old, Old) ->
    ok;

change_password(RealmUri, Username, New, Old) ->
    case lookup(RealmUri, Username) of
        {error, not_found} = Error ->
            Error;
        #{password := PW} ->
            case bondy_password:verify_string(Old, PW) of
                true ->
                    change_password(RealmUri, Username, New);
                false ->
                    {error, bad_signature}
            end
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
%% @doc Removes group named `Groupname' from all users in realm with uri
%% `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_group(
    RealmUri :: uri(), Groupname :: bondy_rbac_group:name()) -> ok.

remove_group(RealmUri, Groupname) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),
    plum_db:fold(fun
        ({_, [?TOMBSTONE]}, Acc) ->
            Acc;
        ({_, _} = Term, Acc) ->
            ok = remove_group(Groupname, from_term(Term), Prefix),
            Acc
        end,
        ok,
        Prefix,
        ?FOLD_OPTS
    ).


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



%% @private
password_opts(RealmUri) ->
    password_opts(RealmUri, #{}).


%% @private
password_opts(_, #{password_opts := Opts}) when is_map(Opts) ->
    Opts;

password_opts(RealmUri, _) ->
    bondy_realm:password_opts(RealmUri).


%% @private
merge(RealmUri, U1, U2) ->
    User = maps:merge(U1, U2),
    P0 = maps:get(password, U1, undefined),
    Future = maps:get(password, U2, undefined),

    case {P0, Future} of
        {undefined, undefined} ->
            User;

        {undefined, _}  ->
            apply_password(User, password_opts(RealmUri));

        {P0, undefined} ->
            bondy_password:is_type(P0) orelse error(badarg),
            User;

        {P0, Future} when is_function(Future, 1) ->
            apply_password(User, password_opts(RealmUri));

        {_, P1} ->
            bondy_password:is_type(P1) orelse error(badarg),
            maps:put(password, P1, User)

    end.


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
    ok = not_exists_check(?PLUMDB_PREFIX(RealmUri), Username),
    ok = not_exists_check(?PLUMDB_PREFIX(SSOUri), Username),
    ok = no_unknown_groups(RealmUri, maps:get(groups, User0)),
    ok = no_unknown_groups(SSOUri, maps:get(groups, SSOOpts)),
    bondy_realm:is_allowed_sso_realm(RealmUri, SSOUri)
        orelse throw(invalid_sso_realm),

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
        groups => maps:get(groups, SSOOpts),
        meta => maps:get(meta, SSOOpts)
    }),

    %% We first add the user to the SSO realm
    {ok, _} = maybe_throw(create(SSOUri, SSOUser)),

    %% We finally add the local user to the realm
    create(RealmUri, LocalUser);

do_add(RealmUri, User0) ->
    Username = maps:get(username, User0),

    %% Key validations first
    ok = not_exists_check(?PLUMDB_PREFIX(RealmUri), Username),
    ok = no_unknown_groups(RealmUri, maps:get(groups, User0)),

    %% We split the user into LocalUser, SSOUSer and Opts
    {Opts, User1} = maps_utils:split([sso_opts, password_opts], User0),
    User = apply_password(User1, password_opts(RealmUri, Opts)),

    create(RealmUri, User).


%% @private
create(RealmUri, #{username := Username} = User) ->
    case plum_db:put(?PLUMDB_PREFIX(RealmUri), Username, User) of
        ok ->
            ok = on_create(RealmUri, Username),
            {ok, User};
        Error ->
            Error
    end.



%% @private
maybe_throw({error, Reason}) ->
    throw(Reason);

maybe_throw(Term) ->
    Term.

%% @private
exists_check(Prefix, Username) ->
    case plum_db:get(Prefix, Username) of
        undefined -> throw(unknown_user);
        _ -> ok
    end.


%% @private
not_exists_check(Prefix, Username) ->
    case plum_db:get(Prefix, Username) of
        undefined -> ok;
        _ -> throw(role_exists)
    end.

%% @private
no_unknown_groups(RealmUri, Groups) ->
    case bondy_rbac_group:unknown(RealmUri, Groups) of
        [] ->
            ok;
        Unknown ->
            throw({unknown_groups, Unknown})
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
remove_group(Groupname, #{username := Key} = User, Prefix) ->
    case is_member(Groupname, User) of
        true ->
            NewGroups = maps:get(groups, User) -- [Groupname],
            NewUser = maps:put(groups, NewGroups, User),
            ok = plum_db:put(Prefix, Key, NewUser),
            ok;
        false ->
            ok
    end.


%% @private
on_create(RealmUri, Username) ->
    ok = bondy_event_manager:notify(
        {rbac_user_added, RealmUri, Username}
    ),
    ok.


%% @private
on_update(RealmUri, Username) ->
    ok = bondy_event_manager:notify(
        {rbac_user_updated, RealmUri, Username}
    ),
    ok.


%% @private
on_password_change(RealmUri, Username) ->
    ok = bondy_event_manager:notify(
        {rbac_user_password_changed, RealmUri, Username}
    ),
    on_update(RealmUri, Username).


%% @private
on_delete(RealmUri, Username) ->
    ok = bondy_event_manager:notify(
        {rbac_user_deleted, RealmUri, Username}
    ),
    ok.


