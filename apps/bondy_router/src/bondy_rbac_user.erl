%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rbac_user).
-moduledoc """
Users: the identities that can log into a realm, and their group memberships.

A user is a role with credentials — a password, authorized keys, or neither —
plus client-supplied metadata. Users are named by a casefolded `username` that
is unique within a realm, and may carry aliases: additional names that resolve
to the same user at authentication.

**A user record does not list its groups.** Membership is a relation of its own,
`security_group_members`, and this module owns both sides of it: the primitives
that read and write the relation live here, and every write path that accepts a
`groups` field reconciles the relation to match. `groups/1` on a record read
through `lookup/2` reports what the relation says, not what was persisted in the
cell.

A user may be backed by a **single sign-on realm**. Such a user's credentials
live in the SSO realm and their local record carries `sso_realm_uri`;
`resolve/2`
merges the two into the view authentication uses. This is why several functions
take an authentication realm distinct from the realm being operated on.

Start from `new/2` and `add/3` to create a user, `lookup/2` to read one,
`add_group/3` and `remove_group/3` to change memberships, and
`change_password/4`
for credentials.

## Storage

Each user is one cell of the durable `security_users` table, banded by realm and
keyed by username; each alias is a second cell in the same table, keyed by the
alias and pointing at the username. Only one writer maintains that split — every
path that persists a user record goes through this module.

The cell's version is the user's `token_version/2`, which authentication uses as
a revocation stamp: any change to the record, including a change of group
membership, moves it forward and invalidates tokens issued before it.

Deleting or changing a user has consequences beyond the cell. Locally, deletion
revokes the user's tickets and tokens, closes their sessions, and retracts every
membership fact; a credential change closes their sessions. When a peer's write
arrives by anti-entropy, the merge-side reactor applies the same session closes
on this node — a delete closing sessions with `bondy.user.deleted`, a credential
change with `bondy.user.credentials_changed`.
""".
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").
-include("bondy_db_tables.hrl").

-define(MAX_ALIASES, 5).
-define(ALIAS_TYPE, alias).
-define(IS_ALIAS(X), ?ALIAS_TYPE =:= map_get(type, X)).
-define(USER_TYPE, user).
-define(IS_USER(X), ?USER_TYPE =:= map_get(type, X)).
-define(VERSION, <<"1.1">>).

-define(VALIDATOR, begin
    ?OPTS_VALIDATOR
end#{
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

-define(UPDATE_VALIDATOR, begin
    ?OPTS_VALIDATOR
end#{
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

%% Membership is stored in the cell-per-fact `security_group_members` relation
%% (NOT in the user cell). Each `(user, group)` fact is an enable-wins presence
%% cell written in BOTH key orderings so each direction is a bounded key-range
%% scan (the permutation-index pattern, design §11): a forward `f` band keyed
%% `enc(user) ⊕ enc(group)` for "groups of a user", and a reverse `r` band keyed
%% `enc(group) ⊕ enc(user)` for "members of a group". The realm is folded into
%% the cell key by the facade (G-1), so reads address `(Table, RealmUri, Key)`.
-define(MEMBER_FWD, <<"f">>).
-define(MEMBER_REV, <<"r">>).

%% Internal page size for the bounded member fold / drain over the reverse band.
-define(MEMBER_PAGE, 1000).

-type t() :: #{
    type := ?USER_TYPE,
    version := binary(),
    username := username(),
    groups := [binary()],
    password => bondy_password:future() | bondy_password:t(),
    authorized_keys => [binary()],
    sso_realm_uri => optional(uri()),
    meta => #{binary() => any()},
    %% Transient, will not be stored
    password_opts => bondy_password:opts()
}.

% -type alias()    ::  #{
%     type                :=  ?ALIAS_TYPE,
%     alias               :=  username(),
%     username            :=  username()
% }.

-type external() :: #{
    type := ?USER_TYPE,
    version := binary(),
    username := username_int(),
    groups := [binary()],
    has_password := boolean(),
    has_authorized_keys := boolean(),
    authorized_keys => [binary()],
    sso_realm_uri => optional(uri()),
    meta => #{binary() => any()}
}.

-type username() :: binary().
-type username_int() :: username() | anonymous.
-type new_opts() :: #{
    password_opts => bondy_password:opts()
}.
-type add_opts() :: #{
    password_opts => bondy_password:opts(),
    %% `true` when applying declarative config (idempotent write, no lifecycle
    %% side-effects) — see `bondy_realm:apply_config/0`.
    declarative => boolean(),
    actor_id => term(),
    if_exists => fail | update
}.
-type update_opts() :: #{
    update_credentials => boolean(),
    password_opts => bondy_password:opts(),
    %% `true` when applying declarative config (idempotent write, no lifecycle
    %% side-effects) — see `bondy_realm:apply_config/0`. `store/3` honours it on
    %% the update path as it does on the add path.
    declarative => boolean()
}.
-type list_opts() :: #{
    limit => pos_integer(),
    cursor => bondy_relation:cursor(),
    mode => bondy_relation:mode()
}.
-type add_error() ::
    {no_such_realm, uri()}
    | reserved_name
    | already_exists.
-type update_error() ::
    reserved_name
    | {no_such_realm, uri()}
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
-export([change_password/3]).
-export([change_password/4]).
-export([close_sessions/3]).
-export([disable/2]).
-export([enable/2]).
-export([exists/2]).
-export([fetch/2]).
-export([from_term/1]).
-export([import_legacy/3]).
-export([groups/1]).
-export([has_authorized_keys/1]).
-export([has_password/1]).
-export([is_enabled/1]).
-export([is_enabled/2]).
-export([is_member/2]).
-export([is_sso_user/1]).
-export([list/1]).
-export([list/2]).
-export([list_members/3]).
-export([lookup/2]).
-export([lookup/3]).
-export([meta/1]).
-export([new/1]).
-export([new/2]).
-export([normalise_username/1]).
-export([password/1]).
-export([remove/2]).
-export([remove/3]).
-export([remove_alias/3]).
-export([remove_all/2]).
-export([remove_group/3]).
-export([remove_group_from_members/2]).
-export([remove_groups/3]).
-export([resolve/1]).
-export([resolve/2]).
-export([sso_realm_uri/1]).
-export([to_external/1]).
-export([token_version/2]).
-export([unknown/2]).
-export([update/3]).
-export([update/4]).
-export([username/1]).

%% TODO new API
%% -export([add_authorized_key/2]).
%% -export([remove_authorized_key/2]).
%% -export([is_authorized_key/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Returns a validated user built from `Data`. Equivalent to `new/2` with
default options.
""".
-spec new(Data :: map()) -> User :: t().

new(Data) ->
    new(Data, #{}).

-doc """
Returns a validated user built from `Data`.

`username` is required and is casefolded. A `password` in `Data` is hashed here,
under `Opts`' password options or the realm's, so the returned record carries
credential material rather than a plaintext secret. Raises on invalid input.

The result is not persisted, and its `groups` are a request rather than a fact
until `add/3` reconciles them into the membership relation.
""".
-spec new(Data :: map(), Opts :: new_opts()) -> User :: t().

new(Data, Opts) ->
    User = type_and_version(?USER_TYPE, maps_utils:validate(Data, ?VALIDATOR)),
    maybe_apply_password(User, Opts).

-doc "Returns the group names the user's username.".
username(#{type := ?USER_TYPE, username := Val}) -> Val.

-doc "Returns the group names the user `User` is member of.".
groups(#{type := ?USER_TYPE, groups := Val}) -> Val.

-doc """
Returns `true` if user `User` is a member of the group named
`Name`. Otherwise returns `false`.
""".
-spec is_member(Name0 :: bondy_rbac_group:name(), User :: t()) -> boolean().

is_member(Name0, #{type := ?USER_TYPE, groups := Val}) ->
    Name = bondy_rbac_group:normalise_name(Name0),
    Name == all orelse lists:member(Name, Val).

-doc """
Returns `true` if user `User` is managed in a SSO Realm, `false` if it
is locally managed.
""".
-spec is_sso_user(User :: t()) -> boolean().

is_sso_user(#{type := ?USER_TYPE, sso_realm_uri := Val}) when is_binary(Val) ->
    true;
is_sso_user(#{type := ?USER_TYPE}) ->
    false.

-doc """
Returns the URI of the Same Sign-on Realm in case the user is a SSO
user. Otherwise, returns `undefined`.
""".
-spec sso_realm_uri(User :: t()) -> optional(uri()).

sso_realm_uri(#{type := ?USER_TYPE, sso_realm_uri := Val}) when
    is_binary(Val)
->
    Val;
sso_realm_uri(#{type := ?USER_TYPE}) ->
    undefined.

-doc """
Returns `true` if user `User` is active. Otherwise returns `false`.
A user that is not active cannot establish a session.
See `enable/3` and `disable/3`.
""".
-spec is_enabled(User :: t()) -> boolean().

is_enabled(#{type := ?USER_TYPE, enabled := Val}) ->
    Val;
is_enabled(#{type := ?USER_TYPE}) ->
    true.

-doc """
Returns `true` if user identified with `Username` is enabled. Otherwise
returns `false`.
A user that is not enabled cannot establish a session.
See `enable/2` and `disable/3`.
""".
-spec is_enabled(RealmUri :: uri(), Username :: username_int()) -> boolean().

is_enabled(RealmUri, Username) ->
    is_enabled(fetch(RealmUri, Username)).

-doc """
If the user `User` is not sso-managed, returns `User` unmodified.
Otherwise, fetches the user's credentials, the enabled status and additional
metadata from the SSO Realm and merges it into `User` using the following
procedure:

- Copies the `password` and `authorized_keys` from the SSO user into `User`.
- Adds the `meta` contents from the SSO user to a key names `sso` to the
`User` `meta` map.
- Sets the `enabled` property by performing the conjunction (logical AND) of
both user records.

The call fails with an exception if the SSO user associated with `User` was
not found.
""".
-spec resolve(User :: t()) -> Resolved :: t() | no_return().

resolve(#{type := ?USER_TYPE, sso_realm_uri := Uri} = User) when
    is_binary(Uri)
->
    SSOUser = fetch(Uri, maps:get(username, User)),
    resolve(User, SSOUser);
resolve(#{type := ?USER_TYPE} = User) ->
    User.

-doc """
Returns `User` with the credentials of `SSOUser` merged in — the view
authentication uses for an SSO-backed user.

The local record supplies identity and metadata, the SSO record supplies the
password and authorized keys. Use this form when the SSO user has already been
read; `resolve/1` reads it.
""".
-spec resolve(User :: t(), SSOUser :: t()) -> Resolved :: t() | no_return().

resolve(LocalUser, SSOUser) ->
    User1 = maps:merge(
        LocalUser,
        maps:with([password, authorized_keys], SSOUser)
    ),

    User2 =
        case maps:find(meta, SSOUser) of
            {ok, Meta} ->
                maps_utils:put_path([meta, sso], Meta, User1);
            error ->
                User1
        end,

    Enabled =
        maps:get(enabled, SSOUser, true) andalso
            maps:get(enabled, LocalUser, true),

    maps:put(enabled, Enabled, User2).

-doc "Returns `true` if user `User` has a password. Otherwise returns `false`.".
-spec has_password(User :: t()) -> boolean().

has_password(#{type := ?USER_TYPE} = User) ->
    maps:is_key(password, User).

-doc """
Returns the password object or `undefined` if the user does not have a
password. See `bondy_password`.
""".
-spec password(User :: t()) ->
    optional(bondy_password:future() | bondy_password:t()).

password(#{type := ?USER_TYPE, password := Future}) when
    is_function(Future, 1)
->
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

-doc """
Returns `true` if user `User` has authorized keys.
Otherwise returns `false`.
See `authorized_keys/1`.
""".
-spec has_authorized_keys(User :: t()) -> boolean().

has_authorized_keys(#{type := ?USER_TYPE, authorized_keys := Val}) ->
    length(Val) > 0;
has_authorized_keys(#{type := ?USER_TYPE}) ->
    false.

-doc """
Returns the list of authorized keys for this user. These keys are used
with the WAMP Cryptosign authentication method or equivalent.
""".
authorized_keys(#{type := ?USER_TYPE, authorized_keys := Val}) ->
    Val;
authorized_keys(#{type := ?USER_TYPE}) ->
    [].

-doc "Returns the metadata map associated with the user `User`.".
-spec meta(User :: t()) -> map().

meta(#{type := ?USER_TYPE, meta := Val}) -> Val.

-doc """
Adds a new user to the RBAC store. `User` MUST have been
created using `new/1` or `new/2`.
This record is globally replicated.

The call returns an error if the username is already associated with another
user. Notice that this check is currently performed locally only, this means
that a concurrent add on another node will succeed unless this operation
broadcast arrives first. To ensure uniqueness the caller could use a strong
consistency service e.g. a database with ACID guarantees, or act as a
singleton serializing this call.
""".
-spec add(uri(), t()) -> {ok, t()} | {error, add_error()}.

add(RealmUri, User) ->
    add(RealmUri, User, #{}).

-doc """
Adds a new user to the RBAC store. `User` MUST have been
created using `new/1` or `new/2`.
This record is globally replicated.

The call returns an error if the username is already associated with another
user. Notice that this check is currently performed locally only, this means
that a concurrent add on another node will succeed unless this operation
broadcast arrives first. To ensure uniqueness the caller could use a strong
consistency service e.g. a database with ACID guarantees, or act as a
singleton serializing this call.
""".
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

-doc """
Updates an existing user.
This change is globally replicated.
""".
-spec update(RealmUri :: uri(), Arg :: username() | t(), Data :: map()) ->
    {ok, NewUser :: t()} | {error, update_error()}.

update(RealmUri, Arg, Data) ->
    update(RealmUri, Arg, Data, #{}).

-doc """
Updates an existing user.
This change is globally replicated.
""".
-spec update(
    RealmUri :: uri(),
    Arg :: username() | t(),
    Data :: map(),
    Opts :: update_opts()
) ->
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

-doc """
Removes user `Arg` from `RealmUri`. Equivalent to `remove/3` with default
options.
""".
-spec remove(RealmUri :: uri(), Arg :: username() | t()) ->
    ok | {error, {no_such_user, username()} | reserved_name}.

remove(RealmUri, Arg) ->
    remove(RealmUri, Arg, #{}).

-doc """
Removes a user from `RealmUri` together with everything keyed by their name:
aliases, sources, grants, group memberships, tickets and OAuth tokens.

The name is left free, and a user created under it afterwards inherits none of
this. Local sessions for the user are closed with `bondy.user.deleted`.

Returns `{error, {no_such_user, Username}}` when there is no such user and
`{error, reserved_name}` for a reserved one.
""".
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
        Table = table(),

        %% We remove all aliases (if it has any)
        _ = [bondy_db:apply(Table, RealmUri, Alias, clear) || Alias <- Aliases],

        %% We remove this user from sources
        ok = bondy_rbac_source:remove_all(RealmUri, Username),

        %% delete any associated grants, so if a user with the same name
        %% is added again, it doesn't pick up these grants
        ok = bondy_rbac:revoke_user(RealmUri, Username),

        %% Delete the user last: the cleanup above reads the record.
        ok = bondy_db:apply(Table, RealmUri, Username, clear),
        do_on_delete(RealmUri, Username)
    catch
        error:{no_such_user, _} = Reason ->
            {error, Reason};
        throw:Reason ->
            {error, Reason}
    end;
remove(_, anonymous, _) ->
    {error, reserved_name}.

-doc """
Removes all users that belongs to realm `RealmUri`.
If the option `dirty` is set to `true` this removes the user directly from
store. If set to `false` (the default) then for each user the function remove/2
is called.

Use `dirty` with a value of `true` only when you are removing the realm
entirely.
""".
-spec remove_all(uri(), #{dirty => boolean()}) -> ok.

remove_all(RealmUri, Opts) ->
    Dirty = maps:get(dirty, Opts, false),
    Table = table(),
    %% Stream every cell (user records AND alias-pointer cells) through a
    %% bounded keyset fold instead of materialising the whole realm. Deleting
    %% behind a forward keyset cursor is safe — cleared cells simply drop out
    %% of the next page.
    {ok, ok} = bondy_relation:fold(
        raw_relation(Table),
        RealmUri,
        fun({Key, V}, ok) ->
            _ =
                case {Dirty, ?IS_USER(V)} of
                    {true, true} ->
                        %% Realm teardown: clear the cell and fire the same
                        %% per-user delete side-effects `remove/3` fires.
                        ok = bondy_db:apply(Table, RealmUri, Key, clear),
                        do_on_delete(RealmUri, Key);
                    {true, false} ->
                        %% Alias cell — clear it; no lifecycle side-effects.
                        bondy_db:apply(Table, RealmUri, Key, clear);
                    {false, true} ->
                        %% Route user records through remove/3 (which also
                        %% clears their aliases, sources and grants).
                        remove(RealmUri, Key, Opts);
                    {false, false} ->
                        %% Alias cell — removed as part of its user's removal.
                        ok
                end,
            ok
        end,
        ok
    ),
    ok.

-doc """
Returns the user named `Username` in `RealmUri`, resolving an alias to the user
it points at.

The returned record's `groups` come from the membership relation rather than
from the stored cell. Credentials are the local record's; for an SSO-backed user
they live in the SSO realm, so use `resolve/2` when the authentication view is
what is wanted.
""".
-spec lookup(RealmUri :: uri(), Username :: username_int()) ->
    {ok, t()} | {error, not_found}.

lookup(RealmUri, Username0) ->
    case normalise_username(Username0) of
        anonymous ->
            {ok, ?ANONYMOUS};
        Username ->
            case do_get(RealmUri, Username) of
                undefined ->
                    {error, not_found};
                Val0 when ?IS_ALIAS(Val0) ->
                    case lookup(RealmUri, maps:get(username, Val0)) of
                        {ok, Val1} when ?IS_USER(Val1) ->
                            {ok, Val1};
                        {ok, Val1} when ?IS_ALIAS(Val1) ->
                            ?LOG_WARNING(#{
                                description => "Recursive index for user alias",
                                alias => Val0
                            }),
                            {error, not_found};
                        {ok, Val1} ->
                            {ok, from_term({Username, Val1})};
                        {error, _} = Error ->
                            Error
                    end;
                Val0 ->
                    {ok,
                        with_groups(
                            RealmUri, Username, from_term({Username, Val0})
                        )}
            end
    end.

-doc """
Looks up a user in `RealmUri`, resolving SSO aliases through `SSORealmUri`.

Behaves like `lookup/2` when the name is a username of `RealmUri`. Otherwise,
and provided `SSORealmUri` is not `undefined`, the SSO realm is consulted to
map an alias onto a username — which must then still exist in `RealmUri`. An
SSO realm can name a user, but it cannot by itself grant access to a realm the
user is not a member of.

The user returned is the merge of the local and SSO records (see `resolve/2`),
and every record consulted must be enabled.

This is the single definition of "which user is this name, in this realm",
shared by the WAMP session path (`bondy_auth`) and by credential verification
outside a handshake (`bondy_http_verify_handler`), so that the two cannot drift
apart on who they consider a valid principal.
""".
-spec lookup(
    RealmUri :: uri(),
    SSORealmUri :: optional(uri()),
    UsernameOrAlias :: username_int()
) ->
    {ok, t()} | {error, not_found | user_disabled}.

lookup(RealmUri, SSORealmUri, UsernameOrAlias) ->
    case lookup(RealmUri, UsernameOrAlias) of
        {ok, User} ->
            case is_enabled(User) of
                true ->
                    %% Merge in the SSO record (if any) so the caller gets the
                    %% credentials, which live on the SSO user.
                    {ok, resolve(User)};
                false ->
                    {error, user_disabled}
            end;
        {error, not_found} when SSORealmUri == undefined ->
            {error, not_found};
        {error, not_found} ->
            resolve_alias(RealmUri, SSORealmUri, UsernameOrAlias)
    end.

-doc "Whether `RealmUri` has a user or alias named `Username`.".
-spec exists(RealmUri :: uri(), Username :: username_int()) -> boolean().

exists(RealmUri, Username0) ->
    resulto:is_ok(lookup(RealmUri, Username0)).

-doc """
Returns the user named `Username` in `RealmUri`, raising `{no_such_user, _}`
when there is none. The raising counterpart of `lookup/2`.
""".
-spec fetch(uri(), username_int()) -> t() | no_return().

fetch(RealmUri, Username) ->
    case lookup(RealmUri, Username) of
        {ok, User} ->
            User;
        {error, not_found} ->
            error({no_such_user, Username})
    end.

-doc """
Returns the current `token_version` for `Username` in realm `RealmUri`.

The token version is the **HLC of the user's cell** — a monotonic,
concurrency-safe version that advances on every write to the user record
(disable/enable, password change, group membership, authorized keys). It is
Bondy's revocation **zookie** (`STORAGE_ARCHITECTURE` §9.3): a token embeds the
version observed at issue time, and the auth path refuses a token whose embedded
version is older than the user cell's current version, forcing
re-authentication.

Grant/source changes do NOT advance it — those cells are separate from the user
cell, and their cross-node freshness is enforced by the AE fence instead (option
(c). The anonymous user has no stored cell and no revocable
tokens, so it reports a stable sentinel of `0`. Aliases resolve to the canonical
user's version.
""".
-spec token_version(RealmUri :: uri(), Username :: username_int()) ->
    {ok, bondy_oplog_hlc:hlc()} | {error, not_found}.

token_version(RealmUri, Username0) ->
    case normalise_username(Username0) of
        anonymous ->
            {ok, 0};
        Username ->
            case bondy_db:read(table(), RealmUri, Username) of
                {ok, {Value, _Hlc}} when ?IS_ALIAS(Value) ->
                    token_version(RealmUri, maps:get(username, Value));
                {ok, {_Value, Hlc}} ->
                    {ok, Hlc};
                {error, not_found} ->
                    {error, not_found}
            end
    end.

-doc "Returns every user of `RealmUri`. Equivalent to `list/2` with no limit.".
-spec list(uri()) -> list(t()).

list(RealmUri) ->
    list(RealmUri, #{}).

-doc """
Returns a page of the users of `RealmUri`, together with their group
memberships.

Without a `limit` the whole realm is returned, streamed rather than materialised
as raw cells, and memberships are joined from one scan of the realm's membership
band. With a `limit`, returns `{Users, Continuation}`; pass the continuation
back as `cursor` for the next page.
""".
-spec list(RealmUri :: uri(), Opts :: list_opts()) ->
    [t()]
    | {[t()], Continuation :: bondy_relation:cursor() | undefined}.

list(RealmUri, Opts) ->
    %% `mode` (`partition` default | `global`) selects how a bounded page is
    %% assembled — see `relation/0`. It only affects the keyset (limit) branch;
    %% the whole-realm fold is order-agnostic.
    Mode = maps_utils:get_any([mode, <<"mode">>], Opts, partition),
    Relation = relation(Mode),
    case maps_utils:get_any([limit, <<"limit">>], Opts, undefined) of
        undefined ->
            %% Whole-realm listing — streamed through a bounded keyset fold so
            %% it never materialises the raw cell set (the prior `bondy_db:list`
            %% + `lists:sublist` could OOM a large realm). Membership is joined
            %% from ONE scan of the realm's forward membership band (rather than
            %% a per-user scan) since the whole realm is materialised anyway.
            {ok, Acc} = bondy_relation:fold(
                Relation, RealmUri, fun(User, A) -> [User | A] end, []
            ),
            GMap = all_member_groups(RealmUri),
            [join_groups(GMap, User) || User <- lists:reverse(Acc)];
        Limit ->
            %% Keyset page — `Cursor` resumes a prior page (the `Continuation`
            %% returned here), `undefined` is the first page.
            Cursor = maps_utils:get_any(
                [cursor, <<"cursor">>], Opts, undefined
            ),
            PageOpts0 = #{limit => Limit},
            PageOpts =
                case Cursor of
                    undefined -> PageOpts0;
                    _ -> PageOpts0#{cursor => Cursor}
                end,
            {ok, #{values := Users, next := Next}} =
                bondy_relation:list(Relation, RealmUri, PageOpts),
            %% Join groups for the WHOLE page in ONE bounded forward-band scan.
            %% The page's usernames are ascending, so their membership cells
            %% occupy the contiguous band «FWD,first»..«FWD,last». The previous
            %% `with_groups/2`-per-user form did a cross-shard scatter PER user,
            %% so a 100-row page cost ~100 scatters (seconds).
            GMap = page_member_groups(RealmUri, Users),
            {[join_groups(GMap, U) || U <- Users], Next}
    end.

-doc """
Lists the usernames of the members of group `Groupname` in realm
`RealmUri`, paginated.

This is the reverse membership access path — the `member` relation read by
group. It answers "which users are in group G" with a bounded ascending scan
of the group's reverse membership band (`enc(group) ⊕ enc(user)`) in
`security_group_members`, bounded to `RealmUri`, instead of scanning the
realm's users. `Opts` carries `limit` (page size, default `1000`) and
`cursor` (a username returned as the previous page's continuation, or
absent for the first page). Returns `{Usernames, Continuation}` where
`Continuation` is the last returned username when more pages remain, or
`undefined` at the end.

The scan reads the synchronously-applied relation, so a just-committed
membership is visible immediately (read-your-writes); retracted memberships
(disabled presence cells) are skipped.
""".
-spec list_members(
    RealmUri :: uri(),
    Groupname :: bondy_rbac_group:name(),
    Opts :: map()
) ->
    {[username()], Continuation :: username() | undefined}.

list_members(RealmUri, Groupname, Opts) ->
    Group = bondy_rbac_group:normalise_name(Groupname),
    Limit = maps_utils:get_any([limit, <<"limit">>], Opts, ?MEMBER_PAGE),
    After = maps_utils:get_any([cursor, <<"cursor">>], Opts, undefined),
    %% Fetch limit+1 to learn whether another page exists without a count.
    Users = members_page(RealmUri, Group, After, Limit + 1),
    case length(Users) > Limit of
        true ->
            Page = lists:sublist(Users, Limit),
            {Page, lists:last(Page)};
        false ->
            {Users, undefined}
    end.

-doc """
Sets the password of `Username` in `RealmUri` without requiring the current one.
The administrative form; `change_password/4` is the user-initiated one.
""".
-spec change_password(
    RealmUri :: uri(),
    Username :: username(),
    New :: binary()
) -> ok | {error, any()}.

change_password(RealmUri, Username, New) ->
    change_password(RealmUri, Username, New, undefined).

-doc """
Replaces the password of `Username` in `RealmUri`, requiring `Old` to match the
current one. Pass `undefined` for `Old` to set it administratively.

For an SSO-backed user the password lives in the SSO realm and is changed there.
The change closes the user's other sessions and moves their `token_version/2`
forward, so tokens issued under the old password stop authenticating.
""".
-spec change_password(
    RealmUri :: uri(),
    Username :: username(),
    New :: binary(),
    Old :: binary() | undefined
) -> ok | {error, any()}.

change_password(RealmUri, Username, New, Old) ->
    case lookup(RealmUri, Username) of
        {ok, #{} = User} ->
            do_change_password(RealmUri, resolve(User), New, Old);
        {error, not_found} = Error ->
            Error
    end.

-doc """
Sets the value of the `enabled` property to `true`.
See `is_enabled/2`.
""".
-spec enable(RealmUri :: uri(), Arg :: t() | username()) ->
    ok | {error, any()}.

enable(RealmUri, Arg) ->
    case update(RealmUri, Arg, #{enabled => true}) of
        {ok, _} ->
            ok;
        Error ->
            Error
    end.

-doc """
Sets the value of the `enabled` property to `false`.
See `is_enabled/2`.
""".
-spec disable(RealmUri :: uri(), Arg :: t() | binary()) ->
    ok | {error, any()}.

disable(RealmUri, Arg) ->
    case update(RealmUri, Arg, #{enabled => false}) of
        {ok, _} ->
            ok;
        Error ->
            Error
    end.

-doc "Returns the external representation of the user `User`.".
-spec to_external(User :: t()) -> external().

to_external(#{type := ?USER_TYPE, version := ?VERSION} = User) ->
    Keys = maps:get(authorized_keys, User, []),
    Map = maps:without([password, authorized_keys], User),

    Map#{
        authorized_keys => [
            list_to_binary(hex_utils:bin_to_hexstr(Key))
         || Key <- Keys
        ],
        has_password => has_password(User),
        has_authorized_keys => has_authorized_keys(User)
    }.

-doc """
Adds an alias to the user. If the user is an SSO user, the alias is
added on the SSO Realm only.
""".
-spec add_alias(
    RealmUri :: uri(), User :: t() | username(), Alias :: username()
) ->
    ok | {error, Reason :: any()}.

add_alias(
    _, #{type := ?USER_TYPE, sso_realm_uri := RealmUri} = User, Alias
) when
    is_binary(RealmUri)
->
    Username = maps:get(username, User),
    do_add_alias(RealmUri, fetch(RealmUri, Username), Alias);
add_alias(RealmUri, #{type := ?USER_TYPE} = User, Alias) ->
    do_add_alias(RealmUri, User, Alias);
add_alias(RealmUri, Username, Alias) ->
    add_alias(RealmUri, fetch(RealmUri, Username), Alias).

-doc """
Removes `Alias` from `User`, so the name no longer resolves to them and is free
for anyone else.

For an SSO-backed user the alias belongs to the SSO realm and is removed there.
Removing an alias the user does not hold succeeds.
""".
-spec remove_alias(
    RealmUri :: uri(), User :: t() | username(), Alias :: username()
) ->
    ok | {error, Reason :: any()}.

remove_alias(
    _, #{type := ?USER_TYPE, sso_realm_uri := RealmUri} = User, Alias
) when
    is_binary(RealmUri)
->
    Username = maps:get(username, User),
    remove_alias(RealmUri, Username, Alias);
remove_alias(RealmUri, #{type := ?USER_TYPE} = User, Alias) ->
    do_remove_alias(RealmUri, User, Alias);
remove_alias(RealmUri, Username, Alias) ->
    remove_alias(RealmUri, fetch(RealmUri, Username), Alias).

-doc """
Adds group named `Groupname` to users `Users` in realm with uri
`RealmUri`.
""".
-spec add_group(
    RealmUri :: uri(),
    Users :: all | t() | list(t()) | username() | list(username()),
    Groupname :: bondy_rbac_group:name()
) -> ok | {error, Reason :: any()}.

add_group(RealmUri, Users, Groupname) ->
    add_groups(RealmUri, Users, [Groupname]).

-doc """
Adds groups `Groupnames` to users `Users` in realm with uri
`RealmUri`.
""".
-spec add_groups(
    RealmUri :: uri(),
    Users :: all | t() | list(t()) | username() | list(username()),
    Groupnames :: [bondy_rbac_group:name()]
) -> ok | {error, Reason :: any()}.

add_groups(RealmUri, Users, Groupnames) ->
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

-doc """
Removes groups `Groupnames` from users `Users` in realm with uri
`RealmUri`.
""".
-spec remove_group(
    RealmUri :: uri(),
    Users :: all | t() | list(t()) | username() | list(username()),
    Groupname :: bondy_rbac_group:name()
) -> ok.

remove_group(RealmUri, Users, Groupname) ->
    remove_groups(RealmUri, Users, [Groupname]).

-doc """
Removes groups `Groupnames` from users `Users` in realm with uri
`RealmUri`.
""".
-spec remove_groups(
    RealmUri :: uri(),
    Users :: all | t() | list(t()) | username() | list(username()),
    Groupnames :: [bondy_rbac_group:name()]
) -> ok.

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

-doc """
Removes group `Groupname` from every user that is a member of it, in realm
`RealmUri`.

Drains the group's members via the `by_group` secondary index (the reverse
membership access path) instead of scanning every user in the realm — the
bounded replacement for `remove_group(RealmUri, all, Groupname)` on the
group-deletion path (O(members-of-G) rather than O(all-users)). The index
is flushed first (`bondy_db:await_index/2`) so the drain reflects every
committed membership and the cleanup is complete; a member whose record was
concurrently removed (a stale index entry) is skipped.
""".
-spec remove_group_from_members(
    RealmUri :: uri(),
    Groupname :: bondy_rbac_group:name()
) -> ok.

remove_group_from_members(RealmUri, Groupname) ->
    Group = bondy_rbac_group:normalise_name(Groupname),
    Fun = fun(Username, ok) ->
        case lookup(RealmUri, Username) of
            {ok, #{type := ?USER_TYPE} = User} ->
                %% `Group` is normalised so it matches the casefolded names
                %% stored in the membership relation.
                ok = remove_group(RealmUri, User, Group);
            {error, not_found} ->
                %% A dangling membership for an already-deleted user: its own
                %% deletion drops its membership cells, so nothing to do.
                ok
        end
    end,
    {ok, ok} = fold_members(RealmUri, Group, Fun, ok),
    ok.

-doc "Takes a list of usernames and returns any that can't be found.".
-spec unknown(RealmUri :: uri(), Usernames :: [username()]) ->
    Unknown :: [username()].

unknown(_, []) ->
    [];
unknown(RealmUri, Usernames) ->
    Set = ordsets:from_list(Usernames),
    ordsets:fold(
        fun
            (anonymous, Acc) ->
                Acc;
            (Username0, Acc) when is_binary(Username0) ->
                Username = normalise_username(Username0),
                case do_get(RealmUri, Username) of
                    undefined -> [Username | Acc];
                    _ -> Acc
                end
        end,
        [],
        Set
    ).

-doc """
Returns `Term` in the form usernames are stored in: casefolded, with the
reserved name `anonymous` as an atom whichever way it was written.

Every read and write path folds names this way, so a caller supplying a name
from outside Bondy should fold it here first. Raises `badarg` for anything that
is not a binary or the reserved name.
""".
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
%% The SSO realm is consulted with no SSO realm of its own, so this bottoms out
%% after one hop even when a realm is configured as its own SSO realm.
resolve_alias(RealmUri, SSORealmUri, Alias) ->
    case lookup(SSORealmUri, undefined, Alias) of
        {ok, SSOUser} ->
            case lookup(RealmUri, undefined, username(SSOUser)) of
                {ok, User} ->
                    %% Both records are already in hand, so merge them directly
                    %% rather than making `resolve/1` re-read the SSO user.
                    {ok, resolve(User, SSOUser)};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% =============================================================================
%% PRIVATE: STORAGE
%% =============================================================================

%% @private
%% The published `security_users` table handle, or an error when the catalogue
%% has not provisioned it yet.
table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_USER_TAB) of
        undefined -> error(security_users_table_unavailable);
        Table -> Table
    end.

%% @private
%% The `security_users` table as a paginatable relation of user records.
%% Alias-pointer cells co-located in the same table are rejected, so they never
%% surface in a user listing or `update_groups` fold.
%%
%% `partition` mode (the default): a page is served from ~1 user-table shard
%% rather than scattering across all of them. The group join (`page_member_groups/2`)
%% stays cheap because a user's forward membership cells co-locate on that same
%% shard (catalogue `aggregate_root => second_col`), so a partition page's join
%% is a single bounded shard scan — no need for the page to be globally ordered.
%% `global` mode (opt-in via `list/2`'s `mode` option) scatters every page and
%% returns it in global username order — slower, but alphabetical.
relation() ->
    relation(partition).

%% @private
relation(Mode) ->
    bondy_relation:new(?BONDY_DB_USER_TAB, #{
        table => table(),
        decode => fun decode_user_row/1,
        mode => Mode
    }).

%% @private
decode_user_row({Key, V, _Hlc}) when is_map(V) ->
    case ?IS_ALIAS(V) of
        true -> skip;
        false -> {ok, from_term({Key, V})}
    end;
decode_user_row(_) ->
    skip.

%% @private
%% Every cell of the user table (user records AND alias-pointer cells) as
%% `{Key, RawValue}` — for whole-table maintenance (`remove_all/2`) that must
%% visit and clear alias cells too.
raw_relation(Table) ->
    bondy_relation:new(?BONDY_DB_USER_TAB, #{
        table => Table,
        decode => fun decode_raw_row/1
    }).

%% @private
decode_raw_row({Key, V, _Hlc}) when is_map(V) ->
    {ok, {Key, V}};
decode_raw_row(_) ->
    skip.

%% =============================================================================
%% PRIVATE: MEMBERSHIP RELATION (security_group_members)
%% =============================================================================
%% Membership is cell-per-fact and add-wins: each `(user, group)` fact is an
%% `ew_flag` (enable-wins) presence cell, written in BOTH key orderings — a
%% forward `f` band (`enc(user) ⊕ enc(group)`) and a reverse `r` band
%% (`enc(group) ⊕ enc(user)`) — so each direction is a bounded, realm-local
%% key-range scan with no secondary index. A retract disables both cells; a
%% disabled cell reads as `false`, so the scans keep only the `true` (live)
%% ones.

%% @private
member_table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_GROUP_MEMBERS_TAB) of
        undefined -> error(security_group_members_table_unavailable);
        Table -> Table
    end.

%% @private
%% Cell keys: a band-tagged, order-preserving composite of the fact's columns.
mkey_fwd(Username, Group) ->
    bondy_oplog_index_key:encode_tuple([?MEMBER_FWD, Username, Group]).

mkey_rev(Group, Username) ->
    bondy_oplog_index_key:encode_tuple([?MEMBER_REV, Group, Username]).

%% @private
%% Half-open `[Lo, Hi)` band over all of one user's forward cells / one group's
%% reverse cells (the prefix `«tag, leading-col»` followed by the 0x00
%% separator that sorts below any continuation).
fwd_band(Username) ->
    P = bondy_oplog_index_key:encode_tuple([?MEMBER_FWD, Username]),
    {<<P/binary, 0>>, <<P/binary, 1>>}.

rev_band(Group) ->
    P = bondy_oplog_index_key:encode_tuple([?MEMBER_REV, Group]),
    {<<P/binary, 0>>, <<P/binary, 1>>}.

%% @private
%% The trailing column of a forward / reverse cell key.
fwd_group(Key) ->
    [_Tag, _User, Group] = bondy_oplog_index_key:decode_tuple(Key),
    Group.

rev_user(Key) ->
    [_Tag, _Group, User] = bondy_oplog_index_key:decode_tuple(Key),
    User.

%% @private
%% Assert / retract one membership fact in both key orderings (add-wins: an
%% `enable` survives a concurrent `disable` that did not observe it).
member_assert(RealmUri, Username, Group) ->
    Table = member_table(),
    ok = bondy_db:apply(Table, RealmUri, mkey_fwd(Username, Group), enable),
    ok = bondy_db:apply(Table, RealmUri, mkey_rev(Group, Username), enable).

member_retract(RealmUri, Username, Group) ->
    Table = member_table(),
    ok = bondy_db:apply(Table, RealmUri, mkey_fwd(Username, Group), disable),
    ok = bondy_db:apply(Table, RealmUri, mkey_rev(Group, Username), disable).

%% @private
%% Bring the relation in line with the user's desired group set: assert the
%% added groups, retract the removed ones. Called at every user store, so a
%% no-op set (desired == current) costs one forward-band scan and no write.
%%
%% Returns whether the relation changed. `store/3` needs that on the
%% declarative path to decide whether the user cell must be re-stamped.
-spec reconcile_membership(uri(), username_int(), [binary()]) -> boolean().

reconcile_membership(RealmUri, Username, Desired0) ->
    Desired = ordsets:from_list(Desired0),
    Current = ordsets:from_list(member_groups(RealmUri, Username)),
    Added = ordsets:subtract(Desired, Current),
    Removed = ordsets:subtract(Current, Desired),
    _ = [member_assert(RealmUri, Username, G) || G <- Added],
    _ = [member_retract(RealmUri, Username, G) || G <- Removed],
    Added =/= [] orelse Removed =/= [].

%% @private
%% Retract every membership fact for a user (on user deletion).
clear_memberships(RealmUri, Username) ->
    _ = [
        member_retract(RealmUri, Username, G)
     || G <- member_groups(RealmUri, Username)
    ],
    ok.

%% @private
%% The group names of one user (forward band scan, live cells only). A user has
%% few groups, so the band is small and read whole (no pagination).
member_groups(RealmUri, Username) ->
    {Lo, Hi} = fwd_band(Username),
    %% Single-shard read: a user's forward cells co-locate on the user's shard
    %% (catalogue `aggregate_root => second_col`), and `range/5` derives that
    %% shard from the band's leading bytes (`second_col(Lo) = Username`) — so
    %% this is one bounded shard scan, not the all-shard scatter `range_all`
    %% would run. This is the hot auth path (`get_context` → `lookup`).
    {ok, Rows} = bondy_db:range(member_table(), RealmUri, Lo, Hi, #{}),
    [fwd_group(Key) || {Key, true, _Hlc} <- Rows].

%% @private
%% Every user's groups in the realm as `#{Username => [Group]}` — one scan of
%% the realm's forward membership band, for the whole-realm `list/2` join.
all_member_groups(RealmUri) ->
    Rel = bondy_relation:new(member_fwd, #{
        table => member_table(),
        decode => fun decode_fwd_member/1
    }),
    {ok, Map} = bondy_relation:fold(
        Rel,
        RealmUri,
        fun({U, G}, Acc) ->
            maps:update_with(U, fun(Gs) -> [G | Gs] end, [G], Acc)
        end,
        #{}
    ),
    Map.

%% @private
%% Groups for a PAGE of users as `#{Username => [Group]}`. A user's forward
%% membership cells co-locate on the user's shard (catalogue
%% `aggregate_root => second_col`), so the page's usernames are grouped by their
%% shard and each shard contributes ONE bounded single-shard band scan. A
%% partition-ordered page is one shard ⇒ one scan; a globally-ordered page spans
%% shards ⇒ one tight scan each — either way no cross-shard scatter, and the
%% page need not be globally ordered (min/max bound each shard's band).
page_member_groups(_RealmUri, []) ->
    #{};
page_member_groups(RealmUri, Users) ->
    Table = member_table(),
    Names = [maps:get(username, U) || U <- Users],
    ByShard = lists:foldl(
        fun(Name, Acc) ->
            {Lo, _} = fwd_band(Name),
            Shard = bondy_db:shard_for(Table, RealmUri, Lo),
            maps:update_with(Shard, fun(Ns) -> [Name | Ns] end, [Name], Acc)
        end,
        #{},
        Names
    ),
    Map = maps:fold(
        fun(Shard, ShardNames, Acc) ->
            {Lo, _} = fwd_band(lists:min(ShardNames)),
            {_, Hi} = fwd_band(lists:max(ShardNames)),
            scan_member_band(RealmUri, Shard, Lo, Hi, Acc)
        end,
        #{},
        ByShard
    ),
    %% Cells scan ascending by key (group); `update_with` prepends, so restore
    %% ascending group order to match the per-user `member_groups/2` path.
    maps:map(fun(_U, Gs) -> lists:reverse(Gs) end, Map).

%% @private
%% Chunked ascending scan of one shard's forward membership band, folding every
%% LIVE cell into `#{Username => [Group]}` (descending group order — caller
%% reverses). Forced onto `Shard` (the band's co-located shard); pages past the
%% row cap so a wide band (many users / groups) is never silently truncated.
scan_member_band(RealmUri, Shard, Lo, Hi, Acc) ->
    RangeOpts = #{limit => 1000, shard => Shard},
    case bondy_db:range(member_table(), RealmUri, Lo, Hi, RangeOpts) of
        {ok, []} ->
            Acc;
        {ok, Rows} ->
            {Acc1, LastKey} = lists:foldl(
                fun({Key, _V, _Hlc} = Row, {A, _Last}) ->
                    case decode_fwd_member(Row) of
                        {ok, {U, G}} ->
                            {
                                maps:update_with(
                                    U, fun(Gs) -> [G | Gs] end, [G], A
                                ),
                                Key
                            };
                        skip ->
                            {A, Key}
                    end
                end,
                {Acc, undefined},
                Rows
            ),
            case length(Rows) < 1000 of
                true ->
                    Acc1;
                false ->
                    scan_member_band(
                        RealmUri, Shard, <<LastKey/binary, 0>>, Hi, Acc1
                    )
            end
    end.

%% @private
%% Decode a live forward membership cell to `{User, Group}`; skip reverse cells
%% and disabled (retracted) ones.
decode_fwd_member({Key, true, _Hlc}) ->
    case bondy_oplog_index_key:decode_tuple(Key) of
        [?MEMBER_FWD, U, G] -> {ok, {U, G}};
        _ -> skip
    end;
decode_fwd_member(_) ->
    skip.

%% @private
%% Add the user's derived `groups` (from the relation) to a user map read from
%% the cell, which does not carry them. The single-user get path uses this;
%% the list page path joins groups in bulk via `page_member_groups/2`.
with_groups(RealmUri, Username, User) ->
    User#{groups => member_groups(RealmUri, Username)}.

%% @private
%% Join a user map against a pre-computed `#{Username => [Group]}` map.
join_groups(GMap, #{username := Username} = User) ->
    User#{groups => maps:get(Username, GMap, [])}.

%% @private
%% The user map as persisted in the cell: `groups` lives in the membership
%% relation, never in the user record.
strip_groups(User) ->
    maps:remove(groups, User).

%% @private
%% One realm-scoped page of group `Group`'s LIVE members from the reverse band:
%% up to `Target` usernames in ascending order, resuming strictly after `After`
%% (a username, or `undefined` for the first page). Disabled (retracted)
%% presence cells are skipped, so the page is over-fetched until `Target` live
%% members are gathered or the band is exhausted. `Group` MUST already be
%% normalised (casefolded) so it matches the stored cell columns.
members_page(RealmUri, Group, After, Target) ->
    {BandLo, Hi} = rev_band(Group),
    Lo =
        case After of
            undefined -> BandLo;
            _ -> <<(mkey_rev(Group, After))/binary, 0>>
        end,
    collect_members(RealmUri, Lo, Hi, Target, []).

%% @private
collect_members(RealmUri, Lo, Hi, Target, Acc) ->
    Chunk = erlang:max(Target, 64),
    RangeOpts = #{limit => Chunk},
    %% Single-shard read: a group's reverse cells co-locate on the group's shard
    %% (`second_col(Lo) = Group`), so `range/5` resolves to that one shard rather
    %% than scattering — "members of a group" is a bounded single-shard band scan.
    case bondy_db:range(member_table(), RealmUri, Lo, Hi, RangeOpts) of
        {ok, []} ->
            lists:sublist(lists:reverse(Acc), Target);
        {ok, Rows} ->
            {Acc1, LastKey} = lists:foldl(
                fun add_live_member/2, {Acc, undefined}, Rows
            ),
            Done = length(Acc1) >= Target orelse length(Rows) < Chunk,
            case Done of
                true ->
                    lists:sublist(lists:reverse(Acc1), Target);
                false ->
                    collect_members(
                        RealmUri, <<LastKey/binary, 0>>, Hi, Target, Acc1
                    )
            end
    end.

%% @private
add_live_member({Key, true, _Hlc}, {Acc, _Last}) ->
    {[rev_user(Key) | Acc], Key};
add_live_member({Key, _V, _Hlc}, {Acc, _Last}) ->
    {Acc, Key}.

%% @private
%% Bounded streaming fold over group `Groupname`'s members, paging the reverse
%% band so it never materialises the whole member set. `Fun` is applied to each
%% username in ascending order. Returns `{ok, Acc}`.
fold_members(RealmUri, Groupname, Fun, Acc0) when is_function(Fun, 2) ->
    Group = bondy_rbac_group:normalise_name(Groupname),
    do_fold_members(RealmUri, Group, undefined, Fun, Acc0).

%% @private
do_fold_members(RealmUri, Group, After, Fun, Acc) ->
    case members_page(RealmUri, Group, After, ?MEMBER_PAGE) of
        [] ->
            {ok, Acc};
        Users ->
            Acc1 = lists:foldl(Fun, Acc, Users),
            case length(Users) < ?MEMBER_PAGE of
                true ->
                    {ok, Acc1};
                false ->
                    do_fold_members(
                        RealmUri, Group, lists:last(Users), Fun, Acc1
                    )
            end
    end.

%% @private
%% Reads a cell, returning the bare value, or `undefined` when the cell is
%% absent or cleared — the two are indistinguishable to callers by design.
do_get(RealmUri, Key) ->
    case bondy_db:read(table(), RealmUri, Key) of
        {ok, {Value, _Hlc}} -> Value;
        {error, not_found} -> undefined
    end.

%% =============================================================================
%% PRIVATE: LIFECYCLE SIDE-EFFECTS
%% =============================================================================
%% The user lifecycle side-effects, invoked inline from the write and delete
%% chokepoints (`store/3`, `remove/3`, `remove_all/2`). A peer's merged write
%% does not reach here: the equivalent session closes are applied by the
%% merge-side reactor.

%% @private
-spec do_on_update(uri(), username_int(), IsCreate :: boolean()) -> ok.

do_on_update(RealmUri, Username, true) ->
    ok = bondy_telemetry:user_event(added, RealmUri, Username),
    bondy_event_manager:notify({[bondy, user, added], RealmUri, Username}),
    ok;
do_on_update(RealmUri, Username, false) ->
    %% 1. Revoke all auth tickets (OAUTH2 tokens: TODO).
    _ = revoke_tickets(RealmUri, Username),
    %% 2. Closing sessions on a credential change is handled by
    %%    on_credentials_change/2 — it has the calling session to exclude.
    %% 3. Publish the event.
    ok = bondy_telemetry:user_event(updated, RealmUri, Username),
    bondy_event_manager:notify({[bondy, user, updated], RealmUri, Username}),
    ok.

%% @private
-spec do_on_delete(uri(), username_int()) -> ok.

do_on_delete(RealmUri, Username) ->
    %% 1. Revoke all auth tickets.
    _ = revoke_tickets(RealmUri, Username),
    %% 2. Revoke the user's OAuth tokens. A token cell is a second cell hanging
    %% off the user record, in another table, and nothing else drops it on this
    %% path — `bondy_oauth_token:refresh/2` names this function as what removes
    %% them. Left behind, the set is storage no one can ever redeem, and a user
    %% re-created under the same name adopts it. One cell, one clear, so it is
    %% synchronous unlike the ticket scan.
    ok = bondy_oauth_token:revoke_all(RealmUri, Username),
    %% 3. Close all local sessions.
    ok = close_sessions(RealmUri, Username, ?BONDY_USER_DELETED),
    %% 4. Retract every membership fact for the user, so it does not linger as
    %% a member of any group.
    ok = clear_memberships(RealmUri, Username),
    %% 5. Publish the event.
    ok = bondy_telemetry:user_event(deleted, RealmUri, Username),
    bondy_event_manager:notify({[bondy, user, deleted], RealmUri, Username}),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
-spec do_add(RealmUri :: binary(), User :: t(), add_opts()) -> ok | no_return().

do_add(RealmUri, #{sso_realm_uri := SSOUri} = User0, Opts) when
    is_binary(SSOUri)
->
    Username = maps:get(username, User0),

    %% Key validations first
    %% We skip the existence check when applying declarative config (overwrite).
    Declarative = maps:get(declarative, Opts, false),
    Declarative == true orelse not_exists_check(RealmUri, Username),
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

    Flag = Declarative == true orelse not exists(SSOUri, Username),
    ok = maybe_add_sso_user(Flag, RealmUri, SSOUri, SSOUser, Opts),

    %% We finally add the local user to the realm
    store(RealmUri, LocalUser, Opts);
do_add(RealmUri, User0, Opts) ->
    %% A local-only user
    Username = maps:get(username, User0),

    %% Key validations first
    %% We skip the existence check when applying declarative config (overwrite).
    Declarative = maps:get(declarative, Opts, false),
    Declarative == true orelse not_exists_check(RealmUri, Username),
    ok = groups_exists_check(RealmUri, maps:get(groups, User0, [])),

    %% We split the user into LocalUser, SSOUSer and Opts
    {UserOpts, User1} = maps_utils:split([sso_opts, password_opts], User0),
    User = apply_password(User1, password_opts(RealmUri, UserOpts)),

    store(RealmUri, User, Opts).

%% @private
maybe_add_sso_user(true, RealmUri, SSOUri, SSOUser, Opts) ->
    bondy_realm:is_allowed_sso_realm(RealmUri, SSOUri) orelse
        throw(invalid_sso_realm),

    ok = groups_exists_check(SSOUri, maps:get(groups, SSOUser, [])),

    %% We add the user to the SSO realm
    {ok, _} = maybe_throw(store(SSOUri, SSOUser, Opts)),
    ok;
maybe_add_sso_user(false, _, _, _, _) ->
    ok.

%% @private
-spec do_update(
    RealmUri :: binary(),
    User :: t(),
    Data :: map(),
    Opts :: update_opts()
) ->
    ok | no_return().

do_update(RealmUri, #{sso_realm_uri := SSOUri} = User, Data0, Opts) when
    is_binary(SSOUri)
->
    Username = maps:get(username, User),

    case lookup(SSOUri, Username) of
        {error, not_found} ->
            throw(not_such_user);
        {ok, SSOUser} ->
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
    has_password_changed(User, Data) orelse
        have_authorized_keys_changed(User, Data).

%% @private
has_password_changed(User, Data) ->
    NewPassword = maps:get(password, Data, undefined),
    NewPassword =/= undefined andalso
        NewPassword =/= maps:get(password, User, undefined).

%% @private
have_authorized_keys_changed(User, Data) ->
    NewKeys = maps:get(authorized_keys, Data, undefined),
    NewKeys =/= undefined andalso
        NewKeys =/= maps:get(authorized_keys, User, undefined).

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
do_change_password(
    RealmUri, #{password := PW, username := Username}, New, Old
) when
    Old =/= undefined
->
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
    %% Bounded keyset fold over every user record (alias cells rejected by the
    %% relation decoder) — replaces a full-realm materialise.
    {ok, ok} = bondy_relation:fold(
        relation(),
        RealmUri,
        fun(User, ok) -> update_groups(RealmUri, User, Groupnames, Fun) end,
        ok
    ),
    ok;
update_groups(RealmUri, Users, Groupnames, Fun) when is_list(Users) ->
    _ = [update_groups(RealmUri, User, Groupnames, Fun) || User <- Users],
    ok;
update_groups(
    RealmUri,
    #{type := ?USER_TYPE, username := Username} = User,
    Groupnames,
    Fun
) when
    is_function(Fun, 2)
->
    %% The current group set is read from the authoritative membership relation
    %% (not the user map, which may be a bare cell from a whole-realm fold), so
    %% `Fun` computes the new set from the live membership. `update` → `store`
    %% reconciles the relation to the result and bumps the user cell HLC
    %% (token_version).
    Current = member_groups(RealmUri, Username),
    Update = #{groups => Fun(Current, Groupnames)},
    case update(RealmUri, User, Update) of
        {ok, _} -> ok;
        {error, Reason} -> throw(Reason)
    end;
update_groups(RealmUri, Username, Groupnames, Fun) when is_binary(Username) ->
    update_groups(RealmUri, fetch(RealmUri, Username), Groupnames, Fun).

-doc """
Persists one cell of a legacy `security_users` backup — one written before the
current storage layout — keyed by `Key` within `RealmUri`.

The table holds two kinds of cell, and this is the one place that decides which
a value is, so a restore splits a record exactly as the live write path does.

**An alias-pointer cell** (`#{type => alias, username => Target}`) is written
verbatim under its own key. It names its target in the same field a user record
names itself, so the `type` decides, never the presence of `username`.

**A user record** is upgraded to the current shape and routed through the
declarative write path. A legacy record carries its groups inline, and `groups`
is not a key of the user cell: they belong in the membership relation, which is
where authorization reads them. Declarative is what a restore is — overwrite the
record, reconcile the membership to what the backup declares, and fire no
runtime lifecycle side-effects.

Not routed through `add/3`, which re-derives credentials and requires every
named group to already exist. A restore must accept a record whose password
shape it cannot re-derive and whose groups have not been read out of the backup
yet.
""".
-spec import_legacy(RealmUri :: uri(), Key :: binary(), Value :: term()) ->
    ok | no_return().

import_legacy(RealmUri, Alias, Entry) when ?IS_ALIAS(Entry) ->
    bondy_db:apply(table(), RealmUri, Alias, {set, Entry});
import_legacy(RealmUri, Username, Value) ->
    User = from_term({Username, Value}),
    {ok, _} = store(RealmUri, User, #{declarative => true}),
    ok.

%% @private
%% `groups` is NOT persisted in the user cell — membership is the authoritative
%% cell-per-fact `security_group_members` relation. The persisted value is the
%% user map with `groups` stripped; the desired membership set (the map's
%% `groups`) is reconciled into the relation. The user-cell write still happens
%% on every membership change, so its HLC — the `token_version` — keeps
%% advancing (a removed/added group forces the zookie forward, design §9.3).
store(RealmUri, #{username := Username} = User, #{declarative := true}) ->
    %% Declarative config apply: write WITHOUT firing the runtime lifecycle
    %% side-effects, and IDEMPOTENTLY — emit a write only when something
    %% differs. Re-reading the same config file on every boot must not re-stamp
    %% the user cell with a fresh HLC (which would diverge the cross-node content
    %% digest); the op-based CRDT + anti-entropy handle convergence, so no
    %% deterministic-version rebase is needed. The user object is deterministic
    %% (see `bondy_realm:validate_rbac_config` for the deterministic salt), so an
    %% unchanged config compares equal.
    %%
    %% The config file declares group membership, so the relation is reconciled
    %% here exactly as on the runtime path: the file is the desired state, and a
    %% group dropped from it is retracted. `reconcile_membership/3` writes
    %% nothing when the relation already matches, so idempotency is preserved.
    %%
    %% A membership change forces the user-cell write even when the record
    %% itself is unchanged: that cell's HLC is the revocation zookie
    %% (`token_version/2`), so without the write, revoking a group through the
    %% config file would leave already-issued tokens valid.
    %%
    %% Both properties are covered by
    %% `bondy_rbac_user_SUITE:declarative_config_membership/1`.
    Desired = strip_groups(User),
    Reconciled = reconcile_membership(
        RealmUri, Username, maps:get(groups, User, [])
    ),
    case do_get(RealmUri, Username) of
        Desired when not Reconciled ->
            %% Unchanged — no write, no new operation, convergence undisturbed.
            ok;
        _ ->
            ok = durable_apply(table(), RealmUri, Username, {set, Desired})
    end,
    {ok, User};
store(RealmUri, #{username := Username} = User, _) ->
    %% The previous value distinguishes a create from an update, which is the
    %% only difference between the two lifecycle events.
    Old = do_get(RealmUri, Username),
    _ = reconcile_membership(RealmUri, Username, maps:get(groups, User, [])),
    ok = durable_apply(table(), RealmUri, Username, {set, strip_groups(User)}),
    ok = do_on_update(RealmUri, Username, Old == undefined),
    {ok, User}.

%% @private
%% A `bondy_db:apply` whose projection-await timeout is tolerated. `apply/4`
%% appends the event to the WAL durably and THEN waits for the applier to
%% project it; under heavy anti-entropy load — or while a shard's projection
%% backend is recovering — that wait can time out even though the write is
%% already durable and WILL be projected once the applier drains. A transient
%% projection-await timeout must NOT crash a boot/realm-config apply (which would
%% brick the node), so we treat it as success and log. Any other error still
%% fails the write.
durable_apply(Table, RealmUri, Key, Event) ->
    case bondy_db:apply(Table, RealmUri, Key, Event) of
        ok ->
            ok;
        {error, timeout} ->
            ?LOG_WARNING(#{
                description =>
                    "User write durably appended but the projection wait timed "
                    "out; continuing. The value projects once the applier "
                    "drains (check the shard's projection backend if persistent).",
                realm_uri => RealmUri,
                username => Key
            }),
            ok;
        {error, Reason} ->
            error({bondy_db_apply, Reason})
    end.

%% @private
password_opts(_, #{password_opts := Opts}) when is_map(Opts) ->
    Opts;
password_opts(RealmUri, _) ->
    bondy_stdlib:or_else(
        bondy_realm:password_opts(RealmUri),
        #{}
    ).

%% @private
merge(RealmUri, U1, U2, #{update_credentials := true} = Opts) ->
    User = maps:merge(U1, U2),
    P0 = maps:get(password, U1, undefined),
    Future = maps:get(password, U2, undefined),

    case {P0, Future} of
        {undefined, undefined} ->
            User;
        {undefined, _} ->
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
apply_password(#{password := Future} = User, POpts) when
    is_function(Future, 1)
->
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
not_exists_check(RealmUri, Username) ->
    case do_get(RealmUri, Username) of
        undefined -> ok;
        _ -> throw(already_exists)
    end.

%% @private
-doc "Takes into account realm inheritance".
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
        Table = table(),
        Aliases0 = sets:from_list(maps:get(aliases, User0, [])),
        case sets:del_element(Alias, Aliases0) of
            Aliases0 ->
                %% Delete anyway
                _ = bondy_db:apply(Table, RealmUri, Alias, clear),
                ok;
            Aliases ->
                _ = bondy_db:apply(Table, RealmUri, Alias, clear),
                User = User0#{aliases => sets:to_list(Aliases)},
                _ = store(RealmUri, User, #{}),
                ok
        end
    catch
        throw:invalid_alias ->
            {error, {invalid_value, alias, Alias0}}
    end.

%% @private
%% The alias index entry is a separate cell keyed by the alias. Writing it does
%% NOT fire the user lifecycle side-effects: an alias cell is not a user record.
%% The read before the write is what makes the name collision detectable — a
%% username or a different alias already occupying the key is refused.
store_alias(RealmUri, Alias, AliasEntry) ->
    Table = table(),
    case bondy_db:read(Table, RealmUri, Alias) of
        {error, not_found} ->
            bondy_db:apply(Table, RealmUri, Alias, {set, AliasEntry});
        {ok, {Val, _Hlc}} when Val == AliasEntry ->
            %% Already there, idempotent re-store.
            bondy_db:apply(Table, RealmUri, Alias, {set, AliasEntry});
        {ok, {_Other, _Hlc}} ->
            %% A user whose username == Alias, or a different alias.
            throw(already_exists)
    end.

-doc """
Exported for legacy-backup import: upgrade a pre-v1.1 proplist user
value to the current map (or pass a current map through).
""".
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

    %% The `{[bondy, user, updated], ...}` event fires from do_on_update/3 at the
    %% store chokepoint; here we publish the credentials-specific event and close
    %% the affected sessions (excluding the caller's own).
    ok = bondy_telemetry:user_event(credentials_updated, RealmUri, Username),
    bondy_event_manager:notify(
        {[bondy, user, credentials, updated], RealmUri, Username}
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
    Fun = fun() -> bondy_ticket:revoke_all(RealmUri, Username) end,
    bondy_router_worker:cast(Fun).

-doc """
Close all of this node's sessions for `Username` in realm `RealmUri` with the
given WAMP close `Reason`. Used both by the local delete/credential-change
chokepoints and by the cluster merge-side reactor (`bondy_aae_reactor`) when a
peer's user delete arrives via anti-entropy.
""".
-spec close_sessions(
    RealmUri :: uri(), Username :: binary(), Reason :: uri()
) -> ok.

close_sessions(RealmUri, Username, Reason) ->
    close_sessions(RealmUri, Username, Reason, #{}).

%% @private
close_sessions(RealmUri, Username, Reason, Opts) ->
    ok = bondy_session_manager:close_all(RealmUri, Username, Reason, Opts).
