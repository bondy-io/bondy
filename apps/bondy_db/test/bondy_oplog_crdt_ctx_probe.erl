%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Test-only fixture: a trivial commutative CRDT that exports the tier_2
%% `apply_op/4` step and RECORDS every `(Op, Context)` it is handed. Used
%% to prove the kernel/contract extension (PR-B) routes to `apply_op/4`
%% and threads the write's causal context (the event `meta`). State is the
%% reversed list of recorded `(Op, Context)` pairs.

-module(bondy_oplog_crdt_ctx_probe).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

-export([causal_tier/0]).
-export([init/0]).
-export([interpret_cog/2]).
-export([query/2]).
-export([to_value/1]).
-export([hlc/1]).
-export([encode_state/1]).
-export([decode_state/1]).
-export([order_independent/0]).
-export([apply_op/4]).
-export([context_of/1]).

causal_tier() -> tier_2.

init() -> [].

%% The tier_2 step: record the op and the causal context it arrived with.
apply_op(State, Op, _Key, Context) -> [{Op, Context} | State].

interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

order_independent() -> true.

%% The cell's "causal context" — here just the count of ops absorbed so
%% far, so a test can prove the stamp reads the CURRENT state (read-your-
%% writes): a second write to the same cell sees the first.
context_of(State) -> length(State).

query(value, State) -> to_value(State).

to_value(State) -> lists:reverse(State).

%% Monotone non-decreasing as ops are absorbed (required of `hlc/1`).
hlc(State) -> length(State).

encode_state(State) -> term_to_binary(State).

decode_state(Bin) -> binary_to_term(Bin).
