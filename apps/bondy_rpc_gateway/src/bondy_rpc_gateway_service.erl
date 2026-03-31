%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_service).

-moduledoc """
Generic authenticated reverse proxy.

Takes a service configuration map that specifies the auth module,
target base URL, path prefix to strip, and operational params.
Tokens are fetched via the token cache so concurrent requests share
a single token, and 401/403 responses trigger automatic invalidation
and one retry with a fresh token.

## Service config shape

```erlang
#{
    name       => binary(),           %% for logging / cache key
    base_url   => binary(),           %% target service
    prefix     => binary(),           %% path prefix to strip, e.g. <<"/gis">>
    auth_mod   => module(),           %% bondy_rpc_gateway_auth_proxy implementation
    auth_conf  => map(),              %% passed to auth_mod + cache config
    timeout    => pos_integer(),      %% ms, default 30000
    retries    => non_neg_integer()   %% default 3
}
```

## Request flow

```
handle_request(Event, Conf)
  │
  ├─ acquire_token  ── token_cache:get_token ── cached? ── yes ──► Token
  │                                             │
  │                                             no
  │                                             │
  │                                         fetch_token
  │                                             │
  ├─ forward(Event, Token, Conf)
  │    │
  │    ├─ validate + build URL
  │    ├─ apply_auth(Token, ...)
  │    ├─ HTTP request
  │    │
  │    ├─ 401/403? ── invalidate ── get_token (fresh) ── retry once
  │    │
  │    └─ other status ── process_response
  │
  └─ catch errors ── error response
```

## Example

```erlang
Conf = #{
    name     => <<"billing">>,
    base_url => <<"https://billing.example.com/api">>,
    prefix   => <<"/billing">>,
    auth_mod => bondy_rpc_gateway_auth_generic,
    auth_conf => #{
        fetch => #{
            method     => post,
            url        => <<"https://idp.example.com/token">>,
            body_encoding => form,
            body       => #{<<"grant_type">> => <<"client_credentials">>},
            token_path => [<<"access_token">>]
        },
        apply => #{
            placement => header,
            name      => <<"Authorization">>,
            format    => <<"Bearer {{token}}">>
        }
    },
    timeout => 15000,
    retries => 2
},
Response = bondy_rpc_gateway_service:handle_request(Event, Conf).
```
""".

%% Public API
-export([handle_request/2]).
-export([create_error_response/2]).

%% Exported for testing
-export([validate_url/1]).
-export([validate_request_body/1]).
-export([normalize_pagination_params/1]).
-export([construct_url/2]).
-export([build_url/2]).

-include_lib("kernel/include/logger.hrl").

%% -------------------------------------------------------------------
%% Constants
%% -------------------------------------------------------------------

-define(DEFAULT_TIMEOUT, 30000).
-define(MAX_BODY_SIZE,   10485760).  %% 10 MB
-define(DEFAULT_PAGE_SIZE, 100).
-define(DEFAULT_RETRIES, 3).
-define(RETRY_BACKOFF_MS, 300).
-define(BYTES_TO_KB,     1024).

%% -------------------------------------------------------------------
%% Types
%% -------------------------------------------------------------------

-type event()    :: map().
-type response() :: #{binary() => term()}.
-type svc_conf() :: map().

%% ===================================================================
%% Main entry point
%% ===================================================================

-doc """
Handle an incoming proxy request for the given service.

Acquires a token via the cache, forwards the request to the upstream
service, and returns a response map. On 401/403 from upstream the
token is invalidated and the request is retried once with a fresh token.

## Examples

```erlang
Event = #{
    <<"path">>       => <<"/billing/invoices">>,
    <<"httpMethod">>  => <<"GET">>,
    <<"headers">>     => #{},
    <<"queryStringParameters">> => #{}
},
#{<<"statusCode">> := 200, <<"body">> := Body} =
    bondy_rpc_gateway_service:handle_request(Event, Conf).
```
""".
-spec handle_request(event(), svc_conf()) -> response().
handle_request(Event, Conf) ->
    #{name := Name, auth_mod := AuthMod, auth_conf := AuthConf} = Conf,
    ?LOG_INFO(#{msg => <<"Handling proxy request">>, service => Name}),
    try
        Token = acquire_token(Name, AuthMod, AuthConf),
        forward(Event, Token, Conf)
    catch
        throw:{auth_error, Reason} ->
            ?LOG_ERROR(#{msg => <<"Auth failed">>,
                         service => Name, reason => Reason}),
            create_error_response(503, <<"Authentication unavailable">>);
        throw:{validation_error, Reason} ->
            ?LOG_ERROR(#{msg => <<"Validation failed">>,
                         service => Name, reason => Reason}),
            create_error_response(400, ensure_binary(Reason));
        throw:{forwarding_error, Reason} ->
            ?LOG_ERROR(#{msg => <<"Forwarding failed">>,
                         service => Name, reason => Reason}),
            create_error_response(502, <<"Service temporarily unavailable">>);
        Class:Reason:Stack ->
            ?LOG_ERROR(#{msg => <<"Unexpected error">>, service => Name,
                         class => Class, reason => Reason, stacktrace => Stack}),
            create_error_response(500, <<"Internal server error">>)
    end.

%% ===================================================================
%% Token acquisition (delegates to auth module)
%% ===================================================================

acquire_token(Name, AuthMod, AuthConf) ->
    case bondy_rpc_gateway_token_cache:get(Name, AuthMod, AuthConf) of
        {ok, Token} ->
            Token;
        {error, Reason} ->
            throw({auth_error, Reason})
    end.

%% ===================================================================
%% Request forwarding
%% ===================================================================

forward(Event, Token,
        #{name := Name, auth_mod := AuthMod, auth_conf := AuthConf} = Conf) ->
    {Endpoint, Body, Method, ContentType} = validate_request(Event, Conf),

    QP0 = maps:get(<<"queryStringParameters">>, Event, #{}),
    QueryParams = normalize_pagination_params(QP0),

    %% Build URL without auth, then let the auth module apply it
    Url = build_url(Endpoint, QueryParams),
    BaseHeaders = [
        {<<"Content-Type">>, ContentType},
        {<<"Accept">>,       <<"application/json">>}
    ],
    {FinalUrl, FinalHeaders} = AuthMod:apply_auth(Token, Url, BaseHeaders, AuthConf),

    ?LOG_INFO(#{msg => <<"Forwarding">>, method => Method, url => FinalUrl}),

    IsGet = Method =:= <<"GET">> orelse Method =:= <<"get">>,
    FwdBody = case IsGet of
        true  -> <<>>;
        false -> ensure_binary(Body)
    end,

    Retries = maps:get(retries, Conf, ?DEFAULT_RETRIES),
    Timeout = maps:get(timeout, Conf, ?DEFAULT_TIMEOUT),
    TlsVerify = maps:get(tls_verify, Conf, verify_peer),
    Pool = pool_name(Name),

    case request_with_retry(
            method_atom(Method), FinalUrl, FinalHeaders, FwdBody,
            Retries, Timeout, Pool, TlsVerify) of
        {ok, Status, _RH, _RespBody} when Status =:= 401; Status =:= 403 ->
            ?LOG_WARNING(#{
                msg => <<"Got auth rejection, retrying with fresh token">>,
                service => Name, status => Status
            }),
            retry_with_fresh_token(
                Name, AuthMod, AuthConf, Url, BaseHeaders,
                method_atom(Method), FwdBody, Retries, Timeout, Pool,
                TlsVerify
            );
        {ok, Status, _RH, RespBody} ->
            process_response(Status, RespBody);
        {error, Reason} ->
            throw({forwarding_error, Reason})
    end.

retry_with_fresh_token(
        Name, AuthMod, AuthConf, Url, BaseHeaders,
        MethodAtom, FwdBody, Retries, Timeout, Pool, TlsVerify) ->
    bondy_rpc_gateway_token_cache:invalidate(Name),
    case bondy_rpc_gateway_token_cache:get(Name, AuthMod, AuthConf) of
        {ok, NewToken} ->
            {RetryUrl, RetryHeaders} =
                AuthMod:apply_auth(NewToken, Url, BaseHeaders, AuthConf),
            case request_with_retry(
                    MethodAtom, RetryUrl, RetryHeaders, FwdBody,
                    Retries, Timeout, Pool, TlsVerify) of
                {ok, Status2, _RH2, RespBody2} ->
                    process_response(Status2, RespBody2);
                {error, Reason} ->
                    throw({forwarding_error, Reason})
            end;
        {error, Reason} ->
            throw({auth_error, Reason})
    end.

%% ===================================================================
%% Request validation
%% ===================================================================

validate_request(Event, #{base_url := BaseUrl, prefix := Prefix}) ->
    Path0 = case maps:find(<<"path">>, Event) of
        {ok, P} when is_binary(P), byte_size(P) > 0 -> P;
        _ -> maps:get(<<"rawPath">>, Event, <<"/">>)
    end,

    case Path0 of
        <<"/">> -> throw({validation_error, <<"Invalid request path">>});
        <<>>    -> throw({validation_error, <<"Invalid request path">>});
        _       -> ok
    end,

    Path     = strip_prefix(Path0, Prefix),
    Endpoint = construct_url(BaseUrl, Path),

    Body = maps:get(<<"body">>, Event, undefined),
    case validate_request_body(Body) of
        false -> throw({validation_error, <<"Request body exceeds maximum size">>});
        true  -> ok
    end,

    Method      = maps:get(<<"httpMethod">>, Event, <<"GET">>),
    Headers     = maps:get(<<"headers">>, Event, #{}),
    ContentType = maps:get(<<"content-type">>, Headers, <<"application/json">>),

    {Endpoint, Body, Method, ContentType}.

%% ===================================================================
%% URL helpers
%% ===================================================================

-spec construct_url(binary(), binary()) -> binary().
construct_url(BaseUrl, RequestPath) ->
    Base = strip_trailing_slash(BaseUrl),
    Path = case RequestPath of
        <<"/", _/binary>> -> RequestPath;
        _                 -> <<"/", RequestPath/binary>>
    end,
    <<Base/binary, Path/binary>>.

-spec build_url(binary(), map() | undefined) -> binary().
build_url(Endpoint, QueryParams) ->
    case query_to_list(QueryParams) of
        [] ->
            Endpoint;
        Params ->
            QS = uri_string:compose_query(Params),
            <<Endpoint/binary, "?", QS/binary>>
    end.

%% ===================================================================
%% Pagination normalization
%% ===================================================================

-spec normalize_pagination_params(map() | undefined) -> map() | undefined.
normalize_pagination_params(undefined) ->
    undefined;
normalize_pagination_params(Params) when map_size(Params) =:= 0 ->
    Params;
normalize_pagination_params(Params) ->
    Norm = maps:filter(
        fun(_, V) -> V =/= undefined andalso V =/= null end,
        Params
    ),

    Page         = parse_int(maps:get(<<"page">>,         Norm, undefined)),
    Size         = parse_int(maps:get(<<"size">>,         Norm, undefined)),
    ResultOffset = parse_int(maps:get(<<"resultOffset">>, Norm, undefined)),
    Limit0       = parse_int(maps:get(<<"limit">>,        Norm, undefined)),
    Offset0      = parse_int(maps:get(<<"offset">>,       Norm, undefined)),

    Limit1 = case Limit0 of
        undefined when Size =/= undefined -> Size;
        undefined when Page =/= undefined -> ?DEFAULT_PAGE_SIZE;
        _                                 -> Limit0
    end,
    Limit = case Limit1 of
        L when is_integer(L), L < 1 -> 1;
        L                           -> L
    end,

    Offset = case Offset0 of
        undefined when ResultOffset =/= undefined ->
            ResultOffset;
        undefined when Page =/= undefined ->
            EffPage  = case Page > 0 of true -> Page; false -> 1 end,
            EffLimit = case Limit of undefined -> ?DEFAULT_PAGE_SIZE; _ -> Limit end,
            (EffPage - 1) * EffLimit;
        _ ->
            Offset0
    end,

    N1 = maybe_put(<<"limit">>,  Limit,  Norm),
    maybe_put(<<"offset">>, Offset, N1).

%% ===================================================================
%% Response processing
%% ===================================================================

process_response(StatusCode, RespData0) ->
    RespData = case RespData0 of <<>> -> <<"{}">>;  _ -> RespData0 end,
    SizeKb = byte_size(RespData) / ?BYTES_TO_KB,
    ?LOG_INFO(#{msg => <<"Response received">>,
                status => StatusCode, size_kb => SizeKb}),
    #{
        <<"statusCode">>      => StatusCode,
        <<"headers">>         => #{<<"Content-Type">> => <<"application/json">>},
        <<"body">>            => RespData,
        <<"isBase64Encoded">> => false
    }.

-doc """
Build a JSON error response map.

## Examples

```erlang
#{<<"statusCode">> := 400, <<"body">> := Body} =
    bondy_rpc_gateway_service:create_error_response(400, <<"Bad input">>).
```
""".
-spec create_error_response(integer(), binary()) -> response().
create_error_response(StatusCode, ErrorMessage) ->
    #{
        <<"statusCode">>      => StatusCode,
        <<"headers">>         => #{<<"Content-Type">> => <<"application/json">>},
        <<"body">>            => iolist_to_binary(json:encode(#{<<"error">> => ErrorMessage})),
        <<"isBase64Encoded">> => false
    }.

%% ===================================================================
%% Validation helpers
%% ===================================================================

-spec validate_url(binary()) -> boolean().
validate_url(Url) when is_binary(Url) ->
    case uri_string:parse(Url) of
        #{scheme := S, host := H}
          when byte_size(S) > 0, byte_size(H) > 0 -> true;
        _ -> false
    end;
validate_url(_) ->
    false.

-spec validate_request_body(binary() | undefined) -> boolean().
validate_request_body(undefined) -> true;
validate_request_body(<<>>)      -> true;
validate_request_body(Body) when is_binary(Body) ->
    byte_size(Body) =< ?MAX_BODY_SIZE;
validate_request_body(Body) when is_list(Body) ->
    iolist_size(Body) =< ?MAX_BODY_SIZE.

%% ===================================================================
%% Internal helpers
%% ===================================================================

hackney_opts(Timeout, Pool, TlsVerify) ->
    SslOpts = case TlsVerify of
        verify_none -> bondy_cert_manager:ssl_opts(#{verify => verify_none});
        _ -> bondy_cert_manager:ssl_opts()
    end,
    [
        {connect_timeout, Timeout},
        {recv_timeout, Timeout},
        {ssl_options, SslOpts},
        {pool, Pool},
        with_body
    ].

request_with_retry(Method, Url, Headers, Body, RetriesLeft, Timeout, Pool, TlsVerify) ->
    case hackney:request(Method, Url, Headers, Body, hackney_opts(Timeout, Pool, TlsVerify)) of
        {ok, S, RH, RB} ->
            {ok, S, RH, RB};
        {error, _} when RetriesLeft > 0 ->
            Attempt   = ?DEFAULT_RETRIES - RetriesLeft + 1,
            BackoffMs = round(?RETRY_BACKOFF_MS * math:pow(2, Attempt - 1)),
            ?LOG_WARNING(#{msg => <<"Retrying">>,
                           attempt => Attempt, backoff_ms => BackoffMs}),
            timer:sleep(BackoffMs),
            request_with_retry(Method, Url, Headers, Body, RetriesLeft - 1, Timeout, Pool, TlsVerify);
        {error, Reason} ->
            {error, Reason}
    end.

pool_name(ServiceName) ->
    binary_to_atom(<<"rpc_gw_pool_", ServiceName/binary>>).

strip_trailing_slash(Bin) ->
    case binary:last(Bin) of
        $/ -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _  -> Bin
    end.

%% Generic prefix stripping: <<"/gis">>, <<"/myservice">>, etc.
strip_prefix(Path, <<>>) ->
    Path;
strip_prefix(Path, Prefix) ->
    %% Normalise: compare without leading slashes
    NormPath   = strip_leading_slash(Path),
    NormPrefix = strip_leading_slash(Prefix),
    PLen = byte_size(NormPrefix),
    case NormPath of
        NormPrefix ->
            <<"/">>;
        <<NormPrefix:PLen/binary, "/", Tail/binary>> ->
            <<"/", Tail/binary>>;
        _ ->
            Path
    end.

strip_leading_slash(<<"/", Rest/binary>>) -> Rest;
strip_leading_slash(Bin)                  -> Bin.

query_to_list(undefined) -> [];
query_to_list(null)      -> [];
query_to_list(M) when is_map(M) ->
    [{K, ensure_binary(V)}
     || {K, V} <- maps:to_list(M),
        V =/= undefined, V =/= null].

parse_int(undefined) -> undefined;
parse_int(null)      -> undefined;
parse_int(V) when is_integer(V) -> V;
parse_int(V) when is_binary(V) ->
    try binary_to_integer(V) catch _:_ -> undefined end;
parse_int(_) -> undefined.

ensure_binary(undefined)             -> <<>>;
ensure_binary(null)                  -> <<>>;
ensure_binary(B) when is_binary(B)   -> B;
ensure_binary(L) when is_list(L)     -> list_to_binary(L);
ensure_binary(A) when is_atom(A)     -> atom_to_binary(A);
ensure_binary(I) when is_integer(I)  -> integer_to_binary(I);
ensure_binary(T) -> iolist_to_binary(io_lib:format("~p", [T])).

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Val, Map) when is_integer(Val) ->
    case maps:is_key(Key, Map) of
        true  -> Map;
        false -> Map#{Key => integer_to_binary(Val)}
    end.

method_atom(<<"GET">>)     -> get;
method_atom(<<"POST">>)    -> post;
method_atom(<<"PUT">>)     -> put;
method_atom(<<"DELETE">>)  -> delete;
method_atom(<<"PATCH">>)   -> patch;
method_atom(<<"HEAD">>)    -> head;
method_atom(<<"OPTIONS">>) -> options;
method_atom(Other) when is_binary(Other) ->
    binary_to_existing_atom(string:lowercase(Other), utf8).
