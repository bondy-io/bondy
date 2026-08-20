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
    %% Converted on read: `bondy_config:splat_listener_blocks/1` writes the block
    %% one leaf at a time, so this path answers a proplist rather than the map
    %% merged below — `splatted_cors_and_security_headers_reach_the_consumers` in
    %% `bondy_listener_SUITE` drives that shape through this function.
    %%
    %% MERGED over the defaults rather than defaulted only on the read, which is
    %% what `bondy_http_cors:config_from_req/1` does with the sibling block: a
    %% block that is present but PARTIAL takes the read's value as-is, so a
    %% listener stating `hsts` alone used to lose `frame_options` and
    %% `content_type_options` — silently emitting FEWER security headers than a
    %% listener that stated nothing. The merge fills only ABSENT keys, so an
    %% explicit `undefined` still means "do not emit this header"
    %% (`hsts_only` in `bondy_http_security_headers_SUITE` covers that).
    Config = maps:merge(
        default_config(),
        key_value:to_map(
            bondy_config:get([ListenerName, security_headers], #{})
        )
    ),
    ServerHeader = bondy_config:get(
        [ListenerName, server_header], <<"bondy">>
    ),
    %% No defaults below this point: the merge above supplies all five keys, so
    %% a default here would be unreachable and would quietly restore the partial
    %% behaviour if the merge were ever removed.
    Headers =
        case maps:get(enabled, Config) of
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
    %% Read without defaults: `init/1` merges over `default_config/0`, so every
    %% key is present. A `maps:get/3` here would make that merge look optional.
    Pairs = [
        {<<"strict-transport-security">>, maps:get(hsts, Config)},
        {<<"x-frame-options">>, maps:get(frame_options, Config)},
        {<<"x-content-type-options">>, maps:get(content_type_options, Config)},
        {<<"content-security-policy">>,
            maps:get(content_security_policy, Config)}
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
        "" ->
            Headers;
        "bondy" ->
            Vsn = bondy_config:get(vsn, "undefined"),
            Headers#{<<"server">> => iolist_to_binary(["bondy/", Vsn])};
        _ ->
            Headers#{<<"server">> => list_to_binary(Value)}
    end.
