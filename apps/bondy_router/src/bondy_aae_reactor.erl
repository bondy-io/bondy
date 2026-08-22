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
-include("bondy.hrl").
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
-export([apply_reaction/4]).
%% Exposed for the same reason as `apply_reaction/4`: it lets the bootstrap
%% dispatch be unit-tested without a running cluster.
-export([bootstrap_reaction/2]).

-ifdef(TEST).
%% Exposed for unit testing the reaction logic without a running cluster.
-export([react_user/3]).
-export([react_realm/2]).
-export([react_grant/4]).
-export([react_member/2]).
-export([react_group/2]).
-export([reacted_table_names/0]).
-export([react_source/4]).
-export([react_rib/3]).
-export([unfold_user_key/1]).
-export([unfold_realm_key/1]).
-export([unfold_grant_key/1]).
-export([unfold_member_key/1]).
-export([make_sub/3]).
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
    %% A peer's change to a reacted-on table arrived via anti-entropy. Resolve
    %% the reaction by namespace and hand it to the pool worker for this cell
    %% `Key` — the reaction runs there, not inline, so one node's anti-entropy
    %% side-effects no longer serialise through this process. `Old` is the
    %% pre-merge cell value (`undefined` when the cell did not exist).
    ok = route(NS, Key, Op, Old, State),
    {noreply, State};
handle_info({bondy_oplog_core_bootstrap_event, NS, _Bucket}, State) ->
    %% A catalogue-snapshot install replaced this table's projection
    %% wholesale. It emits no per-cell merge event, so any state we DERIVE
    %% from the table has to be rebuilt from the projection now — this is
    %% the only notification that path sends.
    %%
    %% Run INLINE, not through the pool: there is no cell key to hash on, and
    %% the rebuild must not interleave with itself (a streamed snapshot can
    %% notify the same table several times).
    ok = bootstrap_rebuild(NS, State),
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
            table = ?BONDY_DB_GROUP_TAB,
            label = "security_groups",
            kind = group
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
ensure_subscribed(#sub{table = Table, label = Label, kind = Kind} = Sub) ->
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
            %% RECONCILE ON ATTACH, do not assume we heard the event.
            %%
            %% The bootstrap notification is one-shot and `fanout_all/2`
            %% reaches only the subscribers that exist when it fires. This
            %% reactor subscribes ASYNCHRONOUSLY — `init/1` defers to a
            %% `{continue, subscribe}` that retries until the catalogue has
            %% provisioned each table — so a bootstrap completing before that
            %% wins the race and its event is lost with no replay.
            %%
            %% MEASURED 2026-08-22: on a PLAIN restart the surviving on-disk
            %% peer state lets AAE bootstrap the registry within milliseconds
            %% of the instance starting, and the restart-suite case failed
            %% 1-in-5 with zero notifications observed on the node.
            %%
            %% Rebuilding here removes the dependency on having heard it: the
            %% state this reactor maintains is DERIVED from the projection, so
            %% deriving it once at attach time is correct regardless of what
            %% happened before. Idempotent, and a no-op when the projection is
            %% still empty (the bootstrap then arrives normally and rebuilds).
            ok = bootstrap_reaction(Kind, Table),
            Sub#sub{ns = NS, ref = Ref}
    end.

%% @private
%% Resolve a delivered merge event's namespace to its subscription and cast the
%% reaction to the pool worker for this cell `Key` (hashed, so a cell's
%% `set`/`clear` land on one worker in order; distinct keys spread across the
%% pool). An event for a namespace not (yet) bound — or with no worker — is
%% ignored.
route(NS, Key, Op, Old, #state{subs = Subs}) ->
    case lists:keyfind(NS, #sub.ns, Subs) of
        #sub{} = Sub ->
            case gproc_pool:pick_worker(?AAE_REACTOR_POOL, Key) of
                Worker when is_pid(Worker) ->
                    gen_server:cast(Worker, {react, Sub, Key, Op, Old});
                _ ->
                    ?LOG_WARNING(#{
                        description =>
                            "Dropping AAE merge reaction, no pool worker",
                        namespace => NS
                    }),
                    ok
            end;
        false ->
            ok
    end.

%% @private
%% Resolve a bootstrap event's namespace to its subscription and rebuild
%% whatever that reaction DERIVES from the table.
%%
%% Only the `rib` kind derives state: `bondy_registry_rib` keeps the stub view
%% — the cross-node routing set that `bondy_broker` and `bondy_dealer` read —
%% in an ETS table that only these reactions ever write, and it also owns the
%% correction of this node's OWN resurrected cells.
%%
%% Every other kind is an INVALIDATION (close sessions whose credentials
%% changed, drop a cached RBAC context). A bootstrap that reaches them has by
%% definition just replaced the projection those caches would be rebuilt
%% from, and the node doing it either has no sessions and no caches yet (a
%% fresh replica) or has already had its caches driven by the op-replay that
%% `bondy_oplog_sync_session:finish_bootstrap/4` runs for a LIVE
%% re-bootstrap. There is nothing for them to invalidate here, so they are a
%% deliberate no-op rather than an oversight.
bootstrap_rebuild(NS, #state{subs = Subs}) ->
    case lists:keyfind(NS, #sub.ns, Subs) of
        #sub{kind = Kind, table = Table} ->
            bootstrap_reaction(Kind, Table);
        false ->
            %% An event for a namespace this reactor is not bound to.
            ok
    end.

-doc """
Rebuild whatever the reaction for `Kind` DERIVES from `Table`, after a
catalogue-snapshot install replaced that table's projection wholesale.

Only `rib` derives state. Every other kind is an invalidation and has
nothing to invalidate at this point — see `bootstrap_rebuild/2`'s note.
MUST be total.
""".
-spec bootstrap_reaction(Kind :: atom(), Table :: atom()) -> ok.

bootstrap_reaction(rib, Table) ->
    bondy_registry_rib:rebuild(Table);
bootstrap_reaction(_Kind, _Table) ->
    ok.

-doc """
Run the reaction for a resolved subscription `Sub` against a delivered merge
event `(Key, Op, Old)`. Runs in the pool worker process (see
`bondy_aae_reactor_worker`); split out from routing so the worker need not know
the reaction taxonomy. Dispatch is by the subscription `kind`, mirroring the
`reacted_tables/0` set.
""".
-spec apply_reaction(
    Sub :: #sub{}, Key :: term(), Op :: term(), Old :: term() | undefined
) -> ok.

apply_reaction(#sub{kind = user}, Key, Op, Old) ->
    react_user(Key, Op, Old);
apply_reaction(#sub{kind = realm}, Key, Op, _Old) ->
    react_realm(Key, Op);
apply_reaction(#sub{kind = grant, label = Label}, Key, Op, Old) ->
    react_grant(Label, Key, Op, Old);
apply_reaction(#sub{kind = member}, Key, Op, _Old) ->
    react_member(Key, Op);
apply_reaction(#sub{kind = group}, Key, Op, _Old) ->
    react_group(Key, Op);
apply_reaction(#sub{kind = source, label = Label}, Key, Op, Old) ->
    react_source(Label, Key, Op, Old);
apply_reaction(#sub{kind = rib, table = Table}, Key, Op, _Old) ->
    react_rib(Table, Key, Op).

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
%% React to a remote group-record change (security_groups). A group's `groups`
%% property is its parent list — the role-inheritance edge — and a cached RBAC
%% context bakes in the grants that edge resolves to, so changing it changes the
%% authorization a live session computes. Invalidate in place (§9.5) exactly as
%% a membership or grant change does; the next authorize re-walks the group
%% graph. Realm-wide, and on any op: a group create carries no members yet and a
%% delete already invalidates through `bondy_rbac:revoke_group/2`, so the
%% over-invalidation costs one rebuild and needs no old/new comparison to be
%% correct.
react_group(Key, _Op) ->
    RealmUri = unfold_realm_banded_key(Key, malformed_group_cell_key),
    ?LOG_INFO(#{
        description =>
            "Invalidating local RBAC contexts after a peer group change",
        realm_uri => RealmUri
    }),
    bondy_session_manager:invalidate_rbac_all(RealmUri).

%% @private
%% A peer's RIB summary cell changed via anti-entropy: delegate to
%% `bondy_registry_rib:on_remote_merge/2`, which reads the cell's current
%% converged value and maintains this node's stub store. Unlike the other
%% `kind`s here, the RIB write path's per-field CRDT ops (`{apply, count,
%% {inc, _}}`, a bare `{inc, _}`, ...) carry no whole-value `{set, _}`/
%% `clear` shape to dispatch on — the op itself is therefore irrelevant and
%% `on_remote_merge/2` re-reads the cell instead. Total: `on_remote_merge/2`
%% is itself total.
react_rib(Table, Key, _Op) ->
    Type =
        case Table of
            ?BONDY_DB_REGISTRATION_RIB_TAB -> registration;
            ?BONDY_DB_SUBSCRIPTION_RIB_TAB -> subscription
        end,
    bondy_registry_rib:on_remote_merge(Type, Key).

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
%% folding (`shared_shards`) main topology its cell key is `<<0, Uri>>` (the
%% empty band, a NUL separator, then the realm URI). Recover the URI.
unfold_realm_key(Key) ->
    case binary:split(Key, <<0>>) of
        [<<>>, RealmUri] ->
            RealmUri;
        _ ->
            error({malformed_realm_cell_key, Key})
    end.

%% @private
%% The realm URI of a REALM-BANDED cell. On the folding (`shared_shards`) main
%% topology such a cell key is `<<RealmUri, 0, EncodedKey/binary>>`, and the
%% realm URI is NUL-free, so the first separator recovers it. The trailing
%% encoded key — a composite grant key, a membership fact, a group name — is
%% never needed here: every reaction that uses this invalidates realm-wide.
%% `Tag` names the table in the error so a malformed key still says which.
unfold_realm_banded_key(Key, Tag) ->
    case binary:split(Key, <<0>>) of
        [RealmUri, _EncodedKey] ->
            RealmUri;
        _ ->
            error({Tag, Key})
    end.

%% @private
unfold_grant_key(Key) ->
    unfold_realm_banded_key(Key, malformed_grant_cell_key).

%% @private
unfold_member_key(Key) ->
    unfold_realm_banded_key(Key, malformed_member_cell_key).

-ifdef(TEST).
%% TEST-only: build a `#sub{}` for exercising `apply_reaction/4` dispatch without
%% a running subscription (`ns`/`ref` are unused on the reaction path).
make_sub(Kind, Label, Table) ->
    #sub{kind = Kind, label = Label, table = Table}.

%% TEST-only: the tables this node reacts on, as plain names. `#sub{}` is
%% private, and a reaction the routing set never names is dead code — so the
%% set itself is worth asserting on.
reacted_table_names() ->
    [T || #sub{table = T} <- reacted_tables()].
-endif.
