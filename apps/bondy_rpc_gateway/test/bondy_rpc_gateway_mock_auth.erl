-module(bondy_rpc_gateway_mock_auth).

-moduledoc """
Mock authentication module for testing.

Implements `bondy_rpc_gateway_auth_proxy` by reading tokens from the
process dictionary or a configurable function, making it possible to
control fetch results, simulate failures, and count calls without
an HTTP server.

## Usage in tests

```erlang
%% Set a token for the calling process
bondy_rpc_gateway_mock_auth:set_token(<<"test-token">>).

%% Set a token with metadata
bondy_rpc_gateway_mock_auth:set_token(<<"test-token">>, #{expires_in => 300}).

%% Simulate a failure
bondy_rpc_gateway_mock_auth:set_error(token_endpoint_down).

%% Track how many times fetch_token was called
bondy_rpc_gateway_mock_auth:reset_call_count().
Count = bondy_rpc_gateway_mock_auth:call_count().
```
""".

-behaviour(bondy_rpc_gateway_auth_proxy).

-export([fetch_token/1]).
-export([apply_auth/4]).

%% Test helpers
-export([set_token/1, set_token/2]).
-export([set_error/1]).
-export([set_fetch_fun/1]).
-export([reset_call_count/0, call_count/0]).

%% ===================================================================
%% Test helpers — call from the test process
%% ===================================================================

-doc "Set the token to return on next `fetch_token/1` call.".
set_token(Token) ->
    set_token(Token, undefined).

-doc "Set the token and optional metadata map.".
set_token(Token, Meta) ->
    persistent_term:put({?MODULE, result}, {ok, Token, Meta}).

-doc "Make `fetch_token/1` return `{error, Reason}`.".
set_error(Reason) ->
    persistent_term:put({?MODULE, result}, {error, Reason}).

-doc "Set a custom fun/1 that receives the config and returns the result.".
set_fetch_fun(Fun) when is_function(Fun, 1) ->
    persistent_term:put({?MODULE, fetch_fun}, Fun).

-doc "Reset the call counter to 0.".
reset_call_count() ->
    persistent_term:put({?MODULE, call_count}, 0).

-doc "Return how many times `fetch_token/1` has been called.".
call_count() ->
    persistent_term:get({?MODULE, call_count}, 0).

%% ===================================================================
%% bondy_rpc_gateway_auth_proxy callbacks
%% ===================================================================

fetch_token(Config) ->
    Count = persistent_term:get({?MODULE, call_count}, 0),
    persistent_term:put({?MODULE, call_count}, Count + 1),
    case persistent_term:get({?MODULE, fetch_fun}, undefined) of
        Fun when is_function(Fun, 1) ->
            Fun(Config);
        _ ->
            case persistent_term:get({?MODULE, result}, {error, not_configured}) of
                {ok, Token, undefined} -> {ok, Token};
                {ok, Token, Meta}      -> {ok, {Token, Meta}};
                {error, _} = Err       -> Err
            end
    end.

apply_auth(Token, Url, Headers, _Config) ->
    {Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>} | Headers]}.
