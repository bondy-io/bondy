%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_http_sse_handler).
-moduledoc """
Cowboy handler for SSE transport HTTP POST endpoints.

Handles three actions:
- `open`  — POST /wamp/sse/open: creates a new transport session
- `send`  — POST /wamp/sse/:transport_id/send: forwards a WAMP message
- `close` — POST /wamp/sse/:transport_id/close: terminates the session
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("http_api.hrl").


-export([init/2]).


-define(SUPPORTED_PROTOCOLS, [?WAMP2_JSON_SSE]).



%% =============================================================================
%% COWBOY CALLBACKS
%% =============================================================================



init(Req0, #{action := open} = State) ->
    handle_open(Req0, State);

init(Req0, #{action := send} = State) ->
    handle_send(Req0, State);

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
            Protocols = maps:get(
                <<"protocols">>, Decoded, []
            ),
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
    %% We use an empty binary as a placeholder.
    RealmUri = <<>>,

    case bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ) of
        {ok, Pid} ->
            {ok, Subprotocol} = bondy_wamp_protocol:validate_subprotocol(
                Protocol
            ),
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
reply_error(StatusCode, ErrorBin, Req) ->
    ReplyBody = json:encode(#{<<"error">> => ErrorBin}),
    cowboy_req:reply(
        StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        ReplyBody,
        Req
    ).
