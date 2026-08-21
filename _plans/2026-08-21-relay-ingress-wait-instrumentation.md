# Relay-ingress wait instrumentation — assessment

**Status:** assessment only, no code change proposed for the product.
**Date:** 2026-08-21

## Retraction first

After the S29 Fly run I recommended "add an enqueue timestamp to the remote
dispatch path so `bondy_router_flow_queue_microseconds` records relay ingress".

**That recommendation was wrong on two counts, and I am withdrawing it.**

1. The gap it describes is already covered. `bondy_router_flow_queue_depth`
   measures relay-ingress backlog, is declared, is observed, and was live
   during both runs.
2. The enqueue-timestamp idea had already been evaluated and rejected on the
   merits, with the reasoning written down in
   `apps/bondy_router/src/bondy_telemetry.erl:281-297`.

The recommendation came from a stale note about the s27 campaign rather than
from the code as it stands. The observation that produced it — `flow.queue`
reading zero for the whole run — was accurate; the inference that this left the
path unmeasured was not.

## What the code actually does

**Local dispatch** — `bondy_router_worker:timed/2`
(`apps/bondy_router/src/bondy_router_worker.erl:428`). `cast/3` wraps the task
in a closure that captures `EnqueuedAt = erlang:monotonic_time(microsecond)` in
the *dispatching* process. The worker stamps `Started` at execution and emits
`Started - EnqueuedAt` as the queue wait. This is sound because both stamps are
taken on the same node, therefore against the same monotonic clock.

**Relay ingress** — `handle_cast({forward, To, Msg, FwdOpts}, State)`
(`bondy_router_worker.erl:342`). This path does **not** go through `cast/3`.
A peer addresses the message to `{via, bondy_router_worker, PartitionKey}`, and
partisan performs the delivery: it calls `whereis_name/1` to resolve the key
against the local pool geometry, then delivers `{forward, To, Msg, FwdOpts}`
straight into the worker's mailbox. No Bondy code runs between resolution and
the send, and no intermediate process exists — deliberately, so that a flow
arriving in wire order lands on one worker in that order
(`bondy_router_worker.erl:169-190`).

Having no dispatch timestamp, the worker instead reads its own
`message_queue_len` at dequeue and emits
`bondy_telemetry:router_flow_ingress(relay, ServiceUs, Depth)`.

**Sink** — `bondy_prometheus.erl:785-813`. The queue histogram is skipped when
the measurement is absent, with the reason stated at the call site: recording a
zero would fake a perfect queue. The depth histogram is recorded when present.

## Why a sender-side stamp is wrong

Already documented at `bondy_telemetry.erl:284-290`, and correct:

- A stamp applied at the sending node spans two nodes' monotonic clocks, which
  are not comparable.
- It would fold network transit into what is meant to be a *queueing*
  measurement.
- Carrying a per-message timestamp costs work on the hottest cross-node path.

## Why a receiver-side stamp is not a small patch

The obvious repair — stamp on the *receiving* node, dodging the cross-node clock
problem entirely — does not fit the architecture:

The `{forward, To, Msg, FwdOpts}` term is constructed on the **sending** node
(`bondy_relay:forward/3`) and shipped whole. On the receiving side Bondy's only
hook is `whereis_name/1`, which resolves a key to a Pid. It does not get to
rewrite the message. So an exact receiver-side enqueue stamp needs one of:

- **An interposed process** to receive, stamp and forward. This destroys the
  "no intermediate process" property that makes wire-order ordering hold, and
  adds a hop to every cross-node message. Not acceptable.
- **A side channel keyed per message.** There is no message identity to key on.
  A per-worker "last enqueue" atomic does not work: with several enqueues in
  flight the worker would read some other message's stamp.

## Options and their cost

Rate context, measured on the S28/S29 runs at 10k publishes/s over 5 nodes:
**~23–25k relay-ingress tasks/s cluster-wide**, ~1.5–2.2M per node per 350 s
steady window. Anything added here runs on every one of them.

| # | Change | Hot-path cost | Semantics |
|---|---|---|---|
| 0 | **Read the depth metric that already exists** | none | `depth × service` estimates the wait every message behind this one pays |
| 1 | Worker emits `depth × own service` as an estimated-wait histogram | one multiply + one histogram observation per task | A distribution rather than a product of marginals — but still estimates the *back-of-queue* message's wait, not this message's |
| 2 | Sender stamps `erlang:system_time`, receiver differences it | one `system_time` call + one extra word in an already-allocated tuple | **Not** queue wait: transit + queue, with NTP skew as error. Only defensible if named end-to-end relay latency |
| 3 | Exact wait via interposed process | an extra hop per cross-node message | Exact, and not worth it |

Option 2's cost is smaller than the existing doc implies — appending a 5th
element to a tuple that is already being allocated adds one word, and a
microsecond `system_time` value is an immediate on 64-bit BEAM, so there is no
boxing and no new allocation. **This is an argument from the BEAM's
representation rules, not a measurement; it must be measured before it is
relied on.** But it buys the wrong quantity, so the cost analysis is moot.

## Recommendation

**Take option 0 and stop there.** Nothing goes on the hot path until
depth-based data shows a backlog worth resolving more precisely. The metric
exists; what was missing was a harness that read it.

Concretely: `harness/fleet-scale/snapshot-stages.sh` reads `match`, `fanout`,
`flow.queue`, `flow.service` and `shed`, but not `flow.queue_depth`. That is a
defect in the harness, not the product, and it is why two full campaigns
produced no ingress-backlog data.

## Acceptance criteria, if hot-path work is ever done

S28 vs S29 measured the end-to-end delivery tail moving p95 29 → 48 ms and
p99 97 → 183 ms across two runs of the *same build under the same load*. So:

- **The end-to-end tail cannot be an acceptance gate.** Its run-to-run variance
  exceeds any per-message cost being contemplated.
- **The per-stage means can be.** Across those same two runs `match`, `fanout`
  and `flow.service` means stayed within a few percent per node, which makes
  them stable enough to detect a regression of the size at issue.
- Any A/B needs n≥5 runs per arm compared as distributions, not single-run
  percentiles.

## Verification (2026-08-21, 2-node `bondy-fleet-1`, cross-node relay load)

Option 0 implemented in `harness/fleet-scale/snapshot-stages.sh`: the probe now
reads `bondy_router_flow_queue_depth` as a 5th histogram (tuple element 5; shed
moves to 6).

Probe output under ~6.6k events/s of genuinely cross-node traffic:

    node 8576719c437778  flow.service {13252, 1381382, 95,183,303}
                         flow.depth   {13252,      36,  0,  0,  0}
    node 8ed9d15f70e018  flow.service {12386, 1863625,143,239,367}
                         flow.depth   {12386,      13,  0,  0,  0}

Three facts established:

1. **The metric populates.** Depth observation count equals flow.service count
   exactly on both nodes (13252/13252, 12386/12386) — every relay-ingress task
   records one. This is the data both earlier campaigns lacked.
2. **There was no relay-ingress backlog at this load.** Depth sums are 36 and 13
   over ~13k observations (mean ~0.002); p50/p95/p99 all 0. Worker mailboxes
   were empty at dequeue.
3. **Relay ingress really is the flow pool's only data-plane role.**
   `flow.queue` count is 0 while `flow.service` is ~13k on both nodes: every
   flow-pool task was relay ingress, none arrived via `cast/3`. This
   corroborates the claim in `bondy_router_worker.erl:169-190` from the outside.

**Scope limit:** this load (~6.6k events/s, 400 publishers, 2 nodes) is far
below the S28/S29 fleet runs (~10k publishes/s, ~25k relay tasks/s, 5 nodes).
It establishes that the probe works and that backlog is zero *here*. It does
NOT establish that relay-ingress backlog is absent at fleet scale — that needs
the next full run, which now has a probe capable of answering it.

### Probe hardening

The first version of this probe could not fail loudly. A mistyped metric name
returned `{0,...}`, indistinguishable from a declared metric with no
observations, because `bondy_metrics:with_name/1` returns `[]` for an
undeclared name rather than raising — so the `-1` sentinel never fired.
Verified live, then fixed with a `bondy_metrics:declared/0` membership guard:

    real name  -> passes
    _TYPO name -> {-1,-1,-1,-1,-1}

Note `bondy_metrics:declared/0` returns a MAP (`maps:from_list(ets:tab2list/1)`),
not a list — `length/1` on it raises badarg.

## S30 — the fleet-scale answer (2026-08-21)

Same load as S29 (50k pub VUs @ 5s, 200 users x 2000 subs, fanout 8, 5 nodes),
same snapshot cadence; the only addition is the depth probe.

**Relay ingress does not back up at fleet scale.** Over the 325 s steady window,
**8,306,108 relay-ingress tasks** (~25.6k/s cluster-wide):

    mean mailbox depth at dequeue = 0.0462   (sum 383,622 / 8,306,108 obs)
    p99 depth = 1-2 messages, every node
    shed = 0, every node
    flow.queue count = 0, every node (relay ingress is the pool's only role)

Converting via `depth x service` (service mean 62-73 us):

    implied wait, mean  ~ 0.046 x 68us ~= 3 us
    implied wait, p99   ~ 2     x 68us ~= 140 us

Delivery p99 for the same run was 72 **ms**. Relay-ingress queueing therefore
accounts for roughly **0.2 % of the p99 delivery budget**. It is not the tail.

**Conclusion: the delivery tail is not cross-node queueing and not the router.**
`match`, `fanout` and `flow.service` are all sub-400 us at p99; relay ingress is
sub-millisecond at p99. The remaining unmeasured segment is the subscriber's own
connection process (egress: per-subscriber send, WS framing, socket) plus the
client and network. That is where any future tail work should look — and option
1/2/3 of the table above would all have instrumented the wrong thing.

## The variance result, now with n=3

Three runs, same build, same load, same cluster:

| run | med | p95 | p99 | max |
|---|---|---|---|---|
| S28 | 5 ms | 29 ms | 97 ms | 1.85 s |
| S29 | 7 ms | 48 ms | 183 ms | 2.51 s |
| S30 | 5 ms | 23 ms (steady) | 72 ms | 709 ms |

p95 spans 23-48 ms and p99 spans 72-183 ms **with no change to the build**.
S30's steady p95 of 23 ms sits beside the s27 baseline of 18 ms. The
"regression" that started this investigation does not exist; it was one draw
from a wide distribution.

Two further consequences:

- The S29 observation that warmup beat steady does NOT replicate. In S30
  warmup p95 (44 ms) is *worse* than steady (23 ms) — the opposite ordering.
  Treat that S29 note as noise, not a finding.
- Per-LG trends refute clock skew a second time, independently: S30 per-LG p95
  spans 22-24 ms across all eight symmetric LGs.

**Mean depth is the stable statistic to track.** It is count-based rather than a
percentile, and it moved from 0.002 (2-node smoke) to 0.046 (fleet scale) —
a difference that reflects real load rather than run-to-run noise.

## Egress instrumentation (implemented 2026-08-21)

S30 left exactly one unmeasured segment: the subscriber's own connection
process, the last hop before the wire. This adds it, deliberately reusing the
shape already blessed for relay ingress rather than inventing a second idiom.

**New metrics**

    bondy_wamp_egress_queue_depth           mailbox depth at dequeue, by transport
    bondy_wamp_egress_service_microseconds  in-process handling time, by transport

**Emitter** `bondy_telemetry:wamp_egress/3` -> `[bondy, wamp, egress]`.
**Sink** `bondy_prometheus:handle_net_event/4` + the `attach_many` list.
**Call site** `bondy_wamp_ws_connection_handler:timed_outbound/3`, wrapping
both `?BONDY_REQ` clauses.

Depth rather than a queue wait, for the same reason as relay ingress: a router
delivery arrives as a plain `!` with no dispatch timestamp. Reading own
`message_queue_len` takes no lock.

**CAVEAT, stated at the call site and in the metric help:** for WebSocket the
service time is the ENCODE only. Cowboy performs the socket write after the
handler callback returns, so the send is out of scope. A transport whose
handler calls `Transport:send` itself would include it — hence the `transport`
label.

### Measured cost (the thing to be careful about)

2,000,000 iterations each, darwin/aarch64, OTP 29:

| operation | ns/op |
|---|---|
| `process_info(self(), message_queue_len)` | 14.4 |
| `erlang:monotonic_time(microsecond)` | 27.7 |
| `wamp_egress/3` -> telemetry -> sink -> 2 histograms | 111.3 |
| **total added per delivery** (1 + 2 + 1) | **181.1** |

At the S30 delivery rate (~70k/s cluster-wide): **12.7 ms/s ~= 1.3 % of ONE
core**, spread over 5 nodes x 8 vCPU — roughly 0.03 % of node CPU. At 250k
deliveries/s it would be ~4.5 % of one core.

The telemetry+histogram path is 61 % of the added cost; the two VM primitives
are nearly free. An obvious "optimisation" — skipping the depth observation
when depth is 0 — is REJECTED: a zero depth is a real reading (empty mailbox),
and dropping it would bias the distribution toward whatever backlog existed.
`bondy_prometheus_broker_publish_test:egress_zero_depth/0` locks that.

**Limits of this measurement:** single process, no scheduler contention on the
histograms, and aarch64 rather than the x86 Fly VM. It bounds the per-call cost;
it does not prove the system-level cost. Confirm on Fly against per-stage means
(`match`, `fanout`, `flow.service`), NOT the end-to-end tail — that statistic
was measured at p95 23/29/48 ms across three identical runs and cannot resolve
a 1 % CPU change.

### Verification

- `bondy_prometheus_broker_publish_test` — 8/8 eunit: both histograms move, a
  zero depth is recorded, malformed measurements do not raise (a raising
  telemetry handler is DETACHED by telemetry, which would silently kill every
  metric sharing the handler id).
- `bondy_prometheus_SUITE:egress_metrics_via_telemetry/1` — 6/6 CT on a booted
  node, driving emitter -> telemetry -> sink -> real scrape. This is the only
  test that can catch a missing `attach_many` entry; the eunit tests call
  `handle_net_event/4` directly and would stay green with the metric dead in
  production. Attachment cannot be asserted in eunit — `setup/0` returns
  `{error, badarg}` without a booted node and attaches nothing at all.
- Full eunit 3047 tests: the only failure is
  `bondy_db_journal_trimmer_test:trim_reclaims_journal_files/0`, confirmed
  PRE-EXISTING by re-running it with these changes stashed. `bondy_db` does not
  depend on `bondy_router`, so it is not reachable from this change.

### Not done

The TCP connection handler (`bondy_wamp_tcp_connection_handler`) is NOT
instrumented. The change is mechanical and the `transport` label already exists
for it, but the fleet harness drives WebSocket only, so there is no way to
exercise it under load yet — and shipping a second hot-path change that cannot
be verified violates the one-mechanism-per-increment rule. Next increment.

## S31 / S32 results (2026-08-21) — egress measured, and a fleet defect found

Two fleet-scale runs of the egress-instrumented build, 50k publisher VUs @
5s, 200 subscriber users x 2000 subs, fanout 8, on 5x performance-8x.

### The egress question is answered: it does not back up

Steady window (B->C differenced), S31:

| stage | obs | mean depth | p99 depth | mean service |
|---|---|---|---|---|
| relay ingress | 7,611,518 | 0.013 | 1 | 68.5us |
| egress | 25,000,243 | 0.108 | 13-21 | 7.95us |

`depth x service` at p99 ~= 92-267us, against a delivery p99 in the tens of ms.
Every segment inside Bondy — match, fanout, relay ingress, egress — is now
instrumented and sub-millisecond at p99 in a healthy run. The remaining tail is
below Bondy: socket, network, or client.

Note the WebSocket caveat holds: `egress.service` is encode-only, so DEPTH is
the discriminator and service is only the multiplier.

### The instrumentation is not the cause of the tail

| run | build | delivery p99 (steady) | max | publisher aborts |
|---|---|---|---|---|
| S30 | pre-egress | 72ms | 709ms | 0 |
| S31 | +egress | 1.29s | 5.51s | ~3,488 |
| S32 | +egress, IDENTICAL binary | 36.15s | 2m39s | ~3,133 |

S31 -> S32 is a 28x degradation with **zero code change**. A code delta cannot
produce a progression; only accumulating or environmental state can. The
measured cost (~181ns/delivery = ~0.3% of one core at 77k deliveries/s) cannot
move a p99 by 18x, and S31's damage was asymmetric across nodes while the
change is symmetric.

### Root cause candidate: the nodename boot race

One node per cluster boot comes up as `bondy@127.0.0.1` instead of
`bondy@$FLY_PRIVATE_IP` (`harness/fleet-scale/setup.sh:18` falls back silently
to the Dockerfile default). The cluster still forms, so nothing reports it.

| run | misnamed node | its fanout mean | healthy peers |
|---|---|---|---|
| S31 | 83e563a7 | 159,289us | 62-87us |
| S32 | 8ed9d15f | 435,899us | 78us |

A full stop/start reassigned which machine lost the race and **the pathology
moved with it** — a natural experiment. n=2, so this is strongly implicated,
not proved.

Plausible mechanism: `fanout` covers `do_publish` = send-per-local-subscriber
plus `forward_using_relay` per peer; a relay send blocks on distribution
backpressure, so a node on a degraded relay path has its publishers block for
seconds. `bondy_broker.erl` carries a standing REVIEW note that Erlang may
penalise a process fanning out to many destinations.

### Not done / next

1. Fail-fast guard in `setup.sh` (`[ -n "$FLY_PRIVATE_IP" ] || exit 1`) instead
   of the silent fallback — eliminate the failure mode rather than guard it.
2. Recreate the machines to clear on-disk state (Fly restarts preserve the
   rootfs; there is no `[mounts]` volume), then one confirming run. If fanout
   goes uniform, the diagnosis is proved.
3. The S31 -> S32 progression itself is still unexplained; the naming race does
   not obviously account for each run being worse than the last.
4. TCP handler instrumentation still deliberately not done.

**This fleet must not be used for regression measurement until 1 and 2 are
done.**

## S33 (2026-08-21) — confirming run. Diagnosis proved, instrumentation cleared.

Fresh deploy (clean rootfs), cluster-identity gate green, same binary and load
as S31/S32.

| | S30 (pre-egress) | S31 | S32 | **S33** |
|---|---|---|---|---|
| fanout spread | 64-77us | 62us-159ms | 78us-436ms | **62.8-74.1us** |
| delivery p99 (steady) | 72ms | 1.29s | 36.15s | **86ms** |
| p95 | 23ms | 26ms | 8.99s | **27ms** |
| med | 5ms | 4ms | 1.03s | **5ms** |

S33's p99 sits inside the established 72-183ms run-to-run band and fanout is
uniform across all five nodes. **The egress instrumentation causes no
regression**, and the S31/S32 blow-ups were the nodename boot race.

### Final egress numbers

| run | egress obs | mean depth | p99 depth | mean service |
|---|---|---|---|---|
| S31 | 25,000,243 | 0.108 | 13-21 | 7.95us |
| S33 | 25,042,966 | 0.373 | 16-21 | 8.30us |

`depth x service` at p99 ~= 208us worst case. With match, fanout, flow.service,
flow.depth and egress all sub-millisecond at p99, **the entire in-router path is
now accounted for**. The remaining delivery tail is below Bondy: socket,
network, or the k6 client.

Re-confirmed: aborts are the load regulator, not a tail driver. S33 had MORE
publisher aborts (~5,075) than S31 (~3,488) with a p99 15x better.

### Nodename boot race — root cause narrowed, gate added

One node per cluster boot comes up as `bondy@127.0.0.1`; which node varies.
MEASURED by tailing `fly logs` across a boot: `priv/hooks/pre_start` echoed the
CORRECT nodename on all five machines and one still came up wrong, with exactly
one pre_start per machine. So the environment is fine and the value is lost in
the relx vm.args substitution — a **product/release-tooling defect**
(`priv/hooks/pre_start`, `config/{prod,docker}/vm.args` are shipped files), not
a harness one. `bondy eval` was ruled out as the trigger: the misnamed node
logged `node=bondy@127.0.0.1` during its own startup, before any eval.

`check-tripwires.sh` now gates on cluster identity (each node's
`partisan:node()` vs its Fly `private_ip`), exit 2 on mismatch. Verified against
a known-bad cluster FIRST, then a clean one.

**Underlying fix still not implemented.** A `setup.sh` guard would not help —
that hypothesis is refuted. The fix belongs in the relx startup path: regenerate
vm.args from `vm.args.orig` unconditionally (or drop the build-time `vm.args`
from the image), and have Bondy refuse to boot when its resolved `-name` does
not match `BONDY_ERL_NODENAME`.
