%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(prop_bondy_itc).
-moduledoc """
Property-based tests for bondy_itc (Interval Tree Clocks).

Tests are based on the properties defined in the ITC paper:
"Interval Tree Clocks: A Logical Clock for Dynamic Systems"
by Paulo Sérgio Almeida, Carlos Baquero, and Victor Fonte (2008)
""".

-include_lib("proper/include/proper.hrl").

%% Properties
-export([
    prop_seed_is_valid/0,
    prop_fork_produces_valid_stamps/0,
    prop_fork_produces_disjoint_ids/0,
    prop_fork_preserves_event/0,
    prop_event_increases_stamp/0,
    prop_event_preserves_validity/0,
    prop_join_is_commutative/0,
    prop_join_is_associative/0,
    prop_join_produces_valid_stamp/0,
    prop_leq_is_reflexive/0,
    prop_leq_is_transitive/0,
    prop_leq_is_antisymmetric/0,
    prop_encode_decode_roundtrip/0,
    prop_peek_preserves_event/0,
    prop_peek_creates_anonymous/0,
    prop_operations_preserve_validity/0
]).


%% =============================================================================
%% Generators
%% =============================================================================

%% Generate a valid stamp by starting from seed and applying random operations
stamp() ->
    ?SIZED(Size, stamp(Size)).

stamp(0) ->
    bondy_itc:seed();

stamp(Size) ->
    ?LET(S, stamp(Size div 2),
         ?LET(Op, oneof([fork_left, fork_right, event, peek_original]),
              apply_op(Op, S))).

apply_op(fork_left, S) ->
    {Left, _Right} = bondy_itc:fork(S),
    Left;

apply_op(fork_right, S) ->
    {_Left, Right} = bondy_itc:fork(S),
    Right;

apply_op(event, {0, _} = S) ->
    %% Anonymous stamps cannot register events, return as-is
    S;

apply_op(event, S) ->
    bondy_itc:event(S);

apply_op(peek_original, S) ->
    {_Anonymous, Original} = bondy_itc:peek(S),
    Original.


%% Generate a pair of stamps that have a common ancestor
stamp_pair() ->
    ?LET(Ancestor, stamp(),
         begin
             {S1, S2} = bondy_itc:fork(Ancestor),
             {S1, S2}
         end).


%% Generate three stamps with a common ancestor (for associativity tests)
stamp_triple() ->
    ?LET(Ancestor, stamp(),
         begin
             {S1, Tmp} = bondy_itc:fork(Ancestor),
             {S2, S3} = bondy_itc:fork(Tmp),
             {S1, S2, S3}
         end).


%% Generate a non-anonymous stamp (one that can register events)
non_anonymous_stamp() ->
    ?SUCHTHAT(S, stamp(), element(1, S) =/= 0).


%% =============================================================================
%% Properties: Core Invariants
%% =============================================================================

%% Property: seed() produces a valid stamp
prop_seed_is_valid() ->
    ?FORALL(_, term(),
            bondy_itc:is_valid(bondy_itc:seed())).


%% Property: fork produces two valid stamps
prop_fork_produces_valid_stamps() ->
    ?FORALL(S, stamp(),
            begin
                {S1, S2} = bondy_itc:fork(S),
                bondy_itc:is_valid(S1) andalso bondy_itc:is_valid(S2)
            end).


%% Property: fork produces stamps with disjoint IDs
%% When joined, the IDs should sum to the original ID
prop_fork_produces_disjoint_ids() ->
    ?FORALL(S, stamp(),
            begin
                {S1, S2} = bondy_itc:fork(S),
                %% Joining forked stamps should reconstruct original event
                Joined = bondy_itc:join(S1, S2),
                %% The event component should be equal
                element(2, Joined) =:= element(2, S)
            end).


%% Property: fork preserves the event component in both stamps
prop_fork_preserves_event() ->
    ?FORALL(S, stamp(),
            begin
                {S1, S2} = bondy_itc:fork(S),
                Event = element(2, S),
                element(2, S1) =:= Event andalso element(2, S2) =:= Event
            end).


%% =============================================================================
%% Properties: Event Operation
%% =============================================================================

%% Property: event() increases the stamp (the result is strictly greater)
prop_event_increases_stamp() ->
    ?FORALL(S, non_anonymous_stamp(),
            begin
                S1 = bondy_itc:event(S),
                %% After event, S1 should be greater than or equal to S
                bondy_itc:leq(S, S1) andalso
                %% And S1 should NOT be less than or equal to S
                %% (i.e., it's strictly greater or concurrent)
                not bondy_itc:leq(S1, S)
            end).


%% Property: event preserves validity
prop_event_preserves_validity() ->
    ?FORALL(S, non_anonymous_stamp(),
            bondy_itc:is_valid(bondy_itc:event(S))).


%% =============================================================================
%% Properties: Join Operation (Lattice Properties)
%% =============================================================================

%% Property: join is commutative - join(A, B) == join(B, A)
prop_join_is_commutative() ->
    ?FORALL({S1, S2}, stamp_pair(),
            begin
                J1 = bondy_itc:join(S1, S2),
                J2 = bondy_itc:join(S2, S1),
                J1 =:= J2
            end).


%% Property: join is associative - join(A, join(B, C)) == join(join(A, B), C)
prop_join_is_associative() ->
    ?FORALL({S1, S2, S3}, stamp_triple(),
            begin
                %% join(S1, join(S2, S3))
                J1 = bondy_itc:join(S1, bondy_itc:join(S2, S3)),
                %% join(join(S1, S2), S3)
                J2 = bondy_itc:join(bondy_itc:join(S1, S2), S3),
                J1 =:= J2
            end).


%% Property: join produces a valid stamp
prop_join_produces_valid_stamp() ->
    ?FORALL({S1, S2}, stamp_pair(),
            bondy_itc:is_valid(bondy_itc:join(S1, S2))).


%% =============================================================================
%% Properties: Partial Order (leq)
%% =============================================================================

%% Property: leq is reflexive - leq(S, S) == true
prop_leq_is_reflexive() ->
    ?FORALL(S, stamp(),
            bondy_itc:leq(S, S)).


%% Property: leq is transitive - if leq(A, B) and leq(B, C), then leq(A, C)
prop_leq_is_transitive() ->
    ?FORALL(S, non_anonymous_stamp(),
            begin
                %% Create a chain: S <= S' <= S''
                S1 = bondy_itc:event(S),
                S2 = bondy_itc:event(S1),
                %% If S <= S1 and S1 <= S2, then S <= S2
                (bondy_itc:leq(S, S1) andalso bondy_itc:leq(S1, S2))
                    =:= bondy_itc:leq(S, S2)
            end).


%% Property: leq is antisymmetric - if leq(A, B) and leq(B, A), then A's event == B's event
prop_leq_is_antisymmetric() ->
    ?FORALL(S, stamp(),
            begin
                %% For the same stamp, antisymmetry should hold
                (bondy_itc:leq(S, S) andalso bondy_itc:leq(S, S))
                    =:= (element(2, S) =:= element(2, S))
            end).


%% =============================================================================
%% Properties: Encoding/Decoding
%% =============================================================================

%% Property: encode/decode is a roundtrip
prop_encode_decode_roundtrip() ->
    ?FORALL(S, stamp(),
            begin
                Encoded = bondy_itc:encode(S),
                Decoded = bondy_itc:decode(Encoded),
                S =:= Decoded
            end).


%% =============================================================================
%% Properties: Peek Operation
%% =============================================================================

%% Property: peek preserves event component in both stamps
prop_peek_preserves_event() ->
    ?FORALL(S, stamp(),
            begin
                {Anonymous, Original} = bondy_itc:peek(S),
                Event = element(2, S),
                element(2, Anonymous) =:= Event andalso
                element(2, Original) =:= Event
            end).


%% Property: peek creates an anonymous stamp (Id = 0)
prop_peek_creates_anonymous() ->
    ?FORALL(S, stamp(),
            begin
                {Anonymous, Original} = bondy_itc:peek(S),
                %% Anonymous stamp has Id = 0
                element(1, Anonymous) =:= 0 andalso
                %% Original keeps the same Id
                element(1, Original) =:= element(1, S)
            end).


%% =============================================================================
%% Properties: General Validity
%% =============================================================================

%% Property: all operations preserve stamp validity
prop_operations_preserve_validity() ->
    ?FORALL(S, non_anonymous_stamp(),
            begin
                %% Test all operations
                {S1, S2} = bondy_itc:fork(S),
                S3 = bondy_itc:event(S),
                S4 = bondy_itc:join(S1, S2),
                {S5, S6} = bondy_itc:peek(S),

                bondy_itc:is_valid(S1) andalso
                bondy_itc:is_valid(S2) andalso
                bondy_itc:is_valid(S3) andalso
                bondy_itc:is_valid(S4) andalso
                bondy_itc:is_valid(S5) andalso
                bondy_itc:is_valid(S6)
            end).
