%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_raw).

-moduledoc """
Shared implementation of the WAMP **raw socket** transports
(`bondy_connect_transport_tcp`, `bondy_connect_transport_tls`,
`bondy_connect_transport_uds`).

The three are identical on the wire — the same 4-octet handshake and
`bondy_connect_framing` frames — and differ only in the socket backend:

- `tcp` → `gen_tcp`/`inet` with `{tcp, _, _}` active message tags (also used by
  the Unix-domain transport: a UDS stream socket is still a `gen_tcp` socket).
- `tls` → `ssl` with `{ssl, _, _}` active message tags.

The concrete transport modules own only their `connect/2` socket-open strategy
and their `messages/0` tag tuple; everything else — handshake, framing/codec,
synchronous `recv/2`, active `handle_info/2`, and the option/peername/close
plumbing — lives here once, parameterised by the `backend()` carried in the
state.
""".

-record(raw, {
    backend :: backend(),
    socket :: socket(),
    codec :: bondy_connect_codec:t() | undefined,
    max_message_length :: pos_integer()
}).

-define(DEFAULT_HANDSHAKE_TIMEOUT, 5000).

-type backend() :: tcp | tls.
-type socket() :: gen_tcp:socket() | ssl:sslsocket().
-type t() :: #raw{}.

-export_type([backend/0]).
-export_type([t/0]).

%% CONSTRUCTOR
-export([new/3]).

%% SHARED TRANSPORT CALLBACKS
-export([handshake/2]).
-export([send/2]).
-export([ping/2]).
-export([pong/2]).
-export([recv/2]).
-export([handle_data/2]).
-export([handle_info/2]).
-export([setopts/2]).
-export([messages/1]).
-export([peername/1]).
-export([close/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Wrap an already-connected `Socket` in raw-transport state. `Backend` selects the
socket backend (`tcp` → `gen_tcp`/`inet`/`{tcp, _, _}`; `tls` → `ssl`/
`{ssl, _, _}`). The codec is `undefined` until `handshake/2` negotiates it.
""".
-spec new(backend(), socket(), pos_integer()) -> t().

new(Backend, Socket, Max) when
    (Backend == tcp orelse Backend == tls), is_integer(Max), Max > 0
->
    #raw{backend = Backend, socket = Socket, max_message_length = Max}.

-doc "Perform the 4-octet raw-socket handshake and negotiate the codec.".
-spec handshake(bondy_connect_transport:subprotocol(), t()) ->
    {ok, bondy_connect_transport:subprotocol(), t()} | {error, term()}.

handshake(
    {raw, binary, Enc}, #raw{socket = Socket, max_message_length = Max} = St
) ->
    Mod = data_mod(St),
    Code = bondy_connect_framing:serializer_code(Enc),
    Exp = bondy_connect_framing:length_exponent(Max),
    Request = bondy_connect_framing:handshake_request(Exp, Code),
    case Mod:send(Socket, Request) of
        ok ->
            case Mod:recv(Socket, 4, ?DEFAULT_HANDSHAKE_TIMEOUT) of
                {ok, Reply} ->
                    negotiate(Reply, Enc, Exp, St);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc "Encode, frame and send a WAMP record.".
-spec send(bondy_wamp_message:t(), t()) -> ok | {error, term()}.

send(Msg, #raw{socket = Socket, codec = Codec} = St) when Codec =/= undefined ->
    case bondy_connect_codec:encode(Msg, Codec) of
        {ok, Frame} ->
            (data_mod(St)):send(Socket, Frame);
        {error, _} = Error ->
            Error
    end.

-doc "Send a transport keepalive ping carrying `Payload`.".
-spec ping(binary(), t()) -> ok | {error, term()}.

ping(Payload, #raw{socket = Socket} = St) ->
    (data_mod(St)):send(Socket, bondy_connect_framing:ping_frame(Payload)).

-doc "Send a transport keepalive pong (the reply to an inbound ping).".
-spec pong(binary(), t()) -> ok | {error, term()}.

pong(Payload, #raw{socket = Socket} = St) ->
    (data_mod(St)):send(Socket, bondy_connect_framing:pong_frame(Payload)).

-doc "Synchronously read available bytes and decode them.".
-spec recv(timeout(), t()) ->
    {ok, [bondy_connect_transport:inbound()], t()} | {error, term()}.

recv(Timeout, #raw{socket = Socket} = St) ->
    case (data_mod(St)):recv(Socket, 0, Timeout) of
        {ok, Data} ->
            case handle_data(Data, St) of
                {ok, Msgs, St1} ->
                    {ok, Msgs, St1};
                {error, Reason, _St1} ->
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

-doc "Decode bytes delivered as an active-socket `info` message.".
-spec handle_data(binary(), t()) ->
    {ok, [bondy_connect_transport:inbound()], t()} | {error, term(), t()}.

handle_data(Data, #raw{codec = Codec} = St) when Codec =/= undefined ->
    case bondy_connect_codec:decode(Data, Codec) of
        {ok, Msgs, Codec1} ->
            {ok, Msgs, St#raw{codec = Codec1}};
        {error, Reason, Codec1} ->
            {error, Reason, St#raw{codec = Codec1}}
    end.

-doc "Interpret an active-socket `info` message (data / closed / error).".
-spec handle_info(term(), t()) ->
    {ok, [bondy_connect_transport:inbound()], t()}
    | {error, term(), t()}
    | closed
    | ignore.

handle_info(Info, #raw{backend = B, socket = Socket} = St) ->
    {OK, Closed, Error} = messages(B),
    case Info of
        {OK, Socket, Bin} ->
            case handle_data(Bin, St) of
                {ok, Msgs, St1} ->
                    %% Re-arm the socket for the next message (the connection
                    %% only arms the first `{active, once}` after the handshake).
                    _ = (ctl_mod(St)):setopts(Socket, [{active, once}]),
                    {ok, Msgs, St1};
                {error, Reason, St1} ->
                    {error, Reason, St1}
            end;
        {Closed, Socket} ->
            closed;
        {Error, Socket, Reason} ->
            {error, {connection_error, Reason}, St};
        _ ->
            ignore
    end.

-doc "Set socket options (e.g. toggle active mode).".
-spec setopts(list() | map(), t()) -> ok | {error, term()}.

setopts(Opts, #raw{socket = Socket} = St) when is_list(Opts) ->
    (ctl_mod(St)):setopts(Socket, Opts);
setopts(_, _) ->
    {error, badarg}.

-doc "The `{OK, Closed, Error}` inbound message tags for `Backend`.".
-spec messages(backend()) -> {atom(), atom(), atom()}.

messages(tcp) -> {tcp, tcp_closed, tcp_error};
messages(tls) -> {ssl, ssl_closed, ssl_error}.

-doc "The remote peer address.".
-spec peername(t()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.

peername(#raw{socket = Socket} = St) ->
    (ctl_mod(St)):peername(Socket).

-doc "Close the transport.".
-spec close(t()) -> ok.

close(#raw{socket = Socket} = St) ->
    _ = (data_mod(St)):close(Socket),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private The data module (send/recv/close).
data_mod(#raw{backend = tcp}) -> gen_tcp;
data_mod(#raw{backend = tls}) -> ssl.

%% @private The control module (setopts/peername).
ctl_mod(#raw{backend = tcp}) -> inet;
ctl_mod(#raw{backend = tls}) -> ssl.

%% @private Negotiate the codec from the peer's 4-octet handshake reply.
negotiate(Reply, Enc, OurExp, St) ->
    case bondy_connect_framing:parse_handshake(Reply) of
        {ok, TheirExp, TheirCode} ->
            case bondy_connect_framing:code_to_encoding(TheirCode) of
                Enc ->
                    SendMax = bondy_connect_framing:exponent_to_bytes(TheirExp),
                    RecvMax = bondy_connect_framing:exponent_to_bytes(OurExp),
                    Codec = bondy_connect_codec:new(Enc, SendMax, RecvMax),
                    {ok, {raw, binary, Enc}, St#raw{codec = Codec}};
                Other ->
                    {error, {serializer_mismatch, Other}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
