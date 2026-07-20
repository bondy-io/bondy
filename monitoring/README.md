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

- **Cluster** — Partisan membership vs connectivity per node; the
  connectivity matrix is red on any member a node cannot reach.
- **Sync / AAE** — convergence is judged exactly like the observer_cli
  Sync pane: by the applied-frontier version vector, not the MST root.
  Each node exports a stable hash of each instance's frontier
  (`bondy_oplog_instance_frontier_hash`); an instance is **IN SYNC** when
  every selected node reports the same hash (computed in PromQL with
  `count_values`, no cross-node calls at scrape time). Divergence during
  active writes is normal — a *persistently* non-zero "Instances
  DIVERGED" stat is not.
- **Write path / WAL / Applier / MST** — throughput, latency
  percentiles, backpressure and integrity counters. Backpressure, fault
  and corruption panels should sit at zero.

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
