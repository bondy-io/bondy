%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% @doc Property-based tests for bondy_session_id.
%%
%% Session IDs consist of a 56-bit WAMP Session ID and 104 bits of random data,
%% encoded as a 27-character base62 string.
%% @end
-module(prop_bondy_session_id).

-include_lib("proper/include/proper.hrl").

%% WAMP max ID is 2^53 = 9007199254740992
-define(MAX_EXT_ID, 9007199254740992).

%% Properties
-export([
    prop_new_fixed_length/0,
    prop_new_is_type/0,
    prop_new_with_external_id_roundtrip/0,
    prop_new_with_external_id_in_range/0,
    prop_external_id_preserved/0,
    prop_uniqueness/0,
    prop_is_type_accepts_valid/0,
    prop_is_type_rejects_invalid/0,
    prop_base62_chars_only/0
]).


%% =============================================================================
%% Generators
%% =============================================================================

%% Generate a valid WAMP external ID (1 to 2^53)
external_id() ->
    range(1, ?MAX_EXT_ID).


%% Generate invalid session IDs
invalid_session_id() ->
    oneof([
        %% Wrong length
        ?LET(Len, range(1, 26), crypto:strong_rand_bytes(Len)),
        ?LET(Len, range(28, 50), crypto:strong_rand_bytes(Len)),
        %% Not binary
        ?LET(_, term(), "not_a_binary"),
        ?LET(_, term(), 12345),
        ?LET(_, term(), {session, id}),
        %% Empty
        <<>>
    ]).


%% =============================================================================
%% Properties: Generation
%% =============================================================================

%% Property: new/0 always produces a 27-character binary
prop_new_fixed_length() ->
    ?FORALL(_, term(),
            begin
                SessionId = bondy_session_id:new(),
                byte_size(SessionId) =:= 27
            end).


%% Property: new/0 produces valid session IDs
prop_new_is_type() ->
    ?FORALL(_, term(),
            bondy_session_id:is_type(bondy_session_id:new())).


%% Property: new/1 with external ID produces valid session ID with that external ID
prop_new_with_external_id_roundtrip() ->
    ?FORALL(ExtId, external_id(),
            begin
                SessionId = bondy_session_id:new(ExtId),
                bondy_session_id:to_external(SessionId) =:= ExtId
            end).


%% Property: to_external always returns a value in the valid range
prop_new_with_external_id_in_range() ->
    ?FORALL(ExtId, external_id(),
            begin
                SessionId = bondy_session_id:new(ExtId),
                ResultExtId = bondy_session_id:to_external(SessionId),
                ResultExtId >= 1 andalso ResultExtId =< ?MAX_EXT_ID
            end).


%% Property: external ID is preserved through encode/decode
prop_external_id_preserved() ->
    ?FORALL(ExtId, external_id(),
            begin
                SessionId = bondy_session_id:new(ExtId),
                %% The external ID should be extractable
                ExtractedId = bondy_session_id:to_external(SessionId),
                ExtractedId =:= ExtId
            end).


%% =============================================================================
%% Properties: Uniqueness
%% =============================================================================

%% Property: Multiple calls to new/0 produce unique session IDs
prop_uniqueness() ->
    ?FORALL(N, range(2, 100),
            begin
                SessionIds = [bondy_session_id:new() || _ <- lists:seq(1, N)],
                UniqueIds = lists:usort(SessionIds),
                length(SessionIds) =:= length(UniqueIds)
            end).


%% =============================================================================
%% Properties: Type Checking
%% =============================================================================

%% Property: is_type accepts valid session IDs
prop_is_type_accepts_valid() ->
    ?FORALL(ExtId, external_id(),
            bondy_session_id:is_type(bondy_session_id:new(ExtId))).


%% Property: is_type rejects invalid terms
prop_is_type_rejects_invalid() ->
    ?FORALL(Invalid, invalid_session_id(),
            not bondy_session_id:is_type(Invalid)).


%% =============================================================================
%% Properties: Encoding
%% =============================================================================

%% Property: Session IDs only contain valid base62 characters
prop_base62_chars_only() ->
    ?FORALL(_, term(),
            begin
                SessionId = bondy_session_id:new(),
                is_valid_base62(SessionId)
            end).


%% Helper: Check if all characters are valid base62
is_valid_base62(Bin) when is_binary(Bin) ->
    Base62Chars = <<"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz">>,
    lists:all(
        fun(Char) ->
            binary:match(Base62Chars, <<Char>>) =/= nomatch
        end,
        binary_to_list(Bin)
    ).
