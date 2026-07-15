# Jepsen tests for bondy_mst

A 3-node cluster, 1 namespace (`jepsen`), 10 tables (`t0`..`t9`),
**16 leveled-backed projection shards shared across every table** —
16 Bookies per node, not 160 — wired together over Distributed
Erlang via the existing `bondy_oplog_transport_disterl` transport.
The topology is `bondy_db_topology_shared_shards`, which keeps the
per-shard write-concurrency boundary while amortising the Bookie
count across tables (each Bookie holds the shard-slice of every
table; bucket disambiguates entity types within a Bookie).

Modelled directly on
[`rabbitmq/ra-kv-store`](https://github.com/rabbitmq/ra-kv-store)'s
Jepsen integration.

## Layout

```
jepsen/
├── docker/                       # Compose harness: 1 control + 3 nodes
│   ├── docker-compose.yml
│   ├── provision.sh
│   └── shared/{init-control,init-node}.sh
└── jepsen.bondymst/              # The Jepsen test itself
    ├── project.clj
    └── src/main/{clojure/jepsen/bondymst.clj,
                  java/io/leapsight/jepsen/Utils.java}
```

The Erlang side that the test drives lives at
`jepsen/bondy_mst_jepsen/` — a sibling rebar3 project that depends on
`bondy_mst` via a `_checkouts/` symlink to the repo root. It opens
the 10×16 table layout, registers a disterl sync dispatch + net-
kernel monitor, and exposes a small Cowboy HTTP shim on port 8080.

## 1. Build the release

The release must be built on Linux because it runs inside the Debian
node containers. The Makefile target does that inside a one-shot
Docker container:

```sh
make rel-jepsen
```

The tarball ends up at `jepsen/jepsen.bondymst/bondy_mst_jepsen_release-0.4.0.tar.gz`.

## 2. Bring up the cluster

```sh
make jepsen-up      # generates ssh key, brings up compose, runs provision.sh
```

Or, equivalently:

```sh
cd jepsen/docker
ssh-keygen -t rsa -m pem -f shared/jepsen-bot -C jepsen-bot -N ''
docker compose up --detach
./provision.sh
```

## 3. Run a test

Open a shell in the control container and launch a test:

```sh
docker exec -it jepsen-control bash
cd /root/jepsen.bondymst

# CRDT set-convergence under partition + kill (the headline check):
lein run test \
  --nodes n1,n2,n3 \
  --ssh-private-key /root/shared/jepsen-bot \
  --workload set --crdt-module aw_set \
  --nemesis combined \
  --time-limit 60 --concurrency 10 --rate 10

# pn_counter convergence:
lein run test --nodes n1,n2,n3 --ssh-private-key /root/shared/jepsen-bot \
  --workload counter --crdt-module pn_counter --nemesis combined \
  --time-limit 60 --concurrency 10 --rate 10
```

### Workloads

| `--workload` | What it checks | `--crdt-module` |
|---|---|---|
| `set` | **Convergence**: every acked add reaches every replica after the nemesis heals (`set-full`, `lost-count 0` + identical final reads). Add-only — the add-wins/remove-wins/2P *conflict* semantics are pinned by the lib's PropEr suites, not here. | `aw_set`, `rw_set`, `two_p_set`, `g_set` |
| `counter` | **Convergence**: after heal, every replica's final read is equal and within `[acked, attempted]` increments. Uses a convergence checker, not jepsen's stock `checker/counter` (that one assumes a *linearizable* counter — stale mid-partition reads, which a CRDT permits, would be flagged). | `pn_counter` |
| `register` | LWW + CAS — a timeline stress/shape probe only (a CRDT register is not linearizable). | — |

Common options:

| Flag | Meaning |
|---|---|
| `--crdt-module` | Native CRDT under test (`aw_set`, `rw_set`, `two_p_set`, `g_set`, `pn_counter`). Threaded into `bondy_db:open_table`. Unset → `--fold-module` drives selection. |
| `--nemesis` | `kill-erlang-vm`, `random-partition-halves`, `partition-halves`, `partition-majorities-ring`, `partition-random-node`, `combined`. |
| `--network-partition-nemesis` | Partition variant used by `--nemesis combined`. |
| `--random-nodes` | How many nodes the kill nemesis hits at once. |
| `--time-before-disruption`, `--disruption-duration` | Nemesis pacing. |
| `--sync-interval-ms` | bondy_mst sync scheduler tick (default 200ms). |
| `--shard-count` | Shards per table; default 16. Has to match the release config. |
| `--fold-module` | `lww_register` (default), `strict_register`. |

## Tear down

```sh
make jepsen-down
```

## How the cluster wiring works

- Each node boots `bondy_mst_jepsen_release` with a per-node sname
  `bondy_mst@<host>` and a shared cookie.
- `bondy_mst_jepsen_cluster` opens `bondy_db:open(jepsen, ...)` with
  the `shared_shards` topology and `shard_count = 16`, then opens 10
  tables that all route into the same 16 Bookies.
- `bondy_mst_jepsen_net_monitor` subscribes to `net_kernel:monitor_nodes/2`
  and maintains an ETS table of `{peer, up|down}`, attempting reconnects
  every second for any down peer.
- `bondy_mst_jepsen_peer_source` returns the currently-up subset of the
  configured peer list to the sync scheduler.
- `bondy_mst_jepsen_dispatch` is the scheduler's dispatch fun — for
  each instance × peer it spawns one async `bondy_oplog_sync_session`
  over `bondy_oplog_transport_disterl`.
- The HTTP shim (`bondy_mst_jepsen_http_handler`) maps the
  rakvstore-style verbs onto `bondy_db:read/3` and `bondy_db:apply/4`.
  The Java client deterministically routes Jepsen's integer keys to
  one of the 10 tables (`key mod 10`) so the workload spreads across
  every table — and therefore every shard.
