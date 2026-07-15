# bondy_db

Consumer-facing database facade and storage topologies for Bondy.

`bondy_db` is the upper of the two extracted database layers. It owns:

- the **public table API** (`bondy_db`) — `open_table`, `apply/4`,
  `apply_batch/4`, `read/3`, `range/5`, secondary-index reads, `info/1`;
- the **storage topologies** (`bondy_db_topology_*`) — per-entity, shared-shards,
  single-bookie and in-memory layouts;
- the **leveled integration** — the bookie supervisor (`bondy_db_leveled_sup`),
  the durable projection adapter (`bondy_db_projection_leveled`) and the
  leveled fold-tag (`bondy_db_leveled_tag`).

It depends on `bondy_oplog` (the replication framework and CRDT catalogue) and
on `leveled` (the durable backend). At start it installs the leveled fold-tag
and registers its idle-probe write with the `bondy_oplog` latency monitor.
