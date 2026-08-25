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

-behaviour(cowboy_loop).

-export([init/2]).
-export([info/3]).
-export([terminate/3]).

%% Longpoll-supported client protocol identifiers.
%% The client sends these in the /open body; we map them to internal tuples.
-define(SUPPORTED_PROTOCOLS, [?WAMP2_JSON]).

%% =============================================================================
%% COWBOY CALLBACKS
%% =============================================================================

init(Req0, State) ->
    CorsConfig = bondy_http_cors:config_from_req(Req0),
    Req1 = bondy_http_cors:set_headers(Req0, CorsConfig),
    Req = bondy_http_utils:set_all_headers(Req1),
    case cowboy_req:method(Req) of
        <<"OPTIONS">> ->
            Req2 = cowboy_req:reply(?HTTP_OK, #{}, <<>>, Req),
            {ok, Req2, State};
        _ ->
            dispatch(Req, State)
    end.

info({poll_result, {ok, {replies, [Bin | _]}}}, Req0, State) ->
    Req1 = cowboy_req:reply(
        ?HTTP_OK,
        #{<<"content-type">> => <<"application/json">>},
        Bin,
        Req0
    ),
    {stop, Req1, State};
info({poll_result, {ok, {messages, [Msg | _]}}}, Req0, State) ->
    Encoding = maps:get(encoding, State),
    Bin = bondy_wamp_encoding:encode(Msg, Encoding),
    Req1 = cowboy_req:reply(
        ?HTTP_OK,
        #{<<"content-type">> => <<"application/json">>},
        Bin,
        Req0
    ),
    {stop, Req1, State};
info({poll_result, {ok, {messages, []}}}, Req0, State) ->
    Req1 = cowboy_req:reply(?HTTP_NO_CONTENT, #{}, <<>>, Req0),
    {stop, Req1, State};
info({poll_result, {ok, {replies, []}}}, Req0, State) ->
    Req1 = cowboy_req:reply(?HTTP_NO_CONTENT, #{}, <<>>, Req0),
    {stop, Req1, State};
info(_Msg, Req, State) ->
    {ok, Req, State}.

terminate(_Reason, _Req, _State) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
dispatch(Req0, #{action := open} = State) ->
    handle_open(Req0, State);
dispatch(Req0, #{action := send} = State) ->
    handle_send(Req0, State);
dispatch(Req0, #{action := receive_msgs} = State) ->
    handle_receive(Req0, State);
dispatch(Req0, #{action := close} = State) ->
    handle_close(Req0, State).

%% @private
handle_open(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            do_handle_open(Req0, State);
        _ ->
            %% The status is kept at 400 for compatibility; what changes is
            %% that the response now says what went wrong instead of being an
            %% empty body.
            Req1 = reply_error(?HTTP_BAD_REQUEST, ~"method_not_allowed", Req0),
            {ok, Req1, State}
    end.

%% @private
do_handle_open(Req0, State) ->
    case bondy_http_utils:validate_csrf(Req0) of
        {error, forbidden} ->
            Req1 = reply_error(
                ?HTTP_FORBIDDEN, <<"csrf_validation_failed">>, Req0
            ),
            {ok, Req1, State};
        ok ->
            do_handle_open_body(Req0, State)
    end.

%% @private
do_handle_open_body(Req0, State) ->
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
    Peer = bondy_http_utils:peer(Req0),

    %% RealmUri is unknown at open time; it comes from the WAMP HELLO message.
    RealmUri = <<>>,

    case
        bondy_http_transport_session_sup:start_child(
            TransportId, RealmUri, SessionId
        )
    of
        {ok, Pid} ->
            %% Map the client protocol to the internal longpoll subprotocol.
            %% The client sends "wamp.2.json" but we use {http_longpoll, text,
            %% json} internally to distinguish from WebSocket.
            Subprotocol = to_longpoll_subprotocol(Protocol),
            {ok, _} = bondy_wamp_protocol:validate_subprotocol(Subprotocol),
            case
                bondy_http_transport_session:init_protocol(
                    Pid, Subprotocol, Peer
                )
            of
                ok ->
                    %% Pass bondy_ticket cookie if present
                    ok = maybe_set_auth_ticket(Pid, Req0),
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
            %% The status is kept at 400 for compatibility; what changes is
            %% that the response now says what went wrong instead of being an
            %% empty body.
            Req1 = reply_error(?HTTP_BAD_REQUEST, ~"method_not_allowed", Req0),
            {ok, Req1, State}
    end.

%% @private
do_handle_send(Req0, State) ->
    case bondy_http_utils:validate_csrf(Req0) of
        {error, forbidden} ->
            Req1 = reply_error(
                ?HTTP_FORBIDDEN, <<"csrf_validation_failed">>, Req0
            ),
            {ok, Req1, State};
        ok ->
            do_handle_send_body(Req0, State)
    end.

%% @private
do_handle_send_body(Req0, State) ->
    TransportId = cowboy_req:binding(transport_id, Req0),

    case bondy_http_transport_session:whereis(TransportId) of
        undefined ->
            Req1 = reply_error(
                ?HTTP_NOT_FOUND, <<"transport_not_found">>, Req0
            ),
            {ok, Req1, State};
        Pid ->
            case validate_auth_ticket(Pid, Req0) of
                {error, unauthorized} ->
                    Req1 = reply_error(
                        ?HTTP_UNAUTHORIZED, <<"unauthorized">>, Req0
                    ),
                    {ok, Req1, State};
                ok ->
                    {ok, Body, Req1} = cowboy_req:read_body(Req0),
                    bondy_http_transport_session:touch(Pid),

                    case
                        bondy_http_transport_session:handle_client_message(
                            Pid, Body
                        )
                    of
                        ok ->
                            Req2 = cowboy_req:reply(
                                ?HTTP_ACCEPTED, #{}, <<>>, Req1
                            ),
                            {ok, Req2, State};
                        {error, Reason} ->
                            ?LOG_WARNING(#{
                                description =>
                                    "Error handling client message",
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
            end
    end.

%% @private
handle_receive(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            do_handle_receive(Req0, State);
        _ ->
            %% The status is kept at 400 for compatibility; what changes is
            %% that the response now says what went wrong instead of being an
            %% empty body.
            Req1 = reply_error(?HTTP_BAD_REQUEST, ~"method_not_allowed", Req0),
            {ok, Req1, State}
    end.

%% @private
do_handle_receive(Req0, State) ->
    TransportId = cowboy_req:binding(transport_id, Req0),

    case bondy_http_transport_session:whereis(TransportId) of
        undefined ->
            Req1 = reply_error(
                ?HTTP_NOT_FOUND, <<"transport_not_found">>, Req0
            ),
            {ok, Req1, State};
        Pid ->
            case validate_auth_ticket(Pid, Req0) of
                {error, unauthorized} ->
                    Req1 = reply_error(
                        ?HTTP_UNAUTHORIZED, <<"unauthorized">>, Req0
                    ),
                    {ok, Req1, State};
                ok ->
                    bondy_http_transport_session:touch(Pid),
                    %% `carrier_state/2' always sets `config' in the route
                    %% state this handler was started with, so this is no
                    %% per-connection configuration lookup. No defaults: a
                    %% resolved `longpoll' carrier config carries every key of
                    %% `bondy_listener_config:?CARRIER_DEFAULTS'.
                    Config = maps:get(config, State),
                    PollTimeout = maps:get(poll_timeout, Config),
                    Encoding = bondy_http_transport_session:encoding(Pid),
                    ok = bondy_http_transport_session:request_poll(
                        Pid, PollTimeout
                    ),
                    %% No timeout cast: the hold survives because
                    %% `bondy_listener_config:held_stream_defaults/1' seats
                    %% the listener's CONNECTION idle timeout from
                    %% `longpoll.idle_timeout' (> `poll_timeout'), which
                    %% covers HTTP/1.1 and HTTP/2 alike — a per-stream cast
                    %% only ever worked over HTTP/1.1
                    %% (`cowboy_http2.erl:988' discards it).
                    {cowboy_loop, Req0, State#{encoding => Encoding}}
            end
    end.

%% @private
handle_close(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            do_handle_close(Req0, State);
        _ ->
            %% The status is kept at 400 for compatibility; what changes is
            %% that the response now says what went wrong instead of being an
            %% empty body.
            Req1 = reply_error(?HTTP_BAD_REQUEST, ~"method_not_allowed", Req0),
            {ok, Req1, State}
    end.

%% @private
do_handle_close(Req0, State) ->
    case bondy_http_utils:validate_csrf(Req0) of
        {error, forbidden} ->
            Req1 = reply_error(
                ?HTTP_FORBIDDEN, <<"csrf_validation_failed">>, Req0
            ),
            {ok, Req1, State};
        ok ->
            do_handle_close_body(Req0, State)
    end.

%% @private
do_handle_close_body(Req0, State) ->
    TransportId = cowboy_req:binding(transport_id, Req0),

    case bondy_http_transport_session:whereis(TransportId) of
        undefined ->
            %% Already gone, treat as success
            Req1 = cowboy_req:reply(?HTTP_ACCEPTED, #{}, <<>>, Req0),
            {ok, Req1, State};
        Pid ->
            case validate_auth_ticket(Pid, Req0) of
                {error, unauthorized} ->
                    Req1 = reply_error(
                        ?HTTP_UNAUTHORIZED, <<"unauthorized">>, Req0
                    ),
                    {ok, Req1, State};
                ok ->
                    try
                        bondy_http_transport_session:close(Pid)
                    catch
                        _:_ -> ok
                    end,
                    Req1 = cowboy_req:reply(
                        ?HTTP_ACCEPTED, #{}, <<>>, Req0
                    ),
                    {ok, Req1, State}
            end
    end.

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
maybe_set_auth_ticket(Pid, Req) ->
    Cookies = bondy_http_utils:parse_cookies(Req),
    case bondy_http_utils:find_ticket_cookie(Cookies) of
        {value, {_, Ticket}} when Ticket =/= <<>> ->
            case bondy_ticket:verify(Ticket) of
                {ok, Claims} ->
                    bondy_http_transport_session:set_auth_claims(Pid, Claims);
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        description =>
                            "Invalid bondy_ticket cookie at /open",
                        reason => Reason
                    }),
                    ok
            end;
        _ ->
            ok
    end.

%% @private
validate_auth_ticket(Pid, Req) ->
    case bondy_http_transport_session:auth_claims(Pid) of
        undefined ->
            %% No OIDC claims — non-cookie flow, skip validation
            ok;
        #{authrealm := Authrealm} = StoredClaims ->
            Cookies = bondy_http_utils:parse_cookies(Req),
            CookieName = bondy_http_utils:ticket_cookie_name(Authrealm),
            case lists:keyfind(CookieName, 1, Cookies) of
                false ->
                    {error, unauthorized};
                {_, Ticket} ->
                    case bondy_ticket:verify(Ticket) of
                        {ok, #{
                            authid := Authid, authrealm := Authrealm2
                        }} ->
                            #{
                                authid := ExpAuthid,
                                authrealm := ExpAuthrealm
                            } = StoredClaims,
                            case
                                Authid =:= ExpAuthid andalso
                                    Authrealm2 =:= ExpAuthrealm
                            of
                                true -> ok;
                                false -> {error, unauthorized}
                            end;
                        {error, _} ->
                            {error, unauthorized}
                    end
            end
    end.

%% @private
reply_error(StatusCode, ErrorBin, Req) ->
    %% `error' is retained for existing clients; the standard error payload is
    %% added alongside it.
    Body = maps:put(
        ~"error", ErrorBin, bondy_error:to_map(bondy_error:from_term(ErrorBin))
    ),
    ReplyBody = json:encode(Body),
    cowboy_req:reply(
        StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        ReplyBody,
        Req
    ).
