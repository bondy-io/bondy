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

Three diagrams accompany it, one per section: the ingress lanes below, the pools
and queues further down, and the regulators and their signals at the end.

Start with ingress. Each transport gets its own lane because the gates genuinely
differ per lane — and the dashed boxes are worth noting early, since they mark
where nothing regulates anything today.

[![Bondy ingress and admission per transport: five lanes — HTTP/HTTPS, WAMP WebSocket, WAMP TCP/TLS, Partisan and Bondy Bridge Relay — each running from client through listener and acceptor pool, connection admission, connection process, session admission and per-session limits.](assets/load_regulation_ingress.svg)](assets/load_regulation_ingress.svg)

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

That completes the set. The diagram below collects every regulator with the
signal it reads: the node load monitor and its single consumer, the four
anti-entropy bounds, callee-side admission, and the counters that tell you any
of it is engaging. It also makes explicit something easy to miss — the node
monitor and anti-entropy sample the run queue **separately**, in different
shapes, and neither feeds the other.

[![Bondy load regulators and their signals: the node load monitor and its watermarks, a comparison of the two independent run-queue signals, the fail-open principle, the four anti-entropy regulators, outbound and callee-side admission, and the metrics to watch.](assets/load_regulation_signals.svg)](assets/load_regulation_signals.svg)

## Rate limiting inbound traffic

Rate limiting is off by default. `security.rate_limit.enabled` is the master
switch, and with it off the check is a single map read on the common path.

When on, four classes apply token buckets at four points in a connection's
life. Each class has a `rate` in tokens per second (the steady-state
allowance) and a `capacity` (the burst a client may spend at once before
being held to the rate).

**Connection**, keyed by source IP, applied at the transport handler before
any per-connection work. A TCP connection over the limit has its socket closed
immediately; a WebSocket upgrade over the limit is answered with HTTP 429.
Defaults: 20/s, burst 100.

**Handshake**, keyed by source IP, applied to `HELLO` after the load
admission gate. Over the limit, the connection is aborted with
`wamp.error.unavailable`. Defaults: 10/s, burst 50.

**Auth**, keyed by source IP, applied to `AUTHENTICATE` *before* credential
verification — which is the point, since verification is the expensive step a
credential-stuffing run is trying to make you perform. Over the limit, the
connection is aborted. Defaults: 5/s, burst 20.

**Message**, keyed by session, applied to `CALL`, `PUBLISH`, `SUBSCRIBE` and
`REGISTER`. This one has its own opt-in flag,
`security.rate_limit.message.enabled`, on top of the master switch, because it
sits on the per-message hot path. The bucket is resolved once at session open
and held in the connection's state, so the per-message cost is a field read
plus an atomics operation — never a configuration lookup. Defaults: 1000/s,
burst 2000.

A throttled message that expects a reply gets a WAMP `ERROR` with
`wamp.error.unavailable`. An unacknowledged `PUBLISH` expects no reply, so it
is dropped silently — sending an error for a message whose sender is not
listening would be a protocol violation.

The abort and error messages are deliberately generic: they say the client
should slow down and retry, and nothing about which limit tripped or whether
the credentials were valid. A pre-authentication signal that varied by cause
would be an enumeration oracle.

Denials increment `bondy_rate_limited_total`, labelled by class.

### Buckets and keyspace

Source IP is an unbounded, transient dimension: a flood from a churning set of
addresses would mint a bucket per address and never release one. Bondy's
keyed limiter creates a bucket on first use and a background sweep deletes
buckets idle beyond a TTL, so the keyspace cannot grow without bound. The hot
path stays a lockless table lookup plus an atomics check.

Per-session message buckets have a definite owner and are freed at session
teardown instead.

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
- `bondy_rate_limited_total{class}` — denials per class. Read alongside the
  node's load: denials on a healthy node point at one misbehaving source,
  while denials across every class at once usually mean the limits are simply
  too tight for your topology.
- Run queue length, from the load monitor. This is the input to everything
  above, and the leading indicator — it rises before the refusals start.

A node that never refuses anything is not necessarily healthy; it may simply
have every regulator switched off. Rate limiting in particular is off by
default, and the message class needs a second opt-in.

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
