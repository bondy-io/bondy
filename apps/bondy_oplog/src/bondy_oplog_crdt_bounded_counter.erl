%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_bounded_counter).

-behaviour(bondy_oplog_crdt).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Zero-bounded counter — the first **non-commutative** operation-based CRDT.

A counter that increments and decrements but is **clamped at zero**: it
never reports a negative value. This is Canteen's `zero_bounded_counter`,
and it is the flagship demonstration that the operation-based approach
unlocks CRDTs whose concurrent operations do **not** commute — something
the state-based folds could never express.

It implements `bondy_oplog_crdt` directly (it is **not** a
`bondy_oplog_crdt_commutative`) and declares `order_independent() ->
false`, so the applier re-interprets the cell's live Concurrent
Operation Group on every write rather than folding ops one at a time.

## Why it is non-commutative

The clamp makes per-operation, arrival-order application order-dependent.
Starting from `0` with a concurrent `{inc, 1}` and `{dec, 1}`:

```
[dec, inc] : max(0, 0-1)=0 -> 0+1 = 1
[inc, dec] : 0+1=1         -> max(0, 1-1) = 0
```

Two arrival orders, two answers (`1` vs `0`). Folding ops incrementally
cannot converge. The COG-Interpreter does.

## Deterministic group resolution

`interpret_cog/2` resolves a whole group deterministically as
**increments-before-decrements**, equivalently:

```
V1 = max(0, V0 + sum(increments) - sum(decrements))
```

applied to the baseline `V0` (the stable checkpoint). This is the
*maximally permissive* deterministic rule — it gives decrements the
largest possible budget, so it never rejects a decrement that some
ordering could have honoured — and it is a pure function of the event
*set*, identical on every replica. For the example above both replicas
get `max(0, 0 + 1 - 1) = 0`.

## State

```
{Value :: non_neg_integer(), Hlc :: hlc()}
```

`Value` is the clamped counter; `Hlc` is the highest HLC absorbed into
it. `init/0` is `{0, 0}`.

## Idempotency

The op-set is keyed by the dot `{hlc, origin, seq}` and deduplicated by
the MST, so each operation appears in a group at most once;
`interpret_cog/2` sums each event exactly once. No dot-set or version
vector is needed in the state — hence `causal_tier/0 = tier_0`.

## Clamp-at-stability (documented semantics)

The zero floor is enforced **at each stability boundary**, not over all
history. If a group drives the value to the floor by clamping away a
decrement "deficit", that deficit is intentionally **forgotten** once the
group folds into the checkpoint; later groups build on the clamped
baseline. This is the Canteen model (snapshot the stable prefix, then
interpret unstable groups on top) and matches the bounded-counter intent:
the invariant is "never observably negative", not "preserve unbounded
decrement debt across compactions".

## Operations

```
{inc, pos_integer()}   increment
{dec, pos_integer()}   decrement (clamped at the group boundary)
```

A catalogue cell wraps these as `{cell_apply, Bucket, Key, Op}`;
`interpret_cog/2` unwraps that. Malformed or unknown op shapes are
ignored (they leave `Value` unchanged) but still advance `Hlc` — the
whole group is absorbed.

## Encoding

```
{V, H} -> <<V:64/big-unsigned, H:64/big-unsigned>>
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
-export([encode_state/1]).
-export([decode_state/1]).
-export([value_equals_state/0]).
-export([order_independent/0]).

-type state() :: {non_neg_integer(), bondy_oplog_hlc:hlc()}.
-type op() :: {inc, pos_integer()} | {dec, pos_integer()}.

-export_type([state/0, op/0]).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

-spec causal_tier() -> tier_0.

causal_tier() ->
    tier_0.

-spec init() -> state().

init() ->
    {0, 0}.

-doc """
Interpret a Concurrent Operation Group on top of the baseline state,
deterministically: net the group's increments and decrements onto the
baseline value and clamp at zero. Order-independent in the event set;
the clamp is applied once, at the group boundary.
""".
-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, {V0, H0}) when is_list(Events) ->
    {Delta, MaxH} = lists:foldl(
        fun(E, {D, H}) ->
            H1 = erlang:max(H, key_hlc(E)),
            D1 =
                case op_of(E) of
                    {inc, N} when is_integer(N), N > 0 -> D + N;
                    {dec, N} when is_integer(N), N > 0 -> D - N;
                    _ -> D
                end,
            {D1, H1}
        end,
        {0, H0},
        Events
    ),
    {erlang:max(0, V0 + Delta), MaxH}.

-spec query(value, state()) -> non_neg_integer().

query(value, {V, _H}) ->
    V.

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> non_neg_integer().

to_value({V, _H}) ->
    V.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_V, H}) ->
    H.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    false.

-spec order_independent() -> boolean().

%% The defining property: NON-commutative under incremental application.
order_independent() ->
    false.

-spec encode_state(state()) -> binary().

encode_state({V, H}) when is_integer(V), V >= 0, is_integer(H), H >= 0 ->
    <<V:64/big-unsigned, H:64/big-unsigned>>.

-spec decode_state(binary()) -> state().

decode_state(<<V:64/big-unsigned, H:64/big-unsigned>>) ->
    {V, H}.

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
%% Unwrap a catalogue `{cell_apply, Bucket, Key, Op}`; pass any other op
%% through. Kept local so this non-commutative CRDT carries no dependency
%% on the commutative helper.
op_of(Event) ->
    case bondy_oplog_event:op(Event) of
        {cell_apply, _Bucket, _Key, Op} -> Op;
        Op -> Op
    end.

%% @private
key_hlc(Event) ->
    bondy_oplog_event:key_hlc(bondy_oplog_event:key(Event)).
