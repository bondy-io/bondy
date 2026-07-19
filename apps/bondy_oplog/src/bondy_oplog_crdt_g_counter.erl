%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_g_counter).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Grow-only counter (G-Counter) — native operation-based CRDT.

The op-based twin of the deprecated `bondy_oplog_fold_g_counter`, with
**identical state, encoding, and semantics** — but expressed as a single
operation step (`apply_op/3`) with no `merge_states` join and no value
delta. The materialised value is `to_value(State)`.

A monotone integer counter that only accepts non-negative increments;
the projected value is the sum across all observed Origins.

## State (byte-identical to the deprecated fold)

```
#{counters := #{Origin :: binary() => {Count :: non_neg_integer(),
                                       MaxSeq :: non_neg_integer()}},
  hlc := hlc()}
```

Each Origin contributes a `{Count, MaxSeq}` pair; events with
`Seq =< MaxSeq` for an Origin are duplicates.

## Operation

```
{inc, Delta :: non_neg_integer()}
```

Origin, Seq and HLC come from the event key (the dot), not the payload.
A negative delta crashes loudly at the guard (the applier catches it).

## Order independence

`order_independent() -> true` holds **under the substrate's causal
(per-Origin FIFO) delivery**: `interpret_cog/2` sorts a cell's events
into canonical `{hlc, origin, seq}` order before folding, which restores
each Origin's Seq order, and the eager `apply_op/3` step rides the same
causal arrival. It is NOT commutative over arbitrary (causality-violating)
permutations — the per-Origin `MaxSeq` dedup is Seq-order-sensitive — so
this type is order-independent in exactly the sense the kernel needs (eager
≡ sorted-group), not over all permutations.

## Encoding

Byte-identical to the deprecated fold (counter entries sorted by Origin),
so a table can switch from the fold to this module with no data migration.
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
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative
-export([apply_op/3]).

-type origin() :: binary().
-type counter() :: {non_neg_integer(), non_neg_integer()}.
-type state() :: #{
    counters := #{origin() => counter()},
    hlc := bondy_oplog_hlc:hlc()
}.
-type op() :: {inc, non_neg_integer()}.

-export_type([state/0, op/0]).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

-spec causal_tier() -> tier_0.

causal_tier() ->
    tier_0.

-spec init() -> state().

init() ->
    #{counters => #{}, hlc => 0}.

-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

-spec query(value, state()) -> non_neg_integer().

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative
%% =============================================================================

-doc """
Apply one `{inc, Delta}` operation in key order. The per-Origin
`{Count, MaxSeq}` accumulates non-negative deltas; an event with
`Seq =< MaxSeq` for its Origin is a duplicate (HLC bump only). `Key` is
the event dot, carrying Origin/Seq/HLC.
""".
-spec apply_op(state(), op(), bondy_oplog_event:event_key()) -> state().

apply_op(#{counters := C0, hlc := H0} = S, {inc, Delta}, Key) when
    is_integer(Delta), Delta >= 0
->
    Origin = bondy_oplog_event:key_origin(Key),
    EventSeq = bondy_oplog_event:key_seq(Key),
    EventHlc = bondy_oplog_event:key_hlc(Key),
    {Count, MaxSeq} = maps:get(Origin, C0, {0, 0}),
    H1 = erlang:max(H0, EventHlc),
    case EventSeq > MaxSeq of
        true ->
            C1 = C0#{Origin => {Count + Delta, EventSeq}},
            S#{counters := C1, hlc := H1};
        false ->
            S#{hlc := H1}
    end.

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> non_neg_integer().

to_value(#{counters := C}) ->
    maps:fold(fun(_O, {Count, _S}, Acc) -> Acc + Count end, 0, C).

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc(#{hlc := H}) -> H.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    false.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-spec encode_state(state()) -> binary().

encode_state(#{counters := C, hlc := H}) ->
    Entries = lists:sort(maps:to_list(C)),
    NumOrigins = length(Entries),
    EntriesBin = iolist_to_binary([encode_entry(O, T) || {O, T} <- Entries]),
    <<H:64/big-unsigned, NumOrigins:32/big-unsigned, EntriesBin/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<H:64/big-unsigned, NumOrigins:32/big-unsigned, Rest0/binary>>) ->
    {Entries, <<>>} = decode_entries(NumOrigins, Rest0, []),
    #{counters => maps:from_list(Entries), hlc => H}.

%% =============================================================================
%% INTERNAL
%% =============================================================================

encode_entry(Origin, {Count, MaxSeq}) when
    is_binary(Origin),
    is_integer(Count),
    Count >= 0,
    is_integer(MaxSeq),
    MaxSeq >= 0
->
    OriginSize = byte_size(Origin),
    <<OriginSize:16/big-unsigned, Origin/binary, Count:64/big-unsigned,
        MaxSeq:64/big-unsigned>>.

decode_entries(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
decode_entries(
    N,
    <<OriginSize:16/big-unsigned, Origin:OriginSize/binary,
        Count:64/big-unsigned, MaxSeq:64/big-unsigned, Rest/binary>>,
    Acc
) when N > 0 ->
    decode_entries(N - 1, Rest, [{Origin, {Count, MaxSeq}} | Acc]).
