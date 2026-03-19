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

-behaviour(cowboy_loop).

-export([init/2]).
-export([info/3]).
-export([terminate/3]).


-define(SUPPORTED_PROTOCOLS, [?WAMP2_JSON_SSE]).



%% =============================================================================
%% COWBOY CALLBACKS
%% =============================================================================



init(Req0, State) ->
    Req = cowboy_req:set_resp_headers(cors_headers(Req0), Req0),
    case cowboy_req:method(Req) of
        <<"OPTIONS">> ->
            Req1 = cowboy_req:reply(?HTTP_OK, #{}, <<>>, Req),

            {ok, Req1, State};
        _ ->
            dispatch(Req, State)
    end.


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

dispatch(Req0, #{action := close} = State) ->
    handle_close(Req0, State).


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
    case validate_csrf(Req0) of
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
            Req1 = cowboy_req:reply(?HTTP_BAD_REQUEST, #{}, <<>>, Req0),
            {ok, Req1, State}
    end.


%% @private
do_handle_send(Req0, State) ->
    case validate_csrf(Req0) of
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
            Req1 = reply_error(?HTTP_NOT_FOUND, <<"transport_not_found">>, Req0),
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

                    case bondy_http_transport_session:handle_client_message(
                        Pid, Body
                    ) of
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
    case validate_csrf(Req0) of
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
                    bondy_http_transport_session:close(Pid),
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
maybe_set_auth_ticket(Pid, Req) ->
    Cookies = cowboy_req:parse_cookies(Req),
    case find_ticket_cookie(Cookies) of
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
validate_csrf(Req) ->
    Cookies = cowboy_req:parse_cookies(Req),
    case find_ticket_cookie(Cookies) of
        false ->
            %% No ticket cookie — non-OIDC flow, skip CSRF
            ok;
        {value, {Name, _}} ->
            %% Extract realm suffix and look up the matching CSRF cookie
            PrefixLen = byte_size(?TICKET_COOKIE_PREFIX),
            RealmUri = binary:part(Name, PrefixLen, byte_size(Name) - PrefixLen),
            CsrfName = <<?CSRF_COOKIE_PREFIX/binary, RealmUri/binary>>,
            CsrfHeader = cowboy_req:header(
                <<"x-csrf-token">>, Req, undefined
            ),
            CsrfCookie = case lists:keyfind(CsrfName, 1, Cookies) of
                {_, V} -> V;
                false -> undefined
            end,
            case is_binary(CsrfHeader) andalso is_binary(CsrfCookie)
                    andalso CsrfHeader =:= CsrfCookie of
                true -> ok;
                false -> {error, forbidden}
            end
    end.


%% @private
validate_auth_ticket(Pid, Req) ->
    case bondy_http_transport_session:auth_claims(Pid) of
        undefined ->
            %% No OIDC claims — non-cookie flow, skip validation
            ok;
        #{authrealm := Authrealm} = StoredClaims ->
            Cookies = cowboy_req:parse_cookies(Req),
            CookieName = <<?TICKET_COOKIE_PREFIX/binary, Authrealm/binary>>,
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
                            case Authid =:= ExpAuthid
                                    andalso Authrealm2 =:= ExpAuthrealm of
                                true -> ok;
                                false -> {error, unauthorized}
                            end;
                        {error, _} ->
                            {error, unauthorized}
                    end
            end
    end.


%% @private
%% Scans cookies for the first one matching the bondy_ticket_ prefix.
find_ticket_cookie(Cookies) ->
    lists:search(
        fun({Name, _}) ->
            PrefixLen = byte_size(?TICKET_COOKIE_PREFIX),
            byte_size(Name) > PrefixLen andalso
            binary:part(Name, 0, PrefixLen) =:= ?TICKET_COOKIE_PREFIX
        end,
        Cookies
    ).


%% @private
cors_headers(Req) ->
    Origin = cowboy_req:header(<<"origin">>, Req, <<"*">>),
    begin ?CORS_HEADERS end#{<<"access-control-allow-origin">> => Origin}.


%% @private
reply_error(StatusCode, ErrorBin, Req) ->
    ReplyBody = json:encode(#{<<"error">> => ErrorBin}),
    cowboy_req:reply(
        StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        ReplyBody,
        Req
    ).
