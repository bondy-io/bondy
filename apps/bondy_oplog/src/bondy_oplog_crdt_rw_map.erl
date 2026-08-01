%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_rw_map).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Remove-Wins observed-remove map (RWORMap) — tier_2 operation-based CRDT,
with optional per-key nested tier_0 sub-CRDT values. The causal dual of
`bondy_oplog_crdt_aw_map`: a key written concurrently with a remove that
did **not** observe that write is still discarded — the remove wins.

## Why this needs its own module, not just `aw_map` with a flag

Add-wins and remove-wins prune on different rules — see
`bondy_oplog_crdt_rw_core`'s moduledoc for the remove-wins rule (an add
survives iff its observed context dominates the *monotone, ever-growing*
remove frontier `R`) versus `bondy_oplog_crdt_aw_core`'s (drop exactly the
dots the *writer* observed). This module reuses
`bondy_oplog_crdt_rw_nested_core` — the remove-wins analogue of
`bondy_oplog_crdt_nested_core` — for the per-key bookkeeping, which in
turn reuses `bondy_oplog_crdt_rw_core`'s per-key cell (shared with
`bondy_oplog_crdt_rw_set`/`bondy_oplog_crdt_dw_flag`) for pruning and
`bondy_oplog_crdt_nested_core`'s `sub_mod/1`/`nested_value/2` (pruning-rule
agnostic) for the type-consistency check and sub-CRDT replay.

## State

```
{Entries :: #{map_key() => bondy_oplog_crdt_rw_core:cell()},
 Context :: bondy_dvvset:vector(),
 MaxHlc  :: hlc()}
```

A key's cell keeps its surviving adds (each with the context it observed,
and either a flat value or a nested `{sub, SubMod, Hlc, SubOp}` tag) and
its remove frontier; the key is present iff the cell has a surviving add
(`bondy_oplog_crdt_rw_core:present/1` — NOT the same as the cell simply
being present in `Entries`: a cell with an empty remove frontier removed
down to zero adds is still retained in `Entries` until its frontier is
ALSO empty, per `bondy_oplog_crdt_rw_core:is_empty/1`).

## Operations

```
{put, key(), value()}              %% assign value to key (remove-wins on concurrent rmv)
{apply, key(), module(), term()}   %% apply a sub-op to a nested tier_0 sub-CRDT
{rmv, key()}                       %% remove-wins remove of the key
```

`{apply, K, SubMod, SubOp}` mirrors `bondy_oplog_crdt_aw_map`'s: `SubMod`
MUST be `causal_tier() =:= tier_0`, and a key's `SubMod` is fixed by its
first nested write (mixing flat and nested writes on the same live key
raises `{badarg, _}`, per `bondy_oplog_crdt_rw_nested_core`).
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
-export([batchable/0]).
-export([context_of/1]).
-export([reap_origins/2]).
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative (tier_2 step)
-export([apply_op/4]).

-type map_key() :: binary().
-type map_value() :: term().
-type origin() :: binary().
-type cell() :: bondy_oplog_crdt_rw_core:cell().
-type entries() :: #{map_key() => cell()}.
-type context() :: bondy_dvvset:vector().
-type state() :: {entries(), context(), bondy_oplog_hlc:hlc()}.
-type op() ::
    {put, map_key(), map_value()}
    | {apply, map_key(), module(), term()}
    | {rmv, map_key()}.

-export_type([state/0, op/0, map_key/0, map_value/0]).

%% The state encoding format version (leading byte of `encode_state/1`).
-define(ENC_V1, 1).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

-spec causal_tier() -> tier_2.

causal_tier() ->
    tier_2.

-spec init() -> state().

init() ->
    {#{}, [], 0}.

-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

-spec query(value, state()) -> #{map_key() => [map_value()] | term()}.

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative (tier_2 step)
%% =============================================================================

-doc """
Apply one `{put, K, V}`, `{apply, K, SubMod, SubOp}`, or `{rmv, K}` with
its observed causal `Context`. Dispatches to
`bondy_oplog_crdt_rw_nested_core`, which owns the per-key remove-wins
dot-store bookkeeping; this clause set only derives the dot/context and
folds the cell-wide context and HLC. Note `{rmv, K}` does not need
`Context` for the removal itself (remove-wins survival depends only on
which removes an add observed, i.e. their dots — see
`bondy_oplog_crdt_rw_core`) but the context is still absorbed into the
cell-wide `CC` for future writes to stamp against.
""".
-spec apply_op(
    state(),
    op(),
    bondy_oplog_event:event_key(),
    Context :: context() | undefined
) -> state().

apply_op({Entries, CC, Hlc}, {put, K, V}, Key, Context0) when is_binary(K) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Entries1 = bondy_oplog_crdt_rw_nested_core:put(Entries, K, Dot, Ctx, V),
    {Entries1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))};
apply_op({Entries, CC, Hlc}, {apply, K, SubMod, SubOp}, Key, Context0) when
    is_binary(K) andalso is_atom(SubMod)
->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Entries1 = bondy_oplog_crdt_rw_nested_core:put_nested(
        Entries, K, Dot, Ctx, SubMod, key_hlc(Key), SubOp
    ),
    {Entries1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))};
apply_op({Entries, CC, Hlc}, {rmv, K}, Key, Context0) when is_binary(K) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Entries1 = bondy_oplog_crdt_rw_nested_core:rmv(Entries, K, Dot),
    {Entries1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))}.

%% =============================================================================
%% projection seam
%% =============================================================================

-doc """
The map's value: present keys (`bondy_oplog_crdt_rw_core:present/1`), each
mapped to the sorted set of its concurrent surviving sibling values, or —
for a nested key — the sub-CRDT's own converged value
(`bondy_oplog_crdt_rw_nested_core:nested_value/2`). Absent/removed keys
are absent from the result.
""".
-spec to_value(state()) -> #{map_key() => [map_value()] | term()}.

to_value({Entries, _CC, _Hlc}) ->
    maps:fold(
        fun(K, Cell, Acc) ->
            case bondy_oplog_crdt_rw_core:present(Cell) of
                false ->
                    Acc;
                true ->
                    case bondy_oplog_crdt_rw_nested_core:sub_mod(Cell) of
                        undefined ->
                            DS = bondy_oplog_crdt_rw_core:adds(Cell),
                            Acc#{K => lists:usort(maps:values(DS))};
                        SubMod ->
                            Acc#{
                                K =>
                                    bondy_oplog_crdt_rw_nested_core:nested_value(
                                        SubMod, Cell
                                    )
                            }
                    end
            end
        end,
        #{},
        Entries
    ).

-doc """
The cell's current causal context — the version vector the substrate
stamps into the next write's `meta`.
""".
-spec context_of(state()) -> context().

context_of({_Entries, CC, _Hlc}) ->
    CC.

-doc """
Reap the causal-context entries of permanently-retired origins, mirroring
`bondy_oplog_crdt_aw_map`. Drops a retired origin's `CC` entry only when
it has no surviving add in any key's cell — so the value (`to_value/1`)
is unchanged (a remove frontier alone carries no origin-attributable
value; only surviving adds do). Idempotent. Safe only once the origin is
permanently gone and causally stable cluster-wide (the operator's
obligation).
""".
-spec reap_origins(state(), [origin()]) -> {state(), Reaped :: [origin()]}.

reap_origins({Entries, CC, Hlc}, Retired) ->
    Live = live_origins(Entries),
    Reaped = [
        O
     || {O, _S} <- CC,
        lists:member(O, Retired),
        not sets:is_element(O, Live)
    ],
    case Reaped of
        [] ->
            {{Entries, CC, Hlc}, []};
        _ ->
            CC1 = [{O, S} || {O, S} <- CC, not lists:member(O, Reaped)],
            {{Entries, CC1, Hlc}, lists:usort(Reaped)}
    end.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_Entries, _CC, Hlc}) ->
    Hlc.

-spec value_equals_state() -> boolean().

value_equals_state() ->
    false.

-spec order_independent() -> boolean().

order_independent() ->
    true.

-spec batchable() -> boolean().

batchable() ->
    true.

-spec encode_state(state()) -> binary().

encode_state({_Entries, _CC, _Hlc} = State) ->
    <<?ENC_V1, (term_to_binary(canon(State)))/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<?ENC_V1, Bin/binary>>) ->
    %% C-2: `[safe]` — decodes peer-shipped CRDT state on the AAE merge path.
    uncanon(binary_to_term(Bin, [safe])).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
%% The set of origins that hold at least one surviving add (across all
%% keys' cells) — these carry the map's value and are never reaped from
%% the context. A remove frontier alone is not origin-attributable value.
live_origins(Entries) ->
    maps:fold(
        fun(_K, Cell, Acc) ->
            DS = bondy_oplog_crdt_rw_core:adds(Cell),
            maps:fold(
                fun({O, _S}, _V, A) -> sets:add_element(O, A) end, Acc, DS
            )
        end,
        sets:new([{version, 2}]),
        Entries
    ).

%% @private
key_hlc(Key) ->
    bondy_oplog_event:key_hlc(Key).

%% @private
%% Canonical (map-free) encodable form: entries as a key-sorted list of
%% `{Key, {Adds sorted list of {Dot, {Ctx, Value}}, R}}`, context sorted
%% by origin, HLC.
canon({Entries, CC, Hlc}) ->
    EntriesL = lists:sort([
        {K, canon_cell(Cell)}
     || {K, Cell} <- maps:to_list(Entries)
    ]),
    {EntriesL, lists:sort(CC), Hlc}.

%% @private
uncanon({EntriesL, CC, Hlc}) ->
    Entries = maps:from_list([
        {K, uncanon_cell(C)}
     || {K, C} <- EntriesL
    ]),
    {Entries, CC, Hlc}.

%% @private
canon_cell({Adds, R}) ->
    {lists:sort(maps:to_list(Adds)), lists:sort(R)}.

%% @private
uncanon_cell({AddsL, R}) ->
    {maps:from_list(AddsL), R}.
