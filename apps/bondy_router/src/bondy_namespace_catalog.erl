%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_namespace_catalog).
-behaviour(gen_server).
-moduledoc """
The single declaration point for Bondy's `bondy_db` databases and tables, and
the owner process for the durable `main` database.

Two databases are declared:

- **`main`** — durable (`bondy_db_topology_shared_shards` over leveled),
  holding the fourteen security / realm / realm-keys / gateway / token /
  bridge / retention / interface tables.
- **`registry`** — ephemeral (`bondy_db_topology_memory`, ETS), holding the
  RIB (Routing Information Base) summary tables — the replicated routing
  cells for registrations / subscriptions. Full `#entry{}` records never
  enter `bondy_db` at all; they live in `bondy_registry_store`'s local ETS
  (see `bondy_registry_rib.erl`'s moduledoc).

The table names mirror the `bondy_db_tables.hrl` prefixes, plus
`security_group_members` (group membership is its own cell-per-fact relation —
an `ew_flag`, enable-wins — rather than a list inline on `security_groups`) and
`retained_messages` (which predates the prefix macros). Each table declares,
where related cells should co-locate, an `aggregate_root` (consumed with the
DB-level `partition_strategy` by strategy-aware shard routing) and its fold
class (`lww | mv | aw | ew`), which selects the table's CRDT (`fold_opts/1`).
Both are honoured by `bondy_db:open_table/3`: they determine on-disk
placement and convergence semantics, not merely metadata.

## Provisioning

Every declared table is provisioned at boot, unconditionally — the full
`main` set and the two `registry` tables. `init/1` opens both DBs with every
table their specs declare; there is no per-table or per-domain gate.

## Lifecycle

This module is a `gen_server` (a child of `bondy_sup`). Because `bondy_db`
keeps leveled supervisors on-demand and **owned by the `open/2` caller**, the
catalogue process owns the `main` DB's `bondy_db_leveled_sup` for its lifetime:

- `init/1` — opens the durable `main` DB and the ephemeral `registry` DB with
  their tables, and publishes the DB / table handles via `persistent_term` for
  lock-free access. The two DBs are opened independently; an open failure logs
  loudly and leaves that DB idle rather than bricking boot.
- `terminate/2` — closes each open table, the DB, and the leveled sup.

Accessors (`main_db/0`, `table/1`, `is_open/0`, `info/0`) read `persistent_term`
and never call the process. Declarations (`tables/0`, `main_db_spec/0`,
`registry_db_spec/0`) are pure.
""".

-include_lib("kernel/include/logger.hrl").

-include("bondy_db_tables.hrl").

-define(PT_MAIN_FAILED, {?MODULE, main_failed}).
-define(PT_DB(Name), {?MODULE, db, Name}).
-define(PT_TABLE(Name), {?MODULE, table, Name}).

%% The native CRDTs that have no short fold alias in `bondy_oplog_cell_kernel`
%% (`mv_register` for grants / sources, `ew_flag` for group membership). They are
%% passed as an explicit `crdt_module`; the `fold_module` stays `lww_register`,
%% their byte-compatible carrier — see the mv_register / ew_flag e2e tests.
-define(MV_CRDT, bondy_oplog_crdt_mv_register).
-define(AW_CRDT, bondy_oplog_crdt_aw_map).
-define(EW_CRDT, bondy_oplog_crdt_ew_flag).

%% The registration RIB cell's `bondy_oplog_crdt_struct` schema, passed as
%% `crdt_opts` (the struct has no schema of its own — see
%% `bondy_oplog_crdt_struct`'s moduledoc). `count`'s `stabilize_zero => 0`
%% is the RIB-specific policy: the local group's cell is reclaimable once
%% it empties. `earliest`/`latest` are monotone ratchets over the group's
%% entry-creation times — a scalar per field regardless of how many
%% entries ever existed (the former `created_times` two_p_set grew one
%% element per add and one tombstone per remove, forever), at the
%% documented cost that removals never shrink them: they are lifetime
%% watermarks of the group, which WAMP dealer semantics permit.
-define(RIB_REGISTRATION_SCHEMA, #{
    count => {bondy_oplog_crdt_pn_counter, #{stabilize_zero => 0}},
    invoke => bondy_oplog_crdt_lww_register,
    earliest => bondy_oplog_crdt_min_register,
    latest => bondy_oplog_crdt_max_register
}).

-record(state, {
    db :: bondy_db:db() | undefined,
    leveled_sup :: pid() | undefined,
    dir :: file:filename_all() | undefined,
    %% The ephemeral `registry` DB (memory topology — no leveled sup / dir),
    %% provisioned alongside `main`.
    registry_db :: bondy_db:db() | undefined
}).

-type fold_class() ::
    lww | mv | aw | ew | presence | rib_registration | rib_subscription.
-type db_name() :: bondy_db_config:db_name().
-type table_spec() :: #{
    name := atom(),
    db := db_name(),
    durability := durable | ephemeral,
    fold := fold_class(),
    %% `true` to wire the table's appliers to publish change events.
    publish => boolean(),
    %% The contract a `publish => true` assumes of its consumer.
    %% `must_not_miss` (the default): events are the only mechanism that
    %% corrects the consumer's derived state — or the event's side effect
    %% is itself the deliverable (an alarm) — so a live subscriber for the
    %% table's whole life is a correctness invariant, asserted by
    %% `bondy_rbac_SUITE:every_publishing_table_has_a_live_subscriber`.
    %% `recovered_on_attach`: the consumer rebuilds its derived state from
    %% current table contents whenever it subscribes (reconcile-on-attach),
    %% so it may start on demand and a missed-event window is harmless;
    %% the assertion exempts these.
    missed_events => must_not_miss | recovered_on_attach,
    %% Declared secondary indexes (substrate-maintained reverse access
    %% paths), passed verbatim to `bondy_db:open_table/3`.
    indexes => [bondy_oplog_index_spec:spec()]
}.

-export_type([table_spec/0]).
-export_type([fold_class/0]).

%% API
-export([fold_opts/1]).
-export([info/0]).
-export([is_open/0]).
-export([main_status/0]).
-export([main_db/0]).
-export([main_db_name/0]).
-export([main_db_spec/0]).
-export([registry_db/0]).
-export([registry_db_name/0]).
-export([registry_db_spec/0]).
-export([start_link/0]).
-export([table/1]).
-export([table_names/1]).
-export([tables/0]).
-export([fold_type/1]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Starts the catalogue process (a `bondy_sup` child).".
-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Returns the declarative specs for all sixteen tables (both DBs), mirroring the
`bondy_db_tables.hrl` prefixes. The single source of truth for the catalogue.
""".
-spec tables() -> [table_spec()].

tables() ->
    [
        %% main — durable (leveled, shared_shards)
        %% bondy_realm — unlike the per-realm tables this is a GLOBAL registry:
        %% every realm shares one band (the empty binary) keyed by its Uri.
        %% Under the aggregate partition strategy the shard hash includes the
        %% Uri, so realms spread across shards while a single
        %% `bondy_db:list/2` over the band scatter-scans them all. Local
        %% lifecycle is inline in bondy_realm; `publish => true` wires the remote
        %% on_merge seam so a peer's realm delete closes this node's sessions for
        %% that realm (the reactor is `bondy_aae_reactor`).
        #{
            name => ?BONDY_DB_REALM_TAB,
            db => main,
            durability => durable,
            fold => lww,
            publish => true
        },
        %% bondy_realm_keys — the realm's signing/encryption key material, split
        %% OUT of the realm identity cell so the realm's bondy_db identity (and
        %% its cross-node convergence) is the Uri + config, never the random key
        %% bytes.
        %% A GLOBAL registry like bondy_realm (constant band, keyed by Uri).
        %% `aw` (add-wins map of `kid => key bundle`): key rotation mints a fresh
        %% kid, so concurrent rotations on different nodes add distinct entries
        %% that merge without loss. Storage-only (no reactor): peers read the
        %% merged keyset on demand.
        #{
            name => ?BONDY_DB_REALM_KEYS_TAB,
            db => main,
            durability => durable,
            fold => aw
        },
        %% security_users — local lifecycle side-effects fire inline in
        %% bondy_rbac_user; `publish => true` wires the remote on_merge seam so
        %% a peer's user delete / credential change closes this node's sessions
        %% for that user (`bondy_aae_reactor:react_user/3` — the delete closes
        %% with `bondy.user.deleted`, a credential-material set-diff with
        %% `bondy.user.credentials_changed`).
        #{
            name => ?BONDY_DB_USER_TAB,
            db => main,
            durability => durable,
            fold => lww,
            publish => true,
            indexes => user_indexes()
        },
        %% security_groups — local lifecycle events fire inline in
        %% bondy_rbac_group; `publish => true` wires the remote on_merge seam so
        %% a peer's change to a group's PARENT groups invalidates this node's
        %% cached RBAC contexts (`bondy_aae_reactor:react_group/2`). The parent
        %% list is a role-inheritance edge and a cached context bakes in the
        %% grants it resolves to, so without this a revoked inheritance is
        %% honoured only when the context expires.
        #{
            name => ?BONDY_DB_GROUP_TAB,
            db => main,
            durability => durable,
            fold => lww,
            publish => true
        },
        %% security_group_members — the AUTHORITATIVE group-membership relation.
        %% Membership is cell-per-fact, add-wins: each `(user, group)` fact is an
        %% `ew_flag` (enable-wins) presence cell, so a concurrent add survives a
        %% remove that did not observe it. Every fact is stored in BOTH key
        %% orderings (a forward `f` band keyed `enc(user) ⊕ enc(group)` and a
        %% reverse `r` band keyed `enc(group) ⊕ enc(user)`) so "groups of a user"
        %% and "members of a group" are each a bounded, realm-local key-range
        %% scan with no secondary index — the permutation-index pattern. The
        %% read/write primitives live in `bondy_rbac_user`. `publish => true`
        %% wires the remote `on_merge` seam so a peer's membership change merged
        %% via anti-entropy invalidates this node's cached RBAC contexts for the
        %% realm in place (reactor `bondy_aae_reactor:react_member/2`), exactly as
        %% grants do. token_version still advances on a membership change because
        %% the write path also touches the user cell.
        #{
            name => ?BONDY_DB_GROUP_MEMBERS_TAB,
            db => main,
            durability => durable,
            %% Co-locate each fact with its leading ENTITY (the 2nd column of the
            %% band-tagged key): a forward `[?MEMBER_FWD, User, Group]` cell lands
            %% on the user record's aggregate shard, a reverse
            %% `[?MEMBER_REV, Group, User]` cell on the group record's. So a
            %% user's groups (hot auth path + list-page join) and a group's
            %% members are each a single-shard band scan, not a cross-shard
            %% scatter. Without this the `identity` default routes every fact by
            %% its whole key ⇒ scatter. (`bondy_db:aggregate_root/2`.)
            aggregate_root => second_col,
            fold => ew,
            publish => true
        },
        %% security_{group,user}_grants — `publish => true` wires the remote
        %% on_merge seam so a peer's grant / revoke (a `set` / `clear` arriving
        %% via anti-entropy) invalidates this node's cached RBAC contexts for the
        %% realm in place (reactor `bondy_aae_reactor`) — an authorization change
        %% re-evaluates on the next authorize, it does NOT tear the session down
        %% (that is reserved for authn-level changes). Local grant / revoke
        %% already invalidates inline in bondy_rbac, so the reactor ignores the
        %% local event tag and acts only on the remote merge tag.
        %% Declared `mv` (sibling-preserving) but cut as `lww`: mv only differs
        %% from lww under concurrent multi-node grant edits, which anti-entropy
        %% reconciles, so honouring mv is deferred. The compound
        %% `{Rolename, Resource}` key is an order-preserving composite
        %% (`bondy_rbac:encode_key/1`) so the forward "grants for role" query is a
        %% bounded role-band range scan; the `by_resource` index provides the
        %% equality reverse lookup "grants on resource R" (see `grant_indexes/0`).
        #{
            name => ?BONDY_DB_GROUP_GRANT_TAB,
            db => main,
            durability => durable,
            %% aggregate root = the Rolename (group) leading the composite key,
            %% so a group's grants co-locate with the group record on one shard.
            aggregate_root => leading_col,
            fold => lww,
            publish => true,
            indexes => grant_indexes()
        },
        #{
            name => ?BONDY_DB_USER_GRANT_TAB,
            db => main,
            durability => durable,
            %% aggregate root = the Rolename (username) leading the composite key,
            %% so a user's grants co-locate with the user record on one shard +
            %% Bookie (cheaper RBAC joins; subjects still spread across shards).
            %% NOTE: this is locality, NOT cross-table atomicity — the records
            %% live in separate per-table oplog instances. token_version
            %% revocation relies on the anti-entropy fence, not an atomic batch.
            aggregate_root => leading_col,
            fold => lww,
            publish => true,
            indexes => grant_indexes()
        },
        %% security_sources — storage-only, same lww-defer as grants (declared
        %% mv → cut lww; honouring mv deferred). The compound `{Username, AMask,
        %% Authmethod}` key is an order-preserving composite
        %% (`bondy_rbac_source:encode_key/1`) so the forward "sources for user"
        %% match (on the auth path) is a bounded username-band range scan. The
        %% reverse by-mask lookup is deferred (the stored `cidr` differs from the
        %% key's anchor-mask, and CIDR matching is containment, not equality).
        #{
            name => ?BONDY_DB_SOURCE_TAB,
            db => main,
            durability => durable,
            %% aggregate root = the Username leading the composite key, so a
            %% user's sources co-locate with the user record (auth-path locality).
            aggregate_root => leading_col,
            fold => lww,
            %% `publish => true` wires the merge-side lww conflict alarm
            %% (`bondy_aae_reactor:react_source/4`) — sources stay lww, so a
            %% remote merge clobbering a concurrent local edit must at least
            %% be observable.
            publish => true
        },
        %% api_gateway — publishes change events so the cowboy-dispatch reactor
        %% rebuilds on local + AE-replicated spec writes.
        #{
            name => api_gateway,
            db => main,
            durability => durable,
            fold => lww,
            publish => true
        },
        %% ticket / oauth_token shard by key — creation + point lookup are
        %% prioritised over listing / range. Storage-only (no `publish` —
        %% revocation is inline; nothing subscribes to ticket/token changes).
        #{
            name => ?BONDY_DB_TICKET_TAB,
            db => main,
            durability => durable,
            fold => lww
        },
        #{
            name => ?BONDY_DB_OAUTH_TOKEN_TAB,
            db => main,
            durability => durable,
            fold => lww
        },
        %% bridge_relay — storage-only (no `publish`): bridge config has no
        %% change reactor — `bondy_bridge_relay_manager` reads it once at boot
        %% and runs only its OWN node's bridges (`nodestring` filter), so it
        %% needs no cluster-wide change notification.
        #{
            name => bondy_bridge_relay,
            db => main,
            durability => durable,
            fold => lww
        },
        %% retained_messages — the WAMP retained-event store. A DURABLE main
        %% table regardless of the legacy `wamp.message_retention.storage_type`
        %% knob (now inert): the operator decision is that retained messages
        %% always survive a restart. The feature is gated per-publish by the
        %% `retain` option, not at provisioning. Storage-only `lww`: the per-realm
        %% count / memory counters are maintained inline at the local write
        %% sites; the remote-replication counter sync is deferred until
        %% anti-entropy reconciles the counters. Keyed by Topic and matched via
        %% key-ordered `range_all/5` prefix / wildcard scans (no secondary index).
        #{
            name => retained_messages,
            db => main,
            durability => durable,
            fold => lww
        },
        %% bondy_interface — interface metadata (procedure/topic/error
        %% descriptions and schemas), the store WAMP Interface Reflection
        %% reads and the MCP manifest projects from. Keyed per realm by
        %% {Kind, MatchPolicy, Uri} — release-cadence data, whole-entry
        %% replacement, so `lww` with the identity routing default.
        %% `publish => true` feeds the MCP manifest cache
        %% (`bondy_mcp_gateway`), which invalidates its compiled per-realm
        %% manifests on local + AE-replicated interface writes. That
        %% consumer is started ON DEMAND (first `manifest/1` call —
        %% `bondy_mcp_sup` runs nothing by default) and reconciles on
        %% attach, so `missed_events => recovered_on_attach`. (`publish`
        %% is a runtime knob, not part of the frozen topology, so wiring it
        %% here is not a manifest divergence.) NOTE for readers of
        %% `bondy_db_manifest`: this was the first table added AFTER the
        %% topology freeze existed — an upgraded data dir adopts it through
        %% the manifest's additive-extension path
        %% (`{extended, [bondy_interface]}`), which is what keeps its AAE
        %% fingerprint equal to a freshly provisioned node's.
        #{
            name => ?BONDY_DB_INTERFACE_TAB,
            db => main,
            durability => durable,
            fold => lww,
            publish => true,
            missed_events => recovered_on_attach
        },
        %% mcp_gateway — the MCP overlay documents (design §18.3): one key
        %% per loaded document in a single flat bucket, the stored value the
        %% SOURCE map (never a parsed form), same posture as `api_gateway`.
        %% `publish => true` feeds the same on-demand manifest-cache
        %% reactor as `bondy_interface` above (hence the same
        %% `missed_events` class). Rides the manifest additive-extension
        %% path on upgraded data dirs, like every table added post-freeze.
        #{
            name => ?BONDY_DB_MCP_GATEWAY_TAB,
            db => main,
            durability => durable,
            fold => lww,
            publish => true,
            missed_events => recovered_on_attach
        },
        %% mcp_upstream — pinned upstream MCP tool definitions (design
        %% §13.3): banded by realm, keyed {UpstreamName, ToolName}, the
        %% value the pinned definition plus its canonical-JSON hash.
        %% Whole-entry replacement on approval, so `lww`. No `publish`:
        %% pins gate the projection of upstream tools into the registry
        %% and never feed the manifest cache. Rides the manifest
        %% additive-extension path on upgraded data dirs, like every
        %% table added post-freeze.
        #{
            name => ?BONDY_DB_MCP_UPSTREAM_TAB,
            db => main,
            durability => durable,
            fold => lww
        },

        %% registry RIB — ephemeral (ETS projection, mem WAL, memory topology —
        %% NO durable or disk-backed storage), the replicated routing summary
        %% cells: one cell per (Realm, MatchPolicy, Uri, Node) carrying
        %% `#{invoke, count, earliest, latest}` (registrations) or `#{count}`
        %% (subscriptions). Only the node named in the key ever writes the
        %% cell — single-writer by construction. `count`/`invoke`/`earliest`/
        %% `latest` are backed by per-field CRDTs (`fold =>
        %% rib_registration`/`rib_subscription` resolve to
        %% `bondy_oplog_crdt_struct`, schema `?RIB_REGISTRATION_SCHEMA`, and a
        %% bare `bondy_oplog_crdt_pn_counter` respectively — registered
        %% directly, no per-use-case wrapper module) rather than one opaque
        %% LWW blob, so `bondy_registry_rib`'s entry-add/remove hooks write
        %% small, lock-free, targeted deltas directly — no per-realm
        %% recompute/serialisation point. `publish => true` wires the
        %% merge-side hook: `bondy_aae_reactor` delegates merged peer cells to
        %% `bondy_registry_rib`, which maintains the local stub view routing
        %% consumes. These cells are the ONLY replicated registry state — full
        %% `#entry{}` records never enter `bondy_db`; they live in
        %% `bondy_registry_store`'s partition-local ETS. Maintained by
        %% `bondy_registry_rib`.
        #{
            name => ?BONDY_DB_REGISTRATION_RIB_TAB,
            db => registry,
            durability => ephemeral,
            fold => rib_registration,
            publish => true
        },
        #{
            name => ?BONDY_DB_SUBSCRIPTION_RIB_TAB,
            db => registry,
            durability => ephemeral,
            fold => rib_subscription,
            publish => true
        }
    ].

-doc """
The `main` DB declaration: durable shared-shards over leveled, with a
deployment-configurable shard count (`db.main.shard_count`, default 16).
""".
-spec main_db_spec() -> map().

main_db_spec() ->
    #{
        name => main,
        topology => bondy_db_topology_shared_shards,
        durability => durable,
        shard_count => bondy_db_config:oplog_shard_count(main),
        partition_strategy => bondy_db_config:oplog_partition_strategy(main),
        realm_prefix_depth => bondy_db_config:oplog_realm_prefix_depth(main)
    }.

%% @private
%% Assemble the frozen keying configuration for the durable `main` DB: the
%% subset of config that determines on-disk key placement and is therefore
%% re-key-on-change. The catalogue supplies the deployment choices
%% (partition_strategy / shard_count / realm_prefix_depth) and each main
%% table's routing key (`aggregate_root`); the substrate invariants (hash
%% function, key-encoding version) are stamped by `bondy_db_manifest`.
main_topology_freeze() ->
    Spec = main_db_spec(),
    Tables = maps:from_list([
        {
            maps:get(name, S),
            #{
                aggregate_root => maps:get(aggregate_root, S, identity)
            }
        }
     || #{db := main} = S <- tables()
    ]),
    #{
        db => main,
        topology_module => maps:get(topology, Spec),
        partition_strategy => maps:get(partition_strategy, Spec),
        shard_count => maps:get(shard_count, Spec),
        realm_prefix_depth => maps:get(realm_prefix_depth, Spec),
        tables => Tables
    }.

-doc """
The `registry` DB declaration: ephemeral ETS, with the four explicit knobs
that pin the whole stack in-memory and avoid the disk-WAL footgun.
""".
-spec registry_db_spec() -> map().

registry_db_spec() ->
    #{
        name => registry,
        topology => bondy_db_topology_memory,
        durability => ephemeral,
        shard_count => bondy_db_config:oplog_shard_count(registry),
        %% The ephemeral knobs, applied per-table at open time.
        table_opts => #{
            projection_backend => ets,
            oplog_instance_opts => #{
                backend => ets,
                wal_backend => mem,
                durability => ephemeral,
                %% Retention-bounded MST history (`db.registry.retention.*`,
                %% defaults 30s / 50K events per shard). The registry's
                %% event history is pure RAM (memory topology) and the
                %% all-peer-confirmed compaction frontier cannot keep pace
                %% under sustained subscribe/register load, so each shard
                %% bounds its own history locally; a peer that misses
                %% truncated history recovers via catalogue bootstrap.
                mst_retention => bondy_db_config:oplog_mst_retention(registry)
            },
            fused => true
        }
    }.

-doc """
The `bondy_db:open_table/3` options that wire a table's fold class to its
native CRDT — the per-table "WAMP fold module" selection. These map what
`tables/0` declares:

- `lww` → `lww_register` (set / clear, highest-HLC wins): most tables —
  realm, user and group records, grants and sources (declared `mv` in the
  design, deliberately cut as `lww`; see the deferral note on their
  specs), the API gateway spec, tickets, tokens, bridge relays, retained
  messages, and the registry tables.
- `aw`  → `lww_register` carrier + the `aw_map` CRDT: a single-cell
  add-wins map — `bondy_realm_keys` (key rotation mints fresh kids, so
  concurrent rotations union without loss).
- `ew`  → `lww_register` carrier + the `ew_flag` CRDT: cell-per-fact group
  membership (`security_group_members`). Each membership fact is an
  enable-wins presence cell, so a concurrent add survives a remove that
  did not observe it (add-wins). See `bondy_rbac_user`'s membership
  relation.
- `mv`  → `lww_register` carrier + the `mv_register` CRDT: reserved — no
  current table uses it (grants and sources are the intended consumers if
  their lww deferral is ever revisited).
- `rib_registration` / `rib_subscription` → `lww_register` carrier +
  `bondy_oplog_crdt_struct` (schema `?RIB_REGISTRATION_SCHEMA`, passed as
  `crdt_opts` — the struct has no schema of its own) /
  `bondy_oplog_crdt_pn_counter`, registered directly (no per-use-case
  wrapper module): the registry RIB tables (see `tables/0`). The raw
  projected value is NOT the external `#{invoke, count, earliest,
  latest}` / `#{count}` summary shape read-side consumers expect —
  `bondy_registry_rib:reshape_summary/2` derives it at every read call
  site, immediately after the raw read/list. `bondy_registry_rib`'s write
  path is lock-free per-field deltas, not a serialised recompute-from-
  scratch whole-blob write.

`mv_register` / `aw_map` / `ew_flag` / the two RIB CRDTs have no short
fold alias in `bondy_oplog_cell_kernel`, so they are passed as an
explicit `crdt_module` (the `fold_module` stays `lww_register`, their
byte-compatible carrier). `presence` has no current table — the registry
tables converge as `rib_registration`/`rib_subscription` now (see
`tables/0`) — and has no mapping yet.
""".
-spec fold_opts(fold_class()) -> map().

fold_opts(lww) ->
    #{fold_module => lww_register};
fold_opts(mv) ->
    #{fold_module => lww_register, crdt_module => ?MV_CRDT};
fold_opts(aw) ->
    #{fold_module => lww_register, crdt_module => ?AW_CRDT};
fold_opts(ew) ->
    #{fold_module => lww_register, crdt_module => ?EW_CRDT};
fold_opts(rib_registration) ->
    #{
        fold_module => lww_register,
        crdt_module => bondy_oplog_crdt_struct,
        crdt_opts => ?RIB_REGISTRATION_SCHEMA
    };
fold_opts(rib_subscription) ->
    #{fold_module => lww_register, crdt_module => bondy_oplog_crdt_pn_counter};
fold_opts(presence) ->
    %% Reserved presence-FSM fold — no current table uses it (the registry
    %% tables converge as `lww`); no mapping yet.
    error({not_yet_supported, presence}).

-doc """
The declared `fold` type of table `Name`, or `undefined` when no table
declares that name.

A cell's fold type IS the language its writes are expressed in — an `lww`
register takes `{set, V}`, an `ew` flag takes `enable` / `disable`, an `aw` map
takes `{put, K, V}` / `{rmv, K}`. Any code that synthesises a write for a table
it does not know statically (`bondy_export`'s import) must ask for the type
rather than assume the register form: the applier SKIPS a cell whose operation
its CRDT cannot interpret and carries on, so a wrong operation is a silent
loss, not an error.
""".
-spec fold_type(Name :: atom()) -> fold_class() | undefined.

fold_type(Name) ->
    case [F || #{name := N, fold := F} <- tables(), N == Name] of
        [Fold | _] -> Fold;
        [] -> undefined
    end.

-doc """
The durable database's name. Callers that need to filter or assert on
`tables/0`'s `db` field should call this instead of spelling `main`
literally — it is the single point that would change on a future rename.
""".
-spec main_db_name() -> db_name().

main_db_name() -> main.

-doc "The ephemeral database's name. See `main_db_name/0`.".
-spec registry_db_name() -> db_name().

registry_db_name() -> registry.

-doc "The published `main` DB handle, or `undefined` when not open.".
-spec main_db() -> bondy_db:db() | undefined.

main_db() ->
    persistent_term:get(?PT_DB(main), undefined).

-doc "The published ephemeral `registry` DB handle, or `undefined`.".
-spec registry_db() -> bondy_db:db() | undefined.

registry_db() ->
    persistent_term:get(?PT_DB(registry), undefined).

-doc "The published handle for table `Name`, or `undefined` when not open.".
-spec table(Name :: atom()) -> bondy_db:table() | undefined.

table(Name) when is_atom(Name) ->
    persistent_term:get(?PT_TABLE(Name), undefined).

-doc "The declared table names for `DbName`, in declaration order.".
-spec table_names(DbName :: db_name()) -> [atom()].

table_names(DbName) ->
    [maps:get(name, S) || S <- tables(), maps:get(db, S) =:= DbName].

-doc "Whether the `main` DB has been provisioned and published.".
-spec is_open() -> boolean().

is_open() ->
    main_db() =/= undefined.

-doc """
Whether the durable `main` DB is usable, distinguishing the two ways it can be
absent.

`idle` means there was nothing to provision — a legitimate configuration, and
NOT a fault. `failed` means opening it raised: every durable table will reject
use, so the node must not report itself ready. Keeping these apart is the whole
point; `is_open/0` returns `false` for both and so cannot drive a health probe.
""".
-spec main_status() -> open | idle | failed.

main_status() ->
    case persistent_term:get(?PT_MAIN_FAILED, undefined) of
        undefined ->
            case main_db() of
                undefined -> idle;
                _ -> open
            end;
        _Reason ->
            failed
    end.

-doc """
A summary of the catalogue: the `main` DB info and each main table's
`bondy_db:info/1` (or `not_open`).
""".
-spec info() -> map().

info() ->
    #{
        main =>
            case main_db() of
                undefined -> not_open;
                Db -> bondy_db:info(Db)
            end,
        tables => maps:from_list([
            {Name, table_info(Name)}
         || #{name := Name, db := main} <- tables()
        ])
    }.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    %% Trap exits so terminate/2 runs on supervised shutdown (to close the DBs)
    %% and so a leveled-sup crash surfaces as an EXIT message we can act on.
    process_flag(trap_exit, true),
    %% Provision the durable `main` and the ephemeral `registry` DBs
    %% independently — an open failure in one leaves it idle without
    %% affecting the other.
    State0 = open_main_into(#state{}),
    State = open_registry_into(State0),
    {ok, State}.

%% @private
open_main_into(State) ->
    case main_specs_to_open() of
        [] ->
            %% Nothing to provision — reachable only if `tables/0` is
            %% emptied of main specs.
            ?LOG_NOTICE(#{
                description =>
                    "bondy_db namespace catalogue idle; no main tables to "
                    "provision"
            }),
            State;
        Specs ->
            case do_open_main(Specs) of
                {ok, Db, Sup, Dir} ->
                    %% Every main table is now open, so every shared per-shard
                    %% instance has its full set of cell-apply buckets
                    %% registered. Release the founding instances' WAL-drain
                    %% gates (set via `drain_gated => true` in
                    %% `maybe_ephemeral_opts/2`) so each shared WAL replays with
                    %% a complete routing directory — no non-founding table's
                    %% cells are skipped. A no-op unless the main topology is
                    %% `per_shard`. See `bondy_db:start_draining/1`.
                    ok = bondy_db:start_draining(Db),
                    %% Now that the gates are open, run the secondary-index
                    %% cold-start that `open_table/3` deferred for the gated
                    %% tables: each barriers its (now ungated) primary drain and
                    %% trust-or-rebuilds from a fully-replayed primary.
                    ok = cold_start_main_indexes(Specs),
                    State#state{db = Db, leveled_sup = Sup, dir = Dir};
                {error, Reason} ->
                    %% Don't brick the node over a storage-open failure — the
                    %% process keeps running so an operator can inspect it and
                    %% the ephemeral registry still works. But the node MUST
                    %% NOT present itself as healthy: every durable table will
                    %% raise `*_not_provisioned` on use, so a readiness probe
                    %% that passes here just routes traffic at a node that can
                    %% serve none of it. Record the failure, raise an alarm,
                    %% and let `main_status/0` fail readiness.
                    ?LOG_ERROR(#{
                        description =>
                            "Failed to provision bondy_db main tables; "
                            "catalogue starting with main idle. The node will "
                            "report NOT READY until this is resolved.",
                        reason => Reason
                    }),
                    ok = set_main_failed(Reason),
                    State
            end
    end.

%% @private
%% Published through `persistent_term` (read on every readiness probe, written
%% once) and mirrored as an alarm so it surfaces wherever alarms already go.
set_main_failed(Reason) ->
    _ = persistent_term:put(?PT_MAIN_FAILED, Reason),
    _ =
        try
            alarm_handler:set_alarm(
                {
                    bondy_db_main_unavailable,
                    <<
                        "The durable `main` database could not be opened. "
                        "Durable operations will fail and this node reports "
                        "NOT READY."
                    >>
                }
            )
        catch
            _:_ -> ok
        end,
    ok.

%% @private
%% Run the deferred secondary-index cold-start for every opened main table. Called
%% AFTER `bondy_db:start_draining/1` has released the founding instances' WAL-drain
%% gates, so each table's `bondy_db:cold_start_table_indexes/1` barriers a now-
%% ungated, fully-replayed primary. A no-op for index-less tables and for tables
%% whose handle is absent (a partial provisioning failure already logged).
cold_start_main_indexes(Specs) ->
    lists:foreach(
        fun(#{name := Name}) ->
            case table(Name) of
                undefined ->
                    ok;
                Table ->
                    ok = bondy_db:cold_start_table_indexes(Table)
            end
        end,
        Specs
    ).

%% @private
open_registry_into(State) ->
    case registry_specs_to_open() of
        [] ->
            State;
        Specs ->
            case do_open_registry(Specs) of
                {ok, Db} ->
                    State#state{registry_db = Db};
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        description =>
                            "Failed to provision bondy_db registry tables; "
                            "catalogue starting with registry idle",
                        reason => Reason
                    }),
                    State
            end
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Sup, Reason}, #state{leveled_sup = Sup} = State) ->
    %% Our leveled sup died — stop so bondy_sup restarts us and re-opens.
    ?LOG_ERROR(#{
        description => "bondy_db main leveled supervisor died",
        reason => Reason
    }),
    {stop, {leveled_sup_died, Reason}, State#state{leveled_sup = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{db = Db, leveled_sup = Sup, registry_db = RegistryDb}) ->
    _ = close_main(Db, Sup),
    _ = close_registry(RegistryDb),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The main table specs to provision at boot: every declared main table.
main_specs_to_open() ->
    [S || #{db := main} = S <- tables()].

%% @private
%% The registry table specs to provision at boot: every declared registry
%% table.
registry_specs_to_open() ->
    [S || #{db := registry} = S <- tables()].

%% @private
do_open_main(Specs) ->
    Dir = main_dir(),
    case filelib:ensure_path(Dir) of
        ok ->
            do_open_main_reconciled(Specs, Dir);
        {error, Reason} ->
            %% A raise here crashes this `init/1` and takes `bondy_sup` — and
            %% the node — down with it, so an unusable main directory must
            %% flow into `open_main_into/1`'s degrade branch like any other
            %% open failure. `bondy_degraded_boot_SUITE` boots a node with a
            %% regular file squatting on this path.
            {error, {ensure_path, Dir, Reason}}
    end.

%% @private
do_open_main_reconciled(Specs, Dir) ->
    %% Reconcile the configured keying topology against the on-disk manifest
    %% BEFORE opening anything. `Effective` is the topology the data is
    %% actually keyed under — the configured one at genesis, otherwise whatever
    %% the manifest froze — and the DB + tables are opened from it so a
    %% mismatched new config is detected (and, under `warn`, NOT applied).
    Configured = main_topology_freeze(),
    case
        bondy_db_manifest:reconcile(
            Dir, Configured, bondy_db_config:oplog_on_topology_mismatch(main)
        )
    of
        {ok, _Decision, Effective} ->
            do_open_main(Specs, Dir, Effective);
        {error, topology_mismatch} ->
            %% Operator chose fail-fast (db.main.on_topology_mismatch = stop):
            %% refuse to boot rather than mis-serve. reconcile/3 already logged
            %% the diverging keys; crashing init halts the node.
            error({bondy_db_topology_mismatch, Dir});
        {error, _} = Err ->
            Err
    end.

%% @private
do_open_main(Specs, Dir, Effective) ->
    ShardCount = maps:get(shard_count, Effective),
    EffTables = maps:get(tables, Effective),
    case bondy_db_leveled_sup:start_link() of
        {ok, Sup} ->
            DbOpts = #{
                topology => maps:get(topology_module, Effective),
                topology_opts => #{sup => Sup, dir => Dir},
                shard_count => ShardCount,
                partition_strategy => maps:get(partition_strategy, Effective),
                realm_prefix_depth => maps:get(realm_prefix_depth, Effective),
                %% DB default fold; mv tables override via per-table crdt_module.
                fold_module => lww_register
            },
            case bondy_db:open(main, DbOpts) of
                {ok, Db} ->
                    ok = put_db(main, Db),
                    %% Publish this node's keying-topology fingerprint (over the
                    %% EFFECTIVE on-disk topology) so anti-entropy peers can
                    %% verify they key data the same way before syncing per-shard
                    %% MST roots — mismatched topologies are refused, not
                    %% silently diverged.
                    ok = bondy_oplog:set_topology_fingerprint(
                        main, bondy_db_manifest:fingerprint(Effective)
                    ),
                    case open_tables(Db, Specs, EffTables) of
                        ok ->
                            ?LOG_NOTICE(#{
                                description =>
                                    "bondy_db main tables provisioned",
                                count => length(Specs),
                                tables => [maps:get(name, S) || S <- Specs],
                                shard_count => ShardCount,
                                dir => Dir
                            }),
                            {ok, Db, Sup, Dir};
                        {error, _} = Err ->
                            _ = close_main(Db, Sup),
                            Err
                    end;
                {error, _} = Err ->
                    _ = stop_sup(Sup),
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
%% Provision the ephemeral `registry` DB (memory topology — no leveled sup or
%% on-disk dir) and its tables. The per-table ephemeral knobs
%% (projection_backend / oplog_instance_opts / fused) ride in via `table_opts/1`
%% from `registry_db_spec/0`.
do_open_registry(Specs) ->
    Spec = registry_db_spec(),
    ShardCount = maps:get(shard_count, Spec),
    DbOpts = #{
        topology => maps:get(topology, Spec),
        shard_count => ShardCount,
        %% DB default fold (lww); the memory topology hosts the ETS projection.
        fold_module => lww_register,
        %% Pin the WAL in-memory at the DB level too; the per-table
        %% `oplog_instance_opts` (registry_db_spec/0) carry the full ephemeral
        %% knobs and replace this at open_table time.
        oplog_instance_opts => #{wal_backend => mem, durability => ephemeral}
    },
    case bondy_db:open(registry, DbOpts) of
        {ok, Db} ->
            ok = put_db(registry, Db),
            case open_tables(Db, Specs) of
                ok ->
                    ?LOG_NOTICE(#{
                        description => "bondy_db registry tables provisioned",
                        count => length(Specs),
                        tables => [maps:get(name, S) || S <- Specs],
                        shard_count => ShardCount
                    }),
                    {ok, Db};
                {error, _} = Err ->
                    _ = close_registry(Db),
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% @private
%% Registry path: ephemeral tables have no manifest, so they open straight from
%% their declared spec (no effective-topology override).
open_tables(_Db, []) ->
    ok;
open_tables(Db, [#{name := Name} = Spec | Rest]) ->
    case bondy_db:open_table(Db, Name, table_opts(Spec)) of
        {ok, Table} ->
            ok = put_table(Name, Table),
            open_tables(Db, Rest);
        {error, _} = Err ->
            Err
    end.

%% @private
%% Main path: open each durable table from its EFFECTIVE routing keys — the
%% on-disk manifest's, which equal the configured ones unless a warn-mismatch
%% pinned the old topology. `EffTables` maps each TableName to
%% `#{aggregate_root => _}`; a table absent from it (should not happen for
%% main) falls back to its declared spec values via `table_opts/2`.
open_tables(_Db, [], _EffTables) ->
    ok;
open_tables(Db, [#{name := Name} = Spec | Rest], EffTables) ->
    Override = maps:get(Name, EffTables, #{}),
    case bondy_db:open_table(Db, Name, table_opts(Spec, Override)) of
        {ok, Table} ->
            ok = put_table(Name, Table),
            open_tables(Db, Rest, EffTables);
        {error, _} = Err ->
            Err
    end.

%% @private
%% Closes every open main table, the DB, and the leveled sup; clears the
%% published handles. Tolerant of partial state (any of Db / Sup undefined).
close_main(Db, Sup) ->
    _ = [
        begin
            _ =
                try
                    bondy_db:close_table(T)
                catch
                    _:_ -> ok
                end,
            _ = persistent_term:erase(?PT_TABLE(Name))
        end
     || #{name := Name, db := main} <- tables(),
        T <- [table(Name)],
        T =/= undefined
    ],
    _ =
        case Db of
            undefined ->
                ok;
            _ ->
                _ =
                    try
                        bondy_db:close(Db)
                    catch
                        _:_ -> ok
                    end,
                persistent_term:erase(?PT_DB(main))
        end,
    _ = stop_sup(Sup),
    ok.

%% @private
%% Closes every open registry table and the registry DB; clears the published
%% handles. The memory topology owns no leveled sup / on-disk dir, so this is
%% simpler than close_main/2. Tolerant of `undefined` (registry idle).
close_registry(undefined) ->
    ok;
close_registry(Db) ->
    _ = [
        begin
            _ =
                try
                    bondy_db:close_table(T)
                catch
                    _:_ -> ok
                end,
            _ = persistent_term:erase(?PT_TABLE(Name))
        end
     || #{name := Name, db := registry} <- tables(),
        T <- [table(Name)],
        T =/= undefined
    ],
    _ =
        try
            bondy_db:close(Db)
        catch
            _:_ -> ok
        end,
    _ = persistent_term:erase(?PT_DB(registry)),
    ok.

%% @private
stop_sup(undefined) ->
    ok;
stop_sup(Sup) when is_pid(Sup) ->
    try
        bondy_db_leveled_sup:stop(Sup)
    catch
        _:_ -> ok
    end,
    ok.

%% @private
%% Maps a table spec to its `bondy_db:open_table/3` opts: the fold→CRDT wiring
%% (see `fold_opts/1`), `publish` for tables with a change reactor, any declared
%% secondary `indexes`, and the routing key `aggregate_root`
%% (identity | leading_col | second_col) consumed by strategy-aware shard
%% routing. `aggregate_root` defaults to `identity`, reproducing the legacy
%% `phash2({EntityType, Key})` placement for a table that declares nothing.
table_opts(Spec) ->
    table_opts(Spec, #{}).

%% @private
%% As `table_opts/1`, but the routing key `aggregate_root` is taken from
%% `Override` (the effective per-table topology from the manifest) when
%% present, falling back to the declared spec otherwise. Registry tables
%% pass `#{}` (no manifest), so they keep their declared values.
table_opts(#{fold := Class} = Spec, Override) ->
    Opts0 = fold_opts(Class),
    Opts1 =
        case maps:get(publish, Spec, false) of
            true -> Opts0#{publish => true};
            false -> Opts0
        end,
    Opts2 =
        case maps:get(indexes, Spec, []) of
            [] -> Opts1;
            Indexes -> Opts1#{indexes => Indexes}
        end,
    Opts3 = Opts2#{
        aggregate_root =>
            maps:get(
                aggregate_root,
                Override,
                maps:get(aggregate_root, Spec, identity)
            )
    },
    maybe_ephemeral_opts(Spec, Opts3).

%% @private
%% Registry (ephemeral, memory-topology) tables carry the in-RAM projection /
%% WAL knobs at the DB-spec level (registry_db_spec/0); merge them under the
%% fold + index opts (the key sets are disjoint). Main tables pass through.
maybe_ephemeral_opts(#{db := registry}, Opts) ->
    maps:merge(maps:get(table_opts, registry_db_spec()), Opts);
maybe_ephemeral_opts(#{db := main, durability := durable}, Opts) ->
    %% Make each durable main table's per-shard WAL + MST pack durable, rooted
    %% under the data dir (collocated with the leveled projection) instead of
    %% the ephemeral `/tmp` fallback (which abandons fsynced frames on restart
    %% and keeps no MST pack on disk). Without this the DB-level
    %% `durability => durable` never reaches the oplog instances.
    %%
    %% The MST pack store (`storage_path`) and the WAL (`wal_dir`) live in their
    %% own sibling subtrees alongside the leveled `main' dir — see
    %% `bondy_db_dir/0`. An explicit `wal_dir` (rather than letting the WAL
    %% default to a `wal/' dir *under* the pack instance dir) keeps the WAL leaf
    %% at `wal/<InstanceId>' (`wal/main/<ET>/<Shard>') instead of the doubly
    %% nested `mst/.../<InstanceId>/wal/<InstanceId>'. The pack store keeps the
    %% default `sharded' path layout (`mst/<hash>/<hash>/<InstanceId>'); `flat'
    %% is unsafe here because the slash-bearing `InstanceId' makes the
    %% pack-store's shard-dir derivation double-nest the pack away from its
    %% manifest.
    %%
    %% `seed => true` starts each instance live as a genesis peer and writes a
    %% durable `lifecycle.live` flag that survives restart. A fresh persistent
    %% instance with the default `seed => false` would instead block in
    %% `pre_bootstrap` waiting for a live peer to bootstrap from — which a single
    %% node never has. Under multi-node AAE every node genesis-seeds and the lww
    %% merge reconciles their cells (proven by `bondy_aae_cluster_SUITE`).
    %% `drain_gated => true` founds each shared per-shard instance with its WAL
    %% drain deferred. The `main` DB collapses every table onto N shard
    %% instances (one WAL each); the first table opened on a shard founds the
    %% instance and the rest register their cell-apply buckets as they open. A
    %% founding instance that drained at init — before its siblings registered —
    %% would skip (and, since the MST install is unconditional, LOSE) every
    %% not-yet-registered table's WAL-tail cells on restart. `provision/1`
    %% releases the gate via `bondy_db:start_draining/1` AFTER all main tables
    %% are open. See `bondy_db:start_draining/1` and the applier `drain_gate`.
    Opts#{
        oplog_instance_opts => #{
            backend => bondy_mst_pack_store,
            storage_path => main_mst_dir(),
            wal_dir => main_wal_dir(),
            seed => true,
            %% WAL fsync/rotation knobs (`db.wal.*`) — read here rather than
            %% defaulting inside `bondy_oplog_wal` so an operator override
            %% reaches the writer; the ephemeral `registry` DB never sets
            %% these (its WAL is in-memory and never fsyncs).
            fsync_mode => bondy_oplog_config:wal_fsync_mode(),
            max_segment_bytes => bondy_oplog_config:wal_max_segment_bytes(),
            batched_fsync_interval =>
                bondy_oplog_config:wal_batched_fsync_interval_ms(),
            batched_fsync_bytes => bondy_oplog_config:wal_batched_fsync_bytes(),
            %% `log_boot_replay` emits one NOTICE when each durable main shard
            %% begins reading its WAL at boot and one when that replay reaches
            %% end-of-log — so a node's boot shows it reading each WAL.
            applier => #{drain_gated => true, log_boot_replay => true}
        }
    };
maybe_ephemeral_opts(_Spec, Opts) ->
    Opts.

%% @private
%% The `security_users` secondary indexes.
%%
%% Empty since membership left the user cell: both the forward ("groups of a
%% user") and reverse ("members of a group") access paths are bounded key-range
%% scans over the cell-per-fact `security_group_members` relation (see
%% `bondy_rbac_user`), so no `by_group` index on `security_users` is needed.
user_indexes() ->
    [].

%% @private
%% The equality reverse index for grants: "which roles have a grant on
%% resource R". The grant cell value is the fact map
%% `#{resource => Resource, permissions => [_]}` (reshaped from the bare
%% permissions list precisely so the resource column is reachable from the
%% value), and `normalize => canonical` maps the structured resource
%% (`any | {Uri, Strategy}`) to its deterministic binary so the lookup term
%% matches byte-for-byte. The reverse read (`bondy_rbac:grants_on_resource/2`)
%% decodes each hit's primary key to recover the role. Both grant tables share
%% the same `by_resource` name; co-located/per-table index scoping keeps them
%% distinct.
grant_indexes() ->
    [#{name => by_resource, extract => [resource], normalize => canonical}].

%% @private
table_info(Name) ->
    case table(Name) of
        undefined -> not_open;
        Table -> bondy_db:info(Table)
    end.

%% @private
%% Root of the on-disk layout for all bondy_db data, configurable via the
%% `platform_data_dir' schema knob. The durable `main' DB keeps its three
%% storage components in sibling subtrees under here:
%%
%%   <data>/bondy_db/main   leveled projection      (shards `main/0'..`main/N')
%%   <data>/bondy_db/mst    MST pack store          (`mst/<InstanceId>/...')
%%   <data>/bondy_db/wal    write-ahead log         (`wal/<InstanceId>/...')
%%
%% with `InstanceId = main/<EntityType>/<Shard>'. `mst' and `wal' are siblings
%% of `main' (not nested under it), and `path_layout => flat' keeps each leaf at
%% `<base>/main/<ET>/<Shard>' rather than under opaque hash dirs.
bondy_db_dir() ->
    DataDir = application:get_env(bondy_router, platform_data_dir, "data"),
    filename:join([DataDir, "bondy_db"]).

%% @private
main_dir() ->
    filename:join([bondy_db_dir(), "main"]).

%% @private
main_mst_dir() ->
    unicode:characters_to_binary(filename:join([bondy_db_dir(), "mst"])).

%% @private
main_wal_dir() ->
    unicode:characters_to_binary(filename:join([bondy_db_dir(), "wal"])).

%% @private
put_db(Name, Db) ->
    persistent_term:put(?PT_DB(Name), Db),
    ok.

%% @private
put_table(Name, Table) ->
    persistent_term:put(?PT_TABLE(Name), Table),
    ok.
