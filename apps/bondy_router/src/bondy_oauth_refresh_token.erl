%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oauth_refresh_token).
-moduledoc """
Generates, parses and verifies OAuth refresh tokens. Supports a plain
sortable variant and an HMAC-protected variant that adds integrity
protection.
""".

-define(SCHEME, "bondy:rtoken:").
-define(VARIANT1, ~"1").
-define(VARIANT2, ~"2").
-define(REFRESH_TOKEN_LEN, 32).

-type secret_key() :: binary().
-type timestamp() :: non_neg_integer().
-type components() :: #{
    variant := binary(),
    key => term(),
    id => binary()
}.

-export_type([components/0]).
-export_type([secret_key/0]).
-export_type([timestamp/0]).

-export([is_valid/1]).
-export([is_valid/2]).
-export([new/1]).
-export([new/2]).
-export([verify/2]).
-export([parse/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec new(Key :: term()) -> {Id :: binary(), Token :: binary()}.

new(Key) ->
    KeyPart = encode_key_part(Key),
    UUID = bondy_connect_uuidv7:new(),

    %% Add additional random bytes for extra entropy

    %% 64 additional random bits
    MinRandomBytes = 8,
    ConfigLen = crypto:strong_rand_bytes(?REFRESH_TOKEN_LEN),
    Len = min(byte_size(UUID) + MinRandomBytes, ConfigLen) - MinRandomBytes,
    ExtraEntropy = crypto:strong_rand_bytes(Len),

    Id = base64_encode(<<UUID/binary, ExtraEntropy/binary>>),
    TokenData = iolist_to_binary([?SCHEME, ?VARIANT1, ":", Id, ".", KeyPart]),
    {Id, TokenData}.

-doc """
Generate HMAC-protected sortable token (for improved security).
""".
-spec new(Key :: term(), SecretKey :: secret_key()) ->
    {Id :: binary(), Token :: binary()}.

new(Key, SecretKey) ->
    KeyPart = encode_key_part(Key),
    UUID = bondy_connect_uuidv7:new(),

    %% Create HMAC for integrity protection
    HMAC = crypto:mac(hmac, sha256, SecretKey, UUID),
    %% Use first 128 bits
    HMACTruncated = binary:part(HMAC, 0, 16),

    Id = base64_encode(<<UUID/binary, HMACTruncated/binary>>),
    TokenData = iolist_to_binary([?SCHEME, ?VARIANT2, ":", Id, $., KeyPart]),
    {Id, TokenData}.

parse(<<?SCHEME, Variant:1/binary, ":", TokenData/binary>>) when
    Variant == ?VARIANT1 orelse Variant == ?VARIANT2
->
    try
        case binary:split(TokenData, ~".", [global]) of
            [IdBin, KeyBin] ->
                Components = do_parse(Variant, IdBin, KeyBin),
                {ok, Components};
            _ ->
                throw(invalid_token)
        end
    catch
        throw:Reason ->
            {error, Reason};
        _:_ ->
            {error, invalid_token}
    end;
parse(_) ->
    {error, invalid_token}.

-doc """
Returns `true` if refresh token is valid, otherwise `false`.
""".
-spec is_valid(binary()) -> boolean().

is_valid(Token) ->
    resulto:is_ok(parse(Token)).

-doc """
Returns `true` if refresh token is valid, otherwise `false`.
""".
-spec is_valid(binary(), binary()) -> boolean().

is_valid(Token, SecretKey) ->
    resulto:is_ok(verify(Token, SecretKey)).

-doc """
Verify HMAC-protected token.
""".
-spec verify(binary(), secret_key()) ->
    {ok, components()} | {error, invalid_token | invalid_hmac}.

verify(<<?SCHEME, Variant:1/binary, ":", TokenData/binary>>, SecretKey) when
    Variant == ?VARIANT2
->
    try
        case binary:split(TokenData, ~".", [global]) of
            [IdBin, KeyBin] ->
                Components = do_parse(?VARIANT2, IdBin, KeyBin),
                ok = do_verify(Components, SecretKey),
                {ok, Components};
            _ ->
                throw(invalid_token)
        end
    catch
        throw:Reason ->
            {error, Reason};
        _:_ ->
            {error, invalid_token}
    end;
verify(_, _) ->
    {error, invalid_token}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
encode_key_part(Term) ->
    base64_encode(term_to_binary(Term)).

%% @private
decode_key_part(Term) when is_binary(Term) ->
    %% `[safe]` prevents atom-table exhaustion from crafted client tokens.
    %% `parse/1` already catches the resulting `badarg` as `invalid_token`.
    binary_to_term(base64_decode(Term), [safe]).

%% @private
base64_encode(Term) ->
    base64:encode(Term, #{mode => urlsafe, padding => false}).

%% @private
base64_decode(Bin) ->
    base64:decode(Bin, #{mode => urlsafe, padding => false}).

%% @private
do_parse(Variant, IdBin, KeyBin) ->
    KeyPart = decode_key_part(KeyBin),
    #{
        variant => Variant,
        key => KeyPart,
        id => IdBin
    }.

%% @private
do_verify(#{variant := ?VARIANT2, id := IdBin}, SecretKey) ->
    IdPart = base64_decode(IdBin),
    byte_size(IdPart) == 32 orelse throw(invalid_token),

    <<UUID:16/binary, ReceivedHMAC:16/binary>> = IdPart,

    ExpectedHMAC = crypto:mac(hmac, sha256, SecretKey, UUID),
    ExpectedHMACTruncated = binary:part(ExpectedHMAC, 0, 16),

    crypto:hash_equals(ReceivedHMAC, ExpectedHMACTruncated) orelse
        throw(invalid_hmac),

    ok.

%% =============================================================================
%% EUNIT
%% =============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% TEST FIXTURES
%% =============================================================================

test_secret_key() ->
    <<"test_secret_key_for_hmac_verification">>.

wrong_secret_key() ->
    <<"wrong_secret_key_for_testing">>.

test_binary_key() ->
    <<"test_binary_key">>.

test_term_key() ->
    {user_id, 12345, <<"session_data">>}.

test_atom_key() ->
    test_atom.

test_number_key() ->
    42.

extract_variant(Token) ->
    case Token of
        <<"bondy:rtoken:", Variant:1/binary, ":", _/binary>> ->
            Variant;
        _ ->
            undefined
    end.

extract_scheme(Token) ->
    case Token of
        <<"bondy:rtoken:", _/binary>> ->
            <<"bondy:rtoken:">>;
        _ ->
            undefined
    end.

%% =============================================================================
%% TESTS
%% =============================================================================

%% -----------------------------------------------------------------------------
%% new/1 tests (Variant 1 - no HMAC)
%% -----------------------------------------------------------------------------

new_with_binary_key_test() ->
    Key = test_binary_key(),
    {Id, Token} = bondy_oauth_refresh_token:new(Key),

    ?assert(is_binary(Id)),
    ?assert(is_binary(Token)),
    ?assert(byte_size(Id) > 0),
    ?assert(byte_size(Token) > 0),

    ?assertEqual(<<"bondy:rtoken:">>, extract_scheme(Token)),

    ?assertEqual(?VARIANT1, extract_variant(Token)),

    ?assert(bondy_oauth_refresh_token:is_valid(Token)).

new_with_term_key_test() ->
    Key = test_term_key(),
    {Id, Token} = bondy_oauth_refresh_token:new(Key),

    ?assert(is_binary(Id)),
    ?assert(is_binary(Token)),
    ?assertEqual(<<"bondy:rtoken:">>, extract_scheme(Token)),
    ?assertEqual(?VARIANT1, extract_variant(Token)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token)).

new_with_atom_key_test() ->
    Key = test_atom_key(),
    {Id, Token} = bondy_oauth_refresh_token:new(Key),

    ?assert(is_binary(Id)),
    ?assert(is_binary(Token)),
    ?assertEqual(<<"bondy:rtoken:">>, extract_scheme(Token)),
    ?assertEqual(?VARIANT1, extract_variant(Token)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token)).

new_with_number_key_test() ->
    Key = test_number_key(),
    {Id, Token} = bondy_oauth_refresh_token:new(Key),

    ?assert(is_binary(Id)),
    ?assert(is_binary(Token)),
    ?assertEqual(<<"bondy:rtoken:">>, extract_scheme(Token)),
    ?assertEqual(?VARIANT1, extract_variant(Token)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token)).

new_generates_unique_tokens_test() ->
    Key = test_binary_key(),
    {Id1, Token1} = bondy_oauth_refresh_token:new(Key),
    {Id2, Token2} = bondy_oauth_refresh_token:new(Key),

    ?assertNotEqual(Id1, Id2),
    ?assertNotEqual(Token1, Token2),

    ?assert(bondy_oauth_refresh_token:is_valid(Token1)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token2)).

%% -----------------------------------------------------------------------------
%% new/2 tests (Variant 2 - with HMAC)
%% -----------------------------------------------------------------------------

new_with_secret_key_binary_key_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    {Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    ?assert(is_binary(Id)),
    ?assert(is_binary(Token)),
    ?assertEqual(<<"bondy:rtoken:">>, extract_scheme(Token)),
    ?assertEqual(?VARIANT2, extract_variant(Token)),

    ?assert(bondy_oauth_refresh_token:is_valid(Token, SecretKey)),

    ?assertNot(bondy_oauth_refresh_token:is_valid(Token, wrong_secret_key())).

new_with_secret_key_term_key_test() ->
    Key = test_term_key(),
    SecretKey = test_secret_key(),
    {Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    ?assert(is_binary(Id)),
    ?assert(is_binary(Token)),
    ?assertEqual(?VARIANT2, extract_variant(Token)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token, SecretKey)).

new_with_secret_generates_unique_tokens_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    {Id1, Token1} = bondy_oauth_refresh_token:new(Key, SecretKey),
    {Id2, Token2} = bondy_oauth_refresh_token:new(Key, SecretKey),

    ?assertNotEqual(Id1, Id2),
    ?assertNotEqual(Token1, Token2),

    ?assert(bondy_oauth_refresh_token:is_valid(Token1, SecretKey)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token2, SecretKey)).

%% -----------------------------------------------------------------------------
%% parse/1 tests
%% -----------------------------------------------------------------------------

parse_valid_variant1_token_test() ->
    Key = test_binary_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key),

    Result = bondy_oauth_refresh_token:parse(Token),

    ?assertMatch({ok, _}, Result),
    {ok, Components} = Result,
    ?assertEqual(?VARIANT1, maps:get(variant, Components)),
    ?assert(maps:is_key(key, Components)),
    ?assert(maps:is_key(id, Components)).

parse_valid_variant2_token_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    Result = bondy_oauth_refresh_token:parse(Token),

    ?assertMatch({ok, _}, Result),
    {ok, Components} = Result,
    ?assertEqual(?VARIANT2, maps:get(variant, Components)),
    ?assert(maps:is_key(key, Components)),
    ?assert(maps:is_key(id, Components)).

parse_invalid_scheme_test() ->
    InvalidToken = <<"invalid:scheme:token">>,
    Result = bondy_oauth_refresh_token:parse(InvalidToken),
    ?assertEqual({error, invalid_token}, Result).

parse_invalid_variant_test() ->
    InvalidToken = <<"bondy:rtoken:99:invalid_data">>,
    Result = bondy_oauth_refresh_token:parse(InvalidToken),
    ?assertEqual({error, invalid_token}, Result).

parse_malformed_token_no_dot_test() ->
    InvalidToken = <<"bondy:rtoken:1:nodot">>,
    Result = bondy_oauth_refresh_token:parse(InvalidToken),
    ?assertEqual({error, invalid_token}, Result).

parse_malformed_token_multiple_dots_test() ->
    InvalidToken = <<"bondy:rtoken:1:part1.part2.part3">>,
    Result = bondy_oauth_refresh_token:parse(InvalidToken),
    ?assertEqual({error, invalid_token}, Result).

parse_empty_token_test() ->
    Result = bondy_oauth_refresh_token:parse(<<>>),
    ?assertEqual({error, invalid_token}, Result).

parse_truncated_token_test() ->
    TruncatedToken = <<"bondy:rtoken:">>,
    Result = bondy_oauth_refresh_token:parse(TruncatedToken),
    ?assertEqual({error, invalid_token}, Result).

%% -----------------------------------------------------------------------------
%% is_valid/1 tests
%% -----------------------------------------------------------------------------

is_valid_variant1_token_test() ->
    Key = test_binary_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key),
    ?assert(bondy_oauth_refresh_token:is_valid(Token)).

is_valid_variant2_token_without_secret_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    %% is_valid/1 should work for variant 2 tokens (just parsing)
    ?assert(bondy_oauth_refresh_token:is_valid(Token)).

is_valid_invalid_token_test() ->
    InvalidToken = <<"invalid_token">>,
    ?assertNot(bondy_oauth_refresh_token:is_valid(InvalidToken)).

is_valid_empty_token_test() ->
    ?assertNot(bondy_oauth_refresh_token:is_valid(<<>>)).

is_valid_malformed_token_test() ->
    MalformedToken = <<"bondy:rtoken:1:malformed">>,
    ?assertNot(bondy_oauth_refresh_token:is_valid(MalformedToken)).

%% -----------------------------------------------------------------------------
%% is_valid/2 tests
%% -----------------------------------------------------------------------------

is_valid_with_correct_secret_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    ?assert(bondy_oauth_refresh_token:is_valid(Token, SecretKey)).

is_valid_with_wrong_secret_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    ?assertNot(bondy_oauth_refresh_token:is_valid(Token, wrong_secret_key())).

is_valid_variant1_token_with_secret_test() ->
    Key = test_binary_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key),
    SecretKey = test_secret_key(),

    ?assertNot(bondy_oauth_refresh_token:is_valid(Token, SecretKey)).

is_valid_invalid_token_with_secret_test() ->
    InvalidToken = <<"invalid_token">>,
    SecretKey = test_secret_key(),
    ?assertNot(bondy_oauth_refresh_token:is_valid(InvalidToken, SecretKey)).

%% -----------------------------------------------------------------------------
%% verify/2 tests
%% -----------------------------------------------------------------------------

verify_valid_token_correct_secret_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    Result = bondy_oauth_refresh_token:verify(Token, SecretKey),

    ?assertMatch({ok, _}, Result),
    {ok, Components} = Result,
    ?assertEqual(?VARIANT2, maps:get(variant, Components)),
    ?assert(maps:is_key(key, Components)),
    ?assert(maps:is_key(id, Components)).

verify_valid_token_wrong_secret_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    Result = bondy_oauth_refresh_token:verify(Token, wrong_secret_key()),
    ?assertEqual({error, invalid_hmac}, Result).

verify_variant1_token_test() ->
    Key = test_binary_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key),
    SecretKey = test_secret_key(),

    Result = bondy_oauth_refresh_token:verify(Token, SecretKey),
    ?assertEqual({error, invalid_token}, Result).

verify_invalid_token_test() ->
    InvalidToken = <<"invalid_token">>,
    SecretKey = test_secret_key(),

    Result = bondy_oauth_refresh_token:verify(InvalidToken, SecretKey),
    ?assertEqual({error, invalid_token}, Result).

verify_malformed_variant2_token_test() ->
    MalformedToken = <<"bondy:rtoken:", 2:8, "malformed_data">>,
    SecretKey = test_secret_key(),

    Result = bondy_oauth_refresh_token:verify(MalformedToken, SecretKey),
    ?assertEqual({error, invalid_token}, Result).

verify_variant2_token_no_dot_test() ->
    InvalidToken = <<"bondy:rtoken:", 2:8, "nodot">>,
    SecretKey = test_secret_key(),

    Result = bondy_oauth_refresh_token:verify(InvalidToken, SecretKey),
    ?assertEqual({error, invalid_token}, Result).

%% -----------------------------------------------------------------------------
%% Token component tests
%% -----------------------------------------------------------------------------

token_components_consistency_test() ->
    Key = test_term_key(),
    {Id, Token} = bondy_oauth_refresh_token:new(Key),

    {ok, Components} = bondy_oauth_refresh_token:parse(Token),

    ParsedId = maps:get(id, Components),
    ?assertEqual(Id, ParsedId),

    ?assertEqual(?VARIANT1, maps:get(variant, Components)),

    ?assert(maps:is_key(key, Components)).

token_components_consistency_variant2_test() ->
    Key = test_term_key(),
    SecretKey = test_secret_key(),
    {Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    {ok, Components} = bondy_oauth_refresh_token:verify(Token, SecretKey),

    ParsedId = maps:get(id, Components),
    ?assertEqual(Id, ParsedId),

    ?assertEqual(?VARIANT2, maps:get(variant, Components)),

    ?assert(maps:is_key(key, Components)).

%% -----------------------------------------------------------------------------
%% Key encoding/decoding tests
%% -----------------------------------------------------------------------------

key_roundtrip_binary_test() ->
    Key = test_binary_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key),

    {ok, Components} = bondy_oauth_refresh_token:parse(Token),
    ParsedKey = maps:get(key, Components),

    ?assertEqual(Key, ParsedKey).

key_roundtrip_term_test() ->
    Key = test_term_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key),

    {ok, Components} = bondy_oauth_refresh_token:parse(Token),
    ParsedKey = maps:get(key, Components),

    ?assert(not is_binary(ParsedKey)).

key_roundtrip_atom_test() ->
    Key = test_atom_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key),

    {ok, Components} = bondy_oauth_refresh_token:parse(Token),
    ParsedKey = maps:get(key, Components),

    ?assert(not is_binary(ParsedKey)).

key_roundtrip_number_test() ->
    Key = test_number_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key),

    {ok, Components} = bondy_oauth_refresh_token:parse(Token),
    ParsedKey = maps:get(key, Components),

    ?assert(not is_binary(ParsedKey)).

%% -----------------------------------------------------------------------------
%% Security tests
%% -----------------------------------------------------------------------------

hmac_security_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    ?assertMatch({ok, _}, bondy_oauth_refresh_token:verify(Token, SecretKey)),

    ?assertEqual(
        {error, invalid_hmac},
        bondy_oauth_refresh_token:verify(Token, wrong_secret_key())
    ),

    ?assertEqual(
        {error, invalid_hmac}, bondy_oauth_refresh_token:verify(Token, <<>>)
    ).

token_tampering_resistance_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    ?assertMatch({ok, _}, bondy_oauth_refresh_token:verify(Token, SecretKey)),

    TamperedToken = <<Token/binary, "x">>,
    ?assertEqual(
        {error, invalid_token},
        bondy_oauth_refresh_token:verify(TamperedToken, SecretKey)
    ),

    <<Prefix:8/binary, Byte:8, Rest/binary>> = Token,
    FlippedToken = <<Prefix/binary, (Byte bxor 1):8, Rest/binary>>,
    Result = bondy_oauth_refresh_token:verify(FlippedToken, SecretKey),
    ?assert(
        Result == {error, invalid_token} orelse Result == {error, invalid_hmac}
    ).

%% -----------------------------------------------------------------------------
%% Edge cases and error handling
%% -----------------------------------------------------------------------------

edge_case_empty_key_test() ->
    Key = <<>>,
    {Id, Token} = bondy_oauth_refresh_token:new(Key),

    ?assert(is_binary(Id)),
    ?assert(is_binary(Token)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token)).

edge_case_large_key_test() ->
    Key = crypto:strong_rand_bytes(1024),
    {Id, Token} = bondy_oauth_refresh_token:new(Key),

    ?assert(is_binary(Id)),
    ?assert(is_binary(Token)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token)).

edge_case_unicode_key_test() ->
    Key = <<"こんにちは世界"/utf8>>,
    {Id, Token} = bondy_oauth_refresh_token:new(Key),

    ?assert(is_binary(Id)),
    ?assert(is_binary(Token)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token)).

edge_case_complex_term_key_test() ->
    Key = {complex, [term, {with, nested}, <<"data">>], #{map => value}},
    {Id, Token} = bondy_oauth_refresh_token:new(Key),

    ?assert(is_binary(Id)),
    ?assert(is_binary(Token)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token)).

%% -----------------------------------------------------------------------------
%% Performance and entropy tests
%% -----------------------------------------------------------------------------

entropy_test() ->
    Key = test_binary_key(),
    Tokens = [bondy_oauth_refresh_token:new(Key) || _ <- lists:seq(1, 100)],

    {Ids, TokenStrings} = lists:unzip(Tokens),

    UniqueIds = sets:from_list(Ids),
    ?assertEqual(100, sets:size(UniqueIds)),

    UniqueTokens = sets:from_list(TokenStrings),
    ?assertEqual(100, sets:size(UniqueTokens)),

    lists:foreach(
        fun({_Id, Token}) ->
            ?assert(bondy_oauth_refresh_token:is_valid(Token))
        end,
        Tokens
    ).

entropy_with_hmac_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),
    Tokens = [
        bondy_oauth_refresh_token:new(Key, SecretKey)
     || _ <- lists:seq(1, 50)
    ],

    {Ids, TokenStrings} = lists:unzip(Tokens),

    UniqueIds = sets:from_list(Ids),
    ?assertEqual(50, sets:size(UniqueIds)),

    UniqueTokens = sets:from_list(TokenStrings),
    ?assertEqual(50, sets:size(UniqueTokens)),

    lists:foreach(
        fun({_Id, Token}) ->
            ?assert(bondy_oauth_refresh_token:is_valid(Token, SecretKey))
        end,
        Tokens
    ).

%% -----------------------------------------------------------------------------
%% Integration tests
%% -----------------------------------------------------------------------------

full_lifecycle_variant1_test() ->
    Key = {user, 123, <<"session">>},

    {Id, Token} = bondy_oauth_refresh_token:new(Key),

    ?assert(bondy_oauth_refresh_token:is_valid(Token)),

    {ok, Components} = bondy_oauth_refresh_token:parse(Token),

    ?assertEqual(Id, maps:get(id, Components)),
    ?assertEqual(?VARIANT1, maps:get(variant, Components)),
    ?assert(maps:is_key(key, Components)).

full_lifecycle_variant2_test() ->
    Key = {user, 456, <<"secure_session">>},
    SecretKey = test_secret_key(),

    {Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    ?assert(bondy_oauth_refresh_token:is_valid(Token, SecretKey)),

    {ok, Components1} = bondy_oauth_refresh_token:verify(Token, SecretKey),

    {ok, Components2} = bondy_oauth_refresh_token:parse(Token),

    ?assertEqual(Components1, Components2),
    ?assertEqual(Id, maps:get(id, Components1)),
    ?assertEqual(?VARIANT2, maps:get(variant, Components1)).

cross_variant_test() ->
    Key = test_binary_key(),
    SecretKey = test_secret_key(),

    {_Id1, Token1} = bondy_oauth_refresh_token:new(Key),
    {_Id2, Token2} = bondy_oauth_refresh_token:new(Key, SecretKey),

    ?assertMatch({ok, _}, bondy_oauth_refresh_token:parse(Token1)),
    ?assertMatch({ok, _}, bondy_oauth_refresh_token:parse(Token2)),

    ?assert(bondy_oauth_refresh_token:is_valid(Token1)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token2)),

    ?assertNot(bondy_oauth_refresh_token:is_valid(Token1, SecretKey)),
    ?assert(bondy_oauth_refresh_token:is_valid(Token2, SecretKey)),

    ?assertEqual(
        {error, invalid_token},
        bondy_oauth_refresh_token:verify(Token1, SecretKey)
    ),
    ?assertMatch({ok, _}, bondy_oauth_refresh_token:verify(Token2, SecretKey)).

%% -----------------------------------------------------------------------------
%% Property-based testing helpers
%% -----------------------------------------------------------------------------

token_format_property_test() ->
    TestKeys = [
        test_binary_key(),
        test_term_key(),
        test_atom_key(),
        test_number_key(),
        <<>>,
        crypto:strong_rand_bytes(32)
    ],

    lists:foreach(
        fun(Key) ->
            {Id1, Token1} = bondy_oauth_refresh_token:new(Key),
            ?assert(is_binary(Id1)),
            ?assert(is_binary(Token1)),
            ?assertEqual(<<"bondy:rtoken:">>, extract_scheme(Token1)),
            ?assertEqual(?VARIANT1, extract_variant(Token1)),

            SecretKey = test_secret_key(),
            {Id2, Token2} = bondy_oauth_refresh_token:new(Key, SecretKey),
            ?assert(is_binary(Id2)),
            ?assert(is_binary(Token2)),
            ?assertEqual(<<"bondy:rtoken:">>, extract_scheme(Token2)),
            ?assertEqual(?VARIANT2, extract_variant(Token2))
        end,
        TestKeys
    ).

consistency_property_test() ->
    Key = test_term_key(),
    SecretKey = test_secret_key(),
    {_Id, Token} = bondy_oauth_refresh_token:new(Key, SecretKey),

    {ok, ParsedComponents} = bondy_oauth_refresh_token:parse(Token),
    {ok, VerifiedComponents} = bondy_oauth_refresh_token:verify(
        Token, SecretKey
    ),

    ?assertEqual(ParsedComponents, VerifiedComponents).

-endif.
