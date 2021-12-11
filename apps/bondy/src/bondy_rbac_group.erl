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
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_plum_db.hrl").



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
        validator => fun bondy_data_validators:groupnames/1
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

-define(TYPE, group).
-define(VERSION, <<"1.1">>).
-define(PLUMDB_PREFIX(RealmUri), {?PLUM_DB_GROUP_TAB, RealmUri}).
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
-type add_error()       ::  no_such_realm | reserved_name | already_exists.
-type list_opts()       ::  #{limit => pos_integer()}.

-export_type([t/0]).
-export_type([external/0]).


-export([add/2]).
-export([add_group/3]).
-export([add_groups/3]).
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
-export([normalise_name/1]).
-export([remove/2]).
-export([remove_group/3]).
-export([remove_groups/3]).
-export([to_external/1]).
-export([topsort/1]).
-export([unknown/2]).
-export([update/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Data :: map()) -> Group :: t().

new(Data) ->
    type_and_version(maps_utils:validate(Data, ?VALIDATOR)).



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

is_member(Name0, #{type := ?TYPE, groups := Val}) ->
    Name = normalise_name(Name0),
    Name == all orelse lists:member(Name, Val).


%% -----------------------------------------------------------------------------
%% @doc Returns the metadata map associated with the group `Group'.
%% @end
%% -----------------------------------------------------------------------------
-spec meta(Group :: t()) -> map().

meta(#{type := ?TYPE, meta := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), t()) -> {ok, t()} | {error, any()}.

add(RealmUri, #{type := ?TYPE} = Group) ->
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

add_or_update(RealmUri, #{type := ?TYPE, name := Name} = Group) ->
    try
        do_add(RealmUri, Group)
    catch
        throw:already_exists ->
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
     %% TODO validate that we are not updating a prototype group, if so raise a
     %% {operation_not_allowed}
    try
        Data = maps_utils:validate(Data0, ?UPDATE_VALIDATOR),

        Prefix = ?PLUMDB_PREFIX(RealmUri),

        ok = not_reserved_name_check(Name),

        case plum_db:get(Prefix, Name) of
            undefined ->
                throw(unknown_group);
            Group ->
                NewGroup = maps:merge(from_term({Name, Group}), Data),

                %% Throws an exception if any group does not exist in RealmUri
                %% or in its prototype
                ok = group_exists_check(RealmUri, maps:get(groups, NewGroup)),

                ok = plum_db:put(Prefix, Name, NewGroup),
                ok = on_update(RealmUri, Name),
                {ok, NewGroup}
        end

    catch
        throw:Reason ->
            {error, Reason}
    end.



%% -----------------------------------------------------------------------------
%% @doc Adds group named `Groupname' to gropus `Groups' in realm with uri
%% `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec add_group(
    RealmUri :: uri(),
    Groups :: all | t() | list(t()) | name() | list(name()),
    Groupname :: name()) -> ok.

add_group(RealmUri, Groups, Groupname) ->
    add_groups(RealmUri, Groups, [Groupname]).


%% -----------------------------------------------------------------------------
%% @doc Adds groups `Groupnames' to gropus `Groups' in realm with uri
%% `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec add_groups(
    RealmUri :: uri(),
    Groups :: all | t() | list(t()) | name() | list(name()),
    Groupnames :: [name()]) -> ok.

add_groups(RealmUri, Groups, Groupnames)  ->
    Fun = fun(Current, ToAdd) ->
         sets:to_list(
            sets:union(
                sets:from_list(Current),
                sets:from_list(ToAdd)
            )
        )
    end,
    update_groups(RealmUri, Groups, Groupnames, Fun).


%% -----------------------------------------------------------------------------
%% @doc Removes groups `Groupnames' from gropus `Groups' in realm with uri
%% `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_group(
    RealmUri :: uri(),
    Groups :: all | t() | list(t()) | name() | list(name()),
    Groupname :: name()) -> ok.

remove_group(RealmUri, Groups, Groupname) ->
    remove_groups(RealmUri, Groups, [Groupname]).


%% -----------------------------------------------------------------------------
%% @doc Removes groups `Groupnames' from gropus `Groups' in realm with uri
%% `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_groups(
    RealmUri :: uri(),
    Groups :: all | t() | list(t()) | name() | list(name()),
    Groupnames :: [name()]) -> ok.

remove_groups(RealmUri, Groups, Groupnames) ->
    Fun = fun(Current, ToRemove) ->
        Current -- ToRemove
    end,
    update_groups(RealmUri, Groups, Groupnames, Fun).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), binary() | map()) ->
    ok | {error, unknown_group | reserved_name}.

remove(RealmUri, #{type := ?TYPE, name := Name}) ->
    remove(RealmUri, Name);

remove(RealmUri, Name) ->
    try
        ok = not_reserved_name_check(Name),
        ok = exists_check(?PLUMDB_PREFIX(RealmUri), Name),

        %% delete any associated grants, so if a group with the same name
        %% is added again, they don't pick up these grants
        ok = bondy_rbac:revoke_group(RealmUri, Name),

        %% Delete the group out of any user or group's `groups` property.
        %% This is very slow as we have to iterate over all the roles (users and
        %% groups) removing and updating the record in the db.
        %% By doing this we will be automatically upgradings those object
        %% versions.
        ok = bondy_rbac_user:remove_group(RealmUri, all, Name),
        ok = remove_groups(RealmUri, all, Name),

        %% We finally delete the group
        ok = plum_db:delete(?PLUMDB_PREFIX(RealmUri), Name),

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
    %% TODO We SHOULD list the realm's prototype roups as well (amd potentially
    %% marking them with a flag)
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

to_external(#{type := ?TYPE, version := ?VERSION} = Group) ->
    Group.


%% -----------------------------------------------------------------------------
%% @doc Takes a list of groupnames and returns any that can't be found on the
%% realm identified by `RealmUri' or in its prototype (if set).
%% @end
%% -----------------------------------------------------------------------------
-spec unknown(RealmUri :: uri(), Names :: [binary()]) ->
    Unknown :: [binary()].

unknown(_, []) ->
    [];

unknown(RealmUri, Names) ->
    case do_unknown(RealmUri, Names) of
        [] ->
            [];
        Unknown ->
            case bondy_realm:prototype_uri(RealmUri) of
                undefined ->
                    Unknown;
                ProtoUri ->
                    %% Inheritance is only one level so we avoid recursion
                    do_unknown(ProtoUri, Unknown)
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc Creates a directed graph of the groups `Groups' by traversing the group
%% membership relationship and computes the topological ordering of the
%% groups if such ordering exists.  Otherwise returns `Groups' unmodified.
%% Fails with `{cycle, Path :: [name()]}' exception if the graph directed graph
%% has cycles of length two or more.
%%
%% This function doesn't fetch the definition of the groups in each group
%% `groups' property.
%% @end
%% -----------------------------------------------------------------------------
-spec topsort([t()]) -> [t()].

topsort(L) when length(L) =< 1 ->
    L;

topsort(Groups) ->
    Graph = digraph:new([acyclic]),

    try
        _ = precedence_graph(Groups, Graph),

        case digraph_utils:topsort(Graph) of
            false ->
                Groups;
            Vertices ->
                lists:reverse(
                    lists:foldl(
                        fun(V, Acc) ->
                            case digraph:vertex(Graph, V) of
                                {_, []} -> Acc;
                                {_, #{type := ?TYPE} = G} -> [G|Acc]
                            end
                        end,
                        [],
                        Vertices
                    )
                )
        end

    catch
        throw:{cycle, _} = Reason ->
            error(Reason)
    after
        digraph:delete(Graph)
    end.



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
do_add(RealmUri, #{type := ?TYPE, name := Name} = Group) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),

    %% This should have been validated before but just to avoid any issues
    %% we do it again.
    ok = not_reserved_name_check(Name),
    ok = not_exists_check(Prefix, Name),
    ok = group_exists_check(RealmUri, maps:get(groups, Group)),

    case plum_db:put(Prefix, Name, Group) of
        ok ->
            ok = on_create(RealmUri, Name),
            {ok, Group};
        Error ->
            Error
    end.



%% -----------------------------------------------------------------------------
%% @private
%% @doc Doesn't take into account realm inheritance.
%% @end
%% -----------------------------------------------------------------------------
exists_check(Prefix, Name) ->
    case plum_db:get(Prefix, Name) of
        undefined -> throw(unknown_group);
        _ -> ok
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Doesn't take into account realm inheritance
%% @end
%% -----------------------------------------------------------------------------
not_exists_check(Prefix, Name) ->
    case plum_db:get(Prefix, Name) of
        undefined -> ok;
        _ -> throw(already_exists)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Takes into account realm inheritance
%% @end
%% -----------------------------------------------------------------------------
group_exists_check(RealmUri, Groups) ->
    %% Takes into account realm inheritance as it uses unknown
    case unknown(RealmUri, Groups) of
        [] ->
            ok;
        Unknown ->
            throw({no_such_groups, Unknown})
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Takes into account realm inheritance
%% @end
%% -----------------------------------------------------------------------------
do_unknown(RealmUri, Names) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),
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
        ordsets:from_list(Names)
    ).


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

from_term({_, #{type := ?TYPE, version := ?VERSION} = Group}) ->
    Group.


%% @private
type_and_version(Group) ->
    Group#{
        version => ?VERSION,
        type => group
    }.


%% @private
-spec update_groups(
    RealmUri :: uri(),
    Groups :: all | t() | list(t()) | name() | list(name()),
    Groupnames :: [name()],
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

update_groups(RealmUri, Groups, Groupnames, Fun) when is_list(Groups) ->
    _ = [
        update_groups(RealmUri, User, Groupnames, Fun) || User <- Groups
    ],
    ok;

update_groups(RealmUri, #{type := ?TYPE} = Group, Groupnames, Fun)
when is_function(2, Fun) ->
    Update = #{groups => Fun(maps:get(groups, Group), Groupnames)},
    case update(RealmUri, Group, Update) of
        {ok, _} -> ok;
        {error, Reason} -> throw(Reason)
    end;

update_groups(RealmUri, GroupName, Groupnames, Fun) when is_binary(GroupName) ->
    update_groups(RealmUri, fetch(RealmUri, GroupName), Groupnames, Fun).


%% @private
on_create(RealmUri, Name) ->
    ok = bondy_event_manager:notify(
        {group_added, RealmUri, Name}
    ),
    ok.


%% @private
on_update(RealmUri, Name) ->
    ok = bondy_event_manager:notify(
        {group_updated, RealmUri, Name}
    ),
    ok.


%% @private
on_delete(RealmUri, Name) ->
    ok = bondy_event_manager:notify(
        {group_deleted, RealmUri, Name}
    ),
    ok.



%% =============================================================================
%% PRIVATE: TOPSORT
%% =============================================================================


precedence_graph(Groups, Graph) ->
    _ = [
        digraph:add_vertex(Graph, N) || #{groups := Names} <- Groups, N <- Names
    ],
    precedence_graph_aux(Groups, Graph).


precedence_graph_aux(
    [#{type := ?TYPE, name := A, groups := Names} = H|T], Graph) ->
    _ = digraph:add_vertex(Graph, A, H),
    _ = [
        begin
            case digraph:add_edge(Graph, B, A) of
                {error, {bad_edge, Path}} ->
                    throw({cycle, Path});
                {error, Reason} ->
                    %% This should never occur
                    error(Reason);
                _Edge ->
                    ok
            end
        end
        || B <- Names
    ],
    precedence_graph_aux(T, Graph);

precedence_graph_aux([#{type := ?TYPE}|T], Graph) ->
    precedence_graph_aux(T, Graph);

precedence_graph_aux([], Graph) ->
    Graph.
