%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_auth_generic).

-moduledoc """
Declarative proxy authentication strategy.

Interprets a configuration map to fetch tokens from arbitrary HTTP
endpoints and apply them to forwarded requests, removing the need
to write a dedicated Erlang module for each upstream auth scheme.

## Config shape

```erlang
#{
    fetch => #{
        method          => get | post,
        url             => binary(),           %% supports {{var}} interpolation
        headers         => [{K, V}],           %% optional, values interpolated
        body_encoding   => form | json | none, %% optional, default none
        body            => #{K => V},          %% optional, values interpolated
        auth            => #{                  %% optional request-level auth
            type     => basic,
            username => binary(),
            password => binary()
        },
        token_path      => [binary()],         %% JSON path to token in response
        error_path      => [binary()],         %% optional, JSON path to error
        expires_in_path => [binary()]          %% optional, JSON path to TTL (seconds)
    },
    apply => #{
        placement => query_param | header,
        name      => binary(),                 %% param or header name
        format    => binary()                  %% optional, e.g. <<"Bearer {{token}}">>
    },
    vars  => #{atom() => binary()},            %% variable bindings
    cache => #{                                %% optional, all keys have defaults
        default_ttl    => pos_integer(),       %% seconds, default 3600
        refresh_margin => pos_integer()        %% seconds, default 60
    }
}
```

## Examples

### OAuth2 client-credentials with Bearer header

```erlang
#{
    fetch => #{
        method        => post,
        url           => <<"https://idp.example.com/oauth/token">>,
        body_encoding => form,
        body => #{
            <<"grant_type">>    => <<"client_credentials">>,
            <<"client_id">>     => <<"{{client_id}}">>,
            <<"client_secret">> => <<"{{client_secret}}">>
        },
        token_path      => [<<"access_token">>],
        expires_in_path => [<<"expires_in">>]
    },
    apply => #{
        placement => header,
        name      => <<"Authorization">>,
        format    => <<"Bearer {{token}}">>
    },
    vars => #{
        client_id     => <<"my-app">>,
        client_secret => <<"s3cret">>
    },
    cache => #{
        default_ttl    => 3600,
        refresh_margin => 120
    }
}
```

### Custom token via query parameter

```erlang
#{
    fetch => #{
        method        => post,
        url           => <<"{{base_url}}/generateToken">>,
        body_encoding => form,
        body => #{
            <<"username">> => <<"{{username}}">>,
            <<"password">> => <<"{{password}}">>,
            <<"f">>        => <<"json">>
        },
        token_path => [<<"token">>],
        error_path => [<<"error">>, <<"message">>]
    },
    apply => #{
        placement => query_param,
        name      => <<"token">>
    },
    vars => #{
        base_url => <<"https://custom.example.com">>,
        username => <<"admin">>,
        password => <<"hunter2">>
    }
}
```
""".

-behaviour(bondy_rpc_gateway_auth_proxy).

-include_lib("kernel/include/logger.hrl").

-export([fetch_token/1]).
-export([apply_auth/4]).


%% =============================================================================
%% BONDY_RPC_GATEWAY_AUTH_PROXY CALLBACKS
%% =============================================================================



-doc """
Fetch a token from the configured HTTP endpoint.

Performs the HTTP request described in the `fetch` section of the config,
extracts the token using `token_path`, and optionally reads `expires_in_path`
to return TTL metadata for the cache.

## Examples

```erlang
Conf = #{
    fetch => #{
        method     => post,
        url        => <<"https://idp.example.com/token">>,
        body_encoding => form,
        body       => #{<<"grant_type">> => <<"client_credentials">>},
        token_path => [<<"access_token">>],
        expires_in_path => [<<"expires_in">>]
    },
    vars => #{}
},
{ok, {<<"eyJ...">>, #{expires_in => 3600}}} = bondy_rpc_gateway_auth_generic:fetch_token(Conf).
```
""".
-spec fetch_token(map()) ->
    {ok, binary()} | {ok, {binary(), map()}} | {error, term()}.

fetch_token(#{fetch := FetchConf} = Conf) ->
    Vars = maps:get(vars, Conf, #{}),
    #{method := Method, url := UrlTpl, token_path := TokenPath} = FetchConf,

    Url = interpolate(UrlTpl, Vars),
    Headers0 = interpolate_pairs(maps:get(headers, FetchConf, []), Vars),
    BodyEncoding = maps:get(body_encoding, FetchConf, none),
    BodyMap = interpolate_map(maps:get(body, FetchConf, #{}), Vars),
    ErrorPath = maps:get(error_path, FetchConf, undefined),
    ExpiresInPath = maps:get(expires_in_path, FetchConf, undefined),

    {Headers1, Body} = encode_body(BodyEncoding, BodyMap, Headers0),
    Headers = apply_request_auth(
        maps:get(auth, FetchConf, undefined), Vars, Headers1
    ),

    Opts = [{ssl_options, bondy_cert_manager:ssl_opts()}, {pool, default}, with_body],

    case hackney:request(Method, Url, Headers, Body, Opts) of
        {ok, 200, _RH, RespBody} ->
            case decode_json(RespBody) of
                {ok, Data} ->
                    case check_error(Data, ErrorPath) of
                        ok ->
                            case walk_path(Data, TokenPath) of
                                {ok, T} when is_binary(T), byte_size(T) > 0 ->
                                    make_token_result(T, Data, ExpiresInPath);
                                _ ->
                                    {error, no_token_in_response}
                            end;

                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;

        {ok, Status, _RH, RespBody} ->
            ?LOG_ERROR(#{
                msg => <<"Token request failed">>,
                status => Status,
                body => RespBody
            }),
            {error, {http_status, Status}};

        {error, Reason} ->
            {error, Reason}
    end.

-doc """
Apply the token to an outgoing request according to the `apply` config.

Supports two placement strategies:

- `query_param` — appends `?name=Token` (or `&name=Token`) to the URL
- `header` — adds a header, optionally using a `format` template

## Examples

```erlang
%% Query parameter placement
Conf = #{apply => #{placement => query_param, name => <<"token">>}},
{<<"https://api.example.com/data?token=abc">>, Headers} =
    bondy_rpc_gateway_auth_generic:apply_auth(
        <<"abc">>, <<"https://api.example.com/data">>, [], Conf
    ).

%% Bearer header placement
Conf = #{apply => #{placement => header, name => <<"Authorization">>,
                     format => <<"Bearer {{token}}">>}},
{Url, [{<<"Authorization">>, <<"Bearer abc">>}]} =
    bondy_rpc_gateway_auth_generic:apply_auth(<<"abc">>, Url, [], Conf).
```
""".
-spec apply_auth(binary(), binary(), [{binary(), binary()}], map()) ->
    {binary(), [{binary(), binary()}]}.

apply_auth(Token, Url, Headers, #{apply := ApplyConf}) ->
    case ApplyConf of
        #{placement := query_param, name := Name} ->
            Sep =
                case binary:match(Url, <<"?">>) of
                    nomatch -> <<"?">>;
                    _       -> <<"&">>
                end,
            Param = uri_string:compose_query([{Name, Token}]),
            {<<Url/binary, Sep/binary, Param/binary>>, Headers};

        #{placement := header, name := Name} ->
            Format = maps:get(format, ApplyConf, <<"{{token}}">>),
            Value = binary:replace(Format, <<"{{token}}">>, Token),
            {Url, [{Name, Value} | Headers]}
    end.




%% =============================================================================
%% PRIVATE
%% =============================================================================



make_token_result(Token, _Data, undefined) ->
    {ok, Token};

make_token_result(Token, Data, ExpiresInPath) ->
    case walk_path(Data, ExpiresInPath) of
        {ok, N} when is_integer(N), N > 0 ->
            {ok, {Token, #{expires_in => N}}};
        _ ->
            {ok, Token}
    end.

interpolate(Template, Vars) ->
    maps:fold(
        fun(Key, Val, Acc) ->
            Pattern = <<"{{", (to_binary(Key))/binary, "}}">>,
            binary:replace(Acc, Pattern, to_binary(Val), [global])
        end,
        Template,
        Vars
    ).

interpolate_pairs(Pairs, Vars) ->
    [{K, interpolate(V, Vars)} || {K, V} <- Pairs].

interpolate_map(Map, Vars) ->
    maps:map(fun(_K, V) -> interpolate(V, Vars) end, Map).

encode_body(none, _BodyMap, Headers) ->
    {Headers, <<>>};

encode_body(form, BodyMap, Headers) ->
    Body = uri_string:compose_query(maps:to_list(BodyMap)),
    {
        ensure_content_type(<<"application/x-www-form-urlencoded">>, Headers),
        Body
    };

encode_body(json, BodyMap, Headers) ->
    Body = iolist_to_binary(json:encode(BodyMap)),
    {ensure_content_type(<<"application/json">>, Headers), Body}.

ensure_content_type(CT, Headers) ->
    case lists:keyfind(<<"Content-Type">>, 1, Headers) of
        false ->
            [{<<"Content-Type">>, CT} | Headers];

        _ ->
            Headers
    end.


apply_request_auth(undefined, _Vars, Headers) ->
    Headers;

apply_request_auth(
    #{type := basic, username := UserTpl, password := PassTpl},
    Vars,
    Headers) ->
    User = interpolate(UserTpl, Vars),
    Pass = interpolate(PassTpl, Vars),
    Cred = base64:encode(<<User/binary, ":", Pass/binary>>),
    [{<<"Authorization">>, <<"Basic ", Cred/binary>>} | Headers].

decode_json(Body) ->
    try
        {ok, json:decode(Body)}
    catch
        error:Reason ->
            ?LOG_ERROR(#{
                description => "Token endpoint returned non-JSON response",
                reason => Reason,
                body_prefix => binary:part(Body, 0, min(200, byte_size(Body)))
            }),
            {error, {invalid_json_response, Reason}}
    end.

check_error(_Data, undefined) ->
    ok;

check_error(Data, ErrorPath) ->
    case walk_path(Data, ErrorPath) of
        {ok, Msg} when is_binary(Msg) ->
            {error, {upstream_error, Msg}};

        {ok, _} ->
            {error, {upstream_error, <<"Unknown error">>}};

        error ->
            ok
    end.

walk_path(Value, []) ->
    {ok, Value};

walk_path(Data, [Key | Rest]) when is_map(Data) ->
    case maps:find(Key, Data) of
        {ok, Value} ->
            walk_path(Value, Rest);
        error ->
            error
    end;

walk_path(_, _) ->
    error.


to_binary(B) when is_binary(B) ->
    B;

to_binary(A) when is_atom(A) ->
    atom_to_binary(A);

to_binary(I) when is_integer(I) ->
    integer_to_binary(I);

to_binary(L) when is_list(L) ->
    list_to_binary(L).
