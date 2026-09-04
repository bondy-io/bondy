# Understanding convergence in bondy_db

`bondy_db` replicates without consensus: any replica accepts a write and the
cluster reconciles afterwards. This document explains what "reconciled" means
precisely, what a replica does to get there, and why the observable signals are
the ones they are — because the interesting question in an eventually consistent
store is never *whether* it converges, but how you know it has.

It assumes the operation key and the applied frontier as
`doc/guides/database/prefix_closure.md` defines them.

## What converges: the applied frontier

Every replicated operation carries a key `{HLC, Origin, Seq}`. A replica's
**applied frontier** is the per-origin maximum `Seq` it has applied — a version
vector over origins.

The frontier is the unit of comparison because it states what a replica *has*
independently of how it got there. Two replicas holding the same frontier hold
the same operations. `bondy_prometheus_db` exports a stable hash of it as
`bondy_oplog_instance_frontier_hash`, computed locally, so cluster-wide
convergence is derivable in PromQL with no scrape-time network traffic: an
instance is converged when every node reports the same hash.

The frontier is a maximum, not a prefix. It records that `Seq` 7 arrived from an
origin; it does not, by itself, record that 5 and 6 did. Closing that gap is the
fold's job — see `doc/guides/database/prefix_closure.md`.

## The sync round

Anti-entropy is pull-based. On each `db.aae.interval` tick,
`bondy_oplog_sync_scheduler` sorts the instances, rotates the list by a
monotonic tick counter — so a scarce `aae_max_concurrency` cap starves nobody —
picks peers for those that win a slot, and `bondy_oplog_sync_session` runs a
round against each:

1. **Fetch the peer's frontier.** The responder answers `get_frontier` only
   after an installed-consistency barrier, so the frontier it reports counts
   operations it can actually serve rather than ones still in flight through its
   own pipeline. The frontier is fetched *before* the root, so the round's tree
   is same-or-newer than the frontier it is judged against.
2. **Fetch the peer's MST root.** Equal roots end the round having moved
   nothing.
3. **Pull the differing pages.** The tree structure localises the difference, so
   bytes moved are proportional to divergence, not to data size.
4. **Integrate.** `bondy_oplog_instance:integrate_peer_root/N` merges the pulled
   pages and hands the operations to `bondy_oplog_applier`.

A round that pulled everything it set out to pull is a **complete round**. A
round capped by its page budget is not, and the distinction is load-bearing:
frontier adoption and the gap verdict are both gated on completeness, because a
capped round has not seen enough to license either.

## Three ways a completed round can still lose data

Each of steps 1–4 can succeed while an operation goes missing, and the round
still records success. A replica that concludes "we agree" from such a round
then acts on it — it lets the origin reclaim the space, and the loss becomes
permanent and invisible to the frontier oracle, because a maximum merges past a
hole. Three mechanisms close that.

### The watermark door

A replica truncates history it has confirmed; its **watermark** is how far. The
rule "an operation at or below the watermark has already been folded" is false
for an operation a peer wrote while the round was in flight: it is below the
watermark and has never been applied here.

`watermark_door/3` in `bondy_oplog_instance` tests application directly instead
of inferring it from the watermark. A never-applied operation arriving at or
below the watermark is accepted — fused and projection instances fold it into
the projection inline via `apply_cell_pairs_mux`, applier-backed instances hold
it for replay and truncate strictly below the smallest held key. Only an
operation the applied frontier genuinely witnesses is dropped.

The same door runs on the live-push path in `do_append_remote`, so a
below-watermark live event is accepted rather than discarded, and both MST entry
paths deliver through the shared `deliver_remote/1`.

Counter: `bondy_oplog_doored_events_total`, labelled `action` (`folded` or
`held`). Thousands per replica under sustained write load is the expected
steady state, not an anomaly.

### Pinned roots

Pages pulled from a peer are unreachable from the local root until integrate.
Between pull and integrate they look like garbage, and a compaction sweeping in
that window collects them. `bondy_mst:merge/2` then treats the missing subtree as
empty and keeps going, so the round completes having silently dropped it — while
`confirm_root` licenses the origin to truncate.

So a sync session pins the root it is pulling (`pin_peer_root/2`, consumed by a
successful integrate, 120s TTL) and `truncate_below_or_equal/4` passes the pins
to `bondy_mst:gc/2` as keep-roots. `integrate_peer_root` additionally re-checks
`missing_set/2` atomically with the merge — same process as the GC — and answers
a retryable `{error, {peer_pages_missing, N}}` so the session re-pulls within
its budget.

If a sweep finds the current root unservable regardless, it aborts rather than
sweeping around the hole and amplifying it. Counter:
`bondy_mst_gc_aborted_total`, labelled `classification` (`deleted`,
`tombstoned`, `transient`). Per-hash evidence outlives the log —
`bondy_oplog_instance:gc_aborts/0,1`.

### The compaction witness rule and the truncation cap

Compaction truncates what it has evidence every replica holds. That witness is a
peer's root **or** its recorded applied frontier from `peer_state`: a rootless
row carrying a VV still constrains the decision, and only a rootless row with no
VV confirms nothing. Admitting the VV is what lets a peer that has itself
compacted continue to constrain compaction here, instead of a pair of replicas
ping-ponging their truncation points. Reclamation
(`confirmed_stability_point`) deliberately remains root-only.

Separately, `finalize_catalogue_compaction/3` caps the truncation point below
the first **never-applied** key at or below the frontier — `Seq` above the
applied VV and the origin not retired. A cycle may therefore truncate less than
its frontier allows, or nothing (`{ok, no_change}`). The retired-origin
exemption matters: the applier drops retired origins, so without it the cap
would hold forever.

Counter: `bondy_oplog_compaction_holds_total`. Sustained growth means the
applier's replay is not keeping up with delivery for that instance. Convergence
is protected; disk is not — check `bondy_oplog_wal_consumer_lag_bytes`
alongside it.

## Detecting a replica that is genuinely behind

With those closed, a complete round that leaves the peer's frontier strictly
ahead of the local one after settle is evidence rather than noise. That is a
**frontier gap verdict** (`bondy_oplog_frontier_gap_verdicts_total`, by
instance and peer). Settle means the instance's `await_apply` *and*
`bondy_oplog_applier:barrier/1`; the instance barrier alone drains only the
overlay, not the applier, and without the applier barrier replay lag
false-flags essentially every first sync.

A single verdict is still not actionable. When a peer door-*folds* an in-flight
operation, its applied VV advances past what its truncated MST can serve, and a
third replica whose complete round lands in that window records a deficit that
only the origin can cover, one round later. The origin cannot have compacted it
away — the peer-confirmed frontier needs the lagging replica's roots to contain
it — so the transient heals by itself.

`bondy_oplog_sync_scheduler` therefore debounces the verdict: a gap must strike
twice for the same `(instance, peer)` inside its gap-strike window (120s) before
the remedy fires, and a successful round clears the count. A
standing gap cannot heal by syncing and strikes again on the very next round, so
detection is delayed by one round, never lost.

The remedy is a catalogue re-bootstrap: the peer streams its whole projection
and the local one is re-derived. Correct for the case that matters — history
compacted past this replica is gone and no amount of syncing recovers it — and
expensive, which is why a transient must never trigger it. Counter:
`bondy_oplog_rebootstraps_scheduled_total`.

Frontier **adoption** is separate and stricter: only at bootstrap finalize, or on
a deficit-free complete round. Adopting a peer's frontier on a live round was
itself a silent-loss mechanism and no longer happens.

### Unservable own root

A replica whose own tree has lost pages can neither serve its root nor repair by
pulling. It drops the tree and resumes anti-entropy on a fresh one, but only
after a domination gate proves no peer is stranded on the tree being discarded.
Counter: `bondy_oplog_mst_rebuilt_total`. It should be zero; any occurrence
means pages went missing and that is the question to chase, not the heal.

## Recovery timing

Three stages, each costing more than the last:

| Situation | What must happen | Bounded by |
|---|---|---|
| Ordinary lag | One sync round for that instance | `db.aae.interval`, times the ticks the instance waits for a slot under `aae_max_concurrency`, + transfer |
| Standing gap | Two complete rounds to strike twice, then the remedy | Two rounds + settle |
| Re-bootstrap | Full projection transfer for the instance | Instance size |

A replica that has just returned from a fault and is still missing operations is
normally inside the detection window rather than faulty. The signal worth
alerting on is the *persistence* of disagreement — a verdict rate that stays
non-zero for one `(instance, peer)`, or a re-bootstrap count that keeps climbing
for the same pair — not its presence.

## See also

- `doc/guides/database/prefix_closure.md` — the ordering property the fold
  enforces, and the `bondy_oplog_events_held_total` /
  `bondy_oplog_prefix_holes_total` signals.
- `doc/guides/database/deletion_and_reclamation.md` — the other decision causal
  stability licenses, and why it stays root-only.
- `doc/guides/configuration/reclamation_options.md` — retirement and reclamation
  tunables.
