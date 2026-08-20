%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_codec).

-moduledoc """
Stateful codec for a raw-socket connection: it pairs `bondy_connect_framing`
(the wire format) with `bondy_wamp_encoding` (the payload serializer) and owns
the inbound decode buffer.

- `encode/2` serializes a WAMP record and frames it, enforcing the send-side
  max length.
- `decode/2` appends new bytes to the buffer, deframes every complete frame
  (enforcing the receive-side max length), decodes message payloads to records,
  and surfaces `ping`/`pong` control frames. A malformed frame or payload is
  returned as `{error, {protocol_error, _}}` — **never asserted/crashed**
  (replacing the legacy `wamper_validator` assertions).

The send/receive max lengths are kept separate because WAMP raw socket
negotiates them independently per direction.
""".

-record(codec, {
    encoding :: bondy_connect_framing:serializer(),
    send_max_len :: pos_integer(),
    recv_max_len :: pos_integer(),
    buffer = <<>> :: binary()
}).

-opaque t() :: #codec{}.
-type inbound() ::
    bondy_wamp_message:t()
    | {ping, binary()}
    | {pong, binary()}.

-export_type([t/0]).
-export_type([inbound/0]).

-export([new/3]).
-export([encoding/1]).
-export([encode/2]).
-export([decode/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Create a codec for an encoding and the negotiated per-direction limits.".
-spec new(
    Encoding :: bondy_connect_framing:serializer(),
    SendMaxLen :: pos_integer(),
    RecvMaxLen :: pos_integer()
) -> t().

new(Encoding, SendMaxLen, RecvMaxLen) when
    is_integer(SendMaxLen),
    SendMaxLen > 0,
    is_integer(RecvMaxLen),
    RecvMaxLen > 0
->
    #codec{
        encoding = Encoding,
        send_max_len = SendMaxLen,
        recv_max_len = RecvMaxLen
    }.

-spec encoding(t()) -> bondy_connect_framing:serializer().
encoding(#codec{encoding = Enc}) -> Enc.

-doc "Serialize and frame a WAMP record, enforcing the send-side max length.".
-spec encode(Msg :: bondy_wamp_message:t(), t()) ->
    {ok, binary()}
    | {error,
        {message_too_large, Size :: non_neg_integer(), Max :: pos_integer()}}.

encode(Msg, #codec{encoding = Enc, send_max_len = Max}) ->
    Payload = iolist_to_binary(bondy_wamp_encoding:encode(Msg, Enc)),
    Size = byte_size(Payload),
    case Size =< Max of
        true ->
            {ok, bondy_connect_framing:frame(Payload)};
        false ->
            {error, {message_too_large, Size, Max}}
    end.

-doc """
Append `Data` to the buffer and decode every complete frame. Returns the
decoded inbound items (records + `ping`/`pong`) and the codec with any partial
frame retained, or `{error, {protocol_error, Reason}, Codec}` on a malformed
frame/payload (the buffer is dropped).
""".
-spec decode(Data :: binary(), t()) ->
    {ok, [inbound()], t()}
    | {error, {protocol_error, term()}, t()}.

decode(Data, #codec{buffer = Buffer, recv_max_len = Max} = Codec) ->
    decode_loop(<<Buffer/binary, Data/binary>>, Max, Codec, []).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
decode_loop(Buffer, Max, Codec, Acc) ->
    case bondy_connect_framing:parse_frame(Buffer, Max) of
        more ->
            {ok, lists:reverse(Acc), Codec#codec{buffer = Buffer}};
        {error, Reason} ->
            {error, {protocol_error, Reason}, Codec#codec{buffer = <<>>}};
        {ok, {message, Payload}, Rest} ->
            decode_message(Payload, Rest, Max, Codec, Acc);
        {ok, {Type, Payload}, Rest} ->
            decode_loop(Rest, Max, Codec, [{Type, Payload} | Acc])
    end.

%% @private
decode_message(Payload, Rest, Max, #codec{encoding = Enc} = Codec, Acc) ->
    %% Partial decoding (`partial_decode => true', the default for json/cbor) is
    %% a router-side passthrough optimisation: it parses only the routing head
    %% and leaves Args/KWArgs as an unparsed binary so a router can re-route a
    %% payload without decoding it. A client is the final consumer, so we
    %% disable it and fully decode every message. We override only that flag,
    %% keeping each serializer's required options (e.g. msgpack's map_format).
    Opts = [{partial_decode, false} | bondy_wamp_encoding:opts(Enc, decode)],
    try bondy_wamp_encoding:decode({raw, binary, Enc}, Payload, Opts) of
        {Msgs, _Ignored} ->
            decode_loop(Rest, Max, Codec, lists:reverse(Msgs) ++ Acc)
    catch
        Class:Reason ->
            {error, {protocol_error, {decode_failed, Class, Reason}},
                Codec#codec{buffer = <<>>}}
    end.
