%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_projection_ets).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
In-memory `bondy_oplog_projection_adapter` backed by a single
`ordered_set` ETS table per `(NS, Index, Shard)`.

Bucket is part of the ETS key: the row tuple is `{{Bucket, Key}, Frame}`,
so an `ordered_set` scan keeps a single bucket's rows contiguous in
`(Bucket, Key)` lexicographic order — the same half-open `[Low, High)`
range semantics the leveled adapter provides.

## When to use it

This is the projection backend for **ephemeral** namespaces — state that
must NOT survive node death. The motivating case is WAMP
registrations/subscriptions: when a node dies, every transport connection
on it drops, so every session (and the registrations/subscriptions it
owned) is gone. Persisting that state to disk would only resurrect dead,
unroutable entries on restart, so it is materialised in RAM and
reconverges from peer anti-entropy.

For durable state use `bondy_db_projection_leveled`.

## Lifecycle and owner-death

The ETS table is owned by the process that calls `open/4`, and the VM
deletes it when that owner dies — the ephemeral wipe on node death.

The owner has to outlive (or supervise) the oplog instances that write
to the table: the applier runs in a separate supervision subtree
(`bondy_oplog_instance_dyn_sup`) and caches the tid, so an owner that
dies while the applier lives would leave the applier's next
`put_batch/2` hitting a dead tid. The `bondy_db_topology_memory` flow
enforces this rather than assuming it: tables are owned by a dedicated,
DB-scoped `bondy_db_topology_memory_owner` process whose lifetime is
bracketed by the topology's `init/2` → `shutdown/1` (decoupled from the
transient `open_table/3` caller), so a facade caller dying no longer
wipes the table or crashes a live applier. A consumer wiring this
adapter into a different topology must provide an equivalent long-lived
owner.

`close/1` deletes the table and, because whole-table `ets:delete/1` is
owner-only (the `public` flag governs only object access, not table
management), must be called from the owning process — which is why the
memory topology funnels both `open/4` and `close/1` through the owner.

## No `head/3`

This adapter deliberately does **not** export the optional `head/3`
fast-path. The HEAD path exists to skip a journal hop on durable backends;
for an in-RAM `ordered_set` `get/3` already returns the full frame with no
I/O, so a separate HEAD read buys nothing. The substrate falls back to
`get/3 + bondy_oplog_cell_frame:extract_head/1`. (A test-only wrapper,
`bondy_oplog_projection_head_counting`, adds `head/3` around this adapter
to exercise the fast-path; production reads use the fallback.)
""").

-behaviour(bondy_oplog_projection_adapter).

-export([
    open/4,
    close/1,
    get/3,
    put_batch/2,
    range/5,
    delete/3,
    clear/2,
    info/1
]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Create a fresh `ordered_set` ETS table for the keyspace. The returned tid
is the handle; it is owned by the calling process and auto-deleted on
owner death. `NS`/`Index`/`Shard`/`Opts` are accepted for behaviour
conformance and ignored — the table is anonymous and one per call.
""".
open(_NS, _Index, _Shard, _Opts) ->
    Tab = ets:new(?MODULE, [
        ordered_set,
        public,
        {read_concurrency, true}
    ]),
    {ok, Tab}.

-doc "Delete the backing table. Must be called from the owning process.".
close(Tab) ->
    true = ets:delete(Tab),
    ok.

-doc "Single-key read. Returns the stored V2 frame or `not_found`.".
get(Tab, Bucket, Key) ->
    case ets:lookup(Tab, {Bucket, Key}) of
        [{_, Frame}] -> {ok, Frame};
        [] -> not_found
    end.

-doc "Batched write. Each entry carries its own `Bucket`.".
put_batch(Tab, Entries) ->
    Rows = [{{B, K}, F} || {B, K, F} <- Entries],
    true = ets:insert(Tab, Rows),
    ok.

-doc """
Single-bucket half-open `[Low, High)` ascending range scan, capped at
`limit` (default 1000). A non-positive `limit` yields `[]`.

`High` may be the atom `infinity` for an open-ended scan (every key
`>= Low` in the bucket) — the form the secondary-index primary-scan
fallback uses, since no finite binary exceeds every possible key.

The scan SEEKS to `Low` and walks forward, so its cost is `O(limit)`
however far into the bucket `Low` lies. That is load-bearing rather than
incidental: every caller that pages a band re-enters here with a rising
`Low`, so a scan whose cost grew with `Low` makes paging a band of N rows
quadratic in N.

A match-spec guard cannot express the seek. `ets:select/3` narrows an
`ordered_set` traversal on a bound key PATTERN, never on a `>=` GUARD, so
the guarded form this replaces re-traversed the bucket from its first key
on every call — measured at 49,918 reductions to reach row 49,900 of
50,000, against 0 for a seek. `range_cost_is_flat_in_low/1` in
`bondy_oplog_projection_ets_test` is the ratchet on that, and
`bondy_oplog_projection_ets_proper_test` pins this against the guarded
form it replaces.

The walk steps with `ets:next_lookup/2`, which yields the next key AND its
object in one atomic operation. A separate `next/2` + `lookup/2` pair would
race a concurrent writer on this `public` table — the row can vanish between
the two — and the resulting empty read has no correct handling that is also
testable: skipping it is right but unreachable from any sequential test, and
counting it against the limit truncates the page, which a paging caller
reads as band exhaustion and silently drops the remainder. Stepping
atomically removes the case instead of arbitrating it.
""".
range(_Tab, _Bucket, _Low, _High, #{limit := Limit}) when
    is_integer(Limit), Limit =< 0
->
    {ok, []};
range(Tab, Bucket, Low, High, Opts) ->
    Limit = maps:get(limit, Opts, ?DEFAULT_RANGE_LIMIT),
    Seed = {Bucket, Low},
    {N, Acc0} =
        case first_row(Tab, Seed, Low, High) of
            {ok, Row} -> {Limit - 1, [Row]};
            none -> {Limit, []}
        end,
    {ok, lists:reverse(walk(Tab, Bucket, Seed, High, N, Acc0))}.

%% @private
%% `Low` itself, when it is stored and inside the upper bound.
%% `ets:next_lookup/2` steps STRICTLY forward, so the inclusive lower bound
%% cannot come out of the walk and needs this probe of its own.
first_row(_Tab, _Seed, Low, High) when High =/= infinity, Low >= High ->
    none;
first_row(Tab, Seed, Low, _High) ->
    case ets:lookup(Tab, Seed) of
        [{_, Frame}] -> {ok, {Low, Frame}};
        [] -> none
    end.

%% @private
%% Step forward from `Prev`, emitting at most `N` rows. Rows accumulate
%% newest-first.
%%
%% Leaving the bucket is detected by the key tag, not by a bound: the
%% successor of a bucket's last key is the FIRST key of the next bucket,
%% which is a well-formed key of the same shape. The pins are
%% `prop_never_leaves_its_bucket/0` and the confinement example beside it.
%%
%% `High =:= infinity` cannot be folded into the comparison because atoms
%% sort BEFORE binaries, so `Key < infinity` is false for every key.
walk(_Tab, _Bucket, _Prev, _High, N, Acc) when N =< 0 ->
    Acc;
walk(Tab, Bucket, Prev, High, N, Acc) ->
    case ets:next_lookup(Tab, Prev) of
        {{Bucket, Key} = EtsKey, [{_, Frame}]} when
            High =:= infinity orelse Key < High
        ->
            walk(Tab, Bucket, EtsKey, High, N - 1, [{Key, Frame} | Acc]);
        _ ->
            %% `'$end_of_table'`, the first key of the NEXT bucket, or a key
            %% at or past `High`. The band is exhausted in every case.
            Acc
    end.

-doc "Single-key delete inside a Bucket.".
delete(Tab, Bucket, Key) ->
    true = ets:delete(Tab, {Bucket, Key}),
    ok.

-doc """
Delete every row in the backing table (the optional `clear/2` callback),
used by the secondary-index rebuild to wipe a stale index shard before
re-folding it from the primary, so orphaned terms (entries the primary
value no longer yields) do not survive the rebuild.

`Scope` (a `bondy_oplog_projection_adapter:clear_scope()`) is accepted for
behaviour conformance but **ignored**: this adapter creates one anonymous table
per `(NS, Index, Shard)` (see `open/4`), so every row already belongs to the one
index being rebuilt — clearing the whole table *is* the bucket-scoped wipe, and
is O(index size). (The scope's entity confinement matters only on backends that
co-locate several tables in one keyspace; ETS never does.) Safe to call from any
process — `ets:delete_all_objects/1` only needs object-write access, which the
`public` table grants.
""".
clear(Tab, _Scope) ->
    true = ets:delete_all_objects(Tab),
    ok.

-doc "Introspection: row count and memory words for the backing table.".
info(Tab) ->
    #{
        backend => ets,
        size => ets:info(Tab, size),
        memory => ets:info(Tab, memory)
    }.
