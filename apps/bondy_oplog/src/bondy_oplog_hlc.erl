%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_hlc).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
A Hybrid Logical Clock (HLC) for the MST event-store replication layer.

An HLC produces a strictly monotonic 64-bit integer that closely tracks
wall-clock time and never regresses within a replica, even across:

- backwards jumps of the system clock,
- repeated calls within the same millisecond,
- receipt of events from peers whose physical clock is ahead of ours.

## Encoding

The HLC is packed into a single non-negative integer:

```
| 48 bits physical (ms since UNIX epoch) | 16 bits logical |
```

Two consequences:

- HLCs compare with the standard integer order (`<`, `=<`, `>`).
- The physical component runs out around year 10889 — comfortable.
- The logical component overflows after 65 535 events generated within
  the same physical millisecond *without* the wall clock advancing. We
  treat overflow defensively by clamping logical at the maximum and
  advancing the physical component by one — the next call still produces
  a strictly larger HLC.

## Concurrency

A clock value is held in an `atomics` array and updated with
`compare_exchange/4`. `now/1` and `update/2` are wait-free for the
common case (no contention) and lock-free under contention.

## Origin scope

An HLC instance is **per replica** (per Origin), not per CRDT instance.
Multiple `bondy_oplog_instance` processes that share the
same Origin must share the same HLC instance to preserve per-origin
monotonicity of `{HLC, Seq}` event keys.
""").

-record(?MODULE, {
    atomic :: atomics:atomics_ref()
}).

-type t() :: #?MODULE{}.
-type hlc() :: non_neg_integer().

-export_type([t/0]).
-export_type([hlc/0]).

-export([new/0]).
-export([new/1]).
-export([now/1]).
-export([peek/1]).
-export([update/2]).
-export([decode/1]).
-export([encode/2]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Creates a new HLC initialised to zero. The first `now/1` call will produce
an HLC at least equal to the current wall-clock millisecond.
""").
-spec new() -> t().

new() ->
    new(0).

?DOC("""
Creates a new HLC initialised to `Seed`. Useful when restoring from
persisted state — `Seed` is typically the highest HLC the replica has
ever observed locally.
""").
-spec new(Seed :: hlc()) -> t().

new(Seed) when is_integer(Seed), Seed >= 0 ->
    Ref = atomics:new(1, [{signed, false}]),
    ok = atomics:put(Ref, 1, Seed),
    #?MODULE{atomic = Ref}.

?DOC("""
Returns the next HLC value, advancing the clock atomically. Strictly
greater than the previous value returned by `now/1` or `update/2`.
""").
-spec now(t()) -> hlc().

now(#?MODULE{atomic = Ref}) ->
    cas(Ref, fun local_next/2).

?DOC("""
Advances the local HLC to dominate `Peer`, then returns the new value.
Used on receipt of a remote event so subsequent local events are
guaranteed to sort after the peer event.
""").
-spec update(t(), Peer :: hlc()) -> hlc().

update(#?MODULE{atomic = Ref}, Peer) when is_integer(Peer), Peer >= 0 ->
    cas(Ref, fun(Old, Wall) -> peer_next(Old, Wall, Peer) end).

?DOC("""
Returns the current HLC without advancing it.
""").
-spec peek(t()) -> hlc().

peek(#?MODULE{atomic = Ref}) ->
    atomics:get(Ref, 1).

?DOC("""
Decodes a packed HLC into its `{Physical, Logical}` components.
""").
-spec decode(hlc()) -> {non_neg_integer(), non_neg_integer()}.

decode(HLC) when is_integer(HLC), HLC >= 0 ->
    {
        HLC bsr ?BONDY_OPLOG_HLC_LOGICAL_BITS,
        HLC band ?BONDY_OPLOG_HLC_LOGICAL_MASK
    }.

?DOC("""
Encodes a `{Physical, Logical}` pair into a packed HLC value.
""").
-spec encode(non_neg_integer(), non_neg_integer()) -> hlc().

encode(Physical, Logical) when
    is_integer(Physical),
    Physical >= 0,
    is_integer(Logical),
    Logical >= 0,
    Logical =< ?BONDY_OPLOG_HLC_LOGICAL_MAX
->
    (Physical bsl ?BONDY_OPLOG_HLC_LOGICAL_BITS) bor Logical.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Generic CAS loop. `Step` is `fun(OldHLC, WallMs) -> NewHLC`.
cas(Ref, Step) ->
    Old = atomics:get(Ref, 1),
    Wall = current_physical_ms(),
    New = Step(Old, Wall),
    case atomics:compare_exchange(Ref, 1, Old, New) of
        ok ->
            New;
        _ ->
            cas(Ref, Step)
    end.

%% @private
%% Local tick: pick the larger of OldPhys and Wall; bump logical when the
%% physical did not advance, otherwise reset logical to zero.
local_next(Old, Wall) ->
    {OldPhys, OldLog} = decode(Old),
    case Wall > OldPhys of
        true ->
            encode(Wall, 0);
        false ->
            bump_logical(OldPhys, OldLog)
    end.

%% @private
%% Peer update: dominate both Old and Peer using the standard HLC merge.
peer_next(Old, Wall, Peer) ->
    {OldPhys, OldLog} = decode(Old),
    {PeerPhys, PeerLog} = decode(Peer),
    Phys = max(OldPhys, max(Wall, PeerPhys)),
    if
        Phys =:= OldPhys andalso Phys =:= PeerPhys ->
            bump_logical(Phys, max(OldLog, PeerLog));
        Phys =:= OldPhys ->
            bump_logical(Phys, OldLog);
        Phys =:= PeerPhys ->
            bump_logical(Phys, PeerLog);
        true ->
            encode(Phys, 0)
    end.

%% @private
%% Increment the logical counter, advancing physical on overflow so that
%% the result still strictly dominates `(Phys, Log)`.
bump_logical(Phys, Log) when Log < ?BONDY_OPLOG_HLC_LOGICAL_MAX ->
    encode(Phys, Log + 1);
bump_logical(Phys, _) ->
    encode(Phys + 1, 0).

%% @private
current_physical_ms() ->
    erlang:system_time(millisecond).
