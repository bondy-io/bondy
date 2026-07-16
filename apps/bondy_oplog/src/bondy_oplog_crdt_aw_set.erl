%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_aw_set).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Add-Wins Set (AWSet / Observed-Remove Set) — tier_2 operation-based CRDT.

The op-based equivalent of the pure `pure_awset`. A set with `add` and
`rmv` where, when an add and a remove of the same element are
**concurrent, the add wins** (the element stays in the set). This is the
classic observed-remove set: a remove only cancels the adds it has
*observed*; a concurrent add (which the remover never saw) survives.

Detecting concurrency needs true happens-before, so this is a **tier_2**
type: each write carries the writer's causal context (a version vector) in
the event `meta`, stamped by the substrate. The add-wins/observed-remove
machinery is shared with `bondy_oplog_crdt_aw_map` and
`bondy_oplog_crdt_ew_flag` via `bondy_oplog_crdt_aw_core`.

For *remove-wins* concurrency resolution use `bondy_oplog_crdt_rw_set`; for
permanent-removal (no re-add) semantics with no causal context use the
tier_0 `bondy_oplog_crdt_two_p_set`.

## State

```
{DotStore :: #{dot() => elem()},
 Context  :: bondy_dvvset:vector(),
 MaxHlc   :: hlc()}
```

A *dot* `{Origin, Seq}` is the unique identity of an `add`; it maps to the
element that add inserted. An element is present iff it has at least one
live dot.

## Operations

```
{add, Elem :: binary()}
{rmv, Elem :: binary()}
```

`{add, E}` mints a fresh dot for `E`. `{rmv, E}` drops every dot of `E`
the writer's context observed; concurrent adds (un-observed dots) survive.
`value_equals_state/0 -> false`: the value is the set of present elements,
not the dot-store, so the substrate stores a value column.
""").

%% bondy_oplog_crdt
-export([causal_tier/0]).
-export([init/0]).
-export([interpret_cog/2]).
-export([query/2]).
%% projection seam
-export([to_value/1]).
-export([hlc/1]).
-export([gc_threshold/1]).
-export([value_equals_state/0]).
-export([order_independent/0]).
-export([batchable/0]).
-export([context_of/1]).
-export([reap_origins/2]).
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative (tier_2 step)
-export([apply_op/4]).

-type elem() :: binary().
-type origin() :: binary().
-type dot() :: bondy_oplog_crdt_aw_core:dot().
-type dot_store() :: #{dot() => elem()}.
-type context() :: bondy_dvvset:vector().
-type state() :: {dot_store(), context(), bondy_oplog_hlc:hlc()}.
-type op() :: {add, elem()} | {rmv, elem()}.

-export_type([state/0, op/0, elem/0]).

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

-spec query(value, state()) -> [elem()].

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative (tier_2 step)
%% =============================================================================

-doc """
Apply one `{add, E}` or `{rmv, E}` with its observed causal `Context` (the
stamped version vector in the event `meta`).

- `add`: insert the op's fresh dot under `E`. An add never drops dots — an
  element accumulates one live dot per concurrent add, and is present
  while any survives.
- `rmv`: drop every dot whose element is `E` and which the writer
  observed; concurrent adds of `E` (un-observed dots) survive — add-wins.

The surviving dot-set is a pure function of the event set (a dot of `E`
survives iff no remove of `E` observed it), so this eager step equals the
key-sorted `interpret_cog/2` fold.
""".
-spec apply_op(
    state(),
    op(),
    bondy_oplog_event:event_key(),
    Context :: context() | undefined
) -> state().

apply_op({DS, CC, Hlc}, {add, E}, Key, Context0) when is_binary(E) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    {
        DS#{Dot => E},
        bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))
    };
apply_op({DS, CC, Hlc}, {rmv, E}, Key, Context0) when is_binary(E) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    DS1 = maps:filter(
        fun(D, V) ->
            not (V =:= E andalso bondy_oplog_crdt_aw_core:dot_observed(D, Ctx))
        end,
        DS
    ),
    {DS1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))}.

%% =============================================================================
%% projection seam
%% =============================================================================

-doc "The set's value: the distinct elements with at least one live dot.".
-spec to_value(state()) -> [elem()].

to_value({DS, _CC, _Hlc}) ->
    lists:usort(maps:values(DS)).

-doc """
The cell's current causal context — the version vector the substrate
stamps into the next write's `meta`.
""".
-spec context_of(state()) -> context().

context_of({_DS, CC, _Hlc}) ->
    CC.

-doc """
Reap the causal-context entries of permanently-retired origins (the
membership-driven GC, mirroring `bondy_oplog_crdt_aw_map`). Drops a retired
origin's `CC` entry only when it has no live dot in the dot-store — so the
value (`to_value/1`) is unchanged. Idempotent. Safe only once the origin is
permanently gone and causally stable cluster-wide (the operator's
obligation).
""".
-spec reap_origins(state(), [origin()]) -> {state(), Reaped :: [origin()]}.

reap_origins({DS, CC, Hlc}, Retired) ->
    Live = live_origins(DS),
    Reaped = [
        O
     || {O, _S} <- CC,
        lists:member(O, Retired),
        not sets:is_element(O, Live)
    ],
    case Reaped of
        [] ->
            {{DS, CC, Hlc}, []};
        _ ->
            CC1 = [{O, S} || {O, S} <- CC, not lists:member(O, Reaped)],
            {{DS, CC1, Hlc}, lists:usort(Reaped)}
    end.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_DS, _CC, Hlc}) ->
    Hlc.

-spec gc_threshold(state()) -> bondy_oplog_hlc:hlc() | undefined.

gc_threshold({_DS, _CC, 0}) ->
    undefined;
gc_threshold({_DS, _CC, Hlc}) ->
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

encode_state({_DS, _CC, _Hlc} = State) ->
    <<?ENC_V1, (term_to_binary(canon(State)))/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<?ENC_V1, Bin/binary>>) ->
    %% C-2: `[safe]` — this decodes peer-shipped CRDT state on the AAE merge
    %% path (`bondy_oplog_cell_apply`), so untrusted bytes must not be able to
    %% create atoms/funs. Bondy-written values are plain data and round-trip.
    uncanon(binary_to_term(Bin, [safe])).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
key_hlc(Key) ->
    bondy_oplog_event:key_hlc(Key).

%% @private
%% The set of origins that hold at least one live dot — these carry the
%% set's value and are never reaped from the context.
live_origins(DS) ->
    maps:fold(
        fun({O, _S}, _V, Acc) -> sets:add_element(O, Acc) end,
        sets:new([{version, 2}]),
        DS
    ).

%% @private
%% Canonical (map-free) encodable form: dot-store as a dot-sorted list of
%% `{Dot, Elem}`, context sorted by origin, HLC.
canon({DS, CC, Hlc}) ->
    {lists:sort(maps:to_list(DS)), lists:sort(CC), Hlc}.

%% @private
uncanon({DSL, CC, Hlc}) ->
    {maps:from_list(DSL), CC, Hlc}.
