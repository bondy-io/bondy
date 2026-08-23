%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_sse).

-moduledoc """
WAMP over Server-Sent Events, against Bondy's `/wamp/sse/*` endpoints.

## Asymmetric by construction

SSE is a one-way server→client stream. WAMP needs both directions, so this
transport is two HTTP conversations at once:

| | |
|---|---|
| receive | `GET /wamp/sse/<id>/receive`, a `text/event-stream` held open |
| send | `POST /wamp/sse/<id>/send`, body is the encoded message, `202` |

Each gets its own `gun` connection. They cannot share one: the stream is open
for the session's lifetime, and on HTTP/1.1 every POST queued behind it would
wait for it to finish, which it never does.

Unlike `m:bondy_connect_transport_longpoll`, the receive half needs no poller
process — the stream pushes, and gun already delivers its chunks as `info`
messages to whoever opened it, which is the connection process. This module's
work on that side is reassembly: `handle_info/2` accumulates chunks and cuts
them into SSE events, because a chunk boundary has nothing to do with an event
boundary.

## Event framing

The server writes `event: wamp` with one `data:` line carrying the encoded WAMP
message (`bondy_http_sse_stream_handler`), and `: keepalive` comments in between.
Events are separated by a blank line, so a `data:` line is only complete once
that blank line has been seen — the reason this module buffers at all.

Comments are discarded rather than surfaced: a keepalive is not a WAMP message
and the connection has nothing to do with it. It does prove the link is alive,
which is why the keepalive note below is not a liveness claim being faked.

## Keepalive

There is no client→server ping on this transport, so `ping/2` answers itself
with a local pong, as `m:bondy_connect_local` does. The stream is the evidence:
the server sends `: keepalive` comments on its own timer
(`listeners.$name.sse.ping.interval`), and a stream that dies arrives here as
`gun_down` or a stream error.

## Encoding

The server advertises `wamp.2.json.sse` only
(`bondy_http_sse_handler:?SUPPORTED_PROTOCOLS`), so `json` is the only
serializer accepted, refused at handshake rather than on the wire.
""".

-behaviour(bondy_connect_transport).

-include_lib("kernel/include/logger.hrl").

-define(SSE_CLOSED, '$bondy_connect_sse_closed').
-define(SSE_ERROR, '$bondy_connect_sse_error').
-define(SSE_LOCAL, '$bondy_connect_sse_local').

-define(DEFAULT_MAX_MESSAGE_LENGTH, 16#1000000).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_REQUEST_TIMEOUT, 15000).
-define(DEFAULT_BASE_PATH, <<"/wamp/sse">>).
-define(PROTOCOL, <<"wamp.2.json.sse">>).
-define(RECONNECT_GRACE, 500).

-record(state, {
    conn_pid :: pid() | undefined,
    stream_conn :: pid() | undefined,
    stream_ref :: reference() | undefined,
    host :: inet:hostname() | inet:ip_address(),
    port :: inet:port_number(),
    gun_opts :: map(),
    base :: binary(),
    transport_id :: binary() | undefined,
    encoding :: bondy_connect_framing:serializer() | undefined,
    max_message_length :: pos_integer(),
    request_timeout :: pos_integer(),
    buffer = <<>> :: binary()
}).

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
%% BEHAVIOUR CALLBACKS
%% =============================================================================

-spec connect(bondy_connect_transport:endpoint(), map()) ->
    {ok, #state{}} | {error, term()}.

connect({Host, Port}, Opts) when is_integer(Port) ->
    Timeout = maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT),
    GunOpts = gun_opts(Host, Opts),

    case open(Host, Port, GunOpts, Timeout) of
        {ok, ConnPid} ->
            {ok, #state{
                conn_pid = ConnPid,
                host = Host,
                port = Port,
                gun_opts = GunOpts,
                base = maps:get(sse_path, Opts, ?DEFAULT_BASE_PATH),
                max_message_length = maps:get(
                    max_message_length, Opts, ?DEFAULT_MAX_MESSAGE_LENGTH
                ),
                request_timeout = maps:get(
                    network_timeout, Opts, ?DEFAULT_REQUEST_TIMEOUT
                )
            }};
        {error, _} = Error ->
            Error
    end.

-spec handshake(bondy_connect_transport:subprotocol(), #state{}) ->
    {ok, bondy_connect_transport:subprotocol(), #state{}} | {error, term()}.

handshake(Sub, #state{} = St) ->
    case serializer(Sub) of
        {ok, json} -> do_handshake(St);
        {ok, Other} -> {error, {unsupported_serializer, Other, [json]}}
    end.

-spec send(bondy_wamp_message:t(), #state{}) -> ok | {error, term()}.

send(Msg, #state{encoding = Enc, max_message_length = Max} = St) when
    Enc =/= undefined
->
    Payload = iolist_to_binary(bondy_wamp_encoding:encode(Msg, Enc)),
    Size = byte_size(Payload),

    case Size =< Max of
        true ->
            case request(path(St, <<"/send">>), Payload, St) of
                {ok, 202, _} -> ok;
                {ok, Status, Body} -> {error, {http_error, Status, Body}};
                {error, _} = Error -> Error
            end;
        false ->
            {error, {message_too_large, Size, Max}}
    end.

-spec ping(binary(), #state{}) -> ok | {error, term()}.

%% See "Keepalive" in the module doc: SSE has no client-to-server ping, and the
%% stream is the liveness evidence.
ping(Payload, #state{}) ->
    self() ! {?SSE_LOCAL, {pong, Payload}},
    ok.

-spec pong(binary(), #state{}) -> ok | {error, term()}.

pong(_Payload, #state{}) ->
    ok.

-spec recv(timeout(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}} | {error, term()}.

%% Synchronous read of the next stream chunk, for tests. The active flow uses
%% `handle_info/2', which is where gun delivers chunks unprompted.
recv(Timeout, #state{stream_conn = Conn, stream_ref = Ref} = St) ->
    receive
        {gun_data, Conn, Ref, _IsFin, Chunk} ->
            case consume(Chunk, St) of
                {ok, Msgs, St1} -> {ok, Msgs, St1};
                {error, Reason, _} -> {error, Reason}
            end
    after Timeout ->
        {error, timeout}
    end.

-spec handle_data(binary(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}}
    | {error, term(), #state{}}.

handle_data(Chunk, #state{} = St) ->
    consume(Chunk, St).

-spec handle_info(term(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}}
    | {error, term(), #state{}}
    | closed
    | ignore.

handle_info({?SSE_LOCAL, Frame}, #state{} = St) ->
    {ok, [Frame], St};
handle_info(
    {gun_data, Conn, Ref, _IsFin, Chunk},
    #state{stream_conn = Conn, stream_ref = Ref} = St
) ->
    consume(Chunk, St);
handle_info(
    {gun_response, Conn, Ref, _, Status, _Headers},
    #state{stream_conn = Conn, stream_ref = Ref} = St
) when Status =/= 200 ->
    {error, {stream_rejected, Status}, St};
handle_info(
    {gun_error, Conn, Ref, Reason},
    #state{stream_conn = Conn, stream_ref = Ref} = St
) ->
    {error, {connection_error, Reason}, St};
%% The STREAM going down ends the session: it is the only inbound path, and
%% unlike the send connection it is never idle — the server keepalives it.
handle_info({gun_down, Conn, _, Reason, _}, #state{stream_conn = Conn} = St) ->
    case Reason of
        normal -> closed;
        closed -> closed;
        _ -> {error, {connection_error, Reason}, St}
    end;
%% The send connection is idle between POSTs and the listener reaps it on its
%% own `http.idle_timeout'; gun reconnects underneath. Not a session event, for
%% the same reason as in `m:bondy_connect_transport_longpoll'.
handle_info({gun_down, ConnPid, _, _, _}, #state{conn_pid = ConnPid}) ->
    ignore;
handle_info({gun_up, _, _}, #state{}) ->
    ignore;
handle_info(_Info, #state{}) ->
    ignore.

-spec setopts(list() | map(), #state{}) -> ok | {error, term()}.

setopts(_Opts, #state{}) ->
    ok.

-spec messages() -> {atom(), atom(), atom()}.

messages() ->
    {gun_data, ?SSE_CLOSED, ?SSE_ERROR}.

-spec peername(#state{}) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.

peername(#state{}) ->
    {error, not_supported}.

-spec close(#state{}) -> ok.

close(#state{conn_pid = undefined}) ->
    ok;
close(#state{} = St) ->
    _ =
        case St#state.transport_id of
            undefined ->
                ok;
            _ ->
                try
                    request(path(St, <<"/close">>), <<>>, St)
                catch
                    _:_ -> ok
                end
        end,
    _ =
        St#state.stream_conn =/= undefined andalso
            gun:close(St#state.stream_conn),
    _ = gun:close(St#state.conn_pid),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_handshake(#state{base = Base} = St) ->
    Body = json:encode(#{<<"protocols">> => [?PROTOCOL]}),

    case request(<<Base/binary, "/open">>, Body, St) of
        {ok, 200, RespBody} ->
            case open_response(RespBody) of
                {ok, Id} ->
                    open_stream(St#state{transport_id = Id, encoding = json});
                {error, _} = Error ->
                    Error
            end;
        {ok, Status, RespBody} ->
            {error, {open_failed, Status, RespBody}};
        {error, _} = Error ->
            Error
    end.

%% @private
open_response(Body) ->
    try json:decode(Body) of
        #{<<"transport">> := Id} when is_binary(Id) -> {ok, Id};
        Other -> {error, {malformed_open_response, Other}}
    catch
        Class:Reason -> {error, {malformed_open_response, Class, Reason}}
    end.

%% @private
%% The stream is opened on its OWN connection and its response headers are
%% awaited here rather than in `handle_info/2', so a rejected stream (404, 401)
%% fails the handshake — where the connection reports it — instead of arriving
%% later as an established session that never receives anything.
open_stream(#state{host = Host, port = Port, gun_opts = GunOpts} = St) ->
    case open(Host, Port, GunOpts, ?DEFAULT_CONNECT_TIMEOUT) of
        {ok, Conn} ->
            Ref = gun:get(Conn, path(St, <<"/receive">>), [
                {<<"accept">>, <<"text/event-stream">>}
            ]),
            case gun:await(Conn, Ref, St#state.request_timeout) of
                {response, nofin, 200, _Headers} ->
                    St1 = St#state{stream_conn = Conn, stream_ref = Ref},
                    {ok, {raw, binary, json}, St1};
                {response, _, Status, _} ->
                    _ = gun:close(Conn),
                    {error, {stream_rejected, Status}};
                {error, Reason} ->
                    _ = gun:close(Conn),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

%% @private
open(Host, Port, GunOpts, Timeout) ->
    case gun:open(Host, Port, GunOpts) of
        {ok, Pid} ->
            case gun:await_up(Pid, Timeout) of
                {ok, _} ->
                    {ok, Pid};
                {error, Reason} ->
                    _ = gun:close(Pid),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

%% @private
%% Appends `Chunk' to whatever was left over and decodes every COMPLETE event in
%% the result. A chunk boundary and an event boundary are unrelated, so the tail
%% is kept: without it a message split across two TCP reads would be decoded as
%% two malformed halves.
consume(Chunk, #state{buffer = Buf} = St) ->
    {Payloads, Rest} = split_events(<<Buf/binary, Chunk/binary>>, []),
    St1 = St#state{buffer = Rest},
    decode_all(Payloads, [], St1).

%% @private
split_events(Bin, Acc) ->
    case binary:split(Bin, <<"\n\n">>) of
        [Event, Rest] ->
            split_events(Rest, add_event(Event, Acc));
        [Incomplete] ->
            {lists:reverse(Acc), Incomplete}
    end.

%% @private
add_event(Event, Acc) ->
    case data_of(binary:split(Event, <<"\n">>, [global]), []) of
        [] -> Acc;
        Datas -> [iolist_to_binary(lists:join(<<"\n">>, Datas)) | Acc]
    end.

%% @private
%% Only `data:' lines carry a WAMP message. `event:' and `id:' are metadata and
%% a leading `:' is a comment — the server's keepalive — all of which are
%% discarded here rather than surfaced as an inbound the connection cannot use.
data_of([], Acc) ->
    lists:reverse(Acc);
data_of([<<"data: ", Rest/binary>> | T], Acc) ->
    data_of(T, [Rest | Acc]);
data_of([<<"data:", Rest/binary>> | T], Acc) ->
    data_of(T, [Rest | Acc]);
data_of([_Other | T], Acc) ->
    data_of(T, Acc).

%% @private
decode_all([], Acc, St) ->
    {ok, lists:reverse(Acc), St};
decode_all([Payload | T], Acc, St) ->
    case decode(Payload, St) of
        {ok, Msgs, St1} -> decode_all(T, lists:reverse(Msgs) ++ Acc, St1);
        {error, _, _} = Error -> Error
    end.

%% @private
decode(Payload, #state{encoding = Enc, max_message_length = Max} = St) when
    Enc =/= undefined
->
    Size = byte_size(Payload),

    case Size =< Max of
        true ->
            Opts = [
                {partial_decode, false}
                | bondy_wamp_encoding:opts(Enc, decode)
            ],
            try bondy_wamp_encoding:decode(subprotocol(St), Payload, Opts) of
                {Msgs, _Ignored} -> {ok, Msgs, St}
            catch
                Class:Reason ->
                    {error, {protocol_error, {decode_failed, Class, Reason}},
                        St}
            end;
        false ->
            {error, {protocol_error, {message_too_large, Size, Max}}, St}
    end.

%% @private
%% The server decodes with `{http_sse, text, json}', so this side uses the same
%% tuple: the encoding layer keys framing decisions off it.
subprotocol(#state{encoding = Enc}) ->
    {http_sse, text, Enc}.

%% @private
serializer({raw, _, Enc}) -> {ok, Enc};
serializer({_, _, Enc}) -> {ok, Enc};
serializer(Enc) when is_atom(Enc) -> {ok, Enc}.

%% @private
path(#state{base = Base, transport_id = Id}, Suffix) when is_binary(Id) ->
    <<Base/binary, "/", Id/binary, Suffix/binary>>.

%% @private
headers() ->
    [{<<"content-type">>, <<"application/json">>}].

%% @private
%% One retry, for the reason given in `m:bondy_connect_transport_longpoll': the
%% send connection is idle between POSTs and the listener reaps it.
request(Path, Body, #state{conn_pid = ConnPid, request_timeout = T}) ->
    case do_request(ConnPid, Path, Body, T) of
        {error, Reason} = Error ->
            case transient(Reason) of
                true ->
                    timer:sleep(?RECONNECT_GRACE),
                    do_request(ConnPid, Path, Body, T);
                false ->
                    Error
            end;
        Result ->
            Result
    end.

%% @private
transient({down, _}) -> true;
transient(noproc) -> true;
transient({shutdown, _}) -> true;
transient(_) -> false.

%% @private
do_request(ConnPid, Path, Body, Timeout) ->
    Ref = gun:post(ConnPid, Path, headers(), Body),

    case gun:await(ConnPid, Ref, Timeout) of
        {response, fin, Status, _} ->
            {ok, Status, <<>>};
        {response, nofin, Status, _} ->
            case gun:await_body(ConnPid, Ref, Timeout) of
                {ok, RespBody} -> {ok, Status, RespBody};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
%% `sse' is plaintext, `sses' is TLS — see the note in
%% `m:bondy_connect_transport_longpoll:gun_opts/2' for why this is keyed on the
%% scheme and not on the presence of a `tls' block.
gun_opts(Host, Opts) ->
    Base = #{
        protocols => [http],
        retry => 5,
        retry_timeout => 250,
        http_opts => #{keepalive => infinity}
    },
    case maps:get(scheme, Opts, sse) of
        sses ->
            TLS = maps:get(tls, Opts, #{}),
            Base#{
                transport => tls,
                tls_opts => bondy_connect_tls:options(Host, TLS)
            };
        _ ->
            Base#{transport => tcp}
    end.
