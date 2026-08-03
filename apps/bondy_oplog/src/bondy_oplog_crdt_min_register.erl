%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_min_register).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Min-Register — native operation-based CRDT.

The op-based twin of the deprecated `bondy_oplog_fold_min_register`, with
**identical state, encoding, and semantics** — expressed as a single
operation step (`apply_op/3`), no `merge_states`, no value delta.

An integer register whose value is the **minimum** of every value ever
written. `min` (for the value) and `max` (for the HLC) are commutative,
associative and idempotent, so this type is order-independent over all
permutations. To "reset", allocate a fresh key.

## State (byte-identical to the deprecated fold)

```
undefined | {V :: integer(), MaxHlc :: hlc()}
```

## Operation

```
{set, V :: integer()}
```

The HLC is read from the event key. Encoding is byte-identical to the
fold, so a table can switch with no data migration.
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
-export([state_to_op/1]).
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative
-export([apply_op/3]).

-type state() :: undefined | {integer(), bondy_oplog_hlc:hlc()}.
-type op() :: {set, integer()}.

-export_type([state/0, op/0]).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

-spec causal_tier() -> tier_0.

causal_tier() ->
    tier_0.

-spec init() -> state().

init() ->
    undefined.

-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

-spec query(value, state()) -> undefined | integer().

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative
%% =============================================================================

-doc """
Apply one `{set, V}` in key order — keep the smaller value and the larger
HLC. `Key` is the event dot (only its HLC is used).
""".
-spec apply_op(state(), op(), bondy_oplog_event:event_key()) -> state().

apply_op(undefined, {set, V}, Key) when is_integer(V) ->
    {V, bondy_oplog_event:key_hlc(Key)};
apply_op({Old, OldH}, {set, V}, Key) when is_integer(V) ->
    {erlang:min(Old, V), erlang:max(OldH, bondy_oplog_event:key_hlc(Key))}.

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> undefined | integer().

to_value(undefined) -> undefined;
to_value({V, _H}) -> V.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc(undefined) -> 0;
hlc({_V, H}) -> H.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    false.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-doc """
The single operation that rebuilds an equivalent register from bottom: a
`{set, _}` of the running minimum. Used by causal-stabilization folding
(`bondy_oplog_crdt_nested_core:stabilize_fold/2`) — `min` is associative,
commutative and idempotent, so the collapse is exact. `undefined` (bottom,
nothing ever written) has no representing op.
""".
-spec state_to_op(state()) -> op() | undefined.

state_to_op(undefined) ->
    undefined;
state_to_op({V, _H}) ->
    {set, V}.

-spec encode_state(state()) -> binary().

encode_state(undefined) ->
    <<0>>;
encode_state({V, H}) when is_integer(V), is_integer(H) ->
    <<1, V:64/big-signed, H:64/big-unsigned>>.

-spec decode_state(binary()) -> state().

decode_state(<<0>>) ->
    undefined;
decode_state(<<1, V:64/big-signed, H:64/big-unsigned>>) ->
    {V, H}.
