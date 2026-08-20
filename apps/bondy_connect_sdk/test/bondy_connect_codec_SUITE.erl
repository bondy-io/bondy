%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_codec_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-compile([nowarn_export_all, export_all]).

-define(MAX, 16#1000000).

all() ->
    [
        %% framing: codes / lengths
        serializer_codes,
        length_exponent_and_bytes,

        %% framing: handshake
        handshake_request_and_parse,
        handshake_parse_error,
        handshake_parse_invalid,

        %% framing: frames
        frame_message_round_trip,
        frame_ping_pong,
        parse_frame_partial,
        parse_frame_multiple,
        parse_frame_oversize,
        parse_frame_reserved_bits,

        %% codec
        codec_encode_decode_round_trip,
        codec_decode_split,
        codec_decode_multiple,
        codec_encode_oversize,
        codec_decode_oversize,
        codec_decode_corrupt_payload,
        codec_decode_materialises_payload
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(bondy_wamp),
    Config.

end_per_suite(_) ->
    ok.

%% @private
hello(Realm) ->
    bondy_wamp_message:hello(Realm, #{roles => #{caller => #{}}}).

%% =============================================================================
%% FRAMING — CODES / LENGTHS
%% =============================================================================

serializer_codes(_) ->
    ?assertEqual(1, bondy_connect_framing:serializer_code(json)),
    ?assertEqual(2, bondy_connect_framing:serializer_code(msgpack)),
    ?assertEqual(3, bondy_connect_framing:serializer_code(cbor)),
    ?assertEqual(json, bondy_connect_framing:code_to_encoding(1)),
    ?assertEqual(cbor, bondy_connect_framing:code_to_encoding(3)),
    ?assertEqual(undefined, bondy_connect_framing:code_to_encoding(7)).

length_exponent_and_bytes(_) ->
    %% code N -> 2^(9+N): 0 -> 512, 15 -> 16 MB
    ?assertEqual(512, bondy_connect_framing:exponent_to_bytes(0)),
    ?assertEqual(16#1000000, bondy_connect_framing:exponent_to_bytes(15)),
    ?assertEqual(15, bondy_connect_framing:length_exponent(16#1000000)),
    ?assertEqual(0, bondy_connect_framing:length_exponent(512)),
    ?assertEqual(0, bondy_connect_framing:length_exponent(1000)),
    ?assertEqual(1, bondy_connect_framing:length_exponent(1024)).

%% =============================================================================
%% FRAMING — HANDSHAKE
%% =============================================================================

handshake_request_and_parse(_) ->
    Req = bondy_connect_framing:handshake_request(15, 1),
    ?assertEqual(<<16#7F, 16#F1, 0, 0>>, Req),
    ?assertEqual({ok, 15, 1}, bondy_connect_framing:parse_handshake(Req)).

handshake_parse_error(_) ->
    %% serializer nibble 0 => error reply, code in high nibble
    ?assertEqual(
        {error, serializer_unsupported},
        bondy_connect_framing:parse_handshake(<<16#7F, 1:4, 0:4, 0:16>>)
    ),
    ?assertEqual(
        {error, maximum_message_length_unacceptable},
        bondy_connect_framing:parse_handshake(<<16#7F, 2:4, 0:4, 0:16>>)
    ).

handshake_parse_invalid(_) ->
    ?assertEqual(
        {error, invalid_handshake},
        bondy_connect_framing:parse_handshake(<<1, 2, 3, 4>>)
    ),
    ?assertEqual(
        {error, invalid_handshake},
        bondy_connect_framing:parse_handshake(<<16#7F, 1, 2>>)
    ).

%% =============================================================================
%% FRAMING — FRAMES
%% =============================================================================

frame_message_round_trip(_) ->
    Payload = <<"a-wamp-payload">>,
    Frame = bondy_connect_framing:frame(Payload),
    ?assertEqual(
        {ok, {message, Payload}, <<>>},
        bondy_connect_framing:parse_frame(Frame, ?MAX)
    ).

frame_ping_pong(_) ->
    P = <<"pp">>,
    ?assertEqual(
        {ok, {ping, P}, <<>>},
        bondy_connect_framing:parse_frame(
            bondy_connect_framing:ping_frame(P), ?MAX
        )
    ),
    ?assertEqual(
        {ok, {pong, P}, <<>>},
        bondy_connect_framing:parse_frame(
            bondy_connect_framing:pong_frame(P), ?MAX
        )
    ).

parse_frame_partial(_) ->
    Frame = bondy_connect_framing:frame(<<"abcdef">>),
    <<Head:5/binary, Tail/binary>> = Frame,
    %% header complete, payload incomplete -> more
    ?assertEqual(more, bondy_connect_framing:parse_frame(Head, ?MAX)),
    %% fewer than 4 header bytes -> more
    ?assertEqual(more, bondy_connect_framing:parse_frame(<<0, 0>>, ?MAX)),
    ?assertEqual(
        {ok, {message, <<"abcdef">>}, <<>>},
        bondy_connect_framing:parse_frame(<<Head/binary, Tail/binary>>, ?MAX)
    ).

parse_frame_multiple(_) ->
    Buf = <<
        (bondy_connect_framing:frame(<<"one">>))/binary,
        (bondy_connect_framing:frame(<<"two">>))/binary
    >>,
    {ok, {message, <<"one">>}, Rest} =
        bondy_connect_framing:parse_frame(Buf, ?MAX),
    ?assertEqual(
        {ok, {message, <<"two">>}, <<>>},
        bondy_connect_framing:parse_frame(Rest, ?MAX)
    ).

parse_frame_oversize(_) ->
    Frame = bondy_connect_framing:frame(binary:copy(<<"x">>, 100)),
    ?assertEqual(
        {error, {message_too_large, 100, 16}},
        bondy_connect_framing:parse_frame(Frame, 16)
    ).

parse_frame_reserved_bits(_) ->
    %% Reserved (top 5) bits set -> protocol error
    Bad = <<1:5, 0:3, 1:24, "z">>,
    ?assertEqual(
        {error, use_of_reserved_bits},
        bondy_connect_framing:parse_frame(Bad, ?MAX)
    ).

%% =============================================================================
%% CODEC
%% =============================================================================

codec_encode_decode_round_trip(_) ->
    Codec = bondy_connect_codec:new(json, ?MAX, ?MAX),
    Hello = hello(<<"com.example.x">>),
    {ok, Frame} = bondy_connect_codec:encode(Hello, Codec),
    {ok, [Decoded], _C1} = bondy_connect_codec:decode(Frame, Codec),
    ?assertMatch(#hello{realm_uri = <<"com.example.x">>}, Decoded).

codec_decode_split(_) ->
    Codec = bondy_connect_codec:new(json, ?MAX, ?MAX),
    {ok, Frame} = bondy_connect_codec:encode(hello(<<"com.example.x">>), Codec),
    <<A:6/binary, B/binary>> = Frame,
    {ok, [], C1} = bondy_connect_codec:decode(A, Codec),
    {ok, [Decoded], _C2} = bondy_connect_codec:decode(B, C1),
    ?assertMatch(#hello{}, Decoded).

codec_decode_multiple(_) ->
    Codec = bondy_connect_codec:new(json, ?MAX, ?MAX),
    {ok, F1} = bondy_connect_codec:encode(hello(<<"com.a">>), Codec),
    {ok, F2} = bondy_connect_codec:encode(hello(<<"com.b">>), Codec),
    {ok, [D1, D2], _} =
        bondy_connect_codec:decode(<<F1/binary, F2/binary>>, Codec),
    ?assertMatch(#hello{realm_uri = <<"com.a">>}, D1),
    ?assertMatch(#hello{realm_uri = <<"com.b">>}, D2).

codec_encode_oversize(_) ->
    %% Tiny send limit -> encode refuses
    Codec = bondy_connect_codec:new(json, 8, ?MAX),
    ?assertMatch(
        {error, {message_too_large, _, 8}},
        bondy_connect_codec:encode(hello(<<"com.example.x">>), Codec)
    ).

codec_decode_oversize(_) ->
    Big = bondy_connect_codec:new(json, ?MAX, ?MAX),
    {ok, Frame} = bondy_connect_codec:encode(hello(<<"com.example.x">>), Big),
    %% Tiny receive limit -> decode rejects the (legitimately framed) message
    Tiny = bondy_connect_codec:new(json, ?MAX, 8),
    ?assertMatch(
        {error, {protocol_error, {message_too_large, _, 8}}, _},
        bondy_connect_codec:decode(Frame, Tiny)
    ).

codec_decode_corrupt_payload(_) ->
    Codec = bondy_connect_codec:new(json, ?MAX, ?MAX),
    %% A well-framed but un-decodable JSON payload must surface as a protocol
    %% error, never crash.
    BadFrame = bondy_connect_framing:frame(<<"{not-json">>),
    ?assertMatch(
        {error, {protocol_error, {decode_failed, _, _}}, _},
        bondy_connect_codec:decode(BadFrame, Codec)
    ).

%% Regression: a client is the final consumer of payloads, so the codec must
%% FULLY decode inbound Args/KWArgs and never surface a `partial' (the
%% router-side passthrough optimisation). json/cbor default to partial
%% decoding, and msgpack's option parser is strict and has no partial path —
%% all three must come back materialised. Guards the disable-at-source decode
%% (`{partial_decode, false}') against a regression to the old
%% decode-then-`decode_partial' post-pass or a strict-parser crash.
codec_decode_materialises_payload(_) ->
    [materialises(Enc) || Enc <- [json, msgpack, cbor]],
    ok.

%% @private
materialises(Enc) ->
    Codec = bondy_connect_codec:new(Enc, ?MAX, ?MAX),
    Args = [<<"hi">>, 42],
    KWArgs = #{<<"k">> => <<"v">>},
    Msg = bondy_wamp_message:result(1, #{}, Args, KWArgs),
    {ok, Frame} = bondy_connect_codec:encode(Msg, Codec),
    {ok, [Decoded], _} = bondy_connect_codec:decode(Frame, Codec),
    ?assertEqual(false, bondy_wamp_message:is_partial(Decoded), {partial, Enc}),
    #result{args = DArgs, kwargs = DKWArgs} = Decoded,
    ?assertEqual(Args, DArgs, {args, Enc}),
    ?assertEqual(KWArgs, DKWArgs, {kwargs, Enc}).
