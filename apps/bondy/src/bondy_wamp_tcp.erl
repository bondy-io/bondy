%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_tcp).


-define(TCP, wamp_tcp).
-define(TLS, wamp_tls).


-export([connections/0]).
-export([resume_listeners/0]).
-export([start_listeners/0]).
-export([stop_listeners/0]).
-export([suspend_listeners/0]).
-export([tcp_connections/0]).
-export([tls_connections/0]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Starts the tcp and tls raw socket listeners
%% @end
%% -----------------------------------------------------------------------------
-spec start_listeners() -> ok | {error, any()}.

start_listeners() ->
    Protocol = bondy_wamp_tcp_connection_handler,
    ok = bondy_ranch_listener:start(?TCP, Protocol, []),
    bondy_ranch_listener:start(?TLS, Protocol, []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec stop_listeners() -> ok.

stop_listeners() ->
    ok = bondy_ranch_listener:stop(?TCP),
    bondy_ranch_listener:stop(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec suspend_listeners() -> ok.

suspend_listeners() ->
    ok = bondy_ranch_listener:suspend(?TCP),
    bondy_ranch_listener:suspend(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec resume_listeners() -> ok.

resume_listeners() ->
    bondy_ranch_listener:resume(?TCP),
    bondy_ranch_listener:resume(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
connections() ->
    bondy_ranch_listener:connections(?TCP)
        ++ bondy_ranch_listener:connections(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
tls_connections() ->
    bondy_ranch_listener:connections(?TLS).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
tcp_connections() ->
    bondy_ranch_listener:connections(?TCP).
