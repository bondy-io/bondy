%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_tls).

-moduledoc """
WAMP **raw socket over TLS** transport (`ssl`).

Identical on the wire to `bondy_connect_transport_tcp` — the same 4-octet
handshake and `bondy_connect_framing` frames — but over a TLS-secured socket.
Only `connect/2` (the secure socket-open) and `messages/0` are specific to this
transport; everything else is shared via `bondy_connect_raw`.

## Secure by default

The TLS options are built by `bondy_connect_tls` (shared with the `wss`
transport), **secure by default** (`verify_peer`): server-certificate
verification against the user's CA or the OS trust store, hostname/SNI checking,
a TLS 1.2+ floor, optional mutual TLS (`certfile`/`keyfile`) and ciphers.
`tls => #{verify => verify_none}` disables verification and is logged at warning
level — local testing only.
""".

-behaviour(bondy_connect_transport).

%% 16 MB
-define(DEFAULT_MAX_MESSAGE_LENGTH, 16#1000000).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).

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
    {ok, bondy_connect_raw:t()} | {error, term()}.

connect({Host, Port}, Opts) when is_integer(Port) ->
    Timeout = maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT),
    Max = maps:get(max_message_length, Opts, ?DEFAULT_MAX_MESSAGE_LENGTH),
    SslOpts = ssl_opts(Host, Opts),
    case ssl:connect(Host, Port, SslOpts, Timeout) of
        {ok, Socket} ->
            {ok, bondy_connect_raw:new(tls, Socket, Max)};
        {error, _} = Error ->
            Error
    end.

-spec handshake(bondy_connect_transport:subprotocol(), bondy_connect_raw:t()) ->
    {ok, bondy_connect_transport:subprotocol(), bondy_connect_raw:t()}
    | {error, term()}.

handshake(Sub, St) ->
    bondy_connect_raw:handshake(Sub, St).

-spec send(bondy_wamp_message:t(), bondy_connect_raw:t()) ->
    ok | {error, term()}.

send(Msg, St) ->
    bondy_connect_raw:send(Msg, St).

-spec ping(binary(), bondy_connect_raw:t()) -> ok | {error, term()}.

ping(Payload, St) ->
    bondy_connect_raw:ping(Payload, St).

-spec pong(binary(), bondy_connect_raw:t()) -> ok | {error, term()}.

pong(Payload, St) ->
    bondy_connect_raw:pong(Payload, St).

-spec recv(timeout(), bondy_connect_raw:t()) ->
    {ok, [bondy_connect_transport:inbound()], bondy_connect_raw:t()}
    | {error, term()}.

recv(Timeout, St) ->
    bondy_connect_raw:recv(Timeout, St).

-spec handle_data(binary(), bondy_connect_raw:t()) ->
    {ok, [bondy_connect_transport:inbound()], bondy_connect_raw:t()}
    | {error, term(), bondy_connect_raw:t()}.

handle_data(Data, St) ->
    bondy_connect_raw:handle_data(Data, St).

-spec handle_info(term(), bondy_connect_raw:t()) ->
    {ok, [bondy_connect_transport:inbound()], bondy_connect_raw:t()}
    | {error, term(), bondy_connect_raw:t()}
    | closed
    | ignore.

handle_info(Info, St) ->
    bondy_connect_raw:handle_info(Info, St).

-spec setopts(list() | map(), bondy_connect_raw:t()) -> ok | {error, term()}.

setopts(Opts, St) ->
    bondy_connect_raw:setopts(Opts, St).

-spec messages() -> {ssl, ssl_closed, ssl_error}.

messages() ->
    bondy_connect_raw:messages(tls).

-spec peername(bondy_connect_raw:t()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.

peername(St) ->
    bondy_connect_raw:peername(St).

-spec close(bondy_connect_raw:t()) -> ok.

close(St) ->
    bondy_connect_raw:close(St).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private Assemble the `ssl:connect/4` options: the raw-socket base plus the
%% shared, secure-by-default TLS options (`bondy_connect_tls`).
ssl_opts(Host, Opts) ->
    TLS = maps:get(tls, Opts, #{}),
    Base = [binary, {packet, 0}, {active, false}, {nodelay, true}],
    Base ++ bondy_connect_tls:options(Host, TLS).
