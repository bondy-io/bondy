# bondy_db

Consumer-facing database facade and storage topologies for Bondy.

`bondy_db` is the upper of the two database layers. It owns:

- the **table API** (`bondy_db`): `open/2`, `open_table/3`, writes
  (`apply/4`, `apply_async/4`, `apply_batch/4`, `map_update/4`,
  `counter_inc/4`, `delete/3`), reads (`read/3`, `range/5`, `range_all/5`,
  `list/2`, `fold/6`), secondary-index reads (`index_get/5`,
  `index_range/6`), the freshness fence (`ensure_fresh/2`) and `info/1`;
- the **storage topologies** (`bondy_db_topology_*`): the per-entity,
  shared-shards and single-bookie layouts over leveled, and the in-memory
  layout;
- the **topology manifest** (`bondy_db_manifest`), which records the keying
  configuration of a durable database on its first open and checks it on
  every later open;
- the **leveled integration**: the Bookie supervisor (`bondy_db_leveled_sup`),
  the journal trimmer (`bondy_db_journal_trimmer`) and the durable projection
  adapter (`bondy_db_projection_leveled`);
- the **relation layer** (`bondy_relation`) and the pagination contract
  (`bondy_pagination`) that list and page the contents of a table.

It depends on `bondy_oplog` (the replication framework, the read substrate
and the CRDT catalogue) and on `leveled` (the durable backend). At start it
sets the `latency_probe` key of the `bondy_oplog` application environment to
`{bondy_db, probe_write}`, so that the `bondy_oplog` latency monitor has a
write to time on an idle node.

The architecture chapters are in `doc_extras/architecture/`, starting with
`README.md`.
