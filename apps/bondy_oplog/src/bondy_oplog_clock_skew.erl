%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_clock_skew).

-moduledoc """
Detection of a peer whose physical clock runs ahead of ours.

## Why this only observes

The HLC merge (`bondy_oplog_hlc:peer_next/3`) takes
`max(OldPhys, max(Wall, PeerPhys))`, so a peer stamp far in the future drags
this replica's clock forward, and the clock never regresses. On a
last-writer-wins cell that is a write a later honest write cannot overwrite.

The obvious remedy -- clamp the merge so a peer cannot pull us past
`Wall + K` -- is **unsound**, and the project's own proofs say so.
`proofs/isabelle/Hlc.thy` proves

```
theorem peer_next_gt_peer: "peer < peer_next old wall peer"
```

the merge strictly dominates the peer's value. That theorem is what discharges
hypothesis **H3** (`hlc_respects_hb`), which `Oplog_Model.thy` *assumes* for
the stability theorem: if `f` happens-before `e` then `ev_hlc f < ev_hlc e`.
A clamp is exactly the statement "when the peer is too far ahead, do not
dominate it", which negates that theorem and removes the hypothesis the
stabilization argument rests on.

Rejecting the event instead is no better. An event's HLC is stamped once at
its origin (`bondy_oplog_instance:append/*` via `bondy_oplog_hlc:now/1`) and
travels with it unchanged; that is what lets every replica agree on order. A
rejection decided against *local* wall clock is not a decision every replica
makes identically, so replicas would disagree on the applied set. That breaks
convergence, which the threat model rates security-critical.

So this module changes nothing. It reads a value and reports. Because it
neither alters a timestamp nor drops an event, there is no invariant to
re-establish and `Hlc.thy` is untouched -- which is also why the check lives
here rather than inside `bondy_oplog_hlc`.

## What it is worth

The realistic trigger is not an attacker but a **misconfigured node**: NTP not
running, a VM restored from a snapshot, a container with a bad RTC. Today that
is silent and its effect is permanent. This makes it visible, which is the
part of the problem that can be solved soundly.

Only a peer running *ahead* is reported. A peer behind us is harmless here --
its writes simply lose last-writer-wins.

## Emission

The seat emits telemetry rather than raising an alarm directly.
`bondy_alarm_handler` de-duplicates an identical `{Id, Desc}`, but the call is
still a `gen_event:notify/2` per event, and a peer with a bad clock trips this
on *every* event it sends. A counter is wait-free and cannot flood; turning a
sustained non-zero rate into a page belongs in an alerting rule, or in a
periodic sweep that owns the alarm lifecycle. Putting `set_alarm/1` on a
per-event path would be the storm this is meant to report.
""".

-include("bondy_oplog.hrl").

%% The default is generous against NTP, which holds hosts within milliseconds,
%% and tight against the failure modes that matter -- a snapshot restore or a
%% timezone bug is hours or days out, not minutes.
-define(DEFAULT_MAX_SKEW_MS, timer:minutes(5)).

-export([check/1]).
-export([check/2]).
-export([max_skew_ms/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Configured tolerance, in milliseconds, before a peer stamp counts as ahead.
""".
-spec max_skew_ms() -> pos_integer().

max_skew_ms() ->
    application:get_env(
        bondy_oplog, peer_clock_max_skew_ms, ?DEFAULT_MAX_SKEW_MS
    ).

-doc """
Same as `check/2` using the configured tolerance and the current wall clock.
""".
-spec check(Hlc :: non_neg_integer()) -> ok | {ahead, pos_integer()}.

check(Hlc) ->
    check(Hlc, erlang:system_time(millisecond)).

-doc """
Reports whether a peer event's HLC is stamped further ahead of `WallMs` than
the configured tolerance allows.

Returns `{ahead, Millis}` with the amount by which the stamp exceeds
`WallMs` -- the raw distance, not the distance past the threshold, because
that is the number an operator needs to recognise the cause (a few hours
reads as a timezone bug; weeks reads as a snapshot restore).

Pure: it decides nothing and mutates nothing.
""".
-spec check(Hlc :: term(), WallMs :: term()) -> ok | {ahead, pos_integer()}.

check(Hlc, WallMs) when is_integer(Hlc), Hlc >= 0, is_integer(WallMs) ->
    %% The physical component is the high bits; the logical counter below it
    %% is a tie-break within a millisecond and carries no wall-clock meaning.
    Physical = Hlc bsr ?BONDY_OPLOG_HLC_LOGICAL_BITS,

    case Physical - WallMs of
        Ahead when Ahead > 0 ->
            case Ahead > max_skew_ms() of
                true -> {ahead, Ahead};
                false -> ok
            end;
        _ ->
            %% Behind, or equal. A peer behind us loses last-writer-wins on
            %% its own; it does not drag this replica's clock anywhere.
            ok
    end;

check(_, _) ->
    %% Total by design. This runs on the remote-event ingress path and its
    %% entire purpose is to observe, so an input it cannot interpret must
    %% cost the caller nothing. A `function_clause` here would turn a
    %% reporting mechanism into an outage on exactly the traffic it exists
    %% to watch -- a worse failure than the one being reported.
    ok.
