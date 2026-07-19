%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_crdt_ew_flag).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Enable-Wins Flag (EWFlag) — tier_2 operation-based CRDT.

The op-based equivalent of the pure `pure_ewflag`. A boolean flag with
`enable` and `disable` where, when an enable and a disable are
**concurrent, enable wins** (the flag reads `true`). It is exactly an
add-wins set over a single implicit token: `enable` is an add, `disable`
is an observed-remove, and the flag is `true` iff that token has any live
dot.

Detecting concurrency needs true happens-before, so this is **tier_2**:
each write carries the writer's causal context (a version vector) in the
event `meta`, stamped by the substrate. The observed-remove machinery is
shared with `bondy_oplog_crdt_aw_set` / `bondy_oplog_crdt_aw_map` via
`bondy_oplog_crdt_aw_core`. For disable-wins resolution use
`bondy_oplog_crdt_dw_flag`.

## State

```
{Dots   :: #{dot() => true},   %% live enable dots (the token)
 Context :: bondy_dvvset:vector(),
 MaxHlc  :: hlc()}
```

## Operations

```
enable | disable
```

`enable` mints a fresh dot. `disable` drops every dot the writer's context
observed; a concurrent enable (un-observed dot) survives — enable-wins.
The value is `true` iff any enable dot is live.
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

-type origin() :: binary().
-type dot() :: bondy_oplog_crdt_aw_core:dot().
-type dots() :: #{dot() => true}.
-type context() :: bondy_dvvset:vector().
-type state() :: {dots(), context(), bondy_oplog_hlc:hlc()}.
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
    {#{}, [], 0}.

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
Apply one `enable` or `disable` with its observed causal `Context`.

- `enable`: insert the op's fresh dot. enable never drops dots.
- `disable`: drop every dot the writer observed; a concurrent enable
  (un-observed dot) survives — enable-wins.

The surviving dot-set is a pure function of the event set, so this eager
step equals the key-sorted `interpret_cog/2` fold.
""".
-spec apply_op(
    state(),
    op(),
    bondy_oplog_event:event_key(),
    Context :: context() | undefined
) -> state().

apply_op({Dots, CC, Hlc}, enable, Key, Context0) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    {
        Dots#{Dot => true},
        bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))
    };
apply_op({Dots, CC, Hlc}, disable, Key, Context0) ->
    Dot = bondy_oplog_crdt_aw_core:dot_of(Key),
    Ctx = bondy_oplog_crdt_aw_core:normalise_context(Context0),
    Dots1 = bondy_oplog_crdt_aw_core:drop_observed(Dots, Ctx),
    {Dots1, bondy_oplog_crdt_aw_core:cc_absorb(CC, Ctx, Dot),
        erlang:max(Hlc, key_hlc(Key))}.

%% =============================================================================
%% projection seam
%% =============================================================================

-doc "The flag's value: `true` iff any enable dot is live.".
-spec to_value(state()) -> boolean().

to_value({Dots, _CC, _Hlc}) ->
    map_size(Dots) > 0.

-doc "The cell's current causal context, stamped into the next write.".
-spec context_of(state()) -> context().

context_of({_Dots, CC, _Hlc}) ->
    CC.

-doc """
Reap the causal-context entries of permanently-retired origins (the
membership-driven GC, mirroring `bondy_oplog_crdt_aw_set`). Value-
preserving: drops a retired origin's `CC` entry only when it holds no live
enable dot. Idempotent.
""".
-spec reap_origins(state(), [origin()]) -> {state(), Reaped :: [origin()]}.

reap_origins({Dots, CC, Hlc}, Retired) ->
    Live = live_origins(Dots),
    Reaped = [
        O
     || {O, _S} <- CC,
        lists:member(O, Retired),
        not sets:is_element(O, Live)
    ],
    case Reaped of
        [] ->
            {{Dots, CC, Hlc}, []};
        _ ->
            CC1 = [{O, S} || {O, S} <- CC, not lists:member(O, Reaped)],
            {{Dots, CC1, Hlc}, lists:usort(Reaped)}
    end.

-spec hlc(state()) -> bondy_oplog_hlc:hlc().

hlc({_Dots, _CC, Hlc}) ->
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

encode_state({_Dots, _CC, _Hlc} = State) ->
    <<?ENC_V1, (term_to_binary(canon(State)))/binary>>.

-spec decode_state(binary()) -> state().

decode_state(<<?ENC_V1, Bin/binary>>) ->
    %% C-2: `[safe]` — decodes peer-shipped CRDT state on the AAE merge path.
    uncanon(binary_to_term(Bin, [safe])).

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
key_hlc(Key) ->
    bondy_oplog_event:key_hlc(Key).

%% @private
live_origins(Dots) ->
    maps:fold(
        fun({O, _S}, _V, Acc) -> sets:add_element(O, Acc) end,
        sets:new([{version, 2}]),
        Dots
    ).

%% @private
%% Canonical (map-free) encodable form: dots as a sorted list, context
%% sorted by origin, HLC.
canon({Dots, CC, Hlc}) ->
    {lists:sort(maps:keys(Dots)), lists:sort(CC), Hlc}.

%% @private
uncanon({DotsL, CC, Hlc}) ->
    {maps:from_keys(DotsL, true), CC, Hlc}.
