%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% =============================================================================
%% Tests for `bondy_http_connector_telemetry:classify_status/1` — the pure
%% function that buckets a `bondy_http_connector_callee_handler:do_handle_wamp_call/2`
%% return tuple into a Prometheus outcome label. Every actual return shape in
%% that module (success, upstream error passthrough, and every wamp_error/3
%% synthetic site) is covered so the classifier can't silently drift from
%% the handler it observes.
%% =============================================================================

-module(bondy_http_connector_telemetry_test).

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_http_connector_telemetry).

classify_status_test_() ->
    [
        {"2xx success is ok",
            ?_assertEqual(
                ok, ?M:classify_status({ok, #{}, [], #{<<"status">> => 200}})
            )},
        {"201 success is ok",
            ?_assertEqual(
                ok, ?M:classify_status({ok, #{}, [], #{<<"status">> => 201}})
            )},
        {"299 boundary is ok",
            ?_assertEqual(
                ok, ?M:classify_status({ok, #{}, [], #{<<"status">> => 299}})
            )},
        {"3xx passthrough is redirect",
            ?_assertEqual(
                redirect,
                ?M:classify_status(
                    {error, ~"bondy.error.bad_gateway", #{}, [], #{
                        <<"status">> => 301
                    }}
                )
            )},
        {"400 invalid_argument is client_error",
            ?_assertEqual(
                client_error,
                ?M:classify_status(
                    {error, ~"wamp.error.invalid_argument", #{}, [], #{
                        <<"status">> => 400
                    }}
                )
            )},
        {"401/403 not_authorized is client_error",
            ?_assertEqual(
                client_error,
                ?M:classify_status(
                    {error, ~"wamp.error.not_authorized", #{}, [], #{
                        <<"status">> => 401
                    }}
                )
            )},
        {"429 too_many_requests is client_error",
            ?_assertEqual(
                client_error,
                ?M:classify_status(
                    {error, ~"bondy.error.too_many_requests", #{}, [], #{
                        <<"status">> => 429
                    }}
                )
            )},
        {"synthetic 503 auth pending is server_error",
            ?_assertEqual(
                server_error,
                ?M:classify_status(
                    {error, ~"bondy.error.bad_gateway", #{}, [], #{
                        <<"status">> => 503,
                        <<"message">> => ~"Service credentials pending"
                    }}
                )
            )},
        {"synthetic 502 upstream connection failed is server_error",
            ?_assertEqual(
                server_error,
                ?M:classify_status(
                    {error, ~"bondy.error.bad_gateway", #{}, [], #{
                        <<"status">> => 502,
                        <<"message">> => ~"Upstream connection failed"
                    }}
                )
            )},
        {"synthetic 500 internal error is server_error",
            ?_assertEqual(
                server_error,
                ?M:classify_status(
                    {error, ~"bondy.error.bad_gateway", #{}, [], #{
                        <<"status">> => 500, <<"message">> => ~"Internal error"
                    }}
                )
            )},
        {"no status key is unknown",
            ?_assertEqual(
                unknown, ?M:classify_status({ok, #{}, [], #{}})
            )},
        {"unrecognised return shape is unknown",
            ?_assertEqual(
                unknown, ?M:classify_status(unexpected_term)
            )}
    ].
