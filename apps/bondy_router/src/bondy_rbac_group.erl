%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rbac_group).
-moduledoc """
Groups: the named roles a realm grants permissions to, and the inheritance
edges between them.

A group is a role. Permissions are granted to it rather than to each user, and a
group may name parent groups in its `groups` property, so a user's effective
permissions are the transitive closure over that graph. The graph must stay
acyclic — `topsort/1` is what establishes that — because `bondy_rbac` resolves
it eagerly when building an authorization context.

**A group does not know its members.** Membership is a relation of its own,
`security_group_members`, read and written through `bondy_rbac_user`; this
module owns the group's identity and its parent edges. `members/3` reads that
relation, and the group's own cell says nothing about who belongs to it.

Every realm has a synthetic `anonymous` group that is never stored. It heads
every listing and is returned by `lookup/2` without a read.

Start from `new/1` and `add/3` to define a group, `add_group/3` to add a parent
edge, and `members/3` to page through its members.

## Names are case-sensitive

Group names are stored casefolded and nothing here folds them for you. Pass
inputs through `normalise_name/1`, or a group written under one spelling will
not be found under another.

## Storage

Each group is one cell in the durable `security_groups` table, banded by realm
and keyed by name. Changing a group's parents changes what its members may do
without touching any grant, so both the local write path and the merge of a
peer's write invalidate this node's cached authorization contexts for the realm.
""".
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").

-define(VALIDATOR, #{
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

-define(ANONYMOUS,
    type_and_version(#{
        name => anonymous,
        groups => [],
        meta => #{}
    })
).

-define(TYPE, group).
-define(VERSION, <<"1.1">>).

-type t() :: #{
    type := group,
    version := binary(),
    name := binary() | anonymous,
    groups := [binary()],
    meta => #{binary() => any()}
}.

-type external() :: t().
-type name() :: binary() | anonymous | all.
-type add_opts() :: #{
    %% `true` when applying declarative config (idempotent write, no lifecycle
    %% event) — see `bondy_realm:apply_config/0`.
    declarative => boolean(),
    actor_id => term(),
    if_exists => fail | update
}.
-type add_error() ::
    {no_such_realm, uri()}
    | reserved_name
    | already_exists.
-type list_opts() :: #{limit => pos_integer()}.
%% Note: the group list contract returns a bare list (the anonymous group always
%% heads it), so Limit truncates rather than yielding a resumable cursor.

-export_type([t/0]).
-export_type([external/0]).
-export_type([name/0]).

%% API
-export([add/2]).
-export([add/3]).
-export([add_group/3]).
%% Exported for the legacy-backup import translator (bondy_export): upgrades a
%% pre-v1.1 proplist group value (or passes a current map through).
-export([from_term/1]).
-export([add_groups/3]).
-export([exists/2]).
-export([fetch/2]).
-export([groups/1]).
-export([is_member/2]).
-export([list/1]).
-export([list/2]).
-export([lookup/2]).
-export([members/3]).
-export([meta/1]).
-export([name/1]).
-export([new/1]).
-export([normalise_name/1]).
-export([remove/2]).
-export([remove/3]).
-export([remove_all/2]).
-export([remove_group/3]).
-export([remove_groups/3]).
-export([to_external/1]).
-export([topsort/1]).
-export([unknown/2]).
-export([update/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Returns a validated group built from `Data`.

`name` is required and must be a valid, non-reserved group name; `groups` — the
parent list — defaults to empty. Raises on invalid input. The result is not
persisted; pass it to `add/3`.
""".
-spec new(Data :: map()) -> Group :: t().

new(Data) ->
    type_and_version(maps_utils:validate(Data, ?VALIDATOR)).

-doc "Returns the group names the user's username.".
-spec name(t()) -> name().

name(#{name := Val}) -> Val.

-doc "Returns the group names the user `User` is member of.".
-spec groups(t()) -> [name()].

groups(#{groups := Val}) -> Val.

-doc """
Returns `true` if group `Group` is a member of the group named `Name`.
Otherwise returns `false`.
""".
-spec is_member(Name :: name(), Group :: t()) -> boolean().

is_member(Name0, #{type := ?TYPE, groups := Val}) ->
    Name = normalise_name(Name0),
    Name == all orelse lists:member(Name, Val).

-doc "Returns the metadata map associated with the group `Group`.".
-spec meta(Group :: t()) -> map().

meta(#{type := ?TYPE, meta := Val}) -> Val.

-doc """
Adds group `Group` to realm `RealmUri`. Equivalent to `add/3` with default
options.
""".
-spec add(uri(), t()) -> {ok, t()} | {error, any()}.

add(RealmUri, Group) ->
    add(RealmUri, Group, #{}).

-doc """
Adds a new group or updates an existing one.
This change is globally replicated.
""".
-spec add(RealmUri :: uri(), Group :: t(), Opts :: add_opts()) ->
    {ok, t()} | {error, add_error()}.

add(RealmUri, #{type := ?TYPE, name := Name} = Group, Opts) ->
    IfExists = maps:get(if_exists, Opts, fail),

    try
        do_add(RealmUri, Group, Opts)
    catch
        throw:already_exists when IfExists == update ->
            update(RealmUri, Name, Group);
        throw:already_exists ->
            {error, already_exists};
        throw:Reason ->
            {error, Reason}
    end.

-doc """
Name cannot be a reserved name. See `bondy_rbac:is_reserved_name/1`.
""".
-spec update(RealmUri :: uri(), Name :: binary(), Data :: map()) ->
    {ok, NewGroup :: t()} | {error, any()}.

update(RealmUri, Name, Data0) when is_binary(Name) ->
    %% TODO validate that we are not updating a prototype group, if so raise a
    %% {operation_not_allowed}
    try
        Data = maps_utils:validate(Data0, ?UPDATE_VALIDATOR),

        ok = not_reserved_name_check(Name),

        case do_get(RealmUri, Name) of
            undefined ->
                throw(unknown_group);
            Group ->
                NewGroup = maps:merge(from_term({Name, Group}), Data),

                %% Throws an exception if any group does not exist in RealmUri
                %% or in its prototype
                ok = group_exists_check(RealmUri, maps:get(groups, NewGroup)),

                ok = store(RealmUri, Name, NewGroup, #{}),
                {ok, NewGroup}
        end
    catch
        throw:Reason ->
            {error, Reason}
    end.

-doc """
Adds group named `Groupname` to groups `Groups` in realm with uri `RealmUri`.
""".
-spec add_group(
    RealmUri :: uri(),
    Groups :: all | t() | list(t()) | name() | list(name()),
    Groupname :: name()
) -> ok.

add_group(RealmUri, Groups, Groupname) ->
    add_groups(RealmUri, Groups, [Groupname]).

-doc """
Adds groups `Groupnames` to groups `Groups` in realm with uri `RealmUri`.
""".
-spec add_groups(
    RealmUri :: uri(),
    Groups :: all | t() | list(t()) | name() | list(name()),
    Groupnames :: [name()]
) -> ok.

add_groups(RealmUri, Groups, Groupnames) ->
    Fun = fun(Current, ToAdd) ->
        sets:to_list(
            sets:union(
                sets:from_list(Current),
                sets:from_list(ToAdd)
            )
        )
    end,
    update_groups(RealmUri, Groups, Groupnames, Fun).

-doc """
Removes groups `Groupnames` from groups `Groups` in realm with uri `RealmUri`.
""".
-spec remove_group(
    RealmUri :: uri(),
    Groups :: all | t() | list(t()) | name() | list(name()),
    Groupname :: name()
) -> ok.

remove_group(RealmUri, Groups, Groupname) ->
    remove_groups(RealmUri, Groups, [Groupname]).

-doc """
Removes groups `Groupnames` from groups `Groups` in realm with uri `RealmUri`.
""".
-spec remove_groups(
    RealmUri :: uri(),
    Groups :: all | t() | list(t()) | name() | list(name()),
    Groupnames :: [name()]
) -> ok.

remove_groups(RealmUri, Groups, Groupnames) ->
    Fun = fun(Current, ToRemove) ->
        Current -- ToRemove
    end,
    update_groups(RealmUri, Groups, Groupnames, Fun).

-doc """
Removes group `Name` from `RealmUri`. Equivalent to `remove/3` with default
options.
""".
-spec remove(uri(), binary() | map()) ->
    ok | {error, unknown_group | reserved_name}.

remove(RealmUri, Name) ->
    remove(RealmUri, Name, #{}).

-doc """
Removes group `Name` from `RealmUri`, together with everything that referred to
it: its grants, its members' memberships, and its appearance in any other
group's parent list.

The name becomes free, and nothing a later group of the same name inherits comes
from this one. Returns `{error, unknown_group}` for a group that does not exist
and `{error, reserved_name}` for a reserved one.
""".
-spec remove(uri(), binary() | map(), map()) ->
    ok | {error, unknown_group | reserved_name}.

remove(RealmUri, #{type := ?TYPE, name := Name}, Opts) ->
    remove(RealmUri, Name, Opts);
remove(RealmUri, Name, _Opts) ->
    try
        ok = not_reserved_name_check(Name),
        ok = exists_check(RealmUri, Name),

        %% delete any associated grants, so if a group with the same name
        %% is added again, they don't pick up these grants
        ok = bondy_rbac:revoke_group(RealmUri, Name),

        %% Delete the group out of any user's or group's `groups` property.
        %% For USERS this drains the group's members via the `by_group`
        %% reverse index (O(members-of-G)) instead of scanning every user in
        %% the realm. For GROUPS (parent-of relationships) there is no reverse
        %% index yet, so it still folds every group — acceptable since groups
        %% are few; a `group_parent` reverse index is the identical follow-on.
        %% Both updates bump the affected records' object versions.
        ok = bondy_rbac_user:remove_group_from_members(RealmUri, Name),
        ok = remove_group(RealmUri, all, Name),

        %% Delete the group and fire the local delete side-effect.
        ok = bondy_db:apply(table(), RealmUri, Name, clear),
        do_on_delete(RealmUri, Name)
    catch
        throw:Reason ->
            {error, Reason}
    end.

-doc """
Removes all groups that beloong to realm `RealmUri`.
If the option `dirty` is set to `true` this removes the groups directly from
store (triggering a broadcast to other Bondy nodes). If set to `false` (the
default) then for each group the function `remove/2` is called.

Use `dirty` with a value of `true` only when you are removing the realm
entirely.
""".
-spec remove_all(uri(), #{dirty => boolean()}) -> ok.

remove_all(RealmUri, Opts) ->
    Dirty = maps:get(dirty, Opts, false),
    Table = table(),
    %% Stream every group cell through a bounded keyset fold instead of
    %% materialising the whole realm. Deleting behind a forward keyset cursor is
    %% safe — cleared cells drop out of the next page.
    {ok, ok} = bondy_relation:fold(
        raw_relation(Table),
        RealmUri,
        fun({Name, _V}, ok) ->
            _ =
                case Dirty of
                    true ->
                        %% Realm teardown: clear the cell and fire the same
                        %% per-group delete event `remove/3` fires.
                        ok = bondy_db:apply(Table, RealmUri, Name, clear),
                        do_on_delete(RealmUri, Name);
                    false ->
                        remove(RealmUri, Name, Opts)
                end,
            ok
        end,
        ok
    ),
    ok.

-doc """
Returns group `Name` of realm `RealmUri`, or `{error, not_found}`.

Note the shape: the group is returned bare, not wrapped in an `ok` tuple. The
name `anonymous` resolves to the synthetic group every realm has, without a
read.
""".
-spec lookup(uri(), list() | binary()) -> t() | {error, not_found}.

lookup(RealmUri, Name0) ->
    Name = normalise_name(Name0),

    case Name == anonymous of
        true ->
            ?ANONYMOUS;
        false ->
            case do_get(RealmUri, Name) of
                undefined ->
                    {error, not_found};
                Value ->
                    from_term({Name, Value})
            end
    end.

-doc """
Returns group `Name` of realm `RealmUri`, raising `not_found` when there is
none. The raising counterpart of `lookup/2`.
""".
-spec fetch(uri(), list() | binary()) -> t() | no_return().

fetch(RealmUri, Name) ->
    case lookup(RealmUri, Name) of
        {error, not_found} -> error(not_found);
        Group -> Group
    end.

-doc "Whether realm `RealmUri` has a group named `Name`.".
-spec exists(uri(), list() | binary()) -> boolean().

exists(RealmUri, Name) ->
    case lookup(RealmUri, Name) of
        {error, not_found} -> false;
        _ -> true
    end.

-doc "Returns every group of `RealmUri`. Equivalent to `list/2` with no limit.".
-spec list(uri()) -> list(t()).

list(RealmUri) ->
    list(RealmUri, #{}).

-doc """
Returns the groups of `RealmUri`, at most `limit` of them when that option is
given.

The synthetic `anonymous` group heads the list and is not stored, so a realm
that declares no groups still lists one. Groups inherited from the realm's
prototype are not included.
""".
-spec list(RealmUri :: uri(), Opts :: list_opts()) -> list(t()).

list(RealmUri, Opts) ->
    %% TODO We SHOULD list the realm's prototype roups as well (amd potentially
    %% marking them with a flag)
    %% The synthetic `?ANONYMOUS` group is not stored; it always heads the list.
    Relation = relation(),
    case maps_utils:get_any([limit, <<"limit">>], Opts, undefined) of
        undefined ->
            %% Whole-realm listing — streamed through a bounded keyset fold so
            %% it never materialises the raw cell set.
            {ok, Acc} = bondy_relation:fold(
                Relation, RealmUri, fun(Group, A) -> [Group | A] end, []
            ),
            [?ANONYMOUS | lists:reverse(Acc)];
        Limit ->
            %% Bounded prefix: at most `Limit` rows incl. the leading anonymous
            %% group (mirrors the prior `lists:sublist([?ANONYMOUS | All], _)`).
            {ok, #{values := Groups}} =
                bondy_relation:list(Relation, RealmUri, #{limit => Limit}),
            lists:sublist([?ANONYMOUS | Groups], Limit)
    end.

-doc """
Lists the usernames of the members of group `Name` in realm `RealmUri`,
paginated — the reverse direction of the `member` relation.

Delegates to `bondy_rbac_user:list_members/3`, which reads the substrate
`by_group` index (bounded, realm-scoped) rather than scanning the realm's
users. `Opts` carries `limit` and `cursor`; returns `{Usernames,
Continuation}` (`Continuation` is `undefined` at the end). The read is
eventually-consistent with `user.groups`.
""".
-spec members(RealmUri :: uri(), Name :: name(), Opts :: map()) ->
    {[bondy_rbac_user:username()], Continuation :: binary() | undefined}.

members(RealmUri, Name, Opts) ->
    bondy_rbac_user:list_members(RealmUri, Name, Opts).

-doc "Returns the external representation of the Group.".
-spec to_external(Group :: t()) -> external().

to_external(#{type := ?TYPE, version := ?VERSION} = Group) ->
    Group.

-doc """
Takes a list of groupnames and returns any that can't be found on the realm
identified by `RealmUri` or in its prototype (if set).
""".
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

-doc """
Creates a directed graph of the groups `Groups` by traversing the group
membership relationship and computes the topological ordering of the
groups if such ordering exists.  Otherwise returns `Groups` unmodified.
Fails with `{cycle, Path :: [name()]}` exception if the graph directed graph
has cycles of length two or more.

This function doesn't fetch the definition of the groups in each group
`groups` property.
""".
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
                                {_, #{type := ?TYPE} = G} -> [G | Acc]
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

-doc """
Returns `Term` in the form group names are stored in: casefolded, with the
reserved names `all` and `anonymous` as atoms whichever way they were written.

Every read and write path folds names this way, so a caller supplying a name
from outside Bondy should fold it here first. Raises `badarg` for anything that
is not a binary or a reserved name.
""".
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
    string:casefold(Term);
normalise_name(_) ->
    error(badarg).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The published `security_groups` table handle, or an error when the catalogue
%% has not provisioned it yet.
table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_GROUP_TAB) of
        undefined -> error(security_groups_table_unavailable);
        Table -> Table
    end.

%% @private
%% The `security_groups` table as a paginatable relation of group records.
relation() ->
    bondy_relation:new(?BONDY_DB_GROUP_TAB, #{
        table => table(),
        decode => fun decode_group_row/1
    }).

%% @private
decode_group_row({Name, V, _Hlc}) when is_map(V) ->
    {ok, from_term({Name, V})};
decode_group_row(_) ->
    skip.

%% @private
%% Every group cell as `{Name, RawValue}` — for whole-table maintenance
%% (`remove_all/2`) that works from the storage key.
raw_relation(Table) ->
    bondy_relation:new(?BONDY_DB_GROUP_TAB, #{
        table => Table,
        decode => fun decode_raw_row/1
    }).

%% @private
decode_raw_row({Name, V, _Hlc}) when is_map(V) ->
    {ok, {Name, V}};
decode_raw_row(_) ->
    skip.

%% @private
%% Reads a cell, returning the bare value, or `undefined` when the cell is
%% absent or cleared — the two are indistinguishable to callers by design.
do_get(RealmUri, Name) ->
    case bondy_db:read(table(), RealmUri, Name) of
        {ok, {Value, _Hlc}} -> Value;
        {error, not_found} -> undefined
    end.

%% @private
%% The group lifecycle events, published inline from the write and delete
%% chokepoints (`store/4`, `remove/3`, `remove_all/2`). A peer's merged write
%% does not reach here; the invalidation it needs is wired through the
%% merge-side reactor instead.
-spec do_on_update(uri(), name(), IsCreate :: boolean()) -> ok.

do_on_update(RealmUri, Name, true) ->
    bondy_event_manager:notify({[bondy, rbac, group, added], RealmUri, Name}),
    ok;
do_on_update(RealmUri, Name, false) ->
    bondy_event_manager:notify({[bondy, rbac, group, updated], RealmUri, Name}),
    ok.

-spec do_on_delete(uri(), name()) -> ok.

do_on_delete(RealmUri, Name) ->
    bondy_event_manager:notify({[bondy, rbac, group, deleted], RealmUri, Name}),
    ok.

%% @private
do_add(RealmUri, #{type := ?TYPE, name := Name} = Group, Opts) ->
    %% This should have been validated before but just to avoid any issues
    %% we do it again.
    ok = not_reserved_name_check(Name),
    ok = group_exists_check(RealmUri, maps:get(groups, Group)),

    %% We skip the existence check when applying declarative config (overwrite).
    Declarative = maps:get(declarative, Opts, false),
    Declarative == true orelse not_exists_check(RealmUri, Name),

    case store(RealmUri, Name, Group, Opts) of
        ok ->
            {ok, Group};
        Error ->
            Error
    end.

%% @private
store(RealmUri, Name, Group, #{declarative := true}) ->
    %% Declarative config apply: write WITHOUT firing the lifecycle event, and
    %% IDEMPOTENTLY (a write only when the value changes). Re-reading the same
    %% config file on every boot must not re-stamp the group cell with a fresh
    %% HLC — that would diverge cross-node convergence. The op-based CRDT
    %% + anti-entropy handle convergence, so no deterministic-version write is
    %% needed.
    %%
    %% The RBAC invalidation is NOT a lifecycle side-effect and is therefore not
    %% skipped here: `bondy_rbac:grant/4` invalidates on this path too. An
    %% unchanged config reconciles to no write, so the common boot emits none.
    invalidate_rbac_on(
        bondy_db:reconcile(table(), RealmUri, Name, Group), RealmUri
    );
store(RealmUri, Name, Group, _) ->
    %% The previous value distinguishes a create from an update, which is the
    %% only difference between the two lifecycle events.
    Old = do_get(RealmUri, Name),
    ok = invalidate_rbac_on(
        bondy_db:apply(table(), RealmUri, Name, {set, Group}), RealmUri
    ),
    do_on_update(RealmUri, Name, Old == undefined).

%% @private
%% A group's `groups` property is its parent list — the role-inheritance edge —
%% and `bondy_rbac:get_context/2` bakes the grants that edge resolves to into
%% the cached context. So a group write changes what a live session is
%% authorized to do, exactly as a grant or membership write does, and gets the
%% same in-place re-evaluation (§9.5): no teardown, the next authorize re-walks
%% the group graph.
%%
%% Realm-wide and unconditional on a successful write. Narrowing it to "only
%% when the parents changed" would need an old/new comparison whose failure
%% mode is a missed revocation; over-invalidating costs one lazy rebuild. This
%% mirrors `bondy_rbac:invalidate_sessions_on/2`, which is deliberately
%% realm-wide for the same reason. Group DELETION is already covered — it goes
%% through `bondy_rbac:revoke_group/2`, which invalidates.
invalidate_rbac_on(ok, RealmUri) ->
    bondy_session_manager:invalidate_rbac_all(RealmUri);
invalidate_rbac_on(Other, _RealmUri) ->
    Other.

%% @private
-doc "Doesn't take into account realm inheritance.".
exists_check(RealmUri, Name) ->
    case do_get(RealmUri, Name) of
        undefined -> throw(unknown_group);
        _ -> ok
    end.

%% @private
-doc "Doesn't take into account realm inheritance".
not_exists_check(RealmUri, Name) ->
    case do_get(RealmUri, Name) of
        undefined -> ok;
        _ -> throw(already_exists)
    end.

%% @private
-doc "Takes into account realm inheritance".
group_exists_check(RealmUri, Groups) ->
    %% Takes into account realm inheritance as it uses unknown
    case unknown(RealmUri, Groups) of
        [] ->
            ok;
        Unknown ->
            throw({no_such_groups, Unknown})
    end.

%% @private
-doc "Takes into account realm inheritance".
do_unknown(RealmUri, Names) ->
    ordsets:fold(
        fun
            (all, Acc) ->
                Acc;
            (anonymous, Acc) ->
                Acc;
            (Name, Acc) ->
                case do_get(RealmUri, Name) of
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

-doc """
Exported for legacy-backup import: upgrade a pre-v1.1 proplist group
value to the current map (or pass a current map through).
""".
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
    %% Bounded keyset fold over every group record — replaces a full-realm
    %% materialise.
    {ok, ok} = bondy_relation:fold(
        relation(),
        RealmUri,
        fun(Group, ok) -> update_groups(RealmUri, Group, Groupnames, Fun) end,
        ok
    ),
    ok;
update_groups(RealmUri, Groups, Groupnames, Fun) when is_list(Groups) ->
    _ = [update_groups(RealmUri, Group, Groupnames, Fun) || Group <- Groups],
    ok;
update_groups(
    RealmUri, #{type := ?TYPE, name := Name} = Group, Groupnames, Fun
) when
    is_function(Fun, 2)
->
    Update = #{groups => Fun(maps:get(groups, Group), Groupnames)},
    case update(RealmUri, Name, Update) of
        {ok, _} -> ok;
        {error, Reason} -> throw(Reason)
    end;
update_groups(RealmUri, GroupName, Groupnames, Fun) when is_binary(GroupName) ->
    update_groups(RealmUri, fetch(RealmUri, GroupName), Groupnames, Fun).

%% =============================================================================
%% PRIVATE: TOPSORT
%% =============================================================================

precedence_graph(Groups, Graph) ->
    _ = [
        digraph:add_vertex(Graph, N)
     || #{groups := Names} <- Groups, N <- Names
    ],
    precedence_graph_aux(Groups, Graph).

precedence_graph_aux(
    [#{type := ?TYPE, name := A, groups := Names} = H | T], Graph
) ->
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
precedence_graph_aux([#{type := ?TYPE} | T], Graph) ->
    precedence_graph_aux(T, Graph);
precedence_graph_aux([], Graph) ->
    Graph.
