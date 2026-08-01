%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_rw_core).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Shared **remove-wins** machinery for the tier_2 remove-wins CRDTs: the
remove-wins set (`bondy_oplog_crdt_rw_set`, one *cell* per element) and the
disable-wins flag (`bondy_oplog_crdt_dw_flag`, a single cell over one
token). It is the causal dual of the add-wins core
(`bondy_oplog_crdt_aw_core`).

## The rule

For one element/token, an **add** survives iff it causally observed
*every* remove — i.e. its stamped context dominates the *remove frontier*
`R` (the join of all remove dots). Consequences:

- add then remove (causal) ⇒ the remove is not in the add's context ⇒
  removed.
- remove then add (re-add) ⇒ the add observed the remove ⇒ present.
- add concurrent remove ⇒ the add did not observe the remove ⇒ removed —
  **remove wins**.

`R` only ever grows, so once an add fails to dominate `R` it can never
recover: a beaten add is pruned permanently. The surviving-add set is
therefore a pure function of the operation set (a add survives iff its
context dominates the *final* `R`), so the eager incremental step equals
the group `interpret_cog` fold (the tier_2 ship gate).

## A cell

```
{Adds :: #{dot() => {context(), payload()}},   %% surviving adds
 R    :: bondy_dvvset:vector()}                 %% remove frontier (join of rmv dots)
```

Each surviving add carries both the context it observed (needed to test
survival against the remove frontier) and its payload — an opaque term
for a presence-only consumer (`bondy_oplog_crdt_rw_set`,
`bondy_oplog_crdt_dw_flag`, which store the element/token itself, never
inspected again), or a flat value / nested sub-op tag for a value-carrying
consumer (`bondy_oplog_crdt_rw_map`). `prune/2` only ever inspects the
context half, never the payload — mirroring how
`bondy_oplog_crdt_aw_core:drop_observed/2` is payload-agnostic on the
add-wins side. `Adds` holds only currently-surviving adds (every stored
add dominates `R`), so a cell is *present* iff `Adds` is non-empty.
""").

-export([add/4]).
-export([adds/1]).
-export([is_empty/1]).
-export([new/0]).
-export([present/1]).
-export([rmv/2]).
-export([vv_dominates/2]).

-type dot() :: bondy_oplog_crdt_aw_core:dot().
-type vv() :: bondy_dvvset:vector().
-type payload() :: term().
-type cell() :: {Adds :: #{dot() => {vv(), payload()}}, R :: vv()}.

-export_type([cell/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc "The empty cell (no adds, empty remove frontier).".
-spec new() -> cell().

new() ->
    {#{}, []}.

-doc """
Apply an add with dot `Dot`, observed context `Ctx`, and `Payload`. The
add is stored, then the cell is re-pruned against the current remove
frontier — so an add concurrent with (or behind) an existing remove is
dropped immediately (remove-wins).
""".
-spec add(cell(), dot(), vv(), payload()) -> cell().

add({Adds, R}, Dot, Ctx, Payload) ->
    {prune(Adds#{Dot => {Ctx, Payload}}, R), R}.

-doc "The surviving adds' payloads, keyed by dot (context stripped).".
-spec adds(cell()) -> #{dot() => payload()}.

adds({Adds, _R}) ->
    maps:map(fun(_Dot, {_Ctx, Payload}) -> Payload end, Adds).

-doc """
Apply a remove with dot `Dot`: extend the remove frontier `R` with `Dot`,
then prune every add the new frontier now beats. (The remove's own context
is irrelevant to survival — only which removes an add *observed* matters,
i.e. the removes' dots.)
""".
-spec rmv(cell(), dot()) -> cell().

rmv({Adds, R}, Dot) ->
    R1 = bondy_oplog_crdt_aw_core:vv_merge(R, [Dot]),
    {prune(Adds, R1), R1}.

-doc "The cell is present iff it has a surviving add.".
-spec present(cell()) -> boolean().

present({Adds, _R}) ->
    map_size(Adds) > 0.

-doc """
Whether the cell carries no information at all (no surviving add and an
empty remove frontier) — used to drop fully-empty per-element entries.
""".
-spec is_empty(cell()) -> boolean().

is_empty({Adds, R}) ->
    map_size(Adds) =:= 0 andalso R =:= [].

-doc """
Version-vector dominance: `C` dominates `R` iff for every `{O, N}` in `R`,
`C[O] >= N`. (An add with context `C` survives the remove frontier `R`
exactly when `C` dominates `R`.)
""".
-spec vv_dominates(vv(), vv()) -> boolean().

vv_dominates(_C, []) ->
    true;
vv_dominates(C, R) ->
    lists:all(
        fun({O, N}) ->
            case lists:keyfind(O, 1, C) of
                {O, M} -> M >= N;
                false -> false
            end
        end,
        R
    ).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
%% Keep only the adds whose context dominates the remove frontier. The
%% payload half of each entry is never inspected.
prune(Adds, R) ->
    maps:filter(fun(_Dot, {Ctx, _Payload}) -> vv_dominates(Ctx, R) end, Adds).
