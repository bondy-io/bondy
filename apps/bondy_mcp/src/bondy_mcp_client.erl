%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_client).

-moduledoc """
A Streamable HTTP MCP client (design §13): the protocol half of projecting
an upstream MCP server's tools into the WAMP registry. Stateless — a
connection is a value (`t()`), owned and refreshed by
`bondy_mcp_upstream`; every function here is a plain call over an
`bondy_http_connector_http_pool` shared with the upstream's declared
`http_connector` service.

Implements the transport's client obligations (2025-06-18 / 2025-11-25,
verified against the specification's transports page):

- every message is one HTTP POST with `Accept: application/json,
  text/event-stream`, and both response framings are supported — a JSON
  body is one message, an SSE body is cut into events and each `data:`
  payload decoded;
- the `Mcp-Session-Id` assigned on the `InitializeResult` response rides
  every subsequent request, and `MCP-Protocol-Version` carries the
  negotiated version on every post-initialize request;
- a `404` on a session-carrying request is returned as
  `{error, session_expired}` — re-initialization is the owner's move
  (single-flight in `bondy_mcp_upstream`), not this module's;
- `close/1` sends the SHOULD-level `DELETE`, tolerating `405`.

Server→client traffic inside a POST's SSE body is answered after the body
is consumed (the pool reads full bodies): `ping` gets its empty result,
anything else `-32601`, each POSTed back as a response message. A server
that blocks its own tool response on an in-stream request before ours
arrives will time out — a documented bound of the full-body read, not a
target.

Authentication is the service's own (`bondy_http_connector_token_cache` +
the service's `auth_mod`), applied per request with the connector's
`401`/`403` invalidate-and-retry-once posture. `auth => none` skips it.
""".

-include_lib("kernel/include/logger.hrl").

%% The handshake-era revisions this client speaks, newest first. The
%% requested version is the newest; anything else the server negotiates
%% down to must be one of these or `connect/1` refuses.
-define(VERSIONS, [~"2025-11-25", ~"2025-06-18"]).

-type t() :: #{
    url := binary(),
    pool := atom(),
    service := binary(),
    auth := none | {module(), map()},
    timeout := pos_integer(),
    version := binary() | undefined,
    session_id := binary() | undefined,
    server_info := map()
}.

-export_type([t/0]).

-export([call_tool/3]).
-export([call_tool/4]).
-export([close/1]).
-export([connect/1]).
-export([list_tools/1]).
-export([new/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
A connection value for `connect/1`. `url` is the full MCP endpoint URL;
`pool` an `bondy_http_connector_http_pool` name; `service` the token
cache key; `auth` the service's `{AuthMod, AuthConf}` or `none`.
""".
-spec new(map()) -> t().

new(#{url := Url, pool := Pool, service := Service} = Opts) ->
    #{
        url => Url,
        pool => Pool,
        service => Service,
        auth => maps:get(auth, Opts, none),
        timeout => maps:get(timeout, Opts, 30000),
        version => undefined,
        session_id => undefined,
        server_info => #{}
    }.

-doc """
Runs the initialization phase: `initialize`, version negotiation, session
id capture, `notifications/initialized`. Returns the connection to use
for every subsequent call.
""".
-spec connect(t()) -> {ok, t()} | {error, any()}.

connect(#{} = Conn0) ->
    [Requested | _] = ?VERSIONS,
    Params = #{
        ~"protocolVersion" => Requested,
        ~"capabilities" => #{},
        ~"clientInfo" => #{
            ~"name" => ~"Bondy",
            ~"version" => client_version()
        }
    },
    Conn = Conn0#{version => undefined, session_id => undefined},
    case request(Conn, ~"initialize", Params) of
        {ok, Result, RespHeaders} ->
            connected(Conn, Result, RespHeaders);
        {error, _} = Error ->
            Error
    end.

-doc """
The upstream's complete tool list, following `nextCursor` pagination.
""".
-spec list_tools(t()) -> {ok, [map()]} | {error, any()}.

list_tools(#{} = Conn) ->
    list_tools(Conn, #{}, []).

-doc "`call_tool/4` without `_meta` entries.".
-spec call_tool(t(), binary(), map()) -> {ok, map()} | {error, any()}.

call_tool(#{} = Conn, Name, Arguments) ->
    call_tool(Conn, Name, Arguments, #{}).

-doc """
One `tools/call`. The result is the raw `CallToolResult` map — mapping it
onto WAMP is `bondy_mcp_wamp`'s job. A non-empty `Meta` rides as the
request's `params._meta` — the SEP-414 trace-context carrier
(`bondy_mcp_wamp:trace_meta/1` builds it from a WAMP message).
""".
-spec call_tool(t(), binary(), map(), map()) -> {ok, map()} | {error, any()}.

call_tool(#{} = Conn, Name, Arguments, Meta) when
    is_binary(Name), is_map(Arguments), is_map(Meta)
->
    Params0 = #{~"name" => Name, ~"arguments" => Arguments},
    Params =
        case maps:size(Meta) of
            0 -> Params0;
            _ -> Params0#{~"_meta" => Meta}
        end,
    case request(Conn, ~"tools/call", Params) of
        {ok, Result, _} ->
            {ok, Result};
        {error, _} = Error ->
            Error
    end.

-doc """
Explicit session termination (transport §Session Management: clients
SHOULD `DELETE`). Best-effort — a server MAY answer `405`, and an
unreachable server changes nothing the owner cares about.
""".
-spec close(t()) -> ok.

close(#{session_id := undefined}) ->
    ok;
close(#{url := Url, pool := Pool} = Conn) ->
    case authenticate(Conn, Url, headers(Conn)) of
        {ok, FinalUrl, FinalHeaders} ->
            _ = send(Conn, Pool, delete, FinalUrl, FinalHeaders, <<>>),
            ok;
        {error, _} ->
            ok
    end.

%% =============================================================================
%% PRIVATE — initialization
%% =============================================================================

%% @private
connected(Conn, Result, RespHeaders) ->
    Version = maps:get(~"protocolVersion", Result, undefined),
    case lists:member(Version, ?VERSIONS) of
        true ->
            Conn1 = Conn#{
                version => Version,
                session_id => header(~"mcp-session-id", RespHeaders),
                server_info => maps:get(~"serverInfo", Result, #{})
            },
            case notify(Conn1, ~"notifications/initialized", #{}) of
                ok ->
                    {ok, Conn1};
                {error, _} = Error ->
                    Error
            end;
        false ->
            {error, {unsupported_version, Version}}
    end.

%% @private
client_version() ->
    case application:get_key(bondy_router, vsn) of
        {ok, Vsn} -> unicode:characters_to_binary(Vsn);
        undefined -> ~"unknown"
    end.

%% =============================================================================
%% PRIVATE — pagination
%% =============================================================================

%% @private
list_tools(Conn, Params, Acc0) ->
    case request(Conn, ~"tools/list", Params) of
        {ok, Result, _} ->
            Tools = maps:get(~"tools", Result, []),
            Acc = Acc0 ++ Tools,
            case maps:get(~"nextCursor", Result, undefined) of
                undefined ->
                    {ok, Acc};
                Cursor when is_binary(Cursor) ->
                    list_tools(Conn, #{~"cursor" => Cursor}, Acc)
            end;
        {error, _} = Error ->
            Error
    end.

%% =============================================================================
%% PRIVATE — request/response
%% =============================================================================

%% @private
%% One JSON-RPC request → its result. `{error, {upstream_error, ...}}`
%% carries the upstream's JSON-RPC error object.
request(Conn, Method, Params) ->
    Id = erlang:unique_integer([positive, monotonic]),
    Msg = #{
        ~"jsonrpc" => ~"2.0",
        ~"id" => Id,
        ~"method" => Method,
        ~"params" => Params
    },
    case post(Conn, Msg) of
        {ok, 200, RespHeaders, Body} ->
            handle_messages(Conn, Id, RespHeaders, Body);
        {ok, 404, _, _} when map_get(session_id, Conn) =/= undefined ->
            %% Transport §Session Management: the server terminated the
            %% session; the client MUST start a new one. That is the
            %% owner's single-flight re-initialize, not ours.
            {error, session_expired};
        {ok, Status, _, Body} ->
            {error, {upstream_status, Status, Body}};
        {error, Reason} ->
            {error, {upstream_unreachable, Reason}}
    end.

%% @private
%% One JSON-RPC notification (or client→server response). The server MUST
%% answer 202; any 2xx is taken as acceptance.
notify(Conn, Method, Params) ->
    send_message(Conn, #{
        ~"jsonrpc" => ~"2.0",
        ~"method" => Method,
        ~"params" => Params
    }).

%% @private
send_message(Conn, Msg) ->
    case post(Conn, Msg) of
        {ok, Status, _, _} when Status >= 200, Status < 300 ->
            ok;
        {ok, 404, _, _} when map_get(session_id, Conn) =/= undefined ->
            {error, session_expired};
        {ok, Status, _, Body} ->
            {error, {upstream_status, Status, Body}};
        {error, Reason} ->
            {error, {upstream_unreachable, Reason}}
    end.

%% @private
%% POST with auth applied, retrying once on a 401/403 with a fresh token
%% (the connector's own posture for an upstream auth rejection).
post(#{url := Url, pool := Pool} = Conn, Msg) ->
    Body = bondy_json_rpc:encode(Msg),
    Headers0 = [
        {~"content-type", ~"application/json"},
        {~"accept", ~"application/json, text/event-stream"}
        | headers(Conn)
    ],
    case authenticate(Conn, Url, Headers0) of
        {ok, FinalUrl, FinalHeaders} ->
            case send(Conn, Pool, post, FinalUrl, FinalHeaders, Body) of
                {ok, Status, _, _} when Status =:= 401; Status =:= 403 ->
                    invalidate(Conn),
                    case authenticate(Conn, Url, Headers0) of
                        {ok, Url2, Headers2} ->
                            send(Conn, Pool, post, Url2, Headers2, Body);
                        {error, _} = Error ->
                            Error
                    end;
                Other ->
                    Other
            end;
        {error, _} = Error ->
            Error
    end.

%% @private
send(#{timeout := Timeout}, Pool, Method, Url, Headers, Body) ->
    bondy_http_connector_http_pool:request(
        Pool, Method, Url, Headers, Body, [{recv_timeout, Timeout}]
    ).

%% @private
headers(#{version := Version, session_id := SessionId}) ->
    H0 =
        case Version of
            undefined -> [];
            _ -> [{~"mcp-protocol-version", Version}]
        end,
    case SessionId of
        undefined -> H0;
        _ -> [{~"mcp-session-id", SessionId} | H0]
    end.

%% @private
authenticate(#{auth := none}, Url, Headers) ->
    {ok, Url, Headers};
authenticate(#{auth := {Mod, Conf}, service := Service}, Url, Headers) ->
    case bondy_http_connector_token_cache:get(Service, Mod, Conf) of
        {ok, Token} ->
            {FinalUrl, FinalHeaders} =
                Mod:apply_auth(Token, Url, Headers, Conf),
            {ok, FinalUrl, FinalHeaders};
        {error, Reason} ->
            {error, {auth_error, Reason}}
    end.

%% @private
invalidate(#{auth := none}) ->
    ok;
invalidate(#{service := Service}) ->
    _ = bondy_http_connector_token_cache:invalidate(Service),
    ok.

%% =============================================================================
%% PRIVATE — response bodies
%% =============================================================================

%% @private
%% A 200 body is either one JSON message or an SSE stream of them
%% (transport §Sending Messages: the client MUST support both). Either
%% way, the caller's answer is the response message carrying `Id`;
%% in-stream server→client requests are answered post-hoc.
handle_messages(Conn, Id, RespHeaders, Body) ->
    Decoded =
        case is_event_stream(RespHeaders) of
            true -> sse_messages(Body);
            false -> decode_message(Body)
        end,
    case Decoded of
        {error, _} = Error ->
            Error;
        Messages ->
            ok = answer_server_requests(Conn, Messages),
            response(Id, Messages, RespHeaders)
    end.

%% @private
is_event_stream(Headers) ->
    case header(~"content-type", Headers) of
        undefined ->
            false;
        CT ->
            case string:lowercase(CT) of
                <<"text/event-stream", _/binary>> -> true;
                _ -> false
            end
    end.

%% @private
decode_message(Body) ->
    try
        [json:decode(Body)]
    catch
        error:Reason ->
            {error, {invalid_upstream_body, Reason}}
    end.

%% @private
%% Cuts an SSE body into events and decodes each event's `data:` payload
%% as one JSON-RPC message. `event:`/`id:`/`retry:` fields and comment
%% lines are transport framing, dropped; an event with no data lines
%% (a keepalive comment) yields nothing.
sse_messages(Body) ->
    Events = binary:split(
        Body, [~"\r\n\r\n", ~"\n\n"], [global, trim_all]
    ),
    try
        lists:filtermap(
            fun(Event) ->
                case event_data(Event) of
                    <<>> -> false;
                    Data -> {true, json:decode(Data)}
                end
            end,
            Events
        )
    catch
        error:Reason ->
            {error, {invalid_upstream_body, Reason}}
    end.

%% @private
event_data(Event) ->
    Lines = binary:split(Event, [~"\r\n", ~"\n"], [global]),
    Data = [strip_field(L) || L <- Lines, is_data_line(L)],
    iolist_to_binary(lists:join($\n, Data)).

%% @private
is_data_line(<<"data:", _/binary>>) -> true;
is_data_line(_) -> false.

%% @private
strip_field(<<"data: ", Rest/binary>>) -> Rest;
strip_field(<<"data:", Rest/binary>>) -> Rest.

%% @private
response(Id, Messages, RespHeaders) ->
    Found = [
        M
     || M <- Messages,
        maps:get(~"id", M, undefined) =:= Id,
        not is_map_key(~"method", M)
    ],
    case Found of
        [#{~"result" := Result}] ->
            {ok, Result, RespHeaders};
        [#{~"error" := Error}] ->
            {error, {upstream_error, Error}};
        [] ->
            {error, missing_response}
    end.

%% @private
%% Transport §Sending Messages: the server MAY send requests on the POST
%% stream, and a client answers every request. The pool reads full
%% bodies, so answers necessarily follow stream consumption: `ping` gets
%% its empty result, anything else `-32601`. Failures are logged — an
%% undeliverable post-hoc answer must not fail the tool call it rode
%% beside.
answer_server_requests(Conn, Messages) ->
    Requests = [
        M
     || M <- Messages,
        is_map_key(~"method", M),
        is_map_key(~"id", M)
    ],
    lists:foreach(
        fun(#{~"id" := Id} = Req) ->
            Answer =
                case maps:get(~"method", Req) of
                    ~"ping" ->
                        bondy_json_rpc:result_response(Id, #{});
                    Method ->
                        bondy_json_rpc:error_response(
                            Id, -32601, ~"Method not found", Method
                        )
                end,
            case send_message(Conn, Answer) of
                ok ->
                    ok;
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        description =>
                            "Failed to answer an upstream MCP "
                            "server-to-client request",
                        reason => Reason,
                        method => maps:get(~"method", Req)
                    })
            end
        end,
        Requests
    ).

%% @private
%% Case-insensitive response-header lookup (hackney preserves wire
%% casing).
header(Name, Headers) ->
    case
        lists:search(
            fun({K, _}) -> string:lowercase(K) =:= Name end,
            Headers
        )
    of
        {value, {_, V}} -> V;
        false -> undefined
    end.
