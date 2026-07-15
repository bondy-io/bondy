%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_high_water).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-shard high-water HLC mark.

Encapsulates a single 64-bit `atomics` counter that tracks the highest
HLC of any `cell_apply` event the applier has materialised into a
projection cell on the owning shard. Maintained lock-free: writers do
a `max`-CAS loop; readers a single `get`.

## Semantics

- `0` means *no watermark yet*. Callers that need to distinguish the
  "no cell ever applied" case from "everything is at HLC 0" should
  read with `read/1`, which returns `{ok, no_watermark}` when the
  counter is still `0`.
- `advance/2` only writes when the proposed HLC is **strictly
  greater** than the current value. Concurrent advancers race on a
  CAS loop; the final value is the max of every advance that
  attempted to win.
- This is a *write-side* watermark only — the applier is the single
  writer of a shard's projection cells, but multiple applier processes
  exist (one per oplog instance) and the registry-owned
  `atomics:atomics_ref()` is shared with read-only consumers
  (catalogue freshness reporting, bootstrap finalise). The CAS loop
  is therefore not optional even in the single-writer case, because
  `finalize_catalogue_bootstrap/3` also advances from a separate
  process.

## Persistence

The watermark is **not** durable across instance restarts: on cold
start the counter is `0` and re-accumulates as new `cell_apply` events
flow. The watermark powers catalogue-freshness reporting and
bootstrap finalisation, both of which tolerate the lag (the worst
case is a stale `{ok, no_watermark}` reply until enough events have
been applied). Durable persistence is deliberately deferred — a future
extension may add it if a use case justifies the per-write cost.
""").

-export([new/0]).
-export([advance/2]).
-export([read/1]).
-export([read_raw/1]).

-type ref() :: atomics:atomics_ref().
-type hlc() :: non_neg_integer().

-export_type([ref/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Allocates a fresh single-counter atomics ref initialised to 0.

Called once per shard at `bondy_oplog_core_registry:register/4` time.
""".
-spec new() -> ref().

new() ->
    atomics:new(1, [{signed, false}]).

-doc """
Advances the watermark to `Hlc` if and only if `Hlc` is strictly
greater than the current value. Returns `ok` either way.

Concurrent advancers race on `atomics:compare_exchange/4`. A losing
CAS triggers a re-read and re-evaluation; the loop terminates when
either the CAS wins or the current value already exceeds `Hlc`.
""".
-spec advance(ref(), hlc()) -> ok.

advance(Ref, Hlc) when is_integer(Hlc), Hlc >= 0 ->
    advance_loop(Ref, Hlc).

-doc """
Returns the current watermark, distinguishing the "no watermark
recorded yet" case (`{ok, no_watermark}`) from the "watermark is
`Hlc`" case (`{ok, Hlc}`).
""".
-spec read(ref()) -> {ok, hlc()} | {ok, no_watermark}.

read(Ref) ->
    case atomics:get(Ref, 1) of
        0 -> {ok, no_watermark};
        Hlc -> {ok, Hlc}
    end.

-doc """
Returns the raw counter value without the no-watermark distinction.

Intended for hot paths that already treat `0` specially (e.g., the
max-CAS loop) and want to skip the wrapper tuple.
""".
-spec read_raw(ref()) -> hlc().

read_raw(Ref) ->
    atomics:get(Ref, 1).

%% =============================================================================
%% INTERNAL
%% =============================================================================

advance_loop(Ref, Hlc) ->
    Cur = atomics:get(Ref, 1),
    case Hlc > Cur of
        false ->
            ok;
        true ->
            case atomics:compare_exchange(Ref, 1, Cur, Hlc) of
                ok -> ok;
                _Other -> advance_loop(Ref, Hlc)
            end
    end.
