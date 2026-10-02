%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_hlc).

-include("bondy_hlc.hrl").

-moduledoc """
A Hybrid Logical Clock (HLC): the clock the oplog keys its events with
and the stream log stamps its records with.

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

## Scope

An instance is one clock; values from one instance are strictly
increasing in the order `now/1` and `update/2` return them, and only in
that order. Two callers minting from one instance in two processes get
distinct, increasing values, but nothing orders what they do with them
afterwards. The oplog keeps one instance per replica (per origin) shared
by every `bondy_oplog_instance` of that origin, so per-origin `{HLC, Seq}`
event keys are monotonic; a stream log keeps one instance per
(stream, node) log in the single process that writes it, so record stamps
are monotonic in append order (`bondy_log_record`).
""".

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

-doc """
Creates a new HLC initialised to zero. The first `now/1` call will produce
an HLC at least equal to the current wall-clock millisecond.
""".
-spec new() -> t().

new() ->
    new(0).

-doc """
Creates a new HLC initialised to `Seed`. Useful when restoring from
persisted state — `Seed` is typically the highest HLC the replica has
ever observed locally.
""".
-spec new(Seed :: hlc()) -> t().

new(Seed) when is_integer(Seed), Seed >= 0 ->
    Ref = atomics:new(1, [{signed, false}]),
    ok = atomics:put(Ref, 1, Seed),
    #?MODULE{atomic = Ref}.

-doc """
Returns the next HLC value, advancing the clock atomically. Strictly
greater than the previous value returned by `now/1` or `update/2`.
""".
-spec now(t()) -> hlc().

now(#?MODULE{atomic = Ref}) ->
    cas(Ref, fun local_next/2).

-doc """
Advances the local HLC to dominate `Peer`, then returns the new value.
Used on receipt of a remote event so subsequent local events are
guaranteed to sort after the peer event.
""".
-spec update(t(), Peer :: hlc()) -> hlc().

update(#?MODULE{atomic = Ref}, Peer) when is_integer(Peer), Peer >= 0 ->
    cas(Ref, fun(Old, Wall) -> peer_next(Old, Wall, Peer) end).

-doc """
Returns the current HLC without advancing it.
""".
-spec peek(t()) -> hlc().

peek(#?MODULE{atomic = Ref}) ->
    atomics:get(Ref, 1).

-doc """
Decodes a packed HLC into its `{Physical, Logical}` components.
""".
-spec decode(hlc()) -> {non_neg_integer(), non_neg_integer()}.

decode(HLC) when is_integer(HLC), HLC >= 0 ->
    {
        HLC bsr ?BONDY_HLC_LOGICAL_BITS,
        HLC band ?BONDY_HLC_LOGICAL_MASK
    }.

-doc """
Encodes a `{Physical, Logical}` pair into a packed HLC value.
""".
-spec encode(non_neg_integer(), non_neg_integer()) -> hlc().

encode(Physical, Logical) when
    is_integer(Physical),
    Physical >= 0,
    is_integer(Logical),
    Logical >= 0,
    Logical =< ?BONDY_HLC_LOGICAL_MAX
->
    (Physical bsl ?BONDY_HLC_LOGICAL_BITS) bor Logical.

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
bump_logical(Phys, Log) when Log < ?BONDY_HLC_LOGICAL_MAX ->
    encode(Phys, Log + 1);
bump_logical(Phys, _) ->
    encode(Phys + 1, 0).

%% @private
current_physical_ms() ->
    erlang:system_time(millisecond).
