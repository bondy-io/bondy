%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_rw_set).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Remove-Wins Set (RWSet) — tier_2 operation-based CRDT.

The op-based equivalent of the pure `pure_rwset`. A set with `add` and
`rmv` where, when an add and a remove of the same element are
**concurrent, the remove wins** (the element is absent). The causal dual
of the add-wins set: an element's add survives only if it causally
observed every remove of that element.

Detecting concurrency needs true happens-before, so this is **tier_2**:
each write carries the writer's causal context (a version vector) in the
event `meta`, stamped by the substrate. The remove-wins resolution is
shared with `bondy_oplog_crdt_dw_flag` via `bondy_oplog_crdt_rw_core`; the
version-vector helpers come from `bondy_oplog_crdt_aw_core`. For add-wins
resolution use `bondy_oplog_crdt_aw_set`.

## State

```
{Elems :: #{elem() => rw_core:cell()},   %% per element: surviving adds + remove frontier
 Context :: bondy_dvvset:vector(),
 MaxHlc  :: hlc()}
```

A per-element cell keeps the element's surviving adds (each with the
context it observed) and its remove frontier; the element is present iff a
surviving add remains.

## Operations

```
{add, Elem :: binary()}
{rmv, Elem :: binary()}
```

`value_equals_state/0 -> false`: the value is the set of present elements,
not the per-element cells.
""").

%% bondy_oplog_crdt
-export([causal_tier/0]).
-export([init/0]).
-export([interpret_cog/2]).
-export([query/2]).
%% projection seam
-export([to_value/1]).
-export([hlc/1]).
-export([gc_threshold/1]).
-export([value_equals_state/0]).
-export([order_independent/0]).
-export([batchable/0]).
-export([context_of/1]).
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative (tier_2 step)
-export([apply_op/4]).

-type elem() :: binary().
-type context() :: bondy_dvvset:vector().
-type state() :: {
    #{elem() => bondy_oplog_crdt_rw_core:cell()},
    context(),
    bondy_oplog_hlc:hlc()
}.
-type op() :: {add, elem()} | {rmv, elem()}.

-export_type([state/0, op/0, elem/0]).

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

-spec query(value, state()) -> [elem()].

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative (tier_2 step)
%% =============================================================================

-doc """
Apply one `{add, E}` or `{rmv, E}` with its observed causal `Context`,
delegating the remove-wins resolution to `bondy_oplog_crdt_rw_core`:

- `add`: store the op's dot with the context it observed, then drop it if a
  prior remove of `E` already beats it (concurrent/older add ⇒ remove
  wins).
- `rmv`: extend `E`'s remove frontier with the op's dot and prune any add
  the new frontier beats.

The surviving-add set is a pure function of the event set (an add survives
iff its context dominates `E`'s final remove frontier), so this eager step
equals the key-sorted `interpret_cog/2` fold.
""".
-spec apply_op(
    state(),
    op(),
    bondy_oplog_event:event_key(),
    Context :: context() | undefined
) -> state().

apply_op({Elems, CC, Hlc}, {add, E}, Key, Context0) when is_binary(E) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Cell0 = maps:get(E, Elems, bondy_oplog_crdt_rw_core:new()),
    Cell1 = bondy_oplog_crdt_rw_core:add(Cell0, Dot, Ctx),
    Elems1 = put_cell(Elems, E, Cell1),
    {Elems1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))};
apply_op({Elems, CC, Hlc}, {rmv, E}, Key, Context0) when is_binary(E) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Cell0 = maps:get(E, Elems, bondy_oplog_crdt_rw_core:new()),
    Cell1 = bondy_oplog_crdt_rw_core:rmv(Cell0, Dot),
    Elems1 = put_cell(Elems, E, Cell1),
    {Elems1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))}.

%% =============================================================================
%% projection seam
%% =============================================================================

-doc "The set's value: the elements with a surviving add.".
-spec to_value(state()) -> [elem()].

to_value({Elems, _CC, _Hlc}) ->
    lists:sort([
        E
     || {E, Cell} <- maps:to_list(Elems),
        bondy_oplog_crdt_rw_core:present(Cell)
    ]).

-doc "The cell's current causal context, stamped into the next write.".
-spec context_of(state()) -> context().

context_of({_Elems, CC, _Hlc}) ->
    CC.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_Elems, _CC, Hlc}) ->
    Hlc.

-spec gc_threshold(state()) -> bondy_oplog_hlc:hlc() | undefined.

gc_threshold({_Elems, _CC, 0}) ->
    undefined;
gc_threshold({_Elems, _CC, Hlc}) ->
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

encode_state({_Elems, _CC, _Hlc} = State) ->
    <<?ENC_V1, (term_to_binary(canon(State)))/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<?ENC_V1, Bin/binary>>) ->
    uncanon(binary_to_term(Bin)).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
key_hlc(Key) ->
    bondy_oplog_event:key_hlc(Key).

%% @private
%% Store a per-element cell, dropping the entry when the cell carries no
%% information (no surviving add and an empty remove frontier).
put_cell(Elems, E, Cell) ->
    case bondy_oplog_crdt_rw_core:is_empty(Cell) of
        true -> maps:remove(E, Elems);
        false -> Elems#{E => Cell}
    end.

%% @private
%% Canonical (map-free) encodable form: per-element cells with their `Adds`
%% maps and remove frontiers as sorted lists, elements key-sorted, context
%% sorted, HLC.
canon({Elems, CC, Hlc}) ->
    ElemsL = lists:sort([
        {E, canon_cell(Cell)}
     || {E, Cell} <- maps:to_list(Elems)
    ]),
    {ElemsL, lists:sort(CC), Hlc}.

%% @private
uncanon({ElemsL, CC, Hlc}) ->
    Elems = maps:from_list([{E, uncanon_cell(C)} || {E, C} <- ElemsL]),
    {Elems, CC, Hlc}.

%% @private
canon_cell({Adds, R}) ->
    {lists:sort(maps:to_list(Adds)), lists:sort(R)}.

%% @private
uncanon_cell({AddsL, R}) ->
    {maps:from_list(AddsL), R}.
