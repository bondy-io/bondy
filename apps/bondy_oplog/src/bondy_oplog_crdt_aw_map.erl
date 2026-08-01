%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_aw_map).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Add-wins observed-remove map (AWORMap) — a **tier_2** native CRDT.

A dynamic-key map whose presence semantics are add-wins: a key written
concurrently with a remove that did **not** observe that write survives
(the add wins). Each key resolves to the set of values written to it
*concurrently* (siblings), exactly like the multi-value register
(`bondy_oplog_crdt_mv_register`) — a sequential overwrite dominates, two
concurrent writes both survive. It is the multi-key generalization of the
mv-register with an observed-remove on the keys themselves, and like the
mv-register it cannot be expressed with a scalar HLC: it needs a true
causal context (a per-cell version vector / Dotted Version Vector,
`bondy_dvvset`).

## Why tier_2, and why a *pure* remove

`causal_tier() -> tier_2`: every write carries, in the event `meta`, the
causal context (a version vector) the origin observed — the substrate
stamps it generically at the origin (`bondy_db:apply_with_context/4`),
exactly as it mints the HLC dot; this module only *consumes* it.

That stamped context is what makes the remove **pure**. The former
state-based aw_map fold (removed in this rollout) resolved a logical
`{remove_aw_key, K}` into a physical `{remove, K, ObservedDots}` by a
server-side round-trip that read the cell state before WAL append.
Here a `{rmv, K}` carries
the observed context in `meta`; `apply_op/4` removes exactly the dots of
`K` that the writer observed (`OldState[K]` filtered by the stamped
context), with **no round-trip and no `ObservedDots` argument**. A remote
remove replays its own immutable observed context verbatim, so a local
concurrent add it never saw is preserved — add-wins falls out.

`order_independent() -> true`: see *Convergence* below — it rides the
existing eager kernel; no live-log is needed.

## State

```
{entries(), bondy_dvvset:vector(), hlc()}

entries() :: #{key() => dot_store()}
dot_store() :: #{dot() => value()}      %% non-empty for a live key
dot() :: {origin(), counter()}          %% counter = the substrate Seq
```

- `entries()` is the ORSet dot-store: a key is **present** iff its
  dot-store is non-empty; the key's value is the set of values carried by
  its surviving dots.
- the `bondy_dvvset:vector()` is the cell-wide **causal context** — the
  version vector of every dot the cell has ever observed (live *or*
  already removed), `[{Origin, MaxSeq}]` sorted by origin. It is what
  `context_of/1` hands the substrate to stamp the next write. A single
  per-cell context (not a DVVSet per key) keeps it `O(replicas)` and
  avoids per-key sibling explosion.
- the `hlc()` is the max HLC absorbed — the projection's per-cell HEAD
  HLC and the GC threshold.

## Operations

```
{put, key(), value()}              %% assign value to key (mv on concurrent puts)
{apply, key(), module(), term()}   %% apply a sub-op to a nested tier_0 sub-CRDT
{rmv, key()}                       %% observed-remove the key
```

`value()` is any term supplied by the application. `{apply, K, SubMod,
SubOp}` lets `K`'s value be another CRDT's converged state instead of
an opaque term — see *Nested sub-CRDTs*.

## Semantics — `apply_op/4` reads `OldState[K]`

For an event with dot `Dot = {Origin, Seq}` and stamped observed context
`Ctx` (a version vector):

- `{put, K, V}`: drop from `K`'s dot-store every dot the writer observed
  (`Dot' <= Ctx`), then add `{Dot => V}`. Observed dots are the writer's
  own prior versions, so a sequential write dominates; a concurrent
  write's dot is not in `Ctx`, so it survives as a sibling.
- `{apply, K, SubMod, SubOp}`: same drop-then-add as `{put, K, V}}`, but
  the added dot carries a tagged sub-operation instead of a flat value
  — see *Nested sub-CRDTs*.
- `{rmv, K}`: drop from `K`'s dot-store every dot the writer observed; add
  nothing. If the dot-store empties, the key is removed. A concurrent add
  the remover never observed survives — add-wins.

All three route through `bondy_oplog_crdt_nested_core`, which owns the
drop-then-add/drop-then-maybe-remove bookkeeping generically (shared
with `bondy_oplog_crdt_aw_set`); this module supplies only the dot/
context derivation and the projection.

## Nested sub-CRDTs

A key's value can be another CRDT's converged state instead of an
opaque term: `{apply, K, SubMod, SubOp}` accumulates `{sub, SubMod,
Hlc, SubOp}` at the operation's dot exactly as `{put, K, V}}` accumulates
`V` — same add-wins/observed-remove treatment, since
`bondy_oplog_crdt_aw_core:drop_observed/2` only ever inspects the dot,
never the value. `to_value/1` detects a nested key
(`bondy_oplog_crdt_nested_core:sub_mod/1`) and, instead of returning the
raw sibling set, replays the surviving sub-ops through `SubMod`'s own
`interpret_cog/2` (`bondy_oplog_crdt_nested_core:nested_value/2`) — no
callback beyond what every `bondy_oplog_crdt` module already exports.

`SubMod` MUST be `causal_tier() =:= tier_0` (`pn_counter`,
`lww_register`, `max_register`, `min_register`, ...): a tier_0 sub-op
only needs its own HLC to linearize, which the parent's dot/event key
already carries — no nested causal-context threading. A key's `SubMod`
is fixed by its first `{apply, ...}` write; mixing `put`/`rmv` and
`apply` on the same live key, or changing `SubMod` on a live key, raises
`{badarg, _}` (`bondy_oplog_crdt_nested_core:put/5`,`:put_nested/7`).

A dot `{O, S}` is *observed* by a context `Ctx` iff `Ctx[O] >= S`. Under
causal (per-origin FIFO) delivery this compact test is exact: observing
`{O, Ctx[O]}` implies having observed every `{O, <= Ctx[O]}` (you cannot
skip), so `Ctx[O] >= S` iff the writer saw the specific dot `{O, S}`. See
*Convergence preconditions*.

## Convergence

The surviving dot-set is a **pure function of the event set**:

```
Dot d ∈ final(K)  ⟺  some {put, K, _} minted d
                     ∧  no operation on K observed d (d ∉ any op's Ctx)
```

because every operation that supersedes `d` (a later put, or a remove)
removes `d` exactly when its context observed `d`, and the minting put
adds `d` exactly once. Neither clause depends on arrival order, so the
eager arrival-order fold (`apply_op/4`) and the canonical key-sorted group
fold (`interpret_cog/2`) compute the same state — provided both are
**causal linearizations** of the event set (an op that observed `d` is
applied after `d`'s put). Causal delivery makes the eager arrival order
causal; HLC-monotonicity makes the key-sorted order causal (an op that
observed `d` has a strictly higher HLC). `interpret_cog/2` additionally
sorts internally, so it is invariant under any input permutation.

This is **op-based** convergence: replicas converge by interpreting the
same event set, not by a state join. There is deliberately **no**
`merge_states/2`.

## Value projection

`to_value/1` returns `#{Key => [value()]}` over **live** keys only, each
value list the sorted set (`lists:usort`) of the key's concurrent
siblings. Removed keys are absent.

## Encoding & determinism

`encode_state/1` is a version byte followed by `term_to_binary/1` of a
**canonical** form: entries as a key-sorted list of `{Key, dot-sorted
list of {Dot, Value}}`, the context sorted by origin, then the HLC. The
canonical form is a list/tuple/binary/integer structure (no maps), so it
is a deterministic function of the logical state — equal state ⇒ equal
bytes ⇒ equal MST page hash ⇒ convergent `root_hash`.

## Deviations

1. **`value()` per dot, multi-value leaf, for flat values** (not a
   per-key sub-CRDT resolved via a state-based `merge_states/2`, as the
   deprecated fold did by attaching a sub-fold — `lww_register`,
   `pn_counter`, ... — to each key). This native map stores an opaque
   value per dot and resolves a *flat* key to the set of concurrent
   siblings — the honest tier_2, concurrency-detecting projection (the
   same shape as `mv_register`). Nested keys (`{apply, K, SubMod,
   SubOp}`) are the op-based analogue of the deprecated fold's per-key
   sub-CRDT — see *Nested sub-CRDTs* — restricted to tier_0 `SubMod`s
   (no recursive tier_2-in-tier_2 nesting).
2. **One per-cell context VV**, not a DVVSet per key — the per-key
   dot-store carries presence; the shared context carries causality.
   `bondy_dvvset` is the conceptual basis, but its API operates on
   `clock()`, not the bare `vector()` this map needs, so the trivial
   VV arithmetic (`vv_merge`, `dot_observed`) is inlined and
   property-pinned rather than routed through `bondy_dvvset`.
3. **`term_to_binary/1` of a canonical form** for `encode_state/1`, not a
   hand-rolled dot framing like the deprecated fold — simpler, and
   canonical by construction (no maps in the encoded term).

## Convergence preconditions (substrate-provided, NOT enforced here)

The same two invariants `bondy_oplog_crdt_mv_register` relies on, for the
same reasons — see its moduledoc and the auto-memory record
`project_prj4_landed_2026_05_25`:

1. **Origin uniqueness.** No two replicas ever mint dots under the same
   `Origin`.
2. **Causal (per-origin FIFO) delivery** of operations to the applier,
   and **per-cell context monotonicity at the origin** (the stamp reads
   the committed projection, and recovery is complete before a new write
   is accepted). Causal delivery is what makes the compact version-vector
   `dot_observed/2` test exact and the surviving dot-set order-independent.
   Invariant 2's in-process half is enforced at the stamp site by
   `bondy_oplog_applier`'s context-regression guard (refuse + telemeter on
   a regressed context); its cross-restart half is covered by durable
   recovery rebuilding the exact context — both pinned by
   `bondy_db_tier2_durability_test` and `bondy_db_tier2_stamp_guard_test`.

Note on the counter: the substrate `Seq` is a *per-origin global*
sequence, so an origin's dots on any one cell are **sparse** (it writes
other cells in between). The context counter `Ctx[O]` is therefore the
max Seq of `O`'s ops *on this cell*, `<=` `O`'s global Seq. The compact
test `Ctx[O] >= S` can be numerically true for an `{O, S}` that never
touched this cell — but that is harmless: it is only ever evaluated
against dots actually in the cell's dot-store, and for those, FIFO makes
it exact (a superseding `{O, S'}` with `S' >= S` means `O` observed
`{O, S}`). A peer's dots live on a disjoint `{Origin, _}` axis and are
never subsumed by `O`'s counter — which is precisely why a concurrent
peer add survives a remove (add-wins).
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
-export([batchable/0]).
-export([context_of/1]).
-export([reap_origins/2]).
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative (tier_2 step)
-export([apply_op/4]).

-type map_key() :: binary().
-type map_value() :: term().
-type origin() :: binary().
-type counter() :: non_neg_integer().
-type dot() :: {origin(), counter()}.
-type dot_store() :: #{dot() => map_value()}.
-type entries() :: #{map_key() => dot_store()}.
-type context() :: bondy_dvvset:vector().
-type state() :: {entries(), context(), bondy_oplog_hlc:hlc()}.
-type op() ::
    {put, map_key(), map_value()}
    | {apply, map_key(), module(), term()}
    | {rmv, map_key()}.

-export_type([state/0, op/0, map_key/0, map_value/0]).

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
    {#{}, [], 0}.

-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

-spec query(value, state()) -> #{map_key() => [map_value()] | term()}.

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative (tier_2 step)
%% =============================================================================

-doc """
Apply one `{put, K, V}`, `{apply, K, SubMod, SubOp}`, or `{rmv, K}` with
its observed causal `Context` (the stamped version vector in the event
`meta`). Dispatches to `bondy_oplog_crdt_nested_core`, which owns the
drop-then-add/drop-then-maybe-remove dot-store bookkeeping generically
(shared with `bondy_oplog_crdt_aw_set`); this clause set only derives
the dot/context and folds the cell-wide context and HLC. The surviving
dot-set is a pure function of the event set, so this eager step equals
the key-sorted `interpret_cog/2` fold.
""".
-spec apply_op(
    state(),
    op(),
    bondy_oplog_event:event_key(),
    Context :: context() | undefined
) -> state().

apply_op({Entries, CC, Hlc}, {put, K, V}, Key, Context0) when is_binary(K) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Entries1 = bondy_oplog_crdt_nested_core:put(Entries, K, Dot, Ctx, V),
    {Entries1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))};
apply_op({Entries, CC, Hlc}, {apply, K, SubMod, SubOp}, Key, Context0)
        when is_binary(K) andalso is_atom(SubMod) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Entries1 = bondy_oplog_crdt_nested_core:put_nested(
        Entries, K, Dot, Ctx, SubMod, key_hlc(Key), SubOp
    ),
    {Entries1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))};
apply_op({Entries, CC, Hlc}, {rmv, K}, Key, Context0) when is_binary(K) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Entries1 = bondy_oplog_crdt_nested_core:rmv(Entries, K, Ctx),
    {Entries1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))}.

%% =============================================================================
%% projection seam
%% =============================================================================

-doc """
The map's value: live keys, each mapped to the sorted set of its
concurrent sibling values, or — for a nested key
(`bondy_oplog_crdt_nested_core:sub_mod/1`) — the sub-CRDT's own
converged value (`bondy_oplog_crdt_nested_core:nested_value/2`). Removed
keys are absent.
""".
-spec to_value(state()) -> #{map_key() => [map_value()] | term()}.

to_value({Entries, _CC, _Hlc}) ->
    maps:fold(
        fun(K, DS, Acc) ->
            case map_size(DS) of
                0 ->
                    Acc;
                _ ->
                    case bondy_oplog_crdt_nested_core:sub_mod(DS) of
                        undefined ->
                            Acc#{K => lists:usort(maps:values(DS))};
                        SubMod ->
                            Acc#{
                                K =>
                                    bondy_oplog_crdt_nested_core:nested_value(
                                        SubMod, DS
                                    )
                            }
                    end
            end
        end,
        #{},
        Entries
    ).

-doc """
The cell's current causal context — the version vector the substrate
stamps into the next write's `meta`.
""".
-spec context_of(state()) -> context().

context_of({_Entries, CC, _Hlc}) ->
    CC.

-doc """
Reap the causal-context entries of permanently-retired origins (the
membership-driven GC). The cell-wide context `CC` carries one
`{Origin, MaxSeq}` entry per origin that ever wrote the cell — the cost
that grows with cluster *churn*. For a
retired origin we drop its `CC` entry **only when it has no live dot** in
any key's dot-store (no surviving add). The dot-stores carry the map's
value, so dropping a dot-free origin from `CC` leaves `to_value/1`
unchanged (value-preserving). A retired origin that still holds a live dot
is retained (that dot is a surviving sibling — real map data, and its
causal context must stay consistent with it) and excluded from `Reaped`,
which lists exactly the origins actually dropped.

Safe only once the origin is permanently gone *and* causally stable
cluster-wide — the operator's obligation, the same class as origin
uniqueness (see *Convergence preconditions*). The pass is idempotent.
""".
-spec reap_origins(state(), [origin()]) -> {state(), Reaped :: [origin()]}.

reap_origins({Entries, CC, Hlc}, Retired) ->
    Live = live_origins(Entries),
    Reaped = [
        O
     || {O, _S} <- CC,
        lists:member(O, Retired),
        not sets:is_element(O, Live)
    ],
    case Reaped of
        [] ->
            {{Entries, CC, Hlc}, []};
        _ ->
            CC1 = [{O, S} || {O, S} <- CC, not lists:member(O, Reaped)],
            {{Entries, CC1, Hlc}, lists:usort(Reaped)}
    end.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_Entries, _CC, Hlc}) ->
    Hlc.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    false.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-spec batchable() -> boolean().

batchable() ->
    true.

-spec encode_state(state()) -> binary().

encode_state({_Entries, _CC, _Hlc} = State) ->
    <<?ENC_V1, (term_to_binary(canon(State)))/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<?ENC_V1, Bin/binary>>) ->
    %% C-2: `[safe]` — decodes peer-shipped CRDT state on the AAE merge path.
    uncanon(binary_to_term(Bin, [safe])).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
%% The set of origins that hold at least one LIVE dot (a surviving
%% sibling) across all keys' dot-stores. An origin in this set carries
%% real map data and is therefore never reaped from the context.
live_origins(Entries) ->
    maps:fold(
        fun(_K, DS, Acc) ->
            maps:fold(
                fun({O, _S}, _V, A) -> sets:add_element(O, A) end, Acc, DS
            )
        end,
        sets:new([{version, 2}]),
        Entries
    ).

%% @private
key_hlc(Key) ->
    bondy_oplog_event:key_hlc(Key).

%% The dot/version-vector machinery (`dot_of`, `normalise_context`,
%% `drop_observed`, `dot_observed`, `cc_absorb`, `vv_merge`) lives in the
%% shared add-wins core `bondy_oplog_crdt_aw_core`, reused by every tier_2
%% add-wins type (this map, the add-wins set, the enable-wins flag).

%% @private
%% Canonical (map-free) encodable form: entries as a key-sorted list of
%% `{Key, dot-sorted list of {Dot, Value}}`, context sorted by origin, HLC.
canon({Entries, CC, Hlc}) ->
    EntriesL = lists:sort([
        {K, lists:sort(maps:to_list(DS))}
     || {K, DS} <- maps:to_list(Entries)
    ]),
    {EntriesL, lists:sort(CC), Hlc}.

%% @private
uncanon({EntriesL, CC, Hlc}) ->
    Entries = maps:from_list([{K, maps:from_list(L)} || {K, L} <- EntriesL]),
    {Entries, CC, Hlc}.
