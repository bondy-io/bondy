%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_http_longpoll_handler).
-moduledoc """
Cowboy handler for HTTP-Longpoll transport endpoints.

Handles four actions:
- `open`    — POST /wamp/longpoll/open: creates a new transport session
- `send`    — POST /wamp/longpoll/:transport_id/send: forwards a WAMP message
- `receive` — POST /wamp/longpoll/:transport_id/receive: blocks until messages
- `close`   — POST /wamp/longpoll/:transport_id/close: terminates the session

The longpoll `/receive` endpoint blocks (long-polls) until WAMP messages are
available or the configured timeout expires. In unbatched mode (`wamp.2.json`),
at most one message is returned per request. On timeout, an empty 200 OK
response is returned.

The client sends `"protocols": ["wamp.2.json"]` in the `/open` request — the
same identifiers as the WAMP spec. The handler determines the transport type
(`http_longpoll`) from the URL path and constructs the subprotocol tuple
`{http_longpoll, text, json}` internally.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("http_api.hrl").


-export([init/2]).


%% Longpoll-supported client protocol identifiers.
%% The client sends these in the /open body; we map them to internal tuples.
-define(SUPPORTED_PROTOCOLS, [?WAMP2_JSON]).

%% Default longpoll timeout (30 seconds)
-define(DEFAULT_POLL_TIMEOUT, 30000).



%% =============================================================================
%% COWBOY CALLBACKS
%% =============================================================================



init(Req0, #{action := open} = State) ->
    handle_open(Req0, State);

init(Req0, #{action := send} = State) ->
    handle_send(Req0, State);

init(Req0, #{action := receive_msgs} = State) ->
    handle_receive(Req0, State);

init(Req0, #{action := close} = State) ->
    handle_close(Req0, State).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
handle_open(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            do_handle_open(Req0, State);
        _ ->
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, #{}, <<>>, Req0),
            {ok, Req1, State}
    end.


%% @private
do_handle_open(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),

    try json:decode(Body) of
        Decoded ->
            Protocols = maps:get(<<"protocols">>, Decoded, []),
            case select_protocol(Protocols) of
                {ok, Protocol} ->
                    open_session(Protocol, Req1, State);
                {error, no_supported_protocol} ->
                    ReplyBody = json:encode(#{
                        <<"error">> => <<"no_supported_protocol">>,
                        <<"supported">> => ?SUPPORTED_PROTOCOLS
                    }),
                    Req2 = cowboy_req:reply(
                        ?HTTP_BAD_REQUEST,
                        #{<<"content-type">> => <<"application/json">>},
                        ReplyBody,
                        Req1
                    ),
                    {ok, Req2, State}
            end
    catch
        _:_ ->
            ReplyBody = json:encode(#{
                <<"error">> => <<"invalid_json">>
            }),
            Req2 = cowboy_req:reply(
                ?HTTP_BAD_REQUEST,
                #{<<"content-type">> => <<"application/json">>},
                ReplyBody,
                Req1
            ),
            {ok, Req2, State}
    end.


%% @private
open_session(Protocol, Req0, State) ->
    TransportId = bondy_utils:uuid(),
    SessionId = bondy_session_id:new(),
    Peer = cowboy_req:peer(Req0),

    %% RealmUri is unknown at open time; it comes from the WAMP HELLO message.
    RealmUri = <<>>,

    case bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ) of
        {ok, Pid} ->
            %% Map the client protocol to the internal longpoll subprotocol.
            %% The client sends "wamp.2.json" but we use {http_longpoll, text,
            %% json} internally to distinguish from WebSocket.
            Subprotocol = to_longpoll_subprotocol(Protocol),
            {ok, _} = bondy_wamp_protocol:validate_subprotocol(Subprotocol),
            case bondy_http_transport_session:init_protocol(
                Pid, Subprotocol, Peer
            ) of
                ok ->
                    ReplyBody = json:encode(#{
                        <<"protocol">> => Protocol,
                        <<"transport">> => TransportId
                    }),
                    Req1 = cowboy_req:reply(
                        ?HTTP_OK,
                        #{<<"content-type">> => <<"application/json">>},
                        ReplyBody,
                        Req0
                    ),
                    {ok, Req1, State};
                {error, Reason} ->
                    bondy_http_transport_session:close(Pid),
                    ?LOG_ERROR(#{
                        description => "Failed to init protocol",
                        transport_id => TransportId,
                        reason => Reason
                    }),
                    Req1 = reply_error(
                        ?HTTP_BAD_REQUEST,
                        <<"protocol_init_failed">>,
                        Req0
                    ),
                    {ok, Req1, State}
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Failed to start transport session",
                reason => Reason
            }),
            Req1 = reply_error(
                ?HTTP_BAD_REQUEST,
                <<"session_start_failed">>,
                Req0
            ),
            {ok, Req1, State}
    end.


%% @private
handle_send(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            do_handle_send(Req0, State);
        _ ->
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, #{}, <<>>, Req0),
            {ok, Req1, State}
    end.


%% @private
do_handle_send(Req0, State) ->
    TransportId = cowboy_req:binding(transport_id, Req0),

    case bondy_http_transport_session:whereis(TransportId) of
        undefined ->
            Req1 = reply_error(?HTTP_NOT_FOUND, <<"transport_not_found">>, Req0),
            {ok, Req1, State};
        Pid ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            bondy_http_transport_session:touch(Pid),

            case bondy_http_transport_session:handle_client_message(Pid, Body) of
                ok ->
                    Req2 = cowboy_req:reply(?HTTP_ACCEPTED, #{}, <<>>, Req1),
                    {ok, Req2, State};
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        description => "Error handling client message",
                        transport_id => TransportId,
                        reason => Reason
                    }),
                    Req2 = reply_error(
                        ?HTTP_BAD_REQUEST,
                        <<"message_error">>,
                        Req1
                    ),
                    {ok, Req2, State}
            end
    end.


%% @private
handle_receive(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            do_handle_receive(Req0, State);
        _ ->
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, #{}, <<>>, Req0),
            {ok, Req1, State}
    end.


%% @private
do_handle_receive(Req0, State) ->
    TransportId = cowboy_req:binding(transport_id, Req0),

    case bondy_http_transport_session:whereis(TransportId) of
        undefined ->
            Req1 = reply_error(?HTTP_NOT_FOUND, <<"transport_not_found">>, Req0),
            {ok, Req1, State};
        Pid ->
            bondy_http_transport_session:touch(Pid),

            Timeout = bondy_config:get(
                [wamp_longpoll, poll_timeout], ?DEFAULT_POLL_TIMEOUT
            ),
            Encoding = bondy_http_transport_session:encoding(Pid),

            case bondy_http_transport_session:poll_receive(Pid, Timeout) of
                {ok, {replies, [Bin | _]}} ->
                    %% Sync replies are already encoded binaries.
                    %% Return the first one (unbatched mode).
                    Req1 = cowboy_req:reply(
                        ?HTTP_OK,
                        #{<<"content-type">> => <<"application/json">>},
                        Bin,
                        Req0
                    ),
                    {ok, Req1, State};
                {ok, {messages, [Msg | _]}} ->
                    %% Queue messages are WAMP records that need encoding.
                    %% Return the first one (unbatched mode).
                    Bin = bondy_wamp_encoding:encode(Msg, Encoding),
                    Req1 = cowboy_req:reply(
                        ?HTTP_OK,
                        #{<<"content-type">> => <<"application/json">>},
                        Bin,
                        Req0
                    ),
                    {ok, Req1, State};
                {ok, {messages, []}} ->
                    %% Timeout — no messages available
                    Req1 = cowboy_req:reply(
                        ?HTTP_OK,
                        #{<<"content-type">> => <<"application/json">>},
                        <<>>,
                        Req0
                    ),
                    {ok, Req1, State};
                {ok, {replies, []}} ->
                    %% Empty replies (should not happen, but handle gracefully)
                    Req1 = cowboy_req:reply(
                        ?HTTP_OK,
                        #{<<"content-type">> => <<"application/json">>},
                        <<>>,
                        Req0
                    ),
                    {ok, Req1, State}
            end
    end.


%% @private
handle_close(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            do_handle_close(Req0, State);
        _ ->
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, #{}, <<>>, Req0),
            {ok, Req1, State}
    end.


%% @private
do_handle_close(Req0, State) ->
    TransportId = cowboy_req:binding(transport_id, Req0),
    bondy_http_transport_session:close(TransportId),
    Req1 = cowboy_req:reply(?HTTP_ACCEPTED, #{}, <<>>, Req0),
    {ok, Req1, State}.


%% @private
select_protocol(ClientProtocols) when is_list(ClientProtocols) ->
    case [P || P <- ClientProtocols, lists:member(P, ?SUPPORTED_PROTOCOLS)] of
        [Protocol | _] ->
            {ok, Protocol};
        [] ->
            {error, no_supported_protocol}
    end;

select_protocol(_) ->
    {error, no_supported_protocol}.


%% @private
to_longpoll_subprotocol(?WAMP2_JSON) ->
    {http_longpoll, text, json}.


%% @private
reply_error(StatusCode, ErrorBin, Req) ->
    ReplyBody = json:encode(#{<<"error">> => ErrorBin}),
    cowboy_req:reply(
        StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        ReplyBody,
        Req
    ).
