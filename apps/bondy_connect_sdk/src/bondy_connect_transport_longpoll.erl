%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_longpoll).

-moduledoc """
WAMP over HTTP long-poll, against Bondy's `/wamp/longpoll/*` endpoints.

## The shape problem

`m:bondy_connect_transport` is socket-shaped: a transport is expected to own a
bidirectional connection whose inbound bytes arrive as `info` messages. Long-poll
has no such thing. It is request/response in both directions:

| | |
|---|---|
| send | `POST /wamp/longpoll/<id>/send`, body is the encoded message, `202` |
| receive | `POST /wamp/longpoll/<id>/receive`, blocks server-side, `200` with ONE message or `204` on timeout |

This module supplies the missing half. It owns a **poller process** that loops on
`/receive` and forwards each message to the connection process as an `info`
message, which `handle_info/2` then decodes — so `m:bondy_connect_connection`
sees the same active-inbound flow it sees from a socket, and needs no long-poll
knowledge of its own.

## Two HTTP connections

The poller owns its own `gun` connection, separate from the one `send/2` uses.
They cannot share: HTTP/1.1 is ordered, so a `/receive` parked server-side for
`poll_timeout` would block every `/send` queued behind it on the same
connection. This is what a browser client does too.

## Keepalive

There is no long-poll transport ping, so `ping/2` answers itself with a local
pong, exactly as `m:bondy_connect_local` does. That is not a liveness claim
being faked: the poll loop is continuously exercising the link, and a failed
`/receive` reports through `handle_info/2` as a transport error, which is
strictly better evidence than a ping — it covers the idle case the ping was for.

## Encoding

The server advertises `wamp.2.json` only for this transport
(`bondy_http_longpoll_handler:?SUPPORTED_PROTOCOLS`), so `json` is the only
serializer accepted here; anything else is refused at handshake rather than
failing later on the wire.
""".

-behaviour(bondy_connect_transport).

-include_lib("kernel/include/logger.hrl").

%% Inbound tags. Namespaced rather than bare atoms because they travel to the
%% connection process, which routes every unrecognised `info' to `handle_info/2'.
-define(LP_DATA, '$bondy_connect_longpoll_data').
-define(LP_CLOSED, '$bondy_connect_longpoll_closed').
-define(LP_ERROR, '$bondy_connect_longpoll_error').

-define(DEFAULT_MAX_MESSAGE_LENGTH, 16#1000000).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_REQUEST_TIMEOUT, 15000).
-define(DEFAULT_BASE_PATH, <<"/wamp/longpoll">>).
-define(PROTOCOL, <<"wamp.2.json">>).

%% How long the poller waits for `/receive'. The server's own `poll_timeout'
%% defaults to 30s and it answers `204' at that point, so this must EXCEED it or
%% the poller would abandon every poll one round-trip before the server replied,
%% turning a quiet link into a busy loop.
-define(DEFAULT_POLL_TIMEOUT, 60000).

%% How long to let gun re-establish a connection the listener reaped for being
%% idle, before deciding the failure is the server's and not the timer's.
-define(RECONNECT_GRACE, 500).

-record(state, {
    conn_pid :: pid() | undefined,
    poller :: pid() | undefined,
    poller_ref :: reference() | undefined,
    host :: inet:hostname() | inet:ip_address(),
    port :: inet:port_number(),
    gun_opts :: map(),
    base :: binary(),
    transport_id :: binary() | undefined,
    encoding :: bondy_connect_framing:serializer() | undefined,
    max_message_length :: pos_integer(),
    request_timeout :: pos_integer(),
    poll_timeout :: pos_integer()
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

%% Poller entry point; exported for `spawn/3' and for tracing.
-export([poll_loop/4]).

%% =============================================================================
%% BEHAVIOUR CALLBACKS
%% =============================================================================

-spec connect(bondy_connect_transport:endpoint(), map()) ->
    {ok, #state{}} | {error, term()}.

connect({Host, Port}, Opts) when is_integer(Port) ->
    Timeout = maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT),
    GunOpts = gun_opts(Host, Opts),

    case gun:open(Host, Port, GunOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, Timeout) of
                {ok, _Protocol} ->
                    {ok, #state{
                        conn_pid = ConnPid,
                        host = Host,
                        port = Port,
                        gun_opts = GunOpts,
                        base = maps:get(
                            longpoll_path, Opts, ?DEFAULT_BASE_PATH
                        ),
                        max_message_length = maps:get(
                            max_message_length,
                            Opts,
                            ?DEFAULT_MAX_MESSAGE_LENGTH
                        ),
                        request_timeout = maps:get(
                            network_timeout, Opts, ?DEFAULT_REQUEST_TIMEOUT
                        ),
                        poll_timeout = maps:get(
                            longpoll_poll_timeout, Opts, ?DEFAULT_POLL_TIMEOUT
                        )
                    }};
                {error, Reason} ->
                    _ = gun:close(ConnPid),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

-spec handshake(bondy_connect_transport:subprotocol(), #state{}) ->
    {ok, bondy_connect_transport:subprotocol(), #state{}} | {error, term()}.

handshake(Sub, #state{} = St) ->
    case serializer(Sub) of
        {ok, json} ->
            do_handshake(St);
        {ok, Other} ->
            {error, {unsupported_serializer, Other, [json]}}
    end.

-spec send(bondy_wamp_message:t(), #state{}) -> ok | {error, term()}.

send(Msg, #state{encoding = Enc, max_message_length = Max} = St) when
    Enc =/= undefined
->
    Payload = iolist_to_binary(bondy_wamp_encoding:encode(Msg, Enc)),
    Size = byte_size(Payload),

    case Size =< Max of
        true ->
            case request(post, path(St, <<"/send">>), Payload, St) of
                {ok, 202, _Body} -> ok;
                {ok, Status, Body} -> {error, {http_error, Status, Body}};
                {error, _} = Error -> Error
            end;
        false ->
            {error, {message_too_large, Size, Max}}
    end.

-spec ping(binary(), #state{}) -> ok | {error, term()}.

%% See the "Keepalive" section of the module doc: there is no long-poll wire
%% ping, and the poll loop is the liveness evidence.
ping(Payload, #state{}) ->
    self() ! {?LP_DATA, self(), {pong, Payload}},
    ok.

-spec pong(binary(), #state{}) -> ok | {error, term()}.

pong(_Payload, #state{}) ->
    ok.

-spec recv(timeout(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}} | {error, term()}.

%% A single synchronous poll on the SEND connection, for the handshake and for
%% tests. The active flow uses the poller and `handle_info/2'.
recv(Timeout, #state{} = St) ->
    case request(post, path(St, <<"/receive">>), <<>>, Timeout, St) of
        {ok, 200, Body} ->
            case decode(Body, St) of
                {ok, Msgs, St1} -> {ok, Msgs, St1};
                {error, Reason, _} -> {error, Reason}
            end;
        {ok, 204, _} ->
            {ok, [], St};
        {ok, Status, Body} ->
            {error, {http_error, Status, Body}};
        {error, _} = Error ->
            Error
    end.

-spec handle_data(binary(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}}
    | {error, term(), #state{}}.

handle_data(Payload, #state{} = St) ->
    decode(Payload, St).

-spec handle_info(term(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}}
    | {error, term(), #state{}}
    | closed
    | ignore.

%% A synthesised control frame (see `ping/2') travels as a term, not bytes.
handle_info({?LP_DATA, _Pid, {pong, _} = Frame}, #state{} = St) ->
    {ok, [Frame], St};
handle_info({?LP_DATA, Poller, Body}, #state{poller = Poller} = St) ->
    decode(Body, St);
handle_info({?LP_CLOSED, Poller}, #state{poller = Poller}) ->
    closed;
handle_info({?LP_ERROR, Poller, Reason}, #state{poller = Poller} = St) ->
    {error, {connection_error, Reason}, St};
handle_info(
    {'DOWN', Ref, process, _Pid, Reason}, #state{poller_ref = Ref} = St
) ->
    %% The poller is the only inbound path; without it this transport is deaf,
    %% so its death is a transport failure rather than something to restart
    %% quietly. `m:bondy_connect_connection' owns the reconnect policy.
    case Reason of
        normal -> closed;
        shutdown -> closed;
        _ -> {error, {poller_down, Reason}, St}
    end;
%% The send connection going down is NOT a session event. It carries one POST at
%% a time and is idle in between, so the listener closes it on its own
%% `http.idle_timeout' during any quiet period; gun reconnects underneath and
%% the session continues. Liveness is the poll loop's to report, and it does,
%% through `?LP_ERROR' and the poller monitor.
handle_info({gun_down, ConnPid, _, _Reason, _}, #state{conn_pid = ConnPid}) ->
    ignore;
handle_info({gun_up, ConnPid, _}, #state{conn_pid = ConnPid}) ->
    ignore;
handle_info(_Info, #state{}) ->
    ignore.

-spec setopts(list() | map(), #state{}) -> ok | {error, term()}.

%% Nothing to configure: the poller is always active and gun manages its own
%% flow control, so the connection's post-handshake `{active, once}' is a no-op.
setopts(_Opts, #state{}) ->
    ok.

-spec messages() -> {atom(), atom(), atom()}.

messages() ->
    {?LP_DATA, ?LP_CLOSED, ?LP_ERROR}.

-spec peername(#state{}) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.

peername(#state{}) ->
    {error, not_supported}.

-spec close(#state{}) -> ok.

close(#state{conn_pid = undefined}) ->
    ok;
close(#state{} = St) ->
    %% Best effort, in this order: tell the server, then stop polling, then drop
    %% the sockets. `/close' first so the server tears the session down rather
    %% than waiting out `wamp.http_transport.idle_timeout'.
    _ =
        case St#state.transport_id of
            undefined ->
                ok;
            _ ->
                try
                    request(post, path(St, <<"/close">>), <<>>, St)
                catch
                    _:_ -> ok
                end
        end,
    ok = stop_poller(St),
    _ = gun:close(St#state.conn_pid),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_handshake(#state{base = Base} = St) ->
    Body = json:encode(#{<<"protocols">> => [?PROTOCOL]}),

    case request(post, <<Base/binary, "/open">>, Body, St) of
        {ok, 200, RespBody} ->
            case open_response(RespBody) of
                {ok, TransportId} ->
                    St1 = St#state{
                        transport_id = TransportId, encoding = json
                    },
                    start_poller(St1);
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
        #{<<"transport">> := Id} when is_binary(Id) ->
            {ok, Id};
        Other ->
            {error, {malformed_open_response, Other}}
    catch
        Class:Reason ->
            {error, {malformed_open_response, Class, Reason}}
    end.

%% @private
start_poller(#state{} = St) ->
    Owner = self(),
    Args = [
        Owner,
        poller_config(St),
        path(St, <<"/receive">>),
        St#state.poll_timeout
    ],
    Poller = erlang:spawn(?MODULE, poll_loop, Args),
    Ref = erlang:monitor(process, Poller),
    St1 = St#state{poller = Poller, poller_ref = Ref},
    {ok, {raw, binary, json}, St1}.

%% @private
poller_config(#state{host = Host, port = Port, gun_opts = GunOpts}) ->
    {Host, Port, GunOpts}.

%% @private
stop_poller(#state{poller = undefined}) ->
    ok;
stop_poller(#state{poller = Poller, poller_ref = Ref}) ->
    _ = Ref =/= undefined andalso erlang:demonitor(Ref, [flush]),
    _ = erlang:exit(Poller, shutdown),
    ok.

-doc """
The poll loop. Runs in its own process with its own `gun` connection and turns
every `/receive` reply into one `info` message for `Owner`.

A `204` is the server's poll timeout, which is a normal quiet interval and not
an event: it loops without telling anyone. Anything else — a body, a non-2xx, a
transport error — is reported, because the connection process cannot see the
HTTP layer at all and this is its only window onto it.
""".
-spec poll_loop(pid(), {term(), integer(), map()}, binary(), pos_integer()) ->
    no_return().

poll_loop(Owner, {Host, Port, GunOpts}, Path, PollTimeout) ->
    case gun:open(Host, Port, GunOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, ?DEFAULT_CONNECT_TIMEOUT) of
                {ok, _} ->
                    poll(Owner, ConnPid, Path, PollTimeout);
                {error, Reason} ->
                    _ = gun:close(ConnPid),
                    Owner ! {?LP_ERROR, self(), Reason}
            end;
        {error, Reason} ->
            Owner ! {?LP_ERROR, self(), Reason}
    end.

%% @private
poll(Owner, ConnPid, Path, PollTimeout) ->
    do_poll(Owner, ConnPid, Path, PollTimeout, 1).

%% @private
%% `Retries' exists for the same reason as `request/5''s: the poll connection is
%% busy almost all the time, but the instant between a `204' and the next
%% `/receive' is a window the listener can close in. A second failure is
%% reported, so a server that is genuinely gone still surfaces promptly.
do_poll(Owner, ConnPid, Path, PollTimeout, Retries) ->
    Ref = gun:post(ConnPid, Path, headers(), <<>>),

    case gun:await(ConnPid, Ref, PollTimeout) of
        {response, fin, 204, _} ->
            poll(Owner, ConnPid, Path, PollTimeout);
        {response, fin, 200, _} ->
            %% A 200 with no body carries nothing to decode.
            poll(Owner, ConnPid, Path, PollTimeout);
        {response, nofin, 200, _} ->
            case gun:await_body(ConnPid, Ref, PollTimeout) of
                {ok, Body} ->
                    Owner ! {?LP_DATA, self(), Body},
                    poll(Owner, ConnPid, Path, PollTimeout);
                {error, Reason} ->
                    stop_polling(Owner, ConnPid, Reason)
            end;
        {response, IsFin, Status, _} ->
            Body = drain(ConnPid, Ref, IsFin, PollTimeout),
            stop_polling(Owner, ConnPid, {http_error, Status, Body});
        {error, timeout} ->
            %% Longer than the server's own poll timeout, so the link, not the
            %% quiet, is what timed out.
            stop_polling(Owner, ConnPid, poll_timeout);
        {error, Reason} when Retries > 0 ->
            case transient(Reason) of
                true ->
                    timer:sleep(?RECONNECT_GRACE),
                    do_poll(Owner, ConnPid, Path, PollTimeout, Retries - 1);
                false ->
                    stop_polling(Owner, ConnPid, Reason)
            end;
        {error, Reason} ->
            stop_polling(Owner, ConnPid, Reason)
    end.

%% @private
stop_polling(Owner, ConnPid, Reason) ->
    _ = gun:close(ConnPid),
    Owner ! {?LP_ERROR, self(), Reason},
    ok.

%% @private
drain(_ConnPid, _Ref, fin, _Timeout) ->
    <<>>;
drain(ConnPid, Ref, nofin, Timeout) ->
    case gun:await_body(ConnPid, Ref, Timeout) of
        {ok, Body} -> Body;
        {error, _} -> <<>>
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

%% @private
%% The server decodes with `{http_longpoll, text, json}'
%% (`bondy_http_longpoll_handler:to_longpoll_subprotocol/1'), so this side uses
%% the same tuple rather than the raw-socket one: the encoding layer keys
%% framing decisions off it.
subprotocol(#state{encoding = Enc}) ->
    {http_longpoll, text, Enc}.

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
request(Method, Path, Body, #state{request_timeout = T} = St) ->
    request(Method, Path, Body, T, St).

%% @private
request(post, Path, Body, Timeout, #state{conn_pid = ConnPid}) ->
    %% One retry, because the send connection is expected to be found closed:
    %% it is idle between POSTs and the listener reaps it on its own
    %% `http.idle_timeout', so the FIRST request after a quiet period can land
    %% while gun is still reconnecting.
    %%
    %% NOT `gun:await_up/2' first. That waits for a `gun_up' MESSAGE, and gun
    %% sends one per connect — already consumed by `connect/2' — so on a
    %% healthy, already-up connection it blocks until the timeout instead of
    %% returning. MEASURED: every case in the long-poll suite failed with
    %% `{connection_error, timeout}' when this was `await_up'.
    case do_request(ConnPid, Path, Body, Timeout) of
        {error, Reason} = Error ->
            case transient(Reason) of
                true ->
                    timer:sleep(?RECONNECT_GRACE),
                    do_request(ConnPid, Path, Body, Timeout);
                false ->
                    Error
            end;
        Result ->
            Result
    end.

%% @private
%% gun reports a connection that is down, or being re-established, in these
%% shapes. Anything else is the server's answer and is the caller's to read.
transient({down, _}) -> true;
transient(noproc) -> true;
transient({shutdown, _}) -> true;
transient(_) -> false.

%% @private
do_request(ConnPid, Path, Body, Timeout) ->
    Ref = gun:post(ConnPid, Path, headers(), Body),

    case gun:await(ConnPid, Ref, Timeout) of
        {response, fin, Status, _Headers} ->
            {ok, Status, <<>>};
        {response, nofin, Status, _Headers} ->
            case gun:await_body(ConnPid, Ref, Timeout) of
                {ok, RespBody} -> {ok, Status, RespBody};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
%% `longpoll' is plaintext, `longpolls' is TLS — the same `scheme' the
%% connection passes for `ws'/`wss', and the same shared secure-by-default TLS
%% set (`m:bondy_connect_tls'). Keyed on the SCHEME rather than on whether a
%% `tls' block is present, because `bondy_connect_config:validate/1' fills that
%% block in for every connection: keying on it would send a plaintext endpoint
%% into a TLS handshake, which the server answers in cleartext and the client
%% reports as `{unsupported_record_type, 72}' — the `H' of `HTTP/1.1'.
%%
%% `protocols => [http]' pins HTTP/1.1. This transport is built on request
%% semantics the poller relies on, and it is not worth having its behaviour
%% depend on whether ALPN happened to negotiate h2.
gun_opts(Host, Opts) ->
    Base = #{
        protocols => [http],
        %% NOT `retry => 0' as the socket transports use. The send connection is
        %% SUPPOSED to sit idle — a long-poll client sends only when it has
        %% something to say — and the listener closes an idle HTTP connection
        %% after `listeners.$name.http.idle_timeout' (15s by default). With no
        %% retry, that ordinary event took the whole session down; MEASURED by
        %% `longpoll_survives_server_poll_timeout', which idles 35s and failed
        %% with `connection_closed' before this. gun's connection PROCESS
        %% survives a reconnect, so the pid held in `#state{}' stays valid,
        %% which matters because `send/2' cannot update transport state.
        retry => 5,
        retry_timeout => 250,
        http_opts => #{keepalive => infinity}
    },
    case maps:get(scheme, Opts, longpoll) of
        longpolls ->
            TLS = maps:get(tls, Opts, #{}),
            Base#{
                transport => tls,
                tls_opts => bondy_connect_tls:options(Host, TLS)
            };
        _ ->
            Base#{transport => tcp}
    end.
