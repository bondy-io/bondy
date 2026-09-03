# Jepsen tests for the Bondy router

A [Jepsen](https://jepsen.io) test that installs the **real Bondy release**
on three Debian nodes, forms a Partisan cluster, drives it through the Admin
API while partitioning the network and crashing nodes, and checks — after the
cluster heals — that every acknowledged write is present on every replica.

It is the sibling of [`jepsen.bondymst`](../jepsen.bondymst/README.md), which
tests the replication substrate (`bondy_mst`) through a purpose-built HTTP
shim. This one tests Bondy itself: the release a deployment ships, its
configuration, its cluster formation, and the full durable path
`bondy_db → bondy_oplog → anti-entropy` under faults.

## Layout

```
jepsen/
├── docker/                      # Compose harness shared with jepsen.bondymst:
│   ├── docker-compose.yml       #   1 control + 3 trixie nodes (NET_ADMIN, sshd)
│   ├── provision.sh
│   └── shared/{init-control,init-node}.sh
└── jepsen.bondy/                # This test
    ├── project.clj
    ├── bondy-<vsn>.tar.gz       # written by `just rel-jepsen-bondy` (untracked)
    └── src/main/{clojure/jepsen/bondy.clj,
                  java/io/leapsight/jepsen/bondy/Utils.java}
```

## 1. Package the release

The nodes run the release out of the production image, so first build it,
then extract it into the tarball the test installs:

```sh
just docker-build        # deployment/Dockerfile -> bondy-prod:latest
just rel-jepsen-bondy    # -> jepsen/jepsen.bondy/bondy-<vsn>.tar.gz
```

The image is the release: same architecture as the node containers, native
dependencies already compiled, and exactly the bytes a deployment would run.

## 2. Bring up the cluster

```sh
just jepsen-up           # compose up + provision (Java 21, lein, sshd, iptables)
```

## 3. Run a test

```sh
docker exec -it jepsen-control bash
cd /root/jepsen.bondy

# Smoke: no faults. Proves install, configuration, cluster formation and the
# workload end to end.
lein run test --nodes n1,n2,n3 --ssh-private-key /root/shared/jepsen-bot \
  --workload users --nemesis none --time-limit 20 --concurrency 10 --rate 10

# Convergence under partition:
lein run test --nodes n1,n2,n3 --ssh-private-key /root/shared/jepsen-bot \
  --workload users --nemesis random-partition-halves \
  --time-limit 60 --concurrency 10 --rate 10

# ...under crash (kill -9 of the VM, then restart on the same data dir):
lein run test --nodes n1,n2,n3 --ssh-private-key /root/shared/jepsen-bot \
  --workload users --nemesis kill-erlang-vm --time-limit 60

# ...under both at once:
lein run test --nodes n1,n2,n3 --ssh-private-key /root/shared/jepsen-bot \
  --workload users --nemesis combined --time-limit 90
```

Results land under `store/<test-name>/<timestamp>/` in this directory;
`lein run serve` browses them.

### Workloads

| Workload | Writes | Final read | Checker | What a failure means |
|---|---|---|---|---|
| `users` | `POST /realms/:r/users {"username": "u<N>"}` on a random node | `GET /realms/:r/users` from every worker (so ≥ 3 per node) | `every-replica` (ours) + `checker/set-full {:linearizable? false}` | An acknowledged user is missing from some replica's final read: durable data did not converge within the recovery wait |

Reading the verdict. The claim is per replica, and the `every-replica`
checker states it directly: after the heal and the recovery wait, **every**
final read — one per worker, several per node, each stamped with the node it
came from — must contain **every** acknowledged add; it reports the missing
elements per node otherwise. `set-full` is kept for its latency statistics,
but its own `lost` verdict is decided against a single "most final" read, so
a replica permanently missing elements shows up there as merely `stale`
whenever that last read landed on a converged node (observed: `set-full`
green while n1 and n3 were each missing acknowledged users in every one of
their reads). Both checkers must be green.

Measured on the compose cluster (2026-09-03): partition alone and kill alone
converge within 15 s; a node killed *while* partitioned (`combined`) left two
replicas short at 30 s and at 60 s and converged by 120 s — the lagging
replica detects a frontier gap against the restarted node, the scheduler
flags a catalogue re-bootstrap only after that repeats across two complete
sync rounds plus a settle, and the re-bootstrap then completes in under
30 s. Hence the 120 s default; a shorter `--recovery-wait` measures that
tail rather than judging it.

Op outcome mapping (the correctness-relevant decision, in `add-type`):
2xx and `bondy.error.already_exists` are `:ok` (the element is in the set);
other 4xx and a refused connection are `:fail` (nothing was written); 5xx,
timeouts and other I/O failures are `:info` (indeterminate — `set-full`
tolerates either outcome for those).

### Options

| Option | Default | Meaning |
|---|---|---|
| `--nemesis` | `none` | `none`, `kill-erlang-vm`, `random-partition-halves`, `partition-halves`, `partition-majorities-ring`, `partition-random-node`, `combined` |
| `--recovery-wait` | 120 | Seconds between the heal and the final reads (see "Reading the verdict": `combined` faults converge in (60, 120] s on the compose cluster) |
| `--aae-interval-ms` | 500 | `db.aae.interval` |
| `--ready-timeout` | 120 | Seconds a node has to answer `/ready` = 204 at setup |
| `--realm` | `com.jepsen.bondy` | The realm the users are written into |
| `--erlang-distribution-url` | newest `bondy-*.tar.gz` here | The release tarball |

## How the cluster wiring works

`db/setup!` installs the tarball at `/bondy` (the release's `pre_start` hook
hardcodes that path; it is not relocatable), writes `etc/bondy.conf`
(rendered by `Utils.configuration`: the node's own IP as `cluster.peer_ip`,
every node's `bondy@<ip>:18086` under `cluster.peer_discovery.config.addresses`
for `partisan_peer_discovery_list`, anti-entropy on) and
`etc/security_config.json` (the workload realm, applied on every boot), then
starts `bin/bondy daemon` with `RELX_REPLACE_OS_VARS=true` and
`BONDY_ERL_NODENAME=bondy@<ip>` — the same naming a Fly deployment uses — and
blocks until `/ready` answers 204. A node that boots degraded (its durable
store failed to open) answers 503 and fails setup instead of taking part.

The `kill-erlang-vm` nemesis is `killall -9 beam.smp` followed by
`bin/bondy daemon` on the same data directory, so it also exercises WAL
replay and MST recovery on restart.

## Tear down

```sh
just jepsen-down
```
