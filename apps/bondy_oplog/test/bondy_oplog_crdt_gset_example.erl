%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% A minimal native grow-only set, built on `bondy_oplog_crdt_commutative`.
%%
%% This is the worked reference for the commutative ops-based CRDT pattern
%% and the subject of `bondy_oplog_crdt_commutative_test`. It uses ONLY the
%% commutative helper and `bondy_oplog_crdt` — never the deprecated
%% `bondy_oplog_fold` family. Production CRDTs implement this same
%% commutative contract; this stays in `test/` as the contract's
%% executable specification.
%%
%% State : an ordset of opaque elements.
%% Op    : {add, Element}.

-module(bondy_oplog_crdt_gset_example).

-behaviour(bondy_oplog_crdt).
-behaviour(bondy_oplog_crdt_commutative).

%% bondy_oplog_crdt
-export([causal_tier/0]).
-export([init/0]).
-export([interpret_cog/2]).
-export([query/2]).
%% projection seam
-export([to_value/1]).
-export([hlc/1]).
-export([encode_state/1]).
-export([decode_state/1]).
-export([order_independent/0]).
%% bondy_oplog_crdt_commutative
-export([apply_op/3]).

%% =============================================================================
%% bondy_oplog_crdt
%% =============================================================================

causal_tier() ->
    tier_0.

init() ->
    [].

%% Authoritative batch interpreter: delegate to the commutative helper.
interpret_cog(Events, State) ->
    bondy_oplog_crdt_commutative:interpret_cog(?MODULE, Events, State).

query(value, State) ->
    State.

%% =============================================================================
%% projection seam
%% =============================================================================

to_value(State) ->
    State.

%% A grow-only set carries no logical timestamp; nothing is ever GC-able
%% by HLC (every element is retained), so hlc/1 is 0.
hlc(_State) ->
    0.

encode_state(State) ->
    term_to_binary(State).

decode_state(Bin) ->
    binary_to_term(Bin).

order_independent() ->
    true.

%% =============================================================================
%% bondy_oplog_crdt_commutative
%% =============================================================================

apply_op(State, {add, Element}, _Key) ->
    ordsets:add_element(Element, State);
apply_op(State, _Other, _Key) ->
    State.
