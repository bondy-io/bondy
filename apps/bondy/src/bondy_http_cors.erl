%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_cors).
-moduledoc """
Centralised CORS (Cross-Origin Resource Sharing) header management.

Provides request-dependent CORS header computation based on per-listener
configuration. Supports three origin modes:

- `*` — wildcard, allows all origins (credentials forced to false)
- `auto` — derives the allowed origin from the request's own
  scheme/host/port
- `[binary()]` — an explicit allowlist of origins; the request
  `Origin` header is validated against this list. Entries starting
  with `*.` are treated as wildcard subdomain patterns (e.g.
  `*.example.com` matches `https://app.example.com`)

Configuration is read from the Bondy application environment at path
`[ListenerName, cors]` using the listener ref from the Cowboy request.
""".

-export([config_from_req/1]).
-export([default_config/0]).
-export([headers/2]).
-export([set_headers/2]).


-type cors_config() :: #{
    enabled := boolean(),
    allowed_origins := '*' | auto | [binary()],
    allowed_methods := binary(),
    allowed_headers := binary(),
    max_age := binary()
}.

-export_type([cors_config/0]).



%% =============================================================================
%% API
%% =============================================================================



-doc "Returns the CORS configuration for the listener associated with the given Cowboy request.".
-spec config_from_req(cowboy_req:req()) -> cors_config().

config_from_req(#{ref := Ref}) ->
    bondy_config:get([Ref, cors], default_config()).


-doc "Returns the default CORS configuration (wildcard origin, all methods).".
-spec default_config() -> cors_config().

default_config() ->
    #{
        enabled => true,
        allowed_origins => '*',
        allowed_methods => <<"GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE">>,
        allowed_headers => <<"origin,x-requested-with,content-type,accept,authorization,accept-language,x-csrf-token">>,
        max_age => <<"86400">>
    }.


-doc """
Computes the CORS response headers map based on the request and the given
CORS configuration.

Returns an empty map when CORS is disabled, or when the request origin
does not match the allowed origins list.
""".
-spec headers(cowboy_req:req(), cors_config()) -> map().

headers(_Req, #{enabled := false}) ->
    #{};

headers(Req, Config) ->
    case effective_origin(Req, Config) of
        undefined ->
            #{};
        Origin ->
            build_headers(Origin, Config)
    end.


-doc "Computes CORS headers and sets them on the Cowboy request.".
-spec set_headers(cowboy_req:req(), cors_config()) -> cowboy_req:req().

set_headers(Req, Config) ->
    cowboy_req:set_resp_headers(headers(Req, Config), Req).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
effective_origin(Req, #{allowed_origins := '*'}) ->
    _ = Req,
    <<"*">>;

effective_origin(Req, #{allowed_origins := auto}) ->
    derive_origin(Req);

effective_origin(Req, #{allowed_origins := AllowedList}) when is_list(AllowedList) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined ->
            undefined;
        Origin ->
            case origin_allowed(Origin, AllowedList) of
                true -> Origin;
                false -> undefined
            end
    end.


%% @private
derive_origin(Req) ->
    Scheme = cowboy_req:scheme(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    case {Scheme, Port} of
        {<<"https">>, 443} ->
            <<Scheme/binary, "://", Host/binary>>;
        {<<"http">>, 80} ->
            <<Scheme/binary, "://", Host/binary>>;
        _ ->
            PortBin = integer_to_binary(Port),
            <<Scheme/binary, "://", Host/binary, ":", PortBin/binary>>
    end.


%% @private
origin_allowed(_Origin, []) ->
    false;

origin_allowed(Origin, [Origin | _]) ->
    true;

origin_allowed(Origin, [<<"*.", Rest/binary>> | Tail]) ->
    case origin_matches_wildcard(Origin, Rest) of
        true -> true;
        false -> origin_allowed(Origin, Tail)
    end;

origin_allowed(Origin, [_ | Tail]) ->
    origin_allowed(Origin, Tail).


%% @private
%% Matches "*.example.com" against an origin like "https://sub.example.com:443".
%% Extracts the host from the origin and checks if it is a subdomain of the
%% wildcard suffix.
origin_matches_wildcard(Origin, DomainSuffix) ->
    case extract_host(Origin) of
        undefined ->
            false;
        Host ->
            %% Host must end with ".example.com" (the DomainSuffix)
            %% and must be strictly longer (i.e. have a subdomain part).
            SuffixWithDot = <<".", DomainSuffix/binary>>,
            SuffixLen = byte_size(SuffixWithDot),
            HostLen = byte_size(Host),
            HostLen > SuffixLen andalso
                binary:part(Host, HostLen - SuffixLen, SuffixLen) =:= SuffixWithDot
    end.


%% @private
%% Extracts the host part from an origin string like "https://host:port".
extract_host(Origin) ->
    case binary:split(Origin, <<"://">>) of
        [_Scheme, Rest] ->
            case binary:split(Rest, <<":">>) of
                [Host, _Port] -> Host;
                [Host] -> Host
            end;
        _ ->
            undefined
    end.


%% @private
build_headers(<<"*">> = Origin, Config) ->
    #{
        <<"access-control-allow-origin">> => Origin,
        <<"access-control-allow-credentials">> => <<"false">>,
        <<"access-control-allow-methods">> => maps:get(allowed_methods, Config),
        <<"access-control-allow-headers">> => maps:get(allowed_headers, Config),
        <<"access-control-max-age">> => maps:get(max_age, Config)
    };

build_headers(Origin, Config) ->
    #{
        <<"access-control-allow-origin">> => Origin,
        <<"access-control-allow-credentials">> => <<"true">>,
        <<"access-control-allow-methods">> => maps:get(allowed_methods, Config),
        <<"access-control-allow-headers">> => maps:get(allowed_headers, Config),
        <<"access-control-max-age">> => maps:get(max_age, Config),
        <<"vary">> => <<"Origin">>
    }.
