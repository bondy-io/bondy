%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_auth_proxy).

-moduledoc """
Behaviour for proxy authentication strategies.

Each implementation knows how to acquire a token from an upstream identity
provider and where to place it on outgoing requests (query parameter,
HTTP header, etc.).

## Implementing a callback module

```erlang
-module(my_auth).
-behaviour(bondy_rpc_gateway_auth_proxy).

-export([fetch_token/1, apply_auth/4]).

fetch_token(#{url := Url, api_key := Key}) ->
    case httpc:request(get, {binary_to_list(Url), []}, [], []) of
        {ok, {{_, 200, _}, _, Body}} ->
            Token = proplists:get_value(<<"token">>, json:decode(Body)),
            %% Return metadata so the cache knows when to refresh
            {ok, {Token, #{expires_in => 3600}}};
        _ ->
            {error, token_fetch_failed}
    end.

apply_auth(Token, Url, Headers, _Config) ->
    {Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>} | Headers]}.
```

## Return values for `fetch_token/1`

- `{ok, Token}` — plain token, cache uses `default_ttl` from config
- `{ok, {Token, Meta}}` — token with metadata; `Meta` may contain
  `#{expires_in => Seconds}` to tell the cache how long the token is valid
- `{error, Reason}` — acquisition failed
""".

-doc """
Acquire a fresh authentication token.

Returns `{ok, Token}` or `{ok, {Token, Meta}}` on success.
`Meta` is an optional map that may contain `expires_in` (seconds until
the token expires), used by the token cache for preemptive refresh
scheduling.

## Examples

```erlang
%% Simple — no expiry metadata
fetch_token(Config) ->
    {ok, <<"abc123">>}.

%% With expiry — cache will refresh 60 s before this
fetch_token(Config) ->
    {ok, {<<"abc123">>, #{expires_in => 7200}}}.
```
""".
-callback fetch_token(Config :: map()) ->
    {ok, Token :: binary()} |
    {ok, {Token :: binary(), Meta :: map()}} |
    {error, term()}.

-doc """
Apply the acquired token to an outgoing request.

Receives the token, the request URL (without auth), the base headers,
and the full auth config. Returns the modified `{Url, Headers}`.

## Examples

```erlang
%% Add as a query parameter
apply_auth(Token, Url, Headers, _Conf) ->
    {<<Url/binary, "?token=", Token/binary>>, Headers}.

%% Add as a Bearer header
apply_auth(Token, Url, Headers, _Conf) ->
    {Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>} | Headers]}.
```
""".
-callback apply_auth(
    Token   :: binary(),
    Url     :: binary(),
    Headers :: [{binary(), binary()}],
    Config  :: map()
) -> {Url :: binary(), Headers :: [{binary(), binary()}]}.
