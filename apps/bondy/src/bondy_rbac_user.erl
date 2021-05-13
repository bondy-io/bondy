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
%% @doc
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


-define(VALIDATOR, #{
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
        required => true,
        allow_null => false,
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
    password            =>  bondy_password:t(),
    authorized_keys     =>  [binary()],
    meta                =>  #{binary() => any()}
}.

-type external() ::  #{
    type                :=  ?TYPE,
    version             :=  binary(),
    username            :=  username(),
    groups              :=  [binary()],
    has_password        :=  boolean(),
    has_authorized_keys :=  boolean(),
    meta                =>  #{binary() => any()}
}.

-type add_error()   ::  no_such_realm | reserved_name | role_exists.
-type new_opts()    ::  #{password_opts => bondy_password:opts()}.
-type list_opts()   ::  #{limit => pos_integer()}.
-type username()    ::  binary() | anonymous.

-export_type([t/0]).
-export_type([external/0]).
-export_type([new_opts/0]).


-export([add/2]).
-export([add_or_update/2]).
-export([add_source/5]).
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
-export([password/1]).
-export([remove/2]).
-export([remove_group/2]).
-export([remove_source/3]).
-export([to_external/1]).
-export([unknown/2]).
-export([update/3]).
-export([username/1]).
-export([normalise_username/1]).


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

    case maps:find(password, User) of
        {ok, Value} ->
            PWD = bondy_password:new(Value, Opts),
            maps:put(password, PWD, User);
        error ->
            User
    end.



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
-spec password(User :: t()) -> bondy_password:t() | undefined.

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
%% @doc Adds a new user to the RBAC store.
%% This record is globally replicated.
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), t()) -> ok | {error, add_error()}.

add(RealmUri, #{type := ?TYPE} = User) ->
    try
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

add_or_update(RealmUri, #{type := ?TYPE, username := Username} = User) ->
    try
        do_add(RealmUri, User)
    catch
        throw:role_exists ->
            update(RealmUri, Username, User);

        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(RealmUri :: uri(), Username :: binary(), Data :: map()) ->
    {ok, NewUser :: t()} | {error, any()}.

update(RealmUri, Username, Data0) when is_binary(Username) ->
    try

        Data = maps_utils:validate(Data0, ?UPDATE_VALIDATOR),

        Prefix = ?PLUMDB_PREFIX(RealmUri),

        ok = not_reserved_name_check(Username),

        case plum_db:get(Prefix, Username) of
            undefined ->
                throw(unknown_user);
            Value ->
                NewUser = maps:merge(from_term({Username, Value}), Data),
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

remove(RealmUri, Username) ->
    try
        Prefix = ?PLUMDB_PREFIX(RealmUri),

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
    Username = normalise_username(Username0),
    Prefix = ?PLUMDB_PREFIX(RealmUri),

    case Username == anonymous of
        true ->
            ?ANONYMOUS;
        false ->
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
change_password(RealmUri, Username, New, Old) ->
    case lookup(RealmUri, Username) of
        {error, not_found} = Error ->
            Error;
        #{password := PW} ->
            case bondy_password:check_password(Old, PW) of
                true ->
                    change_password(RealmUri, Username, New);
                false ->
                    {error, bad_password}
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add_source(
    RealmUri :: uri(),
    Username :: username(),
    CIDR :: bondy_rbac_source:cidr(),
    Source :: atom(),
    Options :: list()) -> ok.

add_source(RealmUri, Username, CIDR, Source, Opts) ->
    bondy_rbac_source:add(RealmUri, [Username], CIDR, Source, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_source(
    RealmUri :: uri(),
    Usernames :: [binary()] | all,
    CIDR :: bondy_rbac_source:cidr()) -> ok.

remove_source(RealmUri, Username, CIDR) ->
    bondy_rbac_source:remove(RealmUri, [Username], CIDR).


%% -----------------------------------------------------------------------------
%% @doc Returns the external representation of the user `User'.
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(User :: t()) -> external().

to_external(#{type := ?TYPE, version := ?VERSION} = User) ->
    %% We leave the authorized keys as they are public keys
    Map = maps:without([password], User),

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
            (Username, Acc) when is_binary(Username) ->
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
    Term;

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

do_add(RealmUri, #{type := ?TYPE, username := Username} = User) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),

    %% This should have been validated before but just to avoid any issues
    %% we do it again.
    ok = not_reserved_name_check(Username),
    ok = not_exists_check(Prefix, Username),
    ok = no_unknown_groups(RealmUri, maps:get(groups, User)),

    case plum_db:put(Prefix, Username, User) of
        ok ->
            ok = on_create(RealmUri, Username),
            {ok, User};
        Error ->
            Error
    end.


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
        {security_user_added, RealmUri, Username}
    ),
    ok.


%% @private
on_update(RealmUri, Username) ->
    ok = bondy_event_manager:notify(
        {security_user_updated, RealmUri, Username}
    ),
    ok.


%% @private
on_password_change(RealmUri, Username) ->
    ok = bondy_event_manager:notify(
        {security_password_changed, RealmUri, Username}
    ),
    on_update(RealmUri, Username).


%% @private
on_delete(RealmUri, Username) ->
    ok = bondy_event_manager:notify(
        {security_user_deleted, RealmUri, Username}
    ),
    ok.


