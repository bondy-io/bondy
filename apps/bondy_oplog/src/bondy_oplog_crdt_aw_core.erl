%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_aw_core).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Shared **add-wins / observed-remove** dot-store machinery for the tier_2
add-wins CRDTs: the add-wins map (`bondy_oplog_crdt_aw_map`), the add-wins
set (`bondy_oplog_crdt_aw_set`), and the enable-wins flag
(`bondy_oplog_crdt_ew_flag`, an add-wins set over a single token).

A *dot* is `{Origin, Seq}` — the unique identity of an operation, taken
from its event key. A *causal context* is a version vector `[{Origin,
MaxSeq}]` (`bondy_dvvset:vector()`): the set of dots a writer had observed.

The two primitives every add-wins type needs:

- **observed-remove** (`drop_observed/2`): given a dot-store and a writer's
  observed context, keep exactly the dots the writer did *not* observe.
  A concurrent add (its dot un-observed) survives a remove — that is
  add-wins.
- **context accumulation** (`cc_absorb/3`): fold a writer's observed
  context and the operation's own dot into the cell-wide context, so a
  later remove can tell whether it observed a given add.

These functions operate on plain `#{dot() => _}` maps and version-vector
lists, independent of how each type shapes its entries, so all three
add-wins types share one correct implementation. Exactness under causal
(per-origin FIFO) delivery is what makes `dot_observed/2` a simple
`Ctx[O] >= S` test.
""").

-export([dot_of/1]).
-export([normalise_context/1]).
-export([drop_observed/2]).
-export([dot_observed/2]).
-export([cc_absorb/3]).
-export([vv_merge/2]).

-type origin() :: binary().
-type counter() :: non_neg_integer().
-type dot() :: {origin(), counter()}.
-type vv() :: bondy_dvvset:vector().

-export_type([dot/0, vv/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc "The operation's dot `{Origin, Seq}`, taken from its event key.".
-spec dot_of(bondy_oplog_event:event_key()) -> dot().

dot_of(Key) ->
    {bondy_oplog_event:key_origin(Key), bondy_oplog_event:key_seq(Key)}.

-doc """
A tier_2 write always carries a stamped context (a version vector). A
missing context (`undefined`) is the empty causal history — a first write
to a fresh cell observes nothing.
""".
-spec normalise_context(undefined | vv()) -> vv().

normalise_context(undefined) -> [];
normalise_context(VV) when is_list(VV) -> VV.

-doc """
Drop from a dot-store every dot the context observed; keep the concurrent
(un-observed) dots. The observed-remove primitive: a remove carrying
context `Ctx` removes exactly the adds `Ctx` had seen, so a concurrent add
survives (add-wins).
""".
-spec drop_observed(#{dot() => V}, vv()) -> #{dot() => V}.

drop_observed(DS, Ctx) ->
    maps:filter(fun(Dot, _V) -> not dot_observed(Dot, Ctx) end, DS).

-doc """
`{O, S}` is observed by `Ctx` iff `Ctx[O] >= S`. Exact under causal
(per-origin FIFO) delivery.
""".
-spec dot_observed(dot(), vv()) -> boolean().

dot_observed({O, S}, Ctx) ->
    case lists:keyfind(O, 1, Ctx) of
        {O, N} -> N >= S;
        false -> false
    end.

-doc """
Fold the writer's observed context and this op's own dot into the
cell-wide context. Monotone: the context only ever grows.
""".
-spec cc_absorb(vv(), vv(), dot()) -> vv().

cc_absorb(CC, Ctx, {O, S}) ->
    vv_merge(vv_merge(CC, Ctx), [{O, S}]).

-doc "Pointwise max of two version vectors, sorted by origin (canonical).".
-spec vv_merge(vv(), vv()) -> vv().

vv_merge(A, B) ->
    Merged = lists:foldl(
        fun({O, N}, Acc) ->
            maps:update_with(O, fun(Old) -> erlang:max(Old, N) end, N, Acc)
        end,
        #{},
        A ++ B
    ),
    lists:sort(maps:to_list(Merged)).
