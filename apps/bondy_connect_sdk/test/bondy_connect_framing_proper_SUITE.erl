%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_framing_proper_SUITE).

-moduledoc """
Property-based tests (PropEr) for the WAMP raw-socket framing/codec layer.

The example-based `bondy_connect_codec_SUITE` pins a handful of split points; the
real risk is the *stateful* reassembly of a byte stream that TCP may deliver in
arbitrary chunks (header split across reads, payload split, several frames in one
read, empty reads). These properties generalise that:

- `prop_frame_split_roundtrip` — any sequence of typed frames, framed and then
  fed to `bondy_connect_framing:parse_frame/2` across an **arbitrary chunking**,
  reassembles into exactly the original `(kind, payload)` sequence with nothing
  left buffered.
- `prop_codec_control_split_roundtrip` — the same, but through the *real*
  stateful `bondy_connect_codec:decode/2` buffer (ping/pong control frames, which
  pass through without a serializer round-trip).
- `prop_codec_message_split_roundtrip` — a real WAMP `RESULT` survives arbitrary
  fragmentation through `encode/2` → split → `decode/2` (the serializer branch).
- `prop_oversize_rejected` — a frame whose declared length exceeds the negotiated
  max is rejected (`message_too_large`) regardless of payload.
- `prop_handshake_roundtrip` — `handshake_request/2` and `parse_handshake/1` are
  inverse over the valid exponent/serializer ranges.
- `prop_next_id_range_wrap` — the per-connection request-id counter stays in
  `[1, ?MAX_ID]` and wraps at `2^53` (`?MAX_ID`), never yielding `0`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-compile([nowarn_export_all, export_all]).

-define(NUMTESTS, 200).
-define(MAX, 16#1000000).

all() ->
    [
        prop_frame_split_roundtrip,
        prop_codec_control_split_roundtrip,
        prop_codec_message_split_roundtrip,
        prop_oversize_rejected,
        prop_handshake_roundtrip,
        prop_next_id_range_wrap
    ].

init_per_suite(Config) ->
    %% The codec message branch and ?MAX_ID-bearing helpers route through
    %% bondy_wamp_encoding, which needs the app's env (uri strictness, etc.).
    {ok, _} = application:ensure_all_started(bondy_wamp),
    Config.

end_per_suite(_) ->
    ok.

%% =============================================================================
%% GENERATORS
%% =============================================================================

%% @private A small (possibly empty) opaque payload — bounded so frames stay
%% well under ?MAX and tests stay fast.
payload() ->
    ?LET(N, range(0, 256), binary(N)).

%% @private A frame kind for the framing-level property (parse_frame does not
%% decode the payload, so any kind takes any bytes).
frame_kind() ->
    oneof([message, ping, pong]).

%% @private A typed frame spec `{Kind, Payload}`.
frame_spec() ->
    {frame_kind(), payload()}.

%% @private A control-frame spec for the codec-level property (ping/pong only —
%% these pass through `decode/2` without a serializer round-trip).
control_spec() ->
    {oneof([ping, pong]), payload()}.

%% @private A printable, non-empty key (valid UTF-8 JSON object key).
json_key() ->
    ?LET(L, non_empty(list(range($a, $z))), list_to_binary(L)).

%% @private A JSON-safe scalar that round-trips exactly through every serializer
%% (printable string or a small non-negative integer — no floats/atoms).
json_value() ->
    oneof([
        ?LET(L, list(range($a, $z)), list_to_binary(L)),
        range(0, 1000000)
    ]).

%% @private A real WAMP RESULT with JSON-safe, non-empty Args/KWArgs so the
%% decoded record compares field-for-field after a serializer round-trip.
result_msg() ->
    ?LET(
        {ReqId, Args, KVs},
        {
            range(1, 1000000),
            non_empty(list(json_value())),
            non_empty(list({json_key(), json_value()}))
        },
        bondy_wamp_message:result(ReqId, #{}, Args, maps:from_list(KVs))
    ).

%% =============================================================================
%% PROPERTIES
%% =============================================================================

%% Any sequence of typed frames, concatenated and then re-delivered in an
%% arbitrary chunking, deframes into exactly the original sequence with an empty
%% trailing buffer.
prop_frame_split_roundtrip(_) ->
    Prop = ?FORALL(
        Specs,
        list(frame_spec()),
        begin
            Wire = iolist_to_binary([frame_bytes(S) || S <- Specs]),
            ?FORALL(
                Chunks,
                chunking(Wire),
                begin
                    {Buf, Items} = deframe_all(Chunks),
                    Buf =:= <<>> andalso Items =:= Specs
                end
            )
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).

%% The same reassembly invariant through the real stateful `decode/2` buffer,
%% using ping/pong control frames (no serializer round-trip).
prop_codec_control_split_roundtrip(_) ->
    Prop = ?FORALL(
        Specs,
        list(control_spec()),
        begin
            Wire = iolist_to_binary([frame_bytes(S) || S <- Specs]),
            ?FORALL(
                Chunks,
                chunking(Wire),
                begin
                    Codec = bondy_connect_codec:new(json, ?MAX, ?MAX),
                    {ok, Items, _C1} = decode_all(Chunks, Codec),
                    Items =:= Specs
                end
            )
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).

%% A real WAMP RESULT survives arbitrary fragmentation: encode → split → decode
%% recovers the message field-for-field (request_id, args, kwargs).
prop_codec_message_split_roundtrip(_) ->
    Prop = ?FORALL(
        Msgs,
        non_empty(list(result_msg())),
        begin
            Codec = bondy_connect_codec:new(json, ?MAX, ?MAX),
            Wire = iolist_to_binary([encode_one(M, Codec) || M <- Msgs]),
            ?FORALL(
                Chunks,
                chunking(Wire),
                begin
                    {ok, Items, _C1} = decode_all(Chunks, Codec),
                    length(Items) =:= length(Msgs) andalso
                        lists:all(
                            fun({Exp, Got}) -> result_eq(Exp, Got) end,
                            lists:zip(Msgs, Items)
                        )
                end
            )
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, 100}])).

%% A frame whose declared length exceeds the negotiated max is rejected on the
%% length check alone (before the payload is required), regardless of bytes.
prop_oversize_rejected(_) ->
    Prop = ?FORALL(
        {Max, Extra},
        {range(1, 1024), range(1, 1024)},
        begin
            Len = Max + Extra,
            Frame = bondy_connect_framing:frame(binary:copy(<<0>>, Len)),
            bondy_connect_framing:parse_frame(Frame, Max) =:=
                {error, {message_too_large, Len, Max}}
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).

%% `handshake_request/2` and `parse_handshake/1` are inverse over the valid
%% exponent (0..15) and serializer-code (1..15) ranges. A non-zero serializer
%% nibble is never misread as an error reply.
prop_handshake_roundtrip(_) ->
    Prop = ?FORALL(
        {Exp, Code},
        {range(0, 15), range(1, 15)},
        begin
            Req = bondy_connect_framing:handshake_request(Exp, Code),
            bondy_connect_framing:parse_handshake(Req) =:= {ok, Exp, Code}
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).

%% The per-connection request-id counter stays a valid WAMP id in [1, ?MAX_ID],
%% increments by one below the ceiling, and wraps to 1 at ?MAX_ID (2^53) — never
%% producing 0 or overflowing.
prop_next_id_range_wrap(_) ->
    Prop = ?FORALL(
        Id,
        frequency([
            {6, range(1, ?MAX_ID)},
            {2, ?MAX_ID},
            {1, ?MAX_ID - 1},
            {1, 1}
        ]),
        begin
            Next = bondy_connect_connection:next_id(Id),
            InRange = Next >= 1 andalso Next =< ?MAX_ID,
            Correct =
                case Id >= ?MAX_ID of
                    true -> Next =:= 1;
                    false -> Next =:= Id + 1
                end,
            InRange andalso Correct
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private Wire bytes for a typed frame spec.
frame_bytes({message, P}) -> bondy_connect_framing:frame(P);
frame_bytes({ping, P}) -> bondy_connect_framing:ping_frame(P);
frame_bytes({pong, P}) -> bondy_connect_framing:pong_frame(P).

%% @private Frame and serialize a single message with a throwaway codec.
encode_one(Msg, Codec) ->
    {ok, Frame} = bondy_connect_codec:encode(Msg, Codec),
    Frame.

%% @private An arbitrary chunking of `Bin`: a list of chunk sizes (favouring
%% small splits that straddle frame/header boundaries) consumes the binary, with
%% any remainder delivered as a final chunk. May include empty chunks (size 0),
%% which exercise the no-op `decode(<<>>)` / partial-buffer path.
chunking(Bin) ->
    ?LET(Sizes, list(chunk_size()), split_bin(Bin, Sizes)).

%% @private
chunk_size() ->
    oneof([range(0, 3), range(0, 16), range(0, 300)]).

%% @private
split_bin(<<>>, _Sizes) ->
    [];
split_bin(Bin, []) ->
    [Bin];
split_bin(Bin, [S | Ss]) ->
    Take = min(S, byte_size(Bin)),
    <<Chunk:Take/binary, Rest/binary>> = Bin,
    [Chunk | split_bin(Rest, Ss)].

%% @private Feed chunks to the pure framing parser, threading the buffer the way
%% the codec does. Returns `{LeftoverBuffer, ItemsInOrder}`.
deframe_all(Chunks) ->
    lists:foldl(
        fun(Chunk, {Buf, Acc}) ->
            {Buf1, Items} = deframe(<<Buf/binary, Chunk/binary>>, []),
            {Buf1, Acc ++ Items}
        end,
        {<<>>, []},
        Chunks
    ).

%% @private
deframe(Buf, Acc) ->
    case bondy_connect_framing:parse_frame(Buf, ?MAX) of
        more ->
            {Buf, lists:reverse(Acc)};
        {ok, {Kind, Payload}, Rest} ->
            deframe(Rest, [{Kind, Payload} | Acc])
    end.

%% @private Feed chunks to the real stateful codec, threading its state.
decode_all(Chunks, Codec) ->
    lists:foldl(
        fun(Chunk, {ok, Acc, C}) ->
            {ok, Items, C1} = bondy_connect_codec:decode(Chunk, C),
            {ok, Acc ++ Items, C1}
        end,
        {ok, [], Codec},
        Chunks
    ).

%% @private RESULT equality on the round-tripping fields (details default to #{}
%% on both sides; partial is disabled by the client codec).
result_eq(
    #result{request_id = R, args = A, kwargs = K},
    #result{request_id = R, args = A, kwargs = K}
) ->
    true;
result_eq(_, _) ->
    false.
