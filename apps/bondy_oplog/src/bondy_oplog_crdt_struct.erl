%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_struct).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Fixed-schema record CRDT — the "ImmutableCRDT" of Bauwens/Gonzalez Boix,
*Nested Pure Operation-Based CRDTs* (ECOOP 2023, Table 4): "a map with
immutable keys, which behaves similarly to structs in C." Every field is
declared upfront by a schema and always exists; there is no add/remove of
a field as a *key* — only its nested sub-CRDT content mutates.

## This is a toolkit, not a `bondy_oplog_crdt` implementation

`bondy_oplog_crdt:init/0` is arity 0 — it cannot take a schema parameter.
A fixed-schema type therefore needs its schema baked in at compile time
by a small, concrete per-use-case module, which forwards each behaviour
callback to this toolkit (the same relationship
`bondy_oplog_crdt_aw_map`/`bondy_oplog_crdt_aw_set` have with
`bondy_oplog_crdt_nested_core`, just with the schema closed over instead
of derived from the op):

```erlang
-module(my_row_crdt).
-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

schema() ->
    #{
        count => bondy_oplog_crdt_pn_counter,
        latest => bondy_oplog_crdt_max_register,
        earliest => bondy_oplog_crdt_min_register,
        invoke => bondy_oplog_crdt_lww_register
    }.

causal_tier() -> bondy_oplog_crdt_struct:causal_tier().
init() -> bondy_oplog_crdt_struct:init(schema()).
interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).
apply_op(State, Op, Key, Ctx) ->
    bondy_oplog_crdt_struct:apply_op(State, Op, Key, Ctx).
to_value(State) -> bondy_oplog_crdt_struct:to_value(State).
%% ... hlc/1, context_of/1, reap_origins/2, encode_state/1, decode_state/1,
%% value_equals_state/0, order_independent/0, batchable/0 forward the same way.
```

## State

```
{Schema  :: #{field_key() => module()},
 Fields  :: #{field_key() => dot_store()},
 Context :: bondy_dvvset:vector(),
 MaxHlc  :: hlc()}
```

`Schema` is fixed at construction (`init/1`) and round-trips through
`encode_state/1`/`decode_state/1` — it is data (a map to module atoms),
not code, so it travels with the cell like any other field. A field
absent from `Fields` (never written) projects its sub-CRDT's *bottom*
value (`SubMod:init/0`'s own `to_value/1`), which is what "always
exists" means in practice: there is nothing to default before first
write, because the sub-CRDT already defines its own zero/empty state.

## Operations

```
{apply, field_key(), term()}   %% apply a sub-op to a schema-declared field
```

There is no `put`/`rmv` — every field's type is fixed by the schema, not
chosen per write, and no field is ever removed. `apply_op/4` still
threads a causal `Context` and mints a dot per sub-op
(`bondy_oplog_crdt_nested_core:put_nested/7`, keyed by `field_key()`
instead of a map key) — not for add-wins resolution (there is nothing to
resolve: field presence is static), but to bound each field's dot-store
the same way `bondy_oplog_crdt_aw_map`'s flat `put` does: a writer's own
prior dot on that field is pruned by `drop_observed/2` before the new
dot is added, so repeated *sequential* writes from one origin do not
accumulate without bound — only genuinely concurrent writers grow the
set of surviving siblings the sub-CRDT replays.

Every schema value MUST be `causal_tier() =:= tier_0`
(`pn_counter`, `lww_register`, `max_register`, `min_register`, ...) —
see `bondy_oplog_crdt_aw_map`'s moduledoc for why (the same reasoning
applies here: a tier_0 sub-op needs only its own HLC to linearize).
""").

-export([apply_op/4]).
-export([batchable/0]).
-export([causal_tier/0]).
-export([context_of/1]).
-export([decode_state/1]).
-export([encode_state/1]).
-export([hlc/1]).
-export([init/1]).
-export([order_independent/0]).
-export([reap_origins/2]).
-export([to_value/1]).
-export([value_equals_state/0]).

-type field_key() :: term().
-type origin() :: binary().
-type schema() :: #{field_key() => module()}.
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

-doc "Bottom state for a struct declaring `Schema`. Pure.".
-spec init(Schema :: schema()) -> state().

init(Schema) when is_map(Schema) ->
    {Schema, #{}, [], 0}.

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
    SubMod = maps:get(FieldKey, Schema, undefined),
    SubMod =/= undefined orelse error({badarg, {unknown_field, FieldKey}}),
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
        fun(FieldKey, SubMod) ->
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
`bondy_oplog_crdt_aw_map`. Drops a retired origin's `CC` entry only when
it has no live dot in any field's dot-store — so the value (`to_value/1`)
is unchanged. Idempotent. Safe only once the origin is permanently gone
and causally stable cluster-wide (the operator's obligation).
""".
-spec reap_origins(state(), [origin()]) -> {state(), Reaped :: [origin()]}.

reap_origins({Schema, Fields, CC, Hlc}, Retired) ->
    Live = live_origins(Fields),
    Reaped = [
        O
     || {O, _S} <- CC,
        lists:member(O, Retired),
        not sets:is_element(O, Live)
    ],
    case Reaped of
        [] ->
            {{Schema, Fields, CC, Hlc}, []};
        _ ->
            CC1 = [{O, S} || {O, S} <- CC, not lists:member(O, Reaped)],
            {{Schema, Fields, CC1, Hlc}, lists:usort(Reaped)}
    end.

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
    %% path. Schema values are module atoms of already-loaded CRDT modules,
    %% so `[safe]` (no new atom creation) round-trips them without risk.
    uncanon(binary_to_term(Bin, [safe])).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
key_hlc(Key) ->
    bondy_oplog_event:key_hlc(Key).

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
