%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_index_entry).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Native operation-based CRDT backing one cell of the secondary-index
keyspace — the op-based twin of the deprecated
`bondy_oplog_fold_index_entry`.

Each `(Term, PrimaryKey)` composite key (see `bondy_oplog_index_key`) is a
cell whose value is the index entry's denormalised columns (or `<<>>` for
a pointer-only index). It is an **LWW register over presence** keyed by the
*primary* HLC carried in the operation payload — not the secondary writer's
own WAL HLC, which is why the HLC is embedded in the operation rather than
read from the event dot (`Key`, which `apply_op/3` ignores).

It is the same conflict-resolution algebra the fold used, re-expressed as a
single-operation step: `apply_op/3` is exactly a merge against a total
order, which is commutative/associative/idempotent — so it is tier_0 and
`order_independent() -> true`, and a permutation of operations yields the
same state (the property the secondary index needs for out-of-order
cross-shard delivery of a `put`/`remove` for the same `(Term, PK)` from a
local drain vs a peer replay).

## State

```
{Presence :: live | dead, Columns :: binary(), Hlc :: hlc()}
```

`init/0` is `{dead, <<>>, 0}` — absent. `live` carries the projected
columns; `dead` is a tombstone (a retracted entry whose term the primary
value no longer yields).

## Operations

```
{put, Columns :: binary(), Hlc} | {remove, Hlc}
```

A `put` is the state `{live, Columns, Hlc}`; a `remove` is
`{dead, <<>>, Hlc}`. `apply_op/3` merges that against the current state.

### LWW order and the equal-HLC tie-break

States are ordered by `{Hlc, presence_rank, Columns}` under standard term
order, where `live` ranks above `dead`. Higher HLC always wins; the
rank/columns tie-break only matters at equal HLC and exists solely to keep
the merge a deterministic total order. By construction a single cell never
receives a genuine `put` and `remove` at the same primary HLC (each
primary value-version has a distinct, monotone HLC and emits at most one
operation per term), so the tie-break is for robustness, not a modelled
case. A bare `>=` is not commutative for a conflicting `put`/`remove` at
equal HLC, so the merge-against-a-total-order construction is used instead —
same intent, provably order-independent.

## value_equals_state/0 -> true

The substrate omits the value column and treats the state bytes as the
value bytes on HEAD reads; the reader decodes the state and projects via
`to_value/1` (`{live, Cols, _} -> Cols`, `{dead, _, _} -> undefined`, the
latter filtered by the substrate's existing `undefined` handling).

## Encoding (byte-identical to the retired fold)

```
state {P, Cols, H} -> <<Rank:8, H:64, ColsSize:32, Cols/binary>>
```

`Rank` is `1` for `live`, `0` for `dead`. Identical bytes to
`bondy_oplog_fold_index_entry:encode_state/1`, so existing durable index
cells decode unchanged after the cutover (a zero-migration swap).
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

-type presence() :: live | dead.
-type columns() :: binary().
-type state() :: {presence(), columns(), bondy_oplog_hlc:hlc()}.
-type op() ::
    {put, columns(), bondy_oplog_hlc:hlc()}
    | {remove, bondy_oplog_hlc:hlc()}.

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
Apply one `{put, Cols, H}` / `{remove, H}` operation: merge the operation's
state against the current state on the LWW total order. `Key` (the event
dot) is unused — the index entry carries its own primary HLC in the
operation.
""".
-spec apply_op(state(), op(), bondy_oplog_event:event_key()) -> state().

apply_op(State, {put, Cols, H}, _Key) when is_binary(Cols), is_integer(H) ->
    merge(State, {live, Cols, H});
apply_op(State, {remove, H}, _Key) when is_integer(H) ->
    merge(State, {dead, <<>>, H}).

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> columns() | undefined.

to_value({live, Cols, _H}) -> Cols;
to_value({dead, _Cols, _H}) -> undefined.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_P, _C, H}) -> H.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    true.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-spec encode_state(state()) -> binary().

encode_state({Presence, Cols, H}) when is_binary(Cols), is_integer(H) ->
    ColsSize = byte_size(Cols),
    <<
        (rank(Presence)):8,
        H:64/big-unsigned,
        ColsSize:32/big-unsigned,
        Cols/binary
    >>.

-spec decode_state(binary()) -> state().

decode_state(
    <<R:8, H:64/big-unsigned, ColsSize:32/big-unsigned, Cols:ColsSize/binary>>
) ->
    {presence(R), Cols, H}.

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
%% The LWW merge: take the state with the greater sort key (HLC dominates,
%% then live > dead, then the columns bytes). Commutative/associative/
%% idempotent by construction.
merge(A, B) ->
    case sort_key(A) >= sort_key(B) of
        true -> A;
        false -> B
    end.

%% @private
%% Total order for the LWW merge: HLC dominates, then live > dead, then the
%% columns bytes. Equal sort keys imply identical states.
sort_key({Presence, Cols, H}) ->
    {H, rank(Presence), Cols}.

rank(live) -> 1;
rank(dead) -> 0.

presence(1) -> live;
presence(0) -> dead.
