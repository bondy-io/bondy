%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_two_p_set).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Two-Phase Set (2P-Set) — native operation-based CRDT.

The op-based equivalent of the pure `pure_twopset`. A set with both
`add` and `rmv`, where **removal is permanent**: once an element has
been removed it can never be re-added (the remove tombstone wins over
any later add). This is the defining 2P-Set semantics and the reason
it is `tier_0` — no causal context is needed, because the resolution
rule ("removed ⇒ stays removed") does not depend on happens-before.

The state is a pair of grow-only sets. `add` grows the *add-set*, `rmv`
grows the *remove-set* (tombstones); the value is their set difference.
Both component sets converge by `ordsets:union/2` (commutative,
associative, idempotent), so the type is order-independent over all
permutations. A `rmv` of an element never added is harmless — it sits
in the tombstone set and the value excludes it regardless.

For *re-addable* observed-remove semantics (where a concurrent add can
survive a remove) use the add-wins set `bondy_oplog_crdt_aw_set`
(tier_2) instead.

## State

```
{Added :: ordsets:ordset(binary()),
 Removed :: ordsets:ordset(binary()),
 MaxHlc :: hlc()}
```

## Operations

```
{add, Elem :: binary()}
{rmv, Elem :: binary()}
```

The HLC is read from the event key. `value_equals_state/0 -> false`:
the value is the *difference* of the two sets, not the state itself, so
the substrate stores a value column.
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
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative
-export([apply_op/3]).

-type elem() :: binary().
-type set_t() :: ordsets:ordset(elem()).
-type state() :: {set_t(), set_t(), bondy_oplog_hlc:hlc()}.
-type op() :: {add, elem()} | {rmv, elem()}.

-export_type([state/0, op/0, elem/0]).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

-spec causal_tier() -> tier_0.

causal_tier() ->
    tier_0.

-spec init() -> state().

init() ->
    {[], [], 0}.

-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

-spec query(value, state()) -> set_t().

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative
%% =============================================================================

-doc """
Apply one operation in key order. `add` grows the add-set, `rmv` grows
the remove-set (tombstones); both via `ordsets:add_element/2`
(idempotent). The event's HLC is absorbed via `max`. `Key` is the event
dot (only its HLC is used — 2P-Set needs no per-op causal identity).
""".
-spec apply_op(state(), op(), bondy_oplog_event:event_key()) -> state().

apply_op({Added, Removed, H0}, {add, Elem}, Key) when is_binary(Elem) ->
    H = bondy_oplog_event:key_hlc(Key),
    {ordsets:add_element(Elem, Added), Removed, erlang:max(H0, H)};
apply_op({Added, Removed, H0}, {rmv, Elem}, Key) when is_binary(Elem) ->
    H = bondy_oplog_event:key_hlc(Key),
    {Added, ordsets:add_element(Elem, Removed), erlang:max(H0, H)}.

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> set_t().

to_value({Added, Removed, _H}) ->
    ordsets:subtract(Added, Removed).

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_A, _R, H}) -> H.

-spec gc_threshold(state()) -> bondy_oplog_hlc:hlc() | undefined.

gc_threshold({[], [], 0}) -> undefined;
gc_threshold({_A, _R, H}) -> H.

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

encode_state({Added, Removed, H}) when is_integer(H) ->
    AddedBin = encode_set(Added),
    RemovedBin = encode_set(Removed),
    <<H:64/big-unsigned, AddedBin/binary, RemovedBin/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<H:64/big-unsigned, Rest0/binary>>) ->
    {Added, Rest1} = decode_set(Rest0),
    {Removed, <<>>} = decode_set(Rest1),
    {Added, Removed, H}.

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
%% A set is encoded as a 32-bit element count followed by each element
%% length-prefixed. Mirrors the `bondy_oplog_crdt_g_set` element framing.
encode_set(Set) ->
    NumElems = length(Set),
    ElemsBin = iolist_to_binary([encode_elem(E) || E <- Set]),
    <<NumElems:32/big-unsigned, ElemsBin/binary>>.

%% @private
decode_set(<<NumElems:32/big-unsigned, Rest0/binary>>) ->
    decode_elems(NumElems, Rest0, []).

encode_elem(Elem) when is_binary(Elem) ->
    ElemSize = byte_size(Elem),
    <<ElemSize:32/big-unsigned, Elem/binary>>.

decode_elems(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
decode_elems(
    N,
    <<ElemSize:32/big-unsigned, Elem:ElemSize/binary, Rest/binary>>,
    Acc
) when N > 0 ->
    decode_elems(N - 1, Rest, [Elem | Acc]).
