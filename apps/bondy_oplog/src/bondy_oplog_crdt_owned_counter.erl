%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_owned_counter).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
A PN-counter whose cell is **owned by one node named in the cell key**, and
whose per-origin entries are therefore reclaimable when that node departs.

State, operation, encoding, tier and stabilization are
`bondy_oplog_crdt_pn_counter`'s, delegated verbatim — the two are
byte-compatible, so a table may switch between them with no data migration
(pinned by `bondy_oplog_crdt_owned_counter_test`'s cross-module round-trip).
The whole of the difference is one optional callback: `reap_origins/2`.

## Why this is a separate module and not a flag on `bondy_oplog_crdt_pn_counter`

`bondy_oplog_crdt_reap_origins_test`'s `kernel_tier0_crdt_is_not_supported_test`
states the general rule, and it is right: *a tier_0 counter's per-origin
entries are value, not disposable bookkeeping*. Dropping a departed origin
from a shared counter destroys real data — measured: a counter carrying
`n1 => 10, n2 => 7` reads 17, and reaping `n1` leaves 7, which `stabilize/2`
then correctly KEEPS. Exporting `reap_origins/2` from `pn_counter` itself
would impose that on every consumer.

What licenses it here is not the counter but the **cell key**. A registry RIB
cell is keyed `{RealmUri, MatchPolicy, Uri, Nodestring}` and is single-writer:
only the node the key names ever writes it, so every contribution in
`counters` was minted by that node's origins. Its value is "live local entries
on that node", which cannot outlive the node. Once the node is gone from the
membership its contributions are not data being discarded — they are a
statement about a node that no longer exists.

So the licensing condition is a property of the TABLE, and the module is where
that declaration lives: naming this module in
`bondy_namespace_catalog:fold_opts/1` is what asserts "the cells of this table
are owned by the node their key names". `bondy_oplog_cell_utils:reap/4` selects
buckets by `erlang:function_exported(Mod, reap_origins, 2)`, so the assertion
is exactly what makes the table visible to the membership-driven reap.

## How a departed node's cell is reclaimed

`bondy_oplog_origin_retirement` computes the dead-origin complement from
Partisan membership and calls the reap.
`bondy_oplog_cell_utils:reap_one_cell/6` then re-encodes a **value-preserving**
frame — same Hlc, same value column, only the state bytes shrink. So this
callback does not reclaim anything by itself; it makes the STATE's value zero
and reclamation rests on a later `stabilize/2` reading those shrunk bytes.
That works here with no new policy at all, because `pn_counter`'s
`stabilize/2` already discards unconditionally at algebraic zero — "not a
policy choice, true for any consumer", as its own doc puts it.

Chain, end to end: dead origin -> `reap_origins/2` drops its `counters` entry
-> `to_value/1` reaches 0 -> `stabilize/2` discards the cell. Pinned by
`bondy_oplog_crdt_owned_counter_test`'s
`reap_all_origins_zeroes_and_discards_test/0`, and end to end across a real
cluster by `bondy_rib_reclamation_cluster_SUITE`.

## What this deliberately does NOT do

It carries no schema and adds no field structure. The RIB subscription cell is
one counter; wrapping it in `bondy_oplog_crdt_struct` to gain a `force_reap`
schema policy moved it from tier_0 to tier_2, where the add-wins state grows
one dot per unstabilized write and `apply_op` becomes quadratic. Measured on
the Fly fleet: subscribe latency 198ms -> 6-23s. See the "Departure" section
of `m:bondy_registry_rib`.
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
-export([stabilize/2]).
-export([state_to_op/1]).
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative
-export([apply_op/3]).
%% optional callback — the whole of the difference from pn_counter
-export([reap_origins/2]).

-type state() :: bondy_oplog_crdt_pn_counter:state().
-type op() :: bondy_oplog_crdt_pn_counter:op().

-export_type([state/0, op/0]).

-define(BASE, bondy_oplog_crdt_pn_counter).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

-spec causal_tier() -> tier_0.

causal_tier() ->
    ?BASE:causal_tier().

-spec init() -> state().

init() ->
    ?BASE:init().

-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, State) ->
    %% `?MODULE`, not `?BASE`: the fold dispatches `apply_op/3` back through
    %% this module, keeping the kernel's module identity consistent with the
    %% one the table declared.
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

-spec query(value, state()) -> integer().

query(Query, State) ->
    ?BASE:query(Query, State).

%% =============================================================================
%% bondy_oplog_crdt_commutative
%% =============================================================================

-spec apply_op(state(), op(), bondy_oplog_event:event_key()) -> state().

apply_op(State, Op, Key) ->
    ?BASE:apply_op(State, Op, Key).

%% =============================================================================
%% projection seam
%% =============================================================================

-spec to_value(state()) -> integer().

to_value(State) ->
    ?BASE:to_value(State).

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc(State) ->
    ?BASE:hlc(State).

-spec value_equals_state() -> boolean().

value_equals_state() ->
    ?BASE:value_equals_state().

-spec order_independent() -> boolean().

order_independent() ->
    ?BASE:order_independent().

-spec stabilize(bondy_oplog_hlc:hlc(), state()) -> keep | discard.

stabilize(StableHlc, State) ->
    ?BASE:stabilize(StableHlc, State).

-spec state_to_op(state()) -> op().

state_to_op(State) ->
    ?BASE:state_to_op(State).

-spec encode_state(state()) -> binary().

encode_state(State) ->
    ?BASE:encode_state(State).

-spec decode_state(binary()) -> state().

decode_state(Bin) ->
    ?BASE:decode_state(Bin).

%% =============================================================================
%% reap
%% =============================================================================

-doc """
Drops the retired origins' `counters` entries, returning the origins actually
removed.

Returns `{State, []}` — no entry matched — when none of `Retired` has ever
written this cell, which is the common case for most cells in a reap pass.
That empty list is load-bearing: `bondy_oplog_cell_utils:reap_one_cell/6`
skips the frame rewrite entirely unless at least one origin was reaped, so an
unmatched cell costs a read and nothing else, and a second reap of the same
cell is a no-op rather than a redundant write.

Removing an entry is exact rather than approximate: `to_value/1` is
`sum(Pos) - sum(Neg)` folded over `counters`, so dropping an origin removes
precisely that origin's contribution and leaves every survivor's intact. On a
single-writer RIB cell that empties the map and the value reaches 0.
""".
-spec reap_origins(state(), [bondy_oplog_origin:t()]) ->
    {state(), [bondy_oplog_origin:t()]}.

reap_origins(#{counters := Counters} = State, Retired) ->
    case [O || O <- Retired, maps:is_key(O, Counters)] of
        [] ->
            {State, []};
        Hit ->
            {State#{counters := maps:without(Hit, Counters)}, lists:usort(Hit)}
    end.
