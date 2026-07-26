%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_aae_reactor).
-moduledoc """
Node-local reactor for bondy_db **remote-merge** changes.

Subscribes to the change-notification namespaces of the bondy_db tables whose
remote (anti-entropy) changes require a node-local side-effect, and acts on the
`{bondy_oplog_core_merge_event, ...}` tag published by the merge-side hook
(`bondy_oplog_core:publish_merge/5`). Local writes are handled inline at their
own write/delete chokepoints, so the `{bondy_oplog_core_event, ...}` (local) tag
is ignored here.

## Reactions

| Table                   | Remote change | Side-effect |
|-------------------------|---------------|-------------|
| `security_users`        | delete        | close this node's sessions for the user (`bondy.user.deleted`) |
| `security_users`        | credential change | close this node's sessions for the user (`bondy.user.credentials_changed`) |
| `bondy_realm`           | delete        | close this node's sessions for the realm (`wamp.close.close_realm`) |
| `security_user_grants`  | grant/revoke  | invalidate this node's cached RBAC contexts for the realm (§9.5) + conflict alarm |
| `security_group_grants` | grant/revoke  | invalidate this node's cached RBAC contexts for the realm (§9.5) + conflict alarm |
| `security_group_members`| add/remove    | invalidate this node's cached RBAC contexts for the realm (§9.5) |
| `security_sources`      | set/delete    | conflict alarm only (sources gate *new* connections; no live-session effect) |
| `bondy_registration_rib`| set / clear   | record / remove the peer's registration RIB summary (`bondy_registry_rib`) |
| `bondy_subscription_rib`| set / clear   | record / remove the peer's subscription RIB summary (`bondy_registry_rib`) |

The **conflict alarm** is the lww safety valve for the authorization tables
(design §3): grants and sources deliberately stay last-writer-wins, so when a
remote merge replaces an existing *different* local value the losing write is
silently discarded. The reactor cannot tell a genuinely newer remote edit from
a concurrent one (lww carries no causal context), so it over-approximates:
every remote replacement of a differing value emits a
`[bondy, aae, merge_conflict]` telemetry event and a warning log naming realm
and table. Operators who never edit the same grant on two nodes concurrently
will never see it fire.

The split mirrors the authn-vs-authz distinction in the local write path: an
**authentication-level** change (a user or realm *delete*) tears the affected
sessions down, whereas an **authorization** change (a grant `set` or a revoke
`clear`) re-evaluates in place — the session survives and its next authorize
re-reads the subject's current grants. Grant invalidation is realm-wide because a
group-grant change affects every member; over-invalidating unaffected sessions
costs only a one-time context rebuild, so both grant tables share one reaction.

## Registry reactions (RIB summaries)

The `registry` tables are an AP namespace. Full registry entries are never
replicated — each node keeps only its own, in local memory. What crosses the
cluster is a per-node **RIB summary** (a count of a peer's registrations /
subscriptions for a `{realm, procedure}`), and it is those summary cells this
reactor consumes: a `set` records or updates the peer's summary, a `clear`
removes it — both delegated to `bondy_registry_rib`, which maintains this node's
stub store. The stub store is what routing consults to decide which peer nodes
to forward to. The RIB cell key is self-contained (realm included), so a `clear`
needs no tombstone resolution.

A peer's user *credential change* (a `set` whose password / authorized keys
differ from the pre-merge value carried by the event) closes this node's
sessions for the user, mirroring the local credential-change chokepoint
(`bondy_rbac_user`). A metadata-only `set` is a no-op. A realm `set` (create /
update) likewise needs no session-close.

## Subscription lifecycle

Each subscription is (re)established once the namespace catalogue has provisioned
the corresponding table (retried until then). Like the api_gateway reactor it
does not currently re-subscribe across a `bondy_oplog_core_dispatcher` restart —
the dispatcher is configured to effectively never restart.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_db_tables.hrl").
-include("bondy_uris.hrl").

-define(RESUBSCRIBE_AFTER, 500).

%% One reacted-on bondy_db table. `ns`/`ref` are filled once the namespace
%% catalogue has provisioned the table and the subscription is established;
%% until then they are `undefined` and the subscription is retried.
-record(sub, {
    table :: atom(),
    label :: string(),
    kind :: user | realm | grant | member | source | rib,
    ns :: atom() | undefined,
    ref :: reference() | undefined
}).

-record(state, {
    subs = [] :: [#sub{}]
}).

%% API
-export([start_link/0]).

-ifdef(TEST).
%% Exposed for unit testing the reaction logic without a running cluster.
-export([react_user/3]).
-export([react_realm/2]).
-export([react_grant/4]).
-export([react_member/2]).
-export([react_source/4]).
-export([react_rib/3]).
-export([unfold_user_key/1]).
-export([unfold_realm_key/1]).
-export([unfold_grant_key/1]).
-export([unfold_member_key/1]).
-endif.

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_continue/2]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    _ = bondy_registry_rib:ensure_stubs_table(),
    {ok, #state{subs = reacted_tables()}, {continue, subscribe}}.

handle_continue(subscribe, State) ->
    {noreply, subscribe(State)}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(retry_subscribe, State) ->
    {noreply, subscribe(State)};
handle_info(
    {bondy_oplog_core_merge_event, NS, Key, _Hlc, Op, Old}, State
) ->
    %% A peer's change to a reacted-on table arrived via anti-entropy; route it
    %% to the matching reaction by namespace. `Old` is the pre-merge cell value
    %% (`undefined` when the cell did not exist).
    ok = react(NS, Key, Op, Old, State),
    {noreply, State};
handle_info({bondy_oplog_core_event, _NS, _Key, _Hlc, _Op}, State) ->
    %% Local write — its side-effects fire inline at the write chokepoint.
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{subs = Subs}) ->
    _ = [
        bondy_oplog_core:unsubscribe(Ref)
     || #sub{ref = Ref} <- Subs, is_reference(Ref)
    ],
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The static set of bondy_db tables this node reacts to on a remote merge, each
%% tagged with the reaction `kind` used to dispatch a delivered event. Both grant
%% tables share the `grant` kind (a realm-wide §9.5 invalidation).
reacted_tables() ->
    [
        #sub{
            table = ?BONDY_DB_USER_TAB,
            label = "security_users",
            kind = user
        },
        #sub{
            table = ?BONDY_DB_REALM_TAB,
            label = "bondy_realm",
            kind = realm
        },
        #sub{
            table = ?BONDY_DB_USER_GRANT_TAB,
            label = "security_user_grants",
            kind = grant
        },
        #sub{
            table = ?BONDY_DB_GROUP_GRANT_TAB,
            label = "security_group_grants",
            kind = grant
        },
        #sub{
            table = ?BONDY_DB_GROUP_MEMBERS_TAB,
            label = "security_group_members",
            kind = member
        },
        #sub{
            table = ?BONDY_DB_SOURCE_TAB,
            label = "security_sources",
            kind = source
        },
        #sub{
            table = ?BONDY_DB_REGISTRATION_RIB_TAB,
            label = "bondy_registration_rib",
            kind = rib
        },
        #sub{
            table = ?BONDY_DB_SUBSCRIPTION_RIB_TAB,
            label = "bondy_subscription_rib",
            kind = rib
        }
    ].

%% @private
%% (Re)subscribe to every reacted-on namespace whose table the catalogue has
%% provisioned; retry shortly while any remains pending.
subscribe(#state{subs = Subs0} = State) ->
    Subs1 = [ensure_subscribed(S) || S <- Subs0],
    case lists:any(fun(#sub{ref = R}) -> R =:= undefined end, Subs1) of
        true ->
            _ = erlang:send_after(?RESUBSCRIBE_AFTER, self(), retry_subscribe),
            ok;
        false ->
            ok
    end,
    State#state{subs = Subs1}.

%% @private
%% Subscribe to one table's change namespace once the catalogue has provisioned
%% it; leave it pending (ns/ref `undefined`) until then.
ensure_subscribed(#sub{ref = Ref} = Sub) when is_reference(Ref) ->
    Sub;
ensure_subscribed(#sub{table = Table, label = Label} = Sub) ->
    case bondy_namespace_catalog:table(Table) of
        undefined ->
            Sub;
        Handle ->
            NS = bondy_db:namespace(Handle),
            {ok, Ref} = bondy_oplog_core:subscribe(NS, all),
            ?LOG_INFO(#{
                description => "AAE merge reactor subscribed to remote changes",
                table => Label
            }),
            Sub#sub{ns = NS, ref = Ref}
    end.

%% @private
%% Route a delivered merge event to the reaction for its namespace. An event for
%% a namespace not (yet) bound — or with no reaction — is ignored.
react(NS, Key, Op, Old, #state{subs = Subs}) ->
    case lists:keyfind(NS, #sub.ns, Subs) of
        #sub{kind = user} ->
            react_user(Key, Op, Old);
        #sub{kind = realm} ->
            react_realm(Key, Op);
        #sub{kind = grant, label = Label} ->
            react_grant(Label, Key, Op, Old);
        #sub{kind = member} ->
            react_member(Key, Op);
        #sub{kind = source, label = Label} ->
            react_source(Label, Key, Op, Old);
        #sub{kind = rib, table = Table} ->
            react_rib(Table, Key, Op);
        false ->
            ok
    end.

%% @private
%% React to a remote security_users change. A `clear` (delete) closes this
%% node's sessions for the user; a `set` closes them only when the merge
%% changed the user's credential material relative to the pre-merge value
%% (`Old`), mirroring the local credential-change chokepoint and the legacy
%% plum_db `on_merge`. Ops arrive as bondy_db's short forms (`{set, Value}` /
%% `clear`); the explicit HLC-carrying forms are accepted too.
react_user(Key, clear, Old) ->
    react_user(Key, {clear, undefined}, Old);
react_user(Key, {clear, _Hlc}, _Old) ->
    {RealmUri, Username} = unfold_user_key(Key),
    ?LOG_INFO(#{
        description =>
            "Closing local sessions for a user deleted on a peer node",
        realm_uri => RealmUri,
        username => Username
    }),
    bondy_rbac_user:close_sessions(RealmUri, Username, ?BONDY_USER_DELETED);
react_user(Key, {set, Value}, Old) ->
    react_user_set(Key, Value, Old);
react_user(Key, {set, _Hlc, Value}, Old) ->
    react_user_set(Key, Value, Old);
react_user(_Key, _Op, _Old) ->
    ok.

%% @private
react_user_set(Key, New, Old) ->
    case credentials_changed(New, Old) of
        true ->
            {RealmUri, Username} = unfold_user_key(Key),
            ?LOG_INFO(#{
                description =>
                    "Closing local sessions for a user whose credentials "
                    "changed on a peer node",
                realm_uri => RealmUri,
                username => Username
            }),
            bondy_rbac_user:close_sessions(
                RealmUri, Username, ?BONDY_USER_CREDENTIALS_CHANGED
            );
        false ->
            ok
    end.

%% @private
%% Whether a merged user value changed the credential material relative to the
%% pre-merge value. Same rule as the legacy plum_db `on_merge`: a credential
%% counts as changed when the NEW value carries it and it differs — a create
%% (`Old = undefined`) or a metadata-only edit is not a change. Total: any
%% non-map shape answers `false` (never crash the reactor).
credentials_changed(New, Old) when is_map(New) andalso is_map(Old) ->
    password_changed(New, Old) orelse authorized_keys_changed(New, Old);
credentials_changed(_New, _Old) ->
    false.

%% @private
password_changed(New, Old) ->
    NewPassword = maps:get(password, New, undefined),
    NewPassword =/= undefined andalso
        NewPassword =/= maps:get(password, Old, undefined).

%% @private
authorized_keys_changed(New, Old) ->
    NewKeys = maps:get(authorized_keys, New, undefined),
    NewKeys =/= undefined andalso
        NewKeys =/= maps:get(authorized_keys, Old, undefined).

%% @private
%% React to a remote bondy_realm change. A `clear` (delete) closes this node's
%% sessions for the realm; a `set` (create / update) is a no-op here. The delete
%% arrives as bondy_db's short-form `clear` atom (the explicit `{clear, Hlc}`
%% form is accepted too).
react_realm(Key, clear) ->
    react_realm(Key, {clear, undefined});
react_realm(Key, {clear, _Hlc}) ->
    RealmUri = unfold_realm_key(Key),
    ?LOG_INFO(#{
        description =>
            "Closing local sessions for a realm deleted on a peer node",
        realm_uri => RealmUri
    }),
    bondy_realm:close(RealmUri, ?WAMP_CLOSE_REALM);
react_realm(_Key, _Op) ->
    ok.

%% @private
%% React to a remote grant change (security_user_grants / security_group_grants).
%% A grant `set` and a revoke `clear` both change the authorization a cached RBAC
%% context would compute, so each invalidates this node's sessions for the realm
%% in place (§9.5): the next authorize re-reads the subject's current grants. No
%% teardown — an authorization change re-evaluates, it does not drop the session.
%% Realm-wide because a group-grant change affects every member. Additionally
%% raises the lww conflict alarm when the merge replaced a differing value.
react_grant(Label, Key, Op, Old) ->
    RealmUri = unfold_grant_key(Key),
    ok = maybe_conflict_alarm(Label, RealmUri, Op, Old),
    ?LOG_INFO(#{
        description =>
            "Invalidating local RBAC contexts after a peer grant change",
        realm_uri => RealmUri
    }),
    bondy_session_manager:invalidate_rbac_all(RealmUri).

%% @private
%% React to a remote security_sources change: conflict alarm only. Sources gate
%% authentication of NEW connections — established sessions are unaffected, so
%% there is nothing to invalidate or close; the next connection attempt reads
%% the merged value. The alarm is the reaction (design §3): sources stay lww,
%% so a silently discarded concurrent edit must at least be observable.
react_source(Label, Key, Op, Old) ->
    RealmUri = unfold_grant_key(Key),
    maybe_conflict_alarm(Label, RealmUri, Op, Old).

%% @private
%% The lww conflict alarm (design §3): a remote merge REPLACED an existing,
%% differing value of an authorization cell. Under lww the losing write is
%% silently discarded; the reactor cannot distinguish a genuinely newer remote
%% edit from a concurrent one (lww carries no causal context), so this
%% over-approximates — it fires on every remote replacement of a differing
%% value. Emits `[bondy, aae, merge_conflict]` telemetry + a warning log.
%% A create (`Old = undefined`), an identical rewrite, and a `clear` (a revoke
%% is an intended removal, not a conflict) are all silent.
maybe_conflict_alarm(Label, RealmUri, Op, Old) ->
    New =
        case Op of
            {set, V} -> V;
            {set, _Hlc, V} -> V;
            _ -> undefined
        end,
    case New =/= undefined andalso Old =/= undefined andalso New =/= Old of
        true ->
            telemetry:execute(
                [bondy, aae, merge_conflict],
                #{count => 1},
                #{table => Label, realm_uri => RealmUri}
            ),
            ?LOG_WARNING(#{
                description =>
                    "A remote anti-entropy merge replaced a different local "
                    "value of an authorization cell (last-writer-wins). If "
                    "both nodes edited it concurrently, the losing edit was "
                    "discarded — re-check the intended value.",
                table => Label,
                realm_uri => RealmUri
            }),
            ok;
        false ->
            ok
    end.

%% @private
%% React to a remote group-membership change (security_group_members). An
%% `enable` (add) or `disable` (remove) of a membership fact changes the
%% authorization a cached RBAC context would compute for the affected user, so
%% it invalidates this node's sessions for the realm in place (§9.5), exactly as
%% a grant change does — the next authorize re-reads the subject's current
%% groups. Realm-wide (the merged key carries no usable old value to scope it to
%% one user). No teardown — `token_version` (advanced by the peer's user-cell
%% touch, replicated separately) is what forces re-authentication.
react_member(Key, _Op) ->
    RealmUri = unfold_member_key(Key),
    ?LOG_INFO(#{
        description =>
            "Invalidating local RBAC contexts after a peer membership change",
        realm_uri => RealmUri
    }),
    bondy_session_manager:invalidate_rbac_all(RealmUri).

%% @private
%% Normalise the fold-event op a registry cell merge delivers. Registry writes use
%% bondy_db's short forms (`{set, Value}` / `clear`); the explicit `{set, Hlc,
%% Value}` / `{clear, Hlc}` forms are accepted too. Anything else is ignored — the
%% reaction MUST be total so an unexpected op never crashes the reactor.
registry_op({set, Value}) ->
    {set, Value};
registry_op({set, _Hlc, Value}) ->
    {set, Value};
registry_op(clear) ->
    clear;
registry_op({clear, _Hlc}) ->
    clear;
registry_op(_) ->
    ignore.

%% @private
%% A peer's RIB summary cell arrived (or was removed) via anti-entropy:
%% delegate to `bondy_registry_rib`, which maintains this node's stub store.
%% The cell key is self-contained (realm included), so a `clear` needs no
%% tombstone resolution. Total: unexpected ops are ignored.
react_rib(Table, Key, Op) ->
    Type =
        case Table of
            ?BONDY_DB_REGISTRATION_RIB_TAB -> registration;
            ?BONDY_DB_SUBSCRIPTION_RIB_TAB -> subscription
        end,
    case registry_op(Op) of
        {set, Summary} ->
            bondy_registry_rib:on_remote_set(Type, Key, Summary);
        clear ->
            bondy_registry_rib:on_remote_clear(Type, Key);
        ignore ->
            ok
    end.

%% @private
%% security_users is realm-sharded, so its cell key is the G-1 realm-folded
%% `<<Realm, 0, Username>>` (realm URIs are NUL-free). Split it back.
unfold_user_key(Key) ->
    case binary:split(Key, <<0>>) of
        [RealmUri, Username] ->
            {RealmUri, Username};
        _ ->
            error({malformed_user_cell_key, Key})
    end.

%% @private
%% bondy_realm is a global registry under the empty band `<<>>`, so on the
%% folding (`shared_shards`) core topology its cell key is `<<0, Uri>>` (the
%% empty band, a NUL separator, then the realm URI). Recover the URI.
unfold_realm_key(Key) ->
    case binary:split(Key, <<0>>) of
        [<<>>, RealmUri] ->
            RealmUri;
        _ ->
            error({malformed_realm_cell_key, Key})
    end.

%% @private
%% Grant tables are realm-banded, so on the folding (`shared_shards`) core
%% topology a grant cell key is `<<RealmUri, 0, EncodedGrantKey/binary>>`. The
%% realm URI is NUL-free, so the first separator recovers it; the trailing
%% composite grant key (role + resource) is not needed, as invalidation is
%% realm-wide.
unfold_grant_key(Key) ->
    case binary:split(Key, <<0>>) of
        [RealmUri, _EncGrantKey] ->
            RealmUri;
        _ ->
            error({malformed_grant_cell_key, Key})
    end.

%% @private
%% security_group_members is realm-banded, so on the folding (`shared_shards`)
%% core topology a membership cell key is `<<RealmUri, 0, EncodedFactKey>>`. The
%% realm URI is NUL-free, so the first separator recovers it; the trailing
%% band-tagged fact key is not needed, as invalidation is realm-wide.
unfold_member_key(Key) ->
    case binary:split(Key, <<0>>) of
        [RealmUri, _EncFactKey] ->
            RealmUri;
        _ ->
            error({malformed_member_cell_key, Key})
    end.
