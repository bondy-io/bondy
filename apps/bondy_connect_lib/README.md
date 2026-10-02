bondy_connect_lib
=====

Bondy's shared library: data structures (`bondy_connect_interval_set`, …), the
hybrid logical clock (`bondy_connect_hlc`), errors, and `bondy_connect_table_manager` — the
process that owns ETS tables on behalf of others and is their heir, so a
table outlives the process that uses it and survives that process's
restart.

The manager is the one process this application runs (`bondy_connect_lib_sup`).
It is started here, by the library every Bondy application depends on, so
it is up before any of them, including those that start before the router's
own supervision tree. Borrow tables with
`bondy_connect_table_manager:get_or_create/2` (manager-owned) or `add_or_claim/2`
(process-owned, manager as heir); never create a table in a supervisor's
`init/1` to make it outlive a process.
