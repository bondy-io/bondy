# Bondy monitoring stack

Prometheus + Grafana for the `bondy_db` / `bondy_oplog` / `bondy_mst`
storage and replication stack, plus Partisan cluster state — the same
signals the `bondy_observer_cli` Cluster (`C`) and Sync (`Y`) panes show,
as time series — and Grafana Tempo for the distributed traces Bondy
exports over OTLP.

## Quick start

```bash
# 1. Start one or more dev nodes (in the repo root)
just node1        # and optionally: just node2, just node3

# 2. Start the monitoring stack
cd monitoring
docker compose up -d

# 3. Open Grafana
open http://localhost:3000    # anonymous admin, no login
```

The dashboards are provisioned into the *Bondy* folder as a hub +
drill-down hierarchy (every dashboard links to the others; time range
and node selection carry across):

- **Bondy — Cluster Overview** (`bondy-cluster-overview`) — the landing
  page. Threshold-colored stats answer "is anything wrong?" at a
  glance: cluster state, **AE / sync health** (frontier-gap verdicts,
  re-bootstraps, sync errors, watermark-door volume, stalest pair),
  per-node vitals, inter-node link health. Anything non-green carries a
  data link to the dashboard that explains it.
- **Bondy — Cluster Sync / AAE** (`bondy-cluster-sync`) — the whole
  cluster's replication state on one screen: an **N×N node × peer
  matrix** (last-completed-sync age; a red row = that node cannot pull,
  a red column = nobody can pull from that peer) plus a gap-verdict
  matrix, trend panels, frontier convergence, the pair inspector
  (`pairA`/`pairB`), and Partisan link health.
- **Bondy — bondy_db / oplog / MST** (`bondy-db-oplog-mst`) — per-node
  storage detail: write path, applier, core substrate, leveled, MST &
  page store, secondary indexes.
- **Bondy — Router / WAMP**, **Bondy — Runtime / BEAM**, **Bondy —
  HTTP Connector** — per-node domain detail.
- **Bondy — Mail** (`bondy-mail`) — outbound email: relay health and the
  `mail_relay_down` alarm, send rate and duration, failures split by
  **nature** (permanent means someone has to change something; transient
  means it ran out of retries), backpressure (queue depth, queue wait,
  rejections, rate limiting) and retries. Empty on a node with no
  `mail.relay.*` configured, which is the dormant state rather than a
  fault.
- **Bondy — Cluster Graph** (`bondy-cluster-graph`) — live topology
  node graph (needs a running node; served from `/cluster/topology`).

The intended debugging flow is topsight-first: start at the Overview,
let a red/amber stat lead you to Cluster Sync / AAE, find the offending
(node, peer) cell in the matrix, set `pairA`/`pairB` for the pair
inspector, then jump to the node-detail dashboards for the mechanism.
Prometheus itself is at <http://localhost:9090>.

## Distributed tracing (Tempo)

Tempo receives the spans Bondy exports over OTLP/HTTP. Turn it on in
`bondy.conf`:

```
tracing.otlp.enabled = on
```

The schema's default endpoint (`http://localhost:4318`) matches the port
this stack publishes, so no further configuration is needed on the same
host; `tracing.service_name` (default `bondy`) is the `service.name`
every span carries. Bondy emits **retroactive spans** for router and SDK
RPC legs and the MCP edge, parented to the W3C `traceparent` the calling
system attached — by default an untraced request produces no span, and a
failed leg carries OTel error status.

To trace calls from clients that attach no context, make Bondy the trace
boundary (the behaviour API gateways implement):

```
tracing.mint.enabled = on
tracing.mint.ratio = 1.0
```

An untraced CALL then gets a context minted at the caller's node, which
rides Bondy's own propagation (both RPC legs, cross-node, the MCP
upstream `_meta`) and reaches callees; `ratio` head-samples the minting.
The call leg at the minting node is exported as the trace's **root**
span — Tempo's root-scoped TraceQL (all of Grafana **Traces
Drilldown**) only counts rooted traces, and the Drilldown app
additionally needs the Tempo metrics-generator this stack's
`tempo/tempo.yml` enables. A context the caller attached is always
honoured and never re-minted, and pub/sub is deliberately excluded —
like a message broker, Bondy carries publisher context verbatim and
mints nothing on that plane.

Explore the traces in Grafana (Explore → **Tempo** datasource): search
by service name, or paste a trace id — Bondy carries trace context
verbatim, so the id is the one the caller minted. Tempo's own query API
is at <http://localhost:3200> (`/api/traces/<trace-id>`); OTLP ingest is
on `:4318`.

Tempo's metrics-generator also runs the `service-graphs` and
`span-metrics` processors, remote-writing `traces_service_graph_*` and
`traces_spanmetrics_*` series into Prometheus — they back the
**Service graph** tab of the Tempo datasource in Explore and are
ordinary Prometheus series for dashboard panels (span-derived RED per
`service.name` / span name). The dev node configs set a per-node
`tracing.service_name` (`bondy-connect-node1` …) so the graph can distinguish
nodes. Edges: Tempo pairs a client span with its server child across
services, and completes an unpaired client span that carries a
`peer.service` attribute into an edge to a *virtual* node — Bondy sets
that attribute on its client-kind spans (the invocation leg carries
the callee's HELLO agent, the MCP upstream leg its upstream id), so
each node shows edges to the callees and upstreams it talks to, and an
unpaired root span yields the `user →` ingress edge. There is no
node-to-node edge: that would need a client span for the inter-node
forward itself, which Bondy does not emit.

## How it works

- Bondy exports Prometheus metrics on the **Admin API** HTTP listener at
  `/metrics` (node1: `18081`, node2: `18181`, node3: `18281`).
- `bondy_prometheus_db` (in `bondy_telemetry_exporter`) bridges the storage stack to
  that endpoint:
  - attaches to the `telemetry` events emitted by `bondy_oplog` and
    `bondy_mst` (WAL, applier, sync/AAE, schedulers, page store,
    secondary indexes) and folds them into Prometheus counters and
    histograms;
  - a `prometheus_collector` adds scrape-time gauges: Partisan
    membership/connectivity, per-instance lifecycle and applied-frontier
    signature, WAL writer state, per-(instance, peer) sync recency,
    substrate AE freshness lag, scheduler state, and a passthrough of the
    `bondy_metrics` registry (`bondy_oplog_core_*`).
- `monitoring/prometheus/prometheus.yml` scrapes the dev-cluster ports on
  the Docker host and attaches a `node` label per target; the dashboard's
  **Node** selector filters on it. Add/remove targets there for other
  topologies.

## Reading the dashboard

- **Cluster** — Partisan membership vs connectivity: an N×N
  connectivity matrix (observer × peer, green/red cells) plus a state
  timeline of link history, node readiness and OTP alarms.
- **Sync / AAE** — convergence is judged exactly like the observer_cli
  Sync pane: by the applied-frontier version vector, not the MST root.
  Each node exports a stable hash of each instance's frontier
  (`bondy_oplog_instance_frontier_hash`); an instance is **IN SYNC** when
  every selected node reports the same hash (computed in PromQL with
  `count_values`, no cross-node calls at scrape time). Divergence during
  active writes is normal — a *persistently* non-zero "Instances
  DIVERGED" stat is not.
- **Frontier sync matrix** — an N×N grid (row per node A, cell per
  node B) where each cell counts the shards whose frontiers differ
  between that pair; green `0` = the pair is converged. Clicking a cell
  jumps to the **Pair inspector**, which lists the diverged shards for
  that pair with their applied-sequence gap (how far apart), the pair's
  sync-session outcomes and last-sync age.
- **Write path / WAL / Applier / MST** — throughput, latency heatmaps
  and percentiles, backpressure state timelines and an integrity
  status-history panel (all rows should stay green).
- **Leveled projection store** — per-Bookie LSM state polled at scrape
  time (`leveled_bookie:book_status/1`, deduplicated per shared Bookie,
  parallel with a deadline): penciller work backlog (the write-stall
  signal), SST files per level, caches, journal compaction score, and
  sampled fetch-resolution levels (read amplification).
- **Router internals** — in-flight RPC promises (callee saturation),
  ranch listener saturation and accept/terminate rates, jobs-pool queue
  depth (async-work backpressure), Partisan connection counts per
  peer/channel, rate-limiter bucket and OIDC flow table sizes, and
  mailbox depth of critical singleton processes.
- **WAMP — sessions & transports** — session churn plus **close
  reasons** (the "why are my clients dropping" diagnostic), session
  duration, socket counts, router-initiated **ping RTT** per transport,
  and a drops/shed stat that should sit at zero (the NATS
  "slow consumers" analog).
- **WAMP — messaging & RPC** — message mix by type, RPC vs PubSub
  traffic, **call round-trip latency** (heatmap, quantiles,
  slowest-procedures ranking) plus **latency attribution** (callee
  execution vs router overhead, from the invocation-leg histogram),
  **in-flight invocations per procedure** (scrape-time, drift-free —
  the per-procedure consumer-lag analog), dropped messages/events by
  reason, registration/subscription churn and realm/user lifecycle
  events.
- **HTTP — API gateway** — aggregate status-class/error/duration
  panels plus **per-route golden signals** (rate, error %, p95 duration
  by route template — bounded cardinality, RED-style).
- **BEAM VM** — memory, msacc scheduler-time breakdown, run queues, GC
  and system-monitor events. RPC promise timeouts and rate-limiter
  denials live in the Router internals row and should sit at zero.

## Notes

- Per-cell and per-read hot-path telemetry events are intentionally not
  bridged (observer effect); their aggregates arrive via the wait-free
  `bondy_metrics` registry instead.
- Histogram families carry only low-cardinality labels (stage, kind,
  outcome). Counters may carry `instance_id`.
- On Linux, `host.docker.internal` is provided via
  `extra_hosts: host-gateway` in the compose file.
- The Grafana instance is provisioned for anonymous admin access —
  workstation use only.
