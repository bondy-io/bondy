%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_connector_telemetry).
-moduledoc """
Telemetry conventions for `bondy_http_connector` instrumentation.

Mirrors `bondy_telemetry` (`apps/bondy_router/src`): events are emitted
with `telemetry:execute/3`, carrying extracted scalars only, and every
emission function is total (wrapped in try/catch, never throws).

Unlike the router, this module also owns the sink — it declares the
`bondy_metrics` families and attaches its own handler
(`handle_event/4`) that writes them. The router splits emission
(`bondy_telemetry`) from sink (`bondy_prometheus`) because router events
fire on every WAMP message; nothing here is anywhere near that hot —
these events fire once per WAMP-to-HTTP call, retry, token operation,
or liveness probe — so a single module keeps the same total/never-throws
guarantees without adding a second file for no operational benefit.
Other consumers (e.g. a future trace exporter) can still
`telemetry:attach/4` to these events independently.
""".

-include_lib("kernel/include/logger.hrl").
-include("bondy_http_connector.hrl").

%% API
-export([init/0]).
-export([liveness_probe/3]).
-export([pool_status/2]).
-export([request/3]).
-export([retry/3]).
-export([secret_resolution/3]).
-export([token_cache/2]).
-export([token_fetch/3]).
-export([token_refresh/3]).

%% Telemetry sink, exported for `telemetry:attach_many/4`
-export([handle_event/4]).

%% Exported for testing
-export([classify_status/1]).

-define(EVENTS, [
    [bondy, http_connector, request],
    [bondy, http_connector, retry],
    [bondy, http_connector, token_cache],
    [bondy, http_connector, token_fetch],
    [bondy, http_connector, token_refresh],
    [bondy, http_connector, secret_resolution],
    [bondy, http_connector, pool_status],
    [bondy, http_connector, liveness_probe]
]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Declares the `bondy_metrics` families and attaches this module's sink.
Called once from `bondy_http_connector_app:start/2`.
""".
-spec init() -> ok.

init() ->
    ok = declare_families(),
    case
        telemetry:attach_many(
            ?MODULE, ?EVENTS, fun ?MODULE:handle_event/4, undefined
        )
    of
        ok -> ok;
        {error, already_exists} -> ok
    end.

-doc """
Emits `[bondy, http_connector, request]` for a completed WAMP-to-HTTP
forwarded call. `StartTs` is the `erlang:monotonic_time(millisecond)`
captured before the call began; the outcome is classified from the
handler's return shape via `classify_status/1`. Total: never throws.
""".
-spec request(
    ProcConf :: #http_connector_proc_conf{},
    StartTs :: integer(),
    Result :: tuple()
) -> ok.

request(
    #http_connector_proc_conf{service_name = Service, uri = ProcUri},
    StartTs,
    Result
) ->
    DurationMs = erlang:monotonic_time(millisecond) - StartTs,
    Outcome = classify_status(Result),
    execute(
        [bondy, http_connector, request],
        #{duration => max(0, DurationMs)},
        #{service => Service, procedure_uri => ProcUri, outcome => Outcome}
    ).

-doc """
Emits `[bondy, http_connector, retry]` for an upstream HTTP retry
attempt. Total: never throws.
""".
-spec retry(Service :: binary(), ProcUri :: binary(), Attempt :: pos_integer()) ->
    ok.

retry(Service, ProcUri, Attempt) ->
    execute(
        [bondy, http_connector, retry],
        #{count => 1},
        #{service => Service, procedure_uri => ProcUri, attempt => Attempt}
    ).

-doc """
Emits `[bondy, http_connector, token_cache]` for a token cache lookup.
`Result` is `hit` when served from the worker's ETS table without a
`gen_server` round trip, `miss` otherwise. Total: never throws.
""".
-spec token_cache(Service :: binary(), Result :: hit | miss) -> ok.

token_cache(Service, Result) ->
    execute(
        [bondy, http_connector, token_cache],
        #{count => 1},
        #{service => Service, result => Result}
    ).

-doc """
Emits `[bondy, http_connector, token_fetch]` for a token acquisition
HTTP call to the identity provider. Total: never throws.
""".
-spec token_fetch(
    Service :: binary(), Outcome :: ok | error, DurationMs :: integer()
) -> ok.

token_fetch(Service, Outcome, DurationMs) ->
    execute(
        [bondy, http_connector, token_fetch],
        #{duration => max(0, DurationMs)},
        #{service => Service, outcome => Outcome}
    ).

-doc """
Emits `[bondy, http_connector, token_refresh]` for a preemptive or
reactive token refresh. Total: never throws.
""".
-spec token_refresh(
    Service :: binary(), Outcome :: ok | error, Trigger :: preemptive | reactive
) -> ok.

token_refresh(Service, Outcome, Trigger) ->
    execute(
        [bondy, http_connector, token_refresh],
        #{count => 1},
        #{service => Service, outcome => Outcome, trigger => Trigger}
    ).

-doc """
Emits `[bondy, http_connector, secret_resolution]` for a secret
resolution attempt against the configured provider (e.g. AWS Secrets
Manager). The sink also reflects the outcome in the
`bondy_http_connector_service_ready` gauge. Total: never throws.
""".
-spec secret_resolution(
    Service :: binary(), Outcome :: ok | error, Phase :: startup | retry
) -> ok.

secret_resolution(Service, Outcome, Phase) ->
    execute(
        [bondy, http_connector, secret_resolution],
        #{count => 1},
        #{service => Service, outcome => Outcome, phase => Phase}
    ).

-doc """
Emits `[bondy, http_connector, pool_status]` for an HTTP pool up/down
transition. The sink also reflects the transition in the
`bondy_http_connector_pool_up` gauge. Total: never throws.
""".
-spec pool_status(Service :: binary(), Status :: up | down) -> ok.

pool_status(Service, Status) ->
    execute(
        [bondy, http_connector, pool_status],
        #{count => 1},
        #{service => Service, status => Status}
    ).

-doc """
Emits `[bondy, http_connector, liveness_probe]` for a periodic
liveness check against a service's upstream endpoint, regardless of
whether it changed the pool's up/down state. Total: never throws.
""".
-spec liveness_probe(
    Service :: binary(), Outcome :: ok | error, DurationMs :: integer()
) -> ok.

liveness_probe(Service, Outcome, DurationMs) ->
    execute(
        [bondy, http_connector, liveness_probe],
        #{duration => max(0, DurationMs)},
        #{service => Service, outcome => Outcome}
    ).

%% =============================================================================
%% TELEMETRY SINK
%% =============================================================================

-doc false.
handle_event([bondy, http_connector, request], #{duration := D}, Meta, _Config) ->
    #{service := Service, procedure_uri := Uri, outcome := Outcome} = Meta,
    safe(fun() ->
        bondy_metrics:counter(#{
            name => bondy_http_connector_requests_total,
            label => #{
                service => Service, procedure_uri => Uri, outcome => Outcome
            }
        })
    end),
    safe(fun() ->
        bondy_metrics:histogram(#{
            name => bondy_http_connector_request_duration_milliseconds,
            label => #{service => Service, procedure_uri => Uri},
            value => D
        })
    end);
handle_event([bondy, http_connector, retry], _Meas, Meta, _Config) ->
    #{service := Service, procedure_uri := Uri} = Meta,
    safe(fun() ->
        bondy_metrics:counter(#{
            name => bondy_http_connector_retries_total,
            label => #{service => Service, procedure_uri => Uri}
        })
    end);
handle_event([bondy, http_connector, token_cache], _Meas, Meta, _Config) ->
    #{service := Service, result := Result} = Meta,
    safe(fun() ->
        bondy_metrics:counter(#{
            name => bondy_http_connector_token_cache_total,
            label => #{service => Service, result => Result}
        })
    end);
handle_event(
    [bondy, http_connector, token_fetch], #{duration := D}, Meta, _Config
) ->
    #{service := Service, outcome := Outcome} = Meta,
    safe(fun() ->
        bondy_metrics:counter(#{
            name => bondy_http_connector_token_fetch_total,
            label => #{service => Service, outcome => Outcome}
        })
    end),
    safe(fun() ->
        bondy_metrics:histogram(#{
            name => bondy_http_connector_token_fetch_duration_milliseconds,
            label => #{service => Service},
            value => D
        })
    end);
handle_event([bondy, http_connector, token_refresh], _Meas, Meta, _Config) ->
    #{service := Service, outcome := Outcome} = Meta,
    safe(fun() ->
        bondy_metrics:counter(#{
            name => bondy_http_connector_token_refresh_total,
            label => #{service => Service, outcome => Outcome}
        })
    end);
handle_event([bondy, http_connector, secret_resolution], _Meas, Meta, _Config) ->
    #{service := Service, outcome := Outcome} = Meta,
    safe(fun() ->
        bondy_metrics:counter(#{
            name => bondy_http_connector_secret_resolution_total,
            label => #{service => Service, outcome => Outcome}
        })
    end),
    Ready = ready_value(Outcome),
    safe(fun() ->
        bondy_metrics:gauge(#{
            name => bondy_http_connector_service_ready,
            label => #{service => Service},
            value => Ready
        })
    end);
handle_event([bondy, http_connector, pool_status], _Meas, Meta, _Config) ->
    #{service := Service, status := Status} = Meta,
    safe(fun() ->
        bondy_metrics:counter(#{
            name => bondy_http_connector_pool_status_changes_total,
            label => #{service => Service, status => Status}
        })
    end),
    Up = up_value(Status),
    safe(fun() ->
        bondy_metrics:gauge(#{
            name => bondy_http_connector_pool_up,
            label => #{service => Service},
            value => Up
        })
    end);
handle_event(
    [bondy, http_connector, liveness_probe], #{duration := D}, Meta, _Config
) ->
    #{service := Service, outcome := Outcome} = Meta,
    safe(fun() ->
        bondy_metrics:counter(#{
            name => bondy_http_connector_liveness_probes_total,
            label => #{service => Service, outcome => Outcome}
        })
    end),
    safe(fun() ->
        bondy_metrics:histogram(#{
            name => bondy_http_connector_liveness_probe_duration_milliseconds,
            label => #{service => Service},
            value => D
        })
    end);
handle_event(_Event, _Measurements, _Meta, _Config) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
declare_families() ->
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_requests_total,
        help =>
            ~"Total WAMP-to-HTTP forwarded calls, by service, procedure and outcome (ok | redirect | client_error | server_error | unknown)."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_request_duration_milliseconds,
        help =>
            ~"Duration of a WAMP-to-HTTP forwarded call, from WAMP invocation to WAMP response, by service and procedure."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_retries_total,
        help => ~"Total upstream HTTP retry attempts, by service and procedure."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_token_cache_total,
        help =>
            ~"Total token cache lookups, by service and result (hit | miss)."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_token_fetch_total,
        help =>
            ~"Total token acquisition HTTP calls to the identity provider, by service and outcome."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_token_fetch_duration_milliseconds,
        help => ~"Duration of a token acquisition HTTP call, by service."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_token_refresh_total,
        help =>
            ~"Total preemptive or reactive token refreshes, by service, outcome and trigger."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_secret_resolution_total,
        help =>
            ~"Total external secret resolution attempts, by service and outcome."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_service_ready,
        help =>
            ~"1 when a service's secrets are resolved and it is ready to serve calls, 0 while pending. Only present for services with a secrets provider configured."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_pool_status_changes_total,
        help => ~"Total HTTP pool up/down transitions, by service and status."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_pool_up,
        help => ~"1 when a service's upstream HTTP pool is up, 0 when down."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_liveness_probes_total,
        help =>
            ~"Total periodic liveness probes against a service's upstream endpoint, by service and outcome."
    }),
    ok = bondy_metrics:declare(#{
        name => bondy_http_connector_liveness_probe_duration_milliseconds,
        help => ~"Duration of a periodic liveness probe, by service."
    }),
    ok.

-doc """
Classifies a handler return tuple's WAMP `<<"status">>` code into a
Prometheus-friendly outcome bucket. Every return path in
`bondy_http_connector_callee_handler` — success, upstream errors passed
through, and the gateway's own synthetic `wamp_error/3` responses
(missing path variable, pending auth, upstream connection failure,
internal error) — carries a `<<"status">>` key in its trailing kwargs
map, so this covers every outcome uniformly without a parallel error
taxonomy.
""".
-spec classify_status(Result :: tuple()) ->
    ok | redirect | client_error | server_error | unknown.

classify_status({ok, _Details, _Args, #{<<"status">> := Status}}) ->
    status_class(Status);
classify_status({error, _Uri, _Details, _Args, #{<<"status">> := Status}}) ->
    status_class(Status);
classify_status(_) ->
    unknown.

%% @private
status_class(S) when is_integer(S), S >= 200, S < 300 -> ok;
status_class(S) when is_integer(S), S >= 300, S < 400 -> redirect;
status_class(S) when is_integer(S), S >= 400, S < 500 -> client_error;
status_class(S) when is_integer(S), S >= 500, S < 600 -> server_error;
status_class(_) -> unknown.

%% @private
ready_value(ok) -> 1;
ready_value(error) -> 0.

%% @private
up_value(up) -> 1;
up_value(down) -> 0.

%% @private
%% Total wrapper for sink writes: a raising `bondy_metrics` call (e.g. a
%% metric name reused with the wrong type) must not detach this handler,
%% which would silently kill every family it renders.
safe(Fun) ->
    try
        Fun()
    catch
        Class:Reason:Stacktrace ->
            ?LOG_DEBUG(#{
                description => "Failed to record http_connector metric",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% @private
%% Total wrapper: an emitter must never affect the caller.
execute(Event, Measurements, Meta) ->
    try
        telemetry:execute(Event, Measurements, Meta)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_DEBUG(#{
                description => "Failed to emit telemetry event",
                event => Event,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.
