%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_security_headers).
-moduledoc """
Static HTTP security headers management.

Handles per-listener security headers (HSTS, X-Frame-Options,
X-Content-Type-Options, Content-Security-Policy) and the configurable
Server response header.

Headers are computed once at listener startup via `init/1` and cached in
`persistent_term` for fast retrieval at request time.
""".

-export([init/1]).
-export([cleanup/1]).
-export([default_config/0]).
-export([headers/1]).
-export([headers_from_req/1]).


-type security_headers_config() :: #{
    enabled := boolean(),
    hsts := binary() | undefined,
    frame_options := binary() | undefined,
    content_type_options := binary() | undefined,
    content_security_policy := binary() | undefined
}.

-export_type([security_headers_config/0]).



%% =============================================================================
%% API
%% =============================================================================



-doc """
Initialises the cached security headers for the given listener.

Reads the security headers configuration from the Bondy application
environment and the server header configuration, builds the static
headers map, and stores it in `persistent_term` for fast access.
""".
-spec init(atom()) -> ok.

init(ListenerName) ->
    Config = bondy_config:get(
        [ListenerName, security_headers], default_config()
    ),
    ServerHeader = bondy_config:get(
        [ListenerName, server_header], <<"bondy">>
    ),
    Headers = case maps:get(enabled, Config, true) of
        true ->
            H = build_headers(Config),
            maybe_add_server_header(ServerHeader, H);
        false ->
            maybe_add_server_header(ServerHeader, #{})
    end,
    ok = persistent_term:put({?MODULE, ListenerName}, Headers),
    ok.


-doc "Removes the cached security headers for the given listener.".
-spec cleanup(atom()) -> ok.

cleanup(ListenerName) ->
    _ = persistent_term:erase({?MODULE, ListenerName}),
    ok.


-doc "Returns the default security headers configuration.".
-spec default_config() -> security_headers_config().

default_config() ->
    #{
        enabled => true,
        hsts => undefined,
        frame_options => <<"SAMEORIGIN">>,
        content_type_options => <<"nosniff">>,
        content_security_policy => undefined
    }.


-doc "Returns the cached security headers map for the given listener name.".
-spec headers(atom()) -> map().

headers(ListenerName) ->
    persistent_term:get({?MODULE, ListenerName}, #{}).


-doc "Returns the cached security headers map for the listener associated with the given Cowboy request.".
-spec headers_from_req(cowboy_req:req()) -> map().

headers_from_req(#{ref := Ref}) ->
    headers(Ref).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
build_headers(Config) ->
    Pairs = [
        {<<"strict-transport-security">>,
            maps:get(hsts, Config, undefined)},
        {<<"x-frame-options">>,
            maps:get(frame_options, Config, undefined)},
        {<<"x-content-type-options">>,
            maps:get(content_type_options, Config, undefined)},
        {<<"content-security-policy">>,
            maps:get(content_security_policy, Config, undefined)}
    ],
    maps:from_list([{K, V} || {K, V} <- Pairs, V =/= undefined]).


%% @private
maybe_add_server_header(<<"bondy">>, Headers) ->
    Vsn = bondy_config:get(vsn, "undefined"),
    Headers#{<<"server">> => iolist_to_binary(["bondy/", Vsn])};

maybe_add_server_header(<<>>, Headers) ->
    Headers;

maybe_add_server_header(Value, Headers) when is_binary(Value) ->
    Headers#{<<"server">> => Value};

maybe_add_server_header(Value, Headers) when is_list(Value) ->
    case Value of
        "" -> Headers;
        "bondy" ->
            Vsn = bondy_config:get(vsn, "undefined"),
            Headers#{<<"server">> => iolist_to_binary(["bondy/", Vsn])};
        _ ->
            Headers#{<<"server">> => list_to_binary(Value)}
    end.
