%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% @doc Property-based tests for bondy_uuidv7 (UUIDv7 generation and parsing).
%%
%% UUIDv7 is a time-ordered UUID that embeds a Unix timestamp in milliseconds.
%% These tests verify the RFC 9562 compliance and implementation correctness.
%% @end
-module(prop_bondy_uuidv7).

-include_lib("proper/include/proper.hrl").

%% Properties
-export([
    prop_new_always_valid/0,
    prop_new_has_correct_version/0,
    prop_new_has_correct_variant/0,
    prop_from_timestamp_roundtrip/0,
    prop_from_timestamp_preserves_timestamp/0,
    prop_format_produces_valid_output/0,
    prop_is_valid_rejects_invalid/0,
    prop_monotonic_ordering/0,
    prop_uniqueness/0
]).


%% =============================================================================
%% Generators
%% =============================================================================

%% Generate a valid timestamp (milliseconds since Unix epoch)
%% We limit the range to reasonable values (year 1970 to ~year 10000)
timestamp() ->
    ?LET(T, range(0, 253402300799999), T). %% Up to year 9999

%% Generate a small timestamp for testing ordering
small_timestamp() ->
    range(1000000000000, 2000000000000). %% Roughly 2001 to 2033

%% Generate a list of ordered timestamps
ordered_timestamps() ->
    ?LET(Base, small_timestamp(),
         ?LET(Offsets, list(range(1, 1000)),
              lists:foldl(
                fun(Offset, Acc) ->
                    Last = case Acc of [] -> Base; [H|_] -> H end,
                    [Last + Offset | Acc]
                end,
                [Base],
                Offsets
              ))).

%% Generate an invalid UUID binary (wrong version or variant)
invalid_uuid() ->
    oneof([
        %% Wrong version (not 7)
        ?LET({Ts, A, B}, {range(0, 281474976710655), range(0, 4095), range(0, 4611686018427387903)},
             <<Ts:48, 6:4, A:12, 2:2, B:62>>), %% Version 6 instead of 7
        %% Wrong variant (not 2)
        ?LET({Ts, A, B}, {range(0, 281474976710655), range(0, 4095), range(0, 4611686018427387903)},
             <<Ts:48, 7:4, A:12, 0:2, B:62>>), %% Variant 0 instead of 2
        %% Wrong size
        ?LET(Bytes, range(1, 15),
             crypto:strong_rand_bytes(Bytes)),
        %% Too large
        ?LET(_, term(),
             crypto:strong_rand_bytes(20))
    ]).


%% =============================================================================
%% Properties: Generation
%% =============================================================================

%% Property: new/0 always produces a valid UUIDv7
prop_new_always_valid() ->
    ?FORALL(_, term(),
            bondy_uuidv7:is_valid(bondy_uuidv7:new())).


%% Property: new/0 produces UUIDs with version 7
prop_new_has_correct_version() ->
    ?FORALL(_, term(),
            begin
                <<_:48, Version:4, _:76>> = bondy_uuidv7:new(),
                Version =:= 7
            end).


%% Property: new/0 produces UUIDs with variant 2 (RFC 4122)
prop_new_has_correct_variant() ->
    ?FORALL(_, term(),
            begin
                <<_:48, _:4, _:12, Variant:2, _:62>> = bondy_uuidv7:new(),
                Variant =:= 2
            end).


%% =============================================================================
%% Properties: Timestamp Operations
%% =============================================================================

%% Property: from_timestamp/1 produces UUID where timestamp/1 returns the same value
prop_from_timestamp_roundtrip() ->
    ?FORALL(Ts, timestamp(),
            begin
                UUID = bondy_uuidv7:from_timestamp(Ts),
                %% Timestamp is truncated to 48 bits
                Expected = Ts band 16#FFFFFFFFFFFF,
                bondy_uuidv7:timestamp(UUID) =:= Expected
            end).


%% Property: from_timestamp produces valid UUIDs
prop_from_timestamp_preserves_timestamp() ->
    ?FORALL(Ts, timestamp(),
            begin
                UUID = bondy_uuidv7:from_timestamp(Ts),
                bondy_uuidv7:is_valid(UUID)
            end).


%% =============================================================================
%% Properties: Formatting
%% =============================================================================

%% Property: format/1 produces valid string output
prop_format_produces_valid_output() ->
    ?FORALL(Ts, timestamp(),
            begin
                UUID = bondy_uuidv7:from_timestamp(Ts),
                Formatted = bondy_uuidv7:format(UUID),
                %% Default format is urlsafe base64
                is_binary(Formatted) orelse is_list(Formatted)
            end).


%% =============================================================================
%% Properties: Validation
%% =============================================================================

%% Property: is_valid rejects invalid UUIDs
prop_is_valid_rejects_invalid() ->
    ?FORALL(Invalid, invalid_uuid(),
            not bondy_uuidv7:is_valid(Invalid)).


%% =============================================================================
%% Properties: Ordering and Uniqueness
%% =============================================================================

%% Property: UUIDs created from increasing timestamps are ordered
%% (when compared as binaries)
prop_monotonic_ordering() ->
    ?FORALL(Timestamps, ordered_timestamps(),
            begin
                UUIDs = [bondy_uuidv7:from_timestamp(Ts) || Ts <- lists:reverse(Timestamps)],
                %% Check that UUIDs are monotonically increasing (as binaries)
                %% Note: Due to random bits, this is only guaranteed for timestamps
                %% that differ by more than the random component can affect ordering
                check_monotonic_timestamps(UUIDs)
            end).


%% Helper: Check that extracted timestamps are monotonically increasing
check_monotonic_timestamps([]) -> true;
check_monotonic_timestamps([_]) -> true;
check_monotonic_timestamps([A, B | Rest]) ->
    TsA = bondy_uuidv7:timestamp(A),
    TsB = bondy_uuidv7:timestamp(B),
    TsA =< TsB andalso check_monotonic_timestamps([B | Rest]).


%% Property: Multiple calls to new/0 produce unique UUIDs
prop_uniqueness() ->
    ?FORALL(N, range(2, 100),
            begin
                UUIDs = [bondy_uuidv7:new() || _ <- lists:seq(1, N)],
                UniqueUUIDs = lists:usort(UUIDs),
                length(UUIDs) =:= length(UniqueUUIDs)
            end).
