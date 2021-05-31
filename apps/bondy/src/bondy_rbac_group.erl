%% =============================================================================
%%  bondy_rbac_group.erl -
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
-module(bondy_rbac_group).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").


-define(VALIDATOR, ?UPDATE_VALIDATOR#{
    <<"name">> => #{
        alias => name,
		key => name,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary,
        validator => fun bondy_data_validators:strict_groupname/1
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
    <<"groups">> => #{
        alias => groups,
		key => groups,
        allow_null => false,
        allow_undefined => false,
        required => false,
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
    name => anonymous,
    groups => [],
    meta => #{}
})).


-define(VERSION, <<"1.1">>).
-define(PLUMDB_PREFIX(RealmUri), {security_groups, RealmUri}).
-define(FOLD_OPTS, [{resolver, lww}]).





-type t()       ::  #{
    type                :=  group,
    version             :=  binary(),
    name                :=  binary() | anonymous,
    groups              :=  [binary()],
    meta                =>  #{binary() => any()}
}.

-type external()        ::  t().
-type name()            ::  binary() | anonymous | all.
-type add_error()       ::  no_such_realm | reserved_name | role_exists.
-type list_opts()       ::  #{limit => pos_integer()}.

-export_type([t/0]).
-export_type([external/0]).

-export([add/2]).
-export([add_or_update/2]).
-export([exists/2]).
-export([fetch/2]).
-export([groups/1]).
-export([is_member/2]).
-export([list/1]).
-export([list/2]).
-export([lookup/2]).
-export([meta/1]).
-export([name/1]).
-export([new/1]).
-export([remove/2]).
-export([to_external/1]).
-export([unknown/2]).
-export([update/3]).
-export([normalise_name/1]).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Data :: map()) -> Group :: t().

new(Data) ->
    Group = maps_utils:validate(Data, ?VALIDATOR),
    type_and_version(Group).



%% -----------------------------------------------------------------------------
%% @doc Returns the group names the user's username.
%% @end
%% -----------------------------------------------------------------------------
-spec name(t()) -> name().

name(#{name := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the group names the user `User' is member of.
%% @end
%% -----------------------------------------------------------------------------
-spec groups(t()) -> [name()].

groups(#{groups := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if group `Group' is a member of the group named
%% `Name'. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_member(Name :: name(), Group :: t()) -> boolean().

is_member(Name0, #{type := group, groups := Val}) ->
    Name = normalise_name(Name0),
    Name == all orelse lists:member(Name, Val).


%% -----------------------------------------------------------------------------
%% @doc Returns the metadata map associated with the group `Group'.
%% @end
%% -----------------------------------------------------------------------------
-spec meta(Group :: t()) -> map().

meta(#{type := group, meta := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), t()) -> {ok, t()} | {error, any()}.

add(RealmUri, #{type := group} = Group) ->
    try
        do_add(RealmUri, Group)
    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc Adds a new user or updates an existing one.
%% This change is globally replicated.
%% @end
%% -----------------------------------------------------------------------------
-spec add_or_update(RealmUri :: uri(), Gropu :: t()) ->
    {ok, t()} | {error, add_error()}.

add_or_update(RealmUri, #{type := group, name := Name} = Group) ->
    try
        do_add(RealmUri, Group)
    catch
        throw:role_exists ->
            update(RealmUri, Name, Group);

        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Name cannot be a reserved name. See {@link bondy_rbac:is_reserved_name/1}.
%% @end
%% -----------------------------------------------------------------------------
-spec update(RealmUri :: uri(), Name :: binary(), Data :: map()) ->
    {ok, NewUser :: t()} | {error, any()}.

update(RealmUri, Name, Data0) when is_binary(Name) ->
    try
        Data = maps_utils:validate(Data0, ?UPDATE_VALIDATOR),

        Prefix = ?PLUMDB_PREFIX(RealmUri),

        ok = not_reserved_name_check(Name),

        case plum_db:get(Prefix, Name) of
            undefined ->
                throw(unknown_group);
            Group ->
                NewGroup = maps:merge(from_term({Name, Group}), Data),
                ok = no_unknown_groups(RealmUri, maps:get(groups, NewGroup)),

                ok = plum_db:put(Prefix, Name, NewGroup),
                ok = on_update(RealmUri, Name),
                {ok, NewGroup}
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
    ok | {error, unknown_group | reserved_name}.

remove(RealmUri, #{type := group, name := Name}) ->
    remove(RealmUri, Name);

remove(RealmUri, Name) ->
    try
        Prefix = ?PLUMDB_PREFIX(RealmUri),

        ok = not_reserved_name_check(Name),
        ok = exists_check(Prefix, Name),

        %% delete any associated grants, so if a group with the same name
        %% is added again, they don't pick up these grants
        ok = bondy_rbac_policy:revoke_group(RealmUri, Name),

        %% Delete the group out of any user or group's `groups` property.
        %% This is very slow as we have to iterate over all the roles (users and
        %% groups) removing and updating the record in the db.
        %% By doing this we will be automatically upgradings those object
        %% versions.
        ok = bondy_rbac_user:remove_group(RealmUri, Name),
        ok = remove_group(Prefix, Name),

        %% We finally delete the group
        ok = plum_db:delete(Prefix, Name),

        on_delete(RealmUri, Name)

    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri(), list() | binary()) -> t() | {error, not_found}.

lookup(RealmUri, Name0) ->
    Name = normalise_name(Name0),
    Prefix = ?PLUMDB_PREFIX(RealmUri),

    case Name == anonymous of
        true ->
            ?ANONYMOUS;
        false ->
            case plum_db:get(Prefix, Name) of
                undefined ->
                    {error, not_found};
                Value ->
                    from_term({Name, Value})
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(uri(), list() | binary()) -> t() | no_return().

fetch(RealmUri, Name) ->
    case lookup(RealmUri, Name) of
        {error, not_found} -> error(not_found);
        Group -> Group
    end.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec exists(uri(), list() | binary()) -> boolean().

exists(RealmUri, Name) ->
    case lookup(RealmUri, Name) of
        {error, not_found} -> false;
        _ -> true
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
        [?ANONYMOUS],
        Prefix,
        FoldOpts
    ).


%% -----------------------------------------------------------------------------
%% @doc Returns the external representation of the user `User'.
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(Group :: t()) -> external().

to_external(#{type := group, version := ?VERSION} = Group) ->
    Group.


%% -----------------------------------------------------------------------------
%% @doc Takes a list of groupnames and returns any that can't be found.
%% @end
%% -----------------------------------------------------------------------------
-spec unknown(RealmUri :: uri(), Names :: [binary()]) ->
    Unknown :: [binary()].

unknown(_, []) ->
    [];

unknown(RealmUri, Names) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),
    Set = ordsets:from_list(Names),
    ordsets:fold(
        fun
            (all, Acc) ->
                Acc;
            (anonymous, Acc) ->
                Acc;
            (Name, Acc) ->
                case plum_db:get(Prefix, Name) of
                    undefined -> [Name | Acc];
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
-spec normalise_name(Term :: name()) -> name() | no_return().

normalise_name(all) ->
    all;

normalise_name(anonymous) ->
    anonymous;

normalise_name(<<"all">>) ->
    all;

normalise_name(<<"anonymous">>) ->
    anonymous;

normalise_name(Term) when is_binary(Term) ->
    Term;

normalise_name(_) ->
    error(badarg).


%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_add(RealmUri, #{type := group, name := Name} = Group) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),

    %% This should have been validated before but just to avoid any issues
    %% we do it again.
    ok = not_reserved_name_check(Name),
    ok = not_exists_check(Prefix, Name),
    ok = no_unknown_groups(RealmUri, maps:get(groups, Group)),

    case plum_db:put(Prefix, Name, Group) of
        ok ->
            ok = on_create(RealmUri, Name),
            {ok, Group};
        Error ->
            Error
    end.



%% @private
exists_check(Prefix, Name) ->
    case plum_db:get(Prefix, Name) of
        undefined -> throw(unknown_group);
        _ -> ok
    end.


%% @private
not_exists_check(Prefix, Name) ->
    case plum_db:get(Prefix, Name) of
        undefined -> ok;
        _ -> throw(role_exists)
    end.


%% @private
no_unknown_groups(RealmUri, Groups) ->
    case unknown(RealmUri, Groups) of
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
from_term({Name, PList}) when is_list(PList) ->
    Group0 = maps:from_list(
        lists:keymap(fun erlang:binary_to_existing_atom/1, 1, PList)
    ),
    %% Prev to v1.1 we removed the name (key) from the payload (value).
    Group = maps:put(name, Name, Group0),
    type_and_version(Group);

from_term({_, #{type := group, version := ?VERSION} = Group}) ->
    Group.



%% @private
type_and_version(Group) ->
    Group#{
        version => ?VERSION,
        type => group
    }.


%% @private
remove_group(Prefix, Name) ->
    plum_db:fold(fun
        ({_, [?TOMBSTONE]}, Acc) ->
            Acc;
        ({_, _} = Term, Acc) ->
            ok = remove_group(Name, from_term(Term), Prefix),
            Acc
        end,
        ok,
        Prefix,
        ?FOLD_OPTS
    ).


%% @private
remove_group(Name, #{name := Key} = Group, Prefix) ->
    case is_member(Name, Group) of
        true ->
            NewGroups = maps:get(groups, Group) -- [Name],
            NewGroup = maps:put(groups, NewGroups, Group),
            ok = plum_db:put(Prefix, Key, NewGroup),
            ok;
        false ->
            ok
    end.


%% @private
on_create(RealmUri, Name) ->
    ok = bondy_event_manager:notify(
        {rbac_group_added, RealmUri, Name}
    ),
    ok.


%% @private
on_update(RealmUri, Name) ->
    ok = bondy_event_manager:notify(
        {rbac_group_updated, RealmUri, Name}
    ),
    ok.


%% @private
on_delete(RealmUri, Name) ->
    ok = bondy_event_manager:notify(
        {rbac_group_deleted, RealmUri, Name}
    ),
    ok.




