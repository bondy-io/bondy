# Why bondy_db is operation-based: the Canteen × MST grounding

This is the design rationale behind
[the CRDT model](../doc_extras/architecture/05_crdt_model.md): why `bondy_db` materialises
application state by *interpreting a log of operations* rather than by *merging
states*, and why that distinction is load-bearing. It draws on two ideas — the
**Merkle Search Tree** (Auvolat & Taïani) and the **Canteen** operation-based
CRDT model (the `interpret_cog` COG-interpreter). The companion
[`architecture_regrounding.html`](architecture_regrounding.html) carries the SVG
diagrams.

## Two layers, two senses of "state-based"

The substrate is two layers, and the word "state-based" is correct for exactly
one of them.

**Layer 1 — op-set reconciliation (legitimately state-based).** The MST is a
grow-only *set of operations*, each keyed by its dot `{HLC, Origin, Seq}`,
reconciled by set-union anti-entropy. Two peers compare roots and exchange only
the pages they differ on. This is the one place state-based reconciliation
belongs: it reconciles the *op-set*, not the application's meaning of those ops
([chapters 01](../doc_extras/architecture/01_bondy_oplog.md) and 02).

**Layer 2 — application semantics (operation-based).** A table's value for a
cell is produced by replaying the converged op-set through a COG-interpreter,
`interpret_cog(Events, State)`. The result is a pure function of the *set* of
operations, read in canonical dot order — not of the order in which they
happened to arrive.

Collapsing Layer 2 into a *second* state-based layer — folding each event into a
single merged cell state with a `merge_states` join — is the design this
re-grounding corrected. That fold foreclosed the whole class of
non-commutative CRDTs: once a cell is collapsed to one merged state, the
order-sensitive structure a correct merge needs is gone.

## Causal delivery without a hold-back buffer

The classic operation-based CRDT requires *causal delivery*, usually via a
version-vector hold-back buffer that withholds an operation until its
predecessors arrive. `bondy_db` needs none, and the reason is structural:

1. **The MST is the buffer.** Anti-entropy reconciles the op-*set*, not a
   stream. Interpretation reads the converged set, so "arrived before its
   predecessor" is a non-event at the interpretation layer.
2. **`interpret_cog` consumes the set in canonical dot order**, and the HLC
   respects happens-before, so the dot order is a causal linearization of the
   set. Same set ⇒ same order ⇒ same state on every replica.
3. Convergence therefore rests on a single property — set-convergence (the MST)
   plus deterministic key-ordered interpretation — which is exactly what lets
   non-commutative CRDTs converge with no buffer at all.

The only real ordering obligation that remains — never truncate a stable event
before it has been interpreted into the projection — is enforced by the
replay-before-truncate guard in compaction
([chapter 06](../doc_extras/architecture/06_compaction_and_bootstrap.md)).

## The one performance-driven choice: eager materialisation

A faithful, lazy reading of Canteen keeps only *stable* snapshots in the store
and folds a cell's live events through `interpret_cog` on every unstable read.
`bondy_db`'s hot path is the WAMP registry — read-your-writes, reads far
outnumbering writes — so it cannot pay an interpretation per read. Instead it
keeps each cell's materialised value current *on write*, with `interpret_cog`
as the sole kernel:

- For a **commutative** CRDT, folding the new operation onto the current state
  *is* `interpret_cog` — order cannot change the result — so the write stays
  O(1) with no per-cell live log.
- For a **non-commutative** CRDT (the add-wins map), the applier re-interprets
  the cell's *bounded* live group on write. These cells need the group anyway;
  there is no correct O(1) path, so the live log is kept only for them.

A CRDT module declares which it is (`order_independent/0`), and that marker —
validated by test — selects the path. The result keeps reads O(1) while keeping
`interpret_cog` the one authoritative semantics
([chapter 05](../doc_extras/architecture/05_crdt_model.md)).

## What the grounding buys

- **Non-commutative CRDTs become possible** — the add-wins map and bounded
  counters that a collapsing fold cannot express.
- **Convergence rests on one property**, set-convergence plus deterministic
  interpretation, rather than on a fragile per-cell merge whose correctness has
  to be re-argued for every CRDT.
- **The performance infrastructure is independent of the CRDT layer.** WAL
  group-commit, pack-store sealing, applier batching and frame caching,
  head-only projections, and sharding all sit below the kernel and were
  preserved wholesale through the re-grounding.

## See also

- [The CRDT model](../doc_extras/architecture/05_crdt_model.md) — the as-built behaviour
  contract and the native catalogue.
- [bondy_oplog: the write side](../doc_extras/architecture/01_bondy_oplog.md) — the MST op-set
  layer and leaderless replication.
- [Compaction & bootstrap](../doc_extras/architecture/06_compaction_and_bootstrap.md) — how
  the bounded op-set and the replay-before-truncate guard work.
