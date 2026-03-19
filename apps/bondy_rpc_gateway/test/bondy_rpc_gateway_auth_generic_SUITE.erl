-module(bondy_rpc_gateway_auth_generic_SUITE).

-moduledoc """
Tests for `bondy_rpc_gateway_auth_generic:apply_auth/4`.

These tests verify the token placement logic (query parameter and header)
without requiring an HTTP server, since `apply_auth/4` is a pure function.
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0]).

%% Test cases
-export([
    apply_auth_query_param/1,
    apply_auth_query_param_existing_qs/1,
    apply_auth_header_bearer/1,
    apply_auth_header_plain/1
]).

%% ===================================================================
%% CT callbacks
%% ===================================================================

all() ->
    [
        apply_auth_query_param,
        apply_auth_query_param_existing_qs,
        apply_auth_header_bearer,
        apply_auth_header_plain
    ].

%% ===================================================================
%% Test cases
%% ===================================================================

apply_auth_query_param(_Config) ->
    Conf = #{apply => #{placement => query_param, name => <<"token">>}},
    {Url, Headers} = bondy_rpc_gateway_auth_generic:apply_auth(
        <<"abc123">>, <<"https://api.example.com/data">>, [], Conf
    ),
    ?assertMatch(<<"https://api.example.com/data?token=abc123">>, Url),
    ?assertEqual([], Headers).

apply_auth_query_param_existing_qs(_Config) ->
    Conf = #{apply => #{placement => query_param, name => <<"token">>}},
    {Url, _} = bondy_rpc_gateway_auth_generic:apply_auth(
        <<"xyz">>, <<"https://api.example.com/data?foo=bar">>, [], Conf
    ),
    %% Should append with &, not ?
    ?assertMatch(<<"https://api.example.com/data?foo=bar&token=xyz">>, Url).

apply_auth_header_bearer(_Config) ->
    Conf = #{apply => #{
        placement => header,
        name      => <<"Authorization">>,
        format    => <<"Bearer {{token}}">>
    }},
    {Url, Headers} = bondy_rpc_gateway_auth_generic:apply_auth(
        <<"mytoken">>, <<"https://api.example.com">>, [], Conf
    ),
    ?assertEqual(<<"https://api.example.com">>, Url),
    ?assertEqual([{<<"Authorization">>, <<"Bearer mytoken">>}], Headers).

apply_auth_header_plain(_Config) ->
    %% No format specified → raw token value
    Conf = #{apply => #{placement => header, name => <<"X-API-Key">>}},
    {_, Headers} = bondy_rpc_gateway_auth_generic:apply_auth(
        <<"key123">>, <<"https://api.example.com">>, [], Conf
    ),
    ?assertEqual([{<<"X-API-Key">>, <<"key123">>}], Headers).
