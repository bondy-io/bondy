# Architecture Rationale: Robustness

The views describe what Bondy is; this page argues why it holds. It
collects the cross-cutting decisions about faults, overload, and
consistency, and states — precisely — which properties are verified by
machine rather than by argument. The audience is anyone deciding whether to
trust the system: an evaluating operator, or an engineer about to modify
something these guarantees rest on.

## Fault design: crash, restart, reconcile

Bondy is an OTP system: every element of the runtime views lives in a
supervision tree, and the response to an inconsistent process is to crash
it and restart clean, not to patch it in place. What makes this safe at the
architecture level is that every restart has a defined resupply path — a
session's client reconnects; a shard replays its log; an ephemeral database
refills from peers; a node that lost too much history rebootstraps. The
[deployment view](view_deployment.md) tabulates blast radii; the property
worth stating here is that **no failure mode's recovery depends on the
failed party having behaved well** — recovery always re-derives from
durable or replicated ground truth.

Cross-node forwarding is not assumed reliable either. The relay treats
Partisan channels as what they are — TCP that can drop — and WAMP's
delivery contract (per-pair ordering, at-most-once eventing) is preserved
by re-derivable state and by a chain of already-serial stages — the
sender's connection process, one pinned channel connection per flow, one
keyed worker on ingress — rather than by pretending the network is a bus.

## Overload design: refuse early, shed nothing silently

The system's posture under load is asymmetric on purpose:

- **Admission is the throttle.** Under measured load
  (`bondy_regulator_load`), new sessions are refused at HELLO with an
  explicit, cheap, retryable ABORT — before authentication, before RIB
  writes, before any real cost. Admitted sessions are protected at the
  expense of unadmitted ones.
- **The data plane backpressures rather than queues, and never drops
  without saying so.** Client-submitted messages are routed synchronously
  in the connection process that received them, so a loaded router slows
  that connection instead of accumulating unbounded work; the regulated
  pool, with its inline fallback, carries only the meta-API calls. The one
  place the data plane does discard is relay *ingress*, where a message
  whose flow worker is at its share of the pool's capacity is shed — WAMP
  eventing is at-most-once, so this is a legitimate response to saturation
  rather than a failure, and every shed is counted.
- **Background work yields to foreground work.** Anti-entropy runs under
  a node-wide concurrency cap and a node-wide page-memory budget
  (independent of shard count), backs off on converged shards, and can
  defer under load — replication lag is recoverable; a saturated node is
  not.

Validated behaviour at roughly 6× over-capacity offered load: refusals in
the tens of thousands, admitted-session delivery latencies stable, and
anti-entropy draining its backlog to zero within seconds of load removal.

## Consistency design: eventual, with honest exceptions

Cross-node consistency is eventual, and the architecture spends its effort
not on hiding that but on making it *safe*:

- **Convergence is structural.** Replicas fold the same events through the
  same per-table CRDT semantics; agreement on the event set implies
  agreement on values. The remaining problem — event-set agreement — is
  anti-entropy's, and its detection and repair machinery is the
  [convergence view](view_convergence.md).
- **Where staleness is dangerous, it is fenced, not tolerated.**
  Authentication refuses on a node whose view of the security tables is
  older than a bound (`db.aae.fence.max_lag`) or that cannot confirm
  freshness while peers exist (`db.aae.fence.on_isolation`) — fail-closed
  by default, with the single-node case exempt because it has no peer to
  lag.
- **Garbage collection is licensed, never assumed.** Tombstone reclamation
  and history truncation happen only below a stability point certified by
  containment proofs against every confirmed peer ([deletion and
  reclamation](../database/deletion_and_reclamation.md)); the repair path
  for the deliberate liveness exception (silent peers age out of the
  confirmation set) is the frontier-gap → rebootstrap chain.

## What is verified, and how

Several of the properties above are not argued in comments — they are
checked by machine, and the artifacts live in the repository:

| Property | Method |
| --- | --- |
| The stability theorem: the containment frontier licenses reclamation of everything at or below it, without causal broadcast | Mechanized proof (Isabelle/HOL), including the exact boundary of the license — scalar (clock) stability suffices for clock-governed state reductions and provably does not for context-governed ones |
| Hybrid-logical-clock monotonicity and domination of received timestamps, including the logical-overflow clamp | Mechanized proof |
| Exactness of the compact observed-remove test under per-origin prefix closure, with its preconditions named | Mechanized proof |
| Per-origin prefix closure under compaction and rejoin — the hypothesis above | Model-checked (TLA+): violated without enforcement, exhaustively clean with the shipped [prefix hold](../database/prefix_closure.md); the violating configurations are kept as regression pins |
| The same, on real clusters | Cluster tests in both polarities: with enforcement off the hazard reproduces and is detected; with enforcement on, zero violations through fault injection and repair to full convergence |
| The same, at production scale | A five-node validation run at the workload's record throughput with a live two-minute node kill: enforcement engaged only at the rejoin, zero remote-origin violations, zero burned sequences, self-heal within three minutes |

The point of the table is not the volume of verification but its
placement: the properties chosen are exactly the ones every view leans on —
the reclamation license, the clock, the observed-remove test, and the fold
order. An engineer changing code near any of these should expect a proof,
a model, and a test to disagree with a mistake before an operator does.

## Standing limits

Honesty about edges the architecture does not cover:

- Cross-node reads are eventually consistent; an application needing
  read-your-write across *different* nodes must route the read to the
  writing node or tolerate the lag.
- The prefix hold cannot cover fold paths with no re-presentation (the
  compaction catch-up, one-shot re-derivations); those are instrumented,
  and the detector's telemetry is the tripwire.
- A permanently unfillable sequence (a burned range under a lost
  storage-failure race) converts into a rebootstrap on peers rather than
  a silent gap — a deliberate trade of noise for correctness, measured at
  zero occurrences in the validation record.

## Related

- [Documentation roadmap](architecture.md) · [Convergence and repair](view_convergence.md) · [Per-origin prefix closure](../database/prefix_closure.md) · [Load regulation](../configuration/load_regulation_and_rate_limiting.md)
