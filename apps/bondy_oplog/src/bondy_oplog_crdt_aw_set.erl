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
`bondy_oplog_crdt_ew_flag` via `bondy_oplog_crdt_aw_core`; the two-level
dot-store bookkeeping (add/apply/rmv per element, keyed by the element
identity — the same shape `bondy_oplog_crdt_aw_map` needs, keyed by the
map key) is shared with it via `bondy_oplog_crdt_nested_core`.

For *remove-wins* concurrency resolution use `bondy_oplog_crdt_rw_set`; for
permanent-removal (no re-add) semantics with no causal context use the
tier_0 `bondy_oplog_crdt_two_p_set`.

## State

```
{Entries :: #{elem() => dot_store()},
 Context :: bondy_dvvset:vector(),
 MaxHlc  :: hlc()}

dot_store() :: #{dot() => elem() | bondy_oplog_crdt_nested_core:sub_value()}
```

A *dot* `{Origin, Seq}` is the unique identity of an `add` or `apply`. An
element is present iff its dot-store is non-empty. For a plain element
each surviving dot maps to the element itself (redundant with the outer
key, but keeps a flat element's dot-store shaped exactly like a nested
one); see *Nested sub-CRDTs* for the `apply` case.

## Operations

```
{add, Elem :: binary()}
{apply, Elem :: binary(), module(), term()}   %% apply a sub-op to a nested tier_0 sub-CRDT
{rmv, Elem :: binary()}
```

`{add, E}` mints a fresh dot for `E`. `{apply, E, SubMod, SubOp}` mints a
fresh dot carrying a tagged sub-operation instead — see *Nested
sub-CRDTs*. `{rmv, E}` drops every dot of `E` the writer's context
observed; concurrent adds/applies of `E` (un-observed dots) survive.

## Nested sub-CRDTs

An element's value can be another CRDT's converged state instead of its
own identity: `{apply, E, SubMod, SubOp}` accumulates `{sub, SubMod, Hlc,
SubOp}` at the operation's dot exactly as `{add, E}` accumulates `E` —
same add-wins/observed-remove treatment, since
`bondy_oplog_crdt_aw_core:drop_observed/2` only ever inspects the dot,
never the value. `to_value/1` detects whether *any* element in the state
is nested and switches its return shape accordingly — see `to_value/1`.

`SubMod` MUST be `causal_tier() =:= tier_0` (`pn_counter`,
`lww_register`, `max_register`, `min_register`, ...) — see
`bondy_oplog_crdt_aw_map`'s moduledoc for the reasoning (identical here).
An element's `SubMod` is fixed by its first `{apply, ...}` write; mixing
`add`/`rmv` and `apply` on the same live element, or changing `SubMod` on
a live element, raises `{badarg, _}`
(`bondy_oplog_crdt_nested_core:put/5`, `:put_nested/7`).

`value_equals_state/0 -> false`: the value is derived from the dot-store,
not the dot-store itself, so the substrate stores a value column.
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

-type elem() :: binary().
-type origin() :: binary().
-type dot_store() :: bondy_oplog_crdt_nested_core:dot_store().
-type entries() :: #{elem() => dot_store()}.
-type context() :: bondy_dvvset:vector().
-type state() :: {entries(), context(), bondy_oplog_hlc:hlc()}.
-type op() ::
    {add, elem()}
    | {apply, elem(), module(), term()}
    | {rmv, elem()}.

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

-spec query(value, state()) -> [elem()] | #{elem() => true | term()}.

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative (tier_2 step)
%% =============================================================================

-doc """
Apply one `{add, E}`, `{apply, E, SubMod, SubOp}`, or `{rmv, E}` with its
observed causal `Context` (the stamped version vector in the event
`meta`). Dispatches to `bondy_oplog_crdt_nested_core`, which owns the
per-element dot-store bookkeeping generically (shared with
`bondy_oplog_crdt_aw_map`); this clause set only derives the dot/context
and folds the cell-wide context and HLC.

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

apply_op({Entries, CC, Hlc}, {add, E}, Key, Context0) when is_binary(E) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Entries1 = bondy_oplog_crdt_nested_core:put(Entries, E, Dot, Ctx, E),
    {
        Entries1,
        bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))
    };
apply_op({Entries, CC, Hlc}, {apply, E, SubMod, SubOp}, Key, Context0)
        when is_binary(E) andalso is_atom(SubMod) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Entries1 = bondy_oplog_crdt_nested_core:put_nested(
        Entries, E, Dot, Ctx, SubMod, key_hlc(Key), SubOp
    ),
    {
        Entries1,
        bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))
    };
apply_op({Entries, CC, Hlc}, {rmv, E}, Key, Context0) when is_binary(E) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Entries1 = bondy_oplog_crdt_nested_core:rmv(Entries, E, Ctx),
    {
        Entries1,
        bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))
    }.

%% =============================================================================
%% projection seam
%% =============================================================================

-doc """
The set's value. When no element is nested (the common case — identical
to every element ever written via plain `add`/`rmv`), returns the sorted
list of present elements, exactly as before this module supported
nesting. As soon as any element is nested (written via at least one
`apply`), returns `#{elem() => true | SubValue}` instead — `true` for a
plain sibling element, the sub-CRDT's converged value
(`bondy_oplog_crdt_nested_core:nested_value/2`) for a nested one. Existing
data can never trigger the map shape: nothing produced a nested entry
before this capability existed.
""".
-spec to_value(state()) -> [elem()] | #{elem() => true | term()}.

to_value({Entries, _CC, _Hlc}) ->
    case any_nested(Entries) of
        false ->
            lists:sort([
                E
             || {E, DS} <- maps:to_list(Entries), map_size(DS) > 0
            ]);
        true ->
            maps:fold(
                fun(E, DS, Acc) ->
                    case map_size(DS) of
                        0 -> Acc;
                        _ -> Acc#{E => elem_value(DS)}
                    end
                end,
                #{},
                Entries
            )
    end.

-doc """
The cell's current causal context — the version vector the substrate
stamps into the next write's `meta`.
""".
-spec context_of(state()) -> context().

context_of({_Entries, CC, _Hlc}) ->
    CC.

-doc """
Reap the causal-context entries of permanently-retired origins (the
membership-driven GC, mirroring `bondy_oplog_crdt_aw_map`). Drops a retired
origin's `CC` entry only when it has no live dot in any element's
dot-store — so the value (`to_value/1`) is unchanged. Idempotent. Safe
only once the origin is permanently gone and causally stable
cluster-wide (the operator's obligation).
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
%% Whether any element in the state is nested — determines to_value/1's
%% return shape.
any_nested(Entries) ->
    maps:fold(
        fun(_E, DS, Acc) ->
            Acc orelse bondy_oplog_crdt_nested_core:sub_mod(DS) =/= undefined
        end,
        false,
        Entries
    ).

%% @private
%% An element's projected value: `true` for a plain (flat) element, the
%% sub-CRDT's converged value for a nested one.
elem_value(DS) ->
    case bondy_oplog_crdt_nested_core:sub_mod(DS) of
        undefined -> true;
        SubMod -> bondy_oplog_crdt_nested_core:nested_value(SubMod, DS)
    end.

%% @private
%% The set of origins that hold at least one live dot (in any element's
%% dot-store) — these carry the set's value and are never reaped from the
%% context.
live_origins(Entries) ->
    maps:fold(
        fun(_E, DS, Acc) ->
            maps:fold(
                fun({O, _S}, _V, A) -> sets:add_element(O, A) end, Acc, DS
            )
        end,
        sets:new([{version, 2}]),
        Entries
    ).

%% @private
%% Canonical (map-free) encodable form: entries as an element-sorted list
%% of `{Elem, dot-sorted list of {Dot, Value}}`, context sorted by
%% origin, HLC.
canon({Entries, CC, Hlc}) ->
    EntriesL = lists:sort([
        {E, lists:sort(maps:to_list(DS))}
     || {E, DS} <- maps:to_list(Entries)
    ]),
    {EntriesL, lists:sort(CC), Hlc}.

%% @private
uncanon({EntriesL, CC, Hlc}) ->
    Entries = maps:from_list([{E, maps:from_list(L)} || {E, L} <- EntriesL]),
    {Entries, CC, Hlc}.
