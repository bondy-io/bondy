# Bondy monitoring stack

Prometheus + Grafana for the `bondy_db` / `bondy_oplog` / `bondy_mst`
storage and replication stack, plus Partisan cluster state — the same
signals the `bondy_observer_cli` Cluster (`C`) and Sync (`Y`) panes show,
as time series.

## Quick start

```bash
# 1. Start one or more dev nodes (in the repo root)
make node1        # and optionally: make node2, make node3

# 2. Start the monitoring stack
cd monitoring
docker compose up -d

# 3. Open Grafana
open http://localhost:3000    # anonymous admin, no login
```

The provisioned dashboard is **Bondy — bondy_db / oplog / MST** in the
*Bondy* folder. Prometheus itself is at <http://localhost:9090>.

## How it works

- Bondy exports Prometheus metrics on the **Admin API** HTTP listener at
  `/metrics` (node1: `18081`, node2: `18181`, node3: `18281`).
- `bondy_prometheus_db` (in `bondy_router`) bridges the storage stack to
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
- **WAMP / HTTP / BEAM VM** — router-level traffic (message mix by
  type, RPC vs PubSub, session churn and duration), **call round-trip
  latency** (heatmap, quantiles and slowest-procedures ranking, observed
  at RPC-promise resolution), registration/subscription churn,
  realm/user lifecycle events, HTTP listener health, and VM depth
  including the msacc scheduler-time breakdown and system-monitor
  events. RPC promise timeouts and rate-limiter denials live in the
  Router internals row and should sit at zero.

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
