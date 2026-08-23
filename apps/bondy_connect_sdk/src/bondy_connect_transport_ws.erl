%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_ws).

-moduledoc """
WAMP-over-**WebSocket** transport (ws/wss) via [gun](https://hex.pm/packages/gun).

Unlike the raw-socket transports there is **no 4-octet handshake and no raw
framing**: the WebSocket layer is the framing, and *each WebSocket message
carries exactly one WAMP message* (RFC). So this transport talks to
`bondy_wamp_encoding` directly (payload only) instead of `bondy_connect_codec`.

## Subprotocol negotiation

The WAMP serializer is negotiated during the WebSocket opening handshake via the
`Sec-WebSocket-Protocol` header. We offer the configured serializers in
preference order as `wamp.2.json` / `wamp.2.msgpack` / `wamp.2.cbor`; the router
picks one. Per the RFC, `wamp.2.json` uses **text** frames and the binary
serializers use **binary** frames.

## Keepalive

WebSocket has its own ping/pong control frames. The connection drives keepalive
(`ping/2`); gun is configured with `silence_pings => false` so the matching
**pong** is delivered and resets the idle timer. gun auto-responds to *inbound*
pings, so we drop them here to avoid a double pong.

## Flow control

gun pushes frames as `{gun_ws, …}` messages with `flow => infinity`, so there is
no per-message re-arm (the `{active, once}` cycle of the raw transports).

## Message size

Both directions are bounded by `max_message_length`: outbound in `send/2`,
inbound in `decode_payload/2` (checked before the payload is decoded into
terms). gun exposes no WebSocket max-frame-size option, so this application-level
check is what protects against an oversized inbound frame.

## TLS (wss)

`wss` TLS options are built by the shared `bondy_connect_tls` module, so they are
**secure by default** (`verify_peer`) and carry the same mutual-TLS
(`certfile`/`keyfile`) and `ciphers` support as the raw `tls` transport.
""".

-behaviour(bondy_connect_transport).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-record(state, {
    conn_pid :: pid() | undefined,
    stream_ref :: reference() | undefined,
    encoding :: bondy_connect_framing:serializer() | undefined,
    frame_kind :: text | binary | undefined,
    max_message_length :: pos_integer(),
    serializers :: [bondy_connect_framing:serializer()],
    path :: iodata()
}).

%% 16 MB
-define(DEFAULT_MAX_MESSAGE_LENGTH, 16#1000000).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_HANDSHAKE_TIMEOUT, 5000).
-define(DEFAULT_PATH, <<"/ws">>).

-export([connect/2]).
-export([handshake/2]).
-export([send/2]).
-export([ping/2]).
-export([pong/2]).
-export([recv/2]).
-export([handle_data/2]).
-export([handle_info/2]).
-export([setopts/2]).
-export([messages/0]).
-export([peername/1]).
-export([close/1]).

%% =============================================================================
%% bondy_connect_transport CALLBACKS
%% =============================================================================

-spec connect(bondy_connect_transport:endpoint(), map()) ->
    {ok, #state{}} | {error, term()}.

connect({Host, Port}, Opts) when is_integer(Port) ->
    Timeout = maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT),
    Max = maps:get(max_message_length, Opts, ?DEFAULT_MAX_MESSAGE_LENGTH),
    Serializers = maps:get(serializers, Opts, [json]),
    Path = maps:get(ws_path, Opts, ?DEFAULT_PATH),
    case gun:open(Host, Port, gun_opts(Host, Opts)) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, Timeout) of
                {ok, _Protocol} ->
                    St = #state{
                        conn_pid = ConnPid,
                        max_message_length = Max,
                        serializers = Serializers,
                        path = Path
                    },
                    {ok, St};
                {error, Reason} ->
                    _ = gun:close(ConnPid),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

-spec handshake(bondy_connect_transport:subprotocol(), #state{}) ->
    {ok, bondy_connect_transport:subprotocol(), #state{}} | {error, term()}.

handshake(
    _Sub, #state{conn_pid = ConnPid, path = Path, serializers = Sers} = St
) ->
    Protocols = [{subprotocol_token(S), gun_ws_h} || S <- Sers],
    WsOpts = #{silence_pings => false, protocols => Protocols},
    StreamRef = gun:ws_upgrade(ConnPid, Path, [], WsOpts),
    case gun:await(ConnPid, StreamRef, ?DEFAULT_HANDSHAKE_TIMEOUT) of
        {upgrade, [<<"websocket">>], Headers} ->
            case negotiated(Headers) of
                {ok, Enc, Kind} ->
                    St1 = St#state{
                        stream_ref = StreamRef,
                        encoding = Enc,
                        frame_kind = Kind
                    },
                    %% `Enc' is the router's pick out of the list offered
                    %% above, which need not be the first one — the connection
                    %% keeps this as its negotiated subprotocol.
                    {ok, {raw, binary, Enc}, St1};
                {error, _} = Error ->
                    Error
            end;
        {response, _IsFin, Status, _Headers} ->
            {error, {ws_upgrade_failed, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec send(bondy_wamp_message:t(), #state{}) -> ok | {error, term()}.

send(
    Msg,
    #state{encoding = Enc, frame_kind = Kind, max_message_length = Max} = St
) when
    Enc =/= undefined
->
    #state{conn_pid = ConnPid, stream_ref = StreamRef} = St,
    Payload = iolist_to_binary(bondy_wamp_encoding:encode(Msg, Enc)),
    Size = byte_size(Payload),
    case Size =< Max of
        true ->
            gun:ws_send(ConnPid, StreamRef, {Kind, Payload});
        false ->
            {error, {message_too_large, Size, Max}}
    end.

-spec ping(binary(), #state{}) -> ok | {error, term()}.

ping(Payload, #state{conn_pid = ConnPid, stream_ref = StreamRef}) ->
    gun:ws_send(ConnPid, StreamRef, {ping, Payload}).

-spec pong(binary(), #state{}) -> ok | {error, term()}.

pong(Payload, #state{conn_pid = ConnPid, stream_ref = StreamRef}) ->
    gun:ws_send(ConnPid, StreamRef, {pong, Payload}).

-spec recv(timeout(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}} | {error, term()}.

recv(Timeout, #state{conn_pid = ConnPid, stream_ref = StreamRef} = St) ->
    case gun:await(ConnPid, StreamRef, Timeout) of
        {ws, Frame} ->
            case handle_frame(Frame, St) of
                {ok, Msgs, St1} ->
                    {ok, Msgs, St1};
                {error, Reason, _St1} ->
                    {error, Reason};
                closed ->
                    {error, closed}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec handle_data(binary(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}}
    | {error, term(), #state{}}.

handle_data(Payload, #state{} = St) ->
    decode_payload(Payload, St).

-spec handle_info(term(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}}
    | {error, term(), #state{}}
    | closed
    | ignore.

handle_info(
    {gun_ws, ConnPid, StreamRef, Frame},
    #state{conn_pid = ConnPid, stream_ref = StreamRef} = St
) ->
    handle_frame(Frame, St);
handle_info(
    {gun_down, ConnPid, _Protocol, Reason, _Killed},
    #state{conn_pid = ConnPid} = St
) ->
    case Reason of
        normal -> closed;
        closed -> closed;
        _ -> {error, {connection_error, Reason}, St}
    end;
handle_info(
    {gun_error, ConnPid, _StreamRef, Reason},
    #state{conn_pid = ConnPid} = St
) ->
    {error, {connection_error, Reason}, St};
handle_info({gun_error, ConnPid, Reason}, #state{conn_pid = ConnPid} = St) ->
    {error, {connection_error, Reason}, St};
handle_info(_Info, _St) ->
    ignore.

-spec setopts(list() | map(), #state{}) -> ok | {error, term()}.

%% gun manages its own flow control (`flow => infinity'), so the connection's
%% post-handshake `{active, once}' is a no-op here.
setopts(_Opts, #state{}) ->
    ok.

-spec messages() -> {atom(), atom(), atom()}.
messages() ->
    {gun_ws, gun_down, gun_error}.

-spec peername(#state{}) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(#state{}) ->
    {error, not_supported}.

-spec close(#state{}) -> ok.
close(#state{conn_pid = undefined}) ->
    ok;
close(#state{conn_pid = ConnPid}) ->
    _ = gun:close(ConnPid),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private Translate a gun WebSocket frame into inbound records.
handle_frame({text, Bin}, St) ->
    decode_payload(Bin, St);
handle_frame({binary, Bin}, St) ->
    decode_payload(Bin, St);
handle_frame({pong, Payload}, St) ->
    %% Our keepalive ping was answered; surface it so the idle timer resets.
    {ok, [{pong, Payload}], St};
handle_frame(pong, St) ->
    {ok, [{pong, <<>>}], St};
handle_frame({ping, _Payload}, St) ->
    %% gun has already auto-responded with a pong; do not double-pong.
    {ok, [], St};
handle_frame(ping, St) ->
    {ok, [], St};
handle_frame(close, _St) ->
    closed;
handle_frame({close, _Code, _Reason}, _St) ->
    closed.

%% @private Decode one WebSocket message payload into a WAMP record. Each WS
%% message carries exactly one WAMP message, so there is no buffering. A decode
%% failure is surfaced as a protocol error, never an assertion crash.
%%
%% The inbound payload is bounded by `max_message_length` **before** decoding:
%% gun has no WebSocket max-frame-size option, so a hostile/slow router could
%% otherwise force decode of an arbitrarily large frame into terms (an
%% asymmetric DoS). This mirrors the raw transports, which reject oversized
%% frames pre-materialization in `bondy_connect_framing`.
decode_payload(
    Payload, #state{encoding = Enc, max_message_length = Max} = St
) when
    Enc =/= undefined
->
    Size = byte_size(Payload),
    case Size =< Max of
        true ->
            Sub = subprotocol_tuple(St),
            Opts = [
                {partial_decode, false} | bondy_wamp_encoding:opts(Enc, decode)
            ],
            try bondy_wamp_encoding:decode(Sub, Payload, Opts) of
                {Msgs, _Ignored} ->
                    {ok, Msgs, St}
            catch
                Class:Reason ->
                    {error, {protocol_error, {decode_failed, Class, Reason}},
                        St}
            end;
        false ->
            {error, {protocol_error, {message_too_large, Size, Max}}, St}
    end.

%% @private The `bondy_wamp_encoding' subprotocol tuple for this session's
%% encoding (json is carried in text frames, the binary serializers in binary).
subprotocol_tuple(#state{encoding = json}) -> {ws, text, json};
subprotocol_tuple(#state{encoding = Enc}) -> {ws, binary, Enc}.

%% @private
subprotocol_token(json) -> ?WAMP2_JSON;
subprotocol_token(msgpack) -> ?WAMP2_MSGPACK;
subprotocol_token(cbor) -> ?WAMP2_CBOR.

%% @private Resolve the router-selected subprotocol from the upgrade response.
negotiated(Headers) ->
    case lists:keyfind(<<"sec-websocket-protocol">>, 1, Headers) of
        {_, ?WAMP2_JSON} -> {ok, json, text};
        {_, ?WAMP2_MSGPACK} -> {ok, msgpack, binary};
        {_, ?WAMP2_CBOR} -> {ok, cbor, binary};
        {_, Other} -> {error, {unsupported_subprotocol, Other}};
        false -> {error, no_subprotocol_selected}
    end.

%% @private Assemble the `gun:open/3' options. ws ⇒ tcp, wss ⇒ tls. The TLS
%% options are the shared, secure-by-default set (`bondy_connect_tls`), giving
%% wss the same mTLS/cipher support as the raw `tls` transport.
%% `protocols => [http]' forces HTTP/1.1, required for the ws upgrade;
%% `retry => 0' leaves reconnection to the connection's own backoff.
gun_opts(Host, Opts) ->
    Base = #{protocols => [http], retry => 0},
    case maps:get(scheme, Opts, ws) of
        wss ->
            TLS = maps:get(tls, Opts, #{}),
            Base#{
                transport => tls,
                tls_opts => bondy_connect_tls:options(Host, TLS)
            };
        _ ->
            Base#{transport => tcp}
    end.
