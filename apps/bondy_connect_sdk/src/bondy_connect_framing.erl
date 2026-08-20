%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_framing).

-moduledoc """
Pure helpers for the **WAMP raw socket** wire format (RFC raw transport), shared
by the raw-socket transports (`tcp`/`tls`/`uds`). `bondy_wamp_encoding` encodes
the *payload* only — framing is the transport's job, so it lives here.

## Handshake (4 octets)

```
octet 0: 0x7F (magic)
octet 1: <<LengthExp:4, Serializer:4>>
octet 2-3: 0x00 0x00 (reserved)
```

`LengthExp` selects the max message length `2^(9+LengthExp)` (512 B … 16 MB);
`Serializer` is `1=json | 2=msgpack | 3=cbor`. The router's reply has the same
shape; a reply whose serializer nibble is `0` is an **error** with the code in
the high nibble.

## Frame

```
octet 0: <<0:5 (reserved), Type:3>>   Type = 0 message | 1 ping | 2 pong
octet 1-3: Length:24 (payload octets, big-endian)
octet 4..: payload
```
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

%% `serializer'/`frame_kind' rather than the bondy_wamp.hrl `encoding'/
%% `frame_type' (which mean the broad serializer set and text|binary) — these
%% are the raw-socket-specific narrow types.
-type serializer() :: json | msgpack | cbor.
-type frame_kind() :: message | ping | pong.
-type handshake_error() ::
    serializer_unsupported
    | maximum_message_length_unacceptable
    | use_of_reserved_bits
    | maximum_connection_count_reached
    | {unknown_error, 0..15}
    | invalid_handshake.

-export_type([serializer/0]).
-export_type([frame_kind/0]).
-export_type([handshake_error/0]).

%% Serializer / length codes
-export([serializer_code/1]).
-export([code_to_encoding/1]).
-export([length_exponent/1]).
-export([exponent_to_bytes/1]).
%% Handshake
-export([handshake_request/2]).
-export([parse_handshake/1]).
-export([error_reason/1]).
%% Frames
-export([frame/1]).
-export([ping_frame/1]).
-export([pong_frame/1]).
-export([parse_frame/2]).

%% =============================================================================
%% SERIALIZER / LENGTH CODES
%% =============================================================================

-doc "The raw-socket serializer code for an encoding (`1`/`2`/`3`).".
-spec serializer_code(serializer()) -> 1..3.
serializer_code(json) -> 1;
serializer_code(msgpack) -> 2;
serializer_code(cbor) -> 3.

-doc "The encoding for a raw-socket serializer code (`undefined` if unknown).".
-spec code_to_encoding(0..15) -> serializer() | undefined.
code_to_encoding(1) -> json;
code_to_encoding(2) -> msgpack;
code_to_encoding(3) -> cbor;
code_to_encoding(_) -> undefined.

-doc """
The largest length-exponent code (0..15) whose `2^(9+code)` does not exceed
`Bytes` (clamped to the 512 B … 16 MB range).
""".
-spec length_exponent(pos_integer()) -> 0..15.
length_exponent(Bytes) when is_integer(Bytes), Bytes >= 512 ->
    exp_search(Bytes, 0);
length_exponent(_) ->
    0.

-doc "The max message length in octets for a length-exponent code.".
-spec exponent_to_bytes(0..15) -> pos_integer().
exponent_to_bytes(N) when is_integer(N), N >= 0, N =< 15 ->
    1 bsl (9 + N).

%% =============================================================================
%% HANDSHAKE
%% =============================================================================

-doc "Build the 4-octet client handshake request.".
-spec handshake_request(Exp :: 0..15, SerializerCode :: 1..15) -> binary().
handshake_request(Exp, Code) when
    is_integer(Exp),
    Exp >= 0,
    Exp =< 15,
    is_integer(Code),
    Code >= 1,
    Code =< 15
->
    <<?RAW_MAGIC:8, Exp:4, Code:4, 0:16>>.

-doc """
Parse the router's 4-octet handshake reply: `{ok, Exp, SerializerCode}` on
success, or `{error, Reason}` on an error reply / malformed bytes.
""".
-spec parse_handshake(binary()) ->
    {ok, Exp :: 0..15, SerializerCode :: 1..15} | {error, handshake_error()}.

%% An error reply carries the code in the high nibble and a zero serializer
%% nibble; check it first so a zero serializer is never read as success.
parse_handshake(<<?RAW_MAGIC:8, Code:4, 0:4, 0:16>>) ->
    {error, error_reason(Code)};
parse_handshake(<<?RAW_MAGIC:8, Exp:4, Code:4, 0:16>>) ->
    {ok, Exp, Code};
parse_handshake(_) ->
    {error, invalid_handshake}.

-doc "Map a raw-socket handshake error code to a reason.".
-spec error_reason(0..15) -> handshake_error().
error_reason(1) -> serializer_unsupported;
error_reason(2) -> maximum_message_length_unacceptable;
error_reason(3) -> use_of_reserved_bits;
error_reason(4) -> maximum_connection_count_reached;
error_reason(N) -> {unknown_error, N}.

%% =============================================================================
%% FRAMES
%% =============================================================================

-doc "Frame a (already-encoded) message payload.".
-spec frame(binary()) -> binary().
frame(Payload) when is_binary(Payload) ->
    ?RAW_FRAME(Payload).

-doc "Build a ping frame.".
-spec ping_frame(binary()) -> binary().
ping_frame(Payload) when is_binary(Payload) ->
    <<(?RAW_PING_PREFIX)/binary, (byte_size(Payload)):24, Payload/binary>>.

-doc "Build a pong frame.".
-spec pong_frame(binary()) -> binary().
pong_frame(Payload) when is_binary(Payload) ->
    <<(?RAW_PONG_PREFIX)/binary, (byte_size(Payload)):24, Payload/binary>>.

-doc """
Parse one frame off the front of `Buffer`, enforcing `MaxLen`:

- `{ok, {Type, Payload}, Rest}` — a complete frame (`Type` =
  `message | ping | pong`).
- `more` — not enough bytes yet (header incomplete, or payload incomplete).
- `{error, Reason}` — oversize (`{message_too_large, Len, MaxLen}`), reserved
  bits set, or an unsupported frame type. The length is checked *before* the
  payload is required, so an oversize frame is rejected without buffering it.
""".
-spec parse_frame(Buffer :: binary(), MaxLen :: pos_integer()) ->
    {ok, {frame_kind(), binary()}, Rest :: binary()}
    | more
    | {error, term()}.

parse_frame(<<Reserved:5, Type:3, Len:24, Body/binary>>, MaxLen) ->
    if
        Len > MaxLen ->
            {error, {message_too_large, Len, MaxLen}};
        Reserved =/= 0 ->
            {error, use_of_reserved_bits};
        true ->
            case Body of
                <<Payload:Len/binary, Rest/binary>> ->
                    classify(Type, Payload, Rest);
                _ ->
                    more
            end
    end;
parse_frame(_Partial, _MaxLen) ->
    more.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
classify(0, Payload, Rest) -> {ok, {message, Payload}, Rest};
classify(1, Payload, Rest) -> {ok, {ping, Payload}, Rest};
classify(2, Payload, Rest) -> {ok, {pong, Payload}, Rest};
classify(Type, _, _) -> {error, {unsupported_frame_type, Type}}.

%% @private
exp_search(Bytes, N) when N < 15, (1 bsl (9 + N + 1)) =< Bytes ->
    exp_search(Bytes, N + 1);
exp_search(_Bytes, N) ->
    N.
