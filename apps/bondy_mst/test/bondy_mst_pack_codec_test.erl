%% =============================================================================
%% EUnit suite for `bondy_mst_pack_codec` — the pure pack-file wire
%% codec. Covers:
%%
%% 1. Pack header round-trip; magic / version / hash-algo gating.
%% 2. Record header round-trip; CRC sensitivity (bit flips in the
%%    page body surface as a typed {crc_mismatch, _, _}).
%% 3. Trailer round-trip; mismatch detection on a single-byte flip.
%% 4. Edge cases: truncated input on each decode path.
%% =============================================================================

-module(bondy_mst_pack_codec_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_mst_pack.hrl").

%% =============================================================================
%% Constants
%% =============================================================================

magic_is_BDPG_test() ->
    ?assertEqual(16#42445047, bondy_mst_pack_codec:magic()).

version_is_1_test() ->
    ?assertEqual(1, bondy_mst_pack_codec:version()).

header_bytes_is_48_test() ->
    ?assertEqual(48, bondy_mst_pack_codec:header_bytes()).

record_header_bytes_is_40_test() ->
    ?assertEqual(40, bondy_mst_pack_codec:record_header_bytes()).

trailer_bytes_is_32_test() ->
    ?assertEqual(32, bondy_mst_pack_codec:trailer_bytes()).

hash_bytes_is_32_test() ->
    ?assertEqual(32, bondy_mst_pack_codec:hash_bytes()).

hash_algo_id_round_trip_test() ->
    ?assertEqual(1, bondy_mst_pack_codec:hash_algo_id(sha256)),
    ?assertEqual({ok, sha256}, bondy_mst_pack_codec:hash_algo_atom(1)).

hash_algo_unknown_id_test() ->
    ?assertEqual(
        {error, {bad_hash_algo, 99}},
        bondy_mst_pack_codec:hash_algo_atom(99)
    ).

%% =============================================================================
%% Pack header round-trip
%% =============================================================================

pack_header_round_trip_test() ->
    H = sample_header(),
    Bin = bondy_mst_pack_codec:encode_pack_header(H),
    ?assertEqual(48, byte_size(Bin)),
    ?assertEqual({ok, H}, bondy_mst_pack_codec:decode_pack_header(Bin)).

pack_header_decode_extra_bytes_test() ->
    %% The codec should accept a header even when the input
    %% binary has trailing bytes — the caller may pread a larger
    %% chunk than the header.
    H = sample_header(),
    Bin = <<(bondy_mst_pack_codec:encode_pack_header(H))/binary, "trailing">>,
    ?assertEqual({ok, H}, bondy_mst_pack_codec:decode_pack_header(Bin)).

pack_header_truncated_test() ->
    Truncated = binary:part(
        bondy_mst_pack_codec:encode_pack_header(sample_header()), 0, 40
    ),
    ?assertEqual(
        {error, truncated_header},
        bondy_mst_pack_codec:decode_pack_header(Truncated)
    ).

pack_header_bad_magic_test() ->
    %% Replace the magic with something else; everything else
    %% is well-formed.
    <<_:32, Tail/binary>> =
        bondy_mst_pack_codec:encode_pack_header(sample_header()),
    Bad = <<16#DEADBEEF:32, Tail/binary>>,
    ?assertEqual(
        {error, bad_magic},
        bondy_mst_pack_codec:decode_pack_header(Bad)
    ).

pack_header_bad_version_test() ->
    <<Magic:32, _Version:8, Rest/binary>> =
        bondy_mst_pack_codec:encode_pack_header(sample_header()),
    Bad = <<Magic:32, 99:8, Rest/binary>>,
    ?assertEqual(
        {error, {bad_version, 99}},
        bondy_mst_pack_codec:decode_pack_header(Bad)
    ).

pack_header_bad_hash_algo_test() ->
    %% Field at offset 20 (4-byte algo id).
    Encoded = bondy_mst_pack_codec:encode_pack_header(sample_header()),
    <<Head:20/binary, _AlgoId:32, Tail/binary>> = Encoded,
    Bad = <<Head/binary, 7:32/big-unsigned, Tail/binary>>,
    ?assertEqual(
        {error, {bad_hash_algo, 7}},
        bondy_mst_pack_codec:decode_pack_header(Bad)
    ).

pack_header_record_count_carries_through_test() ->
    H0 = sample_header(),
    H = H0#{record_count := 12345},
    Bin = bondy_mst_pack_codec:encode_pack_header(H),
    {ok, Decoded} = bondy_mst_pack_codec:decode_pack_header(Bin),
    ?assertEqual(12345, maps:get(record_count, Decoded)).

%% =============================================================================
%% Record round-trip
%% =============================================================================

record_round_trip_test() ->
    Page = <<"hello, page store">>,
    Hash = crypto:hash(sha256, Page),
    IoData = bondy_mst_pack_codec:encode_record(Hash, Page),
    Bin = iolist_to_binary(IoData),
    ?assertEqual(40 + byte_size(Page), byte_size(Bin)),
    {ok, Header} = bondy_mst_pack_codec:decode_record_header(Bin),
    ?assertEqual(Hash, maps:get(hash, Header)),
    ?assertEqual(byte_size(Page), maps:get(page_len, Header)),
    %% The page body sits right after the 40-byte header.
    Body = binary:part(Bin, 40, byte_size(Page)),
    ?assertEqual(Page, Body),
    ?assertEqual(ok, bondy_mst_pack_codec:verify_record(Header, Body)).

record_zero_byte_body_test() ->
    %% Page bytes may be empty (an empty MST page); the codec
    %% should round-trip cleanly.
    Page = <<>>,
    Hash = crypto:hash(sha256, Page),
    IoData = bondy_mst_pack_codec:encode_record(Hash, Page),
    Bin = iolist_to_binary(IoData),
    ?assertEqual(40, byte_size(Bin)),
    {ok, Header} = bondy_mst_pack_codec:decode_record_header(Bin),
    ?assertEqual(ok, bondy_mst_pack_codec:verify_record(Header, <<>>)).

record_crc_sensitive_to_body_bit_flip_test() ->
    %% A single bit flipped inside the body must surface as a
    %% typed crc_mismatch, never as a silently-returned page.
    Page = crypto:strong_rand_bytes(128),
    Hash = crypto:hash(sha256, Page),
    Bin = iolist_to_binary(
        bondy_mst_pack_codec:encode_record(Hash, Page)
    ),
    {ok, Header} = bondy_mst_pack_codec:decode_record_header(Bin),
    Mutated = flip_bit(Page, 0),
    ?assertNotEqual(Page, Mutated),
    Result = bondy_mst_pack_codec:verify_record(Header, Mutated),
    ?assertMatch({error, {crc_mismatch, _, _}}, Result).

record_verify_rejects_wrong_length_test() ->
    Page = <<"the original page">>,
    Hash = crypto:hash(sha256, Page),
    Bin = iolist_to_binary(
        bondy_mst_pack_codec:encode_record(Hash, Page)
    ),
    {ok, Header} = bondy_mst_pack_codec:decode_record_header(Bin),
    ?assertMatch(
        {error, {bad_page_len, _}},
        bondy_mst_pack_codec:verify_record(Header, <<"shorter">>)
    ).

record_header_truncated_test() ->
    ?assertEqual(
        {error, truncated_record_header},
        bondy_mst_pack_codec:decode_record_header(<<"too short">>)
    ).

record_size_test() ->
    ?assertEqual(40, bondy_mst_pack_codec:record_size(0)),
    ?assertEqual(140, bondy_mst_pack_codec:record_size(100)).

%% =============================================================================
%% Trailer
%% =============================================================================

trailer_is_32_byte_sha256_test() ->
    Body = <<"some pack body bytes">>,
    Trailer = bondy_mst_pack_codec:compute_trailer(Body),
    ?assertEqual(32, byte_size(Trailer)),
    ?assertEqual(crypto:hash(sha256, Body), Trailer).

trailer_accepts_iodata_test() ->
    Body = [<<"part1">>, [<<"part2">>, <<"part3">>]],
    Trailer = bondy_mst_pack_codec:compute_trailer(Body),
    ?assertEqual(crypto:hash(sha256, iolist_to_binary(Body)), Trailer).

trailer_verify_ok_test() ->
    Body = <<"pack body">>,
    Trailer = bondy_mst_pack_codec:compute_trailer(Body),
    ?assertEqual(ok, bondy_mst_pack_codec:verify_trailer(Body, Trailer)).

trailer_verify_rejects_bit_flip_test() ->
    Body = <<"pack body">>,
    Trailer0 = bondy_mst_pack_codec:compute_trailer(Body),
    Bad = flip_bit(Trailer0, 0),
    ?assertMatch(
        {error, {trailer_mismatch, _, _}},
        bondy_mst_pack_codec:verify_trailer(Body, Bad)
    ).

trailer_verify_rejects_body_corruption_test() ->
    Body = <<"pack body">>,
    Trailer = bondy_mst_pack_codec:compute_trailer(Body),
    ?assertMatch(
        {error, {trailer_mismatch, _, _}},
        bondy_mst_pack_codec:verify_trailer(<<"pack BODY">>, Trailer)
    ).

trailer_verify_rejects_wrong_size_test() ->
    ?assertEqual(
        {error, truncated_trailer},
        bondy_mst_pack_codec:verify_trailer(<<"body">>, <<"short">>)
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

sample_header() ->
    #{
        version => 1,
        flags => 0,
        pack_id => 42,
        instance_hash => erlang:phash2(<<"test-instance">>),
        hash_algo => sha256,
        created_at => 1715520000000,
        record_count => 0
    }.

flip_bit(Bin, BitIx) ->
    ByteIx = BitIx div 8,
    Mask = 1 bsl (BitIx rem 8),
    <<Head:ByteIx/binary, Byte:8, Rest/binary>> = Bin,
    <<Head/binary, (Byte bxor Mask):8, Rest/binary>>.
