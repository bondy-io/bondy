%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_g_set).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Grow-Only Set (G-Set) — native operation-based CRDT.

The op-based twin of the deprecated `bondy_oplog_fold_g_set`, with
**identical state, encoding, and semantics** — expressed as a single
operation step (`apply_op/3`), no `merge_states`, no value delta.

A monotone `add`-only set; elements are added but never removed.
Concurrent adds converge because `ordsets:union/2` is commutative,
associative and idempotent — so this type IS order-independent over all
permutations (no per-Origin Seq dedup). For observed-remove semantics use
the native `bondy_oplog_crdt_aw_map` (tier_2).

## State (byte-identical to the deprecated fold)

```
{Set :: ordsets:ordset(binary()), MaxHlc :: hlc()}
```

## Operation

```
{add, Elem :: binary()}
```

The HLC is read from the event key. `value_equals_state/0 -> true`: the
substrate omits the value column and treats the state bytes as the value
bytes on HEAD reads. Encoding is byte-identical to the fold, so a table
can switch with no data migration.
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
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative
-export([apply_op/3]).

-type elem() :: binary().
-type set_t() :: ordsets:ordset(elem()).
-type state() :: {set_t(), bondy_oplog_hlc:hlc()}.
-type op() :: {add, elem()}.

-export_type([state/0, op/0, elem/0]).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

-spec causal_tier() -> tier_0.

causal_tier() ->
    tier_0.

-spec init() -> state().

init() ->
    {[], 0}.

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
Add one element in key order — `ordsets:add_element/2` (idempotent),
absorbing the event's HLC via `max`. `Key` is the event dot (only its HLC
is used).
""".
-spec apply_op(state(), op(), bondy_oplog_event:event_key()) -> state().

apply_op({Set, H0}, {add, Elem}, Key) when is_binary(Elem) ->
    H = bondy_oplog_event:key_hlc(Key),
    {ordsets:add_element(Elem, Set), erlang:max(H0, H)}.

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> set_t().

to_value({Set, _H}) -> Set.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_S, H}) -> H.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    true.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-spec batchable() -> boolean().

batchable() ->
    true.

-spec encode_state(state()) -> binary().

encode_state({Set, H}) when is_integer(H) ->
    NumElems = length(Set),
    ElemsBin = iolist_to_binary([encode_elem(E) || E <- Set]),
    <<H:64/big-unsigned, NumElems:32/big-unsigned, ElemsBin/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<H:64/big-unsigned, NumElems:32/big-unsigned, Rest0/binary>>) ->
    {Elems, <<>>} = decode_elems(NumElems, Rest0, []),
    {Elems, H}.

%% =============================================================================
%% INTERNAL
%% =============================================================================

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
