%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_http_handler).

-moduledoc """
Cowboy handler for both MCP paths, selected by the `action` key in its
route state: the JSON-RPC endpoint (`rpc`) and the OAuth protected-resource
metadata document (`oauth_metadata`, still a stub).

## The modern per-request edge (design §5.2, §21 increment 4)

A `2026-07-28` request is served in the REST-gateway shape: no process, no
stored session, nothing retained past the response. The pipeline is

1. transport checks — method, body size, JSON-RPC decode;
2. §10.1 validation — the `MCP-Protocol-Version` header must equal the
   body's `_meta."io.modelcontextprotocol/protocolVersion"` (else `400` +
   `-32020 HeaderMismatch`); a version this endpoint does not carry is
   `400` + `-32022 UnsupportedProtocolVersionError` naming the supported
   set; `Mcp-Method` (all requests) and `Mcp-Name` (`tools/call`,
   `resources/read`, `prompts/get`) must agree with the body,
   Base64-sentinel values decoded before comparison;
3. authentication (§6, modern) — the realm's configured auth methods
   decide what the `Authorization` header may carry: a Bearer JWT
   (OAuth2), a Bearer Bondy ticket, or Basic (password); an absent header
   falls through to the anonymous principal when the realm admits it.
   Failure is `401` with `WWW-Authenticate`; NOTHING has been started;
4. dispatch — `tools/list` (RBAC-projected per §6, paginated),
   `tools/call` and `resources/read` build the §5.2 unstored session and
   context and speak WAMP inward. An unknown method — and a manifest
   entry hidden from this principal, deliberately indistinguishable — is
   `404` + `-32601`.

`tools/call` also carries the §11.1 multi round-trip mechanism: a callee
answering `bondy.error.mcp.input_required` becomes an
`InputRequiredResult` whose `requestState` is sealed by
`bondy_mcp_request_state`, and a retry presenting `inputResponses` /
`requestState` reaches the callee as the reserved `_mcp_input_responses` /
`_mcp_state` kwargs (client arguments in the `_mcp` namespace are
refused, so the channel cannot be impersonated through the gateway).

Every tool call, resource read, and RBAC denial emits one §14 audit
record via `bondy_mcp_audit:record/2` — the denial record is invisible on
the wire, which answers identically for hidden and absent. Emission is
fail-open (see that module's doc).

## The handshake era (design §12, §21 increment 8)

The same endpoint serves protocol revisions `2025-06-18` and
`2025-11-25` when the listener's `protocol_versions` carries them. Era
selection is per request: `initialize` selects handshake semantics and
mints an `Mcp-Session-Id`; a POST carrying that header is an established
handshake request; a session-less request whose `MCP-Protocol-Version`
header names a handshake revision is the transport specification's
`400`; anything else is the modern path above, untouched. `GET` (the
held notification stream) and `DELETE` (session termination) exist only
in this era — a modern-only endpoint answers them `405`, exactly the
specification's "no SSE stream offered".

Session mechanics — bootstrap, principal binding, subscriptions,
in-flight cancellation, the stream's queue drain, graceful close — live
in `bondy_mcp_handshake`; this module keeps the HTTP orchestration and
the status dialect: inside a session, JSON-RPC-level failures ride HTTP
200, because the transport specification reserves `404` for a terminated
or unknown session (the client MUST re-initialize on it) — `hs_status/1`
remaps the shared dispatch's modern-era statuses accordingly. The shared
`tools_call`/`resources_read` are era-gated: `Mcp-Param-*` header checks
and the §11.1 retry params are modern mechanisms, a callee's
`input_required` signal surfaces here as a plain tool error, and audit
records carry the SESSION's id rather than a per-request one.

The per-request RBAC context build (the modern path's floor, §2.5.4) is
measured around `bondy_session:rbac_context/1` and published as the
telemetry event `[bondy_mcp, modern, rbac_context_build]` with a
native-unit `duration` measurement.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_json_rpc/include/bondy_json_rpc.hrl").
-include_lib("bondy_router/include/bondy_security.hrl").
-include_lib("bondy_router/include/bondy_uris.hrl").

%% Streamable HTTP error codes beyond JSON-RPC's reserved set.
-define(MCP_HEADER_MISMATCH, -32020).
-define(MCP_UNSUPPORTED_PROTOCOL_VERSION, -32022).

%% The protocol revisions THIS implementation carries, per era. The
%% effective supported set of an endpoint is the intersection with its
%% configured `protocol_versions`. A modern request is validated against
%% the modern set (§10.1); an `initialize` negotiates against the
%% handshake set (§12), latest first — date-form revisions sort
%% lexicographically in chronological order.
-define(MODERN_VERSIONS, [<<"2026-07-28">>]).
-define(HANDSHAKE_VERSIONS, [<<"2025-11-25">>, <<"2025-06-18">>]).

-define(PROTOCOL_VERSION_META, <<"io.modelcontextprotocol/protocolVersion">>).
-define(JSON_CT, #{<<"content-type">> => <<"application/json">>}).

-export([init/2]).
-export([info/3]).
-export([terminate/3]).

%% =============================================================================
%% COWBOY CALLBACKS
%% =============================================================================

init(Req0, #{action := rpc} = St) ->
    case handle_rpc(Req0, St) of
        {loop, Req, Stream} ->
            %% A `subscriptions/listen` request became a held SSE stream
            %% (§9): this process stays as a cowboy_loop, `info/3` below
            %% delegates to `bondy_mcp_stream`.
            {cowboy_loop, Req, St#{mcp_stream => Stream}};
        {loop_state, Req, St1} ->
            %% A handshake-era GET became the session's held notification
            %% stream (§12.2); `info/3`'s `hs_stream` clauses serve it.
            {cowboy_loop, Req, St1};
        Req ->
            {ok, Req, St}
    end;
init(Req0, #{action := oauth_metadata} = St) ->
    Req = cowboy_req:reply(
        501,
        ?JSON_CT,
        <<"{\"error\":\"mcp_not_implemented\"}">>,
        Req0
    ),
    {ok, Req, St}.

info(Msg, Req0, #{mcp_stream := Stream0} = St) ->
    case bondy_mcp_stream:info(Msg, Req0, Stream0) of
        {ok, Req, Stream} -> {ok, Req, St#{mcp_stream => Stream}};
        {stop, Req, Stream} -> {stop, Req, St#{mcp_stream => Stream}}
    end;
%% The handshake era's held GET stream (§12.2): `drain_queue` arrives
%% from the transport session whenever its queue has content; the drain
%% translates above the queue (§12.3) and re-arms itself while a backlog
%% remains. `{stop_stream, _}` is the session's graceful close, `DOWN`
%% its death — either way the SSE stream just ends; the client learns
%% the session is gone from its next request's 404.
info(
    drain_queue,
    Req,
    #{hs_stream := #{mode := local, pid := Pid, tid := Tid}} = St
) ->
    {Frames, More} = bondy_mcp_handshake:drain(Pid, Tid),
    ok = send_frames(Frames, Req),
    More andalso (self() ! drain_queue),
    {ok, Req, St};
info({stop_stream, _}, Req, #{hs_stream := _} = St) ->
    {stop, Req, St};
info(
    {'DOWN', MRef, process, Pid, _},
    Req,
    #{hs_stream := #{mode := local, pid := Pid, mref := MRef}} = St
) ->
    {stop, Req, St};
%% A REMOTE session's stream: the owner-side proxy pushes finished
%% frames door-to-door; `mcp_hs_stream_down` is the owner saying the
%% session (or its proxy) ended.
info({mcp_hs_frames, Frames}, Req, #{hs_stream := #{mode := remote}} = St) ->
    ok = send_frames(Frames, Req),
    {ok, Req, St};
info(mcp_hs_stream_down, Req, #{hs_stream := #{mode := remote}} = St) ->
    {stop, Req, St};
info(_Msg, Req, #{hs_stream := _} = St) ->
    {ok, Req, St}.

%% Nothing to clean here, deliberately: the stream's session was opened
%% via `bondy_session_manager:open/3`, whose monitor on this process runs
%% the DOWN cleanup (session close + subscription removal) however this
%% process ends — a terminate callback a brutal kill would skip cannot be
%% the cleanup path. The one exception is a REMOTE handshake stream: its
%% owner-side proxy has no monitor on this process, so a best-effort
%% detach frees the one-stream slot promptly — and when this callback is
%% skipped, the next attach's liveness probe detaches the stale proxy
%% instead.
terminate(_Reason, _Req, #{hs_stream := #{mode := remote} = Stream}) ->
    ok = bondy_mcp_handshake:detach_stream(Stream);
terminate(_Reason, _Req, _St) ->
    ok.

%% =============================================================================
%% PRIVATE — pipeline
%% =============================================================================

%% @private
handle_rpc(Req, St) ->
    try
        do_handle_rpc(Req, St)
    catch
        throw:{reply, Status, Body, Req1} ->
            reply(Status, Body, Req1);
        throw:{unauthorized, Reason, Req1} ->
            reply_unauthorized(Reason, Req1, St);
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Unexpected error serving an MCP request",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            reply(
                500,
                bondy_json_rpc:error_response(
                    undefined, ?JSONRPC_INTERNAL_ERROR, <<"Internal error">>
                ),
                Req
            )
    end.

%% @private
do_handle_rpc(Req0, #{config := Config} = St) ->
    %% Per-source-IP request admission (`security.rate_limit.http`, off by
    %% default) — the same inbound throttle the WS and raw-socket handlers
    %% apply, before any realm or parse work. 429 is transport-level here:
    %% it carries no session meaning, so it is safe in both eras (unlike
    %% 404, which is reserved for the session — §12).
    ok =
        case bondy_http_utils:throttle(http, Req0) of
            ok ->
                ok;
            throttled ->
                throw(
                    {reply, 429,
                        bondy_json_rpc:error_response(
                            undefined, -32000, <<"Too many requests">>
                        ),
                        cowboy_req:set_resp_header(
                            <<"retry-after">>, <<"1">>, Req0
                        )}
                )
        end,

    %% DNS-rebinding protection: refuse a disallowed `Origin` before any
    %% realm or body work (transport spec security requirement; measured
    %% against the conformance `dns-rebinding-protection` scenario).
    ok = check_origin(Req0, Config),

    RealmUri = cowboy_req:binding(realm, Req0),
    bondy_realm:exists(RealmUri) orelse
        throw(
            {reply, 404,
                bondy_json_rpc:error_response(
                    undefined, -32000, <<"no_such_realm">>
                ),
                Req0}
        ),

    %% GET and DELETE exist only in the handshake era (§12): the held
    %% notification stream and explicit session termination. On a
    %% modern-only endpoint they are 405 — for GET exactly the answer the
    %% transport specification prescribes for "no SSE stream offered".
    HandshakeEnabled = handshake_versions(Config) =/= [],
    case {cowboy_req:method(Req0), HandshakeEnabled} of
        {<<"POST">>, _} ->
            handle_post(Req0, RealmUri, St);
        {<<"GET">>, true} ->
            handshake_get(Req0, RealmUri, St);
        {<<"DELETE">>, true} ->
            handshake_delete(Req0, RealmUri, St);
        _ ->
            Allow =
                case HandshakeEnabled of
                    false -> <<"POST">>;
                    true -> <<"POST, GET, DELETE">>
                end,
            throw(
                {reply, 405,
                    bondy_json_rpc:error_response(
                        undefined,
                        ?JSONRPC_INVALID_REQUEST,
                        <<"Method not allowed on the MCP endpoint">>
                    ),
                    cowboy_req:set_resp_header(<<"allow">>, Allow, Req0)}
            )
    end.

%% @private
handle_post(Req0, RealmUri, #{config := Config} = St) ->
    {Body, Req1} = read_body(Req0, maps:get(max_body_size, Config)),
    SessionHeader = cowboy_req:header(<<"mcp-session-id">>, Req1),

    case bondy_json_rpc:decode(Body) of
        {ok, {request, #{method := <<"initialize">>} = R}} ->
            handshake_initialize(Req1, R, RealmUri, SessionHeader, St);
        {ok, Message} when is_binary(SessionHeader) ->
            handshake_established(Req1, Message, RealmUri, SessionHeader, St);
        {ok, {request, #{id := Id, method := Method, params := Params}}} ->
            ok = require_session_for_handshake_version(Req1, Id, Config),
            ok = check_version(Req1, Id, Params, St),
            ok = check_standard_headers(Req1, Id, Method, Params),
            AuthSt = authenticate(Req1, RealmUri),
            T0 = erlang:monotonic_time(microsecond),
            Outcome =
                try
                    dispatch(Method, Id, Params, RealmUri, AuthSt, Req1, St)
                catch
                    throw:{reply2, S, B} -> {S, B}
                end,
            ok = bondy_mcp_metrics:request_stop(
                RealmUri, Method, erlang:monotonic_time(microsecond) - T0
            ),
            case Outcome of
                {stream, Req2, StreamSt} ->
                    {loop, Req2, StreamSt};
                {Status, Response} ->
                    reply(Status, Response, Req1)
            end;
        {ok, {notification, _}} ->
            ok = require_session_for_handshake_version(Req1, undefined, Config),
            %% The modern binding defines no client-to-server notifications
            %% Bondy acts on; an accepted notification is 202 with no body.
            cowboy_req:reply(202, #{}, <<>>, Req1);
        {error, {parse_error, _}} ->
            reply(
                400,
                bondy_json_rpc:error_response(
                    undefined, ?JSONRPC_PARSE_ERROR, <<"Parse error">>
                ),
                Req1
            );
        {error, {invalid_request, Id}} ->
            reply(
                400,
                bondy_json_rpc:error_response(
                    Id, ?JSONRPC_INVALID_REQUEST, <<"Invalid request">>
                ),
                Req1
            )
    end.

%% @private
%% Transport spec, session management rule 2: a session-carrying endpoint
%% SHOULD answer a session-less non-initialize request with 400. Applied
%% when the request declares a handshake-era `MCP-Protocol-Version` — a
%% header-less or modern-version request proceeds as a modern request.
require_session_for_handshake_version(Req, Id, Config) ->
    Header = cowboy_req:header(<<"mcp-protocol-version">>, Req),
    case
        is_binary(Header) andalso
            lists:member(Header, handshake_versions(Config))
    of
        true ->
            throw(
                {reply, 400,
                    bondy_json_rpc:error_response(
                        Id,
                        ?JSONRPC_INVALID_REQUEST,
                        <<"Mcp-Session-Id header required">>
                    ),
                    Req}
            );
        false ->
            ok
    end.

%% @private
read_body(Req0, MaxBytes) ->
    case cowboy_req:read_body(Req0, #{length => MaxBytes}) of
        {ok, Body, Req} when byte_size(Body) =< MaxBytes ->
            {Body, Req};
        {_, _, Req} ->
            throw(
                {reply, 413,
                    bondy_json_rpc:error_response(
                        undefined,
                        ?JSONRPC_INVALID_REQUEST,
                        <<"Request body exceeds the endpoint's limit">>
                    ),
                    Req}
            )
    end.

%% @private
%% A request whose `Origin` header falls outside this listener's
%% `mcp.allowed_origins` is refused with 403. A request WITHOUT the
%% header is always served: only browsers send `Origin`, and the browser
%% is the DNS-rebinding vector — a non-browser client can forge any
%% header, so refusing the absent case would break every SDK client
%% (none sends one; measured on the v1 and v2 official clients) while
%% stopping no attacker. A present-but-unparseable value matches no rule
%% and is refused — explicit garbage fails closed.
check_origin(Req, Config) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined ->
            ok;
        Origin ->
            case origin_allowed(Origin, maps:get(allowed_origins, Config)) of
                true ->
                    ok;
                false ->
                    throw(
                        {reply, 403,
                            bondy_json_rpc:error_response(
                                undefined,
                                ?JSONRPC_INVALID_REQUEST,
                                <<"Origin not allowed">>
                            ),
                            Req}
                    )
            end
    end.

%% @private
%% Origins compare case-insensitively: the schema lowercased the
%% configured entries, this lowercases the header.
origin_allowed(_, any) ->
    true;
origin_allowed(Origin, Rules) when is_list(Rules) ->
    Normalized = string:lowercase(Origin),
    lists:any(fun(Rule) -> origin_matches(Rule, Normalized) end, Rules).

%% @private
%% The `local` rule admits the transport spec's localhost set —
%% `localhost`, `127.0.0.1`, `[::1]` — on any scheme and port.
origin_matches(local, Origin) ->
    case uri_string:parse(Origin) of
        #{host := Host} ->
            lists:member(Host, [<<"localhost">>, <<"127.0.0.1">>, <<"::1">>]);
        _ ->
            false
    end;
origin_matches(Rule, Origin) when is_binary(Rule) ->
    Rule == Origin.

%% @private
%% §10.1: `MCP-Protocol-Version` is required and must equal the body's
%% `_meta` value; a version outside this endpoint's supported set is
%% refused naming that set (the -32022 shape's `supported`/`requested`).
check_version(Req, Id, Params, #{config := Config} = St) ->
    Header = cowboy_req:header(<<"mcp-protocol-version">>, Req),
    Meta = maps:get(<<"_meta">>, Params, #{}),
    BodyVersion =
        case is_map(Meta) of
            true -> maps:get(?PROTOCOL_VERSION_META, Meta, undefined);
            false -> undefined
        end,
    (is_binary(Header) andalso Header == BodyVersion) orelse
        throw(
            {reply, 400,
                bondy_json_rpc:error_response(
                    Id,
                    ?MCP_HEADER_MISMATCH,
                    <<
                        "MCP-Protocol-Version header missing or disagreeing "
                        "with the request body"
                    >>
                ),
                Req}
        ),
    Supported = supported_versions(Config),
    lists:member(Header, Supported) orelse
        begin
            ok = bondy_mcp_metrics:version_refused(
                maps:get(listener, St, undefined), sanitize_version(Header)
            ),
            throw(
                {reply, 400,
                    bondy_json_rpc:error_response(
                        Id,
                        ?MCP_UNSUPPORTED_PROTOCOL_VERSION,
                        <<"Unsupported protocol version">>,
                        #{
                            <<"supported">> => Supported,
                            <<"requested">> => Header
                        }
                    ),
                    Req}
            )
        end,
    ok.

%% @private
%% §15.2: `version` is client-controlled, so only a revision Bondy knows
%% may become a label value — anything else is `other`, and an attacker
%% cannot mint Prometheus series by cycling version strings.
sanitize_version(V) ->
    case lists:member(V, ?MODERN_VERSIONS ++ ?HANDSHAKE_VERSIONS) of
        true -> V;
        false -> <<"other">>
    end.

%% @private
supported_versions(Config) ->
    [
        V
     || V <- maps:get(protocol_versions, Config),
        lists:member(V, ?MODERN_VERSIONS)
    ].

%% @private
%% The endpoint's effective handshake-era set, latest first (the order
%% version negotiation picks from).
handshake_versions(Config) ->
    Configured = maps:get(protocol_versions, Config),
    [V || V <- ?HANDSHAKE_VERSIONS, lists:member(V, Configured)].

%% @private
%% §10.1: `Mcp-Method` on every request; `Mcp-Name` on the methods that
%% carry a name (`params.name`) or a URI (`params.uri`), Base64-sentinel
%% decoded before comparison. A request whose body lacks the named field
%% is not a header problem — dispatch answers it with `-32602`.
check_standard_headers(Req, Id, Method, Params) ->
    ok = require_header_equals(
        Req, Id, <<"mcp-method">>, Method, no_sentinel
    ),
    case name_field(Method) of
        undefined ->
            ok;
        Field ->
            case maps:get(Field, Params, undefined) of
                Value when is_binary(Value) ->
                    require_header_equals(
                        Req, Id, <<"mcp-name">>, Value, sentinel
                    );
                _ ->
                    ok
            end
    end.

%% @private
name_field(<<"tools/call">>) -> <<"name">>;
name_field(<<"prompts/get">>) -> <<"name">>;
name_field(<<"resources/read">>) -> <<"uri">>;
name_field(_) -> undefined.

%% @private
require_header_equals(Req, Id, Header, Expected, Sentinel) ->
    Decoded =
        case cowboy_req:header(Header, Req) of
            undefined ->
                undefined;
            Raw when Sentinel == sentinel ->
                case bondy_mcp_wamp:decode_header_value(Raw) of
                    {ok, V} -> V;
                    {error, badarg} -> undefined
                end;
            Raw ->
                Raw
        end,
    Decoded == Expected orelse
        throw(
            {reply, 400,
                bondy_json_rpc:error_response(
                    Id,
                    ?MCP_HEADER_MISMATCH,
                    <<
                        "A required Mcp-* header is missing or disagrees "
                        "with the request body"
                    >>
                ),
                Req}
        ),
    ok.

%% =============================================================================
%% PRIVATE — authentication (§6, modern era)
%% =============================================================================

%% @private
%% Returns `#{authid, authroles, is_anonymous}`. Anything failing throws
%% `{unauthorized, _, Req}` with NOTHING started — no process, no stored
%% session, no auth state outlives the throw.
authenticate(Req, RealmUri) ->
    case bondy_realm:is_security_enabled(RealmUri) of
        false ->
            #{
                authid => bondy_utils:uuid(),
                authroles => [],
                is_anonymous => true
            };
        true ->
            SourceIP = source_ip(Req),
            case cowboy_req:parse_header(<<"authorization">>, Req) of
                {bearer, Token} ->
                    bearer(Token, RealmUri, SourceIP, Req);
                {basic, Username, Password} ->
                    credential(
                        RealmUri,
                        Username,
                        ?PASSWORD_AUTH,
                        Password,
                        SourceIP,
                        Req
                    );
                undefined ->
                    anonymous(RealmUri, SourceIP, Req);
                _ ->
                    throw({unauthorized, invalid_authorization_header, Req})
            end
    end.

%% @private
%% A Bearer credential is a JWT (OAuth2) or a Bondy ticket; which one is
%% decided by shape — a ticket does not decode as a realm JWT.
bearer(Token, RealmUri, SourceIP, Req) ->
    try bondy_oauth_jwt:decode(Token) of
        #{<<"sub">> := Sub} ->
            credential(RealmUri, Sub, ?OAUTH2_AUTH, Token, SourceIP, Req);
        _ ->
            throw({unauthorized, invalid_token, Req})
    catch
        _:_ ->
            case bondy_ticket:verify(Token) of
                {ok, #{authid := Authid}} ->
                    credential(
                        RealmUri,
                        Authid,
                        ?WAMP_TICKET_AUTH,
                        Token,
                        SourceIP,
                        Req
                    );
                {error, _} ->
                    throw({unauthorized, invalid_token, Req})
            end
    end.

%% @private
anonymous(RealmUri, SourceIP, Req) ->
    SessionId = bondy_session_id:new(),
    case
        bondy_auth:init(
            SessionId, RealmUri, anonymous, [<<"anonymous">>], SourceIP
        )
    of
        {ok, Ctxt} ->
            case bondy_auth:authenticate(?WAMP_ANON_AUTH, <<>>, #{}, Ctxt) of
                {ok, _, _} ->
                    #{
                        authid => bondy_utils:uuid(),
                        authroles => [<<"anonymous">>],
                        is_anonymous => true
                    };
                {error, Reason} ->
                    throw({unauthorized, Reason, Req})
            end;
        {error, Reason} ->
            throw({unauthorized, Reason, Req})
    end.

%% @private
credential(RealmUri, UserId, Method, Credential, SourceIP, Req) ->
    SessionId = bondy_session_id:new(),
    case bondy_auth:init(SessionId, RealmUri, UserId, all, SourceIP) of
        {ok, Ctxt} ->
            case bondy_auth:authenticate(Method, Credential, #{}, Ctxt) of
                {ok, _, Ctxt1} ->
                    #{
                        authid => UserId,
                        authroles => bondy_auth:roles(Ctxt1),
                        is_anonymous => false
                    };
                {error, Reason} ->
                    throw({unauthorized, Reason, Req})
            end;
        {error, Reason} ->
            throw({unauthorized, Reason, Req})
    end.

%% @private
source_ip(Req) ->
    {IP, _} = cowboy_req:peer(Req),
    IP.

%% =============================================================================
%% PRIVATE — dispatch
%% =============================================================================

%% @private
dispatch(<<"tools/list">>, Id, Params, RealmUri, AuthSt, Req, St) ->
    tools_list(Id, Params, RealmUri, AuthSt, Req, St);
dispatch(<<"tools/call">>, Id, Params, RealmUri, AuthSt, Req, St) ->
    tools_call(Id, Params, RealmUri, AuthSt, Req, St);
dispatch(<<"resources/read">>, Id, Params, RealmUri, AuthSt, Req, St) ->
    resources_read(Id, Params, RealmUri, AuthSt, Req, St);
dispatch(<<"subscriptions/listen">>, Id, Params, RealmUri, AuthSt, Req, St) ->
    bondy_mcp_stream:open(Id, Params, RealmUri, AuthSt, Req, St);
dispatch(<<"server/discover">>, Id, _, _, _, _, St) ->
    server_discover(Id, St);
dispatch(Method, Id, _, _, _, _, _) ->
    %% §10.1: 404 and -32601 together — the JSON-RPC body is what
    %% distinguishes this from a 404 by something that is not MCP at all.
    {404,
        bondy_json_rpc:error_response(
            Id,
            ?JSONRPC_METHOD_NOT_FOUND,
            <<"Method not found: ", Method/binary>>
        )}.

%% @private
%% The modern era's connect-time negotiation probe. The official client
%% (@modelcontextprotocol/client 2.0.0) decides the connection's era from
%% this answer: `supportedVersions` must offer a 2026-07-28+ revision and
%% `capabilities` is required — both measured against that client (a probe
%% server logging its wire traffic; the SDK's own DiscoverResult
%% validator). The result is deliberately NOT resultType-stamped: the
%% probe runs before the era verdict, and the measured client accepts the
%% bare shape. A handshake-only endpoint never reaches this clause —
%% `check_version/4` already refused the modern header — so discover
%% cannot claim an era the endpoint does not serve.
server_discover(Id, #{config := Config}) ->
    Result = #{
        <<"supportedVersions">> => supported_versions(Config),
        <<"capabilities">> => #{
            <<"tools">> => #{<<"listChanged">> => true},
            <<"resources">> => #{
                <<"subscribe">> => true,
                <<"listChanged">> => true
            }
        },
        <<"_meta">> => #{
            <<"io.modelcontextprotocol/serverInfo">> => #{
                <<"name">> => <<"Bondy">>,
                <<"version">> => server_version()
            }
        }
    },
    {200, bondy_json_rpc:result_response(Id, Result)}.

%% @private
tools_list(Id, Params, RealmUri, AuthSt, _Req, #{config := Config}) ->
    {ok, #{entries := Entries}} = bondy_mcp_gateway:manifest(RealmUri),
    Tools = lists:sort([
        Name
     || {Name, #{kind := tool}} <- maps:to_list(Entries)
    ]),
    Visible = visible_tools(Tools, Entries, RealmUri, AuthSt),
    ok = list_filter_denied(RealmUri, length(Tools) - length(Visible)),
    PageSize = maps:get(default_page_size, maps:get(list, Config)),
    {Page, NextCursor} = page(
        Visible, maps:get(<<"cursor">>, Params, undefined), PageSize, Id
    ),
    Result0 = #{
        <<"resultType">> => <<"complete">>,
        <<"tools">> => [
            bondy_mcp_wamp:tool_descriptor(maps:get(Name, Entries))
         || Name <- Page
        ],
        %% §7.8: the manifest changes at release cadence, so the cache TTL
        %% is the advertised bound; the scope is ALWAYS private — the list
        %% is RBAC-projected per principal and a shared cache would leak it.
        <<"ttlMs">> => application:get_env(
            bondy_mcp, manifest_cache_ttl, 60000
        ),
        <<"cacheScope">> => <<"private">>
    },
    Result =
        case NextCursor of
            undefined -> Result0;
            _ -> Result0#{<<"nextCursor">> => NextCursor}
        end,
    {200, bondy_json_rpc:result_response(Id, Result)}.

%% @private
tools_call(Id, Params, RealmUri, AuthSt, Req, St) ->
    Name = require_binary_param(<<"name">>, Params, Id),
    Arguments =
        case maps:get(<<"arguments">>, Params, #{}) of
            M when is_map(M) -> M;
            _ -> throw_invalid_params(Id, <<"arguments must be an object">>)
        end,
    ok = check_reserved_arguments(Id, Arguments),
    {ok, #{entries := Entries}} = bondy_mcp_gateway:manifest(RealmUri),
    Entry =
        case maps:get(Name, Entries, undefined) of
            #{kind := tool} = E -> E;
            _ -> throw_method_not_found(Id, Name)
        end,
    case is_visible(Entry, RealmUri, AuthSt) of
        true ->
            ok;
        false ->
            %% Hidden by RBAC: deliberately the same answer as absent
            %% (§6) — "exists but you can't see it" leaks the realm's
            %% tool surface. The denial IS audited (§14.1): one
            %% policy-decision record, invisible on the wire.
            _ = audit_denied(Arguments, RealmUri, AuthSt, Entry, St),
            ok = bondy_mcp_metrics:rbac_denied(RealmUri, call_authz, 1),
            throw_method_not_found(Id, Name)
    end,
    Era = maps:get(era, St, modern),
    %% `Mcp-Param-{Name}` headers and the §11.1 retry params are modern
    %% (`2026-07-28`) mechanisms; the handshake era has neither.
    ok =
        case Era of
            modern -> check_param_headers(Req, Id, Entry, Arguments);
            handshake -> ok
        end,
    {Args, KwArgs0} =
        case bondy_mcp_wamp:call_args(Arguments) of
            {ok, AK} -> AK;
            {error, badarg} -> throw_invalid_params(Id, <<"invalid @args">>)
        end,
    {KwArgs, Resume} =
        case Era of
            modern ->
                resume_kwargs(
                    Id, Params, KwArgs0, RealmUri, Name, Arguments, AuthSt
                );
            handshake ->
                {KwArgs0, undefined}
        end,
    Ctxt = wamp_context(RealmUri, AuthSt, Req, St),
    Audit = (audit_base(RealmUri, AuthSt, Entry, St))#{
        args_payload => Arguments,
        decision => allow_decision(RealmUri),
        session_id => maps:get(
            mcp_session_id, St, bondy_context:session_id(Ctxt)
        ),
        continuation => continuation(Resume)
    },
    TraceOpts = bondy_mcp_wamp:trace_options(Params),
    T0 = erlang:monotonic_time(microsecond),
    CallResult = mcp_call(
        maps:get(procedure, Entry),
        maps:get(wamp_options, Entry),
        TraceOpts,
        Args,
        KwArgs,
        Ctxt,
        St
    ),
    ok = bondy_mcp_metrics:tool_call(
        RealmUri,
        maps:get(listener, St, undefined),
        Name,
        call_status(CallResult, Era),
        erlang:monotonic_time(microsecond) - T0,
        bondy_mcp_wamp:trace_meta(TraceOpts)
    ),
    case CallResult of
        {ok, ResultMap} ->
            _ = bondy_mcp_audit:record(tool_call, Audit#{
                status => success,
                result_payload => bondy_mcp_wamp:flatten_payload(
                    maps:get(args, ResultMap), maps:get(kwargs, ResultMap)
                ),
                wamp_request_id => maps:get(request_id, ResultMap, undefined)
            }),
            {200,
                bondy_json_rpc:result_response(
                    Id, bondy_mcp_wamp:call_result(ResultMap)
                )};
        {error, #{error_uri := ?BONDY_ERROR_MCP_INPUT_REQUIRED} = ErrorMap} when
            Era == modern
        ->
            %% §11.1: the callee needs more input before it can complete —
            %% an `InputRequiredResult`, not an error. Handshake-era
            %% requests fall through to the tool-error clause below: the
            %% MRTR result type does not exist in those revisions, so the
            %% callee's signal surfaces as an ordinary retryable tool
            %% error.
            input_required(
                Id, ErrorMap, RealmUri, Name, Arguments, AuthSt, Audit, Resume
            );
        {error, #{error_uri := _} = ErrorMap} ->
            %% §10.2: tool-level failures are SUCCESSFUL responses with
            %% isError and a structured retryable marker.
            _ = bondy_mcp_audit:record(tool_call, Audit#{
                status => tool_error,
                error_uri => maps:get(error_uri, ErrorMap),
                wamp_request_id => maps:get(request_id, ErrorMap, undefined)
            }),
            {200,
                bondy_json_rpc:result_response(
                    Id, bondy_mcp_wamp:call_error(ErrorMap)
                )};
        {error, Other} ->
            ?LOG_ERROR(#{
                description => "Unexpected bondy:call error on MCP tools/call",
                reason => Other
            }),
            _ = bondy_mcp_audit:record(
                tool_call, Audit#{status => internal_error}
            ),
            {500,
                bondy_json_rpc:error_response(
                    Id, ?JSONRPC_INTERNAL_ERROR, <<"Internal error">>
                )}
    end.

%% @private
resources_read(Id, Params, RealmUri, AuthSt, Req, St) ->
    Uri = require_binary_param(<<"uri">>, Params, Id),
    {ok, #{entries := Entries}} = bondy_mcp_gateway:manifest(RealmUri),
    case match_resource(maps:values(Entries), Uri, Id) of
        {Entry, {Args, KwArgs}} ->
            Bound = bondy_mcp_wamp:flatten_payload(Args, KwArgs),
            case is_visible(Entry, RealmUri, AuthSt) of
                true ->
                    ok;
                false ->
                    _ = audit_denied(
                        Bound, RealmUri, AuthSt, Entry#{uri => Uri}, St
                    ),
                    ok = bondy_mcp_metrics:rbac_denied(
                        RealmUri, call_authz, 1
                    ),
                    throw_unknown_resource(Id, St)
            end,
            Ctxt = wamp_context(RealmUri, AuthSt, Req, St),
            Audit = (audit_base(RealmUri, AuthSt, Entry, St))#{
                uri => Uri,
                args_payload => Bound,
                decision => allow_decision(RealmUri),
                session_id => maps:get(
                    mcp_session_id, St, bondy_context:session_id(Ctxt)
                )
            },
            TraceOpts = bondy_mcp_wamp:trace_options(Params),
            T0 = erlang:monotonic_time(microsecond),
            CallResult = mcp_call(
                maps:get(procedure, Entry),
                maps:get(wamp_options, Entry),
                TraceOpts,
                Args,
                KwArgs,
                Ctxt,
                St
            ),
            ok = bondy_mcp_metrics:resource_read(
                RealmUri,
                maps:get(listener, St, undefined),
                maps:get(name, Entry),
                call_status(CallResult, maps:get(era, St, modern)),
                erlang:monotonic_time(microsecond) - T0,
                bondy_mcp_wamp:trace_meta(TraceOpts)
            ),
            case CallResult of
                {ok, ResultMap} ->
                    _ = bondy_mcp_audit:record(resource_read, Audit#{
                        status => success,
                        result_payload => bondy_mcp_wamp:flatten_payload(
                            maps:get(args, ResultMap),
                            maps:get(kwargs, ResultMap)
                        ),
                        wamp_request_id => maps:get(
                            request_id, ResultMap, undefined
                        )
                    }),
                    %% The 2026-07-28 wire schema requires the SEP-2549
                    %% cache fields on `resources/read` results (the
                    %% official v2 client refuses the result without
                    %% them). A read is a live WAMP call, so no
                    %% freshness is promised — `ttlMs: 0` — and like
                    %% `tools/list` the scope is private (the read went
                    %% through this principal's RBAC projection). The
                    %% handshake-era result schemas tolerate the extra
                    %% fields (the v1 SDK and the conformance read
                    %% scenarios pass with them present).
                    Read = (bondy_mcp_wamp:read_result(Uri, ResultMap))#{
                        <<"ttlMs">> => 0,
                        <<"cacheScope">> => <<"private">>
                    },
                    {200, bondy_json_rpc:result_response(Id, Read)};
                {error, #{error_uri := ErrorUri} = ErrorMap} ->
                    _ = bondy_mcp_audit:record(resource_read, Audit#{
                        status => tool_error,
                        error_uri => ErrorUri,
                        wamp_request_id => maps:get(
                            request_id, ErrorMap, undefined
                        )
                    }),
                    {500,
                        bondy_json_rpc:error_response(
                            Id,
                            ?JSONRPC_INTERNAL_ERROR,
                            <<"Resource read failed">>,
                            #{<<"bondy:error_uri">> => ErrorUri}
                        )};
                {error, _} ->
                    _ = bondy_mcp_audit:record(
                        resource_read, Audit#{status => internal_error}
                    ),
                    {500,
                        bondy_json_rpc:error_response(
                            Id, ?JSONRPC_INTERNAL_ERROR, <<"Internal error">>
                        )}
            end;
        nomatch ->
            throw_unknown_resource(Id, St)
    end.

%% @private
%% The first resource template whose RFC 6570 pattern matches `Uri`, with
%% its bound WAMP arguments. A variable failing its declared schema is a
%% client error naming the variable — the template DID match.
match_resource([], _, _) ->
    nomatch;
match_resource([#{kind := resource_template} = Entry | Rest], Uri, Id) ->
    case bondy_mcp_wamp:bind_template(Entry, Uri) of
        {ok, Bound} ->
            {Entry, Bound};
        nomatch ->
            match_resource(Rest, Uri, Id);
        {error, {invalid_var, Var}} ->
            throw_invalid_params(
                Id, <<"invalid value for template variable ", Var/binary>>
            )
    end;
match_resource([_ | Rest], Uri, Id) ->
    match_resource(Rest, Uri, Id).

%% =============================================================================
%% PRIVATE — the handshake era (§12)
%% =============================================================================

%% Streamable HTTP reserves 404 for a terminated or unknown session (the
%% client MUST re-initialize on it), so JSON-RPC-level failures inside an
%% established session — unknown method, unknown tool, invalid params —
%% must NOT ride HTTP error statuses that carry transport meaning. This
%% code is the reference implementation's session-not-found code.
-define(MCP_SESSION_NOT_FOUND, -32001).
%% The resources specification's "Resource not found".
-define(MCP_RESOURCE_NOT_FOUND, -32002).

%% @private
%% `initialize` (§12.1): version negotiation per the lifecycle
%% specification — echo a supported requested version, else answer the
%% latest this endpoint carries; only an endpoint with NO handshake
%% revision refuses, with the specification's own error shape. The
%% session is created only after HTTP-layer authentication; a repeat
%% `initialize` carrying a session id is `-32600`.
handshake_initialize(
    Req, #{id := Id, params := Params}, RealmUri, SessionHeader, St
) ->
    #{config := Config} = St,
    SessionHeader == undefined orelse
        throw(
            {reply, 200,
                bondy_json_rpc:error_response(
                    Id,
                    ?JSONRPC_INVALID_REQUEST,
                    <<"Session already initialized">>
                ),
                Req}
        ),
    Versions = handshake_versions(Config),
    Requested = requested_version(Params),
    Versions =/= [] orelse
        begin
            ok = bondy_mcp_metrics:version_refused(
                maps:get(listener, St, undefined),
                sanitize_version(Requested)
            ),
            throw(
                {reply, 200,
                    bondy_json_rpc:error_response(
                        Id,
                        ?JSONRPC_INVALID_PARAMS,
                        <<"Unsupported protocol version">>,
                        #{
                            <<"supported">> => supported_versions(Config),
                            <<"requested">> => Requested
                        }
                    ),
                    Req}
            )
        end,
    AuthSt = authenticate(Req, RealmUri),
    Version =
        case lists:member(Requested, Versions) of
            true -> Requested;
            false -> hd(Versions)
        end,
    case
        bondy_mcp_handshake:bootstrap(
            RealmUri,
            Version,
            AuthSt,
            cowboy_req:peer(Req),
            maps:get(listener, St, undefined)
        )
    of
        {ok, WireId} ->
            ok = bondy_mcp_metrics:session_opened(
                RealmUri, maps:get(listener, St, undefined)
            ),
            Result = #{
                <<"protocolVersion">> => Version,
                <<"capabilities">> => #{
                    <<"tools">> => #{<<"listChanged">> => true},
                    <<"resources">> => #{
                        <<"subscribe">> => true,
                        <<"listChanged">> => true
                    }
                },
                <<"serverInfo">> => #{
                    <<"name">> => <<"Bondy">>,
                    <<"version">> => server_version()
                }
            },
            Req1 = cowboy_req:set_resp_header(
                <<"mcp-session-id">>, WireId, Req
            ),
            reply(200, bondy_json_rpc:result_response(Id, Result), Req1);
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Failed to bootstrap an MCP handshake session",
                realm => RealmUri,
                reason => Reason
            }),
            reply(
                500,
                bondy_json_rpc:error_response(
                    Id, ?JSONRPC_INTERNAL_ERROR, <<"Internal error">>
                ),
                Req
            )
    end.

%% @private
requested_version(Params) ->
    case maps:get(<<"protocolVersion">>, Params, undefined) of
        V when is_binary(V) -> V;
        _ -> undefined
    end.

%% @private
server_version() ->
    case application:get_key(bondy_router, vsn) of
        {ok, Vsn} when is_list(Vsn) -> list_to_binary(Vsn);
        {ok, Vsn} when is_binary(Vsn) -> Vsn;
        _ -> <<"unknown">>
    end.

%% @private
%% A POST carrying `Mcp-Session-Id`: authenticate (per request — the
%% session is never a credential), then resolve and bind-check the
%% session, then dispatch. Only POSTs reset the idle timer (§12.8).
handshake_established(Req, Message, RealmUri, WireId, St) ->
    AuthSt = authenticate(Req, RealmUri),
    ok = check_hs_version_header(Req, rpc_id(Message), St),
    case bondy_mcp_handshake:fetch(WireId, RealmUri, AuthSt) of
        {ok, Handle, Meta} ->
            ok = bondy_mcp_handshake:touch(Handle),
            handshake_dispatch(
                Message, Handle, Meta, RealmUri, AuthSt, Req, St
            );
        {error, not_found} ->
            session_not_found(Req, rpc_id(Message))
    end.

%% @private
rpc_id({request, #{id := Id}}) -> Id;
rpc_id({notification, _}) -> undefined.

%% @private
%% 404 with the reference implementation's body: unknown, terminated,
%% cross-realm, cross-principal and unreachable-owner sessions all
%% answer it, and the client re-initializes (transport spec, session
%% rule 4). A session on a reachable member node is served through the
%% door (`bondy_mcp_handshake`); only a NON-member or unreachable owner
%% lands here.
session_not_found(Req, Id) ->
    throw(
        {reply, 404,
            bondy_json_rpc:error_response(
                Id, ?MCP_SESSION_NOT_FOUND, <<"Session not found">>
            ),
            Req}
    ).

%% @private
%% The `MCP-Protocol-Version` header on established requests: absent is
%% tolerated (the version was negotiated at initialization and the
%% session knows it — the fallback the transport spec names); present it
%% must be a handshake revision this endpoint carries.
check_hs_version_header(Req, Id, #{config := Config} = St) ->
    case cowboy_req:header(<<"mcp-protocol-version">>, Req) of
        undefined ->
            ok;
        Header ->
            lists:member(Header, handshake_versions(Config)) orelse
                begin
                    ok = bondy_mcp_metrics:version_refused(
                        maps:get(listener, St, undefined),
                        sanitize_version(Header)
                    ),
                    throw(
                        {reply, 400,
                            bondy_json_rpc:error_response(
                                Id,
                                ?JSONRPC_INVALID_REQUEST,
                                <<
                                    "Invalid or unsupported "
                                    "MCP-Protocol-Version"
                                >>
                            ),
                            Req}
                    )
                end,
            ok
    end.

%% @private
handshake_dispatch(
    {notification, #{method := Method, params := Params}},
    Handle,
    _Meta,
    _RealmUri,
    _AuthSt,
    Req,
    _St
) ->
    ok =
        case Method of
            <<"notifications/cancelled">> ->
                %% §12.5: a real client-to-server cancellation. Arriving
                %% after the response was sent is a no-op (the in-flight
                %% entry is gone).
                case maps:get(<<"requestId">>, Params, undefined) of
                    undefined -> ok;
                    ReqId -> bondy_mcp_handshake:cancel_inflight(Handle, ReqId)
                end;
            _ ->
                %% `notifications/initialized` and anything else is
                %% accepted; no initializing→ready state machine exists
                %% (§12.1).
                ok
        end,
    cowboy_req:reply(202, #{}, <<>>, Req);
handshake_dispatch(
    {request, #{id := Id, method := Method, params := Params}},
    Handle,
    Meta,
    RealmUri,
    AuthSt,
    Req,
    St0
) ->
    St = St0#{
        era => handshake,
        hs_handle => Handle,
        rpc_id => Id,
        mcp_session_id => maps:get(session_id, Meta)
    },
    T0 = erlang:monotonic_time(microsecond),
    Outcome =
        try
            hs_method(Method, Id, Params, Handle, RealmUri, AuthSt, Req, St)
        catch
            throw:{reply2, S, B} -> {S, B}
        end,
    ok = bondy_mcp_metrics:request_stop(
        RealmUri, Method, erlang:monotonic_time(microsecond) - T0
    ),
    {Status, Response} = hs_status(Outcome),
    reply(Status, Response, Req).

%% @private
%% See the ?MCP_SESSION_NOT_FOUND comment: inside a session, JSON-RPC
%% failures ride 200 — a 400/404 here would tell the client something
%% about the SESSION that is not true.
hs_status({400, Response}) -> {200, Response};
hs_status({404, Response}) -> {200, Response};
hs_status(Outcome) -> Outcome.

%% @private
hs_method(<<"ping">>, Id, _, _, _, _, _, _) ->
    {200, bondy_json_rpc:result_response(Id, #{})};
hs_method(<<"tools/list">>, Id, Params, _, RealmUri, AuthSt, _, St) ->
    hs_list(tool, Id, Params, RealmUri, AuthSt, St);
hs_method(<<"resources/list">>, Id, Params, _, RealmUri, AuthSt, _, St) ->
    hs_list(resource, Id, Params, RealmUri, AuthSt, St);
hs_method(
    <<"resources/templates/list">>, Id, Params, _, RealmUri, AuthSt, _, St
) ->
    hs_list(resource_template, Id, Params, RealmUri, AuthSt, St);
hs_method(<<"tools/call">>, Id, Params, _, RealmUri, AuthSt, Req, St) ->
    tools_call(Id, Params, RealmUri, AuthSt, Req, St);
hs_method(<<"resources/read">>, Id, Params, _, RealmUri, AuthSt, Req, St) ->
    resources_read(Id, Params, RealmUri, AuthSt, Req, St);
hs_method(
    <<"resources/subscribe">>, Id, Params, Handle, RealmUri, AuthSt, _, St
) ->
    hs_subscribe(Id, Params, Handle, RealmUri, AuthSt, St);
hs_method(<<"resources/unsubscribe">>, Id, Params, Handle, _, _, _, _) ->
    Uri = require_binary_param(<<"uri">>, Params, Id),
    case bondy_mcp_handshake:unsubscribe(Handle, Uri) of
        ok ->
            {200, bondy_json_rpc:result_response(Id, #{})};
        {error, not_found} ->
            hs_unknown_resource(Id);
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "MCP resources/unsubscribe failed",
                reason => Reason
            }),
            {500,
                bondy_json_rpc:error_response(
                    Id, ?JSONRPC_INTERNAL_ERROR, <<"Internal error">>
                )}
    end;
hs_method(Method, Id, _, _, _, _, _, _) ->
    {200,
        bondy_json_rpc:error_response(
            Id,
            ?JSONRPC_METHOD_NOT_FOUND,
            <<"Method not found: ", Method/binary>>
        )}.

%% @private
%% The three listings share the §12.7 cursor: RBAC filtering AFTER
%% slicing — a page can be short once hidden entries are removed, and the
%% cursor advances by the raw slice, so a manifest dense with hidden
%% entries cannot amplify scans. The cursor embeds a content tag over the
%% listed kind's `name => hash` projection; a stale one is `-32602` and
%% the client restarts the listing.
hs_list(Kind, Id, Params, RealmUri, AuthSt, #{config := Config}) ->
    {ok, #{entries := Entries}} = bondy_mcp_gateway:manifest(RealmUri),
    Names = lists:sort([
        N
     || {N, #{kind := K}} <- maps:to_list(Entries),
        K == Kind
    ]),
    Tag = erlang:phash2([
        {N, maps:get(hash, maps:get(N, Entries))}
     || N <- Names
    ]),
    PageSize = maps:get(default_page_size, maps:get(list, Config)),
    {RawPage, NextCursor} = hs_page(
        Names, maps:get(<<"cursor">>, Params, undefined), Tag, PageSize, Id
    ),
    Visible = hs_visible(RawPage, Entries, RealmUri, AuthSt),
    ok = list_filter_denied(RealmUri, length(RawPage) - length(Visible)),
    {Key, Descriptor} = hs_descriptor(Kind),
    Result0 = #{
        Key => [Descriptor(maps:get(N, Entries)) || N <- Visible]
    },
    Result =
        case NextCursor of
            undefined -> Result0;
            _ -> Result0#{<<"nextCursor">> => NextCursor}
        end,
    {200, bondy_json_rpc:result_response(Id, Result)}.

%% @private
hs_descriptor(tool) ->
    {<<"tools">>, fun bondy_mcp_wamp:tool_descriptor/1};
hs_descriptor(resource) ->
    {<<"resources">>, fun bondy_mcp_wamp:resource_descriptor/1};
hs_descriptor(resource_template) ->
    {<<"resourceTemplates">>,
        fun bondy_mcp_wamp:resource_template_descriptor/1}.

%% @private
%% The cursor's tag is BOUND in the pattern: a cursor minted against a
%% different manifest content fails the match and answers stale.
hs_page(Names, undefined, Tag, PageSize, _) ->
    hs_split(Names, Tag, PageSize);
hs_page(Names, Cursor, Tag, PageSize, Id) when is_binary(Cursor) ->
    After =
        try binary_to_term(base64:decode(Cursor), [safe]) of
            {hs1, Tag, Name} when is_binary(Name) -> Name;
            _ -> throw_invalid_params(Id, <<"invalid or stale cursor">>)
        catch
            error:_ -> throw_invalid_params(Id, <<"invalid or stale cursor">>)
        end,
    hs_split([N || N <- Names, N > After], Tag, PageSize);
hs_page(_, _, _, _, Id) ->
    throw_invalid_params(Id, <<"invalid or stale cursor">>).

%% @private
hs_split(Names, _, PageSize) when length(Names) =< PageSize ->
    {Names, undefined};
hs_split(Names, Tag, PageSize) ->
    Page = lists:sublist(Names, PageSize),
    {Page, base64:encode(term_to_binary({hs1, Tag, lists:last(Page)}))}.

%% @private
%% Visibility, total over entry shapes: procedure-backed entries by
%% `wamp.call` on the procedure, topic-backed by `wamp.subscribe` on the
%% topic, and an entry with neither is visible — there is nothing to
%% authorize against until it is used.
hs_visible([], _, _, _) ->
    [];
hs_visible(Names, Entries, RealmUri, AuthSt) ->
    case rbac_context(RealmUri, AuthSt) of
        none ->
            Names;
        {filter, RbacCtxt0} ->
            {Visible, _} = lists:foldl(
                fun(Name, {Acc, C0}) ->
                    case entry_permission(maps:get(Name, Entries)) of
                        none ->
                            {[Name | Acc], C0};
                        Permission ->
                            case bondy_rbac:check_permission(Permission, C0) of
                                {true, C} -> {[Name | Acc], C};
                                {false, _, C} -> {Acc, C}
                            end
                    end
                end,
                {[], RbacCtxt0},
                Names
            ),
            lists:reverse(Visible)
    end.

%% @private
entry_permission(#{procedure := P}) -> {<<"wamp.call">>, P};
entry_permission(#{topic := T}) -> {<<"wamp.subscribe">>, T};
entry_permission(_) -> none.

%% @private
%% `resources/subscribe` (§12.4): the URI resolves through the manifest
%% to an update topic; absent, unresolvable (a procedure-backed resource
%% with no update topic answers `unsupported` as absence) and RBAC-hidden
%% answer identically (§6) — only the denial leaves an audit record.
hs_subscribe(Id, Params, Handle, RealmUri, AuthSt, St) ->
    Uri = require_binary_param(<<"uri">>, Params, Id),
    {ok, #{entries := Entries}} = bondy_mcp_gateway:manifest(RealmUri),
    case hs_resolve(maps:values(Entries), Uri) of
        {ok, Entry, Topic} ->
            case allowed_subscribe(Topic, RealmUri, AuthSt) of
                true ->
                    case bondy_mcp_handshake:subscribe(Handle, Uri, Topic) of
                        ok ->
                            ok = bondy_mcp_metrics:resource_subscribed(
                                RealmUri, maps:get(name, Entry)
                            ),
                            {200, bondy_json_rpc:result_response(Id, #{})};
                        {error, Reason} ->
                            ?LOG_ERROR(#{
                                description =>
                                    "MCP resources/subscribe failed",
                                reason => Reason
                            }),
                            {500,
                                bondy_json_rpc:error_response(
                                    Id,
                                    ?JSONRPC_INTERNAL_ERROR,
                                    <<"Internal error">>
                                )}
                    end;
                false ->
                    _ = audit_denied(
                        #{<<"uri">> => Uri},
                        RealmUri,
                        AuthSt,
                        Entry#{uri => Uri},
                        St
                    ),
                    ok = bondy_mcp_metrics:rbac_denied(
                        RealmUri, subscribe_authz, 1
                    ),
                    hs_unknown_resource(Id)
            end;
        nomatch ->
            hs_unknown_resource(Id)
    end.

%% @private
hs_resolve([], _) ->
    nomatch;
hs_resolve([Entry | Rest], Uri) ->
    case bondy_mcp_wamp:resolve_update_topic(Entry, Uri) of
        {ok, Topic} -> {ok, Entry, Topic};
        _ -> hs_resolve(Rest, Uri)
    end.

%% @private
allowed_subscribe(Topic, RealmUri, AuthSt) ->
    case rbac_context(RealmUri, AuthSt) of
        none ->
            true;
        {filter, RbacCtxt} ->
            case
                bondy_rbac:check_permission(
                    {<<"wamp.subscribe">>, Topic}, RbacCtxt
                )
            of
                {true, _} -> true;
                {false, _, _} -> false
            end
    end.

%% @private
hs_unknown_resource(Id) ->
    {200,
        bondy_json_rpc:error_response(
            Id, ?MCP_RESOURCE_NOT_FOUND, <<"Resource not found">>
        )}.

%% @private
%% The held GET stream (§12.2): one per session — a live predecessor
%% answers 409 (the reference implementation's status) — delivering the
%% queue's backlog first, then whatever the session enqueues while
%% connected. Deliberately NOT `touch`ed: a held stream is not activity
%% (§12.8).
handshake_get(Req0, RealmUri, St) ->
    AuthSt = authenticate(Req0, RealmUri),
    WireId = require_session_header(Req0),
    ok = check_hs_version_header(Req0, undefined, St),
    case bondy_mcp_handshake:fetch(WireId, RealmUri, AuthSt) of
        {ok, Handle, _Meta} ->
            {ok, _, TransportId} =
                bondy_mcp_handshake:parse_session_id(WireId),
            case bondy_mcp_handshake:attach_stream(Handle, TransportId) of
                {ok, Stream} ->
                    Req = cowboy_req:stream_reply(
                        200,
                        #{
                            <<"content-type">> =>
                                <<"text/event-stream; charset=utf-8">>,
                            <<"cache-control">> => <<"no-cache">>,
                            <<"x-accel-buffering">> => <<"no">>
                        },
                        Req0
                    ),
                    %% Local streams drain the queue themselves; the
                    %% initial kick delivers the backlog buffered while
                    %% no stream was connected (§12.2). A remote
                    %% stream's backlog flows from the owner-side proxy,
                    %% whose registration triggers the same kick there.
                    case Stream of
                        #{mode := local} -> self() ! drain_queue;
                        _ -> ok
                    end,
                    {loop_state, Req, St#{hs_stream => Stream}};
                {error, not_found} ->
                    session_not_found(Req0, undefined);
                {error, already_registered} ->
                    throw(
                        {reply, 409,
                            bondy_json_rpc:error_response(
                                undefined,
                                ?JSONRPC_INVALID_REQUEST,
                                <<"Only one stream per session">>
                            ),
                            Req0}
                    )
            end;
        {error, not_found} ->
            session_not_found(Req0, undefined)
    end.

%% @private
%% `DELETE` (§12.8): graceful close — in-flight calls are cancelled (each
%% pending POST answers with its cancellation error), the stream and
%% queue go with the transport session, and the stored WAMP session and
%% its subscriptions with the session manager's monitor. Close metrics
%% ride the transport session's lifecycle event (emitted on the OWNING
%% node, where the open was counted) — not this handler.
handshake_delete(Req, RealmUri, _St) ->
    AuthSt = authenticate(Req, RealmUri),
    WireId = require_session_header(Req),
    case bondy_mcp_handshake:fetch(WireId, RealmUri, AuthSt) of
        {ok, Handle, _Meta} ->
            ok = bondy_mcp_handshake:close(Handle),
            cowboy_req:reply(204, #{}, <<>>, Req);
        {error, not_found} ->
            session_not_found(Req, undefined)
    end.

%% @private
require_session_header(Req) ->
    case cowboy_req:header(<<"mcp-session-id">>, Req) of
        WireId when is_binary(WireId) ->
            WireId;
        undefined ->
            throw(
                {reply, 400,
                    bondy_json_rpc:error_response(
                        undefined,
                        ?JSONRPC_INVALID_REQUEST,
                        <<"Mcp-Session-Id header required">>
                    ),
                    Req}
            )
    end.

%% =============================================================================
%% PRIVATE — multi round-trip requests (§11.1)
%% =============================================================================

%% @private
%% The `_mcp`-prefixed argument namespace is reserved for the gateway's
%% own channel to the callee (`_mcp_state`, `_mcp_input_responses`): a
%% client-supplied argument there could impersonate that channel.
check_reserved_arguments(Id, Arguments) ->
    Reserved = [K || <<"_mcp", _/binary>> = K <- maps:keys(Arguments)],
    Reserved == [] orelse
        throw_invalid_params(
            Id, <<"argument names beginning with _mcp are reserved">>
        ),
    ok.

%% @private
%% A retry of an input-required call carries `inputResponses` and — when
%% the first leg issued one — `requestState`. The request state is
%% attacker-controlled input: it opens ONLY under this realm's keys, on
%% an unexpired envelope bound to this same principal, method, tool and
%% argument digest, and every failure is one uniform client error.
resume_kwargs(Id, Params, KwArgs0, RealmUri, Name, Arguments, AuthSt) ->
    KwArgs1 =
        case maps:get(<<"inputResponses">>, Params, undefined) of
            undefined ->
                KwArgs0;
            Responses when is_map(Responses) ->
                KwArgs0#{<<"_mcp_input_responses">> => Responses};
            _ ->
                throw_invalid_params(
                    Id, <<"inputResponses must be an object">>
                )
        end,
    case maps:get(<<"requestState">>, Params, undefined) of
        undefined ->
            {KwArgs1, undefined};
        Sealed ->
            Expect = #{
                principal => principal_binding(AuthSt),
                method => <<"tools/call">>,
                name => Name,
                args_hash => bondy_mcp_request_state:args_hash(Arguments)
            },
            case bondy_mcp_request_state:open(RealmUri, Sealed, Expect) of
                {ok, #{continuation := Continuation, state := State}} ->
                    {KwArgs1#{<<"_mcp_state">> => State}, #{
                        continuation => Continuation
                    }};
                {error, invalid} ->
                    throw_invalid_params(
                        Id,
                        <<"invalid, expired or mismatched requestState">>
                    )
            end
    end.

%% @private
%% The callee signalled `bondy.error.mcp.input_required`. A resumed call
%% keeps its continuation id so every audit record of one logical MRTR
%% call correlates; a first leg mints it. A malformed signal, or a
%% continuation too large to seal, is a CALLEE bug answered as an internal
%% error — never forwarded to the client.
input_required(Id, ErrorMap, RealmUri, Name, Arguments, AuthSt, Audit, Resume) ->
    WampReqId = maps:get(request_id, ErrorMap, undefined),
    case bondy_mcp_wamp:input_required(ErrorMap) of
        {ok, #{input_requests := Requests, state := State}} ->
            Continuation =
                case Resume of
                    #{continuation := C} -> C;
                    undefined -> bondy_utils:uuid()
                end,
            SealResult =
                case State of
                    undefined ->
                        {ok, undefined};
                    _ ->
                        bondy_mcp_request_state:seal(RealmUri, #{
                            continuation => Continuation,
                            principal => principal_binding(AuthSt),
                            method => <<"tools/call">>,
                            name => Name,
                            args_hash => bondy_mcp_request_state:args_hash(
                                Arguments
                            ),
                            state => State
                        })
                end,
            case SealResult of
                {ok, SealedState} ->
                    _ = bondy_mcp_audit:record(tool_call, Audit#{
                        status => input_required,
                        continuation => Continuation,
                        wamp_request_id => WampReqId
                    }),
                    {200,
                        bondy_json_rpc:result_response(
                            Id,
                            bondy_mcp_wamp:input_required_result(
                                Requests, SealedState
                            )
                        )};
                {error, too_large} ->
                    input_required_callee_bug(
                        Id, too_large, Name, Audit, WampReqId
                    )
            end;
        {error, badarg} ->
            input_required_callee_bug(Id, badarg, Name, Audit, WampReqId)
    end.

%% @private
input_required_callee_bug(Id, Reason, Name, Audit, WampReqId) ->
    ?LOG_ERROR(#{
        description =>
            "Invalid bondy.error.mcp.input_required signal from callee",
        reason => Reason,
        name => Name
    }),
    _ = bondy_mcp_audit:record(tool_call, Audit#{
        status => internal_error,
        wamp_request_id => WampReqId
    }),
    {500,
        bondy_json_rpc:error_response(
            Id, ?JSONRPC_INTERNAL_ERROR, <<"Internal error">>
        )}.

%% @private
%% What of the caller's identity the envelope binds. An anonymous
%% principal has NO stable identity — the handler mints a fresh authid per
%% request — so the binding is the anonymous class: any anonymous client
%% of the realm may resume, which is the strongest binding a realm without
%% authentication admits. Realms with security disabled bind the same way.
principal_binding(#{is_anonymous := true}) -> anonymous;
principal_binding(#{authid := Authid}) -> Authid.

%% @private
continuation(#{continuation := C}) -> C;
continuation(undefined) -> undefined.

%% =============================================================================
%% PRIVATE — RBAC projection (§6)
%% =============================================================================

%% @private
%% The list filter: the context is fetched (and MEASURED) once, then
%% `bondy_rbac:check_permission/2` folds over the entries THREADING the
%% context it returns — `authorize/3` discards it, which is the §6 trap.
visible_tools([], _, _, _) ->
    [];
visible_tools(Names, Entries, RealmUri, AuthSt) ->
    case rbac_context(RealmUri, AuthSt) of
        none ->
            Names;
        {filter, RbacCtxt0} ->
            {Visible, _} = lists:foldl(
                fun(Name, {Acc, RC0}) ->
                    %% The permission subject is the entry's PROCEDURE,
                    %% exactly as `is_visible/3` checks a direct call —
                    %% an overlay-renamed tool must not list under its
                    %% MCP name while its call is judged by its
                    %% procedure.
                    Procedure = maps:get(
                        procedure, maps:get(Name, Entries)
                    ),
                    case
                        bondy_rbac:check_permission(
                            {<<"wamp.call">>, Procedure}, RC0
                        )
                    of
                        {true, RC} -> {[Name | Acc], RC};
                        {false, _, RC} -> {Acc, RC}
                    end
                end,
                {[], RbacCtxt0},
                Names
            ),
            lists:reverse(Visible)
    end.

%% @private
%% §15.1 `rbac_denied{surface=list_filter}`: the entries a list
%% projection hid from this principal.
list_filter_denied(_, 0) ->
    ok;
list_filter_denied(RealmUri, Hidden) when Hidden > 0 ->
    bondy_mcp_metrics:rbac_denied(RealmUri, list_filter, Hidden).

%% @private
is_visible(Entry, RealmUri, AuthSt) ->
    case rbac_context(RealmUri, AuthSt) of
        none ->
            true;
        {filter, RbacCtxt} ->
            case
                bondy_rbac:check_permission(
                    {<<"wamp.call">>, maps:get(procedure, Entry)}, RbacCtxt
                )
            of
                {true, _} -> true;
                {false, _, _} -> false
            end
    end.

%% @private
%% The per-request RBAC context (§5.2): built from an UNSTORED session —
%% the explicitly supported input `bondy_session:rbac_context/1` has a
%% clause for — and measured, because this build is the floor of every
%% modern request on a security-enabled realm (§2.5.4).
rbac_context(RealmUri, AuthSt) ->
    case bondy_realm:is_security_enabled(RealmUri) of
        false ->
            none;
        true ->
            Session = unstored_session(RealmUri, AuthSt, {{127, 0, 0, 1}, 0}),
            T0 = erlang:monotonic_time(),
            RbacCtxt = bondy_session:rbac_context(Session),
            telemetry:execute(
                [bondy_mcp, modern, rbac_context_build],
                #{duration => erlang:monotonic_time() - T0},
                #{realm => RealmUri}
            ),
            {filter, RbacCtxt}
    end.

%% =============================================================================
%% PRIVATE — audit capture (§14)
%% =============================================================================

%% @private
%% What every audit record on this request shares: the principal, the
%% listener the request arrived on and its transport (descriptive only —
%% §6), and the manifest entry's identity including its §7.5 hash, so the
%% record ties to the exact tool version invoked. The entry's §14.3
%% redaction policy rides along and governs the digests.
audit_base(RealmUri, AuthSt, Entry, St) ->
    #{
        realm => RealmUri,
        listener => maps:get(listener, St),
        transport => maps:get(transport, St),
        principal => maps:get(authid, AuthSt),
        is_anonymous => maps:get(is_anonymous, AuthSt),
        name => maps:get(name, Entry),
        uri => maps:get(uri, Entry, undefined),
        procedure => maps:get(procedure, Entry, undefined),
        entry_hash => maps:get(hash, Entry),
        redaction => maps:get(redaction, Entry, none)
    }.

%% @private
%% §14.1's policy-decision record: an RBAC denial the wire deliberately
%% does not distinguish from absence. Denial only arises on a
%% security-enabled realm, so the decision source is `rbac`.
audit_denied(Arguments, RealmUri, AuthSt, Entry, St) ->
    bondy_mcp_audit:record(
        policy_decision,
        (audit_base(RealmUri, AuthSt, Entry, St))#{
            args_payload => Arguments,
            decision => #{verdict => deny, rule => undefined, source => rbac},
            status => denied
        }
    ).

%% @private
%% `rule` stays `undefined` until `bondy_rbac` surfaces which grant
%% matched — the §14.2 schema carries the field from the first release.
allow_decision(RealmUri) ->
    Source =
        case bondy_realm:is_security_enabled(RealmUri) of
            true -> rbac;
            false -> none
        end,
    #{verdict => allow, rule => undefined, source => Source}.

%% =============================================================================
%% PRIVATE — the §5.2 per-request session and context
%% =============================================================================

%% @private
%% The WAMP call, era-routed. Modern requests use the blocking
%% `bondy:call/5`. Handshake requests split it into its own two exported
%% halves — `bondy:cast/5`, which yields the WAMP request id, and
%% `bondy:check_response/4` — registering the in-flight call in between
%% so `notifications/cancelled` (and session close) can cancel it with
%% the original caller context (§12.5); the dealer then answers THIS
%% blocked process with the cancellation error. The WAMP cancel mode is
%% the manifest entry's `cancel_mode` option, `killnowait` by default.
mcp_call(Procedure, EntryOpts, TraceOpts, Args, KwArgs, Ctxt, St) ->
    Realm = bondy_context:realm_uri(Ctxt),
    Listener = maps:get(listener, St, undefined),
    ok = bondy_mcp_metrics:call_inflight(Realm, Listener, 1),
    try
        do_mcp_call(Procedure, EntryOpts, TraceOpts, Args, KwArgs, Ctxt, St)
    after
        %% Paired in `after` so the gauge cannot drift on an exception.
        bondy_mcp_metrics:call_inflight(Realm, Listener, -1)
    end.

%% @private
do_mcp_call(Procedure, EntryOpts, TraceOpts, Args, KwArgs, Ctxt, St) ->
    %% Disjoint merge: the manifest options are binary-keyed, the trace
    %% options are the declared extension atoms (§15.4).
    Opts = maps:merge(
        maps:with([<<"timeout">>, <<"disclose_me">>], EntryOpts),
        TraceOpts
    ),
    case maps:get(era, St, modern) of
        modern ->
            bondy:call(Procedure, Opts, Args, KwArgs, Ctxt);
        handshake ->
            #{hs_handle := Handle, rpc_id := Id} = St,
            Mode = maps:get(<<"cancel_mode">>, EntryOpts, <<"killnowait">>),
            case bondy:cast(Procedure, Opts, Args, KwArgs, Ctxt) of
                {ok, ReqId} ->
                    ok = bondy_mcp_handshake:register_inflight(Handle, Id, #{
                        req_id => ReqId,
                        ctxt => Ctxt,
                        mode => Mode
                    }),
                    Result = bondy:check_response(
                        Procedure, ReqId, call_timeout(Opts), Ctxt
                    ),
                    ok = bondy_mcp_handshake:unregister_inflight(Handle, Id),
                    Result;
                {error, _} = Error ->
                    Error
            end
    end.

%% @private
%% The §15.1 status label from an `mcp_call` outcome. As-built enum:
%% `success | input_required | tool_error | internal_error` — a WAMP
%% timeout or cancellation surfaces as an error URI and lands in
%% `tool_error` (§21.10 records the deviation from §15.1's enum).
call_status({ok, _}, _) ->
    success;
call_status({error, #{error_uri := ?BONDY_ERROR_MCP_INPUT_REQUIRED}}, modern) ->
    input_required;
call_status({error, #{error_uri := _}}, _) ->
    tool_error;
call_status({error, _}, _) ->
    internal_error.

%% @private
%% The same timeout derivation `bondy:call/5` applies.
call_timeout(Opts) ->
    case maps:get(<<"timeout">>, Opts, 0) of
        0 -> bondy_config:get(wamp_call_timeout);
        Timeout -> Timeout
    end.

%% @private
wamp_context(RealmUri, AuthSt, Req, _St) ->
    Peer = cowboy_req:peer(Req),
    Session = unstored_session(RealmUri, AuthSt, Peer),
    bondy_context:new(Peer, {http, text, json}, #{session => Session}).

%% @private
%% `bondy_session:new/2` constructs; `store/1` is never called on this
%% path. `progressive_call_results => true` is the load-bearing line: both
%% progressive features are strict-opt-in per session, and §9.4's progress
%% delivery silently degrades without it.
unstored_session(RealmUri, AuthSt, Peer) ->
    bondy_session:new(RealmUri, #{
        peer => Peer,
        is_anonymous => maps:get(is_anonymous, AuthSt),
        authid => maps:get(authid, AuthSt),
        authroles => maps:get(authroles, AuthSt),
        roles => #{
            caller => #{
                features => #{
                    call_timeout => true,
                    caller_identification => true,
                    call_trustlevels => true,
                    call_canceling => true,
                    progressive_call_results => true
                }
            }
        }
    }).

%% =============================================================================
%% PRIVATE — Mcp-Param-{Name} headers (x-mcp-header)
%% =============================================================================

%% @private
%% For every `inputSchema` property annotated `x-mcp-header` whose value is
%% present in `arguments`, the corresponding `Mcp-Param-{Name}` header must
%% be present and — after sentinel decoding — equal the value's string
%% form; a header for an ABSENT value must itself be absent. Runs after
%% the visibility check so a hidden tool's schema leaks nothing.
check_param_headers(Req, Id, Entry, Arguments) ->
    Props = maps:get(
        <<"properties">>, maps:get(input_schema, Entry, #{}), #{}
    ),
    maps:foreach(
        fun(Prop, Schema) ->
            case
                is_map(Schema) andalso
                    maps:get(<<"x-mcp-header">>, Schema, undefined)
            of
                HeaderName when is_binary(HeaderName) ->
                    check_param_header(
                        Req,
                        Id,
                        HeaderName,
                        maps:get(Prop, Arguments, undefined)
                    );
                _ ->
                    ok
            end
        end,
        Props
    ).

%% @private
check_param_header(Req, Id, HeaderName, BodyValue) ->
    Header = cowboy_req:header(
        <<"mcp-param-", (string:lowercase(HeaderName))/binary>>, Req
    ),
    Expected =
        case BodyValue of
            undefined ->
                undefined;
            _ ->
                case bondy_mcp_wamp:encode_header_value(BodyValue) of
                    {ok, V} -> V;
                    {error, badarg} -> mismatch
                end
        end,
    Decoded =
        case Header of
            undefined ->
                undefined;
            _ ->
                case bondy_mcp_wamp:decode_header_value(Header) of
                    {ok, D} -> D;
                    {error, badarg} -> mismatch
                end
        end,
    Decoded == Expected orelse
        throw(
            {reply, 400,
                bondy_json_rpc:error_response(
                    Id,
                    ?MCP_HEADER_MISMATCH,
                    <<
                        "Mcp-Param-",
                        HeaderName/binary,
                        " is missing or disagrees with the request body"
                    >>
                ),
                Req}
        ),
    ok.

%% =============================================================================
%% PRIVATE — pagination and replies
%% =============================================================================

%% @private
%% Keyset pagination over the name-sorted visible list. The cursor is an
%% opaque versioned token; anything that does not decode is a client error.
page(Names, undefined, PageSize, _) ->
    split_page(Names, PageSize);
page(Names, Cursor, PageSize, Id) when is_binary(Cursor) ->
    After =
        try binary_to_term(base64:decode(Cursor), [safe]) of
            {v1, Name} when is_binary(Name) -> Name;
            _ -> throw_invalid_params(Id, <<"invalid cursor">>)
        catch
            error:_ -> throw_invalid_params(Id, <<"invalid cursor">>)
        end,
    split_page([N || N <- Names, N > After], PageSize);
page(_, _, _, Id) ->
    throw_invalid_params(Id, <<"invalid cursor">>).

%% @private
split_page(Names, PageSize) when length(Names) =< PageSize ->
    {Names, undefined};
split_page(Names, PageSize) ->
    Page = lists:sublist(Names, PageSize),
    {Page, base64:encode(term_to_binary({v1, lists:last(Page)}))}.

%% @private
require_binary_param(Key, Params, Id) ->
    case maps:get(Key, Params, undefined) of
        V when is_binary(V), V =/= <<>> ->
            V;
        _ ->
            throw_invalid_params(
                Id, <<"missing or invalid required param ", Key/binary>>
            )
    end.

%% @private
throw_invalid_params(Id, Message) ->
    throw(
        {reply2, 400,
            bondy_json_rpc:error_response(
                Id, ?JSONRPC_INVALID_PARAMS, Message
            )}
    ).

%% @private
throw_method_not_found(Id, Name) ->
    throw(
        {reply2, 404,
            bondy_json_rpc:error_response(
                Id,
                ?JSONRPC_METHOD_NOT_FOUND,
                <<"Method not found: ", Name/binary>>
            )}
    ).

%% @private
%% Absent and RBAC-hidden resources answer identically (§6's leak rule,
%% applied to the resource space). Each era speaks its own dialect: the
%% handshake era uses the resources specification's `-32002` (ridden on
%% 200 by `hs_status/1`), the modern era its `-32602` on 400.
throw_unknown_resource(Id, #{era := handshake}) ->
    throw(
        {reply2, 404,
            bondy_json_rpc:error_response(
                Id, ?MCP_RESOURCE_NOT_FOUND, <<"Resource not found">>
            )}
    );
throw_unknown_resource(Id, _) ->
    throw(
        {reply2, 400,
            bondy_json_rpc:error_response(
                Id, ?JSONRPC_INVALID_PARAMS, <<"Unknown resource">>
            )}
    ).

%% @private
reply(Status, Body, Req) ->
    cowboy_req:reply(Status, ?JSON_CT, bondy_json_rpc:encode(Body), Req).

%% @private
send_frames(Frames, Req) ->
    lists:foreach(
        fun(Bin) ->
            cowboy_req:stream_events(#{data => Bin}, nofin, Req)
        end,
        Frames
    ).

%% @private
%% 401 with the OAuth-shaped challenge. Nothing was started.
reply_unauthorized(Reason, Req, #{base_uri := _}) ->
    ?LOG_INFO(#{
        description => "Unauthorized MCP request",
        reason => Reason
    }),
    Req1 = cowboy_req:set_resp_header(
        <<"www-authenticate">>, <<"Bearer">>, Req
    ),
    cowboy_req:reply(401, #{}, <<>>, Req1).
