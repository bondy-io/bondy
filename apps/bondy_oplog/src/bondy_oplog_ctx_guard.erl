%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_ctx_guard).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
The tier_2 stamp-site context-regression guard, extracted so both
`bondy_oplog_applier` (the per-instance applier process) and
`bondy_oplog_instance` (a **fused** instance, which has no separate
applier) enforce the identical safety check from one place instead of two
hand-synced copies.

## Why this exists

On the tier_2 write path the substrate reads a cell's current causal
context and stamps it into the new event, so the origin's next dot
strictly succeeds what it already wrote. That is sound only while the
context a stamp reads never regresses below what this origin already
observed for the cell — otherwise the write re-mints a used dot and the
value forks silently (`bondy_oplog_crdt_mv_register` /
`bondy_oplog_crdt_aw_map`, "Convergence preconditions"). This module
remembers the highest context handed out per cell (`stamp/5`) and refuses
— loudly, with a `[bondy_oplog, applier, context_regression]` telemetry
event — any stamp that regressed below it, converting a silent, permanent
fork into a recoverable write error.

This is sound only while a context never legitimately shrinks, which holds
by default (every path joins/grows it). Two paths shrink one on purpose,
and each has to tell the guard, or the next local write to the cell is
refused for a loss that never happened:

* membership-driven dead-origin VV reaping removes a retired origin's
  entry — co-evict the reaped ids via `coevict/2`;
* the causal-stability reclamation sweep DELETES a stable cell, taking its
  whole context with it — drop the cell via `forget/2`.

A wholesale catalogue install resets the guard outright (`new/0`).

## Ownership

The guard (`guard()`) is a plain map, owned by the caller's own process
state (the applier's `#state.ctx_guard`, or a fused instance's equivalent
field) — this module is pure and holds no state of its own.
""").

-export([coevict/2]).
-export([forget/2]).
-export([new/0]).
-export([stamp/5]).

-type guard() :: #{{term(), term()} => bondy_dvvset:vector()}.

-export_type([guard/0]).

%% Coarse-clear the whole guard past this many distinct cells, retaining
%% only the cell just stamped — bounds memory on an instance with an
%% unbounded number of distinct tier_2 cells.
-define(CTX_GUARD_MAX, 100_000).

%% =============================================================================
%% API
%% =============================================================================

-doc "An empty guard.".
-spec new() -> guard().

new() ->
    #{}.

-doc """
Records `Context` as the high-water for `{Bucket, Key}` and returns
`{{ok, Context}, Guard1}`, or refuses and returns
`{{error, {context_regression, Bucket, Key}}, Guard}` (the guard
unchanged) when `Context` regresses below the recorded high-water.

`Context =:= undefined` (tier_0/tier_1, which carry no context) and any
non-version-vector `Context` (a test probe, or a future context shape)
pass through untracked — only a version-vector context
(`[{Id, Counter}]`, what the tier_2 CRDTs return) is guardable.
""".
-spec stamp(
    InstanceId :: term(),
    Guard :: guard(),
    Bucket :: term(),
    Key :: term(),
    Context :: bondy_dvvset:vector() | undefined | term()
) ->
    {
        {ok, term()} | {error, {context_regression, term(), term()}},
        guard()
    }.

stamp(_InstanceId, Guard, _Bucket, _Key, undefined) ->
    {{ok, undefined}, Guard};
stamp(_InstanceId, Guard, _Bucket, _Key, Context) when not is_list(Context) ->
    {{ok, Context}, Guard};
stamp(InstanceId, Guard, Bucket, Key, Context) ->
    CellKey = {Bucket, Key},
    case maps:get(CellKey, Guard, undefined) of
        Prev when is_list(Prev) ->
            case vv_regressed(Context, Prev) of
                true ->
                    emit_regression(InstanceId, Bucket, Key, Prev, Context),
                    {{error, {context_regression, Bucket, Key}}, Guard};
                false ->
                    {{ok, Context}, record(Guard, CellKey, Prev, Context)}
            end;
        undefined ->
            {{ok, Context}, record(Guard, CellKey, [], Context)}
    end.

-doc """
Drops every reaped origin from each affected cell's stamp-site high-water
(removing a cell's entry entirely if it empties). `Reaped` is the
`[{CellKey, FoldModule, [Origin]}]` shape `reap_members/6` already
produces.
""".
-spec coevict(
    Guard :: guard(), Reaped :: [{term(), term(), [term()]}]
) -> guard().

coevict(Guard, Reaped) ->
    lists:foldl(
        fun({CellKey, _FoldModule, Ids}, Acc) ->
            case maps:find(CellKey, Acc) of
                {ok, VV} ->
                    VV1 = [E || {O, _C} = E <- VV, not lists:member(O, Ids)],
                    case VV1 of
                        [] -> maps:remove(CellKey, Acc);
                        _ -> Acc#{CellKey => VV1}
                    end;
                error ->
                    Acc
            end
        end,
        Guard,
        Reaped
    ).

-doc """
Drops `CellKeys` (`{Bucket, Key}`) from the high-water entirely, for cells
whose projection state was deliberately REMOVED — the causal-stability
reclamation sweep's `discard`, which deletes the cell. There is no
high-water left to defend once the state it summarised is gone: the next
local write to the key legitimately reads an empty context, and the
sweep's own contract is that such a cell is re-created by a later replay.

Distinct from `coevict/2`, which drops named origins from a cell that
SURVIVES. Passing a key the guard never tracked is a no-op, so a sweep
need not know which of the cells it discarded had been stamped locally.
""".
-spec forget(Guard :: guard(), CellKeys :: [{term(), term()}]) -> guard().

forget(Guard, CellKeys) ->
    maps:without(CellKeys, Guard).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Advance the per-cell high-water to `max(Prev, Context)` (the context is
%% monotone, so this equals `Context`, but the pointwise max is robust to
%% a non-tracked id). Coarse-clear the whole map past `?CTX_GUARD_MAX`
%% distinct cells, retaining only the cell just stamped.
record(Guard, CellKey, Prev, Context) ->
    Merged = vv_merge(Prev, Context),
    Guard1 = Guard#{CellKey => Merged},
    case map_size(Guard1) > ?CTX_GUARD_MAX of
        true -> #{CellKey => Merged};
        false -> Guard1
    end.

%% @private
emit_regression(InstanceId, Bucket, Key, Prev, Context) ->
    ?LOG_ERROR(#{
        description =>
            "tier_2 stamp-site context regression: a cell's causal context "
            "went backwards between two local writes. The write is refused "
            "to avoid silently forking the value (a re-minted dot). This "
            "signals durable projection state for the cell was lost or "
            "corrupted in process.",
        instance_id => InstanceId,
        bucket => Bucket,
        key => Key,
        previous_context => Prev,
        current_context => Context
    }),
    telemetry:execute(
        [bondy_oplog, applier, context_regression],
        #{count => 1},
        #{instance_id => InstanceId, bucket => Bucket, key => Key}
    ),
    ok.

%% @private
%% A version vector `[{Id, Counter}]` regresses relative to `Prev` when any
%% id `Prev` knows has a strictly smaller counter in `New` (an absent id
%% reads as 0). Equivalent to "New does not dominate Prev".
vv_regressed(New, Prev) ->
    lists:any(fun({Id, C}) -> vv_get(Id, New) < C end, Prev).

%% @private
vv_get(Id, VV) ->
    case lists:keyfind(Id, 1, VV) of
        {Id, C} -> C;
        false -> 0
    end.

%% @private
vv_merge(A, B) ->
    lists:foldl(
        fun({Id, C}, Acc) ->
            lists:keystore(Id, 1, Acc, {Id, erlang:max(C, vv_get(Id, Acc))})
        end,
        A,
        B
    ).
