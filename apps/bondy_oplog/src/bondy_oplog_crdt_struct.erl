%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_struct).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Fixed-schema record CRDT — the "ImmutableCRDT" of Bauwens/Gonzalez Boix,
*Nested Pure Operation-Based CRDTs* (ECOOP 2023, Table 4): "a map with
immutable keys, which behaves similarly to structs in C." Every field is
declared upfront by a schema and always exists; there is no add/remove of
a field as a *key* — only its nested sub-CRDT content mutates.

## A directly-registrable `bondy_oplog_crdt`, construction-configured

`bondy_oplog_crdt:init/0` is arity 0 — it cannot itself take a schema
parameter, so this module's own `init/0` raises: it has no schema of its
own. A table registers this module as its `crdt_module` directly and
supplies the schema as `crdt_opts` in the catalog's table config; the
kernel's opts-aware construction path (`bondy_oplog_cell_kernel:init/2`)
calls `init/1` with it instead of the plain `init/0`. No per-use-case
wrapper module is needed just to supply a schema.

```erlang
%% catalog table config
#{
    fold_module => lww_register,
    crdt_module => bondy_oplog_crdt_struct,
    crdt_opts => #{
        count => {bondy_oplog_crdt_pn_counter, #{stabilize_zero => 0}},
        invoke => bondy_oplog_crdt_lww_register,
        earliest => bondy_oplog_crdt_min_register,
        latest => bondy_oplog_crdt_max_register
    }
}
```

Each schema value is either a bare sub-CRDT module (no policy) or a
`{Module, PolicyOpts}` pair. Two policy keys are recognized, both opt-in
and both affecting only the generic `reap_origins/2`/`stabilize/2` this
module implements — a field with no policy participates in neither:

- `force_reap => true` — this field's dot-store entries for a retired
  origin are unconditionally, permanently dropped by `reap_origins/2`
  (via `force_reap_field/3`, still exported for the rare case a caller
  needs to invoke it directly). Only correct for a field whose own domain
  semantics make a retired origin's contributions permanently invalid
  (e.g. a live-membership set scoped to one node's process lifetime) —
  see `force_reap_field/3`'s doc.
- `stabilize_zero => Zero` — `stabilize/2` discards the whole cell once
  every field declaring this holds its `Zero` value (its own algebraic
  identity, e.g. a live-count field reaching `0`) and every constituent
  operation is causally stable. A schema declaring no `stabilize_zero`
  field never discards.

A per-use-case wrapper module implementing `bondy_oplog_crdt` directly
(the older pattern) is still an option for a type needing bespoke
`to_value/1` reshaping or policy this declarative surface doesn't cover —
this module only removes the need for one when a per-field opt-in policy
and the raw `#{field_key() => value}` projection are enough.

## State

```
{Schema  :: #{field_key() => module() | {module(), map()}},
 Fields  :: #{field_key() => dot_store()},
 Context :: bondy_dvvset:vector(),
 MaxHlc  :: hlc()}
```

`Schema` is fixed at construction (`init/1`) and round-trips through
`encode_state/1`/`decode_state/1` — it is data, not code, so it travels
with the cell like any other field. A field absent from `Fields` (never
written) projects its sub-CRDT's *bottom* value (`SubMod:init/0`'s own
`to_value/1`), which is what "always exists" means in practice: there is
nothing to default before first write, because the sub-CRDT already
defines its own zero/empty state.

## Operations

```
{apply, field_key(), term()}   %% apply a sub-op to a schema-declared field
```

There is no `put`/`rmv` — every field's type is fixed by the schema, not
chosen per write, and no field is ever removed. `apply_op/4` still
threads a causal `Context` and mints a dot per sub-op
(`bondy_oplog_crdt_nested_core:put_nested/7`, keyed by `field_key()`
instead of a map key), but the dot is bookkeeping only — `put_nested/7`
deliberately does **not** prune a writer's own prior dot on the field
(unlike a flat register's `put/5`): every sub-op is one event in a
sequence that must survive to be individually folded through `SubMod`'s
own `interpret_cog` (an accumulator like `pn_counter`, or a
permanent-membership type like `two_p_set`, computes the wrong value if
any of its own ops go missing — pruning "the writer's own observed
dot" is only correct for a value being superseded, never for an op being
accumulated). A field's dot-store therefore grows with every write —
until causal stabilization bounds it: `stabilize/2` folds every field's
causally-stable per-origin sub-op runs into synthetic ops
(`bondy_oplog_crdt_nested_core:stabilize_fold/2`), collapsing each
field to `O(origins)` entries. The struct is precisely the shape that
makes this fold sound at the substrate's HLC stability frontier: with no
`put`/`rmv`, no operation ever partially drops a field's dot-store by
observed context — see the license-boundary discussion in
`bondy_oplog_crdt_nested_core`'s moduledoc (the same fold is NOT safe
for `aw_map`/`aw_set` keys, whose `{rmv, _}` selects dots by context).

Every schema value MUST be `causal_tier() =:= tier_0`
(`pn_counter`, `lww_register`, `max_register`, `min_register`, ...) —
see `bondy_oplog_crdt_aw_map`'s moduledoc for why (the same reasoning
applies here: a tier_0 sub-op needs only its own HLC to linearize).
""").

%% bondy_oplog_crdt
-export([causal_tier/0]).
-export([init/0]).
-export([interpret_cog/2]).
-export([query/2]).
%% projection seam
-export([batchable/0]).
-export([context_of/1]).
-export([decode_state/1]).
-export([encode_state/1]).
-export([hlc/1]).
-export([order_independent/0]).
-export([reap_origins/2]).
-export([stabilize/2]).
-export([to_value/1]).
-export([value_equals_state/0]).
%% bondy_oplog_crdt_commutative (tier_2 step)
-export([apply_op/4]).
%% toolkit-specific (construction + per-field policy escape hatch)
-export([force_reap_field/3]).
-export([init/1]).

-type field_key() :: term().
-type origin() :: binary().
-type field_policy() :: #{force_reap => boolean(), stabilize_zero => term()}.
-type schema() :: #{field_key() => module() | {module(), field_policy()}}.
-type dot_store() :: bondy_oplog_crdt_nested_core:dot_store().
-type fields() :: #{field_key() => dot_store()}.
-type context() :: bondy_dvvset:vector().
-type state() :: {schema(), fields(), context(), bondy_oplog_hlc:hlc()}.
-type op() :: {apply, field_key(), term()}.

-export_type([state/0, op/0, field_key/0, schema/0]).

%% The state encoding format version (leading byte of `encode_state/1`).
-define(ENC_V1, 1).

%% =============================================================================
%% API
%% =============================================================================

-spec causal_tier() -> tier_2.

causal_tier() ->
    tier_2.

-doc """
Raises — this module has no fixed schema of its own; a caller must supply
one via `init/1`. Declared only to complete the `bondy_oplog_crdt`
behaviour contract: the actual dispatch path for a catalog-configured
struct table is the kernel's opts-aware `bondy_oplog_cell_kernel:init/2`,
which calls `init/1` with the table's configured `crdt_opts` (its
schema) — `init/0` is never meant to be reached in practice.
""".
-spec init() -> no_return().

init() ->
    error({missing_schema, ?MODULE}).

-doc "Bottom state for a struct declaring `Schema`. Pure.".
-spec init(Schema :: schema()) -> state().

init(Schema) when is_map(Schema) ->
    {Schema, #{}, [], 0}.

-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

-spec query(value, state()) -> #{field_key() => term()}.

query(value, State) ->
    to_value(State).

-doc """
Apply `{apply, FieldKey, SubOp}` with its observed causal `Context` (the
stamped version vector in the event `meta`). Raises `{badarg,
{unknown_field, FieldKey}}` if `FieldKey` is not in the schema.
""".
-spec apply_op(
    state(),
    op(),
    bondy_oplog_event:event_key(),
    Context :: context() | undefined
) -> state().

apply_op({Schema, Fields, CC, Hlc}, {apply, FieldKey, SubOp}, Key, Context0) ->
    Entry = maps:get(FieldKey, Schema, undefined),
    Entry =/= undefined orelse error({badarg, {unknown_field, FieldKey}}),
    SubMod = field_module(Entry),
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Fields1 = bondy_oplog_crdt_nested_core:put_nested(
        Fields, FieldKey, Dot, Ctx, SubMod, key_hlc(Key), SubOp
    ),
    {
        Schema,
        Fields1,
        bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))
    }.

-doc """
The struct's value: every schema field mapped to its sub-CRDT's converged
value (`bondy_oplog_crdt_nested_core:nested_value/2`) — a field never
written projects its sub-CRDT's bottom value.
""".
-spec to_value(state()) -> #{field_key() => term()}.

to_value({Schema, Fields, _CC, _Hlc}) ->
    maps:map(
        fun(FieldKey, Entry) ->
            SubMod = field_module(Entry),
            DS = maps:get(FieldKey, Fields, #{}),
            bondy_oplog_crdt_nested_core:nested_value(SubMod, DS)
        end,
        Schema
    ).

-doc """
The cell's current causal context — the version vector the substrate
stamps into the next write's `meta`.
""".
-spec context_of(state()) -> context().

context_of({_Schema, _Fields, CC, _Hlc}) ->
    CC.

-doc """
Reap the causal-context entries of permanently-retired origins, mirroring
`bondy_oplog_crdt_aw_map`. First unconditionally force-reaps every
`force_reap => true` schema field (via `force_reap_field/3`), then drops
a retired origin's `CC` entry only when it has no live dot in any field's
dot-store (evaluated AFTER the force-reap step, so a field-force-reaped
origin no longer counts as live through that field alone) — so the value
(`to_value/1`) of every field WITHOUT `force_reap` is unchanged.
Idempotent. Safe only once the origin is permanently gone and causally
stable cluster-wide (the operator's obligation).
""".
-spec reap_origins(state(), [origin()]) -> {state(), Reaped :: [origin()]}.

reap_origins({Schema, Fields0, CC, Hlc}, Retired) ->
    ForceReapKeys = [
        FieldKey
     || {FieldKey, Entry} <- maps:to_list(Schema),
        maps:get(force_reap, field_policy(Entry), false)
    ],
    Fields1 = lists:foldl(
        fun(FieldKey, Acc) ->
            DS0 = maps:get(FieldKey, Acc, #{}),
            DS1 = bondy_oplog_crdt_nested_core:force_reap(DS0, Retired),
            Acc#{FieldKey => DS1}
        end,
        Fields0,
        ForceReapKeys
    ),
    Live = live_origins(Fields1),
    Reaped = [
        O
     || {O, _S} <- CC,
        lists:member(O, Retired),
        not sets:is_element(O, Live)
    ],
    case Reaped of
        [] ->
            {{Schema, Fields1, CC, Hlc}, []};
        _ ->
            CC1 = [{O, S} || {O, S} <- CC, not lists:member(O, Reaped)],
            {{Schema, Fields1, CC1, Hlc}, lists:usort(Reaped)}
    end.

-doc """
Causal stabilization, two reductions in order of strength:

1. `discard` once every schema field declaring a `stabilize_zero` policy
   value currently holds that value and every constituent operation is
   strictly below the stability point. A schema declaring no
   `stabilize_zero` field never discards (opt-in only).
2. Otherwise `{keep, Reduced}` when any field's causally-stable
   per-origin sub-op runs could be folded into synthetic ops
   (`bondy_oplog_crdt_nested_core:stabilize_fold/2`) — the compaction
   that bounds a field's PO-Log at `O(origins)`. Value-preserving
   (the fold is each sub-CRDT's own convergence kernel) and
   context-preserving (`CC` untouched). Sound at the HLC frontier
   because no struct operation partially drops a field's dot-store by
   observed context — see the moduledoc and `stabilize_fold/2`'s
   license boundary.

`keep` when neither applies.
""".
-spec stabilize(bondy_oplog_hlc:hlc(), state()) ->
    keep | {keep, state()} | discard.

stabilize(StableHlc, {Schema, Fields, CC, Hlc} = State) ->
    case zero_discard(StableHlc, State) of
        discard ->
            discard;
        keep ->
            {Fields1, Folded} = maps:fold(
                fun(FieldKey, DS, {Acc, Changed}) ->
                    case
                        bondy_oplog_crdt_nested_core:stabilize_fold(
                            DS, StableHlc
                        )
                    of
                        unchanged -> {Acc, Changed};
                        {folded, DS1} -> {Acc#{FieldKey => DS1}, true}
                    end
                end,
                {Fields, false},
                Fields
            ),
            case Folded of
                true -> {keep, {Schema, Fields1, CC, Hlc}};
                false -> keep
            end
    end.

-doc """
Unconditionally drops `FieldKey`'s dot-store entries whose origin is in
`RetiredOrigins` — see
`bondy_oplog_crdt_nested_core:force_reap/2`'s moduledoc section for when
this is (and is not) safe: only for a field whose own domain semantics
make a retired origin's contributions unconditionally, permanently
invalid, never as a general-purpose substitute for `reap_origins/2`'s
conservative default.
""".
-spec force_reap_field(
    State :: state(), FieldKey :: field_key(), RetiredOrigins :: [term()]
) -> state().

force_reap_field({Schema, Fields, CC, Hlc}, FieldKey, RetiredOrigins) ->
    DS0 = maps:get(FieldKey, Fields, #{}),
    DS1 = bondy_oplog_crdt_nested_core:force_reap(DS0, RetiredOrigins),
    {Schema, Fields#{FieldKey => DS1}, CC, Hlc}.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_Schema, _Fields, _CC, Hlc}) ->
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

encode_state({_Schema, _Fields, _CC, _Hlc} = State) ->
    <<?ENC_V1, (term_to_binary(canon(State)))/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<?ENC_V1, Bin/binary>>) ->
    %% C-2: `[safe]` — this decodes peer-shipped CRDT state on the AAE merge
    %% path. Schema values are module atoms of already-loaded CRDT modules
    %% (optionally paired with a policy map whose keys/values are also
    %% already-loaded atoms), so `[safe]` (no new atom creation) round-trips
    %% them without risk.
    uncanon(binary_to_term(Bin, [safe])).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
key_hlc(Key) ->
    bondy_oplog_event:key_hlc(Key).

%% @private
%% The whole-cell `stabilize_zero` discard check (`stabilize/2`'s first
%% reduction), gated on the cell's head HLC being strictly below the
%% stability point.
zero_discard(StableHlc, {Schema, _Fields, _CC, Hlc} = State) when
    Hlc < StableHlc
->
    ZeroChecks = [
        {FieldKey, Zero}
     || {FieldKey, Entry} <- maps:to_list(Schema),
        {ok, Zero} <- [maps:find(stabilize_zero, field_policy(Entry))]
    ],
    case ZeroChecks of
        [] ->
            keep;
        _ ->
            Value = to_value(State),
            AllZero = lists:all(
                fun({FieldKey, Zero}) -> maps:get(FieldKey, Value) =:= Zero end,
                ZeroChecks
            ),
            case AllZero of
                true -> discard;
                false -> keep
            end
    end;
zero_discard(_StableHlc, _State) ->
    keep.

%% @private
%% Normalizes a schema entry to its sub-CRDT module, ignoring any policy.
field_module({Mod, Opts}) when is_atom(Mod), is_map(Opts) ->
    Mod;
field_module(Mod) when is_atom(Mod) ->
    Mod.

%% @private
%% Normalizes a schema entry to its policy map (`#{}` when none declared).
field_policy({Mod, Opts}) when is_atom(Mod), is_map(Opts) ->
    Opts;
field_policy(Mod) when is_atom(Mod) ->
    #{}.

%% @private
%% The set of origins that hold at least one live dot (in any field's
%% dot-store) — these carry the struct's value and are never reaped from
%% the context.
live_origins(Fields) ->
    maps:fold(
        fun(_FieldKey, DS, Acc) ->
            maps:fold(
                fun({O, _S}, _V, A) -> sets:add_element(O, A) end, Acc, DS
            )
        end,
        sets:new([{version, 2}]),
        Fields
    ).

%% @private
%% Canonical (map-free) encodable form: schema as a field-sorted list,
%% fields as a field-sorted list of `{FieldKey, dot-sorted list of
%% {Dot, Value}}`, context sorted by origin, HLC.
canon({Schema, Fields, CC, Hlc}) ->
    SchemaL = lists:sort(maps:to_list(Schema)),
    FieldsL = lists:sort([
        {FieldKey, lists:sort(maps:to_list(DS))}
     || {FieldKey, DS} <- maps:to_list(Fields)
    ]),
    {SchemaL, FieldsL, lists:sort(CC), Hlc}.

%% @private
uncanon({SchemaL, FieldsL, CC, Hlc}) ->
    Schema = maps:from_list(SchemaL),
    Fields = maps:from_list([
        {FieldKey, maps:from_list(L)}
     || {FieldKey, L} <- FieldsL
    ]),
    {Schema, Fields, CC, Hlc}.
