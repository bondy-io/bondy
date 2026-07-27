%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% @doc Property-based tests for bondy_session_id.
%%
%% A session id is `{NodeHash}.{Rest}' where `NodeHash' is a base62 hash of the
%% owning node (self-locating routing prefix, from `bondy_config:node_hash/0')
%% and `Rest' is the 27-character base62 encoding of the 56-bit WAMP Session ID
%% plus 104 bits of random data. `to_external/1' still yields the embedded WAMP
%% id, unaffected by the prefix.
%%
%% `new/0' reads the node hash from `bondy_config', so the properties seed a
%% nodestring via `?SETUP' rather than depending on a running node.
%% @end
-module(prop_bondy_session_id).

-include_lib("proper/include/proper.hrl").

%% WAMP max ID is 2^53 = 9007199254740992
-define(MAX_EXT_ID, 9007199254740992).
-define(REST_LEN, 27).

%% Seed bondy_config once so bondy_session_id:new/0 (-> bondy_config:node_hash/0)
%% works without a running node.
-define(WITH_CFG(Prop), ?SETUP(fun setup/0, Prop)).

%% Properties
-export([
    prop_new_shape/0,
    prop_new_is_type/0,
    prop_new_with_external_id_roundtrip/0,
    prop_new_with_external_id_in_range/0,
    prop_external_id_preserved/0,
    prop_node_prefix_present/0,
    prop_uniqueness/0,
    prop_is_type_accepts_valid/0,
    prop_is_type_rejects_invalid/0,
    prop_segments_charset/0
]).

%% =============================================================================
%% Fixture
%% =============================================================================

setup() ->
    case bondy_config:get(nodestring, undefined) of
        undefined ->
            ok = bondy_config:set(nodestring, <<"proptest@127.0.0.1">>);
        _ ->
            ok
    end,
    fun() -> ok end.

%% =============================================================================
%% Generators
%% =============================================================================

%% Generate a valid WAMP external ID (1 to 2^53)
external_id() ->
    range(1, ?MAX_EXT_ID).

%% A run of dot-free bytes (lowercase letters) of a given length, so the value
%% cannot accidentally parse as a valid `{prefix}.{27-char rest}' session id.
dotfree_binary(Len) ->
    ?LET(
        Bytes,
        vector(Len, range($a, $z)),
        list_to_binary(Bytes)
    ).

%% Generate invalid session IDs: their `Rest' segment is never 27 chars.
invalid_session_id() ->
    oneof([
        %% Wrong length, no dot -> whole thing is the Rest segment
        ?LET(Len, range(1, ?REST_LEN - 1), dotfree_binary(Len)),
        ?LET(Len, range(?REST_LEN + 1, 50), dotfree_binary(Len)),
        %% Node-hash prefix present but Rest segment is the wrong length
        ?LET(
            {Hash, Len},
            {range(1, 999999999), oneof([range(1, ?REST_LEN - 1), range(?REST_LEN + 1, 40)])},
            <<(integer_to_binary(Hash))/binary, $., (list_to_binary(lists:duplicate(Len, $a)))/binary>>
        ),
        %% Not binary
        "not_a_binary",
        12345,
        {session, id},
        %% Empty
        <<>>
    ]).

%% =============================================================================
%% Properties: Generation
%% =============================================================================

%% Property: new/0 produces `{NodeHash}.{27-char Rest}'
prop_new_shape() ->
    ?WITH_CFG(?FORALL(
        _,
        term(),
        begin
            SessionId = bondy_session_id:new(),
            case binary:split(SessionId, <<$.>>) of
                [NodeHash, Rest] ->
                    NodeHash =/= <<>>
                        andalso byte_size(Rest) =:= ?REST_LEN;
                _ ->
                    false
            end
        end
    )).

%% Property: new/0 produces valid session IDs
prop_new_is_type() ->
    ?WITH_CFG(?FORALL(
        _,
        term(),
        bondy_session_id:is_type(bondy_session_id:new())
    )).

%% Property: the node-hash prefix of new/0 equals the local node hash
prop_node_prefix_present() ->
    ?WITH_CFG(?FORALL(
        _,
        term(),
        begin
            SessionId = bondy_session_id:new(),
            bondy_session_id:node_hash(SessionId) =:= bondy_session_id:node_hash()
        end
    )).

%% Property: new/1 with external ID produces valid session ID with that external ID
prop_new_with_external_id_roundtrip() ->
    ?WITH_CFG(?FORALL(
        ExtId,
        external_id(),
        begin
            SessionId = bondy_session_id:new(ExtId),
            bondy_session_id:to_external(SessionId) =:= ExtId
        end
    )).

%% Property: to_external always returns a value in the valid range
prop_new_with_external_id_in_range() ->
    ?WITH_CFG(?FORALL(
        ExtId,
        external_id(),
        begin
            SessionId = bondy_session_id:new(ExtId),
            ResultExtId = bondy_session_id:to_external(SessionId),
            ResultExtId >= 1 andalso ResultExtId =< ?MAX_EXT_ID
        end
    )).

%% Property: external ID is preserved through encode/decode (past the prefix)
prop_external_id_preserved() ->
    ?WITH_CFG(?FORALL(
        ExtId,
        external_id(),
        begin
            SessionId = bondy_session_id:new(ExtId),
            ExtractedId = bondy_session_id:to_external(SessionId),
            ExtractedId =:= ExtId
        end
    )).

%% =============================================================================
%% Properties: Uniqueness
%% =============================================================================

%% Property: Multiple calls to new/0 produce unique session IDs
prop_uniqueness() ->
    ?WITH_CFG(?FORALL(
        N,
        range(2, 100),
        begin
            SessionIds = [bondy_session_id:new() || _ <- lists:seq(1, N)],
            UniqueIds = lists:usort(SessionIds),
            length(SessionIds) =:= length(UniqueIds)
        end
    )).

%% =============================================================================
%% Properties: Type Checking
%% =============================================================================

%% Property: is_type accepts valid session IDs
prop_is_type_accepts_valid() ->
    ?WITH_CFG(?FORALL(
        ExtId,
        external_id(),
        bondy_session_id:is_type(bondy_session_id:new(ExtId))
    )).

%% Property: is_type rejects invalid terms
prop_is_type_rejects_invalid() ->
    ?FORALL(
        Invalid,
        invalid_session_id(),
        not bondy_session_id:is_type(Invalid)
    ).

%% =============================================================================
%% Properties: Encoding
%% =============================================================================

%% Property: both the node-hash segment and the Rest segment are base62, split
%% by exactly one `.'.
prop_segments_charset() ->
    ?WITH_CFG(?FORALL(
        _,
        term(),
        begin
            SessionId = bondy_session_id:new(),
            case binary:split(SessionId, <<$.>>, [global]) of
                [NodeHash, Rest] ->
                    NodeHash =/= <<>>
                        andalso is_valid_base62(NodeHash)
                        andalso is_valid_base62(Rest);
                _ ->
                    false
            end
        end
    )).

%% Helper: Check if all characters are valid base62
is_valid_base62(Bin) when is_binary(Bin) ->
    Base62Chars =
        <<"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz">>,
    lists:all(
        fun(Char) ->
            binary:match(Base62Chars, <<Char>>) =/= nomatch
        end,
        binary_to_list(Bin)
    ).
