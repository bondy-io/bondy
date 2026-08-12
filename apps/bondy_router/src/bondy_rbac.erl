%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rbac).
-moduledoc """
Authorization: the grants that say which roles may perform which operation on
which resource, and the contexts sessions are authorized against.

A grant binds a role — a user or a group — to a set of permissions on a
resource. `authorize/3` answers whether a session may act, and it answers from a
**context**: a snapshot in which the role's own grants and everything it
inherits through its groups have already been resolved. Resolving that graph on
every message would be too costly, so a context is built once and cached on the
session.

Because a context is a snapshot, a grant change has to reach it. Every write
path here invalidates the realm's cached contexts, and a session re-resolves on
its next authorization; `refresh_context/1` additionally rebuilds a context that
has outlived its epoch. This is why authorization changes take effect without
tearing sessions down, whereas authentication changes do close them.

A resource is matched by policy rather than by equality: a grant names an
exact URI, a prefix, or a wildcard pattern, and `authorize/3` accepts when any
grant of the role matches under its own policy.

Start from `grant/2` and `revoke/2` to change permissions, `get_context/2` to
build a context, and `authorize/3` to decide.

### WAMP Permissions:

- "wamp.register"
- "wamp.unregister"
- "wamp.call"
- "wamp.cancel"
- "wamp.subscribe"
- "wamp.unsubscribe"
- "wamp.publish"
- "wamp.disclose_caller"
- "wamp.disclose_publisher"

### Reserved Names
Reserved names are role (user or group) or resource names that act as
keywords in RBAC in either binary or atom forms and thus cannot be used.

The following is the list of all reserved names.

- all - group
- anonymous - the anonymous user and group
- any - use to denote a resource
- from - use to denote a resource
- on - not used
- to - use to denote a resource

**Note:**
Usernames and group names are stored in lower case. All functions in this
module are case sensitice so when using the functions in this module make
sure the inputs you provide are in lowercase to. If you need to convert your
input to lowercase use `string:casefold/1`.

## Storage

Grants live in the `security_user_grants` and `security_group_grants` tables of
the durable `main` database, banded by realm. The `{Rolename, Resource}` key is
an order-preserving composite leading with the role (`encode_key/1`), so every
grant of one role occupies a contiguous key range and `grants/2` is a bounded
band scan. The reverse question — which roles hold a grant on a resource — is
answered by a `by_resource` index, whose rows are re-read against their primary
cells so a revoked grant cannot surface through a stale index entry.

A grant or revoke invalidates this node's cached authorization contexts for the
realm: inline for a local change, and through the merge-side reactor when a
peer's change arrives by anti-entropy.
""".
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").
-include("bondy_security.hrl").

-define(GRANT_REQ_VALIDATOR_V1, begin
    ?GRANT_RESOURCE_VALIDATOR
end#{
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
        datatype => {in, [?EXACT_MATCH, ?PREFIX_MATCH, ?WILDCARD_MATCH]}
    }
}).

-ifdef(TEST).

-define(CTXT_REFRESH_SECS, 1).

-else.

%% 5 minutes, expressed in SECONDS to match `Diff = Now - epoch` in
%% refresh_context/1 (which is also in seconds). A millisecond value here —
%% `timer:minutes(5)` = 300000 — compares against a seconds-valued Diff and
%% defers the RBAC context refresh for ~3.47 days, so grant and membership
%% revocations go unhonoured for the life of a session.
-define(CTXT_REFRESH_SECS, 300).

-endif.

-record(bondy_rbac_context, {
    realm_uri :: binary(),
    username :: binary(),
    explicit_groups = [] :: [binary()],
    exact_grants = #{} :: #{permission() => Resources :: [binary()]},
    pattern_grants :: [grant()],
    epoch :: integer(),
    is_anonymous = false :: boolean()
}).

-type context() :: #bondy_rbac_context{}.
-type permission() :: binary().
-type resource() ::
    any
    % <<"any">>
    | binary()
    | #{uri := binary(), strategy := binary()}
    | normalised_resource().
-type normalised_resource() :: any | {Uri :: uri(), MatchStrategy :: binary()}.
-type rolename() ::
    all
    | bondy_rbac_user:username()
    | bondy_rbac_group:name().
-type request_data() :: map().
-type request() :: #{
    type := request,
    roles := [rolename()],
    permissions := [binary()],
    resources := [normalised_resource()]
}.
-type grant() :: {
    normalised_resource(),
    [Permission :: permission()]
}.
-type grant_opts() :: #{
    %% `true` when applying declarative config (idempotent write, no runtime
    %% side-effects) — see `bondy_realm:apply_config/0`.
    declarative => boolean(),
    actor_id => term()
}.

-export_type([context/0]).
-export_type([grant/0]).
-export_type([grant_opts/0]).
-export_type([permission/0]).
-export_type([request/0]).
-export_type([request_data/0]).
-export_type([resource/0]).

-export([authorize/2]).
%% Exported for the legacy-backup import translator (bondy_export): the grant
%% key must be encoded byte-identically to the live write path.
-export([encode_key/1]).
-export([authorize/3]).
-export([externalize_grant/1]).
-export([get_anonymous_context/1]).
-export([get_anonymous_context/2]).
-export([anonymous_allowed/1]).
-export([get_context/1]).
-export([get_context/2]).
-export([get_context/3]).
-export([get_metadata/2]).
-export([get_metadata/3]).
-export([grant/2]).
-export([grant/3]).
-export([grants/2]).
-export([grants_on_resource/2]).
-export([group_grants/2]).
-export([is_reserved_name/1]).
-export([normalise_name/1]).
-export([refresh_context/1]).
-export([remove_all/2]).
-export([request/1]).
-export([revoke/2]).
-export([revoke_group/2]).
-export([revoke_user/2]).
-export([user_grants/2]).

-export([do_get_metadata/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Returns 'ok' or an exception.".
-spec authorize(binary(), bondy_context:t() | context()) ->
    ok | no_return().

authorize(Permission, Ctxt) ->
    authorize(Permission, any, Ctxt).

-doc """
Returns 'ok' or an exception.
Failures:

- `{no_such_realm, uri()}`
- `{not_authorized, Reason :: binary()}`
""".
-spec authorize(binary(), binary() | any, bondy_context:t() | context()) ->
    ok | no_return().

authorize(Permission, Resource, #bondy_rbac_context{} = Ctxt) ->
    do_authorize(Permission, Resource, Ctxt);
authorize(_, _, #{authid := '$internal'}) ->
    ok;
authorize(Permission, Resource, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),

    try bondy_context:is_security_enabled(Ctxt) of
        true ->
            RBACCtxt = bondy_session:rbac_context(
                bondy_context:session(Ctxt)
            ),
            do_authorize(Permission, Resource, RBACCtxt);
        false ->
            ok
    catch
        _:{not_found, RealmUri} ->
            error({no_such_realm, RealmUri})
    end.

-doc """
Returns the authorization context for the session `Ctxt` belongs to, resolving
the anonymous case to `get_anonymous_context/1`.
""".
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

-doc """
Returns `{Refreshed, Context}`: the context rebuilt if it has outlived its
epoch or been invalidated, otherwise the one given, with `Refreshed` saying
which happened.

A caller that holds a context across messages calls this so a grant change made
elsewhere takes effect without the session being closed.
""".
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
            Username = Context#bondy_rbac_context.username,
            Ctxt =
                case Context#bondy_rbac_context.explicit_groups of
                    [_ | _] = Groups ->
                        get_context(Uri, Username, Groups);
                    _ ->
                        get_context(Uri, Username)
                end,
            {true, Ctxt};
        _ ->
            {false, Context}
    end.

-doc """
Returns the authorization context for an anonymous session, resolved against the
realm's `anonymous` group.

Whether anonymous access is permitted at all is a policy question decided
before the grants are consulted: `security.allow_anonymous_user` may forbid it,
or permit it only from a loopback address.
""".
-spec get_anonymous_context(Ctxt :: bondy_context:t()) -> context().

get_anonymous_context(Ctxt) ->
    SourceIP = bondy_context:source_ip(Ctxt),
    case anonymous_allowed(SourceIP) of
        true ->
            AuthId = bondy_context:authid(Ctxt),
            RealmUri = bondy_context:realm_uri(Ctxt),
            get_anonymous_context(RealmUri, AuthId);
        false ->
            error({not_authorized, <<"Anonymous user not allowed.">>})
    end.

-doc """
Returns an authorization context for an anonymous session of `RealmUri`,
resolved against the realm's `anonymous` group.

Takes the realm and username directly, without consulting the
`security.allow_anonymous_user` policy that `get_anonymous_context/1` applies —
the caller has already decided anonymous access is permitted.
""".
get_anonymous_context(RealmUri, Username) ->
    Ctxt = build_context(
        RealmUri, Username, grants(RealmUri, anonymous, group)
    ),
    Ctxt#bondy_rbac_context{is_anonymous = true}.

-doc """
Whether anonymous authentication is permitted for a connection originating from
`SourceIP`, per the `security.allow_anonymous_user` policy:

- `off`   — anonymous is disabled.
- `local` — allowed only from a loopback address (the default); mirrors
  RabbitMQ's loopback-only `guest` user and Redis protected mode, so local
  development works out of the box while remote anonymous access is an explicit
  opt-in.
- `on`    — allowed from anywhere the realm's own sources permit.

The master realm never accepts anonymous connections regardless of this policy
(its authmethods do not include anonymous).
""".
-spec anonymous_allowed(SourceIP :: inet:ip_address() | undefined) -> boolean().

anonymous_allowed(SourceIP) ->
    case anonymous_policy() of
        on -> true;
        local -> is_loopback_addr(SourceIP);
        off -> false
    end.

%% @private
anonymous_policy() ->
    case bondy_config:get([security, allow_anonymous_user], local) of
        on -> on;
        local -> local;
        off -> off;
        %% Legacy boolean form (the setting was a {flag, on, off} before it
        %% became a three-state policy).
        true -> on;
        false -> off;
        _ -> local
    end.

%% @private
is_loopback_addr({127, _, _, _}) -> true;
is_loopback_addr({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback_addr(_) -> false.

-doc """
Contexts are only valid until the GRANT epoch changes, and it will
change whenever a GRANT or a REVOKE is performed. This is a little coarse
grained right now, but it'll do for the moment.
""".
get_context(RealmUri, Username) when
    is_binary(Username) orelse Username == anonymous
->
    build_context(RealmUri, Username, grants(RealmUri, Username, user)).

-doc """
Returns an authorization context for `Username` in `RealmUri`, resolved against
`ExplicitGroups` in addition to the user's own memberships.

The context is a snapshot: the role's grants and everything reachable through
the group graph are resolved now and answer every later `authorize/3` without a
further read. It carries an epoch, so `refresh_context/1` can tell when it has
grown stale.

Explicit groups are how a claim-based session contributes roles Bondy does not
store — an OIDC subject may have no local user record at all, and carries its
group memberships from the identity provider. They are added to, never
substituted for, the user's own memberships and the `all` group.
""".
-spec get_context(
    RealmUri :: uri(),
    Username :: binary() | anonymous,
    ExplicitGroups :: [binary()]
) -> context().

get_context(RealmUri, Username, ExplicitGroups0) when
    (is_binary(Username) orelse Username == anonymous) andalso
        is_list(ExplicitGroups0)
->
    %% Normalise group names early so the context stores casefolded names
    ExplicitGroups = [normalise_name(G) || G <- ExplicitGroups0],

    ProtoUri = bondy_realm:prototype_uri(RealmUri),
    RealmProto = {RealmUri, ProtoUri},

    %% 'all' grants always apply
    Acc0 = lists:map(
        fun({{all, Resource}, Permissions}) ->
            {{<<"group/all">>, Resource}, Permissions}
        end,
        lists:append(
            find_grants(RealmUri, {all, '_'}, group),
            find_grants(ProtoUri, {all, '_'}, group)
        )
    ),

    %% Traverse explicit groups (from IdP claims) for their grants
    {Acc1, _Seen1} = acc_grants(ExplicitGroups, group, RealmProto, [], Acc0),

    %% Also gather the user's DIRECT grants (rows whose role IS the username
    %% in the user grant table). Deliberately NOT `acc_grants/5` on the
    %% username: that traverses the user's LOCALLY-STORED group memberships,
    %% which must not contribute here — the explicit (IdP-claimed) groups are
    %% the sole authority on group-derived permissions for this session, and
    %% folding local memberships back in would escalate a claim-restricted
    %% session to the union of both.
    UserGrants = lists:append(
        find_grants(RealmUri, {Username, '_'}, user),
        find_grants(ProtoUri, {Username, '_'}, user)
    ),

    build_context(
        RealmUri,
        Username,
        group_grants(lists:flatten([UserGrants | Acc1])),
        ExplicitGroups
    ).

-doc """
Returns the metadata `Username` accumulates in `RealmUri`: their own, merged
with that of every group they reach through the group graph.
""".
get_metadata(_, anonymous) ->
    #{};
get_metadata(RealmUri, Username) ->
    case bondy_rbac_user:lookup(RealmUri, Username) of
        {ok, User} ->
            ProtoUri = bondy_realm:prototype_uri(RealmUri),
            RealmProto = {RealmUri, ProtoUri},
            Acc = maps:to_list(bondy_rbac_user:meta(User)),
            do_get_metadata(bondy_rbac_user:groups(User), RealmProto, Acc);
        {error, not_found} ->
            #{}
    end.

-doc """
Returns the metadata `Username` accumulates in `RealmUri`, resolving `Groups` in
addition to the user's own memberships.
""".
get_metadata(RealmUri, Username, Groups) ->
    ProtoUri = bondy_realm:prototype_uri(RealmUri),
    RealmProto = {RealmUri, ProtoUri},

    case bondy_rbac_user:lookup(RealmUri, Username) of
        {ok, User} ->
            Acc = maps:to_list(bondy_rbac_user:meta(User)),
            do_get_metadata(Groups, RealmProto, Acc);
        {error, not_found} ->
            %% When IDP is not Bondy
            do_get_metadata(Groups, RealmProto, [])
    end.

-doc """
Returns true if term is a reserved name in binary or atom form.

**Reserved names:**

- all
- anonymous
- any
- from
- on
- to
""".
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

-doc """
Normalises the utf8 binary `Bin` into a Normalised Form of compatibly
equivalent Decomposed characters according to the Unicode standard and
converts it to a case-agnostic comparable string.
""".
-spec normalise_name(Term :: binary() | atom()) -> boolean() | no_return().

normalise_name(Bin) when is_binary(Bin) ->
    string:casefold(unicode:characters_to_nfkd_binary(Bin)).

-doc "Validates the data for a grant or revoke request.".
-spec request(Data :: request_data()) -> Request :: request() | no_return().

request(Data) ->
    validate(Data).

-doc """
**Use cases**

```
grant <permissions> on any to all|{<user>|<group>[,...]}
grant <permissions> on {<resource>, <exact|prefix|wildcard>} to all|{<user>|<group>[,...]}
```
""".
-spec grant(RealmUri :: uri(), Request :: request() | map()) ->
    ok | {error, Reason :: any()} | no_return().

grant(RealmUri, Arg) ->
    grant(RealmUri, Arg, #{}).

-doc """
**Use cases**

```
grant <permissions> on any to all|{<user>|<group>[,...]}
grant <permissions> on {<resource>, <exact|prefix|wildcard>} to all|{<user>|<group>[,...]}
```
""".
-spec grant(
    RealmUri :: uri(), Request :: request() | map(), Opts :: grant_opts()
) ->
    ok | {error, Reason :: any()} | no_return().

grant(RealmUri, #{type := request} = Request, Opts) ->
    bondy_realm:exists(RealmUri) orelse error({no_such_realm, RealmUri}),
    #{
        roles := Roles,
        permissions := Permissions,
        resources := Resources
    } = Request,

    grant(RealmUri, Roles, Resources, Permissions, Opts);
grant(RealmUri, Data, Opts) when is_map(Data) ->
    grant(RealmUri, request(Data), Opts).

-doc """
Revokes the permissions `Request` names, from the roles it names, on the
resource it names.

Revocation is per permission: a grant carrying permissions this request does not
name keeps them. Removing every permission removes the grant. Invalidates the
realm's cached authorization contexts, so sessions lose the permission on their
next authorization rather than when they next connect. Raises
`{no_such_realm, _}` for an unknown realm.
""".
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

-doc """
Revokes every grant held directly by user `Username`. Grants reaching them
through a group are unaffected — those belong to the group.

Part of deleting the user: a grant left behind would apply to whoever next holds
the name.
""".
revoke_user(RealmUri, Username) ->
    revoke_role_grants(grant_table(user), RealmUri, Username).

-doc """
Revokes every grant held directly by group `Name`. Grants reaching it through a
parent group are unaffected — those belong to the parent.

Part of deleting the group: a grant left behind would apply to whatever group
next holds the name.
""".
revoke_group(RealmUri, Name) ->
    revoke_role_grants(grant_table(group), RealmUri, Name).

-doc """
Returns the local grants assigned in realm `RealmUri`. This function does not
use protypical inheritance.
""".
-spec grants(RealmUri :: uri(), Opts :: map()) ->
    [{{binary(), normalised_resource()}, [permission()]}].

grants(RealmUri, Opts0) ->
    Opts = maps:to_list(Opts0),
    GroupGrants = [
        {{concat_role(group, Name), Resource}, Permissions}
     || {{Name, Resource}, Permissions} <- find_grants(
            RealmUri, '_', group, Opts
        )
    ],
    UserGrants = [
        {{concat_role(user, Name), Resource}, Permissions}
     || {{Name, Resource}, Permissions} <- find_grants(
            RealmUri, '_', user, Opts
        )
    ],

    lists:append(GroupGrants, UserGrants).

-doc """
Returns every role holding a grant on exactly `Resource` in `RealmUri`, as
`{{Rolename, Resource}, Permissions}` — the reverse of `grants/2`.

`Resource` must be in stored, normalised form (`any | {Uri, Strategy}`), the
same form `grant/2` writes; a resource built by hand will not match otherwise.

Intended for administration and introspection, not for authorization, which
always reads forward by role. Answered through the `by_resource` index, which is
maintained asynchronously — a grant written moments ago may not appear yet —
and then re-read against the primary cells, so a grant revoked since the index
was written does not appear either.
""".
-spec grants_on_resource(RealmUri :: uri(), Resource :: normalised_resource()) ->
    [{{binary() | all | anonymous, normalised_resource()}, [permission()]}].

grants_on_resource(RealmUri, Resource) ->
    lists:append(
        grants_on_resource(grant_table(user), RealmUri, Resource),
        grants_on_resource(grant_table(group), RealmUri, Resource)
    ).

%% @private
%% Realm-scoped equality read of the `by_resource` index gives the candidate
%% primary keys; the forward fetch returns each grant's *fresh* permissions and
%% drops any entry whose primary was cleared since the index was written.
grants_on_resource(Table, RealmUri, Resource) ->
    {ok, Rows} = bondy_db:index_get(
        Table, RealmUri, by_resource, Resource, #{}
    ),
    lists:filtermap(
        fun({EncKey, _Cols}) ->
            case bondy_db:read(Table, RealmUri, EncKey) of
                {ok, {#{permissions := Permissions}, _Hlc}} ->
                    {true, {decode_key(EncKey), Permissions}};
                _ ->
                    false
            end
        end,
        Rows
    ).

-spec grants(
    RealmUri :: uri(), Name :: binary(), RoleType :: user | group
) ->
    [grant()].

grants(RealmUri, Name, Type) ->
    group_grants(acc_grants(RealmUri, Name, Type)).

-doc """
Returns the grants held by user `Username` — those granted to the user directly
and those reaching them through their groups.
""".
-spec user_grants(RealmUri :: uri(), Username :: binary()) -> [grant()].

user_grants(RealmUri, Username) ->
    grants(RealmUri, Username, user).

-doc """
Returns the grants held by group `Name` — those granted to the group directly
and those reaching it through its parent groups.
""".
-spec group_grants(RealmUri :: uri(), Name :: binary()) -> [grant()].

group_grants(RealmUri, Name) ->
    grants(RealmUri, Name, group).

-doc """
Resource must be a binary or the atom `any`.
In the case the resource is `any`, the role needs to have this permission
applied *globally*. This is for things with undetermined inputs or
permissions that don't tie to a particular resource.
""".
-spec check_permission(Permission :: permission(), Context :: context()) ->
    {true, context()} | {false, binary(), context()}.

check_permission(
    {Action, Resource} = Permission, #bondy_rbac_context{} = Ctxt0
) when
    is_binary(Resource) orelse Resource =:= any
->
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

-doc """
Removes every grant of `RealmUri`, user and group alike. Part of realm teardown
rather than an administrative operation.
""".
-spec remove_all(RealmUri :: uri(), Opts :: map()) -> ok.

remove_all(RealmUri, _Opts) ->
    ok = clear_all_grants(grant_table(user), RealmUri),
    ok = clear_all_grants(grant_table(group), RealmUri).

-doc "To list the grants for a realm, a role (group or user) or a resource.".
-spec externalize_grant(grant()) -> map().

externalize_grant({{Role, {_, _} = Resource}, Permissions}) ->
    ResourceMap = externalize_grant({Resource, Permissions}),
    ResourceMap#{
        <<"roles">> => [Role]
    };
%% To list the grants for a role (group or user)
externalize_grant({{<<>>, Strategy}, Permissions}) ->
    externalize_grant({{any, Strategy}, Permissions});
externalize_grant({{Uri, Strategy}, Permissions}) ->
    #{
        <<"resource">> => #{
            <<"uri">> => Uri,
            <<"match">> => Strategy
        },
        <<"permissions">> => Permissions
    };
%% TODO: check if it is possible or necessary to remove this clause
%% due to {<<>>, <<"prefix">>} is stored in this case matching the previous clause
externalize_grant({any, Permissions}) ->
    #{
        <<"resource">> => #{
            <<"uri">> => <<"">>,
            <<"match">> => ?PREFIX_MATCH
        },
        <<"permissions">> => Permissions
    }.

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
build_context(RealmUri, Username, Grants) ->
    build_context(RealmUri, Username, Grants, []).

%% @private
build_context(RealmUri, Username, Grants, ExplicitGroups) ->
    {Exact, Pattern} = lists:foldl(
        fun
            ({any, Permissions}, {Map, L}) ->
                {maps:put(any, Permissions, Map), L};
            ({{Uri, ?EXACT_MATCH}, Permissions}, {Map, L}) ->
                {maps:put(Uri, Permissions, Map), L};
            (Term, {Map, L}) ->
                {Map, [Term | L]}
        end,
        {#{}, []},
        Grants
    ),
    #bondy_rbac_context{
        realm_uri = RealmUri,
        username = Username,
        explicit_groups = ExplicitGroups,
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
            case bondy_wamp_uri:match(Resource, Uri, Strategy) of
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
    Permission, Resource, #bondy_rbac_context{is_anonymous = false} = Ctxt
) ->
    Username = to_bin(Ctxt#bondy_rbac_context.username),
    Tail =
        case Resource == any of
            true ->
                ["'"];
            false ->
                ["' on '", resource_to_iolist(Resource), "'"]
        end,

    unicode:characters_to_binary(
        [
            "Permission denied. ",
            "User '",
            Username,
            "' does not have permission '",
            Permission
            | Tail
        ],
        utf8,
        utf8
    );
permission_denied_message(
    Permission, Resource, #bondy_rbac_context{is_anonymous = true} = Ctxt
) ->
    Username = to_bin(Ctxt#bondy_rbac_context.username),
    Tail =
        case Resource == any of
            true ->
                ["'"];
            false ->
                ["' on '", resource_to_iolist(Resource), "'"]
        end,
    unicode:characters_to_binary(
        [
            "Permission denied. ",
            "Anonymous user '",
            Username,
            "' does not have permission '",
            Permission
            | Tail
        ],
        utf8,
        utf8
    ).

%% Walks the group graph breadth-first, accumulating each role's metadata.
%% Exported so `bondy_rbac_user` can resolve metadata without duplicating the
%% traversal; not part of the module's public surface.
-doc false.
do_get_metadata([H | T], {RealmUri, ProtoUri} = RealmProto, Acc0) ->
    case bondy_rbac_group:lookup(RealmUri, H) of
        {error, not_found} when ProtoUri == undefined ->
            %% Group not found and no prototype realm — skip and continue
            do_get_metadata(T, RealmProto, Acc0);
        {error, not_found} ->
            %% Try the prototype realm
            case bondy_rbac_group:lookup(ProtoUri, H) of
                {error, not_found} ->
                    %% Not in prototype either — skip and continue
                    do_get_metadata(T, RealmProto, Acc0);
                Group ->
                    Acc = [maps:to_list(bondy_rbac_group:meta(Group)) | Acc0],
                    L = T ++ bondy_rbac_group:groups(Group),
                    do_get_metadata(L, RealmProto, Acc)
            end;
        Group ->
            Acc = [maps:to_list(bondy_rbac_group:meta(Group)) | Acc0],
            L = T ++ bondy_rbac_group:groups(Group),
            do_get_metadata(L, RealmProto, Acc)
    end;
do_get_metadata([], _, []) ->
    #{};
do_get_metadata([], _, Acc) ->
    Map =
        maps:groups_from_list(
            fun({K, _}) -> K end,
            fun({_, V}) -> V end,
            lists:flatten(Acc)
        ),
    maps:map(
        fun
            (_, [[_ | _] = V]) ->
                %% If a singleton containing a list, we return the list
                V;
            (_, L0) when is_list(L0) ->
                IsList = lists:any(fun is_list/1, L0),
                %% Flatten and dedup
                case sets:to_list(sets:from_list(lists:flatten(L0))) of
                    [V] when IsList == false ->
                        % Unwrap if singleton
                        V;
                    L when is_list(L) ->
                        L
                end
        end,
        Map
    ).

%% =============================================================================
%% PRIVATE: REQUEST, GRANT, REVOKE
%% =============================================================================

%% @private
permission_validator(Term) ->
    bondy_wamp_uri:is_valid(Term, loose).

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
    Uri = bondy_wamp_uri:validate(Uri, S),
    P.

%% @private
derive_strategy(Uri) ->
    derive_strategy(Uri, [?EXACT_MATCH, ?WILDCARD_MATCH, ?PREFIX_MATCH]).

%% @private
derive_strategy(Uri, [H | T]) ->
    case bondy_wamp_uri:is_valid(Uri, H) of
        true ->
            H;
        false ->
            derive_strategy(Uri, T)
    end;
derive_strategy(_, []) ->
    error(
        bondy_error:new(missing_required_value, #{details => #{key => ~"match"}})
    ).

%% @private
inconsistency_error(Keys) ->
    error(bondy_error:from_term({inconsistency_error, Keys})).

%% @private
-doc "Grant permissions to one or more roles(".
-spec grant(
    RealmUri :: binary(),
    Arg :: all | [binary()],
    Resources :: [normalised_resource()],
    Permissions :: [binary()],
    Opts :: grant_opts()
) ->
    ok | {error, term()}.

grant(RealmUri, Keyword, Resources, Permissions, Opts) when
    Keyword == all orelse Keyword == anonymous
->
    do_grant([{Keyword, group}], RealmUri, Resources, Permissions, Opts);
grant(RealmUri, RoleList0, Resources, Permissions, Opts) ->
    {Anon, RoleList} = lists:splitwith(
        fun
            (anonymous) -> true;
            (<<"anonymous">>) -> true;
            (_) -> false
        end,
        RoleList0
    ),

    %% If anonymous was found in the list, add the grant for it
    _ =
        length(Anon) > 0 andalso
            grant(RealmUri, anonymous, Resources, Permissions, Opts),

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
            invalidate_sessions_on(
                do_grant(RoleTypes, RealmUri, Resources, Permissions, Opts),
                RealmUri
            );
        Error ->
            Error
    end.

%% @private
%% §9.5: a successful grant/revoke re-evaluates active local sessions in place
%% (no teardown) — each session's next authorize re-reads the subject's current
%% grants. Realm-wide because a group grant change affects every member; the
%% over-invalidation of unaffected sessions costs only a one-time rebuild.
invalidate_sessions_on(ok, RealmUri) ->
    bondy_session_manager:invalidate_rbac_all(RealmUri);
invalidate_sessions_on(Other, _RealmUri) ->
    Other.

%% @private
do_grant([], _, _, _, _) ->
    ok;
do_grant([{Rolename, RoleType} | T], RealmUri, Resources, Permissions0, Opts) ->
    Table = grant_table(RoleType),

    ok = lists:foreach(
        fun(Resource) ->
            Key = {Rolename, Resource},

            %% We store the list of permissions as the value
            Existing = bondy_stdlib:or_else(
                do_get(Table, RealmUri, Key),
                []
            ),

            %% We deduplicate
            Permissions1 = lists:umerge(
                lists:sort(Existing), lists:sort(Permissions0)
            ),

            %% We finally store the updated grant
            ok = store(Table, RealmUri, Key, Permissions1, Opts)
        end,
        Resources
    ),

    do_grant(T, RealmUri, Resources, Permissions0, Opts).

%% @private
%% A runtime grant is a plain lww set (dominates by HLC). A declarative config
%% apply (`declarative`) is IDEMPOTENT via `bondy_db:reconcile`: re-reading the same
%% config file on every boot emits no operation and never re-stamps the cell
%% with a fresh HLC — which would diverge cross-node convergence and make
%% peers ping-pong grant merges on every restart. The op-based CRDT +
%% anti-entropy reconcile multi-node grants, so no deterministic-version rebase
%% is needed here.
store(Table, RealmUri, {_Rolename, Resource} = Key, Permissions, Opts) ->
    %% The grant cell value is the fact map `#{resource, permissions}` (reshaped
    %% from the bare permissions list) so the `by_resource` reverse index can
    %% reach the resource column — it lives only in the key otherwise.
    Value = #{resource => Resource, permissions => Permissions},
    EncKey = encode_key(Key),
    %% `Opts` may be a map (`#{declarative => true}` from config apply) or a
    %% plain list (`[]` from the internal regrant path), so guard with `is_map/1`.
    case is_map(Opts) andalso maps:get(declarative, Opts, false) =:= true of
        true -> bondy_db:reconcile(Table, RealmUri, EncKey, Value);
        false -> bondy_db:apply(Table, RealmUri, EncKey, {set, Value})
    end.

-doc "Revoke permissions to one or more roles".
-spec revoke(
    RealmUri :: binary(),
    Roles :: all | [binary()],
    Resource :: [normalised_resource()],
    Permissions :: [uri()]
) -> ok | {error, term()}.

revoke(RealmUri, all, Resources, Permissions) ->
    %% all and anonymous are always valid
    invalidate_sessions_on(
        do_revoke([{all, group}], RealmUri, Resources, Permissions),
        RealmUri
    );
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
            invalidate_sessions_on(
                do_revoke(RoleTypes, RealmUri, Resources, Permissions),
                RealmUri
            );
        Error ->
            Error
    end.

do_revoke([], _, _, _) ->
    ok;
do_revoke([{Rolename, RoleType} | Roles], RealmUri, Resources, Permissions) ->
    Table = grant_table(RoleType),

    ok = lists:foreach(
        fun(Resource) ->
            Key = {Rolename, Resource},
            %% check if there is currently a GRANT we can revoke
            case do_get(Table, RealmUri, Key) of
                undefined ->
                    %% can't REVOKE what wasn't GRANTED
                    ok;
                GrantedPerms ->
                    NewPerms = [
                        X
                     || X <- GrantedPerms, not lists:member(X, Permissions)
                    ],

                    case NewPerms of
                        [] ->
                            bondy_db:apply(
                                Table, RealmUri, encode_key(Key), clear
                            );
                        _ ->
                            %% Through `store/5` so the value is the fact map.
                            store(Table, RealmUri, Key, NewPerms, [])
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
acc_grants([Rolename | Rolenames], Type, RealmProto, Seen, Acc) ->
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
    acc_grants(Rolenames, Type, RealmProto, NewSeen, [Grants | NewAcc]).

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

%% @private
-doc """
We return the groups this role is a member of. If the groups does not
exist we try fetching from the prototype if it exists.
Returns qualified group names e.g. {Name, Uri} where Uri can be the Realm's
or its prototype.
""".
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
        {ok, User} ->
            bondy_rbac_user:groups(User);
        {error, not_found} ->
            []
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
find_grants(Realm, {Rolename, '_'}, Type, _Opts) ->
    %% The match is always on the `Rolename` (the `Resource` component is a
    %% wildcard) and the composite key is order-preserving on the role column, so
    %% this is a bounded role-band range scan — `O(grants-for-role)`. Every row in
    %% the band is one of `Rolename`'s grants; a non-matching value (a cleared
    %% cell) simply fails the generator pattern and is skipped.
    Table = grant_table(Type),
    {Lo, Hi} = bondy_oplog_index_key:col_bounds(Rolename),
    {ok, Rows} = bondy_db:range_all(Table, Realm, Lo, Hi, #{}),
    grant_rows(Rows);
find_grants(Realm, '_', Type, _Opts) ->
    %% Whole-realm enumeration (`grants/2`, an admin "list all grants" call):
    %% inherently `O(realm)`, no role to bound it by, and off the authz hot path.
    Table = grant_table(Type),
    {ok, Rows} = bondy_db:list(Table, Realm),
    grant_rows(Rows).

%% @private
%% Decode the fact-map rows of a grant scan into `{{Rolename, Resource}, Perms}`;
%% the `#{permissions := _}` generator pattern skips cleared (non-map) cells.
grant_rows(Rows) ->
    [
        {decode_key(EncKey), Permissions}
     || {EncKey, #{permissions := Permissions}, _Hlc} <- Rows
    ].

%% @private
concat_role(user, Name) ->
    <<"user/", Name/binary>>;
concat_role(group, all) ->
    <<"group/all">>;
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

%% =============================================================================
%% PRIVATE: STORAGE
%% =============================================================================

%% @private
%% Resolves the open bondy_db grant table for a role type. Raises if the
%% catalogue has not provisioned it yet.
grant_table(user) ->
    grant_table(?BONDY_DB_USER_GRANT_TAB);
grant_table(group) ->
    grant_table(?BONDY_DB_GROUP_GRANT_TAB);
grant_table(EntityType) ->
    case bondy_namespace_catalog:table(EntityType) of
        undefined ->
            error(security_grants_table_unavailable);
        Table ->
            Table
    end.

%% @private
%% Reads the permissions list for a grant key, or `undefined`. The stored value
%% is the fact map `#{resource, permissions}`; a cleared cell reads back as
%% `not_found` and is reported the same way as one that never existed.
do_get(Table, RealmUri, Key) ->
    case bondy_db:read(Table, RealmUri, encode_key(Key)) of
        {ok, {#{permissions := Permissions}, _Hlc}} ->
            Permissions;
        {ok, {_Other, _Hlc}} ->
            undefined;
        {error, not_found} ->
            undefined
    end.

%% @private
%% Clears every grant for `Rolename` within the realm. The role band
%% (`col_bounds/1`) selects exactly that role's grants, so the scan is bounded
%% to `O(grants-for-role)` — no full-realm decode-and-filter.
revoke_role_grants(Table, RealmUri, Rolename) ->
    {Lo, Hi} = bondy_oplog_index_key:col_bounds(Rolename),
    {ok, Rows} = bondy_db:range_all(Table, RealmUri, Lo, Hi, #{}),
    _ = [
        bondy_db:apply(Table, RealmUri, EncKey, clear)
     || {EncKey, _V, _Hlc} <- Rows
    ],
    ok.

%% @private
%% Clears every grant in the realm's table.
clear_all_grants(Table, RealmUri) ->
    {ok, Rows} = bondy_db:list(Table, RealmUri),
    _ = [
        bondy_db:apply(Table, RealmUri, EncKey, clear)
     || {EncKey, _V, _Hlc} <- Rows
    ],
    ok.

%% The grant store key is the compound `{Rolename, Resource}`, encoded as an
%% order-preserving composite: the role as a type-tagged leading column
%% (`encode_col/1`, so the reserved atoms `all`/`anonymous` and binary rolenames
%% coexist), a `0x00` separator, then the canonical `term_to_binary` of the
%% resource (`any | {Uri, Strategy}`). The role column is `0x00`-free, so every
%% grant for a role is a contiguous band (`col_bounds(Rolename)`) and the forward
%% "grants for role" query is a bounded range scan, not a full-realm filter.
%%
%% Exported so the legacy-backup import translator encodes keys byte-identically
%% to the live write path; not part of the module's public surface.
-doc false.
encode_key({Rolename, Resource}) ->
    <<
        (bondy_oplog_index_key:encode_col(Rolename))/binary,
        0,
        (term_to_binary(Resource, [deterministic]))/binary
    >>.

%% @private
%% Inverse of `encode_key/1`: split at the single `0x00` separator (the role
%% column is `0x00`-free), decode the role column, then `[safe]`-decode the
%% resource (its atoms — `any` — already exist).
decode_key(Bin) when is_binary(Bin) ->
    {ColBin, ResBin} = split_key(Bin),
    {bondy_oplog_index_key:decode_col(ColBin), binary_to_term(ResBin, [safe])}.

%% @private
split_key(Bin) ->
    case binary:match(Bin, <<0>>) of
        {Pos, 1} ->
            Col = binary:part(Bin, 0, Pos),
            Rest = binary:part(Bin, Pos + 1, byte_size(Bin) - Pos - 1),
            {Col, Rest};
        nomatch ->
            error({badarg, Bin})
    end.

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
