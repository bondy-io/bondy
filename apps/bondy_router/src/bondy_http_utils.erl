%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_utils).
-moduledoc """
Utility functions for HTTP request handling, including setting meta and
security response headers, parsing the `Authorization` header, classifying
IP addresses as public or private, and mapping error URIs onto HTTP status
codes.

`http_status/1` is the single source of truth for the error URI to HTTP status
mapping. Two divergent copies of this table used to exist - one in the REST
handler and one supplying the API Gateway spec defaults - and they disagreed on
`wamp.error.not_authorized` and `wamp.error.authorization_failed`.
""".
-include_lib("partisan/include/partisan_util.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").
-include("http_api.hrl").

-export([set_meta_headers/1]).
-export([set_all_headers/1]).
-export([meta_headers/0]).
-export([parse_authorization/1]).
-export([is_public_ip/1]).

%% COOKIES
-export([csrf_cookie_name/1]).
-export([find_ticket_cookie/1]).
-export([find_ticket_cookie/2]).
-export([safe_bearer_token/1]).
-export([safe_parse_cookies/1]).
-export([ticket_cookie_name/1]).
-export([ticket_cookie_realm/1]).
-export([validate_csrf/1]).

%% ERROR STATUS MAPPING
-export([default_status_codes/0]).
-export([http_status/1]).

-on_load(on_load/0).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Returns the HTTP status code for an error.

Accepts a `bondy_error:t()`, an error URI or an error type. A URI with no
explicit mapping is treated as a server-side condition, i.e. 500.
""".
-spec http_status(bondy_error:t() | binary() | atom()) -> pos_integer().

http_status(#{uri := Uri}) ->
    status_of(Uri);

http_status(Uri) when is_binary(Uri) ->
    status_of(Uri);

http_status(Type) when is_atom(Type) ->
    status_of(bondy_error:uri(Type)).

-doc """
Returns the default error URI to HTTP status map used by the API Gateway.

An API specification may override any entry through its `status_codes` key, so
this is a starting point rather than a policy.
""".
-spec default_status_codes() -> #{binary() => pos_integer()}.

default_status_codes() ->
    maps:from_list([
        {bondy_error:uri(Type), http_status(Type)}
     || Type <- bondy_error:types()
    ]).

-spec set_meta_headers(Req :: cowboy_req:req()) ->
    NewReq :: cowboy_req:req().

set_meta_headers(Req) ->
    cowboy_req:set_resp_headers(meta_headers(), Req).

-doc """
Sets both meta headers and per-listener security headers on the
Cowboy request. Security headers are cached in persistent_term by
`bondy_http_security_headers` and include HSTS, X-Frame-Options,
X-Content-Type-Options, Content-Security-Policy, and the Server header.
""".
-spec set_all_headers(cowboy_req:req()) -> cowboy_req:req().

set_all_headers(Req) ->
    SecurityHeaders = bondy_http_security_headers:headers_from_req(Req),
    %% Security headers include the server header (when configured), so they
    %% are applied after meta_headers to allow per-listener overrides.
    Req1 = cowboy_req:set_resp_headers(meta_headers(), Req),
    cowboy_req:set_resp_headers(SecurityHeaders, Req1).

-spec meta_headers() -> map().

meta_headers() ->
    persistent_term:get({?MODULE, meta_headers}).

-spec parse_authorization(Req :: cowboy_req:req()) ->
    {basic, binary(), binary()}
    | {bearer, binary()}
    | {digest, [{binary(), binary()}]}.

parse_authorization(Req) ->
    %% The authorization header has the based64 encoding of the
    %% string username ++ ":" ++ password.
    %% We allow Usernames with colons (as opposed to the HTTP Basic RFC
    %% standard) but we do not allow colons in passwords.
    %% cowboy_req:parse_header/2 follows the RFC standard, so we need
    %% to make sure to split the username and password correctly
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, A, B} = Basic ->
            case binary:matches(B, <<$:>>) of
                [] ->
                    %% No additional colons
                    Basic;
                L ->
                    %% We found at least one colon, the last one is the
                    %% separator between username and password
                    {Pos, 1} = lists:last(L),
                    Rest = binary_part(B, 0, Pos),
                    Username = <<A/binary, $:, Rest/binary>>,
                    Password = binary_part(B, Pos + 1, byte_size(B) - Pos - 1),
                    {basic, Username, Password}
            end;
        Other ->
            Other
    end.

-doc """
Returns the name of the cookie holding the Bondy ticket issued for `RealmUri`.

The ticket cookie value is a signed Bondy ticket (a JWT), not a session
identifier. See `bondy_oidc_handler`, which sets it at the end of the OIDC
authorization code flow.
""".
-spec ticket_cookie_name(RealmUri :: binary()) -> binary().

ticket_cookie_name(RealmUri) when is_binary(RealmUri) ->
    <<?TICKET_COOKIE_PREFIX/binary, RealmUri/binary>>.

-doc """
Returns the name of the CSRF cookie issued for `RealmUri`.
""".
-spec csrf_cookie_name(RealmUri :: binary()) -> binary().

csrf_cookie_name(RealmUri) when is_binary(RealmUri) ->
    <<?CSRF_COOKIE_PREFIX/binary, RealmUri/binary>>.

-doc """
Returns the first cookie whose name carries the Bondy ticket prefix.

Use this when the realm is not known up front. When it is, prefer
`find_ticket_cookie/2`, which pins the exact cookie before falling back to
this scan.
""".
-spec find_ticket_cookie(Cookies :: [{binary(), binary()}]) ->
    {value, {Name :: binary(), Value :: binary()}} | false.

find_ticket_cookie(Cookies) ->
    PrefixLen = byte_size(?TICKET_COOKIE_PREFIX),
    lists:search(
        fun({Name, _}) ->
            byte_size(Name) > PrefixLen andalso
                binary:part(Name, 0, PrefixLen) =:= ?TICKET_COOKIE_PREFIX
        end,
        Cookies
    ).

-doc """
Returns the ticket cookie for `RealmUri`, or any Bondy ticket cookie.

The exact name is tried first. The fallback matters when the ticket was issued
by an SSO realm, in which case the cookie is named after the issuing realm
rather than the realm being accessed; the caller is still responsible for
checking that the issuer is trusted by the target realm, via
`bondy_realm:is_trusted_issuer/2`.
""".
-spec find_ticket_cookie(
    RealmUri :: binary(), Cookies :: [{binary(), binary()}]
) ->
    {value, {Name :: binary(), Value :: binary()}} | false.

find_ticket_cookie(RealmUri, Cookies) when is_binary(RealmUri) ->
    case lists:keyfind(ticket_cookie_name(RealmUri), 1, Cookies) of
        false ->
            find_ticket_cookie(Cookies);
        Entry ->
            {value, Entry}
    end.

-doc """
Returns the realm a ticket cookie was issued for, given the cookie's name.

The inverse of `ticket_cookie_name/1`.
""".
-spec ticket_cookie_realm(Name :: binary()) -> binary().

ticket_cookie_realm(Name) when is_binary(Name) ->
    PrefixLen = byte_size(?TICKET_COOKIE_PREFIX),
    binary:part(Name, PrefixLen, byte_size(Name) - PrefixLen).

-doc """
Validates the double-submit CSRF token of a cookie-authenticated request.

Returns `ok` when the request carries no Bondy ticket cookie, since a request
that does not rely on ambient cookie authority has nothing to protect. When a
ticket cookie is present, the `x-csrf-token` header must match the value of the
matching CSRF cookie. See `bondy_oidc_handler`, which issues the pair.
""".
-spec validate_csrf(Req :: cowboy_req:req()) -> ok | {error, forbidden}.

validate_csrf(Req) ->
    Cookies = safe_parse_cookies(Req),

    case find_ticket_cookie(Cookies) of
        false ->
            %% No ticket cookie — non-OIDC flow, skip CSRF
            ok;

        {value, {Name, _}} ->
            CsrfName = csrf_cookie_name(ticket_cookie_realm(Name)),
            CsrfHeader = cowboy_req:header(<<"x-csrf-token">>, Req, undefined),
            CsrfCookie =
                case lists:keyfind(CsrfName, 1, Cookies) of
                    {_, V} -> V;
                    false -> undefined
                end,

            case
                is_binary(CsrfHeader) andalso is_binary(CsrfCookie) andalso
                    CsrfHeader =:= CsrfCookie
            of
                true -> ok;
                false -> {error, forbidden}
            end
    end.

-doc """
Parses the request cookies, returning `[]` when the header is malformed.

`cowboy_req:parse_cookies/1` raises on input as trivial as `Cookie: =x`, and
`cowboy_req:parse_header/4` does not guard the parser. On an endpoint reachable
before authentication that turns any unauthenticated request into a 500 plus a
crash report, so callers there must use this instead.
""".
-spec safe_parse_cookies(Req :: cowboy_req:req()) -> [{binary(), binary()}].

safe_parse_cookies(Req) ->
    try
        cowboy_req:parse_cookies(Req)
    catch
        _:_ ->
            []
    end.

-doc """
Returns the bearer token of the `Authorization` header, or `undefined`.

`undefined` covers an absent header, a malformed one, and any scheme other than
`Bearer`. As with `safe_parse_cookies/1`, the underlying parser raises on
malformed input, e.g. a bare `Authorization: Bearer`.
""".
-spec safe_bearer_token(Req :: cowboy_req:req()) -> binary() | undefined.

safe_bearer_token(Req) ->
    try cowboy_req:parse_header(<<"authorization">>, Req) of
        {bearer, Token} when is_binary(Token), Token =/= <<>> ->
            Token;
        _ ->
            undefined
    catch
        _:_ ->
            undefined
    end.

-doc """
Returns true if the argument is a valid public IP address.

Private IPv4 fall in the ranges (10.0.0.0/8, 172.16.0.0/12, and
192.168.0.0/16).
Private IPv6 addresses generally include Unique Local Addresses (ULA) which
fall in the range fc00::/7, fd00::/7, and Link-Local addresses, which fall in
the range fe80::/10.
""".
is_public_ip({A, B, _, _}) when
    A == 10;
    A == 172 andalso B >= 16 andalso B =< 31;
    A == 192 andalso B == 168
->
    % IP is private
    false;
is_public_ip({A, _, _, _, _, _, _, _}) when
    A == 65152 orelse A == 65153 orelse A == 65154
->
    %% 65152 -> fc00::/7 (ULA)
    %% 65153 -> fd00::/7 (part of ULA)
    %% 65154 -> fe80::/10. Link local
    false;
is_public_ip(IPAddr) when ?IS_IP(IPAddr) ->
    % IP is valid and public
    true;
is_public_ip(undefined) ->
    % IP is invalid
    false.

%% =============================================================================
%% PRIVATE
%% =============================================================================

on_load() ->
    Meta = #{
        <<"server">> => "bondy/" ++ bondy_config:get(vsn, "undefined")
    },
    ok = persistent_term:put({?MODULE, meta_headers}, Meta),
    ok.

%% -----------------------------------------------------------------------------
%% Error URI to HTTP status
%%
%% Keyed by error URI, which is an error's normative identity. Where the WAMP
%% specification gives a URI a meaning, the status follows that meaning:
%% `not_authorized' is the peer being refused (403), whereas
%% `authorization_failed' is the router being unable to decide (500).
%% -----------------------------------------------------------------------------

%% @private
status_of(?WAMP_NOT_AUTHORIZED) -> ?HTTP_FORBIDDEN;
status_of(?WAMP_AUTHORIZATION_FAILED) -> ?HTTP_INTERNAL_SERVER_ERROR;
status_of(?WAMP_AUTHENTICATION_FAILED) -> ?HTTP_UNAUTHORIZED;
status_of(?WAMP_NOT_AUTH_METHOD) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_NO_SUCH_PRINCIPAL) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_NO_SUCH_ROLE) -> ?HTTP_BAD_REQUEST;

status_of(?WAMP_INVALID_ARGUMENT) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_INVALID_URI) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_INVALID_PAYLOAD) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_PROTOCOL_VIOLATION) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_CANCELLED) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_OPTION_NOT_ALLOWED) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_OPTION_DISALLOWED_DISCLOSE_ME) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_DISCLOSE_ME_NOT_ALLOWED) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_PROCEDURE_ALREADY_EXISTS) -> ?HTTP_BAD_REQUEST;
status_of(?WAMP_PAYLOAD_SIZE_EXCEEDED) -> ?HTTP_PAYLOAD_TOO_LARGE;

status_of(?WAMP_NO_SUCH_PROCEDURE) -> ?HTTP_NOT_IMPLEMENTED;
status_of(?WAMP_FEATURE_NOT_SUPPORTED) -> ?HTTP_NOT_IMPLEMENTED;

status_of(?WAMP_NO_SUCH_REALM) -> ?HTTP_BAD_GATEWAY;
status_of(?WAMP_NO_SUCH_REGISTRATION) -> ?HTTP_BAD_GATEWAY;
status_of(?WAMP_NO_SUCH_SUBSCRIPTION) -> ?HTTP_BAD_GATEWAY;
status_of(?WAMP_NO_ELIGIBLE_CALLE) -> ?HTTP_BAD_GATEWAY;
status_of(?WAMP_NO_AVAILABLE_CALLEE) -> ?HTTP_BAD_GATEWAY;
status_of(?WAMP_NET_FAILURE) -> ?HTTP_BAD_GATEWAY;

status_of(?WAMP_UNAVAILABLE) -> ?HTTP_SERVICE_UNAVAILABLE;
status_of(?WAMP_ERROR_TIMEOUT) -> ?HTTP_GATEWAY_TIMEOUT;

status_of(?WAMP_NO_SUCH_SESSION) -> ?HTTP_INTERNAL_SERVER_ERROR;
status_of(?WAMP_SYSTEM_SHUTDOWN) -> ?HTTP_INTERNAL_SERVER_ERROR;
status_of(?WAMP_CLOSE_REALM) -> ?HTTP_INTERNAL_SERVER_ERROR;
status_of(?WAMP_GOODBYE_AND_OUT) -> ?HTTP_INTERNAL_SERVER_ERROR;

status_of(?BONDY_ERROR_NOT_FOUND) -> ?HTTP_NOT_FOUND;
status_of(?BONDY_ERROR_ALREADY_EXISTS) -> ?HTTP_BAD_REQUEST;
status_of(?BONDY_ERROR_TIMEOUT) -> ?HTTP_GATEWAY_TIMEOUT;
status_of(?BONDY_ERROR_BAD_GATEWAY) -> ?HTTP_SERVICE_UNAVAILABLE;
status_of(?BONDY_ERROR_TOO_MANY_REQUESTS) -> ?HTTP_TOO_MANY_REQUESTS;
status_of(?BONDY_ERROR_NOT_IN_SESSION) -> ?HTTP_BAD_REQUEST;
status_of(?BONDY_ERROR_INCONSISTENCY_ERROR) -> ?HTTP_BAD_REQUEST;
status_of(?BONDY_ERROR_HTTP_API_GATEWAY_INVALID_EXPR) ->
    ?HTTP_INTERNAL_SERVER_ERROR;

status_of(~"bondy.error.bad_request") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.invalid_request") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.invalid_value") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.missing_required_value") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.property_range_limit") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.invalid_data") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.body_max_bytes_exceeded") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.too_many_results") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.deprecated_procedure") -> ?HTTP_GONE;
status_of(~"bondy.error.conflict") -> ?HTTP_CONFLICT;
status_of(~"bondy.error.method_not_allowed") -> ?HTTP_METHOD_NOT_ALLOWED;
status_of(~"bondy.error.request_timeout") -> ?HTTP_REQUEST_TIMEOUT;
status_of(~"bondy.error.too_large_payload") -> ?HTTP_PAYLOAD_TOO_LARGE;

status_of(~"bondy.error.invalid_credentials") -> ?HTTP_UNAUTHORIZED;
status_of(~"bondy.error.token_expired") -> ?HTTP_UNAUTHORIZED;
status_of(~"bondy.error.token_invalid") -> ?HTTP_UNAUTHORIZED;
status_of(~"bondy.error.invalid_client") -> ?HTTP_UNAUTHORIZED;

status_of(~"bondy.error.forbidden") -> ?HTTP_FORBIDDEN;
status_of(~"bondy.error.insufficient_permissions") -> ?HTTP_FORBIDDEN;
status_of(~"bondy.error.role_not_allowed") -> ?HTTP_FORBIDDEN;
status_of(~"bondy.error.proxy_protocol_error") -> ?HTTP_FORBIDDEN;

status_of(~"bondy.error.invalid_grant") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.unauthorized_client") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.unsupported_grant_type") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.invalid_scope") -> ?HTTP_BAD_REQUEST;
status_of(~"bondy.error.unsupported_token_type") -> ?HTTP_SERVICE_UNAVAILABLE;

status_of(~"bondy.error.rate_limit_exceeded") -> ?HTTP_TOO_MANY_REQUESTS;
status_of(~"bondy.error.quota_exceeded") -> ?HTTP_TOO_MANY_REQUESTS;
status_of(~"bondy.error.too_many_sessions") -> ?HTTP_TOO_MANY_REQUESTS;
status_of(~"bondy.error.too_many_connections") -> ?HTTP_SERVICE_UNAVAILABLE;

status_of(~"bondy.error.unavailable") -> ?HTTP_SERVICE_UNAVAILABLE;
status_of(~"bondy.error.temporarily_unavailable") -> ?HTTP_SERVICE_UNAVAILABLE;
status_of(~"bondy.error.gateway_timeout") -> ?HTTP_GATEWAY_TIMEOUT;
status_of(~"bondy.error.node_down") -> ?HTTP_SERVICE_UNAVAILABLE;
status_of(~"bondy.error.cluster_not_formed") -> ?HTTP_SERVICE_UNAVAILABLE;
status_of(~"bondy.error.partition_detected") -> ?HTTP_SERVICE_UNAVAILABLE;
status_of(~"bondy.error.insufficient_resources") -> ?HTTP_SERVICE_UNAVAILABLE;

status_of(_) ->
    ?HTTP_INTERNAL_SERVER_ERROR.
