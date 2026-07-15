%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_db_overlay).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-shard overlay ETS structure for the read-side projection.

The overlay holds events that have been accepted into the WAL but have
not yet been promoted to the projection by the applier. Read paths
merge overlay events with the projection to provide read-your-writes
semantics for the consumer.

## Table

```erlang
ets:new(?MODULE, [
    ordered_set,
    public,
    {read_concurrency, true},
    {write_concurrency, true},
    {decentralized_counters, true}
])
```

This module returns the `tid()` from `new/0`; ownership and lifecycle
(publish-to-registry, teardown on shard restart) belong to the owning
process (`bondy_oplog_core`). The table is not named — naming would
require atom construction from `(NS, Shard)` and risks atom-table
exhaustion.

## Key shape

`{{Bucket, Key}, EventHlc, EventKey}` where:

- `{Bucket, Key}` — the substrate cell key composed of the storage-layer
  partition and the per-cell id. The composition is internal to this
  module; callers pass `Bucket` and `Key` as separate arguments.
- `EventHlc :: bondy_oplog_hlc:hlc()` — the event's HLC, lifted out so
  HLC-windowed match-specs can compare it without unpacking the
  `event_key()` record.
- `EventKey :: bondy_oplog_event:event_key()` — the full
  `{HLC, Origin, Seq}` triple. Used as the tie-breaker within the same
  cell's events at the same HLC so different replicas' events retain a
  deterministic order.

`ordered_set` semantics sort rows lexicographically by this tuple, so
`select/2` against a single `(Bucket, Key)` returns events in HLC order,
with the inner record-tag comparison being a no-op (always
`bondy_oplog_event_key`).

## Value

The full `#bondy_oplog_event{}` record. Stored verbatim — no decoding,
no projection — so the overlay is cheap to write and cheap to read.

## Eviction

`evict_to/3` is called by the applier post-projection-commit: it deletes
every overlay row whose `(EventHlc, EventKey)` pair is `=<` the applied
watermark, preserving rows that arrived after the batch was assembled.
""").

-export([new/0]).
-export([insert/4]).
-export([events_for/4]).
-export([events_for_window/5]).
-export([range/5]).
-export([range_window/5]).
-export([evict_to/3]).
-export([size/1]).
-export([delete/1]).

-export_type([tid/0]).
-export_type([bucket/0]).
-export_type([key/0]).

-type tid() :: ets:tid().
-type bucket() :: binary().
-type key() :: bondy_mst:key().
-type cell_key() :: binary().
-type after_hlc() :: bondy_oplog_hlc:hlc().

%% =============================================================================
%% API
%% =============================================================================

-spec new() -> tid().

new() ->
    ets:new(?MODULE, [
        ordered_set,
        public,
        {read_concurrency, true},
        {write_concurrency, true},
        {decentralized_counters, true}
    ]).

-spec insert(tid(), bucket(), cell_key(), bondy_oplog_event:t()) -> ok.

insert(Tab, Bucket, Key, Event) ->
    EventKey = bondy_oplog_event:key(Event),
    EventHlc = bondy_oplog_event:key_hlc(EventKey),
    true = ets:insert(Tab, {{{Bucket, Key}, EventHlc, EventKey}, Event}),
    ok.

-doc """
Return overlay events for `(Bucket, Key)` whose HLC is strictly greater
than `AfterHlc`, in HLC order (ascending). Caller typically passes the
projection's last-applied HLC as `AfterHlc`.
""".
-spec events_for(tid(), bucket(), cell_key(), after_hlc()) ->
    [bondy_oplog_event:t()].

events_for(Tab, Bucket, Key, AfterHlc) ->
    MS = [
        {
            {{{Bucket, Key}, '$1', '_'}, '$2'},
            [{'>', '$1', AfterHlc}],
            ['$2']
        }
    ],
    ets:select(Tab, MS).

-doc """
Like `events_for/4` but additionally bounded above by `MaxHlc`
(inclusive). Used by the fence-aware read paths (`read_batch/2`,
`read_at_hlc/3`) to exclude overlay events that have moved past the
caller's as-of point.
""".
-spec events_for_window(
    tid(),
    bucket(),
    cell_key(),
    AfterHlc :: after_hlc(),
    MaxHlc :: bondy_oplog_hlc:hlc()
) -> [bondy_oplog_event:t()].

events_for_window(Tab, Bucket, Key, AfterHlc, MaxHlc) ->
    MS = [
        {
            {{{Bucket, Key}, '$1', '_'}, '$2'},
            [
                {'>', '$1', AfterHlc},
                {'=<', '$1', MaxHlc}
            ],
            ['$2']
        }
    ],
    ets:select(Tab, MS).

-doc """
Range scan: return all overlay rows in `Bucket` whose `Key` is in
`[KeyLow, KeyHigh)` and whose HLC is strictly greater than `AfterHlc`.
Result is a list of `{Key, Event}` tuples in `(Key, HLC)` ascending
order. `Bucket` is constant across the scan, so it is not repeated in
each result tuple.
""".
-spec range(
    tid(),
    bucket(),
    KeyLow :: cell_key(),
    KeyHigh :: cell_key(),
    after_hlc()
) -> [{cell_key(), bondy_oplog_event:t()}].

range(Tab, Bucket, KeyLow, KeyHigh, AfterHlc) ->
    MS = [
        {
            {{{Bucket, '$1'}, '$2', '_'}, '$3'},
            [
                {'>=', '$1', {const, KeyLow}},
                {'<', '$1', {const, KeyHigh}},
                {'>', '$2', AfterHlc}
            ],
            [{{'$1', '$3'}}]
        }
    ],
    ets:select(Tab, MS).

-doc """
Range scan bounded above by `MaxHlc` (inclusive). All overlay rows in
`Bucket` whose `Key` is in `[KeyLow, KeyHigh)` and whose HLC is
`=< MaxHlc` are returned. `MaxHlc = infinity` removes the upper bound.

Used by `bondy_oplog_core:range/4` for fence-aware range scans where the
per-cell `> ProjHlc` filter is applied at the merge step.
""".
-spec range_window(
    tid(),
    bucket(),
    KeyLow :: cell_key(),
    KeyHigh :: cell_key(),
    MaxHlc :: bondy_oplog_hlc:hlc() | infinity
) -> [{cell_key(), bondy_oplog_event:t()}].

range_window(Tab, Bucket, KeyLow, KeyHigh, infinity) ->
    range(Tab, Bucket, KeyLow, KeyHigh, 0);
range_window(Tab, Bucket, KeyLow, KeyHigh, MaxHlc) when is_integer(MaxHlc) ->
    MS = [
        {
            {{{Bucket, '$1'}, '$2', '_'}, '$3'},
            [
                {'>=', '$1', {const, KeyLow}},
                {'<', '$1', {const, KeyHigh}},
                {'=<', '$2', MaxHlc}
            ],
            [{{'$1', '$3'}}]
        }
    ],
    ets:select(Tab, MS).

-doc """
Evict rows that have been promoted to the projection. Deletes every row
whose `(EventHlc, EventKey)` is `=<` the supplied watermark. Returns
the number of rows deleted (`select_delete/2`'s native return).
""".
-spec evict_to(
    tid(),
    AppliedHlc :: bondy_oplog_hlc:hlc(),
    AppliedEventKey :: bondy_oplog_event:event_key()
) -> non_neg_integer().

evict_to(Tab, AppliedHlc, AppliedEventKey) ->
    MS = [
        {
            {{'_', '$1', '$2'}, '_'},
            [
                {'orelse', {'<', '$1', AppliedHlc},
                    {'andalso', {'=:=', '$1', AppliedHlc},
                        {'=<', '$2', {const, AppliedEventKey}}}}
            ],
            [true]
        }
    ],
    ets:select_delete(Tab, MS).

-spec size(tid()) -> non_neg_integer().

size(Tab) ->
    ets:info(Tab, size).

-spec delete(tid()) -> ok.

delete(Tab) ->
    true = ets:delete(Tab),
    ok.
