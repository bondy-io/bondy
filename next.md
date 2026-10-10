# Handoff: departed-node reclamation (develop-bdb)

Only facts established by running something or reading the code.

## Working rules

- Work in `~/Work/Bondy/bondy` on `develop-bdb`. Never commit or push.
- Ask the user before every test, TLC or Isabelle run. Run one at a time, always under a guard:
  - tests: `<scratch>/guarded.sh LOG just ct apps/bondy_router/test/<SUITE>`;
  - `<scratch>` is `/private/tmp/claude-501/-Users-aramallo-Work-Bondy-bondy/22f39acc-e4a6-4923-bdb3-eb8ad2bd107c/scratchpad`.
- Stateful behaviour is tested in CT, never eunit.
- Reclamation, compaction and reap changes go through `proofs/tla` before code.

## What broke, and why (bisected by the previous session)

`937eae11` ("Clustering fixes") made four tests fail; `06845f29` passes them all:

- `bondy_prometheus_partisan_test`: `bondy_cluster_channel_connections` left `bondy_prometheus` for the collector; only `_target` remains event-driven.
- `bondy_rib_reclamation_cluster_SUITE`, `bondy_reclamation_cluster_SUITE`: `bondy_oplog_instance:reclamation_members/0` answers `{error, no_members}` for a sole member with clustering enabled, so a 2-node suite that retires one node confirms nothing.
- `bondy_oplog_compaction_cluster_SUITE`: unmodified; passed at HEAD on 2026-10-15 14:44 (2 passed, 1 skipped).

## Uncommitted changes (the whole tree)

- `apps/bondy_telemetry_exporter/test/bondy_prometheus_partisan_test.erl`: assertion on the moved gauge removed.
- `apps/bondy_router/test/bondy_reclamation_cluster_SUITE.erl`: 3 nodes; nothing else.
- `apps/bondy_router/test/bondy_rib_reclamation_cluster_SUITE.erl`: 3 nodes; a pre-retirement check that both seeded cells carry a positive count; read helpers shared with `has_cell/3` and `do_diagnose/1`.

Everything else is at HEAD. `rebar3 as test compile` passes.

## Results (ran 2026-10-15, HEAD source, logs in `<scratch>`)

- `bondy_prometheus_partisan_test`: 5 tests, 0 failures (`prom.log`).
- `bondy_reclamation_cluster_SUITE`: 2 passed (`recl.log`).
- `bondy_rib_reclamation_cluster_SUITE`: FAILED, `registration cell survived retirement`; all four artifacts survive (`rib.log`). The previous session's 10:48 run at HEAD (`af_rib3.log` in its scratchpad) failed the same way.

## The RIB failure, read from the run and the code

- The membership event starts a retirement pass at once (`bondy_oplog_origin_retirement:handle_info({partisan_membership, _})`), so the suite's explicit pass reports `origins_reaped => []` with N2's seven origins already in `swept`. The reap writes value-preserving frames (`bondy_oplog_cell_utils:reap_one_cell/6`), so `bondy_db:read` keeps returning `count => 1`.
- `reclaim_stable_cells/1` on every shard that holds a cell returns `{ok, scanned => 1, discarded => 0}`: a stability point exists and the sweep ran.
- `bondy_oplog_crdt_owned_reading:stabilize/2` and `bondy_oplog_crdt_struct:zero_discard/2` discard only when the cell's head HLC is strictly below the point. HEAD's point is the HLC of the last key every member confirms. In a quiescent shard that key is the departed node's own write, so the cell's HLC equals the point. The `stability_point/1` doc names this hole ("the tail tombstone a strict `<` bound would otherwise never license") as covered only by the clustering-disabled tick.
- Before `937eae11`, the 2-node suite passed through that tick: the survivor was a sole member. With two survivors nothing advances the shard.
- The suite's `do_diagnose/1` computes a dead set as "frontier origins minus local origins", which with 3 nodes includes the live third node's origins; its direct reap then reaped `registry-4`'s cell for one of them. It runs only after the assertion has already failed, but it mutates state wrongly.

## Reverted on 2026-10-15 (do not redo without a model)

The previous session changed `reclamation_stability_point/1` to the HLC of the first unconfirmed tree key, or a fresh tick when every key is confirmed, with a `BoundMode` in `JoinInstall.tla`, three new cfgs, two new CT cases, a stateful eunit case and a post-reap `count = 0` assertion. It made the RIB suite pass. It is reverted because nothing proved it: `_FirstUnconfirmed.cfg` violated its own `NoStuckTombstone` at depth 9; `BelowClaims` was never evaluated; `compacted_tombstone_is_reclaimed` failed in CT; no model has an undelivered event from another origin with a lower HLC.

## Model (ran 2026-10-15, logs in `<scratch>/tla/ji/`)

`JoinInstall.tla` gained `BoundMode` (`claims` = the shipped stand-in, every existing cfg sets it; `last_confirmed` = the code's point; `first_unconfirmed` = the proposed point, past every event when the walk finds nothing uncovered, an empty tree included), `NoStuckTombstone` and `BelowClaims`. Three new cfgs on the `CompactMembers` base:

- `_LastConfirmed.cfg`: `NoStuckTombstone` violated at depth 9 (`last_confirmed.log`). Trace: add, remove, both pulled and applied, two `Reserve` steps make every claim durable; both cells empty, the remove is the newest key, the bound equals the cell's HLC. The RIB defect, in the model.
- `_FirstUnconfirmed.cfg`: clean, 2,075,539 distinct states, depth 29, invariants `SettledSound SomeoneServes CompactedClaimed NoStrandedRecord NoStuckTombstone` (`first_unconfirmed.log`).
- `_Reap_FirstUnconfirmed.cfg` (crash + reap, `MaxEvents = 3`): no violation in 19,666,863 distinct states; the guard stopped it at 897 s with 6,064,115 states on the queue and the 2 GB state-dir cap reached. NOT exhaustive (`reap_first_unconfirmed.log`).
- `BelowClaims` has not been checked.

## Code change (2026-10-15, after the model)

`bondy_oplog_instance`:

- `reclamation_stability_point/1` → `clustered_stability_point/2`: confirmation first (`confirmed_peer_states/2`), then `first_uncovered_point/2`: the walk `first_hole/2` (shared with `compute_frontier_for/2`, whose behaviour is unchanged) returns `all_covered` → `{ok, fresh_tick}`, `{hole, Key, Before}` → `Key`'s HLC, `no_witness` → `{error, no_frontier}`, `unservable` → `{error, unservable}`.
- `{error, idle}` is gone: an empty tree walks like any other and ticks once every member has a recorded frontier. `#state{mst = undefined}` still answers `{error, no_frontier}`.
- `frontier_stability_point/1` no longer takes `undefined` or `unservable`.
- `bondy_oplog_applier` I2 reworded to what the point certifies: every member holds every event this replica's tree holds with HLC `<` the point.

`bondy_oplog_reclamation_test`: `empty_tree_is_idle_not_stalled` → `empty_tree_is_confirmed_then_ticks` (unconfirmed while the ghost has no frontier; `{ok, SP}` and a sweep with 0 discards once it has one); `confirmed_frontier_is_hand_computed` asserts the point is e4's HLC, above e3's; the `undefined` assertion dropped from `non_event_frontier_is_a_named_error`.

Two refinements after the first runs:

- `{error, idle}` is back, with a narrower meaning: the instance has applied nothing (`bondy_oplog_registry:frontier/1` empty), so no cell can exist. `bondy_oplog_peer_state:record_sync_complete/3` keeps the previously recorded frontier on an empty report, so a never-written shard would otherwise be `unconfirmed` forever and raise stall telemetry on every pass. A tree emptied by compaction keeps its frontier and is not idle.
- A first key no witness covers answers `{error, no_frontier}` (`bondy_oplog_frontier_provenance_test:the_stability_point_waits_for_the_own_checkpoint/1`): more conservative than the model's mode, never less.

`bondy_reclamation_cluster_SUITE` gained `compacted_tombstone_is_reclaimed`: compaction empties N1's tree (`bondy_oplog_instance:root_hash/1` is `undefined`) while the cell remains; reclamation then removes it on every node.

Results with the change (logs in `<scratch>`):

- `bondy_rib_reclamation_cluster_SUITE`: 1 passed (`rib2.log`).
- `bondy_oplog_reclamation_test`: 9 passed (`eunit_recl2.log`).
- `bondy_reclamation_cluster_SUITE`: 3 passed (`recl2.log`).
- `bondy_oplog_compaction_cluster_SUITE`: 2 passed, 1 skipped by the suite (`comp.log`).
- Gate: `xref` and `xref-layering` clean; `spellcheck` fails on pre-existing typos in files this work does not touch (`gate_spellcheck.log`); `dialyzer` 278 warnings, 3 in `bondy_oplog_instance` at lines this work does not touch, same 3 as the 2026-10-14 baseline (`gate_dialyzer.log`); `eqwalizer` exits 0 with 3990 pre-existing errors, the one at the new `mst = undefined` clause being the same class as five older clauses in the module (`gate_eqwalizer.log`); full CT 2130 passed, 28 skipped, 0 failed (`gate_ct.log`); proper 114/114 (`gate_proper.log`); eunit first run 3718 tests, 2 failures (`gate_eunit.log`): the provenance test above, fixed, and `bondy_oplog_compaction_fused_test:unservable_own_root_rebuild_holds_unapplied_applier/0`, which passes in isolation (`eunit_three.log`, 52/52). Second full eunit after the fix: 3718 tests, 0 failures (`gate_eunit2.log`).

## Open

- `_Reap_FirstUnconfirmed.cfg` is not exhaustive under the default guard; `BelowClaims` unchecked.
- Whether the RIB suite's `do_diagnose/1` dead set should come from the retirement module instead.
