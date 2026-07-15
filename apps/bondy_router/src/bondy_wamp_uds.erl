%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_uds).

-moduledoc """
WAMP **raw socket over a Unix domain socket** listener.

A UDS connection is a `gen_tcp` stream socket bound to a filesystem path
(`{local, Path}`) rather than a host/port, so it reuses the exact same protocol
handler as the TCP/TLS raw-socket listeners
(`bondy_wamp_tcp_connection_handler`) — only the listen address differs. The
handler maps the UDS peer (which has no IP) to the loopback address, since a UDS
connection is local by construction.

The listener is **opt-in**: it only starts when `[wamp_uds, enabled]` is `true`
(default `false`), so production deployments are unaffected unless the path is
explicitly configured. Because UDS does not fit Bondy's IP-centric listener
config (`bondy_config:listener_transport_opts/1`), this module builds the ranch
transport options directly from a small dedicated `wamp_uds` config block.
""".

-include_lib("kernel/include/logger.hrl").

-define(UDS, wamp_uds).
-define(DEFAULT_PATH, "/tmp/bondy_wamp.sock").
-define(DEFAULT_NUM_ACCEPTORS, 10).
-define(DEFAULT_MAX_CONNECTIONS, infinity).

-export([connections/0]).
-export([path/0]).
-export([resume_listeners/0]).
-export([start_listeners/0]).
-export([stop_listeners/0]).
-export([suspend_listeners/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Conditionally starts the WAMP Unix domain socket listener. A no-op unless
`[wamp_uds, enabled]` is `true`.
""".
-spec start_listeners() -> ok | {error, any()}.

start_listeners() ->
    case bondy_config:get([?UDS, enabled], false) of
        true ->
            Path = path(),
            ok = ensure_clean_path(Path),
            Protocol = bondy_wamp_tcp_connection_handler,
            TransportOpts = transport_opts(Path),
            Result = ranch:start_listener(
                ?UDS, ranch_tcp, TransportOpts, Protocol, []
            ),
            case Result of
                {ok, _} ->
                    ?LOG_NOTICE(#{
                        description =>
                            "Started WAMP Unix domain socket listener",
                        listener => ?UDS,
                        path => Path
                    }),
                    ok;
                {error, _} = Error ->
                    Error
            end;
        false ->
            ok
    end.

-doc "Stops the listener and removes its socket file.".
-spec stop_listeners() -> ok.

stop_listeners() ->
    catch ranch:stop_listener(?UDS),
    _ = file:delete(path()),
    ok.

-spec suspend_listeners() -> ok.

suspend_listeners() ->
    catch ranch:suspend_listener(?UDS),
    ok.

-spec resume_listeners() -> ok.

resume_listeners() ->
    catch ranch:resume_listener(?UDS),
    ok.

connections() ->
    case bondy_config:get([?UDS, enabled], false) of
        true -> ranch:procs(?UDS, connections);
        false -> []
    end.

-doc "Returns the filesystem path the listener binds to.".
-spec path() -> string().

path() ->
    bondy_config:get([?UDS, path], ?DEFAULT_PATH).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
transport_opts(Path) ->
    #{
        num_acceptors =>
            bondy_config:get([?UDS, num_acceptors], ?DEFAULT_NUM_ACCEPTORS),
        max_connections =>
            bondy_config:get([?UDS, max_connections], ?DEFAULT_MAX_CONNECTIONS),
        socket_opts => [{ip, {local, Path}}, {port, 0}]
    }.

%% @private A stale socket file from a previous run makes `gen_tcp:listen/2` fail
%% with `eaddrinuse`, so remove it first.
ensure_clean_path(Path) ->
    case file:delete(Path) of
        ok ->
            ok;
        {error, enoent} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "Could not remove stale Unix domain socket file",
                path => Path,
                reason => Reason
            }),
            ok
    end.
