%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rate_limit).
-moduledoc """
Inbound rate-limiting policy: turns the `[security, rate_limit]`
configuration into per-source-IP / per-session token-bucket admission decisions
over `bondy_rate_limiter`.

The whole feature is OFF by default (`security.rate_limit.enabled`), so
`throttle/2` is a single map read returning `ok` on the common path. When on,
each class (`handshake`, `auth`, `connection`, `http`, `message`) has its own
token bucket keyed by the caller-supplied dimension (a source IP, or a session
id for `message`). `http` is per-source-IP HTTP request admission — the API
Gateway and admin API resources (via the `cowboy_rest` `rate_limited` hook)
and the MCP endpoints; requests, not connections, so it is a separate class
from `connection`. Config `rate` is tokens/SECOND (operator-friendly); the
bucket wants tokens/millisecond.

`opts/1` requires the `[security, rate_limit]` config value to be a MAP —
the shape `schema/bondy.schema`'s `bondy_router.security.rate_limit`
translation builds (verified by generation probe, 2026-08-26; the earlier
per-key schema targets generated nested proplists, which this reader
rejected, so conf-file enablement was a no-op).

It never raises — the underlying limiter fails open — so a limiter problem
degrades to "no limit", never to a wedged inbound path.
""".

-include_lib("kernel/include/logger.hrl").

-type class() :: handshake | auth | connection | http | message.

-export_type([class/0]).

-export([throttle/2]).
-export([enabled/1]).
-export([new_session_limiter/0]).
-export([allow_session/1]).
-export([delete_session_limiter/1]).

-type session_limiter() :: bondy_regulator_rate_limit:t() | undefined.

-export_type([session_limiter/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Consume one token from the `{Class, Key}` bucket. Returns `ok` when allowed (or
the class is disabled) and `throttled` when the bucket is exhausted. `Key` is a
source IP (for `handshake`/`auth`/`connection`) or a session identifier (for
`message`).
""".
-spec throttle(Class :: class(), Key :: term()) -> ok | throttled.

throttle(Class, Key) ->
    case opts(Class) of
        disabled ->
            ok;
        Opts ->
            case
                bondy_rate_limiter:allow({bondy_rate_limit, Class, Key}, Opts)
            of
                true ->
                    ok;
                false ->
                    ?LOG_INFO(#{
                        description =>
                            "Inbound request throttled (rate limit)",
                        class => Class,
                        key => Key
                    }),
                    ok = count_denial(Class),
                    throttled
            end
    end.

-doc "Whether the given class is currently enabled.".
-spec enabled(class()) -> boolean().

enabled(Class) ->
    opts(Class) =/= disabled.

-doc """
Creates a dedicated `message`-class token bucket for the CURRENT session, or
`undefined` when message throttling is off. Held in the session's own state and
deleted on teardown (like `bondy_connect_load`), so the per-message hot path is a
single field check + atomics consume — NO per-message config read. The config is
read once here, at session open.
""".
-spec new_session_limiter() -> session_limiter().

new_session_limiter() ->
    case opts(message) of
        disabled ->
            undefined;
        Opts ->
            Key =
                {bondy_msg_limiter, self(), erlang:unique_integer([positive])},
            try bondy_regulator_rate_limit:new(token_bucket, Key, Opts) of
                {ok, T} ->
                    T;
                {error, Reason} ->
                    log_limiter_unavailable(Reason),
                    undefined
            catch
                %% e.g. the regulator's ETS table is not up yet; degrade to
                %% "no message limit" rather than failing session open.
                Class:EReason ->
                    log_limiter_unavailable({Class, EReason}),
                    undefined
            end
    end.

%% @private
log_limiter_unavailable(Reason) ->
    ?LOG_WARNING(#{
        description =>
            "Could not create per-session message limiter; "
            "message throttling inert for this session",
        reason => Reason
    }).

-doc """
Consumes one token from a per-session limiter created by `new_session_limiter/0`.
`undefined` (message throttling off) is always `ok`. Never raises.
""".
-spec allow_session(session_limiter()) -> ok | throttled.

allow_session(undefined) ->
    ok;
allow_session(T) ->
    case bondy_regulator_rate_limit:allow(T, 1) of
        {true, _} ->
            ok;
        {false, _} ->
            ok = count_denial(message),
            throttled
    end.

%% @private
%% The throttling verdict must never depend on the metrics subsystem
%% being up (e.g. before `bondy_prometheus` setup, or in embedded tests).
count_denial(Class) ->
    _ =
        try
            prometheus_counter:inc(bondy_rate_limited_total, [Class], 1)
        catch
            _:_ -> ok
        end,
    ok.

-doc "Deletes a per-session limiter (frees its bucket). No-op for `undefined`.".
-spec delete_session_limiter(session_limiter()) -> ok.

delete_session_limiter(undefined) ->
    ok;
delete_session_limiter(T) ->
    try
        bondy_regulator_rate_limit:delete(T)
    catch
        _:_ -> ok
    end,
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Resolve the token-bucket opts for `Class`, or `disabled`. Reads the whole
%% `[security, rate_limit]` map once (a 2-level get, never traversing into a
%% non-container) and extracts in-memory.
opts(Class) ->
    case bondy_config:get([security, rate_limit], undefined) of
        Cfg when is_map(Cfg) ->
            case is_enabled(Class, Cfg) of
                true ->
                    ClassCfg = sub(Class, Cfg),
                    RatePerSec = maps:get(
                        rate, ClassCfg, default_rate_per_sec(Class)
                    ),
                    #{
                        rate => RatePerSec / 1000,
                        capacity =>
                            maps:get(
                                capacity, ClassCfg, default_capacity(Class)
                            )
                    };
                false ->
                    disabled
            end;
        _ ->
            disabled
    end.

%% @private
%% The feature-wide flag must be on; `message` additionally has its own opt-in
%% flag (it is on the hot per-message path).
is_enabled(Class, Cfg) ->
    on(maps:get(enabled, Cfg, false)) andalso
        case Class of
            message -> on(maps:get(enabled, sub(message, Cfg), false));
            _ -> true
        end.

%% @private
on(true) -> true;
on(on) -> true;
on(_) -> false.

%% @private
sub(Class, Cfg) ->
    case maps:get(Class, Cfg, #{}) of
        M when is_map(M) -> M;
        _ -> #{}
    end.

%% @private
default_rate_per_sec(handshake) -> 10;
default_rate_per_sec(connection) -> 20;
default_rate_per_sec(http) -> 100;
default_rate_per_sec(message) -> 1000;
default_rate_per_sec(_Auth) -> 5.

%% @private
default_capacity(handshake) -> 50;
default_capacity(connection) -> 100;
default_capacity(http) -> 500;
default_capacity(message) -> 2000;
default_capacity(_Auth) -> 20.
