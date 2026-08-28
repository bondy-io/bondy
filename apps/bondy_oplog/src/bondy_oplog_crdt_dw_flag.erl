%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_dw_flag).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Disable-Wins Flag (DWFlag) — tier_2 operation-based CRDT.

The op-based equivalent of the pure `pure_dwflag`. A boolean flag with
`enable` and `disable` where, when an enable and a disable are
**concurrent, disable wins** (the flag reads `false`). It is exactly a
remove-wins set over a single implicit token: `enable` is an add,
`disable` is a remove, and the flag is `true` iff the token's add survives
(observed every disable). The causal dual of `bondy_oplog_crdt_ew_flag`.

Detecting concurrency needs true happens-before, so this is **tier_2**:
each write carries the writer's causal context in the event `meta`. The
remove-wins resolution is shared with `bondy_oplog_crdt_rw_set` via
`bondy_oplog_crdt_rw_core`.

## State

```
{Cell    :: bondy_oplog_crdt_rw_core:cell(),   %% the token's remove-wins cell
 Context :: bondy_dvvset:vector(),
 MaxHlc  :: hlc()}
```

## Operations

```
enable | disable
```

`enable` adds the op's dot to the token cell; `disable` extends the cell's
remove frontier. The flag is `true` iff a surviving enable remains — i.e.
an enable that observed every disable.
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
-export([removal_op/0]).
-export([stabilize/2]).
-export([encode_state/1]).
-export([decode_state/1]).
%% bondy_oplog_crdt_commutative (tier_2 step)
-export([apply_op/4]).

-type context() :: bondy_dvvset:vector().
-type state() :: {
    bondy_oplog_crdt_rw_core:cell(), context(), bondy_oplog_hlc:hlc()
}.
-type op() :: enable | disable.

-export_type([state/0, op/0]).

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
    {bondy_oplog_crdt_rw_core:new(), [], 0}.

-spec interpret_cog([bondy_oplog_event:t()], state()) -> state().

interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

-spec query(value, state()) -> boolean().

query(value, State) ->
    to_value(State).

%% =============================================================================
%% bondy_oplog_crdt_commutative (tier_2 step)
%% =============================================================================

-doc """
Apply one `enable` or `disable` with its observed causal `Context`,
delegating the remove-wins resolution to `bondy_oplog_crdt_rw_core`:

- `enable`: add the op's dot to the token cell; dropped immediately if a
  prior disable already beats it (concurrent/older enable ⇒ disable wins).
- `disable`: extend the token's remove frontier and prune any enable it
  now beats.

The surviving-enable set is a pure function of the event set, so this eager
step equals the key-sorted `interpret_cog/2` fold.
""".
-spec apply_op(
    state(),
    op(),
    bondy_oplog_event:event_key(),
    Context :: context() | undefined
) -> state().

apply_op({Cell, CC, Hlc}, enable, Key, Context0) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    %% The token has no value beyond its own presence -- the payload is
    %% never inspected, only every rw_core cell's shape is uniform.
    Cell1 = bondy_oplog_crdt_rw_core:add(Cell, Dot, Ctx, enabled),
    {Cell1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))};
apply_op({Cell, CC, Hlc}, disable, Key, Context0) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Cell1 = bondy_oplog_crdt_rw_core:rmv(Cell, Dot),
    {Cell1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))}.

%% =============================================================================
%% projection seam
%% =============================================================================

-doc "The flag's value: `true` iff a surviving enable remains.".
-spec to_value(state()) -> boolean().

to_value({Cell, _CC, _Hlc}) ->
    bondy_oplog_crdt_rw_core:present(Cell).

-doc "The cell's current causal context, stamped into the next write.".
-spec context_of(state()) -> context().

context_of({_Cell, CC, _Hlc}) ->
    CC.

-doc """
The whole-cell removal for `bondy_db:delete/3`: a `disable` extends the
token's remove frontier, driving the value to the fold's empty (`false`,
disable-wins); the cell is physically reclaimed later by `stabilize/2`
once the disable is causally stable (BONDY_DB_RECLAMATION_PROOF.md §9).
""".
-spec removal_op() -> disable.

removal_op() ->
    disable.

-doc """
Causal stabilization (BONDY_DB_RECLAMATION_PROOF.md §9): `discard` when the
flag is `false` (no surviving enable) and every constituent operation is
strictly below the stability point (`hlc(S) < StableHlc`). The retained
remove frontier only beats a CONCURRENT enable, and by obligation A7 no
future-delivered enable is concurrent with the stable disables — it
observed them — so it survives on the kept state exactly as on a fresh
cell; the frontier is effect-unreachable. Strict bound: an operation at
exactly `StableHlc` may be undelivered. A live flag (`true`) is data and
is kept at any stability point.
""".
-spec stabilize(bondy_oplog_hlc:hlc(), state()) -> keep | discard.

stabilize(StableHlc, {_Cell, _CC, Hlc} = State) when Hlc < StableHlc ->
    case to_value(State) of
        false -> discard;
        true -> keep
    end;
stabilize(_StableHlc, _State) ->
    keep.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_Cell, _CC, Hlc}) ->
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

encode_state({_Cell, _CC, _Hlc} = State) ->
    <<?ENC_V1, (term_to_binary(canon(State)))/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<?ENC_V1, Bin/binary>>) ->
    %% Own-persisted projection bytes — plain decode per the C-2
    %% own-bytes rule (rationale:
    %% `bondy_oplog_cell_kernel:decode_value_bytes/2`).
    uncanon(binary_to_term(Bin)).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
key_hlc(Key) ->
    bondy_oplog_event:key_hlc(Key).

%% @private
%% Canonical (map-free) encodable form: the token cell's `Adds` map and
%% remove frontier as sorted lists, context sorted, HLC.
canon({{Adds, R}, CC, Hlc}) ->
    {{lists:sort(maps:to_list(Adds)), lists:sort(R)}, lists:sort(CC), Hlc}.

%% @private
uncanon({{AddsL, R}, CC, Hlc}) ->
    {{maps:from_list(AddsL), R}, CC, Hlc}.
