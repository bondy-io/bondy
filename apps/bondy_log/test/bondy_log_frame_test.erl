%% =============================================================================
%% Unit tests for `bondy_log_frame` (frame encode/decode).
%%
%% Property-based tests live in `bondy_oplog_wal_proper_test`.
%% =============================================================================

-module(bondy_log_frame_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_log.hrl").

%% This suite's own magic ("BDTF"): the frame module has none, every
%% caller names one.
-define(MAGIC, 16#42445446).
-define(HEADER, ?BONDY_LOG_FRAME_HEADER_BYTES).

%% Encode and immediately flatten to a binary for the EUnit tests that
%% want to inspect bytes. The writer passes the iodata straight to
%% `prim_file:write/2`. The helpers supply `?MAGIC` unless the caller
%% names one (the first `magic` in the list wins).
encode(Body) ->
    encode(Body, []).

encode(Body, Opts) ->
    iolist_to_binary(bondy_log_frame:encode(Body, Opts ++ [{magic, ?MAGIC}])).

decode(Frame) ->
    bondy_log_frame:decode(Frame, [{magic, ?MAGIC}]).

decode_header(Bin) ->
    bondy_log_frame:decode_header(Bin, [{magic, ?MAGIC}]).

%% =============================================================================
%% Basic encode/decode round-trip
%% =============================================================================

empty_body_roundtrip_test() ->
    Frame = encode(<<>>),
    ?assertEqual(?HEADER, byte_size(Frame)),
    ?assertMatch(
        {ok, <<>>, #{version := ?BONDY_LOG_FRAME_VERSION, flags := 0}},
        decode(Frame)
    ).

small_body_roundtrip_test() ->
    Body = <<"hello, wal">>,
    Frame = encode(Body),
    ?assertEqual(?HEADER + byte_size(Body), byte_size(Frame)),
    ?assertMatch(
        {ok, Body, _},
        decode(Frame)
    ).

large_body_roundtrip_test() ->
    Body = crypto:strong_rand_bytes(64 * 1024),
    Frame = encode(Body),
    {ok, Decoded, _Meta} = decode(Frame),
    ?assertEqual(Body, Decoded).

iodata_body_is_flattened_on_decode_test() ->
    %% Passing iodata in must produce the same on-wire body bytes
    %% as the contiguous binary equivalent.
    Iodata = [<<"hello, ">>, <<"wal">>],
    Frame = encode(Iodata),
    {ok, Decoded, _} = decode(Frame),
    ?assertEqual(<<"hello, wal">>, Decoded).

term_to_binary_body_roundtrip_test() ->
    Events = [
        {event, 1, <<"alpha">>},
        {event, 2, <<"beta">>},
        {event, 3, <<"gamma">>}
    ],
    Body = term_to_binary(Events, [{minor_version, 2}, deterministic]),
    Frame = encode(Body),
    {ok, Decoded, _} = decode(Frame),
    ?assertEqual(Events, binary_to_term(Decoded)).

zero_flags_roundtrip_test() ->
    Frame = encode(<<"x">>, [{flags, 0}]),
    ?assertMatch(
        {ok, <<"x">>, #{flags := 0}},
        decode(Frame)
    ).

encode_returns_iodata_test() ->
    %% Sanity: the public encode/2 returns iolist that flattens to a
    %% well-formed frame without needing iolist_to_binary in the hot path.
    Iodata = bondy_log_frame:encode(<<"x">>, [{magic, ?MAGIC}]),
    ?assert(is_list(Iodata)),
    ?assertEqual(?HEADER + 1, iolist_size(Iodata)),
    ?assertMatch(
        {ok, <<"x">>, _},
        decode(iolist_to_binary(Iodata))
    ).

header_bytes_constant_test() ->
    ?assertEqual(?HEADER, bondy_log_frame:header_bytes()).

%% =============================================================================
%% Decode error paths
%% =============================================================================

truncated_header_test() ->
    [
        ?assertMatch(
            {error, truncated_header},
            decode(crypto:strong_rand_bytes(N))
        )
     || N <- [0, 1, 5, 15]
    ].

bad_magic_test() ->
    Frame = encode(<<"x">>),
    Corrupt =
        <<16#DEADBEEF:32,
            (binary:part(Frame, 4, byte_size(Frame) - 4))/binary>>,
    ?assertEqual({error, bad_magic}, decode(Corrupt)).

crc_mismatch_test() ->
    Frame0 = encode(<<"hello">>),
    Before = binary:part(Frame0, 0, ?HEADER),
    Body0 = binary:part(Frame0, ?HEADER, byte_size(Frame0) - ?HEADER),
    <<H, T/binary>> = Body0,
    Body1 = <<(H bxor 1):8, T/binary>>,
    Frame1 = <<Before/binary, Body1/binary>>,
    ?assertEqual({error, crc_mismatch}, decode(Frame1)).

length_invalid_test() ->
    Bin = <<?MAGIC:32, 8:32, 0:32, 1:8, 0:24>>,
    ?assertEqual({error, length_invalid}, decode(Bin)).

truncated_body_test() ->
    %% FrameLen says 32 but only 16 bytes are present.
    Bin = <<?MAGIC:32, 32:32, 0:32, 1:8, 0:24>>,
    ?assertEqual({error, truncated_body}, decode(Bin)).

trailing_bytes_test() ->
    %% A complete frame followed by extra bytes the caller forgot to trim.
    Frame = encode(<<"x">>),
    WithGarbage = <<Frame/binary, "extra">>,
    ?assertEqual(
        {error, trailing_bytes},
        decode(WithGarbage)
    ).

unsupported_version_test() ->
    Body = <<"body">>,
    FrameLen = ?HEADER + byte_size(Body),
    Version = 99,
    Flags = 0,
    CrcInput = <<FrameLen:32, Version:8, Flags:24, Body/binary>>,
    Crc = erlang:crc32(CrcInput),
    Frame =
        <<?MAGIC:32, FrameLen:32, Crc:32, Version:8, Flags:24, Body/binary>>,
    ?assertEqual(
        {error, unsupported_version},
        decode(Frame)
    ).

unknown_flag_v1_test() ->
    %% v1's known-flags mask is 0; every set bit is unknown_flag.
    ?assertEqual(
        {error, unknown_flag},
        decode(handcraft_frame(1, 16#000004, <<"body">>))
    ).

unknown_flag_v2_test() ->
    %% v2's mask now includes bit 0 (compressed_body); bit 2 is still
    %% outside the mask, so a v2 frame setting it must be rejected
    %% rather than silently accepted.
    ?assertEqual(
        {error, unknown_flag},
        decode(handcraft_frame(2, 16#000004, <<"body">>))
    ).

%% =============================================================================
%% decode_header/1
%% =============================================================================

decode_header_ok_test() ->
    Frame = encode(<<"abc">>),
    {ok, Header} = decode_header(Frame),
    ?assertEqual(?HEADER + 3, maps:get(frame_len, Header)),
    ?assertEqual(
        ?BONDY_LOG_FRAME_VERSION,
        maps:get(version, Header)
    ),
    ?assertEqual(0, maps:get(flags, Header)).

decode_header_only_header_bytes_test() ->
    Frame = encode(<<"abc">>),
    HeaderOnly = binary:part(Frame, 0, ?HEADER),
    ?assertMatch({ok, _}, decode_header(HeaderOnly)).

decode_header_bad_magic_test() ->
    Bin = <<0:32, 32:32, 0:32, 1:8, 0:24>>,
    ?assertEqual(
        {error, bad_magic},
        decode_header(Bin)
    ).

decode_header_length_invalid_test() ->
    Bin = <<?MAGIC:32, 8:32, 0:32, 1:8, 0:24>>,
    ?assertEqual(
        {error, length_invalid},
        decode_header(Bin)
    ).

decode_header_truncated_test() ->
    [
        ?assertMatch(
            {error, truncated_header},
            decode_header(<<>>)
        ),
        ?assertMatch(
            {error, truncated_header},
            decode_header(<<?MAGIC:32>>)
        ),
        ?assertMatch(
            {error, truncated_header},
            decode_header(<<?MAGIC:32, 0:64>>)
        )
    ].

%% =============================================================================
%% Validation guards
%% =============================================================================

invalid_version_rejected_test() ->
    ?assertError(
        {badarg, _},
        bondy_log_frame:encode(<<>>, [{version, 99}])
    ).

invalid_flag_bit_rejected_at_encode_test() ->
    %% v2 accepts bits 0 (compressed_body) and 1 (encrypted_body);
    %% bit 2 and beyond are still outside the v2 known-flags mask.
    ?assertError(
        {badarg, _},
        bondy_log_frame:encode(<<>>, [{flags, 16#4}])
    ),
    ?assertError(
        {badarg, _},
        bondy_log_frame:encode(<<>>, [{flags, 16#8}])
    ),
    ?assertError(
        {badarg, _},
        bondy_log_frame:encode(<<>>, [{flags, 16#FFFFFFFF}])
    ),
    %% Explicitly producing a v1 frame: mask is zero, every bit is bad.
    ?assertError(
        {badarg, _},
        bondy_log_frame:encode(
            <<>>, [{version, 1}, {flags, 16#1}]
        )
    ).

%% =============================================================================
%% v2 envelope + v1 backward compatibility
%% =============================================================================

%% Default-encoded frames advertise the current writer version.
default_encoded_frame_is_v2_test() ->
    Frame = encode(<<"x">>),
    ?assertMatch(
        {ok, <<"x">>, #{
            version := ?BONDY_LOG_FRAME_VERSION_V2,
            flags := 0
        }},
        decode(Frame)
    ).

%% A v2 reader (this one) must continue to round-trip v1-encoded
%% frames byte-for-byte. Production has v1-frame segments on disk from
%% before PR1; recovery must keep reading them.
v1_frame_decoded_by_v2_reader_test() ->
    Body = <<"legacy body">>,
    Frame = encode(Body, [{version, 1}]),
    ?assertMatch(
        {ok, Body, #{version := 1, flags := 0}},
        decode(Frame)
    ).

%% Same body encoded as v1 and as v2 differs only in the version byte
%% (the CRC differs as a consequence). Bodies decode identically.
v1_and_v2_frames_yield_same_body_test() ->
    Body = <<"abcdefghij">>,
    V1Frame = encode(Body, [{version, 1}]),
    V2Frame = encode(Body, [{version, 2}]),
    {ok, B1, M1} = decode(V1Frame),
    {ok, B2, M2} = decode(V2Frame),
    ?assertEqual(Body, B1),
    ?assertEqual(Body, B2),
    ?assertEqual(1, maps:get(version, M1)),
    ?assertEqual(2, maps:get(version, M2)),
    %% Frames differ in exactly the version byte at offset 12, hence
    %% also in the CRC32 over the modified region.
    ?assertNotEqual(V1Frame, V2Frame).

%% =============================================================================
%% Helpers
%% =============================================================================

handcraft_frame(Version, Flags, Body) when is_binary(Body) ->
    FrameLen = ?HEADER + byte_size(Body),
    CrcInput = <<FrameLen:32, Version:8, Flags:24, Body/binary>>,
    Crc = erlang:crc32(CrcInput),
    <<?MAGIC:32, FrameLen:32, Crc:32, Version:8, Flags:24, Body/binary>>.

%% =============================================================================
%% Byte identity with the pre-move encoder
%% =============================================================================
%%
%% The hex below was produced by `bondy_log_frame:encode/1,2` on the
%% commit that preceded the move into `bondy_log`, on these exact inputs,
%% under the oplog's magic ("BDOP", `?OPLOG_MAGIC`) — the value the oplog
%% adapter still names, spelled out here because the core owns no magic.
%% Any drift in the header layout, the CRC scope or the CRC algorithm
%% shows up here as a byte difference, independently of the round-trip
%% tests above (which would keep passing if encode and decode drifted
%% together).

-define(OPLOG_MAGIC, 16#42444F50).

byte_identity_test_() ->
    Cases = [
        {"v2 flags=0 <<\"hello\">>", <<"hello">>, [],
            "42444F5000000015103775330200000068656C6C6F"},
        {"v1 flags=0 <<\"hello\">>", <<"hello">>, [{version, 1}],
            "42444F500000001529BA49F60100000068656C6C6F"},
        {"v2 flags=3 six bytes", <<0, 1, 2, 3, 255, 254>>, [{flags, 3}],
            "42444F5000000016FEEBC0E40200000300010203FFFE"},
        {"v2 flags=1 empty body", <<>>, [{flags, 1}],
            "42444F5000000010D8CCB0F602000001"},
        {"v2 nested iolist body", [<<"ab">>, [<<"c">>, $d], <<"e">>], [],
            "42444F5000000015A3A00BD0020000006162636465"}
    ],
    [
        {Name,
            ?_assertEqual(
                binary:decode_hex(list_to_binary(Hex)),
                encode(Body, [{magic, ?OPLOG_MAGIC} | Opts])
            )}
     || {Name, Body, Opts, Hex} <- Cases
    ].

%% =============================================================================
%% Magic as a parameter
%% =============================================================================

-define(OTHER_MAGIC, 16#42445354).

a_missing_magic_is_badarg_not_a_frame_error_test() ->
    Frame = encode(<<"x">>),
    ?assertError(
        {badarg, {magic, undefined}}, bondy_log_frame:encode(<<"x">>, [])
    ),
    ?assertError(
        {badarg, {magic, undefined}}, bondy_log_frame:decode(Frame, [])
    ),
    ?assertError(
        {badarg, {magic, undefined}}, bondy_log_frame:decode_header(Frame, [])
    ),
    ?assertError(
        {badarg, {magic, -1}}, bondy_log_frame:decode(Frame, [{magic, -1}])
    ).

custom_magic_is_written_at_offset_zero_test() ->
    Frame = encode(<<"x">>, [{magic, ?OTHER_MAGIC}]),
    ?assertMatch(<<?OTHER_MAGIC:32/big-unsigned, _/binary>>, Frame),
    %% Everything after the magic is unchanged: the CRC does not cover it.
    <<_:4/binary, Rest/binary>> = Frame,
    <<_:4/binary, DefaultRest/binary>> = encode(<<"x">>),
    ?assertEqual(DefaultRest, Rest).

custom_magic_roundtrips_only_with_the_same_magic_test() ->
    Frame = encode(<<"payload">>, [{magic, ?OTHER_MAGIC}]),
    ?assertMatch(
        {ok, <<"payload">>, #{version := 2, flags := 0}},
        bondy_log_frame:decode(Frame, [{magic, ?OTHER_MAGIC}])
    ),
    %% Falsifies "a scanner for kind A accepts kind B's frames": the same
    %% bytes under this suite's magic and under a third magic are rejected
    %% as bad_magic, and so is one of our frames read with a custom magic.
    ?assertEqual({error, bad_magic}, decode(Frame)),
    ?assertEqual(
        {error, bad_magic},
        bondy_log_frame:decode(Frame, [{magic, ?OTHER_MAGIC + 1}])
    ),
    ?assertEqual(
        {error, bad_magic},
        bondy_log_frame:decode(encode(<<"payload">>), [{magic, ?OTHER_MAGIC}])
    ).

decode_header_honours_magic_test() ->
    Frame = encode(<<"abc">>, [{magic, ?OTHER_MAGIC}]),
    ?assertMatch(
        {ok, #{frame_len := 19, version := 2, flags := 0}},
        bondy_log_frame:decode_header(Frame, [{magic, ?OTHER_MAGIC}])
    ),
    ?assertEqual({error, bad_magic}, decode_header(Frame)),
    %% length_invalid still wins over bad_magic only when the magic matches.
    Short = <<?OTHER_MAGIC:32/big-unsigned, 3:32/big-unsigned, 0:64>>,
    ?assertEqual(
        {error, length_invalid},
        bondy_log_frame:decode_header(Short, [{magic, ?OTHER_MAGIC}])
    ),
    ?assertEqual({error, bad_magic}, decode_header(Short)).

truncated_wins_over_magic_test() ->
    %% A too-short input is truncated regardless of which magic is
    %% expected, exactly as in the arity-1 form.
    ?assertEqual(
        {error, truncated_header},
        bondy_log_frame:decode(<<1, 2, 3>>, [{magic, ?OTHER_MAGIC}])
    ),
    ?assertEqual(
        {error, truncated_header},
        bondy_log_frame:decode_header(<<1, 2, 3>>, [{magic, ?OTHER_MAGIC}])
    ).

invalid_magic_is_badarg_at_encode_test() ->
    ?assertError({badarg, {magic, -1}}, encode(<<>>, [{magic, -1}])),
    ?assertError(
        {badarg, {magic, 16#100000000}},
        encode(<<>>, [{magic, 16#100000000}])
    ),
    ?assertError({badarg, {magic, "BDOP"}}, encode(<<>>, [{magic, "BDOP"}])).
