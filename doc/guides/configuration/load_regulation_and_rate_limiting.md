# Understanding load regulation and rate limiting

A router fails under pressure in two different ways, and they need two
different answers.

The first is **overload**: legitimate work arrives faster than this node can
perform it. Nothing here is abusive — the clients are well-behaved and every
request deserves an answer — but the node cannot deliver one in useful time.
Left alone, the node accepts everything and delivers nothing on time: work
that costs microseconds of CPU takes seconds of wall clock because the process
doing it waits behind everything else for a scheduler. Latency degrades for
every client at once, including the ones already connected and working.

The second is **abuse**: a single source sends far more than its fair share —
a reconnect storm, a credential-stuffing run, a runaway publisher loop. The
node may be nowhere near saturation. The problem is the distribution of the
load, not its total.

Bondy answers the first with **load regulation** and the second with **rate
limiting**. This guide explains both: what each mechanism measures, when it
acts, what a client observes when it does, and what you can watch to tell
whether it is working. Everything described here was added after
1.0.0-rc.65.

If you want the per-key types and defaults rather than the model, read the
[schema](../../../schema/bondy.schema) or the configuration reference; this
guide names keys but does not tabulate them.

Two diagrams accompany it — the ingress lanes below and the pools and queues
further down; the closing regulators-at-a-glance section collects every
regulator into two tables.

Start with ingress. Each transport gets its own lane because the gates genuinely
differ per lane — and the dashed boxes are worth noting early: they mark the
spots where no regulator sits, which on the cluster peer planes is deliberate.

[![Bondy ingress and admission per transport: five lanes — HTTP/HTTPS (API Gateway, Admin API, MCP, SSE, long-poll), WAMP WebSocket, WAMP TCP/TLS, Partisan and Bondy Bridge Relay — each running from client through listener and acceptors, connection admission, connection process, the per-request or HELLO admission gate, and the per-source-IP and per-session rate limits with their node, listener and realm scopes.](assets/load_regulation_ingress.svg)](assets/load_regulation_ingress.svg)

## Two questions, two mechanisms

Every regulator in Bondy answers one of two questions.

**Load regulation** asks *"is this node able to do more work right now?"* The
answer is about the node, and it is the same answer for every client. When it
is "no", the cheapest correct response is to refuse new work immediately and
keep serving the work already accepted.

**Rate limiting** asks *"has this particular source had its share?"* The
answer is about one source IP or one session and says nothing about the node's
health. A rate limit trips at exactly the same threshold on an idle node as on
a saturated one — that is the point.

The two compose. A node can be healthy and still throttle an abusive client;
it can be overloaded and refuse a client who has done nothing wrong. Neither
mechanism subsumes the other, and reaching for the wrong one produces bad
behaviour: rate limits tuned to protect the node have to be set so low they
punish legitimate bursts, and load regulation cannot see that one client out
of ten thousand is responsible for the pressure.

## The node load signal

Load regulation needs a number that means "this node is behind". CPU
utilisation is the obvious candidate and the wrong one: a node at 100% CPU
that is keeping up is healthy, and a node at 60% CPU whose work is stuck
behind a few long-running processes is not.

The signal Bondy uses instead is the **run queue** — the count of processes
that are ready to run and waiting for a scheduler. This measures scheduling
delay directly, which is the thing that actually degrades: a session open is
cheap in CPU terms, and it takes seconds anyway when its process sits behind
several thousand others.

Two subsystems sample this signal, in two different shapes, because they are
asking different questions.

### The node monitor: a binary busy state

`bondy_regulator_load` samples the runtime's total run queue length
(`erlang:statistics(total_run_queue_lengths_all)`) every
`load_regulation.load_monitor.sample_interval` (100ms by default) and exposes
a single binary status: **busy** or **normal**.

The thresholds are expressed as multiples of the online scheduler count rather
than absolute queue lengths, so one configuration is portable across machine
sizes. The node becomes busy when the sampled queue reaches
`load_regulation.load_monitor.run_queue_high_watermark` × schedulers (8 ×
schedulers by default), meaning roughly eight runnable processes ahead of any
newly runnable one on every scheduler. It returns to normal only when the
queue falls to `load_regulation.load_monitor.run_queue_low_watermark` ×
schedulers (4 × by default).

The gap between the two watermarks is deliberate. Without it the status would
flap on every sample at the boundary, and each flip would change the node's
admission behaviour — clients would see a node that accepts and refuses
alternately for as long as load hovered near the threshold. Widening the gap
makes the node slower to recover but steadier; narrowing it does the reverse.

Reading the status is a single atomics read behind a cached reference, so
admission gates can consult it per request without a process hop or a lock.

### The anti-entropy signal: a smoothed ratio

Anti-entropy asks a softer question — "is now a good moment for background
work?" — so it uses a softer signal: `erlang:statistics(run_queue)` divided by
the online scheduler count, giving the average number of ready processes per
scheduler, then smoothed with an exponentially weighted moving average across
ticks.

A ratio rather than a count, because the comparison is against an intuitive
figure: a healthy node hovers near 0–1, and a sustained 2 or more means work
is queuing faster than the schedulers drain it. Smoothed rather than raw,
because deferring background reconciliation on a single unlucky sample would
make convergence latency jittery for no benefit — a momentary spike is not a
reason to stop syncing.

## Refusing work at the door

The cheapest work is work never accepted. When the node is busy, Bondy refuses
**new sessions** at the earliest point it can.

With `load_regulation.hello.enabled` on (the default), a `HELLO` arriving
while the node is in the busy state is answered immediately with an `ABORT`
carrying `wamp.error.unavailable`. The cost to the node is a parse and an
encoded reply.

The alternative — accepting the session — is far more expensive, and worse for
the client. Establishing a session means holding a socket, allocating session
state, and running authentication, all of it stretched by the same scheduling
delay that made the node busy. The likely outcome is a client-side timeout
after the node has paid for all of it, with the session state to tear down
afterwards.

Two properties make this safe to leave on:

- **The refusal is retryable.** `wamp.error.unavailable` tells a well-behaved
  client to back off and try again, possibly reaching a different node through
  its load balancer. It is an availability condition, not a client error, and
  clients should not treat it as a permanent failure.
- **It applies only at the door.** Sessions already established are
  unaffected, and so are handshakes already past `HELLO`. The gate protects
  the latency of admitted sessions by declining to share the overload with
  them. A node under pressure keeps its existing clients working rather than
  degrading everyone equally.

Each refusal increments `bondy_wamp_dropped_total` with `reason="admission"`
and `family="hello"`.

## Shedding work that cannot wait

Refusal at the door is not always available. Some work is already inside the
router when the pressure appears, and for one class of it, queuing is not an
option.

That class is **ingress from elsewhere in the cluster**: messages arriving from
a peer node's relay, and from a bridge relay. These arrive in an order that
already means something — the sending side pins each flow (a source/destination
session pair) to one connection on the wire, so the messages of a flow reach
this node in the order they were sent. Preserving that order locally means
dispatching every message of a flow to the same worker in the flow pool, so
they execute in arrival order.

That guarantee is what makes the queue bound unusual. When a worker's queue is
full, the router cannot spill the message to another worker — it would overtake
the messages already queued for that flow — and cannot execute it inline, for
the same reason. The only order-preserving option left is to drop it. WAMP
delivery here is at-most-once, so a drop is the protocol behaving as specified
rather than a failure.

`load_regulation.router.flow_pool.capacity` (100,000 by default) is the total
message budget across the pool; each worker's share is that value divided by
`load_regulation.router.pool.size`. Over its share, the worker sheds.

This bound is deliberately far smaller than
`load_regulation.router.pool.capacity`, which governs the separate, unordered
router pool used for locally-originated routing. An ordered lane cannot
overflow to a neighbour, so a large bound buys memory pressure rather than
throughput — the messages queue up, the flow falls further behind, and the
eventual drop happens anyway with more RAM consumed on the way.

Sheds increment `bondy_wamp_dropped_total` with `reason="shed"` and a `family`
label distinguishing relay from bridge-relay ingress. The accompanying log is
itself rate-limited through a shared atomic, so a shed storm cannot turn into a
log storm — a detail worth knowing when you are reading logs during an incident
and see fewer lines than the counter suggests.

### The pools at a glance

The flow pool is one of seven bounded pools and queues on the request path. They
differ in what feeds them, what bounds them, and — the part worth knowing before
an incident — what each does when it fills. Only the flow pool loses messages
outright.

[![Bondy pools and worker queues: router pool, flow pool, session manager pool, job manager pool and FIFO queues, registry partitions, transport queue and anti-entropy reactor pool, each showing what feeds it, its configuration keys, and its overflow behaviour.](assets/load_regulation_pools.svg)](assets/load_regulation_pools.svg)

## Keeping background work subordinate

Anti-entropy reconciles data between nodes. It is necessary, and it is never
more important than routing. Three mechanisms keep it in its place, and they
bound different things.

**Concurrency** — `db.aae.max_concurrency` (3) caps how many sync sessions run
at once. This governs speed and fairness, not memory: the per-round page batch
is `db.aae.max_pages_in_flight` divided by this value, so raising concurrency
shrinks each session's batch and leaves the node-wide page budget unchanged.
More concurrency means more shards make progress at once, each more slowly, so
no shard starves behind a single serial sync. Setting it to `1` serialises
anti-entropy entirely.

**Memory** — `db.aae.max_pages_in_flight` (2048) is the node-wide budget, in
pages, for reconciliation in flight at any instant. This is the lever that
bounds peak memory, and it holds regardless of dataset size or concurrency.
Larger syncs faster and peaks higher; smaller is gentler and slower.

**Time** — the other two bound anti-entropy in aggregate; neither stops it
from competing with a routing spike happening right now.
`db.aae.live_sync` (on) handles the steady state: a shard whose data has
settled has nothing to pull, so its poll interval backs off geometrically up
to `db.aae.live_sync.max` (5s) and resets to the tick cadence the moment its
data moves again. Because propagation is pull-only, that cap is also the
steady-state convergence latency for a quiescent shard — set it below the
convergence bound you need.

`db.aae.load_adaptive` (off) handles the spike: while the smoothed load ratio
sits at or above `db.aae.load_run_queue_threshold` (2.0), the scheduler skips
its throttleable dispatches for that tick. In-flight sessions are never
aborted and deferred shards retry on the next quiet tick, so this can only
affect convergence latency, never correctness. It is off by default because
the concurrency cap and the live-sync backoff already keep anti-entropy
subordinate; turn it on where routing latency is sensitive to background
pressure.

Both throttles exempt the shards backing the authentication freshness fence.
Those shards always sync every tick, so no amount of throttling can turn into
an authentication outage.

The work anti-entropy triggers when a sync lands — session close, RBAC cache
invalidation, routing summary updates — runs on its own pool, sized by
`load_regulation.aae_reactor.pool.size` (16). Events are sharded by cell key,
so a given cell's changes always run on the same worker and stay ordered.
Raising this helps only when reactions for many distinct cells are in flight
at once.

### The regulators at a glance

That completes the set. Two tables collect it: the run-queue signal in its two
shapes, and then every regulator with what it reads, what it does, and the
counter that tells you it is engaging.

The first makes explicit something easy to miss — the node monitor and
anti-entropy sample the run queue **separately**, in different shapes, and
neither feeds the other:

| | Node load monitor | Anti-entropy scheduler |
|---|---|---|
| Reads | Total run queue length, raw, every 100ms | Run queue ÷ online schedulers |
| Compared against | `run_queue_high_watermark` (8) × schedulers; back to normal at `run_queue_low_watermark` (4) × schedulers | `db.aae.load_run_queue_threshold` (2.0), as an EWMA-smoothed ratio across ticks |
| Output | One binary status: busy / normal | Throttle this tick, or not |
| Consumer | The `HELLO` admission gate | The anti-entropy scheduler, when `db.aae.load_adaptive` is on |

The hard threshold answers an admission question that must not flap; the
smoothed ratio answers a "good moment for background work?" question that must
not overreact to one sample.

| Regulator | Protects | Signal it reads | When it acts | Configuration (default) | Watch |
|---|---|---|---|---|---|
| `HELLO` admission gate | latency of admitted sessions | node monitor busy state | immediate retryable `ABORT` (`wamp.error.unavailable`); established sessions unaffected | `load_regulation.hello.enabled` (`on`) | `bondy_wamp_dropped_total{reason="admission"}` |
| Flow-pool bound | memory and ordering on cluster ingress | a worker's queue vs its share of the budget | the message is shed (at-most-once delivery) | `load_regulation.router.flow_pool.capacity` (100,000) | `bondy_wamp_dropped_total{reason="shed"}` |
| Anti-entropy concurrency cap | routing fairness | count of running sync sessions | further syncs wait; per-round batch = pages ÷ concurrency | `db.aae.max_concurrency` (3) | — |
| Anti-entropy page budget | peak memory | reconciliation pages in flight | batches shrink; the node-wide budget holds regardless of dataset size | `db.aae.max_pages_in_flight` (2048) | — |
| Live-sync backoff | steady-state background cost | whether the shard's data moved | poll interval backs off geometrically to `db.aae.live_sync.max` (5s), resets on change | `db.aae.live_sync` (`on`) | — |
| Load-adaptive throttle | routing during a spike | the smoothed run-queue ratio | that tick's throttleable dispatches are skipped; in-flight syncs never aborted | `db.aae.load_adaptive` (`off`) | — |
| Rate limiting — five classes, three scopes | fair share per source IP / session / tenant | token buckets, consumed node → listener → realm | `429` / `ABORT` / `ERROR` / silent drop, per class — next section | `security.rate_limit.*` · `listeners.$name.rate_limit.*` · the realm `rate_limit` property | `bondy_rate_limited_total{class, scope}` |
| Callee admission (`bondy_connect_sdk`) | the callee's handler pool | in-flight invocation count, plus an optional token bucket | backpressure `ERROR` instead of running the handler | `handler.max_concurrency` · `handler.rate` (client-side, not `bondy.conf`) | — |

Every row fails open (see [Failing open](#failing-open) below), so a missing
denial counter is not proof the regulator is configured — it may simply never
have been needed, or never have been on.

## Rate limiting inbound traffic

Out of the box nothing is throttled. Budgets exist at three scopes — node,
listener and realm, covered below — and none ships enabled: the node scope's
master switch, `security.rate_limit.enabled`, is off (leaving the check a
single map read on the common path), and a listener or realm budget exists
only where an operator configures one.

Five classes apply token buckets at five points in a connection's life. Each
class has a `rate` in tokens per second (the steady-state allowance) and a
`capacity` (the burst a client may spend at once before being held to the
rate).

| Class | Keyed by | Applied at | Node defaults | Client sees |
|---|---|---|---|---|
| `connection` | source IP | transport handler, before any per-connection work | 20/s, burst 100 | TCP: socket closed. WebSocket: HTTP `429` |
| `handshake` | source IP | `HELLO`, after the load admission gate | 10/s, burst 50 | `ABORT` with `wamp.error.unavailable` |
| `auth` | source IP | `AUTHENTICATE`, before credential verification | 5/s, burst 20 | `ABORT` with `wamp.error.unavailable` |
| `http` | source IP | every HTTP request — API Gateway, Admin API and MCP endpoints | 100/s, burst 500 | HTTP `429` with a `retry-after` header |
| `message` | session | `CALL` / `PUBLISH` / `SUBSCRIBE` / `REGISTER` | 1000/s, burst 2000 | `ERROR` with `wamp.error.unavailable`, or a silent drop |

The `auth` limit applies *before* verification, which is the point:
verification is the expensive step a credential-stuffing run is trying to
make you perform.

The `message` class sits on the per-message hot path, so its node-scope
budget has its own opt-in flag, `security.rate_limit.message.enabled`, on top
of the master switch. Its bucket chain — one bucket per scope configured for
the class — is resolved once at session open and held in the connection's
state, so the per-message cost is a field read plus an atomics operation per
configured scope, never a configuration lookup. This applies on every
transport that carries a WAMP session: WebSocket, raw socket, SSE and
long-poll alike. A throttled message that expects a reply gets a WAMP `ERROR`;
an unacknowledged `PUBLISH` expects no reply, so it is dropped silently —
sending an error for a message whose sender is not listening would be a
protocol violation.

The abort and error messages are deliberately generic: they say the client
should slow down and retry, and nothing about which limit tripped or whether
the credentials were valid. A pre-authentication signal that varied by cause
would be an enumeration oracle.

Denials increment `bondy_rate_limited_total`, labelled by class and scope.

### Scopes: node, listener, realm

Every class can be budgeted at up to three scopes, and a request is admitted
only when **all** of them admit it:

- **Node** — the `security.rate_limit.*` keys: budgets shared by every
  listener and realm on the node. This is where the master switch lives.
- **Listener** — the `listeners.$name.rate_limit.*` keys: the same classes,
  budgeted per listener, so an Internet-facing listener can be held to a
  tighter budget than an internal one.
- **Realm** — the realm's own `rate_limit` property, set through the realm
  admin APIs or the security configuration file and replicated with the
  realm. It covers the classes a realm-addressed request reaches — `auth`,
  `http` and `message` (`connection` and `handshake` fire before any realm is
  named) — and is the only scope with two budget *kinds*: `per_caller` (a
  bucket per source IP or session, like the other scopes) and `total`, one
  bucket shared by **all** of the realm's callers — a tenant quota.

The scopes are consumed coarse to fine — node, then listener, then the
realm's `per_caller`, then its `total` — and each configured scope consumes
one token per request; the first refusal answers, and tokens already consumed
at outer scopes are not returned. The composition can therefore only
*narrow*: no listener or realm setting can grant traffic the node's own
budget refuses.

Each scope is enabled independently. The node scope has its master switch; a
listener or realm class budget is in force simply by being configured,
whether or not node-scope limiting is on.

**The realm `total` is a per-node quota.** Buckets are node-local, so a realm
`total` of N tokens per second bounds each node separately: a cluster of
three nodes admits up to 3×N per second for that realm. Size it per node, or
use `per_caller` budgets when you need a bound that does not scale with the
cluster.

The denial metric's `scope` label says which scope refused: `node`,
`listener`, `realm` (a caller over its own realm budget) or `realm_total`
(the realm's shared quota exhausted) — so a hot caller and an exhausted
tenant quota are distinguishable at a glance.

> #### Checking is cheap — refusing is not {: .tip}
>
> Do not size budgets down out of concern for the cost of the checks
> themselves. With nothing configured the per-message check is a single
> field read; each configured scope adds one lock-free atomic operation per
> message, and the realm `total` one shared-table consult — all of it
> orders of magnitude below the cost of routing the message, with no
> measurable effect on message throughput or latency at any scope
> combination. The `connection`, `handshake` and `auth` classes cost one
> keyed-table consult per scope per *attempt*, a similarly negligible
> fraction of establishing a session. The expensive outcome of rate
> limiting is a budget sized too tight for legitimate traffic: refusals,
> retries and reconnect storms cost far more than the checks ever will.
> Size budgets for abuse, leave them enabled, and watch
> `bondy_rate_limited_total` rather than pre-emptively loosening.

### Buckets and keyspace

Source IP is an unbounded, transient dimension: a flood from a churning set of
addresses would mint a bucket per address and never release one. Bondy's
keyed limiter creates a bucket on first use and a background sweep deletes
buckets idle beyond a TTL, so the keyspace cannot grow without bound. The hot
path stays a lockless table lookup plus an atomics check.

Per-session message buckets have a definite owner and are freed at session
teardown instead — except the realm `total`, which is shared by every session
on the realm and therefore lives in the keyed table with the per-IP buckets,
swept by idleness like them.

### Source IP behind a proxy

Every per-IP limit throttles a source IP collectively. Clients behind a shared
NAT or a reverse proxy that does not forward the original address all present
one IP to Bondy and share one bucket, so limits that look generous per client
can be strict in aggregate. Configure trusted proxies so Bondy resolves the
real client address before relying on per-IP limits, and keep the limits
generous until you have confirmed clients present distinct addresses.

## Regulating callee invocations

The mechanisms above protect the router. A callee has the opposite problem: it
is one process pool serving invocations the router sends it, and a burst can
overwhelm the handler rather than the router.

Connections built with `bondy_connect_sdk` regulate invocation **admission** per
connection, through two independent limits: a hard in-flight cap
(`max_concurrency`, where `0` means unlimited) counting invocations currently
being serviced, and an optional token bucket for the rate. Both live in the
connection's `handler` configuration rather than `bondy.conf`, because they
belong to the client, not the node.

When admission is denied the connection replies to the router with a
backpressure `ERROR` instead of running the handler. The distinction matters:
this governs whether an invocation is *started*, while the handler supervisor
governs how it *runs*.

## Failing open

Every regulator described here fails open. If the load monitor is not running,
the node reads as normal and admits. If the rate limiter's table is
unavailable, requests are allowed. If a per-session bucket cannot be created,
that session runs unthrottled and the node logs a warning.

This is a deliberate ordering of risks. A regulator that fails closed converts
its own bug or startup race into a total outage — the node refuses everything
because the thing that decides what to refuse is broken. Failing open degrades
to the behaviour Bondy had before the regulator existed, which is a known and
survivable state. Availability of the router outranks the accuracy of its
regulation.

The consequence for operators: absence of throttling is not proof that
throttling is configured. Confirm with the counters.

## What to watch

Four signals tell you whether regulation is engaging, and they mean different
things.

- `bondy_wamp_dropped_total{reason="admission",family="hello"}` — sessions
  refused because the node was busy. A nonzero rate means the node is at its
  session-establishment ceiling. Sustained, it means you need more nodes or a
  higher watermark, not a bigger timeout.
- `bondy_wamp_dropped_total{reason="shed"}` — messages dropped to preserve
  flow ordering, labelled by family. This is data loss by design, and it is
  the signal that a flow is producing faster than its destination consumes.
- `bondy_rate_limited_total{class, scope}` — denials per class and scope. The
  `scope` label names the budget that refused — `node`, `listener`, `realm`
  (one hot caller) or `realm_total` (a tenant quota exhausted). Read alongside
  the node's load: denials on a healthy node point at one misbehaving source,
  while denials across every class at once usually mean the limits are simply
  too tight for your topology.
- Run queue length, from the load monitor. This is the input to everything
  above, and the leading indicator — it rises before the refusals start.

A node that never refuses anything is not necessarily healthy; it may simply
have every regulator switched off. Rate limiting in particular ships with no
budget enabled at any scope, and the node-scope message class needs a second
opt-in.

## Choosing values

The defaults are sized for a node doing real work and are safe to run
unchanged. When you do change them:

**Watermarks are factors, not counts.** Raising
`load_regulation.load_monitor.run_queue_high_watermark` makes the node
tolerate deeper queues before refusing sessions — more sessions admitted, each
establishing more slowly. Lower it if establishment latency matters more than
admission volume. Keep the low watermark meaningfully below the high one; a
narrow gap trades steadiness for recovery speed.

**Flow pool capacity is not throughput.** Raising
`load_regulation.router.flow_pool.capacity` lets a slow flow queue more before
shedding, which helps a genuinely bursty consumer and does nothing for a
consumer that is persistently slower than its producer — for that one it only
delays the drop and holds the memory meanwhile.

**Anti-entropy trades convergence latency for headroom.** Lowering
`db.aae.max_pages_in_flight` cuts peak memory and slows sync.
`db.aae.live_sync.max` is a convergence bound, so treat it as an SLA figure
rather than a tuning knob.

**Rate limits are topology-dependent.** The right values depend entirely on
how many clients share a source IP. Enable the limits in a staging environment
first, watch `bondy_rate_limited_total`, and raise the limits until legitimate
traffic stops being denied — starting from the defaults on a NAT-heavy
deployment will deny real clients.

## See also

- [How to migrate your configuration from 1.0.0-rc.65](migrating_from_1.0.0-rc.65.md)
  — the wider set of configuration changes in this release.
- [Understanding deletion and reclamation](../database/deletion_and_reclamation.md)
  — the other background subsystem that yields to routing.
- [Registry routing](../router/registry_routing.md) — the routing state
  anti-entropy reactions keep current.
