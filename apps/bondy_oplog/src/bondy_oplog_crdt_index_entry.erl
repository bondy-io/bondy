%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_index_entry).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-moduledoc #{format => "text/markdown"}.
-moduledoc """
Native operation-based CRDT backing one cell of the secondary-index
keyspace.

Each `(Term, PrimaryKey)` composite key (see `bondy_oplog_index_key`) is a
cell whose value is the index entry's denormalised columns (or `<<>>` for
a pointer-only index). It is an **LWW register over presence** ordered by
the **index version** each operation carries: the primary shard's counter
value for the event that produced the op
(`bondy_oplog_cell_apply:next_index_version/1`). The version is in the
operation, not read from the event dot (`Key`, which `apply_op/3` ignores),
because the index has no events of its own.

The order is per primary shard. A table routes each primary key to one
primary shard for a given shard count, so every op on a cell comes from one
counter, and a later event in the shard's apply order carries a higher
version. The cell's HLC would not do:
an op derived from an older value can carry a higher HLC than the value the
primary holds now (`proofs/tla/IndexIntents_HlcOrder.cfg` finds the index
diverging from the primary under HLC order).

`apply_op/3` merges the operation's state against the current state on a
total order, so the type is tier_0 and `order_independent() -> true`: the
writer may apply a batch's ops in any order
(`bondy_oplog_crdt_index_entry_test:order_independent_test/0`).

## State

```
{Presence :: live | dead, Columns :: binary(), Version :: non_neg_integer()}
```

`init/0` is `{dead, <<>>, 0}` — absent. `live` carries the projected
columns; `dead` is a tombstone (a retracted entry whose term the primary
value no longer yields).

## Operations

```
{put, Columns :: binary(), Version} | {remove, Version}
```

A `put` is the state `{live, Columns, Version}`; a `remove` is
`{dead, <<>>, Version}`. `apply_op/3` merges that against the current state.

### Order and the equal-version tie-break

States are ordered by `{Version, presence_rank, Columns}` under standard term
order, where `live` ranks above `dead`. A higher version always wins. The
rank and columns only decide between two states of equal version, so the
merge stays a total order. A bare `>=` on the version alone is not
commutative for a `put` and a `remove` at an equal version.

## value_equals_state/0 -> true

The substrate omits the value column and treats the state bytes as the
value bytes on HEAD reads; the reader decodes the state and projects via
`to_value/1` (`{live, Cols, _} -> Cols`, `{dead, _, _} -> undefined`, the
latter filtered by the substrate's existing `undefined` handling).

`hlc/1`, the `bondy_oplog_crdt` projection seam's HLC slot, returns the
version: the frame header of an index cell holds its version.

## Encoding

```
state {P, Cols, V} -> <<Rank:8, V:64, ColsSize:32, Cols/binary>>
```

`Rank` is `1` for `live`, `0` for `dead`.
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
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative
-export([apply_op/3]).

-type presence() :: live | dead.
-type columns() :: binary().
-type version() :: non_neg_integer().
-type state() :: {presence(), columns(), version()}.
-type op() :: {put, columns(), version()} | {remove, version()}.

-export_type([state/0, op/0]).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

-spec causal_tier() -> tier_0.

causal_tier() ->
    tier_0.

-spec init() -> state().

init() ->
    {dead, <<>>, 0}.

-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

-spec query(value, state()) -> columns() | undefined.

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative
%% =============================================================================

-doc """
Apply one `{put, Cols, Version}` / `{remove, Version}` operation: merge the
operation's state against the current state on the LWW total order. `Key`
(the event dot) is unused.
""".
-spec apply_op(state(), op(), bondy_oplog_event:event_key()) -> state().

apply_op(State, {put, Cols, V}, _Key) when is_binary(Cols), is_integer(V) ->
    merge(State, {live, Cols, V});
apply_op(State, {remove, V}, _Key) when is_integer(V) ->
    merge(State, {dead, <<>>, V}).

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> columns() | undefined.

to_value({live, Cols, _H}) -> Cols;
to_value({dead, _Cols, _H}) -> undefined.

-spec hlc(state()) -> version().

hlc({_P, _C, V}) -> V.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    true.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-spec encode_state(state()) -> binary().

encode_state({Presence, Cols, V}) when is_binary(Cols), is_integer(V) ->
    ColsSize = byte_size(Cols),
    <<
        (rank(Presence)):8,
        V:64/big-unsigned,
        ColsSize:32/big-unsigned,
        Cols/binary
    >>.

-spec decode_state(binary()) -> state().

decode_state(
    <<R:8, V:64/big-unsigned, ColsSize:32/big-unsigned, Cols:ColsSize/binary>>
) ->
    {presence(R), Cols, V}.

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
merge(A, B) ->
    case sort_key(A) >= sort_key(B) of
        true -> A;
        false -> B
    end.

%% @private
sort_key({Presence, Cols, V}) ->
    {V, rank(Presence), Cols}.

rank(live) -> 1;
rank(dead) -> 0.

presence(1) -> live;
presence(0) -> dead.
