# Registry Routing (RIB)

Bondy's registry holds every WAMP **registration** (a callee offering a
procedure) and **subscription** (a subscriber interested in a topic). To route
a call or an event across a cluster, a node must know which other nodes can
serve a given procedure or topic.

Bondy answers that question from a **Routing Information Base (RIB)**: a set of
compact, replicated *summary cells* — one per `(realm, match policy, URI,
node)` — rather than by replicating every full registry entry to every node.
Each node keeps its own full entries in node-local memory and publishes only
the summary of what it can serve. Cross-node routing is decided from the merged
summaries.

The payoff is scale. A registration's replicated footprint is **one small cell
per node that owns it**, not a full copy of the entry on every node in the
cluster. A cluster with many short-lived registrations replicates far less
state and does far less anti-entropy work.

This is how the registry always works — there is no mode to select and nothing
to configure to turn it on.

## How routing works

- **Local registrations and subscriptions** live only in the owning node's
  memory. They are never replicated.
- Each node maintains a **summary cell** per `(realm, match policy, URI)` it
  serves, and those cells replicate cluster-wide by anti-entropy. A peer
  compiles the merged cells into a **stub view** of who can serve what.
- **Dealer (calls).** To route a call whose callee is remote, a node picks the
  owning node from the stub view and forwards the call **node-addressed**. The
  receiving node then re-selects the callee among *its own* live local
  registrations (owner-side completion) rather than acting on the sender's
  possibly-stale choice of entry. If the chosen node's summary was momentarily
  stale, a bounded pre-invocation retry reroutes to another candidate before
  the call fails with `no_eligible_callee`.
- **Broker (events).** To publish to remote subscribers, a node discovers the
  subscriber *nodes* from the subscription stubs and relays one PUBLISH per
  such node; the receiving node matches and delivers to its own local
  subscribers.

Local calls and events never leave the node — they resolve against the local
registry directly.

## Configuration

Routing on the RIB is unconditional; there is nothing to enable. Two optional
settings tune observability and flap control. Neither changes what the registry
replicates.

### Consistency sweep

```
registry.rib.check_interval = 5m   # default; 0 disables
```

Each node periodically compares its summary cells against the registry ground
truth per realm and logs a warning naming any divergence. In steady state the
sweep finds nothing; a persistent divergence is worth investigating.

### Route-flap damping

```
registry.rib.damping = 0   # default (off); a duration enables it
```

On a node whose callee count for a procedure changes rapidly (churny
registrations), each change would otherwise rewrite the summary cell.
With a non-zero window, updates that change *only* the callee count are
coalesced — at most one such write per window, with a trailing update carrying
the final value. Reachability transitions (a procedure's first registration on
the node, or its last one leaving) always propagate immediately, so damping
never delays a node becoming, or ceasing to be, a route for a procedure. Enable
it only if summary write volume is a measured problem.

## Observability

The summary machinery is instrumented on the wait-free metrics lane and
surfaced on the Admin API `/metrics` endpoint:

| Metric | Meaning |
|---|---|
| `bondy_registry_rib_members` | live local entries feeding the summaries |
| `bondy_registry_rib_stub_cells` | merged remote summary cells held for routing |
| `bondy_registry_rib_divergences` | divergences found by the last sweep |
| `bondy_registry_rib_damping_suppressions_total` | summary writes coalesced by damping |
| `bondy_rpc_rib_completions_total` `{outcome}` | owner-side callee re-selections (`ok`/`miss`) |
| `bondy_rpc_rib_retries_total` `{outcome}` | routing retries after a miss (`node`/`local`/`exhausted`) |

The bundled Grafana dashboard (`monitoring/`) has a **Registry RIB** section
covering these.
