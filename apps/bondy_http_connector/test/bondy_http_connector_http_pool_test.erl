%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% =============================================================================
%% Tests for `bondy_http_connector_http_pool:liveness_url/2` — the pure
%% function that resolves the periodic liveness probe's target URL from
%% the pool's endpoint and the configured `liveness.path`. Covers the
%% default (bare endpoint) branch and every slash-normalisation case for a
%% configured path, none of which are exercised by
%% `bondy_http_connector_http_pool_SUITE` (its scenarios all use the
%% default path).
%% =============================================================================

-module(bondy_http_connector_http_pool_test).

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_http_connector_http_pool).

liveness_url_test_() ->
    [
        {"default path probes the bare endpoint",
            ?_assertEqual(
                ~"https://api.example.com",
                ?M:liveness_url(~"https://api.example.com", #{})
            )},
        {"default path with trailing slash endpoint is unchanged",
            ?_assertEqual(
                ~"https://api.example.com/",
                ?M:liveness_url(~"https://api.example.com/", #{})
            )},
        {"configured path with leading slash appends cleanly",
            ?_assertEqual(
                ~"https://api.example.com/healthz",
                ?M:liveness_url(~"https://api.example.com", #{
                    path => ~"/healthz"
                })
            )},
        {"configured path without leading slash gets one added",
            ?_assertEqual(
                ~"https://api.example.com/healthz",
                ?M:liveness_url(~"https://api.example.com", #{
                    path => ~"healthz"
                })
            )},
        {"trailing slash on endpoint is stripped before appending path",
            ?_assertEqual(
                ~"https://api.example.com/healthz",
                ?M:liveness_url(~"https://api.example.com/", #{
                    path => ~"/healthz"
                })
            )},
        {"nested configured path is appended verbatim",
            ?_assertEqual(
                ~"https://api.example.com/api/v1/health",
                ?M:liveness_url(~"https://api.example.com", #{
                    path => ~"/api/v1/health"
                })
            )}
    ].
