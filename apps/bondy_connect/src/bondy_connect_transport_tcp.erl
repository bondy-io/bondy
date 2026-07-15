%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_tcp).

-moduledoc """
WAMP **raw socket over TCP** transport (`gen_tcp`).

The socket is opened `{packet, 0}` (we do our own framing via
`bondy_connect_framing`) and starts passive so the 4-octet handshake can be read
synchronously. After the handshake the connection process switches it to
`{active, once}` and feeds inbound `{tcp, _, Data}` to `handle_data/2`.

Only `connect/2` (the socket-open) and `messages/0` are specific to this
transport; everything else is shared via `bondy_connect_raw` (review D2).
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
    SockOpts = [binary, {packet, 0}, {active, false}, {nodelay, true}],
    case gen_tcp:connect(Host, Port, SockOpts, Timeout) of
        {ok, Socket} ->
            {ok, bondy_connect_raw:new(tcp, Socket, Max)};
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

-spec messages() -> {tcp, tcp_closed, tcp_error}.

messages() ->
    bondy_connect_raw:messages(tcp).

-spec peername(bondy_connect_raw:t()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.

peername(St) ->
    bondy_connect_raw:peername(St).

-spec close(bondy_connect_raw:t()) -> ok.

close(St) ->
    bondy_connect_raw:close(St).
