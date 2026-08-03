%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_pn_counter).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Positive-Negative counter (PN-Counter) — native operation-based CRDT.

The op-based twin of the deprecated `bondy_oplog_fold_pn_counter`, with
**identical state, encoding, and semantics** — expressed as a single
operation step (`apply_op/3`), no `merge_states`, no value delta.

An integer counter supporting concurrent `inc`/`dec` (a decrement is just
`{inc, -K}`); the projected value is `sum(Pos) - sum(Neg)` across Origins.

## State (byte-identical to the deprecated fold)

```
#{counters := #{Origin :: binary() => {Pos :: non_neg_integer(),
                                       Neg :: non_neg_integer(),
                                       MaxSeq :: non_neg_integer()}},
  hlc := hlc()}
```

## Operation

```
{inc, Delta :: integer()}
```

Origin, Seq and HLC come from the event key. See
`bondy_oplog_crdt_g_counter` for why `order_independent/0` holds under
causal delivery (the per-Origin `MaxSeq` dedup) rather than over all
permutations. Encoding is byte-identical to the fold, so a table can
switch with no data migration.
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
-export([stabilize/2]).
-export([state_to_op/1]).
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative
-export([apply_op/3]).

-type origin() :: binary().
-type counter() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}.
-type state() :: #{
    counters := #{origin() => counter()},
    hlc := bondy_oplog_hlc:hlc()
}.
-type op() :: {inc, integer()}.

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

-spec query(value, state()) -> integer().

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative
%% =============================================================================

-doc """
Apply one `{inc, Delta}` (Delta may be negative) in key order. A positive
delta accumulates into `Pos`, a negative into `Neg`; an event with
`Seq =< MaxSeq` for its Origin is a duplicate (HLC bump only). `Key` is
the event dot.
""".
-spec apply_op(state(), op(), bondy_oplog_event:event_key()) -> state().

apply_op(#{counters := C0, hlc := H0} = S, {inc, Delta}, Key) when
    is_integer(Delta)
->
    Origin = bondy_oplog_event:key_origin(Key),
    EventSeq = bondy_oplog_event:key_seq(Key),
    EventHlc = bondy_oplog_event:key_hlc(Key),
    {Pos, Neg, MaxSeq} = maps:get(Origin, C0, {0, 0, 0}),
    H1 = erlang:max(H0, EventHlc),
    case EventSeq > MaxSeq of
        true ->
            C1 =
                case Delta >= 0 of
                    true -> C0#{Origin => {Pos + Delta, Neg, EventSeq}};
                    false -> C0#{Origin => {Pos, Neg + abs(Delta), EventSeq}}
                end,
            S#{counters := C1, hlc := H1};
        false ->
            S#{hlc := H1}
    end.

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> integer().

to_value(#{counters := C}) ->
    maps:fold(fun(_O, {P, N, _S}, Acc) -> Acc + P - N end, 0, C).

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc(#{hlc := H}) -> H.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    false.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-doc """
Causal stabilization: `discard` once the counter's value is its own
algebraic zero (`sum(Pos) - sum(Neg) =:= 0`, the counter's bottom/identity
value — not a policy choice, true for any consumer) and every constituent
operation is strictly below the stability point. A non-zero value is data
and is kept at any stability point.
""".
-spec stabilize(bondy_oplog_hlc:hlc(), state()) -> keep | discard.

stabilize(StableHlc, #{hlc := Hlc} = State) when Hlc < StableHlc ->
    case to_value(State) of
        0 -> discard;
        _ -> keep
    end;
stabilize(_StableHlc, _State) ->
    keep.

-doc """
The single operation that rebuilds an equivalent counter from bottom: the
net delta. Used by causal-stabilization folding
(`bondy_oplog_crdt_nested_core:stabilize_fold/2`) to collapse an origin's
stable `{inc, _}` run into one op — `sum` is associative and commutative,
so the net is exact regardless of how the run interleaved with other
origins' operations.
""".
-spec state_to_op(state()) -> op().

state_to_op(State) ->
    {inc, to_value(State)}.

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

encode_entry(Origin, {Pos, Neg, MaxSeq}) when
    is_binary(Origin),
    is_integer(Pos),
    Pos >= 0,
    is_integer(Neg),
    Neg >= 0,
    is_integer(MaxSeq),
    MaxSeq >= 0
->
    OriginSize = byte_size(Origin),
    <<OriginSize:16/big-unsigned, Origin/binary, Pos:64/big-unsigned,
        Neg:64/big-unsigned, MaxSeq:64/big-unsigned>>.

decode_entries(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
decode_entries(
    N,
    <<OriginSize:16/big-unsigned, Origin:OriginSize/binary, Pos:64/big-unsigned,
        Neg:64/big-unsigned, MaxSeq:64/big-unsigned, Rest/binary>>,
    Acc
) when N > 0 ->
    decode_entries(N - 1, Rest, [{Origin, {Pos, Neg, MaxSeq}} | Acc]).
