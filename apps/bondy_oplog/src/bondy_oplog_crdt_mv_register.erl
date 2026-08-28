%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_mv_register).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Multi-value register (MVRegister) — the first **tier_2** native CRDT.

A multi-value register holds the set of values written *concurrently*:
a write that observed (causally follows) an earlier write replaces it; two
writes that did not observe each other both survive as **siblings**, and a
read returns the whole sibling set for the application to reconcile. This
is the canonical concurrency-detecting register — and the one a scalar HLC
*cannot* express, because `HLC(A) < HLC(B)` does not imply `A → B`.
It therefore needs a true causal context: a per-cell **Dotted Version
Vector** (`bondy_dvvset`).

## Why tier_2 (and why it is still commutative)

`causal_tier() -> tier_2`: each write carries, in the event `meta`, the
causal context (a version vector) the origin observed — the substrate
stamps it generically at the origin (`bondy_db:apply_with_context/4`),
exactly as it already mints the HLC dot; this module only *consumes* it.

`order_independent() -> true`: a write's effect is reconstructed as one
DVV contribution and merged with `bondy_dvvset:sync/1`, which is a lattice
join (commutative, associative, idempotent). So the eager O(1) step
(`apply_op/4`) and the sorted-group fold (`interpret_cog/2`) are both
`sync`-folds and yield the same state regardless of arrival order or
duplication. It therefore rides the existing eager kernel; no live-log
is needed.

## State

```
{bondy_dvvset:clock(), hlc()}
```

The `clock()` is the cell's DVVSet: its causal history is the union of
every observed dot, and its values are the live siblings, each dotted
under the `{Origin, Counter}` of the write that produced it. The `hlc()`
is the max HLC absorbed — the projection's per-cell HEAD HLC and the
GC threshold.

## Operation

```
{set, register_value()}
```

`register_value()` is any term supplied by the application.

## Reconstructing a write's DVV contribution

For an event with dot `Key = {HLC, Origin, Seq}`, observed context
`Context` (the stamped version vector in `meta`) and op `{set, V}`:

```
Contribution = bondy_dvvset:update(bondy_dvvset:new(Context, [V]), Origin)
NewClock     = bondy_dvvset:sync([Clock, Contribution])
```

`new(Context, [V])` seeds the contribution with the observed causal
history and the value in the anonymous slot; `update(_, Origin)` advances
`Origin` by one and dots `V` under it (counter = `Context[Origin] + 1`,
the same dot the origin minted locally). Because each event carries its
*own* observed context, `sync` drops a value only when another write's
context dominates its dot — i.e. add-/multi-value-wins semantics fall out
of the join.

## Encoding & determinism

`encode_state/1` is a version byte followed by `term_to_binary({Clock,
Hlc})`. This is byte-canonical across replicas: `sync` keeps `entries`
sorted by id; an origin is single-applier per cell, so each origin holds
at most one live (non-dominated) value, so per-id value lists are length
≤ 1 and the anonymous slot is always empty. Equal logical state ⇒ equal
bytes ⇒ equal MST page hash ⇒ convergent `root_hash`.

## Convergence preconditions (substrate-provided, NOT enforced here)

The lattice algebra above is correct only while two substrate invariants
hold. They are the same invariants every dot-based type on this system
relies on; this type has no internal tolerance for their violation (a
reused `{Origin, Counter}` carrying two distinct values forks the lattice
silently), so they are called out explicitly:

1. **Origin uniqueness.** No two replicas ever mint events under the same
   `Origin`. The substrate guarantees this (a deterministic per-node
   origin — see the auto-memory record `project_prj4_landed_2026_05_25`,
   which hardened exactly this after an origin-reuse-after-restart Jepsen
   bug).

2. **Per-cell context monotonicity at the origin.** An origin's observed
   context for *itself* (`context_of(cell)[Origin]`) never regresses
   between its successive writes to a cell. This follows from
   read-your-writes (the stamp reads the committed projection,
   `bondy_db:apply_with_context/4`) **provided recovery is complete before
   a new write is accepted** — i.e. on restart the cell DVV is fully
   re-derived from durable state (the compaction checkpoint's
   `StateBytes`, or WAL/MST replay through `interpret_cog/2`) before the
   origin stamps another write. Both recovery paths reconstruct the exact
   DVV (pinned by the encode round-trip and replay-equals-eager tests), so
   the reconstructed context equals the original and the next write
   dominates rather than re-minting a used dot.

The stamp site enforces invariant 2 in-process: `bondy_oplog_applier`'s
tier_2 context-regression guard remembers the highest context it stamped
per cell and refuses (with a `[bondy_oplog, applier, context_regression]`
telemetry event) any write whose freshly read context regressed below it
— turning a silent fork into a loud, recoverable error. It lives at the
origin stamp, not in `apply_op/4` (which cannot tell a local mint from a
remote replay). The guard resets on restart by design; the cross-restart
case is covered instead by durable recovery rebuilding the exact context
before the next write (pinned by `bondy_db_tier2_durability_test`).
""").

%% bondy_oplog_crdt
-export([causal_tier/0]).
-export([init/0]).
-export([interpret_cog/2]).
-export([query/2]).
%% projection seam
-export([to_value/1]).
-export([hlc/1]).
-export([value_equals_state/0]).
-export([order_independent/0]).
-export([context_of/1]).
-export([reap_origins/2]).
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative (tier_2 step)
-export([apply_op/4]).

-type register_value() :: term().
-type clock() :: bondy_dvvset:clock().
-type state() :: {clock(), bondy_oplog_hlc:hlc()}.
-type op() :: {set, register_value()}.

-export_type([state/0, op/0, register_value/0]).

%% The state encoding format version (leading byte of `encode_state/1`).
-define(ENC_V1, 1).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

-spec causal_tier() -> tier_2.

causal_tier() ->
    tier_2.

-spec init() -> state().

init() ->
    {bondy_dvvset:new([]), 0}.

-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

-spec query(value, state()) -> [register_value()].

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative (tier_2 step)
%% =============================================================================

-doc """
Apply one `{set, V}` operation with its observed causal `Context` (the
stamped version vector in the event `meta`). Reconstructs the write's DVV
contribution — `V` dotted under the event's `Origin`, advancing `Context`
— and joins it into the cell clock with `bondy_dvvset:sync/1`. The join is
commutative/idempotent, so this eager step equals the sorted-group
`interpret_cog/2` fold.
""".
-spec apply_op(
    state(),
    op(),
    bondy_oplog_event:event_key(),
    Context :: bondy_dvvset:vector() | undefined
) -> state().

apply_op({Clock, Hlc}, {set, V}, Key, Context) ->
    Origin = bondy_oplog_event:key_origin(Key),
    EventHlc = bondy_oplog_event:key_hlc(Key),
    Ctx = normalise_context(Context),
    %% `update/2` moves `V` from the anonymous slot to `Origin`'s dot, so
    %% the contribution always has an EMPTY anonymous slot. The cell clock
    %% likewise never holds anonymous values. This matters for canonical
    %% encoding: `bondy_dvvset:sync/2`'s anonymous-value union is
    %% `sets:to_list(sets:from_list(...))` (order-nondeterministic), and it
    %% is reached only when BOTH operands carry a non-empty anonymous slot
    %% — which never happens here. Keep it that way: every path into the
    %% clock must go through `update/2` (an id-dotted value), never
    %% `new/1,2` left un-`update`d.
    Contribution = bondy_dvvset:update(bondy_dvvset:new(Ctx, [V]), Origin),
    NewClock = bondy_dvvset:sync([Clock, Contribution]),
    {NewClock, erlang:max(Hlc, EventHlc)}.

%% =============================================================================
%% projection seam
%% =============================================================================

-doc """
The register's value: the sorted set of live concurrent siblings (empty
before any write). Sorting makes the user-facing value canonical and
order-insensitive — a replica-independent multiset of concurrent values.
""".
-spec to_value(state()) -> [register_value()].

to_value({Clock, _Hlc}) ->
    lists:sort(bondy_dvvset:values(Clock)).

-doc """
The cell's current causal context — the version vector the substrate
stamps into the next write's `meta`. `bondy_dvvset:join/1` of the clock.
""".
-spec context_of(state()) -> bondy_dvvset:vector().

context_of({Clock, _Hlc}) ->
    bondy_dvvset:join(Clock).

-doc """
Reap the DVVSet entries of permanently-retired origins (the membership-
driven GC). The clock holds one `{Origin, Counter, Values}` entry per
origin that ever wrote the cell.
For a retired origin we drop its entry **only when `Values` is empty** —
i.e. every value that origin wrote has already been dominated by a later
write, so the entry is pure causal history. Dropping it does not change
`bondy_dvvset:values/1`, hence `to_value/1` is unchanged (value-
preserving). A retired origin that still holds a live sibling is retained
(that value is real register state and survives until a newer write
dominates it) and is excluded from `Reaped`.

This addresses the one cost that grows with cluster *churn* rather than
op count. It is safe to drop a causal-history-only entry only once the
origin is permanently gone *and* causally stable cluster-wide (no replica
can re-deliver an `{Origin, _}`-dotted event the reaped context would have
dominated) — the operator's obligation, the same class as origin
uniqueness. The pass is idempotent: re-reaping a clock with no matching
entry returns it unchanged with `Reaped = []`.
""".
-spec reap_origins(state(), [bondy_dvvset:id()]) ->
    {state(), Reaped :: [bondy_dvvset:id()]}.

reap_origins({{Entries, Anon}, Hlc}, Retired) when is_list(Entries) ->
    {Kept, Reaped} = lists:foldr(
        fun
            ({Id, _N, []} = E, {KAcc, RAcc}) ->
                case lists:member(Id, Retired) of
                    true -> {KAcc, [Id | RAcc]};
                    false -> {[E | KAcc], RAcc}
                end;
            (E, {KAcc, RAcc}) ->
                %% Non-empty Values ⇒ a live sibling ⇒ retain (real data).
                {[E | KAcc], RAcc}
        end,
        {[], []},
        Entries
    ),
    {{{Kept, Anon}, Hlc}, Reaped};
reap_origins({{}, _Hlc} = State, _Retired) ->
    %% The bare empty clock `{}` (no entries) — nothing to reap.
    {State, []}.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_Clock, Hlc}) ->
    Hlc.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    false.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-spec encode_state(state()) -> binary().

encode_state({_Clock, _Hlc} = State) ->
    <<?ENC_V1, (term_to_binary(State))/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<?ENC_V1, Bin/binary>>) ->
    %% Own-persisted projection bytes — plain decode per the C-2
    %% own-bytes rule (rationale:
    %% `bondy_oplog_cell_kernel:decode_value_bytes/2`).
    binary_to_term(Bin).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
%% A tier_2 write always carries a stamped context (a version vector). A
%% missing context is treated as the empty causal history — the same as a
%% first write to a fresh cell.
normalise_context(undefined) -> [];
normalise_context(VV) when is_list(VV) -> VV.
