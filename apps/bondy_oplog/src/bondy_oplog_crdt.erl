%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Behaviour for consumer-defined CRDTs.

A *CRDT module* binds an oplog instance to a domain semantics. The
library is otherwise agnostic to event payload meaning; it is the
CRDT module — through its `interpret_cog/2` callback — that decides
what an event "means" and how concurrent operations are resolved.

The Concurrent Operation Group (COG) abstraction and the
`interpret_cog` interface come from Preston McCrary's *Canteen*
(UC Berkeley, 2022 — EECS-2022-160). The library carries the COG
machinery; the consumer supplies the interpretation function.

## Required callbacks

- `causal_tier/0` declares which Tier of causal metadata this CRDT's
  cells carry, and selects the substrate clock provisioned for the
  table:
  - `tier_0` = none — scalar HLC only. Correct for commutative types
    (registers, counters, sets): HLC-monotonic delivery is a causal
    linearization and order cannot change the result.
  - `tier_1` = dot sets — per-operation observed dots (e.g. the legacy
    observed-remove map).
  - `tier_2` = version vectors — a per-cell causal context (a Dotted
    Version Vector, `bondy_dvvset`) carried in the event `meta`, so
    `interpret_cog/2` can compute true *happens-before* and resolve
    concurrency-detecting types (multi-value register, add-wins map)
    that scalar HLC cannot express. The substrate stamps the context
    generically at the origin (it already mints the HLC dot); the CRDT
    only consumes it.

- `init/0` returns the bottom state — what the CRDT looks like when
  no events have ever been applied. Pure; called at first compaction
  on a fresh instance.

- `interpret_cog(Events, State) -> NewState` is the *workhorse*. It
  receives a batch of events (a Concurrent Operation Group) in key
  order and returns the updated state. It MUST be deterministic: same
  inputs ⇒ same output, on every replica. The library calls this on
  compaction (folding stable prefixes into snapshots) and on hot
  queries (folding live events on top of the latest snapshot).

- `query(Query, State) -> Result` projects the CRDT state for a
  client query. Pure.

## Projection-seam callbacks

These let the applier keep a materialised projection value current on
write (the eager-materialised projection path), with `interpret_cog/2`
as the sole convergence kernel.

- `to_value(State) -> Value` projects a CRDT state to the user-facing
  value stored in the projection / served on reads. Pure.

- `hlc(State) -> hlc()` the state's logical timestamp — non-decreasing
  as operations are interpreted. Drives the projection's per-cell HEAD
  HLC.

- `encode_state(State) -> binary()` / `decode_state(binary()) -> State`
  serialise the state for the compaction checkpoint and the projection
  HEAD column. There is deliberately **no** `encode_event/decode_event`:
  operations travel as opaque terms in the WAL/MST — the substrate never
  asks the CRDT to (de)serialise an op.

## Optional callbacks

- `removal_op() -> Op | undefined` the operation that removes the WHOLE
  cell, for `bondy_db:delete/3` — `clear` for register-like types (a flag
  would declare `disable`; none does yet, so `delete/3` on a flag table
  returns `{error, {no_removal_op, _}}`). Collection types return
  `undefined`: a set or map has no whole-cell removal, its entries are
  removed individually.

- `stabilize(StableHlc, State) -> keep | {keep, State} | discard` — what
  remains of `State` once `StableHlc` is causally stable, i.e. once no
  operation older than it can ever be delivered again.

  `discard` means the cell carries no remaining semantic content and may
  be physically removed from the projection. A tombstone is the case that
  matters: it exists only to reject a concurrent write with a lower HLC,
  so once that is impossible it is pure overhead.

  `{keep, State'}` is the weaker form — retain the cell but drop metadata
  that only served to order it against operations that can no longer
  arrive.

  This is causal *stabilization* in the sense of Baquero, Almeida and
  Shoker (arXiv:1710.04469 §7.2): a data-type-specific reduction licensed
  by stability, distinct from the redundancy applied on delivery. It MUST
  NOT be called with an `StableHlc` derived from anything weaker than a
  confirmed all-peer frontier — see
  `bondy_oplog_peer_state:confirmed_peer_states/2`.

- `value_equals_state() -> boolean()` declares that `to_value/1` is the
  identity (the projection value *is* the state) — a storage optimisation
  for value-carrying CRDTs (e.g. g-sets). Default `false`.

- `order_independent() -> boolean()` the **commutativity marker** the
  applier uses to pick the projection-maintenance path: `true` selects
  the O(1) incremental step (apply one op onto the materialised state,
  safe because order cannot change the result); `false` selects
  re-interpretation of the cell's live group via `interpret_cog/2`
  (the only correct path for non-commutative CRDTs, e.g. an observed-remove
  map or a bounded counter). It is a property of the CRDT *module*,
  validated by test — never an arrival-order heuristic. Default `false`.

- `context_of(State) -> term()` — **tier_2 only.** Returns the cell's
  current causal context (a version vector, e.g. `bondy_dvvset:join/1`).
  The substrate reads this at the origin to stamp a new write's observed
  context into the event `meta`, so `interpret_cog/2` can later resolve
  concurrency. tier_0 CRDTs do not export it.

- `reap_origins(State, RetiredOrigins) -> {NewState, Reaped}` — **tier_2
  only.** Garbage-collect the per-cell causal context entries of
  permanently-retired origins. A tier_2 CRDT carries one version-vector
  entry per origin that ever wrote the cell; an origin whose node is
  decommissioned leaves that entry behind forever (the one cost that grows
  with cluster *churn* rather than op count). Given a set of retired
  origins, this drops only the entries that carry **no live value** —
  pure causal bookkeeping whose every value has already been dominated —
  so the projection's value (`to_value/1`) is unchanged. An origin still
  holding a surviving sibling is *retained* (its value is real data) and
  excluded from `Reaped`, which lists exactly the origins actually
  dropped. The substrate cannot know which origins are retired (membership
  is delegated to the consumer); the *operator* supplies `RetiredOrigins`
  and the obligation that they are permanently gone and causally stable
  cluster-wide, exactly as it owns origin-uniqueness. This callback only
  enforces the local value-preserving gate. tier_0 CRDTs (whose per-origin
  entries are value, not bookkeeping) do not export it.

## Determinism invariant

`interpret_cog/2`'s determinism is the foundation of the system's
*Strong Eventual Consistency* guarantee. A non-deterministic
implementation will break convergence: replicas that received the
same events will produce different snapshots and the system will
silently diverge.
""").

-type tier() :: tier_0 | tier_1 | tier_2.

-export_type([tier/0]).

-callback causal_tier() -> tier().

-callback init() -> State :: term().

-callback interpret_cog(
    Events :: [bondy_oplog_event:t()],
    State :: term()
) -> NewState :: term().

-callback query(Query :: term(), State :: term()) -> Result :: term().

%% Projection-seam callbacks (operation-based projection, Option B).

-callback to_value(State :: term()) -> Value :: term().

-callback hlc(State :: term()) -> bondy_oplog_hlc:hlc().

-callback encode_state(State :: term()) -> binary().

-callback decode_state(binary()) -> State :: term().

%% Optional callbacks.

-callback removal_op() -> Op :: term() | undefined.

-callback stabilize(
    StableHlc :: bondy_oplog_hlc:hlc(),
    State :: term()
) -> keep | {keep, State :: term()} | discard.

-callback value_equals_state() -> boolean().

-callback order_independent() -> boolean().

-callback context_of(State :: term()) -> Context :: term().

-callback reap_origins(
    State :: term(),
    RetiredOrigins :: [term()]
) -> {NewState :: term(), Reaped :: [term()]}.

-optional_callbacks([
    removal_op/0,
    stabilize/2,
    value_equals_state/0,
    order_independent/0,
    context_of/1,
    reap_origins/2
]).
