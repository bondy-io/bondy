%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_http_headers).

-moduledoc """
The MCP request-header contract: `Origin`, `MCP-Protocol-Version`, the
`Mcp-Method` / `Mcp-Name` pair (§10.1) and the `Mcp-Param-{Name}` family
(x-mcp-header), plus the protocol-revision sets those are checked against.

Split out of `bondy_mcp_http_handler`. MCP-D01 keeps ONE handler for both
eras because the era is a per-request property and a router-level split
could not see the request body — but that argument is about the dispatcher,
not about every layer beneath it. Nothing here is era-specific: the same
`Origin` rule, the same header-versus-body agreement and the same
revision sets serve both, which is exactly why they can move without
touching the version decision. The protocol-revision macros moved with
them and are now referenced nowhere else.

Every check either returns `ok` or THROWS `{reply, Status, Body, Req}` —
the same protocol `bondy_mcp_http_handler` catches around its pipeline —
so a caller reads as a straight sequence of assertions.
""".

-include_lib("bondy_json_rpc/include/bondy_json_rpc.hrl").

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

-export([check_origin/2]).
-export([check_param_headers/4]).
-export([check_standard_headers/4]).
-export([check_version/4]).
-export([handshake_versions/1]).
-export([sanitize_version/1]).
-export([supported_versions/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Checks the request's `Origin` against the listener's `allowed_origins`.

Returns `ok`, or throws a `403` reply when the header is present and matches
no rule. Origins compare case-insensitively, and the `local` rule admits the
transport specification's localhost set — `localhost`, `127.0.0.1` and `::1` —
on any scheme and port.

A request carrying NO `Origin` is always served. Only browsers send the
header, and the browser is the DNS-rebinding vector this check exists for; a
non-browser client can forge any header, so refusing the absent case would
break every SDK client while stopping no attacker. A present-but-unparseable
value matches no rule and is refused: explicit garbage fails closed.
""".
-spec check_origin(Req :: cowboy_req:req(), Config :: map()) -> ok.

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

-doc """
Checks the modern era's protocol-version contract.

`MCP-Protocol-Version` is required and must equal the body's
`_meta."io.modelcontextprotocol/protocolVersion"`; a disagreement throws a
`400` carrying `-32020 HeaderMismatch`. A version this endpoint does not carry
throws a `400` carrying `-32022`, whose payload names both the `supported` set
and the `requested` value so a client can renegotiate without guessing.

Returns `ok` when both hold.
""".
-spec check_version(
    Req :: cowboy_req:req(), Id :: term(), Params :: map(), St :: map()
) -> ok.

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

-doc """
Reduces a client-supplied protocol version to a value safe to use as a metric
label: the revision itself when Bondy carries it, `other` otherwise.

The version is client-controlled, so an unbounded label would let a caller
mint Prometheus series by cycling version strings.
""".
-spec sanitize_version(binary() | undefined) -> binary().

sanitize_version(V) ->
    case lists:member(V, ?MODERN_VERSIONS ++ ?HANDSHAKE_VERSIONS) of
        true -> V;
        false -> <<"other">>
    end.

-doc """
The endpoint's effective MODERN-era revisions: the intersection of this
implementation's modern set with the listener's configured
`protocol_versions`.
""".
-spec supported_versions(Config :: map()) -> [binary()].

supported_versions(Config) ->
    [
        V
     || V <- maps:get(protocol_versions, Config),
        lists:member(V, ?MODERN_VERSIONS)
    ].

-doc """
The endpoint's effective HANDSHAKE-era revisions, latest first — the order
`initialize` negotiates from. Empty when the listener carries no handshake
revision, which is what makes an endpoint modern-only.
""".
-spec handshake_versions(Config :: map()) -> [binary()].

handshake_versions(Config) ->
    Configured = maps:get(protocol_versions, Config),
    [V || V <- ?HANDSHAKE_VERSIONS, lists:member(V, Configured)].

-doc """
Checks the `Mcp-Method` and `Mcp-Name` headers against the request body.

`Mcp-Method` is required on every request. `Mcp-Name` is required on the
methods that carry a name or a URI in `params` — `tools/call`, `prompts/get`
and `resources/read` — and its Base64 sentinel form is decoded before
comparison. A disagreement throws a `400` carrying `-32020`.

Returns `ok`. A request whose body simply LACKS the named field is not a
header problem and is left to dispatch, which answers `-32602`.
""".
-spec check_standard_headers(
    Req :: cowboy_req:req(), Id :: term(), Method :: binary(), Params :: map()
) -> ok.

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
%% API — Mcp-Param-{Name} headers (x-mcp-header)
%% =============================================================================

-doc """
Checks the `Mcp-Param-{Name}` headers a manifest entry demands.

For every `inputSchema` property annotated `x-mcp-header` whose value appears
in `arguments`, the matching `Mcp-Param-{Name}` header must be present and,
after sentinel decoding, equal that value's string form. A header naming a
value the request does NOT carry must itself be absent. Either mismatch throws
a `400` carrying `-32020`.

Returns `ok`. The caller runs this only after the entry has passed the
visibility check, so a hidden tool's schema leaks nothing.
""".
-spec check_param_headers(
    Req :: cowboy_req:req(),
    Id :: term(),
    Entry :: map(),
    Arguments :: map()
) -> ok.

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
