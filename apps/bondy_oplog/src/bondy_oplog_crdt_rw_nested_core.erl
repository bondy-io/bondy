%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_rw_nested_core).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Shared **two-level remove-wins-with-nesting** engine for
`bondy_oplog_crdt_rw_map` — the causal dual of
`bondy_oplog_crdt_nested_core` (the add-wins engine
`bondy_oplog_crdt_aw_map`/`bondy_oplog_crdt_aw_set` share).

## Why a separate module, not an extension of `nested_core`

The two families prune on genuinely different rules: add-wins drops the
dots a *writer* observed (`bondy_oplog_crdt_aw_core:drop_observed/2` —
symmetric, no accumulated state beyond the dot-store itself); remove-wins
drops adds whose *own* observed context fails to dominate a *monotone,
ever-growing* remove frontier (`bondy_oplog_crdt_rw_core:add/4`, `:rmv/2`,
`:vv_dominates/2`). Bolting the second rule onto `nested_core` would make
every add-wins caller pay for remove-wins bookkeeping it does not need.
What genuinely IS shared — because it is agnostic to which pruning rule
produced the surviving dot-store — is reused directly:
`bondy_oplog_crdt_nested_core:sub_mod/1` (type-consistency read) and
`:nested_value/2` (the sub-CRDT replay). This module supplies only the
remove-wins-flavoured outer bookkeeping, built on
`bondy_oplog_crdt_rw_core`'s per-key cell.

## Type consistency

Identical contract to `bondy_oplog_crdt_nested_core`: a key's `SubMod` is
fixed by its first nested write; mixing a flat `put/5` and `put_nested/7`
on the same live key, or changing `SubMod` on a live key, raises
`{badarg, _}`.
""").

-export([nested_value/2]).
-export([put/5]).
-export([put_nested/7]).
-export([rmv/3]).
-export([sub_mod/1]).

-type dot() :: bondy_oplog_crdt_aw_core:dot().
-type outer_key() :: term().
-type cell() :: bondy_oplog_crdt_rw_core:cell().
-type entries() :: #{outer_key() => cell()}.

-export_type([entries/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Put a flat value `V` at key `K` with dot `Dot` and observed context `Ctx`:
store the add, then re-prune `K`'s cell against its remove frontier
(`bondy_oplog_crdt_rw_core:add/4`) — remove-wins, the causal dual of
`bondy_oplog_crdt_nested_core:put/5`. Raises `{badarg, {nested_key, K}}`
if `K` currently holds nested sub-ops.
""".
-spec put(
    Entries :: entries(),
    K :: outer_key(),
    Dot :: dot(),
    Ctx :: bondy_oplog_crdt_aw_core:vv(),
    V :: term()
) -> entries().

put(Entries, K, Dot, Ctx, V) ->
    Cell0 = maps:get(K, Entries, bondy_oplog_crdt_rw_core:new()),
    sub_mod(Cell0) =:= undefined orelse error({badarg, {nested_key, K}}),
    Cell1 = bondy_oplog_crdt_rw_core:add(Cell0, Dot, Ctx, V),
    put_cell(Entries, K, Cell1).

-doc """
Put a sub-operation `SubOp` (targeting sub-CRDT `SubMod`) at key `K` with
dot `Dot` and observed context `Ctx` — the remove-wins dual of
`bondy_oplog_crdt_nested_core:put_nested/7`. Raises `{badarg,
{sub_mod_mismatch, K, Expected, Got}}` if `K` already holds sub-ops for a
*different* `SubMod`, or `{badarg, {flat_key, K}}` if `K` currently holds
a flat (non-nested) value.
""".
-spec put_nested(
    Entries :: entries(),
    K :: outer_key(),
    Dot :: dot(),
    Ctx :: bondy_oplog_crdt_aw_core:vv(),
    SubMod :: module(),
    Hlc :: bondy_oplog_hlc:hlc(),
    SubOp :: term()
) -> entries().

put_nested(Entries, K, Dot, Ctx, SubMod, Hlc, SubOp) ->
    Cell0 = maps:get(K, Entries, bondy_oplog_crdt_rw_core:new()),
    ok = check_sub_mod(Cell0, K, SubMod),
    Cell1 = bondy_oplog_crdt_rw_core:add(
        Cell0, Dot, Ctx, {sub, SubMod, Hlc, SubOp}
    ),
    put_cell(Entries, K, Cell1).

-doc """
Remove-wins remove at key `K` with dot `Dot`: extend `K`'s remove frontier
and prune any add it now beats (`bondy_oplog_crdt_rw_core:rmv/2`) — unlike
the add-wins `rmv/3`, the remover's own observed context is irrelevant to
survival, only the removes' dots (see `bondy_oplog_crdt_rw_core`'s
moduledoc). A cell that carries no information at all afterwards (no
surviving add, empty remove frontier) is dropped from `Entries`.
""".
-spec rmv(Entries :: entries(), K :: outer_key(), Dot :: dot()) -> entries().

rmv(Entries, K, Dot) ->
    Cell0 = maps:get(K, Entries, bondy_oplog_crdt_rw_core:new()),
    Cell1 = bondy_oplog_crdt_rw_core:rmv(Cell0, Dot),
    put_cell(Entries, K, Cell1).

-doc """
The `SubMod` a key's cell was written with, or `undefined` if it holds no
nested entries (no surviving add, or all surviving adds are flat values).
""".
-spec sub_mod(cell()) -> module() | undefined.

sub_mod(Cell) ->
    bondy_oplog_crdt_nested_core:sub_mod(bondy_oplog_crdt_rw_core:adds(Cell)).

-doc """
The sub-CRDT's converged value for a key's cell — delegates entirely to
`bondy_oplog_crdt_nested_core:nested_value/2` over the cell's surviving
adds (`bondy_oplog_crdt_rw_core:adds/1`), which is agnostic to whichever
pruning rule produced them.
""".
-spec nested_value(SubMod :: module(), Cell :: cell()) -> term().

nested_value(SubMod, Cell) ->
    bondy_oplog_crdt_nested_core:nested_value(
        SubMod, bondy_oplog_crdt_rw_core:adds(Cell)
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
put_cell(Entries, K, Cell) ->
    case bondy_oplog_crdt_rw_core:is_empty(Cell) of
        true -> maps:remove(K, Entries);
        false -> Entries#{K => Cell}
    end.

%% @private
check_sub_mod(Cell, K, SubMod) ->
    DS = bondy_oplog_crdt_rw_core:adds(Cell),
    case bondy_oplog_crdt_nested_core:sub_mod(DS) of
        undefined when map_size(DS) =:= 0 -> ok;
        undefined -> error({badarg, {flat_key, K}});
        SubMod -> ok;
        Other -> error({badarg, {sub_mod_mismatch, K, Other, SubMod}})
    end.
