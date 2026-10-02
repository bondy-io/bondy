%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_owned_reading).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-moduledoc """
The latest reading of a quantity measured by the **one node named in the cell
key** — native operation-based CRDT.

A reading is `{Stamp, Count}`. The owner is meant to take the stamp after
changing the quantity and before reading it, from a clock that only moves
forward, so that a later stamp carries a later measurement. The value is the
`Count` of the highest reading under Erlang term order, whichever origin wrote
it. Keeping the maximum is commutative, associative and idempotent, so a
replica's value does not depend on delivery order or duplicates
(`bondy_oplog_crdt_owned_reading_proper_test`'s
`prop_interpret_is_order_and_duplicate_independent/0`).

A reading replaces the one before it and is never combined with another
origin's, so an owner that starts writing under a new origin corrects the
value by writing a new reading, not by arithmetic on the old ones.

## State

```
#{readings := #{Origin :: binary() => {Stamp :: non_neg_integer(),
                                       Count :: integer()}},
  hlc := hlc()}
```

One entry per origin that wrote the cell, holding the highest reading it
wrote, so the state is bounded by the number of origins
(`prop_state_size_is_independent_of_writes/0`).

## Operation

```
{set, {Stamp :: non_neg_integer(), Count :: integer()}}
```

Origin and HLC come from the event key.

## Licence to reap

Naming this module as a table's carrier asserts that the table's cells are
single-writer and scoped to the owner's lifetime, so a retired origin's
readings are statements about a writer that no longer exists. `reap_origins/2`
drops them outright; the value becomes the highest reading among the
survivors, or `0` when none survive
(`prop_reap_equals_building_from_the_survivors/0`). `stabilize/2` discards a
cell whose value is `0` once it is causally stable.
""".

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
%% optional callback
-export([reap_origins/2]).

-type origin() :: binary().
-type reading() :: {Stamp :: non_neg_integer(), Count :: integer()}.
-type state() :: #{
    readings := #{origin() => reading()},
    hlc := bondy_connect_hlc:hlc()
}.
-type op() :: {set, reading()}.

-export_type([state/0, op/0, reading/0]).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

-spec causal_tier() -> tier_0.

causal_tier() ->
    tier_0.

-spec init() -> state().

init() ->
    #{readings => #{}, hlc => 0}.

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
Keeps, for the key's origin, the higher of its current reading and the new
one, and advances the state's HLC to the key's. `Key` is the event dot.
""".
-spec apply_op(state(), op(), bondy_oplog_event:event_key()) -> state().

apply_op(
    #{readings := R0, hlc := H0} = S, {set, {Stamp, Count} = New}, Key
) when
    is_integer(Stamp), Stamp >= 0, is_integer(Count)
->
    Origin = bondy_oplog_event:key_origin(Key),
    R1 =
        case R0 of
            #{Origin := Old} when Old >= New -> R0;
            #{} -> R0#{Origin => New}
        end,
    S#{readings := R1, hlc := erlang:max(H0, bondy_oplog_event:key_hlc(Key))}.

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> integer().

to_value(State) ->
    case top(State) of
        undefined -> 0;
        {_Stamp, Count} -> Count
    end.

-spec hlc(state()) -> bondy_connect_hlc:hlc().

hlc(#{hlc := H}) -> H.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    false.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-doc """
`discard` once the value is `0` and every constituent operation is strictly
below the stability point; a non-zero value is kept at any stability point.
""".
-spec stabilize(bondy_connect_hlc:hlc(), state()) -> keep | discard.

stabilize(StableHlc, #{hlc := Hlc} = State) when Hlc < StableHlc ->
    case to_value(State) of
        0 -> discard;
        _ -> keep
    end;
stabilize(_StableHlc, _State) ->
    keep.

-doc """
The single operation that rebuilds a state with the same value from bottom:
a `{set, _}` of the highest reading. `undefined` for bottom.
`bondy_oplog_crdt_nested_core:stabilize_fold/2` folds each origin's run
separately, so the rebuilt state keeps that origin's entry.
""".
-spec state_to_op(state()) -> op() | undefined.

state_to_op(State) ->
    case top(State) of
        undefined -> undefined;
        Reading -> {set, Reading}
    end.

-spec encode_state(state()) -> binary().

encode_state(#{readings := R, hlc := H}) ->
    Entries = lists:sort(maps:to_list(R)),
    EntriesBin = iolist_to_binary([encode_entry(O, T) || {O, T} <- Entries]),
    <<H:64/big-unsigned, (length(Entries)):32/big-unsigned, EntriesBin/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<H:64/big-unsigned, N:32/big-unsigned, Rest0/binary>>) ->
    {Entries, <<>>} = decode_entries(N, Rest0, []),
    #{readings => maps:from_list(Entries), hlc => H}.

%% =============================================================================
%% reap
%% =============================================================================

-doc """
Drops the retired origins' readings, returning the origins actually removed
(sorted). `{State, []}` when none of `Retired` wrote this cell, so
`bondy_oplog_cell_utils:reap/4` writes nothing for an unmatched cell.
""".
-spec reap_origins(state(), [bondy_oplog_origin:t()]) ->
    {state(), [bondy_oplog_origin:t()]}.

reap_origins(#{readings := R} = State, Retired) ->
    case [O || O <- Retired, maps:is_key(O, R)] of
        [] ->
            {State, []};
        Hit ->
            {State#{readings := maps:without(Hit, R)}, lists:usort(Hit)}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

top(#{readings := R}) ->
    maps:fold(
        fun
            (_O, Reading, undefined) -> Reading;
            (_O, Reading, Acc) -> erlang:max(Reading, Acc)
        end,
        undefined,
        R
    ).

encode_entry(Origin, {Stamp, Count}) when
    is_binary(Origin), is_integer(Stamp), Stamp >= 0, is_integer(Count)
->
    <<
        (byte_size(Origin)):16/big-unsigned,
        Origin/binary,
        Stamp:64/big-unsigned,
        Count:64/big-signed
    >>.

decode_entries(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
decode_entries(
    N,
    <<Size:16/big-unsigned, Origin:Size/binary, Stamp:64/big-unsigned,
        Count:64/big-signed, Rest/binary>>,
    Acc
) when N > 0 ->
    decode_entries(N - 1, Rest, [{Origin, {Stamp, Count}} | Acc]).
