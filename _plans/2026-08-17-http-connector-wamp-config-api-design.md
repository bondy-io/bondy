# HTTP Connector — WAMP configuration API

Design document. Status: approved for planning, not yet implemented.

Date: 2026-08-17

## 1. Problem

`bondy_http_connector` services are configured exclusively through
`bondy.conf`. The cuttlefish translation at `schema/bondy_http_connector.schema:833`
materialises `http_connector.services.$service.*` into
`application:get_env(bondy_http_connector, services)`, which
`bondy_http_connector_manager:init/1` reads once at boot
(`bondy_http_connector_manager.erl:111`). There is no runtime mutation path.

Changing a service therefore requires an operator to edit a file and restart the
node. This design adds a WAMP administration API so a Bondy web application can
create, update, delete and inspect connector services at runtime, and import a
JSON document of services, without touching `bondy.conf`.

## 2. Decisions

Each decision records what it rests on. Claims marked VERIFIED were established
by reading the named source; claims marked INTENDED are design intent whose
evidence must be produced by the implementation.

| # | Decision | Rationale |
|---|---|---|
| D-1 | Secrets are handled by **reference only** | Preserves the existing model: `bondy_secret_resolver` stores a `ref()` and fetches bytes on demand. Bondy never persists secret material, so redaction, encryption-at-rest and rotation stay out of scope. VERIFIED: `apps/bondy_stdlib/src/bondy_secret_resolver.erl:7-32`. |
| D-2 | Configuration is **cluster-wide and persisted** | Stored in `bondy_db`, replicated by AAE; every node applies the change and starts its own pool and callees. Matches today's semantics, where `bondy.conf` is deployed to every node. |
| D-3 | `conf` and `api` are **disjoint namespaces** | A service is owned by exactly one source. Neither can silently overwrite the other. Deliberately unlike `bondy_bridge_relay_manager.erl:206-214`, which deletes stored bridges that collide with conf-defined ones. |
| D-4 | Authorisation is **master realm only** | Consistent with every other administration API. VERIFIED: `bondy_wamp_api_utils.erl:167-176` restricts admin calls to `?MASTER_REALM_URI`. |
| D-5 | URI namespace is `bondy.http_connector.service.*` | Mirrors the OTP application name and the `http_connector.*` config prefix. |
| D-6 | `load/1` is **upsert**, never delete | A partial document cannot tear down services it does not mention. Matches `bondy.http_gateway.api.load`. |
| D-7 | Apply is **differential and jittered** | Only what changed is recycled, and nodes stagger so a live sibling keeps serving. |
| D-8 | `invoke` becomes **operator-selectable per procedure** | An internal callee has no principled reason to be second-class relative to an external one. Lands as its own increment. |
| D-9 | `http_connector.config_file` is included | A boot-time declarative JSON seed into the api-managed store. |

### Non-goals

- Storing secret material in Bondy (D-1).
- Per-realm delegation of service administration (D-4). The owning realm is not
  part of the stored record; adding it later is a data migration.
- Cluster-wide aggregation of `status/0`. It returns the calling node's view.
- Managing `bondy.conf`-defined services through the API (D-3).

## 3. Behaviour this design must describe honestly

A connector service's procedures are **served by one node at a time**, not
load-balanced across the cluster. VERIFIED, by the following chain:

1. `bondy_http_connector_callee.erl:276-282` registers with
   `bondy_ref:new(internal, MF, SessionId)` where
   `MF = {bondy_http_connector_callee_handler, handle_wamp_call}` — a *callback*
   ref.
2. `bondy_registry.erl:824-838` (`add_callback_registration/5`) overwrites
   `invoke` with `?INVOKE_SINGLE` unconditionally.
3. `bondy_registry_rib.erl:27-34` keeps peers' registrations as *stubs*, not as
   full entries in the local index. Each node's registration therefore succeeds
   independently — there is no cross-node `already_exists`.
4. `bondy_dealer.erl:2617-2624` performs node-stage selection over
   `self ++ stubs` via `bondy_rpc_load_balancer:select_node/2`.
5. `bondy_rpc_load_balancer.erl:269-274`: with `strategy = single` the winner is
   `extremal_unit(earliest, min, Units)` — the node holding the earliest
   registration always wins.

Consequence: siblings are hot standbys. Traffic moves only when
`prefer_reachable/1` (`bondy_dealer.erl:2660-2665`) finds the winner
unreachable. Documentation must say "failover", never "load balancing", until
increment 0 (§10) lands.

## 4. Layering

`bondy_db` sits below `bondy_router`. The connector depending on `bondy_db` is a
downward edge, and therefore cleaner than the undeclared upward edges the
connector already has into `bondy_dealer`, `bondy_registry`, `bondy_router`,
`bondy_session_manager` and `bondy_cert_manager`. Persistence therefore lives in
the connector application; only the WAMP handler lives in `bondy_router`, where
dispatch is.

| Module | App | Status | Role |
|---|---|---|---|
| `bondy_http_connector_service` | `bondy_http_connector` | new | Service type and persistence |
| `bondy_http_connector_manager` | `bondy_http_connector` | changed | Oplog subscription, debounce+jitter, diff, apply |
| `bondy_http_connector_sup` | `bondy_http_connector` | changed | Unconditional startup |
| `bondy_http_connector_http_pool_sup` | `bondy_http_connector` | changed | `stop_pool/1` |
| `bondy_http_connector_api` | `bondy_router` | new | `bondy_wamp_api` behaviour handler |
| `bondy_wamp_api` | `bondy_router` | changed | Dispatch clause |
| `bondy_namespace_catalog` | `bondy_router` | changed | Table declaration |
| `bondy_uris.hrl` | `bondy_router` | changed | URI macros |

`bondy_db` is added to `applications` in
`apps/bondy_http_connector/src/bondy_http_connector.app.src`.

## 5. Storage

One table, declared alongside `api_gateway` in
`bondy_namespace_catalog.erl` (see the existing entry at lines 309-316):

```erlang
%% http_connector_service — publishes change events so each node's connector
%% manager applies local + AE-replicated service writes.
#{
    name => http_connector_service,
    db => main,
    durability => durable,
    fold => lww,
    publish => true
}
```

`publish => true` is load-bearing: without it no `bondy_oplog_core_merge_event`
is emitted and replicated writes are invisible to peers.

Key: the service name (`binary()`). Value: the **validated source map**, not a
parsed or compiled form. Same reasoning as `bondy_http_gateway.erl:571-577` —
stored values must survive code upgrades.

## 6. Provenance

`source` is derived on every read, never accepted from a client and never
persisted:

- name present in `application:get_env(bondy_http_connector, services)` => `conf`
- name present in the `http_connector_service` table => `api`

Enforcement:

- `service.add` on a name in the conf set => `bondy.error.already_exists`
- `service.update`, `delete`, `enable`, `disable` on a conf name =>
  `bondy.error.read_only`, with a message naming `bondy.conf`
- At boot, a name present in **both**: the conf definition runs, an alarm is
  raised via `bondy_alarm_handler`, and the stored record is **left untouched**.
  Removing the name from `bondy.conf` restores the API definition on the next
  boot. This is the deliberate departure from
  `bondy_bridge_relay_manager.erl:206-214`, which deletes the stored record.

## 7. Validation

`bondy_http_connector_service:new/1` validates and normalises via
`maps_utils:validate/2` and is the only route by which a map becomes runnable.
The `bondy.conf` path is routed through it as well.

This is not only about avoiding drift between two code paths. Cuttlefish cannot
express cross-field constraints, so the conf path has no semantic validation
today: an invalid `auth.apply.placement`, or a `procedures.$proc.realm` naming a
realm that does not exist, currently reaches `register_one` and produces a
logged skip (`bondy_http_connector_callee.erl:294-300`). One validator gives the
conf path validation it has never had.

The validator covers, at minimum: `name`, `base_url`, `prefix`, `timeout`,
`retries`, `tls_verify`, `enabled`, `pool.*`, `liveness.*`,
`procedures.$proc.{uri, realm, method, path, invoke}`,
`auth.{fetch, apply, vars, secrets, cache}`. Field names and datatypes are taken
from `schema/bondy_http_connector.schema` so that a service map accepted by the
API is byte-identical in shape to one produced by the cuttlefish translation.

## 8. Lifecycle changes

**Unconditional startup.** `bondy_http_connector_sup:init/1` returns `[]` when
`services` is empty (`bondy_http_connector_sup.erl:52-66`), so a node booted
with no services has no manager to receive a `service.add`. Startup becomes
unconditional. Cost: four idle processes and one ETS table.

**Per-service handles.** The manager tracks
`#{{ServiceName, RealmUri} => Pid}` with monitors. `bondy_http_connector_callee_sup`
is `simple_one_for_one`, so a specific callee is stopped with
`supervisor:terminate_child(Sup, Pid)`. Pools register under their mangled name
(`bondy_http_connector_manager.erl:352-353`), so `stop_pool/1` resolves the pid
with `whereis/1` and terminates it the same way.

## 9. Apply path

The manager subscribes with `bondy_oplog_core:subscribe(Namespace, all)` and
handles both event shapes, exactly as `bondy_http_gateway.erl:291-302` does:

- `{bondy_oplog_core_event, _NS, Key, _Hlc, _Op}` — a local write
- `{bondy_oplog_core_merge_event, _NS, Key, _Hlc, _Op, _Old}` — a replicated write

On either, the changed name is noted and **one** timer is set:

```
Delay = DebounceMs + rand:uniform(JitterMs)
```

Debounce collapses bursts, so a `load` of twenty services produces one apply.
Jitter decorrelates nodes so they do not all recycle simultaneously. Two config
keys, both with defaults: `http_connector.apply_debounce` (default 250ms) and
`http_connector.apply_jitter` (default 2000ms).

When the timer fires, the manager diffs stored-versus-running per service:

| Changed | Action |
|---|---|
| `base_url`, `pool.*`, `tls_verify`, `liveness.*` | restart pool |
| `auth.*` | `bondy_http_connector_token_cache:invalidate/1`, re-resolve secrets, recycle callees |
| `procedures` for realm R | recycle callee(R) only |
| `enabled` | start or stop pool and callees |
| nothing | no-op |

An `auth` change forces a callee recycle because `register_one` freezes the auth
configuration into `callback_args => [FullProcConf]` at registration time
(`bondy_http_connector_callee.erl:276-281`); the registered closure would
otherwise keep stale credentials. VERIFIED by reading that call site.

Recycling a callee flushes its registrations: the callee's exit triggers the
session manager's `'DOWN'` handler, which calls `bondy_router:flush/2` ->
`bondy_dealer:flush/2` -> `bondy_registry:remove_all/5` keyed by `SessionId`.
VERIFIED: `bondy_http_connector_callee.erl:35-47` (moduledoc, "Cleanup").

Make-before-break is **not** available for `invoke = single`: a second
registration of the same URI on the same node reaches `resolve_duplicates/1` and
is rejected with `already_exists` (`bondy_registry.erl:941-957`). Jitter is
therefore the mechanism that preserves availability, not overlap.

## 10. Increments

Each increment lands and is verified in isolation before the next begins.

**Increment 0 — operator-selectable `invoke`.** Independent of the config API
and sequenced first, because it changes observable routing behaviour and must be
measured on its own.

- `bondy_registry.erl:835-838` stops *overriding* `invoke` and starts
  *defaulting* it to `?INVOKE_SINGLE` when absent.
- The existing duplicate guard is already sufficient:
  `find_registration_duplicates/2` (`bondy_registry.erl:1012-1027`) rejects a
  second registration of the same URI from the same session, and connector
  callee refs carry a session id. Refs with `session_id = undefined` — such as
  `bondy_session_manager.erl:420` — explicitly allow duplicates and are
  unaffected, since they keep the `single` default. VERIFIED by reading both.
- `schema/bondy_http_connector.schema` gains
  `http_connector.services.$service.procedures.$proc.invoke`, default `single`.
- The callee passes `shared_registration => true` when the policy is not
  `single`, as required by `maybe_add_registration/5`
  (`bondy_registry.erl:860-861`).

**Increment 1 — storage and validation.** Table declaration,
`bondy_http_connector_service` with `new/1` plus CRUD, conf path routed through
`new/1`, `bondy_db` added to app deps. No API, no reaction.

`schema/bondy_http_connector.schema` gains
`http_connector.services.$service.enabled` (default `on`). The field is used by
the validator (§7) and by the diff (§9), and without it a conf-defined service
has no way to express the state that `service.disable` sets on an api-defined
one.

**Increment 2 — unconditional startup and per-service handles.** Supervisor
change, `stop_pool/1`, manager pid tracking. No behaviour change visible to a
client.

**Increment 3 — apply path.** Oplog subscription, debounce+jitter, diff.
Exercised by writing to the table directly from a test.

**Increment 4 — WAMP API.** `bondy_http_connector_api`, dispatch clause, URI
macros, provenance enforcement.

**Increment 5 — `config_file`.** Boot-time seed (§12).

## 11. API surface

All procedures are master-realm only, via
`bondy_wamp_api_utils:validate_admin_call_args/3`.

```
bondy.http_connector.service.add(Service)        -> Service
bondy.http_connector.service.update(Name, Svc)   -> Service
bondy.http_connector.service.delete(Name)        -> ok
bondy.http_connector.service.get(Name)           -> Service
bondy.http_connector.service.list()              -> [Service]
bondy.http_connector.service.load(Doc)           -> Summary
bondy.http_connector.service.enable(Name)        -> ok
bondy.http_connector.service.disable(Name)       -> ok
bondy.http_connector.service.status()            -> Status
```

`get` and `list` include the derived `source` field. `list` returns conf-defined
and api-defined services together.

`load(Doc)` takes `#{services => [Service]}` and returns

```erlang
#{added => [Name], updated => [Name], count => non_neg_integer()}
```

Every service is validated before any is written, so a document containing one
invalid entry writes nothing and returns `invalid_argument` naming the offending
service. Writes are then applied per service; a crash mid-way leaves a partial
result, which is acceptable because the operation is an upsert and is idempotent
on retry. This limitation is documented rather than guarded.

`status()` returns, for each service on **this node**: `name`, `source`,
`enabled`, readiness (from the manager's readiness table, see
`bondy_http_connector_manager.erl:90-103`), pool status, and callee count per
realm. It is explicitly not a cluster-wide view.

Errors use the standard `bondy_error` vocabulary: `already_exists`, `not_found`,
`read_only`, `invalid_argument`.

## 12. `http_connector.config_file`

A boot-time JSON document seeded into the api-managed store. It is a seeding
mechanism, not a third provenance: entries become ordinary `api` services.

Writes use the compare-then-write pattern of
`bondy_http_gateway.erl:543-560`. That pattern exists for a specific reason: a
declarative re-read on every boot must not rewrite an unchanged record, because
a per-node timestamp written on each boot diverges the replicated cell and its
content digest. The connector's stored record carries no timestamp, so the
comparison is a plain equality check on the validated map.

**Documented consequence.** A service named in `config_file` is re-asserted on
every boot. An API edit to such a service is therefore reverted at the next
restart. This is the behaviour `bondy_http_gateway` already has. Operators who
want a service to be API-owned must not name it in `config_file`.

## 13. Tests

Written to falsify, not to confirm. Each names the case it covers.

**Disjointness (increment 4).**
- `add` of a name present in `bondy.conf` returns `already_exists`.
- `update`, `delete`, `enable`, `disable` of a conf name return `read_only`.
- Boot with the same name in conf and in the store: conf runs, an alarm is
  raised, and the stored record is still readable afterwards. Removing the conf
  key and rebooting restores the API definition.
- Not covered: concurrent `add` of the same name on two nodes. Last-writer-wins
  applies; the loser is not notified.

**Atomicity (increment 4).**
- A `load` document of five services whose third is invalid writes none of the
  five.

**Replication (increment 3).**
- 3-node `bondy_ct:start_cluster/2`: `add` on node 1; assert nodes 2 and 3 start
  a pool and register the procedures.
- Kill the active node; assert calls fail over to a sibling.

**Diff granularity (increment 3).**
- Change only `liveness.interval`; assert callee pids are unchanged.
- Change `auth.vars`; assert callee pids *have* changed and the token cache was
  invalidated.
- Rewrite an identical service map; assert no pool or callee is touched.

**Jitter (increment 3).**
- Assert the three nodes' apply timestamps are not all inside one debounce
  window. This measures decorrelation; it does not prove that a procedure was
  continuously registered, which would require sampling the registry during the
  window.

**Invoke (increment 0).**
- `round_robin` across three nodes distributes invocations across more than one
  node.
- A registration disagreeing with the established policy for a URI is rejected
  (`resolve_inconsistencies/5`).
- A node-forwarded invocation of a callback-backed procedure under
  `round_robin` succeeds. This path (`rib_rebind/2`) has never been exercised
  for a callback registration and is the highest-risk item in increment 0.

**Zero-service boot (increment 2).**
- Boot a node whose `bondy.conf` defines no services; assert
  `bondy_http_connector_manager` is alive and that a subsequent `service.add`
  starts a pool and registers procedures. This is the defect the unconditional
  startup change exists to fix, so the test must fail against the current
  `bondy_http_connector_sup:init/1`.
- Assert `stop_pool/1` followed by `start_pool/3` for the same service leaves
  exactly one registered pool process.

**Durability (increment 1).**
- Restart a node: API services return from the store; conf services are not
  duplicated into it.

## 14. Risks

| Risk | Mitigation |
|---|---|
| `rib_rebind/2` untested for callback registrations under a shared policy | Explicit test in increment 0; increment 0 lands alone so a regression is attributable |
| Rolling upgrade with mixed `invoke` for one URI is rejected by `resolve_inconsistencies/5` | Test the mixed case; document that changing a procedure's policy requires all nodes to converge |
| `bondy_http_connector_manager` grows substantially | Accepted for now; decompose if it becomes unreadable, as was done for `oplog_instance` |
| `config_file` reverts API edits on restart | Documented in §12 and in the operator guide |
| Cuttlefish `--allow_extra` drops unknown keys silently | No config key is renamed by this design; only additive keys |
