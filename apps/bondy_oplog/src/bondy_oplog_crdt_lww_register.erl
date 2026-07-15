%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_lww_register).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Last-writer-wins (LWW) register — native operation-based CRDT.

The first production fold reimplemented as a native `bondy_oplog_crdt`
on the commutative helper. It is the operation-based twin of the deprecated
`bondy_oplog_fold_lww_register`, with identical state, operations, and
conflict resolution — but expressed as a single-operation step
(`apply_op/3`) interpreted in key order, with **no** `merge_states`
join and **no** value delta. The materialised value is simply
`to_value(State)`.

## Why it is commutative

The state is the join (lub) of `(HLC, payload)` on a total order:
higher HLC wins; at equal HLC a deterministic tie-break on the encoded
payload decides (and `cleared` beats `set` at a tie). "Take the max" is
associative and commutative, so applying operations in any order yields
the same state — hence `order_independent() -> true`, which lets the
applier maintain the projection with the O(1) eager step.

## State

```
undefined
| {set, register_value(), hlc()}
| {cleared, hlc()}
```

- `undefined` — initial; no operation observed.
- `{set, V, H}` — value `V` written at HLC `H`.
- `{cleared, H}` — cleared at HLC `H`. Not terminal: a later-HLC `set`
  resurrects the register.

`register_value()` is **any term** supplied by the application (serialised
via `term_to_binary/1` in the state encoding); the caller never has to encode
it by hand.

## Operations

```
{set, register_value()}   %% HLC stamped from the event key
| clear                   %% HLC stamped from the event key
| {set, hlc(), register_value()}   %% explicit HLC (power users / replay)
| {clear, hlc()}
```

The short forms (`{set, V}`, `clear`) take the write HLC from the event key the
substrate already stamps, so the application never threads an HLC. The explicit
forms remain for callers that supply their own HLC (e.g. deterministic tests or
event replay).

## Conflict resolution

Higher HLC wins regardless of operation type. At equal HLC: two `set`s
resolve to the larger value by Erlang term order; `set` vs `clear` resolves to
`cleared`. Deterministic on every replica.

## Encoding

```
undefined    -> <<0>>
{set, V, H}  -> <<1, H:64/big-unsigned, (term_to_binary(V))/binary>>
{cleared, H} -> <<2, H:64/big-unsigned>>
```
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
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative
-export([apply_op/3]).

-type register_value() :: term().
-type state() ::
    undefined
    | {set, register_value(), bondy_oplog_hlc:hlc()}
    | {cleared, bondy_oplog_hlc:hlc()}.
-type op() ::
    {set, register_value()}
    | clear
    | {set, bondy_oplog_hlc:hlc(), register_value()}
    | {clear, bondy_oplog_hlc:hlc()}.

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

-spec query(value, state()) -> undefined | register_value().

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative
%% =============================================================================

-doc """
Apply one LWW operation in key order. Higher HLC wins; ties resolve
deterministically.

The short operation forms (`{set, V}`, `clear`) take the write HLC from the
event `Key` (the dot the substrate stamps on append/replay); the explicit forms
(`{set, H, V}`, `{clear, H}`) carry their own HLC. Both normalise to the same
explicit clauses below, so resolution is identical.
""".
-spec apply_op(state(), op(), bondy_oplog_event:event_key()) -> state().

%% Short forms — stamp the write HLC from the event key, then resolve.
apply_op(State, {set, V}, Key) ->
    apply_op(State, {set, bondy_oplog_event:key_hlc(Key), V}, Key);
apply_op(State, clear, Key) ->
    apply_op(State, {clear, bondy_oplog_event:key_hlc(Key)}, Key);
%% Explicit forms.
apply_op(undefined, {set, H, V}, _Key) ->
    {set, V, H};
apply_op(undefined, {clear, H}, _Key) ->
    {cleared, H};
%% set vs current set
apply_op({set, _OldV, OldH}, {set, H, V}, _Key) when H > OldH ->
    {set, V, H};
apply_op({set, OldV, OldH} = S, {set, H, V}, _Key) when H == OldH ->
    %% Tie at same HLC — deterministic resolution on Erlang term order.
    case V > OldV of
        true -> {set, V, OldH};
        false -> S
    end;
apply_op({set, _, _} = S, {set, _, _}, _Key) ->
    %% Older HLC; rejected.
    S;
%% set vs incoming clear
apply_op({set, _OldV, OldH}, {clear, H}, _Key) when H > OldH ->
    {cleared, H};
apply_op({set, _OldV, OldH}, {clear, H}, _Key) when H == OldH ->
    %% Tie — cleared deterministically wins.
    {cleared, OldH};
apply_op({set, _, _} = S, {clear, _}, _Key) ->
    %% Older clear; rejected.
    S;
%% cleared vs incoming set
apply_op({cleared, OldH}, {set, H, V}, _Key) when H > OldH ->
    %% Later-HLC set resurrects the register (LWW: latest wins).
    {set, V, H};
apply_op({cleared, OldH} = S, {set, H, _}, _Key) when H =< OldH ->
    %% Older or tied set; cleared retains (cleared wins at tie).
    S;
%% cleared vs incoming clear
apply_op({cleared, OldH}, {clear, H}, _Key) ->
    {cleared, erlang:max(OldH, H)}.

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> undefined | register_value().

to_value(undefined) -> undefined;
to_value({set, V, _H}) -> V;
to_value({cleared, _H}) -> undefined.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc(undefined) -> 0;
hlc({set, _, H}) -> H;
hlc({cleared, H}) -> H.

-spec gc_threshold(state()) -> bondy_oplog_hlc:hlc() | undefined.

gc_threshold(undefined) -> undefined;
gc_threshold({set, _, H}) -> H;
gc_threshold({cleared, H}) -> H.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    false.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-spec encode_state(state()) -> binary().

encode_state(undefined) ->
    <<0>>;
encode_state({set, V, H}) when is_integer(H) ->
    %% V is an arbitrary term; term_to_binary/1 occupies the tail (no length
    %% prefix needed), so decode reads it back with binary_to_term/1.
    <<1, H:64/big-unsigned, (term_to_binary(V))/binary>>;
encode_state({cleared, H}) when is_integer(H) ->
    <<2, H:64/big-unsigned>>.

-spec decode_state(binary()) -> state().

decode_state(<<0>>) ->
    undefined;
decode_state(<<1, H:64/big-unsigned, VBin/binary>>) ->
    {set, binary_to_term(VBin), H};
decode_state(<<2, H:64/big-unsigned>>) ->
    {cleared, H}.
