%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_nested_core).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Shared **two-level add-wins-with-nesting** engine, used by
`bondy_oplog_crdt_aw_map` and `bondy_oplog_crdt_aw_set` to let a
dynamic-key entry's *value* itself be another CRDT's converged state,
rather than an opaque term.

## Why this exists

Both consumers share the identical shape `entries() :: #{OuterKey =>
dot_store()}`, `dot_store() :: #{dot() => value()}` — a key/element is
present iff its dot-store is non-empty, and a remove drops exactly the
dots its writer observed
(`bondy_oplog_crdt_aw_core:drop_observed/2`), leaving concurrent
(un-observed) writes as surviving siblings. That machinery is entirely
value-agnostic — `drop_observed/2` only ever inspects the *dot* (the
map key), never the value — so it already prunes a nested sub-op's dot
on a concurrent remove exactly as it prunes a flat value's dot today,
with no changes needed there. What this module adds is the *nested*
value itself: a value of `{sub, SubMod, Hlc, SubOp}` is replayed, on
read, through `SubMod`'s own `interpret_cog/2` — the same convergence
kernel every `bondy_oplog_crdt` module already implements — rather than
being stored as an opaque flat term.

## Restriction: tier_0 sub-CRDTs only

`SubMod` MUST be a `causal_tier() =:= tier_0` module (`pn_counter`,
`lww_register`, `max_register`, `min_register`, `g_counter`, ...). A
tier_0 sub-CRDT's `interpret_cog/2` needs only each sub-op's HLC to
linearize correctly (`bondy_oplog_crdt.erl`'s tier definitions), and
that HLC is already sitting in the parent's own dot/event key — no
nested causal-context (version-vector) threading is required.
Recursive tier_2-in-tier_2 nesting is a real but separately-scoped
extension, not attempted here.

## Type consistency

A key/element's `SubMod` is fixed by its first nested write — mixing a
flat `put/5` and `put_nested/7` on the same live key, or changing
`SubMod` on a live key, is a caller error and raises `{badarg, _}`: a
silent type mix would corrupt `nested_value/2`'s replay, which assumes
every surviving entry at a key shares one `SubMod`.

## `stabilize_fold/2` — bounding the nested PO-Log by causal stabilization

A nested key/field's dot-store IS a pure op-based PO-Log: one entry per
sub-op, forever (`put_nested/7` deliberately never prunes). What bounds
it is causal stabilization compaction (Baquero, Almeida and Shoker,
arXiv:1710.04469 §7.2): once every op below `StableHlc` is causally
stable, an origin's stable run of sub-ops can be collapsed into ONE
synthetic op — the module's own `interpret_cog/2` folds the run, its
`state_to_op/1` names the op that rebuilds the result — kept at the
run's max dot. The store shrinks from `O(ops)` to `O(origins)` per key.

The fold is **per-origin**, never cross-origin, for three exact reasons:

1. `force_reap/2` drops by dot origin; a contribution folded under a
   foreign origin's dot would silently survive its own origin's forced
   reap.
2. A sub-CRDT that dedups by per-origin sequence (`pn_counter`'s
   `MaxSeq`) must keep seeing each origin's contributions under that
   origin.
3. Per-origin HLC monotonicity makes "entries with `Hlc <
   StableHlc`" a true per-origin *seq prefix*, so the synthetic op at
   the run's max seq linearizes exactly where the run ended.

**License boundary — callers beware.** The HLC frontier (I2 — every
replica holds every event at or below it; nothing at or below it will
ever be delivered again) is sufficient ONLY for a dot-store that is
never *partially dropped by an observed context*. A struct field
qualifies: its only operation is `put_nested/7`, so no context ever
selects among its dots. An `aw_map`/`aw_set` key does NOT: a `{rmv, K}`
minted before frontier certification can carry an HLC *above* the
frontier (HLCs of concurrent events are unordered) while its stamped
context observes only a *prefix* of an origin's stable run — delivered
after the fold, `drop_observed/2` can no longer drop the observed
prefix's contribution out of the synthetic op, and replicas that folded
at different moments diverge. Folding an observed-remove dot-store
therefore needs *vector* stability (a confirmed lower bound on every
future context), which the substrate does not currently certify — so
the collection types do not call this, and their nested keys stay
unbounded until it does.

Two further preconditions the substrate provides: an event reaches a
given projection at most once (replay-pairs anchoring — a folded-away
dot that got re-delivered would re-add itself and double-count), and
the fold is undone (harmlessly, losing only the saving) by any full
re-derivation of the projection from the MST.

## `force_reap/2` — a stronger, opt-in alternative to `reap_origins/2`

A CRDT module's own `reap_origins/2` (see `bondy_oplog_crdt.erl`) is
deliberately conservative: it drops an origin's *causal-context*
bookkeeping only once that origin has no surviving value anywhere,
never the value itself — the right default for a general-purpose type,
where a retired writer's surviving contribution may still be meaningful
application data. `force_reap/2` is the opposite: it unconditionally
drops every surviving entry (flat or nested) whose dot's origin is
retired, discarding value data outright. This is only safe for a field
whose own domain semantics make a retired origin's contributions
unconditionally, permanently invalid — e.g. a set of live-session
markers scoped to one node's process lifetime, where the origin
retiring (that node's oplog identity rotating away, e.g. after a crash)
*means* every entry it wrote is already gone in reality, not just in
bookkeeping. Getting `RetiredOrigins` wrong here is a permanent data
loss, not a bookkeeping-bloat nuisance — heed `reap_origins/2`'s own
"operator's obligation" caution more strictly still.
""").

-export([force_reap/2]).
-export([nested_value/2]).
-export([put/5]).
-export([put_nested/7]).
-export([rmv/3]).
-export([stabilize_fold/2]).
-export([sub_mod/1]).

-type dot() :: bondy_oplog_crdt_aw_core:dot().
-type outer_key() :: term().
-type flat_value() :: term().
-type sub_value() :: {sub, module(), bondy_oplog_hlc:hlc(), term()}.
-type value() :: flat_value() | sub_value().
-type dot_store() :: #{dot() => value()}.
-type entries() :: #{outer_key() => dot_store()}.

-export_type([entries/0, dot_store/0, value/0, sub_value/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Put a flat value `V` at key `K`: drop every dot the writer's `Ctx`
observed, then add `V` under the operation's own `Dot`. Raises
`{badarg, {nested_key, K}}` if `K` currently holds nested sub-ops —
mixing flat and nested writes on the same key is a caller error.
""".
-spec put(
    Entries :: entries(),
    K :: outer_key(),
    Dot :: dot(),
    Ctx :: bondy_oplog_crdt_aw_core:vv(),
    V :: flat_value()
) -> entries().

put(Entries, K, Dot, Ctx, V) ->
    DS0 = maps:get(K, Entries, #{}),
    DS1 = bondy_oplog_crdt_aw_core:drop_observed(DS0, Ctx),
    sub_mod(DS1) =:= undefined orelse error({badarg, {nested_key, K}}),
    Entries#{K => DS1#{Dot => V}}.

-doc """
Adds a sub-operation `SubOp` (targeting sub-CRDT `SubMod`) at key `K`
under the operation's own `Dot`, alongside every sub-op already there —
deliberately not an observed-remove: see the note on `Ctx` below. Raises
`{badarg, {sub_mod_mismatch, K, Expected, Got}}` if `K` already holds
sub-ops for a *different* `SubMod`, or `{badarg, {flat_key, K}}` if `K`
currently holds a flat (non-nested) value.
""".
-spec put_nested(
    Entries :: entries(),
    K :: outer_key(),
    Dot :: dot(),
    Ctx :: bondy_oplog_crdt_aw_core:vv(),
    SubMod :: module(),
    Hlc :: bondy_oplog_hlc:hlc(),
    SubOp :: term()
) -> entries().

%% `Ctx` is accepted (matching `put/5`'s signature, so callers thread the
%% same dot/context pair through either call uniformly) but deliberately
%% unused: see below.
put_nested(Entries, K, Dot, _Ctx, SubMod, Hlc, SubOp) ->
    DS0 = maps:get(K, Entries, #{}),
    ok = check_sub_mod(DS0, K, SubMod),
    %% Deliberately no drop_observed/2 here, unlike put/5. A flat value is
    %% a register — a sequential same-origin write should supersede its
    %% own prior value, which is exactly what drop_observed/2 achieves.
    %% A nested sub-op is not a value to be superseded; it is one event in
    %% a sequence every one of which must survive to be individually
    %% folded through SubMod's own interpret_cog (an accumulator like
    %% pn_counter, or a permanent-membership type like two_p_set, computes
    %% the wrong result if any of its own ops go missing). Only an
    %% explicit rmv/3 of the whole outer key may prune nested sub-op
    %% dots — never an ordinary same-origin put_nested/7.
    Entries#{K => DS0#{Dot => {sub, SubMod, Hlc, SubOp}}}.

-doc """
Observed-remove at key `K`: drop every dot the writer's `Ctx` observed
(flat or nested, uniformly — `drop_observed/2` never inspects the
value). Drops `K` from `Entries` entirely once its dot-store empties.
""".
-spec rmv(
    Entries :: entries(),
    K :: outer_key(),
    Ctx :: bondy_oplog_crdt_aw_core:vv()
) -> entries().

rmv(Entries, K, Ctx) ->
    DS0 = maps:get(K, Entries, #{}),
    DS1 = bondy_oplog_crdt_aw_core:drop_observed(DS0, Ctx),
    case map_size(DS1) of
        0 -> maps:remove(K, Entries);
        _ -> Entries#{K => DS1}
    end.

-doc """
Unconditionally drops every dot (flat or nested value, uniformly) whose
origin is in `RetiredOrigins` — see the moduledoc's *"`force_reap/2` — a
stronger, opt-in alternative to `reap_origins/2`"* section for when this
is (and is not) safe to use. Operates on a bare `dot_store()`, so it
applies equally to one `aw_map`/`aw_set` key's dot-store or one
`bondy_oplog_crdt_struct` field's.
""".
-spec force_reap(DotStore :: dot_store(), RetiredOrigins :: [term()]) ->
    dot_store().

force_reap(DotStore, RetiredOrigins) ->
    maps:filter(
        fun({Origin, _Seq}, _V) -> not lists:member(Origin, RetiredOrigins) end,
        DotStore
    ).

-doc """
Causal-stabilization compaction of one nested PO-Log (see the moduledoc
section *"`stabilize_fold/2` — bounding the nested PO-Log"* for the
theory, the per-origin rationale and the **license boundary**: only a
dot-store never partially dropped by an observed context may be folded
at the HLC frontier — the caller owns that guarantee).

For every origin holding at least two entries with `Hlc < StableHlc`
(per-origin HLC monotonicity makes those a true seq prefix), replays the
run through `SubMod:interpret_cog/2` from bottom — exactly as
`nested_value/2` would — and replaces it with the single op
`SubMod:state_to_op/1` names, kept at the run's max dot and max HLC.
`unchanged` when the store is flat, `SubMod` opts out (no
`state_to_op/1`, or not `order_independent/0`), or no origin has a
foldable run. Value-preserving by construction: the fold IS the module's
own convergence kernel.
""".
-spec stabilize_fold(
    DotStore :: dot_store(), StableHlc :: bondy_oplog_hlc:hlc()
) -> {folded, dot_store()} | unchanged.

stabilize_fold(DotStore, StableHlc) ->
    case sub_mod(DotStore) of
        undefined ->
            unchanged;
        SubMod ->
            case foldable(SubMod) of
                true -> do_stabilize_fold(SubMod, DotStore, StableHlc);
                false -> unchanged
            end
    end.

-doc """
The `SubMod` a dot-store's surviving entries were written with, or
`undefined` if it holds no nested entries (empty, or all flat values).
Every surviving entry at a key is guaranteed to share one `SubMod` —
`put_nested/7` rejects any write that would violate this.
""".
-spec sub_mod(dot_store()) -> module() | undefined.

sub_mod(DotStore) ->
    case [M || {sub, M, _, _} <- maps:values(DotStore)] of
        [M | _] -> M;
        [] -> undefined
    end.

-doc """
The sub-CRDT's converged value at a key: replay every surviving
`{sub, SubMod, Hlc, SubOp}` entry, in `{Hlc, Origin, Seq}` order, through
`SubMod:interpret_cog/2` starting from `SubMod:init/0`, then
`SubMod:to_value/1`. Requires no callback beyond what every
`bondy_oplog_crdt` module already exports.
""".
-spec nested_value(SubMod :: module(), DotStore :: dot_store()) -> term().

nested_value(SubMod, DotStore) ->
    Events = [
        bondy_oplog_event:new(
            bondy_oplog_event:key(Hlc, Origin, Seq), SubOp, undefined
        )
     || {{Origin, Seq}, {sub, _, Hlc, SubOp}} <- maps:to_list(DotStore)
    ],
    State = SubMod:interpret_cog(Events, SubMod:init()),
    SubMod:to_value(State).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% A sub-CRDT opts into folding by exporting `state_to_op/1` AND declaring
%% `order_independent() -> true` — the fold displaces a run's contributions
%% to a single position in the replay order, which only an
%% order-independent type absorbs.
foldable(SubMod) ->
    _ = code:ensure_loaded(SubMod),
    erlang:function_exported(SubMod, state_to_op, 1) andalso
        erlang:function_exported(SubMod, order_independent, 0) andalso
        SubMod:order_independent().

%% @private
do_stabilize_fold(SubMod, DotStore, StableHlc) ->
    Stable = maps:fold(
        fun
            ({O, S}, {sub, _, H, Op}, Acc) when H < StableHlc ->
                maps:update_with(
                    O, fun(L) -> [{S, H, Op} | L] end, [{S, H, Op}], Acc
                );
            (_Dot, _V, Acc) ->
                Acc
        end,
        #{},
        DotStore
    ),
    Runs = [
        {O, lists:sort(Entries)}
     || {O, Entries} <- maps:to_list(Stable),
        length(Entries) >= 2
    ],
    fold_runs(Runs, SubMod, DotStore, false).

%% @private
%% Replace each origin's stable run with its synthetic op. A run whose
%% folded state has no representing op (`state_to_op/1` -> `undefined`)
%% is left as-is — nothing was removed, so correctness is untouched.
fold_runs([], _SubMod, DotStore, true) ->
    {folded, DotStore};
fold_runs([], _SubMod, _DotStore, false) ->
    unchanged;
fold_runs([{O, Entries} | Rest], SubMod, DotStore0, Changed) ->
    Events = [
        bondy_oplog_event:new(bondy_oplog_event:key(H, O, S), Op, undefined)
     || {S, H, Op} <- Entries
    ],
    State = SubMod:interpret_cog(Events, SubMod:init()),
    case SubMod:state_to_op(State) of
        undefined ->
            fold_runs(Rest, SubMod, DotStore0, Changed);
        FoldedOp ->
            {RepSeq, _, _} = lists:last(Entries),
            MaxHlc = lists:max([H || {_S, H, _Op} <- Entries]),
            DotStore1 = lists:foldl(
                fun({S, _H, _Op}, Acc) -> maps:remove({O, S}, Acc) end,
                DotStore0,
                Entries
            ),
            DotStore = DotStore1#{
                {O, RepSeq} => {sub, SubMod, MaxHlc, FoldedOp}
            },
            fold_runs(Rest, SubMod, DotStore, true)
    end.

%% @private
check_sub_mod(DS, K, SubMod) ->
    case sub_mod(DS) of
        undefined when map_size(DS) =:= 0 -> ok;
        undefined -> error({badarg, {flat_key, K}});
        SubMod -> ok;
        Other -> error({badarg, {sub_mod_mismatch, K, Other, SubMod}})
    end.
