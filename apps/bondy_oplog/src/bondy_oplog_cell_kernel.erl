%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_cell_kernel).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
The per-cell projection **kernel** — the single seam through which the
applier maintains a catalogue cell's materialised state and value.

A kernel is `{crdt, Mod}` where `Mod` is a native `bondy_oplog_crdt`
operation-based CRDT. Every cell type is a native CRDT; the legacy
state-based fold path has been retired.

`from_modules/2` selects the module: a configured `crdt_module` wins;
otherwise the `fold_module` *label* is resolved to its native CRDT via
`default_crdt_for_fold/1` (a zero-migration alias — every former fold has a
byte-identical CRDT twin). An unknown label has no twin and is an error.

## Why a kernel

The applier's per-cell compute (`compute_one_cell/12`) reads the old cell,
applies one operation, and encodes a new frame. Routing every step through
this module keeps the projection seam in one place.

## `apply/6` — the eager projection step (Option B)

`apply(Kernel, OldState, OldValueOpt, Op, Key, Context)` returns everything
the frame encoder needs: `{NewState, Hlc, StateBytes, ValueBytes,
ValueEqualsState}`.

For a **commutative** CRDT (`order_independent() -> true`) the O(1)
single-operation step `apply_op/3` (tier_0) or `apply_op/4` (tier_2, with
the write's causal `Context`) equals `interpret_cog` over the cell's group,
so applying one operation onto the materialised state is correct without
re-folding history. The value is `to_value(NewState)` directly — no delta.
A **non-commutative** CRDT has no correct O(1) eager step; the kernel
refuses it with a clear error (the per-cell live-log is a later step).

## `interpret_overlay/4` + `decode_value_bytes/2` — the read seam

The read path (`bondy_oplog_core`) is the symmetric counterpart of the write
path. `interpret_overlay/4` calls the CRDT's own `interpret_cog/2` — the
named operation-based primitive — over the cell's *live group* of pending
overlay events on top of the projection state (key-ordered), and
`decode_value_bytes/2` turns a stored HEAD value-slot back into the
user-facing value. The read path therefore *interprets a COG*; it never
folds events through a state-based `apply_event`.
""").

-export([from_modules/2]).
-export([default_crdt_for_fold/1]).
-export([init/1]).
-export([decode_state/2]).
-export([encode_state/2]).
-export([to_value/2]).
-export([apply/5]).
-export([apply/6]).
-export([interpret_overlay/4]).
-export([decode_value_bytes/2]).
-export([reap_origins/3]).

-type t() :: {crdt, module()}.

-export_type([t/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Select the cell kernel from a table's configured modules. A `crdt_module`
takes precedence; otherwise the `fold_module` label is resolved to its
native CRDT twin via `default_crdt_for_fold/1`. An unknown label (no twin)
raises `{unknown_cell_module, _}`.
""".
-spec from_modules(
    FoldModule :: atom() | undefined,
    CrdtModule :: module() | undefined
) -> t().

from_modules(_FoldModule, CrdtModule) when CrdtModule =/= undefined ->
    {crdt, CrdtModule};
from_modules(FoldModule, undefined) ->
    case default_crdt_for_fold(FoldModule) of
        undefined -> error({unknown_cell_module, FoldModule});
        CrdtModule -> {crdt, CrdtModule}
    end.

-doc """
Map a short label to its native operation-based CRDT module, or
`undefined` when none exists. Two kinds of label resolve here:

- **Legacy fold names** — every former commutative fold has a
  byte-identical CRDT twin, so `fold_module => lww_register` (or the
  fully-qualified `bondy_oplog_fold_lww_register`) resolves to
  `bondy_oplog_crdt_lww_register` and durable cells decode unchanged.
- **Convenience aliases** for CRDTs that never had a fold — e.g.
  `two_p_set`, `aw_set`, `rw_set`, `ew_flag`, `dw_flag` resolve to their
  `bondy_oplog_crdt_*` modules.

A fully-qualified native CRDT module name passed directly resolves to
itself (the pass-through clause).
""".
-spec default_crdt_for_fold(atom() | module() | undefined) ->
    module() | undefined.

default_crdt_for_fold(lww_register) ->
    bondy_oplog_crdt_lww_register;
default_crdt_for_fold(bondy_oplog_fold_lww_register) ->
    bondy_oplog_crdt_lww_register;
default_crdt_for_fold(g_counter) ->
    bondy_oplog_crdt_g_counter;
default_crdt_for_fold(bondy_oplog_fold_g_counter) ->
    bondy_oplog_crdt_g_counter;
default_crdt_for_fold(pn_counter) ->
    bondy_oplog_crdt_pn_counter;
default_crdt_for_fold(bondy_oplog_fold_pn_counter) ->
    bondy_oplog_crdt_pn_counter;
default_crdt_for_fold(g_set) ->
    bondy_oplog_crdt_g_set;
default_crdt_for_fold(bondy_oplog_fold_g_set) ->
    bondy_oplog_crdt_g_set;
default_crdt_for_fold(max_register) ->
    bondy_oplog_crdt_max_register;
default_crdt_for_fold(bondy_oplog_fold_max_register) ->
    bondy_oplog_crdt_max_register;
default_crdt_for_fold(min_register) ->
    bondy_oplog_crdt_min_register;
default_crdt_for_fold(bondy_oplog_fold_min_register) ->
    bondy_oplog_crdt_min_register;
default_crdt_for_fold(index_entry) ->
    bondy_oplog_crdt_index_entry;
default_crdt_for_fold(bondy_oplog_fold_index_entry) ->
    bondy_oplog_crdt_index_entry;
default_crdt_for_fold(two_p_set) ->
    bondy_oplog_crdt_two_p_set;
default_crdt_for_fold(aw_set) ->
    bondy_oplog_crdt_aw_set;
default_crdt_for_fold(rw_set) ->
    bondy_oplog_crdt_rw_set;
default_crdt_for_fold(ew_flag) ->
    bondy_oplog_crdt_ew_flag;
default_crdt_for_fold(dw_flag) ->
    bondy_oplog_crdt_dw_flag;
default_crdt_for_fold(Mod) when is_atom(Mod), Mod =/= undefined ->
    %% A native CRDT module name passed directly (e.g. via `fold_module =>
    %% bondy_oplog_crdt_lww_register`) resolves to itself. An unknown atom
    %% (no native CRDT) maps to `undefined`.
    case is_crdt_module(Mod) of
        true -> Mod;
        false -> undefined
    end;
default_crdt_for_fold(_Other) ->
    undefined.

-doc "The kernel's bottom state (cold-start, no operation observed).".
-spec init(t()) -> term().

init({crdt, Mod}) ->
    Mod:init().

-doc "Decode stored state bytes into the kernel's state.".
-spec decode_state(t(), binary()) -> term().

decode_state({crdt, Mod}, Bytes) ->
    Mod:decode_state(Bytes).

-doc """
Encode a kernel state to its stored state bytes — the inverse of
`decode_state/2`. Used by out-of-band cell rewrites (the dead-origin
reaper) that re-persist a modified state without going through `apply/6`.
""".
-spec encode_state(t(), term()) -> binary().

encode_state({crdt, Mod}, State) ->
    Mod:encode_state(State).

-doc "Project a kernel state to its user-facing value.".
-spec to_value(t(), term()) -> term().

to_value({crdt, Mod}, State) ->
    Mod:to_value(State).

-doc """
Apply one operation onto the materialised cell, returning the components
the V2 frame encoder needs: `{NewState, Hlc, StateBytes, ValueBytes,
ValueEqualsState}`. `ValueBytes` is `undefined` exactly when
`ValueEqualsState` is `true`.
""".
-spec apply(
    Kernel :: t(),
    OldState :: term(),
    OldValueOpt :: binary() | undefined,
    Op :: term(),
    Key :: bondy_oplog_event:event_key()
) ->
    {
        NewState :: term(),
        Hlc :: bondy_oplog_hlc:hlc(),
        StateBytes :: binary(),
        ValueBytes :: binary() | undefined,
        ValueEqualsState :: boolean()
    }.

%% Context-free form (tier_0): equivalent to `apply/6` with `undefined`
%% causal context.
apply(Kernel, OldState, OldValueOpt, Op, Key) ->
    apply(Kernel, OldState, OldValueOpt, Op, Key, undefined).

-doc """
As `apply/5` but with the write's causal `Context` (the event `meta` —
`undefined` for tier_0). The commutative branch threads it to `apply_op/4`
when the CRDT exports it (tier_2); tier_0 CRDTs ignore it.
""".
-spec apply(
    Kernel :: t(),
    OldState :: term(),
    OldValueOpt :: binary() | undefined,
    Op :: term(),
    Key :: bondy_oplog_event:event_key(),
    Context :: term()
) ->
    {
        NewState :: term(),
        Hlc :: bondy_oplog_hlc:hlc(),
        StateBytes :: binary(),
        ValueBytes :: binary() | undefined,
        ValueEqualsState :: boolean()
    }.

apply({crdt, Mod}, OldState, _OldValueOpt, Op, Key, Context) ->
    case crdt_order_independent(Mod) of
        true ->
            NewState = bondy_oplog_crdt_commutative:apply_op(
                Mod, OldState, Op, Key, Context
            ),
            Hlc = Mod:hlc(NewState),
            StateBytes = Mod:encode_state(NewState),
            ValueEqualsState = crdt_value_equals_state(Mod),
            ValueBytes =
                case ValueEqualsState of
                    true -> undefined;
                    false -> term_to_binary(Mod:to_value(NewState))
                end,
            {NewState, Hlc, StateBytes, ValueBytes, ValueEqualsState};
        false ->
            %% Non-commutative CRDTs need their live group re-interpreted
            %% on write; the per-cell live-log is a later rollout step.
            error({non_commutative_crdt_eager_unsupported, Mod})
    end.

-doc """
Interpret a group of pending overlay events on top of a base state,
returning `{NewState, NewHlc}`.

The read-path counterpart of `apply/6`. `Hlc0` is the base state's HLC,
returned unchanged when there are no overlay events to interpret. Calls the
CRDT's own `interpret_cog/2` over the overlay group on top of `State0` (NOT
a per-event state-based fold), then the CRDT's `hlc/1`.
""".
-spec interpret_overlay(
    Kernel :: t(),
    State0 :: term(),
    Hlc0 :: bondy_oplog_hlc:hlc(),
    Events :: [bondy_oplog_event:t()]
) -> {NewState :: term(), NewHlc :: bondy_oplog_hlc:hlc()}.

interpret_overlay(_Kernel, State, Hlc, []) ->
    {State, Hlc};
interpret_overlay({crdt, Mod}, State0, _Hlc0, Events) ->
    NewState = Mod:interpret_cog(Events, State0),
    {NewState, Mod:hlc(NewState)}.

-doc """
Decode the `ValueBytes` slot of a HEAD frame back into the user-facing
value. The read-path inverse of the value bytes `apply/6` composes.

For a `value_equals_state` kernel the bytes are the encoded *state* and
`to_value/1` collapses to the identity; otherwise the bytes are
`term_to_binary(Value)` and a straight `binary_to_term/1` reproduces it.
""".
-spec decode_value_bytes(t(), binary()) -> term().

decode_value_bytes({crdt, Mod}, ValueBytes) when is_binary(ValueBytes) ->
    case crdt_value_equals_state(Mod) of
        true ->
            State = Mod:decode_state(ValueBytes),
            Mod:to_value(State);
        false ->
            binary_to_term(ValueBytes)
    end.

-doc """
Reap the causal-context entries of permanently-retired origins from a
tier_2 CRDT cell state (the dead-origin GC; `bondy_oplog_crdt`
`reap_origins/2`). Returns `{NewState, Reaped}` — `Reaped` is the subset of
`RetiredOrigins` actually dropped (value-preserving: only causal-history-
only entries are removed).

Returns `not_supported` for any CRDT that does not export `reap_origins/2`
(tier_0 CRDTs, whose per-origin entries are value rather than disposable
bookkeeping). The applier short-circuits the whole reap pass on
`not_supported`, so the tier_0 path is untouched.
""".
-spec reap_origins(t(), term(), [term()]) ->
    {NewState :: term(), Reaped :: [term()]} | not_supported.

reap_origins({crdt, Mod}, State, Retired) ->
    case erlang:function_exported(Mod, reap_origins, 2) of
        true -> Mod:reap_origins(State, Retired);
        false -> not_supported
    end.

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
%% Whether `Mod` is a loaded native CRDT (exports the mandatory
%% `bondy_oplog_crdt` `causal_tier/0` callback). `ensure_loaded` first, or a
%% not-yet-loaded module reports `false`.
is_crdt_module(Mod) ->
    _ = code:ensure_loaded(Mod),
    erlang:function_exported(Mod, causal_tier, 0).

%% @private
crdt_order_independent(Mod) ->
    erlang:function_exported(Mod, order_independent, 0) andalso
        Mod:order_independent().

%% @private
crdt_value_equals_state(Mod) ->
    erlang:function_exported(Mod, value_equals_state, 0) andalso
        Mod:value_equals_state().
